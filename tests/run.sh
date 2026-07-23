#!/usr/bin/env bash
#
# tests/run.sh — claude-starter harness regression suite.
#
#   L1: mechanism level  — hooks and sync logic against fixtures
#   L2: integration level — mechanisms inside a really-spawned project
#
# No model calls; safe for CI. Fixtures are spec-faithful (plan.md carries
# the format comment header — the v3.2 P0 escaped precisely because a
# fixture omitted it). Exit 0 = all green; SKIPs don't fail the run.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO/.claude/hooks/stop-gate.sh"
SS="$REPO/.claude/hooks/session-start.sh"

export GIT_AUTHOR_NAME=harness-tests GIT_AUTHOR_EMAIL=tests@local
export GIT_COMMITTER_NAME=harness-tests GIT_COMMITTER_EMAIL=tests@local

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
no()   { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
skp()  { SKIP=$((SKIP+1)); echo "SKIP: $*"; }
ck()   { local want="$1" got="$2"; shift 2; if [ "$want" = "$got" ]; then ok "$*"; else no "$* (want rc=$want got rc=$got)"; fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK" "${TMPDIR:-/tmp}"/claude-setup-nudge-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-integrity-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-red-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-stuck-tsuite-* "$REPO/.secrets/l2-seeded-fake-cred.tmp" "$REPO/l2-seeded-untracked.tmp" ; }
trap cleanup EXIT

# Spec-faithful plan fixture: format header INCLUDED, one in_progress.
write_plan() { # $1 = path, $2 = M2 verify command
  cat > "$1" <<EOF
# Plan: fixture
<!-- profile: opus-tier | fable-tier | mixed ; size: S | M | L -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: groundwork [done]
- verify: \`false\`
- risk: low

## M2: current [in_progress]
- verify: \`$2\`
- risk: low

## M3: future [pending]
- verify: \`false\`
- risk: high
EOF
}

echo "=== L1-1 · stop-gate: setup gate"
D="$WORK/l11"; mkdir -p "$D/.ai_context"
printf '# t\n- **Install:** `<command>`\n' > "$D/CLAUDE.md"
printf '{"session_id": "tsuite-a"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "newborn project blocks first stop"
printf '{"session_id": "tsuite-a"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "same session yields on second stop"
printf '{"session_id": "tsuite-b"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "new session re-arms"
printf '{"stop_hook_active": true, "session_id": "tsuite-c"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "stop_hook_active loop protection wins"
printf '# t\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
printf '{"session_id": "tsuite-d"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "drafted CLAUDE.md passes forever"

echo "=== L1-2 · stop-gate: milestone gate (spec-faithful plans)"
D="$WORK/l12"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
printf '{"session_id": "tsuite-e"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "green verify passes (format header not miscounted)"
grep -q "	M2	PASS" "$D/.ai_context/tasks/demo/gatelog" && ok "gatelog PASS row carries milestone id" || no "gatelog PASS row missing/wrong"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'sh -c "echo boom; exit 1"'
err=$(printf '{"session_id": "tsuite-e"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "red verify blocks"
echo "$err" | grep -q "boom" && ok "failure output fed back" || no "failure output missing"
grep -q "	M2	FAIL" "$D/.ai_context/tasks/demo/gatelog" && ok "gatelog FAIL row" || no "gatelog FAIL row missing"
sed -i.bak 's/## M3: future \[pending\]/## M3: future [in_progress]/' "$D/.ai_context/tasks/demo/plan.md" && rm -f "$D/.ai_context/tasks/demo/plan.md.bak"
err=$(printf '{"session_id": "tsuite-e"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "true double in_progress blocks"
echo "$err" | grep -q '2 milestones' && ok "counts heading lines only (2, not 3)" || no "wrong in_progress count"
rm -f "$D/.ai_context/tasks/CURRENT"
printf '{"session_id": "tsuite-e"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "no active task => no-op"

echo "=== L1-2b · stop-gate: counted red blocks — third stop yields to the human"
D="$WORK/l12b"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "false"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "red block 1 still blocks"
printf '{"stop_hook_active": true, "session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "red block 2 blocks despite stop_hook_active (gate counts for itself)"
out=$(printf '{"stop_hook_active": true, "session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "third consecutive red stop yields"
echo "$out" | grep -q '"systemMessage"' && ok "yield carries a systemMessage for the human" || no "yield lacks systemMessage"
echo "$out" | grep -q 'demo / M2 is RED' && ok "systemMessage names task and milestone" || no "systemMessage vague"
grep -q "	M2	STUCK	" "$D/.ai_context/tasks/demo/gatelog" && ok "gatelog STUCK row written" || no "STUCK row missing"
n_fail=$(grep -c "	M2	FAIL" "$D/.ai_context/tasks/demo/gatelog")
[ "$n_fail" = 3 ] && ok "each attempt logged a FAIL row (3)" || no "FAIL rows: want 3 got $n_fail"
# F10: the yield is ONE handoff event — stop 4 keeps yielding (and keeps
# the human signal) but appends no second STUCK row.
out=$(printf '{"stop_hook_active": true, "session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "fourth red stop still yields"
echo "$out" | grep -q '"systemMessage"' && ok "repeat yield keeps pinging the human" || no "repeat yield lost the systemMessage"
n_stuck=$(grep -c "	M2	STUCK	" "$D/.ai_context/tasks/demo/gatelog")
[ "$n_stuck" = 1 ] && ok "exactly one STUCK row after four red stops (no over-count)" || no "STUCK rows: want 1 got $n_stuck"
# PASS resets the streak: fix the verify, pass once, break it again — blocks anew
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "green verify passes after yield"
write_plan "$D/.ai_context/tasks/demo/plan.md" "false"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "PASS reset the counter — new red streak blocks again"
# ...and re-armed the STUCK row: a post-PASS streak that yields again is a
# genuinely new handoff, so it logs a second row.
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "second streak: red block 2"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "second streak: third stop yields again"
n_stuck=$(grep -c "	M2	STUCK	" "$D/.ai_context/tasks/demo/gatelog")
[ "$n_stuck" = 2 ] && ok "a PASS re-armed the STUCK row (new handoff logged)" || no "post-PASS re-yield rows: want 2 got $n_stuck"
# a fresh session also starts a fresh streak
printf '{"session_id": "tsuite-red2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "new session counts from zero"

echo "=== L1-2c · stop-gate: red wrap-up sweep counted; /wrap --sweep stays strict"
D="$WORK/l12c"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: fixture
<!-- profile: opus-tier ; size: S -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: only [done]
- verify: `false`
- risk: low
PEOF
printf '{"session_id": "tsuite-swp"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "all-done red sweep blocks (1)"
printf '{"session_id": "tsuite-swp"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "all-done red sweep blocks (2)"
out=$(printf '{"session_id": "tsuite-swp"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "third red sweep yields"
echo "$out" | grep -q '"systemMessage"' && ok "sweep yield pings the human" || no "sweep yield silent"
grep -q "	sweep	STUCK	" "$D/.ai_context/tasks/demo/gatelog" && ok "sweep STUCK row" || no "sweep STUCK row missing"
printf '{"session_id": "tsuite-swp"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "fourth red sweep still yields"
n_sw=$(grep -c "	sweep	STUCK	" "$D/.ai_context/tasks/demo/gatelog")
[ "$n_sw" = 1 ] && ok "one sweep STUCK row after repeat stops (F10)" || no "sweep STUCK rows: want 1 got $n_sw"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 2 $? "explicit /wrap --sweep never yields (still strict after counted yields)"

echo "=== L1-2e · absent GNU timeout is loud (F11)"
D="$WORK/l12e"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
SH="$WORK/no-timeout-bin"; mkdir -p "$SH"
for b in bash sh grep sed awk date tr cat rm mv mkdir wc head tail dirname env; do
  p="$(command -v "$b" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$SH/$b" 2>/dev/null
done
err=$(printf '{"session_id": "tsuite-tmo"}' | PATH="$SH" CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 0 $rc "gate still passes a green verify without the timeout binary"
echo "$err" | grep -q 'UNBOUNDED' && ok "missing timeout binary warned (no silent void)" || no "missing timeout stayed silent (F11)"
err=$(printf '{"session_id": "tsuite-tmo2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
echo "$err" | grep -q 'UNBOUNDED' && no "timeout present but warned anyway" || ok "no warning when timeout exists"

echo "=== L1-2d · spawn-log + no-spawn diagnosis"
SL="$REPO/.claude/hooks/spawn-log.sh"
D="$WORK/l12d"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
# unit: no active task => no rows anywhere
printf '{}' | CLAUDE_PROJECT_DIR="$D" bash "$SL" executor
ck 0 $? "spawn-log without CURRENT is a no-op"
[ ! -e "$D/.ai_context/tasks/demo/spawnlog" ] && ok "no spawnlog created without a task" || no "stray spawnlog"
echo demo > "$D/.ai_context/tasks/CURRENT"
# intake state: scout spawned before any milestone arms -> ms '-'
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: fixture
<!-- profile: opus-tier ; size: M -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: groundwork [pending]
- verify: `false`
- risk: low

## M2: current [pending]
- verify: `false`
- risk: low
PEOF
printf '{}' | CLAUDE_PROJECT_DIR="$D" bash "$SL" other
grep -q "	-	other$" "$D/.ai_context/tasks/demo/spawnlog" && ok "intake spawn rows carry '-' (capability handshake)" || no "intake row wrong"
# arm M2, spawn executor => attributed row
sed -i.bak 's/## M2: current \[pending\]/## M2: current [in_progress]/' "$D/.ai_context/tasks/demo/plan.md" && rm -f "$D/.ai_context/tasks/demo/plan.md.bak"
printf '{}' | CLAUDE_PROJECT_DIR="$D" bash "$SL" executor
grep -q "	M2	executor$" "$D/.ai_context/tasks/demo/spawnlog" && ok "executor row attributed to the armed milestone" || no "executor row wrong"
# gate red with executor row present => ladder message, no accusation
err=$(printf '{"session_id": "tsuite-sl1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null)
echo "$err" | grep -q 'no executor spawn' && no "false no-spawn accusation despite executor row" || ok "executor row suppresses the hint"
echo "$err" | grep -q 'escalate per the /task ladder' && ok "ladder guidance kept when spawn evidence exists" || no "ladder guidance missing"
# arm M1 instead (no executor row for it) => diagnosis fires
sed -i.bak -e 's/## M2: current \[in_progress\]/## M2: current [pending]/' -e 's/## M1: groundwork \[pending\]/## M1: groundwork [in_progress]/' "$D/.ai_context/tasks/demo/plan.md" && rm -f "$D/.ai_context/tasks/demo/plan.md.bak"
err=$(printf '{"session_id": "tsuite-sl2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null)
echo "$err" | grep -q 'no executor row for M1' && ok "no-spawn diagnosis fires for the armed milestone" || no "no-spawn diagnosis missing"
echo "$err" | grep -q 'rung 1' && ok "diagnosis redirects to rung 1, not the ladder" || no "redirect missing"
# the third red carries the note into the human ping
printf '{"session_id": "tsuite-sl2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
out=$(printf '{"session_id": "tsuite-sl2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "third red still yields with diagnosis active"
echo "$out" | grep -q 'no executor spawn recorded' && ok "systemMessage carries the no-spawn note" || no "note missing from systemMessage"
# empty spawnlog (event never fired) => silence, never accusation
: > "$D/.ai_context/tasks/demo/spawnlog"
err=$(printf '{"session_id": "tsuite-sl3"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null)
echo "$err" | grep -q 'no executor' && no "accusation from an empty spawnlog" || ok "empty spawnlog stays silent (old-CC safety)"
# missing spawnlog => same silence
rm -f "$D/.ai_context/tasks/demo/spawnlog"
err=$(printf '{"session_id": "tsuite-sl4"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null)
echo "$err" | grep -q 'no executor' && no "accusation without spawnlog" || ok "missing spawnlog stays silent"
# size S (in-context execution by design) => no accusation even with rows
D="$WORK/l12ds"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "false"
printf '%s\t-\tother\n' "2026-07-22T00:00:00" > "$D/.ai_context/tasks/demo/spawnlog"
err=$(printf '{"session_id": "tsuite-sl5"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null)
echo "$err" | grep -q 'no executor' && no "S-size task accused of not spawning" || ok "S size suppresses the diagnosis"
# wiring: settings.json routes SubagentStart and denies hand edits
grep -q '"SubagentStart"' "$REPO/.claude/settings.json" && ok "settings routes SubagentStart" || no "SubagentStart missing from settings"
grep -q 'spawn-log.sh\\" executor' "$REPO/.claude/settings.json" && ok "executor matcher wired" || no "executor matcher missing"
grep -q 'Edit(./.ai_context/tasks/\*\*/spawnlog)' "$REPO/.claude/settings.json" && ok "spawnlog Edit-denied" || no "spawnlog not Edit-denied"

echo "=== L1-3 · session-start: injection + warnings"
D="$WORK/l13"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# n\n- **Dev:** `<command>`\n' > "$D/CLAUDE.md"
printf 'Last updated: 2026-01-01\nbody\n' > "$D/.ai_context/state.md"
printf 'idx\n' > "$D/.ai_context/INDEX.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
printf 'lesson-x\n' > "$D/.ai_context/tasks/demo/lessons.md"
printf 'SPEC-MARKER goal line\n' > "$D/.ai_context/tasks/demo/spec.md"
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" commit -qm x
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'SETUP REQUIRED' && ok "newborn instruction emitted" || no "newborn instruction missing"
echo "$out" | grep -q 'INDEX.md ===' && ok "INDEX injected" || no "INDEX missing"
echo "$out" | grep -q 'lesson-x' && ok "active task plan+lessons injected" || no "task injection missing"
echo "$out" | grep -q 'SPEC-MARKER' && ok "spec.md injected on active task (intent anchor)" || no "spec.md not injected"
echo "$out" | grep -q 'days ago' && ok "stale-state warning (S3)" || no "stale warning missing"
echo "$out" | grep -q 'ended without /wrap' && ok "unwrapped-session warning" || no "unwrapped warning missing"
echo "$out" | grep -q 'milestone gate is OFF' && no "false status warning while in_progress exists" || ok "no false status warning"
D2="$WORK/l13b"; mkdir -p "$D2"
printf '# n2\n- **Dev:** `<command>`\n' > "$D2/CLAUDE.md"
out=$(CLAUDE_PROJECT_DIR="$D2" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'SETUP REQUIRED' && ok "newborn instruction without .ai_context (domain matches gate)" || no "newborn instruction gated on .ai_context"
D3="$WORK/l13c"; mkdir -p "$D3/.ai_context/tasks"
printf '# n3\n## Commands\n- Test: `true`\n' > "$D3/CLAUDE.md"
printf '# s\n- decoy deadline 2026-01-01\n\n_Last updated: %s_\n' "$(date +%F)" > "$D3/.ai_context/state.md"
printf 'idx\n' > "$D3/.ai_context/INDEX.md"
echo ghost > "$D3/.ai_context/tasks/CURRENT"
out=$(CLAUDE_PROJECT_DIR="$D3" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'days ago' && no "body date shadowed the Last-updated line (anchoring broken)" || ok "freshness anchored to the Last-updated line"
echo "$out" | grep -q 'plan.md is missing' && ok "dangling CURRENT warned" || no "dangling CURRENT not warned"

echo "=== L1-3b · session-start: filtered plan view"
D="$WORK/l13d"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# n\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
printf '_Last updated: %s_\n' "$(date +%F)" > "$D/.ai_context/state.md"
printf 'idx\n' > "$D/.ai_context/INDEX.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: fixture
<!-- profile: opus-tier ; size: L -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->
HEADER-NOTE-KEEP

## M1: groundwork [done]
- verify: `true`
- risk: low

<!-- DONE-NOTE-HIDE: long retrospective commentary -->

## M2: current [in_progress]
- verify: `true`
- risk: high

<!-- CURRENT-NOTE-KEEP: exactly what the executor needs -->

## M3: future [pending]
- verify: `test -s artifact.md`
- risk: med

<!-- FUTURE-NOTE-HIDE: design ahead of its time -->
PEOF
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q '(filtered view' && ok "filtered view self-declares" || no "no filter declaration"
echo "$out" | grep -q 'HEADER-NOTE-KEEP' && ok "plan header block kept" || no "header block lost"
echo "$out" | grep -q 'CURRENT-NOTE-KEEP' && ok "armed milestone keeps its full section" || no "armed section truncated"
echo "$out" | grep -q 'DONE-NOTE-HIDE' && no "done-milestone commentary leaked" || ok "done-milestone commentary filtered"
echo "$out" | grep -q 'FUTURE-NOTE-HIDE' && no "future-milestone commentary leaked" || ok "future-milestone commentary filtered"
echo "$out" | grep -q '## M3: future \[pending\]' && ok "all milestone headings survive" || no "heading lost"
echo "$out" | grep -c 'test -s artifact.md' >/dev/null && ok "non-current verify lines survive (gate contract visible)" || no "verify line lost"
# oversized armed section still warns
python3 - "$D/.ai_context/tasks/demo/plan.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('<!-- CURRENT-NOTE-KEEP: exactly what the executor needs -->',
              '<!-- CURRENT-NOTE-KEEP ' + 'x' * 9000 + ' -->')
open(p, 'w').write(s)
PY
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'filtered plan view is' && ok "oversized filtered view warns" || no "no size warning on bloated armed section"

echo "=== L1-3c · task lifecycle warnings (F22, F23)"
D="$WORK/l13e"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# n\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
printf '_Last updated: %s_\n' "$(date +%F)" > "$D/.ai_context/state.md"
printf 'idx\n' > "$D/.ai_context/INDEX.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: fixture
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: a [done]
- verify: `true`
- risk: low

## M2: b [done]
- verify: `true`
- risk: low
PEOF
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'run /wrap to write the scoreboard row' && ok "all-done + CURRENT nudges close-out (F22)" || no "finished-but-unclosed state got no nudge"
echo "$out" | grep -q 'raw plan.md is' && no "small plan falsely size-warned" || ok "small raw plan stays quiet"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'run /wrap to write the scoreboard row' && no "in-flight task falsely nudged to close" || ok "in-flight task gets no close-out nudge"
python3 - "$D/.ai_context/tasks/demo/plan.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p,'w').write(s + '\n<!-- pad ' + 'x'*17000 + ' -->\n')
PY
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'raw plan.md is' && ok "oversized raw plan.md warned (F23)" || no "40 KB-class raw plan went unseen"
echo "$out" | grep -q 'filtered plan view is' && no "pad leaked into the filtered view" || ok "filtered view stays small (pad filtered out)"

echo "=== L1-4 · sync: --update-stock + --adopt"
if [ ! -f "$REPO/sync-project.sh" ]; then
  skp "update-stock history test (spawned project — template-repo only)"
elif git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
  skp "update-stock history test (shallow clone — set fetch-depth: 0)"
else
  OLD_SHA="$(git -C "$REPO" log --format=%H -- .claude/hooks/stop-gate.sh | tail -1)"
  D="$WORK/l14"; mkdir -p "$D/.ai_context" "$D/.claude/hooks"
  printf '# project ignores\nnode_modules/\n' > "$D/.gitignore"
  cp "$REPO/.ai_context/INDEX.md" "$D/.ai_context/"
  git -C "$REPO" show "$OLD_SHA:.claude/hooks/stop-gate.sh" > "$D/.claude/hooks/stop-gate.sh"
  printf '{"custom": true}\n' > "$D/.claude/settings.json"
  out=$("$REPO/sync-project.sh" --update-stock "$D" 2>&1)
  cmp -s "$D/.claude/hooks/stop-gate.sh" "$REPO/.claude/hooks/stop-gate.sh" && ok "historical stock file advanced" || no "stock file not advanced"
  echo "$out" | grep -q 'settings.json differs from every known template version' && ok "customized file flagged, untouched" || no "customized handling wrong"
  grep -q custom "$D/.claude/settings.json" && ok "customized content preserved" || no "customized content clobbered"
  grep -q 'synced-to: claude-starter@' "$D/.claude/.starter-version" 2>/dev/null && ok "synced-to stamp appended on --update-stock" || no "synced-to stamp missing"
  [ -x "$D/scripts/harness-report.sh" ] && ok "new stock file (harness-report.sh) installed by sync" || no "harness-report.sh not installed — copy_if_missing pair missing"
  grep -q '^\.secrets/\*' "$D/.gitignore" && grep -q '^node_modules/' "$D/.gitignore" && ok "sync appends the .secrets/ gitignore block (project lines kept)" || no "sync .gitignore appender missed .secrets/"
  [ -f "$D/.secrets/.gitkeep" ] && ok "sync installs .secrets/.gitkeep" || no "sync did not create .secrets/"
  D5="$WORK/l14b"; mkdir -p "$D5/.ai_context" "$D5/.claude"
  cp -r "$REPO/.claude/hooks" "$REPO/.claude/skills" "$REPO/.claude/agents" "$REPO/.claude/settings.json" "$D5/.claude/"
  cp "$REPO/.ai_context/INDEX.md" "$D5/.ai_context/"
  cp "$REPO/.pre-commit-config.yaml" "$D5/"
  mkdir -p "$D5/scripts"; cp "$REPO/scripts/check-state-size.sh" "$REPO/scripts/precommit-gitleaks.sh" "$D5/scripts/"
  "$REPO/sync-project.sh" --update-stock "$D5" >/dev/null 2>&1
  grep -q 'synced-to: claude-starter@' "$D5/.claude/.starter-version" 2>/dev/null && ok "added-only sync still appends the synced-to stamp (attribution integrity)" || no "added-only sync left no stamp — harness column would mis-attribute"
  # F15: the DEFAULT (no-flag) invocation also mutates mechanisms — it must
  # stamp too, and a no-op re-run must not stamp again.
  D6="$WORK/l14c"; mkdir -p "$D6/.ai_context"
  cp "$REPO/.ai_context/INDEX.md" "$D6/.ai_context/"
  "$REPO/sync-project.sh" "$D6" >/dev/null 2>&1
  grep -q 'synced-to: claude-starter@' "$D6/.claude/.starter-version" 2>/dev/null && ok "no-flag sync that adds files appends the synced-to stamp (F15)" || no "no-flag sync left no stamp — version mis-attribution lives on"
  n1=$(grep -c 'synced-to' "$D6/.claude/.starter-version" 2>/dev/null)
  "$REPO/sync-project.sh" "$D6" >/dev/null 2>&1
  n2=$(grep -c 'synced-to' "$D6/.claude/.starter-version" 2>/dev/null)
  [ "$n1" = "$n2" ] && ok "no-op sync appends no stamp (no spam)" || no "no-op sync stamped anyway ($n1 -> $n2)"
fi
if [ -f "$REPO/sync-project.sh" ]; then
  unpaired=""
  while IFS= read -r f; do
    case "$f" in .ai_context/*) continue ;; esac # the .ai_context seed loop installs these when absent
    grep -q "^copy_if_missing $f\$" "$REPO/sync-project.sh" || unpaired="$unpaired $f"
  done < <(grep -o '^stock_update [^ ]*' "$REPO/sync-project.sh" | awk '{print $2}')
  [ -z "$unpaired" ] && ok "every stock_update file is installable when absent (copy_if_missing pair)" || no "stock_update without copy_if_missing pair:$unpaired"
  D="$WORK/l14a/existing"; mkdir -p "$D/src"; echo 'x=1' > "$D/src/m.py"
  "$REPO/sync-project.sh" "$D" >/dev/null 2>&1 && no "non-starter accepted without --adopt" || ok "non-starter rejected without --adopt"
  out=$("$REPO/sync-project.sh" --adopt "$D" 2>&1)
  { [ -f "$D/.ai_context/INDEX.md" ] && [ -f "$D/CLAUDE.md" ] && [ -d "$D/.ai_context/tasks" ]; } && ok "adopt creates skeleton" || no "adopt skeleton incomplete"
  echo "$out" | grep -q 'run /setup' && ok "adopt hands off to /setup" || no "adopt handoff missing"
  { [ -f "$D/.claude/agents/scout.md" ] && [ -f "$D/.claude/skills/task/reference.md" ]; } && ok "v3.3 files (scout, reference) land via sync" || no "scout/reference missing after sync"
else
  skp "sync pairing + adopt tests (spawned project — template-repo only)"
fi

echo "=== L1-5 · v3.3: sentinel gate, status warning, brief injection, caps"
D="$WORK/l15"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# t\n<!-- claude-starter: UNCONFIGURED — run /setup -->\nno legacy patterns here\n' > "$D/CLAUDE.md"
printf '{"session_id": "tsuite-s1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "sentinel-only CLAUDE.md arms the setup gate"
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'SETUP REQUIRED' && ok "sentinel arms session-start instruction" || no "sentinel missed by session-start"
if [ -d "$REPO/templates" ]; then
  n=$(grep -l 'claude-starter: UNCONFIGURED' "$REPO"/templates/CLAUDE.md.* | wc -l)
  [ "$n" -eq 3 ] && ok "all 3 templates carry the sentinel" || no "only $n/3 templates carry the sentinel"
else
  skp "template sentinel census (spawned project — template-repo only)"
fi
# F13: the sentinel pattern is one sourced constant — prove every token
# (sentinel + 3 legacy placeholders) arms BOTH layers, and the degraded-mode
# fallback literals in the two hooks byte-match the helper's constant.
for tok in 'claude-starter: UNCONFIGURED' '<e.g., pytest>' '- **Install:** `<command>`' 'Replace before first commit'; do
  DT="$WORK/l15tok"; rm -rf "$DT"; mkdir -p "$DT"
  printf '# t\n%s\n' "$tok" > "$DT/CLAUDE.md"
  out=$(CLAUDE_PROJECT_DIR="$DT" bash "$SS" </dev/null 2>&1)
  echo "$out" | grep -q 'SETUP REQUIRED' && ok "session-start arms on: $tok" || no "session-start missed: $tok"
  printf '{"session_id": "tsuite-tok"}' | CLAUDE_PROJECT_DIR="$DT" bash "$GATE" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "stop-gate arms on: $tok" || no "stop-gate missed: $tok"
  rm -f "${TMPDIR:-/tmp}/claude-setup-nudge-tsuite-tok"
done
fb_gp=$(grep -o "GUARD_SETUP_SENTINEL='[^']*'" "$REPO/.claude/hooks/guard-patterns.sh" | head -1)
fb_ss=$(grep -o "GUARD_SETUP_SENTINEL='[^']*'" "$SS" | head -1)
fb_sg=$(grep -o "GUARD_SETUP_SENTINEL='[^']*'" "$GATE" | head -1)
{ [ -n "$fb_gp" ] && [ "$fb_ss" = "$fb_gp" ] && [ "$fb_sg" = "$fb_gp" ]; } && ok "sentinel pattern identical: helper + both hook fallbacks (F13)" || no "sentinel pattern drift between the two layers (ADR-004)"

printf '# ok\n## Commands\n- Test: \`true\`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'EOF'
# Plan: fixture
<!-- profile: opus-tier ; size: S -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: a [done]
- verify: `true`
- risk: low

## M2: b [pending]
- verify: `true`
- risk: low
EOF
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'milestone gate is OFF' && ok "pending-without-in_progress warned (typo net)" || no "status-corruption warning missing"
printf '{"session_id": "tsuite-s2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "status typo (done+pending, no in_progress) blocks first stop (integrity)"
printf '{"session_id": "tsuite-s2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "status-typo integrity yields on second stop (marker)"
grep -q 'INTEGRITY' "$D/.ai_context/tasks/demo/gatelog" && ok "INTEGRITY row logged for dark-gate state" || no "INTEGRITY row missing"

printf 'BRIEF-CONTENT-MARKER\n' > "$D/.ai_context/tasks/demo/brief.md"
python3 - "$D/.ai_context/tasks/demo/lessons.md" <<'PY'
import sys; open(sys.argv[1],'w').write('lesson line\n'*500)
PY
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'BRIEF-CONTENT-MARKER' && ok "brief.md injected on active task" || no "brief.md not injected"
echo "$out" | grep -q 'cap 4096' && ok "oversized lessons.md warned" || no "lessons cap warning missing"

mkdir -p "$D/.claude/hooks"
cp "$REPO/.claude/hooks/post-edit.sh" "$D/.claude/hooks/"
printf '#!/usr/bin/env bash\nfor i in $(seq 1 100); do echo "line $i"; done\nexit 1\n' > "$D/.claude/hooks/lint.sh"
chmod +x "$D/.claude/hooks/lint.sh" "$D/.claude/hooks/post-edit.sh"
err=$(printf '{"file_path": "x.py"}' | CLAUDE_PROJECT_DIR="$D" bash "$D/.claude/hooks/post-edit.sh" 2>&1 >/dev/null); rc=$?
ck 2 $rc "post-edit propagates lint failure"
nl=$(printf '%s\n' "$err" | wc -l)
[ "$nl" -le 45 ] && ok "post-edit output bounded ($nl lines)" || no "post-edit output unbounded ($nl lines)"
# F14: present-but-non-executable lint.sh is a dark state — warn, never block.
chmod -x "$D/.claude/hooks/lint.sh"
err=$(printf '{"file_path": "x.py"}' | CLAUDE_PROJECT_DIR="$D" bash "$D/.claude/hooks/post-edit.sh" 2>&1 >/dev/null); rc=$?
ck 0 $rc "non-executable lint.sh does not block"
echo "$err" | grep -q 'not executable' && ok "non-executable lint.sh warned (F14)" || no "non-executable lint.sh silently dark"
chmod +x "$D/.claude/hooks/lint.sh"

echo "=== L1-6 · resident-size guards + security entries"
sz=$(wc -c < "$REPO/.ai_context/INDEX.md")
[ "$sz" -le 4096 ] && ok "INDEX.md within 4 KB ($sz B — injected every session)" || no "INDEX.md re-bloated ($sz B > 4096)"
sz=$(wc -c < "$REPO/.claude/skills/task/SKILL.md")
[ "$sz" -le 11264 ] && ok "task SKILL.md within 11 KB ($sz B)" || no "task SKILL.md bloated ($sz B) — move detail to reference.md"
sz=$(wc -c < "$REPO/.claude/skills/wrap/SKILL.md")
[ "$sz" -le 2560 ] && ok "wrap SKILL.md within 2.5 KB ($sz B — task machinery lives in reference.md)" || no "wrap SKILL.md bloated ($sz B > 2560)"
[ -f "$REPO/.claude/skills/wrap/reference.md" ] && ok "wrap reference.md exists (on-demand task close-out)" || no "wrap reference.md missing"
grep -q 'reference.md' "$REPO/.claude/skills/wrap/SKILL.md" && ok "wrap body points at the reference" || no "wrap body lost its reference pointer"
grep -qF 'duration_min,outcome,harness' "$REPO/.claude/skills/wrap/reference.md" && ok "wrap reference carries the scoreboard header (harness column)" || no "wrap reference missing the scoreboard header"
grep -qF 'Read(./**/.env)' "$REPO/.claude/settings.json" && ok "nested .env read-deny present" || no "nested .env deny missing"
grep -qxF '**/.env' "$REPO/.gitignore" && ok "nested .env gitignored" || no "nested .env gitignore missing"
grep -q 'gate-cache' "$REPO/.gitignore" && ok "gate-cache gitignored (fingerprint-safe)" || no "gate-cache ignore missing"
grep -qF 'Read(./.secrets/**)' "$REPO/.claude/settings.json" && grep -qF 'Read(./**/.secrets/**)' "$REPO/.claude/settings.json" && ok "secrets-dir read-deny present (root + nested)" || no "secrets-dir read-deny missing"
grep -qxF '.secrets/*' "$REPO/.gitignore" && grep -qxF '!.secrets/.gitkeep' "$REPO/.gitignore" && ok "secrets-dir gitignored, placeholder excepted (contents-form)" || no "secrets-dir gitignore block wrong"
grep -qxF '*.pem' "$REPO/.gitignore" && grep -qxF 'id_rsa*' "$REPO/.gitignore" && ok "key-material gitignored (closes the read-deny asymmetry)" || no "pem/id_rsa gitignore missing"
[ -f "$REPO/.secrets/.gitkeep" ] && ok "seed ships .secrets/.gitkeep" || no "seed .secrets placeholder missing"

echo "=== L1-7 · stop-gate PASS-cache (git-fingerprinted)"
D="$WORK/l17"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: \`true\`\n' > "$D/CLAUDE.md"
printf '.ai_context/tasks/*/.gate-cache\n' > "$D/.gitignore"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" commit -qm base
git -C "$D" checkout -qb task/demo
printf '{"session_id": "tsuite-c1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "green verify passes (run 1)"
printf '{"session_id": "tsuite-c1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "green verify passes (run 2, unchanged tree)"
n=$(grep -c 'PASS' "$D/.ai_context/tasks/demo/gatelog")
[ "$n" -eq 1 ] && ok "unchanged tree hit PASS-cache (1 gatelog row, not 2)" || no "PASS-cache missed ($n rows)"
echo change > "$D/newfile.txt"
printf '{"session_id": "tsuite-c1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
n=$(grep -c 'PASS' "$D/.ai_context/tasks/demo/gatelog")
[ "$n" -eq 2 ] && ok "tree change invalidated the cache (re-ran verify)" || no "cache not invalidated ($n rows)"
printf 'chAnge\n' > "$D/newfile.txt"
printf '{"session_id": "tsuite-c1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
n=$(grep -c 'PASS' "$D/.ai_context/tasks/demo/gatelog")
[ "$n" -eq 3 ] && ok "same-size untracked edit invalidated the cache (content hash)" || no "same-size edit missed ($n rows)"
grep -q "	M2	PASS	true" "$D/.ai_context/tasks/demo/gatelog" && ok "gatelog rows carry the verify command" || no "gatelog command column missing"
write_plan "$D/.ai_context/tasks/demo/plan.md" "false"
printf '{"session_id": "tsuite-c1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "red verify still blocks after prior caching"
[ ! -f "$D/.ai_context/tasks/demo/.gate-cache" ] && ok "FAIL clears the cache" || no "stale cache survives a FAIL"

echo "=== L1-10 · gate integrity: no silent disarm"
D="$WORK/l110"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
: > "$D/.ai_context/tasks/CURRENT"
printf '{"session_id": "tsuite-i1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "empty CURRENT blocks (integrity)"
printf '{"session_id": "tsuite-i1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "empty-CURRENT integrity yields on second stop (marker)"
echo demo > "$D/.ai_context/tasks/CURRENT"
err=$(printf '{"session_id": "tsuite-i2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "CURRENT without plan.md blocks (integrity)"
echo "$err" | grep -q 'mid-intake' && ok "missing-plan message names the legitimate pause" || no "missing-plan message unhelpful"
grep -q 'INTEGRITY' "$D/.ai_context/tasks/demo/gatelog" && ok "INTEGRITY row written to gatelog" || no "INTEGRITY row missing"
printf 'not a plan\n' > "$D/.ai_context/tasks/demo/plan.md"
printf '{"session_id": "tsuite-i3"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "heading-less plan.md blocks (integrity)"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'EOF'
# Plan: fixture
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: only [in_progress]
- risk: low
EOF
printf '{"session_id": "tsuite-i4"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "[in_progress] without a verify command blocks (integrity)"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'EOF'
# Plan: fixture
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: a [pending]
- verify: `true`
- risk: low

## M2: b [pending]
- verify: `true`
- risk: low
EOF
printf '{"session_id": "tsuite-i5"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "all-pending intake pause passes (no false block)"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'EOF'
# Plan: fixture
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: a [done]
- verify: `true`
- risk: low
EOF
printf '{"session_id": "tsuite-i6"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "all-done wrap-up passes (no false block)"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned && git push origin main'
err=$(printf '{"session_id": "tsuite-i7"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "forbidden verify (git push) blocks"
[ ! -f "$D/pwned" ] && ok "forbidden verify was NOT executed" || no "forbidden verify RAN"
echo "$err" | grep -q 'NOT run' && ok "refusal message explains the denylist" || no "refusal message missing"
printf '{"session_id": "tsuite-i7"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "forbidden verify keeps blocking (no once-per-session yield)"
grep -q 'forbidden verify' "$D/.ai_context/tasks/demo/gatelog" && ok "forbidden verify logged (INTEGRITY row)" || no "forbidden-verify row missing"
# Denylist regression net (F8/F21): every entry plus the near-miss spellings
# that bypassed the v3.9 substring matcher. The pwned probe proves refusal
# happened BEFORE execution; the rm target is a nonexistent path so a missed
# match stays harmless while still leaving the probe file as evidence.
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned-sudo && sudo true'
printf '{"session_id": "tsuite-f1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "forbidden verify (sudo) blocks"
[ ! -f "$D/pwned-sudo" ] && ok "sudo verify was NOT executed" || no "sudo verify RAN"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned-rm && rm -rf /nonexistent-starter-probe'
printf '{"session_id": "tsuite-f2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "forbidden verify (rm -rf abs) blocks"
[ ! -f "$D/pwned-rm" ] && ok "rm -rf verify was NOT executed" || no "rm -rf verify RAN"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned-fr && rm -fr /nonexistent-starter-probe'
printf '{"session_id": "tsuite-f3"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "near-miss spelling rm -fr blocks (F8 bypass closed)"
[ ! -f "$D/pwned-fr" ] && ok "rm -fr verify was NOT executed" || no "rm -fr verify RAN (F8 regressed)"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned-split && rm -r -f /nonexistent-starter-probe'
printf '{"session_id": "tsuite-f4"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "near-miss spelling rm -r -f blocks"
[ ! -f "$D/pwned-split" ] && ok "split-flag rm verify was NOT executed" || no "split-flag rm verify RAN"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned-dsp && rm  -rf /nonexistent-starter-probe'
printf '{"session_id": "tsuite-f5"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "near-miss spelling rm<double-space>-rf blocks"
[ ! -f "$D/pwned-dsp" ] && ok "double-space rm verify was NOT executed" || no "double-space rm verify RAN"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned-gp && git  push origin main'
printf '{"session_id": "tsuite-f6"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "near-miss spelling git<double-space>push blocks"
[ ! -f "$D/pwned-gp" ] && ok "double-space push verify was NOT executed" || no "double-space push verify RAN"
# Negative control: relative-path rm is legitimate cleanup, never refused.
write_plan "$D/.ai_context/tasks/demo/plan.md" 'mkdir -p scratch-dir && rm -rf scratch-dir'
printf '{"session_id": "tsuite-f7"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "relative rm -rf verify passes (no matcher false positive)"

# F9: log-always / interrupt-once — a second distinct dark state in the
# SAME session still reaches the audit trail (one interrupt, two rows).
D="$WORK/l110f9"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
printf '{"session_id": "tsuite-f9"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "dark state 1 (missing plan) interrupts"
printf 'not a plan\n' > "$D/.ai_context/tasks/demo/plan.md"
printf '{"session_id": "tsuite-f9"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "dark state 2 (heading-less plan) yields — interrupt already spent"
n_int=$(grep -c "	INTEGRITY	" "$D/.ai_context/tasks/demo/gatelog")
[ "$n_int" = 2 ] && ok "both dark states left INTEGRITY rows (log-always)" || no "INTEGRITY rows: want 2 got $n_int — second dark state went unrecorded"

D="$WORK/l110b"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
git -C "$D" init -q -b main 2>/dev/null || { git -C "$D" init -q && git -C "$D" checkout -qb main; }
git -C "$D" add -A && git -C "$D" commit -qm base
printf '{"session_id": "tsuite-i8"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "active task on main blocks (integrity)"
git -C "$D" checkout -qb task/demo
printf '{"session_id": "tsuite-i9"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "task branch passes (fresh session)"

echo "=== L1-11 · harness-report.sh (scoring is computed, never recalled)"
D="$WORK/l111"; mkdir -p "$D/.ai_context/tasks/t1" "$D/.ai_context/tasks/live"
cat > "$D/.ai_context/scoreboard.csv" <<'EOF'
date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness
2026-07-10,t1,opus-tier,M,4,1,1,0,90,success,aaa1111
2026-07-10,t2,opus-tier,M,3,0,1,0,60,success,aaa1111
2026-07-11,t3,opus-tier,M,5,2,2,1,120,success,aaa1111
2026-07-11,t4,opus-tier,M,4,0,1,0,80,failed,aaa1111
2026-07-12,t5,opus-tier,M,4,1,3,2,100,success,aaa1111
2026-07-08,old1,fable-tier,S,2,1,4,0,?,abandoned
EOF
printf '2026-07-11T10:00:00\tM2\tFAIL\tbash t\n2026-07-11T11:00:00\t?\tINTEGRITY\tempty-current\n2026-07-11T12:00:00\tM1\tUNARMED\tbash t\n' > "$D/.ai_context/tasks/t1/gatelog"
printf '2026-07-15T09:00:00\tM1\tINTEGRITY\ttask-on-main\n' > "$D/.ai_context/tasks/live/gatelog"
printf 'date,harness,area,severity,summary,ref\n2026-07-12,aaa1111,hooks,blocker,gate blocked wrap turn,journal/x.md\n2026-07-13,bbb2222,sync,papercut,stale stamp,-\n' > "$D/.ai_context/friction.csv"
out=$(bash "$REPO/scripts/harness-report.sh" "$D")
echo "$out" | grep -q 'tasks: 6 (success 4, failed 1, abandoned 1)' && ok "dataset counts computed" || no "dataset counts wrong"
echo "$out" | grep -q 'aaa1111 · opus-tier · M : n=5 .* (success 80%)' && ok "N>=5 cell prints success rate" || no "N>=5 cell missing its rate"
echo "$out" | grep -q 'unknown(1)' && ok "old 10-field row lands in the unknown bucket" || no "unknown bucket missing"
echo "$out" | grep -q 'unknown · fable-tier · S : n=1 success=0 failed=0 abandoned=1$' && ok "N<5 cell prints counts only (no %)" || no "N<5 cell printed a percentage"
echo "$out" | grep -q 'INTEGRITY rows: 2' && ok "INTEGRITY rows joined from gatelogs" || no "INTEGRITY join wrong"
echo "$out" | grep -q 'UNARMED rows: 1' && ok "UNARMED rows surfaced (vacuous gates visible)" || no "UNARMED count missing"
# STUCK yields surface even mid-flight (no scoreboard row yet) — the handoff
# happens before any wrap can write one.
S2="$WORK/l111s"; mkdir -p "$S2/.ai_context/tasks/live"
printf '2026-07-22T01:00:00\tM6\tFAIL\tfalse\n2026-07-22T01:05:00\tM6\tSTUCK\tyielded to the human after 3 consecutive red blocks\n' > "$S2/.ai_context/tasks/live/gatelog"
printf '# Plan: x\n## M6: c [in_progress]\n- verify: `false`\n- risk: high\n' > "$S2/.ai_context/tasks/live/plan.md"
echo live > "$S2/.ai_context/tasks/CURRENT"
out2=$(bash "$REPO/scripts/harness-report.sh" "$S2")
echo "$out2" | grep -q 'STUCK yields: 1 (live:1)' && ok "mid-flight STUCK yield surfaces without scoreboard data" || no "mid-flight STUCK invisible"
echo "$out" | grep -q 'blocker:1 friction:0 papercut:1' && ok "friction severities counted" || no "friction counts wrong"
csv=$(bash "$REPO/scripts/harness-report.sh" --csv "$D")
echo "$csv" | head -1 | grep -qxF 'project,harness,n_tasks,n_success,n_failed,n_abandoned,gate_fail_rows,integrity_rows,rung_ge3,interventions_sum,duration_med,friction_total,friction_blockers' && ok "--csv header is the fleet contract" || no "--csv header drifted"
echo "$csv" | grep -q '^l111,aaa1111,5,4,1,0,4,1,1,3,90,1,1$' && ok "--csv per-version aggregates correct" || no "--csv aggregate row wrong"
echo "$csv" | grep -q '^l111,bbb2222,0,0,0,0,0,0,0,0,-,1,0$' && ok "--csv covers friction-only versions" || no "friction-only version row missing"
E="$WORK/l111e"; mkdir -p "$E"
bash "$REPO/scripts/harness-report.sh" "$E" >/dev/null 2>&1
ck 0 $? "no data yields a clean exit 0"
B="$WORK/l111b"; mkdir -p "$B/.ai_context"; echo "garbage,x" > "$B/.ai_context/scoreboard.csv"
bash "$REPO/scripts/harness-report.sh" "$B" >/dev/null 2>&1
ck 2 $? "malformed scoreboard header exits 2"
grep -qF 'date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness' "$REPO/.claude/skills/wrap/reference.md" && grep -qF 'col["harness"]' "$REPO/scripts/harness-report.sh" && ok "wrap reference and report parser agree on the schema" || no "wrap and report schema drifted apart"
grep -qF 'date,harness,area,severity,summary,ref' "$REPO/.claude/skills/wrap/reference.md" && ok "wrap reference carries the friction schema" || no "friction schema missing from wrap reference"
if [ -f "$REPO/sync-project.sh" ]; then
  grep -q 'stock_update scripts/harness-report.sh' "$REPO/sync-project.sh" && ok "sync ships harness-report.sh" || no "sync does not ship harness-report.sh"
else
  skp "sync ships harness-report.sh (spawned project — template-repo only)"
fi

echo "=== L1-12 · zero-stop sweep: no vacuous gatelogs"
D="$WORK/l112"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'EOF'
# Plan: fixture
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: earlier [done]
- verify: `false`
- risk: low

## M2: final [done]
- verify: `true`
- risk: low
EOF
printf '{"session_id": "tsuite-z1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "all-done zero-stop wrap-up passes when the final verify is green"
grep -q "	M2	PASS" "$D/.ai_context/tasks/demo/gatelog" && ok "final [done] milestone verified at wrap (PASS row)" || no "final milestone not swept"
grep -q "	M1	UNARMED" "$D/.ai_context/tasks/demo/gatelog" && ok "earlier rowless [done] recorded UNARMED (verify NOT re-run — point-in-time gate)" || no "UNARMED row missing"
zn=$(grep -c '' "$D/.ai_context/tasks/demo/gatelog")
printf '{"session_id": "tsuite-z1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
[ "$(grep -c '' "$D/.ai_context/tasks/demo/gatelog")" -eq "$zn" ] && ok "sweep idempotent (no duplicate rows on re-stop)" || no "sweep duplicated rows"
sed -i.bak 's/## M2: final \[done\]/## M3: red [done]/; s/- verify: `true`/- verify: `false`/' "$D/.ai_context/tasks/demo/plan.md" && rm -f "$D/.ai_context/tasks/demo/plan.md.bak"
printf '{"session_id": "tsuite-z1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "red final [done] verify blocks the wrap-up turn"
printf '{"session_id": "tsuite-z1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "red sweep keeps blocking (no once-per-session yield)"
grep -q "	M3	FAIL" "$D/.ai_context/tasks/demo/gatelog" && ok "sweep FAIL row logged with the enforced command" || no "sweep FAIL row missing"
D2="$WORK/l112b"; mkdir -p "$D2/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D2/CLAUDE.md"
echo demo > "$D2/.ai_context/tasks/CURRENT"
write_plan "$D2/.ai_context/tasks/demo/plan.md" "true"
CLAUDE_PROJECT_DIR="$D2" bash "$GATE" --sweep >/dev/null 2>&1
ck 0 $? "--sweep exits 0 mid-task (what /wrap calls before deleting CURRENT)"
grep -q "	M1	UNARMED" "$D2/.ai_context/tasks/demo/gatelog" && ok "--sweep records UNARMED for the rowless earlier [done]" || no "--sweep UNARMED missing"
grep -q "	M2	" "$D2/.ai_context/tasks/demo/gatelog" && no "--sweep touched a non-[done] milestone" || ok "--sweep leaves [in_progress]/[pending] milestones alone"
D3="$WORK/l112c"; mkdir -p "$D3/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D3/CLAUDE.md"
echo demo > "$D3/.ai_context/tasks/CURRENT"
printf '# Plan: f\n<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->\n\n## M1: only [done]\n- verify: `touch pwned && git push origin main`\n- risk: low\n' > "$D3/.ai_context/tasks/demo/plan.md"
CLAUDE_PROJECT_DIR="$D3" bash "$GATE" --sweep >/dev/null 2>&1
ck 2 $? "--sweep refuses a forbidden final verify"
[ ! -f "$D3/pwned" ] && ok "--sweep forbidden verify was NOT executed" || no "--sweep ran a forbidden verify"
grep -q 'forbidden verify' "$D3/.ai_context/tasks/demo/gatelog" && ok "--sweep forbidden logged as INTEGRITY" || no "--sweep forbidden row missing"

echo "=== L1-13 · bash-guard: catastrophic-op tripwire (PreToolUse)"
BG="$REPO/.claude/hooks/bash-guard.sh"
bgp() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
D="$WORK/l113"; mkdir -p "$D/.ai_context"
bgp 'git push --force origin main' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "force-push denied"
bgp 'git push --force-with-lease origin main' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "force-with-lease denied"
bgp 'git push -f' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "short -f push denied"
bgp 'git push origin main' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 0 $? "plain push passes the guard (ask-tier lives in settings.json)"
bgp 'tail -f app.log; git push origin main' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 0 $? "-f outside the push segment is not miscounted"
bgp 'sudo apt-get install jq' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "sudo denied"
grep -q "	DENY	sudo	" "$D/.ai_context/private/bash-guard.log" && ok "deny logged to private/bash-guard.log" || no "deny log row missing"
bgp 'rm -rf /' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "rm -rf / denied"
bgp 'rm -rf /*' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "rm -rf /* denied"
bgp 'rm -fr /' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "rm -fr / denied (spelling variant)"
bgp 'rm -r -f /' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "rm -r -f / denied (split flags)"
bgp 'rm  -rf  /' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "rm<double-space>-rf / denied"
bgp 'rm -rf --no-preserve-root /' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "rm -rf --no-preserve-root / denied (F12: the canonical root wipe)"
bgp 'git push origin +main' | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "+refspec force-push denied (F12: flagless force)"
out=$(bgp 'rm -f -r /tmp/scratch' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "split-flag absolute rm -rf downgraded to ask" || no "split-flag absolute rm not asked"
out=$(bgp 'rm -r -f build/' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "relative split-flag rm passes silently" || no "relative split-flag rm flagged"
out=$(bgp 'rm -rf /tmp/scratch' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "absolute-path rm -rf downgraded to ask" || no "absolute rm -rf not asked"
out=$(bgp 'rm -rf build/' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "relative rm -rf passes silently" || no "relative rm -rf flagged"
out=$(bgp 'cat .env' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok ".env access downgraded to ask (H1)" || no ".env access not asked"
out=$(bgp 'cat .env.example' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok ".env.example exempt" || no ".env.example false positive"
out=$(bgp 'pip install python-dotenv' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "no false positive on dotenv" || no "dotenv false positive"
out=$(bgp 'cat .secrets/token.json' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok ".secrets/ access downgraded to ask (H1)" || no ".secrets/ access not asked"
out=$(bgp 'ls foo.secrets/x' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "no false positive on lookalike dir names" || no ".secrets lookalike false positive"
# Shared-matcher integrity (F8): one pattern source, both hooks on it, sync
# ships it — the drift the two hand-mirrored v3.9 copies allowed is closed.
[ -f "$REPO/.claude/hooks/guard-patterns.sh" ] && ok "guard-patterns.sh exists (shared matcher source)" || no "guard-patterns.sh missing"
grep -q 'guard-patterns\.sh' "$REPO/.claude/hooks/stop-gate.sh" && grep -q 'guard-patterns\.sh' "$REPO/.claude/hooks/bash-guard.sh" && ok "both hooks source the shared matchers" || no "a hook does not source guard-patterns.sh (drift risk)"
if [ -f "$REPO/sync-project.sh" ]; then
  grep -q '^copy_if_missing \.claude/hooks/guard-patterns\.sh$' "$REPO/sync-project.sh" && grep -q '^stock_update \.claude/hooks/guard-patterns\.sh$' "$REPO/sync-project.sh" && ok "sync ships guard-patterns.sh (add + stock-update)" || no "sync does not ship guard-patterns.sh"
else
  skp "sync ships guard-patterns.sh (spawned project — template-repo only)"
fi
grep -q '"PreToolUse"' "$REPO/.claude/settings.json" && grep -q 'bash-guard\.sh' "$REPO/.claude/settings.json" && ok "bash-guard wired in settings.json" || no "bash-guard wiring missing"
grep -qF 'Edit(./.ai_context/tasks/**/gatelog)' "$REPO/.claude/settings.json" && grep -qF 'Write(./.ai_context/tasks/**/gatelog)' "$REPO/.claude/settings.json" && ok "gatelog write-deny present (hook-written only)" || no "gatelog deny entries missing"
grep -qF '"Bash(git push --force:*)"' "$REPO/.claude/settings.json" && ok "declarative force-push deny present" || no "force-push deny entry missing"
grep -qF '"ask"' "$REPO/.claude/settings.json" && grep -qF '"Bash(git push:*)"' "$REPO/.claude/settings.json" && ok "ask tier present (push/reset/clean/sudo/rm)" || no "ask tier missing"

echo "=== L1-14 · pre-commit guards: append-only + S2 bulk"
D="$WORK/l114"; mkdir -p "$D/.ai_context/journal" "$D/.ai_context/tasks/demo" "$D/.ai_context/knowledge"
printf 'preamble\n' > "$D/.ai_context/decisions.md"
printf 'date,slug\n2026-07-01,t1\n' > "$D/.ai_context/scoreboard.csv"
printf '2026-07-01T00:00:00\tM1\tPASS\ttrue\n' > "$D/.ai_context/tasks/demo/gatelog"
printf '2026-07-01T00:00:00\tM1\texecutor\n' > "$D/.ai_context/tasks/demo/spawnlog"
printf 'first line\n' > "$D/.ai_context/journal/2026-07-01-x.md"
printf 'lesson 1\n' > "$D/.ai_context/tasks/demo/lessons.md"
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" commit -qm base
printf '## ADR-001: x\n' >> "$D/.ai_context/decisions.md"
printf '2026-07-02,t2\n' >> "$D/.ai_context/scoreboard.csv"
printf '2026-07-02T00:00:00\tM2\tPASS\ttrue\n' >> "$D/.ai_context/tasks/demo/gatelog"
printf '2026-07-02T00:00:00\tM2\texecutor\n' >> "$D/.ai_context/tasks/demo/spawnlog"
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 0 $? "pure appends pass"
git -C "$D" commit -qm appends
sed -i.bak 's/t1/t1-edited/' "$D/.ai_context/scoreboard.csv" && rm -f "$D/.ai_context/scoreboard.csv.bak"
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 1 $? "edited scoreboard row blocks"
( cd "$D" && git reset -q && git checkout -q -- .ai_context/scoreboard.csv )
sed -i.bak '1d' "$D/.ai_context/tasks/demo/gatelog" && rm -f "$D/.ai_context/tasks/demo/gatelog.bak"
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 1 $? "gatelog row removal blocks"
( cd "$D" && git reset -q && git checkout -q -- .ai_context/tasks/demo/gatelog )
# F18: spawnlog is the same evidence class — a history rewrite must block.
sed -i.bak '1d' "$D/.ai_context/tasks/demo/spawnlog" && rm -f "$D/.ai_context/tasks/demo/spawnlog.bak"
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 1 $? "spawnlog rewrite blocks (F18 — commit layer now agrees with runtime deny)"
( cd "$D" && git reset -q && git checkout -q -- .ai_context/tasks/demo/spawnlog )
git -C "$D" mv -f .ai_context/journal/2026-07-01-x.md .ai_context/journal/renamed.md
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 1 $? "journal rename blocks"
( cd "$D" && git reset -q && git checkout -q -- .ai_context/journal && rm -f .ai_context/journal/renamed.md )
printf 'distilled to one line\n' > "$D/.ai_context/tasks/demo/lessons.md"
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 0 $? "lessons.md rewrite passes (wrap distills it — deliberately not covered)"
( cd "$D" && git reset -q && git checkout -q -- . )
python3 - "$D/.ai_context/knowledge/dump.txt" <<'PY'
import sys; open(sys.argv[1],'w').write('x'*150000)
PY
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-context-bulk.sh" ) >/dev/null 2>&1
ck 1 $? "150 KB dump into .ai_context blocks (S2)"
( cd "$D" && git reset -q ) && rm -f "$D/.ai_context/knowledge/dump.txt"
python3 - "$D/big-outside.bin" <<'PY'
import sys; open(sys.argv[1],'w').write('y'*150000)
PY
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-context-bulk.sh" ) >/dev/null 2>&1
ck 0 $? "big files outside .ai_context are not the bulk guard's business"
grep -q 'ai-context-append-only' "$REPO/.pre-commit-config.yaml" && grep -q 'ai-context-bulk' "$REPO/.pre-commit-config.yaml" && ok "both guards wired in .pre-commit-config.yaml" || no "pre-commit wiring missing"
grep -qF 'tasks/.+/(gatelog|spawnlog)' "$REPO/.pre-commit-config.yaml" && ok "pre-commit files regex covers spawnlog (F18)" || no "pre-commit files regex misses spawnlog"

echo "=== L1-15 · gate integrity: wrong-branch task work"
D="$WORK/l115"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
git -C "$D" init -q && git -C "$D" checkout -qb wip && git -C "$D" add -A && git -C "$D" commit -qm base
printf '{"session_id": "tsuite-w1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "task on a non-task branch blocks (integrity)"
grep -q "branch 'wip'" "$D/.ai_context/tasks/demo/gatelog" && ok "wrong-branch INTEGRITY row names the branch" || no "wrong-branch row missing"
grep -q "	FAIL	" "$D/.ai_context/tasks/demo/gatelog" && no "wrong branch polluted the gatelog with a junk FAIL" || ok "no junk FAIL row from the wrong-branch stop"
printf '{"session_id": "tsuite-w1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "wrong-branch integrity yields on second stop (marker)"
git -C "$D" checkout -qb task/demo
printf '{"session_id": "tsuite-w2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "task/ branch passes (fresh session)"

echo "=== L1-16 · session-start: INDEX size warning"
D="$WORK/l116"; mkdir -p "$D/.ai_context"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
printf '# s\n\n_Last updated: %s_\n' "$(date +%F)" > "$D/.ai_context/state.md"
python3 - "$D/.ai_context/INDEX.md" <<'PY'
import sys; open(sys.argv[1],'w').write('meta\n'*1000)
PY
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'INDEX.md is .* bytes (cap 4096)' && ok "bloated INDEX warned at session start" || no "INDEX size warning missing"
printf 'small index\n' > "$D/.ai_context/INDEX.md"
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'INDEX.md is .* bytes (cap 4096)' && no "small INDEX falsely warned" || ok "small INDEX stays quiet"

echo "=== L1-17 · harness-report: integrity cross-checks"
D="$WORK/l117"; mkdir -p "$D/.ai_context/tasks/bad" "$D/.ai_context/tasks/orphan" "$D/.ai_context/tasks/cur"
cat > "$D/.ai_context/scoreboard.csv" <<'EOF'
date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness
2026-07-10,bad,opus-tier,M,2,0,1,0,50,success,ccc3333
2026-07-11,weird,opus-tier,M,2,0,1,0,30,succeeded,ccc3333
EOF
printf '2026-07-10T10:00:00\tM1\tFAIL\ttrue\n2026-07-10T11:00:00\tM1\tFAIL\ttrue\n' > "$D/.ai_context/tasks/bad/gatelog"
printf '# Plan: bad\n\n## M1: a [done]\n- verify: `true`\n\n## M2: b [done]\n- verify: `true`\n' > "$D/.ai_context/tasks/bad/plan.md"
printf '# Plan: orphan\n\n## M1: a [done]\n- verify: `true`\n' > "$D/.ai_context/tasks/orphan/plan.md"
printf '# Plan: cur\n\n## M1: a [in_progress]\n- verify: `true`\n' > "$D/.ai_context/tasks/cur/plan.md"
echo cur > "$D/.ai_context/tasks/CURRENT"
out=$(bash "$REPO/scripts/harness-report.sh" "$D")
echo "$out" | grep -q 'gate_failures mismatch: bad — scoreboard says 0, gatelog has 2' && ok "scoreboard↔gatelog mismatch surfaced" || no "mismatch not surfaced"
echo "$out" | grep -q 'orphan task: tasks/orphan/' && ok "orphan task dir surfaced (survivor-bias net)" || no "orphan not surfaced"
echo "$out" | grep -q 'gate evidence gap: tasks/bad/' && ok "missing PASS/UNARMED evidence surfaced" || no "evidence gap not surfaced"
echo "$out" | grep -q 'enum violation: scoreboard weird: outcome="succeeded"' && ok "outcome enum violation surfaced" || no "enum violation not surfaced"
echo "$out" | grep -q 'orphan task: tasks/cur/' && no "in-flight CURRENT task misflagged as orphan" || ok "in-flight CURRENT task not flagged"
csv=$(bash "$REPO/scripts/harness-report.sh" --csv "$D")
echo "$csv" | grep -q 'mismatch' && no "--csv polluted by integrity lines (13-col contract)" || ok "--csv untouched by integrity section"
out2=$(bash "$REPO/scripts/harness-report.sh" "$WORK/l111")
echo "$out2" | grep -q 'clean — scoreboard, gatelogs and task dirs agree' && ok "healthy dataset reports clean" || no "healthy dataset not reported clean"
D2="$WORK/l117b"; mkdir -p "$D2/.ai_context/tasks/ghost"
printf '# Plan: g\n\n## M1: a [done]\n- verify: `true`\n' > "$D2/.ai_context/tasks/ghost/plan.md"
out3=$(bash "$REPO/scripts/harness-report.sh" "$D2"); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out3" | grep -q 'orphan task: tasks/ghost/'; } && ok "orphan surfaces even with an empty scoreboard (cold-start case)" || no "cold-start orphan hidden by the no-data early exit"
D3="$WORK/l117c"; mkdir -p "$D3/.ai_context"
out4=$(bash "$REPO/scripts/harness-report.sh" "$D3")
echo "$out4" | grep -q 'no harness data yet' && ok "truly-empty project still gets the no-data line" || no "no-data early exit regressed"

echo "=== L1-18 · doc freshness floor (F24)"
if [ -f "$REPO/MIGRATION.md" ] && [ -f "$REPO/README.zh-TW.md" ]; then
  newest="$(grep -m1 '^## .*claude-starter v.* → v' "$REPO/MIGRATION.md" | grep -o 'v[0-9][0-9.]*' | tail -1)"
  if [ -n "$newest" ]; then
    grep -qF "$newest" "$REPO/README.zh-TW.md" && ok "README.zh-TW mentions the newest release ($newest)" || no "README.zh-TW.md lags MIGRATION: no $newest token (doc parity, F24)"
  else
    no "could not extract the newest version token from MIGRATION.md"
  fi
  for t in TUTORIAL.md TUTORIAL.zh-TW.md; do
    head -8 "$REPO/$t" | grep -qE 'v[0-9]+\.[0-9]+.*20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' && ok "$t carries a dated version banner" || no "$t missing its dated version banner (F24)"
  done
else
  skp "doc freshness smoke (spawned project — template-repo only)"
fi

echo "=== L1-8 · S7 pre-commit measures STAGED content"
D="$WORK/l18"; mkdir -p "$D/.ai_context"
printf 'Last updated: 2026-07-08\nsmall\n' > "$D/.ai_context/state.md"
git -C "$D" init -q && git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-state-size.sh" ) >/dev/null 2>&1
ck 0 $? "small staged state.md passes"
python3 - "$D/.ai_context/state.md" <<'PY'
import sys; open(sys.argv[1],'w').write('x'*6000)
PY
( cd "$D" && bash "$REPO/scripts/check-state-size.sh" ) >/dev/null 2>&1
ck 0 $? "bloated worktree with small staged content passes (staged is what commits)"
( cd "$D" && git add .ai_context/state.md && bash "$REPO/scripts/check-state-size.sh" ) >/dev/null 2>&1
ck 1 $? "bloated staged content blocks"
# F20: the worktree fallback was dead code (errexit) and mislabeled its
# measurement as staged — cover untracked, outside-git, and the label.
D="$WORK/l18b"; mkdir -p "$D/.ai_context"
git -C "$D" init -q
python3 - "$D/.ai_context/state.md" <<'PY'
import sys; open(sys.argv[1],'w').write('x'*6000)
PY
out=$( cd "$D" && bash "$REPO/scripts/check-state-size.sh" 2>&1 ); rc=$?
ck 1 $rc "untracked oversized state.md blocks via the worktree fallback"
echo "$out" | grep -q 'worktree' && ok "fallback measurement labeled worktree, not staged" || no "fallback measurement mislabeled"
printf 'small\n' > "$D/.ai_context/state.md"
( cd "$D" && bash "$REPO/scripts/check-state-size.sh" ) >/dev/null 2>&1
ck 0 $? "untracked small state.md passes (no errexit death)"
D="$WORK/l18c"; mkdir -p "$D/.ai_context"
python3 - "$D/.ai_context/state.md" <<'PY'
import sys; open(sys.argv[1],'w').write('y'*6000)
PY
( cd "$D" && bash "$REPO/scripts/check-state-size.sh" ) >/dev/null 2>&1
ck 1 $? "outside git: worktree fallback still enforces S7"
D="$WORK/l18d"; mkdir -p "$D/.ai_context"
: > "$D/.ai_context/state.md"
git -C "$D" init -q && git -C "$D" add -A
python3 - "$D/.ai_context/state.md" <<'PY'
import sys; open(sys.argv[1],'w').write('z'*6000)
PY
( cd "$D" && bash "$REPO/scripts/check-state-size.sh" ) >/dev/null 2>&1
ck 0 $? "empty staged + bloated worktree passes (staged is what commits)"

echo "=== L1-9 · seed purity (the template repo ships placeholders, never real memory)"
if [ -f "$REPO/.claude/.starter-version" ]; then
  skp "seed purity (this is a spawned project, not the template repo)"
else
  grep -q '{{DATE}}' "$REPO/.ai_context/state.md" && ok "seed state.md still a placeholder" || no "seed state.md polluted — real memory belongs in the dev workshop project, not the product"
  grep -q '^## ADR-[0-9]' "$REPO/.ai_context/decisions.md" && no "seed decisions.md contains real ADRs" || ok "seed decisions.md clean"
  for sd in journal knowledge private tasks; do
    stray=$(find "$REPO/.ai_context/$sd" -type f ! -name '.gitkeep' 2>/dev/null | wc -l)
    [ "$stray" -eq 0 ] && ok "seed $sd/ empty" || no "seed $sd/ has $stray stray file(s)"
  done
fi

echo "=== L2-1 · spawn completeness (--local)"
if [ -x "$REPO/start_project.sh" ]; then
  ( cd "$WORK" && "$REPO/start_project.sh" --local --kind code lab ) >/dev/null 2>&1
fi
P="$WORK/lab"
if [ ! -d "$P" ]; then
  if [ -x "$REPO/start_project.sh" ]; then
    no "spawn failed — remaining L2 tests skipped"
  else
    skp "L2 spawn tests (spawned project — template-repo only)"
  fi
else
  ok "spawn succeeded"
  miss=""
  for f in .claude/settings.json .claude/hooks/session-start.sh .claude/hooks/stop-gate.sh \
           .claude/hooks/post-edit.sh .claude/hooks/bash-guard.sh .claude/hooks/guard-patterns.sh \
           .claude/skills/wrap/SKILL.md .claude/skills/wrap/reference.md \
           .claude/skills/task/SKILL.md \
           .claude/skills/task/reference.md .claude/skills/setup/SKILL.md \
           .claude/agents/scout.md .claude/agents/planner.md .claude/agents/plan-critic.md \
           .claude/agents/executor.md .claude/agents/verifier.md .claude/agents/reframer.md \
           .claude/.starter-version .ai_context/INDEX.md .ai_context/tasks/.gitkeep \
           .secrets/.gitkeep \
           scripts/harness-report.sh scripts/check-append-only.sh scripts/check-context-bulk.sh \
           CLAUDE.md README.md; do
    [ -e "$P/$f" ] || miss="$miss $f"
  done
  [ -z "$miss" ] && ok "all mechanism files present" || no "missing:$miss"
  left=""
  for f in TUTORIAL.md TUTORIAL.zh-TW.md MIGRATION.md README.zh-TW.md start_project.sh \
           sync-project.sh bootstrap-machine.sh templates global .github; do
    [ -e "$P/$f" ] && left="$left $f"
  done
  [ -z "$left" ] && ok "template leftovers all removed" || no "leftovers:$left"
  python3 -m json.tool "$P/.claude/settings.json" >/dev/null 2>&1 && ok "settings.json valid JSON" || no "settings.json invalid"
  for k in SessionStart PreToolUse PostToolUse Stop; do
    grep -q "\"$k\"" "$P/.claude/settings.json" && ok "hook wired: $k" || no "hook missing: $k"
  done
  [ -x "$P/.claude/hooks/stop-gate.sh" ] && ok "hooks executable" || no "hooks not executable"
  grep -q 'claude-starter@' "$P/.claude/.starter-version" && ok "provenance stamp present" || no "provenance stamp missing"
  git -C "$P" check-ignore -q .secrets/cred.json && ok "spawn: .secrets/ contents git-invisible" || no "spawn: .secrets/ contents NOT ignored"
  git -C "$P" check-ignore -q .secrets/.gitkeep && no "spawn: .secrets placeholder wrongly ignored" || ok "spawn: .secrets placeholder trackable"

  echo "=== L2-2 · pre-commit guards (gitleaks + S7)"
  if command -v pre-commit >/dev/null 2>&1; then
    ( cd "$P" && pre-commit install >/dev/null 2>&1 )
    # Fake key from AWS docs pattern — test fixture only.        # gitleaks:allow
    printf 'aws_access_key_id = AKIAIOSFODNN7TESTKEY\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYTESTKEY99\n' > "$P/notes.md" # gitleaks:allow
    ( cd "$P" && git add notes.md && git commit -qm leak ) >/dev/null 2>&1 && no "gitleaks let a fake AWS key through" || ok "gitleaks blocks fake AWS key"
    ( cd "$P" && git reset -q HEAD notes.md 2>/dev/null; rm -f notes.md )
    python3 - "$P/.ai_context/state.md" <<'PY'
import sys
open(sys.argv[1],'w').write('Last updated: 2026-07-07\n' + ('x'*79+'\n')*80)
PY
    ( cd "$P" && git add .ai_context/state.md && git commit -qm big ) >/dev/null 2>&1 && no "S7 let >5KB state.md through" || ok "S7 blocks oversized state.md"
    ( cd "$P" && git checkout -q -- .ai_context/state.md 2>/dev/null || git reset -q 2>/dev/null )
    ( cd "$P" && git checkout -q -- .ai_context/state.md 2>/dev/null || true )
    sed -i.bak '1s/.*/EDITED-BY-TEST/' "$P/.ai_context/decisions.md" && rm -f "$P/.ai_context/decisions.md.bak"
    ( cd "$P" && git add .ai_context/decisions.md && git commit -qm edit-adr ) >/dev/null 2>&1 && no "append-only let an ADR edit through" || ok "append-only blocks ADR edits end-to-end"
    ( cd "$P" && git reset -q 2>/dev/null; git checkout -q -- .ai_context/decisions.md 2>/dev/null || true )
  else
    skp "pre-commit not installed — gitleaks/S7 guard tests"
  fi

  echo "=== L2-3 · hook chain inside the spawned project"
  out=$(CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/session-start.sh" </dev/null 2>&1)
  echo "$out" | grep -q 'SETUP REQUIRED' && ok "newborn spawn gets setup instruction" || no "setup instruction missing in spawn"
  mkdir -p "$P/.ai_context/tasks/demo"; echo demo > "$P/.ai_context/tasks/CURRENT"
  write_plan "$P/.ai_context/tasks/demo/plan.md" "true"
  printf '# lab\n## Commands\n- Test: `true`\n' > "$P/CLAUDE.md"
  git -C "$P" checkout -qb task/demo 2>/dev/null || true
  printf '{"session_id": "tsuite-l2"}' | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 0 $? "project gate: green passes"
  write_plan "$P/.ai_context/tasks/demo/plan.md" "false"
  printf '{"session_id": "tsuite-l2"}' | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 2 $? "project gate: red blocks"
  grep -qc "	M2	" "$P/.ai_context/tasks/demo/gatelog" >/dev/null && ok "project gatelog written" || no "project gatelog missing"
  rm -f "$P/.ai_context/tasks/CURRENT"

  echo "=== L2-5 · no-op latency"
  t0=$(date +%s%N)
  printf '{"session_id": "tsuite-l5"}' | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  [ "$ms" -lt 500 ] && ok "no-op gate latency ${ms}ms (<500ms)" || no "no-op gate latency ${ms}ms (>=500ms)"
fi

echo "=== L2-1b · --local spawn ships tracked content only (F17)"
if [ -x "$REPO/start_project.sh" ] && git -C "$REPO" rev-parse HEAD >/dev/null 2>&1; then
  # Seed both leak classes into the REAL checkout (uniquely named, removed
  # below and in cleanup): a gitignored credential and a plain untracked file.
  printf 'FAKE-CRED do-not-ship\n' > "$REPO/.secrets/l2-seeded-fake-cred.tmp"
  printf 'untracked scratch\n' > "$REPO/l2-seeded-untracked.tmp"
  ( cd "$WORK" && "$REPO/start_project.sh" --local --kind code hyglab ) >/dev/null 2>&1
  H="$WORK/hyglab"
  if [ -d "$H" ]; then
    [ ! -e "$H/.secrets/l2-seeded-fake-cred.tmp" ] && ok "gitignored secret did NOT ride into the spawn" || no "SECRET LEAKED into --local spawn (F17 regressed)"
    [ ! -e "$H/l2-seeded-untracked.tmp" ] && ok "untracked file did not ride along" || no "untracked file leaked into spawn"
    [ -f "$H/.secrets/.gitkeep" ] && ok "tracked .secrets placeholder still ships" || no ".secrets/.gitkeep lost by the archive copy"
    [ -f "$H/.claude/hooks/stop-gate.sh" ] && [ -f "$H/.ai_context/INDEX.md" ] && ok "tracked mechanisms ship via git archive" || no "archive copy missing tracked files"
  else
    no "hygiene spawn failed"
  fi
  rm -f "$REPO/.secrets/l2-seeded-fake-cred.tmp" "$REPO/l2-seeded-untracked.tmp"
else
  skp "--local hygiene test (needs the template git checkout)"
fi

echo "=== L2-4 · research kind + artifact verify"
if [ -x "$REPO/start_project.sh" ]; then
  ( cd "$WORK" && "$REPO/start_project.sh" --local --kind research rlab ) >/dev/null 2>&1
fi
R="$WORK/rlab"
if [ ! -d "$R" ]; then
  if [ -x "$REPO/start_project.sh" ]; then
    no "research spawn failed"
  else
    skp "research spawn tests (spawned project — template-repo only)"
  fi
else
  grep -q 'research project' "$R/CLAUDE.md" && ok "research CLAUDE.md in place" || no "research template wrong"
  grep -q '## Long-horizon tasks' "$R/CLAUDE.md" && ok "research template carries /task section" || no "research /task section missing"
  mkdir -p "$R/.ai_context/tasks/demo"; echo demo > "$R/.ai_context/tasks/CURRENT"
  printf '# r\n## Commands\n- Test: `true`\n' > "$R/CLAUDE.md"
  write_plan "$R/.ai_context/tasks/demo/plan.md" "test -s reports/x.md"
  git -C "$R" checkout -qb task/demo 2>/dev/null || true
  printf '{"session_id": "tsuite-r"}' | CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 2 $? "artifact gate blocks while deliverable absent"
  mkdir -p "$R/reports" && echo content > "$R/reports/x.md"
  printf '{"session_id": "tsuite-r"}' | CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 0 $? "artifact gate passes once deliverable exists"
fi

echo "=== L2-6 · spawning via a symlink resolves the real template"
if [ -x "$REPO/start_project.sh" ]; then
  ln -s "$REPO/start_project.sh" "$WORK/spawn-link"
  ( cd "$WORK" && "$WORK/spawn-link" --local --kind code symlab ) >/dev/null 2>&1
  if [ -d "$WORK/symlab" ]; then
    [ -f "$WORK/symlab/CLAUDE.md" ] && ok "symlink spawn produced a project" || no "symlink spawn missing CLAUDE.md"
    [ -e "$WORK/symlab/l11" ] && no "symlink spawn copied the link's PARENT directory (SCRIPT_DIR bug regressed)" || ok "no parent-directory copy artifact"
  else
    no "symlink spawn failed entirely"
  fi
else
  skp "symlink spawn (spawned project — template-repo only)"
fi

echo ""
echo "==== summary: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
