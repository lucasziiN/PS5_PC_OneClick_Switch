. (Join-Path $PSScriptRoot 'Common.ps1')

Invoke-SwitchAction 'TOGGLE' {
    param($cfg)
    $mode = Get-CurrentMode $cfg
    Write-Log "Detected current mode: $mode"
    if ($mode -eq 'PS5') { Invoke-PCMode $cfg } else { Invoke-PS5Mode $cfg }
}
