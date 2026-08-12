[CmdletBinding(DefaultParameterSetName = 'New')]
param(
    [Parameter(ParameterSetName = 'New')]
    [string]$RunId,
    [Parameter(ParameterSetName = 'Resume', Mandatory)]
    [string]$ResumeRoot,
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
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')

$campaign = Get-CampaignDefinition
$plan = New-CampaignPlan
$planErrors = [Collections.Generic.List[string]]::new()
foreach ($shape in $campaign.Shapes) {
    $diagnostic = $plan.Diagnostics.PSObject.Properties[$shape.Key].Value
    if ($diagnostic.PositionImbalance -ne 0 -or $diagnostic.CarryoverImbalance -ne 0) {
        $planErrors.Add("$($shape.Key) measured design is not exactly position/carryover balanced.")
    }
    foreach ($condition in $shape.Conditions) {
        $normal = New-ConditionEnvironment `
            -Condition $condition `
            -PipeName 'plan-only-pipe' `
            -DotNetRoot 'C:\immutable-bootstrap' `
            -EnableDebugTrace `
            -DebugPath 'C:\trace'
        Assert-ConditionEnvironmentContract -Condition $condition -Environment $normal
        $injected = New-ConditionEnvironment `
            -Condition $condition `
            -PipeName 'plan-only-pipe' `
            -DotNetRoot 'C:\immutable-bootstrap' `
            -Injected `
            -EnableDebugTrace `
            -DebugPath 'C:\trace'
        Assert-ConditionEnvironmentContract -Condition $condition -Environment $injected -Injected
    }
}
if ($plan.Rows.Count -ne 82) {
    $planErrors.Add("Matrix has $($plan.Rows.Count) rows; expected exactly 82.")
}

if ($PlanOnly) {
    if ([string]::IsNullOrWhiteSpace($PlanOutputRoot)) {
        $PlanOutputRoot = Join-Path 'C:\perf\results' ("current-vs-final-plan-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    if (Test-Path -LiteralPath $PlanOutputRoot) {
        if (@(Get-ChildItem -LiteralPath $PlanOutputRoot -Force).Count -gt 0) {
            throw "Plan output '$PlanOutputRoot' already exists and is not empty."
        }
    }
    else {
        New-Item -ItemType Directory -Path $PlanOutputRoot | Out-Null
    }
    $root = (Resolve-Path -LiteralPath $PlanOutputRoot).Path
    $plan.Rows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $root 'matrix-plan.csv')
    Write-JsonAtomic -Path (Join-Path $root 'matrix-plan.json') -Value $plan.Rows -Depth 7
    Write-JsonAtomic -Path (Join-Path $root 'run-metadata.json') -Value ([pscustomobject][ordered]@{
        SchemaVersion = 1
        PlanOnly = $true
        CreatedUtc = [DateTime]::UtcNow.ToString('O')
        Campaign = $campaign
        Plan = $plan
    }) -Depth 15
    Write-JsonAtomic -Path (Join-Path $root 'plan-validation.json') -Value ([pscustomobject][ordered]@{
        Valid = $planErrors.Count -eq 0
        Errors = $planErrors.ToArray()
        ExpectedRows = 82
        ActualRows = $plan.Rows.Count
        Diagnostics = $plan.Diagnostics
    }) -Depth 10
    if ($planErrors.Count -gt 0) {
        throw "Plan validation failed: $($planErrors -join '; ')"
    }
    $positionMaximum = ($campaign.Shapes | ForEach-Object {
        $plan.Diagnostics.PSObject.Properties[$_.Key].Value.PositionImbalance
    } | Measure-Object -Maximum).Maximum
    $carryoverMaximum = ($campaign.Shapes | ForEach-Object {
        $plan.Diagnostics.PSObject.Properties[$_.Key].Value.CarryoverImbalance
    } | Measure-Object -Maximum).Maximum
    Write-Host "PLAN_ROOT=$root"
    Write-Host "PLAN_ROWS=$($plan.Rows.Count)"
    Write-Host "POSITION_IMBALANCE=$positionMaximum"
    Write-Host "CARRYOVER_IMBALANCE=$carryoverMaximum"
    return
}

Assert-WindowsCampaignHost
if ($planErrors.Count -gt 0) {
    throw "Plan validation failed: $($planErrors -join '; ')"
}
if ([Environment]::ProcessorCount -ne 16) {
    throw "The authoritative campaign requires exactly 16 logical processors; this process sees $([Environment]::ProcessorCount)."
}
$campaignMutexName = 'Global\MSBuild-PR14241-CurrentVsFinal-Campaign'
$campaignMutex = [Threading.Mutex]::new($false, $campaignMutexName)
$campaignMutexOwned = $false
try {
    $campaignMutexOwned = $campaignMutex.WaitOne(0)
}
catch [Threading.AbandonedMutexException] {
    $campaignMutexOwned = $true
}
if (-not $campaignMutexOwned) {
    $campaignMutex.Dispose()
    throw 'Another current-vs-final campaign process owns the global no-overlap mutex.'
}

$resuming = $PSCmdlet.ParameterSetName -eq 'Resume'
if ($resuming) {
    if (-not (Test-Path -LiteralPath $ResumeRoot -PathType Container)) {
        throw "Resume root '$ResumeRoot' does not exist."
    }
    $runRoot = (Resolve-Path -LiteralPath $ResumeRoot).Path
}
else {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = "current-vs-final-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    }
    if (-not $RunId.StartsWith('current-vs-final-', [StringComparison]::Ordinal)) {
        throw "RunId '$RunId' must start with 'current-vs-final-'."
    }
    $runRoot = Join-Path 'C:\perf\results' $RunId
    if (Test-Path -LiteralPath $runRoot) {
        throw "Fresh campaign root '$runRoot' already exists."
    }
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $runRoot = (Resolve-Path -LiteralPath $runRoot).Path
}
$runIdValue = Split-Path -Leaf $runRoot
$computerSystem = Get-CimInstance Win32_ComputerSystem
$operatingSystem = Get-CimInstance Win32_OperatingSystem
$processors = @(Get-CimInstance Win32_Processor)
Write-JsonAtomic -Path (Join-Path $runRoot 'machine.json') -Value ([pscustomobject][ordered]@{
    CapturedUtc = [DateTime]::UtcNow.ToString('O')
    ComputerName = $env:COMPUTERNAME
    OperatingSystem = $operatingSystem.Caption
    OperatingSystemVersion = $operatingSystem.Version
    ProcessorNames = @($processors.Name)
    LogicalProcessors = [Environment]::ProcessorCount
    TotalPhysicalMemoryBytes = [int64]$computerSystem.TotalPhysicalMemory
    AuthoritativeSixteenNodeHost = [Environment]::ProcessorCount -eq 16
})
$metadataPath = Join-Path $runRoot 'run-metadata.json'
$campaignProcessStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime()

function Set-CampaignStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Step,

        [string]$Detail,

        [ValidateSet('Running', 'Succeeded', 'Failed')]
        [string]$Status = 'Running'
    )

    $record = [pscustomobject][ordered]@{
        UpdatedUtc = [DateTime]::UtcNow.ToString('O')
        Status = $Status
        ProcessId = $PID
        ProcessStartUtc = $campaignProcessStartUtc.ToString('O')
        RunId = $runIdValue
        ResultRoot = $runRoot
        CurrentStep = $Step
        Detail = $Detail
        EstimatedTotalCampaignHours = '2-4 (strict projected maximum 4)'
    }
    Write-JsonAtomic -Path (Join-Path $runRoot 'status.json') -Value $record
    if (-not [string]::IsNullOrWhiteSpace($LaunchRoot)) {
        Write-JsonAtomic -Path (Join-Path $LaunchRoot 'status.json') -Value $record
    }
}

$toolingFiles = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
        Where-Object {
            $_.Extension -in @('.ps1', '.cs', '.csproj', '.proj', '.md') -and
                $_.FullName -notmatch '\\\.test-output\\'
        } |
        Sort-Object FullName |
        ForEach-Object { Get-FileSha256Record -Path $_.FullName -RelativeTo $PSScriptRoot }
)
$preservedMonitorPath = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\scripts\idle-tooling\Monitor-PublicRepoCoordinatorBenchmark.ps1'))
$externalProvenTooling = @(
    Get-FileSha256Record `
        -Path $preservedMonitorPath `
        -RelativeTo ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')))
)
if ($resuming) {
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Resume root '$runRoot' has no run metadata."
    }
    $recordedMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($recordedMetadata.Campaign.Base.Commit -ne $campaign.Base.Commit -or
        $recordedMetadata.Campaign.Final.Commit -ne $campaign.Final.Commit) {
        throw 'Resume metadata has different tested revisions.'
    }
    $recordedHashes = @($recordedMetadata.ToolingFiles | ForEach-Object { "$($_.Path)=$($_.Sha256)" })
    $currentHashes = @($toolingFiles | ForEach-Object { "$($_.Path)=$($_.Sha256)" })
    if (($recordedHashes -join "`n") -ne ($currentHashes -join "`n")) {
        throw 'Tooling changed since this campaign started; strict resume is refused.'
    }
    $recordedExternalHashes = @($recordedMetadata.ExternalProvenTooling | ForEach-Object { "$($_.Path)=$($_.Sha256)" })
    $currentExternalHashes = @($externalProvenTooling | ForEach-Object { "$($_.Path)=$($_.Sha256)" })
    if (($recordedExternalHashes -join "`n") -ne ($currentExternalHashes -join "`n")) {
        throw 'Preserved proven monitor changed since this campaign started; strict resume is refused.'
    }
}
else {
    $plan.Rows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $runRoot 'matrix-plan.csv')
    Write-JsonAtomic -Path (Join-Path $runRoot 'matrix-plan.json') -Value $plan.Rows -Depth 7
    Write-JsonAtomic -Path (Join-Path $runRoot 'plan-validation.json') -Value ([pscustomobject][ordered]@{
        Valid = $true
        Errors = @()
        ExpectedRows = 82
        ActualRows = $plan.Rows.Count
        Diagnostics = $plan.Diagnostics
    }) -Depth 10
    Write-JsonAtomic -Path $metadataPath -Value ([pscustomobject][ordered]@{
        SchemaVersion = 1
        RunId = $runIdValue
        CreatedUtc = [DateTime]::UtcNow.ToString('O')
        ResultRoot = $runRoot
        LaunchRoot = $LaunchRoot
        Campaign = $campaign
        MatrixPlanRows = $plan.Rows.Count
        PlanDiagnostics = $plan.Diagnostics
        ToolingRoot = $PSScriptRoot
        ToolingFiles = $toolingFiles
        ExternalProvenTooling = $externalProvenTooling
        SourceRepositoryRoot = $SourceRepositoryRoot
        BuildWorktreeRoot = $BuildWorktreeRoot
        BootstrapStagingRoot = $BootstrapStagingRoot
        RawArtifactsAreOutsideGit = $true
        NoOverlapMutex = $campaignMutexName
    }) -Depth 16
}
Write-Host "RUN_ROOT=$runRoot"
Set-CampaignStatus -Step 'initializing' -Detail 'Validated the exact matrix and durable result root.'

$keepAwake = $null
$campaignError = $null
try {
    $keepAwake = Enable-CampaignKeepAwake
    Write-JsonAtomic -Path (Join-Path $runRoot 'keep-awake-start.json') -Value $keepAwake

    $exactBuildRoot = Join-Path $runRoot '_setup\exact-build'
    Set-CampaignStatus -Step 'exact-builds' -Detail 'Building BASE and FINAL separately from clean detached exact revisions.'
    & (Join-Path $PSScriptRoot 'Build-ExactRevisions.ps1') `
        -SourceRepositoryRoot $SourceRepositoryRoot `
        -BuildWorktreeRoot $BuildWorktreeRoot `
        -BootstrapStagingRoot $BootstrapStagingRoot `
        -OutputRoot $exactBuildRoot `
        -SkipFetch:$SkipFetch
    $bootstrapIdentityPath = Join-Path $exactBuildRoot 'bootstrap-identities.json'
    if (-not (Test-Path -LiteralPath $bootstrapIdentityPath -PathType Leaf)) {
        throw 'Exact bootstrap identity checkpoint is missing.'
    }

    $toolingValidationPath = Join-Path $runRoot '_setup\tooling-validation\completion.json'
    Set-CampaignStatus -Step 'deterministic-tooling-validation' -Detail 'Parsing scripts and validating the exact lean PlanOnly matrix balance.'
    & (Join-Path $PSScriptRoot 'Test-Tooling.ps1') -ResultPath $toolingValidationPath
    $toolingValidation = Get-Content -LiteralPath $toolingValidationPath -Raw | ConvertFrom-Json
    if (-not $toolingValidation.Valid -or $toolingValidation.PlanRows -ne 82) {
        throw 'Deterministic tooling or exact lean PlanOnly validation failed.'
    }

    $preflightRoot = Join-Path $runRoot '_setup\preflight'
    Set-CampaignStatus -Step 'preflight-smoke' -Detail 'Running the exactly-once FINAL functional smoke and both-binary controller/trace smoke.'
    & (Join-Path $PSScriptRoot 'Run-PreflightValidation.ps1') `
        -BootstrapIdentityPath $bootstrapIdentityPath `
        -OutputRoot $preflightRoot
    if (-not (Test-Path -LiteralPath (Join-Path $preflightRoot 'completion.json') -PathType Leaf)) {
        throw 'Exactly-once preflight checkpoint is missing.'
    }

    $preparationRoot = Join-Path $runRoot '_setup\preparation'
    Set-CampaignStatus -Step 'workload-preparation' -Detail 'Creating, restoring, and warming the 19 pinned worktrees per repository outside timing.'
    & (Join-Path $PSScriptRoot 'Prepare-Workloads.ps1') `
        -BootstrapIdentityPath $bootstrapIdentityPath `
        -OutputRoot $preparationRoot
    $preparationPath = Join-Path $preparationRoot 'preparation-completion.json'
    if (-not (Test-Path -LiteralPath $preparationPath -PathType Leaf)) {
        throw 'Workload preparation checkpoint is missing.'
    }

    $directProjectSmokeRoot = Join-Path $runRoot '_setup\direct-project-smoke'
    Set-CampaignStatus -Step 'direct-project-smoke' -Detail 'Running one excluded direct FINAL-N isolated project smoke per repository.'
    & (Join-Path $PSScriptRoot 'Run-DirectProjectSmoke.ps1') `
        -BootstrapIdentityPath $bootstrapIdentityPath `
        -PreparationPath $preparationPath `
        -OutputRoot $directProjectSmokeRoot
    $directProjectSmoke = Get-Content `
        -LiteralPath (Join-Path $directProjectSmokeRoot 'completion.json') `
        -Raw |
        ConvertFrom-Json
    if (-not $directProjectSmoke.Valid -or @($directProjectSmoke.Smokes).Count -ne 2) {
        throw 'Direct isolated project smoke gate did not pass.'
    }

    $timingGateRoot = Join-Path $runRoot '_setup\project-timing-gate'
    Set-CampaignStatus -Step 'project-timing-gate' -Detail 'Running excluded actual sustained pilots for BASE, FINAL-N, and FINAL-H per repository and enforcing conservative four-hour and ability gates.'
    $runMetadataForTiming = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $campaignStartedUtc = [DateTime]::Parse([string]$runMetadataForTiming.CreatedUtc).ToUniversalTime()
    & (Join-Path $PSScriptRoot 'Run-ProjectTimingGate.ps1') `
        -BootstrapIdentityPath $bootstrapIdentityPath `
        -PreparationPath $preparationPath `
        -CampaignStartedUtc $campaignStartedUtc `
        -OutputRoot $timingGateRoot
    $timingGate = Get-Content -LiteralPath (Join-Path $timingGateRoot 'completion.json') -Raw | ConvertFrom-Json
    if (-not $timingGate.Passed -or [double]$timingGate.ProjectedTotalHours -gt 4) {
        throw 'Strict projected campaign gate did not pass; scope will not be reduced.'
    }
    Set-CampaignStatus `
        -Step 'measured-matrix' `
        -Detail "Lean project campaign projected at $([Math]::Round([double]$timingGate.ProjectedTotalHours, 3)) total hours; all strict gates passed."

    foreach ($shape in $campaign.Shapes) {
        Assert-FreeDiskSpace `
            -Path 'C:\' `
            -MinimumGiB $campaign.Validity.RawResultsReserveGiB `
            -RecordPath (Join-Path $runRoot "_checkpoints\disk-before-$($shape.Key).json") | Out-Null
        $shapeIdentityRecord = Get-Content -LiteralPath $bootstrapIdentityPath -Raw | ConvertFrom-Json
        [void](Test-ImmutableBootstrapStage `
            -Root $shapeIdentityRecord.Base.Root `
            -RecordPath (Join-Path $runRoot "_checkpoints\$($shape.Key)-base-stage-integrity.json"))
        [void](Test-ImmutableBootstrapStage `
            -Root $shapeIdentityRecord.Final.Root `
            -RecordPath (Join-Path $runRoot "_checkpoints\$($shape.Key)-final-stage-integrity.json"))
        $shapeRows = @($plan.Rows | Where-Object Shape -eq $shape.Key)
        foreach ($repository in $campaign.Repositories) {
            $repositoryRows = @($shapeRows | Where-Object Repository -eq $repository.Name)
            $blockNumbers = @($repositoryRows.BlockNumber | Sort-Object -Unique)
            foreach ($blockNumber in $blockNumbers) {
                $blockRows = @(
                    $repositoryRows |
                        Where-Object BlockNumber -eq $blockNumber |
                        Sort-Object OrderIndex
                )
                $blockRoot = Join-Path $runRoot "$($shape.Key)\$($repository.Name)\block-$('{0:D3}' -f $blockNumber)"
                Set-CampaignStatus `
                    -Step "$($shape.Key)-$($repository.Name)-block-$blockNumber" `
                    -Detail "Executing warm-up/measured whole block in predeclared Williams order."
                $blockCompletionPath = Join-Path $blockRoot 'block-completion.json'
                if (Test-Path -LiteralPath (Join-Path $blockRoot 'block-ability-gate-failure.json') -PathType Leaf) {
                    throw "Block '$blockRoot' previously failed the non-retriable sustained ability gate."
                }
                if (Test-Path -LiteralPath (Join-Path $blockRoot 'block-policy-outcome.json') -PathType Leaf) {
                    throw "Block '$blockRoot' previously recorded a non-retriable tested-condition policy outcome."
                }
                if (Test-Path -LiteralPath $blockCompletionPath -PathType Leaf) {
                    $existingCompletion = Get-Content -LiteralPath $blockCompletionPath -Raw | ConvertFrom-Json
                    if ($existingCompletion.Disposition -ne 'Valid') {
                        throw "Block checkpoint '$blockCompletionPath' is not valid."
                    }
                    continue
                }
                New-Item -ItemType Directory -Force -Path $blockRoot | Out-Null
                foreach ($incompleteAttempt in @(
                    Get-ChildItem -LiteralPath $blockRoot -Directory -Filter 'attempt-*' -ErrorAction SilentlyContinue
                )) {
                    $hasMarker = Test-Path -LiteralPath (Join-Path $incompleteAttempt.FullName 'valid-attempt.json') -PathType Leaf
                    $hasMarker = $hasMarker -or
                        (Test-Path -LiteralPath (Join-Path $incompleteAttempt.FullName 'invalid-attempt.json') -PathType Leaf) -or
                        (Test-Path -LiteralPath (Join-Path $incompleteAttempt.FullName 'policy-outcome-attempt.json') -PathType Leaf) -or
                        (Test-Path -LiteralPath (Join-Path $incompleteAttempt.FullName 'ability-gate-attempt.json') -PathType Leaf)
                    if (-not $hasMarker) {
                        $attemptNumber = [int]$incompleteAttempt.Name.Substring('attempt-'.Length)
                        Write-JsonAtomic -Path (Join-Path $incompleteAttempt.FullName 'invalid-attempt.json') -Value ([pscustomobject][ordered]@{
                            CompletedUtc = [DateTime]::UtcNow.ToString('O')
                            Shape = $shape.Key
                            Repository = $repository.Name
                            BlockNumber = $blockNumber
                            AnalysisBlockNumber = $blockRows[0].AnalysisBlockNumber
                            IsWarmup = [bool]$blockRows[0].IsWarmup
                            AttemptNumber = $attemptNumber
                            Disposition = 'InvalidRetryable'
                            Valid = $false
                            Errors = @('Interrupted or incomplete whole-block attempt discovered during strict resume.')
                            TestedConditionPolicyOutcomes = @()
                            CampaignAbilityGateErrors = @()
                        }) -Depth 8
                    }
                }
                $existingAttempts = @(
                    Get-ChildItem -LiteralPath $blockRoot -Directory -Filter 'attempt-*' -ErrorAction SilentlyContinue
                ).Count
                $blockValid = $false
                for ($attempt = $existingAttempts + 1;
                    $attempt -le $campaign.Validity.MaximumBlockAttempts;
                    $attempt++) {
                    $attemptRoot = Join-Path $blockRoot "attempt-$('{0:D2}' -f $attempt)"
                    New-Item -ItemType Directory -Path $attemptRoot | Out-Null
                    if ($attempt -gt 1) {
                        $resetRoot = Join-Path $attemptRoot 'prepared-baseline-reset'
                        & (Join-Path $PSScriptRoot 'Reset-PreparedWorktrees.ps1') `
                            -BootstrapIdentityPath $bootstrapIdentityPath `
                            -PreparationPath $preparationPath `
                            -RepositoryName $repository.Name `
                            -Shape $shape.Key `
                            -Reason "Whole-block retry $attempt after interrupted or externally invalid attempt." `
                            -OutputRoot $resetRoot
                        $resetCheckpoint = Get-Content `
                            -LiteralPath (Join-Path $resetRoot 'reset-completion.json') `
                            -Raw |
                            ConvertFrom-Json
                        $resetValidation = Test-WorktreeResetCheckpointRecord `
                            -Record $resetCheckpoint `
                            -Repository $repository.Name `
                            -Shape $shape.Key
                        if (-not $resetValidation.Valid) {
                            throw "Prepared baseline reset failed before retry attempt $attempt`: $($resetValidation.Errors -join '; ')"
                        }
                    }
                    $attemptErrors = [Collections.Generic.List[string]]::new()
                    $policyOutcomes = [Collections.Generic.List[string]]::new()
                    $abilityGateOutcomes = [Collections.Generic.List[string]]::new()
                    foreach ($row in $blockRows) {
                        $scenarioRoot = Join-Path $attemptRoot "$('{0:D2}' -f $row.OrderIndex)-$($row.Condition)"
                        try {
                            $validation = @(
                                & (Join-Path $PSScriptRoot 'Invoke-Scenario.ps1') `
                                    -BootstrapIdentityPath $bootstrapIdentityPath `
                                    -PreparationPath $preparationPath `
                                    -Shape $shape.Key `
                                    -RepositoryName $repository.Name `
                                    -Condition $row.Condition `
                                    -BlockNumber $blockNumber `
                                    -AttemptNumber $attempt `
                                    -OrderIndex $row.OrderIndex `
                                    -ScenarioRoot $scenarioRoot
                            ) | Select-Object -Last 1
                            if ($validation.Disposition -eq 'InvalidRetryable') {
                                $attemptErrors.Add("$($row.Condition): $(@($validation.HarnessErrors + $validation.ExternalValidityErrors) -join '; ')")
                                break
                            }
                            if ($validation.Disposition -eq 'TestedConditionPolicyOutcome') {
                                $policyOutcomes.Add("$($row.Condition): $(@($validation.TestedConditionPolicyOutcomes) -join '; ')")
                                break
                            }
                            if ($validation.Disposition -eq 'CampaignAbilityGateFailure') {
                                $abilityGateOutcomes.Add("$($row.Condition): $(@($validation.CampaignAbilityGateErrors) -join '; ')")
                                break
                            }
                            if ($validation.Disposition -ne 'Valid') {
                                $attemptErrors.Add("$($row.Condition): unknown disposition '$($validation.Disposition)'.")
                                break
                            }
                        }
                        catch {
                            $attemptErrors.Add("$($row.Condition): $($_.Exception.Message)")
                            break
                        }
                        if ($campaign.Validity.CooldownSeconds -gt 0) {
                            Start-Sleep -Seconds $campaign.Validity.CooldownSeconds
                        }
                    }
                    $disposition = if ($abilityGateOutcomes.Count -gt 0) {
                        'CampaignAbilityGateFailure'
                    }
                    elseif ($policyOutcomes.Count -gt 0) {
                        'TestedConditionPolicyOutcome'
                    }
                    elseif ($attemptErrors.Count -gt 0) {
                        'InvalidRetryable'
                    }
                    else {
                        'Valid'
                    }
                    $attemptRecord = [pscustomobject][ordered]@{
                        CompletedUtc = [DateTime]::UtcNow.ToString('O')
                        Shape = $shape.Key
                        Repository = $repository.Name
                        BlockNumber = $blockNumber
                        AnalysisBlockNumber = $blockRows[0].AnalysisBlockNumber
                        IsWarmup = [bool]$blockRows[0].IsWarmup
                        AttemptNumber = $attempt
                        Disposition = $disposition
                        Valid = $disposition -eq 'Valid'
                        Errors = $attemptErrors.ToArray()
                        TestedConditionPolicyOutcomes = $policyOutcomes.ToArray()
                        CampaignAbilityGateErrors = $abilityGateOutcomes.ToArray()
                    }
                    $attemptMarker = switch ($disposition) {
                        'Valid' { 'valid-attempt.json' }
                        'TestedConditionPolicyOutcome' { 'policy-outcome-attempt.json' }
                        'CampaignAbilityGateFailure' { 'ability-gate-attempt.json' }
                        default { 'invalid-attempt.json' }
                    }
                    Write-JsonAtomic -Path (Join-Path $attemptRoot $attemptMarker) -Value $attemptRecord -Depth 8
                    if ($disposition -eq 'Valid') {
                        Write-JsonAtomic -Path $blockCompletionPath -Value $attemptRecord -Depth 8
                        $blockValid = $true
                        break
                    }
                    if ($disposition -eq 'TestedConditionPolicyOutcome') {
                        Write-JsonAtomic -Path (Join-Path $blockRoot 'block-policy-outcome.json') -Value $attemptRecord -Depth 8
                        throw "Tested condition produced a non-retriable policy outcome: $($policyOutcomes -join '; ')"
                    }
                    if ($disposition -eq 'CampaignAbilityGateFailure') {
                        Write-JsonAtomic -Path (Join-Path $blockRoot 'block-ability-gate-failure.json') -Value $attemptRecord -Depth 8
                        throw "Sustained ability gate failed non-retriably: $($abilityGateOutcomes -join '; ')"
                    }
                }
                if (-not $blockValid) {
                    throw "$($shape.Key)/$($repository.Name)/block-$blockNumber failed all $($campaign.Validity.MaximumBlockAttempts) whole-block attempts."
                }
            }
        }
        Write-JsonAtomic -Path (Join-Path $runRoot "_checkpoints\$($shape.Key)-completion.json") -Value ([pscustomobject][ordered]@{
            CompletedUtc = [DateTime]::UtcNow.ToString('O')
            Shape = $shape.Key
            RepositoryCount = $campaign.Repositories.Count
            WarmupBlocksPerRepository = $shape.WarmupBlocks
            MeasuredBlocksPerRepository = $shape.MeasuredBlocks
        })
    }

    Write-JsonAtomic -Path (Join-Path $runRoot 'completion.json') -Value ([pscustomobject][ordered]@{
        Status = 'Succeeded'
        CompletedUtc = [DateTime]::UtcNow.ToString('O')
        RunId = $runIdValue
        ResultRoot = $runRoot
    })
    Set-CampaignStatus -Step 'complete' -Detail 'All shapes and paired blocks completed.' -Status Succeeded
}
catch {
    $campaignError = $_.Exception.ToString()
    Set-CampaignStatus -Step 'stopped' -Detail $_.Exception.Message -Status Failed
    Write-JsonAtomic -Path (Join-Path $runRoot 'failure.json') -Value ([pscustomobject][ordered]@{
        Status = 'Failed'
        FailedUtc = [DateTime]::UtcNow.ToString('O')
        RunId = $runIdValue
        ResultRoot = $runRoot
        Error = $campaignError
    }) -Depth 8
}
finally {
    if ($null -ne $keepAwake) {
        Write-JsonAtomic `
            -Path (Join-Path $runRoot 'keep-awake.json') `
            -Value (Disable-CampaignKeepAwake -State $keepAwake)
    }
    if ($campaignMutexOwned) {
        $campaignMutex.ReleaseMutex()
        $campaignMutexOwned = $false
    }
    $campaignMutex.Dispose()
    if (-not [string]::IsNullOrWhiteSpace($LaunchRoot)) {
        Write-JsonAtomic -Path (Join-Path $LaunchRoot 'campaign-completion.json') -Value ([pscustomobject][ordered]@{
            Status = if ($null -eq $campaignError) { 'Succeeded' } else { 'Failed' }
            CompletedUtc = [DateTime]::UtcNow.ToString('O')
            ProcessId = $PID
            RunId = $runIdValue
            ResultRoot = $runRoot
            Error = $campaignError
        }) -Depth 8
    }
}
if ($null -ne $campaignError) {
    throw $campaignError
}
Write-Host "CAMPAIGN_COMPLETION=$(Join-Path $runRoot 'completion.json')"
