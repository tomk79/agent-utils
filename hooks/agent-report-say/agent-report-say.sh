#!/usr/bin/env bash
# User-level (global) port of the project's agent-report-say.sh hook.
# Speaks a short summary of the finished turn via macOS `say`, gated by the
# hardcoded ENABLE_HOOKS/ENABLE_REPORT flags below (global, not per-repo, no
# .env file). Reads the original hook JSON payload on stdin and
# tries, in order: Codex's final answer in the transcript, hook-provided
# assistant message fields, then the last assistant text block in the transcript
# the payload points to, then falls back to a generic message.
# The raw text is rewritten into a short spoken-friendly Japanese sentence by
# a backgrounded `claude -p` call (file paths/identifiers/etc. dropped) so the
# hook itself returns immediately; falls back to the raw (truncated) text if
# that call fails, times out, or is unavailable.
# AGENT_REPORT_SUMMARIZING guards against the summarizer's own `claude -p`
# call re-triggering this same Stop hook recursively.
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
  if [ "$tool" = "cursor" ] && declare -f agent_utils_cursor_speak >/dev/null 2>&1; then
    AGENT_UTILS_CURSOR_KILL_WEAK=1
    if agent_utils_cursor_speak "$tool" "$payload" 2.5 30 "$fallback" \
      sound /System/Library/Sounds/Glass.aiff \
      say "報告します。" \
      say "$fallback" \
      say "以上です。" \
      sound /System/Library/Sounds/Bottle.aiff; then
      exit 0
    fi
    unset AGENT_UTILS_CURSOR_KILL_WEAK
  fi
  speak "$fallback"
  exit 0
fi

raw="$(printf '%s' "$message" | tr '\n\r' '  ' | cut -c1-200)"

# Recursive invocation from our own summarizer's `claude -p` call below
# (it fires this same Stop hook via the user's Claude Code settings) -
# stay silent, the outer call already speaks the summary.
[ "${AGENT_REPORT_SUMMARIZING:-}" = "1" ] && exit 0

if ! command -v claude >/dev/null 2>&1; then
  if [ "$tool" = "cursor" ] && declare -f agent_utils_cursor_speak >/dev/null 2>&1; then
    AGENT_UTILS_CURSOR_KILL_WEAK=1
    if agent_utils_cursor_speak "$tool" "$payload" 2.5 30 "$raw" \
      sound /System/Library/Sounds/Glass.aiff \
      say "報告します。" \
      say "$raw" \
      say "以上です。" \
      sound /System/Library/Sounds/Bottle.aiff; then
      exit 0
    fi
    unset AGENT_UTILS_CURSOR_KILL_WEAK
  fi
  speak "$raw"
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

  if command -v timeout >/dev/null 2>&1; then
    summary="$(timeout 25 claude -p "$prompt" --model haiku 2>/dev/null)"
  else
    summary="$(claude -p "$prompt" --model haiku 2>/dev/null)"
  fi
  summary="$(printf '%s' "$summary" | tr '\n\r' '  ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-200)"

  [ -z "$summary" ] && summary="$raw"
  if [ -n "$cursor_request_id" ] && declare -f agent_utils_say_request_is_latest >/dev/null 2>&1; then
    agent_utils_say_request_is_latest "$cursor_latest_file" "$cursor_request_id" || exit 0
  fi
  if [ "$tool" = "cursor" ] && declare -f agent_utils_cursor_speak >/dev/null 2>&1; then
    AGENT_UTILS_CURSOR_KILL_WEAK=1
    if agent_utils_cursor_speak "$tool" "$payload" 2.5 30 "$summary" \
      sound /System/Library/Sounds/Glass.aiff \
      say "報告します。" \
      say "$summary" \
      say "以上です。" \
      sound /System/Library/Sounds/Bottle.aiff; then
      exit 0
    fi
    unset AGENT_UTILS_CURSOR_KILL_WEAK
  fi
  speak "$summary"
) &
disown 2>/dev/null || true

exit 0
