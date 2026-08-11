Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$launchRoot = 'C:\perf\benchmark-launches\idle-node-burst-matrix-20260807-181942'
$outputRoot = 'C:\perf\results\idle-node-burst-matrix-20260807-181942'
$matrixScript = 'C:\Users\emafern\.copilot\repos\copilot-worktrees\msbuild\emaf-fictional-garbanzo\scripts\benchmarks\Run-PublicRepoCoordinatorMatrix.ps1'
$bootstrap = 'C:\perf\coordinator-bootstrap-staging\dcf76ee0204f-F8B91508ED12\core'
$completionPath = Join-Path $launchRoot 'completion.json'

$parameters = @{
    BaseBootstrapRoot = $bootstrap
    BaseExpectedCommit = 'dcf76ee0204f7d94776079b4293c043ccec0ad0c'
    CandidateBootstrapRoot = $bootstrap
    CandidateExpectedCommit = 'dcf76ee0204f7d94776079b4293c043ccec0ad0c'
    RoslynRoot = 'C:\perf\repos\roslyn'
    RoslynExpectedCommit = 'bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b'
    RoslynWorkRoot = 'C:\w\rf'
    AspireRoot = 'C:\perf\repos\aspire'
    AspireExpectedCommit = '110a63da8357af437a00d9efc5887ffdcbdfbb3c'
    AspireWorkRoot = 'C:\w\af'
    OutputRoot = $outputRoot
    BootstrapStagingRoot = 'C:\perf\coordinator-bootstrap-staging'
    Workload = 'solution-propagated'
    ConditionKeys = @('F4-N', 'AUTO-N', 'F4-H', 'AUTO-H')
    WarmupBlocks = 1
    PrimaryBlocks = 4
    NodeBudget = 16
    NormalBuildCount = 4
    CandidateBuildCount = 1
    CandidateDelaySeconds = 15
    CandidateOffsetMinimumSeconds = 14
    CandidateOffsetMaximumSeconds = 18
    SystemGapWarningThresholdSeconds = 5
    MaxSystemCounterGapSeconds = 30
    MaxProcessSnapshotGapSeconds = 15
    MaxProbeGapSeconds = 15
    MaximumBlockAttempts = 3
    CooldownSeconds = 30
}

New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null
[ordered]@{
    Status = 'Running'
    ProcessId = $PID
    StartedUtc = [DateTime]::UtcNow.ToString('O')
    OutputRoot = $outputRoot
    MatrixScript = $matrixScript
    ToolingCommit = (git -C (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $matrixScript))) rev-parse HEAD)
    Parameters = $parameters
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $launchRoot 'start.json') -Encoding UTF8

try {
    & $matrixScript @parameters
    [ordered]@{
        Status = 'Succeeded'
        ProcessId = $PID
        CompletedUtc = [DateTime]::UtcNow.ToString('O')
        OutputRoot = $outputRoot
        ExitCode = 0
    } | ConvertTo-Json | Set-Content -LiteralPath $completionPath -Encoding UTF8
}
catch {
    [ordered]@{
        Status = 'Failed'
        ProcessId = $PID
        CompletedUtc = [DateTime]::UtcNow.ToString('O')
        OutputRoot = $outputRoot
        ExitCode = 1
        Error = $_.Exception.ToString()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $completionPath -Encoding UTF8
    throw
}
