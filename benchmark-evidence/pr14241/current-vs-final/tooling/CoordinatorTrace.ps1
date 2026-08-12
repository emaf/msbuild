Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-TraceTimestampAndMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Line,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [int]$LineNumber
    )

    if ($Line -notmatch '^\s*(?<thread>.*?)\s+(?<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+\+\s*[\d.]+ms:\s*(?<message>.*)$') {
        return $null
    }
    [pscustomobject][ordered]@{
        TimestampUtc = [DateTime]::Parse(
            $Matches.timestamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        Message = $Matches.message
        ThreadKey = $Matches.thread.Trim()
        SourcePath = $SourcePath
        LineNumber = $LineNumber
    }
}

function Get-RunProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Run,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Run.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }
    return $null
}

function Resolve-TraceRunIdentity {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [DateTime]$TimestampUtc,

        [object[]]$RunRecords = @()
    )

    $matches = @(
        foreach ($run in $RunRecords) {
            $runPid = Get-RunProperty -Run $run -Names @('RootProcessId', 'rootProcessId')
            if ($null -eq $runPid -or [int]$runPid -ne $ProcessId) {
                continue
            }
            $startValue = Get-RunProperty -Run $run -Names @('ProcessStartUtc', 'processStartUtc', 'StartUtc')
            $exitValue = Get-RunProperty -Run $run -Names @('ProcessExitUtc', 'processExitUtc', 'ExitUtc')
            if ([string]::IsNullOrWhiteSpace([string]$startValue)) {
                continue
            }
            $start = ([DateTime]$startValue).ToUniversalTime()
            $exit = if ([string]::IsNullOrWhiteSpace([string]$exitValue)) {
                [DateTime]::MaxValue
            }
            else {
                ([DateTime]$exitValue).ToUniversalTime().AddSeconds(30)
            }
            if ($TimestampUtc -ge $start.AddSeconds(-2) -and $TimestampUtc -le $exit) {
                $runId = Get-RunProperty -Run $run -Names @('RunId', 'runId', 'Label', 'label')
                [pscustomobject]@{
                    Key = "$ProcessId|$($start.Ticks)"
                    RunId = if ([string]::IsNullOrWhiteSpace([string]$runId)) { "$ProcessId|$($start.Ticks)" } else { [string]$runId }
                    ProcessStartUtc = $start
                }
            }
        }
    )
    if ($matches.Count -gt 0) {
        $ordered = @($matches | Sort-Object ProcessStartUtc -Descending)
        if ($ordered.Count -gt 1 -and $ordered[0].ProcessStartUtc -eq $ordered[1].ProcessStartUtc) {
            throw "Trace PID $ProcessId at $($TimestampUtc.ToString('O')) maps to duplicate OS process identities."
        }
        return $ordered[0]
    }
    return $null
}

