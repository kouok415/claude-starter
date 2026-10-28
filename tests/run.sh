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
cleanup() { rm -rf "$WORK" "${TMPDIR:-/tmp}"/claude-setup-nudge-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-integrity-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-red-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-stuck-tsuite-* "${TMPDIR:-/tmp}"/claude-status-nag-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-green-tsuite-* "$REPO/.secrets/l2-seeded-fake-cred.tmp" "$REPO/l2-seeded-untracked.tmp" ; }
trap cleanup EXIT

# --- v4 evidence fixtures ------------------------------------------------------
# Lane records only ever come from evidence.sh trust/run/check; tests edit the
# ledger, card or donelog by hand only to prove tampering and foreign records.
EV="$REPO/scripts/evidence.sh"
LANE_SMOKE='smoke | src/ scripts/ | 1 | ^verify: [1-9][0-9]* passed, 0 failed$ | bash scripts/canary.sh | bash scripts/verify.sh'
LANE_MULTI='multi | src/ scripts/ | 1 | ^verify: [0-9]+ passed, 0 failed$ ; ^coverage: ok$ | bash scripts/canary.sh | bash scripts/verify.sh'
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
mkproj() { # $1 = dir: git repo on task/demo, evidence.sh and what it reads, fixture verify/canary; commit "base" (OLD=1: 8 days ago)
  local d="$1" t
  mkdir -p "$d/src" "$d/scripts" "$d/.claude/hooks" "$d/.ai_context/tasks"
  git -C "$d" init -q -b task/demo 2>/dev/null || { git -C "$d" init -q && git -C "$d" checkout -qb task/demo; }
  printf '# ok\n## Commands\n- Test: `true`\n' > "$d/CLAUDE.md"; echo a > "$d/src/a.txt"
  # src/mode picks the behaviour; absent = pass (with a coverage line for LANE_MULTI)
  cat > "$d/scripts/verify.sh" <<'EOF'
#!/usr/bin/env bash
n="$(ls src | wc -l | tr -d ' ')"
case "$(cat src/mode 2>/dev/null)" in
  broken) echo "verify: 0 passed, 1 failed"; exit 1 ;;
  exit1) sleep 1; echo "verify: $n passed, 0 failed"; exit 1 ;;
  zero) sleep 1; echo "verify: 0 passed, 0 failed"; echo "coverage: ok" ;;
  partial) sleep 1; echo "verify: $n passed, 0 failed" ;;
  mutate) sleep 1; echo x >> src/b.txt; echo "verify: $n passed, 0 failed" ;;
  leak) sleep 1; cat src/emit.txt; echo "verify: $n passed, 0 failed" ;;
  skips) sleep 1; echo "verify: $n passed, 0 failed"; echo "3 skipped" ;;
  slow) sleep 3; echo "verify: $n passed, 0 failed" ;;
  *) sleep 1; echo "verify: $n passed, 0 failed"; echo "coverage: ok" ;;
