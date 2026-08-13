[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$TargetProcessId,
    [Parameter(Mandatory)]
    [DateTimeOffset]$TargetProcessStartUtc,
    [Parameter(Mandatory)]
    [DateTimeOffset]$DeadlineUtc,
    [Parameter(Mandatory)]
    [string]$RunRoot,
    [Parameter(Mandatory)]
    [string]$LaunchRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Campaign.Common.ps1')

$deadline = $DeadlineUtc.ToUniversalTime()
$recordPath = Join-Path $LaunchRoot 'deadline-watchdog.json'
Write-JsonAtomic `
    -Path $recordPath `
    -Value ([pscustomobject][ordered]@{
        SchemaVersion = 1
        Status = 'Armed'
        ArmedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        WatchdogProcessId = $PID
        TargetProcessId = $TargetProcessId
        TargetProcessStartUtc =
            $TargetProcessStartUtc.ToUniversalTime().ToString('O')
        DeadlineUtc = $deadline.ToString('O')
        HardTimeoutHours = 8
    })

$lastQueryFailure = $null
$targetProcess = $null
$targetExited = $false
try {
    try {
        $targetProcess =
            [Diagnostics.Process]::GetProcessById($TargetProcessId)
    }
    catch [ArgumentException] {
        $targetExited = $true
    }
    if ($null -ne $targetProcess) {
        $actualStart =
            ConvertTo-UtcDateTimeOffset -Value $targetProcess.StartTime
        if ([Math]::Abs(
            ($actualStart -
                $TargetProcessStartUtc.ToUniversalTime()).TotalSeconds) -ge
            1) {
            $targetExited = $true
        }
        else {
            $remainingMilliseconds = [Math]::Max(
                0,
                [Math]::Min(
                    [int]::MaxValue,
                    [Math]::Ceiling(
                        ($deadline -
                            [DateTimeOffset]::UtcNow).TotalMilliseconds)))
            $targetExited =
                $targetProcess.WaitForExit(
                    [int]$remainingMilliseconds)
        }
    }
}
catch {
    $lastQueryFailure = $_.Exception.ToString()
}
finally {
    if ($null -ne $targetProcess) {
        $targetProcess.Dispose()
    }
}
if ($targetExited) {
    Write-JsonAtomic `
        -Path $recordPath `
        -Value ([pscustomobject][ordered]@{
            SchemaVersion = 1
            Status = 'TargetExitedBeforeDeadline'
            CompletedUtc =
                [DateTimeOffset]::UtcNow.ToString('O')
            WatchdogProcessId = $PID
            TargetProcessId = $TargetProcessId
            TargetProcessStartUtc =
                $TargetProcessStartUtc.ToUniversalTime().ToString('O')
            DeadlineUtc = $deadline.ToString('O')
            LastQueryFailure = $lastQueryFailure
            TimeoutTerminationAttempted = $false
        }) `
        -Depth 8
    return
}
if ([DateTimeOffset]::UtcNow -lt $deadline) {
    $remaining = $deadline - [DateTimeOffset]::UtcNow
    Start-Sleep -Milliseconds (
        [int][Math]::Min(
            [int]::MaxValue,
            [Math]::Ceiling($remaining.TotalMilliseconds)))
}

$timeoutMarker = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Status = 'HardTimeoutTerminationStarting'
    TimedOutUtc = [DateTimeOffset]::UtcNow.ToString('O')
    WatchdogProcessId = $PID
    TargetProcessId = $TargetProcessId
    TargetProcessStartUtc =
        $TargetProcessStartUtc.ToUniversalTime().ToString('O')
    DeadlineUtc = $deadline.ToString('O')
    HardTimeoutHours = 8
    LastQueryFailure = $lastQueryFailure
    TimeoutTerminationAttempted = $true
}
Write-JsonAtomic -Path $recordPath -Value $timeoutMarker -Depth 8
if (Test-Path -LiteralPath $RunRoot -PathType Container) {
    Write-JsonAtomic `
        -Path (Join-Path $RunRoot 'campaign-hard-timeout.json') `
        -Value $timeoutMarker `
        -Depth 8
}

$termination = Stop-VerifiedProcessTree `
    -RootProcessId $TargetProcessId `
    -RootProcessStartUtc $TargetProcessStartUtc `
    -TimeoutSeconds 60
$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Status = if ($termination.Succeeded) {
        'HardTimeoutTerminationCompleted'
    }
    else {
        'HardTimeoutTerminationFailed'
    }
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    WatchdogProcessId = $PID
    TargetProcessId = $TargetProcessId
    TargetProcessStartUtc =
        $TargetProcessStartUtc.ToUniversalTime().ToString('O')
    DeadlineUtc = $deadline.ToString('O')
    HardTimeoutHours = 8
    TimeoutTerminationAttempted = $true
    Termination = $termination
}
Write-JsonAtomic -Path $recordPath -Value $result -Depth 12
if (Test-Path -LiteralPath $RunRoot -PathType Container) {
    Write-JsonAtomic `
        -Path (Join-Path $RunRoot 'campaign-hard-timeout.json') `
        -Value $result `
        -Depth 12
}
if (-not $termination.Succeeded) {
    throw 'Eight-hour watchdog could not verify termination of the exact campaign process tree.'
}
