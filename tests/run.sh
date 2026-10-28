#!/usr/bin/env bash
#
# tests/run.sh — claude-starter harness regression suite.
#
#   L1: mechanism level  — hooks and sync logic against fixtures
#   L2: integration level — mechanisms inside a really-spawned project
#
# No model calls; safe for CI. Fixtures follow the v4 spec: card.md carries
# its `<!-- card v4 … -->` header, lane records come only from evidence.sh
# trust/run/check, and only the tampering, foreign-record and gate-error
# assertions edit the ledger, card or donelog by hand or swap evidence.sh.
# Exit 0 = all green; SKIPs don't fail the run.

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
cleanup() { rm -rf "$WORK" "/tmp/pair-${H8:-none}-pdemo" "${TMPDIR:-/tmp}"/claude-setup-nudge-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-red-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-stuck-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-line-tsuite-* "${TMPDIR:-/tmp}"/claude-gate-v3note-tsuite-* "$REPO/.secrets/l2-seeded-fake-cred.tmp" "$REPO/l2-seeded-untracked.tmp" ; }
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
mkfakes() { # a fake gitleaks (FAKE-LEAK-0123 fires rule fake-leak), a PATH without gitleaks, evidence.sh stubs for the gate's fail-open paths
  mkdir -p "$WORK/fakebin" "$WORK/nogl-bin"
  printf '#!/usr/bin/env bash\n[ "$1" = help ] && exit 0\nf="$2"; [ "$1" = detect ] && f="$4"\ngrep -q FAKE-LEAK-0123 "$f" && { echo "RuleID:      fake-leak"; exit 1; }\nexit 0\n' > "$WORK/fakebin/gitleaks"
  chmod +x "$WORK/fakebin/gitleaks"
  for b in bash sh grep sed awk date tr cat rm mv mkdir wc head tail dirname env python3 sha256sum cut sort find stat touch ls kill ps timeout git mktemp chmod cmp cp sleep; do
    p="$(command -v "$b" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$WORK/nogl-bin/$b" 2>/dev/null
  done
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/stub-ev-fail.sh"
  printf '#!/usr/bin/env bash\necho hello\n' > "$WORK/stub-ev-garbage.sh"
  printf '#!/usr/bin/env bash\nsleep 5\n' > "$WORK/stub-ev-slow.sh"
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "status --line" ] && exit 1\nexit 0\n' > "$WORK/stub-ev-line-fail.sh"
}

