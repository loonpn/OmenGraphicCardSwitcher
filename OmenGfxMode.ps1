<#
.SYNOPSIS
    HP OMEN Graphics Mode Switch Tool (PowerShell)

.DESCRIPTION
    Queries and modifies graphics modes on HP OMEN laptops using the BIOS WMI interface (root\wmi : hpqBIntM).
    Provides options to switch between hybrid (default), discrete, Optimus, and UMA modes.

.PARAMETER Action
    Get  - Query current graphics mode (default)
    Set  - Switch graphics mode, requires -Mode
    
.PARAMETER Mode
    Target mode:
        0 = Hybrid     (default mixed GPU operation)
        1 = Discrete   (direct access to discrete GPU)
        2 = Optimus
        3 = UMA        (integrated GPU only)

.PARAMETER DynamicSwitch
    Leverages Dynamic Switch (DDS) for immediate mode change without reboot (if supported by the laptop model).

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

#region ---- Administrator Check ----
$current = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($current)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Administrator privileges required. Attempting to elevate..."
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
           "-Action $Action " +
           $(if ($PSBoundParameters.ContainsKey('Mode')) { "-Mode $Mode " } else { "" }) +
           $(if ($DynamicSwitch) { "-DynamicSwitch" } else { "" })
    Start-Process powershell -Verb RunAs -ArgumentList $psi
    exit
}
#endregion

Add-Type -AssemblyName System.Management

#region ---- Graphics Mode Enum ----
# C# GraphicsMode Enum: NotSupported = -1, Hybrid = 0, Discrete = 1, Optimus = 2, UMA = 3
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
        if (-not $bios) { Write-Warning "Unable to locate WMI class $className. This may not be an HP OMEN laptop."; return $null }

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
        Write-Warning ("Send-OmenBiosWmi failed (CommandType=0x{0:X2}) - {1}" -f $CommandType,$msg)
        return $null
    } catch {
        Write-Warning "WMI exception: $($_.Exception.Message)"
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

#region ---- Main Entry ----
switch ($Action) {
    'Get' {
        $info = Get-GfxMode
        Write-Host ""
        Write-Host "Current Graphics Mode: " -NoNewline
        Write-Host ("{0} (Value={1}, Raw={2})" -f $info.Name,$info.Value,$info.Raw) -ForegroundColor Cyan
        Write-Host ""
        $info
    }
    'Set' {
        if (-not $PSBoundParameters.ContainsKey('Mode')) {
            Write-Error "You must specify -Mode (0~3) when using -Action Set."
            exit 1
        }
        $target = $GfxModeNames[[int]$Mode]
        Write-Host ("Switching Graphics Mode -> {0} ({1})  DDS={2}" -f $target,$Mode,$DynamicSwitch.IsPresent) -ForegroundColor Yellow
        $ok = Set-GfxMode -Mode $Mode -DynamicSwitch:$DynamicSwitch
        if ($ok) {
            Write-Host "✔ Command successfully sent." -ForegroundColor Green
            if (-not $DynamicSwitch) {
                Write-Host "⚠ Non-DDS mode. A restart is required to take effect." -ForegroundColor Yellow
            }
            Start-Sleep -Milliseconds 500
            Get-GfxMode | Format-List
        } else {
            Write-Host "✘ Failed to switch mode." -ForegroundColor Red
            exit 2
        }
    }
}
#endregion
