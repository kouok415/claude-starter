#!/usr/bin/env bash
# tests/fake-herdr.sh — stand-in `herdr` CLI for task-pair.sh tests.
#
# Installed into a temp bin dir under the name `herdr`. Replays the compact
# JSON shapes observed from herdr 0.9.0 (2026-09-15) and lets each test
# script the judge's behaviour through env vars — no model, no terminal:
#
#   FAKE_HERDR_LOG        every argv is appended here (one line per call)
#   FAKE_HERDR_STATE      dir; `agent start` drops `agent` there so later
#                         `agent get` calls find it (FAKE_HERDR_AGENT seeds
#                         a pre-existing agent: idle|working|blocked)
#   FAKE_HERDR_SCREEN     file printed by `agent read` (default: a plain
#                         Codex status line); `send-keys … esc` restores the
#                         plain line when FAKE_HERDR_ESC_CLEARS=1
#   FAKE_HERDR_PROMPT     ok | no_result | bad_header | base_mismatch |
#                         tree_changed | timeout | stalled | blocked
#   FAKE_HERDR_WAIT       ok | timeout   (for `agent wait`)
#   FAKE_HERDR_TOUCH      file the tree_changed scenario appends to
#   FAKE_HERDR_START      ok | not_ready
set -uo pipefail
LOG="${FAKE_HERDR_LOG:-/dev/null}"
STATE="${FAKE_HERDR_STATE:-/tmp}"
printf '%s\n' "$*" >> "$LOG"

status_line='  gpt-5.6-terra medium · /fixture · Approve for me · 12 in · 34 out · Context 0% used'
agent_json() { # $1 status
  printf '{"agent":"codex","agent_status":"%s","cwd":"/fixture","focused":false,"interactive_ready":true,"name":"judge","pane_id":"w9:p9","tab_id":"w9:t1","workspace_id":"w9"}' "$1"
}
err() { # $1 code
  printf '{"error":{"code":"%s","message":"fake %s"},"id":"cli:fake"}\n' "$1" "$1" >&2; exit 1
}

# The prompt text names the packet: "…packet at <path>. It is frozen…".
packet_from() { printf '%s' "$1" | sed -n 's/.*packet at \([^ ]*\)\. It is frozen.*/\1/p'; }
write_result() { # $1 packet, $2 variant
  local res base
  res="${1%.md}.result.md"
  base="$(sed -n 's/^base:[[:space:]]*//p' "$1" | head -1)"
  case "$2" in
    bad_header) printf 'run: completed\nbase: %s\n\nno verdict line\n' "$base" > "$res" ;;
    base_mismatch) printf 'run: completed\nverdict: pass\nbase: deadbeef\nfindings: 0\n' > "$res" ;;
    *) printf 'run: completed\nverdict: pass\nbase: %s\nfindings: 0\nassumptions: []\n\nfake judge body\n' "$base" > "$res" ;;
  esac
}

case "$1 $2" in
  "agent get")
    if [ -f "$STATE/agent" ]; then s="$(cat "$STATE/agent")"
    elif [ -n "${FAKE_HERDR_AGENT:-}" ]; then s="$FAKE_HERDR_AGENT"
    else err agent_not_found; fi
    printf '{"id":"cli:agent:get","result":{"agent":%s,"type":"agent_info"}}\n' "$(agent_json "$s")" ;;
  "agent read")
    if [ -n "${FAKE_HERDR_SCREEN:-}" ] && [ -f "$FAKE_HERDR_SCREEN" ]; then cat "$FAKE_HERDR_SCREEN"; else printf '%s\n' "$status_line"; fi ;;
  "agent send-keys")
    if [ "${FAKE_HERDR_ESC_CLEARS:-0}" = 1 ] && printf '%s' "$*" | grep -q ' esc'; then
      [ -n "${FAKE_HERDR_SCREEN:-}" ] && printf '%s\n' "$status_line" > "$FAKE_HERDR_SCREEN"
    fi
    printf '{"id":"cli:agent:send-keys","result":{"type":"ok"}}\n' ;;
  "pane layout")
    printf '{"id":"cli:pane:layout","result":{"layout":{"area":{"height":35,"width":184,"x":0,"y":0},"focused_pane_id":"w9:p1","panes":[{"focused":true,"pane_id":"w9:p1","rect":{"height":35,"width":184,"x":0,"y":0}}],"splits":[],"tab_id":"w9:t1","workspace_id":"w9"},"type":"pane_layout"}}\n' ;;
  "pane split")
    printf '{"id":"cli:pane:split","result":{"pane":{"agent_status":"unknown","cwd":"/fixture","pane_id":"w9:p9","tab_id":"w9:t1","workspace_id":"w9"},"type":"pane_info"}}\n' ;;
  "pane read")
    printf '%s\n' "$status_line" ;;
  "agent start")
    [ "${FAKE_HERDR_START:-ok}" = not_ready ] && err agent_not_ready
    echo idle > "$STATE/agent"
    printf '{"id":"cli:agent:start","result":{"agent":%s,"argv":["codex"],"type":"agent_started"}}\n' "$(agent_json idle)" ;;
  "agent prompt")
    if [ "$4" = "/new" ]; then   # slash command: no turn, stays idle
      printf '{"id":"cli:agent:prompt","result":{"agent":%s,"type":"agent_prompted"}}\n' "$(agent_json idle)"; exit 0
    fi
    pk="$(packet_from "$4")"
    case "${FAKE_HERDR_PROMPT:-ok}" in
      ok) write_result "$pk" ok; st=idle ;;
      no_result) st=idle ;;
      bad_header) write_result "$pk" bad_header; st=idle ;;
      base_mismatch) write_result "$pk" base_mismatch; st=idle ;;
      tree_changed) write_result "$pk" ok; echo tampered >> "${FAKE_HERDR_TOUCH:?}"; st=idle ;;
      timeout) printf '%s' "$pk" > "$STATE/pending-packet"; err timeout ;;
      stalled) err agent_prompt_stalled ;;
      blocked) st=blocked; echo blocked > "$STATE/agent" ;;
      *) err fake_unknown_scenario ;;
    esac
    printf '{"id":"cli:agent:prompt","result":{"agent":%s,"type":"agent_prompted"}}\n' "$(agent_json "$st")" ;;
  "agent wait")
    case "${FAKE_HERDR_WAIT:-ok}" in
      timeout) err timeout ;;
      *) pk="$(cat "$STATE/pending-packet" 2>/dev/null || true)"
         [ -n "$pk" ] && write_result "$pk" ok
         printf '{"id":"cli:agent:wait","result":{"agent":%s,"type":"agent_wait"}}\n' "$(agent_json idle)" ;;
    esac ;;
  *) err fake_unsupported ;;
esac