# --- v4 hook fixtures: the gate, spawn-log and recorded CC 2.1.309 payloads ----
SL="$REPO/.claude/hooks/spawn-log.sh"
FX="$REPO/tests/fixtures/cc-2.1.309"
gt() { # $1 = project dir, $2 = session id, $3 = JSON tail -> the gate's rc; stdout/stderr in $WORK/g.out / g.err (GATE_BIN = a gate copy)
  printf '{"session_id":"%s"%s}' "$2" "${3:-}" | CLAUDE_PROJECT_DIR="$1" bash "${GATE_BIN:-$GATE}" >"$WORK/g.out" 2>"$WORK/g.err"; echo $?
}
bgt() { # $1 = a recorded Stop payload -> its background_tasks as a JSON tail for gt
  python3 -I -c 'import json,sys; print(",\"background_tasks\":" + json.dumps(json.load(open(sys.argv[1]))["background_tasks"]))' "$1"
}
mktr() { # $1 = out, $2 = report, $3 = recorded transcript (default agent-checker.jsonl): its last SubagentHandback message, else its last assistant text, becomes the report
  python3 -I - "$FX/${3:-agent-checker.jsonl}" "$1" "$2" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
blocks = [b for r in rows if r["type"] == "assistant" for b in r["message"]["content"]]
hb = [b["input"] for b in blocks if b["type"] == "tool_use" and b["name"] == "SubagentHandback"]
if hb:
    hb[-1]["message"] = sys.argv[3]
else:
    [b for b in blocks if b["type"] == "text"][-1]["text"] = sys.argv[3]
open(sys.argv[2], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
}
mkstop() { # $1 = out, $2 = agent transcript ('-' = drop agent_transcript_path), $3 = nolast: drop last_assistant_message too
  # transcript_path moves under $WORK/tr, so the derived agent transcript path
  # (<transcript_path minus .jsonl>/subagents/agent-<agent_id>.jsonl) is writable.
  python3 -I - "$FX/subagentstop-checker.json" "$1" "$2" "${3:-}" "$WORK/tr" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["transcript_path"] = "%s/%s.jsonl" % (sys.argv[5], p["session_id"])
if sys.argv[3] == "-":
    del p["agent_transcript_path"]
else:
    p["agent_transcript_path"] = sys.argv[3]
if sys.argv[4] == "nolast":
    del p["last_assistant_message"]
json.dump(p, open(sys.argv[2], "w"))
PY
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
n="$(wc -l < "$EV" | tr -d ' ')"; [ "$n" -le 1600 ] && ok "evidence.sh has not run away ($n lines, guard 1600)" || no "evidence.sh is $n lines (guard 1600) — find out why it grew before raising the guard"
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
[ "$(tail -n 1 "$TRF" | cut -f3)" = "$(printf 'bash scripts/verify.sh\nscripts/verify.sh %s' "$(sha256sum < "$P/scripts/verify.sh" | cut -c1-64)" | sha256sum | cut -c1-12)" ] \
  && ok "cmd_sha = sha256(cmd + LF<path> <sha256> per repo file it names)[:12] (review #8)" || no "cmd_sha does not fold in scripts/verify.sh"
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
cedit 's/^- \[[ ~]\] (S[12] .*)$/- [x] \1 ✓ smoke@00000000 check@00000000/'; rc=$(ev "$P" lint); ck 0 "$rc" "lint checks the format only: two [x] with references pass"
cedit "s/^Goal: .*/Goal: $(printf '%*s' $((4200 - $(wc -c < "$WORK/c127") + 24)) '' | tr ' ' x)/"; rc=$(ev "$P" lint)
{ [ "$rc" = 1 ] && grep -qF "card is 4200 B (cap 4096)" "$WORK/ev.out"; } && ok "lint: a card over 4096 B" || no "oversized card passed (rc=$rc, $(wc -c < "$C") B)"
crestore; mklanes "$P" '@pair codex' "$LANE_SMOKE"; rc=$(ev "$P" lint)
{ [ "$rc" = 1 ] && grep -qF 'a card may raise pairing, never lower it' "$WORK/ev.out"; } && ok "lint: card pair: off under @pair codex" || no "pairing lowered by the card (rc=$rc)"
mklanes "$P" "$LANE_SMOKE"; cedit 's/pair: off/pair: codex/'; rc=$(ev "$P" lint); ck 0 "$rc" "a card may raise pairing (pair: codex without @pair)"
crestore; rc=$(ev "$P" approve)
{ [ "$rc" = 0 ] && grep -qF 'card approved at card:' "$WORK/ev.out" && awk -F'\t' -v d="$(cdig "$P" demo)" '$2 == "APPROVE" && $4 == "human" && $5 == d' "$PD" | grep -q .; } && ok "approve writes APPROVE with the card digest" || no "approve row wrong (rc=$rc)"
n="$(dl "$P" demo APPROVE)"; cedit 's/^Goal: .*/Goal:/'; rc=$(ev "$P" approve)
{ [ "$rc" = 1 ] && grep -qF 'approve refused — fix the card first:' "$WORK/ev.out" && [ "$(dl "$P" demo APPROVE)" = "$n" ]; } && ok "approve refuses a card that fails lint" || no "approve accepted a bad card (rc=$rc)"
cedit 's/^- \[ \] S2 (.*)$/- [x] S2 \1 ✓ smoke@00000000 check@00000000/'; ev "$P" status --line >/dev/null
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
pkt() { # $1 = dir, $2 = name, $3 = stage, $4 = unit, $5 = base [, $6 = since] -> packet path (06: D's packet header)
  local f="$1/.ai_context/tasks/demo/pair/$2.md"; mkdir -p "${f%/*}"
  { printf 'stage: %s\nunit: %s\nbase: %s\n' "$3" "$4" "$5"; [ -z "${6:-}" ] || printf 'since: %s\n' "$6"; printf '\n# Task\n'; } > "$f"; echo "$f"
}
res() { # $1 = packet, $2 = verdict, $3 = blocker, $4 = major -> result path
  printf 'run: completed\nverdict: %s\nbase: %s\nblocker: %s\nmajor: %s\nminor: 0\n\nfindings\n' "$2" "$(sed -n 's/^base: //p' "$1")" "$3" "$4" > "${1%.md}.result.md"; echo "${1%.md}.result.md"
}
cxp() { # $1 = dir, $2 = packet, $3 = result: evidence.sh codex for a completed run whose result the judge wrote with apply_patch (a transcript in the 0.165.0 shape)
  local ro="$WORK/ro-${2##*/}.jsonl" since; since="$(date -u +%Y-%m-%dT%H:%M:%S).000Z"
  ( cd "$1" && FAKE_HERDR_STATE="$WORK" bash "$REPO/tests/fake-herdr.sh" fake-rollout "${3#"$1"/}" "$ro" )
  ( cd "$1" && PAIR_ROLLOUT="$ro" PAIR_SINCE="$since" PAIR_RESULT_PATH="${3#"$1"/}" bash scripts/evidence.sh codex "$2" "$3" completed ok )
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
out="$(cxp "$Pp" "$k" "$(res "$k" pass 0 0)" 2>/dev/null)"; rc=$(ev "$Pp" "done" S1)
{ [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && [ "$out" = "$(lastid "$Pp" codex.jsonl)" ] && [ "$rc" = 1 ] && grep -qF 'no approving codex-slice review of S1' "$WORK/ev.out"; } \
  && ok "codex prints only the record id; the slice still needs its own review" || no "codex card record or slice gap wrong (out='$out' rc=$rc)"
k="$(pkt "$Pp" 002-slice-S1 slice S1 "$(git -C "$Pp" rev-parse HEAD)" "$(git -C "$Pp" rev-parse HEAD)")"; ( cd "$Pp" && bash scripts/evidence.sh codex "$k" "$(res "$k" pass 0 1)" completed ok >/dev/null 2>&1 ); rc=$(ev "$Pp" "done" S1)
{ [ "$rc" = 1 ] && [ "$(python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(r["verdict"], r["high"])' "$Pp/.claude/evidence/codex.jsonl")" = 'pass 1' ]; } \
  && ok "a pass carrying a major does not approve" || no "pass+major approved (rc=$rc)"
k="$(pkt "$Pp" 003-slice-S1 slice S1 "$(git -C "$Pp" rev-parse HEAD)" "$(git -C "$Pp" rev-parse HEAD)")"; ( cd "$Pp" && bash scripts/evidence.sh codex "$k" "${k%.md}.result.md" failed no_result >/dev/null 2>&1 )
k="$(pkt "$Pp" 004-slice-S1 slice S1 "$(git -C "$Pp" rev-parse HEAD)" "$(git -C "$Pp" rev-parse HEAD)")"; err="$(cd "$Pp" && bash scripts/evidence.sh codex "$k" "${k%.md}.result.md" failed no_result 2>&1 >/dev/null)"; rc=$(ev "$Pp" "done" S1)
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
k="$(pkt "$Pp" 005-slice-S2 slice S2 "$(git -C "$Pp" rev-parse HEAD)" "$(git -C "$Pp" rev-parse HEAD)")"; cxp "$Pp" "$k" "$(res "$k" pass 0 0)" >/dev/null 2>&1; rc=$(ev "$Pp" "done" S2)
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

echo "=== L1-30 · stop-gate v4: evidence references, Closed:, in-flight deferral, fail-open"
# The gate reads evidence only through `evidence.sh status --porcelain`. Fixture:
# a ready project (S1 done: lane, checker and DONE row), then S2 started. Every
# stop that should block gets its own session id, so the counted-block yield
# (L1-2b) never interferes.
P="$WORK/l130"; ready "$P"; ev "$P" start S2 >/dev/null
mklanes "$P" "$LANE_SMOKE" 'probe | src/ | 1 | ^x$ | false | touch gate-ran'   # never trusted; the gate must never run it (#42)
C="$P/.ai_context/tasks/demo/card.md"; DLG="$P/.ai_context/tasks/demo/donelog"
cp "$C" "$WORK/c130"
c30() { sed -E "$1" "$WORK/c130" > "$C"; }   # one edit on the saved card
s1id="$(lastid "$P" smoke.jsonl)"; tok="$(sed -n 's/^- \[x\] S1 .* ✓ //p' "$C")"
n0=$(wc -l < "$DLG"); mv "$P/.ai_context/tasks/CURRENT" "$WORK/cur130"; rc=$(gt "$P" tsuite-g1); mv "$WORK/cur130" "$P/.ai_context/tasks/CURRENT"
{ [ "$rc" = 0 ] && [ "$(wc -l < "$DLG")" = "$n0" ]; } && ok "no CURRENT: the gate passes and writes no row" || no "no-task stop wrong (rc=$rc)"
rc=$(gt "$P" tsuite-g2); ck 0 "$rc" "[x] S1 with holding references + [~] S2: the stop passes"
grep -q '^{"systemMessage":"claude-starter gate: .*demo' "$WORK/g.out" && ok "a passing stop shows the status line once (systemMessage)" || no "status line missing: $(cat "$WORK/g.out")"
rc=$(gt "$P" tsuite-g2); { [ "$rc" = 0 ] && [ ! -s "$WORK/g.out" ]; } && ok "same session, same status line: the next stop is silent" || no "status line repeated (rc=$rc): $(cat "$WORK/g.out")"
[ "$(dl "$P" demo BLOCK)" = 0 ] && ok "passing stops write no BLOCK row" || no "BLOCK rows on passing stops: $(dl "$P" demo BLOCK)"
c30 's/^- \[~\] S2 /- [x] S2 /'; rc=$(gt "$P" tsuite-g6); ck 2 "$rc" "an [x] with no ✓ reference blocks (noref)"
{ grep -qF 'S2 is marked [x] without an evidence reference' "$WORK/g.err" && grep -qF 'bash scripts/evidence.sh done' "$WORK/g.err"; } && ok "noref block names the slice and the only way to [x]" || no "noref stderr: $(head -c 400 "$WORK/g.err")"
awk -F'\t' '$2 == "BLOCK" {r = $0; n = NF} END {split(r, f, "\t"); exit !(n == 7 && f[3] == "S2" && f[4] == "noref")}' "$DLG" && ok "BLOCK row: 7 fields, slice S2, class noref" || no "BLOCK row wrong: $(grep BLOCK "$DLG" | tail -1)"
c30 "s/smoke@$s1id/smoke@00000000/"; rc=$(gt "$P" tsuite-g9)
{ [ "$rc" = 2 ] && grep -qF 'cites evidence that does not hold' "$WORK/g.err" && grep -qF 'not found' "$WORK/g.err"; } && ok "a cited id with no record blocks (badref, not found)" || no "unknown id (rc=$rc): $(head -c 400 "$WORK/g.err")"
c30 "s/smoke@$s1id/fork@$s1id/"; rc=$(gt "$P" tsuite-g10); ck 2 "$rc" "a record cited under another lane's name blocks"
echo broken > "$P/src/mode"; ev "$P" run smoke >/dev/null; fid="$(lastid "$P" smoke.jsonl)"; rm -f "$P/src/mode"
c30 "s/smoke@$s1id/smoke@$fid/"; rc=$(gt "$P" tsuite-g11); ck 2 "$rc" "citing a failing run blocks"
c30 "s/^- \[~\] S2 (.*)\$/- [x] S2 \1 ✓ $tok/"; rc=$(gt "$P" tsuite-g12); ck 2 "$rc" "S1's ids copied onto S2 block (no DONE row of S2 with these ids, P-4)"
cp "$P/.claude/done-lanes" "$WORK/dl130"; echo '@pair codex' >> "$P/.claude/done-lanes"
c30 's/pair: off/pair: codex/; s/^(- \[x\] S1 .*); codex: no/\1; codex: yes/'; rc=$(gt "$P" tsuite-g13)
{ [ "$rc" = 2 ] && grep -qF 'codex@ missing' "$WORK/g.err"; } && ok "pair on + codex: yes without codex@ blocks" || no "missing codex@ (rc=$rc): $(head -c 400 "$WORK/g.err")"
cp "$WORK/dl130" "$P/.claude/done-lanes"; cp "$WORK/c130" "$C"
git -C "$P" add .ai_context/tasks/demo/donelog; git -C "$P" commit -qm donelog   # H3b: foreign trusts committed rows only
mv "$P/.claude/evidence" "$WORK/ev130"; rc=$(gt "$P" tsuite-g14); mv "$WORK/ev130" "$P/.claude/evidence"
ck 0 "$rc" "ledger absent but the committed DONE row names the same ids: foreign, the stop passes (R3)"
ev "$P" run smoke >/dev/null; rep S2 pass | ev "$P" check S2 --agent fx --source human >/dev/null; ev "$P" "done" S2 >/dev/null
rep final pass | ev "$P" check final --agent fx --source human >/dev/null; rc0=$(ev "$P" close); rc=$(gt "$P" tsuite-g15)
{ [ "$rc0" = 0 ] && [ "$rc" = 0 ]; } && ok "closed at the current content: the stop passes (R11)" || no "close rc=$rc0 ($(head -c 300 "$WORK/ev.out")), gate rc=$rc"
cp "$C" "$WORK/c130c"
echo b >> "$P/src/a.txt"; rc=$(gt "$P" tsuite-g16); echo a > "$P/src/a.txt"
{ [ "$rc" = 2 ] && grep -qF 'not fresh' "$WORK/g.err" && grep -qF 'smoke' "$WORK/g.err"; } && ok "lane content changed after close: Closed: is stale and blocks" || no "stale close (rc=$rc): $(head -c 400 "$WORK/g.err")"
echo r > "$P/README.md"; rc=$(gt "$P" tsuite-g17)
{ [ "$rc" = 2 ] && grep -qF 'not fresh' "$WORK/g.err"; } && ok "a new file outside every lane also stales Closed: (checker final binds the whole tree)" || no "out-of-lane change after close (rc=$rc)"
rm -f "$P/README.md"; rc=$(gt "$P" tsuite-g18); ck 0 "$rc" "content back to the closed tree: the stop passes"
git -C "$P" add .ai_context/tasks/demo/donelog; git -C "$P" commit -qm donelog
mv "$P/.claude/evidence" "$WORK/ev130"; rc=$(gt "$P" tsuite-g19); mv "$WORK/ev130" "$P/.claude/evidence"
ck 0 "$rc" "ledger absent, a committed CLOSE row at the current tree: foreign close passes"
sed -E 's/^(- \[x\] S2 .*) ✓ .*$/\1/' "$WORK/c130c" > "$C"
LK="$P/.claude/evidence/locks/run-smoke.lock"; mkdir -p "${LK%/*}"
bash -c 'exec -a evidence.sh sleep 30' & lp=$!
printf '%s\trun\tsmoke\tS2\t%s\n' "$lp" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$LK"
rc=$(gt "$P" tsuite-g20); ck 0 "$rc" "a live evidence.sh run lock defers the stop (D3)"
awk -F'\t' '$2 == "WAITING" && $4 ~ /run:smoke/' "$DLG" | grep -q . && ok "WAITING row names run:smoke" || no "WAITING row missing: $(grep WAITING "$DLG")"
grep -qF 'in flight; evidence check deferred until it reports' "$WORK/g.out" && ok "deferral surfaces a systemMessage" || no "deferral message missing: $(cat "$WORK/g.out")"
sleep 0 & dp=$!; wait "$dp"
printf '%s\trun\tsmoke\tS2\t-\n' "$dp" > "$LK"; rc=$(gt "$P" tsuite-g23); ck 2 "$rc" "a lock whose pid has exited does not defer"
sleep 30 & sp=$!
printf '%s\trun\tsmoke\tS2\t-\n' "$sp" > "$LK"; rc=$(gt "$P" tsuite-g24); ck 2 "$rc" "a live pid that is not evidence.sh (pid reuse) does not defer"
rm -f "$LK"; kill "$lp" "$sp" 2>/dev/null; wait "$lp" "$sp" 2>/dev/null
rc=$(gt "$P" tsuite-g25 "$(bgt "$FX/stop-background-subagent.json")"); ck 0 "$rc" "a running background checker (recorded CC 2.1.309 payload) defers the stop"
rc=$(gt "$P" tsuite-g26 ',"background_tasks":[{"id":"b1","type":"shell","status":"running","description":"grep \"type\":\"subagent\" log","command":"sleep 60"}]')
ck 2 "$rc" "a background shell whose description quotes the subagent key (JSON-escaped) does not defer"
cp "$WORK/c130c" "$C"; cp "$P/scripts/evidence.sh" "$WORK/ev130.sh"
cp "$WORK/stub-ev-fail.sh" "$P/scripts/evidence.sh"; rc=$(gt "$P" tsuite-g27); ck 0 "$rc" "evidence.sh exits 1: the gate fails open (D5)"
{ grep -qF 'internal error' "$WORK/g.out" && grep -qF 'not blocking this stop' "$WORK/g.out"; } && ok "fail-open says so in a systemMessage" || no "fail-open message: $(cat "$WORK/g.out")"
[ "$(dl "$P" demo GATE-ERROR)" = 1 ] && ok "fail-open logs a GATE-ERROR row" || no "GATE-ERROR rows: $(dl "$P" demo GATE-ERROR)"
cp "$WORK/stub-ev-garbage.sh" "$P/scripts/evidence.sh"; rc=$(gt "$P" tsuite-g30)
{ [ "$rc" = 0 ] && [ "$(dl "$P" demo GATE-ERROR)" = 2 ]; } && ok "unparseable porcelain fails open (+1 GATE-ERROR)" || no "garbage porcelain (rc=$rc, rows $(dl "$P" demo GATE-ERROR))"
cp "$WORK/stub-ev-slow.sh" "$P/scripts/evidence.sh"; rc=$(CLAUDE_STARTER_GATE_STATUS_TIMEOUT=1 gt "$P" tsuite-g31); cp "$WORK/ev130.sh" "$P/scripts/evidence.sh"
{ [ "$rc" = 0 ] && [ "$(dl "$P" demo GATE-ERROR)" = 3 ]; } && ok "a hung evidence.sh times out and fails open (+1 GATE-ERROR)" || no "slow porcelain (rc=$rc, rows $(dl "$P" demo GATE-ERROR))"
mkdir -p "$WORK/g31" "$WORK/g32"; cp "$REPO/.claude/hooks/guard-patterns.sh" "$WORK/g31/"; cp "$GATE" "$WORK/g32/"
awk '/^# --- 1\. Setup gate/ {print "if ;; then"} {print}' "$GATE" > "$WORK/g31/stop-gate.sh"
rc=$(GATE_BIN="$WORK/g31/stop-gate.sh" gt "$P" tsuite-g32)
{ [ "$rc" = 0 ] && [ "$(dl "$P" demo GATE-ERROR)" = 4 ] && ! grep -qF 'claude-starter-gate: BLOCK' "$WORK/g.out"; } && ok "a bash syntax error in the gate (rc 2, no marker) fails open" || no "syntax error path (rc=$rc, rows $(dl "$P" demo GATE-ERROR)): $(cat "$WORK/g.out")"
rc=$(GATE_BIN="$WORK/g32/stop-gate.sh" gt "$P" tsuite-g33)
{ [ "$rc" = 0 ] && [ "$(dl "$P" demo GATE-ERROR)" = 5 ]; } && ok "guard-patterns.sh missing: the evidence gate fails open" || no "missing helpers (rc=$rc, rows $(dl "$P" demo GATE-ERROR))"
cp "$P/CLAUDE.md" "$WORK/cl130"; printf '# t\n<!-- claude-starter: UNCONFIGURED -->\n' > "$P/CLAUDE.md"
rc=$(GATE_BIN="$WORK/g32/stop-gate.sh" gt "$P" tsuite-g34); cp "$WORK/cl130" "$P/CLAUDE.md"
{ [ "$rc" = 2 ] && grep -qF 'claude-starter-gate: BLOCK' "$WORK/g.out"; } && ok "guard-patterns.sh missing: the setup gate still blocks (fallback sentinel)" || no "fallback setup gate (rc=$rc)"
# Idle (D6, R13): card, donelog and the task/<slug> branch all a week old.
Pi="$WORK/l130i"; OLD=1 mkproj "$Pi"; mkcard "$Pi" demo off '- [x] S1 first — lanes: smoke ; codex: no'
Ti="$Pi/.ai_context/tasks/demo"; touch -d '8 days ago' "$Ti/card.md" "$Ti/donelog"
rc=$(gt "$Pi" tsuite-g35); ck 0 "$rc" "an idle task is not checked (card, donelog, task/demo 8 days old)"
[ "$(dl "$Pi" demo BLOCK)" = 0 ] && ok "an idle task gets no BLOCK row" || no "idle task logged a BLOCK"
touch "$Ti/card.md"; rc=$(gt "$Pi" tsuite-g37); ck 2 "$rc" "editing the card re-activates the task"
touch -d '8 days ago' "$Ti/card.md" "$Ti/donelog"; echo n > "$Pi/src/n.txt"; git -C "$Pi" add src/n.txt; git -C "$Pi" commit -qm now
rc=$(gt "$Pi" tsuite-g38); ck 2 "$rc" "a fresh commit on task/demo keeps an old card active"
# v3 leftovers (R15): an empty CURRENT, a dir without card.md, a v3 plan.md task.
CUR="$P/.ai_context/tasks/CURRENT"; cp "$CUR" "$WORK/cur130"
: > "$CUR"; rc=$(gt "$P" tsuite-g39); ck 0 "$rc" "an empty CURRENT is no task"
mkdir -p "$P/.ai_context/tasks/ghost"; echo ghost > "$CUR"; rc=$(gt "$P" tsuite-g40); ck 0 "$rc" "CURRENT naming a dir with neither card.md nor plan.md is no task"
mkdir -p "$P/.ai_context/tasks/v3t"; printf '# Plan: v3\n## M1: x [in_progress]\n- verify: `false`\n' > "$P/.ai_context/tasks/v3t/plan.md"; echo v3t > "$CUR"
rc=$(gt "$P" tsuite-g41); { [ "$rc" = 0 ] && grep -qF 'a v3 plan.md task without card.md' "$WORK/g.out"; } && ok "a v3 plan.md task passes with a one-line note (R15)" || no "v3 task (rc=$rc): $(cat "$WORK/g.out")"
cp "$WORK/cur130" "$CUR"
{ [ ! -e "$P/gate-ran" ] && [ ! -e gate-ran ]; } && ok "the gate never ran a lane (the untrusted probe lane least of all)" || no "the gate executed a lane command"
grep -q 'no verdict' "$GATE" && no "stop-gate carries a Codex no-verdict block (R12: evidence.sh owns it)" || ok "no Codex no-verdict block in the gate (R12)"

echo "=== L1-2b · stop-gate: counted blocks — third stop on the same card and content yields"
# Hand-written card, no git: S2 is [x] with no ✓ reference (noref), so the
# gate decides without evidence.sh. The count key is the card bytes + content.
D="$WORK/l12b"; T="$D/.ai_context/tasks/demo"; mkdir -p "$T"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
{ echo '# Demo task'; echo '<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->'
  echo 'Goal: count the blocks'; echo 'Done when: S2 cites evidence'; echo '## Slices'
  echo '- [~] S1 first — lanes: smoke ; codex: no'; echo '- [x] S2 second — lanes: smoke ; codex: no'; } > "$T/card.md"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "noref block 1 blocks"
printf '{"stop_hook_active": true, "session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "block 2 blocks despite stop_hook_active (the gate counts for itself)"
out=$(printf '{"stop_hook_active": true, "session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "third stop on the same card and content yields"
echo "$out" | grep -q '"systemMessage"' && ok "yield carries a systemMessage for the human" || no "yield lacks systemMessage"
{ echo "$out" | grep -q 'task demo is BLOCKED' && echo "$out" | grep -q 'noref'; } && ok "systemMessage names the task and the finding class" || no "systemMessage vague: $out"
[ "$(dl "$D" demo STUCK)" = 1 ] && ok "donelog STUCK row written" || no "STUCK row missing"
[ "$(dl "$D" demo BLOCK)" = 2 ] && ok "each counted block logged a BLOCK row (2)" || no "BLOCK rows: want 2 got $(dl "$D" demo BLOCK)"
# F10: the yield is ONE handoff event — stop 4 keeps yielding (and keeps
# the human signal) but appends no second STUCK row.
out=$(printf '{"stop_hook_active": true, "session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" 2>/dev/null); rc=$?
ck 0 $rc "fourth stop still yields"
echo "$out" | grep -q '"systemMessage"' && ok "repeat yield keeps pinging the human" || no "repeat yield lost the systemMessage"
[ "$(dl "$D" demo STUCK)" = 1 ] && ok "exactly one STUCK row after four stops (no over-count)" || no "STUCK rows: want 1 got $(dl "$D" demo STUCK)"
# A changed card is a new key: a fresh count, and a second handoff when it yields.
sed -i 's/^Goal: count the blocks$/Goal: count the blocks again/' "$T/card.md"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "an edited card starts a fresh count (blocks again)"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "new key: block 2"
printf '{"session_id": "tsuite-red"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 0 $? "new key: third stop yields again"
[ "$(dl "$D" demo STUCK)" = 2 ] && ok "the new key logged its own STUCK row" || no "STUCK rows: want 2 got $(dl "$D" demo STUCK)"
[ "$(dl "$D" demo BLOCK)" = 4 ] && ok "BLOCK rows: 2 per key (4)" || no "BLOCK rows: want 4 got $(dl "$D" demo BLOCK)"
printf '{"session_id": "tsuite-red2"}' | CLAUDE_PROJECT_DIR="$D" bash "$GATE" >/dev/null 2>&1
ck 2 $? "new session counts from zero"

echo "=== L1-2d · spawn-log: SPAWN rows, in-flight deferral, wiring (v4)"
D="$WORK/l12d"; T="$D/.ai_context/tasks/demo"; mkdir -p "$T"
printf '# ok\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
# unit: no active task => no rows anywhere
printf '{}' | CLAUDE_PROJECT_DIR="$D" bash "$SL" executor start
ck 0 $? "spawn-log without CURRENT is a no-op"
[ ! -e "$T/donelog" ] && ok "no donelog created without a task" || no "stray donelog"
echo demo > "$D/.ai_context/tasks/CURRENT"
{ echo '# Demo task'; echo '<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->'; echo 'Goal: spawn rows'; echo '## Slices'
  echo '- [ ] S1 first — lanes: smoke ; codex: no'; echo '- [ ] S2 second — lanes: smoke ; codex: no'; } > "$T/card.md"
# nothing in progress yet -> slice '-'
printf '{}' | CLAUDE_PROJECT_DIR="$D" bash "$SL" executor start
awk -F'\t' '$2 == "SPAWN" && $3 == "-" && $4 == "executor"' "$T/donelog" | grep -q . && ok "a spawn before any [~] slice carries '-'" || no "pre-slice SPAWN row wrong: $(cat "$T/donelog")"
sed -i 's/^- \[ \] S2 /- [~] S2 /' "$T/card.md"
printf '{}' | CLAUDE_PROJECT_DIR="$D" bash "$SL" executor start
[ "$(tail -n 1 "$T/donelog" | cut -f2-)" = "$(printf 'SPAWN\tS2\texecutor\t-\t-\tstart')" ] && ok "executor SPAWN row attributed to the [~] slice (7 fields)" || no "SPAWN row wrong: $(tail -n 1 "$T/donelog")"
# in-flight deferral reads the Stop payload: an executor Claude Code lists as
# a running background task defers every stop (WAITING row) — its completion
# notification is the wake signal. S1 is a noref [x], so a stop that is not
# deferred blocks.
sed -i 's/^- \[ \] S1 /- [x] S1 /' "$T/card.md"
BT_EXEC=',"background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"Execute S2","agent_type":"executor"}]'
rc=$(gt "$D" tsuite-sl1 "$BT_EXEC"); ck 0 "$rc" "running background executor defers the gate (in flight)"
awk -F'\t' '$2 == "WAITING" && $4 ~ /subagent:executor/' "$T/donelog" | grep -q . && ok "WAITING row records the deferral" || no "WAITING row missing: $(cat "$T/donelog")"
grep -qF 'in flight; evidence check deferred until it reports' "$WORK/g.out" && ok "deferral surfaces a systemMessage" || no "deferral systemMessage missing"
rc=$(gt "$D" tsuite-sl1 "$BT_EXEC"); ck 0 "$rc" "still running at the next stop => deferred again (no per-spawn cap)"
[ "$(dl "$D" demo WAITING)" = 2 ] && ok "one WAITING row per deferred stop" || no "WAITING rows: want 2 got $(dl "$D" demo WAITING)"
# codex_desktop 2026-10-21 replay: a fresh SPAWN row but nothing listed => the
# gate checks. Row freshness never defers — background agents log a row per re-wake.
rc=$(gt "$D" tsuite-sl1b ',"background_tasks":[]'); ck 2 "$rc" "finished executor + fresh SPAWN row => the gate checks (no dark deferral)"
rc=$(gt "$D" tsuite-sl1c "$(bgt "$FX/stop-background.json")"); ck 2 "$rc" "a running background shell (recorded CC 2.1.309 payload) does not defer (D3)"
rc=$(gt "$D" tsuite-sl1d); ck 2 "$rc" "payload without background_tasks: the gate checks (fails loud, never dark)"
# wiring: settings.json routes both events, by agent name, with the phase in argv
{ grep -q '"SubagentStart"' "$REPO/.claude/settings.json" && grep -q '"SubagentStop"' "$REPO/.claude/settings.json"; } && ok "settings routes SubagentStart and SubagentStop" || no "Subagent events missing from settings"
{ grep -q 'spawn-log.sh\\" executor start"' "$REPO/.claude/settings.json" && grep -q 'spawn-log.sh\\" executor stop"' "$REPO/.claude/settings.json"; } && ok "executor start/stop wired" || no "executor wiring missing"
{ grep -q 'spawn-log.sh\\" checker start"' "$REPO/.claude/settings.json" && grep -q 'spawn-log.sh\\" checker stop"' "$REPO/.claude/settings.json"; } && ok "checker start/stop wired" || no "checker wiring missing"
python3 - "$REPO/.claude/settings.json" <<'PY' && ok "each Subagent event matches exactly executor and checker (no retired agent)" || no "Subagent matchers wrong (retired agent or regex matcher)"
import json, re, sys
h = json.load(open(sys.argv[1]))["hooks"]
gone = re.compile("scout|planner|plan-critic|verifier|reframer|final-verifier|other")
ok = all(sorted(e["matcher"] for e in h[ev]) == ["checker", "executor"] and not any(gone.search(e["matcher"]) for e in h[ev])
         for ev in ("SubagentStart", "SubagentStop"))
sys.exit(0 if ok else 1)
PY
CLAUDE_PROJECT_DIR="$D" bash "$SL" checker start < "$FX/subagentstart-checker.json"
awk -F'\t' '$2 == "SPAWN" && $4 == "checker" && $6 == "a0000000000000003"' "$T/donelog" | grep -q . && ok "checker SPAWN row (agent_id from the recorded payload)" || no "checker SPAWN row wrong: $(tail -n 1 "$T/donelog")"
grep -q 'Edit(./.ai_context/tasks/\*\*/spawnlog)' "$REPO/.claude/settings.json" && ok "spawnlog Edit-denied" || no "spawnlog not Edit-denied"

echo "=== L1-29 · spawn-log: the checker's report becomes a checker record (SubagentStop)"
# tests/fixtures/cc-2.1.309/ — Source: Claude Code 2.1.309, two `claude -p
# --model sonnet` runs on 2026-10-28 (foreground and background checker),
# recorded by hooks that saved stdin verbatim; ids, session paths and project
# paths replaced with fixed fakes. agent-checker-handback.jsonl is synthetic:
# same row shape as a real interactive-session subagent that handed back via
# the SubagentHandback tool (input.message = report), built from
# agent-checker.jsonl's report text.
Ps="$WORK/l129s"; T="$Ps/.ai_context/tasks/demo"; mkdir -p "$T" "$Ps/scripts" "$WORK/tr"
{ echo '# Demo task'; echo '<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->'; echo 'Goal: reports'; echo '## Slices'
  echo '- [~] S1 first — lanes: smoke ; codex: no'; } > "$T/card.md"
echo demo > "$Ps/.ai_context/tasks/CURRENT"
cat > "$Ps/scripts/evidence.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$WORK/stub.argv"; cat > "$WORK/stub.stdin"; echo 'check S1 pass deadbeef01'
EOF
sl() { CLAUDE_PROJECT_DIR="$1" bash "$SL" "$2" "$3" < "$4" >/dev/null 2>&1; }   # $1 project, $2 kind, $3 phase, $4 payload file
mktr "$WORK/t1" "$(rep S1 pass)" agent-checker-handback.jsonl; mkstop "$WORK/p1" "$WORK/t1"
sl "$Ps" checker stop "$WORK/p1"
{ grep -qx 'checker-verdict: S1 pass' "$WORK/stub.stdin" && grep -q 'fixture claim' "$WORK/stub.stdin"; } && ok "the handed-back report reaches evidence.sh check on stdin" || no "report not passed: $(head -c 300 "$WORK/stub.stdin" 2>/dev/null)"
a1="$(cat "$WORK/stub.argv" 2>/dev/null)"
mktr "$WORK/t2" "$(rep S1 pass)"; mkstop "$WORK/p2" "$WORK/t2"; sl "$Ps" checker stop "$WORK/p2"
want2="$(python3 -I -c 'import json,sys; print("last_message" if "checker-verdict:" in json.load(open(sys.argv[1]))["last_assistant_message"] else "transcript")' "$FX/subagentstop-checker.json")"
{ [ "$a1" = 'check S1 --agent a0000000000000003 --source handback' ] && [ "$(cat "$WORK/stub.argv")" = "check S1 --agent a0000000000000003 --source $want2" ]; } && ok "argv: check <[~] slice> --agent <id> --source handback | $want2 (no handback)" || no "argv wrong: [$a1] [$(cat "$WORK/stub.argv")]"
dv="$WORK/tr/$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_id"])' "$FX/subagentstop-checker.json")/subagents"
mkdir -p "$dv"; mktr "$dv/agent-a0000000000000003.jsonl" "$(rep S1 pass 'VERIFIED (L4) derived path claim — cat x')" agent-checker-handback.jsonl
mkstop "$WORK/p3" -; rm -f "$WORK/stub.stdin"; sl "$Ps" checker stop "$WORK/p3"
grep -q 'derived path claim' "$WORK/stub.stdin" 2>/dev/null && ok "no agent_transcript_path: the derived <session>/subagents/agent-<id>.jsonl is read" || no "derived transcript path not used"
rm -f "$dv/agent-a0000000000000003.jsonl"; mkstop "$WORK/p4" - nolast; sl "$Ps" checker stop "$WORK/p4"
{ grep -q -- '--source none$' "$WORK/stub.argv" && [ ! -s "$WORK/stub.stdin" ]; } && ok "nothing captured: --source none with an empty report (done refuses it)" || no "uncaptured path: [$(cat "$WORK/stub.argv")]"
echo 'not json{' | CLAUDE_PROJECT_DIR="$Ps" bash "$SL" checker stop >/dev/null 2>&1; ck 0 $? "a garbage payload never fails the hook"
rm -f "$WORK/stub.argv"; n0=$(wc -l < "$T/donelog")
sl "$Ps" executor stop "$FX/subagentstop-executor.json"
{ [ "$(tail -n 1 "$T/donelog" | cut -f2,4,7)" = "$(printf 'RETURN\texecutor\treturned')" ] && [ ! -e "$WORK/stub.argv" ]; } && ok "executor stop: one RETURN row, evidence.sh not called" || no "executor stop wrong: $(tail -n 1 "$T/donelog")"
n0=$(wc -l < "$T/donelog"); printf '{}' | CLAUDE_PROJECT_DIR="$Ps" bash "$SL" other start
[ "$(wc -l < "$T/donelog")" = "$n0" ] && ok "an unknown kind writes nothing" || no "other start wrote a row"
printf '{"agent_type":"executor"}' | CLAUDE_PROJECT_DIR="$Ps" bash "$SL" checker start
[ "$(tail -n 1 "$T/donelog" | cut -f2,4)" = "$(printf 'SPAWN\tchecker')" ] && ok "the kind comes from argv, never the payload" || no "payload overrode argv: $(tail -n 1 "$T/donelog")"
Pr="$WORK/l129r"; mkproj "$Pr"; mklanes "$Pr" "$LANE_SMOKE"; ev "$Pr" trust smoke >/dev/null
mkcard "$Pr" demo off '- [~] S1 first — lanes: smoke ; codex: no'
ev "$Pr" approve >/dev/null; ev "$Pr" start S1 >/dev/null; ev "$Pr" run smoke >/dev/null
mktr "$WORK/t9" "$(rep S1 pass 'NOT VERIFIED (L2) a — b')" agent-checker-handback.jsonl; mkstop "$WORK/p9" "$WORK/t9"; sl "$Pr" checker stop "$WORK/p9"
[ "$(awk -F'\t' '$2 == "CHECK" {v = $7} END {print v}' "$Pr/.ai_context/tasks/demo/donelog")" = fail ] && ok "a NOT VERIFIED claim records a failing check" || no "CHECK row: $(grep CHECK "$Pr/.ai_context/tasks/demo/donelog")"
rc=$(ev "$Pr" "done" S1); ck 1 "$rc" "done refuses a slice whose latest check failed"
mktr "$WORK/t11" "$(rep S1 pass)" agent-checker-handback.jsonl; mkstop "$WORK/p11" "$WORK/t11"; sl "$Pr" checker stop "$WORK/p11"
[ "$(awk -F'\t' '$2 == "CHECK" {v = $7} END {print v}' "$Pr/.ai_context/tasks/demo/donelog")" = pass ] && ok "a VERIFIED report records a passing check" || no "CHECK row: $(grep CHECK "$Pr/.ai_context/tasks/demo/donelog" | tail -1)"
ret="$(awk -F'\t' '$2 == "RETURN" {v = $7} END {print v}' "$Pr/.ai_context/tasks/demo/donelog")"
rc=$(ev "$Pr" "done" S1); ck 0 "$rc" "done accepts the hook-recorded passing check"
[ "$ret" = "checked $(lastid "$Pr" checker.jsonl) pass" ] && ok "RETURN row names the checker record and its verdict" || no "RETURN row: [$ret] want checked $(lastid "$Pr" checker.jsonl) pass"
dl7 "$Pr" demo && ok "spawn-log + evidence.sh donelog: 7 fields, UTC ts on every row" || no "donelog rows malformed: $(head -c 400 "$Pr/.ai_context/tasks/demo/donelog")"
n0=$(wc -l < "$T/donelog"); o=""
for a in verifier executor 'verifier start'; do
  # shellcheck disable=SC2086
  o="$o$(printf '{}' | CLAUDE_PROJECT_DIR="$Ps" bash "$SL" $a 2>&1; echo "rc=$?;")"
done
{ [ "$o" = 'rc=0;rc=0;rc=0;' ] && [ "$(wc -l < "$T/donelog")" = "$n0" ]; } && ok "v3 one-argument calls and retired kinds: silent no-ops (R15)" || no "v3 argv not a no-op: $o"

echo "=== L1-3 · session-start: injection + warnings"
D="$WORK/l13"; mkdir -p "$D/.ai_context/tasks/demo"
printf '# n\n- **Dev:** `<command>`\n' > "$D/CLAUDE.md"
printf 'Last updated: 2026-01-01\nbody\n' > "$D/.ai_context/state.md"
printf 'idx\n' > "$D/.ai_context/INDEX.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
printf '# Demo task\n<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->\nGoal: CARD-MARKER goal\n## Slices\n- [~] S1 first — lanes: smoke ; codex: no\n' > "$D/.ai_context/tasks/demo/card.md"
printf 'lesson-x\n' > "$D/.ai_context/tasks/demo/lessons.md"
printf 'SPEC-MARKER goal line\n' > "$D/.ai_context/tasks/demo/spec.md"
printf 'BRIEF-MARKER map\n' > "$D/.ai_context/tasks/demo/brief.md"
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" commit -qm x
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'SETUP REQUIRED' && ok "newborn instruction emitted" || no "newborn instruction missing"
echo "$out" | grep -q 'INDEX.md ===' && ok "INDEX injected" || no "INDEX missing"
echo "$out" | grep -q 'CARD-MARKER' && ok "active task card injected" || no "card injection missing"
echo "$out" | grep -qE 'SPEC-MARKER|lesson-x' && no "v3 spec.md/lessons.md still injected" || ok "spec.md and lessons.md are not injected (v4: the card is the anchor)"
echo "$out" | grep -q 'BRIEF-MARKER' && no "brief.md injected" || ok "brief.md is not injected"
echo "$out" | grep -q 'days ago' && ok "stale-state warning (S3)" || no "stale warning missing"
echo "$out" | grep -q 'ended without /wrap' && ok "unwrapped-session warning" || no "unwrapped warning missing"
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
echo "$out" | grep -q 'but its card.md is missing' && ok "dangling CURRENT warned" || no "dangling CURRENT not warned"

echo "=== L1-3c · task lifecycle warnings: Closed but not wrapped, notes.md size"
D="$WORK/l13e"; T="$D/.ai_context/tasks/demo"; mkdir -p "$T"
printf '# n\n## Commands\n- Test: `true`\n' > "$D/CLAUDE.md"
printf '_Last updated: %s_\n' "$(date +%F)" > "$D/.ai_context/state.md"
printf 'idx\n' > "$D/.ai_context/INDEX.md"
echo demo > "$D/.ai_context/tasks/CURRENT"
printf '# Demo task\n<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->\nGoal: closed\n## Slices\n- [x] S1 first — lanes: smoke ; codex: no ✓ smoke@0123456789ab check@0123456789ac\nClosed: tree:0123456789ab 2026-10-28\n' > "$T/card.md"
head -c 100 /dev/zero | tr '\0' n > "$T/notes.md"
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'is Closed but tasks/CURRENT still points at it' && ok "Closed card + CURRENT nudges /wrap" || no "closed-but-unwrapped state got no nudge"
echo "$out" | grep -q 'notes.md is' && no "small notes.md falsely size-warned" || ok "small notes.md stays quiet"
sed -i '/^Closed:/d' "$T/card.md"
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -q 'is Closed but' && no "open task falsely nudged to wrap" || ok "a card without Closed: gets no wrap nudge"
head -c 17000 /dev/zero | tr '\0' n > "$T/notes.md"
out=$(CLAUDE_PROJECT_DIR="$D" bash "$SS" </dev/null 2>&1)
echo "$out" | grep -qF 'WARNING: tasks/demo/notes.md is 17000 bytes (cap 16384)' && ok "oversized notes.md warned (D13)" || no "17 KB notes.md went unseen"

echo "=== L1-31 · session-start v4: card cap, idle, evidence line, CLAUDE.md size"
D="$WORK/l131"; mkproj "$D"; mklanes "$D" "$LANE_SMOKE"
printf '_Last updated: %s_\n' "$(date +%F)" > "$D/.ai_context/state.md"; printf 'idx\n' > "$D/.ai_context/INDEX.md"
mkcard "$D" demo off '- [~] S1 first — lanes: smoke ; codex: no'; C="$D/.ai_context/tasks/demo/card.md"; cp "$C" "$WORK/c131"
printf 'NOTES-MARKER\n' > "$D/.ai_context/tasks/demo/notes.md"
ss() { CLAUDE_PROJECT_DIR="$1" bash "$SS" </dev/null > "$WORK/ss.out" 2>&1; }
ss "$D"
grep -q 'NOTES-MARKER' "$WORK/ss.out" && no "notes.md injected" || ok "notes.md is never injected"
grep -qF '=== evidence (scripts/evidence.sh status --line) ===' "$WORK/ss.out" && ok "one evidence status line rides along" || no "evidence line missing: $(tail -n 5 "$WORK/ss.out")"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("".join(("CARD-HEAD" if i == 0 else "CARD-TAIL" if i == 90 else "- filler %03d" % i).ljust(49, ".") + "\n" for i in range(100)))' "$C"
ss "$D"
{ grep -q 'CARD-HEAD' "$WORK/ss.out" && ! grep -q 'CARD-TAIL' "$WORK/ss.out"; } && ok "a 5000 B card is injected up to the cap (head in, byte-4500 tail out)" || no "oversized card injection wrong"
{ grep -qF 'TRUNCATED: first 4096 of 5000 bytes' "$WORK/ss.out" && grep -qF 'WARNING: card.md is 5000 bytes (cap 4096)' "$WORK/ss.out"; } && ok "truncation is announced (header + WARNING)" || no "truncation not announced"
python3 -I - "$WORK/ss.out" "$C" <<'PY' && ok "the injected part is <= 4096 B of whole card lines" || no "truncated injection is not a whole-line prefix <= 4096 B"
import sys
out, card = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
s = out.index(b"\n", out.index(b"(TRUNCATED: first 4096")) + 1
body = out[s:out.index(b"WARNING: card.md is", s)]
sys.exit(0 if len(body) <= 4096 and body.endswith(b"\n") and card.startswith(body) else 1)
PY
cp "$WORK/c131" "$C"
Di="$WORK/l131i"; OLD=1 mkproj "$Di"; mkcard "$Di" demo off '- [~] S1 first — lanes: smoke ; codex: no'
touch -d '8 days ago' "$Di/.ai_context/tasks/demo/card.md" "$Di/.ai_context/tasks/demo/donelog"
ss "$Di"
grep -q 'CARD-MARKER' "$WORK/ss.out" && no "an idle card was injected" || ok "an idle card (card, donelog, task/demo 8 days old) is not injected"
grep -q 'has been idle 8 days' "$WORK/ss.out" && ok "the idle task gets a one-line NOTE" || no "idle NOTE missing: $(cat "$WORK/ss.out")"
touch "$Di/.ai_context/tasks/demo/card.md"; ss "$Di"
grep -q 'CARD-MARKER' "$WORK/ss.out" && ok "editing the card re-activates injection" || no "touched card still idle"
cp "$D/CLAUDE.md" "$WORK/cl131"; { cat "$WORK/cl131"; head -c $((21000 - $(wc -c < "$WORK/cl131"))) /dev/zero | tr '\0' x; } > "$D/CLAUDE.md"
ss "$D"
grep -qF 'WARNING: CLAUDE.md is 21000 bytes (cap 20480)' "$WORK/ss.out" && ok "CLAUDE.md over 20480 B warned" || no "21000 B CLAUDE.md not warned"
mkdir -p "$WORK/l131n"; cp "$D/CLAUDE.md" "$WORK/l131n/"; ss "$WORK/l131n"
grep -qF 'WARNING: CLAUDE.md is 21000 bytes (cap 20480)' "$WORK/ss.out" && ok "the CLAUDE.md warning needs no .ai_context" || no "CLAUDE.md warning gated on .ai_context"
cp "$WORK/cl131" "$D/CLAUDE.md"; mv "$D/scripts/evidence.sh" "$WORK/ev131.sh"; ss "$D"
{ grep -qF 'WARNING: scripts/evidence.sh is missing' "$WORK/ss.out" && grep -q 'CARD-MARKER' "$WORK/ss.out"; } && ok "missing evidence.sh warned, card still injected" || no "missing evidence.sh path wrong"
cp "$WORK/stub-ev-line-fail.sh" "$D/scripts/evidence.sh"; ss "$D"; mv "$WORK/ev131.sh" "$D/scripts/evidence.sh"
grep -qF 'WARNING: evidence.sh status --line failed (rc 1)' "$WORK/ss.out" && ok "a failing status --line is a WARNING, not silence" || no "status --line failure unseen"
mkdir -p "$D/.ai_context/tasks/v3t"; printf '# Plan: v3\n## M1: x [in_progress]\n' > "$D/.ai_context/tasks/v3t/plan.md"; echo v3t > "$D/.ai_context/tasks/CURRENT"; ss "$D"
{ grep -q 'a v3 plan.md task without card.md' "$WORK/ss.out" && ! grep -q 'CARD-MARKER' "$WORK/ss.out"; } && ok "a v3 plan.md CURRENT is named, nothing injected (R15)" || no "v3 CURRENT path wrong"
echo demo > "$D/.ai_context/tasks/CURRENT"

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
  D="$WORK/l14a/existing"; mkdir -p "$D/src"; echo 'x=1' > "$D/src/m.py"
  "$REPO/sync-project.sh" "$D" >/dev/null 2>&1 && no "non-starter accepted without --adopt" || ok "non-starter rejected without --adopt"
  out=$("$REPO/sync-project.sh" --adopt "$D" 2>&1)
  { [ -f "$D/.ai_context/INDEX.md" ] && [ -f "$D/CLAUDE.md" ] && [ -d "$D/.ai_context/tasks" ]; } && ok "adopt creates skeleton" || no "adopt skeleton incomplete"
  echo "$out" | grep -q 'run /setup' && ok "adopt hands off to /setup" || no "adopt handoff missing"
  { [ -f "$D/.claude/agents/checker.md" ] && [ -f "$D/.claude/skills/task/reference.md" ]; } && ok "v4 files (checker, task reference) land via sync" || no "checker/reference missing after sync"
  { [ -f "$D/scripts/evidence.sh" ] && [ -f "$D/.claude/skills/prove/SKILL.md" ]; } && ok "v4 files (evidence.sh, prove) land via sync" || no "evidence.sh/prove missing after sync"
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
  echo "$out3" | grep -qE 'has no SubagentStop wiring|lacks the v4 evidence (denies|\.sh rules)|still carries v3 task wiring' && no "settings suggestion on a stock v4 settings.json" || ok "stock v4 settings.json gets no settings suggestion (S2-S4)"
  sed -i.bak 's/"matcher": "checker"/"matcher": "verifier"/' "$D8/.claude/settings.json" && rm -f "$D8/.claude/settings.json.bak"
  out4=$("$REPO/sync-project.sh" "$D8" 2>&1)
  echo "$out4" | grep -q 'settings.json still carries v3 task wiring' && ok "a settings.json with a v3 verifier matcher gets the v3-wiring suggestion (S4)" || no "v3-wiring suggestion missing for a verifier matcher"
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
[ -f "$REPO/.claude/skills/task/pair.md" ] && ok "task pair.md exists (on-demand pair-codex protocol)" || no "task pair.md missing"
grep -q 'pair.md' "$REPO/.claude/skills/task/SKILL.md" && ok "task body points at pair.md (pair-codex protocol, read on demand)" || no "task body lost its pair.md pointer"
[ "$(grep -c 'pair.md' "$REPO/.claude/skills/task/SKILL.md")" -ge 3 ] && ok "task body points at pair.md from the card, slice and final checks" || no "task body lacks the per-check pair.md pointers (want >= 3, got $(grep -c 'pair.md' "$REPO/.claude/skills/task/SKILL.md"))"
PM="$REPO/.claude/skills/task/pair.md"
for sec in '## When pair is on' '## Requirements' '## Commands' '## Running a check' '## Stages' '## Result contract' '## No-verdict rule' '## Acting on findings' '## Quota' '## Files' '## Operator notes'; do
  grep -q "^$sec" "$PM" && ok "pair.md carries $sec" || no "pair.md missing $sec"
done
grep -q 'High-stakes findings are the human' "$PM" && ok "high-stakes findings: never disputed away, left for the human" || no "high-stakes rule missing"
awk '/^    run: completed\|failed\|blocked$/ {f = 1} f && /^    (run|verdict|base|blocker|major|minor): / {n++; next} f {exit} END {exit n != 6}' "$PM" \
  && ok "pair.md: the six result-header keys in one indented block" || no "pair.md result contract block is not the six keys"
grep -q 'run_in_background' "$PM" && ok "pair.md: check/send/wait run in the background" || no "pair.md lost run_in_background"
[ "$(wc -l < "$PM")" -le 170 ] && ok "pair.md within 170 lines ($(wc -l < "$PM") — read on demand)" || no "pair.md is $(wc -l < "$PM") lines (> 170)"
! grep -qE 'plan\.md|spec\.md|brief\.md|lessons\.md|ledger\.md|verifier|planner|milestone|profile' "$PM" && ok "pair.md names no v3 /task artefact (plan, spec, brief, lessons, ledger, verifier, milestone, profile)" || no "pair.md still names v3 artefacts: $(grep -oE 'plan\.md|spec\.md|brief\.md|lessons\.md|ledger\.md|verifier|planner|milestone|profile' "$PM" | sort -u | tr '\n' ' ')"
sz=$(wc -c < "$REPO/.claude/skills/wrap/SKILL.md")
[ "$sz" -le 2560 ] && ok "wrap SKILL.md within 2.5 KB ($sz B — task machinery lives in reference.md)" || no "wrap SKILL.md bloated ($sz B > 2560)"
[ -f "$REPO/.claude/skills/wrap/reference.md" ] && ok "wrap reference.md exists (on-demand task close-out)" || no "wrap reference.md missing"
grep -q 'reference.md' "$REPO/.claude/skills/wrap/SKILL.md" && ok "wrap body points at the reference" || no "wrap body lost its reference pointer"
grep -qF 'date,slug,slices,blocks,stuck,codex_runs,interventions,duration_min,outcome,harness' "$REPO/.claude/skills/wrap/reference.md" && ok "wrap reference carries the scoreboard-v4.csv header (R25)" || no "wrap reference missing the scoreboard-v4.csv header"
nc="$REPO/.claude/skills/number-check/SKILL.md"
{ [ "$(sed -n 1p "$nc" 2>/dev/null)" = '---' ] && grep -q '^name: number-check$' "$nc" && grep -q '^description: .' "$nc"; } && ok "number-check skill registers (name + description frontmatter)" || no "number-check skill missing or its frontmatter is broken"
if [ -f "$REPO/templates/CLAUDE.md.analysis" ]; then
  ref="$(grep -o 'number passed `/[a-z-]*`' "$REPO/templates/CLAUDE.md.analysis" | sed 's/.*`\/\(.*\)`/\1/' | head -1)"
  { [ -n "$ref" ] && [ -f "$REPO/.claude/skills/$ref/SKILL.md" ]; } && ok "analysis DoD points at a skill that exists (/$ref)" || no "analysis DoD names no existing skill (got '/$ref')"
else
  skp "analysis DoD → skill check (spawned project — template-repo only)"
fi
grep -qF 'Read(./**/.env)' "$REPO/.claude/settings.json" && ok "nested .env read-deny present" || no "nested .env deny missing"
grep -qxF '**/.env' "$REPO/.gitignore" && ok "nested .env gitignored" || no "nested .env gitignore missing"
grep -qF '.ai_context/tasks/*/pair/.fp-*' "$REPO/.gitignore" && ok "pair/.fp-* gitignored (in-flight fingerprints never memory)" || no "pair/.fp-* ignore missing"
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

echo "=== L1-11 · harness-report.sh (scoring is computed, never recalled)"
SB_V4='date,slug,slices,blocks,stuck,codex_runs,interventions,duration_min,outcome,harness'
CSV_V2='csv_version,project,harness,n_tasks,n_success,n_failed,n_abandoned,slices_sum,codex_runs_sum,interventions_sum,duration_med,block_rows,stuck_rows,escalate_rows,gate_error_rows,defects_pre_done,defects_post_done,defects_post_close,friction_total,friction_blockers'
csvget() { # $1 = --csv output, $2 = harness, then column names -> their values on that row (looked up by header name)
  local c="$1" h="$2"; shift 2
  awk -F, -v h="$h" -v cols="$*" 'NR == 1 {for (i = 1; i <= NF; i++) ix[$i] = i; next}
    $ix["harness"] == h {n = split(cols, C, " "); o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? " " : "") ((C[i] in ix) ? $ix[C[i]] : "?"); print o}' <<<"$c"
}
D="$WORK/l111"; mkdir -p "$D/.ai_context/tasks/t1" "$D/.ai_context/tasks/live"
# v3 scoreboard.csv stays readable history (R25); v4 rows go to scoreboard-v4.csv
cat > "$D/.ai_context/scoreboard.csv" <<'EOF'
date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness
2026-07-10,t1,opus-tier,M,4,1,1,0,90,success,aaa1111
2026-07-10,t2,opus-tier,M,3,0,1,0,60,success,aaa1111
2026-07-11,t3,opus-tier,M,5,2,2,1,120,success,aaa1111
2026-07-11,t4,opus-tier,M,4,0,1,0,80,failed,aaa1111
2026-07-12,t5,opus-tier,M,4,1,3,2,100,success,aaa1111
2026-07-08,old1,fable-tier,S,2,1,4,0,?,abandoned
EOF
echo "$SB_V4" > "$D/.ai_context/scoreboard-v4.csv"
printf '2026-07-11T10:00:00Z\tBLOCK\tS2\tnoref\t-\t-\tblock 1/2\n2026-07-11T10:01:00Z\tBLOCK\tS2\tnoref\t-\t-\tblock 2/2\n2026-07-11T11:00:00Z\tGATE-ERROR\t-\tgate\t-\t-\tevidence.sh status --porcelain failed (rc 1)\n' > "$D/.ai_context/tasks/t1/donelog"
printf '2026-07-15T09:00:00Z\tWAITING\tS1\tsubagent:executor\t-\t-\tdeferred\n' > "$D/.ai_context/tasks/live/donelog"
printf 'date,harness,area,severity,summary,ref\n2026-07-12,aaa1111,hooks,blocker,gate blocked wrap turn,journal/x.md\n2026-07-13,bbb2222,sync,papercut,stale stamp,-\n' > "$D/.ai_context/friction.csv"
out=$(bash "$REPO/scripts/harness-report.sh" "$D")
echo "$out" | grep -q 'tasks: 6 (success 4, failed 1, abandoned 1)' && ok "dataset counts computed" || no "dataset counts wrong"
echo "$out" | grep -q '^aaa1111 : n=5 .* (success 80%)' && ok "N>=5 cell (per harness) prints success rate" || no "N>=5 cell missing its rate"
echo "$out" | grep -q 'unknown(1)' && ok "old 10-field row lands in the unknown bucket" || no "unknown bucket missing"
echo "$out" | grep -q '^unknown : n=1 success=0 failed=0 abandoned=1$' && ok "N<5 cell prints counts only (no %)" || no "N<5 cell printed a percentage"
echo "$out" | grep -q '^donelog: BLOCK 2 · ' && ok "BLOCK rows joined from donelogs" || no "donelog BLOCK join wrong"
echo "$out" | grep -q '^!! donelog GATE-ERROR rows: 1 (t1:1)' && ok "GATE-ERROR rows surfaced per task (the gate failed open)" || no "GATE-ERROR rows not surfaced"
# STUCK rows surface even mid-flight (no scoreboard row yet) — the handoff
# happens before any wrap can write one.
S2="$WORK/l111s"; mkdir -p "$S2/.ai_context/tasks/live"
printf '# Live\n<!-- card v4 ; pair: off ; base: 0000000 ; estimate: 1h 10L -->\n## Slices\n- [~] S6 c — lanes: smoke ; codex: no\n' > "$S2/.ai_context/tasks/live/card.md"
printf '2026-07-22T01:05:00Z\tSTUCK\tS6\tnoref\t-\t-\tyielded after 3 blocks on the same card and content\n' > "$S2/.ai_context/tasks/live/donelog"
echo live > "$S2/.ai_context/tasks/CURRENT"
out2=$(bash "$REPO/scripts/harness-report.sh" "$S2")
echo "$out2" | grep -qxF '!! donelog STUCK rows: 1 (live:1) — the gate handed a blocked slice to the human' && ok "mid-flight STUCK row surfaces without scoreboard data (fleet-report parses this line)" || no "mid-flight STUCK invisible or reworded"
echo "$out" | grep -q 'blocker:1 friction:0 papercut:1' && ok "friction severities counted" || no "friction counts wrong"
csv=$(bash "$REPO/scripts/harness-report.sh" --csv "$D")
[ "$(echo "$csv" | head -1)" = "$CSV_V2" ] && ok "--csv header is the v2 fleet contract (csv_version first)" || no "--csv header drifted: $(echo "$csv" | head -1)"
got="$(csvget "$csv" aaa1111 csv_version project harness n_tasks n_success n_failed n_abandoned interventions_sum duration_med block_rows gate_error_rows friction_blockers)"
[ "$got" = '2 l111 aaa1111 5 4 1 0 3 90 2 1 1' ] && ok "--csv per-version aggregates correct (read by column name)" || no "--csv aggregate row wrong: $got"
got="$(csvget "$csv" bbb2222 n_tasks friction_total friction_blockers)"
[ "$got" = '0 1 0' ] && ok "--csv covers friction-only versions" || no "friction-only version row wrong: $got"
E="$WORK/l111e"; mkdir -p "$E"
bash "$REPO/scripts/harness-report.sh" "$E" >/dev/null 2>&1
ck 0 $? "no data yields a clean exit 0"
B="$WORK/l111b"; mkdir -p "$B/.ai_context"; echo "garbage,x" > "$B/.ai_context/scoreboard.csv"
bash "$REPO/scripts/harness-report.sh" "$B" >/dev/null 2>&1
ck 2 $? "malformed scoreboard header exits 2"
grep -qF "$SB_V4" "$REPO/.claude/skills/wrap/reference.md" && grep -qF "SB_V4='$SB_V4'" "$REPO/scripts/harness-report.sh" && ok "wrap reference and harness-report.sh carry the same scoreboard-v4.csv header" || no "wrap and report scoreboard-v4 headers drifted apart"
grep -qF 'date,harness,area,severity,summary,ref' "$REPO/.claude/skills/wrap/reference.md" && ok "wrap reference carries the friction schema" || no "friction schema missing from wrap reference"
if [ -f "$REPO/sync-project.sh" ]; then
  grep -q 'stock_update scripts/harness-report.sh' "$REPO/sync-project.sh" && ok "sync ships harness-report.sh" || no "sync does not ship harness-report.sh"
else
  skp "sync ships harness-report.sh (spawned project — template-repo only)"
fi

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
grep -qF 'Edit(./.ai_context/tasks/**/gatelog)' "$REPO/.claude/settings.json" && ok "gatelog Edit-deny present (covers all file-editing tools)" || no "gatelog deny entry missing"
grep -qF 'Write(./.ai_context/tasks/**/' "$REPO/.claude/settings.json" && no "dead Write() deny rule present — CC matches only Edit(path) for file edits and warns every session (F25)" || ok "no dead Write() deny rules (F25)"
grep -qF '"Bash(git push --force:*)"' "$REPO/.claude/settings.json" && ok "declarative force-push deny present" || no "force-push deny entry missing"
grep -qF '"ask"' "$REPO/.claude/settings.json" && grep -qF '"Bash(git push:*)"' "$REPO/.claude/settings.json" && ok "ask tier present (push/reset/clean/sudo)" || no "ask tier missing"
for r in 'Bash(rm -rf ~/*)' 'Bash(rm -rf $HOME/*)' 'Bash(rm -rf ../*)'; do grep -qF "\"$r\"" "$REPO/.claude/settings.json" && ok "declarative ask rule present: $r (v3.14.3 — prompts even under bypass, where hook asks are dropped)" || no "declarative ask rule missing: $r"; done
grep -qF '"Bash(rm -rf:*)"' "$REPO/.claude/settings.json" && no "rm -rf ask rule back in settings.json — declarative ask rules prompt in every mode incl. bypass, per subcommand, and no hook exemption reaches them (v3.14.2)" || ok "no declarative rm -rf ask rule: bash-guard is the single rm tier (v3.14.2)"

echo "=== L1-32 · bash-guard, settings and guard-patterns (v4)"
# ask = rc 0 + a permissionDecision ask; silent = rc 0 + empty stdout.
bgo() { bgp "$2" | CLAUDE_PROJECT_DIR="$1" bash "${BG_BIN:-$BG}" > "$WORK/bg.out" 2>/dev/null; echo $?; }
ask_is() { [ "$(bgo "$1" "$2")" = 0 ] && grep -q '"permissionDecision":"ask"' "$WORK/bg.out"; }
silent() { [ "$(bgo "$1" "$2")" = 0 ] && [ ! -s "$WORK/bg.out" ]; }
D="$WORK/l132"; mkproj "$D"; mkcard "$D" demo off '- [~] S1 first — lanes: smoke ; codex: no'
Dn="$WORK/l132n"; mkdir -p "$Dn/.ai_context/tasks"
Dc="$WORK/l132c"; mkdir -p "$Dc/.ai_context/tasks/demo"; echo demo > "$Dc/.ai_context/tasks/CURRENT"
Di="$WORK/l132i"; OLD=1 mkproj "$Di"; mkcard "$Di" demo off '- [~] S1 first — lanes: smoke ; codex: no'
touch -d '8 days ago' "$Di/.ai_context/tasks/demo/card.md" "$Di/.ai_context/tasks/demo/donelog"
for c in 'git add -A' 'git add --all' 'git add .' 'git -C sub add -A' 'cd x && git add .' 'git checkout -- src/a.txt' 'git checkout HEAD~1 -- a b' 'git checkout .' \
         'git restore src/a.txt' 'git stash' 'git stash pop' 'git stash list; git stash pop' 'git checkout -f' 'git switch --discard-changes main' 'git switch -f main'; do
  ask_is "$D" "$c" && ok "task active: '$c' asks" || no "task active: '$c' not asked ($(cat "$WORK/bg.out"))"
done
for c in 'git add src/a.txt' 'git add -p' 'git checkout main' 'git checkout -b task/x' 'git stash list' 'git stash show -p' 'git switch main' 'git commit -a -m x'; do
  silent "$D" "$c" && ok "task active: '$c' stays silent" || no "task active: '$c' flagged ($(cat "$WORK/bg.out"))"
done
silent "$Dn" 'git add -A' && ok "no CURRENT: git add -A stays silent" || no "git add -A asked without a task"
silent "$Dc" 'git add -A' && ok "CURRENT without a card: git add -A stays silent" || no "git add -A asked without a card"
silent "$Di" 'git stash' && ok "idle task: git stash stays silent" || no "git stash asked on an idle task"
for c in 'cat .claude/evidence/smoke.jsonl' 'echo x >> .claude/evidence/smoke.jsonl' 'rm .claude/done-lanes.trust' 'bash scripts/evidence.sh show smoke > .claude/evidence/x'; do
  ask_is "$Dn" "$c" && ok "ledger, no task: '$c' asks" || no "ledger: '$c' not asked ($(cat "$WORK/bg.out"))"
done
for s in 'run smoke' 'status --line' 'show smoke' 'done S1' 'close' 'lint' 'start S2'; do
  silent "$D" "bash scripts/evidence.sh $s" && ok "evidence.sh $s stays silent" || no "evidence.sh $s flagged ($(cat "$WORK/bg.out"))"
done
{ ask_is "$D" 'bash scripts/evidence.sh trust smoke' && grep -q 'YOU approve this lane command' "$WORK/bg.out"; } && ok "evidence.sh trust asks: the human signs the lane" || no "trust not asked: $(cat "$WORK/bg.out")"
ask_is "$D" 'bash scripts/evidence.sh approve' && ok "evidence.sh approve asks" || no "approve not asked"
ask_is "$D" 'bash scripts/evidence.sh check S1 --agent fx --source human' && ok "evidence.sh check by hand asks" || no "check not asked"
ask_is "$D" 'bash scripts/evidence.sh run smoke --escalated' && ok "run --escalated asks (past an ESCALATE)" || no "--escalated not asked"
ask_is "$D" 'bash scripts/evidence.sh run smoke; rm .claude/evidence/smoke.jsonl' && ok "an allowed call chained with a ledger write asks" || no "chained ledger write not asked"
{ ask_is "$D" 'bash scripts/evidence.sh codex p r completed ok' && grep -q 'writes a Codex review record' "$WORK/bg.out"; } && ok "evidence.sh codex by hand asks (A3b)" || no "codex not asked: $(cat "$WORK/bg.out")"
ask_is "$D" 'bash scripts/task-pair.sh check slice S2 --over-estimate' && ok "task-pair.sh --over-estimate asks (Codex quota past the approval)" || no "--over-estimate not asked"
ask_is "$D" 'echo x >> .ai_context/tasks/demo/donelog' && ok "appending to a donelog asks" || no "donelog append not asked"
ask_is "$D" 'sed -i 1d .ai_context/tasks/demo/donelog' && ok "editing a donelog in place asks" || no "donelog sed not asked"
silent "$D" 'git add .ai_context/tasks/demo/donelog' && ok "staging a donelog stays silent" || no "git add donelog flagged"
silent "$D" 'grep RUN .ai_context/tasks/demo/donelog' && ok "reading a donelog stays silent" || no "grep donelog flagged"
mkdir -p "$WORK/bg132"; cp "$BG" "$WORK/bg132/"
BG_BIN="$WORK/bg132/bash-guard.sh" silent "$D" 'git add -A' && ok "no guard-patterns.sh: the v4 tier is off (degrades to v3, never asks on everything)" || no "degraded guard asked: $(cat "$WORK/bg.out")"
rc=$(BG_BIN="$WORK/bg132/bash-guard.sh" bgo "$D" 'sudo ls'); ck 2 "$rc" "no guard-patterns.sh: the built-in deny tier still holds"
for r in 'Edit(./.claude/evidence/**)' 'Edit(./.ai_context/tasks/**/donelog)' 'Edit(./.claude/done-lanes.trust)' 'Edit(./.claude/gitleaks.toml)'; do
  grep -qF "\"$r\"" "$REPO/.claude/settings.json" && ok "settings denies $r" || no "deny missing: $r"
done
grep -q 'ack-' "$REPO/.claude/settings.json" && no "settings still carries v3 ack- rules" || ok "no v3 ack- rules in settings"
python3 - "$REPO/.claude/settings.json" <<'PY' > "$WORK/st132"
import json, re, sys
s = json.load(open(sys.argv[1])); h = s["hooks"]; p = s["permissions"]
cmd = lambda ev, end: [k for e in h[ev] for k in e["hooks"] if k["command"].endswith(end)]
ev = [re.fullmatch(r"Bash\(bash scripts/evidence\.sh (\w+):\*\)", a) for a in p["allow"]]
print("stop30", h["Stop"][0]["hooks"][0].get("timeout") == 30)
print("checker60", [k.get("timeout") for k in cmd("SubagentStop", "checker stop")] == [60])
print("ask3", all("Bash(bash scripts/evidence.sh %s:*)" % x in p["ask"] for x in ("trust", "approve", "check")))
print("allow0", not any("evidence.sh" in a and re.search("trust|approve|check", a) for a in p["allow"]))
print("allow7", sorted(m.group(1) for m in ev if m) == sorted("run status show start done close lint".split()))
print("pair", "Bash(bash scripts/task-pair.sh check:*)" in p["allow"] and "Bash(bash scripts/task-pair.sh wait:*)" in p["allow"])
print("nostatus", "statusLine" not in s)
print("editask", all("Edit(./%s)" % f in p["ask"] for f in ("scripts/evidence.sh", "scripts/precommit-gitleaks.sh", "scripts/harness-report.sh", ".claude/hooks/guard-patterns.sh", ".claude/hooks/stop-gate.sh", ".claude/hooks/spawn-log.sh", ".claude/settings.json")))
PY
for k in stop30 checker60 ask3 allow0 allow7 pair nostatus editask; do
  case "$k" in
    stop30) m='Stop hook timeout is 30 s' ;; checker60) m='checker stop hook timeout is 60 s' ;;
    ask3) m='declarative asks for evidence.sh trust/approve/check (survive bypassPermissions)' ;;
    allow0) m='no allow rule for evidence.sh trust/approve/check' ;; allow7) m='allow covers exactly evidence.sh run status show start done close lint' ;;
    pair) m='allow covers task-pair.sh check and wait' ;; nostatus) m='no statusLine key (R21)' ;;
    editask) m='edits to the scripts the evidence chain trusts ask (evidence.sh, the gate, spawn-log, guard-patterns, gitleaks wrapper, harness-report, settings.json)' ;;
  esac
  grep -qx "$k True" "$WORK/st132" && ok "settings: $m" || no "settings: $m"
