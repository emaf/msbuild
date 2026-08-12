Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-Mean {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
        throw 'Cannot compute a mean of zero values.'
    }
    $sum = 0.0
    foreach ($value in $Values) {
        $sum += $value
    }
    return $sum / $Values.Count
}

function Get-NearestRankPercentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        throw 'Cannot compute a percentile of zero values.'
    }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Min(
        $sorted.Count - 1,
        [Math]::Max(0, [Math]::Ceiling($Percentile * $sorted.Count) - 1))
    return [double]$sorted[$index]
}

function Get-WholeBlockBootstrapInterval {
    param(
        [Parameter(Mandatory)]
        [double[]]$PairedLogRatios,

        [Parameter(Mandatory)]
        [int]$Seed,

        [int]$Iterations = 10000
    )

    if ($Iterations -ne 10000) {
        throw 'The predeclared campaign requires exactly 10,000 resamples.'
    }
    $random = [Random]::new($Seed)
    $means = [double[]]::new($Iterations)
    for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
        $sum = 0.0
        for ($sample = 0; $sample -lt $PairedLogRatios.Count; $sample++) {
            $sum += $PairedLogRatios[$random.Next($PairedLogRatios.Count)]
        }
        $means[$iteration] = $sum / $PairedLogRatios.Count
    }
    [pscustomobject][ordered]@{
        LowerLogRatio = Get-NearestRankPercentile -Values $means -Percentile 0.025
        UpperLogRatio = Get-NearestRankPercentile -Values $means -Percentile 0.975
        Iterations = $Iterations
        Seed = $Seed
    }
}

function Get-ExactSignFlipPValue {
    param(
        [Parameter(Mandatory)]
        [double[]]$PairedLogRatios
    )

    if ($PairedLogRatios.Count -eq 0 -or $PairedLogRatios.Count -gt 20) {
        throw 'Exact sign flips require between 1 and 20 paired blocks.'
    }
    $observed = [Math]::Abs((Get-Mean -Values $PairedLogRatios))
    $permutations = [int64]1 -shl $PairedLogRatios.Count
    $extreme = [int64]0
    for ($mask = [int64]0; $mask -lt $permutations; $mask++) {
        $sum = 0.0
        for ($index = 0; $index -lt $PairedLogRatios.Count; $index++) {
            $sign = if (($mask -band ([int64]1 -shl $index)) -eq 0) { -1.0 } else { 1.0 }
            $sum += $sign * $PairedLogRatios[$index]
        }
        if ([Math]::Abs($sum / $PairedLogRatios.Count) -ge ($observed - 1e-12)) {
            $extreme++
        }
    }
    return [double]$extreme / [double]$permutations
}

function Get-NestedValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyPath
    )

    $value = $InputObject
    foreach ($part in $PropertyPath.Split('.')) {
        if ($null -eq $value) {
            return $null
        }
        $property = $value.PSObject.Properties[$part]
        if ($null -eq $property) {
            return $null
        }
        $value = $property.Value
    }
    return $value
}

function New-PlainLanguageEffect {
    param(
        [Parameter(Mandatory)]
        [string]$Candidate,

        [Parameter(Mandatory)]
        [string]$Baseline,

        [Parameter(Mandatory)]
        [string]$Metric,

        [Parameter(Mandatory)]
        [double]$EffectPercent,

        [Parameter(Mandatory)]
        [ValidateSet('lower', 'higher')]
        [string]$PreferredDirection
    )

    $magnitude = [Math]::Abs($EffectPercent).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    $increased = $EffectPercent -gt 0
    $word = if ($Metric -match 'Throughput') {
        if ($increased) { 'more throughput' } else { 'less throughput' }
    }
    elseif ($Metric -match 'Memory|WorkingSet|Private|Committed|ProcessCount|Unused|Reserved') {
        if ($increased) { 'more resource use' } else { 'less resource use' }
    }
    elseif ($Metric -match 'Grant|Wait|Latency|Duration|Wall|Seconds') {
        if ($increased) { 'slower/later' } else { 'faster/sooner' }
    }
    else {
        if ($increased) { 'higher' } else { 'lower' }
    }
    $preferred = if (($PreferredDirection -eq 'higher' -and $increased) -or
        ($PreferredDirection -eq 'lower' -and -not $increased)) {
        'in the preferred direction'
    }
    else {
        'in the adverse direction'
    }
    "$Candidate was $magnitude% $word than $Baseline for $Metric ($preferred)."
}

