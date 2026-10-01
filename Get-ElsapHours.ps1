#Requires -Version 7.0
<#
.SYNOPSIS
Reads ordered and open hours of all bookable ELSAP time sheets, appends them to a history CSV
and shows a notification when anything changed since the previous run.

.DESCRIPTION
Runs at most once per day (use -Force to override). The first run only records the baseline.
On any failure nothing is written to the CSV, a notification is shown and the script exits with 1.
#>
[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/Elsap.psm1') -Force

$csvPath   = Join-Path $DataDir 'elsap-hours.csv'
$statePath = Join-Path $DataDir 'last-success.txt'
$logPath   = Join-Path $DataDir 'elsap.log'
$stampFormat = 'yyyy-MM-dd HH:mm:ss'

function Write-Log([string]$Message) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Add-Content -Path $logPath -Value ('{0} {1}' -f (Get-Date -Format $stampFormat), $Message) -Encoding utf8NoBOM
}

try {
    $lastSuccess = if (Test-Path $statePath) { (Get-Content $statePath -Raw).Trim() } else { $null }
    if (-not $Force -and $lastSuccess -and $lastSuccess.StartsWith((Get-Date -Format 'yyyy-MM-dd'))) {
        Write-Log "Skipped: already ran successfully today ($lastSuccess)."
        return
    }

    $credential = Get-ElsapCredential
    if (-not $credential) { throw "No stored ELSAP credential. Run Setup-Elsap.ps1 first." }

    $session = Connect-Elsap -Credential $credential
    $current = @(Get-ElsapTimeSheet -Session $session)

    $stamp = Get-Date -Format $stampFormat
    $previous = if ($lastSuccess) { @(Get-ElsapSnapshot -Path $csvPath -Timestamp $lastSuccess) } else { @() }
    $changes = if ($lastSuccess) { @(Compare-ElsapSnapshot -Previous $previous -Current $current) } else { @() }

    Add-ElsapSnapshot -Path $csvPath -Timestamp $stamp -Rows $current
    Set-Content -Path $statePath -Value $stamp -Encoding utf8NoBOM

    if (-not $lastSuccess) {
        Write-Log "Baseline recorded: $($current.Count) bookable time sheets."
    } elseif ($changes) {
        $lines = $changes | ForEach-Object { Format-ElsapChange $_ }
        Write-Log ("{0} change(s): {1}" -f $changes.Count, ($lines -join ' | '))
        $shown = @($lines | Select-Object -First 5)
        if ($lines.Count -gt 5) { $shown += "and $($lines.Count - 5) more" }
        Show-ElsapNotification -Title 'ELSAP hours changed' -Message ($shown -join "`n")
    } else {
        Write-Log "No changes ($($current.Count) bookable time sheets)."
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Show-ElsapNotification -Title 'ELSAP check failed' -Message $_.Exception.Message
    exit 1
}
