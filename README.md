# ghsync - GitHub File Sync

Bidirectional file and directory synchronization across machines using Git and symlinks.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ofrades/ghsync/main/install.sh | bash
```

## Quick Start

```bash
# Initialize with your repo (SSH recommended)
# Default layout stores files directly at the repo root
ghsync init git@github.com:user/dotfiles.git

# Or map your home folder into a subdirectory inside the repo
ghsync init git@github.com:user/dotfiles.git dotfiles

# Save files or directories you want to sync
ghsync save ~/.bashrc
ghsync save ~/.config/nvim

# Push changes to remote
ghsync sync
```

## Commands

| Command | Description |
|---------|-------------|
| `ghsync init <repo> [token] [repo-subdir]` | Initialize and restore symlinks. `repo-subdir` is the directory in the repo that maps to `$HOME`; default is `.` for repo root. |
| `ghsync save <path>` | Save file or directory to repo and create symlink |
| `ghsync remove <path>` | Stop tracking and restore original |
| `ghsync sync` | Push/pull changes and restore new symlinks |
| `ghsync status` | Show local changes and remote sync status |
| `ghsync restore` | Manually restore all symlinks |
| `ghsync list` | List all tracked files and directories |

## How It Works

1. `save` copies a file/directory into your configured repo subdir and replaces the original with a symlink
2. `sync` pushes your commits, pulls remote changes, and restores any new symlinks
3. `init` clones the repo and automatically restores all symlinks
4. `remove` restores the original file/directory and stops tracking

## Setup

### Initialize with SSH (recommended)

```bash
ghsync init git@github.com:user/dotfiles.git
```

### Initialize against an existing dotfiles layout

If your repo already has dotfiles at the root, the default is enough:

```bash
ghsync init git@github.com:user/dotfiles.git
```

If your dotfiles live in a subdirectory like `dotfiles/`:

```bash
ghsync init git@github.com:user/dotfiles.git dotfiles
# or
ghsync init git@github.com:user/dotfiles.git --repo-subdir dotfiles
```

If you are migrating an older ghsync repo that literally stores files under `~/` in the repo, you can still opt into that legacy layout:

```bash
ghsync init git@github.com:user/dotfiles.git --repo-subdir '~'
```

### Initialize with HTTPS + token

```bash
ghsync init https://github.com/user/dotfiles TOKEN
```

With a token and a custom repo subdir:

```bash
ghsync init https://github.com/user/dotfiles TOKEN dotfiles
# or
ghsync init https://github.com/user/dotfiles TOKEN --repo-subdir dotfiles
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

# Check status without syncing
ghsync status
```

## File Structure

Default layout:

```text
~/.ghsync/
├── config              # Repo URL, token, and repo subdir
└── repo/               # Git clone
    ├── manifest.json   # Tracked files/directories list
    ├── .bashrc
    └── .config/
        └── nvim/
```

If you initialize with a custom repo subdir like `dotfiles`, files are stored there instead:

```text
~/.ghsync/
├── config
└── repo/
    ├── manifest.json
    └── dotfiles/
        ├── .bashrc
        └── .config/
            └── nvim/
```

Legacy repos with a literal `~/` folder are still supported for compatibility, but new setups no longer need that extra directory.

## Requirements

- `bash`
- `git`
- Optional: `jq` (falls back to `python3` if available)

## Testing

Run the automated command coverage suite:

```bash
bash tests/ghsync_tests.sh
```

## Notes

- Token stored in `~/.ghsync/config` - keep it secure (use SSH to avoid tokens)
- Files and directories become symlinks pointing to the repo
- Use `ghsync remove <path>` to stop tracking and restore the original
