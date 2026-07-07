---
name: task
description: Long-horizon execution harness — plan a big task into verifiable milestones, execute each in a fresh executor subagent, adversarially verify, gate on verify commands, escalate through divergent retries and reframing. Use for any task expected to exceed ~30 minutes of autonomous work, or when the user says /task, "long task", or "長任務".
---

# /task — long-horizon execution harness

You are the **orchestrator**. Keep your own context for decisions; delegate
reading-heavy and writing-heavy work to subagents — their contexts are fresh
by design, that is the point. Task state lives in `.ai_context/tasks/<slug>/`;
the Stop gate (`.claude/hooks/stop-gate.sh`) independently enforces the
current milestone's verify command at end-of-turn.

## 0 · Intake

1. Derive a short kebab-case `<slug>` from the request.
2. If scope, constraints, or "what does done mean" are genuinely ambiguous,
   ask now — never mid-run.
3. Create `.ai_context/tasks/<slug>/`, write the slug into
   `.ai_context/tasks/CURRENT`, and create a branch `task/<slug>`
   (never run a task on main).

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

Reject vibes criteria ("works well", "clean"). Every AC needs a command or a
directly observable behavior. If the user can't supply one, propose one and
confirm it.

## 2 · Plan fusion

1. Spawn **3 `planner` subagents in parallel** on the same spec, each with a
   different assigned lens — e.g. minimal-change / risk-first /
   redesign-first (adapt lenses to the task).
2. Spawn **`plan-critic`** over all three candidates. It attacks; it never
   fixes.
3. **You synthesize** the final `plan.md`: take the soundest skeleton, graft
   the best milestones from the others, resolve every blocker/major finding.
4. Milestone sizing: one fresh executor context should finish a milestone in
   roughly ≤15 tool calls. Split anything bigger — prefer 12 small
   milestones over 6 large ones (gate overhead is linear, error compounding
   is exponential).

`plan.md` format — **the Stop gate parses this; keep it exact**:

    # Plan: <title>
    <!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

    ## M1: <milestone title> [pending]
    - verify: `<command that fails today and passes when this milestone is done>`
    - risk: low

    ## M2: <title> [pending]
    - verify: `<command>`
    - risk: high

## 3 · Milestone loop

For each milestone in order:

1. Mark it `[in_progress]` in `plan.md` (exactly one at a time).
2. Spawn `executor` with: the task paths, the milestone text, and a reminder
   to read `spec.md` + `lessons.md` first.
3. Spawn `verifier` on the result — fresh context, adversarial.
4. **PASS** → mark `[done]`, commit (`feat(<slug>): M<n> <title>`), update
   `state.md` Now/Next in two lines, move on.
5. **FAIL** → escalation ladder below.
6. Every 3rd milestone, spawn `verifier` in **drift-check mode**: compare
   the accumulated diff against `spec.md` — still pointed at the acceptance
   criteria? any quiet scope creep?

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

After every failed rung: append what-was-tried / why-it-failed to
`lessons.md` — the next fresh context must not re-learn it. If the
`planner` / `plan-critic` / `reframer` agents are not installed, collapse
rungs 3–4 into stop-and-report.

## 5 · Completion

1. Final panel — 3 `verifier`s in parallel, one lens each: correctness vs
   spec / regression & side effects / test-integrity ("were tests
   weakened?"). Any FAIL → back into the loop as a repair milestone.
2. All green: mark everything `[done]`, delete `.ai_context/tasks/CURRENT`
   (keep the task dir), run `/wrap` (it archives the scoreboard to
   `journal/`), then offer to merge `task/<slug>` or open a PR.

## Rules

- Never claim done while a verify is red — the gate blocks it anyway.
- `plan.md` statuses are the compaction anchor: update them at every
  transition. The SessionStart hook re-injects plan + lessons after /clear
  and after compaction — stale statuses poison the re-anchor.
- Scoreboard (goes in the journal entry on completion): milestones total,
  gate failures, highest ladder rung used, human interventions. This is the
  data that says whether the harness earns its keep.
