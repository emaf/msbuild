[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$PreparationPath,
    [Parameter(Mandatory)]
    [ValidateSet('roslyn', 'aspire')]
    [string]$RepositoryName,
    [Parameter(Mandatory)]
    [ValidateSet('BASE', 'FINAL-N', 'FINAL-H')]
    [string]$Condition,
    [Parameter(Mandatory)]
    [ValidateSet(8, 10)]
    [int]$WorkerCount,
    [Parameter(Mandatory)]
    [int]$BlockNumber,
    [Parameter(Mandatory)]
    [int]$AttemptNumber,
    [Parameter(Mandatory)]
    [int]$OrderIndex,
    [int]$AnalysisBlockNumber = 0,
    [bool]$IsWarmup = $false,
    [switch]$Pilot,
    [string]$RunIdentity,
    [DateTimeOffset]$HardDeadlineUtc = [DateTimeOffset]::MaxValue,
    [Parameter(Mandatory)]
    [string]$ScenarioRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$parentToolingRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $parentToolingRoot 'Scenario.Common.ps1')
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
Assert-WindowsCampaignHost

$campaign = Get-CampaignDefinition
$validity = $campaign.Validity
if (Test-Path -LiteralPath $ScenarioRoot) {
    throw "Scenario root '$ScenarioRoot' already exists."
}
$expectedRunIdentity = New-SustainedScenarioRunIdentity `
    -Repository $RepositoryName `
    -Condition $Condition `
    -BlockNumber $BlockNumber `
    -AttemptNumber $AttemptNumber `
    -OrderIndex $OrderIndex `
    -WorkerCount $WorkerCount
if ([string]::IsNullOrWhiteSpace($RunIdentity)) {
    $RunIdentity = $expectedRunIdentity
}
elseif ($RunIdentity -ne $expectedRunIdentity) {
    throw "Scenario run identity '$RunIdentity' does not match '$expectedRunIdentity'."
}

New-Item -ItemType Directory -Path $ScenarioRoot | Out-Null
$monitorRoot = Join-Path $ScenarioRoot 'monitor'
$debugPath = Join-Path $ScenarioRoot 'coordinator-debug'
$journal = Join-Path $ScenarioRoot 'commands.jsonl'
$commandOutput = Join-Path $ScenarioRoot 'command-output'
$eventPath = Join-Path $ScenarioRoot 'controller-events.jsonl'
New-Item -ItemType Directory -Force -Path $debugPath | Out-Null

$identityRecord =
    Get-Content -LiteralPath $BootstrapIdentityPath -Raw |
    ConvertFrom-Json
$base = Get-BootstrapIdentity `
    -Role base `
    -Root $identityRecord.Base.Root `
    -ExpectedCommit $campaign.Base.Commit
$final = Get-BootstrapIdentity `
    -Role final `
    -Root $identityRecord.Final.Root `
    -ExpectedCommit $campaign.Final.Commit
$conditionDefinition = Get-ConditionDefinition -Key $Condition
$bootstrap = if ($conditionDefinition.BootstrapRole -eq 'base') {
    $base
}
else {
    $final
}
$preparation =
    Get-Content -LiteralPath $PreparationPath -Raw |
    ConvertFrom-Json
if ($preparation.BootstrapIdentities.Base.Commit -ne $campaign.Base.Commit -or
    $preparation.BootstrapIdentities.Final.Commit -ne $campaign.Final.Commit -or
    $preparation.BootstrapIdentitySha256 -ne
        (Get-FileHash -LiteralPath $BootstrapIdentityPath -Algorithm SHA256).Hash) {
    throw 'Preparation metadata targets different bootstrap identities.'
}
$preparedRepository = $preparation.Repositories |
    Where-Object Name -eq $RepositoryName |
    Select-Object -First 1
if ($null -eq $preparedRepository) {
    throw "Preparation metadata does not contain '$RepositoryName'."
}
$repositoryDefinition = Get-RepositoryDefinition -Name $RepositoryName
$selectedWorktreeNames = @(
    Get-SustainedSelectedWorktreeNames -WorkerCount $WorkerCount
)
$selectedWorktrees = @(
    foreach ($name in $selectedWorktreeNames) {
        $worktree = $preparedRepository.Worktrees |
            Where-Object Name -eq $name |
            Select-Object -First 1
        if ($null -eq $worktree) {
            throw "Prepared worktree '$RepositoryName/$name' is missing."
        }
        $worktree
    }
)
$repository = [pscustomobject][ordered]@{
    Name = $RepositoryName
    Root = $preparedRepository.Repository.Root
    Commit = $repositoryDefinition.Commit
    WorkRoot = $preparedRepository.WorkRoot
    BuildPath = $preparedRepository.BuildPath
    TouchPath = $preparedRepository.TouchPath
    AdditionalBuildArguments =
        @($preparedRepository.AdditionalBuildArguments)
    Worktrees = $selectedWorktrees
}

function Get-PreparedSustainedWorktree {
    param([Parameter(Mandatory)][string]$Name)

    $worktree = $repository.Worktrees |
        Where-Object Name -eq $Name |
        Select-Object -First 1
    if ($null -eq $worktree) {
        throw "Selected prepared worktree '$Name' is missing."
    }
    return [string]$worktree.Path
}

