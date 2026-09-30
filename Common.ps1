# Shared helpers for the PS5 / PC one-click switch. Dot-source this file.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

$ErrorActionPreference = 'Stop'

$Root      = $PSScriptRoot
$LogDir    = Join-Path $Root 'logs'
$LogFile   = Join-Path $LogDir 'switch.log'
$StateFile = Join-Path $Root 'state.txt'

$VcpInputSelect = '60'
$MaxLogBytes    = 1MB

# Problems that should be reported to the user without aborting the switch.
$script:SwitchWarnings = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- logging

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

function Add-SwitchWarning([string]$Message) {
    Write-Log $Message 'WARN'
    $script:SwitchWarnings.Add($Message)
}

function Limit-LogSize {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $MaxLogBytes) {
        Move-Item -Path $LogFile -Destination (Join-Path $LogDir 'switch.old.log') -Force
    }
}

function Show-Message([string]$Text, [string]$Title, [string]$Icon) {
    Add-Type -AssemblyName System.Windows.Forms
    # DefaultDesktopOnly keeps the box in front even when launched from a hidden window.
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', $Icon, 'Button1', 'DefaultDesktopOnly') | Out-Null
}

# ---------------------------------------------------------------- processes

function ConvertTo-ArgumentString([string[]]$Arguments) {
    $parts = foreach ($arg in $Arguments) {
        if ($arg -and $arg -notmatch '[\s"]') { $arg; continue }
        # Windows argv quoting: double backslashes that precede a quote or the closing quote.
        '"' + (($arg -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    $parts -join ' '
}

# Starts a program without waiting. Pair with Wait-External to get its exit code and output.
function Start-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

    $process = [System.Diagnostics.Process]::Start($psi)
    [pscustomobject]@{
        Process   = $process
        FilePath  = $FilePath
        Arguments = $psi.Arguments
        StdOut    = $process.StandardOutput.ReadToEndAsync()
        StdErr    = $process.StandardError.ReadToEndAsync()
    }
}

function Wait-External($Handle, [int]$TimeoutSec = 60) {
    if (-not $Handle.Process.WaitForExit($TimeoutSec * 1000)) {
        try { $Handle.Process.Kill() } catch { }
        throw "$(Split-Path -Leaf $Handle.FilePath) $($Handle.Arguments) did not finish within $TimeoutSec s."
    }
    $Handle.Process.WaitForExit()  # flushes the async output readers
    [pscustomobject]@{
        ExitCode = $Handle.Process.ExitCode
        StdOut   = $Handle.StdOut.Result.Trim()
        StdErr   = $Handle.StdErr.Result.Trim()
    }
}

# Runs a program, waits for it to exit (with timeout) and captures its output.
function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 60
    )
    Wait-External (Start-External $FilePath $Arguments) $TimeoutSec
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$TimeoutSec = 20,
        [int]$IntervalMs = 500
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Condition) {
            Write-Log "$Description (after $($clock.ElapsedMilliseconds) ms)"
            return $true
        }
        Start-Sleep -Milliseconds $IntervalMs
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSec)
    Write-Log "Timed out after $TimeoutSec s waiting for: $Description" 'WARN'
    return $false
}

# ---------------------------------------------------------------- config

function Get-PythonCommand {
    foreach ($name in 'py', 'python', 'python3') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        $prefix = @()
        if ($name -eq 'py') { $prefix = @('-3') }
        try {
            $probe = Invoke-External $cmd.Source ($prefix + @('-c', 'import sys;print(sys.version_info[0])')) 20
        } catch { continue }
        if ($probe.ExitCode -eq 0 -and $probe.StdOut -eq '3') {
            return [pscustomobject]@{ Path = $cmd.Source; Prefix = $prefix }
        }
    }
    return $null
}

# Locates ps5-remoteplay.exe via Python's user (pip --user) and global Scripts folders.
function Find-PS5Remote {
    $python = Get-PythonCommand
    if ($python) {
        $code = "import sysconfig,os;print(sysconfig.get_path('scripts', os.name + '_user'));print(sysconfig.get_path('scripts'))"
        $result = Invoke-External $python.Path ($python.Prefix + @('-c', $code)) 20
        if ($result.ExitCode -eq 0) {
            foreach ($dir in ($result.StdOut -split "`r?`n")) {
                if (-not $dir) { continue }
                $exe = Join-Path $dir.Trim() 'ps5-remoteplay.exe'
                if (Test-Path $exe) { return $exe }
            }
        }
    }
    $cmd = Get-Command 'ps5-remoteplay' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Resolve-ProjectPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $Root $Path
}

