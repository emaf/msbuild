Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:SustainedParentToolingRoot = Split-Path -Parent $PSScriptRoot
if ($null -eq (Get-Command Write-JsonAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SustainedParentToolingRoot 'Campaign.Common.ps1')
}

function Get-CampaignDefinition {
    [pscustomobject][ordered]@{
        SchemaVersion = 2
        Name = 'dotnet-msbuild-pr14241-current-vs-final-sustained'
        Design = 'Approved fixed-window sustained-only representative project campaign'
        WorkloadDeviation = 'Pinned representative propagated project workloads are used; historical campaigns and product files are not modified or pooled.'
        NodeBudget = 16
        HardTimeoutHours = 8
        Base = [pscustomobject][ordered]@{
            Key = 'BASE'
            Repository = 'https://github.com/dotnet/msbuild'
            Commit = 'ff5b281f0c5828dec0d092fcd1b682019de7d1ca'
        }
        Final = [pscustomobject][ordered]@{
            Key = 'FINAL'
            Repository = 'https://github.com/emaf/msbuild'
            Branch = 'coordinator-priorities'
            Commit = '432466e41a95f9bbb25cad7ff9bd1b89b4a6bcef'
        }
        Repositories = @(
            [pscustomobject][ordered]@{
                Name = 'roslyn'
                Repository = 'https://github.com/dotnet/roslyn'
                Root = 'C:\perf\repos\current-vs-final\roslyn'
                Commit = 'bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b'
                WorkRoot = 'C:\w\cvf\r'
                BuildPath = 'src\Compilers\CSharp\Portable\Microsoft.CodeAnalysis.CSharp.csproj'
                TouchPath = 'src\Compilers\CSharp\Portable\CSharpCompilationOptions.cs'
                AdditionalBuildArguments = @()
            },
            [pscustomobject][ordered]@{
                Name = 'aspire'
                Repository = 'https://github.com/dotnet/aspire'
                Root = 'C:\perf\repos\current-vs-final\aspire'
                Commit = '110a63da8357af437a00d9efc5887ffdcbdfbb3c'
                WorkRoot = 'C:\w\cvf\a'
                BuildPath = 'src\Aspire.Hosting\Aspire.Hosting.csproj'
                TouchPath = 'src\Aspire.Hosting\DistributedApplication.cs'
                AdditionalBuildArguments = @('/p:InstallBrowsersForPlaywright=false')
            }
        )
        Conditions = @(
            [pscustomobject][ordered]@{
                Key = 'BASE'
                BootstrapRole = 'base'
                Reservation = $null
                MaximumNodes = $null
                NormalPriorityValue = $null
                Description = 'Unchanged BASE Coordinator defaults with policy variables absent.'
            },
            [pscustomobject][ordered]@{
                Key = 'FINAL-N'
                BootstrapRole = 'final'
                Reservation = $null
                MaximumNodes = $null
                NormalPriorityValue = 'Normal'
                Description = 'Approved FINAL computed defaults with every request encoded Normal.'
            },
            [pscustomobject][ordered]@{
                Key = 'FINAL-H'
                BootstrapRole = 'final'
                Reservation = $null
                MaximumNodes = $null
                NormalPriorityValue = 'Normal'
                Description = 'Approved FINAL computed defaults with only the minute-four probe encoded High.'
            }
        )
        Shapes = @(
            [pscustomobject][ordered]@{
                Key = 'sustained'
                Conditions = @('BASE', 'FINAL-N', 'FINAL-H')
                WarmupBlocks = 1
                MeasuredBlocks = 3
                Seed = 20260813
                MinimumAvailableMB = 16384
            }
        )
        Validity = [pscustomobject][ordered]@{
            InitialDiskSafetyGiB = 20
            RawResultsReserveGiB = 25
            SystemSampleSeconds = 1
            ProcessSampleSeconds = 5
            ProbeSampleSeconds = 5
            SystemGapWarningSeconds = 5
            SystemGapHardSeconds = 30
            ProcessGapHardSeconds = 15
            ProbeGapHardSeconds = 15
            GrantTimestampCrossCheckMaximumSeconds = 5
            IdleConsecutiveSamples = 3
            IdleSampleSeconds = 2
            IdleCpuMaximumPercent = 20
            IdleQueueMaximum = 2
            IdleTimeoutSeconds = 300
            CooldownSeconds = 30
            MaximumBlockAttempts = 2
            InitialWorkerCount = 8
            EscalatedWorkerCount = 10
            OnsetQueueContinuousSeconds = 30
            OnsetTimeoutMinutes = 15
            MeasuredWindowSeconds = 480
            InjectionOffsetSeconds = 240
            InjectionTimingToleranceSeconds = 2
            QueueNonemptyFractionMinimum = 0.90
            MinimumMeasuredNormalCompletions = 2
            MinimumNormalCompletionsPerHalf = 1
            DrainTimeoutMinutes = 10
            FinalMaximumGrantNodes = 4
            PromptReserveNodesToObserve = 4
            MaxKnownExternalNoiseCpuCoreFraction = 0.10
            MaxKnownExternalNoiseWorkingSetBytes = 4GB
        }
    }
}

