#!/bin/sh
# spinel doctor — one-shot risk report for a Spinel program.
#
# Runs the cheap-to-expensive battery and says, in one place, everything risky
# about compiling <program.rb> with Spinel:
#   1. compile probe   — `spinel -c`. The LEGACY Ruby compiler silently degrades
#                        an unlowerable call to `emitting 0` (`cannot resolve
#                        call ...`); the C `spinel` (post Ruby->C rewrite) is
#                        strict — it HARD-ERRORS (`spinel: unsupported ...`) and
#                        emits no C. Both signals (+ the exit code) are captured.
#   1c. silent degrade — SPINEL_WARN_UNRESOLVED: the C compiler still silently
#                        lowers an unresolved call on a dynamic receiver (or a
#                        `.new` on an unresolved constant) to nil/0 instead of
#                        raising. The flag surfaces each such site (file:line) —
#                        the C analogue of the legacy `emitting 0`.
#   2. inference scan  — `spinel --emit-rbs`, surface methods whose signature
#                        widened to `untyped` (the boxed poly slow path / a gap).
#   2c. codegen build  — `cc -c` the emitted C. For the strict C compiler this is
#                        the primary leg: its toy-parity gaps surface as cc type
#                        errors here, not as silent emit-0.
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

# 1. Compile probe. Two compiler error models:
#   - LEGACY Ruby compiler: silently degrades an unlowerable call to `emitting 0`
#     and keeps going (`cannot resolve call to 'X' on Y (emitting 0)`).
#   - C `spinel` (post Ruby->C rewrite): strict — it HARD-ERRORS such a construct
#     (`spinel: unsupported ...`, non-zero exit) and emits no C, so the legacy
#     emit-0 grep would FALSELY read "clean". Capture the exit code + the C
#     compiler's own `spinel:` diagnostics too.
# Codegen probe — NO symbol-map env here. The C compiler treats
# --emit-symbol-map / its SPINEL_EMIT_SYMBOL_MAP env as an emit-ONLY mode (writes
# the map, emits an EMPTY .c, exits 0), which would defeat both this leg and the
# cc-build leg (2c). The legacy compiler instead rode the env along with normal
# codegen. So probe codegen first, clean.
# SPINEL_WARN_UNRESOLVED=1 (matz/spinel 5e53c78): default-off, zero codegen effect
# — it only adds stderr `file:line: warning: unresolved ...` lines for the C
# compiler's silent nil/0 degrade path (see leg 1c). Safe to ride the probe run;
# the emitted x.c (and leg 2c) is byte-identical with or without it. Unknown env
# on the legacy compiler → ignored, so this is harmless on both backends.
SPINEL_WARN_UNRESOLVED=1 "$SPINEL" "$SRC" -c -o "$WORK/x.c" >"$WORK/cc.out" 2>&1
SPINEL_C_RC=$?
# Symbol map (matz/spinel#1345) for leg 2c's C-symbol -> Ruby attribution,
# emitted in a SEPARATE best-effort run (throwaway C) so it can't perturb the
# probe above. Honored by both the legacy env path and the C emit-only mode.
SPINEL_EMIT_SYMBOL_MAP="$WORK/x.symbols.json" "$SPINEL" "$SRC" -c -o "$WORK/xsym.c" >/dev/null 2>&1 || true
UNRESOLVED=$(grep -E "cannot resolve call" "$WORK/cc.out" 2>/dev/null | sed 's/^[[:space:]]*//')
N_UNRESOLVED=$(nlines "$UNRESOLVED")
# C-compiler codegen refusal: `spinel: unsupported call/...`. Distinct from the
# cc-build leg (2c) — this is spinel itself refusing to emit valid C. Gated on a
# non-zero exit so a benign `spinel:` info line never trips it.
CODEGEN_REFUSED=""
if [ "$SPINEL_C_RC" -ne 0 ]; then
  CODEGEN_REFUSED=$(grep -E "^spinel: (unsupported|.*unsupported type|C compilation failed)" "$WORK/cc.out" 2>/dev/null | sed 's/^[[:space:]]*//')
fi
N_CODEGEN_REFUSED=$(nlines "$CODEGEN_REFUSED")

