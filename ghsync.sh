#!/bin/bash

CONFIG_DIR="$HOME/.ghsync"
CONFIG_FILE="$CONFIG_DIR/config"
REPO_PATH="$CONFIG_DIR/repo"
MANIFEST_FILE="manifest.json"

ensure_config_dir() {
  mkdir -p "$CONFIG_DIR"
}

escape_config_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

detect_repo_subdir() {
  local manifest_path="$REPO_PATH/$MANIFEST_FILE"

  if [[ -d "$REPO_PATH/~" ]]; then
    printf '~\n'
    return
  fi

  if [[ -f "$manifest_path" ]]; then
    if command -v jq &> /dev/null; then
      if jq -e 'keys[] | select(startswith("~/"))' "$manifest_path" >/dev/null 2>&1; then
        printf '~\n'
        return
      fi
    elif grep -q '"~/[^\"]*"' "$manifest_path" 2>/dev/null; then
      printf '~\n'
      return
    fi
  fi

  printf '.\n'
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 1
  fi

  REPO_URL=$(sed -n 's/^REPO_URL="\([^"]*\)"$/\1/p' "$CONFIG_FILE")
  GH_TOKEN=$(sed -n 's/^GH_TOKEN="\([^"]*\)"$/\1/p' "$CONFIG_FILE")
  REPO_SUBDIR=$(sed -n 's/^REPO_SUBDIR="\([^"]*\)"$/\1/p' "$CONFIG_FILE")

  if [[ -z "$REPO_URL" ]]; then
    return 1
  fi

  if [[ -z "$REPO_SUBDIR" ]]; then
    REPO_SUBDIR=$(detect_repo_subdir)
  fi

  return 0
}

save_config() {
  local repo_url="$1"
  local token="$2"
  local repo_subdir="$3"
  ensure_config_dir
  cat > "$CONFIG_FILE" << EOF
REPO_URL="$(escape_config_value "$repo_url")"
GH_TOKEN="$(escape_config_value "$token")"
REPO_SUBDIR="$(escape_config_value "$repo_subdir")"
EOF
}

print_init_usage() {
  echo "Usage: ghsync init <repo-url> [github-token] [repo-subdir]"
  echo "       ghsync init <repo-url> --repo-subdir <repo-subdir> [github-token]"
  echo ""
  echo "repo-subdir is the directory inside the repo that maps to your home folder."
  echo "Default is '.' so files are stored directly in the repo root."
  echo "Use '~' only for legacy repos that already have a literal ~/ directory."
}

print_not_initialized() {
  echo "Not initialized. Run: ghsync init <repo-url> [github-token] [repo-subdir]"
}

