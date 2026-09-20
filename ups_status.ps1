#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet("show", "monitor", "web")]
    [string]$Mode = "web"
)

# ================================================================
# 1. LOAD CONFIG
# ================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath = Join-Path $ScriptDir "ups_shutdown.cfg"
$LOG_DIR = Join-Path $ScriptDir "logs"

$cfg = @{
    MODE                = 1
    DIALOG_TIMEOUT_SEC  = 60
    POSTPONE_MINUTES    = 5
    SHUTDOWN_GRACE_SEC  = 10
    POLL_INTERVAL       = 5
    NUT_HOST            = "192.168.0.15"
    NUT_PORT            = 3493
    UPS_NAME            = "ups"
    WEB_PORT            = 9921
    WEB_HOST            = "localhost"
    WEB_REFRESH         = 5
    ONLINE_LOG_INTERVAL = 3600
    EVENT_LOG_INTERVAL  = 5
    MAX_FILE_SIZE_MB    = 50
    MAX_TOTAL_SIZE_MB   = 500
}

if (Test-Path $CfgPath) {
    Get-Content $CfgPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        if ($line -match '^([^=]+)=(.+)$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim().Trim('"').Trim("'")
            if ($cfg.ContainsKey($k)) { $cfg[$k] = $v }
        }
    }
}

$SHUTDOWN_MODE = [int]$cfg['MODE']
$DIALOG_TIMEOUT = [int]$cfg['DIALOG_TIMEOUT_SEC']
$POSTPONE_MIN = [int]$cfg['POSTPONE_MINUTES']
$SHUTDOWN_GRACE = [int]$cfg['SHUTDOWN_GRACE_SEC']
$POLL_INTERVAL = [int]$cfg['POLL_INTERVAL']
$NUT_HOST = [string]$cfg['NUT_HOST']
$NUT_PORT = [int]$cfg['NUT_PORT']
$UPS_NAME = [string]$cfg['UPS_NAME']
$WebPort = [int]$cfg['WEB_PORT']
$WebHost = [string]$cfg['WEB_HOST']
$WebRefresh = [int]$cfg['WEB_REFRESH']
$ONLINE_LOG_INTERVAL = [int]$cfg['ONLINE_LOG_INTERVAL']
$EVENT_LOG_INTERVAL = [int]$cfg['EVENT_LOG_INTERVAL']
$MAX_FILE_SIZE = [int]$cfg['MAX_FILE_SIZE_MB'] * 1MB
$MAX_TOTAL_SIZE = [int]$cfg['MAX_TOTAL_SIZE_MB'] * 1MB

$ONLINE_FILE_NAME = "ups_online.txt"
$EVENT_FILE_PREFIX = "ups_power_event"

$UPS_VARS = @(
    "battery.charge", "battery.charge.low", "battery.charge.warning",
    "battery.runtime", "battery.runtime.low", "battery.status",
    "battery.type", "battery.voltage", "battery.voltage.nominal",
    "device.mfr", "device.model", "device.serial", "device.type",
    "driver.name", "driver.state", "driver.version", "driver.version.data",
    "driver.version.internal", "driver.version.usb",
    "input.frequency", "input.transfer.high", "input.transfer.low",
    "input.voltage", "input.voltage.nominal", "output.voltage",
    "ups.beeper.status", "ups.delay.shutdown", "ups.delay.start",
    "ups.firmware", "ups.load", "ups.mfr", "ups.model",
    "ups.power.nominal", "ups.realpower.nominal", "ups.serial",
    "ups.status", "ups.test.result", "ups.timer.shutdown", "ups.timer.start",
    "ups.vendorid", "ups.productid"
)

# ================================================================
# 2. STATE
# ================================================================
$script:LastOnlineLog = 0
$script:EventFile = $null
$script:LastEventWrite = 0
$script:OnBatterySince = $null
$script:ShutdownPostponedTill = $null
$script:ShutdownIssued = $false

# ================================================================
# 3. UTILITIES
# ================================================================
function Get-UnixTime { [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }

function Ensure-LogDir {
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -Path $LOG_DIR -ItemType Directory -Force | Out-Null
    }
}

function Write-LogLine {
    param([string]$Path, [string]$Line, [switch]$NoAppend)
    $enc = New-Object System.Text.UTF8Encoding($false)
    if ($NoAppend) {
        [System.IO.File]::WriteAllText($Path, $Line + "`r`n", $enc)
    }
    else {
        [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $enc)
    }
}

