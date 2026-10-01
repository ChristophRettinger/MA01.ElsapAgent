#Requires -Version 7.0
<#
.SYNOPSIS
Shows the changes of ordered and open hours recorded in the history CSV.

.DESCRIPTION
Reads data/elsap-hours.csv (written by Get-ElsapHours.ps1) and lists every change between
consecutive runs: a time sheet that appeared, disappeared, or whose ordered or open hours differ.
Does not contact ELSAP.

.PARAMETER Project
Regular expression matched (case-insensitive) against the project name, e.g. "Orchestra".
Omit to show all projects.

.PARAMETER Role
Regular expression matched (case-insensitive) against the service/role text, e.g. "Architekt".
Combined with -Project, both must match.

.PARAMETER Days
How many days back to look. Default 90.

.PARAMETER Since
Explicit start date; overrides -Days.

.PARAMETER PassThru
Emit objects instead of a formatted table, e.g. for Export-Csv.

.EXAMPLE
./Show-ElsapChanges.ps1 Orchestra
./Show-ElsapChanges.ps1 -Days 30
./Show-ElsapChanges.ps1 'Azure|ChatGPT' -Since 2026-01-01
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Project,
    [string]$Role,
    [int]$Days = 90,
    [datetime]$Since,
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/Elsap.psm1') -Force

$csvPath = Join-Path $DataDir 'elsap-hours.csv'
if (-not (Test-Path $csvPath)) { throw "No history found at $csvPath. Run Get-ElsapHours.ps1 first." }
if (-not $PSBoundParameters.ContainsKey('Since')) { $Since = (Get-Date).AddDays(-$Days) }

$changes = @(Get-ElsapChangeHistory -Path $csvPath -Since $Since -Project $Project -Role $Role)

if ($PassThru) { return $changes }

if (-not $changes) {
    $scope = (@($Project, $Role) | Where-Object { $_ } | ForEach-Object { "'$_'" }) -join ' / '
    if ($scope) { $scope = " for $scope" }
    Write-Host ("No changes{0} since {1:yyyy-MM-dd}." -f $scope, $Since)
    return
}

$de = [cultureinfo]::GetCultureInfo('de-DE')
$num = { param($v) $v.ToString('N2', $de) }
$delta = { param($v) $v.ToString('+#,##0.00;-#,##0.00;0.00', $de) }
# "old -> new (+delta)"; for new/removed time sheets only the value that exists; "-" when unchanged.
$hours = {
    param($old, $new, $diff)
    if ($null -ne $old -and $null -ne $new) {
        if ($diff -eq 0) { '-' } else { '{0} -> {1} ({2})' -f (& $num $old), (& $num $new), (& $delta $diff) }
    } elseif ($null -ne $new) { & $num $new } else { '(' + (& $num $old) + ')' }
}

$changes | Format-Table -AutoSize @(
    @{ Label = 'When'; Expression = { $_.Timestamp.ToString('yyyy-MM-dd HH:mm') } }
    @{ Label = 'Change'; Expression = { $_.Kind } }
    @{ Label = 'Project'; Expression = { $_.Project -replace '^[A-Z]_', '' } }
    @{ Label = 'Role'; Expression = { $_.Role } }
    @{ Label = 'Open'; Alignment = 'Right'; Expression = { & $hours $_.OpenOld $_.OpenNew $_.OpenDelta } }
    @{ Label = 'Ordered'; Alignment = 'Right'; Expression = { & $hours $_.OrderedOld $_.OrderedNew $_.OrderedDelta } }
)
