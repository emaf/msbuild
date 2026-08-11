<#
.SYNOPSIS
Validates and analyzes a Run-PublicRepoCoordinatorMatrix.ps1 run root.

.DESCRIPTION
Validation is repeated from raw artifacts. Analysis stays within repository and
block, uses paired log ratios, deterministic block resampling for 95% confidence
intervals, and exact two-sided sign-flip tests when the number of blocks is small
enough to enumerate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot,

    [string]$OutputRoot,
    [int]$ResampleIterations = 10000,
    [int]$RandomSeed = 20260723
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
$minimumInferentialPairedBlocks = 10
$maximumExactSignFlipBlocks = 20

if (-not (Test-Path -LiteralPath $RunRoot)) {
    throw "RunRoot '$RunRoot' does not exist."
}
$RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RunRoot 'analysis'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

function Add-ValidationError {
    param(
        [Collections.Generic.List[string]]$Errors,
        [string]$Message
    )

    $Errors.Add($Message)
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return 0.0
    }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Min(
        $sorted.Count - 1,
        [Math]::Max(0, [Math]::Ceiling($Percentile * $sorted.Count) - 1))
    return [double]$sorted[$index]
}

function Get-Median {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
        return 0.0
    }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [double]$sorted[$middle]
    }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-Average {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
        return 0.0
    }
    $sum = 0.0
    foreach ($value in $Values) {
        $sum += $value
    }
    return $sum / $Values.Count
}

function Get-TimestampGaps {
    param([object[]]$Rows)

    $gaps = [Collections.Generic.List[object]]::new()
    for ($index = 1; $index -lt $Rows.Count; $index++) {
        $start = [DateTime]$Rows[$index - 1].timestampUtc
        $end = [DateTime]$Rows[$index].timestampUtc
        $gaps.Add([pscustomobject]@{
            GapIndex = $index
            StartUtc = $start.ToUniversalTime().ToString('O')
            EndUtc = $end.ToUniversalTime().ToString('O')
            GapSeconds = ($end - $start).TotalSeconds
        })
    }
    return $gaps
}

function Get-MaxTimestampGapSeconds {
    param([object[]]$Gaps)

    if ($Gaps.Count -eq 0) {
        return 0.0
    }
    return ($Gaps.GapSeconds | Measure-Object -Maximum).Maximum
}

function New-SystemGapDistributionRow {
    param(
        [string]$Scope,
        [string]$BlockKind,
        [string]$Repository,
        [string]$ConditionKey,
        [object[]]$Rows
    )

    $values = [double[]]@($Rows | ForEach-Object { [double]$_.GapSeconds })
    return [pscustomobject][ordered]@{
        Scope = $Scope
        BlockKind = $BlockKind
        Repository = $Repository
        ConditionKey = $ConditionKey
        WarningGapCount = $values.Count
        MinimumGapSeconds = if ($values.Count -gt 0) { ($values | Measure-Object -Minimum).Minimum } else { $null }
        MedianGapSeconds = if ($values.Count -gt 0) { Get-Median $values } else { $null }
        P95GapSeconds = if ($values.Count -gt 0) { Get-Percentile -Values $values -Percentile 0.95 } else { $null }
        P99GapSeconds = if ($values.Count -gt 0) { Get-Percentile -Values $values -Percentile 0.99 } else { $null }
        MaximumGapSeconds = if ($values.Count -gt 0) { ($values | Measure-Object -Maximum).Maximum } else { $null }
    }
}

function New-SystemGapWarningRow {
    param(
        [string]$Repository = '',
        [int]$BlockNumber = 0,
        [int]$AnalysisBlockNumber = 0,
        [bool]$IsWarmup = $false,
        [int]$AttemptNumber = 0,
        [int]$OrderIndex = 0,
        [string]$ConditionKey = '',
        [int]$GapIndex = 0,
        [string]$StartUtc = '',
        [string]$EndUtc = '',
        [double]$GapSeconds = 0,
        [double]$WarningThresholdSeconds = 0,
        [double]$HardThresholdSeconds = 0,
        [string]$SystemCsv = ''
    )

    return [pscustomobject][ordered]@{
        Repository = $Repository
        BlockNumber = $BlockNumber
        AnalysisBlockNumber = $AnalysisBlockNumber
        IsWarmup = $IsWarmup
        AttemptNumber = $AttemptNumber
        OrderIndex = $OrderIndex
        ConditionKey = $ConditionKey
        GapIndex = $GapIndex
        StartUtc = $StartUtc
        EndUtc = $EndUtc
        GapSeconds = $GapSeconds
        WarningThresholdSeconds = $WarningThresholdSeconds
        HardThresholdSeconds = $HardThresholdSeconds
        SystemCsv = $SystemCsv
    }
}

function Get-StableHash {
    param([string]$Value)

    $hash = 17
    foreach ($character in $Value.ToCharArray()) {
        $hash = (($hash * 31) + [int]$character) -band 0x7fffffff
    }
    return $hash
}

function Get-ResampledMeanInterval {
    param(
        [double[]]$Values,
        [int]$Seed
    )

    if ($Values.Count -eq 0) {
        return [pscustomobject]@{ Lower = 0.0; Upper = 0.0 }
    }
    $random = [Random]::new($Seed)
    $means = [double[]]::new($ResampleIterations)
    for ($iteration = 0; $iteration -lt $ResampleIterations; $iteration++) {
        $sum = 0.0
        for ($sample = 0; $sample -lt $Values.Count; $sample++) {
            $sum += $Values[$random.Next($Values.Count)]
        }
        $means[$iteration] = $sum / $Values.Count
    }
    return [pscustomobject]@{
        Lower = Get-Percentile -Values $means -Percentile 0.025
        Upper = Get-Percentile -Values $means -Percentile 0.975
    }
}

function Get-ExactSignFlipPValue {
    param([double[]]$Values)

    if ($Values.Count -eq 0 -or $Values.Count -gt $maximumExactSignFlipBlocks) {
        return $null
    }
    $observed = [Math]::Abs((Get-Average -Values $Values))
    $permutations = [int64]1 -shl $Values.Count
    $extreme = [int64]0
    for ($mask = [int64]0; $mask -lt $permutations; $mask++) {
        $sum = 0.0
        for ($index = 0; $index -lt $Values.Count; $index++) {
            $sign = if (($mask -band ([int64]1 -shl $index)) -eq 0) { -1.0 } else { 1.0 }
            $sum += $sign * $Values[$index]
        }
        if ([Math]::Abs($sum / $Values.Count) -ge ($observed - 1e-12)) {
            $extreme++
        }
    }
    return [double]$extreme / [double]$permutations
}

function Convert-LogEffectToPercent {
    param([double]$LogEffect)

    return ([Math]::Exp($LogEffect) - 1.0) * 100.0
}

