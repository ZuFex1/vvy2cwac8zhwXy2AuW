@echo off
chcp 65001 >nul
setlocal EnableExtensions
title 永久开启移动热点 - AutoHotspot

rem =====================================================================
rem  改热点名字 / 密码，只改下面两行。
rem  密码 8-63 位，别用空格、引号、& | ^ 这类特殊符号。
rem =====================================================================
set "SSID=487"
set "PASS=487@zdtssl"

rem ------------------------- 自动申请管理员权限 -------------------------
fltmc >nul 2>&1
if errorlevel 1 (
    echo 需要管理员权限，正在重新启动...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    exit /b
)

set "DIR=%ProgramData%\AutoHotspot"
set "PS1=%DIR%\hotspot.ps1"
if not exist "%DIR%" md "%DIR%" >nul 2>&1

echo.
echo [1/3] 部署组件 -^> %DIR%
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=Get-Content -LiteralPath '%~f0'; $i=[array]::IndexOf($l,'::PS1_BEGIN'); if($i -lt 0){exit 1}; $l[($i+1)..($l.Count-1)] | Set-Content -LiteralPath '%PS1%' -Encoding UTF8"
if errorlevel 1 (
    echo       失败：无法写出 hotspot.ps1
    echo.
    pause
    exit /b 1
)

echo [2/3] 立即开启热点并写入配置
echo [3/3] 注册开机自启计划任务
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Install -Ssid "%SSID%" -Pass "%PASS%"

echo.
echo ================================================================
echo   热点名称 : %SSID%
echo   热点密码 : %PASS%
echo ----------------------------------------------------------------
echo   已注册计划任务 AutoHotspot：
echo     - 每次登录 Windows 后约 30 秒自动开热点
echo     - 每 5 分钟自检一次，被关掉/掉线会自动重开
echo   日志文件 : %DIR%\hotspot.log
echo ================================================================
echo.
pause
exit /b

::PS1_BEGIN
<#
  AutoHotspot runtime
  Deployed by the .bat to %ProgramData%\AutoHotspot\hotspot.ps1
  ASCII only on purpose: safe for PowerShell 5.1 + batch extraction.

  Usage:
    -Install -Ssid NAME -Pass PASSWORD   enable now + register auto-start task
    -Uninstall                           remove task + folder
    -Status                              print current hotspot state
    (no arguments)                       ensure hotspot is on (used by the task)
#>
[CmdletBinding()]
param(
    [string]$Ssid = '',
    [string]$Pass = '',
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [int]$Tries = 12,
    [int]$DelaySec = 5
)

$ErrorActionPreference = 'Stop'
$TaskName  = 'AutoHotspot'
$Dir       = Join-Path $env:ProgramData 'AutoHotspot'
$Log       = Join-Path $Dir 'hotspot.log'
$SelfPath  = Join-Path $Dir 'hotspot.ps1'

function Write-Log {
    param([string]$Message)
    $line = '{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $Log) -and ((Get-Item -LiteralPath $Log).Length -gt 1048576)) {
            Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Initialize-WinRT {
    if ($script:WinRTReady) { return }
    [void][Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    if ($null -eq $script:AsTaskGeneric) { throw 'cannot resolve AsTask overload' }
    $script:WinRTReady = $true
}

function Await {
    param($Operation, [Type]$ResultType)
    $asTask = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($Operation))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

function Get-TetheringManager {
    Initialize-WinRT
    $profile = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]::GetInternetConnectionProfile()
    if ($null -eq $profile) { return $null }
    try {
        return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::CreateFromConnectionProfile($profile)
    } catch {
        # WLAN AutoConfig may be stopped - start it and retry once
        try {
            $svc = Get-Service -Name 'WlanSvc' -ErrorAction Stop
            if ($svc.Status -ne 'Running') {
                Set-Service -Name 'WlanSvc' -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service -Name 'WlanSvc' -ErrorAction Stop
                Start-Sleep -Seconds 3
            }
        } catch { }
        return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]::CreateFromConnectionProfile($profile)
    }
}

