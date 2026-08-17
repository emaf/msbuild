[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('roslyn', 'aspire')]
    [string]$RepositoryName,

    [Parameter(Mandatory)]
    [ValidateSet('BASE', 'FINAL-N', 'FINAL-H')]
    [string]$Condition,

    [Parameter(Mandatory)]
    [ValidateRange(1, 10)]
    [int]$WorkerCount,

    [Parameter(Mandatory)]
    [string]$ScenarioRoot,

    [string]$PreparationPath =
        'C:\perf\results\current-vs-final-sustained-pilot-20260813\preparation\preparation-completion.json',

    [ValidateRange(30, 480)]
    [int]$WindowSeconds = 480,

    [ValidateRange(10, 240)]
    [int]$InjectionOffsetSeconds = 240,

    [ValidateRange(30, 900)]
    [int]$OnsetTimeoutSeconds = 900,

    [switch]$SkipOnsetGate,

    [switch]$Pilot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolingRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolingRoot 'Scenario.Common.ps1')
. (Join-Path $toolingRoot 'sustained\SustainedCampaign.Common.ps1')

if ($InjectionOffsetSeconds -ge $WindowSeconds) {
    throw 'InjectionOffsetSeconds must be less than WindowSeconds.'
}
if (Test-Path -LiteralPath $ScenarioRoot) {
    throw "Scenario root '$ScenarioRoot' already exists."
}
New-Item -ItemType Directory -Path $ScenarioRoot | Out-Null
$ScenarioRoot = (Resolve-Path -LiteralPath $ScenarioRoot).Path

$debugPath = Join-Path $ScenarioRoot 'coordinator-debug'
$monitorRoot = Join-Path $ScenarioRoot 'monitor'
$eventPath = Join-Path $ScenarioRoot 'events.jsonl'
$runsRoot = Join-Path $ScenarioRoot 'runs'
New-Item -ItemType Directory -Force -Path $debugPath,$runsRoot | Out-Null
$script:eventWriter = [IO.StreamWriter]::new(
    $eventPath,
    $false,
    [Text.UTF8Encoding]::new($false))
$script:eventWriter.AutoFlush = $true

$campaign = Get-CampaignDefinition
$preparation =
    Get-Content -LiteralPath $PreparationPath -Raw |
    ConvertFrom-Json
$preparedRepository =
    $preparation.Repositories |
    Where-Object Name -eq $RepositoryName |
    Select-Object -First 1
if ($null -eq $preparedRepository) {
    throw "Preparation does not contain '$RepositoryName'."
}
$repositoryDefinition =
    $campaign.Repositories |
    Where-Object Name -eq $RepositoryName |
    Select-Object -First 1
$bootstrapRoot = if ($Condition -eq 'BASE') {
    'C:\perf\bootstraps\current-vs-final\ff5b281f0c58-2E843FFB6575\core'
}
else {
    'C:\perf\bootstraps\current-vs-final\432466e41a95-3B4AF511ED65\core'
}
$bootstrapCommit = if ($Condition -eq 'BASE') {
    $campaign.Base.Commit
}
else {
    $campaign.Final.Commit
}
$bootstrap = Get-BootstrapIdentity `
    -Role $(if ($Condition -eq 'BASE') { 'base' } else { 'final' }) `
    -Root $bootstrapRoot `
    -ExpectedCommit $bootstrapCommit

$selectedWorktrees = @(
    foreach ($name in @(
        (1..$WorkerCount | ForEach-Object { "normal$_" }) +
            @('injected')
    )) {
        $worktree =
            $preparedRepository.Worktrees |
            Where-Object Name -eq $name |
            Select-Object -First 1
        if ($null -eq $worktree) {
            throw "Prepared worktree '$RepositoryName/$name' is missing."
        }
        [void](Get-GitIdentity `
            -Root $worktree.Path `
            -ExpectedCommit $repositoryDefinition.Commit `
            -RequireClean)
        $worktree
    }
)

function Write-SimpleJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [object]$Value,
        [int]$Depth = 12
    )

    Write-JsonAtomic -Path $Path -Value $Value -Depth $Depth
}

function Add-SimpleEvent {
    param(
        [Parameter(Mandatory)]
        [string]$Event,
        [object]$Run,
        [System.Collections.IDictionary]$Data = @{}
    )

    $entry = [ordered]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Event = $Event
        RunId = if ($null -eq $Run) { $null } else { $Run.RunId }
        Worker = if ($null -eq $Run) { $null } else { $Run.Worker }
        Generation = if ($null -eq $Run) { $null } else { $Run.Generation }
    }
    foreach ($item in $Data.GetEnumerator()) {
        $entry[$item.Key] = $item.Value
    }
    $script:eventWriter.WriteLine(
        ([pscustomobject]$entry | ConvertTo-Json -Compress -Depth 8))
}

function Get-SimpleWorktree {
    param([Parameter(Mandatory)][string]$Name)

    $worktree =
        $selectedWorktrees |
        Where-Object Name -eq $Name |
        Select-Object -First 1
    if ($null -eq $worktree) {
        throw "Selected worktree '$Name' is missing."
    }
    return [string]$worktree.Path
}

