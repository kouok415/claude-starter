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
   - Task finished: write its journal entry with the scoreboard — profile,
     size, milestones total, gate_failures = **count of `FAIL` rows in
     `tasks/<slug>/gatelog`** (never from memory; note any `INTEGRITY`
     rows separately in the journal — each is a caught dark-gate state),
     highest escalation rung used, human interventions, duration_min =
     minutes between the first and last commit on `task/<slug>` (git
     timestamps, not memory), and harness = the ref after
     `claude-starter@` on the LAST line of `.claude/.starter-version`
     (`unknown` if that file is missing) — and append one row to
     `.ai_context/scoreboard.csv` (create it with header
     `date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness`
     if absent). `outcome` is exactly one of `success` | `failed` |
     `abandoned`. Then delete `CURRENT` (keep the task directory).
   - Task abandoned (dropped or superseded): same journal entry + scoreboard
     row with `outcome=abandoned` — failed and dropped runs must reach the
     dataset too, or the A/B data is survivor-biased. Then delete `CURRENT`
     (keep the directory).
   - Task unfinished: leave `CURRENT` in place; make sure `state.md`'s
     Now/Next points at the `[in_progress]` milestone so the next session
     resumes cold from the checkpoint. If `lessons.md` or `brief.md`
     exceeds 4 KB, distill now: one line per entry, narratives to
     `journal/` — the next session inherits these files whole.

5. **CLAUDE.md drift** — did this session change commands, stack, or how
   the project is verified? Update CLAUDE.md's Commands/Verify to match
   reality before they mislead the next session.

6. Apply the writing rules as you go: S1 (only what the next session needs),
   S3 (date every aging claim), S4 (no fluff — the why, not "went well"),
   H1 (no secrets), H2 (don't duplicate what code/git already records).

7. If the project uses git, offer to commit the memory changes as
   `chore(context): wrap <topic>`.

Finish by replying with a one-line summary of what was persisted and where.
