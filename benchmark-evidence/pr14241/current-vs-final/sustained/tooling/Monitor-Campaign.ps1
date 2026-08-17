<#
.SYNOPSIS
Runs the preserved split system/process/probe monitor for this campaign.

.DESCRIPTION
The implementation is intentionally delegated to the exact monitor preserved
with the prior PR #14241 evidence. Keeping this thin entry point makes the
proven 1s/5s/5s sampling behavior reusable without changing historical files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [Parameter(Mandatory)]
    [string]$StopFile,
    [Parameter(Mandatory)]
    [string]$ReadyFile,
    [int]$SampleIntervalSeconds = 1,
    [int]$ProcessIntervalSeconds = 5,
    [int]$ProbeIntervalSeconds = 5,
    [switch]$ProcessWorker,
    [switch]$ProbeWorker
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$preservedMonitor = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\scripts\idle-tooling\Monitor-PublicRepoCoordinatorBenchmark.ps1'))
if (-not (Test-Path -LiteralPath $preservedMonitor -PathType Leaf)) {
    throw "Preserved monitor '$preservedMonitor' is missing."
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
[pscustomobject][ordered]@{
    ReusedUtc = [DateTime]::UtcNow.ToString('O')
    SourcePath = $preservedMonitor
    SourceSha256 = (Get-FileHash -LiteralPath $preservedMonitor -Algorithm SHA256).Hash
    SampleIntervalSeconds = $SampleIntervalSeconds
    ProcessIntervalSeconds = $ProcessIntervalSeconds
    ProbeIntervalSeconds = $ProbeIntervalSeconds
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'preserved-monitor-provenance.json') -Encoding utf8
& $preservedMonitor @PSBoundParameters