function Get-SustainedConditionKeys {
    return @('BASE', 'FINAL-N', 'FINAL-H')
}

function Get-SustainedSelectedWorktreeNames {
    param(
        [ValidateSet(8, 10)]
        [int]$WorkerCount
    )

    return @((1..$WorkerCount | ForEach-Object { "normal$_" }) + @('injected'))
}

function Get-ShapeWorktreeNames {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('sustained')]
        [string]$Shape,

        [ValidateSet(8, 10)]
        [int]$WorkerCount = 10
    )

    return @(Get-SustainedSelectedWorktreeNames -WorkerCount $WorkerCount)
}

function Get-SustainedMeasuredOrders {
    return @(
        [pscustomobject][ordered]@{
            DesignRow = 1
            Items = @('BASE', 'FINAL-N', 'FINAL-H')
        },
        [pscustomobject][ordered]@{
            DesignRow = 2
            Items = @('FINAL-N', 'FINAL-H', 'BASE')
        },
        [pscustomobject][ordered]@{
            DesignRow = 3
            Items = @('FINAL-H', 'BASE', 'FINAL-N')
        }
    )
}

function New-SustainedCampaignPlan {
    $campaign = Get-CampaignDefinition
    $orders = @(Get-SustainedMeasuredOrders)
    $warmup = $orders[0]
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($repository in $campaign.Repositories) {
        for ($position = 0; $position -lt $warmup.Items.Count; $position++) {
            $rows.Add([pscustomobject][ordered]@{
                Shape = 'sustained'
                Repository = $repository.Name
                BlockNumber = 1
                AnalysisBlockNumber = 0
                IsWarmup = $true
                DesignRow = $warmup.DesignRow
                OrderIndex = $position + 1
                Condition = $warmup.Items[$position]
            })
        }
        for ($orderIndex = 0; $orderIndex -lt $orders.Count; $orderIndex++) {
            $order = $orders[$orderIndex]
            for ($position = 0; $position -lt $order.Items.Count; $position++) {
                $rows.Add([pscustomobject][ordered]@{
                    Shape = 'sustained'
                    Repository = $repository.Name
                    BlockNumber = $orderIndex + 2
                    AnalysisBlockNumber = $orderIndex + 1
                    IsWarmup = $false
                    DesignRow = $order.DesignRow
                    OrderIndex = $position + 1
                    Condition = $order.Items[$position]
                })
            }
        }
    }
    $diagnostics = Get-OrderDiagnostics `
        -Orders $orders `
        -Items ([string[]](Get-SustainedConditionKeys))
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        Rows = $rows.ToArray()
        Diagnostics = [pscustomobject][ordered]@{
            MeasuredOrders = $orders
            PositionCounts = $diagnostics.PositionCounts
            CarryoverCounts = $diagnostics.CarryoverCounts
            PositionImbalance = $diagnostics.PositionImbalance
            PositionBalanced = $diagnostics.PositionImbalance -eq 0
            CarryoverImbalance = $diagnostics.CarryoverImbalance
            CarryoverBalanced = $false
            CarryoverDeclaration = 'The approved three-row rotation is exactly position-balanced and explicitly carryover-unbalanced; only BASE->FINAL-N, FINAL-N->FINAL-H, and FINAL-H->BASE transitions occur.'
            WarmupOrder = @($warmup.Items)
            WarmupExcluded = $true
        }
    }
}

