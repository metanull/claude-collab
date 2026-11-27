# Ends the sites tunnel (started by Start-MwnfTunnel.ps1 or by "ssh -N <Alias>-sites").
# The flag file tells a running Start-MwnfTunnel.ps1 to end instead of reconnecting.
$tunnel = "$((& "$PSScriptRoot\Get-CollabConfig.ps1").Alias)-sites"
$flag = Join-Path $env:TEMP 'collab-sites-tunnel.stop'
Set-Content -Path $flag -Value (Get-Date -Format o)
$tunnels = @(Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "\s$([regex]::Escape($tunnel))\s*$" })
$tunnels | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if (-not $tunnels) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }   # nothing to tell
"Stopped $($tunnels.Count) tunnel(s)."