esac
EOF
  printf '#!/usr/bin/env bash\necho "verify: 0 passed, 1 failed"; exit 1\n' > "$d/scripts/canary.sh"
  cp "$EV" "$REPO/scripts/precommit-gitleaks.sh" "$REPO/scripts/harness-report.sh" "$d/scripts/"
  cp "$REPO/.claude/hooks/guard-patterns.sh" "$d/.claude/hooks/"; cp "$REPO/.claude/gitleaks.toml" "$d/.claude/"; cp "$REPO/.gitignore" "$d/"
  chmod +x "$d"/scripts/*.sh; git -C "$d" add -A
  if [ "${OLD:-}" = 1 ]; then t="@$(( $(date +%s) - 8 * 86400 )) +0000"; GIT_AUTHOR_DATE="$t" GIT_COMMITTER_DATE="$t" git -C "$d" commit -qm base
  else git -C "$d" commit -qm base; fi
}
mklanes() { local d="$1"; shift; { echo '# name | paths | min_secs | expect | canary | cmd'; printf '%s\n' "$@"; } > "$d/.claude/done-lanes"; }
mkcard() { # $1 dir, $2 slug, $3 pair (codex|off), then slice lines; also points CURRENT at it
  local d="$1" s="$2" p="$3"; shift 3; mkdir -p "$d/.ai_context/tasks/$s"
  { echo '# Demo task'; echo "<!-- card v4 ; pair: $p ; base: $(git -C "$d" rev-parse HEAD) ; estimate: 2h 100L -->"
    echo 'Goal: CARD-MARKER fixture goal'; echo 'Done when: verify passes ; outside check: suite'
    echo 'Decisions: [human] use smoke ; [own] fixture only'; echo '## Slices'; printf '%s\n' "$@"; } > "$d/.ai_context/tasks/$s/card.md"
  echo "$s" > "$d/.ai_context/tasks/CURRENT"
}
ev() { local d="$1"; shift; ( cd "$d" && PATH="${EVPATH:-$PATH}" bash scripts/evidence.sh "$@" ) >"$WORK/ev.out" 2>"$WORK/ev.err"; echo $?; }
rep() { # checker report (I-5): claim lines (default one VERIFIED), then the verdict line
  local u="$1" v="$2"; shift 2; [ $# -gt 0 ] || set -- 'VERIFIED (L4) fixture claim — bash scripts/verify.sh'
  printf '%s\n' "$@" "checker-verdict: $u $v"
}
dl() { awk -F'\t' -v t="$3" '$2 == t' "$1/.ai_context/tasks/$2/donelog" 2>/dev/null | wc -l | tr -d ' '; }
dl7() { local f="$1/.ai_context/tasks/$2/donelog"; [ -s "$f" ] && awk -F'\t' 'NF != 7 {exit 1}' "$f" && ! cut -f1 "$f" | grep -Evq "$TS_RE"; }
lastid() { python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["id"])' "$1/.claude/evidence/$2" 2>/dev/null; }
cdig() { sed -e 's/^- \[[ ~ox]\] /- [ ] /' -e 's/ ✓ .*$//' -e '/^Closed:/d' "$1/.ai_context/tasks/$2/card.md" | sha256sum | cut -c1-12; }
ready() { # $1 = dir: smoke trusted, card S1 [~] S2 [ ], approved, S1 started, run, checked and done
  mkproj "$1"; mklanes "$1" "$LANE_SMOKE"; ev "$1" trust smoke >/dev/null
  mkcard "$1" demo off '- [~] S1 first — lanes: smoke ; codex: no' '- [ ] S2 second — lanes: smoke ; codex: no'
  ev "$1" approve >/dev/null; ev "$1" start S1 >/dev/null; ev "$1" run smoke >/dev/null
  rep S1 pass | ev "$1" check S1 --agent fx --source human >/dev/null; ev "$1" "done" S1 >/dev/null
}
mkfakes() { # a fake gitleaks (FAKE-LEAK-0123 fires rule fake-leak) and a PATH without gitleaks
  mkdir -p "$WORK/fakebin" "$WORK/nogl-bin"
  printf '#!/usr/bin/env bash\n[ "$1" = help ] && exit 0\nf="$2"; [ "$1" = detect ] && f="$4"\ngrep -q FAKE-LEAK-0123 "$f" && { echo "RuleID:      fake-leak"; exit 1; }\nexit 0\n' > "$WORK/fakebin/gitleaks"
  chmod +x "$WORK/fakebin/gitleaks"
  for b in bash sh grep sed awk date tr cat rm mv mkdir wc head tail dirname env python3 sha256sum cut sort find stat touch ls kill ps timeout git mktemp chmod cmp cp sleep; do
    p="$(command -v "$b" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$WORK/nogl-bin/$b" 2>/dev/null
  done
}

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

echo "=== L1-25 · evidence.sh: done-lanes, trust and --scan-file (v4)"
mkfakes
P="$WORK/l125"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE"; TRF="$P/.claude/done-lanes.trust"
# A size guard, not a budget: evidence.sh is executed, never injected into model context, so it
# is written for reading; the guard only catches the file roughly doubling.
n="$(wc -l < "$EV" | tr -d ' ')"; [ "$n" -le 1200 ] && ok "evidence.sh has not doubled ($n lines, guard 1200)" || no "evidence.sh is $n lines (guard 1200) — it roughly doubled; find out why before raising the guard"
mklanes "$P" "$LANE_SMOKE" "${LANE_SMOKE/smoke/l2}" "${LANE_SMOKE/smoke/l3}" "${LANE_SMOKE/smoke/l4}"
rc=$(ev "$P" trust smoke); { [ "$rc" = 2 ] && grep -qF 'declares 4 lanes (max 3)' "$WORK/ev.err"; } && ok "four lanes refused (max 3, exit 2)" || no "four lanes not refused (rc=$rc)"
for c in 'bash -n scripts/verify.sh' 'python3 -m py_compile src/x.py' 'shellcheck scripts/verify.sh' 'bash scripts/verify.sh --help' 'bash scripts/verify.sh --list-tests' \
         'bash scripts/verify.sh --parse-check' 'bash scripts/verify.sh --selftest' 'grep -q a src/a.txt' 'test -f src/a.txt && ls src'; do
  mklanes "$P" "st | src/ | 1 | ^x\$ | bash scripts/canary.sh | $c"; rc=$(ev "$P" trust st)
  { [ "$rc" = 3 ] && grep -qF 'TRUST REFUSED — st: static-only command' "$WORK/ev.err" && ! grep -q '	st	' "$TRF" 2>/dev/null; } \
    && ok "trust refuses a static-only lane: $c" || no "static-only lane not refused (rc=$rc): $c"
done
mklanes "$P" "${LANE_SMOKE/| 1 |/| 0 |}"; rc=$(ev "$P" trust smoke)
{ [ "$rc" = 2 ] && grep -qF 'min_secs must be an integer >= 1' "$WORK/ev.err"; } && ok "min_secs 0 is a done-lanes format error (exit 2)" || no "min_secs 0 accepted (rc=$rc)"
mklanes "$P" 'smoke | src/ scripts/ | 1 |  | bash scripts/canary.sh | bash scripts/verify.sh'; rc=$(ev "$P" trust smoke)
{ [ "$rc" = 2 ] && grep -qF 'expect is empty' "$WORK/ev.err"; } && ok "an empty expect is a format error (exit 2)" || no "empty expect accepted (rc=$rc)"
# A canary that passes, spelled differently from cmd (a canary equal to cmd is refused earlier as trivial).
mklanes "$P" "${LANE_SMOKE/bash scripts\/canary.sh/BROKEN=0 bash scripts/verify.sh}"; rc=$(ev "$P" trust smoke)
{ [ "$rc" = 3 ] && grep -qF 'the canary passed' "$WORK/ev.err" && ! grep -q '	smoke	' "$TRF" 2>/dev/null; } && ok "a canary that passes is refused, nothing recorded" || no "passing canary accepted (rc=$rc)"
mklanes "$P" 'vm | src/ | 1 | ^verify: [1-9] | skip:needs the VM | bash scripts/verify.sh'; rc=$(ev "$P" trust vm)
{ [ "$rc" = 3 ] && grep -qF 'canary is skip:needs the VM' "$WORK/ev.err" && grep -qF -- '--skip-canary' "$WORK/ev.err"; } && ok "a skip: canary needs the human's --skip-canary" || no "skip: canary trusted without the flag (rc=$rc)"
rc=$(ev "$P" trust vm --skip-canary); { [ "$rc" = 0 ] && [ "$(tail -n 1 "$TRF" | cut -f7)" = 'skip:needs the VM' ]; } && ok "--skip-canary records canary_result skip:<reason>" || no "--skip-canary trust failed (rc=$rc)"
rm -f "$TRF"; mklanes "$P" "$LANE_SMOKE"; rc=$(ev "$P" trust smoke)
{ [ "$rc" = 0 ] && grep -qF 'trusted lane smoke — canary red:exit=1' "$WORK/ev.out" && head -n 1 "$TRF" | grep -q '^# ts	lane	cmd_sha	lane_sha	dir_sha	canary_sha	canary_result' \
  && [ "$(grep -vc '^#' "$TRF")" = 1 ] && tail -n 1 "$TRF" | awk -F'\t' 'NF == 7 && $2 == "smoke" && $7 == "red:exit=1"' | grep -q . && tail -n 1 "$TRF" | cut -f1 | grep -Eq "$TS_RE" \
  && [ "$(tail -n 1 "$TRF" | cut -f3-6 | grep -Ec '^[0-9a-f]{12}	[0-9a-f]{12}	[0-9a-f]{12}	[0-9a-f]{12}$')" = 1 ]; } \
  && ok "trust: red canary, commented header, one 7-field UTC row" || no "trust row or output wrong (rc=$rc): $(tail -n 1 "$TRF" 2>/dev/null)"
[ "$(tail -n 1 "$TRF" | cut -f3)" = "$(printf '%s' 'bash scripts/verify.sh' | sha256sum | cut -c1-12)" ] && ok "cmd_sha = sha256(cmd)[:12]" || no "cmd_sha is not sha256 of the cmd field"
mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no'; rc=$(ev "$P" trust smoke)
{ [ "$rc" = 0 ] && dl7 "$P" demo && awk -F'\t' '$2 == "TRUST" && $4 == "smoke" && $7 ~ /^canary red:exit=1 cmd /' "$P/.ai_context/tasks/demo/donelog" | grep -q .; } \
  && ok "trust during a task writes a 7-field TRUST donelog row" || no "TRUST donelog row missing or malformed"
grep -qxF '.claude/evidence/' "$REPO/.gitignore" && ok "template .gitignore ignores .claude/evidence/" || no ".claude/evidence/ not in the template .gitignore"
miss=""; for f in static_only donelog_row lock_alive task_slug card_current_slice; do grep -q "^$f() {" "$REPO/.claude/hooks/guard-patterns.sh" || miss="$miss $f"; done
[ -z "$miss" ] && ok "guard-patterns.sh ships the five v4 helpers evidence.sh sources" || no "guard-patterns.sh lacks:$miss"
mv "$P/.claude/hooks/guard-patterns.sh" "$WORK/gp.bak"; rc=$(ev "$P" trust smoke); mv "$WORK/gp.bak" "$P/.claude/hooks/guard-patterns.sh"
{ [ "$rc" = 6 ] && grep -qF 'guard-patterns.sh is missing or predates v4' "$WORK/ev.err"; } && ok "missing guard-patterns.sh is an internal error (exit 6)" || no "missing guard-patterns.sh not caught (rc=$rc)"
cp "$P/.gitignore" "$WORK/gi.bak"; grep -vxF '.claude/evidence/' "$WORK/gi.bak" > "$P/.gitignore"; rc=$(ev "$P" trust smoke); grep -qF 'is not gitignored' "$WORK/ev.err"; m=$?
rc2=$(ev "$P" status --porcelain); cp "$WORK/gi.bak" "$P/.gitignore"
{ [ "$rc" = 6 ] && [ "$m" = 0 ] && [ "$rc2" = 0 ]; } && ok "unignored .claude/evidence/ refuses (exit 6); status --porcelain still exits 0" || no "ignore guard wrong (trust rc=$rc, porcelain rc=$rc2)"
mklanes "$P" "${LANE_SMOKE/bash scripts\/canary.sh/false}"; rc=$(ev "$P" trust smoke)
{ [ "$rc" = 3 ] && grep -qF 'canary is trivial' "$WORK/ev.err"; } && ok "canary 'false' is trivial" || no "trivial canary accepted (rc=$rc)"
mklanes "$P" "${LANE_SMOKE/bash scripts\/canary.sh/echo y >> src/a.txt; bash scripts/canary.sh}"; rc=$(ev "$P" trust smoke); echo a > "$P/src/a.txt"
{ [ "$rc" = 3 ] && grep -qF "the canary left the lane's content changed" "$WORK/ev.err"; } && ok "a canary that leaves the lane changed is refused" || no "dirty canary accepted (rc=$rc)"
mklanes "$P" "$LANE_SMOKE" '@verify-paths src/'; rc=$(ev "$P" run smoke); grep -qF '@ directives or scan rules changed since trust' "$WORK/ev.err"; m=$?
ev "$P" trust smoke >/dev/null; rc2=$(ev "$P" run smoke)
{ [ "$rc" = 3 ] && [ "$m" = 0 ] && [ "$rc2" = 0 ]; } && ok "a new @ line needs a re-trust before run" || no "@ line change not caught (rc=$rc, after trust rc=$rc2)"
cp "$P/.claude/gitleaks.toml" "$WORK/gl.bak"; echo '# local note' >> "$P/.claude/gitleaks.toml"; rc=$(ev "$P" run smoke); cp "$WORK/gl.bak" "$P/.claude/gitleaks.toml"
{ [ "$rc" = 3 ] && grep -qF '@ directives or scan rules changed since trust' "$WORK/ev.err"; } && ok "editing .claude/gitleaks.toml needs a re-trust" || no "scan rule change not caught (rc=$rc)"
mklanes "$P" "${LANE_SMOKE/failed\$/failed}" '@verify-paths src/'; rc=$(ev "$P" run smoke); mklanes "$P" "$LANE_SMOKE" '@verify-paths src/'
{ [ "$rc" = 3 ] && grep -qF 'lane line changed since trust' "$WORK/ev.err"; } && ok "an expect edit needs a re-trust" || no "expect edit not caught (rc=$rc)"
mklanes "$P" "${LANE_SMOKE/bash scripts\/verify.sh/bash scripts/verify.sh | cat}"; rc=$(ev "$P" trust smoke); mklanes "$P" "$LANE_SMOKE" '@verify-paths src/'
{ [ "$rc" = 2 ] && grep -qF "no '|' inside cmd" "$WORK/ev.err"; } && ok "a pipeline in cmd is a format error" || no "pipe in cmd accepted (rc=$rc)"
mklanes "$P" "$LANE_SMOKE" '@verify-paths src/' '@ext nosuch echo ab12cd3'; rc=$(ev "$P" trust smoke); mklanes "$P" "$LANE_SMOKE" '@verify-paths src/'
{ [ "$rc" = 2 ] && grep -qF "@ext names unknown lane 'nosuch'" "$WORK/ev.err"; } && ok "@ext must name a declared lane" || no "@ext of an unknown lane accepted (rc=$rc)"
GL="$REPO/.claude/gitleaks.toml"
{ grep -qF 'useDefault = true' "$GL" && grep -qF 'id = "internal-ipv4"' "$GL" && grep -qF '10\.0\.2\.' "$GL"; } && ok ".claude/gitleaks.toml: default rules + internal-ipv4 + QEMU allowlist" || no ".claude/gitleaks.toml incomplete"
echo 'all clean here' > "$WORK/scan-clean.txt"; printf 'connect 10.%s.30.40:443\n' 20 > "$WORK/scan-ip.txt"; printf 'qemu guest %s\n' "$(printf '10.0.2.%s' 15)" > "$WORK/scan-qemu.txt"
PATH="$WORK/nogl-bin" bash "$P/scripts/precommit-gitleaks.sh" --scan-file "$WORK/scan-clean.txt" >/dev/null 2>&1; ck 3 $? "--scan-file without gitleaks: clean, internal-ipv4 only (exit 3)"
out="$(PATH="$WORK/nogl-bin" bash "$P/scripts/precommit-gitleaks.sh" --scan-file "$WORK/scan-ip.txt" 2>/dev/null)"; rc=$?
{ [ "$rc" = 1 ] && [ "$out" = internal-ipv4 ]; } && ok "--scan-file without gitleaks: an internal IP fires internal-ipv4" || no "ERE fallback missed the internal IP (rc=$rc, '$out')"
PATH="$WORK/nogl-bin" bash "$P/scripts/precommit-gitleaks.sh" --scan-file "$WORK/scan-qemu.txt" >/dev/null 2>&1; ck 3 $? "--scan-file without gitleaks: QEMU 10.0.2.0/24 is allowlisted"
if command -v gitleaks >/dev/null 2>&1; then
  out="$(bash "$P/scripts/precommit-gitleaks.sh" --scan-file "$WORK/scan-ip.txt" 2>/dev/null)"; rc=$?
  bash "$P/scripts/precommit-gitleaks.sh" --scan-file "$WORK/scan-qemu.txt" >/dev/null 2>&1; rc2=$?
  { [ "$rc" = 1 ] && [ "$out" = internal-ipv4 ] && [ "$rc2" = 0 ]; } && ok "gitleaks and the ERE fallback agree (internal IP hit, QEMU clean)" || no "gitleaks parity broken (ip rc=$rc '$out', qemu rc=$rc2)"
  G="$WORK/l125g"; mkdir -p "$G"; git -C "$G" init -q; cp "$WORK/scan-ip.txt" "$G/notes.txt"; git -C "$G" add notes.txt
  ( cd "$G" && bash "$REPO/scripts/precommit-gitleaks.sh" ) >/dev/null 2>&1; ck 0 $? "pre-commit (no args) keeps gitleaks' own config: a staged internal IP passes"
else
  skp "gitleaks parity (gitleaks not installed)"; skp "pre-commit default-config scan (gitleaks not installed)"
fi
{ ! grep -qE 'gitleaks\.toml|--config' "$REPO/.pre-commit-config.yaml" && [ ! -e "$REPO/.gitleaks.toml" ]; } && ok "pre-commit gitleaks hook unchanged; no repo-root .gitleaks.toml" || no "pre-commit reads the lane rules or a root .gitleaks.toml appeared"

echo "=== L1-26 · evidence.sh run (v4)"
P="$WORK/l126"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE" "$LANE_MULTI"; ev "$P" trust smoke >/dev/null; ev "$P" trust multi >/dev/null
mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no'; PL="$P/.claude/evidence/smoke.jsonl"; PD="$P/.ai_context/tasks/demo/donelog"
jf() { python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1]).get(sys.argv[2]))' "$P/.claude/evidence/$1" "$2" 2>/dev/null; }
mklanes "$P" "$LANE_SMOKE" "$LANE_MULTI" 'fork | src/ | 1 | ^verify: [0-9]+ passed | bash scripts/canary.sh | bash scripts/verify.sh'; rc=$(ev "$P" run fork)
{ [ "$rc" = 3 ] && grep -qF 'RUN REFUSED — lane fork: never trusted' "$WORK/ev.err" && [ ! -e "$P/.claude/evidence/fork.jsonl" ]; } && ok "an untrusted lane never runs" || no "untrusted lane ran (rc=$rc)"
mklanes "$P" "${LANE_SMOKE/%verify.sh/verify.sh --again}" "$LANE_MULTI"; rc=$(ev "$P" run smoke); mklanes "$P" "$LANE_SMOKE" "$LANE_MULTI"
{ [ "$rc" = 3 ] && grep -qF 'command changed since trust' "$WORK/ev.err"; } && ok "a changed command is refused until re-trusted" || no "changed command ran (rc=$rc)"
rc=$(ev "$P" run smoke); { [ "$rc" = 0 ] && grep -q '^evidence: smoke PASS id=' "$WORK/ev.out"; } && ok "run smoke passes" || no "run smoke failed (rc=$rc): $(head -c 300 "$WORK/ev.out")"
python3 -I - "$PL" "$TS_RE" <<'PY' && ok "lane record: 20 keys in order (id first, markers last), UTC started" || no "lane record keys or started wrong"
import json, re, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
want = "id lane slice tree head ext cmd_sha lane_sha exit started secs executed skipped scan log log_sha verdict why ack markers".split()
ints = {"exit", "secs", "executed", "skipped", "ack"}
sys.exit(0 if list(r) == want and all(isinstance(r[k], int) for k in ints) and isinstance(r["markers"], list) and re.match(sys.argv[2], r["started"]) else 1)
PY
{ [ "$(jf smoke.jsonl verdict)" = pass ] && [ "$(jf smoke.jsonl executed)" -gt 0 ] && [ "$(jf smoke.jsonl why)" = - ] && [ "$(jf smoke.jsonl ack)" = 0 ] && [ "$(jf smoke.jsonl slice)" = S1 ]; } \
  && ok "pass record: executed > 0, why -, ack 0, slice S1" || no "pass record fields wrong"
python3 -I - "$P" "$(jf smoke.jsonl log)" <<'PY' && ok "log name <lane>-<UTC>.log, mode 600 in a 700 logs/ dir" || no "log naming or modes wrong"
import os, re, stat, sys
p, log = sys.argv[1], sys.argv[2]
m = lambda f: stat.S_IMODE(os.stat(os.path.join(p, f)).st_mode)
sys.exit(0 if re.fullmatch(r"\.claude/evidence/logs/smoke-\d{8}T\d{6}Z\.log", log) and m(log) == 0o600 and m(".claude/evidence/logs") == 0o700 else 1)
PY
{ awk -F'\t' -v id="$(lastid "$P" smoke.jsonl)" '$2 == "RUN" && NF == 7 && $3 == "S1" && $4 == "smoke" && $6 == id && $7 == "pass"' "$PD" | grep -q .; } && ok "RUN donelog row names slice, lane, record id, verdict" || no "RUN donelog row wrong"
echo partial > "$P/src/mode"; rc=$(ev "$P" run multi)
{ [ "$rc" = 1 ] && [ "$(jf multi.jsonl verdict)" = fail ] && [ "$(jf multi.jsonl why)" = expect=2 ] && grep -qF 'expect not matched — pattern 2' "$WORK/ev.out"; } && ok "a missing second marker fails with why=expect=2" || no "expect=2 not reported (rc=$rc)"
echo zero > "$P/src/mode"; ev "$P" run multi >/dev/null
{ [ "$(jf multi.jsonl verdict)" = fail ] && [ "$(jf multi.jsonl why)" = executed=0 ]; } && ok "zero work fails with why=executed=0" || no "executed=0 not caught"
echo exit1 > "$P/src/mode"; ev "$P" run smoke >/dev/null
{ [ "$(jf smoke.jsonl verdict)" = fail ] && [ "$(jf smoke.jsonl why)" = exit=1 ]; } && ok "a non-zero exit fails with why=exit=1" || no "exit=1 not caught"
rm -f "$P/src/mode"; mklanes "$P" "${LANE_SMOKE/| 1 |/| 5 |}" "$LANE_MULTI"; ev "$P" trust smoke >/dev/null; rc=$(ev "$P" run smoke)
{ [ "$(jf smoke.jsonl verdict)" = fail ] && case "$(jf smoke.jsonl why)" in too-fast:*) true ;; *) false ;; esac && grep -qF 'too fast' "$WORK/ev.out"; } && ok "faster than min_secs fails (too-fast)" || no "too-fast not caught (rc=$rc)"
mklanes "$P" "$LANE_SMOKE" "$LANE_MULTI"; ev "$P" trust smoke >/dev/null; ev "$P" run smoke >/dev/null; echo r > "$P/README.md"
ev "$P" status --line >/dev/null; grep -qF 'smoke fresh' "$WORK/ev.out" && ok "a file outside the lane's paths keeps it fresh" || no "status --line lost 'smoke fresh': $(cat "$WORK/ev.out")"
echo b > "$P/src/a.txt"; ev "$P" status --line >/dev/null; echo a > "$P/src/a.txt"
grep -qF 'smoke stale' "$WORK/ev.out" && ok "an edit inside the lane's paths makes it stale" || no "status --line missed 'smoke stale': $(cat "$WORK/ev.out")"
echo mutate > "$P/src/mode"; rc=$(ev "$P" run smoke); rm -f "$P/src/mode" "$P/src/b.txt"
{ [ "$(jf smoke.jsonl verdict)" = void ] && [ "$(jf smoke.jsonl why)" = changed-during-run ] && grep -qF 'changed during the run' "$WORK/ev.out"; } && ok "lane files changed during the run void the record" || no "mid-run change not voided (rc=$rc)"
echo leak > "$P/src/mode"; echo 'token FAKE-LEAK-0123' > "$P/src/emit.txt"; rc=$(EVPATH="$WORK/fakebin:$PATH" ev "$P" run smoke)
{ [ "$(jf smoke.jsonl scan)" = hit:fake-leak ] && [ "$(jf smoke.jsonl why)" = leak:fake-leak ] && [ "$(jf smoke.jsonl markers)" = "['withheld: scan hit']" ]; } && ok "a secret in the log fails the run and withholds the markers" || no "secret scan not applied (rc=$rc, scan=$(jf smoke.jsonl scan))"
printf 'connect 10.%s.30.40:443\n' 20 > "$P/src/emit.txt"; EVPATH="$WORK/nogl-bin" ev "$P" run smoke >/dev/null
[ "$(jf smoke.jsonl scan)" = hit:internal-ipv4 ] && ok "without gitleaks an internal IP still fails the run" || no "ERE scan missed the IP: scan=$(jf smoke.jsonl scan)"
echo slow > "$P/src/mode"; ( cd "$P" && bash scripts/evidence.sh run smoke >/dev/null 2>&1 ) & bgp=$!; sleep 1
LK="$P/.claude/evidence/locks/run-smoke.lock"
{ [ -f "$LK" ] && kill -0 "$(cut -f1 "$LK")" 2>/dev/null && [ "$(cut -f2-3 "$LK")" = "run	smoke" ] && cut -f5 "$LK" | grep -Eq "$TS_RE"; } && ok "a running lane holds a pid lock (pid, run, lane, slice, UTC)" || no "run lock missing or malformed: $(cat "$LK" 2>/dev/null)"
rc=$(ev "$P" run smoke); { [ "$rc" = 4 ] && grep -qF 'is already running (pid' "$WORK/ev.err"; } && ok "a second run of a running lane is refused (exit 4)" || no "concurrent run not refused (rc=$rc)"
wait "$bgp"; [ ! -e "$LK" ] && ok "the lock goes when the run ends" || no "lock left behind"
echo broken > "$P/src/mode"; n=0; for _ in 1 2 3; do [ "$(ev "$P" run smoke)" = 1 ] && n=$((n + 1)); done; c0="$(wc -l < "$PL" | tr -d ' ')"; rc=$(ev "$P" run smoke)
{ [ "$n" = 3 ] && [ "$rc" = 5 ] && grep -qF 'ESCALATE — lane smoke failed 3 times in a row on S1' "$WORK/ev.out" && [ "$(wc -l < "$PL" | tr -d ' ')" = "$c0" ]; } && ok "three straight fails on a slice ESCALATE (exit 5, no run)" || no "ESCALATE missing (fails=$n rc=$rc)"
awk -F'\t' '$2 == "ESCALATE" && $3 == "S1" && $4 == "smoke" && $7 == "3 consecutive fails"' "$PD" | grep -q . && ok "ESCALATE donelog row" || no "ESCALATE row missing"
c0="$(wc -l < "$PL" | tr -d ' ')"; ev "$P" run smoke --escalated >/dev/null
{ [ "$(wc -l < "$PL" | tr -d ' ')" = $((c0 + 1)) ] && [ "$(jf smoke.jsonl verdict)" = fail ] && [ "$(jf smoke.jsonl ack)" = 1 ] \
  && awk -F'\t' '$2 == "ESCALATE" && $7 == "escalated: human override"' "$PD" | grep -q .; } && ok "--escalated runs once more (ack=1, override row)" || no "--escalated did not run as an override"
rm -f "$P/src/mode"; mklanes "$P" "$LANE_SMOKE" "$LANE_MULTI" '@ext smoke echo 0123456789ab'; ev "$P" trust smoke >/dev/null; ev "$P" run smoke >/dev/null
[ "$(jf smoke.jsonl ext)" = 0123456789ab ] && ok "@ext records the external commit" || no "@ext not recorded: $(jf smoke.jsonl ext)"
mklanes "$P" "$LANE_SMOKE" "$LANE_MULTI" '@ext smoke echo not-hex'; ev "$P" trust smoke >/dev/null; rc=$(ev "$P" run smoke)
{ [ "$rc" = 1 ] && [ "$(jf smoke.jsonl ext)" = invalid ] && [ "$(jf smoke.jsonl why)" = ext ] && grep -qF '@ext printed no commit id' "$WORK/ev.out"; } && ok "a non-hex @ext fails the run (why=ext)" || no "bad @ext passed (rc=$rc)"
mklanes "$P" "$LANE_SMOKE" "$LANE_MULTI"; ev "$P" trust smoke >/dev/null
echo leak > "$P/src/mode"; printf 'guest %s\n' "$(printf '10.0.2.%s' 15)" > "$P/src/emit.txt"; EVPATH="$WORK/nogl-bin" ev "$P" run smoke >/dev/null
{ [ "$(jf smoke.jsonl verdict)" = pass ] && [ "$(jf smoke.jsonl scan)" = clean-ip-only ]; } && ok "QEMU addresses pass; without gitleaks scan=clean-ip-only" || no "QEMU log: verdict=$(jf smoke.jsonl verdict) scan=$(jf smoke.jsonl scan)"
rm -f "$P/src/mode" "$P/src/emit.txt"; sleep 0 & dp=$!; wait "$dp"; printf '%s\trun\tsmoke\tS1\t%s\n' "$dp" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$LK"; rc=$(ev "$P" run smoke)
{ [ "$rc" = 0 ] && grep -qF 'removed stale lock run-smoke.lock' "$WORK/ev.err"; } && ok "a dead lock is cleared, the run goes ahead" || no "stale lock blocked the run (rc=$rc)"
mv "$P/.ai_context/tasks/CURRENT" "$WORK/cur.bak"; c0="$(wc -l < "$PD")"; rc=$(ev "$P" run smoke); mv "$WORK/cur.bak" "$P/.ai_context/tasks/CURRENT"
{ [ "$rc" = 0 ] && [ "$(jf smoke.jsonl slice)" = - ] && [ "$(wc -l < "$PD")" = "$c0" ]; } && ok "no task: slice -, no donelog row" || no "taskless run wrote task state (rc=$rc)"

echo "=== L1-27 · evidence.sh lint / approve / start / status (v4)"
P="$WORK/l127"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null
mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no' '- [ ] S2 second — lanes: smoke ; codex: no'
C="$P/.ai_context/tasks/demo/card.md"; PD="$P/.ai_context/tasks/demo/donelog"; cp "$C" "$WORK/c127"
cedit() { sed -E "$1" "$WORK/c127" > "$C"; } # one edit on the pristine card
crestore() { cp "$WORK/c127" "$C"; }
rc=$(ev "$P" lint); { [ "$rc" = 0 ] && grep -q '^card lint ok — card .*pair off$' "$WORK/ev.out"; } && ok "lint passes a well-formed card" || no "lint rejected a good card (rc=$rc): $(cat "$WORK/ev.out")"
cedit 's/(S2 second — lanes:) smoke/\1 nosuch/'; rc=$(ev "$P" lint); { [ "$rc" = 1 ] && grep -qF "S2 names lane 'nosuch'" "$WORK/ev.out"; } && ok "lint: an undeclared lane" || no "undeclared lane passed lint (rc=$rc)"
cedit 's/^Done when: .*/Done when:/'; rc=$(ev "$P" lint); { [ "$rc" = 1 ] && grep -qF 'Done when: is empty' "$WORK/ev.out"; } && ok "lint: empty Done when:" || no "empty Done when: passed (rc=$rc)"
cedit 's/^Decisions: .*/Decisions: use smoke/'; rc=$(ev "$P" lint); { [ "$rc" = 1 ] && grep -qF 'decision without a [human]/[inferred]/[own]/[ASSUMED] tag' "$WORK/ev.out"; } && ok "lint: an untagged decision" || no "untagged decision passed (rc=$rc)"
cedit 's/^- \[ \] S2/- [~] S2/'; rc=$(ev "$P" lint); { [ "$rc" = 1 ] && grep -qF '2 slices are [~] (at most one)' "$WORK/ev.out"; } && ok "lint: two [~] slices" || no "two [~] passed (rc=$rc)"
cedit 's/^- \[[ ~]\] (S[12] .*)$/- [x] \1 ✓ smoke@0000000 check@0000000/'; rc=$(ev "$P" lint); ck 0 "$rc" "lint checks the format only: two [x] with references pass"
cedit "s/^Goal: .*/Goal: $(printf '%*s' $((4200 - $(wc -c < "$WORK/c127") + 24)) '' | tr ' ' x)/"; rc=$(ev "$P" lint)
{ [ "$rc" = 1 ] && grep -qF "card is 4200 B (cap 4096)" "$WORK/ev.out"; } && ok "lint: a card over 4096 B" || no "oversized card passed (rc=$rc, $(wc -c < "$C") B)"
crestore; mklanes "$P" '@pair codex' "$LANE_SMOKE"; rc=$(ev "$P" lint)
{ [ "$rc" = 1 ] && grep -qF 'a card may raise pairing, never lower it' "$WORK/ev.out"; } && ok "lint: card pair: off under @pair codex" || no "pairing lowered by the card (rc=$rc)"
mklanes "$P" "$LANE_SMOKE"; cedit 's/pair: off/pair: codex/'; rc=$(ev "$P" lint); ck 0 "$rc" "a card may raise pairing (pair: codex without @pair)"
crestore; rc=$(ev "$P" approve)
{ [ "$rc" = 0 ] && grep -qF 'card approved at card:' "$WORK/ev.out" && awk -F'\t' -v d="$(cdig "$P" demo)" '$2 == "APPROVE" && $4 == "human" && $5 == d' "$PD" | grep -q .; } && ok "approve writes APPROVE with the card digest" || no "approve row wrong (rc=$rc)"
n="$(dl "$P" demo APPROVE)"; cedit 's/^Goal: .*/Goal:/'; rc=$(ev "$P" approve)
{ [ "$rc" = 1 ] && grep -qF 'approve refused — fix the card first:' "$WORK/ev.out" && [ "$(dl "$P" demo APPROVE)" = "$n" ]; } && ok "approve refuses a card that fails lint" || no "approve accepted a bad card (rc=$rc)"
cedit 's/^- \[ \] S2 (.*)$/- [x] S2 \1 ✓ smoke@0000000 check@0000000/'; ev "$P" status --line >/dev/null
grep -qF 'card approved' "$WORK/ev.out" && ok "status marks and refs keep the approval" || no "status --line lost the approval: $(cat "$WORK/ev.out")"
cedit 's/^Goal: .*/Goal: another goal/'; ev "$P" status --line >/dev/null; grep -qF 'card changed' "$WORK/ev.out" && ok "a content edit shows card changed" || no "content edit not shown: $(cat "$WORK/ev.out")"
crestore; rc=$(ev "$P" start S1)
{ [ "$rc" = 0 ] && grep -qF 'S1 started at' "$WORK/ev.out" && awk -F'\t' -v h="$(git -C "$P" rev-parse HEAD | cut -c1-12)" '$2 == "START" && $3 == "S1" && $5 == h' "$PD" | grep -q .; } && ok "start S1 records START with HEAD" || no "start S1 wrong (rc=$rc)"
rc=$(ev "$P" start S9); { [ "$rc" = 2 ] && grep -qF 'no slice S9 on the card' "$WORK/ev.err"; } && ok "start of an unknown slice is a usage error" || no "start S9 rc=$rc"
mklanes "$P" '@pair codex' "$LANE_SMOKE"; cedit 's/pair: off/pair: codex/'; ev "$P" status >/dev/null
head -n 1 "$WORK/ev.out" | grep -qF 'pair on' && ok "status shows pair on (@pair codex + card pair: codex)" || no "status first line lacks pair on: $(head -n 1 "$WORK/ev.out")"
ev "$P" lint >/dev/null; grep -q 'pair on$' "$WORK/ev.out" && ok "lint reports pair on" || no "lint lacks pair on: $(cat "$WORK/ev.out")"
mklanes "$P" "$LANE_SMOKE"; cedit 's/^- \[~\] S1/- [ ] S1/; s/^- \[ \] S2/- [~] S2/'; ev "$P" status --line >/dev/null
grep -qF 'evidence[demo]: slice S2' "$WORK/ev.out" && ok "status --line names the [~] slice" || no "status --line slice wrong: $(cat "$WORK/ev.out")"
mv "$P/.ai_context/tasks/CURRENT" "$WORK/cur.bak"; rc=$(ev "$P" status --line); mv "$WORK/cur.bak" "$P/.ai_context/tasks/CURRENT"
{ [ "$rc" = 0 ] && [ ! -s "$WORK/ev.out" ]; } && ok "no task: status --line prints nothing" || no "status --line without a task: rc=$rc '$(cat "$WORK/ev.out")'"
cedit 's/^- \[~\] S1 first/- [~] S1 里程碑中文標題超長需要截斷測試甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥里程碑中文標題超長需要截斷測試甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申/'; rc=$(ev "$P" lint)
if command -v iconv >/dev/null 2>&1; then ev "$P" status --line >/dev/null
  { [ "$rc" = 0 ] && iconv -f UTF-8 -t UTF-8 "$WORK/ev.out" >/dev/null 2>&1; } && ok "a long CJK title lints and status --line stays valid UTF-8" || no "CJK title broke lint or the line (rc=$rc)"
