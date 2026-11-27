<#
    .SYNOPSIS
        First-time setup of the Windows side: settings file, SSH keys, SSH aliases, and the collab skill. Safe to run again.
    .DESCRIPTION
        1. Writes <SkillDir>\collab.config.json: the machine-specific values, which exist nowhere else. A value not given
           on a later run keeps what the file holds.
        2. Creates two SSH key pairs if they do not exist (never overwrites one):
             <SshDir>\<Alias>_<Owner>   the owner's account on the Ubuntu machine (note channel, tunnel)
             <SshDir>\<Alias>_<Admin>   the key-only admin account (root through sudo -n)
           The private keys stay on this PC. Nothing is sent anywhere.
        3. Adds the aliases <Alias>, <Alias>-admin and <Alias>-sites to <SshDir>\config; an alias already there is left as is.
        4. Installs the skill to <SkillDir>: the scripts of ..\skill, SKILL.md rendered from SKILL.template.md, and
           machine.md rendered from machine.template.md only if missing (it then becomes local notes). A changed file
           keeps a .bak.
        5. Prints what the Ubuntu side needs: the two public key files.
        Use -WhatIf to see what it would do. Check the result with Test-Collab.ps1.
        There is no undo: to remove the setup, delete the two key pairs, the three Host blocks in <SshDir>\config and <SkillDir>.
    .EXAMPLE
        .\Install-Collab.ps1 -Alias ubuntu-box -HostAddress 192.0.2.10 -Owner owner -Mac 00:00:5e:00:53:01 -WiredInterface IFACE
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Alias,            # name for the Ubuntu machine on this PC (SSH alias, key file names)
    [string]$HostAddress,      # its address for SSH
    [string]$Owner,            # the user's own account there
    [string]$Admin,            # the key-only admin account there (default: claude)
    [string]$Mac,              # MAC address of its wired port: the Wake-on-LAN target (setup-wol.sh prints it)
    [string]$WiredInterface,   # name of that wired port on the Ubuntu machine
    [string]$WindowsAdapter,   # this PC's adapter on the same cable or segment (default: Ethernet)
    [string]$SitesUrl,         # optional: page to open once the sites tunnel is up
    [string]$SshDir = "$env:USERPROFILE\.ssh",
    [string]$SkillDir = "$env:USERPROFILE\.claude\skills\collab"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Expand-CollabTemplate.ps1"
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { throw 'ssh-keygen not found: install the Windows OpenSSH client first.' }

