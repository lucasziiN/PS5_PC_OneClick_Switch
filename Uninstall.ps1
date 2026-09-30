# Removes the PS5 / PC switch from this PC: tray app, autostart, desktop shortcuts, and optionally your settings.
. (Join-Path $PSScriptRoot 'Common.ps1')

try {
    Write-Host '=== PS5 / PC SWITCH UNINSTALL ===' -ForegroundColor Cyan

    if ((Test-Path (Join-Path $Root 'config.json')) -and (Get-CurrentMode (Get-SwitchConfig)) -eq 'PS5') {
        Write-Host 'Currently in PS5 mode; switching back to PC mode first...'
        Restore-PCDisplays (Get-SwitchConfig)
    }

    Stop-TrayApp
    Set-TrayAutostart $false
    Write-Host 'Tray app stopped and removed from Windows startup.'

    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($name in 'PS5 MODE', 'PC MODE', 'PS5-PC TOGGLE') {
        Remove-Item (Join-Path $desktop "$name.lnk") -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Desktop shortcuts removed.'

    if ((Read-Host 'Also delete your settings, display layouts, logs and downloaded tools from this folder? [y/N]') -match '^(y|yes)$') {
        foreach ($item in 'config.json', 'pc-layout.cfg', 'ps5-layout.cfg', 'state.txt', 'logs', 'Tools') {
            Remove-Item (Join-Path $Root $item) -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host 'Personal files deleted.'
    }

    Write-Host ''
    Write-Host 'Done. Left in place (remove manually if you want):'
    Write-Host '  - this folder'
    Write-Host '  - ps5-remoteplay:  python -m pip uninstall ps5-remoteplay'
    Write-Host "  - PS5 pairing:     $env:USERPROFILE\.config\ps5-remoteplay\credentials.json"
} catch {
    Write-Host "UNINSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host 'Press Enter to close'
