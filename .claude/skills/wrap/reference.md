# /wrap reference — task close-out + friction rows

Loaded on demand from the wrap skill (step 4/5 pointers) so routine wraps
don't pay for it. Two sections; read the one your situation names.

## Task close-out (`.ai_context/tasks/CURRENT` exists)

- **Task finished:** FIRST run `bash .claude/hooks/stop-gate.sh --sweep` —
  it closes zero-stop gaps mechanically (verifies the final `[done]`
  milestone if unproven, records `UNARMED` rows for earlier gates that
  never fired); a FAIL means the task is NOT finished. Then write the
  task's journal entry with the scoreboard numbers — profile, size,
  milestones total, gate_failures = **count of `FAIL` rows in
  `tasks/<slug>/gatelog`** (never from memory; note any `INTEGRITY` or
  `UNARMED` rows separately — INTEGRITY is a caught dark-gate state,
  UNARMED a gate that never fired), highest escalation rung used, human
  interventions, duration_min = minutes between the first and last commit
  on `task/<slug>` (git timestamps, not memory), and harness = the ref
  after `claude-starter@` on the LAST line of `.claude/.starter-version`
  (`unknown` if that file is missing). Append one row to
  `.ai_context/scoreboard.csv`, creating it with header
  `date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness`
  if absent. `outcome` is exactly one of `success` | `failed` |
  `abandoned`. After the row lands, run `bash scripts/harness-report.sh`
  and include its summary in your wrap reply. Then delete `CURRENT` (keep
  the task directory).
- **Task abandoned** (dropped or superseded): run the `--sweep` here too
  (it records `UNARMED` evidence for whatever was claimed done), then the
  same journal entry + scoreboard row with `outcome=abandoned` — failed
  and dropped runs must reach the dataset too, or the A/B data is
  survivor-biased. Then delete `CURRENT` (keep the directory).
- **Task unfinished:** leave `CURRENT` in place; make sure `state.md`'s
  Now/Next points at the `[in_progress]` milestone so the next session
  resumes cold from the checkpoint. If `lessons.md` or `brief.md` exceeds
  4 KB, distill now: one line per entry, narratives to `journal/` — the
  next session inherits these files whole.

## Friction rows

One row per real mechanism incident (hooks, `/task` machinery, `/setup`,
`/wrap`, sync) appended to `.ai_context/friction.csv`, created with header
`date,harness,area,severity,summary,ref` if absent: `area` is one of
`setup|task|wrap|hooks|sync|skills|other`, `severity` one of
`blocker|friction|papercut`, `summary` a single comma-free clause, `ref` a
journal file / `tasks/<slug>/gatelog` / `-`, `harness` the same stamp ref
as the scoreboard column. Never duplicate `INTEGRITY` events — the gatelog
records those; the report joins them.