else skp "iconv absent — CJK status line unchecked"; fi
crestore; P3="$WORK/l127c"; mkproj "$P3"; mkcard "$P3" demo off '- [~] S1 first — lanes: smoke ; codex: no'; rc=$(ev "$P3" status --porcelain)
{ [ "$rc" = 0 ] && [ "$(grep -c '^TREE	' "$WORK/ev.out")" = 1 ] && [ "$(grep -c '^CLOSED	none' "$WORK/ev.out")" = 1 ] && [ "$(grep -c '^LINE	' "$WORK/ev.out")" = 1 ]; } \
  && ok "porcelain without done-lanes or ledger: TREE, CLOSED none, LINE, exit 0" || no "porcelain incomplete (rc=$rc): $(cat "$WORK/ev.out")"
P2="$WORK/l127b"; mkproj "$P2"; mklanes "$P2" "$LANE_SMOKE"; ev "$P2" trust smoke >/dev/null
mkcard "$P2" demo off '- [ ] S1 first — lanes: smoke ; codex: no' '- [ ] S2 second — lanes: smoke ; codex: no'
rc=$(ev "$P2" lint); rc2=$(ev "$P2" approve); { [ "$rc" = 0 ] && [ "$rc2" = 0 ]; } && ok "a card with no [~] lints and approves" || no "all-[ ] card refused (lint=$rc approve=$rc2)"
ev "$P2" start S1 >/dev/null; grep -q '^- \[~\] S1 ' "$P2/.ai_context/tasks/demo/card.md" && ok "start marks the slice [~]" || no "start did not mark [~]"
rc=$(ev "$P2" start S2); { [ "$rc" = 1 ] && grep -qF 'S1 is still [~]' "$WORK/ev.err"; } && ok "start refuses a second [~]" || no "second start accepted (rc=$rc)"
rc=$(ev "$P2" start S1); { [ "$rc" = 1 ] && grep -qF 'already started at' "$WORK/ev.err"; } && ok "a repeated start is refused (the first start is the baseline)" || no "restart accepted (rc=$rc)"
cedit 's/^Decisions: .*/Decisions: [ASSUMED] x ; [inferred] y/'; rc=$(ev "$P" lint); ck 0 "$rc" "[ASSUMED] and [inferred] decisions lint"
cedit 's/(S2 second — lanes:) smoke/\1 -/'; rc=$(ev "$P" lint); { [ "$rc" = 1 ] && grep -qF 'slice line does not parse' "$WORK/ev.out"; } && ok "lanes: - does not parse (every slice has a lane)" || no "lanes: - accepted (rc=$rc)"
cedit "s/^Goal: .*/Goal: $(printf '%*s' $((3900 - $(wc -c < "$WORK/c127") + 24)) '' | tr ' ' x)/"; rc=$(ev "$P" lint); rc2=$(ev "$P" approve)
{ [ "$(wc -c < "$C" | tr -d ' ')" = 3900 ] && [ "$rc" = 1 ] && grep -qF 'leaves no room for evidence suffixes' "$WORK/ev.out" && [ "$rc2" = 1 ]; } && ok "lint and approve keep room for ✓ suffixes" || no "suffix budget not enforced (lint=$rc approve=$rc2, $(wc -c < "$C") B)"
crestore

echo "=== L1-28 · evidence.sh done / check / close / show — and what is not proven (v4)"
P="$WORK/l128"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null
mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no' '- [ ] S2 second — lanes: smoke ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null
C="$P/.ai_context/tasks/demo/card.md"; PD="$P/.ai_context/tasks/demo/donelog"
Pb="$WORK/l128b"; mkproj "$Pb"; mklanes "$Pb" "$LANE_SMOKE"; ev "$Pb" trust smoke >/dev/null
mkcard "$Pb" demo off '- [~] S1 first — lanes: smoke ; codex: no' '- [ ] S2 second — lanes: smoke ; codex: no'; ev "$Pb" start S1 >/dev/null
Pp="$WORK/l128p"; mkproj "$Pp"; mklanes "$Pp" '@pair codex' "$LANE_SMOKE"; ev "$Pp" trust smoke >/dev/null
mkcard "$Pp" demo codex '- [~] S1 first — lanes: smoke ; codex: yes' '- [ ] S2 second — lanes: smoke ; codex: yes'; ev "$Pp" approve >/dev/null; ev "$Pp" start S1 >/dev/null
ev "$Pp" run smoke >/dev/null; rep S1 pass | ev "$Pp" check S1 --agent fx --source human >/dev/null; Cp="$Pp/.ai_context/tasks/demo/card.md"
pkt() { # $1 = dir, $2 = name, $3 = stage, $4 = unit, $5 = base -> packet path (06: D's packet header)
  local f="$1/.ai_context/tasks/demo/pair/$2.md"; mkdir -p "${f%/*}"; printf 'stage: %s\nunit: %s\nbase: %s\n\n# Task\n' "$3" "$4" "$5" > "$f"; echo "$f"
}
res() { # $1 = packet, $2 = verdict, $3 = blocker, $4 = major -> result path
  printf 'run: completed\nverdict: %s\nbase: %s\nblocker: %s\nmajor: %s\nminor: 0\n\nfindings\n' "$2" "$(sed -n 's/^base: //p' "$1")" "$3" "$4" > "${1%.md}.result.md"; echo "${1%.md}.result.md"
}
cp "$C" "$WORK/c128"; rc=$(ev "$P" "done" S1); { [ "$rc" = 1 ] && cmp -s "$C" "$WORK/c128"; } && ok "done S1 refuses without a lane run; the card stays byte-identical" || no "done without a lane run (rc=$rc) or the card changed"
{ grep -qF 'NOT DONE — S1:' "$WORK/ev.out" && grep -qF 'lane smoke: never run' "$WORK/ev.out"; } && ok "NOT DONE lists the lane that never ran" || no "NOT DONE text wrong: $(head -c 400 "$WORK/ev.out")"
ev "$P" run smoke >/dev/null; rc=$(ev "$P" "done" S1); { [ "$rc" = 1 ] && grep -qF 'no checker record for S1' "$WORK/ev.out"; } && ok "done needs a checker record" || no "done without checker (rc=$rc)"
rc=$(printf '' | ev "$P" check S1 --agent t0 --source human); { [ "$rc" = 0 ] && grep -Eq '^check S1 uncaptured [0-9a-f]{8}$' "$WORK/ev.out"; } && ok "an empty report records verdict uncaptured" || no "empty report: rc=$rc $(cat "$WORK/ev.out")"
rc=$(ev "$P" "done" S1); { [ "$rc" = 1 ] && grep -qF 'for S1: uncaptured' "$WORK/ev.out"; } && ok "done names the uncaptured checker record" || no "uncaptured checker not reported (rc=$rc)"
printf 'VERIFIED (L4) a — b\n' | ev "$P" check S1 --agent t1 --source human >/dev/null; grep -q '^check S1 unparsed ' "$WORK/ev.out" && ok "a report without a verdict line is unparsed" || no "no-verdict report: $(cat "$WORK/ev.out")"
rep S1 pass 'NOT VERIFIED (L2) a — b' | ev "$P" check S1 --agent t2 --source human >/dev/null
awk -F'\t' -v id="$(lastid "$P" checker.jsonl)" '$2 == "CHECK" && $3 == "S1" && $4 == "checker" && $5 ~ /^[0-9a-f]{12}$/ && $6 == id && $7 == "fail"' "$PD" | grep -q . \
  && ok "a NOT VERIFIED claim makes the check fail (CHECK row)" || no "NOT VERIFIED check row wrong"
