# Using claude-starter in a project

**English** · [繁體中文](./TUTORIAL.zh-TW.md)

> Documents claude-starter **v4.0** (2026-10-29). If the version here
> trails the newest section in [MIGRATION.md](./MIGRATION.md), mechanisms
> have moved since this walkthrough was stamped — MIGRATION is the authority.

The hands-on walkthrough: from zero to an evidence-checked long-horizon run.
For the architecture rationale, read [README.md](./README.md); for upgrading
older projects, [MIGRATION.md](./MIGRATION.md).

---

## 0. One-time machine setup

```bash
git clone https://github.com/<your-username>/claude-starter.git
cd claude-starter
./bootstrap-machine.sh     # installs ~/.claude/CLAUDE.md; optional pre-commit/gitleaks
```

Re-run after template updates — it shows a diff and asks before touching
your global layer (dated backup kept).

## 1. Spawn a project

```bash
./start_project.sh my-app                      # code project, private
./start_project.sh --kind research my-survey   # research framing
./start_project.sh --kind analysis my-backtest # data/analysis framing
./start_project.sh --local --kind code demo    # offline, no GitHub
```

The new project carries everything: hooks, `/wrap`, `/task` with its
executor and checker, the `/prove`, `/debug`, `/number-check`,
`/backtest-check` and `/defect` skills, and the `.ai_context/` skeleton.
Template infrastructure is removed.

## 2. First session — `/setup` runs the birth protocol

Open Claude in the project. While `CLAUDE.md` still contains template
placeholders, the session-start hook instructs Claude to run **`/setup`**
in its first reply — and the Stop gate blocks the first turn-end until the
draft lands, so this is mechanical, not a suggestion the model can drift
past. The protocol: one batched interview round (only what the code can't
tell) → scaffold the stack + wire `lint.sh` → draft CLAUDE.md / README /
state.md → write the project's `verify` skill and declare its lanes in
`.claude/done-lanes` → trust each lane (you confirm; its canary must fail)
and run it once → commit.

Your job is the 2-minute review, not the 10-minute write-up — and your
edits matter exactly where Claude can't guess:

- **Verify** — the command that proves a change works end-to-end
  (a smoke run, one real request), not just the test suite.
- **Definition of done** — project-specific bars: perf floors, coverage,
  "must run on the sample fixture". Intent lives here, not in the code.
- **Lanes** — the 1–3 commands that count as evidence for `/task`. Read
  each one before you approve its trust prompt.

Declining is fine — the gate yields after one block and re-arms next
session. Greenfield with no code yet? The interview does the work instead.

## 3. The daily loop (small work)

```
open Claude ──→ hook injects INDEX + state automatically (also after
   │            /clear and compaction — no manual protocol)
   work normally
   │
wrap up ──→ /wrap ──→ state.md refreshed, decisions → ADRs, events → journal
   │
   └──→ accept the commit: chore(context): wrap <topic>
```

Where memory goes (rule H4, one line): **now → `state.md` · forever →
`decisions.md` · this event → `journal/` · sensitive → `private/`** (never
committed).

## 4. Big work — `/task`

Anything expected to exceed ~30 minutes of autonomous work:

```
/task migrate auth from session cookies to JWT without breaking the 12 API tests
```

What happens, in order:

1. **Intake** — Claude reads the code the request touches, echoes the
   goal back, and asks the one question that most changes the result,
   plus "what would make you reject this even with every check green?".
   You get 2–3 approaches with their build and verification cost.
2. **Card** — a one-page `card.md`: goal, what "done" means on the running
   product, tagged decisions, slices (slice 1 = the thinnest real
   end-to-end path). Read it, then approve the confirmation
   `evidence.sh approve` raises. Any later edit beyond status marks needs
   your approval again before work goes on.
3. **Lanes** — the checks that count as evidence, from `.claude/done-lanes`
   (`/setup` declares them). The first time a lane is used,
   `evidence.sh trust` asks you to confirm — read the lane's line in
   `.claude/done-lanes` first — then runs its canary, which must fail.
   Approve only commands you understand.
4. **Slices** — per slice: a fresh `executor` builds it, runs the lanes
   (`evidence.sh run`) and commits, a fresh `checker` re-checks from the
   diff and the raw records, Codex joins on `codex: yes` slices (pair
   mode), and `evidence.sh done S<n>` marks it `[x]` with record ids — or
   prints what is missing. You can walk away.
5. **The gate** — it runs no lane. A slice marked `[x]` without a valid
   record, or a stale `Closed:` line, keeps the turn from ending;
   otherwise you see one status line. Two blocks in a row on the same
   card and content hand the run to you (`STUCK`).
