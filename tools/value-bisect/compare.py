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

    findings = []  # (line, var, idx, cruby_val, spinel_val)
    common = sorted(set(ch) & set(sh))
    for var in common:
        cv, sv = ch[var], sh[var]
        # Spinel zero-inits every local at function entry, so a breakpoint on
        # the assignment line can read the variable *before* it is set — a
        # phantom leading 0 that CRuby (which skips a still-nil local) never
        # sees. Drop exactly that single leading zero-init entry, and only when
        # it disagrees with the oracle's first value (if the real first value
        # is itself 0, the phantom is indistinguishable and harmless). Values,
        # not lines, drive alignment: the two runtimes attribute the same
        # value-change to different lines (CRuby reports it as-of the next line
        # event, Spinel as-of the breakpoint line).
        if sv and cv and _is_zero(sv[0][1]) and not _eq(sv[0][1], cv[0][1], ftol):
            sv = sv[1:]
        n = min(len(cv), len(sv))
        for idx in range(n):
            (cl, ct), (sl, st) = cv[idx], sv[idx]
            if not _eq(ct, st, ftol):
                findings.append((cl, var, idx, ct, st))
                break
        else:
            if len(cv) != len(sv):
                # Histories agreed as far as both went, but one kept changing.
                longer, val = (("CRuby", cv) if len(cv) > len(sv)
                               else ("Spinel", sv))
                extra_line = val[n][0]
                findings.append((extra_line, var, n,
                                 "<%s has more changes>" % longer, ""))

    findings.sort(key=lambda t: (t[0], t[1]))

    only_c = sorted(set(ch) - set(sh))
    only_s = sorted(set(sh) - set(ch))

    diverged = bool(findings)
    if not diverged and cruby.get("exit") != spinel.get("exit"):
        print("\n[!] exit codes differ (CRuby=%s, Spinel=%s) but no scalar "
              "divergence found — check non-scalar state or control flow."
              % (cruby.get("exit"), spinel.get("exit")))

    if findings:
        cl, var, idx, ct, st = findings[0]
        print("\n[FIRST DIVERGENCE]")
        print("  variable : %s" % var)
        print("  line     : %s" % cl)
        print("  change # : %d (of this var's history)" % idx)
        print("  CRuby    : %s" % ct)
        print("  Spinel   : %s" % st)
        if len(findings) > 1:
            print("\n  other diverging variables:")
            for cl, var, idx, ct, st in findings[1:]:
                print("    %s @ line %s: CRuby %s vs Spinel %s"
                      % (var, cl, ct, st))
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