function Get-ProcessMetrics {
    param(
        [object[]]$Rows,
        [object[]]$RootProcesses
    )

    $roots = @{}
    foreach ($rootProcess in $RootProcesses) {
        $roots[[int]$rootProcess.rootProcessId] = [DateTime]$rootProcess.processStartUtc
    }
    $peakWorkingSetBytes = 0.0
    $peakPrivateBytes = 0.0
    $peakProcessCount = 0
    $peakNoiseWorkingSetBytes = 0.0
    $peakNoiseProcessCount = 0

    foreach ($group in ($Rows | Group-Object timestampUtc)) {
        $byId = @{}
        foreach ($row in $group.Group) {
            $byId[[int]$row.processId] = $row
        }
        $descendantIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($row in $group.Group) {
            $current = [int]$row.processId
            $visited = [Collections.Generic.HashSet[int]]::new()
            while ($current -gt 0 -and $visited.Add($current)) {
                if ($roots.ContainsKey($current)) {
                    if ($byId.ContainsKey($current) -and
                        -not [string]::IsNullOrWhiteSpace([string]$byId[$current].processStartUtc)) {
                        $observedStart = [DateTime]$byId[$current].processStartUtc
                        if ([Math]::Abs(($observedStart - $roots[$current]).TotalSeconds) -le 2) {
                            [void]$descendantIds.Add([int]$row.processId)
                            break
                        }
                    }
                    break
                }
                if (-not $byId.ContainsKey($current)) {
                    break
                }
                $current = [int]$byId[$current].parentProcessId
            }
        }

        $workingSetBytes = 0.0
        $privateBytes = 0.0
        foreach ($processId in $descendantIds) {
            $row = $byId[$processId]
            if (-not [string]::IsNullOrWhiteSpace([string]$row.workingSetBytes)) {
                $workingSetBytes += [double]$row.workingSetBytes
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$row.privateBytes)) {
                $privateBytes += [double]$row.privateBytes
            }
        }
        $peakWorkingSetBytes = [Math]::Max($peakWorkingSetBytes, $workingSetBytes)
        $peakPrivateBytes = [Math]::Max($peakPrivateBytes, $privateBytes)
        $peakProcessCount = [Math]::Max($peakProcessCount, $descendantIds.Count)

        $noiseRows = @($group.Group | Where-Object category -eq 'external-noise-known')
        $noiseWorkingSetBytes = 0.0
        foreach ($noiseRow in $noiseRows) {
            if (-not [string]::IsNullOrWhiteSpace([string]$noiseRow.workingSetBytes)) {
                $noiseWorkingSetBytes += [double]$noiseRow.workingSetBytes
            }
        }
        $peakNoiseWorkingSetBytes = [Math]::Max($peakNoiseWorkingSetBytes, $noiseWorkingSetBytes)
        $peakNoiseProcessCount = [Math]::Max($peakNoiseProcessCount, $noiseRows.Count)
    }

    return [pscustomobject]@{
        PeakWorkingSetMB = $peakWorkingSetBytes / 1MB
        PeakPrivateMB = $peakPrivateBytes / 1MB
        PeakProcessCount = $peakProcessCount
        PeakExternalNoiseWorkingSetMB = $peakNoiseWorkingSetBytes / 1MB
        PeakExternalNoiseProcessCount = $peakNoiseProcessCount
    }
}

function Format-Percent {
    param([double]$Value)

    $prefix = if ($Value -gt 0) { '+' } else { '' }
    return "$prefix$($Value.ToString('F1', $culture))%"
}

function Test-RecordedBootstrap {
    param(
        [pscustomobject]$Bootstrap,
        [Collections.Generic.List[string]]$Errors,
        [Collections.Generic.List[string]]$Warnings
    )

    if ($Bootstrap.ValidationStatus -ne 'Verified') {
        Add-ValidationError $Errors "Recorded $($Bootstrap.Role) bootstrap was not verified."
        return
    }

    $trackedFiles = if ($null -ne $Bootstrap.PSObject.Properties['TrackedFiles']) {
        @($Bootstrap.TrackedFiles)
    }
    else {
        @(
            [pscustomobject]@{ Name = 'dotnet.exe'; Path = $Bootstrap.DotNetPath; Sha256 = $Bootstrap.DotNetSha256 },
            [pscustomobject]@{ Name = 'MSBuild.dll'; Path = $Bootstrap.MSBuildDllPath; Sha256 = $Bootstrap.MSBuildDllSha256 }
        )
    }
    $missingCanonicalFile = $false
    foreach ($trackedFile in $trackedFiles) {
        if (-not (Test-Path -LiteralPath $trackedFile.Path -PathType Leaf)) {
            Add-ValidationError $Errors "Recorded $($Bootstrap.Role) tracked file '$($trackedFile.Path)' is missing."
            $missingCanonicalFile = $true
            continue
        }
        $hash = (Get-FileHash -LiteralPath $trackedFile.Path -Algorithm SHA256).Hash
        if ($hash -ne $trackedFile.Sha256) {
            Add-ValidationError $Errors "Recorded $($Bootstrap.Role) tracked file '$($trackedFile.Path)' no longer matches its hash."
        }
    }
    if (-not $missingCanonicalFile) {
        $msbuildFile = $trackedFiles | Where-Object Name -eq 'MSBuild.dll' | Select-Object -First 1
        $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($msbuildFile.Path).ProductVersion
        if ($productVersion -ne $Bootstrap.ProductVersion -or
            -not $productVersion.Contains($Bootstrap.ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
            Add-ValidationError $Errors "Recorded $($Bootstrap.Role) bootstrap ProductVersion no longer identifies '$($Bootstrap.ExpectedCommit)'."
        }
    }

    if ($null -ne $Bootstrap.PSObject.Properties['StagedTrackedFiles']) {
        $stagedFiles = @($Bootstrap.StagedTrackedFiles)
        $missingStagedFiles = @($stagedFiles | Where-Object { -not (Test-Path -LiteralPath $_.Path -PathType Leaf) })
        if ($missingStagedFiles.Count -gt 0) {
            $Warnings.Add("Recorded $($Bootstrap.Role) staging files are no longer available; canonical bootstrap identity remains authoritative.")
        }
        foreach ($stagedFile in $stagedFiles) {
            if (-not (Test-Path -LiteralPath $stagedFile.Path -PathType Leaf)) {
                continue
            }
            $hash = (Get-FileHash -LiteralPath $stagedFile.Path -Algorithm SHA256).Hash
            if ($hash -ne $stagedFile.Sha256) {
                Add-ValidationError $Errors "Recorded $($Bootstrap.Role) staged file '$($stagedFile.Path)' no longer matches its hash."
            }
        }
    }
}

$metadataPath = Join-Path $RunRoot 'run-metadata.json'
$matrixPath = Join-Path $RunRoot 'matrix-plan.csv'
if (-not (Test-Path -LiteralPath $metadataPath) -or -not (Test-Path -LiteralPath $matrixPath)) {
    throw 'Run metadata or matrix plan is missing.'
}
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$matrixRows = @(Import-Csv -LiteralPath $matrixPath)
$designKind = if ($null -ne $metadata.PSObject.Properties['DesignKind']) {
    [string]$metadata.DesignKind
}
elseif ([int]$metadata.CandidateBuildCount -eq 1) {
    'paired-priority'
}
else {
    'single-build-compatibility'
}
$maxProcessSnapshotGapSeconds = if ($null -ne $metadata.PSObject.Properties['MaxProcessSnapshotGapSeconds']) {
    [double]$metadata.MaxProcessSnapshotGapSeconds
}
else {
    15.0
}
$maxProbeGapSeconds = if ($null -ne $metadata.PSObject.Properties['MaxProbeGapSeconds']) {
    [double]$metadata.MaxProbeGapSeconds
}
else {
    15.0
}
$hasSeparateSystemGapThresholds = $null -ne $metadata.PSObject.Properties['MaxSystemCounterGapSeconds']
$systemGapWarningThresholdSeconds = if ($null -ne $metadata.PSObject.Properties['SystemGapWarningThresholdSeconds']) {
    [double]$metadata.SystemGapWarningThresholdSeconds
}
else {
    [double]$metadata.MaxTelemetryGapSeconds
}
$maxSystemCounterGapSeconds = if ($hasSeparateSystemGapThresholds) {
    [double]$metadata.MaxSystemCounterGapSeconds
}
else {
    [double]$metadata.MaxTelemetryGapSeconds
}
$validationErrors = [Collections.Generic.List[string]]::new()
$validationWarnings = [Collections.Generic.List[string]]::new()
if ($systemGapWarningThresholdSeconds -le 0 -or $maxSystemCounterGapSeconds -le 0) {
    Add-ValidationError $validationErrors 'System-counter gap thresholds must be positive.'
}
elseif ($hasSeparateSystemGapThresholds -and
    $systemGapWarningThresholdSeconds -gt $maxSystemCounterGapSeconds) {
    Add-ValidationError $validationErrors 'The system-counter warning threshold must not exceed the hard threshold.'
}
if (-not $metadata.PlanOnly) {
    Test-RecordedBootstrap -Bootstrap $metadata.BaseBootstrap -Errors $validationErrors -Warnings $validationWarnings
    Test-RecordedBootstrap -Bootstrap $metadata.CandidateBootstrap -Errors $validationErrors -Warnings $validationWarnings
}

$conditionByKey = @{}
foreach ($condition in $metadata.Conditions) {
    $conditionByKey[$condition.Key] = $condition
}
$repositoryByName = @{}
foreach ($repository in $metadata.Repositories) {
    $repositoryByName[$repository.Name] = $repository
}

if ($conditionByKey.ContainsKey('D-candidate-default-normal') -and
    $conditionByKey.ContainsKey('E-candidate-default-high')) {
    $normal = $conditionByKey['D-candidate-default-normal']
    $high = $conditionByKey['E-candidate-default-high']
    foreach ($property in @('BootstrapRole', 'UseCoordinator', 'NodeBudget', 'Slice', 'Reservation')) {
        if ([string]$normal.$property -cne [string]$high.$property) {
            Add-ValidationError $validationErrors "D and E differ in '$property'."
        }
    }
    if ($normal.CandidatePriority -ne 'Normal' -or $high.CandidatePriority -ne 'High') {
        Add-ValidationError $validationErrors 'D/E candidate priorities are not Normal/High.'
    }
}

foreach ($repository in $metadata.Repositories) {
    if ($repository.ValidationStatus -eq 'Verified') {
        $actualCommit = (& git -C $repository.Root rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $repository.ActualCommit) {
            Add-ValidationError $validationErrors "Repository '$($repository.Name)' no longer matches recorded commit '$($repository.ActualCommit)'."
        }
    }
}

if ($metadata.PlanOnly) {
    foreach ($repository in $metadata.Repositories) {
        $repositoryRows = @($matrixRows | Where-Object Repository -eq $repository.Name)
        foreach ($blockNumber in @($repositoryRows.BlockNumber | Sort-Object -Unique)) {
            $blockRows = @($repositoryRows | Where-Object BlockNumber -eq $blockNumber)
            if ($blockRows.Count -ne $metadata.Conditions.Count) {
                Add-ValidationError $validationErrors "Plan block $($repository.Name)/$blockNumber has $($blockRows.Count) rows."
            }
            if (@($blockRows.ConditionKey | Sort-Object -Unique).Count -ne $metadata.Conditions.Count) {
                Add-ValidationError $validationErrors "Plan block $($repository.Name)/$blockNumber does not contain each condition once."
            }
        }
    }
    if ([int]$metadata.PrimaryBlocks -eq @($metadata.OrderDesign.DesignRows).Count) {
        if ([int]$metadata.OrderDesign.Diagnostics.PositionImbalance -ne 0 -or
            [int]$metadata.OrderDesign.Diagnostics.CarryoverImbalance -ne 0) {
            Add-ValidationError $validationErrors 'Complete Williams design is not exactly balanced.'
        }
    }

    $planValidation = [ordered]@{
        RunRoot = $RunRoot
        PlanOnly = $true
        Valid = $validationErrors.Count -eq 0
        MatrixRows = $matrixRows.Count
        PositionImbalance = $metadata.OrderDesign.Diagnostics.PositionImbalance
        CarryoverImbalance = $metadata.OrderDesign.Diagnostics.CarryoverImbalance
        Errors = $validationErrors
        Warnings = $validationWarnings
    }
    $planValidation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'validation.json') -Encoding UTF8
    if ($validationErrors.Count -gt 0) {
        throw "Plan validation failed: $($validationErrors -join '; ')"
    }
    Write-Host "PLAN_VALIDATION=True"
    Write-Host "ANALYSIS_ROOT=$OutputRoot"
    return
}

