# Maintenance — keep the fork rebased on upstream

`matz/spinel` master moves ~60 commits/day. The fork's PR branch (`feat/typing`)
must be rebased onto it regularly or it drifts toward unmergeable. This routine
automates the *detection + verification*; conflicts and tool evolution still need
a human/agent (by design — see below).

## `rebase-and-verify.sh`

Rebases `feat/typing` onto `origin/master` **in a throwaway detached worktree**
(never touches your main checkout, which may be on a frozen/detached engine),
then gates on:

1. clean rebase (no conflicts),
2. `make all` (build),
3. `make test` (unit suite),
4. **tool smokes** — `--emit-rbs`, `--emit-types`, `--debug` native backtrace,
   and `value-bisect` localizing `overflow.rb`.

The tool smokes exist because a rebase can apply "cleanly" yet silently drop
wrapper glue: we once lost `--emit-rbs`/`--debug` from the `spinel` wrapper in a
rebase while `make test` stayed green (the tools aren't in the unit suite). The
smokes catch that class of regression.

```
sh rebase-and-verify.sh          # verify only; prints the push command on green
sh rebase-and-verify.sh --push   # force-push (--force-with-lease) to ori on all-green
```

Exit codes: `0` up-to-date or green · `3` conflict (needs resolution) · `4` build
failed · `5` unit suite failed · `6` tool smoke failed. A backup ref
(`backup/rebase-<sha>`) is written before each attempt.

Env: `FORK_DIR` (~/sites/spinel), `BRANCH` (feat/typing), `UPSTREAM_REMOTE`
(origin = matz/spinel), `PUSH_REMOTE` (ori), `WORKTREE`, `SPINEL_DEV`.

## Scheduled (gx10)

A user crontab runs it daily (~08:47 local), **verify-only**, logging to
`/srv/data/scratch/spinel-rebase.log`:

```
47 8 * * * .../rebase-and-verify.sh >> /srv/data/scratch/spinel-rebase.log 2>&1
```

Verify-only is the safe default: the daily run is an **early-warning detector**
(did master drift in a way that breaks our build/tests/tools?). It does *not*
auto-publish. On a green day it logs the exact push command; flip the cron to
`--push` to auto-publish on all-green.

## When the routine reports a problem (the agentic part)

Exit `3`/`4`/`5`/`6` means a human or a Claude session resolves it — this is where
"evolution of the harness/tools" happens (resolve the rebase conflict, fix any
tool the upstream churn broke, re-run, push).

**Recurring conflict:** the multi-file-source-map commit conflicts in
`spinel_parse.c` most rebases — upstream actively edits the same plain-`require`
resolution region. Resolution is stable: keep our `sp_wrap_included(content, ...)`
call **and** take upstream's statement-level `line_len` (the two are orthogonal —
content wrapping vs. how much source to excise). The Makefile (`triage`/`fast-test`
union) and `lib/sp_runtime.h` (FloatArray/inspect) conflicts are likewise additive.
