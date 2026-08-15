# /task reference — protocols and tables

Loaded on demand: the skill points here from the rungs/knobs that need it.
Nothing in this file is injected by default — that's the point.

## Rung-3 worktree protocol

Subagents share your working directory, so isolation must be explicit:

1. From the task branch: `git worktree add ../<repo>-r3-<n> -b
   task/<slug>-r3-<n>` for n = 1..3.
2. Each executor declares its strategy in ONE sentence before running —
   reject non-distinct strategies before they spend tokens.
3. Spawn each executor WITH its worktree path; all of its file operations
   and its verify run happen inside that path only. Never let rung-3
   executors loose in the shared tree.
4. `verifier` runs the milestone verify in each worktree and picks the
   winner (tie-break: smallest diff).
5. Merge the winning branch into `task/<slug>` (squash is fine), then
   `git worktree remove` all three and delete the `-r3-*` branches.

## Profiles — knob table

| Knob | `opus-tier` | `fable-tier` |
|---|---|---|
| Milestone size (per fresh executor context) | ≤15 tool calls | 30–50 tool calls |
| Planner fan-out (M / L) | 1 + critic / 3 lenses + critic | 1 + critic / 1 + critic |
| Executor spawn prompt | milestone + a suggested approach | milestone + goal + constraints only — no prescribed steps |
| Drift-check cadence (L tasks) | every 3rd milestone | every 5th, or after `risk: high` only |
| Escalation ladder | 1 → 2 → 3 → 4 | 1 → 2 → 4 |

`mixed` — where both tiers are available: `bash scripts/task-profile.sh
mixed` pins `model: opus` on the executor; run the session on a
fable-class model. Judgment-dense, low-token stages (plan synthesis,
critique, reframing, final panel) get the strong model; token-heavy
execution runs cheaper. Use `opus-tier` milestone sizing (the executor
does the work); planner fan-out may drop to 1 + critic.

`mixed-judge` — the fully pinned split: `bash scripts/task-profile.sh
mixed-judge` writes every agent's model explicitly — scout, planner,
plan-critic, reframer, final-verifier → `fable`; executor, verifier →
`opus` — so the agent layer no longer depends on the session model (run
the session on either tier; that changes only the orchestration price).
Knobs: `opus-tier` milestone sizing, 1 + critic fan-out, `fable-tier`
drift cadence, opus escalation ladder (1 → 2 → 3 → 4).

Selection is per task, applied at intake by `task-profile.sh apply`:
`/task --profile=mixed-judge ...` pins; a flagless `/task` resets to
inherit — **except on resume**, where the active task's plan.md header
wins (`apply` resolves: explicit flag > active header > inherit, and
warns when a flag contradicts the header — that is a mid-task switch,
protocol below). Inspect anytime with `task-profile.sh status`; reset
with `task-profile.sh inherit` (restores frontmatter byte-identical to
stock, so `--update-stock` syncs work again). While pinned, agent files
count as customized — sync lists template updates to them as hand-merge
suggestions; quick path: `inherit` → sync → re-apply. Pins require
`CLAUDE_CODE_SUBAGENT_MODEL` to be unset — it overrides every
frontmatter pin (the script warns if it is set).

**Mid-task model switches are never silent.** The plan's granularity was
cut for the recorded profile. If the session model changes mid-task: keep
completed milestones, spawn `planner` to re-cut only the remaining ones
under the new profile, update the `plan.md` header, note the switch in
`lessons.md`.

## Non-code verify patterns

Research / analysis milestones gate on the artifact, not a test suite —
same executability bar, different target:

    - verify: `test -s reports/h2-outlook.md`
    - verify: `test "$(grep -c '^## ' reports/x.md)" -ge 6`
    - verify: `python scripts/check_csv.py data/out.csv`
    - verify: `test "$(wc -l < data/prices.csv)" -ge 250`
    - verify: `jq -e '.results | length >= 10' out/scan.json`

Only when done-ness truly cannot be expressed as a command, let a
verifier-agent spot-check stand in as the gate — try the artifact check
first.

## brief.md format (what the scout writes)

    # Brief: <slug>
    ## Map            — path → one-line role, task-relevant areas only
    ## Interfaces     — signatures/contracts the task will touch
    ## Commands       — build / test / lint / run, verified once
    ## Conventions    — naming, layout, patterns to match
    ## Gotchas        — traps a fresh context would step into
    ## Corrections    — dated one-liners appended by later contexts

Cap: ≤150 lines / 4 KB. Distill, don't dump — every line pays rent in
every later context. Claims not directly observed are tagged
`[UNVERIFIED]`.

## Kickoff brief (before M1)

≤30 lines of prose to the human — a translation, never plan.md pasted:

1. What will exist when this is done, in problem language.
2. One line per milestone — its `- demo:` promise ("after M2: run X,
   you will see Y"). Approving the plan = approving these promises.
3. The veto contract, stated: each milestone lands as one commit, so
   "M\<n\> is wrong, redo via Z" rolls back one milestone, not the task —
   vetoes stay cheap until merge; the human never has to catch things
   live.

Attended runs pause here for a reply; `--auto` posts it and proceeds.

## Checkpoints & milestone boundaries (v3.14)

A milestone whose section carries `- checkpoint: human` is a human gate:
its verify PASS holds the run (PAUSED row + repeating systemMessage)
until the human signs off with `touch .ai_context/tasks/<slug>/ack-<id>`
— their own shell, or approving the bash-guard confirmation, IS the
sign-off. Advancing past an un-acked checkpoint is an integrity block.
Mark checkpoints at plan approval (deploys, spend, outward-facing
steps); they are the mechanical form of "wait for me here".

Non-checkpoint milestones: a PASS with `[pending]` milestones left gets
ONE continuation prompt per session — answer it by continuing (flip
statuses, spawn the executor) or by pausing EXPLICITLY (state why,
restate any unanswered human question, finish). The second stop passes
and records a PAUSED row. A fresh executor spawn also buys one quiet
WAITING stop — the completion notification is the wake signal; do not
babysit it with wait-loops.

## STATUS.md — the live view

`tasks/<slug>/STATUS.md` answers "where are we and what is happening" at
a glance, any time. Machine region (position, mermaid map, demo promises,
change footprint, last verify output, the `[ASSUMED]` ledger) is
regenerated by `scripts/task-status.sh` — the stop-gate re-renders it
after every real verify run, session-start on every resume. The model
owns only §Architecture below the end marker: written at kickoff, kept
current as milestones land. A VIEW, not memory — gitignored, rebuildable,
never read back as truth (plan/spec/gatelog stay the sources).