done
( . "$REPO/.claude/hooks/guard-patterns.sh"; for f in task_slug task_idle task_active lock_alive donelog_row card_current_slice static_only; do declare -F "$f" >/dev/null || exit 1; done
  ! declare -F guard_forbidden_verify >/dev/null && [ -z "${GUARD_GIT_PUSH+x}" ] ) && ok "guard-patterns.sh defines the v4 helpers, none of the v3 verify denylist" || no "guard-patterns.sh helpers wrong"
idle() { ( . "$REPO/.claude/hooks/guard-patterns.sh"; task_idle "$Di" demo ); echo $?; }
touch -d '6 days ago' "$Di/.ai_context/tasks/demo/card.md" "$Di/.ai_context/tasks/demo/donelog"
ck 1 "$(idle)" "task_idle: card and donelog 6 days old -> active"
touch -d '8 days ago' "$Di/.ai_context/tasks/demo/card.md" "$Di/.ai_context/tasks/demo/donelog"
ck 0 "$(idle)" "task_idle: card, donelog and task/demo 8 days old -> idle"
echo n > "$Di/src/n.txt"; git -C "$Di" add src/n.txt; git -C "$Di" commit -qm now
ck 1 "$(idle)" "task_idle: a fresh task/demo commit keeps it active"
la() { ( . "$REPO/.claude/hooks/guard-patterns.sh"; lock_alive "$1" ); echo $?; }
bash -c 'exec -a evidence.sh sleep 5' & lp=$!
ck 0 "$(la "$lp")" "lock_alive: a live evidence.sh pid"; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
ck 1 "$(la "$lp")" "lock_alive: a reaped pid"
ck 1 "$(la abc)" "lock_alive: a non-numeric pid"
mkdir -p "$WORK/l132d"; ( . "$REPO/.claude/hooks/guard-patterns.sh"; donelog_row "$WORK/l132d/donelog" CHECK S1 checker - abc "a$(printf '\t')b
c" )
{ [ "$(wc -l < "$WORK/l132d/donelog" | tr -d ' ')" = 1 ] && awk -F'\t' 'NF != 7 {exit 1}' "$WORK/l132d/donelog" && cut -f1 "$WORK/l132d/donelog" | grep -Eq "$TS_RE"; } && ok "donelog_row: TAB/newline in a field -> one 7-field row, UTC ts" || no "donelog_row row: $(cat -A "$WORK/l132d/donelog")"

echo "=== L1-45 · independent review regressions: evidence.sh (review of 27f53be), hooks review H2/H3b/H4/M1"
# One assertion (or one small group) per finding; the finding id leads each message.
lv() { sed -n 's/.*"verdict":"\([a-z]*\)".*/\1/p' "$1/.claude/evidence/$2" | tail -n 1; }   # the last record's verdict
porc() { ev "$1" status --porcelain >/dev/null; grep "^$2" "$WORK/ev.out"; }                    # $2 = a porcelain row prefix
cxv() { ( cd "$1" && bash scripts/evidence.sh codex "$2" "$3" completed ok >/dev/null 2>>"$WORK/cx.err" ); lv "$1" codex.jsonl; }
fin() { # $1 = a dir from ready: S2 started, run, checked and done, a final check -> close's rc
  ev "$1" start S2 >/dev/null; ev "$1" run smoke >/dev/null; rep S2 pass | ev "$1" check S2 --agent fx --source human >/dev/null; ev "$1" "done" S2 >/dev/null
  rep final pass | ev "$1" check final --agent fx --source human >/dev/null; ev "$1" close
}
LANE_VM='vm-release | src/ | 1 | ^verify: [1-9][0-9]* passed, 0 failed$ | bash scripts/canary.sh | bash scripts/verify.sh'

# #1 / #11 — the digest and the lanes come only from the text before a slice line's first ' ✓ '
P="$WORK/l145k"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE" "$LANE_VM"; ev "$P" trust smoke >/dev/null; ev "$P" trust vm-release >/dev/null
mkcard "$P" demo off '- [~] S1 boots — lanes: vm-release ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null
C="$P/.ai_context/tasks/demo/card.md"; cp "$C" "$WORK/k3card"
sed -i.bak 's/^\(- \[~\] S1 .*codex: no\)$/\1 ✓ — lanes: smoke ; codex: no/' "$C"
rc=$(ev "$P" lint); lint="$(cat "$WORK/ev.out" "$WORK/ev.err")"
ev "$P" run smoke >/dev/null; rep S1 pass | ev "$P" check S1 --agent fx --source human >/dev/null; rc2=$(ev "$P" "done" S1)
{ [ "$rc" = 1 ] && printf '%s' "$lint" | grep -qF "S1 carries text after ' ✓ ' that is not evidence tokens" && [ "$rc2" = 1 ] && grep -qF 'lane vm-release: never run' "$WORK/ev.out"; } \
  && ok "#1 a smuggled ' ✓ — lanes:' clause: lint flags it and done still needs the approved lane" || no "#1 smuggled clause: lint rc=$rc done rc=$rc2: $(head -c 300 "$WORK/ev.out")"
sid="$(lastid "$P" smoke.jsonl)"; cid="$(lastid "$P" checker.jsonl)"; cp "$WORK/k3card" "$C"
sed -i.bak "s/^- \[~\] \(S1 .*codex: no\)\$/- [x] \1 ✓ — lanes: smoke ; codex: no ✓ smoke@$sid check@$cid/" "$C"
porc "$P" 'SLICE	S1	bad	the line does not parse' >/dev/null && ok "#1 a hand-written [x] line carrying the clause before its tokens is SLICE bad" || no "#1 clause before tokens: $(grep SLICE "$WORK/ev.out")"
cp "$WORK/k3card" "$C"; sed -i.bak "s/^- \[~\] \(S1 .*codex: no\)\$/- [x] \1 ✓ smoke@$sid check@$cid/" "$C"; a1="$(porc "$P" LINE)"
sed -i.bak 's/^\(- \[x\] S1 .*\)$/\1 x/' "$C"; a2="$(porc "$P" LINE)"
{ printf '%s' "$a1" | grep -qF 'card approved' && printf '%s' "$a2" | grep -qF 'card changed'; } && ok "#1 a token suffix keeps the approval; any other text after ' ✓ ' changes the digest" || no "#1 digest: '$a1' / '$a2'"
cp "$WORK/k3card" "$C"; sed -i.bak 's/^Goal: .*/& ✓ smuggled/' "$C"; a1="$(porc "$P" LINE)"
awk '/^## Slices/ {print "Closed: tree:000000000000 smuggled"} {print}' "$WORK/k3card" > "$C"; a2="$(porc "$P" LINE)"
cp "$WORK/k3card" "$C"; printf 'Closed: tree:000000000000 head:000000000000 ✓ smoke@00000000 — 2026-01-01T00:00:00Z\n' >> "$C"; a3="$(porc "$P" LINE)"
{ printf '%s' "$a1" | grep -qF 'card changed' && printf '%s' "$a2" | grep -qF 'card changed' && printf '%s' "$a3" | grep -qF 'card approved'; } \
  && ok "#11 ' ✓ ' on a non-slice line and a Closed: line that is not the last line change the digest; close's last line does not" || no "#11 digest: '$a1' / '$a2' / '$a3'"
cp "$WORK/k3card" "$C"

# #2 A/A2, #6 B, #12 V, #26, H3b, H4, M1 — one task taken to a genuine close
P="$WORK/l145a"; ready "$P"; C="$P/.ai_context/tasks/demo/card.md"; PD="$P/.ai_context/tasks/demo/donelog"; cp "$C" "$WORK/a-card"
sed -i.bak 's/^- \[ \] S2 second/- [x] S2\tsecond/' "$C"
porc "$P" 'SLICE	S2	' >/dev/null && ok "M1 a TAB after S<n> on an [x] line still yields a SLICE row (the gate's own regex)" || no "M1 no SLICE row for '[x] S2<TAB>': $(cat "$WORK/ev.out")"
cp "$WORK/a-card" "$C"; printf '%s\tDONE\tS2\t-\t000000000000\tsmoke@0badc0de,check@0badc0df\tok\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$PD"
sed -i.bak 's/^- \[ \] S2 second — lanes: smoke ; codex: no$/& ✓ smoke@0badc0de check@0badc0df/; s/^- \[ \] S2 /- [x] S2 /' "$C"
porc "$P" 'SLICE	S2	bad	.*not committed' >/dev/null && ok "H3b invented ids backed only by an uncommitted DONE row are bad, not foreign" || no "H3b forged row: $(grep SLICE "$WORK/ev.out")"
cp "$WORK/a-card" "$C"; sed -i.bak '$d' "$PD"
rep final pass | ev "$P" check final --agent fx --source human >/dev/null
W="$(porc "$P" TREE | cut -f2 | cut -c1-12)"; echo "Closed: tree:$W done" >> "$C"; c1="$(porc "$P" CLOSED)"; cp "$WORK/a-card" "$C"
printf 'Closed: tree:%s head:%s ✓ smoke@%s check@%s — 2026-01-01T00:00:00Z\n' "$W" "$(git -C "$P" rev-parse HEAD | cut -c1-12)" "$(lastid "$P" smoke.jsonl)" "$(lastid "$P" checker.jsonl)" >> "$C"; c2="$(porc "$P" CLOSED)"
{ printf '%s' "$c1" | grep -q '^CLOSED	stale	' && printf '%s' "$c2" | grep -qF 'not every slice is [x]' && printf '%s' "$c2" | grep -qF 'the last CLOSE row does not match'; } \
  && ok "H4 a hand-written Closed: line with S2 open and no close run is CLOSED stale" || no "H4 hand Closed: '$c1' / '$c2'"
cp "$WORK/a-card" "$C"; mkdir -p "$P/docs"; echo x > "$P/docs/x.md"; git -C "$P" add docs; git -C "$P" commit -qm docs
rc="$(fin "$P")"; { [ "$rc" = 1 ] && grep -qF "outside the cited lanes' paths: docs/x.md" "$WORK/ev.out"; } && ok "#26 close reports a change committed between slices outside every cited lane" || no "#26 close coverage (rc=$rc): $(head -c 400 "$WORK/ev.out")"
git -C "$P" rm -rq docs; git -C "$P" commit -qm undocs; rep final pass | ev "$P" check final --agent fx --source human >/dev/null; rc=$(ev "$P" close)
{ [ "$rc" = 0 ] && porc "$P" 'CLOSED	ok' >/dev/null; } && ok "#26 reverted, the task closes (CLOSED ok)" || no "close after revert (rc=$rc): $(head -c 400 "$WORK/ev.out")"
mv "$P/.claude/evidence" "$WORK/a-ev"; s1="$(porc "$P" 'SLICE	S1')"; c1="$(porc "$P" CLOSED)"
git -C "$P" add .ai_context/tasks/demo/donelog; git -C "$P" commit -qm donelog; s2="$(porc "$P" 'SLICE	S1')"; c2="$(porc "$P" CLOSED)"; rm -rf "$P/.claude/evidence"; mv "$WORK/a-ev" "$P/.claude/evidence"
{ printf '%s' "$s1" | grep -q '	bad	' && printf '%s' "$c1" | grep -q '^CLOSED	stale' && printf '%s' "$s2" | grep -q '	foreign	' && printf '%s' "$c2" | grep -q '^CLOSED	foreign'; } \
  && ok "#12/H3b another machine (no local ledger): foreign once the DONE/CLOSE rows are committed, stale/bad before" || no "#12 foreign: '$s1' '$c1' / '$s2' '$c2'"
mv "$P/.claude/done-lanes" "$WORK/a-lanes"; c1="$(porc "$P" CLOSED)"; mv "$WORK/a-lanes" "$P/.claude/done-lanes"
mklanes "$P" 'idle | docs/ | 1 | ^x | bash scripts/canary.sh | bash scripts/verify.sh'; rc=$(ev "$P" close); grep -qF 'lane smoke: not declared in .claude/done-lanes' "$WORK/ev.out"; r=$?
c2="$(porc "$P" CLOSED)"
{ printf '%s' "$c1" | grep -q '^CLOSED	stale	.*done-lanes is missing' && [ "$rc" = 1 ] && [ $r = 0 ] && printf '%s' "$c2" | grep -q 'smoke: undeclared'; } \
  && ok "#2 a cited lane deleted from done-lanes (or done-lanes gone) blocks close and makes CLOSED stale" || no "#2 undeclared lane: '$c1' close rc=$rc '$c2'"
mklanes "$P" "$LANE_SMOKE" "@ext smoke touch $WORK/l145-PWNED; echo deadbeef"; rc=$(ev "$P" close)
{ [ "$rc" = 1 ] && [ ! -e "$WORK/l145-PWNED" ] && grep -qF 'lane smoke: not trusted' "$WORK/ev.out"; } && ok "#6 close never runs an @ext added after trust" || no "#6 @ext (rc=$rc, PWNED: $([ -e "$WORK/l145-PWNED" ] && echo yes || echo no))"
mklanes "$P" "$LANE_SMOKE"

# #3 C1/hollow, #15 N, #23 — tree_of fails closed; nested repositories count
P="$WORK/l145c"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE" 'hollow | nothere/ | 1 | ^x | bash scripts/canary.sh | bash scripts/verify.sh'; ev "$P" trust smoke >/dev/null
ev "$P" status >/dev/null; [ ! -s "$WORK/ev.err" ] && ok "#23 status without a CURRENT task prints nothing on stderr" || no "#23 stderr: $(head -c 200 "$WORK/ev.err")"
rc=$(ev "$P" trust hollow); { [ "$rc" = 3 ] && grep -qF 'no tracked or unignored file under its paths' "$WORK/ev.err"; } && ok "#3 trust refuses a lane whose paths hold no file" || no "#3 hollow lane trusted (rc=$rc)"
mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null
if [ "$(id -u)" = 0 ]; then skp "#3 unreadable file (root reads everything)"
else
  echo junk > "$P/src/zz"; chmod 000 "$P/src/zz"; rc=$(ev "$P" run smoke)
  t1="$(cd "$P" && bash scripts/evidence.sh status --tree S1 2>/dev/null)"; t2="$(cd "$P" && bash scripts/evidence.sh status --tree S1 2>/dev/null)"; chmod 600 "$P/src/zz"; rm -f "$P/src/zz"
  { [ "$rc" = 6 ] && grep -qF 'RUN REFUSED — lane smoke: git could not hash' "$WORK/ev.err" && [ "${t1#error:}" != "$t1" ] && [ "$t1" != "$t2" ]; } \
    && ok "#3 an unreadable file: run refuses (rc 6), the tree is a never-equal error id" || no "#3 unreadable: rc=$rc t1=$t1 t2=$t2"
fi
mkdir -p "$P/src/sub"; git -C "$P/src/sub" init -q; echo 1 > "$P/src/sub/f"; t1="$(cd "$P" && bash scripts/evidence.sh status --tree S1)"
echo 2 > "$P/src/sub/f"; t2="$(cd "$P" && bash scripts/evidence.sh status --tree S1)"; rm -rf "$P/src/sub"
{ [ "$t1" != "$t2" ] && [ "${t1#error:}" = "$t1" ] && [ "${t2#error:}" = "$t2" ]; } && ok "#15 an edit inside a nested repository changes the lane's tree" || no "#15 nested repo: $t1 / $t2"

# fix review — done's lint must normalise ✓ tokens like `lint` does (slice_gaps' token list once shadowed the TOK regex)
P="$WORK/l145t"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null
mkcard "$P" demo off "- [~] S1 first $(head -c 3400 /dev/zero | tr '\0' x) — lanes: smoke ; codex: no" '- [ ] S2 second — lanes: smoke ; codex: no'
C="$P/.ai_context/tasks/demo/card.md"; sed -i.bak "s/^\(- \[~\] S1 first x*\)/\1$(head -c $((3766 - $(wc -c < "$C"))) /dev/zero | tr '\0' x)/" "$C"
ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null; ev "$P" run smoke >/dev/null; rep S1 pass | ev "$P" check S1 --agent fx --source human >/dev/null; ev "$P" "done" S1 >/dev/null
ev "$P" start S2 >/dev/null; ev "$P" run smoke >/dev/null; rep S2 pass | ev "$P" check S2 --agent fx --source human >/dev/null; rc=$(ev "$P" "done" S2)
[ "$rc" = 0 ] && ok "a near-cap card: done S2 measures the card without S1's ✓ tokens, as lint does" || no "near-cap done S2 (rc=$rc): $(head -c 300 "$WORK/ev.out")"

# #4 D, #16 R — review records and ESCALATE belong to one task
P="$WORK/l145d"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null
mkcard "$P" taska off '- [~] S1 first — lanes: smoke ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null; ev "$P" run smoke >/dev/null
rep S1 pass | ev "$P" check S1 --agent fx --source human >/dev/null; ev "$P" "done" S1 >/dev/null
mkcard "$P" taskb off '- [~] S1 first — lanes: smoke ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null; ev "$P" run smoke >/dev/null; rc=$(ev "$P" "done" S1)
{ [ "$rc" = 1 ] && grep -qF 'no checker record for S1' "$WORK/ev.out"; } && ok "#4 task B cannot use task A's checker record for its own S1" || no "#4 cross-task check (rc=$rc): $(head -c 300 "$WORK/ev.out")"
echo broken > "$P/src/mode"; for _ in 1 2 3; do ev "$P" run smoke >/dev/null; done; rc=$(ev "$P" run smoke)
mkcard "$P" taskc off '- [~] S1 first — lanes: smoke ; codex: no'; sleep 1; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null; rc2=$(ev "$P" run smoke); rm -f "$P/src/mode"
{ [ "$rc" = 5 ] && [ "$rc2" = 1 ] && [ "$(dl "$P" taskc ESCALATE)" = 0 ]; } && ok "#16 three fails on task B's S1 do not ESCALATE task C's S1" || no "#16 ESCALATE scope: B rc=$rc C rc=$rc2 rows=$(dl "$P" taskc ESCALATE)"

# #5 E/E2/X, #18 RUNHDR — a codex record approves only what Codex was shown
P="$WORK/l145e"; mkproj "$P"; mklanes "$P" '@pair codex' "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null; H0="$(git -C "$P" rev-parse HEAD)"
mkcard "$P" demo codex '- [~] S1 first — lanes: smoke ; codex: yes'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null; : > "$WORK/cx.err"
dg="card:$(sed -e 's/^- \[[ ~ox]\] /- [ ] /' -e 's/ ✓ .*$//' -e '/^Closed:/d' "$P/.ai_context/tasks/demo/card.md" | sha256sum | cut -c1-64)"
k="$(pkt "$P" 001-card card card "card:$(printf '%064d' 0)")"; v1="$(cxv "$P" "$k" "$(res "$k" pass 0 0)")"
k="$(pkt "$P" 002-card card card "$dg")"; v2="$(cxv "$P" "$k" "$(res "$k" pass 0 0)")"
{ [ "$v1 $v2" = "none pass" ] && grep -qF 'codex result not bound to what was reviewed' "$WORK/cx.err"; } && ok "#5 X a card review at another digest records verdict none" || no "#5 card binding: $v1 $v2"
echo b > "$P/src/b.txt"; git -C "$P" add -A; git -C "$P" commit -qm work; H1="$(git -C "$P" rev-parse HEAD)"
k="$(pkt "$P" 003-slice-S1 slice S1 "$H1" "$H1")"; v1="$(cxv "$P" "$k" "$(res "$k" pass 0 0)")"
echo c > "$P/src/c.txt"; k="$(pkt "$P" 004-slice-S1 slice S1 "$H1" "$H0")"; v2="$(cxv "$P" "$k" "$(res "$k" pass 0 0)")"; rm -f "$P/src/c.txt"
k="$(pkt "$P" 005-slice-S1 slice S1 "$H1" "$H0")"; v3="$(cxv "$P" "$k" "$(res "$k" pass 0 0)")"
[ "$v1 $v2 $v3" = "none none pass" ] && ok "#5 E/E2 a slice review counts only from the slice's START head to a clean HEAD" || no "#5 slice binding: $v1 $v2 $v3"
k="$(pkt "$P" 006-slice-S1 slice S1 "$H1" "$H0")"; r="$(res "$k" pass 0 0)"; sed -i.bak 's/^run: completed/run: failed/' "$r"; v1="$(cxv "$P" "$k" "$r")"
k="$(pkt "$P" 007-slice-S1 slice S1 "$H1" "$H0")"; r="$(res "$k" pass 0 0)"; sed -i.bak "s/^base: .*/base: $H0/" "$r"; v2="$(cxv "$P" "$k" "$r")"
k="$(pkt "$P" 008-final final final "$H1" "$H1")"; v3="$(cxv "$P" "$k" "$(res "$k" pass 0 0)")"
k="$(pkt "$P" 009-final final final "$H1" "$H0")"; v4="$(cxv "$P" "$k" "$(res "$k" pass 0 0)")"
[ "$v1 $v2 $v3 $v4" = "none none none pass" ] && ok "#18 a result's run:/base: must agree; #5 a final review counts only since the card's base" || no "#18/#5 final: $v1 $v2 $v3 $v4"

# #7 G — a project that is not its repository's top level
M="$WORK/l145g"; mkdir -p "$M"; git -C "$M" init -q; echo r > "$M/root.txt"; P="$M/proj"; mkproj "$P" >/dev/null 2>&1; rm -rf "$P/.git"
git -C "$M" add -A; git -C "$M" commit -qm root; mklanes "$P" "$LANE_SMOKE"; rc=$(ev "$P" trust smoke); grep -qF 'the project root is not the git top level' "$WORK/ev.err"; r=$?
rc2=$(ev "$P" status --porcelain)
{ [ "$rc" = 6 ] && [ $r = 0 ] && [ "$rc2" = 0 ] && grep -qx 'TREE	-' "$WORK/ev.out"; } && ok "#7 not the git top level: trust exits 6, porcelain still answers" || no "#7 monorepo: trust rc=$rc status rc=$rc2"

# #8 F, #9 L, #10 J, #24, #26 (.claude/done-lanes.bak), #19 M, #20 CAN — definitions, show, scans
P="$WORK/l145f"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null
printf '#!/usr/bin/env bash\nsleep 1; echo "verify: 1 passed, 0 failed"\n' > "$P/scripts/verify.sh"; rc=$(ev "$P" run smoke); git -C "$P" checkout -q scripts/verify.sh
{ [ "$rc" = 3 ] && grep -qF 'command changed since trust (its text or a repo file it names)' "$WORK/ev.err"; } && ok "#8 gutting the script a trusted cmd names un-trusts the lane" || no "#8 wrapper edit ran (rc=$rc)"
echo 'exit 0' >> "$P/scripts/canary.sh"; rc=$(ev "$P" run smoke); git -C "$P" checkout -q scripts/canary.sh
{ [ "$rc" = 3 ] && grep -qF 'canary changed since trust' "$WORK/ev.err"; } && ok "#8 editing the canary's script un-trusts the lane" || no "#8 canary edit ran (rc=$rc)"
mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null
echo broken > "$P/src/mode"; EVPATH="$WORK/nogl-bin" ev "$P" run smoke >/dev/null; rm -f "$P/src/mode"
{ grep -qF 'log tail not printed: gitleaks is not installed' "$WORK/ev.out" && ! grep -qF 'verify: 0 passed' "$WORK/ev.out"; } && ok "#24 clean-ip-only: a failed run prints no log tail" || no "#24 tail printed without gitleaks: $(head -c 300 "$WORK/ev.out")"
ev "$P" run smoke >/dev/null; rep S1 pass | ev "$P" check S1 --agent fx --source human >/dev/null
mklanes "$P" 'smoke | src/ scripts/ | 1 | ^verify: [0-9]+ passed, 0 failed$ | bash scripts/canary.sh | bash scripts/verify.sh'; ev "$P" trust smoke >/dev/null
cp "$P/.claude/done-lanes" "$P/.claude/done-lanes.bak"; rc=$(ev "$P" "done" S1); rm -f "$P/.claude/done-lanes.bak"
{ [ "$rc" = 1 ] && grep -qF 'ran under another definition' "$WORK/ev.out"; } && ok "#9 a pass recorded under the previous lane definition does not count after re-trust" || no "#9 superseded record (rc=$rc): $(head -c 300 "$WORK/ev.out")"
grep -qF '.claude/done-lanes.bak' "$WORK/ev.out" && ok "#26 .claude/done-lanes.bak is not exempt from coverage (only the exact files are)" || no "#26 done-lanes.bak not reported"
rc=$(ev "$P" show ../../notes); ck 2 "$rc" "#10 show refuses a name that is not a lane, review kind or @id"
echo SECRET-MARKER-145 > "$P/notes.txt"; printf '{"id":"0badc0de","lane":"smoke","log":"notes.txt","scan":"clean"}\n' >> "$P/.claude/evidence/smoke.jsonl"; ev "$P" show smoke >/dev/null
{ ! grep -qF SECRET-MARKER-145 "$WORK/ev.out" && grep -qF 'log not shown: notes.txt' "$WORK/ev.out"; } && ok "#10 show prints no log outside .claude/evidence/logs/" || no "#10 forged log path printed"
sed -i.bak '$d' "$P/.claude/evidence/smoke.jsonl"; rm -f "$P/notes.txt"; ev "$P" run smoke >/dev/null
log="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p' "$P/.claude/evidence/smoke.jsonl" | tail -n 1)"; echo 'token FAKE-LEAK-0123' >> "$P/$log"; EVPATH="$WORK/fakebin:$PATH" ev "$P" show smoke >/dev/null
{ ! grep -qF FAKE-LEAK-0123 "$WORK/ev.out" && grep -qF 'log withheld' "$WORK/ev.out"; } && ok "#10 show re-scans a log before printing it" || no "#10 log printed without a fresh scan"
rep S1 pass 'VERIFIED (L4) saw FAKE-LEAK-0123 in the env — x' | ev "$P" check S1 --agent fx --source human >/dev/null; EVPATH="$WORK/fakebin:$PATH" ev "$P" show checker >/dev/null
{ ! grep -qF FAKE-LEAK-0123 "$WORK/ev.out" && grep -qF 'log withheld' "$WORK/ev.out"; } && ok "#24 a checker report is scanned before show prints it" || no "#24 checker report printed unscanned"
grep -v '^\.claude/evidence/$' "$P/.gitignore" > "$WORK/gi"; cp "$P/.gitignore" "$WORK/gi.orig"; cp "$WORK/gi" "$P/.gitignore"; a1="$(porc "$P" LINE)"; cp "$WORK/gi.orig" "$P/.gitignore"
printf '%s' "$a1" | grep -qF '.claude/evidence/ is not gitignored' && ok "#24 status reads no ledger that is not gitignored" || no "#24 unignored ledger: $a1"
mklanes "$P" 'check | src/ | 1 | ^x | bash scripts/canary.sh | bash scripts/verify.sh'; rc=$(ev "$P" trust check); grep -qF "bad lane name 'check'" "$WORK/ev.err"; r1=$?
mklanes "$P" "$LANE_SMOKE" '@ext smoke echo a' '@ext smoke echo b'; rc2=$(ev "$P" trust smoke); grep -qF "a second @ext for lane 'smoke'" "$WORK/ev.err"; r=$?
{ [ "$rc" = 2 ] && [ "$rc2" = 2 ] && [ $r1 = 0 ] && [ $r = 0 ]; } && ok "#19/#26 a lane named check and a second @ext for one lane are format errors" || no "#19/#26 lint rc=$rc / rc=$rc2"
bad=""; for c in 'false ' '(false)' 'exit  1' '/bin/false'; do
  mklanes "$P" "fake | src/ | 1 | ^verify: [1-9] | $c | bash scripts/verify.sh"; rc=$(ev "$P" trust fake); { [ "$rc" = 3 ] && grep -qF 'canary is trivial' "$WORK/ev.err"; } || bad="$bad [$c]"
done; [ -z "$bad" ] && ok "#20 spacing, parentheses or a path do not hide a trivial canary" || no "#20 trivial canaries trusted:$bad"
mklanes "$P" "$LANE_SMOKE"

# #13 H, #14 I — names git would quote; renames
P="$WORK/l145h"; mkproj "$P"; mkdir -p "$P/config"; echo p > "$P/config/prod.yaml"; git -C "$P" add -A; git -C "$P" commit -qm config
mklanes "$P" "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null; mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no' '- [ ] S2 second — lanes: smoke ; codex: no'
ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null; printf 'x\n' > "$P/src/$(printf '\347\231\273\345\205\245').txt"
ev "$P" run smoke >/dev/null; rep S1 pass | ev "$P" check S1 --agent fx --source human >/dev/null; rc=$(ev "$P" "done" S1)
ck 0 "$rc" "#13 a non-ASCII file name inside the lane's paths is not reported outside"
ev "$P" start S2 >/dev/null; git -C "$P" mv config/prod.yaml src/prod.yaml; git -C "$P" commit -qm move
ev "$P" run smoke >/dev/null; rep S2 pass | ev "$P" check S2 --agent fx --source human >/dev/null; rc=$(ev "$P" "done" S2)
{ [ "$rc" = 1 ] && grep -qF 'config/prod.yaml' "$WORK/ev.out"; } && ok "#14 a rename into the lane still reports the deletion outside it" || no "#14 rename (rc=$rc): $(head -c 300 "$WORK/ev.out")"

# #21 JSON, #22 log mode — an executed count with leading zeros, a marker cut inside a UTF-8 character
P="$WORK/l145j"; mkproj "$P"
cat > "$P/scripts/v7.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1; echo "verify: 007 passed, 0 failed"
printf 'note: x%s\n' "$(printf '\303\251%.0s' $(seq 1 150))"
echo "perm: $(find .claude/evidence/logs -type f \( -perm -040 -o -perm -004 \) | wc -l | tr -d ' ')"
EOF
mklanes "$P" 'v7 | src/ scripts/ | 1 | ^verify: [0-9]+ passed, 0 failed$ ; ^note: | bash scripts/canary.sh | bash scripts/v7.sh'; ev "$P" trust v7 >/dev/null; ev "$P" run v7 >/dev/null
r="$(python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(r["executed"], r["verdict"], len(r["markers"][1].encode()) <= 200)' "$P/.claude/evidence/v7.jsonl" 2>&1)"
[ "$r" = "7 pass True" ] && ok "#21 the record stays valid JSON (executed 7; the 200-byte marker cut drops a split character)" || no "#21 record: $r"
log="$(sed -n 's/.*"log":"\([^"]*\)".*/\1/p' "$P/.claude/evidence/v7.jsonl" | tail -n 1)"
grep -qx 'perm: 0' "$P/$log" && ok "#22 no lane log is group- or world-readable while the lane runs" || no "#22 log mode: $(grep '^perm' "$P/$log")"

# #17 — a checker record is void when the unit's content moved between its spawn and its report
P="$WORK/l145s"; mkproj "$P"; mklanes "$P" "$LANE_SMOKE"; ev "$P" trust smoke >/dev/null
mkcard "$P" demo off '- [~] S1 first — lanes: smoke ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null; ev "$P" run smoke >/dev/null
printf '{"agent_id":"ag145a"}' | CLAUDE_PROJECT_DIR="$P" bash "$SL" checker start
row="$(awk -F'\t' '$2 == "SPAWN" && $6 == "ag145a"' "$P/.ai_context/tasks/demo/donelog")"
echo z > "$P/src/a.txt"; rep S1 pass | ev "$P" check S1 --agent ag145a --source human >/dev/null; v1="$(cut -d' ' -f3 "$WORK/ev.out")"
printf '{"agent_id":"ag145b"}' | CLAUDE_PROJECT_DIR="$P" bash "$SL" checker start; rep S1 pass | ev "$P" check S1 --agent ag145b --source human >/dev/null; v2="$(cut -d' ' -f3 "$WORK/ev.out")"
{ printf '%s' "$row" | cut -f5 | grep -Eqx '[0-9a-f]{12}' && [ "$v1 $v2" = "void pass" ]; } && ok "#17 SPAWN carries the unit's tree12; a change before the report voids the check" || no "#17 spawn tree: row='$row' verdicts $v1 $v2"

# H2 — status latency and no object writes: 3 lanes + a Closed: line
P="$WORK/l145t"; mkproj "$P"; mkdir -p "$P/a" "$P/b" "$P/c"; for l in a b c; do echo 1 > "$P/$l/x"; done; git -C "$P" add -A; git -C "$P" commit -qm abc
L3() { echo "$1 | $1/ src/ | 1 | ^verify: [1-9][0-9]* passed, 0 failed\$ | bash scripts/canary.sh | bash scripts/verify.sh"; }
mklanes "$P" "$(L3 a)" "$(L3 b)" "$(L3 c)"; for l in a b c; do ev "$P" trust $l >/dev/null; done
mkcard "$P" demo off '- [~] S1 first — lanes: a,b,c ; codex: no'; ev "$P" approve >/dev/null; ev "$P" start S1 >/dev/null
for l in a b c; do ev "$P" run $l >/dev/null; done; rep S1 pass | ev "$P" check S1 --agent fx --source human >/dev/null; ev "$P" "done" S1 >/dev/null
rep final pass | ev "$P" check final --agent fx --source human >/dev/null; rc=$(ev "$P" close)
mkdir -p "$WORK/gitlog-bin"; printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$WORK/git.calls" "$(command -v git)" > "$WORK/gitlog-bin/git"; chmod +x "$WORK/gitlog-bin/git"
n0="$(find "$P/.git/objects" -type f | wc -l | tr -d ' ')"; : > "$WORK/git.calls"
head -c 200000 /dev/urandom > "$P/src/big.bin"; EVPATH="$WORK/gitlog-bin:$PATH" ev "$P" status --porcelain >/dev/null; cp "$WORK/ev.out" "$WORK/t.out"
head -c 200000 /dev/urandom > "$P/src/big.bin"; EVPATH="$WORK/gitlog-bin:$PATH" ev "$P" status --porcelain >/dev/null
n1="$(find "$P/.git/objects" -type f | wc -l | tr -d ' ')"; wt="$(grep -c 'write-tree' "$WORK/git.calls")"; ui="$(grep -c '^update-index' "$WORK/git.calls")"
{ [ "$rc" = 0 ] && grep -q '^CLOSED	stale' "$WORK/t.out" && [ "$wt" -le 4 ] && [ "$ui" -le 2 ] && [ "$n0" = "$n1" ]; } \
  && ok "H2 two porcelain calls (3 lanes + Closed:, a changing untracked file): $wt write-tree, $ui update-index, .git/objects unchanged" || no "H2 close rc=$rc write-tree=$wt update-index=$ui objects $n0 -> $n1: $(head -c 200 "$WORK/t.out")"
rm -f "$P/src/big.bin"; ms="$(cd "$P" && python3 -I -c '
import statistics, subprocess, time
t = []
for _ in range(3):
    s = time.time(); subprocess.run(["bash", "scripts/evidence.sh", "status", "--porcelain"], capture_output=True); t.append((time.time() - s) * 1000)
print(int(statistics.median(t)))')"
porc "$P" 'CLOSED	ok' >/dev/null && [ "${ms:-99999}" -lt 1000 ] && ok "H2 porcelain status on 3 lanes + Closed: is fast (median ${ms} ms; bound 1000, target 500)" || no "H2 porcelain median ${ms} ms or CLOSED not ok: $(cat "$WORK/ev.out")"

# bash-guard: a Bash-side write to a script or setting the evidence chain trusts asks
bad=""; for c in 'sed -i s/a/b/ scripts/evidence.sh' 'echo x > scripts/evidence.sh' 'echo x >> .claude/hooks/stop-gate.sh' 'tee -a .claude/settings.json' \
  'cp /tmp/x scripts/precommit-gitleaks.sh' 'mv x .claude/hooks/spawn-log.sh' 'truncate -s 0 scripts/harness-report.sh' 'cat > .claude/hooks/guard-patterns.sh' 'perl -pi -e s/a/b/ scripts/evidence.sh'; do
  ask_is "$WORK/l145a" "$c" && grep -qF 'evidence chain trusts' "$WORK/bg.out" || bad="$bad [$c]"
done; [ -z "$bad" ] && ok "bash-guard asks before a Bash write to evidence.sh, the gate, spawn-log, guard-patterns, the gitleaks wrapper, harness-report or settings.json" || no "chain write not asked:$bad"
bad=""; for c in 'cat scripts/evidence.sh' 'bash scripts/evidence.sh status > /tmp/x' 'cp scripts/evidence.sh /tmp/x' 'grep x .claude/settings.json' 'sed -n 1p scripts/evidence.sh' 'git diff scripts/evidence.sh'; do
  silent "$WORK/l145a" "$c" || bad="$bad [$c]"
done; [ -z "$bad" ] && ok "bash-guard stays silent on reads of those files" || no "chain read asked:$bad"

echo "=== L1-46 · hooks review regressions (independent review of the C3 hooks at 818e0f3)"
# One assertion (or one small group) per finding; the finding id leads each message.
# Each fails on 8f41e9d (the C3 hooks plus the evidence.sh review fix) and passes here.
# H2, H3b, H4 and M1's evidence.sh half are L1-45's.
bgj() { python3 -I -c 'import json,sys; d={"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}
if len(sys.argv) > 2: d["cwd"] = sys.argv[2]
print(json.dumps(d))' "$@"; }
asks() { bgj "${@:2}" | CLAUDE_PROJECT_DIR="$1" bash "$BG" > "$WORK/bg.out" 2>/dev/null && grep -q '"permissionDecision":"ask"' "$WORK/bg.out"; }   # $1 project, $2 command [, $3 cwd]
quiet() { bgj "${@:2}" | CLAUDE_PROJECT_DIR="$1" bash "$BG" > "$WORK/bg.out" 2>/dev/null && [ ! -s "$WORK/bg.out" ]; }
Pg="$WORK/l146g"; mkproj "$Pg"; mkcard "$Pg" demo off '- [~] S1 first — lanes: smoke ; codex: no'; TD="$Pg/.ai_context/tasks/demo"

# H1 — spawn-log reads the current wake only. tests/fixtures/cc-2.1.309/agent-checker-twowake.jsonl is
# SYNTHESIZED from the recorded fixtures: rows 1-5 = agent-checker-handback.jsonl verbatim (wake 1, a handback
# with S1 pass), then a SendMessage re-wake row shaped like CC's ("The coordinator sent a message while you were
# working: …", isMeta) and wake 2's re-check, ending in a handback with S1 fail (rows 9-10).
Ph="$WORK/l146h"; mkdir -p "$Ph/.ai_context/tasks/demo" "$Ph/scripts"; cp "$TD/card.md" "$Ph/.ai_context/tasks/demo/"; echo demo > "$Ph/.ai_context/tasks/CURRENT"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"; cat > "%s"; echo "check S1 pass deadbeef01"\n' "$WORK/h1.argv" "$WORK/h1.stdin" > "$Ph/scripts/evidence.sh"
hstop() { python3 -I - "$FX/subagentstop-checker.json" "$1" "$2" "$3" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); p["agent_transcript_path"] = sys.argv[3]; p["last_assistant_message"] = sys.argv[4]
json.dump(p, open(sys.argv[2], "w"))
PY
}
head -n 8 "$FX/agent-checker-twowake.jsonl" > "$WORK/h1.jsonl"; hstop "$WORK/h1.json" "$WORK/h1.jsonl" 'Handing the report back now.'
( sleep 1; tail -n 2 "$FX/agent-checker-twowake.jsonl" >> "$WORK/h1.jsonl" ) & ap=$!
CLAUDE_PROJECT_DIR="$Ph" bash "$SL" checker stop < "$WORK/h1.json" >/dev/null 2>&1; wait "$ap"
{ grep -q -- '--source handback$' "$WORK/h1.argv" && grep -qx 'checker-verdict: S1 fail' "$WORK/h1.stdin" && ! grep -q 'S1 pass' "$WORK/h1.stdin"; } \
  && ok "H1 a re-woken checker whose handback lands 1 s late: wake 2's verdict (fail) is recorded, never wake 1's pass" || no "H1 stale wake: [$(cat "$WORK/h1.argv")] $(tail -n 1 "$WORK/h1.stdin")"
python3 -I - "$FX/agent-checker-handback.jsonl" "$WORK/h1b.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
for r in rows:
    for b in r["message"]["content"]:
        if b.get("type") == "text":
            b["text"] = "Draft.\nVERIFIED (L4) draft claim — cat hello.txt\ncheckker-verdict: S1 pass".replace("checkker", "checker")
        if b.get("name") == "SubagentHandback":
            b["input"]["message"] = "DELIVERED-REPORT: the claim could not be checked; no verdict line."
open(sys.argv[2], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
hstop "$WORK/h1b.json" "$WORK/h1b.jsonl" 'Handed back.'; CLAUDE_PROJECT_DIR="$Ph" bash "$SL" checker stop < "$WORK/h1b.json" >/dev/null 2>&1
{ grep -q -- '--source handback$' "$WORK/h1.argv" && grep -q DELIVERED-REPORT "$WORK/h1.stdin" && ! grep -q 'checker-verdict' "$WORK/h1.stdin"; } \
  && ok "H1 a delivered handback without a verdict beats an earlier draft that had one (recorded unparsed, done refuses)" || no "H1 draft won: [$(cat "$WORK/h1.argv")] $(head -c 200 "$WORK/h1.stdin")"

# H3a / M3 — A6 asks for real donelog writes only, also through a cd or the payload's cwd
bad=""; for c in 'cd .ai_context/tasks/demo && printf "x\tDONE\tS2\n" >> donelog' 'cd .ai_context/tasks && echo x >> demo/donelog'; do asks "$Pg" "$c" || bad="$bad [$c]"; done
asks "$Pg" 'printf x >> donelog' "$TD" || bad="$bad [cwd: printf x >> donelog]"
[ -z "$bad" ] && ok "H3a a write to a bare donelog after cd into the task dir (or with cwd there) asks" || no "H3a donelog write via cd not asked:$bad"
bad=""; for c in 'grep -c BLOCK .ai_context/tasks/demo/donelog 2>/dev/null' 'wc -l .ai_context/tasks/demo/donelog 2>&1' "awk -F'\t' '\$2 == \"RUN\"' .ai_context/tasks/demo/donelog" \
  "sed -n '1,20p' .ai_context/tasks/demo/donelog" 'cp .ai_context/tasks/demo/donelog /tmp/donelog.bak' 'cd .ai_context/tasks/demo && grep RUN donelog'; do quiet "$Pg" "$c" || bad="$bad [$c]"; done
for c in 'cp /tmp/x .ai_context/tasks/demo/donelog 2>/dev/null' "awk -i inplace '{print}' .ai_context/tasks/demo/donelog" 'tee -a .ai_context/tasks/demo/donelog' \
  'dd if=/dev/null of=.ai_context/tasks/demo/donelog' 'truncate -s0 .ai_context/tasks/demo/donelog' 'ln -sf /tmp/x .ai_context/tasks/demo/donelog'; do asks "$Pg" "$c" || bad="$bad [write: $c]"; done
[ -z "$bad" ] && ok "M3 donelog reads (grep/wc 2>, awk, sed -n, cp elsewhere) stay silent; writes (cp onto, awk -i inplace, tee, dd of=, truncate, ln) ask" || no "M3 donelog rule:$bad"

# M1 — the gate trusts only ok/foreign SLICE rows, and every [x] it sees needs one (stub porcelain)
Pm="$WORK/l146m"; mkdir -p "$Pm/.ai_context/tasks/demo" "$Pm/scripts"; printf '# ok\n## Commands\n- Test: `true`\n' > "$Pm/CLAUDE.md"; echo demo > "$Pm/.ai_context/tasks/CURRENT"
printf '# Demo task\n<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->\nGoal: m1\n## Slices\n- [x] S1 first — lanes: smoke ; codex: no ✓ smoke@0123abcd check@0123abce\n' > "$Pm/.ai_context/tasks/demo/card.md"
printf '#!/usr/bin/env bash\nprintf "TREE\\t0123456789ab\\nCLOSED\\tnone\\t-\\nLINE\\tstub\\n"\n' > "$Pm/scripts/evidence.sh"; rc=$(gt "$Pm" tsuite-l146m1)
{ [ "$rc" = 2 ] && grep -qF 'S1 cites evidence that does not hold: not evaluated by evidence.sh' "$WORK/g.err"; } && ok "M1 an [x] slice with no SLICE row in the porcelain blocks (not evaluated by evidence.sh)" || no "M1 missing SLICE row passed (rc=$rc)"
printf '#!/usr/bin/env bash\nprintf "TREE\\t0123456789ab\\nSLICE\\tS1\\tnoref\\tno evidence reference\\nCLOSED\\tnone\\t-\\nLINE\\tstub\\n"\n' > "$Pm/scripts/evidence.sh"; rc=$(gt "$Pm" tsuite-l146m1b)
{ [ "$rc" = 2 ] && grep -qF 'S1 is marked [x] without an evidence reference' "$WORK/g.err"; } && ok "M1 a porcelain noref blocks even where the gate itself read a reference" || no "M1 porcelain noref passed (rc=$rc)"

# M2 — gate state never under the project; an unwritable counter yields; the supervisor never blocks mute
P2="$WORK/l146s"; ready "$P2"; mkdir -p "$P2/.tmp"
sed -i.bak 's/^- \[ \] S2 second — lanes: smoke ; codex: no$/& ✓ smoke@0badc0de check@0badc0df/; s/^- \[ \] S2 /- [x] S2 /' "$P2/.ai_context/tasks/demo/card.md"; rm -f "$P2/.ai_context/tasks/demo/card.md.bak"
r=""; for _ in 1 2 3; do printf '{"session_id":"tsuite-l146m2"}' | TMPDIR="$P2/.tmp" CLAUDE_PROJECT_DIR="$P2" bash "$GATE" >/dev/null 2>&1; r="$r$?"; done
{ [ "$r" = 220 ] && [ "$(dl "$P2" demo STUCK)" = 1 ] && [ -z "$(ls -A "$P2/.tmp")" ]; } && ok "M2 TMPDIR inside the project: state goes elsewhere, the third stop yields (STUCK)" || no "M2 in-project TMPDIR: rcs $r, STUCK $(dl "$P2" demo STUCK), .tmp: $(ls -A "$P2/.tmp" | head -3)"
rm -f /tmp/claude-gate-red-tsuite-l146m2-* /tmp/claude-gate-stuck-tsuite-l146m2-* /tmp/claude-gate-line-tsuite-l146m2-*
if [ "$(id -u)" = 0 ]; then skp "M2 unwritable TMPDIR (root writes everywhere)"
else
  mkdir -p "$WORK/l146ro"; chmod 555 "$WORK/l146ro"; n0="$(dl "$P2" demo GATE-ERROR)"
  printf '{"session_id":"tsuite-l146ro"}' | TMPDIR="$WORK/l146ro" CLAUDE_PROJECT_DIR="$P2" bash "$GATE" > "$WORK/g.out" 2>/dev/null; rc=$?
  { [ "$rc" = 0 ] && [ "$(dl "$P2" demo GATE-ERROR)" = $((n0 + 1)) ] && grep -q 'GATE-ERROR.*block counter' "$P2/.ai_context/tasks/demo/donelog" && grep -qF 'internal error' "$WORK/g.out"; } \
    && ok "M2 an unwritable block counter yields with a GATE-ERROR row instead of blocking uncounted" || no "M2 unwritable counter (rc=$rc): $(cat "$WORK/g.out")"
  cp "$P2/CLAUDE.md" "$WORK/l146cl"; printf '# t\n<!-- claude-starter: UNCONFIGURED -->\n' > "$P2/CLAUDE.md"
  printf '{"session_id":"tsuite-l146ro2"}' | TMPDIR="$WORK/l146ro" CLAUDE_PROJECT_DIR="$P2" bash "$GATE" > "$WORK/g.out" 2> "$WORK/g.err"; rc=$?; cp "$WORK/l146cl" "$P2/CLAUDE.md"
  { [ "$rc" = 2 ] && grep -qF 'SETUP GATE' "$WORK/g.err"; } && ok "M2 no writable TMPDIR: a block still carries its reason on stderr" || no "M2 mute block (rc=$rc): stderr '$(head -c 120 "$WORK/g.err")'"
  chmod 755 "$WORK/l146ro"
fi

# M4 / L2 — evidence.sh trust|approve|check|codex in command position on a normalised probe
bad=""; for c in "bash scripts/evidence.sh 'trust' smoke" 'bash scripts/evidence.sh "approve"' $'bash scripts/evidence.sh \\\ntrust smoke' \
  'bash scripts/evidence\.sh check S1 --agent x --source human' 'bash -c "bash scripts/evidence.sh trust smoke"'; do asks "$Pg" "$c" || bad="$bad [$c]"; done
[ -z "$bad" ] && ok "M4 quoted, escaped or line-continued subcommands still ask (globs, variables and symlinks stay the boundary)" || no "M4 not asked:$bad"
bad=""; for c in 'git commit -m "fix: evidence.sh check S1 parses the verdict"' "git commit -m 'docs: run bash scripts/evidence.sh approve after reading'"; do quiet "$Pg" "$c" || bad="$bad [$c]"; done
[ -z "$bad" ] && ok "L2 a commit message mentioning evidence.sh check/approve does not ask" || no "L2 commit message asked:$bad"

# M5 — a session started with --agent executor|checker is no background subagent
Pa="$WORK/l146a"; ready "$Pa"; sed -i.bak 's/^- \[ \] S2 /- [x] S2 /' "$Pa/.ai_context/tasks/demo/card.md"
rc=$(gt "$Pa" tsuite-l146m5 ',"agent_type":"executor","background_tasks":[]'); ck 2 "$rc" "M5 a top-level agent_type (--agent executor session) does not defer the gate"

# L1 — bash-guard bypasses
bad=""; for c in '$(rm${IFS}.claude/evidence/smoke.jsonl)scripts/evidence.sh status' 'rm -rf .claude' 'rm -rf ./.claude/./evidence' 'rm -r "$CLAUDE_PROJECT_DIR"/.claude/'; do asks "$Pg" "$c" || bad="$bad [$c]"; done
[ -z "$bad" ] && ok "L1 A5: a \$( ) prefix on an allowed call, rm -r of .claude itself and ./ /./ path variants ask" || no "L1 A5 bypass:$bad"
bad=""; for c in '/usr/bin/git stash' 'bash -c "git add -A"' 'git checkout src/a.txt' 'git add *'; do asks "$Pg" "$c" || bad="$bad [$c]"; done
for c in 'git checkout main' 'git checkout -b src'; do quiet "$Pg" "$c" || bad="$bad [quiet: $c]"; done
[ -z "$bad" ] && ok "L1 G rules: absolute git, bash -c \"git …\", git checkout <existing path> and git add * ask; branch checkouts stay silent" || no "L1 G rules:$bad"

# L2 — no ask for git add/diff/log/show of the trust file, nor for git restore --staged
bad=""; for c in 'git add .claude/done-lanes .claude/done-lanes.trust' 'git diff .claude/done-lanes.trust' 'git log -p -- .claude/done-lanes.trust' 'git restore --staged src/a.txt'; do quiet "$Pg" "$c" || bad="$bad [$c]"; done
for c in 'cat .claude/done-lanes.trust' 'git show HEAD:.claude/done-lanes.trust > .claude/done-lanes.trust' 'git restore --staged -W src/a.txt' 'git restore src/a.txt'; do asks "$Pg" "$c" || bad="$bad [ask: $c]"; done
[ -z "$bad" ] && ok "L2 staging or reading the trust file and unstaging stay silent; other trust-file use and worktree restores ask" || no "L2:$bad"

# L3 — a GATE-ERROR reason holds no absolute project or home path, and a long one keeps its end
P3="$WORK/l146e"; ready "$P3"; cp "$REPO/.claude/hooks/"*.sh "$P3/.claude/hooks/"
awk '/^# --- 1\. Setup gate/ {print "if ;; then"} {print}' "$GATE" > "$P3/.claude/hooks/stop-gate.sh"
printf '{"session_id":"tsuite-l146l3"}' | CLAUDE_PROJECT_DIR="$P3" bash "$P3/.claude/hooks/stop-gate.sh" >/dev/null 2>&1; r1="$(tail -n 1 "$P3/.ai_context/tasks/demo/donelog")"
H3="$WORK/l146home"; mkdir -p "$H3/hk" "$H3/$(printf 'deep%.0s/' $(seq 1 30))"; cp "$P3/.claude/hooks/"*.sh "$H3/hk/"; cp "$P3/.claude/hooks/"*.sh "$H3/$(printf 'deep%.0s/' $(seq 1 30))"
printf '{"session_id":"tsuite-l146l3b"}' | HOME="$H3" CLAUDE_PROJECT_DIR="$P3" bash "$H3/hk/stop-gate.sh" >/dev/null 2>&1; r2="$(tail -n 1 "$P3/.ai_context/tasks/demo/donelog")"
printf '{"session_id":"tsuite-l146l3c"}' | CLAUDE_PROJECT_DIR="$P3" bash "$H3/$(printf 'deep%.0s/' $(seq 1 30))stop-gate.sh" >/dev/null 2>&1; r3="$(tail -n 1 "$P3/.ai_context/tasks/demo/donelog")"
{ printf '%s' "$r1" | grep -qF 'rc=2: .claude/hooks/stop-gate.sh: line' && ! printf '%s' "$r1$r2" | grep -qF -e "$P3" -e "$H3" && printf '%s' "$r2" | grep -qF 'rc=2: ~/hk/stop-gate.sh: line' \
  && printf '%s' "$r3" | grep -qE 'rc=2: \.\.\..*stop-gate\.sh: line [0-9]+' && [ "$(printf '%s' "$r3" | cut -f7 | wc -c)" -le 170 ]; } \
  && ok "L3 GATE-ERROR reasons strip the project root and \$HOME, and a long one keeps its end" || no "L3 reasons: [$r1] [$r2] [$r3]"

# L4 — Edit asks and their Bash-side twin cover bash-guard, session-start, the checker agent, settings.local.json
bad=""; for f in .claude/hooks/bash-guard.sh .claude/hooks/session-start.sh .claude/agents/checker.md .claude/settings.local.json; do
  grep -qF "\"Edit(./$f)\"" "$REPO/.claude/settings.json" || bad="$bad [Edit $f]"
  { asks "$Pg" "echo x >> $f" && grep -qF 'evidence chain trusts' "$WORK/bg.out"; } || bad="$bad [Bash $f]"
done
[ -z "$bad" ] && ok "L4 settings.json Edit-asks and bash-guard asks on writes to bash-guard, session-start, checker.md, settings.local.json" || no "L4 uncovered:$bad"

echo "=== L1-14 · pre-commit guards: append-only + S2 bulk"
D="$WORK/l114"; mkdir -p "$D/.ai_context/journal" "$D/.ai_context/tasks/demo" "$D/.ai_context/knowledge/lessons"
printf 'preamble\n' > "$D/.ai_context/decisions.md"
printf 'date,slug\n2026-07-01,t1\n' > "$D/.ai_context/scoreboard.csv"
printf '2026-07-01T00:00:00\tM1\tPASS\ttrue\n' > "$D/.ai_context/tasks/demo/gatelog"
printf '2026-07-01T00:00:00\tM1\texecutor\n' > "$D/.ai_context/tasks/demo/spawnlog"
printf 'first line\n' > "$D/.ai_context/journal/2026-07-01-x.md"
printf '# build fails on a cold cache\nWhat works: warm it first\n' > "$D/.ai_context/knowledge/lessons/build.md"
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
ck 1 $? "gatelog row removal blocks (frozen v3 evidence, R24)"
( cd "$D" && git reset -q && git checkout -q -- .ai_context/tasks/demo/gatelog )
# F18: spawnlog is the same evidence class — a history rewrite must block.
sed -i.bak '1d' "$D/.ai_context/tasks/demo/spawnlog" && rm -f "$D/.ai_context/tasks/demo/spawnlog.bak"
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 1 $? "spawnlog rewrite blocks (F18 — commit layer agrees with the runtime deny, R24)"
( cd "$D" && git reset -q && git checkout -q -- .ai_context/tasks/demo/spawnlog )
git -C "$D" mv -f .ai_context/journal/2026-07-01-x.md .ai_context/journal/renamed.md
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 1 $? "journal rename blocks"
( cd "$D" && git reset -q && git checkout -q -- .ai_context/journal && rm -f .ai_context/journal/renamed.md )
printf '# build fails on a cold cache\nWhat works: warm it first (re-confirmed)\nLast confirmed: 2026-07-03\n' > "$D/.ai_context/knowledge/lessons/build.md"
git -C "$D" add -A
( cd "$D" && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1
ck 0 $? "a lesson file rewrite passes (one lesson per file, updated in place — deliberately not covered)"
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
grep -qF 'tasks/.+/(donelog|gatelog|spawnlog)' "$REPO/.pre-commit-config.yaml" && grep -qF 'done-lanes\.trust' "$REPO/.pre-commit-config.yaml" && ok "pre-commit files regex covers donelog, the v3 logs and the trust file" || no "pre-commit files regex misses donelog, gatelog/spawnlog or done-lanes.trust"

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
cat > "$D/.ai_context/scoreboard-v4.csv" <<'EOF'
date,slug,slices,blocks,stuck,codex_runs,interventions,duration_min,outcome,harness
2026-07-10,bad,2,0,0,0,-,50,success,ccc3333
2026-07-11,weird,2,0,0,0,-,30,succeeded,ccc3333
EOF
# bad: S1 is evidence.sh's (tokens + DONE row), S2 was marked [x] by hand; 2 BLOCK rows the row says 0 of
cardx() { # $1 = task dir, $2 = title, then slice lines
  local d="$1" t="$2"; shift 2
  { echo "# $t"; echo '<!-- card v4 ; pair: off ; base: 0000000 ; estimate: 1h 10L -->'; echo '## Slices'; printf '%s\n' "$@"; } > "$d/card.md"
}
cardx "$D/.ai_context/tasks/bad" bad '- [x] S1 a — lanes: smoke ; codex: no ✓ smoke@1a2b3c4d check@5e6f7a8b' '- [x] S2 b — lanes: smoke ; codex: no'
printf '2026-07-10T09:00:00Z\tDONE\tS1\t-\t9c8b7a6f5e4d\tsmoke@1a2b3c4d,check@5e6f7a8b\tok\n2026-07-10T09:10:00Z\tBLOCK\tS2\tnoref\t-\t-\tblock 1/2\n2026-07-10T09:11:00Z\tBLOCK\tS2\tnoref\t-\t-\tblock 2/2\n' > "$D/.ai_context/tasks/bad/donelog"
cardx "$D/.ai_context/tasks/orphan" orphan '- [ ] S1 a — lanes: smoke ; codex: no'
cardx "$D/.ai_context/tasks/cur" cur '- [~] S1 a — lanes: smoke ; codex: no'
echo cur > "$D/.ai_context/tasks/CURRENT"
out=$(bash "$REPO/scripts/harness-report.sh" "$D")
echo "$out" | grep -q 'scoreboard/donelog mismatch: bad — blocks: scoreboard 0, donelog 2' && ok "scoreboard↔donelog mismatch surfaced" || no "mismatch not surfaced"
echo "$out" | grep -q 'orphan task: tasks/orphan/' && ok "orphan task dir surfaced (survivor-bias net)" || no "orphan not surfaced"
echo "$out" | grep -q '\[x\] without evidence: tasks/bad/ S2 ' && ! echo "$out" | grep -q 'without evidence: tasks/bad/ S1 ' && ok "[x] slice evidence.sh done never wrote surfaced (S1 with tokens and a DONE row is not)" || no "[x] without evidence not surfaced, or S1 misflagged"
echo "$out" | grep -q 'enum violation: scoreboard weird: outcome="succeeded"' && ok "outcome enum violation surfaced" || no "enum violation not surfaced"
echo "$out" | grep -q 'orphan task: tasks/cur/' && no "in-flight CURRENT task misflagged as orphan" || ok "in-flight CURRENT task not flagged"
csv=$(bash "$REPO/scripts/harness-report.sh" --csv "$D")
echo "$csv" | grep -q 'mismatch' && no "--csv polluted by integrity lines (v2 contract)" || ok "--csv untouched by integrity section"
echo "$csv" | grep -q 'without evidence' && no "--csv polluted by the [x]-without-evidence line" || ok "--csv untouched by the [x]-without-evidence line"
out2=$(bash "$REPO/scripts/harness-report.sh" "$WORK/l111")
echo "$out2" | grep -q 'clean — scoreboard, donelogs, cards and defects agree' && ok "healthy dataset reports clean" || no "healthy dataset not reported clean"
D2="$WORK/l117b"; mkdir -p "$D2/.ai_context/tasks/ghost"
cardx "$D2/.ai_context/tasks/ghost" ghost '- [ ] S1 a — lanes: smoke ; codex: no'
out3=$(bash "$REPO/scripts/harness-report.sh" "$D2"); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out3" | grep -q 'orphan task: tasks/ghost/'; } && ok "orphan surfaces even with an empty scoreboard (cold-start case)" || no "cold-start orphan hidden by the no-data early exit"
D3="$WORK/l117c"; mkdir -p "$D3/.ai_context"
out4=$(bash "$REPO/scripts/harness-report.sh" "$D3")
echo "$out4" | grep -q 'no harness data yet' && ok "truly-empty project still gets the no-data line" || no "no-data early exit regressed"

echo "=== L1-34 · harness-report v4: --row, defects, fix-commit candidates, --tripwire, pair runlog"
HR="$REPO/scripts/harness-report.sh"
utc() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
gco() { # $1 = repo, $2 = epoch, $3 = subject: commit everything at that author/committer time
  git -C "$1" add -A && GIT_AUTHOR_DATE="@$2 +0000" GIT_COMMITTER_DATE="@$2 +0000" git -C "$1" commit -qm "$3"
}
D="$WORK/l134"; DT="$D/.ai_context/tasks/demo"; mkdir -p "$D/src" "$DT" "$D/.claude/evidence"
TC=$(( $(date +%s) - 5 * 86400 ))   # the task closed five days ago
git -C "$D" init -q; echo a > "$D/src/a.txt"; echo o > "$D/src/other.txt"; gco "$D" $((TC - 3 * 86400)) base
base=$(git -C "$D" rev-parse HEAD)
echo a2 >> "$D/src/a.txt"; gco "$D" $((TC - 2 * 86400)) "S1 change a"
head=$(git -C "$D" rev-parse HEAD)
echo a3 >> "$D/src/a.txt"; gco "$D" $((TC - 86400)) "fix: early"   # touches the task's file, but before the close
{ echo '# Demo'; echo "<!-- card v4 ; pair: off ; base: $base ; estimate: 2h 100L -->"; echo 'Goal: fixture'; echo '## Slices'
  echo '- [x] S1 a — lanes: smoke ; codex: no ✓ smoke@1a2b3c4d check@5e6f7a8b'
  echo '- [x] S2 b — lanes: smoke ; codex: no ✓ smoke@2b3c4d5e check@6f7a8b9c'
  echo '- [x] S3 c — lanes: smoke ; codex: no ✓ smoke@3c4d5e6f check@7a8b9c0d'
  echo "Closed: tree:4d3c2b1a0f9e head:${head:0:12} ✓ smoke@3c4d5e6f check@8b9c0d1e — $(utc "$TC")"; } > "$DT/card.md"
{ T0=$((TC - 5400)); r() { printf '%s\t%s\n' "$(utc $((T0 + $1)))" "$2"; }
  r 0 "APPROVE	-	human	efb2b73e63fb	-	-"; r 60 "START	S1	-	8a7b6c5d4e3f	-	started"; r 120 "RUN	S1	smoke	9c8b7a6f5e4d	1a2b3c4d	pass"
  r 180 "BLOCK	S1	noref	-	-	block 1/2"; r 240 "BLOCK	S1	noref	-	-	block 2/2"; r 300 "STUCK	S1	noref	4d3c2b1a0f9e	-	yielded after 3 blocks on the same card and content"
  r 360 "CODEX	S1	codex-slice	9c8b7a6f5e4d	0a1b2c3d	reject"; r 420 "CODEX	S1	codex-slice	9c8b7a6f5e4d	0b1c2d3e	approve"
  r 480 "CHECK	S1	checker	9c8b7a6f5e4d	5e6f7a8b	pass"; r 540 "DONE	S1	-	9c8b7a6f5e4d	smoke@1a2b3c4d,check@5e6f7a8b	ok"
  r 5400 "CLOSE	-	-	4d3c2b1a0f9e	smoke@3c4d5e6f,check@8b9c0d1e	ok"; } > "$DT/donelog"
printf 'spawned-by: claude-starter@0000000 on 2026-01-01\nsynced-to: claude-starter@abc1234 on 2026-10-01\n' > "$D/.claude/.starter-version"
echo "$SB_V4" > "$D/.ai_context/scoreboard-v4.csv"
echo 'date,slug,slice,finder,phase,severity,n,summary,fixed_in,ref' > "$D/.ai_context/defects.csv"
echo '{"id":"5e6f7a8b","lane":"checker","unit":"S1","verdict":"pass"}' > "$D/.claude/evidence/checker.jsonl"
want1="$(utc "$TC" | cut -c1-10),demo,3,2,1,2,-,90,success,abc1234"
row1=$(bash "$HR" --row demo "$D" 2>"$WORK/hr.err"); rc=$?
[ "$row1" = "$want1" ] && ok "--row: one row from card + donelog (slices 3, blocks 2, stuck 1, codex_runs 2, interventions -, 90 min, harness stamp)" || no "--row printed '$row1' (want '$want1')"
{ [ "$rc" = 0 ] && [ ! -s "$WORK/hr.err" ]; } && ok "--row: exit 0, nothing on stderr" || no "--row: rc=$rc stderr: $(head -c 200 "$WORK/hr.err")"
cp "$DT/card.md" "$WORK/l134-card"; grep -v '^Closed:' "$WORK/l134-card" > "$DT/card.md"
bash "$HR" --row demo "$D" >/dev/null 2>"$WORK/hr.err"; rc=$?
{ [ "$rc" = 3 ] && grep -qF 'has no Closed: line — ask the human' "$WORK/hr.err"; } && ok "--row without Closed: asks for the outcome (exit 3)" || no "--row without Closed: rc=$rc $(head -c 200 "$WORK/hr.err")"
out=$(bash "$HR" --row demo --outcome abandoned "$D" 2>/dev/null); rc=$?
{ [ "$rc" = 0 ] && [ "$(echo "$out" | cut -d, -f9)" = abandoned ]; } && ok "--row --outcome abandoned scores the unfinished task" || no "--outcome abandoned: rc=$rc '$out'"
cp "$WORK/l134-card" "$DT/card.md"
bash "$HR" --row nosuch "$D" >/dev/null 2>"$WORK/hr.err"; rc=$?
{ [ "$rc" = 3 ] && grep -qF 'card.md not found' "$WORK/hr.err"; } && ok "--row of a task without a card exits 3 (v4 tasks only)" || no "--row nosuch: rc=$rc $(head -c 200 "$WORK/hr.err")"
# fix-commit candidates: commits after the close that touch the task's files
echo fix >> "$D/src/a.txt"; gco "$D" "$(date +%s)" "fix: repair a"; s6=$(git -C "$D" rev-parse HEAD | cut -c1-7)
out=$(bash "$HR" "$D")
echo "$out" | grep -qF "defect candidate: $s6 " && echo "$out" | grep -qF '"fix: repair a" touches 1 file(s) of tasks/demo/' && ok "a fix commit after the close on the task's file is a defect candidate" || no "fix-commit candidate missing: $(echo "$out" | grep -F 'candidate' | head -c 300)"
echo more >> "$D/src/a.txt"; gco "$D" "$(date +%s)" "feat: more a"
bash "$HR" "$D" | grep -qF '"feat: more a"' && no "a feat: commit listed as a defect candidate" || ok "a feat: commit on the same file is not a candidate"
echo o2 >> "$D/src/other.txt"; gco "$D" "$(date +%s)" "fix: other"
bash "$HR" "$D" | grep -qF '"fix: other"' && no "a fix on an unrelated file listed" || ok "a fix: commit on a file the task never touched is not a candidate"
bash "$HR" "$D" | grep -qF '"fix: early"' && no "a fix made before the close listed" || ok "a fix: commit before the close is not a candidate"
out=$(cd "$D" && bash "$HR" --defect-dismiss "$s6" 2>&1)
{ [ "$out" = "defect candidate $s6 dismissed" ] && ! bash "$HR" "$D" | grep -qF "defect candidate: $s6" \
  && tail -n 1 "$D/.ai_context/defects.csv" | grep -qE ",fix-commit,-,none,0,dismissed: not a defect of the closed work,$s6,-\$"; } \
  && ok "--defect-dismiss settles the candidate with a severity-none row" || no "--defect-dismiss: '$out' / $(tail -n 1 "$D/.ai_context/defects.csv")"
out=$(cd "$D" && bash "$HR" --defect demo S1 human major "x" - 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ "${out#defect recorded: }" != "$out" ] && tail -n 1 "$D/.ai_context/defects.csv" | awk -F, 'NF == 10 && $4 == "human" && $5 == "post-close" {f = 1} END {exit !f}'; } \
  && ok "--defect writes a 10-column row; the phase is derived (post-close: the card is Closed)" || no "--defect: rc=$rc '$out' / $(tail -n 1 "$D/.ai_context/defects.csv")"
( cd "$D" && bash "$HR" --defect demo S1 badfinder major "x" - ) >/dev/null 2>"$WORK/hr.err"; rc=$?
{ [ "$rc" = 1 ] && grep -qF 'is not one of' "$WORK/hr.err"; } && ok "--defect rejects a finder outside the enum (exit 1)" || no "badfinder: rc=$rc $(head -c 200 "$WORK/hr.err")"
( cd "$D" && bash "$HR" --defect demo S1 checker unrated "x" - ) >/dev/null 2>"$WORK/hr.err"; rc=$?
( cd "$D" && bash "$HR" --defect demo S1 checker major "x" check@5e6f7a8b ) >/dev/null 2>&1; rc2=$?
{ [ "$rc" = 1 ] && grep -qF 'needs ref check@<id>|codex@<id>' "$WORK/hr.err" && [ "$rc2" = 1 ]; } && ok "checker rows need a ledger record ref and severity unrated (R26)" || no "checker finder: rc=$rc/$rc2 $(head -c 200 "$WORK/hr.err")"
out=$(bash "$HR" "$D")
echo "$out" | grep -qF 'post-close: 1 (human 1,' && echo "$out" | grep -qF 'by severity: blocker 0 · major 1 · minor 0 · unrated 0' && ok "== defects counts phases and severities (the dismissed row counts nowhere)" || no "defect counts wrong: $(echo "$out" | grep -A2 '== defects' | tr '\n' '|')"
Pc="$WORK/l134c"; mkproj "$Pc"; mklanes "$Pc" "$LANE_SMOKE"; mkcard "$Pc" demo off '- [~] S1 first — lanes: smoke ; codex: no'
rep S1 pass 'NOT VERIFIED (L2) a — b' | ev "$Pc" check S1 --agent fx --source human >/dev/null
id=$(lastid "$Pc" checker.jsonl)
tail -n 1 "$Pc/.ai_context/defects.csv" 2>/dev/null | awk -F, -v r="check@$id" '$2 == "demo" && $3 == "S1" && $4 == "checker" && $5 == "pre-done" && $6 == "unrated" && $7 == 1 && $10 == r {f = 1} END {exit !f}' \
  && ok "a failing checker record lands in defects.csv (checker, pre-done, unrated, n = NOT VERIFIED count, ref check@<id>)" || no "checker defect row: '$(tail -n 1 "$Pc/.ai_context/defects.csv" 2>/dev/null)' (id $id) $(head -c 200 "$WORK/ev.err")"
csv=$(bash "$HR" --csv "$D")
{ [ "$(echo "$csv" | head -1)" = "$CSV_V2" ] && [ "$(echo "$csv" | sed 1d | grep -c .)" -ge 1 ] && ! echo "$csv" | sed 1d | grep -qv '^2,'; } && ok "--csv: the v2 header, every data row starts with csv_version 2" || no "--csv v2 shape wrong: $(echo "$csv" | head -3 | tr '\n' '|')"
V="$WORK/l134v"; mkdir -p "$V/.ai_context"
printf 'date,slug,profile,size,milestones,gate_failures,highest_rung,interventions,duration_min,outcome,harness\n2026-07-01,a,opus-tier,M,4,0,1,0,30,success,h1\n2026-07-02,b,opus-tier,M,5,0,1,0,40,failed,h1\n' > "$V/.ai_context/scoreboard.csv"
printf '%s\n2026-11-01,c,3,0,0,1,-,60,success,h1\n' "$SB_V4" > "$V/.ai_context/scoreboard-v4.csv"
{ bash "$HR" "$V" | grep -qF 'tasks: 3 (success 2, failed 1, abandoned 0)' && [ "$(csvget "$(bash "$HR" --csv "$V")" h1 slices_sum codex_runs_sum)" = '3 1' ]; } \
  && ok "v3 scoreboard.csv and scoreboard-v4.csv read together; v3 rows add nothing to slices_sum (R25)" || no "v3+v4 scoreboards: $(bash "$HR" --csv "$V" | tr '\n' '|')"
mv "$D/.claude/evidence" "$D/.claude/evidence.off"
[ "$(bash "$HR" --row demo "$D" 2>/dev/null)" = "$want1" ] && ok "--row reads card + donelog only, never the per-machine ledger (R25)" || no "--row changed without the ledger"
mv "$D/.claude/evidence.off" "$D/.claude/evidence"
rm "$D/.ai_context/scoreboard-v4.csv"
[ "$(bash "$HR" --row demo "$D" 2>/dev/null)" = "$(printf '%s\n%s' "$SB_V4" "$want1")" ] && ok "--row prints the v4 header first when scoreboard-v4.csv is missing" || no "--row without scoreboard-v4.csv: $(bash "$HR" --row demo "$D" 2>&1 | tr '\n' '|')"
echo "$SB_V4" > "$D/.ai_context/scoreboard-v4.csv"
cp "$D/.ai_context/defects.csv" "$WORK/l134-defects"
printf 'date,what,where,who,when,sev,fix,ref\n2026-01-01,x,y,z,w,major,-,-\n' > "$D/.ai_context/defects.csv"
bash "$HR" "$D" >/dev/null 2>"$WORK/hr.err"; rc=$?
( cd "$D" && bash "$HR" --defect demo S1 human minor "x" - ) >/dev/null 2>"$WORK/hr.err2"; rc2=$?
{ [ "$rc" = 0 ] && grep -qF 'non-v4 header' "$WORK/hr.err" && [ "$rc2" = 2 ] && grep -qF 'has a non-v4 header' "$WORK/hr.err2"; } \
  && ok "a project's own defects.csv: the report warns and skips it, --defect refuses to append (exit 2)" || no "foreign defects.csv: report rc=$rc, --defect rc=$rc2 $(head -c 200 "$WORK/hr.err2")"
cp "$WORK/l134-defects" "$D/.ai_context/defects.csv"
echo late >> "$D/src/a.txt"; gco "$D" $((TC + 31 * 86400)) "fix: late"
bash "$HR" "$D" | grep -qF '"fix: late"' && no "a fix 31 days after the close listed" || ok "candidates stop 30 days after the close"
( cd "$D" && bash "$HR" --defect demo S1 post-close-review minor "y" - ) >/dev/null 2>&1; rc=$?
( cd "$D" && bash "$HR" --defect demo S1 review minor "y" - ) >/dev/null 2>&1; rc2=$?
{ [ "$rc" = 0 ] && [ "$rc2" = 1 ]; } && ok "finder post-close-review accepted, the old name review refused (R26)" || no "post-close-review rc=$rc, review rc=$rc2"
Pt="$WORK/l134t"; mkproj "$Pt"; mklanes "$Pt" '@verify-paths tests/' "$LANE_SMOKE"; mkcard "$Pt" demo off '- [~] S1 first — lanes: smoke ; codex: no'
printf '%s\tAPPROVE\t-\thuman\tefb2b73e63fb\t-\t-\n' "$(utc $(( $(date +%s) - 3600 )))" > "$Pt/.ai_context/tasks/demo/donelog"
mkdir -p "$Pt/tests"; seq 60 > "$Pt/tests/t.txt"; seq 10 > "$Pt/src/b.txt"
tw=$(cd "$Pt" && bash scripts/harness-report.sh --tripwire demo 2>&1)
echo "$tw" | grep -qE '^tripwire: product \+10 · verify \+60 lines since base [0-9a-f]{7} · 1\.0h of 2h est\. — TRIPPED: verify>product$' && ok "--tripwire: verify lines over product lines (>= 50) trip it" || no "--tripwire: '$tw'"
rc=$(ev "$Pt" status --line); { [ "$rc" = 0 ] && grep -qF 'tripwire: verify>product' "$WORK/ev.out"; } && ok "evidence.sh status --line carries the tripped reasons" || no "status --line: rc=$rc $(head -c 300 "$WORK/ev.out")"
rm "$Pt/tests/t.txt"
tw=$(cd "$Pt" && bash scripts/harness-report.sh --tripwire demo 2>&1)
echo "$tw" | grep -q ' — ok$' && ok "--tripwire within the estimate ends in ok" || no "--tripwire (product only): '$tw'"
mkdir -p "$D/.ai_context/tasks/nc"
printf '# NC\n<!-- card v4 ; pair: off ; base: %s ; estimate: 1h 10L -->\n## Slices\n- [ ] S1 a — lanes: smoke ; codex: no\nClosed: tree:000000000000 head:000000000000 ✓ smoke@1a2b3c4d check@5e6f7a8b — 2026-01-01T00:00:00Z\n' "$base" > "$D/.ai_context/tasks/nc/card.md"
printf '2026-01-01T00:00:00Z\tAPPROVE\t-\thuman\tefb2b73e63fb\t-\t-\n' > "$D/.ai_context/tasks/nc/donelog"
bash "$HR" "$D" | grep -qF 'Closed: without a CLOSE row: tasks/nc/' && ok "a Closed: line no CLOSE row backs is surfaced (written by hand?)" || no "Closed: without a CLOSE row not surfaced"
mkdir -p "$DT/pair"
{ p() { printf '2026-11-02T01:00:0%s\t%s\t%s\t%s\t%s\t-\t-\tGPT-5.6-Sol high\t-\t%s\t%s\n' "$@"; }
  p 0 1 reset - - - '/new + current worktree'; p 1 1 start card card - 'timeout=7200000ms'; p 2 1 end:failed card card - not_started
  p 3 2 start card card - 'timeout=7200000ms'; p 4 2 end:failed card card - herdr_blocked
  p 5 3 start slice S1 - 'timeout=7200000ms'; p 6 3 blocked slice S1 - 'the judge waits for the human'
  # shellcheck disable=SC2088 # the runlog writes the rollout path with a literal ~ (task-pair.sh tilde())
  p 7 3 end:completed slice S1 '~/.codex/sessions/2026/11/02/rollout-x.jsonl' 'verdict=pass blocker=0 major=0 minor=0'; } > "$DT/pair/runlog"
bash "$HR" "$D" | grep -qF 'pair runlog: Codex runs 1 (completed 1, failed 0) · not started 2 (never a run) · blocked mid-run 1 · record failed 0' \
  && ok "pair runlog: not_started / herdr_blocked attempts are never counted as Codex runs" || no "pair runlog line: $(bash "$HR" "$D" | grep -F 'pair runlog' || echo none)"
echo '2026-11-02,demo,S1,human,post-close,huge,1,x,-,-' >> "$D/.ai_context/defects.csv"
bash "$HR" "$D" | grep -qF 'enum violation: defects 2026-11-02: severity="huge"' && ok "a defects.csv severity outside the enum is an integrity line" || no "defects enum violation not surfaced"

echo "=== L1-35 · wrap, setup and defect skills; append-only and bulk guards (v4)"
SK="$REPO/.claude/skills"
f="$SK/wrap/SKILL.md"
{ grep -qF 'harness-report.sh --row' "$f" && grep -qF 'Re-run every command state.md cites' "$f" && ! grep -qF -- '--sweep' "$f" && ! grep -qF 'Offer to commit' "$f"; } \
  && ok "wrap: the row comes from harness-report.sh --row, cited commands re-run, no --sweep, commits itself" || no "wrap SKILL.md lost --row / re-run, or still says --sweep / Offer to commit"
f="$SK/wrap/reference.md"
{ grep -qF 'knowledge/lessons/' "$f" && grep -qF 'one lesson per file' "$f" && grep -qF 'never add a' "$f" && grep -qF -- '--defect-dismiss' "$f" && grep -qF 'scoreboard-v4.csv' "$f" \
  && ! grep -qF 'gatelog' "$f" && ! grep -qF -- '--sweep' "$f"; } && ok "wrap reference: lessons one per file (no twins), defect candidates, scoreboard-v4.csv; no gatelog or --sweep" || no "wrap reference.md content drifted"
f="$SK/setup/SKILL.md"
{ grep -qF '/run-skill-generator' "$f" && grep -qF 'verify-template.md' "$f" && grep -qF 'evidence.sh trust' "$f" && grep -qF '.claude/done-lanes' "$f" && grep -qF 'Proven:' "$f" && ! grep -q 'milestone' "$f"; } \
  && ok "setup: run skill, verify skill from the template, lanes declared and trusted, Proven: stamp; no milestones" || no "setup SKILL.md lacks the v4 mechanisms step or still says milestone"
f="$SK/defect/SKILL.md"
{ grep -q '^name: defect$' "$f" && grep -q '^disable-model-invocation: true$' "$f"; } 2>/dev/null && ok "defect skill registers, user-invoked only" || no "defect/SKILL.md missing or not user-invoked"
{ grep -qF 'harness-report.sh --defect' "$f" && grep -qF 'Never edit `defects.csv` by hand' "$f"; } 2>/dev/null && ok "defect: writes through harness-report.sh --defect, never by hand" || no "defect SKILL.md lost the script or the never-by-hand rule"
D="$WORK/l135"; DT="$D/.ai_context/tasks/demo"; mkdir -p "$DT" "$D/.claude"
printf '2026-11-02T01:00:00Z\tSTART\tS1\t-\t8a7b6c5d4e3f\t-\tstarted\n2026-11-02T01:05:00Z\tRUN\tS1\tsmoke\t9c8b7a6f5e4d\t1a2b3c4d\tpass\n' > "$DT/donelog"
printf 'date,slug,slice,finder,phase,severity,n,summary,fixed_in,ref\n2026-11-02,demo,S1,human,pre-done,minor,1,x,-,-\n' > "$D/.ai_context/defects.csv"
printf '%s\n2026-11-02,demo,1,0,0,0,-,10,success,abc1234\n' "$SB_V4" > "$D/.ai_context/scoreboard-v4.csv"
printf '# ts\tlane\tcmd_sha\tlane_sha\tdir_sha\tcanary_sha\tcanary_result — written only by scripts/evidence.sh trust; append-only\n2026-11-02T01:00:05Z\tsmoke\t3f2a9c0d1e2b\t77aa01bc23de\t5d6e7f809a1b\tc0ffee123456\tred:exit=1\n' > "$D/.claude/done-lanes.trust"
printf '# Demo\n- [~] S1 a\n' > "$DT/card.md"; printf '## Rulings\n- none\n' > "$DT/notes.md"
git -C "$D" init -q && git -C "$D" add -A && git -C "$D" commit -qm base
ao() { ( cd "$D" && git add -A && bash "$REPO/scripts/check-append-only.sh" ) >/dev/null 2>&1; echo $?; }
undo() { ( cd "$D" && git reset -q && git checkout -q -- . ); }
sed -i.bak '1d' "$DT/donelog" && rm -f "$DT/donelog.bak"; ck 1 "$(ao)" "a deleted donelog row blocks the commit"; undo
sed -i.bak 's/pass$/fail/' "$DT/donelog" && rm -f "$DT/donelog.bak"; ck 1 "$(ao)" "a donelog row changed in place blocks the commit"; undo
grep -E '^ +name: "append-only:' "$REPO/.pre-commit-config.yaml" | grep -q 'donelog' && grep -E '^ +name: "append-only:' "$REPO/.pre-commit-config.yaml" | grep -q 'trust' \
  && ok "the append-only hook names donelog and trust (R24: files regex keeps gatelog|spawnlog)" || no "append-only hook name lacks donelog or trust"
miss=""
for c in '.ai_context/tasks/*/donelog) ;;' '.claude/done-lanes.trust) ;;' '.ai_context/scoreboard-v4.csv) ;;' '.ai_context/defects.csv) ;;' '.ai_context/tasks/*/gatelog) ;;' '.ai_context/tasks/*/spawnlog) ;;'; do
  grep -qF -- "$c" "$REPO/scripts/check-append-only.sh" || miss="$miss [$c]"
done
[ -z "$miss" ] && ok "check-append-only.sh covers donelog, the trust file, scoreboard-v4.csv, defects.csv and still the v3 logs" || no "check-append-only.sh case list lacks:$miss"
sed -i.bak 's/red:exit=1/skip:none/' "$D/.claude/done-lanes.trust" && rm -f "$D/.claude/done-lanes.trust.bak"; ck 1 "$(ao)" "an edited done-lanes.trust row blocks the commit"; undo
sed -i.bak 's/minor/blocker/' "$D/.ai_context/defects.csv" && rm -f "$D/.ai_context/defects.csv.bak"; ck 1 "$(ao)" "an edited defects.csv row blocks the commit"; undo
printf '2026-11-02T01:06:00Z\tCHECK\tS1\tchecker\t9c8b7a6f5e4d\t5e6f7a8b\tpass\n' >> "$DT/donelog"
printf '2026-11-03,demo,S1,human,post-done,major,1,y,-,-\n' >> "$D/.ai_context/defects.csv"
printf '2026-11-03,demo,1,0,0,0,-,12,success,abc1234\n' >> "$D/.ai_context/scoreboard-v4.csv"
printf '2026-11-03T01:00:05Z\tsmoke\t3f2a9c0d1e2b\t77aa01bc23de\t5d6e7f809a1b\tc0ffee123456\tred:exit=1\n' >> "$D/.claude/done-lanes.trust"
ck 0 "$(ao)" "appending to donelog, defects.csv, scoreboard-v4.csv and done-lanes.trust passes"; undo
printf '# Demo\n- [x] S1 a ✓ smoke@1a2b3c4d check@5e6f7a8b\n' > "$DT/card.md"; printf '## Rulings\n- one\n' > "$DT/notes.md"
ck 0 "$(ao)" "rewriting card.md and notes.md passes (deliberately not append-only)"; undo
python3 - "$DT/donelog" <<'PY'
import sys; open(sys.argv[1],'a').write(('2026-11-02T01:07:00Z\tWAITING\tS1\tsubagent:executor\t-\t-\tdeferred\n')*2600)
PY
( cd "$D" && git add -A && bash "$REPO/scripts/check-context-bulk.sh" ) >/dev/null 2>&1
ck 0 $? "a 150 KB donelog passes the S2 bulk guard (machine log, R34)"; undo

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

echo "=== L1-33 · agents and the task skill (v4): checker, executor, card / lanes / evidence"
AG="$REPO/.claude/agents"; TK="$REPO/.claude/skills/task"
f="$AG/checker.md"
{ [ "$(sed -n 1p "$f" 2>/dev/null)" = '---' ] && grep -q '^name: checker$' "$f" && grep -q '^description: .' "$f"; } && ok "checker.md registers (frontmatter; name: checker is what the Subagent matchers see)" || no "checker.md missing or its frontmatter is broken"
grep -q '^tools: Bash, Read, Grep, Glob$' "$f" && ok "checker tools: Bash, Read, Grep, Glob (it cannot edit)" || no "checker tools line: '$(grep '^tools:' "$f" 2>/dev/null)'"
n=$(wc -l < "$f" 2>/dev/null); [ "${n:-999}" -le 70 ] && ok "checker.md within 70 lines ($n — injected into every checker)" || no "checker.md is ${n:-?} lines (> 70)"
{ grep -qF 'checker-verdict: S<n> pass|fail' "$f" && grep -qF 'VERIFIED (L4)' "$f" && grep -qF 'VERIFIED at L4' "$f" && grep -qF '"Check card"' "$f"; } \
  && ok "checker: verdict line, claim grammar, first claim VERIFIED at L4-5 (R10), card mode (U7)" || no "checker.md lost its verdict line, claim grammar, the L4 first-claim rule or \"Check card\""
{ grep -qF 'checker-verdict:' "$f" && grep -qF 'checker-verdict:' "$REPO/scripts/evidence.sh"; } && ok "checker-verdict: named by the agent and by the parser (evidence.sh check)" || no "checker-verdict: missing from checker.md or scripts/evidence.sh"
{ grep -qF 'git checkout' "$f" && grep -qF 'git stash' "$f" && grep -qF 'git restore' "$f" && grep -qF 'run `evidence.sh check`' "$f"; } && ok "checker never runs git checkout / stash / restore or evidence.sh check" || no "checker.md lost its forbidden-command list"
f="$AG/executor.md"
{ grep -q '^name: executor$' "$f" && grep -qF 'evidence.sh run' "$f" && ! grep -qF -- '- verify:' "$f"; } && ok "executor: name: executor, proves with evidence.sh run (no v3 verify: line)" || no "executor.md name, evidence.sh run or a v3 '- verify:' line wrong"
grep -qF 'Never edit `card.md` marks' "$f" && ok "executor keeps its hands off the card marks and the evidence" || no "executor.md lost 'Never edit \`card.md\` marks'"
hits=""
for f in "$AG"/*.md "$REPO"/.claude/skills/*/*.md; do
  h="$(grep -oE 'plan\.md|spec\.md|brief\.md|lessons\.md|gatelog|spawnlog|STATUS\.md|task-profile|final-verifier|plan-critic|reframer|scout|--sweep|/ack-' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
  [ -z "$h" ] || hits="$hits ${f#"$REPO"/}: $h"
done
[ -z "$hits" ] && ok "agents and every skill file name no v3 /task artefact" || no "v3 artefacts still named:$hits"
n=$(wc -l < "$TK/SKILL.md"); [ "$n" -le 150 ] && ok "task SKILL.md within 150 lines ($n — U10, ADR-039)" || no "task SKILL.md is $n lines (> 150)"
n=$(wc -l < "$TK/reference.md"); [ "$n" -le 120 ] && ok "task reference.md within 120 lines ($n — read on demand)" || no "task reference.md is $n lines (> 120)"
{ [ "$(sed -n 1p "$TK/SKILL.md")" = '---' ] && grep -q '^name: task$' "$TK/SKILL.md" && grep -q '^description: .' "$TK/SKILL.md"; } && ok "task skill registers (name + description frontmatter)" || no "task SKILL.md frontmatter broken"
miss=""
for s in 'evidence.sh start' 'evidence.sh done' 'evidence.sh approve' 'evidence.sh trust' 'check card' 'check slice' 'check final' \
         'even with every check green' '[ASSUMED]' 'task/<slug>' 'considered, not built' '/goal' 'or stop after' 'shared premise' 'notes.md'; do
  grep -qF -- "$s" "$TK/SKILL.md" || miss="$miss [$s]"
done
[ -z "$miss" ] && ok "task SKILL.md carries the v4 protocol (evidence.sh steps, Codex checks, intake and stuck rules)" || no "task SKILL.md lacks:$miss"
subs="$(grep -ohE 'evidence\.sh [a-z]+' "$TK/SKILL.md" "$TK/reference.md" | awk '{print $2}' | sort -u)"; miss=""
for s in $subs; do grep -qE "^  $s\) shift; cmd_$s " "$REPO/scripts/evidence.sh" || miss="$miss $s"; done
{ [ "$(echo "$subs" | wc -w)" -ge 8 ] && [ -z "$miss" ]; } && ok "every evidence.sh subcommand the task skill names exists ($(echo $subs))" || no "task skill names evidence.sh subcommands without a case:${miss:- (only $(echo "$subs" | wc -w) parsed)}"
miss=""
for h in Resume Notes Lanes Approval Spawn Escalation 'Close report'; do grep -qx "## $h" "$TK/reference.md" || miss="$miss [$h]"; done
[ -z "$miss" ] && ok "task reference.md has its seven sections (SKILL.md points at them)" || no "task reference.md missing:$miss"
Pl="$WORK/l133l"; mkproj "$Pl"; mklanes "$Pl" "$(sed -nE 's/^ *(smoke \| .*)$/\1/p' "$TK/reference.md" | head -n 1)"
mkcard "$Pl" demo off '- [ ] S1 first — lanes: smoke ; codex: no'
rc=$(ev "$Pl" lint); { [ "$rc" = 0 ] && grep -q '^card lint ok' "$WORK/ev.out"; } && ok "reference.md's example smoke lane passes evidence.sh lint" || no "example lane refused (rc=$rc): $(cat "$WORK/ev.out" "$WORK/ev.err" | head -c 300)"
left=""
for f in .claude/agents/{planner,plan-critic,reframer,scout,final-verifier,verifier}.md scripts/{task-profile,task-status,task-statusline}.sh; do
  [ -e "$REPO/$f" ] && left="$left $f"
done
[ -z "$left" ] && ok "v3 crew (planner, plan-critic, reframer, scout, final-verifier, verifier) and task-profile/status/statusline are gone" || no "retired files still shipped:$left"
ms="$(python3 -I -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]; print(" ".join(sorted({e.get("matcher","") for k in ("SubagentStart","SubagentStop") for e in h.get(k,[])})))' "$REPO/.claude/settings.json" 2>/dev/null)"; miss=""
for m in $ms; do grep -qx "name: $m" "$AG/$m.md" 2>/dev/null || miss="$miss $m"; done
{ [ -n "$ms" ] && [ -z "$miss" ]; } && ok "every Subagent matcher names an agent file whose frontmatter name is the matcher ($ms)" || no "Subagent matchers without a matching agent name:${miss:- (none parsed)}"
# The hooks review (H1): spawn-log reads only the checker's CURRENT wake, so
# the agent text must ask for the whole report again on every re-wake.
grep -qF 'reads only this wake' "$AG/checker.md" && grep -qF 'SendMessage re-wake' "$AG/checker.md" && ok "checker: every wake, a SendMessage re-wake too, ends with the whole report" || no "checker.md does not ask for the full report on every wake"
# checker.md's own closing block, filled in and handed back, is a report the
# hook records: spawn-log -> the real evidence.sh check (agent text and parser
# share one grammar). The block is indented in the file; the checker writes it
# unindented, as the file says.
blk="$(sed -nE 's/^    ((VERIFIED|NOT VERIFIED|INCONCLUSIVE) \(L[1-5]\) |checker-verdict: )/\1/p' "$AG/checker.md")"
crec() { python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(r["unit"], r["verdict"], r["verified"], r["not_verified"], r["inconclusive"], r["source"])' "$1/.claude/evidence/checker.jsonl" 2>/dev/null; }
Pc="$WORK/l133c"; mkproj "$Pc"; mklanes "$Pc" "$LANE_SMOKE"; ev "$Pc" trust smoke >/dev/null
mkcard "$Pc" demo off '- [~] S1 first — lanes: smoke ; codex: no'
ev "$Pc" approve >/dev/null; ev "$Pc" start S1 >/dev/null; ev "$Pc" run smoke >/dev/null
mktr "$WORK/t133a" "$(printf '## Ran\n$ bash scripts/verify.sh → exit 0, 1s, verify: 3 passed, 0 failed\n\n%s\n' "$(sed 's/^checker-verdict: S<n> pass|fail$/checker-verdict: S1 fail/' <<<"$blk")")" agent-checker-handback.jsonl
mkstop "$WORK/p133a" "$WORK/t133a"; CLAUDE_PROJECT_DIR="$Pc" bash "$SL" checker stop < "$WORK/p133a" >/dev/null 2>&1
[ "$(crec "$Pc")" = 'S1 fail 1 1 1 handback' ] && ok "checker.md's example block, handed back, is recorded: S1 fail, 1 VERIFIED / 1 NOT VERIFIED / 1 INCONCLUSIVE" || no "example block record: '$(crec "$Pc")' (block: $(echo "$blk" | head -c 200))"
mktr "$WORK/t133b" "$(sed -e '/^NOT VERIFIED /d' -e 's/^checker-verdict: S<n> pass|fail$/checker-verdict: S1 pass/' <<<"$blk")" agent-checker-handback.jsonl
mkstop "$WORK/p133b" "$WORK/t133b"; CLAUDE_PROJECT_DIR="$Pc" bash "$SL" checker stop < "$WORK/p133b" >/dev/null 2>&1
rc=$(ev "$Pc" "done" S1); { [ "$(crec "$Pc")" = 'S1 pass 1 0 1 handback' ] && [ "$rc" = 0 ]; } && ok "the same block without its NOT VERIFIED line records a pass that done accepts" || no "pass variant: '$(crec "$Pc")', done rc=$rc $(head -c 200 "$WORK/ev.out")"

echo "=== L1-21 · every exit-2 block prints the stdout marker (CLI heuristic, v3.14)"
# The missing-hook heuristic (exit 2 + EMPTY stdout + stderr matching
# /no such file|can't open/i) silently drops legitimate blocks — journal
# 2026-08-13. Non-empty stdout breaks the conjunction; every block path
# must print the marker. mk() runs the gate and asserts rc=2 + marker on stdout.
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
printf '# Demo task\n<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->\nGoal: marker\n## Slices\n- [x] S1 first — lanes: smoke ; codex: no\n' > "$D/.ai_context/tasks/demo/card.md"
mk "noref" tsuite-mk2 "$D"
# a closed task whose lane content changed after close; one failing smoke
# record on the way, for the badref case below
Pm="$WORK/l121c"; ready "$Pm"; ev "$Pm" start S2 >/dev/null
echo broken > "$Pm/src/mode"; ev "$Pm" run smoke >/dev/null; fid="$(lastid "$Pm" smoke.jsonl)"; rm -f "$Pm/src/mode"
ev "$Pm" run smoke >/dev/null; rep S2 pass | ev "$Pm" check S2 --agent fx --source human >/dev/null; ev "$Pm" "done" S2 >/dev/null
rep final pass | ev "$Pm" check final --agent fx --source human >/dev/null; ev "$Pm" close >/dev/null
echo b >> "$Pm/src/a.txt"; mk "Closed: stale" tsuite-mk3 "$Pm"; echo a > "$Pm/src/a.txt"
# static net: no exit-2 path exists that the runtime cases miss
n_exit2=$(grep -c 'exit 2' "$GATE")
n_mark=$(grep -c 'mark_block$\|mark_block;' "$GATE")
[ "$n_mark" -ge 2 ] && ok "mark_block wired across block paths ($n_mark call sites, $n_exit2 exit-2 lines)" || no "mark_block call sites: want >=2 got $n_mark"
C="$Pm/.ai_context/tasks/demo/card.md"; sed -i '/^Closed:/d' "$C"; cp "$C" "$WORK/c121"
sed -E 's/^(- \[x\] S1 .*) ✓ .*$/\1 ✓ smoke@00000000 check@00000000/' "$WORK/c121" > "$C"
mk "badref: id not found" tsuite-mk4 "$Pm"
sed -E "s/^(- \[x\] S1 .* ✓ )smoke@[0-9a-f]+/\1smoke@$fid/" "$WORK/c121" > "$C"
mk "badref: failing record" tsuite-mk5 "$Pm"

echo "=== L1-22 · a human checkpoint slice [o]: the gate passes and shows it (v4)"
D="$WORK/l122"; mkproj "$D"; mklanes "$D" "$LANE_SMOKE"
mkcard "$D" demo off '- [o] S1 gated deploy — lanes: smoke ; codex: no' '- [ ] S2 aftermath — lanes: smoke ; codex: no'
rc=$(gt "$D" tsuite-ck1); ck 0 "$rc" "an [o] checkpoint slice holds without a block"
grep -qF 'claude-starter gate: evidence[demo]: slice -' "$WORK/g.out" && ok "the status line shows no slice in progress while [o] waits" || no "status line: $(cat "$WORK/g.out")"
rc=$(gt "$D" tsuite-ck1); ck 0 "$rc" "the next stop still passes (the checkpoint is the human's, not the gate's)"


echo "=== L1-23 · pair-codex transport: task-pair.sh over a fake herdr (ADR-028, v4)"
# Every scenario asserts the same invariant from two sides: a run that did
# not end in a checkable result never exits 0, and the script never prints
# a verdict of its own. The fake herdr replays herdr 0.9.0 JSON shapes and the
# Codex 0.165.0 screens of the C4 live re-record (2026-10-28); a stub
# evidence.sh logs what task-pair.sh hands it (L1-44 swaps in the real one).
PD="$WORK/l123"; FK="$WORK/l123-fake"   # fake herdr's log/state live OUTSIDE the fixture repo
CD="$PD/.ai_context/tasks/pdemo"; PKD="$CD/pair"; RL="$PKD/runlog"
mkdir -p "$PD/scripts" "$PD/.claude/hooks" "$PKD" "$FK/bin" "$FK/codex-home" "$FK/empty-home" "$FK/state"
cp "$REPO/scripts/task-pair.sh" "$REPO/scripts/precommit-gitleaks.sh" "$PD/scripts/"; cp "$REPO/.claude/hooks/guard-patterns.sh" "$REPO/.claude/gitleaks.toml" "$PD/.claude/hooks/"
mv "$PD/.claude/hooks/gitleaks.toml" "$PD/.claude/"   # the real evidence.sh (L1-44) hashes it with the lane directives
cp "$REPO/tests/fake-herdr.sh" "$FK/bin/herdr"; chmod +x "$FK/bin/herdr"
cat > "$PD/scripts/evidence.sh" <<'EOF'
#!/usr/bin/env bash
# L1-23 stub of scripts/evidence.sh: logs each call; codex appends a record in
# codex.jsonl's shape (what task-pair.sh counts the quota and the re-ask gate
# from; its tree is FAKE_EVIDENCE_TREE, else one `status --tree` never prints)
# and prints its id
L="${FAKE_EVIDENCE_LOG:-/dev/null}"
case "$1" in
  codex) printf '%s model=%s rollout=%s secs=%s\n' "$*" "${PAIR_MODEL:-}" "${PAIR_ROLLOUT:-}" "${PAIR_SECS:-}" >> "$L"
         n="$(grep -c '^codex ' "$L")"; [ "${FAKE_EVIDENCE_RC:-0}" = 0 ] || { echo "rec-$n"; exit "$FAKE_EVIDENCE_RC"; }
         h="$(head -n 6 "$3" 2>/dev/null | tr -d '\r')"; v=none; b=0; m=0
         if [ "$4" = completed ]; then v="$(sed -n 's/^verdict: //p' <<<"$h")"; b="$(sed -n 's/^blocker: //p' <<<"$h")"; m="$(sed -n 's/^major: //p' <<<"$h")"; fi
         mkdir -p .claude/evidence
         printf '{"id":"rec-%s","lane":"codex-%s","unit":"%s","tree":"%s","task":"pdemo","run_state":"%s","verdict":"%s","critical":%s,"high":%s,"packet_sha":"%s"}\n' \
           "$n" "$(sed -n 's/^stage: //p' "$2" | head -n 1)" "$(sed -n 's/^unit: //p' "$2" | head -n 1)" "${FAKE_EVIDENCE_TREE:-stub-record}" \
           "$4" "${v:-none}" "${b:-0}" "${m:-0}" "$(sha256sum < "$2" | cut -c1-64)" >> .claude/evidence/codex.jsonl
         echo "rec-$n"
         # L1-47 (L7): a signal to task-pair.sh right after its record is written
         case "${FAKE_EVIDENCE_KILL:-}" in TERM|9) kill "-$FAKE_EVIDENCE_KILL" "$(cut -f1 .claude/evidence/locks/pair-*.lock | head -n 1)"; sleep 1 ;; esac ;;
  show) echo "$*" >> "$L"; [ "${FAKE_EVIDENCE_NOREC:-0}" = 1 ] && { echo "evidence: no record for $2" >&2; exit 1; }
        echo "record: {\"id\":\"0123abcd\",\"lane\":\"$2\",\"exit\":0,\"executed\":3,\"verdict\":\"pass\"}"
        if [ "${FAKE_EVIDENCE_FLAGGED:-0}" = 1 ]; then echo "log withheld: scan hit fake"
        else echo "--- log tail (60 lines) ---"; tail -n 60 "$FAKE_EVIDENCE_LANELOG"; fi ;;
  status) echo "$*" >> "$L"; [ "${2:-}" != --tree ] || { echo "${FAKE_EVIDENCE_TREE:-stub-tree}"; exit 0; }
          printf 'evidence status — task pdemo (stub)\nlane smoke: %s — stub\n' "${FAKE_EVIDENCE_LANE:-fresh}" ;;
  lint) echo "$*" >> "$L"; exit "${FAKE_EVIDENCE_LINT:-0}" ;;
