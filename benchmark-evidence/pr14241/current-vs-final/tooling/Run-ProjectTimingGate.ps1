[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$PreparationPath,
    [Parameter(Mandatory)]
    [DateTimeOffset]$CampaignStartedUtc,
    [Parameter(Mandatory)]
    [string]$OutputRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')

$campaign = Get-CampaignDefinition
$completionPath = Join-Path $OutputRoot 'completion.json'
if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
    if (-not $existing.Passed) {
        throw "Existing sustained pilot gate '$completionPath' did not pass."
    }
    Write-Host "PROJECT_TIMING_GATE=$completionPath"
    return
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$pilotConditions = @('BASE', 'FINAL-N', 'FINAL-H')
$pilots = [Collections.Generic.List[object]]::new()
foreach ($repository in $campaign.Repositories) {
    for ($conditionIndex = 0; $conditionIndex -lt $pilotConditions.Count; $conditionIndex++) {
        $condition = $pilotConditions[$conditionIndex]
        $conditionRoot = Join-Path $OutputRoot "$($repository.Name)\$condition"
        $pilotCompletionPath = Join-Path $conditionRoot 'pilot-completion.json'
        $nonRetryableFailurePath = Join-Path $conditionRoot 'pilot-nonretriable-failure.json'
        if (Test-Path -LiteralPath $nonRetryableFailurePath -PathType Leaf) {
            throw "Excluded sustained pilot previously recorded a non-retriable failure at '$nonRetryableFailurePath'."
        }
        if (Test-Path -LiteralPath $pilotCompletionPath -PathType Leaf) {
            $pilot = Get-Content -LiteralPath $pilotCompletionPath -Raw | ConvertFrom-Json
            if (-not $pilot.Valid -or $pilot.Condition -ne $condition) {
                throw "Existing excluded sustained pilot '$pilotCompletionPath' is invalid."
            }
            if (-not (Test-Path -LiteralPath $pilot.MetricsPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $pilot.ValidationPath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $pilot.MetricsPath -Algorithm SHA256).Hash -ne $pilot.MetricsSha256 -or
                (Get-FileHash -LiteralPath $pilot.ValidationPath -Algorithm SHA256).Hash -ne $pilot.ValidationSha256) {
                throw "Existing excluded sustained pilot '$pilotCompletionPath' evidence identity changed."
            }
            $pilots.Add($pilot)
            continue
        }
        New-Item -ItemType Directory -Force -Path $conditionRoot | Out-Null
        foreach ($incompleteAttempt in @(
            Get-ChildItem -LiteralPath $conditionRoot -Directory -Filter 'attempt-*' -ErrorAction SilentlyContinue
        )) {
            $terminalPromotion = Get-InterruptedAttemptTerminalPromotion `
                -AttemptRoot $incompleteAttempt.FullName `
                -ResumeScope Pilot
            if ($null -ne $terminalPromotion) {
                $promotionRecord = [pscustomobject][ordered]@{
                    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    Disposition = $terminalPromotion.Disposition
                    Errors = @($terminalPromotion.Errors)
                    RetryAllowed = $false
                    InterruptedAttempt = $incompleteAttempt.FullName
                    TerminalOutcomes = @($terminalPromotion.TerminalOutcomes)
                }
                Write-JsonAtomic `
                    -Path (Join-Path $conditionRoot $terminalPromotion.PromotionMarkerName) `
                    -Value $promotionRecord `
                    -Depth 8
                throw "Excluded $($repository.Name)/$condition sustained pilot found a prior non-retriable terminal outcome: $(@($terminalPromotion.Errors) -join '; ')"
            }
            $hasMarker =
                (Test-Path -LiteralPath (Join-Path $incompleteAttempt.FullName 'valid-attempt.json') -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $incompleteAttempt.FullName 'invalid-attempt.json') -PathType Leaf)
            if (-not $hasMarker) {
                Write-JsonAtomic -Path (Join-Path $incompleteAttempt.FullName 'invalid-attempt.json') -Value ([pscustomobject][ordered]@{
                    CompletedUtc = [DateTime]::UtcNow.ToString('O')
                    Valid = $false
                    Disposition = 'InvalidRetryable'
                    Reason = 'Interrupted excluded sustained pilot attempt discovered during resume.'
                })
            }
        }
        $existingAttempts = @(
            Get-ChildItem -LiteralPath $conditionRoot -Directory -Filter 'attempt-*' -ErrorAction SilentlyContinue
        ).Count
        $validPilot = $null
        for ($attempt = $existingAttempts + 1;
            $attempt -le $campaign.Validity.MaximumBlockAttempts;
            $attempt++) {
            $attemptRoot = Join-Path $conditionRoot "attempt-$('{0:D2}' -f $attempt)"
            New-Item -ItemType Directory -Path $attemptRoot | Out-Null
            if ($attempt -gt 1) {
                & (Join-Path $PSScriptRoot 'Reset-PreparedWorktrees.ps1') `
                    -BootstrapIdentityPath $BootstrapIdentityPath `
                    -PreparationPath $PreparationPath `
                    -RepositoryName $repository.Name `
                    -Shape sustained `
                    -Reason "Excluded sustained pilot retry $attempt after interrupted or externally invalid attempt." `
                    -OutputRoot (Join-Path $attemptRoot 'prepared-baseline-reset')
            }
            $scenarioRoot = Join-Path $attemptRoot 'scenario'
            try {
                $validation = @(
                    & (Join-Path $PSScriptRoot 'Invoke-Scenario.ps1') `
                        -BootstrapIdentityPath $BootstrapIdentityPath `
                        -PreparationPath $PreparationPath `
                        -Shape sustained `
                        -RepositoryName $repository.Name `
                        -Condition $condition `
                        -BlockNumber 0 `
                        -AttemptNumber $attempt `
                        -OrderIndex ($conditionIndex + 1) `
                        -ScenarioRoot $scenarioRoot
                ) | Select-Object -Last 1
            }
            catch {
                $terminalOutcome = Get-ScenarioTerminalOutcome -ScenarioRoot $scenarioRoot
                if ($null -ne $terminalOutcome) {
                    $validation = [pscustomobject]@{
                        Disposition = [string]$terminalOutcome.Disposition
                        RetryAllowed = $false
                        HarnessErrors = @()
                        ExternalValidityErrors = @()
                        CampaignAbilityGateErrors = if ($terminalOutcome.Disposition -eq 'CampaignAbilityGateFailure') {
                            @($terminalOutcome.Errors)
                        }
                        else {
                            @()
                        }
                        TestedConditionPolicyOutcomes = if ($terminalOutcome.Disposition -eq 'TestedConditionPolicyOutcome') {
                            @($terminalOutcome.Errors)
                        }
                        else {
                            @()
                        }
                        TerminalErrors = @($terminalOutcome.Errors)
                    }
                }
                else {
                    $validation = [pscustomobject]@{
                        Disposition = 'InvalidRetryable'
                        RetryAllowed = $true
                        HarnessErrors = @($_.Exception.Message)
                        ExternalValidityErrors = @()
                    }
                }
            }
            if ($validation.Disposition -eq 'CampaignAbilityGateFailure') {
                Write-JsonAtomic -Path $nonRetryableFailurePath -Value ([pscustomobject][ordered]@{
                    CompletedUtc = [DateTime]::UtcNow.ToString('O')
                    Disposition = $validation.Disposition
                    Errors = $validation.CampaignAbilityGateErrors
                    RetryAllowed = $false
                })
                throw "Excluded $($repository.Name)/$condition sustained pilot failed the non-retriable 12-completion/10-minute ability gate: $(@($validation.CampaignAbilityGateErrors) -join '; ')"
            }
            if ($validation.Disposition -eq 'TestedConditionPolicyOutcome') {
                Write-JsonAtomic -Path $nonRetryableFailurePath -Value ([pscustomobject][ordered]@{
                    CompletedUtc = [DateTime]::UtcNow.ToString('O')
                    Disposition = $validation.Disposition
                    Errors = $validation.TestedConditionPolicyOutcomes
                    RetryAllowed = $false
                })
                throw "Excluded $($repository.Name)/$condition sustained pilot produced a tested-condition policy outcome: $(@($validation.TestedConditionPolicyOutcomes) -join '; ')"
            }
            if ($validation.PSObject.Properties['RetryAllowed'] -and
                -not (ConvertTo-StrictBoolean -Value $validation.RetryAllowed) -and
                $validation.Disposition -ne 'Valid') {
                $terminalErrors = if ($validation.PSObject.Properties['TerminalErrors']) {
                    @($validation.TerminalErrors)
                }
                else {
                    @("Non-retriable scenario outcome '$($validation.Disposition)'.")
                }
                Write-JsonAtomic -Path $nonRetryableFailurePath -Value ([pscustomobject][ordered]@{
                    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    Disposition = $validation.Disposition
                    Errors = $terminalErrors
                    RetryAllowed = $false
                })
                throw "Excluded $($repository.Name)/$condition sustained pilot stopped after a non-retriable scenario failure: $($terminalErrors -join '; ')"
            }
            if ($validation.Disposition -ne 'Valid') {
                Write-JsonAtomic -Path (Join-Path $attemptRoot 'invalid-attempt.json') -Value ([pscustomobject][ordered]@{
                    CompletedUtc = [DateTime]::UtcNow.ToString('O')
                    Valid = $false
                    Disposition = 'InvalidRetryable'
                    Errors = @($validation.HarnessErrors + $validation.ExternalValidityErrors)
                }) -Depth 8
                continue
            }

            $metricsPath = Join-Path $scenarioRoot 'scenario-metrics.json'
            $controllerPath = Join-Path $scenarioRoot 'controller-summary.json'
            $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
            $controller = Get-Content -LiteralPath $controllerPath -Raw | ConvertFrom-Json
            $abilityPassed =
                [int]$controller.MeasuredNormalCompletions -eq $campaign.Validity.SustainedEndingCompletion -and
                [double]$metrics.SteadyWindowSeconds -le ($campaign.Validity.SustainedTimeoutMinutes * 60)
            $validPilot = [pscustomobject][ordered]@{
                SchemaVersion = 1
                CompletedUtc = [DateTime]::UtcNow.ToString('O')
                Valid = $abilityPassed
                Repository = $repository.Name
                RepositoryCommit = $repository.Commit
                WorkloadKind = 'representative-propagated-project-sustained-pilot'
                BuildPath = $repository.BuildPath
                TouchPath = $repository.TouchPath
                Condition = $condition
                BaseOneNodeSaturationCovered = $condition -eq 'BASE'
                FinalNormalCovered = $condition -eq 'FINAL-N'
                FinalHighInjectionCovered = $condition -eq 'FINAL-H'
                AttemptNumber = $attempt
                ExcludedFromMeasuredAnalysis = $true
                InitialNormalWorkers = 18
                InjectedWorkers = 1
                MeasuredNormalCompletions = [int]$controller.MeasuredNormalCompletions
                InjectionAfterCompletion = $campaign.Validity.SustainedInjectionCompletion
                SteadyWindowSeconds = [double]$metrics.SteadyWindowSeconds
                TotalWallSeconds = [double]$metrics.TotalWallSeconds
                DrainSeconds = [double]$metrics.DrainSeconds
                QueueNonemptyFraction = [double]$metrics.QueueNonemptyFraction
                SemanticBridgedHandoffCount = [int]$metrics.SemanticBridgedHandoffCount
                SemanticHandoffGapToleranceSeconds = [double]$metrics.SemanticHandoffGapToleranceSeconds
                AbilityLimitSeconds = $campaign.Validity.SustainedTimeoutMinutes * 60
                TwelveCompletionsWithinTenMinutes = $abilityPassed
                ScenarioRoot = $scenarioRoot
                MetricsPath = $metricsPath
                ValidationPath = Join-Path $scenarioRoot 'scenario-validation.json'
                MetricsSha256 = (Get-FileHash -LiteralPath $metricsPath -Algorithm SHA256).Hash
                ValidationSha256 = (Get-FileHash -LiteralPath (Join-Path $scenarioRoot 'scenario-validation.json') -Algorithm SHA256).Hash
            }
            if (-not $abilityPassed) {
                Write-JsonAtomic -Path $nonRetryableFailurePath -Value ([pscustomobject][ordered]@{
                    CompletedUtc = [DateTime]::UtcNow.ToString('O')
                    Disposition = 'CampaignAbilityGateFailure'
                    Errors = @('Pilot metrics did not prove 12 completions within 10 minutes.')
                    RetryAllowed = $false
                })
                throw "Excluded $($repository.Name)/$condition sustained pilot did not prove 12 completions within 10 minutes."
            }
            Write-JsonAtomic -Path (Join-Path $attemptRoot 'valid-attempt.json') -Value $validPilot -Depth 8
            Write-JsonAtomic -Path $pilotCompletionPath -Value $validPilot -Depth 8
            break
        }
        if ($null -eq $validPilot) {
            if (-not (Test-Path -LiteralPath $pilotCompletionPath -PathType Leaf)) {
                throw "Excluded $($repository.Name)/$condition sustained pilot exhausted all $($campaign.Validity.MaximumBlockAttempts) validity attempts."
            }
            $validPilot = Get-Content -LiteralPath $pilotCompletionPath -Raw | ConvertFrom-Json
        }
        $pilots.Add($validPilot)
    }
}

