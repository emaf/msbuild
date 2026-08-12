[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BootstrapIdentityPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Scenario.Common.ps1')
. (Join-Path $PSScriptRoot 'PhaseOneDisposablePreflight.Common.ps1')
Assert-WindowsCampaignHost

function Assert-PhaseOneValue {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-PhaseOneBootstrapEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$IdentityPath,

        [Parameter(Mandatory)]
        [string]$EvidenceRoot
    )

    $campaign = Get-CampaignDefinition
    $identityRecord = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json
    $baseRecord = Get-PhaseOneRecordProperty -Record $identityRecord -Name Base
    $finalRecord = Get-PhaseOneRecordProperty -Record $identityRecord -Name Final
    $sources = Get-PhaseOneRecordProperty -Record $identityRecord -Name Sources
    Assert-PhaseOneValue ($null -ne $baseRecord -and $null -ne $finalRecord) `
        'Bootstrap identity must contain exact Base and Final records.'
    Assert-PhaseOneValue ($null -ne $sources) `
        'Bootstrap identity must contain exact Base and Final source records.'

    $base = Get-BootstrapIdentity `
        -Role base `
        -Root ([string]$baseRecord.Root) `
        -ExpectedCommit $campaign.Base.Commit
    $final = Get-BootstrapIdentity `
        -Role final `
        -Root ([string]$finalRecord.Root) `
        -ExpectedCommit $campaign.Final.Commit
    $baseStage = Test-ImmutableBootstrapStage `
        -Root $base.Root `
        -RecordPath (Join-Path $EvidenceRoot 'base-stage-integrity.json')
    $finalStage = Test-ImmutableBootstrapStage `
        -Root $final.Root `
        -RecordPath (Join-Path $EvidenceRoot 'final-stage-integrity.json')

    $roleEvidence = [ordered]@{}
    foreach ($role in @(
        [pscustomobject]@{
            Name = 'Base'
            ExpectedRole = 'base'
            ExpectedCommit = $campaign.Base.Commit
            Recorded = $baseRecord
            Actual = $base
            Stage = $baseStage
        },
        [pscustomobject]@{
            Name = 'Final'
            ExpectedRole = 'final'
            ExpectedCommit = $campaign.Final.Commit
            Recorded = $finalRecord
            Actual = $final
            Stage = $finalStage
        }
    )) {
        $recorded = $role.Recorded
        $actual = $role.Actual
        Assert-PhaseOneValue (
            (Get-PhaseOneCanonicalPath -Path ([string]$recorded.Root)).Equals(
                (Get-PhaseOneCanonicalPath -Path $actual.Root),
                [StringComparison]::OrdinalIgnoreCase)) `
            "$($role.Name) bootstrap root changed."
        Assert-PhaseOneValue ([string]$recorded.ExpectedCommit -eq $role.ExpectedCommit) `
            "$($role.Name) recorded commit is not exact."
        Assert-PhaseOneValue ([string]$recorded.ProductVersion -eq $actual.ProductVersion) `
            "$($role.Name) ProductVersion changed."
        Assert-PhaseOneValue (
            $actual.ProductVersion.Contains(
                $role.ExpectedCommit,
                [StringComparison]::OrdinalIgnoreCase)) `
            "$($role.Name) ProductVersion does not contain its exact commit."
        foreach ($propertyName in @('DotNetSha256', 'MSBuildDllSha256')) {
            Assert-PhaseOneValue (
                [string](Get-PhaseOneRecordProperty -Record $recorded -Name $propertyName) -eq
                [string](Get-PhaseOneRecordProperty -Record $actual -Name $propertyName)) `
                "$($role.Name) $propertyName changed."
        }

        $recordedFiles = @(
            Get-PhaseOneRecordProperty -Record $recorded -Name TrackedFiles
        )
        foreach ($actualFile in @($actual.TrackedFiles)) {
            $recordedFile = @(
                $recordedFiles |
                    Where-Object {
                        [string]$_.RelativePath -eq [string]$actualFile.RelativePath
                    }
            )
            Assert-PhaseOneValue (
                $recordedFile.Count -eq 1 -and
                [string]$recordedFile[0].Sha256 -eq [string]$actualFile.Sha256) `
                "$($role.Name) tracked binary '$($actualFile.RelativePath)' changed."
        }
        Assert-PhaseOneValue ($recordedFiles.Count -eq @($actual.TrackedFiles).Count) `
            "$($role.Name) tracked binary set changed."

        $stageMetadata =
            Get-Content -LiteralPath $role.Stage.MetadataPath -Raw |
            ConvertFrom-Json
        Assert-PhaseOneValue (
            [string]$stageMetadata.Role -eq $role.ExpectedRole -and
            [string]$stageMetadata.ExpectedCommit -eq $role.ExpectedCommit -and
            [string]$stageMetadata.ProductVersion -eq $actual.ProductVersion) `
            "$($role.Name) immutable-stage metadata identity changed."

        $sourceRecord = Get-PhaseOneRecordProperty -Record $sources -Name $role.Name
        Assert-PhaseOneValue ($null -ne $sourceRecord) `
            "$($role.Name) source identity is missing."
        $source = Get-GitIdentity `
            -Root ([string]$sourceRecord.Root) `
            -ExpectedCommit $role.ExpectedCommit `
            -RequireClean
        Assert-PhaseOneValue (
            [string]$sourceRecord.ExpectedCommit -eq $role.ExpectedCommit -and
            [string]$sourceRecord.ActualCommit -eq $role.ExpectedCommit -and
            $sourceRecord.Verified -eq $true -and
            $source.Verified -eq $true -and
            $source.Clean -eq $true) `
            "$($role.Name) source identity is not exact and clean."

        $roleEvidence[$role.Name] = [pscustomobject][ordered]@{
            Role = $actual.Role
            Commit = $actual.ExpectedCommit
            ProductVersion = $actual.ProductVersion
            BootstrapRoot = $actual.Root
            SourceRoot = $source.Root
            SourceCommit = $source.ActualCommit
            SourceClean = $source.Clean
            DotNetSha256 = $actual.DotNetSha256
            MSBuildDllSha256 = $actual.MSBuildDllSha256
            TrackedBinaries = $actual.TrackedFiles
            ImmutableStage = $role.Stage
            Valid = $true
        }
    }
    Assert-PhaseOneValue (
        -not $base.Root.Equals($final.Root, [StringComparison]::OrdinalIgnoreCase)) `
        'BASE and FINAL unexpectedly resolve to the same bootstrap root.'
    Assert-PhaseOneValue ($base.MSBuildDllSha256 -ne $final.MSBuildDllSha256) `
        'BASE and FINAL unexpectedly have the same MSBuild binary identity.'

    $evidence = [pscustomobject][ordered]@{
        Valid = $true
        BootstrapIdentityPath = $IdentityPath
        BootstrapIdentitySha256 =
            (Get-FileHash -LiteralPath $IdentityPath -Algorithm SHA256).Hash
        Base = $roleEvidence.Base
        Final = $roleEvidence.Final
    }
    Write-JsonAtomic `
        -Path (Join-Path $EvidenceRoot 'bootstrap-validation.json') `
        -Value $evidence `
        -Depth 12
    [pscustomobject]@{
        Base = $base
        Final = $final
        Evidence = $evidence
    }
}

function Get-PhaseOneExistingPreflightEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$PreflightRoot,

        [Parameter(Mandatory)]
        [pscustomobject]$Base,

        [Parameter(Mandatory)]
        [pscustomobject]$Final
    )

    $completionPath = Join-Path $PreflightRoot 'completion.json'
    Assert-PhaseOneValue (Test-Path -LiteralPath $completionPath -PathType Leaf) `
        "Existing preflight completion '$completionPath' is missing."
    $completion = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
    Assert-PhaseOneValue ($completion.Valid -eq $true) `
        'Existing preflight completion is invalid.'
    $expectedNames = @(
        'base-functional-isolated',
        'final-functional-compat-isolated',
        'final-functional-default-isolated',
        'final-functional-high-injection',
        'base-controller-trace',
        'final-controller-trace'
    )
    $results = @($completion.Results)
    Assert-PhaseOneValue (
        (@($results.Name | Sort-Object) -join '|') -eq
        (@($expectedNames | Sort-Object) -join '|')) `
        'Existing preflight did not produce the exact functional/controller result set.'

    foreach ($result in $results) {
        $expectedBootstrap = if ([string]$result.Name -like 'base-*') {
            $Base
        }
        else {
            $Final
        }
        Assert-PhaseOneValue (
            $result.Valid -eq $true -and
            [string]$result.BootstrapRole -eq $expectedBootstrap.Role -and
            [string]$result.BootstrapCommit -eq $expectedBootstrap.ExpectedCommit) `
            "Existing preflight result '$($result.Name)' has the wrong exact binary identity."
        Assert-PhaseOneValue (
            [int]$result.TraceSummary.FinalQueueDepth -eq 0 -and
            [int]$result.TraceSummary.FinalActiveBuilds -eq 0 -and
            [int]$result.TraceSummary.FinalAllocatedNodes -eq 0 -and
            $result.TraceSummary.Consistent -eq $true) `
            "Existing preflight result '$($result.Name)' did not pass strict quiescent trace validation."
        Assert-PhaseOneValue (
            (@($result.ActualGrants) -join ',') -eq
            (@($result.ExpectedGrants) -join ',')) `
            "Existing preflight result '$($result.Name)' did not replay its exact grants."
    }

    $grantReplayProjectPath = Join-Path $PSScriptRoot 'GrantReplay\GrantReplay.csproj'
    [xml]$grantReplayProject = Get-Content -LiteralPath $grantReplayProjectPath -Raw
    $targetFrameworks = @(
        $grantReplayProject.Project.PropertyGroup |
            ForEach-Object { [string]$_.TargetFramework } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    Assert-PhaseOneValue (
        $targetFrameworks.Count -eq 1 -and
        $targetFrameworks[0] -eq 'net11.0') `
        'GrantReplay does not target exactly net11.0.'
    $scannerParent = Join-Path $PreflightRoot '_tooling'
    $scannerEvidence = [Collections.Generic.List[object]]::new()
    foreach ($bootstrap in @($Base, $Final)) {
        $matches = @(
            Get-ChildItem -LiteralPath $scannerParent -Directory -Filter 'grant-replay-*' |
                Where-Object {
                    $markerPath = Join-Path $_.FullName 'build-identity.json'
                    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
                        return $false
                    }
                    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
                    return [string]$marker.BootstrapMSBuildSha256 -eq
                        [string]$bootstrap.MSBuildDllSha256
                }
        )
        Assert-PhaseOneValue ($matches.Count -eq 1) `
            "Existing preflight has no unique exact $($bootstrap.Role) GrantReplay scanner."
        $scannerRoot = $matches[0].FullName
        $markerPath = Join-Path $scannerRoot 'build-identity.json'
        $scannerPath = Join-Path $scannerRoot 'GrantReplay.dll'
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        Assert-PhaseOneValue (
            [string]$marker.BootstrapCommit -eq $bootstrap.ExpectedCommit -and
            [string]$marker.ScannerSha256 -eq
                (Get-FileHash -LiteralPath $scannerPath -Algorithm SHA256).Hash) `
            "Existing preflight $($bootstrap.Role) GrantReplay identity is invalid."
        Assert-PhaseOneValue (
            (Get-PhaseOneCanonicalPath -Path (Join-Path $scannerRoot 'intermediate')).StartsWith(
                "$(Get-PhaseOneCanonicalPath -Path $scannerRoot)\",
                [StringComparison]::OrdinalIgnoreCase)) `
            'GrantReplay intermediate root escaped its isolated scanner root.'
        $scannerEvidence.Add([pscustomobject][ordered]@{
            Role = $bootstrap.Role
            Commit = $bootstrap.ExpectedCommit
            MSBuildAssembliesRoot = $bootstrap.SdkRoot
            BootstrapMSBuildSha256 = $bootstrap.MSBuildDllSha256
            ScannerRoot = $scannerRoot
            IntermediateRoot = Join-Path $scannerRoot 'intermediate'
            ScannerSha256 = $marker.ScannerSha256
            Valid = $true
        })
    }
    Assert-PhaseOneValue (
        -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'GrantReplay\obj'))) `
        'GrantReplay created intermediates below its source directory.'

    $rootIdentities = @(
        foreach ($result in $results) {
            foreach ($run in @($result.Runs)) {
                [pscustomobject]@{
                    Kind = "existing-preflight/$($result.Name)/$($run.RunId)"
                    ProcessId = [int]$run.RootProcessId
                    ProcessStartUtc = [string]$run.ProcessStartUtc
                }
            }
        }
    )
    [pscustomobject][ordered]@{
        Valid = $true
        CompletionPath = $completionPath
        CompletionSha256 = (Get-FileHash -LiteralPath $completionPath -Algorithm SHA256).Hash
        FunctionalGrantSmokes = 4
        BinaryControllerTraces = 2
        StrictTraceParsing = $true
        EmptyFinalTraceStateRequired = $true
        Net11GrantReplay = $true
        GrantReplayProjectSha256 =
            (Get-FileHash -LiteralPath $grantReplayProjectPath -Algorithm SHA256).Hash
        GrantReplayScanners = $scannerEvidence.ToArray()
        CapturedRootIdentities = $rootIdentities
    }
}

function Invoke-PhaseOneDuplicateProbe {
    param(
        [Parameter(Mandatory)]
        [string]$IdentityPath,

        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$AttemptRoot
    )

    $attemptCountBefore = @(
        Get-ChildItem -LiteralPath $Root -Directory -Filter 'attempt-*'
    ).Count
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-BootstrapIdentityPath', $IdentityPath,
        '-OutputRoot', $Root
    )) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $processStartUtc = $null
    $stdout = ''
    $stderr = ''
    try {
        [void]$process.Start()
        $processIdentity = Register-StartedProcess `
            -Process $process `
            -Kind 'duplicate-probe' `
            -Source $AttemptRoot
        $processStartUtc =
            ConvertTo-UtcDateTimeOffset -Value $processIdentity.ProcessStartUtc
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $stop = Stop-VerifiedProcessTree `
                -RootProcessId $process.Id `
                -RootProcessStartUtc $processStartUtc
            throw "Duplicate probe timed out: $($stop.Errors -join '; ')"
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
        $attemptCountAfter = @(
            Get-ChildItem -LiteralPath $Root -Directory -Filter 'attempt-*'
        ).Count
        $live = Test-VerifiedProcessIdentity `
            -ProcessId $process.Id `
            -ProcessStartUtc $processStartUtc
        $record = [pscustomobject][ordered]@{
            Valid =
                $exitCode -ne 0 -and
                "$stdout`n$stderr".Contains(
                    'PHASE_ONE_DUPLICATE_INVOCATION',
                    [StringComparison]::Ordinal) -and
                $attemptCountAfter -eq $attemptCountBefore -and
                -not $live
            CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            SameExactInvocation = $true
            MutexName = Get-PhaseOneRootMutexName -OutputRoot $Root
            RootLockPath = Join-Path $Root '.phase-one-preflight.lock'
            ProcessId = $process.Id
            ProcessStartUtc = $processStartUtc.ToString('O')
            ExitCode = $exitCode
            RefusalMarker = 'PHASE_ONE_DUPLICATE_INVOCATION'
            RefusalObserved = "$stdout`n$stderr".Contains(
                'PHASE_ONE_DUPLICATE_INVOCATION',
                [StringComparison]::Ordinal)
            AttemptsBefore = $attemptCountBefore
            AttemptsAfter = $attemptCountAfter
            ProcessLiveAfterExit = $live
            StandardOutput = $stdout
            StandardError = $stderr
        }
        Write-JsonAtomic `
            -Path (Join-Path $AttemptRoot 'duplicate-refusal.json') `
            -Value $record `
            -Depth 6
        Assert-PhaseOneValue $record.Valid `
            'Concurrent duplicate invocation was not refused cleanly.'
        return $record
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-PhaseOneExpectedErrorCleanupProbe {
    param(
        [Parameter(Mandatory)]
        [string]$AttemptRoot
    )

    $probeRoot = Join-Path $AttemptRoot 'expected-error-cleanup'
    New-Item -ItemType Directory -Path $probeRoot | Out-Null
    $identityPath = Join-Path $probeRoot 'child-identity.json'
    $escapedIdentityPath = $identityPath.Replace("'", "''")
    $probeSource = @'
$ErrorActionPreference = 'Stop'
$childInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120')) {
    $childInfo.ArgumentList.Add($argument)
}
$childInfo.UseShellExecute = $false
$childInfo.CreateNoWindow = $true
$child = [Diagnostics.Process]::Start($childInfo)
[IO.File]::WriteAllText(
    '__IDENTITY_PATH__',
    ([pscustomobject]@{
        ProcessId = $child.Id
        ProcessStartUtc = $child.StartTime.ToUniversalTime().ToString('O')
    } | ConvertTo-Json -Compress),
    [Text.UTF8Encoding]::new($false))
