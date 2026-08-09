#!/usr/bin/env bash
# User-level (global) port of the project's agent-report-say.sh hook.
# Speaks a short summary of the finished turn via macOS `say`, gated by the
# hardcoded ENABLE_HOOKS/ENABLE_REPORT flags below (global, not per-repo, no
# .env file). Reads the original hook JSON payload on stdin and
# tries, in order: Codex's final answer in the transcript, hook-provided
# assistant message fields, then the last assistant text block in the transcript
# the payload points to, then falls back to a generic message.
# The raw text can be rewritten into a short spoken-friendly Japanese sentence
# by a configured summarizer. The default summarizer is `none`, which speaks the
# raw (truncated) text without calling an LLM. AGENT_REPORT_SUMMARIZING guards
# against the summarizer's own agent command re-triggering this same Stop hook
# recursively.
# Always exits 0 - this is cosmetic and must never affect the stop decision.
set -uo pipefail

ENABLE_HOOKS=true
ENABLE_REPORT=say

tool="${1:?tool name required (claude, codex, cursor, copilot, opencode)}"
outcome="${2:-done}" # done | gaveup

payload="$(cat 2>/dev/null || true)"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$script_dir/agent-utils-lib/say-control.sh" ]; then
  # shellcheck source=/dev/null
  source "$script_dir/agent-utils-lib/say-control.sh"
else
  script_real="$script_dir/$(basename "${BASH_SOURCE[0]}")"
  if [ -L "$script_real" ]; then
    script_real="$(readlink "$script_real")"
    script_real_dir="$(cd "$(dirname "$script_real")" && pwd)"
    if [ -r "$script_real_dir/../lib/say-control.sh" ]; then
      # shellcheck source=/dev/null
      source "$script_real_dir/../lib/say-control.sh"
    fi
  elif [ -r "$script_dir/../lib/say-control.sh" ]; then
    # shellcheck source=/dev/null
    source "$script_dir/../lib/say-control.sh"
  fi
fi

[ "$(uname -s 2>/dev/null)" = "Darwin" ] || exit 0
command -v say >/dev/null 2>&1 || exit 0

play_sound() {
  command -v afplay >/dev/null 2>&1 || return 0
  afplay "$1" >/dev/null 2>&1
}

speak() {
  play_sound /System/Library/Sounds/Glass.aiff
  say "報告します。"
  say "$1" >/dev/null 2>&1
  say "以上です。"
  play_sound /System/Library/Sounds/Bottle.aiff
}

speak_report_text() {
  local text="$1"

  if [ "$tool" = "cursor" ] && declare -f agent_utils_cursor_speak >/dev/null 2>&1; then
    AGENT_UTILS_CURSOR_KILL_WEAK=1
    if agent_utils_cursor_speak "$tool" "$payload" 2.5 30 "$text" \
      sound /System/Library/Sounds/Glass.aiff \
      say "報告します。" \
      say "$text" \
      say "以上です。" \
      sound /System/Library/Sounds/Bottle.aiff; then
      unset AGENT_UTILS_CURSOR_KILL_WEAK
      return 0
    fi
    unset AGENT_UTILS_CURSOR_KILL_WEAK
  fi

  speak "$text"
}

