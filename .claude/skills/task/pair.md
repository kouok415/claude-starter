# /task pair-codex — the Codex judge over herdr

Loaded only when the active profile is `pair-*`. Nothing here is injected
by default. Design and evidence: workshop ADR-028 (refined by ADR-029 plan
loop, ADR-030 fresh thread per packet) and
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
| `packet <role> <M<n>\|-> [--mode light\|full\|drift] [--lens L] [--changed a,b] [--since REF] [--rebuttal FILE] [--budget TEXT] [--candidate FILE] [--round N]` | write the next packet: header, task paths, the inlined milestone section / acceptance criteria / frozen plan candidate, mode or lens framing, ledger rows, result contract; prints its path | 0 · 2 refused (unknown milestone, missing inputs, unwired role) · 6 plan round cap |
| `digest <file>` | `plan:<sha256>` of a frozen plan candidate — the version a critic pass is bound to | 0 |
| `send <packet>` | freeze + digest the packet, fingerprint the tree, `/new` the judge (every packet runs in a fresh thread), prompt, wait (≤540 s per call), collect, log | 0 completed · 4 blocked/dialog · 5 in flight or busy · 6 no usable result |
| `wait <seq>` | keep waiting for an in-flight run (chain after exit 5) | as `send` |
| `reset` | `/new` to the judge by hand — `send` already does it before every packet; logged | 0 · 3 no judge · 4 not idle after |
| `status` | judge record + one line per seq from the runlog; flags any `start` row that no `reset` row precedes | 0 |

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
  `ts seq event role milestone base digest model tokens rollout detail`;
  events `reset`, `start`, `waiting`, `end:<state>` — `send` writes a
  `reset` row (same seq) right before its `start` row; a `start` row with
  no `reset` before it means the judge was prompted around the script.
  `model` and `tokens`
  (cumulative `in/out`) are the status line as observed at that moment —
  Codex can switch its own model under rate pressure, so read the
  scoreboard per model, never per profile alone; a run's cost is the
  token delta between its start and end rows. `rollout` is the judge's
  own transcript (`~/.codex/sessions/…/rollout-*.jsonl`, the newest one
  whose cwd is this repo and which started after the judge): the result
  file is the judge's self-report, the rollout is what it actually ran.
  Codex creates the rollout at the first turn, so `start`/`reset` rows
  may show `?` or the previous thread; the `end:` row is the link. Both
  observed columns are `?` when Codex's status line is truncated (long
  cwd, narrow pane).
- `NNN-<role>.screen.txt` / `dialog-*.screen.txt` / `start-*.screen.txt`
  — the judge's screen saved whenever a run did not settle `completed`,
  a dialog was refused, or startup was not ready. Forensics, not memory.

## Operator notes

- The judge is one Codex session per task, but every packet runs in a
  fresh thread: `send` sends `/new` and waits for idle before prompting
  (ADR-030). What it remembers of earlier stages is anchoring, not
  evidence — packets carry paths to everything it needs. `reset` remains
  for a hand `/new`.
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

### §1 spec — critique before the first plan

After spec.md is drafted and BEFORE round 0 (the planner packet binds to
the spec digest, so the spec must settle first):
`packet spec-critic -` → `send`. The seat is Codex-only (no Claude agent
does this — you hold the human conversation), so its contract is inlined
by the script. Rule each finding into `pair/ledger.md` (`stage: spec`):

- executability blockers ⇒ rewrite the AC as a command (accepted);
- ambiguity / direction-question candidates ⇒ attended: put them to the
  human with the direction question — Codex's candidates make "what would
  make you reject this even with every AC green?" concrete; `--auto`:
  decide, record as `[ASSUMED: ...]`;
- vetoable assumptions ⇒ same path.

One critique round; a second only if a blocker was rewritten (it runs
against the new digest). Spec edits after that are the plan-stage
critics' business (their packets carry the ACs).

### §0.5 brief — audit after the scout

After the scout writes brief.md and BEFORE planners read it:
`packet brief-audit -` → `send`. Contradicted load-bearing claims ⇒ you
append dated one-liners under `## Corrections` in brief.md (INDEX's
writing protocol) and a ledger row (`stage: brief`); a contradicted
claim the whole plan would rest on ⇒ re-spawn the scout for that area.
Missing items the spec needs ⇒ append them too. Unverifiable claims stay
tagged `[UNVERIFIED]` as the scout left them.

### §2 plan — the convergence loop

Plan-stage packets bind to digests, not commits: `planner` to
`spec:<sha256 of spec.md>`, `plan-critic` to `plan:<sha256 of the frozen
candidate file>` (`task-pair.sh digest <file>` prints it). A pass is a
pass on that digest only.

    round 0   Claude planner(s) per the size table  +  Codex planner, one lens
              → you synthesize v1 (plan.md)
    round 1   freeze v1: copy plan.md to pair/plan-v1.md; D_1 = digest
              spawn Claude plan-critic (background) on the frozen copy — the
              baseline's one critic pass, on the candidate where Claude's
              own blind spots are densest
              packet plan-critic - --candidate pair/plan-v1.md --round 1 → send
              both results: no blocker, no major ⇒ CONVERGED → kickoff brief
              else rule every finding (below) → v2 → round 2
    round r≥2 freeze v_r; Codex critic only:
              packet plan-critic - --candidate pair/plan-v<r>.md --round r → send
              no blocker, no major ⇒ CONVERGED
              else rule every finding → v_{r+1} → next round
    cap 10    `packet --round 11` is refused (exit 6): stop, put the open
              ledger rows in the kickoff brief, the human decides

