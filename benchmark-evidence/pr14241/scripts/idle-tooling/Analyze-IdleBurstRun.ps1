[CmdletBinding()]
param(
    [string]$RunRoot = 'C:\perf\results\idle-node-burst-matrix-20260807-181942'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$analysisRoot = Join-Path $RunRoot 'analysis'

function Get-Median {
    param([double[]]$Values)

    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [double]$sorted[$middle]
    }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

$planByBlock = @{}
foreach ($row in Import-Csv (Join-Path $RunRoot 'matrix-plan.csv')) {
    $planByBlock["$($row.Repository)|$($row.BlockNumber)"] = [bool]::Parse($row.IsWarmup)
}

$grantByPath = @{}
foreach ($scan in @(Get-Content (Join-Path $analysisRoot 'grant-scan.json') -Raw | ConvertFrom-Json)) {
    $grantByPath[[IO.Path]::GetFullPath($scan.Path).ToLowerInvariant()] = $scan
}

$errors = [Collections.Generic.List[string]]::new()
$grantRows = [Collections.Generic.List[object]]::new()
foreach ($runsPath in Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter 'runs.csv') {
    if ($runsPath.FullName -notmatch '\\(roslyn|aspire)\\block-(\d+)\\attempt-(\d+)\\(F4-N|AUTO-N|F4-H|AUTO-H)\\') {
        continue
    }
    $repository = $Matches[1]
    $blockNumber = [int]$Matches[2]
    $attemptNumber = [int]$Matches[3]
    $condition = $Matches[4]
    $isWarmup = $planByBlock["$repository|$blockNumber"]
    foreach ($run in Import-Csv $runsPath.FullName) {
        $binlogPath = [IO.Path]::GetFullPath($run.binlog)
        $key = $binlogPath.ToLowerInvariant()
        if (-not $grantByPath.ContainsKey($key)) {
            $errors.Add("Missing grant scan for '$binlogPath'.")
            continue
        }
        $grants = @($grantByPath[$key].Grants)
        if ($grants.Count -ne 1) {
            $errors.Add("'$binlogPath' contained $($grants.Count) grant events.")
            continue
        }
        $grant = $grants[0]
        $processStartUtc = ([DateTime]$run.processStartUtc).ToUniversalTime()
        $processExitUtc = ([DateTime]$run.processExitUtc).ToUniversalTime()
        $grantTimestampUtc = ([DateTime]$grant.TimestampUtc).ToUniversalTime()
        $stderrText = Get-Content -LiteralPath $run.stderr -Raw
        if ([int]$run.exitCode -ne 0) {
            $errors.Add("'$binlogPath' exited with code $($run.exitCode).")
        }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $errors.Add("'$($run.stderr)' was not whitespace-only.")
        }
        $grantRows.Add([pscustomobject][ordered]@{
            Repository = $repository
            BlockNumber = $blockNumber
            AttemptNumber = $attemptNumber
            IsWarmup = $isWarmup
            Condition = $condition
            Label = $run.label
            Kind = $run.kind
            Priority = $run.priority
            DurationSec = [double]$run.durationSec
            ProcessStartUtc = $processStartUtc.ToString('O')
            ProcessExitUtc = $processExitUtc.ToString('O')
            GrantTimestampUtc = $grantTimestampUtc.ToString('O')
            GrantDelaySec = ($grantTimestampUtc - $processStartUtc).TotalSeconds
            GrantedNodes = [int]$grant.Nodes
            Binlog = $binlogPath
        })
    }
}