$isPrepareOnly = $null -ne $metadata.PSObject.Properties['PrepareOnly'] -and [bool]$metadata.PrepareOnly
if ($isPrepareOnly) {
    if (-not (Test-Path -LiteralPath (Join-Path $RunRoot 'preparation-completion.json'))) {
        Add-ValidationError $validationErrors 'Preparation completion marker is missing.'
    }
    $keepAwakePath = Join-Path $RunRoot 'keep-awake.json'
    if (-not (Test-Path -LiteralPath $keepAwakePath)) {
        Add-ValidationError $validationErrors 'Keep-awake cleanup record is missing.'
    }
    else {
        $keepAwake = Get-Content -LiteralPath $keepAwakePath -Raw | ConvertFrom-Json
        if ($keepAwake.Restored -ne $true) {
            Add-ValidationError $validationErrors 'SetThreadExecutionState was not restored.'
        }
    }
    foreach ($repository in $metadata.Repositories) {
        foreach ($role in @('base', 'candidate')) {
            $smokePath = Join-Path $RunRoot "_setup\$($repository.Name)-$role-preparation-smoke.json"
            if (-not (Test-Path -LiteralPath $smokePath -PathType Leaf)) {
                Add-ValidationError $validationErrors "Preparation smoke '$smokePath' is missing."
                continue
            }
            $smoke = Get-Content -LiteralPath $smokePath -Raw | ConvertFrom-Json
            if ($smoke.Valid -ne $true) {
                Add-ValidationError $validationErrors "Preparation smoke '$smokePath' is invalid."
            }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $RunRoot "_setup\$($repository.Name)\scenario-summary.csv"))) {
            Add-ValidationError $validationErrors "Preparation summary for '$($repository.Name)' is missing."
        }
    }
    $scenarioMetadataCount = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter scenario-metadata.json -ErrorAction SilentlyContinue).Count
    if ($scenarioMetadataCount -ne 0) {
        Add-ValidationError $validationErrors "PrepareOnly root contains $scenarioMetadataCount measured scenario metadata file(s)."
    }

    $preparationValidation = [ordered]@{
        RunRoot = $RunRoot
        PrepareOnly = $true
        Valid = $validationErrors.Count -eq 0
        RepositoryCount = @($metadata.Repositories).Count
        MeasuredScenarioCount = $scenarioMetadataCount
        Errors = $validationErrors
        Warnings = $validationWarnings
    }
    $preparationValidation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'validation.json') -Encoding UTF8
    if ($validationErrors.Count -gt 0) {
        throw "Preparation validation failed: $($validationErrors -join '; ')"
    }
    Write-Host 'PREPARATION_VALIDATION=True'
    Write-Host "ANALYSIS_ROOT=$OutputRoot"
    return
}

if (-not (Test-Path -LiteralPath (Join-Path $RunRoot 'completion.json'))) {
    Add-ValidationError $validationErrors 'Run completion marker is missing.'
}
$keepAwakePath = Join-Path $RunRoot 'keep-awake.json'
if (-not (Test-Path -LiteralPath $keepAwakePath)) {
    Add-ValidationError $validationErrors 'Keep-awake cleanup record is missing.'
}
else {
    $keepAwake = Get-Content -LiteralPath $keepAwakePath -Raw | ConvertFrom-Json
    if ($keepAwake.Restored -ne $true) {
        Add-ValidationError $validationErrors 'SetThreadExecutionState was not restored.'
    }
}