try {
    Start-Sleep -Seconds 120
}
finally {
    $child.Dispose()
}
'@.Replace('__IDENTITY_PATH__', $escapedIdentityPath)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeSource))
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $probeRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $processStartUtc = $null
    $captured = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $controlledMessage = 'PHASE_ONE_CONTROLLED_EXPECTED_ERROR'
    $controlledObserved = $false
    $unexpectedError = $null
    $finallyExecuted = $false
    $stop = $null
    try {
        [void]$process.Start()
        $processIdentity = Register-StartedProcess `
            -Process $process `
            -Kind 'expected-error-cleanup-root' `
            -Source $probeRoot
        $processStartUtc =
            ConvertTo-UtcDateTimeOffset -Value $processIdentity.ProcessStartUtc
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
            if ($process.HasExited) {
                throw "Cleanup probe root exited early with code $($process.ExitCode)."
            }
            if ($timer.Elapsed.TotalSeconds -gt 15) {
                throw 'Cleanup probe child identity was not published within 15 seconds.'
            }
            Start-Sleep -Milliseconds 50
        }
        $childIdentity =
            Get-Content -LiteralPath $identityPath -Raw |
            ConvertFrom-Json
        [void]$captured.Add(
            "$([int]$childIdentity.ProcessId)|$([string]$childIdentity.ProcessStartUtc)")
        [void](Register-ProcessIdentity `
            -ProcessId ([int]$childIdentity.ProcessId) `
            -ProcessStartUtc $childIdentity.ProcessStartUtc `
            -Kind 'expected-error-cleanup-child' `
            -Source $probeRoot)
        $captureRun = [pscustomobject]@{
            RunId = 'expected-error-cleanup'
            Completed = $false
            RootProcessId = $process.Id
            DescendantIdentities = $captured
        }
        Update-ScenarioProcessTrees -Runs @($captureRun)
        throw $controlledMessage
    }
    catch {
        if ($_.Exception.Message -eq $controlledMessage) {
            $controlledObserved = $true
        }
        else {
            $unexpectedError = $_.Exception
        }
    }
    finally {
        $finallyExecuted = $true
        if ($null -ne $processStartUtc) {
            $stop = Stop-VerifiedProcessTree `
                -RootProcessId $process.Id `
                -RootProcessStartUtc $processStartUtc `
                -DescendantIdentities @($captured)
            if (-not $process.HasExited) {
                [void]$process.WaitForExit(15000)
            }
        }
    }

    $rootLive = if ($null -eq $processStartUtc) {
        $false
    }
    else {
        Test-VerifiedProcessIdentity `
            -ProcessId $process.Id `
            -ProcessStartUtc $processStartUtc
    }
    $liveDescendants = @(
        foreach ($identity in $captured) {
            $parts = $identity -split '\|', 2
            if (Test-VerifiedProcessIdentity `
                -ProcessId ([int]$parts[0]) `
                -ProcessStartUtc $parts[1]) {
                $identity
            }
        }
    )
    $record = [pscustomobject][ordered]@{
        Valid =
            $controlledObserved -and
            $null -eq $unexpectedError -and
            $finallyExecuted -and
            $null -ne $stop -and
            $stop.Succeeded -and
            -not $rootLive -and
            $liveDescendants.Count -eq 0
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        ControlledError = $controlledMessage
        ControlledErrorObserved = $controlledObserved
        UnexpectedError = if ($null -eq $unexpectedError) { $null } else { $unexpectedError.ToString() }
        FinallyExecuted = $finallyExecuted
        RootIdentity = if ($null -eq $processStartUtc) {
            $null
        }
        else {
            "$($process.Id)|$($processStartUtc.ToString('O'))"
        }
        CapturedDescendantIdentities = @($captured)
        StopResult = $stop
        RootLiveAfterFinally = $rootLive
        LiveDescendantsAfterFinally = $liveDescendants
    }
    Write-JsonAtomic `
        -Path (Join-Path $probeRoot 'validation.json') `
        -Value $record `
        -Depth 8
    $process.Dispose()
    Assert-PhaseOneValue $record.Valid `
        'Controlled expected-error cleanup did not prove root/descendant quiescence.'
    return $record
}

