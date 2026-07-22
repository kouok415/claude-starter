<!-- schema: v3 -->
<!--
purpose: Registry of .ai_context/ — what's here, when to read, when to write.
mutability: edit when adding or removing files; otherwise stable.
do-not: no project content here — only meta-information about other files;
        keep this file ≤ 4 KB (it is injected into every session).
-->

# .ai_context Index

Claude's persistent project memory. Each file declares its own rules in a
top-of-file HTML-comment preamble — read it before writing. This file and
`state.md` are auto-injected at every session start (hooks); read the rest
**on-demand**:

| Situation | Read |
|---|---|
| Design choice, picking between options, dependency pick | `decisions.md` (check existing ADRs first) |
| Touching the API, changing contracts | `knowledge/api-spec.md` |
| Code review, PR, writing new code | `knowledge/conventions.md` |
| Unfamiliar domain term | `knowledge/glossary.md` |
| Past event, debate, retro, specific date | search `journal/YYYY-MM-DD-*.md` |
| Sensitive scratch, local-only notes | `private/` |
| Active `/task` (`tasks/CURRENT` exists) | that task's `brief.md` + `plan.md` + `lessons.md` (auto-injected too) |

Don't warm up on `journal/` or `knowledge/` — they exist for retrieval.
Procedural knowledge (runbooks, checklists, how-tos) belongs in a skill
(`.claude/skills/<name>/SKILL.md`), which loads itself on demand; keep
factual reference (contracts, glossaries) in `knowledge/`.

## Writing protocol

| File / dir | Mutability |
|---|---|
| `state.md` | overwrite; reflects *now* only; ≤5 KB (S7) |
| `decisions.md` | append-only ADRs; never edit existing entries |
| `knowledge/*.md` | accumulate; create on demand (no empty stubs), add a row here |
| `journal/*.md` | append-only; one file per event; first line = one-sentence summary |
| `tasks/<slug>/spec.md` | frozen once the plan is approved (reframer rung-4 patches excepted — note them in lessons) |
| `tasks/<slug>/plan.md` | statuses updated at every transition; exactly one `[in_progress]` |
| `tasks/<slug>/brief.md` | scout-written map; others append dated corrections; ≤4 KB |
| `tasks/<slug>/lessons.md` | append-only; one line per lesson; ≤4 KB |
| `tasks/<slug>/gatelog` | hook-written only, never hand-edited |
| `tasks/<slug>/spawnlog` | hook-written only, never hand-edited |
| `scoreboard.csv` | append-only (A/B dataset); corrections are appended, never edited |
| `private/*` | free-form; gitignored |

End significant sessions with `/wrap` — a reading protocol without
write-back is half a loop. Teams with concurrent ADR writers: switch to
`decisions/NNN-<slug>.md` (one file per ADR) and note the switch here.

## Forbidden (hard rules — never violate)

- **H1 — No secrets.** No keys, tokens, passwords, connection strings, or
  internal URLs — not even as placeholders. Write `<redacted>` plus where
  the real value lives (e.g., "in `.env`" or "in `.secrets/`" — both are
  runtime-only: code reads them, Claude and git do not).
- **H2 — No fact duplication.** If it exists in README, code, type
  signatures, or git history, reference it by path — don't copy it here.
  Duplication creates drift.
- **H3 — No speculation as fact.** Tag tentative claims `[TENTATIVE]` or
  `[HYPOTHESIS]`; untagged statements are trusted as facts.
- **H4 — Right file, right purpose.** *Now* → `state.md`; *permanent* →
  `decisions.md` / `knowledge/`; *this event* → `journal/`. Wrong placement
  pollutes the category.
- **L1 — No real names.** Use roles (`PM`, `customer-A`, `vendor-X`). Real
  names at most in `private/`, never in tracked files.

## Mechanisms

Every rule above is enforced mechanically where possible — session-start
injection, Stop gates, pre-commit scans, permission denies. The mechanism
map lives in **README.md §Prose → mechanism**. If you change a rule, change
its mechanism too.
