#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet("show","monitor")]
    [string]$Mode = "monitor",

    [string]$NUT_HOST = "192.168.0.15",
    [int]$NUT_PORT    = 3493,
    [string]$UPS_NAME = "ups",
    [int]$NUT_TIMEOUT = 5
)

# ---------- Настройки ----------
$ScriptDir           = Split-Path -Parent $MyInvocation.MyCommand.Path
$LOG_DIR             = Join-Path $ScriptDir "logs"
$ONLINE_LOG_INTERVAL = 3600        # 1 час
$EVENT_LOG_INTERVAL  = 5           # 5 сек
$MAX_FILE_SIZE       = 50MB
$MAX_TOTAL_SIZE      = 500MB
$POLL_INTERVAL       = 1           # сек между опросами NUT

$ONLINE_FILE_NAME    = "ИБП_онлайн.txt"
$EVENT_FILE_PREFIX   = "ИБП_отключение-от-сети"

# Полный список переменных (используется для fallback GET VAR,
# если LIST VAR не работает по сети — у вас как раз такой случай)
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

# ---------- Состояние логгера ----------
$script:LastOnlineLog  = 0
$script:EventFile      = $null
$script:LastEventWrite = 0

# ---------- Утилиты логирования ----------
function Ensure-LogDir {
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -Path $LOG_DIR -ItemType Directory -Force | Out-Null
    }
}

function Get-UnixTime { [int](Get-Date -UFormat %s) }

function Write-LogLine {
    param(
        [string]$Path,
        [string]$Line,
        [switch]$NoAppend
    )
    $enc = New-Object System.Text.UTF8Encoding($false)  # без BOM
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
    if ($statusRaw -match "OL")      { $statusText = "Питание от сети" }
    elseif ($statusRaw -match "OB")  { $statusText = "Работа от батареи" }
    else                             { $statusText = $statusRaw }

    $charge  = if ($Vars.ContainsKey("battery.charge"))  { $Vars["battery.charge"] }  else { "?" }
    $runtime = if ($Vars.ContainsKey("battery.runtime")) { $Vars["battery.runtime"] } else { "?" }
    $load    = if ($Vars.ContainsKey("ups.load"))        { $Vars["ups.load"] }        else { "?" }
    $inV     = if ($Vars.ContainsKey("input.voltage"))   { $Vars["input.voltage"] }   else { "?" }
    $outV    = if ($Vars.ContainsKey("output.voltage"))  { $Vars["output.voltage"] }  else { "?" }

    return "[$ts] Статус`t$statusText`tЗаряд`t$charge %`tОсталось`t$runtime сек`tНагрузка`t$load %`tВход`t$inV В`tВыход`t$outV В"
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
    $ts = Get-Date -Format "dd.MM.yyyy_HH-mm-ss"
    $filename = Join-Path $LOG_DIR "${EVENT_FILE_PREFIX}_${ts}.txt"
    $header = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === НАЧАЛО СОБЫТИЯ (отключение питания) ==="
    Write-LogLine -Path $filename -Line $header -NoAppend
    Write-LogLine -Path $filename -Line (Format-LogLine -Vars $Vars)
    $script:EventFile = $filename
    $script:LastEventWrite = (Get-UnixTime) - $EVENT_LOG_INTERVAL
}

function Continue-EventLogging {
    param([hashtable]$Vars)
    $ts = Get-Date -Format "dd.MM.yyyy_HH-mm-ss"
    $newFile = Join-Path $LOG_DIR "${EVENT_FILE_PREFIX}_${ts}.txt"
    $header = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === ПРОДОЛЖЕНИЕ СОБЫТИЯ (ротация файла) ==="
    Write-LogLine -Path $newFile -Line $header -NoAppend
    Write-LogLine -Path $newFile -Line (Format-LogLine -Vars $Vars)
    $script:EventFile = $newFile
}