function Test-SustainedCampaignPlan {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Plan
    )

    $errors = [Collections.Generic.List[string]]::new()
    $campaign = Get-CampaignDefinition
    $conditions = @(Get-SustainedConditionKeys)
    $expectedRows =
        $campaign.Repositories.Count *
        ($campaign.Shapes[0].WarmupBlocks + $campaign.Shapes[0].MeasuredBlocks) *
        $conditions.Count
    if (@($Plan.Rows).Count -ne $expectedRows) {
        $errors.Add("Plan has $(@($Plan.Rows).Count) rows; expected $expectedRows.")
    }
    foreach ($repository in $campaign.Repositories) {
        $repositoryRows = @($Plan.Rows | Where-Object Repository -eq $repository.Name)
        $blocks = @($repositoryRows.BlockNumber | Sort-Object -Unique)
        if (($blocks -join ',') -ne '1,2,3,4') {
            $errors.Add("$($repository.Name) block numbers are '$($blocks -join ',')'; expected 1,2,3,4.")
            continue
        }
        $expectedOrders = @(
            'BASE,FINAL-N,FINAL-H',
            'BASE,FINAL-N,FINAL-H',
            'FINAL-N,FINAL-H,BASE',
            'FINAL-H,BASE,FINAL-N'
        )
        for ($index = 0; $index -lt $blocks.Count; $index++) {
            $actual = @(
                $repositoryRows |
                    Where-Object BlockNumber -eq $blocks[$index] |
                    Sort-Object OrderIndex |
                    Select-Object -ExpandProperty Condition
            ) -join ','
            if ($actual -ne $expectedOrders[$index]) {
                $errors.Add("$($repository.Name) block $($blocks[$index]) order '$actual' does not match '$($expectedOrders[$index])'.")
            }
        }
        $warmupRows = @($repositoryRows | Where-Object IsWarmup)
        if ($warmupRows.Count -ne 3 -or
            @($warmupRows.AnalysisBlockNumber | Sort-Object -Unique) -ne 0) {
            $errors.Add("$($repository.Name) does not have one declared, excluded complete warmup block.")
        }
    }
    if (-not [bool]$Plan.Diagnostics.PositionBalanced -or
        [int]$Plan.Diagnostics.PositionImbalance -ne 0) {
        $errors.Add('Measured plan is not exactly position-balanced.')
    }
    if ([bool]$Plan.Diagnostics.CarryoverBalanced -or
        [int]$Plan.Diagnostics.CarryoverImbalance -le 0 -or
        [string]::IsNullOrWhiteSpace([string]$Plan.Diagnostics.CarryoverDeclaration)) {
        $errors.Add('Measured carryover imbalance is not explicitly declared.')
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        ExpectedRows = $expectedRows
        ActualRows = @($Plan.Rows).Count
        PositionBalanced = [bool]$Plan.Diagnostics.PositionBalanced
        CarryoverBalanced = [bool]$Plan.Diagnostics.CarryoverBalanced
        CarryoverDeclaration = [string]$Plan.Diagnostics.CarryoverDeclaration
    }
}

function Get-SustainedWindowTiming {
    param(
        [Parameter(Mandatory)]
        [DateTimeOffset]$OnsetUtc
    )

    $validity = (Get-CampaignDefinition).Validity
    $start = $OnsetUtc.ToUniversalTime()
    [pscustomobject][ordered]@{
        WindowStartUtc = $start.ToString('O')
        InjectionDueUtc = $start.AddSeconds(
            [int]$validity.InjectionOffsetSeconds).ToString('O')
        SubmissionStopUtc = $start.AddSeconds(
            [int]$validity.MeasuredWindowSeconds).ToString('O')
        WindowSeconds = [int]$validity.MeasuredWindowSeconds
        InjectionOffsetSeconds = [int]$validity.InjectionOffsetSeconds
        FixedWindow = $true
    }
}

function Get-SustainedWorkerSizingResponse {
    param(
        [ValidateSet(8, 10)]
        [int]$WorkerCount,

        [Parameter(Mandatory)]
        [bool]$QueueCriterionPassed
    )

    if ($QueueCriterionPassed) {
        return [pscustomobject][ordered]@{
            Status = 'Ready'
            WorkerCount = $WorkerCount
            FrozenWorkerCount = $WorkerCount
            NextWorkerCount = $null
            RerunAllPilots = $false
        }
    }
    if ($WorkerCount -eq 8) {
        return [pscustomobject][ordered]@{
            Status = 'WorkerCountIncreaseRequired'
            WorkerCount = 8
            FrozenWorkerCount = $null
            NextWorkerCount = 10
            RerunAllPilots = $true
        }
    }
    [pscustomobject][ordered]@{
        Status = 'QueueCriterionFailedAtFrozenMaximum'
        WorkerCount = 10
        FrozenWorkerCount = $null
        NextWorkerCount = $null
        RerunAllPilots = $false
    }
}

