"""Spinel side of the differential value-bisection harness (runs inside lldb).

A Spinel binary compiled with `--debug` carries `#line` directives mapping the
generated C back to the original .rb files (multi-file: across
require_relative'd sources) plus named `lv_<local>` variables. This script
drives that binary under lldb: it sets a breakpoint on every source line of
every compiled file, runs to exit, and at each stop records the change-history
of every scalar `lv_*` local — keyed by "<basename>::<var>", the same structure
cruby_trace.rb emits, so compare.py can diff the two symmetrically.

Invoke (from bisect.sh):
    SP_TRACE_SRCS=<file1.rb:file2.rb:...> SP_TRACE_OUT=<out.json> \
    lldb -b -o 'command script import spinel_lldb_trace.py' \
            -o 'spinel_value_trace' <binary> [-- args...]

Scope: scalar locals only (mrb_int / mrb_float / mrb_bool). Strings and
containers are pointers to runtime structs and need formatter support — a
follow-up. Their absence is reported in the JSON ("skipped_nonscalar").
"""

import json
import os

import lldb

INT_TYPES = {"mrb_int", "long", "long long", "long int", "int", "int64_t"}
FLOAT_TYPES = {"mrb_float", "double", "float"}
BOOL_TYPES = {"mrb_bool", "bool", "_Bool"}

MAX_STOPS = 200000  # backstop against a runaway loop in a bad repro
MAX_STR = 65536     # cap a string read; matches the CRuby side


def _format(v, process):
    """Return a typed 'tag:value' string for a scalar or string SBValue, else
    None. Strings (Spinel string locals are `const char *` to NUL-terminated
    bytes) are read straight from inferior memory — no inferior calls."""
    tn = v.GetTypeName()
    if tn in INT_TYPES:
        return "i:%d" % v.GetValueAsSigned()
    if tn in BOOL_TYPES:
        return "b:true" if v.GetValueAsUnsigned() != 0 else "b:false"
    if tn in FLOAT_TYPES:
        err = lldb.SBError()
        d = v.GetData().GetDouble(err, 0)
        if err.Success():
            return "f:%r" % d
        txt = v.GetValue()
        return "f:" + txt if txt else None
    if tn.replace("const", "").replace(" ", "") == "char*":
        addr = v.GetValueAsUnsigned()
        if addr == 0:
            return "s:"
        err = lldb.SBError()
        s = process.ReadCStringFromMemory(addr, MAX_STR, err)
        if err.Success() and s is not None:
            return "s:" + s
        return None
    return None


def value_trace(debugger, command, result, internal_dict):
    srcs = os.environ.get("SP_TRACE_SRCS")
    out_path = os.environ.get("SP_TRACE_OUT")
    if not srcs or not out_path:
        result.SetError("SP_TRACE_SRCS and SP_TRACE_OUT must be set")
        return

    files = [s for s in srcs.split(":") if s]

    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        result.SetError("no target selected")
        return

    # One breakpoint per source line of every compiled file. Lines with no
    # generated code resolve to zero locations and are harmless; lldb matches
    # by basename against the (now multi-file) line table.
    resolved = 0
    for src in files:
        base = os.path.basename(src)
        try:
            with open(src) as f:
                n_lines = sum(1 for _ in f)
        except OSError:
            continue
        for line in range(1, n_lines + 1):
            bp = target.BreakpointCreateByLocation(base, line)
            if bp.GetNumLocations() > 0:
                resolved += 1

    histories = {}      # "<file>::<var>" -> [[line, tagged_value], ...]
    last = {}
    skipped = set()
    events = 0

    process = target.LaunchSimple(None, None, os.getcwd())

    src_bases = set(os.path.basename(s) for s in files)
    crash = None  # {line, file, signal} when the program stops on a signal

    stops = 0
    while process and process.GetState() == lldb.eStateStopped:
        stops += 1
        if stops > MAX_STOPS:
            break
        thread = process.GetSelectedThread()
        reason = thread.GetStopReason()
        # A signal/exception stop that isn't one of our breakpoints is a crash
        # (SIGSEGV, SIGABRT, …). Attribute it to the nearest Ruby-source frame
        # so triage points at a .rb line, not runtime C, then stop tracing.
        if reason in (lldb.eStopReasonSignal, lldb.eStopReasonException):
            cline, cfile = 0, "?"
            for i in range(thread.GetNumFrames()):
                fle = thread.GetFrameAtIndex(i).GetLineEntry()
                fb = fle.GetFileSpec().GetFilename()
                if fb in src_bases and fle.GetLine() > 0:
                    cline, cfile = fle.GetLine(), fb
                    break
            crash = {
                "line": cline,
                "file": cfile,
                "signal": thread.GetStopDescription(128) or "signal",
            }
            break

        frame = thread.GetFrameAtIndex(0)
        le = frame.GetLineEntry()
        line = le.GetLine()
        fbase = le.GetFileSpec().GetFilename() or "?"
        events += 1
        for v in frame.GetVariables(True, True, False, True):
            name = v.GetName()
            if not name or not name.startswith("lv_"):
                continue
            tagged = _format(v, process)
            key = fbase + "::" + name[3:]
            if tagged is None:
                skipped.add(key)
                continue
            if last.get(key) != tagged:
                last[key] = tagged
                # [line, value, global-event-seq]; seq is symmetric with the
                # CRuby side (the comparator ranks by the oracle's seq).
                histories.setdefault(key, []).append([line, tagged, events])
        process.Continue()

    exit_code = -1
    state = process.GetState() if process else lldb.eStateInvalid
    if state == lldb.eStateExited:
        exit_code = process.GetExitStatus()

    payload = {
        "exit": exit_code,
        "events": events,
        "resolved_lines": resolved,
        "skipped_nonscalar": sorted(skipped),
        "crash": crash,
        "histories": histories,
    }
    with open(out_path, "w") as f:
        json.dump(payload, f)
    result.AppendMessage(
        "spinel_value_trace: %d line-bps, %d stops, exit=%d -> %s"
        % (resolved, events, exit_code, out_path)
    )


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "command script add -f spinel_lldb_trace.value_trace spinel_value_trace"
    )