function Stop-EventLogging {
    param([int]$ChargeInt)
    if ($script:EventFile) {
        $endHeader = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === КОНЕЦ СОБЫТИЯ (питание восстановлено, заряд ${ChargeInt}%) ==="
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

# ---------- Клиент NUT ----------
function Get-UPSVars {
    $result = @{}
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($NUT_HOST, $NUT_PORT, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($NUT_TIMEOUT * 1000, $false)) {
            throw "Таймаут подключения к ${NUT_HOST}:${NUT_PORT}"
        }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $NUT_TIMEOUT * 1000
        $client.SendTimeout    = $NUT_TIMEOUT * 1000

        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true

        # 1) Пробуем LIST VAR
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

        # 2) Если LIST VAR пуст — используем GET VAR по списку
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

# ---------- Разовый вывод (режим show) ----------
function Show-UPSStatus {
    param([hashtable]$Vars)
    if ($Vars.ContainsKey("error")) {
        Write-Host "Ошибка подключения: $($Vars['error'])" -ForegroundColor Red
        return
    }

    $model = if ($Vars.ContainsKey("device.model")) { $Vars["device.model"] } else { "?" }
    $mfr   = if ($Vars.ContainsKey("device.mfr"))   { $Vars["device.mfr"] }   else { "" }
    $status = if ($Vars.ContainsKey("ups.status"))  { $Vars["ups.status"] }  else { "" }
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
        "OL LB" { "Сеть есть, но батарея разряжена" }
        "OB LB" { "Батареи разряжаются (Low Battery)" }
        "OB"    { "Работа от батарей (On Battery)" }
        "OL"    { "Работа от сети (On Line)" }
        default { $status }
    }

    Clear-Host
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "          Статус ИБП (NUT)                       " -ForegroundColor Yellow
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ("Дата и время: {0}" -f (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) -ForegroundColor Gray
    Write-Host ""

    Write-Host "Модель: " -NoNewline -ForegroundColor Magenta
    Write-Host "$mfr $model" -ForegroundColor White

    Write-Host "Статус: " -NoNewline -ForegroundColor Magenta
    if ($status -match "OB") { Write-Host "$statusText" -ForegroundColor Yellow }
    else                     { Write-Host "$statusText" -ForegroundColor Green }

    Write-Host ""
    Write-Host "БАТАРЕЯ:" -ForegroundColor Cyan
    if ($charge) {
        $ci = 0; [int]::TryParse($charge, [ref]$ci) | Out-Null
        $col = if ($ci -ge 80) { "Green" } elseif ($ci -ge 50) { "Yellow" } else { "Red" }
        Write-Host ("   Заряд: {0} %" -f $charge) -ForegroundColor $col
    }
    if ($runtime) {
        $rm = [math]::Round([int]$runtime / 60, 1)
        Write-Host ("   Осталось: {0} мин ({1} сек)" -f $rm, $runtime) -ForegroundColor Yellow
    }
    if ($bVolt) {
        $line = "   Напряжение: $bVolt В"
        if ($bVoltN) { $line += " (номинал $bVoltN В)" }
        Write-Host $line -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "ПИТАНИЕ:" -ForegroundColor Cyan
    if ($inV) {
        Write-Host "   Входное:  $inV В" -ForegroundColor Gray
        if ($inF) { Write-Host "   Частота:  $inF Гц" -ForegroundColor Gray }
    }
    if ($outV) { Write-Host "   Выходное: $outV В" -ForegroundColor Gray }
    if ($load) {
        $li = 0; [int]::TryParse($load, [ref]$li) | Out-Null
        $col = if ($li -le 50) { "Green" } elseif ($li -le 80) { "Yellow" } else { "Red" }
        Write-Host "   Нагрузка: $load %" -ForegroundColor $col
    }
    if ($pNom -and $pNom -ne "0") {
        Write-Host "   Номинал:  $pNom Вт" -ForegroundColor Gray
    }
    if ($test) {
        Write-Host ""
        Write-Host "ТЕСТ БАТАРЕИ:" -ForegroundColor Cyan
        Write-Host "   $test" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
}

# ---------- Постоянный мониторинг (режим monitor) ----------
function Start-Monitor {
    Ensure-LogDir
    Write-Host "=== UPS Monitor запущен ===" -ForegroundColor Cyan
    Write-Host "NUT: ${NUT_HOST}:${NUT_PORT}  /  UPS: $UPS_NAME" -ForegroundColor Gray
    Write-Host "Логи: $LOG_DIR" -ForegroundColor Gray
    Write-Host "Нажмите Ctrl+C для остановки." -ForegroundColor Gray
    Write-Host ""

    $script:LastOnlineLog = 0

    try {
        while ($true) {
            $vars = Get-UPSVars
            if ($vars.ContainsKey("error")) {
                Write-Host ("[{0}] Ошибка: {1}" -f (Get-Date -Format 'HH:mm:ss'), $vars["error"]) -ForegroundColor Red
                Start-Sleep -Seconds 10
                continue
            }

            $currentStatus = if ($vars.ContainsKey("ups.status")) { $vars["ups.status"] } else { "" }
            $chargeInt = 0
            if ($vars.ContainsKey("battery.charge")) {
                [int]::TryParse($vars["battery.charge"], [ref]$chargeInt) | Out-Null
            }

            # Онлайн-лог раз в час
            $now = Get-UnixTime
            if ($now - $script:LastOnlineLog -ge $ONLINE_LOG_INTERVAL) {
                Write-OnlineLog -Vars $vars
                Write-Host ("[{0}] Записан онлайн-лог." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor DarkGray
                $script:LastOnlineLog = $now
            }

            # Определяем активность события
            $eventActive = ($currentStatus -notmatch "OL") -or ($chargeInt -lt 100)

            if ($eventActive -and -not $script:EventFile) {
                Start-EventLogging -Vars $vars
                Write-Host ("[{0}] НАЧАЛО СОБЫТИЯ (сеть пропала или заряд < 100%)" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Yellow
            }
            elseif (-not $eventActive -and $script:EventFile) {
                Stop-EventLogging -ChargeInt $chargeInt
                Write-Host ("[{0}] КОНЕЦ СОБЫТИЯ (питание восстановлено, заряд {1}%)" -f (Get-Date -Format 'HH:mm:ss'), $chargeInt) -ForegroundColor Green
            }

            if ($eventActive -and $script:EventFile) {
                $now2 = Get-UnixTime
                if ($now2 - $script:LastEventWrite -ge $EVENT_LOG_INTERVAL) {
                    Write-EventLog -Vars $vars
                    $script:LastEventWrite = $now2
                }
            }

            Start-Sleep -Seconds $POLL_INTERVAL
        }
    } finally {
        if ($script:EventFile) {
            $endHeader = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] === МОНИТОРИНГ ОСТАНОВЛЕН ==="
            Write-LogLine -Path $script:EventFile -Line $endHeader
        }
        Write-Host ""
        Write-Host "Мониторинг остановлен." -ForegroundColor Cyan
    }
}

# ---------- Точка входа ----------
switch ($Mode) {
    "show"    { Show-UPSStatus -Vars (Get-UPSVars) }
    "monitor" { Start-Monitor }
    default   { Show-UPSStatus -Vars (Get-UPSVars) }
}