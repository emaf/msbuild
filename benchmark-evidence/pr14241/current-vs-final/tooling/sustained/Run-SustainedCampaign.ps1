[CmdletBinding()]
param(
    [string]$RunId,
    [switch]$PlanOnly,
    [string]$PlanOutputRoot,
    [string]$SourceRepositoryRoot = 'C:\perf\repos\msbuild-current-vs-final',
    [string]$BuildWorktreeRoot = 'C:\perf\worktrees\msbuild-current-vs-final',
    [string]$BootstrapStagingRoot = 'C:\perf\bootstraps\current-vs-final',
    [string]$LaunchRoot,
    [switch]$SkipFetch
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')

$campaign = Get-CampaignDefinition
$plan = New-SustainedCampaignPlan
$planValidation = Test-SustainedCampaignPlan -Plan $plan
if (-not $planValidation.Valid) {
    throw "Sustained plan validation failed: $($planValidation.Errors -join '; ')"
}
foreach ($condition in Get-SustainedConditionKeys) {
    $normal = New-ConditionEnvironment `
        -Condition $condition `
        -PipeName 'sustained-plan-pipe' `
        -DotNetRoot 'C:\immutable-bootstrap' `
        -EnableDebugTrace `
        -DebugPath 'C:\trace'
    $injected = New-ConditionEnvironment `
        -Condition $condition `
        -PipeName 'sustained-plan-pipe' `
        -DotNetRoot 'C:\immutable-bootstrap' `
        -Injected `
        -EnableDebugTrace `
        -DebugPath 'C:\trace'
    Assert-ConditionEnvironmentContract `
        -Condition $condition `
        -Environment $normal
    Assert-ConditionEnvironmentContract `
        -Condition $condition `
        -Environment $injected `
        -Injected
    $parity = Test-SustainedDebugEnvironmentParity `
        -NormalEnvironment $normal `
        -InjectedEnvironment $injected `
        -Condition $condition
    if (-not $parity.Valid) {
        throw "$condition environment plan failed: $($parity.Errors -join '; ')"
    }
}

if ($PlanOnly) {
    if ([string]::IsNullOrWhiteSpace($PlanOutputRoot)) {
        $PlanOutputRoot = Join-Path 'C:\perf\results' (
            'current-vs-final-sustained-plan-' +
            (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    if (Test-Path -LiteralPath $PlanOutputRoot) {
        if (@(
            Get-ChildItem -LiteralPath $PlanOutputRoot -Force
        ).Count -gt 0) {
            throw "Plan output '$PlanOutputRoot' already exists and is not empty."
        }
    }
    else {
        New-Item -ItemType Directory -Path $PlanOutputRoot | Out-Null
    }
    $root = (Resolve-Path -LiteralPath $PlanOutputRoot).Path
    $plan.Rows |
        Export-Csv `
            -NoTypeInformation `
            -LiteralPath (Join-Path $root 'matrix-plan.csv')
    Write-JsonAtomic `
        -Path (Join-Path $root 'matrix-plan.json') `
        -Value $plan.Rows `
        -Depth 8
    Write-JsonAtomic `
        -Path (Join-Path $root 'plan-validation.json') `
        -Value $planValidation `
        -Depth 10
    Write-JsonAtomic `
        -Path (Join-Path $root 'run-metadata.json') `
        -Value ([pscustomobject][ordered]@{
            SchemaVersion = 1
            PlanOnly = $true
            CreatedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            Campaign = $campaign
            Plan = $plan
            MaximumBlockAttempts =
                $campaign.Validity.MaximumBlockAttempts
            HardTimeoutHours = $campaign.HardTimeoutHours
        }) `
        -Depth 15
    Write-Host "PLAN_ROOT=$root"
    Write-Host "PLAN_ROWS=$($plan.Rows.Count)"
    Write-Host "POSITION_BALANCED=$($plan.Diagnostics.PositionBalanced)"
    Write-Host "CARRYOVER_BALANCED=$($plan.Diagnostics.CarryoverBalanced)"
    return
}

Assert-WindowsCampaignHost
if ([Environment]::ProcessorCount -ne $campaign.NodeBudget) {
    throw "Authoritative sustained campaign requires exactly $($campaign.NodeBudget) logical processors; this process sees $([Environment]::ProcessorCount)."
}
if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId =
        "current-vs-final-sustained-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}
if (-not $RunId.StartsWith(
    'current-vs-final-sustained-',
    [StringComparison]::Ordinal)) {
    throw "RunId '$RunId' must start with 'current-vs-final-sustained-'."
}

$mutexName = 'Global\MSBuild-PR14241-CurrentVsFinal-Sustained'
$mutex = [Threading.Mutex]::new($false, $mutexName)
$mutexOwned = $false
try {
    $mutexOwned = $mutex.WaitOne(0)
}
catch [Threading.AbandonedMutexException] {
    $mutexOwned = $true
}
if (-not $mutexOwned) {
    $mutex.Dispose()
    throw 'Another authoritative sustained campaign owns the global mutex.'
}
$duplicates = @(
    Get-CimInstance Win32_Process |
        Where-Object {
            [int]$_.ProcessId -ne $PID -and
            $_.Name -eq 'pwsh.exe' -and
            $_.CommandLine -like '*Run-SustainedCampaign.ps1*' -and
            $_.CommandLine -like '*current-vs-final-sustained-*'
        }
)
if ($duplicates.Count -gt 0) {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    throw "Duplicate sustained campaign process(es) already exist: $(@($duplicates.ProcessId) -join ', ')."
}

$runRoot = Join-Path 'C:\perf\results' $RunId
if (Test-Path -LiteralPath $runRoot) {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    throw "Fresh sustained result root '$runRoot' already exists; no automatic relaunch is allowed."
}
New-Item -ItemType Directory -Path $runRoot | Out-Null
$runRoot = (Resolve-Path -LiteralPath $runRoot).Path
$campaignStartedUtc = [DateTimeOffset]::UtcNow
$hardDeadlineUtc = $campaignStartedUtc.AddHours(
    [double]$campaign.HardTimeoutHours)
$statusPath = Join-Path $runRoot 'status.json'

function Set-SustainedCampaignStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Step,
        [string]$Detail,
        [ValidateSet('Running', 'Succeeded', 'Failed')]
        [string]$Status = 'Running'
    )

    $record = [pscustomobject][ordered]@{
        UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Status = $Status
        ProcessId = $PID
        ProcessStartUtc =
            (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')
        RunId = $RunId
        ResultRoot = $runRoot
        CurrentStep = $Step
        Detail = $Detail
        HardDeadlineUtc = $hardDeadlineUtc.ToString('O')
        HardTimeoutHours = $campaign.HardTimeoutHours
        AutomaticRelaunch = $false
    }
    Write-JsonAtomic -Path $statusPath -Value $record
    if (-not [string]::IsNullOrWhiteSpace($LaunchRoot)) {
        Write-JsonAtomic `
            -Path (Join-Path $LaunchRoot 'status.json') `
            -Value $record
    }
}

