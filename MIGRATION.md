# Migration: from multi-agent-dev-team to claude-starter

If you have projects using the previous PM/BE/FE/QA + ECC + Discord layout,
this guide walks through migrating them to the new architecture.

---

## What changed, and why

| Old | New | Reason |
|---|---|---|
| `skills/{pm,backend,frontend,qa}/` per project | _(removed)_ | Roles overspecified — only useful for software dev, blocked other use cases |
| `!plan / !backend / !frontend / !review / !debate / !summary / !automate` | _(removed)_ | Command router belongs in slash commands, not in CLAUDE.md |
| Discord prefixes, 1500-char limit, emoji conventions | _(removed)_ | Plug-in concern, not architecture |
| `.ai_context/{progress,architecture,api_spec,conventions,discussion_log}.md` (5 fixed files) | `.ai_context/{state.md, decisions.md, knowledge/, journal/, INDEX.md, private/}` | Structure by lifecycle (state vs permanent vs event), not by software role |
| `dev.sh` orchestration script | _(removed)_ | Claude Code's subagent / Task system handles this |
| ECC hard-wired in CLAUDE.md and skills | _(decoupled)_ | If installed, it works; architecture doesn't depend on it |
| PUA inlined as `## High Agency Mode` in CLAUDE.md | `~/.claude/skills/pua/SKILL.md`, on-demand | Maximum-effort mode shouldn't be the default — burns tokens when not needed |
| One CLAUDE.md mixes philosophy + project + Discord | Three layers: global / project / `.ai_context/` | Separation of concerns |
| `.ai_context/` not in git | `.ai_context/` in git (except `private/`) | Cross-machine continuity, decision history is a feature |

---

## Migration steps for an existing project

### 1. Make a backup

```bash
cd <your-old-project>
cp -r .ai_context .ai_context.backup
```

### 2. Move old files to the new layout

The mapping:

| Old file | New location |
|---|---|
| `progress.md` | Split: current status → `state.md`; resolved tasks → archive into `journal/YYYY-MM-DD-sprint-archive.md` |
| `architecture.md` | Convert each entry into an ADR in `decisions.md` |
| `api_spec.md` | Move to `knowledge/api-spec.md` (no change to content) |
| `conventions.md` | Move to `knowledge/conventions.md` |
| `discussion_log.md` | Split per debate → individual `journal/YYYY-MM-DD-<topic>.md` files |

```bash
mkdir -p .ai_context/knowledge .ai_context/journal .ai_context/private
mv .ai_context/api_spec.md   .ai_context/knowledge/api-spec.md
mv .ai_context/conventions.md .ai_context/knowledge/conventions.md
# state.md, decisions.md, journal/* require manual translation — see below
```

### 3. Translate `architecture.md` → `decisions.md`

For each design decision in the old `architecture.md`, write an ADR using
the template at the top of `decisions.md`:

```markdown
## ADR-001: <title>
- Date: <if known, else today>
- Status: Accepted
- Context: ...
- Decision: ...
- Rationale: ...
- Alternatives considered: ...
- Consequences: ...
```

Number them in the order they were originally decided.

### 4. Translate `progress.md` → `state.md` + journal

- **Current sprint / in-progress / TODOs** → write into `state.md`
- **Constraints + Human Feedback sections** → keep them as sections in
  `state.md`
- **Completed work, old sprints** → archive into a single
  `journal/YYYY-MM-DD-pre-migration-archive.md`

### 5. Add the new files

Copy from claude-starter:
- `.ai_context/INDEX.md`
- `.ai_context/state.md` (template, then fill in)
- `.ai_context/decisions.md` (template, then fill in from step 3)
- `.gitignore` AI additions (append to existing `.gitignore`)
- `.claudeignore`

### 6. Replace the project `CLAUDE.md`

The old CLAUDE.md mixed roles, commands, Discord, ECC. Replace with the new
template and fill in only project-specific stack and rules:

```bash
cp <claude-starter>/CLAUDE.md.template ./CLAUDE.md
# edit: replace {{PROJECT_NAME}}, fill stack/commands/rules
```

### 7. Remove obsolete pieces

```bash
rm -rf skills/                      # role skills (PM/BE/FE/QA)
rm -f  dev.sh                       # orchestration script
rm -rf .ai_context/pua_skill/       # PUA now installs as a Claude plugin,
                                    # not as a project-local git clone.
                                    # See bootstrap-machine.sh.
```

### 8. Set up the global layer (one-time per machine)

If you haven't already:

```bash
cd <claude-starter>
./bootstrap-machine.sh
```

This installs `~/.claude/CLAUDE.md` and (optionally) the PUA plugin via
Claude's plugin marketplace.

### 9. Verify and commit

```bash
git add -A
git commit -m "chore: migrate to claude-starter layout"
git push
```

Open a new Claude session and confirm:
- Claude reads `INDEX.md` first
- `state.md` reflects current work
- ADRs in `decisions.md` are findable
- No references to old commands or Discord remain

---

## Common mistakes to avoid

- **Don't migrate everything blindly.** Old `progress.md` often contains
  noise — fluff updates, resolved bikesheds, stale TODOs. Filter as you go.
  This is the natural moment to apply the new S4 (no fluff) rule.
- **Don't keep the role skills "just in case".** They tied the project to
  one workflow. If you find yourself wanting them back, write a `mode/` or
  `personas/` directory with non-PM/BE/FE/QA framings instead.
- **Don't put `.ai_context/` in `.gitignore` because the old project did.**
  The new design intentionally tracks it. If concerned about leaks, audit
  H1/L1 first; only opt out as a last resort.
- **Don't carry over speculation as fact.** While translating, tag
  uncertain claims with `[TENTATIVE]`.
