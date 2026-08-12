[CmdletBinding()]
param(
    [string]$EventPath,
    [int]$ExpectedInitialWorkers = 18,
    [int]$ExpectedInjectionCompletion = 6,
    [int]$ExpectedEndingCompletion = 12
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

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
    $measuredCount = 0
    $onsetSeen = $false
    $injectionSeen = $false
    $steadyEndSeen = $false
    $lastTimestamp = [DateTime]::MinValue
    foreach ($event in $Events) {
        $timestamp = ([DateTime]$event.TimestampUtc).ToUniversalTime()
        if ($timestamp -lt $lastTimestamp) {
            $errors.Add('Controller timestamps are not monotonic.')
        }
        $lastTimestamp = $timestamp
        $worker = if ($null -eq $event.Worker) { 0 } else { [int]$event.Worker }
        switch ([string]$event.Event) {
            'Launched' {
                if ($worker -le 0) {
                    $errors.Add('Initial launch has no positive worker.')
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
                if (-not $activeByWorker.ContainsKey($worker) -or
                    $activeByWorker[$worker] -ne [string]$event.RunId) {
                    $errors.Add("Worker $worker completed '$($event.RunId)' without a matching active identity.")
                }
                else {
                    if ($event.PSObject.Properties['Quiescent'] -and -not [bool]$event.Quiescent) {
                        $errors.Add("Worker $worker completed without full quiescence.")
                    }
                    $activeByWorker.Remove($worker)
                    $lastCompletedByWorker[$worker] = [string]$event.RunId
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
                $onsetSeen = $true
            }
            'MeasuredCompletion' {
                if (-not $onsetSeen -or $steadyEndSeen) {
                    $errors.Add('Measured completion occurred outside the steady window.')
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
    if ($initialWorkerSet.Count -ne $InitialWorkers) {
        $errors.Add("Found $($initialWorkerSet.Count) initial workers; expected $InitialWorkers.")
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
