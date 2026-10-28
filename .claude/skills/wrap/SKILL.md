---
name: wrap
description: End-of-session memory writeback for .ai_context — update state.md, append ADRs for decisions made, journal notable events. Use when finishing a work session, before a long pause, after a task slice or task closes, or when the user says "wrap up", "收尾", "handoff", or "/wrap".
---

# Session wrap — write project memory back

Steps, against `.ai_context/` (INDEX.md §Writing protocol governs each
file):

1. **`state.md`** — rewrite to reflect *now* only; `Last updated:` = today:
   - **Now**: what is actively in progress after this session.
   - **Next steps**: the first 1–3 concrete actions for the next session —
     the resumability contract: any session can die; the next starts here.
   - **Open questions**: decisions blocked on the human.
   - Re-run every command state.md cites as evidence; write its output
     now, not the remembered one. Archive resolved sections to
     `journal/YYYY-MM-DD-<topic>.md`. Keep under 5 KB (S7).

2. **`decisions.md`** — if this session decided something that shapes the
   project (dependency, architecture, an approach rejected after real
   investigation), append an ADR per the template at the top of the file,
   numbered last + 1. Nothing decided → no ADR; don't manufacture.

3. **`journal/`** — notable event this session? ONE dated entry
   `YYYY-MM-DD-<topic>.md`, first line a one-sentence summary; skip
   routine sessions. A lesson that passes the counterfactual test →
   `reference.md` **§Lessons**.

4. **Active `/task`** — if `.ai_context/tasks/CURRENT` exists, STOP: read
   `reference.md` **§Task close-out** and follow it; append the output of
   `harness-report.sh --row` to `scoreboard-v4.csv` — never type a row.

5. **Harness friction / defect candidates** — a starter mechanism
   malfunctioned or blocked wrongly, or the report lists defect
   candidates? `reference.md` **§Friction rows** / **§Defects**.

6. **CLAUDE.md drift** — commands, stack, or verify changed this session?
   Update Commands/Verify before they mislead the next session.

7. Writing rules throughout: S1 (only what the next session needs), S3
   (date aging claims), S4 (no fluff), H1 (no secrets), H2 (don't
   duplicate code/git).

8. Using git? Commit what this wrap wrote, explicit paths only, as
   `chore(context): wrap <topic>`.

Finish with a one-line summary of what was persisted and where.
