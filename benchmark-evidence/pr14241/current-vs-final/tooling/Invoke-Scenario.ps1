[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$PreparationPath,
    [Parameter(Mandatory)]
    [ValidateSet('isolated', 'sustained')]
    [string]$Shape,
    [Parameter(Mandatory)]
    [ValidateSet('roslyn', 'aspire')]
    [string]$RepositoryName,
    [Parameter(Mandatory)]
    [ValidateSet('BASE', 'COMPAT', 'FINAL-N', 'FINAL-H')]
    [string]$Condition,
    [Parameter(Mandatory)]
    [int]$BlockNumber,
    [Parameter(Mandatory)]
    [int]$AttemptNumber,
    [Parameter(Mandatory)]
    [int]$OrderIndex,
    [int]$AnalysisBlockNumber = 0,
    [bool]$IsWarmup = $false,
    [string]$RunIdentity,
    [Parameter(Mandatory)]
    [string]$ScenarioRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Scenario.Common.ps1')
. (Join-Path $PSScriptRoot 'ControllerValidation.ps1')
Assert-WindowsCampaignHost

$campaign = Get-CampaignDefinition
$shapeDefinition = Get-ShapeDefinition -Key $Shape
if ($shapeDefinition.Conditions -notcontains $Condition) {
    throw "Condition '$Condition' is not part of '$Shape'."
}
if (Test-Path -LiteralPath $ScenarioRoot) {
    throw "Scenario root '$ScenarioRoot' already exists."
}
$expectedRunIdentity = New-ScenarioRunIdentity `
    -Shape $Shape `
    -Repository $RepositoryName `
    -Condition $Condition `
    -BlockNumber $BlockNumber `
    -AttemptNumber $AttemptNumber `
    -OrderIndex $OrderIndex
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
New-Item -ItemType Directory -Force -Path $debugPath | Out-Null

$identityRecord = Get-Content -LiteralPath $BootstrapIdentityPath -Raw | ConvertFrom-Json
$base = Get-BootstrapIdentity -Role base -Root $identityRecord.Base.Root -ExpectedCommit $campaign.Base.Commit
$final = Get-BootstrapIdentity -Role final -Root $identityRecord.Final.Root -ExpectedCommit $campaign.Final.Commit
$conditionDefinition = Get-ConditionDefinition -Key $Condition
$bootstrap = if ($conditionDefinition.BootstrapRole -eq 'base') { $base } else { $final }
$preparation = Get-Content -LiteralPath $PreparationPath -Raw | ConvertFrom-Json
$preparedRepository = $preparation.Repositories |
    Where-Object Name -eq $RepositoryName |
    Select-Object -First 1
if ($null -eq $preparedRepository) {
    throw "Preparation metadata does not contain '$RepositoryName'."
}
$repositoryDefinition = Get-RepositoryDefinition -Name $RepositoryName
$repository = [pscustomobject][ordered]@{
    Name = $RepositoryName
    Root = $preparedRepository.Repository.Root
    Commit = $repositoryDefinition.Commit
    WorkRoot = $preparedRepository.WorkRoot
    BuildPath = $preparedRepository.BuildPath
    TouchPath = $preparedRepository.TouchPath
    AdditionalBuildArguments = @($preparedRepository.AdditionalBuildArguments)
    Worktrees = @($preparedRepository.Worktrees)
}
if ($repository.Worktrees.Count -ne 19) {
    throw "$RepositoryName does not have exactly 19 prepared worktrees."
}

function Get-PreparedWorktree {
    param([string]$Name)

    $worktree = $repository.Worktrees | Where-Object Name -eq $Name | Select-Object -First 1
    if ($null -eq $worktree) {
        throw "Prepared worktree '$Name' is missing for '$RepositoryName'."
    }
    return $worktree.Path
}

function Save-LiveRuns {
    param([object[]]$Runs)

    $records = @($Runs | ForEach-Object { ConvertTo-RunRecord -Run $_ })
    Write-JsonAtomic -Path (Join-Path $ScenarioRoot 'runs-live.json') -Value $records -Depth 8
}

function Add-ControllerEvent {
    param(
        [string]$Event,
        [object]$Run,
        [hashtable]$Data = @{}
    )

    $entry = [ordered]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Event = $Event
        RunId = if ($null -eq $Run) { $null } else { $Run.RunId }
        Worker = if ($null -eq $Run) { $null } else { $Run.Worker }
        Generation = if ($null -eq $Run) { $null } else { $Run.Generation }
    }
    foreach ($item in $Data.GetEnumerator()) {
        $entry[$item.Key] = $item.Value
    }
    Add-CommandJournalEntry -JournalPath (Join-Path $ScenarioRoot 'controller-events.jsonl') -Entry ([pscustomobject]$entry)
}

Assert-FreeDiskSpace `
    -Path $repository.WorkRoot `
    -MinimumGiB $campaign.Validity.RawResultsReserveGiB `
    -RecordPath (Join-Path $ScenarioRoot 'disk-guard.json') | Out-Null
foreach ($worktree in $repository.Worktrees) {
    [void](Get-GitIdentity -Root $worktree.Path -ExpectedCommit $repository.Commit -RequireClean)
}
Invoke-BuildServerShutdown `
    -Bootstraps @($base, $final) `
    -JournalPath $journal `
    -OutputDirectory $commandOutput
Wait-ForMachineIdle `
    -RecordPath (Join-Path $ScenarioRoot 'idle-gate.json') `
    -MinimumAvailableMB $shapeDefinition.MinimumAvailableMB

