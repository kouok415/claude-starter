# Migration guide

Three migrations live here:

- **[A. claude-starter v2 → v3](#a-claude-starter-v2--v3)** — add the
  long-horizon execution harness (`/task`, stop gate, agent crew) to
  projects spawned from v2.
- **[B. claude-starter v1 → v2](#b-claude-starter-v1--v2)** — projects
  spawned from this template before the mechanisms layer existed.
- **[C. multi-agent-dev-team → claude-starter](#c-from-multi-agent-dev-team-to-claude-starter)**
  — the original migration from the PM/BE/FE/QA + ECC + Discord layout.

---

## A. claude-starter v2 → v3

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

## B. claude-starter v1 → v2

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

## C. From multi-agent-dev-team to claude-starter

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