# 1. settings: argument > existing file > default
$configPath = Join-Path $SkillDir 'collab.config.json'
$old = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
$defaults = @{ Admin = 'claude'; WindowsAdapter = 'Ethernet' }
$settings = [ordered]@{}
foreach ($name in 'Alias', 'HostAddress', 'Owner', 'Admin', 'Mac', 'WiredInterface', 'WindowsAdapter', 'SitesUrl') {
    $settings[$name] = if ($PSBoundParameters.ContainsKey($name)) { $PSBoundParameters[$name] } elseif ($old -and $old.$name) { $old.$name } else { $defaults[$name] }
}
foreach ($name in 'Alias', 'HostAddress', 'Owner') { if (-not $settings[$name]) { throw "-$name is required (no value in $configPath yet)." } }
foreach ($name in 'Alias', 'Owner', 'Admin') { if ($settings[$name] -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { throw "-$name '$($settings[$name])': letters, digits, _ . - only." } }
if ($settings.Mac -and $settings.Mac -notmatch '^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') { throw "-Mac '$($settings.Mac)' is not a MAC address." }
foreach ($name in 'Mac', 'WiredInterface') { if (-not $settings[$name]) { Write-Warning "-$name is not set: Wake-on-LAN will not work until it is (run again with -$name)." } }

if (-not (Test-Path $SkillDir)) { if ($PSCmdlet.ShouldProcess($SkillDir, 'create folder')) { New-Item -ItemType Directory -Path $SkillDir -Force | Out-Null } }
$json = $settings | ConvertTo-Json
if ($old -and (($old | ConvertTo-Json) -eq $json)) { "config   same     $configPath" }
elseif ($PSCmdlet.ShouldProcess($configPath, 'write settings')) { Set-Content -Path $configPath -Value $json; "config   written  $configPath" }
$Alias = $settings.Alias; $Owner = $settings.Owner; $Admin = $settings.Admin; $HostAddress = $settings.HostAddress

# 2. keys
if (-not (Test-Path $SshDir)) { if ($PSCmdlet.ShouldProcess($SshDir, 'create folder')) { New-Item -ItemType Directory -Path $SshDir | Out-Null } }
$keys = [ordered]@{ $Owner = Join-Path $SshDir "${Alias}_$Owner"; $Admin = Join-Path $SshDir "${Alias}_$Admin" }
foreach ($account in $keys.Keys) {
    $path = $keys[$account]
    if (Test-Path $path) { "key      present  $path"; continue }
    if ($PSCmdlet.ShouldProcess($path, 'create ed25519 key pair')) {
        # No passphrase: the sessions use the key unattended (BatchMode). The comment carries no user or machine name.
        # Through cmd: how PowerShell passes an empty argument to a native command depends on its version, and a
        # literal "" would become the passphrase.
        cmd /c "ssh-keygen -q -t ed25519 -N `"`" -C collab-key -f `"$path`""
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed for $path" }
        $derived = cmd /c "ssh-keygen -y -P `"`" -f `"$path`" 2>nul"
        if ($LASTEXITCODE -ne 0 -or (@($derived)[0] -split ' ')[1] -ne ((Get-Content "$path.pub" -TotalCount 1) -split ' ')[1]) {
            Remove-Item $path, "$path.pub" -Force -ErrorAction SilentlyContinue
            throw "The new key $path does not open with an empty passphrase; removed it. Report this with your PowerShell version."
        }
        "key      created  $path"
    }
}

# 3. aliases
$config = Join-Path $SshDir 'config'
$existing = if (Test-Path $config) { Get-Content $config -Raw } else { '' }
# accept-new: the first connection records the host key without a prompt (the sessions run with BatchMode);
# a host key that later changes is still refused.
$common = @('    IdentitiesOnly yes', '    StrictHostKeyChecking accept-new')
$blocks = [ordered]@{
    $Alias           = @("Host $Alias", "    HostName $HostAddress", "    User $Owner", "    IdentityFile ~/.ssh/${Alias}_$Owner") + $common
    "$Alias-admin"   = @("Host $Alias-admin", "    HostName $HostAddress", "    User $Admin", "    IdentityFile ~/.ssh/${Alias}_$Admin") + $common
    "$Alias-sites"   = @(
        "# Tunnel only: this PC's port 80 -> the sites the Ubuntu machine serves on its own loopback port 80",
        "Host $Alias-sites", "    HostName $HostAddress", "    User $Owner", "    IdentityFile ~/.ssh/${Alias}_$Owner") + $common + @(
        '    LocalForward 127.0.0.1:80 127.0.0.1:80', '    ExitOnForwardFailure yes', '    ServerAliveInterval 30', '    ServerAliveCountMax 3', '    RequestTTY no')
}
foreach ($name in $blocks.Keys) {
    if ($existing -match "(?m)^\s*Host\s+$([regex]::Escape($name))\s*$") {
        # left as it is, but say so when it points elsewhere (the address may come from DHCP)
        $current = ((ssh -F $config -G $name 2>$null) -match '^hostname ') -replace '^hostname ', '' | Select-Object -First 1
        if ($current -and $current -ne $HostAddress) { "alias    present  $name  (HostName differs: $current instead of $HostAddress; edit $config by hand)" }
        else { "alias    present  $name" }
        continue
    }
    if ($PSCmdlet.ShouldProcess($config, "add alias $name")) {
        Add-Content -Path $config -Value (@('') + $blocks[$name])
        "alias    added    $name"
    }
}

# 4. skill
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'skill'
if (-not (Test-Path $source)) { throw "Skill folder not found: $source" }
function Install-Text([string]$name, [string]$text, [switch]$OnlyIfMissing) {
    $target = Join-Path $SkillDir $name
    $text = $text -replace "`r", ''
    if (Test-Path $target) {
        if ($OnlyIfMissing) { "skill    kept     $name  (local notes, not replaced)"; return }
        if (([IO.File]::ReadAllText($target) -replace "`r", '') -eq $text) { "skill    same     $name"; return }
    }
    if ($PSCmdlet.ShouldProcess($target, 'install skill file')) {
        if (Test-Path $target) { Copy-Item $target "$target.bak" -Force }
        [IO.File]::WriteAllText($target, $text)
        "skill    written  $name"
    }
}
foreach ($file in Get-ChildItem $source -File | Where-Object Name -NotLike '*.template.md') { Install-Text $file.Name ([IO.File]::ReadAllText($file.FullName)) }
Install-Text 'SKILL.md' (Expand-CollabTemplate (Join-Path $source 'SKILL.template.md') $settings)
Install-Text 'machine.md' (Expand-CollabTemplate (Join-Path $source 'machine.template.md') $settings) -OnlyIfMissing

# 5. what the other side needs
''
'Next, on the Ubuntu machine (see ubuntu/README.md): authorise these public keys. Copy the .pub files only, never the private keys.'
"  owner account '$Owner' : $($keys[$Owner]).pub   -> append to that account's ~/.ssh/authorized_keys"
"  admin account '$Admin' : $($keys[$Admin]).pub   -> give to setup-admin.sh --pubkey"
'Then check from here: .\Test-Collab.ps1'
