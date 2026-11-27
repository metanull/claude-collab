#!/usr/bin/env bash
# Emits one line each time the peer's note file changes. Usage: watch.sh [dir] [peer-file]
DIR="${1:-$HOME/claude-collab}"
FILE="$DIR/${2:-from-windows.md}"
sig() { stat -c '%s:%Y' "$FILE" 2>/dev/null || echo missing; }
last=$(sig)
while true; do
    sleep 2
    cur=$(sig)
    if [[ "$cur" != "$last" ]]; then
        sleep 1   # let the writer finish
        cur=$(sig)
        echo "$(date +%H:%M:%S) $(basename "$FILE") changed: $(wc -l < "$FILE" 2>/dev/null || echo 0) lines"
        last=$cur
    fi
done
