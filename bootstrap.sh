#!/usr/bin/env bash
set -euo pipefail

# Public bootstrap for a fresh macOS machine.
# Installs 1Password, waits for the SSH agent, then clones a PRIVATE dotfiles
# repo over SSH and hands off to its setup.sh.
#
# The control flow is the main() sequence at the very bottom; each numbered step
# is one function defined above it. Steps share state through a few globals:
# decrypt_secrets sets the SSH_KEY_OP_* / DOTFILES_REPO_SSH_URL / TRANSCRYPT_OP_*
# vars (shell vars, not exported), and install_homebrew puts brew on PATH.

# --- non-sensitive constants (safe in a public repo) ---
AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
CM_PATH="$HOME/.local/share/chezmoi"
# 1Password stores "Unlock using Touch ID" here; the file is undocumented and may
# change across versions, so a failed match is treated as "not enabled".
OP_SETTINGS="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json"

# Single-line base64 AES-256-CBC/PBKDF2 blob of env vars. Encode with ./secrets-write.sh.
SECRETS_ENCODED='U2FsdGVkX18mWByFpEBXcapj64yi77y4ioXNKFWVS9kAdpC2DO8MsfAQZTexz8Fzg6daHh1WDNEL7P9VDmJvgjr41ibqt+2MGqeJpkWXSlZH/EZdunDuh5a7Qhfdd3E2aP3evRISnlxNuILxQcu2KVdatLPH21EkiGKoSnTFnsCGnGTeBagmPzIUZwkow+EmQqCcFzip3g5rJel8EeHcmmM+4owT/z93rT9tGzTmr+WnpicpYklp4SVIV56mGfEIAVF/DPMD7mBzH0ERh/aYwW00l2DBWloQO67j/CC0/iYaSGS3PBt8qLknDU26jiRH1BIGWXi0Hj8sudqkR/zDHPuwuEBSwglKJjsMMnC7waeAj4bGtxtIxoyk7rd6/Syu'

# 0. Get the bootstrap passphrase (first arg if given, else prompt) and decrypt FIRST,
#    so a wrong passphrase fails fast before we install anything. Prompt reads from
#    /dev/tty (stdin may be the curl pipe); pin the system openssl (LibreSSL has -pbkdf2).
#    Note: passing it as an arg leaves it in this process's argv / your shell history.
decrypt_secrets() {
  local secrets
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
  eval "$secrets"                        # sets the SSH_KEY_OP_* / DOTFILES_REPO_SSH_URL / TRANSCRYPT_OP_* globals
}

# 1. Ensure Touch ID has a fingerprint enrolled — needed for 1Password unlock and
#    sudo Touch ID. Enrollment is GUI-only, so open the pane and wait.
has_fingerprint() { bioutil -c 2>/dev/null | grep -qE '[1-9][0-9]* biometric template'; }
ensure_touchid() {
  has_fingerprint && return
  open "x-apple.systempreferences:com.apple.preferences.password" 2>/dev/null || true
  cat >/dev/tty <<'EOF'
No Touch ID fingerprints are enrolled.
Open System Settings > Touch ID & Password and add at least one fingerprint.
Waiting for enrollment...
EOF
  until has_fingerprint; do sleep 5; done
}

# 2. Install Homebrew (its installer pulls in Xcode CLT) + 1Password GUI & CLI, and
#    transcrypt (+ coreutils), which must exist before the clone so the dotfiles
#    worktree can be decrypted in place once transcrypt is configured below.
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
install_homebrew() {
  command -v brew >/dev/null || \
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Persist brew on PATH for future shells (idempotent), then load it for this one.
  # shellcheck disable=SC2016  # the single-quoted eval is meant to land literally in .zprofile
  grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null \
    || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  # brew_ensure installs only what's missing — `brew install` still does update/network
  # work when everything is current, so skip it entirely when the deps are present.
  brew_ensure --cask 1password 1password-cli
  brew_ensure transcrypt coreutils
}

