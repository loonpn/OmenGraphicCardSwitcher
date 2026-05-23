<#
.SYNOPSIS
    HP OMEN 显卡模式查看/切换工具 (PowerShell 版)

.DESCRIPTION
    通过 HP BIOS WMI 接口 (root\wmi : hpqBIntM) 获取或设置独显/混合/Optimus/UMA 模式。
    必须以管理员身份运行。

.PARAMETER Action
    Get  - 获取当前显卡模式 (默认)
    Set  - 设置显卡模式，需要配合 -Mode

.PARAMETER Mode
    目标模式:
        0 = Hybrid
        1 = Discrete (独显直连)
        2 = Optimus
        3 = UMA

.PARAMETER DynamicSwitch
    使用动态切换 (DDS)，机型支持时无需重启。

.EXAMPLE
    .\OmenGfxMode.ps1
    .\OmenGfxMode.ps1 -Action Get
    .\OmenGfxMode.ps1 -Action Set -Mode 1
    .\OmenGfxMode.ps1 -Action Set -Mode 0 -DynamicSwitch
#>

[CmdletBinding()]
param(
    [ValidateSet('Get','Set')]
    [string]$Action = 'Get',

    [ValidateRange(0,3)]
    [byte]$Mode,

    [switch]$DynamicSwitch
)

#region ---- 管理员权限检查 ----
$current = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($current)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "需要管理员权限运行，正在尝试提权..."
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
           "-Action $Action " +
           $(if ($PSBoundParameters.ContainsKey('Mode')) { "-Mode $Mode " } else { "" }) +
           $(if ($DynamicSwitch) { "-DynamicSwitch" } else { "" })
    Start-Process powershell -Verb RunAs -ArgumentList $psi
    exit
}
#endregion

Add-Type -AssemblyName System.Management

#region ---- 枚举 ----
$GfxModeNames = @{
    0 = 'Hybrid'
    1 = 'Discrete'
    2 = 'Optimus'
    3 = 'UMA'
}
#endregion

function Send-OmenBiosWmi {
    param(
        [uint32]$CommandType,
        [byte[]]$Data,
        [int]$OutputSize,
        [uint32]$Command = 0x20008
    )

    $ns         = 'root\wmi'
    $className  = 'hpqBIntM'
    $methodName = "hpqBIOSInt$OutputSize"
    $sign       = [byte[]](0x53,0x45,0x43,0x55)   # 'SECU'

    try {
        $dataInClass = New-Object System.Management.ManagementClass($ns,'hpqBDataIn',$null)
        $dataIn      = $dataInClass.CreateInstance()
        $dataIn['Command']     = $Command
        $dataIn['CommandType'] = $CommandType
        $dataIn['Sign']        = $sign
        if ($Data) {
            $dataIn['hpqBData'] = $Data
            $dataIn['Size']     = [uint32]$Data.Length
        } else {
            $dataIn['Size']     = [uint32]0
        }

        $searcher = New-Object System.Management.ManagementObjectSearcher($ns, "SELECT * FROM $className")
        $bios     = $searcher.Get() | Select-Object -First 1
        if (-not $bios) { Write-Warning "找不到 WMI 类 $className，可能不是 HP/OMEN 机型。"; return $null }

        $inParams = $bios.GetMethodParameters($methodName)
        $inParams['InData'] = $dataIn
        $result   = $bios.InvokeMethod($methodName,$inParams,$null)

        $outData    = $result['OutData']
        $returnCode = [uint32]$outData['rwReturnCode']

        if ($returnCode -eq 0) {
            if ($OutputSize -ne 0) { return [byte[]]$outData['Data'] }
            else                    { return ,@() }
        }

        $msg = switch ($returnCode) {
            0x03 { 'Command Not Available' }
            0x05 { 'Input or Output Size Too Small' }
            default { "0x{0:X}" -f $returnCode }
        }
        Write-Warning ("SendOmenBiosWmi 失败 (CommandType=0x{0:X2}) - {1}" -f $CommandType,$msg)
        return $null
    } catch {
        Write-Warning "WMI 异常: $($_.Exception.Message)"
        return $null
    }
}

function Get-GfxMode {
    $r = Send-OmenBiosWmi -CommandType 82 -Data ([byte[]](0,0,0,0)) -OutputSize 4 -Command 1
    if ($r -and $r.Length -gt 0) {
        $val  = $r[0] -band 0x7F
        $name = if ($GfxModeNames.ContainsKey([int]$val)) { $GfxModeNames[[int]$val] } else { 'Unknown' }
        [pscustomobject]@{ Value = $val; Name = $name; Raw = ('0x{0:X2}' -f $r[0]) }
    } else {
        [pscustomobject]@{ Value = -1; Name = 'NotSupported'; Raw = $null }
    }
}

function Set-GfxMode {
    param(
        [Parameter(Mandatory)][ValidateRange(0,3)][byte]$Mode,
        [switch]$DynamicSwitch
    )
    $b = $Mode
    if ($DynamicSwitch) { $b = $b -bor 0x80 }
    $r = Send-OmenBiosWmi -CommandType 82 -Data ([byte[]]($b,0,0,0)) -OutputSize 0 -Command 2
    return ($null -ne $r)
}

#region ---- 主入口 ----
switch ($Action) {
    'Get' {
        $info = Get-GfxMode
        Write-Host ""
        Write-Host "当前显卡模式: " -NoNewline
        Write-Host ("{0} (Value={1}, Raw={2})" -f $info.Name,$info.Value,$info.Raw) -ForegroundColor Cyan
        Write-Host ""
        $info
    }
    'Set' {
        if (-not $PSBoundParameters.ContainsKey('Mode')) {
            Write-Error "使用 -Action Set 时必须指定 -Mode (0~3)。"
            exit 1
        }
        $target = $GfxModeNames[[int]$Mode]
        Write-Host ("正在切换显卡模式 -> {0} ({1})  DDS={2}" -f $target,$Mode,$DynamicSwitch.IsPresent) -ForegroundColor Yellow
        $ok = Set-GfxMode -Mode $Mode -DynamicSwitch:$DynamicSwitch
        if ($ok) {
            Write-Host "[OK] 命令已发送成功。" -ForegroundColor Green
            if (-not $DynamicSwitch) {
                Write-Host "[提示] 非动态切换模式，需要重启电脑才能生效。" -ForegroundColor Yellow
            }
            Start-Sleep -Milliseconds 500
            Get-GfxMode | Format-List
        } else {
            Write-Host "[Error] 切换失败。" -ForegroundColor Red
            exit 2
        }
    }
}
#endregion