#!/usr/bin/env bash
# Read-only check of the Ubuntu side. Changes nothing. One line per check:
#
#   PASS <check>: <what was found>
#   FAIL <check>: <what was found>
#   SKIP <check>: <why>            (needs root and neither root nor `sudo -n` is available)
#   SUMMARY pass=N fail=N skip=N   (last line)
#
# Exit status: 0 if nothing failed, 1 otherwise, 2 for a usage error (printed as `FAIL usage: ...`).
# SKIP does not fail the run unless --strict is given.
#
#   bash verify.sh [--owner USER] [--iface IFACE] [--profile PROFILE] [--account NAME] [--from NETWORKS] [--strict]
#
# Without arguments the values come from the owner's ~/.config/claude-collab/config, written by
# install-collab.sh. An argument overrides the file.
#
#   --owner    account that owns ~/claude-collab, the skill and the config file. Default: the
#              calling user (the sudo caller under sudo). Example: owner
#   --iface    wired interface with Wake-on-LAN. Default: WOL_IFACE of the config file, else the
#              machine's only physical wired interface. Example: IFACE
#   --profile  its NetworkManager profile. Default: WOL_PROFILE, else the profile active on the
#              interface. Example: PROFILE
#   --account  the key-only admin account. Default: ADMIN_ACCOUNT, else claude
#   --from     expected source networks of the admin key. Default: ADMIN_FROM; if neither is set,
#              any from="..." restriction passes. Example: 192.0.2.0/24,198.51.100.0/24
#
# As the owner without sudo, the root-only checks are SKIP. As the admin account (which has
# `sudo -n`) or as root, everything is checked; pass --owner then.
set -uo pipefail
export LC_ALL=C

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "FAIL usage: $1"; exit 2; }

IFACE=""; PROFILE=""; OWNER=""; ACCOUNT=""; FROM=""; STRICT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iface)   IFACE="${2:-}"; shift ;;
        --profile) PROFILE="${2:-}"; shift ;;
        --owner)   OWNER="${2:-}"; shift ;;
        --account) ACCOUNT="${2:-}"; shift ;;
        --from)    FROM="${2:-}"; shift ;;
        --strict)  STRICT=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument $1" ;;
    esac
    shift || true
done
if [[ -z "$OWNER" ]]; then
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then OWNER=$SUDO_USER; else OWNER=$(id -un); fi
fi
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
[[ -n "$OWNER_HOME" ]] || die "unknown owner account: $OWNER"

# Root access, if any: R is the prefix for commands that need it.
if [[ $EUID -eq 0 ]]; then ROOT=1; R=()
elif sudo -n true 2>/dev/null; then ROOT=1; R=(sudo -n)
else ROOT=0; R=(); fi
# Files in the owner's home: read directly when we are the owner, through root otherwise.
if [[ "$(id -un)" == "$OWNER" ]]; then O=(); CAN_OWNER=1
elif [[ $ROOT -eq 1 ]]; then O=("${R[@]}"); CAN_OWNER=1
else O=(); CAN_OWNER=0; fi