function Format-LogLine {
    param([hashtable]$Vars)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # --- Status ---
    $sr = if ($Vars.ContainsKey("ups.status")) { $Vars["ups.status"] } else { "" }
    if ($sr -match "OL")      { $st = "OnLine" }
    elseif ($sr -match "OB")  { $st = "OnBattery" }
    else                      { $st = $sr }

    # --- Основные значения ---
    $charge  = if ($Vars.ContainsKey("battery.charge"))        { $Vars["battery.charge"] }        else { "?" }
    $runtime = if ($Vars.ContainsKey("battery.runtime"))       { $Vars["battery.runtime"] }       else { "?" }
    $load    = if ($Vars.ContainsKey("ups.load"))              { $Vars["ups.load"] }              else { "?" }
    $inV     = if ($Vars.ContainsKey("input.voltage"))         { $Vars["input.voltage"] }         else { $null }
    $outV    = if ($Vars.ContainsKey("output.voltage"))        { $Vars["output.voltage"] }        else { $null }
    $inF     = if ($Vars.ContainsKey("input.frequency"))       { $Vars["input.frequency"] }       else { $null }
    $pNom    = if ($Vars.ContainsKey("ups.realpower.nominal")) { $Vars["ups.realpower.nominal"] } else { $null }

    # --- Расчёт потребления в Ваттах ---
    $watts = "?"
    if ($load -ne "?" -and $pNom -and $pNom -ne "0" -and $pNom -ne "?") {
        $watts = [math]::Round(([double]$load / 100.0) * [double]$pNom)
    }

    # --- Расчёт состояния AVR ---
    # Boost  = ИБП повышает напряжение (сеть просела)
    # Trim   = ИБП понижает напряжение (сеть завышена)
    # Normal = пропускает как есть
    $avr = "?"
    if ($inV -and $outV) {
        $diff = [double]$outV - [double]$inV
        if ($diff -gt 10)       { $avr = "Boost" }
        elseif ($diff -lt -10)  { $avr = "Trim" }
        else                    { $avr = "Normal" }
    }

    # --- Сборка строки ---
    $line = "[$ts] Status`t$st" +
            "`tCharge`t$charge %" +
            "`tRuntime`t$runtime s" +
            "`tLoad`t$load %" +
            "`tUsage`t$watts W of $pNom W"
    if ($inV)         { $line += "`tIn`t$inV V" }
    if ($outV)        { $line += "`tOut`t$outV V" }
    if ($avr -ne "?") { $line += "`tAVR`t$avr" }
    if ($inF)         { $line += "`tFreq`t$inF Hz" }

    return $line
}

function Rotate-FileIfNeeded {
    param([string]$Path)
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -ge $MAX_FILE_SIZE)) {
        $dir = Split-Path -Parent $Path
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $ext = [System.IO.Path]::GetExtension($Path)
        $ts = Get-Date -Format "yyyyMMdd_HHmmss"
        $new = Join-Path $dir "${base}_${ts}${ext}"
        Move-Item -Path $Path -Destination $new -Force
        return $null
    }
    return $Path
}

function Cleanup-OldEventFiles {
    $pattern = Join-Path $LOG_DIR "$EVENT_FILE_PREFIX*.txt"
    $files = @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object CreationTime)
    if ($files.Count -eq 0) { return }
    $total = ($files | Measure-Object -Property Length -Sum).Sum
    while ($total -gt $MAX_TOTAL_SIZE -and $files.Count -gt 0) {
        $oldest = $files[0]
        $total -= $oldest.Length
        Remove-Item -Path $oldest.FullName -Force -ErrorAction SilentlyContinue
        if ($files.Count -le 1) { break }
        $files = $files[1..($files.Count - 1)]
    }
}

function Start-EventLogging {
    param([hashtable]$Vars)
    $ts = Get-Date -Format "yyyyMMdd_HH-mm-ss"
    $filename = Join-Path $LOG_DIR "${EVENT_FILE_PREFIX}_${ts}.txt"
    $header = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === EVENT START (power lost) ==="
    Write-LogLine -Path $filename -Line $header -NoAppend
    Write-LogLine -Path $filename -Line (Format-LogLine -Vars $Vars)
    $script:EventFile = $filename
    $script:LastEventWrite = (Get-UnixTime) - $EVENT_LOG_INTERVAL
}

function Continue-EventLogging {
    param([hashtable]$Vars)
    $ts = Get-Date -Format "yyyyMMdd_HH-mm-ss"
    $newFile = Join-Path $LOG_DIR "${EVENT_FILE_PREFIX}_${ts}.txt"
    $header = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === EVENT CONTINUED (file rotation) ==="
    Write-LogLine -Path $newFile -Line $header -NoAppend
    Write-LogLine -Path $newFile -Line (Format-LogLine -Vars $Vars)
    $script:EventFile = $newFile
}

function Stop-EventLogging {
    param([int]$ChargeInt)
    if ($script:EventFile) {
        $endHeader = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === EVENT END (power restored, charge ${ChargeInt}%) ==="
        Write-LogLine -Path $script:EventFile -Line $endHeader
        $script:EventFile = $null
        Cleanup-OldEventFiles
    }
}

function Write-OnlineLog {
    param([hashtable]$Vars)
    $filename = Join-Path $LOG_DIR $ONLINE_FILE_NAME
    $rotated = Rotate-FileIfNeeded -Path $filename
    if ($null -eq $rotated) { $filename = Join-Path $LOG_DIR $ONLINE_FILE_NAME }
    Write-LogLine -Path $filename -Line (Format-LogLine -Vars $Vars)
}