esac
exit 0
EOF
printf '# p\n## Definition of done\n- t.sh prints ok\n## Project rules\n- no network\n' > "$PD/CLAUDE.md"
printf 'echo ok\n' > "$PD/t.sh"; printf '.pytest_cache/\n.claude/evidence/\n' > "$PD/.gitignore"
( cd "$PD" && git init -q . && git add -A && git commit -qm init )
PH="$(git -C "$PD" rev-parse HEAD)"
H8="$(printf '%s' "$(cd "$PD" && pwd)" | sha256sum | cut -c1-8)"   # task-pair.sh's REPO_ID recipe
JN="judge-$H8-pdemo"; EVD="$PD/.claude/evidence/pair/pdemo"   # the judge's herdr name; run state (gitignored, Edit-denied)
pcard() { # $1 = codex|off: S1 done, S2 in progress (codex: yes), S3 open
  printf '# p\n<!-- card v4 ; pair: %s ; base: %s ; estimate: 1h 50L -->\nGoal: g\nDone when: `bash t.sh` prints ok ; outside check: the human runs t.sh\nDecisions: [human] bash only\n## Slices\n- [x] S1 thin path — lanes: smoke ; codex: no ✓ smoke@0123abcd\n- [~] S2 money path — lanes: smoke ; codex: yes ; notes: §Limits\n- [ ] S3 later — lanes: smoke ; codex: no\n' "$1" "$PH" > "$CD/card.md"
}
plane() { { [ "$1" = on ] && echo '@pair codex'; echo 'smoke | t.sh | 1 | ^ok$ | false | bash t.sh'; } > "$PD/.claude/done-lanes"; }
pcedit() { sed "$@" "$CD/card.md" > "$FK/card.tmp" && mv "$FK/card.tmp" "$CD/card.md"; }
pcard codex; plane on; echo pdemo > "$PD/.ai_context/tasks/CURRENT"
printf '# notes\n## Limits\n- at most 3 orders\n## Unused\n- UNUSED-MARKER\n' > "$CD/notes.md"
seq 1 100 | sed 's/^/line /' > "$FK/lane.log"
( cd "$PD" && git add -A && git commit -qm card )
HD="$(git -C "$PD" rev-parse HEAD)"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$PD" > "$FK/codex-home/config.toml"
pdl() { printf '%s\t%s\t%s\t-\t%s\t-\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" "$3" "${4:-x}" >> "$CD/donelog"; }   # TYPE slice tree12 [result]
pdig() { ( cd "$PD" && bash scripts/task-pair.sh digest 2>/dev/null ); }
pstart() { pdl START "$1" "$(printf %.12s "$PH")" started; }
papprove() { pdl APPROVE - "$(pdig | cut -c6-17)" codex_est=3; }
pstart S2; papprove
mkpkt() { printf 'stage: %s\nunit: %s\nbase: %s\nscratch: /tmp/x/%s\n\n# packet body\n' "$2" "$3" "$4" "$1" > "$PKD/$1-$2.md"; echo "$PKD/$1-$2.md"; }   # one seq, one packet sha (as packet's scratch: line makes it)
# tp <ENV=val ...> -- <task-pair args>: runs inside the fixture with the fake
# herdr on PATH; stdout/stderr land in $FK/out and $FK/err, rc is echoed.
# tp adds --over-estimate to send/check (transport tests send one unit many
# times; the quota has its own block, L1-43, which uses tpn).
tpx() {
  local flag="$1" envs=(); shift
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  if [ "$flag" = 1 ]; then case "${1:-}" in send|check) set -- "$@" --over-estimate ;; esac; fi
  ( cd "$PD" && env HERDR_ENV=1 PATH="$FK/bin:$PATH" CODEX_HOME="$FK/codex-home" \
      FAKE_HERDR_LOG="$FK/herdr.log" FAKE_HERDR_STATE="$FK/state" \
      FAKE_EVIDENCE_LOG="$FK/evidence.log" FAKE_EVIDENCE_LANELOG="$FK/lane.log" TASK_PAIR_START_GRACE_S=1 TASK_PAIR_NEW_WAIT_S=3 "${envs[@]}" \
      bash scripts/task-pair.sh "$@" ) >"$FK/out${TPSFX:-}" 2>"$FK/err${TPSFX:-}"; echo $?
}
tp() { tpx 1 "$@"; }
tpn() { tpx 0 "$@"; }
prompts() { grep '^agent prompt' "$FK/herdr.log" 2>/dev/null | grep -vc ' /new$'; }   # packet prompts only (/new is a slash command)
no_verdict_printed() { ! grep -q 'PASS\|FAIL' "$FK/out" "$FK/err"; }
recs() { grep -c "^codex [^ ]*/$1-" "$FK/evidence.log" 2>/dev/null; }   # records handed to evidence.sh for seq $1
nfiles() { find "$PKD" -maxdepth 1 -name '*.md' | wc -l | tr -d ' '; }

