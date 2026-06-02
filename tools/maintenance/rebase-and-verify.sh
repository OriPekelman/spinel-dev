#!/bin/sh
# Keep the Spinel fork's PR branch (feat/typing) rebased on matz/spinel master,
# gated by BOTH the unit suite AND a tool-smoke pass.
#
# Why the tool smokes: matz/spinel moves ~60 commits/day, and a rebase can apply
# "cleanly" yet silently drop our wrapper glue — we hit exactly this once, where
# the rebase lost `--emit-rbs`/`--debug` from the `spinel` wrapper and `make test`
# stayed green (the tools aren't in the unit suite). So after the suite we
# exercise the tooling surfaces directly; a drop there fails the run.
#
# Safe by construction: works in a throwaway worktree (never touches your main
# checkout, which may be on a frozen/detached engine), keeps a backup ref, and
# only force-pushes when the rebase is conflict-free AND the suite AND the tool
# smokes all pass. Conflicts or any red -> abort, report, exit non-zero (a human
# or a scheduled agent then resolves + evolves the harness).
#
# Usage:  rebase-and-verify.sh [--push]
#   (default: verify only, print the push command; --push: force-push on green)
#
# Env: FORK_DIR (default ~/sites/spinel), BRANCH (feat/typing),
#      UPSTREAM_REMOTE (origin), PUSH_REMOTE (ori), WORKTREE (scratch path).
set -eu

FORK_DIR="${FORK_DIR:-$HOME/sites/spinel}"
BRANCH="${BRANCH:-feat/typing}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-origin}"     # = matz/spinel
PUSH_REMOTE="${PUSH_REMOTE:-fork}"               # = OriPekelman/spinel via SSH.
# NB: use the SSH remote, not the HTTPS/OAuth one (`ori`): when a rebase pulls in
# upstream .github/workflows/*.yml changes, an OAuth token without `workflow`
# scope is refused ("refusing to allow an OAuth App to ... workflow"). SSH has no
# such restriction.
WORKTREE="${WORKTREE:-/srv/data/scratch/spinel-rebase}"
SPINEL_DEV="${SPINEL_DEV:-$HOME/sites/spinel-dev}"
DO_PUSH=0
[ "${1:-}" = "--push" ] && DO_PUSH=1

say() { echo "[rebase-verify] $*"; }
fail() { echo "[rebase-verify] FAIL: $*" >&2; exit "${2:-1}"; }

git -C "$FORK_DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "no git repo at $FORK_DIR"
say "fetching $UPSTREAM_REMOTE master ..."
git -C "$FORK_DIR" fetch "$UPSTREAM_REMOTE" master --quiet

MB=$(git -C "$FORK_DIR" merge-base "$BRANCH" "$UPSTREAM_REMOTE/master")
BEHIND=$(git -C "$FORK_DIR" rev-list --count "$MB..$UPSTREAM_REMOTE/master")
AHEAD=$(git -C "$FORK_DIR" rev-list --count "$MB..$BRANCH")
say "$BRANCH is $AHEAD commit(s) ahead of merge-base; master is $BEHIND ahead."
if [ "$BEHIND" -eq 0 ]; then say "already current with master. nothing to do."; exit 0; fi

# Backup ref (cheap; lets us recover if anything goes sideways).
BACKUP="backup/rebase-$(git -C "$FORK_DIR" rev-parse --short "$BRANCH")"
git -C "$FORK_DIR" branch -f "$BACKUP" "$BRANCH"
say "backup ref: $BACKUP"

# Fresh DETACHED worktree at the branch tip (detached so it doesn't collide with
# the branch being checked out in another worktree; we publish via HEAD:BRANCH).
git -C "$FORK_DIR" worktree remove --force "$WORKTREE" 2>/dev/null || true
git -C "$FORK_DIR" worktree add --force --detach "$WORKTREE" "$BRANCH" >/dev/null
# Vendored prism/rbs aren't tracked; share the main checkout's.
mkdir -p "$WORKTREE/vendor"
for v in prism rbs; do
  [ -d "$FORK_DIR/vendor/$v" ] && ln -sfn "$FORK_DIR/vendor/$v" "$WORKTREE/vendor/$v"