function Test-SustainedCampaignDeadline {
    param(
        [Parameter(Mandatory)]
        [DateTimeOffset]$StartedUtc,

        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    $deadline = $StartedUtc.ToUniversalTime().AddHours(
        [double](Get-CampaignDefinition).HardTimeoutHours)
    [pscustomobject][ordered]@{
        StartedUtc = $StartedUtc.ToUniversalTime().ToString('O')
        DeadlineUtc = $deadline.ToString('O')
        NowUtc = $NowUtc.ToUniversalTime().ToString('O')
        RemainingSeconds = ($deadline - $NowUtc.ToUniversalTime()).TotalSeconds
        Expired = $NowUtc.ToUniversalTime() -ge $deadline
        HardTimeoutHours = [double](Get-CampaignDefinition).HardTimeoutHours
    }
}

function Get-SustainedQueueContinuity {
    param(
        [Parameter(Mandatory)]
        [object[]]$Timeline,

        [Parameter(Mandatory)]
        [DateTimeOffset]$NowUtc
    )

    $ordered = @(
        $Timeline |
            Where-Object {
                (ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc) -le
                    $NowUtc.ToUniversalTime()
            } |
            Sort-Object { ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc }, Sequence
    )
    $queueDepth = 0
    $continuousStart = $null
    foreach ($row in $ordered) {
        $timestamp = ConvertTo-UtcDateTimeOffset -Value $row.TimestampUtc
        $nextDepth = [int]$row.QueueDepth
        if ($queueDepth -le 0 -and $nextDepth -gt 0) {
            $continuousStart = $timestamp
        }
        elseif ($nextDepth -le 0) {
            $continuousStart = $null
        }
        $queueDepth = $nextDepth
    }
    [pscustomobject][ordered]@{
        QueueDepth = $queueDepth
        QueueNonempty = $queueDepth -gt 0
        ContinuousStartUtc = if ($null -eq $continuousStart) {
            $null
        }
        else {
            $continuousStart.ToString('O')
        }
        ContinuousSeconds = if ($null -eq $continuousStart) {
            0.0
        }
        else {
            ($NowUtc.ToUniversalTime() - $continuousStart).TotalSeconds
        }
    }
}

function Test-SustainedWindowOnset {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Trace,

        [Parameter(Mandatory)]
        [object[]]$RunRecords,

        [Parameter(Mandatory)]
        [int]$InitialNormalCompletionCount,

        [Parameter(Mandatory)]
        [DateTimeOffset]$NowUtc
    )

    $validity = (Get-CampaignDefinition).Validity
    $normalIds = @(
        $RunRecords |
            Where-Object Kind -eq 'normal' |
            Select-Object -ExpandProperty RunId
    )
    $activeNormals = @(
        $Trace.RootStates |
            Where-Object {
                $_.State -eq 'Active' -and $normalIds -contains $_.RunId
            }
    )
    $waitingNormals = @(
        $Trace.RootStates |
            Where-Object {
                $_.State -eq 'Queued' -and $normalIds -contains $_.RunId
            }
    )
    $continuity = Get-SustainedQueueContinuity `
        -Timeline $Trace.Timeline `
        -NowUtc $NowUtc
    $accepted =
        $Trace.Consistent -and
        $InitialNormalCompletionCount -ge 1 -and
        $Trace.DeferredGrantOccurred -and
        $activeNormals.Count -ge 1 -and
        $waitingNormals.Count -ge 1 -and
        $continuity.QueueNonempty -and
        $continuity.ContinuousSeconds -ge
            [double]$validity.OnsetQueueContinuousSeconds
    [pscustomobject][ordered]@{
        Accepted = $accepted
        TraceConsistent = [bool]$Trace.Consistent
        InitialNormalCompletionCount = $InitialNormalCompletionCount
        DeferredGrantOccurred = [bool]$Trace.DeferredGrantOccurred
        ActiveNormalCount = $activeNormals.Count
        WaitingNormalCount = $waitingNormals.Count
        QueueDepth = $continuity.QueueDepth
        QueueNonemptyContinuousSeconds = $continuity.ContinuousSeconds
        RequiredQueueNonemptyContinuousSeconds =
            [int]$validity.OnsetQueueContinuousSeconds
        QueueNonemptyContinuousStartUtc = $continuity.ContinuousStartUtc
    }
}

function Get-SustainedInjectionState {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Trace,

        [Parameter(Mandatory)]
        [object[]]$RunRecords
    )

    $normalIds = @(
        $RunRecords |
            Where-Object Kind -eq 'normal' |
            Select-Object -ExpandProperty RunId
    )
    $activeNormals = @(
        $Trace.RootStates |
            Where-Object {
                $_.State -eq 'Active' -and $normalIds -contains $_.RunId
            }
    )
    $waitingNormals = @(
        $Trace.RootStates |
            Where-Object {
                $_.State -eq 'Queued' -and $normalIds -contains $_.RunId
            }
    )
    [pscustomobject][ordered]@{
        Valid = $Trace.Consistent -and
            $activeNormals.Count -ge 1 -and
            $waitingNormals.Count -ge 1
        ActiveNormalCount = $activeNormals.Count
        WaitingNormalCount = $waitingNormals.Count
        ActiveNormalRunIds = @($activeNormals.RunId)
        WaitingNormalRunIds = @($waitingNormals.RunId)
        QueueDepth = [int]$Trace.FinalQueueDepth
        ActiveBuilds = [int]$Trace.FinalActiveBuilds
        AllocatedNodes = [int]$Trace.FinalAllocatedNodes
    }
}

