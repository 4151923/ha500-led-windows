# Remote: deploy HA500 LED auto-control - status check, register startup task, start it, verify.
$ErrorActionPreference = 'Continue'

Write-Output '=== current status ==='
& powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\zcode-ha500\ha500-led.ps1' -Status 2>&1 | ForEach-Object { Write-Output $_ }

Write-Output '=== registering scheduled task (SYSTEM, at startup) ==='
Stop-ScheduledTask -TaskName 'HA500LedControl' -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\zcode-ha500\ha500-led.ps1 -Auto'
$trigger1 = New-ScheduledTaskTrigger -AtStartup
$trigger2 = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(50))
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'HA500LedControl' -Action $action -Trigger $trigger1 -Settings $settings -Principal $principal -Force | Out-Null
Write-Output 'task registered'

Write-Output '=== starting task ==='
Start-ScheduledTask -TaskName 'HA500LedControl'
Start-Sleep -Seconds 6
$ti = Get-ScheduledTask -TaskName 'HA500LedControl'
Write-Output ('task state: ' + $ti.State)

Write-Output '=== status after task start ==='
& powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\zcode-ha500\ha500-led.ps1' -Status 2>&1 | ForEach-Object { Write-Output $_ }

Write-Output '=== recent log ==='
Get-Content 'C:\zcode-ha500\ha500-led.log' -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ('  ' + $_) }
Write-Output '=== DONE ==='