done

cd "$WORKTREE"
say "rebasing $BRANCH onto $UPSTREAM_REMOTE/master ($BEHIND commits) ..."
if ! GIT_EDITOR=true git rebase "$UPSTREAM_REMOTE/master" >/tmp/rebase.log 2>&1; then
  git rebase --abort 2>/dev/null || true
  CONFLICTS=$(grep -c '^CONFLICT' /tmp/rebase.log || true)
  fail "rebase hit conflicts ($CONFLICTS) — needs manual/agent resolution. See /tmp/rebase.log" 3
fi
say "rebase clean. building (make all) ..."
make all >/tmp/build.log 2>&1 || fail "build failed after rebase — see /tmp/build.log" 4

say "running unit suite (make test) ..."
make test >/tmp/test.log 2>&1 || { tail -3 /tmp/test.log; fail "unit suite failed — see /tmp/test.log" 5; }
TESTLINE=$(grep -E 'Tests: .* pass' /tmp/test.log | tail -1)
say "suite: $TESTLINE"

# ---- Tool-smoke gate: the part `make test` does NOT cover ----
say "tool smokes (the rebase-can-silently-drop-these surfaces) ..."
T=/tmp/rv_smoke; rm -rf "$T"; mkdir -p "$T"

# (a) --emit-rbs writes a non-empty RBS
printf 'class C\n  def add(a, b)\n    a + b\n  end\nend\nputs C.new.add(1, 2)\n' > "$T/r.rb"
./spinel --emit-rbs "$T/r.rb" -o "$T/r.rbs" >/dev/null 2>&1 || fail "tool smoke: --emit-rbs errored (wrapper regression?)" 6
[ -s "$T/r.rbs" ] || fail "tool smoke: --emit-rbs produced no output (wrapper regression?)" 6

# (b) --emit-types writes JSON
./spinel --emit-types "$T/r.rb" -o "$T/r.json" >/dev/null 2>&1 && [ -s "$T/r.json" ] \
  || fail "tool smoke: --emit-types produced no JSON (wrapper regression?)" 6

# (c) --debug build runs and Exception#backtrace names a frame
printf 'def k\n  raise "x"\nend\nbegin\n  k\nrescue => e\n  e.backtrace.each { |l| puts l }\nend\n' > "$T/b.rb"
./spinel --debug "$T/b.rb" -o "$T/b" >/dev/null 2>&1 || fail "tool smoke: --debug build failed (wrapper regression?)" 6
"$T/b" 2>/dev/null | grep -q "in \`k'" || fail "tool smoke: native backtrace didn't name frame 'k' (backtrace regression?)" 6

# (d) value-bisect still localizes the canonical scalar divergence
if [ -x "$SPINEL_DEV/tools/value-bisect/bisect.sh" ]; then
  V=$(SPINEL_DIR="$WORKTREE" sh "$SPINEL_DEV/tools/value-bisect/bisect.sh" --json \
        "$SPINEL_DEV/tools/value-bisect/examples/overflow.rb" 2>/dev/null | tail -1)
  echo "$V" | grep -q '"verdict": "diverge"' || fail "tool smoke: value-bisect didn't localize overflow.rb (harness regression?)" 6
  say "value-bisect: $V"
fi
say "tool smokes PASS."

NEWTIP=$(git rev-parse --short HEAD)
say "GREEN: rebased $BRANCH -> $NEWTIP on master (+$BEHIND), $TESTLINE, tool smokes ok."
if [ "$DO_PUSH" -eq 1 ]; then
  say "force-pushing to $PUSH_REMOTE/$BRANCH ..."
  git push --force-with-lease "$PUSH_REMOTE" "HEAD:$BRANCH"
  say "pushed. backup ref $BACKUP retained in $FORK_DIR."
else
  say "verify-only. To publish:  git -C $WORKTREE push --force-with-lease $PUSH_REMOTE HEAD:$BRANCH"
fi