# The owner's config file: defaults for what was not given as an argument.
CONF="$OWNER_HOME/.config/claude-collab/config"
CONF_TEXT=""
[[ $CAN_OWNER -eq 1 ]] && CONF_TEXT=$("${O[@]}" cat "$CONF" 2>/dev/null)
cfg_get() { sed -n "s/^$1=//p" <<<"$CONF_TEXT" | head -n 1; }
HOST_NAME=$(cfg_get UBUNTU_HOST)
[[ -n "$IFACE" ]]   || IFACE=$(cfg_get WOL_IFACE)
[[ -n "$PROFILE" ]] || PROFILE=$(cfg_get WOL_PROFILE)
[[ -n "$ACCOUNT" ]] || ACCOUNT=$(cfg_get ADMIN_ACCOUNT)
[[ -n "$ACCOUNT" ]] || ACCOUNT=claude
[[ -n "$FROM" ]]    || FROM=$(cfg_get ADMIN_FROM)
if [[ -z "$IFACE" ]]; then
    cand=()
    for d in /sys/class/net/*; do
        [[ -e "$d/device" && ! -d "$d/wireless" && "$(cat "$d/type" 2>/dev/null)" == 1 ]] && cand+=("${d##*/}")
    done
    [[ ${#cand[@]} -eq 1 ]] || die "no WOL_IFACE in the config file and ${#cand[@]} wired interfaces found (${cand[*]:-none}); give --iface"
    IFACE=${cand[0]}
fi
[[ "$IFACE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid interface name"
[[ "$ACCOUNT" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid account name"

pass=0; fail=0; skip=0
PASS() { echo "PASS $1: $2"; pass=$((pass+1)); }
FAIL() { echo "FAIL $1: $2"; fail=$((fail+1)); }
SKIP() { echo "SKIP $1: $2"; skip=$((skip+1)); }
oneline() { tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//'; }

# {{KEY}} -> value, exactly as install-collab.sh renders a template.
render() {
    local s k v
    s=$(<"$1")
    for k in UBUNTU_HOST WOL_IFACE WOL_PROFILE ADMIN_ACCOUNT ADMIN_FROM; do v=$(cfg_get "$k"); s=${s//"{{$k}}"/"${v:-(not set)}"}; done
    s=${s//"{{OWNER}}"/"$OWNER"}
    printf '%s\n' "$s"
}

HERE=$(cd "$(dirname "$0")" && pwd)
DIR="$OWNER_HOME/claude-collab"
SKILL="$OWNER_HOME/.claude/skills/collab"

# ---- config file, shared folder and skill -----------------------------------------------
if [[ $CAN_OWNER -eq 0 ]]; then
    for c in config folder notes skill skill-current; do SKIP "$c" "cannot read $OWNER's home as $(id -un) without root"; done
else
    if [[ -n "$HOST_NAME" && -n "$(cfg_get WOL_IFACE)" ]]; then PASS config "$CONF has UBUNTU_HOST and WOL_IFACE"
    elif [[ -z "$CONF_TEXT" ]]; then FAIL config "$CONF is missing or empty (run install-collab.sh)"
    else FAIL config "$CONF lacks UBUNTU_HOST or WOL_IFACE (run install-collab.sh)"; fi

    if "${O[@]}" test -d "$DIR"; then PASS folder "$DIR exists"; else FAIL folder "$DIR is missing"; fi

    missing=""
    for f in from-windows.md from-ubuntu.md; do "${O[@]}" test -f "$DIR/$f" || missing+=" $f"; done
    if [[ -z "$missing" ]]; then PASS notes "from-windows.md and from-ubuntu.md exist"; else FAIL notes "missing in $DIR:$missing"; fi

    missing=""
    for f in SKILL.md reference.md watch.sh; do "${O[@]}" test -s "$SKILL/$f" || missing+=" $f"; done
    "${O[@]}" test -x "$SKILL/watch.sh" || missing+=" (watch.sh not executable)"
    if [[ -z "$missing" ]]; then PASS skill "$SKILL has SKILL.md, reference.md, executable watch.sh"; else FAIL skill "$SKILL:$missing"; fi

    # Installed skill against the template next to this script, rendered with the config values
    # (only when run from the repository tree). reference.md is local and is not compared.
    if [[ -f "$HERE/../skill/SKILL.template.md" && -f "$HERE/../skill/watch.sh" ]]; then
        differ=""
        render "$HERE/../skill/SKILL.template.md" | "${O[@]}" cmp -s - "$SKILL/SKILL.md" || differ+=" SKILL.md"
        "${O[@]}" cmp -s "$SKILL/watch.sh" "$HERE/../skill/watch.sh" || differ+=" watch.sh"
        if [[ -z "$CONF_TEXT" ]]; then FAIL skill-current "no config file to render the template with"
        elif [[ -z "$differ" ]]; then PASS skill-current "installed SKILL.md equals the rendered template, watch.sh equals the repository copy"
        else FAIL skill-current "installed copy differs from the repository:$differ (run install-collab.sh)"; fi
    else
        SKIP skill-current "no ../skill next to this script to compare with"
    fi
fi

# ---- Wake-on-LAN --------------------------------------------------------------------------
if [[ -e "/sys/class/net/$IFACE" ]]; then
    PASS wol-interface "$IFACE exists, MAC $(cat "/sys/class/net/$IFACE/address" 2>/dev/null), link $(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null)"
else
    FAIL wol-interface "$IFACE does not exist"
fi

if ! command -v nmcli >/dev/null; then
    FAIL wol-profile "nmcli not found"
else
    [[ -n "$PROFILE" ]] || PROFILE=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null)
    if [[ -z "$PROFILE" ]]; then
        FAIL wol-profile "no active NetworkManager profile on $IFACE (give --profile)"
    else
        v=$(nmcli -g 802-3-ethernet.wake-on-lan connection show "$PROFILE" 2>/dev/null | oneline)
        if [[ "$v" == magic ]]; then PASS wol-profile "profile $PROFILE has wake-on-lan = magic"
        else FAIL wol-profile "profile $PROFILE has wake-on-lan = '${v:-not readable}', expected magic"; fi
    fi
fi

v=$(cat "/sys/class/net/$IFACE/device/power/wakeup" 2>/dev/null)
if [[ "$v" == enabled ]]; then PASS wol-device-wakeup "device wakeup is enabled"
else FAIL wol-device-wakeup "device wakeup is '${v:-not readable}', expected enabled"; fi

if [[ $ROOT -eq 0 ]]; then
    SKIP wol-adapter "ethtool needs root"
elif ! command -v ethtool >/dev/null; then
    FAIL wol-adapter "ethtool not installed"
else
    v=$("${R[@]}" ethtool "$IFACE" 2>/dev/null | grep -E '^[[:space:]]*Wake-on:' | oneline)
    if [[ "$v" =~ ^Wake-on:.*g ]]; then PASS wol-adapter "$v"; else FAIL wol-adapter "'${v:-no Wake-on line}', expected Wake-on: g"; fi
fi

# ---- admin account ------------------------------------------------------------------------
SUDOERS="/etc/sudoers.d/90-$ACCOUNT-admin"
ent=$(getent passwd "$ACCOUNT")
if [[ -n "$ent" ]]; then
    PASS admin-account "$ACCOUNT exists (uid $(cut -d: -f3 <<<"$ent"), comment '$(cut -d: -f5 <<<"$ent")')"
    ADMIN_HOME=$(cut -d: -f6 <<<"$ent")
else
    FAIL admin-account "$ACCOUNT does not exist"
    ADMIN_HOME=""
fi

if [[ $ROOT -eq 0 ]]; then
    SKIP admin-password-locked "passwd -S needs root"
elif [[ -z "$ent" ]]; then
    FAIL admin-password-locked "no account"
else
    v=$("${R[@]}" passwd -S "$ACCOUNT" 2>/dev/null | awk '{print $2}')
    if [[ "$v" == L* ]]; then PASS admin-password-locked "password status $v (key login only)"
    else FAIL admin-password-locked "password status '${v:-unknown}', expected L"; fi
fi

v=$(stat -c '%a %U:%G' "$SUDOERS" 2>/dev/null)
if [[ "$v" == "440 root:root" ]]; then PASS admin-sudoers-file "$SUDOERS is $v"
elif [[ -z "$v" ]]; then FAIL admin-sudoers-file "$SUDOERS is missing"
else FAIL admin-sudoers-file "$SUDOERS is $v, expected 440 root:root"; fi

if [[ $ROOT -eq 0 ]]; then
    SKIP admin-sudoers-rule "reading $SUDOERS needs root"
else
    v=$("${R[@]}" grep -v '^[[:space:]]*\(#\|$\)' "$SUDOERS" 2>/dev/null | oneline)
    if [[ "$v" == "$ACCOUNT ALL=(ALL:ALL) NOPASSWD: ALL" ]]; then PASS admin-sudoers-rule "$v"
    else FAIL admin-sudoers-rule "'${v:-not readable}', expected '$ACCOUNT ALL=(ALL:ALL) NOPASSWD: ALL'"; fi
fi

if [[ $ROOT -eq 0 && "$(id -un)" != "$ACCOUNT" ]]; then
    SKIP admin-key "reading the account's authorized_keys needs root"
elif [[ -z "$ADMIN_HOME" ]]; then
    FAIL admin-key "no account"
else
    AK="$ADMIN_HOME/.ssh/authorized_keys"
    [[ "$(id -un)" == "$ACCOUNT" ]] && K=() || K=("${R[@]}")
    lines=$("${K[@]}" grep -v '^[[:space:]]*\(#\|$\)' "$AK" 2>/dev/null)
    n=$(grep -c . <<<"$lines")
    opt=$(sed -n 's/^from="\([^"]*\)" .*/\1/p' <<<"$lines")
    perm=$("${K[@]}" stat -c '%a' "$AK" 2>/dev/null)
    # Only the restriction and the key type are printed, never the key itself.
    if [[ -z "$lines" ]]; then FAIL admin-key "$AK is missing or empty"
    elif [[ "$n" -ne 1 ]]; then FAIL admin-key "$n keys in authorized_keys, expected exactly 1"
    elif [[ -z "$opt" ]]; then FAIL admin-key "the key has no from=\"...\" restriction"
    elif [[ -n "$FROM" && "$opt" != "$FROM" ]]; then FAIL admin-key "restricted to from=\"$opt\", expected \"$FROM\""
    elif [[ "$perm" != 600 ]]; then FAIL admin-key "authorized_keys has mode $perm, expected 600"
    else PASS admin-key "1 key, restricted to from=\"$opt\", file mode 600"; fi
fi

# ---- SSH server -----------------------------------------------------------------------------
if ss -ltn 2>/dev/null | grep -Eq '[:.]22[[:space:]]'; then PASS sshd-listening "a service listens on TCP port 22"
else FAIL sshd-listening "nothing listens on TCP port 22"; fi

echo "SUMMARY pass=$pass fail=$fail skip=$skip"
if [[ $fail -gt 0 || ( $STRICT -eq 1 && $skip -gt 0 ) ]]; then exit 1; fi
exit 0
