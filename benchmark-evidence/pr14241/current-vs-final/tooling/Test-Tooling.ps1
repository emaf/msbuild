[CmdletBinding()]
param(
    [switch]$KeepOutput,
    [string]$ResultPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot '.test-output'
Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $testRoot | Out-Null
$assertionCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $script:assertionCount++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,
        [AllowNull()]
        [object]$Expected,
        [Parameter(Mandatory)]
        [string]$Message
    )

    Assert-True -Condition ($Actual -eq $Expected) -Message "$Message (actual='$Actual', expected='$Expected')"
}

function Start-TestPowerShellProcess {
    param(
        [Parameter(Mandatory)]
        [string]$Script,
        [switch]$RedirectOutput
    )

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    foreach ($argument in @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $RedirectOutput
    $startInfo.RedirectStandardError = $RedirectOutput
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    return $process
}

try {
    $parseErrors = [Collections.Generic.List[string]]::new()
    foreach ($scriptFile in Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.ps1') {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptFile.FullName,
            [ref]$tokens,
            [ref]$errors)
        foreach ($error in $errors) {
            $parseErrors.Add("$($scriptFile.Name):$($error.Extent.StartLineNumber): $($error.Message)")
        }
    }
    Assert-Equal -Actual $parseErrors.Count -Expected 0 -Message 'All PowerShell scripts parse'

    foreach ($jsonFile in Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.json') {
        [void](Get-Content -LiteralPath $jsonFile.FullName -Raw | ConvertFrom-Json)
    }
    foreach ($xmlFile in Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
        Where-Object Extension -in @('.csproj', '.proj')) {
        [xml](Get-Content -LiteralPath $xmlFile.FullName -Raw) | Out-Null
    }
    $grantProjectText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'GrantReplay\GrantReplay.csproj') -Raw
    Assert-True -Condition $grantProjectText.Contains('$(MSBuildAssembliesRoot)', [StringComparison]::Ordinal) -Message 'Grant scanner uses injected exact assembly root'
    Assert-True -Condition (-not $grantProjectText.Contains('C:\perf', [StringComparison]::OrdinalIgnoreCase)) -Message 'Grant scanner project has no historical hard-coded bootstrap'
    Assert-True -Condition $grantProjectText.Contains('<TargetFramework>net11.0</TargetFramework>', [StringComparison]::Ordinal) -Message 'Grant scanner targets the exact bootstrap runtime generation'
    $exactBuildText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Build-ExactRevisions.ps1') -Raw
    Assert-True -Condition $exactBuildText.Contains('Test-ImmutableBootstrapStage', [StringComparison]::Ordinal) -Message 'Exact builds can reuse only integrity-validated immutable stages'
    Assert-True -Condition $exactBuildText.Contains('ReusedValidatedStages', [StringComparison]::Ordinal) -Message 'Exact build identity records disclose validated stage reuse'
    $commonText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Campaign.Common.ps1') -Raw
    Assert-True -Condition $commonText.Contains('/NJS /NP | Out-Null', [StringComparison]::Ordinal) -Message 'Immutable staging suppresses native copy output before returning identity'
    $preflightText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Run-PreflightValidation.ps1') -Raw
    Assert-True -Condition $preflightText.Contains("'base-functional-isolated'", [StringComparison]::Ordinal) -Message 'Preflight includes an exact BASE functional grant smoke'
    Assert-True -Condition $preflightText.Contains("'final-functional-default-isolated'", [StringComparison]::Ordinal) -Message 'Preflight includes an exact FINAL functional grant smoke'
    Assert-True -Condition $preflightText.Contains('Stop-UnfinishedScenarioBuilds', [StringComparison]::Ordinal) -Message 'Preflight synthetic failures clean captured process trees in finally'
    Assert-True -Condition $preflightText.Contains('BuildServerShutdownError', [StringComparison]::Ordinal) -Message 'Preflight failure evidence retains build-server shutdown errors'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Run-DirectProjectSmoke.ps1') -PathType Leaf) -Message 'Preflight includes direct isolated project smoke tooling'
    $invokeScenarioText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Scenario.ps1') -Raw
    Assert-True -Condition $invokeScenarioText.Contains('Stop-UnfinishedScenarioBuilds', [StringComparison]::Ordinal) -Message 'Scenario finally performs verified captured-build cleanup'
    Assert-True -Condition $invokeScenarioText.Contains('Test-SustainedControllerEvents', [StringComparison]::Ordinal) -Message 'Scenario output enforces sustained controller event validation'
    $analyzeText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Analyze-Campaign.ps1') -Raw
    Assert-True -Condition $analyzeText.Contains('Test-ScenarioEvidenceIdentity', [StringComparison]::Ordinal) -Message 'Analysis validates evidence identity before labeling metric rows'
    $preparationText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Prepare-Workloads.ps1') -Raw
    Assert-True -Condition $preparationText.Contains('Test-PreparationCompletionRecord', [StringComparison]::Ordinal) -Message 'Preparation resume invokes authoritative checkpoint validation'
    $grantReplayText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-GrantReplay.ps1') -Raw
    Assert-True -Condition $grantReplayText.Contains('Get-GrantReplayBuildArguments', [StringComparison]::Ordinal) -Message 'Grant replay build consumes isolated intermediate arguments'

    . (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
    $OutputRoot = 'trace-library-caller-output-sentinel'
    . (Join-Path $PSScriptRoot 'CoordinatorTrace.ps1')
    Assert-Equal -Actual $OutputRoot -Expected 'trace-library-caller-output-sentinel' -Message 'Dot-sourcing trace functions preserves caller parameters'
    Remove-Variable OutputRoot
    . (Join-Path $PSScriptRoot 'ControllerValidation.ps1')
    . (Join-Path $PSScriptRoot 'Analysis.Common.ps1')
    . (Join-Path $PSScriptRoot 'Scenario.Common.ps1')

    $nativeSingleLine = @(
        Get-NativeOutput `
            -FileName (Get-Command pwsh).Source `
            -Arguments @('-NoProfile', '-Command', '[Console]::WriteLine("single-line")') `
            -WorkingDirectory $PSScriptRoot
    )
    Assert-Equal -Actual $nativeSingleLine.Count -Expected 1 -Message 'Native single-line output remains a one-element line collection'
    Assert-Equal -Actual $nativeSingleLine[0] -Expected 'single-line' -Message 'Native single-line output is not indexed as its first character'
    Assert-True -Condition (-not (ConvertTo-StrictBoolean -Value 'False')) -Message 'CSV warmup identity parses False without PowerShell string truthiness'
    $exactBuildArguments = @(Get-ExactBootstrapBuildArguments)
    Assert-Equal -Actual ($exactBuildArguments -join '|') -Expected '-configuration|Release|-msbuildEngine|dotnet|-verbosity|quiet|/p:CreateTlb=false|/p:RuntimeOutputTargetFrameworks=net11.0' -Message 'Exact builds use the validated repository-supported dotnet command'

    $stageFixtureRoot = Join-Path $testRoot 'stage-candidates'
    $expectedStageCommit = '0123456789abcdef0123456789abcdef01234567'
    $validStage = Join-Path $stageFixtureRoot '0123456789ab-valid'
    $missingMetadataStage = Join-Path $stageFixtureRoot '0123456789ab-missing-metadata'
    $wrongCommitStage = Join-Path $stageFixtureRoot 'ffffffffffff-wrong'
    New-Item -ItemType Directory -Force -Path (Join-Path $validStage 'core'),(Join-Path $missingMetadataStage 'core'),(Join-Path $wrongCommitStage 'core') | Out-Null
    Set-Content -LiteralPath (Join-Path $validStage 'staging-metadata.json') -Value '{}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $wrongCommitStage 'staging-metadata.json') -Value '{}' -Encoding utf8
    $stageCandidates = @(Get-ImmutableBootstrapStageCandidates -StagingRoot $stageFixtureRoot -ExpectedCommit $expectedStageCommit)
    Assert-Equal -Actual $stageCandidates.Count -Expected 1 -Message 'Stage discovery requires matching commit, core directory, and metadata'
    Assert-Equal -Actual $stageCandidates[0].FullName -Expected $validStage -Message 'Stage discovery returns only the complete exact-commit candidate'

    $scannerRoot = Join-Path $testRoot 'grant-scanner\hash-a'
    $scannerProject = Join-Path $PSScriptRoot 'GrantReplay\GrantReplay.csproj'
    $scannerSdk = Join-Path $testRoot 'bootstrap\sdk\fixture'
    $grantBuildArguments = @(
        Get-GrantReplayBuildArguments `
            -ProjectPath $scannerProject `
            -ScannerRoot $scannerRoot `
            -MSBuildAssembliesRoot $scannerSdk
    )
    $scannerFullPath = [IO.Path]::GetFullPath($scannerRoot)
    foreach ($propertyName in @(
        'MSBuildProjectExtensionsPath',
        'BaseIntermediateOutputPath',
        'IntermediateOutputPath'
    )) {
        $propertyArgument = $grantBuildArguments |
            Where-Object { $_.StartsWith("/p:$propertyName=", [StringComparison]::Ordinal) } |
            Select-Object -First 1
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($propertyArgument)) -Message "Grant replay sets $propertyName"
        $propertyPath = $propertyArgument.Substring($propertyArgument.IndexOf('=') + 1)
        Assert-True `
            -Condition ([IO.Path]::GetFullPath($propertyPath).StartsWith(
                "$($scannerFullPath.TrimEnd('\'))\",
                [StringComparison]::OrdinalIgnoreCase)) `
            -Message "Grant replay $propertyName stays below the bootstrap-hash scanner root"
    }
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'GrantReplay\obj'))) `
        -Message 'Grant replay source tree has no generated obj directory'

    $offsetFixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\utc-offset-window.json') -Raw | ConvertFrom-Json
    $offsetStart = ConvertTo-UtcDateTimeOffset -Value $offsetFixture.StartUtc
    $offsetEnd = ConvertTo-UtcDateTimeOffset -Value $offsetFixture.EndUtcMinus04
    $legacyLocalDateTime = [DateTime]$offsetFixture.StartUtc
    $normalizedLegacyDateTime = ConvertTo-UtcDateTimeOffset -Value $legacyLocalDateTime
    Assert-Equal `
        -Actual $normalizedLegacyDateTime.UtcTicks `
        -Expected $offsetStart.UtcTicks `
        -Message 'A Z timestamp materialized as local DateTime is explicitly restored to its UTC instant'
    Assert-Equal `
        -Actual ($offsetEnd - $offsetStart).TotalSeconds `
        -Expected ([double]$offsetFixture.ExpectedElapsedSeconds) `
        -Message 'UTC Z and UTC-04 persisted timestamps describe the same timeline without four-hour skew'
    $offsetTimeline = @(
        [pscustomobject]@{
            TimestampUtc = $offsetFixture.StartUtc
            Sequence = 1
            Event = 'Granted'
            QueueDepth = 1
            ActiveBuilds = 1
            AllocatedNodes = 8
        }
    )
    $offsetWindow = Get-TraceWindowMetrics `
        -Timeline $offsetTimeline `
        -StartUtc $offsetFixture.StartUtc `
        -EndUtc $offsetFixture.EndUtcMinus04 `
        -Budget 16
    Assert-Equal -Actual $offsetWindow.WindowSeconds -Expected 30 -Message 'Trace window arithmetic is offset-stable'

    $terminalRoot = Join-Path $testRoot 'terminal-outcome'
    $abilityOutcome = Write-ScenarioTerminalOutcome `
        -ScenarioRoot $terminalRoot `
        -OutcomeType 'SustainedCompletionTimeout' `
        -Disposition 'CampaignAbilityGateFailure' `
        -Errors @('synthetic 10-minute timeout')
    $cleanupOutcome = Write-ScenarioTerminalOutcome `
        -ScenarioRoot $terminalRoot `
        -OutcomeType 'LiveBuildCleanupFailure' `
        -Disposition 'NonRetryableHarnessFailure' `
        -Errors @('synthetic later cleanup error')
    $persistedOutcome = Get-ScenarioTerminalOutcome -ScenarioRoot $terminalRoot
    Assert-Equal -Actual $cleanupOutcome.Disposition -Expected 'CampaignAbilityGateFailure' -Message 'Later cleanup cannot replace an established ability timeout'
    Assert-Equal -Actual $persistedOutcome.OutcomeType -Expected 'SustainedCompletionTimeout' -Message 'Typed timeout marker remains authoritative'
    Assert-True -Condition (-not $persistedOutcome.RetryAllowed) -Message 'Established timeout marker is non-retriable'
    $terminalOnlyPilotAttempt = Join-Path $testRoot 'terminal-only-pilot\attempt-01'
    [void](Write-ScenarioTerminalOutcome `
        -ScenarioRoot (Join-Path $terminalOnlyPilotAttempt 'scenario') `
        -OutcomeType 'SustainedCompletionTimeout' `
        -Disposition 'CampaignAbilityGateFailure' `
        -Errors @('terminal-only pilot ability failure'))
    $pilotPromotion = Get-InterruptedAttemptTerminalPromotion `
        -AttemptRoot $terminalOnlyPilotAttempt `
        -ResumeScope Pilot
    Assert-Equal -Actual $pilotPromotion.Disposition -Expected 'CampaignAbilityGateFailure' -Message 'Terminal-only interrupted pilot preserves ability-gate disposition'
    Assert-Equal -Actual $pilotPromotion.PromotionMarkerName -Expected 'pilot-nonretriable-failure.json' -Message 'Terminal-only interrupted pilot promotes to the pilot non-retriable marker'
    Assert-True -Condition (-not $pilotPromotion.RetryAllowed) -Message 'Terminal-only interrupted pilot cannot be retried'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $terminalOnlyPilotAttempt 'invalid-attempt.json'))) -Message 'Terminal-only interrupted pilot is never marked retryable'
    $terminalOnlyBlockAttempt = Join-Path $testRoot 'terminal-only-block\attempt-01'
    [void](Write-ScenarioTerminalOutcome `
        -ScenarioRoot (Join-Path $terminalOnlyBlockAttempt '03-FINAL-N') `
        -OutcomeType 'BuildQuiescenceFailure' `
        -Disposition 'NonRetryableHarnessFailure' `
        -Errors @('terminal-only measured-block cleanup failure'))
    $blockPromotion = Get-InterruptedAttemptTerminalPromotion `
        -AttemptRoot $terminalOnlyBlockAttempt `
        -ResumeScope MeasuredBlock
    Assert-Equal -Actual $blockPromotion.Disposition -Expected 'NonRetryableHarnessFailure' -Message 'Terminal-only interrupted measured block preserves non-retriable semantics'
    Assert-Equal -Actual $blockPromotion.PromotionMarkerName -Expected 'block-nonretriable-harness-failure.json' -Message 'Terminal-only interrupted measured block promotes to the block harness marker'
    Assert-True -Condition (-not $blockPromotion.RetryAllowed) -Message 'Terminal-only interrupted measured block cannot be retried'
    $timingGateText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Run-ProjectTimingGate.ps1') -Raw
    $campaignRunText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Run-Campaign.ps1') -Raw
    Assert-True -Condition $timingGateText.Contains('Get-InterruptedAttemptTerminalPromotion', [StringComparison]::Ordinal) -Message 'Timing-gate resume promotes terminal-only interrupted pilots before retry marking'
    Assert-True -Condition $campaignRunText.Contains('Get-InterruptedAttemptTerminalPromotion', [StringComparison]::Ordinal) -Message 'Campaign resume promotes terminal-only interrupted blocks before retry marking'

    $treeIdentityPath = Join-Path $testRoot 'synthetic-tree-child.txt'
    $pwshPath = (Get-Command pwsh).Source
    $childEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 120'))
    $parentScript = @"
`$child = Start-Process -FilePath '$($pwshPath.Replace("'", "''"))' -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', '$childEncoded') -PassThru
[IO.File]::WriteAllText('$($treeIdentityPath.Replace("'", "''"))', "`$(`$child.Id)|`$(`$child.StartTime.ToUniversalTime().ToString('O'))")
Start-Sleep -Seconds 120
"@
    $treeProcess = $null
    $treeRootStart = $null
    $treeChildIdentity = $null
    try {
        $treeProcess = Start-TestPowerShellProcess -Script $parentScript
        $treeRootStart = ConvertTo-UtcDateTimeOffset -Value $treeProcess.StartTime
        $waitForChild = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $treeIdentityPath -PathType Leaf)) {
            if ($treeProcess.HasExited -or $waitForChild.Elapsed.TotalSeconds -gt 10) {
                throw 'Synthetic process tree did not publish its child identity.'
            }
            Start-Sleep -Milliseconds 50
        }
        $treeChildIdentity = (Get-Content -LiteralPath $treeIdentityPath -Raw).Trim()
        $wrongIdentityStop = Stop-VerifiedProcessTree `
            -RootProcessId $treeProcess.Id `
            -RootProcessStartUtc $treeRootStart.AddMinutes(-1) `
            -TimeoutSeconds 1
        Assert-True -Condition $wrongIdentityStop.Succeeded -Message 'PID reuse guard treats a mismatched identity as an already-gone target'
        Assert-True `
            -Condition (Test-VerifiedProcessIdentity -ProcessId $treeProcess.Id -ProcessStartUtc $treeRootStart) `
            -Message 'PID reuse guard never kills a process with a different start identity'

        $treeStop = Stop-VerifiedProcessTree `
            -RootProcessId $treeProcess.Id `
            -RootProcessStartUtc $treeRootStart `
            -DescendantIdentities @($treeChildIdentity) `
            -TimeoutSeconds 5
        Assert-True -Condition $treeStop.Succeeded -Message 'Targeted verified process-tree termination reaches quiescence'
        Assert-True `
            -Condition (-not (Test-VerifiedProcessIdentity -ProcessId $treeProcess.Id -ProcessStartUtc $treeRootStart)) `
            -Message 'Synthetic root process is gone after targeted tree termination'
        $childParts = $treeChildIdentity -split '\|', 2
        Assert-True `
            -Condition (-not (Test-VerifiedProcessIdentity -ProcessId ([int]$childParts[0]) -ProcessStartUtc $childParts[1])) `
            -Message 'Synthetic child process is gone after targeted tree termination'
    }
    finally {
        if ($null -ne $treeProcess) {
            if ($null -ne $treeRootStart -and
                (Test-VerifiedProcessIdentity -ProcessId $treeProcess.Id -ProcessStartUtc $treeRootStart)) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId $treeProcess.Id `
                    -RootProcessStartUtc $treeRootStart `
                    -DescendantIdentities @($treeChildIdentity) `
                    -TimeoutSeconds 5)
            }
            $treeProcess.Dispose()
        }
        if (-not [string]::IsNullOrWhiteSpace($treeChildIdentity)) {
            $childParts = $treeChildIdentity -split '\|', 2
            if ($childParts.Count -eq 2 -and
                (Test-VerifiedProcessIdentity -ProcessId ([int]$childParts[0]) -ProcessStartUtc $childParts[1])) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId ([int]$childParts[0]) `
                    -RootProcessStartUtc $childParts[1] `
                    -TimeoutSeconds 5)
            }
        }
    }

    foreach ($cleanupCase in @(
        [pscustomobject]@{ Name = 'clean-finally'; InjectCleanupError = $false },
        [pscustomobject]@{ Name = 'aggregate-error'; InjectCleanupError = $true }
    )) {
        $cleanupProcess = $null
        $cleanupPid = $null
        $cleanupStart = $null
        try {
            $cleanupProcess = Start-TestPowerShellProcess `
                -Script 'Start-Sleep -Seconds 120' `
                -RedirectOutput
            $cleanupPid = $cleanupProcess.Id
            $cleanupStart = ConvertTo-UtcDateTimeOffset -Value $cleanupProcess.StartTime
            $descendants = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ($cleanupCase.InjectCleanupError) {
                [void]$descendants.Add('999999|')
            }
            $syntheticRunRoot = Join-Path $testRoot $cleanupCase.Name
            New-Item -ItemType Directory -Force -Path $syntheticRunRoot | Out-Null
            $syntheticRun = [pscustomobject][ordered]@{
                RunId = $cleanupCase.Name
                Process = $cleanupProcess
                RootProcessId = $cleanupPid
                ProcessStartUtc = $cleanupStart
                ProcessExitUtc = $null
                ExitCode = $null
                Quiescent = $null
                Completed = $false
                StdoutTask = $cleanupProcess.StandardOutput.ReadToEndAsync()
                StderrTask = $cleanupProcess.StandardError.ReadToEndAsync()
                Stdout = Join-Path $syntheticRunRoot 'stdout.log'
                Stderr = Join-Path $syntheticRunRoot 'stderr.log'
                DescendantIdentities = $descendants
            }
            $cleanupResult = Stop-UnfinishedScenarioBuilds `
                -Runs @($syntheticRun) `
                -TimeoutSeconds 3
            Assert-True -Condition $syntheticRun.Completed -Message "$($cleanupCase.Name) disposes and completes its captured run"
            Assert-True `
                -Condition (-not (Test-VerifiedProcessIdentity -ProcessId $syntheticRun.RootProcessId -ProcessStartUtc $cleanupStart)) `
                -Message "$($cleanupCase.Name) leaves no captured build process alive"
            Assert-Equal -Actual @($cleanupResult.LiveRunIds).Count -Expected 0 -Message "$($cleanupCase.Name) reaches build quiescence"
            if ($cleanupCase.InjectCleanupError) {
                Assert-True -Condition (-not $cleanupResult.Succeeded) -Message 'Cleanup failures are aggregated instead of swallowed'
                Assert-True -Condition (@($cleanupResult.Errors).Count -gt 0) -Message 'Aggregated cleanup result retains the shutdown error'
            }
            else {
                Assert-True -Condition $cleanupResult.Succeeded -Message 'Synthetic finally cleanup succeeds'
                Assert-True -Condition $syntheticRun.Quiescent -Message 'Synthetic finally cleanup drains redirected streams'
            }
        }
        finally {
            if ($null -ne $cleanupProcess -and
                $null -ne $cleanupPid -and
                $null -ne $cleanupStart -and
                (Test-VerifiedProcessIdentity -ProcessId $cleanupPid -ProcessStartUtc $cleanupStart)) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId $cleanupPid `
                    -RootProcessStartUtc $cleanupStart `
                    -TimeoutSeconds 5)
                $cleanupProcess.Dispose()
            }
        }
    }

    $orphanIdentityPath = Join-Path $testRoot 'completed-root-child.txt'
    $orphanChildEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 120'))
    $orphanParentScript = @"
