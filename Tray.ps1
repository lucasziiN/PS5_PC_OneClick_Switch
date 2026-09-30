# PS5 / PC switch tray app.
# - Tray menu: switch modes, auto-switch options, start with Windows, log, diagnostics.
# - Double-click the icon to toggle.
# - Watches the PS5 over the network and switches automatically when it wakes / enters Rest Mode.
# Run with: powershell -STA -WindowStyle Hidden -File Tray.ps1
. (Join-Path $PSScriptRoot 'Common.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$TickMs             = 100   # UI timer; replies are read every tick
$ProbeEveryTicks    = 5     # one PS5 status probe every 500 ms
$ReplyStaleSec      = 5     # no reply for this long -> PS5 shown as "not answering"
$DiscoveryPort      = 9302  # PS5 discovery service; same query as 'ps5-remoteplay status'
$DiscoveryProbe     = [System.Text.Encoding]::ASCII.GetBytes("SRCH * HTTP/1.1`ndevice-discovery-protocol-version:00030010`n")
$StandbyStatusCode  = '620'
$SioUdpConnReset    = -1744830452  # stops Windows reporting ICMP "port unreachable" as a receive error

$trayMutex = New-Object System.Threading.Mutex($false, 'Local\PS5PCTray')
try { $isOnlyTray = $trayMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $isOnlyTray = $true }
if (-not $isOnlyTray) { exit 0 }

# ---------------------------------------------------------------- icons

function New-TrayIcon([string]$Label, [System.Drawing.Color]$Color) {
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = 'AntiAlias'
    $graphics.TextRenderingHint = 'AntiAliasGridFit'
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.FillEllipse((New-Object System.Drawing.SolidBrush $Color), 0, 0, 31, 31)
    $font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = 'Center'
    $format.LineAlignment = 'Center'
    $graphics.DrawString($Label, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 32, 32)), $format)
    $graphics.Dispose()
    return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

$Icons = @{
    PC   = New-TrayIcon 'PC' ([System.Drawing.Color]::FromArgb(0x2E, 0x8B, 0x57))
    PS5  = New-TrayIcon 'PS5' ([System.Drawing.Color]::FromArgb(0x00, 0x43, 0x9C))
    Busy = New-TrayIcon '...' ([System.Drawing.Color]::FromArgb(0xD9, 0x8C, 0x00))
}

# ---------------------------------------------------------------- state

$script:Mode            = 'PC'     # from state.txt / detection
$script:PS5State        = $null    # last definite PS5 reply: 'Awake' or 'Standby'
$script:LastReplyUtc    = [datetime]::MinValue
$script:SwitchProcess   = $null    # running PS5-Mode/PC-Mode/Toggle process
$script:StateFileStamp  = [datetime]::MinValue
$script:Tick            = 0
$script:DisplayKey      = ''       # last icon/tooltip shown; avoids redundant shell updates
$script:LastTickError   = ''       # last status-check error; logged once, not every tick

function Get-PS5Label {
    if (([datetime]::UtcNow - $script:LastReplyUtc).TotalSeconds -gt $ReplyStaleSec) { return 'not answering' }
    if ($script:PS5State -eq 'Standby') { return 'Rest Mode' }
    return 'on'
}

function Update-TrayDisplay {
    $busy = $script:SwitchProcess -ne $null
    $modeText = if ($busy) { 'switching...' } else { "$($script:Mode) mode" }
    $ps5Text = Get-PS5Label
    $key = "$busy|$modeText|$ps5Text"
    if ($key -eq $script:DisplayKey) { return }
    $script:DisplayKey = $key

    $notifyIcon.Icon = if ($busy) { $Icons.Busy } else { $Icons[$script:Mode] }
    $notifyIcon.Text = "PS5 / PC switch: $modeText, PS5 $ps5Text"   # tooltip max 63 chars
    $statusItem.Text = "Now: $modeText   |   PS5: $ps5Text"
    $ps5Item.Enabled = -not $busy
    $pcItem.Enabled = -not $busy
}

