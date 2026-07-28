#!/usr/bin/env bash
# User-level (global) port of the project's agent-notification-say.sh hook.
# Speaks a short Japanese heads-up via macOS `say` when Claude Code is paused
# waiting on a tool-permission approval (Notification hook, matcher:
# "permission_prompt"). Gated by the hardcoded ENABLE_HOOKS/ENABLE_REPORT
# flags below (global, not per-repo, no .env file), same as
# agent-report-say.sh. Reads the Notification hook JSON payload on stdin and
# speaks its `message` field as-is (no LLM summarization - these messages are
# already short, e.g. `Ready to execute: Bash "npm test"`).
# Always exits 0 - cosmetic only, must never delay or block the permission
# prompt itself.
set -uo pipefail

ENABLE_HOOKS=true
ENABLE_REPORT=say

tool="${1:?tool name required (claude, codex, cursor, copilot, opencode)}"

payload="$(cat 2>/dev/null || true)"

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

[ "$ENABLE_HOOKS" = "true" ] || exit 0
[ "$ENABLE_REPORT" = "say" ] || exit 0

message=""
if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
  message="$(jq -r '.message // empty' <<<"$payload" 2>/dev/null)"
fi

[ -z "$message" ] && message="${tool} がツールの実行許可を求めています。"

raw="$(printf '%s' "$message" | tr '\n\r' '  ' | cut -c1-200)"

speak "$raw" &
disown 2>/dev/null || true

exit 0
