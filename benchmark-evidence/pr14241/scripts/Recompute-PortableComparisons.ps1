[CmdletBinding()]
param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-GeometricMean {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
        throw 'Cannot compute a geometric mean from an empty set.'
    }

    $logSum = 0.0
    foreach ($value in $Values) {
        if ($value -le 0) {
            throw "Geometric mean input must be positive; found $value."
        }
        $logSum += [Math]::Log($value)
    }

    return [Math]::Exp($logSum / $Values.Count)
}

function Get-ComparisonRow {
    param(
        [object[]]$Rows,
        [string]$Repository,
        [string]$Comparison
    )

    $match = @($Rows | Where-Object {
        $_.Repository -eq $Repository -and $_.Comparison -eq $Comparison
    })
    if ($match.Count -ne 1) {
        throw "Expected one '$Comparison' row for '$Repository'; found $($match.Count)."
    }
    return $match[0]
}

function Add-PairedComparison {
    param(
        [Collections.Generic.List[object]]$Output,
        [object[]]$ScenarioRows,
        [object[]]$ComparisonRows,
        [string]$Evidence,
        [string]$Repository,
        [string]$Comparison,
        [string]$BaselineCondition,
        [string]$CandidateCondition,
        [string]$Metric,
        [string]$ComparisonMetricPrefix,
        [string]$PlainEnglish
    )

    $rows = @($ScenarioRows | Where-Object {
        $_.Repository -eq $Repository -and
        $_.IsWarmup -eq 'False'
    })
    $baselineValues = [double[]]@($rows | Where-Object {
        $_.ConditionKey -eq $BaselineCondition
    } | ForEach-Object { [double]($_.$Metric) })
    $candidateValues = [double[]]@($rows | Where-Object {
        $_.ConditionKey -eq $CandidateCondition
    } | ForEach-Object { [double]($_.$Metric) })
    if ($baselineValues.Count -ne $candidateValues.Count) {
        throw "$Evidence/$Repository/$Comparison/$Metric is not paired."
    }

    $baseline = Get-GeometricMean $baselineValues
    $candidate = Get-GeometricMean $candidateValues
    $summary = Get-ComparisonRow $ComparisonRows $Repository $Comparison
    $effectProperty = "${ComparisonMetricPrefix}CostPercent"
    $lowerProperty = "${ComparisonMetricPrefix}CostCiLowerPercent"
    $upperProperty = "${ComparisonMetricPrefix}CostCiUpperPercent"
    $pProperty = if ($ComparisonMetricPrefix -eq 'CandidateLatency') {
        'CandidateExactSignFlipP'
    }
    else {
        "${ComparisonMetricPrefix}ExactSignFlipP"
    }

    $Output.Add([pscustomobject][ordered]@{
        Evidence = $Evidence
        Repository = $Repository
        Comparison = $Comparison
        Metric = $Metric
        BaselineCondition = $BaselineCondition
        CandidateCondition = $CandidateCondition
        BaselineValue = $baseline
        CandidateValue = $candidate
        Units = 'seconds'
        Statistic = "paired log-ratio estimate from $($baselineValues.Count) measured blocks; displayed values are geometric means"
        Formula = '100 * (candidate / baseline - 1)'
        EffectPercent = [double]$summary.$effectProperty
        CiLowerPercent = [double]$summary.$lowerProperty
        CiUpperPercent = [double]$summary.$upperProperty
        ExactSignFlipP = [double]$summary.$pProperty
        Interpretation = $PlainEnglish
    })
}

function Add-MedianComparison {
    param(
        [Collections.Generic.List[object]]$Output,
        [string]$Evidence,
        [string]$Repository,
        [string]$Comparison,
        [string]$Metric,
        [string]$BaselineCondition,
        [string]$CandidateCondition,
        [double]$Baseline,
        [double]$Candidate,
        [string]$Units,
        [string]$PlainEnglish
    )

    $Output.Add([pscustomobject][ordered]@{
        Evidence = $Evidence
        Repository = $Repository
        Comparison = $Comparison
        Metric = $Metric
        BaselineCondition = $BaselineCondition
        CandidateCondition = $CandidateCondition
        BaselineValue = $Baseline
        CandidateValue = $Candidate
        Units = $Units
        Statistic = 'median across measured scenarios'
        Formula = '100 * (candidate / baseline - 1)'
        EffectPercent = 100.0 * (($Candidate / $Baseline) - 1.0)
        CiLowerPercent = $null
        CiUpperPercent = $null
        ExactSignFlipP = $null
        Interpretation = $PlainEnglish
    })
}

