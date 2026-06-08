#!/usr/bin/env bash
set -euo pipefail

# Public bootstrap for a fresh macOS machine.
# Installs 1Password, waits for the SSH agent, then clones a PRIVATE dotfiles
# repo over SSH and hands off to its setup.sh.

# --- non-sensitive constants (safe in a public repo) ---
AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
CM_PATH="$HOME/.local/share/chezmoi"

# Single-line base64 AES-256-CBC/PBKDF2 blob of env vars. Encode with ./secrets-write.sh.
SECRETS_ENCODED='U2FsdGVkX1/k5qIvyTI5t/QR4F98brbcGKugSvGfo3bbnsSUVgoUs1NdYmzBcwGitZp8MI/LxwNGx64bk6TL8Uvo/Af44eWk1+aObpWhVZfBvnbC0yGh857Ut5tTXPR39OPMP84wFTzTM4eMp6nLLzGyCtEwVelE3fiEQ5rI2F4uhBfS/tVmstTVTWxV187OQpvvahudiz2/pcNsmzLHSXSPEmYd1Sb2TvYCZ6FIBaRQMrOfTKLwgO1obtmPQ5xjvjhF7jw/b6UcLjHyBgohWOPkV42Wpl3Ag2h2Ru6wWLWicZ35hmFaP7Ku5DJz44rGkxAXCyTbwOB8rQgUsGCRoJCuY+ktnOJDA8bxt5YLcKc='

# 0. Get the bootstrap passphrase (first arg if given, else prompt) and decrypt FIRST,
#    so a wrong passphrase fails fast before we install anything. Prompt reads from
#    /dev/tty (stdin may be the curl pipe); pin the system openssl (LibreSSL has -pbkdf2).
#    Note: passing it as an arg leaves it in this process's argv / your shell history.
if [ -n "${1:-}" ]; then
  BOOTSTRAP_PASS="$1"
else
  printf 'Bootstrap passphrase: ' >/dev/tty
  read -rs BOOTSTRAP_PASS </dev/tty; printf '\n' >/dev/tty
fi
export BOOTSTRAP_PASS                  # to openssl via env, not pass:<value>, so it's not in openssl's argv
secrets="$(printf '%s\n' "$SECRETS_ENCODED" | /usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 \
  -iter 600000 -a -pass env:BOOTSTRAP_PASS 2>/dev/null)" \
  || { echo "Wrong passphrase or corrupt blob." >&2; exit 1; }
unset BOOTSTRAP_PASS
echo 'Decrypted:'
echo "$secrets"
eval "$secrets"                        # sets env vars
unset secrets

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
# Install brew packages only if missing — `brew install` still does update/network
# work when everything is current, so skip it entirely when the deps are present.
brew_ensure() {  # brew_ensure [--cask] pkg...
  local list_flag=--formula install_flag='' missing='' pkg
  if [ "${1:-}" = "--cask" ]; then list_flag=--cask; install_flag=--cask; shift; fi
  for pkg in "$@"; do
    brew list "$list_flag" "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
  done
  if [ -n "$missing" ]; then
    # shellcheck disable=SC2086  # word-split the missing list (+ optional --cask)
    brew install $install_flag $missing
  fi
}
brew_ensure --cask 1password 1password-cli
# transcrypt (+ coreutils dep) must be present before the clone, so the dotfiles
# worktree can be decrypted in place once we configure transcrypt below.
brew_ensure transcrypt coreutils

# 3. Check the 1Password preconditions once, failing fast with guidance if any is unmet
#    (no polling — fix what's flagged and re-run). `require` evaluates its test in this
#    shell (the SSH_KEY_OP_* vars aren't exported); on the first miss it opens 1Password,
#    prints the setup steps, and exits.
require() {  # require "description" 'shell test'
  local desc="$1" test="$2"
  if eval "$test" >/dev/null 2>&1; then
    printf '  · %s ✓\n' "$desc" >/dev/tty
    return
  fi
  printf '  · %s ✗\n' "$desc" >/dev/tty  
  cat >/dev/tty <<EOF
1Password isn't ready yet. In the 1Password app:
  1. Sign in to the account: ${SSH_KEY_OP_ACCOUNT_URL}
  2. Settings > Security  > enable "Unlock using Touch ID"
  3. Settings > Developer > enable "Integrate with 1Password CLI"
  4. Settings > Developer > enable "Use the SSH agent"
Then re-run this bootstrap.
EOF
  exit 1
}