function ConvertTo-SimpleRunRecord {
    param([Parameter(Mandatory)][object]$Run)

    [pscustomobject][ordered]@{
        RunId = $Run.RunId
        Kind = $Run.Kind
        Worker = $Run.Worker
        Generation = $Run.Generation
        Priority = $Run.Priority
        Worktree = $Run.Worktree
        RootProcessId = $Run.RootProcessId
        ProcessStartUtc = $Run.ProcessStartUtc.ToString('O')
        ProcessExitUtc = if ($null -eq $Run.ProcessExitUtc) {
            $null
        }
        else {
            $Run.ProcessExitUtc.ToString('O')
        }
        DurationSeconds = if ($null -eq $Run.ProcessExitUtc) {
            $null
        }
        else {
            ($Run.ProcessExitUtc - $Run.ProcessStartUtc).TotalSeconds
        }
        ExitCode = $Run.ExitCode
        Quiescent = $Run.Quiescent
        JobEmptyUtc = if ($null -eq $Run.JobEmptyUtc) {
            $null
        }
        else {
            $Run.JobEmptyUtc.ToString('O')
        }
        StreamDrainedUtc = if ($null -eq $Run.StreamDrainedUtc) {
            $null
        }
        else {
            $Run.StreamDrainedUtc.ToString('O')
        }
        EnvironmentPath = $Run.EnvironmentPath
        Stdout = $Run.Stdout
        Stderr = $Run.Stderr
        Binlog = $Run.Binlog
        Command = $Run.Command
    }
}

