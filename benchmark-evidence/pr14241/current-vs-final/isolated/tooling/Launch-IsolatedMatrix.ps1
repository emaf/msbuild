[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$runId = "current-vs-final-isolated-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))"
$resultRoot = Join-Path 'C:\perf\results' $runId
$launchRoot = Join-Path 'C:\perf\benchmark-launches' $runId
$runner = Join-Path $PSScriptRoot 'Run-PublicRepoCoordinatorMatrix.ps1'
$stdout = Join-Path $launchRoot 'stdout.log'
$stderr = Join-Path $launchRoot 'stderr.log'
$completion = Join-Path $launchRoot 'completion.json'

New-Item -ItemType Directory -Path $launchRoot | Out-Null

$arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $runner,
    '-BaseBootstrapRoot', 'C:\perf\bootstraps\current-vs-final\ff5b281f0c58-2E843FFB6575\core',
    '-BaseExpectedCommit', 'ff5b281f0c5828dec0d092fcd1b682019de7d1ca',
    '-CandidateBootstrapRoot', 'C:\perf\bootstraps\current-vs-final\9aa319701cc7-6295250A1F2B\core',
    '-CandidateExpectedCommit', '9aa319701cc70713e5f017a1a8e0cc88b1813ae1',
    '-RoslynRoot', 'C:\perf\repos\roslyn',
    '-RoslynExpectedCommit', 'bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b',
    '-RoslynWorkRoot', 'C:\w\cvfi\r',
    '-AspireRoot', 'C:\perf\repos\aspire',
    '-AspireExpectedCommit', '110a63da8357af437a00d9efc5887ffdcbdfbb3c',
    '-AspireWorkRoot', 'C:\w\cvfi\a',
    '-OutputRoot', $resultRoot,
    '-BootstrapStagingRoot', 'C:\perf\coordinator-bootstrap-staging',
    '-Workload', 'project-incremental',
    '-WarmupBlocks', '1',
    '-PrimaryBlocks', '6',
    '-NodeBudget', '16',
    '-NormalBuildCount', '1',
    '-CandidateBuildCount', '0',
    '-SystemGapWarningThresholdSeconds', '5',
    '-MaxSystemCounterGapSeconds', '30',
    '-MaxProcessSnapshotGapSeconds', '15',
    '-MaxProbeGapSeconds', '15',
    '-MaximumBlockAttempts', '3',
    '-CooldownSeconds', '10'
)

[ordered]@{
    SchemaVersion = 1
    RunId = $runId
    RequestedUtc = [DateTime]::UtcNow.ToString('O')
    LauncherProcessId = $PID
    ResultRoot = $resultRoot
    Runner = $runner
    RunnerSha256 = (Get-FileHash $runner -Algorithm SHA256).Hash
    HarnessSha256 = (Get-FileHash (Join-Path $PSScriptRoot 'Run-PublicRepoCoordinatorBenchmark.ps1') -Algorithm SHA256).Hash
    MonitorSha256 = (Get-FileHash (Join-Path $PSScriptRoot 'Monitor-PublicRepoCoordinatorBenchmark.ps1') -Algorithm SHA256).Hash
    Arguments = $arguments
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $launchRoot 'launch-request.json') -Encoding utf8

$process = Start-Process `
    -FilePath (Get-Command pwsh).Source `
    -ArgumentList $arguments `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru

[ordered]@{
    Status = 'Running'
    ProcessId = $process.Id
    ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('O')
    RunId = $runId
    ResultRoot = $resultRoot
    Stdout = $stdout
    Stderr = $stderr
} | ConvertTo-Json | Set-Content (Join-Path $launchRoot 'launch.json') -Encoding utf8

Write-Host "RUN_ID=$runId"
Write-Host "RUN_ROOT=$resultRoot"
Write-Host "RUNNER_PID=$($process.Id)"
Write-Host "STDOUT=$stdout"
Write-Host "STDERR=$stderr"

$process.WaitForExit()
$exitCode = $process.ExitCode
$process.Dispose()

[ordered]@{
    Status = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
    ExitCode = $exitCode
    CompletedUtc = [DateTime]::UtcNow.ToString('O')
    RunId = $runId
    ResultRoot = $resultRoot
} | ConvertTo-Json | Set-Content $completion -Encoding utf8

exit $exitCode
