<#
.SYNOPSIS
Runs balanced Coordinator benchmark blocks across base and candidate bootstraps.

.DESCRIPTION
This Windows-only orchestrator verifies bootstrap and repository identities,
emits a carryover-balanced matrix, prevents system sleep, gates each attempt on
bounded idle checks, and preserves every invalid whole-block attempt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BaseBootstrapRoot,

    [Parameter(Mandatory)]
    [string]$BaseExpectedCommit,

    [Parameter(Mandatory)]
    [string]$CandidateBootstrapRoot,

    [Parameter(Mandatory)]
    [string]$CandidateExpectedCommit,

    [Parameter(Mandatory)]
    [string]$RoslynRoot,

    [Parameter(Mandatory)]
    [string]$RoslynExpectedCommit,

    [Parameter(Mandatory)]
    [string]$RoslynWorkRoot,

    [Parameter(Mandatory)]
    [string]$AspireRoot,

    [Parameter(Mandatory)]
    [string]$AspireExpectedCommit,

    [Parameter(Mandatory)]
    [string]$AspireWorkRoot,

    [Parameter(Mandatory)]
    [string]$OutputRoot,

    [string]$BootstrapStagingRoot = (Join-Path ([IO.Path]::GetTempPath()) 'MSBuildCoordinatorBenchmarkBootstraps'),

    [ValidateSet('project-incremental', 'project-clean', 'solution-propagated', 'solution-clean')]
    [string]$Workload = 'solution-propagated',

    [string[]]$RepositoryNames = @('roslyn', 'aspire'),
    [string[]]$ConditionKeys = @('BASE', 'COMPAT', 'FINAL-N'),
    [int]$WarmupBlocks = 1,
    [int]$PrimaryBlocks = 10,
    [int]$NodeBudget = 16,
    [int]$NormalBuildCount = 4,
    [int]$CandidateBuildCount = 1,
    [int]$CandidateDelaySeconds = 15,
    [double]$CandidateOffsetMinimumSeconds = 14,
    [double]$CandidateOffsetMaximumSeconds = 18,
    [double]$SystemGapWarningThresholdSeconds = 5,
    [Alias('MaxTelemetryGapSeconds')]
    [double]$MaxSystemCounterGapSeconds = 30,
    [double]$MaxProcessSnapshotGapSeconds = 15,
    [double]$MaxProbeGapSeconds = 15,
    [int]$MaximumBlockAttempts = 3,
    [int]$MonitorReadyTimeoutSeconds = 30,
    [int]$IdleTimeoutSeconds = 300,
    [int]$IdleConsecutiveSamples = 3,
    [double]$IdleCpuMaximumPercent = 20,
    [double]$IdleQueueMaximum = 2,
    [double]$IdleMinimumAvailableMB = 4096,
    [int]$IdleSampleIntervalSeconds = 2,
    [int]$CooldownSeconds = 30,
    [string]$BuildConfiguration = 'Debug',
    [switch]$SkipPrepare,
    [switch]$PrepareOnly,
    [switch]$PlanOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'Run-PublicRepoCoordinatorMatrix.ps1 is Windows-only because it uses Windows performance counters and SetThreadExecutionState.'
}
if ($WarmupBlocks -lt 0 -or $PrimaryBlocks -le 0) {
    throw 'WarmupBlocks must be non-negative and PrimaryBlocks must be positive.'
}
if ($NormalBuildCount -le 0 -or $CandidateBuildCount -notin @(0, 1)) {
    throw 'NormalBuildCount must be positive and CandidateBuildCount must be zero or one.'
}
if ($CandidateBuildCount -eq 0 -and $NormalBuildCount -ne 1) {
    throw 'A matrix without a delayed candidate is a single-build design and requires NormalBuildCount=1.'
}
if ($CandidateBuildCount -eq 0 -and $ConditionKeys -contains 'E-candidate-default-high') {
    throw 'E-candidate-default-high requires one delayed candidate build.'
}
if ($CandidateOffsetMinimumSeconds -ge $CandidateOffsetMaximumSeconds) {
    throw 'Candidate offset bounds are invalid.'
}
if ($MaximumBlockAttempts -le 0 -or $SystemGapWarningThresholdSeconds -le 0 -or
    $MaxSystemCounterGapSeconds -le 0 -or
    $MaxProcessSnapshotGapSeconds -le 0 -or $MaxProbeGapSeconds -le 0) {
    throw 'MaximumBlockAttempts and all telemetry gap thresholds must be positive.'
}
if ($SystemGapWarningThresholdSeconds -gt $MaxSystemCounterGapSeconds) {
    throw 'SystemGapWarningThresholdSeconds must not exceed MaxSystemCounterGapSeconds.'
}
if ($PrepareOnly -and $SkipPrepare) {
    throw 'PrepareOnly cannot be combined with SkipPrepare.'
}
if ($PrepareOnly -and $PlanOnly) {
    throw 'PrepareOnly cannot be combined with PlanOnly.'
}

$benchmarkScript = Join-Path $PSScriptRoot 'Run-PublicRepoCoordinatorBenchmark.ps1'
$monitorScript = Join-Path $PSScriptRoot 'Monitor-PublicRepoCoordinatorBenchmark.ps1'
foreach ($path in @($benchmarkScript, $monitorScript)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required benchmark script '$path' does not exist."
    }
}

function Resolve-BootstrapIdentity {
    param(
        [string]$Role,
        [string]$Root,
        [string]$ExpectedCommit,
        [bool]$AllowMissing
    )

    $identity = [ordered]@{
        Role = $Role
        Root = $Root
        StagingRoot = $null
        StagingMetadataPath = $null
        ExpectedCommit = $ExpectedCommit
        ValidationStatus = 'Deferred'
        DotNetPath = $null
        SdkVersion = $null
        MSBuildDllPath = $null
        ProductVersion = $null
        FileVersion = $null
        DotNetSha256 = $null
        MSBuildDllSha256 = $null
        TrackedFiles = @()
        StagedTrackedFiles = @()
        DotNetInfo = @()
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        if ($AllowMissing) {
            return [pscustomobject]$identity
        }
        throw "$Role bootstrap root '$Root' does not exist."
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $dotnetPath = Join-Path $resolvedRoot 'dotnet.exe'
    $sdkRoot = Join-Path $resolvedRoot 'sdk'
    $sdk = Get-ChildItem -LiteralPath $sdkRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not (Test-Path -LiteralPath $dotnetPath) -or $null -eq $sdk) {
        throw "$Role bootstrap under '$resolvedRoot' is incomplete."
    }

    $msbuildDllPath = Join-Path $sdk.FullName 'MSBuild.dll'
    if (-not (Test-Path -LiteralPath $msbuildDllPath)) {
        throw "$Role bootstrap MSBuild.dll was not found at '$msbuildDllPath'."
    }
    $version = (Get-Item -LiteralPath $msbuildDllPath).VersionInfo
    if (-not $version.ProductVersion.Contains($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Role bootstrap ProductVersion '$($version.ProductVersion)' does not identify expected commit '$ExpectedCommit'."
    }

    $identity.Root = $resolvedRoot
    $identity.ValidationStatus = 'Verified'
    $identity.DotNetPath = $dotnetPath
    $identity.SdkVersion = $sdk.Name
    $identity.MSBuildDllPath = $msbuildDllPath
    $identity.ProductVersion = $version.ProductVersion
    $identity.FileVersion = $version.FileVersion
    $identity.DotNetSha256 = (Get-FileHash -LiteralPath $dotnetPath -Algorithm SHA256).Hash
    $identity.MSBuildDllSha256 = (Get-FileHash -LiteralPath $msbuildDllPath -Algorithm SHA256).Hash
    $trackedFiles = [Collections.Generic.List[object]]::new()
    $trackedFiles.Add([pscustomobject]@{
        Name = 'dotnet.exe'
        Path = $dotnetPath
        Sha256 = $identity.DotNetSha256
    })
    foreach ($fileName in @(
        'MSBuild.dll',
        'Microsoft.Build.dll',
        'Microsoft.Build.Framework.dll',
        'MSBuild.Coordinator.dll'
    )) {
        $path = Join-Path $sdk.FullName $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$Role bootstrap tracked file '$path' is missing."
        }
        $trackedFiles.Add([pscustomobject]@{
            Name = $fileName
            Path = $path
            Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        })
    }
    $identity.TrackedFiles = $trackedFiles.ToArray()
    $identity.DotNetInfo = @(& $dotnetPath --info 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "'$dotnetPath --info' failed with exit code $LASTEXITCODE."
    }

    return [pscustomobject]$identity
}

