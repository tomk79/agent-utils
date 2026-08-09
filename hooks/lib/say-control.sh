#!/usr/bin/env bash
# Shared speech control for agent-utils hooks.

agent_utils_say_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum | awk '{print $1}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

agent_utils_say_now() {
  date +%s
}

agent_utils_cursor_session_info() {
  local tool="$1" payload="$2"
  local conversation_id transcript_path workspace_root raw strength

  [ "$tool" = "cursor" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$payload" ] || return 1

  conversation_id="$(jq -r '.conversation_id // .conversationId // empty' <<<"$payload" 2>/dev/null)"
  if [ -n "$conversation_id" ]; then
    raw="$tool:conversation:$conversation_id"
    strength="strong"
  else
    transcript_path="$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$payload" 2>/dev/null)"
    if [ -n "$transcript_path" ]; then
      raw="$tool:transcript:$transcript_path"
      strength="strong"
    else
      workspace_root="$(jq -r '.workspace_roots[0] // .workspaceRoots[0] // empty' <<<"$payload" 2>/dev/null)"
      [ -n "$workspace_root" ] || return 1
      raw="$tool:workspace:$workspace_root"
      strength="weak"
    fi
  fi

  printf '%s %s\n' "$strength" "$(agent_utils_say_hash "$raw")"
}

agent_utils_say_lock() {
  local lock_dir="$1" i=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 100 ] && return 1
    sleep 0.05
  done
}

agent_utils_say_unlock() {
  rmdir "$1" 2>/dev/null || true
}

agent_utils_say_pid_alive() {
  local pid="$1"
  local command_line
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *agent-notification-say.sh*|*agent-report-say.sh*)
      return 0
      ;;
  esac
  return 1
}

agent_utils_say_child_pid_alive() {
  local pid="$1"
  local command_line
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *say*|*afplay*)
      return 0
      ;;
  esac
  return 1
}

agent_utils_say_duplicate_recent() {
  local file="$1" ttl="$2" text="$3"
  local now last_ts last_hash text_hash

  [ "$ttl" -gt 0 ] || return 1
  [ -f "$file" ] || return 1

  now="$(agent_utils_say_now)"
  read -r last_ts last_hash < "$file" 2>/dev/null || return 1
  [ -n "$last_ts" ] || return 1
  [ $((now - last_ts)) -le "$ttl" ] || return 1

  text_hash="$(agent_utils_say_hash "$text")"
  [ "$last_hash" = "$text_hash" ]
}

agent_utils_cursor_begin_request() {
  local tool="$1" payload="$2"
  local required_strength="${3:-any}"
  local session_info strength session_hash base_dir state_dir lock_dir latest_file request_id

  session_info="$(agent_utils_cursor_session_info "$tool" "$payload")" || return 1
  strength="${session_info%% *}"
  if [ "$required_strength" = "strong" ] && [ "$strength" != "strong" ]; then
    return 1
  fi
  session_hash="${session_info#* }"

  base_dir="${TMPDIR:-/tmp}/agent-utils-say"
  state_dir="$base_dir/$session_hash"
  lock_dir="$state_dir.lock"
  latest_file="$state_dir/latest"

  mkdir -p "$state_dir" || return 1
  agent_utils_say_lock "$lock_dir" || return 1
  request_id="$(agent_utils_say_now).$$.$RANDOM"
  printf '%s\n' "$request_id" > "$latest_file"
  agent_utils_say_unlock "$lock_dir"

  printf '%s\n%s\n' "$latest_file" "$request_id"
}

agent_utils_cursor_begin_strong_request() {
  agent_utils_cursor_begin_request "$1" "$2" strong
}

agent_utils_say_request_is_latest() {
  local latest_file="$1" request_id="$2"
  [ -n "$latest_file" ] || return 1
  [ -n "$request_id" ] || return 1
  [ "$(cat "$latest_file" 2>/dev/null)" = "$request_id" ]
}

