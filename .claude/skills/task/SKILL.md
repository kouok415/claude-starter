---
name: task
description: Long tasks, multi-hour features, unattended runs — a one-page task card the human approves, thin end-to-end slices, lane evidence written by scripts/evidence.sh, a fresh checker per slice, Codex on the card, risky slices and close. Use for work expected to exceed ~30 minutes, or when the user says /task, "long task", or "長任務". --auto records intent calls as [ASSUMED] instead of asking.
---

# /task — card, lanes, evidence, checker

You orchestrate. `.ai_context/tasks/<slug>/card.md` is the contract,
`notes.md` the detail, `.claude/done-lanes` how the product runs. Only
`scripts/evidence.sh` writes `[x]` and `Closed:`; the Stop gate checks them
and runs nothing. The checker never sees the executor's report.

## 0 · Resume

1. `tasks/CURRENT` names a task → resume; never re-interview or re-plan.
   Card + `evidence.sh status --line` are injected; run
   `bash scripts/evidence.sh status` for the full view.
2. No APPROVE row for the current card → §3.4 first.
3. Re-enter the `[~]` slice after its last donelog row (`reference.md`
   §Resume). A `[~]` mark alone never proves the executor ran.
4. Another task asked for → finish, abandon (`/wrap`) or defer? One at a time.

## 1 · Intake

1. Read what the request touches first. Never ask what the repo answers.
2. Echo the goal (what, for whom, why) in ≤200 words. Ask the ONE question
   that most changes what gets built, plus "what would make you reject
   this even with every check green?" Quote answers in `notes.md` §Rulings.
3. Give 2–3 approaches: what each builds, build cost (hours, lines, files
   to maintain), verification cost (lanes, check code) and what it rules
   out later. Recommend the least added scope; never narrow the request.
4. Empirical fork (works? how fast?) → a ≤30-min throwaway in `scratch/`,
   deleted after, not a debate. Direction, cost or preference → ask now,
   with your pick and its cost.
5. Unrequested mechanism (guard, retry, mode, abstraction, checker/judge/
   selftest code) only if a contract requires it, leaving it out lets harm
   land unnoticed, or adding it later is expensive; else Decisions gets
   `[own] considered, not built: <what> — <why>`. Review findings asking
   for more pass the same test.
6. Slice 1 = the thinnest real end-to-end path through the product.
7. Tripwire: time or lines pass 2× the approved estimate, or verification
   code outgrows product code (`evidence.sh status`) → stop, re-present
   cost and cheaper options — unattended too.
8. Tag each decision `[human]`, `[inferred]`, `[own]`, or `[ASSUMED]` (an
   intent call made without asking; `--auto` only).
9. Clean tree first (commit, or ask whose changes they are); a kebab-case
   ASCII slug into `tasks/CURRENT`; branch `task/<slug>` — never on main.

## 2 · Card (≤4 KB incl. room for ✓ suffixes) + notes.md

    # <title>
    <!-- card v4 ; pair: codex|off ; base: <sha> ; estimate: <h>h <n>L -->
    Goal: <what, for whom, why — ≤3 lines>
    Done when: <predicate on the running product> ; outside check: <who/what, not you>
    Decisions:
    - [human] <decision>
    ## Slices
    - [ ] S1 <what the user sees> — lanes: smoke ; codex: no ; notes: §<name>

1. Marks: `[ ]` todo · `[~]` in progress, at most one · `[o]` waiting on
   the owner (state exactly what they must do) · `[x]` only via
   `evidence.sh done` · `Closed:` only via `evidence.sh close`.
2. Each slice: what the user sees + ≥1 lane; never consumes a later
   slice's output. `codex: yes` when it touches money, secrets or
   installs. `pair:` may raise `@pair`, never lower it.
3. `notes.md` (never injected; >16 KB warns): constraints, interfaces,
   edge cases, rulings verbatim, measured facts with their command — no
   plan narrative (`reference.md` §Notes). Checkable detail → a lane
   `expect` or check script, not prose.
4. Any edit beyond status marks needs re-approval (§3.4).

## 3 · Lanes, trust, approve

1. Every slice lane exists in `.claude/done-lanes` (≤3; format and
   recipes: `reference.md` §Lanes). Adding one is a Decision.
