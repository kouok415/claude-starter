---
name: task
description: Long-horizon execution harness — plan a big task into verifiable milestones, execute each in a fresh executor subagent, adversarially verify, gate on verify commands, escalate through divergent retries and reframing. Use for any task expected to exceed ~30 minutes of autonomous work, or when the user says /task, "long task", or "長任務". Supports --auto for unattended runs (intent calls are recorded as assumptions instead of asked).
---

# /task — long-horizon execution harness

You are the **orchestrator**. Keep your own context for decisions; delegate
reading-heavy and writing-heavy work to subagents — their contexts are fresh
by design, that is the point. Task state lives in `.ai_context/tasks/<slug>/`;
the Stop gate (`.claude/hooks/stop-gate.sh`) independently enforces the
current milestone's verify command at end-of-turn.

## 0 · Intake

0. **Resume, not restart.** If `.ai_context/tasks/CURRENT` already names a
   task, this is a resume: read that task's `plan.md` + `lessons.md`, find
   the `[in_progress]` milestone, and re-enter the milestone loop (§3) —
   do NOT re-interview or re-plan. If the user is clearly asking for a
   *different* task, ask whether to finish, abandon (delete `CURRENT`),
   or defer the new one. One active task at a time.
1. Derive a short kebab-case `<slug>` from the request.
2. If scope, constraints, or "what does done mean" are genuinely ambiguous,
   ask now — never mid-run. **Autonomous mode** (`--auto`, or the user says
   to proceed without confirmation): don't pause — resolve derivable
   ambiguities by reading the code (asking those is a design flaw, not
   caution), make a documented call on preference/intent ambiguities and
   record each as an `[ASSUMED: ...]` line in spec.md's Assumptions
   section. Destructive or outward-facing actions still require
   confirmation regardless of mode.
3. **Start from a clean tree** — uncommitted changes would get entangled
   with the first checkpoint; commit or stash them first (ask if it's
   unclear whose they are). Then create `.ai_context/tasks/<slug>/`, write
   the slug into `.ai_context/tasks/CURRENT`, and create a branch
   `task/<slug>` (never run a task on main).
4. **Pick the profile** (see § Profiles below): use the `Task profile:`
   override from the project's CLAUDE.md if present, otherwise detect your
   own model tier. Record it in the `plan.md` header — every later knob
   reads the recorded value, never the live model. If you are fable-class
   and `.claude/agents/executor.md` still says `model: inherit`, suggest
   the `mixed` setup once (pin the executor to `opus` for markedly cheaper
   execution), then proceed with whatever the user chooses.

## 1 · Spec — acceptance criteria must be executable

Write `spec.md`:

    # Spec: <title>
    Goal: <one paragraph — what exists afterwards, for whom>

    ## Acceptance criteria
    - [ ] AC1: <phrased as a check someone can run, with the command>
    - [ ] AC2: ...

    ## Constraints
    - <hard limits: interfaces to keep, deps to avoid, perf floors>

    ## Out of scope
    - <explicitly not doing>

    ## Assumptions
    - [ASSUMED: <call made without confirmation — reviewed at the end>]

Reject vibes criteria ("works well", "clean"). Every AC needs a command or a
directly observable behavior. If the user can't supply one, propose one and
confirm it — in autonomous mode, propose it and record it under
`## Assumptions` instead of pausing.

## 2 · Plan fusion

1. Spawn `planner` subagents per the profile's fan-out — `opus-tier`:
   **3 in parallel** on the same spec, each with a different assigned lens,
   e.g. minimal-change / risk-first / redesign-first (adapt lenses to the
   task); `fable-tier` / `mixed`: 1 planner is enough.
2. Spawn **`plan-critic`** over all three candidates. It attacks; it never
   fixes.
3. **You synthesize** the final `plan.md`: take the soundest skeleton, graft
   the best milestones from the others, resolve every blocker/major finding.
4. Milestone sizing comes from the profile — pass the tool-call budget to
   the planners when you spawn them. One fresh executor context should
   finish a milestone within that budget; split anything bigger (gate
   overhead is linear, error compounding is exponential).

`plan.md` format — **the Stop gate parses this; keep it exact**:

    # Plan: <title>
    <!-- profile: opus-tier | fable-tier | mixed -->
    <!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

    ## M1: <milestone title> [pending]
    - verify: `<command that fails today and passes when this milestone is done>`
    - risk: low

    ## M2: <title> [pending]
    - verify: `<command>`
    - risk: high

**Non-code work (research / analysis kinds):** verify commands check the
artifact, not a test suite — existence, structure, coverage:

    - verify: `test -s reports/h2-outlook.md`
    - verify: `test "$(grep -c '^## ' reports/x.md)" -ge 6`
    - verify: `python scripts/check_csv.py data/out.csv`

Only when done-ness truly cannot be expressed as a command, let a
verifier-agent spot-check stand in as the gate — but try the artifact
check first.

## 3 · Milestone loop

For each milestone in order:

1. Mark it `[in_progress]` in `plan.md` (exactly one at a time).
2. Spawn `executor` with: the task paths, the milestone text, and a reminder
   to read `spec.md` + `lessons.md` first.
