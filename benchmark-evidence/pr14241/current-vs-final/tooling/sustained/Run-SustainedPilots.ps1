[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$PreparationPath,
    [Parameter(Mandatory)]
    [DateTimeOffset]$HardDeadlineUtc,
    [Parameter(Mandatory)]
    [string]$OutputRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')

$campaign = Get-CampaignDefinition
$completionPath = Join-Path $OutputRoot 'pilot-completion.json'
if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    $existing =
        Get-Content -LiteralPath $completionPath -Raw |
        ConvertFrom-Json
    if (-not $existing.Valid -or
        [int]$existing.FrozenWorkerCount -notin @(8, 10) -or
        @($existing.SelectedPilots).Count -ne 6) {
        throw "Existing pilot completion '$completionPath' is invalid."
    }
    Write-Host "SUSTAINED_PILOT_COMPLETION=$completionPath"
    $existing
    return
}
if (Test-Path -LiteralPath $OutputRoot) {
    if (@(Get-ChildItem -LiteralPath $OutputRoot -Force).Count -gt 0) {
        throw "Incomplete pilot root '$OutputRoot' already exists; automatic relaunch is refused."
    }
}
else {
    New-Item -ItemType Directory -Path $OutputRoot | Out-Null
}

$roundRecords = [Collections.Generic.List[object]]::new()
$selectedPilots = $null
$frozenWorkerCount = $null
foreach ($workerCount in @(8, 10)) {
    $roundRoot = Join-Path $OutputRoot "workers-$workerCount"
    New-Item -ItemType Directory -Path $roundRoot | Out-Null
    $pilots = [Collections.Generic.List[object]]::new()
    $increaseRequired = $false
    $queueFailureAtMaximum = $false
    $conditionOrdinal = 0
    foreach ($repository in $campaign.Repositories) {
        foreach ($condition in Get-SustainedConditionKeys) {
            $conditionOrdinal++
            if ([DateTimeOffset]::UtcNow -ge
                $HardDeadlineUtc.ToUniversalTime()) {
                throw 'The eight-hour campaign hard deadline expired during excluded pilots.'
            }
            $pilotRoot =
                Join-Path $roundRoot "$($repository.Name)\$condition"
            $resetRoot = Join-Path $pilotRoot 'prepared-baseline-reset'
            & (Join-Path $PSScriptRoot 'Reset-SustainedWorktrees.ps1') `
                -BootstrapIdentityPath $BootstrapIdentityPath `
                -PreparationPath $PreparationPath `
                -RepositoryName $repository.Name `
                -WorkerCount $workerCount `
                -Reason (
                    "Excluded workers-$workerCount sustained pilot baseline.") `
                -OutputRoot $resetRoot
            $scenarioRoot = Join-Path $pilotRoot 'scenario'
            $validation = @(
                & (Join-Path $PSScriptRoot 'Invoke-SustainedWindowScenario.ps1') `
                    -BootstrapIdentityPath $BootstrapIdentityPath `
                    -PreparationPath $PreparationPath `
                    -RepositoryName $repository.Name `
                    -Condition $condition `
                    -WorkerCount $workerCount `
                    -BlockNumber 0 `
                    -AttemptNumber 1 `
                    -OrderIndex $conditionOrdinal `
                    -Pilot `
                    -HardDeadlineUtc $HardDeadlineUtc `
                    -ScenarioRoot $scenarioRoot
            ) | Select-Object -Last 1
            if ($validation.Disposition -eq
                'WorkerCountIncreaseRequired') {
                if ($workerCount -ne 8 -or
                    -not $validation.WorkerCountIncreaseRequired -or
                    -not $validation.WorkerSizingResponse.RerunAllPilots -or
                    [int]$validation.WorkerSizingResponse.NextWorkerCount -ne
                        10) {
                    throw 'Worker sizing response did not request the one approved global 8-to-10 transition.'
                }
                $increaseRequired = $true
                $pilots.Add([pscustomobject][ordered]@{
                    Repository = $repository.Name
                    Condition = $condition
                    WorkerCount = $workerCount
                    Status = 'WorkerCountIncreaseRequired'
                    ScenarioRoot = $scenarioRoot
                    ValidationPath =
                        Join-Path $scenarioRoot 'scenario-validation.json'
                })
                break
            }
            if ($validation.Disposition -eq
                'QueueCriterionFailedAtFrozenMaximum') {
                if ($workerCount -ne 10 -or
                    $validation.WorkerCountIncreaseRequired -or
                    $null -ne
                        $validation.WorkerSizingResponse.NextWorkerCount) {
                    throw 'Ten-worker queue failure returned an invalid sizing response.'
                }
                $queueFailureAtMaximum = $true
                $pilots.Add([pscustomobject][ordered]@{
                    Repository = $repository.Name
                    Condition = $condition
                    WorkerCount = $workerCount
                    Status = 'QueueCriterionFailedAtFrozenMaximum'
                    ScenarioRoot = $scenarioRoot
                    ValidationPath =
                        Join-Path $scenarioRoot 'scenario-validation.json'
                })
                break
            }
            if ($validation.Disposition -ne 'Valid') {
                throw "Excluded $($repository.Name)/$condition workers-$workerCount pilot failed with '$($validation.Disposition)': $(@($validation.HarnessErrors + $validation.ExternalValidityErrors + $validation.TestedConditionPolicyOutcomes) -join '; ')"
            }
            $metrics =
                Get-Content `
                    -LiteralPath (
                        Join-Path $scenarioRoot 'scenario-metrics.json') `
                    -Raw |
                ConvertFrom-Json
            if ([double]$metrics.MeasuredWindowSeconds -ne 480 -or
                [int]$metrics.MeasuredNormalCompletionCount -lt
                    [int]$campaign.Validity.MinimumMeasuredNormalCompletions -or
                [int]$metrics.PreInjectionNormalCompletionCount -lt
                    [int]$campaign.Validity.MinimumNormalCompletionsPerHalf -or
                [int]$metrics.PostInjectionNormalCompletionCount -lt
                    [int]$campaign.Validity.MinimumNormalCompletionsPerHalf -or
                $metrics.OldTwelveCompletionTenMinuteGateApplied) {
                throw "Excluded $($repository.Name)/$condition pilot did not produce an exact usable eight-minute completion count."
            }
            $policy = $metrics.GrantPolicyEvidence
            if ($condition -eq 'FINAL-N' -and
                (-not $policy.Valid -or
                    [int]$policy.ActualGrantCount -lt 1 -or
                    [int]$policy.OversizedFinalGrantCount -ne 0 -or
                    $policy.ExpectedInjectedPriority -ne 'Normal' -or
                    $policy.TraceInjectedPriority -ne 'Normal')) {
                throw "Excluded $($repository.Name)/FINAL-N pilot did not validate actual <=4-node Normal grants through binlog replay and trace."
            }
            if ($condition -eq 'FINAL-H' -and
                (-not $policy.Valid -or
                    $policy.ExpectedInjectedPriority -ne 'High' -or
                    $policy.EnvironmentInjectedPriority -ne 'High' -or
                    $policy.TraceInjectedPriority -ne 'High' -or
                    -not $policy.PromptReserveBehaviorObserved)) {
                throw "Excluded $($repository.Name)/FINAL-H pilot did not prove High encoding and observed prompt reserve behavior."
            }
            $pilots.Add([pscustomobject][ordered]@{
                Repository = $repository.Name
                RepositoryCommit = $repository.Commit
                Condition = $condition
                WorkerCount = $workerCount
                Status = 'Valid'
                ExcludedFromMeasuredAnalysis = $true
                FixedWindowSeconds = [double]$metrics.MeasuredWindowSeconds
                ExactMeasuredNormalCompletionCount =
                    [int]$metrics.MeasuredNormalCompletionCount
                ExactPreInjectionNormalCompletionCount =
                    [int]$metrics.PreInjectionNormalCompletionCount
                ExactPostInjectionNormalCompletionCount =
                    [int]$metrics.PostInjectionNormalCompletionCount
                QueueNonemptyTimeFraction =
                    [double]$metrics.QueueNonemptyTimeFraction
                QueueNonemptySampleFraction =
                    [double]$metrics.QueueNonemptySampleFraction
                ActualGrantCount = [int]$policy.ActualGrantCount
                OversizedFinalGrantCount =
                    [int]$policy.OversizedFinalGrantCount
                IdleEightNodeGrantCount =
                    [int]$policy.IdleEightNodeGrantCount
                EnvironmentInjectedPriority =
                    $policy.EnvironmentInjectedPriority
                TraceInjectedPriority =
                    $policy.TraceInjectedPriority
                PromptReserveBehaviorObserved =
                    [bool]$policy.PromptReserveBehaviorObserved
                ScenarioRoot = $scenarioRoot
                MetricsPath =
                    Join-Path $scenarioRoot 'scenario-metrics.json'
                ValidationPath =
                    Join-Path $scenarioRoot 'scenario-validation.json'
            })
            if ($campaign.Validity.CooldownSeconds -gt 0) {
                Start-Sleep -Seconds $campaign.Validity.CooldownSeconds
            }
        }
        if ($increaseRequired -or $queueFailureAtMaximum) {
            break
        }
    }
    $round = [pscustomobject][ordered]@{
        WorkerCount = $workerCount
        CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        PilotCount = $pilots.Count
        WorkerCountIncreaseRequired = $increaseRequired
        QueueCriterionFailedAtFrozenMaximum =
            $queueFailureAtMaximum
        GlobalRerunAtTen = $increaseRequired
        Pilots = $pilots.ToArray()
    }
    Write-JsonAtomic `
        -Path (Join-Path $roundRoot 'round-completion.json') `
        -Value $round `
        -Depth 12
    $roundRecords.Add($round)
    if ($queueFailureAtMaximum) {
        throw 'Queue criterion failed at the frozen maximum of ten workers; no other size retry is permitted.'
    }
    if ($increaseRequired) {
        if ($workerCount -ne 8) {
            throw 'Queue criterion failed at the frozen maximum of ten workers.'
        }
        continue
    }
    if ($pilots.Count -ne 6) {
        throw "Workers-$workerCount pilot round completed $($pilots.Count) pilots; expected all six."
    }
    $selectedPilots = $pilots.ToArray()
    $frozenWorkerCount = $workerCount
    break
}

if ($null -eq $selectedPilots -or
    $null -eq $frozenWorkerCount) {
    throw 'Sustained pilots did not establish an approved frozen worker count.'
}
$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Valid = $true
    ExcludedFromMeasuredAnalysis = $true
    InitialWorkerCount = 8
    PermittedGlobalRerunWorkerCount = 10
    GlobalRerunCount = @(
        $roundRecords |
            Where-Object WorkerCountIncreaseRequired
    ).Count
    FrozenWorkerCount = $frozenWorkerCount
    WorkerCountFrozenForAllMeasuredScenarios = $true
    NoOtherSizeRetry = $true
    FixedWindowSeconds = 480
    InjectionOffsetSeconds = 240
    OldTwelveCompletionTenMinuteGateApplied = $false
    Rounds = $roundRecords.ToArray()
    SelectedPilots = $selectedPilots
}
Write-JsonAtomic -Path $completionPath -Value $result -Depth 14
Write-Host "SUSTAINED_PILOT_COMPLETION=$completionPath"
$result
