# Makes the web sites that the Ubuntu machine serves on its own 127.0.0.1:80 reachable on this PC.
# Browsers send every *.localhost name to this PC's port 80, and the SSH alias "<Alias>-sites" forwards that port to
# the machine, so http://<site>.<domain>.localhost/ works here as it does there. A bare http://localhost/ reaches the
# machine's default site, which may refuse it. Wakes the machine first if it does not answer.
# Runs until closed (Ctrl+C); reconnects when the connection drops. Stop-MwnfTunnel.ps1 ends one started elsewhere.
param(
    [string]$Open,                    # page opened once the tunnel is up; default: SitesUrl of collab.config.json; '' for none
    [int]$WakeTimeoutSeconds = 150
)
$config = & "$PSScriptRoot\Get-CollabConfig.ps1"
$tunnel = "$($config.Alias)-sites"
if (-not $PSBoundParameters.ContainsKey('Open')) { $Open = $config.SitesUrl }

function Get-TunnelProcess {
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "\s$([regex]::Escape($tunnel))\s*$" }
}
function Test-Ssh { ssh -o BatchMode=yes -o ConnectTimeout=4 -o ClearAllForwardings=yes $tunnel true 2>$null; $LASTEXITCODE -eq 0 }

if (Get-TunnelProcess) { 'The tunnel is already running.'; return }

$busy = Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($busy) {
    $name = (Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    throw "Port 80 of this PC is already used by '$name' (process $($busy.OwningProcess)); close it first."
}

if (-not (Test-Ssh)) {
    'The machine does not answer; sending Wake-on-LAN...'
    & "$PSScriptRoot\Send-WoL.ps1"
    $deadline = (Get-Date).AddSeconds($WakeTimeoutSeconds)
    while (-not (Test-Ssh)) {
        if ((Get-Date) -gt $deadline) { throw "The machine did not answer within $WakeTimeoutSeconds s." }
        Start-Sleep -Seconds 3
    }
}

$stopFlag = Join-Path $env:TEMP 'collab-sites-tunnel.stop'   # written by Stop-MwnfTunnel.ps1
Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue
$opened = $false
while ($true) {
    if ($Open -and -not $opened) {
        # once, when the sites answer (the services need a little time after a boot)
        $null = Start-Job -ArgumentList $Open {
            param($u)
            foreach ($i in 1..40) {
                Start-Sleep -Seconds 3
                if ((curl.exe -s -o NUL --max-time 10 -w '%{http_code}' $u) -match '^[23]') { Start-Process $u; break }
            }
        }
        $opened = $true
    }
    "$(Get-Date -Format T) tunnel up through '$tunnel' (Ctrl+C to close)"
    ssh -N $tunnel
    if (Test-Path $stopFlag) { Remove-Item $stopFlag -Force; "$(Get-Date -Format T) tunnel stopped (Stop-MwnfTunnel.ps1)"; break }
    "$(Get-Date -Format T) tunnel closed (exit $LASTEXITCODE); retrying in 5 s"
    Start-Sleep -Seconds 5
}
$global:LASTEXITCODE = 0   # the tunnel was stopped on purpose: not an error