3. Spawn `verifier` on the result — fresh context, adversarial.
4. **PASS** → mark `[done]`, commit (`feat(<slug>): M<n> <title>`), update
   `state.md` Now/Next in two lines, move on.
5. **FAIL** → escalation ladder below.
6. At the profile's drift cadence, spawn `verifier` in **drift-check
   mode**: compare the accumulated diff against `spec.md` — still pointed
   at the acceptance criteria? any quiet scope creep?

The Stop gate re-runs the in_progress verify whenever you try to end a turn;
a red gate cannot be narrated over — don't try, fix it.

## 4 · Escalation ladder (per milestone)

| Rung | Who | Input |
|---|---|---|
| 1 | `executor` | milestone + spec + lessons |
| 2 | fresh `executor` | + rung-1 failure evidence + "use a materially different approach" |
| 3 | 3 × `executor` in parallel **worktrees**, each declares its strategy in one sentence first — reject non-distinct strategies before they run; `verifier` picks the winner |
| 4 | `reframer` | all failure evidence; it re-cuts the milestone / patches the spec — then back to rung 1 on the revised problem |
| exhausted | **stop** | append `lessons.md`, write a `journal/` entry, report honestly (three-strikes rule) |

**Rung-3 worktree protocol** — subagents share your working directory, so
isolation must be explicit:

1. From the task branch: `git worktree add ../<repo>-r3-<n> -b
   task/<slug>-r3-<n>` for n = 1..3.
2. Spawn each executor WITH its worktree path; all of its file operations
   and its verify run happen inside that path only.
3. `verifier` runs the milestone verify in each worktree and picks the
   winner (tie-break: smallest diff).
4. Merge the winning branch into `task/<slug>` (squash is fine), then
   `git worktree remove` all three and delete the `-r3-*` branches.

Never let rung-3 executors loose in the shared tree.

After every failed rung: append what-was-tried / why-it-failed to
`lessons.md` — the next fresh context must not re-learn it. On
`fable-tier`, skip rung 3 and go straight to `reframer`: two failed,
genuinely distinct approaches from a strong model is evidence the problem
is mis-posed — diagnose, don't resample. If the `planner` / `plan-critic`
/ `reframer` agents are not installed, collapse rungs 3–4 into
stop-and-report.

## 5 · Completion

1. Final panel — 3 `verifier`s in parallel, one lens each: correctness vs
   spec / regression & side effects / test-integrity ("were tests
   weakened?"). Any FAIL → back into the loop as a repair milestone.
2. All green: mark everything `[done]`, delete `.ai_context/tasks/CURRENT`
   (keep the task dir), run `/wrap` (it archives the scoreboard to
   `journal/`), then offer to merge `task/<slug>` or open a PR. The
   completion report must list every `[ASSUMED: ...]` entry from spec.md —
   in autonomous mode those are the decisions the human still owes a
   review.

## Profiles — one protocol, tiered knobs

The harness core is model-independent and always fully on: stop gate,
external state, fresh-context verification, executable acceptance criteria,
lessons, scoreboard. Only the knobs below scale with the model tier —
they compensate for capability, so stronger models need less of them.

Resolution order: `Task profile:` in the project's CLAUDE.md → otherwise
detect the orchestrator's own model tier at intake. Record the result in
the `plan.md` header; downstream reads the recorded profile, never the
live model.

| Knob | `opus-tier` | `fable-tier` |
|---|---|---|
| Milestone size (per fresh executor context) | ≤15 tool calls | 30–50 tool calls |
| Planner fan-out | 3 lenses + `plan-critic` | 1 + `plan-critic` |
| Executor spawn prompt | milestone + a suggested approach | milestone + goal + constraints only — no prescribed steps |
| Drift-check cadence | every 3rd milestone | every 5th, or after `risk: high` milestones only |
| Escalation ladder | 1 → 2 → 3 → 4 | 1 → 2 → 4 |

`mixed` — recommended where both tiers are available: pin `model: opus` in
`.claude/agents/executor.md` and run the session on a fable-class model.
Judgment-dense, low-token stages (plan synthesis, critique, reframing,
final panel) get the strong model; token-heavy execution runs at the
cheaper tier. Use `opus-tier` milestone sizing (the executor does the
work); planner fan-out may drop to 1 + critic (a strong model plans).

**Mid-task model switches are never silent.** The plan's granularity was
cut for the recorded profile. If the session model changes mid-task: keep
completed milestones, spawn `planner` to re-cut only the remaining ones
under the new profile, update the `plan.md` header, note the switch in
`lessons.md`.

## Rules

- Never claim done while a verify is red — the gate blocks it anyway.
- `plan.md` statuses are the compaction anchor: update them at every
  transition. The SessionStart hook re-injects plan + lessons after /clear
  and after compaction — stale statuses poison the re-anchor.
- Scoreboard (goes in the journal entry on completion): profile, milestones
  total, gate failures, highest ladder rung used, human interventions. Gate
  outcomes are logged mechanically to `tasks/<slug>/gatelog` by the Stop
  hook — count from the file, never from memory. This is the data that says
  whether the harness earns its keep — and, across tasks, which profile
  earns it for which kind of work.
