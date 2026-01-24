#!/bin/bash

CONFIG_DIR="$HOME/.ghsync"
CONFIG_FILE="$CONFIG_DIR/config"
REPO_PATH="$CONFIG_DIR/repo"
MANIFEST_FILE="manifest.json"

ensure_config_dir() {
  mkdir -p "$CONFIG_DIR"
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 1
  fi
  source "$CONFIG_FILE"
  return 0
}

save_config() {
  local repo_url="$1"
  local token="$2"
  ensure_config_dir
  cat > "$CONFIG_FILE" << EOF
REPO_URL="$repo_url"
GH_TOKEN="$token"
EOF
}

load_manifest() {
  local manifest_path="$REPO_PATH/$MANIFEST_FILE"
  if [[ ! -f "$manifest_path" ]]; then
    echo "{}"
    return
  fi
  cat "$manifest_path"
}

save_manifest() {
  local manifest_path="$REPO_PATH/$MANIFEST_FILE"
  echo "$1" > "$manifest_path"
}

add_to_manifest() {
  local repo_relative_path="$1"
  local manifest=$(load_manifest)
  
  if command -v jq &> /dev/null; then
    manifest=$(echo "$manifest" | jq --arg path "$repo_relative_path" '. + {($path): $path}')
  else
    manifest=$(echo "$manifest" | sed "s/}$/,\"$repo_relative_path\":\"$repo_relative_path\"}/")
    if [[ "$manifest" == "{}" ]]; then
      manifest="{\"$repo_relative_path\":\"$repo_relative_path\"}"
    fi
  fi
  
  save_manifest "$manifest"
}

cmd_init() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: ghsync init <repo-url> <github-token>"
    exit 1
  fi
  
  local repo_url="$1"
  local token="$2"
  
  ensure_config_dir
  
  if [[ -d "$REPO_PATH" ]]; then
    rm -rf "$REPO_PATH"
  fi
  
  local auth_url="${repo_url/https:\/\//https:\/\/$token@}"
  
  if ! git clone "$auth_url" "$REPO_PATH" 2>/dev/null; then
    echo "Error: Failed to clone repository"
    exit 1
  fi
  
  save_config "$repo_url" "$token"
  echo "Repository initialized"
}

cmd_save() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: ghsync save <file-path>"
    exit 1
  fi
  
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  local file_path="$1"
  file_path="${file_path/#\~/$HOME}"
  file_path=$(realpath "$file_path" 2>/dev/null || echo "$file_path")
  
  if [[ ! -f "$file_path" ]]; then
    echo "File not found: $file_path"
    exit 1
  fi
  
  cd "$REPO_PATH" && git pull -q
  
  local repo_relative_path="${file_path/#$HOME/\~}"
  local repo_file_path="$REPO_PATH/$repo_relative_path"
  
  mkdir -p "$(dirname "$repo_file_path")"
  cp "$file_path" "$repo_file_path"
  
  add_to_manifest "$repo_relative_path"
  
  cd "$REPO_PATH"
  git add .
  git commit -m "Save $repo_relative_path from $(hostname)" -q
  git push -q
  
  if [[ -L "$file_path" ]]; then
    echo "Already symlinked: $repo_relative_path"
  else
    rm "$file_path"
    ln -s "$repo_file_path" "$file_path"
    echo "Saved and symlinked: $repo_relative_path"
  fi
}

cmd_sync() {
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  cd "$REPO_PATH" && git pull -q
  echo "Synced with remote"
}

cmd_restore() {
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  cd "$REPO_PATH" && git pull -q
  
  local manifest=$(load_manifest)
  
  if command -v jq &> /dev/null; then
    echo "$manifest" | jq -r 'keys[]' | while read -r repo_relative_path; do
      restore_file "$repo_relative_path"
    done
  else
    echo "$manifest" | grep -o '"[^"]*"' | sed 's/"//g' | while read -r repo_relative_path; do
      if [[ "$repo_relative_path" != "$repo_relative_path" ]]; then
        restore_file "$repo_relative_path"
      fi
    done
  fi
}

restore_file() {
  local repo_relative_path="$1"
  local target_path="${repo_relative_path/#\~/$HOME}"
  local repo_file_path="$REPO_PATH/$repo_relative_path"
  
  if [[ ! -f "$repo_file_path" ]]; then
    echo "Skipping missing: $repo_relative_path"
    return
  fi
  
  mkdir -p "$(dirname "$target_path")"
  
  if [[ -e "$target_path" ]]; then
    if [[ -L "$target_path" ]]; then
      echo "Already linked: $repo_relative_path"
      return
    fi
    echo "File exists, skipping: $repo_relative_path"
    return
  fi
  
  ln -s "$repo_file_path" "$target_path"
  echo "Restored: $repo_relative_path"
}

cmd_list() {
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  local manifest=$(load_manifest)
  
  echo "Tracked files:"
  if command -v jq &> /dev/null; then
    echo "$manifest" | jq -r 'keys[]' | sed 's/^/  /'
  else
    echo "$manifest" | grep -o '"[^"]*"' | sed 's/"//g;s/^/  /'
  fi
}

case "$1" in
  init)
    shift
    cmd_init "$@"
    ;;
  save)
    shift
    cmd_save "$@"
    ;;
  sync)
    cmd_sync
    ;;
  restore)
    cmd_restore
    ;;
  list)
    cmd_list
    ;;
  *)
    echo "GitHub File Sync with Symlinks"
    echo ""
    echo "Commands:"
    echo "  init <repo-url> <token>  Initialize with a GitHub repo"
    echo "  save <file-path>         Save file to repo and create symlink"
    echo "  sync                     Pull updates from remote"
    echo "  restore                  Restore all files from repo (new machine)"
    echo "  list                     List tracked files"
    ;;
esac
