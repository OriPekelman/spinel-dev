#!/bin/sh
# Automatic miscompile / crash triage for the Spinel test suite.
#
# For each failing test, run the differential value-bisection harness and report
# WHERE the Spinel binary first parts ways with CRuby — variable + line for a
# silent miscompile, file:line + signal for a crash — instead of just "output
# differs". Turns a red test into an actionable pointer for a human or an agent.
#
# Usage:
#   triage.sh --failing            # triage every FAIL/ERR in build/test-results
#   triage.sh test/foo.rb [...]    # triage specific tests
#
# Run `make test` first for --failing (it writes build/test-results/*.ok).
# Env: SPINEL_DIR (default ~/sites/spinel).

HERE="$(cd "$(dirname "$0")" && pwd)"
SPINEL_DIR="${SPINEL_DIR:-$HOME/sites/spinel}"

if [ "$1" = "--failing" ]; then
  RESULTS="$SPINEL_DIR/build/test-results"
  if [ ! -d "$RESULTS" ]; then
    echo "triage: no results at $RESULTS — run 'make test' in $SPINEL_DIR first" >&2
    exit 2
  fi
  TESTS=$(grep -lE '^(FAIL|ERR)' "$RESULTS"/*.ok 2>/dev/null | while read -r f; do
    bn=$(basename "$f" .ok); echo "$SPINEL_DIR/test/$bn.rb"
  done)
elif [ -n "$1" ]; then
  TESTS="$*"
else
  echo "usage: triage.sh --failing | <test.rb>..." >&2
  exit 2
fi

if [ -z "$TESTS" ]; then
  echo "triage: no failing tests 🎉"
  exit 0
fi

n=0; loc=0; crash=0; abort=0; opaque=0; nobuild=0
for t in $TESTS; do
  n=$((n + 1))
  base=$(basename "$t")
  if [ ! -f "$t" ]; then
    printf '  ??      %-32s (no such file)\n' "$base"; continue
  fi
  args=""
  [ -f "$t.args" ] && args=$(cat "$t.args")

  out=$(SPINEL_INT_OVERFLOW="${SPINEL_INT_OVERFLOW:-raise}" \
        "$HERE/bisect.sh" "$t" -- $args 2>/dev/null)
  v=$(printf '%s\n' "$out" | grep '^VERDICT|' | head -1)
  vtype=$(printf '%s' "$v" | cut -d'|' -f2)

  case "$vtype" in
    crash)
      crash=$((crash + 1))
      f=$(printf '%s' "$v" | cut -d'|' -f3)
      l=$(printf '%s' "$v" | cut -d'|' -f4)
      s=$(printf '%s' "$v" | cut -d'|' -f5)
      printf '  CRASH   %-32s %s:%s  %s\n' "$base" "$f" "$l" "$s" ;;
    diverge)
      loc=$((loc + 1))
      var=$(printf '%s' "$v" | cut -d'|' -f4)
      l=$(printf '%s' "$v" | cut -d'|' -f5)
      c=$(printf '%s' "$v" | cut -d'|' -f6)
      sp=$(printf '%s' "$v" | cut -d'|' -f7)
      printf '  MISCMP  %-32s %s @L%s  CRuby=%s  Spinel=%s\n' "$base" "$var" "$l" "$c" "$sp" ;;
    abort)
      abort=$((abort + 1))
      se=$(printf '%s' "$v" | cut -d'|' -f3)
      printf '  ABORT   %-32s Spinel raised/exited %s before CRuby'\''s result\n' "$base" "$se" ;;
    exit-differ)
      opaque=$((opaque + 1))
      printf '  ABORT   %-32s exit codes differ; no scalar/string divergence\n' "$base" ;;
    ok)
      opaque=$((opaque + 1))
      printf '  OPAQUE  %-32s no scalar/string divergence (container/output, or -O2-specific)\n' "$base" ;;
    *)
      nobuild=$((nobuild + 1))
      printf '  NOBUILD %-32s harness could not run (does not compile / error)\n' "$base" ;;
  esac
done

echo "  ----"
printf '  triaged %d: %d localized, %d crash, %d abort, %d opaque, %d no-build\n' \
  "$n" "$loc" "$crash" "$abort" "$opaque" "$nobuild"
