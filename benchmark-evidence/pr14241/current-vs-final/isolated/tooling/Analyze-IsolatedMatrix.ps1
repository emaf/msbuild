[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    $middle = [int]($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Min($sorted.Count - 1, [Math]::Max(0, [Math]::Ceiling($Percentile * $sorted.Count) - 1))
    return [double]$sorted[$index]
}

function Get-Mean([double[]]$Values) {
    return [double](($Values | Measure-Object -Average).Average)
}

function Get-ProcessMetrics([object[]]$Rows, [pscustomobject]$Run) {
    $rootId = [int]$Run.rootProcessId
    $rootStart = [DateTimeOffset]::Parse([string]$Run.processStartUtc, $culture)
    $peakWorkingSetBytes = 0.0
    $peakPrivateBytes = 0.0
    $peakProcessCount = 0
    $rootObserved = $false
    foreach ($group in ($Rows | Group-Object timestampUtc)) {
        $byId = @{}
        foreach ($row in $group.Group) { $byId[[int]$row.processId] = $row }
        if ($byId.ContainsKey($rootId)) {
            $observedStart = [DateTimeOffset]::Parse([string]$byId[$rootId].processStartUtc, $culture)
            if ([Math]::Abs(($observedStart - $rootStart).TotalSeconds) -le 2.0) { $rootObserved = $true }
        }
        $descendantIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($row in $group.Group) {
            $current = [int]$row.processId
            $visited = [Collections.Generic.HashSet[int]]::new()
            while ($current -gt 0 -and $visited.Add($current)) {
                if ($current -eq $rootId) {
                    if ($byId.ContainsKey($rootId)) {
                        $observedStart = [DateTimeOffset]::Parse([string]$byId[$rootId].processStartUtc, $culture)
                        if ([Math]::Abs(($observedStart - $rootStart).TotalSeconds) -le 2.0) {
                            [void]$descendantIds.Add([int]$row.processId)
                        }
                    }
                    break
                }
                if (-not $byId.ContainsKey($current)) { break }
                $current = [int]$byId[$current].parentProcessId
            }
        }
        $workingSet = 0.0
        $private = 0.0
        foreach ($id in $descendantIds) {
            $workingSet += [double]$byId[$id].workingSetBytes
            $private += [double]$byId[$id].privateBytes
        }
        $peakWorkingSetBytes = [Math]::Max($peakWorkingSetBytes, $workingSet)
        $peakPrivateBytes = [Math]::Max($peakPrivateBytes, $private)
        $peakProcessCount = [Math]::Max($peakProcessCount, $descendantIds.Count)
    }
    return [pscustomobject]@{
        RootObserved = $rootObserved
        PeakWorkingSetMB = $peakWorkingSetBytes / 1MB
        PeakPrivateMB = $peakPrivateBytes / 1MB
        PeakProcessCount = $peakProcessCount
    }
}

function Get-Interval([double[]]$Values, [int]$Seed) {
    $random = [Random]::new($Seed)
    $means = [double[]]::new(10000)
    for ($iteration = 0; $iteration -lt $means.Count; $iteration++) {
        $sum = 0.0
        for ($sample = 0; $sample -lt $Values.Count; $sample++) { $sum += $Values[$random.Next($Values.Count)] }
        $means[$iteration] = $sum / $Values.Count
    }
    return [pscustomobject]@{
        Lower = Get-Percentile $means 0.025
        Upper = Get-Percentile $means 0.975
    }
}

function Get-SignFlipP([double[]]$Values) {
    $observed = [Math]::Abs((Get-Mean $Values))
    $count = [int64]1 -shl $Values.Count
    $extreme = 0
    for ($mask = [int64]0; $mask -lt $count; $mask++) {
        $sum = 0.0
        for ($index = 0; $index -lt $Values.Count; $index++) {
            $sum += $(if (($mask -band ([int64]1 -shl $index)) -eq 0) { -$Values[$index] } else { $Values[$index] })
        }
        if ([Math]::Abs($sum / $Values.Count) -ge ($observed - 1e-12)) { $extreme++ }
    }
    return [double]$extreme / $count
}

$RunRoot = (Resolve-Path $RunRoot).Path
$plan = @(Import-Csv (Join-Path $RunRoot 'matrix-plan.csv'))
$rows = [Collections.Generic.List[object]]::new()
foreach ($planRow in $plan) {
    $repository = $planRow.Repository
    $blockNumber = [int]$planRow.BlockNumber
    $blockRoot = Join-Path $RunRoot "$repository\block-$('{0:D3}' -f $blockNumber)"
    $blockCompletion = Get-Content (Join-Path $blockRoot 'block-completion.json') -Raw | ConvertFrom-Json
    $attempt = 'attempt-{0:D2}' -f [int]$blockCompletion.AttemptNumber
    $scenarioRoot = Join-Path $blockRoot "$attempt\$($planRow.ConditionKey)"
    $summary = Import-Csv (Join-Path $scenarioRoot 'benchmark\scenario-summary.csv') | Select-Object -First 1
    $run = Import-Csv $summary.runs | Select-Object -First 1
    $system = @(Import-Csv (Join-Path $scenarioRoot 'monitor\system.csv'))
    $processes = @(Import-Csv (Join-Path $scenarioRoot 'monitor\processes.csv'))
    $metrics = Get-ProcessMetrics $processes $run
    if (-not $metrics.RootObserved) { throw "Root process was not observed for '$scenarioRoot'." }
    $committed = [double[]]@($system | ForEach-Object { [double]$_.committedBytes })
    $baselineCount = [Math]::Min(3, $committed.Count)
    $baselineCommit = Get-Median ([double[]]$committed[0..($baselineCount - 1)])
    $peakCommit = [double](($committed | Measure-Object -Maximum).Maximum)
    $cpu = [double[]]@($system | ForEach-Object { [double]$_.cpuPercent })
    $rows.Add([pscustomobject][ordered]@{
        Repository = $repository
        BlockNumber = $blockNumber
        AnalysisBlockNumber = [int]$planRow.AnalysisBlockNumber
        IsWarmup = [bool]::Parse($planRow.IsWarmup)
        OrderIndex = [int]$planRow.OrderIndex
        Condition = $planRow.ConditionKey
        AttemptNumber = [int]$blockCompletion.AttemptNumber
        DurationSec = [double]$run.durationSec
        TotalWallSec = [double]$summary.totalWallSec
        PeakCommittedDeltaMB = ($peakCommit - $baselineCommit) / 1MB
        DescendantPeakWorkingSetMB = $metrics.PeakWorkingSetMB
        DescendantPeakPrivateMB = $metrics.PeakPrivateMB
        DescendantPeakProcessCount = $metrics.PeakProcessCount
        CpuMedianPercent = Get-Median $cpu
        CpuP95Percent = Get-Percentile $cpu 0.95
        Binlog = $run.binlog
        RootProcessId = [int]$run.rootProcessId
        ProcessStartUtc = $run.processStartUtc
        ProcessExitUtc = $run.processExitUtc
    })
}

$analysisRoot = Join-Path $RunRoot 'analysis'
New-Item -ItemType Directory -Force -Path $analysisRoot | Out-Null
$rows | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'scenario-metrics.csv')

