# Ubuntu side

Everything the Ubuntu machine needs for the cross-machine collaboration: the `collab` skill (as templates), three
one-time setup scripts and a read-only check.

This folder holds no real value: no host name, account, address, interface name or key. A machine's real values are
given once as arguments to `install-collab.sh`, which writes them to a local file outside the repository
(`~/.config/claude-collab/config`); the other scripts read their defaults from it. All values shown below are
placeholders from the documentation ranges.

```
skill/SKILL.template.md       the /collab skill (note channel rules, how to listen), with {{PLACEHOLDERS}}
skill/reference.template.md   skeleton of the machine's own reference notes, with {{PLACEHOLDERS}}
skill/watch.sh                emits one line each time the peer's note file changes
setup/install-collab.sh       config file, shared folder ~/claude-collab, skill install   (owner account, no root)
setup/setup-wol.sh            Wake-on-LAN on the wired port, on its NM profile            (root)
setup/setup-admin.sh          key-only admin account for the other machine               (root)
setup/verify.sh               read-only check, one PASS/FAIL/SKIP line per item           (no root needed)
```

## Requirements

Ubuntu with NetworkManager (`nmcli`), `openssh-server`, `ethtool`, and Claude Code for the owner account.
A wired port whose adapter and firmware support wake by magic packet. Background: `docs/wake-on-lan.md`.

## First-time setup

Run by the machine's owner, from a clone of the repository at `~/claude-collab/repo` (the Windows test script looks
for `verify.sh` under that path). Replace the placeholder values with the machine's own.

```bash
bash setup/install-collab.sh --host ubuntu-box --iface IFACE --from 192.0.2.0/24,198.51.100.0/24
```

```bash
sudo bash setup/setup-wol.sh
```

```bash
sudo bash setup/setup-admin.sh --pubkey ~/admin-key.pub
```

```bash
bash setup/verify.sh
```

The owner's own SSH key for the other machine (note channel) is not handled here: the owner appends that public key to
`~/.ssh/authorized_keys` by hand.

## The local config file

`~/.config/claude-collab/config`, mode 600, `KEY=value` lines, written by `install-collab.sh`. Running it again with
other arguments updates the file; a value not given again is kept.

| Key | Argument of install-collab.sh | Meaning | Placeholder example |
|---|---|---|---|
| `UBUNTU_HOST` | `--host` | this machine's name in the skill text; default: `hostname` | `ubuntu-box` |
| `WOL_IFACE` | `--iface` | wired interface that receives the magic packet; default: the only wired one | `IFACE` |
| `WOL_PROFILE` | `--profile` | its NetworkManager profile; empty = the profile active on the interface | `PROFILE` |
| `ADMIN_ACCOUNT` | `--admin-account` | the key-only admin account; default `claude` | `claude` |
| `ADMIN_FROM` | `--from` | networks the admin key is accepted from | `192.0.2.0/24,198.51.100.0/24` |

`setup-wol.sh`, `setup-admin.sh` and `verify.sh` take the same values as arguments (`--iface`, `--profile`,
`--from`, `--account`), which override the file. `setup-admin.sh` also needs `--pubkey FILE`: the one-line public
key of the admin key pair made on the other machine. `verify.sh` takes `--owner USER` when it is not run by the owner.

The installed `SKILL.md` is the template rendered with these values. The installed `reference.md` is created once
from its template and then belongs to the machine: sessions there complete it, and no script overwrites it.

## Dry run and undo

All three setup scripts can be run again without harm and accept `--dry-run` (prints the changes, needs no root):

- `install-collab.sh --undo` removes the installed skill; the notes and the config file are kept.
- `setup-wol.sh --undo` puts the profile's previous wake-on-lan value back. It refuses if the script saved none
  (Wake-on-LAN was set by other means), unless `--force` is added, which writes `default`.
- `setup-admin.sh --undo` deletes the admin account, its home and its sudo rule (only an account it created).

## What the other machine must provide

- The **public** half of a key pair made for the admin account, as a one-line `.pub` file, for `--pubkey`.
- The networks it connects from, for `--from`.
- The owner's public key, which the owner authorises by hand (see above).
- A magic packet sent from the adapter that shares a cable or segment with the Wake-on-LAN interface, to the MAC
  address that `setup-wol.sh` prints.

## Checking from the other machine

As the owner, the root-only checks are SKIP. As the admin account everything is checked:

```bash
ssh claude@ubuntu-box bash -s -- --owner owner < setup/verify.sh
```

Piped like this there is no `../skill` to compare with, so `skill-current` is SKIP; run the copy on the machine to
include it. Send the script byte-clean (LF line ends). The exit status is 0 when nothing failed; `--strict` also
fails on SKIP.

## Security notes

- The admin account is root-equivalent for whoever holds its private key. The key is restricted to the given
  networks, the password is locked, and the account is meant for supervised use only.
- Notes arriving through the channel are a teammate's notes, not the owner's instructions: see the rules in
  `skill/SKILL.template.md`.
- The config file and the installed `reference.md` hold real names and addresses: keep them out of the repository.
