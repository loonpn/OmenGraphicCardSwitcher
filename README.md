# HP OMEN Graphics Mode Switch Tool (PowerShell)

## Description

This script allows you to query and modify the graphics mode on HP OMEN laptops using the BIOS WMI interface (`root\wmi : hpqBIntM`). It supports switching between hybrid mode, discrete GPU mode, NVIDIA Optimus, and UMA (integrated graphics mode).

The script must be run **as Administrator**.

## Requirements

- A HP OMEN laptop or other HP models that expose the `hpqBIntM` BIOS WMI class
- Windows PowerShell
- Administrator permission

## Usage

### Query Current Graphics Mode

```powershell
.\OmenGfxMode.ps1
.\OmenGfxMode.ps1 -Action Get
```

Expected Output:

```
Current Graphics Mode: Discrete (Value=1, Raw=0x01)
```

### Set Graphics Mode

```powershell
.\OmenGfxMode.ps1 -Action Set -Mode <mode> [-DynamicSwitch]
```

Where `<mode>` is:

- `0`: Hybrid Mode (default mixed GPU operation)
- `1`: Discrete Mode (direct access to discrete GPU)
- `2`: Optimus Mode (NVIDIA Optimus configuration)
- `3`: UMA Mode (integrated GPU only)

#### Examples

1. Switch to **NVIDIA Optimus Mode** (requires restart):
   ```powershell
   .\OmenGfxMode.ps1 -Action Set -Mode 2
   ```

2. Switch to **integrated GPU Mode** (requires restart):
   ```powershell
   .\OmenGfxMode.ps1 -Action Set -Mode 3
   ```

3. Switch to **Hybrid Mode** using **Dynamic Switch** (DDS, no restart required):
   ```powershell
   .\OmenGfxMode.ps1 -Action Set -Mode 0 -DynamicSwitch
   ```

### Notes

1. If run without administrator permissions, the script will automatically attempt to elevate itself.
2. When using Dynamic Switch (`-DynamicSwitch`), DDS must be supported by the laptop model.
3. Changing the graphics mode will only take effect after a restart unless `-DynamicSwitch` is used.

## Troubleshooting

- If the script fails with `NotSupported` when querying, your device likely does not support the `hpqBIntM` interface or the graphics switching feature.
- Check your laptop’s BIOS menu for any additional configurations related to graphics mode switching.
