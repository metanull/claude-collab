# Appends a local text file as a new entry at the end of ~/claude-collab/from-windows.md on the Ubuntu machine.
# Append only: earlier entries are never rewritten. Usage: post.ps1 -EntryFile <path>
# Connects through the SSH alias of collab.config.json (the owner's account).
param(
    [Parameter(Mandatory)][string]$EntryFile,
    [string]$Alias
)
$ErrorActionPreference = 'Stop'
if (-not $Alias) { $Alias = (& "$PSScriptRoot\Get-CollabConfig.ps1").Alias }
if (-not (Test-Path $EntryFile)) { throw "No such file: $EntryFile" }

scp -q -o BatchMode=yes -o ConnectTimeout=8 $EntryFile "${Alias}:claude-collab/.entry-windows.tmp"
if ($LASTEXITCODE -ne 0) { throw 'scp failed (the Ubuntu machine is asleep or unreachable?)' }

ssh -o BatchMode=yes -o ConnectTimeout=8 $Alias 'cd ~/claude-collab && { echo; sed "s/\r$//" .entry-windows.tmp; } >> from-windows.md && rm -f .entry-windows.tmp && echo "from-windows.md: $(wc -l < from-windows.md) lines"'
if ($LASTEXITCODE -ne 0) { throw 'append failed' }
