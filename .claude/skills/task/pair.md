# /task pair-codex — the Codex judge over herdr

Loaded only when the active profile is `pair-*`. Nothing here is injected
by default. Design and evidence: workshop ADR-028 and
`tools/reviews/2026-09-15-task-pair-mode.md`.

## What the profile means

`/task --profile=pair-codex` keeps every Claude agent on `inherit` and adds
one non-Claude seat: a **Codex judge** running in a sibling herdr pane on
the user's current Codex default. Roles are fixed — Claude produces, Codex
checks — so the executor/spawnlog/gate path is untouched and the
scoreboard's `profile` column separates pair tasks from the same-model
baseline. The judge never writes the tree, never advances the plan, never
touches shared memory; it returns files, you decide.

Requirements, all checked mechanically by `scripts/task-pair.sh`:

- the session runs inside herdr (`HERDR_ENV=1`, `herdr` on PATH);
- the repo is trusted in Codex (`~/.codex/config.toml` `[projects."<repo>"]`);
- `plan.md`'s header profile is `pair-*` — the header IS the mode switch;
- if `.codex/hooks.json` exists, the judge must have been started by the
  script (hooks disabled). Codex hooks are Claude-compatible, so a Stop or
  SubagentStart hook copied from `.claude/` would run a second gate inside
  the judge and write gatelog/spawnlog rows — one orchestrator, one gate.

## Lifecycle — `scripts/task-pair.sh`

| Command | Does | Exit |
|---|---|---|
| `ensure` | find the judge (`judge-<slug>`) or split a pane and start it: `codex -s workspace-write -c features.hooks=false -c 'project_doc_fallback_filenames=["CLAUDE.md"]'` — no model/effort args | 0 · 3 refused · 4 human needed |
| `send <packet>` | freeze + digest the packet, fingerprint the tree, prompt the judge, wait (≤540 s per call), collect, log | 0 completed · 4 blocked/dialog · 5 in flight or busy · 6 no usable result |
| `wait <seq>` | keep waiting for an in-flight run (chain after exit 5) | as `send` |
| `status` | judge record + one line per seq from the runlog | 0 |

The script decides only `run_state`; the verdict is whatever the judge
wrote in the result file. It never prints PASS/FAIL. A run that ends
without a result, with a malformed header, for another base, after the
tree changed, stalled, timed out or blocked is **not** a pass — treat it as
"no verdict", inspect, write a NEW packet if a retry is warranted.

One orchestrator tool call is capped at 600 s. `send` returns 5 on a herdr
timeout and names `wait <seq>`; chain waits in the foreground — the Stop
gate does not know about external runs, so do not end the turn with a run
in flight.

## Packet — `tasks/<slug>/pair/NNN-<role>[-M<n>].md`

Written by you, frozen once sent (the script records its sha256).

    role: verifier            # the role contract is .claude/agents/<role>.md
    milestone: M3             # or `-`
    base: <commit or plan digest>

    # Task
    - spec: .ai_context/tasks/<slug>/spec.md
    - brief: .ai_context/tasks/<slug>/brief.md
    - lessons: .ai_context/tasks/<slug>/lessons.md
    - changed files: <list>   # verifier light mode
    <the FULL milestone section, inlined — never "read plan.md">

    # Result contract
    Write <this path with .result.md> starting with exactly:
      run: completed|failed|blocked
      verdict: pass|fail|inconclusive
      base: <the base above, verbatim>
      findings: <n> (blocker/major/minor)
      assumptions: [...]
    then the findings, each with a reproducible claim (command or
    file:line). Do not modify any file outside tasks/<slug>/pair/.

Packets carry paths, not copies: the judge runs on the same machine in the
same repo and reads the task files itself. Role bodies stay single-source
in `.claude/agents/` — never paste a second copy. A commit-shaped `base`
must equal HEAD at send time (stale packets are refused); a plan-critique
packet uses the plan digest instead.

## Result, ledger, runlog

- `NNN-<role>[-M<n>].result.md` — judge-written; header checked, then
  yours to read. Kept even when voided (evidence).
- `plan-ledger.md` — append-only, one row per finding across plan rounds:
  `round | id | source | severity | claim | resolution`. Only you write it.
- `runlog` — script-written, tab-separated:
  `ts seq event role milestone base digest model detail`; events `start`,
  `waiting`, `end:<state>`. The model column is the status line as
  observed at that moment — Codex can switch its own model under rate
  pressure, so read the scoreboard per model, never per profile alone.

## Operator notes

- The judge is one fresh Codex session per task; its context persists
  across milestones. Before each final-panel lens, `herdr agent prompt
  judge-<slug> "/new"` resets it (verified offline).
- herdr reports `idle` while Codex modal dialogs are open. The script scans
  the screen before and after every prompt: the rate-limit "switch model"
  nudge is dismissed with `esc` (keeps the model); a directory-trust or
  unknown dialog is reported and the run refused — answer it in the pane.
  Choosing "Keep current model (never show again)" once removes the nudge.
- Codex quota is a separate budget. The judge shows the remaining-limit
  warnings on its status screen; `ensure` prints the observed model.
- Sandbox: `workspace-write` writes cwd + `/tmp` only (`read-only` cannot
  even `mktemp`, so verify commands could not run). The tree fingerprint
  before/after each run is the mechanical "reviewer changed nothing".

## Stage wiring

Which stage sends which packet (spec/brief critique, plan rounds, verify
tiers, drift, final panel) is added to this file as each stage ships; the
transport above is complete and tested (`tests/run.sh` L1-23) on its own.