$setupElapsedSeconds = ([DateTimeOffset]::UtcNow - $CampaignStartedUtc.ToUniversalTime()).TotalSeconds
$projection = Get-LeanCampaignProjection `
    -RepositoryTimings $pilots.ToArray() `
    -SetupElapsedSeconds $setupElapsedSeconds
$result = [pscustomobject][ordered]@{
    SchemaVersion = 2
    CompletedUtc = [DateTime]::UtcNow.ToString('O')
    WorkloadKind = 'representative-propagated-project-sustained-pilot'
    WorkloadDeviation = $campaign.WorkloadDeviation
    PilotConditions = $pilotConditions
    PilotCount = $pilots.Count
    PilotsPerRepository = $pilotConditions.Count
    PilotsExcluded = $true
    Pilots = $pilots.ToArray()
    ProjectionFormula = 'Each condition uses 1.25 times its actual sustained-pilot total wall (including ramp, 12-completion steady window, and drain) as an upper bound for every isolated or sustained matrix scenario of that condition. COMPAT uses 1.25 times the maximum observed BASE/FINAL pilot wall. Add all 41 per-repository cooldowns and all elapsed build/stage/smoke/preparation/pilot time.'
    RuntimeProjectionSafetyFactor = $campaign.RuntimeProjectionSafetyFactor
    IsolatedScenariosPerRepository = $projection.IsolatedScenariosPerRepository
    SustainedScenariosPerRepository = $projection.SustainedScenariosPerRepository
    RepositoryUpperBounds = $projection.RepositoryUpperBounds
    SetupElapsedSeconds = $projection.SetupElapsedSeconds
    ProjectedMatrixSeconds = $projection.ProjectedMatrixSeconds
    ProjectedTotalSeconds = $projection.ProjectedTotalSeconds
    ProjectedTotalHours = $projection.ProjectedTotalHours
    MaximumProjectedCampaignHours = $projection.MaximumProjectedCampaignHours
    RuntimeProjectionPassed = $projection.RuntimeProjectionPassed
    SustainedAbilityProjection = 'Every excluded BASE, FINAL-N, and FINAL-H pilot must actually complete the 18-outstanding, inject-after-6, end-at-12, drain scenario and reach completion 12 within 600 seconds after onset.'
    SustainedAbilityProjectionPassed = $projection.SustainedAbilityProjectionPassed
    ActualSustainedAbilityGate = 'Every measured sustained scenario independently enforces the same 12-completion/10-minute non-retriable gate.'
    ScopeReductionOnGateFailure = $false
    Passed = $projection.Passed
}
Write-JsonAtomic -Path $completionPath -Value $result -Depth 12
if (-not $projection.SustainedAbilityProjectionPassed) {
    throw 'Excluded representative sustained pilots did not all pass the actual ability gate; stop and report rather than reducing scope.'
}
if (-not $projection.RuntimeProjectionPassed) {
    throw "Conservative pilot projection is $([Math]::Round($projection.ProjectedTotalHours, 3)) hours, exceeding the strict four-hour gate; stop and report rather than reducing scope."
}
Write-Host "PROJECT_TIMING_GATE=$completionPath"
