#!/usr/bin/env bash
# Key-only admin account for the Claude Code session on the other machine. Run as root:
#
#   sudo bash setup-admin.sh --pubkey FILE [--from NETWORKS] [--account NAME]   # create / refresh
#   sudo bash setup-admin.sh [--account NAME] --undo                           # remove account + sudo rule
#   bash setup-admin.sh --pubkey FILE [--from NETWORKS] --dry-run              # no root: show what would be done
#
#   --pubkey   file holding exactly ONE SSH public key (the .pub file, never the private key),
#              made on the other machine and copied here by the owner. Example: ~/admin-key.pub
#   --from     comma-separated source networks the key is accepted from (sshd from="..." patterns).
#              Default: ADMIN_FROM of the sudo caller's ~/.config/claude-collab/config (written by
#              install-collab.sh). Example: 192.0.2.0/24,198.51.100.0/24
#   --account  account name. Default: ADMIN_ACCOUNT of that file, else claude
#
# What it does (safe to run again; it rewrites the same three things):
#   1. Account with a locked password: it can log in by SSH key only.
#   2. ~ACCOUNT/.ssh/authorized_keys holding that one key, restricted with from="NETWORKS".
#      Any other key in that file is dropped: to change the key, run again with the new file.
#   3. /etc/sudoers.d/90-ACCOUNT-admin: full sudo without a password.
#
# This account is root-equivalent for whoever holds the private key. Keep the private key on the
# other machine only, and never use the account for anything unattended.
# --undo deletes the account and its home, and only an account this script created.
set -euo pipefail
export LC_ALL=C

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

ACCOUNT=""; PUBKEY_FILE=""; FROM=""; UNDO=0; DRY=0
COMMENT="Claude Code remote admin (key only)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pubkey)  PUBKEY_FILE="${2:?--pubkey needs a value}"; shift ;;
        --from)    FROM="${2:?--from needs a value}"; shift ;;
        --account) ACCOUNT="${2:?--account needs a value}"; shift ;;
        --undo)    UNDO=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Defaults from the owner's local config file (written by install-collab.sh), if there is one.
