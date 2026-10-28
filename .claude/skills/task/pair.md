# /task pair — the Codex judge over herdr

Read this when pair is on for the active task. Claude builds; a Codex
session in a sibling herdr pane checks, on the user's own Codex default.
It reads one frozen packet per run and writes one result file; it never
edits the tree, marks a slice or writes memory. Every run that settles
becomes an evidence record (`evidence.sh codex`); only `evidence.sh done`
/ `close` decide what counts. Design: workshop ADR-028, ADR-030, ADR-039.

## When pair is on

- Project default: `@pair codex` in `.claude/done-lanes` (bound by
  `evidence.sh trust`: changing any `@` line needs a re-trust). The card
  header `pair: codex|off` can raise it for one task, never lower it.
- Codex checks three points: the card before any code (`check card`),
  each `codex: yes` slice before `evidence.sh done` (`check slice`), the
  whole branch before `evidence.sh close` (`check final`). `done`/`close`
  refuse without an approving record for the content, or a waiver.
- Tag `codex: yes` on every slice touching money, secrets, credentials,
  installation or deployment.

## Requirements — the script refuses (exit 3) without them

1. Inside herdr (`HERDR_ENV=1`, `herdr` on PATH); the repo trusted in
   `~/.codex/config.toml`; `.claude/evidence/` gitignored.
2. Codex must read CLAUDE.md: `AGENTS.override.md` and `AGENTS.md` each
   identical to it (copy or symlink) or absent. `project_doc_max_bytes` is
   sized to CLAUDE.md; if CLAUDE.md outgrows a running judge, or herdr
   shows it in another repo or pane than its record, close that pane and
   run `ensure`.
3. With `.codex/hooks.json` present, only a judge this script started
   (hooks off) is used — a copied Stop hook would gate inside the judge.

## Commands — `scripts/task-pair.sh`

| Command | Does |
|---|---|
| `ensure` | find `judge-<repo hash>-<slug>` or start Codex in a new pane: `-s workspace-write -c features.hooks=false -c project_doc_fallback_filenames=["CLAUDE.md"] -c project_doc_max_bytes=<n>`, never a model or effort |
| `check card` | write the card packet and `send` it |
| `check slice S<n> [--since REF]` | REF defaults to — and must be — the HEAD `evidence.sh start S<n>` recorded |
| `check final [--since REF] [--rebuttal FILE]` | REF defaults to — and must be — the card's `base:` |
| `packet <as check>` | write the packet only; print its path |
| `send <packet>` · `wait <seq>` | run one packet · re-attach to a run in flight, or retry its record |
| `digest` | the card digest a card check binds to (status marks excluded) |

Exit: 0 completed and recorded (the verdict is in the result, never in the
exit code) · 2 usage · 3 refused (requirements, quota, a stale packet, a
unit not on the card, a re-ask of failed content) · 4 the judge needs you
in its pane (a dialog, a `/new` that did not take; blocked mid-run: answer
it, then `wait <seq>` — nothing is recorded meanwhile) · 5 in flight or
herdr's wait timed out — `wait <seq>` · 6 no usable result (`no_result`,
`bad_header:<key>|counts`, `base_mismatch`, `scratch_in_mailbox`,
`tree_changed`, `judge_run_failed|blocked`), the record failed, or
`not_started` (never reached the model: not recorded, not counted).

## Running a check

1. Run `check`, `send` and `wait` with `run_in_background: true`. No
   10-minute cap: a run takes minutes to an hour (median ~6 min). You are
   notified when it exits; the Stop gate sees the lock
   (`.claude/evidence/locks/pair-<seq>.lock`) and lets you stop meanwhile.
2. While it runs, change nothing in the tree — no edits, commits or
   `evidence.sh start|done|close`; reading and the Claude checker are fine.
   Any other change voids the run (`tree_changed`). One run at a time.
3. On exit 0 read the result yourself. The summary line echoes its header
   and the record id; the script never says PASS or FAIL.

## Stages

**Card** — after `evidence.sh lint` passes, before the human approves.
The packet carries the card, the notes it cites, CLAUDE.md's Definition
of done and Project rules, and nine checks (the direction question, detail
enough that the executor need not guess, a thin slice 1, ≤5 claims). Put
the direction candidates to the human with the card (`--auto`: decide, tag
`[ASSUMED]`), fix the card, `check card` until it passes, then ask for approval.

**Slice** — each `codex: yes` slice, once its lanes are fresh and its
work is committed (refused otherwise), before `evidence.sh done` (the
Claude checker may run alongside). The packet carries the slice line, the
diff stat since its START head, each lane's record and log tail — never
the executor's summary. The judge re-runs the lanes or says why not,
attacks any check the diff adds, and grades each claim.