# 1c. Silent-degrade scan (matz/spinel 5e53c78, SPINEL_WARN_UNRESOLVED). The C
# compiler hard-errors on MANY unlowerable calls (caught above) but it ALSO keeps
# a silent degrade path: an unresolved call on a dynamically-typed receiver
# (poly/nil/int/unknown), or a `.new` on an unresolved constant, lowers to a
# typed nil/0 instead of raising — the C-compiler analogue of the legacy
# `emitting 0`. With the WARN env on the probe above, each such site reports
# `file:line: warning: unresolved ...`. These are exactly the silent miscompiles
# CRuby would NoMethodError on — the most dangerous failure mode because nothing
# else flags them. Some are deliberate (dead poly arms, inert stdlib like
# Mutex/Pathname), so this is a warn-tier "degrades" signal, not a hard error.
SILENT_DEGRADE=$(grep -E "^spinel: .*: warning: unresolved" "$WORK/cc.out" 2>/dev/null | sed 's/^spinel: //; s/^[[:space:]]*//')
N_SILENT_DEGRADE=$(nlines "$SILENT_DEGRADE")

# 1a. Parse leg. spinel_parse couldn't build the AST — a syntax spinel's Prism
# subset rejects (real gems hit this: e.g. colorize). Nothing downstream is
# meaningful, and the other legs would misleadingly read "✓ clean", so this is
# surfaced first and loudest. (Found running doctor on a real gem.)
PARSE_ERR=$(grep -iE "^Parse error|unexpected .*(expecting|ignoring)" "$WORK/cc.out" 2>/dev/null | sed 's/^[[:space:]]*//')
N_PARSE=$(nlines "$PARSE_ERR")

# 1b. Ignored requires (spinel-dev#9 re-scope). A require Spinel can't resolve — a
# wrong relative path, or a stdlib it doesn't ship — is silently dropped. If it
# defines a module the program then calls, EVERY call to that module resolves
# "on int → emitting 0". So an ignored require is the PRIME SUSPECT for an emit-0
# cascade and deserves top billing, not a buried warning. (A real toy blocker:
# `require_relative "../tinynn"` off by one dir → TinyNN never loads → all
# `TinyNN.tnn_*` emit 0 → zero weights → CE=0.)
IGNORED_REQ=$(grep -iE "(call|require) is ignored" "$WORK/cc.out" 2>/dev/null | sed 's/^[[:space:]]*//; s/^warning: //')
N_IGNORED_REQ=$(nlines "$IGNORED_REQ")

# 2. Inference scan: methods that widened to untyped (the # spinel: comments).
"$SPINEL" "$SRC" --emit-rbs -o "$WORK/x.rbs" >/dev/null 2>&1
DEGRADED=$(grep -E "# spinel: widened" "$WORK/x.rbs" 2>/dev/null | sed 's/ # spinel:.*//; s/^[[:space:]]*//')
N_DEGRADED=$(nlines "$DEGRADED")
# Count untyped only in signature lines (`def`/ivar/attr), not the header comment.
N_UNTYPED=$(grep -E "^\s*(def |attr_|@)" "$WORK/x.rbs" 2>/dev/null | grep -oE "untyped" | grep -c . 2>/dev/null)
[ -z "$N_UNTYPED" ] && N_UNTYPED=0

# 2b. Inference↔codegen disagreement (spinel-dev#9, proposals 2 & 4). LEGACY-ONLY:
# this fingerprints the Ruby compiler's silent emit-0 (it cross-refs the `cannot
# resolve ... (emitting 0)` lines against the RBS). The C `spinel` emits no such
# line: it either HARD-ERRORS (caught by leg 1 / leg 2c) or silently degrades a
# dynamic-receiver call to nil/0 — and that silent path is now surfaced directly
# by leg 1c (SPINEL_WARN_UNRESOLVED), not via this RBS cross-ref. So this leg is
# naturally empty on the C backend (no `emitting 0` lines to match).
# The silent-miscompile fingerprint: codegen emits-0 a call to a method that
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

