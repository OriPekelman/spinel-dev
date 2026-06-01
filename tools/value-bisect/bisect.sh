#!/bin/sh
# Differential value-bisection harness for Spinel.
#
# Runs one Ruby program two ways — under CRuby (the oracle) and as a
# Spinel-compiled --debug binary — capturing the change-history of every
# scalar local on each side, then reports the first local whose value
# diverges. That (file, line, variable) is the likely silent-miscompile site:
# the failure mode spinelgems calls the dangerous one, because "it compiled"
# != "it works" and nothing else points at where the value went wrong.
#
# Multi-file: require_relative'd files are traced too. The set of compiled
# files is read from the parser's FILE records (which back --debug's
# multi-file source map) and handed to both sides so they trace the same
# files and key variables by "<basename>::<var>".
#
# Usage:
#   bisect.sh <program.rb> [-- program-args...]
#
# Environment:
#   SPINEL_DIR           Spinel checkout (default: ~/sites/spinel)
#   SPINEL_INT_OVERFLOW  raise|wrap|promote (default: raise)
#   CC                   C compiler (default: cc)
#
# The Spinel build uses the Ruby interpreter path (ruby spinel_analyze.rb /
# spinel_codegen.rb) so the harness always reflects the current compiler
# source and does not depend on a `make` rebuild.

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

export SPINEL_DEBUG=1
export SPINEL_INT_OVERFLOW="$INT_OVERFLOW"

# --- Parse first, so the FILE table tells us which files to trace ----------
"$PARSE_BIN" "$SRC" "$WORK/ast"
# FILE <id> <escaped-path>; $3 is the escaped path (no spaces). Unescape the
# couple of characters the parser escapes, then join with ':'.
SRCS="$(awk '/^FILE /{print $3}' "$WORK/ast" | sed 's/%20/ /g; s/%25/%/g' | paste -sd: -)"
[ -z "$SRCS" ] && SRCS="$SRC"
echo "bisect: tracing files: $(printf '%s' "$SRCS" | tr ':' ' ')" >&2

# --- CRuby oracle -----------------------------------------------------------
echo "bisect: tracing under CRuby..." >&2
ruby "$HERE/cruby_trace.rb" "$SRC" "$WORK/cruby.json" "$SRCS" "$@"

# --- Spinel --debug build (explicit Ruby path; mirrors `spinel --debug`) -----
echo "bisect: compiling with Spinel (--debug)..." >&2
ruby "$SPINEL_DIR/spinel_analyze.rb" "$WORK/ast" "$WORK/ir"
ruby "$SPINEL_DIR/spinel_codegen.rb" "$WORK/ast" "$WORK/ir" "$WORK/out.c"
$CC -g -O0 -I"$SPINEL_DIR/lib" -I"$SPINEL_DIR/lib/regexp" "$WORK/out.c" \
    "$SPINEL_DIR/lib/libspinel_rt.a" -lm $OVF_DEF -o "$WORK/bin"

# Reliability guard: SP_GC_ROOT's cleanup attribute + #line make clang emit
# DWARF where lldb reads a function's locals at their *entry* values, so a heap
# local (array/hash/object) — and every other local in that same function —
# can read as its zero-init. Value divergences in such a program may be false
# positives; warn so they're confirmed against the native run, not trusted.
if grep -q 'SP_GC_ROOT' "$WORK/out.c" 2>/dev/null; then
  echo "bisect: ⚠ note: this program has heap-allocated (GC-rooted) locals; under" >&2
  echo "        -O0+#line, lldb may read locals at their entry values, so a reported" >&2
  echo "        divergence may be a false positive. Confirm against the native run." >&2
fi

# --- Spinel trace under lldb ------------------------------------------------
echo "bisect: tracing the binary under lldb..." >&2
SP_TRACE_SRCS="$SRCS" SP_TRACE_OUT="$WORK/spinel.json" \
  lldb -b \
    -o "command script import $HERE/spinel_lldb_trace.py" \
    -o "spinel_value_trace" \
    "$WORK/bin" -- "$@" >/dev/null 2>"$WORK/lldb.err" || {
      echo "bisect: lldb run failed:" >&2; cat "$WORK/lldb.err" >&2; exit 1; }

# --- Compare ----------------------------------------------------------------
echo >&2
python3 "$HERE/compare.py" "$WORK/cruby.json" "$WORK/spinel.json"
