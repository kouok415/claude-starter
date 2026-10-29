# /task reference — formats and recipes

## Resume

Last donelog row for the `[~]` slice → where to re-enter:

| Last row | Re-enter |
|---|---|
| START, no SPAWN executor | §4.2 spawn the executor |
| SPAWN executor, no RETURN | still listed in background tasks → wait; else §4.2 |
| RETURN executor | slow lanes not yet RUN → run them; then §4.3 |
| SPAWN checker, no CHECK | still listed in background tasks → wait; else §4.3 |
| RUN fail / CHECK fail | §5 Stuck, then §4.2 |
| CHECK pass (`codex: yes`, pair on, no CODEX pass) | §4.5 |
| CHECK pass / CODEX pass or WAIVE | §4.7 `evidence.sh done` |
| ESCALATE | report (§Escalation) and wait for the human |

## Notes

`notes.md`, one line per entry, dated; H1 applies (no secrets, no hosts):

    ## Rulings   — the human's words verbatim; never paraphrased
    ## Measured  — fact — `command` that showed it
    ## Tried     — S<n>: approach — why it failed — premise it rested on
    ## Calls     — S<n> [own|ASSUMED] call — why — risk if wrong
    ## S<n>      — constraint found later that slice S<n> must honor
    ## <topic>   — constraints, interfaces, edge cases (`notes: §<topic>`)

Executor and checker read only the sections the slice names plus `## S<n>`.
Over 16 KB: move narratives to `journal/`, keep the facts.

## Lanes

    # name | paths | min_secs | expect (; separated, all must match) | canary | cmd
    @pair codex
    @verify-paths tests/ probes/
    smoke | . | 4 | ^verify: [1-9][0-9]* passed, 0 failed$ | <cmd that must fail> | bash scripts/verify.sh

1. A lane runs the product the way its user does. `trust` refuses static
   commands (`bash -n`, `--help`, `--list-*`, shellcheck, py_compile,
   grep/test/ls only), `min_secs` 0 and an empty `expect`. No `|` in a
   cmd or canary: pipes and multi-step commands go in a wrapper script.
2. `expect` matches the run's own verdict line, including a nonzero work
   count (rows, trades, files, requests) — never a bare exit 0.
3. `canary` runs the check against a known-bad input or a reverted line
   and must fail; `skip:<reason>` needs a separate human yes.
4. Idempotent; no push, deploy, paid call or order. A run leaves no untracked,
   unignored file inside its paths (gitignore caches), or it is voided.
5. `smoke` (minutes; paths `.`, so doc and config edits are proven too) is
   also the `verify` skill Claude Code runs before each commit; slow lanes
   (VM, full backtest) name their own paths. Every change in a task must lie
   inside a cited lane's paths; after /wrap clears CURRENT nothing is checked.
6. `@ext <lane> <cmd>` prints the external commit a lane ran against (a fork
   elsewhere); close compares it. A changed lane line, file its cmd/canary
   names, `@` line or `.claude/gitleaks.toml` → the human re-runs `trust`.

Recipes (cmd prints a verdict line with a count; expect matches it):
- report/analysis: a wrapper that re-derives each cited number and source,
  printing `checked=<n> mismatched=0`; canary: feed it one broken number.
- data pipeline: fixed fixture window; print rows/errors/NaN counts.
- desktop: drive it under Xvfb (Playwright for Electron); a blank frame fails.
- VM / package: revert snapshot, install in the guest, smoke inside,
  `dpkg -s` reports installed, purge, check leftovers.
- backtest: pinned data hash + seed, golden metrics, a look-ahead canary
  (shifted future data must change nothing) — see `/backtest-check`.

## Approval

At most 25 lines to the human — a translation, never the card pasted:
1. What will exist when this is done, in problem language.
2. One line per slice: "after S2: run X, you will see Y". Approving the
   card approves these promises.
3. Cost: hours, lines, lanes, run time. Pair on → Codex runs: approval covers
   2(m+1)+1 for m `codex: yes` slices (each and final once, a retry each,
   one rebuttal; 2m+5 counting the card check and its retry) — state it.
   Past it `task-pair.sh` exits 3 → ask; on a yes, `--over-estimate`.
4. Considered, not built — one line each.
5. Veto contract: each slice lands as its own commits (`S<n>` in the
   message), so "S<n> is wrong, redo via Z" reverts one slice, not the task.

## Spawn

Executor — nothing beyond these lines:

    Slice: <slice line verbatim>
    Card: .ai_context/tasks/<slug>/card.md ; notes: §<a>, §S<n>
    Start: <sha> ; lanes you run: <fast> ; lanes I run: <slow>
    Retry: <failing output verbatim> ; premise: <one line> — test it first

Checker — never the executor's report or your opinion:

    Check S<n>. Card: <path>. Start: <sha>. Lanes: <names>. Notes: §<a>, §S<n>.
    Check card. Card: <path>.                        (pair off, before approval)
    Check final. Card: <path>. Base: <card base>.    (pair off, at close)

## Escalation

    S<n> stopped after <k> attempts.
    Tried: <k>) <approach> — <why it failed, quoted output> — premise: <...>
    Shared premise: <premise> → tested by <command> → <result>
    Diagnosis: <slice cut | missing constraint | environment>, one evidence line each
    Why every attempt was doomed under the old framing: <...>
    Next: <re-cut slices (card change → re-approval) | access or facts needed>

Never "try harder" or a variant of an approach already in §Tried.

## Unattended

`/goal` judges the transcript, never the product: quote printed output, cap it.
- good: "`evidence.sh status --line` shows S4 `[x]`, or stop after 30 turns"
- bad: "the app works", "pick the best design" — direction stays human.

## Close report

1. Outside check: the owner's verdict quoted, or "pending: <who runs what>".
2. Each `[own]`/`[ASSUMED]` call: call / why / risk if wrong / what
   changes if vetoed — the reply alone must be enough to rule on it.
3. Not proven: the "what this does not prove" block `close` printed.
4. The `Closed:` line.