# 3. Verify 1Password is ready, then sign in. The checks run once and fail fast with
#    guidance (no polling — fix what's flagged and re-run). Each predicate is evaluated
#    in THIS shell, so it sees the SSH_KEY_OP_* vars (set by decrypt_secrets, not exported).
require() {  # require "description" predicate [args...]
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
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
op_touchid_unlock() { grep -q '"security.authenticatedUnlock.appleTouchId" *: *true' "$OP_SETTINGS" 2>/dev/null; }
op_account_added()  { op account list 2>/dev/null | grep "$SSH_KEY_OP_ACCOUNT_URL"; }
op_key_readable()   { op item get "$SSH_KEY_OP_ITEM_ID" --account "$SSH_KEY_OP_ACCOUNT_URL"; }
op_agent_has_keys() { SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -l; }
verify_1password() {
  printf '\nChecking 1Password configuration:\n' >/dev/tty
  require "'Unlock using Touch ID' enabled"        op_touchid_unlock
  require "Account '$SSH_KEY_OP_ACCOUNT_URL' added" op_account_added
  op signin --account "$SSH_KEY_OP_ACCOUNT_URL"
  require "SSH key item readable"                   op_key_readable
  require "SSH agent serving keys"                  op_agent_has_keys
}

# 4. Configure SSH: 1Password agent + seed GitHub host key (no interactive prompt).
configure_ssh() {
  install -m 700 -d ~/.ssh
  grep -q IdentityAgent ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<EOF
Host *
  IdentityAgent "${AGENT_SOCK}"
EOF
  ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null
}

# 5. Prove the chain end-to-end. `ssh -T git@github.com` exits non-zero even on success
#    (GitHub gives no shell), and pipefail would propagate that — so capture the output
#    (|| true) and match the success text instead of the exit code. Resolve the key's
#    1Password title only on failure, for a clearer message.
verify_github_ssh() {
  local auth keyName
  auth="$(SSH_AUTH_SOCK="$AGENT_SOCK" ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
  case "$auth" in
    *"successfully authenticated"*) return ;;
  esac
  keyName="$(op item get "$SSH_KEY_OP_ITEM_ID" --account "$SSH_KEY_OP_ACCOUNT_URL" --format json 2>/dev/null \
    | sed -n 's/.*"title" *: *"\([^"]*\)".*/\1/p' | head -1)"
  echo "SSH to GitHub failed — is ${keyName:-the SSH key}'s PUBLIC key on the GitHub account?" >&2
  echo "$auth" >&2
  exit 1
}

# 6. Clone the private repo over SSH.
clone_dotfiles() {
  [ -d "$CM_PATH/.git" ] || git clone "$DOTFILES_REPO_SSH_URL" "$CM_PATH"
}

# 7. Configure transcrypt in the fresh clone so its encrypted files decrypt before
#    setup.sh runs. The passphrase lives in 1Password (signed in above); fall back to
#    an interactive prompt on /dev/tty (stdin is the curl pipe). Idempotent.
configure_transcrypt() {
  local passphrase
  passphrase="$(op item get "$TRANSCRYPT_OP_ITEM_ID" --account "$TRANSCRYPT_OP_ACCOUNT_URL" \
    --fields password --reveal 2>/dev/null || true)"
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
}

# --- main: the bootstrap sequence ---
main() {
  decrypt_secrets "$@"      # 0. decrypt embedded identifiers
  ensure_touchid            # 1. Touch ID fingerprint enrolled
  install_homebrew          # 2. Homebrew + 1Password + transcrypt
  verify_1password          # 3. 1Password ready + signed in
  configure_ssh             # 4. SSH agent + GitHub host key
  verify_github_ssh         # 5. prove SSH auth to GitHub
  clone_dotfiles            # 6. clone the private dotfiles repo
  configure_transcrypt      # 7. decrypt the repo's transcrypt files
  exec "$CM_PATH/setup.sh"  # 8. hand off to the dotfiles setup
}
main "$@"
