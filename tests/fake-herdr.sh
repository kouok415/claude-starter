#!/usr/bin/env bash
# tests/fake-herdr.sh — stand-in `herdr` CLI for task-pair.sh tests.
#
# Installed into a temp bin dir under the name `herdr`. Replays the compact
# JSON shapes observed from herdr 0.9.0 (2026-09-15) and lets each test
# script the judge's behaviour through env vars — no model, no terminal.
# The screens (header, composer, status line, /new picker) and the judge's
# Codex transcript (rollout) shape were recorded on Codex 0.165.0
# (2026-10-28, c4-live re-record).
#
#   FAKE_HERDR_LOG        every argv is appended here (one line per call)
#   FAKE_HERDR_STATE      dir; `agent start` drops `agent` (status) and
#                         `agent-name` there so later `agent get` calls find
#                         it (FAKE_HERDR_AGENT seeds a pre-existing agent:
#                         idle|working|blocked); `pane split --cwd` keeps the
#                         judge's cwd; `turns` drives the token counters
#   FAKE_HERDR_CWD        the cwd `agent get` reports (default: the split's
#                         --cwd, else $PWD); FAKE_HERDR_PANE its pane_id (w9:p9)
#   FAKE_HERDR_SCREEN     file printed by `agent read` (a dialog; default:
#                         the idle screen); `send-keys … esc` removes it when
#                         FAKE_HERDR_ESC_CLEARS=1, `/new` when
#                         FAKE_HERDR_NEW_CLEARS=1
#   FAKE_HERDR_RUN_SCREEN file shown from the packet prompt on (the judge's
#                         screen during and after its turn) until the next /new
#   FAKE_HERDR_BLANK_EVERY n: every n-th `agent read` prints nothing (a repaint)
#   FAKE_HERDR_NEW        plain | picker | picker_other | picker_stuck — what
#                         `/new` shows: nothing (0.154), the 0.165.0 "Where
#                         should the new conversation run?" picker (enter
#                         closes it), the picker on option 2, or one enter
#                         does not close; FAKE_HERDR_NEW_DELAY=s: /new takes
#                         effect s seconds late (text typed before that is
#                         lost); FAKE_HERDR_NEW_FAIL=1: herdr refuses /new
#   FAKE_HERDR_PROMPT     ok | pass_major | fail_major | run_failed |
#                         run_blocked | bad_counts | counts_mismatch | leaky |
#                         v3_header | dup_key | reordered | crlf | blank_line |
#                         bad_header | base_mismatch | no_result |
#                         not_started | tree_changed | scratch_in_mailbox |
#                         scratch_ignored | scratch_tmp | timeout |
#                         timeout_done | stalled | stalled_late | blocked |
#                         refused_blocked
#   FAKE_HERDR_RESULT     the result a deferred write uses (timeout,
#                         timeout_done, blocked, stalled_late; default ok)
#   FAKE_HERDR_PROV       how the judge's transcript shows its write:
#                         apply_patch (default: the exec call + FileChange
#                         item, as recorded live) | filechange | exec | shell
#                         (a shell redirect, no apply_patch) | aborted (turn
#                         aborted after the write) | none (no transcript)
#   FAKE_HERDR_SLEEP      seconds a packet prompt waits before answering
#                         (lock tests)
#   FAKE_HERDR_WAIT       ok | timeout   (for `agent wait`)
#   FAKE_HERDR_TOUCH      file the tree_changed scenario appends to
#   FAKE_HERDR_START      ok | not_ready
# `fake-rollout <result> <out> [variant] [prompt]` writes one transcript
# (tests that call evidence.sh codex directly).
set -uo pipefail
LOG="${FAKE_HERDR_LOG:-/dev/null}"
STATE="${FAKE_HERDR_STATE:-/tmp}"
printf '%s\n' "$*" >> "$LOG"

