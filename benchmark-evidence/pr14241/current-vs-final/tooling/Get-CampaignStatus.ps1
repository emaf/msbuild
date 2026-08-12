[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LaunchRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$launchPath = Join-Path $LaunchRoot 'launch.json'
if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
    throw "Launch metadata '$launchPath' is missing."
}
$launch = Get-Content -LiteralPath $launchPath -Raw | ConvertFrom-Json
$alive = $false
$identityMatches = $false
try {
    $process = Get-Process -Id ([int]$launch.ProcessId) -ErrorAction Stop
    $alive = -not $process.HasExited
    $identityMatches = $process.StartTime.ToUniversalTime() -eq ([DateTime]$launch.ProcessStartUtc).ToUniversalTime()
}
catch {
    $alive = $false
}
$statusPath = Join-Path $LaunchRoot 'status.json'
$status = if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
}
else {
    $null
}
$completionPath = Join-Path $LaunchRoot 'campaign-completion.json'
$completion = if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
}
else {
    $null
}
[pscustomobject][ordered]@{
    LaunchRoot = $LaunchRoot
    RunId = $launch.RunId
    ResultRoot = $launch.ResultRoot
    ProcessId = $launch.ProcessId
    ProcessStartUtc = $launch.ProcessStartUtc
    Alive = $alive
    ProcessIdentityMatches = $identityMatches
    CurrentStep = if ($null -eq $status) { $null } else { $status.CurrentStep }
    Detail = if ($null -eq $status) { $null } else { $status.Detail }
    EstimatedTotalCampaignHours = if ($null -eq $status) { '2-4 (strict projected maximum 4)' } else { $status.EstimatedTotalCampaignHours }
    Completion = $completion
    Stdout = $launch.Stdout
    Stderr = $launch.Stderr
}
