#!/usr/bin/env bash
#
# SubagentStart / SubagentStop hook — spawn and return evidence for /task (v4,
# D14), and the checker's report turned into a checker record.
#
# argv = <executor|checker> <start|stop>, routed by the settings.json matchers
# (plain names: an exact match on the agent's frontmatter `name:`). Any other
# argv — a customized v3 settings.json still passing `executor`, `verifier` or
# `other` alone — is a silent no-op, never a hook error. The payload is read
# for data only (agent_id, the report), never for routing.
#
# Rows in the active task's donelog (donelog_row, 7 TAB fields):
#   SPAWN  <[~] slice> <executor|checker> <checker: the unit's tree12 | -> <agent_id> start
#   RETURN <[~] slice> <executor|checker> - <agent_id> returned | checked <id> <verdict>
# Why (2026-07-22 v_trader): the plan said a milestone was in progress while
# no executor had ever been spawned; after a compaction the two states look
# the same unless spawning leaves a trace. SubagentStart also fires when a
# background agent is re-woken (ADR-037), so one agent_id may own several
# SPAWN rows.
#
# checker stop: the report goes to `evidence.sh check` — the only checker
# record `evidence.sh done` accepts. Only the CURRENT wake counts: the rows
# after the transcript's last `user` row that is a plain prompt (the spawn
# prompt, or the "sent a message while you were working" row of a SendMessage
# re-wake), not a tool_result — a re-woken checker must never be recorded
# with the previous wake's verdict (hooks review H1). Sources, by delivery
# order, the first non-empty one wins — a verdict line is NOT a criterion:
#   a. the current wake's last SubagentHandback tool_use input.message — on
#      CC >= 2.1.271 a handed-back report is NOT the last_assistant_message,
#      and a delivered handback beats an earlier draft that had a verdict
#   b. the payload's last_assistant_message (what `claude -p` delivers, C0)
#   c. the current wake's last assistant text
# The transcript is written asynchronously (C0, CC 2.1.309: the copy taken
# inside the hook lacked its last rows; +1 s had them), so with no handback in
# the current wake and no `checker-verdict:` line in (b), an existing
# transcript is re-read every 0.5 s for up to 3 s. Residual: a lag that also
# hides a short re-wake's prompt row leaves the previous wake looking current.
# Nothing captured -> a record with verdict `uncaptured`, which done refuses:
# the harness never trusts narration.
#
# Always exit 0: a SubagentStop hook that exits 2 keeps the subagent running.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
TASKS="$ROOT/.ai_context/tasks"
kind="${1:-}"
phase="${2:-}"

payload="$(cat 2>/dev/null || true)"
case "$kind $phase" in
  'executor start'|'executor stop'|'checker start'|'checker stop') ;;
  *) exit 0 ;;
esac

_GP="$(dirname "${BASH_SOURCE[0]}")/guard-patterns.sh"
# shellcheck source=guard-patterns.sh
[ -f "$_GP" ] && . "$_GP"
[ "${GUARD_PATTERNS_V4:-}" = 1 ] || exit 0
slug="$(task_slug "$ROOT")" || exit 0
card="$TASKS/$slug/card.md"
donelog="$TASKS/$slug/donelog"
[ -f "$card" ] || exit 0   # no task, or a v3 one; an idle card still logs: a spawn is activity
slice="$(card_current_slice "$card")"

agent_id="$(printf '%s' "$payload" | python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin).get("agent_id") or "")
except Exception:
    pass' 2>/dev/null)" || agent_id=""
[ -n "$agent_id" ] || agent_id="$(printf '%s' "$payload" | sed -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
agent_id="$(printf '%s' "$agent_id" | tr -cd 'A-Za-z0-9._-')"
agent_id="${agent_id:--}"

