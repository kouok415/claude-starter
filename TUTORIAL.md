# Using claude-starter in a project

**English** · [繁體中文](./TUTORIAL.zh-TW.md)

> Documents claude-starter **v3.10** (2026-07-23). If the version here
> trails the newest section in [MIGRATION.md](./MIGRATION.md), mechanisms
> have moved since this walkthrough was stamped — MIGRATION is the authority.

The hands-on walkthrough: from zero to a gated long-horizon run. For the
architecture rationale, read [README.md](./README.md); for upgrading older
projects, [MIGRATION.md](./MIGRATION.md).

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

The new project carries everything: hooks, `/wrap`, `/task`, the agent
crew, and the `.ai_context/` skeleton. Template infrastructure is removed.

## 2. First session — `/setup` runs the birth protocol

Open Claude in the project. While `CLAUDE.md` still contains template
placeholders, the session-start hook instructs Claude to run **`/setup`**
in its first reply — and the Stop gate blocks the first turn-end until the
draft lands, so this is mechanical, not a suggestion the model can drift
past. The protocol: one batched interview round (only what the code can't
tell) → scaffold the stack + wire `lint.sh` → draft CLAUDE.md / README /
state.md → run the drafted Verify once → commit.

Your job is the 2-minute review, not the 10-minute write-up — and your
edits matter exactly where Claude can't guess:

- **Verify** — the command that proves a change works end-to-end
  (a smoke run, one real request), not just the test suite.
- **Definition of done** — project-specific bars: perf floors, coverage,
  "must run on the sample fixture". Intent lives here, not in the code.

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

1. **Spec** — the request is distilled into executable acceptance
   criteria. Ambiguities about *intent* are asked now, never mid-run.
2. **Plan** — planner agent(s) draft milestone candidates, a red-team
   critic attacks them, and a synthesized `plan.md` lands: small
   milestones, each with a `verify:` command. This is your moment to
   glance at the cut.
3. **Milestone loop** — per milestone: a fresh-context `executor`
   implements, an adversarial `verifier` re-runs verify itself and checks
   for weakened tests, and a passed gate becomes a commit on the
   `task/<slug>` branch. You can walk away.
4. **The gate** — if Claude tries to end a turn while the milestone's
   verify is red, `stop-gate.sh` blocks it and feeds the failure back.
   You'll see `GATE FAILED` plus the command output. Done stops being
   prose.
