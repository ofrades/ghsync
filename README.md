# ghsync - Archived

> **Archived:** use [chezmoi](https://www.chezmoi.io/) instead.

`ghsync` started as a small Git + symlink dotfile synchronizer. After adding encrypted secrets, it became clear that chezmoi already solves this problem better: it manages dotfiles, encryption, templates, diffs, updates, and git-backed workflows without custom symlink logic.

This repository is kept for history only. New setups should use chezmoi directly.

## Recommended replacement: chezmoi

### First machine

```bash
# Install chezmoi
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin

# Initialize a dotfiles repo
chezmoi init git@github.com:user/dotfiles.git

# Add normal files
chezmoi add ~/.bashrc
chezmoi add ~/.config/nvim

# Add encrypted secrets
chezmoi add --encrypt ~/.bash_secrets
chezmoi add --encrypt ~/.ssh/id_ed25519

# Review, commit, and push
chezmoi diff
chezmoi git status
chezmoi git add .
chezmoi git commit -m "Add dotfiles"
chezmoi git push
```

### New machine

```bash
# Install chezmoi
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin

# Restore your encryption key/config first if using encrypted files
# Then initialize and apply
chezmoi init git@github.com:user/dotfiles.git
chezmoi apply
```

### Daily workflow

```bash
chezmoi diff
chezmoi apply
chezmoi update
chezmoi git status
chezmoi git add .
chezmoi git commit -m "Update dotfiles"
chezmoi git push
```

## Encrypted secrets

Chezmoi stores secrets encrypted in the repo and decrypts them to normal plaintext files locally.

Example with age encryption:

```bash
mkdir -p ~/.config/chezmoi
age-keygen -o ~/.config/chezmoi/key.txt
chmod 600 ~/.config/chezmoi/key.txt

recipient=$(grep '^# public key:' ~/.config/chezmoi/key.txt | sed 's/^# public key: //')
cat > ~/.config/chezmoi/chezmoi.toml <<EOF
encryption = "age"
[age]
identity = "~/.config/chezmoi/key.txt"
recipient = "$recipient"
EOF
```

Back up `~/.config/chezmoi/key.txt` somewhere safe. Without it, other machines cannot decrypt your secrets.

## Migrating from ghsync

If you used `ghsync`, migrate files into chezmoi explicitly:

```bash
chezmoi init --source ~/code/dotfiles
chezmoi add ~/.bashrc
chezmoi add ~/.config/nvim
chezmoi add --encrypt ~/.bash_secrets
chezmoi add --encrypt ~/.ssh/id_ed25519
chezmoi diff
```

After verifying chezmoi applies correctly, remove old `ghsync` symlink tracking/manifest files from your dotfiles repo.