# --- refusals happen before any herdr call --------------------------------
pcard off; plane off
rc=$(tp -- ensure); ck 3 "$rc" "pair off (no @pair, card pair: off): ensure refuses"
[ ! -s "$FK/herdr.log" ] && ok "no herdr call while pair is off" || no "herdr was called with pair off"
pcard codex; rc=$(tp -- digest); ck 0 "$rc" "a card can raise pair (card pair: codex, no @pair in done-lanes)"
plane on; pcard off; rc=$(tp -- digest); ck 0 "$rc" "a card's pair: off cannot lower the project's @pair codex"
grep -q 'a card can only raise pair' "$FK/err" && ok "...and says so on stderr" || no "pair: off under @pair codex was silent: $(cat "$FK/err")"
pcard codex; mv "$CD/card.md" "$FK/card.saved"; rc=$(tp -- ensure); mv "$FK/card.saved" "$CD/card.md"
ck 3 "$rc" "no card: ensure refuses (pair runs start once the card exists)"
rc=$(tp HERDR_ENV=0 -- ensure); ck 3 "$rc" "ensure refuses outside herdr (HERDR_ENV != 1)"
rc=$(tp CODEX_HOME="$FK/empty-home" -- ensure); ck 3 "$rc" "ensure refuses when Codex has not trusted the repo"
grep -q 'trust' "$FK/err" && ok "untrusted refusal names the fix" || no "untrusted refusal message missing"
# Hooks tripwire: a judge we did not start cannot prove hooks are off.
mkdir -p "$PD/.codex"; printf '{"hooks":{}}' > "$PD/.codex/hooks.json"
rc=$(tp FAKE_HERDR_AGENT=idle -- ensure); ck 3 "$rc" "ensure refuses a foreign judge when .codex/hooks.json exists"
mkdir -p "$EVD"; printf 'name=%s\npane_id=w9:p9\nhooks_off=1\ndoc_max_bytes=32768\n' "$JN" > "$EVD/judge"
rc=$(tp FAKE_HERDR_AGENT=idle -- ensure); ck 0 "$rc" "ensure accepts a judge whose record says hooks off at the current doc cap"
rm -rf "$PD/.codex" "$EVD/judge"
rc=$(tp FAKE_HERDR_AGENT=idle -- ensure); ck 3 "$rc" "a judge with no record is refused even without .codex/hooks.json (its doc cap is unknown)"
: > "$FK/herdr.log"

