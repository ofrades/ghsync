# ghsync - GitHub File Sync

Bidirectional file synchronization across machines using Git and symlinks.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ofrades/ghsync/main/install.sh | bash
```

## Quick Start

```bash
# Initialize with your repo (SSH recommended)
ghsync init git@github.com:user/dotfiles.git

# Save files you want to sync
ghsync save ~/.bashrc
ghsync save ~/.config/nvim/init.vim

# Push changes to remote
ghsync sync
```

## Commands

| Command | Description |
|---------|-------------|
| `ghsync init <repo> [token]` | Initialize with a GitHub repo (token optional for SSH) |
| `ghsync save <file>` | Save file to repo and create symlink |
| `ghsync remove <file>` | Stop tracking file and restore original |
| `ghsync sync` | Push local changes and pull remote updates |
| `ghsync restore` | Restore all symlinks from repo (for new machines) |
| `ghsync list` | List all tracked files |

## How It Works

1. `save` copies file to `~/.ghsync/repo/`, commits locally, replaces original with symlink
2. `sync` pushes your commits and pulls remote changes
3. `restore` creates symlinks for all tracked files on a new machine
4. `remove` restores the original file and stops tracking

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
ghsync save ~/.vimrc
ghsync sync
```

**Machine 2 (setup):**

```bash
ghsync init git@github.com:user/dotfiles.git
ghsync restore
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
    ├── manifest.json   # Tracked files list
    └── ~/
        ├── .bashrc
        └── .config/
            └── nvim/
                └── init.vim
```

## Requirements

- `bash`
- `git`
- Optional: `jq` (for better manifest handling)

## Notes

- Token stored in `~/.ghsync/config` - keep it secure (use SSH to avoid tokens)
- Files become symlinks pointing to the repo
- Use `ghsync remove <file>` to stop tracking and restore the original file