# 2c. Codegen/build leg (spinel-dev#10). The legs above run `spinel -c` (emit C)
# but never compile the C, so a program that analyzes clean yet emits C that `cc`
# rejects (a Class boxed as int, a reopened `Object` struct, an undeclared branch
# local) reads "clean" — and those C-codegen errors are the bulk of what the
# spinelgems harness files. Compile-only (`cc -c`, no link → skips FFI-object
# noise) the already-emitted `x.c` and classify the first diagnostic.
CODEGEN_CLASS=""; CODEGEN_SYM=""; CODEGEN_MSG=""; CODEGEN_SRC=""; CODEGEN_RUBY=""; N_CODEGEN=0
if [ -s "$WORK/x.c" ]; then
  CFLAGS_X=$(grep -oE 'SPINEL_CFLAGS: .*\*/' "$WORK/x.c" 2>/dev/null | sed 's/.*SPINEL_CFLAGS: //; s/ \*\/.*//' | head -1)
  if ! ${CC:-cc} -c "$WORK/x.c" -o /dev/null -w -I"$SPINEL_DIR/lib" -I"$SPINEL_DIR/lib/regexp" $CFLAGS_X >"$WORK/cc_build.out" 2>&1; then
    CG=$(python3 - "$WORK/cc_build.out" <<'PY'
import sys, re
msg = ""; src = ""
for line in open(sys.argv[1], errors="replace"):
    # gcc's standard `path:line[:col]: error: msg`. With matz/spinel#1338
    # (ea60d5f, #line on by default) `path` is the *Ruby* source — capture it.
    m = re.match(r'\s*([^:\s]+):(\d+)(?::\d+)?:\s*(?:fatal\s+)?error:\s*(.+)', line)
    if m:
        if m.group(1).endswith('.rb'):
            src = f"{m.group(1)}:{m.group(2)}"
        msg = m.group(3).strip(); break
    m2 = re.search(r'error:\s*(.+)', line)
    if m2:
        msg = m2.group(1).strip(); break
if msg:
    q = msg.replace('‘', "'").replace('’', "'").replace('`', "'")
    def sym(p):
        mm = re.search(p, q); return mm.group(1) if mm else ''
    if 'redefinition of' in q:
        cls, s = 'redefinition', sym(r"redefinition of '([^']+)'")
    elif 'unknown type name' in q:
        cls, s = 'unknown-type', sym(r"unknown type name '([^']+)'")
    elif 'undeclared' in q:
        cls, s = 'undeclared-identifier', sym(r"'([^']+)' undeclared")
    elif 'incompatible type for argument' in q:
        cls, s = 'incompatible-type', sym(r"argument \d+ of '([^']+)'")
    elif re.search(r'incompatible|makes (integer|pointer)', q):
        cls, s = 'incompatible-type', sym(r"'([^']+)'")
    elif re.search(r'too (many|few) arguments', q):
        cls, s = 'arg-count-mismatch', sym(r"'([^']+)'")
    elif 'invalid operands' in q:
        cls, s = 'invalid-operands', sym(r"have '([^']+)'")   # e.g. `Set << int`
    else:
        cls, s = 'other', sym(r"'([^']+)'")
    print(f"{cls}\t{s}\t{msg}\t{src}")
PY
)
    CODEGEN_CLASS=$(printf '%s' "$CG" | cut -f1)
    CODEGEN_SYM=$(printf '%s' "$CG" | cut -f2)
    CODEGEN_MSG=$(printf '%s' "$CG" | cut -f3)
    CODEGEN_SRC=$(printf '%s' "$CG" | cut -f4)
    [ -n "$CODEGEN_CLASS" ] && N_CODEGEN=1
    # Attribute the failing C symbol back to its Ruby method via the symbol
    # map — exact, unlike demangling (sanitize_name is irreversible).
    if [ -n "$CODEGEN_SYM" ] && [ -s "$WORK/x.symbols.json" ]; then
      CODEGEN_RUBY=$(python3 - "$WORK/x.symbols.json" "$CODEGEN_SYM" <<'PY'
import sys, json
try:
    rows = json.load(open(sys.argv[1]))["symbols"]
except Exception:
    rows = []
for r in rows:
    if r.get("c") == sys.argv[2]:
        print(r.get("ruby") or "")
        break
PY
)
    fi
  fi
fi