# --- ensure starts the judge with the verified argument set -----------------
rc=$(tp -- ensure); ck 0 "$rc" "ensure starts a judge when none is live"
st_line="$(grep '^agent start' "$FK/herdr.log" || true)"
printf '%s' "$st_line" | grep -q -- '-c features.hooks=false' && ok "judge starts with Codex hooks disabled (no second Stop gate)" || no "judge started with hooks enabled: $st_line"
printf '%s' "$st_line" | grep -q -- '-s workspace-write' && ok "judge starts in workspace-write (read-only cannot even mktemp)" || no "judge sandbox flag wrong: $st_line"
printf '%s' "$st_line" | grep -q 'project_doc_fallback_filenames' && ok "judge reads CLAUDE.md as its project doc" || no "CLAUDE.md fallback missing: $st_line"
printf '%s' "$st_line" | grep -qE -- '(^| )-m |model_reasoning_effort|-c model=' && no "judge pins a model/effort (must inherit the user's Codex default)" || ok "judge inherits the user's Codex model and effort"
printf '%s' "$st_line" | grep -q -- '-c project_doc_max_bytes=32768' && ok "X1: a small CLAUDE.md starts the judge with project_doc_max_bytes=32768" || no "doc cap missing from start argv: $st_line"
grep -qx 'hooks_off=1' "$EVD/judge" && ok "judge record written (hooks_off=1)" || no "judge record missing"
grep -qx 'doc_max_bytes=32768' "$EVD/judge" && ok "judge record keeps the doc cap it was started with" || no "judge record lacks doc_max_bytes: $(cat "$EVD/judge")"
grep -q 'GPT-5.6-Sol high' "$FK/out" && ok "ensure reports the observed model from the status line (0.165.0: capitalised model)" || no "model not scraped: $(cat "$FK/out")"
rc=$(tp -- ensure); ck 0 "$rc" "ensure is idempotent (judge present)"
[ "$(grep -c '^agent start' "$FK/herdr.log")" -eq 1 ] && ok "second ensure does not start a second judge" || no "ensure restarted a live judge"
printf '  Trust this folder? Codex can read, edit, and run files\n\n› 1. Trust and continue\n  2. Quit\n\n  enter continue · esc quit\n' > "$FK/trust.txt"
rm -f "$FK/state/agent" "$EVD/judge"; : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_START=not_ready FAKE_HERDR_SCREEN="$FK/trust.txt" -- ensure)
{ [ "$rc" = 4 ] && grep -qx 'doc_max_bytes=32768' "$EVD/judge" && ! grep -q '^agent send-keys' "$FK/herdr.log"; } \
  && ok "a judge that starts into a dialog (agent_not_ready): exit 4, no key sent, its record kept for the next ensure" || no "not_ready start (rc=$rc): $(cat "$FK/err")"
rm -f "$EVD/judge"; tp -- ensure >/dev/null

# --- send: the happy path, the record, and the script's silence on verdicts ---
pk=$(mkpkt 001 slice S2 "$HD")
rc=$(tp -- send "$pk"); ck 0 "$rc" "send: completed run exits 0"
[ -s "${pk%.md}.result.md" ] && ok "send: result file collected" || no "send: result missing"
grep -q "	001	start	slice	S2	$HD	" "$RL" && ok "runlog: start row (seq, stage, unit, base)" || no "runlog start row malformed: $(cat "$RL")"
grep -q "	001	end:completed	" "$RL" && ok "runlog: end:completed row" || no "runlog end row missing"
grep -q 'state=completed (verdict=pass blocker=0 major=0 minor=0)' "$FK/out" && ok "send: summary echoes the judge's header verbatim, lowercase" || no "send summary wrong: $(cat "$FK/out")"
no_verdict_printed && ok "script prints no PASS/FAIL of its own" || no "script printed a verdict"
{ grep -q "	001	start	.*	GPT-5.6-Sol high	0/0	" "$RL" && grep -q "	001	end:completed	.*	GPT-5.6-Sol high	1200/340	" "$RL"; } && ok "runlog rows record the observed model and token counters (0/0 after /new, 1200/340 after the turn)" || no "runlog model/tokens columns wrong: $(cat "$RL")"
[ ! -e "$PKD/001-slice.screen.txt" ] && ok "completed run leaves no screen dump" || no "screen dump written for a completed run"
# Fresh thread per packet (ADR-030): send itself sends /new right before the
# packet prompt, and the runlog shows the reset row before the start row.
grep '^agent prompt' "$FK/herdr.log" | grep -B1 'Read and execute' | head -1 | grep -q ' /new$' \
  && ok "send: /new is the prompt right before the packet prompt" || no "send did not open a fresh thread: $(grep '^agent prompt' "$FK/herdr.log" | cut -c1-60 | tr '\n' '|')"
grep -B1 "	001	start	" "$RL" | head -1 | grep -q "	001	reset	" && ok "runlog: reset row (same seq) precedes the start row" || no "runlog start row not preceded by a reset row: $(cat "$RL")"
{ [ "$(grep -c '^codex ' "$FK/evidence.log")" = 1 ] && grep -q '^codex [^ ]*/001-slice\.md [^ ]*/001-slice\.result\.md completed verdict=pass blocker=0 major=0 minor=0 model=' "$FK/evidence.log"; } \
  && ok "send: the settled run is handed to evidence.sh codex once (packet, result, state, reason)" || no "evidence.sh codex call wrong: $(cat "$FK/evidence.log")"
grep -q "^codex .* model=GPT-5.6-Sol high rollout=$FK/codex-home/sessions/[0-9/]*/rollout-[^ ]*-fake-001-slice\.jsonl secs=[0-9][0-9]*$" "$FK/evidence.log" && ok "...with the observed model, this run's Codex transcript and duration in its environment" || no "PAIR_* env not passed: $(cat "$FK/evidence.log")"
grep -q 'record=rec-1$' "$FK/out" && ok "send: summary names the record id evidence.sh printed" || no "record id missing: $(cat "$FK/out")"
{ grep 'Read and execute' "$FK/herdr.log" | head -1 | grep -q -- '--wait --timeout 7200000$' && ! grep -q 540000 "$FK/herdr.log"; } \
  && ok "send: herdr's wait is 2 hours (background run), the v3 540 s cap is gone" || no "prompt timeout wrong: $(grep 'Read and execute' "$FK/herdr.log" | head -1 | grep -o -- '--timeout.*')"
ls "$PD/.claude/evidence/locks/"pair-*.lock >/dev/null 2>&1 && no "send left a pair lock behind" || ok "send: no pair lock is left after the run"
{ grep -q "Keep every temporary file under /tmp/pair-$H8-pdemo/001\. " "$FK/herdr.log" && [ ! -e "/tmp/pair-$H8-pdemo/001" ]; } \
  && ok "send: the prompt names the judge's scratch /tmp/pair-<repo hash>-<slug>/<seq>, removed once completed" || no "scratch path wrong or kept: $(grep -o 'under [^ ]*' "$FK/herdr.log" | head -1)"

# --- send: every way a run can end without a usable result -----------------
pk=$(mkpkt 002 slice S2 "$HD")
rc=$(tp FAKE_HERDR_PROMPT=no_result -- send "$pk"); ck 6 "$rc" "idle without a result file is failed:no_result"
grep -q "	002	end:failed	.*	no_result$" "$RL" && ok "runlog: no_result recorded" || no "runlog no_result row missing"
[ -s "$PKD/002-slice.screen.txt" ] && ok "failed run saves the judge's screen next to the packet" || no "screen dump missing for the failed run"
pk=$(mkpkt 003 slice S2 "$HD")
rc=$(tp FAKE_HERDR_PROMPT=bad_header -- send "$pk"); ck 6 "$rc" "result without a verdict line is failed:bad_header"
grep -q "	003	end:failed	.*	bad_header:verdict$" "$RL" && ok "runlog: bad_header:<key> recorded" || no "runlog bad_header row missing: $(grep '	003	end' "$RL")"
pk=$(mkpkt 004 slice S2 "$HD")
rc=$(tp FAKE_HERDR_PROMPT=base_mismatch -- send "$pk"); ck 6 "$rc" "result for another base is failed:base_mismatch"
pk=$(mkpkt 005 slice S2 "$HD")
rc=$(tp FAKE_HERDR_PROMPT=tree_changed FAKE_HERDR_TOUCH="$PD/CLAUDE.md" -- send "$pk"); ck 6 "$rc" "a judge that touched the tree voids its own result (tree_changed)"
grep -q "	005	end:failed	.*	tree_changed$" "$RL" && ok "runlog: tree_changed recorded" || no "runlog tree_changed row missing"
[ -s "${pk%.md}.result.md" ] && ok "tree_changed: the (voided) result file is kept as evidence" || no "tree_changed result vanished"
git -C "$PD" checkout -q CLAUDE.md
pk=$(mkpkt 006 slice S2 "$HD")
rc=$(tp FAKE_HERDR_PROMPT=timeout -- send "$pk"); ck 5 "$rc" "herdr timeout leaves the run in flight (exit 5, wait in the background)"
grep -q "	006	waiting	" "$RL" && ok "runlog: waiting row on timeout" || no "runlog waiting row missing"
{ [ -f "$EVD/fp-006" ] && [ ! -e "$PKD/.fp-006" ]; } && ok "in-flight state kept for wait — in .claude/evidence/pair/<slug>/, not in pair/" || no "in-flight state missing or in pair/"
grep -q 'task-pair.sh wait 006' "$FK/out" && ok "timeout output names the wait command" || no "timeout output lacks the wait hint"
r6="$(recs 006)"
rc=$(tp FAKE_HERDR_WAIT=ok -- wait 006); ck 0 "$rc" "wait: settles the in-flight run"
grep -q "	006	end:completed	" "$RL" && ok "runlog: wait completed the run" || no "runlog after wait wrong"
[ ! -f "$EVD/fp-006" ] && ok "in-flight state cleared after settle" || no "stale fp file left"
rc=$(tp -- wait 006); ck 2 "$rc" "wait refuses a seq with no run in flight"
pk=$(mkpkt 007 slice S2 "$HD"); p0=$(prompts)
rc=$(tp FAKE_HERDR_PROMPT=stalled -- send "$pk"); ck 6 "$rc" "agent_prompt_stalled with no sign of a turn is not_started (6), not resent"
[ "$(prompts)" -eq $((p0 + 1)) ] && ok "stalled prompt was not resubmitted" || no "prompt count after stall: $(prompts) (before $p0)"
grep -q "	007	end:failed	.*	not_started$" "$RL" && ok "runlog: a stall that never became a turn is not_started" || no "stall row: $(grep '	007	' "$RL")"
pk9=$(mkpkt 009 slice S2 "$HD")   # written before 008 runs: a new file in pair/ would void it
pk=$(mkpkt 008 slice S2 "$HD")
rc=$(tp FAKE_HERDR_PROMPT=blocked -- send "$pk"); ck 4 "$rc" "judge blocked mid-run exits 4 (human)"
{ grep -q "	008	blocked	" "$RL" && ! grep -q "	008	end:" "$RL" && [ -f "$EVD/fp-008" ] && [ -f "$EVD/parked-008" ]; } \
  && ok "blocked mid-run: a blocked row, nothing settled, the run stays in flight (fp-008, parked-008)" || no "blocked mid-run: $(grep '	008	' "$RL")"
p0=$(prompts)
rc=$(tp -- send "$pk9"); ck 4 "$rc" "send refuses while the judge is still blocked mid-run"
[ "$(prompts)" -eq "$p0" ] && ok "nothing was typed into a blocked judge" || no "prompt sent to a blocked judge"
grep -q 'task-pair.sh wait 008' "$FK/err" && ok "...and names the wait that re-attaches once the human answered" || no "blocked refusal: $(cat "$FK/err")"
rc=$(tp -- wait 008); ck 0 "$rc" "wait 008 re-attaches once the human answered and settles the run"
{ [ "$(recs 008)" = 1 ] && grep -q '^codex [^ ]*/008-slice\.md [^ ]* completed verdict=pass' "$FK/evidence.log" && [ ! -e "$EVD/fp-008" ] && [ ! -e "$EVD/parked-008" ]; } \
  && ok "...one record, of the finished run" || no "blocked run after wait: $(grep 008 "$FK/evidence.log")"
miss=""; for w in 002:failed:no_result 003:failed:bad_header:verdict 004:failed:base_mismatch 005:failed:tree_changed; do
  s="${w%%:*}"; r="${w#*:}"
  [ "$(recs "$s")" = 1 ] && grep -q "^codex [^ ]*/$s-slice\.md [^ ]* ${r%%:*} ${r#*:} model=" "$FK/evidence.log" || miss="$miss $s"
done
[ -z "$miss" ] && ok "every settled failure became one record with its state and reason" || no "records missing or wrong for:$miss"
[ "$(recs 007)" = 0 ] && ok "a stall that never became a turn writes no record" || no "the stall was recorded"
[ "$r6" = 0 ] && ok "a herdr timeout (exit 5) writes no record — the run has not settled" || no "a timed-out run was recorded"
{ [ "$(recs 006)" = 1 ] && grep -q '^codex [^ ]*/006-slice\.md [^ ]* completed verdict=pass' "$FK/evidence.log"; } && ok "wait records the run once it settles" || no "wait did not record: $(grep 006 "$FK/evidence.log")"
[ "$(recs 009)" = 0 ] && ok "a send refused at a blocked judge writes no record" || no "a refused send was recorded"