printf "\nChecking 1Password configurations:\n"

# Soft check: confirm "Unlock using Touch ID" got enabled. Best-effort only — this reads
# 1Password's internal settings file, which is undocumented and may change across versions.
OP_SETTINGS="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json"
grep -q '"security.authenticatedUnlock.appleTouchId" *: *true' "$OP_SETTINGS" 2>/dev/null \
  || echo "Note: couldn't confirm 1Password > Settings > Security > 'Unlock using Touch ID' is on." >/dev/tty

require "1Password 'Unlock using Touch ID' enabled" "grep -q '\"security.authenticatedUnlock.appleTouchId\" *: *true' \"$OP_SETTINGS\" 2>/dev/null"
require "Account '$SSH_KEY_OP_ACCOUNT_URL' added"   "op account list 2>/dev/null | grep $SSH_KEY_OP_ACCOUNT_URL"

# ensure we're signed in
op signin --account "$SSH_KEY_OP_ACCOUNT_URL"

require "SSH key item readable"                         "op item get $SSH_KEY_OP_ITEM_ID --account $SSH_KEY_OP_ACCOUNT_URL"
require "1Password SSH agent serving keys"              "SSH_AUTH_SOCK=\"$AGENT_SOCK\" ssh-add -l"

# Resolve the SSH key's name (title) from its 1Password item, for clearer messaging.
keyName="$(op item get "$SSH_KEY_OP_ITEM_ID" --account "$SSH_KEY_OP_ACCOUNT_URL" --format json 2>/dev/null \
  | sed -n 's/.*"title" *: *"\([^"]*\)".*/\1/p' | head -1)"
keyName="${keyName:-the SSH key}"

# 5. Configure SSH: 1Password agent + seed GitHub host key (no interactive prompt).
install -m 700 -d ~/.ssh
grep -q IdentityAgent ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<EOF
Host *
  IdentityAgent "${AGENT_SOCK}"
EOF
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null

# 6. Prove the chain end-to-end. `ssh -T git@github.com` exits non-zero even on success
#    (GitHub gives no shell), and `set -o pipefail` would propagate that through a pipe —
#    so capture the output (|| true) and match the success text instead of the exit code.
auth="$(SSH_AUTH_SOCK="$AGENT_SOCK" ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
case "$auth" in
  *"successfully authenticated"*) ;;
  *)
    echo "SSH to GitHub failed — is ${keyName}'s PUBLIC key on the GitHub account?" >&2
    echo "$auth" >&2
    exit 1 ;;
esac

# 7. Clone the private repo over SSH.
[ -d "$CM_PATH/.git" ] || git clone "$DOTFILES_REPO_SSH_URL" "$CM_PATH"

# 8. Configure transcrypt in the fresh clone so its encrypted files decrypt before
#    setup.sh runs. The passphrase lives in 1Password (signed in above); fall back to
#    an interactive prompt on /dev/tty (stdin is the curl pipe). Idempotent.
#    TRANSCRYPT_OP_REF / TRANSCRYPT_OP_ACCOUNT come from the decrypted SECRETS_ENCODED.
passphrase="$(op read "$TRANSCRYPT_OP_REF" --account "$TRANSCRYPT_OP_ACCOUNT" 2>/dev/null || true)"
if [ -z "$passphrase" ]; then
  printf 'Transcrypt passphrase: ' >/dev/tty
  read -rs passphrase </dev/tty; printf '\n' >/dev/tty
fi
[ -n "$passphrase" ] || { echo "No transcrypt passphrase provided." >&2; exit 1; }
if git -C "$CM_PATH" config --local --get transcrypt.version >/dev/null 2>&1; then
  # Already initialised: just refresh the stored passphrase (re-init is refused).
  git -C "$CM_PATH" config --local transcrypt.password "$passphrase"
else
  # Fresh clone: a full init also installs the filter/diff/merge drivers.
  ( cd "$CM_PATH" && transcrypt -c aes-256-cbc -p "$passphrase" -y )
fi
unset passphrase

# Re-materialize any files still sitting as ciphertext, then enable the repo-tracked
# git hooks that keep them decrypted on future operations.
[ -x "$CM_PATH/hooks/lib/transcrypt-resmudge.sh" ] && ( cd "$CM_PATH" && hooks/lib/transcrypt-resmudge.sh )
git -C "$CM_PATH" config --local core.hooksPath hooks

# 9. Hand off to the dotfiles setup.
exec "$CM_PATH/setup.sh"