# 3. Behavior check (best-effort): the value-bisection harness vs CRuby. bisect
# exits 1 on a real divergence, so we validate the JSON rather than the exit code.
# Skipped when the codegen leg already failed — there's no valid binary to run.
BEHAVIOR="skipped"
BEHAVIOR_JSON='null'
if [ "$DO_BISECT" -eq 1 ] && [ "$N_CODEGEN" -eq 0 ] && [ "$N_CODEGEN_REFUSED" -eq 0 ] && [ "$N_PARSE" -eq 0 ] && [ -x "$BISECT" ]; then
  BJSON=$(SPINEL_DIR="$SPINEL_DIR" "$BISECT" --json $NOCRUBY_FLAG "$SRC" -- "$@" 2>/dev/null)
  V=$(printf '%s' "$BJSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("verdict","?"))' 2>/dev/null)
  if [ -n "$V" ]; then BEHAVIOR="$V"; BEHAVIOR_JSON="$BJSON"; else BEHAVIOR="unavailable"; fi
fi

# Overall verdict. Order of severity: clean < degrades < miscompile-risk <
# miscompiles. A disagreement is the *static* silent-miscompile fingerprint
# (#9): stronger than a plain degrade, but not behavior-confirmed, so it gets
# its own tier between them.
OVERALL="clean"
# N_SILENT_DEGRADE is the C-compiler analogue of the legacy N_UNRESOLVED (emit-0):
# both are unresolved calls lowered to nil/0, so they share the "degrades" tier.
if [ "$N_UNRESOLVED" -gt 0 ] || [ "$N_DEGRADED" -gt 0 ] || [ "$N_SILENT_DEGRADE" -gt 0 ]; then OVERALL="degrades"; fi
# An ignored require is itself a degrade; paired with an emit-0/degrade cascade
# it's the likely root cause, so escalate to the static-miscompile tier.
if [ "$N_IGNORED_REQ" -gt 0 ]; then
  [ "$OVERALL" = "clean" ] && OVERALL="degrades"
  if [ "$N_UNRESOLVED" -gt 0 ] || [ "$N_SILENT_DEGRADE" -gt 0 ] || [ "$N_DISAGREE" -gt 0 ]; then OVERALL="miscompile-risk"; fi
fi
if [ "$N_DISAGREE" -gt 0 ]; then OVERALL="miscompile-risk"; fi
if [ "$BEHAVIOR" = "diverge" ] || [ "$BEHAVIOR" = "crash" ] || [ "$BEHAVIOR" = "abort" ] || [ "$BEHAVIOR" = "output-differ" ]; then OVERALL="miscompiles"; fi
# A codegen error means the program doesn't even build — definitive, and it
# trumps the rest (there's no binary to have behavior). Set last.
if [ "$N_CODEGEN" -gt 0 ]; then OVERALL="codegen-error"; fi
# The strict C compiler refusing to emit valid C (`spinel: unsupported ...`,
# non-zero exit) is the same tier: no C, no binary. (The legacy compiler instead
# emits-0 and is caught by N_UNRESOLVED above, a softer "degrades".)
if [ "$N_CODEGEN_REFUSED" -gt 0 ]; then OVERALL="codegen-error"; fi
# A parse error is the earliest, most fundamental failure — spinel couldn't even
# build the AST, so every other leg's reading is moot. Trumps all. Set last.
if [ "$N_PARSE" -gt 0 ]; then OVERALL="parse-error"; fi

if [ "$JSON" -eq 1 ]; then
  python3 - "$SRC" "$OVERALL" "$N_UNRESOLVED" "$N_DEGRADED" "$N_UNTYPED" "$BEHAVIOR" "$WORK/cc.out" "$WORK/x.rbs" "$BEHAVIOR_JSON" "$WORK/disagree.txt" "$CODEGEN_CLASS" "$CODEGEN_SYM" "$CODEGEN_MSG" "$CODEGEN_SRC" "$CODEGEN_RUBY" <<'PY'
import sys, json, re
src, overall, nu, nd, nt, behavior, ccpath, rbspath, bjson, dispath, cg_cls, cg_sym, cg_msg, cg_src, cg_ruby = sys.argv[1:16]
cc = open(ccpath, errors="replace").read().splitlines()
unresolved = [l.strip() for l in cc if "cannot resolve call" in l]
parse_errors = [l.strip() for l in cc
                if re.match(r"^Parse error", l) or re.search(r"unexpected .*(expecting|ignoring)", l)]
ignored_requires = [re.sub(r"^\s*warning:\s*", "", l).strip()
                    for l in cc if re.search(r"(call|require) is ignored", l, re.I)]
codegen_refused = [l.strip() for l in cc
                   if re.match(r"^spinel: (unsupported|.*unsupported type|C compilation failed)", l)]
silent_degrades = [re.sub(r"^spinel:\s*", "", l).strip() for l in cc
                   if re.search(r": warning: unresolved", l)]
try:
    degraded = [re.sub(r" # spinel:.*", "", l).strip() for l in open(rbspath, errors="replace") if "# spinel: widened" in l]
except OSError:  # emit-rbs produces no file on a parse-error input
    degraded = []
try:
    disagreements = [l.strip() for l in open(dispath, errors="replace") if l.strip()]
except OSError:
    disagreements = []
codegen = {"error_class": cg_cls, "symbol": cg_sym, "ruby": (cg_ruby or None), "message": cg_msg, "source": (cg_src or None)} if cg_cls else None
out = {"file": src, "verdict": overall,
       "parse_errors": parse_errors,
       "compile": {"unresolved_calls": unresolved, "silent_degrades": silent_degrades, "ignored_requires": ignored_requires, "codegen_refused": codegen_refused},
       "inference": {"degraded_methods": degraded, "untyped_count": int(nt or 0)},
       "disagreements": disagreements,
       "codegen": codegen,
       "behavior": (json.loads(bjson) if bjson and bjson != "null" else behavior)}
print(json.dumps(out))
PY
  exit 0
fi

# Human report.
printf 'spinel doctor: %s\n' "$SRC"
if [ "$N_PARSE" -gt 0 ]; then
  printf '  parse      ✗ spinel could not parse this file (%s error(s)) — its Prism subset\n' "$N_PARSE"
  printf '             rejects some syntax here; every check below is moot until this is fixed:\n'
  printf '%s\n' "$PARSE_ERR" | head -6 | sed 's/^/               - /'
fi
if [ "$N_IGNORED_REQ" -gt 0 ]; then
  printf '  require    ✗ %s ignored require(s) — PRIME SUSPECT for emit-0 cascades:\n' "$N_IGNORED_REQ"
  printf '%s\n' "$IGNORED_REQ" | sed 's/^/               - /'
  if [ "$N_UNRESOLVED" -gt 0 ]; then
    printf '             ↳ likely the root cause of the %s unresolved call(s) below: an unloaded\n' "$N_UNRESOLVED"
    printf '               module makes every call to it resolve "on int" and emit 0.\n'
  fi
fi
if [ "$N_CODEGEN_REFUSED" -gt 0 ]; then
  printf '  compile    ✗ spinel refused to emit C (strict C compiler) — %s diagnostic(s):\n' "$N_CODEGEN_REFUSED"
  printf '%s\n' "$CODEGEN_REFUSED" | head -6 | sed 's/^/               - /'
elif [ "$N_UNRESOLVED" -gt 0 ]; then
  printf '  compile    ⚠ %s unresolved call(s) — the legacy compiler silently emits 0:\n' "$N_UNRESOLVED"
  printf '%s\n' "$UNRESOLVED" | sed 's/^/               - /'
else
  printf '  compile    ✓ no unresolved/unsupported calls\n'
fi
if [ "$N_SILENT_DEGRADE" -gt 0 ]; then
  printf '  degrade    ⚠ %s silent unresolved-call degrade(s) — the C compiler lowered these to\n' "$N_SILENT_DEGRADE"
  printf '             nil/0 where CRuby would raise (some may be deliberate dead/inert paths):\n'
  printf '%s\n' "$SILENT_DEGRADE" | head -10 | sed 's/^/               - /'
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
if [ "$N_CODEGEN" -gt 0 ]; then
  # Show the exact Ruby method when the symbol map resolved it.
  SYM_SHOW="${CODEGEN_SYM:-?}"
  [ -n "$CODEGEN_RUBY" ] && SYM_SHOW="$SYM_SHOW (= $CODEGEN_RUBY)"
  if [ -n "$CODEGEN_SRC" ]; then
    printf '  codegen    ✗ C build FAILS at %s [%s] on %s:\n' "$CODEGEN_SRC" "$CODEGEN_CLASS" "$SYM_SHOW"
  else
    printf '  codegen    ✗ C build FAILS [%s] on %s — the emitted C does not compile:\n' "$CODEGEN_CLASS" "$SYM_SHOW"
  fi
  printf '               %s\n' "$CODEGEN_MSG"
else
  printf '  codegen    ✓ emitted C compiles\n'
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
