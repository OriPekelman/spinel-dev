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

JSON=0
NOCRUBY=0          # single-sided: skip the CRuby oracle (for FFI/AOT-only apps
                   # that can't run under CRuby — tep, toy). No divergence verdict;
                   # still gives crash localization + the Spinel-side value trace.
while :; do
  case "$1" in
    --json)     JSON=1; shift ;;       # machine-readable verdict
    --no-cruby) NOCRUBY=1; shift ;;    # explicit single-sided mode
    *) break ;;
  esac
done
if [ -z "$1" ]; then
  echo "usage: bisect.sh [--json] [--no-cruby] <program.rb> [-- program-args...]" >&2
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
# Single-sided when --no-cruby, or auto when the program can't run under CRuby
# (FFI / AOT-only frameworks: a plain `ruby <file>` raises at require). Without an
# oracle there's no divergence check, but the Spinel-side trace still localizes a
# crash and dumps the computed values.
if [ "$NOCRUBY" -eq 0 ]; then
  echo "bisect: tracing under CRuby..." >&2
  # The traced program's own stdout (its puts output) is irrelevant — we compare
  # values, not output — and would pollute --json. Drop it; the trace goes to a file.
  ruby "$HERE/cruby_trace.rb" "$SRC" "$WORK/cruby.json" "$SRCS" "$@" >/dev/null
  # Auto-fallback: cruby_trace records the program's own exit in the JSON; 70 is
  # its sentinel for "raised an exception". An immediate raise (e.g. `ffi_lib`
  # undefined, or an AOT-only `require` guard) means there's no usable oracle —
  # switch to single-sided rather than emit a misleading exit-differ.
  CEXIT=$(awk -F'"exit":' 'NR==1{split($2,a,",");print a[1]+0}' "$WORK/cruby.json" 2>/dev/null)
  if [ "$CEXIT" = "70" ]; then
    echo "bisect: program does not run under CRuby (raised) — no oracle; single-sided." >&2
    NOCRUBY=1
  fi
fi
if [ "$NOCRUBY" -eq 1 ]; then
  printf '{"exit":null,"events":0,"histories":{},"no_oracle":true}' > "$WORK/cruby.json"
fi

# --- Spinel --debug build (explicit Ruby path; mirrors `spinel --debug`) -----
echo "bisect: compiling with Spinel (--debug)..." >&2
ruby "$SPINEL_DIR/spinel_analyze.rb" "$WORK/ast" "$WORK/ir"
ruby "$SPINEL_DIR/spinel_codegen.rb" "$WORK/ast" "$WORK/ir" "$WORK/out.c"

# `#line` directives corrupt clang's DWARF variable-location info, so lldb reads
# a function's locals from the wrong stack slot (their zero-init) whenever the
# function has heap/GC-rooted locals — see spinel-line-dwarf-bug. So we DON'T
# trace the #line build. Instead: derive a C-line -> (ruby file, ruby line) map
# from the directives, then blank them out (preserving line count, so the C
# physical lines are stable and the DWARF is clean). We breakpoint by C line and
# map values back to Ruby positions via the cmap. Locals then read correctly.
# Each C line maps to the Ruby line of the most recent #line directive — a
# statement's several C lines all belong to that ONE Ruby line, so do NOT
# increment. (Epilogue C lines after the last directive map to the last
# statement's line; their reads agree with it, so they're harmless.)
awk '
  /^}/ { armed = 0; next }          # function close: stop mapping until the
                                     # next function arms via its own #line, so
                                     # a callees prologue/decls (no #line of
                                     # their own) do not inherit a stale mapping
  /^#line / {
    rl = $2 + 0
    f = $3; gsub(/"/, "", f)
    armed = 1; next
  }
  { if (armed) print NR, f, rl }
' "$WORK/out.c" > "$WORK/cmap"
sed 's/^#line .*//' "$WORK/out.c" > "$WORK/trace.c"
CFILE="$WORK/trace.c"
# Scrape the codegen's FFI markers (same as the `spinel` wrapper) so a program
# that calls into an ffi_lib / ffi_func actually links — without this the harness
# can only build FFI-free programs. Markers with an unresolved @PLACEHOLDER@
# (e.g. tep's @TEP_SPHTTP_O@) still fail to link: build such apps with their
# placeholders substituted (their own build, or a vendored copy).
FFI_LINKS=$(sed -n 's|^/\* SPINEL_LINK: \(.*\) \*/$|\1|p' "$WORK/out.c" | tr '\n' ' ')
FFI_CFLAGS=$(sed -n 's|^/\* SPINEL_CFLAGS: \(.*\) \*/$|\1|p' "$WORK/out.c" | tr '\n' ' ')
$CC -g -O0 -I"$SPINEL_DIR/lib" -I"$SPINEL_DIR/lib/regexp" $FFI_CFLAGS "$CFILE" \
    "$SPINEL_DIR/lib/libspinel_rt.a" -lm $OVF_DEF $FFI_LINKS -o "$WORK/bin" 2>"$WORK/cc.err" || {
      echo "bisect: C build failed (FFI markers unresolved? see below):" >&2
      grep -iE "error|undefined|placeholder|@[A-Z_]+@" "$WORK/cc.err" | head -5 >&2
      exit 1; }

# Capture the binary's own stdout for the output-diff fallback: when no local
# diverges but the program's output does (a divergent method return consumed
# straight by `puts`), compare.py reports output-differ instead of a false ok.
# Oracle mode only (no CRuby stdout to compare against under --no-cruby).
SP_STDOUT="$WORK/spinel.stdout"
if [ "$NOCRUBY" -eq 0 ]; then
  "$WORK/bin" "$@" > "$SP_STDOUT" 2>/dev/null || true
fi

# --- Spinel trace under lldb ------------------------------------------------
echo "bisect: tracing the binary under lldb..." >&2
SP_TRACE_SRCS="$SRCS" SP_TRACE_OUT="$WORK/spinel.json" \
SP_TRACE_CMAP="$WORK/cmap" SP_TRACE_CFILE="$(basename "$CFILE")" \
  lldb -b \
    -o "command script import $HERE/spinel_lldb_trace.py" \
    -o "spinel_value_trace" \
    "$WORK/bin" -- "$@" >/dev/null 2>"$WORK/lldb.err" || {
      echo "bisect: lldb run failed:" >&2; cat "$WORK/lldb.err" >&2; exit 1; }

# --- Compare (or single-sided report when there's no oracle) ----------------
CMP_FLAGS=""
if [ "$NOCRUBY" -eq 1 ]; then
  CMP_FLAGS="--no-oracle"
else
  CMP_FLAGS="--spinel-stdout $SP_STDOUT"
fi
if [ "$JSON" -eq 1 ]; then
  python3 "$HERE/compare.py" "$WORK/cruby.json" "$WORK/spinel.json" $CMP_FLAGS --json
else
  echo >&2
  python3 "$HERE/compare.py" "$WORK/cruby.json" "$WORK/spinel.json" $CMP_FLAGS
fi
