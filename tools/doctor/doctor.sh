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

# 2b. Inference↔codegen disagreement (spinel-dev#9, proposals 2 & 4). The
# silent-miscompile fingerprint: codegen emits-0 a call to a method that
# inference RESOLVED on a user class. That means the receiver's class was lost
# at the codegen leg while the inference leg knew it — the call silently no-ops.
# This is the malign subset of `on int` (proposal 4): an emit-0 on a *user*
# method is a lost-receiver bug; an emit-0 on a non-user (FFI/builtin) call is
# the expected/benign `:ptr`-as-int lowering. Cross-reference the two legs.
python3 - "$WORK/cc.out" "$WORK/x.rbs" >"$WORK/disagree.txt" 2>/dev/null <<'PY'
import sys, re
cc = open(sys.argv[1], errors="replace").read()
rbs = open(sys.argv[2], errors="replace").read()
# methods inference defined on user classes (def name:, def self.name:, attrs)
methods = set()
for m in re.finditer(r'^\s*def\s+(?:self\.)?([A-Za-z_]\w*[=?!]?)\s*:', rbs, re.M):
    methods.add(m.group(1))
for m in re.finditer(r'^\s*attr_(?:reader|writer|accessor)\s+([A-Za-z_]\w*)', rbs, re.M):
    methods.add(m.group(1)); methods.add(m.group(1) + '=')
DEGRADED = re.compile(r'\b(?:int|poly|untyped|nil)\b')
seen = set()
for line in cc.splitlines():
    mm = re.search(r"cannot resolve call to '([^']+)' on (.+?) \(emitting 0\)", line)
    if not mm:
        continue
    meth, recv = mm.group(1), mm.group(2).strip()
    deg = bool(DEGRADED.search(recv))
    # A constructor call (`X.new`) emit-0'd on a degraded receiver is, by
    # definition, a lost class receiver — `new`/`allocate` can't land on an int.
    ctor = meth in ("new", "allocate") and deg
    if meth in methods or ctor:               # inference knows it on a user class (or it's a constructor)
        sev = "lost-receiver" if deg else "type-mismatch"
        key = (meth, recv)
        if key not in seen:
            seen.add(key)
            print(f"{meth} on {recv}  [{sev}: inference resolves it, codegen emits 0]")
PY
N_DISAGREE=$(nlines "$(cat "$WORK/disagree.txt" 2>/dev/null)")

# 3. Behavior check (best-effort): the value-bisection harness vs CRuby. bisect
# exits 1 on a real divergence, so we validate the JSON rather than the exit code.
BEHAVIOR="skipped"
BEHAVIOR_JSON='null'
if [ "$DO_BISECT" -eq 1 ] && [ -x "$BISECT" ]; then
  BJSON=$(SPINEL_DIR="$SPINEL_DIR" "$BISECT" --json $NOCRUBY_FLAG "$SRC" -- "$@" 2>/dev/null)
  V=$(printf '%s' "$BJSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("verdict","?"))' 2>/dev/null)
  if [ -n "$V" ]; then BEHAVIOR="$V"; BEHAVIOR_JSON="$BJSON"; else BEHAVIOR="unavailable"; fi
fi

# Overall verdict. Order of severity: clean < degrades < miscompile-risk <
# miscompiles. A disagreement is the *static* silent-miscompile fingerprint
# (#9): stronger than a plain degrade, but not behavior-confirmed, so it gets
# its own tier between them.
OVERALL="clean"
if [ "$N_UNRESOLVED" -gt 0 ] || [ "$N_DEGRADED" -gt 0 ]; then OVERALL="degrades"; fi
if [ "$N_DISAGREE" -gt 0 ]; then OVERALL="miscompile-risk"; fi
if [ "$BEHAVIOR" = "diverge" ] || [ "$BEHAVIOR" = "crash" ] || [ "$BEHAVIOR" = "abort" ] || [ "$BEHAVIOR" = "output-differ" ]; then OVERALL="miscompiles"; fi

if [ "$JSON" -eq 1 ]; then
  python3 - "$SRC" "$OVERALL" "$N_UNRESOLVED" "$N_DEGRADED" "$N_UNTYPED" "$BEHAVIOR" "$WORK/cc.out" "$WORK/x.rbs" "$BEHAVIOR_JSON" "$WORK/disagree.txt" <<'PY'
import sys, json, re
src, overall, nu, nd, nt, behavior, ccpath, rbspath, bjson, dispath = sys.argv[1:11]
unresolved = [l.strip() for l in open(ccpath, errors="replace") if "cannot resolve call" in l]
degraded = [re.sub(r" # spinel:.*", "", l).strip() for l in open(rbspath, errors="replace") if "# spinel: widened" in l]
try:
    disagreements = [l.strip() for l in open(dispath, errors="replace") if l.strip()]
except OSError:
    disagreements = []
out = {"file": src, "verdict": overall,
       "compile": {"unresolved_calls": unresolved},
       "inference": {"degraded_methods": degraded, "untyped_count": int(nt or 0)},
       "disagreements": disagreements,
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
if [ "$N_DISAGREE" -gt 0 ]; then
  printf '  disagree   ✗ %s inference↔codegen DISAGREEMENT(s) — the silent-miscompile fingerprint:\n' "$N_DISAGREE"
  printf '             (inference resolves the method on a user class; codegen lost the receiver and emits 0)\n'
  cat "$WORK/disagree.txt" | sed 's/^/               - /'
fi
case "$BEHAVIOR" in
  ok)          printf '  behavior   ✓ matches CRuby (value-bisection)\n' ;;
  diverge)     printf '  behavior   ✗ MISCOMPILE — diverges from CRuby (run bisect.sh for the site)\n' ;;
  output-differ) printf '  behavior   ✗ MISCOMPILE — stdout differs from CRuby (no scalar local pinned; run bisect.sh)\n' ;;
  ran)         printf '  behavior   ~ ran clean under Spinel, but no CRuby oracle (single-sided — values unchecked)\n' ;;
  crash)       printf '  behavior   ✗ CRASH under the harness\n' ;;
  abort)       printf '  behavior   ✗ Spinel raised/aborted before CRuby'\''s result\n' ;;
  skipped)     printf '  behavior   - skipped (--no-bisect)\n' ;;
  *)           printf '  behavior   - unavailable (harness could not run)\n' ;;
esac
printf '  verdict    %s\n' "$OVERALL"