function Save-SustainedLiveRuns {
    $records = @(
        $script:allRuns |
            ForEach-Object {
                ConvertTo-RunRecord -Run $_
            }
    )
    Write-JsonAtomic `
        -Path (Join-Path $ScenarioRoot 'runs-live.json') `
        -Value $records `
        -Depth 9
}

function Add-SustainedControllerEvent {
    param(
        [Parameter(Mandatory)]
        [string]$Event,
        [object]$Run,
        [System.Collections.IDictionary]$Data = @{}
    )

    $entry = [ordered]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Event = $Event
        RunId = if ($null -eq $Run) {
            $null
        }
        else {
            $Run.RunId
        }
        Worker = if ($null -eq $Run) {
            $null
        }
        else {
            $Run.Worker
        }
        Generation = if ($null -eq $Run) {
            $null
        }
        else {
            $Run.Generation
        }
    }
    foreach ($item in $Data.GetEnumerator()) {
        $entry[$item.Key] = $item.Value
    }
    Add-CommandJournalEntry `
        -JournalPath $eventPath `
        -Entry ([pscustomobject]$entry)
}

function Get-SustainedLiveTrace {
    $traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
    if ($traceFiles.Count -eq 0) {
        return $null
    }
    if ($traceFiles.Count -ne 1) {
        throw "Sustained scenario produced $($traceFiles.Count) Coordinator server traces; expected exactly one."
    }
    $records = @(
        $script:allRuns |
            ForEach-Object {
                ConvertTo-RunRecord -Run $_
            }
    )
    $trace = ConvertFrom-CoordinatorTrace `
        -TracePaths $traceFiles `
        -RunRecords $records `
        -Budget $campaign.NodeBudget `
        -StrictParsing
    if (-not $trace.Consistent) {
        throw "Live Coordinator trace became inconsistent: $($trace.Errors -join '; ')"
    }
    return $trace
}

function Complete-SustainedExitedRuns {
    param([bool]$AllowReplacement)

    $completed = [Collections.Generic.List[object]]::new()
    foreach ($run in @(
        $script:allRuns |
            Where-Object {
                -not $_.Completed -and $_.Process.HasExited
            }
    )) {
        if (Complete-ExitedScenarioBuild -Run $run) {
            $completed.Add($run)
        }
    }
    foreach ($run in $completed | Sort-Object ProcessExitUtc) {
        Add-SustainedControllerEvent `
            -Event 'Completed' `
            -Run $run `
            -Data ([ordered]@{
                ExitCode = $run.ExitCode
                Quiescent = $run.Quiescent
                ProcessExitUtc = $run.ProcessExitUtc.ToString('O')
            })
        $run.CompletionEventWritten = $true
        if ($run.Kind -eq 'normal' -and
            $run.Generation -eq 1 -and
            $null -eq $script:windowTiming -and
            $run.Quiescent -and
            $run.ExitCode -eq 0) {
            $script:initialNormalCompletionCount++
        }
        if (-not $run.Quiescent) {
            $script:controller.WorktreeOverlap = $true
            $script:stopSubmissions = $true
        }
        if ($run.ExitCode -ne 0) {
            $script:controller.PolicyFailureRunIds += $run.RunId
            $script:stopSubmissions = $true
        }
        if ($run.Kind -ne 'normal' -or
            -not $AllowReplacement -or
            $script:stopSubmissions -or
            -not $run.Quiescent -or
            $run.ExitCode -ne 0) {
            continue
        }
        $now = [DateTimeOffset]::UtcNow
        if ($null -ne $script:windowTiming -and
            $now -ge $script:measurementEndUtc) {
            continue
        }
        $worktreeName = "normal$($run.Worker)"
        $worktree = Get-PreparedSustainedWorktree -Name $worktreeName
        $touch = Touch-CampaignInput `
            -Worktree $worktree `
            -RelativePath $repository.TouchPath
        $script:generation[$run.Worker]++
        $replacement = Start-ScenarioBuild `
            -Bootstrap $bootstrap `
            -Repository $repository `
            -Worktree $worktree `
            -Condition $Condition `
            -PipeName $script:pipeName `
            -DebugPath $debugPath `
            -ScenarioRoot $ScenarioRoot `
            -RunId (
                "normal$($run.Worker)-g$($script:generation[$run.Worker])") `
            -Kind normal `
            -Worker $run.Worker `
            -Generation $script:generation[$run.Worker] `
            -ScenarioStartedUtc $script:scenarioStartedUtc
        $script:allRuns.Add($replacement)
        Add-SustainedControllerEvent `
            -Event 'ReplacementLaunched' `
            -Run $replacement `
            -Data ([ordered]@{
                ReplacedRunId = $run.RunId
                PredecessorExitUtc = $run.ProcessExitUtc.ToString('O')
                PredecessorQuiescent = $run.Quiescent
                TouchUtc = $touch.TouchedUtc
                ProcessStartUtc = $replacement.ProcessStartUtc.ToString('O')
            })
    }
}

Assert-FreeDiskSpace `
    -Path $repository.WorkRoot `
    -MinimumGiB $validity.RawResultsReserveGiB `
    -RecordPath (Join-Path $ScenarioRoot 'disk-guard.json') |
    Out-Null
foreach ($worktree in $selectedWorktrees) {
    [void](Get-GitIdentity `
        -Root $worktree.Path `
        -ExpectedCommit $repository.Commit `
        -RequireClean)
}
Invoke-BuildServerShutdown `
    -Bootstraps @($base, $final) `
    -JournalPath $journal `
    -OutputDirectory $commandOutput
Wait-ForMachineIdle `
    -RecordPath (Join-Path $ScenarioRoot 'idle-gate.json') `
    -MinimumAvailableMB 16384

$pipeName = "cvf-sustained-$RepositoryName-b$BlockNumber-a$AttemptNumber-o$OrderIndex-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$normalEnvironment = New-ConditionEnvironment `
    -Condition $Condition `
    -PipeName $pipeName `
    -DotNetRoot $bootstrap.Root `
    -EnableDebugTrace `
    -DebugPath $debugPath
$injectedEnvironment = New-ConditionEnvironment `
    -Condition $Condition `
    -PipeName $pipeName `
    -DotNetRoot $bootstrap.Root `
    -Injected `
    -EnableDebugTrace `
    -DebugPath $debugPath
Assert-ConditionEnvironmentContract `
    -Condition $Condition `
    -Environment $normalEnvironment
Assert-ConditionEnvironmentContract `
    -Condition $Condition `
    -Environment $injectedEnvironment `
    -Injected
$debugEnvironmentParity = Test-SustainedDebugEnvironmentParity `
    -NormalEnvironment $normalEnvironment `
    -InjectedEnvironment $injectedEnvironment `
    -Condition $Condition
if (-not $debugEnvironmentParity.Valid) {
    throw "Normal/injected debug environment parity failed: $($debugEnvironmentParity.Errors -join '; ')"
}

$metadata = [ordered]@{
    SchemaVersion = 1
    StartedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Shape = 'sustained'
    FixedWindowMode = $true
    Pilot = [bool]$Pilot
    Repository = $RepositoryName
    RepositoryCommit = $repository.Commit
    Condition = $Condition
    WorkerCount = $WorkerCount
    BlockNumber = $BlockNumber
    AnalysisBlockNumber = $AnalysisBlockNumber
    IsWarmup = $IsWarmup
    AttemptNumber = $AttemptNumber
    OrderIndex = $OrderIndex
    RunIdentity = $RunIdentity
    BootstrapRole = $bootstrap.Role
    BootstrapCommit = $bootstrap.ExpectedCommit
    BootstrapProductVersion = $bootstrap.ProductVersion
    BootstrapMSBuildSha256 = $bootstrap.MSBuildDllSha256
    PipeName = $pipeName
    DebugPath = $debugPath
    DebugEnvironmentParity = $debugEnvironmentParity
    NodeBudget = $campaign.NodeBudget
    FixedWindowSeconds = $validity.MeasuredWindowSeconds
    FixedInjectionOffsetSeconds = $validity.InjectionOffsetSeconds
    OldTwelveCompletionTenMinuteGateApplied = $false
    HardDeadlineUtc = if ($HardDeadlineUtc -eq [DateTimeOffset]::MaxValue) {
        $null
    }
    else {
        $HardDeadlineUtc.ToUniversalTime().ToString('O')
    }
    SelectedWorktrees = @($selectedWorktreeNames)
    NormalEnvironment =
        Get-EnvironmentContractRecord -Environment $normalEnvironment
    InjectedEnvironment =
        Get-EnvironmentContractRecord -Environment $injectedEnvironment
    Succeeded = $false
}
Write-JsonAtomic `
    -Path (Join-Path $ScenarioRoot 'scenario-metadata.json') `
    -Value ([pscustomobject]$metadata) `
    -Depth 12

$allRuns = [Collections.Generic.List[object]]::new()
$generation = [int[]]::new($WorkerCount + 1)
$windowSamples = [Collections.Generic.List[object]]::new()
$controller = [ordered]@{
    ScenarioStartedUtc = $null
    InitialNormalCompletionCount = 0
    LastOnsetEvidence = $null
    MeasurementStartUtc = $null
    MeasurementEndUtc = $null
    InjectionDueUtc = $null
    InjectionStartedUtc = $null
    InjectionActualOffsetSeconds = $null
    InjectionState = $null
    SubmissionStopObservedUtc = $null
    SubmissionStopActualOffsetSeconds = $null
    SubmissionStopObservedOffsetSeconds = $null
    WorktreeOverlap = $false
    PolicyFailureRunIds = @()
    WorkerSizingResponse = $null
    DrainCompleted = $false
    DrainTimedOut = $false
    HardDeadlineExceeded = $false
}
$monitor = $null
$cleanup = $null
$executionErrors = [Collections.Generic.List[string]]::new()
$scenarioStartedUtc = [DateTimeOffset]::MinValue
$windowTiming = $null
$measurementStartUtc = $null
$measurementEndUtc = $null
$injectionDueUtc = $null
$injectedRun = $null
$initialNormalCompletionCount = 0
$lastOnsetEvidence = $null
$lastTraceCheckUtc = [DateTimeOffset]::MinValue
$lastProcessTreeSampleUtc = [DateTimeOffset]::MinValue
$nextWindowSampleUtc = [DateTimeOffset]::MaxValue
$stopSubmissions = $false
$stopEventWritten = $false
$onsetDeadlineUtc = [DateTimeOffset]::MaxValue
$drainStartedUtc = $null

try {
    $monitor = Start-ScenarioMonitor -MonitorRoot $monitorRoot
    foreach ($worker in 1..$WorkerCount) {
        [void](Touch-CampaignInput `
            -Worktree (
                Get-PreparedSustainedWorktree -Name "normal$worker") `
            -RelativePath $repository.TouchPath)
    }
    $scenarioStartedUtc = [DateTimeOffset]::UtcNow
    $controller.ScenarioStartedUtc = $scenarioStartedUtc.ToString('O')
    $onsetDeadlineUtc = $scenarioStartedUtc.AddMinutes(
        [double]$validity.OnsetTimeoutMinutes)
    Add-SustainedControllerEvent -Event 'ScenarioStarted' -Run $null
    foreach ($worker in 1..$WorkerCount) {
        $generation[$worker]++
        $run = Start-ScenarioBuild `
            -Bootstrap $bootstrap `
            -Repository $repository `
            -Worktree (
                Get-PreparedSustainedWorktree -Name "normal$worker") `
            -Condition $Condition `
            -PipeName $pipeName `
            -DebugPath $debugPath `
            -ScenarioRoot $ScenarioRoot `
            -RunId "normal$worker-g$($generation[$worker])" `
            -Kind normal `
            -Worker $worker `
            -Generation $generation[$worker] `
            -ScenarioStartedUtc $scenarioStartedUtc
        $allRuns.Add($run)
        Add-SustainedControllerEvent -Event 'Launched' -Run $run
    }

    while (-not $stopSubmissions) {
        $now = [DateTimeOffset]::UtcNow
        if ($HardDeadlineUtc -ne [DateTimeOffset]::MaxValue -and
            $now -ge $HardDeadlineUtc.ToUniversalTime()) {
            $controller.HardDeadlineExceeded = $true
            $stopSubmissions = $true
            Add-SustainedControllerEvent `
                -Event 'CampaignHardTimeout' `
                -Run $null
            break
        }
        if (($now - $lastProcessTreeSampleUtc).TotalSeconds -ge 1) {
            Update-ScenarioProcessTrees -Runs $allRuns.ToArray()
            $lastProcessTreeSampleUtc = $now
        }

        $allowReplacement =
            $null -eq $windowTiming -or $now -lt $measurementEndUtc
        Complete-SustainedExitedRuns -AllowReplacement $allowReplacement
        Save-SustainedLiveRuns
        if ($stopSubmissions) {
            break
        }

        $now = [DateTimeOffset]::UtcNow
        $traceCheckRequired =
            ($now - $lastTraceCheckUtc).TotalSeconds -ge 1 -or
            ($null -ne $windowTiming -and
                $null -eq $injectedRun -and $now -ge $injectionDueUtc)
        $liveTrace = $null
        if ($traceCheckRequired) {
            $liveTrace = Get-SustainedLiveTrace
            $lastTraceCheckUtc = $now
        }
        if ($null -eq $windowTiming -and $null -ne $liveTrace) {
            $runRecords = @(
                $allRuns |
                    ForEach-Object {
                        ConvertTo-RunRecord -Run $_
                    }
            )
            $lastOnsetEvidence = Test-SustainedWindowOnset `
                -Trace $liveTrace `
                -RunRecords $runRecords `
                -InitialNormalCompletionCount $initialNormalCompletionCount `
                -NowUtc $now
            $controller.LastOnsetEvidence = $lastOnsetEvidence
            if ($lastOnsetEvidence.Accepted) {
                $measurementStartUtc = $now.ToUniversalTime()
                $windowTiming = Get-SustainedWindowTiming `
                    -OnsetUtc $measurementStartUtc
                $injectionDueUtc = ConvertTo-UtcDateTimeOffset `
                    -Value $windowTiming.InjectionDueUtc
                $measurementEndUtc = ConvertTo-UtcDateTimeOffset `
                    -Value $windowTiming.SubmissionStopUtc
                $nextWindowSampleUtc = $measurementStartUtc
                $controller.MeasurementStartUtc =
                    $measurementStartUtc.ToString('O')
                $controller.MeasurementEndUtc =
                    $measurementEndUtc.ToString('O')
                $controller.InjectionDueUtc =
                    $injectionDueUtc.ToString('O')
                Add-SustainedControllerEvent `
                    -Event 'SteadyOnset' `
                    -Run $null `
                    -Data ([ordered]@{
                        InitialNormalCompletionCount =
                            $lastOnsetEvidence.InitialNormalCompletionCount
                        DeferredGrantOccurred =
                            $lastOnsetEvidence.DeferredGrantOccurred
                        ActiveNormalCount =
                            $lastOnsetEvidence.ActiveNormalCount
                        WaitingNormalCount =
                            $lastOnsetEvidence.WaitingNormalCount
                        QueueDepth = $lastOnsetEvidence.QueueDepth
                        QueueNonemptyContinuousSeconds =
                            $lastOnsetEvidence.QueueNonemptyContinuousSeconds
                        QueueNonemptyContinuousStartUtc =
                            $lastOnsetEvidence.QueueNonemptyContinuousStartUtc
                    })
            }
        }

        if ($null -ne $windowTiming -and
            $null -ne $liveTrace -and
            $now -lt $measurementEndUtc -and
            $now -ge $nextWindowSampleUtc) {
            $runRecords = @(
                $allRuns |
                    ForEach-Object {
                        ConvertTo-RunRecord -Run $_
                    }
            )
            $state = Get-SustainedInjectionState `
                -Trace $liveTrace `
                -RunRecords $runRecords
            $windowSamples.Add([pscustomobject][ordered]@{
                TimestampUtc = $now.ToUniversalTime().ToString('O')
                OffsetSeconds =
                    ($now.ToUniversalTime() - $measurementStartUtc).TotalSeconds
                QueueDepth = $state.QueueDepth
                ActiveBuilds = $state.ActiveBuilds
                AllocatedNodes = $state.AllocatedNodes
                ActiveNormalCount = $state.ActiveNormalCount
                WaitingNormalCount = $state.WaitingNormalCount
            })
            $nextWindowSampleUtc = $now.AddSeconds(1)
        }

        if ($null -ne $windowTiming -and
            $null -eq $injectedRun -and
            $now -ge $injectionDueUtc -and
            $null -ne $liveTrace) {
            $runRecords = @(
                $allRuns |
                    ForEach-Object {
                        ConvertTo-RunRecord -Run $_
                    }
            )
            $injectionState = Get-SustainedInjectionState `
                -Trace $liveTrace `
                -RunRecords $runRecords
            $controller.InjectionState = $injectionState
            $injectedWorktree =
                Get-PreparedSustainedWorktree -Name injected
            $touch = Touch-CampaignInput `
                -Worktree $injectedWorktree `
                -RelativePath $repository.TouchPath
            $injectedRun = Start-ScenarioBuild `
                -Bootstrap $bootstrap `
                -Repository $repository `
                -Worktree $injectedWorktree `
                -Condition $Condition `
                -PipeName $pipeName `
                -DebugPath $debugPath `
                -ScenarioRoot $ScenarioRoot `
                -RunId 'injected-g1' `
                -Kind injected `
                -Worker 0 `
                -Generation 1 `
                -ScenarioStartedUtc $scenarioStartedUtc `
                -Injected
            $allRuns.Add($injectedRun)
            $actualOffset =
                ($injectedRun.ProcessStartUtc - $measurementStartUtc).TotalSeconds
            $controller.InjectionStartedUtc =
                $injectedRun.ProcessStartUtc.ToString('O')
            $controller.InjectionActualOffsetSeconds = $actualOffset
            Add-SustainedControllerEvent `
                -Event 'Injected' `
                -Run $injectedRun `
                -Data ([ordered]@{
                    ScheduledUtc = $injectionDueUtc.ToString('O')
                    ActualOffsetSeconds = $actualOffset
                    TouchUtc = $touch.TouchedUtc
                    ProcessStartUtc = $injectedRun.ProcessStartUtc.ToString('O')
                    Priority = $injectedRun.Priority
                    ActiveNormalCount = $injectionState.ActiveNormalCount
                    WaitingNormalCount = $injectionState.WaitingNormalCount
                    QueueDepth = $injectionState.QueueDepth
                    AllocatedNodes = $injectionState.AllocatedNodes
                })
        }

        $now = [DateTimeOffset]::UtcNow
        if ($null -ne $windowTiming -and $now -ge $measurementEndUtc) {
            $stopSubmissions = $true
            $controller.SubmissionStopObservedUtc = $now.ToString('O')
            $controller.SubmissionStopActualOffsetSeconds =
                [double]$validity.MeasuredWindowSeconds
            $controller.SubmissionStopObservedOffsetSeconds =
                ($now - $measurementStartUtc).TotalSeconds
            Add-SustainedControllerEvent `
                -Event 'SubmissionStopped' `
                -Run $null `
                -Data ([ordered]@{
                    ScheduledUtc = $measurementEndUtc.ToString('O')
                    ActualOffsetSeconds =
                        $controller.SubmissionStopActualOffsetSeconds
                    ObservedOffsetSeconds =
                        $controller.SubmissionStopObservedOffsetSeconds
                    FixedWindowSeconds = $validity.MeasuredWindowSeconds
                })
            $stopEventWritten = $true
            break
        }
        if ($null -eq $windowTiming -and $now -ge $onsetDeadlineUtc) {
            $queueCriterionPassed =
                $null -ne $lastOnsetEvidence -and
                [double]$lastOnsetEvidence.QueueNonemptyContinuousSeconds -ge
                    [double]$validity.OnsetQueueContinuousSeconds -and
                [int]$lastOnsetEvidence.WaitingNormalCount -ge 1 -and
                [bool]$lastOnsetEvidence.DeferredGrantOccurred
            $sizingEvidenceAvailable =
                $null -ne $lastOnsetEvidence -and
                [bool]$lastOnsetEvidence.TraceConsistent -and
                [int]$lastOnsetEvidence.InitialNormalCompletionCount -ge 1 -and
                [int]$lastOnsetEvidence.ActiveNormalCount -ge 1
            if ($sizingEvidenceAvailable -and
                -not $queueCriterionPassed) {
                $controller.WorkerSizingResponse =
                    Get-SustainedWorkerSizingResponse `
                        -WorkerCount $WorkerCount `
                        -QueueCriterionPassed $false
                Add-SustainedControllerEvent `
                    -Event $controller.WorkerSizingResponse.Status `
                    -Run $null `
                    -Data ([ordered]@{
                        WorkerCount = $WorkerCount
                        NextWorkerCount =
                            $controller.WorkerSizingResponse.NextWorkerCount
                        RerunAllPilots =
                            $controller.WorkerSizingResponse.RerunAllPilots
                        QueueNonemptyTimeFraction =
                            $window.QueueNonemptyFraction
                        QueueNonemptySampleFraction =
                            $sampleSummary.QueueNonemptySampleFraction
                    })
                Add-SustainedControllerEvent `
                    -Event $controller.WorkerSizingResponse.Status `
                    -Run $null `
                    -Data ([ordered]@{
                        WorkerCount = $WorkerCount
                        NextWorkerCount =
                            $controller.WorkerSizingResponse.NextWorkerCount
                        RerunAllPilots =
                            $controller.WorkerSizingResponse.RerunAllPilots
                        LastOnsetEvidence = $lastOnsetEvidence
                    })
            }
            else {
                $controller.WorkerSizingResponse =
                    [pscustomobject][ordered]@{
                        Status = 'OnsetEvidenceFailed'
                        WorkerCount = $WorkerCount
                        FrozenWorkerCount = $null
                        NextWorkerCount = $null
                        RerunAllPilots = $false
                    }
                Add-SustainedControllerEvent `
                    -Event 'OnsetEvidenceFailed' `
                    -Run $null `
                    -Data ([ordered]@{
                        LastOnsetEvidence = $lastOnsetEvidence
                    })
            }
            $stopSubmissions = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }

    $controller.InitialNormalCompletionCount =
        $initialNormalCompletionCount
    $drainStartedUtc = [DateTimeOffset]::UtcNow
    while (@($allRuns | Where-Object { -not $_.Completed }).Count -gt 0) {
        $now = [DateTimeOffset]::UtcNow
        if ($HardDeadlineUtc -ne [DateTimeOffset]::MaxValue -and
            $now -ge $HardDeadlineUtc.ToUniversalTime()) {
            $controller.HardDeadlineExceeded = $true
            break
        }
        if (($now - $drainStartedUtc).TotalMinutes -gt
            [double]$validity.DrainTimeoutMinutes) {
            $controller.DrainTimedOut = $true
            break
        }
        if (($now - $lastProcessTreeSampleUtc).TotalSeconds -ge 1) {
            Update-ScenarioProcessTrees -Runs $allRuns.ToArray()
            $lastProcessTreeSampleUtc = $now
        }
        Complete-SustainedExitedRuns -AllowReplacement $false
        Save-SustainedLiveRuns
        Start-Sleep -Milliseconds 100
    }
    $controller.DrainCompleted =
        @($allRuns | Where-Object { -not $_.Completed }).Count -eq 0
    if ($controller.DrainCompleted) {
        Add-SustainedControllerEvent -Event 'DrainCompleted' -Run $null
    }
}
catch {
    $executionErrors.Add($_.Exception.ToString())
    $metadata['ExecutionError'] = $_.Exception.ToString()
}
finally {
    try {
        $cleanup = Stop-UnfinishedScenarioBuilds -Runs $allRuns.ToArray()
        $metadata['BuildCleanup'] = $cleanup
        if (-not $cleanup.Succeeded) {
            $executionErrors.Add(
                "Build cleanup failed: $($cleanup.Errors -join '; ')")
        }
    }
    catch {
        $executionErrors.Add(
            "Build cleanup threw: $($_.Exception.ToString())")
        $metadata['BuildCleanupError'] = $_.Exception.ToString()
    }
    try {
        Save-SustainedLiveRuns
    }
    catch {
        $executionErrors.Add(
            "Run persistence failed: $($_.Exception.ToString())")
    }
    if ($null -ne $monitor) {
        try {
            Stop-ScenarioMonitor -Monitor $monitor
            $metadata['MonitorReadyObservedUtc'] =
                $monitor.ReadyObservedUtc.ToString('O')
            $metadata['MonitorStopRequestedUtc'] =
                $monitor.StopRequestedUtc.ToString('O')
            $metadata['MonitorProcessExitObservedUtc'] =
                $monitor.ProcessExitObservedUtc.ToString('O')
        }
        catch {
            $executionErrors.Add(
                "Monitor cleanup failed: $($_.Exception.ToString())")
            $metadata['MonitorStopError'] = $_.Exception.ToString()
        }
    }
    try {
        Invoke-BuildServerShutdown `
            -Bootstraps @($base, $final) `
            -JournalPath $journal `
            -OutputDirectory $commandOutput
    }
    catch {
        $executionErrors.Add(
            "Build-server shutdown failed: $($_.Exception.ToString())")
        $metadata['BuildServerShutdownError'] = $_.Exception.ToString()
    }
    $metadata['CompletedUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    Write-JsonAtomic `
        -Path (Join-Path $ScenarioRoot 'controller-summary.json') `
        -Value ([pscustomobject]$controller) `
        -Depth 12
}

$runRecords = @(
    foreach ($run in $allRuns) {
        $record = ConvertTo-RunRecord -Run $run
        $record | Add-Member `
            -NotePropertyName CurrentJobProcessIds `
            -NotePropertyValue @($run.CurrentJobProcessIds)
        $record | Add-Member `
            -NotePropertyName CurrentNonCoordinatorJobProcessIds `
            -NotePropertyValue @($run.CurrentNonCoordinatorJobProcessIds)
        $record
    }
)
$runRecords |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $ScenarioRoot 'runs.csv')
Write-JsonAtomic `
    -Path (Join-Path $ScenarioRoot 'runs.json') `
    -Value $runRecords `
    -Depth 9
$windowSamples |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $ScenarioRoot 'window-samples.csv')
Write-JsonAtomic `
    -Path (Join-Path $ScenarioRoot 'window-samples.json') `
    -Value $windowSamples.ToArray() `
    -Depth 6

$harnessErrors = [Collections.Generic.List[string]]::new()
$externalErrors = [Collections.Generic.List[string]]::new()
$policyFailures = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
foreach ($message in $executionErrors) {
    $harnessErrors.Add($message)
}
if ($null -ne $cleanup -and -not $cleanup.Succeeded) {
    foreach ($message in $cleanup.Errors) {
        $harnessErrors.Add([string]$message)
    }
}
foreach ($run in $runRecords) {
    if ([int]$run.RootProcessId -le 0) {
        $harnessErrors.Add("Run '$($run.RunId)' has no valid root PID.")
    }
    try {
        $start = ConvertTo-UtcDateTimeOffset -Value $run.ProcessStartUtc
        $exit = ConvertTo-UtcDateTimeOffset -Value $run.ProcessExitUtc
        if ($exit -lt $start) {
            $harnessErrors.Add("Run '$($run.RunId)' exited before it started.")
        }
    }
    catch {
        $harnessErrors.Add("Run '$($run.RunId)' has invalid start/exit timestamps.")
    }
    if ($run.ExitCode -ne 0) {
        $policyFailures.Add(
            "Build '$($run.RunId)' exited with code $($run.ExitCode).")
    }
    if (-not $run.Quiescent) {
        $harnessErrors.Add(
            "Build '$($run.RunId)' did not reach corrected current-membership quiescence.")
    }
    if ($run.JobCensusFailed -or
        @($run.CurrentNonCoordinatorJobProcessIds).Count -ne 0) {
        $harnessErrors.Add(
            "Build '$($run.RunId)' retained current non-Coordinator Job membership or a failed census.")
    }
    if (-not $run.TrackingJobClosed) {
        $harnessErrors.Add(
            "Build '$($run.RunId)' tracking Job was not closed after drain.")
    }
    if (-not (Test-Path -LiteralPath $run.Binlog -PathType Leaf) -or
        (Get-Item -LiteralPath $run.Binlog).Length -eq 0) {
        $harnessErrors.Add(
            "Build '$($run.RunId)' has a missing or empty binlog.")
    }
    if (-not (Test-Path -LiteralPath $run.Stdout -PathType Leaf) -or
        -not (Test-Path -LiteralPath $run.Stderr -PathType Leaf)) {
        $harnessErrors.Add(
            "Build '$($run.RunId)' is missing stdout/stderr evidence.")
    }
    elseif (-not [string]::IsNullOrWhiteSpace(
        (Get-Content -LiteralPath $run.Stderr -Raw))) {
        if ($run.ExitCode -ne 0) {
            $policyFailures.Add(
                "Build '$($run.RunId)' wrote stderr with tested-condition failure.")
        }
        else {
            $harnessErrors.Add(
                "Successful build '$($run.RunId)' has nonempty stderr.")
        }
    }
    try {
        $runEnvironment = @(
            Get-Content -LiteralPath $run.EnvironmentPath -Raw |
                ConvertFrom-Json)
        $runDebugEnabled = Get-SustainedEnvironmentValue `
            -EnvironmentRecord $runEnvironment `
            -Name 'MSBUILDDEBUGCOMM'
        $runDebugPath = Get-SustainedEnvironmentValue `
            -EnvironmentRecord $runEnvironment `
            -Name 'MSBUILDDEBUGPATH'
        $runPipe = Get-SustainedEnvironmentValue `
            -EnvironmentRecord $runEnvironment `
            -Name 'MSBUILDCOORDINATORPIPENAME'
        $runPriority = Get-SustainedEnvironmentValue `
            -EnvironmentRecord $runEnvironment `
            -Name 'MSBUILDCOORDINATORBUILDREQUESTPRIORITY'
        $expectedRunPriority = if ($Condition -eq 'BASE') {
            $null
        }
        elseif ($Condition -eq 'FINAL-H' -and
            $run.Kind -eq 'injected') {
            'High'
        }
        else {
            'Normal'
        }
        if ($runDebugEnabled -ne '1' -or
            $runDebugPath -ne $debugPath -or
            $runPipe -ne $pipeName -or
            $runPriority -ne $expectedRunPriority) {
            $harnessErrors.Add(
                "Build '$($run.RunId)' environment does not preserve identical debug/pipe settings and exact priority encoding.")
        }
    }
    catch {
        $harnessErrors.Add(
            "Build '$($run.RunId)' environment evidence is invalid: $($_.Exception.Message)")
    }
}

$telemetry = $null
if ($null -ne $monitor -and
    $null -ne $monitor.ReadyObservedUtc -and
    $null -ne $monitor.StopRequestedUtc) {
    try {
        $telemetry = Test-TelemetryContinuity `
            -MonitorRoot $monitorRoot `
            -ReadyUtc $monitor.ReadyObservedUtc `
            -StopUtc $monitor.StopRequestedUtc
        foreach ($message in $telemetry.Errors) {
            $externalErrors.Add([string]$message)
        }
        foreach ($message in $telemetry.Warnings) {
            $warnings.Add([string]$message)
        }
    }
    catch {
        $harnessErrors.Add(
            "Telemetry continuity validation failed: $($_.Exception.Message)")
    }
}
else {
    $harnessErrors.Add('Scenario monitor did not record ready/stop identities.')
}

$traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
$trace = $null
$replays = @()
$grantMetrics = [Collections.Generic.List[object]]::new()
if ($traceFiles.Count -ne 1) {
    $harnessErrors.Add(
        "Expected exactly one Coordinator server trace; found $($traceFiles.Count).")
}
elseif ($runRecords.Count -gt 0 -and
    @($runRecords | Where-Object {
        -not (Test-Path -LiteralPath $_.Binlog -PathType Leaf)
    }).Count -eq 0) {
    try {
        $replays = @(
            & (Join-Path $parentToolingRoot 'Invoke-GrantReplay.ps1') `
                -BootstrapRoot $bootstrap.Root `
                -Binlog @($runRecords.Binlog) `
                -OutputPath (
                    Join-Path $ScenarioRoot 'grant-replay.json') `
                -WorkRoot (Join-Path $ScenarioRoot '_tooling') `
                -JournalPath $journal
        )
        $trace = ConvertFrom-CoordinatorTrace `
            -TracePaths $traceFiles `
            -RunRecords $runRecords `
            -Budget $campaign.NodeBudget `
            -RequireEmptyFinalState `
            -StrictParsing
        [void](Export-CoordinatorTraceResult `
            -Trace $trace `
            -DestinationRoot (
                Join-Path $ScenarioRoot 'parsed-trace'))
        if (-not $trace.Consistent) {
            foreach ($message in $trace.Errors) {
                $harnessErrors.Add([string]$message)
            }
        }
        foreach ($run in $runRecords) {
            $replay = $replays |
                Where-Object {
                    [IO.Path]::GetFullPath($_.Path) -eq
                        [IO.Path]::GetFullPath($run.Binlog)
                } |
                Select-Object -First 1
            $traceState = $trace.RootStates |
                Where-Object RunId -eq $run.RunId |
                Select-Object -First 1
            if ($null -eq $replay -or @($replay.Grants).Count -ne 1) {
                $harnessErrors.Add(
                    "Build '$($run.RunId)' does not have exactly one replayed actual grant.")
                continue
            }
            if ($null -eq $traceState -or
                $null -eq $traceState.GrantedUtc) {
                $harnessErrors.Add(
                    "Build '$($run.RunId)' has no trace grant mapped by PID/start identity.")
                continue
            }
            $metric = Get-GrantMetricsForRun `
                -Run $run `
                -Replay $replay `
                -TraceState $traceState
            if ($metric.GrantedNodes -ne
                [int]$traceState.GrantedNodes) {
                $harnessErrors.Add(
                    "Build '$($run.RunId)' replay/trace grants differ.")
            }
            if ($metric.TraceAndBinlogGrantDeltaSeconds -gt
                [double]$validity.GrantTimestampCrossCheckMaximumSeconds) {
                $harnessErrors.Add(
                    "Build '$($run.RunId)' replay/trace timestamps differ by $($metric.TraceAndBinlogGrantDeltaSeconds) seconds.")
            }
            $grantMetrics.Add($metric)
        }
    }
    catch {
        $harnessErrors.Add(
            "Grant replay or strict trace validation failed: $($_.Exception.Message)")
    }
}