$pipeName = "cvf-$Shape-$RepositoryName-b$BlockNumber-a$AttemptNumber-o$OrderIndex-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
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
Assert-ConditionEnvironmentContract -Condition $Condition -Environment $normalEnvironment
Assert-ConditionEnvironmentContract -Condition $Condition -Environment $injectedEnvironment -Injected
$metadata = [ordered]@{
    SchemaVersion = 2
    StartedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Shape = $Shape
    Repository = $RepositoryName
    RepositoryCommit = $repository.Commit
    Condition = $Condition
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
    NodeBudget = 16
    BuildArguments = New-BuildArguments `
        -MSBuildDllPath $bootstrap.MSBuildDllPath `
        -BuildPath $repository.BuildPath `
        -BinlogPath '<per-run>\build.binlog' `
        -AdditionalArguments $repository.AdditionalBuildArguments
    NormalEnvironment = Get-EnvironmentContractRecord -Environment $normalEnvironment
    InjectedEnvironment = Get-EnvironmentContractRecord -Environment $injectedEnvironment
    Succeeded = $false
}
Write-JsonAtomic -Path (Join-Path $ScenarioRoot 'scenario-metadata.json') -Value $metadata -Depth 10

$allRuns = [Collections.Generic.List[object]]::new()
$controller = [ordered]@{
    ScenarioStartedUtc = $null
    InjectionStartedUtc = $null
    InjectionOffsetSeconds = $null
    SteadyOnsetUtc = $null
    SemanticSaturationStartUtc = $null
    SemanticBridgedHandoffCount = 0
    SemanticHandoffGapToleranceSeconds = $campaign.Validity.SustainedHandoffGapToleranceSeconds
    SteadyEndUtc = $null
    MeasuredNormalCompletions = 0
    MeasuredCompletionRunIds = @()
    TimedOut = $false
    WorktreeOverlap = $false
    PolicyFailureRunIds = @()
}
$monitor = $null
$scenarioExceptions = [Collections.Generic.List[Exception]]::new()
$terminalOutcome = $null
try {
    $monitor = Start-ScenarioMonitor -MonitorRoot $monitorRoot
    if ($Shape -eq 'isolated') {
        [void](Touch-CampaignInput `
            -Worktree (Get-PreparedWorktree -Name 'normal1') `
            -RelativePath $repository.TouchPath)
    }
    elseif ($Shape -eq 'sustained') {
        foreach ($worker in 1..18) {
            [void](Touch-CampaignInput `
                -Worktree (Get-PreparedWorktree -Name "normal$worker") `
                -RelativePath $repository.TouchPath)
        }
    }
    $scenarioStartedUtc = [DateTimeOffset]::UtcNow
    $controller.ScenarioStartedUtc = $scenarioStartedUtc.ToString('O')
    Add-ControllerEvent -Event 'ScenarioStarted' -Run $null

    if ($Shape -eq 'isolated') {
        $worktree = Get-PreparedWorktree -Name 'normal1'
        $run = Start-ScenarioBuild `
            -Bootstrap $bootstrap `
            -Repository $repository `
            -Worktree $worktree `
            -Condition $Condition `
            -PipeName $pipeName `
            -DebugPath $debugPath `
            -ScenarioRoot $ScenarioRoot `
            -RunId 'normal1-g1' `
            -Kind normal `
            -Worker 1 `
            -Generation 1 `
            -ScenarioStartedUtc $scenarioStartedUtc
        $allRuns.Add($run)
        Add-ControllerEvent -Event 'Launched' -Run $run
        Wait-ScenarioBuilds -Runs $allRuns.ToArray()
        Add-ControllerEvent -Event 'Completed' -Run $run -Data @{
            ExitCode = $run.ExitCode
            Quiescent = $run.Quiescent
        }
        $run.CompletionEventWritten = $true
    }
    elseif ($Shape -eq 'sustained') {
        $generation = [int[]]::new(19)
        $measuredCompletionIds = [Collections.Generic.List[string]]::new()
        $lastProcessTreeSampleUtc = [DateTimeOffset]::MinValue
        $lastTraceCheckUtc = [DateTimeOffset]::MinValue
        $expectedAllocation = if ($Condition -in @('BASE', 'COMPAT')) { 16 } else { 12 }
        foreach ($worker in 1..18) {
            $generation[$worker]++
            $run = Start-ScenarioBuild `
                -Bootstrap $bootstrap `
                -Repository $repository `
                -Worktree (Get-PreparedWorktree -Name "normal$worker") `
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
            Add-ControllerEvent -Event 'Launched' -Run $run
        }
        $stopReplacements = $false
        $injectedRun = $null
        while (-not $stopReplacements) {
            $now = [DateTimeOffset]::UtcNow
            if (($now - $lastProcessTreeSampleUtc).TotalSeconds -ge 5) {
                Update-ScenarioProcessTrees -Runs $allRuns.ToArray()
                $lastProcessTreeSampleUtc = $now
            }

            if ($null -eq $controller.SteadyOnsetUtc -and
                ($now - $lastTraceCheckUtc).TotalSeconds -ge 1) {
                $traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
                if ($traceFiles.Count -eq 1) {
                    $liveRecords = @($allRuns | ForEach-Object { ConvertTo-RunRecord -Run $_ })
                    $liveTrace = ConvertFrom-CoordinatorTrace `
                        -TracePaths $traceFiles `
                        -RunRecords $liveRecords `
                        -Budget 16 `
                        -StrictParsing
                    if (-not $liveTrace.Consistent) {
                        throw "Live Coordinator trace became inconsistent: $($liveTrace.Errors -join '; ')"
                    }
                    $onset = Test-SteadyOnsetState `
                        -Trace $liveTrace `
                        -NowUtc $now `
                        -ExpectedAllocation $expectedAllocation `
                        -MinimumQueueDepth $campaign.Validity.SustainedQueueMinimum `
                        -StableSeconds $campaign.Validity.SustainedSteadyAllocationSeconds `
                        -HandoffGapToleranceSeconds $campaign.Validity.SustainedHandoffGapToleranceSeconds
                    if ($onset.Accepted) {
                        $controller.SteadyOnsetUtc = $now.ToString('O')
                        $controller.SemanticSaturationStartUtc = $onset.SemanticSaturationStartUtc
                        $controller.SemanticBridgedHandoffCount = $onset.BridgedHandoffCount
                        Add-ControllerEvent -Event 'SteadyOnset' -Run $null -Data @{
                            QueueDepth = $onset.QueueDepth
                            AllocatedNodes = $onset.AllocatedNodes
                            AllocationStableSeconds = $onset.AllocationStableSeconds
                            SemanticSaturationStartUtc = $onset.SemanticSaturationStartUtc
                            BridgedHandoffCount = $onset.BridgedHandoffCount
                            HandoffGapToleranceSeconds = $onset.HandoffGapToleranceSeconds
                        }
                    }
                }
                elseif ($traceFiles.Count -gt 1) {
                    throw "Sustained scenario produced $($traceFiles.Count) Coordinator server traces; expected exactly one."
                }
                $lastTraceCheckUtc = $now
            }

            $newlyCompleted = [Collections.Generic.List[object]]::new()
            foreach ($run in @($allRuns | Where-Object { -not $_.Completed -and $_.Process.HasExited })) {
                if (Complete-ExitedScenarioBuild -Run $run) {
                    $newlyCompleted.Add($run)
                }
            }
            foreach ($run in $newlyCompleted | Sort-Object ProcessExitUtc) {
                Add-ControllerEvent -Event 'Completed' -Run $run -Data @{
                    ExitCode = $run.ExitCode
                    Quiescent = $run.Quiescent
                }
                $run.CompletionEventWritten = $true
                if (-not $run.Quiescent) {
                    $controller.WorktreeOverlap = $true
                    $stopReplacements = $true
                }
                if ($run.ExitCode -ne 0) {
                    $controller.PolicyFailureRunIds += $run.RunId
                    $stopReplacements = $true
                }
                $counted = $false
                if ($null -ne $controller.SteadyOnsetUtc -and
                    $run.Kind -eq 'normal' -and
                    $run.Quiescent -and
                    $run.ExitCode -eq 0 -and
                    $run.ProcessExitUtc -ge (ConvertTo-UtcDateTimeOffset -Value $controller.SteadyOnsetUtc) -and
                    $measuredCompletionIds.Count -lt $campaign.Validity.SustainedEndingCompletion) {
                    $measuredCompletionIds.Add($run.RunId)
                    $controller.MeasuredNormalCompletions = $measuredCompletionIds.Count
                    $counted = $true
                    Add-ControllerEvent -Event 'MeasuredCompletion' -Run $run -Data @{
                        CompletionNumber = $measuredCompletionIds.Count
                    }
                    if ($measuredCompletionIds.Count -eq $campaign.Validity.SustainedInjectionCompletion) {
                        $injectedWorktree = Get-PreparedWorktree -Name injected
                        [void](Touch-CampaignInput -Worktree $injectedWorktree -RelativePath $repository.TouchPath)
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
                        $controller.InjectionStartedUtc = $injectedRun.ProcessStartUtc.ToString('O')
                        $controller.InjectionOffsetSeconds = $injectedRun.StartOffsetSeconds
                        Add-ControllerEvent -Event 'Injected' -Run $injectedRun -Data @{
                            AfterMeasuredCompletion = $measuredCompletionIds.Count
                        }
                    }
                    if ($measuredCompletionIds.Count -eq $campaign.Validity.SustainedEndingCompletion) {
                        $controller.SteadyEndUtc = $run.ProcessExitUtc.ToString('O')
                        if (($run.ProcessExitUtc - (ConvertTo-UtcDateTimeOffset -Value $controller.SteadyOnsetUtc)).TotalMinutes -gt
                            $campaign.Validity.SustainedTimeoutMinutes) {
                            $controller.TimedOut = $true
                            $terminalOutcome = Write-ScenarioTerminalOutcome `
                                -ScenarioRoot $ScenarioRoot `
                                -OutcomeType 'SustainedCompletionTimeout' `
                                -Disposition 'CampaignAbilityGateFailure' `
                                -Errors @('Sustained ability gate exceeded 10 minutes between steady onset and the twelfth measured Normal completion.')
                        }
                        $stopReplacements = $true
                        Add-ControllerEvent -Event 'SteadyEnd' -Run $run -Data @{
                            MeasuredCompletions = $measuredCompletionIds.Count
                        }
                    }
                }

                if (-not $stopReplacements -and $run.Kind -eq 'normal') {
                    $worktree = Get-PreparedWorktree -Name "normal$($run.Worker)"
                    if (-not $run.Quiescent) {
                        throw "Worker $($run.Worker) was selected for replacement before quiescence."
                    }
                    [void](Touch-CampaignInput -Worktree $worktree -RelativePath $repository.TouchPath)
                    $generation[$run.Worker]++
                    $replacement = Start-ScenarioBuild `
                        -Bootstrap $bootstrap `
                        -Repository $repository `
                        -Worktree $worktree `
                        -Condition $Condition `
                        -PipeName $pipeName `
                        -DebugPath $debugPath `
                        -ScenarioRoot $ScenarioRoot `
                        -RunId "normal$($run.Worker)-g$($generation[$run.Worker])" `
                        -Kind normal `
                        -Worker $run.Worker `
                        -Generation $generation[$run.Worker] `
                        -ScenarioStartedUtc $scenarioStartedUtc
                    $allRuns.Add($replacement)
                    Add-ControllerEvent -Event 'ReplacementLaunched' -Run $replacement -Data @{
                        ReplacedRunId = $run.RunId
                        PriorCompletionCounted = $counted
                    }
                }
            }
            Save-LiveRuns -Runs $allRuns.ToArray()

            if (-not $stopReplacements) {
                if ($null -eq $controller.SteadyOnsetUtc) {
                    if (($now - $scenarioStartedUtc).TotalMinutes -gt $campaign.Validity.SustainedTimeoutMinutes) {
                        $controller.TimedOut = $true
                        $terminalOutcome = Write-ScenarioTerminalOutcome `
                            -ScenarioRoot $ScenarioRoot `
                            -OutcomeType 'SustainedOnsetTimeout' `
                            -Disposition 'CampaignAbilityGateFailure' `
                            -Errors @('Sustained ability gate did not establish steady onset within 10 minutes.')
                        $stopReplacements = $true
                        Add-ControllerEvent -Event 'OnsetTimeout' -Run $null
                    }
                }
                elseif (($now - (ConvertTo-UtcDateTimeOffset -Value $controller.SteadyOnsetUtc)).TotalMinutes -gt
                    $campaign.Validity.SustainedTimeoutMinutes) {
                    $controller.TimedOut = $true
                    $controller.SteadyEndUtc = $now.ToString('O')
                    $terminalOutcome = Write-ScenarioTerminalOutcome `
                        -ScenarioRoot $ScenarioRoot `
                        -OutcomeType 'SustainedCompletionTimeout' `
                        -Disposition 'CampaignAbilityGateFailure' `
                        -Errors @('Sustained ability gate did not reach 12 measured Normal completions within 10 minutes after steady onset.')
                    $stopReplacements = $true
                    Add-ControllerEvent -Event 'SteadyTimeout' -Run $null
                }
            }
            Start-Sleep -Milliseconds 100
        }
        $controller.MeasuredCompletionRunIds = $measuredCompletionIds.ToArray()
        Wait-ScenarioBuilds -Runs $allRuns.ToArray() -TimeoutMinutes 10
        foreach ($run in $allRuns | Where-Object { $_.Completed }) {
            if ($run.ExitCode -ne 0 -and $controller.PolicyFailureRunIds -notcontains $run.RunId) {
                $controller.PolicyFailureRunIds += $run.RunId
            }
        }
    }
    Save-LiveRuns -Runs $allRuns.ToArray()
    $metadata.Succeeded = $true
}
catch {
    $scenarioExceptions.Add($_.Exception)
    $metadata['Error'] = $_.Exception.ToString()
}
finally {
    try {
        $cleanup = Stop-UnfinishedScenarioBuilds -Runs $allRuns.ToArray()
        $metadata['BuildCleanup'] = $cleanup
        if (-not $cleanup.Succeeded) {
            $cleanupException = [InvalidOperationException]::new(
                "Scenario build cleanup failed: $($cleanup.Errors -join '; ')")
            $scenarioExceptions.Add($cleanupException)
            $terminalOutcome = Write-ScenarioCleanupTerminalOutcome `
                -ScenarioRoot $ScenarioRoot `
                -Cleanup $cleanup
        }
    }
    catch {
        $scenarioExceptions.Add($_.Exception)
        $metadata['BuildCleanupError'] = $_.Exception.ToString()
        $liveAfterCleanupError = @(
            $allRuns |
                Where-Object {
                    $rootLive = Test-VerifiedProcessIdentity `
                        -ProcessId $_.RootProcessId `
                        -ProcessStartUtc $_.ProcessStartUtc
                    $descendantLive = @(
                        foreach ($identity in @($_.DescendantIdentities)) {
                            $parts = [string]$identity -split '\|', 2
                            if ($parts.Count -eq 2 -and
                                -not [string]::IsNullOrWhiteSpace($parts[1]) -and
                                (Test-VerifiedProcessIdentity `
                                    -ProcessId ([int]$parts[0]) `
                                    -ProcessStartUtc $parts[1])) {
                                $identity
                            }
                        }
                    ).Count -gt 0
                    return $rootLive -or $descendantLive
                } |
                Select-Object -ExpandProperty RunId
        )
        $uncertainAfterCleanupError = @(
            $allRuns |
                Where-Object {
                    -not $_.Completed -or $_.Quiescent -ne $true
                } |
                Select-Object -ExpandProperty RunId
        )
        $cleanupFailureErrors = [Collections.Generic.List[string]]::new()
        $cleanupFailureErrors.Add("Scenario build cleanup threw: $($_.Exception.Message)")
        if ($liveAfterCleanupError.Count -gt 0) {
            $cleanupFailureErrors.Add(
                "Build process identities remained live after cleanup failed: $($liveAfterCleanupError -join ', ').")
        }
        if ($uncertainAfterCleanupError.Count -gt 0) {
            $cleanupFailureErrors.Add(
                "Build quiescence remained uncertain after cleanup failed: $($uncertainAfterCleanupError -join ', ').")
        }
        $terminalOutcome = Write-ScenarioTerminalOutcome `
            -ScenarioRoot $ScenarioRoot `
            -OutcomeType 'BuildCleanupFailure' `
            -Disposition 'NonRetryableHarnessFailure' `
            -Errors $cleanupFailureErrors.ToArray()
    }
    try {
        Save-LiveRuns -Runs $allRuns.ToArray()
    }
    catch {
        $scenarioExceptions.Add($_.Exception)
        $metadata['RunPersistenceError'] = $_.Exception.ToString()
    }
    if ($null -ne $monitor) {
        $monitorProcessId = $monitor.Process.Id
        $monitorProcessStartUtc = $monitor.ProcessStartUtc
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
            $metadata['MonitorStopError'] = $_.Exception.ToString()
            $scenarioExceptions.Add($_.Exception)
            $monitorLive = Test-VerifiedProcessIdentity `
                -ProcessId $monitorProcessId `
                -ProcessStartUtc $monitorProcessStartUtc
            $terminalOutcome = Write-ScenarioTerminalOutcome `
                -ScenarioRoot $ScenarioRoot `
                -OutcomeType 'MonitorCleanupFailure' `
                -Disposition 'NonRetryableHarnessFailure' `
                -Errors @(
                    "Resource monitor cleanup failed: $($_.Exception.Message)",
                    "Resource monitor remained live after cleanup: $monitorLive"
                )
        }
    }
    try {
        Invoke-BuildServerShutdown `
            -Bootstraps @($base, $final) `
            -JournalPath $journal `
            -OutputDirectory $commandOutput
    }
    catch {
        $metadata['BuildServerShutdownError'] = $_.Exception.ToString()
        $scenarioExceptions.Add($_.Exception)
    }
    $terminalOutcome = Get-ScenarioTerminalOutcome -ScenarioRoot $ScenarioRoot
    if ($null -ne $terminalOutcome) {
        $metadata['TerminalOutcome'] = $terminalOutcome
    }
    if ($scenarioExceptions.Count -gt 0 -or $null -ne $terminalOutcome) {
        $metadata.Succeeded = $false
    }
    $metadata.CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    try {
        Write-JsonAtomic -Path (Join-Path $ScenarioRoot 'scenario-metadata.json') -Value $metadata -Depth 10
        Write-JsonAtomic -Path (Join-Path $ScenarioRoot 'controller-summary.json') -Value ([pscustomobject]$controller) -Depth 8
    }
    catch {
        $scenarioExceptions.Add($_.Exception)
    }
}
if ($scenarioExceptions.Count -gt 0) {
    throw [AggregateException]::new(
        'Scenario execution, cleanup, monitoring, or build-server shutdown failed.',
        [Exception[]]$scenarioExceptions.ToArray())
}

$runRecords = @($allRuns | ForEach-Object { ConvertTo-RunRecord -Run $_ })
$runRecords | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $ScenarioRoot 'runs.csv')
Write-JsonAtomic -Path (Join-Path $ScenarioRoot 'runs.json') -Value $runRecords -Depth 8
$traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
$harnessErrors = [Collections.Generic.List[string]]::new()
$externalErrors = [Collections.Generic.List[string]]::new()
$policyFailures = [Collections.Generic.List[string]]::new()
$abilityGateErrors = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
if ($traceFiles.Count -ne 1) {
    $harnessErrors.Add("Expected exactly one Coordinator server trace; found $($traceFiles.Count).")
}
foreach ($run in $runRecords) {
    if ($run.ExitCode -ne 0) {
        $policyFailures.Add("Build '$($run.RunId)' exited with code $($run.ExitCode).")
    }
    if (-not $run.Quiescent) {
        $harnessErrors.Add("Build '$($run.RunId)' did not reach full descendant/stdout/stderr quiescence.")
    }
    if (-not (Test-Path -LiteralPath $run.Binlog -PathType Leaf) -or
        (Get-Item -LiteralPath $run.Binlog -ErrorAction SilentlyContinue).Length -eq 0) {
        $harnessErrors.Add("Build '$($run.RunId)' has a missing or empty binlog.")
    }
    if (-not (Test-Path -LiteralPath $run.Stderr -PathType Leaf)) {
        $harnessErrors.Add("Build '$($run.RunId)' has no stderr record.")
    }
    elseif (-not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $run.Stderr -Raw))) {
        if ($run.ExitCode -ne 0) {
            $policyFailures.Add("Build '$($run.RunId)' wrote stderr while producing tested-condition exit code $($run.ExitCode).")
        }
        else {
            $harnessErrors.Add("Successful build '$($run.RunId)' has nonempty stderr.")
        }
    }
}

$telemetry = Test-TelemetryContinuity `
    -MonitorRoot $monitorRoot `
    -ReadyUtc $monitor.ReadyObservedUtc `
    -StopUtc $monitor.StopRequestedUtc
foreach ($message in $telemetry.Errors) {
    $externalErrors.Add($message)
}
foreach ($message in $telemetry.Warnings) {
    $warnings.Add($message)
}
$trace = $null
$grantMetrics = [Collections.Generic.List[object]]::new()
$replays = @()
if ($harnessErrors.Count -eq 0 -and $traceFiles.Count -eq 1) {
    try {
        $replayPath = Join-Path $ScenarioRoot 'grant-replay.json'
        $replays = @(
            & (Join-Path $PSScriptRoot 'Invoke-GrantReplay.ps1') `
                -BootstrapRoot $bootstrap.Root `
                -Binlog @($runRecords.Binlog) `
                -OutputPath $replayPath `
                -WorkRoot (Join-Path $ScenarioRoot '_tooling') `
                -JournalPath $journal
        )
        $trace = ConvertFrom-CoordinatorTrace `
            -TracePaths $traceFiles `
            -RunRecords $runRecords `
            -Budget 16 `
            -RequireEmptyFinalState `
            -StrictParsing
        [void](Export-CoordinatorTraceResult `
            -Trace $trace `
            -DestinationRoot (Join-Path $ScenarioRoot 'parsed-trace'))
        if (-not $trace.Consistent) {
            foreach ($message in $trace.Errors) {
                $harnessErrors.Add($message)
            }
        }
        foreach ($run in $runRecords) {
            $replay = $replays |
                Where-Object { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($run.Binlog) } |
                Select-Object -First 1
            $traceState = $trace.RootStates |
                Where-Object RunId -eq $run.RunId |
                Select-Object -First 1
            if ($null -eq $replay) {
                $harnessErrors.Add("Build '$($run.RunId)' has no grant replay record.")
                continue
            }
            if (@($replay.Grants).Count -ne 1) {
                $harnessErrors.Add("Build '$($run.RunId)' has $(@($replay.Grants).Count) binlog grants; expected exactly one.")
                continue
            }
            if ($null -eq $traceState -or $null -eq $traceState.GrantedUtc) {
                $harnessErrors.Add("Build '$($run.RunId)' has no trace grant mapped to its OS process identity.")
                continue
            }
            $metric = Get-GrantMetricsForRun -Run $run -Replay $replay -TraceState $traceState
            if ($metric.GrantedNodes -ne [int]$traceState.GrantedNodes) {
                $harnessErrors.Add("Build '$($run.RunId)' binlog grant $($metric.GrantedNodes) differs from trace grant $($traceState.GrantedNodes).")
            }
            if ($metric.TraceAndBinlogGrantDeltaSeconds -gt $campaign.Validity.GrantTimestampCrossCheckMaximumSeconds) {
                $harnessErrors.Add("Build '$($run.RunId)' trace/binlog grant timestamps differ by $($metric.TraceAndBinlogGrantDeltaSeconds) seconds.")
            }
            $grantMetrics.Add($metric)
        }
    }
    catch {
        $harnessErrors.Add($_.Exception.Message)
    }
}

$scenarioStart = ConvertTo-UtcDateTimeOffset -Value $controller.ScenarioStartedUtc
$scenarioEnd = @(
    $runRecords |
        ForEach-Object { ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc } |
        Sort-Object |
        Select-Object -Last 1
)[0]
$wallSeconds = ($scenarioEnd - $scenarioStart).TotalSeconds
$resource = Get-ScenarioResourceMetrics `
    -MonitorRoot $monitorRoot `
    -RunRecords $runRecords `
    -WindowStartUtc $scenarioStart `
    -WindowEndUtc $scenarioEnd
if ($resource.SystemSampleCount -lt 2) {
    $externalErrors.Add('Scenario window has fewer than two system telemetry samples.')
}
if ($resource.PeakDescendantProcessCount -lt 1) {
    $harnessErrors.Add('Process telemetry did not attribute any root/descendant process to the scenario window.')
}
if ($resource.ForeignConflictingProcessCount -gt 0) {
    $externalErrors.Add("Process telemetry found $($resource.ForeignConflictingProcessCount) foreign build/compiler process identity or identities during the scenario window.")
}
$logicalProcessors = [Environment]::ProcessorCount
$noiseFraction = if ($wallSeconds -le 0) {
    0.0
}
else {
    $resource.KnownExternalNoiseCpuSeconds / ($wallSeconds * $logicalProcessors)
}
if ($noiseFraction -gt $campaign.Validity.MaxKnownExternalNoiseCpuCoreFraction) {
    $externalErrors.Add("Known external-noise CPU fraction $noiseFraction exceeded $($campaign.Validity.MaxKnownExternalNoiseCpuCoreFraction).")
}
if ($resource.PeakKnownExternalNoiseWorkingSetBytes -gt $campaign.Validity.MaxKnownExternalNoiseWorkingSetBytes) {
    $externalErrors.Add("Known external-noise working set $($resource.PeakKnownExternalNoiseWorkingSetBytes) exceeded $($campaign.Validity.MaxKnownExternalNoiseWorkingSetBytes).")
}
foreach ($worktree in $repository.Worktrees) {
    try {
        [void](Get-GitIdentity -Root $worktree.Path -ExpectedCommit $repository.Commit -RequireClean)
    }
    catch {
        $harnessErrors.Add($_.Exception.Message)
    }
}

$metrics = [ordered]@{
    SchemaVersion = 2
    Shape = $Shape
    Repository = $RepositoryName
    Condition = $Condition
    BlockNumber = $BlockNumber
    AnalysisBlockNumber = $AnalysisBlockNumber
    IsWarmup = $IsWarmup
    AttemptNumber = $AttemptNumber
    OrderIndex = $OrderIndex
    RunIdentity = $RunIdentity
    ScenarioStartUtc = $scenarioStart.ToString('O')
    ScenarioEndUtc = $scenarioEnd.ToString('O')
    TotalWallSeconds = $wallSeconds
    RunCount = $runRecords.Count
    FailedRunCount = @($runRecords | Where-Object ExitCode -ne 0).Count
    Resource = $resource
    KnownExternalNoiseCpuCoreFraction = $noiseFraction
    Grants = $grantMetrics.ToArray()
    ParsedTraceRoot = if ($null -eq $trace) { $null } else { 'parsed-trace' }
    WorkloadKind = 'representative-propagated-project'
    WorkloadDeviation = $campaign.WorkloadDeviation
    BaseOneNodeSaturationIsMeasuredMechanism = $Shape -eq 'sustained' -and $Condition -eq 'BASE'
}
if ($Shape -eq 'isolated') {
    if ($grantMetrics.Count -eq 1) {
        $expectedGrant = switch ($Condition) {
            'BASE' { 16 }
            'COMPAT' { 16 }
            'FINAL-N' { 8 }
        }
        if ($grantMetrics[0].GrantedNodes -ne $expectedGrant) {
            $harnessErrors.Add("Isolated $Condition grant was $($grantMetrics[0].GrantedNodes); expected $expectedGrant.")
        }
        $metrics.EndToEndSeconds = $grantMetrics[0].RequestToCompletionSeconds
        $metrics.GrantedNodes = $grantMetrics[0].GrantedNodes
        $metrics.CoordinatorWaitSeconds = $grantMetrics[0].QueueWaitSeconds
        $metrics.CoordinatorNegotiationSeconds = $grantMetrics[0].CoordinatorNegotiationSeconds
    }
}
elseif ($Shape -eq 'sustained') {
    $controllerEvents = @(
        Get-Content -LiteralPath (Join-Path $ScenarioRoot 'controller-events.jsonl') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $controllerValidation = Test-SustainedControllerEvents `
        -Events $controllerEvents `
        -InitialWorkers $campaign.Validity.SustainedWorkers `
        -InjectionCompletion $campaign.Validity.SustainedInjectionCompletion `
        -EndingCompletion $campaign.Validity.SustainedEndingCompletion
    if (-not $controllerValidation.Valid) {
        foreach ($message in $controllerValidation.Errors) {
            $harnessErrors.Add($message)
        }
    }
    if ($controller.TimedOut) {
        if ($null -ne $terminalOutcome -and
            $terminalOutcome.Disposition -eq 'CampaignAbilityGateFailure') {
            foreach ($message in @($terminalOutcome.Errors)) {
                $abilityGateErrors.Add([string]$message)
            }
        }
        else {
            $abilityGateErrors.Add("Sustained ability gate failed: the controller did not reach 12 measured Normal completions within 10 minutes after onset.")
        }
    }
    if ($controller.WorktreeOverlap) {
        $harnessErrors.Add('Sustained controller detected worktree overlap or incomplete quiescence.')
    }
    if ($controller.MeasuredNormalCompletions -ne $campaign.Validity.SustainedEndingCompletion) {
        $abilityGateErrors.Add("Sustained ability gate recorded $($controller.MeasuredNormalCompletions) Normal completions; expected $($campaign.Validity.SustainedEndingCompletion).")
    }
    if ($null -eq $controller.SteadyOnsetUtc -or $null -eq $controller.SteadyEndUtc) {
        $externalErrors.Add('Sustained controller did not establish a complete steady window.')
    }
    elseif ($null -ne $trace) {
        $steadyStart = ConvertTo-UtcDateTimeOffset -Value $controller.SteadyOnsetUtc
        $steadyEnd = ConvertTo-UtcDateTimeOffset -Value $controller.SteadyEndUtc
        $injectionUtc = if ($null -eq $controller.InjectionStartedUtc) {
            $null
        }
        else {
            ConvertTo-UtcDateTimeOffset -Value $controller.InjectionStartedUtc
        }
        $reserved = if ($Condition -in @('FINAL-N', 'FINAL-H')) { 4 } else { 0 }
        $window = Get-TraceWindowMetrics `
            -Timeline $trace.Timeline `
            -StartUtc $steadyStart `
            -EndUtc $steadyEnd `
            -Budget 16 `
            -ReservedNodes $reserved
        if ($window.QueueNonemptyFraction -lt $campaign.Validity.SustainedQueueNonemptyFractionMinimum) {
            $externalErrors.Add("Sustained queue was nonempty for $($window.QueueNonemptyFraction); required at least $($campaign.Validity.SustainedQueueNonemptyFractionMinimum).")
        }
        if ($null -eq $injectionUtc) {
            $externalErrors.Add('Sustained injection did not occur.')
        }
        else {
            $stateAtInjection = Get-StateAtTimestamp -Timeline $trace.Timeline -TimestampUtc $injectionUtc
            if ($stateAtInjection.ActiveBuilds -lt 1 -or $stateAtInjection.QueueDepth -lt 1) {
                $externalErrors.Add("Injection state had active=$($stateAtInjection.ActiveBuilds), queued=$($stateAtInjection.QueueDepth); both must be at least one.")
            }
            $queueDrainedEightNodeGrants = @(
                $trace.Events |
                    Where-Object {
                        $_.Event -in @('Granted', 'DeferredGranted') -and
                            $_.Nodes -eq 8 -and
                            (ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc) -ge $steadyStart -and
                            (ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc) -le $steadyEnd -and
                            $_.QueueDepthBefore -le 1 -and
                            $_.QueueDepth -eq 0
                    }
            )
            if ($queueDrainedEightNodeGrants.Count -gt 0) {
                $externalErrors.Add("Found $($queueDrainedEightNodeGrants.Count) queue-drained 8-node grant(s) in the steady window.")
            }
            $injectedMetric = $grantMetrics | Where-Object RunId -eq 'injected-g1' | Select-Object -First 1
            $preSeconds = ($injectionUtc - $steadyStart).TotalSeconds
            $postSeconds = ($steadyEnd - $injectionUtc).TotalSeconds
            $completedInWindow = @(
                $runRecords |
                    Where-Object {
                        $_.Kind -eq 'normal' -and
                            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -ge $steadyStart -and
                            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -le $steadyEnd
                    }
            )
            if ($completedInWindow.Count -ne $campaign.Validity.SustainedEndingCompletion) {
                $externalErrors.Add("Trace-time steady interval contains $($completedInWindow.Count) Normal exits; expected exactly $($campaign.Validity.SustainedEndingCompletion).")
            }
            $includedLatencyRuns = @(
                $runRecords |
                    Where-Object { $controller.MeasuredCompletionRunIds -contains $_.RunId }
            )
            $rightCensored = @(
                $runRecords |
                    Where-Object {
                        $_.Kind -eq 'normal' -and
                            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessStartUtc) -le $steadyEnd -and
                            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -gt $steadyEnd
                    }
            )
            $steadyResource = Get-ScenarioResourceMetrics `
                -MonitorRoot $monitorRoot `
                -RunRecords $runRecords `
                -WindowStartUtc $steadyStart `
                -WindowEndUtc $steadyEnd
            $metrics.SteadyOnsetUtc = $steadyStart.ToString('O')
            $metrics.SemanticSaturationStartUtc = $controller.SemanticSaturationStartUtc
            $metrics.SemanticBridgedHandoffCount = $controller.SemanticBridgedHandoffCount
            $metrics.SemanticHandoffGapToleranceSeconds = $controller.SemanticHandoffGapToleranceSeconds
            $metrics.SteadyEndUtc = $steadyEnd.ToString('O')
            $metrics.SteadyWindowSeconds = $window.WindowSeconds
            $metrics.OverallNormalThroughputPerSecond =
                [double]$campaign.Validity.SustainedEndingCompletion / $window.WindowSeconds
            $metrics.PreInjectionNormalThroughputPerSecond =
                [double]$campaign.Validity.SustainedInjectionCompletion / $preSeconds
            $metrics.PostInjectionNormalThroughputPerSecond =
                [double]($campaign.Validity.SustainedEndingCompletion - $campaign.Validity.SustainedInjectionCompletion) / $postSeconds
            $metrics.InjectedRequestToGrantSeconds = if ($null -eq $injectedMetric) { $null } else { $injectedMetric.RequestToGrantSeconds }
            $metrics.InjectedRequestToCompletionSeconds = if ($null -eq $injectedMetric) { $null } else { $injectedMetric.RequestToCompletionSeconds }
            $metrics.QueueDepthP50 = $window.QueueDepthP50
            $metrics.QueueDepthP95 = $window.QueueDepthP95
            $metrics.QueueDepthMaximum = $window.QueueDepthMaximum
            $metrics.QueueNonemptyFraction = $window.QueueNonemptyFraction
            $metrics.UnusedNodeSeconds = $window.UnusedNodeSeconds
            $metrics.ReservedIdleNodeSeconds = $window.ReservedIdleNodeSeconds
            $metrics.RampSeconds = ($steadyStart - $scenarioStart).TotalSeconds
            $metrics.DrainSeconds = ($scenarioEnd - $steadyEnd).TotalSeconds
            $metrics.CompletedLatencyInclusionCount = $includedLatencyRuns.Count
            $metrics.AllNormalExitsInWindow = $completedInWindow.Count
            $metrics.RightCensoredNormalCount = $rightCensored.Count
            $metrics.AverageIncludedNormalLatencySeconds =
                ($includedLatencyRuns | Measure-Object DurationSeconds -Average).Average
            $metrics.SteadyResource = $steadyResource
            $metrics.GrantSequence = @($grantMetrics | Sort-Object GrantTimestampUtc | Select-Object RunId,GrantedNodes,GrantTimestampUtc)
        }
    }
}
Write-JsonAtomic -Path (Join-Path $ScenarioRoot 'scenario-metrics.json') -Value ([pscustomobject]$metrics) -Depth 12

$disposition = if ($null -ne $terminalOutcome) {
    [string]$terminalOutcome.Disposition
}
elseif ($abilityGateErrors.Count -gt 0) {
    'CampaignAbilityGateFailure'
}
elseif ($harnessErrors.Count -gt 0 -or $externalErrors.Count -gt 0) {
    'InvalidRetryable'
}
elseif ($policyFailures.Count -gt 0) {
    'TestedConditionPolicyOutcome'
}
else {
    'Valid'
}
$validation = [pscustomobject][ordered]@{
    SchemaVersion = 2
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Shape = $Shape
    Repository = $RepositoryName
    Condition = $Condition
    BlockNumber = $BlockNumber
    AnalysisBlockNumber = $AnalysisBlockNumber
    IsWarmup = $IsWarmup
    AttemptNumber = $AttemptNumber
    OrderIndex = $OrderIndex
    RunIdentity = $RunIdentity
    ValidForAnalysis = $disposition -eq 'Valid'
    RetryAllowed = $disposition -eq 'InvalidRetryable' -and $null -eq $terminalOutcome
    Disposition = $disposition
    Warnings = $warnings.ToArray()
    HarnessErrors = $harnessErrors.ToArray()
    ExternalValidityErrors = $externalErrors.ToArray()
    TestedConditionPolicyOutcomes = $policyFailures.ToArray()
    CampaignAbilityGateErrors = $abilityGateErrors.ToArray()
    Telemetry = $telemetry
}
Write-JsonAtomic -Path (Join-Path $ScenarioRoot 'scenario-validation.json') -Value $validation -Depth 10
Write-Host "SCENARIO_VALIDATION=$(Join-Path $ScenarioRoot 'scenario-validation.json')"
$validation