function Get-ValidatedStagedFiles {
    param(
        [pscustomobject]$Bootstrap,
        [string]$StageRoot
    )

    foreach ($file in $Bootstrap.TrackedFiles) {
        $relativePath = [IO.Path]::GetRelativePath($Bootstrap.Root, $file.Path)
        $stagedPath = Join-Path $StageRoot $relativePath
        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
            throw "Staged $($Bootstrap.Role) bootstrap file '$stagedPath' is missing."
        }
        $stagedHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash
        if ($stagedHash -ne $file.Sha256) {
            throw "Staged $($Bootstrap.Role) bootstrap file '$stagedPath' does not match its validated source hash."
        }
        [pscustomobject]@{
            Name = $file.Name
            Path = $stagedPath
            SourcePath = $file.Path
            Sha256 = $stagedHash
        }
    }
}

function Copy-BootstrapToStaging {
    param(
        [pscustomobject]$Bootstrap,
        [string]$StagingRoot
    )

    $commitKeyLength = [Math]::Min(12, $Bootstrap.ExpectedCommit.Length)
    if ($commitKeyLength -eq 0) {
        throw "$($Bootstrap.Role) expected commit cannot be empty."
    }
    $key = '{0}-{1}' -f $Bootstrap.ExpectedCommit.Substring(0, $commitKeyLength), $Bootstrap.MSBuildDllSha256.Substring(0, 12)
    $stageParent = Join-Path $StagingRoot $key
    $stageRoot = Join-Path $stageParent 'core'
    $metadataPath = Join-Path $stageParent 'staging-metadata.json'
    New-Item -ItemType Directory -Force -Path $StagingRoot | Out-Null
    $lockPath = Join-Path $StagingRoot "$key.lock"
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch {
        throw "Staging directory '$stageParent' is in use by another process: $($_.Exception.Message)"
    }
    try {
        if (Test-Path -LiteralPath $stageParent) {
            if (-not (Test-Path -LiteralPath $stageRoot -PathType Container) -or
                -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
                throw "Staged $($Bootstrap.Role) bootstrap '$stageParent' is incomplete and will not be mutated."
            }
        }
        else {
            $temporaryParent = "$stageParent.incomplete-$PID-$([guid]::NewGuid().ToString('N'))"
            $temporaryRoot = Join-Path $temporaryParent 'core'
            New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
            & robocopy $Bootstrap.Root $temporaryRoot /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
            if ($LASTEXITCODE -ge 8) {
                throw "Staging $($Bootstrap.Role) bootstrap with robocopy failed with exit code $LASTEXITCODE."
            }
            [void]@(Get-ValidatedStagedFiles -Bootstrap $Bootstrap -StageRoot $temporaryRoot)
            $publishedFiles = @(
                foreach ($file in $Bootstrap.TrackedFiles) {
                    $relativePath = [IO.Path]::GetRelativePath($Bootstrap.Root, $file.Path)
                    [pscustomobject]@{
                        Name = $file.Name
                        Path = Join-Path $stageRoot $relativePath
                        SourcePath = $file.Path
                        Sha256 = $file.Sha256
                    }
                }
            )
            [ordered]@{
                SchemaVersion = 1
                CreatedUtc = [DateTime]::UtcNow.ToString('O')
                Role = $Bootstrap.Role
                SourceRoot = $Bootstrap.Root
                StagingRoot = $stageRoot
                ExpectedCommit = $Bootstrap.ExpectedCommit
                ProductVersion = $Bootstrap.ProductVersion
                Files = $publishedFiles
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temporaryParent 'staging-metadata.json') -Encoding UTF8
            Move-Item -LiteralPath $temporaryParent -Destination $stageParent
        }

        $stagedFiles = @(Get-ValidatedStagedFiles -Bootstrap $Bootstrap -StageRoot $stageRoot)
        $Bootstrap.StagingRoot = $stageRoot
        $Bootstrap.StagingMetadataPath = $metadataPath
        $Bootstrap.DotNetPath = Join-Path $stageRoot 'dotnet.exe'
        $Bootstrap.MSBuildDllPath = Join-Path $stageRoot "sdk\$($Bootstrap.SdkVersion)\MSBuild.dll"
        $Bootstrap.StagedTrackedFiles = $stagedFiles
    }
    finally {
        $lock.Dispose()
    }
}

function Resolve-RepositoryIdentity {
    param(
        [string]$Name,
        [string]$Root,
        [string]$ExpectedCommit,
        [string]$WorkRoot,
        [bool]$AllowMissing
    )

    $identity = [ordered]@{
        Name = $Name
        Root = $Root
        WorkRoot = $WorkRoot
        ExpectedCommit = $ExpectedCommit
        ActualCommit = $null
        ValidationStatus = 'Deferred'
    }
    if (-not (Test-Path -LiteralPath $Root)) {
        if ($AllowMissing) {
            return [pscustomobject]$identity
        }
        throw "$Name repository root '$Root' does not exist."
    }

    $actualCommit = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read $Name repository commit."
    }
    if (-not $actualCommit.StartsWith($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name repository is at '$actualCommit'; expected '$ExpectedCommit'."
    }

    $identity.Root = (Resolve-Path -LiteralPath $Root).Path
    $identity.WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
    $identity.ActualCommit = $actualCommit
    $identity.ValidationStatus = 'Verified'
    return [pscustomobject]$identity
}

function Get-WilliamsOrders {
    param([string[]]$Items)

    if ($Items.Count -eq 1) {
        return [pscustomobject]@{
            DesignRow = 0
            Items = @($Items)
        }
    }

    $first = [Collections.Generic.List[int]]::new()
    $first.Add(0)
    for ($position = 1; $position -lt $Items.Count; $position++) {
        $index = if (($position % 2) -eq 1) {
            [int](($position + 1) / 2)
        }
        else {
            $Items.Count - [int]($position / 2)
        }
        $first.Add($index)
    }

    $orders = [Collections.Generic.List[object]]::new()
    for ($shift = 0; $shift -lt $Items.Count; $shift++) {
        $row = @(
            foreach ($index in $first) {
                $Items[($index + $shift) % $Items.Count]
            }
        )
        $orders.Add([pscustomobject]@{
            DesignRow = $orders.Count
            Items = $row
        })
    }
    if (($Items.Count % 2) -eq 1) {
        for ($rowIndex = 0; $rowIndex -lt $Items.Count; $rowIndex++) {
            $orders.Add([pscustomobject]@{
                DesignRow = $orders.Count
                Items = @($orders[$rowIndex].Items[($Items.Count - 1)..0])
            })
        }
    }

    return $orders.ToArray()
}

