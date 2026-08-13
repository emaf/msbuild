[CmdletBinding()]
param(
    [switch]$KeepOutput,
    [string]$ResultPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot '.test-output'
Remove-Item `
    -LiteralPath $testRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $testRoot | Out-Null
$assertions = 0

function Assert-SustainedTrue {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $script:assertions++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-SustainedEqual {
    param(
        [AllowNull()]
        [object]$Actual,
        [AllowNull()]
        [object]$Expected,
        [Parameter(Mandatory)]
        [string]$Message
    )

    Assert-SustainedTrue `
        -Condition ($Actual -eq $Expected) `
        -Message "$Message (actual='$Actual', expected='$Expected')"
}

try {
    $parseErrors = [Collections.Generic.List[string]]::new()
    $scripts = @(
        Get-ChildItem `
            -LiteralPath $PSScriptRoot `
            -Recurse `
            -File `
            -Filter '*.ps1'
    )
    foreach ($scriptFile in $scripts) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptFile.FullName,
            [ref]$tokens,
            [ref]$errors)
        foreach ($error in $errors) {
            $parseErrors.Add(
                "$($scriptFile.Name):$($error.Extent.StartLineNumber): $($error.Message)")
        }
    }
    Assert-SustainedEqual `
        -Actual $parseErrors.Count `
        -Expected 0 `
        -Message 'Every focused sustained PowerShell script parses'

    . (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
    $campaign = Get-CampaignDefinition
    Assert-SustainedEqual `
        -Actual $campaign.Base.Commit `
        -Expected 'ff5b281f0c5828dec0d092fcd1b682019de7d1ca' `
        -Message 'BASE revision is unchanged'
    Assert-SustainedEqual `
        -Actual $campaign.Final.Branch `
        -Expected 'coordinator-priorities' `
        -Message 'FINAL branch is exact'
    Assert-SustainedEqual `
        -Actual $campaign.Final.Commit `
        -Expected '432466e41a95f9bbb25cad7ff9bd1b89b4a6bcef' `
        -Message 'FINAL commit is exact'
    Assert-SustainedEqual `
        -Actual (@($campaign.Conditions.Key) -join ',') `
        -Expected 'BASE,FINAL-N,FINAL-H' `
        -Message 'Only approved sustained conditions exist'

    $plan = New-SustainedCampaignPlan
    $planCheck = Test-SustainedCampaignPlan -Plan $plan
    Assert-SustainedTrue `
        -Condition $planCheck.Valid `
        -Message "Focused plan validates: $($planCheck.Errors -join '; ')"
    Assert-SustainedEqual `
        -Actual $plan.Rows.Count `
        -Expected 24 `
        -Message 'Plan has two repositories times four complete blocks times three conditions'
    Assert-SustainedTrue `
        -Condition $plan.Diagnostics.PositionBalanced `
        -Message 'Measured three-row rotation is exactly position-balanced'
    Assert-SustainedEqual `
        -Actual $plan.Diagnostics.PositionImbalance `
        -Expected 0 `
        -Message 'Measured position imbalance is zero'
    Assert-SustainedTrue `
        -Condition (-not $plan.Diagnostics.CarryoverBalanced) `
        -Message 'Carryover is explicitly not described as balanced'
    Assert-SustainedTrue `
        -Condition (
            $plan.Diagnostics.CarryoverImbalance -gt 0 -and
            $plan.Diagnostics.CarryoverDeclaration -match
                'explicitly carryover-unbalanced') `
        -Message 'Carryover imbalance and declaration are durable'
    foreach ($repository in $campaign.Repositories.Name) {
        $rows = @(
            $plan.Rows |
                Where-Object Repository -eq $repository
        )
        Assert-SustainedEqual `
            -Actual @($rows | Where-Object IsWarmup).Count `
            -Expected 3 `
            -Message "$repository has one complete three-condition warmup block"
        $orders = @(
            foreach ($block in 1..4) {
                @(
                    $rows |
                        Where-Object BlockNumber -eq $block |
                        Sort-Object OrderIndex |
                        Select-Object -ExpandProperty Condition
                ) -join ','
            }
        )
        Assert-SustainedEqual `
            -Actual ($orders -join ';') `
            -Expected (
                'BASE,FINAL-N,FINAL-H;' +
                'BASE,FINAL-N,FINAL-H;' +
                'FINAL-N,FINAL-H,BASE;' +
                'FINAL-H,BASE,FINAL-N') `
            -Message "$repository warmup and measured orders are exact"
    }

    $environmentCases = @(
        [pscustomobject]@{
            Condition = 'BASE'
            NormalPriority = $null
            InjectedPriority = $null
        },
        [pscustomobject]@{
            Condition = 'FINAL-N'
            NormalPriority = 'Normal'
            InjectedPriority = 'Normal'
        },
        [pscustomobject]@{
            Condition = 'FINAL-H'
            NormalPriority = 'Normal'
            InjectedPriority = 'High'
        }
    )
    foreach ($case in $environmentCases) {
        $normal = New-ConditionEnvironment `
            -Condition $case.Condition `
            -PipeName 'test-pipe' `
            -DotNetRoot 'C:\bootstrap' `
            -EnableDebugTrace `
            -DebugPath 'C:\debug'
        $injected = New-ConditionEnvironment `
            -Condition $case.Condition `
            -PipeName 'test-pipe' `
            -DotNetRoot 'C:\bootstrap' `
            -Injected `
            -EnableDebugTrace `
            -DebugPath 'C:\debug'
        Assert-ConditionEnvironmentContract `
            -Condition $case.Condition `
            -Environment $normal
        Assert-ConditionEnvironmentContract `
            -Condition $case.Condition `
            -Environment $injected `
            -Injected
        $parity = Test-SustainedDebugEnvironmentParity `
            -NormalEnvironment $normal `
            -InjectedEnvironment $injected `
            -Condition $case.Condition
        Assert-SustainedTrue `
            -Condition $parity.Valid `
            -Message "$($case.Condition) uses identical debug/pipe settings"
        Assert-SustainedEqual `
            -Actual $normal['MSBUILDCOORDINATORBUILDREQUESTPRIORITY'] `
            -Expected $case.NormalPriority `
            -Message "$($case.Condition) Normal priority encoding is exact"
        Assert-SustainedEqual `
            -Actual $injected['MSBUILDCOORDINATORBUILDREQUESTPRIORITY'] `
            -Expected $case.InjectedPriority `
            -Message "$($case.Condition) injected priority encoding is exact"
        Assert-SustainedEqual `
            -Actual $normal['MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES'] `
            -Expected $null `
            -Message "$($case.Condition) does not force reservation"
        Assert-SustainedEqual `
            -Actual $normal['MSBUILDCOORDINATORMAXNODESPERBUILD'] `
            -Expected $null `
            -Message "$($case.Condition) does not force a maximum"
        $expectedAging = if ($case.Condition -eq 'BASE') {
            $null
        }
        else {
            '3'
        }
        Assert-SustainedEqual `
            -Actual $normal['MSBUILDCOORDINATORPRIORITYAGINGTHRESHOLD'] `
            -Expected $expectedAging `
            -Message "$($case.Condition) priority aging environment is exact"
    }

    $onset = [DateTimeOffset]::Parse('2026-08-13T12:00:00Z')
    $timing = Get-SustainedWindowTiming -OnsetUtc $onset
    Assert-SustainedEqual `
        -Actual $timing.WindowSeconds `
        -Expected 480 `
        -Message 'Measured window is fixed at eight minutes'
    Assert-SustainedEqual `
        -Actual (
            (ConvertTo-UtcDateTimeOffset -Value $timing.InjectionDueUtc) -
            $onset).TotalSeconds `
        -Expected 240 `
        -Message 'Probe injection is fixed at minute four'
    Assert-SustainedEqual `
        -Actual (
            (ConvertTo-UtcDateTimeOffset -Value $timing.SubmissionStopUtc) -
            $onset).TotalSeconds `
        -Expected 480 `
        -Message 'Submissions stop at minute eight'

    $trace = [pscustomobject]@{
        Consistent = $true
        DeferredGrantOccurred = $true
        Timeline = @(
            [pscustomobject]@{
                TimestampUtc = $onset.ToString('O')
                Sequence = 1
                QueueDepth = 1
            },
            [pscustomobject]@{
                TimestampUtc = $onset.AddSeconds(31).ToString('O')
                Sequence = 2
                QueueDepth = 2
            }
        )
        RootStates = @(
            [pscustomobject]@{
                RunId = 'normal1-g2'
                State = 'Active'
            },
            [pscustomobject]@{
                RunId = 'normal2-g1'
                State = 'Queued'
            }
        )
    }
    $onsetRuns = @(
        [pscustomobject]@{
            RunId = 'normal1-g2'
            Kind = 'normal'
        },
        [pscustomobject]@{
            RunId = 'normal2-g1'
            Kind = 'normal'
        }
    )
    $onsetEvidence = Test-SustainedWindowOnset `
        -Trace $trace `
        -RunRecords $onsetRuns `
        -InitialNormalCompletionCount 1 `
        -NowUtc $onset.AddSeconds(31)
    Assert-SustainedTrue `
        -Condition $onsetEvidence.Accepted `
        -Message 'Onset requires initial completion, deferred grant, active/waiting Normal, and 30 continuous queued seconds'
    $missingCompletion = Test-SustainedWindowOnset `
        -Trace $trace `
        -RunRecords $onsetRuns `
        -InitialNormalCompletionCount 0 `
        -NowUtc $onset.AddSeconds(31)
    Assert-SustainedTrue `
        -Condition (-not $missingCompletion.Accepted) `
        -Message 'Onset cannot precede the first initial Normal completion'

    $increase = Get-SustainedWorkerSizingResponse `
        -WorkerCount 8 `
        -QueueCriterionPassed $false
    Assert-SustainedEqual `
        -Actual $increase.Status `
        -Expected 'WorkerCountIncreaseRequired' `
        -Message 'Eight-worker queue failure returns the explicit approved response'
    Assert-SustainedEqual `
        -Actual $increase.NextWorkerCount `
        -Expected 10 `
        -Message 'The only sizing rerun is globally at ten'
    Assert-SustainedTrue `
        -Condition $increase.RerunAllPilots `
        -Message 'Sizing transition reruns all pilots globally'
    $maximumFailure = Get-SustainedWorkerSizingResponse `
        -WorkerCount 10 `
        -QueueCriterionPassed $false
    Assert-SustainedEqual `
        -Actual $maximumFailure.NextWorkerCount `
        -Expected $null `
        -Message 'No size retry exists above ten'
    $ready = Get-SustainedWorkerSizingResponse `
        -WorkerCount 8 `
        -QueueCriterionPassed $true
    Assert-SustainedEqual `
        -Actual $ready.FrozenWorkerCount `
        -Expected 8 `
        -Message 'Passing eight-worker pilots freeze eight globally'

    $parentToolingRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $parentToolingRoot 'Scenario.Common.ps1')
    . (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
    $staleSet =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
    [void]$staleSet.Add('123|2026-08-13T00:00:00Z')
    $staleRun = [pscustomobject]@{
        JobCensusFailed = $false
        CurrentNonCoordinatorJobProcessIds = [int[]]@()
        DescendantIdentities = $staleSet
    }
    Assert-SustainedTrue `
        -Condition (Test-RunDescendantsExited -Run $staleRun) `
        -Message 'Corrected quiescence uses current Job membership rather than stale identities'
    Assert-SustainedEqual `
        -Actual $staleRun.DescendantIdentities.Count `
        -Expected 0 `
        -Message 'Stale descendant identities are pruned after current membership is empty'
    $currentSet =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
    [void]$currentSet.Add('456|2026-08-13T00:00:01Z')
    $currentRun = [pscustomobject]@{
        JobCensusFailed = $false
        CurrentNonCoordinatorJobProcessIds = [int[]]@(456)
        DescendantIdentities = $currentSet
    }
    Assert-SustainedTrue `
        -Condition (-not (Test-RunDescendantsExited -Run $currentRun)) `
        -Message 'Current non-Coordinator Job membership prevents relaunch'

    $highEnvironmentPath = Join-Path $testRoot 'high-environment.json'
    @(
        [pscustomobject]@{
            Name = 'MSBUILDCOORDINATORBUILDREQUESTPRIORITY'
            Present = $true
            Value = 'High'
        }
    ) |
        ConvertTo-Json |
        Set-Content `
            -LiteralPath $highEnvironmentPath `
            -Encoding utf8
    $policyRuns = @(
        [pscustomobject]@{
            RunId = 'normal1-g1'
            EnvironmentPath = $highEnvironmentPath
        },
        [pscustomobject]@{
            RunId = 'injected-g1'
            EnvironmentPath = $highEnvironmentPath
        }
    )
    $policyMetrics = @(
        [pscustomobject]@{
            RunId = 'normal1-g1'
            GrantedNodes = 4
            GrantTimestampUtc = $onset.AddSeconds(1).ToString('O')
        },
        [pscustomobject]@{
            RunId = 'injected-g1'
            GrantedNodes = 4
            GrantTimestampUtc = $onset.AddSeconds(2).ToString('O')
            RequestToGrantSeconds = 0.01
        }
    )
    $policyTrace = [pscustomobject]@{
        RootStates = @(
            [pscustomobject]@{
                RunId = 'injected-g1'
                IdentityKey = '22|start'
            }
        )
        Events = @(
            [pscustomobject]@{
                Event = 'Connected'
                IdentityKey = '22|start'
                Priority = 'High'
                Nodes = $null
                QueueDepthBefore = 2
                QueueDepth = 2
                AllocatedNodesBefore = 12
                AllocatedNodes = 12
            },
            [pscustomobject]@{
                Event = 'Granted'
                IdentityKey = '22|start'
                Priority = $null
                Nodes = 4
                TimestampUtc = $onset.AddSeconds(2).ToString('O')
                QueueDepthBefore = 2
                QueueDepth = 2
                AllocatedNodesBefore = 12
                AllocatedNodes = 16
            }
        )
    }
    $policyEvidence = Test-SustainedGrantPolicyEvidence `
        -Condition 'FINAL-H' `
        -RunRecords $policyRuns `
        -GrantMetrics $policyMetrics `
        -Trace $policyTrace
    Assert-SustainedTrue `
        -Condition $policyEvidence.Valid `
        -Message "FINAL-H policy evidence records actual <=4-node replay, High trace/environment, and prompt reserve behavior: $($policyEvidence.Errors -join '; ')"
    Assert-SustainedTrue `
        -Condition $policyEvidence.PromptReserveBehaviorObserved `
        -Message 'Prompt reserve behavior is observed from trace state, not assumed'
    $oversizedPolicy = Test-SustainedGrantPolicyEvidence `
        -Condition 'FINAL-H' `
        -RunRecords $policyRuns `
        -GrantMetrics @(
            [pscustomobject]@{
                RunId = 'normal1-g1'
                GrantedNodes = 8
                GrantTimestampUtc = $onset.AddSeconds(1).ToString('O')
            },
            $policyMetrics[1]) `
        -Trace $policyTrace
    Assert-SustainedTrue `
        -Condition (
            -not $oversizedPolicy.Valid -and
            $oversizedPolicy.OversizedFinalGrantCount -eq 1) `
        -Message 'Any replayed FINAL grant above four nodes is rejected'

    $controllerEvents = [Collections.Generic.List[object]]::new()
    foreach ($worker in 1..8) {
        $controllerEvents.Add([pscustomobject]@{
            TimestampUtc = $onset.AddMilliseconds($worker).ToString('O')
            Event = 'Launched'
            RunId = "normal$worker-g1"
            Worker = $worker
            Generation = 1
        })
    }
    $controllerEvents.Add([pscustomobject]@{
        TimestampUtc = $onset.AddSeconds(1).ToString('O')
        Event = 'Completed'
        RunId = 'normal1-g1'
        Worker = 1
        Generation = 1
        ExitCode = 0
        Quiescent = $true
    })
    $controllerEvents.Add([pscustomobject]@{
        TimestampUtc = $onset.AddSeconds(1.2).ToString('O')
        Event = 'ReplacementLaunched'
        RunId = 'normal1-g2'
        Worker = 1
        Generation = 2
        ReplacedRunId = 'normal1-g1'
        TouchUtc = $onset.AddSeconds(1.1).ToString('O')
        ProcessStartUtc = $onset.AddSeconds(1.15).ToString('O')
    })
    $controllerEvents.Add([pscustomobject]@{
        TimestampUtc = $onset.AddSeconds(31).ToString('O')
        Event = 'SteadyOnset'
        RunId = $null
        Worker = $null
        Generation = $null
        DeferredGrantOccurred = $true
        ActiveNormalCount = 3
        WaitingNormalCount = 5
        QueueNonemptyContinuousSeconds = 30
    })
    $controllerEvents.Add([pscustomobject]@{
        TimestampUtc = $onset.AddSeconds(271).ToString('O')
        Event = 'Injected'
        RunId = 'injected-g1'
        Worker = 0
        Generation = 1
        ActualOffsetSeconds = 240
        ActiveNormalCount = 3
        WaitingNormalCount = 5
    })
    $controllerEvents.Add([pscustomobject]@{
        TimestampUtc = $onset.AddSeconds(511).ToString('O')
        Event = 'SubmissionStopped'
        RunId = $null
        Worker = $null
        Generation = $null
        ActualOffsetSeconds = 480
    })
    foreach ($worker in 1..8) {
        $runId = if ($worker -eq 1) {
            'normal1-g2'
        }
        else {
            "normal$worker-g1"
        }
        $controllerEvents.Add([pscustomobject]@{
            TimestampUtc =
                $onset.AddSeconds(512 + $worker).ToString('O')
            Event = 'Completed'
            RunId = $runId
            Worker = $worker
            Generation = if ($worker -eq 1) { 2 } else { 1 }
            ExitCode = 0
            Quiescent = $true
        })
    }
    $controllerCheck = Test-SustainedWindowControllerEvents `
        -Events $controllerEvents.ToArray() `
        -InitialWorkers 8
    Assert-SustainedTrue `
        -Condition $controllerCheck.Valid `
        -Message "Controller proves no-overlap quiescence/touch ordering and fixed timing: $($controllerCheck.Errors -join '; ')"

    Assert-SustainedEqual `
        -Actual $campaign.Validity.MaximumBlockAttempts `
        -Expected 2 `
        -Message 'Measured blocks have at most two whole-block attempts'
    Assert-SustainedEqual `
        -Actual $campaign.HardTimeoutHours `
        -Expected 8 `
        -Message 'Total campaign hard timeout is eight hours'
    $deadlineCheck = Test-SustainedCampaignDeadline `
        -StartedUtc $onset `
        -NowUtc $onset.AddHours(8)
    Assert-SustainedTrue `
        -Condition $deadlineCheck.Expired `
        -Message 'Eight-hour deadline expires exactly at the boundary'

    $runnerText = Get-Content `
        -LiteralPath (
            Join-Path $PSScriptRoot 'Invoke-SustainedWindowScenario.ps1') `
        -Raw
    $completeIndex = $runnerText.IndexOf(
        'Complete-ExitedScenarioBuild',
        [StringComparison]::Ordinal)
    $touchIndex = $runnerText.IndexOf(
        'Touch-CampaignInput',
        $completeIndex,
        [StringComparison]::Ordinal)
    $replacementIndex = $runnerText.IndexOf(
        '$replacement = Start-ScenarioBuild',
        $touchIndex,
        [StringComparison]::Ordinal)
    Assert-SustainedTrue `
        -Condition (
            $completeIndex -ge 0 -and
            $completeIndex -lt $touchIndex -and
            $touchIndex -lt $replacementIndex) `
        -Message 'Focused runner completes corrected quiescence, then touches, then relaunches'
    Assert-SustainedTrue `
        -Condition (
            -not $runnerText.Contains(
                'SustainedEndingCompletion',
                [StringComparison]::Ordinal) -and
            -not $runnerText.Contains(
                'SustainedInjectionCompletion',
                [StringComparison]::Ordinal)) `
        -Message 'Focused runner contains no historical completion-count gate'

    $orchestratorText = Get-Content `
        -LiteralPath (
            Join-Path $PSScriptRoot 'Run-SustainedCampaign.ps1') `
        -Raw
    Assert-SustainedTrue `
        -Condition (
            $orchestratorText.Contains(
                'MaximumBlockAttempts',
                [StringComparison]::Ordinal) -and
            $orchestratorText.Contains(
                'hardDeadlineUtc',
                [StringComparison]::Ordinal) -and
            $orchestratorText.Contains(
                'Analyze-SustainedCampaign.ps1',
                [StringComparison]::Ordinal)) `
        -Message 'Measured orchestrator enforces attempts/deadline and produces analysis'
    $launcherText = Get-Content `
        -LiteralPath (
            Join-Path $PSScriptRoot 'Launch-SustainedCampaign.ps1') `
        -Raw
    Assert-SustainedTrue `
        -Condition (
            $launcherText.Contains(
                'current-vs-final-sustained-',
                [StringComparison]::Ordinal) -and
            $launcherText.Contains(
                'AutomaticRelaunch = $false',
                [StringComparison]::Ordinal) -and
            $launcherText.Contains(
                'DuplicateProcessCount',
                [StringComparison]::Ordinal) -and
            $launcherText.Contains(
                'Watch-SustainedCampaignDeadline.ps1',
                [StringComparison]::Ordinal)) `
        -Message 'Launcher is one detached, duplicate-guarded, no-relaunch launch'
    $watchdogText = Get-Content `
        -LiteralPath (
            Join-Path $PSScriptRoot 'Watch-SustainedCampaignDeadline.ps1') `
        -Raw
    Assert-SustainedTrue `
        -Condition (
            $watchdogText.Contains(
                'Stop-VerifiedProcessTree',
                [StringComparison]::Ordinal) -and
            $watchdogText.Contains(
                'HardTimeoutHours = 8',
                [StringComparison]::Ordinal) -and
            $watchdogText.Contains(
                'TargetProcessStartUtc',
                [StringComparison]::Ordinal)) `
        -Message 'Auxiliary watchdog enforces eight hours against exact process identity'
    $buildText = Get-Content `
        -LiteralPath (
            Join-Path $PSScriptRoot 'Build-SustainedExactRevisions.ps1') `
        -Raw
    Assert-SustainedTrue `
        -Condition (
            $buildText.Contains(
                'foreach ($role in $roles)',
                [StringComparison]::Ordinal) -and
            $buildText.Contains(
                'ReusedRoles',
                [StringComparison]::Ordinal) -and
            $buildText.Contains(
                'PerRoleImmutableReuse = $true',
                [StringComparison]::Ordinal)) `
        -Message 'Exact revision builder independently reuses and records each role'

    . (Join-Path $parentToolingRoot 'Analysis.Common.ps1')
    $analysisPairs = @(
        [pscustomobject]@{
            BaselineValue = 10.0
            CandidateValue = 11.0
        },
        [pscustomobject]@{
            BaselineValue = 20.0
            CandidateValue = 22.0
        },
        [pscustomobject]@{
            BaselineValue = 30.0
            CandidateValue = 33.0
        }
    )
    $estimate1 = New-PairedEstimate `
        -Pairs $analysisPairs `
        -Shape sustained `
        -Repository roslyn `
        -Baseline BASE `
        -Candidate 'FINAL-N' `
        -Metric OverallNormalThroughputPerSecond `
        -PreferredDirection higher `
        -Seed 20260813
    $estimate2 = New-PairedEstimate `
        -Pairs $analysisPairs `
        -Shape sustained `
        -Repository roslyn `
        -Baseline BASE `
        -Candidate 'FINAL-N' `
        -Metric OverallNormalThroughputPerSecond `
        -PreferredDirection higher `
        -Seed 20260813
    Assert-SustainedEqual `
        -Actual $estimate1.PairedBlocks `
        -Expected 3 `
        -Message 'Directional analysis uses n=3 whole blocks'
    Assert-SustainedEqual `
        -Actual $estimate1.ResampleIterations `
        -Expected 10000 `
        -Message 'Analysis uses exactly 10,000 resamples'
    Assert-SustainedEqual `
        -Actual $estimate1.ExactSignFlipPermutationCount `
        -Expected 8 `
        -Message 'Analysis enumerates all exact n=3 sign flips'
    Assert-SustainedEqual `
        -Actual $estimate1.ExactTwoSidedSignFlipP `
        -Expected 0.25 `
        -Message 'Exact directional n=3 p-value discreteness is correct'
    Assert-SustainedEqual `
        -Actual $estimate1.ConfidenceIntervalLowerPercent `
        -Expected $estimate2.ConfidenceIntervalLowerPercent `
        -Message 'Whole-block resampling is deterministic at the declared seed'

    $analysisRun = Join-Path $testRoot 'analysis-fixture'
    New-Item -ItemType Directory -Path $analysisRun | Out-Null
    Write-JsonAtomic `
        -Path (Join-Path $analysisRun 'run-metadata.json') `
        -Value ([pscustomobject][ordered]@{
            Campaign = $campaign
        }) `
        -Depth 12
    $plan.Rows |
        Export-Csv `
            -NoTypeInformation `
            -LiteralPath (Join-Path $analysisRun 'matrix-plan.csv')
    $pilotFixtureRoot =
        Join-Path $analysisRun '_setup\pilots'
    New-Item `
        -ItemType Directory `
        -Path $pilotFixtureRoot `
        -Force |
        Out-Null
    $pilotFixtures = @(
        foreach ($repository in $campaign.Repositories) {
            foreach ($condition in Get-SustainedConditionKeys) {
                [pscustomobject]@{
                    Repository = $repository.Name
                    Condition = $condition
                }
            }
        }
    )
    Write-JsonAtomic `
        -Path (Join-Path $pilotFixtureRoot 'pilot-completion.json') `
        -Value ([pscustomobject][ordered]@{
            Valid = $true
            FrozenWorkerCount = 8
            SelectedPilots = $pilotFixtures
        }) `
        -Depth 8
    foreach ($repository in $campaign.Repositories) {
        foreach ($block in 2..4) {
            $analysisBlock = $block - 1
            $blockRoot = Join-Path $analysisRun (
                "sustained\$($repository.Name)\block-$('{0:D3}' -f $block)")
            New-Item -ItemType Directory -Path $blockRoot -Force |
                Out-Null
            Write-JsonAtomic `
                -Path (Join-Path $blockRoot 'block-completion.json') `
                -Value ([pscustomobject][ordered]@{
                    Disposition = 'Valid'
                    WorkerCount = 8
                    AttemptNumber = 1
                })
            $blockRows = @(
                $plan.Rows |
                    Where-Object {
                        $_.Repository -eq $repository.Name -and
                        $_.BlockNumber -eq $block
                    }
            )
            foreach ($row in $blockRows) {
                $scenarioRoot = Join-Path $blockRoot (
                    "attempt-01\$('{0:D2}' -f $row.OrderIndex)-$($row.Condition)")
                New-Item `
                    -ItemType Directory `
                    -Path $scenarioRoot `
                    -Force |
                    Out-Null
                $identity = New-SustainedScenarioRunIdentity `
                    -Repository $repository.Name `
                    -Condition $row.Condition `
                    -BlockNumber $block `
                    -AttemptNumber 1 `
                    -OrderIndex $row.OrderIndex `
                    -WorkerCount 8
                $conditionMultiplier = switch ($row.Condition) {
                    'BASE' { 1.0 }
                    'FINAL-N' { 1.1 }
                    'FINAL-H' { 1.2 }
                }
                $blockMultiplier = 1.0 + ($analysisBlock / 100.0)
                Write-JsonAtomic `
                    -Path (
                        Join-Path $scenarioRoot 'scenario-validation.json') `
                    -Value ([pscustomobject][ordered]@{
                        Valid = $true
                        Disposition = 'Valid'
                        IsWarmup = $false
                        RunIdentity = $identity
                        Repository = $repository.Name
                        Condition = $row.Condition
                        AnalysisBlockNumber = $analysisBlock
                    })
                Write-JsonAtomic `
                    -Path (
                        Join-Path $scenarioRoot 'scenario-metrics.json') `
                    -Value ([pscustomobject][ordered]@{
                        IsWarmup = $false
                        RunIdentity = $identity
                        Repository = $repository.Name
                        Condition = $row.Condition
                        AnalysisBlockNumber = $analysisBlock
                        WorkerCount = 8
                        MeasuredWindowSeconds = 480
                        OldTwelveCompletionTenMinuteGateApplied = $false
                        MeasuredNormalCompletionCount =
                            [int](10 * $conditionMultiplier)
                        OverallNormalThroughputPerSecond =
                            0.02 * $conditionMultiplier * $blockMultiplier
                        PreInjectionNormalThroughputPerSecond =
                            0.018 * $conditionMultiplier * $blockMultiplier
                        PostInjectionNormalThroughputPerSecond =
                            0.022 * $conditionMultiplier * $blockMultiplier
                        AverageCompletedNormalLatencySeconds =
                            100 / $conditionMultiplier
                        InjectedRequestToGrantSeconds =
                            2 / $conditionMultiplier
                        InjectedRequestToCompletionSeconds =
                            80 / $conditionMultiplier
                        QueueDepthP95 = 5 * $blockMultiplier
                        QueueNonemptyTimeFraction = 0.95
                        QueueNonemptySampleFraction = 0.95
                        SteadyResource = [pscustomobject]@{
                            PeakCommittedBytes =
                                1000000 * $conditionMultiplier
                            PeakDescendantWorkingSetBytes =
                                900000 * $conditionMultiplier
                            PeakDescendantPrivateBytes =
                                800000 * $conditionMultiplier
                            PeakDescendantProcessCount =
                                20 * $conditionMultiplier
                        }
                        GrantPolicyEvidence = [pscustomobject]@{
                            TraceInjectedPriority =
                                if ($row.Condition -eq 'FINAL-H') {
                                    'High'
                                }
                                elseif ($row.Condition -eq 'FINAL-N') {
                                    'Normal'
                                }
                                else {
                                    $null
                                }
                            PromptReserveBehaviorObserved =
                                $row.Condition -eq 'FINAL-H'
                        }
                    }) `
                    -Depth 10
            }
        }
    }
    & (Join-Path $PSScriptRoot 'Analyze-SustainedCampaign.ps1') `
        -RunRoot $analysisRun `
        -OutputRoot (Join-Path $analysisRun 'analysis')
    $analysisValidation =
        Get-Content `
            -LiteralPath (
                Join-Path $analysisRun 'analysis\analysis-validation.json') `
            -Raw |
        ConvertFrom-Json
    Assert-SustainedTrue `
        -Condition $analysisValidation.Valid `
        -Message "Focused analysis validates synthetic exact matrix: $($analysisValidation.Errors -join '; ')"
    Assert-SustainedEqual `
        -Actual $analysisValidation.RawMeasuredRows `
        -Expected 18 `
        -Message 'Focused analysis consumes exactly 18 measured rows'
    Assert-SustainedEqual `
        -Actual $analysisValidation.EstimateRows `
        -Expected 48 `
        -Message 'Focused analysis emits every declared repository/comparison/metric estimate'
    Assert-SustainedTrue `
        -Condition (
            (Test-Path -LiteralPath (
                Join-Path $analysisRun 'analysis\raw-metrics.csv')) -and
            (Test-Path -LiteralPath (
                Join-Path $analysisRun 'analysis\formulas.json')) -and
            (Test-Path -LiteralPath (
                Join-Path $analysisRun 'analysis\report.md'))) `
        -Message 'Analysis emits raw, formula, and plain-English outputs'

    $publisherText = Get-Content `
        -LiteralPath (
            Join-Path $PSScriptRoot 'Publish-SustainedEvidence.ps1') `
        -Raw
    Assert-SustainedTrue `
        -Condition (
            $publisherText.Contains(
                "'..\..\sustained'",
                [StringComparison]::Ordinal) -and
            $publisherText.Contains(
                'RawOriginalsMutated = $false',
                [StringComparison]::Ordinal) -and
            -not $orchestratorText.Contains(
                'Publish-SustainedEvidence.ps1',
                [StringComparison]::Ordinal)) `
        -Message 'Sanitizer is a non-invoked hook constrained to current-vs-final/sustained'

    $result = [pscustomobject][ordered]@{
        Valid = $true
        CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Assertions = $assertions
        PowerShellScriptsParsed = $scripts.Count
        PlanRows = $plan.Rows.Count
        PositionBalanced = $plan.Diagnostics.PositionBalanced
        CarryoverBalanced = $plan.Diagnostics.CarryoverBalanced
        CarryoverDeclaration =
            $plan.Diagnostics.CarryoverDeclaration
        FixedWindowSeconds = $campaign.Validity.MeasuredWindowSeconds
        InjectionOffsetSeconds =
            $campaign.Validity.InjectionOffsetSeconds
        MaximumBlockAttempts =
            $campaign.Validity.MaximumBlockAttempts
        HardTimeoutHours = $campaign.HardTimeoutHours
        StaleIdentityCurrentMembershipCovered = $true
        PublicWorkloadsRun = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        Write-JsonAtomic -Path $ResultPath -Value $result -Depth 8
    }
    $result
}
finally {
    if (-not $KeepOutput) {
        Remove-Item `
            -LiteralPath $testRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
