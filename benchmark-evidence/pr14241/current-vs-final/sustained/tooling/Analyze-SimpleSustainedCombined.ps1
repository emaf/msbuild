[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OriginalRoot,

    [Parameter(Mandatory)]
    [string]$SupplementalRoot,

    [Parameter(Mandatory)]
    [string]$OutputRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolingRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolingRoot 'Campaign.Common.ps1')
. (Join-Path $toolingRoot 'Analysis.Common.ps1')

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$originalPlan = @(Import-Csv -LiteralPath (Join-Path $OriginalRoot 'matrix-plan.csv'))
$rows = [Collections.Generic.List[object]]::new()

function Add-AcceptedBlock {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [ValidateSet('roslyn', 'aspire')]
        [string]$Repository,
        [Parameter(Mandatory)]
        [ValidateRange(1, 3)]
        [int]$AnalysisBlock
    )

    $blockRoot =
        Join-Path $Root (
            "measured\$Repository\block-$('{0:D2}' -f $AnalysisBlock)")
    $completionPath = Join-Path $blockRoot 'block-completion.json'
    if (-not (Test-Path -LiteralPath $completionPath -PathType Leaf)) {
        throw "Missing block completion '$completionPath'."
    }
    $completion =
        Get-Content -LiteralPath $completionPath -Raw |
        ConvertFrom-Json
    if (-not $completion.Valid -or
        [int]$completion.AnalysisBlock -ne $AnalysisBlock) {
        throw "Invalid block completion '$completionPath'."
    }
    $attemptRoot =
        Join-Path $blockRoot (
            "attempt-$('{0:D2}' -f [int]$completion.Attempt)")
    $expected = @(
        $originalPlan |
            Where-Object {
                $_.Repository -eq $Repository -and
                [int]$_.AnalysisBlock -eq $AnalysisBlock -and
                $_.IsWarmup -eq 'False'
            } |
            Sort-Object { [int]$_.Position }
    )
    if ($expected.Count -ne 3 -or
        (@($expected.Condition) -join ',') -ne
            (@($completion.Conditions) -join ',')) {
        throw "$Repository block $AnalysisBlock does not preserve its original condition order."
    }
    for ($position = 0; $position -lt 3; $position++) {
        $scenarioRoot =
            Join-Path $attemptRoot (
                "$('{0:D2}' -f ($position + 1))-$($expected[$position].Condition)")
        $validation =
            Get-Content `
                -LiteralPath (Join-Path $scenarioRoot 'scenario-validation.json') `
                -Raw |
            ConvertFrom-Json
        $metrics =
            Get-Content `
                -LiteralPath (Join-Path $scenarioRoot 'scenario-metrics.json') `
                -Raw |
            ConvertFrom-Json
        if (-not $validation.Valid -or
            -not $metrics.Valid -or
            $validation.Repository -ne $Repository -or
            $validation.Condition -ne $expected[$position].Condition -or
            [int]$validation.WorkerCount -ne 8 -or
            [double]$metrics.MeasuredWindowSeconds -ne 480 -or
            [double]$metrics.QueueNonemptyTimeFraction -lt 0.90 -or
            [double]$metrics.QueueNonemptySampleFraction -lt 0.90) {
            throw "Accepted scenario '$scenarioRoot' violates the original validity contract."
        }
        $rows.Add([pscustomobject][ordered]@{
            Repository = $Repository
            AnalysisBlock = $AnalysisBlock
            Position = $position + 1
            Condition = $expected[$position].Condition
            SourceRoot = $Root
            ScenarioRoot = $scenarioRoot
            Metrics = $metrics
        })
    }
}

