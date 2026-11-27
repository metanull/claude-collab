# Dot-sourced by Install-Collab.ps1 and Test-Collab.ps1.
# Expand-CollabTemplate: text of a *.template.md file with every {{NAME}} replaced by the setting of that name.
$script:CollabPlaceholders = [ordered]@{
    ALIAS = 'Alias'; HOST_ADDRESS = 'HostAddress'; OWNER = 'Owner'; ADMIN = 'Admin'
    MAC = 'Mac'; WIRED_INTERFACE = 'WiredInterface'; WINDOWS_ADAPTER = 'WindowsAdapter'
}
function Expand-CollabTemplate([string]$Path, $Settings) {
    $text = [IO.File]::ReadAllText($Path)   # UTF-8 in every PowerShell version
    foreach ($name in $script:CollabPlaceholders.Keys) {
        $value = $Settings.($script:CollabPlaceholders[$name])
        if (-not $value) { $value = '(not set)' }
        $text = $text.Replace("{{$name}}", [string]$value)
    }
    if ($text -match '\{\{[A-Z_]+\}\}') { throw "Unknown placeholder $($Matches[0]) in $Path" }
    $text
}
