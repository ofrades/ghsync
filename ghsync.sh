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

remove_from_manifest() {
  local repo_relative_path="$1"
  local manifest=$(load_manifest)
  
  if command -v jq &> /dev/null; then
    manifest=$(echo "$manifest" | jq --arg path "$repo_relative_path" 'del(.[$path])')
  else
    # Simple sed-based removal (not perfect but works for basic cases)
    manifest=$(echo "$manifest" | sed "s/\"$repo_relative_path\":\"$repo_relative_path\",\?//g" | sed 's/,}/}/g')
  fi
  
  save_manifest "$manifest"
}

cmd_init() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: ghsync init <repo-url> [github-token]"
    echo ""
    echo "Examples:"
    echo "  ghsync init git@github.com:user/dotfiles.git"
    echo "  ghsync init https://github.com/user/dotfiles TOKEN"
    exit 1
  fi
  
  local repo_url="$1"
  local token="${2:-}"
  
  ensure_config_dir
  
  if [[ -d "$REPO_PATH" ]]; then
    rm -rf "$REPO_PATH"
  fi
  
  local clone_url="$repo_url"
  
  # Handle different URL formats
  if [[ "$repo_url" == git@* ]]; then
    # SSH URL (git@github.com:user/repo.git) - no token needed
    clone_url="$repo_url"
  elif [[ "$repo_url" == https://* ]] && [[ -n "$token" ]]; then
    # HTTPS with token
    clone_url="${repo_url/https:\/\//https:\/\/$token@}"
  fi
  
  if ! git clone "$clone_url" "$REPO_PATH" 2>/dev/null; then
    echo "Error: Failed to clone repository"
    exit 1
  fi
  
  save_config "$repo_url" "$token"
  echo "Repository initialized"
  
  # Restore symlinks for all tracked items
  do_restore
}

cmd_save() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: ghsync save <path>"
    exit 1
  fi
  
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  local file_path="$1"
  file_path="${file_path/#\~/$HOME}"
  # Remove trailing slash for directories
  file_path="${file_path%/}"
  
  # Normalize path without resolving symlinks (keep logical path)
  # Use realpath -s if available, otherwise use pwd -L approach
  if realpath -s / &>/dev/null; then
    file_path=$(realpath -s "$file_path" 2>/dev/null || echo "$file_path")
  else
    # Fallback: cd to dir and use pwd -L to get logical path
    local dir=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -L)
    file_path="$dir/$(basename "$file_path")"
  fi
  
  if [[ ! -e "$file_path" ]]; then
    echo "Not found: $file_path"
    exit 1
  fi
  
  cd "$REPO_PATH" && git pull -q
  
  local repo_relative_path="${file_path/#$HOME/\~}"
  local repo_file_path="$REPO_PATH/$repo_relative_path"
  
  # Handle directories
  if [[ -d "$file_path" ]] && [[ ! -L "$file_path" ]]; then
    mkdir -p "$(dirname "$repo_file_path")"
    # Copy directory contents (follow symlinks)
    cp -rL "$file_path" "$repo_file_path"
    
    add_to_manifest "$repo_relative_path"
    
    cd "$REPO_PATH"
    git add .
    git commit -m "Save $repo_relative_path from $(hostname)" -q 2>/dev/null || true
    
    # Remove original directory and create symlink
    rm -rf "$file_path"
    ln -s "$repo_file_path" "$file_path"
    echo "Saved and symlinked: $repo_relative_path/ (run 'ghsync sync' to push)"
    return
  fi
  
  # Handle files
  mkdir -p "$(dirname "$repo_file_path")"
  
  # Copy the actual file content (follow symlinks for cp)
  cp -L "$file_path" "$repo_file_path"
  
  add_to_manifest "$repo_relative_path"
  
  cd "$REPO_PATH"
  git add .
  git commit -m "Save $repo_relative_path from $(hostname)" -q 2>/dev/null || true
  
  # Check if already a symlink pointing to our repo
  if [[ -L "$file_path" ]]; then
    local link_target=$(readlink "$file_path")
    if [[ "$link_target" == "$repo_file_path" ]] || [[ "$link_target" == *".ghsync/repo/"* ]]; then
      echo "Already symlinked: $repo_relative_path"
      return
    fi
  fi
  
  # Remove original and create symlink
  rm -f "$file_path"
  ln -s "$repo_file_path" "$file_path"
  echo "Saved and symlinked: $repo_relative_path (run 'ghsync sync' to push)"
}

