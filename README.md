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
human forgetfulness. A fifth layer turns big jobs into gated milestone runs:
`/task` plans, executes, and verifies long-horizon work that a single
context could not reliably survive.

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
│ Layer 5 — Execution     /task + stop gate + agents       │
│   Long-horizon harness: milestone plans, fresh-context   │
│   executors, adversarial verify, enforced gates.         │
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
| "No secrets in commits" (H1) | gitleaks pre-commit hook + `settings.json` denies reading `.env*` and `.secrets/**` |
| "Secrets are runtime-only: code may read them, Claude and git may not" | the `.secrets/` folder — Read tool denied (`settings.json`), bash access downgraded to a confirmation (`bash-guard.sh`), gitignored except the placeholder; execution-time reads (`GOOGLE_APPLICATION_CREDENTIALS=.secrets/sa.json ...`) untouched. Hard on the Read tool, a tripwire elsewhere — code that can read a secret can always leak it, so don't echo secrets to stdout |
| "state.md stays under 5 KB" (S7) | pre-commit size check + session-start warning |
| "Time-stamp aging facts" (S3) | session-start hook warns when `state.md` is stale |
| "Verify before claiming done" | **Stop gate**: on `/task` runs, the active milestone's verify command must pass before a turn may end (unchanged tree = cached PASS, no re-run); plus the `Verify` + **Definition of done** contract in CLAUDE.md and the optional `lint.sh` post-edit hook. The gate arms only while a `/task` is active — work big enough to need one should *be* a `/task`. Two consecutive red stops block; the third hands off (next row) |
| "A red gate must reach the human, not die in the transcript" | counted yields: the third consecutive red stop per (session, milestone) exits 0 with a `STUCK` gatelog row and a `{"systemMessage"}` surfaced in the UI — three failed attempts is the three-strikes rule, and the handoff is visible instead of a silent pass-through. `PASS` resets the streak; `/wrap --sweep` never yields; model-fixable blocks (status typos, forbidden verifies) keep blocking. One `STUCK` row per (session, milestone) — later stops repeat the `systemMessage`, never the row, so the scoreboard counts one handoff as one (v3.10) |
| "`[in_progress]` must prove the executor actually started" | `spawn-log.sh` on `SubagentStart` appends hook-written rows to `tasks/<slug>/spawnlog` (Edit/Write-denied; matchers route `executor` vs scout/planner/…, no payload parsing); a red M/L milestone with intake rows but no executor row makes the gate redirect to rung 1 ("spawn it") instead of the escalation ladder — never-started and tried-but-failed stop being indistinguishable after compaction |
| "The re-anchor pays for the current milestone, not the whole plan" | session-start injects a filtered plan.md view — header + all headings + verify/risk lines + the full `[in_progress]` section; self-declares as filtered, warns past 8 KB. Forward constraints live in the *target* milestone's comment block (SKILL rule), so they surface exactly when it arms instead of renting context every session |
| "Long tasks decay — drift, silent errors, lost state" | `/task` harness: milestone plan with executable gates, fresh executor context per milestone, adversarial verifier, escalation ladder, commit per gate |
| "A new project's first session sets it up" | session-start `SETUP REQUIRED` instruction + Stop gate blocks the first turn-end (once per session); both key on the `claude-starter: UNCONFIGURED` sentinel in CLAUDE.md, which `/setup` deletes when the draft lands |
| "Discovery is paid once, not once per subagent" | `scout` agent writes `tasks/<slug>/brief.md` at intake; session-start injects it; every later context navigates by it and appends corrections instead of re-surveying |
| "Ceremony scales with the task, verification with the risk" | `/task` records size (S/M/L) in the plan header — S plans and executes inline; each milestone's `risk:` picks gate-only / light / full verification |
| "A status typo must not silently disarm the gate" | session-start warns on `[pending]`-without-`[in_progress]`; the Stop gate blocks the mid-flight case (`[done]`+`[pending]`, none in progress) once per session |
| "The milestone gate can never be silently off" | every other dark-gate state — empty/corrupt `CURRENT`, missing or heading-less plan.md, an `[in_progress]` milestone with no verify command, task work off `task/*` branches (main/master or any other: the verify would run against the wrong tree) — interrupts once per session, and EVERY detection appends an `INTEGRITY` gatelog row (log-always since v3.10 — a second dark state in the same session still reaches the trail): a quiet gatelog provably means a clean run |
| "A one-turn task must not leave an empty audit trail" | zero-stop sweep at the all-`[done]` state (and via `stop-gate.sh --sweep`, which `/wrap` runs before deleting `CURRENT`): the final milestone's verify RUNS — red blocks every time — and earlier rowless gates get `UNARMED` rows: recorded vacuity, never fake evidence |
| "Verify commands are audited, not just executed" | every gatelog row records the exact command that was enforced (mid-run weakening is visible); the final panel audits `git log -p -- spec.md` for quietly weakened acceptance criteria |
| "Verify commands can't do catastrophic ops unattended" | Stop-gate denylist: a verify containing `sudo`, `git push`, or a recursive force delete on an absolute path is never executed — always blocked, always logged. Matchers are spelling-tolerant (`-fr`, split flags, multi-space all refused alike) and live once in `guard-patterns.sh`, shared with `bash-guard.sh` so the two layers cannot drift (v3.10) |
| "Catastrophic bash never runs unattended" (never force-push, no sudo) | `bash-guard.sh` PreToolUse tripwire: force-push in any spelling (flags or `+refspec`) / `sudo` / root deletes (incl. `--no-preserve-root`, v3.10) denied and logged to `private/bash-guard.log`; absolute-path `rm -rf` and `.env` access downgraded to a confirmation; declarative `ask`/`deny` mirrors in `settings.json`. Contains-matching beats prefix rules — but it is a tripwire, not a sandbox |
| "A `--local` spawn never exports local state" | the copy is `git archive HEAD` — tracked content only: gitignored credentials (`.secrets/`), local settings, untracked scratch stay home; uncommitted template edits don't ride either (commit first). Non-git sources fall back to `cp -R` + purge of the known leak homes (v3.10) |
| "Failed and abandoned runs reach the dataset too" | `/wrap` writes the scoreboard row on abandonment as well (`outcome` pinned to `success\|failed\|abandoned`), plus `duration_min` from git timestamps — no survivor bias |
| "Every scoreboard row names the harness that produced it" | `/wrap` fills the `harness` column from the last `claude-starter@<ref>` stamp in `.claude/.starter-version`; releases are git-tagged, so ref→version mapping is mechanical. The stamp tells the truth (v3.10): ANY sync that changed mechanisms appends a `synced-to:` stamp (not just `--update-stock`), and GitHub-mode spawns stamp the template head actually cloned, not the possibly-stale spawner checkout |
| "Harness friction is data, not vibes" | `/wrap` appends enum rows (`area` × `severity`) to `.ai_context/friction.csv` only when a mechanism actually misbehaved; `harness-report.sh` joins them with the gatelog's `INTEGRITY` rows |
| "Scoring is computed, never recalled" | `scripts/harness-report.sh` (CI-tested) computes outcome/gate/escalation/cost aggregates per harness version; percentages are suppressed below N=5; no composite score exists, on purpose |
| "Scoring data is cross-checked, not trusted" | `harness-report.sh` `== integrity` section: scoreboard↔gatelog `gate_failures` mismatches, orphan task dirs (runs that never reached the scoreboard), missing PASS/UNARMED evidence, enum violations — surfaced, never auto-repaired |
| "Always-injected files stay small" | 4 KB warnings for `brief.md`/`lessons.md`, 5 KB pre-commit cap + warning for `state.md` (S7), size-guard test on `INDEX.md` itself + a session-start warning when a project's copy outgrows 4 KB |
| "Externalize bulk" (S2) | `check-context-bulk.sh` pre-commit: any staged `.ai_context` file over 100 KB blocks — dumps are referenced, not pasted |
| "Scoreboard numbers must be real" | the Stop gate writes a `gatelog` per real run; `/wrap` aggregates it into `scoreboard.csv` |
| "Append-only files are never rewritten" (decisions, journal, scoreboard, friction, gatelog) | `check-append-only.sh` pre-commit: staged edits or deletions of existing lines are rejected; corrections happen by appending. `lessons.md`/`brief.md` stay rewritable — `/wrap` distills them by design |
| "gatelog and spawnlog are hook-written only" | `settings.json` denies Edit/Write on `tasks/*/gatelog` and `tasks/*/spawnlog`; the append-only pre-commit backstops both (v3.10 — the two evidence trails get equal protection at both layers; raw Bash appends remain possible — tripwire, not sandbox) |
| "Sessions that die without /wrap lose their state" | session-start warns when commits are newer than `state.md` |

