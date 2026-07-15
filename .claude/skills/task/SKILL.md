---
name: task
description: Long-horizon execution harness — verifiable milestone plan, size-scaled ceremony (S/M/L), risk-scaled adversarial verification, mechanical Stop gate on verify commands, divergent-retry escalation. Use for any task expected to exceed ~30 minutes of autonomous work, or when the user says /task, "long task", or "長任務". Supports --auto for unattended runs (intent calls recorded as [ASSUMED] instead of asked).
---

# /task — long-horizon execution harness

You are the **orchestrator**. Keep your context for decisions; delegate
reading-heavy and writing-heavy work to subagents. Contexts are fresh for
**judgment independence** (a verifier must not inherit the executor's
rationalizations) — but **facts are inherited, never re-derived**: the scout
maps the repo once into `brief.md`, and no later context re-surveys what the
map already covers. Task state lives in `.ai_context/tasks/<slug>/`; the
Stop gate (`.claude/hooks/stop-gate.sh`) independently re-runs the current
milestone's verify command at end-of-turn (unchanged tree = cached PASS).

Token discipline, both directions: spawn prompts carry deltas — paths, the
milestone, the changed-file list — not restated documents; subagents return
deltas, not summaries of what they read.

## 0 · Intake

0. **Resume, not restart.** If `.ai_context/tasks/CURRENT` names a task,
   this is a resume — `spec.md`, `brief.md`, `plan.md`, `lessons.md` are
   ALREADY in your context (SessionStart injects them; don't re-read unless
   they changed during this session). Find the `[in_progress]` milestone and
   re-enter §3. Never re-interview or re-plan. If the user is clearly
   asking for a *different* task, ask whether to finish, abandon (run
   `/wrap` — abandoned tasks still get their scoreboard row — then delete
   `CURRENT`), or defer the new one. One active task at a time.
1. Derive a short kebab-case `<slug>`.
2. If scope, constraints, or "what does done mean" are genuinely
   ambiguous, ask now — never mid-run. **Autonomous mode** (`--auto`, or
   the user says to proceed without confirmation): resolve derivable
   ambiguities by reading the code; make a documented call on
   preference/intent ambiguities, each recorded as `[ASSUMED: ...]` in
   spec.md. Destructive or outward-facing actions still require
   confirmation regardless of mode.