rc=$(ev "$P" "done" S1); ck 1 "$rc" "done refuses a failing checker record"
rep S2 pass | ev "$P" check S1 --agent t3 --source human >/dev/null; grep -q '^check S1 fail ' "$WORK/ev.out" && ok "a verdict for another slice fails (slice-mismatch)" || no "slice mismatch: $(cat "$WORK/ev.out")"
rep S1 pass 'VERIFIED (L4) a — b' 'INCONCLUSIVE (L3) c — d' | ev "$P" check S1 --agent t4 --source human >/dev/null; grep -q '^check S1 pass ' "$WORK/ev.out" && ok "VERIFIED + INCONCLUSIVE with a pass line passes" || no "pass check: $(cat "$WORK/ev.out")"
rc=$(ev "$P" "done" S1); { [ "$rc" = 0 ] && grep -qF 'S1 ✓ smoke@' "$WORK/ev.out"; } && ok "done S1 with a fresh lane and a passing check" || no "done S1 refused (rc=$rc): $(head -c 600 "$WORK/ev.out")"
cp "$WORK/ev.out" "$WORK/done1.out"; sid="$(lastid "$P" smoke.jsonl)"; cid="$(lastid "$P" checker.jsonl)"
grep -qxF -- "- [x] S1 first — lanes: smoke ; codex: no ✓ smoke@$sid check@$cid" "$C" && ok "the card line carries ✓ smoke@<id> check@<id>" || no "card line wrong: $(grep ' S1 ' "$C")"
awk -F'\t' -v r="smoke@$sid,check@$cid" '$2 == "DONE" && $3 == "S1" && $6 == r' "$PD" | grep -q . && ok "DONE row repeats the card's tokens" || no "DONE row tokens differ"
{ grep -qF 'Not proven this time' "$WORK/done1.out" && grep -qF 'INCONCLUSIVE' "$WORK/done1.out"; } && ok "done prints what is not proven (the INCONCLUSIVE claim)" || no "done footer missing"
ev "$P" status --porcelain >/dev/null; grep -q '^SLICE	S1	ok' "$WORK/ev.out" && ok "porcelain: S1 ok" || no "porcelain S1: $(grep SLICE "$WORK/ev.out")"
ev "$P" start S2 >/dev/null; rc=$(ev "$P" "done" S2); { [ "$rc" = 1 ] && grep -qF 'no run since S2 started' "$WORK/ev.out"; } && ok "a run from before the slice started does not count" || no "pre-start run accepted (rc=$rc)"
mkdir -p "$P/docs"; echo x > "$P/docs/x.md"; ev "$P" run smoke >/dev/null; rep S2 pass | ev "$P" check S2 --agent t5 --source human >/dev/null; rc=$(ev "$P" "done" S2)
{ [ "$rc" = 1 ] && grep -qF "outside its lanes' paths" "$WORK/ev.out" && grep -qF 'docs/x.md' "$WORK/ev.out"; } && ok "done refuses changes outside the slice's lane paths" || no "uncovered change accepted (rc=$rc)"
ev "$Pb" run smoke >/dev/null; rep S1 pass | ev "$Pb" check S1 --agent fx --source human >/dev/null; rc=$(ev "$Pb" "done" S1)
{ [ "$rc" = 1 ] && grep -qF 'approved never' "$WORK/ev.out"; } && ok "done refuses an unapproved card" || no "unapproved done (rc=$rc)"
ev "$Pb" approve >/dev/null; sed -i.bak 's/^Goal: .*/Goal: moved/' "$Pb/.ai_context/tasks/demo/card.md"; rc=$(ev "$Pb" "done" S1)
{ [ "$rc" = 1 ] && grep -qF 'card changed since approval' "$WORK/ev.out"; } && ok "done refuses a card edited after approval" || no "edited card accepted (rc=$rc)"
rc=$(ev "$Pp" "done" S1); { [ "$rc" = 1 ] && grep -qF 'no approving codex-card review' "$WORK/ev.out"; } && ok "pair on: done needs the card's Codex review" || no "codex-card gap missing (rc=$rc)"
k="$(pkt "$Pp" 001-card card card "card:$(sed -e 's/^- \[[ ~ox]\] /- [ ] /' -e 's/ ✓ .*$//' -e '/^Closed:/d' "$Cp" | sha256sum | cut -c1-64)")"
out="$(cd "$Pp" && bash scripts/evidence.sh codex "$k" "$(res "$k" pass 0 0)" completed ok 2>/dev/null)"; rc=$(ev "$Pp" "done" S1)
{ [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && [ "$out" = "$(lastid "$Pp" codex.jsonl)" ] && [ "$rc" = 1 ] && grep -qF 'no approving codex-slice review of S1' "$WORK/ev.out"; } \
  && ok "codex prints only the record id; the slice still needs its own review" || no "codex card record or slice gap wrong (out='$out' rc=$rc)"
k="$(pkt "$Pp" 002-slice-S1 slice S1 "$(git -C "$Pp" rev-parse HEAD)")"; ( cd "$Pp" && bash scripts/evidence.sh codex "$k" "$(res "$k" pass 0 1)" completed ok >/dev/null 2>&1 ); rc=$(ev "$Pp" "done" S1)
{ [ "$rc" = 1 ] && [ "$(python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(r["verdict"], r["high"])' "$Pp/.claude/evidence/codex.jsonl")" = 'pass 1' ]; } \
  && ok "a pass carrying a major does not approve" || no "pass+major approved (rc=$rc)"
k="$(pkt "$Pp" 003-slice-S1 slice S1 "$(git -C "$Pp" rev-parse HEAD)")"; ( cd "$Pp" && bash scripts/evidence.sh codex "$k" "${k%.md}.result.md" failed no_result >/dev/null 2>&1 )
k="$(pkt "$Pp" 004-slice-S1 slice S1 "$(git -C "$Pp" rev-parse HEAD)")"; err="$(cd "$Pp" && bash scripts/evidence.sh codex "$k" "${k%.md}.result.md" failed no_result 2>&1 >/dev/null)"; rc=$(ev "$Pp" "done" S1)
{ printf '%s' "$err" | grep -qF 'codex no verdict twice' && [ "$rc" = 1 ]; } && ok "two no-verdict runs at one content warn; done stays refused" || no "no-verdict twice: '$err' rc=$rc"
rc=$(ev "$Pp" approve --waive S1 --reason "quota out")
{ [ "$rc" = 0 ] && awk -F'\t' -v d="$(awk -F'\t' '$2 == "APPROVE" {a = $5} END {print a}' "$Pp/.ai_context/tasks/demo/donelog")" '$2 == "WAIVE" && NF == 7 && $3 == "S1" && $4 == "human" && $5 == d && $7 == "quota out"' "$Pp/.ai_context/tasks/demo/donelog" | grep -q .; } \
  && ok "approve --waive writes a WAIVE row bound to the card digest" || no "WAIVE row wrong (rc=$rc)"
rc=$(ev "$Pp" "done" S1); { [ "$rc" = 0 ] && grep -q '^- \[x\] S1 .*codex@waived' "$Cp" && grep -qF 'waived by the human' "$WORK/ev.out"; } && ok "a waived Codex review lets done write codex@waived" || no "waived done refused (rc=$rc): $(head -c 400 "$WORK/ev.out")"
sed -i.bak 's/^Goal: .*/Goal: moved/' "$Cp"; ev "$Pp" approve >/dev/null; ev "$Pp" status --porcelain >/dev/null; grep -q '^SLICE	S1	bad' "$WORK/ev.out"; b1=$?
sed -i.bak 's/^Goal: .*/Goal: CARD-MARKER fixture goal/' "$Cp"; ev "$Pp" approve >/dev/null; ev "$Pp" status --porcelain >/dev/null; grep -q '^SLICE	S1	ok' "$WORK/ev.out"; b2=$?
{ [ $b1 = 0 ] && [ $b2 = 0 ]; } && ok "a waiver holds only under the digest it was given at" || no "waiver digest binding wrong (changed=$b1 restored=$b2)"
rc=$(ev "$P" approve --waive S1 --reason x); { [ "$rc" = 1 ] && grep -qF 'pairing is off' "$WORK/ev.err"; } && ok "pair off: nothing to waive" || no "waive with pair off (rc=$rc)"
rc=$(ev "$Pp" approve --waive S9 --reason x); rc2=$(ev "$Pp" approve --waive S2); { [ "$rc" = 2 ] && [ "$rc2" = 2 ]; } && ok "--waive needs a real unit and a reason" || no "bad --waive accepted ($rc, $rc2)"
ev "$Pp" start S2 >/dev/null; ev "$Pp" run smoke >/dev/null; rep S2 pass | ev "$Pp" check S2 --agent fx --source human >/dev/null
k="$(pkt "$Pp" 005-slice-S2 slice S2 "$(git -C "$Pp" rev-parse HEAD)")"; ( cd "$Pp" && bash scripts/evidence.sh codex "$k" "$(res "$k" pass 0 0)" completed ok >/dev/null 2>&1 ); rc=$(ev "$Pp" "done" S2)
{ [ "$rc" = 0 ] && grep -q "^- \[x\] S2 .* codex@$(lastid "$Pp" codex.jsonl)\$" "$Cp"; } && ok "an approving codex-slice review lands as codex@<id>" || no "codex slice done failed (rc=$rc)"
ev "$P" show smoke >/dev/null; { grep -qF "record: {\"id\":\"$(lastid "$P" smoke.jsonl)\"" "$WORK/ev.out" && grep -qF '"lane":"smoke"' "$WORK/ev.out"; } && ok "show prints the latest record" || no "show record wrong"
grep -qF 'Not proven this time' "$WORK/ev.out" && ok "show ends with what is not proven" || no "show footer missing"
echo skips > "$P/src/mode"; ev "$P" run smoke >/dev/null; ev "$P" show smoke >/dev/null; rm -f "$P/src/mode"
grep -qF 'smoke log reports 3 skipped' "$WORK/ev.out" && ok "show names skipped tests" || no "skipped not reported"
echo b > "$P/src/a.txt"; ev "$P" show smoke >/dev/null; echo a > "$P/src/a.txt"; grep -qF 'lane smoke: stale' "$WORK/ev.out" && ok "show flags a stale lane" || no "stale lane not shown"
rc=$(ev "$P" close); { [ "$rc" = 1 ] && grep -qF 'NOT CLOSED —' "$WORK/ev.out" && grep -qF 'not done: S2 [~]' "$WORK/ev.out"; } && ok "close refuses while a slice is not [x]" || no "close with open slice (rc=$rc)"
rm -rf "$P/docs"; ev "$P" run smoke >/dev/null; rep S2 pass | ev "$P" check S2 --agent fx --source human >/dev/null; ev "$P" "done" S2 >/dev/null
echo b > "$P/src/a.txt"; rc=$(ev "$P" close); echo a > "$P/src/a.txt"
{ [ "$rc" = 1 ] && grep -qF 'lane smoke: stale' "$WORK/ev.out"; } && ok "close refuses a stale lane" || no "close with a stale lane (rc=$rc)"
ev "$P" run smoke >/dev/null; rc=$(ev "$P" close); { [ "$rc" = 1 ] && grep -qF 'no passing checker final record' "$WORK/ev.out"; } && ok "pair off: close needs a checker final record" || no "close without checker final (rc=$rc)"
mklanes "$P" "$LANE_SMOKE" 'idle | docs/ | 1 | ^x | bash scripts/canary.sh | bash scripts/verify.sh'
rep final pass | ev "$P" check final --agent fx --source human >/dev/null; rc=$(ev "$P" close); cp "$WORK/ev.out" "$WORK/close.out"
{ [ "$rc" = 0 ] && grep -Eq "^Closed: tree:[0-9a-f]{12} head:[0-9a-f]{12} ✓ smoke@$(lastid "$P" smoke.jsonl) check@$(lastid "$P" checker.jsonl) — [0-9TZ:-]+\$" "$C" \
  && grep -qF 'Not proven this time' "$WORK/close.out" && grep -qF 'next: /wrap' "$WORK/close.out"; } && ok "close writes Closed: (an uncited, never-run lane does not block)" || no "close failed (rc=$rc): $(head -c 600 "$WORK/close.out")"
awk -F'\t' -v r="$(sed -n 's/^Closed: .* ✓ \(.*\) — .*/\1/p' "$C" | tr ' ' ,)" '$2 == "CLOSE" && $6 == r' "$PD" | grep -q . && ok "CLOSE row repeats the Closed: tokens" || no "CLOSE row tokens differ"
ev "$P" status --porcelain >/dev/null; { grep -q '^CLOSED	ok' "$WORK/ev.out" && [ ! -s "$WORK/ev.err" ]; } && ok "porcelain: CLOSED ok, nothing on stderr" || no "porcelain CLOSED: $(grep CLOSED "$WORK/ev.out") stderr: $(head -c 200 "$WORK/ev.err")"
rc=$(ev "$Pp" close); { [ "$rc" = 1 ] && grep -qF 'no approving codex-final review' "$WORK/ev.out"; } && ok "pair on: close needs the final Codex review" || no "close without codex-final (rc=$rc): $(head -c 400 "$WORK/ev.out")"
ev "$Pp" approve --waive final --reason x >/dev/null; rc=$(ev "$Pp" close); { [ "$rc" = 0 ] && grep -q '^Closed: .*codex@waived' "$Cp"; } && ok "a waived final review closes with codex@waived" || no "waived close failed (rc=$rc): $(head -c 400 "$WORK/ev.out")"
bad=""; for d in "$P" "$Pp"; do dl7 "$d" demo || bad="$bad 7col:$d"; cut -f2 "$d/.ai_context/tasks/demo/donelog" | grep -Evxq 'TRUST|APPROVE|WAIVE|START|SPAWN|RETURN|RUN|CHECK|CODEX|DONE|CLOSE|BLOCK|WAITING|STUCK|ESCALATE|GATE-ERROR' && bad="$bad type:$d"; done
[ -z "$bad" ] && ok "donelogs: 7 fields, UTC ts, the 16 row types only" || no "donelog format:$bad"
rc=$(rep card pass | ev "$Pb" check card --agent fx --source human); rc2=$(ev "$Pb" approve)
{ [ "$rc" = 0 ] && awk -F'\t' -v d="$(cdig "$Pb" demo)" '$2 == "CHECK" && $3 == "card" && $5 == d && $7 == "pass"' "$Pb/.ai_context/tasks/demo/donelog" | grep -q . && [ ! -e "$Pb/.ai_context/defects.csv" ] && [ "$rc2" = 0 ]; } \
  && ok "a card-mode check records unit card at the card digest; approve does not need it" || no "card check wrong (rc=$rc approve=$rc2)"

echo "=== L1-2 · stop-gate: milestone gate (spec-faithful plans)"
D="$WORK/l12"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
out=$(printf '{"session_id": "tsuite-e"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>"$WORK/l12.err"); rc=$?
ck 2 $rc "green with [pending] left prompts the boundary once (v3.14)"
grep -q "	M2	PASS" "$D/.ai_context/tasks/demo/gatelog" && ok "gatelog PASS row carries milestone id" || no "gatelog PASS row missing/wrong"
echo "$out" | grep -q 'claude-starter-gate: BLOCK' && ok "boundary prompt carries the stdout marker" || no "stdout marker missing on green prompt"
grep -q 'MILESTONE COMPLETE' "$WORK/l12.err" && ok "prompt reads as a continuation ask, not an error" || no "continuation prompt text missing"
grep -q 'never proceed past an unanswered question' "$WORK/l12.err" && ok "prompt protects pending human questions" || no "question-guard line missing"
out=$(printf '{"session_id": "tsuite-e"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "second green stop passes (one-shot consumed)"
grep -q "	M2	PAUSED	" "$D/.ai_context/tasks/demo/gatelog" && ok "explicit PAUSED row makes the park legible" || no "PAUSED row missing"
echo "$out" | grep -q 'paused at a milestone boundary' && ok "pause surfaces a systemMessage" || no "pause systemMessage missing"
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
ck 2 $? "green after yield prompts the boundary (PASS recorded, streak reset)"
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
ck 2 $rc "green boundary prompt fires even without the timeout binary"
echo "$err" | grep -q 'UNBOUNDED' && ok "missing timeout binary warned (no silent void)" || no "missing timeout stayed silent (F11)"
printf '{"session_id": "tsuite-tmo"}' | PATH="$SH" CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "gate still passes the second green stop without the timeout binary"
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
# in-flight deferral reads the Stop payload: an executor Claude Code lists
# as a running background task defers every stop (quiet, WAITING row) — its
# completion notification is the wake signal. Payload shape as CC builds it.
BT_EXEC='"background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"Execute milestone M2","agent_type":"executor"}]'
out=$(printf '{"session_id":"tsuite-sl1",%s}' "$BT_EXEC" | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "running background executor defers the verify (in-flight)"
grep -q "	M2	WAITING	executor in flight" "$D/.ai_context/tasks/demo/gatelog" && ok "WAITING row records the deferral" || no "WAITING row missing"
echo "$out" | grep -q 'executor in flight' && ok "deferral surfaces a systemMessage" || no "deferral systemMessage missing"
printf '{"session_id":"tsuite-sl1",%s}' "$BT_EXEC" | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "still running at the next stop => deferred again (no per-spawn cap)"
n_wait=$(grep -c "	M2	WAITING	" "$D/.ai_context/tasks/demo/gatelog")
[ "$n_wait" = 2 ] && ok "one WAITING row per deferred stop" || no "WAITING rows: want 2 got $n_wait"
# codex_desktop 2026-10-21 replay: a fresh executor row no stop has deferred
# on, but the executor already reported (nothing listed) => the verify runs.
# Spawnlog freshness never defers — background executors log a row per re-wake.
printf '%s\tM2\texecutor\n' "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$D/.ai_context/tasks/demo/spawnlog"
grep -v "	M2	WAITING	" "$D/.ai_context/tasks/demo/gatelog" > "$D/.ai_context/tasks/demo/gatelog.new" && mv "$D/.ai_context/tasks/demo/gatelog.new" "$D/.ai_context/tasks/demo/gatelog"
err=$(printf '%s' '{"session_id":"tsuite-sl1b","background_tasks":[]}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "finished executor + fresh spawn row => verify runs (no dark deferral)"
echo "$err" | grep -q 'no executor spawn' && no "false no-spawn accusation despite executor row" || ok "executor row suppresses the hint"
echo "$err" | grep -q 'escalate per the /task ladder' && ok "ladder guidance kept when spawn evidence exists" || no "ladder guidance missing"
# only a verifier and a shell running (the shell's description quotes the
# key, JSON-escaped) => not in flight
printf '%s' '{"session_id":"tsuite-sl1c","background_tasks":[{"id":"a2","type":"subagent","status":"running","description":"Light-verify M2","agent_type":"verifier"},{"id":"b1","type":"shell","status":"running","description":"grep \"agent_type\":\"executor\" log","command":"sleep 60"}]}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "running verifier/shell does not defer"
# no background_tasks field (older CC, format drift) => verify runs: loud, never dark
printf '{"session_id": "tsuite-sl1d"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "payload without background_tasks runs the verify (fails loud)"
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
grep -q 'spawn-log.sh\\" verifier' "$REPO/.claude/settings.json" && ok "verifier matcher wired (own class)" || no "verifier matcher missing"
python3 - "$REPO/.claude/settings.json" <<'PY' && ok "verifier matcher is a plain name and the crew regex no longer lists it" || no "verifier routing ambiguous (would double-log or catch final-verifier)"
import json, sys
ms = [h["matcher"] for h in json.load(open(sys.argv[1]))["hooks"]["SubagentStart"]]
sys.exit(0 if "verifier" in ms and not any("verifier" in m.split("|") for m in ms if m != "verifier") else 1)
PY
printf '{}' | CLAUDE_PROJECT_DIR="$D" bash "$SL" verifier
grep -q "	M2	verifier$" "$D/.ai_context/tasks/demo/spawnlog" && ok "verifier class lands in the spawnlog" || no "verifier row wrong"
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
  grep -qF '.ai_context/tasks/*/pair/.fp-*' "$D/.gitignore" && ok "sync appends the pair/.fp-* ignore (ADR-028 in-flight fingerprints)" || no "sync .gitignore appender missed pair/.fp-*"
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
  { [ -f "$D/.claude/agents/final-verifier.md" ] && [ -f "$D/scripts/task-profile.sh" ]; } && ok "v3.13 files (final-verifier, task-profile) land via sync" || no "final-verifier/task-profile missing after sync"
  # /number-check: the skill lands by sync; its DoD line is only suggested,
  # once (the installing sync), and never to a CLAUDE.md that names it.
  D7="$WORK/l14d"; mkdir -p "$D7/.ai_context"
  cp "$REPO/.ai_context/INDEX.md" "$D7/.ai_context/"
  printf '# p\n\n## Definition of done\n\n- tests pass\n' > "$D7/CLAUDE.md"
  out1=$("$REPO/sync-project.sh" "$D7" 2>&1)
  out2=$("$REPO/sync-project.sh" "$D7" 2>&1)
  [ -f "$D7/.claude/skills/number-check/SKILL.md" ] && ok "sync installs the number-check skill" || no "number-check skill not installed by sync"
  echo "$out1" | grep -q 'new skill /number-check installed' && ok "installing sync suggests the number-check DoD line" || no "number-check DoD suggestion missing on the installing sync"
  echo "$out2" | grep -q 'new skill /number-check installed' && no "number-check suggestion repeats on a later sync (nag)" || ok "number-check suggestion fires once (installing sync only)"
  grep -q 'number-check' "$D7/CLAUDE.md" && no "sync edited CLAUDE.md (must only suggest)" || ok "sync leaves CLAUDE.md untouched (suggestion only)"
  D8="$WORK/l14e"; mkdir -p "$D8/.ai_context"
  cp "$REPO/.ai_context/INDEX.md" "$D8/.ai_context/"
  printf '# p\n\n## Definition of done\n\n- Every reported number passed `/number-check`.\n' > "$D8/CLAUDE.md"
  out3=$("$REPO/sync-project.sh" "$D8" 2>&1)
  echo "$out3" | grep -q 'new skill /number-check installed' && no "number-check suggested to a CLAUDE.md that already names it" || ok "no number-check suggestion when CLAUDE.md already names it"
  echo "$out3" | grep -q 'logs verifier spawns as' && no "verifier-class suggestion on a stock settings.json" || ok "stock settings.json carries the verifier class (no suggestion)"
  sed -i.bak -e 's/"matcher": "verifier"/"matcher": "verifier-old"/' -e 's/spawn-log.sh\\" verifier/spawn-log.sh\\" other/' "$D8/.claude/settings.json" && rm -f "$D8/.claude/settings.json.bak"
  out4=$("$REPO/sync-project.sh" "$D8" 2>&1)
  echo "$out4" | grep -q 'logs verifier spawns as "other"' && ok "customized pre-class settings.json gets the verifier-matcher suggestion" || no "verifier-matcher suggestion missing for a customized settings.json"
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
# task SKILL.md has no size assertion since the pair-codex work (workshop
# ADR-028): the cap was lifted by the user; on-demand detail still belongs
# in reference.md / pair.md, so the pointer checks below stay.
[ -f "$REPO/.claude/skills/task/pair.md" ] && ok "task pair.md exists (on-demand pair-codex protocol)" || no "task pair.md missing"
grep -q 'pair.md' "$REPO/.claude/skills/task/SKILL.md" && ok "task body points at pair.md for pair-* profiles" || no "task body lost its pair.md pointer"
[ "$(grep -c 'pair.md' "$REPO/.claude/skills/task/SKILL.md")" -ge 7 ] && ok "task body points at pair.md from the verify, drift and final stages" || no "task body lacks the per-stage pair.md pointers"
for sec in '### No-verdict rule' '### §1 spec' '### §0.5 brief' '### §2 plan' '### §3.3 verification' '### §3.6 drift check' '### §5 final panel' '### `pair/ledger.md`'; do
  grep -qF "$sec" "$REPO/.claude/skills/task/pair.md" && ok "pair.md carries $sec" || no "pair.md missing $sec"
done
grep -qF '| stage | ref | source | seats | severity | claim | resolution |' "$REPO/.claude/skills/task/pair.md" && grep -q '`both` (each seat' "$REPO/.claude/skills/task/pair.md" && ok "pair ledger schema: source enum incl. both + seats column (cross-model catches countable)" || no "pair ledger schema lost source/seats"
grep -q '`noted: <why the plan stays>` — minor findings only' "$REPO/.claude/skills/task/pair.md" && ok "pair plan rulings offer noted for minors" || no "pair noted ruling missing"
grep -q 'High-stakes findings are the human' "$REPO/.claude/skills/task/pair.md" && [ "$(grep -c 'high-stakes: `open`' "$REPO/.claude/skills/task/pair.md")" -ge 2 ] && ok "high-stakes findings: never rejected by the orchestrator, at every reject site" || no "high-stakes rule missing or not wired to the reject sites"
sz=$(wc -c < "$REPO/.claude/skills/wrap/SKILL.md")
[ "$sz" -le 2560 ] && ok "wrap SKILL.md within 2.5 KB ($sz B — task machinery lives in reference.md)" || no "wrap SKILL.md bloated ($sz B > 2560)"
[ -f "$REPO/.claude/skills/wrap/reference.md" ] && ok "wrap reference.md exists (on-demand task close-out)" || no "wrap reference.md missing"
grep -q 'reference.md' "$REPO/.claude/skills/wrap/SKILL.md" && ok "wrap body points at the reference" || no "wrap body lost its reference pointer"
grep -qF 'duration_min,outcome,harness' "$REPO/.claude/skills/wrap/reference.md" && ok "wrap reference carries the scoreboard header (harness column)" || no "wrap reference missing the scoreboard header"
nc="$REPO/.claude/skills/number-check/SKILL.md"
{ [ "$(sed -n 1p "$nc" 2>/dev/null)" = '---' ] && grep -q '^name: number-check$' "$nc" && grep -q '^description: .' "$nc"; } && ok "number-check skill registers (name + description frontmatter)" || no "number-check skill missing or its frontmatter is broken"
if [ -f "$REPO/templates/CLAUDE.md.analysis" ]; then
  ref="$(grep -o 'number passed `/[a-z-]*`' "$REPO/templates/CLAUDE.md.analysis" | sed 's/.*`\/\(.*\)`/\1/' | head -1)"
  { [ -n "$ref" ] && [ -f "$REPO/.claude/skills/$ref/SKILL.md" ]; } && ok "analysis DoD points at a skill that exists (/$ref)" || no "analysis DoD names no existing skill (got '/$ref')"
else
  skp "analysis DoD → skill check (spawned project — template-repo only)"
fi
lenses="$(sed -n 's/^description:.*lens (\([^)]*\)).*/\1/p' "$REPO/.claude/agents/planner.md" | tr ',' '\n' | tr -d ' .' | grep -v '^$')"
miss=""; for l in $lenses; do grep -q "^- \*\*$l\*\* — " "$REPO/.claude/skills/task/reference.md" || miss="$miss $l"; done
{ [ -n "$lenses" ] && [ -z "$miss" ]; } && ok "every lens planner.md names is defined in task reference.md ($(echo $lenses | tr '\n' ' '))" || no "planner lenses without a definition:${miss:- none parsed}"
grep -q '^| 2 | fresh `executor` | .*premise' "$REPO/.claude/skills/task/SKILL.md" && grep -q 'premise it rested on' "$REPO/.claude/skills/task/SKILL.md" && ok "rung 2 carries rung 1's premise; failed rungs log their premise" || no "ladder lost the premise step (rung 2 / lessons line)"
grep -q 'exit 0 = vacuous' "$REPO/.claude/agents/plan-critic.md" && grep -q '126/127' "$REPO/.claude/agents/plan-critic.md" && ok "plan-critic observes fails-today (runs risk:low verifies)" || no "plan-critic lost the observed-red check"
grep -qF 'Read(./**/.env)' "$REPO/.claude/settings.json" && ok "nested .env read-deny present" || no "nested .env deny missing"
grep -qxF '**/.env' "$REPO/.gitignore" && ok "nested .env gitignored" || no "nested .env gitignore missing"
grep -q 'gate-cache' "$REPO/.gitignore" && ok "gate-cache gitignored (fingerprint-safe)" || no "gate-cache ignore missing"
grep -qF 'Read(./.secrets/**)' "$REPO/.claude/settings.json" && grep -qF 'Read(./**/.secrets/**)' "$REPO/.claude/settings.json" && ok "secrets-dir read-deny present (root + nested)" || no "secrets-dir read-deny missing"
grep -qxF '.secrets/*' "$REPO/.gitignore" && grep -qxF '!.secrets/.gitkeep' "$REPO/.gitignore" && ok "secrets-dir gitignored, placeholder excepted (contents-form)" || no "secrets-dir gitignore block wrong"
grep -qxF '*.pem' "$REPO/.gitignore" && grep -qxF 'id_rsa*' "$REPO/.gitignore" && ok "key-material gitignored (closes the read-deny asymmetry)" || no "pem/id_rsa gitignore missing"
[ -f "$REPO/.secrets/.gitkeep" ] && ok "seed ships .secrets/.gitkeep" || no "seed .secrets placeholder missing"

echo "=== L1-24 · SOP skills, verify template, NOTICE (v4)"
SK="$REPO/.claude/skills"
# A model-invocable skill: frontmatter opens line 1, exact name, a
# description inside the 1,536-char listing cut, and no invocation opt-out.
skill_fm() { # $1 = file, $2 = name
  local d; d="$(sed -n 's/^description: //p' "$1" 2>/dev/null | head -1)"
  [ "$(sed -n 1p "$1" 2>/dev/null)" = '---' ] && grep -q "^name: $2\$" "$1" && [ -n "$d" ] \
    && [ "${#d}" -le 1536 ] && ! grep -q 'disable-model-invocation' "$1"
}
f="$SK/prove/SKILL.md"
skill_fm "$f" prove && ok "prove skill registers (model-invocable, description ≤1,536 chars)" || no "prove skill missing or its frontmatter is broken"
{ grep -qF 'VERIFIED (L4|L5)' "$f" && grep -qF 'partly done' "$f" && grep -qF 'Watch it go red' "$f"; } && ok "prove: claim lines with levels, partly-done wording, observed red" || no "prove body lost its claim grammar, 'partly done' or 'Watch it go red'"
f="$SK/debug/SKILL.md"
skill_fm "$f" debug && ok "debug skill registers (model-invocable, description ≤1,536 chars)" || no "debug skill missing or its frontmatter is broken"
{ grep -qF 'Two failed fixes' "$f" && grep -qF '</dev/null' "$f" && grep -qF 'fails before and passes' "$f"; } && ok "debug: two-fix premise rule, stdin trap, before/after repro" || no "debug body lost the two-fix rule, the </dev/null trap or the before/after repro"
f="$SK/backtest-check/SKILL.md"
skill_fm "$f" backtest-check && ok "backtest-check skill registers (model-invocable, description ≤1,536 chars)" || no "backtest-check skill missing or its frontmatter is broken"
{ grep -q '^description: .*Only for backtests' "$f" && [ "$(grep -c '^[1-8]\. ' "$f")" = 8 ]; } && ok "backtest-check: scoped to backtests, exactly 8 numbered checks" || no "backtest-check lost its 'Only for backtests' scope or its 8 checks (got $(grep -c '^[1-8]\. ' "$f" 2>/dev/null))"
f="$SK/setup/verify-template.md"
{ [ -f "$f" ] && grep -q '^name: verify$' "$f" && ! grep -q 'disable-model-invocation' "$f" && grep -qF 'Proven:' "$f" && grep -qF 'before every commit' "$f"; } && ok "verify template: model-invocable 'verify' skill with a Proven: line" || no "setup/verify-template.md missing or not a model-invocable verify skill with Proven:"
{ grep -qF 'claude-starter third-party notices' "$REPO/NOTICE" && grep -qF 'Superpowers' "$REPO/NOTICE" && grep -qF 'Compound Engineering' "$REPO/NOTICE" \
  && grep -qF 'pstack' "$REPO/NOTICE" && grep -qF 'MIT' "$REPO/NOTICE"; } 2>/dev/null && ok "NOTICE carries the marker and the three MIT notices" || no "NOTICE missing, or lacks its marker or a project's MIT notice"
miss=""
for f in prove/SKILL.md debug/SKILL.md setup/verify-template.md; do
  tail -1 "$SK/$f" 2>/dev/null | grep -q '^<!-- Source: adapted from .* see NOTICE\. -->$' || miss="$miss $f"
done
tail -1 "$SK/backtest-check/SKILL.md" 2>/dev/null | grep -q '^<!-- Rules from the claude-starter fleet failure taxonomy' || miss="$miss backtest-check/SKILL.md"
[ -z "$miss" ] && ok "adapted skills end with a Source line citing NOTICE; backtest-check cites its own origin" || no "source line missing or wrong:$miss"
f="$SK/number-check/SKILL.md"
{ grep -q '^description: .*Eight questions' "$f" && grep -qF 'Does an outside source agree?' "$f" && grep -qF 'Is it possible' "$f"; } && ok "number-check: eight questions incl. hard range and outside-source cross-check" || no "number-check lost Eight questions, the Q3 range or the Q8 cross-check"

echo "=== L1-7 · stop-gate PASS-cache (git-fingerprinted)"
D="$WORK/l17"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: \`true\`\n' > "$D/CLAUDE.md"
printf '.ai_context/tasks/*/.gate-cache\n' > "$D/.gitignore"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" commit -qm base
git -C "$D" checkout -qb task/demo
printf '{"session_id": "tsuite-c1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "green run 1 prompts the boundary (verify ran, cache written)"
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
# (The green boundary prompt is rc 2 too, so distinguish via stderr text.)
write_plan "$D/.ai_context/tasks/demo/plan.md" 'mkdir -p scratch-dir && rm -rf scratch-dir'
err=$(printf '{"session_id": "tsuite-f7"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "relative rm -rf verify runs green (boundary prompt, not a refusal)"
echo "$err" | grep -q 'GATE REFUSED' && no "relative rm -rf falsely refused (matcher false positive)" || ok "no forbidden-verify false positive"
echo "$err" | grep -q 'MILESTONE COMPLETE' && ok "verify actually ran and passed" || no "green boundary prompt missing"

# F9: log-always / interrupt-once — a second distinct dark state in the
# SAME session still reaches the audit trail (one interrupt, two rows).
D="$WORK/l110f9"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
printf '{"session_id": "tsuite-f9"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "dark state 1 (missing plan) interrupts"
printf 'not a plan\n' > "$D/.ai_context/tasks/demo/plan.md"
printf '{"session_id": "tsuite-f9"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "dark state 2 (heading-less plan) gets its OWN interrupt (per-class, v3.14)"
printf '{"session_id": "tsuite-f9"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "same dark-state class yields on repeat (marker spent)"
n_int=$(grep -c "	INTEGRITY	" "$D/.ai_context/tasks/demo/gatelog")
[ "$n_int" = 3 ] && ok "every dark-state stop left an INTEGRITY row (log-always)" || no "INTEGRITY rows: want 3 got $n_int — a dark state went unrecorded"

D="$WORK/l110b"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
git -C "$D" init -q -b main 2>/dev/null || { git -C "$D" init -q && git -C "$D" checkout -qb main; }
git -C "$D" add -A && git -C "$D" commit -qm base
printf '{"session_id": "tsuite-i8"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "active task on main blocks (integrity)"
git -C "$D" checkout -qb task/demo
err=$(printf '{"session_id": "tsuite-i9"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "task branch arms the gate (boundary prompt, not an integrity block)"
grep -q "	M2	PASS" "$D/.ai_context/tasks/demo/gatelog" && ok "verify ran and passed on the task/ branch" || no "no PASS row on task/ branch"

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
[ "$(grep -c '' "$D/.ai_context/tasks/demo/gatelog")" -eq "$((zn + 1))" ] && ok "non-git final verify re-runs; earlier UNARMED is not duplicated" || no "non-git sweep evidence incorrect"
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


echo "=== L1-12b · completion verifies the current tree and command"
D="$WORK/l112d"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# configured\n' > "$D/CLAUDE.md"
printf '.ai_context/tasks/*/.gate-cache\n' > "$D/.gitignore"
echo demo > "$D/.ai_context/tasks/CURRENT"
printf 'good\n' > "$D/payload.txt"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: final freshness
## M1: final [in_progress]
- verify: `test "$(cat payload.txt)" = good`
- risk: low
PEOF
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" commit -qm base
git -C "$D" checkout -qb task/demo
printf '{"session_id":"tsuite-final-fp"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "final fixture records a real in-progress PASS"
sed -i 's/\[in_progress\]/[done]/' "$D/.ai_context/tasks/demo/plan.md"
printf 'evil\n' > "$D/payload.txt"
printf '{"session_id":"tsuite-final-fp"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "all-done Stop rejects changed code despite historical PASS"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 2 $? "explicit sweep rejects changed code despite historical PASS"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 2 $? "explicit sweep stays red on repeat"
[ ! -f "$D/.ai_context/tasks/demo/.gate-cache" ] && ok "final failure clears PASS-cache" || no "final failure left stale cache"
printf 'good\n' > "$D/payload.txt"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 0 $? "repaired final verify passes"
final_n=$(grep -c PASS "$D/.ai_context/tasks/demo/gatelog")
printf '{"session_id":"tsuite-final-fp"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "unchanged all-done Stop passes"
[ "$(grep -c PASS "$D/.ai_context/tasks/demo/gatelog")" -eq "$final_n" ] && ok "unchanged final tree uses fingerprint cache" || no "final cache missed"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 0 $? "explicit sweep revalidates a cached final PASS"
[ "$(grep -c PASS "$D/.ai_context/tasks/demo/gatelog")" -eq "$((final_n + 1))" ] && ok "explicit sweep executes verify even when cached" || no "explicit sweep trusted cached PASS"
# Even an ignored plan must not hide a changed verify command from the cache.
git -C "$D" rm --cached -q .ai_context/tasks/demo/plan.md
printf '.ai_context/tasks/*/plan.md\n' >> "$D/.gitignore"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
sed -i 's/^- verify:.*/- verify: `false`/' "$D/.ai_context/tasks/demo/plan.md"
printf '{"session_id":"tsuite-final-command"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "same milestone with changed ignored verify cannot use old PASS"
sed -i 's/^- verify:.*/- verify: `touch forbidden-ran \&\& git push origin main`/' "$D/.ai_context/tasks/demo/plan.md"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 2 $? "prior PASS cannot hide a forbidden final verify"
[ ! -f "$D/forbidden-ran" ] && ok "forbidden final verify was never executed" || no "forbidden final verify ran"
sed -i '/^- verify:/d' "$D/.ai_context/tasks/demo/plan.md"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 2 $? "removing final verify cannot turn a historical PASS into completion"

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
out=$(bgp 'rm -f -r /var/scratch' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "split-flag absolute rm -rf downgraded to ask" || no "split-flag absolute rm not asked"
out=$(bgp 'rm -r -f build/' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "relative split-flag rm passes silently" || no "relative split-flag rm flagged"
out=$(bgp 'rm -rf /var/scratch' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "absolute-path rm -rf downgraded to ask" || no "absolute rm -rf not asked"
out=$(bgp 'rm -rf build/' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "relative rm -rf passes silently" || no "relative rm -rf flagged"
# v3.14.3: with the settings.json rm rule gone (ADR-023), the hook is the only
# rm tier — home-relative and parent-traversal spellings join the ask tier.
out=$(bgp 'rm -rf ~/projects/x' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "home-relative rm -rf (~/) asks (v3.14.3)" || no "home-relative rm -rf passes silently (guard hole)"
out=$(bgp 'rm -rf $HOME/projects/x' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "\$HOME/ rm -rf asks (v3.14.3)" || no "\$HOME/ rm -rf passes silently (guard hole)"
out=$(bgp 'rm -rf ../sibling' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "parent-traversal rm -rf (..) asks (v3.14.3)" || no ".. rm -rf passes silently (guard hole)"
out=$(bgp 'rm -rf ./build' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "dot-relative rm -rf still passes silently" || no "./ rm -rf flagged (false positive)"
( . "$REPO/.claude/hooks/guard-patterns.sh"; guard_forbidden_verify "rm -rf ~/x" ) && ok "stop-gate refuses a ~/ rm -rf verify (shared matcher, v3.14.3)" || no "stop-gate lets a ~/ rm -rf verify through"
# v3.14.4: the ask tier reads a probe — heredoc bodies dropped, the project's own
# tree scrubbed like the scratchpad. The deny tier still reads the full text.
# The fixture dir lives under /tmp, which v3.14.5 exempts wholesale below one
# level — so the project-tree cases use a fake root outside /tmp (the hook only
# matches the path textually; it need not exist).
PD=/var/lib/l113-proj
out=$(bgp "cat > notes.md <<'EOF'\nsecrets live in .env, never here\nEOF" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "heredoc prose mentioning .env passes silently (v3.14.4)" || no "heredoc prose .env still asks"
out=$(bgp "cat > plan.md <<'EOF'\n- verify: rm -rf /var/x && make\nEOF" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "heredoc prose with an absolute rm -rf passes silently (v3.14.4)" || no "heredoc prose rm -rf still asks"
out=$(bgp "cat > .env <<'EOF'\nA=1\nEOF" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok ".env on the command line beside a heredoc still asks" || no "heredoc strip swallowed a command-line .env"
out=$(bgp "cat > notes.md <<'EOF'\nunterminated body mentions .env" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "unterminated heredoc keeps the full text (fails toward asking)" || no "unterminated heredoc exempted"
bgp "bash <<'EOF'\nsudo ls\nEOF" | CLAUDE_PROJECT_DIR="$D" bash "$BG" >/dev/null 2>&1
ck 2 $? "deny tier still reads heredoc bodies (sudo inside bash <<EOF denied)"
out=$(bgp "rm -rf $PD/build" | CLAUDE_PROJECT_DIR="$PD" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "absolute path inside the project tree passes silently (v3.14.4)" || no "project-tree absolute rm -rf still asks"
out=$(bgp "rm -rf $PD" | CLAUDE_PROJECT_DIR="$PD" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "the project root itself still asks" || no "project root rm -rf exempted"
out=$(bgp "rm -rf ${PD}x/build" | CLAUDE_PROJECT_DIR="$PD" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "project-dir lookalike prefix still asks" || no "lookalike prefix exempted"
out=$(bgp "rm -rf $PD/../other" | CLAUDE_PROJECT_DIR="$PD" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "traversal out of the project tree still asks" || no "project-tree traversal exempted"
out=$(bgp "rm -rf $PD/build /var/other" | CLAUDE_PROJECT_DIR="$PD" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "second target outside the tree still asks" || no "tree scrub swallowed a second target"
out=$(bgp "rm -rf $PD/build" | CLAUDE_PROJECT_DIR="." bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "no project-tree exemption without an absolute CLAUDE_PROJECT_DIR" || no "relative ROOT produced an exemption"
out=$(bgp "python3 - <<'PY'\nimport os; os.system('rm -rf /var/q')\nPY" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "executed heredoc body is outside the ask tier (documented boundary, same class as bash -c)" || no "heredoc strip changed for executed heredocs — update the boundary note"
# Session-scratchpad exemption (v3.14.1): the harness's own disposable tree
# is not a decision worth a click; every other absolute target still asks.
SP='/tmp/claude-1000/-code-demo/9f2c4a1b-0000-4000-8000-000000000000/scratchpad'
out=$(bgp "rm -rf $SP/mirror" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "rm -rf inside the session scratchpad passes silently" || no "scratchpad rm -rf still asks"
out=$(bgp "rm -rf $SP" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "rm -rf of the scratchpad root passes silently" || no "scratchpad root rm -rf still asks"
out=$(bgp "rm -rf \"$SP/mirror\"" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "quoted scratchpad path passes silently" || no "quoted scratchpad rm -rf still asks"
out=$(bgp "rm -rf $SP/../../../../etc" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "traversal out of the scratchpad still asks" || no "scratchpad traversal exempted (guard hole)"
out=$(bgp "rm -rf $SP/x /etc/nginx" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "second absolute target beside a scratchpad path still asks" || no "scrub swallowed a non-scratchpad target"
out=$(bgp "rm -rf $SP/x;rm -rf /etc/nginx" | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "chained absolute rm -rf after a scratchpad path still asks" || no "scrub swallowed a chained rm -rf"
out=$(bgp 'rm -rf /tmp/claude-1000/scratchpad' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "shallow /tmp/claude-* lookalike passes (v3.14.5: any /tmp/<name> does)" || no "/tmp/<name> lookalike still asks"
# v3.14.5 (ADR-026): /tmp/<name> is disposable by definition; the wholesale wipe still asks.
out=$(bgp 'rm -rf /tmp/zzac5' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "rm -rf /tmp/<name> passes silently (v3.14.5)" || no "/tmp/<name> still asks"
out=$(bgp 'rm -rf /tmp/zzac5/sub dir' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "rm -rf /tmp/<name>/<sub> passes silently" || no "/tmp/<name>/<sub> still asks"
out=$(bgp 'rm -rf /tmp' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "rm -rf /tmp itself still asks" || no "/tmp itself exempted (wholesale wipe)"
out=$(bgp 'rm -rf /tmp/' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "rm -rf /tmp/ still asks" || no "/tmp/ exempted (wholesale wipe)"
out=$(bgp 'rm -rf /tmp/*' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "rm -rf /tmp/* still asks" || no "/tmp/* exempted (wholesale wipe)"
out=$(bgp 'rm -rf /tmp/foo/../x' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "traversal under /tmp/<name> still asks" || no "/tmp traversal exempted"
out=$(bgp 'rm -rf /tmp/foo /var/x' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -q '"permissionDecision":"ask"'; } && ok "second target outside /tmp beside a /tmp/<name> still asks" || no "/tmp scrub swallowed a second target"
out=$(bgp 'rm -rf /tmp/claude-1000' | CLAUDE_PROJECT_DIR="$D" bash "$BG" 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "the whole /tmp/claude-<uid> tree passes (documented edge, ADR-026)" || no "/tmp/claude-<uid> handling changed — update the edge note"
( . "$REPO/.claude/hooks/guard-patterns.sh"; guard_forbidden_verify "rm -rf /tmp/foo" ) && ok "stop-gate still refuses a /tmp/<name> rm -rf verify (exemption not shared)" || no "stop-gate inherited the /tmp exemption"
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
# The scratchpad exemption is bash-guard-only: verifies execute unattended at
# turn end, so the stop-gate denylist keeps refusing scratchpad deletes.
( . "$REPO/.claude/hooks/guard-patterns.sh"; guard_forbidden_verify "rm -rf $SP/build" ) && ok "stop-gate still refuses a scratchpad rm -rf verify (exemption not shared)" || no "stop-gate inherited the scratchpad exemption"
if [ -f "$REPO/sync-project.sh" ]; then
  grep -q '^copy_if_missing \.claude/hooks/guard-patterns\.sh$' "$REPO/sync-project.sh" && grep -q '^stock_update \.claude/hooks/guard-patterns\.sh$' "$REPO/sync-project.sh" && ok "sync ships guard-patterns.sh (add + stock-update)" || no "sync does not ship guard-patterns.sh"
else
  skp "sync ships guard-patterns.sh (spawned project — template-repo only)"
fi
grep -q '"PreToolUse"' "$REPO/.claude/settings.json" && grep -q 'bash-guard\.sh' "$REPO/.claude/settings.json" && ok "bash-guard wired in settings.json" || no "bash-guard wiring missing"
grep -qF 'Edit(./.ai_context/tasks/**/gatelog)' "$REPO/.claude/settings.json" && ok "gatelog Edit-deny present (covers all file-editing tools)" || no "gatelog deny entry missing"
grep -qF 'Write(./.ai_context/tasks/**/' "$REPO/.claude/settings.json" && no "dead Write() deny rule present — CC matches only Edit(path) for file edits and warns every session (F25)" || ok "no dead Write() deny rules (F25)"
grep -qF '"Bash(git push --force:*)"' "$REPO/.claude/settings.json" && ok "declarative force-push deny present" || no "force-push deny entry missing"
grep -qF '"ask"' "$REPO/.claude/settings.json" && grep -qF '"Bash(git push:*)"' "$REPO/.claude/settings.json" && ok "ask tier present (push/reset/clean/sudo)" || no "ask tier missing"
for r in 'Bash(rm -rf ~/*)' 'Bash(rm -rf $HOME/*)' 'Bash(rm -rf ../*)'; do grep -qF "\"$r\"" "$REPO/.claude/settings.json" && ok "declarative ask rule present: $r (v3.14.3 — prompts even under bypass, where hook asks are dropped)" || no "declarative ask rule missing: $r"; done
grep -qF '"Bash(rm -rf:*)"' "$REPO/.claude/settings.json" && no "rm -rf ask rule back in settings.json — declarative ask rules prompt in every mode incl. bypass, per subcommand, and no hook exemption reaches them (v3.14.2)" || ok "no declarative rm -rf ask rule: bash-guard is the single rm tier (v3.14.2)"

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
err=$(printf '{"session_id": "tsuite-w2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "task/ branch arms the gate (boundary prompt, fresh session)"
grep -q "	M2	PASS" "$D/.ai_context/tasks/demo/gatelog" && ok "verify ran and passed on the task/ branch" || no "no PASS row on task/ branch"

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
D4="$WORK/l117d"; mkdir -p "$D4/.ai_context/tasks/mv"
printf '# Plan: mv\n\n## M1: a [done]\n- verify: `x`\n\n## M2: b [done]\n- verify: `x`\n\n## M3: c [done]\n- verify: `x`\n\n## M4: d [done]\n- verify: `x`\n' > "$D4/.ai_context/tasks/mv/plan.md"
{ printf '2026-07-10T10:00:00\tM1\tFAIL\tcheck --all\n2026-07-10T10:05:00\tM1\tPASS\tcheck --year 2014\n'
  printf '2026-07-10T11:00:00\tM2\tFAIL\tpytest\n2026-07-10T11:05:00\tM2\tPASS\tpytest\n'
  printf '2026-07-10T12:00:00\tM3\tPASS\ta\n2026-07-10T12:05:00\tM3\tPASS\tb\n'
  printf '2026-07-10T13:00:00\tM4\tFAIL\tgen | wc -l\n2026-07-10T13:05:00\tM4\tPASS\tgen | head\n'; } > "$D4/.ai_context/tasks/mv/gatelog"
out5=$(bash "$REPO/scripts/harness-report.sh" "$D4")
echo "$out5" | grep -q 'verify changed after FAIL: tasks/mv/ M1 — FAIL ran `check --all`, PASS ran `check --year 2014`' && ok "verify narrowed after a FAIL surfaced with both commands" || no "verify change after FAIL not surfaced"
echo "$out5" | grep -q 'verify changed after FAIL: tasks/mv/ M2' && no "same-command repair misflagged as a moved gate" || ok "fix-the-code repair (same command) not flagged"
echo "$out5" | grep -q 'verify changed after FAIL: tasks/mv/ M3' && no "change without a prior FAIL misflagged" || ok "command change with no FAIL before it not flagged"
echo "$out5" | grep -q 'verify changed after FAIL: tasks/mv/ M4 — FAIL ran `gen / wc -l`, PASS ran `gen / head`' && ok "pipes inside commands survive the report stream" || no "piped verify command broke the VC row"
D5="$WORK/l117e"; T5="$D5/.ai_context/tasks"; mkdir -p "$T5/dv" "$T5/legacy" "$T5/small" "$T5/nosl" "$T5/pr/pair"
mkplan() { # $1 file, $2 profile, $3 size, then "id status risk" triples
  local f="$1" p="$2" z="$3"; shift 3
  printf '# Plan: x\n<!-- profile: %s ; size: %s -->\n' "$p" "$z" > "$f"
  while [ $# -gt 0 ]; do printf '\n## %s: t [%s]\n- verify: `true`\n- risk: %s\n' "$1" "$2" "$3" >> "$f"; shift 3; done
}
mkplan "$T5/dv/plan.md" opus-tier M M1 "done" med M2 "done" high M3 "done" low M4 pending med
printf 'x\t-\tother\nx\tM1\texecutor\nx\tM1\tverifier\nx\tM2\texecutor\nx\tM2\tother\nx\tM3\texecutor\n' > "$T5/dv/spawnlog"
mkplan "$T5/legacy/plan.md" opus-tier L M1 "done" med M2 "done" med
printf 'x\t-\tother\nx\tM1\texecutor\nx\tM1\tother\nx\tM2\texecutor\n' > "$T5/legacy/spawnlog"
mkplan "$T5/small/plan.md" opus-tier S M1 "done" high
printf 'x\t-\tother\n' > "$T5/small/spawnlog"
mkplan "$T5/nosl/plan.md" opus-tier M M1 "done" high
mkplan "$T5/pr/plan.md" pair-codex M M1 "done" med M2 "done" high M3 "done" med
printf 'x\t-\tother\nx\tM1\texecutor\nx\tM2\texecutor\nx\tM3\texecutor\nx\t-\tverifier\n' > "$T5/pr/spawnlog"
printf 'x\t1\treset\tverifier\tM1\nx\t1\tstart\tverifier\tM1\nx\t2\tstart\tverifier\tM2\n' > "$T5/pr/pair/runlog"
out6=$(bash "$REPO/scripts/harness-report.sh" "$D5")
echo "$out6" | grep -q 'verification depth gap: tasks/dv/ — 1 of 2 \[done\] risk:med/high milestones had no verifier spawn while in progress (M2)$' && ok "depth gap: high milestone with only a non-verifier spawn flagged; low and pending ignored" || no "depth gap (verifier class) wrong"
echo "$out6" | grep -q 'verification depth gap: tasks/legacy/ — 1 of 2 .*(M2)$' && ok "depth gap: pre-class spawnlogs count 'other' as the verifier seat" || no "depth gap (legacy spawnlog) wrong"
echo "$out6" | grep -q 'depth gap: tasks/small/' && no "S task flagged (S has no verifier step)" || ok "depth gap: S tasks exempt"
echo "$out6" | grep -q 'depth gap: tasks/nosl/' && no "task without a spawnlog flagged (SubagentStart may never fire)" || ok "depth gap: no spawnlog = Claude seat unjudged"
echo "$out6" | grep -q 'verification depth gap: tasks/pr/ — 2 of 3 .*(M2 M3)$' && ok "depth gap: pair-* reads the runlog for med, both seats for high" || no "depth gap (pair) wrong"
csv=$(bash "$REPO/scripts/harness-report.sh" --csv "$D5")
echo "$csv" | grep -q 'depth gap' && no "--csv polluted by the depth-gap line" || ok "--csv untouched by the depth-gap line"

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

echo "=== L1-18b · box trees name every shipped agent, skill file and hook"
if [ -f "$REPO/MIGRATION.md" ] && [ -f "$REPO/README.zh-TW.md" ]; then
  for pair in "README.md|## What's in the box" "README.zh-TW.md|## 盒子裡有什麼"; do
    f="${pair%%|*}"; h="${pair#*|}"
    tree="$(awk -v h="$h" '$0==h {f=1; next} f && /^```/ {if (++n==2) exit; next} f && n==1' "$REPO/$f")"
    [ -n "$tree" ] || { no "$f: no box tree under '$h'"; continue; }
    miss=""
    for a in "$REPO"/.claude/agents/*.md; do
      n="$(basename "$a" .md)"; echo "$tree" | grep -qE "(^|[^a-z-])$n([^a-z-]|\$)" || miss="$miss $n"
    done
    for k in "$REPO"/.claude/skills/*/*.md; do
      n="$(basename "$(dirname "$k")")/$(basename "$k")"; echo "$tree" | grep -qF "$n" || miss="$miss $n"
    done
    for k in "$REPO"/.claude/hooks/*; do
      n="$(basename "$k")"; echo "$tree" | grep -qF "$n" || miss="$miss $n"
    done
    [ -z "$miss" ] && ok "$f box tree names every agent, skill file and hook" || no "$f box tree is missing:$miss"
  done
else
  skp "box-tree parity (spawned project — template-repo only)"
fi

echo "=== L1-18c · TUTORIAL message table quotes strings the harness really prints"
if [ -f "$REPO/TUTORIAL.md" ] && [ -f "$REPO/TUTORIAL.zh-TW.md" ]; then
  msg_rows() { awk -v h="$2" 'index($0, h)==1 {f=1; next} /^## 8\./ {f=0} f && /^\| / && !/^\|---/ && ++n>1' "$1"; }
  frags="$(msg_rows "$REPO/TUTORIAL.md" '**What each message means.**' | cut -d'|' -f2 | grep -o '`[^`]*`' | tr -d '`' \
           | sed -e 's/…/\n/g' -e 's/ n /\n/g' | sed 's/^ *//; s/ *$//' | awk 'length >= 6')"
  miss=""; nf=0
  while IFS= read -r fr; do
    [ -n "$fr" ] || continue; nf=$((nf+1))
    grep -qF -- "$fr" "$REPO"/.claude/hooks/*.sh "$REPO"/scripts/*.sh "$REPO"/.claude/skills/task/*.md "$REPO/.claude/settings.json" || miss="$miss [$fr]"
  done <<< "$frags"
  { [ "$nf" -ge 20 ] && [ -z "$miss" ]; } && ok "every quoted message fragment exists in the hooks/scripts ($nf fragments)" || no "TUTORIAL quotes messages the harness does not print:${miss:- (only $nf fragments parsed)}"
  ne="$(msg_rows "$REPO/TUTORIAL.md" '**What each message means.**' | wc -l)"
  nz="$(msg_rows "$REPO/TUTORIAL.zh-TW.md" '**每種訊息代表什麼。**' | wc -l)"
  { [ "$ne" -gt 0 ] && [ "$ne" = "$nz" ]; } && ok "zh-TW message table has the same $ne rows" || no "message tables differ: EN $ne rows, zh-TW $nz"
else
  skp "TUTORIAL message table (spawned project — template-repo only)"
fi

echo "=== L1-19 · task legibility: STATUS.md view + statusline (v3.12)"
TS="$REPO/scripts/task-status.sh"
TSL="$REPO/scripts/task-statusline.sh"
D="$WORK/l119"; mkdir -p "$D/.ai_context/tasks/lg" "$D/scripts"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo lg > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/lg/plan.md" <<'EOF'
# Plan: legibility fixture
<!-- profile: opus-tier ; size: M -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: groundwork [done]
- verify: `true`
- risk: low
- demo: run the tool, see the usage line

## M2: current [in_progress]
- verify: `true`
- risk: med
- demo: run the tool on a fixture, see exit 1 + offenders

## M3: future [pending]
- verify: `false`
- risk: low
EOF
printf '# Spec\n## Assumptions\n- [ASSUMED: fixture assumption]\n' > "$D/.ai_context/tasks/lg/spec.md"
bash "$TS" "$D/.ai_context/tasks/lg"
ck 0 $? "task-status.sh exits 0 on a well-formed task dir"
ST="$D/.ai_context/tasks/lg/STATUS.md"
[ -f "$ST" ] && ok "STATUS.md created" || no "STATUS.md missing"
grep -q 'M2 (2/3)' "$ST" && ok "position names the armed milestone" || no "position line wrong"
grep -q 'mermaid' "$ST" && ok "mermaid map present" || no "mermaid map missing"
grep -qF 'run the tool on a fixture' "$ST" && ok "demo promises rendered" || no "demo promises missing"
grep -qF '[ASSUMED: fixture assumption]' "$ST" && ok "ASSUMED ledger mirrored from spec" || no "ASSUMED ledger missing"
grep -qF 'unwritten — orchestrator' "$ST" && ok "fresh view carries the architecture stub" || no "architecture stub missing"
# model-owned tail survives regeneration; machine region tracks transitions
awk '/status:machine:end/{print; print "## Architecture"; print ""; print "ARCH-KEEP line"; exit} {print}' "$ST" > "$ST.tmp" && mv "$ST.tmp" "$ST"
sed -i.bak 's/## M2: current \[in_progress\]/## M2: current [done]/; s/## M3: future \[pending\]/## M3: future [in_progress]/' "$D/.ai_context/tasks/lg/plan.md" && rm -f "$D/.ai_context/tasks/lg/plan.md.bak"
bash "$TS" "$D/.ai_context/tasks/lg"
grep -qF 'ARCH-KEEP line' "$ST" && ok "model-owned tail survives regeneration" || no "regeneration ate the model section"
grep -q 'M3 (3/3)' "$ST" && ok "machine region tracks the transition" || no "machine region stale after transition"
grep -qF 'unwritten — orchestrator' "$ST" && no "stub resurrected over model content" || ok "stub gone once the model wrote"
# stop-gate integration: PASS captures .last-verify, refreshes the view, nags once
sed -i.bak 's/## M2: current \[done\]/## M2: current [in_progress]/; s/## M3: future \[in_progress\]/## M3: future [pending]/' "$D/.ai_context/tasks/lg/plan.md" && rm -f "$D/.ai_context/tasks/lg/plan.md.bak"
cp "$TS" "$D/scripts/task-status.sh"
rm -f "$ST"
printf '{"session_id": "tsuite-lg"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1; rc=$?
ck 2 $rc "green verify prompts the boundary with the renderer installed"
[ -f "$D/.ai_context/tasks/lg/.last-verify" ] && ok "PASS captured .last-verify" || no ".last-verify missing"
[ -f "$ST" ] && ok "PASS regenerated STATUS.md" || no "gate did not refresh the view"
# The nag waits for the first PASSING green stop — an exit-2 stop discards
# stdout, so nagging there would burn the marker on an unseen message.
out=$(printf '{"session_id": "tsuite-lg"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "second green stop passes with the renderer installed"
echo "$out" | grep -q 'Architecture is still the stub' && ok "stub nag fired on the passing stop (systemMessage)" || no "stub nag missing"
out=$(printf '{"session_id": "tsuite-lg"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null)
echo "$out" | grep -q 'Architecture is still the stub' && no "stub nag repeated in-session" || ok "stub nag is once per session"
# statusline: position line when a task is armed, silence otherwise
sl=$(printf '{"current_dir":"%s"}' "$D" | bash "$TSL")
echo "$sl" | grep -q 'lg ▶ 2/3' && ok "statusline shows slug + position ($sl)" || no "statusline wrong: '$sl'"
sl=$(printf '{}' | CLAUDE_PROJECT_DIR="$WORK" bash "$TSL")
[ -z "$sl" ] && ok "no task → empty statusline" || no "statusline noisy without a task: '$sl'"
# the view never enters git or the fingerprint (gate-cache precedent)
grep -qF '.ai_context/tasks/*/STATUS.md' "$REPO/.gitignore" && ok "STATUS.md gitignored (fingerprint-safe)" || no "STATUS.md ignore missing"
grep -qF '.ai_context/tasks/*/.last-verify' "$REPO/.gitignore" && ok ".last-verify gitignored" || no ".last-verify ignore missing"
grep -qF '.ai_context/tasks/*/pair/.fp-*' "$REPO/.gitignore" && ok "pair/.fp-* gitignored (in-flight fingerprints never memory)" || no "pair/.fp-* ignore missing"
# prose ↔ mechanism links (README §Prose → mechanism discipline)
grep -qF -- '- demo:' "$REPO/.claude/skills/task/SKILL.md" && ok "SKILL.md carries the demo-line plan contract" || no "SKILL.md lost the demo line"
grep -qF 'STATUS.md' "$REPO/.claude/skills/task/SKILL.md" && ok "SKILL.md names the STATUS.md duty" || no "SKILL.md lost STATUS.md"
grep -qF 'Kickoff brief' "$REPO/.claude/skills/task/reference.md" && ok "reference.md carries the kickoff-brief format" || no "kickoff-brief section missing"
grep -qF -- '- demo:' "$REPO/.claude/agents/executor.md" && ok "executor contract demands the demo" || no "executor lost the demo duty"
grep -qF 'ASSUMED' "$REPO/.claude/agents/verifier.md" && ok "verifier drift mode audits the ASSUMED ledger" || no "verifier lost the intent lens"
grep -qF 'task-status.sh' "$REPO/.claude/hooks/session-start.sh" && ok "session-start refreshes the view on resume" || no "session-start refresh missing"
# CJK titles must truncate on character boundaries — a byte-based cut
# leaves invalid UTF-8 inside mermaid labels (found live on stock_AGI).
mkdir -p "$D/.ai_context/tasks/cjk"
cat > "$D/.ai_context/tasks/cjk/plan.md" <<'EOF'
# Plan: 中文截斷
<!-- profile: fable-tier ; size: S -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: 里程碑中文標題超長需要截斷測試甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥 [in_progress]
- verify: `true`
- risk: low
EOF
bash "$TS" "$D/.ai_context/tasks/cjk"
if command -v iconv >/dev/null 2>&1; then
  iconv -f UTF-8 -t UTF-8 "$D/.ai_context/tasks/cjk/STATUS.md" >/dev/null 2>&1 && ok "CJK truncation keeps STATUS.md valid UTF-8" || no "CJK title truncated mid-character (invalid UTF-8 in view)"
  echo cjk > "$D/.ai_context/tasks/CURRENT"
  printf '{"current_dir":"%s"}' "$D" | bash "$TSL" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && ok "CJK truncation keeps statusline valid UTF-8" || no "statusline CJK cut mid-character"
  echo lg > "$D/.ai_context/tasks/CURRENT"
else
  skp "iconv absent — CJK truncation validity unchecked"
fi
# sync-project.sh manifest completeness: every shipped mechanism file must
# be named there, or spawned-then-synced projects silently miss additions
# (exactly how the v3.12 scripts were first forgotten). Every skill file
# counts (v4: setup/verify-template.md), and NOTICE ships with them; a
# whole-line match, since a bare substring hits comments too.
miss=""
for f in $(cd "$REPO" && ls scripts/*.sh .claude/hooks/*.sh .claude/agents/*.md .claude/skills/*/*.md NOTICE .claude/gitleaks.toml 2>/dev/null); do
  grep -qxF "copy_if_missing $f" "$REPO/sync-project.sh" || miss="$miss $f"
done
[ -z "$miss" ] && ok "sync-project.sh manifest covers every mechanism file" || no "sync-project.sh manifest missing:$miss"

echo "=== L1-20 · mixed-judge profile: task-profile.sh (v3.13)"
D="$WORK/l120"; mkdir -p "$D/.claude/agents" "$D/scripts" "$D/.ai_context/tasks/pdemo"
cp "$REPO"/.claude/agents/*.md "$D/.claude/agents/"
cp "$REPO/scripts/task-profile.sh" "$D/scripts/"
tp_before=$(cat "$D"/.claude/agents/*.md | md5sum)
( cd "$D" && bash scripts/task-profile.sh mixed-judge >/dev/null 2>&1 )
{ grep -q '^model: fable$' "$D/.claude/agents/planner.md" && grep -q '^model: fable$' "$D/.claude/agents/final-verifier.md" && grep -q '^model: fable$' "$D/.claude/agents/scout.md"; } \
  && ok "mixed-judge pins judgment agents to fable" || no "mixed-judge fable pins missing"
{ grep -q '^model: opus$' "$D/.claude/agents/executor.md" && grep -q '^model: opus$' "$D/.claude/agents/verifier.md"; } \
  && ok "mixed-judge pins executor + verifier to opus" || no "mixed-judge opus pins missing"
( cd "$D" && bash scripts/task-profile.sh inherit >/dev/null 2>&1 )
tp_after=$(cat "$D"/.claude/agents/*.md | md5sum)
[ "$tp_before" = "$tp_after" ] && ok "inherit restores frontmatter byte-identical (stock_update compatible)" || no "inherit round-trip not byte-identical"
( cd "$D" && bash scripts/task-profile.sh apply >/dev/null 2>&1 )
grep -q '^model: inherit$' "$D/.claude/agents/planner.md" && ok "apply: no flag + no active task -> inherit" || no "apply default is not inherit"
printf 'pdemo\n' > "$D/.ai_context/tasks/CURRENT"
printf '# Plan: p\n<!-- profile: mixed-judge ; size: M -->\n## M1: x [in_progress]\n- verify: `true`\n' > "$D/.ai_context/tasks/pdemo/plan.md"
( cd "$D" && bash scripts/task-profile.sh apply >/dev/null 2>&1 )
grep -q '^model: fable$' "$D/.claude/agents/scout.md" && ok "apply: resume re-applies the plan.md header profile" || no "resume did not restore the header profile"
tp_warn=$( cd "$D" && bash scripts/task-profile.sh apply inherit 2>&1 >/dev/null )
echo "$tp_warn" | grep -q 'PROFILE SWITCH' && ok "apply: conflicting flag warns (mid-task switch, never silent)" || no "mid-task switch warning missing"
grep -q '^model: inherit$' "$D/.claude/agents/scout.md" && ok "apply: explicit flag still wins after the warning" || no "explicit flag did not apply"
tp_env=$( cd "$D" && CLAUDE_CODE_SUBAGENT_MODEL=sonnet bash scripts/task-profile.sh status 2>&1 >/dev/null )
echo "$tp_env" | grep -q 'CLAUDE_CODE_SUBAGENT_MODEL' && ok "status warns when CLAUDE_CODE_SUBAGENT_MODEL overrides pins" || no "env-override warning missing"


# Every writing entry point must warn, not only `apply`.
for tp_alias in mixed mixed-judge inherit; do
  tp_active=mixed-judge
  [ "$tp_alias" = mixed-judge ] && tp_active=mixed
  printf '# Plan: p\n<!-- profile: %s ; size: M -->\n## M1: x [in_progress]\n- verify: `true`\n' "$tp_active" > "$D/.ai_context/tasks/pdemo/plan.md"
  tp_warn=$( cd "$D" && bash scripts/task-profile.sh "$tp_alias" 2>&1 >/dev/null ); tp_rc=$?
  ck 0 "$tp_rc" "$tp_alias still applies the user-selected profile"
  echo "$tp_warn" | grep -q "PROFILE SWITCH mid-task ($tp_active -> $tp_alias)" && ok "$tp_alias warns on active profile mismatch" || no "$tp_alias switched without warning"
done
printf '# Plan: p\n<!-- profile: mixed-judge ; size: M -->\n' > "$D/.ai_context/tasks/pdemo/plan.md"
tp_warn=$( cd "$D" && bash scripts/task-profile.sh mixed-judge 2>&1 >/dev/null )
[ -z "$tp_warn" ] && ok "matching direct profile has no switch warning" || no "matching profile warned"
# pair-codex (ADR-028): all seven inherit — the Codex judge is the only
# non-Claude seat and it is not a pin; the plan header is the whole state.
( cd "$D" && bash scripts/task-profile.sh pair-codex >/dev/null 2>&1 ); tp_rc=$?
ck 0 "$tp_rc" "pair-codex is an accepted profile"
[ "$(grep -h '^model:' "$D"/.claude/agents/*.md | sort -u)" = "model: inherit" ] && ok "pair-codex pins every agent to inherit (both sides run their session default)" || no "pair-codex wrote a model pin"
printf '# Plan: p\n<!-- profile: pair-codex ; size: M -->\n## M1: x [in_progress]\n- verify: `true`\n' > "$D/.ai_context/tasks/pdemo/plan.md"
tp_warn=$( cd "$D" && bash scripts/task-profile.sh apply mixed-judge 2>&1 >/dev/null )
echo "$tp_warn" | grep -q 'PROFILE SWITCH mid-task (pair-codex -> mixed-judge)' && ok "leaving pair-codex mid-task warns like any other switch" || no "pair-codex switch was silent"
( cd "$D" && bash scripts/task-profile.sh apply >/dev/null 2>&1 )
grep -q '^model: inherit$' "$D/.claude/agents/executor.md" && ok "apply: resume restores pair-codex from the header (inherit pins)" || no "resume under pair-codex left pins behind"
( cd "$D" && bash scripts/task-profile.sh status 2>/dev/null ) | grep -q 'active plan.md profile: pair-codex' && ok "status names the active plan.md profile" || no "status does not show the active profile"

echo "=== L1-21 · every exit-2 block prints the stdout marker (CLI heuristic, v3.14)"
# The missing-hook heuristic (exit 2 + EMPTY stdout + stderr matching
# /no such file|can't open/i) silently drops legitimate blocks — journal
# 2026-08-13. Non-empty stdout breaks the conjunction; every block path
# must print the marker, INCLUDING when verify output carries the fatal
# strings. mk() runs the gate and asserts rc=2 + marker on stdout.
MARK='claude-starter-gate: BLOCK'
mk() { # $1 = label, $2 = session id, $3 = project dir, $4... = extra gate args
  local label="$1" sidq="$2" dir="$3"; shift 3
  local o rc
  o=$(printf '{"session_id": "%s"}' "$sidq" | CLAUDE_PROJECT_DIR="$dir" bash "$GATE" "$@" 2>/dev/null); rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$o" | grep -qF "$MARK"; then ok "marker: $label"
  else no "marker: $label (rc=$rc stdout='$o')"; fi
}
D="$WORK/l121"; mkdir -p "$D/.ai_context"
printf '# t\n- **Install:** `<command>`\n' > "$D/CLAUDE.md"
mk "setup gate" tsuite-mk1 "$D"
D="$WORK/l121b"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
mk "integrity (missing plan)" tsuite-mk2 "$D"
# the heuristic's exact bait: verify output contains "can't open file"
write_plan "$D/.ai_context/tasks/demo/plan.md" "python3 no-such-script-xyz.py"
mk "red verify whose output matches the heuristic regex" tsuite-mk3 "$D"
write_plan "$D/.ai_context/tasks/demo/plan.md" 'touch pwned-mk && git push origin main'
mk "forbidden verify" tsuite-mk4 "$D"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
sed -i.bak 's/## M3: future \[pending\]/## M3: future [in_progress]/' "$D/.ai_context/tasks/demo/plan.md" && rm -f "$D/.ai_context/tasks/demo/plan.md.bak"
mk "double in_progress" tsuite-mk5 "$D"
write_plan "$D/.ai_context/tasks/demo/plan.md" "true"
mk "green boundary prompt" tsuite-mk6 "$D"
# red wrap-up sweep (stop mode) and strict /wrap sweep
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: fixture
<!-- profile: opus-tier ; size: S -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: only [done]
- verify: `false`
- risk: low
PEOF
rm -f "$D/.ai_context/tasks/demo/gatelog"
mk "red wrap-up sweep" tsuite-mk7 "$D"
rm -f "$D/.ai_context/tasks/demo/gatelog"
o=$(CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep 2>/dev/null); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$o" | grep -qF "$MARK"; then ok "marker: strict /wrap --sweep"
else no "marker: strict /wrap --sweep (rc=$rc)"; fi
# static net: no exit-2 path exists that the runtime cases above miss
n_exit2=$(grep -c 'exit 2' "$GATE")
n_mark=$(grep -c 'mark_block$\|mark_block;' "$GATE")
[ "$n_mark" -ge 7 ] && ok "mark_block wired across block paths ($n_mark call sites, $n_exit2 exit-2 lines)" || no "mark_block call sites: want >=7 got $n_mark"

echo "=== L1-22 · checkpoint milestones: hold for the human, never advance past (v3.14)"
D="$WORK/l122"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: fixture
<!-- profile: opus-tier ; size: M -->
<!-- statuses: [pending] [in_progress] [done]; exactly one in_progress -->

## M1: gated deploy [in_progress]
- verify: `true`
- checkpoint: human
- risk: high

## M2: aftermath [pending]
- verify: `false`
- risk: low
PEOF
out=$(printf '{"session_id": "tsuite-ck1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "checkpoint PASS holds quietly (no continuation prompt)"
echo "$out" | grep -q 'human checkpoint' && ok "hold surfaces the sign-off systemMessage" || no "checkpoint systemMessage missing"
grep -q "	M1	PAUSED	checkpoint" "$D/.ai_context/tasks/demo/gatelog" && ok "checkpoint hold recorded (PAUSED row)" || no "checkpoint PAUSED row missing"
# work advanced past the un-acked checkpoint => integrity block, then a
# repeating systemMessage — the human signal must not die with the one-shot
sed -i.bak 's/## M1: gated deploy \[in_progress\]/## M1: gated deploy [done]/; s/## M2: aftermath \[pending\]/## M2: aftermath [in_progress]/' "$D/.ai_context/tasks/demo/plan.md" && rm -f "$D/.ai_context/tasks/demo/plan.md.bak"
err=$(printf '{"session_id": "tsuite-ck1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>&1 >/dev/null); rc=$?
ck 2 $rc "advancing past an un-acked checkpoint blocks (integrity)"
echo "$err" | grep -q 'sign-off' && ok "block names the missing sign-off" || no "block message unhelpful"
out=$(printf '{"session_id": "tsuite-ck1"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "checkpoint integrity yields on repeat (one-shot spent)"
echo "$out" | grep -q 'awaits human sign-off' && ok "repeat stop keeps pinging the human" || no "repeat signal lost"
# the ack releases everything: hold gone, gate arms M2 normally (red)
touch "$D/.ai_context/tasks/demo/ack-M1"
printf '{"session_id": "tsuite-ck2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "acked checkpoint releases the run (M2 arms, red verify blocks normally)"
# wiring: ack files are Edit-denied and bash-guard confirms model-side writes
grep -q 'Edit(./.ai_context/tasks/\*\*/ack-\*)' "$REPO/.claude/settings.json" && ok "ack files Edit-denied" || no "ack Edit-deny missing"
bgout=$(printf '{"tool_input":{"command":"touch .ai_context/tasks/demo/ack-M1"}}' | CLAUDE_PROJECT_DIR="$D" bash "$REPO/.claude/hooks/bash-guard.sh" 2>/dev/null)
echo "$bgout" | grep -q '"permissionDecision":"ask"' && ok "bash-guard asks on model-side ack writes (sign-off stays human)" || no "bash-guard ack confirmation missing"


echo "=== L1-22b · terminal checkpoints hold through Stop and strict wrap"
D="$WORK/l122final"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# configured\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
cat > "$D/.ai_context/tasks/demo/plan.md" <<'PEOF'
# Plan: terminal checkpoint
## M1: final [in_progress]
- verify: `true`
- checkpoint: human
PEOF
out=$(printf '{"session_id":"tsuite-ck-final"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "final in-progress checkpoint allows a human pause"
echo "$out" | grep -q 'human checkpoint' && ok "final checkpoint holds even without pending milestones" || no "terminal checkpoint hold missing"
sed -i 's/\[in_progress\]/[done]/' "$D/.ai_context/tasks/demo/plan.md"
out=$(printf '{"session_id":"tsuite-ck-final"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 2 $rc "all-done task cannot skip final human ack"
echo "$out" | grep -q 'claude-starter-gate: BLOCK' && ok "terminal checkpoint block has CLI marker" || no "terminal checkpoint marker missing"
out=$(printf '{"session_id":"tsuite-ck-final"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "repeated Stop yields for human sign-off"
echo "$out" | grep -q 'awaits human sign-off' && ok "all-done pause keeps the missing ack visible" || no "all-done checkpoint silently passed"
for ck_try in 1 2; do
  out=$(CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep 2>/dev/null); rc=$?
  ck 2 $rc "explicit sweep refuses unacked final checkpoint (attempt $ck_try)"
  echo "$out" | grep -q 'claude-starter-gate: BLOCK' && ok "checkpoint sweep block carries marker ($ck_try)" || no "checkpoint sweep marker missing ($ck_try)"
done
touch "$D/.ai_context/tasks/demo/ack-M1"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 0 $? "human ack releases final wrap"
# An earlier checkpoint must also be checked when every milestone is done.
sed -i 's/## M1:/## M0:/' "$D/.ai_context/tasks/demo/plan.md"
printf '\n## M2: later [done]\n- verify: `true`\n' >> "$D/.ai_context/tasks/demo/plan.md"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 2 $? "all-done sweep also checks earlier unacked checkpoints"
touch "$D/.ai_context/tasks/demo/ack-M0"
CLAUDE_PROJECT_DIR="$D" bash "$GATE" --sweep >/dev/null 2>&1
ck 0 $? "all acknowledged checkpoints allow completion"

echo "=== L1-23 · pair-codex transport: task-pair.sh over a fake herdr (ADR-028)"
# Every scenario asserts the same invariant from two sides: a run that did
# not end in a checkable result never exits 0, and the script never prints
# a verdict of its own. The fake herdr replays herdr 0.9.0 JSON shapes.
PD="$WORK/l123"; FK="$WORK/l123-fake"   # fake herdr's log/state live OUTSIDE the fixture repo
mkdir -p "$PD/scripts" "$PD/.ai_context/tasks/pdemo" "$FK/bin" "$FK/codex-home" "$FK/empty-home" "$FK/state"
cp "$REPO/scripts/task-pair.sh" "$PD/scripts/"
cp "$REPO/tests/fake-herdr.sh" "$FK/bin/herdr"; chmod +x "$FK/bin/herdr"
( cd "$PD" && git init -q . && printf '# p\n' > CLAUDE.md && git add -A && git commit -qm init )
PH="$(git -C "$PD" rev-parse HEAD)"
printf 'pdemo\n' > "$PD/.ai_context/tasks/CURRENT"
pplan() { printf '# Plan: p\n<!-- profile: %s ; size: M -->\n## M1: x [in_progress]\n- verify: `true`\n' "$1" > "$PD/.ai_context/tasks/pdemo/plan.md"; }
pplan pair-codex
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$PD" > "$FK/codex-home/config.toml"
PKD="$PD/.ai_context/tasks/pdemo/pair"; mkdir -p "$PKD"
mkpkt() { printf 'role: %s\nmilestone: M1\nbase: %s\n\n# packet body\n' "$2" "$3" > "$PKD/$1-$2-M1.md"; echo "$PKD/$1-$2-M1.md"; }
# tp <ENV=val ...> -- <task-pair args>: runs inside the fixture with the fake
# herdr on PATH; stdout/stderr land in $FK/out and $FK/err, rc is echoed.
tp() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  ( cd "$PD" && env HERDR_ENV=1 PATH="$FK/bin:$PATH" CODEX_HOME="$FK/codex-home" \
      FAKE_HERDR_LOG="$FK/herdr.log" FAKE_HERDR_STATE="$FK/state" "${envs[@]}" \
      bash scripts/task-pair.sh "$@" ) >"$FK/out" 2>"$FK/err"; echo $?
}
prompts() { grep '^agent prompt' "$FK/herdr.log" 2>/dev/null | grep -vc ' /new$' || echo 0; }   # packet prompts only (/new is a slash command)
no_verdict_printed() { ! grep -q 'PASS\|FAIL' "$FK/out" "$FK/err"; }
RL="$PKD/runlog"

# --- refusals happen before any herdr call --------------------------------
pplan opus-tier
rc=$(tp -- ensure); ck 3 "$rc" "ensure refuses under a non-pair profile"
[ ! -s "$FK/herdr.log" ] && ok "no herdr call under a non-pair profile" || no "herdr was called under a non-pair profile"
pplan pair-codex
rc=$(tp HERDR_ENV=0 -- ensure); ck 3 "$rc" "ensure refuses outside herdr (HERDR_ENV != 1)"
rc=$(tp CODEX_HOME="$FK/empty-home" -- ensure); ck 3 "$rc" "ensure refuses when Codex has not trusted the repo"
grep -q 'trust' "$FK/err" && ok "untrusted refusal names the fix" || no "untrusted refusal message missing"
# Hooks tripwire: a judge we did not start cannot prove hooks are off.
mkdir -p "$PD/.codex"; printf '{"hooks":{}}' > "$PD/.codex/hooks.json"
rc=$(tp FAKE_HERDR_AGENT=idle -- ensure); ck 3 "$rc" "ensure refuses a foreign judge when .codex/hooks.json exists"
printf 'name=judge-pdemo\nhooks_off=1\n' > "$PKD/judge"
rc=$(tp FAKE_HERDR_AGENT=idle -- ensure); ck 0 "$rc" "ensure accepts a judge whose record says hooks are off"
rm -rf "$PD/.codex" "$PKD/judge"; : > "$FK/herdr.log"

# --- ensure starts the judge with the verified argument set -----------------
rc=$(tp -- ensure); ck 0 "$rc" "ensure starts a judge when none is live"
st_line="$(grep '^agent start' "$FK/herdr.log" || true)"
printf '%s' "$st_line" | grep -q -- '-c features.hooks=false' && ok "judge starts with Codex hooks disabled (no second Stop gate)" || no "judge started with hooks enabled: $st_line"
printf '%s' "$st_line" | grep -q -- '-s workspace-write' && ok "judge starts in workspace-write (read-only cannot even mktemp)" || no "judge sandbox flag wrong: $st_line"
printf '%s' "$st_line" | grep -q 'project_doc_fallback_filenames' && ok "judge reads CLAUDE.md as its project doc" || no "CLAUDE.md fallback missing: $st_line"
printf '%s' "$st_line" | grep -qE -- '(^| )-m |model_reasoning_effort' && no "judge pins a model/effort (must inherit the user's Codex default)" || ok "judge inherits the user's Codex model and effort"
grep -qx 'hooks_off=1' "$PKD/judge" && ok "judge record written (hooks_off=1)" || no "judge record missing"
grep -q 'gpt-5.6-terra medium' "$FK/out" && ok "ensure reports the observed model from the status line" || no "model not scraped: $(cat "$FK/out")"
rc=$(tp -- ensure); ck 0 "$rc" "ensure is idempotent (judge present)"
[ "$(grep -c '^agent start' "$FK/herdr.log")" -eq 1 ] && ok "second ensure does not start a second judge" || no "ensure restarted a live judge"

# --- send: the happy path, and the script's silence on verdicts -------------
pk=$(mkpkt 001 verifier "$PH")
rc=$(tp -- send "$pk"); ck 0 "$rc" "send: completed run exits 0"
[ -s "${pk%.md}.result.md" ] && ok "send: result file collected" || no "send: result missing"
grep -q "	001	start	verifier	M1	$PH	" "$RL" && ok "runlog: start row (seq, role, milestone, base)" || no "runlog start row malformed: $(cat "$RL")"
grep -q "	001	end:completed	" "$RL" && ok "runlog: end:completed row" || no "runlog end row missing"
grep -q 'state=completed (verdict=pass)' "$FK/out" && ok "send: summary carries the judge's verdict verbatim, lowercase" || no "send summary wrong: $(cat "$FK/out")"
no_verdict_printed && ok "script prints no PASS/FAIL of its own" || no "script printed a verdict"
grep -q '	gpt-5.6-terra medium	12/34	' "$RL" && ok "runlog rows record the observed model and token counters" || no "runlog model/tokens columns wrong: $(tail -1 "$RL")"
[ ! -e "$PKD/001-verifier.screen.txt" ] && ok "completed run leaves no screen dump" || no "screen dump written for a completed run"
# Fresh thread per packet (ADR-030): send itself sends /new right before the
# packet prompt, and the runlog shows the reset row before the start row.
grep '^agent prompt' "$FK/herdr.log" | grep -B1 'Read and execute' | head -1 | grep -q ' /new$' \
  && ok "send: /new is the prompt right before the packet prompt" || no "send did not open a fresh thread: $(grep '^agent prompt' "$FK/herdr.log" | cut -c1-60 | tr '\n' '|')"
grep -B1 "	001	start	" "$RL" | head -1 | grep -q "	001	reset	" && ok "runlog: reset row (same seq) precedes the start row" || no "runlog start row not preceded by a reset row: $(cat "$RL")"
rc=$(tp -- status); ck 0 "$rc" "status runs"
grep -q 'no fresh thread' "$FK/out" && no "status flags a fresh-thread run as stale" || ok "status: no stale-thread flag on a send-driven run"

# --- send: every way a run can end without a usable result -----------------
pk=$(mkpkt 002 verifier "$PH")
rc=$(tp FAKE_HERDR_PROMPT=no_result -- send "$pk"); ck 6 "$rc" "idle without a result file is failed:no_result"
grep -q "	002	end:failed	.*	no_result$" "$RL" && ok "runlog: no_result recorded" || no "runlog no_result row missing"
[ -s "$PKD/002-verifier.screen.txt" ] && ok "failed run saves the judge's screen next to the packet" || no "screen dump missing for the failed run"
pk=$(mkpkt 003 verifier "$PH")
rc=$(tp FAKE_HERDR_PROMPT=bad_header -- send "$pk"); ck 6 "$rc" "result without a verdict line is failed:bad_header"
grep -q "	003	end:failed	.*	bad_header$" "$RL" && ok "runlog: bad_header recorded" || no "runlog bad_header row missing"
pk=$(mkpkt 004 verifier "$PH")
rc=$(tp FAKE_HERDR_PROMPT=base_mismatch -- send "$pk"); ck 6 "$rc" "result for another base is failed:base_mismatch"
pk=$(mkpkt 005 verifier "$PH")
rc=$(tp FAKE_HERDR_PROMPT=tree_changed FAKE_HERDR_TOUCH="$PD/CLAUDE.md" -- send "$pk"); ck 6 "$rc" "a judge that touched the tree voids its own result (tree_changed)"
grep -q "	005	end:failed	.*	tree_changed$" "$RL" && ok "runlog: tree_changed recorded" || no "runlog tree_changed row missing"
[ -s "${pk%.md}.result.md" ] && ok "tree_changed: the (voided) result file is kept as evidence" || no "tree_changed result vanished"
git -C "$PD" checkout -q CLAUDE.md
pk=$(mkpkt 006 verifier "$PH")
rc=$(tp FAKE_HERDR_PROMPT=timeout -- send "$pk"); ck 5 "$rc" "herdr timeout leaves the run in flight (exit 5, chain wait)"
grep -q "	006	waiting	" "$RL" && ok "runlog: waiting row on timeout" || no "runlog waiting row missing"
[ -f "$PKD/.fp-006" ] && ok "in-flight fingerprint kept for wait" || no "in-flight fingerprint missing"
grep -q 'task-pair.sh wait 006' "$FK/out" && ok "timeout output names the wait command" || no "timeout output lacks the wait hint"
rc=$(tp FAKE_HERDR_WAIT=ok -- wait 006); ck 0 "$rc" "wait: settles the in-flight run"
grep -q "	006	end:completed	" "$RL" && ok "runlog: wait completed the run" || no "runlog after wait wrong"
[ ! -f "$PKD/.fp-006" ] && ok "in-flight fingerprint cleared after settle" || no "stale .fp file left"
rc=$(tp -- wait 006); ck 2 "$rc" "wait refuses a seq with no run in flight"
pk=$(mkpkt 007 verifier "$PH")
rc=$(tp FAKE_HERDR_PROMPT=stalled -- send "$pk"); ck 6 "$rc" "agent_prompt_stalled is failed:stalled, not resent"
[ "$(prompts)" -eq 7 ] && ok "stalled prompt was not resubmitted" || no "prompt count after stall: $(prompts)"
pk=$(mkpkt 008 verifier "$PH")
rc=$(tp FAKE_HERDR_PROMPT=blocked -- send "$pk"); ck 4 "$rc" "judge blocked mid-run exits 4 (human)"
grep -q "	008	end:blocked	" "$RL" && ok "runlog: blocked recorded" || no "runlog blocked row missing"
pk=$(mkpkt 009 verifier "$PH")
rc=$(tp -- send "$pk"); ck 4 "$rc" "send refuses while the judge is still blocked"
[ "$(prompts)" -eq 8 ] && ok "nothing was typed into a blocked judge" || no "prompt sent to a blocked judge"
echo idle > "$FK/state/agent"

# --- modal dialogs: herdr says idle, the screen says otherwise ---------------
SCR="$FK/screen.txt"
printf '  Do you trust the contents of this directory? Working with untrusted contents\n› 1. Yes, continue\n  2. No, quit\n  Press enter to continue\n' > "$SCR"
pk=$(mkpkt 010 verifier "$PH")
rc=$(tp FAKE_HERDR_SCREEN="$SCR" -- send "$pk"); ck 4 "$rc" "trust dialog on screen: refused, never answered"
[ "$(prompts)" -eq 8 ] && ok "no prompt typed into the trust dialog" || no "prompt sent over a trust dialog"
grep -q "trust" "$FK/err" && ok "trust dialog is reported to the human" || no "trust dialog not reported"
ls "$PKD"/dialog-*.screen.txt >/dev/null 2>&1 && ok "dialog refusal saves the screen" || no "dialog screen dump missing"
printf '  Approaching rate limits\n  Switch to gpt-5.6-luna for lower credit usage?\n› 1. Switch to gpt-5.6-luna\n  2. Keep current model\n  Press enter to confirm or esc to go back\n' > "$SCR"
pk=$(mkpkt 011 verifier "$PH")
rc=$(tp FAKE_HERDR_SCREEN="$SCR" FAKE_HERDR_ESC_CLEARS=1 -- send "$pk"); ck 0 "$rc" "rate-limit nudge: dismissed with esc, run proceeds"
grep -q '^agent send-keys judge-pdemo esc' "$FK/herdr.log" && ok "esc sent for the rate-limit nudge (keeps the current model)" || no "esc not sent"
printf '  Approaching rate limits\n  Switch to gpt-5.6-luna for lower credit usage?\n  Press enter to confirm or esc to go back\n' > "$SCR"
pk=$(mkpkt 012 verifier "$PH")
rc=$(tp FAKE_HERDR_SCREEN="$SCR" FAKE_HERDR_ESC_CLEARS=0 -- send "$pk"); ck 4 "$rc" "a nudge that survives esc is handed to the human"
[ "$(prompts)" -eq 9 ] && ok "no prompt typed into a surviving dialog" || no "prompt sent over a surviving dialog"

# --- packet hygiene ---------------------------------------------------------
pk=$(mkpkt 013 verifier 0123456789abcdef0123456789abcdef01234567)
rc=$(tp -- send "$pk"); ck 6 "$rc" "commit-shaped base that is not HEAD: stale packet, not sent"
[ "$(prompts)" -eq 9 ] && ok "stale packet never reached the judge" || no "stale packet was sent"
pk=$(mkpkt 014 plan-critic "sha256:plan-digest-v3")
rc=$(tp -- send "$pk"); ck 0 "$rc" "non-commit base (plan digest) is passed through and matched"
pk=$(mkpkt 015 verifier "$PH"); : > "${pk%.md}.result.md"
rc=$(tp -- send "$pk"); ck 2 "$rc" "existing result file: refused (one packet, one run)"
printf 'milestone: M1\nbase: %s\n' "$PH" > "$PKD/016-verifier-M1.md"
rc=$(tp -- send "$PKD/016-verifier-M1.md"); ck 2 "$rc" "packet without a role line is refused"
rc=$(tp -- status); ck 0 "$rc" "status runs"
grep -q 'seq 001  verifier M1  -> completed' "$FK/out" && ok "status summarises seq 001 as completed" || no "status output wrong: $(head -3 "$FK/out")"
grep -q 'seq 008  verifier M1  -> blocked' "$FK/out" && ok "status summarises seq 008 as blocked" || no "status lost the blocked row"

# --- packet: the judge's inputs are generated, not remembered (phase 2) -----
mkdir -p "$PD/.claude/agents"; cp "$REPO/.claude/agents/verifier.md" "$REPO/.claude/agents/final-verifier.md" "$REPO/.claude/agents/planner.md" "$REPO/.claude/agents/plan-critic.md" "$PD/.claude/agents/"
printf '# Plan: p\n<!-- profile: pair-codex ; size: M -->\n\n## M1: x [done]\n- verify: `true`\n- risk: low\n\n## M2: y [in_progress]\n- verify: `bash t.sh`\n- risk: med\n- demo: run y\n<!-- 2026-09-15: forward constraint for M2 -->\n\n## M3: z [pending]\n- verify: `false`\n- risk: high\n' > "$PD/.ai_context/tasks/pdemo/plan.md"
printf '# Spec: p\nGoal: g\n\n## Acceptance criteria\n- [ ] AC1: `bash t.sh` exits 0\n- [x] AC2: `test -f x`\n\n## Assumptions\n- [ASSUMED: y]\n' > "$PD/.ai_context/tasks/pdemo/spec.md"
( cd "$PD" && git add -A && git commit -qm "plan for packets" )
PH2="$(git -C "$PD" rev-parse HEAD)"
rc=$(tp -- packet verifier M2 --changed a.sh,b.sh); ck 0 "$rc" "packet: verifier light generates"
pk="$(cat "$FK/out")"
[ "$pk" = ".ai_context/tasks/pdemo/pair/017-verifier-M2.md" ] && ok "packet: seq continues after the last packet (017)" || no "packet path/seq wrong: $pk"
grep -q "^base: $PH2$" "$PD/$pk" && ok "packet: base is HEAD at generation time" || no "packet base wrong"
grep -q '^mode: light$' "$PD/$pk" && grep -q 'changed files (uncommitted, vs base .*): a.sh,b.sh' "$PD/$pk" && ok "packet: light mode carries the changed-file list" || no "packet light mode text missing"
grep -q '^## M2: y \[in_progress\]$' "$PD/$pk" && grep -q 'forward constraint for M2' "$PD/$pk" && ok "packet: the FULL milestone section is inlined (comment block included)" || no "packet milestone section incomplete"
! grep -q '^## M3' "$PD/$pk" && ok "packet: neighbouring milestones are not inlined" || no "packet leaked another milestone"
grep -q '^Your role contract is .claude/agents/verifier.md' "$PD/$pk" && ok "packet: role body referenced by path, never copied" || no "packet lacks the role-contract pointer"
grep -q "^Write $PD/.ai_context/tasks/pdemo/pair/017-verifier-M2.result.md$" "$PD/$pk" && ok "packet: result path is absolute and derived from the packet name" || no "packet result path wrong"
grep -q '^  base: '"$PH2"'$' "$PD/$pk" && ok "packet: result contract pins the same base" || no "packet result-contract base wrong"
# rollout linkage: the judge's transcript is the newest Codex rollout whose
# session_meta names this repo and started after the judge did
mkdir -p "$FK/codex-home/sessions/2026/09/15"
printf '{"timestamp":"2099-01-01T00:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"a","id":"a","timestamp":"2099-01-01T00:00:00.000Z","cwd":"%s","originator":"codex-tui"}}\n' "$PD" > "$FK/codex-home/sessions/2026/09/15/rollout-a.jsonl"
printf '{"timestamp":"2098-01-01T00:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"b","id":"b","timestamp":"2098-01-01T00:00:00.000Z","cwd":"%s","originator":"codex-tui"}}\n' "$PD" > "$FK/codex-home/sessions/2026/09/15/rollout-b.jsonl"
printf '{"timestamp":"2099-06-01T00:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"c","id":"c","timestamp":"2099-06-01T00:00:00.000Z","cwd":"/elsewhere","originator":"codex-tui"}}\n' > "$FK/codex-home/sessions/2026/09/15/rollout-c.jsonl"
printf '{"timestamp":"2000-01-01T00:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"session_id":"d","id":"d","timestamp":"2000-01-01T00:00:00.000Z","cwd":"%s","originator":"codex-tui"}}\n' "$PD" > "$FK/codex-home/sessions/2026/09/15/rollout-d.jsonl"
rc=$(tp -- send "$pk"); ck 0 "$rc" "packet → send round-trips over the fake judge"
grep -q "	017	end:completed	.*	$FK/codex-home/sessions/2026/09/15/rollout-a.jsonl	" "$RL" && ok "runlog: rollout column names the newest matching Codex transcript (not the other repo's, not the pre-start one)" || no "rollout linkage wrong: $(grep '	017	end' "$RL")"
rc=$(tp -- packet verifier M3 --mode full); ck 0 "$rc" "packet: verifier full generates"
pk="$(cat "$FK/out")"
grep -q 'FULL PROTOCOL' "$PD/$pk" && grep -q '^- \[ \] AC1' "$PD/$pk" && grep -q '^- \[x\] AC2' "$PD/$pk" && ok "packet: full mode inlines the spec's acceptance criteria" || no "packet full mode incomplete"
rc=$(tp -- packet verifier M2 --mode drift --since "$PH"); ck 0 "$rc" "packet: drift generates"
pk="$(cat "$FK/out")"
grep -q "git diff $PH" "$PD/$pk" && grep -q 'ON-TRACK maps to verdict pass' "$PD/$pk" && ok "packet: drift names the diff base and the verdict mapping" || no "packet drift text incomplete"
rc=$(tp -- packet final-verifier - --lens regression); ck 2 "$rc" "packet: final-verifier without --since refused (the whole-task diff needs its start)"
rc=$(tp -- packet final-verifier - --lens regression --since "$PH"); ck 0 "$rc" "packet: final-verifier lens generates"
pk="$(cat "$FK/out")"
[ "$pk" = ".ai_context/tasks/pdemo/pair/020-final-verifier-regression.md" ] && ok "packet: lens is in the file name" || no "packet lens file name wrong: $pk"
grep -q '^lens: regression$' "$PD/$pk" && grep -q 'PANEL LENS: regression' "$PD/$pk" && grep -q '^milestone: -$' "$PD/$pk" && grep -q "git diff $PH..HEAD" "$PD/$pk" && ok "packet: lens header + whole-task diff range" || no "packet lens body incomplete"
printf 'run: completed\nverdict: fail\nbase: %s\nfindings: 1 (blocker/major/minor)\nassumptions: []\n\n- major: suite skips t.sh — `grep skip t.sh`\n' "$PH2" > "$FK/other.result.md"
rc=$(tp -- packet final-verifier - --lens regression --since "$PH" --rebuttal "$FK/other.result.md"); ck 0 "$rc" "packet: rebuttal round generates"
pk="$(cat "$FK/out")"
grep -q '^# Rebuttal round' "$PD/$pk" && grep -q '^> - major: suite skips t.sh' "$PD/$pk" && grep -q 'reproduce it (command + output) or refute it' "$PD/$pk" && ok "packet: rebuttal quotes the other side's findings and demands commands" || no "packet rebuttal incomplete"
rc=$(tp -- packet verifier M9 --changed a); ck 2 "$rc" "packet: unknown milestone refused"
rc=$(tp -- packet verifier M2); ck 2 "$rc" "packet: light mode without --changed refused"
rc=$(tp -- packet verifier M2 --mode drift); ck 2 "$rc" "packet: drift without --since refused"
rc=$(tp -- packet final-verifier - --since "$PH"); ck 2 "$rc" "packet: final-verifier without a lens refused"
rc=$(tp -- packet final-verifier M2 --lens correctness --since "$PH"); ck 2 "$rc" "packet: final-verifier with a milestone refused"
rc=$(tp -- packet verifier M2 --changed a --lens correctness); ck 2 "$rc" "packet: --lens on verifier refused"
rc=$(tp -- packet scout -); ck 2 "$rc" "packet: unwired role refused"
grep -q 'not wired' "$FK/err" && ok "packet: unwired role names the reason" || no "packet unwired-role message: $(cat "$FK/err")"
n_before=$(find "$PKD" -maxdepth 1 -name '*.md' | wc -l)
rc=$(tp -- packet verifier M2); [ "$(find "$PKD" -maxdepth 1 -name '*.md' | wc -l)" -eq "$n_before" ] && ok "packet: a refused packet leaves no file behind" || no "refused packet wrote a file"

# --- packet: plan loop roles (phase 3) ---------------------------------------
rc=$(tp -- packet planner - --lens risk-first --budget "<=15 tool calls"); ck 0 "$rc" "packet: planner candidate generates"
pk="$(cat "$FK/out")"
spec_d="$(sha256sum "$PD/.ai_context/tasks/pdemo/spec.md" | awk '{print $1}')"
grep -q "^base: spec:$spec_d$" "$PD/$pk" && ok "packet: planner binds to the spec digest, not a commit" || no "planner base wrong: $(grep '^base:' "$PD/$pk")"
grep -q '^lens: risk-first$' "$PD/$pk" && grep -q 'milestone budget: <=15 tool calls' "$PD/$pk" && ok "packet: planner carries lens + budget" || no "planner lens/budget missing"
grep -q '^    ## M1: <milestone title> \[pending\]$' "$PD/$pk" && grep -q 'profile: pair-codex ; size: S | M | L' "$PD/$pk" && ok "packet: planner inlines the gate-parseable plan.md format" || no "planner format block missing"
rc=$(tp FAKE_HERDR_PROMPT=ok -- send "$pk"); ck 0 "$rc" "packet: planner packet round-trips (spec digest echoed as base)"
printf '# Plan: cand\n<!-- profile: pair-codex ; size: M -->\n\n## M1: a [pending]\n- verify: `true`\n- risk: low\n' > "$FK/cand.md"
cand_d="plan:$(sha256sum "$FK/cand.md" | awk '{print $1}')"
rc=$(tp -- digest "$FK/cand.md"); ck 0 "$rc" "digest: prints the candidate digest"
[ "$(cat "$FK/out")" = "$cand_d" ] && ok "digest: plan:<sha256> of the frozen file" || no "digest output wrong: $(cat "$FK/out")"
rc=$(tp -- packet plan-critic - --candidate "$FK/cand.md" --round 1); ck 0 "$rc" "packet: plan-critic round 1 generates"
pk="$(cat "$FK/out")"
[ "$pk" = ".ai_context/tasks/pdemo/pair/023-plan-critic-r1.md" ] && ok "packet: round is in the file name" || no "plan-critic file name wrong: $pk"
grep -q "^base: $cand_d$" "$PD/$pk" && grep -q '^round: 1$' "$PD/$pk" && ok "packet: critic pass is bound to the candidate digest" || no "plan-critic base/round wrong"
grep -q '^    ## M1: a \[pending\]$' "$PD/$pk" && grep -q 'do not$' "$PD/$pk" && ok "packet: the candidate is inlined frozen (not read from plan.md)" || no "candidate not inlined"
! grep -q 'Ledger so far' "$PD/$pk" && ok "packet: round 1 has no ledger section" || no "round 1 carried a ledger"
grep -q 'rejected or noted may be re-raised ONLY' "$PD/$pk" && grep -q 'verdict pass means: no blocker and no major' "$PD/$pk" && ok "packet: anti-ping-pong rules are in the critic contract" || no "critic rules missing"
grep -q 'checklist 1 is observed, not reasoned' "$PD/$pk" && ok "packet: the Codex critic runs the risk:low verifies too (observed red)" || no "observed-red clause missing from the critic packet"
printf '| stage | ref | source | severity | claim | resolution |\n|---|---|---|---|---|---|\n| final | x | claude | minor | y | rejected: z |\n| plan | r1/1 | codex | major | M1 verify true cannot fail | accepted: verify is bash t.sh |\n' > "$PKD/ledger.md"
rc=$(tp -- packet plan-critic - --candidate "$FK/cand.md" --round 2); ck 0 "$rc" "packet: plan-critic round 2 generates"
pk="$(cat "$FK/out")"
grep -q '^    | plan | r1/1 | codex | major |' "$PD/$pk" && ! grep -q '| final | x |' "$PD/$pk" && ok "packet: round 2 carries the plan-stage ledger rows only" || no "ledger inclusion wrong"
rc=$(tp -- packet plan-critic - --candidate "$FK/cand.md" --round 11); ck 6 "$rc" "packet: round 11 refused — the 10-round cap is mechanical"
grep -q 'round cap 10' "$FK/err" && ok "packet: cap message hands the ledger to the human" || no "cap message wrong: $(cat "$FK/err")"
rc=$(tp -- packet plan-critic - --candidate "$FK/cand.md"); ck 2 "$rc" "packet: plan-critic without --round refused"
rc=$(tp -- packet plan-critic - --round 1); ck 2 "$rc" "packet: plan-critic without --candidate refused"
rc=$(tp -- packet plan-critic - --candidate "$FK/nope.md" --round 1); ck 2 "$rc" "packet: missing candidate file refused"
rc=$(tp -- packet planner -); ck 2 "$rc" "packet: planner without --lens refused"
rc=$(tp -- packet planner M2 --lens x); ck 2 "$rc" "packet: planner with a milestone refused"
rm -f "$PKD/ledger.md"

# --- packet: intake seats (phase 4) — Codex-only roles, contract inlined -----
rc=$(tp -- packet spec-critic -); ck 0 "$rc" "packet: spec-critic generates without an agent file"
pk="$(cat "$FK/out")"
grep -q "^base: spec:$spec_d$" "$PD/$pk" && ok "packet: spec-critic binds to the spec digest" || no "spec-critic base wrong"
grep -q 'Your contract is this packet' "$PD/$pk" && ! grep -q 'role contract is .claude/agents' "$PD/$pk" && ok "packet: spec-critic contract is inlined (no .claude/agents copy)" || no "spec-critic contract pointer wrong"
grep -q '^    - \[ \] AC1: `bash t.sh` exits 0$' "$PD/$pk" && grep -q '^    - \[ASSUMED: y\]$' "$PD/$pk" && ok "packet: the whole spec is inlined frozen" || no "spec not inlined"
grep -q 'what would make the human REJECT this even with' "$PD/$pk" && grep -q '1. Executability' "$PD/$pk" && ok "packet: spec-critic carries the four checks incl. the direction question" || no "spec-critic checks missing"
rc=$(tp -- send "$pk"); ck 0 "$rc" "packet: spec-critic round-trips over the fake judge"
printf '# Brief: p\n## Map\n- t.sh — the verify\n## Gotchas\n- none\n' > "$PD/.ai_context/tasks/pdemo/brief.md"
brief_d="$(sha256sum "$PD/.ai_context/tasks/pdemo/brief.md" | awk '{print $1}')"
rc=$(tp -- packet brief-audit -); ck 0 "$rc" "packet: brief-audit generates"
pk="$(cat "$FK/out")"
grep -q "^base: brief:$brief_d$" "$PD/$pk" && grep -q '^    - t.sh — the verify$' "$PD/$pk" && grep -q 'contradicted load-bearing' "$PD/$pk" && ok "packet: brief-audit binds to the brief digest and inlines it" || no "brief-audit body wrong"
rm -f "$PD/.ai_context/tasks/pdemo/brief.md"
rc=$(tp -- packet brief-audit -); ck 2 "$rc" "packet: brief-audit without a brief refused (scout first)"
rc=$(tp -- packet spec-critic - --lens x); ck 2 "$rc" "packet: spec-critic takes no options"
rc=$(tp -- packet spec-critic M1); ck 2 "$rc" "packet: spec-critic with a milestone refused"

# --- status invariant: every start row follows a reset row ------------------
# A start row that no reset row precedes means a judge prompted around the
# script (or a runlog from before ADR-030); status flags it, never hides it.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 2026-01-01T00:00:00Z 099 start verifier M1 "$PH" d m t r "timeout=1ms" >> "$RL"
rc=$(tp -- status); ck 0 "$rc" "status: tolerates a start row without a reset row"
grep -q 'seq 099 .*no fresh thread before start' "$FK/out" && ok "status flags a start row that no reset row precedes" || no "status missed the stale-thread run: $(grep 'seq 099' "$FK/out")"
[ "$(grep -c 'no fresh thread' "$FK/out")" -eq 1 ] && ok "status: send-driven runs carry no stale-thread flag" || no "stale-thread flag on send-driven runs: $(grep 'no fresh thread' "$FK/out")"

# --- reset: /new by hand (send does it itself before every packet) ----------
rc=$(tp -- reset); ck 0 "$rc" "reset: sends /new to the live judge"
grep -q '^agent prompt judge-pdemo /new$' "$FK/herdr.log" && ok "reset: /new goes through agent prompt (slash command, no --wait)" || no "reset did not send /new"
grep -q "	-	reset	" "$RL" && ok "runlog: hand reset row recorded (seq -)" || no "runlog reset row missing"
rm -f "$FK/state/agent"
rc=$(tp -- reset); ck 3 "$rc" "reset: refuses when no judge is live"

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
           .claude/skills/number-check/SKILL.md \
           .claude/agents/scout.md .claude/agents/planner.md .claude/agents/plan-critic.md \
           .claude/agents/executor.md .claude/agents/verifier.md .claude/agents/reframer.md \
           .claude/agents/final-verifier.md \
           .claude/.starter-version .ai_context/INDEX.md .ai_context/tasks/.gitkeep \
           .secrets/.gitkeep \
           scripts/harness-report.sh scripts/check-append-only.sh scripts/check-context-bulk.sh \
           scripts/task-profile.sh \
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
  ck 2 $? "project gate: green boundary prompts (v3.14: PASS with [pending] left ⇒ one-time exit 2)"
  write_plan "$P/.ai_context/tasks/demo/plan.md" "false"
  printf '{"session_id": "tsuite-l2"}' | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 2 $? "project gate: red blocks"
  grep -qc "	M2	" "$P/.ai_context/tasks/demo/gatelog" >/dev/null && ok "project gatelog written" || no "project gatelog missing"

  echo "=== L2-3b · completion and profile fixes ship through git archive"
  mkdir -p "$P/.ai_context/tasks/finalfix"; echo finalfix > "$P/.ai_context/tasks/CURRENT"
  printf '# Plan: shipped fixes\n<!-- profile: mixed-judge ; size: S -->\n## M1: final [done]\n- verify: `true`\n' > "$P/.ai_context/tasks/finalfix/plan.md"
  CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" --sweep >/dev/null 2>&1
  ck 0 $? "spawned final verify records PASS"
  sed -i 's/- verify: `true`/- verify: `false`/' "$P/.ai_context/tasks/finalfix/plan.md"
  CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" --sweep >/dev/null 2>&1
  ck 2 $? "spawned sweep rejects stale final PASS"
  sed -i 's/- verify: `false`/- verify: `true`/' "$P/.ai_context/tasks/finalfix/plan.md"
  printf '%s\n' '- checkpoint: human' >> "$P/.ai_context/tasks/finalfix/plan.md"
  CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" --sweep >/dev/null 2>&1
  ck 2 $? "spawned sweep refuses missing final ack"
  touch "$P/.ai_context/tasks/finalfix/ack-M1"
  CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" --sweep >/dev/null 2>&1
  ck 0 $? "spawned sweep accepts acknowledged green completion"
  tp_warn=$(bash "$P/scripts/task-profile.sh" mixed 2>&1 >/dev/null)
  echo "$tp_warn" | grep -q 'PROFILE SWITCH' && ok "spawned direct profile warns on mismatch" || no "spawned profile alias missed warning"
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
  grep -q "What we don't know" "$R/CLAUDE.md" && grep -q 'An empty search is a finding' "$R/CLAUDE.md" && ok "research DoD requires a What-we-don't-know section + empty-search records" || no "research epistemics lines missing from the spawned CLAUDE.md"
  mkdir -p "$R/.ai_context/tasks/demo"; echo demo > "$R/.ai_context/tasks/CURRENT"
  printf '# r\n## Commands\n- Test: `true`\n' > "$R/CLAUDE.md"
  write_plan "$R/.ai_context/tasks/demo/plan.md" "test -s reports/x.md"
  git -C "$R" checkout -qb task/demo 2>/dev/null || true
  printf '{"session_id": "tsuite-r"}' | CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 2 $? "artifact gate blocks while deliverable absent"
  mkdir -p "$R/reports" && echo content > "$R/reports/x.md"
  printf '{"session_id": "tsuite-r"}' | CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 2 $? "artifact gate: deliverable present ⇒ PASS + green boundary prompt (v3.14)"
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