---

## Quick start

> Hands-on walkthrough (spawn → daily loop → `/task` → profiles):
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

Adds missing mechanism files (never overwrites), and prints suggestions for
the rest. See [MIGRATION.md](./MIGRATION.md).

---

## Long-horizon tasks — `/task`

Memory keeps *sessions* continuous; `/task` keeps a single *big run* alive.
It converts "one heroic context" into a gated pipeline:

1. **Spec** — acceptance criteria as executable checks, or it doesn't start.
2. **Scout** — one survey pass writes `brief.md`, the map every later
   context navigates by. Contexts stay fresh for judgment independence;
   facts are inherited, never re-derived.
3. **Plan** — ceremony scales with recorded task size: **S** drafts inline
   (no spawns), **M** = 1 `planner` + red-team `plan-critic`, **L** = 3
   planner lenses + critic. Small milestones, each with a `verify:` command
   and a `risk:` grade.
4. **Milestone loop** — S executes in the main context; M/L spawn a fresh
   `executor` per milestone. Verification depth follows risk: `low` = the
   mechanical gate only, `med` = light diff review, `high` = full
   adversarial `verifier`. A commit per passed gate.
5. **Stop gate** — `stop-gate.sh` re-runs the active milestone's verify when
   the turn tries to end; a red gate means the turn *cannot* end (an
   unchanged tree hits the PASS-cache instead of re-running). The
   Definition of done stops being prose.