function Start-SimpleBuild {
    param(
        [Parameter(Mandatory)]
        [string]$RunId,
        [Parameter(Mandatory)]
        [ValidateSet('normal', 'probe')]
        [string]$Kind,
        [Parameter(Mandatory)]
        [int]$Worker,
        [Parameter(Mandatory)]
        [int]$Generation,
        [Parameter(Mandatory)]
        [string]$Worktree,
        [switch]$Injected
    )

    $runRoot = Join-Path $runsRoot $RunId
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $stdout = Join-Path $runRoot 'stdout.log'
    $stderr = Join-Path $runRoot 'stderr.log'
    $binlog = Join-Path $runRoot 'build.binlog'
    $environmentPath = Join-Path $runRoot 'environment.json'
    $environment = New-ConditionEnvironment `
        -Condition $Condition `
        -PipeName $script:pipeName `
        -DotNetRoot $bootstrap.Root `
        -Injected:$Injected `
        -EnableDebugTrace `
        -DebugPath $debugPath
    Assert-ConditionEnvironmentContract `
        -Condition $Condition `
        -Environment $environment `
        -Injected:$Injected
    Write-SimpleJson `
        -Path $environmentPath `
        -Value (Get-EnvironmentContractRecord -Environment $environment)

    $arguments = New-BuildArguments `
        -MSBuildDllPath $bootstrap.MSBuildDllPath `
        -BuildPath $preparedRepository.BuildPath `
        -BinlogPath $binlog `
        -AdditionalArguments @($preparedRepository.AdditionalBuildArguments)
    $startInfo = [Diagnostics.ProcessStartInfo]::new($bootstrap.DotNetPath)
    foreach ($argument in $arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $Worktree
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($item in $environment.GetEnumerator()) {
        if ($null -eq $item.Value) {
            [void]$startInfo.Environment.Remove([string]$item.Key)
        }
        else {
            $startInfo.Environment[[string]$item.Key] = [string]$item.Value
        }
    }

    Add-SimpleEvent `
        -Event 'request-created' `
        -Run ([pscustomobject]@{
            RunId = $RunId
            Worker = $Worker
            Generation = $Generation
        }) `
        -Data ([ordered]@{
            Kind = $Kind
            Worktree = $Worktree
            Priority = if ($Condition -eq 'FINAL-H' -and $Injected) {
                'High'
            }
            else {
                'Normal'
            }
        })

    $job = New-ScenarioTrackingJob -RunId $RunId
    $process = $null
    try {
        $process = New-SuspendedScenarioProcess -StartInfo $startInfo
        Add-ProcessToScenarioTrackingJob -Job $job -Process $process
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $processStartUtc =
            [DateTimeOffset]::new($process.StartTime).ToUniversalTime()
        Resume-SuspendedScenarioProcess -Process $process
    }
    catch {
        if ($null -ne $process) {
            try {
                if (-not $process.IsResumed) {
                    Stop-SuspendedScenarioProcessBeforeResume -Process $process
                }
            }
            finally {
                $process.Dispose()
            }
        }
        $job.Dispose()
        throw
    }

    $run = [pscustomobject][ordered]@{
        RunId = $RunId
        Kind = $Kind
        Worker = $Worker
        Generation = $Generation
        Priority = if ($Condition -eq 'FINAL-H' -and $Injected) {
            'High'
        }
        else {
            'Normal'
        }
        Worktree = $Worktree
        RootProcessId = $process.Id
        ProcessStartUtc = $processStartUtc
        ProcessExitUtc = $null
        ExitCode = $null
        Quiescent = $false
        Completed = $false
        GrantEventWritten = $false
        JobEmptyUtc = $null
        StreamDrainedUtc = $null
        Process = $process
        TrackingJob = $job
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
        Stdout = $stdout
        Stderr = $stderr
        Binlog = $binlog
        EnvironmentPath = $environmentPath
        Command = [pscustomobject]@{
            FileName = $bootstrap.DotNetPath
            Arguments = $arguments
            WorkingDirectory = $Worktree
        }
    }
    Add-SimpleEvent `
        -Event 'process-start' `
        -Run $run `
        -Data ([ordered]@{
            RootProcessId = $run.RootProcessId
            ProcessStartUtc = $run.ProcessStartUtc.ToString('O')
            JobName = $job.Name
        })
    return $run
}

function Complete-SimpleBuild {
    param([Parameter(Mandatory)][object]$Run)

    if ($Run.Completed -or -not $Run.Process.HasExited) {
        return $false
    }

    $Run.Process.WaitForExit()
    $Run.ProcessExitUtc =
        [DateTimeOffset]::new($Run.Process.ExitTime).ToUniversalTime()
    $Run.ExitCode = $Run.Process.ExitCode
    Add-SimpleEvent `
        -Event 'root-exit' `
        -Run $Run `
        -Data ([ordered]@{
            RootProcessId = $Run.RootProcessId
            ExitCode = $Run.ExitCode
            ProcessExitUtc = $Run.ProcessExitUtc.ToString('O')
        })

    $jobWait = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $current = @(Get-ScenarioTrackingJobProcessIds -Job $Run.TrackingJob)
        if ($current.Count -eq 0) {
            break
        }
        if ($jobWait.Elapsed.TotalMinutes -ge 10) {
            throw "Job '$($Run.TrackingJob.Name)' for '$($Run.RunId)' remained nonempty for ten minutes: $($current -join ',')."
        }
        Start-Sleep -Milliseconds 100
    }
    $Run.JobEmptyUtc = [DateTimeOffset]::UtcNow
    $Run.Quiescent = $true
    Add-SimpleEvent `
        -Event 'job-empty' `
        -Run $Run `
        -Data ([ordered]@{
            JobName = $Run.TrackingJob.Name
            ActiveProcessCount = 0
        })

    if (-not $Run.StdoutTask.Wait([TimeSpan]::FromMinutes(5)) -or
        -not $Run.StderrTask.Wait([TimeSpan]::FromMinutes(5))) {
        throw "Output streams for '$($Run.RunId)' did not drain within five minutes after the Job Object became empty."
    }
    [IO.File]::WriteAllText(
        $Run.Stdout,
        $Run.StdoutTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $Run.Stderr,
        $Run.StderrTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
    $Run.StreamDrainedUtc = [DateTimeOffset]::UtcNow
    Add-SimpleEvent `
        -Event 'stream-drained' `
        -Run $Run `
        -Data ([ordered]@{
            StdoutBytes = (Get-Item -LiteralPath $Run.Stdout).Length
            StderrBytes = (Get-Item -LiteralPath $Run.Stderr).Length
        })

    $Run.TrackingJob.Dispose()
    $Run.Process.Dispose()
    $Run.Completed = $true
    Add-SimpleEvent `
        -Event 'completion' `
        -Run $Run `
        -Data ([ordered]@{
            ExitCode = $Run.ExitCode
            Quiescent = $Run.Quiescent
            Binlog = $Run.Binlog
        })
    return $true
}

function Get-SimpleLiveTrace {
    $files = @(Get-TraceFiles -DebugPath $debugPath)
    if ($files.Count -eq 0) {
        return $null
    }
    if ($files.Count -ne 1) {
        throw "Found $($files.Count) Coordinator timelines; expected exactly one."
    }
    return ConvertFrom-CoordinatorTrace `
        -TracePaths $files `
        -RunRecords @(
            $script:allRuns |
            ForEach-Object { ConvertTo-SimpleRunRecord -Run $_ }
        ) `
        -Budget 16 `
        -StrictParsing
}

function Get-SimpleInjectionState {
    param(
        [Parameter(Mandatory)]
        [object]$Trace
    )

    $normalIds = @(
        $script:allRuns |
        Where-Object Kind -eq normal |
        Select-Object -ExpandProperty RunId
    )
    $active = @(
        $Trace.RootStates |
        Where-Object {
            $_.State -eq 'Active' -and
            $normalIds -contains $_.RunId
        }
    )
    $waiting = @(
        $Trace.RootStates |
        Where-Object {
            $_.State -eq 'Queued' -and
            $normalIds -contains $_.RunId
        }
    )
    [pscustomobject][ordered]@{
        Valid = $Trace.Consistent -and
            $active.Count -ge 1 -and
            $waiting.Count -ge 1
        ActiveNormalCount = $active.Count
        WaitingNormalCount = $waiting.Count
        ActiveNormalRunIds =
            @($active | Select-Object -ExpandProperty RunId)
        WaitingNormalRunIds =
            @($waiting | Select-Object -ExpandProperty RunId)
        QueueDepth = [int]$Trace.FinalQueueDepth
        ActiveBuilds = [int]$Trace.FinalActiveBuilds
        AllocatedNodes = [int]$Trace.FinalAllocatedNodes
    }
}

function Write-NewGrantEvents {
    param([Parameter(Mandatory)][object]$Trace)

    foreach ($run in $script:allRuns | Where-Object { -not $_.GrantEventWritten }) {
        $state =
            $Trace.RootStates |
            Where-Object RunId -eq $run.RunId |
            Select-Object -First 1
        if ($null -eq $state -or $null -eq $state.GrantedUtc) {
            continue
        }
        Add-SimpleEvent `
            -Event 'grant' `
            -Run $run `
            -Data ([ordered]@{
                Source = 'coordinator-trace'
                GrantedUtc = $state.GrantedUtc
                GrantedNodes = $state.GrantedNodes
                Priority = $state.Priority
            })
        $run.GrantEventWritten = $true
    }
}

