<#
.SYNOPSIS
Runs C# Dev Kit ProjectDataBuild node-count benchmarks.

.DESCRIPTION
This script measures how MSBuild node count affects C# Dev Kit ProjectDataBuild
time and resource usage for a Roslyn solution or solution filter. It is intended
for coordinator sizing experiments, especially comparing small DTB reservations
against 4-node and full-machine runs.

The script imports the C# Dev Kit ProjectData targets into the Roslyn build by
setting CustomAfterMicrosoftCommonTargets and
CustomAfterMicrosoftCommonCrossTargetingTargets. It writes ProjectData cache
files to a per-run scratch directory via DOTNET_PROJECTDATA_CACHE_DIR so the
Roslyn or C# Dev Kit repos are not dirtied.

.PARAMETER RoslynRoot
Path to the local Roslyn repo. If omitted, the script tries ROSLYN_REPO and a
sibling "roslyn" checkout next to this MSBuild repo.

.PARAMETER BuildPath
Path to build relative to RoslynRoot, usually Roslyn.slnx or Compilers.slnf.

.PARAMETER ProjectDataTargets
Path to Microsoft.NET.ProjectData.targets from C# Dev Kit's deployed bundle,
usually extension/dist/msbuild/Microsoft.NET.ProjectData.targets. If omitted,
the script tries CDK_PROJECTDATA_TARGETS and a sibling "vs-green" checkout.

.PARAMETER OutputRoot
Directory for CSV results, logs, samples, and scratch caches. Defaults under the
current user's temp directory.

.PARAMETER NodeCounts
MSBuild /m values to test. If omitted, the script chooses common values up to
the current logical processor count.

.PARAMETER Rounds
Number of rounds per node count.

.PARAMETER DotNetPath
dotnet executable to use. Defaults to dotnet from PATH.

.PARAMETER IncludeRestore
If set, allows dotnet build to perform restore. By default the script passes
--no-restore so repeated timing is focused on ProjectDataBuild.

.PARAMETER NoForce
If set, does not pass _ProjectDataBuildForce=true.

.PARAMETER ExtraBuildArguments
Additional arguments appended to dotnet build.

.PARAMETER ShowInstructions
Prints a short usage guide and exits.

.EXAMPLE
pwsh ./scripts/benchmarks/Run-CdkProjectDataBenchmark.ps1 -ShowInstructions

