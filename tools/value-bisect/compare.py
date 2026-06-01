"""Diff a CRuby value-history against a Spinel value-history and report the
first place a local's value diverges — the likely silent-miscompile site.

Both inputs are { "histories": { var: [[line, "tag:value"], ...] } } as emitted
by cruby_trace.rb and spinel_lldb_trace.py. For each variable present on both
sides we walk the two change-histories in lockstep and find the first index
where they differ; the earliest such divergence (by source line) is the headline
finding. Variables present on only one side, and any line/exit-level
disagreement, are reported as secondary signals.

Usage: python3 compare.py <cruby.json> <spinel.json> [--float-tol 1e-9]
Exit status: 0 = traces agree on all common scalars, 1 = divergence found.
"""

import json
import sys


def _load(path):
    with open(path) as f:
        return json.load(f)


def _split(key):
    """'helper.rb::r' -> ('helper.rb', 'r'); bare key -> ('', key)."""
    if "::" in key:
        f, v = key.split("::", 1)
        return f, v
    return "", key


def _parse(tag):
    """'i:5'->('i',5); 'f:1.5'->('f',1.5); 'b:true'->('b',True); 's:hi'->('s','hi')."""
    kind, _, raw = tag.partition(":")
    if kind == "i":
        return ("i", int(raw))
    if kind == "f":
        return ("f", float(raw))
    if kind == "b":
        return ("b", raw == "true")
    if kind == "s":
        return ("s", raw)
    if kind == "a":
        return ("a", raw)
    return ("?", raw)


def _is_zero(tag):
    kind, val = _parse(tag)
    if kind == "i":
        return val == 0
    if kind == "f":
        return val == 0.0
    if kind == "b":
        return val is False
    if kind == "s":
        return val == ""   # Spinel's empty-string init is the string phantom
    if kind == "a":
        return val == "[]"  # Spinel's NULL-array init is the array phantom
    return False


def _eq(a, b, ftol):
    ka, va = _parse(a)
    kb, vb = _parse(b)
    if ka != kb:
        # int vs float of equal magnitude can be a faithful representation
        # difference; treat numerically rather than as a hard type clash.
        if {ka, kb} <= {"i", "f"}:
            return abs(float(va) - float(vb)) <= ftol * max(1.0, abs(float(va)))
        return False
    if ka == "f":
        return abs(va - vb) <= ftol * max(1.0, abs(va))
    return va == vb


def _first_divergence(cv, sv, ftol):
    """First point cv and sv part. Returns (idx, cruby_tag, spinel_tag) for a
    value mismatch; if the overlap matches but lengths differ, the divergence
    is at the end of the overlap (one side kept changing); None if identical."""
    n = min(len(cv), len(sv))
    for idx in range(n):
        if not _eq(cv[idx][1], sv[idx][1], ftol):
            return (idx, cv[idx][1], sv[idx][1])
    if len(cv) != len(sv):
        ct = cv[n][1] if n < len(cv) else "<no more changes>"
        st = sv[n][1] if n < len(sv) else "<no more changes>"
        return (n, ct, st)
    return None


