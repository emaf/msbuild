[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolingRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolingRoot 'Analysis.Common.ps1')

$analysisRoot = Join-Path $RunRoot 'analysis'
$evidenceRoot = Join-Path $RunRoot 'evidence'
New-Item -ItemType Directory -Force -Path $analysisRoot,$evidenceRoot | Out-Null

$scenarioRows = [Collections.Generic.List[object]]::new()
foreach ($completionPath in Get-ChildItem `
    -LiteralPath (Join-Path $RunRoot 'measured') `
    -Filter 'block-completion.json' `
    -Recurse `
    -File) {
    $completion =
        Get-Content -LiteralPath $completionPath.FullName -Raw |
        ConvertFrom-Json
    if (-not $completion.Valid) {
        throw "Invalid measured completion '$($completionPath.FullName)'."
    }
    $attemptRoot =
        Join-Path $completionPath.Directory.FullName (
            "attempt-$('{0:D2}' -f [int]$completion.Attempt)")
    foreach ($metricsPath in Get-ChildItem `
        -LiteralPath $attemptRoot `
        -Filter 'scenario-metrics.json' `
        -Recurse `
        -File) {
        $metrics =
            Get-Content -LiteralPath $metricsPath.FullName -Raw |
            ConvertFrom-Json
        if (-not $metrics.Valid) {
            throw "Invalid measured scenario '$($metricsPath.FullName)'."
        }
        $scenarioRows.Add([pscustomobject][ordered]@{
            Repository = $metrics.Repository
            AnalysisBlock = [int]$completion.AnalysisBlock
            Condition = $metrics.Condition
            MetricsPath =
                [IO.Path]::GetRelativePath($RunRoot, $metricsPath.FullName)
            Metrics = $metrics
        })
    }
}
if ($scenarioRows.Count -ne 18) {
    throw "Expected 18 measured scenarios; found $($scenarioRows.Count)."
}

$raw = @(
    foreach ($row in $scenarioRows) {
        $metrics = $row.Metrics
        [pscustomobject][ordered]@{
            Repository = $row.Repository
            AnalysisBlock = $row.AnalysisBlock
            Condition = $row.Condition
            NormalCompletions = $metrics.MeasuredNormalCompletionCount
            NormalThroughputPerMinute = $metrics.NormalThroughputPerMinute
            AverageNormalLatencySeconds =
                $metrics.AverageCompletedNormalLatencySeconds
            ProbeRequestToGrantSeconds =
                $metrics.InjectedRequestToGrantSeconds
            ProbeRequestToCompletionSeconds =
                $metrics.InjectedRequestToCompletionSeconds
            QueueDepthP95 = $metrics.QueueDepthP95
            QueueNonemptyTimeFraction =
                $metrics.QueueNonemptyTimeFraction
            AverageAllocatedNodes = $metrics.AverageAllocatedNodes
            AverageUnusedNodes = $metrics.AverageUnusedNodes
            AverageSystemCpuPercent =
                $metrics.SteadyResource.AverageSystemCpuPercent
            PeakCommittedBytes =
                $metrics.SteadyResource.PeakCommittedBytes
            PeakDescendantWorkingSetBytes =
                $metrics.SteadyResource.PeakDescendantWorkingSetBytes
            PeakDescendantPrivateBytes =
                $metrics.SteadyResource.PeakDescendantPrivateBytes
            PeakDescendantProcessCount =
                $metrics.SteadyResource.PeakDescendantProcessCount
            DescendantCpuSeconds =
                $metrics.SteadyResource.DescendantCpuSeconds
            ActualGrantCount = $metrics.ActualGrantCount
            InjectedPriority =
                $metrics.GrantPolicyEvidence.TraceInjectedPriority
            PromptReserveObserved =
                $metrics.GrantPolicyEvidence.PromptReserveBehaviorObserved
            MetricsPath = $row.MetricsPath
        }
    }
)
$raw |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $analysisRoot 'raw-scenarios.csv')
$raw |
    ConvertTo-Json -Depth 8 |
    Set-Content `
        -LiteralPath (Join-Path $analysisRoot 'raw-scenarios.json') `
        -Encoding utf8

