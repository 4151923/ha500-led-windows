# HA500 LED control - target machine installer.
# Run from an ELEVATED PowerShell, inside the package directory:  .\install.ps1
# Optional: -StartNow  (also starts the polling task immediately after install)
param([switch]$StartNow)
$ErrorActionPreference = 'Stop'

# ---- checks ----
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'ERROR: run this script from an elevated (Administrator) PowerShell.' -ForegroundColor Red; exit 1 }
if (-not [Environment]::Is64BitProcess) { Write-Host 'ERROR: must run under 64-bit PowerShell.' -ForegroundColor Red; exit 1 }

$hvci = (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue).SecurityServicesRunning
if ($hvci -contains 2) {
  Write-Host 'ERROR: HVCI / Memory Integrity is RUNNING. The signed legacy driver cannot load under HVCI.' -ForegroundColor Red
  Write-Host '       Turn off "Memory integrity" (Windows Security > Device security) and reboot first.' -ForegroundColor Red
  exit 1
}

$payload = Join-Path $PSScriptRoot 'payload'
foreach ($f in 'inpoutx64.sys', 'inpoutx64.dll', 'ha500-led.ps1') {
  if (-not (Test-Path (Join-Path $payload $f))) { Write-Host "ERROR: payload file missing: $f" -ForegroundColor Red; exit 1 }
}

# ---- files ----
$wd = 'C:\zcode-ha500'
New-Item -ItemType Directory -Force -Path $wd | Out-Null
foreach ($f in 'inpoutx64.sys', 'inpoutx64.dll', 'ha500-led.ps1') {
  Copy-Item (Join-Path $payload $f) (Join-Path $wd $f) -Force
  Write-Host ("copied " + $f)
}

# ---- driver service ----
sc.exe create inpoutx64 type= kernel start= demand binPath= "$wd\inpoutx64.sys" | Out-Null
sc.exe start inpoutx64 2>&1 | Out-Null
$svc = Get-Service inpoutx64 -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { Write-Host 'ERROR: inpoutx64 driver service failed to start.' -ForegroundColor Red; exit 1 }
Write-Host 'driver service inpoutx64: RUNNING'

# ---- device hardening: admin-only DACL on \\.\inpoutx64 ----
# The driver creates its device openable by everyone; anyone who can open it gets
# kernel-memory R/W. Restrict to SYSTEM/Administrators (re-applied by ha500-led.ps1
# at every startup because the SD resets when the driver reloads).
try {
  $fi = New-Object IO.FileInfo('\\.\inpoutx64')
  $acl = $fi.GetAccessControl()
  $acl.SetSecurityDescriptorSddlForm('D:P(A;;GA;;;SY)(A;;GA;;;BA)')
  $fi.SetAccessControl($acl)
  Write-Host 'device ACL hardened (SYSTEM/Administrators only)'
} catch {
  Write-Host "WARNING: could not harden device ACL: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---- driver smoke test ----
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class InpChk {
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr LoadLibraryEx(string name, IntPtr h, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr GetProcAddress(IntPtr h, string name);
  public delegate bool BoolFn();
}
'@
$lib = [InpChk]::LoadLibraryEx("$wd\inpoutx64.dll", [IntPtr]::Zero, 0)
$p = [InpChk]::GetProcAddress($lib, 'IsInpOutDriverOpen')
$fn = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($p, [InpChk+BoolFn])
if (-not $fn.Invoke()) { Write-Host 'ERROR: driver loaded but device did not open.' -ForegroundColor Red; exit 1 }
Write-Host 'driver smoke test: OK (IsInpOutDriverOpen = True)'

# ---- scheduled task ----
Stop-ScheduledTask -TaskName 'HA500LedControl' -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\zcode-ha500\ha500-led.ps1 -Auto'
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'HA500LedControl' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host 'scheduled task HA500LedControl registered (SYSTEM, at startup)'

Write-Host ''
Write-Host '=== INSTALL COMPLETE ===' -ForegroundColor Green
Write-Host 'Next steps (VERIFY before enabling auto mode!):'
Write-Host '  1. Watch the front panel and run:'
Write-Host '       powershell -File C:\zcode-ha500\ha500-led.ps1 -Test'
Write-Host '     Each bay should light in order DISK1..DISK5, 3s each.'
Write-Host '  2. If the order matches your bays, start auto mode:'
if ($StartNow) {
  Start-ScheduledTask -TaskName 'HA500LedControl'
  Start-Sleep -Seconds 4
  powershell -NoProfile -ExecutionPolicy Bypass -File "$wd\ha500-led.ps1" -Status
  Write-Host 'auto task STARTED (HA500LedControl).'
} else {
  Write-Host '       Start-ScheduledTask -TaskName HA500LedControl'
}
Write-Host '  Log: C:\zcode-ha500\ha500-led.log'