function Enable-Hotspot {
    param([string]$NewSsid, [string]$NewPass)

    $mgr = Get-TetheringManager
    if ($null -eq $mgr) { return 'NO-UPLINK' }
    if ([int]$mgr.TetheringOperationalState -eq 1) { return 'ALREADY-ON' }

    if ($NewSsid) {
        try {
            $ap = $mgr.GetCurrentAccessPointConfiguration()
            $ap.Ssid = $NewSsid
            $ap.Passphrase = $NewPass
            $null = Await ($mgr.ConfigureAccessPointAsync($ap)) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        } catch {
            Write-Log ('  configure warning: ' + $_.Exception.Message)
        }
    }

    $result = Await ($mgr.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    return ('START:' + $result.Status)
}

function Start-HotspotWithRetry {
    param([string]$NewSsid, [string]$NewPass, [int]$MaxTries = 12, [int]$WaitSec = 5)
    $last = 'UNKNOWN'
    for ($i = 1; $i -le $MaxTries; $i++) {
        try {
            $last = Enable-Hotspot -NewSsid $NewSsid -NewPass $NewPass
        } catch {
            $last = 'ERROR:' + $_.Exception.Message
        }
        if ($last -eq 'ALREADY-ON' -or $last -like 'START:Success*') {
            Write-Log ("  attempt {0}: {1}" -f $i, $last)
            return $last
        }
        Write-Log ("  attempt {0}/{1}: {2}" -f $i, $MaxTries, $last)
        if ($i -lt $MaxTries) { Start-Sleep -Seconds $WaitSec }
    }
    return $last
}

function Install-AutoStart {
    param([string]$NewSsid, [string]$NewPass)

    try {
        $wifi = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN' -and
            $_.InterfaceDescription -notmatch 'VMware|VirtualBox|Hyper-V|Loopback|TAP'
        }
        if (-not $wifi) { Write-Log '  WARNING: no wireless adapter found - Mobile Hotspot needs a Wi-Fi card' }
    } catch { }

    foreach ($name in @('SharedAccess', 'WlanSvc')) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            if ($svc.StartType -ne 'Automatic') { Set-Service -Name $name -StartupType Automatic -ErrorAction Stop }
            if ($svc.Status -ne 'Running') { Start-Service -Name $name -ErrorAction SilentlyContinue }
            Write-Log ("  service {0}: ready" -f $name)
        } catch {
            Write-Log ("  service {0}: {1}" -f $name, $_.Exception.Message)
        }
    }

    $argument = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $SelfPath
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

    $trigger = New-ScheduledTaskTrigger -AtLogOn
    try { $trigger.Delay = 'PT30S' } catch { }

    try {
        $repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                -RepetitionInterval (New-TimeSpan -Minutes 5) `
                -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
        $trigger.Repetition = $repetition
    } catch {
        Write-Log ('  repetition skipped: ' + $_.Exception.Message)
    }

    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force `
        -Description 'Keep Windows Mobile Hotspot on, auto start after reboot' | Out-Null

    Write-Log ("  scheduled task '{0}' registered" -f $TaskName)
}

function Uninstall-AutoHotspot {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log '  scheduled task removed'
    } catch {
        Write-Log '  scheduled task not found'
    }

    try {
        $mgr = Get-TetheringManager
        if ($null -ne $mgr -and [int]$mgr.TetheringOperationalState -eq 1) {
            $null = Await ($mgr.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            Write-Log '  hotspot stopped'
        }
    } catch { }

    try {
        Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop
        Write-Host '  folder removed'
    } catch {
        Write-Host ('  folder remove failed: ' + $_.Exception.Message)
    }
}

function Show-Status {
    try {
        $mgr = Get-TetheringManager
        if ($null -eq $mgr) { Write-Host '  no internet uplink right now'; return }
        $ap = $mgr.GetCurrentAccessPointConfiguration()
        Write-Host ("  state   : {0}" -f $mgr.TetheringOperationalState)
        Write-Host ("  ssid    : {0}" -f $ap.Ssid)
        Write-Host ("  clients : {0}" -f $mgr.ClientCount)
    } catch {
        Write-Host ('  cannot query hotspot: ' + $_.Exception.Message)
    }
}

# ------------------------------- main -------------------------------
if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

if ($Uninstall) { Uninstall-AutoHotspot; exit 0 }
if ($Status)    { Show-Status; exit 0 }

if ($Install) {
    if ($Ssid.Length -lt 1 -or $Ssid.Length -gt 32) { Write-Log 'ERROR: SSID must be 1-32 characters'; exit 1 }
    if ($Pass.Length -lt 8 -or $Pass.Length -gt 63) { Write-Log 'ERROR: password must be 8-63 characters'; exit 1 }

    Write-Log ("installing, SSID = '{0}'" -f $Ssid)
    Install-AutoStart -NewSsid $Ssid -NewPass $Pass
    $r = Start-HotspotWithRetry -NewSsid $Ssid -NewPass $Pass -MaxTries $Tries -WaitSec $DelaySec
    if ($r -eq 'ALREADY-ON' -or $r -like 'START:Success*') { Write-Log 'RESULT: OK'; exit 0 }
    Write-Log ('RESULT: FAILED -> ' + $r)
    exit 2
}

$r = Start-HotspotWithRetry -MaxTries $Tries -WaitSec $DelaySec
if ($r -eq 'ALREADY-ON' -or $r -like 'START:Success*') { exit 0 }
exit 2
