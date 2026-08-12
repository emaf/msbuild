Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
. (Join-Path $PSScriptRoot 'CoordinatorTrace.ps1')

function Start-ScenarioMonitor {
    param(
        [Parameter(Mandatory)]
        [string]$MonitorRoot
    )

    $stopFile = Join-Path $MonitorRoot 'stop'
    $readyFile = Join-Path $MonitorRoot 'ready'
    New-Item -ItemType Directory -Force -Path $MonitorRoot | Out-Null
    Remove-Item -LiteralPath $stopFile,$readyFile -Force -ErrorAction SilentlyContinue
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'Monitor-Campaign.ps1'),
        '-OutputRoot', $MonitorRoot,
        '-StopFile', $stopFile,
        '-ReadyFile', $readyFile,
        '-SampleIntervalSeconds', '1',
        '-ProcessIntervalSeconds', '5',
        '-ProbeIntervalSeconds', '5'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyFile)) {
        if ($process.HasExited) {
            throw "Resource monitor exited before readiness with code $($process.ExitCode)."
        }
        if ($timer.Elapsed.TotalSeconds -gt 30) {
            Stop-Process -Id $process.Id
            throw 'Resource monitor did not become ready within 30 seconds.'
        }
        Start-Sleep -Milliseconds 100
    }
    [pscustomobject]@{
        Process = $process
        StopFile = $stopFile
        ReadyFile = $readyFile
    }
}

function Stop-ScenarioMonitor {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Monitor
    )

    New-Item -ItemType File -Force -Path $Monitor.StopFile | Out-Null
    if (-not $Monitor.Process.WaitForExit(30000)) {
        Stop-Process -Id $Monitor.Process.Id
        [void]$Monitor.Process.WaitForExit(5000)
    }
    $exitCode = $Monitor.Process.ExitCode
    $Monitor.Process.Dispose()
    if ($exitCode -ne 0) {
        throw "Resource monitor exited with code $exitCode."
    }
}

function ConvertTo-RunRecord {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    [pscustomobject][ordered]@{
        RunId = $Run.RunId
        Kind = $Run.Kind
        Worker = $Run.Worker
        Generation = $Run.Generation
        Priority = $Run.Priority
        Worktree = $Run.Worktree
        RootProcessId = $Run.RootProcessId
        ProcessStartUtc = $Run.ProcessStartUtc.ToString('O')
        ProcessExitUtc = if ($null -eq $Run.ProcessExitUtc) { $null } else { $Run.ProcessExitUtc.ToString('O') }
        StartOffsetSeconds = $Run.StartOffsetSeconds
        DurationSeconds = if ($null -eq $Run.ProcessExitUtc) {
            $null
        }
        else {
            ($Run.ProcessExitUtc - $Run.ProcessStartUtc).TotalSeconds
        }
        ExitCode = $Run.ExitCode
        Quiescent = $Run.Quiescent
        EnvironmentPath = $Run.EnvironmentPath
        Stdout = $Run.Stdout
        Stderr = $Run.Stderr
        Binlog = $Run.Binlog
        Command = $Run.Command
    }
}

