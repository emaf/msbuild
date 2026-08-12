Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
. (Join-Path $PSScriptRoot 'CoordinatorTrace.ps1')

function Test-VerifiedProcessIdentity {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,
        [Parameter(Mandatory)]
        [object]$ProcessStartUtc
    )

    $process = $null
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $expected = ConvertTo-UtcDateTimeOffset -Value $ProcessStartUtc
        $actual = ConvertTo-UtcDateTimeOffset -Value $process.StartTime
        return -not $process.HasExited -and
            [Math]::Abs(($actual - $expected).TotalSeconds) -lt 1
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Stop-VerifiedProcessTree {
    param(
        [Parameter(Mandatory)]
        [int]$RootProcessId,
        [Parameter(Mandatory)]
        [object]$RootProcessStartUtc,
        [string[]]$DescendantIdentities = @(),
        [int]$TimeoutSeconds = 15
    )

    $errors = [Collections.Generic.List[string]]::new()
    $targets = [Collections.Generic.List[object]]::new()
    $targets.Add([pscustomobject]@{
        ProcessId = $RootProcessId
        ProcessStartUtc = (ConvertTo-UtcDateTimeOffset -Value $RootProcessStartUtc)
        Root = $true
    })
    foreach ($identity in $DescendantIdentities) {
        $parts = [string]$identity -split '\|', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
            $errors.Add("Captured descendant identity '$identity' is incomplete.")
            continue
        }
        try {
            $targets.Add([pscustomobject]@{
                ProcessId = [int]$parts[0]
                ProcessStartUtc = (ConvertTo-UtcDateTimeOffset -Value $parts[1])
                Root = $false
            })
        }
        catch {
            $errors.Add("Captured descendant identity '$identity' is invalid: $($_.Exception.Message)")
        }
    }
    $targets = @($targets | Sort-Object Root -Descending | Group-Object {
        "$($_.ProcessId)|$($_.ProcessStartUtc.UtcTicks)"
    } | ForEach-Object { $_.Group[0] })

    foreach ($target in $targets) {
        $process = Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            continue
        }
        try {
            $actualStart = ConvertTo-UtcDateTimeOffset -Value $process.StartTime
            if ([Math]::Abs(($actualStart - $target.ProcessStartUtc).TotalSeconds) -ge 1) {
                continue
            }
            if (-not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    $errors.Add("PID $($target.ProcessId) did not exit within $TimeoutSeconds seconds.")
                }
            }
        }
        catch {
            $errors.Add("Failed to terminate verified PID $($target.ProcessId): $($_.Exception.Message)")
        }
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }
        }
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $live = @()
    do {
        $live = @(
            $targets |
                Where-Object {
                    Test-VerifiedProcessIdentity `
                        -ProcessId $_.ProcessId `
                        -ProcessStartUtc $_.ProcessStartUtc
                }
        )
        if ($live.Count -eq 0 -or $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ($true)
    if ($live.Count -gt 0) {
        $errors.Add("Verified process identities remain live: $(@($live | ForEach-Object { "$($_.ProcessId)|$($_.ProcessStartUtc.ToString('O'))" }) -join ', ').")
    }

    [pscustomobject][ordered]@{
        Succeeded = $errors.Count -eq 0 -and $live.Count -eq 0
        Errors = $errors.ToArray()
        LiveIdentities = @($live | ForEach-Object {
            "$($_.ProcessId)|$($_.ProcessStartUtc.ToString('O'))"
        })
    }
}

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
    $processStartUtc = ConvertTo-UtcDateTimeOffset -Value $process.StartTime
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $readyFile)) {
            if ($process.HasExited) {
                throw "Resource monitor exited before readiness with code $($process.ExitCode)."
            }
            if ($timer.Elapsed.TotalSeconds -gt 30) {
                throw 'Resource monitor did not become ready within 30 seconds.'
            }
            Start-Sleep -Milliseconds 100
        }
        return [pscustomobject]@{
            Process = $process
            ProcessStartUtc = $processStartUtc
            StopFile = $stopFile
            ReadyFile = $readyFile
        }
    }
    catch {
        $startupException = $_.Exception
        $stop = Stop-VerifiedProcessTree `
            -RootProcessId $process.Id `
            -RootProcessStartUtc $processStartUtc
        $process.Dispose()
        if (-not $stop.Succeeded) {
            throw [AggregateException]::new(
                'Resource monitor startup and cleanup failed.',
                [Exception[]]@(
                    $startupException,
                    [InvalidOperationException]::new(($stop.Errors -join '; '))
                ))
        }
        throw $startupException
    }
}