function Start-SimpleCoordinator {
    $coordinatorDll = Join-Path $bootstrap.SdkRoot 'MSBuild.Coordinator.dll'
    $environment = New-ConditionEnvironment `
        -Condition $Condition `
        -PipeName $script:pipeName `
        -DotNetRoot $bootstrap.Root `
        -EnableDebugTrace `
        -DebugPath $debugPath
    $environment['MSBUILDCOORDINATORSHUTDOWNTIMEOUT'] = '3600000'
    $startInfo = [Diagnostics.ProcessStartInfo]::new($bootstrap.DotNetPath)
    $startInfo.ArgumentList.Add($coordinatorDll)
    $startInfo.WorkingDirectory = $bootstrap.SdkRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($item in $environment.GetEnumerator()) {
        if ($null -eq $item.Value) {
            [void]$startInfo.Environment.Remove([string]$item.Key)
        }
        else {
            $startInfo.Environment[[string]$item.Key] = [string]$item.Value
        }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Coordinator process did not start.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $readyTimer = [Diagnostics.Stopwatch]::StartNew()
    $traceFile = $null
    while ($readyTimer.Elapsed.TotalSeconds -lt 30) {
        if ($process.HasExited) {
            throw "Coordinator exited during startup with code $($process.ExitCode)."
        }
        $files = @(Get-TraceFiles -DebugPath $debugPath)
        if ($files.Count -gt 1) {
            throw "Coordinator startup produced $($files.Count) server timelines."
        }
        if ($files.Count -eq 1) {
            $lines = @(Read-CoordinatorTraceSnapshot -Path $files[0])
            if (@($lines | Where-Object { $_ -like '*CoordinatorServer: Accept loop started*' }).Count -gt 0) {
                $traceFile = $files[0]
                break
            }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $traceFile) {
        throw 'Coordinator did not become ready within 30 seconds.'
    }
    $expectedTraceName = "MSBuild_CoordinatorTrace_PID_$($process.Id).txt"
    if ([IO.Path]::GetFileName($traceFile) -ne $expectedTraceName) {
        throw "Coordinator timeline '$traceFile' does not match explicit PID $($process.Id)."
    }
    [pscustomobject][ordered]@{
        Process = $process
        ProcessId = $process.Id
        ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('O')
        TraceFile = $traceFile
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
        Stdout = Join-Path $ScenarioRoot 'coordinator.stdout.log'
        Stderr = Join-Path $ScenarioRoot 'coordinator.stderr.log'
    }
}

function Stop-SimpleCoordinator {
    param([Parameter(Mandatory)][object]$Coordinator)

    Add-SimpleEvent `
        -Event 'stop' `
        -Run $null `
        -Data ([ordered]@{
            Target = 'coordinator'
            CoordinatorProcessId = $Coordinator.ProcessId
        })
    if (-not $Coordinator.Process.HasExited) {
        $Coordinator.Process.Kill($true)
        if (-not $Coordinator.Process.WaitForExit(30000)) {
            throw "Coordinator PID $($Coordinator.ProcessId) did not stop."
        }
    }
    if (-not $Coordinator.StdoutTask.Wait([TimeSpan]::FromSeconds(30)) -or
        -not $Coordinator.StderrTask.Wait([TimeSpan]::FromSeconds(30))) {
        throw 'Coordinator streams did not drain after stop.'
    }
    [IO.File]::WriteAllText(
        $Coordinator.Stdout,
        $Coordinator.StdoutTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $Coordinator.Stderr,
        $Coordinator.StderrTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
    $exitCode = $Coordinator.Process.ExitCode
    $Coordinator.Process.Dispose()
    return $exitCode
}

$script:pipeName =
    "cvf-simple-$RepositoryName-$Condition-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 10))"
$metadata = [pscustomobject][ordered]@{
    SchemaVersion = 1
    StartedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Repository = $RepositoryName
    RepositoryCommit = $repositoryDefinition.Commit
    Condition = $Condition
    WorkerCount = $WorkerCount
    WindowSeconds = $WindowSeconds
    InjectionOffsetSeconds = $InjectionOffsetSeconds
    Pilot = [bool]$Pilot
    SkipOnsetGate = [bool]$SkipOnsetGate
    PipeName = $script:pipeName
    BootstrapRoot = $bootstrap.Root
    BootstrapCommit = $bootstrap.ExpectedCommit
    BootstrapProductVersion = $bootstrap.ProductVersion
    BootstrapMSBuildSha256 = $bootstrap.MSBuildDllSha256
    BootstrapDotNetSha256 = $bootstrap.DotNetSha256
    SelectedWorktrees = @($selectedWorktrees.Name)
}
Write-SimpleJson `
    -Path (Join-Path $ScenarioRoot 'scenario-metadata.json') `
    -Value $metadata

$script:allRuns = [Collections.Generic.List[object]]::new()
$generation = [int[]]::new($WorkerCount + 1)
$samples = [Collections.Generic.List[object]]::new()
$coordinator = $null
$monitor = $null
$measurementStartUtc = $null
$measurementEndUtc = $null
$injectionDueUtc = $null
$injectionState = $null
$probe = $null
$initialCompletionCount = 0
$scenarioStartedUtc = [DateTimeOffset]::UtcNow
$stopSubmissions = $false
$lastTraceCheck = [DateTimeOffset]::MinValue
$nextSample = [DateTimeOffset]::MaxValue
$onsetDeadline = $scenarioStartedUtc.AddSeconds($OnsetTimeoutSeconds)
$executionError = $null

try {
    $coordinator = Start-SimpleCoordinator
    Write-SimpleJson `
        -Path (Join-Path $ScenarioRoot 'coordinator-identity.json') `
        -Value ([pscustomobject][ordered]@{
            ProcessId = $coordinator.ProcessId
            ProcessStartUtc = $coordinator.ProcessStartUtc
            TraceFile = $coordinator.TraceFile
            PipeName = $script:pipeName
            BootstrapRoot = $bootstrap.Root
        })
    $monitor = Start-ScenarioMonitor -MonitorRoot $monitorRoot

    foreach ($worker in 1..$WorkerCount) {
        $worktree = Get-SimpleWorktree -Name "normal$worker"
        [void](Touch-CampaignInput `
            -Worktree $worktree `
            -RelativePath $preparedRepository.TouchPath)
        $generation[$worker]++
        $run = Start-SimpleBuild `
            -RunId "normal$worker-g$($generation[$worker])" `
            -Kind normal `
            -Worker $worker `
            -Generation $generation[$worker] `
            -Worktree $worktree
        $script:allRuns.Add($run)
    }

    while (-not $stopSubmissions) {
        foreach ($run in @($script:allRuns | Where-Object { -not $_.Completed })) {
            if (-not (Complete-SimpleBuild -Run $run)) {
                continue
            }
            if ($run.Kind -eq 'normal' -and $null -eq $measurementStartUtc) {
                $initialCompletionCount++
            }
            if ($run.ExitCode -ne 0) {
                throw "Build '$($run.RunId)' failed with exit code $($run.ExitCode)."
            }
            $now = [DateTimeOffset]::UtcNow
            if ($run.Kind -eq 'normal' -and
                ($null -eq $measurementEndUtc -or $now -lt $measurementEndUtc)) {
                $worktree = Get-SimpleWorktree -Name "normal$($run.Worker)"
                [void](Touch-CampaignInput `
                    -Worktree $worktree `
                    -RelativePath $preparedRepository.TouchPath)
                $generation[$run.Worker]++
                $replacement = Start-SimpleBuild `
                    -RunId "normal$($run.Worker)-g$($generation[$run.Worker])" `
                    -Kind normal `
                    -Worker $run.Worker `
                    -Generation $generation[$run.Worker] `
                    -Worktree $worktree
                $script:allRuns.Add($replacement)
                Add-SimpleEvent `
                    -Event 'relaunch' `
                    -Run $replacement `
                    -Data ([ordered]@{ ReplacedRunId = $run.RunId })
            }
        }
        $now = [DateTimeOffset]::UtcNow
        $trace = $null
        if (($now - $lastTraceCheck).TotalSeconds -ge 1) {
            $trace = Get-SimpleLiveTrace
            $lastTraceCheck = $now
            if ($null -ne $trace) {
                Write-NewGrantEvents -Trace $trace
            }
        }
        if ($null -eq $measurementStartUtc) {
            $onsetAccepted = $false
            $onsetEvidence = $null
            if ($SkipOnsetGate) {
                $onsetAccepted =
                    $initialCompletionCount -ge 1 -and
                    $null -ne $trace -and
                    $trace.FinalActiveBuilds -ge 1
            }
            elseif ($null -ne $trace) {
                $onsetEvidence = Test-SustainedWindowOnset `
                    -Trace $trace `
                    -RunRecords @(
                        $script:allRuns |
                        ForEach-Object { ConvertTo-SimpleRunRecord -Run $_ }
                    ) `
                    -InitialNormalCompletionCount $initialCompletionCount `
                    -NowUtc $now
                $onsetAccepted = $onsetEvidence.Accepted
            }
            if ($onsetAccepted) {
                $measurementStartUtc = $now.ToUniversalTime()
                $measurementEndUtc =
                    $measurementStartUtc.AddSeconds($WindowSeconds)
                $injectionDueUtc =
                    $measurementStartUtc.AddSeconds($InjectionOffsetSeconds)
                $nextSample = $measurementStartUtc
                Add-SimpleEvent `
                    -Event 'measurement-start' `
                    -Run $null `
                    -Data ([ordered]@{
                        MeasurementStartUtc = $measurementStartUtc.ToString('O')
                        MeasurementEndUtc = $measurementEndUtc.ToString('O')
                        OnsetEvidence = $onsetEvidence
                    })
            }
            elseif ($now -ge $onsetDeadline) {
                throw "Steady queue onset did not occur within $OnsetTimeoutSeconds seconds."
            }
        }

        if ($null -ne $measurementStartUtc -and
            $null -ne $trace -and
            $now -ge $nextSample -and
            $now -lt $measurementEndUtc) {
            $state = Get-SimpleInjectionState -Trace $trace
            $samples.Add([pscustomobject][ordered]@{
                TimestampUtc = $now.ToString('O')
                QueueDepth = $state.QueueDepth
                ActiveBuilds = $state.ActiveBuilds
                AllocatedNodes = $state.AllocatedNodes
                ActiveNormalCount = $state.ActiveNormalCount
                WaitingNormalCount = $state.WaitingNormalCount
            })
            $nextSample = $now.AddSeconds(1)
        }

        if ($null -ne $measurementStartUtc -and
            $null -eq $probe -and
            $now -ge $injectionDueUtc -and
            $null -ne $trace) {
            $injectionState = Get-SimpleInjectionState -Trace $trace
            $worktree = Get-SimpleWorktree -Name injected
            [void](Touch-CampaignInput `
                -Worktree $worktree `
                -RelativePath $preparedRepository.TouchPath)
            $probe = Start-SimpleBuild `
                -RunId 'injected-g1' `
                -Kind probe `
                -Worker 0 `
                -Generation 1 `
                -Worktree $worktree `
                -Injected
            $script:allRuns.Add($probe)
            Add-SimpleEvent `
                -Event 'injection' `
                -Run $probe `
                -Data ([ordered]@{
                    ScheduledUtc = $injectionDueUtc.ToString('O')
                    ActualOffsetSeconds =
                        ($probe.ProcessStartUtc - $measurementStartUtc).TotalSeconds
                    State = $injectionState
                })
        }

        if ($null -ne $measurementEndUtc -and $now -ge $measurementEndUtc) {
            $stopSubmissions = $true
            Add-SimpleEvent `
                -Event 'stop' `
                -Run $null `
                -Data ([ordered]@{
                    Target = 'normal-submissions'
                    MeasurementEndUtc = $measurementEndUtc.ToString('O')
                })
            break
        }
        Start-Sleep -Milliseconds 100
    }

    $drainTimer = [Diagnostics.Stopwatch]::StartNew()
    while (@($script:allRuns | Where-Object { -not $_.Completed }).Count -gt 0) {
        foreach ($run in @($script:allRuns | Where-Object { -not $_.Completed })) {
            [void](Complete-SimpleBuild -Run $run)
        }
        if ($drainTimer.Elapsed.TotalMinutes -ge 10) {
            throw 'Scenario drain exceeded ten minutes.'
        }
        Start-Sleep -Milliseconds 100
    }
    Add-SimpleEvent `
        -Event 'drain' `
        -Run $null `
        -Data ([ordered]@{
            Complete = $true
            RunCount = $script:allRuns.Count
        })
}
catch {
    $executionError = $_.Exception.ToString()
}
finally {
    if ($null -ne $executionError) {
        foreach ($run in @($script:allRuns | Where-Object { -not $_.Completed })) {
            try {
                if (-not $run.TrackingJob.IsClosed) {
                    Stop-ScenarioTrackingJob -Job $run.TrackingJob
                }
                $run.Process.WaitForExit()
                [void](Complete-SimpleBuild -Run $run)
            }
            catch {
                $executionError += "`nWorker cleanup for '$($run.RunId)': $($_.Exception)"
                try {
                    $run.TrackingJob.Dispose()
                    $run.Process.Dispose()
                }
                catch {
                }
            }
        }
    }
    if ($null -ne $coordinator) {
        try {
            [void](Stop-SimpleCoordinator -Coordinator $coordinator)
        }
        catch {
            if ($null -eq $executionError) {
                $executionError = $_.Exception.ToString()
            }
            else {
                $executionError += "`nCoordinator cleanup: $($_.Exception)"
            }
        }
    }
    if ($null -ne $monitor) {
        try {
            Stop-ScenarioMonitor -Monitor $monitor
        }
        catch {
            if ($null -eq $executionError) {
                $executionError = $_.Exception.ToString()
            }
            else {
                $executionError += "`nMonitor cleanup: $($_.Exception)"
            }
        }
    }
}

