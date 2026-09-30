# Guided setup for the PS5 / PC one-click switch. Safe to re-run: current settings are offered as defaults.
. (Join-Path $PSScriptRoot 'Common.ps1')

$Tools       = Join-Path $Root 'Tools'
$ConfigPath  = Join-Path $Root 'config.json'
$CMM         = Join-Path $Tools 'ControlMyMonitor.exe'
$MMT         = Join-Path $Tools 'MultiMonitorTool.exe'
$PcLayout    = Join-Path $Root 'pc-layout.cfg'
$Ps5Layout   = Join-Path $Root 'ps5-layout.cfg'
$Credentials = Join-Path $env:USERPROFILE '.config\ps5-remoteplay\credentials.json'
$DesktopShortcuts = @(
    @{ Name = 'PS5 MODE';      Script = 'PS5-Mode.ps1'; Description = 'Wake the PS5 and switch the shared monitor to it' },
    @{ Name = 'PC MODE';       Script = 'PC-Mode.ps1';  Description = 'Put the PS5 in Rest Mode and switch back to the PC' },
    @{ Name = 'PS5-PC TOGGLE'; Script = 'Toggle.ps1';   Description = 'Switch between PS5 mode and PC mode' }
)

# ---------------------------------------------------------------- prompts

function Step([int]$Number, [string]$Title) {
    Write-Host ''
    Write-Host "[$Number/8] $Title" -ForegroundColor Cyan
}

function Read-WithDefault([string]$Prompt, [string]$Default) {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Prompt$suffix"
    if ($answer) { return $answer.Trim() }
    return $Default
}

function Confirm-Yes([string]$Prompt) { return (Read-Host "$Prompt [Y/n]") -notmatch '^(n|no)$' }
function Confirm-No([string]$Prompt) { return (Read-Host "$Prompt [y/N]") -match '^(y|yes)$' }

function Read-Choice([string]$Prompt, [int]$Count, [int]$Default) {
    while ($true) {
        $answer = Read-WithDefault $Prompt "$Default"
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Count) { return $number }
        Write-Host "Enter a number from 1 to $Count." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- setup helpers

function Install-NirSoftTool([string]$Url, [string]$ExeName) {
    $exe = Join-Path $Tools $ExeName
    if (Test-Path $exe) { Write-Host "$ExeName already present."; return }
    $zip = Join-Path $env:TEMP ([System.IO.Path]::GetFileName($Url))
    Write-Host "Downloading $ExeName from nirsoft.net..."
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $Tools -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $exe)) { throw "$ExeName was not found after extraction." }
}

# Returns "IP  name  status" lines for every PS5 that answers a network broadcast.
function Find-PS5Consoles([string]$RemoteExe) {
    $result = Invoke-External $RemoteExe @('status', '--timeout', '3') 30
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match '^(?<name>.+?) \(.+\) at (?<ip>\d{1,3}(\.\d{1,3}){3}): (?<status>\w+)') {
            [pscustomobject]@{ IP = $Matches.ip; Name = $Matches.name; Status = $Matches.status }
        }
    }
}

# Parses ControlMyMonitor /smonitors output into objects.
function Get-DdcMonitors {
    $list = Join-Path $env:TEMP 'ps5pc-cmm-monitors.txt'
    Remove-Item $list -Force -ErrorAction SilentlyContinue
    Invoke-External $CMM @('/smonitors', $list) 30 | Out-Null
    if (-not (Test-Path $list)) { throw 'ControlMyMonitor /smonitors produced no output.' }
    $monitors = @()
    $current = [ordered]@{}
    foreach ($line in (Get-Content $list) + '') {
        if ($line -match '^\s*([^:]+):\s*"(.*)"\s*$') {
            $current[$Matches[1].Trim()] = $Matches[2]
        } elseif ($current.Count -gt 0) {
            $monitors += [pscustomobject]$current
            $current = [ordered]@{}
        }
    }
    Remove-Item $list -Force -ErrorAction SilentlyContinue
    return $monitors
}

