#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet("show","monitor","web")]
    [string]$Mode = "web",

    [string]$NUT_HOST = "192.168.0.15",
    [int]$NUT_PORT    = 3493,
    [string]$UPS_NAME = "ups",
    [int]$NUT_TIMEOUT = 5,

    [int]$WebPort     = 9921,
    [string]$WebHost  = "localhost",
    [int]$WebRefresh  = 5
)

# ---------- Constants ----------
$ScriptDir           = Split-Path -Parent $MyInvocation.MyCommand.Path
$LOG_DIR             = Join-Path $ScriptDir "logs"
$ONLINE_LOG_INTERVAL = 3600
$EVENT_LOG_INTERVAL  = 5
$MAX_FILE_SIZE       = 50MB
$MAX_TOTAL_SIZE      = 500MB
$POLL_INTERVAL       = 1

$ONLINE_FILE_NAME  = "ups_online.txt"
$EVENT_FILE_PREFIX = "ups_power_event"

$UPS_VARS = @(
    "battery.charge","battery.charge.low","battery.charge.warning",
    "battery.current","battery.date","battery.mfr.date",
    "battery.runtime","battery.runtime.low","battery.status",
    "battery.temperature","battery.type","battery.voltage","battery.voltage.nominal",
    "device.mfr","device.model","device.serial","device.type",
    "driver.debug","driver.flag.allow_killpower","driver.name","driver.state",
    "driver.version","driver.version.data","driver.version.internal","driver.version.usb",
    "driver.parameter.pollfreq","driver.parameter.pollinterval",
    "driver.parameter.port","driver.parameter.synchronous",
    "driver.parameter.interrupt_pipe_no_events_tolerance",
    "input.current","input.frequency","input.frequency.nominal",
    "input.transfer.high","input.transfer.low",
    "input.voltage","input.voltage.nominal",
    "output.current","output.frequency","output.frequency.nominal","output.voltage",
    "ups.beeper.status","ups.delay.shutdown","ups.delay.start",
    "ups.firmware","ups.load","ups.mfr","ups.model",
    "ups.power.nominal","ups.realpower.nominal","ups.serial",
    "ups.status","ups.test.result","ups.timer.shutdown","ups.timer.start",
    "ups.vendorid","ups.productid","ups.temperature","ups.type"
)

# ---------- Logger state ----------
$script:LastOnlineLog  = 0
$script:EventFile      = $null
$script:LastEventWrite = 0

# ---------- Utilities ----------
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
    } else {
        [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $enc)
    }
}

function Format-LogLine {
    param([hashtable]$Vars)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $statusRaw = if ($Vars.ContainsKey("ups.status")) { $Vars["ups.status"] } else { "" }
    if ($statusRaw -match "OL")      { $statusText = "OnLine" }
    elseif ($statusRaw -match "OB")  { $statusText = "OnBattery" }
    else                             { $statusText = $statusRaw }

    $charge  = if ($Vars.ContainsKey("battery.charge"))  { $Vars["battery.charge"] }  else { "?" }
    $runtime = if ($Vars.ContainsKey("battery.runtime")) { $Vars["battery.runtime"] } else { "?" }
    $load    = if ($Vars.ContainsKey("ups.load"))        { $Vars["ups.load"] }        else { "?" }
    $inV     = if ($Vars.ContainsKey("input.voltage"))   { $Vars["input.voltage"] }   else { "?" }
    $outV    = if ($Vars.ContainsKey("output.voltage"))  { $Vars["output.voltage"] }  else { "?" }

    return "[$ts] Status`t$statusText`tCharge`t$charge %`tRuntime`t$runtime s`tLoad`t$load %`tInput`t$inV V`tOutput`t$outV V"
}

