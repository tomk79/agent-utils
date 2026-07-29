#!/usr/bin/env bash
# User-level (global) port of the project's agent-report-say.sh hook.
# Speaks a short summary of the finished turn via macOS `say`, gated by the
# hardcoded ENABLE_HOOKS/ENABLE_REPORT flags below (global, not per-repo, no
# .env file). Reads the original hook JSON payload on stdin and
# tries, in order: Codex's `last_assistant_message` field, then the last
# assistant text block in the transcript the payload points to, then falls
# back to a generic message. Assistant entries are matched on either
# `.type=="assistant"` (Claude Code's transcript schema) or `.role=="assistant"`
# (other tools' transcript schemas).
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

[ "$ENABLE_HOOKS" = "true" ] || exit 0
[ "$ENABLE_REPORT" = "say" ] || exit 0

message=""
if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
  message="$(jq -r '.last_assistant_message // empty' <<<"$payload" 2>/dev/null)"

  if [ -z "$message" ]; then
    transcript_path="$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$payload" 2>/dev/null)"
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
      message="$(tail -n 200 "$transcript_path" 2>/dev/null | jq -rs '
        [.[] | select(.type=="assistant" or .role=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // empty
      ' 2>/dev/null)"
    fi
  fi
fi

fallback="${tool} の作業が完了しました。"
[ "$outcome" = "gaveup" ] && fallback="${tool} の作業が終了しました。テストは失敗したままです。"

if [ -z "$message" ]; then
  speak "$fallback"
  exit 0
fi

raw="$(printf '%s' "$message" | tr '\n\r' '  ' | cut -c1-200)"

# Recursive invocation from our own summarizer's `claude -p` call below
# (it fires this same Stop hook via the user's Claude Code settings) -
# stay silent, the outer call already speaks the summary.
[ "${AGENT_REPORT_SUMMARIZING:-}" = "1" ] && exit 0

if ! command -v claude >/dev/null 2>&1; then
  speak "$raw"
  exit 0
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
  speak "$summary"
) &
disown 2>/dev/null || true

exit 0
