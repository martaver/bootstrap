# bootstrap

One-line bootstrap for a fresh macOS machine. Installs 1Password, waits for you to sign in
and enable the SSH agent, then clones the private `dotfiles` repo over SSH and runs its
`setup.sh`.

## Usage

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/martaver/bootstrap/main/bootstrap.sh)"
```

You'll be prompted for the **bootstrap passphrase**, which decrypts the embedded identifiers
(1Password account, SSH-key item id, dotfiles repo URL). This is the one secret you carry to
a fresh machine — everything else is pulled from 1Password after you sign in.

## Prerequisites

- The 1Password Item's SSH **public** key must be registered on the GitHub account that owns the
  private `dotfiles` repo (the bootstrap can't do this headlessly).

## Regenerating the encrypted blob

The identifiers live in `bootstrap.sh` as a single-line AES-256 blob (`SECRETS_ENC`).

To set `SECRETS_ENC` to your own values, run `./encrypt-secrets.sh` and follow the prompts.

`openssl` prompts (twice, to confirm) for the **bootstrap passphrase** on the terminal.

Remember this passphrase and use it when bootstrapping a new machine.