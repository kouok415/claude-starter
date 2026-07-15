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
cleanup() { rm -rf "$WORK" "${TMPDIR:-/tmp}"/claude-setup-nudge-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-integrity-tsuite-* ; }
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

echo "=== L1-4 · sync: --update-stock + --adopt"
if git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
  skp "update-stock history test (shallow clone — set fetch-depth: 0)"
else
  OLD_SHA="$(git -C "$REPO" log --format=%H -- .claude/hooks/stop-gate.sh | tail -1)"
  D="$WORK/l14"; mkdir -p "$D/.ai_context" "$D/.claude/hooks"
  cp "$REPO/.ai_context/INDEX.md" "$D/.ai_context/"
  git -C "$REPO" show "$OLD_SHA:.claude/hooks/stop-gate.sh" > "$D/.claude/hooks/stop-gate.sh"
  printf '{"custom": true}\n' > "$D/.claude/settings.json"
  out=$("$REPO/sync-project.sh" --update-stock "$D" 2>&1)
  cmp -s "$D/.claude/hooks/stop-gate.sh" "$REPO/.claude/hooks/stop-gate.sh" && ok "historical stock file advanced" || no "stock file not advanced"
  echo "$out" | grep -q 'settings.json differs from every known template version' && ok "customized file flagged, untouched" || no "customized handling wrong"
  grep -q custom "$D/.claude/settings.json" && ok "customized content preserved" || no "customized content clobbered"
  grep -q 'synced-to: claude-starter@' "$D/.claude/.starter-version" 2>/dev/null && ok "synced-to stamp appended on --update-stock" || no "synced-to stamp missing"
  [ -x "$D/scripts/harness-report.sh" ] && ok "new stock file (harness-report.sh) installed by sync" || no "harness-report.sh not installed — copy_if_missing pair missing"
  D5="$WORK/l14b"; mkdir -p "$D5/.ai_context" "$D5/.claude"
  cp -r "$REPO/.claude/hooks" "$REPO/.claude/skills" "$REPO/.claude/agents" "$REPO/.claude/settings.json" "$D5/.claude/"
  cp "$REPO/.ai_context/INDEX.md" "$D5/.ai_context/"
  cp "$REPO/.pre-commit-config.yaml" "$D5/"
  mkdir -p "$D5/scripts"; cp "$REPO/scripts/check-state-size.sh" "$REPO/scripts/precommit-gitleaks.sh" "$D5/scripts/"
  "$REPO/sync-project.sh" --update-stock "$D5" >/dev/null 2>&1
  grep -q 'synced-to: claude-starter@' "$D5/.claude/.starter-version" 2>/dev/null && ok "added-only sync still appends the synced-to stamp (attribution integrity)" || no "added-only sync left no stamp — harness column would mis-attribute"
fi
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

echo "=== L1-5 · v3.3: sentinel gate, status warning, brief injection, caps"
D="$WORK/l15"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# t\n<!-- claude-starter: UNCONFIGURED — run /setup -->\nno legacy patterns here\n' > "$D/CLAUDE.md"
printf '{"session_id": "tsuite-s1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "sentinel-only CLAUDE.md arms the setup gate"
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'SETUP REQUIRED' && ok "sentinel arms session-start instruction" || no "sentinel missed by session-start"
n=$(grep -l 'claude-starter: UNCONFIGURED' "$REPO"/templates/CLAUDE.md.* | wc -l)
[ "$n" -eq 3 ] && ok "all 3 templates carry the sentinel" || no "only $n/3 templates carry the sentinel"

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

