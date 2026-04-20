#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHSYNC_BIN="$ROOT_DIR/ghsync.sh"

TMP_ROOTS=()

tests_run=0
tests_failed=0

fail() {
  echo "  FAIL: $1"
  return 1
}

cleanup_all() {
  for dir in "${TMP_ROOTS[@]}"; do
    [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"
  done
}

trap cleanup_all EXIT

ghsync() {
  bash "$GHSYNC_BIN" "$@"
}

setup_seed_repo() {
  TMP_ROOT=$(mktemp -d)
  TMP_ROOTS+=("$TMP_ROOT")
  export HOME="$TMP_ROOT/home"
  mkdir -p "$HOME"

  # Each isolated repo needs git identity
  git config --global user.name "Test User" >/dev/null
  git config --global user.email "test@example.com" >/dev/null

  REMOTE_REPO="$TMP_ROOT/remote.git"
  git init --bare "$REMOTE_REPO" >/dev/null

  local seed="$TMP_ROOT/seed"
  git clone "$REMOTE_REPO" "$seed" >/dev/null
  git -C "$seed" config user.name "Test User" >/dev/null
  git -C "$seed" config user.email "test@example.com" >/dev/null
  echo '{}' > "$seed/manifest.json"
  git -C "$seed" add manifest.json >/dev/null
  git -C "$seed" commit -m "Initial manifest" >/dev/null
  git -C "$seed" push >/dev/null
  rm -rf "$seed"
}

configure_repo_user() {
  git -C "$HOME/.ghsync/repo" config user.name "Test User" >/dev/null
  git -C "$HOME/.ghsync/repo" config user.email "test@example.com" >/dev/null
}

run_test() {
  local name="$1"
  shift
  tests_run=$((tests_run + 1))
  if ( "$name" "$@" ); then
    echo "ok - $name"
  else
    tests_failed=$((tests_failed + 1))
    echo "not ok - $name"
  fi
}

test_init_creates_repo_and_config() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" >/dev/null

  [[ -d "$HOME/.ghsync/repo/.git" ]] || fail "git repo missing"
  [[ -f "$HOME/.ghsync/config" ]] || fail "config file missing"
  grep -q "REPO_URL=\"$REMOTE_REPO\"" "$HOME/.ghsync/config" || fail "config missing repo url"
  grep -q 'REPO_SUBDIR="."' "$HOME/.ghsync/config" || fail "config missing default repo subdir"
  [[ -f "$HOME/.ghsync/repo/manifest.json" ]] || fail "manifest missing"
}

test_init_accepts_custom_repo_subdir() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" dotfiles >/dev/null

  grep -q 'REPO_SUBDIR="dotfiles"' "$HOME/.ghsync/config" || fail "config missing custom repo subdir"
}

test_save_creates_symlink_and_manifest_entry() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" >/dev/null
  configure_repo_user

  echo "hello" > "$HOME/.bashrc"
  ghsync save "$HOME/.bashrc" >/dev/null

  [[ -L "$HOME/.bashrc" ]] || fail "bashrc not symlinked"
  local target
  target=$(readlink "$HOME/.bashrc")
  [[ "$target" == "$HOME/.ghsync/repo/.bashrc" ]] || fail "bashrc symlink target wrong"
  [[ "$(cat "$HOME/.ghsync/repo/.bashrc")" == "hello" ]] || fail "repo copy missing content"
  grep -q '".bashrc"' "$HOME/.ghsync/repo/manifest.json" || fail "manifest missing entry"
}

test_save_with_custom_repo_subdir_uses_existing_layout() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" dotfiles >/dev/null
  configure_repo_user

  echo "hello" > "$HOME/.bashrc"
  ghsync save "$HOME/.bashrc" >/dev/null

  [[ -L "$HOME/.bashrc" ]] || fail "bashrc not symlinked"
  local target
  target=$(readlink "$HOME/.bashrc")
  [[ "$target" == "$HOME/.ghsync/repo/dotfiles/.bashrc" ]] || fail "bashrc symlink target wrong for custom repo subdir"
  [[ "$(cat "$HOME/.ghsync/repo/dotfiles/.bashrc")" == "hello" ]] || fail "custom subdir copy missing content"
  grep -q '"dotfiles/.bashrc"' "$HOME/.ghsync/repo/manifest.json" || fail "manifest missing custom subdir entry"
}

test_sync_restores_new_remote_symlink() {
  setup_seed_repo
  "$GHSYNC_BIN" init "$REMOTE_REPO" >/dev/null

  local other="$TMP_ROOT/other"
  git clone "$REMOTE_REPO" "$other" >/dev/null
  git -C "$other" config user.name "Test User" >/dev/null
  git -C "$other" config user.email "test@example.com" >/dev/null
  echo "vimrc" > "$other/.vimrc"
  echo '{".vimrc":".vimrc"}' > "$other/manifest.json"
  git -C "$other" add manifest.json .vimrc >/dev/null
  git -C "$other" commit -m "Add vimrc" >/dev/null
  git -C "$other" push >/dev/null

  rm -rf "$other"

  ghsync sync >/dev/null

  [[ -L "$HOME/.vimrc" ]] || fail "vimrc symlink not created"
  local target
  target=$(readlink "$HOME/.vimrc")
  [[ "$target" == "$HOME/.ghsync/repo/.vimrc" ]] || fail "vimrc symlink target wrong"
  [[ "$(cat "$HOME/.vimrc")" == "vimrc" ]] || fail "vimrc content missing"
}

