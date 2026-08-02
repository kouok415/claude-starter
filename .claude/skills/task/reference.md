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

`mixed` — where both tiers are available: pin `model: opus` in
`.claude/agents/executor.md` and run the session on a fable-class model.
Judgment-dense, low-token stages (plan synthesis, critique, reframing,
final panel) get the strong model; token-heavy execution runs cheaper. Use
`opus-tier` milestone sizing (the executor does the work); planner fan-out
may drop to 1 + critic.

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