# --- modal dialogs: herdr says idle, the screen says otherwise ---------------
# Texts recorded live (2026-10-28): the trust dialog on Codex 0.165.0, the
# update notice on 0.162.1; one trust case keeps the 0.154 wording. The
# rate-limit nudge is the 0.154 text: not verified on 0.165.0.
SCR="$FK/screen.txt"
nokeys() { ! grep -q "^agent send-keys $JN" "$FK/herdr.log"; }
printf '  Folder access\n  /fixture\n\n  Trust this folder? Codex can read, edit, and run files\n  here, subject to your permission settings.\n\n› 1. Trust and continue\n  2. Quit\n\n  enter continue · esc quit\n' > "$SCR"
pk=$(mkpkt 010 slice S2 "$HD"); p0=$(prompts); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" -- send "$pk"); ck 4 "$rc" "trust dialog (0.165.0 'Trust this folder?') on screen: refused, never answered"
{ [ "$(prompts)" = 0 ] && nokeys; } && ok "no prompt and no key (its esc quits Codex) sent into the trust dialog" || no "keys or prompt sent over a trust dialog: $(grep -c . "$FK/herdr.log")"
grep -q "trust" "$FK/err" && ok "trust dialog is reported to the human" || no "trust dialog not reported"
ls "$PKD"/dialog-*.screen.txt >/dev/null 2>&1 && ok "dialog refusal saves the screen" || no "dialog screen dump missing"
printf '  Do you trust the contents of this directory? Working with untrusted contents\n› 1. Yes, continue\n  2. No, quit\n  Press enter to continue\n' > "$SCR"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" -- ensure); ck 4 "$rc" "the Codex 0.154 trust wording is still recognised"
printf '  Update available · 0.162.1 → 0.165.0\n  Release notes: https://github.com/openai/codex/releases/latest\n\n› 1. Update now (runs `sh -c '"'"'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh'"'"'`)\n  2. Skip\n  3. Skip until next version\n\n  enter continue · esc skip\n' > "$SCR"
cp "$SCR" "$FK/update.txt"; pk=$(mkpkt 011 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" FAKE_HERDR_ESC_CLEARS=0 -- send "$pk"); ck 4 "$rc" "an update notice that esc does not close: handed to the human"
{ [ "$(prompts)" = 0 ] && grep -q "^agent send-keys $JN esc\$" "$FK/herdr.log" && ! grep -q "^agent send-keys $JN enter" "$FK/herdr.log"; } \
  && ok "update notice: esc (skip) is the only key sent — never enter (it runs the installer), never the packet" || no "update notice keys: $(grep '^agent \(send-keys\|prompt\)' "$FK/herdr.log" | tr '\n' '|')"
cp "$FK/update.txt" "$SCR"; : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" FAKE_HERDR_ESC_CLEARS=1 -- send "$pk"); ck 0 "$rc" "update notice: skipped with esc, the run proceeds"
! grep -q "^agent send-keys $JN enter" "$FK/herdr.log" && ok "...and enter was never sent" || no "enter sent at an update notice"
printf '  Approaching rate limits\n  Switch to gpt-5.6-luna for lower credit usage?\n› 1. Switch to gpt-5.6-luna\n  2. Keep current model\n  Press enter to confirm or esc to go back\n' > "$SCR"
pk=$(mkpkt 012 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" FAKE_HERDR_ESC_CLEARS=1 -- send "$pk"); ck 0 "$rc" "rate-limit nudge: dismissed with esc, run proceeds"
grep -q "^agent send-keys $JN esc\$" "$FK/herdr.log" && ok "esc sent for the rate-limit nudge (keeps the current model)" || no "esc not sent"
printf '  Approaching rate limits\n  Switch to gpt-5.6-luna for lower credit usage?\n  Press enter to confirm or esc to go back\n' > "$SCR"
pk=$(mkpkt 013 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" FAKE_HERDR_ESC_CLEARS=0 -- send "$pk"); ck 4 "$rc" "a nudge that survives esc is handed to the human"
[ "$(prompts)" = 0 ] && ok "no prompt typed into a surviving dialog" || no "prompt sent over a surviving dialog"
printf '  Something new\n\n› 1. Do the thing\n  2. Do not\n\n  enter continue · esc cancel\n' > "$SCR"
pk=$(mkpkt 014 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" FAKE_HERDR_ESC_CLEARS=1 -- send "$pk")
{ [ "$rc" = 4 ] && [ "$(prompts)" = 0 ] && nokeys; } && ok "an unknown numbered dialog (› 1. … enter continue): handed over, no key, no prompt" || no "unknown dialog (rc=$rc): $(grep '^agent \(send-keys\|prompt\)' "$FK/herdr.log" | tr '\n' '|')"
{ printf '  >_ OpenAI Codex (v0.165.0)\n\n› Ask Codex to do anything\n\n'; printf '  GPT-5.6-Sol high · /tmp/work/fixtu…\n  ? for shortcuts                ⚠ 1 warning · f2 to view\n'; } > "$SCR"
pk=$(mkpkt 015 slice S2 "$HD")
rc=$(tp FAKE_HERDR_SCREEN="$SCR" -- send "$pk"); ck 0 "$rc" "the '⚠ 1 warning · f2 to view' footer is not a dialog"
grep -q "	015	end:completed	.*	GPT-5.6-Sol high	-	" "$RL" && ok "a narrow pane (cwd cut with …, no counters): model still read, tokens '-'" || no "narrow status line: $(grep '	015	end' "$RL")"
rm -f "$SCR"

# --- /new on Codex 0.165.0: the new-thread picker ----------------------------
pk=$(mkpkt 016 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_NEW=picker -- send "$pk"); ck 0 "$rc" "/new opens the picker: '1. Use current Git worktree' is taken with enter, the run completes"
{ [ "$(grep -c "^agent send-keys $JN enter\$" "$FK/herdr.log")" = 1 ] && grep -q "	016	reset	.*	/new + current worktree$" "$RL"; } \
  && ok "...one enter, and the reset row says so" || no "picker answer: $(grep '^agent send-keys' "$FK/herdr.log" | tr '\n' '|') $(grep '	016	reset' "$RL")"
awk -v n="$JN" '$0 == "agent send-keys " n " enter" {e = NR} index($0, "agent prompt " n " Read and execute") == 1 {p = NR} END {exit !(e && p > e)}' "$FK/herdr.log" \
  && ok "the packet prompt comes only after the picker is answered" || no "packet prompt order wrong"
pk=$(mkpkt 017 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_NEW=picker_other -- send "$pk"); rm -f "$FK/state/screen"
{ [ "$rc" = 4 ] && [ "$(prompts)" = 0 ] && nokeys && grep -q 'another choice highlighted' "$FK/err"; } && ok "picker on 'Create new Git worktree': handed over, no key, no packet" || no "picker_other (rc=$rc): $(cat "$FK/err")"
[ ! -e "$EVD/fp-017" ] && ! grep -q "	017	start	" "$RL" && ok "...and no run was started (no start row, nothing in flight)" || no "a start row was written for an unsent packet"
pk=$(mkpkt 018 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_NEW=picker_stuck -- send "$pk"); rm -f "$FK/state/screen"
{ [ "$rc" = 4 ] && [ "$(prompts)" = 0 ] && [ "$(grep -c "^agent send-keys $JN enter\$" "$FK/herdr.log")" = 1 ]; } && ok "a picker that one enter does not close: handed over after one enter, packet never typed" || no "picker_stuck (rc=$rc)"

printf '  ? for shortcuts\n' > "$SCR"; pk=$(mkpkt 019 slice S2 "$HD"); : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_SCREEN="$SCR" -- send "$pk"); rm -f "$SCR"
{ [ "$rc" = 4 ] && ! grep -q '^agent prompt' "$FK/herdr.log" && grep -q 'not at an empty prompt' "$FK/err"; } && ok "no composer on screen (and no dialog): handed over before /new" || no "no-composer screen (rc=$rc): $(cat "$FK/err")"

# --- the record is part of the run ------------------------------------------
pk=$(mkpkt 019 slice S2 "$HD")
rc=$(tp FAKE_EVIDENCE_RC=1 -- send "$pk")
{ [ "$rc" = 6 ] && grep -q "	019	record_failed	.*	rc=1$" "$RL" && grep -q 'NOT recorded' "$FK/err" && [ -f "$EVD/unrecorded-019" ] && [ ! -e "$EVD/fp-019" ]; } \
  && ok "evidence.sh codex failing: exit 6, a record_failed row, the settled run kept as unrecorded-019" || no "record_failed (rc=$rc): $(grep '	019	' "$RL")"
rc=$(tp -- packet card); x="$(cat "$FK/out")"; [ "$rc" = 0 ] && rm -f "$PD/$x"
[ "$rc" = 0 ] && ok "an unrecorded run blocks no new packet (M8)" || no "packet after record_failed (rc=$rc): $(cat "$FK/err")"
rc=$(tp -- wait 019); { [ "$rc" = 0 ] && [ "$(recs 019)" = 2 ] && [ ! -e "$EVD/unrecorded-019" ] && [ "$(prompts)" = 1 ]; } && ok "wait 019 retries the record (the judge is not asked again)" || no "wait after record_failed (rc=$rc, records $(recs 019))"

# --- packet hygiene ---------------------------------------------------------
pk=$(mkpkt 020 slice S2 0123456789abcdef0123456789abcdef01234567); p0=$(prompts)
rc=$(tp -- send "$pk"); ck 3 "$rc" "commit-shaped base that is not HEAD: stale packet refused (3), not sent"
[ "$(prompts)" -eq "$p0" ] && ok "stale packet never reached the judge" || no "stale packet was sent"
pk=$(mkpkt 021 card card "$(pdig)")
rc=$(tp -- send "$pk"); ck 0 "$rc" "a card:<digest> base equal to the current card digest is sent and matched"
pk=$(mkpkt 022 slice S2 "$HD"); : > "${pk%.md}.result.md"
rc=$(tp -- send "$pk"); ck 2 "$rc" "existing result file: refused (one packet, one run)"
printf 'unit: S2\nbase: %s\n' "$HD" > "$PKD/023-slice.md"
rc=$(tp -- send "$PKD/023-slice.md"); ck 2 "$rc" "packet without a stage: line is refused"
pk=$(mkpkt 024 card card "$(pdig)"); pcedit 's/^Goal: g$/Goal: g2/'
rc=$(tp -- send "$pk"); pcard codex
{ [ "$rc" = 3 ] && grep -q 'stale packet' "$FK/err"; } && ok "a card packet from before a content edit is stale (3), never sent" || no "stale card packet (rc=$rc): $(cat "$FK/err")"
pk=$(mkpkt 025 card card "$(pdig)")
pcedit -e 's/^- \[ \] S3 \(.*\)$/- [x] S3 \1 ✓ smoke@0123abce check@0123abcf/'
echo 'Closed: tree:0123456789ab head:0123456789ab ✓ smoke@0123abce check@0123abcf — 2026-10-28T00:00:00Z' >> "$CD/card.md"
rc=$(tp -- send "$pk"); ck 0 "$rc" "status marks, ✓ tokens and close's Closed: line leave a card packet current"
pcard codex

# --- packet slice / final: the judge's inputs are generated, not remembered ---
rc=$(tp -- packet slice S2); pk="$(cat "$FK/out")"
{ [ "$rc" = 0 ] && grep -qx "since: $PH" "$PD/$pk"; } && ok "packet slice S2 without --since: since = the HEAD its START row recorded, full sha" || no "slice packet (rc=$rc) since wrong: $(grep '^since' "$PD/$pk" 2>/dev/null) $(cat "$FK/err")"
[ "$pk" = ".ai_context/tasks/pdemo/pair/026-slice-S2.md" ] && ok "packet: seq continues after the last packet (026), stage and slice in the name" || no "packet path/seq wrong: $pk"
grep -qx "base: $HD" "$PD/$pk" && ok "packet: base is HEAD at generation time" || no "packet base wrong"
grep -qx 'lanes: smoke' "$PD/$pk" && ok "packet: lanes: header names the slice's lanes" || no "lanes header missing"
grep -qx '    - \[~\] S2 money path — lanes: smoke ; codex: yes ; notes: §Limits' "$PD/$pk" && ok "packet: the slice line is inlined verbatim" || no "slice line not inlined"
! grep -q '^    - \[.\] S[13] ' "$PD/$pk" && ok "packet: other slice lines are not inlined" || no "packet leaked another slice line"
grep -qF '    record: {"id":"0123abcd","lane":"smoke"' "$PD/$pk" && ok "packet: each lane's evidence.sh show output, verbatim" || no "show output missing"
{ grep -qx '    line 41' "$PD/$pk" && grep -qx '    line 100' "$PD/$pk" && ! grep -qx '    line 40' "$PD/$pk"; } && ok "packet: the log tail is show's last 60 lines (41..100)" || no "log tail wrong"
{ grep -q "^## Diff since $PH (stat" "$PD/$pk" && grep -q '^    untracked: ' "$PD/$pk"; } && ok "packet: diff stat since START and the untracked list" || no "diff stat / untracked missing"
{ grep -q 'Re-run each lane yourself' "$PD/$pk" && grep -q 'Check of a check' "$PD/$pk" && grep -qF 'VERIFIED|NOT VERIFIED|INCONCLUSIVE' "$PD/$pk" && grep -q 'do not run scripts/evidence.sh' "$PD/$pk"; } \
  && ok "packet: slice checklist (re-run lanes, check of a check, claim grades, hands off the ledger)" || no "slice checklist incomplete"
grep -q 'no summary from the implementer' "$PD/$pk" && ok "packet: the judge gets no implementer summary, on purpose" || no "no-summary line missing"
grep -q "^Write \.ai_context/tasks/pdemo/pair/026-slice-S2\.result\.md (relative to the repository root" "$PD/$pk" && ok "packet: result path derived from the packet name, repo-relative (so is the prompt's)" || no "packet result path wrong: $(grep '^Write' "$PD/$pk")"
grep -q 'once, with your$' "$PD/$pk" && grep -q '^file-edit tool (apply_patch, `\*\*\* Add File:`) — never through a shell command' "$PD/$pk" && ok "packet: the result is written once, with apply_patch — the write the record binds to" || no "packet: apply_patch instruction missing"
[ "$(grep -cx "base: $HD" "$PD/$pk")" = 2 ] && ok "packet: result contract pins the same base" || no "packet result-contract base wrong"
# rollout linkage (pair review L1): the judge's transcript is a Codex rollout
# written since the run began, in a day dir from the day before on, whose
# session_meta names this repo and which holds this packet's path (the
# prompt). Shape recorded on Codex 0.165.0 (first line session_meta;
# sessions/YYYY/MM/DD/). The decoys carry a future mtime: only their content
# or their day dir can rule them out.
RO="$FK/codex-home/sessions/$(date +%Y/%m/%d)"; RO0="$FK/codex-home/sessions/2000/01/01"; mkdir -p "$RO" "$RO0"
rmeta() { # $1 id, $2 ts, $3 cwd [, $4 the session's first prompt]
  printf '{"timestamp":"%s","ordinal":0,"type":"session_meta","payload":{"session_id":"%s","id":"%s","timestamp":"%s","cwd":"%s","runtime_workspace_roots":["%s"],"originator":"codex-tui","cli_version":"0.165.0"}}\n' "$2" "$1" "$1" "$2" "$3" "$3"
  [ -z "${4:-}" ] || printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$2" "$4"
}
rmeta b 2099-01-01T00:00:00.000Z "$PD" 'an unrelated session' > "$RO/rollout-b.jsonl"
rmeta c 2099-06-01T00:00:00.000Z /elsewhere "Read and execute the packet at $pk; x" > "$RO/rollout-c.jsonl"
rmeta e 2099-06-01T00:00:00.000Z "$PD" "Read and execute the packet at $pk; x" > "$RO0/rollout-e.jsonl"
rmeta d 2000-01-01T00:00:00.000Z "$PD" "Read and execute the packet at $pk; x" > "$RO/rollout-d.jsonl"   # right content, written before the run
python3 -I -c 'import os, sys, time; t = time.time() + 3600; [os.utime(f, (t, t)) for f in sys.argv[1:]]' "$RO/rollout-b.jsonl" "$RO/rollout-c.jsonl" "$RO0/rollout-e.jsonl"
rc=$(tp -- send "$pk"); ck 0 "$rc" "packet → send round-trips over the fake judge"
grep -q "	026	end:completed	.*	$FK/codex-home/sessions/[0-9/]*/rollout-[^	]*-fake-026-slice-S2\.jsonl	" "$RL" && ok "runlog: rollout column names this run's transcript (not another repo's or session's, not one from before the run or an old day dir)" || no "rollout linkage wrong: $(grep '	026	end' "$RL")"
# pair/ is tracked: a path under $HOME names the user, so it is written ~/…
rc=$(tp HOME="$WORK" -- packet slice S2); pk="$(cat "$FK/out")"; sq="${pk##*/}"; sq="${sq%%-*}"
{ [ "$rc" = 0 ] && grep -q '^You are the Codex judge for the active task in ~/l123\. ' "$PD/$pk" && ! grep -qF "$WORK/" "$PD/$pk"; } && ok "packet: paths under \$HOME are written ~/…" || no "home path in the packet (rc=$rc): $(grep -nF "$WORK/" "$PD/$pk" | head -3)"
rc=$(tp HOME="$WORK" -- send "$pk")
{ [ "$rc" = 0 ] && grep -q "	$sq	end:completed	.*	~/l123-fake/codex-home/sessions/[0-9/]*/rollout-[^	]*-fake-$sq-slice-S2\.jsonl	" "$RL" && ! grep "	$sq	" "$RL" | grep -qF "$WORK/"; } \
  && ok "runlog: the rollout column under \$HOME is ~/.codex/…-style, no home path in any row" || no "home path in the runlog (rc=$rc): $(grep "	$sq	end" "$RL")"
rc=$(tp FAKE_EVIDENCE_FLAGGED=1 -- packet slice S2); pk="$(cat "$FK/out")"
{ [ "$rc" = 0 ] && grep -q 'log withheld' "$PD/$pk" && ! grep -qE '^    line [0-9]+$' "$PD/$pk"; } && ok "packet: a log the secret scan flagged is withheld, not one line of it inlined" || no "flagged log leaked (rc=$rc)"
n0=$(nfiles); rc=$(tp FAKE_EVIDENCE_NOREC=1 -- packet slice S2)
{ [ "$rc" = 3 ] && [ "$(nfiles)" = "$n0" ]; } && ok "packet: a lane with no evidence record is refused (3), no file left" || no "no-record lane (rc=$rc)"
git -C "$PD" checkout -qb side; git -C "$PD" commit -q --allow-empty -m side; SIDE="$(git -C "$PD" rev-parse HEAD)"; git -C "$PD" checkout -q -
rc=$(tp -- packet slice S2 --since "$SIDE"); ck 2 "$rc" "packet: --since that is not an ancestor of HEAD is refused"
rc=$(tp -- packet slice S2 --since "$HD"); { [ "$rc" = 3 ] && grep -q 'binds the review only to that' "$FK/err"; } && ok "packet: --since other than the START head is refused — evidence.sh would not bind it" || no "foreign --since accepted (rc=$rc)"
echo 'echo changed' >> "$PD/t.sh"; n0=$(nfiles); rc=$(tp -- packet slice S2); git -C "$PD" checkout -q t.sh
{ [ "$rc" = 3 ] && grep -q 'uncommitted changes' "$FK/err" && [ "$(nfiles)" = "$n0" ]; } && ok "packet: uncommitted changes in the slice's lane paths are refused (commit first)" || no "dirty lane paths accepted (rc=$rc)"
rc=$(tp -- packet slice S9); ck 2 "$rc" "packet: a slice not on the card is refused"
grep -v '	START	S2	' "$CD/donelog" > "$FK/dl.tmp"; mv "$FK/dl.tmp" "$CD/donelog"; n0=$(nfiles)
rc=$(tp -- packet slice S2); pstart S2
{ [ "$rc" = 3 ] && grep -q 'no open START row' "$FK/err" && [ "$(nfiles)" = "$n0" ]; } && ok "packet: no START row for the slice → refused (3), no file left" || no "START-less slice packet (rc=$rc)"
pcedit -e 's/^- \[[ ~]\] \(S[23] .*\)$/- [x] \1/'   # the final judges the finished task: every slice [x] (marks keep the approval)
rc=$(tp -- packet final); pk="$(cat "$FK/out")"; ck 0 "$rc" "packet: final generates"
printf '%s' "$pk" | grep -qE '^\.ai_context/tasks/pdemo/pair/[0-9]{3}-final\.md$' && ok "packet: final is NNN-final.md" || no "final file name wrong: $pk"
grep -qx "since: $PH" "$PD/$pk" && ok "packet: final since = the card's base:, full sha" || no "final since wrong: $(grep '^since' "$PD/$pk")"
{ grep -q "git diff $PH\.\.HEAD" "$PD/$pk" && grep -qx 'Correctness' "$PD/$pk" && grep -qx 'Regression' "$PD/$pk" && grep -qx 'Test integrity' "$PD/$pk"; } && ok "packet: final names since..HEAD and the three checklists" || no "final body incomplete"
grep -qx '    evidence status — task pdemo (stub)' "$PD/$pk" && ok "packet: final inlines evidence.sh status verbatim" || no "status not inlined"
{ grep -qF "T3. git log -p $PH..HEAD -- .ai_context/tasks/pdemo/card.md .claude/done-lanes" "$PD/$pk" && grep -q 'T4. Every lane the status shows stale or missing' "$PD/$pk"; } && ok "packet: final carries T3 (card and lane history) and T4 (stale lanes)" || no "T3/T4 missing"
echo x > "$PD/stray.txt"; rc=$(tp -- packet final); rm -f "$PD/stray.txt"
{ [ "$rc" = 3 ] && grep -q 'judges committed work' "$FK/err"; } && ok "packet: final with uncommitted work outside .ai_context/ is refused" || no "dirty final accepted (rc=$rc)"
printf 'checker findings\n- major: suite skips t.sh — `grep skip t.sh`\n' > "$FK/rebut.md"
rc=$(tp FAKE_EVIDENCE_TREE=tf -- packet final --rebuttal "$FK/rebut.md")
{ [ "$rc" = 3 ] && grep -q 'there is none — run check final first' "$FK/err"; } && ok "packet: a rebuttal answers a completed final review of this content — none yet, refused" || no "rebuttal before any final review (rc=$rc): $(cat "$FK/err")"
rc=$(tp FAKE_EVIDENCE_TREE=tf -- send "$pk"); ck 0 "$rc" "packet final → send round-trips"
rc=$(tp FAKE_EVIDENCE_TREE=tf -- packet final --rebuttal "$FK/rebut.md"); pk="$(cat "$FK/out")"
{ [ "$rc" = 0 ] && printf '%s' "$pk" | grep -qE '/[0-9]{3}-final-rebuttal\.md$'; } && ok "packet: rebuttal round generates NNN-final-rebuttal.md" || no "rebuttal (rc=$rc): $pk"
{ grep -q '^# Rebuttal round' "$PD/$pk" && grep -qx '> checker findings' "$PD/$pk" && grep -q '^> - major: suite skips t.sh' "$PD/$pk" && grep -q 'reproduce it (command + output) or refute it' "$PD/$pk"; } \
  && ok "packet: rebuttal quotes the whole file and demands commands" || no "packet rebuttal incomplete"
rc=$(tp FAKE_EVIDENCE_TREE=tf -- send "$pk"); ck 0 "$rc" "the rebuttal round runs"
rc=$(tp FAKE_EVIDENCE_TREE=tf -- packet final --rebuttal "$FK/rebut.md"); ck 3 "$rc" "packet: a second rebuttal at the same content is refused"
n0=$(nfiles); rc=$(tp -- packet final --rebuttal "$FK/nope.md")
{ [ "$rc" = 2 ] && [ "$(nfiles)" = "$n0" ]; } && ok "packet: a refused packet leaves no file behind" || no "refused packet wrote a file (rc=$rc)"
pcard codex
rc=$(tp -- packet scout); ck 2 "$rc" "packet: unknown stage refused"
grep -q 'card | slice | final' "$FK/err" && ok "packet: the refusal names the three stages" || no "unknown-stage message: $(cat "$FK/err")"

# --- packet card: the card, the notes it cites, CLAUDE.md's rules -------------
rc=$(tp -- packet card); pk="$(cat "$FK/out")"
{ [ "$rc" = 0 ] && printf '%s' "$pk" | grep -qE '/[0-9]{3}-card\.md$'; } && ok "packet card generates NNN-card.md" || no "packet card (rc=$rc): $pk $(cat "$FK/err")"
{ grep -qx "base: $(pdig)" "$PD/$pk" && pdig | grep -qE '^card:[0-9a-f]{64}$'; } && ok "packet: card base = card:<sha256> = task-pair.sh digest" || no "card base wrong: $(grep -m1 '^base' "$PD/$pk") vs $(pdig)"
{ grep -qx '# Result contract' "$PD/$pk" && grep -qx 'run: completed|failed|blocked' "$PD/$pk" && ! grep -q '\.claude/agents' "$PD/$pk"; } && ok "packet: result contract inline, no agent-file pointer" || no "card contract wrong"
{ grep -qx '    Goal: g' "$PD/$pk" && grep -qx '    - \[ \] S3 later — lanes: smoke ; codex: no' "$PD/$pk"; } && ok "packet: the whole card is inlined, indented" || no "card not inlined"
{ grep -q '1. Executable done' "$PD/$pk" && grep -q '2. Ambiguity that changes the work' "$PD/$pk" && grep -q 'what would make the human REJECT this' "$PD/$pk" && grep -q '4. Decisions' "$PD/$pk"; } \
  && ok "packet: card checks 1-4, the direction question included" || no "card checks 1-4 missing"
{ grep -q 'need not guess' "$PD/$pk" && grep -q 'thinnest real end-to-end' "$PD/$pk" && grep -q '`codex: yes`' "$PD/$pk" && grep -q 'at most 5 claims' "$PD/$pk"; } \
  && ok "packet: card checks 5-9 (detail, thin slice 1, codex: yes, ≤5 spot checks)" || no "card checks 5-9 missing"
{ grep -qx '### §Limits' "$PD/$pk" && grep -qx '    - at most 3 orders' "$PD/$pk"; } && ok "packet: the notes section the card cites is inlined" || no "cited notes missing"
! grep -q 'UNUSED-MARKER' "$PD/$pk" && ok "packet: an uncited notes section is not" || no "uncited notes leaked"
{ grep -qx '    - t.sh prints ok' "$PD/$pk" && grep -qx '    - no network' "$PD/$pk"; } && ok "packet: CLAUDE.md's Definition of done and Project rules inlined" || no "CLAUDE.md sections missing"
{ grep -qx "scratch: /tmp/pair-$H8-pdemo/${pk##*/pair/}" "$PD/$pk" 2>/dev/null || grep -q "^scratch: /tmp/pair-$H8-pdemo/[0-9]\{3\}$" "$PD/$pk"; } && grep -q 'export TMPDIR=' "$PD/$pk" \
  && ok "packet: scratch is /tmp/pair-<repo hash>-<slug>/<seq>, with the TMPDIR export" || no "scratch line wrong: $(grep '^scratch' "$PD/$pk")"
rc=$(tp -- send "$pk"); ck 0 "$rc" "packet card → send round-trips (card digest echoed as base)"
d0="$(pdig)"; pcedit -e 's/^- \[~\] S2 /- [o] S2 /' -e 's/^- \[ \] S3 \(.*\)$/- [x] S3 \1 ✓ smoke@0123abce/'; d1="$(pdig)"; pcedit 's/^Goal: g$/Goal: g2/'; d2="$(pdig)"; pcard codex
[ "$d0" = "$d1" ] && ok "digest: status marks and ✓ tokens do not change it" || no "digest moved on marks: $d0 / $d1"
[ "$d0" != "$d2" ] && ok "digest: a content edit changes it" || no "digest blind to content"
n0=$(nfiles); rc=$(tp FAKE_EVIDENCE_LINT=1 -- packet card)
{ [ "$rc" = 3 ] && grep -q 'card lint fails' "$FK/err" && [ "$(nfiles)" = "$n0" ]; } && ok "packet card: a card lint failure refuses (3), no file left" || no "lint failure not refused (rc=$rc)"
rc=$(tp -- packet card --since x); ck 2 "$rc" "packet card takes no options"

echo "=== L1-39 · X1: the judge reads all of CLAUDE.md, never a different AGENTS.md (v4)"
printf '# other brief\n' > "$PD/AGENTS.md"
rc=$(tp -- ensure); ck 3 "$rc" "an AGENTS.md that differs from CLAUDE.md: ensure refuses"
grep -q 'AGENTS.md differs from CLAUDE.md' "$FK/err" && ok "...and names the X1 fix" || no "X1 message: $(cat "$FK/err")"
rm -f "$PD/AGENTS.md"; ln -s CLAUDE.md "$PD/AGENTS.md"
rc=$(tp -- ensure); ck 0 "$rc" "an AGENTS.md symlinked to CLAUDE.md is accepted"
rm -f "$PD/AGENTS.md"; mv "$PD/CLAUDE.md" "$FK/claude.saved"
rc=$(tp -- ensure); mv "$FK/claude.saved" "$PD/CLAUDE.md"; ck 3 "$rc" "no CLAUDE.md: ensure refuses"
{ cat "$PD/CLAUDE.md"; yes 'filler that grows CLAUDE.md past the 32 KiB doc cap' | head -c $((40000 - $(wc -c < "$PD/CLAUDE.md"))); } > "$FK/claude.big"
cp "$FK/claude.big" "$PD/CLAUDE.md"
rc=$(tp -- ensure); { [ "$rc" = 3 ] && grep -q 'close pane' "$FK/err"; } && ok "a judge started for a smaller CLAUDE.md is refused once it grows (close its pane)" || no "grown CLAUDE.md accepted by the old judge (rc=$rc)"
rm -f "$FK/state/agent" "$EVD/judge"; : > "$FK/herdr.log"
rc=$(tp -- ensure); { [ "$rc" = 0 ] && grep '^agent start' "$FK/herdr.log" | grep -q -- '-c project_doc_max_bytes=40960' && grep -qx 'doc_max_bytes=40960' "$EVD/judge"; } \
  && ok "a 40,000 B CLAUDE.md starts the judge with project_doc_max_bytes=40960" || no "doc cap for a big CLAUDE.md (rc=$rc): $(grep '^agent start' "$FK/herdr.log")"
git -C "$PD" checkout -q CLAUDE.md; rm -f "$FK/state/agent" "$EVD/judge"; tp -- ensure >/dev/null

echo "=== L1-40 · the six-line result contract (v4)"
vr() { local pk; pk=$(mkpkt "$1" slice S2 "$HD"); tp FAKE_HERDR_PROMPT="$2" -- send "$pk"; }   # $1 seq, $2 fake variant -> rc
rc=$(vr 101 run_failed); ck 6 "$rc" "run: failed is no result (6), never exit 0"
grep -q "	101	end:failed	.*	judge_run_failed$" "$RL" && ok "runlog: judge_run_failed" || no "judge_run_failed row missing: $(grep '	101	end' "$RL")"
rc=$(vr 102 run_blocked); ck 6 "$rc" "run: blocked is no result (6)"
rc=$(vr 103 pass_major); { [ "$rc" = 0 ] && grep -q 'state=completed (verdict=pass blocker=0 major=1 minor=0)' "$FK/out"; } && ok "a pass carrying a major completes; the summary shows major=1" || no "pass_major (rc=$rc): $(cat "$FK/out")"
rc=$(vr 104 fail_major); { [ "$rc" = 0 ] && grep -q 'verdict=fail blocker=0 major=1 minor=2' "$FK/out"; } && ok "a fail verdict completes (the verdict is in the result, not the exit code)" || no "fail_major (rc=$rc)"
rc=$(vr 105 bad_counts); { [ "$rc" = 6 ] && grep -q "	105	end:failed	.*	bad_header:major$" "$RL"; } && ok "a non-integer count is bad_header:major" || no "bad_counts (rc=$rc)"
rc=$(vr 106 v3_header); { [ "$rc" = 6 ] && grep -q "	106	end:failed	.*	bad_header:blocker$" "$RL"; } && ok "a v3 header (findings:, assumptions:) is bad_header:blocker" || no "v3_header (rc=$rc)"
rc=$(vr 107 dup_key); ck 6 "$rc" "a key twice in the first six lines is a bad header"
rc=$(vr 108 reordered); ck 0 "$rc" "the six keys in another order are accepted"
rc=$(vr 109 crlf); ck 0 "$rc" "CRLF line ends are accepted"
rc=$(vr 110 blank_line); ck 6 "$rc" "a blank line among the first six is a bad header"
miss=""; for w in 101:judge_run_failed 102:judge_run_blocked 105:bad_header:major 106:bad_header:blocker 107:bad_header:major 110:bad_header:minor; do
  s="${w%%:*}"; [ "$(recs "$s")" = 1 ] && grep -q "^codex [^ ]*/$s-slice\.md [^ ]* failed ${w#*:} model=" "$FK/evidence.log" || miss="$miss $s"
done
[ -z "$miss" ] && ok "every no-verdict run is recorded as failed with its reason" || no "no-verdict records missing or wrong for:$miss"

echo "=== L1-41 · judge scratch stays out of the mailbox (v4)"
rc=$(vr 121 scratch_in_mailbox); ck 6 "$rc" "a judge that wrote scratch into pair/ voids its run (scratch_in_mailbox)"
{ grep -q "	121	end:failed	.*	scratch_in_mailbox$" "$RL" && grep -q 'tmp-scratch/f' "$FK/err"; } && ok "runlog reason scratch_in_mailbox; stderr lists the stray path" || no "scratch_in_mailbox report: $(cat "$FK/err")"
[ -d "/tmp/pair-$H8-pdemo/121" ] && ok "a failed run keeps its scratch dir for inspection" || no "failed run's scratch removed"
rm -rf "$PKD/tmp-scratch"
rc=$(vr 122 scratch_ignored); { [ "$rc" = 6 ] && grep -q "	122	end:failed	.*	scratch_in_mailbox$" "$RL"; } && ok "a gitignored file in pair/ (invisible to the fingerprint) still voids the run" || no "scratch_ignored (rc=$rc)"
rm -rf "$PKD/.pytest_cache"
rc=$(vr 123 scratch_tmp); ck 0 "$rc" "scratch under the packet's scratch dir is fine"
fpr() { tp -- fingerprint >/dev/null; cat "$FK/out"; }
f0="$(fpr)"; printf '%s\t900\tstart\tslice\tS2\t-\t-\t-\t-\t-\tx\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RL"; pdl RUN S2 000000000000 pass
mkdir -p "$PD/.claude/evidence"; echo '{}' > "$PD/.claude/evidence/r.json"; f1="$(fpr)"
echo x > "$PKD/x.txt"; f2="$(fpr)"; rm -f "$PKD/x.txt"; sed '$d' "$RL" > "$FK/rl.tmp"; mv "$FK/rl.tmp" "$RL"
{ [ -n "$f0" ] && [ "$f0" = "$f1" ] && [ "$f1" != "$f2" ]; } && ok "fingerprint: a new pair/ file counts; runlog, donelog and .claude/evidence/ writes do not" || no "fingerprint exclusions wrong ($f0 / $f1 / $f2)"

echo "=== L1-42 · one run per task: the pair lock (v4, D3)"
LK="$PD/.claude/evidence/locks"; pre=$(prompts); pk2=$(mkpkt 132 slice S2 "$HD")   # written before: a new file in pair/ would void 131
pk=$(mkpkt 131 slice S2 "$HD"); TPSFX=.bg tp FAKE_HERDR_SLEEP=3 -- send "$pk" > "$FK/rc.bg" & bgp=$!
for _ in $(seq 1 60); do [ -s "$LK/pair-131.lock" ] && [ "$(prompts)" -gt "$pre" ] && break; sleep 0.1; done
IFS=$'\t' read -r lp lt ls lu lts < "$LK/pair-131.lock" 2>/dev/null
{ [ "$(awk -F'\t' '{print NF}' "$LK/pair-131.lock" 2>/dev/null)" = 5 ] && [ "$lt $ls $lu" = "pair slice S2" ] && printf '%s' "$lts" | grep -Eq "$TS_RE" && kill -0 "$lp" 2>/dev/null; } \
  && ok "in flight: pair-<seq>.lock = pid, pair, stage, unit, UTC ts; the pid is alive" || no "lock while in flight: $(cat "$LK/pair-131.lock" 2>/dev/null)"
p0=$(prompts); rc=$(tp -- send "$pk2"); ck 5 "$rc" "a second send while one is in flight exits 5"
n0=$(nfiles); rc=$(tp -- check card); { [ "$rc" = 5 ] && [ "$(nfiles)" = "$n0" ]; } && ok "check while a run is in flight exits 5 before writing a packet (one would void the run)" || no "check during a run (rc=$rc, files $n0 -> $(nfiles))"
[ "$(prompts)" -eq "$p0" ] && ok "...and typed nothing into the judge" || no "the second send prompted the judge"
wait "$bgp"; { [ "$(cat "$FK/rc.bg")" = 0 ] && [ ! -e "$LK/pair-131.lock" ]; } && ok "the background send completes and removes its lock" || no "background send (rc=$(cat "$FK/rc.bg")) or lock left"
dp="$(bash -c 'echo $$')"; printf '%s\tpair\tslice\tS2\t2026-01-01T00:00:00Z\n' "$dp" > "$LK/pair-090.lock"
pk=$(mkpkt 133 slice S2 "$HD"); rc=$(tp -- send "$pk")
{ [ "$rc" = 0 ] && [ ! -e "$LK/pair-090.lock" ] && grep -q 'stale lock pair-090.lock' "$FK/err"; } && ok "a dead pid's lock is removed (stale lock), the send runs" || no "stale lock handling (rc=$rc): $(cat "$FK/err")"
pk=$(mkpkt 134 slice S2 "$HD"); rc=$(tp FAKE_HERDR_PROMPT=blocked -- send "$pk")
{ [ "$rc" = 4 ] && ! ls "$LK"/pair-*.lock >/dev/null 2>&1; } && ok "a run parked blocked (4) releases its lock too" || no "lock after a blocked run (rc=$rc)"
rc=$(tp -- wait 134); ck 0 "$rc" "...and wait 134 settles it once the human answered"

echo "=== L1-43 · Codex quota: what the human consented to (v4, U1)"
mv "$RL" "$FK/runlog.saved"; mv "$PD/.claude/evidence/codex.jsonl" "$FK/codex.saved"; pcard codex; papprove; n0="$(grep -c '^codex ' "$FK/evidence.log")"
# A prompt that never became a turn (live attempt 1, 2026-10-28: typed into
# the /new picker): idle at once, no result, counters still 0/0, no transcript.
rc=$(tpn TASK_PAIR_START_GRACE_S=1 FAKE_HERDR_PROMPT=not_started -- check card); ck 6 "$rc" "a packet that never reached the model exits 6"
grep -q "	end:failed	card	card	.*	not_started$" "$RL" && ok "runlog: not_started" || no "not_started row missing: $(cat "$RL")"
{ [ "$(grep -c '^codex ' "$FK/evidence.log")" = "$n0" ] && grep -q 'record=none' "$FK/out" && grep -q 'not counted against the quota' "$FK/err"; } \
  && ok "not_started is not recorded (not a Codex run, no step toward no-verdict-twice) and says so" || no "not_started recorded or silent: $(cat "$FK/err")"
p0=$(prompts)
r1=$(tpn -- check card); r2=$(tpn -- check card); r3=$(tpn -- check card)
{ [ "$r1 $r2 $r3" = "0 0 3" ] && [ "$(prompts)" -eq $((p0 + 2)) ]; } && ok "card: two runs are consented (the not_started one is not counted), the third is refused before any prompt" || no "card quota: $r1 $r2 $r3, prompts +$(( $(prompts) - p0 ))"
grep -q 'beyond the consented estimate' "$FK/err" && ok "...naming the consented estimate and --over-estimate" || no "quota message: $(cat "$FK/err")"
rc=$(tpn -- check card --over-estimate)
{ [ "$rc" = 0 ] && awk -F'\t' '$3 == "start"' "$RL" | tail -n 1 | cut -f11 | grep -q 'over-estimate'; } && ok "--over-estimate runs it and marks the runlog start row" || no "over-estimate (rc=$rc): $(tail -n 2 "$RL")"
pdl APPROVE - 000000000000 codex_est=3; rc=$(tpn -- check slice S2); papprove
{ [ "$rc" = 3 ] && grep -q 'not approved' "$FK/err"; } && ok "a slice run before the card is approved at its current digest is refused" || no "unapproved slice run (rc=$rc)"
rc=$(tpn -- check slice S3); { [ "$rc" = 3 ] && grep -q 'not tagged codex: yes' "$FK/err"; } && ok "a slice without codex: yes is outside the consent" || no "untagged slice run (rc=$rc)"
pcedit -e 's/^- \[[ ~]\] \(S[23] .*\)$/- [x] \1/'
r1=$(tpn -- check final); r2=$(tpn -- check final); r3=$(tpn -- check final); r4=$(tpn -- check final)
[ "$r1 $r2 $r3 $r4" = "0 0 0 3" ] && ok "final: three runs (one, a retry, the rebuttal), the fourth refused" || no "final quota: $r1 $r2 $r3 $r4"
pcard codex; rm -f "$RL"; mv "$FK/runlog.saved" "$RL"; mv "$FK/codex.saved" "$PD/.claude/evidence/codex.jsonl"

echo "=== L1-44 · task-pair.sh → the real evidence.sh: records, binding, digest parity (v4)"
cp "$PD/scripts/evidence.sh" "$FK/evidence-stub.sh"; cp "$EV" "$PD/scripts/evidence.sh"; pcard codex; plane on; papprove
lrec() { python3 -I -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(*[r.get(k) for k in sys.argv[2:]])' "$PD/.claude/evidence/codex.jsonl" "$@" 2>/dev/null; }
rc=$(tp HOME="$WORK" -- check card)
{ [ "$rc" = 0 ] && [ "$(lrec lane unit tree)" = "codex-card card $(pdig)" ]; } && ok "check card: evidence.sh records lane codex-card, unit card, tree = task-pair.sh digest" || no "codex-card record (rc=$rc): $(lrec lane unit tree) $(head -c 300 "$FK/err")"
[ "$(lrec run_state verdict critical high prov)" = "completed pass 0 0 ok" ] && ok "a clean pass is recorded as approving (completed, pass, 0 critical, 0 high, prov ok: the judge's own apply_patch write)" || no "approving record: $(lrec run_state verdict critical high prov reason)"
{ lrec rollout | grep -q '^~/l123-fake/codex-home/sessions/' && ! tail -n 1 "$PD/.claude/evidence/codex.jsonl" | grep -qF "$WORK/" && ! tail -n 3 "$RL" | grep -qF "$WORK/"; } \
  && ok "the record and the run's runlog rows hold the rollout as ~/…, never the home path" || no "home path in record/runlog: $(lrec rollout) / $(tail -n 3 "$RL" | cut -f10)"
rc=$(tp FAKE_HERDR_PROMPT=no_result -- check card); [ "$(lrec run_state verdict)" = "failed none" ] && ok "no_result is recorded failed with no verdict" || no "no_result record (rc=$rc): $(lrec run_state verdict)"
rc=$(tp FAKE_HERDR_PROMPT=pass_major -- check card); [ "$(lrec run_state verdict high)" = "completed pass 1" ] && ok "a pass carrying a major is recorded high=1 — not approving" || no "pass_major record (rc=$rc): $(lrec run_state verdict high)"
# Digest parity (02 review #1/#11): task-pair.sh card_digest must equal evidence.sh card_norm
# on cards built to trip the normalisation; evidence.sh's digest is a codex-card record's tree.
sed -e 's/^- \[[x~]\] /- [ ] /' -e 's/ ✓ .*$//' "$CD/card.md" > "$FK/v1"                                  # bare: [ ] marks, no suffix
cp "$CD/card.md" "$FK/v0"                                                                                 # [x] + token, [~]
sed -e 's/^- \[ \] S3 \(.*\)$/- [o] S3 \1 ✓ smoke@0123abce check@0123abcf codex@waived/' -e 's/^- \[ \] S2 /- [~] S2 /' "$FK/v1" > "$FK/v2"
{ cat "$FK/v0"; echo 'Closed: tree:0123456789ab head:0123456789ab ✓ smoke@0123abcd check@0123abce — 2026-10-28T00:00:00Z'; } > "$FK/v3"   # close's line, last
sed 's/^\(- \[x\] S1 .*smoke@0123abcd\)$/\1 extra words/' "$FK/v0" > "$FK/v4"                             # non-token text after ✓
sed 's/smoke@0123abcd$/smoke@0123abc/' "$FK/v0" > "$FK/v5"                                                 # 7-hex token
{ cat "$FK/v3"; echo '- a line after Closed:'; } > "$FK/v6"                                               # Closed: not last
{ cat "$FK/v0"; echo 'Closed: tree:000000000000 done'; } > "$FK/v7"                                       # malformed Closed:
sed 's/^Goal: g$/Goal: g ✓ smoke@0123abcd/' "$FK/v1" > "$FK/v8"                                           # ✓ on a non-slice line
DG=(); dm=""
for v in 0 1 2 3 4 5 6 7 8; do
  cp "$FK/v$v" "$CD/card.md"; DG[v]="$(pdig)"; k=".ai_context/tasks/pdemo/pair/90$v-card.md"
  printf 'stage: card\nunit: card\nbase: %s\n' "${DG[v]}" > "$PD/$k"
  ( cd "$PD" && bash scripts/evidence.sh codex "$k" "${k%.md}.result.md" failed no_result >/dev/null 2>&1 )
  [ "$(lrec tree)" = "${DG[v]}" ] || dm="$dm v$v"
done
[ -z "$dm" ] && ok "digest parity: task-pair.sh digest = evidence.sh's on 9 tricky cards (marks, tokens, Closed: last or not)" || no "digest drift between task-pair.sh and evidence.sh on:$dm"
{ [ "${DG[0]}" = "${DG[1]}" ] && [ "${DG[2]}" = "${DG[1]}" ] && [ "${DG[3]}" = "${DG[1]}" ] && for v in 4 5 6 7 8; do [ "${DG[v]}" != "${DG[1]}" ] || exit 1; done; } 2>/dev/null \
  && ok "digest: marks, token suffixes and close's last Closed: line are status; other ✓ text, a 7-hex token and a stray Closed: are content" || no "normalisation: $(for v in 0 1 2 3 4 5 6 7 8; do printf 'v%s=%s ' "$v" "${DG[v]:5:8}"; done)"
pcard codex; rm -rf "/tmp/pair-$H8-pdemo"

echo "=== L1-47 · pair review regressions (independent review of task-pair.sh at d033182)"
# One assertion group per finding; the finding id leads each message. The real
# evidence.sh where the record decides (C1, M6), the committed stub elsewhere.
usereal() { cp "$EV" "$PD/scripts/evidence.sh"; }; usestub() { cp "$FK/evidence-stub.sh" "$PD/scripts/evidence.sh"; }
goal() { pcedit "s/^Goal: .*/Goal: $1/"; }   # new card content: a card check binds to the digest
lastseq() { awk -F'\t' '$3 == "start" {s = $2} END {print s}' "$RL"; }
dlr() { awk -F'\t' '$2 == "CODEX" {r = $7} END {print r}' "$CD/donelog"; }   # the last CODEX donelog row's result
usestub; pcard codex; papprove; echo idle > "$FK/state/agent"; rm -f "$FK/state/screen" "$FK/state/run-screen"; : > "$FK/herdr.log"

# C1 — a FAIL turned into an approving record: (a) no write path, (b) no state in pair/, (c) provenance
D47="$WORK/l147g"; mkproj "$D47"; mkcard "$D47" demo codex '- [~] S1 first — lanes: smoke ; codex: yes'
grep -qF '"Edit(./.ai_context/tasks/**/pair/**)"' "$REPO/.claude/settings.json" && ok "C1 settings.json denies Edit/Write into a pair mailbox" || no "C1 pair/ Edit deny missing"
miss=""
for c in 'sed -i s/fail/pass/ .ai_context/tasks/demo/pair/001-card.result.md' 'printf x > .ai_context/tasks/demo/pair/001-card.result.md' \
         'cp /tmp/r.md .ai_context/tasks/demo/pair/001-card.result.md' 'rm -f .ai_context/tasks/demo/pair/runlog' \
         'cd .ai_context/tasks/demo/pair && sed -i s/a/b/ 001-card.result.md' 'echo x >> ~/.codex/sessions/2026/10/28/rollout-x.jsonl' \
         'tee \"$CODEX_HOME/sessions/x.jsonl\" < /dev/null'; do   # bgp writes the command into JSON as is
  ask_is "$D47" "$c" || miss="$miss [$c]"
done
[ -z "$miss" ] && ok "C1 bash-guard asks on Bash writes into pair/ and into Codex's session transcripts" || no "C1 not asked:$miss"
miss=""
for c in 'bash scripts/task-pair.sh wait 001' 'bash scripts/task-pair.sh check final --rebuttal .ai_context/tasks/demo/rebuttal.md' \
         'cat .ai_context/tasks/demo/pair/001-card.result.md' 'cp .ai_context/tasks/demo/pair/001-card.result.md /tmp/r.md' 'grep -c major .ai_context/tasks/demo/pair/001-card.md'; do
  silent "$D47" "$c" || miss="$miss [$c]"
done
[ -z "$miss" ] && ok "C1 ...task-pair.sh itself and reads stay silent" || no "C1 asked on:$miss"
{ [ -f "$EVD/judge" ] && [ ! -e "$PKD/judge" ] && ! compgen -G "$PKD/.fp-*" >/dev/null && git -C "$PD" check-ignore -q "$EVD/judge" && [ -s "$EVD/not_started" ]; } \
  && ok "C1 run state (judge record, fp-<seq>, not_started) lives in gitignored .claude/evidence/pair/<slug>/, none in pair/" || no "C1 state files: $(ls -a "$PKD" | tr '\n' ' ')"
usereal; goal c1
rc=$(tp FAKE_HERDR_PROMPT=timeout_done FAKE_HERDR_RESULT=fail_major -- check card); s=$(lastseq); r="$PKD/$s-card.result.md"
sed -e 's/^verdict: fail/verdict: pass/' -e 's/^major: 1/major: 0/' -e '/^1\. major /d' "$r" > "$FK/forged"; cat "$FK/forged" > "$r"
rc2=$(tp -- wait "$s")
{ [ "$rc" = 5 ] && [ "$rc2" = 0 ] && [ "$(lrec verdict high prov)" = "pass 0 mismatch" ] && [ "$(dlr)" = unbound ] && grep -q 'provenance mismatch' "$FK/err"; } \
  && ok "C1 a result edited after the judge wrote it (fail → pass) is recorded prov=mismatch and approves nothing" || no "C1 forged result (rc=$rc/$rc2): $(lrec verdict high prov) $(dlr) $(cat "$FK/err")"
goal c1b; rc=$(tp FAKE_HERDR_PROV=shell -- check card)
{ [ "$rc" = 0 ] && [ "$(lrec run_state verdict high prov)" = "completed pass 0 unbound" ] && [ "$(dlr)" = unbound ]; } \
  && ok "C1 a result its transcript shows written by a shell command, not apply_patch, approves nothing (prov=unbound)" || no "C1 shell-written result (rc=$rc): $(lrec run_state verdict high prov) $(dlr)"
usestub
P47="$WORK/l147p"; mkproj "$P47"; mklanes "$P47" '@pair codex' "$LANE_SMOKE"; ev "$P47" trust smoke >/dev/null
mkcard "$P47" demo codex '- [~] S1 first — lanes: smoke ; codex: yes'
LF="$REPO/tests/fixtures/codex-0.165.0"; LR=.ai_context/tasks/livecard/pair/001-card.result.md; mkdir -p "$P47/${LR%/*}"
sed "s#/work/livecard#$P47#g" "$LF/rollout-card.jsonl" > "$WORK/live.jsonl"; cp "$LF/rollout-card.result.md" "$P47/$LR"
lk="$P47/.ai_context/tasks/demo/pair/001-card.md"; mkdir -p "${lk%/*}"; printf 'stage: card\nunit: card\nbase: %s\n\n# Task\n' "$(sed -n 's/^base: //p' "$LF/rollout-card.result.md")" > "$lk"
lpv() { # $1 = PAIR_SINCE -> the prov evidence.sh codex records for the live transcript and the result on disk
  ( cd "$P47" && PAIR_ROLLOUT="$WORK/live.jsonl" PAIR_SINCE="$1" PAIR_RESULT_PATH="$LR" bash scripts/evidence.sh codex "$lk" "$LR" completed ok >/dev/null 2>"$WORK/lpv.err" )
  python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["prov"])' "$P47/.claude/evidence/codex.jsonl"
}
v1="$(lpv 2026-10-28T18:27:30.000Z)"; v3="$(lpv 2026-10-28T18:30:00.000Z)"
sed -i.bak 's/^verdict: fail/verdict: pass/' "$P47/$LR"; v2="$(lpv 2026-10-28T18:27:30.000Z)"
{ [ "$v1" = ok ] && [ "$v2" = mismatch ] && [ "$v3" = unbound ]; } \
  && ok "C1 on the live 0.165.0 transcript: the judge's apply_patch write binds (ok); an edited verdict is mismatch; a write before the run began is unbound" || no "C1 live transcript prov: $v1 / $v2 / $v3 ($(cat "$WORK/lpv.err"))"

# R10 (evidence.sh) — a checker pass needs its first claim seen running
ev "$P47" approve >/dev/null; ev "$P47" start S1 >/dev/null
rep S1 pass 'INCONCLUSIVE (L3) a — b' 'VERIFIED (L4) c — d' | ev "$P47" check S1 --agent r10 --source human >/dev/null
{ grep -q '^check S1 fail ' "$WORK/ev.out" && grep -qF 'R10: the first claim must be VERIFIED at L4 or L5' "$WORK/ev.err" \
  && [ "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["reason"])' "$P47/.claude/evidence/checker.jsonl")" = 'R10: the first claim must be VERIFIED at L4 or L5' ]; } \
  && ok "R10 a checker pass whose first claim is not VERIFIED at L4/L5 is recorded fail, with the reason" || no "R10: $(cat "$WORK/ev.out" "$WORK/ev.err")"
rep S1 pass 'VERIFIED (L2) a — b' | ev "$P47" check S1 --agent r10 --source human >/dev/null; a1="$(cat "$WORK/ev.out")"
rep S1 pass 'VERIFIED (L5) a — b' 'INCONCLUSIVE (L2) c — d' | ev "$P47" check S1 --agent r10 --source human >/dev/null; a2="$(cat "$WORK/ev.out")"
rep card pass 'VERIFIED (L2) a — b' | ev "$P47" check card --agent r10 --source human >/dev/null; a3="$(cat "$WORK/ev.out")"
{ grep -q '^check S1 fail ' <<<"$a1" && grep -q '^check S1 pass ' <<<"$a2" && grep -q '^check card pass ' <<<"$a3"; } \
  && ok "R10 ...VERIFIED (L2) first fails, VERIFIED (L5) first passes; a card-mode check needs no L4" || no "R10 levels: $a1 / $a2 / $a3"

# H1 — herdr's "never started" signals are no Codex run; a late start is re-attached
goal h1; : > "$FK/herdr.log"
rc=$(tp FAKE_HERDR_PROMPT=refused_blocked -- check card); s=$(lastseq)
{ [ "$rc" = 4 ] && [ "$(recs "$s")" = 0 ] && [ ! -e "$EVD/fp-$s" ] && grep -q "	$s	card	card	herdr_blocked$" "$EVD/not_started"; } \
  && ok "H1 herdr refusing the prompt (agent_blocked: nothing typed) exits 4 — no record, nothing in flight, the attempt in the not_started ledger" || no "H1 agent_blocked (rc=$rc): $(cat "$FK/err")"
rc=$(tp FAKE_HERDR_PROMPT=stalled -- check card); s=$(lastseq)
{ [ "$rc" = 6 ] && [ "$(recs "$s")" = 0 ] && grep -q "	$s	end:failed	.*	not_started$" "$RL"; } \
  && ok "H1 agent_prompt_stalled with no turn is not_started — no record, no quota, no no-verdict count" || no "H1 stall (rc=$rc): $(grep "	$s	" "$RL")"
rc=$(tp FAKE_HERDR_PROMPT=stalled_late -- check card); s=$(lastseq)
{ [ "$rc" = 0 ] && [ "$(recs "$s")" = 1 ] && grep -q "	$s	end:completed	" "$RL" && grep -q '^agent wait' "$FK/herdr.log"; } \
  && ok "H1 a stall whose turn starts late is re-attached (agent wait) and completes — one record" || no "H1 late start (rc=$rc): $(grep "	$s	" "$RL")"

# H2 — blocked mid-turn is not settled; the exit-5 message never says `seq ?`
goal h2; rc=$(tp FAKE_HERDR_PROMPT=blocked -- check card); s=$(lastseq); n1=$(nfiles); rc2=$(tp -- check card)
{ [ "$rc" = 4 ] && [ "$rc2" = 4 ] && [ "$(nfiles)" = "$n1" ] && [ "$(recs "$s")" = 0 ] && grep -q "task-pair.sh wait $s" "$FK/err"; } \
  && ok "H2 blocked mid-run settles nothing: no record, and the next check is refused (4) before a packet, naming wait <seq>" || no "H2 blocked (rc=$rc/$rc2): $(cat "$FK/err")"
rc=$(tp -- wait "$s"); { [ "$rc" = 0 ] && [ "$(recs "$s")" = 1 ]; } && ok "H2 ...wait <seq> re-attaches once answered: one record, of the finished turn" || no "H2 wait (rc=$rc)"
printf '%s\t950\tstart\tcard\tcard\t-\t-\t-\t-\t-\tx\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RL"; echo working > "$FK/state/agent"
pk=$(mkpkt 951 card card "$(pdig)"); rc=$(tp -- send "$pk"); echo idle > "$FK/state/agent"; rm -f "$pk"; sed '$d' "$RL" > "$FK/rl.tmp"; mv "$FK/rl.tmp" "$RL"
{ [ "$rc" = 5 ] && grep -q 'the last one started: seq 950' "$FK/err" && ! grep -q 'seq ?' "$FK/err" "$FK/out"; } \
  && ok "H2 a working judge with no run of ours in flight: exit 5 names the last started seq (runlog), never 'seq ?'" || no "H2 exit 5 (rc=$rc): $(cat "$FK/err")"

# H3 — dialogs only at the bottom of the screen, keys only to an idle judge
goal h3; : > "$FK/herdr.log"
{ printf '  >_ OpenAI Codex (v0.165.0)\n\n• Ran sed -n 1,40p scripts/task-pair.sh\n    Trust this folder? Codex can read, edit, and run files\n'
  printf '    Update available · esc skip\n    Approaching rate limits · Switch to gpt-5.6-luna\n    enter continue · esc quit\n'
  printf '• Those dialog texts are quoted, not shown.\n\n› Ask Codex to do anything\n\n  GPT-5.6-Sol high · /fixture · 1.2k in · 340 out\n  ? for shortcuts\n'; } > "$FK/h3.cur"
rc=$(tp FAKE_HERDR_SCREEN="$FK/h3.cur" FAKE_HERDR_NEW_CLEARS=1 -- check card)
{ [ "$rc" = 0 ] && ! grep -q '^agent send-keys' "$FK/herdr.log"; } \
  && ok "H3 dialog texts in the transcript above an empty composer are no dialog: no key, the run completes" || no "H3 transcript (rc=$rc): $(grep '^agent send-keys' "$FK/herdr.log" | tr '\n' '|') $(cat "$FK/err")"
printf '  Update available · 0.162.1 → 0.165.0\n\n› 1. Update now\n  2. Skip\n\n  enter continue · esc skip\n' > "$FK/h3.cur"; echo working > "$FK/state/agent"; : > "$FK/herdr.log"
pk=$(mkpkt 952 card card "$(pdig)"); rc=$(tp FAKE_HERDR_SCREEN="$FK/h3.cur" FAKE_HERDR_ESC_CLEARS=1 -- send "$pk"); echo idle > "$FK/state/agent"; rm -f "$pk" "$FK/h3.cur"
{ [ "$rc" = 5 ] && ! grep -q '^agent send-keys' "$FK/herdr.log"; } && ok "H3 a dialog over a working judge gets no key (esc there interrupts it): exit 5" || no "H3 working (rc=$rc): $(grep '^agent send-keys' "$FK/herdr.log")"

# M1 — a slow /new: the packet waits until the fresh thread shows
goal m1; echo 5 > "$FK/state/turns"
rc=$(tp FAKE_HERDR_NEW_DELAY=2 TASK_PAIR_NEW_WAIT_S=8 -- check card); s=$(lastseq)
{ [ "$rc" = 0 ] && grep -q "	$s	end:completed	" "$RL" && grep -q "	$s	start	.*	0/0	" "$RL"; } \
  && ok "M1 a /new that shows 2 s late: the packet waits for the fresh thread (start row at 0/0) and the run completes" || no "M1 slow /new (rc=$rc): $(grep "	$s	" "$RL")"

# M2 — a failed review is not asked again at the same content; the rebuttal is per final tree, not per HEAD
n0=$(nfiles); rc=$(tp FAKE_EVIDENCE_TREE=m2 FAKE_HERDR_PROMPT=fail_major -- check slice S2); n1=$(nfiles); rc2=$(tp FAKE_EVIDENCE_TREE=m2 -- check slice S2)
{ [ "$rc" = 0 ] && [ "$rc2" = 3 ] && [ "$(nfiles)" = "$n1" ] && grep -qF 'the latest completed S2 review at this content failed — change the content or ask the human to waive' "$FK/err"; } \
  && ok "M2 a failed slice review is not asked again at the same content: refused (3) before a packet" || no "M2 re-ask (rc=$rc/$rc2): $(cat "$FK/err")"
rc=$(tp FAKE_EVIDENCE_TREE=m2b -- check slice S2); ck 0 "$rc" "M2 ...new content (another tree) is reviewed"
pcedit -e 's/^- \[[ ~]\] \(S[23] .*\)$/- [x] \1/'
r1=$(tp FAKE_EVIDENCE_TREE=m2f -- check final); r2=$(tp FAKE_EVIDENCE_TREE=m2f -- check final --rebuttal "$FK/rebut.md")
echo 'memory only' >> "$CD/notes.md"; git -C "$PD" add -A .ai_context; git -C "$PD" commit -qm 'memory only'   # HEAD moves, the final tree does not
r3=$(tp FAKE_EVIDENCE_TREE=m2f -- check final --rebuttal "$FK/rebut.md")
{ [ "$r1 $r2 $r3" = "0 0 3" ] && grep -q 'one rebuttal round per content' "$FK/err"; } \
  && ok "M2 the rebuttal round is per final content, not per HEAD: a memory-only commit does not reopen it" || no "M2 rebuttal per content: $r1 $r2 $r3 $(cat "$FK/err")"

# M3 — a rebuttal that never reached the model does not spend the round
r1=$(tp FAKE_EVIDENCE_TREE=m3 FAKE_HERDR_PROMPT=fail_major -- check final)
r2=$(tp FAKE_EVIDENCE_TREE=m3 FAKE_HERDR_PROMPT=not_started -- check final --rebuttal "$FK/rebut.md")
r3=$(tp FAKE_EVIDENCE_TREE=m3 -- check final --rebuttal "$FK/rebut.md")
[ "$r1 $r2 $r3" = "0 6 0" ] && ok "M3 a not_started rebuttal leaves the round open; the next one runs" || no "M3 rebuttal round: $r1 $r2 $r3 $(cat "$FK/err")"
pcard codex; papprove

# M4 — the judge is this checkout's: name keyed by repo, cwd and pane checked
rc1=$(tp FAKE_HERDR_CWD=/elsewhere -- ensure); e1="$(cat "$FK/err")"; rc2=$(tp FAKE_HERDR_PANE=w9:p7 -- ensure); e2="$(cat "$FK/err")"
rc3=$(tp FAKE_HERDR_CWD="$(cd "$PD" && pwd -P)" -- ensure)
{ [ "$rc1" = 3 ] && grep -q 'not in this checkout' <<<"$e1" && [ "$rc2" = 3 ] && grep -q 'its record says w9:p9' <<<"$e2" && [ "$rc3" = 0 ]; } \
  && ok "M4 a judge herdr shows in another checkout or another pane than its record is refused (3); the physical path is the same checkout" || no "M4 identity: $rc1 $rc2 $rc3 $e1 $e2"
PB="$WORK/l123b"; git clone -q "$PD" "$PB"; printf '[projects."%s"]\ntrust_level = "trusted"\n' "$PB" >> "$FK/codex-home/config.toml"
H8B="$(printf '%s' "$PB" | sha256sum | cut -c1-8)"; : > "$FK/herdr.log"
rc=$( (cd "$PB" && env HERDR_ENV=1 PATH="$FK/bin:$PATH" CODEX_HOME="$FK/codex-home" FAKE_HERDR_LOG="$FK/herdr.log" FAKE_HERDR_STATE="$FK/state" bash scripts/task-pair.sh ensure) >/dev/null 2>&1; echo $?)
{ [ "$rc" = 0 ] && grep -q "^agent start judge-$H8B-pdemo " "$FK/herdr.log" && [ "$H8B" != "$H8" ] && [ "${#JN}" -le 32 ]; } \
  && ok "M4 a second checkout of the same task starts its own judge (judge-<repo hash>-<slug>), never drives the first one's" || no "M4 clone (rc=$rc): $(cut -c1-80 "$FK/herdr.log" | tr '\n' '|')"
printf '%s\n' "$JN" > "$FK/state/agent-name"; printf '%s\n' "$PD" > "$FK/state/agent-cwd"; rm -rf "/tmp/pair-$H8B-pdemo"

# M5 — secrets and home paths stay out of tracked pair/
goal m5; IP="10.$((19 + 1)).30.40"
rc=$(tp FAKE_HERDR_PROMPT=leaky -- check card); s=$(lastseq); r="$PKD/$s-card.result.md"; w="$PD/.claude/evidence/logs/pair-pdemo-$s-card.result.md"
{ [ "$rc" = 0 ] && grep -qF "$IP" "$w" && ! grep -qF "$IP" "$r" && grep -q 'withheld (secret scan hit: .*internal-ipv4' "$r" && [ "$(recs "$s")" = 1 ]; } \
  && ok "M5 a result the secret scan flags moves to .claude/evidence/logs/, a stub naming the rule stays in pair/; the run is still recorded" || no "M5 leaky result (rc=$rc): $(cat "$r" 2>/dev/null | head -n 3)"
printf '› Read and execute the packet\n• Ran bash t.sh\n  └ connecting to db at %s:5432\n\n› Ask Codex to do anything\n\n  GPT-5.6-Sol high · /fixture · 9 in · 9 out\n' "$IP" > "$FK/m5.run"
rc=$(tp FAKE_HERDR_PROMPT=no_result FAKE_HERDR_RUN_SCREEN="$FK/m5.run" -- check card); s=$(lastseq); d="$PKD/$s-card.screen.txt"
{ [ "$rc" = 6 ] && ! grep -qF "$IP" "$d" && grep -q 'withheld' "$d" && grep -qF "$IP" "$PD/.claude/evidence/logs/pair-pdemo-$s-card.screen.txt"; } \
  && ok "M5 a screen dump the secret scan flags is withheld the same way" || no "M5 leaky screen (rc=$rc): $(head -n 3 "$d" 2>/dev/null)"
printf '› Read and execute the packet at %s/\n    %s/l123/.ai_context/tasks/pdemo/pair/x.md; its paths\n\n› Ask Codex to do anything\n\n  GPT-5.6-Sol high · /fixture · 9 in · 9 out\n' "${WORK%/*}" "${WORK##*/}" > "$FK/m5.run"
rc=$(tp HOME="$WORK" FAKE_HERDR_PROMPT=no_result FAKE_HERDR_RUN_SCREEN="$FK/m5.run" -- check card); s=$(lastseq); d="$PKD/$s-card.screen.txt"
{ [ "$rc" = 6 ] && grep -q '[~]/l123/\.ai_context/tasks/pdemo/pair/x\.md' "$d" && ! tr -d '\n ' < "$d" | grep -qF "$WORK/"; } \
  && ok "M5 a home path Codex wrapped across lines is joined, then written ~/…" || no "M5 wrapped home path: $(cat "$d")"
! grep 'Read and execute' "$FK/herdr.log" | grep -qF "$PD/" && ok "M5 the prompt names repo-relative paths only" || no "M5 absolute repo path in the prompt"
rm -f "$FK/m5.run"

# M6 — counts must match the findings; the turn must have ended normally
goal m6; rc=$(tp FAKE_HERDR_PROMPT=counts_mismatch -- check card); s=$(lastseq)
{ [ "$rc" = 6 ] && grep -q "	$s	end:failed	.*	bad_header:counts$" "$RL"; } && ok "M6 header counts that differ from the finding lines are bad_header:counts (6)" || no "M6 counts (rc=$rc): $(grep "	$s	end" "$RL")"
usereal; rc=$(tp FAKE_HERDR_PROV=aborted -- check card); usestub
{ [ "$(lrec run_state verdict prov)" = "completed pass unbound" ] && [ "$(dlr)" = unbound ] && grep -q 'did not end normally' "$FK/err"; } \
  && ok "M6 a turn aborted after the judge wrote its result is recorded prov=unbound — it approves nothing" || no "M6 aborted turn (rc=$rc): $(lrec run_state verdict prov) $(dlr)"

# M7 — only a unit on the card runs; the quota counts records, not the runlog
p0=$(prompts); pk=$(mkpkt 960 slice S9 "$(git -C "$PD" rev-parse HEAD)"); rc=$(tp -- send "$pk"); e1="$(cat "$FK/err")"
printf 'stage: card\nunit: anything\nbase: %s\n' "$(pdig)" > "$PKD/961-card.md"; rc2=$(tp -- send "$PKD/961-card.md"); rm -f "$pk" "$PKD/961-card.md"
{ [ "$rc" = 3 ] && [ "$rc2" = 3 ] && grep -q 'names nothing on this card' <<<"$e1" && [ "$(prompts)" = "$p0" ]; } \
  && ok "M7 a hand-written packet for a unit not on the card (slice S9, card/anything) is refused (3) — no quota of its own" || no "M7 foreign unit ($rc/$rc2): $e1"
mv "$RL" "$FK/rl47.saved"; mv "$PD/.claude/evidence/codex.jsonl" "$FK/cx47.saved"; goal m7
r1=$(tpn -- check card); r2=$(tpn -- check card)
for s in $(awk -F'\t' '$3 == "start" {print $2}' "$RL"); do printf '%s\t%s\tend:failed\tcard\tcard\t-\t-\t?\t-\t?\tnot_started\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$s" >> "$RL"; done
r3=$(tpn -- check card)
{ [ "$r1 $r2 $r3" = "0 0 3" ] && grep -q 'beyond the consented estimate' "$FK/err"; } \
  && ok "M7 the quota counts the Codex records: not_started rows appended to the runlog by hand free no run" || no "M7 quota source: $r1 $r2 $r3"
rm -f "$RL"; mv "$FK/rl47.saved" "$RL"; mv "$FK/cx47.saved" "$PD/.claude/evidence/codex.jsonl"

# M8 — a failed record blocks nothing; wait retries it
goal m8; rc=$(tp FAKE_EVIDENCE_RC=1 -- check card); s=$(lastseq); rc2=$(tp -- check card); s2=$(lastseq); rc3=$(tp -- wait "$s")
{ [ "$rc" = 6 ] && [ "$rc2" = 0 ] && [ "$s2" != "$s" ] && [ "$rc3" = 0 ] && [ ! -e "$EVD/unrecorded-$s" ] && [ "$(recs "$s")" = 2 ]; } \
  && ok "M8 a run whose record failed blocks no new check; wait <seq> writes its record later" || no "M8 record_failed ($rc/$rc2/$rc3)"

# L1 — the transcript is looked up once, after the prompt
awk -F'\t' '$3 == "start" && $10 != "-"' "$RL" | grep -q . && no "L1 a start row carries a rollout lookup: $(awk -F'\t' '$3 == "start" && $10 != "-"' "$RL" | head -n 1)" \
  || ok "L1 start rows carry rollout '-': no scan of Codex transcripts before the packet is typed (end rows carry it)"

# L2 — AGENTS.override.md is read before CLAUDE.md too
printf '# other\n' > "$PD/AGENTS.override.md"; rc=$(tp -- ensure); e="$(cat "$FK/err")"
cp "$PD/CLAUDE.md" "$PD/AGENTS.override.md"; rc2=$(tp -- ensure); rm -f "$PD/AGENTS.override.md"
{ [ "$rc" = 3 ] && grep -q 'AGENTS.override.md differs from CLAUDE.md' <<<"$e" && [ "$rc2" = 0 ]; } \
  && ok "L2 an AGENTS.override.md that differs from CLAUDE.md is refused (Codex reads it first); a copy is fine" || no "L2 override ($rc/$rc2): $e"

# L3 — packets only into an empty composer
printf '  >_ OpenAI Codex (v0.165.0)\n\n› please also fix the README\n\n  GPT-5.6-Sol high · /fixture · 0 in · 0 out\n  ? for shortcuts\n' > "$FK/l3.cur"; : > "$FK/herdr.log"
pk=$(mkpkt 962 card card "$(pdig)"); rc=$(tp FAKE_HERDR_SCREEN="$FK/l3.cur" -- send "$pk"); rm -f "$pk" "$FK/l3.cur"
{ [ "$rc" = 4 ] && ! grep -q '^agent prompt' "$FK/herdr.log" && grep -q 'not at an empty prompt' "$FK/err"; } \
  && ok "L3 a draft in the composer is no empty prompt: nothing typed, not even /new (exit 4)" || no "L3 draft (rc=$rc): $(grep '^agent prompt' "$FK/herdr.log")"

# L4 — what close/done would refuse is not spent on Codex first
goal l4; n0=$(nfiles); rc=$(tp -- check final); e1="$(cat "$FK/err")"; rc2=$(tp FAKE_EVIDENCE_LANE=stale -- check slice S2); e2="$(cat "$FK/err")"
{ [ "$rc" = 3 ] && grep -qF 'not done yet: S2 [~] S3 [ ]' <<<"$e1" && [ "$rc2" = 3 ] && grep -q 'lane smoke is stale' <<<"$e2" && [ "$(nfiles)" = "$n0" ]; } \
  && ok "L4 check final with slices not [x], and check slice with a stale lane, are refused (3) before a packet" || no "L4 ($rc/$rc2): $e1 $e2"

# L5 — exit codes as pair.md states them
pk=$(mkpkt 963 card card "card:$(printf '%064d' 0)"); rc=$(tp -- send "$pk"); rm -f "$pk"
pk=$(mkpkt 964 card card "$(pdig)"); : > "$FK/herdr.log"; rc2=$(tp FAKE_HERDR_NEW_FAIL=1 -- send "$pk"); rm -f "$pk"
{ [ "$rc" = 3 ] && [ "$rc2" = 4 ] && grep -q 'sending /new to the judge failed' "$FK/err" && [ "$(prompts)" = 0 ]; } \
  && ok "L5 a stale packet exits 3; a refused /new exits 4 (the judge needs a look) and sends nothing" || no "L5 exit codes ($rc/$rc2): $(cat "$FK/err")"

# L6 — one blank read is a repaint, not a missing prompt
goal l6; rc=$(tp FAKE_HERDR_BLANK_EVERY=2 -- check card); ck 0 "$rc" "L6 every other screen read blank (repaints): three reads a second apart, the run completes"

# L7 — the record and the cleanup after it are one step
goal l7; rc=$(tp FAKE_EVIDENCE_KILL=TERM -- check card); s=$(lastseq)
{ [ "$rc" = 0 ] && [ "$(recs "$s")" = 1 ] && [ ! -e "$EVD/fp-$s" ] && [ ! -e "$EVD/settle-$s" ]; } \
  && ok "L7 a TERM while the record is written is held off: one record, the run cleaned up" || no "L7 TERM (rc=$rc, records $(recs "$s"))"
goal l7b; rc=$(tp FAKE_EVIDENCE_KILL=9 -- check card); s=$(lastseq); sleep 2; rc2=$(tp -- wait "$s")
{ [ "$rc" = 137 ] && [ "$rc2" = 0 ] && [ "$(recs "$s")" = 1 ] && [ ! -e "$EVD/fp-$s" ] && [ ! -e "$EVD/settle-$s" ]; } \
  && ok "L7 killed right after its record: wait <seq> settles it again without a second record" || no "L7 KILL (rc=$rc/$rc2, records $(recs "$s"))"
pcard codex; rm -rf "/tmp/pair-$H8-pdemo"

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
           .claude/hooks/spawn-log.sh .claude/gitleaks.toml \
           .claude/skills/wrap/SKILL.md .claude/skills/wrap/reference.md \
           .claude/skills/task/SKILL.md .claude/skills/task/pair.md \
           .claude/skills/task/reference.md .claude/skills/setup/SKILL.md \
           .claude/skills/setup/verify-template.md .claude/skills/number-check/SKILL.md \
           .claude/skills/prove/SKILL.md .claude/skills/debug/SKILL.md .claude/skills/backtest-check/SKILL.md \
           .claude/skills/defect/SKILL.md \
           .claude/agents/executor.md .claude/agents/checker.md \
           .claude/.starter-version .ai_context/INDEX.md .ai_context/tasks/.gitkeep \
           .secrets/.gitkeep NOTICE \
           scripts/harness-report.sh scripts/check-append-only.sh scripts/check-context-bulk.sh \
           scripts/evidence.sh scripts/task-pair.sh \
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
  printf '# lab\n## Commands\n- Test: `true`\n' > "$P/CLAUDE.md"
  git -C "$P" checkout -qb task/demo 2>/dev/null || true
  printf '# Demo task\n<!-- card v4 ; pair: off ; base: - ; estimate: 1h 50L -->\nGoal: hook chain\n## Slices\n- [~] S1 first — lanes: smoke ; codex: no\n' > "$P/.ai_context/tasks/demo/card.md"
  printf '{"session_id": "tsuite-l2"}' | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 0 $? "project gate: a slice in progress passes"
  sed -i 's/^- \[~\] S1 /- [x] S1 /' "$P/.ai_context/tasks/demo/card.md"
  printf '{"session_id": "tsuite-l2"}' | CLAUDE_PROJECT_DIR="$P" bash "$P/.claude/hooks/stop-gate.sh" >/dev/null 2>&1
  ck 2 $? "project gate: an [x] without evidence blocks"
  grep -q '	BLOCK	' "$P/.ai_context/tasks/demo/donelog" 2>/dev/null && ok "project donelog BLOCK row written" || no "project donelog BLOCK row missing"
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
  # A research lane proves the deliverable exists and prints its own work
  # marker (U8: executed=0 is unproven); trust reads only the top command.
  printf '#!/usr/bin/env bash\nsleep 1\ntest -s reports/x.md || exit 1\necho "report: $(grep -c . reports/x.md) lines checked"\n' > "$R/scripts/check-report.sh"
  printf '#!/usr/bin/env bash\necho "report: 0 lines checked"\nexit 1\n' > "$R/scripts/canary.sh"
  chmod +x "$R/scripts/check-report.sh" "$R/scripts/canary.sh"
  mklanes "$R" 'report | reports/ scripts/ | 1 | ^report: [1-9][0-9]* lines checked$ | bash scripts/canary.sh | bash scripts/check-report.sh'
  ev "$R" trust report >/dev/null
  rc=$(ev "$R" run report)
  { [ "$rc" = 1 ] && [ "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["verdict"])' "$R/.claude/evidence/report.jsonl" 2>/dev/null)" = fail ]; } && ok "research lane fails while the deliverable is absent (verdict fail)" || no "absent deliverable: run rc=$rc ($(head -c 300 "$WORK/ev.out"))"
  mkdir -p "$R/reports" && echo content > "$R/reports/x.md"
  rc=$(ev "$R" run report)
  { [ "$rc" = 0 ] && [ "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["verdict"])' "$R/.claude/evidence/report.jsonl" 2>/dev/null)" = pass ]; } && ok "deliverable present: the lane passes (verdict pass)" || no "present deliverable: run rc=$rc ($(head -c 300 "$WORK/ev.out"))"
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
