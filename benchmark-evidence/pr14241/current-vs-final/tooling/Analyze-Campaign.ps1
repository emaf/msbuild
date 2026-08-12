[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot,
    [string]$OutputRoot = (Join-Path $RunRoot 'analysis')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
. (Join-Path $PSScriptRoot 'Analysis.Common.ps1')

$campaign = Get-CampaignDefinition
$metadata = Get-Content -LiteralPath (Join-Path $RunRoot 'run-metadata.json') -Raw | ConvertFrom-Json
if ($metadata.Campaign.Base.Commit -ne $campaign.Base.Commit -or
    $metadata.Campaign.Final.Commit -ne $campaign.Final.Commit) {
    throw 'Run metadata does not contain the exact campaign revisions.'
}
$plan = @(Import-Csv -LiteralPath (Join-Path $RunRoot 'matrix-plan.csv'))
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$errors = [Collections.Generic.List[string]]::new()
$metricRows = [Collections.Generic.List[object]]::new()
$exclusions = [Collections.Generic.List[object]]::new()
$pilotGatePath = Join-Path $RunRoot '_setup\project-timing-gate\completion.json'
$pilotGate = if (Test-Path -LiteralPath $pilotGatePath -PathType Leaf) {
    Get-Content -LiteralPath $pilotGatePath -Raw | ConvertFrom-Json
}
else {
    $errors.Add('Excluded sustained pilot/runtime gate completion is missing.')
    $null
}
if ($null -ne $pilotGate -and -not $pilotGate.Passed) {
    $errors.Add('Excluded sustained pilot/runtime gate did not pass.')
}

foreach ($invalidMarker in @(
    Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter 'invalid-attempt.json' -ErrorAction SilentlyContinue
)) {
    $record = Get-Content -LiteralPath $invalidMarker.FullName -Raw | ConvertFrom-Json
    $exclusions.Add([pscustomobject][ordered]@{
        Shape = $record.Shape
        Repository = $record.Repository
        BlockNumber = $record.BlockNumber
        AnalysisBlockNumber = $record.AnalysisBlockNumber
        AttemptNumber = $record.AttemptNumber
        Reason = @($record.Errors) -join '; '
        RecordPath = [IO.Path]::GetRelativePath($RunRoot, $invalidMarker.FullName)
    })
}

foreach ($shape in $campaign.Shapes) {
    foreach ($repository in $campaign.Repositories) {
        $measuredPlan = @(
            $plan |
                Where-Object {
                    $_.Shape -eq $shape.Key -and
                        $_.Repository -eq $repository.Name -and
                        $_.IsWarmup -eq 'False'
                }
        )
        $analysisBlocks = @($measuredPlan.AnalysisBlockNumber | Sort-Object -Unique)
        if ($analysisBlocks.Count -ne $shape.MeasuredBlocks) {
            $errors.Add("$($shape.Key)/$($repository.Name) plan has $($analysisBlocks.Count) measured blocks; expected $($shape.MeasuredBlocks).")
            continue
        }
        foreach ($analysisBlock in $analysisBlocks) {
            $blockRows = @($measuredPlan | Where-Object AnalysisBlockNumber -eq $analysisBlock)
            $blockNumber = [int]$blockRows[0].BlockNumber
            $blockRoot = Join-Path $RunRoot "$($shape.Key)\$($repository.Name)\block-$('{0:D3}' -f $blockNumber)"
            $completionPath = Join-Path $blockRoot 'block-completion.json'
            if (-not (Test-Path -LiteralPath $completionPath -PathType Leaf)) {
                $errors.Add("Missing valid block completion '$completionPath'.")
                continue
            }
            $completion = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
            if ($completion.Disposition -ne 'Valid') {
                $errors.Add("Invalid block completion '$completionPath'.")
                continue
            }
            $attemptRoot = Join-Path $blockRoot "attempt-$('{0:D2}' -f [int]$completion.AttemptNumber)"
            foreach ($row in $blockRows) {
                $scenarioRoot = Join-Path $attemptRoot "$('{0:D2}' -f [int]$row.OrderIndex)-$($row.Condition)"
                $validationPath = Join-Path $scenarioRoot 'scenario-validation.json'
                $metricsPath = Join-Path $scenarioRoot 'scenario-metrics.json'
                if (-not (Test-Path -LiteralPath $validationPath -PathType Leaf) -or
                    -not (Test-Path -LiteralPath $metricsPath -PathType Leaf)) {
                    $errors.Add("Missing validation or metrics under '$scenarioRoot'.")
                    continue
                }
                $validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
                if (-not $validation.ValidForAnalysis -or $validation.Disposition -ne 'Valid') {
                    $errors.Add("Scenario '$scenarioRoot' is not valid for analysis.")
                    continue
                }
                $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
                $identity = Test-ScenarioEvidenceIdentity `
                    -PlanRow $row `
                    -BlockCompletion $completion `
                    -Validation $validation `
                    -Metrics $metrics
                if (-not $identity.Valid) {
                    $errors.Add("Scenario identity mismatch under '$scenarioRoot': $($identity.Errors -join '; ')")
                    continue
                }
                $metricRows.Add([pscustomobject][ordered]@{
                    Shape = [string]$metrics.Shape
                    Repository = [string]$metrics.Repository
                    AnalysisBlockNumber = [int]$metrics.AnalysisBlockNumber
                    Condition = [string]$metrics.Condition
                    OrderIndex = [int]$metrics.OrderIndex
                    RunIdentity = [string]$metrics.RunIdentity
                    MetricsPath = [IO.Path]::GetRelativePath($RunRoot, $metricsPath)
                    Metrics = $metrics
                })
            }
        }
    }
}

$metricDefinitions = [ordered]@{
    isolated = @(
        [pscustomobject]@{ Path = 'EndToEndSeconds'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'CoordinatorNegotiationSeconds'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakCommittedBytes'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakDescendantWorkingSetBytes'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakDescendantPrivateBytes'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakDescendantProcessCount'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.DescendantCpuSeconds'; Direction = 'lower' }
    )
    sustained = @(
        [pscustomobject]@{ Path = 'OverallNormalThroughputPerSecond'; Direction = 'higher' },
        [pscustomobject]@{ Path = 'PreInjectionNormalThroughputPerSecond'; Direction = 'higher' },
        [pscustomobject]@{ Path = 'PostInjectionNormalThroughputPerSecond'; Direction = 'higher' },
        [pscustomobject]@{ Path = 'InjectedRequestToGrantSeconds'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'InjectedRequestToCompletionSeconds'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'TotalWallSeconds'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'QueueDepthP95'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakCommittedBytes'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakDescendantWorkingSetBytes'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakDescendantPrivateBytes'; Direction = 'lower' },
        [pscustomobject]@{ Path = 'Resource.PeakDescendantProcessCount'; Direction = 'lower' }
    )
}
$comparisonsByShape = [ordered]@{
    isolated = @(
        [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'COMPAT' },
        [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'FINAL-N' }
    )
    sustained = @(
        [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'COMPAT' },
        [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'FINAL-N' },
        [pscustomobject]@{ Baseline = 'FINAL-N'; Candidate = 'FINAL-H' }
    )
}

$pairedRows = [Collections.Generic.List[object]]::new()
$estimates = [Collections.Generic.List[object]]::new()
if ($errors.Count -eq 0) {
    foreach ($shape in $campaign.Shapes) {
        foreach ($repository in $campaign.Repositories) {
            foreach ($comparison in $comparisonsByShape[$shape.Key]) {
                foreach ($metric in $metricDefinitions[$shape.Key]) {
                    $pairs = [Collections.Generic.List[object]]::new()
                    for ($block = 1; $block -le $shape.MeasuredBlocks; $block++) {
                        $baselineRow = $metricRows |
                            Where-Object {
                                $_.Shape -eq $shape.Key -and
                                    $_.Repository -eq $repository.Name -and
                                    $_.AnalysisBlockNumber -eq $block -and
                                    $_.Condition -eq $comparison.Baseline
                            } |
                            Select-Object -First 1
                        $candidateRow = $metricRows |
                            Where-Object {
                                $_.Shape -eq $shape.Key -and
                                    $_.Repository -eq $repository.Name -and
                                    $_.AnalysisBlockNumber -eq $block -and
                                    $_.Condition -eq $comparison.Candidate
                            } |
                            Select-Object -First 1
                        $baselineValue = Get-NestedValue -InputObject $baselineRow.Metrics -PropertyPath $metric.Path
                        $candidateValue = Get-NestedValue -InputObject $candidateRow.Metrics -PropertyPath $metric.Path
                        if ($null -eq $baselineValue -or $null -eq $candidateValue) {
                            $errors.Add("$($shape.Key)/$($repository.Name)/block-$block/$($metric.Path) is missing.")
                            continue
                        }
                        $pair = [pscustomobject][ordered]@{
                            Shape = $shape.Key
                            Repository = $repository.Name
                            AnalysisBlockNumber = $block
                            BaselineCondition = $comparison.Baseline
                            CandidateCondition = $comparison.Candidate
                            Metric = $metric.Path
                            BaselineValue = [double]$baselineValue
                            CandidateValue = [double]$candidateValue
                            LogRatio = if ([double]$baselineValue -gt 0 -and [double]$candidateValue -gt 0) {
                                [Math]::Log([double]$candidateValue / [double]$baselineValue)
                            }
                            else {
                                $null
                            }
                        }
                        $pairs.Add($pair)
                        $pairedRows.Add($pair)
                    }
                    if ($pairs.Count -eq $shape.MeasuredBlocks) {
                        try {
                            $estimates.Add((New-PairedEstimate `
                                -Pairs $pairs.ToArray() `
                                -Shape $shape.Key `
                                -Repository $repository.Name `
                                -Baseline $comparison.Baseline `
                                -Candidate $comparison.Candidate `
                                -Metric $metric.Path `
                                -PreferredDirection $metric.Direction `
                                -Seed $shape.Seed))
                        }
                        catch {
                            $errors.Add($_.Exception.Message)
                        }
                    }
                }
            }
        }
    }
}

$pairedRows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputRoot 'paired-values.csv')
$estimates | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputRoot 'comparisons.csv')
$exclusions | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputRoot 'declared-exclusions.csv')
$expectedMetricScenarioRows = 68
if ($metricRows.Count -ne $expectedMetricScenarioRows) {
    $errors.Add("Collected $($metricRows.Count) measured condition rows; expected $expectedMetricScenarioRows.")
}

