#Requires -Version 7.0
<#
.SYNOPSIS
One-time setup: stores the ELSAP credential in the OS credential store and schedules the daily check.

.DESCRIPTION
Windows: Windows Credential Manager (target "ELSAP") and a Task Scheduler task with triggers "at logon" and "daily".
macOS:   Keychain (service "ELSAP") and a LaunchAgent with the same two triggers.
The password is never written to a file or the log.
#>
[CmdletBinding()]
param(
    [string]$DailyAt = '09:00',
    [switch]$SkipLoginTest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/Elsap.psm1') -Force

$credential = Get-Credential -Message 'ELSAP user name and password'
if (-not $credential) { throw "No credential entered." }

if (-not $SkipLoginTest) {
    Write-Host 'Testing login ...'
    $session = Connect-Elsap -Credential $credential
    $count = @(Get-ElsapTimeSheet -Session $session).Count
    Write-Host "Login OK, $count bookable time sheet(s) found."
}

Set-ElsapCredential -Credential $credential
Write-Host 'Credential stored.'

$pwsh = (Get-Process -Id $PID).Path
$script = Join-Path $PSScriptRoot 'Get-ElsapHours.ps1'

if ($IsWindows) {
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -File `"$script`""
    $triggers = @(
        New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        New-ScheduledTaskTrigger -Daily -At $DailyAt
    )
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    Register-ScheduledTask -TaskName 'ELSAP Hours Check' -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "Scheduled task 'ELSAP Hours Check' registered (at logon + daily $DailyAt, runs only while you are logged on)."
} elseif ($IsMacOS) {
    $label = 'local.elsap-agent'
    $plistPath = Join-Path $HOME "Library/LaunchAgents/$label.plist"
    $hour, $minute = $DailyAt.Split(':') | ForEach-Object { [int]$_ }
    $plist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$pwsh</string><string>-NoProfile</string><string>-File</string><string>$script</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>$minute</integer></dict>
</dict>
</plist>
"@
    New-Item -ItemType Directory -Force -Path (Split-Path $plistPath) | Out-Null
    Set-Content -Path $plistPath -Value $plist -Encoding utf8NoBOM
    & launchctl bootout "gui/$(id -u)/$label" 2>$null
    & launchctl bootstrap "gui/$(id -u)" $plistPath
    Write-Host "LaunchAgent '$label' registered (at login + daily $DailyAt)."
}