function Read-InputValue([string]$Monitor, [string]$Label) {
    $value = [int](Invoke-External $CMM @('/GetValue', $Monitor, $VcpInputSelect) 30).ExitCode
    if ($value -gt 0) {
        Write-Host "$Label input value detected: $value" -ForegroundColor Green
        return $value
    }
    Write-Host "Couldn't read it automatically. ControlMyMonitor will open: select your monitor, find" -ForegroundColor Yellow
    Write-Host "VCP code 60 'Input Select' and type its Current Value here." -ForegroundColor Yellow
    Start-Process $CMM
    return [int](Read-Host "$Label input value")
}

# MultiMonitorTool writes the file after the process starts; save to a temp name and wait for it,
# so a failed save never destroys the previous layout.
function Save-DisplayLayout([string]$Path) {
    $temp = "$Path.new"
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    $result = Invoke-External $MMT @('/SaveConfig', $temp) 30
    $saved = Wait-Until -Description "Saved $(Split-Path -Leaf $Path)" -TimeoutSec 10 -Condition {
        (Test-Path $temp) -and (Get-Item $temp).Length -gt 0
    }
    if (-not $saved) { throw "MultiMonitorTool /SaveConfig produced no file (exit $($result.ExitCode))." }
    Move-Item -Path $temp -Destination $Path -Force
}

# PS5 layout = the PC layout with the shared monitor disabled. Built automatically, then the PC layout is restored.
function New-PS5Layout($DisplayCfg) {
    Invoke-External $MMT @('/disable', $DisplayCfg.Monitor) 30 | Out-Null
    if (-not (Wait-Until -Description 'Shared monitor disabled' -TimeoutSec 15 -Condition { -not (Test-SharedMonitorActive $DisplayCfg) })) {
        throw 'Windows did not disable the shared monitor. Disable it in Settings > System > Display and rerun setup.'
    }
    Save-DisplayLayout $Ps5Layout
    Restore-PCLayout $DisplayCfg
}

# ---------------------------------------------------------------- setup