$headlineDefinitions = @(
    [pscustomobject]@{
        Row = 'Isolated build'
        Shape = 'isolated'
        Comparison = 'FINAL-N-vs-BASE'
        Metric = 'EndToEndSeconds'
    },
    [pscustomobject]@{
        Row = 'Sustained Normal contention'
        Shape = 'sustained'
        Comparison = 'FINAL-N-vs-BASE'
        Metric = 'OverallNormalThroughputPerSecond'
    },
    [pscustomobject]@{
        Row = 'Sustained contention with High injection'
        Shape = 'sustained'
        Comparison = 'FINAL-H-vs-FINAL-N'
        Metric = 'InjectedRequestToCompletionSeconds'
    },
    [pscustomobject]@{
        Row = 'Explicit 0/0 compatibility control'
        Shape = 'isolated'
        Comparison = 'COMPAT-vs-BASE'
        Metric = 'EndToEndSeconds'
    }
)
$headlineRows = @(
    foreach ($headline in $headlineDefinitions) {
        $roslyn = $estimates |
            Where-Object {
                $_.Shape -eq $headline.Shape -and
                    $_.Repository -eq 'roslyn' -and
                    $_.Comparison -eq $headline.Comparison -and
                    $_.Metric -eq $headline.Metric
            } |
            Select-Object -First 1
        $aspire = $estimates |
            Where-Object {
                $_.Shape -eq $headline.Shape -and
                    $_.Repository -eq 'aspire' -and
                    $_.Comparison -eq $headline.Comparison -and
                    $_.Metric -eq $headline.Metric
            } |
            Select-Object -First 1
        if ($null -eq $roslyn -or $null -eq $aspire) {
            $errors.Add("Headline row '$($headline.Row)' is missing a repository-specific estimate.")
            continue
        }
        [pscustomobject][ordered]@{
            WorkloadShape = $headline.Row
            Comparison = $headline.Comparison
            Metric = $headline.Metric
            Formula = $roslyn.Formula
            RoslynBaselineMean = $roslyn.BaselineArithmeticMean
            RoslynCandidateMean = $roslyn.CandidateArithmeticMean
            RoslynEffectPercent = $roslyn.EffectPercent
            RoslynConfidenceIntervalLowerPercent = $roslyn.ConfidenceIntervalLowerPercent
            RoslynConfidenceIntervalUpperPercent = $roslyn.ConfidenceIntervalUpperPercent
            RoslynExactP = $roslyn.ExactTwoSidedSignFlipP
            AspireBaselineMean = $aspire.BaselineArithmeticMean
            AspireCandidateMean = $aspire.CandidateArithmeticMean
            AspireEffectPercent = $aspire.EffectPercent
            AspireConfidenceIntervalLowerPercent = $aspire.ConfidenceIntervalLowerPercent
            AspireConfidenceIntervalUpperPercent = $aspire.ConfidenceIntervalUpperPercent
            AspireExactP = $aspire.ExactTwoSidedSignFlipP
            PlainLanguage = "Roslyn: $($roslyn.Interpretation) Aspire: $($aspire.Interpretation)"
            RepositoriesPooled = $false
        }
    }
)
$headlineRows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputRoot 'pr-facing-table.csv')
Write-JsonAtomic -Path (Join-Path $OutputRoot 'analysis.json') -Value ([pscustomobject][ordered]@{
    SchemaVersion = 1
    CreatedUtc = [DateTime]::UtcNow.ToString('O')
    RunRoot = $RunRoot
    Pairing = 'Within repository and measured analysis block; repositories are never pooled.'
    WorkloadKind = 'representative-propagated-project'
    WorkloadDeviation = $campaign.WorkloadDeviation
    Formula = '100 * (exp(mean(log(candidate / baseline))) - 1)'
    Resampling = '10,000 deterministic whole-block resamples'
    SignFlip = 'Exact two-sided paired sign flips'
    Seeds = [pscustomobject]@{ isolated = 20260812; sustained = 20260814 }
    Estimates = $estimates.ToArray()
    HeadlineRows = $headlineRows
    ExcludedSustainedPilotGate = $pilotGate
    Exclusions = $exclusions.ToArray()
}) -Depth 12
Write-JsonAtomic -Path (Join-Path $OutputRoot 'analysis-validation.json') -Value ([pscustomobject][ordered]@{
    Valid = $errors.Count -eq 0
    Errors = $errors.ToArray()
    MetricScenarioRows = $metricRows.Count
    PairedValueRows = $pairedRows.Count
    EstimateRows = $estimates.Count
    ResampleIterations = 10000
    ExpectedPairedBlocks = [pscustomobject]@{ isolated = 6; sustained = 4 }
    DirectionalInference = $true
    ExactPDiscretenessReported = $true
    RepositoriesPooled = $false
    HistoricalCampaignsPooled = $false
    HistoricalFullSolutionAndNodeMatricesRole = 'Supporting evidence only'
    CompatibilityPostHocTolerance = $null
}) -Depth 8