2. Untrusted → `bash scripts/evidence.sh trust <lane>`: the human approves
   the prompt; the canary must go red.
3. Run each lane once (`evidence.sh run <lane>`) before any unattended run.
4. `bash scripts/evidence.sh lint`. Pair on → `bash scripts/task-pair.sh
   check card` (`pair.md`); off → `checker` on "Check card" (`reference.md`
   §Spawn). Fix blocker/major. Show the card per `reference.md` §Approval
   (Codex runs included), then `bash scripts/evidence.sh approve` — the
   human's yes on that prompt is the approval. `--auto` never skips it.

## 4 · Slice loop

1. `bash scripts/evidence.sh start S<n>` (records HEAD + time, marks `[~]`).
2. Spawn `executor` (`reference.md` §Spawn): card path, slice line
   verbatim, notes sections, start HEAD, lanes; on a retry the failing
   output and the premise it rested on. It commits `S<n>` by path. Lanes
   over ~8 min: you run them in the background and await the notification.
3. Spawn `checker` (fresh): slice id, card path, start HEAD, lanes —
   never the executor's report. The hook records its closing
   `checker-verdict:` block; never run `evidence.sh check` yourself.
4. `fail` with NOT VERIFIED → step 2 with those lines and findings verbatim;
   `fail` on INCONCLUSIVE only → the human rules on what it could not reach.
5. `codex: yes` and pair on → `bash scripts/task-pair.sh check slice S<n>`
   in the background (`pair.md`); blocker/major → step 2; no verdict
   twice → the human fixes, rescopes or waives (`approve --waive`).
6. A repair changes content: re-run lanes and checker (and Codex) — `done`
   refuses stale records.
7. `bash scripts/evidence.sh done S<n>`. Refused → do what it lists.
   Never write `[x]` by hand.
8. Report demo-first: what the user sees as actual output, the calls
   made (`notes.md` §Calls), one line `S<n> ✓ <records> · checker pass ·
   codex pass|n/a`. Two lines to state.md Now/Next. Next slice.

## 5 · Stuck

1. Red with no proven cause → `/debug`. No reproduction, no fix.
2. Two failed fixes on a slice → write their shared premise in `notes.md`
   §Tried (wrong slice cut? missing constraint? an environment assumption
   every attempt shared?) and test it before attempt 3.
3. Three → stop; report per `reference.md` §Escalation. After 3
   consecutive fails of one lane on one slice `evidence.sh run` writes
   ESCALATE and asks the human before running again — never route around.
4. Changing a lane, its expect or a threshold after it went red: own
   commit, reason in §Tried naming what it no longer covers; thresholds
   only on a human ruling.

## 6 · Close

1. All `[x]` → pair on: `bash scripts/task-pair.sh check final` (`pair.md`);
   off: `checker` on "Check final". Blocker/major or `fail` → a repair slice.
2. `bash scripts/evidence.sh close` — needs every slice `[x]`, the card's
   lanes fresh now, and the codex final, its waiver or (off) checker final.
3. Outside check: its named owner runs it; quote the verdict in §Rulings.
   Unattended → it heads the report as the open item.
4. Report every `[own]`/`[ASSUMED]` call (Decisions + §Calls) per
   `reference.md` §Close report.
5. `/wrap` (row from `harness-report.sh --row`; clears CURRENT); offer to
   merge `task/<slug>` or open a PR.

## 7 · Unattended

1. `--auto`: intent calls become `[ASSUMED]` Decisions instead of
   questions. Approve, trust, destructive and outward steps still wait.
2. `/goal` only for convergent mechanical work: its condition names a
   script's printed verdict and ends "or stop after <N> turns" (`reference.md`
   §Unattended). Never for direction, cost or "it works".

## Rules

- Mid-run messages are first-class: answer from card, notes and
  `evidence.sh status`; fold vetoes into the current slice; resume.
- No `git add -A/.`, `git checkout -- <path>`/`.`/`-f`, `git restore|stash`,
  `git switch --discard-changes` in a task (bash-guard asks); stage by path.
- Never edit `.claude/done-lanes.trust`, `.claude/evidence/`, `donelog`.
- Done/fixed claims go through `/prove`; numbers through `/number-check`.
