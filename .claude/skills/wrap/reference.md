# /wrap reference — task close-out, lessons, defects, friction rows

Loaded on demand from the wrap skill (steps 3–5) so routine wraps don't pay
for it. Read the section your situation names.

## Task close-out (`.ai_context/tasks/CURRENT` exists)

- **Task finished** (the card has a `Closed:` line):
  1. `bash scripts/evidence.sh status` — the close must still be fresh.
     Stale (content changed after close) → the task is NOT finished: rerun
     `bash scripts/evidence.sh close`, or treat it as unfinished.
  2. `bash scripts/harness-report.sh --row <slug>` prints the scoreboard
     row from the card and `tasks/<slug>/donelog` (`interventions` stays
     `-`), preceded by the header
     `date,slug,slices,blocks,stuck,codex_runs,interventions,duration_min,outcome,harness`
     when `.ai_context/scoreboard-v4.csv` is missing or empty. Append its
     output verbatim to `scoreboard-v4.csv`; the v3 `scoreboard.csv` stays
     as it is (history). Never type or edit a field.
  3. Journal entry `journal/YYYY-MM-DD-<slug>.md`: one-sentence summary,
     the row, the outside-check verdict (quoted), open `[ASSUMED]` calls,
     and the "what this does not prove" block `close` printed.
  4. Promote lessons from `notes.md` §Tried (§Lessons below).
  5. Run `bash scripts/harness-report.sh`; put its summary in the reply.
  6. Delete `CURRENT` (keep the task directory).
- **Task abandoned or failed** (no `Closed:`, and the work stops here):
  ask the human which — the only outcome you ask for. Then steps 2–6 with
  `bash scripts/harness-report.sh --row <slug> --outcome failed|abandoned`
  in step 2. Failed and dropped runs must reach the dataset too, or it is
  survivor-biased.
- **Task unfinished:** leave `CURRENT`; state.md Now/Next names the `[~]`
  slice and its last donelog row so the next session resumes cold. Card
  over 4 KB or `notes.md` over 16 KB → distill now: one line per entry,
  narratives to `journal/`.

## Lessons

Promote, don't trim. Candidates: `notes.md` §Tried lines and this
session's discoveries. Counterfactual test: would someone reading the final
code and tests still repeat the mistake or redo the hunt? No → drop it.
Yes → one lesson per file, `.ai_context/knowledge/lessons/<area>-<symptom>.md`:

    # <symptom, in the words you would grep for>
    Applies when: <area, tool, condition>
    What didn't work: <approach> — <why>
    What works: <fix or check> — <evidence: command, commit or journal>
    Last confirmed: YYYY-MM-DD

First `grep -ril '<symptom words>' .ai_context/knowledge/lessons/`: the
same problem already has a file → update it (evidence, date), never add a
twin. No secrets or hosts (H1).

## Defects

`harness-report.sh` lists defect candidates: fix commits after a task's
close that touch its files. Ask the human about each: a defect of the
closed work → run the `--defect … fix-commit …` line the report printed,
severity and summary per `.claude/skills/defect/SKILL.md`; not one (or
already recorded) → `bash scripts/harness-report.sh --defect-dismiss <sha>`.

## Friction rows

One row per real mechanism incident (hooks, `/task` machinery, `/setup`,
`/wrap`, sync) appended to `.ai_context/friction.csv`, created with header
`date,harness,area,severity,summary,ref` if absent: `area` is one of
`setup|task|wrap|hooks|sync|skills|other`, `severity` one of
`blocker|friction|papercut`, `summary` a single comma-free clause, `ref` a
journal file / `tasks/<slug>/donelog` / `-`, `harness` the ref after
`claude-starter@` on the last line of `.claude/.starter-version`. Never
duplicate BLOCK, STUCK, ESCALATE or GATE-ERROR events — the donelog records
those; the report joins them.