$sequences = [Collections.Generic.List[object]]::new()
foreach ($scenario in $grantRows | Group-Object Repository,BlockNumber,Condition) {
    $rows = @($scenario.Group)
    $condition = $rows[0].Condition
    $byGrant = @($rows | Sort-Object GrantTimestampUtc,ProcessStartUtc)
    if ($condition.StartsWith('F4-', [StringComparison]::Ordinal)) {
        if (@($rows | Where-Object GrantedNodes -ne 4).Count -ne 0) {
            $errors.Add("$($scenario.Name) had a fixed-policy grant other than 4.")
        }
    }
    else {
        if (@($rows | Where-Object GrantedNodes -eq 8).Count -ne 1 -or
            @($rows | Where-Object GrantedNodes -eq 4).Count -ne 4) {
            $errors.Add("$($scenario.Name) did not have exactly one 8-node and four 4-node grants.")
        }
        foreach ($row in $rows | Where-Object GrantedNodes -ne 8) {
            if ($row.GrantedNodes -ne 4) {
                $errors.Add("$($scenario.Name) did not converge to 4 nodes after the burst grant.")
            }
        }
    }
    if ($condition -eq 'AUTO-H') {
        $high = $rows | Where-Object Label -eq 'high1' | Select-Object -First 1
        $firstNormalExitUtc = ($rows |
            Where-Object Kind -eq 'normal' |
            Sort-Object ProcessExitUtc |
            Select-Object -First 1).ProcessExitUtc
        if ($null -eq $high -or $high.Priority -ne 'High' -or $high.GrantedNodes -ne 4 -or
            ([DateTime]$high.GrantTimestampUtc) -ge ([DateTime]$firstNormalExitUtc)) {
            $errors.Add("$($scenario.Name) did not grant delayed High 4 nodes immediately.")
        }
    }
    $burstGrant = $rows | Where-Object GrantedNodes -eq 8 | Select-Object -First 1
    $sequences.Add([pscustomobject][ordered]@{
        Repository = $rows[0].Repository
        BlockNumber = $rows[0].BlockNumber
        IsWarmup = $rows[0].IsWarmup
        Condition = $condition
        GrantSequence = ($byGrant | ForEach-Object { "$($_.Label):$($_.GrantedNodes)" }) -join ','
        BurstGrantLabel = if ($null -ne $burstGrant) { $burstGrant.Label } else { $null }
        BurstGrantDelaySec = if ($null -ne $burstGrant) { $burstGrant.GrantDelaySec } else { $null }
        High1GrantDelaySec = ($rows | Where-Object Label -eq 'high1').GrantDelaySec
        QueuedGrantCount = @($rows | Where-Object GrantDelaySec -ge 20).Count
    })
}

$grantRows | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'grant-events.csv')
$sequences | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'grant-sequences.csv')

$labelEffects = [Collections.Generic.List[object]]::new()
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($pair in @(
        [pscustomobject]@{ Comparison = 'AUTO-N-vs-F4-N'; Numerator = 'AUTO-N'; Denominator = 'F4-N' },
        [pscustomobject]@{ Comparison = 'AUTO-H-vs-F4-H'; Numerator = 'AUTO-H'; Denominator = 'F4-H' }
    )) {
        foreach ($label in @('normal1', 'normal2', 'normal3', 'normal4', 'high1')) {
            $logRatios = [Collections.Generic.List[double]]::new()
            foreach ($blockNumber in 2..5) {
                $numerator = $grantRows | Where-Object {
                    $_.Repository -eq $repository -and $_.BlockNumber -eq $blockNumber -and
                    $_.Condition -eq $pair.Numerator -and $_.Label -eq $label
                } | Select-Object -First 1
                $denominator = $grantRows | Where-Object {
                    $_.Repository -eq $repository -and $_.BlockNumber -eq $blockNumber -and
                    $_.Condition -eq $pair.Denominator -and $_.Label -eq $label
                } | Select-Object -First 1
                if ($null -eq $numerator -or $null -eq $denominator) {
                    $errors.Add("Missing $repository/$($pair.Comparison)/block-$blockNumber/$label.")
                    continue
                }
                $logRatios.Add([Math]::Log($numerator.DurationSec / $denominator.DurationSec))
            }
            $labelEffects.Add([pscustomobject][ordered]@{
                Repository = $repository
                Comparison = $pair.Comparison
                Label = $label
                Blocks = $logRatios.Count
                GeometricDurationEffectPercent = ([Math]::Exp(($logRatios | Measure-Object -Average).Average) - 1) * 100
            })
        }
    }
}
$labelEffects | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'label-duration-effects.csv')