def main():
    args = sys.argv[1:]
    ftol = 1e-9
    if "--float-tol" in args:
        i = args.index("--float-tol")
        ftol = float(args[i + 1])
        del args[i : i + 2]
    as_json = "--json" in args
    if as_json:
        args.remove("--json")
    # In --json mode the human report is suppressed; a single JSON object is
    # printed at the end (for triage / agents / CI).
    _print = (lambda *a, **k: None) if as_json else print
    cruby_path, spinel_path = args[0], args[1]

    cruby = _load(cruby_path)
    spinel = _load(spinel_path)
    ch = cruby.get("histories", {})
    sh = spinel.get("histories", {})

    _print("== differential value-bisection ==")
    _print("  CRuby : exit=%s, %s line-events, %d scalar vars"
          % (cruby.get("exit"), cruby.get("events"), len(ch)))
    _print("  Spinel: exit=%s, %s line-events, %d scalar vars"
          % (spinel.get("exit"), spinel.get("events"), len(sh)))
    skipped = spinel.get("skipped_nonscalar") or []
    if skipped:
        _print("  (Spinel non-scalar locals not compared: %s)" % ", ".join(skipped))

    findings = []  # (seq, line, var, idx, cruby_val, spinel_val)
    common = sorted(set(ch) & set(sh))
    for var in common:
        cv = ch[var]
        # Spinel zero-inits every local, so its first entry can be a phantom
        # the oracle never sees — but the phantom's value (0) can also equal a
        # genuine value, so we can't decide by value alone. Instead try the
        # alignment with and without a single leading zero-init entry and keep
        # whichever agrees *longest*; the right one falls out naturally:
        #   - real overflow (phantom 0 != true first): dropping aligns far ->
        #     finds the real, late divergence;
        #   - legit first 0 (i = 0): not dropping aligns perfectly;
        #   - wrapped result that happens to be 0: not dropping reports the
        #     clean "0 vs <big>" instead of vanishing.
        candidates = [sh[var]]
        if sh[var] and _is_zero(sh[var][0][1]):
            candidates.append(sh[var][1:])  # drop one leading zero-init phantom
        # Score each alignment: no-divergence beats any divergence; among
        # divergences a later first-divergence beats an earlier one, and a
        # concrete value mismatch beats a "ran out of changes". On a full tie
        # prefer the phantom-dropped alignment (later in the list) so the
        # reported Spinel value is the real one, not the zero-init.
        def _score(d):
            if d is None:
                return (2, 0, 0)
            is_val = 0 if (str(d[1]).startswith("<no more")
                           or str(d[2]).startswith("<no more")) else 1
            return (1, d[0], is_val)
        div = None
        best_score = None
        for sv in candidates:
            d = _first_divergence(cv, sv, ftol)
            sc = _score(d)
            if best_score is None or sc >= best_score:
                best_score = sc
                div = d
        if div is not None:
            idx, ct, st = div[0], div[1], div[2]
            # Locate the oracle entry for execution-order ranking + reporting.
            ce = cv[idx] if idx < len(cv) else (cv[-1] if cv else (0, "", 0))
            seq = ce[2] if len(ce) > 2 else 0
            findings.append((seq, ce[0], var, idx, ct, st))

    # Rank by the oracle's event sequence: the earliest-executing divergence
    # (the likely root cause) comes first, even if it lives in a callee on a
    # higher line number than its downstream consequence.
    findings.sort(key=lambda t: (t[0], t[2]))

    only_c = sorted(set(ch) - set(sh))
    only_s = sorted(set(sh) - set(ch))

    crash = spinel.get("crash")
    spinel_exit = spinel.get("exit")
    cruby_exit = cruby.get("exit")
    # Spinel exited nonzero while CRuby didn't: it raised/aborted before
    # producing CRuby's result. That outranks a value divergence, which here is
    # usually the zero-init phantom of a variable Spinel never got to assign.
    aborted = bool(spinel_exit) and spinel_exit > 0 and spinel_exit != cruby_exit

    if crash:
        where = ("%s:%s" % (crash.get("file"), crash.get("line"))
                 if crash.get("line") else "an unknown location")
        _print("\n[CRASH] Spinel stopped on a fault at %s\n        %s"
              % (where, crash.get("signal")))
    elif aborted:
        _print("\n[ABORT] Spinel exited %s (raised/aborted) where CRuby exited %s "
              "— it stopped before producing CRuby's result." % (spinel_exit, cruby_exit))

    diverged = bool(findings) or bool(crash) or aborted

    if findings:
        seq, cl, var, idx, ct, st = findings[0]
        fname, vname = _split(var)
        _print("\n[FIRST DIVERGENCE]  (earliest in execution order)")
        _print("  file     : %s" % (fname or "(toplevel)"))
        _print("  variable : %s" % vname)
        _print("  line     : %s" % cl)
        _print("  change # : %d (of this var's history)" % idx)
        _print("  CRuby    : %s" % ct)
        _print("  Spinel   : %s" % st)
        if len(findings) > 1:
            _print("\n  other diverging variables (later in execution):")
            for seq, cl, var, idx, ct, st in findings[1:]:
                fname, vname = _split(var)
                loc = ("%s:%s" % (fname, cl)) if fname else ("line %s" % cl)
                _print("    %s @ %s: CRuby %s vs Spinel %s"
                      % (vname, loc, ct, st))
    else:
        _print("\n[OK] all %d common scalar variables agree across their "
              "full change-histories." % len(common))

    if only_c or only_s:
        _print()
        if only_c:
            _print("  only CRuby tracked (scalar): %s" % ", ".join(only_c))
        if only_s:
            _print("  only Spinel tracked (scalar): %s" % ", ".join(only_s))

    # Stable verdict (one-line pipe form for triage.sh; full object for --json).
    # Priority: crash > abort > value divergence > bare exit mismatch > ok.
    result = {"cruby_exit": cruby_exit, "spinel_exit": spinel_exit}
    if crash:
        result.update(verdict="crash", file=crash.get("file"),
                      line=crash.get("line"), signal=crash.get("signal"))
        _print("VERDICT|crash|%s|%s|%s"
              % (crash.get("file"), crash.get("line"), crash.get("signal")))
    elif aborted:
        result.update(verdict="abort")
        _print("VERDICT|abort|%s|%s" % (spinel_exit, cruby_exit))
    elif findings:
        seq, cl, var, idx, ct, st = findings[0]
        fname, vname = _split(var)
        result.update(verdict="diverge", file=fname, variable=vname, line=cl,
                      cruby=ct, spinel=st,
                      others=[{"file": _split(v)[0], "variable": _split(v)[1],
                               "line": l, "cruby": c, "spinel": s}
                              for (_sq, l, v, _i, c, s) in findings[1:]])
        _print("VERDICT|diverge|%s|%s|%s|%s|%s" % (fname, vname, cl, ct, st))
    elif cruby_exit != spinel_exit:
        result.update(verdict="exit-differ")
        _print("VERDICT|exit-differ|%s|%s" % (cruby_exit, spinel_exit))
    else:
        result.update(verdict="ok")
        _print("VERDICT|ok")

    if as_json:
        print(json.dumps(result))

    return 1 if diverged else 0


if __name__ == "__main__":
    sys.exit(main())
