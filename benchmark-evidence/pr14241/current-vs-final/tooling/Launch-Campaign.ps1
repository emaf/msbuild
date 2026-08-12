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
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
Assert-WindowsCampaignHost

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "current-vs-final-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}
if (-not $RunId.StartsWith('current-vs-final-', [StringComparison]::Ordinal)) {
    throw "RunId '$RunId' must start with 'current-vs-final-'."
}
$existingCampaigns = @(
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq 'pwsh.exe' -and
                $_.CommandLine -like '*Run-Campaign.ps1*' -and
                $_.CommandLine -like '*current-vs-final-*'
        }
)
if ($existingCampaigns.Count -gt 0) {
    throw "A current-vs-final campaign is already running (PID(s): $(@($existingCampaigns.ProcessId) -join ', '))."
}
$launchRoot = Join-Path $LaunchBaseRoot $RunId
$resultRoot = Join-Path 'C:\perf\results' $RunId
if (Test-Path -LiteralPath $launchRoot) {
    throw "Launch root '$launchRoot' already exists; duplicate launch refused."
}
if (Test-Path -LiteralPath $resultRoot) {
    throw "Result root '$resultRoot' already exists; duplicate launch refused."
}
New-Item -ItemType Directory -Path $launchRoot | Out-Null
$stdout = Join-Path $launchRoot 'stdout.log'
$stderr = Join-Path $launchRoot 'stderr.log'
$script = Join-Path $PSScriptRoot 'Run-Campaign.ps1'
$arguments = [Collections.Generic.List[string]]::new()
foreach ($argument in @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', $script,
    '-RunId', $RunId,
    '-LaunchRoot', $launchRoot,
    '-SourceRepositoryRoot', $SourceRepositoryRoot,
    '-BuildWorktreeRoot', $BuildWorktreeRoot,
    '-BootstrapStagingRoot', $BootstrapStagingRoot
)) {
    $arguments.Add($argument)
}
if ($SkipFetch) {
    $arguments.Add('-SkipFetch')
}

Write-JsonAtomic -Path (Join-Path $launchRoot 'launch-request.json') -Value ([pscustomobject][ordered]@{
    Status = 'Starting'
    RequestedUtc = [DateTime]::UtcNow.ToString('O')
    LauncherProcessId = $PID
    RunId = $RunId
    ResultRoot = $resultRoot
    LaunchRoot = $launchRoot
    FileName = (Get-Command pwsh).Source
    Arguments = $arguments.ToArray()
    CampaignScript = $script
    CampaignScriptSha256 = (Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash
})

$process = $null
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
    while ($timer.Elapsed.TotalSeconds -le 30 -and
        (-not (Test-Path -LiteralPath $resultRoot -PathType Container) -or
            -not (Test-Path -LiteralPath $stdout -PathType Leaf) -or
            -not (Test-Path -LiteralPath $stderr -PathType Leaf))) {
        if ($process.HasExited) {
            throw "Detached campaign exited during launch verification with code $($process.ExitCode)."
        }
        Start-Sleep -Milliseconds 200
    }
    if ($process.HasExited) {
        throw "Detached campaign exited during launch verification with code $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $resultRoot -PathType Container)) {
        throw "Detached campaign did not create result root '$resultRoot' within 30 seconds."
    }
    if (-not (Test-Path -LiteralPath $stdout -PathType Leaf) -or
        -not (Test-Path -LiteralPath $stderr -PathType Leaf)) {
        throw 'Detached campaign stdout/stderr files were not created.'
    }
    if (-not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $stderr -Raw))) {
        throw "Detached campaign wrote stderr during launch verification. See '$stderr'."
    }
    $duplicates = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq 'pwsh.exe' -and
                    $_.CommandLine -like "*Run-Campaign.ps1*" -and
                    $_.CommandLine -like "*$RunId*"
            }
    )
    if ($duplicates.Count -ne 1 -or [int]$duplicates[0].ProcessId -ne $process.Id) {
        throw "Expected exactly one detached campaign for '$RunId'; found $($duplicates.Count)."
    }
    $actual = Get-Process -Id $process.Id -ErrorAction Stop
    if ($actual.StartTime.ToUniversalTime() -ne $processStartUtc) {
        throw 'Detached process identity changed during verification.'
    }
    $launchedProcessId = $process.Id
    Write-JsonAtomic -Path (Join-Path $launchRoot 'launch.json') -Value ([pscustomobject][ordered]@{
        Status = 'Running'
        VerifiedUtc = [DateTime]::UtcNow.ToString('O')
        ProcessId = $launchedProcessId
        ProcessStartUtc = $processStartUtc.ToString('O')
        RunId = $RunId
        ResultRoot = $resultRoot
        LaunchRoot = $launchRoot
        Stdout = $stdout
        Stderr = $stderr
        DuplicateProcessCount = $duplicates.Count
        Alive = -not $process.HasExited
        ResultRootExists = Test-Path -LiteralPath $resultRoot -PathType Container
        StdoutExists = Test-Path -LiteralPath $stdout -PathType Leaf
        StderrExists = Test-Path -LiteralPath $stderr -PathType Leaf
        StderrEmpty = [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $stderr -Raw))
        CurrentStep = 'initializing'
        EstimatedTotalCampaignHours = '2-4 (strict projected maximum 4)'
    })
}
catch {
    $launchError = $_.Exception.ToString()
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id
        [void]$process.WaitForExit(10000)
    }
    Write-JsonAtomic -Path (Join-Path $launchRoot 'launch-failure.json') -Value ([pscustomobject][ordered]@{
        Status = 'Failed'
        FailedUtc = [DateTime]::UtcNow.ToString('O')
        RunId = $RunId
        ResultRoot = $resultRoot
        Error = $launchError
        ChildStopped = $null -ne $process -and $process.HasExited
    }) -Depth 8
    throw
}
finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
}
Write-Host "RUN_ID=$RunId"
Write-Host "RESULT_ROOT=$resultRoot"
Write-Host "LAUNCH_ROOT=$launchRoot"
Write-Host "PROCESS_ID=$launchedProcessId"
Write-Host 'CURRENT_STEP=initializing'
Write-Host 'ESTIMATED_TOTAL_HOURS=2-4 (strict maximum 4)'
Write-Host "STDOUT=$stdout"
Write-Host "STDERR=$stderr"