echo "=== L1-6 · resident-size guards + security entries"
sz=$(wc -c < "$REPO/.ai_context/INDEX.md")
[ "$sz" -le 4096 ] && ok "INDEX.md within 4 KB ($sz B — injected every session)" || no "INDEX.md re-bloated ($sz B > 4096)"
sz=$(wc -c < "$REPO/.claude/skills/task/SKILL.md")
[ "$sz" -le 11264 ] && ok "task SKILL.md within 11 KB ($sz B)" || no "task SKILL.md bloated ($sz B) — move detail to reference.md"
sz=$(wc -c < "$REPO/.claude/skills/wrap/SKILL.md")
[ "$sz" -le 6144 ] && ok "wrap SKILL.md within 6 KB ($sz B)" || no "wrap SKILL.md bloated ($sz B)"
grep -qF 'duration_min,outcome,harness' "$REPO/.claude/skills/wrap/SKILL.md" && ok "wrap scoreboard header carries the harness column" || no "wrap scoreboard header missing the harness column"
grep -qF 'Read(./**/.env)' "$REPO/.claude/settings.json" && ok "nested .env read-deny present" || no "nested .env deny missing"
grep -qxF '**/.env' "$REPO/.gitignore" && ok "nested .env gitignored" || no "nested .env gitignore missing"
grep -q 'gate-cache' "$REPO/.gitignore" && ok "gate-cache gitignored (fingerprint-safe)" || no "gate-cache ignore missing"

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
printf '2026-07-11T10:00:00\tM2\tFAIL\tbash t\n2026-07-11T11:00:00\t?\tINTEGRITY\tempty-current\n' > "$D/.ai_context/tasks/t1/gatelog"
printf '2026-07-15T09:00:00\tM1\tINTEGRITY\ttask-on-main\n' > "$D/.ai_context/tasks/live/gatelog"
printf 'date,harness,area,severity,summary,ref\n2026-07-12,aaa1111,hooks,blocker,gate blocked wrap turn,journal/x.md\n2026-07-13,bbb2222,sync,papercut,stale stamp,-\n' > "$D/.ai_context/friction.csv"
out=$(bash "$REPO/scripts/harness-report.sh" "$D")
echo "$out" | grep -q 'tasks: 6 (success 4, failed 1, abandoned 1)' && ok "dataset counts computed" || no "dataset counts wrong"
echo "$out" | grep -q 'aaa1111 · opus-tier · M : n=5 .* (success 80%)' && ok "N>=5 cell prints success rate" || no "N>=5 cell missing its rate"
echo "$out" | grep -q 'unknown(1)' && ok "old 10-field row lands in the unknown bucket" || no "unknown bucket missing"
echo "$out" | grep -q 'unknown · fable-tier · S : n=1 success=0 failed=0 abandoned=1$' && ok "N<5 cell prints counts only (no %)" || no "N<5 cell printed a percentage"
echo "$out" | grep -q 'INTEGRITY rows: 2' && ok "INTEGRITY rows joined from gatelogs" || no "INTEGRITY join wrong"
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
grep -qF 'date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness' "$REPO/.claude/skills/wrap/SKILL.md" && grep -qF 'col["harness"]' "$REPO/scripts/harness-report.sh" && ok "wrap header and report parser agree on the schema" || no "wrap and report schema drifted apart"
grep -qF 'date,harness,area,severity,summary,ref' "$REPO/.claude/skills/wrap/SKILL.md" && ok "wrap prose carries the friction schema" || no "friction schema missing from wrap"
grep -q 'stock_update scripts/harness-report.sh' "$REPO/sync-project.sh" && ok "sync ships harness-report.sh" || no "sync does not ship harness-report.sh"

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
( cd "$WORK" && "$REPO/start_project.sh" --local --kind code lab ) >/dev/null 2>&1
P="$WORK/lab"
if [ ! -d "$P" ]; then
  no "spawn failed — remaining L2 tests skipped"
else
  ok "spawn succeeded"
  miss=""
  for f in .claude/settings.json .claude/hooks/session-start.sh .claude/hooks/stop-gate.sh \
           .claude/hooks/post-edit.sh .claude/skills/wrap/SKILL.md .claude/skills/task/SKILL.md \
           .claude/skills/task/reference.md .claude/skills/setup/SKILL.md \
           .claude/agents/scout.md .claude/agents/planner.md .claude/agents/plan-critic.md \
           .claude/agents/executor.md .claude/agents/verifier.md .claude/agents/reframer.md \
           .claude/.starter-version .ai_context/INDEX.md .ai_context/tasks/.gitkeep \
           scripts/harness-report.sh CLAUDE.md README.md; do
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
  for k in SessionStart PostToolUse Stop; do
    grep -q "\"$k\"" "$P/.claude/settings.json" && ok "hook wired: $k" || no "hook missing: $k"
  done
  [ -x "$P/.claude/hooks/stop-gate.sh" ] && ok "hooks executable" || no "hooks not executable"
  grep -q 'claude-starter@' "$P/.claude/.starter-version" && ok "provenance stamp present" || no "provenance stamp missing"

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

echo "=== L2-4 · research kind + artifact verify"
( cd "$WORK" && "$REPO/start_project.sh" --local --kind research rlab ) >/dev/null 2>&1
R="$WORK/rlab"
if [ ! -d "$R" ]; then
  no "research spawn failed"
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
ln -s "$REPO/start_project.sh" "$WORK/spawn-link"
( cd "$WORK" && "$WORK/spawn-link" --local --kind code symlab ) >/dev/null 2>&1
if [ -d "$WORK/symlab" ]; then
  [ -f "$WORK/symlab/CLAUDE.md" ] && ok "symlink spawn produced a project" || no "symlink spawn missing CLAUDE.md"
  [ -e "$WORK/symlab/l11" ] && no "symlink spawn copied the link's PARENT directory (SCRIPT_DIR bug regressed)" || ok "no parent-directory copy artifact"
else
  no "symlink spawn failed entirely"
fi

echo ""
echo "==== summary: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
