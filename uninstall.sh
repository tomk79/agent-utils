#!/usr/bin/env bash
# Removes agent-utils features previously installed by install.sh: deletes
# the symlink and removes the matching settings.json fragment.
#
# Usage:
#   ./uninstall.sh              interactive selection menu (installed only)
#   ./uninstall.sh --all        uninstall every currently-installed pair
#   ./uninstall.sh <feature>... uninstall only the named feature(s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "エラー: jq が必要です。'brew install jq' でインストールしてください。" >&2
  exit 1
fi

REMOVED_COUNT=0
SKIPPED_COUNT=0

uninstall_one() {
  local feature_dir="$1" integration_json="$2"
  local name agent script link_dir_raw link_dir target
  local settings_file event entry did_something=false

  name="$(jq -r '.name' "$feature_dir/meta.json")"
  agent="$(integration_agent_name "$integration_json")"
  script="$(feature_script "$feature_dir")"
  link_dir_raw="$(jq -r '.link.dir' "$integration_json")"
  link_dir="$(expand_tilde "$link_dir_raw")"
  target="$link_dir/$(basename "$script")"
  settings_file="$(expand_tilde "$(jq -r '.settings.file' "$integration_json")")"
  event="$(jq -r '.settings.event' "$integration_json")"
  entry="$(jq -c '.settings.entry' "$integration_json")"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$script" ]; then
    rm "$target"
    did_something=true
  elif [ -e "$target" ] || [ -L "$target" ]; then
    echo "⚠ skip: $name ($agent) - $target はこのリポジトリの管理下ではないため残します" >&2
  fi

  if [ -f "$settings_file" ] && jq -e --arg event "$event" --argjson entry "$entry" \
    '(.hooks[$event] // []) | any(. == $entry)' "$settings_file" >/dev/null 2>&1; then
    settings_remove "$settings_file" "$event" "$entry"
    did_something=true
  fi

  if [ "$did_something" = true ]; then
    echo "✓ uninstalled: $name ($agent)"
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
  else
    echo "- not installed, skip: $name ($agent)"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
  fi
}

# Build the candidate list: feature/agent pairs whose agent is detected here
# AND that are currently installed.
CANDIDATES=()
while IFS= read -r feature_dir; do
  [ -n "$feature_dir" ] || continue
  while IFS= read -r integ; do
    [ -n "$integ" ] || continue
    if agent_detected "$integ" && [ "$(is_installed "$feature_dir" "$integ")" = "true" ]; then
      CANDIDATES+=("$feature_dir::$integ")
    fi
  done < <(list_integrations "$feature_dir")
done < <(discover_features)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "アンインストール対象の機能は見つかりませんでした。"
  exit 0
fi

SELECTED=()

if [ "$#" -eq 0 ]; then
  echo "インストール済みの機能:"
  i=1
  for c in "${CANDIDATES[@]}"; do
    feature_dir="${c%%::*}"
    integ="${c##*::}"
    name="$(jq -r '.name' "$feature_dir/meta.json")"
    desc="$(jq -r '.description' "$feature_dir/meta.json")"
    agent="$(integration_agent_name "$integ")"
    printf '  %2d) %-28s (%s) - %s\n' "$i" "$name" "$agent" "$desc"
    i=$((i + 1))
  done
  echo
  read -r -p "アンインストールする番号をスペース区切りで入力 ('all'で全選択, 空Enterで中止): " selection
  [ -n "$selection" ] || { echo "中止しました。"; exit 0; }
  if [ "$selection" = "all" ]; then
    SELECTED=("${CANDIDATES[@]}")
  else
    for token in $selection; do
      idx=$((token - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#CANDIDATES[@]}" ]; then
        SELECTED+=("${CANDIDATES[$idx]}")
      else
        echo "無効な番号です: $token" >&2
        exit 1
      fi
    done
  fi
elif [ "$1" = "--all" ]; then
  SELECTED=("${CANDIDATES[@]}")
else
  for feature_name in "$@"; do
    found=false
    for c in "${CANDIDATES[@]}"; do
      feature_dir="${c%%::*}"
      if [ "$(basename "$feature_dir")" = "$feature_name" ]; then
        SELECTED+=("$c")
        found=true
      fi
    done
    if [ "$found" = false ]; then
      echo "不明な機能名、またはインストールされていません: $feature_name" >&2
      exit 1
    fi
  done
fi

for c in "${SELECTED[@]}"; do
  feature_dir="${c%%::*}"
  integ="${c##*::}"
  uninstall_one "$feature_dir" "$integ"
done

echo
echo "完了: $REMOVED_COUNT 件アンインストール, $SKIPPED_COUNT 件スキップ"
