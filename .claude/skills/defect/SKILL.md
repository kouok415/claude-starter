---
name: defect
description: Record a defect found after work was marked done — by the user, in production, or in a post-close review — into .ai_context/defects.csv. Use when the user says /defect.
disable-model-invocation: true
argument-hint: "<what broke, where you saw it>"
---

# /defect — count what escaped "done"

1. Restate the defect in one line from what the user saw (command, screen,
   row, order) — their words, not a diagnosis.
2. Find the work it belongs to: `git log --format='%h %s' -- <files
   involved>`; commits named `S<n>` on `task/<slug>` give the slug and
   slice (whole branch: `final`). Not from a `/task` → slug and slice `-`.
3. `finder`: `human` (the user saw it), `production` or `post-close-review`.
   Checker and Codex findings are recorded automatically from their
   records; fix commits come from the candidates /wrap lists.
4. `severity`: `blocker` (wrong money or data, security, user blocked) ·
   `major` (wrong result, workaround exists) · `minor`.
5. Record: `bash scripts/harness-report.sh --defect <slug|-> <S<n>|final|->
   <finder> <severity> "<summary>" <ref|-> [--n N] [--fixed-in SHA]`
   — ref is a journal file, issue or commit; the script derives the phase
   (pre-done, post-done, post-close) and refuses a slug without a card, a
   slice not on it, or a ref already recorded.
   Never edit `defects.csv` by hand.
6. Show the row it printed. Then fix it through `/debug` — the defect row
   stays even when the fix is quick.
7. A row recorded by mistake (not a defect, wrong task) is retracted, never
   edited: `bash scripts/harness-report.sh --defect-retract <date> <slug>
   <slice> <ref> --reason "<why>"` — the row's own date, slug, slice and
   ref; both rows then count nowhere.