function Get-SustainedWindowSampleSummary {
    param(
        [Parameter(Mandatory)]
        [object[]]$Samples
    )

    $queueNonempty = @($Samples | Where-Object { [int]$_.QueueDepth -gt 0 })
    [pscustomobject][ordered]@{
        SampleCount = $Samples.Count
        QueueNonemptySampleCount = $queueNonempty.Count
        QueueNonemptySampleFraction = if ($Samples.Count -eq 0) {
            0.0
        }
        else {
            [double]$queueNonempty.Count / [double]$Samples.Count
        }
        ActiveAndWaitingSampleCount = @(
            $Samples |
                Where-Object {
                    [int]$_.ActiveNormalCount -ge 1 -and
                    [int]$_.WaitingNormalCount -ge 1
                }
        ).Count
    }
}

function Test-SustainedDebugEnvironmentParity {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$NormalEnvironment,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$InjectedEnvironment,

        [Parameter(Mandatory)]
        [string]$Condition
    )

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'MSBUILDUSECOORDINATOR',
        'MSBUILDCOORDINATORPIPENAME',
        'MSBUILDCOORDINATORNODEBUDGET',
        'MSBUILDDEBUGCOMM',
        'MSBUILDDEBUGPATH',
        'DOTNET_ROOT',
        'DOTNET_ROOT_X64'
    )) {
        if ($NormalEnvironment[$name] -ne $InjectedEnvironment[$name]) {
            $errors.Add("$name differs between Normal and injected requests.")
        }
    }
    if ($NormalEnvironment['MSBUILDDEBUGCOMM'] -ne '1' -or
        [string]::IsNullOrWhiteSpace(
            [string]$NormalEnvironment['MSBUILDDEBUGPATH'])) {
        $errors.Add('Coordinator debug tracing is not identically enabled.')
    }
    $normalPriority =
        $NormalEnvironment['MSBUILDCOORDINATORBUILDREQUESTPRIORITY']
    $injectedPriority =
        $InjectedEnvironment['MSBUILDCOORDINATORBUILDREQUESTPRIORITY']
    if ($Condition -eq 'BASE') {
        if ($null -ne $normalPriority -or $null -ne $injectedPriority) {
            $errors.Add('BASE priority must remain absent for both requests.')
        }
    }
    elseif ($Condition -eq 'FINAL-N') {
        if ($normalPriority -ne 'Normal' -or $injectedPriority -ne 'Normal') {
            $errors.Add('FINAL-N must encode both requests Normal.')
        }
    }
    elseif ($normalPriority -ne 'Normal' -or $injectedPriority -ne 'High') {
        $errors.Add('FINAL-H must encode only the injected request High.')
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        DebugPath = $NormalEnvironment['MSBUILDDEBUGPATH']
        PipeName = $NormalEnvironment['MSBUILDCOORDINATORPIPENAME']
        NormalPriority = $normalPriority
        InjectedPriority = $injectedPriority
    }
}

function Get-SustainedEnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [object[]]$EnvironmentRecord,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $entry = $EnvironmentRecord |
        Where-Object Name -eq $Name |
        Select-Object -First 1
    if ($null -eq $entry -or -not [bool]$entry.Present) {
        return $null
    }
    return [string]$entry.Value
}