foreach ($block in 1..3) {
    Add-AcceptedBlock `
        -Root $OriginalRoot `
        -Repository roslyn `
        -AnalysisBlock $block
}
Add-AcceptedBlock `
    -Root $OriginalRoot `
    -Repository aspire `
    -AnalysisBlock 1
foreach ($block in 2..3) {
    Add-AcceptedBlock `
        -Root $SupplementalRoot `
        -Repository aspire `
        -AnalysisBlock $block
}

if ($rows.Count -ne 18) {
    throw "Combined accepted set has $($rows.Count) scenarios; expected 18."
}
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($block in 1..3) {
        foreach ($condition in @('BASE', 'FINAL-N', 'FINAL-H')) {
            $matches = @(
                $rows |
                    Where-Object {
                        $_.Repository -eq $repository -and
                        $_.AnalysisBlock -eq $block -and
                        $_.Condition -eq $condition
                    }
            )
            if ($matches.Count -ne 1) {
                throw "$repository block $block $condition has $($matches.Count) accepted rows."
            }
        }
    }
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return $null
    }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Min(
        $sorted.Count - 1,
        [Math]::Max(0, [Math]::Ceiling($Percentile * $sorted.Count) - 1))
    return [double]$sorted[$index]
}

$rawRows = @(
    foreach ($row in $rows) {
        $metrics = $row.Metrics
        $workerGrants = [double[]]@($metrics.WorkerRequestToGrantSeconds)
        $workerCompletion = [double[]]@(
            $metrics.WorkerRequestToCompletionSeconds)
        [pscustomobject][ordered]@{
            Repository = $row.Repository
            AnalysisBlock = $row.AnalysisBlock
            Position = $row.Position
            Condition = $row.Condition
            MeasuredNormalCompletionCount =
                [int]$metrics.MeasuredNormalCompletionCount
            NormalThroughputPerMinute =
                [double]$metrics.NormalThroughputPerMinute
            AverageCompletedNormalLatencySeconds =
                [double]$metrics.AverageCompletedNormalLatencySeconds
            WorkerRequestToGrantP50Seconds =
                Get-Percentile -Values $workerGrants -Percentile 0.50
            WorkerRequestToGrantP95Seconds =
                Get-Percentile -Values $workerGrants -Percentile 0.95
            WorkerRequestToCompletionP50Seconds =
                Get-Percentile -Values $workerCompletion -Percentile 0.50
            WorkerRequestToCompletionP95Seconds =
                Get-Percentile -Values $workerCompletion -Percentile 0.95
            InjectedRequestToGrantSeconds =
                [double]$metrics.InjectedRequestToGrantSeconds
            InjectedRequestToCompletionSeconds =
                [double]$metrics.InjectedRequestToCompletionSeconds
            QueueDepthP95 = [double]$metrics.QueueDepthP95
            QueueNonemptyTimeFraction =
                [double]$metrics.QueueNonemptyTimeFraction
            QueueNonemptySampleFraction =
                [double]$metrics.QueueNonemptySampleFraction
            AverageAllocatedNodes =
                [double]$metrics.AverageAllocatedNodes
            AverageUnusedNodes =
                [double]$metrics.AverageUnusedNodes
            AverageSystemCpuPercent =
                [double]$metrics.SteadyResource.AverageSystemCpuPercent
            PeakCommittedBytes =
                [double]$metrics.SteadyResource.PeakCommittedBytes
            PeakDescendantWorkingSetBytes =
                [double]$metrics.SteadyResource.PeakDescendantWorkingSetBytes
            PeakDescendantPrivateBytes =
                [double]$metrics.SteadyResource.PeakDescendantPrivateBytes
            PeakDescendantProcessCount =
                [double]$metrics.SteadyResource.PeakDescendantProcessCount
            DescendantCpuSeconds =
                [double]$metrics.SteadyResource.DescendantCpuSeconds
            ActualGrantCount = [int]$metrics.ActualGrantCount
            InjectedPriority =
                $metrics.GrantPolicyEvidence.TraceInjectedPriority
            PromptReserveObserved =
                [bool]$metrics.GrantPolicyEvidence.PromptReserveBehaviorObserved
            Source = if ($row.SourceRoot -eq $OriginalRoot) {
                'original'
            }
            else {
                'supplemental'
            }
        }
    }
)
$rawRows |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $OutputRoot 'raw-scenarios.csv')
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'raw-scenarios.json') `
    -Value $rawRows `
    -Depth 10

$metricDefinitions = @(
    [pscustomobject]@{
        Path = 'MeasuredNormalCompletionCount'
        Direction = 'higher'
    },
    [pscustomobject]@{
        Path = 'NormalThroughputPerMinute'
        Direction = 'higher'
    },
    [pscustomobject]@{
        Path = 'AverageCompletedNormalLatencySeconds'
        Direction = 'lower'
    },
    [pscustomobject]@{
        Path = 'InjectedRequestToGrantSeconds'
        Direction = 'lower'
    },
    [pscustomobject]@{
        Path = 'InjectedRequestToCompletionSeconds'
        Direction = 'lower'
    },
    [pscustomobject]@{ Path = 'QueueDepthP95'; Direction = 'lower' },
    [pscustomobject]@{
        Path = 'AverageAllocatedNodes'
        Direction = 'higher'
    },
    [pscustomobject]@{ Path = 'AverageUnusedNodes'; Direction = 'lower' },
    [pscustomobject]@{
        Path = 'SteadyResource.AverageSystemCpuPercent'
        Direction = 'lower'
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakCommittedBytes'
        Direction = 'lower'
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakDescendantWorkingSetBytes'
        Direction = 'lower'
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakDescendantPrivateBytes'
        Direction = 'lower'
    },
    [pscustomobject]@{
        Path = 'SteadyResource.PeakDescendantProcessCount'
        Direction = 'lower'
    },
    [pscustomobject]@{
        Path = 'SteadyResource.DescendantCpuSeconds'
        Direction = 'lower'
    }
)
$comparisons = @(
    [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'FINAL-N' },
    [pscustomobject]@{ Baseline = 'FINAL-N'; Candidate = 'FINAL-H' },
    [pscustomobject]@{ Baseline = 'BASE'; Candidate = 'FINAL-H' }
)
$pairsOutput = [Collections.Generic.List[object]]::new()
$estimates = [Collections.Generic.List[object]]::new()
$seed = 20260813
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($comparison in $comparisons) {
        foreach ($metric in $metricDefinitions) {
            $pairs = [Collections.Generic.List[object]]::new()
            foreach ($block in 1..3) {
                $baseline =
                    $rows |
                    Where-Object {
                        $_.Repository -eq $repository -and
                        $_.AnalysisBlock -eq $block -and
                        $_.Condition -eq $comparison.Baseline
                    } |
                    Select-Object -First 1
                $candidate =
                    $rows |
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
                $pair = [pscustomobject][ordered]@{
                    Repository = $repository
                    AnalysisBlock = $block
                    Baseline = $comparison.Baseline
                    Candidate = $comparison.Candidate
                    Metric = $metric.Path
                    BaselineValue = [double]$baselineValue
                    CandidateValue = [double]$candidateValue
                }
                $pairs.Add($pair)
                $pairsOutput.Add($pair)
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
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'paired-raw-values.json') `
    -Value $pairsOutput.ToArray() `
    -Depth 8
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'paired-estimates.json') `
    -Value $estimates.ToArray() `
    -Depth 10
$estimates |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $OutputRoot 'paired-estimates.csv')

$conditionSummaries = @(
    foreach ($repository in @('roslyn', 'aspire')) {
        foreach ($condition in @('BASE', 'FINAL-N', 'FINAL-H')) {
            $conditionRows = @(
                $rawRows |
                    Where-Object {
                        $_.Repository -eq $repository -and
                        $_.Condition -eq $condition
                    }
            )
            [pscustomobject][ordered]@{
                Repository = $repository
                Condition = $condition
                Blocks = $conditionRows.Count
                MeanNormalThroughputPerMinute =
                    ($conditionRows |
                        Measure-Object NormalThroughputPerMinute -Average).Average
                MeanQueueDepthP95 =
                    ($conditionRows |
                        Measure-Object QueueDepthP95 -Average).Average
                MeanQueueNonemptyTimeFraction =
                    ($conditionRows |
                        Measure-Object QueueNonemptyTimeFraction -Average).Average
                MeanAverageAllocatedNodes =
                    ($conditionRows |
                        Measure-Object AverageAllocatedNodes -Average).Average
                MeanAverageUnusedNodes =
                    ($conditionRows |
                        Measure-Object AverageUnusedNodes -Average).Average
                MeanSystemCpuPercent =
                    ($conditionRows |
                        Measure-Object AverageSystemCpuPercent -Average).Average
                MaximumCommittedBytes =
                    ($conditionRows |
                        Measure-Object PeakCommittedBytes -Maximum).Maximum
                MaximumDescendantWorkingSetBytes =
                    ($conditionRows |
                        Measure-Object PeakDescendantWorkingSetBytes -Maximum).Maximum
                MaximumDescendantPrivateBytes =
                    ($conditionRows |
                        Measure-Object PeakDescendantPrivateBytes -Maximum).Maximum
                MaximumDescendantProcessCount =
                    ($conditionRows |
                        Measure-Object PeakDescendantProcessCount -Maximum).Maximum
                TotalActualGrants =
                    ($conditionRows |
                        Measure-Object ActualGrantCount -Sum).Sum
            }
        }
    }
)
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'condition-summaries.json') `
    -Value $conditionSummaries `
    -Depth 8

$acceptedBinlogs = @(
    foreach ($row in $rows) {
        foreach ($binlog in Get-ChildItem `
            -LiteralPath (Join-Path $row.ScenarioRoot 'runs') `
            -Filter '*.binlog' `
            -Recurse `
            -File) {
            [pscustomobject][ordered]@{
                Repository = $row.Repository
                AnalysisBlock = $row.AnalysisBlock
                Condition = $row.Condition
                LogicalPath =
                    "$($row.Repository)/block-$($row.AnalysisBlock)/$($row.Condition)/$($binlog.Directory.Name)/$($binlog.Name)"
                Bytes = $binlog.Length
                Sha256 =
                    (Get-FileHash `
                        -LiteralPath $binlog.FullName `
                        -Algorithm SHA256).Hash
            }
        }
    }
)
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'binlog-hash-index.json') `
    -Value $acceptedBinlogs `
    -Depth 8

$invalidAttempts = @(
    foreach ($root in @($OriginalRoot, $SupplementalRoot)) {
        foreach ($validationPath in Get-ChildItem `
            -LiteralPath $root `
            -Filter scenario-validation.json `
            -Recurse `
            -File) {
            $validation =
                Get-Content -LiteralPath $validationPath.FullName -Raw |
                ConvertFrom-Json
            if (-not $validation.Valid) {
                [pscustomobject][ordered]@{
                    Source = if ($root -eq $OriginalRoot) {
                        'original'
                    }
                    else {
                        'supplemental'
                    }
                    RelativePath =
                        [IO.Path]::GetRelativePath(
                            $root,
                            $validationPath.Directory.FullName)
                    Condition = $validation.Condition
                    Errors = @($validation.Errors)
                    Excluded = $true
                }
            }
        }
    }
)
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'invalid-attempts.json') `
    -Value $invalidAttempts `
    -Depth 8

$identity = [pscustomobject][ordered]@{
    SchemaVersion = 1
    GeneratedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    OriginalRoot = $OriginalRoot
    SupplementalRoot = $SupplementalRoot
    BaseCommit = 'ff5b281f0c5828dec0d092fcd1b682019de7d1ca'
    FinalCommit = '432466e41a95f9bbb25cad7ff9bd1b89b4a6bcef'
    RoslynCommit = 'bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b'
    AspireCommit = '110a63da8357af437a00d9efc5887ffdcbdfbb3c'
    WorkerCount = 8
    NodeBudget = 16
    MeasuredWindowSeconds = 480
    InjectionOffsetSeconds = 240
    AcceptedScenarioCount = $rows.Count
    CompleteBlocksPerRepository = 3
    DuplicateAcceptedRows = 0
    SupplementalBlocks = @(2, 3)
    Limitation = 'The original campaign was interrupted by host suspension during Aspire block 2. That partial scenario remains excluded; Aspire blocks 2 and 3 were completed in one preauthorized supplemental campaign with identical identities, configuration, orders, and acceptance rules.'
}
Write-JsonAtomic `
    -Path (Join-Path $OutputRoot 'combined-identity.json') `
    -Value $identity `
    -Depth 8

$report = [Collections.Generic.List[string]]::new()
$report.Add('# PR #14241 sustained contention results')
$report.Add('')
$report.Add('The combined accepted set contains three complete measured blocks for each repository and condition. Roslyn and Aspire block 1 come from the original campaign; Aspire blocks 2 and 3 come from the preauthorized supplemental campaign. The host-suspended partial Aspire block 2 is excluded.')
$report.Add('')
$report.Add('Effects use `100 * (exp(mean(log(candidate / baseline))) - 1)` over three paired whole blocks. Intervals use 10,000 deterministic whole-block resamples; p-values use exact two-sided sign flips. With n=3, estimates are directional.')
$report.Add('')
foreach ($repository in @('roslyn', 'aspire')) {
    $report.Add("## $repository")
    $report.Add('')
    $report.Add('| Comparison | Metric | Baseline mean | Candidate mean | Effect | 95% interval | Exact p |')
    $report.Add('|---|---|---:|---:|---:|---:|---:|')
    foreach ($estimate in $estimates | Where-Object Repository -eq $repository) {
        $report.Add(
            "| $($estimate.Comparison) | $($estimate.Metric) | $([Math]::Round($estimate.BaselineArithmeticMean, 4)) | $([Math]::Round($estimate.CandidateArithmeticMean, 4)) | $([Math]::Round($estimate.EffectPercent, 2))% | [$([Math]::Round($estimate.ConfidenceIntervalLowerPercent, 2))%, $([Math]::Round($estimate.ConfidenceIntervalUpperPercent, 2))%] | $($estimate.ExactTwoSidedSignFlipP) |")
    }
    $report.Add('')
}
$report.Add('## Validity limitation')
$report.Add('')
$report.Add('The original run experienced a roughly 36,182-second telemetry discontinuity caused by host suspension during Aspire block 2. That partial scenario was never reused. A fresh supplemental root reran the complete original rows for Aspire blocks 2 and 3 under the same immutable binaries, workload commit, eight-worker design, fixed window, injection timing, and validity criteria.')
$report |
    Set-Content `
        -LiteralPath (Join-Path $OutputRoot 'report.md') `
        -Encoding utf8

[pscustomobject][ordered]@{
    Valid = $true
    AcceptedScenarioCount = $rows.Count
    EstimateCount = $estimates.Count
    BinlogCount = $acceptedBinlogs.Count
    InvalidAttemptCount = $invalidAttempts.Count
    OutputRoot = $OutputRoot
}
