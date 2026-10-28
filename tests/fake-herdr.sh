#!/usr/bin/env bash
# tests/fake-herdr.sh — stand-in `herdr` CLI for task-pair.sh tests.
#
# Installed into a temp bin dir under the name `herdr`. Replays the compact
# JSON shapes observed from herdr 0.9.0 (2026-09-15) and lets each test
# script the judge's behaviour through env vars — no model, no terminal.
# The screens (header, composer, status line, /new picker) were recorded on
# Codex 0.165.0 (2026-10-28, c4-live re-record).
#
#   FAKE_HERDR_LOG        every argv is appended here (one line per call)
#   FAKE_HERDR_STATE      dir; `agent start` drops `agent` there so later
#                         `agent get` calls find it (FAKE_HERDR_AGENT seeds
#                         a pre-existing agent: idle|working|blocked);
#                         `turns` drives the status line's token counters
#   FAKE_HERDR_SCREEN     file printed by `agent read` (a dialog; default:
#                         the idle screen); `send-keys … esc` replaces it
#                         with the idle screen when FAKE_HERDR_ESC_CLEARS=1
#   FAKE_HERDR_NEW        plain | picker | picker_other | picker_stuck — what
#                         `/new` shows: nothing (0.154), the 0.165.0 "Where
#                         should the new conversation run?" picker (enter
#                         closes it), the picker on option 2, or one enter
#                         does not close
#   FAKE_HERDR_PROMPT     ok | pass_major | fail_major | run_failed |
#                         run_blocked | bad_counts | v3_header | dup_key |
#                         reordered | crlf | blank_line | bad_header |
#                         base_mismatch | no_result | not_started |
#                         tree_changed | scratch_in_mailbox |
#                         scratch_ignored | scratch_tmp | timeout | stalled |
#                         blocked
#   FAKE_HERDR_SLEEP      seconds a packet prompt waits before answering
#                         (lock tests)
#   FAKE_HERDR_WAIT       ok | timeout   (for `agent wait`)
#   FAKE_HERDR_TOUCH      file the tree_changed scenario appends to
#   FAKE_HERDR_START      ok | not_ready
set -uo pipefail
LOG="${FAKE_HERDR_LOG:-/dev/null}"
STATE="${FAKE_HERDR_STATE:-/tmp}"
printf '%s\n' "$*" >> "$LOG"

turns="$(cat "$STATE/turns" 2>/dev/null || echo 0)"
status_line="  GPT-5.6-Sol high · /fixture · Approve for me · $((turns * 1200)) in · $((turns * 340)) out · Context 0% used · 5h 100% left · weekly 100% left"
idle_screen() {
  printf '  >_ OpenAI Codex (v0.165.0)\n     /fixture\n\n› Ask Codex to do anything\n\n%s\n  ? for shortcuts\n' "$status_line"
}
picker_screen() { # $1 the highlighted option (1|2)
  local a='  ' b='  '; if [ "$1" = 2 ]; then b='› '; else a='› '; fi
  printf '  >_ OpenAI Codex (v0.165.0)\n     /fixture\n\n  Where should the new conversation run?\n\n'
  printf '%s1. Use current Git worktree  Keep using the current working directory\n' "$a"
  printf '%s2. Create new Git worktree   Create a separate checkout of this repository in another directory\n\n  enter select · esc back\n' "$b"
}
turn() { echo $((turns + 1)) > "$STATE/turns"; }   # a model turn moves the token counters
agent_json() { # $1 status
  printf '{"agent":"codex","agent_status":"%s","cwd":"/fixture","focused":false,"interactive_ready":true,"name":"judge","pane_id":"w9:p9","tab_id":"w9:t1","workspace_id":"w9"}' "$1"
}
err() { # $1 code
  printf '{"error":{"code":"%s","message":"fake %s"},"id":"cli:fake"}\n' "$1" "$1" >&2; exit 1
}

# The prompt text names the packet: "…packet at <path>. It is frozen…".
packet_from() { printf '%s' "$1" | sed -n 's/.*packet at \([^ ]*\)\. It is frozen.*/\1/p'; }
hdr() { # run verdict base blocker major minor -> the six-line result header and a blank line
  printf 'run: %s\nverdict: %s\nbase: %s\nblocker: %s\nmajor: %s\nminor: %s\n\n' "$@"
}
write_result() { # $1 packet, $2 variant — the base is always the packet's own
  local res base
  res="${1%.md}.result.md"
  base="$(sed -n 's/^base:[[:space:]]*//p' "$1" | head -1)"
  case "$2" in
    pass_major) { hdr completed pass "$base" 0 1 0; echo '1. major — C1 — fake — `true` — fix'; } > "$res" ;;
    fail_major) { hdr completed fail "$base" 0 1 2; echo 'fake findings'; } > "$res" ;;
    run_failed) { hdr failed inconclusive "$base" 0 0 0; echo 'could not run'; } > "$res" ;;
    run_blocked) { hdr blocked inconclusive "$base" 0 0 0; echo 'blocked'; } > "$res" ;;
    bad_counts) hdr completed pass "$base" 0 two 0 > "$res" ;;
    v3_header) printf 'run: completed\nverdict: pass\nbase: %s\nfindings: 0\nassumptions: []\n\nv3 body\n' "$base" > "$res" ;;
    dup_key) printf 'run: completed\nverdict: pass\nbase: %s\nblocker: 0\nmajor: 0\nmajor: 0\nminor: 0\n' "$base" > "$res" ;;
    reordered) printf 'minor: 0\nmajor: 0\nblocker: 0\nbase: %s\nverdict: pass\nrun: completed\n\nbody\n' "$base" > "$res" ;;
    crlf) { hdr completed pass "$base" 0 0 0; echo 'fake judge body'; } | sed 's/$/\r/' > "$res" ;;
    blank_line) printf 'run: completed\nverdict: pass\n\nbase: %s\nblocker: 0\nmajor: 0\nminor: 0\n' "$base" > "$res" ;;
    bad_header) printf 'run: completed\nbase: %s\n\nno verdict line\n' "$base" > "$res" ;;
    base_mismatch) { hdr completed pass deadbeef 0 0 0; echo body; } > "$res" ;;
    *) { hdr completed pass "$base" 0 0 0; echo 'fake judge body'; } > "$res" ;;
  esac
}