function Invoke-PhaseOneControllerLifecycleSmoke {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Bootstrap,

        [Parameter(Mandatory)]
        [string]$LifecycleRoot,

        [Parameter(Mandatory)]
        [string]$AttemptToolRoot,

        [Parameter(Mandatory)]
        [string]$JournalPath
    )

    if (Test-Path -LiteralPath $LifecycleRoot) {
        throw "Controller lifecycle root '$LifecycleRoot' already exists."
    }
    New-Item -ItemType Directory -Path $LifecycleRoot | Out-Null
    $debugPath = Join-Path $LifecycleRoot 'coordinator-debug'
    New-Item -ItemType Directory -Path $debugPath | Out-Null
    $pipeName = "cvf-phase1-lifecycle-$PID-$([guid]::NewGuid().ToString('N'))"
    $condition = 'FINAL-H'
    $initialWorkers = 18
    $injectionCompletion = 1
    $endingCompletion = 2
    $steadySeconds = 1
    $initialHoldSeconds = 4
    $runs = [Collections.Generic.List[object]]::new()
    $events = [Collections.Generic.List[object]]::new()
    $generation = [int[]]::new($initialWorkers + 1)
    $measuredIds = [Collections.Generic.List[string]]::new()
    $result = $null
    $executionException = $null
    $cleanupException = $null

    $addEvent = {
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [AllowNull()]
            [object]$Run,

            [hashtable]$Data = @{}
        )

        $entry = [ordered]@{
            TimestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
            Event = $Name
            RunId = if ($null -eq $Run) { $null } else { $Run.RunId }
            Worker = if ($null -eq $Run) { $null } else { $Run.Worker }
            Generation = if ($null -eq $Run) { $null } else { $Run.Generation }
        }
        foreach ($item in $Data.GetEnumerator()) {
            $entry[$item.Key] = $item.Value
        }
        $record = [pscustomobject]$entry
        $events.Add($record)
        Add-CommandJournalEntry `
            -JournalPath (Join-Path $LifecycleRoot 'controller-events.jsonl') `
            -Entry $record
    }

    try {
        foreach ($name in @((1..$initialWorkers | ForEach-Object { "normal$_" }) + @('injected'))) {
            $worktree = Join-Path $LifecycleRoot "worktrees\$name"
            New-Item -ItemType Directory -Force -Path $worktree | Out-Null
            Copy-Item `
                -LiteralPath (Join-Path $PSScriptRoot 'SyntheticWork.proj') `
                -Destination (Join-Path $worktree 'SyntheticWork.proj')
        }
        Write-JsonAtomic -Path (Join-Path $LifecycleRoot 'contract.json') -Value ([pscustomobject][ordered]@{
            SchemaVersion = 1
            Kind = 'controller-lifecycle-smoke'
            ProductionSteadySeconds = 30
            SmokeSteadySeconds = $steadySeconds
            ProductionInjectionCompletion = 6
            SmokeInjectionCompletion = $injectionCompletion
            ProductionEndingCompletion = 12
            SmokeEndingCompletion = $endingCompletion
            InitialWorkers = $initialWorkers
            NodeBudget = 16
            Condition = $condition
            BootstrapRole = $Bootstrap.Role
            BootstrapCommit = $Bootstrap.ExpectedCommit
            BootstrapProductVersion = $Bootstrap.ProductVersion
            BootstrapMSBuildSha256 = $Bootstrap.MSBuildDllSha256
            PipeName = $pipeName
            Synchronous = $true
            Workload = 'SyntheticWork.proj'
            WorkloadSha256 = (
                Get-FileHash `
                    -LiteralPath (Join-Path $PSScriptRoot 'SyntheticWork.proj') `
                    -Algorithm SHA256
            ).Hash
        })

        $scenarioStartedUtc = [DateTimeOffset]::UtcNow
        & $addEvent -Name ScenarioStarted -Run $null
        $initialRepository = [pscustomobject]@{
            BuildPath = 'SyntheticWork.proj'
            AdditionalBuildArguments = @("/p:HoldSeconds=$initialHoldSeconds")
        }
        foreach ($worker in 1..$initialWorkers) {
            $generation[$worker]++
            $run = Start-ScenarioBuild `
                -Bootstrap $Bootstrap `
                -Repository $initialRepository `
                -Worktree (Join-Path $LifecycleRoot "worktrees\normal$worker") `
                -Condition $condition `
                -PipeName $pipeName `
                -DebugPath $debugPath `
                -ScenarioRoot $LifecycleRoot `
                -RunId "normal$worker-g1" `
                -Kind normal `
                -Worker $worker `
                -Generation 1 `
                -ScenarioStartedUtc $scenarioStartedUtc
            $runs.Add($run)
            & $addEvent -Name Launched -Run $run
        }

        $onsetUtc = $null
        $stopReplacements = $false
        $lastTreeSampleUtc = [DateTimeOffset]::MinValue
        $lastTraceCheckUtc = [DateTimeOffset]::MinValue
        $preOnsetExitObservedUtc = $null
        while (-not $stopReplacements) {
            $now = [DateTimeOffset]::UtcNow
            if (($now - $lastTreeSampleUtc).TotalSeconds -ge 1) {
                Update-ScenarioProcessTrees -Runs $runs.ToArray()
                $lastTreeSampleUtc = $now
            }
            if ($null -eq $onsetUtc -and
                ($now - $lastTraceCheckUtc).TotalMilliseconds -ge 200) {
                $traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
                if ($traceFiles.Count -eq 1) {
                    $liveRecords = @($runs | ForEach-Object { ConvertTo-RunRecord -Run $_ })
                    $liveTrace = ConvertFrom-CoordinatorTrace `
                        -TracePaths $traceFiles `
                        -RunRecords $liveRecords `
                        -Budget 16 `
                        -StrictParsing
                    Assert-PhaseOneValue $liveTrace.Consistent `
                        "Live controller-lifecycle trace is inconsistent: $($liveTrace.Errors -join '; ')"
                    $onset = Test-SteadyOnsetState `
                        -Trace $liveTrace `
                        -NowUtc $now `
                        -ExpectedAllocation 12 `
                        -MinimumQueueDepth 2 `
                        -StableSeconds $steadySeconds `
                        -HandoffGapToleranceSeconds 1
                    if ($onset.Accepted) {
                        $onsetUtc = $now
                        & $addEvent -Name SteadyOnset -Run $null -Data @{
                            QueueDepth = $onset.QueueDepth
                            AllocatedNodes = $onset.AllocatedNodes
                            AllocationStableSeconds = $onset.AllocationStableSeconds
                            SemanticSaturationStartUtc = $onset.SemanticSaturationStartUtc
                            ControllerLifecycleSmoke = $true
                        }
                    }
                }
                elseif ($traceFiles.Count -gt 1) {
                    throw "Controller lifecycle produced $($traceFiles.Count) traces; expected one."
                }
                $lastTraceCheckUtc = $now
            }

            if ($null -eq $onsetUtc) {
                if (@($runs | Where-Object { $_.Process.HasExited }).Count -gt 0) {
                    if ($null -eq $preOnsetExitObservedUtc) {
                        $preOnsetExitObservedUtc = $now
                    }
                    elseif (($now - $preOnsetExitObservedUtc).TotalSeconds -gt 5) {
                        throw 'A synthetic build exited before controller-lifecycle onset was established.'
                    }
                }
                if (($now - $scenarioStartedUtc).TotalMinutes -gt 2) {
                    throw 'Controller-lifecycle smoke did not establish onset within two minutes.'
                }
                Start-Sleep -Milliseconds 50
                continue
            }

            $newlyCompleted = [Collections.Generic.List[object]]::new()
            foreach ($run in @($runs | Where-Object { -not $_.Completed -and $_.Process.HasExited })) {
                if (Complete-ExitedScenarioBuild -Run $run) {
                    $newlyCompleted.Add($run)
                }
            }
            foreach ($run in @($newlyCompleted | Sort-Object ProcessExitUtc)) {
                & $addEvent -Name Completed -Run $run -Data @{
                    ExitCode = $run.ExitCode
                    Quiescent = $run.Quiescent
                }
                $run.CompletionEventWritten = $true
                Assert-PhaseOneValue ($run.ExitCode -eq 0 -and $run.Quiescent) `
                    "Controller-lifecycle run '$($run.RunId)' failed or did not quiesce."

                if ($run.Kind -eq 'normal' -and
                    $measuredIds.Count -lt $endingCompletion) {
                    $measuredIds.Add($run.RunId)
                    & $addEvent -Name MeasuredCompletion -Run $run -Data @{
                        CompletionNumber = $measuredIds.Count
                    }
                    if ($measuredIds.Count -eq $injectionCompletion) {
                        $injectedRepository = [pscustomobject]@{
                            BuildPath = 'SyntheticWork.proj'
                            AdditionalBuildArguments = @('/p:HoldSeconds=1')
                        }
                        $injected = Start-ScenarioBuild `
                            -Bootstrap $Bootstrap `
                            -Repository $injectedRepository `
                            -Worktree (Join-Path $LifecycleRoot 'worktrees\injected') `
                            -Condition $condition `
                            -PipeName $pipeName `
                            -DebugPath $debugPath `
                            -ScenarioRoot $LifecycleRoot `
                            -RunId 'injected-g1' `
                            -Kind injected `
                            -Worker 0 `
                            -Generation 1 `
                            -ScenarioStartedUtc $scenarioStartedUtc `
                            -Injected
                        $runs.Add($injected)
                        & $addEvent -Name Injected -Run $injected -Data @{
                            AfterMeasuredCompletion = $measuredIds.Count
                        }
                    }
                    if ($measuredIds.Count -eq $endingCompletion) {
                        $stopReplacements = $true
                        & $addEvent -Name SteadyEnd -Run $run -Data @{
                            MeasuredCompletions = $measuredIds.Count
                            StopReplacement = $true
                            ControllerLifecycleSmoke = $true
                        }
                    }
                    else {
                        Assert-PhaseOneValue $run.Quiescent `
                            "Worker $($run.Worker) replacement was selected before quiescence."
                        $generation[$run.Worker]++
                        $replacementRepository = [pscustomobject]@{
                            BuildPath = 'SyntheticWork.proj'
                            AdditionalBuildArguments = @('/p:HoldSeconds=1')
                        }
                        $replacement = Start-ScenarioBuild `
                            -Bootstrap $Bootstrap `
                            -Repository $replacementRepository `
                            -Worktree $run.Worktree `
                            -Condition $condition `
                            -PipeName $pipeName `
                            -DebugPath $debugPath `
                            -ScenarioRoot $LifecycleRoot `
                            -RunId "normal$($run.Worker)-g$($generation[$run.Worker])" `
                            -Kind normal `
                            -Worker $run.Worker `
                            -Generation $generation[$run.Worker] `
                            -ScenarioStartedUtc $scenarioStartedUtc
                        $runs.Add($replacement)
                        & $addEvent -Name ReplacementLaunched -Run $replacement -Data @{
                            ReplacedRunId = $run.RunId
                            PriorExitCode = $run.ExitCode
                            PriorQuiescent = $run.Quiescent
                        }
                    }
                }
            }
            if (($now - $scenarioStartedUtc).TotalMinutes -gt 3) {
                throw 'Controller-lifecycle smoke did not reach its predeclared ending completion.'
            }
            Start-Sleep -Milliseconds 50
        }

        & $addEvent -Name DrainStarted -Run $null -Data @{
            ReplacementsStopped = $true
        }
        Wait-ScenarioBuilds -Runs $runs.ToArray() -TimeoutMinutes 3
        foreach ($run in @($runs | Where-Object {
            $_.Completed -and -not $_.CompletionEventWritten
        } | Sort-Object ProcessExitUtc)) {
            & $addEvent -Name Completed -Run $run -Data @{
                ExitCode = $run.ExitCode
                Quiescent = $run.Quiescent
                DuringDrain = $true
            }
            $run.CompletionEventWritten = $true
        }
        $runRecords = @($runs | ForEach-Object { ConvertTo-RunRecord -Run $_ })
        foreach ($run in $runRecords) {
            Assert-PhaseOneValue (
                $run.ExitCode -eq 0 -and
                $run.Quiescent -eq $true -and
                (Test-Path -LiteralPath $run.Binlog -PathType Leaf) -and
                (Get-Item -LiteralPath $run.Binlog).Length -gt 0) `
                "Controller-lifecycle run '$($run.RunId)' has invalid completion evidence."
            Assert-PhaseOneValue (
                [string]::IsNullOrWhiteSpace(
                    (Get-Content -LiteralPath $run.Stderr -Raw))) `
                "Controller-lifecycle run '$($run.RunId)' has nonempty stderr."
            Assert-PhaseOneValue (
                (Get-PhaseOneCanonicalPath -Path ([string]$run.Command.FileName)).Equals(
                    (Get-PhaseOneCanonicalPath -Path $Bootstrap.DotNetPath),
                    [StringComparison]::OrdinalIgnoreCase) -and
                (Get-PhaseOneCanonicalPath -Path ([string]$run.Command.Arguments[0])).Equals(
                    (Get-PhaseOneCanonicalPath -Path $Bootstrap.MSBuildDllPath),
                    [StringComparison]::OrdinalIgnoreCase)) `
                "Controller-lifecycle run '$($run.RunId)' did not use the exact bootstrap binary."
        }

        $traceFiles = @(Get-TraceFiles -DebugPath $debugPath)
        Assert-PhaseOneValue ($traceFiles.Count -eq 1) `
            "Controller lifecycle produced $($traceFiles.Count) traces; expected one."
        $trace = ConvertFrom-CoordinatorTrace `
            -TracePaths $traceFiles `
            -RunRecords $runRecords `
            -Budget 16 `
            -RequireEmptyFinalState `
            -StrictParsing
        [void](Export-CoordinatorTraceResult `
            -Trace $trace `
            -DestinationRoot (Join-Path $LifecycleRoot 'parsed-trace'))
        $replays = @(
            & (Join-Path $PSScriptRoot 'Invoke-GrantReplay.ps1') `
                -BootstrapRoot $Bootstrap.Root `
                -Binlog @($runRecords.Binlog) `
                -OutputPath (Join-Path $LifecycleRoot 'grant-replay.json') `
                -WorkRoot $AttemptToolRoot `
                -JournalPath $JournalPath
        )
        $scannerRoot = Join-Path `
            $AttemptToolRoot `
            "grant-replay-$($Bootstrap.MSBuildDllSha256.Substring(0, 12))"
        $scannerMarkerPath = Join-Path $scannerRoot 'build-identity.json'
        $scannerPath = Join-Path $scannerRoot 'GrantReplay.dll'
        Assert-PhaseOneValue (
            (Test-Path -LiteralPath $scannerMarkerPath -PathType Leaf) -and
            (Test-Path -LiteralPath $scannerPath -PathType Leaf)) `
            'Controller-lifecycle GrantReplay scanner identity is missing.'
        $scannerMarker =
            Get-Content -LiteralPath $scannerMarkerPath -Raw |
            ConvertFrom-Json
        Assert-PhaseOneValue (
            [string]$scannerMarker.BootstrapCommit -eq $Bootstrap.ExpectedCommit -and
            [string]$scannerMarker.BootstrapMSBuildSha256 -eq
                $Bootstrap.MSBuildDllSha256 -and
            [string]$scannerMarker.ScannerSha256 -eq
                (Get-FileHash -LiteralPath $scannerPath -Algorithm SHA256).Hash) `
            'Controller-lifecycle GrantReplay scanner is not bound to the exact binary.'
        & $addEvent -Name Drained -Run $null -Data @{
            FinalActiveWorkers = 0
            FinalQueueDepth = $trace.FinalQueueDepth
            FinalActiveBuilds = $trace.FinalActiveBuilds
            FinalAllocatedNodes = $trace.FinalAllocatedNodes
        }
        $validation = Test-PhaseOneControllerLifecycleContract `
            -Events $events.ToArray() `
            -Runs $runRecords `
            -Replays $replays `
            -Trace $trace `
            -InitialWorkers $initialWorkers `
            -InjectionCompletion $injectionCompletion `
            -EndingCompletion $endingCompletion
        Assert-PhaseOneValue $validation.Valid `
            "Controller-lifecycle contract failed: $($validation.Errors -join '; ')"

        $result = [pscustomobject][ordered]@{
            Valid = $true
            Kind = 'controller-lifecycle-smoke'
            Synchronous = $true
            BootstrapRole = $Bootstrap.Role
            BootstrapCommit = $Bootstrap.ExpectedCommit
            BootstrapProductVersion = $Bootstrap.ProductVersion
            BootstrapMSBuildSha256 = $Bootstrap.MSBuildDllSha256
            PipeName = $pipeName
            UniqueCoordinatorTraceCount = $traceFiles.Count
            StrictTraceParsing = $true
            GrantReplay = $true
            GrantReplayScanner = [pscustomobject]@{
                Root = $scannerRoot
                BootstrapCommit = $scannerMarker.BootstrapCommit
                BootstrapMSBuildSha256 = $scannerMarker.BootstrapMSBuildSha256
                ScannerSha256 = $scannerMarker.ScannerSha256
                IntermediateRoot = Join-Path $scannerRoot 'intermediate'
                Valid = $true
            }
            Contract = $validation
            MeasuredRunIds = $measuredIds.ToArray()
            Runs = $runRecords
            CapturedRootIdentities = @($runRecords | ForEach-Object {
                [pscustomobject]@{
                    Kind = "controller-lifecycle/$($_.RunId)"
                    ProcessId = [int]$_.RootProcessId
                    ProcessStartUtc = [string]$_.ProcessStartUtc
                }
            })
            CapturedDescendantIdentities = @(
                $runs |
                    ForEach-Object { @($_.DescendantIdentities) } |
                    Sort-Object -Unique
            )
            TraceSummary = [pscustomobject]@{
                Consistent = $trace.Consistent
                DeferredGrantOccurred = $trace.DeferredGrantOccurred
                MaximumQueueDepth = $validation.MaximumQueueDepth
                FinalQueueDepth = $trace.FinalQueueDepth
                FinalActiveBuilds = $trace.FinalActiveBuilds
                FinalAllocatedNodes = $trace.FinalAllocatedNodes
            }
        }
    }
    catch {
        $executionException = $_.Exception
    }
    finally {
        try {
            $cleanup = Stop-UnfinishedScenarioBuilds -Runs $runs.ToArray()
            $liveRoots = @(
                foreach ($run in $runs) {
                    if (Test-VerifiedProcessIdentity `
                        -ProcessId $run.RootProcessId `
                        -ProcessStartUtc $run.ProcessStartUtc) {
                        $run.RunId
                    }
                }
            )
            $liveDescendants = @(
                foreach ($run in $runs) {
                    foreach ($identity in @($run.DescendantIdentities)) {
                        $parts = $identity -split '\|', 2
                        if ($parts.Count -eq 2 -and
                            (Test-VerifiedProcessIdentity `
                                -ProcessId ([int]$parts[0]) `
                                -ProcessStartUtc $parts[1])) {
                            $identity
                        }
                    }
                }
            )
            $cleanupRecord = [pscustomobject][ordered]@{
                Valid =
                    $cleanup.Succeeded -and
                    $liveRoots.Count -eq 0 -and
                    $liveDescendants.Count -eq 0
                Cleanup = $cleanup
                LiveRootRunIds = $liveRoots
                LiveDescendantIdentities = $liveDescendants
            }
            Write-JsonAtomic `
                -Path (Join-Path $LifecycleRoot 'lifecycle-cleanup.json') `
                -Value $cleanupRecord `
                -Depth 8
            if (-not $cleanupRecord.Valid) {
                [void](Write-ScenarioCleanupTerminalOutcome `
                    -ScenarioRoot $LifecycleRoot `
                    -Cleanup $cleanup)
                $cleanupException = [InvalidOperationException]::new(
                    "Controller-lifecycle cleanup failed: $($cleanup.Errors -join '; ')")
            }
        }
        catch {
            $cleanupException = $_.Exception
        }
    }

    if ($null -ne $executionException -or $null -ne $cleanupException) {
        $failures = [Collections.Generic.List[Exception]]::new()
        if ($null -ne $executionException) {
            $failures.Add($executionException)
        }
        if ($null -ne $cleanupException) {
            $failures.Add($cleanupException)
        }
        $failure = if ($failures.Count -eq 1) {
            $failures[0]
        }
        else {
            [AggregateException]::new(
                'Controller-lifecycle execution and cleanup failed.',
                [Exception[]]$failures.ToArray())
        }
        Write-JsonAtomic -Path (Join-Path $LifecycleRoot 'failure.json') -Value ([pscustomobject]@{
            Valid = $false
            FailedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            Error = $failure.ToString()
            SuccessFallbackWritten = $false
        }) -Depth 8
        throw $failure
    }
    $result | Add-Member -NotePropertyName CleanupValidated -NotePropertyValue $true
    Write-JsonAtomic `
        -Path (Join-Path $LifecycleRoot 'completion.json') `
        -Value $result `
        -Depth 14
    return $result
}

if (-not [IO.Path]::IsPathFullyQualified($BootstrapIdentityPath)) {
    throw 'BootstrapIdentityPath must be an exact fully qualified path.'
}
if (-not [IO.Path]::IsPathFullyQualified($OutputRoot)) {
    throw 'OutputRoot must be one fixed fully qualified path.'
}
$repositoryRoot = Get-PhaseOneCanonicalPath -Path (
    Join-Path $PSScriptRoot '..\..\..\..')
$identityInput = Read-PhaseOneBootstrapIdentityInput -Path $BootstrapIdentityPath
$sourceBootstrapIdentityPath = $identityInput.SourcePath
$sourceBootstrapIdentitySha256 = $identityInput.SourceSha256
$outputSafety = Test-PhaseOneOutputRootSafety `
    -OutputRoot $OutputRoot `
    -IdentityInput $identityInput `
    -RepositoryRoot $repositoryRoot
if (-not $outputSafety.Valid) {
    throw "Unsafe OutputRoot: $($outputSafety.Errors -join '; ')"
}
$OutputRoot = $outputSafety.OutputRoot
$rootLock = Enter-PhaseOneRootLock -OutputRoot $OutputRoot
$rootFailures = [Collections.Generic.List[Exception]]::new()
$monitor = $null
$keepAwake = $null
$processRegistryPath = $null
$monitorCleanupAttempted = $false
$keepAwakeCleanupAttempted = $false
$finalProcessAuditAttempted = $false
try {
    $rootCompletionPath = Join-Path $OutputRoot 'completion.json'
    if (Test-Path -LiteralPath $rootCompletionPath -PathType Leaf) {
        $existingRootCompletion =
            Get-Content -LiteralPath $rootCompletionPath -Raw |
            ConvertFrom-Json
        $existingSnapshotPath = [string]$existingRootCompletion.BootstrapIdentityPath
        $existingSnapshotSha256 = [string]$existingRootCompletion.BootstrapIdentitySha256
        $existingValidation = Test-PhaseOneRootCompletionRecord `
            -Record $existingRootCompletion `
            -OutputRoot $OutputRoot `
            -BootstrapIdentityPath $existingSnapshotPath `
            -BootstrapIdentitySha256 $existingSnapshotSha256 `
            -SourceBootstrapIdentityPath $sourceBootstrapIdentityPath `
            -SourceBootstrapIdentitySha256 $sourceBootstrapIdentitySha256 `
            -ValidateFileSystem
        if (-not $existingValidation.Valid) {
            throw "Existing root completion is invalid: $($existingValidation.Errors -join '; ')"
        }
        $resumeBootstrap = Get-PhaseOneFinalBootstrapRehash `
            -BootstrapIdentityEvidence $existingRootCompletion.FinalBootstrapRehash
        Assert-PhaseOneValue $resumeBootstrap.Valid `
            'Existing root completion bootstrap identities no longer validate.'
        $resumeBinding = Test-PhaseOneBootstrapIdentityBinding `
            -SourcePath $sourceBootstrapIdentityPath `
            -SourceSha256 $sourceBootstrapIdentitySha256 `
            -SnapshotPath $existingSnapshotPath `
            -SnapshotSha256 $existingSnapshotSha256
        Assert-PhaseOneValue $resumeBinding.Valid `
            "Existing root completion input binding failed: $($resumeBinding.Errors -join '; ')"
        Write-Host "PHASE_ONE_PREFLIGHT_COMPLETION=$rootCompletionPath"
        return
    }

    $attempt = New-PhaseOneAttemptRoot -OutputRoot $OutputRoot
    $attemptRoot = $attempt.Path
    $attemptStartedUtc = [DateTimeOffset]::UtcNow
    $identitySnapshot = New-PhaseOneBootstrapIdentitySnapshot `
        -IdentityInput $identityInput `
        -AttemptRoot $attemptRoot
    $BootstrapIdentityPath = $identitySnapshot.SnapshotPath
    $bootstrapIdentitySha256 = $identitySnapshot.SnapshotSha256
    $processRegistryPath = Join-Path $attemptRoot 'process-registry.jsonl'
    [void](Initialize-ToolingProcessRegistry -Path $processRegistryPath)
    Write-JsonAtomic `
        -Path (Join-Path $attemptRoot 'output-root-safety.json') `
        -Value $outputSafety `
        -Depth 10
    Write-JsonAtomic `
        -Path (Join-Path $attemptRoot 'bootstrap-identity-snapshot.json') `
        -Value $identitySnapshot `
        -Depth 6
    Write-JsonAtomic -Path (Join-Path $attemptRoot 'started.json') -Value ([pscustomobject][ordered]@{
        SchemaVersion = 1
        Kind = 'PhaseOneDisposablePreflightAttempt'
        StartedUtc = $attemptStartedUtc.ToString('O')
        ProcessId = $PID
        ProcessStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')
        AttemptNumber = $attempt.Number
        AttemptRelativePath = $attempt.RelativePath
        OutputRoot = $OutputRoot
        BootstrapIdentityPath = $BootstrapIdentityPath
        BootstrapIdentitySha256 = $bootstrapIdentitySha256
        SourceBootstrapIdentityPath = $sourceBootstrapIdentityPath
        SourceBootstrapIdentitySha256 = $sourceBootstrapIdentitySha256
        ProcessRegistryPath = $processRegistryPath
        OutputRootSafety = $outputSafety
        Synchronous = $true
        DetachedCampaignLaunched = $false
    })

    $components = [ordered]@{
        OutputRootSafety = $outputSafety
    }
    $base = $null
    $final = $null
    $monitor = $null
    $monitorStartRecord = $null
    $keepAwake = $null
    $executionException = $null
    $cleanupExceptions = [Collections.Generic.List[Exception]]::new()
    $existingEvidence = $null
    $lifecycleEvidence = $null
    $duplicateEvidence = $null
    $expectedErrorEvidence = $null
    try {
        $initialInputBinding = Test-PhaseOneBootstrapIdentityBinding `
            -SourcePath $sourceBootstrapIdentityPath `
            -SourceSha256 $sourceBootstrapIdentitySha256 `
            -SnapshotPath $BootstrapIdentityPath `
            -SnapshotSha256 $bootstrapIdentitySha256
        Assert-PhaseOneValue $initialInputBinding.Valid `
            "Bootstrap identity changed while freezing the attempt: $($initialInputBinding.Errors -join '; ')"
        Write-JsonAtomic `
            -Path (Join-Path $attemptRoot 'bootstrap-input-binding.json') `
            -Value $initialInputBinding `
            -Depth 6
        $keepAwake = Enable-CampaignKeepAwake
        Write-JsonAtomic `
            -Path (Join-Path $attemptRoot 'keep-awake-start.json') `
            -Value $keepAwake

        $bootstrapValidation = Get-PhaseOneBootstrapEvidence `
            -IdentityPath $BootstrapIdentityPath `
            -EvidenceRoot (Join-Path $attemptRoot 'bootstrap')
        $base = $bootstrapValidation.Base
        $final = $bootstrapValidation.Final
        $bootstrapValidation.Evidence | Add-Member `
            -NotePropertyName Snapshot `
            -NotePropertyValue $identitySnapshot
        $bootstrapValidation.Evidence | Add-Member `
            -NotePropertyName InitialInputBinding `
            -NotePropertyValue $initialInputBinding
        $components.BootstrapIdentity = $bootstrapValidation.Evidence

        $monitorRoot = Join-Path $attemptRoot 'resource-monitor'
        $monitor = Start-ScenarioMonitor -MonitorRoot $monitorRoot
        $monitorStartRecord = [pscustomobject][ordered]@{
            StartedUtc = $monitor.ProcessStartUtc.ToString('O')
            ProcessId = $monitor.Process.Id
            ProcessStartUtc = $monitor.ProcessStartUtc.ToString('O')
            ReadyPath = $monitor.ReadyFile
            ReadyObserved = Test-Path -LiteralPath $monitor.ReadyFile -PathType Leaf
            ReadyObservedUtc = $monitor.ReadyObservedUtc.ToString('O')
            StopPath = $monitor.StopFile
            SampleIntervalSeconds = 1
            ProcessIntervalSeconds = 5
            ProbeIntervalSeconds = 5
        }
        Write-JsonAtomic `
            -Path (Join-Path $monitorRoot 'lifecycle-start.json') `
            -Value $monitorStartRecord
        Assert-PhaseOneValue $monitorStartRecord.ReadyObserved `
            'Resource monitor did not prove readiness.'

        $duplicateEvidence = Invoke-PhaseOneDuplicateProbe `
            -IdentityPath $sourceBootstrapIdentityPath `
            -Root $OutputRoot `
            -AttemptRoot $attemptRoot
        $components.DuplicateRefusal = $duplicateEvidence

        $expectedErrorEvidence = Invoke-PhaseOneExpectedErrorCleanupProbe `
            -AttemptRoot $attemptRoot
        $components.ExpectedErrorCleanup = $expectedErrorEvidence

        $existingPreflightRoot = Join-Path $attemptRoot 'existing-preflight'
        $null = & (Join-Path $PSScriptRoot 'Run-PreflightValidation.ps1') `
            -BootstrapIdentityPath $BootstrapIdentityPath `
            -OutputRoot $existingPreflightRoot
        $existingEvidence = Get-PhaseOneExistingPreflightEvidence `
            -PreflightRoot $existingPreflightRoot `
            -Base $base `
            -Final $final
        Write-JsonAtomic `
            -Path (Join-Path $existingPreflightRoot 'phase-one-validation.json') `
            -Value $existingEvidence `
            -Depth 10
        $components.ExistingPreflight = $existingEvidence

        $lifecycleEvidence = Invoke-PhaseOneControllerLifecycleSmoke `
            -Bootstrap $final `
            -LifecycleRoot (Join-Path $attemptRoot 'controller-lifecycle-smoke') `
            -AttemptToolRoot (Join-Path $attemptRoot '_tooling') `
            -JournalPath (Join-Path $attemptRoot 'commands.jsonl')
        $components.ControllerLifecycleSmoke = $lifecycleEvidence
    }
    catch {
        $executionException = $_.Exception
    }
    finally {
        try {
            if ($null -eq $base -or $null -eq $final) {
                throw 'Both exact bootstraps were not available for final build-server shutdown.'
            }
            Invoke-BuildServerShutdown `
                -Bootstraps @($base, $final) `
                -JournalPath (Join-Path $attemptRoot 'commands.jsonl') `
                -OutputDirectory (Join-Path $attemptRoot 'command-output')
            $components.BuildServerShutdown = [pscustomobject][ordered]@{
                Valid = $true
                CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                Roles = @($base.Role, $final.Role)
                Commits = @($base.ExpectedCommit, $final.ExpectedCommit)
                BothExactBuildServersShutdown = $true
            }
            Write-JsonAtomic `
                -Path (Join-Path $attemptRoot 'build-server-shutdown.json') `
                -Value $components.BuildServerShutdown
        }
        catch {
            $shutdownException = $_.Exception
            $cleanupExceptions.Add($shutdownException)
            $components.BuildServerShutdown = [pscustomobject][ordered]@{
                Valid = $false
                CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                Error = $shutdownException.ToString()
                BothExactBuildServersShutdown = $false
            }
            try {
                Write-JsonAtomic `
                    -Path (Join-Path $attemptRoot 'build-server-shutdown.json') `
                    -Value $components.BuildServerShutdown `
                    -Depth 8
            }
            catch {
                $cleanupExceptions.Add($_.Exception)
            }
        }

        if ($null -ne $monitor) {
            $monitorCleanupAttempted = $true
            try {
                $monitorProcessId = $monitor.Process.Id
                $monitorProcessStartUtc = $monitor.ProcessStartUtc
                Stop-ScenarioMonitor -Monitor $monitor
                $continuity = Test-TelemetryContinuity `
                    -MonitorRoot (Join-Path $attemptRoot 'resource-monitor') `
                    -ReadyUtc $monitor.ReadyObservedUtc `
                    -StopUtc $monitor.StopRequestedUtc
                $monitorLive = Test-VerifiedProcessIdentity `
                    -ProcessId $monitorProcessId `
                    -ProcessStartUtc $monitorProcessStartUtc
                $monitorRecord = [pscustomobject][ordered]@{
                    Valid =
                        $monitorStartRecord.ReadyObserved -and
                        (Test-Path -LiteralPath $monitorStartRecord.StopPath -PathType Leaf) -and
                        -not $monitorLive -and
                        $continuity.Valid
                    Started = $monitorStartRecord
                    StopObserved =
                        Test-Path -LiteralPath $monitorStartRecord.StopPath -PathType Leaf
                    StopRequestedUtc = $monitor.StopRequestedUtc.ToString('O')
                    StopFileObservedUtc = $monitor.StopFileObservedUtc.ToString('O')
                    ProcessExitObservedUtc = $monitor.ProcessExitObservedUtc.ToString('O')
                    ProcessExited = -not $monitorLive
                    HardGapValidation = $continuity
                }
                Write-JsonAtomic `
                    -Path (Join-Path $attemptRoot 'resource-monitor\lifecycle-completion.json') `
                    -Value $monitorRecord `
                    -Depth 10
                Assert-PhaseOneValue $monitorRecord.Valid `
                    "Resource monitor lifecycle/continuity failed: $($continuity.Errors -join '; ')"
                $components.ResourceMonitor = $monitorRecord
            }
            catch {
                $monitorException = $_.Exception
                $cleanupExceptions.Add($monitorException)
                $components.ResourceMonitor = [pscustomobject][ordered]@{
                    Valid = $false
                    Started = $monitorStartRecord
                    Error = $monitorException.ToString()
                }
            }
        }
        else {
            $components.ResourceMonitor = [pscustomobject]@{
                Valid = $false
                Error = 'Resource monitor was not started.'
            }
        }

        if ($null -ne $keepAwake) {
            $keepAwakeCleanupAttempted = $true
            try {
                $restore = Disable-CampaignKeepAwake -State $keepAwake
                $keepAwakeRecord = [pscustomobject][ordered]@{
                    Valid = $restore.Restored -eq $true
                    Enabled = $true
                    FinallyExecuted = $true
                    RequestedUtc = $restore.RequestedUtc
                    PreviousExecutionState = $restore.PreviousExecutionState
                    RestoredUtc = $restore.RestoredUtc
                    RestoreResult = $restore.RestoreResult
                    Restored = $restore.Restored
                }
                Write-JsonAtomic `
                    -Path (Join-Path $attemptRoot 'keep-awake.json') `
                    -Value $keepAwakeRecord
                Assert-PhaseOneValue $keepAwakeRecord.Valid `
                    'Keep-awake execution state was not restored.'
                $components.KeepAwake = $keepAwakeRecord
            }
            catch {
                $keepAwakeException = $_.Exception
                $cleanupExceptions.Add($keepAwakeException)
                $components.KeepAwake = [pscustomobject][ordered]@{
                    Valid = $false
                    Enabled = $true
                    FinallyExecuted = $true
                    Error = $keepAwakeException.ToString()
                }
            }
        }
        else {
            $components.KeepAwake = [pscustomobject]@{
                Valid = $false
                Enabled = $false
                FinallyExecuted = $true
                Error = 'Keep-awake was not enabled.'
            }
        }

        try {
            $auditRecord = Invoke-PhaseOneRegisteredProcessAudit `
                -RegistryPath $processRegistryPath `
                -TimeoutSeconds 15
            Write-JsonAtomic `
                -Path (Join-Path $attemptRoot 'process-cleanup-audit-initial.json') `
                -Value $auditRecord `
                -Depth 12
            Assert-PhaseOneValue $auditRecord.Valid `
                "Registered process cleanup/audit failed: $(@($auditRecord.VerifiedStop.Errors) + @($auditRecord.Audit.Identities | Where-Object { $_.Status -notin @('ConfirmedAbsent', 'IdentityMismatch') } | ForEach-Object { "$($_.Kind):$($_.Status)" }) -join '; ')"
            $components.ProcessCleanupAudit = $auditRecord
        }
        catch {
            $auditException = $_.Exception
            $cleanupExceptions.Add($auditException)
            $components.ProcessCleanupAudit = [pscustomobject]@{
                Valid = $false
                Error = $auditException.ToString()
                RegistryPath = $processRegistryPath
            }
        }
    }

    $finalProcessAudit = $null
    $finalProcessAuditAttempted = $true
    try {
        $finalProcessAudit = Invoke-PhaseOneRegisteredProcessAudit `
            -RegistryPath $processRegistryPath `
            -TimeoutSeconds 15
        $finalProcessAudit | Add-Member `
            -NotePropertyName FinalPass `
            -NotePropertyValue $true
        Write-JsonAtomic `
            -Path (Join-Path $attemptRoot 'process-cleanup-audit.json') `
            -Value $finalProcessAudit `
            -Depth 12
        Assert-PhaseOneValue $finalProcessAudit.Valid `
            'Final registered process stop/audit did not prove every identity absent.'
        $components.ProcessCleanupAudit = $finalProcessAudit
    }
    catch {
        $cleanupExceptions.Add($_.Exception)
        $components.ProcessCleanupAudit = [pscustomobject]@{
            Valid = $false
            FinalPass = $true
            RegistryPath = $processRegistryPath
            Audit = $finalProcessAudit
            Error = $_.Exception.ToString()
        }
    }

    $finalBootstrapRehash = $null
    if ($null -eq $executionException -and $cleanupExceptions.Count -eq 0) {
        try {
            $binding = Test-PhaseOneBootstrapIdentityBinding `
                -SourcePath $sourceBootstrapIdentityPath `
                -SourceSha256 $sourceBootstrapIdentitySha256 `
                -SnapshotPath $BootstrapIdentityPath `
                -SnapshotSha256 $bootstrapIdentitySha256
            Assert-PhaseOneValue $binding.Valid `
                "Bootstrap identity binding changed before promotion: $($binding.Errors -join '; ')"
            $registryEntryCountBeforeFinalRehash =
                @(Get-ToolingProcessRegistry).Count
            Assert-PhaseOneValue (
                $registryEntryCountBeforeFinalRehash -eq
                    [int]$finalProcessAudit.RegistryEntryCount) `
                'Process registry changed after the final cleanup audit.'
            $finalBootstrapRehash = Get-PhaseOneFinalBootstrapRehash `
                -BootstrapIdentityEvidence $components.BootstrapIdentity
            $registryEntryCountAfterFinalRehash =
                @(Get-ToolingProcessRegistry).Count
            Assert-PhaseOneValue (
                $registryEntryCountAfterFinalRehash -eq
                    $registryEntryCountBeforeFinalRehash) `
                'Final bootstrap rehash unexpectedly registered a native process.'
            $components.PromotionRevalidation = [pscustomobject][ordered]@{
                Valid = $true
                CheckedUtc = $finalBootstrapRehash.CheckedUtc
                FinalProcessCleanupAuditCheckedUtc = $finalProcessAudit.CheckedUtc
                FinalProcessCleanupRegistrySha256 = $finalProcessAudit.RegistrySha256
                RegistryEntryCountBeforeFinalRehash =
                    $registryEntryCountBeforeFinalRehash
                RegistryEntryCountAfterFinalRehash =
                    $registryEntryCountAfterFinalRehash
                InputBinding = $binding
                FinalBootstrapRehashSha256 = $finalBootstrapRehash.BindingSha256
                FinalBootstrapRehash = $finalBootstrapRehash
                ProductVersionsRechecked = $true
                TrackedBinariesRehashed = $true
                ImmutableStagesRehashed = $true
                SourceInputHashRechecked = $true
                ManagedOnlyAfterFinalProcessAudit = $true
                NativeCallsAfterRehash = 0
            }
        }
        catch {
            $executionException = $_.Exception
            $components.PromotionRevalidation = [pscustomobject]@{
                Valid = $false
                Error = $_.Exception.ToString()
                ManagedOnlyAfterFinalProcessAudit = $true
            }
        }
    }
    elseif (-not $components.Contains('PromotionRevalidation')) {
        $components.PromotionRevalidation = [pscustomobject]@{
            Valid = $false
            Error = 'Final bootstrap rehash was skipped because execution or final process cleanup failed.'
        }
    }

    $requiredComponents = @(
        'BootstrapIdentity',
        'OutputRootSafety',
        'ExistingPreflight',
        'ControllerLifecycleSmoke',
        'ResourceMonitor',
        'KeepAwake',
        'DuplicateRefusal',
        'ExpectedErrorCleanup',
        'BuildServerShutdown',
        'ProcessCleanupAudit',
        'PromotionRevalidation'
    )
    foreach ($name in $requiredComponents) {
        if (-not $components.Contains($name) -or
            (Get-PhaseOneRecordProperty -Record $components[$name] -Name Valid) -ne $true) {
            if ($null -eq $executionException) {
                $executionException = [InvalidOperationException]::new(
                    "Required Phase 1 component '$name' is missing or invalid.")
            }
        }
    }
    if ($null -ne $executionException -or $cleanupExceptions.Count -gt 0) {
        $failures = [Collections.Generic.List[Exception]]::new()
        if ($null -ne $executionException) {
            $failures.Add($executionException)
        }
        foreach ($exception in $cleanupExceptions) {
            $failures.Add($exception)
        }
        $failure = if ($failures.Count -eq 1) {
            $failures[0]
        }
        else {
            [AggregateException]::new(
                'Phase 1 disposable preflight execution or final cleanup failed.',
                [Exception[]]$failures.ToArray())
        }
        Write-JsonAtomic -Path (Join-Path $attemptRoot 'failure.json') -Value ([pscustomobject][ordered]@{
            SchemaVersion = 1
            Kind = 'PhaseOneDisposablePreflightAttempt'
            Valid = $false
            FailedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            AttemptNumber = $attempt.Number
            AttemptRelativePath = $attempt.RelativePath
            BootstrapIdentityPath = $BootstrapIdentityPath
            BootstrapIdentitySha256 = $bootstrapIdentitySha256
            SourceBootstrapIdentityPath = $sourceBootstrapIdentityPath
            SourceBootstrapIdentitySha256 = $sourceBootstrapIdentitySha256
            ProcessRegistryPath = $processRegistryPath
            Error = $failure.ToString()
            ExecutionError =
                if ($null -eq $executionException) { $null } else { $executionException.ToString() }
            CleanupErrors = @($cleanupExceptions | ForEach-Object { $_.ToString() })
            Components = [pscustomobject]$components
            RetryCreatesNextAttemptInSameRoot = $true
            RootCompletionWritten = $false
            SuccessFallbackWritten = $false
        }) -Depth 16
        throw $failure
    }

    $attemptCompletionPath = Join-Path $attemptRoot 'completion.json'
    $attemptCompletion = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Kind = 'PhaseOneDisposablePreflightAttempt'
        Valid = $true
        StartedUtc = $attemptStartedUtc.ToString('O')
        CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        AttemptNumber = $attempt.Number
        AttemptRelativePath = $attempt.RelativePath
        OutputRoot = $OutputRoot
        BootstrapIdentityPath = $BootstrapIdentityPath
        BootstrapIdentitySha256 = $bootstrapIdentitySha256
        SourceBootstrapIdentityPath = $sourceBootstrapIdentityPath
        SourceBootstrapIdentitySha256 = $sourceBootstrapIdentitySha256
        FinalBootstrapRehashSha256 = $finalBootstrapRehash.BindingSha256
        FinalBootstrapRehash = $finalBootstrapRehash
        ProcessRegistryPath = $processRegistryPath
        Synchronous = $true
        DetachedCampaignLaunched = $false
        ControllerLifecycleKind = 'controller-lifecycle-smoke'
        Components = [pscustomobject]$components
        ValidatedComponentCount = $requiredComponents.Count
    }
    try {
        Write-JsonAtomic `
            -Path $attemptCompletionPath `
            -Value $attemptCompletion `
            -Depth 16
        $componentSummaries = [ordered]@{}
        foreach ($name in $requiredComponents) {
            $componentSummaries[$name] = [pscustomobject]@{
                Valid = $true
                EvidenceRoot = $attempt.RelativePath
            }
        }
        $rootCompletion = [pscustomobject][ordered]@{
            SchemaVersion = 1
            Kind = 'PhaseOneDisposablePreflight'
            Valid = $true
            CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            OutputRoot = $OutputRoot
            BootstrapIdentityPath = $BootstrapIdentityPath
            BootstrapIdentitySha256 = $bootstrapIdentitySha256
            SourceBootstrapIdentityPath = $sourceBootstrapIdentityPath
            SourceBootstrapIdentitySha256 = $sourceBootstrapIdentitySha256
            FinalBootstrapRehashSha256 = $finalBootstrapRehash.BindingSha256
            FinalBootstrapRehash = $finalBootstrapRehash
            AttemptNumber = $attempt.Number
            AttemptRelativePath = $attempt.RelativePath
            AttemptCompletionRelativePath = Join-Path $attempt.RelativePath 'completion.json'
            AttemptCompletionSha256 =
                (Get-FileHash -LiteralPath $attemptCompletionPath -Algorithm SHA256).Hash
            Synchronous = $true
            DetachedCampaignLaunched = $false
            RetryModel = 'Numbered attempts remain under this fixed root; only a valid root completion returns.'
            RawArtifactsOutsideGit =
                $components.OutputRootSafety.Valid -eq $true -and
                $components.OutputRootSafety.ValidatedBeforeWrites -eq $true -and
                $components.OutputRootSafety.InsideGitWorktree -eq $false -and
                [int]$components.OutputRootSafety.ProtectedPathOverlapCount -eq 0
            Components = [pscustomobject]$componentSummaries
        }
        $rootValidation = Test-PhaseOneRootCompletionRecord `
            -Record $rootCompletion `
            -OutputRoot $OutputRoot `
            -BootstrapIdentityPath $BootstrapIdentityPath `
            -BootstrapIdentitySha256 $bootstrapIdentitySha256 `
            -SourceBootstrapIdentityPath $sourceBootstrapIdentityPath `
            -SourceBootstrapIdentitySha256 $sourceBootstrapIdentitySha256 `
            -ValidateFileSystem
        Assert-PhaseOneValue $rootValidation.Valid `
            "Refusing root completion: $($rootValidation.Errors -join '; ')"
        Write-JsonAtomic -Path $rootCompletionPath -Value $rootCompletion -Depth 10
    }
    catch {
        $promotionException = $_.Exception
        $unpromotedPath = Join-Path $attemptRoot 'unpromoted-completion.json'
        if ((Test-Path -LiteralPath $attemptCompletionPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $rootCompletionPath -PathType Leaf)) {
            Move-Item `
                -LiteralPath $attemptCompletionPath `
                -Destination $unpromotedPath `
                -Force
        }
        Write-JsonAtomic -Path (Join-Path $attemptRoot 'failure.json') -Value ([pscustomobject][ordered]@{
            SchemaVersion = 1
            Kind = 'PhaseOneDisposablePreflightAttempt'
            Valid = $false
            FailedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            AttemptNumber = $attempt.Number
            AttemptRelativePath = $attempt.RelativePath
            BootstrapIdentityPath = $BootstrapIdentityPath
            BootstrapIdentitySha256 = $bootstrapIdentitySha256
            SourceBootstrapIdentityPath = $sourceBootstrapIdentityPath
            SourceBootstrapIdentitySha256 = $sourceBootstrapIdentitySha256
            ProcessRegistryPath = $processRegistryPath
            Error = $promotionException.ToString()
            Phase = 'RootCompletionPromotion'
            Components = [pscustomobject]$components
            UnpromotedCompletionPath =
                if (Test-Path -LiteralPath $unpromotedPath -PathType Leaf) {
                    $unpromotedPath
                }
                else {
                    $null
                }
            RootCompletionWritten =
                Test-Path -LiteralPath $rootCompletionPath -PathType Leaf
            RetryCreatesNextAttemptInSameRoot = $true
            SuccessFallbackWritten = $false
        }) -Depth 16
        throw $promotionException
    }
    Write-Host "PHASE_ONE_PREFLIGHT_COMPLETION=$rootCompletionPath"
}
catch {
    $rootFailures.Add($_.Exception)
}
finally {
    if ($null -ne $monitor -and -not $monitorCleanupAttempted) {
        try {
            Stop-ScenarioMonitor -Monitor $monitor
        }
        catch {
            $rootFailures.Add($_.Exception)
        }
    }
    if ($null -ne $keepAwake -and -not $keepAwakeCleanupAttempted) {
        try {
            $fallbackRestore = Disable-CampaignKeepAwake -State $keepAwake
            if (-not $fallbackRestore.Restored) {
                throw 'Fallback keep-awake restoration failed.'
            }
        }
        catch {
            $rootFailures.Add($_.Exception)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($processRegistryPath) -and
        -not $finalProcessAuditAttempted) {
        try {
            $fallbackAudit = Invoke-PhaseOneRegisteredProcessAudit `
                -RegistryPath $processRegistryPath `
                -TimeoutSeconds 15
            if (-not $fallbackAudit.Valid) {
                throw 'Fallback registered process stop/audit failed.'
            }
        }
        catch {
            $rootFailures.Add($_.Exception)
        }
    }
    try {
        Exit-PhaseOneRootLock -Lock $rootLock
    }
    catch {
        $rootFailures.Add($_.Exception)
    }
    if ($rootFailures.Count -eq 1) {
        throw $rootFailures[0]
    }
    if ($rootFailures.Count -gt 1) {
        throw [AggregateException]::new(
            'Phase 1 execution and root-lock cleanup failed.',
            [Exception[]]$rootFailures.ToArray())
    }
}