normalize_repo_subdir() {
  local repo_subdir="${1:-.}"

  while [[ "$repo_subdir" == ./* ]]; do
    repo_subdir="${repo_subdir#./}"
  done
  repo_subdir="${repo_subdir%/}"

  if [[ -z "$repo_subdir" ]]; then
    repo_subdir="."
  fi

  if [[ "$repo_subdir" == "/"* ]]; then
    echo "Error: repo-subdir must be relative to the repo root" >&2
    return 1
  fi

  if [[ "$repo_subdir" == "." ]]; then
    echo "."
    return 0
  fi

  local old_ifs="$IFS"
  local parts=()
  IFS='/' read -r -a parts <<< "$repo_subdir"
  IFS="$old_ifs"

  local part
  for part in "${parts[@]}"; do
    if [[ -z "$part" || "$part" == "." || "$part" == ".." ]]; then
      echo "Error: invalid repo-subdir '$repo_subdir'" >&2
      return 1
    fi
  done

  echo "$repo_subdir"
}

home_path_to_repo_relative() {
  local file_path="$1"
  local repo_subdir="${REPO_SUBDIR:-.}"
  local home_relative_path

  if [[ "$file_path" == "$HOME" ]]; then
    echo "Error: refusing to track the home directory itself" >&2
    return 1
  fi

  if [[ "$file_path" != "$HOME/"* ]]; then
    echo "Error: only paths inside $HOME can be tracked: $file_path" >&2
    return 1
  fi

  home_relative_path="${file_path#$HOME/}"

  if [[ "$repo_subdir" == "." ]]; then
    printf '%s\n' "$home_relative_path"
  else
    printf '%s/%s\n' "$repo_subdir" "$home_relative_path"
  fi
}

repo_relative_to_home_relative() {
  local repo_relative_path="$1"
  local repo_subdir="${REPO_SUBDIR:-.}"

  if [[ "$repo_relative_path" == "~/"* ]]; then
    printf '%s\n' "${repo_relative_path#\~/}"
    return 0
  fi

  if [[ "$repo_subdir" == "." ]]; then
    printf '%s\n' "$repo_relative_path"
    return 0
  fi

  if [[ "$repo_relative_path" == "$repo_subdir/"* ]]; then
    printf '%s\n' "${repo_relative_path#"$repo_subdir/"}"
    return 0
  fi

  return 1
}

repo_relative_to_target_path() {
  local repo_relative_path="$1"
  local home_relative_path

  if ! home_relative_path=$(repo_relative_to_home_relative "$repo_relative_path"); then
    return 1
  fi

  printf '%s/%s\n' "$HOME" "$home_relative_path"
}

repo_relative_to_display_path() {
  local repo_relative_path="$1"
  local home_relative_path

  if ! home_relative_path=$(repo_relative_to_home_relative "$repo_relative_path"); then
    return 1
  fi

  printf '~/%s\n' "$home_relative_path"
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
  printf '%s\n' "$1" > "$manifest_path"
}

manifest_keys() {
  local manifest="$1"

  if command -v jq &> /dev/null; then
    echo "$manifest" | jq -r 'keys[]'
    return
  fi

  if command -v python3 &> /dev/null; then
    MANIFEST_JSON="$manifest" python3 - <<'PY'
import json
import os

manifest = os.environ.get("MANIFEST_JSON", "{}")
for key in json.loads(manifest).keys():
    print(key)
PY
    return
  fi

  echo "$manifest" | tr '{},' '\n' | sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*$/\1/p'
}

add_to_manifest() {
  local repo_relative_path="$1"
  local manifest
  manifest=$(load_manifest)

  if command -v jq &> /dev/null; then
    manifest=$(echo "$manifest" | jq -c --arg path "$repo_relative_path" '. + {($path): $path}')
  elif command -v python3 &> /dev/null; then
    manifest=$(MANIFEST_JSON="$manifest" python3 - "$repo_relative_path" <<'PY'
import json
import os
import sys

path = sys.argv[1]
manifest = json.loads(os.environ.get("MANIFEST_JSON", "{}"))
manifest[path] = path
print(json.dumps(manifest, sort_keys=True))
PY
)
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
  local manifest
  manifest=$(load_manifest)

  if command -v jq &> /dev/null; then
    manifest=$(echo "$manifest" | jq -c --arg path "$repo_relative_path" 'del(.[$path])')
  elif command -v python3 &> /dev/null; then
    manifest=$(MANIFEST_JSON="$manifest" python3 - "$repo_relative_path" <<'PY'
import json
import os
import sys

path = sys.argv[1]
manifest = json.loads(os.environ.get("MANIFEST_JSON", "{}"))
manifest.pop(path, None)
print(json.dumps(manifest, sort_keys=True))
PY
)
  else
    manifest=$(echo "$manifest" | sed "s/\"$repo_relative_path\":\"$repo_relative_path\",\?//g" | sed 's/,}/}/g')
  fi

  save_manifest "$manifest"
}

cmd_init() {
  if [[ $# -lt 1 ]]; then
    print_init_usage
    echo ""
    echo "Examples:"
    echo "  ghsync init git@github.com:user/dotfiles.git"
    echo "  ghsync init git@github.com:user/dotfiles.git dotfiles"
    echo "  ghsync init git@github.com:user/dotfiles.git --repo-subdir '~'"
    echo "  ghsync init https://github.com/user/dotfiles TOKEN --repo-subdir dotfiles"
    exit 1
  fi

  local repo_url="$1"
  shift
  local token=""
  local repo_subdir="."

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-subdir)
        if [[ $# -lt 2 ]]; then
          echo "Error: --repo-subdir requires a value"
          exit 1
        fi
        repo_subdir="$2"
        shift 2
        ;;
      --repo-subdir=*)
        repo_subdir="${1#*=}"
        shift
        ;;
      *)
        if [[ -z "$token" ]] && [[ $# -eq 1 ]] && [[ "$repo_url" != https://* ]]; then
          repo_subdir="$1"
        elif [[ -z "$token" ]]; then
          token="$1"
        elif [[ "$repo_subdir" == "." ]]; then
          repo_subdir="$1"
        else
          print_init_usage
          exit 1
        fi
        shift
        ;;
    esac
  done

  if ! repo_subdir=$(normalize_repo_subdir "$repo_subdir"); then
    exit 1
  fi

  ensure_config_dir

  local clone_url="$repo_url"
  local temp_repo_path="$CONFIG_DIR/repo.tmp.$$"
  local backup_repo_path="$CONFIG_DIR/repo.backup.$$"

  rm -rf "$temp_repo_path" "$backup_repo_path"

  # Handle different URL formats
  if [[ "$repo_url" == git@* ]]; then
    # SSH URL (git@github.com:user/repo.git) - no token needed
    clone_url="$repo_url"
  elif [[ "$repo_url" == https://* ]] && [[ -n "$token" ]]; then
    # HTTPS with token
    clone_url="${repo_url/https:\/\//https:\/\/$token@}"
  fi

  if ! git clone "$clone_url" "$temp_repo_path" 2>/dev/null; then
    rm -rf "$temp_repo_path"
    echo "Error: Failed to clone repository"
    exit 1
  fi

  if [[ -d "$REPO_PATH" ]]; then
    mv "$REPO_PATH" "$backup_repo_path"
  fi

  if ! mv "$temp_repo_path" "$REPO_PATH"; then
    rm -rf "$temp_repo_path"
    if [[ -d "$backup_repo_path" ]]; then
      mv "$backup_repo_path" "$REPO_PATH"
    fi
    echo "Error: Failed to activate cloned repository"
    exit 1
  fi

  rm -rf "$backup_repo_path"

  save_config "$repo_url" "$token" "$repo_subdir"
  echo "Repository initialized"
  echo "Repo subdir: $repo_subdir"

  # Restore symlinks for all tracked items
  do_restore
}

cmd_save() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: ghsync save <path>"
    exit 1
  fi

  if ! load_config; then
    print_not_initialized
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
    local dir
    dir=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -L)
    file_path="$dir/$(basename "$file_path")"
  fi

  if [[ ! -e "$file_path" ]]; then
    echo "Not found: $file_path"
    exit 1
  fi

  cd "$REPO_PATH" && git pull -q

  local repo_relative_path
  if ! repo_relative_path=$(home_path_to_repo_relative "$file_path"); then
    exit 1
  fi
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
    echo "Saved and symlinked: $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path")/ (run 'ghsync sync' to push)"
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
    local link_target
    link_target=$(readlink "$file_path")
    if [[ "$link_target" == "$repo_file_path" ]] || [[ "$link_target" == *".ghsync/repo/"* ]]; then
      echo "Already symlinked: $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path")"
      return
    fi
  fi

  # Remove original and create symlink
  rm -f "$file_path"
  ln -s "$repo_file_path" "$file_path"
  echo "Saved and symlinked: $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path") (run 'ghsync sync' to push)"
}

cmd_sync() {
  if ! load_config; then
    print_not_initialized
    exit 1
  fi

  cd "$REPO_PATH"

  # Auto-commit any local changes before syncing
  if [[ -n $(git status --porcelain) ]]; then
    git add .
    git commit -m "Sync changes from $(hostname)" -q 2>/dev/null || true
  fi

  git fetch -q 2>/dev/null || true
  local behind
  local ahead
  behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
  ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")

  if [[ "$behind" -gt 0 ]]; then
    git pull --rebase -q
    echo "Pulled $behind commit(s) from remote"
  fi

  # Recompute after any pull
  behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
  ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")

  if [[ "$ahead" -gt 0 ]]; then
    git push -q
    echo "Pushed $ahead commit(s) to remote"
  fi

  # Always ensure symlinks exist locally based on manifest
  do_restore

  if [[ "$ahead" -eq 0 ]] && [[ "$behind" -eq 0 ]]; then
    echo "Already up to date"
  fi
}

cmd_status() {
  if ! load_config; then
    print_not_initialized
    exit 1
  fi

  cd "$REPO_PATH"

  git fetch -q 2>/dev/null || true
  local behind
  local ahead
  behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
  ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")

  if [[ "$ahead" -gt 0 ]]; then
    echo "Needs push: ahead of remote by $ahead commit(s)"
  fi

  if [[ "$behind" -gt 0 ]]; then
    echo "Needs pull: behind remote by $behind commit(s)"
  fi

  if [[ "$ahead" -eq 0 ]] && [[ "$behind" -eq 0 ]]; then
    echo "Remote in sync"
  fi

  local short_status
  short_status=$(git status --porcelain)
  if [[ -n "$short_status" ]]; then
    echo "Local changes:"
    echo "$short_status"
  else
    echo "No local changes"
  fi
}

cmd_restore() {
  if ! load_config; then
    print_not_initialized
    exit 1
  fi

  cd "$REPO_PATH" && git pull -q
  do_restore
  echo "Restore complete"
}

restore_item() {
  local repo_relative_path="$1"
  local target_path
  if ! target_path=$(repo_relative_to_target_path "$repo_relative_path"); then
    echo "Skipping unmappable manifest entry: $repo_relative_path"
    return
  fi
  local repo_file_path="$REPO_PATH/$repo_relative_path"

  if [[ ! -e "$repo_file_path" ]]; then
    return
  fi

  mkdir -p "$(dirname "$target_path")"

  if [[ -e "$target_path" || -L "$target_path" ]]; then
    if [[ -L "$target_path" ]]; then
      local link_target
      link_target=$(readlink "$target_path")
      if [[ "$link_target" == "$repo_file_path" ]]; then
        return
      fi
    fi
    rm -rf "$target_path"
  fi

  ln -s "$repo_file_path" "$target_path"
  echo "Restored: $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path")"
}

do_restore() {
  local manifest
  manifest=$(load_manifest)

  while IFS= read -r repo_relative_path; do
    [[ -z "$repo_relative_path" ]] && continue
    restore_item "$repo_relative_path"
  done < <(manifest_keys "$manifest")
}

cmd_list() {
  if ! load_config; then
    print_not_initialized
    exit 1
  fi

  local manifest
  manifest=$(load_manifest)

  echo "Tracked files:"
  while IFS= read -r repo_relative_path; do
    [[ -z "$repo_relative_path" ]] && continue
    echo "  $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path")"
  done < <(manifest_keys "$manifest")
}

cmd_remove() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: ghsync remove <path>"
    exit 1
  fi

  if ! load_config; then
    print_not_initialized
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
    local dir
    dir=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd -L)
    file_path="$dir/$(basename "$file_path")"
  fi

  local repo_relative_path
  if ! repo_relative_path=$(home_path_to_repo_relative "$file_path"); then
    exit 1
  fi
  local repo_file_path="$REPO_PATH/$repo_relative_path"

  # Check if file/directory exists in repo
  if [[ ! -e "$repo_file_path" ]]; then
    echo "Not tracked: $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path")"
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

  echo "Removed: $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path") (run 'ghsync sync' to push)"
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
  status)
    cmd_status
    ;;
  *)
    echo "GitHub File Sync with Symlinks"
    echo ""
    echo "Commands:"
    echo "  init <repo-url> [token] [repo-subdir]  Initialize and restore symlinks"
    echo "  save <path>                            Save file or directory to repo and create symlink"
    echo "  remove <path>                          Stop tracking and restore original"
    echo "  sync                                   Push/pull changes and restore new symlinks"
    echo "  restore                                Manually restore all symlinks"
    echo "  list                                   List all tracked files and directories"
    echo "  status                                 Show local changes and remote sync status"
    echo ""
    echo "Examples:"
    echo "  ghsync init git@github.com:user/dotfiles.git"
    echo "  ghsync init git@github.com:user/dotfiles.git dotfiles"
    echo "  ghsync init git@github.com:user/dotfiles.git --repo-subdir '~'"
    echo "  ghsync init https://github.com/user/dotfiles TOKEN --repo-subdir dotfiles"
    echo "  ghsync save ~/.bashrc"
    echo "  ghsync save ~/.config/nvim"
    echo "  ghsync sync"
    ;;
esac
