#!/usr/bin/env bash
set -euo pipefail

# Public bootstrap for a fresh macOS machine.
# Installs 1Password, waits for the SSH agent, then clones a PRIVATE dotfiles
# repo over SSH and hands off to its setup.sh.
#
# The sensitive identifiers (1Password account, SSH-key item id, dotfiles repo
# URL) are NOT in cleartext — they live in the AES-256 blob below, decrypted at
# runtime with a passphrase you type. Run ./encrypt-secrets.sh to (re)generate it.

# --- non-sensitive constants (safe in a public repo) ---
AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
CM_PATH="$HOME/.local/share/chezmoi"

# --- encrypted identifiers: SSH_KEY_OP_ACCOUNT_URL, SSH_KEY_OP_ITEM_ID, DOTFILES_REPO_SSH_URL ---
# Single-line base64 AES-256-CBC/PBKDF2 blob. Regenerate with ./encrypt-secrets.sh.
SECRETS_ENC='U2FsdGVkX19Yu3d0OL6IG5mm0q3IluQD+ZBrNZ9Y7bqu2nIe06SZ9IkDmmNtlkgrHQk78huUv3bihEkqYLyphQchibx4t/Anuec2B8vWu3chQ8lA9W2Lx4mPDWUoZHZb+80O3pR5OlOqxQ9gTYrom/2UXXb/iUbvi/IuG3is26cc41+nXAKcdOUu12IqqgiIPGsMVvu6by9AfCkS53l4rNS3WVj/kJF+5arQursKh0Y='

# 0. Prompt for the bootstrap passphrase and decrypt FIRST, so a wrong passphrase
#    fails fast before we install anything. Read from /dev/tty (stdin may be the
#    curl pipe) and pin the system openssl (LibreSSL supports -pbkdf2).
printf 'Bootstrap passphrase: ' >/dev/tty
read -rs BOOTSTRAP_PASS </dev/tty; printf '\n' >/dev/tty
export BOOTSTRAP_PASS                  # via env, not pass:<value>, so it's not in `ps` argv
secrets="$(printf '%s\n' "$SECRETS_ENC" | /usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 \
  -iter 600000 -a -pass env:BOOTSTRAP_PASS 2>/dev/null)" \
  || { echo "Wrong passphrase or corrupt blob." >&2; exit 1; }
unset BOOTSTRAP_PASS
eval "$secrets"                        # sets SSH_KEY_OP_ACCOUNT_URL, SSH_KEY_OP_ITEM_ID, DOTFILES_REPO_SSH_URL
unset secrets

echo 'Bootstrap identifiers decrypted:'
echo "  SSH_KEY_OP_ACCOUNT_URL=$SSH_KEY_OP_ACCOUNT_URL"
echo "  SSH_KEY_OP_ITEM_ID=$SSH_KEY_OP_ITEM_ID"
echo "  DOTFILES_REPO_SSH_URL=$DOTFILES_REPO_SSH_URL"

# 1. Ensure Touch ID has a fingerprint enrolled — needed for 1Password unlock and
#    sudo Touch ID. Enrollment is GUI-only, so open the pane and wait.
if ! bioutil -c 2>/dev/null | grep -qE '[1-9][0-9]* biometric template'; then
  open "x-apple.systempreferences:com.apple.preferences.password" 2>/dev/null || true
  cat >/dev/tty <<'EOF'
No Touch ID fingerprints are enrolled.
Open System Settings > Touch ID & Password and add at least one fingerprint.
Waiting for enrollment...
EOF
  until bioutil -c 2>/dev/null | grep -qE '[1-9][0-9]* biometric template'; do
    sleep 5
  done
fi

# 2. Install Homebrew (its installer pulls in Xcode CLT) + 1Password GUI & CLI.
command -v brew >/dev/null || \
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Persist brew on PATH for future shells (idempotent), then load it for this one.
# shellcheck disable=SC2016  # the single-quoted eval is meant to land literally in .zprofile
grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null \
  || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install --cask 1password 1password-cli

# 3. Launch the GUI and instruct the user.
open -a 1Password
cat >/dev/tty <<EOF
In 1Password:
  1. Sign in to the account: ${SSH_KEY_OP_ACCOUNT_URL}
  2. Settings > Security  > enable "Unlock using Touch ID"
  3. Settings > Developer > enable "Integrate with 1Password CLI"
  4. Settings > Developer > enable "Use the SSH agent"
Waiting for that to complete...
EOF

# 4. Poll until: account present + CLI integrated/unlocked + SSH agent serving keys.
until op account list 2>/dev/null | grep -q "$SSH_KEY_OP_ACCOUNT_URL" \
   && op whoami --account "$SSH_KEY_OP_ACCOUNT_URL" >/dev/null 2>&1 \
   && op item get "$SSH_KEY_OP_ITEM_ID" --account "$SSH_KEY_OP_ACCOUNT_URL" >/dev/null 2>&1 \
   && SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -l >/dev/null 2>&1; do
  sleep 5
done

# Resolve the SSH key's name (title) from its 1Password item, for clearer messaging.
keyName="$(op item get "$SSH_KEY_OP_ITEM_ID" --account "$SSH_KEY_OP_ACCOUNT_URL" --format json 2>/dev/null \
  | sed -n 's/.*"title" *: *"\([^"]*\)".*/\1/p' | head -1)"
keyName="${keyName:-the SSH key}"

# Soft check: confirm "Unlock using Touch ID" got enabled. Best-effort only — this reads
# 1Password's internal settings file, which is undocumented and may change across versions.
OP_SETTINGS="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json"
grep -q '"security.authenticatedUnlock.appleTouchId" *: *true' "$OP_SETTINGS" 2>/dev/null \
  || echo "Note: couldn't confirm 1Password > Settings > Security > 'Unlock using Touch ID' is on." >/dev/tty

# 5. Configure SSH: 1Password agent + seed GitHub host key (no interactive prompt).
install -m 700 -d ~/.ssh
grep -q IdentityAgent ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<EOF
Host *
  IdentityAgent "${AGENT_SOCK}"
EOF
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null

# 6. Prove the chain end-to-end (ssh -T exits non-zero even on success, so match the text).
SSH_AUTH_SOCK="$AGENT_SOCK" ssh -T git@github.com 2>&1 | grep -q "successfully authenticated" \
  || { echo "SSH to GitHub failed — is ${keyName}'s PUBLIC key on the GitHub account?"; exit 1; }

# 7. Clone the private repo over SSH, then hand off to its setup.sh.
[ -d "$CM_PATH/.git" ] || git clone "$DOTFILES_REPO_SSH_URL" "$CM_PATH"
exec "$CM_PATH/setup.sh"