$measured = @($rows | Where-Object { -not $_.IsWarmup })
$comparisonRows = [Collections.Generic.List[object]]::new()
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($definition in @(
        [pscustomobject]@{ Name = 'COMPAT-vs-BASE'; Baseline = 'BASE'; Candidate = 'COMPAT' },
        [pscustomobject]@{ Name = 'FINAL-N-vs-BASE'; Baseline = 'BASE'; Candidate = 'FINAL-N' },
        [pscustomobject]@{ Name = 'FINAL-N-vs-COMPAT'; Baseline = 'COMPAT'; Candidate = 'FINAL-N' }
    )) {
        $logRatios = [Collections.Generic.List[double]]::new()
        $baselineValues = [Collections.Generic.List[double]]::new()
        $candidateValues = [Collections.Generic.List[double]]::new()
        foreach ($block in 1..6) {
            $blockRows = @($measured | Where-Object { $_.Repository -eq $repository -and $_.AnalysisBlockNumber -eq $block })
            $baseline = $blockRows | Where-Object Condition -eq $definition.Baseline | Select-Object -First 1
            $candidate = $blockRows | Where-Object Condition -eq $definition.Candidate | Select-Object -First 1
            $baselineValues.Add([double]$baseline.DurationSec)
            $candidateValues.Add([double]$candidate.DurationSec)
            $logRatios.Add([Math]::Log([double]$candidate.DurationSec / [double]$baseline.DurationSec))
        }
        $mean = Get-Mean $logRatios.ToArray()
        $interval = Get-Interval $logRatios.ToArray() (20260812 + $comparisonRows.Count)
        $comparisonRows.Add([pscustomobject][ordered]@{
            Repository = $repository
            Comparison = $definition.Name
            BaselineCondition = $definition.Baseline
            CandidateCondition = $definition.Candidate
            Blocks = 6
            BaselineGeometricMeanSec = [Math]::Exp((Get-Mean ([double[]]@($baselineValues | ForEach-Object { [Math]::Log($_) }))))
            CandidateGeometricMeanSec = [Math]::Exp((Get-Mean ([double[]]@($candidateValues | ForEach-Object { [Math]::Log($_) }))))
            EffectPercent = ([Math]::Exp($mean) - 1) * 100
            CiLowerPercent = ([Math]::Exp($interval.Lower) - 1) * 100
            CiUpperPercent = ([Math]::Exp($interval.Upper) - 1) * 100
            ExactSignFlipP = Get-SignFlipP $logRatios.ToArray()
        })
    }
}
$comparisonRows | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'comparisons.csv')