function Start-ScenarioBuild {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Bootstrap,

        [Parameter(Mandatory)]
        [pscustomobject]$Repository,

        [Parameter(Mandatory)]
        [string]$Worktree,

        [Parameter(Mandatory)]
        [string]$Condition,

        [Parameter(Mandatory)]
        [string]$PipeName,

        [Parameter(Mandatory)]
        [string]$DebugPath,

        [Parameter(Mandatory)]
        [string]$ScenarioRoot,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [int]$Worker,

        [Parameter(Mandatory)]
        [int]$Generation,

        [Parameter(Mandatory)]
        [DateTime]$ScenarioStartedUtc,

        [switch]$Injected
    )

    $runRoot = Join-Path $ScenarioRoot "runs\$RunId"
    if (Test-Path -LiteralPath $runRoot) {
        throw "Run root '$runRoot' already exists."
    }
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $stdout = Join-Path $runRoot 'stdout.log'
    $stderr = Join-Path $runRoot 'stderr.log'
    $binlog = Join-Path $runRoot 'build.binlog'
    $environmentPath = Join-Path $runRoot 'environment.json'
    $environment = New-ConditionEnvironment `
        -Condition $Condition `
        -PipeName $PipeName `
        -DotNetRoot $Bootstrap.Root `
        -Injected:$Injected `
        -EnableDebugTrace `
        -DebugPath $DebugPath
    Assert-ConditionEnvironmentContract -Condition $Condition -Environment $environment -Injected:$Injected
    $environmentRecord = Get-EnvironmentContractRecord -Environment $environment
    Write-JsonAtomic -Path $environmentPath -Value $environmentRecord

    $arguments = New-BuildArguments `
        -MSBuildDllPath $Bootstrap.MSBuildDllPath `
        -BuildPath $Repository.BuildPath `
        -BinlogPath $binlog `
        -AdditionalArguments $Repository.AdditionalBuildArguments
    $startInfo = [Diagnostics.ProcessStartInfo]::new($Bootstrap.DotNetPath)
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
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $processStartUtc = $process.StartTime.ToUniversalTime()
    [pscustomobject][ordered]@{
        RunId = $RunId
        Kind = $Kind
        Worker = $Worker
        Generation = $Generation
        Priority = if ($Condition -eq 'FINAL-H' -and $Injected) { 'High' } else { 'Normal' }
        Injected = [bool]$Injected
        Worktree = $Worktree
        Process = $process
        RootProcessId = $process.Id
        ProcessStartUtc = $processStartUtc
        ProcessExitUtc = $null
        StartOffsetSeconds = ($processStartUtc - $ScenarioStartedUtc).TotalSeconds
        ExitCode = $null
        Quiescent = $null
        Completed = $false
        CompletionEventWritten = $false
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
        Stdout = $stdout
        Stderr = $stderr
        Binlog = $binlog
        EnvironmentPath = $environmentPath
        Command = [pscustomobject]@{
            FileName = $Bootstrap.DotNetPath
            Arguments = $arguments
            WorkingDirectory = $Worktree
        }
        DescendantIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
}

function Update-ScenarioProcessTrees {
    param(
        [Parameter(Mandatory)]
        [object[]]$Runs
    )

    $activeRuns = @($Runs | Where-Object { -not $_.Completed })
    if ($activeRuns.Count -eq 0) {
        return
    }
    $processes = @(Get-CimInstance Win32_Process)
    $children = @{}
    $byPid = @{}
    foreach ($process in $processes) {
        $processIdValue = [int]$process.ProcessId
        $byPid[$processIdValue] = $process
        $parent = [int]$process.ParentProcessId
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = [Collections.Generic.List[int]]::new()
        }
        $children[$parent].Add($processIdValue)
    }
    foreach ($run in $activeRuns) {
        $queue = [Collections.Generic.Queue[int]]::new()
        $seen = [Collections.Generic.HashSet[int]]::new()
        $queue.Enqueue($run.RootProcessId)
        [void]$seen.Add($run.RootProcessId)
        while ($queue.Count -gt 0) {
            $parent = $queue.Dequeue()
            if (-not $children.ContainsKey($parent)) {
                continue
            }
            foreach ($child in $children[$parent]) {
                if (-not $seen.Add($child)) {
                    continue
                }
                $queue.Enqueue($child)
                $process = $byPid[$child]
                if ($process.Name -eq 'MSBuild.Coordinator.exe') {
                    continue
                }
                $created = if ($null -eq $process.CreationDate) {
                    ''
                }
                else {
                    ([DateTime]$process.CreationDate).ToUniversalTime().ToString('O')
                }
                [void]$run.DescendantIdentities.Add("$child|$created")
            }
        }
    }
}

function Test-RunDescendantsExited {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    if ($Run.DescendantIdentities.Count -eq 0) {
        return $true
    }
    foreach ($identity in $Run.DescendantIdentities) {
        $parts = $identity -split '\|', 2
        try {
            $process = Get-Process -Id ([int]$parts[0]) -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($parts[1])) {
                return $false
            }
            $capturedStart = ([DateTime]$parts[1]).ToUniversalTime()
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $capturedStart).TotalSeconds) -lt 1) {
                return $false
            }
        }
        catch {
            # The exact PID/start identity no longer exists.
        }
    }
    return $true
}

