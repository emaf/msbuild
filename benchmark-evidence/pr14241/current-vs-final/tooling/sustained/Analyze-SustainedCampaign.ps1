[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot,
    [string]$OutputRoot = (Join-Path $RunRoot 'analysis')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Analysis.Common.ps1')

$campaign = Get-CampaignDefinition
$metadata =
    Get-Content `
        -LiteralPath (Join-Path $RunRoot 'run-metadata.json') `
        -Raw |
    ConvertFrom-Json
if ($metadata.Campaign.Base.Commit -ne $campaign.Base.Commit -or
    $metadata.Campaign.Final.Commit -ne $campaign.Final.Commit -or
    $metadata.Campaign.Final.Branch -ne $campaign.Final.Branch) {
    throw 'Run metadata does not contain the exact approved sustained revisions.'
}
$plan = @(
    Import-Csv -LiteralPath (Join-Path $RunRoot 'matrix-plan.csv')
)
$planObject = New-SustainedCampaignPlan
$planValidation = Test-SustainedCampaignPlan -Plan $planObject
if (-not $planValidation.Valid) {
    throw "Compiled sustained plan is invalid: $($planValidation.Errors -join '; ')"
}
$pilotPath = Join-Path $RunRoot '_setup\pilots\pilot-completion.json'
if (-not (Test-Path -LiteralPath $pilotPath -PathType Leaf)) {
    throw 'Excluded sustained pilot completion is missing.'
}
$pilot =
    Get-Content -LiteralPath $pilotPath -Raw |
    ConvertFrom-Json
if (-not $pilot.Valid -or
    [int]$pilot.FrozenWorkerCount -notin @(8, 10)) {
    throw 'Excluded sustained pilot completion is invalid.'
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$errors = [Collections.Generic.List[string]]::new()
$metricRows = [Collections.Generic.List[object]]::new()
$rawRows = [Collections.Generic.List[object]]::new()
$excludedRows = [Collections.Generic.List[object]]::new()
foreach ($row in $plan | Where-Object IsWarmup -eq 'True') {
    $excludedRows.Add([pscustomobject][ordered]@{
        Kind = 'DeclaredWarmup'
        Repository = $row.Repository
        BlockNumber = [int]$row.BlockNumber
        Condition = $row.Condition
        Reason = 'One complete warmup block per repository is excluded from paired analysis.'
    })
}
foreach ($selectedPilot in $pilot.SelectedPilots) {
    $excludedRows.Add([pscustomobject][ordered]@{
        Kind = 'WorkerSizingPilot'
        Repository = $selectedPilot.Repository
        BlockNumber = 0
        Condition = $selectedPilot.Condition
        Reason = 'Real representative worker-sizing pilot is excluded from measured analysis.'
    })
}

foreach ($repository in $campaign.Repositories) {
    $measuredPlan = @(
        $plan |
            Where-Object {
                $_.Repository -eq $repository.Name -and
                $_.IsWarmup -eq 'False'
            }
    )
    $analysisBlocks = @(
        $measuredPlan.AnalysisBlockNumber |
            Sort-Object -Unique
    )
    if (($analysisBlocks -join ',') -ne '1,2,3') {
        $errors.Add("$($repository.Name) measured blocks are '$($analysisBlocks -join ',')'; expected 1,2,3.")
        continue
    }
    foreach ($analysisBlock in $analysisBlocks) {
        $blockRows = @(
            $measuredPlan |
                Where-Object AnalysisBlockNumber -eq $analysisBlock |
                Sort-Object OrderIndex
        )
        $blockNumber = [int]$blockRows[0].BlockNumber
        $blockRoot = Join-Path $RunRoot (
            "sustained\$($repository.Name)\block-$('{0:D3}' -f $blockNumber)")
        $completionPath = Join-Path $blockRoot 'block-completion.json'
        if (-not (Test-Path -LiteralPath $completionPath -PathType Leaf)) {
            $errors.Add("Missing valid block completion '$completionPath'.")
            continue
        }
        $completion =
            Get-Content -LiteralPath $completionPath -Raw |
            ConvertFrom-Json
        if ($completion.Disposition -ne 'Valid' -or
            [int]$completion.WorkerCount -ne
                [int]$pilot.FrozenWorkerCount) {
            $errors.Add("Block completion '$completionPath' is invalid or uses a different worker count.")
            continue
        }
        $attemptRoot = Join-Path $blockRoot (
            "attempt-$('{0:D2}' -f [int]$completion.AttemptNumber)")
        foreach ($row in $blockRows) {
            $scenarioRoot = Join-Path $attemptRoot (
                "$('{0:D2}' -f [int]$row.OrderIndex)-$($row.Condition)")
            $validationPath =
                Join-Path $scenarioRoot 'scenario-validation.json'
            $metricsPath =
                Join-Path $scenarioRoot 'scenario-metrics.json'
            if (-not (Test-Path -LiteralPath $validationPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $metricsPath -PathType Leaf)) {
                $errors.Add("Missing validation or metrics under '$scenarioRoot'.")
                continue
            }
            $validation =
                Get-Content -LiteralPath $validationPath -Raw |
                ConvertFrom-Json
            $metrics =
                Get-Content -LiteralPath $metricsPath -Raw |
                ConvertFrom-Json
            $expectedIdentity = New-SustainedScenarioRunIdentity `
                -Repository $repository.Name `
                -Condition $row.Condition `
                -BlockNumber $blockNumber `
                -AttemptNumber ([int]$completion.AttemptNumber) `
                -OrderIndex ([int]$row.OrderIndex) `
                -WorkerCount ([int]$pilot.FrozenWorkerCount)
            if (-not $validation.Valid -or
                $validation.Disposition -ne 'Valid' -or
                $validation.IsWarmup -or
                $metrics.IsWarmup -or
                $validation.RunIdentity -ne $expectedIdentity -or
                $metrics.RunIdentity -ne $expectedIdentity -or
                $validation.Repository -ne $repository.Name -or
                $metrics.Repository -ne $repository.Name -or
                $validation.Condition -ne $row.Condition -or
                $metrics.Condition -ne $row.Condition -or
                [int]$validation.AnalysisBlockNumber -ne
                    [int]$analysisBlock -or
                [int]$metrics.AnalysisBlockNumber -ne
                    [int]$analysisBlock -or
                [int]$metrics.WorkerCount -ne
                    [int]$pilot.FrozenWorkerCount -or
                [double]$metrics.MeasuredWindowSeconds -ne 480 -or
                $metrics.OldTwelveCompletionTenMinuteGateApplied) {
                $errors.Add("Scenario identity or fixed-window contract mismatch under '$scenarioRoot'.")
                continue
            }
            $metricRows.Add([pscustomobject][ordered]@{
                Repository = $repository.Name
                AnalysisBlockNumber = [int]$analysisBlock
                Condition = $row.Condition
                OrderIndex = [int]$row.OrderIndex
                RunIdentity = $expectedIdentity
                MetricsPath =
                    [IO.Path]::GetRelativePath($RunRoot, $metricsPath)
                Metrics = $metrics
            })
            $rawRows.Add([pscustomobject][ordered]@{
                Repository = $repository.Name
                AnalysisBlockNumber = [int]$analysisBlock
                Condition = $row.Condition
                OrderIndex = [int]$row.OrderIndex
                WorkerCount = [int]$metrics.WorkerCount
                MeasuredWindowSeconds =
                    [double]$metrics.MeasuredWindowSeconds
                MeasuredNormalCompletionCount =
                    [int]$metrics.MeasuredNormalCompletionCount
                OverallNormalThroughputPerSecond =
                    [double]$metrics.OverallNormalThroughputPerSecond
                PreInjectionNormalThroughputPerSecond =
                    [double]$metrics.PreInjectionNormalThroughputPerSecond
                PostInjectionNormalThroughputPerSecond =
                    [double]$metrics.PostInjectionNormalThroughputPerSecond
                AverageCompletedNormalLatencySeconds =
                    [double]$metrics.AverageCompletedNormalLatencySeconds
                InjectedRequestToGrantSeconds =
                    [double]$metrics.InjectedRequestToGrantSeconds
                InjectedRequestToCompletionSeconds =
                    [double]$metrics.InjectedRequestToCompletionSeconds
                QueueDepthP95 = [double]$metrics.QueueDepthP95
                QueueNonemptyTimeFraction =
                    [double]$metrics.QueueNonemptyTimeFraction
                QueueNonemptySampleFraction =
                    [double]$metrics.QueueNonemptySampleFraction
                PeakCommittedBytes =
                    [double]$metrics.SteadyResource.PeakCommittedBytes
                PeakDescendantWorkingSetBytes =
                    [double]$metrics.SteadyResource.PeakDescendantWorkingSetBytes
                PeakDescendantPrivateBytes =
                    [double]$metrics.SteadyResource.PeakDescendantPrivateBytes
                PeakDescendantProcessCount =
                    [double]$metrics.SteadyResource.PeakDescendantProcessCount
                InjectedPriority =
                    $metrics.GrantPolicyEvidence.TraceInjectedPriority
                PromptReserveBehaviorObserved =
                    [bool]$metrics.GrantPolicyEvidence.PromptReserveBehaviorObserved
                MetricsPath =
                    [IO.Path]::GetRelativePath($RunRoot, $metricsPath)
            })
        }
    }
}

$metricDefinitions = @(
    [pscustomobject]@{
        Path = 'MeasuredNormalCompletionCount'
        Direction = 'higher'
        PlainName = 'Normal completions in the fixed eight-minute window'
        SeedOffset = 1
    },
    [pscustomobject]@{
        Path = 'OverallNormalThroughputPerSecond'
        Direction = 'higher'
        PlainName = 'Normal throughput across the fixed eight-minute window'
        SeedOffset = 2
    },
    [pscustomobject]@{
        Path = 'PreInjectionNormalThroughputPerSecond'
        Direction = 'higher'
        PlainName = 'Normal throughput before the minute-four probe'
        SeedOffset = 3
    },
    [pscustomobject]@{
        Path = 'PostInjectionNormalThroughputPerSecond'
        Direction = 'higher'
        PlainName = 'Normal throughput after the minute-four probe'
        SeedOffset = 4
    },
    [pscustomobject]@{
        Path = 'AverageCompletedNormalLatencySeconds'
        Direction = 'lower'
        PlainName = 'Average latency of completed Normal builds'
        SeedOffset = 5
    },
    [pscustomobject]@{
        Path = 'InjectedRequestToGrantSeconds'
        Direction = 'lower'
        PlainName = 'Injected probe request-to-grant latency'
        SeedOffset = 6
    },
    [pscustomobject]@{
        Path = 'InjectedRequestToCompletionSeconds'
        Direction = 'lower'
        PlainName = 'Injected probe request-to-completion latency'
        SeedOffset = 7
    },
    [pscustomobject]@{
        Path = 'QueueDepthP95'
        Direction = 'lower'
        PlainName = 'Time-weighted queue-depth p95'
        SeedOffset = 8
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakCommittedBytes'
        Direction = 'lower'
        PlainName = 'Peak system committed bytes'
        SeedOffset = 9
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakDescendantWorkingSetBytes'
        Direction = 'lower'
        PlainName = 'Peak descendant working set'
        SeedOffset = 10
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakDescendantPrivateBytes'
        Direction = 'lower'
        PlainName = 'Peak descendant private bytes'
        SeedOffset = 11
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakDescendantProcessCount'
        Direction = 'lower'
        PlainName = 'Peak descendant process count'
        SeedOffset = 12
    }
)
$comparisons = @(
    [pscustomobject]@{
        Baseline = 'BASE'
        Candidate = 'FINAL-N'
        SeedOffset = 0
        Purpose = 'Normal-policy FINAL versus unchanged BASE'
    },
    [pscustomobject]@{
        Baseline = 'FINAL-N'
        Candidate = 'FINAL-H'
        SeedOffset = 100
        Purpose = 'High injected probe versus otherwise identical FINAL Normal policy'
    }
)
$pairedRows = [Collections.Generic.List[object]]::new()
$estimates = [Collections.Generic.List[object]]::new()
if ($metricRows.Count -eq 18 -and $errors.Count -eq 0) {
    for ($repositoryIndex = 0;
        $repositoryIndex -lt $campaign.Repositories.Count;
        $repositoryIndex++) {
        $repository = $campaign.Repositories[$repositoryIndex]
        foreach ($comparison in $comparisons) {
            foreach ($metric in $metricDefinitions) {
                $pairs = [Collections.Generic.List[object]]::new()
                foreach ($block in 1..3) {
                    $baselineRow = $metricRows |
                        Where-Object {
                            $_.Repository -eq $repository.Name -and
                            $_.AnalysisBlockNumber -eq $block -and
                            $_.Condition -eq $comparison.Baseline
                        } |
                        Select-Object -First 1
                    $candidateRow = $metricRows |
                        Where-Object {
                            $_.Repository -eq $repository.Name -and
                            $_.AnalysisBlockNumber -eq $block -and
                            $_.Condition -eq $comparison.Candidate
                        } |
                        Select-Object -First 1
                    if ($null -eq $baselineRow -or
                        $null -eq $candidateRow) {
                        $errors.Add("$($repository.Name)/block-$block/$($comparison.Candidate)-vs-$($comparison.Baseline)/$($metric.Path) is missing.")
                        continue
                    }
                    $baselineValue = Get-NestedValue `
                        -InputObject $baselineRow.Metrics `
                        -PropertyPath $metric.Path
                    $candidateValue = Get-NestedValue `
                        -InputObject $candidateRow.Metrics `
                        -PropertyPath $metric.Path
                    if ($null -eq $baselineValue -or
                        $null -eq $candidateValue -or
                        [double]$baselineValue -le 0 -or
                        [double]$candidateValue -le 0) {
                        $errors.Add("$($repository.Name)/block-$block/$($comparison.Candidate)-vs-$($comparison.Baseline)/$($metric.Path) is missing or nonpositive.")
                        continue
                    }
                    $pair = [pscustomobject][ordered]@{
                        Repository = $repository.Name
                        AnalysisBlockNumber = $block
                        BaselineCondition = $comparison.Baseline
                        CandidateCondition = $comparison.Candidate
                        Metric = $metric.Path
                        BaselineValue = [double]$baselineValue
                        CandidateValue = [double]$candidateValue
                        LogRatio =
                            [Math]::Log(
                                [double]$candidateValue /
                                [double]$baselineValue)
                    }
                    $pairs.Add($pair)
                    $pairedRows.Add($pair)
                }
                if ($pairs.Count -eq 3) {
                    $seed =
                        [int]$campaign.Shapes[0].Seed +
                        [int]$comparison.SeedOffset +
                        [int]$metric.SeedOffset +
                        ($repositoryIndex * 1000)
                    try {
                        $estimate = New-PairedEstimate `
                            -Pairs $pairs.ToArray() `
                            -Shape sustained `
                            -Repository $repository.Name `
                            -Baseline $comparison.Baseline `
                            -Candidate $comparison.Candidate `
                            -Metric $metric.Path `
                            -PreferredDirection $metric.Direction `
                            -Seed $seed
                        $estimate |
                            Add-Member `
                                -NotePropertyName MetricPlainName `
                                -NotePropertyValue $metric.PlainName
                        $estimate |
                            Add-Member `
                                -NotePropertyName ComparisonPurpose `
                                -NotePropertyValue $comparison.Purpose
                        $estimates.Add($estimate)
                    }
                    catch {
                        $errors.Add($_.Exception.Message)
                    }
                }
            }
        }
    }
}
if ($metricRows.Count -ne 18) {
    $errors.Add("Collected $($metricRows.Count) measured condition rows; expected exactly 18.")
}

$rawRows |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $OutputRoot 'raw-metrics.csv')
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'raw-metrics.json') `
    -Value $rawRows.ToArray() `
    -Depth 10
