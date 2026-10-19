@echo off
chcp 936 >nul
setlocal EnableExtensions
title 永久开启移动热点

rem ==================================================================
rem  改热点名称和密码，只改下面两行。
rem  密码 8-63 位，不要用空格、引号、& | ^ 这类特殊符号。
rem ==================================================================
set "SSID=487"
set "PASS=487@zdtssl"

set "SETUP=%TEMP%\AutoHotspot_setup.ps1"
set "MARK=%TEMP%\AutoHotspot_batch.log"

rem 诊断标记：如果双击后这个文件都没生成，说明脚本被安全软件拦掉了
>"%MARK%" echo [%date% %time%] batch started
echo [%date% %time%] path=%~f0 >>"%MARK%"

echo.
echo   正在准备，请稍候...
echo.

rem ------------------ 从自身解出 PowerShell 主体 ------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=Get-Content -LiteralPath '%~f0' -Encoding Default; $i=[array]::IndexOf($l,'::PS1_BEGIN'); if($i -lt 0){exit 9}; $l[($i+1)..($l.Count-1)] | Set-Content -LiteralPath '%SETUP%' -Encoding UTF8"
if errorlevel 1 goto deployfail
echo [%date% %time%] extracted ok >>"%MARK%"

rem ------------- 运行主体，管理员权限由它自己申请 -------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP%" -Install -Ssid "%SSID%" -Pass "%PASS%"
set "RC=%ERRORLEVEL%"
echo [%date% %time%] finished rc=%RC% >>"%MARK%"

echo.
if not "%RC%"=="0" echo   [注意] 返回码 %RC%，请看上面输出的原因。
echo   按任意键关闭本窗口...
pause >nul
exit /b

:deployfail
echo.
echo   [失败] 无法从本文件解出脚本主体。
echo   请确认：一、不是从压缩包里直接双击运行的；
echo             二、本文件所在目录可写。
echo   文件路径：%~f0
echo.
pause
exit /b

::PS1_BEGIN
<#
  AutoHotspot - 让 Windows 移动热点开机自动开启
  由 .bat 释放到 %ProgramData%\AutoHotspot\hotspot.ps1
  用法：
    -Install -Ssid 名称 -Pass 密码   立即开启 + 注册开机自启
    -Uninstall                       删除所有自启项并关闭热点
    -Status                          查看当前热点状态
    -Check                           诊断：自启项是否健在、上次运行结果、日志
    （不带参数）                      仅确保热点是开着的，自启项用这个
#>
[CmdletBinding()]
param(
    [string]$Ssid = '',
    [string]$Pass = '',
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Check,
    [int]$Tries = 12,
    [int]$DelaySec = 5
)

$ErrorActionPreference = 'Stop'
$TaskName   = 'AutoHotspot'
$Dir        = Join-Path $env:ProgramData 'AutoHotspot'
$Log        = Join-Path $Dir 'hotspot.log'
$SelfPath   = Join-Path $Dir 'hotspot.ps1'
$StartupDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
$VbsPath    = Join-Path $StartupDir 'AutoHotspot.vbs'

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
    Write-Host ('  ' + $line)
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 取"当前真正登录在控制台的那个用户"。
# 本进程可能是用另一个管理员账号提权起来的，直接用 $env:USERNAME 会把任务绑错人。
function Get-InteractiveUser {
    try {
        $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($u) { return $u }
    } catch { }
    try {
        $proc = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($proc) {
            $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
            if ($owner.User) { return ('{0}\{1}' -f $owner.Domain, $owner.User) }
        }
    } catch { }
    return ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
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
    if ($null -eq $script:AsTaskGeneric) { throw '无法解析 AsTask 重载' }
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
            Write-Log ('  写配置时告警：' + $_.Exception.Message)
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
            Write-Log ("  第 {0} 次尝试：{1}" -f $i, $last)
            return $last
        }
        Write-Log ("  第 {0}/{1} 次尝试：{2}" -f $i, $MaxTries, $last)
        if ($i -lt $MaxTries) { Start-Sleep -Seconds $WaitSec }
    }
    return $last
}

