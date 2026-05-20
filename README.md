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

# Or point ghsync at an existing local checkout
ghsync init --repo-dir ~/code/dotfiles

# Or map your home folder into a subdirectory inside the repo
ghsync init git@github.com:user/dotfiles.git dotfiles

# Save files or directories you want to sync
ghsync save ~/.bashrc
ghsync save ~/.config/nvim

# Secrets such as ~/.ssh/id_* are encrypted automatically with chezmoi
ghsync save ~/.ssh/id_ed25519

# Push changes to remote
ghsync sync
```

## Commands

| Command | Description |
|---------|-------------|
| `ghsync init <repo> [token] [repo-subdir] [--repo-dir <dir>]` | Initialize and restore symlinks. `repo-subdir` maps the repo to `$HOME`; `--repo-dir` uses an existing local checkout instead of `~/.ghsync/repo`. |
| `ghsync save [--encrypt\|--no-encrypt] <path>` | Save file or directory. Secret paths are encrypted with chezmoi instead of symlinked |
| `ghsync remove <path>` | Stop tracking and restore original |
| `ghsync sync` | Push/pull changes and restore new symlinks |
| `ghsync status` | Show local changes and remote sync status |
| `ghsync restore` | Manually restore all symlinks |
| `ghsync list` | List all tracked files and directories |
| `ghsync setup-encryption [key-file]` | Configure chezmoi age encryption for encrypted secrets |

## How It Works

1. `save` copies a file/directory into your configured repo subdir and replaces the original with a symlink
2. Secret paths are saved through chezmoi as encrypted source files under `.chezmoi/` and are restored as real files, not symlinks
3. `sync` pushes your commits, pulls remote changes, and restores any new symlinks and encrypted secrets
4. `init` either clones the repo or attaches to an existing local checkout, then restores all symlinks and encrypted secrets
5. `remove` restores the original file/directory and stops tracking

## Setup

### First machine with encrypted secrets

```bash
# Install and initialize ghsync
ghsync init git@github.com:user/dotfiles.git --repo-dir ~/code/dotfiles

# Configure chezmoi age encryption. This creates ~/.config/chezmoi/key.txt
ghsync setup-encryption

# Save normal public config as symlinks
ghsync save ~/.bashrc

# Save secrets as encrypted source in the repo, while keeping plaintext locally
ghsync save --encrypt ~/.bash_secrets
ghsync sync
```

Back up `~/.config/chezmoi/key.txt` somewhere safe. It is your decryption key and should not be committed to the dotfiles repo.

### New machine / decrypting encrypted secrets

```bash
# Restore your backed-up decryption key first
mkdir -p ~/.config/chezmoi
cp /secure/backup/key.txt ~/.config/chezmoi/key.txt
chmod 600 ~/.config/chezmoi/key.txt

# Configure chezmoi to use that key, then initialize ghsync
ghsync setup-encryption
ghsync init git@github.com:user/dotfiles.git
```

`ghsync init`, `ghsync sync`, and `ghsync restore` run `chezmoi apply`, so encrypted files from `<repo>/.chezmoi/` are decrypted into normal plaintext files in your home directory.

### Initialize with SSH (recommended)

```bash
ghsync init git@github.com:user/dotfiles.git
```

### Initialize against an existing dotfiles layout

If your repo already has dotfiles at the root, the default is enough:

```bash
ghsync init git@github.com:user/dotfiles.git
```

If you already have the repo checked out locally and want symlinks to point there directly:

```bash
ghsync init --repo-dir ~/code/dotfiles
# or explicitly keep the remote url in config
ghsync init git@github.com:user/dotfiles.git --repo-dir ~/code/dotfiles
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
ghsync init git@github.com:user/dotfiles.git --repo-dir ~/code/dotfiles
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
├── config              # Repo URL, token, repo subdir, and repo dir
└── repo/               # Git clone (default when --repo-dir is not used)
    ├── manifest.json   # Tracked files/directories list
    ├── .bashrc
    └── .config/
        └── nvim/
```

If you initialize with `--repo-dir ~/code/dotfiles`, symlinks point straight into that checkout instead:

```text
~/code/dotfiles/
├── manifest.json
├── .bashrc
└── .config/
    └── nvim/
```

If you initialize with a custom repo subdir like `dotfiles`, files are stored there instead:

```text
~/.ghsync/repo/
├── manifest.json
└── dotfiles/
    ├── .bashrc
    └── .config/
        └── nvim/
```

Legacy repos with a literal `~/` folder are still supported for compatibility, but new setups no longer need that extra directory.

## Encrypted secrets with chezmoi

`ghsync save` automatically encrypts common secret paths when `chezmoi` is installed and configured with encryption (age or gpg). Built-in secret patterns include SSH private keys, `.gnupg`, `.netrc`, AWS credentials, GitHub CLI hosts, and kubeconfig. It also scans shell env files such as `.bashrc`, `.profile`, `.zshrc`, and `.env` for secret-looking assignments like `export API_TOKEN=...` or `PASSWORD=...`; for these mixed config files, ghsync refuses the save and asks you to move secrets into a separate encrypted file unless you explicitly use `--encrypt`.

```bash
# Uses chezmoi add --encrypt and stores encrypted source state in <repo>/.chezmoi/
ghsync save ~/.ssh/id_ed25519

# Force encryption for any path
ghsync save --encrypt ~/.config/myapp/secret.yml

# Recommended for shell secrets: source an encrypted sidecar file from .bashrc
echo '[[ -f "$HOME/.bash_secrets" ]] && source "$HOME/.bash_secrets"' >> ~/.bashrc
ghsync save --no-encrypt ~/.bashrc
ghsync save --encrypt ~/.bash_secrets

# Bypass automatic encryption if needed
ghsync save --no-encrypt ~/.ssh/config
```

Add repo-specific glob patterns to `.ghsync-secrets` (one pattern per line, `#` comments allowed), for example:

```text
.config/myapp/*secret*
.env
```

Encrypted files are tracked in `.ghsync-encrypted`, refreshed with `chezmoi add --encrypt` during `ghsync sync`, and restored by `ghsync init`, `ghsync sync`, and `ghsync restore` via `chezmoi --source <repo>/.chezmoi apply`.

### Secret encryption setup

For encrypted secrets, install `chezmoi` plus `age-keygen`, then let ghsync write the chezmoi age config:

```bash
# Install chezmoi locally
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin

# Install age/age-keygen with your package manager, or from https://github.com/FiloSottile/age

# Create ~/.config/chezmoi/key.txt if missing and configure ~/.config/chezmoi/chezmoi.toml
ghsync setup-encryption
```

Back up `~/.config/chezmoi/key.txt` somewhere safe. Without it, other machines cannot decrypt your secrets. On a new machine, restore that key first, then run `ghsync setup-encryption` again to recreate the local chezmoi config.

## Requirements

- `bash`
- `git`
- Optional: `jq` (falls back to `python3` if available)
- Optional for encrypted secrets: `chezmoi`
- Optional for age-backed encryption: `age` / `age-keygen`

## Testing

Run the automated command coverage suite:

```bash
bash tests/ghsync_tests.sh
```

## Notes

- Token stored in `~/.ghsync/config` - keep it secure (use SSH to avoid tokens)
- Files and directories become symlinks pointing to the repo
- Use `ghsync remove <path>` to stop tracking and restore the original