function Get-OrderDiagnostics {
    param(
        [object[]]$Orders,
        [string[]]$Items
    )

    $positionCounts = @{}
    $carryoverCounts = @{}
    foreach ($item in $Items) {
        $positionCounts[$item] = [int[]]::new($Items.Count)
        foreach ($next in $Items) {
            if ($item -ne $next) {
                $carryoverCounts["$item->$next"] = 0
            }
        }
    }

    foreach ($orderRecord in $Orders) {
        $order = @($orderRecord.Items)
        if ($order.Count -ne $Items.Count -or @($order | Sort-Object -Unique).Count -ne $Items.Count) {
            throw "Invalid condition order '$($order -join ',')'."
        }
        for ($position = 0; $position -lt $order.Count; $position++) {
            $positionCounts[$order[$position]][$position]++
            if ($position -gt 0) {
                $key = "$($order[$position - 1])->$($order[$position])"
                $carryoverCounts[$key]++
            }
        }
    }

    $positionValues = [int[]]@($positionCounts.Values | ForEach-Object { $_ })
    $carryoverValues = [int[]]@($carryoverCounts.Values)
    return [pscustomobject]@{
        PositionCounts = $positionCounts
        CarryoverCounts = $carryoverCounts
        PositionImbalance = if ($positionValues.Count -gt 0) {
            ($positionValues | Measure-Object -Maximum).Maximum -
                ($positionValues | Measure-Object -Minimum).Minimum
        }
        else {
            0
        }
        CarryoverImbalance = if ($carryoverValues.Count -gt 0) {
            ($carryoverValues | Measure-Object -Maximum).Maximum -
                ($carryoverValues | Measure-Object -Minimum).Minimum
        }
        else {
            0
        }
    }
}

function Get-MaxTimestampGapSeconds {
    param([object[]]$Rows)

    $maximum = 0.0
    for ($index = 1; $index -lt $Rows.Count; $index++) {
        $gap = ([DateTime]$Rows[$index].timestampUtc - [DateTime]$Rows[$index - 1].timestampUtc).TotalSeconds
        if ($gap -gt $maximum) {
            $maximum = $gap
        }
    }
    return $maximum
}

function Get-TimestampGapStatistics {
    param(
        [object[]]$Rows,
        [double]$WarningThresholdSeconds
    )

    $maximum = 0.0
    $warningMaximum = $null
    $warningCount = 0
    for ($index = 1; $index -lt $Rows.Count; $index++) {
        $gap = ([DateTime]$Rows[$index].timestampUtc - [DateTime]$Rows[$index - 1].timestampUtc).TotalSeconds
        if ($gap -gt $maximum) {
            $maximum = $gap
        }
        if ($gap -gt $WarningThresholdSeconds) {
            $warningCount++
            if ($null -eq $warningMaximum -or $gap -gt $warningMaximum) {
                $warningMaximum = $gap
            }
        }
    }
    return [pscustomobject]@{
        MaximumSeconds = $maximum
        WarningCount = $warningCount
        WarningMaximumSeconds = $warningMaximum
    }
}

function Wait-ForMachineIdle {
    param([string]$RecordPath)

    $records = [Collections.Generic.List[object]]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $consecutive = 0
    while ($timer.Elapsed.TotalSeconds -le $IdleTimeoutSeconds) {
        $timestampUtc = [DateTime]::UtcNow.ToString('O')
        $cpu = $null
        $queue = $null
        $available = $null
        $errors = ''
        try {
            $samples = (Get-Counter -Counter @(
                '\Processor(_Total)\% Processor Time',
                '\Memory\Available MBytes',
                '\System\Processor Queue Length'
            )).CounterSamples
            foreach ($sample in $samples) {
                $path = $sample.Path.ToLowerInvariant()
                if ($path.EndsWith('\processor(_total)\% processor time')) {
                    $cpu = [double]$sample.CookedValue
                }
                elseif ($path.EndsWith('\memory\available mbytes')) {
                    $available = [double]$sample.CookedValue
                }
                elseif ($path.EndsWith('\system\processor queue length')) {
                    $queue = [double]$sample.CookedValue
                }
            }
        }
        catch {
            $errors = $_.Exception.Message
        }

        $activeBuildProcesses = @(
            Get-CimInstance Win32_Process |
                Where-Object {
                    $_.Name -in @(
                        'MSBuild.exe',
                        'MSBuild.Coordinator.exe',
                        'csc.exe',
                        'vbc.exe'
                    ) -or
                    ($_.Name -eq 'dotnet.exe' -and
                     $_.CommandLine -match 'MSBuild\.dll' -and
                     $_.CommandLine -notmatch '/nodemode:')
                }
        ).Count
        $accepted = [string]::IsNullOrEmpty($errors) -and
            $null -ne $cpu -and $cpu -le $IdleCpuMaximumPercent -and
            $null -ne $queue -and $queue -le $IdleQueueMaximum -and
            $null -ne $available -and $available -ge $IdleMinimumAvailableMB -and
            $activeBuildProcesses -eq 0
        $consecutive = if ($accepted) { $consecutive + 1 } else { 0 }
        $records.Add([pscustomobject]@{
            timestampUtc = $timestampUtc
            elapsedSec = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
            cpuPercent = $cpu
            processorQueueLength = $queue
            availableMB = $available
            activeBuildProcesses = $activeBuildProcesses
            accepted = $accepted
            consecutiveAccepted = $consecutive
            error = $errors
        })
        $records | Export-Csv -NoTypeInformation -LiteralPath $RecordPath
        if ($consecutive -ge $IdleConsecutiveSamples) {
            return
        }
        Start-Sleep -Seconds $IdleSampleIntervalSeconds
    }

    throw "Machine did not meet the recorded idle gate within $IdleTimeoutSeconds seconds. See '$RecordPath'."
}

function Invoke-BuildServerShutdown {
    param([pscustomobject]$Bootstrap)

    if ($Bootstrap.ValidationStatus -ne 'Verified') {
        throw "Cannot shut down build servers with unverified $($Bootstrap.Role) bootstrap."
    }
    & $Bootstrap.DotNetPath build-server shutdown | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$($Bootstrap.Role) build-server shutdown failed with exit code $LASTEXITCODE."
    }
}