`$child = Start-Process -FilePath '$($pwshPath.Replace("'", "''"))' -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', '$orphanChildEncoded') -PassThru
[IO.File]::WriteAllText('$($orphanIdentityPath.Replace("'", "''"))', "`$(`$child.Id)|`$(`$child.StartTime.ToUniversalTime().ToString('O'))")
"@
    $orphanParent = $null
    $orphanParentStart = $null
    $orphanChildIdentity = $null
    try {
        $orphanParent = Start-TestPowerShellProcess -Script $orphanParentScript
        $orphanParentStart = ConvertTo-UtcDateTimeOffset -Value $orphanParent.StartTime
        $orphanWait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $orphanIdentityPath -PathType Leaf)) {
            if ($orphanWait.Elapsed.TotalSeconds -gt 10) {
                throw 'Completed-root fixture did not publish its child identity.'
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not $orphanParent.WaitForExit(5000)) {
            throw 'Completed-root fixture parent did not exit.'
        }
        $orphanChildIdentity = (Get-Content -LiteralPath $orphanIdentityPath -Raw).Trim()
        $orphanChildParts = $orphanChildIdentity -split '\|', 2
        Assert-True `
            -Condition (Test-VerifiedProcessIdentity -ProcessId ([int]$orphanChildParts[0]) -ProcessStartUtc $orphanChildParts[1]) `
            -Message 'Completed-root fixture leaves a captured child alive'
        $orphanDescendants = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$orphanDescendants.Add($orphanChildIdentity)
        $completedRootRun = [pscustomobject][ordered]@{
            RunId = 'completed-root-live-child'
            Process = $orphanParent
            RootProcessId = $orphanParent.Id
            ProcessStartUtc = $orphanParentStart
            ProcessExitUtc = ConvertTo-UtcDateTimeOffset -Value $orphanParent.ExitTime
            ExitCode = $orphanParent.ExitCode
            Quiescent = $false
            Completed = $true
            DescendantIdentities = $orphanDescendants
        }
        $completedRootCleanup = Stop-UnfinishedScenarioBuilds `
            -Runs @($completedRootRun) `
            -TimeoutSeconds 5
        Assert-True `
            -Condition (-not (Test-VerifiedProcessIdentity -ProcessId ([int]$orphanChildParts[0]) -ProcessStartUtc $orphanChildParts[1])) `
            -Message 'Cleanup targets a captured child after its completed root exited'
        Assert-True -Condition (-not $completedRootCleanup.Succeeded) -Message 'Forced descendant cleanup retains quiescence uncertainty'
        Assert-True `
            -Condition (@($completedRootCleanup.QuiescenceUncertainRunIds) -contains $completedRootRun.RunId) `
            -Message 'Completed root with a surviving child is identified as quiescence-uncertain'
        $orphanAttemptRoot = Join-Path $testRoot 'completed-root-resume\attempt-01'
        $orphanScenarioRoot = Join-Path $orphanAttemptRoot '01-FINAL-N'
        $cleanupTerminal = Write-ScenarioCleanupTerminalOutcome `
            -ScenarioRoot $orphanScenarioRoot `
            -Cleanup $completedRootCleanup
        Assert-Equal -Actual $cleanupTerminal.Disposition -Expected 'NonRetryableHarnessFailure' -Message 'Completed-root quiescence uncertainty persists a non-retriable terminal outcome'
        $cleanupPromotion = Get-InterruptedAttemptTerminalPromotion `
            -AttemptRoot $orphanAttemptRoot `
            -ResumeScope MeasuredBlock
        Assert-Equal -Actual $cleanupPromotion.PromotionMarkerName -Expected 'block-nonretriable-harness-failure.json' -Message 'Persisted cleanup terminal outcome blocks measured-block retry'
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($orphanChildIdentity)) {
            $orphanChildParts = $orphanChildIdentity -split '\|', 2
            if ($orphanChildParts.Count -eq 2 -and
                (Test-VerifiedProcessIdentity -ProcessId ([int]$orphanChildParts[0]) -ProcessStartUtc $orphanChildParts[1])) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId ([int]$orphanChildParts[0]) `
                    -RootProcessStartUtc $orphanChildParts[1] `
                    -TimeoutSeconds 5)
            }
        }
        if ($null -ne $orphanParent) {
            if ($null -ne $orphanParentStart -and
                (Test-VerifiedProcessIdentity -ProcessId $orphanParent.Id -ProcessStartUtc $orphanParentStart)) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId $orphanParent.Id `
                    -RootProcessStartUtc $orphanParentStart `
                    -TimeoutSeconds 5)
            }
            $orphanParent.Dispose()
        }
    }

    $campaign = Get-CampaignDefinition
    Assert-Equal -Actual $campaign.Base.Commit -Expected 'ff5b281f0c5828dec0d092fcd1b682019de7d1ca' -Message 'BASE identity is exact'
    Assert-Equal -Actual $campaign.Final.Commit -Expected '9aa319701cc70713e5f017a1a8e0cc88b1813ae1' -Message 'FINAL identity is exact'
    Assert-Equal -Actual $campaign.NodeBudget -Expected 16 -Message 'Coordinator budget is exact'
    Assert-Equal -Actual $campaign.Validity.InitialDiskSafetyGiB -Expected 20 -Message 'Initial measured-disk safety guard is exact'
    Assert-Equal -Actual $campaign.Validity.RawResultsReserveGiB -Expected 25 -Message 'Raw-result disk reserve is exact'
    Assert-Equal -Actual $campaign.Validity.SustainedWorkers -Expected 18 -Message 'Sustained worker count is exact'
    Assert-Equal -Actual $campaign.Validity.SustainedEndingCompletion -Expected 12 -Message 'Sustained ending completion is exact'
    Assert-Equal -Actual $campaign.Validity.SustainedInjectionCompletion -Expected 6 -Message 'Sustained injection completion is exact'
    Assert-Equal -Actual $campaign.Validity.SustainedTimeoutMinutes -Expected 10 -Message 'Sustained ability timeout is exact'
    Assert-Equal -Actual $campaign.Validity.SustainedHandoffGapToleranceSeconds -Expected 1 -Message 'Semantic saturation handoff tolerance is exactly one trace second'
    Assert-Equal -Actual $campaign.MaximumProjectedCampaignHours -Expected 4 -Message 'Projected runtime gate is exactly four hours'
    Assert-Equal -Actual $campaign.RuntimeProjectionSafetyFactor -Expected 1.25 -Message 'Actual sustained pilot walls receive a conservative 1.25 projection factor'
    Assert-Equal -Actual @($campaign.Shapes).Count -Expected 2 -Message 'Contemporaneous campaign has exactly two shapes'
    Assert-Equal -Actual (@($campaign.Shapes.Key) -join '|') -Expected 'isolated|sustained' -Message 'Only isolated and sustained shapes are callable'
    Assert-Equal -Actual (Get-RepositoryDefinition -Name roslyn).BuildPath -Expected 'src\Compilers\CSharp\Portable\Microsoft.CodeAnalysis.CSharp.csproj' -Message 'Roslyn project workload is exact'
    Assert-Equal -Actual (Get-RepositoryDefinition -Name roslyn).TouchPath -Expected 'src\Compilers\CSharp\Portable\CSharpCompilationOptions.cs' -Message 'Roslyn propagated input is exact'
    Assert-Equal -Actual (Get-RepositoryDefinition -Name aspire).BuildPath -Expected 'src\Aspire.Hosting\Aspire.Hosting.csproj' -Message 'Aspire project workload is exact'
    Assert-True -Condition $campaign.WorkloadDeviation.Contains('historical full-solution', [StringComparison]::OrdinalIgnoreCase) -Message 'Reports predeclare historical full-solution evidence as supporting only'
    $passingDiskProjection = Get-MeasuredWorktreeDiskProjection `
        -Repository fixture `
        -FirstRestoredWarmWorktreeBytes 1GB `
        -ExistingCampaignWorktreeCount 1 `
        -AvailableBytesBeforeExpansion 50GB `
        -RawResultsReserveGiB 25
    Assert-True -Condition $passingDiskProjection.Passed -Message 'Measured project-worktree disk projection passes sufficient capacity'
    Assert-Equal -Actual $passingDiskProjection.MissingCampaignWorktreeCount -Expected 18 -Message 'Disk projection expands only after measuring the first of 19 worktrees'
    $failingDiskProjection = Get-MeasuredWorktreeDiskProjection `
        -Repository fixture `
        -FirstRestoredWarmWorktreeBytes 1GB `
        -ExistingCampaignWorktreeCount 1 `
        -AvailableBytesBeforeExpansion 40GB `
        -RawResultsReserveGiB 25
    Assert-True -Condition (-not $failingDiskProjection.Passed) -Message 'Measured disk projection fails before unsafe expansion'
    Assert-Equal -Actual @(Get-ShapeWorktreeNames -Shape isolated).Count -Expected 1 -Message 'Isolated reset affects one dedicated worktree'
    Assert-Equal -Actual @(Get-ShapeWorktreeNames -Shape sustained).Count -Expected 19 -Message 'Sustained reset affects all 18 Normal plus injected worktrees'
    $resetFixtureRoot = Join-Path $testRoot 'reset-worktree'
    foreach ($directory in @(
        'src\Project\bin',
        'src\Project\obj',
        'artifacts\bin',
        'src\Tracked\bin'
    )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $resetFixtureRoot $directory) | Out-Null
        Set-Content -LiteralPath (Join-Path $resetFixtureRoot "$directory\fixture.txt") -Value fixture
    }
    $unsafeResetPlan = Get-ProjectOutputResetPlan `
        -Worktree $resetFixtureRoot `
        -TrackedRelativePaths @('src\Tracked\bin\fixture.txt')
    Assert-True -Condition (-not $unsafeResetPlan.Valid) -Message 'Output reset refuses any candidate containing a tracked file'
    Assert-Equal -Actual $unsafeResetPlan.UnsafeCandidates.Count -Expected 1 -Message 'Unsafe tracked output candidate is isolated'
    $safeResetPlan = Get-ProjectOutputResetPlan -Worktree $resetFixtureRoot
    Assert-True -Condition $safeResetPlan.Valid -Message 'Explicit bin/obj/artifacts reset plan is valid when no tracked files are removed'
    Assert-True -Condition (@($safeResetPlan.SafeCandidates.RelativePath) -contains 'artifacts') -Message 'Reset plan removes the repository artifacts output root explicitly'
    $baselineOutputIdentity = Get-ProjectOutputContentIdentity -Worktree $resetFixtureRoot
    Set-Content `
        -LiteralPath (Join-Path $resetFixtureRoot 'src\Project\bin\fixture.txt') `
        -Value changed
    $changedOutputIdentity = Get-ProjectOutputContentIdentity -Worktree $resetFixtureRoot
    Assert-True -Condition ($baselineOutputIdentity.ContentSha256 -ne $changedOutputIdentity.ContentSha256) -Message 'Prepared baseline output identity detects partial bin/obj state changes'
    $checkpointRecord = [pscustomobject]@{
        Repository = 'roslyn'
        Shape = 'sustained'
        Completed = $true
        NoOverlap = $true
        BaselineRestored = $true
        PreparationSha256 = ('A' * 64)
        AffectedWorktrees = @(
            Get-ShapeWorktreeNames -Shape sustained |
                ForEach-Object {
                    [pscustomobject]@{
                        Name = $_
                        RestoreCompleted = $true
                        WarmCompleted = $true
                        BaselineOutputIdentityMatched = $true
                        Retouched = $false
                    }
                }
        )
    }
    $checkpointValidation = Test-WorktreeResetCheckpointRecord `
        -Record $checkpointRecord `
        -Repository roslyn `
        -Shape sustained
    Assert-True -Condition $checkpointValidation.Valid -Message 'Prepared baseline reset checkpoint proves exact worktree state and no overlap'
    $checkpointRecord.BaselineRestored = $false
    $invalidCheckpoint = Test-WorktreeResetCheckpointRecord `
        -Record $checkpointRecord `
        -Repository roslyn `
        -Shape sustained
    Assert-True -Condition (-not $invalidCheckpoint.Valid) -Message 'Incomplete prepared baseline checkpoint is rejected'

    $preparationSource = Join-Path $testRoot 'preparation-source'
    $preparationWorkRoot = Join-Path $testRoot 'preparation-worktrees'
    New-Item -ItemType Directory -Force -Path $preparationSource,$preparationWorkRoot | Out-Null
    [void](Get-NativeOutput -FileName git -Arguments @('init', '--quiet') -WorkingDirectory $preparationSource)
    [void](Get-NativeOutput -FileName git -Arguments @('config', 'user.name', 'Tooling Test') -WorkingDirectory $preparationSource)
    [void](Get-NativeOutput -FileName git -Arguments @('config', 'user.email', 'tooling-test@example.invalid') -WorkingDirectory $preparationSource)
    Set-Content `
        -LiteralPath (Join-Path $preparationSource '.gitignore') `
        -Value @('obj/', 'ignored-outside/') `
        -Encoding utf8
    Set-Content -LiteralPath (Join-Path $preparationSource 'tracked.txt') -Value 'fixture' -Encoding utf8
    [void](Get-NativeOutput -FileName git -Arguments @('add', '.gitignore', 'tracked.txt') -WorkingDirectory $preparationSource)
    [void](Get-NativeOutput -FileName git -Arguments @('commit', '--quiet', '-m', 'fixture') -WorkingDirectory $preparationSource)
    $preparationCommit = @(
        Get-NativeOutput -FileName git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $preparationSource
    )[0].Trim()
    $preparationRemote = 'https://example.invalid/preparation-fixture.git'
    [void](Get-NativeOutput `
        -FileName git `
        -Arguments @('remote', 'add', 'origin', $preparationRemote) `
        -WorkingDirectory $preparationSource)
    $preparedWorktrees = [Collections.Generic.List[object]]::new()
    foreach ($worktreeName in @((1..18 | ForEach-Object { "normal$_" }) + @('injected'))) {
        $worktreePath = Join-Path $preparationWorkRoot $worktreeName
        [void](Get-NativeOutput `
            -FileName git `
            -Arguments @('worktree', 'add', '--quiet', '--detach', $worktreePath, $preparationCommit) `
            -WorkingDirectory $preparationSource)
        New-Item -ItemType Directory -Force -Path (Join-Path $worktreePath 'obj') | Out-Null
        Set-Content -LiteralPath (Join-Path $worktreePath 'obj\baseline.bin') -Value $worktreeName -Encoding utf8
        $worktreeGit = Get-GitIdentity `
            -Root $worktreePath `
            -ExpectedCommit $preparationCommit `
            -RequireClean
        $trackedFiles = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('ls-files') `
                -WorkingDirectory $worktreePath
        )
        $preparedWorktrees.Add([pscustomobject][ordered]@{
            Name = $worktreeName
            Path = $worktreePath
            Git = $worktreeGit
            BaselineOutputIdentity = Get-ProjectOutputContentIdentity `
                -Worktree $worktreePath `
                -TrackedRelativePaths $trackedFiles
        })
    }
    $preparationRepositoryIdentity = Get-GitIdentity `
        -Root $preparationSource `
        -ExpectedCommit $preparationCommit `
        -RequireClean
    $preparationRepositoryIdentity | Add-Member `
        -NotePropertyName Remote `
        -NotePropertyValue (Get-GitRemoteIdentity `
            -Root $preparationSource `
            -RemoteName origin `
            -ExpectedUrl $preparationRemote)
    $preparationDefinition = [pscustomobject][ordered]@{
        Name = 'fixture'
        Root = $preparationSource
        Commit = $preparationCommit
        Repository = $preparationRemote
        WorkRoot = $preparationWorkRoot
        BuildPath = 'tracked.txt'
        TouchPath = 'tracked.txt'
        AdditionalBuildArguments = @()
    }
    $preparationIdentityPath = Join-Path $testRoot 'bootstrap-identities.json'
    Set-Content -LiteralPath $preparationIdentityPath -Value '{}' -Encoding utf8
    $fixtureBaseBootstrap = [pscustomobject]@{
        Root = Join-Path $testRoot 'base-bootstrap'
        ExpectedCommit = 'base-commit'
        MSBuildDllSha256 = 'A' * 64
    }
    $fixtureFinalBootstrap = [pscustomobject]@{
        Root = Join-Path $testRoot 'final-bootstrap'
        ExpectedCommit = 'final-commit'
        MSBuildDllSha256 = 'B' * 64
    }
    $preparationRecord = [pscustomobject][ordered]@{
        SchemaVersion = 2
        CompletedUtc = '2026-08-12T12:00:00.0000000Z'
        Authoritative = $true
        BootstrapIdentityPath = $preparationIdentityPath
        BootstrapIdentitySha256 = (Get-FileHash -LiteralPath $preparationIdentityPath -Algorithm SHA256).Hash
        BootstrapIdentities = [pscustomobject][ordered]@{
            Base = [pscustomobject]@{
                Root = $fixtureBaseBootstrap.Root
                Commit = $fixtureBaseBootstrap.ExpectedCommit
                MSBuildDllSha256 = $fixtureBaseBootstrap.MSBuildDllSha256
            }
            Final = [pscustomobject]@{
                Root = $fixtureFinalBootstrap.Root
                Commit = $fixtureFinalBootstrap.ExpectedCommit
                MSBuildDllSha256 = $fixtureFinalBootstrap.MSBuildDllSha256
            }
        }
        PreparationBootstrapRole = 'final'
        Repositories = @(
            [pscustomobject][ordered]@{
                Name = 'fixture'
                Repository = $preparationRepositoryIdentity
                BuildPath = $preparationDefinition.BuildPath
                TouchPath = $preparationDefinition.TouchPath
                AdditionalBuildArguments = @()
                WorkRoot = $preparationWorkRoot
                Worktrees = $preparedWorktrees.ToArray()
                Restored = $true
                Warmed = $true
            }
        )
    }
    $preparationValidation = Test-PreparationCompletionRecord `
        -Record $preparationRecord `
        -BaseBootstrap $fixtureBaseBootstrap `
        -FinalBootstrap $fixtureFinalBootstrap `
        -RepositoryDefinitions @($preparationDefinition) `
        -BootstrapIdentityPath $preparationIdentityPath `
        -ValidateFileSystem
    Assert-True -Condition $preparationValidation.Valid -Message 'Authoritative preparation resume validates exact identities, 19 clean worktrees, and baselines'
    Assert-Equal -Actual $preparationValidation.WorktreeCount -Expected 19 -Message 'Preparation resume requires 19 worktrees per repository'
    Set-Content -LiteralPath $preparationIdentityPath -Value '{"changed":true}' -Encoding utf8
    $changedBootstrapPreparation = Test-PreparationCompletionRecord `
        -Record $preparationRecord `
        -BaseBootstrap $fixtureBaseBootstrap `
        -FinalBootstrap $fixtureFinalBootstrap `
        -RepositoryDefinitions @($preparationDefinition) `
        -BootstrapIdentityPath $preparationIdentityPath
    Assert-True -Condition (-not $changedBootstrapPreparation.Valid) -Message 'Preparation resume rejects a changed bootstrap identity file'
    Set-Content -LiteralPath $preparationIdentityPath -Value '{}' -Encoding utf8
    Set-Content `
        -LiteralPath (Join-Path $preparationWorkRoot 'normal1\obj\baseline.bin') `
        -Value 'changed' `
        -Encoding utf8
    $changedPreparation = Test-PreparationCompletionRecord `
        -Record $preparationRecord `
        -BaseBootstrap $fixtureBaseBootstrap `
        -FinalBootstrap $fixtureFinalBootstrap `
        -RepositoryDefinitions @($preparationDefinition) `
        -BootstrapIdentityPath $preparationIdentityPath `
        -ValidateFileSystem
    Assert-True -Condition (-not $changedPreparation.Valid) -Message 'Preparation resume rejects a changed recorded baseline output hash'
    Set-Content `
        -LiteralPath (Join-Path $preparationWorkRoot 'normal1\obj\baseline.bin') `
        -Value 'normal1' `
        -Encoding utf8
    Set-Content `
        -LiteralPath (Join-Path $preparationWorkRoot 'normal1\unexpected-source.txt') `
        -Value 'untracked' `
        -Encoding utf8
    $uncleanPreparation = Test-PreparationCompletionRecord `
        -Record $preparationRecord `
        -BaseBootstrap $fixtureBaseBootstrap `
        -FinalBootstrap $fixtureFinalBootstrap `
        -RepositoryDefinitions @($preparationDefinition) `
        -BootstrapIdentityPath $preparationIdentityPath `
        -ValidateFileSystem
    Assert-True -Condition (-not $uncleanPreparation.Valid) -Message 'Preparation resume rejects an unclean pinned worktree'
    Remove-Item -LiteralPath (Join-Path $preparationWorkRoot 'normal1\unexpected-source.txt') -Force
    New-Item `
        -ItemType Directory `
        -Force `
        -Path (Join-Path $preparationWorkRoot 'normal1\ignored-outside') |
        Out-Null
    Set-Content `
        -LiteralPath (Join-Path $preparationWorkRoot 'normal1\ignored-outside\mutation.bin') `
        -Value 'ignored mutation' `
        -Encoding utf8
    $ignoredMutationPreparation = Test-PreparationCompletionRecord `
        -Record $preparationRecord `
        -BaseBootstrap $fixtureBaseBootstrap `
        -FinalBootstrap $fixtureFinalBootstrap `
        -RepositoryDefinitions @($preparationDefinition) `
        -BootstrapIdentityPath $preparationIdentityPath `
        -ValidateFileSystem
    Assert-True -Condition (-not $ignoredMutationPreparation.Valid) -Message 'Preparation resume rejects ignored mutation outside hashed/reset output roots'
    Assert-True `
        -Condition (@($ignoredMutationPreparation.Errors | Where-Object { $_ -match 'ignored or untracked state outside explicitly hashed/reset output roots' }).Count -gt 0) `
        -Message 'Ignored mutation failure identifies the uncaptured state boundary'
    Remove-Item -LiteralPath (Join-Path $preparationWorkRoot 'normal1\ignored-outside') -Recurse -Force
    $preparationRecord.Authoritative = $false
    $preparationRecord.Repositories[0].Warmed = $false
    $skipWarmPreparation = Test-PreparationCompletionRecord `
        -Record $preparationRecord `
        -BaseBootstrap $fixtureBaseBootstrap `
        -FinalBootstrap $fixtureFinalBootstrap `
        -RepositoryDefinitions @($preparationDefinition) `
        -BootstrapIdentityPath $preparationIdentityPath
    Assert-True -Condition (-not $skipWarmPreparation.Valid) -Message 'SkipWarm preparation checkpoint cannot satisfy authoritative resume'

    foreach ($condition in @('BASE', 'COMPAT', 'FINAL-N', 'FINAL-H')) {
        foreach ($injected in @($false, $true)) {
            $environment = New-ConditionEnvironment `
                -Condition $condition `
                -PipeName fixture `
                -DotNetRoot 'C:\bootstrap' `
                -Injected:$injected `
                -EnableDebugTrace `
                -DebugPath 'C:\trace'
            Assert-ConditionEnvironmentContract -Condition $condition -Environment $environment -Injected:$injected
        }
    }
    $baseEnvironment = New-ConditionEnvironment -Condition BASE -PipeName fixture -DotNetRoot 'C:\bootstrap'
    Assert-Equal -Actual $baseEnvironment['MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES'] -Expected $null -Message 'BASE reservation is genuinely absent'
    Assert-Equal -Actual $baseEnvironment['MSBUILDCOORDINATORMAXNODESPERBUILD'] -Expected $null -Message 'BASE cap is genuinely absent'
    Assert-Equal -Actual $baseEnvironment['MSBUILDCOORDINATORBUILDREQUESTPRIORITY'] -Expected $null -Message 'BASE priority is genuinely absent'
    $compatEnvironment = New-ConditionEnvironment -Condition COMPAT -PipeName fixture -DotNetRoot 'C:\bootstrap'
    Assert-Equal -Actual $compatEnvironment['MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES'] -Expected '0' -Message 'COMPAT reservation is explicit zero'
    Assert-Equal -Actual $compatEnvironment['MSBUILDCOORDINATORMAXNODESPERBUILD'] -Expected '0' -Message 'COMPAT cap is explicit zero'

    $isolatedOrders = @(Get-CampaignShapeOrders -Shape isolated)
    $expectedIsolated = @(
        'BASE COMPAT FINAL-N',
        'COMPAT FINAL-N BASE',
        'FINAL-N BASE COMPAT',
        'FINAL-N COMPAT BASE',
        'BASE FINAL-N COMPAT',
        'COMPAT BASE FINAL-N'
    )
    Assert-Equal -Actual $isolatedOrders.Count -Expected 6 -Message 'Isolated has one complete six-row Williams cycle'
    Assert-Equal -Actual (@($isolatedOrders | ForEach-Object { $_.Items -join ' ' }) -join '|') -Expected ($expectedIsolated -join '|') -Message 'Isolated Williams cycle is exact'
    $sustainedOrders = @(Get-CampaignShapeOrders -Shape sustained)
    $expectedSustained = @(
        'BASE COMPAT FINAL-H FINAL-N',
        'COMPAT FINAL-N BASE FINAL-H',
        'FINAL-N FINAL-H COMPAT BASE',
        'FINAL-H BASE FINAL-N COMPAT'
    )
    Assert-Equal -Actual $sustainedOrders.Count -Expected 4 -Message 'Sustained uses one complete four-row Williams cycle'
    Assert-Equal -Actual (@($sustainedOrders | ForEach-Object { $_.Items -join ' ' }) -join '|') -Expected ($expectedSustained -join '|') -Message 'Sustained Williams cycle is exact'
    foreach ($shape in $campaign.Shapes) {
        $orders = @(Get-CampaignShapeOrders -Shape $shape.Key)
        $diagnostics = Get-OrderDiagnostics -Orders $orders -Items $shape.Conditions
        Assert-Equal -Actual $diagnostics.PositionImbalance -Expected 0 -Message "$($shape.Key) position imbalance is zero"
        Assert-Equal -Actual $diagnostics.CarryoverImbalance -Expected 0 -Message "$($shape.Key) carryover imbalance is zero"
    }
    $plan = New-CampaignPlan
    Assert-Equal -Actual $plan.Rows.Count -Expected 82 -Message 'Exact two-shape matrix row count'
    foreach ($repositoryName in @('roslyn', 'aspire')) {
        Assert-Equal `
            -Actual (@($plan.Rows | Where-Object {
                $_.Repository -eq $repositoryName -and $_.Shape -eq 'isolated'
            }).Count) `
            -Expected 21 `
            -Message "$repositoryName isolated plan has 3 warm-up plus 18 measured rows"
        Assert-Equal `
            -Actual (@($plan.Rows | Where-Object {
                $_.Repository -eq $repositoryName -and $_.Shape -eq 'sustained'
            }).Count) `
            -Expected 20 `
            -Message "$repositoryName sustained plan has 4 warm-up plus 16 measured rows"
    }

    $planRoot = Join-Path $testRoot 'plan'
    $planOutput = @(
        & (Join-Path $PSScriptRoot 'Run-Campaign.ps1') -PlanOnly -PlanOutputRoot $planRoot 6>&1
    )
    $planValidation = Get-Content -LiteralPath (Join-Path $planRoot 'plan-validation.json') -Raw | ConvertFrom-Json
    Assert-True -Condition $planValidation.Valid -Message 'PlanOnly validation passes'
    Assert-Equal -Actual $planValidation.ActualRows -Expected 82 -Message 'PlanOnly two-shape row count is exact'
    Assert-True -Condition (($planOutput | Out-String) -match 'POSITION_IMBALANCE=0') -Message 'PlanOnly emits exact zero position imbalance'
    Assert-True -Condition (($planOutput | Out-String) -match 'CARRYOVER_IMBALANCE=0') -Message 'PlanOnly emits exact zero carryover imbalance'

    $fixtures = Join-Path $PSScriptRoot 'fixtures'
    foreach ($name in @('final', 'base')) {
        $runs = @(Get-Content -LiteralPath (Join-Path $fixtures "$name-valid-runs.json") -Raw | ConvertFrom-Json)
        $trace = ConvertFrom-CoordinatorTrace `
            -TracePaths @((Join-Path $fixtures "$name-valid.trace")) `
            -RunRecords $runs `
            -Budget 16 `
            -RequireEmptyFinalState `
            -StrictParsing
        Assert-True -Condition $trace.Consistent -Message "$name fixture trace is consistent"
        Assert-True -Condition $trace.DeferredGrantOccurred -Message "$name fixture proves a deferred grant"
        Assert-Equal -Actual $trace.FinalQueueDepth -Expected 0 -Message "$name fixture queue drains"
        Assert-Equal -Actual $trace.FinalActiveBuilds -Expected 0 -Message "$name fixture active set drains"
        Assert-Equal -Actual $trace.FinalAllocatedNodes -Expected 0 -Message "$name fixture allocation drains"
        if ($name -eq 'final') {
            $traceExportRoot = Join-Path $testRoot 'parsed-trace'
            [void](Export-CoordinatorTraceResult -Trace $trace -DestinationRoot $traceExportRoot)
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $traceExportRoot 'events.csv') -PathType Leaf) -Message 'Parsed trace events are exported'
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $traceExportRoot 'timeline.csv') -PathType Leaf) -Message 'Exact queue/active/allocation timeline is exported'
            $traceSummary = Get-Content -LiteralPath (Join-Path $traceExportRoot 'summary.json') -Raw | ConvertFrom-Json
            Assert-True -Condition $traceSummary.Consistent -Message 'Exported trace summary preserves consistency'
        }
    }
    $invalidTrace = ConvertFrom-CoordinatorTrace `
        -TracePaths @((Join-Path $fixtures 'invalid.trace')) `
        -Budget 16 `
        -StrictParsing
    Assert-True -Condition (-not $invalidTrace.Consistent) -Message 'Impossible trace is rejected'
    $missingRootRuns = @(
        Get-Content -LiteralPath (Join-Path $fixtures 'final-missing-root-runs.json') -Raw |
            ConvertFrom-Json
    )
    $missingRootTrace = ConvertFrom-CoordinatorTrace `
        -TracePaths @((Join-Path $fixtures 'final-valid.trace')) `
        -RunRecords $missingRootRuns `
        -Budget 16 `
        -RequireEmptyFinalState `
        -StrictParsing
    Assert-True -Condition (-not $missingRootTrace.Consistent) -Message 'Removing a captured root PID makes unresolved non-nested state events inconsistent'
    Assert-True `
        -Condition (($missingRootTrace.Errors -join '; ') -match 'PID 102') `
        -Message 'Unresolved root fixture identifies the removed PID'
    $churnRuns = @(
        Get-Content -LiteralPath (Join-Path $fixtures 'sustained-churn-runs.json') -Raw |
            ConvertFrom-Json
    )
    $churnTrace = ConvertFrom-CoordinatorTrace `
        -TracePaths @((Join-Path $fixtures 'sustained-churn.trace')) `
        -RunRecords $churnRuns `
        -Budget 16 `
        -StrictParsing
    Assert-True -Condition $churnTrace.Consistent -Message 'Sustained churn fixture trace is consistent'
    $onsetResult = Test-SteadyOnsetState `
        -Trace $churnTrace `
        -NowUtc ([DateTimeOffset]'2026-08-12T06:00:35Z') `
        -ExpectedAllocation 12 `
        -MinimumQueueDepth 2 `
        -StableSeconds 30 `
        -HandoffGapToleranceSeconds 1
    Assert-True -Condition $onsetResult.Accepted -Message 'Semantic sustained onset bridges repeated sub-second release/deferred-grant handoffs'
    Assert-Equal -Actual $onsetResult.BridgedHandoffCount -Expected 3 -Message 'All saturated handoffs in the 30-second interval are bridged'
    $shortfallOnset = Test-SteadyOnsetState `
        -Trace $churnTrace `
        -NowUtc ([DateTimeOffset]'2026-08-12T06:00:43Z') `
        -ExpectedAllocation 12 `
        -MinimumQueueDepth 2 `
        -StableSeconds 30 `
        -HandoffGapToleranceSeconds 1
    Assert-True -Condition (-not $shortfallOnset.Accepted) -Message 'Allocation shortfall longer than the trace-event tolerance resets semantic saturation'
    $drainedQueueOnset = Test-SteadyOnsetState `
        -Trace $churnTrace `
        -NowUtc ([DateTimeOffset]'2026-08-12T06:00:55Z') `
        -ExpectedAllocation 12 `
        -MinimumQueueDepth 2 `
        -StableSeconds 30 `
        -HandoffGapToleranceSeconds 1
    Assert-True -Condition (-not $drainedQueueOnset.Accepted) -Message 'Queue depth below two resets semantic saturation'

    $monitorRoot = Join-Path $testRoot 'monitor'
    New-Item -ItemType Directory -Force -Path $monitorRoot | Out-Null
    @(
        'timestampUtc,value',
        '2026-08-12T05:00:00Z,1',
        '2026-08-12T05:00:01Z,1',
        '2026-08-12T05:00:07Z,1'
    ) | Set-Content -LiteralPath (Join-Path $monitorRoot 'system.csv') -Encoding utf8
    @(
        'timestampUtc,processId',
        '2026-08-12T05:00:00Z,1',
        '2026-08-12T05:00:05Z,1'
    ) | Set-Content -LiteralPath (Join-Path $monitorRoot 'processes.csv') -Encoding utf8
    @(
        'timestampUtc,value',
        '2026-08-12T05:00:00Z,1',
        '2026-08-12T05:00:05Z,1'
    ) | Set-Content -LiteralPath (Join-Path $monitorRoot 'probes.csv') -Encoding utf8
    $continuity = Test-TelemetryContinuity -MonitorRoot $monitorRoot
    Assert-True -Condition $continuity.Valid -Message 'Telemetry fixture below hard limits is valid'
    Assert-Equal -Actual $continuity.Statistics.system.WarningCount -Expected 1 -Message 'Five-second system warning gap is counted'
    Add-Content -LiteralPath (Join-Path $monitorRoot 'probe-monitor-errors.log') -Value 'synthetic failure'
    $invalidContinuity = Test-TelemetryContinuity -MonitorRoot $monitorRoot
    Assert-True -Condition (-not $invalidContinuity.Valid) -Message 'Monitor error log invalidates telemetry'

    $controllerModel = Get-Content -LiteralPath (Join-Path $fixtures 'controller-model.json') -Raw | ConvertFrom-Json
    $events = [Collections.Generic.List[object]]::new()
    $activeRun = @{}
    $generation = @{}
    $timestamp = [DateTimeOffset]'2026-08-12T03:00:00Z'
    foreach ($worker in 1..$controllerModel.InitialWorkers) {
        $generation[$worker] = 1
        $activeRun[$worker] = "normal$worker-g1"
        $events.Add([pscustomobject]@{
            TimestampUtc = $timestamp.ToString('O')
            Event = 'Launched'
            RunId = $activeRun[$worker]
            Worker = $worker
        })
        $timestamp = $timestamp.AddMilliseconds(10)
    }
    $events.Add([pscustomobject]@{
        TimestampUtc = $timestamp.ToString('O')
        Event = 'SteadyOnset'
        RunId = $null
        Worker = $null
    })
    foreach ($completion in 1..$controllerModel.MeasuredCompletions) {
        $worker = [int]$controllerModel.CompletionWorkerOrder[$completion - 1]
        $completedRun = $activeRun[$worker]
        $timestamp = $timestamp.AddSeconds(1)
        $events.Add([pscustomobject]@{
            TimestampUtc = $timestamp.ToString('O')
            Event = 'Completed'
            RunId = $completedRun
            Worker = $worker
            ExitCode = 0
            Quiescent = $true
        })
        $events.Add([pscustomobject]@{
            TimestampUtc = $timestamp.AddMilliseconds(1).ToString('O')
            Event = 'MeasuredCompletion'
            RunId = $completedRun
            Worker = $worker
            CompletionNumber = $completion
        })
        if ($completion -eq $controllerModel.InjectionAfterCompletion) {
            $events.Add([pscustomobject]@{
                TimestampUtc = $timestamp.AddMilliseconds(2).ToString('O')
                Event = 'Injected'
                RunId = 'injected-g1'
                Worker = 0
            })
        }
        if ($completion -eq $controllerModel.MeasuredCompletions) {
            $events.Add([pscustomobject]@{
                TimestampUtc = $timestamp.AddMilliseconds(3).ToString('O')
                Event = 'SteadyEnd'
                RunId = $completedRun
                Worker = $worker
            })
        }
        else {
            $generation[$worker]++
            $replacement = "normal$worker-g$($generation[$worker])"
            $events.Add([pscustomobject]@{
                TimestampUtc = $timestamp.AddMilliseconds(4).ToString('O')
                Event = 'ReplacementLaunched'
                RunId = $replacement
                Worker = $worker
                ReplacedRunId = $completedRun
            })
            $activeRun[$worker] = $replacement
        }
    }
    $controllerValidation = Test-SustainedControllerEvents `
        -Events $events.ToArray() `
        -InitialWorkers 18 `
        -InjectionCompletion 6 `
        -EndingCompletion 12
    Assert-True -Condition $controllerValidation.Valid -Message 'Synthetic sustained controller fixture is valid'
    $overlapEvents = [Collections.Generic.List[object]]::new()
    $overlapEvents.AddRange([object[]]$events.ToArray())
    $overlapEvents.Insert(1, [pscustomobject]@{
        TimestampUtc = (ConvertTo-UtcDateTimeOffset -Value $events[0].TimestampUtc).AddMilliseconds(1).ToString('O')
        Event = 'ReplacementLaunched'
        RunId = 'overlap'
        Worker = 1
        ReplacedRunId = 'none'
    })
    $overlapValidation = Test-SustainedControllerEvents -Events $overlapEvents.ToArray()
    Assert-True -Condition (-not $overlapValidation.Valid) -Message 'Controller overlap is rejected'
    $nonexistentCompletionEvents = @(
        Get-Content -LiteralPath (Join-Path $fixtures 'controller-invalid-nonexistent-completion.json') -Raw |
            ConvertFrom-Json
    )
    $nonexistentCompletionValidation = Test-SustainedControllerEvents `
        -Events $nonexistentCompletionEvents `
        -InitialWorkers 2 `
        -InjectionCompletion 1 `
        -EndingCompletion 1
    Assert-True -Condition (-not $nonexistentCompletionValidation.Valid) -Message 'Measured marker without a successful quiescent Completed event is rejected'
    $lateLaunchEvents = @(
        Get-Content -LiteralPath (Join-Path $fixtures 'controller-invalid-late-launch.json') -Raw |
            ConvertFrom-Json
    )
    $lateLaunchValidation = Test-SustainedControllerEvents `
        -Events $lateLaunchEvents `
        -InitialWorkers 2 `
        -InjectionCompletion 1 `
        -EndingCompletion 1
    Assert-True -Condition (-not $lateLaunchValidation.Valid) -Message 'Initial launch after steady onset is rejected'

    $swappedIdentityFixture = Get-Content `
        -LiteralPath (Join-Path $fixtures 'scenario-identity-swapped.json') `
        -Raw |
        ConvertFrom-Json
    $swappedIdentity = Test-ScenarioEvidenceIdentity `
        -PlanRow $swappedIdentityFixture.Plan `
        -BlockCompletion $swappedIdentityFixture.Completion `
        -Validation $swappedIdentityFixture.Validation `
        -Metrics $swappedIdentityFixture.Metrics
    Assert-True -Condition (-not $swappedIdentity.Valid) -Message 'Swapped BASE/FINAL scenario evidence cannot be relabeled from the plan'
    Assert-True `
        -Condition (($swappedIdentity.Errors -join '; ') -match 'Condition') `
        -Message 'Swapped scenario identity reports the exact mismatched condition'
    $matchingIdentityFixture = Get-Content `
        -LiteralPath (Join-Path $fixtures 'scenario-identity-swapped.json') `
        -Raw |
        ConvertFrom-Json
    foreach ($artifact in @($matchingIdentityFixture.Validation, $matchingIdentityFixture.Metrics)) {
        $artifact.Condition = 'BASE'
        $artifact.RunIdentity = 'isolated|roslyn|block=2|attempt=1|order=1|condition=BASE'
    }
    $matchingIdentity = Test-ScenarioEvidenceIdentity `
        -PlanRow $matchingIdentityFixture.Plan `
        -BlockCompletion $matchingIdentityFixture.Completion `
        -Validation $matchingIdentityFixture.Validation `
        -Metrics $matchingIdentityFixture.Metrics
    Assert-True -Condition $matchingIdentity.Valid -Message 'Exactly matching plan, completion, validation, and metrics identity is accepted'

    $pairs = @(
        [pscustomobject]@{ BaselineValue = 1.0; CandidateValue = 2.0 },
        [pscustomobject]@{ BaselineValue = 2.0; CandidateValue = 4.0 }
    )
    $estimate1 = New-PairedEstimate `
        -Pairs $pairs `
        -Shape isolated `
        -Repository fixture `
        -Baseline BASE `
        -Candidate COMPAT `
        -Metric EndToEndSeconds `
        -PreferredDirection lower `
        -Seed 20260812
    $estimate2 = New-PairedEstimate `
        -Pairs $pairs `
        -Shape isolated `
        -Repository fixture `
        -Baseline BASE `
        -Candidate COMPAT `
        -Metric EndToEndSeconds `
        -PreferredDirection lower `
        -Seed 20260812
    Assert-Equal -Actual ([Math]::Round($estimate1.EffectPercent, 8)) -Expected 100 -Message 'Paired log-ratio effect is correct'
    Assert-Equal -Actual $estimate1.ConfidenceIntervalLowerPercent -Expected $estimate2.ConfidenceIntervalLowerPercent -Message 'Whole-block resampling is deterministic'
    Assert-Equal -Actual $estimate1.ExactTwoSidedSignFlipP -Expected 0.5 -Message 'Exact sign-flip p-value is correct'
    Assert-Equal -Actual $estimate1.ResampleIterations -Expected 10000 -Message 'Exactly 10,000 resamples are used'
    Assert-Equal -Actual $estimate1.Seed -Expected 20260812 -Message 'Isolated seed is exact'
    Assert-True -Condition $estimate1.ControlKind.Contains('no post-hoc', [StringComparison]::OrdinalIgnoreCase) -Message 'Compatibility control forbids post-hoc tolerance'
    $sixPairs = @(1..6 | ForEach-Object {
        [pscustomobject]@{ BaselineValue = 10.0; CandidateValue = 9.0 }
    })
    $sixEstimate = New-PairedEstimate `
        -Pairs $sixPairs `
        -Shape isolated `
        -Repository fixture `
        -Baseline BASE `
        -Candidate FINAL-N `
        -Metric EndToEndSeconds `
        -PreferredDirection lower `
        -Seed 20260812
    Assert-Equal -Actual $sixEstimate.MinimumAttainableTwoSidedExactP -Expected 0.03125 -Message 'n=6 exact p-value discreteness is explicit'
    Assert-True -Condition $sixEstimate.DirectionalEstimate -Message 'Lean small-n inference is explicitly directional'
    $fourPairs = @($sixPairs[0..3])
    $fourEstimate = New-PairedEstimate `
        -Pairs $fourPairs `
        -Shape sustained `
        -Repository fixture `
        -Baseline BASE `
        -Candidate FINAL-N `
        -Metric TotalWallSeconds `
        -PreferredDirection lower `
        -Seed 20260814
    Assert-Equal -Actual $fourEstimate.MinimumAttainableTwoSidedExactP -Expected 0.125 -Message 'n=4 exact p-value discreteness is explicit'
    $passingPilots = @(
        foreach ($repository in @('roslyn', 'aspire')) {
            [pscustomobject]@{ Repository = $repository; Condition = 'BASE'; TotalWallSeconds = 40.0; MeasuredNormalCompletions = 12; SteadyWindowSeconds = 100.0 }
            [pscustomobject]@{ Repository = $repository; Condition = 'FINAL-N'; TotalWallSeconds = 45.0; MeasuredNormalCompletions = 12; SteadyWindowSeconds = 100.0 }
            [pscustomobject]@{ Repository = $repository; Condition = 'FINAL-H'; TotalWallSeconds = 50.0; MeasuredNormalCompletions = 12; SteadyWindowSeconds = 100.0 }
        }
    )
    $projection = Get-LeanCampaignProjection `
        -RepositoryTimings $passingPilots `
        -SetupElapsedSeconds 600
    Assert-True -Condition $projection.Passed -Message 'Actual sustained-pilot fixture passes the conservative strict projection'
    Assert-Equal -Actual $projection.PilotCount -Expected 6 -Message 'Projection requires minimum BASE, FINAL-N, and FINAL-H pilots for both repositories'
    Assert-Equal -Actual $projection.IsolatedScenariosPerRepository -Expected 21 -Message 'Projection includes 21 isolated condition scenarios per repository'
    Assert-Equal -Actual $projection.SustainedScenariosPerRepository -Expected 20 -Message 'Projection includes 20 sustained condition scenarios per repository'
    Assert-Equal -Actual $projection.ConditionScenariosPerRepository -Expected 41 -Message 'Projection accounts for every two-shape condition scenario and cooldown'
    $abilityFailurePilots = @($passingPilots | ForEach-Object {
        [pscustomobject]@{
            Repository = $_.Repository
            Condition = $_.Condition
            TotalWallSeconds = $_.TotalWallSeconds
            MeasuredNormalCompletions = $_.MeasuredNormalCompletions
            SteadyWindowSeconds = if ($_.Repository -eq 'roslyn' -and $_.Condition -eq 'BASE') { 601.0 } else { $_.SteadyWindowSeconds }
        }
    })
    $failedAbilityProjection = Get-LeanCampaignProjection `
        -RepositoryTimings $abilityFailurePilots `
        -SetupElapsedSeconds 0
    Assert-True -Condition (-not $failedAbilityProjection.SustainedAbilityProjectionPassed) -Message 'Observed pilot inability to finish 12 completions within 10 minutes stops the campaign'
    $runtimeFailurePilots = @(
        foreach ($repository in @('roslyn', 'aspire')) {
            foreach ($condition in @('BASE', 'FINAL-N', 'FINAL-H')) {
                [pscustomobject]@{ Repository = $repository; Condition = $condition; TotalWallSeconds = 120.0; MeasuredNormalCompletions = 12; SteadyWindowSeconds = 100.0 }
            }
        }
    )
    $failedRuntimeProjection = Get-LeanCampaignProjection `
        -RepositoryTimings $runtimeFailurePilots `
        -SetupElapsedSeconds 0
    Assert-True -Condition $failedRuntimeProjection.SustainedAbilityProjectionPassed -Message 'Runtime-gate fixture isolates campaign duration from sustained ability'
    Assert-True -Condition (-not $failedRuntimeProjection.RuntimeProjectionPassed) -Message 'Projection above four hours stops rather than reducing scope'

    $fakeRun = Join-Path $testRoot 'fake-run'
    $fakeDestination = Join-Path $testRoot 'public'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeRun 'analysis') | Out-Null
    Write-JsonAtomic -Path (Join-Path $fakeRun 'analysis\analysis-validation.json') -Value ([pscustomobject]@{ Valid = $true })
    Write-JsonAtomic -Path (Join-Path $fakeRun 'run-metadata.json') -Value ([pscustomobject]@{
        UserPath = "C:\Users\$env:USERNAME\private"
        Host = $env:COMPUTERNAME
        Url = 'https://name:password@example.test/path?token=secret-value'
        Perf = 'C:\perf\results\run'
    })
    Set-Content -LiteralPath (Join-Path $fakeRun 'analysis\report.md') -Value 'safe report' -Encoding utf8
    & (Join-Path $PSScriptRoot 'Publish-Evidence.ps1') -RunRoot $fakeRun -DestinationRoot $fakeDestination | Out-Null
    $sanitization = Get-Content -LiteralPath (Join-Path $fakeDestination 'sanitization-report.json') -Raw | ConvertFrom-Json
    Assert-True -Condition $sanitization.Valid -Message 'Synthetic public package sanitizes successfully'
    $publicMetadata = Get-Content -LiteralPath (Join-Path $fakeDestination 'run-metadata.json') -Raw
    Assert-True -Condition (-not $publicMetadata.Contains($env:USERNAME, [StringComparison]::OrdinalIgnoreCase)) -Message 'Public package removes username'
    Assert-True -Condition (-not $publicMetadata.Contains('secret-value', [StringComparison]::Ordinal)) -Message 'Public package removes query credential'

    $testResult = [pscustomobject][ordered]@{
        Valid = $true
        Assertions = $assertionCount
        PowerShellScriptsParsed = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.ps1').Count
        PlanRows = $plan.Rows.Count
        TraceFixtures = 5
        ReviewFindingsCovered = 8
        ControllerInvalidFixtures = 2
        PreparationWorktreesValidated = 19
        ControllerMeasuredCompletions = $controllerValidation.MeasuredCompletionCount
        ResampleIterations = $estimate1.ResampleIterations
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        Write-JsonAtomic -Path $ResultPath -Value $testResult
    }
    $testResult | ConvertTo-Json
}
finally {
    if (-not $KeepOutput) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