function Update-ModeFromStateFile {
    if (-not (Test-Path $StateFile)) { return }
    $stamp = (Get-Item $StateFile).LastWriteTimeUtc
    if ($stamp -eq $script:StateFileStamp) { return }
    $script:StateFileStamp = $stamp
    $mode = Get-SwitchStateFile
    if ($mode -in 'PC', 'PS5') { $script:Mode = $mode }
}

# ---------------------------------------------------------------- actions

function Start-SwitchScript([string]$ScriptName) {
    if ($script:SwitchProcess) { return }
    $script:SwitchProcess = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $Root $ScriptName)`"")
    Update-TrayDisplay
}

function Invoke-Safely([string]$What, [scriptblock]$Action) {
    try { & $Action } catch {
        Write-Log "Tray: $What failed: $($_.Exception.Message)" 'WARN'
        $notifyIcon.ShowBalloonTip(5000, 'PS5 / PC switch', "$What failed: $($_.Exception.Message)", 'Warning')
    }
}

# Reacts to a PS5 state change seen on the network.
function Invoke-PS5Transition([string]$Previous, [string]$Current) {
    Write-Log "PS5 state: $Previous -> $Current"
    # A switch that is already running (from the tray, a shortcut or a console) caused or handles this change.
    if ($script:SwitchProcess -or (Test-SwitchRunning)) { Write-Log 'A switch is already running; leaving it to that.'; return }
    $settings = Get-SwitchConfig   # re-read so option changes apply immediately

    if ($Previous -eq 'Standby' -and $Current -eq 'Awake') {
        if (-not $settings.AutoPS5OnWake) { Write-Log 'PS5 woke up; AutoPS5OnWake is off.'; return }
        Write-Log 'PS5 woke up; running PS5 mode.'
        Start-SwitchScript 'PS5-Mode.ps1'
    } elseif ($Previous -eq 'Awake' -and $Current -eq 'Standby') {
        if (-not $settings.AutoPCOnStandby) { Write-Log 'PS5 entered Rest Mode; AutoPCOnStandby is off.'; return }
        if ((Get-CurrentMode $settings) -ne 'PS5') { Write-Log 'PS5 entered Rest Mode; already in PC mode.'; return }
        Write-Log 'PS5 entered Rest Mode; running PC mode.'
        Start-SwitchScript 'PC-Mode.ps1'
    }
}

# Reads every discovery reply that has arrived; returns the newest state or $null. Never blocks.
function Read-PS5Replies {
    $state = $null
    $sender = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    while ($udp.Available -gt 0) {
        $bytes = $udp.Receive([ref]$sender)
        if (-not $sender.Address.Equals($ps5Endpoint.Address)) { continue }
        $statusLine = ([System.Text.Encoding]::UTF8.GetString($bytes) -split "`n")[0].Trim()   # "HTTP/1.1 620 Server Standby"
        if ($statusLine -notlike 'HTTP*') { continue }
        $state = if (($statusLine -split ' ')[1] -eq $StandbyStatusCode) { 'Standby' } else { 'Awake' }
    }
    return $state
}

function Invoke-TimerTick {
    $script:Tick++

    $state = Read-PS5Replies
    if ($state) {
        $script:LastReplyUtc = [datetime]::UtcNow
        if ($state -ne $script:PS5State) {
            $previous = $script:PS5State
            $script:PS5State = $state
            if ($previous) { Invoke-PS5Transition $previous $state } else { Write-Log "PS5 state: $state" }
        }
    }
    if ($script:Tick % $ProbeEveryTicks -eq 0) {
        [void]$udp.Send($DiscoveryProbe, $DiscoveryProbe.Length, $ps5Endpoint)
        Update-ModeFromStateFile
    }

    if ($script:SwitchProcess -and $script:SwitchProcess.HasExited) {
        $script:SwitchProcess = $null
        Update-ModeFromStateFile
    }
    Update-TrayDisplay
}

# ---------------------------------------------------------------- UI

try {
    $cfg = Get-SwitchConfig
} catch {
    Show-Message "PS5 / PC switch can't start:`n`n$($_.Exception.Message)" 'PS5 / PC switch' 'Error'
    exit 1
}