function Write-EventLog {
    param([hashtable]$Vars)
    if (-not $script:EventFile) { return }
    $rotated = Rotate-FileIfNeeded -Path $script:EventFile
    if ($null -eq $rotated) { Continue-EventLogging -Vars $Vars }
    else { Write-LogLine -Path $script:EventFile -Line (Format-LogLine -Vars $Vars) }
}

# ================================================================
# 4. NUT CLIENT
# ================================================================
function Get-UPSVars {
    $result = @{}
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($NUT_HOST, $NUT_PORT, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000, $false)) {
            throw "Timeout connecting to ${NUT_HOST}:${NUT_PORT}"
        }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 5000

        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true

        $writer.WriteLine("LIST VAR $UPS_NAME")
        $gotList = $false
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -eq "END LIST VAR $UPS_NAME") { break }
            if ($line -match "^ERR ") { break }
            if ($line -match ("^VAR " + [regex]::Escape($UPS_NAME) + " (\S+) `"(.*)`"$")) {
                $result[$matches[1]] = $matches[2]
                $gotList = $true
            }
        }

        if (-not $gotList) {
            foreach ($v in $UPS_VARS) {
                $writer.WriteLine("GET VAR $UPS_NAME $v")
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                if ($line -match ("^VAR " + [regex]::Escape($UPS_NAME) + " (\S+) `"(.*)`"$")) {
                    $result[$matches[1]] = $matches[2]
                }
            }
        }
    }
    catch {
        return @{ "error" = $_.Exception.Message }
    }
    finally {
        if ($client) { try { $client.Close() } catch {} }
    }
    return $result
}

# ================================================================
# 5. SHUTDOWN DIALOG
# ================================================================
function Show-ShutdownDialog {
    param(
        [int]$TimeoutSec,
        [int]$PostponeMinutes,
        [string]$Title,
        [string]$Reason,
        [string]$Info
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "UPS Alert"
    $form.ClientSize = New-Object System.Drawing.Size(560, 330)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 46)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = $Title
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(243, 139, 168)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.Size = New-Object System.Drawing.Size(520, 40)
    $form.Controls.Add($lblTitle)

    $lblReason = New-Object System.Windows.Forms.Label
    $lblReason.Text = $Reason
    $lblReason.Location = New-Object System.Drawing.Point(20, 65)
    $lblReason.Size = New-Object System.Drawing.Size(520, 40)
    $lblReason.ForeColor = [System.Drawing.Color]::FromArgb(205, 214, 244)
    $form.Controls.Add($lblReason)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = $Info
    $lblInfo.Location = New-Object System.Drawing.Point(20, 110)
    $lblInfo.Size = New-Object System.Drawing.Size(520, 40)
    $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(166, 173, 200)
    $form.Controls.Add($lblInfo)

    $lblCountdown = New-Object System.Windows.Forms.Label
    $lblCountdown.Location = New-Object System.Drawing.Point(20, 160)
    $lblCountdown.Size = New-Object System.Drawing.Size(520, 45)
    $lblCountdown.Font = New-Object System.Drawing.Font("Segoe UI", 17, [System.Drawing.FontStyle]::Bold)
    $lblCountdown.ForeColor = [System.Drawing.Color]::FromArgb(249, 226, 175)
    $lblCountdown.TextAlign = "MiddleLeft"
    $form.Controls.Add($lblCountdown)

    $btnNow = New-Object System.Windows.Forms.Button
    $btnNow.Text = "Shutdown Now"
    $btnNow.Location = New-Object System.Drawing.Point(20, 230)
    $btnNow.Size = New-Object System.Drawing.Size(200, 60)
    $btnNow.BackColor = [System.Drawing.Color]::FromArgb(243, 139, 168)
    $btnNow.ForeColor = [System.Drawing.Color]::Black
    $btnNow.FlatStyle = "Flat"
    $btnNow.FlatAppearance.BorderSize = 0
    $btnNow.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnNow)

    $btnPost = New-Object System.Windows.Forms.Button
    $btnPost.Text = "Postpone $PostponeMinutes min"
    $btnPost.Location = New-Object System.Drawing.Point(240, 230)
    $btnPost.Size = New-Object System.Drawing.Size(200, 60)
    $btnPost.BackColor = [System.Drawing.Color]::FromArgb(137, 220, 235)
    $btnPost.ForeColor = [System.Drawing.Color]::Black
    $btnPost.FlatStyle = "Flat"
    $btnPost.FlatAppearance.BorderSize = 0
    $btnPost.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnPost)

    $script:dialogRemaining = $TimeoutSec
    $script:dialogResult = "timeout"

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
            $script:dialogRemaining--
            if ($script:dialogRemaining -le 0) {
                $script:dialogRemaining = 0
                $timer.Stop()
                $script:dialogResult = "shutdown"
                $form.Close()
            }
            else {
                $lblCountdown.Text = "Auto-shutdown in: $($script:dialogRemaining) s"
            }
        })

    $lblCountdown.Text = "Auto-shutdown in: $($script:dialogRemaining) s"

    $btnNow.Add_Click({
            $script:dialogResult = "shutdown"
            $timer.Stop()
            $form.Close()
        })

    $btnPost.Add_Click({
            $script:dialogResult = "postpone"
            $timer.Stop()
            $form.Close()
        })

    $form.Add_FormClosing({
            param($s, $e)
            if ($script:dialogResult -eq "timeout") {
                $script:dialogResult = "postpone"
                $timer.Stop()
            }
        })

    $timer.Start()
    [void]$form.ShowDialog()
    $form.Dispose()

    return $script:dialogResult
}

