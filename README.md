# ghsync - GitHub File Sync

Bidirectional file and directory synchronization across machines using Git and symlinks.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ofrades/ghsync/main/install.sh | bash
```

## Quick Start

```bash
# Initialize with your repo (SSH recommended)
ghsync init git@github.com:user/dotfiles.git

# Save files or directories you want to sync
ghsync save ~/.bashrc
ghsync save ~/.config/nvim

# Push changes to remote
ghsync sync
```

## Commands

| Command | Description |
|---------|-------------|
| `ghsync init <repo> [token]` | Initialize and restore symlinks (token optional for SSH) |
| `ghsync save <path>` | Save file or directory to repo and create symlink |
| `ghsync remove <path>` | Stop tracking and restore original |
| `ghsync sync` | Push/pull changes and restore new symlinks |
| `ghsync restore` | Manually restore all symlinks |
| `ghsync list` | List all tracked files and directories |

## How It Works

1. `save` copies file/directory to `~/.ghsync/repo/`, commits locally, replaces original with symlink
2. `sync` pushes your commits, pulls remote changes, and restores any new symlinks
3. `init` clones the repo and automatically restores all symlinks
4. `remove` restores the original file/directory and stops tracking

## Setup

### Initialize with SSH (recommended)

```bash
ghsync init git@github.com:user/dotfiles.git
```

### Initialize with HTTPS + token

```bash
ghsync init https://github.com/user/dotfiles YOUR_TOKEN
```

Get a token with 'repo' scope at https://github.com/settings/tokens

## Typical Workflow

**Machine 1 (first time):**

```bash
ghsync init git@github.com:user/dotfiles.git
ghsync save ~/.bashrc
ghsync save ~/.config/nvim
ghsync sync
```

**Machine 2 (setup):**

```bash
ghsync init git@github.com:user/dotfiles.git
# Symlinks are automatically restored!
```

**Daily use (any machine):**

```bash
# Edit files normally (they're symlinks to the repo)
vim ~/.bashrc

# Sync changes
ghsync sync
```

## File Structure

```
~/.ghsync/
├── config              # Repo URL and token
└── repo/               # Git clone
    ├── manifest.json   # Tracked files/directories list
    └── ~/
        ├── .bashrc
        └── .config/
            └── nvim/   # Entire directory synced
```

## Requirements

- `bash`
- `git`
- Optional: `jq` (for better manifest handling)

## Testing

Run the automated command coverage suite:

```bash
bash tests/ghsync_tests.sh
```

## Notes

- Token stored in `~/.ghsync/config` - keep it secure (use SSH to avoid tokens)
- Files and directories become symlinks pointing to the repo
- Use `ghsync remove <path>` to stop tracking and restore the original