extract_codex_transcript_message() {
  local transcript_path="$1"
  tail -n 500 "$transcript_path" 2>/dev/null | jq -rs '
    def content_text($items):
      [$items[]? | select(.type=="text" or .type=="output_text" or .type=="Text") | (.text // empty)] | join("\n");

    [
      .[] |
      if .type=="response_item" and .payload.type=="message" and .payload.role=="assistant" and .payload.phase=="final_answer" then
        content_text(.payload.content)
      elif .type=="event_msg" and .payload.type=="task_complete" and ((.payload.last_agent_message // "") != "") then
        .payload.last_agent_message
      elif .type=="event_msg" and .payload.item.type=="AgentMessage" and .payload.item.phase=="final_answer" then
        content_text(.payload.item.content)
      else
        empty
      end
    ] | map(select(. != "")) | last // empty
  ' 2>/dev/null
}

extract_generic_transcript_message() {
  local transcript_path="$1"
  tail -n 200 "$transcript_path" 2>/dev/null | jq -rs '
    [
      .[] |
      if .type=="assistant" then
        .message.content[]? | select(.type=="text" or .type=="output_text") | (.text // empty)
      elif .role=="assistant" then
        if (.content | type) == "array" then
          .content[]? | select(.type=="text" or .type=="output_text") | (.text // empty)
        else
          .content // empty
        end
      else
        empty
      end
    ] | map(select(. != "")) | last // empty
  ' 2>/dev/null
}

agent_utils_config_file() {
  if [ -n "${AGENT_UTILS_CONFIG_FILE:-}" ]; then
    printf '%s' "$AGENT_UTILS_CONFIG_FILE"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.config/agent-utils/config.json' "$HOME"
  else
    printf ''
  fi
}

agent_utils_report_summarizer_name() {
  local current_tool="$1"
  local config_file env_tool env_name env_value

  env_tool="$(printf '%s' "$current_tool" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
  env_name="AGENT_UTILS_REPORT_SUMMARIZER_${env_tool}"
  env_value="$(printenv "$env_name" 2>/dev/null || true)"
  if [ -n "$env_value" ]; then
    printf '%s' "$env_value"
    return 0
  fi

  if [ -n "${AGENT_UTILS_REPORT_SUMMARIZER:-}" ]; then
    printf '%s' "$AGENT_UTILS_REPORT_SUMMARIZER"
    return 0
  fi

  config_file="$(agent_utils_config_file)"
  if [ -n "$config_file" ] && [ -r "$config_file" ] && command -v jq >/dev/null 2>&1; then
    jq -r --arg tool "$current_tool" '
      .agentReportSay.summarizer.byTool[$tool]
      // .agentReportSay.summarizer.default
      // "none"
    ' "$config_file" 2>/dev/null
    return 0
  fi

  printf 'none'
}

agent_utils_report_summarizer_profile() {
  local profile_name="$1"
  local config_file

  if [ "$profile_name" = "none" ]; then
    printf '{"type":"none"}'
    return 0
  fi

  config_file="$(agent_utils_config_file)"
  if [ -n "$config_file" ] && [ -r "$config_file" ] && command -v jq >/dev/null 2>&1; then
    jq -c --arg name "$profile_name" '
      .agentReportSay.summarizer.profiles[$name] // empty
    ' "$config_file" 2>/dev/null
  fi
}

agent_utils_jq_walk_strings() {
  cat <<'JQ'
def walk(f):
  . as $in
  | if type == "object" then
      reduce keys_unsorted[] as $key
        ({}; . + { ($key): ($in[$key] | walk(f)) }) | f
    elif type == "array" then
      map(walk(f)) | f
    else
      f
    end;
walk(if type == "string" then gsub("\\{prompt\\}"; $prompt) else . end)
JQ
}

agent_utils_run_command_summarizer() {
  local profile_json="$1"
  local prompt="$2"
  local inherited_timeout="${3:-}"
  local command_name timeout_seconds arg
  local -a args

  command_name="$(jq -r '.command // empty' <<<"$profile_json" 2>/dev/null)"
  [ -n "$command_name" ] || return 1
  command -v "$command_name" >/dev/null 2>&1 || return 1

  timeout_seconds="$(jq -r --arg inherited "$inherited_timeout" '.timeoutSeconds // ($inherited | select(. != "") | tonumber) // 25 | floor' <<<"$profile_json" 2>/dev/null)"
  [ -n "$timeout_seconds" ] || timeout_seconds=25

  args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(jq -j --arg prompt "$prompt" '.args[]? | gsub("\\{prompt\\}"; $prompt), "\u0000"' <<<"$profile_json" 2>/dev/null)

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" "$command_name" "${args[@]}" 2>/dev/null
  else
    "$command_name" "${args[@]}" 2>/dev/null
  fi
}

agent_utils_run_http_json_summarizer() {
  local profile_json="$1"
  local prompt="$2"
  local url method timeout_seconds output_filter body response header
  local -a curl_args

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  url="$(jq -r '.url // empty' <<<"$profile_json" 2>/dev/null)"
  [ -n "$url" ] || return 1
  method="$(jq -r '.method // "POST"' <<<"$profile_json" 2>/dev/null)"
  timeout_seconds="$(jq -r '.timeoutSeconds // 25 | floor' <<<"$profile_json" 2>/dev/null)"
  [ -n "$timeout_seconds" ] || timeout_seconds=25
  output_filter="$(jq -r '.output // ".response"' <<<"$profile_json" 2>/dev/null)"
  [ -n "$output_filter" ] || output_filter=".response"
  body="$(jq -c --arg prompt "$prompt" "$(agent_utils_jq_walk_strings)" <<<"$(jq -c '.body // {}' <<<"$profile_json" 2>/dev/null)" 2>/dev/null)"
  [ -n "$body" ] || body='{}'

  curl_args=(-fsS --max-time "$timeout_seconds" -X "$method" -H "Content-Type: application/json")
  while IFS= read -r -d '' header; do
    curl_args+=(-H "$header")
  done < <(jq -j '.headers // {} | to_entries[]? | "\(.key): \(.value)\u0000"' <<<"$profile_json" 2>/dev/null)

  response="$(curl "${curl_args[@]}" --data "$body" "$url" 2>/dev/null)" || return 1
  jq -r "$output_filter // empty" <<<"$response" 2>/dev/null
}

agent_utils_generate_summary() {
  local current_tool="$1"
  local prompt="$2"
  local raw_text="$3"
  local profile_name profile_json profile_type subprofile inherited_timeout

  profile_name="$(agent_utils_report_summarizer_name "$current_tool")"
  profile_json="$(agent_utils_report_summarizer_profile "$profile_name")"
  [ -n "$profile_json" ] || profile_json='{"type":"none"}'

  profile_type="$(jq -r '.type // "none"' <<<"$profile_json" 2>/dev/null)"
  case "$profile_type" in
    none)
      printf '%s' "$raw_text"
      ;;
    command)
      agent_utils_run_command_summarizer "$profile_json" "$prompt"
      ;;
    commandByTool)
      subprofile="$(jq -c --arg tool "$current_tool" '.commands[$tool] // empty' <<<"$profile_json" 2>/dev/null)"
      [ -n "$subprofile" ] || return 1
      inherited_timeout="$(jq -r '.timeoutSeconds // empty' <<<"$profile_json" 2>/dev/null)"
      agent_utils_run_command_summarizer "$subprofile" "$prompt" "$inherited_timeout"
      ;;
    httpJson)
      agent_utils_run_http_json_summarizer "$profile_json" "$prompt"
      ;;
    *)
      return 1
      ;;
  esac
}

[ "$ENABLE_HOOKS" = "true" ] || exit 0
[ "$ENABLE_REPORT" = "say" ] || exit 0

message=""
if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
  transcript_path="$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$payload" 2>/dev/null)"

  if [ "$tool" = "codex" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    message="$(extract_codex_transcript_message "$transcript_path")"
  fi

  if [ -z "$message" ]; then
    message="$(jq -r '.last_assistant_message // .last_agent_message // empty' <<<"$payload" 2>/dev/null)"
  fi

  if [ -z "$message" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    message="$(extract_generic_transcript_message "$transcript_path")"
  fi
fi

fallback="${tool} の作業が完了しました。"
[ "$outcome" = "gaveup" ] && fallback="${tool} の作業が終了しました。テストは失敗したままです。"

if [ -z "$message" ]; then
  speak_report_text "$fallback"
  exit 0
fi

raw="$(printf '%s' "$message" | tr '\n\r' '  ' | cut -c1-200)"

# Recursive invocation from our own summarizer command/API below
# (it may fire this same Stop hook via the user's agent settings) -
# stay silent, the outer call already speaks the summary.
[ "${AGENT_REPORT_SUMMARIZING:-}" = "1" ] && exit 0

if [ "$(agent_utils_report_summarizer_name "$tool")" = "none" ]; then
  speak_report_text "$raw"
  exit 0
fi

cursor_latest_file=""
cursor_request_id=""
if [ "$tool" = "cursor" ] && declare -f agent_utils_cursor_begin_request >/dev/null 2>&1; then
  cursor_request_info="$(agent_utils_cursor_begin_request "$tool" "$payload" 2>/dev/null || true)"
  if [ -n "$cursor_request_info" ]; then
    cursor_latest_file="$(printf '%s\n' "$cursor_request_info" | sed -n '1p')"
    cursor_request_id="$(printf '%s\n' "$cursor_request_info" | sed -n '2p')"
  fi
fi

(
  export AGENT_REPORT_SUMMARIZING=1
  prompt="次のエージェント出力を、音声で聞いてすぐ理解できる自然な日本語1〜2文に要約してください。ファイルパス・変数名・関数名・テーブル名・コードスニペットなどの技術的な固有名詞は具体名を出さず、意味だけを自然な言葉で言い換えてください。要約文以外は出力しないでください。

---
${message}"

  summary="$(agent_utils_generate_summary "$tool" "$prompt" "$raw" 2>/dev/null)"
  summary="$(printf '%s' "$summary" | tr '\n\r' '  ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-200)"

  [ -z "$summary" ] && summary="$raw"
  if [ -n "$cursor_request_id" ] && declare -f agent_utils_say_request_is_latest >/dev/null 2>&1; then
    agent_utils_say_request_is_latest "$cursor_latest_file" "$cursor_request_id" || exit 0
  fi
  speak_report_text "$summary"
) &
disown 2>/dev/null || true

exit 0