function Stop-ScenarioMonitor {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Monitor
    )

    $errors = [Collections.Generic.List[string]]::new()
    try {
        New-Item -ItemType File -Force -Path $Monitor.StopFile | Out-Null
        if (-not $Monitor.Process.WaitForExit(30000)) {
            $stop = Stop-VerifiedProcessTree `
                -RootProcessId $Monitor.Process.Id `
                -RootProcessStartUtc $Monitor.ProcessStartUtc
            foreach ($message in $stop.Errors) {
                $errors.Add($message)
            }
        }
        if (-not $Monitor.Process.HasExited) {
            $errors.Add('Resource monitor remained live after targeted shutdown.')
        }
        elseif ($Monitor.Process.ExitCode -ne 0) {
            $errors.Add("Resource monitor exited with code $($Monitor.Process.ExitCode).")
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }
    finally {
        $Monitor.Process.Dispose()
    }
    if ($errors.Count -gt 0) {
        throw ($errors -join '; ')
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
        [DateTimeOffset]$ScenarioStartedUtc,

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
    $processStartUtc = $null
    try {
        [void]$process.Start()
        $processStartUtc = ConvertTo-UtcDateTimeOffset -Value $process.StartTime
        return [pscustomobject][ordered]@{
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
    catch {
        $startException = $_.Exception
        $cleanupErrors = @()
        if ($null -ne $processStartUtc) {
            $stop = Stop-VerifiedProcessTree `
                -RootProcessId $process.Id `
                -RootProcessStartUtc $processStartUtc
            $cleanupErrors = @($stop.Errors)
            if (@($stop.LiveIdentities).Count -gt 0) {
                [void](Write-ScenarioTerminalOutcome `
                    -ScenarioRoot $ScenarioRoot `
                    -OutcomeType 'LiveBuildStartupCleanupFailure' `
                    -Disposition 'NonRetryableHarnessFailure' `
                    -Errors @("Build '$RunId' remained live after startup cleanup."))
            }
        }
        $process.Dispose()
        if ($cleanupErrors.Count -gt 0) {
            throw [AggregateException]::new(
                "Build '$RunId' startup and targeted cleanup failed.",
                [Exception[]]@(
                    $startException,
                    [InvalidOperationException]::new(($cleanupErrors -join '; '))
                ))
        }
        throw $startException
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
                    (ConvertTo-UtcDateTimeOffset -Value $process.CreationDate).ToString('O')
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
            $capturedStart = ConvertTo-UtcDateTimeOffset -Value $parts[1]
            $actualStart = ConvertTo-UtcDateTimeOffset -Value $process.StartTime
            if ([Math]::Abs(($actualStart - $capturedStart).TotalSeconds) -lt 1) {
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
    $completionError = $null
    try {
        $Run.Process.WaitForExit()
        $Run.ProcessExitUtc = ConvertTo-UtcDateTimeOffset -Value $Run.Process.ExitTime
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
    }
    catch {
        $Run.Quiescent = $false
        $completionError = $_.Exception
    }
    finally {
        $Run.Completed = $true
        $Run.Process.Dispose()
    }
    if ($null -ne $completionError) {
        throw $completionError
    }
    return $true
}

function Stop-UnfinishedScenarioBuilds {
    param(
        [Parameter(Mandatory)]
        [object[]]$Runs,
        [int]$TimeoutSeconds = 15
    )

    $errors = [Collections.Generic.List[string]]::new()
    $liveRunIds = [Collections.Generic.List[string]]::new()
    $quiescenceUncertainRunIds = [Collections.Generic.List[string]]::new()
    $cleanupRuns = @(
        $Runs |
            Where-Object {
                -not $_.Completed -or $_.Quiescent -ne $true
            }
    )
    if ($cleanupRuns.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Errors = @()
            LiveRunIds = @()
            QuiescenceUncertainRunIds = @()
        }
    }

    try {
        Update-ScenarioProcessTrees -Runs $cleanupRuns
    }
    catch {
        $errors.Add("Final process-tree capture failed: $($_.Exception.Message)")
        foreach ($run in $cleanupRuns) {
            if (-not $quiescenceUncertainRunIds.Contains([string]$run.RunId)) {
                $quiescenceUncertainRunIds.Add([string]$run.RunId)
            }
        }
    }
    foreach ($run in $cleanupRuns) {
        $wasCompleted = [bool]$run.Completed
        if ($wasCompleted -and $run.Quiescent -ne $true) {
            $errors.Add("$($run.RunId): root completed without proven redirected-stream/descendant quiescence.")
            if (-not $quiescenceUncertainRunIds.Contains([string]$run.RunId)) {
                $quiescenceUncertainRunIds.Add([string]$run.RunId)
            }
        }
        $stop = Stop-VerifiedProcessTree `
            -RootProcessId $run.RootProcessId `
            -RootProcessStartUtc $run.ProcessStartUtc `
            -DescendantIdentities @($run.DescendantIdentities) `
            -TimeoutSeconds $TimeoutSeconds
        foreach ($message in $stop.Errors) {
            $errors.Add("$($run.RunId): $message")
            if (-not $quiescenceUncertainRunIds.Contains([string]$run.RunId)) {
                $quiescenceUncertainRunIds.Add([string]$run.RunId)
            }
        }
        if (-not $wasCompleted) {
            try {
                if (-not $run.Process.HasExited) {
                    [void]$run.Process.WaitForExit($TimeoutSeconds * 1000)
                }
                if ($run.Process.HasExited) {
                    [void](Complete-ExitedScenarioBuild `
                        -Run $run `
                        -QuiescenceTimeoutSeconds $TimeoutSeconds)
                    if (-not $run.Quiescent) {
                        $errors.Add("$($run.RunId): redirected streams or captured descendants did not quiesce.")
                        if (-not $quiescenceUncertainRunIds.Contains([string]$run.RunId)) {
                            $quiescenceUncertainRunIds.Add([string]$run.RunId)
                        }
                    }
                }
            }
            catch {
                $errors.Add("$($run.RunId): process completion failed: $($_.Exception.Message)")
                if (-not $quiescenceUncertainRunIds.Contains([string]$run.RunId)) {
                    $quiescenceUncertainRunIds.Add([string]$run.RunId)
                }
                if (-not $run.Completed) {
                    $run.Process.Dispose()
                }
            }
        }

        $rootLive = Test-VerifiedProcessIdentity `
            -ProcessId $run.RootProcessId `
            -ProcessStartUtc $run.ProcessStartUtc
        $descendantLive = @(
            foreach ($identity in @($run.DescendantIdentities)) {
                $parts = [string]$identity -split '\|', 2
                if ($parts.Count -eq 2 -and
                    -not [string]::IsNullOrWhiteSpace($parts[1]) -and
                    (Test-VerifiedProcessIdentity `
                        -ProcessId ([int]$parts[0]) `
                        -ProcessStartUtc $parts[1])) {
                    $identity
                }
            }
        )
        if ($rootLive -or $descendantLive.Count -gt 0) {
            $liveRunIds.Add([string]$run.RunId)
            if (-not $quiescenceUncertainRunIds.Contains([string]$run.RunId)) {
                $quiescenceUncertainRunIds.Add([string]$run.RunId)
            }
        }
    }

    [pscustomobject][ordered]@{
        Succeeded =
            $errors.Count -eq 0 -and
            $liveRunIds.Count -eq 0 -and
            $quiescenceUncertainRunIds.Count -eq 0
        Errors = $errors.ToArray()
        LiveRunIds = $liveRunIds.ToArray()
        QuiescenceUncertainRunIds = $quiescenceUncertainRunIds.ToArray()
    }
}

function Write-ScenarioCleanupTerminalOutcome {
    param(
        [Parameter(Mandatory)]
        [string]$ScenarioRoot,

        [Parameter(Mandatory)]
        [pscustomobject]$Cleanup
    )

    if ($Cleanup.Succeeded) {
        return $null
    }
    $liveRunIds = @(
        if ($null -ne $Cleanup.PSObject.Properties['LiveRunIds']) {
            $Cleanup.LiveRunIds
        }
    )
    $uncertainRunIds = @(
        if ($null -ne $Cleanup.PSObject.Properties['QuiescenceUncertainRunIds']) {
            $Cleanup.QuiescenceUncertainRunIds
        }
    )
    $terminalErrors = [Collections.Generic.List[string]]::new()
    foreach ($message in @($Cleanup.Errors)) {
        $terminalErrors.Add([string]$message)
    }
    if ($liveRunIds.Count -gt 0) {
        $terminalErrors.Add(
            "Build process identities remained live after cleanup: $($liveRunIds -join ', ').")
    }
    if ($uncertainRunIds.Count -gt 0) {
        $terminalErrors.Add(
            "Build quiescence could not be established without forced or uncertain cleanup: $($uncertainRunIds -join ', ').")
    }
    if ($terminalErrors.Count -eq 0) {
        $terminalErrors.Add('Scenario build cleanup failed without proving process quiescence.')
    }

    Write-ScenarioTerminalOutcome `
        -ScenarioRoot $ScenarioRoot `
        -OutcomeType $(if ($liveRunIds.Count -gt 0) {
            'LiveBuildCleanupFailure'
        }
        else {
            'BuildQuiescenceFailure'
        }) `
        -Disposition 'NonRetryableHarnessFailure' `
        -Errors $terminalErrors.ToArray()
}

function Wait-ScenarioBuilds {
    param(
        [Parameter(Mandatory)]
        [object[]]$Runs,

        [int]$TimeoutMinutes = 10
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastProcessTreeSampleUtc = [DateTimeOffset]::MinValue
    while (@($Runs | Where-Object { -not $_.Completed }).Count -gt 0) {
        if (([DateTimeOffset]::UtcNow - $lastProcessTreeSampleUtc).TotalSeconds -ge 5) {
            Update-ScenarioProcessTrees -Runs $Runs
            $lastProcessTreeSampleUtc = [DateTimeOffset]::UtcNow
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

        [DateTimeOffset]$WindowStartUtc,

        [DateTimeOffset]$WindowEndUtc
    )

    $systemRows = @(Import-Csv -LiteralPath (Join-Path $MonitorRoot 'system.csv'))
    if ($PSBoundParameters.ContainsKey('WindowStartUtc')) {
        $systemRows = @(
            $systemRows |
                Where-Object {
                    $timestamp = ConvertTo-UtcDateTimeOffset -Value $_.timestampUtc
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
                StartUtc = ConvertTo-UtcDateTimeOffset -Value $run.ProcessStartUtc
                ExitUtc = if ([string]::IsNullOrWhiteSpace([string]$run.ProcessExitUtc)) {
                    [DateTimeOffset]::MaxValue
                }
                else {
                    ConvertTo-UtcDateTimeOffset -Value $run.ProcessExitUtc
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
        $timestamp = ConvertTo-UtcDateTimeOffset -Value $snapshot.Name
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
    $traceGrant = ConvertTo-UtcDateTimeOffset -Value $TraceState.GrantedUtc
    $start = ConvertTo-UtcDateTimeOffset -Value $Run.ProcessStartUtc
    $exit = ConvertTo-UtcDateTimeOffset -Value $Run.ProcessExitUtc
    $grant = if ($grants.Count -eq 1) { $grants[0] } else { $null }
    $grantUtc = if ($null -eq $grant) { $null } else { ConvertTo-UtcDateTimeOffset -Value $grant.TimestampUtc }
    $waitStarted = if ($waits.Count -gt 0) {
        ConvertTo-UtcDateTimeOffset -Value $waits[0].TimestampUtc
    }
    elseif ($null -ne $TraceState.QueuedUtc) {
        ConvertTo-UtcDateTimeOffset -Value $TraceState.QueuedUtc
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
        CoordinatorNegotiationSeconds = ($traceGrant - (ConvertTo-UtcDateTimeOffset -Value $TraceState.ConnectedUtc)).TotalSeconds
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
        [DateTimeOffset]$TimestampUtc
    )

    $state = [pscustomobject]@{ QueueDepth = 0; ActiveBuilds = 0; AllocatedNodes = 0 }
    foreach ($row in $Timeline | Sort-Object { ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc }, Sequence) {
        if ((ConvertTo-UtcDateTimeOffset -Value $row.TimestampUtc) -gt $TimestampUtc.ToUniversalTime()) {
            break
        }
        $state = $row
    }
    return $state
}