$udp = New-Object System.Net.Sockets.UdpClient(0)
[void]$udp.Client.IOControl($SioUdpConnReset, [byte[]](0, 0, 0, 0), $null)
$ps5Endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($cfg.PS5IP), $DiscoveryPort)

function Add-MenuSeparator { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add('Now: ...')
$statusItem.Enabled = $false
Add-MenuSeparator
$ps5Item = $menu.Items.Add('Switch to PS5 mode')
$pcItem = $menu.Items.Add('Switch to PC mode')
Add-MenuSeparator
$autoWakeItem = $menu.Items.Add('Switch to PS5 mode when the PS5 turns on')
$autoWakeItem.CheckOnClick = $true
$autoWakeItem.Checked = $cfg.AutoPS5OnWake
$autoRestItem = $menu.Items.Add('Switch to PC mode when the PS5 goes to Rest Mode')
$autoRestItem.CheckOnClick = $true
$autoRestItem.Checked = $cfg.AutoPCOnStandby
$autostartItem = $menu.Items.Add('Start with Windows')
$autostartItem.CheckOnClick = $true
$autostartItem.Checked = Test-TrayAutostart
Add-MenuSeparator
$logItem = $menu.Items.Add('Open log')
$diagnosticsItem = $menu.Items.Add('Run diagnostics')
Add-MenuSeparator
$exitItem = $menu.Items.Add('Exit')

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Icon = $Icons.PC
$notifyIcon.Visible = $true

$ps5Item.add_Click({ Invoke-Safely 'PS5 mode' { Start-SwitchScript 'PS5-Mode.ps1' } })
$pcItem.add_Click({ Invoke-Safely 'PC mode' { Start-SwitchScript 'PC-Mode.ps1' } })
$notifyIcon.add_DoubleClick({ Invoke-Safely 'Toggle' { Start-SwitchScript 'Toggle.ps1' } })
$autoWakeItem.add_Click({
    Invoke-Safely 'Saving option' {
        Set-SwitchConfigValue 'AutoPS5OnWake' $autoWakeItem.Checked
        Write-Log "Tray: AutoPS5OnWake set to $($autoWakeItem.Checked)"
    }
})
$autoRestItem.add_Click({
    Invoke-Safely 'Saving option' {
        Set-SwitchConfigValue 'AutoPCOnStandby' $autoRestItem.Checked
        Write-Log "Tray: AutoPCOnStandby set to $($autoRestItem.Checked)"
    }
})
$autostartItem.add_Click({ Invoke-Safely 'Start with Windows' { Set-TrayAutostart $autostartItem.Checked } })
$logItem.add_Click({ Invoke-Safely 'Open log' { if (Test-Path $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" } } })
$diagnosticsItem.add_Click({
    Invoke-Safely 'Diagnostics' {
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'Diagnostics.ps1')`"")
    }
})
$exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $TickMs
$timer.add_Tick({
    try {
        Invoke-TimerTick
        $script:LastTickError = ''
    } catch {
        # Runs 10x per second: log a failure once, not on every tick.
        if ($_.Exception.Message -ne $script:LastTickError) {
            $script:LastTickError = $_.Exception.Message
            Write-Log "Tray: status check failed: $($script:LastTickError)" 'WARN'
        }
    }
})

try {
    Limit-LogSize
    $isFirstRun = -not ((Test-Path $LogFile) -and (Select-String -Path $LogFile -Pattern 'Tray started' -SimpleMatch -Quiet))
    $script:Mode = Get-CurrentMode $cfg
    Write-Log "Tray started: $($script:Mode) mode, watching PS5 at $($cfg.PS5IP)."
    Update-TrayDisplay
    if ($isFirstRun) {
        $notifyIcon.ShowBalloonTip(6000, 'PS5 / PC switch', 'Running in the tray. Right-click for options, double-click to toggle.', 'Info')
    }
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $udp.Close()
    Write-Log 'Tray stopped.'
    $trayMutex.ReleaseMutex()
    $trayMutex.Dispose()
}