$scenarioMetrics = [Collections.Generic.List[object]]::new()
$systemGapWarnings = [Collections.Generic.List[object]]::new()
$validPrimaryBlocks = 0
$validWarmupBlocks = 0
foreach ($repository in $metadata.Repositories) {
    $repositoryRows = @($matrixRows | Where-Object Repository -eq $repository.Name)
    foreach ($blockNumber in @($repositoryRows.BlockNumber | Sort-Object -Unique)) {
        $blockRows = @($repositoryRows | Where-Object BlockNumber -eq $blockNumber | Sort-Object OrderIndex)
        $blockRoot = Join-Path $RunRoot "$($repository.Name)\block-$('{0:D3}' -f [int]$blockNumber)"
        $completionPath = Join-Path $blockRoot 'block-completion.json'
        if (-not (Test-Path -LiteralPath $completionPath)) {
            Add-ValidationError $validationErrors "Block completion is missing for $($repository.Name)/$blockNumber."
            continue
        }
        $blockCompletion = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
        if ($blockCompletion.Valid -ne $true) {
            Add-ValidationError $validationErrors "Block $($repository.Name)/$blockNumber is not valid."
            continue
        }
        $attemptRoot = Join-Path $blockRoot "attempt-$('{0:D2}' -f [int]$blockCompletion.AttemptNumber)"
        if (-not (Test-Path -LiteralPath (Join-Path $attemptRoot 'valid-attempt.json'))) {
            Add-ValidationError $validationErrors "Valid attempt marker is missing for $($repository.Name)/$blockNumber."
            continue
        }

        $blockIsValid = $true
        $blockSystemGapWarnings = [Collections.Generic.List[object]]::new()
        foreach ($blockRow in $blockRows) {
            $condition = $conditionByKey[$blockRow.ConditionKey]
            $scenarioRoot = Join-Path $attemptRoot $blockRow.ConditionKey
            $scenarioMetadataPath = Join-Path $scenarioRoot 'scenario-metadata.json'
            $scenarioValidationPath = Join-Path $scenarioRoot 'scenario-validation.json'
            if (-not (Test-Path -LiteralPath $scenarioMetadataPath) -or
                -not (Test-Path -LiteralPath $scenarioValidationPath)) {
                Add-ValidationError $validationErrors "Scenario metadata/validation is missing at '$scenarioRoot'."
                $blockIsValid = $false
                continue
            }
            $scenarioMetadata = Get-Content -LiteralPath $scenarioMetadataPath -Raw | ConvertFrom-Json
            $scenarioValidation = Get-Content -LiteralPath $scenarioValidationPath -Raw | ConvertFrom-Json
            if ($scenarioValidation.Valid -ne $true -or $scenarioMetadata.Succeeded -ne $true) {
                Add-ValidationError $validationErrors "Scenario '$scenarioRoot' is not valid."
                $blockIsValid = $false
            }
            if ($scenarioMetadata.RepositoryCommit -ne $repository.ActualCommit) {
                Add-ValidationError $validationErrors "Repository commit mismatch in '$scenarioRoot'."
                $blockIsValid = $false
            }
            $bootstrap = if ($condition.BootstrapRole -eq 'base') {
                $metadata.BaseBootstrap
            }
            else {
                $metadata.CandidateBootstrap
            }
            if ($scenarioMetadata.BootstrapCommit -ne $bootstrap.ExpectedCommit -or
                $scenarioMetadata.BootstrapProductVersion -ne $bootstrap.ProductVersion) {
                Add-ValidationError $validationErrors "Bootstrap identity mismatch in '$scenarioRoot'."
                $blockIsValid = $false
            }

            $summaryFiles = @(Get-ChildItem (Join-Path $scenarioRoot 'benchmark') -Filter scenario-summary.csv -ErrorAction SilentlyContinue)
            if ($summaryFiles.Count -ne 1) {
                Add-ValidationError $validationErrors "Expected one summary in '$scenarioRoot'."
                $blockIsValid = $false
                continue
            }
            $summary = Import-Csv -LiteralPath $summaryFiles[0].FullName | Select-Object -First 1
            $runs = @(Import-Csv -LiteralPath $summary.runs)
            if ($runs.Count -ne ([int]$metadata.NormalBuildCount + [int]$metadata.CandidateBuildCount)) {
                Add-ValidationError $validationErrors "Build count mismatch in '$scenarioRoot'."
                $blockIsValid = $false
            }
            if (@($runs | Where-Object kind -eq 'normal').Count -ne [int]$metadata.NormalBuildCount -or
                @($runs | Where-Object kind -eq 'high').Count -ne [int]$metadata.CandidateBuildCount) {
                Add-ValidationError $validationErrors "Normal/candidate build-kind count mismatch in '$scenarioRoot'."
                $blockIsValid = $false
            }
            foreach ($run in $runs) {
                if ([int]$run.exitCode -ne 0 -or [int]$run.rootProcessId -le 0) {
                    Add-ValidationError $validationErrors "Build exit/root PID failure for '$($run.label)' in '$scenarioRoot'."
                    $blockIsValid = $false
                }
                if (-not (Test-Path -LiteralPath $run.stderr) -or
                    -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $run.stderr -Raw))) {
                    Add-ValidationError $validationErrors "Missing or non-empty stderr for '$($run.label)' in '$scenarioRoot'."
                    $blockIsValid = $false
                }
                if ([string]::IsNullOrWhiteSpace([string]$run.processStartUtc) -or
                    [string]::IsNullOrWhiteSpace([string]$run.processExitUtc) -or
                    [DateTime]$run.processExitUtc -lt [DateTime]$run.processStartUtc) {
                    Add-ValidationError $validationErrors "Invalid process timestamps for '$($run.label)' in '$scenarioRoot'."
                    $blockIsValid = $false
                }
                if (-not (Test-Path -LiteralPath $run.binlog) -or
                    (Get-Item -LiteralPath $run.binlog -ErrorAction SilentlyContinue).Length -eq 0) {
                    Add-ValidationError $validationErrors "Missing or empty binlog for '$($run.label)' in '$scenarioRoot'."
                    $blockIsValid = $false
                }
            }
            $worktreeCommits = @($scenarioMetadata.WorktreeCommits)
            if ($worktreeCommits.Count -ne $runs.Count) {
                Add-ValidationError $validationErrors "Worktree commit count mismatch in '$scenarioRoot'."
                $blockIsValid = $false
            }
            foreach ($run in $runs) {
                $worktree = $worktreeCommits | Where-Object Name -eq $run.label | Select-Object -First 1
                if ($null -eq $worktree -or $worktree.Commit -ne $repository.ActualCommit) {
                    Add-ValidationError $validationErrors "Worktree '$($run.label)' commit mismatch in '$scenarioRoot'."
                    $blockIsValid = $false
                }
            }
            $candidate = $runs | Where-Object kind -eq 'high' | Select-Object -First 1
            $candidateOffset = $null
            if ([int]$metadata.CandidateBuildCount -eq 1) {
                if ($null -eq $candidate) {
                    Add-ValidationError $validationErrors "Candidate row is missing in '$scenarioRoot'."
                    $blockIsValid = $false
                    continue
                }
                $candidateOffset = [double]$candidate.startOffsetSec
                if ($candidateOffset -lt [double]$metadata.CandidateOffsetMinimumSeconds -or
                    $candidateOffset -gt [double]$metadata.CandidateOffsetMaximumSeconds) {
                    Add-ValidationError $validationErrors "Candidate offset $candidateOffset is invalid in '$scenarioRoot'."
                    $blockIsValid = $false
                }
            }

            $monitorRoot = Join-Path $scenarioRoot 'monitor'
            $systemPath = Join-Path $monitorRoot 'system.csv'
            $processPath = Join-Path $monitorRoot 'processes.csv'
            $probePath = Join-Path $monitorRoot 'probes.csv'
            if (-not (Test-Path -LiteralPath $systemPath) -or
                -not (Test-Path -LiteralPath $processPath) -or
                -not (Test-Path -LiteralPath $probePath)) {
                Add-ValidationError $validationErrors "Telemetry files are missing in '$scenarioRoot'."
                $blockIsValid = $false
                continue
            }
            $systemRows = @(Import-Csv -LiteralPath $systemPath)
            $processRows = @(Import-Csv -LiteralPath $processPath)
            $probeRows = @(Import-Csv -LiteralPath $probePath)
            $processSnapshots = @(
                $processRows |
                    Group-Object timestampUtc |
                    ForEach-Object { $_.Group[0] }
            )
            if ($systemRows.Count -lt 2 -or $processSnapshots.Count -lt 2 -or $probeRows.Count -lt 2) {
                Add-ValidationError $validationErrors "Telemetry files are empty in '$scenarioRoot'."
                $blockIsValid = $false
                continue
            }
            $systemGaps = @(Get-TimestampGaps -Rows $systemRows)
            $processGaps = @(Get-TimestampGaps -Rows $processSnapshots)
            $probeGaps = @(Get-TimestampGaps -Rows $probeRows)
            $maxSystemGap = Get-MaxTimestampGapSeconds -Gaps $systemGaps
            $maxProcessGap = Get-MaxTimestampGapSeconds -Gaps $processGaps
            $maxProbeGap = Get-MaxTimestampGapSeconds -Gaps $probeGaps
            $scenarioSystemGapWarnings = @(
                $systemGaps |
                    Where-Object GapSeconds -gt $systemGapWarningThresholdSeconds
            )
            foreach ($gap in $scenarioSystemGapWarnings) {
                $blockSystemGapWarnings.Add((New-SystemGapWarningRow `
                    -Repository $repository.Name `
                    -BlockNumber ([int]$blockRow.BlockNumber) `
                    -AnalysisBlockNumber ([int]$blockRow.AnalysisBlockNumber) `
                    -IsWarmup ([bool]::Parse([string]$blockRow.IsWarmup)) `
                    -AttemptNumber ([int]$blockCompletion.AttemptNumber) `
                    -OrderIndex ([int]$blockRow.OrderIndex) `
                    -ConditionKey $blockRow.ConditionKey `
                    -GapIndex $gap.GapIndex `
                    -StartUtc $gap.StartUtc `
                    -EndUtc $gap.EndUtc `
                    -GapSeconds $gap.GapSeconds `
                    -WarningThresholdSeconds $systemGapWarningThresholdSeconds `
                    -HardThresholdSeconds $maxSystemCounterGapSeconds `
                    -SystemCsv $systemPath))
            }
            if ($maxSystemGap -gt $maxSystemCounterGapSeconds) {
                Add-ValidationError $validationErrors "System-counter gap $maxSystemGap exceeds the $maxSystemCounterGapSeconds second hard limit in '$scenarioRoot'."
                $blockIsValid = $false
            }
            if ($maxProcessGap -gt $maxProcessSnapshotGapSeconds) {
                Add-ValidationError $validationErrors "Process-snapshot gap $maxProcessGap exceeds limit in '$scenarioRoot'."
                $blockIsValid = $false
            }
            if ($maxProbeGap -gt $maxProbeGapSeconds) {
                Add-ValidationError $validationErrors "Probe gap $maxProbeGap exceeds limit in '$scenarioRoot'."
                $blockIsValid = $false
            }
            foreach ($monitorErrorPath in @(
                (Join-Path $monitorRoot 'monitor-errors.log'),
                (Join-Path $monitorRoot 'process-monitor-errors.log'),
                (Join-Path $monitorRoot 'probe-monitor-errors.log')
            )) {
                if ((Test-Path -LiteralPath $monitorErrorPath) -and
                    -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $monitorErrorPath -Raw))) {
                    Add-ValidationError $validationErrors "Monitor errors are present in '$monitorErrorPath'."
                    $blockIsValid = $false
                }
            }

            $committed = [double[]]@($systemRows | ForEach-Object { [double]$_.committedBytes })
            $baselineCount = [Math]::Min(3, $committed.Count)
            $baselineCommitted = Get-Median ([double[]]$committed[0..($baselineCount - 1)])
            $peakCommitted = ($committed | Measure-Object -Maximum).Maximum
            $queue = [double[]]@(
                $systemRows |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.processorQueueLength) } |
                    ForEach-Object { [double]$_.processorQueueLength }
            )
            $probe = [double[]]@(
                $probeRows |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.probeLatencyMs) } |
                    ForEach-Object { [double]$_.probeLatencyMs }
            )
            $processMetrics = Get-ProcessMetrics `
                -Rows $processRows `
                -RootProcesses $runs
            $scenarioMetrics.Add([pscustomobject][ordered]@{
                Repository = $repository.Name
                Workload = $metadata.Workload
                BlockNumber = [int]$blockRow.BlockNumber
                AnalysisBlockNumber = [int]$blockRow.AnalysisBlockNumber
                IsWarmup = [bool]::Parse([string]$blockRow.IsWarmup)
                AttemptNumber = [int]$blockCompletion.AttemptNumber
                OrderIndex = [int]$blockRow.OrderIndex
                ConditionKey = $blockRow.ConditionKey
                CandidateDurationSec = if ([int]$metadata.CandidateBuildCount -eq 1) {
                    [double]$summary.avgHighDurationSec
                }
                else {
                    $null
                }
                SingleBuildDurationSec = if ([int]$metadata.CandidateBuildCount -eq 0) {
                    [double]$summary.avgNormalDurationSec
                }
                else {
                    $null
                }
                AverageNormalDurationSec = [double]$summary.avgNormalDurationSec
                TotalWallSec = [double]$summary.totalWallSec
                CandidateOffsetSec = $candidateOffset
                MaximumTelemetryGapSec = $maxSystemGap
                MaximumSystemCounterGapSec = $maxSystemGap
                SystemGapWarningThresholdSec = $systemGapWarningThresholdSeconds
                SystemGapHardThresholdSec = $maxSystemCounterGapSeconds
                SystemGapWarningCount = $scenarioSystemGapWarnings.Count
                SystemGapWarningMaximumSec = if ($scenarioSystemGapWarnings.Count -gt 0) {
                    ($scenarioSystemGapWarnings.GapSeconds | Measure-Object -Maximum).Maximum
                }
                else {
                    $null
                }
                MaximumProcessSnapshotGapSec = $maxProcessGap
                MaximumProbeGapSec = $maxProbeGap
                PeakCommittedDeltaMB = ($peakCommitted - $baselineCommitted) / 1MB
                ProcessorQueueP95 = Get-Percentile -Values $queue -Percentile 0.95
                ProbeP95Ms = Get-Percentile -Values $probe -Percentile 0.95
                DescendantPeakWorkingSetMB = $processMetrics.PeakWorkingSetMB
                DescendantPeakPrivateMB = $processMetrics.PeakPrivateMB
                DescendantPeakProcessCount = $processMetrics.PeakProcessCount
                ExternalNoisePeakWorkingSetMB = $processMetrics.PeakExternalNoiseWorkingSetMB
                ExternalNoisePeakProcessCount = $processMetrics.PeakExternalNoiseProcessCount
                Binlogs = @($runs.binlog) -join ';'
                RunsCsv = $summary.runs
                SystemCsv = $systemPath
                ProcessesCsv = $processPath
                ProbesCsv = $probePath
            })
        }

        if ($blockIsValid) {
            foreach ($gapWarning in $blockSystemGapWarnings) {
                $systemGapWarnings.Add($gapWarning)
            }
            if ([bool]::Parse([string]$blockRows[0].IsWarmup)) {
                $validWarmupBlocks++
            }
            else {
                $validPrimaryBlocks++
            }
        }
    }
}

