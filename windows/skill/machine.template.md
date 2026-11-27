# {{ALIAS}} (the user's Ubuntu machine): reference for sessions on the Windows PC

Local notes, never published. Written from the template at install time; fill in and correct as facts are verified.
Date every statement you add, and check before relying on an old one: addresses can change.

## The machine

- Name `{{ALIAS}}`, address for SSH `{{HOST_ADDRESS}}`.
- Wired port `{{WIRED_INTERFACE}}`, MAC `{{MAC}}`: the Wake-on-LAN target. It shares a cable or segment with this PC's
  `{{WINDOWS_ADAPTER}}` adapter.
- (record here: what else the machine is and runs, which addresses answer SSH and which do not)

## Access from this PC

| Alias (`~/.ssh/config`) | Account | Key | Use |
|---|---|---|---|
| `ssh {{ALIAS}}` | `{{OWNER}}` (the user's own; sudo asks their password) | `~/.ssh/{{ALIAS}}_{{OWNER}}` | the shared folder, the user's Claude login and skills |
| `ssh {{ALIAS}}-admin` | `{{ADMIN}}` (key only, password locked, `NOPASSWD: ALL`) | `~/.ssh/{{ALIAS}}_{{ADMIN}}` | root: `ssh {{ALIAS}}-admin "sudo -n <cmd>"` |
| `ssh -N {{ALIAS}}-sites` | `{{OWNER}}` | same as the first | tunnel: this PC's port 80 to the machine's `127.0.0.1:80` |

- The admin key is accepted only from the networks given to the Ubuntu side's `setup-admin.sh --from`.
- The admin account exists so the user need not type a sudo password each time; this app's permission prompts are the
  confirmation step. Read-only `sudo -n` checks are fine; confirm with the user before destructive or hard-to-reverse
  commands (deleting data, changing accounts/keys/sudoers/SSH/firewall, suspend, reboot, power-off).
- Undo of the admin account, on the machine: `sudo bash ~/claude-collab/repo/ubuntu/setup/setup-admin.sh --undo`.

## Wake-on-LAN

- Send: `& $env:USERPROFILE\.claude\skills\collab\Send-WoL.ps1`. The packet must leave through the `{{WINDOWS_ADAPTER}}`
  adapter (the script binds to its address); a packet sent through another adapter never reaches the wired port.
- The setting lives on the machine's NetworkManager profile of `{{WIRED_INTERFACE}}` (`802-3-ethernet.wake-on-lan magic`,
  set by the Ubuntu side's `setup-wol.sh`). A one-off `ethtool -s ... wol g` does not survive the next activation.
- Before suspending or powering off remotely, check `ssh {{ALIAS}}-admin "sudo -n ethtool {{WIRED_INTERFACE}} | grep Wake-on:"`
  shows `g`. If it shows `d` the machine cannot be woken remotely and needs its power button.
- (record here: wake from suspend / from power-off tested? how long until ping and SSH answer?)

## Web sites served by the machine

- `Start-MwnfTunnel.ps1` / `Stop-MwnfTunnel.ps1` in this folder: the sites listen on the machine's `127.0.0.1:80` only and
  are selected by host name, so use `http://<site>.<domain>.localhost/` in a browser on this PC while the tunnel is up.
- (record here: where the services live on the machine, how they start, which names exist)

## Ways to reach a Claude session on the machine

1. Start a session from the Claude desktop app with an SSH connection to the machine (wake it first if needed).
2. `ssh -t {{ALIAS}} "screen -DRS collab bash -lc 'claude /collab'"` (detachable). Do not run two listeners at once.
