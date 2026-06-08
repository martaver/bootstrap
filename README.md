# bootstrap

One-line bootstrap for a fresh macOS machine. Installs 1Password, waits for you to sign in
and enable the SSH agent, then clones the private `dotfiles` repo over SSH and runs its
`setup.sh`.

## Usage

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/martaver/bootstrap/main/bootstrap.sh)"
```

You'll be prompted for the **bootstrap passphrase**, which decrypts the embedded identifiers
(1Password account, SSH-key item id, dotfiles repo URL, transcrypt passphrase reference +
account). This is the one secret you carry to a fresh machine — everything else is pulled from
1Password after you sign in.

## Prerequisites

- The 1Password Item's SSH **public** key must be registered on the GitHub account that owns the
  private `dotfiles` repo (the bootstrap can't do this headlessly).

## Editing the encrypted identifiers

The identifiers live in `bootstrap.sh` as a single-line AES-256 blob (`SECRETS_ENCODED`).
The blob is **push-only** — you maintain the values in a local, gitignored `.env` file and
encode them in; there's no decode step. Seed `.env` from the committed template:

```sh
cp .env.tpl .env     # one KEY=value per line; keep values simple/unquoted
$EDITOR .env         # fill in the <placeholder> values
./secrets-write.sh   # encode .env -> SECRETS_ENCODED (prompts for the passphrase, twice)
```

`.env` holds your secrets in cleartext — it's gitignored; never commit it (keep it as your
source of truth). `.env.tpl` is the committed, placeholder-only template. `secrets-write.sh`
round-trip-checks the blob before writing and leaves `bootstrap.sh` untouched on failure;
verify with `./bootstrap.sh`, which decrypts the blob and echoes the identifiers.

Remember the **bootstrap passphrase** — it's the one secret you type when bootstrapping a new
machine, and it must match what `secrets-write.sh` encrypted with.