6. **Escalation** — retry differently → 3 divergent worktree attempts →
   `reframer` rewrites the problem → stop and report (three strikes).

State lives in `.ai_context/tasks/<slug>/` (`spec.md`, `plan.md`,
`brief.md`, `lessons.md`) and is re-injected after `/clear` and compaction,
so the run survives context loss. On completion `/wrap` appends a
scoreboard row (profile, size, gates failed, highest rung used) — the data
for judging whether the harness earns its keep.

**Profiles.** The protocol is model-tier aware: the reliability core (gate,
state, verification) is always fully on, while milestone size, planner
fan-out, and the escalation path scale with the tier — detected at intake,
frozen into the task's `plan.md`, overridable with `Task profile:` in the
project CLAUDE.md. A `mixed` setup (strong model orchestrates, cheaper tier
executes) is one frontmatter line: `model: opus` in
`.claude/agents/executor.md`. Mid-task model switches are never silent —
remaining milestones get re-cut explicitly.

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
│   ├── hooks/
│   │   ├── session-start.sh    Injects INDEX+state (+ active task plan)
│   │   ├── post-edit.sh        Instant lint feedback (delegates to lint.sh)
│   │   ├── bash-guard.sh       PreToolUse tripwire (force-push/sudo/rm -rf /)
│   │   ├── guard-patterns.sh   Shared destructive-op matchers + setup sentinel
│   │   ├── spawn-log.sh        SubagentStart evidence rows → tasks/*/spawnlog
│   │   ├── stop-gate.sh        /task milestone gate — no stop on red verify
│   │   └── lint.sh.example     Fill in your linter after language init
│   ├── agents/                 /task crew: scout, planner, plan-critic,
│   │                           executor, verifier, reframer
│   └── skills/
│       ├── wrap/SKILL.md       /wrap — end-of-session memory write-back
│       ├── task/SKILL.md       /task — long-horizon milestone harness
│       ├── task/reference.md   worktree protocol + profile knobs (on demand)
│       └── setup/SKILL.md      /setup — first-session birth protocol
├── .ai_context/                Layer 3 (schema v3) — INDEX, state, decisions…
├── .secrets/                   Runtime-only credentials (Read-denied · gitignored)
├── .pre-commit-config.yaml     H1 secret scan + S7 size cap
├── scripts/                    pre-commit helper scripts (kept in projects)
├── tests/run.sh                L1+L2 regression suite (runs in CI)
├── .mcp.json.example           MCP stub (kept for --kind analysis)
├── .github/workflows/lint.yml  CI for this template repo (removed on spawn)
├── start_project.sh            Spawner (validates, personalizes, cleans up)
├── bootstrap-machine.sh        Machine setup + global-layer updates
├── sync-project.sh             Upgrade existing projects (add-only, safe)
├── MIGRATION.md                v2 → v3, v1 → v2, and older layouts
└── TUTORIAL.md / .zh-TW.md     Hands-on walkthrough (removed on spawn)
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
  *functional stages* of the `/task` loop (plan, critique, execute, verify,
  reframe) — inert unless `/task` runs. Org-chart personas stay out; add
  further task-scoped agents per project if you need them.
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

---

## License

MIT (or whatever you prefer — pick before going public).
