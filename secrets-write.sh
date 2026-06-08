#!/usr/bin/env bash
set -euo pipefail

# Encode the local .env file into bootstrap.sh's SECRETS_ENCODED blob. Seed .env from
# the committed template first (cp .env.tpl .env, then fill in the values). The blob is
# push-only — there's no decode step, so keep .env as your editable source of truth.
# Prompts for the bootstrap passphrase twice (a typo would make the blob undecryptable).
# No plaintext is written to disk — the .env bytes are piped straight into openssl.
# Pins the system openssl (LibreSSL).

cd "$(dirname "$0")"
readonly target="bootstrap.sh"
readonly envfile=".env"
[[ -f "$target" ]]  || { echo "!!! $target not found next to this script." >&2; exit 1; }
[[ -f "$envfile" ]] || { echo "!!! $envfile not found — seed it with: cp .env.tpl .env && \$EDITOR .env" >&2; exit 1; }
# Refuse to encode unfilled template placeholders (e.g. the <...> from .env.tpl).
if grep -q '<.*>' "$envfile"; then
  echo "!!! $envfile still contains <placeholder> values — fill them in before encoding." >&2; exit 1
fi

read -rs -p "Bootstrap passphrase: " BOOTSTRAP_PASS;  echo
read -rs -p "Confirm passphrase:   " bootstrap_pass2; echo
[[ -n "$BOOTSTRAP_PASS" ]]                     || { echo "!!! Empty passphrase." >&2; exit 1; }
[[ "$BOOTSTRAP_PASS" == "$bootstrap_pass2" ]]  || { echo "!!! Passphrases don't match." >&2; exit 1; }
unset bootstrap_pass2
export BOOTSTRAP_PASS   # via env, not pass:<value>, so it's not in `ps` argv

# Encrypt the .env bytes verbatim into a single-line base64 blob (-A keeps it one line).
blob="$(/usr/bin/openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -a -A \
  -pass env:BOOTSTRAP_PASS -in "$envfile")"

# Round-trip self-check before touching bootstrap.sh.
if ! printf '%s\n' "$blob" | /usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -a \
  -pass env:BOOTSTRAP_PASS >/dev/null 2>&1; then
  unset BOOTSTRAP_PASS
  echo "!!! Self-check failed; $target left unchanged." >&2; exit 1
fi
unset BOOTSTRAP_PASS

# Replace the single-line SECRETS_ENCODED='...' assignment. base64 contains no '|',
# '&' or '\', so a '|'-delimited sed substitution is safe.
sed -i '' "s|^SECRETS_ENCODED=.*|SECRETS_ENCODED='${blob}'|" "$target"
grep -qF "SECRETS_ENCODED='${blob}'" "$target" \
  || { echo "!!! Failed to update SECRETS_ENCODED in $target." >&2; exit 1; }

echo ">> Wrote SECRETS_ENCODED to $target ($(printf '%s' "$blob" | wc -c | tr -d ' ') base64 chars)."
echo ">> Verify by running ./$target (it decrypts the blob and echoes the identifiers)."
