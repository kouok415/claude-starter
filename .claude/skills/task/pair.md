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
| `packet <role> <M<n>\|-> [--mode light\|full\|drift] [--lens L] [--changed a,b] [--since REF] [--rebuttal FILE]` | write the next packet: header, task paths, the inlined milestone section / acceptance criteria, mode or lens framing, result contract; prints its path | 0 · 2 refused (unknown milestone, missing inputs, unwired role) |
| `send <packet>` | freeze + digest the packet, fingerprint the tree, prompt the judge, wait (≤540 s per call), collect, log | 0 completed · 4 blocked/dialog · 5 in flight or busy · 6 no usable result |
| `wait <seq>` | keep waiting for an in-flight run (chain after exit 5) | as `send` |
| `reset` | `/new` to the judge — fresh context between final-panel lenses; logged | 0 · 3 no judge · 4 not idle after |
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

Written by `task-pair.sh packet`, frozen once sent (the script records
its sha256). Shape, for reference:

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
- `ledger.md` — append-only, one row per finding that needed a ruling
  (format under §Stage wiring). Only you write it.
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

Every packet comes from `task-pair.sh packet` — never hand-written — so
the judge's inputs are a script's output, not a memory. `send` blocks;
on exit 5 chain `wait <seq>`. Read the result file yourself; the script's
summary line only echoes it.

### No-verdict rule (all stages)

A run that ends with exit 4/6, or with `verdict: inconclusive`, is a
**no-verdict**, never a pass. Once: write a NEW packet (same inputs) and
send again — never resend the same file. Twice: fall back to the Claude
agent for that seat (`verifier` / `final-verifier`), and append to
`lessons.md`: `pair: judge no-verdict ×2 at <stage> M<n> (<reasons>) —
Claude seat used`. Exit 4 means the human must act in the pane first.

### §3.3 verification, by risk

- `low` — unchanged: the gate is the only net.
- `med` — the Codex judge REPLACES the Claude verifier:
  1. `pk=$(bash scripts/task-pair.sh packet verifier M<n> --changed <files>)`
  2. `bash scripts/task-pair.sh send "$pk"`
  3. `verdict: pass` → step 4 (PASS). `verdict: fail` → step 5 (FAIL); the
     result's findings are the rung's failure evidence and go into
     `lessons.md` in the usual one-line form.
- `high` — BOTH seats, both must pass: spawn the Claude `verifier` (full
  protocol) first — it runs in the background — then send
  `packet verifier M<n> --mode full`. Either `fail` ⇒ FAIL. When the two
  disagree, run the failing side's reproduction command yourself: it
  reproduces ⇒ FAIL stands; it does not ⇒ append the finding to
  `pair/ledger.md` as `rejected: <command + output>` and treat that side
  as pass. No opinion overrides a command; no rebuttal round at
  milestone level.

### §3.6 drift check

`packet verifier M<n> --mode drift --since <commit>` where `<commit>` is
the previous drift check's HEAD (first time: the task's base commit).
`fail` (DRIFTING) ⇒ a repair milestone, exactly as today.

### §5 final panel — both sides, all three lenses

Under `pair-*` the final check is always the 3-lens panel on both sides,
whatever the size table's last column says (user ruling, ADR-028).

1. Spawn the three Claude `final-verifier` lenses (background). Save each
   returned verdict + findings verbatim as
   `pair/claude-<lens>.result.md` (same header as a judge result) — the
   rebuttal round needs files, not transcripts.
2. Codex side, per lens in turn: `reset` → `packet final-verifier -
   --lens <lens> --since <task base commit>` → `send` (`--since` is where
   the task branch started, e.g. `git merge-base main task/<slug>`; the
   judge diffs `<since>..HEAD`). `reset` is what keeps the three lenses
   independent inside one Codex session.
3. Union all six results. Every finding is a candidate; nothing is
   averaged away.
4. One rebuttal round, only for lenses where exactly one side failed:
   - Codex failed, Claude passed → spawn a fresh `final-verifier` for that
     lens with the Codex result path and: "for each finding, reproduce it
     (command + output) or refute it (command + output)".
   - Claude failed, Codex passed → `reset` → `packet final-verifier -
     --lens <lens> --since <base> --rebuttal pair/claude-<lens>.result.md`
     → `send`.
5. Resolution, per finding, into `pair/ledger.md`:
   - reproduced by either side ⇒ `confirmed` ⇒ FAIL ⇒ repair milestone;
   - refuted with a command ⇒ `rejected: <command + output>`;
   - neither ⇒ `open` — listed to the human. Open blocker/major findings
     hold completion like an un-acked checkpoint: attended runs ask;
     `--auto` runs stop at the completion report with the list. Never a
     vote, never a tie-break by count.
6. "Both pass" = all six lenses `pass` on the final HEAD, or every fail
   resolved `rejected`. Any commit after a lens ran invalidates that lens:
   the Codex side is refused by the base check (re-`packet`), the Claude
   side is re-spawned.

### `pair/ledger.md` (orchestrator-written, append-only)

    | stage | ref | source | severity | claim | resolution |
    |---|---|---|---|---|---|
    | verify | M3 | codex | major | `bash t.sh` exits 1 | confirmed |
    | final | test-integrity | claude | minor | tolerance loosened in x_test.py:40 | rejected: `git log -p` shows spec.md AC2 change with lessons entry |

`stage` is `verify` / `drift` / `final` (the plan loop adds `plan`).

### Not wired yet

Plan convergence rounds (Codex planner candidate + critic seat, ledger
rows `stage: plan`) and the spec/brief critique land as their own stages;
`packet` refuses those roles until then.
