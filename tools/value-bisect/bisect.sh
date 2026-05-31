#!/bin/sh
# Differential value-bisection harness for Spinel.
#
# Runs one Ruby program two ways — under CRuby (the oracle) and as a
# Spinel-compiled --debug binary — capturing the change-history of every
# scalar local on each side, then reports the first local whose value
# diverges. That (line, variable) is the likely silent-miscompile site:
# the failure mode spinelgems calls the dangerous one, because "it compiled"
# != "it works" and nothing else points at where the value went wrong.
#
# Usage:
#   bisect.sh <program.rb> [-- program-args...]
#
# Environment:
#   SPINEL_DIR           Spinel checkout (default: ~/sites/spinel)
#   SPINEL_INT_OVERFLOW  raise|wrap|promote (default: raise) — passed to both
#                        the cc -D switch and matches the wrapper's modes
#   CC                   C compiler (default: cc)
#
# The Spinel build deliberately uses the Ruby interpreter path
# (ruby spinel_analyze.rb / spinel_codegen.rb) rather than the prebuilt
# native binaries, so the harness always reflects the current compiler
# source — and does not depend on a `make` rebuild having happened.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SPINEL_DIR="${SPINEL_DIR:-$HOME/sites/spinel}"
CC="${CC:-cc}"
INT_OVERFLOW="${SPINEL_INT_OVERFLOW:-raise}"

if [ -z "$1" ]; then
  echo "usage: bisect.sh <program.rb> [-- program-args...]" >&2
  exit 2
fi
SRC="$1"; shift
if [ "$1" = "--" ]; then shift; fi   # remaining $@ = program args

if [ ! -f "$SRC" ]; then
  echo "bisect: $SRC: no such file" >&2
  exit 2
fi
PARSE_BIN="$SPINEL_DIR/spinel_parse"
if [ ! -x "$PARSE_BIN" ]; then
  echo "bisect: $PARSE_BIN missing; run 'make parse' in $SPINEL_DIR first" >&2
  exit 2
fi

case "$INT_OVERFLOW" in
  raise)   OVF_DEF="-DSP_INT_OVERFLOW_MODE_RAISE" ;;
  wrap)    OVF_DEF="-DSP_INT_OVERFLOW_MODE_WRAP" ;;
  promote) OVF_DEF="-DSP_INT_OVERFLOW_MODE_PROMOTE" ;;
  *) echo "bisect: SPINEL_INT_OVERFLOW must be raise|wrap|promote" >&2; exit 2 ;;
esac

WORK="$(mktemp -d /tmp/spinel_bisect.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "bisect: program=$SRC  overflow=$INT_OVERFLOW  spinel=$SPINEL_DIR" >&2

# --- CRuby oracle -----------------------------------------------------------
echo "bisect: tracing under CRuby..." >&2
ruby "$HERE/cruby_trace.rb" "$SRC" "$WORK/cruby.json" "$@"

# --- Spinel --debug build (explicit Ruby path; mirrors `spinel --debug`) -----
echo "bisect: compiling with Spinel (--debug)..." >&2
export SPINEL_DEBUG=1
export SPINEL_INT_OVERFLOW="$INT_OVERFLOW"
"$PARSE_BIN" "$SRC" "$WORK/ast"
ruby "$SPINEL_DIR/spinel_analyze.rb" "$WORK/ast" "$WORK/ir"
ruby "$SPINEL_DIR/spinel_codegen.rb" "$WORK/ast" "$WORK/ir" "$WORK/out.c"
$CC -g -O0 -I"$SPINEL_DIR/lib" -I"$SPINEL_DIR/lib/regexp" "$WORK/out.c" \
    "$SPINEL_DIR/lib/libspinel_rt.a" -lm $OVF_DEF -o "$WORK/bin"

# --- Spinel trace under lldb ------------------------------------------------
echo "bisect: tracing the binary under lldb..." >&2
SP_TRACE_SRC="$SRC" SP_TRACE_OUT="$WORK/spinel.json" \
  lldb -b \
    -o "command script import $HERE/spinel_lldb_trace.py" \
    -o "spinel_value_trace" \
    "$WORK/bin" -- "$@" >/dev/null 2>"$WORK/lldb.err" || {
      echo "bisect: lldb run failed:" >&2; cat "$WORK/lldb.err" >&2; exit 1; }

# --- Compare ----------------------------------------------------------------
echo >&2
python3 "$HERE/compare.py" "$WORK/cruby.json" "$WORK/spinel.json"