# ================================================================
# 6. SHUTDOWN TRIGGER LOGIC
# ================================================================
function Invoke-ShutdownCheck {
    param([hashtable]$Vars)

    $statusRaw = if ($Vars.ContainsKey("ups.status")) { $Vars["ups.status"] } else { "" }
    $chargeInt = 0
    if ($Vars.ContainsKey("battery.charge")) {
        [int]::TryParse($Vars["battery.charge"], [ref]$chargeInt) | Out-Null
    }
    $runtimeInt = 0
    if ($Vars.ContainsKey("battery.runtime")) {
        [int]::TryParse($Vars["battery.runtime"], [ref]$runtimeInt) | Out-Null
    }
    $loadInt = 0
    if ($Vars.ContainsKey("ups.load")) {
        [int]::TryParse($Vars["ups.load"], [ref]$loadInt) | Out-Null
    }

    $onBattery = ($statusRaw -match "OB")

    if (-not $onBattery) {
        if ($null -ne $script:OnBatterySince) {
            Write-Host ("[{0}] AC restored. Shutdown state reset." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Green
        }
        $script:OnBatterySince = $null
        $script:ShutdownPostponedTill = $null
        $script:ShutdownIssued = $false
        return
    }

    if ($null -eq $script:OnBatterySince) {
        $script:OnBatterySince = Get-Date
        Write-Host ("[{0}] On battery since {1}." -f (Get-Date -Format 'HH:mm:ss'), $script:OnBatterySince.ToString('HH:mm:ss')) -ForegroundColor Yellow
    }

    if ($script:ShutdownIssued) { return }

    $trigger = $false
    $reason = ""
    $onBattMin = ((Get-Date) - $script:OnBatterySince).TotalMinutes

    if ($SHUTDOWN_MODE -ge 1 -and $SHUTDOWN_MODE -le 4) {
        $thresholds = @(1, 5, 10, 30)
        $t = $thresholds[$SHUTDOWN_MODE - 1]
        if ($onBattMin -ge $t) {
            $trigger = $true
            $reason = "UPS has been on battery for $([math]::Round($onBattMin,1)) min (threshold: $t min)."
        }
    }
    elseif ($SHUTDOWN_MODE -ge 5 -and $SHUTDOWN_MODE -le 8) {
        $thresholds = @(50, 25, 10, 5)
        $t = $thresholds[$SHUTDOWN_MODE - 5]
        if ($chargeInt -le $t) {
            $trigger = $true
            $reason = "Battery charge is $chargeInt% (threshold: $t%)."
        }
    }
    else {
        return
    }

    if (-not $trigger) { return }

    $now = Get-Date
    if ($null -ne $script:ShutdownPostponedTill -and $now -lt $script:ShutdownPostponedTill) {
        return
    }

    $modeText = switch ($SHUTDOWN_MODE) {
        1 { "1 min on battery" }
        2 { "5 min on battery" }
        3 { "10 min on battery" }
        4 { "30 min on battery" }
        5 { "50% charge" }
        6 { "25% charge" }
        7 { "10% charge" }
        8 { "5% charge" }
    }

    $info = "Charge: $chargeInt%  |  Runtime: $([math]::Round($runtimeInt/60,1)) min  |  Load: $loadInt%"
    Write-Host ("[{0}] SHUTDOWN TRIGGER: {1}" -f (Get-Date -Format 'HH:mm:ss'), $reason) -ForegroundColor Red

    $result = Show-ShutdownDialog -TimeoutSec $DIALOG_TIMEOUT -PostponeMinutes $POSTPONE_MIN `
        -Title "UPS: Power Failure" `
        -Reason "$reason  Mode: $modeText." `
        -Info $info

    switch ($result) {
        "shutdown" {
            Write-Host ("[{0}] User chose Shutdown Now (or timeout). Executing shutdown in {1} s..." -f (Get-Date -Format 'HH:mm:ss'), $SHUTDOWN_GRACE) -ForegroundColor Red
            $script:ShutdownIssued = $true
            if ($script:EventFile) {
                Write-LogLine -Path $script:EventFile -Line ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === USER CONFIRMED SHUTDOWN ===")
            }
            & shutdown.exe /s /t $SHUTDOWN_GRACE /c "UPS triggered shutdown: $reason"
        }
        "postpone" {
            $script:ShutdownPostponedTill = (Get-Date).AddMinutes($POSTPONE_MIN)
            Write-Host ("[{0}] Postponed until {1}" -f (Get-Date -Format 'HH:mm:ss'), $script:ShutdownPostponedTill.ToString('HH:mm:ss')) -ForegroundColor Yellow
            if ($script:EventFile) {
                Write-LogLine -Path $script:EventFile -Line ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === SHUTDOWN POSTPONED until $($script:ShutdownPostponedTill.ToString('yyyy-MM-dd HH:mm:ss')) ===")
            }
        }
    }
}

# ================================================================
# 7. LOGGER ITERATION
# ================================================================
function Invoke-LoggerIteration {
    param([hashtable]$Vars)

    if ($Vars.ContainsKey("error")) { return }

    $currentStatus = if ($Vars.ContainsKey("ups.status")) { $Vars["ups.status"] } else { "" }
    $chargeInt = 0
    if ($Vars.ContainsKey("battery.charge")) {
        [int]::TryParse($Vars["battery.charge"], [ref]$chargeInt) | Out-Null
    }

    $now = Get-UnixTime
    if ($now - $script:LastOnlineLog -ge $ONLINE_LOG_INTERVAL) {
        Write-OnlineLog -Vars $Vars
        Write-Host ("[{0}] Online log written." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
        $script:LastOnlineLog = $now
    }

    $eventActive = ($currentStatus -notmatch "OL") -or ($chargeInt -lt 100)

    if ($eventActive -and -not $script:EventFile) {
        Start-EventLogging -Vars $Vars
        Write-Host ("[{0}] EVENT START (power lost or charge < 100%%)" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Yellow
    }
    elseif (-not $eventActive -and $script:EventFile) {
        Stop-EventLogging -ChargeInt $chargeInt
        Write-Host ("[{0}] EVENT END (power restored, charge {1}%%)" -f (Get-Date -Format 'HH:mm:ss'), $chargeInt) -ForegroundColor Green
    }

    if ($eventActive -and $script:EventFile) {
        $now2 = Get-UnixTime
        if ($now2 - $script:LastEventWrite -ge $EVENT_LOG_INTERVAL) {
            Write-EventLog -Vars $Vars
            $script:LastEventWrite = $now2
        }
    }

    Invoke-ShutdownCheck -Vars $Vars
}

# ================================================================
# 8. HTML PAGE
# ================================================================
function Get-HtmlPage {
    param([int]$RefreshSec)
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>UPS Status</title>
<link id="favicon" rel="icon" type="image/png" href="/sphere-green.png">
<style>
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #1e1e2e; color: #eee; margin: 0; padding: 20px; }
  h1 { color: #89dceb; margin: 0 0 4px 0; }
  .sub { color: #888; font-size: 12px; margin-bottom: 20px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; max-width: 1100px; }
  .card { background: #2a2a3e; border-radius: 8px; padding: 14px 18px; border-left: 4px solid #89dceb; }
  .card.green { border-color: #a6e3a1; }
  .card.yellow { border-color: #f9e2af; }
  .card.red { border-color: #f38ba8; }
  .card.magenta { border-color: #cba6f7; }
  .label { color: #888; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
  .value { font-size: 22px; font-weight: 600; margin-top: 4px; }
  .value.small { font-size: 16px; }
  .value .hint { font-size: 12px; color: #888; font-weight: 400; }
  details { margin-top: 24px; max-width: 1100px; background: #2a2a3e; border-radius: 8px; padding: 12px 18px; }
  summary { cursor: pointer; font-weight: 600; color: #cba6f7; }
  table { border-collapse: collapse; width: 100%; margin-top: 12px; font-size: 13px; }
  th, td { border-bottom: 1px solid #444; padding: 6px 10px; text-align: left; }
  th { color: #89dceb; }
  #error { display: none; background: #f38ba8; color: #1e1e2e; padding: 12px; border-radius: 6px; margin-bottom: 16px; font-weight: 600; }
  .footer { color: #666; font-size: 12px; margin-top: 20px; }
</style>
</head>
<body>
  <h1>UPS Status</h1>
  <div class="sub">NUT server &middot; refresh every $RefreshSec s &middot; <span id="last-update">-</span></div>
  <div id="error"></div>
  <div class="grid">
    <div class="card" id="c-status"><div class="label">Status</div><div class="value" id="v-status">-</div></div>
    <div class="card" id="c-charge"><div class="label">Battery charge</div><div class="value" id="v-charge">-</div></div>
    <div class="card" id="c-runtime"><div class="label">Runtime left</div><div class="value" id="v-runtime">-</div></div>
    <div class="card" id="c-load"><div class="label">Load</div><div class="value" id="v-load">-</div></div>
    <div class="card" id="c-usage"><div class="label">Estimated usage</div><div class="value" id="v-usage">-</div></div>
    <div class="card"><div class="label">Input voltage</div><div class="value small" id="v-input">-</div></div>
    <div class="card"><div class="label">Output voltage</div><div class="value small" id="v-output">-</div></div>
    <div class="card"><div class="label">Model</div><div class="value small" id="v-model">-</div></div>
    <div class="card"><div class="label">Nominal power</div><div class="value small" id="v-power">-</div></div>
  </div>
  <details>
    <summary>All UPS parameters</summary>
    <table id="full-table"><thead><tr><th>Parameter</th><th>Value</th></tr></thead><tbody></tbody></table>
  </details>
  <div class="footer" id="footer">-</div>
<script>
const REFRESH = $RefreshSec * 1000;

function fmtRuntime(sec){sec=parseInt(sec);if(isNaN(sec))return '-';return Math.floor(sec/60)+' min '+(sec%60)+' s';}
function setCard(id,cls){document.getElementById(id).className='card'+(cls?' '+cls:'');}
function setFavicon(name){document.getElementById('favicon').href='/'+name;}

function updateFaviconAndTitle(status, charge, statusText){
  let icon = 'sphere-green.png';
  if (status.includes('OB')) {
    icon = 'sphere-red.png';
  } else if (status.includes('OL')) {
    if (isNaN(charge)) { icon = 'sphere-green.png'; }
    else if (charge < 25) { icon = 'sphere-magenta.png'; }
    else if (charge < 90) { icon = 'sphere-orange.png'; }
    else { icon = 'sphere-green.png'; }
  }
  setFavicon(icon);
  const title = isNaN(charge) ? '(' + (statusText || '?') + ')' : '(' + charge + '%) ' + (statusText || '');
  document.title = title;
}

function setErrorState(msg) {
  const errEl = document.getElementById('error');
  errEl.style.display = 'block';
  errEl.textContent = 'Error: ' + msg;

  setFavicon('error.png');
  document.title = '(!) UPS unreachable';

  document.getElementById('v-status').textContent  = '-';
  document.getElementById('v-charge').textContent  = '-';
  document.getElementById('v-runtime').textContent = '-';
  document.getElementById('v-load').textContent    = '-';
  document.getElementById('v-usage').textContent   = '-';
  document.getElementById('v-input').textContent   = '-';
  document.getElementById('v-output').textContent  = '-';
  document.getElementById('v-model').textContent   = '-';
  document.getElementById('v-power').textContent   = '-';
  setCard('c-status', 'red');
  setCard('c-charge', '');
  setCard('c-load', '');
  setCard('c-usage', '');

  document.querySelector('#full-table tbody').innerHTML = '';
  document.getElementById('footer').textContent = '';
  document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
}

function updateUI(data){
  if (data.error) { setErrorState(data.error); return; }

  document.getElementById('error').style.display = 'none';

  const status = data['ups.status'] || '';
  let statusText = status, statusCls = '';
  if (status.includes('OL')) { statusText = 'On Line (AC power)'; statusCls = 'green'; }
  if (status.includes('OB')) { statusText = 'On Battery'; statusCls = 'yellow'; }
  if (status.includes('LB')) { statusText = 'Low Battery'; statusCls = 'red'; }

  document.getElementById('v-status').textContent = statusText;
  setCard('c-status', statusCls);

  const charge = parseInt(data['battery.charge']);
  let cc = '';
  if (!isNaN(charge)) { if (charge >= 80) cc = 'green'; else if (charge >= 50) cc = 'yellow'; else cc = 'red'; }
  document.getElementById('v-charge').textContent = isNaN(charge) ? '-' : charge + ' %';
  setCard('c-charge', cc);

  document.getElementById('v-runtime').textContent = fmtRuntime(data['battery.runtime']);

  const loadPct = parseFloat(data['ups.load']);
  document.getElementById('v-load').textContent = isNaN(loadPct) ? '-' : loadPct + ' %';
  setCard('c-load', loadPct > 80 ? 'red' : (loadPct > 50 ? 'yellow' : 'green'));

  // --- Estimated usage in Watts ---
  const nominalW = parseFloat(data['ups.realpower.nominal']);
  if (!isNaN(loadPct) && !isNaN(nominalW) && nominalW > 0) {
    const usageW = Math.round((loadPct / 100) * nominalW);
    document.getElementById('v-usage').innerHTML =
      usageW + ' W <span class="hint">of ' + Math.round(nominalW) + ' W</span>';
    const usagePct = (usageW / nominalW) * 100;
    setCard('c-usage', usagePct > 80 ? 'red' : (usagePct > 50 ? 'yellow' : 'green'));
  } else {
    document.getElementById('v-usage').textContent = '-';
    setCard('c-usage', '');
  }

  document.getElementById('v-input').textContent  = (data['input.voltage']  || '-') + ' V';
  document.getElementById('v-output').textContent = (data['output.voltage'] || '-') + ' V';

  const mfr = data['device.mfr'] || '';
  const model = data['device.model'] || '-';
  document.getElementById('v-model').textContent = (mfr + ' ' + model).trim();

  document.getElementById('v-power').textContent =
    (!isNaN(nominalW) && nominalW > 0) ? Math.round(nominalW) + ' W' : '-';

  const tbody = document.querySelector('#full-table tbody');
  tbody.innerHTML = '';
  const keys = Object.keys(data).sort();
  for (const k of keys) {
    const tr = document.createElement('tr');
    const td1 = document.createElement('td'); td1.textContent = k;
    const td2 = document.createElement('td'); td2.textContent = data[k];
    tr.appendChild(td1); tr.appendChild(td2);
    tbody.appendChild(tr);
  }

  updateFaviconAndTitle(status, charge, statusText);
  document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
  document.getElementById('footer').textContent = 'Parameters: ' + keys.length;
}

function fetchStatus(){
  fetch('/api/status')
    .then(r => r.json())
    .then(d => updateUI(d))
    .catch(e => setErrorState('Connection error: ' + e));
}

fetchStatus();
setInterval(fetchStatus, REFRESH);
</script>
</body>
</html>
"@
}

function Send-HttpResponse {
    param([System.Net.HttpListenerContext]$Context, [int]$StatusCode, [string]$ContentType, [byte[]]$Body)
    try {
        $Context.Response.StatusCode = $StatusCode
        $Context.Response.ContentType = $ContentType
        $Context.Response.ContentLength64 = $Body.Length
        $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
    }
    catch {}
    finally {
        try { $Context.Response.OutputStream.Close() } catch {}
        try { $Context.Response.Close() } catch {}
    }
}

function Handle-Request {
    param([System.Net.HttpListenerContext]$Context)

    $path = $Context.Request.Url.AbsolutePath

    if ($path -match "^/(sphere-(green|orange|red|magenta)|error)\.png$") {
        $imgPath = Join-Path $ScriptDir $path.TrimStart('/')
        if (Test-Path $imgPath) {
            $bytes = [System.IO.File]::ReadAllBytes($imgPath)
            Send-HttpResponse -Context $Context -StatusCode 200 -ContentType "image/png" -Body $bytes
        }
        else {
            Send-HttpResponse -Context $Context -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes("Not found"))
        }
        return
    }

    if ($path -eq "/api/status") {
        $vars = Get-UPSVars
        $json = $vars | ConvertTo-Json -Compress -Depth 3
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Send-HttpResponse -Context $Context -StatusCode 200 -ContentType "application/json; charset=utf-8" -Body $bytes
        return
    }

    if ($path -eq "/" -or $path -eq "/index.html") {
        $html = Get-HtmlPage -RefreshSec $WebRefresh
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
        Send-HttpResponse -Context $Context -StatusCode 200 -ContentType "text/html; charset=utf-8" -Body $bytes
        return
    }

    Send-HttpResponse -Context $Context -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes("Not found"))
}

# ================================================================
# 9. MODES
# ================================================================
function Show-UPSStatus {
    param([hashtable]$Vars)
    if ($Vars.ContainsKey("error")) { Write-Host "Connection error: $($Vars['error'])" -ForegroundColor Red; return }
    $model = if ($Vars.ContainsKey("device.model")) { $Vars["device.model"] } else { "?" }
    $mfr = if ($Vars.ContainsKey("device.mfr")) { $Vars["device.mfr"] }   else { "" }
    $status = if ($Vars.ContainsKey("ups.status")) { $Vars["ups.status"] }  else { "" }
    $charge = if ($Vars.ContainsKey("battery.charge")) { $Vars["battery.charge"] }  else { "?" }
    $runtime = if ($Vars.ContainsKey("battery.runtime")) { $Vars["battery.runtime"] } else { $null }
    $bVolt = if ($Vars.ContainsKey("battery.voltage")) { $Vars["battery.voltage"] } else { $null }
    $bVoltN = if ($Vars.ContainsKey("battery.voltage.nominal")) { $Vars["battery.voltage.nominal"] } else { $null }
    $inV = if ($Vars.ContainsKey("input.voltage")) { $Vars["input.voltage"] }  else { $null }
    $inF = if ($Vars.ContainsKey("input.frequency")) { $Vars["input.frequency"] } else { $null }
    $outV = if ($Vars.ContainsKey("output.voltage")) { $Vars["output.voltage"] } else { $null }
    $load = if ($Vars.ContainsKey("ups.load")) { $Vars["ups.load"] }       else { $null }
    $pNom = if ($Vars.ContainsKey("ups.realpower.nominal")) { $Vars["ups.realpower.nominal"] } else { $null }
    $statusText = switch -Regex ($status) {
        "OL LB" { "AC present, battery low" }
        "OB LB" { "On battery, low battery" }
        "OB" { "On battery" }
        "OL" { "On line (AC power)" }
        default { $status }
    }
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "                 UPS STATUS                       " -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ("Date: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
    Write-Host ""
    Write-Host "Model:  " -NoNewline -ForegroundColor Magenta; Write-Host "$mfr $model" -ForegroundColor White
    Write-Host "Status: " -NoNewline -ForegroundColor Magenta
    if ($status -match "OB") { Write-Host "$statusText" -ForegroundColor Yellow } else { Write-Host "$statusText" -ForegroundColor Green }
    Write-Host ""
    Write-Host "BATTERY:" -ForegroundColor Cyan
    if ($charge) {
        $ci = 0; [int]::TryParse($charge, [ref]$ci) | Out-Null
        $col = if ($ci -ge 80) { "Green" } elseif ($ci -ge 50) { "Yellow" } else { "Red" }
        Write-Host ("   Charge:     {0} %" -f $charge) -ForegroundColor $col
    }
    if ($runtime) {
        $rm = [math]::Round([int]$runtime / 60, 1)
        Write-Host ("   Runtime:    {0} min ({1} s)" -f $rm, $runtime) -ForegroundColor Yellow
    }
    if ($bVolt) {
        $line = "   Voltage:    $bVolt V"
        if ($bVoltN) { $line += " (nominal $bVoltN V)" }
        Write-Host $line -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "POWER:" -ForegroundColor Cyan
    if ($inV) {
        Write-Host "   Input:      $inV V" -ForegroundColor Gray
        if ($inF) { Write-Host "   Frequency:  $inF Hz" -ForegroundColor Gray }
    }
    if ($outV) { Write-Host "   Output:     $outV V" -ForegroundColor Gray }
    if ($load) {
        $li = 0; [int]::TryParse($load, [ref]$li) | Out-Null
        $col = if ($li -le 50) { "Green" } elseif ($li -le 80) { "Yellow" } else { "Red" }
        Write-Host "   Load:       $load %" -ForegroundColor $col
        if ($pNom -and $pNom -ne "0") {
            $w = [math]::Round(([double]$load / 100.0) * [double]$pNom)
            Write-Host "   Estimated:  $w W (nominal $pNom W)" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
}

function Start-Monitor {
    Ensure-LogDir
    Write-Host "=== UPS Monitor started ===" -ForegroundColor Cyan
    Write-Host "NUT: ${NUT_HOST}:${NUT_PORT}  /  UPS: $UPS_NAME" -ForegroundColor Gray
    Write-Host "Logs: $LOG_DIR" -ForegroundColor Gray
    Write-Host "Shutdown mode: $SHUTDOWN_MODE (dialog timeout: ${DIALOG_TIMEOUT}s, postpone: ${POSTPONE_MIN} min)" -ForegroundColor Gray
    Write-Host "Ctrl+C to stop." -ForegroundColor Gray
    Write-Host ""
    try {
        while ($true) {
            $vars = Get-UPSVars
            if ($vars.ContainsKey("error")) {
                Write-Host ("[{0}] Error: {1}" -f (Get-Date -Format 'HH:mm:ss'), $vars["error"]) -ForegroundColor Red
                Start-Sleep -Seconds 10
                continue
            }
            Invoke-LoggerIteration -Vars $vars
            Start-Sleep -Seconds $POLL_INTERVAL
        }
    }
    finally {
        if ($script:EventFile) {
            Write-LogLine -Path $script:EventFile -Line ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === MONITORING STOPPED ===")
        }
        Write-Host "`nMonitoring stopped." -ForegroundColor Cyan
    }
}