tmo=()
command -v timeout >/dev/null 2>&1 && tmo=(timeout 20)
if [ "$phase" = start ]; then
  # A checker's SPAWN row carries the tree it is about to read (the [~] slice's, or the whole tree for a
  # final check); `evidence.sh check` voids its record when that content moved before the stop (review #17).
  t=-
  if [ "$kind" = checker ] && [ -f "$ROOT/scripts/evidence.sh" ]; then
    u="$slice"; [ "$u" = - ] && u=final
    t="$(${tmo[@]+"${tmo[@]}"} bash "$ROOT/scripts/evidence.sh" status --tree "$u" </dev/null 2>/dev/null | head -n 1)"
    case "$t" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) t="${t:0:12}" ;; *) t=- ;; esac
  fi
  donelog_row "$donelog" SPAWN "$slice" "$kind" "$t" "$agent_id" start
  exit 0
fi
if [ "$kind" = executor ]; then
  donelog_row "$donelog" RETURN "$slice" executor - "$agent_id" returned
  exit 0
fi

# checker stop: report text -> $tf, its source on stdout.
tf="$(mktemp "${TMPDIR:-/tmp}/claude-checker.XXXXXX" 2>/dev/null)" || {
  donelog_row "$donelog" RETURN "$slice" checker - "$agent_id" "check-error no temp file"
  exit 0
}
src="$(printf '%s' "$payload" | python3 -I -c '
import json, os, sys, time
try:
    p = json.load(sys.stdin)
except Exception:
    p = None
p = p if isinstance(p, dict) else {}
path = p.get("agent_transcript_path") or ""
if not path:
    t, a = p.get("transcript_path") or "", p.get("agent_id") or ""
    if isinstance(t, str) and t.endswith(".jsonl") and a:
        path = "%s/subagents/agent-%s.jsonl" % (t[:-6], a)
path = os.path.expanduser(path) if isinstance(path, str) else ""
last = p.get("last_assistant_message")
last = last if isinstance(last, str) else ""

def blocks(c, kind):
    return [b for b in c if isinstance(b, dict) and b.get("type") == kind] if isinstance(c, list) else []

def wake():  # the current wake -> (its last handback message, its last assistant text)
    hb, text = "", ""
    try:
        rows = open(path, encoding="utf-8", errors="replace").read().splitlines() if path else []
    except OSError:
        rows = []
    for row in rows:
        try:
            r = json.loads(row)
            c = r["message"]["content"]
        except Exception:
            continue
        if r.get("type") == "user":
            if isinstance(c, str) or (blocks(c, "text") and not blocks(c, "tool_result")):
                hb, text = "", ""   # a plain prompt starts a new wake
            continue
        if r.get("type") != "assistant":
            continue
        for b in blocks(c, "tool_use"):
            m = b.get("input").get("message") if b.get("name") == "SubagentHandback" and isinstance(b.get("input"), dict) else None
            hb = m if isinstance(m, str) and m.strip() else hb
        ts = [b["text"] for b in blocks(c, "text") if isinstance(b.get("text"), str)]
        text = "\n".join(ts) if ts else text
    return hb, text

hb, text = wake()
verdict = any(l.startswith("checker-verdict:") for l in last.splitlines())
end = time.time() + 3
while not hb and not verdict and path and os.path.isfile(path) and time.time() < end:
    time.sleep(0.5)
    hb, text = wake()
pick = [c for c in (("handback", hb), ("last_message", last), ("transcript", text)) if c[1].strip()] or [("none", "")]
open(sys.argv[1], "w", encoding="utf-8").write(pick[0][1])
print(pick[0][0])' "$tf" 2>/dev/null)"
case "$src" in handback|last_message|transcript) ;; *) src=none ;; esac

if [ ! -f "$ROOT/scripts/evidence.sh" ]; then
  res="check-skipped no-evidence.sh"
else
  command -v timeout >/dev/null 2>&1 && tmo=(timeout 50)
  out="$(${tmo[@]+"${tmo[@]}"} bash "$ROOT/scripts/evidence.sh" check "$slice" --agent "$agent_id" --source "$src" < "$tf" 2>&1)"
  rc=$?
  if [ "$rc" = 0 ]; then
    out="$(printf '%s\n' "$out" | grep -E '^check ' | tail -n 1)"
    res="checked $(printf '%s' "$out" | cut -d' ' -f4) $(printf '%s' "$out" | cut -d' ' -f3)"
  else
    res="check-error rc=$rc"
  fi
fi
donelog_row "$donelog" RETURN "$slice" checker - "$agent_id" "$res"
rm -f "$tf"
exit 0