$output = [Collections.Generic.List[object]]::new()

$idleRoot = Join-Path $PackageRoot 'evidence\idle-burst'
$idleScenarios = @(Import-Csv (Join-Path $idleRoot 'scenario-metrics.csv'))
$idleComparisons = @(Import-Csv (Join-Path $idleRoot 'comparisons.csv'))
foreach ($repository in @('roslyn', 'aspire')) {
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'AUTO-H-vs-AUTO-N' 'AUTO-N' 'AUTO-H' 'CandidateDurationSec' 'CandidateLatency' `
        'The delayed High build completed sooner under AUTO-H than the delayed Normal build under AUTO-N.'
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'AUTO-H-vs-AUTO-N' 'AUTO-N' 'AUTO-H' 'AverageNormalDurationSec' 'AverageNormal' `
        'The four initial Normal builds completed later on average under AUTO-H.'
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'AUTO-H-vs-AUTO-N' 'AUTO-N' 'AUTO-H' 'TotalWallSec' 'TotalWall' `
        'The complete scenario finished sooner under AUTO-H.'
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'AUTO-N-vs-F4-N' 'F4-N' 'AUTO-N' 'TotalWallSec' 'TotalWall' `
        'The automatic idle-8 scenario finished later than fixed 4/4 under all-Normal contention.'
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'AUTO-N-vs-F4-N' 'F4-N' 'AUTO-N' 'AverageNormalDurationSec' 'AverageNormal' `
        'Normal builds completed later on average after the immutable idle 8-node grant.'
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'F4-H-vs-F4-N' 'F4-N' 'F4-H' 'CandidateDurationSec' 'CandidateLatency' `
        'The delayed High build completed sooner than the delayed Normal control under fixed 4/4.'
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'F4-H-vs-F4-N' 'F4-N' 'F4-H' 'AverageNormalDurationSec' 'AverageNormal' `
        'The initial Normal builds completed later on average when the delayed build was High.'
    Add-PairedComparison $output $idleScenarios $idleComparisons 'idle-burst' $repository `
        'F4-H-vs-F4-N' 'F4-N' 'F4-H' 'TotalWallSec' 'TotalWall' `
        'The fixed-4/4 High scenario had this total-wall change relative to all-Normal.'
}

$idlePressure = @(Import-Csv (Join-Path $idleRoot 'pressure-medians.csv'))
foreach ($repository in @('roslyn', 'aspire')) {
    $baseline = $idlePressure | Where-Object {
        $_.Repository -eq $repository -and $_.Condition -eq 'F4-N'
    }
    $candidate = $idlePressure | Where-Object {
        $_.Repository -eq $repository -and $_.Condition -eq 'AUTO-N'
    }
    foreach ($definition in @(
        @('PeakCommittedDeltaMedianMB', 'committed memory growth'),
        @('DescendantPeakWorkingSetMedianMB', 'descendant working set'),
        @('DescendantPeakPrivateMedianMB', 'descendant private memory')
    )) {
        $metric = $definition[0]
        Add-MedianComparison $output 'idle-burst' $repository 'AUTO-N-vs-F4-N' $metric `
            'F4-N' 'AUTO-N' ([double]$baseline.$metric) ([double]$candidate.$metric) 'MiB' `
            "AUTO-N used less $($definition[1]) than fixed 4/4."
    }
}

$priorityRoot = Join-Path $PackageRoot 'evidence\priority'
$priorityScenarios = @(Import-Csv (Join-Path $priorityRoot 'scenario-metrics.csv'))
$priorityComparisons = @(Import-Csv (Join-Path $priorityRoot 'comparisons.csv'))
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($definition in @(
        @('CandidateDurationSec', 'CandidateLatency', 'The delayed compatibility-candidate build had this latency change relative to the pre-priority Coordinator.'),
        @('AverageNormalDurationSec', 'AverageNormal', 'Normal builds had this average latency change under compatibility 0/0.'),
        @('TotalWallSec', 'TotalWall', 'The complete compatibility scenario had this wall-time change.')
    )) {
        Add-PairedComparison $output $priorityScenarios $priorityComparisons 'priority' $repository `
            'B-vs-C' 'B-base-coordinator' 'C-candidate-compat' $definition[0] $definition[1] $definition[2]
    }
    foreach ($definition in @(
        @('CandidateDurationSec', 'CandidateLatency', 'The delayed High build completed sooner than the delayed Normal control under fixed 4/4.'),
        @('AverageNormalDurationSec', 'AverageNormal', 'Normal builds completed later on average when the delayed build was High.'),
        @('TotalWallSec', 'TotalWall', 'The fixed-4/4 High scenario had this total-wall change.')
    )) {
        Add-PairedComparison $output $priorityScenarios $priorityComparisons 'priority' $repository `
            'D-vs-E' 'D-candidate-default-normal' 'E-candidate-default-high' $definition[0] $definition[1] $definition[2]
    }
}

$nodeRoot = Join-Path $PackageRoot 'evidence\node-count'
$nodeScenarios = @(Import-Csv (Join-Path $nodeRoot 'scenario-metrics.csv'))
$nodeComparisons = @(Import-Csv (Join-Path $nodeRoot 'comparisons.csv'))
$nodePressure = @(Import-Csv (Join-Path $nodeRoot 'pressure-summary.csv'))
foreach ($repository in @('roslyn', 'aspire')) {
    $rows = @($nodeScenarios | Where-Object {
        $_.Repository -eq $repository -and $_.IsWarmup -eq 'False'
    })
    foreach ($definition in @(
        @('N4-vs-N8', 'N8', 'N4', $false),
        @('N16-vs-N8', 'N16', 'N8', $true)
    )) {
        $sourceComparison = $definition[0]
        $baselineCondition = $definition[1]
        $candidateCondition = $definition[2]
        $invert = [bool]$definition[3]
        $baselineValues = [double[]]@($rows | Where-Object {
            $_.ConditionKey -eq $baselineCondition
        } | ForEach-Object { [double]$_.TotalWallSec })
        $candidateValues = [double[]]@($rows | Where-Object {
            $_.ConditionKey -eq $candidateCondition
        } | ForEach-Object { [double]$_.TotalWallSec })
        $baseline = Get-GeometricMean $baselineValues
        $candidate = Get-GeometricMean $candidateValues
        $summary = Get-ComparisonRow $nodeComparisons $repository $sourceComparison
        if ($invert) {
            $sourceEffect = [double]$summary.WallEffectPercent / 100.0
            $sourceLower = [double]$summary.WallCiLowerPercent / 100.0
            $sourceUpper = [double]$summary.WallCiUpperPercent / 100.0
            $effect = 100.0 * ((1.0 / (1.0 + $sourceEffect)) - 1.0)
            $lower = 100.0 * ((1.0 / (1.0 + $sourceUpper)) - 1.0)
            $upper = 100.0 * ((1.0 / (1.0 + $sourceLower)) - 1.0)
            $comparison = 'N8-vs-N16'
            $interpretation = 'Eight nodes finished slower than sixteen nodes, while using less memory.'
        }
        else {
            $effect = [double]$summary.WallEffectPercent
            $lower = [double]$summary.WallCiLowerPercent
            $upper = [double]$summary.WallCiUpperPercent
            $comparison = 'N4-vs-N8'
            $interpretation = 'Four nodes finished slower than eight nodes.'
        }
        $output.Add([pscustomobject][ordered]@{
            Evidence = 'node-count'
            Repository = $repository
            Comparison = $comparison
            Metric = 'TotalWallSec'
            BaselineCondition = $baselineCondition
            CandidateCondition = $candidateCondition
            BaselineValue = $baseline
            CandidateValue = $candidate
            Units = 'seconds'
            Statistic = "paired log-ratio estimate from $($baselineValues.Count) measured blocks; displayed values are geometric means"
            Formula = '100 * (candidate / baseline - 1)'
            EffectPercent = $effect
            CiLowerPercent = $lower
            CiUpperPercent = $upper
            ExactSignFlipP = [double]$summary.WallExactSignFlipP
            Interpretation = $interpretation
        })
    }

    $n16 = $nodePressure | Where-Object {
        $_.Repository -eq $repository -and $_.ConditionKey -eq 'N16'
    }
    $n8 = $nodePressure | Where-Object {
        $_.Repository -eq $repository -and $_.ConditionKey -eq 'N8'
    }
    foreach ($definition in @(
        @('PeakCommittedDeltaMBMedian', 'committed memory growth'),
        @('DescendantPeakWorkingSetMBMedian', 'descendant working set'),
        @('DescendantPeakPrivateMBMedian', 'descendant private memory')
    )) {
        $metric = $definition[0]
        Add-MedianComparison $output 'node-count' $repository 'N8-vs-N16' $metric `
            'N16' 'N8' ([double]$n16.$metric) ([double]$n8.$metric) 'MiB' `
            "Eight nodes used less $($definition[1]) than sixteen nodes."
    }
}

$vsGreenRoot = Join-Path $PackageRoot 'evidence\vs-green'
$vsGreenScenarios = @(Import-Csv (Join-Path $vsGreenRoot 'scenario-metrics.csv'))
$vsGreenComparisons = @(Import-Csv (Join-Path $vsGreenRoot 'comparisons.csv'))
$vsGreenPressure = @(Import-Csv (Join-Path $vsGreenRoot 'pressure-summary.csv'))
$vsGreenRows = @($vsGreenScenarios | Where-Object { $_.IsWarmup -eq 'False' })
foreach ($definition in @(
    @('N4-vs-N8', 'N8', 'N4', $false),
    @('N16-vs-N8', 'N16', 'N8', $true)
)) {
    $sourceComparison = $definition[0]
    $baselineCondition = $definition[1]
    $candidateCondition = $definition[2]
    $invert = [bool]$definition[3]
    $baselineValues = [double[]]@($vsGreenRows | Where-Object {
        $_.ConditionKey -eq $baselineCondition
    } | ForEach-Object { [double]$_.TotalWallSec })
    $candidateValues = [double[]]@($vsGreenRows | Where-Object {
        $_.ConditionKey -eq $candidateCondition
    } | ForEach-Object { [double]$_.TotalWallSec })
    $baseline = Get-GeometricMean $baselineValues
    $candidate = Get-GeometricMean $candidateValues
    $summary = Get-ComparisonRow $vsGreenComparisons 'vs-green' $sourceComparison
    if ($invert) {
        $sourceEffect = [double]$summary.WallEffectPercent / 100.0
        $sourceLower = [double]$summary.WallCiLowerPercent / 100.0
        $sourceUpper = [double]$summary.WallCiUpperPercent / 100.0
        $effect = 100.0 * ((1.0 / (1.0 + $sourceEffect)) - 1.0)
        $lower = 100.0 * ((1.0 / (1.0 + $sourceUpper)) - 1.0)
        $upper = 100.0 * ((1.0 / (1.0 + $sourceLower)) - 1.0)
        $comparison = 'N8-vs-N16'
        $interpretation = 'Eight and sixteen nodes had effectively the same wall time on vs-green.'
    }
    else {
        $effect = [double]$summary.WallEffectPercent
        $lower = [double]$summary.WallCiLowerPercent
        $upper = [double]$summary.WallCiUpperPercent
        $comparison = 'N4-vs-N8'
        $interpretation = 'Four nodes were directionally slower than eight nodes on vs-green.'
    }
    $output.Add([pscustomobject][ordered]@{
        Evidence = 'vs-green'
        Repository = 'vs-green'
        Comparison = $comparison
        Metric = 'TotalWallSec'
        BaselineCondition = $baselineCondition
        CandidateCondition = $candidateCondition
        BaselineValue = $baseline
        CandidateValue = $candidate
        Units = 'seconds'
        Statistic = "paired log-ratio estimate from $($baselineValues.Count) measured blocks; displayed values are geometric means"
        Formula = '100 * (candidate / baseline - 1)'
        EffectPercent = $effect
        CiLowerPercent = $lower
        CiUpperPercent = $upper
        ExactSignFlipP = [double]$summary.WallExactSignFlipP
        Interpretation = $interpretation
    })
}

$vsGreenN16 = $vsGreenPressure | Where-Object { $_.ConditionKey -eq 'N16' }
$vsGreenN8 = $vsGreenPressure | Where-Object { $_.ConditionKey -eq 'N8' }
foreach ($definition in @(
    @('PeakCommittedDeltaMBMedian', 'committed memory growth'),
    @('DescendantPeakWorkingSetMBMedian', 'descendant working set'),
    @('DescendantPeakPrivateMBMedian', 'descendant private memory')
)) {
    $metric = $definition[0]
    Add-MedianComparison $output 'vs-green' 'vs-green' 'N8-vs-N16' $metric `
        'N16' 'N8' ([double]$vsGreenN16.$metric) ([double]$vsGreenN8.$metric) 'MiB' `
        "Eight nodes used less $($definition[1]) than sixteen nodes on vs-green."
}

$outputPath = Join-Path $PackageRoot 'recomputed-comparisons.csv'
$output | Export-Csv -NoTypeInformation -LiteralPath $outputPath
Write-Host "Wrote $($output.Count) rows to $outputPath"
