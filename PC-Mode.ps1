# -OnlyIfPS5Mode: used by the tray when the PS5 enters Rest Mode; does nothing if already in PC mode.
param([switch]$OnlyIfPS5Mode)
. (Join-Path $PSScriptRoot 'Common.ps1')

Invoke-SwitchAction 'PC MODE' {
    param($cfg)
    if ($OnlyIfPS5Mode -and (Get-CurrentMode $cfg) -ne 'PS5') { Write-Log 'Already in PC mode; nothing to do.'; return }
    Invoke-PCMode $cfg
}