function Assert-WorktreeCommits {
    param([pscustomobject]$Repository)

    $records = @(Get-WorktreeCommitRecords -Repository $Repository)
    foreach ($record in $records) {
        if (-not $record.Commit.StartsWith($Repository.ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Worktree '$($record.Path)' is at '$($record.Commit)'; expected '$($Repository.ExpectedCommit)'."
        }
    }
}

function Get-WorktreeCommitRecords {
    param([pscustomobject]$Repository)

    $worktreeNames = @(
        for ($index = 1; $index -le $NormalBuildCount; $index++) {
            "normal$index"
        }
        for ($index = 1; $index -le $CandidateBuildCount; $index++) {
            "high$index"
        }
    )
    foreach ($name in $worktreeNames) {
        $worktree = Join-Path $Repository.WorkRoot $name
        if (-not (Test-Path -LiteralPath $worktree)) {
            throw "Missing benchmark worktree '$worktree'."
        }
        $commit = (& git -C $worktree rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read the commit for benchmark worktree '$worktree'."
        }
        [pscustomobject]@{
            Name = $name
            Path = $worktree
            Commit = $commit
        }
    }
}

function Invoke-PrepareRepository {
    param(
        [pscustomobject]$Repository,
        [pscustomobject]$Bootstrap,
        [string]$SetupRoot,
        [bool]$SkipWarm
    )

    $parameters = @{
        BenchmarkRoot = $Repository.Root
        RepositoryName = $Repository.Name
        BuildPath = $Repository.BuildPath
        TouchFileRelativePath = $Repository.TouchPath
        AdditionalBuildArguments = $Repository.AdditionalBuildArguments
        DotNetPath = $Bootstrap.DotNetPath
        MSBuildDllPath = $Bootstrap.MSBuildDllPath
        WorkRoot = $Repository.WorkRoot
        OutputRoot = $SetupRoot
        NormalBuildCount = $NormalBuildCount
        HighBuildCount = $CandidateBuildCount
        HighDelaySeconds = $CandidateDelaySeconds
        Rounds = 0
        Scenarios = @('no-coordinator')
        NodeBudget = $NodeBudget
        NoCoordinatorNodeCount = $NodeBudget
        Prepare = $true
        SkipWarm = $SkipWarm
    }
    & $benchmarkScript @parameters | Out-Host
    Assert-WorktreeCommits -Repository $Repository
}

function Invoke-PreparationEvaluationSmoke {
    param(
        [pscustomobject]$Repository,
        [pscustomobject]$Bootstrap,
        [string]$RecordPath
    )

    $recordDirectory = Split-Path -Parent $RecordPath
    New-Item -ItemType Directory -Force -Path $recordDirectory | Out-Null
    $resultOutputPath = Join-Path $recordDirectory "$([IO.Path]::GetFileNameWithoutExtension($RecordPath))-result.json"
    $projectPath = Join-Path $Repository.Root $Repository.PreparationSmokeProject
    $arguments = @(
        $Bootstrap.MSBuildDllPath,
        $projectPath,
        '-getProperty:OutputType;UsingMicrosoftNETSdkWeb;UsingMicrosoftNETSdkWebProjectSystem;MSBuildSDKsPath;Configuration',
        "-getResultOutputFile:$resultOutputPath"
    ) + $Repository.AdditionalBuildArguments
    $oldDotNetRoot = $env:DOTNET_ROOT
    $oldDotNetRootX64 = $env:DOTNET_ROOT_X64
    $oldPath = $env:PATH
    try {
        $env:DOTNET_ROOT = $Bootstrap.StagingRoot
        $env:DOTNET_ROOT_X64 = $Bootstrap.StagingRoot
        $env:PATH = "$($Bootstrap.StagingRoot)$([IO.Path]::PathSeparator)$oldPath"
        $output = @(& $Bootstrap.DotNetPath @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:DOTNET_ROOT = $oldDotNetRoot
        $env:DOTNET_ROOT_X64 = $oldDotNetRootX64
        $env:PATH = $oldPath
    }

    $properties = $null
    $parseError = $null
    if ($exitCode -eq 0) {
        if (Test-Path -LiteralPath $resultOutputPath -PathType Leaf) {
            try {
                $properties = (Get-Content -LiteralPath $resultOutputPath -Raw | ConvertFrom-Json).Properties
            }
            catch {
                $parseError = $_.Exception.ToString()
            }
        }
        else {
            $parseError = "MSBuild did not create '$resultOutputPath'."
        }
    }
    $actualOutputType = if ($null -eq $properties) { $null } else { $properties.OutputType }
    $record = [ordered]@{
        Repository = $Repository.Name
        ProjectPath = $projectPath
        ExpectedOutputType = $Repository.ExpectedPreparationOutputType
        BootstrapSourceRoot = $Bootstrap.Root
        BootstrapStagingRoot = $Bootstrap.StagingRoot
        DotNetPath = $Bootstrap.DotNetPath
        MSBuildDllPath = $Bootstrap.MSBuildDllPath
        Arguments = $arguments
        ResultOutputPath = $resultOutputPath
        ExitCode = $exitCode
        Properties = $properties
        ParseError = $parseError
        Output = $output
        Valid = $exitCode -eq 0 -and $null -eq $parseError -and $actualOutputType -eq $Repository.ExpectedPreparationOutputType
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $RecordPath -Encoding UTF8
    if (-not $record.Valid) {
        throw "Preparation evaluation smoke failed for $($Repository.Name): expected OutputType '$($Repository.ExpectedPreparationOutputType)', actual '$actualOutputType', exit code $exitCode. See '$RecordPath'."
    }
}

function Reset-CleanWorktrees {
    param([pscustomobject]$Repository)

    foreach ($worktree in @(Get-WorktreeCommitRecords -Repository $Repository)) {
        & git -C $worktree.Path clean -xdf -q
        if ($LASTEXITCODE -ne 0) {
            throw "Cleaning '$($worktree.Path)' failed with exit code $LASTEXITCODE."
        }
    }
}

function Start-ResourceMonitor {
    param(
        [string]$MonitorRoot,
        [string]$StopFile,
        [string]$ReadyFile
    )

    New-Item -ItemType Directory -Force -Path $MonitorRoot | Out-Null
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $monitorScript,
        '-OutputRoot', $MonitorRoot,
        '-StopFile', $StopFile,
        '-ReadyFile', $ReadyFile
    )) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ReadyFile)) {
        if ($process.HasExited) {
            throw "Resource monitor exited before readiness with code $($process.ExitCode)."
        }
        if ($timer.Elapsed.TotalSeconds -gt $MonitorReadyTimeoutSeconds) {
            Stop-Process -Id $process.Id
            throw "Resource monitor did not become ready within $MonitorReadyTimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds 100
    }
    return $process
}

function Stop-ResourceMonitor {
    param(
        [Diagnostics.Process]$Process,
        [string]$StopFile
    )

    New-Item -ItemType File -Force -Path $StopFile | Out-Null
    if (-not $Process.WaitForExit(30000)) {
        Stop-Process -Id $Process.Id
        [void]$Process.WaitForExit(5000)
    }
    $exitCode = $Process.ExitCode
    $Process.Dispose()
    if ($exitCode -ne 0) {
        throw "Resource monitor exited with code $exitCode."
    }
}

