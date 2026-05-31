"""Spinel side of the differential value-bisection harness (runs inside lldb).

A Spinel binary compiled with `--debug` carries `#line` directives mapping the
generated C back to the original .rb plus named `lv_<local>` variables. This
script drives that binary under lldb: it sets a breakpoint on every source
line, runs to exit, and at each stop records the change-history of every scalar
`lv_*` local — the exact same {var: [[line, "tag:value"], ...]} structure the
CRuby side emits, so `compare.py` can diff the two symmetrically.

Invoke (from bisect.sh):
    SP_TRACE_SRC=<program.rb> SP_TRACE_OUT=<out.json> \
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


def _scalarize(v):
    """Return a typed 'tag:value' string for a scalar SBValue, else None."""
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
    return None


def value_trace(debugger, command, result, internal_dict):
    src = os.environ.get("SP_TRACE_SRC")
    out_path = os.environ.get("SP_TRACE_OUT")
    if not src or not out_path:
        result.SetError("SP_TRACE_SRC and SP_TRACE_OUT must be set")
        return

    src_base = os.path.basename(src)
    with open(src) as f:
        n_lines = sum(1 for _ in f)

    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        result.SetError("no target selected")
        return

    # One breakpoint per source line. Lines with no generated code resolve to
    # zero locations and are harmless; lldb matches the file by basename.
    resolved = 0
    for line in range(1, n_lines + 1):
        bp = target.BreakpointCreateByLocation(src_base, line)
        if bp.GetNumLocations() > 0:
            resolved += 1

    histories = {}      # var -> [[line, tagged_value], ...]
    last = {}           # var -> last recorded tagged_value
    skipped = set()     # names seen but non-scalar (reported, not compared)
    events = 0

    error = lldb.SBError()
    process = target.LaunchSimple(None, None, os.getcwd())

    stops = 0
    while process and process.GetState() == lldb.eStateStopped:
        stops += 1
        if stops > MAX_STOPS:
            break
        thread = process.GetSelectedThread()
        frame = thread.GetFrameAtIndex(0)
        line = frame.GetLineEntry().GetLine()
        events += 1
        # args=True, locals=True, statics=False, in_scope_only=True
        for v in frame.GetVariables(True, True, False, True):
            name = v.GetName()
            if not name or not name.startswith("lv_"):
                continue
            tagged = _scalarize(v)
            key = name[3:]
            if tagged is None:
                skipped.add(key)
                continue
            if last.get(key) != tagged:
                last[key] = tagged
                histories.setdefault(key, []).append([line, tagged])
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