$events = @(
    if (Test-Path -LiteralPath $eventPath -PathType Leaf) {
        Get-Content -LiteralPath $eventPath |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } |
            ForEach-Object {
                $_ | ConvertFrom-Json
            }
    }
)
$completeWindowRequired =
    $null -eq $controller.WorkerSizingResponse -and
    -not $controller.HardDeadlineExceeded
$controllerValidation = Test-SustainedWindowControllerEvents `
    -Events $events `
    -InitialWorkers $WorkerCount `
    -RequireCompleteWindow $completeWindowRequired
if (-not $controllerValidation.Valid) {
    foreach ($message in $controllerValidation.Errors) {
        $harnessErrors.Add([string]$message)
    }
}

$scenarioEndUtc = if ($runRecords.Count -eq 0) {
    [DateTimeOffset]::UtcNow
}
else {
    @(
        $runRecords |
            ForEach-Object {
                ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc
            } |
            Sort-Object |
            Select-Object -Last 1
    )[0]
}
$metrics = [ordered]@{
    SchemaVersion = 1
    Shape = 'sustained'
    FixedWindowMode = $true
    Repository = $RepositoryName
    Condition = $Condition
    WorkerCount = $WorkerCount
    BlockNumber = $BlockNumber
    AnalysisBlockNumber = $AnalysisBlockNumber
    IsWarmup = $IsWarmup
    AttemptNumber = $AttemptNumber
    OrderIndex = $OrderIndex
    RunIdentity = $RunIdentity
    ScenarioStartUtc = if ($scenarioStartedUtc -eq
        [DateTimeOffset]::MinValue) {
        $null
    }
    else {
        $scenarioStartedUtc.ToString('O')
    }
    ScenarioEndUtc = $scenarioEndUtc.ToString('O')
    TotalWallSeconds = if ($scenarioStartedUtc -eq
        [DateTimeOffset]::MinValue) {
        0.0
    }
    else {
        ($scenarioEndUtc - $scenarioStartedUtc).TotalSeconds
    }
    RunCount = $runRecords.Count
    FailedRunCount =
        @($runRecords | Where-Object ExitCode -ne 0).Count
    ActualGrantCount = $grantMetrics.Count
    ProbeExcludedFromNormalThroughput = $true
    OldTwelveCompletionTenMinuteGateApplied = $false
    WorkloadKind = 'representative-propagated-project'
    WorkloadDeviation = $campaign.WorkloadDeviation
}

$policyEvidence = $null
$queueWindowCriterionFailed = $false
if ($null -ne $trace -and $null -ne $windowTiming -and
    $null -ne $injectedRun) {
    $policyEvidence = Test-SustainedGrantPolicyEvidence `
        -Condition $Condition `
        -RunRecords $runRecords `
        -GrantMetrics $grantMetrics.ToArray() `
        -Trace $trace
    $metrics['GrantPolicyEvidence'] = $policyEvidence
    if (-not $policyEvidence.Valid) {
        foreach ($message in $policyEvidence.Errors) {
            $externalErrors.Add([string]$message)
        }
    }
}

if ($null -ne $trace -and $null -ne $windowTiming) {
    $window = Get-TraceWindowMetrics `
        -Timeline $trace.Timeline `
        -StartUtc $measurementStartUtc `
        -EndUtc $measurementEndUtc `
        -Budget $campaign.NodeBudget `
        -ReservedNodes 0
    $sampleSummary = Get-SustainedWindowSampleSummary `
        -Samples $windowSamples.ToArray()
    $sampleCoverageFraction =
        [double]$sampleSummary.SampleCount /
        [double]$validity.MeasuredWindowSeconds
    $completedNormals = @(
        $runRecords |
            Where-Object {
                $_.Kind -eq 'normal' -and
                $_.ExitCode -eq 0 -and
                $_.Quiescent -and
                (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -ge
                    $measurementStartUtc -and
                (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -lt
                    $measurementEndUtc
            }
    )
    $preInjectionNormals = @(
        $completedNormals |
            Where-Object {
                (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -lt
                    $injectionDueUtc
            }
    )
    $postInjectionNormals = @(
        $completedNormals |
            Where-Object {
                (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -ge
                    $injectionDueUtc
            }
    )
    $rightCensored = @(
        $runRecords |
            Where-Object {
                $_.Kind -eq 'normal' -and
                (ConvertTo-UtcDateTimeOffset -Value $_.ProcessStartUtc) -lt
                    $measurementEndUtc -and
                (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -ge
                    $measurementEndUtc
            }
    )
    $steadyResource = $null
    try {
        $steadyResource = Get-ScenarioResourceMetrics `
            -MonitorRoot $monitorRoot `
            -RunRecords $runRecords `
            -WindowStartUtc $measurementStartUtc `
            -WindowEndUtc $measurementEndUtc
        if ($steadyResource.SystemSampleCount -lt 2) {
            $externalErrors.Add(
                'Measured window has fewer than two system telemetry samples.')
        }
        if ($steadyResource.ForeignConflictingProcessCount -gt 0) {
            $externalErrors.Add(
                "Measured window found $($steadyResource.ForeignConflictingProcessCount) foreign build/compiler identities.")
        }
        $noiseFraction =
            $steadyResource.KnownExternalNoiseCpuSeconds /
            ($validity.MeasuredWindowSeconds *
                [Environment]::ProcessorCount)
        if ($noiseFraction -gt
            [double]$validity.MaxKnownExternalNoiseCpuCoreFraction) {
            $externalErrors.Add(
                "Known external-noise CPU fraction $noiseFraction exceeded $($validity.MaxKnownExternalNoiseCpuCoreFraction).")
        }
        if ($steadyResource.PeakKnownExternalNoiseWorkingSetBytes -gt
            [int64]$validity.MaxKnownExternalNoiseWorkingSetBytes) {
            $externalErrors.Add(
                'Known external-noise working set exceeded the campaign limit.')
        }
        $metrics['KnownExternalNoiseCpuCoreFraction'] = $noiseFraction
    }
    catch {
        $harnessErrors.Add(
            "Measured resource extraction failed: $($_.Exception.Message)")
    }

    $injectedMetric = $grantMetrics |
        Where-Object RunId -eq 'injected-g1' |
        Select-Object -First 1
    $metrics['MeasurementStartUtc'] = $measurementStartUtc.ToString('O')
    $metrics['MeasurementEndUtc'] = $measurementEndUtc.ToString('O')
    $metrics['MeasuredWindowSeconds'] = $window.WindowSeconds
    $metrics['FixedInjectionOffsetSeconds'] =
        $validity.InjectionOffsetSeconds
    $metrics['InjectionActualOffsetSeconds'] =
        $controller.InjectionActualOffsetSeconds
    $metrics['SubmissionStopEffectiveOffsetSeconds'] =
        $controller.SubmissionStopActualOffsetSeconds
    $metrics['SubmissionStopObservedOffsetSeconds'] =
        $controller.SubmissionStopObservedOffsetSeconds
    $metrics['InjectionState'] = $controller.InjectionState
    $metrics['MeasuredNormalCompletionCount'] = $completedNormals.Count
    $metrics['MeasuredNormalCompletionRunIds'] =
        @($completedNormals.RunId)
    $metrics['PreInjectionNormalCompletionCount'] =
        $preInjectionNormals.Count
    $metrics['PostInjectionNormalCompletionCount'] =
        $postInjectionNormals.Count
    $metrics['OverallNormalThroughputPerSecond'] =
        [double]$completedNormals.Count /
        [double]$validity.MeasuredWindowSeconds
    $metrics['PreInjectionNormalThroughputPerSecond'] =
        [double]$preInjectionNormals.Count /
        [double]$validity.InjectionOffsetSeconds
    $metrics['PostInjectionNormalThroughputPerSecond'] =
        [double]$postInjectionNormals.Count /
        ([double]$validity.MeasuredWindowSeconds -
            [double]$validity.InjectionOffsetSeconds)
    $metrics['AverageCompletedNormalLatencySeconds'] =
        if ($completedNormals.Count -eq 0) {
            $null
        }
        else {
            ($completedNormals |
                Measure-Object DurationSeconds -Average).Average
        }
    $metrics['InjectedRequestToGrantSeconds'] =
        if ($null -eq $injectedMetric) {
            $null
        }
        else {
            $injectedMetric.RequestToGrantSeconds
        }
    $metrics['InjectedRequestToCompletionSeconds'] =
        if ($null -eq $injectedMetric) {
            $null
        }
        else {
            $injectedMetric.RequestToCompletionSeconds
        }
    $metrics['QueueDepthP50'] = $window.QueueDepthP50
    $metrics['QueueDepthP95'] = $window.QueueDepthP95
    $metrics['QueueDepthMaximum'] = $window.QueueDepthMaximum
    $metrics['QueueNonemptySeconds'] = $window.QueueNonemptySeconds
    $metrics['QueueNonemptyTimeFraction'] =
        $window.QueueNonemptyFraction
    $metrics['QueueNonemptySampleFraction'] =
        $sampleSummary.QueueNonemptySampleFraction
    $metrics['WindowSampleCount'] = $sampleSummary.SampleCount
    $metrics['WindowSampleCoverageFraction'] = $sampleCoverageFraction
    $metrics['ActiveAndWaitingSampleCount'] =
        $sampleSummary.ActiveAndWaitingSampleCount
    $metrics['UnusedNodeSeconds'] = $window.UnusedNodeSeconds
    $metrics['RightCensoredNormalCount'] = $rightCensored.Count
    $metrics['RampSeconds'] =
        ($measurementStartUtc - $scenarioStartedUtc).TotalSeconds
    $metrics['DrainSeconds'] =
        ($scenarioEndUtc - $measurementEndUtc).TotalSeconds
    $metrics['SteadyResource'] = $steadyResource
    $metrics['GrantSequence'] = @(
        $grantMetrics |
            Sort-Object GrantTimestampUtc |
            Select-Object RunId,GrantedNodes,GrantTimestampUtc
    )

    if ([Math]::Abs(
        [double]$window.WindowSeconds -
        [double]$validity.MeasuredWindowSeconds) -gt 0.001) {
        $harnessErrors.Add('Measured trace window is not exactly eight minutes.')
    }
    $lateNormalLaunches = @(
        $runRecords |
            Where-Object {
                $_.Kind -eq 'normal' -and
                (ConvertTo-UtcDateTimeOffset -Value $_.ProcessStartUtc) -ge
                    $measurementEndUtc
            }
    )
    if ($lateNormalLaunches.Count -gt 0) {
        $harnessErrors.Add(
            "Found $($lateNormalLaunches.Count) Normal submission(s) after the fixed minute-eight stop.")
    }
    if ($null -eq $injectedRun) {
        $externalErrors.Add('Fixed minute-four probe was not injected.')
    }
    elseif ([Math]::Abs(
        [double]$controller.InjectionActualOffsetSeconds -
        [double]$validity.InjectionOffsetSeconds) -gt
        [double]$validity.InjectionTimingToleranceSeconds) {
        $externalErrors.Add(
            'Probe injection missed fixed minute four beyond tolerance.')
    }
    if ($null -eq $controller.InjectionState -or
        -not [bool]$controller.InjectionState.Valid) {
        $externalErrors.Add(
            'Probe injection did not have at least one active and one waiting Normal request.')
    }
    if ($completedNormals.Count -lt
        [int]$validity.MinimumMeasuredNormalCompletions) {
        $externalErrors.Add(
            "Fixed window completed $($completedNormals.Count) Normal builds; at least $($validity.MinimumMeasuredNormalCompletions) is required for throughput.")
    }
    if ($preInjectionNormals.Count -lt
            [int]$validity.MinimumNormalCompletionsPerHalf -or
        $postInjectionNormals.Count -lt
            [int]$validity.MinimumNormalCompletionsPerHalf) {
        $externalErrors.Add(
            "Fixed window completed $($preInjectionNormals.Count)/$($postInjectionNormals.Count) Normal builds before/after injection; at least $($validity.MinimumNormalCompletionsPerHalf) in each half is required for paired throughput metrics.")
    }
    if ($window.QueueNonemptyFraction -lt
        [double]$validity.QueueNonemptyFractionMinimum) {
        $queueWindowCriterionFailed = $true
        $externalErrors.Add(
            "Queue was nonempty for $($window.QueueNonemptyFraction) of trace time; required $($validity.QueueNonemptyFractionMinimum).")
    }
    if ($sampleSummary.QueueNonemptySampleFraction -lt
        [double]$validity.QueueNonemptyFractionMinimum) {
        $queueWindowCriterionFailed = $true
        $externalErrors.Add(
            "Queue was nonempty for $($sampleSummary.QueueNonemptySampleFraction) of controller samples; required $($validity.QueueNonemptyFractionMinimum).")
    }
    if ($sampleCoverageFraction -lt
        [double]$validity.QueueNonemptyFractionMinimum) {
        $externalErrors.Add(
            "Window sample coverage was $sampleCoverageFraction; required at least $($validity.QueueNonemptyFractionMinimum).")
    }
    if (-not $controller.DrainCompleted -or $controller.DrainTimedOut) {
        $harnessErrors.Add('Scenario did not completely drain after stopping submissions.')
    }
}

if ($Pilot -and
    $queueWindowCriterionFailed -and
    $null -eq $controller.WorkerSizingResponse) {
    $controller.WorkerSizingResponse =
        Get-SustainedWorkerSizingResponse `
            -WorkerCount $WorkerCount `
            -QueueCriterionPassed $false
    Write-JsonAtomic `
        -Path (Join-Path $ScenarioRoot 'controller-summary.json') `
        -Value ([pscustomobject]$controller) `
        -Depth 12
}