$toolingFiles = @(
    @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
            Where-Object {
                $_.Extension -in @('.ps1', '.md')
            }
    ) +
    @(
        'Campaign.Common.ps1',
        'Scenario.Common.ps1',
        'CoordinatorTrace.ps1',
        'Invoke-GrantReplay.ps1',
        'Monitor-Campaign.ps1',
        'Analysis.Common.ps1'
    ) |
        ForEach-Object {
            if ($_ -is [IO.FileInfo]) {
                $_
            }
            else {
                Get-Item -LiteralPath (
                    Join-Path (Split-Path -Parent $PSScriptRoot) $_)
            }
        } |
        Sort-Object FullName -Unique |
        ForEach-Object {
            Get-FileSha256Record `
                -Path $_.FullName `
                -RelativeTo (
                    Split-Path -Parent $PSScriptRoot)
        }
)
$plan.Rows |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $runRoot 'matrix-plan.csv')
Write-JsonAtomic `
    -Path (Join-Path $runRoot 'matrix-plan.json') `
    -Value $plan.Rows `
    -Depth 8
Write-JsonAtomic `
    -Path (Join-Path $runRoot 'plan-validation.json') `
    -Value $planValidation `
    -Depth 10
$machine = [pscustomobject][ordered]@{
    CapturedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    ComputerName = $env:COMPUTERNAME
    LogicalProcessors = [Environment]::ProcessorCount
    OperatingSystem =
        (Get-CimInstance Win32_OperatingSystem).Caption
    ProcessorNames = @(
        (Get-CimInstance Win32_Processor).Name
    )
}
Write-JsonAtomic -Path (Join-Path $runRoot 'machine.json') -Value $machine
$metadata = [pscustomobject][ordered]@{
    SchemaVersion = 1
    RunId = $RunId
    CreatedUtc = $campaignStartedUtc.ToString('O')
    HardDeadlineUtc = $hardDeadlineUtc.ToString('O')
    HardTimeoutHours = $campaign.HardTimeoutHours
    ResultRoot = $runRoot
    LaunchRoot = $LaunchRoot
    Campaign = $campaign
    PlanRows = $plan.Rows.Count
    PlanDiagnostics = $plan.Diagnostics
    SourceRepositoryRoot = $SourceRepositoryRoot
    BuildWorktreeRoot = $BuildWorktreeRoot
    BootstrapStagingRoot = $BootstrapStagingRoot
    ToolingRoot = $PSScriptRoot
    ToolingFiles = $toolingFiles
    MaximumBlockAttempts = $campaign.Validity.MaximumBlockAttempts
    NoAutomaticRelaunch = $true
    RawArtifactsOutsideGit = $true
    OldTwelveCompletionTenMinuteGateApplied = $false
}
Write-JsonAtomic `
    -Path (Join-Path $runRoot 'run-metadata.json') `
    -Value $metadata `
    -Depth 16
Write-Host "RUN_ROOT=$runRoot"
Set-SustainedCampaignStatus `
    -Step 'initializing' `
    -Detail 'Created fresh sustained-only plan and exact eight-hour deadline.'

$keepAwake = $null
$campaignError = $null
try {
    $keepAwake = Enable-CampaignKeepAwake
    Write-JsonAtomic `
        -Path (Join-Path $runRoot 'keep-awake-start.json') `
        -Value $keepAwake

    $buildRoot = Join-Path $runRoot '_setup\exact-build'
    Set-SustainedCampaignStatus `
        -Step 'exact-builds' `
        -Detail 'Validating per-role immutable reuse and building only missing exact roles.'
    & (Join-Path $PSScriptRoot 'Build-SustainedExactRevisions.ps1') `
        -SourceRepositoryRoot $SourceRepositoryRoot `
        -BuildWorktreeRoot $BuildWorktreeRoot `
        -BootstrapStagingRoot $BootstrapStagingRoot `
        -OutputRoot $buildRoot `
        -SkipFetch:$SkipFetch
    $bootstrapIdentityPath =
        Join-Path $buildRoot 'bootstrap-identities.json'
    if (-not (Test-Path -LiteralPath $bootstrapIdentityPath -PathType Leaf)) {
        throw 'Exact sustained bootstrap identity checkpoint is missing.'
    }

    $testRoot = Join-Path $runRoot '_setup\tooling-validation'
    Set-SustainedCampaignStatus `
        -Step 'tooling-validation' `
        -Detail 'Running focused parser and deterministic sustained campaign contracts.'
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    & (Join-Path $PSScriptRoot 'Test-SustainedCampaign.ps1') `
        -ResultPath (Join-Path $testRoot 'completion.json')
    $testResult =
        Get-Content `
            -LiteralPath (Join-Path $testRoot 'completion.json') `
            -Raw |
        ConvertFrom-Json
    if (-not $testResult.Valid -or $testResult.PlanRows -ne 24) {
        throw 'Focused sustained tooling validation failed.'
    }

    $preparationRoot = Join-Path $runRoot '_setup\preparation'
    Set-SustainedCampaignStatus `
        -Step 'workload-preparation' `
        -Detail 'Reusing dedicated pinned clones/worktrees and warming normal1..normal10 plus injected with exact FINAL.'
    & (Join-Path $PSScriptRoot 'Prepare-SustainedWorkloads.ps1') `
        -BootstrapIdentityPath $bootstrapIdentityPath `
        -OutputRoot $preparationRoot
    $preparationPath =
        Join-Path $preparationRoot 'preparation-completion.json'
    if (-not (Test-Path -LiteralPath $preparationPath -PathType Leaf)) {
        throw 'Sustained workload preparation checkpoint is missing.'
    }

    $pilotRoot = Join-Path $runRoot '_setup\pilots'
    Set-SustainedCampaignStatus `
        -Step 'excluded-pilots' `
        -Detail 'Running six real fixed-window pilots at eight workers, with at most one global rerun at ten.'
    $pilot = @(
        & (Join-Path $PSScriptRoot 'Run-SustainedPilots.ps1') `
            -BootstrapIdentityPath $bootstrapIdentityPath `
            -PreparationPath $preparationPath `
            -HardDeadlineUtc $hardDeadlineUtc `
            -OutputRoot $pilotRoot
    ) | Select-Object -Last 1
    if (-not $pilot.Valid -or
        [int]$pilot.FrozenWorkerCount -notin @(8, 10)) {
        throw 'Excluded sustained pilots did not freeze an approved worker count.'
    }
    $workerCount = [int]$pilot.FrozenWorkerCount

    foreach ($repository in $campaign.Repositories) {
        $repositoryRows = @(
            $plan.Rows |
                Where-Object Repository -eq $repository.Name
        )
        $blockNumbers = @(
            $repositoryRows.BlockNumber |
                Sort-Object -Unique
        )
        foreach ($blockNumber in $blockNumbers) {
            if ([DateTimeOffset]::UtcNow -ge $hardDeadlineUtc) {
                throw 'The total sustained campaign reached its hard eight-hour deadline.'
            }
            $blockRows = @(
                $repositoryRows |
                    Where-Object BlockNumber -eq $blockNumber |
                    Sort-Object OrderIndex
            )
            $blockRoot = Join-Path $runRoot (
                "sustained\$($repository.Name)\block-$('{0:D3}' -f $blockNumber)")
            New-Item -ItemType Directory -Force -Path $blockRoot | Out-Null
            $blockKind = if (
                ConvertTo-StrictBoolean -Value $blockRows[0].IsWarmup) {
                'excluded warmup'
            }
            else {
                'measured'
            }
            Set-SustainedCampaignStatus `
                -Step "$($repository.Name)-block-$blockNumber" `
                -Detail "Executing complete $blockKind block at frozen worker count $workerCount."
            $blockValid = $false
            for ($attempt = 1;
                $attempt -le $campaign.Validity.MaximumBlockAttempts;
                $attempt++) {
                if ([DateTimeOffset]::UtcNow -ge $hardDeadlineUtc) {
                    throw 'The total sustained campaign reached its hard eight-hour deadline.'
                }
                $attemptRoot = Join-Path $blockRoot (
                    "attempt-$('{0:D2}' -f $attempt)")
                New-Item -ItemType Directory -Path $attemptRoot | Out-Null
                if (($blockNumber -eq 1 -and $attempt -eq 1) -or
                    $attempt -gt 1) {
                    $resetReason = if ($attempt -gt 1) {
                        "Whole-block retry $attempt after declared external/harness invalidity."
                    }
                    else {
                        'Post-pilot reset before the declared warmup block.'
                    }
                    & (Join-Path $PSScriptRoot 'Reset-SustainedWorktrees.ps1') `
                        -BootstrapIdentityPath $bootstrapIdentityPath `
                        -PreparationPath $preparationPath `
                        -RepositoryName $repository.Name `
                        -WorkerCount $workerCount `
                        -Reason $resetReason `
                        -OutputRoot (
                            Join-Path $attemptRoot 'prepared-baseline-reset')
                }
                $attemptErrors = [Collections.Generic.List[string]]::new()
                $nonRetryable = [Collections.Generic.List[string]]::new()
                foreach ($row in $blockRows) {
                    if ([DateTimeOffset]::UtcNow -ge $hardDeadlineUtc) {
                        $nonRetryable.Add(
                            'The total campaign reached its hard eight-hour deadline.')
                        break
                    }
                    $scenarioRoot = Join-Path $attemptRoot (
                        "$('{0:D2}' -f [int]$row.OrderIndex)-$($row.Condition)")
                    $runIdentity = New-SustainedScenarioRunIdentity `
                        -Repository $repository.Name `
                        -Condition $row.Condition `
                        -BlockNumber $blockNumber `
                        -AttemptNumber $attempt `
                        -OrderIndex ([int]$row.OrderIndex) `
                        -WorkerCount $workerCount
                    try {
                        $validation = @(
                            & (Join-Path $PSScriptRoot 'Invoke-SustainedWindowScenario.ps1') `
                                -BootstrapIdentityPath $bootstrapIdentityPath `
                                -PreparationPath $preparationPath `
                                -RepositoryName $repository.Name `
                                -Condition $row.Condition `
                                -WorkerCount $workerCount `
                                -BlockNumber $blockNumber `
                                -AttemptNumber $attempt `
                                -OrderIndex ([int]$row.OrderIndex) `
                                -AnalysisBlockNumber (
                                    [int]$row.AnalysisBlockNumber) `
                                -IsWarmup (
                                    ConvertTo-StrictBoolean -Value $row.IsWarmup) `
                                -RunIdentity $runIdentity `
                                -HardDeadlineUtc $hardDeadlineUtc `
                                -ScenarioRoot $scenarioRoot
                        ) | Select-Object -Last 1
                    }
                    catch {
                        $attemptErrors.Add(
                            "$($row.Condition): scenario invocation threw: $($_.Exception.Message)")
                        break
                    }
                    if ($validation.Disposition -eq 'InvalidRetryable') {
                        $attemptErrors.Add(
                            "$($row.Condition): $(@($validation.HarnessErrors + $validation.ExternalValidityErrors) -join '; ')")
                        break
                    }
                    if ($validation.Disposition -ne 'Valid') {
                        $nonRetryable.Add(
                            "$($row.Condition): non-retriable '$($validation.Disposition)' $(@($validation.TestedConditionPolicyOutcomes + $validation.HarnessErrors + $validation.ExternalValidityErrors) -join '; ')")
                        break
                    }
                    if ($campaign.Validity.CooldownSeconds -gt 0) {
                        Start-Sleep `
                            -Seconds $campaign.Validity.CooldownSeconds
                    }
                }
                $attemptRecord = [pscustomobject][ordered]@{
                    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    Repository = $repository.Name
                    BlockNumber = $blockNumber
                    AnalysisBlockNumber =
                        [int]$blockRows[0].AnalysisBlockNumber
                    IsWarmup =
                        ConvertTo-StrictBoolean -Value $blockRows[0].IsWarmup
                    AttemptNumber = $attempt
                    WorkerCount = $workerCount
                    MaximumAttempts =
                        $campaign.Validity.MaximumBlockAttempts
                    Disposition = if ($nonRetryable.Count -gt 0) {
                        'NonRetryable'
                    }
                    elseif ($attemptErrors.Count -gt 0) {
                        'InvalidRetryable'
                    }
                    else {
                        'Valid'
                    }
                    Errors = $attemptErrors.ToArray()
                    NonRetryableErrors = $nonRetryable.ToArray()
                }
                $marker = if ($attemptRecord.Disposition -eq 'Valid') {
                    'valid-attempt.json'
                }
                elseif ($attemptRecord.Disposition -eq
                    'InvalidRetryable') {
                    'invalid-attempt.json'
                }
                else {
                    'nonretriable-attempt.json'
                }
                Write-JsonAtomic `
                    -Path (Join-Path $attemptRoot $marker) `
                    -Value $attemptRecord `
                    -Depth 8
                if ($nonRetryable.Count -gt 0) {
                    throw "Block '$blockRoot' stopped: $($nonRetryable -join '; ')"
                }
                if ($attemptErrors.Count -gt 0) {
                    continue
                }
                Write-JsonAtomic `
                    -Path (
                        Join-Path $blockRoot 'block-completion.json') `
                    -Value $attemptRecord `
                    -Depth 8
                $blockValid = $true
                break
            }
            if (-not $blockValid) {
                throw "Block '$blockRoot' exhausted the approved maximum of two whole-block attempts."
            }
        }
    }

    Set-SustainedCampaignStatus `
        -Step 'analysis' `
        -Detail 'Computing directional n=3 paired analysis with deterministic whole-block resamples and exact sign flips.'
    & (Join-Path $PSScriptRoot 'Analyze-SustainedCampaign.ps1') `
        -RunRoot $runRoot
    $analysisValidation =
        Get-Content `
            -LiteralPath (
                Join-Path $runRoot 'analysis\analysis-validation.json') `
            -Raw |
        ConvertFrom-Json
    if (-not $analysisValidation.Valid) {
        throw 'Sustained analysis validation failed.'
    }
    if ([DateTimeOffset]::UtcNow -ge $hardDeadlineUtc) {
        throw 'The total sustained campaign reached its hard eight-hour deadline before completion promotion.'
    }
    $completion = [pscustomobject][ordered]@{
        SchemaVersion = 1
        CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Valid = $true
        RunId = $RunId
        ResultRoot = $runRoot
        FrozenWorkerCount = $workerCount
        PlanRows = $plan.Rows.Count
        WarmupBlocks = 2
        MeasuredBlocks = 6
        MeasuredConditionRows = 18
        MaximumBlockAttempts =
            $campaign.Validity.MaximumBlockAttempts
        HardTimeoutHours = $campaign.HardTimeoutHours
        CompletedBeforeHardDeadline =
            [DateTimeOffset]::UtcNow -lt $hardDeadlineUtc
        NoAutomaticRelaunch = $true
        SanitizerPackagingInvoked = $false
    }
    Write-JsonAtomic `
        -Path (Join-Path $runRoot 'completion.json') `
        -Value $completion
    Set-SustainedCampaignStatus `
        -Step 'complete' `
        -Detail 'Sustained-only campaign and analysis completed; packaging remains uninvoked.' `
        -Status Succeeded
}
catch {
    $campaignError = $_.Exception
    Set-SustainedCampaignStatus `
        -Step 'failed' `
        -Detail $_.Exception.Message `
        -Status Failed
}
finally {
    if ($null -ne $keepAwake) {
        try {
            $restored = Disable-CampaignKeepAwake -State $keepAwake
            Write-JsonAtomic `
                -Path (Join-Path $runRoot 'keep-awake-restored.json') `
                -Value $restored
        }
        catch {
            if ($null -eq $campaignError) {
                $campaignError = $_.Exception
            }
            else {
                $campaignError = [AggregateException]::new(
                    'Campaign and keep-awake restoration failed.',
                    [Exception[]]@($campaignError, $_.Exception))
            }
        }
    }
    if ($mutexOwned) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
if ($null -ne $campaignError) {
    throw $campaignError
}