3. **Start from a clean tree** — commit or stash unrelated changes first
   (ask if it's unclear whose they are). Create `.ai_context/tasks/<slug>/`,
   write the slug into `.ai_context/tasks/CURRENT`, branch `task/<slug>`
   (never run a task on main).
4. **Pick the profile** (`opus-tier` / `fable-tier` / `mixed`): use the
   `Task profile:` override in the project's CLAUDE.md if present, else
   detect your own model tier. Knobs and the `mixed` setup live in
   `reference.md` §Profiles (same directory as this skill).
5. **Size the task** — ceremony scales with the task, not only the model:

   | Size | When | Plan | Execute | Final check |
   |---|---|---|---|---|
   | **S** | ≤2 milestones, all `risk: low`, one area | draft plan.md yourself — no scout, no planners | **yourself, in this context** — no executor spawns; the gate still checks every milestone | 1 `verifier` |
   | **M** | 3–6 milestones | scout → 1 `planner` + `plan-critic` | fresh `executor` per milestone | 1 `verifier`; 3-lens panel if any `risk: high` |
   | **L** | >6, architectural, or unfamiliar territory | scout → 3 `planner` lenses + `plan-critic` (fable-tier: 1 + critic) | fresh `executor` per milestone | 3-lens panel |

   Record profile AND size in the plan.md header; downstream reads the
   recorded values, never the live model. In doubt between two sizes,
   pick the larger. **M escalation:** if the critic returns blocker-level
   *structural* findings against two consecutive candidates, re-plan with
   the full 3-lens fan-out — buy planning diversity on evidence, not as
   a flat premium.

## 0.5 · Scout → brief.md (M and L only)

Spawn `scout` with the goal + repo areas the task touches. It surveys ONCE
and writes `tasks/<slug>/brief.md` (≤150 lines / 4 KB): file map, key
interfaces, commands, conventions, gotchas. Downstream rules:

- planners / executors / verifiers read brief.md FIRST, then open only
  files they will modify or must quote — never re-survey the repo;
- whoever finds the map wrong appends a dated one-line correction to it —
  discovery accumulates across contexts instead of being re-bought;
- the brief is navigation, not truth: gate and verifiers check reality.

## 1 · Spec — acceptance criteria must be executable

Write `spec.md`:

    # Spec: <title>
    Goal: <one paragraph — what exists afterwards, for whom>

    ## Acceptance criteria
    - [ ] AC1: <phrased as a check someone can run, with the command>

    ## Constraints
    - <hard limits: interfaces to keep, deps to avoid, perf floors>

    ## Out of scope
    - <explicitly not doing>

    ## Assumptions
    - [ASSUMED: <call made without confirmation — reviewed at the end>]

Reject vibes criteria ("works well", "clean"). Every AC needs a command or
a directly observable behavior; if the user can't supply one, propose one
and confirm it (in `--auto`: record it under Assumptions instead).

## 2 · Plan

1. Per the size table: spawn planner(s) — each gets its lens, the spec,
   the brief, and the profile's milestone tool-call budget — or draft the
   plan yourself (S). Planners spot-check at most ~5 load-bearing claims;
   the survey already happened.
2. Spawn `plan-critic` over the candidate(s). It attacks; it never fixes.
   It also spot-checks brief.md's load-bearing claims, and flags any
   `risk: low` milestone with a weak verify command (low risk skips model
   verification — the gate is its only net, so the gate must be strong).
3. **You synthesize** the final `plan.md`: soundest skeleton, best
   milestones grafted in, every blocker/major finding resolved.
4. Milestone size comes from the profile budget — one fresh executor
   context must finish within it; split anything bigger (gate overhead is
   linear, error compounding is exponential).

`plan.md` format — **the Stop gate parses this; keep it exact**:

    # Plan: <title>
    <!-- profile: opus-tier | fable-tier | mixed ; size: S | M | L -->
    <!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

    ## M1: <milestone title> [pending]
    - verify: `<command that fails today and passes when this milestone is done>`
    - risk: low

**Non-code work** verifies via artifact checks, same executability bar:
`test -s reports/x.md`, `test "$(grep -c '^## ' reports/x.md)" -ge 6` —
more patterns in `reference.md` §Non-code verify.

## 3 · Milestone loop

For each milestone in order:

1. Mark it `[in_progress]` in `plan.md` (exactly one at a time).
2. **S:** execute it yourself; run its verify; continue at 4.
   **M/L:** spawn `executor` with the task paths + the milestone text +
   a reminder to read brief.md first, then spec + lessons.
3. **Verification depth = the milestone's `risk:`** —
   - `low`: no model verifier. The mechanical gate re-runs the verify at
     turn-end; that strength was policed at plan time.
   - `med`: `verifier` in **light mode** — prompt carries the changed-file
     list; it re-runs verify + reviews the diff for weakened tests and
     scope creep. No re-discovery.
   - `high`: `verifier` full protocol — fresh, adversarial, spot-checks
     the ACs this milestone touches.
4. **PASS** → mark `[done]`, commit (`feat(<slug>): M<n> <title>`), update
   state.md Now/Next in two lines, move on.
5. **FAIL** → escalation ladder (§4).
6. **Drift check** (`verifier` drift mode: accumulated diff vs spec.md):
   after every `risk: high` milestone; on L additionally at the profile's
   cadence.

The Stop gate re-runs the in_progress verify whenever you try to end a
turn; a red gate cannot be narrated over — don't try, fix it.

## 4 · Escalation ladder (per milestone)

| Rung | Who | Input |
|---|---|---|
| 1 | `executor` | milestone + brief + spec + lessons |
| 2 | fresh `executor` | + rung-1 failure evidence + "use a materially different approach" |
| 3 | 3 × `executor` in parallel **worktrees** — read `reference.md` §Rung-3 protocol BEFORE starting; `verifier` picks the winner |
| 4 | `reframer` | all failure evidence; it re-cuts the milestone / patches the spec — back to rung 1 on the revised problem |
| exhausted | **stop** | append `lessons.md`, write a `journal/` entry, report honestly (three-strikes rule) |

After every failed rung: append what-was-tried / why-it-failed to
`lessons.md` — the next fresh context must not re-learn it. On
`fable-tier`, skip rung 3 (two failed distinct approaches from a strong
model = the problem is mis-posed; diagnose, don't resample). If the
planner / plan-critic / reframer agents are not installed, collapse rungs
3–4 into stop-and-report.

## 5 · Completion

1. Final check per the size table (§0.5 table, last column). Panel lenses:
   correctness vs spec / regression & side effects / test-integrity
   ("were tests weakened?"). Any FAIL → back into the loop as a repair
   milestone.
2. All green: mark everything `[done]`, delete `.ai_context/tasks/CURRENT`
   (keep the task dir), run `/wrap` (it writes the scoreboard row), then
   offer to merge `task/<slug>` or open a PR. The completion report lists
   every `[ASSUMED: ...]` from spec.md — in autonomous mode those are the
   decisions the human still owes a review.

## Profiles — one protocol, tiered knobs

The core is model-independent and always fully on: stop gate, external
state, fresh-context verification, executable ACs, lessons, scoreboard.
Only knobs scale with the model tier (milestone budget, planner fan-out,
executor prompt style, drift cadence, ladder shape) — table, `mixed` setup
and the mid-task model-switch protocol: `reference.md` §Profiles.

## Rules

- Never claim done while a verify is red — the gate blocks it anyway.
- `plan.md` statuses are the compaction anchor: update them at every
  transition. SessionStart re-injects brief + plan + lessons after /clear
  and after compaction — stale statuses poison the re-anchor.
- `brief.md` and `lessons.md` are capped at 4 KB (the hook warns): keep
  one line per entry, move narratives to `journal/`.
- Scoreboard (written by /wrap on completion): profile, size, milestones,
  gate failures **counted from `tasks/<slug>/gatelog`** (never from
  memory), highest rung, interventions. That file decides whether this
  harness earns its keep — and which knobs earn it for which work.