function Test-ScenarioResult {
    param(
        [string]$ScenarioRoot,
        [pscustomobject]$Definition
    )

    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $summaryFiles = @(Get-ChildItem (Join-Path $ScenarioRoot 'benchmark') -Filter scenario-summary.csv -ErrorAction SilentlyContinue)
    $runs = @()
    $candidateOffset = $null
    if ($summaryFiles.Count -ne 1) {
        $errors.Add("Expected one scenario-summary.csv; found $($summaryFiles.Count).")
    }
    else {
        $summary = Import-Csv -LiteralPath $summaryFiles[0].FullName | Select-Object -First 1
        if ([int]$summary.failedRuns -ne 0) {
            $errors.Add("Harness reported $($summary.failedRuns) failed builds.")
        }
        $runs = @(Import-Csv -LiteralPath $summary.runs)
        if ($runs.Count -ne ($NormalBuildCount + $CandidateBuildCount)) {
            $errors.Add("Found $($runs.Count) build rows; expected $($NormalBuildCount + $CandidateBuildCount).")
        }
        if (@($runs | Where-Object kind -eq 'normal').Count -ne $NormalBuildCount) {
            $errors.Add('Normal build count did not match.')
        }
        if (@($runs | Where-Object kind -eq 'high').Count -ne $CandidateBuildCount) {
            $errors.Add('Candidate build count did not match.')
        }
        foreach ($run in $runs) {
            if ([int]$run.exitCode -ne 0) {
                $errors.Add("Build '$($run.label)' exited with code $($run.exitCode).")
            }
            if ([int]$run.rootProcessId -le 0) {
                $errors.Add("Build '$($run.label)' did not record a root process ID.")
            }
            if (-not (Test-Path -LiteralPath $run.binlog) -or
                (Get-Item -LiteralPath $run.binlog -ErrorAction SilentlyContinue).Length -eq 0) {
                $errors.Add("Build '$($run.label)' binlog is missing or empty.")
            }
            if (-not (Test-Path -LiteralPath $run.stderr)) {
                $errors.Add("Build '$($run.label)' stderr file is missing.")
            }
            elseif (-not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $run.stderr -Raw))) {
                $errors.Add("Build '$($run.label)' has non-empty stderr.")
            }
        }
        $candidate = $runs | Where-Object kind -eq 'high' | Select-Object -First 1
        if ($CandidateBuildCount -eq 1 -and $null -ne $candidate) {
            $candidateOffset = [double]$candidate.startOffsetSec
            if ($candidateOffset -lt $CandidateOffsetMinimumSeconds -or
                $candidateOffset -gt $CandidateOffsetMaximumSeconds) {
                $errors.Add("Candidate offset $candidateOffset seconds is outside the valid range.")
            }
        }
        elseif ($CandidateBuildCount -eq 1) {
            $errors.Add('Candidate build row is missing.')
        }
    }

    $monitorRoot = Join-Path $ScenarioRoot 'monitor'
    $systemPath = Join-Path $monitorRoot 'system.csv'
    $processPath = Join-Path $monitorRoot 'processes.csv'
    $probePath = Join-Path $monitorRoot 'probes.csv'
    $maxSystemGap = $null
    $systemGapWarningCount = 0
    $systemGapWarningMaximum = $null
    $maxProcessGap = $null
    $maxProbeGap = $null
    if (-not (Test-Path -LiteralPath $systemPath)) {
        $errors.Add('system.csv is missing.')
    }
    else {
        $systemRows = @(Import-Csv -LiteralPath $systemPath)
        if ($systemRows.Count -lt 2) {
            $errors.Add('system.csv has fewer than two samples.')
        }
        else {
            $systemGapStatistics = Get-TimestampGapStatistics `
                -Rows $systemRows `
                -WarningThresholdSeconds $SystemGapWarningThresholdSeconds
            $maxSystemGap = $systemGapStatistics.MaximumSeconds
            $systemGapWarningCount = $systemGapStatistics.WarningCount
            $systemGapWarningMaximum = $systemGapStatistics.WarningMaximumSeconds
            if ($systemGapWarningCount -gt 0) {
                $warnings.Add("$systemGapWarningCount system-counter timestamp gap(s) exceeded the $SystemGapWarningThresholdSeconds second warning threshold; maximum $([Math]::Round($systemGapWarningMaximum, 3)) seconds.")
            }
            if ($maxSystemGap -gt $MaxSystemCounterGapSeconds) {
                $errors.Add("Maximum system-counter timestamp gap $([Math]::Round($maxSystemGap, 3)) seconds exceeds the $MaxSystemCounterGapSeconds second hard limit.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath $processPath) -or (Get-Item -LiteralPath $processPath).Length -eq 0) {
        $errors.Add('processes.csv is missing or empty.')
    }
    else {
        $processRows = @(Import-Csv -LiteralPath $processPath)
        $processSnapshots = @(
            $processRows |
                Group-Object timestampUtc |
                ForEach-Object { $_.Group[0] }
        )
        if ($processSnapshots.Count -lt 2) {
            $errors.Add('processes.csv has fewer than two snapshots.')
        }
        else {
            $maxProcessGap = Get-MaxTimestampGapSeconds -Rows $processSnapshots
            if ($maxProcessGap -gt $MaxProcessSnapshotGapSeconds) {
                $errors.Add("Maximum process-snapshot timestamp gap $([Math]::Round($maxProcessGap, 3)) seconds exceeds $MaxProcessSnapshotGapSeconds seconds.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath $probePath) -or (Get-Item -LiteralPath $probePath).Length -eq 0) {
        $errors.Add('probes.csv is missing or empty.')
    }
    else {
        $probeRows = @(Import-Csv -LiteralPath $probePath)
        if ($probeRows.Count -lt 2) {
            $errors.Add('probes.csv has fewer than two samples.')
        }
        else {
            $maxProbeGap = Get-MaxTimestampGapSeconds -Rows $probeRows
            if ($maxProbeGap -gt $MaxProbeGapSeconds) {
                $errors.Add("Maximum probe timestamp gap $([Math]::Round($maxProbeGap, 3)) seconds exceeds $MaxProbeGapSeconds seconds.")
            }
        }
    }
    foreach ($monitorErrorPath in @(
        (Join-Path $monitorRoot 'monitor-errors.log'),
        (Join-Path $monitorRoot 'process-monitor-errors.log'),
        (Join-Path $monitorRoot 'probe-monitor-errors.log')
    )) {
        if ((Test-Path -LiteralPath $monitorErrorPath) -and
            -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $monitorErrorPath -Raw))) {
            $errors.Add("Monitor errors were recorded in '$monitorErrorPath'.")
        }
    }

    $result = [ordered]@{
        Valid = $errors.Count -eq 0
        ConditionKey = $Definition.Key
        CandidateOffsetSeconds = $candidateOffset
        MaximumTelemetryGapSeconds = $maxSystemGap
        MaximumSystemCounterGapSeconds = $maxSystemGap
        SystemGapWarningThresholdSeconds = $SystemGapWarningThresholdSeconds
        SystemGapHardThresholdSeconds = $MaxSystemCounterGapSeconds
        SystemGapWarningCount = $systemGapWarningCount
        SystemGapWarningMaximumSeconds = $systemGapWarningMaximum
        MaximumProcessSnapshotGapSeconds = $maxProcessGap
        MaximumProbeGapSeconds = $maxProbeGap
        BuildCount = $runs.Count
        RootProcessIds = @($runs | ForEach-Object { [int]$_.rootProcessId })
        Warnings = $warnings
        Errors = $errors
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ScenarioRoot 'scenario-validation.json') -Encoding UTF8
    return [pscustomobject]$result
}

function Invoke-Condition {
    param(
        [pscustomobject]$Repository,
        [pscustomobject]$Definition,
        [int]$BlockNumber,
        [int]$AttemptNumber,
        [int]$OrderIndex,
        [string]$AttemptRoot
    )

    $bootstrap = if ($Definition.BootstrapRole -eq 'base') {
        $baseBootstrap
    }
    else {
        $candidateBootstrap
    }
    $scenarioRoot = Join-Path $AttemptRoot $Definition.Key
    $monitorRoot = Join-Path $scenarioRoot 'monitor'
    $benchmarkRoot = Join-Path $scenarioRoot 'benchmark'
    $stopFile = Join-Path $monitorRoot 'stop'
    $readyFile = Join-Path $monitorRoot 'ready'
    New-Item -ItemType Directory -Force -Path $scenarioRoot,$benchmarkRoot | Out-Null

    $metadata = [ordered]@{
        Repository = $Repository.Name
        RepositoryCommit = $Repository.ActualCommit
        Workload = $Workload
        BlockNumber = $BlockNumber
        AttemptNumber = $AttemptNumber
        OrderIndex = $OrderIndex
        ConditionKey = $Definition.Key
        BootstrapRole = $Definition.BootstrapRole
        BootstrapCommit = $bootstrap.ExpectedCommit
        BootstrapProductVersion = $bootstrap.ProductVersion
        DotNetPath = $bootstrap.DotNetPath
        MSBuildDllPath = $bootstrap.MSBuildDllPath
        UseCoordinator = $Definition.UseCoordinator
        ScriptScenario = $Definition.ScriptScenario
        NodeBudget = $Definition.NodeBudget
        Slice = $Definition.Slice
        Reservation = $Definition.Reservation
        AutomaticPolicy = $Definition.AutomaticPolicy
        CandidatePriority = $Definition.CandidatePriority
        NormalBuildCount = $NormalBuildCount
        CandidateBuildCount = $CandidateBuildCount
        DesignKind = if ($CandidateBuildCount -eq 1) { 'paired-priority' } else { 'single-build-compatibility' }
        CandidateDelaySeconds = $CandidateDelaySeconds
        WorktreeCommits = @(Get-WorktreeCommitRecords -Repository $Repository)
        StartedUtc = [DateTime]::UtcNow.ToString('O')
        Succeeded = $false
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $scenarioRoot 'scenario-metadata.json') -Encoding UTF8

    $monitorProcess = $null
    try {
        if ($Workload.EndsWith('-clean', [StringComparison]::Ordinal)) {
            Reset-CleanWorktrees -Repository $Repository
            Invoke-PrepareRepository -Repository $Repository -Bootstrap $bootstrap -SetupRoot (Join-Path $scenarioRoot 'setup') -SkipWarm $true
        }

        Invoke-BuildServerShutdown -Bootstrap $baseBootstrap
        if ($candidateBootstrap.Root -ne $baseBootstrap.Root) {
            Invoke-BuildServerShutdown -Bootstrap $candidateBootstrap
        }
        $monitorProcess = Start-ResourceMonitor -MonitorRoot $monitorRoot -StopFile $stopFile -ReadyFile $readyFile

        $parameters = @{
            BenchmarkRoot = $Repository.Root
            RepositoryName = "$($Repository.Name)-b$BlockNumber-a$AttemptNumber-$($Definition.Key)"
            BuildPath = $Repository.BuildPath
            TouchFileRelativePath = $Repository.TouchPath
            AdditionalBuildArguments = $Repository.AdditionalBuildArguments
            DotNetPath = $bootstrap.DotNetPath
            MSBuildDllPath = $bootstrap.MSBuildDllPath
            WorkRoot = $Repository.WorkRoot
            OutputRoot = $benchmarkRoot
            NormalBuildCount = $NormalBuildCount
            HighBuildCount = $CandidateBuildCount
            HighDelaySeconds = $CandidateDelaySeconds
            Rounds = 1
            Scenarios = @($Definition.ScriptScenario)
            NodeBudget = $Definition.NodeBudget
            NoCoordinatorNodeCount = $NodeBudget
            Slice = $Definition.Slice
            Reservation = $Definition.Reservation
            AutomaticPolicy = $Definition.AutomaticPolicy
            OmitPriorityEnvironment = $Definition.OmitPriorityEnvironment
            SkipInternalProcessSampling = $true
        }
        & $benchmarkScript @parameters | Out-Host
        $metadata.Succeeded = $true
    }
    catch {
        $metadata.Error = $_.Exception.ToString()
    }
    finally {
        if ($null -ne $monitorProcess) {
            try {
                Stop-ResourceMonitor -Process $monitorProcess -StopFile $stopFile
            }
            catch {
                $metadata.MonitorStopError = $_.Exception.ToString()
            }
        }
        $metadata.CompletedUtc = [DateTime]::UtcNow.ToString('O')
        $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $scenarioRoot 'scenario-metadata.json') -Encoding UTF8
    }

    if (-not $metadata.Succeeded) {
        $failure = [ordered]@{
            Valid = $false
            ConditionKey = $Definition.Key
            Errors = @($metadata.Error)
        }
        $failure | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $scenarioRoot 'scenario-validation.json') -Encoding UTF8
        return [pscustomobject]$failure
    }
    if ($metadata.Contains('MonitorStopError')) {
        $failure = [ordered]@{
            Valid = $false
            ConditionKey = $Definition.Key
            Errors = @($metadata.MonitorStopError)
        }
        $failure | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $scenarioRoot 'scenario-validation.json') -Encoding UTF8
        return [pscustomobject]$failure
    }

    return Test-ScenarioResult -ScenarioRoot $scenarioRoot -Definition $Definition
}