try {
    $existing = $null
    if (Test-Path $ConfigPath) { $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json }
    function Get-Existing([string]$Key, [string]$Fallback = '') {
        if ($existing -and $existing.PSObject.Properties[$Key]) { return "$($existing.$Key)" }
        return $Fallback
    }

    Write-Host ''
    Write-Host '=== PS5 / PC ONE-CLICK SWITCH SETUP ===' -ForegroundColor Cyan
    Write-Host 'Before you start:'
    Write-Host '  - PS5: Settings > System > Remote Play > Enable Remote Play'
    Write-Host '  - PS5: Settings > System > Power Saving > Features Available in Rest Mode:'
    Write-Host '         Stay Connected to the Internet + Enable Turning On PS5 from Network'
    Write-Host '  - Shared monitor: DDC/CI turned on in its on-screen menu'
    Write-Host '  - The PS5 must be ON for the first-time pairing'
    if ($existing) { Write-Host 'Existing settings found; press Enter to keep a value shown in [brackets].' -ForegroundColor Green }
    Stop-TrayApp   # the tray must not auto-switch while setup wakes the PS5 and changes displays

    Step 1 'Monitor tools (NirSoft)'
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    Install-NirSoftTool 'https://www.nirsoft.net/utils/controlmymonitor.zip' 'ControlMyMonitor.exe'
    Install-NirSoftTool 'https://www.nirsoft.net/utils/multimonitortool-x64.zip' 'MultiMonitorTool.exe'

    Step 2 'PS5 control tool (ps5-remoteplay)'
    $python = Get-PythonCommand
    if (-not $python) {
        throw "Python 3 is required. Install it from https://www.python.org/downloads/ (tick 'Add Python to PATH') or run: winget install -e --id Python.Python.3.13 -- then rerun Install.ps1."
    }
    Write-Host 'Installing/updating ps5-remoteplay...'
    & $python.Path @($python.Prefix + @('-m', 'pip', 'install', '--user', '--upgrade', '--quiet', 'ps5-remoteplay'))
    if ($LASTEXITCODE -ne 0) { throw 'pip failed to install ps5-remoteplay.' }
    $RemoteExe = Find-PS5Remote
    if (-not $RemoteExe) { throw 'ps5-remoteplay installed, but ps5-remoteplay.exe was not found in the Python Scripts folders.' }
    Write-Host "Found: $RemoteExe" -ForegroundColor Green

    Step 3 'Find and pair your PS5'
    Write-Host 'Searching the network for a PS5...'
    $consoles = @(Find-PS5Consoles $RemoteExe)
    $defaultIP = Get-Existing 'PS5IP'
    foreach ($console in $consoles) { Write-Host "  Found $($console.Name) at $($console.IP) ($($console.Status))" -ForegroundColor Green }
    if (-not $defaultIP -and $consoles.Count -ge 1) { $defaultIP = $consoles[0].IP }
    if ($consoles.Count -eq 0) {
        Write-Host '  No PS5 answered. Find its IP on the PS5: Settings > Network > Connection Status > View Connection Status.' -ForegroundColor Yellow
    }
    $PS5IP = Read-WithDefault 'PS5 IP address' $defaultIP
    if ($PS5IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "'$PS5IP' does not look like an IP address." }
    Write-Host 'Tip: reserve this IP for the PS5 in your router so it never changes.'
    Write-Host 'If your PS5 user has a login passcode, putting the PS5 in Rest Mode needs it.'
    $Passcode = Read-WithDefault 'PS5 login passcode (4 digits, empty if none)' (Get-Existing 'PS5Passcode')
    if ($Passcode -and $Passcode -notmatch '^\d{4}$') { throw 'The PS5 passcode must be 4 digits.' }

    $pair = -not (Test-Path $Credentials)
    if (-not $pair) { $pair = Confirm-No 'This PC is already paired with a PS5. Pair again?' }
    if ($pair) {
        Write-Host 'Pairing: your browser opens a PlayStation sign-in page. Afterwards, the PS5 shows a PIN at'
        Write-Host 'Settings > System > Remote Play > Link Device.'
        & $RemoteExe pair --host $PS5IP
        if ($LASTEXITCODE -ne 0) { throw 'Pairing failed. Keep the PS5 on, check Remote Play is enabled, and rerun setup.' }
    }

    Step 4 'Choose the shared monitor (the one connected to both the PC and the PS5)'
    $displayRows = @(Get-DisplayTopology ([pscustomobject]@{ MultiTool = $MMT }))
    if (@($displayRows | Where-Object { $_.Active -eq 'Yes' }).Count -lt 2) {
        throw 'Only one monitor is active in Windows. PS5 mode needs a second, PC-only monitor to keep Windows on.'
    }
    $ddc = @(Get-DdcMonitors)
    $defaultChoice = 1
    for ($i = 0; $i -lt $ddc.Count; $i++) {
        $name = if ($ddc[$i].'Monitor Name') { $ddc[$i].'Monitor Name' } else { '(no name reported)' }
        $display = $displayRows | Where-Object { $_.'Short Monitor ID' -eq $ddc[$i].'Short Monitor ID' } | Select-Object -First 1
        $size = if ($display) { "$($display.Resolution) $($display.Frequency) Hz" } else { '' }
        Write-Host ("  [{0}] {1,-22} {2,-9} {3}" -f ($i + 1), $name, $ddc[$i].'Short Monitor ID', $size)
        if ($ddc[$i].'Short Monitor ID' -eq (Get-Existing 'Monitor')) { $defaultChoice = $i + 1 }
    }
    Write-Host 'Not sure which one? It is the monitor that has both the PC cable and the PS5 cable plugged in.'
    $Monitor = $ddc[(Read-Choice 'Number of the shared monitor' $ddc.Count $defaultChoice) - 1].'Short Monitor ID'
    Write-Host "Shared monitor: $Monitor" -ForegroundColor Green

    Step 5 'Detect the PC and PS5 inputs'
    $PcInput = Get-Existing 'PCInput'
    $Ps5Input = Get-Existing 'PS5Input'
    if ($PcInput -and $Ps5Input -and -not (Confirm-No "Re-detect inputs (currently PC=$PcInput, PS5=$Ps5Input)?")) {
        $PcInput = [int]$PcInput
        $Ps5Input = [int]$Ps5Input
    } else {
        Write-Host 'Make sure the shared monitor is showing the PC right now.'
        Read-Host 'Press Enter to read the PC input'
        $PcInput = Read-InputValue $Monitor 'PC'
        Write-Host "Now use the monitor's own buttons to switch it to the PS5's input (a black 'no signal' screen is fine)."
        Read-Host 'Press Enter when the monitor is on the PS5 input'
        $Ps5Input = Read-InputValue $Monitor 'PS5'
        if ($Ps5Input -eq $PcInput) { throw 'The PC and PS5 inputs read the same value; rerun setup.' }
        Invoke-External $CMM @('/SetValue', $Monitor, $VcpInputSelect, "$PcInput") 30 | Out-Null
        Write-Host 'Switched the monitor back to the PC.'
    }

    Step 6 'Save your display layouts'
    Write-Host 'Arrange your monitors in Windows exactly how you normally use them (Settings > System > Display).'
    Read-Host 'Press Enter to save this as your PC layout'
    Save-DisplayLayout $PcLayout
    Write-Host 'Creating the PS5 layout: the shared monitor turns off in Windows for a moment, then comes back.'
    $displayCfg = [pscustomobject]@{ Monitor = $Monitor; MultiTool = $MMT; PCLayout = $PcLayout }
    New-PS5Layout $displayCfg
    Write-Host 'Both layouts saved.' -ForegroundColor Green

    Step 7 'Options'
    $autoWake = Confirm-Yes 'Switch to PS5 mode automatically when the PS5 turns on?'
    $autoRest = Confirm-Yes 'Switch back to PC mode automatically when the PS5 goes to Rest Mode?'
    $config = [ordered]@{
        PS5IP              = $PS5IP
        PS5Passcode        = $Passcode
        PS5Remote          = $RemoteExe
        Monitor            = $Monitor
        PCInput            = [int]$PcInput
        PS5Input           = [int]$Ps5Input
        AutoPS5OnWake      = $autoWake
        AutoPCOnStandby    = $autoRest
        StandbyAnimationMs = [int](Get-Existing 'StandbyAnimationMs' '1500')
        ControlTool        = 'Tools\ControlMyMonitor.exe'
        MultiTool          = 'Tools\MultiMonitorTool.exe'
        PCLayout           = 'pc-layout.cfg'
        PS5Layout          = 'ps5-layout.cfg'
    }
    $config | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
    $cfg = Get-SwitchConfig   # validates everything that was just written
    Set-SwitchState 'PC'

    Step 8 'Shortcuts and tray app'
    if (Confirm-Yes 'Create PS5 MODE / PC MODE / TOGGLE shortcuts on the desktop?') {
        $desktop = [Environment]::GetFolderPath('Desktop')
        foreach ($shortcut in $DesktopShortcuts) {
            New-ScriptShortcut (Join-Path $desktop "$($shortcut.Name).lnk") $shortcut.Script $shortcut.Description
        }
        Write-Host 'Desktop shortcuts created.'
    }
    Set-TrayAutostart (Confirm-Yes 'Start the tray app with Windows (needed for automatic switching)?')
    Start-TrayApp
    Write-Host 'Tray app started: look for the green PC icon near the clock (it may be under the ^ arrow).'

    Write-Host ''
    Write-Host 'DONE.' -ForegroundColor Green
    Write-Host 'Try it: right-click the tray icon > Switch to PS5 mode. Problems? Tray menu > Run diagnostics.'
} catch {
    Write-Host ''
    Write-Host "SETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host 'Press Enter to close'