picker_screen() { # $1 the highlighted option (1|2)
  local a='  ' b='  '; if [ "$1" = 2 ]; then b='› '; else a='› '; fi
  printf '  >_ OpenAI Codex (v0.165.0)\n     /fixture\n\n  Where should the new conversation run?\n\n'
  printf '%s1. Use current Git worktree  Keep using the current working directory\n' "$a"
  printf '%s2. Create new Git worktree   Create a separate checkout of this repository in another directory\n\n  enter select · esc back\n' "$b"
}
new_effect() { # what /new does once it lands
  echo 0 > "$STATE/turns"; rm -f "$STATE/run-screen"
  [ "${FAKE_HERDR_NEW_CLEARS:-0}" != 1 ] || [ -z "${FAKE_HERDR_SCREEN:-}" ] || rm -f "$FAKE_HERDR_SCREEN"
  case "${FAKE_HERDR_NEW:-plain}" in
    picker|picker_stuck) picker_screen 1 > "$STATE/screen" ;;
    picker_other) picker_screen 2 > "$STATE/screen" ;;
  esac
}
# A /new sent with FAKE_HERDR_NEW_DELAY lands once its time has come.
if [ -f "$STATE/new-at" ] && [ "$(date +%s)" -ge "$(cat "$STATE/new-at")" ]; then rm -f "$STATE/new-at"; new_effect; fi

turns="$(cat "$STATE/turns" 2>/dev/null || echo 0)"
status_line="  GPT-5.6-Sol high · /fixture · Approve for me · $((turns * 1200)) in · $((turns * 340)) out · Context 0% used · 5h 100% left · weekly 100% left"
idle_screen() {
  printf '  >_ OpenAI Codex (v0.165.0)\n     /fixture\n\n› Ask Codex to do anything\n\n%s\n  ? for shortcuts\n' "$status_line"
}
turn() { echo $((turns + 1)) > "$STATE/turns"; }   # a model turn moves the token counters
agent_cwd() { if [ -n "${FAKE_HERDR_CWD:-}" ]; then echo "$FAKE_HERDR_CWD"; elif [ -f "$STATE/agent-cwd" ]; then cat "$STATE/agent-cwd"; else echo "$PWD"; fi; }
agent_json() { # $1 status
  printf '{"agent":"codex","agent_status":"%s","cwd":"%s","focused":false,"interactive_ready":true,"name":"judge","pane_id":"%s","tab_id":"w9:t1","workspace_id":"w9"}' \
    "$1" "$(agent_cwd)" "${FAKE_HERDR_PANE:-w9:p9}"
}
err() { # $1 code
  printf '{"error":{"code":"%s","message":"fake %s"},"id":"cli:fake"}\n' "$1" "$1" >&2; exit 1
}

# The prompt text names the packet: "…packet at <path>; its paths are…".
packet_from() { printf '%s' "$1" | sed -n 's/.*packet at \([^ ;]*[^ ;.]\)[;.] .*/\1/p'; }
hdr() { # run verdict base blocker major minor -> the six-line result header and a blank line
  printf 'run: %s\nverdict: %s\nbase: %s\nblocker: %s\nmajor: %s\nminor: %s\n\n' "$@"
}
write_result() { # $1 packet, $2 variant — the base is always the packet's own
  local res base
  res="${1%.md}.result.md"
  base="$(sed -n 's/^base:[[:space:]]*//p' "$1" | head -1)"
  case "$2" in
    pass_major) { hdr completed pass "$base" 0 1 0; echo '1. major — C1 — fake — `true` — fix'; } > "$res" ;;
    fail_major) { hdr completed fail "$base" 0 1 2; echo '1. major — C1 — fake defect — `true` — fix'
                  echo '2. minor — C2 — fake nit — `true` — none'; echo '3. minor — R1 — fake nit — `true` — none'; } > "$res" ;;
    counts_mismatch) { hdr completed pass "$base" 0 0 0; echo '1. blocker — C1 — a blocker the header does not count — `true` — fix'; } > "$res" ;;
    leaky) { hdr completed pass "$base" 0 0 0; printf 'C1 ran: connecting to db at 10.%s.30.40:5432 — ok\n' 20; } > "$res" ;;   # an internal IP, built at runtime
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

