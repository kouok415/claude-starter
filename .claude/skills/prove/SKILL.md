---
name: prove
description: Done, fixed, passing, shipped, works — check the claim before saying it. Use before claiming work is done or fixed, before accepting a subagent's "done", and before a claim goes into state.md, a journal entry, a commit message, a PR or a report. Runs the falsifying check fresh and labels each requirement VERIFIED / NOT VERIFIED / INCONCLUSIVE with an evidence level.
---

# /prove — a claim is not done until a run could have refuted it

1. Write the claim, and the run that would show it false. Run it fresh —
   or, inside a `/task`, read this tree's record (`bash scripts/evidence.sh
   show <lane>`) — and quote the output. A subagent's "done" is a claim:
   read its diff and rerun.
2. Behavior, not text. `bash -n`, `--help`, `--list-*`, grepping strings
   you wrote, or a selftest on your own fixture prove the source exists,
   not that it works. Run the product the way its user does, real input.
3. Watch it go red — revert the change or feed bad input — and keep the
   red output. If no state of the world can fail it, it is not a check.
   The work count must be > 0 (rows, trades, files, requests).
4. Expected values come from the spec, an outside reference or
   hand-worked literals — never from the code under test or a mock.
5. Out-of-repo deliverables (VM, install, deploy, broker, live rows):
   judge the observed state, never a commit. A stand-in (container for a
   VM, paper for live, a sample for full data) lists the steps it skipped;
   those stay NOT VERIFIED.
6. A failed check changes only in its own commit, with a reason naming
   what it no longer covers. Thresholds change only on a human ruling.
   Never narrow scope to get green.
7. Claims about cause, provenance or generality: cite the run or
   file:line; N=1 says "one case"; ask whether the opposite wording would
   fit the same numbers. Numbers → `/number-check`.

## Output

One line per requirement, unindented, then what was not proven:

    VERIFIED (L4|L5) <requirement> — `<command>` → "<quoted output>" (<record id or log path>)
    NOT VERIFIED (L<n>) <requirement> — <what ran and what happened, or what never ran>
    INCONCLUSIVE (L<n>) <requirement> — <what is missing>
    Not proven: <stale or missing lanes, lines never executed, skips>

Levels: 1 said · 2 file:line · 3 failure path walked · 4 code ran ·
5 reproduced in the product. A user-facing claim needs 4–5. Any line not
VERIFIED → the work is "partly done", and you say so in those words.

<!-- Source: adapted from Superpowers v7.0.1 (skills/verification-before-completion/SKILL.md, skills/test-driven-development/SKILL.md); Compound Engineering v3.31.1 (skills/ce-work/references/implementation-loop.md, skills/ce-code-review/references/personas/adversarial-reviewer.md); pstack v0.15.31 (skills/blast-radius/SKILL.md). MIT — see NOTICE. -->
