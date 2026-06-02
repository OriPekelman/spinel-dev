#!/bin/sh
# spinel doctor — one-shot risk report for a Spinel program.
#
# Runs the cheap-to-expensive battery and says, in one place, everything risky
# about compiling <program.rb> with Spinel:
#   1. compile probe   — `spinel -c`, scrape `cannot resolve call ... (emitting 0)`:
#                        the loud silent-degrade signal (a call Spinel can't lower).
#   2. inference scan  — `spinel --emit-rbs`, surface methods whose signature
#                        widened to `untyped` (the boxed poly slow path / a gap).
#   3. behavior check  — the value-bisection harness vs CRuby (best-effort): does
#                        the compiled binary actually match CRuby? (silent
#                        miscompiles emit no warning, so only this catches them.)
#
# Usage:
#   doctor.sh [--json] [--no-bisect] [--no-cruby] <program.rb> [-- program-args...]
#
# --no-cruby: single-sided behavior leg — for FFI / AOT-only apps (tep, toy) that
# can't run under CRuby. The behavior leg then reports "ran clean" / "crash"
# instead of comparing against an oracle. (Auto-detected too: if the program
# raises immediately under CRuby, the leg degrades to single-sided on its own.)
#
# Env: SPINEL_DIR (default ~/sites/spinel), SPINEL_INT_OVERFLOW (passed to bisect).

HERE="$(cd "$(dirname "$0")" && pwd)"
SPINEL_DIR="${SPINEL_DIR:-$HOME/sites/spinel}"
BISECT="$HERE/../value-bisect/bisect.sh"
JSON=0
DO_BISECT=1
NOCRUBY_FLAG=""
while :; do
  case "$1" in
    --json)      JSON=1; shift ;;
    --no-bisect) DO_BISECT=0; shift ;;
    --no-cruby)  NOCRUBY_FLAG="--no-cruby"; shift ;;  # single-sided behavior leg
    *) break ;;
  esac
done
SRC="$1"; shift
if [ "$1" = "--" ]; then shift; fi
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "usage: doctor.sh [--json] [--no-bisect] <program.rb> [-- args]" >&2
  exit 2
fi
SPINEL="$SPINEL_DIR/spinel"
if [ ! -x "$SPINEL" ]; then
  echo "doctor: $SPINEL not found (set SPINEL_DIR)" >&2; exit 2
fi

WORK="$(mktemp -d /tmp/spinel_doctor.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# count non-empty lines of a (possibly empty) string, robustly.
nlines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c .; fi; }

# 1. Compile probe: collect `cannot resolve call to 'X' ... (emitting 0)`.
"$SPINEL" "$SRC" -c -o "$WORK/x.c" >"$WORK/cc.out" 2>&1
UNRESOLVED=$(grep -E "cannot resolve call" "$WORK/cc.out" 2>/dev/null | sed 's/^[[:space:]]*//')
N_UNRESOLVED=$(nlines "$UNRESOLVED")

# 2. Inference scan: methods that widened to untyped (the # spinel: comments).
"$SPINEL" "$SRC" --emit-rbs -o "$WORK/x.rbs" >/dev/null 2>&1
DEGRADED=$(grep -E "# spinel: widened" "$WORK/x.rbs" 2>/dev/null | sed 's/ # spinel:.*//; s/^[[:space:]]*//')
N_DEGRADED=$(nlines "$DEGRADED")
# Count untyped only in signature lines (`def`/ivar/attr), not the header comment.
N_UNTYPED=$(grep -E "^\s*(def |attr_|@)" "$WORK/x.rbs" 2>/dev/null | grep -oE "untyped" | grep -c . 2>/dev/null)
[ -z "$N_UNTYPED" ] && N_UNTYPED=0

# 3. Behavior check (best-effort): the value-bisection harness vs CRuby. bisect
# exits 1 on a real divergence, so we validate the JSON rather than the exit code.
BEHAVIOR="skipped"
BEHAVIOR_JSON='null'
if [ "$DO_BISECT" -eq 1 ] && [ -x "$BISECT" ]; then
  BJSON=$(SPINEL_DIR="$SPINEL_DIR" "$BISECT" --json $NOCRUBY_FLAG "$SRC" -- "$@" 2>/dev/null)
  V=$(printf '%s' "$BJSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("verdict","?"))' 2>/dev/null)
  if [ -n "$V" ]; then BEHAVIOR="$V"; BEHAVIOR_JSON="$BJSON"; else BEHAVIOR="unavailable"; fi
fi

# Overall verdict.
OVERALL="clean"
if [ "$N_UNRESOLVED" -gt 0 ] || [ "$N_DEGRADED" -gt 0 ]; then OVERALL="degrades"; fi
if [ "$BEHAVIOR" = "diverge" ] || [ "$BEHAVIOR" = "crash" ] || [ "$BEHAVIOR" = "abort" ]; then OVERALL="miscompiles"; fi

if [ "$JSON" -eq 1 ]; then
  python3 - "$SRC" "$OVERALL" "$N_UNRESOLVED" "$N_DEGRADED" "$N_UNTYPED" "$BEHAVIOR" "$WORK/cc.out" "$WORK/x.rbs" "$BEHAVIOR_JSON" <<'PY'
import sys, json, re
src, overall, nu, nd, nt, behavior, ccpath, rbspath, bjson = sys.argv[1:10]
unresolved = [l.strip() for l in open(ccpath, errors="replace") if "cannot resolve call" in l]
degraded = [re.sub(r" # spinel:.*", "", l).strip() for l in open(rbspath, errors="replace") if "# spinel: widened" in l]
out = {"file": src, "verdict": overall,
       "compile": {"unresolved_calls": unresolved},
       "inference": {"degraded_methods": degraded, "untyped_count": int(nt or 0)},
       "behavior": (json.loads(bjson) if bjson and bjson != "null" else behavior)}
print(json.dumps(out))
PY
  exit 0
fi

# Human report.
printf 'spinel doctor: %s\n' "$SRC"
if [ "$N_UNRESOLVED" -gt 0 ]; then
  printf '  compile    ⚠ %s unresolved call(s) — Spinel silently emits 0:\n' "$N_UNRESOLVED"
  printf '%s\n' "$UNRESOLVED" | sed 's/^/               - /'
else
  printf '  compile    ✓ no unresolved calls\n'
fi
if [ "$N_DEGRADED" -gt 0 ]; then
  printf '  inference  ⚠ %s method(s) widened to untyped (slow path / inference gap):\n' "$N_DEGRADED"
  printf '%s\n' "$DEGRADED" | sed 's/^/               - /'
else
  printf '  inference  ✓ no methods widened to untyped (%s untyped slots total)\n' "$N_UNTYPED"
fi
case "$BEHAVIOR" in
  ok)          printf '  behavior   ✓ matches CRuby (value-bisection)\n' ;;
  diverge)     printf '  behavior   ✗ MISCOMPILE — diverges from CRuby (run bisect.sh for the site)\n' ;;
  ran)         printf '  behavior   ~ ran clean under Spinel, but no CRuby oracle (single-sided — values unchecked)\n' ;;
  crash)       printf '  behavior   ✗ CRASH under the harness\n' ;;
  abort)       printf '  behavior   ✗ Spinel raised/aborted before CRuby'\''s result\n' ;;
  skipped)     printf '  behavior   - skipped (--no-bisect)\n' ;;
  *)           printf '  behavior   - unavailable (harness could not run)\n' ;;
esac
printf '  verdict    %s\n' "$OVERALL"