# The judge's Codex transcript of one turn, in the shape recorded live on
# 0.165.0: session_meta (cwd), task_started, the prompt, the result written
# by an apply_patch exec call and its FileChange item, the final answer,
# task_complete. Written only under a CODEX_HOME the test set.
rollout_file() { # $1 result path or '', $2 out file, $3 variant, $4 prompt
  python3 -I - "$2" "$PWD" "$1" "$3" "$4" <<'PY'
import datetime, json, os, sys
out, cwd, res, var, prompt = sys.argv[1:6]
def ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
rows = []
def ev(typ, payload):
    rows.append({'timestamp': ts(), 'type': typ, 'payload': payload})
ev('session_meta', {'id': 'fake-session', 'timestamp': ts(), 'cwd': cwd, 'originator': 'codex-tui', 'cli_version': '0.165.0'})
ev('event_msg', {'type': 'task_started', 'turn_id': 'fake-turn'})
ev('event_msg', {'type': 'item_completed', 'item': {'type': 'UserMessage', 'content': [{'type': 'text', 'text': prompt}]}})
absr = ''
if res and os.path.exists(res):
    absr = res if res.startswith('/') else os.path.join(cwd, res)
    body = open(res, encoding='utf-8', newline='').read()
    patch = '*** Begin Patch\n*** Add File: %s\n%s*** End Patch' % (absr, ''.join('+%s\n' % l for l in body.rstrip('\n').split('\n')))
    if var in ('apply_patch', 'exec', 'aborted'):
        ev('response_item', {'type': 'custom_tool_call', 'status': 'completed', 'call_id': 'call_fake', 'name': 'exec',
                             'input': 'const patch = %s;\ntext(await tools.apply_patch(patch));' % json.dumps(patch)})
    if var in ('apply_patch', 'filechange', 'aborted'):
        ev('event_msg', {'type': 'item_completed', 'item': {'type': 'FileChange', 'id': 'exec-fake', 'changes': {absr: {'type': 'add', 'content': body}}, 'status': 'completed'}})
    if var == 'shell':
        ev('response_item', {'type': 'function_call', 'name': 'exec_command', 'call_id': 'call_fake',
                             'arguments': json.dumps({'cmd': "cat > %s <<'EOF'\n%sEOF" % (res, body)})})
if var == 'aborted':
    ev('event_msg', {'type': 'turn_aborted', 'turn_id': 'fake-turn', 'reason': 'interrupted'})
else:
    ev('event_msg', {'type': 'item_completed', 'item': {'type': 'AgentMessage', 'content': [{'type': 'Text', 'text': absr}], 'phase': 'final_answer'}})
    ev('event_msg', {'type': 'task_complete', 'turn_id': 'fake-turn', 'last_agent_message': absr})
with open(out, 'w', encoding='utf-8') as f:
    for r in rows:
        f.write(json.dumps(r, separators=(',', ':'), ensure_ascii=False) + '\n')
PY
}
rollout() { # $1 packet, $2 result written (1) or not (0), $3 prompt
  local v="${FAKE_HERDR_PROV:-apply_patch}" d r=""
  [ -n "${CODEX_HOME:-}" ] && [ "$v" != none ] || return 0
  d="$CODEX_HOME/sessions/$(date +%Y/%m/%d)"; mkdir -p "$d"
  [ "$2" != 1 ] || r="${1%.md}.result.md"
  rollout_file "$r" "$d/rollout-$(date +%Y-%m-%dT%H-%M-%S)-fake-$(basename "$1" .md).jsonl" "$v" "$3"
}
deferred() { # the turn a prompt left running finishes now: result + transcript
  local pk
  pk="$(cat "$STATE/pending-packet" 2>/dev/null || true)"
  [ -n "$pk" ] || return 0
  write_result "$pk" "${FAKE_HERDR_RESULT:-ok}"
  rollout "$pk" 1 "$(cat "$STATE/pending-prompt" 2>/dev/null || true)"
  rm -f "$STATE/pending-packet" "$STATE/pending-prompt"
}
pending() { printf '%s' "$1" > "$STATE/pending-packet"; printf '%s' "$2" > "$STATE/pending-prompt"; }

