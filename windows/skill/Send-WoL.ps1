# Sends a Wake-on-LAN magic packet out of a specific local adapter.
# The packet only wakes the machine if it arrives on its wired port, so it must leave through the adapter that shares
# a cable or segment with that port: not through whichever adapter has the default route (often Wi-Fi).
# Defaults come from collab.config.json (Mac, WindowsAdapter).
param(
    [string]$Mac,
    [string]$InterfaceAlias,
    [int]$Repeat = 3
)
$config = & "$PSScriptRoot\Get-CollabConfig.ps1"
if (-not $Mac) { $Mac = $config.Mac }
if (-not $InterfaceAlias) { $InterfaceAlias = $config.WindowsAdapter }
if (-not $Mac -or -not $InterfaceAlias) { throw 'Mac and WindowsAdapter are not set in collab.config.json (Install-Collab.ps1 -Mac ... -WindowsAdapter ...).' }

$localIp = (Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop |
    Select-Object -First 1).IPAddress

$macBytes = $Mac -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) }
[byte[]]$packet = (, [byte]0xFF * 6) + ($macBytes * 16)

$udp = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($localIp), 0))
$udp.EnableBroadcast = $true
try {
    foreach ($port in 9, 7) {
        $target = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, $port)
        1..$Repeat | ForEach-Object { [void]$udp.Send($packet, $packet.Length, $target); Start-Sleep -Milliseconds 100 }
    }
    "Magic packet sent from the '$InterfaceAlias' adapter, $($packet.Length) bytes, ports 9 and 7."
}
finally { $udp.Close() }
