<#
    .SYNOPSIS
        Read-only check of the whole setup, from the Windows PC: one PASS / FAIL / SKIP line per item.
    .DESCRIPTION
        Takes every machine-specific value from <SkillDir>\collab.config.json (written by Install-Collab.ps1).
        Local items (settings, keys, aliases, skill, wired adapter), then the Ubuntu machine over SSH (logins, sudo,
        Wake-on-LAN armed, note folder), then the Ubuntu side's own verify.sh, as the owner and as the admin account.
        Changes nothing on either machine. -Wake first sends the magic packet and waits, for a machine that is asleep or off.
        Exit code: the number of FAIL lines.
#>
param(
    [string]$SshDir = "$env:USERPROFILE\.ssh",
    [string]$SkillDir = "$env:USERPROFILE\.claude\skills\collab",
    [string]$RemoteVerify = '~/claude-collab/repo/ubuntu/setup/verify.sh',   # the repository cloned to ~/claude-collab/repo there
    [string]$From,                               # optional: networks the admin key must be restricted to (as given to setup-admin.sh --from)
    [switch]$LocalOnly,
    [switch]$Wake
)
. "$PSScriptRoot\Expand-CollabTemplate.ps1"
$script:fail = 0
function Report([string]$status, [string]$item, [string]$detail = '') {
    if ($status -eq 'FAIL') { $script:fail++ }
    '{0,-4} {1}{2}' -f $status, $item, $(if ($detail) { "  ($detail)" })
}
function Check([string]$item, [scriptblock]$test) {
    try { $r = & $test; if ($r -is [string] -and $r) { Report 'PASS' $item $r } elseif ($r) { Report 'PASS' $item } else { Report 'FAIL' $item } }
    catch { Report 'FAIL' $item $_.Exception.Message }
}
function Remote([string]$alias, [string]$command) {
    $out = ssh -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes $alias $command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE $(@($out)[-1])" }
    ($out -join "`n").Trim()
}

'--- this PC'
$configPath = Join-Path $SkillDir 'collab.config.json'
if (-not (Test-Path $configPath)) { Report 'FAIL' 'settings file collab.config.json' 'missing: run Install-Collab.ps1'; "--- $script:fail FAIL"; exit $script:fail }
$s = Get-Content $configPath -Raw | ConvertFrom-Json
$Alias = $s.Alias; $Owner = $s.Owner; $Admin = $s.Admin
Check 'settings: Alias, HostAddress, Owner, Admin' { [bool]($s.Alias -and $s.HostAddress -and $s.Owner -and $s.Admin) }
Check 'settings: Mac, WiredInterface, WindowsAdapter (Wake-on-LAN)' { [bool]($s.Mac -and $s.WiredInterface -and $s.WindowsAdapter) }
Check 'OpenSSH client' { [bool](Get-Command ssh -ErrorAction SilentlyContinue) }
foreach ($account in $Owner, $Admin) {
    $key = Join-Path $SshDir "${Alias}_$account"
    $label = if ($account -eq $Owner) { 'owner' } else { 'admin' }
    Check "$label key pair exists" { (Test-Path $key) -and (Test-Path "$key.pub") }
    Check "$label key opens without a passphrase and matches its .pub" {
        $derived = cmd /c "ssh-keygen -y -P `"`" -f `"$key`" 2>nul"
        if ($LASTEXITCODE -ne 0) { throw 'has a passphrase or is unreadable: unusable for unattended sessions' }
        (@($derived)[0] -split ' ')[1] -eq ((Get-Content "$key.pub" -TotalCount 1) -split ' ')[1]
    }
}
$config = Join-Path $SshDir 'config'
foreach ($suffix in '', '-admin', '-sites') {
    $name = "$Alias$suffix"
    Check "SSH alias <Alias>$suffix exists" { (Test-Path $config) -and ((Get-Content $config -Raw) -match "(?m)^\s*Host\s+$([regex]::Escape($name))\s*$") }
    Check "SSH alias <Alias>$suffix points to the configured address" {
        $current = ((ssh -F $config -G $name 2>$null) -match '^hostname ') -replace '^hostname ', '' | Select-Object -First 1
        if ($current -ne $s.HostAddress) { throw 'HostName differs from HostAddress in collab.config.json' } else { $true }
    }
}
Check 'SSH alias <Alias>-sites forwards port 80' { [bool]((ssh -F $config -G "$Alias-sites" 2>$null) -match '^localforward .*:80 ') }