1. **Round 0.** `packet planner - --lens <lens> --budget "<the profile's
   milestone budget>"` → `send`. The candidate is the result body below
   the header, in the gate-parseable plan.md format. Give Codex a lens the
   Claude planners do not have (M: Claude 1 + Codex 1; L: Claude 3 +
   Codex 1 — `reference.md` §Planner lenses; L's fourth lens is defined in
   one line in `--lens`). Synthesize as today.
2. **Critics.** Round 1 runs both critics on the SAME frozen file; from
   round 2 the Codex critic is the only seat — Claude's critic shares
   weights with the planner and the synthesizer, so its value is one fresh
   look at v1, not a vote every round (ADR-029). Neither critic reads
   plan.md. Claude's round-1 findings go into the ledger too (`source:
   claude`, or `both` when the Codex critic raised the same one). A Codex no-verdict ×2 in any round hands that round's seat
   to a Claude `plan-critic` (§No-verdict rule).
3. **Ruling, per finding, into `pair/ledger.md`** (`stage: plan`, `ref:
   r<round>/<id>`): `accepted: <the concrete plan change>` — an accept
   without a plan edit is not a ruling; `rejected: <reason with evidence>`;
   `noted: <why the plan stays>` — minor findings only: true, not worth a
   plan change (a minor need not be accepted to be acknowledged); `open`
   only for spec/scope/preference questions that belong to the human, and
   for high-stakes findings (§ledger). Minor findings never block
   convergence; a finding without a checkable claim is at most minor.
4. **Re-raise rule.** The next critic packet carries the plan-stage ledger
   rows automatically; a rejected or noted finding may come back only with
   new evidence. If it comes back without, rule it `rejected: repeated without
   evidence` and move on — do not argue with it.
5. **Digest binding.** Any edit to plan.md after a critic passed
   invalidates that pass: freeze again, new round. This includes a rung-4
   reframer patch mid-run — the remaining milestones re-enter the loop
   from round 1 (completed milestones stay).
6. **Structural escalation** (SKILL.md §0.5 M rule) still applies: two
   consecutive candidates with blocker-level structural findings ⇒ the
   3-lens Claude fan-out; the Codex lens joins it.

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
  `pair/ledger.md` as `rejected: <command + output>` (high-stakes: `open`
  with that evidence, §ledger) and treat that side as pass. No opinion overrides a command; no rebuttal round at
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
2. Codex side, per lens in turn: `packet final-verifier - --lens <lens>
   --since <task base commit>` → `send` (`--since` is where the task
   branch started, e.g. `git merge-base main task/<slug>`; the judge
   diffs `<since>..HEAD`). `send`'s own `/new` is what keeps the three
   lenses independent inside one Codex session.
3. Union all six results. Every finding is a candidate; nothing is
   averaged away.
4. One rebuttal round, only for lenses where exactly one side failed:
   - Codex failed, Claude passed → spawn a fresh `final-verifier` for that
     lens with the Codex result path and: "for each finding, reproduce it
     (command + output) or refute it (command + output)".
   - Claude failed, Codex passed → `packet final-verifier - --lens <lens>
     --since <base> --rebuttal pair/claude-<lens>.result.md` → `send`.
5. Resolution, per finding, into `pair/ledger.md`:
   - reproduced by either side ⇒ `confirmed` ⇒ FAIL ⇒ repair milestone;
   - refuted with a command ⇒ `rejected: <command + output>`
     (high-stakes: `open` with that evidence, §ledger);
   - neither ⇒ `open` — listed to the human. Open blocker/major findings
     hold completion like an un-acked checkpoint: attended runs ask;
     `--auto` runs stop at the completion report with the list. Never a
     vote, never a tie-break by count.
6. "Both pass" = all six lenses `pass` on the final HEAD, or every fail
   resolved `rejected`. Any commit after a lens ran invalidates that lens:
   the Codex side is refused by the base check (re-`packet`), the Claude
   side is re-spawned.

### `pair/ledger.md` (orchestrator-written, append-only)

    | stage | ref | source | seats | severity | claim | resolution |
    |---|---|---|---|---|---|---|
    | verify | M3 | codex | 1 | major | `bash t.sh` exits 1 | confirmed |
    | plan | r1/2 | both | 2 | minor | M4 demo line names no command | noted: M4 verify already prints the count |
    | final | test-integrity | claude | 2 | minor | tolerance loosened in x_test.py:40 | rejected: `git log -p` shows spec.md AC2 change with lessons entry |

`stage` is `spec` / `brief` / `plan` / `verify` / `drift` / `final`; plan
rows use `ref: r<round>/<id>` and are what the next critic packet
carries. `source` is who raised it: `codex`, `claude`, `both` (each seat
raised it independently on the same base) or `orchestrator` (you, or an
executor's own report); a Claude agent sitting the Codex seat after a
no-verdict is `claude`. `seats` is how many seats judged that base — `2`
at plan round 1, `risk: high` verify and the final panel, `1` everywhere
else — so a `codex`-only row counts as a catch Claude missed only where
`seats` is `2`. A ledger started before these columns keeps its header.

**High-stakes findings are the human's.** A finding about security, data
loss, or real money / live orders is never `rejected` or `noted` by you,
at any stage: fix it (`accepted` / `confirmed`) or rule it `open` with
your refuting evidence in the row. Open rows are listed in the completion
report; open blocker/major ones hold completion like §5 step 5's.

### Seats that stay Claude-only

`scout` (writes brief.md), `executor`, `reframer`: production seats.
`packet` refuses them — the judge checks, it does not produce the
artifacts the task runs on. (The planner candidate is the one exception,
and it is an input to your synthesis, never the plan itself.)
