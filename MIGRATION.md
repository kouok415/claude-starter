# Migration guide

Five migrations live here (docs are bilingual elsewhere; this file and the
English README are the authority when translations drift):

- **[0. claude-starter v3.3 → v3.4](#0-claude-starter-v33--v34)** — the
  gate-integrity release: no silent gate-off states, content-hashed
  PASS-cache, gatelog command provenance, decision-grade scoreboard.
- **[A. claude-starter v3.x → v3.3](#a-claude-starter-v3x--v33)** — the
  token-economy release: scout/brief, S/M/L sizing, risk-scaled
  verification, PASS-cache, setup sentinel.
- **[B. claude-starter v2 → v3](#b-claude-starter-v2--v3)** — add the
  long-horizon execution harness (`/task`, stop gate, agent crew) to
  projects spawned from v2.
- **[C. claude-starter v1 → v2](#c-claude-starter-v1--v2)** — projects
  spawned from this template before the mechanisms layer existed.
- **[D. multi-agent-dev-team → claude-starter](#d-from-multi-agent-dev-team-to-claude-starter)**
  — the original migration from the PM/BE/FE/QA + ECC + Discord layout.

---

## 0. claude-starter v3.3 → v3.4

v3.4 closes the milestone gate's remaining silent-failure paths and makes
the scoreboard able to answer its own question ("does the harness earn its
keep?"). Well-formed tasks see no behavior change; malformed task state now
gets caught instead of silently disarming the gate.

### What changed, and why

| v3.3 | v3.4 | Reason |
|---|---|---|
| A status typo (`[done]`+`[pending]`, no `[in_progress]`) only warned at the NEXT session start | The Stop gate blocks it once per session and logs an `INTEGRITY` gatelog row | The typo happens at milestone transitions — mid-session — and left the gate dark until the next session |
| Empty/corrupt `CURRENT`, missing plan.md, heading-less plan.md, verify-less `[in_progress]` milestone: all silent `exit 0` | Each blocks once per session (shared marker) + `INTEGRITY` row; all-`[pending]` (intake pause) and all-`[done]` (wrap-up) stay legitimate no-ops | Every silent disarm made `gate_failures=0` unreadable — clean run or dark gate? Now a quiet gatelog is proof of a clean run |
| "Never run a task on main" was prose | CURRENT + branch main/master blocks once per session | Task-on-main breaks the rollback model and rung-3 worktrees; violation was silent, detection is one git call |
| PASS-cache fingerprinted untracked files by size only | Content hash for untracked files ≤1 MB; larger fall back to size+mtime | A same-size edit could ride a stale PASS — the one violation of ADR "conservative misses OK, stale passes never" |
| gatelog rows: timestamp + milestone + verdict | + the exact verify command enforced (tabs sanitized) | A mid-run weakening of the verify left no trace; now it's on the audit record |
| Verify commands ran whatever plan.md said | Denylist: `sudo` / `git push` / `rm -rf <absolute>` never execute — blocked every time, logged | Verifies run unattended at every turn end, and `--auto` S-tasks have no plan-critic reviewing them |
| SessionStart injected brief + plan + lessons | + spec.md (ACs, constraints, out-of-scope) | S tasks execute in the main context — after compaction the intent lived only in luck; executors re-read spec, the orchestrator didn't |
| scoreboard: `...,interventions,outcome`, outcome wording ad hoc, completed tasks only | + `duration_min` (first→last commit on `task/<slug>`); `outcome` pinned to `success\|failed\|abandoned`; abandoned tasks must write their row too | Without a cost axis and failure rows the A/B dataset was survivor-biased and couldn't answer "earns its keep" |
| Freshness warning keyed on the first date found in state.md | Anchored to the `Last updated:` line (S3's label) | A body date ("ship by 2026-08-01") could shadow the real freshness claim |
| `--update-stock` advanced files but not the provenance stamp | Appends `synced-to: claude-starter@<ref>` to `.claude/.starter-version` | The stamp exists for stale-spawner debugging; it was lying after every sync |

The final review panel's test-integrity lens now also audits
`git log -p -- .ai_context/tasks/<slug>/spec.md` — spec weakening was
invisible to a panel that only reads the current spec (git already stores
the history; the fix is pointing the judge at it).

### Upgrade steps for a v3.3 project

```bash
cd <claude-starter>
./sync-project.sh --update-stock <path-to-project>
```

Provably-stock hooks/skills/agents advance automatically. Then:

1. **Existing `scoreboard.csv`** (if any): add the `duration_min` column to
   the header, second-from-last (`...,interventions,duration_min,outcome`),
   and backfill old rows with `?`.
2. Mid-flight tasks need nothing — the integrity checks only fire on
   malformed state, and a well-formed task passes untouched.
3. Note the freshness-warning change: a `state.md` without a labeled
   `Last updated:` line now warns even if a date appears elsewhere (that
   is S3 as written).

---

## A. claude-starter v3.x → v3.3

v3.3 keeps every reliability mechanism and removes structural token waste:
discovery is externalized once per task instead of re-derived per subagent,
ceremony scales with task size, and model-verification depth follows
milestone risk. No model switching is involved anywhere — the harness runs
whatever model the session runs.

### What changed, and why

| v3.0–v3.2 | v3.3 | Reason |
|---|---|---|
| Every subagent re-surveyed the repo | `scout` writes `tasks/<slug>/brief.md` once (M/L tasks); everyone else navigates by it and appends dated corrections | Fresh context exists for judgment independence; facts carry no bias — re-deriving them N× was pure waste |
| Full ceremony regardless of task size | Size recorded in the plan header: **S** plans + executes inline (no spawns), **M** = 1 planner + critic (escalates to 3-lens on repeated structural blockers), **L** = full fan-out | A 2-milestone task paid ~11 spawns of overhead for nothing |
| Model verifier after every milestone + 3-lens panel always | Depth follows `risk:` — low = mechanical gate only, med = light diff review, high = full adversarial; panel reserved for L / any-high. The critic now blocks weak verify commands on `risk: low` | The Stop gate re-runs verify commands for free; buy model judgment only where judgment risk exists |
| Verify re-ran on every turn-end | PASS-cache: unchanged tree (HEAD + diff + untracked sizes) = cached PASS, silent skip | Minute-long test suites were re-running on conversational turns |
| Setup gate keyed on placeholder heuristics | Templates carry a `claude-starter: UNCONFIGURED` sentinel; both hooks key on it (legacy patterns still honored) | Heuristics mis-fire both ways: the research template had a one-line margin, and a literal `<command>` in user content would arm the gate forever |
| `plan.md` header records profile only | `profile … ; size: S \| M \| L`; `scoreboard.csv` gains a `size` column | Size is the second A/B axis the scoreboard needs |
| INDEX.md ~7 KB injected every session | ≤4 KB (mechanism map moved to README §Prose → mechanism); `brief.md`/`lessons.md` capped at 4 KB with warnings | The injection tax is paid every session in every project |

New files: `.claude/agents/scout.md`, `.claude/skills/task/reference.md`
(rung-3 worktree protocol + profile knobs + non-code verify patterns,
loaded on demand instead of resident). Also fixed: status-typo warning
(`[pending]` milestones with no `[in_progress]` = the gate is silently
OFF — session-start now says so), bounded post-edit lint output (tail
-40), nested `.env` read-deny + gitignore, staged-content S7 check.

### Upgrade steps for a v3.0–v3.2 project

```bash
cd <claude-starter>
./sync-project.sh --update-stock <path-to-project>
```

Provably-unmodified stock hooks/skills/agents advance automatically;
customized ones are flagged for hand-merge. Then:

1. `.gitignore` — append the new lines: `**/.env` variants and
   `.ai_context/tasks/*/.gate-cache`.
2. Already-configured projects need nothing else: the sentinel only
   matters for newborn projects, and legacy placeholder detection still
   covers unconfigured pre-v3.3 spawns.
3. An in-flight `/task` keeps running — old plan headers (no `size:`)
   are treated as size L (they were planned under full ceremony);
   `brief.md` appears naturally on the next task.

---

## B. claude-starter v2 → v3

v3 adds the execution harness: long-horizon tasks run as gated milestone
pipelines instead of one heroic context.

### What changed in v3, and why

| v2 | v3 | Reason |
|---|---|---|
| "Verify before claiming done" was a CLAUDE.md contract | **Stop gate** (`stop-gate.sh`): on `/task` runs, the active milestone's verify command must pass before a turn may end | The DoD was the one v2 rule with prose but no mechanism |
| Long tasks ran in one context until it drifted | `/task`: milestone plan → fresh executor context per milestone → adversarial verifier → commit per gate; plan re-injected after compaction | Error compounding is exponential; gate overhead is linear |
| Plans came from a single attempt | Plan fusion: 3 planner lenses + red-team critic + synthesis | Decorrelated candidates + selection beat one-shot planning |
| Stuck = retry harder, or hand back to the human | Escalation ladder: different approach → 3 divergent worktree attempts → reframer (change the problem, not the attempt) → stop | Mechanizes the global three-strikes rule |
| No agents shipped | Functional `/task` crew in `.claude/agents/` (planner, plan-critic, executor, verifier, reframer) | Functional pipeline stages, not role personas; inert unless `/task` runs |
| — | Tier profiles: `opus-tier` / `fable-tier` / `mixed`, detected at intake and frozen per task | One protocol serves both model tiers — reliability core always on, capability-substitution knobs scale |

### Upgrade steps for an existing v2 project

1. **Add the harness files** (add-only, never overwrites):

   ```bash
   cd <claude-starter>
   ./sync-project.sh <path-to-project>
   ```

2. **Apply its suggestions** — for v2 projects that's typically two manual
   merges, because both files already exist and sync never overwrites:
   - merge the `"Stop"` hook block from the template's
     `.claude/settings.json` into yours;
   - diff `.claude/hooks/session-start.sh` against the template's and add
     the active-task plan injection block.

3. **Add the protocol to the project brief** — copy the "Long-horizon
   tasks" section from `templates/CLAUDE.md.code` into your `CLAUDE.md`.

4. Commit: `chore(context): upgrade to claude-starter v3 harness`

---

## C. claude-starter v1 → v2

### What changed in v2, and why

| v1 | v2 | Reason |
|---|---|---|
| Reading protocol was prose in 4 places | `SessionStart` hook injects INDEX+state (incl. after compaction); protocol text lives in `INDEX.md` only | Prose rules decay in long sessions; hooks don't |
| Write-back "as work progresses" | `/wrap` skill + `Next steps` section in `state.md` | Sessions end abruptly; write-back needs a trigger |
| H1 (no secrets) / S7 (5 KB cap) unenforced | pre-commit (gitleaks + size check) + `settings.json` read-deny on `.env*` | Rules that matter get mechanisms |
| `.claudeignore` | removed | Claude Code never read it — decorative |
| One `CLAUDE.md.template` | `templates/CLAUDE.md.{code,research,analysis}` with **Verify** + **Definition of done** | The DoD contract is the single biggest agentic-quality lever; kinds fit non-code work |
| Template infra copied into every spawned project | `start_project.sh` removes infra + generates a real project README | GitHub templates have no `.templateignore`; cleanup is the spawner's job |
| `global-claude/` had to sit next to this repo | vendored at `global/CLAUDE.md`; bootstrap shows diff + backs up before updating | Fresh-machine bootstrap used to fail; Layer 1 had no upgrade path |
| Global rules: pause every ~10 tool calls, etc. | risk-based autonomy rules (see `global/CLAUDE.md` v2) | Old guardrails were written for weaker models and now cost capability |
| Soft rules L2–L4 | renumbered S5–S7 | One contiguous S-series; L-series stays project-side (L1) |

### Upgrade steps for an existing v1 project

1. **Add the mechanisms** (add-only, never overwrites):

   ```bash
   cd <claude-starter>
   ./sync-project.sh <path-to-project>
   ```

2. **Apply its suggestions**, typically:

   ```bash
   cd <path-to-project>
   git rm -f start_project.sh bootstrap-machine.sh MIGRATION.md \
             README.zh-TW.md .claudeignore CLAUDE.md.template
   pre-commit install   # if you use pre-commit
   ```

   (v1's spawner left `CLAUDE.md.template` tracked in every repo — this is
   the moment to drop it.)

3. **Give `CLAUDE.md` a Verify command and a Definition of done** — copy the
   sections from `templates/CLAUDE.md.<kind>` and fill them in. This is the
   highest-value single edit in the whole migration.

4. **Optionally merge `INDEX.md` v2** (schema comment, Mechanisms section,
   journal first-line-summary rule):

   ```bash
   diff <path-to-project>/.ai_context/INDEX.md <claude-starter>/.ai_context/INDEX.md
   ```

   Merge by hand — your registry rows are yours.

5. **If your README is still the claude-starter README**, replace it with a
   real project README (see `templates/README.project.md`).

6. **Update the machine's global layer** (shows a diff, keeps a backup):

   ```bash
   cd <claude-starter> && ./bootstrap-machine.sh --force-global
   ```

7. Commit: `chore(context): upgrade to claude-starter v2 mechanisms`

---

## D. From multi-agent-dev-team to claude-starter

If you have projects using the previous PM/BE/FE/QA + ECC + Discord layout,
this guide walks through migrating them to this architecture.

### What changed, and why

| Old | New | Reason |
|---|---|---|
| `skills/{pm,backend,frontend,qa}/` per project | _(removed)_ | Roles overspecified — only useful for software dev, blocked other use cases. (Task-scoped agents can live in `.claude/agents/` per project when needed.) |
| `!plan / !backend / !frontend / !review / !debate / !summary / !automate` | _(removed)_ | Command router belongs in the skill system, not in CLAUDE.md |
| Discord prefixes, 1500-char limit, emoji conventions | _(removed)_ | Plug-in concern, not architecture |
| `.ai_context/{progress,architecture,api_spec,conventions,discussion_log}.md` (5 fixed files) | `.ai_context/{state.md, decisions.md, knowledge/, journal/, INDEX.md, private/}` | Structure by lifecycle (state vs permanent vs event), not by software role |
| `dev.sh` orchestration script | _(removed)_ | Claude Code's subagent / Task system handles this |
| ECC hard-wired in CLAUDE.md and skills | _(decoupled)_ | If installed, it works; architecture doesn't depend on it |
| PUA inlined as `## High Agency Mode` in CLAUDE.md | optional plugin, offered by bootstrap | Maximum-effort mode shouldn't be the default; v2's DoD + hooks mechanize its useful core |
| One CLAUDE.md mixes philosophy + project + Discord | Layers: global / project / `.ai_context/` / `.claude/` | Separation of concerns |
| `.ai_context/` not in git | `.ai_context/` in git (except `private/`) | Cross-machine continuity, decision history is a feature |

### Migration steps for an existing project

#### 1. Make a backup

```bash
cd <your-old-project>
cp -r .ai_context .ai_context.backup
```

#### 2. Move old files to the new layout

| Old file | New location |
|---|---|
| `progress.md` | Split: current status → `state.md`; resolved tasks → archive into `journal/YYYY-MM-DD-sprint-archive.md` |
| `architecture.md` | Convert each entry into an ADR in `decisions.md` |
| `api_spec.md` | Move to `knowledge/api-spec.md` (no change to content) |
| `conventions.md` | Move to `knowledge/conventions.md` |
| `discussion_log.md` | Split per debate → individual `journal/YYYY-MM-DD-<topic>.md` files |

```bash
mkdir -p .ai_context/knowledge .ai_context/journal .ai_context/private
mv .ai_context/api_spec.md    .ai_context/knowledge/api-spec.md
mv .ai_context/conventions.md .ai_context/knowledge/conventions.md
# state.md, decisions.md, journal/* require manual translation — see below
```

#### 3. Translate `architecture.md` → `decisions.md`

For each design decision in the old `architecture.md`, write an ADR using
the template at the top of `decisions.md`. Number them in the order they
were originally decided.

#### 4. Translate `progress.md` → `state.md` + journal

- **Current sprint / in-progress / TODOs** → `state.md` (`Now` and
  `Next steps` sections)
- **Constraints + Human Feedback sections** → keep as sections in `state.md`
- **Completed work, old sprints** → archive into a single
  `journal/YYYY-MM-DD-pre-migration-archive.md`

#### 5. Add the new files

Copy from claude-starter:
- `.ai_context/INDEX.md`, `state.md` (template), `decisions.md` (template)
- `.claude/` (settings, hooks, wrap skill), `scripts/`,
  `.pre-commit-config.yaml` — or just run `./sync-project.sh <project>`
- `.gitignore` AI additions (append to existing `.gitignore`)

#### 6. Replace the project `CLAUDE.md`

```bash
cp <claude-starter>/templates/CLAUDE.md.code ./CLAUDE.md
# edit: replace {{PROJECT_NAME}}, fill stack/commands/Verify/DoD
```

#### 7. Remove obsolete pieces

```bash
rm -rf skills/                      # role skills (PM/BE/FE/QA)
rm -f  dev.sh                       # orchestration script
rm -rf .ai_context/pua_skill/       # PUA installs as a plugin now, if at all
```

#### 8. Set up the global layer (one-time per machine)

```bash
cd <claude-starter>
./bootstrap-machine.sh
```

#### 9. Verify and commit

```bash
git add -A
git commit -m "chore: migrate to claude-starter layout"
git push
```

Open a new Claude session and confirm:
- the SessionStart hook injects `INDEX.md` + `state.md`
- `state.md` reflects current work
- ADRs in `decisions.md` are findable
- no references to old commands or Discord remain

### Common mistakes to avoid

- **Don't migrate everything blindly.** Old `progress.md` often contains
  noise — fluff updates, resolved bikesheds, stale TODOs. Filter as you go
  (S4: no fluff).
- **Don't keep the role skills "just in case".** If you need agents, write
  task-scoped ones in `.claude/agents/`, not org-chart personas.
- **Don't put `.ai_context/` in `.gitignore` because the old project did.**
  The design intentionally tracks it; audit H1/L1 instead.
- **Don't carry over speculation as fact.** Tag uncertain claims
  `[TENTATIVE]` while translating.
