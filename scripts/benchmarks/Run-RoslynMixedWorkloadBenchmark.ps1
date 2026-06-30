<#
.SYNOPSIS
Runs mixed Roslyn regular-build plus C# Dev Kit ProjectDataBuild stress scenarios.

.DESCRIPTION
Creates isolated Roslyn worktrees, optionally restores and warms them, then runs:
  - strict coordinator simulation: capped normal builds plus capped DTB, no overflow
  - overflow coordinator simulation: capped normal builds plus capped DTB, with one overflow lane
  - no-coordinator/default simulation: all clients use full logical processor count

This does not require the coordinator protocol. It simulates the proposed node
shapes by controlling /m and how many normal builds are allowed to run at once.

.EXAMPLE
pwsh ./scripts/benchmarks/Run-RoslynMixedWorkloadBenchmark.ps1 `
  -RoslynRoot ~/code/roslyn `
  -ProjectDataTargets ~/code/vs-green/extension/dist/msbuild/Microsoft.NET.ProjectData.targets `
  -Prepare
#>
[CmdletBinding()]
param(
    [string]$RoslynRoot = $env:ROSLYN_REPO,
    [string]$ProjectDataTargets = $env:CDK_PROJECTDATA_TARGETS,
    [string]$WorkRoot,
    [string]$OutputRoot,
    [int]$Slice = 4,
    [int]$Reservation = 4,
    [int]$Overflow = -1,
    [int]$NormalBuildCount = 0,
    [int]$DtbDelaySeconds = 15,
    [switch]$Prepare,
    [switch]$SkipWarm,
    [switch]$ShowInstructions
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
$ProcessorCount = [Environment]::ProcessorCount
$NormalSolution = 'Compilers.slnf'
$DtbSolution = 'Roslyn.slnx'
$TouchFileRelativePath = [System.IO.Path]::Combine('src', 'Compilers', 'CSharp', 'Portable', 'CSharpCompilationOptions.cs')

function Write-Instructions {
    @"
Roslyn mixed workload benchmark

Purpose:
  Compare proposed coordinator cap/reservation/overflow shapes with today's
  no-coordinator default behavior under concurrent real Roslyn work:
    normal builds: Compilers.slnf
    DTB/cache:     Roslyn.slnx ProjectDataBuild

Suggested M1 Pro command:
  pwsh ./scripts/benchmarks/Run-RoslynMixedWorkloadBenchmark.ps1 \
    -RoslynRoot /path/to/roslyn \
    -ProjectDataTargets /path/to/vs-green/extension/dist/msbuild/Microsoft.NET.ProjectData.targets \
    -Prepare

Defaults on this machine:
  logical processors: $ProcessorCount
  slice:              $Slice
  reservation:        $Reservation
  overflow:           $(Get-AutoOverflow -TotalNodes $ProcessorCount -Slice $Slice -Reservation $Reservation)

Outputs:
  scenario-summary.csv
  <scenario>/runs.csv
  <scenario>/samples.csv
  per-run stdout/stderr logs and DTB cache output
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

function Get-AutoOverflow {
    param(
        [int]$TotalNodes,
        [int]$Slice,
        [int]$Reservation
    )

    if ($TotalNodes -lt 8) {
        return 0
    }

    if ($TotalNodes -ge 12) {
        return $Slice
    }

    $baseNormal = [Math]::Max(0, $TotalNodes - $Reservation)
    return ($Slice - ($baseNormal % $Slice)) % $Slice
}

function Get-MaxNormalBuilds {
    param(
        [int]$TotalNodes,
        [int]$Reservation,
        [int]$Overflow,
        [int]$Slice
    )

    return [Math]::Max(1, [int][Math]::Floor(($TotalNodes - $Reservation + $Overflow) / $Slice))
}

function Invoke-Checked {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$Label
    )

    Write-Host "[$Label] $FileName $($Arguments -join ' ')"
    Push-Location $WorkingDirectory
    try {
        $output = & $FileName @Arguments 2>&1
        foreach ($line in $output) {
            Write-Host $line
        }

        if ($LASTEXITCODE -ne 0) {
            throw "$Label failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-ProcessCreationUtc {
    param([object]$CimProcess)

    if ($CimProcess.CreationDate -is [DateTime]) {
        return $CimProcess.CreationDate.ToUniversalTime()
    }

    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$CimProcess.CreationDate).ToUniversalTime()
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Get-DescendantProcessIdsWindows {
    param([int[]]$RootProcessIds)

    $processes = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
    $childrenByParent = @{}
    foreach ($process in $processes) {
        if (-not $childrenByParent.ContainsKey($process.ParentProcessId)) {
            $childrenByParent[$process.ParentProcessId] = [System.Collections.Generic.List[int]]::new()
        }

        $childrenByParent[$process.ParentProcessId].Add([int]$process.ProcessId)
    }

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    foreach ($rootProcessId in $RootProcessIds) {
        if ($ids.Add($rootProcessId)) {
            $queue.Enqueue($rootProcessId)
        }
    }

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

    return [int[]]@($ids)
}

function Get-TrackedBenchmarkProcessesWindows {
    param(
        [int[]]$RootProcessIds,
        [DateTime]$ScenarioStartUtc
    )

    $trackedIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in @(Get-DescendantProcessIdsWindows -RootProcessIds $RootProcessIds)) {
        [void]$trackedIds.Add($id)
    }

    foreach ($process in Get-CimInstance Win32_Process) {
        $name = [string]$process.Name
        if ($name -notin @('dotnet.exe', 'MSBuild.exe', 'VBCSCompiler.exe', 'csc.exe')) {
            continue
        }

        if ((Get-ProcessCreationUtc -CimProcess $process) -lt $ScenarioStartUtc.AddSeconds(-5)) {
            continue
        }

        $commandLine = [string]$process.CommandLine
        if ($trackedIds.Contains([int]$process.ParentProcessId) -or
            $commandLine.Contains('MSBuild.dll') -or
            $commandLine.Contains('Compilers.slnf') -or
            $commandLine.Contains('Roslyn.slnx') -or
            $commandLine.Contains('VBCSCompiler')) {
            [void]$trackedIds.Add([int]$process.ProcessId)
        }
    }

    return @(Get-Process -Id ([int[]]@($trackedIds)) -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; WorkingSetBytes = [int64]$_.WorkingSet64 }
    })
}

function Get-UnixProcessTable {
    $psPath = if (Test-Path -LiteralPath '/bin/ps') { '/bin/ps' } else { 'ps' }
    $lines = & $psPath -axo pid=,ppid=,rss=,command=
    foreach ($line in $lines) {
        if ($line -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$') {
            [pscustomobject]@{
                Id = [int]$Matches[1]
                ParentId = [int]$Matches[2]
                WorkingSetBytes = [int64]$Matches[3] * 1024
                CommandLine = $Matches[4]
            }
        }
    }
}

function Get-TrackedBenchmarkProcessesUnix {
    param([int[]]$RootProcessIds)

    $entries = @(Get-UnixProcessTable)
    $childrenByParent = @{}
    foreach ($entry in $entries) {
        if (-not $childrenByParent.ContainsKey($entry.ParentId)) {
            $childrenByParent[$entry.ParentId] = [System.Collections.Generic.List[int]]::new()
        }

        $childrenByParent[$entry.ParentId].Add($entry.Id)
    }

    $trackedIds = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    foreach ($rootProcessId in $RootProcessIds) {
        if ($trackedIds.Add($rootProcessId)) {
            $queue.Enqueue($rootProcessId)
        }
    }

    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($parent)) {
            continue
        }

        foreach ($child in $childrenByParent[$parent]) {
            if ($trackedIds.Add($child)) {
                $queue.Enqueue($child)
            }
        }
    }

    foreach ($entry in $entries) {
        $commandLine = [string]$entry.CommandLine
        if ($commandLine.Contains('MSBuild.dll') -or
            $commandLine.Contains('Compilers.slnf') -or
            $commandLine.Contains('Roslyn.slnx') -or
            $commandLine.Contains('VBCSCompiler')) {
            [void]$trackedIds.Add($entry.Id)
        }
    }

    return @($entries | Where-Object { $trackedIds.Contains($_.Id) })
}

function Get-TrackedBenchmarkProcesses {
    param(
        [int[]]$RootProcessIds,
        [DateTime]$ScenarioStartUtc
    )

    if ($IsWindowsPlatform) {
        return @(Get-TrackedBenchmarkProcessesWindows -RootProcessIds $RootProcessIds -ScenarioStartUtc $ScenarioStartUtc)
    }

    return @(Get-TrackedBenchmarkProcessesUnix -RootProcessIds $RootProcessIds)
}

function New-BenchmarkProcess {
    param(
        [string]$Kind,
        [string]$Label,
        [string]$WorkingDirectory,
        [int]$NodeCount,
        [string]$ScenarioDir
    )

    $runDir = Join-Path $ScenarioDir $Label
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $stdoutPath = Join-Path $runDir "$Label.out.log"
    $stderrPath = Join-Path $runDir "$Label.err.log"

    if ($Kind -eq 'normal') {
        $arguments = @('build', $NormalSolution, '--no-restore', "/m:$NodeCount", '/v:q', '/nodeReuse:false')
    } else {
        $arguments = @(
            'build', $DtbSolution,
            '/t:ProjectDataBuild',
            '/p:DesignTimeBuild=true',
            '/p:BuildingProject=false',
            '/p:SkipCompilerExecution=true',
            '/p:ProvideCommandLineArgs=true',
            '/p:SuppressImplicitGitSourceLink=true',
            '/p:EnableDynamicPlatformResolution=false',
            '/p:_ProjectDataBuildForce=true',
            '--no-restore',
            "/m:$NodeCount",
            '/v:q',
            '/nodeReuse:false'
        )
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('dotnet')
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($Kind -eq 'dtb') {
        $cacheDir = Join-Path $runDir 'cache'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $startInfo.Environment['CustomAfterMicrosoftCommonTargets'] = $ProjectDataTargets
        $startInfo.Environment['CustomAfterMicrosoftCommonCrossTargetingTargets'] = $ProjectDataTargets
        $startInfo.Environment['EnableProjectDataInProjectFolder'] = 'false'
        $startInfo.Environment['DOTNET_PROJECTDATA_CACHE_DIR'] = $cacheDir
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    [pscustomobject]@{
        kind = $Kind
        label = $Label
        workingDirectory = $WorkingDirectory
        nodes = $NodeCount
        process = $process
        stdoutTask = $process.StandardOutput.ReadToEndAsync()
        stderrTask = $process.StandardError.ReadToEndAsync()
        stdout = $stdoutPath
        stderr = $stderrPath
        startTime = Get-Date
        endTime = $null
        exitCode = $null
        completed = $false
    }
}

function Complete-BenchmarkProcess {
    param([object]$Run)

    if ($Run.completed -or -not $Run.process.HasExited) {
        return
    }

    $Run.process.WaitForExit()
    $Run.endTime = Get-Date
    $Run.exitCode = $Run.process.ExitCode
    Set-Content -Path $Run.stdout -Value $Run.stdoutTask.GetAwaiter().GetResult() -Encoding UTF8
    Set-Content -Path $Run.stderr -Value $Run.stderrTask.GetAwaiter().GetResult() -Encoding UTF8
    $Run.completed = $true
}

function Ensure-Worktrees {
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    $worktrees = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -le $NormalBuildCount; $i++) {
        $worktrees.Add([pscustomobject]@{ kind = 'normal'; index = $i; path = Join-Path $WorkRoot "normal$i" })
    }

    $worktrees.Add([pscustomobject]@{ kind = 'dtb'; index = 1; path = Join-Path $WorkRoot 'dtb1' })

    foreach ($worktree in $worktrees) {
        if (-not (Test-Path -LiteralPath $worktree.path)) {
            Invoke-Checked -FileName 'git' -Arguments @('-C', $RoslynRoot, 'worktree', 'add', '--detach', $worktree.path, 'HEAD') -WorkingDirectory $RoslynRoot -Label "worktree-$($worktree.kind)$($worktree.index)"
        }
    }

    return $worktrees.ToArray()
}

function Restore-And-Warm {
    param([object[]]$Worktrees)

    foreach ($worktree in $Worktrees) {
        Invoke-Checked -FileName 'dotnet' -Arguments @('restore', $DtbSolution, '/v:q') -WorkingDirectory $worktree.path -Label "restore-$($worktree.kind)$($worktree.index)"
    }

    if ($SkipWarm) {
        return
    }

    foreach ($worktree in @($Worktrees | Where-Object { $_.kind -eq 'normal' })) {
        Invoke-Checked -FileName 'dotnet' -Arguments @('build', $NormalSolution, '--no-restore', "/m:$ProcessorCount", '/v:q', '/nodeReuse:false') -WorkingDirectory $worktree.path -Label "warm-normal$($worktree.index)"
    }

    $dtbWorktree = @($Worktrees | Where-Object { $_.kind -eq 'dtb' })[0]
    $env:CustomAfterMicrosoftCommonTargets = $ProjectDataTargets
    $env:CustomAfterMicrosoftCommonCrossTargetingTargets = $ProjectDataTargets
    $env:EnableProjectDataInProjectFolder = 'false'
    $env:DOTNET_PROJECTDATA_CACHE_DIR = Join-Path $WorkRoot 'warm-dtb-cache'
    Invoke-Checked -FileName 'dotnet' -Arguments @(
        'build', $DtbSolution,
        '/t:ProjectDataBuild',
        '/p:DesignTimeBuild=true',
        '/p:BuildingProject=false',
        '/p:SkipCompilerExecution=true',
        '/p:ProvideCommandLineArgs=true',
        '/p:SuppressImplicitGitSourceLink=true',
        '/p:EnableDynamicPlatformResolution=false',
        '/p:_ProjectDataBuildForce=true',
        '--no-restore',
        "/m:$Slice",
        '/v:q',
        '/nodeReuse:false'
    ) -WorkingDirectory $dtbWorktree.path -Label 'warm-dtb'
    Remove-Item Env:\CustomAfterMicrosoftCommonTargets -ErrorAction SilentlyContinue
    Remove-Item Env:\CustomAfterMicrosoftCommonCrossTargetingTargets -ErrorAction SilentlyContinue
    Remove-Item Env:\EnableProjectDataInProjectFolder -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_PROJECTDATA_CACHE_DIR -ErrorAction SilentlyContinue
}

function Touch-NormalInputs {
    param([object[]]$NormalWorktrees)

    foreach ($worktree in $NormalWorktrees) {
        $touchPath = Join-Path $worktree.path $TouchFileRelativePath
        if (-not (Test-Path -LiteralPath $touchPath)) {
            throw "Touch file missing: $touchPath"
        }

        (Get-Item -LiteralPath $touchPath).LastWriteTimeUtc = [DateTime]::UtcNow
    }
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [object[]]$Worktrees,
        [int]$NormalNodeCount,
        [int]$DtbNodeCount,
        [int]$MaxConcurrentNormal
    )

    Write-Host "Starting scenario $Name (normal /m:$NormalNodeCount, dtb /m:$DtbNodeCount, max normal $MaxConcurrentNormal)"
    $scenarioDir = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Force -Path $scenarioDir | Out-Null

    $normalWorktrees = @($Worktrees | Where-Object { $_.kind -eq 'normal' } | Sort-Object index)
    $dtbWorktree = @($Worktrees | Where-Object { $_.kind -eq 'dtb' })[0]
    Touch-NormalInputs -NormalWorktrees $normalWorktrees
    Invoke-Checked -FileName 'dotnet' -Arguments @('build-server', 'shutdown') -WorkingDirectory $RoslynRoot -Label "shutdown-$Name"

    $pendingNormals = [System.Collections.Generic.Queue[object]]::new()
    foreach ($normalWorktree in $normalWorktrees) {
        $pendingNormals.Enqueue($normalWorktree)
    }

    $runs = [System.Collections.Generic.List[object]]::new()
    $scenarioStartTime = Get-Date
    $scenarioStartUtc = [DateTime]::UtcNow
    $scenarioTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $samples = [System.Collections.Generic.List[object]]::new()
    $dtbStarted = $false

    while ($pendingNormals.Count -gt 0 -and (@($runs | Where-Object { $_.kind -eq 'normal' -and -not $_.completed }).Count -lt $MaxConcurrentNormal)) {
        $normalWorktree = $pendingNormals.Dequeue()
        $runs.Add((New-BenchmarkProcess -Kind 'normal' -Label "normal$($normalWorktree.index)" -WorkingDirectory $normalWorktree.path -NodeCount $NormalNodeCount -ScenarioDir $scenarioDir))
    }

    while ($true) {
        foreach ($run in @($runs)) {
            Complete-BenchmarkProcess -Run $run
        }

        while ($pendingNormals.Count -gt 0 -and (@($runs | Where-Object { $_.kind -eq 'normal' -and -not $_.completed }).Count -lt $MaxConcurrentNormal)) {
            $normalWorktree = $pendingNormals.Dequeue()
            $runs.Add((New-BenchmarkProcess -Kind 'normal' -Label "normal$($normalWorktree.index)" -WorkingDirectory $normalWorktree.path -NodeCount $NormalNodeCount -ScenarioDir $scenarioDir))
        }

        if (-not $dtbStarted -and $scenarioTimer.Elapsed.TotalSeconds -ge $DtbDelaySeconds) {
            $runs.Add((New-BenchmarkProcess -Kind 'dtb' -Label 'dtb1' -WorkingDirectory $dtbWorktree.path -NodeCount $DtbNodeCount -ScenarioDir $scenarioDir))
            $dtbStarted = $true
        }

        $activeRuns = @($runs | Where-Object { -not $_.completed })
        if ($dtbStarted -and $pendingNormals.Count -eq 0 -and $activeRuns.Count -eq 0) {
            break
        }

        $rootIds = @($activeRuns | ForEach-Object { $_.process.Id })
        if ($rootIds.Count -gt 0) {
            $processes = @(Get-TrackedBenchmarkProcesses -RootProcessIds $rootIds -ScenarioStartUtc $scenarioStartUtc)
            $workingSetBytes = 0L
            foreach ($process in $processes) {
                $workingSetBytes += [int64]$process.WorkingSetBytes
            }

            $samples.Add([pscustomobject]@{
                elapsedSec = [Math]::Round($scenarioTimer.Elapsed.TotalSeconds, 2)
                activeRuns = $activeRuns.Count
                processCount = $processes.Count
                workingSetMB = [Math]::Round($workingSetBytes / 1MB, 1)
            })
        }

        Start-Sleep -Milliseconds 500
    }

    $scenarioTimer.Stop()
    foreach ($run in @($runs)) {
        Complete-BenchmarkProcess -Run $run
    }

    $resultRows = foreach ($run in $runs) {
        $duration = if ($run.endTime -is [DateTime]) { ($run.endTime - $run.startTime).TotalSeconds } else { 0 }
        [pscustomobject]@{
            scenario = $Name
            label = $run.label
            kind = $run.kind
            nodes = $run.nodes
            exitCode = $run.exitCode
            startOffsetSec = [Math]::Round(($run.startTime - $scenarioStartTime).TotalSeconds, 2)
            durationSec = [Math]::Round($duration, 2)
            stdout = $run.stdout
            stderr = $run.stderr
        }
    }

    $resultsPath = Join-Path $scenarioDir 'runs.csv'
    $samplesPath = Join-Path $scenarioDir 'samples.csv'
    $summaryPath = Join-Path $scenarioDir 'summary.csv'
    $resultRows | Export-Csv -NoTypeInformation -Path $resultsPath
    $samples | Export-Csv -NoTypeInformation -Path $samplesPath

    $peakProcessCount = 0
    $peakWorkingSetMB = 0.0
    foreach ($sample in $samples) {
        if ($sample.processCount -gt $peakProcessCount) { $peakProcessCount = $sample.processCount }
        if ($sample.workingSetMB -gt $peakWorkingSetMB) { $peakWorkingSetMB = $sample.workingSetMB }
    }

    $dtbRun = @($resultRows | Where-Object { $_.kind -eq 'dtb' })[0]
    $normalRows = @($resultRows | Where-Object { $_.kind -eq 'normal' })
    $scenarioSummary = [pscustomobject]@{
        scenario = $Name
        normalNodeCount = $NormalNodeCount
        dtbNodeCount = $DtbNodeCount
        maxConcurrentNormal = $MaxConcurrentNormal
        totalWallSec = [Math]::Round($scenarioTimer.Elapsed.TotalSeconds, 2)
        dtbDurationSec = $dtbRun.durationSec
        avgNormalDurationSec = [Math]::Round((($normalRows.durationSec | Measure-Object -Average).Average), 2)
        maxNormalDurationSec = [Math]::Round((($normalRows.durationSec | Measure-Object -Maximum).Maximum), 2)
        peakProcessCount = $peakProcessCount
        peakWorkingSetMB = $peakWorkingSetMB
        failedRuns = @($resultRows | Where-Object { $_.exitCode -ne 0 }).Count
        results = $resultsPath
        samples = $samplesPath
    }
    $scenarioSummary | Export-Csv -NoTypeInformation -Path $summaryPath
    $scenarioSummary
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

if ($Overflow -lt 0) {
    $Overflow = Get-AutoOverflow -TotalNodes $ProcessorCount -Slice $Slice -Reservation $Reservation
}

$strictNormal = Get-MaxNormalBuilds -TotalNodes $ProcessorCount -Reservation $Reservation -Overflow 0 -Slice $Slice
$overflowNormal = Get-MaxNormalBuilds -TotalNodes $ProcessorCount -Reservation $Reservation -Overflow $Overflow -Slice $Slice
if ($NormalBuildCount -le 0) {
    $NormalBuildCount = $overflowNormal
}

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roslyn-mixed-worktrees-$ProcessorCount"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('roslyn-mixed-workload-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

Write-Host "RoslynRoot: $RoslynRoot"
Write-Host "ProjectDataTargets: $ProjectDataTargets"
Write-Host "WorkRoot: $WorkRoot"
Write-Host "OutputRoot: $OutputRoot"
Write-Host "Logical processors: $ProcessorCount"
Write-Host "Slice: $Slice"
Write-Host "Reservation: $Reservation"
Write-Host "Overflow: $Overflow"
Write-Host "NormalBuildCount: $NormalBuildCount"
Write-Host "Strict max normal: $strictNormal"
Write-Host "Overflow max normal: $overflowNormal"

$worktrees = Ensure-Worktrees
if ($Prepare) {
    Restore-And-Warm -Worktrees $worktrees
}

$summaries = [System.Collections.Generic.List[object]]::new()
[void]$summaries.Add((Invoke-Scenario -Name 'coordinator-strict-sim' -Worktrees $worktrees -NormalNodeCount $Slice -DtbNodeCount $Slice -MaxConcurrentNormal $strictNormal))
[void]$summaries.Add((Invoke-Scenario -Name 'coordinator-overflow-sim' -Worktrees $worktrees -NormalNodeCount $Slice -DtbNodeCount $Slice -MaxConcurrentNormal $overflowNormal))
[void]$summaries.Add((Invoke-Scenario -Name 'no-coordinator-default-sim' -Worktrees $worktrees -NormalNodeCount $ProcessorCount -DtbNodeCount $ProcessorCount -MaxConcurrentNormal $NormalBuildCount))

$summaryCsv = Join-Path $OutputRoot 'scenario-summary.csv'
$summaries | Export-Csv -NoTypeInformation -Path $summaryCsv
$summaries | Format-Table -AutoSize
Write-Host "Summary CSV: $summaryCsv"
