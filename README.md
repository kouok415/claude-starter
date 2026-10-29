# claude-starter

**English** · [繁體中文](./README.zh-TW.md)

> A language-agnostic project scaffold for working with Claude Code:
> structured persistent memory, plus the mechanisms that make the rules
> actually hold.

When you work with Claude across many sessions, three things go wrong:

1. **Claude forgets between sessions.** Decisions made on Tuesday vanish by
   Thursday. You re-explain. Claude re-discovers. Time leaks.
2. **The usual fix is a `CLAUDE.md` and a notes folder, glued together
   ad-hoc.** Each project ends up with a different layout. Rules drift.
   Sensitive data leaks into commits.
3. **Prose rules don't enforce themselves.** "Read state.md first", "no
   secrets", "keep it under 5 KB" — written in markdown, obeyed only while
   the model happens to remember them.

`claude-starter` fixes all three, designed once and reused: three layers of
memory, backed by a fourth layer of *mechanisms* — hooks, permission rules,
pre-commit checks — so the protocol survives long sessions, compaction, and
human forgetfulness. A fifth layer keeps big jobs honest: `/task` runs
long-horizon work from a one-page card, and nothing counts as done until a
script has recorded a real run of the product and an independent checker
has looked at it.

---

## The architecture

```
┌──────────────────────────────────────────────────────────┐
│ Layer 1 — Global        ~/.claude/CLAUDE.md              │
│   Behavior & preferences. Loaded for every project.      │
│   Canonical copy: global/CLAUDE.md in this repo.         │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 2 — Project       <project>/CLAUDE.md              │
│   Stack, commands, Verify, Definition of done.           │
│   What's true here that isn't true everywhere.           │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 3 — Memory        <project>/.ai_context/           │
│   ├── INDEX.md      Registry: where things live          │
│   ├── state.md      Now (mutable, ≤5 KB)                 │
│   ├── decisions.md  Forever (append-only ADR log)        │
│   ├── knowledge/    Long-term reference                  │
│   ├── journal/      Per-event records (dated)            │
│   └── private/      Sensitive scratch (gitignored)       │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 4 — Mechanisms    <project>/.claude/ + pre-commit  │
│   Hooks, skills, permission rules that ENFORCE the       │
│   three layers above instead of hoping they're followed. │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 5 — Execution     /task + evidence + checker       │
│   Long-horizon harness: a one-page task card, run        │
│   evidence only a script can write, a fresh checker      │
│   per slice, Codex (pair mode) at card, slices, close.   │
└──────────────────────────────────────────────────────────┘
```

Each layer answers one question:

- **Global:** how should Claude *behave*?
- **Project:** what is *this project*, and what does *done* mean here?
- **Memory:** what has *already happened*, and what's *true now*?
- **Mechanisms:** what holds when nobody is paying attention?
- **Execution:** how does a job too big for one context get done — and
  *proven* done?

## Prose → mechanism

The v2 principle: every rule that matters gets a mechanism. Prose is the
spec; the mechanism is the guarantee.

