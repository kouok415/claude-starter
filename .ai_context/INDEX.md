<!-- schema: v2 -->
<!--
purpose: Registry of .ai_context/ — what's here, when to read, when to write.
mutability: edit when adding or removing files; otherwise stable.
format: keep sections in this order; keep entries terse.
do-not: don't put project content here, only meta-information about other files.
-->

# .ai_context Index

This directory is Claude's persistent project memory. Each file declares its
own rules in a top-of-file HTML-comment preamble — read it before writing.

---

## Reading protocol

**On every session start, read in this order:**

1. `INDEX.md` — this file.
2. `state.md` — current project snapshot.

In projects spawned from claude-starter v2 this is mechanized: a SessionStart
hook (`.claude/hooks/session-start.sh`) injects both files automatically — on
startup, resume, `/clear`, and after compaction. If hooks are disabled, do it
manually.

**Then read on-demand based on the situation:**

| If the situation is... | Read |
|---|---|
| Making a design choice, picking between options, choosing a dependency | `decisions.md` (check existing ADRs first) |
| Touching the API, adding endpoints, changing contracts | `knowledge/api-spec.md` |
| Code review, opening a PR, writing new code | `knowledge/conventions.md` |
| Encountering an unfamiliar domain term | `knowledge/glossary.md` |
| User asks about a past event, debate, retro, or specific date | search `journal/` for matching `YYYY-MM-DD-*.md` |
| User mentions sensitive scratch, untriaged data, or local-only notes | `private/` |

**Do not auto-read** `journal/` or `knowledge/` files unless triggered. They
exist for retrieval, not for warmup.

**Procedural knowledge routes itself:** when a `knowledge/` file describes
*how to do something* (a runbook, a coding pattern, a release checklist),
prefer promoting it to a skill under `.claude/skills/<name>/SKILL.md` with a
trigger description — skills load on demand without anyone remembering this
table. Keep *factual* reference (API contracts, glossaries) in `knowledge/`.

---

## Writing protocol

| File / dir | Mutability |
|---|---|
| `state.md` | overwrite-friendly; reflects *now* only |
| `decisions.md` | append-only; never edit existing entries |
| `knowledge/*.md` | accumulate; edit factual updates, don't rewrite history |
| `journal/*.md` | append-only per file; new file per event; first line = one-sentence summary |
| `private/*` | free-form; gitignored |

Before writing to any file, read its top preamble for format and `do-not`
rules. At the end of a significant session, run `/wrap` (or update `state.md`
by hand) — a reading protocol without write-back is only half the loop.

---

## Forbidden (hard rules — never violate)

- **H1 — No secrets.** Never write API keys, tokens, passwords, connection
  strings, or internal URLs. Not even as placeholders. If a secret is needed
  to make a point, write `<redacted>` and reference where the real value
  lives (e.g., "in `.env`, see `.env.example`").
- **H2 — No fact duplication.** If a fact exists in `README.md`, source
  code, type signatures, or commit history, do not copy it here. Reference
  it by path or link. Duplication creates drift.
- **H3 — No speculation as fact.** Tentative claims must be tagged
  `[TENTATIVE]` or `[HYPOTHESIS]`. When confirmed, remove the tag.
  Untagged statements are facts and are trusted as such.
- **H4 — Right file, right purpose.** Before writing, ask: is this *now*
  (state.md), *permanent* (decisions.md / knowledge/), or *this event*
  (journal/)? Wrong placement is worse than no entry — it pollutes the
  category.
- **L1 — No real names.** Don't write real customer, employee, or external
  contact names. Use roles (`PM`, `customer-A`, `vendor-X`). Real names
  belong in private/ at most, never in tracked files.

---

## Mechanisms

Where possible, the rules above are enforced mechanically (v2 projects):

| Mechanism | Enforces |
|---|---|
| `.claude/hooks/session-start.sh` | reading protocol; warns on stale `state.md` (S3) and >5 KB (S7) |
| `/wrap` skill (`.claude/skills/wrap/`) | write-back of state / ADRs / journal |
| `.claude/hooks/post-edit.sh` + `lint.sh` | instant lint feedback after every edit |
| `.pre-commit-config.yaml` | H1 secret scan (gitleaks) + S7 size cap at commit time |
| `.claude/settings.json` permissions | denies reading `.env*` and key files (H1) |

Prose is the spec; mechanisms are the guarantee. If you change a rule,
change its mechanism too.

---

## File registry

| Path | Mutability | Purpose |
|---|---|---|
| `INDEX.md` | edit on add/remove | This registry |
| `state.md` | overwrite | Current snapshot: in-progress work, next steps, constraints |
| `decisions.md` | append-only | ADR log of design decisions |
| `knowledge/api-spec.md` | accumulate | API contracts (create when project has APIs) |
| `knowledge/conventions.md` | accumulate | Code patterns, naming, layout (create as patterns emerge) |
| `knowledge/glossary.md` | accumulate | Domain terms (create when domain has jargon) |
| `journal/YYYY-MM-DD-*.md` | append-only per file | Per-event records: debates, retros, post-mortems, findings |
| `private/*` | free-form | Sensitive scratch, gitignored, not committed |

**Files in `knowledge/` are created on-demand**, not upfront. Don't create
empty stubs. Add a file when you have real content for it, and add a row to
this registry.

**Teams with concurrent ADR writers:** the single `decisions.md` will merge-
conflict; switch to `decisions/NNN-<slug>.md` (one file per ADR) and note the
switch here.