function Get-LiveTraceState {
    param(
        [Parameter(Mandatory)]
        [hashtable]$States,

        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    $matches = @(
        $States.Values |
            Where-Object { $_.ProcessId -eq $ProcessId -and $_.State -ne 'Released' }
    )
    if ($matches.Count -gt 1) {
        throw "PID $ProcessId has multiple live trace identities."
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

function ConvertFrom-CoordinatorTrace {
    param(
        [Parameter(Mandatory)]
        [string[]]$TracePaths,

        [object[]]$RunRecords = @(),

        [int]$Budget = 16,

        [switch]$RequireEmptyFinalState,

        [switch]$StrictParsing
    )

    if ($Budget -le 0) {
        throw 'Budget must be positive.'
    }
    $rawEvents = [Collections.Generic.List[object]]::new()
    $sourceOrdinal = 0
    foreach ($tracePath in $TracePaths | Sort-Object -Unique) {
        if (-not (Test-Path -LiteralPath $tracePath -PathType Leaf)) {
            throw "Coordinator trace '$tracePath' does not exist."
        }
        $sourceOrdinal++
        $lineNumber = 0
        foreach ($line in [IO.File]::ReadLines($tracePath)) {
            $lineNumber++
            $parsed = Get-TraceTimestampAndMessage -Line $line -SourcePath $tracePath -LineNumber $lineNumber
            if ($null -ne $parsed -and $parsed.Message.StartsWith('CoordinatorServer:', [StringComparison]::Ordinal)) {
                $parsed | Add-Member -NotePropertyName SourceOrdinal -NotePropertyValue $sourceOrdinal
                $rawEvents.Add($parsed)
            }
        }
    }
    $orderedEvents = @(
        $rawEvents |
            Sort-Object TimestampUtc,SourceOrdinal,LineNumber
    )
    if ($orderedEvents.Count -eq 0) {
        throw 'No timestamped CoordinatorServer events were found.'
    }

    $errors = [Collections.Generic.List[string]]::new()
    $events = [Collections.Generic.List[object]]::new()
    $timeline = [Collections.Generic.List[object]]::new()
    $states = @{}
    $generationByPid = @{}
    $knownPids = [Collections.Generic.HashSet[int]]::new()
    foreach ($run in $RunRecords) {
        $rootProcessId = Get-RunProperty -Run $run -Names @('RootProcessId', 'rootProcessId')
        if ($null -ne $rootProcessId) {
            [void]$knownPids.Add([int]$rootProcessId)
        }
    }
    $pendingLegacyNestedByThread = @{}
    $allocated = 0
    $queueDepth = 0
    $activeBuilds = 0
    $deferredOccurred = $false
    $allocationStableSince = $orderedEvents[0].TimestampUtc
    $sequence = 0

    foreach ($raw in $orderedEvents) {
        $sequence++
        $message = $raw.Message.Substring('CoordinatorServer:'.Length).Trim()
        $eventType = 'Other'
        $traceProcessId = $null
        $identity = $null
        $nodes = $null
        $priority = $null
        $nested = $false
        $stateChanging = $false
        $queueBefore = $queueDepth
        $activeBefore = $activeBuilds
        $allocatedBefore = $allocated

        if ($message -match '^Accept loop started on pipe .*?\(budget=(?<budget>\d+)') {
            $eventType = 'Accept'
            if ([int]$Matches.budget -ne $Budget) {
                $errors.Add("Trace budget $($Matches.budget) does not match expected $Budget.")
            }
        }
        elseif ($message -match '^Client requested to join grant ') {
            $eventType = 'NestedRequest'
            $threadKey = [string]$raw.ThreadKey
            if (-not $pendingLegacyNestedByThread.ContainsKey($threadKey)) {
                $pendingLegacyNestedByThread[$threadKey] = 0
            }
            $pendingLegacyNestedByThread[$threadKey]++
        }
        elseif ($message -match '^Client connected \(PID (?<pid>\d+), ConnectionId (?<connection>[^,]+), requested (?<requested>\d+) nodes(?:, priority (?<priority>[^,]+), nested=(?<nested>True|False))?\)$') {
            $traceProcessId = [int]$Matches.pid
            $priorityValue = if ($Matches.ContainsKey('priority')) { [string]$Matches['priority'] } else { '' }
            $nestedValue = if ($Matches.ContainsKey('nested')) { [string]$Matches['nested'] } else { '' }
            $priority = if ([string]::IsNullOrWhiteSpace($priorityValue)) { 'Unknown' } else { $priorityValue }
            $nested = if ([string]::IsNullOrWhiteSpace($nestedValue)) {
                $threadKey = [string]$raw.ThreadKey
                if ($pendingLegacyNestedByThread.ContainsKey($threadKey) -and
                    $pendingLegacyNestedByThread[$threadKey] -gt 0) {
                    $pendingLegacyNestedByThread[$threadKey]--
                    $true
                }
                else {
                    $false
                }
            }
            else {
                [bool]::Parse($nestedValue)
            }
            $eventType = if ($nested) { 'NestedConnected' } else { 'Connected' }
            if (-not $nested) {
                $resolved = Resolve-TraceRunIdentity -ProcessId $traceProcessId -TimestampUtc $raw.TimestampUtc -RunRecords $RunRecords
                if ($RunRecords.Count -gt 0 -and $null -eq $resolved) {
                    $eventType = 'UnmatchedConnected'
                }
                else {
                    if ($null -eq $resolved) {
                        $generation = if ($generationByPid.ContainsKey($traceProcessId)) { [int]$generationByPid[$traceProcessId] + 1 } else { 1 }
                        $generationByPid[$traceProcessId] = $generation
                        $resolved = [pscustomobject]@{ Key = "$traceProcessId|generation-$generation"; RunId = "$traceProcessId|generation-$generation" }
                    }
                    $identity = $resolved.Key
                    if ($states.ContainsKey($identity) -and $states[$identity].State -ne 'Released') {
                        $errors.Add("Duplicate live connection for '$identity'.")
                    }
                    $states[$identity] = [pscustomobject][ordered]@{
                        IdentityKey = $identity
                        RunId = $resolved.RunId
                        ProcessId = $traceProcessId
                        RequestedNodes = [int]$Matches.requested
                        Priority = $priority
                        ConnectedUtc = $raw.TimestampUtc
                        QueuedUtc = $null
                        GrantedUtc = $null
                        GrantedNodes = 0
                        State = 'Connected'
                    }
                }
            }
        }
        elseif ($message -match '^PID (?<pid>\d+) queued \(no nodes available\)$') {
            $traceProcessId = [int]$Matches.pid
            $state = Get-LiveTraceState -States $states -ProcessId $traceProcessId
            if ($null -eq $state) {
                if ($RunRecords.Count -eq 0 -or $knownPids.Contains($traceProcessId)) {
                    $errors.Add("Queued PID $traceProcessId has no live root connection.")
                }
                $eventType = 'IgnoredQueued'
            }
            elseif ($state.State -ne 'Connected') {
                $errors.Add("PID $traceProcessId queued from impossible state '$($state.State)'.")
                $eventType = 'InvalidQueued'
            }
            else {
                $eventType = 'Queued'
                $identity = $state.IdentityKey
                $state.State = 'Queued'
                $state.QueuedUtc = $raw.TimestampUtc
                $queueDepth++
                $stateChanging = $true
            }
        }
        elseif ($message -match '^Granted (?<nodes>\d+) nodes to PID (?<pid>\d+)$') {
            $traceProcessId = [int]$Matches.pid
            $nodes = [int]$Matches.nodes
            $state = Get-LiveTraceState -States $states -ProcessId $traceProcessId
            if ($null -eq $state) {
                if ($RunRecords.Count -eq 0 -or $knownPids.Contains($traceProcessId)) {
                    $errors.Add("Immediate grant for PID $traceProcessId has no live root connection.")
                }
                $eventType = 'IgnoredGrant'
            }
            elseif ($state.State -ne 'Connected') {
                $errors.Add("Immediate grant for PID $traceProcessId came from '$($state.State)'.")
                $eventType = 'InvalidGrant'
            }
            else {
                $eventType = 'Granted'
                $identity = $state.IdentityKey
                $state.State = 'Active'
                $state.GrantedUtc = $raw.TimestampUtc
                $state.GrantedNodes = $nodes
                $allocated += $nodes
                $activeBuilds++
                $stateChanging = $true
            }
        }
        elseif ($message -match '^Granting (?<nodes>\d+) deferred nodes to PID (?<pid>\d+)$') {
            $traceProcessId = [int]$Matches.pid
            $nodes = [int]$Matches.nodes
            $state = Get-LiveTraceState -States $states -ProcessId $traceProcessId
            if ($null -eq $state) {
                if ($RunRecords.Count -eq 0 -or $knownPids.Contains($traceProcessId)) {
                    $errors.Add("Deferred grant for PID $traceProcessId has no live root connection.")
                }
                $eventType = 'IgnoredDeferredGrant'
            }
            elseif ($state.State -ne 'Queued') {
                $errors.Add("Deferred grant for PID $traceProcessId came from '$($state.State)'.")
                $eventType = 'InvalidDeferredGrant'
            }
            else {
                $eventType = 'DeferredGranted'
                $identity = $state.IdentityKey
                $state.State = 'Active'
                $state.GrantedUtc = $raw.TimestampUtc
                $state.GrantedNodes = $nodes
                $queueDepth--
                $allocated += $nodes
                $activeBuilds++
                $deferredOccurred = $true
                $stateChanging = $true
            }
        }
        elseif ($message -match '^PID (?<pid>\d+) released grant$') {
            $traceProcessId = [int]$Matches.pid
            $eventType = 'Released'
            $state = Get-LiveTraceState -States $states -ProcessId $traceProcessId
            if ($null -eq $state) {
                if ($RunRecords.Count -eq 0 -or $knownPids.Contains($traceProcessId)) {
                    $errors.Add("Release for PID $traceProcessId has no live root state.")
                }
                $eventType = 'IgnoredReleased'
            }
            else {
                $identity = $state.IdentityKey
                if ($state.State -eq 'Active') {
                    $allocated -= $state.GrantedNodes
                    $activeBuilds--
                }
                elseif ($state.State -eq 'Queued') {
                    $queueDepth--
                }
                elseif ($state.State -ne 'Connected') {
                    $errors.Add("PID $traceProcessId released from impossible state '$($state.State)'.")
                }
                $state.State = 'Released'
                $stateChanging = $true
            }
        }
        elseif ($message -match '^PID (?<pid>\d+) disconnected(?: \(.*\)| while waiting)$') {
            $traceProcessId = [int]$Matches.pid
            $eventType = 'Disconnected'
            $state = Get-LiveTraceState -States $states -ProcessId $traceProcessId
            if ($null -ne $state) {
                $identity = $state.IdentityKey
                if ($state.State -eq 'Active') {
                    $allocated -= $state.GrantedNodes
                    $activeBuilds--
                }
                elseif ($state.State -eq 'Queued') {
                    $queueDepth--
                }
                $state.State = 'Released'
                $stateChanging = $true
            }
            elseif ($RunRecords.Count -eq 0 -or $knownPids.Contains($traceProcessId)) {
                $errors.Add("Disconnect for PID $traceProcessId has no live root state.")
            }
            else {
                $eventType = 'IgnoredDisconnected'
            }
        }
        elseif ($message -match '^Reclaiming grant from dead PID (?<pid>\d+)$') {
            $traceProcessId = [int]$Matches.pid
            $eventType = 'Reclaimed'
            $state = Get-LiveTraceState -States $states -ProcessId $traceProcessId
            if ($null -eq $state) {
                if ($RunRecords.Count -eq 0 -or $knownPids.Contains($traceProcessId)) {
                    $errors.Add("Reclaim for PID $traceProcessId has no live root state.")
                }
                $eventType = 'IgnoredReclaimed'
            }
            else {
                $identity = $state.IdentityKey
                if ($state.State -eq 'Active') {
                    $allocated -= $state.GrantedNodes
                    $activeBuilds--
                }
                elseif ($state.State -eq 'Queued') {
                    $queueDepth--
                }
                $state.State = 'Released'
                $stateChanging = $true
            }
        }
        elseif ($StrictParsing -and
            $message -match '(Client connected| queued |Granted \d+|Granting \d+|released grant|disconnected|Reclaiming)') {
            $errors.Add("Unrecognized state-bearing trace line: '$message'.")
        }

        if ($queueDepth -lt 0 -or $activeBuilds -lt 0 -or $allocated -lt 0) {
            $errors.Add("Negative state after trace sequence $sequence.")
        }
        if ($allocated -gt $Budget) {
            $errors.Add("Allocated nodes $allocated exceed budget $Budget after trace sequence $sequence.")
        }
        if ($allocated -ne $allocatedBefore) {
            $allocationStableSince = $raw.TimestampUtc
        }
        $event = [pscustomobject][ordered]@{
            Sequence = $sequence
            TimestampUtc = $raw.TimestampUtc.ToString('O')
            Event = $eventType
            ProcessId = $traceProcessId
            IdentityKey = $identity
            Priority = $priority
            Nodes = $nodes
            QueueDepthBefore = $queueBefore
            ActiveBuildsBefore = $activeBefore
            AllocatedNodesBefore = $allocatedBefore
            QueueDepth = $queueDepth
            ActiveBuilds = $activeBuilds
            AllocatedNodes = $allocated
            SourcePath = $raw.SourcePath
            LineNumber = $raw.LineNumber
            Message = $message
        }
        $events.Add($event)
        if ($stateChanging -or $eventType -eq 'Accept') {
            $timeline.Add($event)
        }
    }

    if ($RequireEmptyFinalState -and ($queueDepth -ne 0 -or $activeBuilds -ne 0 -or $allocated -ne 0)) {
        $errors.Add("Final trace state is not quiescent (queue=$queueDepth, active=$activeBuilds, allocated=$allocated).")
    }
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        TracePaths = $TracePaths
        Budget = $Budget
        Consistent = $errors.Count -eq 0
        Errors = $errors.ToArray()
        DeferredGrantOccurred = $deferredOccurred
        FinalQueueDepth = $queueDepth
        FinalActiveBuilds = $activeBuilds
        FinalAllocatedNodes = $allocated
        AllocationStableSinceUtc = $allocationStableSince.ToString('O')
        Events = $events.ToArray()
        Timeline = $timeline.ToArray()
        RootStates = @($states.Values)
    }
}

function Get-WeightedPercentile {
    param(
        [Parameter(Mandatory)]
        [object[]]$Segments,

        [Parameter(Mandatory)]
        [double]$Percentile,

        [Parameter(Mandatory)]
        [string]$ValueProperty
    )

    $total = ($Segments.DurationSeconds | Measure-Object -Sum).Sum
    if ($null -eq $total -or $total -le 0) {
        return 0.0
    }
    $target = $total * $Percentile
    $accumulated = 0.0
    foreach ($segment in $Segments | Sort-Object $ValueProperty) {
        $accumulated += [double]$segment.DurationSeconds
        if ($accumulated -ge $target) {
            return [double]$segment.$ValueProperty
        }
    }
    return [double](($Segments | Sort-Object $ValueProperty | Select-Object -Last 1).$ValueProperty)
}

function Get-TraceWindowMetrics {
    param(
        [Parameter(Mandatory)]
        [object[]]$Timeline,

        [Parameter(Mandatory)]
        [DateTime]$StartUtc,

        [Parameter(Mandatory)]
        [DateTime]$EndUtc,

        [int]$Budget = 16,

        [int]$ReservedNodes = 0
    )

    $start = $StartUtc.ToUniversalTime()
    $end = $EndUtc.ToUniversalTime()
    if ($end -le $start) {
        throw 'Trace metric window end must be after start.'
    }
    $ordered = @($Timeline | Sort-Object { [DateTime]$_.TimestampUtc }, Sequence)
    $state = [pscustomobject]@{ QueueDepth = 0; ActiveBuilds = 0; AllocatedNodes = 0 }
    foreach ($row in $ordered) {
        if (([DateTime]$row.TimestampUtc).ToUniversalTime() -le $start) {
            $state = $row
        }
        else {
            break
        }
    }
    $segments = [Collections.Generic.List[object]]::new()
    $cursor = $start
    foreach ($row in $ordered) {
        $timestamp = ([DateTime]$row.TimestampUtc).ToUniversalTime()
        if ($timestamp -le $start) {
            continue
        }
        if ($timestamp -ge $end) {
            break
        }
        $duration = ($timestamp - $cursor).TotalSeconds
        if ($duration -gt 0) {
            $segments.Add([pscustomobject]@{
                StartUtc = $cursor.ToString('O')
                EndUtc = $timestamp.ToString('O')
                DurationSeconds = $duration
                QueueDepth = [int]$state.QueueDepth
                ActiveBuilds = [int]$state.ActiveBuilds
                AllocatedNodes = [int]$state.AllocatedNodes
            })
        }
        $cursor = $timestamp
        $state = $row
    }
    if ($cursor -lt $end) {
        $segments.Add([pscustomobject]@{
            StartUtc = $cursor.ToString('O')
            EndUtc = $end.ToString('O')
            DurationSeconds = ($end - $cursor).TotalSeconds
            QueueDepth = [int]$state.QueueDepth
            ActiveBuilds = [int]$state.ActiveBuilds
            AllocatedNodes = [int]$state.AllocatedNodes
        })
    }
    $windowSeconds = ($end - $start).TotalSeconds
    $queueNonemptySeconds = 0.0
    $unusedNodeSeconds = 0.0
    $reservedIdleNodeSeconds = 0.0
    foreach ($segment in $segments) {
        if ($segment.QueueDepth -gt 0) {
            $queueNonemptySeconds += $segment.DurationSeconds
        }
        $unused = [Math]::Max(0, $Budget - $segment.AllocatedNodes)
        $unusedNodeSeconds += $unused * $segment.DurationSeconds
        $reservedIdleNodeSeconds += [Math]::Min($ReservedNodes, $unused) * $segment.DurationSeconds
    }
    [pscustomobject][ordered]@{
        StartUtc = $start.ToString('O')
        EndUtc = $end.ToString('O')
        WindowSeconds = $windowSeconds
        QueueNonemptySeconds = $queueNonemptySeconds
        QueueNonemptyFraction = $queueNonemptySeconds / $windowSeconds
        QueueDepthP50 = Get-WeightedPercentile -Segments $segments.ToArray() -Percentile 0.50 -ValueProperty QueueDepth
        QueueDepthP95 = Get-WeightedPercentile -Segments $segments.ToArray() -Percentile 0.95 -ValueProperty QueueDepth
        QueueDepthMaximum = ($segments.QueueDepth | Measure-Object -Maximum).Maximum
        ActiveBuildsMaximum = ($segments.ActiveBuilds | Measure-Object -Maximum).Maximum
        AllocatedNodesMaximum = ($segments.AllocatedNodes | Measure-Object -Maximum).Maximum
        UnusedNodeSeconds = $unusedNodeSeconds
        ReservedIdleNodeSeconds = $reservedIdleNodeSeconds
        Segments = $segments.ToArray()
    }
}

function Get-SemanticSaturationState {
    param(
        [Parameter(Mandatory)]
        [object[]]$Timeline,

        [Parameter(Mandatory)]
        [DateTime]$NowUtc,

        [Parameter(Mandatory)]
        [int]$ExpectedAllocation,

        [int]$MinimumQueueDepth = 2,

        [double]$HandoffGapToleranceSeconds = 1
    )

    if ($HandoffGapToleranceSeconds -le 0) {
        throw 'Handoff gap tolerance must be positive.'
    }
    $ordered = @($Timeline | Sort-Object { [DateTime]$_.TimestampUtc }, Sequence)
    $continuousStart = $null
    $handoffStart = $null
    $handoffEligible = $false
    $bridgedHandoffs = 0
    $resetCount = 0
    $allowedHandoffEvents = @('Released', 'DeferredGranted')
    foreach ($row in $ordered) {
        $timestamp = ([DateTime]$row.TimestampUtc).ToUniversalTime()
        if ($timestamp -gt $NowUtc.ToUniversalTime()) {
            break
        }
        $allocation = [int]$row.AllocatedNodes
        $queue = [int]$row.QueueDepth
        $isExpectedAndQueued =
            $allocation -eq $ExpectedAllocation -and $queue -ge $MinimumQueueDepth
        if ($isExpectedAndQueued) {
            if ($null -ne $handoffStart) {
                $handoffSeconds = ($timestamp - $handoffStart).TotalSeconds
                if ($handoffEligible -and $handoffSeconds -le $HandoffGapToleranceSeconds) {
                    $bridgedHandoffs++
                }
                else {
                    $continuousStart = $timestamp
                    $resetCount++
                }
                $handoffStart = $null
                $handoffEligible = $false
            }
            elseif ($null -eq $continuousStart) {
                $continuousStart = $timestamp
            }
            continue
        }

        if ($null -eq $continuousStart) {
            continue
        }
        if ($queue -lt $MinimumQueueDepth -or $allocation -gt $ExpectedAllocation) {
            $continuousStart = $null
            $handoffStart = $null
            $handoffEligible = $false
            $resetCount++
            continue
        }
        if ($allocation -lt $ExpectedAllocation) {
            if ($null -eq $handoffStart) {
                $handoffStart = $timestamp
                $handoffEligible = $row.Event -eq 'Released'
            }
            elseif ($row.Event -notin $allowedHandoffEvents) {
                $handoffEligible = $false
            }
            if (($timestamp - $handoffStart).TotalSeconds -gt $HandoffGapToleranceSeconds) {
                $continuousStart = $null
                $handoffStart = $null
                $handoffEligible = $false
                $resetCount++
            }
        }
    }

    $activeHandoffSeconds = if ($null -eq $handoffStart) {
        0.0
    }
    else {
        ($NowUtc.ToUniversalTime() - $handoffStart).TotalSeconds
    }
    if ($null -ne $handoffStart -and $activeHandoffSeconds -gt $HandoffGapToleranceSeconds) {
        $continuousStart = $null
        $handoffStart = $null
        $handoffEligible = $false
        $resetCount++
    }
    $eligibleLatest = @($ordered | Where-Object {
        ([DateTime]$_.TimestampUtc).ToUniversalTime() -le $NowUtc.ToUniversalTime()
    })
    $latest = if ($eligibleLatest.Count -eq 0) {
        [pscustomobject]@{ AllocatedNodes = 0; QueueDepth = 0 }
    }
    else {
        $eligibleLatest[-1]
    }
    $currentExpectedAndQueued =
        [int]$latest.AllocatedNodes -eq $ExpectedAllocation -and
        [int]$latest.QueueDepth -ge $MinimumQueueDepth
    [pscustomobject][ordered]@{
        SemanticallySaturated = $null -ne $continuousStart -and
            $null -eq $handoffStart -and $currentExpectedAndQueued
        ContinuousStartUtc = if ($null -eq $continuousStart) { $null } else { $continuousStart.ToString('O') }
        ContinuousSeconds = if ($null -eq $continuousStart) {
            0.0
        }
        else {
            ($NowUtc.ToUniversalTime() - $continuousStart).TotalSeconds
        }
        CurrentAllocatedNodes = [int]$latest.AllocatedNodes
        CurrentQueueDepth = [int]$latest.QueueDepth
        ExpectedAllocation = $ExpectedAllocation
        MinimumQueueDepth = $MinimumQueueDepth
        HandoffGapToleranceSeconds = $HandoffGapToleranceSeconds
        ActiveHandoffSeconds = $activeHandoffSeconds
        BridgedHandoffCount = $bridgedHandoffs
        ResetCount = $resetCount
    }
}

function Test-SteadyOnsetState {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Trace,

        [Parameter(Mandatory)]
        [DateTime]$NowUtc,

        [Parameter(Mandatory)]
        [int]$ExpectedAllocation,

        [int]$MinimumQueueDepth = 2,

        [int]$StableSeconds = 30,

        [double]$HandoffGapToleranceSeconds = 1
    )

    $saturation = Get-SemanticSaturationState `
        -Timeline $Trace.Timeline `
        -NowUtc $NowUtc `
        -ExpectedAllocation $ExpectedAllocation `
        -MinimumQueueDepth $MinimumQueueDepth `
        -HandoffGapToleranceSeconds $HandoffGapToleranceSeconds
    [pscustomobject][ordered]@{
        Accepted = $Trace.Consistent -and
            $Trace.DeferredGrantOccurred -and
            $saturation.SemanticallySaturated -and
            $saturation.ContinuousSeconds -ge $StableSeconds
        DeferredGrantOccurred = $Trace.DeferredGrantOccurred
        QueueDepth = $saturation.CurrentQueueDepth
        AllocatedNodes = $saturation.CurrentAllocatedNodes
        ExpectedAllocation = $ExpectedAllocation
        AllocationStableSeconds = $saturation.ContinuousSeconds
        SemanticSaturationStartUtc = $saturation.ContinuousStartUtc
        HandoffGapToleranceSeconds = $saturation.HandoffGapToleranceSeconds
        BridgedHandoffCount = $saturation.BridgedHandoffCount
        SaturationResetCount = $saturation.ResetCount
    }
}

function Export-CoordinatorTraceResult {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Trace,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    $Trace.Events | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $DestinationRoot 'events.csv')
    $Trace.Timeline | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $DestinationRoot 'timeline.csv')
    $summary = [pscustomobject][ordered]@{
        SchemaVersion = $Trace.SchemaVersion
        TracePaths = $Trace.TracePaths
        Budget = $Trace.Budget
        Consistent = $Trace.Consistent
        Errors = $Trace.Errors
        DeferredGrantOccurred = $Trace.DeferredGrantOccurred
        FinalQueueDepth = $Trace.FinalQueueDepth
        FinalActiveBuilds = $Trace.FinalActiveBuilds
        FinalAllocatedNodes = $Trace.FinalAllocatedNodes
        AllocationStableSinceUtc = $Trace.AllocationStableSinceUtc
        RootStates = $Trace.RootStates
        EventCount = $Trace.Events.Count
        TimelineRowCount = $Trace.Timeline.Count
    }
    $summary | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $DestinationRoot 'summary.json') -Encoding utf8
    return $summary
}