function Install-AutoStart {
    param([string]$NewSsid, [string]$NewPass)

    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    if ($PSCommandPath -and ($PSCommandPath -ne $SelfPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $SelfPath -Force
        Write-Log ('  脚本已部署到 ' + $SelfPath)
    }

    try {
        $wifi = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN' -and
            $_.InterfaceDescription -notmatch 'VMware|VirtualBox|Hyper-V|Loopback|TAP'
        }
        if (-not $wifi) { Write-Log '  [警告] 没有检测到无线网卡，移动热点必须有 Wi-Fi 网卡才能用' }
    } catch { }

    foreach ($name in @('SharedAccess', 'WlanSvc')) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            if ($svc.StartType -ne 'Automatic') { Set-Service -Name $name -StartupType Automatic -ErrorAction Stop }
            if ($svc.Status -ne 'Running') { Start-Service -Name $name -ErrorAction SilentlyContinue }
            Write-Log ("  服务 {0}：就绪" -f $name)
        } catch {
            Write-Log ("  服务 {0}：{1}" -f $name, $_.Exception.Message)
        }
    }

    $taskUser = Get-InteractiveUser
    Write-Log ("  计划任务将绑定到登录用户：{0}" -f $taskUser)

    $argument = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $SelfPath
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

    $trigger = New-ScheduledTaskTrigger -AtLogOn
    try { $trigger.Delay = 'PT20S' } catch { }

    try {
        $repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                -RepetitionInterval (New-TimeSpan -Minutes 2)).Repetition
        $trigger.Repetition = $repetition
    } catch {
        Write-Log ('  未能设置每 2 分钟自检：' + $_.Exception.Message)
    }

    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    $principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest

    $ok = $false
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop `
            -Description '保持 Windows 移动热点开启，重启后自动恢复' | Out-Null
        Write-Log ("  计划任务 {0} 已注册" -f $TaskName)
        $ok = $true
    } catch {
        Write-Log ('  [失败] 注册计划任务出错：' + $_.Exception.Message)
    }

    # 回读校验：确认触发器和运行账户真的写进去了
    if ($ok) {
        try {
            $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            foreach ($tr in $t.Triggers) {
                Write-Log ("  触发器校验：{0} 延迟={1} 间隔={2}" -f $tr.CimClass.CimClassName, $tr.Delay, $tr.Repetition.Interval)
            }
            Write-Log ("  运行账户校验：{0} / {1}" -f $t.Principal.UserId, $t.Principal.RunLevel)
        } catch {
            Write-Log ('  回读计划任务失败：' + $_.Exception.Message)
        }
    }

    # 第二道保险：所有用户共用的启动目录里放一个隐藏启动脚本。
    # 计划任务万一被组策略/安全软件拦掉，这条还能兜住。
    try {
        if (-not (Test-Path -LiteralPath $StartupDir)) { New-Item -ItemType Directory -Path $StartupDir -Force | Out-Null }
        $line1 = 'Set sh = CreateObject("WScript.Shell")'
        $line2 = 'sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""' + $SelfPath + '""", 0, False'
        Set-Content -LiteralPath $VbsPath -Value ($line1 + "`r`n" + $line2) -Encoding ASCII -Force
        Write-Log ('  已添加登录自启兜底：' + $VbsPath)
    } catch {
        Write-Log ('  添加登录自启兜底失败：' + $_.Exception.Message)
    }

    return $ok
}

function Uninstall-AutoHotspot {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host '  计划任务已删除'
    } catch {
        Write-Host '  没有找到计划任务'
    }

    if (Test-Path -LiteralPath $VbsPath) {
        try {
            Remove-Item -LiteralPath $VbsPath -Force -ErrorAction Stop
            Write-Host '  登录自启兜底已删除'
        } catch {
            Write-Host ('  删除兜底失败：' + $_.Exception.Message)
        }
    }

    try {
        $mgr = Get-TetheringManager
        if ($null -ne $mgr -and [int]$mgr.TetheringOperationalState -eq 1) {
            $null = Await ($mgr.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
            Write-Host '  热点已关闭'
        }
    } catch { }

    try {
        if (Test-Path -LiteralPath $Dir) {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop
            Write-Host '  配置目录已清理'
        }
    } catch {
        Write-Host ('  清理目录失败：' + $_.Exception.Message)
    }

    $setup = Join-Path $env:TEMP 'AutoHotspot_setup.ps1'
    if (Test-Path -LiteralPath $setup) { Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue }
}

function Show-Status {
    try {
        $mgr = Get-TetheringManager
        if ($null -eq $mgr) { Write-Host '  当前没有可用的上网连接'; return }
        $ap = $mgr.GetCurrentAccessPointConfiguration()
        Write-Host ("  热点状态：{0}" -f $mgr.TetheringOperationalState)
        Write-Host ("  热点名称：{0}" -f $ap.Ssid)
        Write-Host ("  连接设备：{0}" -f $mgr.ClientCount)
    } catch {
        Write-Host ('  无法查询热点状态：' + $_.Exception.Message)
    }
}

function Show-LogTail {
    param([int]$Count = 14)
    if (Test-Path -LiteralPath $Log) {
        Write-Host ''
        Write-Host '  ---------- 执行日志 ----------'
        Get-Content -LiteralPath $Log -Tail $Count -Encoding UTF8 | ForEach-Object { Write-Host ('  ' + $_) }
        Write-Host '  ------------------------------'
    }
}

function Show-Check {
    Write-Host ''
    Write-Host '  ============ 自启项检查 ============'
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ('  计划任务：存在，状态 ' + $t.State)
        Write-Host ('  运行账户：' + $t.Principal.UserId + ' / ' + $t.Principal.RunLevel + ' / ' + $t.Principal.LogonType)
        foreach ($tr in $t.Triggers) {
            Write-Host ('  触发器：' + $tr.CimClass.CimClassName + ' 延迟=' + $tr.Delay + ' 间隔=' + $tr.Repetition.Interval)
        }
        $code = $info.LastTaskResult
        $desc = '代码 ' + $code
        if ($code -eq 0)      { $desc = '成功' }
        if ($code -eq 267009) { $desc = '正在运行' }
        if ($code -eq 267011) { $desc = '还没有运行过' }
        if ($code -eq 267014) { $desc = '被终止' }
        Write-Host ('  上次运行：' + $info.LastRunTime + '   结果：' + $desc)
        Write-Host ('  下次运行：' + $info.NextRunTime)
    } else {
        Write-Host '  计划任务：不存在！'
    }
    Write-Host ('  登录兜底：' + $VbsPath + ' -> ' + (Test-Path -LiteralPath $VbsPath))
    Write-Host ('  安装目录：' + $Dir + ' -> ' + (Test-Path -LiteralPath $Dir))
    Write-Host ''
    Write-Host '  ============ 热点状态 ============'
    Show-Status
    Show-LogTail -Count 20
    Write-Host ''
}

# ------------------------------ 主流程 ------------------------------
# 需要管理员权限的动作，先自己提权再干活（不依赖 .bat 提权，避免静默失败）
if (($Install -or $Uninstall) -and -not (Test-IsAdmin)) {
    Write-Host ''
    Write-Host '  需要管理员权限，马上会弹出 UAC 窗口，请点【是】。' -ForegroundColor Yellow
    $forward = @()
    if ($Install)   { $forward += @('-Install', '-Ssid', ('"' + $Ssid + '"'), '-Pass', ('"' + $Pass + '"')) }
    if ($Uninstall) { $forward += '-Uninstall' }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"')) + $forward
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -Wait -PassThru -ErrorAction Stop
        Show-LogTail
        Write-Host ''
        if ($proc.ExitCode -eq 0) { Write-Host '  [完成] 操作成功。' -ForegroundColor Green }
        else { Write-Host ('  [失败] 返回码 ' + $proc.ExitCode + '，原因见上面的日志。') -ForegroundColor Red }
        exit $proc.ExitCode
    } catch {
        Write-Host ''
        Write-Host '  [失败] 没有拿到管理员权限：' -ForegroundColor Red
        Write-Host ('  ' + $_.Exception.Message)
        Write-Host '  如果刚才点了【否】，重新运行一次并点【是】即可。'
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

if ($Check)     { Show-Check; exit 0 }
if ($Uninstall) { Uninstall-AutoHotspot; exit 0 }
if ($Status)    { Show-Status; exit 0 }

if ($Install) {
    if ($Ssid.Length -lt 1 -or $Ssid.Length -gt 32) { Write-Log '错误：热点名称必须是 1-32 个字符'; exit 1 }
    if ($Pass.Length -lt 8 -or $Pass.Length -gt 63) { Write-Log '错误：密码必须是 8-63 个字符'; exit 1 }

    Write-Log ("开始安装，热点名称 = {0}" -f $Ssid)
    if (-not (Install-AutoStart -NewSsid $Ssid -NewPass $Pass)) {
        Write-Host ''
        Write-Host '  [失败] 开机自启任务没能注册，热点即使开了也不会自己恢复。' -ForegroundColor Red
        Write-Host '  如果是权限问题，请右键本文件选【以管理员身份运行】。'
        exit 1
    }
    $r = Start-HotspotWithRetry -NewSsid $Ssid -NewPass $Pass -MaxTries $Tries -WaitSec $DelaySec

    Write-Host ''
    if ($r -eq 'ALREADY-ON' -or $r -like 'START:Success*') {
        Write-Host '  ================================================'
        Write-Host ("   热点名称：{0}" -f $Ssid)
        Write-Host ("   热点密码：{0}" -f $Pass)
        Write-Host '  ------------------------------------------------'
        Write-Host '   双重自启已就位：'
        Write-Host '     1) 计划任务 AutoHotspot（登录后 20 秒，每 2 分钟自检）'
        Write-Host '     2) 启动目录 AutoHotspot.vbs（兜底，隐藏运行）'
        Write-Host ("   日志：{0}" -f $Log)
        Write-Host '   自检命令（复制到 PowerShell 里跑）：'
        Write-Host '     powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\AutoHotspot\hotspot.ps1" -Check'
        Write-Host '  ================================================'
        exit 0
    }

    Write-Host '  [失败] 热点没能开启，原因见上面的日志。'
    Write-Host '  常见原因：'
    Write-Host '    1) 这台机器没有无线网卡，或网卡驱动不支持 Wi-Fi Direct'
    Write-Host '    2) 当前没有可用的上网连接（热点需要有网才能共享）'
    Write-Host '    3) 网卡被禁用，或飞行模式开着'
    exit 2
}

# 自启模式：开机时网络可能还没就绪，最多等 8 分钟
Write-Log ('【自启】开始，用户 = {0}' -f $env:USERNAME)
$r = Start-HotspotWithRetry -MaxTries 24 -WaitSec 20
Write-Log ('【自启】结束：' + $r)
if ($r -eq 'ALREADY-ON' -or $r -like 'START:Success*') { exit 0 }
exit 2
