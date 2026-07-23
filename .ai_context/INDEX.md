<!-- schema: v3 -->
<!-- Meta-registry only, ≤4 KB (injected every session). Per-file writing
     rules live in §Writing protocol below. -->

# .ai_context Index

Claude's persistent project memory. This file and `state.md` are
auto-injected at every session start (hooks); read the rest **on-demand**:

| Situation | Read |
|---|---|
| Design choice, picking between options, dependency pick | `decisions.md` (check existing ADRs first) |
| Domain reference needed (contracts, conventions, terms) | the matching `knowledge/*.md` (create on demand, add a row here) |
| Past event, debate, retro, specific date | search `journal/YYYY-MM-DD-*.md` |
| Sensitive scratch, local-only notes | `private/` |
| Active `/task` (`tasks/CURRENT` exists) | that task's `brief.md` + `plan.md` + `lessons.md` (auto-injected too) |

Don't warm up on `journal/` or `knowledge/` — they exist for retrieval.
Procedural knowledge (runbooks, how-tos) belongs in a skill
(`.claude/skills/<name>/SKILL.md`); factual reference in `knowledge/`.

## Writing protocol

| File / dir | Mutability |
|---|---|
| `state.md` | overwrite; reflects *now* only; ≤5 KB (S7) |
| `decisions.md` | append-only ADRs; never edit existing entries |
| `knowledge/*.md` | accumulate; create on demand (no empty stubs), add a row above |
| `journal/*.md` | append-only; one file per event; first line = one-sentence summary |
| `tasks/<slug>/spec.md` | frozen once the plan is approved (reframer rung-4 patches excepted — note in lessons) |
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
  the real value lives (`.env` / `.secrets/` — runtime-only homes).
- **H2 — No fact duplication.** If it exists in README, code, or git
  history, reference it by path — duplication creates drift.
- **H3 — No speculation as fact.** Tag tentative claims `[TENTATIVE]` or
  `[HYPOTHESIS]`; untagged statements are trusted as facts.
- **H4 — Right file, right purpose.** *Now* → `state.md`; *permanent* →
  `decisions.md` / `knowledge/`; *this event* → `journal/`.
- **L1 — No real names.** Roles only (`PM`, `customer-A`); real names at
  most in `private/`.

## Mechanisms

Every rule above is enforced mechanically where possible — session-start
injection, Stop gates, pre-commit scans, permission denies. The mechanism
map lives in **README.md §Prose → mechanism**. If you change a rule, change
its mechanism too.