.EXAMPLE
pwsh ./scripts/benchmarks/Run-CdkProjectDataBenchmark.ps1 `
  -RoslynRoot ~/src/roslyn `
  -BuildPath Roslyn.slnx `
  -ProjectDataTargets ~/src/vs-green/extension/dist/msbuild/Microsoft.NET.ProjectData.targets `
  -NodeCounts 2 3 4 6 8 10 `
  -Rounds 3
#>
[CmdletBinding()]
param(
    [string]$RoslynRoot = $env:ROSLYN_REPO,
    [string]$BuildPath = 'Roslyn.slnx',
    [string]$ProjectDataTargets = $env:CDK_PROJECTDATA_TARGETS,
    [string]$OutputRoot,
    [int[]]$NodeCounts,
    [int]$Rounds = 3,
    [string]$DotNetPath = 'dotnet',
    [switch]$IncludeRestore,
    [switch]$NoForce,
    [string[]]$ExtraBuildArguments = @(),
    [switch]$ShowInstructions
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

function Write-Instructions {
    $processorCount = [Environment]::ProcessorCount
    @"
C# Dev Kit ProjectDataBuild node benchmark

Prerequisites:
  1. A local Roslyn checkout restored for the target solution.
  2. A local C# Dev Kit/vs-green checkout with extension/dist/msbuild/Microsoft.NET.ProjectData.targets.
  3. PowerShell 7+ and dotnet on PATH.

Suggested M1 Pro run:
  sysctl -n hw.logicalcpu
  pwsh ./scripts/benchmarks/Run-CdkProjectDataBenchmark.ps1 \
    -RoslynRoot /path/to/roslyn \
    -BuildPath Roslyn.slnx \
    -ProjectDataTargets /path/to/vs-green/extension/dist/msbuild/Microsoft.NET.ProjectData.targets \
    -NodeCounts 2 3 4 6 8 10 \
    -Rounds 3

If the M1 Pro has 8 logical cores, use -NodeCounts 2 3 4 6 8.
This machine reports $processorCount logical processors.

Outputs:
  cdk-projectdata-node-results.csv   per-run wall time, process, memory, cache metrics
  cdk-projectdata-node-summary.csv   aggregate min/avg/max/stdev per node count
  <label>/*.out.log and *.err.log    per-run build logs
  <label>/*.samples.csv              sampled process count and working set
"@
}

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded) {
            return (Resolve-Path -LiteralPath $expanded).Path
        }
    }

    return $null
}

function Get-DefaultNodeCounts {
    $processorCount = [Environment]::ProcessorCount
    $candidates = @(1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 32)
    $selected = @($candidates | Where-Object { $_ -le $processorCount })
    if ($selected -notcontains $processorCount) {
        $selected += $processorCount
    }

    return @($selected | Sort-Object -Unique)
}

function Convert-ProcessTimeToSeconds {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 0.0
    }

    $days = 0
    $time = $Value
    if ($Value.Contains('-')) {
        $parts = $Value.Split('-', 2)
        [void][int]::TryParse($parts[0], [ref]$days)
        $time = $parts[1]
    }

    $segments = $time.Split(':')
    if ($segments.Count -eq 2) {
        $minutes = 0
        $seconds = 0.0
        [void][int]::TryParse($segments[0], [ref]$minutes)
        [void][double]::TryParse($segments[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
        return ($days * 86400) + ($minutes * 60) + $seconds
    }

    if ($segments.Count -eq 3) {
        $hours = 0
        $minutes = 0
        $seconds = 0.0
        [void][int]::TryParse($segments[0], [ref]$hours)
        [void][int]::TryParse($segments[1], [ref]$minutes)
        [void][double]::TryParse($segments[2], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)
        return ($days * 86400) + ($hours * 3600) + ($minutes * 60) + $seconds
    }

    return 0.0
}

function Get-DescendantProcessIdsWindows {
    param([int]$RootProcessId)

    $processes = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
    $childrenByParent = @{}
    foreach ($process in $processes) {
        if (-not $childrenByParent.ContainsKey($process.ParentProcessId)) {
            $childrenByParent[$process.ParentProcessId] = [System.Collections.Generic.List[int]]::new()
        }

        $childrenByParent[$process.ParentProcessId].Add([int]$process.ProcessId)
    }

    $ids = [System.Collections.Generic.List[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($parent)) {
            continue
        }

        foreach ($child in $childrenByParent[$parent]) {
            $ids.Add($child)
            $queue.Enqueue($child)
        }
    }

    return $ids.ToArray()
}

function Get-UnixProcessTable {
    $psPath = if (Test-Path -LiteralPath '/bin/ps') { '/bin/ps' } else { 'ps' }
    $lines = & $psPath -axo pid=,ppid=,rss=,time=
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)') {
            $entries.Add([pscustomobject]@{
                Id = [int]$Matches[1]
                ParentId = [int]$Matches[2]
                WorkingSetBytes = [int64]$Matches[3] * 1024
                CpuSeconds = Convert-ProcessTimeToSeconds $Matches[4]
            })
        }
    }

    return $entries
}

function Get-TrackedProcesses {
    param([int]$RootProcessId)

    if ($IsWindowsPlatform) {
        $ids = @($RootProcessId) + @(Get-DescendantProcessIdsWindows -RootProcessId $RootProcessId)
        return @(Get-Process -Id $ids -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Id = $_.Id
                WorkingSetBytes = [int64]$_.WorkingSet64
                CpuSeconds = $_.TotalProcessorTime.TotalSeconds
            }
        })
    }

    $entries = @(Get-UnixProcessTable)
    $childrenByParent = @{}
    foreach ($entry in $entries) {
        if (-not $childrenByParent.ContainsKey($entry.ParentId)) {
            $childrenByParent[$entry.ParentId] = [System.Collections.Generic.List[int]]::new()
        }

        $childrenByParent[$entry.ParentId].Add($entry.Id)
    }

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($RootProcessId)
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($parent)) {
            continue
        }

        foreach ($child in $childrenByParent[$parent]) {
            if ($ids.Add($child)) {
                $queue.Enqueue($child)
            }
        }
    }

    return @($entries | Where-Object { $ids.Contains($_.Id) })
}

function Get-PropertySum {
    param(
        [object[]]$Items,
        [string]$PropertyName
    )

    $sum = 0.0
    foreach ($item in $Items) {
        $sum += [double]$item.$PropertyName
    }

    return $sum
}

function Get-StandardDeviation {
    param([double[]]$Values)

    if ($Values.Count -le 1) {
        return 0.0
    }

    $average = ($Values | Measure-Object -Average).Average
    $sumSquares = 0.0
    foreach ($value in $Values) {
        $delta = $value - $average
        $sumSquares += $delta * $delta
    }

    return [Math]::Sqrt($sumSquares / $Values.Count)
}

function Invoke-DtbRun {
    param(
        [int]$NodeCount,
        [int]$Round
    )

    $label = "m$NodeCount-r$Round"
    $runDir = Join-Path $OutputRoot $label
    $cacheDir = Join-Path $runDir 'cache'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $stdoutPath = Join-Path $runDir "$label.out.log"
    $stderrPath = Join-Path $runDir "$label.err.log"
    $samplesPath = Join-Path $runDir "$label.samples.csv"

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        'build',
        $BuildPath,
        '/t:ProjectDataBuild',
        '/p:DesignTimeBuild=true',
        '/p:BuildingProject=false',
        '/p:SkipCompilerExecution=true',
        '/p:ProvideCommandLineArgs=true',
        '/p:SuppressImplicitGitSourceLink=true',
        '/p:EnableDynamicPlatformResolution=false'
    )) {
        [void]$arguments.Add($argument)
    }

    if (-not $NoForce) {
        [void]$arguments.Add('/p:_ProjectDataBuildForce=true')
    }

    if (-not $IncludeRestore) {
        [void]$arguments.Add('--no-restore')
    }

    foreach ($argument in @(
        "/m:$NodeCount",
        '/v:quiet',
        '/nodeReuse:false'
    )) {
        [void]$arguments.Add($argument)
    }

    foreach ($argument in $ExtraBuildArguments) {
        [void]$arguments.Add($argument)
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($DotNetPath)
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $startInfo.WorkingDirectory = $RoslynRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['CustomAfterMicrosoftCommonTargets'] = $ProjectDataTargets
    $startInfo.Environment['CustomAfterMicrosoftCommonCrossTargetingTargets'] = $ProjectDataTargets
    $startInfo.Environment['EnableProjectDataInProjectFolder'] = 'false'
    $startInfo.Environment['DOTNET_PROJECTDATA_CACHE_DIR'] = $cacheDir

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $peakProcessCount = 1
    $peakWorkingSetBytes = 0L
    $peakTotalCpuSec = 0.0
    $samples = [System.Collections.Generic.List[object]]::new()

    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 250
        $tracked = @(Get-TrackedProcesses -RootProcessId $process.Id)
        $workingSetBytes = [int64](Get-PropertySum -Items $tracked -PropertyName WorkingSetBytes)
        $totalCpuSec = Get-PropertySum -Items $tracked -PropertyName CpuSeconds

        if ($tracked.Count -gt $peakProcessCount) {
            $peakProcessCount = $tracked.Count
        }

        if ($workingSetBytes -gt $peakWorkingSetBytes) {
            $peakWorkingSetBytes = $workingSetBytes
        }

        if ($totalCpuSec -gt $peakTotalCpuSec) {
            $peakTotalCpuSec = $totalCpuSec
        }

        $samples.Add([pscustomobject]@{
            elapsedSec = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
            processCount = $tracked.Count
            workingSetMB = [Math]::Round($workingSetBytes / 1MB, 1)
            totalCpuSec = [Math]::Round($totalCpuSec, 2)
        })
    }

    $process.WaitForExit()
    $timer.Stop()

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Set-Content -Path $stdoutPath -Value $stdout -Encoding UTF8
    Set-Content -Path $stderrPath -Value $stderr -Encoding UTF8
    $samples | Export-Csv -NoTypeInformation -Path $samplesPath

    $cacheFiles = @(Get-ChildItem -Path $cacheDir -Recurse -File -ErrorAction SilentlyContinue)
    $cacheBytes = [int64](Get-PropertySum -Items $cacheFiles -PropertyName Length)

    [pscustomobject]@{
        label = $label
        nodes = $NodeCount
        round = $Round
        exitCode = $process.ExitCode
        wallSec = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
        peakProcessCount = $peakProcessCount
        peakWorkingSetMB = [Math]::Round($peakWorkingSetBytes / 1MB, 1)
        totalCpuSec = [Math]::Round($peakTotalCpuSec, 2)
        cacheFileCount = $cacheFiles.Count
        cacheBytes = $cacheBytes
        cacheMB = [Math]::Round($cacheBytes / 1MB, 2)
        stdout = $stdoutPath
        stderr = $stderrPath
        samples = $samplesPath
    }
}

if ($ShowInstructions) {
    Write-Instructions
    return
}

if ([string]::IsNullOrWhiteSpace($RoslynRoot)) {
    $RoslynRoot = Resolve-FirstExistingPath @(
        $env:ROSLYN_REPO,
        (Join-Path (Split-Path -Parent $RepoRoot) 'roslyn'),
        'C:\code\roslyn'
    )
}

if ([string]::IsNullOrWhiteSpace($ProjectDataTargets)) {
    $siblingVsGreenTargets = Join-Path (Split-Path -Parent $RepoRoot) 'vs-green'
    $siblingVsGreenTargets = Join-Path $siblingVsGreenTargets 'extension'
    $siblingVsGreenTargets = Join-Path $siblingVsGreenTargets 'dist'
    $siblingVsGreenTargets = Join-Path $siblingVsGreenTargets 'msbuild'
    $siblingVsGreenTargets = Join-Path $siblingVsGreenTargets 'Microsoft.NET.ProjectData.targets'

    $ProjectDataTargets = Resolve-FirstExistingPath @(
        $env:CDK_PROJECTDATA_TARGETS,
        $siblingVsGreenTargets,
        'C:\code\vs-green\extension\dist\msbuild\Microsoft.NET.ProjectData.targets'
    )
}

if ([string]::IsNullOrWhiteSpace($RoslynRoot) -or -not (Test-Path -LiteralPath $RoslynRoot)) {
    throw "RoslynRoot was not found. Pass -RoslynRoot or set ROSLYN_REPO."
}

if ([string]::IsNullOrWhiteSpace($ProjectDataTargets) -or -not (Test-Path -LiteralPath $ProjectDataTargets)) {
    throw "ProjectDataTargets was not found. Pass -ProjectDataTargets or set CDK_PROJECTDATA_TARGETS."
}

if (-not $PSBoundParameters.ContainsKey('NodeCounts') -or $null -eq $NodeCounts -or $NodeCounts.Count -eq 0) {
    $NodeCounts = Get-DefaultNodeCounts
}

$NodeCounts = @($NodeCounts | Sort-Object -Unique)

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('msbuild-cdk-projectdata-benchmark-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

Write-Host "RoslynRoot: $RoslynRoot"
Write-Host "BuildPath: $BuildPath"
Write-Host "ProjectDataTargets: $ProjectDataTargets"
Write-Host "OutputRoot: $OutputRoot"
Write-Host "NodeCounts: $($NodeCounts -join ', ')"
Write-Host "Rounds: $Rounds"
Write-Host "Logical processors: $([Environment]::ProcessorCount)"

$results = [System.Collections.Generic.List[object]]::new()
for ($round = 1; $round -le $Rounds; $round++) {
    foreach ($nodeCount in $NodeCounts) {
        Write-Host "Running $BuildPath /m:$nodeCount round $round..."
        $result = Invoke-DtbRun -NodeCount $nodeCount -Round $round
        $results.Add($result)
        Write-Host ("  exit={0} wall={1}s peakProc={2} peakWS={3}MB cacheFiles={4} cacheBytes={5}" -f
            $result.exitCode,
            $result.wallSec,
            $result.peakProcessCount,
            $result.peakWorkingSetMB,
            $result.cacheFileCount,
            $result.cacheBytes)
    }
}

$resultsPath = Join-Path $OutputRoot 'cdk-projectdata-node-results.csv'
$results | Export-Csv -NoTypeInformation -Path $resultsPath

$summary = @(foreach ($group in $results | Group-Object nodes) {
    $rows = @($group.Group)
    $wallSeconds = [double[]]@($rows | ForEach-Object { [double]$_.wallSec })
    $peakProcessCounts = [double[]]@($rows | ForEach-Object { [double]$_.peakProcessCount })
    $peakWorkingSetMb = [double[]]@($rows | ForEach-Object { [double]$_.peakWorkingSetMB })
    $cacheFileCounts = [double[]]@($rows | ForEach-Object { [double]$_.cacheFileCount })
    $cacheBytes = [double[]]@($rows | ForEach-Object { [double]$_.cacheBytes })

    [pscustomobject]@{
        nodes = [int]$group.Name
        runs = $rows.Count
        minSec = [Math]::Round(($wallSeconds | Measure-Object -Minimum).Minimum, 2)
        avgSec = [Math]::Round(($wallSeconds | Measure-Object -Average).Average, 2)
        maxSec = [Math]::Round(($wallSeconds | Measure-Object -Maximum).Maximum, 2)
        stdevSec = [Math]::Round((Get-StandardDeviation -Values $wallSeconds), 2)
        avgPeakProcessCount = [Math]::Round(($peakProcessCounts | Measure-Object -Average).Average, 1)
        avgPeakWorkingSetMB = [Math]::Round(($peakWorkingSetMb | Measure-Object -Average).Average, 1)
        avgCacheFiles = [Math]::Round(($cacheFileCounts | Measure-Object -Average).Average, 1)
        avgCacheBytes = [Math]::Round(($cacheBytes | Measure-Object -Average).Average, 0)
        avgCacheMB = [Math]::Round((($cacheBytes | Measure-Object -Average).Average / 1MB), 2)
    }
}) | Sort-Object nodes

$summaryPath = Join-Path $OutputRoot 'cdk-projectdata-node-summary.csv'
$summary | Export-Csv -NoTypeInformation -Path $summaryPath
$summary | Format-Table -AutoSize

Write-Host
Write-Host "Results CSV: $resultsPath"
Write-Host "Summary CSV: $summaryPath"

$failed = @($results | Where-Object { $_.exitCode -ne 0 })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) benchmark run(s) failed. Inspect per-run stderr logs under $OutputRoot."
}