$script:eventWriter.Dispose()
$errors = [Collections.Generic.List[string]]::new()
if ($null -ne $executionError) {
    $errors.Add($executionError)
}
$runRecords = @(
    $script:allRuns |
    ForEach-Object { ConvertTo-SimpleRunRecord -Run $_ }
)
Write-SimpleJson `
    -Path (Join-Path $ScenarioRoot 'runs.json') `
    -Value $runRecords
foreach ($run in $runRecords) {
    if ($run.ExitCode -ne 0 -or
        -not $run.Quiescent -or
        $null -eq $run.JobEmptyUtc -or
        $null -eq $run.StreamDrainedUtc) {
        $errors.Add("Run '$($run.RunId)' did not exit, empty its job, and drain streams cleanly.")
    }
    if (-not (Test-Path -LiteralPath $run.Binlog -PathType Leaf) -or
        (Get-Item -LiteralPath $run.Binlog).Length -eq 0) {
        $errors.Add("Run '$($run.RunId)' has no nonempty binlog.")
    }
}

$trace = $null
$replays = @()
$grantMetrics = [Collections.Generic.List[object]]::new()
$traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
if ($traceFiles.Count -ne 1) {
    $errors.Add("Expected one Coordinator timeline; found $($traceFiles.Count).")
}
elseif ($runRecords.Count -gt 0 -and
    @($runRecords | Where-Object { -not (Test-Path -LiteralPath $_.Binlog) }).Count -eq 0) {
    try {
        $replays = @(
            & (Join-Path $toolingRoot 'Invoke-GrantReplay.ps1') `
                -BootstrapRoot $bootstrap.Root `
                -Binlog @($runRecords.Binlog) `
                -OutputPath (Join-Path $ScenarioRoot 'grant-replay.json') `
                -WorkRoot (Join-Path $ScenarioRoot '_replay')
        )
        $trace = ConvertFrom-CoordinatorTrace `
            -TracePaths $traceFiles `
            -RunRecords $runRecords `
            -Budget 16 `
            -RequireEmptyFinalState `
            -StrictParsing
        [void](Export-CoordinatorTraceResult `
            -Trace $trace `
            -DestinationRoot (Join-Path $ScenarioRoot 'parsed-trace'))
        if (-not $trace.Consistent) {
            foreach ($message in $trace.Errors) {
                $errors.Add([string]$message)
            }
        }
        foreach ($run in $runRecords) {
            $replay =
                $replays |
                Where-Object {
                    [IO.Path]::GetFullPath($_.Path) -eq
                        [IO.Path]::GetFullPath($run.Binlog)
                } |
                Select-Object -First 1
            $state =
                $trace.RootStates |
                Where-Object RunId -eq $run.RunId |
                Select-Object -First 1
            if ($null -eq $replay -or @($replay.Grants).Count -ne 1) {
                $errors.Add("Run '$($run.RunId)' does not have one replayed grant.")
                continue
            }
            if ($null -eq $state -or $null -eq $state.GrantedUtc) {
                $errors.Add("Run '$($run.RunId)' does not have a mapped trace grant.")
                continue
            }
            $grant = Get-GrantMetricsForRun `
                -Run $run `
                -Replay $replay `
                -TraceState $state
            $grantMetrics.Add($grant)
            if ($grant.GrantedNodes -ne $state.GrantedNodes -or
                $grant.TraceAndBinlogGrantDeltaSeconds -gt 5) {
                $errors.Add("Run '$($run.RunId)' trace/binlog grant evidence differs.")
            }
        }
    }
    catch {
        $errors.Add("Trace or binlog replay failed: $($_.Exception)")
    }
}