6. **Stuck?** — `/debug` takes over: two failed fixes → test their shared
   premise; three → stop and report. A lane that failed three times in a
   row on one slice asks you before it runs again (`ESCALATE`).
7. **Close** — `evidence.sh close` (every slice `[x]`, every lane the
   card cites fresh on the final tree, and a final check: Codex with
   pair on, the checker with pair off), your acceptance run for anything
   outside the repo, then `/wrap` appends the computed scoreboard row and
   clears `tasks/CURRENT`. You get a merge/PR offer.

**Unattended mode:** `/task --auto <description>` — intent calls are
recorded as `[ASSUMED: ...]` decisions on the card instead of asked, and
the close-out lists them all for your review. Destructive or
outward-facing actions still require confirmation. `/goal` only for
convergent mechanical work, with a round cap.

**Interrupted?** Reopen the session — the hook re-injects the card and one
evidence status line; invoking `/task` while a task is active
**resumes** it at the `[~]` slice (never re-plans). A card untouched for 7
days (card, donelog and `task/<slug>` branch) is no longer injected or
gated; it stays on disk.

## 5. Pair mode (Codex)

A Codex judge in a sibling herdr pane checks the work at three points;
Claude still does all of it. Needs: the session running inside a herdr
pane, Codex CLI logged in, the repo trusted in Codex once, and no
`AGENTS.md` or `AGENTS.override.md` (or ones identical to `CLAUDE.md`).
The dialog texts it handles were recorded on Codex 0.165.0 and herdr
0.9.0; a dialog it does not know stops the run and hands you the pane.

| Stage | When | Codex checks |
|---|---|---|
| card | before slice 1 | every slice can fail and has a lane and a visible result; slice 1 is end-to-end; money/secret/install slices say `codex: yes` |
| slice | before `done` on a `codex: yes` slice | re-runs the lane or says why it can't; checks the check |
| final | before `close` | correctness, regressions, test integrity across the branch; one rebuttal round |

Turn it on with `@pair codex` in `.claude/done-lanes` (project default;
then re-trust one lane, since `@` lines are part of the trust) or
`pair: codex` in the card header (can raise, never lower). A judge run
takes about 6 minutes (up to an hour; the script's wait gives up at 2
hours and `task-pair.sh wait <seq>` re-attaches) and the tree must not
change meanwhile; a pass needs `verdict: pass` with zero blockers and zero
majors, written by the judge itself (its own write of the result must be
in its Codex transcript).

Runs spend your Codex quota. Starting `/task` with pair on covers the
card check and one retry; approving the card covers the estimate it
shows (one run per `codex: yes` slice, the final run, a retry per unit,
one rebuttal). Past the estimate the script stops and asks. If Codex
cannot answer, `bash scripts/evidence.sh approve --waive <unit> --reason
"…"` lets that unit through on your word — it asks first, and a card
edit voids it.

## 6. Upgrading existing projects

```bash
cd claude-starter && ./sync-project.sh ../my-older-project
```

Add-only: missing mechanism files are copied in, anything that exists is
never overwritten — instead you get suggestions for the manual merges.
Two extra modes: `--update-stock` also advances mechanism files that are
provably unmodified stock copies (content matches a historical template
version) and deletes stock copies of files the template retired
(customized files are never touched; it refuses while a task started
under v3 is still active), and `--adopt` onboards an existing non-starter
repo (creates the skeleton, then `/setup` drafts the brief from the code).
Full guide: [MIGRATION.md](./MIGRATION.md).

## 7. Troubleshooting

- **A lane checks the wrong thing** — edit `.claude/done-lanes`, then run
  `bash scripts/evidence.sh trust <lane>` again (the old hash no longer
  runs) and note in `notes.md` §Tried what the old command did not check —
  the checker flags a changed lane without that reason. Old records stop
  counting.
- **Lane runs are slow** — keep the minutes-long path in the `verify` skill
  (Claude Code runs it before commits); give slow paths (VM, full
  backtest) their own lane and run them in the background — the gate
  waits while the run's lock is alive.
- **The gate itself misbehaves** — it never blocks on its own bug: it logs
  `GATE-ERROR` in the donelog and lets the turn end. Report it as a
  friction row.
- **A commit message triggers a bash-guard ask** — bash-guard reads
  `evidence.sh trust|approve|check|codex` in command position, after
  splitting the command on `;` `&` `|` `(` `)`, backticks and newlines; a
  message that puts one of those right before `evidence.sh <sub>` looks
  like a command to it. Reword the message, or commit with `git commit
  -F <file>`. The other side is the boundary: a glob (`evid*.sh`), a
  variable or a symlink naming the script is not caught — it stops slips,
  not a deliberate bypass.
