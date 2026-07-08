---
name: setup
description: First-session protocol for a newly spawned (or newly adopted) claude-starter project — interview the human for intent, scaffold the stack, draft CLAUDE.md/README/state.md for review, wire mechanisms, commit. Use when CLAUDE.md still contains template placeholders, when the session-start hook says SETUP REQUIRED, or when the user says /setup, "set up this project", or "初始化專案".
---

# /setup — project birth protocol

Goal: after one run, the project knows what it is (CLAUDE.md), the human has
reviewed the two lines that encode intent (**Verify** and **Definition of
done**), and the mechanisms are live. You do the writing; the human does a
2-minute review.

## 1 · Interview — one round, batched

Ask only what the code cannot tell you, in ONE message:

- What is this project? (what / for whom / what does success look like)
- Stack preference, or "you pick" (skip if code already exists)
- What does "working" look like → seeds the Verify command and the DoD bars

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
  sentinel comment — the setup gate keys on it.
- `README.md` — from the interview, not boilerplate.
- `state.md` — Now: "project bootstrapped"; Next steps: the first 1–3 real
  milestones from the interview.
- `decisions.md` — if a stack was chosen, record ADR-001 with the why.

Then tell the human exactly what to review: the CLAUDE.md diff — especially
Verify and DoD; those two carry the intent everything downstream enforces.

## 4 · Mechanism check

- hooks executable; pre-commit installed if available.
- Run the drafted Verify command once — it must actually pass today, even
  if it only proves a hello-world skeleton.

## 5 · Commit and hand off

- `chore: set up project (interview + scaffold + brief)`
- Report: what was set up, what to review, and suggest the first `/task`.

## Rules

- The Stop gate blocks the first turn-end while CLAUDE.md placeholders
  remain — writing the draft clears it. If the human explicitly declines
  setup, say so and finish; the gate yields after one block and re-arms
  next session.
- Don't invent intent. Anything the human didn't say and the code doesn't
  show is a question, not an assumption.
