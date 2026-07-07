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
| "No secrets in commits" (H1) | gitleaks pre-commit hook + `settings.json` denies reading `.env*` |
| "state.md stays under 5 KB" (S7) | pre-commit size check + session-start warning |
| "Time-stamp aging facts" (S3) | session-start hook warns when `state.md` is stale |
| "Verify before claiming done" | **Stop gate**: on `/task` runs, the active milestone's verify command must pass before a turn may end; plus the `Verify` + **Definition of done** contract in CLAUDE.md and the optional `lint.sh` post-edit hook |
| "Long tasks decay — drift, silent errors, lost state" | `/task` harness: milestone plan with executable gates, fresh executor context per milestone, adversarial verifier, escalation ladder, commit per gate |

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
2. **Plan fusion** — 3 `planner` agents (different lenses) → red-team
   `plan-critic` → a synthesized `plan.md` of small milestones, each with a
   `verify:` command.
3. **Milestone loop** — fresh `executor` context per milestone, adversarial
   `verifier` after it, a commit per passed gate, drift check every third
   milestone.
4. **Stop gate** — `stop-gate.sh` re-runs the active milestone's verify when
   the turn tries to end; a red gate means the turn *cannot* end. The
   Definition of done stops being prose.
5. **Escalation** — retry differently → 3 divergent worktree attempts →
   `reframer` rewrites the problem → stop and report (three strikes).

State lives in `.ai_context/tasks/<slug>/` (`spec.md`, `plan.md`,
`lessons.md`) and is re-injected after `/clear` and compaction, so the run
survives context loss. On completion `/wrap` archives a scoreboard (profile,
gates failed, highest rung used) to `journal/` — the data for judging
whether the harness earns its keep.

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
│   │   ├── stop-gate.sh        /task milestone gate — no stop on red verify
│   │   └── lint.sh.example     Fill in your linter after language init
│   ├── agents/                 /task crew: planner, plan-critic, executor,
│   │                           verifier, reframer (fresh-context stages)
│   └── skills/
│       ├── wrap/SKILL.md       /wrap — end-of-session memory write-back
│       └── task/SKILL.md       /task — long-horizon milestone harness
├── .ai_context/                Layer 3 (schema v2) — INDEX, state, decisions…
├── .pre-commit-config.yaml     H1 secret scan + S7 size cap
├── scripts/                    pre-commit helper scripts (kept in projects)
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

- **H1 — No secrets.** Enforced: gitleaks + read-deny on `.env*`.
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