foreach ($worktree in $selectedWorktrees) {
    try {
        [void](Get-GitIdentity `
            -Root $worktree.Path `
            -ExpectedCommit $repository.Commit `
            -RequireClean)
        $tracked = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('-C', $worktree.Path, 'ls-files') `
                -WorkingDirectory $worktree.Path
        )
        $currentOutput = Get-ProjectOutputContentIdentity `
            -Worktree $worktree.Path `
            -TrackedRelativePaths $tracked
        $status = Test-GitStatusWithinProjectOutputs `
            -Worktree $worktree.Path `
            -OutputDirectories @($currentOutput.OutputDirectories)
        if (-not $status.Valid) {
            $harnessErrors.Add(
                "Worktree '$($worktree.Name)' has ignored or untracked state outside explicit project output roots.")
        }
    }
    catch {
        $harnessErrors.Add($_.Exception.Message)
    }
}

Write-JsonAtomic `
    -Path (Join-Path $ScenarioRoot 'scenario-metrics.json') `
    -Value ([pscustomobject]$metrics) `
    -Depth 14

$workerSizingStatus = if ($null -eq $controller.WorkerSizingResponse) {
    $null
}
else {
    [string]$controller.WorkerSizingResponse.Status
}
$nonRetryableCleanupFailure =
    $null -ne $cleanup -and -not $cleanup.Succeeded
$disposition = if ($controller.HardDeadlineExceeded) {
    'CampaignHardTimeout'
}
elseif ($nonRetryableCleanupFailure) {
    'NonRetryableHarnessFailure'
}
elseif ($policyFailures.Count -gt 0) {
    'TestedConditionPolicyOutcome'
}
elseif ($harnessErrors.Count -gt 0) {
    'InvalidRetryable'
}
elseif ($workerSizingStatus -eq 'WorkerCountIncreaseRequired') {
    'WorkerCountIncreaseRequired'
}
elseif ($workerSizingStatus -eq
    'QueueCriterionFailedAtFrozenMaximum') {
    'QueueCriterionFailedAtFrozenMaximum'
}
elseif ($workerSizingStatus -eq 'OnsetEvidenceFailed') {
    'OnsetEvidenceFailed'
}
elseif ($externalErrors.Count -gt 0) {
    'InvalidRetryable'
}
else {
    'Valid'
}
$validation = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Shape = 'sustained'
    FixedWindowMode = $true
    Repository = $RepositoryName
    Condition = $Condition
    WorkerCount = $WorkerCount
    BlockNumber = $BlockNumber
    AnalysisBlockNumber = $AnalysisBlockNumber
    IsWarmup = $IsWarmup
    Pilot = [bool]$Pilot
    AttemptNumber = $AttemptNumber
    OrderIndex = $OrderIndex
    RunIdentity = $RunIdentity
    ValidForAnalysis = $disposition -eq 'Valid' -and -not $IsWarmup
    Valid = $disposition -eq 'Valid'
    RetryAllowed = $disposition -eq 'InvalidRetryable'
    Disposition = $disposition
    WorkerCountIncreaseRequired =
        $disposition -eq 'WorkerCountIncreaseRequired'
    WorkerSizingResponse = $controller.WorkerSizingResponse
    HardTimeoutHours = $campaign.HardTimeoutHours
    HardDeadlineExceeded = $controller.HardDeadlineExceeded
    OldTwelveCompletionTenMinuteGateApplied = $false
    Controller = $controllerValidation
    Telemetry = $telemetry
    Warnings = $warnings.ToArray()
    HarnessErrors = $harnessErrors.ToArray()
    ExternalValidityErrors = $externalErrors.ToArray()
    TestedConditionPolicyOutcomes = $policyFailures.ToArray()
}
Write-JsonAtomic `
    -Path (Join-Path $ScenarioRoot 'scenario-validation.json') `
    -Value $validation `
    -Depth 12
$metadata.Succeeded = $disposition -eq 'Valid'
$metadata['Disposition'] = $disposition
Write-JsonAtomic `
    -Path (Join-Path $ScenarioRoot 'scenario-metadata.json') `
    -Value ([pscustomobject]$metadata) `
    -Depth 12
Write-Host "SCENARIO_VALIDATION=$(Join-Path $ScenarioRoot 'scenario-validation.json')"
$validation