function Get-SwitchConfig {
    $configPath = Join-Path $Root 'config.json'
    if (-not (Test-Path $configPath)) { throw "config.json not found in $Root. Run Install.ps1 first." }
    $raw = Get-Content $configPath -Raw | ConvertFrom-Json

    foreach ($key in 'PS5IP', 'Monitor', 'PCInput', 'PS5Input', 'ControlTool', 'MultiTool', 'PCLayout', 'PS5Layout') {
        if (-not $raw.PSObject.Properties[$key] -or -not "$($raw.$key)") { throw "config.json is missing '$key'. Run Install.ps1." }
    }

    $ps5Remote = $null
    if ($raw.PSObject.Properties['PS5Remote'] -and $raw.PS5Remote -and (Test-Path $raw.PS5Remote)) {
        $ps5Remote = $raw.PS5Remote
    } else {
        $ps5Remote = Find-PS5Remote
    }
    if (-not $ps5Remote) { throw 'ps5-remoteplay.exe not found. Run: python -m pip install --user ps5-remoteplay' }

    $passcode = $null
    if ($raw.PSObject.Properties['PS5Passcode']) { $passcode = "$($raw.PS5Passcode)" }

    # How long the shared monitor stays on the PS5 after standby is accepted, so its shutdown screen is seen.
    $standbyAnimationMs = 1500
    if ($raw.PSObject.Properties['StandbyAnimationMs']) { $standbyAnimationMs = [int]$raw.StandbyAnimationMs }

    # Tray options: switch to PS5 mode when the PS5 wakes / back to PC mode when it enters Rest Mode.
    $autoPS5OnWake = $true
    if ($raw.PSObject.Properties['AutoPS5OnWake']) { $autoPS5OnWake = [bool]$raw.AutoPS5OnWake }
    $autoPCOnStandby = $false
    if ($raw.PSObject.Properties['AutoPCOnStandby']) { $autoPCOnStandby = [bool]$raw.AutoPCOnStandby }

    $cfg = [pscustomobject]@{
        PS5IP       = "$($raw.PS5IP)"
        PS5Remote   = $ps5Remote
        PS5Passcode = $passcode
        Monitor     = "$($raw.Monitor)"
        PCInput     = [int]$raw.PCInput
        PS5Input    = [int]$raw.PS5Input
        ControlTool = Resolve-ProjectPath $raw.ControlTool
        MultiTool   = Resolve-ProjectPath $raw.MultiTool
        PCLayout    = Resolve-ProjectPath $raw.PCLayout
        PS5Layout   = Resolve-ProjectPath $raw.PS5Layout
        StandbyAnimationMs = $standbyAnimationMs
        AutoPS5OnWake      = $autoPS5OnWake
        AutoPCOnStandby    = $autoPCOnStandby
    }
    foreach ($key in 'ControlTool', 'MultiTool', 'PCLayout', 'PS5Layout') {
        if (-not (Test-Path $cfg.$key)) { throw "$key not found: $($cfg.$key)" }
    }
    if ($cfg.Monitor -eq 'Primary') {
        throw "config.json Monitor is 'Primary'. Set it to the shared monitor's Short Monitor ID (run Diagnostics.ps1)."
    }
    return $cfg
}