agent_utils_say_run_sequence() {
  local state_dir="$1" latest_file="$2" request_id="$3" debounce="$4" dedupe_ttl="$5" dedupe_text="$6"
  shift 6

  local current_child=""
  local child_file="$state_dir/child.pid"

  agent_utils_say_cleanup() {
    if [ -n "$current_child" ]; then
      kill "$current_child" 2>/dev/null || true
      wait "$current_child" 2>/dev/null || true
      if [ "$(cat "$child_file" 2>/dev/null)" = "$current_child" ]; then
        rm -f "$child_file"
      fi
    fi
    if [ "$(cat "$latest_file" 2>/dev/null)" = "$request_id" ]; then
      rm -f "$state_dir/worker.pid"
    fi
    exit 0
  }

  trap agent_utils_say_cleanup TERM INT HUP

  sleep "$debounce"
  [ "$(cat "$latest_file" 2>/dev/null)" = "$request_id" ] || exit 0

  local kind value
  while [ "$#" -gt 0 ]; do
    kind="$1"
    value="$2"
    shift 2

    case "$kind" in
      sound)
        command -v afplay >/dev/null 2>&1 || continue
        afplay "$value" >/dev/null 2>&1 &
        ;;
      say)
        say "$value" >/dev/null 2>&1 &
        ;;
      *)
        continue
        ;;
    esac

    current_child="$!"
    printf '%s\n' "$current_child" > "$child_file"
    wait "$current_child" 2>/dev/null || true
    if [ "$(cat "$child_file" 2>/dev/null)" = "$current_child" ]; then
      rm -f "$child_file"
    fi
    current_child=""
  done

  if [ "$dedupe_ttl" -gt 0 ]; then
    printf '%s %s\n' "$(agent_utils_say_now)" "$(agent_utils_say_hash "$dedupe_text")" > "$state_dir/last"
  fi

  if [ "$(cat "$latest_file" 2>/dev/null)" = "$request_id" ]; then
    rm -f "$state_dir/worker.pid"
  fi
}

agent_utils_cursor_speak() {
  local tool="$1" payload="$2" debounce="$3" dedupe_ttl="$4" dedupe_text="$5"
  shift 5

  local session_info strength session_hash base_dir state_dir lock_dir latest_file pid_file child_file last_file
  local old_pid old_child_pid old_alive=false request_id worker_pid

  session_info="$(agent_utils_cursor_session_info "$tool" "$payload")" || return 1
  strength="${session_info%% *}"
  session_hash="${session_info#* }"

  base_dir="${TMPDIR:-/tmp}/agent-utils-say"
  state_dir="$base_dir/$session_hash"
  lock_dir="$state_dir.lock"
  latest_file="$state_dir/latest"
  pid_file="$state_dir/worker.pid"
  child_file="$state_dir/child.pid"
  last_file="$state_dir/last"

  mkdir -p "$state_dir" || return 1

  agent_utils_say_lock "$lock_dir" || return 1

  old_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if agent_utils_say_pid_alive "$old_pid"; then
    old_alive=true
  fi

  if [ "$old_alive" = false ] && agent_utils_say_duplicate_recent "$last_file" "$dedupe_ttl" "$dedupe_text"; then
    agent_utils_say_unlock "$lock_dir"
    return 0
  fi

  request_id="$(agent_utils_say_now).$$.$RANDOM"
  printf '%s\n' "$request_id" > "$latest_file"

  if { [ "$strength" = "strong" ] || [ "${AGENT_UTILS_CURSOR_KILL_WEAK:-}" = "1" ]; } && [ "$old_alive" = true ]; then
    old_child_pid="$(cat "$child_file" 2>/dev/null || true)"
    if agent_utils_say_child_pid_alive "$old_child_pid"; then
      kill "$old_child_pid" 2>/dev/null || true
    fi
    kill "$old_pid" 2>/dev/null || true
  fi

  agent_utils_say_run_sequence "$state_dir" "$latest_file" "$request_id" "$debounce" "$dedupe_ttl" "$dedupe_text" "$@" &
  worker_pid="$!"
  printf '%s\n' "$worker_pid" > "$pid_file"
  disown "$worker_pid" 2>/dev/null || true

  agent_utils_say_unlock "$lock_dir"
  return 0
}
