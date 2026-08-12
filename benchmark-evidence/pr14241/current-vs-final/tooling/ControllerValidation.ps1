[CmdletBinding()]
param(
    [string]$EventPath,
    [int]$ExpectedInitialWorkers = 18,
    [int]$ExpectedInjectionCompletion = 6,
    [int]$ExpectedEndingCompletion = 12
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function ConvertTo-ControllerUtcDateTimeOffset {
    param([Parameter(Mandatory)][object]$Value)

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        $dateTime = [DateTime]$Value
        if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
            $dateTime = [DateTime]::SpecifyKind($dateTime, [DateTimeKind]::Utc)
        }
        return [DateTimeOffset]::new($dateTime).ToUniversalTime()
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed)) {
        throw "Controller timestamp '$Value' is invalid."
    }
    return $parsed.ToUniversalTime()
}

function Test-SustainedControllerEvents {
    param(
        [Parameter(Mandatory)]
        [object[]]$Events,

        [int]$InitialWorkers = 18,

        [int]$InjectionCompletion = 6,

        [int]$EndingCompletion = 12
    )

    $errors = [Collections.Generic.List[string]]::new()
    $activeByWorker = @{}
    $lastCompletedByWorker = @{}
    $initialWorkerSet = [Collections.Generic.HashSet[int]]::new()
    $initialRunIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $completedByRunId = @{}
    $measuredRunIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $initialLaunchCount = 0
    $measuredCount = 0
    $onsetSeen = $false
    $injectionSeen = $false
    $steadyEndSeen = $false
    $lastTimestamp = [DateTimeOffset]::MinValue
    foreach ($event in $Events) {
        $timestamp = ConvertTo-ControllerUtcDateTimeOffset -Value $event.TimestampUtc
        if ($timestamp -lt $lastTimestamp) {
            $errors.Add('Controller timestamps are not monotonic.')
        }
        $lastTimestamp = $timestamp
        $worker = if ($null -eq $event.Worker) { 0 } else { [int]$event.Worker }
        switch ([string]$event.Event) {
            'Launched' {
                if ($onsetSeen) {
                    $errors.Add("Initial launch '$($event.RunId)' occurred after steady onset.")
                }
                else {
                    $initialLaunchCount++
                }
                if ($worker -le 0) {
                    $errors.Add('Initial launch has no positive worker.')
                }
                elseif (-not $initialRunIds.Add([string]$event.RunId)) {
                    $errors.Add("Initial run '$($event.RunId)' was launched more than once.")
                }
                elseif ($activeByWorker.ContainsKey($worker)) {
                    $errors.Add("Worker $worker was launched while already active.")
                }
                else {
                    $activeByWorker[$worker] = [string]$event.RunId
                    [void]$initialWorkerSet.Add($worker)
                }
            }
            'Completed' {
                if ($worker -le 0) {
                    continue
                }
                $runId = [string]$event.RunId
                if ($completedByRunId.ContainsKey($runId)) {
                    $errors.Add("Run '$runId' completed more than once.")
                    continue
                }
                $matchedActive = $activeByWorker.ContainsKey($worker) -and
                    $activeByWorker[$worker] -eq $runId
                $quiescent = $null -ne $event.PSObject.Properties['Quiescent'] -and
                    [bool]$event.Quiescent
                $exitCode = if ($null -eq $event.PSObject.Properties['ExitCode']) {
                    $null
                }
                else {
                    [int]$event.ExitCode
                }
                $completedByRunId[$runId] = [pscustomobject]@{
                    Worker = $worker
                    MatchedActive = $matchedActive
                    Quiescent = $quiescent
                    ExitCode = $exitCode
                }
                if (-not $activeByWorker.ContainsKey($worker) -or
                    $activeByWorker[$worker] -ne $runId) {
                    $errors.Add("Worker $worker completed '$runId' without a matching active identity.")
                }
                else {
                    if (-not $quiescent) {
                        $errors.Add("Worker $worker completed without full quiescence.")
                    }
                    $activeByWorker.Remove($worker)
                    $lastCompletedByWorker[$worker] = $runId
                }
            }
            'ReplacementLaunched' {
                if ($worker -le 0) {
                    $errors.Add('Replacement launch has no positive worker.')
                }
                elseif ($activeByWorker.ContainsKey($worker)) {
                    $errors.Add("Worker $worker replacement overlapped '$($activeByWorker[$worker])'.")
                }
                elseif (-not $lastCompletedByWorker.ContainsKey($worker)) {
                    $errors.Add("Worker $worker replacement has no completed predecessor.")
                }
                elseif ($event.PSObject.Properties['ReplacedRunId'] -and
                    $event.ReplacedRunId -ne $lastCompletedByWorker[$worker]) {
                    $errors.Add("Worker $worker replacement predecessor does not match.")
                }
                else {
                    $activeByWorker[$worker] = [string]$event.RunId
                }
            }
            'SteadyOnset' {
                if ($onsetSeen) {
                    $errors.Add('Steady onset was recorded more than once.')
                }
                if ($initialLaunchCount -ne $InitialWorkers -or
                    $initialWorkerSet.Count -ne $InitialWorkers) {
                    $errors.Add("Steady onset occurred after $initialLaunchCount initial launches across $($initialWorkerSet.Count) workers; expected exactly $InitialWorkers.")
                }
                $onsetSeen = $true
            }
            'MeasuredCompletion' {
                if (-not $onsetSeen -or $steadyEndSeen) {
                    $errors.Add('Measured completion occurred outside the steady window.')
                }
                $runId = [string]$event.RunId
                if (-not $measuredRunIds.Add($runId)) {
                    $errors.Add("Run '$runId' was measured more than once.")
                }
                if (-not $completedByRunId.ContainsKey($runId)) {
                    $errors.Add("Measured run '$runId' has no completed event.")
                }
                else {
                    $completed = $completedByRunId[$runId]
                    if (-not $completed.MatchedActive -or
                        [int]$completed.Worker -ne $worker) {
                        $errors.Add("Measured run '$runId' was not the matching active run for worker $worker.")
                    }
                    if (-not $completed.Quiescent -or
                        $null -eq $completed.ExitCode -or
                        [int]$completed.ExitCode -ne 0) {
                        $errors.Add("Measured run '$runId' was not a successful quiescent completion.")
                    }
                }
                $measuredCount++
                if ([int]$event.CompletionNumber -ne $measuredCount) {
                    $errors.Add("Measured completion numbering skipped at $measuredCount.")
                }
            }
            'Injected' {
                if ($injectionSeen) {
                    $errors.Add('Injection was recorded more than once.')
                }
                if ($measuredCount -ne $InjectionCompletion) {
                    $errors.Add("Injection occurred after measured completion $measuredCount; expected $InjectionCompletion.")
                }
                $injectionSeen = $true
            }
            'SteadyEnd' {
                if ($steadyEndSeen) {
                    $errors.Add('Steady end was recorded more than once.')
                }
                if ($measuredCount -ne $EndingCompletion) {
                    $errors.Add("Steady end occurred after measured completion $measuredCount; expected $EndingCompletion.")
                }
                $steadyEndSeen = $true
            }
        }
    }
    if ($initialLaunchCount -ne $InitialWorkers -or
        $initialWorkerSet.Count -ne $InitialWorkers) {
        $errors.Add("Found $initialLaunchCount pre-onset initial launches across $($initialWorkerSet.Count) workers; expected $InitialWorkers.")
    }
    if (-not $onsetSeen -or -not $injectionSeen -or -not $steadyEndSeen) {
        $errors.Add('Controller log is missing onset, injection, or steady end.')
    }
    if ($measuredCount -ne $EndingCompletion) {
        $errors.Add("Found $measuredCount measured completions; expected $EndingCompletion.")
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        InitialWorkerCount = $initialWorkerSet.Count
        MeasuredCompletionCount = $measuredCount
        InjectionAfterCompletion = $InjectionCompletion
        EndingCompletion = $EndingCompletion
        ActiveWorkersAtEnd = $activeByWorker.Count
    }
}

if ($MyInvocation.InvocationName -ne '.' -and -not [string]::IsNullOrWhiteSpace($EventPath)) {
    $events = @(
        Get-Content -LiteralPath $EventPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $result = Test-SustainedControllerEvents `
        -Events $events `
        -InitialWorkers $ExpectedInitialWorkers `
        -InjectionCompletion $ExpectedInjectionCompletion `
        -EndingCompletion $ExpectedEndingCompletion
    $result
    if (-not $result.Valid) {
        throw "Sustained controller event validation failed: $($result.Errors -join '; ')"
    }
}