case "$1 ${2:-}" in
  "fake-rollout "*)
    rollout_file "$2" "$3" "${4:-apply_patch}" "${5:-Read and execute the packet}" ;;
  "agent get")
    if [ -f "$STATE/agent-name" ] && [ "$(cat "$STATE/agent-name")" != "${3:-}" ] && [ -z "${FAKE_HERDR_AGENT:-}" ]; then err agent_not_found; fi
    if [ -f "$STATE/agent" ]; then s="$(cat "$STATE/agent")"
    elif [ -n "${FAKE_HERDR_AGENT:-}" ]; then s="$FAKE_HERDR_AGENT"
    else err agent_not_found; fi
    printf '{"id":"cli:agent:get","result":{"agent":%s,"type":"agent_info"}}\n' "$(agent_json "$s")" ;;
  "agent read")
    n=$(( $(cat "$STATE/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/reads"
    if [ -n "${FAKE_HERDR_BLANK_EVERY:-}" ] && [ $((n % FAKE_HERDR_BLANK_EVERY)) = 0 ]; then exit 0; fi
    if [ -n "${FAKE_HERDR_SCREEN:-}" ] && [ -f "$FAKE_HERDR_SCREEN" ]; then cat "$FAKE_HERDR_SCREEN"
    elif [ -f "$STATE/screen" ]; then cat "$STATE/screen"
    elif [ -f "$STATE/run-screen" ]; then cat "$STATE/run-screen"
    else idle_screen; fi ;;
  "agent send-keys")
    if [ "${FAKE_HERDR_ESC_CLEARS:-0}" = 1 ] && [ "${4:-}" = esc ] && [ -n "${FAKE_HERDR_SCREEN:-}" ]; then rm -f "$FAKE_HERDR_SCREEN"; fi
    if [ "${4:-}" = enter ] && [ "${FAKE_HERDR_NEW:-plain}" != picker_stuck ]; then rm -f "$STATE/screen"; fi
    printf '{"id":"cli:agent:send-keys","result":{"type":"ok"}}\n' ;;
  "pane layout")
    printf '{"id":"cli:pane:layout","result":{"layout":{"area":{"height":35,"width":184,"x":0,"y":0},"focused_pane_id":"w9:p1","panes":[{"focused":true,"pane_id":"w9:p1","rect":{"height":35,"width":184,"x":0,"y":0}}],"splits":[],"tab_id":"w9:t1","workspace_id":"w9"},"type":"pane_layout"}}\n' ;;
  "pane split")
    c="$PWD"; while [ $# -gt 0 ]; do if [ "$1" = --cwd ]; then c="${2:-}"; fi; shift; done
    printf '%s\n' "$c" > "$STATE/agent-cwd"
    printf '{"id":"cli:pane:split","result":{"pane":{"agent_status":"unknown","cwd":"%s","pane_id":"%s","tab_id":"w9:t1","workspace_id":"w9"},"type":"pane_info"}}\n' "$c" "${FAKE_HERDR_PANE:-w9:p9}" ;;
  "pane read")
    idle_screen ;;
  "agent start")
    [ "${FAKE_HERDR_START:-ok}" = not_ready ] && err agent_not_ready
    echo idle > "$STATE/agent"; printf '%s\n' "$3" > "$STATE/agent-name"
    printf '{"id":"cli:agent:start","result":{"agent":%s,"argv":["codex"],"type":"agent_started"}}\n' "$(agent_json idle)" ;;
  "agent prompt")
    if [ "$4" = "/new" ]; then   # slash command: no turn, stays idle; a fresh thread's counters start at 0
      [ "${FAKE_HERDR_NEW_FAIL:-0}" != 1 ] || err fake_new_refused
      if [ -n "${FAKE_HERDR_NEW_DELAY:-}" ]; then echo $(( $(date +%s) + FAKE_HERDR_NEW_DELAY )) > "$STATE/new-at"; else new_effect; fi
      printf '{"id":"cli:agent:prompt","result":{"agent":%s,"type":"agent_prompted"}}\n' "$(agent_json idle)"; exit 0
    fi
    if [ -f "$STATE/screen" ] || [ -f "$STATE/new-at" ]; then   # typed into the picker, or while /new still opens it (attempt 1, 2026-10-28): its Enter picks, the text is lost
      if [ -f "$STATE/new-at" ]; then rm -f "$STATE/new-at"; new_effect; fi
      rm -f "$STATE/screen"
      printf '{"id":"cli:agent:prompt","result":{"agent":%s,"type":"agent_prompted"}}\n' "$(agent_json idle)"; exit 0
    fi
    sleep "${FAKE_HERDR_SLEEP:-0}"
    pk="$(packet_from "$4")"
    v="${FAKE_HERDR_PROMPT:-ok}"
    case "$v" in
      stalled|not_started|refused_blocked) ;;
      *) turn; [ -z "${FAKE_HERDR_RUN_SCREEN:-}" ] || cp "$FAKE_HERDR_RUN_SCREEN" "$STATE/run-screen" ;;
    esac
    case "$v" in
      ok|pass_major|fail_major|counts_mismatch|leaky|run_failed|run_blocked|bad_counts|v3_header|dup_key|reordered|crlf|blank_line|bad_header|base_mismatch)
        write_result "$pk" "$v"; rollout "$pk" 1 "$4"; st=idle ;;
      no_result) rollout "$pk" 0 "$4"; st=idle ;;
      not_started) st=idle ;;
      tree_changed) write_result "$pk" ok; rollout "$pk" 1 "$4"; echo tampered >> "${FAKE_HERDR_TOUCH:?}"; st=idle ;;
      scratch_in_mailbox) write_result "$pk" ok; rollout "$pk" 1 "$4"; mkdir -p "$(dirname "$pk")/tmp-scratch"; echo x > "$(dirname "$pk")/tmp-scratch/f"; st=idle ;;
      scratch_ignored) write_result "$pk" ok; rollout "$pk" 1 "$4"; mkdir -p "$(dirname "$pk")/.pytest_cache"; echo x > "$(dirname "$pk")/.pytest_cache/x"; st=idle ;;
      scratch_tmp)   # the judge's legal scratch: the dir the prompt names (= the packet's scratch: line)
        write_result "$pk" ok; rollout "$pk" 1 "$4"; d="$(printf '%s' "$4" | sed -n 's/.*Keep every temporary file under \([^ ]*\)\. When.*/\1/p')"
        mkdir -p "$d" && echo x > "$d/cache"; st=idle ;;
      timeout) pending "$pk" "$4"; err timeout ;;
      timeout_done)   # the turn ends after herdr's own wait gave up
        write_result "$pk" "${FAKE_HERDR_RESULT:-ok}"; rollout "$pk" 1 "$4"; err timeout ;;
      stalled) err agent_prompt_stalled ;;
      stalled_late)   # herdr gave up on seeing the turn start; it started a moment later
        pending "$pk" "$4"; echo working > "$STATE/agent"; err agent_prompt_stalled ;;
      refused_blocked) err agent_blocked ;;   # herdr refuses to type into a blocked agent
      blocked) pending "$pk" "$4"; st=blocked; echo blocked > "$STATE/agent" ;;
      *) err fake_unknown_scenario ;;
    esac
    printf '{"id":"cli:agent:prompt","result":{"agent":%s,"type":"agent_prompted"}}\n' "$(agent_json "$st")" ;;
  "agent wait")
    case "${FAKE_HERDR_WAIT:-ok}" in
      timeout) err timeout ;;
      *) deferred; [ ! -f "$STATE/agent" ] || echo idle > "$STATE/agent"
         printf '{"id":"cli:agent:wait","result":{"agent":%s,"type":"agent_wait"}}\n' "$(agent_json idle)" ;;
    esac ;;
  *) err fake_unsupported ;;
esac
