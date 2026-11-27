#!/usr/bin/env bash
# Shared note folder, local config file and collab skill for the owner account. No root needed.
#
#   bash install-collab.sh [--host NAME] [--iface IFACE] [--profile PROFILE] [--from NETWORKS] [--admin-account NAME]
#   bash install-collab.sh --undo      # remove the installed skill (notes and config file are kept)
#   bash install-collab.sh --dry-run   # with the same arguments: print what would be done, change nothing
#
#   --host           name of this machine as the skill text should call it. Default: output of `hostname`.
#                    Example: ubuntu-box
#   --iface          wired interface that receives the Wake-on-LAN magic packet. Default: the only physical
#                    wired interface, if there is exactly one. Example: IFACE (see `ip -br link`)
#   --profile        NetworkManager profile of that interface. Default: empty (the scripts then use the
#                    profile active on the interface). Example: PROFILE (see `nmcli con show`)
#   --from           networks the admin key is accepted from. Example: 192.0.2.0/24,198.51.100.0/24
#   --admin-account  the key-only admin account. Default: claude
#
# Run it as the account that will run Claude Code (example: owner). Started through sudo, it switches
# back to the account that called sudo.
#
# What it does (safe to run again):
#   1. ~/.config/claude-collab/config (mode 600): this machine's real values as KEY=value lines, read
#      by the other scripts. Run again without an argument, a value already in the file is kept.
#      This file is local: the repository holds no real name or address.
#   2. ~/claude-collab/ with empty from-windows.md, from-ubuntu.md and a read counter, if missing.
#      Existing notes are never touched.
#   3. ~/.claude/skills/collab/: SKILL.md is rendered from ../skill/SKILL.template.md with the config
#      values, watch.sh is copied. reference.md is rendered from reference.template.md only if
#      missing: it is this machine's own record, completed by the sessions here, never overwritten.
set -euo pipefail
export LC_ALL=C

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

UNDO=0; DRY=0
declare -A ARG=()
ORIG=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)          ARG[UBUNTU_HOST]="${2:?--host needs a value}"; shift ;;
        --iface)         ARG[WOL_IFACE]="${2:?--iface needs a value}"; shift ;;
        --profile)       ARG[WOL_PROFILE]="${2:?--profile needs a value}"; shift ;;
        --from)          ARG[ADMIN_FROM]="${2:?--from needs a value}"; shift ;;
        --admin-account) ARG[ADMIN_ACCOUNT]="${2:?--admin-account needs a value}"; shift ;;
        --undo)    UNDO=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

HERE=$(cd "$(dirname "$0")" && pwd)