function Complete-ExitedScenarioBuild {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run,

        [int]$QuiescenceTimeoutSeconds = 60
    )

    if ($Run.Completed -or -not $Run.Process.HasExited) {
        return $false
    }
    $Run.Process.WaitForExit()
    $Run.ProcessExitUtc = $Run.Process.ExitTime.ToUniversalTime()
    $Run.ExitCode = $Run.Process.ExitCode
    if (-not $Run.StdoutTask.Wait([TimeSpan]::FromSeconds($QuiescenceTimeoutSeconds)) -or
        -not $Run.StderrTask.Wait([TimeSpan]::FromSeconds($QuiescenceTimeoutSeconds))) {
        $Run.Quiescent = $false
    }
    else {
        [IO.File]::WriteAllText(
            $Run.Stdout,
            $Run.StdoutTask.GetAwaiter().GetResult(),
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            $Run.Stderr,
            $Run.StderrTask.GetAwaiter().GetResult(),
            [Text.UTF8Encoding]::new($false))
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.Elapsed.TotalSeconds -le $QuiescenceTimeoutSeconds -and
            -not (Test-RunDescendantsExited -Run $Run)) {
            Start-Sleep -Milliseconds 100
        }
        $Run.Quiescent = Test-RunDescendantsExited -Run $Run
    }
    $Run.Completed = $true
    $Run.Process.Dispose()
    return $true
}

