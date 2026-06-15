#!/bin/sh
# spinel-gate-bisect — which upstream spinel commit first broke (or fixed) my app?
#
# Wraps `git bisect run` over a spinel rev range: at each candidate it BUILDS the
# compiler, then runs a project GATE as the discriminator — with the skip
# discipline the manual #13/#14 bisects needed (a rev whose toolchain won't build,
# or whose app fails for an UNRELATED reason, must be skipped, not mis-classified).
# Distinct from value-bisect (which localizes a value within one compile): this
# localizes the COMMIT. See docs/09 tool #3.
#
# Two gate modes:
#   --compile <entry.rb> --bad-when <regex>   [--rbs DIR] [--root DIR]
#       built-in: build spinel, compile <entry> with it, then classify ->
#         compiles clean            => GOOD (regression absent)
#         output matches <regex>    => BAD  (the regression)
#         fails some OTHER way      => SKIP (unrelated breakage at this rev)
#   --gate "<cmd>"
#       generic: run <cmd> with SPINEL_DIR/SPINEL_BIN pointing at the freshly
#       built compiler; its exit code IS the verdict (0 good / 1 bad / 125 skip).
#
# Usage:
#   spinel-gate-bisect.sh --repo <spinel-git-dir> --good <rev> --bad <rev> \
#       [--build "<cmd>"]   ( --compile <entry.rb> --bad-when <re> [--rbs D] [--root D] | --gate "<cmd>" )
#
#   --build  how to build the compiler at each rev (default: "make all"); run in --repo.
#
# IMPORTANT: --repo's HEAD is moved by git bisect. Use a DEDICATED worktree
# (`git worktree add`), not your working checkout. The tool restores HEAD
# (git bisect reset) on exit, including Ctrl-C.

set -u

REPO="" GOOD="" BAD="" BUILD="make all" GATE="" ENTRY="" BADWHEN="" RBS="" ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="$2"; shift 2 ;;
    --good)     GOOD="$2"; shift 2 ;;
    --bad)      BAD="$2"; shift 2 ;;
    --build)    BUILD="$2"; shift 2 ;;
    --gate)     GATE="$2"; shift 2 ;;
    --compile)  ENTRY="$2"; shift 2 ;;
    --bad-when) BADWHEN="$2"; shift 2 ;;
    --rbs)      RBS="$2"; shift 2 ;;
    --root)     ROOT="$2"; shift 2 ;;
    *) echo "spinel-gate-bisect: unknown arg $1" >&2; exit 2 ;;
  esac
done

die() { echo "spinel-gate-bisect: $1" >&2; exit 2; }
[ -n "$REPO" ] || die "missing --repo <spinel-git-dir>"
[ -n "$GOOD" ] || die "missing --good <rev>"
[ -n "$BAD" ]  || die "missing --bad <rev>"
REPO=$(CDPATH= cd -- "$REPO" && pwd) || die "--repo: no such dir"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "--repo is not a git repo"
git -C "$REPO" rev-parse --verify "$GOOD^{commit}" >/dev/null 2>&1 || die "--good: bad rev $GOOD"
git -C "$REPO" rev-parse --verify "$BAD^{commit}"  >/dev/null 2>&1 || die "--bad: bad rev $BAD"
if [ -z "$GATE" ]; then
  [ -n "$ENTRY" ] && [ -n "$BADWHEN" ] || die "give either --gate, or --compile <entry> --bad-when <regex>"
fi
ROOT=${ROOT:-$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)}
# Resolve a stable label for HEAD to restore (branch name, else detached SHA).
ORIG_HEAD=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$REPO" rev-parse HEAD)

cleanup() { git -C "$REPO" bisect reset >/dev/null 2>&1; git -C "$REPO" checkout -q "$ORIG_HEAD" 2>/dev/null; }
trap 'cleanup; exit 130' INT TERM

# --- the per-rev step script (run by `git bisect run`, cwd = $REPO at the rev) --
STEP=$(mktemp /tmp/spinel_gate_step.XXXXXX.sh)
cat > "$STEP" <<STEPEOF
#!/bin/sh
# Build the compiler at this rev; a build failure is a SKIP (toolchain-broken),
# never a verdict — git bisect treats 125 as "can't test this one".
$BUILD >/dev/null 2>&1 || exit 125
[ -x "$REPO/spinel" ] || exit 125
STEPEOF
if [ -n "$GATE" ]; then
  cat >> "$STEP" <<STEPEOF
SPINEL_DIR="$REPO" SPINEL_BIN="$REPO/spinel" sh -c '$GATE'
ec=\$?
# Map a non-{0,1,125} exit to skip so a crashing gate doesn't mis-bisect.
case \$ec in 0|1|125) exit \$ec ;; *) exit 125 ;; esac
STEPEOF
else
  RBSARG=""; [ -n "$RBS" ] && RBSARG="--rbs '$RBS'"
  cat >> "$STEP" <<STEPEOF
out=\$( cd "$ROOT" && "$REPO/spinel" $RBSARG "$ENTRY" -o /tmp/spinel_gate_bin.\$\$ 2>&1 )
rc=\$?
rm -f /tmp/spinel_gate_bin.\$\$
if [ \$rc -eq 0 ]; then exit 0; fi                                   # compiles -> GOOD
if printf '%s\n' "\$out" | grep -qE "$BADWHEN"; then exit 1; fi      # the regression -> BAD
exit 125                                                            # other failure -> SKIP
STEPEOF
fi
chmod +x "$STEP"

echo "spinel-gate-bisect: repo=$REPO" >&2
echo "  range: good=$GOOD  bad=$BAD  ($(git -C "$REPO" rev-list --count "$GOOD..$BAD" 2>/dev/null) commits)" >&2
echo "  gate:  ${GATE:-compile '$ENTRY' bad-when /$BADWHEN/}" >&2

git -C "$REPO" bisect reset >/dev/null 2>&1
git -C "$REPO" bisect start || die "bisect start failed"
git -C "$REPO" bisect bad "$BAD"   || { cleanup; die "bisect bad failed"; }
git -C "$REPO" bisect good "$GOOD" || { cleanup; die "bisect good failed"; }

RUNLOG=$(mktemp /tmp/spinel_gate_run.XXXXXX)
git -C "$REPO" bisect run "$STEP" 2>&1 | tee "$RUNLOG"

echo >&2
# `git bisect run` prints "<sha> is the first bad commit" on a clean converge, or
# leaves a candidate set when skips block a unique answer. Report both honestly.
FIRSTBAD=$(grep -E 'is the first bad commit' "$RUNLOG" | head -1 | awk '{print $1}')
if [ -n "$FIRSTBAD" ]; then
  echo "FIRST BAD: $(git -C "$REPO" log --oneline -1 "$FIRSTBAD")" >&2
else
  echo "INCONCLUSIVE — skips (toolchain-broken / unrelated-failure revs) blocked a unique answer." >&2
  echo "Remaining candidates (git bisect's bad-set minus skips):" >&2
  git -C "$REPO" bisect log 2>/dev/null | grep -E '^# (skip|good|bad)' | tail -20 >&2
fi

git -C "$REPO" bisect log > "${BISECT_LOG_OUT:-/tmp/spinel-gate-bisect.log}" 2>/dev/null
echo "  full bisect log: ${BISECT_LOG_OUT:-/tmp/spinel-gate-bisect.log}" >&2
cleanup
rm -f "$STEP" "$RUNLOG"
[ -n "$FIRSTBAD" ]