# Changes one setting in config.json, keeping every other setting as it is.
function Set-SwitchConfigValue([string]$Key, $Value) {
    $configPath = Join-Path $Root 'config.json'
    $raw = Get-Content $configPath -Raw | ConvertFrom-Json
    $raw | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    $raw | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

# ---------------------------------------------------------------- shortcuts / tray app

$TrayStartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'PS5 PC Switch.lnk'
$TraySource = Join-Path $Root 'Tray.cs'
$TrayExe = Join-Path $Root 'PS5PCSwitch.exe'

# Creates a shortcut that runs one of this project's scripts in a hidden PowerShell window.
function New-ScriptShortcut([string]$ShortcutPath, [string]$ScriptName, [string]$Description) {
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Root $ScriptName)`""
    $shortcut.WorkingDirectory = $Root
    $shortcut.Description = $Description
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
    $shortcut.WindowStyle = 7  # minimized: keeps the console flash out of sight
    $shortcut.Save()
}

# Compiles Tray.cs into PS5PCSwitch.exe with the C# compiler that ships with .NET Framework 4 on every
# Windows 10/11 PC, so no binary has to be downloaded and no SDK installed.
function Build-TrayApp {
    $compiler = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $compiler) { throw '.NET Framework 4 C# compiler (csc.exe) not found; it is part of every Windows 10/11 install.' }
    $result = Invoke-External $compiler @(
        '/nologo', '/target:winexe', '/optimize+', "/out:$TrayExe",
        '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll', '/r:System.Web.Extensions.dll', '/r:Microsoft.CSharp.dll',
        $TraySource) 120
    if ($result.ExitCode -ne 0) { throw "Building the tray app failed:`n$($result.StdOut)`n$($result.StdErr)" }
}

function Test-TrayAutostart { return Test-Path $TrayStartupShortcut }

function Set-TrayAutostart([bool]$Enabled) {
    if (-not $Enabled) { Remove-Item $TrayStartupShortcut -Force -ErrorAction SilentlyContinue; return }
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($TrayStartupShortcut)
    $shortcut.TargetPath = $TrayExe
    $shortcut.WorkingDirectory = $Root
    $shortcut.Description = 'PS5 / PC switch tray app'
    $shortcut.Save()
}

# Starts the tray app, (re)building it first when Tray.cs is newer than the exe (e.g. after an update).
function Start-TrayApp {
    if (-not (Test-Path $TrayExe) -or (Get-Item $TraySource).LastWriteTimeUtc -gt (Get-Item $TrayExe).LastWriteTimeUtc) {
        Stop-TrayApp
        Build-TrayApp
    }
    Start-Process -FilePath $TrayExe -WorkingDirectory $Root
}

function Stop-TrayApp {
    $running = @(Get-Process -Name 'PS5PCSwitch' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }
    $running | Stop-Process -Force
    # The exe file stays locked until the process has fully exited.
    $null = Wait-Until -Description 'Tray app stopped' -TimeoutSec 5 -IntervalMs 100 -Condition {
        -not (Get-Process -Name 'PS5PCSwitch' -ErrorAction SilentlyContinue)
    }
}

function Set-SwitchState([string]$Mode) {
    $Mode | Set-Content -Path $StateFile -Encoding ASCII
    Write-Log "State file set to $Mode"
}

function Get-SwitchStateFile {
    if (Test-Path $StateFile) { return (Get-Content $StateFile -Raw).Trim() }
    return 'PC'
}

# ---------------------------------------------------------------- PS5

function Get-PS5Status($Cfg) {
    $result = Invoke-External $Cfg.PS5Remote @('status', '--host', $Cfg.PS5IP) 45
    Write-Log "ps5-remoteplay status: exit $($result.ExitCode) $($result.StdOut) $($result.StdErr)"
    switch ($result.ExitCode) {
        0 { return 'Awake' }
        1 { return 'Standby' }
        2 { return 'NotFound' }
        default { return 'Unknown' }
    }
}

function Invoke-PS5Command($Cfg, [string]$Command, [string[]]$ExtraArgs, [int]$TimeoutSec) {
    $arguments = @($Command, '--host', $Cfg.PS5IP) + $ExtraArgs
    Write-Log "ps5-remoteplay $Command ..."
    $result = Invoke-External $Cfg.PS5Remote $arguments $TimeoutSec
    Write-Log "ps5-remoteplay ${Command}: exit $($result.ExitCode) $($result.StdOut) $($result.StdErr)"
    return $result
}

# Sends the wake packet without waiting for the console to boot.
# Returns $true if the console was asleep, so the caller must confirm it with Wait-PS5Awake.
function Send-PS5Wake($Cfg) {
    $status = Get-PS5Status $Cfg
    if ($status -eq 'NotFound') {
        # The console stops answering for a while as it enters Rest Mode; wait that out before giving up.
        $null = Wait-Until -Description 'PS5 answering on the network' -TimeoutSec 90 -IntervalMs 3000 -Condition {
            (Get-PS5Status $Cfg) -in 'Awake', 'Standby'
        }
        $status = Get-PS5Status $Cfg
    }
    if ($status -eq 'Awake') { Write-Log 'PS5 already awake.'; return $false }
    if ($status -eq 'NotFound') {
        throw "PS5 not found at $($Cfg.PS5IP). Is it in Rest Mode (not fully off) and is the IP still correct?"
    }
    $result = Invoke-PS5Command $Cfg 'wake' @('--no-wait') 30
    if ($result.ExitCode -ne 0) {
        throw "PS5 wake failed (exit $($result.ExitCode)): $($result.StdErr) $($result.StdOut)"
    }
    return $true
}

function Wait-PS5Awake($Cfg, [int]$TimeoutSec = 45) {
    Wait-Until -Description 'PS5 awake' -TimeoutSec $TimeoutSec -IntervalMs 500 -Condition { (Get-PS5Status $Cfg) -eq 'Awake' }
}

# Starts the standby command in the background. Returns a handle for Complete-PS5Standby,
# or $null if there is nothing to wait for.
function Start-PS5Standby($Cfg) {
    $status = Get-PS5Status $Cfg
    if ($status -eq 'Standby') { Write-Log 'PS5 already in Rest Mode.'; return $null }
    if ($status -eq 'NotFound') { Write-Log 'PS5 not reachable; assuming it is off.' 'WARN'; return $null }
    $arguments = @('standby', '--host', $Cfg.PS5IP)
    if ($Cfg.PS5Passcode) { $arguments += @('--passcode', $Cfg.PS5Passcode) }
    Write-Log 'ps5-remoteplay standby ... (running in background)'
    return Start-External $Cfg.PS5Remote $arguments
}

# Waits for the standby command to be accepted; from here the console shows its shutdown screen.
function Wait-PS5StandbyAccepted($Handle) {
    $result = Wait-External $Handle 90
    Write-Log "ps5-remoteplay standby: exit $($result.ExitCode) $($result.StdOut) $($result.StdErr)"
    # standby exits 1 ("going into standby") on success, mirroring the status codes; errors use other codes.
    if ($result.ExitCode -notin 0, 1) {
        throw "PS5 standby failed (exit $($result.ExitCode)): $($result.StdErr) $($result.StdOut)"
    }
}

function Wait-PS5Resting($Cfg) {
    # While entering Rest Mode the console stops answering for a while (NotFound); both mean it is no longer awake.
    if (-not (Wait-Until -Description 'PS5 left awake state' -TimeoutSec 60 -IntervalMs 3000 -Condition { (Get-PS5Status $Cfg) -in 'Standby', 'NotFound' })) {
        throw 'PS5 accepted the standby command but was still awake after 60 s.'
    }
}

# ---------------------------------------------------------------- Windows displays
# "Shared monitor" = the monitor wired to both the PC and the PS5 (config.json "Monitor").

function Get-DisplayTopology($Cfg) {
    $csv = Join-Path $env:TEMP "ps5pc-switch-$PID.csv"
    Remove-Item $csv -Force -ErrorAction SilentlyContinue
    $result = Invoke-External $Cfg.MultiTool @('/scomma', $csv) 30
    if (-not (Test-Path $csv)) { throw "MultiMonitorTool /scomma wrote no output (exit $($result.ExitCode))." }
    try { $rows = @(Import-Csv $csv) } finally { Remove-Item $csv -Force -ErrorAction SilentlyContinue }
    return $rows
}

function Test-IsSharedMonitor($Display, $Cfg) {
    return $Display.'Short Monitor ID' -eq $Cfg.Monitor -or $Display.'Monitor ID' -eq $Cfg.Monitor
}

function Test-SharedMonitorActive($Cfg) {
    $shared = Get-DisplayTopology $Cfg | Where-Object { Test-IsSharedMonitor $_ $Cfg } | Select-Object -First 1
    return [bool]($shared -and $shared.Active -eq 'Yes')
}

# ControlMyMonitor returns the VCP value as its exit code; 0 means the monitor was not reachable.
function Get-SharedMonitorInput($Cfg) {
    $result = Invoke-External $Cfg.ControlTool @('/GetValue', $Cfg.Monitor, $VcpInputSelect) 30
    return [int]$result.ExitCode
}

function Set-SharedMonitorInput($Cfg, [int]$Value, [int]$Attempts = 3) {
    $current = Get-SharedMonitorInput $Cfg
    if ($current -eq $Value) { Write-Log "Shared monitor input already VCP 60 = $Value"; return }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Write-Log "Shared monitor VCP 60 reads $current; setting $Value (attempt $attempt/$Attempts)"
        Invoke-External $Cfg.ControlTool @('/SetValue', $Cfg.Monitor, $VcpInputSelect, "$Value") 30 | Out-Null
        # DDC reads return 0 while the monitor re-syncs to the new input.
        if (Wait-Until -Description "Shared monitor input verified: VCP 60 = $Value" -TimeoutSec 5 -IntervalMs 250 -Condition { (Get-SharedMonitorInput $Cfg) -eq $Value }) {
            return
        }
        $current = Get-SharedMonitorInput $Cfg
    }
    throw "Shared monitor ($($Cfg.Monitor)) did not switch to input $Value; VCP 60 reads $current (0 = DDC/CI unreachable)."
}

function Set-DisplayLayout($Cfg, [string]$Layout, [bool]$SharedMonitorActive) {
    $state = if ($SharedMonitorActive) { 'enabled' } else { 'disabled' }
    Write-Log "Loading layout $(Split-Path -Leaf $Layout)"
    Invoke-External $Cfg.MultiTool @('/LoadConfig', $Layout) 30 | Out-Null
    return Wait-Until -Description "Shared monitor $state in Windows" -TimeoutSec 15 -Condition { (Test-SharedMonitorActive $Cfg) -eq $SharedMonitorActive }
}

# Windows may drop the remaining displays to 60 Hz when the shared monitor is detached, even though
# the saved layout has a higher rate. Puts every active PC-only display on its highest supported rate.
function Set-PCOnlyDisplaysMaxRefresh($Cfg) {
    $displays = @(Get-DisplayTopology $Cfg | Where-Object { $_.Active -eq 'Yes' -and -not (Test-IsSharedMonitor $_ $Cfg) })
    if ($displays.Count -eq 0) { throw 'No PC-only display is active in PS5 mode; check ps5-layout.cfg.' }
    # Load only in PS5 mode; PC mode pays no compiler/startup cost.
    if (-not ('SwitchDisplayModes' -as [type])) {
        Add-Type -Path (Join-Path $Root 'DisplayModes.cs')
    }
    foreach ($display in $displays) {
        $deviceName = $display.Name
        $highestHz = [SwitchDisplayModes]::HighestRefreshRate($deviceName)
        $currentHz = [SwitchDisplayModes]::CurrentRefreshRate($deviceName)
        if ($currentHz -eq $highestHz) {
            Write-Log "$deviceName already at maximum: $highestHz Hz"
            continue
        }
        Write-Log "${deviceName}: $currentHz Hz -> highest supported $highestHz Hz"
        [SwitchDisplayModes]::SetRefreshRate($deviceName, $highestHz)
        if (-not (Wait-Until -Description "$deviceName verified at $highestHz Hz" -TimeoutSec 5 -IntervalMs 100 -Condition {
            [SwitchDisplayModes]::CurrentRefreshRate($deviceName) -eq $highestHz
        })) {
            throw "$deviceName did not reach $highestHz Hz."
        }
    }
}

# PC mode = shared monitor attached to the Windows desktop and not showing the PS5 input.
function Get-CurrentMode($Cfg) {
    try {
        if (-not (Test-SharedMonitorActive $Cfg)) { return 'PS5' }
        if ((Get-SharedMonitorInput $Cfg) -eq $Cfg.PS5Input) { return 'PS5' }
        return 'PC'
    } catch {
        $fallback = Get-SwitchStateFile
        Write-Log "Could not detect current mode ($($_.Exception.Message)); using state.txt = $fallback" 'WARN'
        return $fallback
    }
}

# ---------------------------------------------------------------- modes

# The PS5 boots (~10 s) while the displays switch (~4 s). The shared monitor is only detached after the
# wake command was accepted, and if the console never comes up the PC displays are restored.
function Invoke-PS5Mode($Cfg) {
    $wakePending = Send-PS5Wake $Cfg

    if (Test-SharedMonitorActive $Cfg) {
        # DDC/CI only reaches a monitor while Windows still drives it, so switch input before detaching.
        Set-SharedMonitorInput $Cfg $Cfg.PS5Input
        if (-not (Set-DisplayLayout $Cfg $Cfg.PS5Layout $false)) {
            throw 'Windows did not disable the shared monitor after loading ps5-layout.cfg.'
        }
    } else {
        Write-Log 'Shared monitor already disabled in Windows; display side is already in PS5 mode.'
    }
    Set-PCOnlyDisplaysMaxRefresh $Cfg

    if ($wakePending -and -not (Wait-PS5Awake $Cfg)) {
        Write-Log 'PS5 did not wake; restoring PC displays.' 'WARN'
        Restore-PCDisplays $Cfg
        Set-SwitchState 'PC'
        throw 'The PS5 did not wake within 45 s after the wake command. PC displays were restored.'
    }
    Set-SwitchState 'PS5'
}

# Re-attaches the shared monitor and restores pc-layout.cfg. The monitor stays on its current input.
function Restore-PCLayout($Cfg) {
    if (-not (Test-SharedMonitorActive $Cfg)) {
        # MultiMonitorTool cannot re-attach a disabled monitor on current Windows 11 builds (its /enable and
        # /LoadConfig silently do nothing). Windows' own extend topology can, and it restores the
        # extended arrangement stored in the Windows display database.
        Write-Log 'Re-attaching shared monitor via DisplaySwitch /extend'
        Invoke-External (Join-Path $env:SystemRoot 'System32\DisplaySwitch.exe') @('/extend') 30 | Out-Null
        if (-not (Wait-Until -Description 'Shared monitor enabled in Windows' -TimeoutSec 15 -Condition { Test-SharedMonitorActive $Cfg })) {
            throw 'Windows did not re-enable the shared monitor (DisplaySwitch /extend).'
        }
    }
    # Enforce the exact saved arrangement (positions, primary, refresh rates, rotation).
    if (-not (Set-DisplayLayout $Cfg $Cfg.PCLayout $true)) {
        throw 'Shared monitor dropped out of the Windows desktop after loading pc-layout.cfg.'
    }
}

# Restores the layout and switches the shared monitor to the PC input immediately.
function Restore-PCDisplays($Cfg) {
    Restore-PCLayout $Cfg
    Set-SharedMonitorInput $Cfg $Cfg.PCInput
}

# Standby runs in the background while the layout is restored. The shared monitor is switched to the PC
# only after the PS5 accepted standby plus StandbyAnimationMs, so the shutdown screen stays visible.
function Invoke-PCMode($Cfg) {
    $standby = $null
    try { $standby = Start-PS5Standby $Cfg } catch { Add-SwitchWarning $_.Exception.Message }
    Restore-PCLayout $Cfg

    $standbyAccepted = $false
    if ($standby) {
        try {
            Wait-PS5StandbyAccepted $standby
            $standbyAccepted = $true
            Write-Log "Holding $($Cfg.StandbyAnimationMs) ms on the PS5 for its shutdown animation."
            Start-Sleep -Milliseconds $Cfg.StandbyAnimationMs
        } catch { Add-SwitchWarning $_.Exception.Message }
    }

    Set-SharedMonitorInput $Cfg $Cfg.PCInput
    if ($standbyAccepted) {
        try { Wait-PS5Resting $Cfg } catch { Add-SwitchWarning $_.Exception.Message }
    }
    Set-SwitchState 'PC'
}

$SwitchMutexName = 'Local\PS5PCOneClickSwitch'

# True while a PS5-Mode/PC-Mode/Toggle run holds the switch lock (from any shortcut, the tray, or a console).
function Test-SwitchRunning {
    $mutex = New-Object System.Threading.Mutex($false, $SwitchMutexName)
    try {
        try { $free = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
        if ($free) { $mutex.ReleaseMutex() }
        return -not $free
    } finally { $mutex.Dispose() }
}

# Runs one switch action with logging, a single-instance lock and visible errors.
function Invoke-SwitchAction([string]$Name, [scriptblock]$Action) {
    Limit-LogSize
    $mutex = New-Object System.Threading.Mutex($false, $SwitchMutexName)
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Write-Log "$Name ignored: another switch is already running." 'WARN'
        $mutex.Dispose()
        return
    }

    $failure = $null
    try {
        Write-Log "===== $Name start ====="
        $cfg = Get-SwitchConfig
        & $Action $cfg
        Write-Log "===== $Name done ====="
    } catch {
        $failure = $_.Exception.Message
        Write-Log "$Name FAILED: $failure" 'ERROR'
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }

    if ($failure) {
        Show-Message "$Name failed:`n`n$failure`n`nLog: $LogFile" 'PS5 / PC switch' 'Error'
        exit 1
    }
    if ($script:SwitchWarnings.Count -gt 0) {
        Show-Message ("$Name finished with warnings:`n`n" + ($script:SwitchWarnings -join "`n") + "`n`nLog: $LogFile") 'PS5 / PC switch' 'Warning'
    }
}