function Start-WebMonitor {
    Ensure-LogDir
    $prefix = "http://${WebHost}:${WebPort}/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try { $listener.Start() }
    catch {
        Write-Host ""
        Write-Host "Failed to start web server on $prefix" -ForegroundColor Red
        Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Try as admin once:" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=http://+:${WebPort}/ sddl=D:(A;;GX;;;S-1-1-0)" -ForegroundColor Yellow
        return
    }
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  UPS Monitor + Web UI started" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "NUT:      ${NUT_HOST}:${NUT_PORT}  /  UPS: $UPS_NAME" -ForegroundColor Gray
    Write-Host "Web UI:   $prefix" -ForegroundColor Green
    Write-Host "Logs:     $LOG_DIR" -ForegroundColor Gray
    Write-Host "Shutdown: mode $SHUTDOWN_MODE (dialog ${DIALOG_TIMEOUT}s, postpone ${POSTPONE_MIN} min)" -ForegroundColor Gray
    Write-Host "Ctrl+C to stop." -ForegroundColor Gray
    Write-Host ""

    $async = $listener.BeginGetContext($null, $null)
    $lastPoll = 0

    try {
        while ($true) {
            if ($async.AsyncWaitHandle.WaitOne(500)) {
                $context = $listener.EndGetContext($async)
                Handle-Request -Context $context
                $async = $listener.BeginGetContext($null, $null)
            }
            $now = Get-UnixTime
            if ($now - $lastPoll -ge $POLL_INTERVAL) {
                $vars = Get-UPSVars
                if ($vars.ContainsKey("error")) {
                    Write-Host ("[{0}] NUT: {1}" -f (Get-Date -Format 'HH:mm:ss'), $vars["error"]) -ForegroundColor Red
                }
                else {
                    Invoke-LoggerIteration -Vars $vars
                }
                $lastPoll = $now
            }
        }
    }
    finally {
        if ($script:EventFile) {
            Write-LogLine -Path $script:EventFile -Line ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === MONITORING STOPPED ===")
        }
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
        Write-Host "`nWeb monitor stopped." -ForegroundColor Cyan
    }
}

# ================================================================
# 10. ENTRY POINT
# ================================================================
switch ($Mode) {
    "show" { Show-UPSStatus -Vars (Get-UPSVars) }
    "monitor" { Start-Monitor }
    "web" { Start-WebMonitor }
}