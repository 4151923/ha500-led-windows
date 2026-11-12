# HA500 LED control - uninstaller.  Run from an ELEVATED PowerShell:  .\uninstall.ps1
# -Purge also removes C:\zcode-ha500 (logs included).
param([switch]$Purge)
$ErrorActionPreference = 'Continue'

Stop-ScheduledTask -TaskName 'HA500LedControl' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'HA500LedControl' -Confirm:$false -ErrorAction SilentlyContinue
Write-Host 'scheduled task removed'

powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\zcode-ha500\ha500-led.ps1' -AllOff 2>$null

sc.exe stop inpoutx64 2>&1 | Out-Null
sc.exe delete inpoutx64 2>&1 | Out-Null
Write-Host 'driver service removed'

if ($Purge) {
  Remove-Item 'C:\zcode-ha500' -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host 'C:\zcode-ha500 removed'
} else {
  Write-Host 'C:\zcode-ha500 kept (logs). Remove manually if desired.'
}
Write-Host '=== UNINSTALL DONE ==='
