# Migration guide

Ten migrations live here (docs are bilingual elsewhere; this file and the
English README are the authority when translations drift):

- **[-1. claude-starter v3.8 → v3.9](#-1-claude-starter-v38--v39)** — the
  handoff release: a red gate reaches the human (counted blocks → `STUCK` +
  `systemMessage`), spawn evidence (`spawnlog` + no-spawn diagnosis),
  filtered plan injection.
- **[0. claude-starter v3.7 → v3.8](#0-claude-starter-v37--v38)** — the
  runtime-only secrets release: the `.secrets/` folder convention
  (Read-denied, bash-guard ask, gitignored except placeholder) + pem/id_rsa
  gitignore asymmetry closed.
- **[1. claude-starter v3.6 → v3.7](#1-claude-starter-v36--v37)** — the
  guardrail release: `bash-guard.sh` PreToolUse tripwire, append-only +
  S2-bulk pre-commit guards, gatelog write-deny, wrong-branch gate
  integrity, `harness-report.sh` integrity cross-checks.
- **[2. claude-starter v3.5 → v3.6](#2-claude-starter-v35--v36)** — the
  audit-honesty release: zero-stop sweep (final `[done]` milestone verified
  at wrap, earlier rowless gates recorded `UNARMED`), `stop-gate.sh --sweep`
  for `/wrap`.
- **[3. claude-starter v3.4 → v3.5](#3-claude-starter-v34--v35)** — the
  scoring-loop release: version-attributed scoreboard rows, structured
  friction capture, deterministic `harness-report.sh`.
- **[4. claude-starter v3.3 → v3.4](#4-claude-starter-v33--v34)** — the
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

## -1. claude-starter v3.8 → v3.9

v3.9 exists because of one incident shape: a `/task` orchestrator marked a
milestone `[in_progress]`, never spawned its executor, and the gate — which
correctly caught the red verify — blocked once, then let the next stop pass
through silently. The harness *detected* and did not *hand off*; a human
found the stall by hand half a day later. Every v3.9 mechanism is one link
of that chain closed.

### What changed, and why

| v3.8 | v3.9 | Reason |
|---|---|---|
| Stop gate blocks a red verify once, then `stop_hook_active` passes the next stop through silently | counted yields: two red blocks per (session, milestone); the **third** consecutive red stop exits 0 with a `STUCK` gatelog row and a `{"systemMessage"}` the human sees in the UI. `PASS` resets the streak; `/wrap --sweep` stays strict (wrap never wraps red); model-fixable blocks (status corruption, forbidden verify) still block every attempt | "a red gate cannot be narrated over" was prose, not mechanism — the pass-through made it false on the second stop. Three failed attempts = the three-strikes rule: stop resampling, hand off *visibly* |
| `[in_progress]` conflates "armed, executor not yet spawned" with "executor ran, verifying" — indistinguishable after compaction | `spawn-log.sh` (`SubagentStart`, matcher-routed, reads nothing from the payload) appends `ts/milestone/class` rows to `tasks/<slug>/spawnlog` (Edit/Write-denied like gatelog); on red, size-M/L, non-empty spawnlog and no executor row for the armed milestone, the gate redirects to **rung 1** ("spawn the executor") instead of the escalation ladder | the resume path read `[in_progress]` as "step 2 already happened" and skipped the spawn; without spawn evidence the gate's "escalate" advice was actively wrong for never-started milestones |
| full plan.md re-injected every session start / compaction (40 KB on a real L task; the armed milestone was 3.7% of it) | filtered view: header + every heading + verify/risk lines + the full `[in_progress]` section only (same task: 9.4 KB, armed share 16%); self-declares as filtered; warns past 8 KB | the file meant to survive compaction was feeding compaction; the re-anchor needs the current milestone, not 20 milestones of design commentary |
| forward constraints discovered mid-task accumulate in lessons.md (injected every session) | SKILL rule: a discovery constraining a FUTURE milestone is appended, dated, into THAT milestone's plan.md comment block — it resurfaces exactly when the milestone arms | lessons.md is a resident cost paid every session; plan comments are lazy-loaded at the right moment |

Old-Claude-Code safety: on CC versions without the `SubagentStart` event the
spawnlog never materializes, and a gate that sees no spawnlog (or an empty
one) says nothing about spawning — the diagnosis only arms once intake rows
(scout/planner) prove the event fires in this environment.

### Upgrade steps for a v3.8 project

```bash
cd <claude-starter>
./sync-project.sh --update-stock <path-to-project>
```

That advances stock `stop-gate.sh` / `session-start.sh` / `spawn-log.sh` /
`settings.json` and the `/task` skill. Customized settings.json: hand-merge
the `SubagentStart` hooks block and the two `spawnlog` deny entries.
Mid-flight `/task`s: the counter starts on the next red stop; spawnlog
starts recording on the next spawn — earlier milestones simply have no rows,
which the diagnosis treats as silence, never as an accusation.

---

## 0. claude-starter v3.7 → v3.8

v3.8 adds the missing "bucket" for credentials. The template protected
secrets by filename pattern (`.env*`, `*.pem`, `id_rsa*`) — enumeration
leaks (`service-account.json`, `kubeconfig`, token files…). `.secrets/` is
the opt-in folder where anything dropped in gets all three protections at
once, with one mental model: **sensitive but Claude-readable →
`.ai_context/private/`; runtime-only, not even Claude → `.secrets/`;
git sees neither.**

### What changed, and why

| v3.7 | v3.8 | Reason |
|---|---|---|
| secrets protected by filename enumeration only | `.secrets/` folder: `settings.json` denies `Read(./.secrets/**)` (root + nested), `bash-guard.sh` downgrades bash access to a confirmation, `.gitignore` ignores contents (contents-form: `.secrets/*` + `!.secrets/.gitkeep` — ignoring the dir itself would make the negation unreachable) | one folder beats a pattern list: opt-in placement is explicit intent, so the deny has ~zero false positives (ADR-011 bar) |
| runtime use undocumented | seed ships `.secrets/.gitkeep`; H1 guidance names it; usage: `GOOGLE_APPLICATION_CREDENTIALS=.secrets/sa.json python app.py` | execution-time reads are the point — the folder is runtime-only, not Claude-readable storage |
| `*.pem` / `id_rsa*` Read-denied but NOT gitignored | both gitignored | closes a v2-era asymmetry |

Honest boundary (unchanged philosophy): the Read-tool deny is hard; the
bash path is an ask-tier tripwire; and code that reads a secret at runtime
can always print it — so the convention includes "don't echo secrets to
stdout". True isolation is the runtime's job (secret managers, sandbox),
not a repo folder's.

### Upgrade steps for a v3.7 project

```bash
cd <claude-starter>
./sync-project.sh --update-stock <path-to-project>
```

That installs `.secrets/.gitkeep`, appends the `.secrets/` block to your
`.gitignore` (append-only, project lines untouched), and advances stock
`settings.json` / `bash-guard.sh`. Customized settings.json: merge the two
`Read(...secrets...)` deny entries by hand (sync prints a suggestion when
gatelog/bash-guard wiring is missing; the deny entries ride the same merge).

---

## 1. claude-starter v3.6 → v3.7

v3.7 comes from auditing every prose rule against its mechanism and closing
the gaps that passed the bar (blocking mechanisms require near-zero false
positives against the real workflow and must protect something irreversible
or load-bearing; everything else lands in a warning or the report). Nothing
about the daily loop changes — what changes is what *cannot silently
happen*.

### What changed, and why

| v3.6 | v3.7 | Reason |
|---|---|---|
| force-push / sudo / `rm -rf` in interactive bash guarded by prose only | `bash-guard.sh` (PreToolUse) denies force-push, `sudo`, `rm -rf /` — absolutely, logged to `.ai_context/private/bash-guard.log`; absolute-path `rm -rf` and `.env` access become a confirmation; `settings.json` gains a declarative `ask` tier plus force-push/gatelog `deny` entries | the global git rules had no mechanism exactly where they matter most — permissive/unattended modes; contains-matching beats prefix rules, but it stays a tripwire, not a sandbox |
| append-only files (decisions.md, journal/, scoreboard.csv, friction.csv, gatelog) trusted to discipline | `check-append-only.sh` pre-commit rejects staged edits/deletions of existing lines; `settings.json` denies Edit/Write on `tasks/*/gatelog` | the scoring loop's honesty rests on these files (a fake PASS row could even skip the wrap sweep); corrections are appended, never rewritten. `lessons.md`/`brief.md` stay rewritable — `/wrap` distills them by design |
| a `/task` on a non-task branch ran its verify against the wrong tree, logging junk FAIL rows | any branch other than `task/*` (or main/master, as before) is a blocked INTEGRITY state with a clear reason | better diagnosis than a baffling red gate, and `gate_failures` stats stop being polluted |
| scoreboard rows trusted as /wrap wrote them | `harness-report.sh` `== integrity`: scoreboard↔gatelog mismatches, orphan task dirs, missing PASS/UNARMED evidence, enum violations (human mode only — the 13-column `--csv` contract is untouched) | "computed, never recalled" now includes cross-checking the model-written rows against ground truth |
| INDEX.md size guarded only by template CI; nothing capped bulk pastes | session-start warns when a project's INDEX.md exceeds 4 KB; `check-context-bulk.sh` blocks any staged `.ai_context` file over 100 KB (S2) | the injected-every-session files stay small in *projects*, and dumps get referenced instead of pasted |
| `tests/run.sh` assumed the template repo (spawner/sync present) | template-only sections SKIP gracefully in projects that carry `tests/` (spawns inherit it; sync deliberately never ships it — `tests/` may be *your* test dir) | the suite doubles as the post-sync smoke test where present; synced projects smoke the hooks directly (see upgrade steps) |

### Upgrade steps for a v3.6 project

```bash
cd <claude-starter>
./sync-project.sh --update-stock <path-to-project>
```

That installs `bash-guard.sh` and the two new pre-commit scripts, and
advances the stock hooks/report/config. Two things sync will not do to a
*customized* file (it prints suggestions instead):

- **settings.json** — merge by hand: the `PreToolUse` hook block, the
  `ask` tier, and the new `deny` entries (force-push, `tasks/*/gatelog`).
- **.pre-commit-config.yaml** — add the `ai-context-append-only` and
  `ai-context-bulk` hooks, then re-run `pre-commit install`.

Post-sync smoke: if the project carries `tests/run.sh` (spawned from the
template — sync deliberately never ships it, since `tests/` may be your
own test directory), run `bash tests/run.sh`; template-only sections skip.
Otherwise exercise the synced hooks directly:

```bash
printf '{"tool_input":{"command":"git push --force"}}' \
  | bash .claude/hooks/bash-guard.sh; echo "rc=$? (want 2)"
bash .claude/hooks/stop-gate.sh --sweep; echo "rc=$? (want 0)"
bash scripts/harness-report.sh .    # exits 0; prints report or no-data line
```

---

## 2. claude-starter v3.5 → v3.6

v3.6 closes the audit blind spot the first real `/task` run exposed: a task
completed inside ONE turn never armed the Stop gate, so its gatelog was
empty and `gate_failures=0` was vacuous — indistinguishable from an
evidential clean run.

### What changed, and why

| v3.5 | v3.6 | Reason |
|---|---|---|
| all-`[done]` at turn end was an unconditional no-op | zero-stop sweep: the FINAL `[done]` milestone's verify runs if it has no PASS row (its point-in-time is exactly now; red blocks every time, forbidden ops refused as before); earlier rowless `[done]` milestones get an `UNARMED` gatelog row | earlier milestones' verifies are point-in-time gates, not permanent invariants — later work may legitimately supersede them, so honest vacuity is recorded instead of fake evidence or false blocks |
| `/wrap` could delete `CURRENT` in the same turn, bypassing even the wrap-up stop | new `stop-gate.sh --sweep` mode; `/wrap` runs it BEFORE deleting `CURRENT` (finished and abandoned tasks both) | the sweep must be reachable from inside the turn that wraps; abandoned tasks get `UNARMED` evidence for whatever was claimed done |
| `harness-report.sh` gates section: FAIL + INTEGRITY | + `UNARMED rows: N` (human output only — the 13-column `--csv` contract is frozen) | vacuous gates become visible in per-project and fleet reporting without breaking cross-version fleet aggregation |

### Upgrade steps for a v3.5 project

```bash
cd <claude-starter>
./sync-project.sh --update-stock <path-to-project>
```

That advances `stop-gate.sh`, `/wrap`, and `scripts/harness-report.sh`.
Nothing else to do: completed task dirs (no `CURRENT`) are never swept, and
the first wrap-up stop of the next task does the right thing on its own.
Historical scoreboard rows written before v3.6 keep their ambiguity — a
`gate_failures=0` from a pre-v3.6 zero-stop run cannot be retro-classified;
read them with that caveat.

---

## 3. claude-starter v3.4 → v3.5

v3.5 adds the scoring side of the loop the scoreboard only collected for:
every row now names the harness version that produced it, harness friction
becomes structured data, and a deterministic report computes the rates —
"does the harness earn its keep" becomes answerable version-over-version
instead of by recall.

### What changed, and why

| v3.4 | v3.5 | Reason |
|---|---|---|
| scoreboard rows didn't say WHICH harness produced them | new `harness` column — `/wrap` fills it from the last `claude-starter@<ref>` line of `.claude/.starter-version`; releases are git-tagged (`v3.3`+) so ref→version mapping is mechanical | an A/B dataset without its treatment variable can't A/B: "did v3.5 lower the gate-failure rate for M tasks?" was unanswerable |
| harness pain lived in journal prose, if anywhere | `.ai_context/friction.csv` (`date,harness,area,severity,summary,ref`; enums `setup\|task\|wrap\|hooks\|sync\|skills\|other` × `blocker\|friction\|papercut`), written by a new `/wrap` step only when something actually misbehaved | prose doesn't aggregate across projects; enum rows do — and non-`/task` friction (setup, hooks, sync) had no channel at all |
| scoreboard.csv had no reader | `scripts/harness-report.sh`: per-(harness, profile, size) outcome cells, gate-failure and escalation rates, duration/intervention medians, INTEGRITY counts, friction matrix; `--csv` emits one aggregate row per version (the fleet-aggregation interface); `/wrap` runs it after appending a row | computed-once, CI-tested numbers beat rates recalled by a model; percentages are suppressed below N=5 and no composite score exists — both on purpose |

### Upgrade steps for a v3.4 project

```bash
cd <claude-starter>
./sync-project.sh --update-stock <path-to-project>
```

That advances `/wrap`, ships `scripts/harness-report.sh`, and appends the
`synced-to:` stamp. Then:

1. **Existing `scoreboard.csv`** (if any): append `,harness` to the header
   line. Old rows may stay short — readers treat the missing value as
   `unknown`; backfill only where the vintage is actually known.
2. `friction.csv` needs nothing — `/wrap` creates it on its first real
   entry (no empty stubs).
3. A scoreboard whose header still lacks `duration_min` is pre-v3.4:
   finish section 2's migration first.

---

## 4. claude-starter v3.3 → v3.4

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
