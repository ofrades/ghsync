# ghsync

> **Not archived.** We tried chezmoi. It was a phase.

`ghsync` is a small Git-backed dotfile synchronizer. It copies files into a repo,
commits them, and replaces the originals with symlinks so edits flow directly
back into git. No templates, no source directories, no `apply` step.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ofrades/ghsync/main/install.sh | bash
```

## First machine

```bash
ghsync init git@github.com:ofrades/dot.git --repo-dir ~/code/ofrades/dot
ghsync save ~/.bashrc
ghsync save ~/.config/nvim
ghsync save ~/.config/tmux
ghsync sync
```

## Daily workflow

```bash
ghsync sync          # pull, push, and fix any broken symlinks
ghsync save <path>   # add a new file or directory to tracking
ghsync list          # show what's tracked
ghsync remove <path> # stop tracking something
ghsync status        # git status + remote sync check
```

## How it works

- `ghsync save ~/.bashrc` copies `~/.bashrc` to the repo, commits it, and symlinks `~/.bashrc` → `repo/.bashrc`
- Edit `~/.bashrc` normally — you're editing the repo file via the symlink
- `ghsync sync` commits any changes, pulls, pushes, and ensures symlinks are healthy
- The repo stores files exactly as they appear in `~` — no `dot_` prefixes, no templates

## New machine

```bash
ghsync init git@github.com:ofrades/dot.git --repo-dir ~/code/ofrades/dot
ghsync restore
```

## Encrypted secrets

Not supported, and that's intentional. Store secrets in a password manager.
If you must keep something encrypted in the repo, encrypt it yourself with `age`
and decrypt on `ghsync restore`. SSH keys and tokens do not belong here.