CONF_USER=${SUDO_USER:-$(id -un)}
CONF="$(getent passwd "$CONF_USER" | cut -d: -f6)/.config/claude-collab/config"
cfg_get() { [[ -r "$CONF" ]] && sed -n "s/^$1=//p" "$CONF" | head -n 1; return 0; }
[[ -n "$ACCOUNT" ]] || ACCOUNT=$(cfg_get ADMIN_ACCOUNT)
[[ -n "$ACCOUNT" ]] || ACCOUNT=claude
[[ -n "$FROM" ]]    || FROM=$(cfg_get ADMIN_FROM)
[[ "$ACCOUNT" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo "Invalid account name: $ACCOUNT" >&2; exit 2; }
[[ "$ACCOUNT" != root ]] || { echo "Not for root." >&2; exit 2; }
SUDOERS="/etc/sudoers.d/90-$ACCOUNT-admin"

TMP=""; trap '[[ -z "$TMP" ]] || rm -f -- "$TMP"' EXIT   # temp files never outlive the script
run() { if [[ $DRY -eq 1 ]]; then echo "   would run: $*"; else "$@"; fi; }
runq() { if [[ $DRY -eq 1 ]]; then echo "   would run: $*"; else "$@" >/dev/null; fi; }   # same, output discarded
ours() { [[ "$(getent passwd "$ACCOUNT" | cut -d: -f5)" == "$COMMENT" ]]; }

if [[ $UNDO -eq 0 ]]; then
    [[ -n "$PUBKEY_FILE" ]] || { echo "--pubkey FILE is required." >&2; exit 2; }
    [[ -n "$FROM" ]] || { echo "No source networks: give --from NETWORKS (e.g. 192.0.2.0/24,198.51.100.0/24), or run install-collab.sh --from first." >&2; exit 2; }
    [[ "$FROM" =~ ^[A-Za-z0-9.:/*?!,_-]+$ ]] || { echo "Invalid --from value: $FROM" >&2; exit 2; }
    [[ -s "$PUBKEY_FILE" ]] || { echo "Missing or empty: $PUBKEY_FILE" >&2; exit 1; }
    ! grep -q 'PRIVATE KEY' "$PUBKEY_FILE" || { echo "$PUBKEY_FILE is a PRIVATE key. Give the .pub file." >&2; exit 1; }
    [[ $(grep -c '[^[:space:]]' "$PUBKEY_FILE") -eq 1 ]] || { echo "$PUBKEY_FILE must hold exactly one key." >&2; exit 1; }
    KEY=$(grep '[^[:space:]]' "$PUBKEY_FILE" | tr -d '\r')
    [[ "$KEY" =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+\ [A-Za-z0-9+/=]+(\ .*)?$ ]] \
        || { echo "$PUBKEY_FILE must start with the key type (no options before the key)." >&2; exit 1; }
    FINGERPRINT=$(ssh-keygen -l -f "$PUBKEY_FILE") || { echo "$PUBKEY_FILE is not a valid public key." >&2; exit 1; }
fi

[[ $DRY -eq 1 || $EUID -eq 0 ]] || { echo "Run with sudo (or add --dry-run)." >&2; exit 1; }

if [[ $UNDO -eq 1 ]]; then
    if id "$ACCOUNT" &>/dev/null; then
        ours || { echo "Account '$ACCOUNT' was not created by this script (comment differs). Nothing removed." >&2; exit 1; }
        run rm -f -- "$SUDOERS"
        run pkill -u "$ACCOUNT" || true
        run userdel -r "$ACCOUNT" || true
    else
        run rm -f -- "$SUDOERS"
    fi
    echo "Undone: account '$ACCOUNT' and $SUDOERS removed."
    exit 0
fi

echo "== 1. Account '$ACCOUNT'"
if id "$ACCOUNT" &>/dev/null; then
    ours || { echo "An account '$ACCOUNT' already exists and was not created by this script. Choose another --account." >&2; exit 1; }
    echo "   exists"
else
    run useradd --create-home --shell /bin/bash --comment "$COMMENT" "$ACCOUNT"
fi
runq passwd --lock "$ACCOUNT"

echo "== 2. SSH key"
if [[ $DRY -eq 1 ]]; then
    echo "   would write ~$ACCOUNT/.ssh/authorized_keys (mode 600) with: from=\"$FROM\" <the key>"
else
    HOME_DIR=$(getent passwd "$ACCOUNT" | cut -d: -f6)
    GROUP=$(id -gn "$ACCOUNT")
    install -d -m 700 -o "$ACCOUNT" -g "$GROUP" "$HOME_DIR/.ssh"
    TMP=$(mktemp)
    printf 'from="%s" %s\n' "$FROM" "$KEY" > "$TMP"
    install -m 600 -o "$ACCOUNT" -g "$GROUP" "$TMP" "$HOME_DIR/.ssh/authorized_keys"
    rm -f "$TMP"
fi
echo "   $FINGERPRINT"
echo "   accepted from: $FROM"

echo "== 3. sudo rule $SUDOERS"
if [[ $DRY -eq 1 ]]; then
    echo "   would write: $ACCOUNT ALL=(ALL:ALL) NOPASSWD: ALL"
else
    TMP=$(mktemp)
    echo "$ACCOUNT ALL=(ALL:ALL) NOPASSWD: ALL" > "$TMP"
    visudo -cf "$TMP" >/dev/null
    install -m 440 -o root -g root "$TMP" "$SUDOERS"
    rm -f "$TMP"
    sudo -l -U "$ACCOUNT" | tail -n 1
fi

echo
echo "Done. Test from the other machine:  ssh -i <private key> $ACCOUNT@<this machine> sudo -n true"
