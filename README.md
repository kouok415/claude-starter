# claude-starter

**English** · [繁體中文](./README.zh-TW.md)

> A language-agnostic project scaffold for working with Claude Code,
> with structured persistent memory baked in.

When you work with Claude across many sessions, two things go wrong:

1. **Claude forgets between sessions.** Decisions made on Tuesday vanish
   by Thursday. You re-explain. Claude re-discovers. Time leaks.
2. **The fix is usually a `CLAUDE.md` and a notes folder, glued together
   ad-hoc.** Each project ends up with a different layout. Rules drift.
   Sensitive data leaks into commits. Nobody knows what to read first.

`claude-starter` is the same fix, but designed once and reused: a
three-layer architecture that gives Claude consistent project memory across
every project, every machine, every collaborator.

---

## The architecture

```
┌──────────────────────────────────────────────────────────┐
│ Layer 1 — Global       ~/.claude/CLAUDE.md               │
│   Engineering principles, .ai_context schema, soft rules │
│   Loaded for every project, every session.               │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 2 — Project      <project>/CLAUDE.md               │
│   Stack, commands, project-specific rules. 30–60 lines.  │
│   What's true here that isn't true everywhere.           │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 3 — Project memory       <project>/.ai_context/    │
│   ├── INDEX.md      Registry: where things live          │
│   ├── state.md      Now (mutable)                        │
│   ├── decisions.md  Forever (append-only ADR log)        │
│   ├── knowledge/    Long-term reference                  │
│   ├── journal/      Per-event records (dated)            │
│   └── private/      Sensitive scratch (gitignored)       │
└──────────────────────────────────────────────────────────┘
```

Each layer answers one question:

- **Global:** how should Claude *think and behave*?
- **Project:** what is *this project*?
- **Project memory:** what has *already happened*, and what's *true now*?

The split is deliberate. It lets the same architecture serve software
projects, log analysis, research notes, or writing — without role-specific
machinery getting in the way.

---

## Quick start

### 1. Set up the global layer (once per machine)

Clone this repo and run the bootstrap:

```bash
git clone https://github.com/<your-username>/claude-starter.git
cd claude-starter
./bootstrap-machine.sh
```

That installs `~/.claude/CLAUDE.md` (engineering principles) and optionally
the [PUA plugin](https://github.com/tanweai/pua) — a third-party Claude
Code plugin that escalates when Claude is about to give up, gets stuck, or
detects user frustration. Auto-triggers; manually `/pua`.

### 2. Mark this repo as a GitHub template

Push this repo to GitHub, then in the repo Settings → check
"Template repository". This is what makes `gh repo create --template`
work below.

### 3. Spawn a new project

```bash
./start_project.sh my-new-project
```

This creates a new GitHub repo from the template, clones it, and fills in
the project name. Then run your language's init command in the new
directory (`npm init`, `uv init`, `cargo init`, `flutter create .`, or
nothing for a research / docs / log-analysis project — the starter is
language-agnostic on purpose).

### 4. Start working

Open Claude in the project. On every session it will:

1. Read `./.ai_context/INDEX.md`
2. Read `./.ai_context/state.md`
3. Read other files only when their trigger conditions in INDEX match

That's the whole protocol.

---

## What's in the box

```
claude-starter/
├── CLAUDE.md.template      Project brief — fill in stack, commands, rules
├── .gitignore              Ships with AI-aware ignores; append language ones
├── .claudeignore           What Claude shouldn't bother scanning
├── .ai_context/
│   ├── INDEX.md            Read-first registry, with the hard rules
│   ├── state.md            Current snapshot template
│   ├── decisions.md        ADR log template
│   ├── knowledge/          Empty; add files as patterns emerge
│   ├── journal/            Empty; YYYY-MM-DD-<topic>.md per event
│   └── private/            Gitignored scratch — Claude reads, git doesn't
├── start_project.sh        Template-based project spawner
├── bootstrap-machine.sh    One-time machine setup
├── MIGRATION.md            For projects coming from other layouts
└── README.md               You are here
```

---

## Design principles

### Hard rules (live in every project's `INDEX.md`)

- **H1 — No secrets.** Not even placeholder ones.
- **H2 — No fact duplication.** If it's in the README or the source,
  don't copy it. Reference it.
- **H3 — No speculation as fact.** Tag tentative claims `[TENTATIVE]`.
- **H4 — Right file, right purpose.** Now → `state.md`. Forever →
  `decisions.md`. This event → `journal/`.
- **L1 — No real names.** Use roles. Real names belong in `private/`,
  if anywhere.

### Soft rules (live in `~/.claude/CLAUDE.md`)

- **S1** — Persistence threshold: write only what the *next* session
  needs.
- **S2** — Externalize bulk content (>200 lines) by reference, not paste.
- **S3** — Time-stamp anything that ages.
- **S4** — No fluff. State *why*, not "looks great".
- **L2** — No emotional content.
- **L3** — No PR/commit description copies.
- **L4** — `state.md` size cap: 5 KB. Archive to `journal/` when it grows.

### What we deliberately don't do

- **No role personas (PM / Backend / Frontend / QA).** They tied previous
  layouts to one workflow (software dev). Removed.
- **No command router (`!plan`, `!review`, etc.).** Slash commands belong
  in the slash-command system, not in `CLAUDE.md`.
- **No Discord / chat-platform conventions.** Plug-in concern.
- **No hard dependency on third-party plugins.** If you have ECC or
  similar, great — but the architecture works without them.
- **No `mkdir src/` baked in.** Source layout is decided by your
  language's scaffolding tool, not by us.

---

## FAQ

**Q: Why is `.ai_context/` in git? Won't it pollute the repo?**

It's in git so Claude has continuity across machines, contributors, and
months. The cost is one folder of small markdown files; the benefit is
that "what we decided in March" survives. Use commit type
`chore(context): ...` to keep these out of release-notes filters.

**Q: What if I have secrets or sensitive notes?**

Three layers of protection: (1) `.ai_context/private/` is gitignored;
(2) `H1` forbids writing secrets anywhere; (3) `L1` forbids real names.
Audit before pushing public repos.

**Q: Do I have to use the helper scripts?**

No. They're conveniences. You can clone the template manually, copy files
by hand, whatever. The architecture is just files and conventions.

**Q: How does this compare to plain `CLAUDE.md`?**

Plain `CLAUDE.md` covers Layer 2 only. This adds Layer 1 (cross-project
defaults) and Layer 3 (persistent memory). The point is what plain
`CLAUDE.md` *can't* do: remember decisions across sessions, share
conventions across projects, separate volatile state from permanent ones.

**Q: I have a project on the old multi-agent layout. How do I migrate?**

See [`MIGRATION.md`](./MIGRATION.md). It's a step-by-step from PM/BE/FE/QA
+ ECC + Discord layouts to this one.

**Q: Can my team use this?**

Yes. `bootstrap-machine.sh` is per-developer; the template repo is shared.
Everyone gets the same global principles, every project gets the same
memory layout.

---

## License

MIT (or whatever you prefer — pick before going public).