$metricDefinitions = @(
    [pscustomobject]@{ Path = 'MeasuredNormalCompletionCount'; Direction = 'higher' },
    [pscustomobject]@{ Path = 'NormalThroughputPerMinute'; Direction = 'higher' },
    [pscustomobject]@{ Path = 'AverageCompletedNormalLatencySeconds'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'InjectedRequestToGrantSeconds'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'InjectedRequestToCompletionSeconds'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'QueueDepthP95'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'AverageAllocatedNodes'; Direction = 'higher' },
    [pscustomobject]@{ Path = 'AverageUnusedNodes'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'SteadyResource.AverageSystemCpuPercent'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'SteadyResource.PeakCommittedBytes'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'SteadyResource.PeakDescendantWorkingSetBytes'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'SteadyResource.PeakDescendantPrivateBytes'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'SteadyResource.PeakDescendantProcessCount'; Direction = 'lower' },
    [pscustomobject]@{ Path = 'SteadyResource.DescendantCpuSeconds'; Direction = 'lower' }
)
$comparisons = @(
    [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'FINAL-N' },
    [pscustomobject]@{ Baseline = 'FINAL-N'; Candidate = 'FINAL-H' },
    [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'FINAL-H' }
)
$estimates = [Collections.Generic.List[object]]::new()
$seed = 20260813
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($comparison in $comparisons) {
        foreach ($metric in $metricDefinitions) {
            $pairs = [Collections.Generic.List[object]]::new()
            foreach ($block in 1..3) {
                $baseline =
                    $scenarioRows |
                    Where-Object {
                        $_.Repository -eq $repository -and
                        $_.AnalysisBlock -eq $block -and
                        $_.Condition -eq $comparison.Baseline
                    } |
                    Select-Object -First 1
                $candidate =
                    $scenarioRows |
                    Where-Object {
                        $_.Repository -eq $repository -and
                        $_.AnalysisBlock -eq $block -and
                        $_.Condition -eq $comparison.Candidate
                    } |
                    Select-Object -First 1
                $baselineValue =
                    Get-NestedValue `
                        -InputObject $baseline.Metrics `
                        -PropertyPath $metric.Path
                $candidateValue =
                    Get-NestedValue `
                        -InputObject $candidate.Metrics `
                        -PropertyPath $metric.Path
                if ($null -eq $baselineValue -or
                    $null -eq $candidateValue -or
                    [double]$baselineValue -le 0 -or
                    [double]$candidateValue -le 0) {
                    continue
                }
                $pairs.Add([pscustomobject]@{
                    Block = $block
                    BaselineValue = [double]$baselineValue
                    CandidateValue = [double]$candidateValue
                })
            }
            if ($pairs.Count -ne 3) {
                continue
            }
            $seed++
            $estimates.Add(
                (New-PairedEstimate `
                    -Pairs $pairs.ToArray() `
                    -Shape sustained `
                    -Repository $repository `
                    -Baseline $comparison.Baseline `
                    -Candidate $comparison.Candidate `
                    -Metric $metric.Path `
                    -PreferredDirection $metric.Direction `
                    -Seed $seed))
        }
    }
}
$estimates.ToArray() |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath (Join-Path $analysisRoot 'paired-estimates.json') `
        -Encoding utf8
$estimates |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $analysisRoot 'paired-estimates.csv')

$binlogIndex = @(
    Get-ChildItem `
        -LiteralPath $RunRoot `
        -Filter '*.binlog' `
        -Recurse `
        -File |
    ForEach-Object {
        [pscustomobject][ordered]@{
            RelativePath = [IO.Path]::GetRelativePath($RunRoot, $_.FullName)
            Bytes = $_.Length
            Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
)
$binlogIndex |
    ConvertTo-Json -Depth 5 |
    Set-Content `
        -LiteralPath (Join-Path $evidenceRoot 'binlog-hash-index.json') `
        -Encoding utf8
$toolingIndex = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -File |
    ForEach-Object {
        [pscustomobject][ordered]@{
            Name = $_.Name
            Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
)
$toolingIndex |
    ConvertTo-Json -Depth 5 |
    Set-Content `
        -LiteralPath (Join-Path $evidenceRoot 'tooling-hash-index.json') `
        -Encoding utf8

$report = [Collections.Generic.List[string]]::new()
$report.Add('# PR #14241 sustained contention results')
$report.Add('')
$report.Add('All reported effects are directional paired estimates with n=3 complete blocks per repository. Percentages use `100 * (exp(mean(log(candidate / baseline))) - 1)`. Confidence intervals use 10,000 deterministic whole-block resamples; p-values use exact two-sided sign flips.')
$report.Add('')
foreach ($repository in @('roslyn', 'aspire')) {
    $report.Add("## $repository")
    $report.Add('')
    $report.Add('| Comparison | Metric | Baseline mean | Candidate mean | Effect | 95% interval | Exact p | Plain English |')
    $report.Add('|---|---:|---:|---:|---:|---:|---:|---|')
    foreach ($estimate in $estimates | Where-Object Repository -eq $repository) {
        $report.Add(
            "| $($estimate.Comparison) | $($estimate.Metric) | $([Math]::Round($estimate.BaselineArithmeticMean, 4)) | $([Math]::Round($estimate.CandidateArithmeticMean, 4)) | $([Math]::Round($estimate.EffectPercent, 2))% | [$([Math]::Round($estimate.ConfidenceIntervalLowerPercent, 2))%, $([Math]::Round($estimate.ConfidenceIntervalUpperPercent, 2))%] | $($estimate.ExactTwoSidedSignFlipP) | $($estimate.Interpretation) |")
    }
    $report.Add('')
}
$report |
    Set-Content `
        -LiteralPath (Join-Path $analysisRoot 'report.md') `
        -Encoding utf8

[pscustomobject][ordered]@{
    Valid = $true
    ScenarioCount = $scenarioRows.Count
    EstimateCount = $estimates.Count
    BinlogCount = $binlogIndex.Count
    ReportPath = Join-Path $analysisRoot 'report.md'
}
