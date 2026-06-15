#!/bin/sh
# Regression guard for spinel-dev#11-#14 — the "f7ae245 family" of
# poly-widening / array-element-typing miscompiles that were fixed in the
# legacy Ruby compiler on a fork branch (08a189c / 96c6c48 / a699cf9 /
# ddee073) and never upstreamed.
#
# The matz/spinel Ruby->C rewrite (legacy/ -> src/*.c) fixes all four
# INDEPENDENTLY in the new C `spinel` (verified on b60fbd7, 2026-06-15):
# whole-program parse + reachability-based dead-method elimination (#11/#12),
# native poly_array with sp_PolyArray_delete_at + element dispatch (#14,
# also matz/spinel#1369 closed same day), and element-handoff FFI bridges
# sp_PolyArray_ffi_int_data/_float_data (#13, matz/spinel#1389 = b60fbd7).
#
# The fork patches are therefore terminal (they patch the now-frozen
# legacy/ tree). These repros are kept as a behavior guard so the four
# fixes can't silently regress in the C compiler. Each FAILED on the
# pre-fix legacy compiler with the symptom noted in its .rb header.
#
# Usage:
#   ./run.sh                  # uses ${SPINEL_BIN} or ${SPINEL_DIR}/spinel
#   SPINEL_BIN=/path/to/spinel ./run.sh
#   SPINEL_DIR=/srv/data/scratch/sp-master ./run.sh
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SPINEL="${SPINEL_BIN:-${SPINEL_DIR:-$HOME/sites/spinel}/spinel}"

if [ ! -x "$SPINEL" ]; then
  echo "error: spinel binary not found/executable at: $SPINEL" >&2
  echo "       set SPINEL_BIN or SPINEL_DIR" >&2
  exit 2
fi

pass=0 fail=0
for rb in "$dir"/*.rb; do
  name=$(basename "$rb" .rb)
  exp="$rb.expected"
  [ -f "$exp" ] || { echo "SKIP $name (no .expected)"; continue; }
  got=$("$SPINEL" -E "$rb" 2>"$dir/.$name.err")
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$got" = "$(cat "$exp")" ]; then
    echo "PASS $name"
    pass=$((pass + 1))
    rm -f "$dir/.$name.err"
  else
    echo "FAIL $name (rc=$rc)"
    echo "  expected: $(cat "$exp" | tr '\n' '|')"
    echo "  got:      $(printf '%s' "$got" | tr '\n' '|')"
    grep -E ': error:|^spinel:' "$dir/.$name.err" 2>/dev/null | head -3 | sed 's/^/  /'
    fail=$((fail + 1))
  fi
done

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