case "$1 ${2:-}" in
  "agent get")
    if [ -f "$STATE/agent" ]; then s="$(cat "$STATE/agent")"
    elif [ -n "${FAKE_HERDR_AGENT:-}" ]; then s="$FAKE_HERDR_AGENT"
    else err agent_not_found; fi
    printf '{"id":"cli:agent:get","result":{"agent":%s,"type":"agent_info"}}\n' "$(agent_json "$s")" ;;
  "agent read")
    if [ -n "${FAKE_HERDR_SCREEN:-}" ] && [ -f "$FAKE_HERDR_SCREEN" ]; then cat "$FAKE_HERDR_SCREEN"
    elif [ -f "$STATE/screen" ]; then cat "$STATE/screen"
    else idle_screen; fi ;;
  "agent send-keys")
    if [ "${FAKE_HERDR_ESC_CLEARS:-0}" = 1 ] && [ "${4:-}" = esc ] && [ -n "${FAKE_HERDR_SCREEN:-}" ]; then idle_screen > "$FAKE_HERDR_SCREEN"; fi
    if [ "${4:-}" = enter ] && [ "${FAKE_HERDR_NEW:-plain}" != picker_stuck ]; then rm -f "$STATE/screen"; fi
    printf '{"id":"cli:agent:send-keys","result":{"type":"ok"}}\n' ;;
  "pane layout")
    printf '{"id":"cli:pane:layout","result":{"layout":{"area":{"height":35,"width":184,"x":0,"y":0},"focused_pane_id":"w9:p1","panes":[{"focused":true,"pane_id":"w9:p1","rect":{"height":35,"width":184,"x":0,"y":0}}],"splits":[],"tab_id":"w9:t1","workspace_id":"w9"},"type":"pane_layout"}}\n' ;;
  "pane split")
    printf '{"id":"cli:pane:split","result":{"pane":{"agent_status":"unknown","cwd":"/fixture","pane_id":"w9:p9","tab_id":"w9:t1","workspace_id":"w9"},"type":"pane_info"}}\n' ;;
  "pane read")
    idle_screen ;;
  "agent start")
    [ "${FAKE_HERDR_START:-ok}" = not_ready ] && err agent_not_ready
    echo idle > "$STATE/agent"
    printf '{"id":"cli:agent:start","result":{"agent":%s,"argv":["codex"],"type":"agent_started"}}\n' "$(agent_json idle)" ;;
  "agent prompt")
    if [ "$4" = "/new" ]; then   # slash command: no turn, stays idle; a fresh thread's counters start at 0
      echo 0 > "$STATE/turns"
      case "${FAKE_HERDR_NEW:-plain}" in
        picker|picker_stuck) picker_screen 1 > "$STATE/screen" ;;
        picker_other) picker_screen 2 > "$STATE/screen" ;;
      esac
      printf '{"id":"cli:agent:prompt","result":{"agent":%s,"type":"agent_prompted"}}\n' "$(agent_json idle)"; exit 0
    fi
    if [ -f "$STATE/screen" ]; then   # typed into the picker (attempt 1, 2026-10-28): its Enter picks, the text is lost
      rm -f "$STATE/screen"
      printf '{"id":"cli:agent:prompt","result":{"agent":%s,"type":"agent_prompted"}}\n' "$(agent_json idle)"; exit 0
    fi
    sleep "${FAKE_HERDR_SLEEP:-0}"
    pk="$(packet_from "$4")"
    v="${FAKE_HERDR_PROMPT:-ok}"
    case "$v" in stalled|not_started) ;; *) turn ;; esac
    case "$v" in
      ok|pass_major|fail_major|run_failed|run_blocked|bad_counts|v3_header|dup_key|reordered|crlf|blank_line|bad_header|base_mismatch)
        write_result "$pk" "$v"; st=idle ;;
      no_result|not_started) st=idle ;;
      tree_changed) write_result "$pk" ok; echo tampered >> "${FAKE_HERDR_TOUCH:?}"; st=idle ;;
      scratch_in_mailbox) write_result "$pk" ok; mkdir -p "$(dirname "$pk")/tmp-scratch"; echo x > "$(dirname "$pk")/tmp-scratch/f"; st=idle ;;
      scratch_ignored) write_result "$pk" ok; mkdir -p "$(dirname "$pk")/.pytest_cache"; echo x > "$(dirname "$pk")/.pytest_cache/x"; st=idle ;;
      scratch_tmp)   # the judge's legal scratch: the dir the prompt names (= the packet's scratch: line)
        write_result "$pk" ok; d="$(printf '%s' "$4" | sed -n 's/.*Keep every temporary file under \([^ ]*\)\. When.*/\1/p')"
        mkdir -p "$d" && echo x > "$d/cache"; st=idle ;;
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
         if [ -n "$pk" ]; then write_result "$pk" ok; rm -f "$STATE/pending-packet"; fi
         printf '{"id":"cli:agent:wait","result":{"agent":%s,"type":"agent_wait"}}\n' "$(agent_json idle)" ;;
    esac ;;
  *) err fake_unsupported ;;
esac
