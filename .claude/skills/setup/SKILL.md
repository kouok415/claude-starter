---
name: setup
description: First-session protocol for a newly spawned (or newly adopted) claude-starter project — interview the human for intent, scaffold the stack, draft CLAUDE.md/README/state.md for review, wire mechanisms, commit. Use when CLAUDE.md still contains template placeholders, when the session-start hook says SETUP REQUIRED, or when the user says /setup, "set up this project", or "初始化專案".
---

# /setup — project birth protocol

Goal: after one run, the project knows what it is (CLAUDE.md), the human has
reviewed the two lines that encode intent (**Verify** and **Definition of
done**), and the mechanisms are live. You do the writing; the human does a
2-minute review.

**Already configured** (CLAUDE.md has no `claude-starter: UNCONFIGURED`
sentinel — e.g. a project `sync-project.sh` brought to v4): skip §1–§3;
never re-interview or re-draft its documents. Do §4–§5 only, asking just
what the lanes need (what proves the product works, `@pair`).

## 1 · Interview — one round, batched

Ask only what the code cannot tell you, in ONE message:

- What is this project? (what / for whom / what does success look like)
- Stack preference, or "you pick" (skip if code already exists)
- What does "working" look like → seeds the Verify command, the smoke lane
  and the DoD bars
- Codex cross-checks for /task (card, risky slices, close; spends your
  Codex quota)? Ask only when herdr and codex are on PATH; the answer
  becomes `@pair codex|off` in §4.

If the codebase already exists (adopted project), survey it first and ask
only about intent and bars. If the user already stated intent when opening
the session, don't re-ask — proceed on what they said.

## 2 · Scaffold (skip whatever already exists)

- **code kind:** run the language init (uv init / npm create / cargo init
  ...) per the interview; `cp .claude/hooks/lint.sh.example
  .claude/hooks/lint.sh` and wire the project's linter; prove the toolchain
  with one smoke command and show its output.
- **research / analysis kinds:** create the data/reports layout instead,
  and register sources with reliability grades in CLAUDE.md's Sources
  table.

## 3 · Draft the documents (write them, then ask for review)

- `CLAUDE.md` — stack, commands, **Verify** (end-to-end proof, not just the
  test suite), **Definition of done** (project-specific bars). Clear every
  template placeholder AND delete the `claude-starter: UNCONFIGURED`
  sentinel comment — the setup gate keys on it. A Verify proves use, not
  liveness: "ready" means a real request succeeds, not that the process
  answered; it checks side effects too (file written, row inserted,
  message sent); a dry-run flag counts only once you saw what it skips.
  The Verify command is the smoke lane's cmd (§4) — keep the two identical.
- `README.md` — from the interview, not boilerplate.
- `state.md` — Now: "project bootstrapped"; Next steps: the first 1–3 real
  tasks from the interview.
- `decisions.md` — if a stack was chosen, record ADR-001 with the why.

Then tell the human exactly what to review: the CLAUDE.md diff — especially
Verify and DoD; those two carry the intent everything downstream enforces.

## 4 · Mechanisms — run skill, verify skill, lanes

1. Hooks executable; pre-commit installed if available.
2. Something to run (an app, CLI, service or pipeline)? Invoke
   `/run-skill-generator` to write the project's run skill (setup, env,
   build, launch, expected output, gotchas). Follow it once from a clean
   shell and fix what it got wrong. Research/analysis with no runnable
   product: skip.
3. Copy `.claude/skills/setup/verify-template.md` to
   `.claude/skills/verify/SKILL.md` and fill every `<…>`: Surface, Launch,
   Doctor, one Drive journey, Evidence, `Lane: smoke`. Only steps that
   finish in a few minutes — Claude Code runs this skill before every
   commit. Never add `disable-model-invocation`.
4. Declare lanes in `.claude/done-lanes` (≤3; format and recipes:
   `.claude/skills/task/reference.md` §Lanes): `smoke` runs the Verify
   command on paths `.` (the whole repo, so doc and config edits are
   proven too); each slow path (VM, full backtest, remote target) is its
   own lane naming its own paths. A run must leave no untracked, unignored
   file inside its paths: gitignore the caches it writes. Add
   `@pair codex|off` from the interview and
   `@verify-paths <dirs holding test or probe code>`.
5. Trust each lane: `bash scripts/evidence.sh trust <lane>` — the human
   approves the prompt and the canary must go red. A refusal (static
   command, empty expect, `min_secs` 0) means fix the lane, never the
   script.
6. First run: `bash scripts/evidence.sh run <lane>` per lane, then
   `bash scripts/evidence.sh show <lane>`. It must pass today, even if it
   only proves a hello-world skeleton. Stamp the verify skill's `Proven:`
   line (date · commit · journey · record id).

## 5 · Commit and hand off

- `chore: set up project (interview + scaffold + lanes)` (lanes only:
  `chore: declare lanes`) — stage by path:
  CLAUDE.md, README.md, .ai_context/, .claude/done-lanes,
  .claude/done-lanes.trust, .claude/skills/verify/, the run skill; never
  `git add -A`.
- Report: what was set up, what to review, and suggest the first `/task`.

## Rules

- The Stop gate blocks the first turn-end while CLAUDE.md placeholders
  remain — writing the draft clears it. If the human explicitly declines
  setup, say so and finish; the gate yields after one block and re-arms
  next session.
- Don't invent intent. Anything the human didn't say and the code doesn't
  show is a question, not an assumption.
