---
name: wrap
description: End-of-session memory writeback for .ai_context — update state.md, append ADRs for decisions made, journal notable events. Use when finishing a work session, before a long pause, after completing a milestone, or when the user says "wrap up", "收尾", "handoff", or "/wrap".
---

# Session wrap — write project memory back

Work through these steps against `.ai_context/` (read each file's HTML-comment
preamble before writing to it):

1. **`state.md`** — rewrite so it reflects *now* only:
   - Set `Last updated:` to today's date.
   - **Now**: what is actively in progress after this session.
   - **Next steps**: the first 1–3 concrete actions the next session should
     take. This is the resumability contract — any session can die; the next
     one starts here.
   - **Open questions**: decisions blocked on the human.
   - Remove sections that are no longer true. If a resolved section is worth
     preserving, move it to `journal/YYYY-MM-DD-<topic>.md` first.
   - Keep the file under 5 KB (S7).

2. **`decisions.md`** — if this session made a decision that shapes the
   project (dependency choice, architecture, an approach rejected after real
   investigation), append an ADR using the template at the top of the file.
   Number it last + 1. Skip if nothing was decided — don't manufacture ADRs.

3. **`journal/`** — if this session contained a notable event (debugging
   hunt, incident, analysis with findings, debate), write ONE dated entry
   `YYYY-MM-DD-<topic>.md` whose first line is a one-sentence summary.
   Skip routine sessions.

4. **Active `/task`** — if `.ai_context/tasks/CURRENT` exists:
   - Task finished: write its journal entry with the scoreboard (profile,
     milestones total, gate failures, highest escalation rung used, human
     interventions), then delete `CURRENT` (keep the task directory).
   - Task unfinished: leave `CURRENT` in place; make sure `state.md`'s
     Now/Next points at the `[in_progress]` milestone so the next session
     resumes cold from the checkpoint.

5. Apply the writing rules as you go: S1 (only what the next session needs),
   S3 (date every aging claim), S4 (no fluff — the why, not "went well"),
   H1 (no secrets), H2 (don't duplicate what code/git already records).

6. If the project uses git, offer to commit the memory changes as
   `chore(context): wrap <topic>`.

Finish by replying with a one-line summary of what was persisted and where.
