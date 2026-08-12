[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [switch]$ValidateInputsOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Scenario.Common.ps1')
Assert-WindowsCampaignHost

if ($ValidateInputsOnly) {
    if (-not (Test-Path -LiteralPath $BootstrapIdentityPath -PathType Leaf)) {
        throw "Bootstrap identity '$BootstrapIdentityPath' does not exist."
    }
    $validationCampaign = Get-CampaignDefinition
    $validationIdentityRecord = Get-Content -LiteralPath $BootstrapIdentityPath -Raw | ConvertFrom-Json
    [void](Get-BootstrapIdentity -Role base -Root $validationIdentityRecord.Base.Root -ExpectedCommit $validationCampaign.Base.Commit)
    [void](Get-BootstrapIdentity -Role final -Root $validationIdentityRecord.Final.Root -ExpectedCommit $validationCampaign.Final.Commit)
    Write-Host "PREFLIGHT_INPUTS_VALID=$OutputRoot"
    return
}

$completionPath = Join-Path $OutputRoot 'completion.json'
$startedPath = Join-Path $OutputRoot 'started.json'
if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    $completion = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
    if (-not $completion.Valid) {
        throw "Existing preflight completion '$completionPath' is invalid."
    }
    Write-Host "PREFLIGHT_COMPLETION=$completionPath"
    return
}
if (Test-Path -LiteralPath $startedPath -PathType Leaf) {
    throw "Preflight started previously but did not complete. Exactly-once functional smoke will not be rerun; inspect '$OutputRoot'."
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Write-JsonAtomic -Path $startedPath -Value ([pscustomobject][ordered]@{
    StartedUtc = [DateTime]::UtcNow.ToString('O')
    ProcessId = $PID
    BootstrapIdentityPath = $BootstrapIdentityPath
    ExactlyOnceBaseFunctionalSmoke = $true
    ExactlyOnceFinalFunctionalSmoke = $true
})

$campaign = Get-CampaignDefinition
$identityRecord = Get-Content -LiteralPath $BootstrapIdentityPath -Raw | ConvertFrom-Json
$base = Get-BootstrapIdentity -Role base -Root $identityRecord.Base.Root -ExpectedCommit $campaign.Base.Commit
$final = Get-BootstrapIdentity -Role final -Root $identityRecord.Final.Root -ExpectedCommit $campaign.Final.Commit
$journal = Join-Path $OutputRoot 'commands.jsonl'
$commandOutput = Join-Path $OutputRoot 'command-output'

function Invoke-SyntheticScenario {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [pscustomobject]$Bootstrap,

        [Parameter(Mandatory)]
        [string]$Condition,

        [Parameter(Mandatory)]
        [object[]]$Builds,

        [Parameter(Mandatory)]
        [int[]]$ExpectedGrants,

        [switch]$RequireDeferred,

        [switch]$ExerciseReplacement
    )

    $scenarioRoot = Join-Path $OutputRoot $Name
    $debugPath = Join-Path $scenarioRoot 'debug'
    New-Item -ItemType Directory -Force -Path $debugPath | Out-Null
    $pipeName = "cvf-preflight-$Name-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $scenarioStartedUtc = [DateTimeOffset]::UtcNow
    $runs = [Collections.Generic.List[object]]::new()
    $result = $null
    $scenarioException = $null
    $cleanupException = $null
    try {
    foreach ($build in $Builds) {
        while (([DateTimeOffset]::UtcNow - $scenarioStartedUtc).TotalSeconds -lt [double]$build.DelaySeconds) {
            Start-Sleep -Milliseconds 20
        }
        $workerRoot = Join-Path $scenarioRoot "worker-$($build.Worker)"
        New-Item -ItemType Directory -Force -Path $workerRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SyntheticWork.proj') -Destination (Join-Path $workerRoot 'SyntheticWork.proj') -Force
        $repository = [pscustomobject]@{
            BuildPath = 'SyntheticWork.proj'
            AdditionalBuildArguments = @("/p:HoldSeconds=$($build.HoldSeconds)")
        }
        $run = Start-ScenarioBuild `
            -Bootstrap $Bootstrap `
            -Repository $repository `
            -Worktree $workerRoot `
            -Condition $Condition `
            -PipeName $pipeName `
            -DebugPath $debugPath `
            -ScenarioRoot $scenarioRoot `
            -RunId $build.RunId `
            -Kind $build.Kind `
            -Worker $build.Worker `
            -Generation 1 `
            -ScenarioStartedUtc $scenarioStartedUtc `
            -Injected:([bool]$build.Injected)
        $runs.Add($run)
    }
    if ($ExerciseReplacement) {
        $replacementStarted = $false
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $lastTreeSampleUtc = [DateTimeOffset]::MinValue
        while (-not $replacementStarted) {
            if (([DateTimeOffset]::UtcNow - $lastTreeSampleUtc).TotalSeconds -ge 1) {
                Update-ScenarioProcessTrees -Runs $runs.ToArray()
                $lastTreeSampleUtc = [DateTimeOffset]::UtcNow
            }
            foreach ($completedRun in @($runs | Where-Object { -not $_.Completed -and $_.Process.HasExited })) {
                if (-not (Complete-ExitedScenarioBuild -Run $completedRun)) {
                    continue
                }
                if ($completedRun.Worker -gt 1 -and -not $replacementStarted) {
                    if (-not $completedRun.Quiescent) {
                        throw "$Name cannot replace worker $($completedRun.Worker) before quiescence."
                    }
                    $workerRoot = $completedRun.Worktree
                    (Get-Item -LiteralPath (Join-Path $workerRoot 'SyntheticWork.proj')).LastWriteTimeUtc = [DateTime]::UtcNow
                    $replacementRepository = [pscustomobject]@{
                        BuildPath = 'SyntheticWork.proj'
                        AdditionalBuildArguments = @('/p:HoldSeconds=1')
                    }
                    $replacement = Start-ScenarioBuild `
                        -Bootstrap $Bootstrap `
                        -Repository $replacementRepository `
                        -Worktree $workerRoot `
                        -Condition $Condition `
                        -PipeName $pipeName `
                        -DebugPath $debugPath `
                        -ScenarioRoot $scenarioRoot `
                        -RunId "$($completedRun.RunId)-replacement" `
                        -Kind normal `
                        -Worker $completedRun.Worker `
                        -Generation 2 `
                        -ScenarioStartedUtc $scenarioStartedUtc
                    $runs.Add($replacement)
                    $replacementStarted = $true
                }
            }
            if ($timer.Elapsed.TotalMinutes -gt 1) {
                throw "$Name did not reach a quiescent worker replacement within one minute."
            }
            Start-Sleep -Milliseconds 50
        }
    }
    Wait-ScenarioBuilds -Runs $runs.ToArray() -TimeoutMinutes 2
    $runRecords = @($runs | ForEach-Object { ConvertTo-RunRecord -Run $_ })
    foreach ($run in $runRecords) {
        if ($run.ExitCode -ne 0 -or -not $run.Quiescent) {
            throw "$Name/$($run.RunId) failed or did not quiesce."
        }
        if (-not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $run.Stderr -Raw))) {
            throw "$Name/$($run.RunId) has nonempty stderr."
        }
    }
    $traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
    if ($traceFiles.Count -ne 1) {
        throw "$Name produced $($traceFiles.Count) Coordinator traces; expected one."
    }
    $trace = ConvertFrom-CoordinatorTrace `
        -TracePaths $traceFiles `
        -RunRecords $runRecords `
        -Budget 16 `
        -RequireEmptyFinalState `
        -StrictParsing
    if (-not $trace.Consistent) {
        throw "$Name trace is inconsistent: $($trace.Errors -join '; ')"
    }
    if ($RequireDeferred -and -not $trace.DeferredGrantOccurred) {
        throw "$Name did not exercise a deferred grant."
    }
    $replayPath = Join-Path $scenarioRoot 'grant-replay.json'
    $replays = @(
        & (Join-Path $PSScriptRoot 'Invoke-GrantReplay.ps1') `
            -BootstrapRoot $Bootstrap.Root `
            -Binlog @($runRecords.Binlog) `
            -OutputPath $replayPath `
            -WorkRoot (Join-Path $OutputRoot '_tooling') `
            -JournalPath $journal
    )
    $grantEvidence = @(
        foreach ($run in $runRecords) {
            $replay = $replays |
                Where-Object { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($run.Binlog) } |
                Select-Object -First 1
            if ($null -eq $replay -or @($replay.Grants).Count -ne 1) {
                throw "$Name/$($run.RunId) does not have exactly one replayed grant."
            }
            [pscustomobject][ordered]@{
                RunId = $run.RunId
                Nodes = [int]$replay.Grants[0].Nodes
            }
        }
    )
    $actualGrants = @($grantEvidence.Nodes)
    $actualGrantMultiset = @($actualGrants | Sort-Object)
    $expectedGrantMultiset = @($ExpectedGrants | Sort-Object)
    if (($actualGrantMultiset -join ',') -ne ($expectedGrantMultiset -join ',')) {
        throw "$Name grant multiset '$($actualGrantMultiset -join ',')' did not match '$($expectedGrantMultiset -join ',')'."
    }
    $record = [pscustomobject][ordered]@{
        Name = $Name
        BootstrapRole = $Bootstrap.Role
        BootstrapCommit = $Bootstrap.ExpectedCommit
        Condition = $Condition
        ExpectedGrants = $ExpectedGrants
        ActualGrants = $actualGrants
        GrantEvidence = $grantEvidence
        DeferredGrantOccurred = $trace.DeferredGrantOccurred
        Runs = $runRecords
        TraceSummary = [pscustomobject]@{
            Consistent = $trace.Consistent
            FinalQueueDepth = $trace.FinalQueueDepth
            FinalActiveBuilds = $trace.FinalActiveBuilds
            FinalAllocatedNodes = $trace.FinalAllocatedNodes
        }
        Valid = $true
    }
    Write-JsonAtomic -Path (Join-Path $scenarioRoot 'validation.json') -Value $record -Depth 9
    $result = $record
    }
    catch {
        $scenarioException = $_.Exception
    }
    finally {
        try {
            $cleanup = Stop-UnfinishedScenarioBuilds -Runs $runs.ToArray()
            Write-JsonAtomic `
                -Path (Join-Path $scenarioRoot 'lifecycle-cleanup.json') `
                -Value $cleanup
            if (-not $cleanup.Succeeded) {
                [void](Write-ScenarioCleanupTerminalOutcome `
                    -ScenarioRoot $scenarioRoot `
                    -Cleanup $cleanup)
                $cleanupException = [InvalidOperationException]::new(
                    "Synthetic scenario cleanup failed: $($cleanup.Errors -join '; ')")
            }
        }
        catch {
            $cleanupException = $_.Exception
        }
    }
    if ($null -ne $scenarioException -and $null -ne $cleanupException) {
        throw [AggregateException]::new(
            "Synthetic scenario '$Name' execution and cleanup failed.",
            [Exception[]]@($scenarioException, $cleanupException))
    }
    if ($null -ne $scenarioException) {
        throw $scenarioException
    }
    if ($null -ne $cleanupException) {
        throw $cleanupException
    }
    return $result
}

$results = [Collections.Generic.List[object]]::new()
$preflightException = $null
$shutdownException = $null
try {
    Invoke-BuildServerShutdown `
        -Bootstraps @($base, $final) `
        -JournalPath $journal `
        -OutputDirectory $commandOutput

    $results.Add((Invoke-SyntheticScenario `
        -Name 'base-functional-isolated' `
        -Bootstrap $base `
        -Condition BASE `
        -Builds @(
            [pscustomobject]@{ RunId = 'normal1'; Kind = 'normal'; Worker = 1; DelaySeconds = 0; HoldSeconds = 1; Injected = $false }
        ) `
        -ExpectedGrants @(16)))

    # This group is the one allowed exact-FINAL functional smoke invocation.
    $results.Add((Invoke-SyntheticScenario `
        -Name 'final-functional-compat-isolated' `
        -Bootstrap $final `
        -Condition COMPAT `
        -Builds @(
            [pscustomobject]@{ RunId = 'normal1'; Kind = 'normal'; Worker = 1; DelaySeconds = 0; HoldSeconds = 1; Injected = $false }
        ) `
        -ExpectedGrants @(16)))
    $results.Add((Invoke-SyntheticScenario `
        -Name 'final-functional-default-isolated' `
        -Bootstrap $final `
        -Condition FINAL-N `
        -Builds @(
            [pscustomobject]@{ RunId = 'normal1'; Kind = 'normal'; Worker = 1; DelaySeconds = 0; HoldSeconds = 1; Injected = $false }
        ) `
        -ExpectedGrants @(8)))
    $results.Add((Invoke-SyntheticScenario `
        -Name 'final-functional-high-injection' `
        -Bootstrap $final `
        -Condition FINAL-H `
        -Builds @(
            [pscustomobject]@{ RunId = 'normal1'; Kind = 'normal'; Worker = 1; DelaySeconds = 0; HoldSeconds = 3; Injected = $false },
            [pscustomobject]@{ RunId = 'injected'; Kind = 'injected'; Worker = 2; DelaySeconds = 0.5; HoldSeconds = 1; Injected = $true }
        ) `
        -ExpectedGrants @(8, 4)))

    # Short control-plane/controller traces exercise both exact binaries.
    $results.Add((Invoke-SyntheticScenario `
        -Name 'base-controller-trace' `
        -Bootstrap $base `
        -Condition BASE `
        -Builds @(
            [pscustomobject]@{ RunId = 'normal1'; Kind = 'normal'; Worker = 1; DelaySeconds = 0; HoldSeconds = 6; Injected = $false },
            [pscustomobject]@{ RunId = 'normal2'; Kind = 'normal'; Worker = 2; DelaySeconds = 0.2; HoldSeconds = 1; Injected = $false },
            [pscustomobject]@{ RunId = 'normal3'; Kind = 'normal'; Worker = 3; DelaySeconds = 0.4; HoldSeconds = 3; Injected = $false }
        ) `
        -ExpectedGrants @(16, 8, 8, 8) `
        -RequireDeferred `
        -ExerciseReplacement))
    $results.Add((Invoke-SyntheticScenario `
        -Name 'final-controller-trace' `
        -Bootstrap $final `
        -Condition FINAL-N `
        -Builds @(
            [pscustomobject]@{ RunId = 'normal1'; Kind = 'normal'; Worker = 1; DelaySeconds = 0; HoldSeconds = 6; Injected = $false },
            [pscustomobject]@{ RunId = 'normal2'; Kind = 'normal'; Worker = 2; DelaySeconds = 0.2; HoldSeconds = 1; Injected = $false },
            [pscustomobject]@{ RunId = 'normal3'; Kind = 'normal'; Worker = 3; DelaySeconds = 0.4; HoldSeconds = 3; Injected = $false }
        ) `
        -ExpectedGrants @(8, 4, 4, 4) `
        -RequireDeferred `
        -ExerciseReplacement))

}
catch {
    $preflightException = $_.Exception
}
finally {
    try {
        Invoke-BuildServerShutdown `
            -Bootstraps @($base, $final) `
            -JournalPath $journal `
            -OutputDirectory $commandOutput
    }
    catch {
        $shutdownException = $_.Exception
    }
}
if ($null -ne $preflightException -or $null -ne $shutdownException) {
    $failures = [Collections.Generic.List[Exception]]::new()
    if ($null -ne $preflightException) {
        $failures.Add($preflightException)
    }
    if ($null -ne $shutdownException) {
        $failures.Add($shutdownException)
    }
    $failure = if ($failures.Count -eq 1) {
        $failures[0]
    }
    else {
        [AggregateException]::new(
            'Preflight execution and build-server shutdown both failed.',
            [Exception[]]$failures.ToArray())
    }
    Write-JsonAtomic -Path (Join-Path $OutputRoot 'failure.json') -Value ([pscustomobject][ordered]@{
        FailedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Error = $failure.ToString()
        ExecutionError = if ($null -eq $preflightException) { $null } else { $preflightException.ToString() }
        BuildServerShutdownError = if ($null -eq $shutdownException) { $null } else { $shutdownException.ToString() }
        ExactlyOnceSmokeWillNotBeRetriedAutomatically = $true
    }) -Depth 8
    throw $failure
}

Write-JsonAtomic -Path $completionPath -Value ([pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    ExactlyOnceBaseFunctionalSmoke = $true
    ExactlyOnceFinalFunctionalSmoke = $true
    ExactBaseControllerTraceSmoke = $true
    ExactFinalControllerTraceSmoke = $true
    Results = $results.ToArray()
    Valid = $true
}) -Depth 12
Write-Host "PREFLIGHT_COMPLETION=$completionPath"