| Rule (prose) | Mechanism (enforced) |
|---|---|
| "Read INDEX.md, then state.md, every session" | `SessionStart` hook injects both — on startup, resume, `/clear`, and after compaction |
| "Write memory back before you stop" | `/wrap` skill runs the write-back ritual |
| "The Codex judge checks; it never writes, and its verdict counts only as a record" (pair-codex) | `scripts/task-pair.sh`: hooks-off start, refusal when `AGENTS.md` or `AGENTS.override.md` differs from `CLAUDE.md`, a tree fingerprint before and after every run (`tree_changed` voids it), modal scan, judge scratch kept under `/tmp` (anything new in `pair/` voids the run: `scratch_in_mailbox`), a six-line result contract; it never prints a verdict. Every run that reached the judge becomes a `codex-<stage>` record through `evidence.sh codex` (a `not_started` attempt is neither recorded nor counted); a record approves only when the run completed with `verdict: pass`, 0 blockers and 0 majors, and the judge's own `apply_patch` write of that result is in its Codex transcript (`prov=ok`). While pair is on, `done` and `close` need approving card, `codex: yes` slice and final records — or your waiver, `evidence.sh approve --waive` (a confirmation, void once the card changes) — `tests/run.sh` L1-23, L1-39–L1-44 and L1-47 over a fake herdr |
| "No secrets in commits" (H1) | gitleaks pre-commit hook + `settings.json` denies reading `.env*` and `.secrets/**` |
| "Secrets are runtime-only: code may read them, Claude and git may not" | the `.secrets/` folder — Read tool denied (`settings.json`), bash access downgraded to a confirmation (`bash-guard.sh`), gitignored except the placeholder; execution-time reads (`GOOGLE_APPLICATION_CREDENTIALS=.secrets/sa.json ...`) untouched. Hard on the Read tool, a tripwire elsewhere — code that can read a secret can always leak it, so don't echo secrets to stdout |
| "state.md stays under 5 KB" (S7) | pre-commit size check + session-start warning |
| "Time-stamp aging facts" (S3) | session-start hook warns when `state.md` is stale |
| "Prove it before you say it" | `/prove`, `/debug`, `/number-check` and `/backtest-check` are model-invocable skills: Claude loads one when its description matches the situation — guidance, not a gate — and each ends in checkable output (quoted runs, `VERIFIED` / `NOT VERIFIED` / `INCONCLUSIVE` labels, a pass/fail line per check). The project's `verify` skill, written by `/setup` from `.claude/skills/setup/verify-template.md`, is the one Claude Code runs before a commit, so it stays minutes long. Inside `/task` the enforced form is the next row |
| "Done means the product ran — recorded by a script, not claimed" | only `scripts/evidence.sh done S<n>` writes a slice's `[x]`, with the record ids after a ` ✓ `. It refuses, listing each gap, unless: every lane the slice names has a passing record made after `evidence.sh start S<n>`, under the lane definition trusted now, on the current content of its `paths`; a checker record of the slice at that content passes (no `NOT VERIFIED`, and its first claim — the slice's own result — `VERIFIED` by running it, L4/L5; anything else is recorded as a fail); with pair on and `codex: yes`, an approving `codex-slice` record or your waiver; your approval matches the current card; and no file changed since the slice's start lies outside its lanes' `paths`. The Stop gate re-checks every `[x]` citation and runs no lane. Outside `/task`, CLAUDE.md's `Verify` + **Definition of done** still govern — prose, plus the optional `lint.sh` post-edit hook |
| "A check that cannot fail is not a check" | `evidence.sh trust <lane>` refuses a static-only command (every segment one of `bash -n`, `py_compile`, `shellcheck`, `grep`/`rg`, `test`, `ls`, `cat`, `echo`, … or carrying `--help`, `--version`, `--list-*`, `--parse-check`, `--selftest`, `--dry-run`, `--collect-only`), an empty or trivial canary (`false`, `exit 1`, the lane's own command) and paths that hold no tracked or unignored file; `.claude/done-lanes` itself rejects `min_secs` below 1 and an empty `expect`. Then it runs the canary — a known-bad input that must turn the lane red, restore what it broke and print nothing the log scan flags; `canary = skip:<reason>` needs a second run with `--skip-canary`, a second confirmation |
| "Evidence belongs to the content it ran on" | each run record binds a content id of the lane's `paths` (tracked and untracked-unignored files, hashed from the worktree — files marked assume-unchanged or skip-worktree included; `.ai_context/` and `.claude/evidence/` never count): changed content → stale; content changed during the run → voided, with up to five changed paths named; `amend`/`rebase` alone don't invalidate it; a record older than the slice's `evidence.sh start` doesn't count |
| "Zero executed is unproven" | a run passes only on exit 0, every `expect` marker matched, an executed count > 0 (the first number on the first marker's line) and at least `min_secs` seconds; its log (`.claude/evidence/logs/`, mode 600) is scanned with `.claude/gitleaks.toml` — gitleaks defaults plus internal-IPv4 (QEMU's `10.0.2.0/24` allowed), tailnet-hostname and URL-credential rules; without gitleaks, the internal-IP rule alone via `grep -E` — and a hit fails the run; `done`, `close` and `show` always end with what the records do *not* prove |
| "Your approval of the card is a record" | `evidence.sh approve` runs behind a confirmation and writes an `APPROVE` donelog row with the card digest (status marks, ` ✓ ` tokens and the `Closed:` line excluded); after any other edit `start` refuses and `done`/`close` list the gap until you approve again. `approve` refuses a card that fails `evidence.sh lint`: header, `Goal:`, `Done when: … ; outside check:`, tagged decisions, slice lines that parse and name declared lanes, no duplicate ids, at most one `[~]`, every cited `notes.md` § present, ≤4096 B with room left for the evidence suffixes |
| "Three strikes is mechanical" | three consecutive failed runs of one lane on one slice since its start → `evidence.sh run` writes an `ESCALATE` row and refuses the next one (exit 5); `run --escalated` goes on only after a bash-guard confirmation (a hook ask — under `bypassPermissions` it does not appear); `/debug` says stop and report at three |
| "A blocked stop must reach the human, not die in the transcript" | counted yields: after two blocks in a row in one session on the same card and content, the third stop exits 0 with a `STUCK` donelog row and a `{"systemMessage"}` — the handoff is visible, not a silent pass-through; one `STUCK` row per (session, card, content), so the scoreboard counts one handoff as one. The counters live outside the project (`$TMPDIR`, else `/tmp`); one that cannot be written yields at once with a `GATE-ERROR` row instead of blocking without a bound |
| "A block must survive the host CLI, not just the hook" (v3.14) | every exit-2 path prints one fixed stdout marker line first — the CLI's missing-hook heuristic (`exit 2` + empty stdout + stderr matching `/no such file\|can't open/i`, observed through 2.1.229) otherwise demotes legitimate blocks to non-blocking. v4's outer pass forwards a block only when the inner pass exits 2 with that marker first. L1-21 exercises every block path |
| "A running check is a wake guarantee, not a red state" | `evidence.sh run` and `task-pair.sh send` hold a pid lock in `.claude/evidence/locks/` while they run; the gate defers on a lock whose pid is alive (and, where `ps` exists, still `evidence.sh` or `task-pair.sh`) and on a `"type": "subagent"` entry in the Stop payload's `background_tasks` — `WAITING` donelog row + systemMessage, quiet stop; the finished run wakes the session. A dead pid is a stale lock (`evidence.sh status` removes it), not a wait |
| "A gate bug never stalls the work" | the gate runs as two passes: the outer one forwards a block only when the inner one exits 2 with the marker first; anything else — a crash, a syntax error, 25 s without an answer — becomes a `GATE-ERROR` donelog row and a systemMessage, and the stop is allowed. Only evidence blocks. A task idle more than 7 days (card, donelog and `task/<slug>` branch untouched) is neither injected nor gated, and neither is a v3 `plan.md` task |
| "An independent checker actually ran — the hook says so, not the plan" | `spawn-log.sh` on `SubagentStart`/`SubagentStop`, routed by matcher (`executor`, `checker`; no payload parsing for routing), writes `SPAWN`/`RETURN` donelog rows; on a checker's stop it takes the report from the current wake only — its `SubagentHandback` message, else the payload's `last_assistant_message`, else its last text in the transcript — and has `evidence.sh check` write the checker record `done` requires. Nothing captured → `uncaptured`; the unit's content changed while it checked → `void`; `done` accepts neither |
| "The re-anchor costs at most a page" | session-start injects INDEX + state + the active card — 4096 B, cut at the last full line with a warning past that — plus one `evidence.sh status --line`; `notes.md` is never injected (warns past 16 KB), and executors and checkers read only the `§` a slice line cites; CLAUDE.md past 20 KB warns |
| "Long tasks decay — drift, silent errors, lost state" | `/task` v4: a one-page card you approve, slice 1 the thinnest real end-to-end path, a fresh `executor` and an independent `checker` per slice, Codex at the card, `codex: yes` slices and the close when pair is on (with it off, the checker reviews the card — a report for you — and the close), `/debug` when stuck; state lives in files the hooks re-inject |
| "Scope creep is visible" | `harness-report.sh --tripwire` (shown by `evidence.sh status`, and in the status line once tripped) compares the lines this task added under `@verify-paths` with everything else, and the hours since approval and the lines with the card's estimate; past 2× either, or verification code ahead of product code by 50+ lines, it says `TRIPPED` — a report, never a block |
| "Slices are things you can see, and every decision says whose it was" | each card slice names what the user sees and its lanes; `Decisions:` entries carry `[human]`, `[inferred]`, `[own]` or — for intent calls `--auto` made without asking — `[ASSUMED]` (`lint` rejects untagged ones); `[o]` marks a slice waiting on the owner — shown, never blocking a stop (`close` still needs it `[x]`) |
| "A new project's first session sets it up" | session-start `SETUP REQUIRED` instruction + Stop gate blocks the first turn-end (once per session); both key on the `claude-starter: UNCONFIGURED` sentinel in CLAUDE.md, which `/setup` deletes when the draft lands |
| "Checks can't be swapped quietly" | lanes live in `.claude/done-lanes` (≤3, one line each; `cmd` and `canary` hold no `\|` — anything longer is a wrapper script); `evidence.sh trust <lane>` — a confirmation: you read the line — hashes the lane's whole line, its `cmd` and `canary` together with every repo file they name, every `@` line and `.claude/gitleaks.toml` into `.claude/done-lanes.trust` (tracked, append-only, written only by `trust`, Edit-denied); `run` refuses when any of them differs, and records made under an older definition stop counting — so changing a lane, a script it calls, a directive or the scan rules means re-trusting in front of you |
| "Catastrophic bash never runs unattended" (never force-push, no sudo) | `bash-guard.sh` PreToolUse tripwire: force-push in any spelling (flags or `+refspec`) / `sudo` / root deletes (incl. `--no-preserve-root`, v3.10) denied and logged to `private/bash-guard.log`; `rm -rf` beyond the project tree (absolute, `~/`, `$HOME/`, `..` — v3.14.3) and `.env` access downgraded to a confirmation — the session's own `/tmp/claude-*/…/scratchpad` tree is exempt (v3.14.1: the harness discards it anyway, and a confirmation that fires every cleanup only teaches click-through). The hook is the ONLY `rm` tier: v3.14.2 dropped the `Bash(rm -rf:*)` ask rule from `settings.json`, because the CLI honors declarative `ask` rules in every mode — bypass included — per subcommand and regardless of hook output, so that rule kept prompting on every scratchpad cleanup and no hook-side exemption could reach it (the CLI's built-in critical-path breaker still asks for root / top-level / home / cwd deletes in every mode). Declarative `ask` (push, reset --hard, clean, sudo) and `deny` rules stay in `settings.json` for what should prompt even under bypass — and v3.14.3 adds three there for `rm -rf ~/*`, `$HOME/*`, `../*`: the CLI drops hook asks under bypass, and these spellings never touch a `/tmp` scratchpad, so they can prompt there without the storm; the hook mirrors them (any flag spelling) for the other modes. v3.14.4: the ask tier reads the command with heredoc bodies removed — prose in a memory-file write is not a command (17 of the fleet's 48 subagent `.env` stalls were exactly that, a median 10 minutes each) — and treats the project's own tree like the scratchpad for `rm -rf`; the deny tier still reads the full text. v3.14.5: any `/tmp/<name>…` passes too — on a dev box `/tmp` is disposable by definition, and every `/tmp/<name>` the fleet's subagents deleted was their own — while `/tmp`, `/tmp/`, `/tmp/*` still ask (`/tmp/claude-<uid>` as a whole passes: known edge). Contains-matching beats prefix rules — but it is a tripwire, not a sandbox |
| "Task work never stages or discards wholesale" | while a task is active, `bash-guard.sh` asks before `git add -A`/`--all`/`.`/`:/`/`*`, `git checkout [ref] [--] <path>` (any word that names an existing path), `git checkout .`, `git checkout -f`, `git switch --discard-changes`/`-f`, `git restore` (not `--staged` alone) and `git stash` (except `list`/`show`); `git commit -a` stays free (it loses nothing). The checker is told never to change git state (`checker.md`; it has no Edit or Write tool) — a prompt rule, not a lock |
| "A `--local` spawn never exports local state" | the copy is `git archive HEAD` — tracked content only: gitignored credentials (`.secrets/`), local settings, untracked scratch stay home; uncommitted template edits don't ride either (commit first). Non-git sources fall back to `cp -R` + purge of the known leak homes (v3.10) |
| "Failed and abandoned runs reach the dataset too" | `harness-report.sh --row <slug>` computes the scoreboard row from the card and the donelog only — run records are per machine; `outcome` is `success` only with a `Closed:` line and its `CLOSE` row, otherwise it must be given (`--outcome failed\|abandoned`, asked of you); `/wrap` appends the row to `.ai_context/scoreboard-v4.csv` at every close-out, abandonment included, and the report lists task directories that never got one |
| "Every scoreboard row names the harness that produced it" | `harness-report.sh --row` fills the `harness` column from the last `spawned-by:` or `synced-to:` line in `.claude/.starter-version` (`claude-starter@<ref>`); releases are git-tagged, so ref→version mapping is mechanical. The stamp tells the truth (v3.10): ANY sync that changed mechanisms appends a stamp (not just `--update-stock`) — `synced-to:` when every v4 core file is the template's afterwards (or a finished hand merge), else `partial-sync: <ref> on <date> (<n> core files kept back)`, which names no harness, so rows keep the last full one — and GitHub-mode spawns stamp the template head actually cloned, not the possibly-stale spawner checkout |
| "Harness friction is data, not vibes" | `/wrap` appends enum rows (`area` × `severity`) to `.ai_context/friction.csv` only when a mechanism actually misbehaved; `harness-report.sh` reports them next to the donelogs' `STUCK` and `GATE-ERROR` rows |
| "Scoring is computed, never recalled" | `scripts/harness-report.sh` (CI-tested) aggregates per harness version from donelogs, cards, pair runlogs, `scoreboard.csv` (v3 rows, now read-only), `scoreboard-v4.csv`, `defects.csv` and `friction.csv`; `--csv` v2 leads with `csv_version`; percentages are suppressed below N=5; no composite score exists, on purpose |
| "Scoring data is cross-checked, not trusted" | `harness-report.sh` `== integrity` lists task directories with a card but no scoreboard row, `[x]` slices `evidence.sh done` never wrote, `Closed:` lines without a `CLOSE` row, scoreboard/donelog mismatches (blocks, stuck, Codex runs) and enum violations; `== defects` lists fix commits made within 30 days after a task's close that touch its files — the task's own work merged, squashed or replayed after the close excluded (same `git patch-id`) — candidates you confirm (`/defect`) or dismiss (`--defect-dismiss <sha>`). Nothing is auto-repaired |
| "Defects are counted, not remembered" | `.ai_context/defects.csv` (`date,slug,slice,finder,phase,severity,n,summary,fixed_in,ref`) gets a row for every failing checker record with `NOT VERIFIED` claims (severity `unrated`) and every Codex slice or final record with blockers or majors — `evidence.sh` writes those itself — plus fix-commit candidates you confirm and owner, production or post-close findings you record with `/defect`; all go through `harness-report.sh --defect`, which derives `phase` (pre-done, post-done, post-close) and refuses a checker or Codex row without its ledger record, a slug without `tasks/<slug>/card.md` (slug `-` outside a task), a slice not on that card and a `ref` already recorded with that severity. A wrong row is withdrawn by appending a retraction: `--defect-retract <date> <slug> <slice> <ref> --reason "…"` (severity `retracted`; neither it nor the rows it retracts count anywhere). A `defects.csv` with another header is reported and skipped, never appended to |
| "Always-injected files stay small" | card 4096 B (cut at injection, refused by `lint`), INDEX size test + session-start warning past 4 KB, `state.md` 5 KB pre-commit cap + warning (S7), `notes.md` warning past 16 KB, CLAUDE.md warning past 20 KB |
| "Externalize bulk" (S2) | `check-context-bulk.sh` pre-commit: any staged `.ai_context` file over 100 KB blocks — dumps are referenced, not pasted. Task donelogs (and v3 gatelogs/spawnlogs) are exempt at `tasks/<slug>/` only, and only while every row is a log row: machine logs, append-only, and long tasks outgrow the cap |
| "Scoreboard numbers must be real" | every `scoreboard-v4.csv` column comes from the card or the donelog (`harness-report.sh --row`); `interventions` stays `-` in the project — it can only be counted from session transcripts, never remembered |
| "Append-only files are never rewritten" (decisions, journal, both scoreboards, friction, defects, task donelogs, `.claude/done-lanes.trust`, v3 gatelog/spawnlog) | `check-append-only.sh` pre-commit (`always_run`: pre-commit never hands a hook a deleted file): a staged change may only add lines at the end — a changed, removed or mid-file line, or a deleted, renamed or relinked file, is rejected; a committed journal entry is never edited (a new dated entry corrects it); corrections happen by appending. `knowledge/lessons/*` is updated in place by design — one lesson per file |
| "Evidence is script-written only" | `settings.json` denies `Edit(...)` on `.claude/evidence/**`, `.claude/done-lanes.trust`, `.claude/gitleaks.toml`, `tasks/**/donelog`, `tasks/**/pair/**`, `~/.codex/sessions/**` and v3's frozen `gatelog`/`spawnlog` (Edit rules cover Write too), and asks before an Edit of the scripts, hooks, checker agent and settings the evidence chain trusts; `bash-guard.sh` asks before any command naming the ledger or the trust file other than one allowed `evidence.sh run\|status\|show\|start\|done\|close\|lint` call, before Bash writes to a donelog, a `pair/` mailbox, Codex's session logs or those scripts and settings, and before `evidence.sh trust`, `approve`, `check`, `codex` and `run --escalated`. Under `bypassPermissions` Claude Code drops hook asks: there only the `settings.json` rules still stop for you — the Edit denies and asks, and the declarative asks for `evidence.sh trust`, `approve` and `check`. The append-only pre-commit backstops the donelog and the trust file. A tripwire against shortcuts and slips, not a sandbox against deliberate bypass: a glob, a variable or a symlink naming the script gets past bash-guard — the checker and Codex re-running lanes are the last line |
| "Sessions that die without /wrap lose their state" | session-start warns when commits are newer than `state.md` |

---

## Quick start

> Hands-on walkthrough (spawn → daily loop → `/task` → pair mode):
> **[TUTORIAL.md](./TUTORIAL.md)** · [繁中](./TUTORIAL.zh-TW.md)

### 1. Set up the global layer (once per machine)

```bash
git clone https://github.com/<your-username>/claude-starter.git
cd claude-starter
./bootstrap-machine.sh
```

The repo is self-contained: `global/CLAUDE.md` ships inside it. Re-running
later shows a diff and asks before updating `~/.claude/CLAUDE.md` (dated
backup kept); `--force-global` skips the prompt. Optional extras: bun + uv
toolchains, pre-commit + gitleaks, the PUA plugin.

### 2. Mark this repo as a GitHub template

Push to GitHub, then Settings → check "Template repository". This is what
makes `gh repo create --template` work.

### 3. Spawn a new project

```bash
./start_project.sh my-app                      # code project, private
./start_project.sh --kind research my-survey   # research framing
./start_project.sh --kind analysis my-backtest # data/analysis framing
./start_project.sh --local --kind code demo    # offline, no GitHub
```

The spawner personalizes CLAUDE.md for the chosen kind, generates a real
project README, fills dates, **removes the scaffold's own infrastructure
files** (spawned projects don't carry `start_project.sh`, this README,
etc.), installs pre-commit hooks if available, commits and pushes.

### 4. Start working

Open Claude in the project. The SessionStart hook injects `INDEX.md` +
`state.md` automatically. Work. Run `/wrap` when you stop — it writes
state, decisions, and journal entries back. Kick off anything big with
`/task <description>` — see **Long-horizon tasks** below.

### 5. Upgrading projects spawned earlier

```bash
./sync-project.sh ../my-older-project
```

Adds missing mechanism files (never overwrites) and prints suggestions for
the rest. `--update-stock` also advances provably unmodified stock copies
and deletes stock copies of files the template retired (v4 retired nine);
customized files are never touched. It ships the template's last commit
(uncommitted template edits never ride), never writes through a symlink,
and appends the template's test and build caches to `.gitignore`.

The v4 `/task` core — `settings.json`, `stop-gate.sh`, `session-start.sh`,
`spawn-log.sh`, `bash-guard.sh`, `guard-patterns.sh`, `evidence.sh`,
`task-pair.sh`, the task skill, the executor and checker agents — moves as
one unit. While any of it is customized, `--update-stock` adds, replaces
and retires none of it, prints `MIGRATION INCOMPLETE — v4 /task is not
safe until: <files> are merged by hand` and exits 2; merge those files,
then re-run (a file that keeps every template line in order, plus your
own, counts as merged). A plain sync never installs half the core either.
A sync that held the core back stamps `partial-sync:` instead of
`synced-to:`. A project with a `/task` started under v3 finishes or
abandons it first: `--update-stock` exits 1 before writing anything while
one is active (no `plan.md` yet, a `[pending]` or `[in_progress]`
milestone, or a change within 7 days). Exit codes: 0 done · 1 usage, not a
project, or an active v3 task · 2 `MIGRATION INCOMPLETE`, or
`--update-stock` from a template without git history. See
[MIGRATION.md](./MIGRATION.md).

---

## Long-horizon tasks — `/task`

Memory keeps *sessions* continuous; `/task` keeps one *big run* honest.
Since v4.0 it rests on three things instead of a planning ceremony and a
verify-running gate: a one-page card you approve, run evidence that only a
script can write, and an independent checker for every slice.

1. **Intake** — read what the request touches before asking anything; echo
   the goal; ask the one question that most changes what gets built, plus
   "what would make you reject this with every check green?"; offer 2–3
   approaches with their build and verification cost; settle empirical
   forks with a ≤30-minute throwaway; an unrequested mechanism is written
   down as "considered, not built" instead of built.
2. **Card** — `tasks/<slug>/card.md`, ≤4 KB, injected every session: goal,
   a done predicate on the running product plus an outside check, tagged
   decisions, and slices — slice 1 is the thinnest real end-to-end path,
   each names what you will see and its lanes. Detail lives in `notes.md`
   (never injected; a slice line cites its `§`). `evidence.sh lint` checks
   the format; `evidence.sh approve` records your yes behind a
   confirmation. With pair mode on, Codex checks the card first and
   `done`/`close` need that review (or your waiver); with it off, the
   checker reviews the card — a report for you, not a requirement.
3. **Lanes** — up to three per project in `.claude/done-lanes`.
   `evidence.sh trust <lane>` asks you first, refuses static checks, runs
   the canary (which must fail) and pins the hashes of the lane's line,
   the files its command and canary name, every `@` line and
   `.claude/gitleaks.toml` — change any of them and it needs your trust
   again.
4. **Slice loop** — `evidence.sh start S<n>` → a fresh `executor` builds the
   slice, runs its lanes with `evidence.sh run` and commits by path → a
   fresh `checker` gets the card, the diff and the raw records — never the
   executor's summary — and re-runs a lane of ≤10 minutes itself → Codex
   on `codex: yes` slices (pair on) → `evidence.sh done S<n>` writes `[x]`
   with the record ids, or lists what is missing.
5. **The gate** — `stop-gate.sh` runs no lane. It checks that every `[x]`
   cites a passing record and that a `Closed:` line is still fresh, waits
   while a lane run, a Codex send or a subagent is in flight, and otherwise
   prints one status line and lets the turn end. A gate bug is logged and
   allowed, never a stall.
6. **Stuck** — `/debug`: reproduce, one hypothesis per change; two failed
   fixes → write their shared premise and test it; three → stop and
   report. `evidence.sh run` enforces it: after three straight failures of
   one lane on one slice, the next run needs your confirmation (`ESCALATE`).
7. **Close** — `evidence.sh close` requires every slice `[x]`, every lane
   the card cites fresh on the final tree, nothing changed since the
   card's base outside those lanes' paths, and a final check — Codex with
   pair on (or your waiver), the checker's `final` pass with pair off —
   then your acceptance run for anything outside the repo, then `/wrap`,
   which appends the row `harness-report.sh --row` computed to
   `.ai_context/scoreboard-v4.csv` and clears `tasks/CURRENT`. Until then
   any change outside `.ai_context/` makes the `Closed:` line stale and the
   gate blocks; after it, nothing is checked any more.

State lives in `.ai_context/tasks/<slug>/` (`card.md`, `notes.md`,
`donelog`, `pair/`) and is committed, like `.claude/done-lanes` and
`.claude/done-lanes.trust`; run records and lane logs live in
`.claude/evidence/`, per machine and gitignored (nothing prunes the logs:
`find .claude/evidence/logs -mtime +30 -delete`). An `[x]` whose records
were made on another machine passes once its `DONE` row is committed.
Scores are computed from the card and the donelog, never from the model's
account.

**Lanes.** One line per lane, fixed fields, plus `@` directives:

    # name | paths | min_secs | expect (; separated, all must match) | canary | cmd
    @pair codex
    @verify-paths tests/ probes/
    smoke | . | 4 | ^verify: [1-9][0-9]* passed, 0 failed$ | <cmd that must fail> | bash scripts/verify.sh

`@pair codex` makes pair mode the project default; `@verify-paths` names
the test and probe code for the tripwire report; `@ext <lane> <cmd>`
prints the commit of an external repo a lane runs against, and `close`
checks it has not moved. The `cmd` and `canary` fields hold no `|`:
anything that needs a pipe or more than one readable command goes into a
wrapper script the lane calls. Every change a task makes must lie inside
the paths of a lane its slice cites (`smoke` takes `.`, so docs and config
are covered too), and a run must leave no untracked, unignored file in its
paths — gitignore the caches it writes, or the record is voided. Fast
paths also go into the project's `verify` skill (Claude Code runs it before
commits); slow ones (a VM, a full backtest) get their own lane and paths
and run in the background while the gate waits.

**Pair mode.** One non-Claude seat: a Codex judge in a sibling
[herdr](https://herdr.dev) pane named `judge-<repo id>-<slug>`, on your
Codex default (no model or effort is passed). Claude executes, Codex
checks — at three points: the card before work starts, each slice marked
`codex: yes` (money, secrets, installs), and the whole branch at close.
`@pair codex` in `.claude/done-lanes` is the project default (adding it
means re-trusting a lane: `@` lines are part of the trust); a card's
`pair:` header can raise it, never lower it. `scripts/task-pair.sh` is the
pen: it generates every packet (`check card`, `check slice S<n>`, `check
final`; `--since` defaults to, and must be, the slice's start head or the
card's base), starts the judge with Codex hooks off, refuses when
`AGENTS.md` or `AGENTS.override.md` differs from `CLAUDE.md`,
fingerprints the tree around every run (change nothing while one is in
flight), keeps the judge's scratch under `/tmp/pair-<repo hash>-<slug>/`
(anything new in `pair/` voids the run as `scratch_in_mailbox`), answers
only the Codex dialogs it knows — `esc` for the update notice and the
rate-limit nudge, `enter` only on "Use current Git worktree" after `/new`;
anything else stops the run for you (exit 4) — and never prints a verdict
of its own. Its run state lives in `.claude/evidence/pair/<slug>/`. The
judge answers in six fixed lines (`run:`, `verdict:`, `base:`, `blocker:
N`, `major: N`, `minor: N`) and passes only when the run completed, the
verdict is `pass`, there are no blockers or majors, and the result is
provably the judge's: its own `apply_patch` write of that file is in its
Codex transcript, its turn ended normally, and the file still says what it
wrote. Every run that reached the judge, failures included, becomes a
`codex-<stage>` record through `evidence.sh`, so `done` and `close` read
Codex's result the way they read a lane's; an attempt that never became a
turn (`not_started`) is neither recorded nor counted. Runs spend your
Codex quota, and you consent twice: starting `/task` with pair on covers
the card check and one retry; approving the card covers its estimate —
one run per `codex: yes` slice, the final run, one retry per unit and one
rebuttal round — counted from this task's Codex records. Past the estimate
`task-pair.sh` stops (exit 3) and asks; so does a re-check of content
whose last completed review failed. When Codex cannot answer (two runs
without a verdict on the same content, or no quota left), `done`/`close`
keep refusing that unit until it passes or you waive it:
`bash scripts/evidence.sh approve --waive <S<n>|card|final> --reason "…"`
— a confirmation, recorded, void once the card changes. The dialog texts
were recorded on Codex 0.165.0 and herdr 0.9.0.

**Permissions.** `evidence.sh run`, `status`, `show`, `start`, `done`,
`close` and `lint`, and `task-pair.sh check` and `wait`, are allow-listed,
so slices run unattended in the default permission mode. `trust`,
`approve` and `check` always ask: bash-guard asks, and they are also
declarative `permissions.ask` rules in `settings.json`. Under
`bypassPermissions` (`--dangerously-skip-permissions`) Claude Code drops a
hook's ask, so there only `settings.json` still stops for you — those
three rules, the `Edit` asks on the scripts, hooks, checker agent and
settings the evidence chain trusts, the `git push` / `reset --hard` /
`clean` / `sudo` / `rm -rf ~/*`-style asks, and the `Edit` denies on the
ledger, the trust file, donelogs, the pair mailbox and Codex's session
logs. bash-guard's task-time git asks, its ledger and donelog write asks,
`run --escalated` and `--over-estimate` do not fire there; its blocks
(force-push, `sudo`, `rm -rf /`) still do. None of it is a sandbox: a
glob, a variable or a symlink naming `evidence.sh` gets past bash-guard.

**Status line (opt-in).** Add
`"statusLine": {"type": "command", "command": "bash scripts/evidence.sh status --line"}`
to `.claude/settings.local.json`; the template's `settings.json` leaves
your own status line alone.

**Unattended.** `/task --auto` records intent calls as `[ASSUMED: …]`
decisions on the card instead of asking, and the close-out lists them.
Approval, trust, destructive and outward-facing steps still wait for you.
`/goal` is for convergent mechanical work only — an explicit evidence
condition and a round cap, never a direction decision.

---

## What's in the box

```
claude-starter/
├── global/CLAUDE.md            Layer 1 canonical copy (installed by bootstrap)
├── templates/
│   ├── CLAUDE.md.code          Project brief: stack, commands, Verify, DoD
│   ├── CLAUDE.md.research      Research framing: sources, evidence grades
│   ├── CLAUDE.md.analysis      Data framing: pipeline, reproducibility
│   └── README.project.md       Real README stub for spawned projects
├── .claude/
│   ├── settings.json           Hooks wiring + permission rules (tracked)
│   ├── gitleaks.toml           Lane-log scan rules: gitleaks defaults + internal IPs
│   ├── hooks/
│   │   ├── session-start.sh    Injects INDEX+state (+ task card, status line)
│   │   ├── post-edit.sh        Instant lint feedback (delegates to lint.sh)
│   │   ├── bash-guard.sh       PreToolUse tripwire (force-push/sudo/rm -rf /; ledger and task-time git asks)
│   │   ├── guard-patterns.sh   Shared matchers + task helpers + setup sentinel
│   │   ├── spawn-log.sh        executor/checker spawns → donelog + checker records
│   │   ├── stop-gate.sh        /task evidence gate — reads records, runs no lane
│   │   └── lint.sh.example     Fill in your linter after language init
│   ├── agents/                 /task crew: executor (one slice, fresh context),
│   │                           checker (independent check per slice)
│   └── skills/
│       ├── wrap/SKILL.md       /wrap — end-of-session memory write-back
│       ├── wrap/reference.md   task close-out, lessons, defects, friction rows (on demand)
│       ├── task/SKILL.md       /task — card, lanes, slice loop, close
│       ├── task/reference.md   card format, lane examples, unattended runs (on demand)
│       ├── task/pair.md        pair-codex: card / slice / final checks (on demand)
│       ├── setup/SKILL.md      /setup — first-session birth protocol, lanes
│       ├── setup/verify-template.md  template for the project's verify skill
│       ├── prove/SKILL.md      /prove — evidence before any done/fixed claim
│       ├── debug/SKILL.md      /debug — cause before fix; 2 fails → premise, 3 → stop
│       ├── defect/SKILL.md     /defect — record a defect found after done (user-invoked)
│       ├── backtest-check/SKILL.md  /backtest-check — backtest and strategy integrity
│       └── number-check/SKILL.md  /number-check — vet a measured number before reporting it
├── .ai_context/                Layer 3 (schema v4) — INDEX, state, decisions…
├── .secrets/                   Runtime-only credentials (Read-denied · gitignored)
├── .pre-commit-config.yaml     H1 secret scan + S7 size cap + S2 bulk + append-only guards
├── scripts/                    pre-commit guards + evidence.sh (lanes, records,
│                               done/close) + task-pair.sh + harness-report.sh
├── tests/run.sh                L1+L2 regression suite (runs in CI)
├── .mcp.json.example           MCP stub (kept for --kind analysis)
├── .github/workflows/lint.yml  CI for this template repo (removed on spawn)
├── start_project.sh            Spawner (validates, personalizes, cleans up)
├── bootstrap-machine.sh        Machine setup + global-layer updates
├── sync-project.sh             Upgrade projects (adds; --update-stock replaces and retires stock copies)
├── NOTICE                      Third-party MIT notices (ships into projects)
├── MIGRATION.md                v3 → v4, v2 → v3, v1 → v2, and older layouts
├── TUTORIAL.md                 Hands-on walkthrough (removed on spawn)
└── TUTORIAL.zh-TW.md           The walkthrough in Traditional Chinese (removed on spawn)
```

---

## Design principles

### Hard rules (live in every project's `INDEX.md`)

- **H1 — No secrets.** Enforced: gitleaks + read-deny on `.env*` and
  `.secrets/` (the runtime-only folder: code reads it, Claude and git don't).
- **H2 — No fact duplication.** If it's in the README or the source,
  reference it, don't copy it.
- **H3 — No speculation as fact.** Tag tentative claims `[TENTATIVE]`.
- **H4 — Right file, right purpose.** Now → `state.md`. Forever →
  `decisions.md`. This event → `journal/`.
- **L1 — No real names.** Use roles. Real names belong in `private/`, if
  anywhere.

### Soft rules (live in `global/CLAUDE.md`, → `~/.claude/CLAUDE.md`)

S1 persistence threshold · S2 externalize bulk · S3 time-stamp aging facts
· S4 no fluff · S5 no emotional content · S6 no PR/commit copies ·
S7 `state.md` ≤ 5 KB. *(S5–S7 were L2–L4 in v1.)*

### What we deliberately don't do

- **No role personas (PM / Backend / QA).** The agents that do ship are
  the two working stages of `/task` (execute a slice, check it) — inert
  unless `/task` runs. Add further task-scoped agents per project if you
  need them.
- **No planning ceremony.** v3's planner fan-out, plan critic, risk tiers,
  escalation ladder and reframer are gone: fleet data showed bigger plans
  and no measurable catch rate, while independent checks caught the bugs
  (MIGRATION, v3-final → v4.0).
- **No command router in CLAUDE.md.** Slash commands belong to the skill
  system (`/wrap` is one).
- **No pressure-prompting.** Verification loops beat exhortation; the DoD
  contract and hooks carry that weight.
- **No language toolchains baked in.** `bootstrap-machine.sh` offers bun/uv
  as an option; the scaffold itself works for code, research, analysis, or
  writing.
- **No `mkdir src/`.** Source layout is your language scaffolder's job.

---

## FAQ

**Q: Why is `.ai_context/` in git?**

Continuity across machines, contributors, and months. Commit as
`chore(context): ...` to keep it out of release-notes filters.

**Q: What happened to `.claudeignore`?**

Removed in v2 — Claude Code doesn't read that file, so it was decorative.
The real mechanism is `.claude/settings.json` permission rules (shipped)
plus Claude's own default skipping of build artifacts.

**Q: What's the difference between `.ai_context/` and Claude's native memory?**

`.ai_context/` is in-repo and shared: project truth. Native memory
(`~/.claude/...`) is per-user and cross-project: personal preferences.
`global/CLAUDE.md` tells Claude not to double-write.

**Q: Can my team use this?**

Yes — bootstrap per developer, template shared. If several people write
ADRs concurrently, switch `decisions.md` to one-file-per-ADR
(`decisions/NNN-title.md`); `INDEX.md` explains when.

**Q: I have projects on the old v1 layout (or the ancient PM/BE/FE/QA one).**

`./sync-project.sh <path>` for v1 → v2, [MIGRATION.md](./MIGRATION.md) for
the full story.

**Q: Can a project stay on v3?**

Yes. `v3-final` is tagged; run `sync-project.sh` from a `v3-final`
checkout to keep a project on v3 mechanisms, and finish any task started
under v3 there — v4 cannot continue it. v3 fixes, if any, ship from
branches cut at `v3-final`. If v4.0 itself has to go, the template rolls
back in one new commit, no force-push:
`git revert --no-commit v3-final..v4.0 && git commit` — see
[MIGRATION.md](./MIGRATION.md) §-9 Rollback for synced projects.

**Q: Can commits be scanned for internal IPs too?**

Not by default: `.claude/gitleaks.toml` (gitleaks defaults + internal-IP,
tailnet and URL-credential rules) is applied only to lane and canary logs,
and the pre-commit scan keeps gitleaks' own config lookup. To apply the
same rules at commit time, add a repo-root `.gitleaks.toml`:

```toml
[extend]
path = ".claude/gitleaks.toml"
```

gitleaks runs that look up their config at the repo root — the
pre-commit scan, `gitleaks dir .` — then read it (`evidence.sh` keeps
passing `.claude/gitleaks.toml` itself), so scan your tracked files once
(`gitleaks dir .`) before you commit it.

---

## License

MIT (or whatever you prefer — pick before going public). Files adapted
from third-party projects are listed with their MIT notices in
[NOTICE](./NOTICE).