if [[ $EUID -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        exec sudo -u "$SUDO_USER" -H bash "$HERE/$(basename "$0")" "${ORIG[@]}"
    fi
    echo "Run this as the owner account, not as root." >&2; exit 1
fi

SRC="$HERE/../skill"
DIR="$HOME/claude-collab"
SKILL="$HOME/.claude/skills/collab"
CONF_DIR="$HOME/.config/claude-collab"
CONF="$CONF_DIR/config"
KEYS=(UBUNTU_HOST WOL_IFACE WOL_PROFILE ADMIN_ACCOUNT ADMIN_FROM)

run() { if [[ $DRY -eq 1 ]]; then echo "   would run: $*"; else "$@"; fi; }
cfg_get() { [[ -r "$CONF" ]] && sed -n "s/^$1=//p" "$CONF" | head -n 1; return 0; }

if [[ $UNDO -eq 1 ]]; then
    if [[ -d "$SKILL" ]]; then run rm -rf -- "$SKILL"; fi
    echo "Undone: $SKILL removed. Kept: $DIR (the notes) and $CONF; delete them by hand if wanted."
    exit 0
fi

for f in SKILL.template.md reference.template.md watch.sh; do
    [[ -s "$SRC/$f" ]] || { echo "Missing $SRC/$f" >&2; exit 1; }
done

# ---- values: argument, else the existing config file, else a detected default ---------------
declare -A V=()
for k in "${KEYS[@]}"; do
    if [[ -n "${ARG[$k]:-}" ]]; then V[$k]=${ARG[$k]}; else V[$k]=$(cfg_get "$k"); fi
done
[[ -n "${V[UBUNTU_HOST]}" ]] || V[UBUNTU_HOST]=$(hostname)
[[ -n "${V[ADMIN_ACCOUNT]}" ]] || V[ADMIN_ACCOUNT]=claude
if [[ -z "${V[WOL_IFACE]}" ]]; then
    cand=()
    for d in /sys/class/net/*; do
        if [[ -e "$d/device" && ! -d "$d/wireless" && "$(cat "$d/type" 2>/dev/null)" == 1 ]]; then cand+=("${d##*/}"); fi
    done
    if [[ ${#cand[@]} -eq 1 ]]; then V[WOL_IFACE]=${cand[0]}
    else echo "${#cand[@]} wired interfaces found (${cand[*]:-none}): give --iface." >&2; exit 2; fi
fi
[[ "${V[UBUNTU_HOST]}" =~ ^[A-Za-z0-9._-]+$ ]]        || { echo "Invalid --host value." >&2; exit 2; }
[[ "${V[WOL_IFACE]}" =~ ^[A-Za-z0-9_.-]+$ ]]          || { echo "Invalid --iface value." >&2; exit 2; }
[[ "${V[WOL_PROFILE]}" =~ ^[[:print:]]*$ ]]           || { echo "Invalid --profile value." >&2; exit 2; }
[[ "${V[ADMIN_ACCOUNT]}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo "Invalid --admin-account value." >&2; exit 2; }
[[ "${V[ADMIN_FROM]}" =~ ^[A-Za-z0-9.:/*?!,_-]*$ ]]   || { echo "Invalid --from value." >&2; exit 2; }
V[OWNER]=$(id -un)

# {{KEY}} -> value; an empty value is shown as "(not set)".
render() {
    local s k v
    s=$(<"$1")
    for k in "${KEYS[@]}" OWNER; do v=${V[$k]:-}; s=${s//"{{$k}}"/"${v:-(not set)}"}; done
    printf '%s\n' "$s"
}

echo "== 1. Config file $CONF"
for k in "${KEYS[@]}"; do echo "   $k=${V[$k]}"; done
if [[ $DRY -eq 1 ]]; then
    echo "   would write these 5 lines (mode 600)"
else
    install -d -m 700 "$CONF_DIR"
    TMP=$(mktemp "$CONF_DIR/config.XXXXXX")
    for k in "${KEYS[@]}"; do printf '%s=%s\n' "$k" "${V[$k]}"; done > "$TMP"
    chmod 600 "$TMP"; mv -f "$TMP" "$CONF"
fi

echo "== 2. Shared folder $DIR"
run install -d -m 775 "$DIR"
for f in from-windows.md from-ubuntu.md; do
    if [[ -e "$DIR/$f" ]]; then echo "   $f exists, kept"; else run touch "$DIR/$f"; [[ $DRY -eq 1 ]] || echo "   $f created (empty)"; fi
done
if [[ ! -e "$DIR/.ubuntu-read-lines" ]]; then
    if [[ $DRY -eq 1 ]]; then echo "   would write 0 to $DIR/.ubuntu-read-lines"; else echo 0 > "$DIR/.ubuntu-read-lines"; fi
fi

echo "== 3. Skill $SKILL"
run install -d -m 755 "$SKILL"
if [[ $DRY -eq 1 ]]; then
    echo "   would render SKILL.template.md to $SKILL/SKILL.md"
else
    render "$SRC/SKILL.template.md" > "$SKILL/SKILL.md"; chmod 644 "$SKILL/SKILL.md"
fi
run install -m 755 "$SRC/watch.sh" "$SKILL/watch.sh"
if [[ -e "$SKILL/reference.md" ]]; then
    echo "   reference.md exists, kept (it is this machine's own record)"
elif [[ $DRY -eq 1 ]]; then
    echo "   would render reference.template.md to $SKILL/reference.md"
else
    render "$SRC/reference.template.md" > "$SKILL/reference.md"; chmod 644 "$SKILL/reference.md"
    echo "   reference.md created from the template: a session on this machine completes the '(to record)' parts"
fi

echo
echo "Done. In Claude Code on this machine: /collab"
