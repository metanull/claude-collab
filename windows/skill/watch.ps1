# Emits one line each time the peer's note file on the Ubuntu machine changes.
# One long-lived SSH session runs the poll loop; if it drops (machine suspended, network down)
# this script reconnects quietly and still reports a change that happened while it was away.
# Connects through the SSH alias of collab.config.json (the owner's account).
param(
    [string]$File = 'from-ubuntu.md',
    [string]$Alias,
    [int]$PollSeconds = 5
)
if (-not $Alias) { $Alias = (& "$PSScriptRoot\Get-CollabConfig.ps1").Alias }

$remote = 'f=$HOME/claude-collab/' + $File + '; sig(){ echo "SIG $(stat -c %s:%Y "$f" 2>/dev/null || echo missing) $(wc -l < "$f" 2>/dev/null || echo 0)"; }; last=$(sig); echo "$last"; while true; do sleep ' + $PollSeconds + '; cur=$(sig); if [ "$cur" != "$last" ]; then sleep 1; last=$(sig); echo "$last"; fi; done'

$last = $null
while ($true) {
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 $Alias $remote 2>$null |
        ForEach-Object {
            if ($_ -match '^SIG (\S+) (\d+)') {
                $sig = $Matches[1]
                if ($null -eq $last) { $last = $sig }
                elseif ($sig -ne $last) {
                    $last = $sig
                    "$(Get-Date -Format HH:mm:ss) $File changed: $($Matches[2]) lines"
                }
            }
        }
    Start-Sleep -Seconds 15   # unreachable (asleep?) - retry quietly
}
