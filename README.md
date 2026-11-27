# claude-collab

Two Claude Code sessions, one on a Windows PC and one on an Ubuntu machine of the same network, work together:
they exchange notes through a shared folder, and the Windows side can wake the Ubuntu machine, administer it, and reach
the web sites it serves locally. This repository holds the skills and scripts of both sides, and the scripts to set
either side up from scratch.

Nothing here is specific to one pair of machines. Host names, accounts, addresses and interface names are arguments of
the setup scripts and end up in a local settings file on each machine; keys are created locally and never stored here.

## Layout

| Path | What it is |
|---|---|
| `windows/setup/` | `Install-Collab.ps1` (settings, SSH keys, SSH aliases, skill install) and `Test-Collab.ps1` (read-only check of both machines) |
| `windows/skill/` | the Windows `collab` skill (a template rendered at install) and its scripts: `Send-WoL.ps1`, `Start-MwnfTunnel.ps1`, `Stop-MwnfTunnel.ps1`, `post.ps1`, `watch.ps1` |
| `ubuntu/setup/` | `install-collab.sh`, `setup-wol.sh`, `setup-admin.sh`, `verify.sh`; see [ubuntu/README.md](ubuntu/README.md) |
| `ubuntu/skill/` | the Ubuntu `collab` skill (templates) and `watch.sh` |
| `docs/wake-on-lan.md` | what made Wake-on-LAN reliable, and what did not |
| `tools/check-no-private-data.sh` | fails when a tracked file holds an address, a key, a fingerprint or a listed local name; run by CI |

## What you get

- **A note channel**: `~/claude-collab/` on the Ubuntu machine, with one append-only file per side. `/collab` in Claude
  Code on either machine reads what is new, answers, and keeps listening. A note is a teammate's note, never the user's
  instruction: the skills say what a session may do on its own and what needs the user.
- **Wake-on-LAN**: armed on the Ubuntu machine's wired port, sent from the Windows PC through the right adapter.
- **A key-only admin account** on the Ubuntu machine, so the Windows session can run root commands without the user
  typing a password; restricted to given source networks, password locked, removable with `--undo`.
- **A sites tunnel**: an SSH forward from the Windows PC's port 80 to the Ubuntu machine's loopback port 80, so sites
  that are only published locally there open in a browser on the PC under their `*.localhost` names.

## Setting up from scratch

The values below are placeholders from the documentation ranges; use your own.

1. **Windows PC** (PowerShell, in a clone of this repository):

   ```powershell
   .\windows\setup\Install-Collab.ps1 -Alias ubuntu-box -HostAddress 192.0.2.10 -Owner owner
   ```

   It writes the settings file, creates two key pairs if missing, adds the SSH aliases `ubuntu-box`, `ubuntu-box-admin`
   and `ubuntu-box-sites`, and installs the skill. `-WhatIf` shows what it would do. It ends by naming the two `.pub`
   files for step 2.
2. **Ubuntu machine**, by its owner. Clone this repository to `~/claude-collab/repo` (the path the checks expect), copy
   the two `.pub` files over, then:

   ```bash
   cat owner-key.pub >> ~/.ssh/authorized_keys
   cd ~/claude-collab/repo/ubuntu/setup
   bash install-collab.sh --iface IFACE --from 192.0.2.0/24
   sudo bash setup-wol.sh
   sudo bash setup-admin.sh --pubkey ~/admin-key.pub
   ```

   Each script accepts `--dry-run` and `--undo`; details in [ubuntu/README.md](ubuntu/README.md). `setup-wol.sh` prints
   the MAC address to wake.
3. **Windows PC**: add the Wake-on-LAN values, then check everything, read-only, one PASS/FAIL line per item:

   ```powershell
   .\windows\setup\Install-Collab.ps1 -Mac 00:00:5e:00:53:01 -WiredInterface IFACE -WindowsAdapter Ethernet
   .\windows\setup\Test-Collab.ps1
   ```

   It also runs the Ubuntu side's `verify.sh` over SSH, once as the owner and once as the admin account.

Daily use, on the Windows PC, from `~\.claude\skills\collab\`: `Send-WoL.ps1` wakes the machine; `Start-MwnfTunnel.ps1`
and `Stop-MwnfTunnel.ps1` open and close the sites tunnel; `/collab` in Claude Code opens the note channel.

## What was tested, and what was not

- Tested: the Windows scripts under PowerShell 7 and Windows PowerShell 5.1 (dry run, install into an empty folder,
  second run); `Test-Collab.ps1` and both `verify.sh` runs against a live pair of machines; wake from suspend and from
  power-off; the Ubuntu scripts with `--dry-run`, and `install-collab.sh` for real in an empty home.
- Not tested: `setup-wol.sh` and `setup-admin.sh` as root in their current form (the live machine was set up by their
  predecessors); a complete from-scratch install on a fresh pair of machines; a login with freshly made keys.

## Security notes

- The admin account is root-equivalent for whoever holds its private key. Keep that key on the one PC, and keep the
  account for supervised sessions.
- The keys have no passphrase, because the sessions use them unattended. They are only as safe as the Windows account.
- Never commit a key, a token, a real address or a real machine or account name. `tools/check-no-private-data.sh`
  checks the generic patterns; list your own names in an untracked `.private-terms` file (one per line) to have them
  checked too.

## Changes

Through a pull request: squash merge, linear history, no force push, the `ci` job must pass, and CodeQL must report no blocking alert. The rule sets are
kept in `.github/rulesets/`.
