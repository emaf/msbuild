[CmdletBinding()]
param(
    [string]$RunId,
    [string]$LaunchBaseRoot = 'C:\perf\benchmark-launches',
    [string]$SourceRepositoryRoot = 'C:\perf\repos\msbuild-current-vs-final',
    [string]$BuildWorktreeRoot = 'C:\perf\worktrees\msbuild-current-vs-final',
    [string]$BootstrapStagingRoot = 'C:\perf\bootstraps\current-vs-final',
    [switch]$SkipFetch
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
Assert-WindowsCampaignHost

if (-not [IO.Path]::GetFullPath($LaunchBaseRoot).TrimEnd('\').Equals(
    'C:\perf\benchmark-launches',
    [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The authoritative sustained launcher root is fixed at C:\perf\benchmark-launches.'
}
if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId =
        "current-vs-final-sustained-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}
if (-not $RunId.StartsWith(
    'current-vs-final-sustained-',
    [StringComparison]::Ordinal)) {
    throw "RunId '$RunId' must start with 'current-vs-final-sustained-'."
}
$launchMutex = [Threading.Mutex]::new(
    $false,
    'Global\MSBuild-PR14241-CurrentVsFinal-Sustained-Launch')
$launchMutexOwned = $false
try {
    $launchMutexOwned = $launchMutex.WaitOne(0)
}
catch [Threading.AbandonedMutexException] {
    $launchMutexOwned = $true
}
if (-not $launchMutexOwned) {
    $launchMutex.Dispose()
    throw 'Another sustained authoritative launch request is in progress.'
}

$process = $null
$watchdog = $null
try {
    $existingCampaigns = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq 'pwsh.exe' -and
                $_.CommandLine -like '*Run-SustainedCampaign.ps1*' -and
                $_.CommandLine -like '*current-vs-final-sustained-*'
            }
    )
    if ($existingCampaigns.Count -gt 0) {
        throw "A sustained campaign is already running (PID(s): $(@($existingCampaigns.ProcessId) -join ', ')); duplicate launch refused."
    }
    $launchRoot = Join-Path $LaunchBaseRoot $RunId
    $resultRoot = Join-Path 'C:\perf\results' $RunId
    if (Test-Path -LiteralPath $launchRoot) {
        throw "Launch root '$launchRoot' already exists; no relaunch is allowed."
    }
    if (Test-Path -LiteralPath $resultRoot) {
        throw "Result root '$resultRoot' already exists; no relaunch is allowed."
    }
    New-Item -ItemType Directory -Path $launchRoot | Out-Null
    $stdout = Join-Path $launchRoot 'stdout.log'
    $stderr = Join-Path $launchRoot 'stderr.log'
    $watchdogStdout = Join-Path $launchRoot 'deadline-watchdog-stdout.log'
    $watchdogStderr = Join-Path $launchRoot 'deadline-watchdog-stderr.log'
    $script = Join-Path $PSScriptRoot 'Run-SustainedCampaign.ps1'
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $script,
        '-RunId',
        $RunId,
        '-LaunchRoot',
        $launchRoot,
        '-SourceRepositoryRoot',
        $SourceRepositoryRoot,
        '-BuildWorktreeRoot',
        $BuildWorktreeRoot,
        '-BootstrapStagingRoot',
        $BootstrapStagingRoot
    )) {
        $arguments.Add($argument)
    }
    if ($SkipFetch) {
        $arguments.Add('-SkipFetch')
    }
    $request = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Status = 'Starting'
        RequestedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        LauncherProcessId = $PID
        RunId = $RunId
        ResultRoot = $resultRoot
        LaunchRoot = $launchRoot
        FileName = (Get-Command pwsh).Source
        Arguments = $arguments.ToArray()
        CampaignScript = $script
        CampaignScriptSha256 =
            (Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash
        AuthoritativeDetachedLaunchCount = 1
        DuplicateGuardEnabled = $true
        AutomaticRelaunch = $false
        HardTimeoutHours = (Get-CampaignDefinition).HardTimeoutHours
    }
    Write-JsonAtomic `
        -Path (Join-Path $launchRoot 'launch-request.json') `
        -Value $request

    try {
        $process = Start-Process `
            -FilePath (Get-Command pwsh).Source `
            -ArgumentList $arguments.ToArray() `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -WindowStyle Hidden `
            -PassThru
        $processStartUtc = $process.StartTime.ToUniversalTime()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $runMetadataPath = Join-Path $resultRoot 'run-metadata.json'
        while ($timer.Elapsed.TotalSeconds -le 30 -and
            (-not (Test-Path -LiteralPath $resultRoot -PathType Container) -or
                -not (Test-Path -LiteralPath $runMetadataPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $stdout -PathType Leaf) -or
                -not (Test-Path -LiteralPath $stderr -PathType Leaf))) {
            if ($process.HasExited) {
                throw "Detached sustained campaign exited during launch verification with code $($process.ExitCode)."
            }
            Start-Sleep -Milliseconds 200
        }
        if ($process.HasExited) {
            throw "Detached sustained campaign exited during launch verification with code $($process.ExitCode)."
        }
        if (-not (Test-Path -LiteralPath $resultRoot -PathType Container)) {
            throw "Detached campaign did not create '$resultRoot' within 30 seconds."
        }
        if (-not (Test-Path -LiteralPath $runMetadataPath -PathType Leaf)) {
            throw 'Detached campaign did not persist run metadata and its hard deadline within 30 seconds.'
        }
        if (-not (Test-Path -LiteralPath $stdout -PathType Leaf) -or
            -not (Test-Path -LiteralPath $stderr -PathType Leaf)) {
            throw 'Detached sustained stdout/stderr files were not created.'
        }
        if (-not [string]::IsNullOrWhiteSpace(
            (Get-Content -LiteralPath $stderr -Raw))) {
            throw "Detached campaign wrote stderr during launch verification. See '$stderr'."
        }
        $duplicates = @(
            Get-CimInstance Win32_Process |
                Where-Object {
                    $_.Name -eq 'pwsh.exe' -and
                    $_.CommandLine -like
                        '*Run-SustainedCampaign.ps1*' -and
                    $_.CommandLine -like "*$RunId*"
                }
        )
        if ($duplicates.Count -ne 1 -or
            [int]$duplicates[0].ProcessId -ne $process.Id) {
            throw "Expected one authoritative detached process for '$RunId'; found $($duplicates.Count)."
        }
        $actual = Get-Process -Id $process.Id -ErrorAction Stop
        if ($actual.StartTime.ToUniversalTime() -ne $processStartUtc) {
            throw 'Detached sustained process identity changed during verification.'
        }
        $runMetadata =
            Get-Content -LiteralPath $runMetadataPath -Raw |
            ConvertFrom-Json
        $hardDeadlineUtc =
            ConvertTo-UtcDateTimeOffset -Value $runMetadata.HardDeadlineUtc
        $createdUtc =
            ConvertTo-UtcDateTimeOffset -Value $runMetadata.CreatedUtc
        if ([Math]::Abs(
            ($hardDeadlineUtc - $createdUtc).TotalHours - 8.0) -gt
            0.000001) {
            throw 'Detached campaign metadata does not contain the exact eight-hour hard deadline.'
        }
        $watchdogScript =
            Join-Path $PSScriptRoot 'Watch-SustainedCampaignDeadline.ps1'
        $watchdogArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $watchdogScript,
            '-TargetProcessId',
            [string]$process.Id,
            '-TargetProcessStartUtc',
            $processStartUtc.ToString('O'),
            '-DeadlineUtc',
            $hardDeadlineUtc.ToString('O'),
            '-RunRoot',
            $resultRoot,
            '-LaunchRoot',
            $launchRoot
        )
        $watchdog = Start-Process `
            -FilePath (Get-Command pwsh).Source `
            -ArgumentList $watchdogArguments `
            -RedirectStandardOutput $watchdogStdout `
            -RedirectStandardError $watchdogStderr `
            -WindowStyle Hidden `
            -PassThru
        $watchdogStartUtc = $watchdog.StartTime.ToUniversalTime()
        Start-Sleep -Milliseconds 250
        if ($watchdog.HasExited -or
            -not (Test-Path -LiteralPath (
                Join-Path $launchRoot 'deadline-watchdog.json') -PathType Leaf)) {
            throw 'Eight-hour deadline watchdog did not arm durably.'
        }
        $launch = [pscustomobject][ordered]@{
            SchemaVersion = 1
            Status = 'Running'
            VerifiedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            ProcessId = $process.Id
            ProcessStartUtc = $processStartUtc.ToString('O')
            RunId = $RunId
            ResultRoot = $resultRoot
            LaunchRoot = $launchRoot
            Stdout = $stdout
            Stderr = $stderr
            DuplicateProcessCount = $duplicates.Count
            AuthoritativeDetachedLaunchCount = 1
            AuxiliaryDeadlineWatchdogCount = 1
            DeadlineWatchdogProcessId = $watchdog.Id
            DeadlineWatchdogProcessStartUtc =
                $watchdogStartUtc.ToString('O')
            DeadlineWatchdogScript = $watchdogScript
            DeadlineWatchdogScriptSha256 =
                (Get-FileHash `
                    -LiteralPath $watchdogScript `
                    -Algorithm SHA256).Hash
            HardDeadlineUtc = $hardDeadlineUtc.ToString('O')
            AutomaticRelaunch = $false
            HardTimeoutHours = (Get-CampaignDefinition).HardTimeoutHours
        }
        Write-JsonAtomic `
            -Path (Join-Path $launchRoot 'launch.json') `
            -Value $launch
    }
    catch {
        $launchError = $_.Exception.ToString()
        if ($null -ne $watchdog -and -not $watchdog.HasExited) {
            Stop-Process -Id $watchdog.Id
            [void]$watchdog.WaitForExit(10000)
        }
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id
            [void]$process.WaitForExit(10000)
        }
        Write-JsonAtomic `
            -Path (Join-Path $launchRoot 'launch-failure.json') `
            -Value ([pscustomobject][ordered]@{
                Status = 'Failed'
                FailedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                RunId = $RunId
                ResultRoot = $resultRoot
                Error = $launchError
                ExactChildStopped =
                    $null -ne $process -and $process.HasExited
                DeadlineWatchdogStopped =
                    $null -eq $watchdog -or $watchdog.HasExited
                AutomaticRelaunchAttempted = $false
            }) `
            -Depth 8
        throw
    }
    Write-Host "RUN_ID=$RunId"
    Write-Host "RESULT_ROOT=$resultRoot"
    Write-Host "LAUNCH_ROOT=$launchRoot"
    Write-Host "PROCESS_ID=$($process.Id)"
    Write-Host "DEADLINE_WATCHDOG_PROCESS_ID=$($watchdog.Id)"
    Write-Host "STDOUT=$stdout"
    Write-Host "STDERR=$stderr"
}
finally {
    if ($null -ne $watchdog) {
        $watchdog.Dispose()
    }
    if ($null -ne $process) {
        $process.Dispose()
    }
    if ($launchMutexOwned) {
        $launchMutex.ReleaseMutex()
    }
    $launchMutex.Dispose()
}
