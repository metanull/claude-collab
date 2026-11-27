#!/usr/bin/env bash
# Fails when a tracked file holds something that must not be published: this repository is public, and every
# machine-specific value belongs in a local settings file, not in the repository.
#
#   bash tools/check-no-private-data.sh          # the tracked files, as they are in the working tree
#
# Generic patterns (always):
#   - IPv4 addresses other than loopback, 0.0.0.0, broadcast and the documentation ranges
#     (192.0.2.x, 198.51.100.x, 203.0.113.x)
#   - MAC addresses other than the documentation range 00:00:5e:00:53:xx and ff:ff:ff:ff:ff:ff
#   - SSH key fingerprints, private or public key material, GitHub and API tokens
#   - e-mail addresses other than no-reply and example ones
# Local terms (only where the file exists): every line of .private-terms at the repository root (untracked) is a
# literal that must not appear: the real host names, account names, interface names. Case-insensitive.
set -uo pipefail
export LC_ALL=C
cd "$(git rev-parse --show-toplevel)" || exit 2

self=tools/check-no-private-data.sh
status=0
report() { echo "FAIL $1"; status=1; }

mapfile -t files < <(git ls-files | grep -v -x "$self")
[[ ${#files[@]} -gt 0 ]] || { echo "No tracked files."; exit 2; }

# scan NAME PATTERN [ALLOWED]: a line is a finding when PATTERN still matches after the ALLOWED matches are removed
scan() {
    local name=$1 pattern=$2 allowed=${3:-} hit line
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        line=${hit#*:}; line=${line#*:}
        if [[ -n "$allowed" ]]; then line=$(sed -E "s/$allowed/ /g" <<<"$line"); fi
        # only file:line is printed: in a public CI log the offending value would be a second copy of it
        if grep -Eq -- "$pattern" <<<"$line"; then report "$name: $(cut -d: -f1,2 <<<"$hit")"; fi
    done < <(grep -nIE -- "$pattern" "${files[@]}" /dev/null 2>/dev/null)
}

scan 'ipv4 address' \
    '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' \
    '(127\.[0-9]+\.[0-9]+\.[0-9]+|0\.0\.0\.0|255\.255\.255\.255|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)'
scan 'mac address' \
    '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}' \
    '(00[:-]00[:-]5[eE][:-]00[:-]53[:-][0-9A-Fa-f]{2}|([fF]{2}[:-]){5}[fF]{2})'
scan 'key fingerprint' 'SHA256:[A-Za-z0-9+/]{43}'
scan 'private key' 'BEGIN [A-Z ]*PRIVATE KEY'
scan 'public key' '(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+) AAAA[A-Za-z0-9+/]{20,}'
scan 'token' '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{10,})'
scan 'e-mail address' \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' \
    '([A-Za-z0-9._%+-]*noreply@[A-Za-z0-9.-]+|[A-Za-z0-9._%+-]+@users\.noreply\.github\.com|[A-Za-z0-9._%+-]+@example\.(com|org|net)|git@github\.com)'

if [[ -f .private-terms ]]; then
    n=0
    while IFS= read -r term || [[ -n "$term" ]]; do
        term=${term%$'\r'}
        [[ -n "$term" && "$term" != \#* ]] || continue
        n=$((n + 1))
        while IFS= read -r hit; do
            [[ -n "$hit" ]] || continue
            # the term itself is not echoed: the output of this script may end up in a log
            report "local term #$n: $(cut -d: -f1,2 <<<"$hit")"
        done < <(grep -nIiF -- "$term" "${files[@]}" "$self" /dev/null 2>/dev/null)
    done < .private-terms
    echo "NOTE $n local terms checked"
else
    echo "NOTE no .private-terms file: only the generic patterns were checked"
fi

if [[ $status -eq 0 ]]; then echo "PASS no private data found in $((${#files[@]} + 1)) tracked files"; fi
exit $status