function Test-SustainedGrantPolicyEvidence {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('BASE', 'FINAL-N', 'FINAL-H')]
        [string]$Condition,

        [Parameter(Mandatory)]
        [object[]]$RunRecords,

        [Parameter(Mandatory)]
        [object[]]$GrantMetrics,

        [Parameter(Mandatory)]
        [pscustomobject]$Trace,

        [string]$InjectionRunId = 'injected-g1',

        [DateTimeOffset]$MeasurementStartUtc = [DateTimeOffset]::MinValue
    )

    $errors = [Collections.Generic.List[string]]::new()
    $validity = (Get-CampaignDefinition).Validity
    $injectedRun = $RunRecords |
        Where-Object RunId -eq $InjectionRunId |
        Select-Object -First 1
    $injectedState = $Trace.RootStates |
        Where-Object RunId -eq $InjectionRunId |
        Select-Object -First 1
    $connectedEvent = if ($null -eq $injectedState) {
        $null
    }
    else {
        $Trace.Events |
            Where-Object {
                $_.Event -eq 'Connected' -and
                $_.IdentityKey -eq $injectedState.IdentityKey
            } |
            Select-Object -First 1
    }
    $grantEvent = if ($null -eq $injectedState) {
        $null
    }
    else {
        $Trace.Events |
            Where-Object {
                $_.Event -in @('Granted', 'DeferredGranted') -and
                $_.IdentityKey -eq $injectedState.IdentityKey
            } |
            Select-Object -First 1
    }
    $injectedMetric = $GrantMetrics |
        Where-Object RunId -eq $InjectionRunId |
        Select-Object -First 1
    if ($null -eq $injectedRun -or
        $null -eq $injectedState -or
        $null -eq $connectedEvent -or
        $null -eq $grantEvent -or
        $null -eq $injectedMetric) {
        $errors.Add('Injected request does not have complete run, trace, and replay grant evidence.')
    }

    $queuedFinalGrantMetrics = if ($Condition -eq 'BASE') {
        @()
    }
    else {
        @(
            foreach ($metric in $GrantMetrics) {
                $state =
                    $Trace.RootStates |
                    Where-Object RunId -eq $metric.RunId |
                    Select-Object -First 1
                if ($null -ne $state -and
                    $null -ne $state.QueuedUtc) {
                    $metric
                }
            }
        )
    }
    $oversizedFinalGrants = @(
        $queuedFinalGrantMetrics |
            Where-Object {
                [int]$_.GrantedNodes -gt
                    [int]$validity.FinalMaximumGrantNodes
            }
    )
    $idleEightNodeGrantEvents = @(
        $Trace.Events |
            Where-Object {
                $_.Event -in @('Granted', 'DeferredGranted') -and
                [int]$_.Nodes -eq 8 -and
                ($MeasurementStartUtc -eq [DateTimeOffset]::MinValue -or
                    (ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc) -ge
                        $MeasurementStartUtc.ToUniversalTime())
            }
    )
    $preOnsetImmediateEightNodeGrantEvents = @(
        if ($MeasurementStartUtc -ne [DateTimeOffset]::MinValue) {
            $Trace.Events |
                Where-Object {
                    $_.Event -eq 'Granted' -and
                    [int]$_.Nodes -eq 8 -and
                    (ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc) -lt
                        $MeasurementStartUtc.ToUniversalTime()
                }
        }
    )
    if ($Condition -ne 'BASE' -and
        $MeasurementStartUtc -ne [DateTimeOffset]::MinValue -and
        $preOnsetImmediateEightNodeGrantEvents.Count -ne 1) {
        $errors.Add(
            "FINAL trace contains $($preOnsetImmediateEightNodeGrantEvents.Count) pre-onset immediate eight-node grant(s); exactly one is permitted.")
    }
    $queuedOversizedGrantEvents = @(
        $Trace.Events |
            Where-Object {
                $_.Event -eq 'DeferredGranted' -and
                [int]$_.Nodes -gt
                    [int]$validity.FinalMaximumGrantNodes
            }
    )
    if ($Condition -ne 'BASE' -and $oversizedFinalGrants.Count -gt 0) {
        $errors.Add("FINAL replay contains $($oversizedFinalGrants.Count) queued grant(s) above four nodes.")
    }
    if ($Condition -ne 'BASE' -and $idleEightNodeGrantEvents.Count -gt 0) {
        $errors.Add("FINAL trace contains $($idleEightNodeGrantEvents.Count) idle eight-node grant(s) during the measured queue window.")
    }
    if ($Condition -ne 'BASE' -and $queuedOversizedGrantEvents.Count -gt 0) {
        $errors.Add("FINAL trace contains $($queuedOversizedGrantEvents.Count) queued/deferred grant(s) above four nodes.")
    }

    $environmentPriority = if ($null -eq $injectedRun -or
        -not (Test-Path -LiteralPath $injectedRun.EnvironmentPath -PathType Leaf)) {
        $null
    }
    else {
        Get-SustainedEnvironmentValue `
            -EnvironmentRecord @(
                Get-Content -LiteralPath $injectedRun.EnvironmentPath -Raw |
                    ConvertFrom-Json) `
            -Name 'MSBUILDCOORDINATORBUILDREQUESTPRIORITY'
    }
    $expectedPriority = switch ($Condition) {
        'BASE' { $null }
        'FINAL-N' { 'Normal' }
        'FINAL-H' { 'High' }
    }
    if ($Condition -eq 'BASE') {
        if ($null -ne $environmentPriority) {
            $errors.Add('BASE injected request unexpectedly encoded a priority.')
        }
    }
    elseif ($environmentPriority -ne $expectedPriority -or
        $null -eq $connectedEvent -or
        [string]$connectedEvent.Priority -ne $expectedPriority) {
        $errors.Add("$Condition injected priority is not proven consistently by environment and trace.")
    }

    $promptReserveObserved = $false
    if ($Condition -eq 'FINAL-H' -and $null -ne $grantEvent) {
        $promptReserveObserved =
            $grantEvent.Event -eq 'Granted' -and
            [int]$grantEvent.Nodes -le
                [int]$validity.PromptReserveNodesToObserve -and
            [int]$grantEvent.QueueDepthBefore -ge 1 -and
            [int]$grantEvent.QueueDepth -ge 1 -and
            [int]$grantEvent.AllocatedNodesBefore -le
                ((Get-CampaignDefinition).NodeBudget -
                    [int]$validity.PromptReserveNodesToObserve)
        if (-not $promptReserveObserved) {
            $errors.Add('FINAL-H did not record an immediate High grant from observed reserve while Normal work remained queued.')
        }
    }

    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        Condition = $Condition
        ActualGrantCount = $GrantMetrics.Count
        ActualGrantSequence = @(
            $GrantMetrics |
                Sort-Object GrantTimestampUtc |
                Select-Object RunId, GrantedNodes, GrantTimestampUtc
        )
        FinalMaximumGrantNodesRequired =
            [int]$validity.FinalMaximumGrantNodes
        QueuedFinalGrantCount = @($queuedFinalGrantMetrics).Count
        OversizedFinalGrantCount = $oversizedFinalGrants.Count
        PreOnsetImmediateEightNodeGrantCount =
            $preOnsetImmediateEightNodeGrantEvents.Count
        IdleEightNodeGrantCount = $idleEightNodeGrantEvents.Count
        InjectionRunId = $InjectionRunId
        ExpectedInjectedPriority = $expectedPriority
        EnvironmentInjectedPriority = $environmentPriority
        TraceInjectedPriority = if ($null -eq $connectedEvent) {
            $null
        }
        else {
            [string]$connectedEvent.Priority
        }
        InjectedGrantEvent = if ($null -eq $grantEvent) {
            $null
        }
        else {
            [pscustomobject][ordered]@{
                Event = $grantEvent.Event
                TimestampUtc = $grantEvent.TimestampUtc
                Nodes = $grantEvent.Nodes
                QueueDepthBefore = $grantEvent.QueueDepthBefore
                QueueDepthAfter = $grantEvent.QueueDepth
                AllocatedNodesBefore = $grantEvent.AllocatedNodesBefore
                AllocatedNodesAfter = $grantEvent.AllocatedNodes
            }
        }
        InjectedReplayGrant = $injectedMetric
        ObservedUnusedNodesBeforeInjectedGrant =
            if ($null -eq $grantEvent) {
                $null
            }
            else {
                [int](Get-CampaignDefinition).NodeBudget -
                    [int]$grantEvent.AllocatedNodesBefore
            }
        PromptReserveBehaviorRequired = $Condition -eq 'FINAL-H'
        PromptReserveBehaviorObserved = $promptReserveObserved
        PromptReserveBehaviorInterpretation = if ($Condition -eq 'FINAL-H') {
            'Observed only when the trace proves an immediate <=4-node High grant while Normal requests remain queued and at least four nodes were unallocated before the grant.'
        }
        else {
            'Not applicable; no prompt-reserve claim is made for this condition.'
        }
    }
}