function Rotate-FileIfNeeded {
    param([string]$Path)
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -ge $MAX_FILE_SIZE)) {
        $dir  = Split-Path -Parent $Path
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $ext  = [System.IO.Path]::GetExtension($Path)
        $ts   = Get-Date -Format "yyyyMMdd_HHmmss"
        $new  = Join-Path $dir "${base}_${ts}${ext}"
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
    $rotated  = Rotate-FileIfNeeded -Path $filename
    if ($null -eq $rotated) {
        $filename = Join-Path $LOG_DIR $ONLINE_FILE_NAME
    }
    Write-LogLine -Path $filename -Line (Format-LogLine -Vars $Vars)
}

function Write-EventLog {
    param([hashtable]$Vars)
    if (-not $script:EventFile) { return }
    $rotated = Rotate-FileIfNeeded -Path $script:EventFile
    if ($null -eq $rotated) {
        Continue-EventLogging -Vars $Vars
    } else {
        Write-LogLine -Path $script:EventFile -Line (Format-LogLine -Vars $Vars)
    }
}

# ---------- NUT client ----------
function Get-UPSVars {
    $result = @{}
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($NUT_HOST, $NUT_PORT, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($NUT_TIMEOUT * 1000, $false)) {
            throw "Timeout connecting to ${NUT_HOST}:${NUT_PORT}"
        }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $NUT_TIMEOUT * 1000
        $client.SendTimeout    = $NUT_TIMEOUT * 1000

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
    } catch {
        return @{ "error" = $_.Exception.Message }
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
    return $result
}

# ---------- Logger iteration ----------
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
}

