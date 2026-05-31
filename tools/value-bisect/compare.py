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
    """'i:5' -> ('i', 5); 'f:1.5' -> ('f', 1.5); 'b:true' -> ('b', True)."""
    kind, _, raw = tag.partition(":")
    if kind == "i":
        return ("i", int(raw))
    if kind == "f":
        return ("f", float(raw))
    if kind == "b":
        return ("b", raw == "true")
    return ("?", raw)


def _is_zero(tag):
    kind, val = _parse(tag)
    if kind == "i":
        return val == 0
    if kind == "f":
        return val == 0.0
    if kind == "b":
        return val is False
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
    cruby_path, spinel_path = args[0], args[1]

    cruby = _load(cruby_path)
    spinel = _load(spinel_path)
    ch = cruby.get("histories", {})
    sh = spinel.get("histories", {})

    print("== differential value-bisection ==")
    print("  CRuby : exit=%s, %s line-events, %d scalar vars"
          % (cruby.get("exit"), cruby.get("events"), len(ch)))
    print("  Spinel: exit=%s, %s line-events, %d scalar vars"
          % (spinel.get("exit"), spinel.get("events"), len(sh)))
    skipped = spinel.get("skipped_nonscalar") or []
    if skipped:
        print("  (Spinel non-scalar locals not compared: %s)" % ", ".join(skipped))

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
            candidates.append(sh[var][1:])
        best = None  # (rank, divergence-tuple-or-None)
        for sv in candidates:
            div = _first_divergence(cv, sv, ftol)
            rank = float("inf") if div is None else div[0]
            if best is None or rank > best[0]:
                best = (rank, div)
        div = best[1]
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

    diverged = bool(findings)
    if not diverged and cruby.get("exit") != spinel.get("exit"):
        print("\n[!] exit codes differ (CRuby=%s, Spinel=%s) but no scalar "
              "divergence found — check non-scalar state or control flow."
              % (cruby.get("exit"), spinel.get("exit")))

    if findings:
        seq, cl, var, idx, ct, st = findings[0]
        fname, vname = _split(var)
        print("\n[FIRST DIVERGENCE]  (earliest in execution order)")
        print("  file     : %s" % (fname or "(toplevel)"))
        print("  variable : %s" % vname)
        print("  line     : %s" % cl)
        print("  change # : %d (of this var's history)" % idx)
        print("  CRuby    : %s" % ct)
        print("  Spinel   : %s" % st)
        if len(findings) > 1:
            print("\n  other diverging variables (later in execution):")
            for seq, cl, var, idx, ct, st in findings[1:]:
                fname, vname = _split(var)
                loc = ("%s:%s" % (fname, cl)) if fname else ("line %s" % cl)
                print("    %s @ %s: CRuby %s vs Spinel %s"
                      % (vname, loc, ct, st))
    else:
        print("\n[OK] all %d common scalar variables agree across their "
              "full change-histories." % len(common))

    if only_c or only_s:
        print()
        if only_c:
            print("  only CRuby tracked (scalar): %s" % ", ".join(only_c))
        if only_s:
            print("  only Spinel tracked (scalar): %s" % ", ".join(only_s))

    return 1 if diverged else 0


if __name__ == "__main__":
    sys.exit(main())