function Test-SustainedWindowControllerEvents {
    param(
        [Parameter(Mandatory)]
        [object[]]$Events,

        [ValidateSet(8, 10)]
        [int]$InitialWorkers,

        [bool]$RequireCompleteWindow = $true
    )

    $errors = [Collections.Generic.List[string]]::new()
    $activeByWorker = @{}
    $completed = @{}
    $initialWorkerSet = [Collections.Generic.HashSet[int]]::new()
    $initialRunIds =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
    $initialLaunchCount = 0
    $initialNormalCompletions = 0
    $onsetCount = 0
    $injectionCount = 0
    $stopCount = 0
    $lastTimestamp = [DateTimeOffset]::MinValue
    foreach ($event in $Events) {
        $timestamp = ConvertTo-UtcDateTimeOffset -Value $event.TimestampUtc
        if ($timestamp -lt $lastTimestamp) {
            $errors.Add('Controller event timestamps are not monotonic.')
        }
        $lastTimestamp = $timestamp
        $worker = if ($null -eq $event.Worker) {
            0
        }
        else {
            [int]$event.Worker
        }
        switch ([string]$event.Event) {
            'Launched' {
                $initialLaunchCount++
                if ($worker -lt 1 -or $worker -gt $InitialWorkers -or
                    -not $initialWorkerSet.Add($worker)) {
                    $errors.Add("Initial launch '$($event.RunId)' has an invalid or duplicate worker.")
                }
                elseif ($activeByWorker.ContainsKey($worker)) {
                    $errors.Add("Initial worker $worker overlapped an active run.")
                }
                else {
                    $activeByWorker[$worker] = [string]$event.RunId
                    [void]$initialRunIds.Add([string]$event.RunId)
                }
            }
            'Completed' {
                if ($worker -le 0) {
                    continue
                }
                $runId = [string]$event.RunId
                if ($completed.ContainsKey($runId)) {
                    $errors.Add("Run '$runId' completed more than once.")
                    continue
                }
                $matched = $activeByWorker.ContainsKey($worker) -and
                    $activeByWorker[$worker] -eq $runId
                if (-not $matched) {
                    $errors.Add("Worker $worker completed '$runId' without a matching active run.")
                }
                else {
                    $activeByWorker.Remove($worker)
                }
                $quiescent =
                    $null -ne $event.PSObject.Properties['Quiescent'] -and
                    [bool]$event.Quiescent
                $exitCode = if ($null -eq
                    $event.PSObject.Properties['ExitCode']) {
                    $null
                }
                else {
                    [int]$event.ExitCode
                }
                $completed[$runId] = [pscustomobject]@{
                    Worker = $worker
                    TimestampUtc = $timestamp
                    Quiescent = $quiescent
                    ExitCode = $exitCode
                }
                if ($onsetCount -eq 0 -and
                    $initialRunIds.Contains($runId) -and
                    $quiescent -and
                    $exitCode -eq 0) {
                    $initialNormalCompletions++
                }
            }
            'ReplacementLaunched' {
                if ($worker -le 0 -or
                    $activeByWorker.ContainsKey($worker)) {
                    $errors.Add("Replacement '$($event.RunId)' overlaps worker $worker.")
                    continue
                }
                $predecessor = [string]$event.ReplacedRunId
                if (-not $completed.ContainsKey($predecessor) -or
                    -not $completed[$predecessor].Quiescent -or
                    [int]$completed[$predecessor].ExitCode -ne 0) {
                    $errors.Add("Replacement '$($event.RunId)' lacks a successful quiescent predecessor.")
                    continue
                }
                try {
                    $touch = ConvertTo-UtcDateTimeOffset -Value $event.TouchUtc
                    $processStart =
                        ConvertTo-UtcDateTimeOffset -Value $event.ProcessStartUtc
                    if ($touch -lt $completed[$predecessor].TimestampUtc -or
                        $processStart -lt $touch) {
                        $errors.Add("Replacement '$($event.RunId)' touch/start ordering is invalid.")
                    }
                }
                catch {
                    $errors.Add("Replacement '$($event.RunId)' has invalid touch/start timestamps.")
                }
                $activeByWorker[$worker] = [string]$event.RunId
            }
            'SteadyOnset' {
                $onsetCount++
                if ($initialNormalCompletions -lt 1) {
                    $errors.Add('Steady onset preceded the first successful initial Normal completion.')
                }
                if (-not [bool]$event.DeferredGrantOccurred -or
                    [int]$event.ActiveNormalCount -lt 1 -or
                    [int]$event.WaitingNormalCount -lt 1 -or
                    [double]$event.QueueNonemptyContinuousSeconds -lt 30) {
                    $errors.Add('Steady onset does not prove deferred, active, waiting, and continuous-queue requirements.')
                }
            }
            'Injected' {
                $injectionCount++
                if ([Math]::Abs(
                    [double]$event.ActualOffsetSeconds - 240.0) -gt
                    [double](Get-CampaignDefinition).Validity.InjectionTimingToleranceSeconds) {
                    $errors.Add('Injection was not launched at fixed minute four within tolerance.')
                }
                if ([int]$event.ActiveNormalCount -lt 1 -or
                    [int]$event.WaitingNormalCount -lt 1) {
                    $errors.Add('Injection did not occur with active and waiting Normal work.')
                }
            }
            'SubmissionStopped' {
                $stopCount++
                if ([Math]::Abs(
                    [double]$event.ActualOffsetSeconds - 480.0) -gt
                    [double](Get-CampaignDefinition).Validity.InjectionTimingToleranceSeconds) {
                    $errors.Add('Submission stop was not observed at fixed minute eight within tolerance.')
                }
            }
        }
    }
    if ($initialLaunchCount -ne $InitialWorkers -or
        $initialWorkerSet.Count -ne $InitialWorkers) {
        $errors.Add("Controller recorded $initialLaunchCount launches across $($initialWorkerSet.Count) initial workers; expected $InitialWorkers.")
    }
    if ($RequireCompleteWindow -and
        ($onsetCount -ne 1 -or $injectionCount -ne 1 -or $stopCount -ne 1)) {
        $errors.Add("Complete fixed window requires one onset, injection, and submission-stop event; found $onsetCount/$injectionCount/$stopCount.")
    }
    if ($RequireCompleteWindow -and $activeByWorker.Count -ne 0) {
        $errors.Add("Controller retained $($activeByWorker.Count) active Normal worker(s) after drain.")
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        InitialWorkerCount = $initialWorkerSet.Count
        InitialNormalCompletionsBeforeOnset = $initialNormalCompletions
        OnsetCount = $onsetCount
        InjectionCount = $injectionCount
        SubmissionStopCount = $stopCount
        ActiveWorkersAfterDrain = $activeByWorker.Count
    }
}

function New-SustainedScenarioRunIdentity {
    param(
        [string]$Repository,
        [string]$Condition,
        [int]$BlockNumber,
        [int]$AttemptNumber,
        [int]$OrderIndex,
        [int]$WorkerCount
    )

    "sustained|$Repository|$Condition|b$BlockNumber|a$AttemptNumber|o$OrderIndex|w$WorkerCount"
}
