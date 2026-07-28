#!/usr/bin/env bash
# Shared helpers for install.sh / uninstall.sh.
# Discovers feature directories (category/<feature>/meta.json), evaluates
# per-agent integration files (category/<feature>/integrations/<agent>.json),
# and manages the resulting symlink + settings.json state idempotently.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

expand_tilde() {
  local path="$1"
  printf '%s' "${path/#\~/$HOME}"
}

discover_features() {
  find "$REPO_ROOT" -mindepth 3 -maxdepth 3 -name meta.json | while read -r meta; do
    dirname "$meta"
  done
}

feature_script() {
  local feature_dir="$1"
  printf '%s/%s.sh' "$feature_dir" "$(basename "$feature_dir")"
}

list_integrations() {
  local feature_dir="$1"
  [ -d "$feature_dir/integrations" ] || return 0
  find "$feature_dir/integrations" -maxdepth 1 -name '*.json' | sort
}

integration_agent_name() {
  basename "$1" .json
}

# Normalizes integrations/<agent>.json's `.settings` (a single object or an
# array of objects) into one compact JSON object per line.
list_settings_entries() {
  local integration_json="$1"
  jq -c 'if (.settings | type) == "array" then .settings[] else .settings end' "$integration_json"
}

agent_detected() {
  local integration_json="$1"
  local config_dir command_name
  config_dir="$(jq -r '.detect.configDir // empty' "$integration_json")"
  command_name="$(jq -r '.detect.command // empty' "$integration_json")"

  if [ -n "$config_dir" ] && [ -d "$(expand_tilde "$config_dir")" ]; then
    return 0
  fi
  if [ -n "$command_name" ] && command -v "$command_name" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Prints "true" or "false"
is_installed() {
  local feature_dir="$1" integration_json="$2"
  local script link_dir_raw link_dir target
  local settings_file event entry

  script="$(feature_script "$feature_dir")"
  link_dir_raw="$(jq -r '.link.dir' "$integration_json")"
  link_dir="$(expand_tilde "$link_dir_raw")"
  target="$link_dir/$(basename "$script")"

  local symlink_ok=false
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$script" ]; then
    symlink_ok=true
  fi

  local settings_ok=true
  while IFS= read -r settings_entry; do
    [ -n "$settings_entry" ] || continue
    settings_file="$(expand_tilde "$(jq -r '.file' <<<"$settings_entry")")"
    event="$(jq -r '.event' <<<"$settings_entry")"
    entry="$(jq -c '.entry' <<<"$settings_entry")"

    if [ -f "$settings_file" ] && jq -e --arg event "$event" --argjson entry "$entry" \
      '(.hooks[$event] // []) | any(. == $entry)' "$settings_file" >/dev/null 2>&1; then
      : # this entry is present
    else
      settings_ok=false
    fi
  done < <(list_settings_entries "$integration_json")

  if [ "$symlink_ok" = true ] && [ "$settings_ok" = true ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# Ensures link.dir is a real directory, migrating away from a stale
# whole-directory symlink into this same repo if one is found.
prepare_link_dir() {
  local link_dir="$1"
  if [ -L "$link_dir" ]; then
    local resolved
    resolved="$(readlink "$link_dir")"
    case "$resolved" in
      "$REPO_ROOT"/*)
        rm "$link_dir"
        ;;
    esac
  fi
  mkdir -p "$link_dir"
}

settings_merge() {
  local file="$1" event="$2" entry="$3" base_fields="${4:-{\}}"
  local dir tmp content
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  content='{}'
  [ -f "$file" ] && content="$(cat "$file")"
  tmp="$(mktemp "$dir/.settings.XXXXXX")"
  printf '%s' "$content" | jq --arg event "$event" --argjson entry "$entry" --argjson base "$base_fields" '
    reduce ($base | to_entries[]) as $kv (.; if has($kv.key) then . else .[$kv.key] = $kv.value end) |
    .hooks = (.hooks // {}) |
    .hooks[$event] = (.hooks[$event] // []) |
    if (.hooks[$event] | any(. == $entry))
    then .
    else .hooks[$event] += [$entry]
    end
  ' > "$tmp"
  mv "$tmp" "$file"
}

settings_remove() {
  local file="$1" event="$2" entry="$3"
  [ -f "$file" ] || return 0
  local dir tmp
  dir="$(dirname "$file")"
  tmp="$(mktemp "$dir/.settings.XXXXXX")"
  jq --arg event "$event" --argjson entry "$entry" '
    .hooks[$event] = ((.hooks[$event] // []) | map(select(. != $entry)))
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}