$pairedRows |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $OutputRoot 'paired-values.csv')
$estimates |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $OutputRoot 'comparisons.csv')
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'comparisons.json') `
    -Value $estimates.ToArray() `
    -Depth 10
$excludedRows |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $OutputRoot 'declared-exclusions.csv')

$formulaRecord = [pscustomobject][ordered]@{
    EffectPercent =
        '100 * (exp(mean(log(candidate / baseline))) - 1)'
    Pairing =
        'Within repository and measured block; each estimate has n=3 complete block pairs.'
    Interval =
        'Nearest-rank 95% interval from exactly 10,000 deterministic whole-block resamples of the three paired log ratios.'
    SignFlip =
        'Exact two-sided sign flip over all 2^3 = 8 paired sign assignments.'
    MinimumAttainableTwoSidedExactP = 0.25
    Directional = $true
    RepositoriesPooled = $false
    HistoricalCampaignsPooled = $false
    Seeds = @(
        $estimates |
            Select-Object Repository,Comparison,Metric,Seed
    )
}
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'formulas.json') `
    -Value $formulaRecord `
    -Depth 8

$headlineDefinitions = @(
    [pscustomobject]@{
        Comparison = 'FINAL-N-vs-BASE'
        Metric = 'OverallNormalThroughputPerSecond'
        Label = 'FINAL Normal throughput vs BASE'
    },
    [pscustomobject]@{
        Comparison = 'FINAL-H-vs-FINAL-N'
        Metric = 'InjectedRequestToGrantSeconds'
        Label = 'High probe grant latency vs FINAL Normal probe'
    },
    [pscustomobject]@{
        Comparison = 'FINAL-H-vs-FINAL-N'
        Metric = 'InjectedRequestToCompletionSeconds'
        Label = 'High probe completion latency vs FINAL Normal probe'
    },
    [pscustomobject]@{
        Comparison = 'FINAL-H-vs-FINAL-N'
        Metric = 'PostInjectionNormalThroughputPerSecond'
        Label = 'Normal throughput after High vs Normal probe'
    }
)
$headlines = @(
    foreach ($definition in $headlineDefinitions) {
        foreach ($repository in $campaign.Repositories) {
            $estimate = $estimates |
                Where-Object {
                    $_.Repository -eq $repository.Name -and
                    $_.Comparison -eq $definition.Comparison -and
                    $_.Metric -eq $definition.Metric
                } |
                Select-Object -First 1
            if ($null -eq $estimate) {
                $errors.Add("Headline '$($definition.Label)' is missing '$($repository.Name)'.")
                continue
            }
            [pscustomobject][ordered]@{
                Label = $definition.Label
                Repository = $repository.Name
                Comparison = $estimate.Comparison
                Metric = $estimate.Metric
                BaselineMean = $estimate.BaselineArithmeticMean
                CandidateMean = $estimate.CandidateArithmeticMean
                EffectPercent = $estimate.EffectPercent
                ConfidenceIntervalLowerPercent =
                    $estimate.ConfidenceIntervalLowerPercent
                ConfidenceIntervalUpperPercent =
                    $estimate.ConfidenceIntervalUpperPercent
                ExactTwoSidedSignFlipP =
                    $estimate.ExactTwoSidedSignFlipP
                PlainEnglish = $estimate.Interpretation
                Formula = $estimate.Formula
            }
        }
    }
)
$headlines |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $OutputRoot 'pr-facing-table.csv')

