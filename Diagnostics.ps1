. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Continue'

function Section([string]$Title) { Write-Host ''; Write-Host "=== $Title ===" -ForegroundColor Cyan }

Section 'CONFIG'
try {
    $cfg = Get-SwitchConfig
    $cfg | Select-Object * -ExcludeProperty PS5Passcode | Format-List | Out-Host
    Write-Host "PS5 passcode set: $([bool]$cfg.PS5Passcode)"
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

Section 'PS5'
try {
    $status = Get-PS5Status $cfg
    Write-Host "PS5 status: $status"
} catch { Write-Host $_.Exception.Message -ForegroundColor Red }

Section 'WINDOWS DISPLAYS (MultiMonitorTool)'
try {
    Get-DisplayTopology $cfg |
        Format-Table Name, 'Short Monitor ID', Active, Disconnected, Primary, Resolution, 'Left-Top', Frequency, Orientation |
        Out-Host
    Write-Host "Shared monitor ($($cfg.Monitor)) active in Windows: $(Test-SharedMonitorActive $cfg)"
} catch { Write-Host $_.Exception.Message -ForegroundColor Red }

Section 'DDC/CI MONITORS (ControlMyMonitor)'
$list = Join-Path $env:TEMP 'ps5pc-cmm-monitors.txt'
try {
    Invoke-External $cfg.ControlTool @('/smonitors', $list) 30 | Out-Null
    Get-Content $list | Out-Host
    Remove-Item $list -Force -ErrorAction SilentlyContinue
    $input60 = Get-SharedMonitorInput $cfg
    $meaning = switch ($input60) {
        $cfg.PCInput { 'PC input' }
        $cfg.PS5Input { 'PS5 input' }
        0 { 'not reachable (expected while the shared monitor is disabled in Windows)' }
        default { 'unknown input' }
    }
    Write-Host "Shared monitor VCP 60 = $input60 -> $meaning"
} catch { Write-Host $_.Exception.Message -ForegroundColor Red }

Section 'MODE'
Write-Host "Detected mode: $(Get-CurrentMode $cfg)"
Write-Host "state.txt:     $(Get-SwitchStateFile)"

Section 'RECENT LOG'
if (Test-Path $LogFile) { Get-Content $LogFile -Tail 25 | Out-Host } else { Write-Host 'No log yet.' }

Write-Host ''
Read-Host 'Press Enter to close'