$systemGapWarningMaximum = if ($systemGapWarnings.Count -gt 0) {
    ($systemGapWarnings.GapSeconds | Measure-Object -Maximum).Maximum
}
else {
    $null
}
if ($systemGapWarnings.Count -gt 0) {
    $validationWarnings.Add("$($systemGapWarnings.Count) accepted system-counter gap(s) exceeded the $systemGapWarningThresholdSeconds second warning threshold; maximum $([Math]::Round($systemGapWarningMaximum, 3)) seconds.")
}

$systemGapWarningPath = Join-Path $OutputRoot 'system-gap-warnings.csv'
if ($systemGapWarnings.Count -gt 0) {
    $systemGapWarnings | Export-Csv -NoTypeInformation -LiteralPath $systemGapWarningPath
}
else {
    $warningHeader = (New-SystemGapWarningRow | ConvertTo-Csv -NoTypeInformation)[0]
    $warningHeader | Set-Content -LiteralPath $systemGapWarningPath -Encoding UTF8
}

$systemGapDistributionRows = [Collections.Generic.List[object]]::new()
foreach ($blockKind in @('primary', 'warmup')) {
    $isWarmup = $blockKind -eq 'warmup'
    $blockKindWarnings = @($systemGapWarnings | Where-Object IsWarmup -eq $isWarmup)
    $systemGapDistributionRows.Add((New-SystemGapDistributionRow `
        -Scope 'all' `
        -BlockKind $blockKind `
        -Repository 'all' `
        -ConditionKey 'all' `
        -Rows $blockKindWarnings))
    foreach ($repository in $metadata.Repositories) {
        $repositoryWarnings = @($blockKindWarnings | Where-Object Repository -eq $repository.Name)
        $systemGapDistributionRows.Add((New-SystemGapDistributionRow `
            -Scope 'repository' `
            -BlockKind $blockKind `
            -Repository $repository.Name `
            -ConditionKey 'all' `
            -Rows $repositoryWarnings))
        foreach ($conditionKey in @(
            $scenarioMetrics |
                Where-Object {
                    $_.Repository -eq $repository.Name -and
                        $_.IsWarmup -eq $isWarmup
                } |
                Select-Object -ExpandProperty ConditionKey -Unique
        )) {
            $systemGapDistributionRows.Add((New-SystemGapDistributionRow `
                -Scope 'condition' `
                -BlockKind $blockKind `
                -Repository $repository.Name `
                -ConditionKey $conditionKey `
                -Rows @($repositoryWarnings | Where-Object ConditionKey -eq $conditionKey)))
        }
    }
}
$systemGapDistributionPath = Join-Path $OutputRoot 'system-gap-warning-summary.csv'
$systemGapDistributionRows | Export-Csv -NoTypeInformation -LiteralPath $systemGapDistributionPath

$validation = [ordered]@{
    RunRoot = $RunRoot
    ValidatedUtc = [DateTime]::UtcNow.ToString('O')
    Valid = $validationErrors.Count -eq 0
    RepositoryCount = $metadata.Repositories.Count
    ValidWarmupBlocks = $validWarmupBlocks
    ValidPrimaryBlocks = $validPrimaryBlocks
    ScenarioCount = $scenarioMetrics.Count
    SystemGapWarningThresholdSeconds = $systemGapWarningThresholdSeconds
    SystemGapHardThresholdSeconds = $maxSystemCounterGapSeconds
    SystemGapWarningCount = $systemGapWarnings.Count
    SystemGapWarningMaximumSeconds = $systemGapWarningMaximum
    Errors = $validationErrors
    Warnings = $validationWarnings
}
$validation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'validation.json') -Encoding UTF8
if ($validationErrors.Count -gt 0) {
    throw "Benchmark validation failed with $($validationErrors.Count) error(s). See '$OutputRoot\\validation.json'."
}

$scenarioMetricsPath = Join-Path $OutputRoot 'scenario-metrics.csv'
$scenarioMetrics | Export-Csv -NoTypeInformation -LiteralPath $scenarioMetricsPath

$comparisonDefinitions = @(
    [pscustomobject]@{
        Key = 'AUTO-N-vs-F4-N'
        Denominator = 'F4-N'
        Numerator = 'AUTO-N'
        Description = 'Automatic idle-burst policy divided by fixed 4/4 with all-Normal work.'
        DesignKinds = @('paired-priority')
    },
    [pscustomobject]@{
        Key = 'AUTO-H-vs-F4-H'
        Denominator = 'F4-H'
        Numerator = 'AUTO-H'
        Description = 'Automatic idle-burst policy divided by fixed 4/4 with a delayed High candidate.'
        DesignKinds = @('paired-priority')
    },
    [pscustomobject]@{
        Key = 'AUTO-H-vs-AUTO-N'
        Denominator = 'AUTO-N'
        Numerator = 'AUTO-H'
        Description = 'Delayed High priority effect within the automatic idle-burst policy.'
        DesignKinds = @('paired-priority')
    },
    [pscustomobject]@{
        Key = 'F4-H-vs-F4-N'
        Denominator = 'F4-N'
        Numerator = 'F4-H'
        Description = 'Delayed High priority effect within the fixed 4/4 policy.'
        DesignKinds = @('paired-priority')
    },
    [pscustomobject]@{
        Key = 'D-vs-E'
        Denominator = 'D-candidate-default-normal'
        Numerator = 'E-candidate-default-high'
        Description = 'Primary priority effect: E divided by D.'
        DesignKinds = @('paired-priority')
    },
    [pscustomobject]@{
        Key = 'B-vs-C'
        Denominator = 'B-base-coordinator'
        Numerator = 'C-candidate-compat'
        Description = 'Branch/compatibility overhead: C divided by B.'
        DesignKinds = @('paired-priority', 'single-build-compatibility')
    },
    [pscustomobject]@{
        Key = 'C-vs-D'
        Denominator = 'C-candidate-compat'
        Numerator = 'D-candidate-default-normal'
        Description = 'Bundled default-policy impact: D divided by C.'
        DesignKinds = @('paired-priority', 'single-build-compatibility')
    },
    [pscustomobject]@{
        Key = 'A-vs-C'
        Denominator = 'A-no-coordinator'
        Numerator = 'C-candidate-compat'
        Description = 'Candidate compatibility Coordinator overhead: C divided by A.'
        DesignKinds = @('single-build-compatibility')
    },
    [pscustomobject]@{
        Key = 'A-vs-D'
        Denominator = 'A-no-coordinator'
        Numerator = 'D-candidate-default-normal'
        Description = 'Candidate default-policy Coordinator impact: D divided by A.'
        DesignKinds = @('paired-priority', 'single-build-compatibility')
    },
    [pscustomobject]@{
        Key = 'A-vs-B'
        Denominator = 'A-no-coordinator'
        Numerator = 'B-base-coordinator'
        Description = 'Cross-binary pre-change Coordinator reference: B divided by A.'
        DesignKinds = @('single-build-compatibility')
    }
)

$pairedRows = [Collections.Generic.List[object]]::new()
$primaryMetrics = @($scenarioMetrics | Where-Object { -not $_.IsWarmup })
foreach ($repository in $metadata.Repositories) {
    $repositoryMetrics = @($primaryMetrics | Where-Object Repository -eq $repository.Name)
    foreach ($comparison in $comparisonDefinitions) {
        if ($comparison.DesignKinds -notcontains $designKind -or
            -not $conditionByKey.ContainsKey($comparison.Denominator) -or
            -not $conditionByKey.ContainsKey($comparison.Numerator)) {
            continue
        }
        foreach ($analysisBlockNumber in @($repositoryMetrics.AnalysisBlockNumber | Sort-Object -Unique)) {
            $blockMetrics = @($repositoryMetrics | Where-Object AnalysisBlockNumber -eq $analysisBlockNumber)
            $denominator = $blockMetrics | Where-Object ConditionKey -eq $comparison.Denominator | Select-Object -First 1
            $numerator = $blockMetrics | Where-Object ConditionKey -eq $comparison.Numerator | Select-Object -First 1
            if ($null -eq $denominator -or $null -eq $numerator) {
                Add-ValidationError $validationErrors "Comparison '$($comparison.Key)' is incomplete for $($repository.Name) block $analysisBlockNumber."
                continue
            }
            $requiredMetrics = if ([int]$metadata.CandidateBuildCount -eq 1) {
                @('CandidateDurationSec', 'AverageNormalDurationSec', 'TotalWallSec')
            }
            else {
                @('SingleBuildDurationSec', 'TotalWallSec')
            }
            foreach ($metric in $requiredMetrics) {
                if ([double]$denominator.$metric -le 0 -or [double]$numerator.$metric -le 0) {
                    Add-ValidationError $validationErrors "Comparison '$($comparison.Key)' has non-positive '$metric' for $($repository.Name) block $analysisBlockNumber."
                }
            }
            $pairedRows.Add([pscustomobject][ordered]@{
                Repository = $repository.Name
                Workload = $metadata.Workload
                AnalysisBlockNumber = [int]$analysisBlockNumber
                Comparison = $comparison.Key
                DenominatorCondition = $comparison.Denominator
                NumeratorCondition = $comparison.Numerator
                CandidateLogRatio = if ([int]$metadata.CandidateBuildCount -eq 1) {
                    [Math]::Log([double]$numerator.CandidateDurationSec / [double]$denominator.CandidateDurationSec)
                }
                else {
                    $null
                }
                SingleBuildLogRatio = if ([int]$metadata.CandidateBuildCount -eq 0) {
                    [Math]::Log([double]$numerator.SingleBuildDurationSec / [double]$denominator.SingleBuildDurationSec)
                }
                else {
                    $null
                }
                AverageNormalLogRatio = [Math]::Log([double]$numerator.AverageNormalDurationSec / [double]$denominator.AverageNormalDurationSec)
                TotalWallLogRatio = [Math]::Log([double]$numerator.TotalWallSec / [double]$denominator.TotalWallSec)
            })
        }
    }
}
if ($validationErrors.Count -gt 0) {
    $validation.Valid = $false
    $validation.Errors = $validationErrors
    $validation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'validation.json') -Encoding UTF8
    throw "Paired comparison validation failed. See '$OutputRoot\\validation.json'."
}

$pairedRowsPath = Join-Path $OutputRoot 'paired-block-log-ratios.csv'
$pairedRows | Export-Csv -NoTypeInformation -LiteralPath $pairedRowsPath

$comparisonRows = [Collections.Generic.List[object]]::new()
foreach ($group in ($pairedRows | Group-Object Repository,Comparison)) {
    $rows = @($group.Group | Sort-Object AnalysisBlockNumber)
    $candidateValues = if ([int]$metadata.CandidateBuildCount -eq 1) {
        [double[]]$rows.CandidateLogRatio
    }
    else {
        [double[]]$rows.SingleBuildLogRatio
    }
    $normalValues = [double[]]$rows.AverageNormalLogRatio
    $wallValues = [double[]]$rows.TotalWallLogRatio
    $stableSeed = $RandomSeed + (Get-StableHash "$($rows[0].Repository)|$($rows[0].Comparison)")
    $candidateMean = Get-Average $candidateValues
    $normalMean = Get-Average $normalValues
    $wallMean = Get-Average $wallValues
    $candidateInterval = Get-ResampledMeanInterval -Values $candidateValues -Seed $stableSeed
    $normalInterval = Get-ResampledMeanInterval -Values $normalValues -Seed ($stableSeed + 1)
    $wallInterval = Get-ResampledMeanInterval -Values $wallValues -Seed ($stableSeed + 2)
    $hasInferentialEvidence = $rows.Count -ge $minimumInferentialPairedBlocks -and
        $rows.Count -le $maximumExactSignFlipBlocks
    $comparisonRows.Add([pscustomobject][ordered]@{
        Repository = $rows[0].Repository
        Workload = $metadata.Workload
        Comparison = $rows[0].Comparison
        Blocks = $rows.Count
        CandidateLatencyCostPercent = Convert-LogEffectToPercent $candidateMean
        CandidateLatencyCostCiLowerPercent = Convert-LogEffectToPercent $candidateInterval.Lower
        CandidateLatencyCostCiUpperPercent = Convert-LogEffectToPercent $candidateInterval.Upper
        CandidateLatencyGainPercent = -(Convert-LogEffectToPercent $candidateMean)
        CandidateLatencyGainCiLowerPercent = -(Convert-LogEffectToPercent $candidateInterval.Upper)
        CandidateLatencyGainCiUpperPercent = -(Convert-LogEffectToPercent $candidateInterval.Lower)
        CandidateExactSignFlipP = Get-ExactSignFlipPValue $candidateValues
        SingleBuildDurationCostPercent = if ([int]$metadata.CandidateBuildCount -eq 0) {
            Convert-LogEffectToPercent $candidateMean
        }
        else {
            $null
        }
        SingleBuildDurationCostCiLowerPercent = if ([int]$metadata.CandidateBuildCount -eq 0) {
            Convert-LogEffectToPercent $candidateInterval.Lower
        }
        else {
            $null
        }
        SingleBuildDurationCostCiUpperPercent = if ([int]$metadata.CandidateBuildCount -eq 0) {
            Convert-LogEffectToPercent $candidateInterval.Upper
        }
        else {
            $null
        }
        SingleBuildExactSignFlipP = if ([int]$metadata.CandidateBuildCount -eq 0) {
            Get-ExactSignFlipPValue $candidateValues
        }
        else {
            $null
        }
        AverageNormalCostPercent = Convert-LogEffectToPercent $normalMean
        AverageNormalCostCiLowerPercent = Convert-LogEffectToPercent $normalInterval.Lower
        AverageNormalCostCiUpperPercent = Convert-LogEffectToPercent $normalInterval.Upper
        AverageNormalExactSignFlipP = Get-ExactSignFlipPValue $normalValues
        TotalWallCostPercent = Convert-LogEffectToPercent $wallMean
        TotalWallCostCiLowerPercent = Convert-LogEffectToPercent $wallInterval.Lower
        TotalWallCostCiUpperPercent = Convert-LogEffectToPercent $wallInterval.Upper
        TotalWallExactSignFlipP = Get-ExactSignFlipPValue $wallValues
        AnalysisLabel = if ($hasInferentialEvidence) {
            'Inferential paired analysis'
        }
        else {
            'Descriptive directional paired analysis'
        }
    })
}

$comparisonPath = Join-Path $OutputRoot 'comparisons.csv'
$comparisonRows | Export-Csv -NoTypeInformation -LiteralPath $comparisonPath

$reportPath = Join-Path $OutputRoot 'report.md'
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Public-repository Coordinator benchmark analysis')
$lines.Add('')
$lines.Add("- Run root: ``$RunRoot``")
$lines.Add("- Workload: ``$($metadata.Workload)``; repositories analyzed separately.")
$lines.Add("- Valid blocks: $validPrimaryBlocks primary and $validWarmupBlocks discarded warm-up blocks across $($metadata.Repositories.Count) repositories.")
$lines.Add("- Effects are geometric paired effects from within-block log ratios. No ratio of independent medians is used.")
$lines.Add("- Confidence intervals are deterministic 95% block-resampling intervals ($ResampleIterations iterations; seed $RandomSeed).")
$lines.Add("- Exact p-values enumerate all sign flips when there are at most $maximumExactSignFlipBlocks paired blocks.")
$lines.Add('- Coordinator grant counts remain available through `CoordinatorNodeGrantReceived` messages in each runs.csv binlog.')
$lines.Add('- Effective auto/manual policy origin is not currently captured in binlogs; this tooling does not change the production protocol.')
$inferentialResultCount = @($comparisonRows | Where-Object AnalysisLabel -eq 'Inferential paired analysis').Count
$descriptiveResultCount = $comparisonRows.Count - $inferentialResultCount
if ($inferentialResultCount -gt 0) {
    $lines.Add('')
    $lines.Add("> **Inferential paired evidence:** $inferentialResultCount repository-comparison result(s) have at least $minimumInferentialPairedBlocks valid measured paired blocks and an exact sign-flip test.")
}
if ($descriptiveResultCount -gt 0) {
    $lines.Add('')
    $lines.Add("> **Descriptive/directional evidence:** $descriptiveResultCount repository-comparison result(s) have fewer than $minimumInferentialPairedBlocks valid measured paired blocks or no exact sign-flip test.")
}
$lines.Add('')
$lines.Add('## Predeclared comparisons')
$lines.Add('')
if ([int]$metadata.CandidateBuildCount -eq 1) {
    $lines.Add('| Repository | Comparison | Blocks | Candidate latency effect (95% CI) | Average Normal cost (95% CI) | Total-wall cost (95% CI) | Exact sign-flip p (candidate / Normal / wall) |')
    $lines.Add('|---|---|---:|---:|---:|---:|---:|')
    foreach ($row in ($comparisonRows | Sort-Object Repository,Comparison)) {
        $candidate = if ($row.Comparison -eq 'D-vs-E') {
            'gain {0} ({1}, {2})' -f
                (Format-Percent $row.CandidateLatencyGainPercent),
                (Format-Percent $row.CandidateLatencyGainCiLowerPercent),
                (Format-Percent $row.CandidateLatencyGainCiUpperPercent)
        }
        else {
            'cost {0} ({1}, {2})' -f
                (Format-Percent $row.CandidateLatencyCostPercent),
                (Format-Percent $row.CandidateLatencyCostCiLowerPercent),
                (Format-Percent $row.CandidateLatencyCostCiUpperPercent)
        }
        $normal = '{0} ({1}, {2})' -f
            (Format-Percent $row.AverageNormalCostPercent),
            (Format-Percent $row.AverageNormalCostCiLowerPercent),
            (Format-Percent $row.AverageNormalCostCiUpperPercent)
        $wall = '{0} ({1}, {2})' -f
            (Format-Percent $row.TotalWallCostPercent),
            (Format-Percent $row.TotalWallCostCiLowerPercent),
            (Format-Percent $row.TotalWallCostCiUpperPercent)
        $pValues = '{0:F4} / {1:F4} / {2:F4}' -f
            $row.CandidateExactSignFlipP,
            $row.AverageNormalExactSignFlipP,
            $row.TotalWallExactSignFlipP
        $lines.Add("| $($row.Repository) | ``$($row.Comparison)`` | $($row.Blocks) | $candidate | $normal | $wall | $pValues |")
    }
}
else {
    $lines.Add('| Repository | Comparison | Blocks | Single-build duration cost (95% CI) | Total-wall cost (95% CI) | Exact sign-flip p (build / wall) |')
    $lines.Add('|---|---|---:|---:|---:|---:|')
    foreach ($row in ($comparisonRows | Sort-Object Repository,Comparison)) {
        $duration = '{0} ({1}, {2})' -f
            (Format-Percent $row.SingleBuildDurationCostPercent),
            (Format-Percent $row.SingleBuildDurationCostCiLowerPercent),
            (Format-Percent $row.SingleBuildDurationCostCiUpperPercent)
        $wall = '{0} ({1}, {2})' -f
            (Format-Percent $row.TotalWallCostPercent),
            (Format-Percent $row.TotalWallCostCiLowerPercent),
            (Format-Percent $row.TotalWallCostCiUpperPercent)
        $pValues = '{0:F4} / {1:F4}' -f
            $row.SingleBuildExactSignFlipP,
            $row.TotalWallExactSignFlipP
        $lines.Add("| $($row.Repository) | ``$($row.Comparison)`` | $($row.Blocks) | $duration | $wall | $pValues |")
    }
}
$lines.Add('')
$lines.Add('### Interpretation')
$lines.Add('')
$reportedComparisons = @($comparisonRows.Comparison | Sort-Object -Unique)
if ($reportedComparisons -contains 'D-vs-E') {
    $lines.Add('- `D-vs-E`: positive candidate gain means High reduced delayed-candidate latency; Normal and wall costs must be considered alongside it.')
}
if ($reportedComparisons -contains 'B-vs-C') {
    $lines.Add('- `B-vs-C`: positive costs indicate overhead from the candidate branch even with compatibility policy.')
}
if ($reportedComparisons -contains 'C-vs-D') {
    $lines.Add('- `C-vs-D`: positive costs indicate the bundled default reservation/cap policy impact.')
}
if ($reportedComparisons -contains 'A-vs-C') {
    $lines.Add('- `A-vs-C`: candidate compatibility Coordinator overhead relative to the same candidate binary without Coordinator.')
}
if ($reportedComparisons -contains 'A-vs-D') {
    $lines.Add('- `A-vs-D`: candidate default-policy Coordinator impact relative to the same candidate binary without Coordinator.')
}
if ($reportedComparisons -contains 'A-vs-B') {
    $lines.Add('- `A-vs-B`: cross-binary reference only; it combines binary and Coordinator differences.')
}
$lines.Add('')
$lines.Add('## Validity and diagnostics')
$lines.Add('')
$lines.Add("- System-counter timestamp gaps above $systemGapWarningThresholdSeconds seconds are responsiveness warnings and remain visible without invalidating a scenario. Gaps above the $maxSystemCounterGapSeconds second hard limit invalidate the whole block.")
$lines.Add("- Process-snapshot and probe timestamp-gap limits are $maxProcessSnapshotGapSeconds and $maxProbeGapSeconds seconds respectively; they are validated independently from system-counter continuity.")
$lines.Add("- This protocol was declared after a zero-measured-block pilot produced 5.8-8.25 second system-loop delays under realistic overload with 45/45 successful builds and binlogs and no monitor errors. The 30 second hard limit remains far below previously observed sleep contamination of about 882 seconds and multiple hours.")
$lines.Add('- Earlier invalid roots remain invalid and are never retroactively accepted under a later protocol.')
$lines.Add('- Every accepted build recorded a root PID; descendant process peaks were reconstructed from full process/parent snapshots.')
$lines.Add('- `scenario-metrics.csv` reports known Defender/search/update process peaks so external interference remains diagnosable.')
$lines.Add('')
$lines.Add('### System-gap warning distribution')
$lines.Add('')
$lines.Add('| Scope | Block kind | Repository | Condition | Warning gaps | Minimum (s) | Median (s) | P95 (s) | P99 (s) | Maximum (s) |')
$lines.Add('|---|---|---|---|---:|---:|---:|---:|---:|---:|')
foreach ($row in $systemGapDistributionRows) {
    $minimum = if ($row.WarningGapCount -gt 0) { '{0:F3}' -f $row.MinimumGapSeconds } else { 'n/a' }
    $median = if ($row.WarningGapCount -gt 0) { '{0:F3}' -f $row.MedianGapSeconds } else { 'n/a' }
    $p95 = if ($row.WarningGapCount -gt 0) { '{0:F3}' -f $row.P95GapSeconds } else { 'n/a' }
    $p99 = if ($row.WarningGapCount -gt 0) { '{0:F3}' -f $row.P99GapSeconds } else { 'n/a' }
    $maximum = if ($row.WarningGapCount -gt 0) { '{0:F3}' -f $row.MaximumGapSeconds } else { 'n/a' }
    $lines.Add("| $($row.Scope) | $($row.BlockKind) | $($row.Repository) | ``$($row.ConditionKey)`` | $($row.WarningGapCount) | $minimum | $median | $p95 | $p99 | $maximum |")
}
$lines.Add('')
$lines.Add('## Artifacts')
$lines.Add('')
$lines.Add("- Scenario metrics: ``$scenarioMetricsPath``")
$lines.Add("- System-gap warning events: ``$systemGapWarningPath``")
$lines.Add("- System-gap warning distribution: ``$systemGapDistributionPath``")
$lines.Add("- Paired block log ratios: ``$pairedRowsPath``")
$lines.Add("- Comparison summary: ``$comparisonPath``")
$lines.Add("- Validation: ``$(Join-Path $OutputRoot 'validation.json')``")
$lines | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host "VALIDATION=True"
Write-Host "SCENARIO_METRICS=$scenarioMetricsPath"
Write-Host "PAIRED_LOG_RATIOS=$pairedRowsPath"
Write-Host "COMPARISONS=$comparisonPath"
Write-Host "REPORT=$reportPath"