$analysis = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CreatedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    RunRoot = [IO.Path]::GetFullPath($RunRoot)
    Campaign = $campaign.Name
    FixedWindowSeconds = 480
    InjectionOffsetSeconds = 240
    FrozenWorkerCount = [int]$pilot.FrozenWorkerCount
    Pairing = $formulaRecord.Pairing
    DirectionalInference = $true
    PairedBlocksPerEstimate = 3
    ResampleIterations = 10000
    ExactSignFlipPermutationCount = 8
    MinimumAttainableTwoSidedExactP = 0.25
    Formula = $formulaRecord.EffectPercent
    Estimates = $estimates.ToArray()
    Headlines = $headlines
    Exclusions = $excludedRows.ToArray()
}
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'analysis.json') `
    -Value $analysis `
    -Depth 12
$validation = [pscustomobject][ordered]@{
    Valid = $errors.Count -eq 0
    Errors = $errors.ToArray()
    RawMeasuredRows = $rawRows.Count
    ExpectedRawMeasuredRows = 18
    EstimateRows = $estimates.Count
    ExpectedEstimateRows =
        $campaign.Repositories.Count *
        $comparisons.Count *
        $metricDefinitions.Count
    PairedBlocksPerEstimate = 3
    ResampleIterations = 10000
    ExactSignFlipPermutationCount = 8
    DirectionalInference = $true
    PositionBalanced = $planObject.Diagnostics.PositionBalanced
    CarryoverBalanced = $planObject.Diagnostics.CarryoverBalanced
    CarryoverDeclaration =
        $planObject.Diagnostics.CarryoverDeclaration
    WarmupExcluded = $true
    PilotsExcluded = $true
    ProbeExcludedFromNormalThroughput = $true
    RepositoriesPooled = $false
    HistoricalCampaignsPooled = $false
}
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'analysis-validation.json') `
    -Value $validation `
    -Depth 8

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Sustained-only current-vs-final analysis')
$lines.Add('')
$lines.Add('- Raw input: `raw-metrics.csv` contains exactly the 18 measured condition rows; the two complete warmup blocks and six selected pilots are declared exclusions.')
$lines.Add('- Pairing: within repository and measured block, n=3. Roslyn and Aspire are never pooled.')
$lines.Add('- Formula: `100 * (exp(mean(log(candidate / baseline))) - 1)`.')
$lines.Add('- Interval: 10,000 deterministic whole-block resamples. Test: exact two-sided 2^3 sign flips.')
$lines.Add('- Directional inference: the minimum attainable two-sided exact p-value at n=3 is 0.25; results are not described as high-powered confirmation.')
$lines.Add('- Normal throughput excludes the injected probe and always uses the fixed 480-second denominator.')
$lines.Add('')
$lines.Add('## Headline comparisons')
$lines.Add('')
$lines.Add('| Comparison | Repository | Metric | Baseline mean | Candidate mean | Effect | 95% interval | Exact p | Plain English |')
$lines.Add('|---|---|---|---:|---:|---:|---:|---:|---|')
foreach ($row in $headlines) {
    $lines.Add(
        "| $($row.Comparison) | $($row.Repository) | $($row.Metric) | " +
        "$([double]$row.BaselineMean).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) | " +
        "$([double]$row.CandidateMean).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) | " +
        "$([double]$row.EffectPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)% | " +
        "[$([double]$row.ConfidenceIntervalLowerPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)%, $([double]$row.ConfidenceIntervalUpperPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)%] | " +
        "$([double]$row.ExactTwoSidedSignFlipP).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) | " +
        "$($row.PlainEnglish) |")
}
$lines.Add('')
$lines.Add('## Complete directional estimates')
$lines.Add('')
foreach ($estimate in $estimates) {
    $lines.Add(
        "- **$($estimate.Repository), $($estimate.Comparison), $($estimate.Metric)**: " +
        "$($estimate.Interpretation) 95% whole-block interval " +
        "[$([double]$estimate.ConfidenceIntervalLowerPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)%, " +
        "$([double]$estimate.ConfidenceIntervalUpperPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)%], " +
        "exact p=$([double]$estimate.ExactTwoSidedSignFlipP).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture).")
}
[IO.File]::WriteAllLines(
    (Join-Path $OutputRoot 'report.md'),
    $lines,
    [Text.UTF8Encoding]::new($false))

if (-not $validation.Valid) {
    throw "Sustained analysis validation failed: $($errors -join '; ')"
}
Write-Host "ANALYSIS_ROOT=$OutputRoot"