**Final** — every slice `[x]` (refused otherwise), branch committed,
before `evidence.sh close`. The packet carries the card, diff stat and
commits since REF, and `evidence.sh status`; one checklist: correctness,
regression, test integrity. One rebuttal round, here only, per content:
after a completed final review, write the disputes (or a Claude checker's
failing findings) to a file outside `pair/`, each with your command and
its output, and run `check final --rebuttal FILE`. Only a completed run
spends the round; a second is refused; what stays open goes to the human.

## Result contract

The judge writes its result once, with apply_patch. The first six lines,
each exactly once:

    run: completed|failed|blocked
    verdict: pass|fail|inconclusive
    base: <the packet's base, verbatim>
    blocker: <n>
    major: <n>
    minor: <n>

Anything else is `bad_header:<key>`; counts unequal to the `<n>. <severity>
— …` finding lines `bad_header:counts`; another base `base_mismatch`. A
record approves only when the run completed, `verdict: pass`, blocker 0,
major 0, and `prov=ok`: the judge's own apply_patch write of this result
is in its Codex transcript, its turn ended normally, and the file still
says what it wrote. Edited afterwards (`mismatch`) or written another way
(`unbound`), a result approves nothing.

## No-verdict rule

Exit 6 or `verdict: inconclusive` is a no-verdict, never a pass. Once: run
the same `check` again (a new packet). Twice on the same unit and content
(`evidence.sh codex` warns `codex no verdict twice`): stop; `done`/`close`
refuse that unit until the human rules — fix the environment, rescope, or
waive: `bash scripts/evidence.sh approve --waive <unit> --reason "<their
words>"` (it asks them; the waiver lapses when the card changes).

## Acting on findings

- blocker / major: fix (in the slice or a repair slice), re-run the
  lanes, `check` again. A pass binds to the content it saw.
- minor: fix or note it in the slice's notes section; never blocks.
- A failed review is never asked again at the same content (`check`
  refuses, exit 3). On a slice, run the finding's reproduction yourself;
  if it does not reproduce, take the command and output to the human.
- **High-stakes findings are the human's.** Security, data loss, real
  money / live orders: never disputed away by you, at any stage — fix it
  or leave it open for the human with your evidence.
- Counts live in the records; `defects.csv` gets Codex blockers/majors.

## Quota

Runs spend the user's Codex quota. Starting /task with pair on covers the
card check and one retry; approving the card covers one run per `codex:
yes` slice, the final run, one retry per unit and the rebuttal (card 2,
slice 2, final 3), counted from this task's Codex records plus runs not
yet recorded. Past that, or a slice/final run before approval, `check`
refuses (exit 3): ask the human; on a yes re-run with `--over-estimate`
(its prompt asks them too). `--auto`: stop at the report.

## Files

- `.ai_context/tasks/<slug>/pair/` (Edit-denied; Bash writes ask):
  packets `NNN-card.md`, `NNN-slice-S<n>.md`, `NNN-final[-rebuttal].md`,
  frozen once sent; `NNN-….result.md`, kept even when voided; `runlog`
  (`ts seq event stage unit base digest model tokens rollout detail`,
  UTC); `*.screen.txt` when a run did not complete. Paths under `$HOME`
  are `~/…`; a screen or result the secret scan flags moves to
  `.claude/evidence/logs/`, leaving a stub.
- `.claude/evidence/pair/<slug>/`: `judge` (its record), `fp-<seq>` (in
  flight), `parked-<seq>` (blocked), `unrecorded-<seq>` (`wait <seq>`
  retries the record; it blocks no new check), `not_started`.
- Scratch: `/tmp/pair-<repo hash>-<slug>/<seq>/`; anything new in `pair/`
  besides the result voids the run (`scratch_in_mailbox`).

## Operator notes

- Every packet gets a fresh thread (`/new`, seen to take effect): the
  judge's memory of earlier stages is anchoring, not evidence.
- Keys go only to an idle judge, for a dialog at the bottom of its screen:
  `esc` for the rate-limit nudge and the update notice ("esc skip"; enter
  would run the installer), enter for "Use current Git worktree" after
  `/new`. Any other dialog: exit 4. Packets go only into an empty prompt.
- `workspace-write` writes the repo and `/tmp`, has no network and blocks
  loopback sockets; what that stops is INCONCLUSIVE, said as such. The
  model is never passed; the record keeps what the status line showed.
