#!/usr/bin/env bash
# Installs agent-utils features (symlink into the agent's config dir +
# merge the matching settings fragment) for whichever agents are detected
# on this machine.
#
# Usage:
#   ./install.sh              interactive selection menu
#   ./install.sh --all        install every applicable feature/agent pair
#   ./install.sh <feature>... install only the named feature(s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "エラー: jq が必要です。'brew install jq' でインストールしてください。" >&2
  exit 1
fi

INSTALLED_COUNT=0
SKIPPED_COUNT=0
ALREADY_COUNT=0

install_one() {
  local feature_dir="$1" integration_json="$2"
  local name agent script link_dir_raw link_dir target
  local settings_file event entry

  name="$(jq -r '.name' "$feature_dir/meta.json")"
  agent="$(integration_agent_name "$integration_json")"
  script="$(feature_script "$feature_dir")"
  link_dir_raw="$(jq -r '.link.dir' "$integration_json")"
  link_dir="$(expand_tilde "$link_dir_raw")"
  target="$link_dir/$(basename "$script")"
  settings_file="$(expand_tilde "$(jq -r '.settings.file' "$integration_json")")"
  event="$(jq -r '.settings.event' "$integration_json")"
  entry="$(jq -c '.settings.entry' "$integration_json")"

  prepare_link_dir "$link_dir"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$script" ]; then
    : # already the correct symlink, nothing to do
  elif [ -e "$target" ] || [ -L "$target" ]; then
    echo "⚠ skip: $name ($agent) - $target が既に存在し、このリポジトリの管理下ではありません" >&2
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  else
    ln -s "$script" "$target"
  fi

  settings_merge "$settings_file" "$event" "$entry"
  echo "✓ installed: $name ($agent)"
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
}

# Build the candidate list: feature/agent pairs whose agent is detected here.
CANDIDATES=()
while IFS= read -r feature_dir; do
  [ -n "$feature_dir" ] || continue
  while IFS= read -r integ; do
    [ -n "$integ" ] || continue
    if agent_detected "$integ"; then
      CANDIDATES+=("$feature_dir::$integ")
    fi
  done < <(list_integrations "$feature_dir")
done < <(discover_features)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "このマシンで検出されたエージェント向けに、インストール可能な機能が見つかりませんでした。"
  exit 0
fi

SELECTED=()

if [ "$#" -eq 0 ]; then
  echo "インストール可能な機能:"
  i=1
  for c in "${CANDIDATES[@]}"; do
    feature_dir="${c%%::*}"
    integ="${c##*::}"
    name="$(jq -r '.name' "$feature_dir/meta.json")"
    desc="$(jq -r '.description' "$feature_dir/meta.json")"
    agent="$(integration_agent_name "$integ")"
    installed="$(is_installed "$feature_dir" "$integ")"
    mark="[ ]"
    [ "$installed" = "true" ] && mark="[installed]"
    printf '  %2d) %s %-28s (%s) - %s\n' "$i" "$mark" "$name" "$agent" "$desc"
    i=$((i + 1))
  done
  echo
  read -r -p "インストールする番号をスペース区切りで入力 ('all'で全選択, 空Enterで中止): " selection
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
      echo "不明な機能名、またはこのマシンでは対応エージェントが検出されませんでした: $feature_name" >&2
      exit 1
    fi
  done
fi

for c in "${SELECTED[@]}"; do
  feature_dir="${c%%::*}"
  integ="${c##*::}"
  install_one "$feature_dir" "$integ"
done

echo
echo "完了: $INSTALLED_COUNT 件インストール, $SKIPPED_COUNT 件スキップ"
