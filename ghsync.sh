#!/bin/bash

CONFIG_DIR="$HOME/.ghsync"
CONFIG_FILE="$CONFIG_DIR/config"
DEFAULT_REPO_PATH="$CONFIG_DIR/repo"
REPO_PATH="$DEFAULT_REPO_PATH"
MANIFEST_FILE="manifest.json"
ENCRYPTED_MANIFEST_FILE=".ghsync-encrypted"
CHEZMOI_DIR=".chezmoi"
SECRET_PATTERNS_FILE=".ghsync-secrets"

ensure_config_dir() {
  mkdir -p "$CONFIG_DIR"
}

escape_config_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

normalize_repo_dir() {
  local repo_dir="${1:-$DEFAULT_REPO_PATH}"

  repo_dir="${repo_dir/#\~/$HOME}"
  repo_dir="${repo_dir%/}"

  if [[ -z "$repo_dir" ]]; then
    repo_dir="$DEFAULT_REPO_PATH"
  fi

  if [[ "$repo_dir" != /* ]]; then
    repo_dir="$PWD/$repo_dir"
  fi

  if command -v python3 &> /dev/null; then
    REPO_DIR_INPUT="$repo_dir" python3 - <<'PY'
import os
print(os.path.abspath(os.environ["REPO_DIR_INPUT"]))
PY
  else
    printf '%s\n' "$repo_dir"
  fi
}

is_git_repo() {
  local repo_dir="$1"
  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
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
  REPO_DIR=$(sed -n 's/^REPO_DIR="\([^"]*\)"$/\1/p' "$CONFIG_FILE")

  if [[ -z "$REPO_URL" ]]; then
    return 1
  fi

  REPO_PATH=$(normalize_repo_dir "${REPO_DIR:-$DEFAULT_REPO_PATH}")

  if [[ -z "$REPO_SUBDIR" ]]; then
    REPO_SUBDIR=$(detect_repo_subdir)
  fi

  return 0
}

save_config() {
  local repo_url="$1"
  local token="$2"
  local repo_subdir="$3"
  local repo_dir="$4"
  ensure_config_dir
  cat > "$CONFIG_FILE" << EOF
REPO_URL="$(escape_config_value "$repo_url")"
GH_TOKEN="$(escape_config_value "$token")"
REPO_SUBDIR="$(escape_config_value "$repo_subdir")"
REPO_DIR="$(escape_config_value "$repo_dir")"
EOF
}

print_init_usage() {
  echo "Usage: ghsync init <repo-url> [github-token] [repo-subdir] [--repo-dir <dir>]"
  echo "       ghsync init [--repo-dir <dir>] <repo-url> [github-token] [repo-subdir]"
  echo "       ghsync init --repo-dir <existing-dir>"
  echo ""
  echo "repo-subdir is the directory inside the repo that maps to your home folder."
  echo "Default is '.' so files are stored directly in the repo root."
  echo "Use '~' only for legacy repos that already have a literal ~/ directory."
  echo "--repo-dir points ghsync at an existing local checkout instead of ~/.ghsync/repo."
}

print_not_initialized() {
  echo "Not initialized. Run: ghsync init <repo-url> [github-token] [repo-subdir]"
}

cmd_setup_encryption() {
  local key_file="${1:-$HOME/.config/chezmoi/key.txt}"
  local config_file="$HOME/.config/chezmoi/chezmoi.toml"
  local recipient

  if ! command -v chezmoi >/dev/null 2>&1; then
    echo "Error: chezmoi is not installed" >&2
    echo "Install with: sh -c \"\$(curl -fsLS get.chezmoi.io)\" -- -b ~/.local/bin" >&2
    exit 1
  fi

  if ! command -v age-keygen >/dev/null 2>&1; then
    echo "Error: age-keygen is not installed" >&2
    echo "Install age/age-keygen with your package manager or from https://github.com/FiloSottile/age" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$key_file")" "$HOME/.config/chezmoi"

  if [[ ! -f "$key_file" ]]; then
    age-keygen -o "$key_file"
    chmod 600 "$key_file"
  else
    chmod 600 "$key_file" 2>/dev/null || true
  fi

  recipient=$(sed -n 's/^# public key: //p' "$key_file" | head -n 1)
  if [[ -z "$recipient" ]]; then
    echo "Error: could not read age recipient from $key_file" >&2
    exit 1
  fi

  if [[ -f "$config_file" ]] && ! grep -q 'encryption = "age"' "$config_file"; then
    cp "$config_file" "$config_file.ghsync-backup.$(date +%s)"
  fi

  cat > "$config_file" << EOF
encryption = "age"
[age]
identity = "$key_file"
recipient = "$recipient"
EOF

  if ! printf 'test' | chezmoi encrypt | chezmoi decrypt >/dev/null; then
    echo "Error: chezmoi encryption test failed" >&2
    exit 1
  fi

  echo "chezmoi age encryption configured"
  echo "Key: $key_file"
  echo "Back up this key. Without it, other machines cannot decrypt your secrets."
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

fix_repo_item_permissions() {
  local repo_relative_path="$1"
  local repo_file_path="$2"
  local home_relative_path

  if ! home_relative_path=$(repo_relative_to_home_relative "$repo_relative_path" 2>/dev/null); then
    return
  fi

  case "$home_relative_path" in
    .ssh|.ssh/*)
      if [[ -d "$repo_file_path" ]]; then
        chmod 700 "$repo_file_path" 2>/dev/null || true
        find "$repo_file_path" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
        find "$repo_file_path" -maxdepth 1 -type f -name '*.pub' -exec chmod 644 {} + 2>/dev/null || true
        [[ -f "$repo_file_path/config" ]] && chmod 600 "$repo_file_path/config" 2>/dev/null || true
      elif [[ -f "$repo_file_path" ]]; then
        chmod 700 "$(dirname "$repo_file_path")" 2>/dev/null || true
        case "$(basename "$repo_file_path")" in
          *.pub)
            chmod 644 "$repo_file_path" 2>/dev/null || true
            ;;
          id_*)
            chmod 600 "$repo_file_path" 2>/dev/null || true
            ;;
          config)
            chmod 600 "$repo_file_path" 2>/dev/null || true
            ;;
        esac
      fi
      ;;
  esac
}

chezmoi_source_dir() {
  printf '%s/%s\n' "$REPO_PATH" "$CHEZMOI_DIR"
}

has_chezmoi_source() {
  local source_dir
  source_dir=$(chezmoi_source_dir)
  [[ -d "$source_dir" ]] && [[ -n $(find "$source_dir" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1) ]]
}

apply_chezmoi_secrets() {
  local source_dir
  source_dir=$(chezmoi_source_dir)

  if ! has_chezmoi_source; then
    return 0
  fi

  if ! command -v chezmoi >/dev/null 2>&1; then
    echo "Warning: chezmoi is not installed; encrypted secrets were not restored" >&2
    return 0
  fi

  if ! chezmoi --source "$source_dir" apply; then
    echo "Warning: chezmoi failed to restore encrypted secrets" >&2
    return 1
  fi
}

file_has_secret_env_vars() {
  local file_path="$1"
  local home_relative_path="$2"

  [[ -f "$file_path" ]] || return 1

  case "$home_relative_path" in
    .bashrc|.bash_profile|.bash_login|.profile|.zshrc|.zprofile|.env|*.env)
      ;;
    *)
      return 1
      ;;
  esac

  grep -Eq '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|ACCESS_KEY|CREDENTIAL)[A-Za-z0-9_]*[[:space:]]*=' "$file_path"
}

path_matches_secret_pattern() {
  local home_relative_path="$1"
  local pattern

  case "$home_relative_path" in
    .ssh/id_*|.gnupg|.gnupg/*|.netrc|.aws/credentials|.config/gh/hosts.yml|.kube/config)
      case "$home_relative_path" in
        .ssh/*.pub)
          return 1
          ;;
      esac
      return 0
      ;;
  esac

  if [[ -f "$REPO_PATH/$SECRET_PATTERNS_FILE" ]]; then
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
      pattern="${pattern%%#*}"
      pattern="${pattern#${pattern%%[![:space:]]*}}"
      pattern="${pattern%${pattern##*[![:space:]]}}"
      [[ -z "$pattern" ]] && continue
      [[ "$home_relative_path" == $pattern ]] && return 0
    done < "$REPO_PATH/$SECRET_PATTERNS_FILE"
  fi

  return 1
}

encrypted_manifest_path() {
  printf '%s/%s\n' "$REPO_PATH" "$ENCRYPTED_MANIFEST_FILE"
}

encrypted_manifest_keys() {
  local path
  path=$(encrypted_manifest_path)
  [[ -f "$path" ]] || return 0
  grep -v '^[[:space:]]*$' "$path" 2>/dev/null | sort -u
}

add_to_encrypted_manifest() {
  local repo_relative_path="$1"
  local path
  path=$(encrypted_manifest_path)
  { encrypted_manifest_keys; printf '%s\n' "$repo_relative_path"; } | sort -u > "$path.tmp"
  mv "$path.tmp" "$path"
}

remove_from_encrypted_manifest() {
  local repo_relative_path="$1"
  local path
  path=$(encrypted_manifest_path)
  [[ -f "$path" ]] || return 0
  grep -vxF "$repo_relative_path" "$path" > "$path.tmp" 2>/dev/null || true
  mv "$path.tmp" "$path"
}

refresh_chezmoi_encrypted_files() {
  local repo_relative_path
  local target_path
  local source_dir

  if [[ ! -f "$(encrypted_manifest_path)" ]]; then
    return 0
  fi

  if ! command -v chezmoi >/dev/null 2>&1; then
    echo "Warning: chezmoi is not installed; encrypted secrets were not refreshed" >&2
    return 0
  fi

  source_dir=$(chezmoi_source_dir)
  mkdir -p "$source_dir"

  while IFS= read -r repo_relative_path; do
    [[ -z "$repo_relative_path" ]] && continue
    if target_path=$(repo_relative_to_target_path "$repo_relative_path" 2>/dev/null) && [[ -e "$target_path" ]]; then
      if ! chezmoi --source "$source_dir" add --encrypt "$target_path"; then
        echo "Warning: chezmoi failed to refresh encrypted secret: $target_path" >&2
      fi
    fi
  done < <(encrypted_manifest_keys)
}

save_with_chezmoi_encryption() {
  local file_path="$1"
  local home_relative_path="$2"
  local repo_relative_path="$3"
  local source_dir
  local repo_file_path="$REPO_PATH/$repo_relative_path"
  local temp_plain=""

  if ! command -v chezmoi >/dev/null 2>&1; then
    echo "Error: '$home_relative_path' looks like a secret, but chezmoi is not installed" >&2
    echo "Install chezmoi and configure encryption, or rerun with --no-encrypt." >&2
    return 1
  fi

  source_dir=$(chezmoi_source_dir)
  mkdir -p "$source_dir"

  temp_plain=$(mktemp)
  cp -L "$file_path" "$temp_plain"

  if ! chezmoi --source "$source_dir" add --encrypt "$file_path"; then
    rm -f "$temp_plain"
    echo "Error: chezmoi failed to encrypt '$file_path'. Configure chezmoi encryption first (for example age/gpg), then retry." >&2
    return 1
  fi

  if [[ -L "$file_path" ]]; then
    rm -f "$file_path"
    cp "$temp_plain" "$file_path"
  fi
  rm -f "$temp_plain"

  if [[ -e "$repo_file_path" || -L "$repo_file_path" ]]; then
    rm -rf "$repo_file_path"
    remove_from_manifest "$repo_relative_path"
  fi

  if ! chezmoi --source "$source_dir" add --encrypt "$file_path"; then
    echo "Error: chezmoi failed to encrypt '$file_path'. Configure chezmoi encryption first (for example age/gpg), then retry." >&2
    return 1
  fi

  add_to_encrypted_manifest "$repo_relative_path"

  cd "$REPO_PATH"
  git add -A -- "$CHEZMOI_DIR" "$ENCRYPTED_MANIFEST_FILE" "$MANIFEST_FILE"
  if git ls-files --error-unmatch "$repo_relative_path" >/dev/null 2>&1 || [[ -e "$repo_relative_path" || -L "$repo_relative_path" ]]; then
    git add -A -- "$repo_relative_path"
  fi
  git commit -m "Save encrypted $home_relative_path from $(hostname)" -q 2>/dev/null || true

  echo "Saved encrypted with chezmoi: ~/$home_relative_path (run 'ghsync sync' to push)"
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
  local repo_url=""
  local token=""
  local repo_subdir="."
  local repo_dir="$DEFAULT_REPO_PATH"
  local repo_dir_specified=""
  local repo_url_inferred=""
  local positionals=()

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
      --repo-dir)
        if [[ $# -lt 2 ]]; then
          echo "Error: --repo-dir requires a value"
          exit 1
        fi
        repo_dir="$2"
        repo_dir_specified="1"
        shift 2
        ;;
      --repo-dir=*)
        repo_dir="${1#*=}"
        repo_dir_specified="1"
        shift
        ;;
      *)
        positionals+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positionals[@]} -gt 0 ]]; then
    repo_url="${positionals[0]}"
    if [[ ${#positionals[@]} -gt 1 ]]; then
      local extra_args=("${positionals[@]:1}")
      local arg
      local i
      local remaining
      for ((i=0; i<${#extra_args[@]}; i++)); do
        arg="${extra_args[$i]}"
        remaining=$(( ${#extra_args[@]} - i ))
        if [[ -z "$token" ]] && [[ $remaining -eq 1 ]] && [[ "$repo_url" != https://* ]]; then
          repo_subdir="$arg"
        elif [[ -z "$token" ]]; then
          token="$arg"
        elif [[ "$repo_subdir" == "." ]]; then
          repo_subdir="$arg"
        else
          print_init_usage
          exit 1
        fi
      done
    fi
  fi

  repo_dir=$(normalize_repo_dir "$repo_dir")
  REPO_PATH="$repo_dir"

  if [[ -z "$repo_url" ]]; then
    if [[ -n "$repo_dir_specified" ]] && is_git_repo "$repo_dir"; then
      repo_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || printf '%s' "$repo_dir")
      repo_url_inferred="1"
    else
      print_init_usage
      echo ""
      echo "Examples:"
      echo "  ghsync init git@github.com:user/dotfiles.git"
      echo "  ghsync init git@github.com:user/dotfiles.git --repo-dir ~/code/dotfiles"
      echo "  ghsync init --repo-dir ~/code/dotfiles"
      exit 1
    fi
  fi

  if ! repo_subdir=$(normalize_repo_subdir "$repo_subdir"); then
    exit 1
  fi

  ensure_config_dir

  if [[ -e "$repo_dir" ]] && [[ ! -d "$repo_dir" ]]; then
    echo "Error: repo-dir is not a directory: $repo_dir"
    exit 1
  fi

  if is_git_repo "$repo_dir" && [[ -n "$repo_dir_specified" || -n "$repo_url_inferred" ]]; then
    save_config "$repo_url" "$token" "$repo_subdir" "$repo_dir"
    echo "Repository initialized"
    echo "Repo subdir: $repo_subdir"
    echo "Repo dir: $repo_dir"
    do_restore
    return
  fi

  if [[ -n "$repo_dir_specified" ]] && [[ -d "$repo_dir" ]] && [[ -n $(find "$repo_dir" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1) ]]; then
    echo "Error: repo-dir exists but is not a git repository: $repo_dir"
    exit 1
  fi

  local clone_url="$repo_url"
  local temp_repo_path="${repo_dir}.tmp.$$"
  local backup_repo_path="${repo_dir}.backup.$$"

  rm -rf "$temp_repo_path" "$backup_repo_path"
  mkdir -p "$(dirname "$repo_dir")"

  # Handle different URL formats
  if [[ "$repo_url" == git@* ]]; then
    clone_url="$repo_url"
  elif [[ "$repo_url" == https://* ]] && [[ -n "$token" ]]; then
    clone_url="${repo_url/https:\/\//https:\/\/$token@}"
  fi

  if ! git clone "$clone_url" "$temp_repo_path" 2>/dev/null; then
    rm -rf "$temp_repo_path"
    echo "Error: Failed to clone repository"
    exit 1
  fi

  if [[ -e "$repo_dir" ]]; then
    mv "$repo_dir" "$backup_repo_path"
  fi

  if ! mv "$temp_repo_path" "$repo_dir"; then
    rm -rf "$temp_repo_path"
    if [[ -e "$backup_repo_path" ]]; then
      mv "$backup_repo_path" "$repo_dir"
    fi
    echo "Error: Failed to activate cloned repository"
    exit 1
  fi

  rm -rf "$backup_repo_path"

  save_config "$repo_url" "$token" "$repo_subdir" "$repo_dir"
  echo "Repository initialized"
  echo "Repo subdir: $repo_subdir"
  echo "Repo dir: $repo_dir"

  do_restore
}

cmd_save() {
  local encrypt_mode="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --encrypt)
        encrypt_mode="always"
        shift
        ;;
      --no-encrypt)
        encrypt_mode="never"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Usage: ghsync save [--encrypt|--no-encrypt] <path>"
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -lt 1 ]]; then
    echo "Usage: ghsync save [--encrypt|--no-encrypt] <path>"
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
  local home_relative_path
  if ! home_relative_path=$(repo_relative_to_home_relative "$repo_relative_path"); then
    exit 1
  fi

  if [[ "$encrypt_mode" == "auto" ]] && file_has_secret_env_vars "$file_path" "$home_relative_path" && ! path_matches_secret_pattern "$home_relative_path"; then
    echo "Error: secret-looking environment variables found in ~/$home_relative_path" >&2
    echo "Move them to a separate file such as ~/.bash_secrets and run:" >&2
    echo "  ghsync save --encrypt ~/.bash_secrets" >&2
    echo "Then source that file from ~/$home_relative_path, or use --encrypt to encrypt the whole file." >&2
    exit 1
  fi

  if [[ "$encrypt_mode" == "always" ]] || { [[ "$encrypt_mode" == "auto" ]] && path_matches_secret_pattern "$home_relative_path"; }; then
    save_with_chezmoi_encryption "$file_path" "$home_relative_path" "$repo_relative_path"
    return $?
  fi

  # Handle directories
  if [[ -d "$file_path" ]] && [[ ! -L "$file_path" ]]; then
    mkdir -p "$(dirname "$repo_file_path")"
    # Copy directory contents (follow symlinks)
    cp -rL "$file_path" "$repo_file_path"

    add_to_manifest "$repo_relative_path"
    fix_repo_item_permissions "$repo_relative_path" "$repo_file_path"

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
  fix_repo_item_permissions "$repo_relative_path" "$repo_file_path"

  cd "$REPO_PATH"
  git add .
  git commit -m "Save $repo_relative_path from $(hostname)" -q 2>/dev/null || true

  # Check if already a symlink pointing to our repo
  if [[ -L "$file_path" ]]; then
    local link_target
    link_target=$(readlink "$file_path")
    if [[ "$link_target" == "$repo_file_path" ]]; then
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

  refresh_chezmoi_encrypted_files

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
  fix_repo_item_permissions "$repo_relative_path" "$repo_file_path"

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

  apply_chezmoi_secrets
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

  while IFS= read -r repo_relative_path; do
    [[ -z "$repo_relative_path" ]] && continue
    echo "  $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path") (encrypted)"
  done < <(encrypted_manifest_keys)
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

  if encrypted_manifest_keys | grep -qxF "$repo_relative_path"; then
    if ! command -v chezmoi >/dev/null 2>&1; then
      echo "Error: chezmoi is required to remove encrypted tracked files" >&2
      exit 1
    fi

    if ! chezmoi --source "$(chezmoi_source_dir)" forget "$file_path"; then
      echo "Error: chezmoi failed to forget encrypted file: $file_path" >&2
      exit 1
    fi

    remove_from_encrypted_manifest "$repo_relative_path"

    cd "$REPO_PATH"
    git add "$CHEZMOI_DIR" "$ENCRYPTED_MANIFEST_FILE"
    git commit -m "Remove encrypted $repo_relative_path from $(hostname)" -q 2>/dev/null || true

    echo "Removed encrypted tracking: $(repo_relative_to_display_path "$repo_relative_path" 2>/dev/null || echo "$repo_relative_path") (run 'ghsync sync' to push)"
    return
  fi

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
  setup-encryption)
    shift
    cmd_setup_encryption "$@"
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
    echo "  init <repo-url> [token] [repo-subdir] [--repo-dir <dir>]  Initialize and restore symlinks"
    echo "  save [--encrypt|--no-encrypt] <path>   Save file/directory; secrets use chezmoi encryption"
    echo "  remove <path>                          Stop tracking and restore original"
    echo "  sync                                   Push/pull changes and restore new symlinks"
    echo "  restore                                Manually restore all symlinks"
    echo "  list                                   List all tracked files and directories"
    echo "  status                                 Show local changes and remote sync status"
    echo "  setup-encryption [key-file]            Configure chezmoi age encryption"
    echo ""
    echo "Examples:"
    echo "  ghsync init git@github.com:user/dotfiles.git"
    echo "  ghsync init git@github.com:user/dotfiles.git --repo-dir ~/code/dotfiles"
    echo "  ghsync init --repo-dir ~/code/dotfiles"
    echo "  ghsync init git@github.com:user/dotfiles.git dotfiles"
    echo "  ghsync init git@github.com:user/dotfiles.git --repo-subdir '~'"
    echo "  ghsync init https://github.com/user/dotfiles TOKEN --repo-subdir dotfiles"
    echo "  ghsync save ~/.bashrc"
    echo "  ghsync save ~/.config/nvim"
    echo "  ghsync sync"
    echo "  ghsync setup-encryption"
    ;;
esac