$lines = [Collections.Generic.List[string]]::new()
$pilotProjectedHoursText = if ($null -eq $pilotGate) {
    'missing'
}
else {
    ([double]$pilotGate.ProjectedTotalHours).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
}
$lines.Add('# Current-vs-final deterministic paired analysis')
$lines.Add('')
$lines.Add('- Pairing: within repository and measured block; Roslyn and Aspire are not pooled.')
$lines.Add("- Workload scope: representative propagated projects. $($campaign.WorkloadDeviation)")
$lines.Add("- Pre-measurement gate: six excluded actual sustained pilots (BASE, FINAL-N, FINAL-H per repository) covered ramp, 12-completion window, injection, and drain. Projected total: $pilotProjectedHoursText hours; strict maximum: 4 hours.")
$lines.Add('- Effect: `100 * (exp(mean(log(candidate / baseline))) - 1)`.')
$lines.Add('- Interval: 10,000 deterministic whole-block resamples; p-value: exact two-sided sign flips.')
$lines.Add('- Inference is directional: isolated n=6 has minimum attainable two-sided exact p=0.03125; sustained n=4 has minimum 0.125. This discreteness is reported rather than overstating power.')
$lines.Add('- BASE one-node saturation under sustained backlog is an explicit measured mechanism, not an exclusion.')
$lines.Add('- BASE versus COMPAT is an explicit 0/0 overhead control; no post-hoc equivalence tolerance is imposed.')
$lines.Add('')
$lines.Add('## PR-facing contemporaneous summary')
$lines.Add('')
$lines.Add('| Workload shape | Comparison | Metric | Roslyn effect | Aspire effect | Plain language |')
$lines.Add('|---|---|---|---:|---:|---|')
foreach ($row in $headlineRows) {
    $lines.Add(
        "| $($row.WorkloadShape) | $($row.Comparison) | $($row.Metric) | " +
        "$([double]$row.RoslynEffectPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)% | " +
        "$([double]$row.AspireEffectPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)% | " +
        "$($row.PlainLanguage) |")
}
$lines.Add('')
$lines.Add('Repository-specific values are shown separately; no cross-repository pooling is used.')
$lines.Add('')
$lines.Add('## Complete paired estimates')
$lines.Add('')
$lines.Add('| Shape | Repository | Comparison | Metric | BASELINE mean | CANDIDATE mean | Effect | 95% interval | Exact p | Interpretation |')
$lines.Add('|---|---|---|---|---:|---:|---:|---:|---:|---|')
foreach ($estimate in $estimates) {
    $lines.Add(
        "| $($estimate.Shape) | $($estimate.Repository) | $($estimate.Comparison) | $($estimate.Metric) | " +
        "$([double]$estimate.BaselineArithmeticMean).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) | " +
        "$([double]$estimate.CandidateArithmeticMean).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) | " +
        "$([double]$estimate.EffectPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)% | " +
        "[$([double]$estimate.ConfidenceIntervalLowerPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)%, " +
        "$([double]$estimate.ConfidenceIntervalUpperPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)%] | " +
        "$([double]$estimate.ExactTwoSidedSignFlipP).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) | " +
        "$($estimate.Interpretation) |")
}
$lines | Set-Content -LiteralPath (Join-Path $OutputRoot 'report.md') -Encoding utf8
if ($errors.Count -gt 0) {
    throw "Analysis validation failed: $($errors -join '; ')"
}
Write-Host "ANALYSIS_ROOT=$OutputRoot"