$telemetry = $null
if ($null -ne $monitor) {
    try {
        $telemetry = Test-TelemetryContinuity `
            -MonitorRoot $monitorRoot `
            -ReadyUtc $monitor.ReadyObservedUtc `
            -StopUtc $monitor.StopRequestedUtc
        foreach ($message in $telemetry.Errors) {
            $errors.Add([string]$message)
        }
    }
    catch {
        $errors.Add("Telemetry validation failed: $($_.Exception)")
    }
}

$metrics = [ordered]@{
    SchemaVersion = 1
    Repository = $RepositoryName
    Condition = $Condition
    WorkerCount = $WorkerCount
    Pilot = [bool]$Pilot
    RunCount = $runRecords.Count
    FailedRunCount = @($runRecords | Where-Object ExitCode -ne 0).Count
    AllJobsEmpty = @($runRecords | Where-Object Quiescent -ne $true).Count -eq 0
    AllStreamsDrained =
        @($runRecords | Where-Object { $null -eq $_.StreamDrainedUtc }).Count -eq 0
    CoordinatorTimelineCount = $traceFiles.Count
    ActualGrantCount = $grantMetrics.Count
    Grants = $grantMetrics.ToArray()
}

if ($null -ne $trace -and
    $null -ne $measurementStartUtc -and
    $null -ne $measurementEndUtc -and
    $null -ne $probe) {
    $window = Get-TraceWindowMetrics `
        -Timeline $trace.Timeline `
        -StartUtc $measurementStartUtc `
        -EndUtc $measurementEndUtc `
        -Budget 16 `
        -ReservedNodes 0
    $sampleSummary =
        Get-SustainedWindowSampleSummary -Samples $samples.ToArray()
    $completedNormals = @(
        $runRecords |
        Where-Object {
            $_.Kind -eq 'normal' -and
            $_.ExitCode -eq 0 -and
            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -ge
                $measurementStartUtc -and
            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -lt
                $measurementEndUtc
        }
    )
    $preInjection = @(
        $completedNormals |
        Where-Object {
            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -lt
                $injectionDueUtc
        }
    )
    $postInjection = @(
        $completedNormals |
        Where-Object {
            (ConvertTo-UtcDateTimeOffset -Value $_.ProcessExitUtc) -ge
                $injectionDueUtc
        }
    )
    $resource = Get-ScenarioResourceMetrics `
        -MonitorRoot $monitorRoot `
        -RunRecords $runRecords `
        -WindowStartUtc $measurementStartUtc `
        -WindowEndUtc $measurementEndUtc
    $probeGrant =
        $grantMetrics |
        Where-Object RunId -eq 'injected-g1' |
        Select-Object -First 1
    $policy = Test-SustainedGrantPolicyEvidence `
        -Condition $Condition `
        -RunRecords $runRecords `
        -GrantMetrics $grantMetrics.ToArray() `
        -Trace $trace `
        -MeasurementStartUtc $measurementStartUtc
    foreach ($message in $policy.Errors) {
        $errors.Add([string]$message)
    }

    $metrics['MeasurementStartUtc'] = $measurementStartUtc.ToString('O')
    $metrics['MeasurementEndUtc'] = $measurementEndUtc.ToString('O')
    $metrics['MeasuredWindowSeconds'] = $window.WindowSeconds
    $metrics['InjectionActualOffsetSeconds'] =
        ($probe.ProcessStartUtc - $measurementStartUtc).TotalSeconds
    $metrics['InjectionState'] = $injectionState
    $metrics['MeasuredNormalCompletionCount'] = $completedNormals.Count
    $metrics['PreInjectionNormalCompletionCount'] = $preInjection.Count
    $metrics['PostInjectionNormalCompletionCount'] = $postInjection.Count
    $metrics['NormalThroughputPerMinute'] =
        $completedNormals.Count / ($window.WindowSeconds / 60.0)
    $metrics['OverallNormalThroughputPerSecond'] =
        $completedNormals.Count / $window.WindowSeconds
    $metrics['PreInjectionNormalThroughputPerSecond'] =
        $preInjection.Count / $InjectionOffsetSeconds
    $metrics['PostInjectionNormalThroughputPerSecond'] =
        $postInjection.Count /
        ($WindowSeconds - $InjectionOffsetSeconds)
    $metrics['AverageCompletedNormalLatencySeconds'] =
        if ($completedNormals.Count -eq 0) {
            $null
        }
        else {
            ($completedNormals |
                Measure-Object DurationSeconds -Average).Average
        }
    $metrics['WorkerRequestToGrantSeconds'] =
        @($grantMetrics | Where-Object RunId -ne 'injected-g1' |
            Select-Object -ExpandProperty RequestToGrantSeconds)
    $metrics['WorkerRequestToCompletionSeconds'] =
        @($grantMetrics | Where-Object RunId -ne 'injected-g1' |
            Select-Object -ExpandProperty RequestToCompletionSeconds)
    $metrics['InjectedRequestToGrantSeconds'] =
        if ($null -eq $probeGrant) { $null } else { $probeGrant.RequestToGrantSeconds }
    $metrics['InjectedRequestToCompletionSeconds'] =
        if ($null -eq $probeGrant) { $null } else { $probeGrant.RequestToCompletionSeconds }
    $metrics['QueueDepthP50'] = $window.QueueDepthP50
    $metrics['QueueDepthP95'] = $window.QueueDepthP95
    $metrics['QueueDepthMaximum'] = $window.QueueDepthMaximum
    $metrics['QueueNonemptyTimeFraction'] = $window.QueueNonemptyFraction
    $metrics['QueueNonemptySampleFraction'] =
        $sampleSummary.QueueNonemptySampleFraction
    $metrics['ActiveAndWaitingSampleCount'] =
        $sampleSummary.ActiveAndWaitingSampleCount
    $metrics['AllocatedTimeline'] =
        @($window.Segments | Select-Object StartUtc,EndUtc,DurationSeconds,
            QueueDepth,ActiveBuilds,AllocatedNodes)
    $metrics['AverageAllocatedNodes'] =
        16.0 - ($window.UnusedNodeSeconds / $window.WindowSeconds)
    $metrics['AverageUnusedNodes'] =
        $window.UnusedNodeSeconds / $window.WindowSeconds
    $metrics['UnusedNodeSeconds'] = $window.UnusedNodeSeconds
    $metrics['SteadyResource'] = $resource
    $metrics['GrantPolicyEvidence'] = $policy

    if (-not $SkipOnsetGate -and
        ($window.QueueNonemptyFraction -lt 0.90 -or
            $sampleSummary.QueueNonemptySampleFraction -lt 0.90)) {
        $errors.Add(
            "Queue nonempty fractions were $($window.QueueNonemptyFraction)/$($sampleSummary.QueueNonemptySampleFraction); both must be at least 0.90.")
    }
    if (-not $SkipOnsetGate -and
        ($null -eq $injectionState -or -not $injectionState.Valid)) {
        $errors.Add('Injection did not observe active and waiting Normal work.')
    }
    if ([Math]::Abs(
        [double]$metrics['InjectionActualOffsetSeconds'] -
            $InjectionOffsetSeconds) -gt 2) {
        $errors.Add('Probe injection missed its fixed offset by more than two seconds.')
    }
}
else {
    $errors.Add('Scenario did not produce a complete measurement window and probe.')
}

foreach ($worktree in $selectedWorktrees) {
    try {
        [void](Get-GitIdentity `
            -Root $worktree.Path `
            -ExpectedCommit $repositoryDefinition.Commit `
            -RequireClean)
    }
    catch {
        $errors.Add($_.Exception.Message)
    }
}

$metrics['Errors'] = $errors.ToArray()
$metrics['Valid'] = $errors.Count -eq 0
Write-SimpleJson `
    -Path (Join-Path $ScenarioRoot 'scenario-metrics.json') `
    -Value ([pscustomobject]$metrics) `
    -Depth 20
$validation = [pscustomobject][ordered]@{
    Valid = $errors.Count -eq 0
    Disposition = if ($errors.Count -eq 0) {
        'Valid'
    }
    else {
        'Invalid'
    }
    Repository = $RepositoryName
    Condition = $Condition
    WorkerCount = $WorkerCount
    Errors = $errors.ToArray()
    ScenarioRoot = $ScenarioRoot
}
Write-SimpleJson `
    -Path (Join-Path $ScenarioRoot 'scenario-validation.json') `
    -Value $validation

if (-not $validation.Valid) {
    throw "Scenario failed: $($validation.Errors -join '; ')"
}
$validation