5. **Stuck?** — the escalation ladder runs itself: retry differently
   (testing the failed attempt's premise first) → divergent parallel attempts → `reframer` rewrites the problem → after
   three strikes it stops and reports honestly.
6. **Completion** — a three-lens review panel, then `/wrap` archives a
   scoreboard (profile, gate failures, highest rung used) to `journal/`
   and appends a row to `.ai_context/scoreboard.csv`. Gate counts come
   from the hook-written `gatelog`, not from the model's memory. You get
   a merge/PR offer.

**Unattended mode:** `/task --auto <description>` — intent calls are
recorded as `[ASSUMED: ...]` entries in spec.md instead of asked, and the
completion report lists them all for your review. Destructive or
outward-facing actions still require confirmation.

**Interrupted?** Reopen the session — the hook re-injects the task's
`plan.md` + `lessons.md`, and the run resumes from the last passed gate.
Compaction mid-run is survivable for the same reason. Invoking `/task`
while a task is active **resumes** it (finds the `[in_progress]` milestone
and re-enters the loop — never re-plans); abandoning is deleting
`.ai_context/tasks/CURRENT`.

## 5. Profiles

| Profile | How to enable | When |
|---|---|---|
| `opus-tier` | run the session on an opus-class model (auto-detected) | no fable access, security-domain work, latency-sensitive |
| `fable-tier` | run the session on a fable-class model (auto-detected) | highest-stakes long runs, overnight unattended work |
| `mixed` | pin `model: opus` in `.claude/agents/executor.md`, run the session on a fable-class model | **recommended default** — strong model plans/critiques/reviews, cheaper tier executes |

The profile is detected at intake and **frozen into the task's plan.md** —
pin it per project by uncommenting a `Task profile:` line in `CLAUDE.md`.
Switching models mid-task never silently changes behavior: remaining
milestones get re-cut explicitly.

## 6. Upgrading existing projects

```bash
cd claude-starter && ./sync-project.sh ../my-older-project
```

Add-only: missing mechanism files are copied in, anything that exists is
never overwritten — instead you get suggestions for the manual merges.
Two extra modes: `--update-stock` also advances mechanism files that are
provably unmodified stock copies (content matches a historical template
version; customized files are still never touched), and `--adopt` onboards
an existing non-starter repo (creates the skeleton, then `/setup` drafts
the brief from the code). Full guide: [MIGRATION.md](./MIGRATION.md).

## 7. Troubleshooting

- **Gate keeps failing but the verify command itself is broken** — edit
  that milestone's `- verify:` line in `plan.md`, and append one
  `lessons.md` line saying why the old command was wrong and what the new
  one no longer checks — the final panel and `harness-report.sh` flag a
  verify that changed after a FAIL with no reason. The gate forces at
  most one continuation per stop cycle (no deadlock possible) and re-arms
  next turn.
- **Abandon a task** — delete `.ai_context/tasks/CURRENT`; the harness
  disarms instantly. The task directory stays; write the slug back to
  resume later.
- **Hooks don't seem to fire** — hooks load at session start; restart the
  session after changing `settings.json`. Quickest check: INDEX/state
  injection at the top of a fresh session.
- **Stale / oversize `state.md` warnings** — run `/wrap`; it refreshes the
  date and archives resolved sections.
- **Verify commands run unprompted.** The gate executes the active
  milestone's `- verify:` at every turn-end without permission prompts —
  keep them read-only and fast (< 5 min). The plan-critic rejects
  destructive ones; plan review is your checkpoint.

**What each message means.** Harness messages start with a fixed
prefix; the ones you will meet:

| You see | It means | Do |
|---|---|---|
| `SETUP GATE` | CLAUDE.md still carries the `UNCONFIGURED` sentinel | let `/setup` run — or say you decline; it yields once and re-arms next session |
| `GATE BLOCKED (block n of 2 …)` … `is marked [x] without an evidence reference` | a slice is `[x]` but `evidence.sh done` never wrote it; the turn cannot end | let it set the line back to `[~]` and run `evidence.sh done S<n>`; never hand-edit `[x]` |
| `… cites evidence that does not hold: …` | an `[x]` cites a record that is gone, red, another lane's, or not the one its `DONE` row names | re-run the lane, then `done` again |
| `… the evidence is not fresh for the current content` | content changed after `close` wrote `Closed:` | re-run the lanes (and final Codex), then `close` again — or delete the `Closed:` line |
| `claude-starter-gate: BLOCK` | the marker printed before every block | nothing — it keeps the CLI from dropping the block |
| `… in flight; evidence check deferred until it reports` (`WAITING` row) | a lane run, a Codex send or a subagent is still running | wait — its end wakes the session |
| `… is BLOCKED - n stops in a row on the same card and content …` `yielding now` (`STUCK` row) | two blocks on the same card and content: the run is yours | read `donelog`; fix, re-trust a wrong lane, or abandon |
| `internal error` … `not blocking this stop` (`GATE-ERROR` row) | the gate itself failed; this stop was allowed | file a friction row; slices are not checked until it is fixed |
| `codex no verdict twice` | the judge gave no verdict twice on the same unit and content; `done`/`close` stay refused for it | look at the judge pane (a dialog may need you), fix and re-run — or waive the unit: `evidence.sh approve --waive <unit> --reason "…"` |
| `TRUST REFUSED —` … `static-only command` | the lane only proves the source exists | make the lane run the product |
| `TRUST REFUSED —` … `the canary passed` | the lane stays green on a known-bad input | fix the lane or its canary |
| `RUN REFUSED —` … `changed since trust` | the lane's line, an `@` line or `.claude/gitleaks.toml` changed after trust | read the change, then `bash scripts/evidence.sh trust <lane>` again |
| `ESCALATE —` … `failed 3 times in a row` | one lane failed three straight runs on one slice | stop and report (`/debug`); confirm `run --escalated` only if you want another try |
| `expect not matched` | the run finished but a marker line is missing | open the log path it prints; the product did not do what the lane checks |
| `executed=0` | nothing ran (zero tests, rows or requests) | unproven, not passed — fix the selection |
| `secret or internal-IP rule` | the lane (or canary) log matched `.claude/gitleaks.toml`; the run failed | stop the output from printing it; never paste that log |
| `lane files changed during the run` | edits landed while the lane ran; the record was voided | re-run once edits stop |
| `NOT DONE —` / `NOT CLOSED —` … `Not proven this time` | `done` or `close` refused and lists what is missing (record, checker, Codex, approval, files outside lane paths, stale lanes) | supply the missing piece; read the "not proven" footer before saying done |
| `card changed since approval` / `CARD LINT —` | the card was edited after your yes, or its format is broken | review the diff and approve again / fix what lint names |
| `scratch_in_mailbox` / `AGENTS.md differs from CLAUDE.md` | the judge wrote into `pair/` (run voided) / the judge would read the wrong brief | nothing — it re-runs / delete `AGENTS.md` or copy `CLAUDE.md` over it |
| a confirmation prompt from `bash-guard` | `rm -rf` leaving the project, `.env` access, or during a task: `git add -A`/`.`, `git checkout -- <path>`, `git checkout .`/`-f`, `git switch --discard-changes`/`-f`, `git restore`, `git stash`; any time: a command touching `.claude/evidence/`, the trust file or a donelog, `evidence.sh trust`/`approve`/`check`/`codex`, `run --escalated`, `task-pair.sh --over-estimate` | approve only what you meant; trust, approve and check are your sign-off. Under `bypassPermissions` only the `settings.json` asks (trust/approve/check) still appear |
| `BASH GUARD — blocked (…)` | force-push, a privileged command or `rm -rf /`: never run unattended; logged to `private/bash-guard.log` | run it yourself if you really mean it |
| a permission denial reading `.env*` / `.secrets/` | H1: Claude never reads secrets | keep them there; code reads them at runtime |
| `WARNING: state.md last updated …` / `… is newer than state.md` / `WARNING: … bytes (cap …)` / `TRUNCATED: first 4096 of` | memory is stale or the last session skipped `/wrap`; or an injected file outgrew its cap (state.md 5120, card.md 4096 — truncated, notes.md 16384, CLAUDE.md 20480) | `/wrap`; distill or move detail to `notes.md` |
| `has been idle` … `the Stop gate does not check it` / `a v3 plan.md task without card.md` | the task idled > 7 days / `tasks/CURRENT` names a v3 task, which v4 neither injects nor gates | `/task` to resume or delete `CURRENT` / finish it on a `v3-final` checkout, rewrite it as a card, or delete `CURRENT` |
| `harness-report.sh`: `verify changed after FAIL` | a gate moved after it failed | find the reason in `lessons.md`; none → ask why |
| `harness-report.sh`: `verification depth gap` | a `risk: med/high` milestone finished without its verifier | re-check it, or accept the risk knowingly |

## 8. Cheat sheet

| Action | Command |
|---|---|
| New project | `./start_project.sh [--kind code\|research\|analysis] <name>` |
| End of session | `/wrap` |
| Big task | `/task <description>` |
| Big task, unattended | `/task --auto <description>` |
| Abandon a task | delete `.ai_context/tasks/CURRENT` |
| Set up / re-draft the project brief | `/setup` |
| Upgrade a project | `./sync-project.sh <path>` |
| Upgrade + advance stock files | `./sync-project.sh --update-stock <path>` |
| Onboard an existing repo | `./sync-project.sh --adopt <path>` |
| Update global layer | `./bootstrap-machine.sh --force-global` |

First recommended run: pick a real mid-size task, use the `mixed` profile,
and read the scoreboard in `journal/` afterwards — that's your first data
point on whether the harness earns its keep on your workload.
