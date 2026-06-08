#!/usr/bin/env bash
set -euo pipefail

# Prompt for the bootstrap identifiers, encrypt them into a single-line AES-256
# blob, and write that into bootstrap.sh's SECRETS_ENC. Run whenever a value
# changes. No plaintext is written to disk — values are piped straight into openssl.

cd "$(dirname "$0")"
target="bootstrap.sh"
[[ -f "$target" ]] || { echo "!!! $target not found next to this script." >&2; exit 1; }

echo "Sets the encrypted identifiers embedded in $target. Enter each value when prompted."
echo

echo "SSH_KEY_OP_ACCOUNT_URL — the 1Password account that holds your SSH key."
echo "  Example: ***REMOVED***"
read -rp "  value: " ssh_key_op_account_url

echo
echo "SSH_KEY_OP_ITEM_ID — the 1Password item ID of that SSH key (e.g. id_martaver)."
echo "  Example: ***REMOVED***"
read -rp "  value: " ssh_key_op_item_id

echo
echo "DOTFILES_REPO_SSH_URL — the SSH clone URL of your PRIVATE dotfiles repo."
echo "  Example: ***REMOVED***"
read -rp "  value: " dotfiles_repo_ssh_url

echo
echo "Bootstrap passphrase — you'll type this on a fresh machine to decrypt the blob."
read -rs -p "  passphrase: " bootstrap_pass; echo
read -rs -p "  confirm:    " bootstrap_pass2; echo
[[ -n "$bootstrap_pass" ]]                  || { echo "!!! Empty passphrase." >&2; exit 1; }
[[ "$bootstrap_pass" == "$bootstrap_pass2" ]] || { echo "!!! Passphrases don't match." >&2; exit 1; }

# Encrypt the KEY=value lines (%q-quoted so eval reconstructs them safely) into a
# single-line base64 blob. -A keeps it on one line for a clean regex replace.
export BOOTSTRAP_PASS="$bootstrap_pass"
blob="$(printf 'SSH_KEY_OP_ACCOUNT_URL=%q\nSSH_KEY_OP_ITEM_ID=%q\nDOTFILES_REPO_SSH_URL=%q\n' \
  "$ssh_key_op_account_url" "$ssh_key_op_item_id" "$dotfiles_repo_ssh_url" \
  | /usr/bin/openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -a -A -pass env:BOOTSTRAP_PASS)"

# Sanity-check the round-trip before touching bootstrap.sh.
if ! printf '%s\n' "$blob" | /usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -a \
  -pass env:BOOTSTRAP_PASS >/dev/null 2>&1; then
  unset BOOTSTRAP_PASS bootstrap_pass bootstrap_pass2
  echo "!!! Self-check failed; $target left unchanged." >&2; exit 1
fi
unset BOOTSTRAP_PASS bootstrap_pass bootstrap_pass2

# Replace the single-line SECRETS_ENC='...' assignment via regex. base64 contains
# no '|', '&', or '\', so a '|'-delimited sed substitution is safe.
sed -i '' "s|^SECRETS_ENC=.*|SECRETS_ENC='${blob}'|" "$target"
grep -qF "SECRETS_ENC='${blob}'" "$target" \
  || { echo "!!! Failed to update SECRETS_ENC in $target." >&2; exit 1; }

echo
echo ">> Wrote SECRETS_ENC to $target ($(printf '%s' "$blob" | wc -c | tr -d ' ') base64 chars)."
echo ">> Verify by running ./$target (it will prompt for the passphrase and decrypt)."