$conditionDefinitions = [ordered]@{
    'BASE' = [pscustomobject]@{
        Key = 'BASE'
        BootstrapRole = 'base'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 0
        Reservation = 0
        AutomaticPolicy = $true
        OmitPriorityEnvironment = $true
        CandidatePriority = 'Normal'
        Description = 'Current Coordinator defaults with reservation, cap, and priority variables absent.'
    }
    'COMPAT' = [pscustomobject]@{
        Key = 'COMPAT'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 0
        Reservation = 0
        AutomaticPolicy = $false
        OmitPriorityEnvironment = $false
        CandidatePriority = 'Normal'
        Description = 'Final candidate with explicit 0/0 compatibility policy.'
    }
    'FINAL-N' = [pscustomobject]@{
        Key = 'FINAL-N'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 4
        Reservation = 4
        AutomaticPolicy = $true
        OmitPriorityEnvironment = $false
        CandidatePriority = 'Normal'
        Description = 'Final candidate with computed defaults and an idle 8-node ceiling.'
    }
    'A-no-coordinator' = [pscustomobject]@{
        Key = 'A-no-coordinator'
        BootstrapRole = 'candidate'
        UseCoordinator = $false
        ScriptScenario = 'no-coordinator'
        NodeBudget = $NodeBudget
        Slice = 0
        Reservation = 0
        AutomaticPolicy = $false
        CandidatePriority = 'Normal'
        Description = 'Candidate binary without Coordinator.'
    }
    'B-base-coordinator' = [pscustomobject]@{
        Key = 'B-base-coordinator'
        BootstrapRole = 'base'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 0
        Reservation = 0
        AutomaticPolicy = $false
        CandidatePriority = 'Normal'
        Description = 'Immediate pre-change Coordinator behavior.'
    }
    'C-candidate-compat' = [pscustomobject]@{
        Key = 'C-candidate-compat'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 0
        Reservation = 0
        AutomaticPolicy = $false
        CandidatePriority = 'Normal'
        Description = 'Candidate in compatibility mode with reservation and cap disabled.'
    }
    'D-candidate-default-normal' = [pscustomobject]@{
        Key = 'D-candidate-default-normal'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 4
        Reservation = 4
        AutomaticPolicy = $false
        CandidatePriority = 'Normal'
        Description = 'Candidate default policy control; delayed candidate remains Normal.'
    }
    'E-candidate-default-high' = [pscustomobject]@{
        Key = 'E-candidate-default-high'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-priority'
        NodeBudget = $NodeBudget
        Slice = 4
        Reservation = 4
        AutomaticPolicy = $false
        CandidatePriority = 'High'
        Description = 'Candidate default policy; only delayed candidate priority changes to High.'
    }
    'F4-N' = [pscustomobject]@{
        Key = 'F4-N'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 4
        Reservation = 4
        AutomaticPolicy = $false
        CandidatePriority = 'Normal'
        Description = 'Explicit fixed 4/4 policy; all builds use Normal priority.'
    }
    'AUTO-N' = [pscustomobject]@{
        Key = 'AUTO-N'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-all-normal'
        NodeBudget = $NodeBudget
        Slice = 4
        Reservation = 4
        AutomaticPolicy = $true
        CandidatePriority = 'Normal'
        Description = 'Automatic idle-burst policy; all builds use Normal priority.'
    }
    'F4-H' = [pscustomobject]@{
        Key = 'F4-H'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-priority'
        NodeBudget = $NodeBudget
        Slice = 4
        Reservation = 4
        AutomaticPolicy = $false
        CandidatePriority = 'High'
        Description = 'Explicit fixed 4/4 policy; delayed candidate uses High priority.'
    }
    'AUTO-H' = [pscustomobject]@{
        Key = 'AUTO-H'
        BootstrapRole = 'candidate'
        UseCoordinator = $true
        ScriptScenario = 'coordinator-priority'
        NodeBudget = $NodeBudget
        Slice = 4
        Reservation = 4
        AutomaticPolicy = $true
        CandidatePriority = 'High'
        Description = 'Automatic idle-burst policy; delayed candidate uses High priority.'
    }
}

foreach ($conditionKey in $ConditionKeys) {
    if (-not $conditionDefinitions.Contains($conditionKey)) {
        throw "Unknown condition '$conditionKey'."
    }
}
if (@($ConditionKeys | Sort-Object -Unique).Count -ne $ConditionKeys.Count) {
    throw 'ConditionKeys contains duplicates.'
}

$normalDefinition = $conditionDefinitions['D-candidate-default-normal']
$highDefinition = $conditionDefinitions['E-candidate-default-high']
foreach ($property in @('BootstrapRole', 'UseCoordinator', 'NodeBudget', 'Slice', 'Reservation', 'AutomaticPolicy')) {
    if ($normalDefinition.$property -ne $highDefinition.$property) {
        throw "D and E differ in '$property'; they may differ only in candidate priority/script scenario."
    }
}

$baseBootstrap = Resolve-BootstrapIdentity -Role 'base' -Root $BaseBootstrapRoot -ExpectedCommit $BaseExpectedCommit -AllowMissing $PlanOnly
$candidateBootstrap = Resolve-BootstrapIdentity -Role 'candidate' -Root $CandidateBootstrapRoot -ExpectedCommit $CandidateExpectedCommit -AllowMissing $PlanOnly
if ($baseBootstrap.ValidationStatus -eq 'Verified' -and
    $candidateBootstrap.ValidationStatus -eq 'Verified' -and
    $baseBootstrap.SdkVersion -ne $candidateBootstrap.SdkVersion) {
    throw "Base SDK '$($baseBootstrap.SdkVersion)' and candidate SDK '$($candidateBootstrap.SdkVersion)' differ."
}
if (-not $PlanOnly) {
    Copy-BootstrapToStaging -Bootstrap $baseBootstrap -StagingRoot $BootstrapStagingRoot
    Copy-BootstrapToStaging -Bootstrap $candidateBootstrap -StagingRoot $BootstrapStagingRoot
}