test_legacy_layout_is_auto_detected_without_repo_subdir_config() {
  setup_seed_repo
  "$GHSYNC_BIN" init "$REMOTE_REPO" '~' >/dev/null
  configure_repo_user

  echo "hello" > "$HOME/.bashrc"
  ghsync save "$HOME/.bashrc" >/dev/null

  cat > "$HOME/.ghsync/config" << EOF
REPO_URL="$REMOTE_REPO"
GH_TOKEN=""
EOF

  echo "set number" > "$HOME/.vimrc"
  ghsync save "$HOME/.vimrc" >/dev/null

  [[ -L "$HOME/.vimrc" ]] || fail "vimrc not symlinked for legacy layout"
  local target
  target=$(readlink "$HOME/.vimrc")
  [[ "$target" == "$HOME/.ghsync/repo/~/.vimrc" ]] || fail "legacy vimrc symlink target wrong"
  [[ "$(cat "$HOME/.ghsync/repo/~/.vimrc")" == "set number" ]] || fail "legacy repo copy missing content"
  grep -q '"~/.vimrc"' "$HOME/.ghsync/repo/manifest.json" || fail "legacy manifest missing entry"
}

test_restore_recreates_missing_symlink() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" >/dev/null
  configure_repo_user

  echo "hello" > "$HOME/.bashrc"
  ghsync save "$HOME/.bashrc" >/dev/null
  rm "$HOME/.bashrc"

  ghsync restore >/dev/null

  [[ -L "$HOME/.bashrc" ]] || fail "bashrc symlink not restored"
  [[ "$(cat "$HOME/.bashrc")" == "hello" ]] || fail "restored content wrong"
}

test_restore_replaces_broken_symlink_after_layout_change() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" >/dev/null
  configure_repo_user

  echo "hello" > "$HOME/.bashrc"
  ghsync save "$HOME/.bashrc" >/dev/null

  mkdir -p "$HOME/.ghsync/repo/~"
  mv "$HOME/.ghsync/repo/.bashrc" "$HOME/.ghsync/repo/~/.bashrc"
  cat > "$HOME/.ghsync/repo/manifest.json" << EOF
{"~/.bashrc":"~/.bashrc"}
EOF
  ln -sfn "$HOME/.ghsync/repo/~/.bashrc" "$HOME/.bashrc"

  mv "$HOME/.ghsync/repo/~/.bashrc" "$HOME/.ghsync/repo/.bashrc"
  rmdir "$HOME/.ghsync/repo/~"
  cat > "$HOME/.ghsync/config" << EOF
REPO_URL="$REMOTE_REPO"
GH_TOKEN=""
REPO_SUBDIR="."
EOF
  cat > "$HOME/.ghsync/repo/manifest.json" << EOF
{".bashrc":".bashrc"}
EOF

  ghsync restore >/dev/null

  [[ -L "$HOME/.bashrc" ]] || fail "bashrc symlink missing after broken-link restore"
  local target
  target=$(readlink "$HOME/.bashrc")
  [[ "$target" == "$HOME/.ghsync/repo/.bashrc" ]] || fail "broken symlink not repointed to new layout"
  [[ "$(cat "$HOME/.bashrc")" == "hello" ]] || fail "content wrong after broken-link restore"
}

test_remove_restores_real_file_and_updates_manifest() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" >/dev/null
  configure_repo_user

  echo "hello" > "$HOME/.bashrc"
  ghsync save "$HOME/.bashrc" >/dev/null

  ghsync remove "$HOME/.bashrc" >/dev/null

  [[ -f "$HOME/.bashrc" ]] || fail "bashrc file missing after remove"
  [[ ! -L "$HOME/.bashrc" ]] || fail "bashrc still symlink after remove"
  [[ "$(cat "$HOME/.bashrc")" == "hello" ]] || fail "restored file content wrong"
  ! grep -q '".bashrc"' "$HOME/.ghsync/repo/manifest.json" || fail "manifest still contains entry"
  [[ ! -e "$HOME/.ghsync/repo/.bashrc" ]] || fail "repo copy not removed"
}

test_list_outputs_tracked_files() {
  setup_seed_repo
  ghsync init "$REMOTE_REPO" >/dev/null
  configure_repo_user

  echo "hello" > "$HOME/.bashrc"
  ghsync save "$HOME/.bashrc" >/dev/null

  local output
  output=$(ghsync list)
  echo "$output" | grep -q "~/.bashrc" || fail "list missing tracked file"
}

main() {
  run_test test_init_creates_repo_and_config
  run_test test_init_accepts_custom_repo_subdir
  run_test test_save_creates_symlink_and_manifest_entry
  run_test test_save_with_custom_repo_subdir_uses_existing_layout
  run_test test_sync_restores_new_remote_symlink
  run_test test_legacy_layout_is_auto_detected_without_repo_subdir_config
  run_test test_restore_recreates_missing_symlink
  run_test test_restore_replaces_broken_symlink_after_layout_change
  run_test test_remove_restores_real_file_and_updates_manifest
  run_test test_list_outputs_tracked_files

  echo ""
  echo "Tests run: $tests_run"
  echo "Tests failed: $tests_failed"
  if [[ "$tests_failed" -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