- **Abandon a task** — run `/wrap` and say so: it records the run as
  abandoned (or failed) in `scoreboard-v4.csv` and deletes
  `.ai_context/tasks/CURRENT`; the task directory stays. Deleting
  `CURRENT` by hand disarms the harness too, but `harness-report.sh` then
  lists the task as an orphan. Write the slug back to resume later.
- **Hooks don't seem to fire** — hooks load at session start; restart the
  session after changing `settings.json`. Quickest check: INDEX/state
  injection at the top of a fresh session.
- **Stale / oversize `state.md` warnings** — run `/wrap`; it refreshes the
  date and archives resolved sections.

**What each message means.** Harness messages start with a fixed
prefix; the ones you will meet:

| You see | It means | Do |
|---|---|---|
| `SETUP GATE` | CLAUDE.md still carries the `UNCONFIGURED` sentinel | let `/setup` run — or say you decline; it yields once and re-arms next session |
| `GATE BLOCKED (block n of 2 …)` … `is marked [x] without an evidence reference` | a slice is `[x]` but `evidence.sh done` never wrote it; the turn cannot end | let it set the line back to `[~]` and run `evidence.sh done S<n>`; never hand-edit `[x]` |
| `… cites evidence that does not hold: …` | an `[x]` cites a record that is gone, red, another lane's, or not the one its `DONE` row names — or (`not evaluated by evidence.sh`) the gate saw an `[x]` that `evidence.sh status` returned no verdict for, and blocks rather than pass it unchecked | re-run the lane, then `done` again; for the second, run `bash scripts/evidence.sh status` and fix what it reports |
| `… the evidence is not fresh for the current content` | content changed after `close` wrote `Closed:` | re-run the lanes (and final Codex), then `close` again — or delete the `Closed:` line |
| `claude-starter-gate: BLOCK` | the marker printed before every block | nothing — it keeps the CLI from dropping the block |
| `… in flight; evidence check deferred until it reports` (`WAITING` row) | a lane run, a Codex send or a subagent is still running | wait — its end wakes the session |
| `… is BLOCKED - n stops in a row on the same card and content …` `yielding now` (`STUCK` row) | two blocks on the same card and content: the run is yours | read `donelog`; fix, re-trust a wrong lane, or abandon |
| `internal error` … `not blocking this stop` (`GATE-ERROR` row), e.g. `block counter not writable - yielding instead of blocking uncounted` | the gate itself failed and this stop was allowed — in the example it could not keep its block count in `$TMPDIR` (else `/tmp`), so it yields rather than block without a bound | file a friction row and fix the cause (a writable `$TMPDIR`); slices are not checked while it fails |
| `codex no verdict twice` | the judge gave no verdict twice on the same unit and content; `done`/`close` stay refused for it | look at the judge pane (a dialog may need you), fix and re-run — or waive the unit: `evidence.sh approve --waive <unit> --reason "…"` |
| `TRUST REFUSED —` … `static-only command` | the lane only proves the source exists | make the lane run the product |
| `TRUST REFUSED —` … `the canary passed` | the lane stays green on a known-bad input | fix the lane or its canary |
| `TRUST REFUSED —` … `the canary left the lane's content changed` | the canary broke something in the lane's paths and did not put it back, or wrote a file there (up to five paths are named) | make the canary restore what it breaks; gitignore the caches it writes |
| `RUN REFUSED —` … `changed since trust` | the lane's line, a file its command or canary names, an `@` line or `.claude/gitleaks.toml` changed after trust | read the change, then `bash scripts/evidence.sh trust <lane>` again |
| `ESCALATE —` … `failed 3 times in a row` | one lane failed three straight runs on one slice | stop and report (`/debug`); confirm `run --escalated` only if you want another try |
| `expect not matched` | the run finished but a marker line is missing | open the log path it prints; the product did not do what the lane checks |
| `executed=0` | nothing ran (zero tests, rows or requests) | unproven, not passed — fix the selection |
| `secret or internal-IP rule` | the lane (or canary) log matched `.claude/gitleaks.toml`; the run failed | stop the output from printing it; never paste that log |
| `lane files changed during the run` | files in the lane's paths changed while it ran (up to five are named) — your edits, or the run's own output such as a cache; the record was voided | gitignore what the run writes itself; otherwise re-run once edits stop |
| `NOT DONE —` / `NOT CLOSED —` … `Not proven this time` | `done` or `close` refused and lists what is missing (record, checker, Codex, approval, files outside lane paths, stale lanes) | supply the missing piece; read the "not proven" footer before saying done |
| `card changed since approval` / `CARD LINT —` | the card was edited after your yes, or its format is broken | review the diff and approve again / fix what lint names |
| `scratch_in_mailbox` / `AGENTS.md differs from CLAUDE.md` | the judge wrote into `pair/` (run voided) / the judge would read the wrong brief | nothing — it re-runs / delete `AGENTS.md` or copy `CLAUDE.md` over it |
| a confirmation prompt from `bash-guard` | `rm -rf` leaving the project, `.env` or `.secrets/` access; during a task: `git add -A`/`.`, `git checkout [--] <path>`, `git checkout .`/`-f`, `git switch --discard-changes`/`-f`, `git restore` (not `--staged` alone), `git stash` (not `list`/`show`); any time: a command touching `.claude/evidence/` or the trust file, a write to a donelog, a `pair/` mailbox or Codex's session logs, a write to a script or setting the evidence chain trusts (`evidence.sh`, the hooks, `guard-patterns.sh`, the checker agent, the gitleaks wrapper, `harness-report.sh`, `settings.json`, `settings.local.json` — an Edit of them asks too), `evidence.sh trust`/`approve`/`check`/`codex`, `run --escalated`, `task-pair.sh --over-estimate` | approve only what you meant; trust, approve and check are your sign-off. Under `bypassPermissions` no hook ask appears — only `settings.json`'s own asks (trust/approve/check, the Edit asks on the chain files, push/reset --hard/clean/sudo and the `rm -rf ~/*`-style rules) |
| `BASH GUARD — blocked (…)` | force-push, a privileged command or `rm -rf /`: never run unattended; logged to `private/bash-guard.log` | run it yourself if you really mean it |
| a permission denial reading `.env*` / `.secrets/` | H1: Claude never reads secrets | keep them there; code reads them at runtime |
| `WARNING: state.md last updated …` / `… is newer than state.md` / `WARNING: … bytes (cap …)` / `TRUNCATED: first 4096 of` | memory is stale or the last session skipped `/wrap`; or an injected file outgrew its cap (state.md 5120, card.md 4096 — truncated, notes.md 16384, CLAUDE.md 20480) | `/wrap`; distill or move detail to `notes.md` |
| `has been idle` … `the Stop gate does not check it` / `a v3 plan.md task without card.md` | the task idled > 7 days / `tasks/CURRENT` names a v3 task, which v4 neither injects nor gates | `/task` to resume or delete `CURRENT` / finish it on a `v3-final` checkout, rewrite it as a card, or delete `CURRENT` |
| `harness-report.sh`: `defect candidate` | a fix commit within 30 days after `Closed:` touched this task's files | confirm (`/defect`) or dismiss (`harness-report.sh --defect-dismiss <sha>`) |