function Wait-ScenarioBuilds {
    param(
        [Parameter(Mandatory)]
        [object[]]$Runs,

        [int]$TimeoutMinutes = 10
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastProcessTreeSampleUtc = [DateTime]::MinValue
    while (@($Runs | Where-Object { -not $_.Completed }).Count -gt 0) {
        if (([DateTime]::UtcNow - $lastProcessTreeSampleUtc).TotalSeconds -ge 5) {
            Update-ScenarioProcessTrees -Runs $Runs
            $lastProcessTreeSampleUtc = [DateTime]::UtcNow
        }
        foreach ($run in @($Runs | Where-Object { -not $_.Completed })) {
            [void](Complete-ExitedScenarioBuild -Run $run)
        }
        if ($timer.Elapsed.TotalMinutes -gt $TimeoutMinutes) {
            throw "Timed out draining scenario builds after $TimeoutMinutes minutes."
        }
        Start-Sleep -Milliseconds 100
    }
}

function Get-ScenarioResourceMetrics {
    param(
        [Parameter(Mandatory)]
        [string]$MonitorRoot,

        [Parameter(Mandatory)]
        [object[]]$RunRecords,

        [DateTime]$WindowStartUtc,

        [DateTime]$WindowEndUtc
    )

    $systemRows = @(Import-Csv -LiteralPath (Join-Path $MonitorRoot 'system.csv'))
    if ($PSBoundParameters.ContainsKey('WindowStartUtc')) {
        $systemRows = @(
            $systemRows |
                Where-Object {
                    $timestamp = ([DateTime]$_.timestampUtc).ToUniversalTime()
                    $timestamp -ge $WindowStartUtc.ToUniversalTime() -and
                        $timestamp -le $WindowEndUtc.ToUniversalTime()
                }
        )
    }
    $processRows = @(Import-Csv -LiteralPath (Join-Path $MonitorRoot 'processes.csv'))
    $rootWindows = @(
        foreach ($run in $RunRecords) {
            [pscustomobject]@{
                ProcessId = [int]$run.RootProcessId
                StartUtc = ([DateTime]$run.ProcessStartUtc).ToUniversalTime()
                ExitUtc = if ([string]::IsNullOrWhiteSpace([string]$run.ProcessExitUtc)) {
                    [DateTime]::MaxValue
                }
                else {
                    ([DateTime]$run.ProcessExitUtc).ToUniversalTime()
                }
            }
        }
    )
    $peakWorkingSet = [int64]0
    $peakPrivate = [int64]0
    $peakCount = 0
    $peakNoiseWorkingSet = [int64]0
    $cpuByIdentity = @{}
    $noiseCpuByIdentity = @{}
    $foreignConflictingIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($snapshot in $processRows | Group-Object timestampUtc) {
        $timestamp = ([DateTime]$snapshot.Name).ToUniversalTime()
        if ($PSBoundParameters.ContainsKey('WindowStartUtc') -and
            ($timestamp -lt $WindowStartUtc.ToUniversalTime() -or $timestamp -gt $WindowEndUtc.ToUniversalTime())) {
            continue
        }
        $byPid = @{}
        foreach ($row in $snapshot.Group) {
            $byPid[[int]$row.processId] = $row
        }
        $descendantIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($row in $snapshot.Group) {
            $candidate = [int]$row.processId
            $visited = [Collections.Generic.HashSet[int]]::new()
            while ($visited.Add($candidate)) {
                $root = $rootWindows |
                    Where-Object {
                        $_.ProcessId -eq $candidate -and
                            $timestamp -ge $_.StartUtc.AddSeconds(-2) -and
                            $timestamp -le $_.ExitUtc.AddSeconds(2)
                    } |
                    Select-Object -First 1
                if ($null -ne $root) {
                    [void]$descendantIds.Add([int]$row.processId)
                    break
                }
                if (-not $byPid.ContainsKey($candidate)) {
                    break
                }
                $entry = $byPid[$candidate]
                $candidate = [int]$entry.parentProcessId
            }
        }
        $workingSet = [int64]0
        $private = [int64]0
        foreach ($row in $snapshot.Group) {
            $processIdValue = [int]$row.processId
            $identity = "$processIdValue|$($row.processStartUtc)"
            if ($descendantIds.Contains($processIdValue)) {
                $workingSet += [int64]$row.workingSetBytes
                $private += [int64]$row.privateBytes
                $cpu = [double]$row.cpuSeconds
                if (-not $cpuByIdentity.ContainsKey($identity)) {
                    $cpuByIdentity[$identity] = [pscustomobject]@{ Minimum = $cpu; Maximum = $cpu }
                }
                else {
                    $cpuByIdentity[$identity].Minimum = [Math]::Min($cpuByIdentity[$identity].Minimum, $cpu)
                    $cpuByIdentity[$identity].Maximum = [Math]::Max($cpuByIdentity[$identity].Maximum, $cpu)
                }
            }
            elseif ($row.name -in @('MSBuild.exe', 'csc.exe', 'vbc.exe', 'VBCSCompiler.exe') -or
                ($row.name -eq 'dotnet.exe' -and $row.commandLine -match 'MSBuild\.dll')) {
                [void]$foreignConflictingIdentities.Add($identity)
            }
            if ($row.category -eq 'external-noise-known') {
                $noiseCpu = [double]$row.cpuSeconds
                if (-not $noiseCpuByIdentity.ContainsKey($identity)) {
                    $noiseCpuByIdentity[$identity] = [pscustomobject]@{ Minimum = $noiseCpu; Maximum = $noiseCpu }
                }
                else {
                    $noiseCpuByIdentity[$identity].Minimum = [Math]::Min($noiseCpuByIdentity[$identity].Minimum, $noiseCpu)
                    $noiseCpuByIdentity[$identity].Maximum = [Math]::Max($noiseCpuByIdentity[$identity].Maximum, $noiseCpu)
                }
            }
        }
        $noiseWorkingSet = [int64](
            $snapshot.Group |
                Where-Object category -eq 'external-noise-known' |
                Measure-Object workingSetBytes -Sum
        ).Sum
        $peakWorkingSet = [Math]::Max($peakWorkingSet, $workingSet)
        $peakPrivate = [Math]::Max($peakPrivate, $private)
        $peakCount = [Math]::Max($peakCount, $descendantIds.Count)
        $peakNoiseWorkingSet = [Math]::Max($peakNoiseWorkingSet, $noiseWorkingSet)
    }
    $descendantCpu = 0.0
    foreach ($range in $cpuByIdentity.Values) {
        $descendantCpu += $range.Maximum - $range.Minimum
    }
    $noiseCpu = 0.0
    foreach ($range in $noiseCpuByIdentity.Values) {
        $noiseCpu += $range.Maximum - $range.Minimum
    }
    $averageCpu = if ($systemRows.Count -eq 0) {
        $null
    }
    else {
        ($systemRows | Measure-Object cpuPercent -Average).Average
    }
    [pscustomobject][ordered]@{
        SystemSampleCount = $systemRows.Count
        AverageSystemCpuPercent = $averageCpu
        PeakCommittedBytes = if ($systemRows.Count -eq 0) { $null } else { ($systemRows | Measure-Object committedBytes -Maximum).Maximum }
        MinimumAvailableMB = if ($systemRows.Count -eq 0) { $null } else { ($systemRows | Measure-Object availableMB -Minimum).Minimum }
        PeakProcessorQueueLength = if ($systemRows.Count -eq 0) { $null } else { ($systemRows | Measure-Object processorQueueLength -Maximum).Maximum }
        PeakDescendantWorkingSetBytes = $peakWorkingSet
        PeakDescendantPrivateBytes = $peakPrivate
        PeakDescendantProcessCount = $peakCount
        DescendantCpuSeconds = $descendantCpu
        KnownExternalNoiseCpuSeconds = $noiseCpu
        PeakKnownExternalNoiseWorkingSetBytes = $peakNoiseWorkingSet
        ForeignConflictingProcessCount = $foreignConflictingIdentities.Count
        ForeignConflictingProcessIdentities = @($foreignConflictingIdentities)
    }
}

function Get-GrantMetricsForRun {
    param(
        [Parameter(Mandatory)]
        [object]$Run,

        [Parameter(Mandatory)]
        [object]$Replay,

        [Parameter(Mandatory)]
        [object]$TraceState
    )

    $grants = @($Replay.Grants)
    $waits = @($Replay.Waits)
    $traceGrant = ([DateTime]$TraceState.GrantedUtc).ToUniversalTime()
    $start = ([DateTime]$Run.ProcessStartUtc).ToUniversalTime()
    $exit = ([DateTime]$Run.ProcessExitUtc).ToUniversalTime()
    $grant = if ($grants.Count -eq 1) { $grants[0] } else { $null }
    $grantUtc = if ($null -eq $grant) { $null } else { ([DateTime]$grant.TimestampUtc).ToUniversalTime() }
    $waitStarted = if ($waits.Count -gt 0) {
        ([DateTime]$waits[0].TimestampUtc).ToUniversalTime()
    }
    elseif ($null -ne $TraceState.QueuedUtc) {
        ([DateTime]$TraceState.QueuedUtc).ToUniversalTime()
    }
    else {
        $traceGrant
    }
    [pscustomobject][ordered]@{
        RunId = $Run.RunId
        RootProcessId = [int]$Run.RootProcessId
        GrantCount = $grants.Count
        GrantedNodes = if ($null -eq $grant) { $null } else { [int]$grant.Nodes }
        GrantTimestampUtc = if ($null -eq $grantUtc) { $null } else { $grantUtc.ToString('O') }
        TraceGrantTimestampUtc = $traceGrant.ToString('O')
        TraceAndBinlogGrantDeltaSeconds = if ($null -eq $grantUtc) { $null } else { [Math]::Abs(($traceGrant - $grantUtc).TotalSeconds) }
        RequestToGrantSeconds = if ($null -eq $grantUtc) { $null } else { ($grantUtc - $start).TotalSeconds }
        QueueWaitSeconds = if ($null -eq $grantUtc) { $null } else { [Math]::Max(0, ($grantUtc - $waitStarted).TotalSeconds) }
        RequestToCompletionSeconds = ($exit - $start).TotalSeconds
        CoordinatorNegotiationSeconds = ($traceGrant - ([DateTime]$TraceState.ConnectedUtc).ToUniversalTime()).TotalSeconds
        BinlogErrorCount = [int]$Replay.ErrorCount
        BinlogWarningCount = [int]$Replay.WarningCount
    }
}

function Get-TraceFiles {
    param(
        [Parameter(Mandatory)]
        [string]$DebugPath
    )

    @(
        Get-ChildItem -LiteralPath $DebugPath -Filter 'MSBuild_CoordinatorTrace_PID_*.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            Select-Object -ExpandProperty FullName
    )
}

function Get-StateAtTimestamp {
    param(
        [Parameter(Mandatory)]
        [object[]]$Timeline,

        [Parameter(Mandatory)]
        [DateTime]$TimestampUtc
    )

    $state = [pscustomobject]@{ QueueDepth = 0; ActiveBuilds = 0; AllocatedNodes = 0 }
    foreach ($row in $Timeline | Sort-Object { [DateTime]$_.TimestampUtc }, Sequence) {
        if (([DateTime]$row.TimestampUtc -gt $TimestampUtc)) {
            break
        }
        $state = $row
    }
    return $state
}
