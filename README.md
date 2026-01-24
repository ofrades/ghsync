# ghsync - GitHub File Sync

Bidirectional file synchronization across machines using Git and symlinks. Like GNU Stow but two-way.

## Features

- **Save files once, access everywhere**: Save any file to a private GitHub repo
- **Automatic symlinks**: Preserves original file locations via symlinks
- **Directory structure preserved**: Files maintain their full path (`~/.config/nvim/init.vim`)
- **Bidirectional sync**: Edit on any machine, changes sync through Git
- **Zero installation**: Pure bash, only requires git
- **Single source of truth**: Your repo becomes the canonical location for all tracked files

## How It Works

1. You save a file (e.g., `~/.bashrc`)
2. Script copies it to `~/.ghsync/repo/~/.bashrc` (preserving path)
3. Commits and pushes to GitHub
4. Replaces original with symlink pointing to repo version
5. On other machines, `restore` creates the same symlinks
6. All machines edit the same file through symlinks
7. Just commit/push from `~/.ghsync/repo` to sync changes

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ofrades/ghsync/main/install.sh | bash
```

Or manually:

```bash
curl -o ~/.local/bin/ghsync https://raw.githubusercontent.com/ofrades/ghsync/main/ghsync.sh
chmod +x ~/.local/bin/ghsync
```

## Setup

### First Time (Create GitHub repo first)

```bash
# Create a private repo on GitHub: https://github.com/new

# Initialize with SSH (recommended)
ghsync init git@github.com:yourusername/dotfiles.git

# Or with HTTPS + token
# Get a token with 'repo' scope: https://github.com/settings/tokens
ghsync init https://github.com/yourusername/dotfiles YOUR_GITHUB_TOKEN
```

## Commands

### `ghsync save <file-path>`

Save a file to the repo and create a symlink.

```bash
ghsync save ~/.bashrc
ghsync save ~/.config/nvim/init.vim
ghsync save ~/Documents/notes.txt
```

The file is copied to the repo, committed, pushed, then replaced with a symlink.

### `ghsync sync`

Pull latest changes from GitHub.

```bash
ghsync sync
```

Since your files are symlinks to the repo, pulling updates immediately reflects in all tracked files.

### `ghsync restore`

Set up all symlinks on a new machine.

```bash
ghsync init git@github.com:yourusername/dotfiles.git
ghsync restore
```

This creates symlinks for all tracked files at their original locations.

### `ghsync list`

Show all tracked files.

```bash
ghsync list
```

## Typical Workflow

**On Machine 1:**

```bash
# First time
ghsync init git@github.com:user/dotfiles.git
ghsync save ~/.bashrc
ghsync save ~/.vimrc

# Edit ~/.bashrc (you're editing the repo copy through symlink)
vim ~/.bashrc

# Commit and push
cd ~/.ghsync/repo
git add -A
git commit -m "update bashrc"
git push
```

**On Machine 2:**

```bash
# First time setup
ghsync init git@github.com:user/dotfiles.git
ghsync restore

# Later, get updates
ghsync sync

# Your ~/.bashrc now has Machine 1's changes
```

## File Structure

```
~/.ghsync/
├── config              # Stores repo URL and token
└── repo/               # Git clone of your private repo
    ├── manifest.json   # Tracks which files are synced
    └── ~/              # Your files, preserving full paths
        ├── .bashrc
        ├── .vimrc
        └── .config/
            └── nvim/
                └── init.vim
```

## Requirements

- `bash`
- `git`
- Optional: `jq` (for prettier manifest handling, but not required)

## Notes

- Your GitHub token is stored in `~/.ghsync/config` - keep it secure
- Files are replaced with symlinks after saving
- The repo becomes the single source of truth
- Manual git operations in `~/.ghsync/repo` work normally
- To stop tracking a file, just delete it from the repo and remove the symlink
