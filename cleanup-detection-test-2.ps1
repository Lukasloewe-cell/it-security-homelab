#Requires -RunAsAdministrator

Write-Host "=== Cleanup Detection Test 2 ===" -ForegroundColor Yellow

Remove-Item "$env:TEMP\exec-marker.txt" -ErrorAction SilentlyContinue

Remove-LocalGroupMember -Group "Administrators" -Member "svc_update" -ErrorAction SilentlyContinue
Remove-LocalUser -Name "svc_update" -ErrorAction SilentlyContinue

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 1 -PropertyType DWord -Force | Out-Null

Unregister-ScheduledTask -TaskName "WindowsUpdateHelper" -Confirm:$false -ErrorAction SilentlyContinue

Remove-Item "$env:USERPROFILE\Downloads\Rechnung_Oktober.pdf.exe" -ErrorAction SilentlyContinue

Remove-Item "$env:TEMP\sysinfo_recon.txt" -ErrorAction SilentlyContinue

Write-Host "=== Cleanup fertig. UAC wieder aktiv (ggf. Neustart noetig). ===" -ForegroundColor Green
Write-Host "Pruef zur Kontrolle:"
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA"
