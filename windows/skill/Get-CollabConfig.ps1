# Returns this machine's collab settings (collab.config.json next to this script, written by Install-Collab.ps1).
# Every other script takes its machine-specific values from here: none is hardcoded.
#   Alias           SSH alias of the Ubuntu machine (also <Alias>-admin and <Alias>-sites)
#   HostAddress     its address for SSH
#   Owner, Admin    the user's own account there, and the key-only admin account
#   Mac             MAC address of its wired port (Wake-on-LAN target)
#   WiredInterface  name of that wired port on the Ubuntu machine
#   WindowsAdapter  this PC's adapter on the same cable or segment (the magic packet leaves through it)
#   SitesUrl        optional: page to open once the sites tunnel is up
$path = Join-Path $PSScriptRoot 'collab.config.json'
if (-not (Test-Path $path)) { throw "No settings file ${path}: run windows\setup\Install-Collab.ps1 from the repository first." }
Get-Content $path -Raw | ConvertFrom-Json