# ---------- HTML page ----------
function Get-HtmlPage {
    param([int]$RefreshSec)
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>UPS Status</title>
<style>
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #1e1e2e; color: #eee; margin: 0; padding: 20px; }
  h1 { color: #89dceb; margin: 0 0 4px 0; }
  .sub { color: #888; font-size: 12px; margin-bottom: 20px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; max-width: 1100px; }
  .card { background: #2a2a3e; border-radius: 8px; padding: 14px 18px; border-left: 4px solid #89dceb; }
  .card.green { border-color: #a6e3a1; }
  .card.yellow { border-color: #f9e2af; }
  .card.red { border-color: #f38ba8; }
  .label { color: #888; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
  .value { font-size: 22px; font-weight: 600; margin-top: 4px; }
  .value.small { font-size: 16px; }
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
    <div class="card" id="c-status">
      <div class="label">Status</div>
      <div class="value" id="v-status">-</div>
    </div>
    <div class="card" id="c-charge">
      <div class="label">Battery charge</div>
      <div class="value" id="v-charge">-</div>
    </div>
    <div class="card" id="c-runtime">
      <div class="label">Runtime left</div>
      <div class="value" id="v-runtime">-</div>
    </div>
    <div class="card" id="c-load">
      <div class="label">Load</div>
      <div class="value" id="v-load">-</div>
    </div>
    <div class="card">
      <div class="label">Input voltage</div>
      <div class="value small" id="v-input">-</div>
    </div>
    <div class="card">
      <div class="label">Output voltage</div>
      <div class="value small" id="v-output">-</div>
    </div>
    <div class="card">
      <div class="label">Model</div>
      <div class="value small" id="v-model">-</div>
    </div>
    <div class="card">
      <div class="label">Nominal power</div>
      <div class="value small" id="v-power">-</div>
    </div>
  </div>

  <details>
    <summary>All UPS parameters</summary>
    <table id="full-table">
      <thead><tr><th>Parameter</th><th>Value</th></tr></thead>
      <tbody></tbody>
    </table>
  </details>

  <div class="footer" id="footer">-</div>

<script>
const REFRESH = $RefreshSec * 1000;

function fmtRuntime(sec) {
  sec = parseInt(sec);
  if (isNaN(sec)) return '-';
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return m + ' min ' + s + ' s';
}

function setCard(id, cls) {
  const el = document.getElementById(id);
  el.className = 'card' + (cls ? ' ' + cls : '');
}

function updateUI(data) {
  const errEl = document.getElementById('error');
  if (data.error) {
    errEl.style.display = 'block';
    errEl.textContent = 'Error: ' + data.error;
    return;
  }
  errEl.style.display = 'none';

  const status = data['ups.status'] || '';
  let statusText = status;
  let statusCls = '';
  if (status.includes('OL')) { statusText = 'On Line (AC power)'; statusCls = 'green'; }
  if (status.includes('OB')) { statusText = 'On Battery'; statusCls = 'yellow'; }
  if (status.includes('LB')) { statusText = 'Low Battery'; statusCls = 'red'; }

  document.getElementById('v-status').textContent = statusText;
  setCard('c-status', statusCls);

  const charge = parseInt(data['battery.charge']);
  let chargeCls = '';
  if (!isNaN(charge)) {
    if (charge >= 80) chargeCls = 'green';
    else if (charge >= 50) chargeCls = 'yellow';
    else chargeCls = 'red';
  }
  document.getElementById('v-charge').textContent = isNaN(charge) ? '-' : charge + ' %';
  setCard('c-charge', chargeCls);

  document.getElementById('v-runtime').textContent = fmtRuntime(data['battery.runtime']);
  document.getElementById('v-load').textContent = (data['ups.load'] || '-') + ' %';
  setCard('c-load', parseInt(data['ups.load']) > 80 ? 'red' : '');

  document.getElementById('v-input').textContent  = (data['input.voltage']  || '-') + ' V';
  document.getElementById('v-output').textContent = (data['output.voltage'] || '-') + ' V';

  const mfr = data['device.mfr'] || '';
  const model = data['device.model'] || '-';
  document.getElementById('v-model').textContent = (mfr + ' ' + model).trim();

  const pnom = data['ups.realpower.nominal'];
  document.getElementById('v-power').textContent = (pnom && pnom !== '0') ? pnom + ' W' : '-';

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

  document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
  document.getElementById('footer').textContent = 'Parameters: ' + keys.length;
}

function fetchStatus() {
  fetch('/api/status')
    .then(r => r.json())
    .then(d => updateUI(d))
    .catch(e => {
      const errEl = document.getElementById('error');
      errEl.style.display = 'block';
      errEl.textContent = 'Connection error: ' + e;
    });
}

fetchStatus();
setInterval(fetchStatus, REFRESH);
</script>
</body>
</html>
"@
}

# ---------- HTTP response helper ----------
function Send-HttpResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body
    )
    try {
        $Context.Response.StatusCode = $StatusCode
        $Context.Response.ContentType = $ContentType
        $Context.Response.ContentLength64 = $Body.Length
        $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
    } catch {
        # client disconnected
    } finally {
        try { $Context.Response.OutputStream.Close() } catch {}
        try { $Context.Response.Close() } catch {}
    }
}

function Handle-Request {
    param([System.Net.HttpListenerContext]$Context)

    $path = $Context.Request.Url.AbsolutePath

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

    $body = [System.Text.Encoding]::UTF8.GetBytes("Not found")
    Send-HttpResponse -Context $Context -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Body $body
}

# ---------- SHOW mode ----------
function Show-UPSStatus {
    param([hashtable]$Vars)
    if ($Vars.ContainsKey("error")) {
        Write-Host "Connection error: $($Vars['error'])" -ForegroundColor Red
        return
    }
    $model  = if ($Vars.ContainsKey("device.model")) { $Vars["device.model"] } else { "?" }
    $mfr    = if ($Vars.ContainsKey("device.mfr"))   { $Vars["device.mfr"] }   else { "" }
    $status = if ($Vars.ContainsKey("ups.status"))   { $Vars["ups.status"] }  else { "" }
    $charge = if ($Vars.ContainsKey("battery.charge"))  { $Vars["battery.charge"] }  else { "?" }
    $runtime= if ($Vars.ContainsKey("battery.runtime")) { $Vars["battery.runtime"] } else { $null }
    $bVolt  = if ($Vars.ContainsKey("battery.voltage")) { $Vars["battery.voltage"] } else { $null }
    $bVoltN = if ($Vars.ContainsKey("battery.voltage.nominal")) { $Vars["battery.voltage.nominal"] } else { $null }
    $inV    = if ($Vars.ContainsKey("input.voltage"))  { $Vars["input.voltage"] }  else { $null }
    $inF    = if ($Vars.ContainsKey("input.frequency")){ $Vars["input.frequency"] } else { $null }
    $outV   = if ($Vars.ContainsKey("output.voltage")) { $Vars["output.voltage"] } else { $null }
    $load   = if ($Vars.ContainsKey("ups.load"))       { $Vars["ups.load"] }       else { $null }
    $pNom   = if ($Vars.ContainsKey("ups.realpower.nominal")) { $Vars["ups.realpower.nominal"] } else { $null }
    $test   = if ($Vars.ContainsKey("ups.test.result")){ $Vars["ups.test.result"] } else { $null }

    $statusText = switch -Regex ($status) {
        "OL LB" { "AC present, battery low" }
        "OB LB" { "On battery, low battery" }
        "OB"    { "On battery" }
        "OL"    { "On line (AC power)" }
        default { $status }
    }

    Clear-Host
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "                 UPS STATUS                       " -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ("Date: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
    Write-Host ""
    Write-Host "Model:  " -NoNewline -ForegroundColor Magenta
    Write-Host "$mfr $model" -ForegroundColor White
    Write-Host "Status: " -NoNewline -ForegroundColor Magenta
    if ($status -match "OB") { Write-Host "$statusText" -ForegroundColor Yellow }
    else                     { Write-Host "$statusText" -ForegroundColor Green }
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
    }
    if ($pNom -and $pNom -ne "0") {
        Write-Host "   Nominal:    $pNom W" -ForegroundColor Gray
    }
    if ($test) {
        Write-Host ""
        Write-Host "BATTERY TEST:" -ForegroundColor Cyan
        Write-Host "   $test" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
}

# ---------- MONITOR mode ----------
function Start-Monitor {
    Ensure-LogDir
    Write-Host "=== UPS Monitor started ===" -ForegroundColor Cyan
    Write-Host "NUT:  ${NUT_HOST}:${NUT_PORT}  /  UPS: $UPS_NAME" -ForegroundColor Gray
    Write-Host "Logs: $LOG_DIR" -ForegroundColor Gray
    Write-Host "Press Ctrl+C to stop." -ForegroundColor Gray
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
    } finally {
        if ($script:EventFile) {
            Write-LogLine -Path $script:EventFile -Line ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === MONITORING STOPPED ===")
        }
        Write-Host "`nMonitoring stopped." -ForegroundColor Cyan
    }
}

# ---------- WEB mode ----------
function Start-WebMonitor {
    Ensure-LogDir

    $prefix = "http://${WebHost}:${WebPort}/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    } catch {
        Write-Host ""
        Write-Host "Failed to start web server on $prefix" -ForegroundColor Red
        Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "If you want to listen on all interfaces (WebHost = '+'), run as admin once:" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=http://+:${WebPort}/ user=$env:USERNAME" -ForegroundColor Yellow
        Write-Host "Or use WebHost = 'localhost' (default)." -ForegroundColor Yellow
        return
    }

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  UPS Monitor + Web UI started" -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "NUT:      ${NUT_HOST}:${NUT_PORT}  /  UPS: $UPS_NAME" -ForegroundColor Gray
    Write-Host "Web UI:   $prefix" -ForegroundColor Green
    Write-Host "Logs:     $LOG_DIR" -ForegroundColor Gray
    Write-Host "Page refresh: every $WebRefresh s." -ForegroundColor Gray
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
                } else {
                    Invoke-LoggerIteration -Vars $vars
                }
                $lastPoll = $now
            }
        }
    } finally {
        if ($script:EventFile) {
            Write-LogLine -Path $script:EventFile -Line ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === MONITORING STOPPED ===")
        }
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
        Write-Host "`nWeb monitor stopped." -ForegroundColor Cyan
    }
}

# ---------- Entry point ----------
switch ($Mode) {
    "show"    { Show-UPSStatus -Vars (Get-UPSVars) }
    "monitor" { Start-Monitor }
    "web"     { Start-WebMonitor }
}