$pressureRows = foreach ($group in ($measured | Group-Object Repository, Condition)) {
    $values = @($group.Group)
    [pscustomobject][ordered]@{
        Repository = $values[0].Repository
        Condition = $values[0].Condition
        Scenarios = $values.Count
        DurationMedianSec = Get-Median ([double[]]$values.DurationSec)
        CommitMedianMB = Get-Median ([double[]]$values.PeakCommittedDeltaMB)
        WorkingSetMedianMB = Get-Median ([double[]]$values.DescendantPeakWorkingSetMB)
        PrivateMedianMB = Get-Median ([double[]]$values.DescendantPeakPrivateMB)
        ProcessCountMedian = Get-Median ([double[]]$values.DescendantPeakProcessCount)
        CpuMedianPercent = Get-Median ([double[]]$values.CpuMedianPercent)
        CpuP95Percent = Get-Median ([double[]]$values.CpuP95Percent)
    }
}
$pressureRows | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'pressure-summary.csv')

$binlogGroups = $rows | Group-Object { if ($_.Condition -eq 'BASE') { 'base' } else { 'final' } }
$identity = Get-Content 'C:\perf\results\current-vs-final-20260811-1950-lean\_setup\exact-build\bootstrap-identities.json' -Raw | ConvertFrom-Json
foreach ($group in $binlogGroups) {
    $role = $group.Name
    $bootstrap = if ($role -eq 'base') { $identity.Base } else { $identity.Final }
    $scannerRoot = "C:\perf\preflight\pr14241-phase-one\attempt-0002\existing-preflight\_tooling\grant-replay-$($bootstrap.MSBuildDllSha256.Substring(0,12))"
    $listPath = Join-Path $analysisRoot "$role-binlogs.txt"
    $scanPath = Join-Path $analysisRoot "$role-grants.json"
    $group.Group.Binlog | Set-Content $listPath
    & $bootstrap.DotNetPath (Join-Path $scannerRoot 'GrantReplay.dll') --output $scanPath --list $listPath
    if ($LASTEXITCODE -ne 0) { throw "Grant replay failed for $role." }
}

$grantRows = [Collections.Generic.List[object]]::new()
foreach ($role in @('base', 'final')) {
    foreach ($scan in @(Get-Content (Join-Path $analysisRoot "$role-grants.json") -Raw | ConvertFrom-Json)) {
        $scenario = $rows | Where-Object Binlog -eq $scan.Path | Select-Object -First 1
        $grants = @($scan.Grants)
        if ($grants.Count -ne 1) { throw "Expected one grant in '$($scan.Path)'." }
        $grantRows.Add([pscustomobject][ordered]@{
            Repository = $scenario.Repository
            BlockNumber = $scenario.BlockNumber
            IsWarmup = $scenario.IsWarmup
            Condition = $scenario.Condition
            GrantedNodes = [int]$grants[0].Nodes
            GrantTimestampUtc = $grants[0].TimestampUtc
            EventCount = [int]$scan.EventCount
            Errors = [int]$scan.ErrorCount
            Warnings = [int]$scan.WarningCount
            Binlog = $scan.Path
        })
    }
}
$grantRows | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'grant-summary.csv')

Write-Host "ANALYSIS_ROOT=$analysisRoot"
Write-Host "SCENARIOS=$($rows.Count)"
Write-Host "GRANTS=$($grantRows.Count)"
