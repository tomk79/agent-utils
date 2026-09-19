#!/usr/bin/env bash
# User-level (global) port of the project's agent-notification-say.sh hook.
# Speaks a short Japanese heads-up via macOS `say` when Claude Code is paused
# waiting on a tool-permission approval (Notification hook, matcher:
# "permission_prompt"). Gated by the hardcoded ENABLE_HOOKS/ENABLE_REPORT
# flags below (global, not per-repo, no .env file), same as
# agent-report-say.sh. Reads the Notification hook JSON payload on stdin and
# speaks its `message` field as-is (no LLM summarization - these messages are
# already short, e.g. `Ready to execute: Bash "npm test"`).
# Stays silent for Codex voice conversation (GPT-Live / realtime) turns, whose
# reply the voice model already speaks.
# Always exits 0 - cosmetic only, must never delay or block the permission
# prompt itself.
set -uo pipefail

ENABLE_HOOKS=true
ENABLE_REPORT=say

tool="${1:?tool name required (claude, codex, cursor, copilot, opencode)}"

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
  play_sound /System/Library/Sounds/Sosumi.aiff
  say "確認をお願いします。"
  say "$1" >/dev/null 2>&1
  play_sound /System/Library/Sounds/Bottle.aiff
}

speak_cursor() {
  play_sound /System/Library/Sounds/Sosumi.aiff
  say "ツールを実行します。"
  say "$1" >/dev/null 2>&1
  play_sound /System/Library/Sounds/Bottle.aiff
}

[ "$ENABLE_HOOKS" = "true" ] || exit 0
[ "$ENABLE_REPORT" = "say" ] || exit 0

# Codex voice conversation turn: the voice model already speaks the reply.
if [ "$tool" = "codex" ] && declare -f agent_utils_codex_is_voice_turn >/dev/null 2>&1 \
  && agent_utils_codex_is_voice_turn "$payload"; then
  exit 0
fi

message=""
if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
  message="$(jq -r '.message // empty' <<<"$payload" 2>/dev/null)"
fi

if [ -z "$message" ]; then
  if [ "$tool" = "cursor" ]; then
    message="${tool} がツールを実行します。"
  else
    message="${tool} がツールの実行許可を求めています。"
  fi
fi

raw="$(printf '%s' "$message" | tr '\n\r' '  ' | cut -c1-1000)"

if [ "$tool" = "cursor" ]; then
  raw="$(printf '%s' "$raw" | sed 's/ツールの実行許可を求めています/ツールを実行します/g; s/実行許可を求めています/ツールを実行します/g; s/確認をお願いします/ツールを実行します/g')"
  if declare -f agent_utils_cursor_speak >/dev/null 2>&1; then
    if agent_utils_cursor_speak "$tool" "$payload" 0.5 0 "$raw" \
      sound /System/Library/Sounds/Sosumi.aiff \
      say "ツールを実行します。" \
      say "$raw" \
      sound /System/Library/Sounds/Bottle.aiff; then
      exit 0
    fi
  fi
  speak_cursor "$raw" &
  disown 2>/dev/null || true
  exit 0
fi

speak "$raw" &
disown 2>/dev/null || true

exit 0