## 8. Cheat sheet

| Action | Command |
|---|---|
| New project | `./start_project.sh [--kind code\|research\|analysis] <name>` |
| End of session | `/wrap` |
| Big task | `/task <description>` |
| Big task, unattended | `/task --auto <description>` |
| Abandon a task | `/wrap` (records it as abandoned), or delete `.ai_context/tasks/CURRENT` |
| Set up / re-draft the project brief | `/setup` |
| Trust a lane | `bash scripts/evidence.sh trust <lane>` |
| Run a lane | `bash scripts/evidence.sh run <lane>` |
| Mark a slice done | `bash scripts/evidence.sh done S<n>` |
| Where does the task stand? | `bash scripts/evidence.sh status` |
| Let a unit through without Codex | `bash scripts/evidence.sh approve --waive <S<n>\|card\|final> --reason "…"` |
| Record a defect found after done | `/defect` |
| Prune old lane logs | `find .claude/evidence/logs -mtime +30 -delete` |
| Status line (opt-in) | `"statusLine": {"type": "command", "command": "bash scripts/evidence.sh status --line"}` in `.claude/settings.local.json` |
| Upgrade a project | `./sync-project.sh <path>` |
| Upgrade + advance stock files | `./sync-project.sh --update-stock <path>` |
| Onboard an existing repo | `./sync-project.sh --adopt <path>` |
| Update global layer | `./bootstrap-machine.sh --force-global` |

First recommended run: let `/setup` declare one fast lane, then pick a real
mid-size task and read `bash scripts/harness-report.sh` afterwards — that's
your first data point on whether the harness earns its keep on your
workload.
