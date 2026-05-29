<#
.SYNOPSIS
    HP OMEN Graphics Mode Auto-Toggle & Reboot Tool (PowerShell)

.DESCRIPTION
    Automatically detects current graphics mode via HP BIOS WMI:
    - If current mode is 2 (Optimus), switches to 3 (UMA)
    - If current mode is 3 (UMA), switches to 2 (Optimus)
    After successful switch, waits 3 seconds and reboots the system.
    Must be run as Administrator.
#>

#region ---- Administrator privilege check ----
$current = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($current)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Administrator privileges required. Attempting to elevate..."
    $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell -Verb RunAs -ArgumentList $psi
    exit
}
#endregion

Add-Type -AssemblyName System.Management

#region ---- Enums ----
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
        if (-not $bios) { Write-Warning "WMI class $className not found. Not an HP/OMEN machine?"; return $null }

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
        Write-Warning ("SendOmenBiosWmi failed (CommandType=0x{0:X2}) - {1}" -f $CommandType,$msg)
        return $null
    } catch {
        Write-Warning "WMI Exception: $($_.Exception.Message)"
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

#region ---- Main logic: auto-toggle 2 <-> 3 and reboot ----
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HP OMEN Graphics Mode Auto-Toggle Tool" -ForegroundColor Cyan
Write-Host "  Mode: 2 (Optimus) <-> 3 (UMA)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Get current mode
$currentMode = Get-GfxMode
if ($currentMode.Value -eq -1) {
    Write-Error "Unable to get current graphics mode. Please confirm this is an HP/OMEN system."
    exit 1
}

Write-Host "`nCurrent Graphics Mode: $($currentMode.Name) (Value=$($currentMode.Value))" -ForegroundColor Yellow

# Determine target mode
$targetValue = $null
if ($currentMode.Value -eq 2) {
    $targetValue = 3
    Write-Host "Detected Optimus (2). Switching to UMA (3)" -ForegroundColor Green
} elseif ($currentMode.Value -eq 3) {
    $targetValue = 2
    Write-Host "Detected UMA (3). Switching to Optimus (2)" -ForegroundColor Green
} else {
    Write-Host "Current mode is not 2 or 3 (value = $($currentMode.Value)). No action taken. Exiting." -ForegroundColor Red
    exit 0
}

# Perform switch
$targetName = $GfxModeNames[$targetValue]
Write-Host "Switching graphics mode to $targetName ($targetValue) ..." -ForegroundColor Yellow
$ok = Set-GfxMode -Mode $targetValue -DynamicSwitch:$false

if ($ok) {
    Write-Host "[Success] Graphics mode switch command sent." -ForegroundColor Green
    Write-Host "System will reboot in 3 seconds to apply changes..." -ForegroundColor Magenta
    Start-Sleep -Seconds 3
    Write-Host "Rebooting now..." -ForegroundColor Cyan
    Restart-Computer -Force
} else {
    Write-Host "[Error] Graphics mode switch failed. Check BIOS/driver support." -ForegroundColor Red
    exit 2
}
#endregion