function New-PairedEstimate {
    param(
        [Parameter(Mandatory)]
        [object[]]$Pairs,

        [Parameter(Mandatory)]
        [string]$Shape,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Baseline,

        [Parameter(Mandatory)]
        [string]$Candidate,

        [Parameter(Mandatory)]
        [string]$Metric,

        [Parameter(Mandatory)]
        [ValidateSet('lower', 'higher')]
        [string]$PreferredDirection,

        [Parameter(Mandatory)]
        [int]$Seed
    )

    $logRatios = [Collections.Generic.List[double]]::new()
    foreach ($pair in $Pairs) {
        $baselineValue = [double]$pair.BaselineValue
        $candidateValue = [double]$pair.CandidateValue
        if ($baselineValue -le 0 -or $candidateValue -le 0) {
            throw "$Shape/$Repository/$Candidate-vs-$Baseline/$Metric contains a nonpositive value; paired log ratios are undefined."
        }
        $logRatios.Add([Math]::Log($candidateValue / $baselineValue))
    }
    $meanLogRatio = Get-Mean -Values $logRatios.ToArray()
    $interval = Get-WholeBlockBootstrapInterval `
        -PairedLogRatios $logRatios.ToArray() `
        -Seed $Seed `
        -Iterations 10000
    $effect = ([Math]::Exp($meanLogRatio) - 1.0) * 100.0
    [pscustomobject][ordered]@{
        Shape = $Shape
        Repository = $Repository
        Comparison = "$Candidate-vs-$Baseline"
        BaselineCondition = $Baseline
        CandidateCondition = $Candidate
        ControlKind = if ($Baseline -eq 'BASE' -and $Candidate -eq 'COMPAT') {
            'Explicit 0/0 compatibility overhead control; no post-hoc equivalence tolerance.'
        }
        else {
            'Policy comparison'
        }
        Metric = $Metric
        PreferredDirection = $PreferredDirection
        PairedBlocks = $Pairs.Count
        BaselineArithmeticMean = Get-Mean -Values ([double[]]@($Pairs.BaselineValue))
        CandidateArithmeticMean = Get-Mean -Values ([double[]]@($Pairs.CandidateValue))
        Formula = '100 * (exp(mean(log(candidate / baseline))) - 1)'
        MeanPairedLogRatio = $meanLogRatio
        EffectPercent = $effect
        ConfidenceIntervalLowerPercent = ([Math]::Exp($interval.LowerLogRatio) - 1.0) * 100.0
        ConfidenceIntervalUpperPercent = ([Math]::Exp($interval.UpperLogRatio) - 1.0) * 100.0
        ExactTwoSidedSignFlipP = Get-ExactSignFlipPValue -PairedLogRatios $logRatios.ToArray()
        ExactSignFlipPermutationCount = [int64]1 -shl $Pairs.Count
        MinimumAttainableTwoSidedExactP = 2.0 / ([int64]1 -shl $Pairs.Count)
        DirectionalEstimate = $true
        InferenceScope = "Directional paired estimate with n=$($Pairs.Count); exact p-values are discrete and are not treated as high-powered confirmation."
        ResampleIterations = $interval.Iterations
        Seed = $interval.Seed
        Interpretation = New-PlainLanguageEffect `
            -Candidate $Candidate `
            -Baseline $Baseline `
            -Metric $Metric `
            -EffectPercent $effect `
            -PreferredDirection $PreferredDirection
    }
}