$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'skill'
$same = { param($installed, $text) (Test-Path $installed) -and (([IO.File]::ReadAllText($installed) -replace "`r", '') -eq ($text -replace "`r", '')) }
foreach ($file in Get-ChildItem $source -File | Where-Object Name -NotLike '*.template.md') {
    Check "skill file $($file.Name) installed and current" { & $same (Join-Path $SkillDir $file.Name) ([IO.File]::ReadAllText($file.FullName)) }
}
Check 'skill file SKILL.md equals the rendered template' { & $same (Join-Path $SkillDir 'SKILL.md') (Expand-CollabTemplate (Join-Path $source 'SKILL.template.md') $s) }
Check 'skill file machine.md present (local notes)' { Test-Path (Join-Path $SkillDir 'machine.md') }
Check 'wired adapter has an IPv4 address (Wake-on-LAN leaves through it)' {
    [bool](Get-NetIPAddress -InterfaceAlias $s.WindowsAdapter -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1).IPAddress
}
Check 'wired adapter link is up' { (Get-NetAdapter -Name $s.WindowsAdapter -ErrorAction Stop).Status -eq 'Up' }

if ($LocalOnly) { "--- $script:fail FAIL"; exit $script:fail }

'--- the Ubuntu machine'
if ($Wake) {
    & (Join-Path $SkillDir 'Send-WoL.ps1') | Out-Null
    $deadline = (Get-Date).AddSeconds(150)
    do { ssh -o BatchMode=yes -o ConnectTimeout=4 $Alias true 2>$null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 3 } while ((Get-Date) -lt $deadline)
}
$script:reachable = $false
Check 'SSH login as the owner (<Alias>)' { $null = Remote $Alias 'true'; $script:reachable = $true; $true }
if (-not $script:reachable) {
    Report 'SKIP' 'remaining remote checks' 'machine not reachable: asleep or off? use -Wake'
    "--- $script:fail FAIL"; exit $script:fail
}
Check 'SSH login as the admin account (<Alias>-admin)' { (Remote "$Alias-admin" 'whoami') -eq $Admin }
Check 'admin account has passwordless sudo' { (Remote "$Alias-admin" 'sudo -n whoami') -eq 'root' }
Check 'owner has NO passwordless sudo' { (Remote $Alias 'sudo -n true 2>/dev/null && echo yes || echo no') -eq 'no' }
Check 'admin account cannot enter the owner''s home' { (Remote "$Alias-admin" "test -r `"`$(getent passwd $Owner | cut -d: -f6)`" && echo yes || echo no") -eq 'no' }
Check 'Wake-on-LAN armed on the wired port (Wake-on: g)' {
    $w = Remote "$Alias-admin" "sudo -n ethtool $($s.WiredInterface) | grep '^[[:space:]]*Wake-on:' | tr -d '[:space:]'"
    if ($w -ne 'Wake-on:g') { throw $w } else { $true }
}
Check 'MAC of the wired port equals the configured one' {
    (Remote $Alias "cat /sys/class/net/$($s.WiredInterface)/address") -eq ($s.Mac.ToLower() -replace '-', ':')
}
Check 'note folder ~/claude-collab with both note files' { (Remote $Alias 'test -f ~/claude-collab/from-ubuntu.md && test -f ~/claude-collab/from-windows.md && echo ok') -eq 'ok' }
Check 'Ubuntu collab skill installed' { (Remote $Alias 'test -f ~/.claude/skills/collab/SKILL.md && echo ok') -eq 'ok' }

"--- the Ubuntu side's own checks ($RemoteVerify)"
function Invoke-Verify([string]$label, [string]$commandLine) {
    # through cmd: a byte-clean pipe, and the script's own exit code
    $seen = 0
    cmd /c "$commandLine 2>&1" | ForEach-Object { if ($_ -match '^\s*FAIL\b') { $seen++ }; "$_" }
    $script:fail += $seen
    # a broken connection or a script that dies without a FAIL line must not count as a pass
    if ($LASTEXITCODE -ne 0 -and $seen -eq 0) { Report 'FAIL' "verify.sh $label" "exit $LASTEXITCODE" }
}
$present = ssh -o BatchMode=yes -o ConnectTimeout=8 $Alias "test -f $RemoteVerify && echo yes" 2>$null
if ($present -eq 'yes') {
    $ssh = 'ssh -o BatchMode=yes -o ConnectTimeout=8'
    $fromArg = if ($From) { " --from $From" } else { '' }
    '  as the owner:'
    Invoke-Verify 'as the owner' "$ssh $Alias bash $RemoteVerify"
    # as the admin account the root-only items are checked for real (key restriction, sudo rule, locked password)
    '  as the admin account (root-only items):'
    Invoke-Verify 'as the admin account' "$ssh $Alias cat $RemoteVerify | $ssh $Alias-admin bash -s -- --owner $Owner$fromArg"
} else { Report 'SKIP' 'verify.sh' 'not found on the Ubuntu machine: clone the repository to ~/claude-collab/repo there' }

"--- $script:fail FAIL"
exit $script:fail