$repositoryDefinitions = @(
    [pscustomobject]@{
        Name = 'roslyn'
        Root = $RoslynRoot
        ExpectedCommit = $RoslynExpectedCommit
        WorkRoot = $RoslynWorkRoot
        ProjectBuildPath = 'src\Compilers\CSharp\Portable\Microsoft.CodeAnalysis.CSharp.csproj'
        ProjectTouchPath = 'src\Compilers\CSharp\Portable\CSharpCompilationOptions.cs'
        SolutionBuildPath = 'Compilers.slnf'
        SolutionTouchPath = 'src\Compilers\Core\Portable\Diagnostic\Diagnostic.cs'
        PreparationSmokeProject = 'src\Compilers\CSharp\Portable\Microsoft.CodeAnalysis.CSharp.csproj'
        ExpectedPreparationOutputType = 'Library'
        AdditionalBuildArguments = @()
    },
    [pscustomobject]@{
        Name = 'aspire'
        Root = $AspireRoot
        ExpectedCommit = $AspireExpectedCommit
        WorkRoot = $AspireWorkRoot
        ProjectBuildPath = 'src\Aspire.Hosting\Aspire.Hosting.csproj'
        ProjectTouchPath = 'src\Aspire.Hosting\DistributedApplication.cs'
        SolutionBuildPath = 'Aspire-Core.slnf'
        SolutionTouchPath = 'src\Aspire.Hosting\DistributedApplication.cs'
        PreparationSmokeProject = 'src\Aspire.Dashboard\Aspire.Dashboard.csproj'
        ExpectedPreparationOutputType = 'Exe'
        AdditionalBuildArguments = @('/p:InstallBrowsersForPlaywright=false')
    }
)
$repositories = [Collections.Generic.List[object]]::new()
foreach ($repositoryDefinition in $repositoryDefinitions) {
    if ($RepositoryNames -notcontains $repositoryDefinition.Name) {
        continue
    }
    $identity = Resolve-RepositoryIdentity `
        -Name $repositoryDefinition.Name `
        -Root $repositoryDefinition.Root `
        -ExpectedCommit $repositoryDefinition.ExpectedCommit `
        -WorkRoot $repositoryDefinition.WorkRoot `
        -AllowMissing $PlanOnly
    $identity | Add-Member -NotePropertyName ProjectBuildPath -NotePropertyValue $repositoryDefinition.ProjectBuildPath
    $identity | Add-Member -NotePropertyName ProjectTouchPath -NotePropertyValue $repositoryDefinition.ProjectTouchPath
    $identity | Add-Member -NotePropertyName SolutionBuildPath -NotePropertyValue $repositoryDefinition.SolutionBuildPath
    $identity | Add-Member -NotePropertyName SolutionTouchPath -NotePropertyValue $repositoryDefinition.SolutionTouchPath
    $identity | Add-Member -NotePropertyName PreparationSmokeProject -NotePropertyValue $repositoryDefinition.PreparationSmokeProject
    $identity | Add-Member -NotePropertyName ExpectedPreparationOutputType -NotePropertyValue $repositoryDefinition.ExpectedPreparationOutputType
    $identity | Add-Member -NotePropertyName AdditionalBuildArguments -NotePropertyValue $repositoryDefinition.AdditionalBuildArguments
    $buildPath = if ($Workload -in @('project-incremental', 'project-clean')) {
        $identity.ProjectBuildPath
    }
    else {
        $identity.SolutionBuildPath
    }
    $touchPath = if ($Workload -in @('project-incremental', 'project-clean')) {
        $identity.ProjectTouchPath
    }
    else {
        $identity.SolutionTouchPath
    }
    $identity | Add-Member -NotePropertyName BuildPath -NotePropertyValue $buildPath
    $identity | Add-Member -NotePropertyName TouchPath -NotePropertyValue $touchPath
    $repositories.Add($identity)
}
if ($repositories.Count -eq 0) {
    throw 'RepositoryNames did not select Roslyn or Aspire.'
}

if (Test-Path -LiteralPath $OutputRoot) {
    if (@(Get-ChildItem -LiteralPath $OutputRoot -Force).Count -gt 0) {
        throw "OutputRoot '$OutputRoot' already exists and is not empty."
    }
}
else {
    New-Item -ItemType Directory -Path $OutputRoot | Out-Null
}
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

$designOrders = @(Get-WilliamsOrders -Items $ConditionKeys)
$primaryOrders = @(
    for ($block = 0; $block -lt $PrimaryBlocks; $block++) {
        $design = $designOrders[$block % $designOrders.Count]
        [pscustomobject]@{
            DesignRow = $design.DesignRow
            Items = @($design.Items)
        }
    }
)
$warmupOrders = @(
    for ($block = 0; $block -lt $WarmupBlocks; $block++) {
        $design = $designOrders[($designOrders.Count - 1 - ($block % $designOrders.Count))]
        [pscustomobject]@{
            DesignRow = $design.DesignRow
            Items = @($design.Items)
        }
    }
)
$orderDiagnostics = Get-OrderDiagnostics -Orders $primaryOrders -Items $ConditionKeys
$planErrors = [Collections.Generic.List[string]]::new()
if ($PrimaryBlocks -eq $designOrders.Count -and
    ($orderDiagnostics.PositionImbalance -ne 0 -or $orderDiagnostics.CarryoverImbalance -ne 0)) {
    $planErrors.Add('A complete Williams design was not exactly position/carryover balanced.')
}

$matrixRows = [Collections.Generic.List[object]]::new()
foreach ($repository in $repositories) {
    for ($warmup = 0; $warmup -lt $WarmupBlocks; $warmup++) {
        $orderRecord = $warmupOrders[$warmup]
        $order = @($orderRecord.Items)
        for ($position = 0; $position -lt $order.Count; $position++) {
            $matrixRows.Add([pscustomobject]@{
                Repository = $repository.Name
                BlockNumber = $warmup + 1
                AnalysisBlockNumber = 0
                IsWarmup = $true
                DesignRow = $orderRecord.DesignRow
                OrderIndex = $position + 1
                ConditionKey = $order[$position]
            })
        }
    }
    for ($block = 0; $block -lt $PrimaryBlocks; $block++) {
        $orderRecord = $primaryOrders[$block]
        $order = @($orderRecord.Items)
        for ($position = 0; $position -lt $order.Count; $position++) {
            $matrixRows.Add([pscustomobject]@{
                Repository = $repository.Name
                BlockNumber = $WarmupBlocks + $block + 1
                AnalysisBlockNumber = $block + 1
                IsWarmup = $false
                DesignRow = $orderRecord.DesignRow
                OrderIndex = $position + 1
                ConditionKey = $order[$position]
            })
        }
    }
}

$runMetadata = [ordered]@{
    SchemaVersion = 2
    PlanOnly = [bool]$PlanOnly
    PrepareOnly = [bool]$PrepareOnly
    CreatedUtc = [DateTime]::UtcNow.ToString('O')
    OutputRoot = $OutputRoot
    Workload = $Workload
    BuildConfiguration = $BuildConfiguration
    WarmupBlocks = $WarmupBlocks
    PrimaryBlocks = $PrimaryBlocks
    NodeBudget = $NodeBudget
    NormalBuildCount = $NormalBuildCount
    CandidateBuildCount = $CandidateBuildCount
    DesignKind = if ($CandidateBuildCount -eq 1) { 'paired-priority' } else { 'single-build-compatibility' }
    CandidateDelaySeconds = $CandidateDelaySeconds
    CandidateOffsetMinimumSeconds = $CandidateOffsetMinimumSeconds
    CandidateOffsetMaximumSeconds = $CandidateOffsetMaximumSeconds
    SystemGapWarningThresholdSeconds = $SystemGapWarningThresholdSeconds
    MaxSystemCounterGapSeconds = $MaxSystemCounterGapSeconds
    MaxTelemetryGapSeconds = $MaxSystemCounterGapSeconds
    MaxProcessSnapshotGapSeconds = $MaxProcessSnapshotGapSeconds
    MaxProbeGapSeconds = $MaxProbeGapSeconds
    MaximumBlockAttempts = $MaximumBlockAttempts
    Diagnostics = [ordered]@{
        GrantCountLogging = [ordered]@{
            ResourceName = 'CoordinatorNodeGrantReceived'
            Storage = 'Per-build binlogs listed in runs.csv'
        }
        EffectivePolicyOrigin = [ordered]@{
            CapturedInBinlog = $false
            Note = 'Binlogs record granted node counts but do not currently identify whether effective policy values came from auto or manual configuration.'
        }
    }
    Conditions = @($ConditionKeys | ForEach-Object { $conditionDefinitions[$_] })
    BaseBootstrap = $baseBootstrap
    CandidateBootstrap = $candidateBootstrap
    Repositories = $repositories
    OrderDesign = [ordered]@{
        Name = 'Williams balanced design'
        DesignRows = $designOrders
        PrimaryOrders = $primaryOrders
        WarmupOrders = $warmupOrders
        Diagnostics = $orderDiagnostics
    }
}
$runMetadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputRoot 'run-metadata.json') -Encoding UTF8
$matrixRows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputRoot 'matrix-plan.csv')
$matrixRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'matrix-plan.json') -Encoding UTF8
[ordered]@{
    Valid = $planErrors.Count -eq 0
    Errors = $planErrors
    PrimaryOrderDiagnostics = $orderDiagnostics
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'plan-validation.json') -Encoding UTF8

if ($planErrors.Count -gt 0) {
    throw "Matrix plan is invalid: $($planErrors -join '; ')"
}
if ($PlanOnly) {
    Write-Host "PLAN_ROOT=$OutputRoot"
    Write-Host "PLAN_ROWS=$($matrixRows.Count)"
    Write-Host "POSITION_IMBALANCE=$($orderDiagnostics.PositionImbalance)"
    Write-Host "CARRYOVER_IMBALANCE=$($orderDiagnostics.CarryoverImbalance)"
    return
}

if ($baseBootstrap.ValidationStatus -ne 'Verified' -or $candidateBootstrap.ValidationStatus -ne 'Verified') {
    throw 'Execution requires verified base and candidate bootstraps.'
}
foreach ($repository in $repositories) {
    if ($repository.ValidationStatus -ne 'Verified') {
        throw 'Execution requires verified repository roots.'
    }
}

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class CoordinatorBenchmarkPower
{
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@
$executionStateContinuous = [uint32]2147483648
$executionStateSystemRequired = [uint32]2147483649
$keepAwakeStartedUtc = [DateTime]::UtcNow.ToString('O')
$previousExecutionState = [CoordinatorBenchmarkPower]::SetThreadExecutionState($executionStateSystemRequired)
if ($previousExecutionState -eq 0) {
    throw 'SetThreadExecutionState failed to request system-awake execution.'
}

try {
    if (-not $SkipPrepare) {
        foreach ($repository in $repositories) {
            foreach ($bootstrap in @($baseBootstrap, $candidateBootstrap)) {
                Invoke-PreparationEvaluationSmoke `
                    -Repository $repository `
                    -Bootstrap $bootstrap `
                    -RecordPath (Join-Path $OutputRoot "_setup\$($repository.Name)-$($bootstrap.Role)-preparation-smoke.json")
            }
        }
        foreach ($repository in $repositories) {
            Invoke-PrepareRepository `
                -Repository $repository `
                -Bootstrap $candidateBootstrap `
                -SetupRoot (Join-Path $OutputRoot "_setup\$($repository.Name)") `
                -SkipWarm ($Workload.EndsWith('-clean', [StringComparison]::Ordinal))
        }
    }
    if ($PrepareOnly) {
        [ordered]@{
            CompletedUtc = [DateTime]::UtcNow.ToString('O')
            RepositoryCount = $repositories.Count
            Workload = $Workload
            WarmSkipped = $Workload.EndsWith('-clean', [StringComparison]::Ordinal)
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'preparation-completion.json') -Encoding UTF8
        Write-Host "PREPARATION_ROOT=$OutputRoot"
        return
    }
    foreach ($repository in $repositories) {
        Assert-WorktreeCommits -Repository $repository
    }

    foreach ($repository in $repositories) {
        $repositoryPlan = @($matrixRows | Where-Object Repository -eq $repository.Name)
        $blockNumbers = @($repositoryPlan.BlockNumber | Sort-Object -Unique)
        foreach ($blockNumber in $blockNumbers) {
            $blockRows = @($repositoryPlan | Where-Object BlockNumber -eq $blockNumber | Sort-Object OrderIndex)
            $blockRoot = Join-Path $OutputRoot "$($repository.Name)\block-$('{0:D3}' -f $blockNumber)"
            New-Item -ItemType Directory -Force -Path $blockRoot | Out-Null
            $blockValid = $false

            for ($attempt = 1; $attempt -le $MaximumBlockAttempts; $attempt++) {
                $attemptRoot = Join-Path $blockRoot "attempt-$('{0:D2}' -f $attempt)"
                New-Item -ItemType Directory -Path $attemptRoot | Out-Null
                $attemptErrors = [Collections.Generic.List[string]]::new()
                try {
                    Wait-ForMachineIdle -RecordPath (Join-Path $attemptRoot 'idle-gate.csv')
                }
                catch {
                    $attemptErrors.Add($_.Exception.Message)
                }

                if ($attemptErrors.Count -eq 0) {
                    foreach ($blockRow in $blockRows) {
                        $definition = $conditionDefinitions[$blockRow.ConditionKey]
                        $result = Invoke-Condition `
                            -Repository $repository `
                            -Definition $definition `
                            -BlockNumber $blockNumber `
                            -AttemptNumber $attempt `
                            -OrderIndex $blockRow.OrderIndex `
                            -AttemptRoot $attemptRoot
                        foreach ($warningMessage in $result.Warnings) {
                            Write-Warning "$($definition.Key): $warningMessage"
                        }
                        if (-not $result.Valid) {
                            foreach ($errorMessage in $result.Errors) {
                                $attemptErrors.Add("$($definition.Key): $errorMessage")
                            }
                            break
                        }
                        if ($CooldownSeconds -gt 0) {
                            Start-Sleep -Seconds $CooldownSeconds
                        }
                    }
                }

                $attemptResult = [ordered]@{
                    Repository = $repository.Name
                    BlockNumber = $blockNumber
                    AnalysisBlockNumber = $blockRows[0].AnalysisBlockNumber
                    IsWarmup = [bool]$blockRows[0].IsWarmup
                    AttemptNumber = $attempt
                    Valid = $attemptErrors.Count -eq 0
                    CompletedUtc = [DateTime]::UtcNow.ToString('O')
                    Errors = $attemptErrors
                }
                $markerName = if ($attemptResult.Valid) { 'valid-attempt.json' } else { 'invalid-attempt.json' }
                $attemptResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $attemptRoot $markerName) -Encoding UTF8

                if ($attemptResult.Valid) {
                    $attemptResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $blockRoot 'block-completion.json') -Encoding UTF8
                    $blockValid = $true
                    break
                }
            }

            if (-not $blockValid) {
                throw "Repository '$($repository.Name)' block $blockNumber did not produce a valid whole-block attempt after $MaximumBlockAttempts attempts."
            }
        }
    }

    [ordered]@{
        CompletedUtc = [DateTime]::UtcNow.ToString('O')
        RepositoryCount = $repositories.Count
        WarmupBlocksPerRepository = $WarmupBlocks
        PrimaryBlocksPerRepository = $PrimaryBlocks
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'completion.json') -Encoding UTF8
}
finally {
    $restoreResult = [CoordinatorBenchmarkPower]::SetThreadExecutionState($executionStateContinuous)
    [ordered]@{
        RequestedUtc = $keepAwakeStartedUtc
        PreviousExecutionState = $previousExecutionState
        RestoredUtc = [DateTime]::UtcNow.ToString('O')
        RestoreResult = $restoreResult
        Restored = $restoreResult -ne 0
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'keep-awake.json') -Encoding UTF8
}

Write-Host "RUN_ROOT=$OutputRoot"