$grantRoleEffects = [Collections.Generic.List[object]]::new()
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($pair in @(
        [pscustomobject]@{ Comparison = 'AUTO-N-vs-F4-N'; Numerator = 'AUTO-N'; Denominator = 'F4-N' },
        [pscustomobject]@{ Comparison = 'AUTO-H-vs-F4-H'; Numerator = 'AUTO-H'; Denominator = 'F4-H' }
    )) {
        $roleBlockRatios = @{}
        foreach ($role in @('Burst8', 'ImmediateNormal4', 'QueuedNormal4', 'DelayedCandidate4')) {
            $roleBlockRatios[$role] = [Collections.Generic.List[double]]::new()
        }
        foreach ($blockNumber in 2..5) {
            $autoRows = @($grantRows | Where-Object {
                $_.Repository -eq $repository -and $_.BlockNumber -eq $blockNumber -and
                $_.Condition -eq $pair.Numerator
            })
            $fixedRows = @($grantRows | Where-Object {
                $_.Repository -eq $repository -and $_.BlockNumber -eq $blockNumber -and
                $_.Condition -eq $pair.Denominator
            })
            $roles = [ordered]@{
                Burst8 = @($autoRows | Where-Object GrantedNodes -eq 8)
                ImmediateNormal4 = @($autoRows | Where-Object {
                    $_.Kind -eq 'normal' -and $_.GrantedNodes -eq 4 -and $_.GrantDelaySec -lt 20
                })
                QueuedNormal4 = @($autoRows | Where-Object {
                    $_.Kind -eq 'normal' -and $_.GrantedNodes -eq 4 -and $_.GrantDelaySec -ge 20
                })
                DelayedCandidate4 = @($autoRows | Where-Object Label -eq 'high1')
            }
            foreach ($role in $roles.Keys) {
                $ratiosWithinBlock = [Collections.Generic.List[double]]::new()
                foreach ($autoRow in $roles[$role]) {
                    $fixedRow = $fixedRows | Where-Object Label -eq $autoRow.Label | Select-Object -First 1
                    if ($null -eq $fixedRow) {
                        $errors.Add("Missing fixed counterpart for $repository/$($pair.Comparison)/block-$blockNumber/$($autoRow.Label).")
                        continue
                    }
                    $ratiosWithinBlock.Add([Math]::Log($autoRow.DurationSec / $fixedRow.DurationSec))
                }
                if ($ratiosWithinBlock.Count -gt 0) {
                    $roleBlockRatios[$role].Add(($ratiosWithinBlock | Measure-Object -Average).Average)
                }
            }
        }
        foreach ($role in $roleBlockRatios.Keys) {
            $values = $roleBlockRatios[$role]
            $grantRoleEffects.Add([pscustomobject][ordered]@{
                Repository = $repository
                Comparison = $pair.Comparison
                GrantRole = $role
                Blocks = $values.Count
                GeometricDurationEffectPercent = ([Math]::Exp(($values | Measure-Object -Average).Average) - 1) * 100
            })
        }
    }
}
$grantRoleEffects | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'grant-role-duration-effects.csv')

$scenarioMetrics = @(Import-Csv (Join-Path $analysisRoot 'scenario-metrics.csv') | Where-Object IsWarmup -eq 'False')
$pressure = [Collections.Generic.List[object]]::new()
foreach ($group in $scenarioMetrics | Group-Object Repository,ConditionKey) {
    $rows = @($group.Group)
    $pressure.Add([pscustomobject][ordered]@{
        Repository = $rows[0].Repository
        Condition = $rows[0].ConditionKey
        Blocks = $rows.Count
        WallMedianSec = Get-Median ([double[]]$rows.TotalWallSec)
        CandidateMedianSec = Get-Median ([double[]]$rows.CandidateDurationSec)
        AverageNormalMedianSec = Get-Median ([double[]]$rows.AverageNormalDurationSec)
        PeakCommittedDeltaMedianMB = Get-Median ([double[]]$rows.PeakCommittedDeltaMB)
        DescendantPeakWorkingSetMedianMB = Get-Median ([double[]]$rows.DescendantPeakWorkingSetMB)
        DescendantPeakPrivateMedianMB = Get-Median ([double[]]$rows.DescendantPeakPrivateMB)
        DescendantPeakProcessCountMedian = Get-Median ([double[]]$rows.DescendantPeakProcessCount)
        ProcessorQueueP95Median = Get-Median ([double[]]$rows.ProcessorQueueP95)
        ProbeP95MedianMs = Get-Median ([double[]]$rows.ProbeP95Ms)
    })
}
$pressure | Export-Csv -NoTypeInformation (Join-Path $analysisRoot 'pressure-medians.csv')

$summary = [ordered]@{
    Valid = $errors.Count -eq 0
    Errors = $errors
    BinlogsReplayed = $grantByPath.Count
    GrantEvents = $grantRows.Count
    Scenarios = $sequences.Count
    MeasuredScenarios = @($sequences | Where-Object { -not $_.IsWarmup }).Count
    WarmupScenarios = @($sequences | Where-Object IsWarmup).Count
    MaximumAutoHighGrantDelaySec = ($grantRows |
        Where-Object { $_.Condition -eq 'AUTO-H' -and $_.Label -eq 'high1' } |
        Measure-Object GrantDelaySec -Maximum).Maximum
    MinimumAutoHighGrantDelaySec = ($grantRows |
        Where-Object { $_.Condition -eq 'AUTO-H' -and $_.Label -eq 'high1' } |
        Measure-Object GrantDelaySec -Minimum).Minimum
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $analysisRoot 'grant-validation.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 6
if (-not $summary.Valid) {
    exit 1
}