cmd_sync() {
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  cd "$REPO_PATH"
  
  # Check for local changes
  local has_changes=false
  if [[ -n $(git status --porcelain) ]]; then
    has_changes=true
  fi
  
  # Check if ahead of remote
  git fetch -q 2>/dev/null || true
  local ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
  local behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
  
  # Pull first (rebase to keep local commits on top)
  if [[ "$behind" -gt 0 ]]; then
    git pull --rebase -q
    echo "Pulled $behind commit(s) from remote"
    # Restore any new symlinks
    do_restore
  fi
  
  # Push if we have commits ahead
  if [[ "$ahead" -gt 0 ]]; then
    git push -q
    echo "Pushed $ahead commit(s) to remote"
  fi
  
  if [[ "$ahead" -eq 0 ]] && [[ "$behind" -eq 0 ]]; then
    echo "Already up to date"
  fi
}

cmd_restore() {
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  cd "$REPO_PATH" && git pull -q
  do_restore
  echo "Restore complete"
}

restore_item() {
  local repo_relative_path="$1"
  local target_path="${repo_relative_path/#\~/$HOME}"
  local repo_file_path="$REPO_PATH/$repo_relative_path"
  
  if [[ ! -e "$repo_file_path" ]]; then
    return
  fi
  
  mkdir -p "$(dirname "$target_path")"
  
  if [[ -e "$target_path" ]]; then
    if [[ -L "$target_path" ]]; then
      # Already a symlink, skip silently
      return
    fi
    # Exists but not a symlink, skip
    return
  fi
  
  ln -s "$repo_file_path" "$target_path"
  echo "Restored: $repo_relative_path"
}

do_restore() {
  local manifest=$(load_manifest)
  
  if command -v jq &> /dev/null; then
    echo "$manifest" | jq -r 'keys[]' | while read -r repo_relative_path; do
      restore_item "$repo_relative_path"
    done
  else
    echo "$manifest" | grep -o '"[^"]*"' | sed 's/"//g' | while read -r repo_relative_path; do
      restore_item "$repo_relative_path"
    done
  fi
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

cmd_remove() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: ghsync remove <path>"
    exit 1
  fi
  
  if ! load_config; then
    echo "Not initialized. Run: ghsync init <repo-url> <token>"
    exit 1
  fi
  
  local file_path="$1"
  file_path="${file_path/#\~/$HOME}"
  # Remove trailing slash for directories
  file_path="${file_path%/}"
  
  # Normalize path without resolving symlinks
  if realpath -s / &>/dev/null; then
    file_path=$(realpath -s "$file_path" 2>/dev/null || echo "$file_path")
  else
    local dir=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -L)
    file_path="$dir/$(basename "$file_path")"
  fi
  
  local repo_relative_path="${file_path/#$HOME/\~}"
  local repo_file_path="$REPO_PATH/$repo_relative_path"
  
  # Check if file/directory exists in repo
  if [[ ! -e "$repo_file_path" ]]; then
    echo "Not tracked: $repo_relative_path"
    exit 1
  fi
  
  # Handle directories
  if [[ -d "$repo_file_path" ]]; then
    # Remove symlink and copy directory back
    rm -f "$file_path"
    cp -r "$repo_file_path" "$file_path"
    
    # Remove from repo
    rm -rf "$repo_file_path"
  else
    # Handle files
    rm -f "$file_path"
    cp "$repo_file_path" "$file_path"
    
    # Remove from repo
    rm -f "$repo_file_path"
  fi
  
  # Remove from manifest
  remove_from_manifest "$repo_relative_path"
  
  # Commit changes
  cd "$REPO_PATH"
  git add .
  git commit -m "Remove $repo_relative_path from $(hostname)" -q 2>/dev/null || true
  
  echo "Removed: $repo_relative_path (run 'ghsync sync' to push)"
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
  remove)
    shift
    cmd_remove "$@"
    ;;
  list)
    cmd_list
    ;;
  *)
    echo "GitHub File Sync with Symlinks"
    echo ""
    echo "Commands:"
    echo "  init <repo-url> [token]  Initialize and restore symlinks (token optional for SSH)"
    echo "  save <path>              Save file or directory to repo and create symlink"
    echo "  remove <path>            Stop tracking and restore original"
    echo "  sync                     Push/pull changes and restore new symlinks"
    echo "  restore                  Manually restore all symlinks"
    echo "  list                     List tracked files and directories"
    echo ""
    echo "Examples:"
    echo "  ghsync init git@github.com:user/dotfiles.git"
    echo "  ghsync save ~/.bashrc"
    echo "  ghsync save ~/.config/nvim"
    echo "  ghsync sync"
    ;;
esac
