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
$savedRegistryVariable = Get-Variable `
    -Name CurrentVsFinalToolingProcessRegistry `
    -Scope Global `
    -ErrorAction SilentlyContinue
$savedRegistryKeysVariable = Get-Variable `
    -Name CurrentVsFinalToolingProcessRegistryKeys `
    -Scope Global `
    -ErrorAction SilentlyContinue
$savedRegistryPathVariable = Get-Variable `
    -Name CurrentVsFinalToolingProcessRegistryPath `
    -Scope Global `
    -ErrorAction SilentlyContinue
$savedRegistryEntries = if ($null -eq $savedRegistryVariable) {
    @()
}
else {
    @($savedRegistryVariable.Value)
}
$savedRegistryKeys = if ($null -eq $savedRegistryKeysVariable) {
    @()
}
else {
    @($savedRegistryKeysVariable.Value)
}
$savedRegistryPath = if ($null -eq $savedRegistryPathVariable) {
    $null
}
else {
    $savedRegistryPathVariable.Value
}

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
    $nativeOutputFunctionText = $commonText.Substring(
        $commonText.IndexOf('function Get-NativeOutput', [StringComparison]::Ordinal),
        $commonText.IndexOf(
            'function Get-ExactBootstrapBuildArguments',
            [StringComparison]::Ordinal) -
            $commonText.IndexOf('function Get-NativeOutput', [StringComparison]::Ordinal))
    Assert-True -Condition (-not $nativeOutputFunctionText.Contains('& $FileName', [StringComparison]::Ordinal)) -Message 'Get-NativeOutput never invokes native commands directly'
    Assert-True -Condition $nativeOutputFunctionText.Contains('[Diagnostics.ProcessStartInfo]', [StringComparison]::Ordinal) -Message 'Get-NativeOutput uses bounded ProcessStartInfo execution'
    Assert-True -Condition $nativeOutputFunctionText.Contains('[int]$TimeoutSeconds = 300', [StringComparison]::Ordinal) -Message 'Get-NativeOutput has a reasonable configurable default timeout'
    $preflightText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Run-PreflightValidation.ps1') -Raw
    Assert-True -Condition $preflightText.Contains("'base-functional-isolated'", [StringComparison]::Ordinal) -Message 'Preflight includes an exact BASE functional grant smoke'
    Assert-True -Condition $preflightText.Contains("'final-functional-default-isolated'", [StringComparison]::Ordinal) -Message 'Preflight includes an exact FINAL functional grant smoke'
    Assert-True -Condition $preflightText.Contains('Stop-UnfinishedScenarioBuilds', [StringComparison]::Ordinal) -Message 'Preflight synthetic failures clean captured process trees in finally'
    Assert-True -Condition $preflightText.Contains('BuildServerShutdownError', [StringComparison]::Ordinal) -Message 'Preflight failure evidence retains build-server shutdown errors'
    $phaseOnePath = Join-Path $PSScriptRoot 'Run-PhaseOneDisposablePreflight.ps1'
    Assert-True -Condition (Test-Path -LiteralPath $phaseOnePath -PathType Leaf) -Message 'Disposable Phase 1 synchronous entry point exists'
    $phaseOneText = Get-Content -LiteralPath $phaseOnePath -Raw
    Assert-True -Condition $phaseOneText.Contains('[Parameter(Mandatory)]', [StringComparison]::Ordinal) -Message 'Disposable Phase 1 requires explicit parameters'
    Assert-True -Condition $phaseOneText.Contains('Run-PreflightValidation.ps1', [StringComparison]::Ordinal) -Message 'Disposable Phase 1 invokes the existing exact smoke'
    Assert-True -Condition $phaseOneText.Contains('Start-ScenarioBuild', [StringComparison]::Ordinal) -Message 'Disposable Phase 1 lifecycle uses the real scenario-build helper'
    Assert-True -Condition $phaseOneText.Contains('Start-ScenarioMonitor', [StringComparison]::Ordinal) -Message 'Disposable Phase 1 starts the real resource monitor'
    Assert-True -Condition $phaseOneText.Contains('Disable-CampaignKeepAwake', [StringComparison]::Ordinal) -Message 'Disposable Phase 1 restores keep-awake state'
    Assert-True -Condition $phaseOneText.Contains('unpromoted-completion.json', [StringComparison]::Ordinal) -Message 'Disposable Phase 1 cannot leave an attempt success marker after root promotion fails'
    Assert-True -Condition (-not $phaseOneText.Contains('Launch-Campaign.ps1', [StringComparison]::OrdinalIgnoreCase)) -Message 'Disposable Phase 1 never delegates to the detached launcher'
    Assert-True -Condition (-not [regex]::IsMatch($phaseOneText, '(?m)\bStart-Process\b')) -Message 'Disposable Phase 1 contains no detached process cmdlet'
    $finalAuditOrderingIndex = $phaseOneText.IndexOf(
        '$finalProcessAudit = Invoke-PhaseOneRegisteredProcessAudit',
        [StringComparison]::Ordinal)
    $finalRehashOrderingIndex = $phaseOneText.IndexOf(
        '$finalBootstrapRehash = Get-PhaseOneFinalBootstrapRehash',
        [StringComparison]::Ordinal)
    $attemptPromotionOrderingIndex = $phaseOneText.IndexOf(
        '-Path $attemptCompletionPath',
        $finalRehashOrderingIndex,
        [StringComparison]::Ordinal)
    $rootPromotionOrderingIndex = $phaseOneText.IndexOf(
        'Write-JsonAtomic -Path $rootCompletionPath',
        $attemptPromotionOrderingIndex,
        [StringComparison]::Ordinal)
    Assert-True `
        -Condition (
            $finalAuditOrderingIndex -ge 0 -and
            $finalAuditOrderingIndex -lt $finalRehashOrderingIndex -and
            $finalRehashOrderingIndex -lt $attemptPromotionOrderingIndex -and
            $attemptPromotionOrderingIndex -lt $rootPromotionOrderingIndex) `
        -Message 'Final process audit precedes the final managed rehash and atomic completion promotion'
    $postRehashPromotionContract = $phaseOneText.Substring(
        $finalRehashOrderingIndex,
        $rootPromotionOrderingIndex - $finalRehashOrderingIndex)
    Assert-True `
        -Condition (-not [regex]::IsMatch(
            $postRehashPromotionContract,
            '(?m)\b(Get-NativeOutput|Invoke-RecordedCommand|Get-PhaseOneBootstrapEvidence|Invoke-BuildServerShutdown)\b')) `
        -Message 'No native command can run between final bootstrap rehash and completion promotion'
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
    . (Join-Path $PSScriptRoot 'PhaseOneDisposablePreflight.Common.ps1')

    $jobProbeProcess = $null
    $jobProbe = $null
    $jobProbeStart = $null
    try {
        $jobProbeProcess =
            Start-TestPowerShellProcess -Script 'Start-Sleep -Seconds 120'
        $jobProbeStart =
            ConvertTo-UtcDateTimeOffset -Value $jobProbeProcess.StartTime
        $jobProbe = New-ScenarioTrackingJob -RunId 'job-api-probe'
        Add-ProcessToScenarioTrackingJob `
            -Job $jobProbe `
            -Process $jobProbeProcess
        Assert-True `
            -Condition $jobProbe.KillOnJobClose `
            -Message 'Scenario tracking job configures KILL_ON_JOB_CLOSE'
        $jobProbeMembers = @(Get-ScenarioTrackingJobProcessIds -Job $jobProbe)
        Assert-True `
            -Condition ($jobProbeMembers -contains $jobProbeProcess.Id) `
            -Message 'Scenario tracking job query returns its exact assigned root'
        Close-ScenarioTrackingJob -Job $jobProbe
        Assert-True `
            -Condition $jobProbe.IsClosed `
            -Message 'Scenario tracking job close disposes its native handle'
        [void]$jobProbeProcess.WaitForExit(5000)
        Assert-True `
            -Condition (-not (Test-VerifiedProcessIdentity `
                -ProcessId $jobProbeProcess.Id `
                -ProcessStartUtc $jobProbeStart)) `
            -Message 'KILL_ON_JOB_CLOSE terminates an assigned process'
        $closedJobQueryFailed = $false
        try {
            [void](Get-ScenarioTrackingJobProcessIds -Job $jobProbe)
        }
        catch [ObjectDisposedException] {
            $closedJobQueryFailed = $true
        }
        Assert-True `
            -Condition $closedJobQueryFailed `
            -Message 'A closed scenario tracking job cannot be queried as though census succeeded'
    }
    finally {
        if ($null -ne $jobProbe -and -not $jobProbe.IsClosed) {
            Close-ScenarioTrackingJob -Job $jobProbe
        }
        if ($null -ne $jobProbeProcess) {
            if ($null -ne $jobProbeStart -and
                (Test-VerifiedProcessIdentity `
                    -ProcessId $jobProbeProcess.Id `
                    -ProcessStartUtc $jobProbeStart)) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId $jobProbeProcess.Id `
                    -RootProcessStartUtc $jobProbeStart `
                    -TimeoutSeconds 5)
            }
            $jobProbeProcess.Dispose()
        }
    }

    $suspendedFixturePath =
        Join-Path $testRoot 'suspended-launch-fixture.ps1'
    @'
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]]$FixtureArguments
)

$ErrorActionPreference = 'Stop'
$markerPrefix = 'CVF_MARKER_'
$markerTokens = @(
    @($FixtureArguments) |
        Where-Object {
            $_.StartsWith($markerPrefix, [StringComparison]::Ordinal)
        }
)
if ($markerTokens.Count -ne 1) {
    throw "Expected one encoded marker argument, found $($markerTokens.Count)."
}
$markerPath = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String(
        $markerTokens[0].Substring($markerPrefix.Length)))
$observedArguments = @(
    @($FixtureArguments) |
        Where-Object {
            -not $_.StartsWith($markerPrefix, [StringComparison]::Ordinal)
        }
)

$childScript = 'Start-Sleep -Seconds 120'
$childEncoded = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($childScript))
$childStartInfo =
    [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
foreach ($argument in @(
    '-NoLogo',
    '-NoProfile',
    '-EncodedCommand',
    $childEncoded
)) {
    $childStartInfo.ArgumentList.Add($argument)
}
$childStartInfo.UseShellExecute = $false
$childStartInfo.CreateNoWindow = $true
$child = [Diagnostics.Process]::new()
$child.StartInfo = $childStartInfo
try {
    [void]$child.Start()
    $childStartUtc = $child.StartTime.ToUniversalTime()
    $record = [pscustomobject][ordered]@{
        ParentProcessId = $PID
        ChildProcessId = $child.Id
        ChildStartUtc = $childStartUtc.ToString('O')
        WorkingDirectory = (Get-Location).Path
        RemovedPresent = Test-Path Env:CVF_SUSPENDED_REMOVE
        PreservedValue =
            [Environment]::GetEnvironmentVariable(
                'CVF_SUSPENDED_PRESERVE',
                'Process')
        Arguments = $observedArguments
    }
    [IO.File]::WriteAllText(
        $markerPath,
        ($record | ConvertTo-Json -Depth 5 -Compress),
        [Text.UTF8Encoding]::new($false))
    [Console]::Out.WriteLine('suspended-fixture-stdout')
    [Console]::Error.WriteLine('suspended-fixture-stderr')
}
finally {
    $child.Dispose()
}
'@ | Set-Content -LiteralPath $suspendedFixturePath -Encoding utf8

    $suspendedProcess = $null
    $suspendedJob = $null
    $suspendedChildId = $null
    $suspendedChildStart = $null
    $removedEnvironmentValue =
        [Environment]::GetEnvironmentVariable(
            'CVF_SUSPENDED_REMOVE',
            'Process')
    $preservedEnvironmentValue =
        [Environment]::GetEnvironmentVariable(
            'CVF_SUSPENDED_PRESERVE',
            'Process')
    try {
        [Environment]::SetEnvironmentVariable(
            'CVF_SUSPENDED_REMOVE',
            'must-be-removed',
            'Process')
        [Environment]::SetEnvironmentVariable(
            'CVF_SUSPENDED_PRESERVE',
            'value with spaces = and 雪',
            'Process')
        $suspendedWorkingDirectory =
            Join-Path $testRoot 'suspended launch 工作'
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $suspendedWorkingDirectory |
            Out-Null
        $suspendedMarker = Join-Path $testRoot 'suspended-launch.json'
        $markerToken = 'CVF_MARKER_' + [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($suspendedMarker))
        $expectedSuspendedArguments = @(
            'plain',
            'two words',
            '',
            'quote"inside',
            'ends-in-slash\',
            'slashes\\before"quote',
            '雪'
        )
        $suspendedStartInfo =
            [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        foreach ($argument in @(
            '-NoLogo',
            '-NoProfile',
            '-File',
            $suspendedFixturePath,
            $markerToken
        ) + $expectedSuspendedArguments) {
            $suspendedStartInfo.ArgumentList.Add($argument)
        }
        $suspendedStartInfo.WorkingDirectory =
            $suspendedWorkingDirectory
        $suspendedStartInfo.UseShellExecute = $false
        $suspendedStartInfo.CreateNoWindow = $true
        $suspendedStartInfo.RedirectStandardOutput = $true
        $suspendedStartInfo.RedirectStandardError = $true
        [void]$suspendedStartInfo.Environment.Remove(
            'CVF_SUSPENDED_REMOVE')
        $suspendedStartInfo.Environment['CVF_SUSPENDED_PRESERVE'] =
            'value with spaces = and 雪'

        $suspendedJob =
            New-ScenarioTrackingJob -RunId 'suspended-child-fixture'
        $suspendedProcess =
            New-SuspendedScenarioProcess -StartInfo $suspendedStartInfo
        Add-ProcessToScenarioTrackingJob `
            -Job $suspendedJob `
            -Process $suspendedProcess
        $suspendedIdentity = Register-StartedProcess `
            -Process $suspendedProcess.ManagedProcess `
            -Kind 'test-suspended-scenario' `
            -Source $testRoot
        $suspendedProcessStart =
            ConvertTo-UtcDateTimeOffset `
                -Value $suspendedIdentity.ProcessStartUtc
        $suspendedStdoutTask =
            $suspendedProcess.StandardOutput.ReadToEndAsync()
        $suspendedStderrTask =
            $suspendedProcess.StandardError.ReadToEndAsync()
        Assert-True `
            -Condition (-not $suspendedProcess.IsResumed) `
            -Message 'CreateProcessW returns the scenario root suspended'
        Assert-True `
            -Condition (-not (Test-Path -LiteralPath $suspendedMarker)) `
            -Message 'Suspended scenario user code cannot execute before assignment and identity registration'
        Assert-True `
            -Condition (
                @(Get-ScenarioTrackingJobProcessIds -Job $suspendedJob) `
                    -contains $suspendedProcess.Id) `
            -Message 'Suspended scenario root is a job member before ResumeThread'

        Resume-SuspendedScenarioProcess -Process $suspendedProcess
        Assert-True `
            -Condition $suspendedProcess.IsResumed `
            -Message 'Scenario wrapper records successful ResumeThread'
        Assert-True `
            -Condition $suspendedProcess.WaitForExit(15000) `
            -Message 'Immediate-exit suspended fixture root completes'
        $suspendedProcess.WaitForExit()
        Assert-Equal `
            -Actual $suspendedProcess.ExitCode `
            -Expected 0 `
            -Message 'Suspended fixture root exits successfully'
        Assert-True `
            -Condition ($suspendedProcess.ExitTime -ge $suspendedProcess.StartTime) `
            -Message 'Suspended process wrapper exposes managed ExitTime'
        $suspendedRecord =
            Get-Content -LiteralPath $suspendedMarker -Raw |
                ConvertFrom-Json
        Assert-Equal `
            -Actual $suspendedRecord.ParentProcessId `
            -Expected $suspendedProcess.Id `
            -Message 'Fixture evidence identifies the exact suspended root'
        Assert-Equal `
            -Actual $suspendedRecord.WorkingDirectory `
            -Expected $suspendedWorkingDirectory `
            -Message 'CreateProcessW preserves the exact working directory'
        Assert-True `
            -Condition (-not [bool]$suspendedRecord.RemovedPresent) `
            -Message 'CreateProcessW environment block genuinely removes inherited variables'
        Assert-Equal `
            -Actual $suspendedRecord.PreservedValue `
            -Expected 'value with spaces = and 雪' `
            -Message 'CreateProcessW Unicode environment block preserves override values'
        Assert-Equal `
            -Actual (@($suspendedRecord.Arguments) -join '|') `
            -Expected ($expectedSuspendedArguments -join '|') `
            -Message 'CreateProcessW argument quoting preserves spaces, empties, quotes, slashes, and Unicode'

        $suspendedChildId = [int]$suspendedRecord.ChildProcessId
        $suspendedChildStart =
            ConvertTo-UtcDateTimeOffset `
                -Value $suspendedRecord.ChildStartUtc
        Assert-True `
            -Condition (
                @(Get-ScenarioTrackingJobProcessIds -Job $suspendedJob) `
                    -contains $suspendedChildId) `
            -Message 'Child spawned by an immediate-exit root inherits the dedicated job'
        Assert-True `
            -Condition (Test-VerifiedProcessIdentity `
                -ProcessId $suspendedChildId `
                -ProcessStartUtc $suspendedChildStart) `
            -Message 'Immediate-exit fixture child is live before job cleanup'

        Close-ScenarioTrackingJob -Job $suspendedJob
        $suspendedChildExitTimer = [Diagnostics.Stopwatch]::StartNew()
        while (
            (Test-VerifiedProcessIdentity `
                -ProcessId $suspendedChildId `
                -ProcessStartUtc $suspendedChildStart) -and
            $suspendedChildExitTimer.Elapsed.TotalSeconds -lt 5) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True `
            -Condition (-not (Test-VerifiedProcessIdentity `
                -ProcessId $suspendedChildId `
                -ProcessStartUtc $suspendedChildStart)) `
            -Message 'KILL_ON_JOB_CLOSE cleans the inherited child after its root exits'
        Assert-True `
            -Condition $suspendedStdoutTask.Wait(
                [TimeSpan]::FromSeconds(5)) `
            -Message 'Suspended fixture stdout drains after job cleanup'
        Assert-True `
            -Condition $suspendedStderrTask.Wait(
                [TimeSpan]::FromSeconds(5)) `
            -Message 'Suspended fixture stderr drains after job cleanup'
        Assert-True `
            -Condition $suspendedStdoutTask.GetAwaiter().GetResult().Contains(
                'suspended-fixture-stdout',
                [StringComparison]::Ordinal) `
            -Message 'Suspended process wrapper exposes redirected async stdout'
        Assert-True `
            -Condition $suspendedStderrTask.GetAwaiter().GetResult().Contains(
                'suspended-fixture-stderr',
                [StringComparison]::Ordinal) `
            -Message 'Suspended process wrapper exposes redirected async stderr'

        $failureScenarioRoot =
            Join-Path $testRoot 'suspended-startup-failure'
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $failureScenarioRoot |
            Out-Null
        $failureMarker =
            Join-Path $failureScenarioRoot 'unexpected-resume.json'
        $failureMarkerToken =
            'CVF_MARKER_' + [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($failureMarker))
        $failureBootstrap = [pscustomobject]@{
            Root = Split-Path -Parent (Get-Command pwsh).Source
            DotNetPath = (Get-Command pwsh).Source
            MSBuildDllPath = '-File'
        }
        $failureRepository = [pscustomobject]@{
            BuildPath = $suspendedFixturePath
            AdditionalBuildArguments = @($failureMarkerToken)
        }
        $script:suspendedFailureProcessId = $null
        $script:suspendedFailureProcessStart = $null
        $originalRegisterStartedProcess =
            (Get-Item Function:Register-StartedProcess).ScriptBlock
        try {
            Set-Item Function:Register-StartedProcess -Value {
                param(
                    [Parameter(Mandatory)]
                    [Diagnostics.Process]$Process,
                    [Parameter(Mandatory)]
                    [string]$Kind,
                    [string]$Source
                )

                $script:suspendedFailureProcessId = $Process.Id
                $script:suspendedFailureProcessStart =
                    ConvertTo-UtcDateTimeOffset -Value $Process.StartTime
                throw [InvalidOperationException]::new(
                    'synthetic pre-resume registration failure')
            }
            $suspendedFailureObserved = $false
            try {
                [void](Start-ScenarioBuild `
                    -Bootstrap $failureBootstrap `
                    -Repository $failureRepository `
                    -Worktree $suspendedWorkingDirectory `
                    -Condition BASE `
                    -PipeName "suspended-failure-$PID" `
                    -DebugPath (Join-Path $failureScenarioRoot 'debug') `
                    -ScenarioRoot $failureScenarioRoot `
                    -RunId 'registration-failure' `
                    -Kind 'isolated' `
                    -Worker 1 `
                    -Generation 1 `
                    -ScenarioStartedUtc ([DateTimeOffset]::UtcNow))
            }
            catch {
                $suspendedFailureObserved =
                    $_.Exception.ToString().Contains(
                        'synthetic pre-resume registration failure',
                        [StringComparison]::Ordinal)
            }
            Assert-True `
                -Condition $suspendedFailureObserved `
                -Message 'Injected pre-resume registration failure propagates'
            Assert-True `
                -Condition ($null -ne $script:suspendedFailureProcessId) `
                -Message 'Failure fixture captures the exact suspended PID before cleanup'
            Assert-True `
                -Condition (-not (Test-Path -LiteralPath $failureMarker)) `
                -Message 'Pre-resume failure cleanup never executes scenario user code'
            Assert-True `
                -Condition (-not (Test-VerifiedProcessIdentity `
                    -ProcessId $script:suspendedFailureProcessId `
                    -ProcessStartUtc $script:suspendedFailureProcessStart)) `
                -Message 'Pre-resume failure terminates the exact suspended process'
        }
        finally {
            Set-Item `
                Function:Register-StartedProcess `
                -Value $originalRegisterStartedProcess
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'CVF_SUSPENDED_REMOVE',
            $removedEnvironmentValue,
            'Process')
        [Environment]::SetEnvironmentVariable(
            'CVF_SUSPENDED_PRESERVE',
            $preservedEnvironmentValue,
            'Process')
        if ($null -ne $suspendedJob -and -not $suspendedJob.IsClosed) {
            Close-ScenarioTrackingJob -Job $suspendedJob
        }
        if ($null -ne $suspendedProcess -and
            -not $suspendedProcess.IsDisposed) {
            try {
                if (-not $suspendedProcess.HasExited) {
                    if ($suspendedProcess.IsResumed) {
                        $suspendedProcess.Kill($true)
                    }
                    else {
                        Stop-SuspendedScenarioProcessBeforeResume `
                            -Process $suspendedProcess
                    }
                    [void]$suspendedProcess.WaitForExit(5000)
                }
            }
            finally {
                $suspendedProcess.Dispose()
            }
        }
        if ($null -ne $suspendedChildId -and
            $null -ne $suspendedChildStart -and
            (Test-VerifiedProcessIdentity `
                -ProcessId $suspendedChildId `
                -ProcessStartUtc $suspendedChildStart)) {
            [void](Stop-VerifiedProcessTree `
                -RootProcessId $suspendedChildId `
                -RootProcessStartUtc $suspendedChildStart `
                -TimeoutSeconds 5)
        }
        Remove-Item `
            -LiteralPath $suspendedFixturePath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    $failingJobQuery = [pscustomobject]@{ IsClosed = $false }
    $failingJobQuery | Add-Member -MemberType ScriptMethod -Name GetProcessIds -Value {
        throw [InvalidOperationException]::new('synthetic job query failure')
    }
    $failingJobQueryRun = [pscustomobject]@{
        RunId = 'job-query-failure'
        TrackingJob = $failingJobQuery
        JobMembershipQueryCount = 0
        JobMembershipLastQueryUtc = $null
        JobCensusFailed = $false
        JobCensusErrors = [Collections.Generic.List[string]]::new()
    }
    $jobQueryFailureObserved = $false
    try {
        [void](Get-ScenarioRunJobProcessIds -Run $failingJobQueryRun)
    }
    catch {
        $jobQueryFailureObserved =
            $_.Exception.Message -match 'synthetic job query failure'
    }
    Assert-True `
        -Condition (
            $jobQueryFailureObserved -and
            $failingJobQueryRun.JobCensusFailed -and
            $failingJobQueryRun.JobCensusErrors.Count -eq 1) `
        -Message 'Tracking-job query failure makes run quiescence explicitly unproven'
    $jobQueryFailureCleanup = [pscustomobject]@{
        Succeeded = $false
        Errors = @($failingJobQueryRun.JobCensusErrors)
        LiveRunIds = @()
        QuiescenceUncertainRunIds = @($failingJobQueryRun.RunId)
    }
    $jobQueryFailureTerminal = Write-ScenarioCleanupTerminalOutcome `
        -ScenarioRoot (Join-Path $testRoot 'job-query-failure') `
        -Cleanup $jobQueryFailureCleanup
    Assert-Equal `
        -Actual $jobQueryFailureTerminal.Disposition `
        -Expected 'NonRetryableHarnessFailure' `
        -Message 'Tracking-job query failure persists a non-retriable terminal cleanup outcome'

    $nativeSingleLine = @(
        Get-NativeOutput `
            -FileName (Get-Command pwsh).Source `
            -Arguments @('-NoProfile', '-Command', '[Console]::WriteLine("single-line")') `
            -WorkingDirectory $PSScriptRoot
    )
    Assert-Equal -Actual $nativeSingleLine.Count -Expected 1 -Message 'Native single-line output remains a one-element line collection'
    Assert-Equal -Actual $nativeSingleLine[0] -Expected 'single-line' -Message 'Native single-line output is not indexed as its first character'
    $nativeCaptureError = $null
    try {
        [void](Get-NativeOutput `
            -FileName (Get-Command pwsh).Source `
            -Arguments @(
                '-NoProfile',
                '-Command',
                '[Console]::WriteLine("captured-stdout"); [Console]::Error.WriteLine("captured-stderr"); exit 7'
            ) `
            -WorkingDirectory $PSScriptRoot)
    }
    catch {
        $nativeCaptureError = $_.Exception.Message
    }
    Assert-True `
        -Condition (
            $nativeCaptureError -match 'exit code 7' -and
            $nativeCaptureError.Contains('captured-stdout', [StringComparison]::Ordinal) -and
            $nativeCaptureError.Contains('captured-stderr', [StringComparison]::Ordinal)) `
        -Message 'Get-NativeOutput captures both stdout and stderr in a clear failure'
    $earlyRegistryEntries = @(Get-ToolingProcessRegistry)
    Assert-True `
        -Condition (@($earlyRegistryEntries | Where-Object Kind -like 'native-output/*').Count -ge 1) `
        -Message 'Native output started before evidence-root creation is registered in memory'
    $earlyRegistryPath = Join-Path $testRoot 'early-process-registry.jsonl'
    [void](Initialize-ToolingProcessRegistry -Path $earlyRegistryPath)
    $persistedEarlyEntries = @(
        Get-Content -LiteralPath $earlyRegistryPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    Assert-Equal `
        -Actual $persistedEarlyEntries.Count `
        -Expected $earlyRegistryEntries.Count `
        -Message 'Attempt registry initialization binds every early process identity into evidence'
    $earlyRegistryAudit = Invoke-PhaseOneRegisteredProcessAudit `
        -RegistryPath $earlyRegistryPath `
        -TimeoutSeconds 5
    Assert-True -Condition $earlyRegistryAudit.Valid -Message 'Strict final audit includes and clears all early native identities'
    Assert-Equal `
        -Actual $earlyRegistryAudit.Audit.CapturedIdentityCount `
        -Expected $earlyRegistryEntries.Count `
        -Message 'Final audit accounts for every identity captured before attempt registry initialization'
    Assert-True -Condition (-not (ConvertTo-StrictBoolean -Value 'False')) -Message 'CSV warmup identity parses False without PowerShell string truthiness'
    foreach ($coordinatorCase in @(
        [pscustomobject]@{
            Name = 'MSBuild.Coordinator.exe'
            CommandLine = '"C:\bootstrap\MSBuild.Coordinator.exe" pipe'
            Expected = $true
            Description = 'native Coordinator'
        },
        [pscustomobject]@{
            Name = 'dotnet.exe'
            CommandLine = '"C:\bootstrap\dotnet.exe" "C:\bootstrap\sdk\11.0.0\MSBuild.Coordinator.dll" pipe'
            Expected = $true
            Description = 'direct DLL-hosted Coordinator'
        },
        [pscustomobject]@{
            Name = 'DOTNET.EXE'
            CommandLine = '"C:\bootstrap\dotnet.exe" exec --roll-forward Major "C:\bootstrap\sdk\11.0.0\MSBuild.Coordinator.dll" pipe'
            Expected = $true
            Description = 'dotnet exec-hosted Coordinator'
        },
        [pscustomobject]@{
            Name = 'dotnet.exe'
            CommandLine = '"C:\bootstrap\dotnet.exe" "C:\bootstrap\sdk\11.0.0\MSBuild.dll" /m'
            Expected = $false
            Description = 'ordinary DLL-hosted MSBuild'
        },
        [pscustomobject]@{
            Name = 'dotnet.exe'
            CommandLine = '"C:\bootstrap\dotnet.exe" build "C:\src\MSBuild.Coordinator.dll"'
            Expected = $false
            Description = 'unrelated dotnet build whose project resembles the Coordinator'
        },
        [pscustomobject]@{
            Name = 'dotnet.exe'
            CommandLine = '"C:\bootstrap\dotnet.exe" "C:\tools\worker.dll" --label MSBuild.Coordinator.dll'
            Expected = $false
            Description = 'unrelated dotnet app with a Coordinator-like later argument'
        }
    )) {
        Assert-Equal `
            -Actual (Test-MSBuildCoordinatorProcess `
                -Name $coordinatorCase.Name `
                -CommandLine $coordinatorCase.CommandLine) `
            -Expected $coordinatorCase.Expected `
            -Message "Process classification handles $($coordinatorCase.Description)"
    }
    $scenarioCommonText =
        Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Scenario.Common.ps1') -Raw
    Assert-True `
        -Condition $scenarioCommonText.Contains("-Kind 'scenario-coordinator'", [StringComparison]::Ordinal) `
        -Message 'Scenario process-tree capture registers Coordinator identities separately for final audit'
    $startScenarioBuildText = $scenarioCommonText.Substring(
        $scenarioCommonText.IndexOf(
            'function Start-ScenarioBuild',
            [StringComparison]::Ordinal),
        $scenarioCommonText.IndexOf(
            'function Update-ScenarioProcessTrees',
            [StringComparison]::Ordinal) -
            $scenarioCommonText.IndexOf(
                'function Start-ScenarioBuild',
                [StringComparison]::Ordinal))
    $rootCreateSuspendedIndex = $startScenarioBuildText.IndexOf(
        '$process = New-SuspendedScenarioProcess',
        [StringComparison]::Ordinal)
    $rootJobAssignmentIndex = $startScenarioBuildText.IndexOf(
        'Add-ProcessToScenarioTrackingJob',
        [StringComparison]::Ordinal)
    $rootRegistrationIndex = $startScenarioBuildText.IndexOf(
        '$processIdentity = Register-StartedProcess',
        [StringComparison]::Ordinal)
    $rootResumeIndex = $startScenarioBuildText.IndexOf(
        'Resume-SuspendedScenarioProcess',
        [StringComparison]::Ordinal)
    Assert-True `
        -Condition (
            $rootCreateSuspendedIndex -ge 0 -and
            $rootJobAssignmentIndex -gt $rootCreateSuspendedIndex -and
            $rootRegistrationIndex -gt $rootJobAssignmentIndex -and
            $rootResumeIndex -gt $rootRegistrationIndex) `
        -Message 'Every scenario root is created suspended, job-assigned, identity-registered, then resumed'
    Assert-True `
        -Condition (-not $startScenarioBuildText.Contains(
            '$process.Start()',
            [StringComparison]::Ordinal)) `
        -Message 'Scenario launch has no success fallback to unsuspended Process.Start'
    foreach ($nativeLaunchContract in @(
        'CreateProcessW',
        'CreateSuspended',
        'CreateUnicodeEnvironment',
        'CreateNoWindow',
        'ProcThreadAttributeHandleList',
        'ResumeThread',
        'TerminateBeforeResume'
    )) {
        Assert-True `
            -Condition $scenarioCommonText.Contains(
                $nativeLaunchContract,
                [StringComparison]::Ordinal) `
            -Message "Suspended scenario launch includes $nativeLaunchContract"
    }
    Assert-True `
        -Condition $startScenarioBuildText.Contains(
            "-Disposition 'NonRetryableHarnessFailure'",
            [StringComparison]::Ordinal) `
        -Message 'Scenario job creation or assignment failure is explicitly non-retriable'
    $coordinatorFixtureStart = [DateTimeOffset]::UtcNow
    $coordinatorFixtureProcesses = @(
        [pscustomobject]@{
            ProcessId = 1900000000
            ParentProcessId = 0
            Name = 'dotnet.exe'
            CreationDate = $coordinatorFixtureStart
            CommandLine = 'dotnet.exe MSBuild.dll'
        },
        [pscustomobject]@{
            ProcessId = 1900000001
            ParentProcessId = 1900000000
            Name = 'MSBuild.Coordinator.exe'
            CreationDate = $coordinatorFixtureStart.AddMilliseconds(10)
            CommandLine = 'MSBuild.Coordinator.exe pipe'
        },
        [pscustomobject]@{
            ProcessId = 1900000002
            ParentProcessId = 1900000000
            Name = 'dotnet.exe'
            CreationDate = $coordinatorFixtureStart.AddMilliseconds(20)
            CommandLine = 'dotnet.exe C:\sdk\MSBuild.Coordinator.dll pipe'
        },
        [pscustomobject]@{
            ProcessId = 1900000003
            ParentProcessId = 1900000000
            Name = 'dotnet.exe'
            CreationDate = $coordinatorFixtureStart.AddMilliseconds(30)
            CommandLine = 'dotnet.exe C:\sdk\MSBuild.dll /m'
        }
    )
    $coordinatorFixtureRun = [pscustomobject]@{
        RunId = 'coordinator-classification'
        RootProcessId = 1900000000
        Completed = $false
        DescendantIdentities =
            [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
    $registryCountBeforeCoordinatorFixture = @(Get-ToolingProcessRegistry).Count
    Update-ScenarioProcessTrees `
        -Runs @($coordinatorFixtureRun) `
        -Processes $coordinatorFixtureProcesses
    Assert-Equal `
        -Actual $coordinatorFixtureRun.DescendantIdentities.Count `
        -Expected 1 `
        -Message 'Per-run descendants exclude both native and DLL-hosted Coordinators without excluding unrelated dotnet'
    Assert-True `
        -Condition (@(
            @($coordinatorFixtureRun.DescendantIdentities) |
                Where-Object { $_ -match '^1900000003\|' }
        ).Count -eq 1) `
        -Message 'Unrelated dotnet remains in per-run descendant quiescence'
    $coordinatorFixtureRegistryEntries = @(
        Get-ToolingProcessRegistry |
            Select-Object -Skip $registryCountBeforeCoordinatorFixture
    )
    Assert-Equal `
        -Actual @(
            $coordinatorFixtureRegistryEntries |
                Where-Object Kind -eq 'scenario-coordinator'
        ).Count `
        -Expected 2 `
        -Message 'Both Coordinator host forms receive separate exact global registry identities'
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

    function New-FinalRehashFixtureRole {
        param(
            [Parameter(Mandatory)]
            [string]$Role,
            [Parameter(Mandatory)]
            [string]$Parent
        )

        $root = Join-Path $Parent 'core'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $sourceBinary = (Get-Command pwsh).Source
        foreach ($relativePath in @(
            'dotnet.exe',
            'sdk\fixture\MSBuild.dll',
            'sdk\fixture\Microsoft.Build.dll'
        )) {
            $destination = Join-Path $root $relativePath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) |
                Out-Null
            Copy-Item -LiteralPath $sourceBinary -Destination $destination
        }
        $msbuildPath = Join-Path $root 'sdk\fixture\MSBuild.dll'
        $productVersion = (Get-Item -LiteralPath $msbuildPath).VersionInfo.ProductVersion
        $manifest = Get-DirectoryContentManifest -Root $root
        Write-JsonAtomic `
            -Path (Join-Path $Parent 'staging-metadata.json') `
            -Value ([pscustomobject][ordered]@{
                SchemaVersion = 1
                Role = $Role
                ExpectedCommit = $productVersion
                ProductVersion = $productVersion
                ContentSha256 = $manifest.ContentSha256
                FileCount = $manifest.FileCount
                TotalBytes = $manifest.TotalBytes
            })
        $stage = Test-ImmutableBootstrapStage -Root $root
        $tracked = @(
            foreach ($file in $manifest.Files) {
                [pscustomobject][ordered]@{
                    Name = [IO.Path]::GetFileName($file.RelativePath)
                    RelativePath = $file.RelativePath
                    Path = Join-Path $root $file.RelativePath
                    Sha256 = $file.Sha256
                }
            }
        )
        [pscustomobject][ordered]@{
            Role = $Role
            Commit = $productVersion
            ProductVersion = $productVersion
            BootstrapRoot = $root
            DotNetSha256 = @(
                $tracked |
                    Where-Object RelativePath -eq 'dotnet.exe'
            )[0].Sha256
            MSBuildDllSha256 = @(
                $tracked |
                    Where-Object Name -eq 'MSBuild.dll'
            )[0].Sha256
            TrackedBinaries = $tracked
            ImmutableStage = $stage
            Valid = $true
        }
    }
    $finalRehashFixtureRoot = Join-Path $testRoot 'final-rehash'
    $finalRehashEvidence = [pscustomobject][ordered]@{
        Base = New-FinalRehashFixtureRole `
            -Role base `
            -Parent (Join-Path $finalRehashFixtureRoot 'base')
        Final = New-FinalRehashFixtureRole `
            -Role final `
            -Parent (Join-Path $finalRehashFixtureRoot 'final')
    }
    $validFinalRehash = Get-PhaseOneFinalBootstrapRehash `
        -BootstrapIdentityEvidence $finalRehashEvidence
    Assert-True -Condition $validFinalRehash.Valid -Message 'Final managed bootstrap rehash accepts unchanged exact binaries and full stages'
    Assert-True -Condition $validFinalRehash.ManagedOnly -Message 'Final bootstrap rehash proves it launches no native process'
    Assert-Equal -Actual $validFinalRehash.NativeProcessCount -Expected 0 -Message 'Final bootstrap rehash records zero native calls'
    Assert-Equal `
        -Actual (Get-PhaseOneFinalBootstrapRehashBindingSha256 -Record $validFinalRehash) `
        -Expected $validFinalRehash.BindingSha256 `
        -Message 'Final bootstrap rehash hashes are completion-bindable'
    [IO.File]::AppendAllText(
        (Join-Path $finalRehashEvidence.Final.BootstrapRoot 'sdk\fixture\Microsoft.Build.dll'),
        'mutation',
        [Text.UTF8Encoding]::new($false))
    $finalMutationDetected = $false
    try {
        [void](Get-PhaseOneFinalBootstrapRehash `
            -BootstrapIdentityEvidence $finalRehashEvidence)
    }
    catch {
        $finalMutationDetected =
            $_.Exception.Message -match 'changed final tracked binary|changed full immutable Final stage'
    }
    Assert-True -Condition $finalMutationDetected -Message 'Final managed rehash detects a last-moment immutable-stage binary mutation'

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

    $retryRoot = Join-Path $testRoot 'phase-one-retry'
    $retryAttempt1 = New-PhaseOneAttemptRoot -OutputRoot $retryRoot
    Write-JsonAtomic `
        -Path (Join-Path $retryAttempt1.Path 'failure.json') `
        -Value ([pscustomobject]@{ Valid = $false; Expected = $true })
    $retryAttempt2 = New-PhaseOneAttemptRoot -OutputRoot $retryRoot
    Assert-Equal -Actual $retryAttempt1.RelativePath -Expected 'attempt-0001' -Message 'Phase 1 first attempt is numbered deterministically'
    Assert-Equal -Actual $retryAttempt2.RelativePath -Expected 'attempt-0002' -Message 'Phase 1 rerun allocates the next attempt in the same root'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $retryAttempt1.Path 'failure.json') -PathType Leaf) -Message 'Phase 1 retry preserves failed-attempt evidence'

    $completionRoot = Join-Path $testRoot 'phase-one-completion'
    $completionIdentityPath = Join-Path $testRoot 'phase-one-bootstrap-identity.json'
    Set-Content -LiteralPath $completionIdentityPath -Value '{"fixture":true}' -Encoding utf8
    $completionIdentityHash = (Get-FileHash -LiteralPath $completionIdentityPath -Algorithm SHA256).Hash
    $completionAttempt = New-PhaseOneAttemptRoot -OutputRoot $completionRoot
    $completionSnapshotDirectory = Join-Path $completionAttempt.Path 'inputs'
    New-Item -ItemType Directory -Path $completionSnapshotDirectory | Out-Null
    $completionSnapshotPath = Join-Path $completionSnapshotDirectory 'bootstrap-identities.json'
    Copy-Item -LiteralPath $completionIdentityPath -Destination $completionSnapshotPath
    (Get-Item -LiteralPath $completionSnapshotPath).IsReadOnly = $true
    $completionSnapshotHash =
        (Get-FileHash -LiteralPath $completionSnapshotPath -Algorithm SHA256).Hash
    $completionRegistryPath =
        Join-Path $completionAttempt.Path 'process-registry.jsonl'
    [IO.File]::WriteAllText(
        $completionRegistryPath,
        '',
        [Text.UTF8Encoding]::new($false))
    $completionAttemptPath = Join-Path $completionAttempt.Path 'completion.json'
    $phaseOneComponentNames = @(
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
    $completionComponents = [ordered]@{}
    foreach ($name in $phaseOneComponentNames) {
        $completionComponents[$name] = [pscustomobject]@{ Valid = $true }
    }
    $completionComponents.OutputRootSafety = [pscustomobject]@{
        Valid = $true
        ValidatedBeforeWrites = $true
        InsideGitWorktree = $false
        ProtectedPathOverlapCount = 0
    }
    $completionComponents.ProcessCleanupAudit = [pscustomobject]@{
        Valid = $true
        RegistryPath = $completionRegistryPath
        RegistryEntryCount = 0
        RegistrySha256 =
            (Get-FileHash -LiteralPath $completionRegistryPath -Algorithm SHA256).Hash
    }
    $completionRehash = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Kind = 'PhaseOneFinalBootstrapRehash'
        Valid = $true
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        ManagedOnly = $true
        NativeProcessCount = 0
        Base = [pscustomobject]@{ Valid = $true }
        Final = [pscustomobject]@{ Valid = $true }
    }
    $completionRehash | Add-Member `
        -NotePropertyName BindingSha256 `
        -NotePropertyValue (
            Get-PhaseOneFinalBootstrapRehashBindingSha256 -Record $completionRehash)
    $completionComponents.PromotionRevalidation = [pscustomobject]@{
        Valid = $true
        FinalBootstrapRehashSha256 = $completionRehash.BindingSha256
        FinalBootstrapRehash = $completionRehash
        ManagedOnlyAfterFinalProcessAudit = $true
        NativeCallsAfterRehash = 0
        RegistryEntryCountBeforeFinalRehash = 0
        RegistryEntryCountAfterFinalRehash = 0
        FinalProcessCleanupRegistrySha256 =
            $completionComponents.ProcessCleanupAudit.RegistrySha256
    }
    Write-JsonAtomic -Path $completionAttemptPath -Value ([pscustomobject]@{
        Kind = 'PhaseOneDisposablePreflightAttempt'
        Valid = $true
        AttemptNumber = $completionAttempt.Number
        BootstrapIdentityPath = $completionSnapshotPath
        BootstrapIdentitySha256 = $completionSnapshotHash
        SourceBootstrapIdentityPath = $completionIdentityPath
        SourceBootstrapIdentitySha256 = $completionIdentityHash
        FinalBootstrapRehashSha256 = $completionRehash.BindingSha256
        FinalBootstrapRehash = $completionRehash
        Synchronous = $true
        DetachedCampaignLaunched = $false
        Components = [pscustomobject]$completionComponents
    })
    $rootCompletionFixture = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Kind = 'PhaseOneDisposablePreflight'
        Valid = $true
        OutputRoot = [IO.Path]::GetFullPath($completionRoot)
        BootstrapIdentityPath = [IO.Path]::GetFullPath($completionSnapshotPath)
        BootstrapIdentitySha256 = $completionSnapshotHash
        SourceBootstrapIdentityPath = [IO.Path]::GetFullPath($completionIdentityPath)
        SourceBootstrapIdentitySha256 = $completionIdentityHash
        FinalBootstrapRehashSha256 = $completionRehash.BindingSha256
        FinalBootstrapRehash = $completionRehash
        AttemptNumber = $completionAttempt.Number
        AttemptRelativePath = $completionAttempt.RelativePath
        AttemptCompletionRelativePath = Join-Path $completionAttempt.RelativePath 'completion.json'
        AttemptCompletionSha256 = (Get-FileHash -LiteralPath $completionAttemptPath -Algorithm SHA256).Hash
        Synchronous = $true
        DetachedCampaignLaunched = $false
        RawArtifactsOutsideGit = $true
        Components = [pscustomobject]$completionComponents
    }
    $rootCompletionValidation = Test-PhaseOneRootCompletionRecord `
        -Record $rootCompletionFixture `
        -OutputRoot $completionRoot `
        -BootstrapIdentityPath $completionSnapshotPath `
        -BootstrapIdentitySha256 $completionSnapshotHash `
        -SourceBootstrapIdentityPath $completionIdentityPath `
        -SourceBootstrapIdentitySha256 $completionIdentityHash `
        -ValidateFileSystem
    Assert-True `
        -Condition $rootCompletionValidation.Valid `
        -Message "Valid Phase 1 root completion is resumable: $($rootCompletionValidation.Errors -join '; ')"
    $changedIdentityValidation = Test-PhaseOneRootCompletionRecord `
        -Record $rootCompletionFixture `
        -OutputRoot $completionRoot `
        -BootstrapIdentityPath $completionSnapshotPath `
        -BootstrapIdentitySha256 ('0' * 64) `
        -SourceBootstrapIdentityPath $completionIdentityPath `
        -SourceBootstrapIdentitySha256 $completionIdentityHash
    Assert-True -Condition (-not $changedIdentityValidation.Valid) -Message 'Phase 1 root completion refuses a changed bootstrap identity'
    $rootCompletionFixture.Components.ResourceMonitor.Valid = $false
    $invalidComponentValidation = Test-PhaseOneRootCompletionRecord `
        -Record $rootCompletionFixture `
        -OutputRoot $completionRoot `
        -BootstrapIdentityPath $completionSnapshotPath `
        -BootstrapIdentitySha256 $completionSnapshotHash `
        -SourceBootstrapIdentityPath $completionIdentityPath `
        -SourceBootstrapIdentitySha256 $completionIdentityHash
    Assert-True -Condition (-not $invalidComponentValidation.Valid) -Message 'Phase 1 root completion refuses an invalid required component'
    $rootCompletionFixture.Components.ResourceMonitor.Valid = $true

    $safetyFixtureRoot = Join-Path $testRoot 'phase-one-safety'
    $safetyBaseBootstrap = Join-Path $safetyFixtureRoot 'bootstraps\base\core'
    $safetyFinalBootstrap = Join-Path $safetyFixtureRoot 'bootstraps\final\core'
    $safetyBaseSource = Join-Path $safetyFixtureRoot 'sources\base'
    $safetyFinalSource = Join-Path $safetyFixtureRoot 'sources\final'
    New-Item `
        -ItemType Directory `
        -Force `
        -Path $safetyBaseBootstrap,$safetyFinalBootstrap,$safetyBaseSource,$safetyFinalSource |
        Out-Null
    $safetyIdentityPath = Join-Path $safetyFixtureRoot 'identity\bootstrap-identities.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $safetyIdentityPath) | Out-Null
    Write-JsonAtomic -Path $safetyIdentityPath -Value ([pscustomobject]@{
        Base = [pscustomobject]@{ Root = $safetyBaseBootstrap }
        Final = [pscustomobject]@{ Root = $safetyFinalBootstrap }
        Sources = [pscustomobject]@{
            Base = [pscustomobject]@{ Root = $safetyBaseSource }
            Final = [pscustomobject]@{ Root = $safetyFinalSource }
        }
    })
    $safetyInput = Read-PhaseOneBootstrapIdentityInput -Path $safetyIdentityPath
    $toolingRepositoryRoot = Get-PhaseOneCanonicalPath -Path (
        Join-Path $PSScriptRoot '..\..\..\..')
    $safeOutputCandidate = Join-Path `
        (Split-Path -Parent $toolingRepositoryRoot) `
        "phase-one-safe-output-$([guid]::NewGuid().ToString('N'))"
    $safeOutputValidation = Test-PhaseOneOutputRootSafety `
        -OutputRoot $safeOutputCandidate `
        -IdentityInput $safetyInput `
        -RepositoryRoot $toolingRepositoryRoot
    Assert-True -Condition $safeOutputValidation.Valid -Message 'External nonoverlapping output root passes read-only safety validation'
    Assert-True -Condition (-not (Test-Path -LiteralPath $safeOutputCandidate)) -Message 'Output-root safety validation performs no writes'

    $nestedGitRoot = Join-Path $safetyFixtureRoot 'nested-git'
    New-Item -ItemType Directory -Path $nestedGitRoot | Out-Null
    [void](Get-NativeOutput `
        -FileName git `
        -Arguments @('init', '--quiet') `
        -WorkingDirectory $nestedGitRoot)
    $gitOutputValidation = Test-PhaseOneOutputRootSafety `
        -OutputRoot (Join-Path $nestedGitRoot 'raw-output') `
        -IdentityInput $safetyInput `
        -RepositoryRoot $toolingRepositoryRoot
    Assert-True -Condition (-not $gitOutputValidation.Valid) -Message 'Output root inside any git worktree is rejected'
    Assert-True -Condition $gitOutputValidation.InsideGitWorktree -Message 'Git-worktree rejection records its physical marker evidence'

    $bootstrapOverlapValidation = Test-PhaseOneOutputRootSafety `
        -OutputRoot (Join-Path $safetyBaseBootstrap 'raw-output') `
        -IdentityInput $safetyInput `
        -RepositoryRoot $toolingRepositoryRoot
    Assert-True -Condition (-not $bootstrapOverlapValidation.Valid) -Message 'Output root below a bootstrap root is rejected'
    Assert-True `
        -Condition (@($bootstrapOverlapValidation.Overlaps | Where-Object ProtectedKind -eq 'base-bootstrap-root').Count -eq 1) `
        -Message 'Bootstrap overlap identifies the protected BASE root'
    $sourceAncestorValidation = Test-PhaseOneOutputRootSafety `
        -OutputRoot (Split-Path -Parent $safetyBaseSource) `
        -IdentityInput $safetyInput `
        -RepositoryRoot $toolingRepositoryRoot
    Assert-True -Condition (-not $sourceAncestorValidation.Valid) -Message 'Output root containing a source worktree is rejected'
    $identityDirectoryValidation = Test-PhaseOneOutputRootSafety `
        -OutputRoot (Split-Path -Parent $safetyIdentityPath) `
        -IdentityInput $safetyInput `
        -RepositoryRoot $toolingRepositoryRoot
    Assert-True -Condition (-not $identityDirectoryValidation.Valid) -Message 'Output root overlapping the identity directory is rejected'

    $snapshotAttemptRoot = Join-Path $testRoot 'phase-one-snapshot-attempt'
    New-Item -ItemType Directory -Path $snapshotAttemptRoot | Out-Null
    $identitySnapshot = New-PhaseOneBootstrapIdentitySnapshot `
        -IdentityInput $safetyInput `
        -AttemptRoot $snapshotAttemptRoot
    $snapshotBeforeMutation =
        Get-Content -LiteralPath $identitySnapshot.SnapshotPath -Raw |
        ConvertFrom-Json
    Write-JsonAtomic -Path $safetyIdentityPath -Value ([pscustomobject]@{
        Base = [pscustomobject]@{ Root = (Join-Path $safetyFixtureRoot 'mutated-base') }
        Final = [pscustomobject]@{ Root = $safetyFinalBootstrap }
        Sources = [pscustomobject]@{
            Base = [pscustomobject]@{ Root = $safetyBaseSource }
            Final = [pscustomobject]@{ Root = $safetyFinalSource }
        }
    })
    $mutatedBinding = Test-PhaseOneBootstrapIdentityBinding `
        -SourcePath $identitySnapshot.SourcePath `
        -SourceSha256 $identitySnapshot.SourceSha256 `
        -SnapshotPath $identitySnapshot.SnapshotPath `
        -SnapshotSha256 $identitySnapshot.SnapshotSha256
    Assert-True -Condition $mutatedBinding.SnapshotValid -Message 'Attempt snapshot stays bound to the original identity after source mutation'
    Assert-Equal -Actual $snapshotBeforeMutation.Base.Root -Expected $safetyBaseBootstrap -Message 'Attempt parses and retains the frozen bootstrap identity'
    Assert-True -Condition (-not $mutatedBinding.SourceUnchanged) -Message 'Source identity mutation is detected before promotion'
    Assert-True -Condition (-not $mutatedBinding.Valid) -Message 'Changed source input cannot be promoted despite a valid frozen snapshot'

    $lockRoot = Join-Path $testRoot 'phase-one-lock'
    $rootLock = Enter-PhaseOneRootLock -OutputRoot $lockRoot
    $lockChild = $null
    try {
        $commonPathForChild = (Join-Path $PSScriptRoot 'PhaseOneDisposablePreflight.Common.ps1').Replace("'", "''")
        $lockRootForChild = $lockRoot.Replace("'", "''")
        $lockChildScript = @'
. '__COMMON_PATH__'
try {
    $lock = Enter-PhaseOneRootLock -OutputRoot '__LOCK_ROOT__'
    Exit-PhaseOneRootLock -Lock $lock
    [Console]::WriteLine('UNEXPECTED_LOCK_ACQUISITION')
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 23
}
'@.Replace('__COMMON_PATH__', $commonPathForChild).Replace('__LOCK_ROOT__', $lockRootForChild)
        $lockChild = Start-TestPowerShellProcess -Script $lockChildScript -RedirectOutput
        $lockStdoutTask = $lockChild.StandardOutput.ReadToEndAsync()
        $lockStderrTask = $lockChild.StandardError.ReadToEndAsync()
        Assert-True -Condition $lockChild.WaitForExit(30000) -Message 'Duplicate lock probe exits promptly'
        $lockChild.WaitForExit()
        $lockStdout = $lockStdoutTask.GetAwaiter().GetResult()
        $lockStderr = $lockStderrTask.GetAwaiter().GetResult()
        Assert-Equal -Actual $lockChild.ExitCode -Expected 23 -Message 'Concurrent Phase 1 root owner is refused'
        Assert-True -Condition "$lockStdout`n$lockStderr".Contains('PHASE_ONE_DUPLICATE_INVOCATION', [StringComparison]::Ordinal) -Message 'Duplicate refusal emits its stable evidence marker'
    }
    finally {
        if ($null -ne $lockChild) {
            $lockChild.Dispose()
        }
        Exit-PhaseOneRootLock -Lock $rootLock
    }
    $reacquiredLock = Enter-PhaseOneRootLock -OutputRoot $lockRoot
    Exit-PhaseOneRootLock -Lock $reacquiredLock

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

    $hungRegistryPath = Join-Path $testRoot 'native-output-timeout-process-registry.jsonl'
    [void](Initialize-ToolingProcessRegistry -Path $hungRegistryPath -Reset)
    $hungNativeObserved = $false
    $hungNativeTimer = [Diagnostics.Stopwatch]::StartNew()
    $hungRegistryEntries = @()
    try {
        [void](Get-NativeOutput `
            -FileName $pwshPath `
            -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 120') `
            -WorkingDirectory $testRoot `
            -TimeoutSeconds 1)
    }
    catch {
        $hungNativeObserved = $_.Exception.Message -match 'timed out after 1 seconds'
    }
    finally {
        $hungRegistryEntries = @(Get-ToolingProcessRegistry)
        $hungNativeStop = Stop-RegisteredProcessTrees `
            -Entries $hungRegistryEntries `
            -TimeoutSeconds 5
    }
    Assert-True -Condition $hungNativeObserved -Message 'Get-NativeOutput enforces its configurable timeout'
    Assert-True -Condition ($hungNativeTimer.Elapsed.TotalSeconds -lt 20) -Message 'Get-NativeOutput hung-process cleanup remains bounded'
    Assert-Equal `
        -Actual @(
            $hungRegistryEntries |
                Where-Object Kind -eq "native-output/$([IO.Path]::GetFileName($pwshPath))"
        ).Count `
        -Expected 1 `
        -Message 'Hung native root is registered immediately'
    Assert-True -Condition $hungNativeStop.Succeeded -Message 'Hung native cleanup leaves no registered process live'
    $hungNativeAudit = Get-PhaseOneProcessCleanupAudit `
        -RegistryEntries $hungRegistryEntries
    Assert-True -Condition $hungNativeAudit.Valid -Message 'Final audit proves the hung native probe did not leak'
    Assert-Equal `
        -Actual @(
            Get-Content -LiteralPath $hungRegistryPath |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        ).Count `
        -Expected $hungRegistryEntries.Count `
        -Message 'Hung native identity is persisted for final audit'

    $timeoutRegistryPath = Join-Path $testRoot 'recorded-timeout-process-registry.jsonl'
    [void](Initialize-ToolingProcessRegistry -Path $timeoutRegistryPath -Reset)
    $timeoutChildIdentityPath = Join-Path $testRoot 'recorded-timeout-child.txt'
    $timeoutChildEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 120'))
    $timeoutCommandScript = @"
`$child = Start-Process -FilePath '$($pwshPath.Replace("'", "''"))' -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', '$timeoutChildEncoded') -PassThru
[IO.File]::WriteAllText('$($timeoutChildIdentityPath.Replace("'", "''"))', "`$(`$child.Id)|`$(`$child.StartTime.ToUniversalTime().ToString('O'))")
Start-Sleep -Seconds 120
"@
    $timeoutCommandEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($timeoutCommandScript))
    $timeoutJournal = Join-Path $testRoot 'recorded-timeout-commands.jsonl'
    $timeoutObserved = $false
    $timeoutTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void](Invoke-RecordedCommand `
            -FileName $pwshPath `
            -Arguments @('-NoLogo', '-NoProfile', '-EncodedCommand', $timeoutCommandEncoded) `
            -WorkingDirectory $testRoot `
            -JournalPath $timeoutJournal `
            -Label 'short-timeout-tree' `
            -TimeoutSeconds 2)
    }
    catch {
        $timeoutObserved = $_.Exception.Message -match 'timed out after 2 seconds'
    }
    Assert-True -Condition $timeoutObserved -Message 'Recorded native command enforces its configured timeout'
    Assert-True -Condition ($timeoutTimer.Elapsed.TotalSeconds -lt 20) -Message 'Recorded native timeout remains bounded through stream drain and cleanup'
    $timeoutEntry =
        Get-Content -LiteralPath $timeoutJournal |
        Select-Object -Last 1 |
        ConvertFrom-Json
    Assert-True -Condition $timeoutEntry.TimedOut -Message 'Native timeout is journaled explicitly'
    Assert-Equal -Actual $timeoutEntry.TimeoutSeconds -Expected 2 -Message 'Native timeout journal records the configured bound'
    Assert-True -Condition $timeoutEntry.Termination.Succeeded -Message 'Timed-out native process tree has verified termination evidence'
    Assert-True `
        -Condition (-not (Test-VerifiedProcessIdentity `
            -ProcessId ([int]$timeoutEntry.ProcessId) `
            -ProcessStartUtc $timeoutEntry.ProcessStartUtc)) `
        -Message 'Timed-out native root process does not leak'
    Assert-True -Condition (Test-Path -LiteralPath $timeoutChildIdentityPath -PathType Leaf) -Message 'Timed-out command fixture published its sleeping child identity'
    $timeoutChildIdentity = (Get-Content -LiteralPath $timeoutChildIdentityPath -Raw).Trim()
    $timeoutChildParts = $timeoutChildIdentity -split '\|', 2
    Assert-True `
        -Condition (-not (Test-VerifiedProcessIdentity `
            -ProcessId ([int]$timeoutChildParts[0]) `
            -ProcessStartUtc $timeoutChildParts[1])) `
        -Message 'Timed-out native sleeping child does not leak'

    $fastOrphanRegistryPath = Join-Path $testRoot 'fast-orphan-process-registry.jsonl'
    [void](Initialize-ToolingProcessRegistry -Path $fastOrphanRegistryPath -Reset)
    $fastOrphanIdentityPath = Join-Path $testRoot 'fast-orphan-child.txt'
    $fastOrphanScript = @"
`$child = Start-Process -FilePath '$($pwshPath.Replace("'", "''"))' -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', '$timeoutChildEncoded') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText(
    '$($fastOrphanIdentityPath.Replace("'", "''"))',
    "`$(`$child.Id)|`$(`$child.StartTime.ToUniversalTime().ToString('O'))",
    [Text.UTF8Encoding]::new(`$false))
`$child.Dispose()
"@
    $fastOrphanEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($fastOrphanScript))
    $fastOrphanIdentity = $null
    $fastOrphanAudit = $null
    try {
        $fastOrphanEntry = Invoke-RecordedCommand `
            -FileName $pwshPath `
            -Arguments @('-NoLogo', '-NoProfile', '-EncodedCommand', $fastOrphanEncoded) `
            -WorkingDirectory $testRoot `
            -JournalPath (Join-Path $testRoot 'fast-orphan-commands.jsonl') `
            -OutputDirectory (Join-Path $testRoot 'fast-orphan-output') `
            -Label 'fast-orphan-parent' `
            -TimeoutSeconds 10
        Assert-True `
            -Condition (Test-Path -LiteralPath $fastOrphanIdentityPath -PathType Leaf) `
            -Message 'Fast-exit parent publishes its persistent child identity'
        $fastOrphanIdentity =
            (Get-Content -LiteralPath $fastOrphanIdentityPath -Raw).Trim()
        $fastOrphanParts = $fastOrphanIdentity -split '\|', 2
        $matchingCapturedFastOrphans = @(
            foreach ($capturedIdentity in @(
                $fastOrphanEntry.CapturedDescendantIdentities
            )) {
                $capturedParts = [string]$capturedIdentity -split '\|', 2
                if ($capturedParts.Count -eq 2 -and
                    [int]$capturedParts[0] -eq [int]$fastOrphanParts[0] -and
                    [Math]::Abs((
                        (ConvertTo-UtcDateTimeOffset -Value $capturedParts[1]) -
                        (ConvertTo-UtcDateTimeOffset -Value $fastOrphanParts[1])
                    ).TotalSeconds) -lt 1) {
                    $capturedIdentity
                }
            }
        )
        Assert-True `
            -Condition ($matchingCapturedFastOrphans.Count -eq 1) `
            -Message 'Repeated post-exit ancestry capture finds a child after its root exits immediately'
        Assert-True `
            -Condition (Test-VerifiedProcessIdentity `
                -ProcessId ([int]$fastOrphanParts[0]) `
                -ProcessStartUtc $fastOrphanParts[1]) `
            -Message 'Fast-orphan fixture remains live until the strict final registry audit'
        $fastOrphanAudit = Invoke-PhaseOneRegisteredProcessAudit `
            -RegistryPath $fastOrphanRegistryPath `
            -TimeoutSeconds 5
        Assert-True -Condition $fastOrphanAudit.Valid -Message 'Final audit sees and stops the registered fast orphan'
        Assert-True `
            -Condition (-not (Test-VerifiedProcessIdentity `
                -ProcessId ([int]$fastOrphanParts[0]) `
                -ProcessStartUtc $fastOrphanParts[1])) `
            -Message 'Fast orphan does not leak after final audit'
    }
    finally {
        [void](Stop-RegisteredProcessTrees `
            -Entries @(Get-ToolingProcessRegistry) `
            -TimeoutSeconds 5)
        if (-not [string]::IsNullOrWhiteSpace($fastOrphanIdentity)) {
            $fastOrphanParts = $fastOrphanIdentity -split '\|', 2
            if ($fastOrphanParts.Count -eq 2 -and
                (Test-VerifiedProcessIdentity `
                    -ProcessId ([int]$fastOrphanParts[0]) `
                    -ProcessStartUtc $fastOrphanParts[1])) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId ([int]$fastOrphanParts[0]) `
                    -RootProcessStartUtc $fastOrphanParts[1] `
                    -TimeoutSeconds 5)
            }
        }
    }

    $lateScenarioIdentityPath = Join-Path $testRoot 'late-scenario-child.txt'
    $lateScenarioGatePath = Join-Path $testRoot 'late-scenario-spawn.gate'
    $lateScenarioParentScript = @"
while (-not [IO.File]::Exists('$($lateScenarioGatePath.Replace("'", "''"))')) {
    Start-Sleep -Milliseconds 10
}
`$child = Start-Process -FilePath '$($pwshPath.Replace("'", "''"))' -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', '$timeoutChildEncoded') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText(
    '$($lateScenarioIdentityPath.Replace("'", "''"))',
    "`$(`$child.Id)|`$(`$child.StartTime.ToUniversalTime().ToString('O'))",
    [Text.UTF8Encoding]::new(`$false))
`$child.Dispose()
"@
    $lateScenarioParentEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($lateScenarioParentScript))
    $lateScenarioStartInfo = [Diagnostics.ProcessStartInfo]::new($pwshPath)
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-EncodedCommand', $lateScenarioParentEncoded
    )) {
        [void]$lateScenarioStartInfo.ArgumentList.Add($argument)
    }
    $lateScenarioStartInfo.UseShellExecute = $false
    $lateScenarioStartInfo.CreateNoWindow = $true
    $lateScenarioStartInfo.RedirectStandardOutput = $true
    $lateScenarioStartInfo.RedirectStandardError = $true
    $lateScenarioProcess = [Diagnostics.Process]::new()
    $lateScenarioProcess.StartInfo = $lateScenarioStartInfo
    $lateScenarioRun = $null
    $lateScenarioJob = $null
    $lateScenarioChildIdentity = $null
    try {
        $lateScenarioJob =
            New-ScenarioTrackingJob -RunId 'late-descendant-run'
        [void]$lateScenarioProcess.Start()
        Add-ProcessToScenarioTrackingJob `
            -Job $lateScenarioJob `
            -Process $lateScenarioProcess
        $lateScenarioProcessStart =
            ConvertTo-UtcDateTimeOffset -Value $lateScenarioProcess.StartTime
        $lateScenarioRootIdentity =
            "$($lateScenarioProcess.Id)|$($lateScenarioProcessStart.ToString('O'))"
        $lateScenarioJobMembers =
            [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$lateScenarioJobMembers.Add($lateScenarioRootIdentity)
        $lateScenarioRun = [pscustomobject]@{
            RunId = 'late-descendant-run'
            Completed = $false
            Process = $lateScenarioProcess
            RootProcessId = $lateScenarioProcess.Id
            ProcessStartUtc = $lateScenarioProcessStart
            ProcessExitUtc = $null
            ExitCode = $null
            Quiescent = $null
            StdoutTask = $lateScenarioProcess.StandardOutput.ReadToEndAsync()
            StderrTask = $lateScenarioProcess.StandardError.ReadToEndAsync()
            Stdout = Join-Path $testRoot 'late-scenario.stdout.log'
            Stderr = Join-Path $testRoot 'late-scenario.stderr.log'
            DescendantIdentities =
                [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            CoordinatorIdentities =
                [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            JobMemberIdentities = $lateScenarioJobMembers
            CurrentJobProcessIds = [int[]]@($lateScenarioProcess.Id)
            CurrentNonCoordinatorJobProcessIds =
                [int[]]@($lateScenarioProcess.Id)
            CurrentCoordinatorJobProcessIds = [int[]]@()
            TrackingJobRequired = $true
            TrackingJob = $lateScenarioJob
            TrackingJobName = $lateScenarioJob.Name
            TrackingJobClosed = $false
            TrackingJobClosedUtc = $null
            JobMembershipQueryCount = 0
            JobMembershipLastQueryUtc = $null
            JobCensusFailed = $false
            JobCensusErrors = [Collections.Generic.List[string]]::new()
        }
        New-Item -ItemType File -Path $lateScenarioGatePath | Out-Null
        $lateScenarioPublishTimer = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $lateScenarioIdentityPath -PathType Leaf)) {
            if ($lateScenarioPublishTimer.Elapsed.TotalSeconds -gt 10) {
                throw 'Late-descendant scenario fixture did not publish its child identity.'
            }
            Start-Sleep -Milliseconds 25
        }
        $lateScenarioChildIdentity =
            (Get-Content -LiteralPath $lateScenarioIdentityPath -Raw).Trim()
        [void]$lateScenarioProcess.WaitForExit(5000)
        [void](Complete-ExitedScenarioBuild `
            -Run $lateScenarioRun `
            -QuiescenceTimeoutSeconds 2)
        $lateScenarioChildParts = $lateScenarioChildIdentity -split '\|', 2
        $capturedLateScenarioChildren = @(
            foreach ($capturedIdentity in @(
                $lateScenarioRun.DescendantIdentities
            )) {
                $capturedParts = [string]$capturedIdentity -split '\|', 2
                if ($capturedParts.Count -eq 2 -and
                    [int]$capturedParts[0] -eq
                        [int]$lateScenarioChildParts[0] -and
                    [Math]::Abs(((
                        ConvertTo-UtcDateTimeOffset -Value $capturedParts[1]
                    ) - (
                        ConvertTo-UtcDateTimeOffset `
                            -Value $lateScenarioChildParts[1]
                    )).TotalSeconds) -lt 1) {
                    $capturedIdentity
                }
            }
        )
        Assert-True `
            -Condition ($capturedLateScenarioChildren.Count -eq 1) `
            -Message 'Post-exit job census finds the exact persistent child after root ancestry is gone'
        Assert-True `
            -Condition ($lateScenarioRun.JobMembershipQueryCount -gt 0) `
            -Message 'Late-scenario completion queried dedicated job membership after root exit'
        Assert-True `
            -Condition ($lateScenarioRun.Quiescent -eq $false) `
            -Message 'A live late descendant prevents scenario quiescence'
        [void](Stop-UnfinishedScenarioBuilds `
            -Runs @($lateScenarioRun) `
            -TimeoutSeconds 5)
        Assert-True `
            -Condition (-not (Test-VerifiedProcessIdentity `
                -ProcessId ([int]$lateScenarioChildParts[0]) `
                -ProcessStartUtc $lateScenarioChildParts[1])) `
            -Message 'Late scenario descendant is stopped during strict cleanup'
        Assert-True `
            -Condition $lateScenarioRun.TrackingJobClosed `
            -Message 'Late-scenario cleanup closes the exact dedicated job handle'
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($lateScenarioChildIdentity)) {
            $lateScenarioChildParts = $lateScenarioChildIdentity -split '\|', 2
            if ($lateScenarioChildParts.Count -eq 2 -and
                (Test-VerifiedProcessIdentity `
                    -ProcessId ([int]$lateScenarioChildParts[0]) `
                    -ProcessStartUtc $lateScenarioChildParts[1])) {
                [void](Stop-VerifiedProcessTree `
                    -RootProcessId ([int]$lateScenarioChildParts[0]) `
                    -RootProcessStartUtc $lateScenarioChildParts[1] `
                    -TimeoutSeconds 5)
            }
        }
        if ($null -ne $lateScenarioRun -and
            -not $lateScenarioRun.Completed -and
            (Test-VerifiedProcessIdentity `
                -ProcessId $lateScenarioProcess.Id `
                -ProcessStartUtc $lateScenarioRun.ProcessStartUtc)) {
            [void](Stop-VerifiedProcessTree `
                -RootProcessId $lateScenarioProcess.Id `
                -RootProcessStartUtc $lateScenarioRun.ProcessStartUtc `
                -TimeoutSeconds 5)
        }
        if ($null -ne $lateScenarioJob -and -not $lateScenarioJob.IsClosed) {
            Close-ScenarioTrackingJob -Job $lateScenarioJob
        }
        if ($null -ne $lateScenarioProcess) {
            $lateScenarioProcess.Dispose()
        }
    }

    $absentStatus = Get-VerifiedProcessIdentityStatus `
        -ProcessId 2147483646 `
        -ProcessStartUtc ([DateTimeOffset]::UtcNow)
    Assert-Equal -Actual $absentStatus.Status -Expected 'ConfirmedAbsent' -Message 'Missing PID is distinguished as confirmed absent'
    $queryFailureStatus = Get-VerifiedProcessIdentityStatus `
        -ProcessId 42 `
        -ProcessStartUtc ([DateTimeOffset]::UtcNow) `
        -ProcessQuery { param($id) throw [UnauthorizedAccessException]::new("synthetic query failure $id") }
    Assert-Equal -Actual $queryFailureStatus.Status -Expected 'QueryFailed' -Message 'Process query error is not treated as absence'
    $strictQueryThrew = $false
    try {
        [void](Test-VerifiedProcessIdentity `
            -ProcessId 42 `
            -ProcessStartUtc ([DateTimeOffset]::UtcNow) `
            -ProcessQuery { param($id) throw [UnauthorizedAccessException]::new("synthetic query failure $id") })
    }
    catch {
        $strictQueryThrew = $_.Exception.Message -match 'Could not verify PID'
    }
    Assert-True -Condition $strictQueryThrew -Message 'Strict process identity check reports unverifiable queries'
    $queryFailureAudit = Get-PhaseOneProcessCleanupAudit `
        -RegistryEntries @([pscustomobject]@{
            Kind = 'synthetic-query-failure'
            ProcessId = 42
            ProcessStartUtc = [DateTimeOffset]::UtcNow.ToString('O')
            VerifiedStartIdentity = $true
        }) `
        -ProcessQuery { param($id) throw [UnauthorizedAccessException]::new("synthetic query failure $id") }
    Assert-True -Condition (-not $queryFailureAudit.Valid) -Message 'Final audit rejects an unverifiable process query'
    Assert-Equal -Actual $queryFailureAudit.QueryFailureCount -Expected 1 -Message 'Final audit reports the process query failure'

    $throwRegistryPath = Join-Path $testRoot 'helper-throw-process-registry.jsonl'
    [void](Initialize-ToolingProcessRegistry -Path $throwRegistryPath -Reset)
    & {
        [void](Register-ProcessIdentity `
            -ProcessId 2147483645 `
            -ProcessStartUtc ([DateTimeOffset]'2026-08-12T00:00:00Z') `
            -Kind 'child-scope-registry-probe' `
            -Source $testRoot)
    }
    Assert-Equal -Actual @(Get-ToolingProcessRegistry).Count -Expected 1 -Message 'Shared process registry survives child script scopes'
    $helperThrowProcess = $null
    $helperThrowObserved = $false
    try {
        $helperThrowProcess = Start-TestPowerShellProcess -Script 'Start-Sleep -Seconds 120'
        $helperThrowStart =
            ConvertTo-UtcDateTimeOffset -Value $helperThrowProcess.StartTime
        [void](Register-ProcessIdentity `
            -ProcessId $helperThrowProcess.Id `
            -ProcessStartUtc $helperThrowStart `
            -Kind 'synthetic-helper-throw' `
            -Source $testRoot)
        throw 'SYNTHETIC_HELPER_THROW_AFTER_START'
    }
    catch {
        $helperThrowObserved =
            $_.Exception.Message -eq 'SYNTHETIC_HELPER_THROW_AFTER_START'
    }
    finally {
        $helperThrowEntries = @(Get-ToolingProcessRegistry)
        $helperThrowStop = Stop-RegisteredProcessTrees `
            -Entries $helperThrowEntries `
            -TimeoutSeconds 5
        $helperThrowAudit = Get-PhaseOneProcessCleanupAudit `
            -RegistryEntries $helperThrowEntries
        if ($null -ne $helperThrowProcess) {
            $helperThrowProcess.Dispose()
        }
    }
    Assert-True -Condition $helperThrowObserved -Message 'Synthetic helper throws after starting its child'
    Assert-Equal -Actual $helperThrowEntries.Count -Expected 2 -Message 'Shared registry captures a start before helper return'
    Assert-True -Condition $helperThrowStop.Succeeded -Message 'Outer cleanup stops a process registered before helper failure'
    Assert-True -Condition $helperThrowAudit.Valid -Message 'Final audit proves helper-throw process absence'
    Assert-True -Condition (Test-Path -LiteralPath $throwRegistryPath -PathType Leaf) -Message 'Component failure retains the shared process-registry path'

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
        foreach ($run in $runs) {
            $rootState = @($trace.RootStates | Where-Object RunId -eq $run.RunId)
            Assert-Equal -Actual $rootState.Count -Expected 1 -Message "$name fixture maps $($run.RunId) to one strict trace root"
            Assert-Equal -Actual $rootState[0].RequestedNodes -Expected $run.RequestedNodes -Message "$name fixture records requested nodes for $($run.RunId)"
            Assert-Equal -Actual $rootState[0].GrantedNodes -Expected $run.GrantedNodes -Message "$name fixture records granted nodes for $($run.RunId)"
        }
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
    Write-JsonAtomic `
        -Path (Join-Path $monitorRoot 'preserved-monitor-provenance.json') `
        -Value ([pscustomobject]@{
            SampleIntervalSeconds = 1
            ProcessIntervalSeconds = 5
            ProbeIntervalSeconds = 5
        })
    $continuity = Test-TelemetryContinuity -MonitorRoot $monitorRoot
    Assert-True -Condition $continuity.Valid -Message 'Telemetry fixture below hard limits is valid'
    Assert-Equal -Actual $continuity.Statistics.system.WarningCount -Expected 1 -Message 'Five-second system warning gap is counted'
    $boundaryContinuity = Test-TelemetryContinuity `
        -MonitorRoot $monitorRoot `
        -ReadyUtc ([DateTimeOffset]'2026-08-12T05:00:00Z') `
        -StopUtc ([DateTimeOffset]'2026-08-12T05:00:20Z')
    Assert-True -Condition $boundaryContinuity.Valid -Message 'Telemetry tail exactly on the 15-second process/probe boundary is valid'
    Assert-Equal -Actual $boundaryContinuity.Statistics.system.ExpectedSampleIntervalSeconds -Expected 1 -Message 'System telemetry records the required one-second sample interval'
    Assert-Equal -Actual $boundaryContinuity.Statistics.process.ExpectedSampleIntervalSeconds -Expected 5 -Message 'Process telemetry records the required five-second sample interval'
    Assert-Equal -Actual $boundaryContinuity.Statistics.probe.ExpectedSampleIntervalSeconds -Expected 5 -Message 'Probe telemetry records the required five-second sample interval'
    $stalledTailContinuity = Test-TelemetryContinuity `
        -MonitorRoot $monitorRoot `
        -ReadyUtc ([DateTimeOffset]'2026-08-12T05:00:00Z') `
        -StopUtc ([DateTimeOffset]'2026-08-12T05:00:20.001Z')
    Assert-True -Condition (-not $stalledTailContinuity.Valid) -Message 'Telemetry tail beyond the hard 15-second boundary is rejected'
    Assert-True `
        -Condition (@($stalledTailContinuity.Errors | Where-Object { $_ -match 'last-sample-to-stop gap' }).Count -ge 2) `
        -Message 'Stalled process and probe tails identify their boundary gaps'
    Add-Content `
        -LiteralPath (Join-Path $monitorRoot 'system.csv') `
        -Value '2026-08-12T05:00:04Z,1'
    $nonmonotonicContinuity = Test-TelemetryContinuity -MonitorRoot $monitorRoot
    Assert-True -Condition (-not $nonmonotonicContinuity.Valid) -Message 'Nonmonotonic telemetry timestamps are rejected'
    Assert-True `
        -Condition (@($nonmonotonicContinuity.Errors | Where-Object { $_ -match 'not monotonic' }).Count -eq 1) `
        -Message 'Nonmonotonic telemetry failure is explicit'
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

    $lifecycleEvents = [Collections.Generic.List[object]]::new()
    $lifecycleTimestamp = [DateTimeOffset]'2026-08-12T04:00:00Z'
    $addLifecycleFixtureEvent = {
        param(
            [string]$Name,
            [AllowNull()][string]$RunId,
            [AllowNull()][object]$Worker,
            [hashtable]$Data = @{}
        )
        $entry = [ordered]@{
            TimestampUtc = $lifecycleTimestamp.ToString('O')
            Event = $Name
            RunId = $RunId
            Worker = $Worker
        }
        foreach ($item in $Data.GetEnumerator()) {
            $entry[$item.Key] = $item.Value
        }
        $lifecycleEvents.Add([pscustomobject]$entry)
        $lifecycleTimestamp = $lifecycleTimestamp.AddMilliseconds(1)
    }
    $lifecycleActive = @{}
    foreach ($worker in 1..18) {
        $runId = "normal$worker-g1"
        $lifecycleActive[$worker] = $runId
        . $addLifecycleFixtureEvent -Name Launched -RunId $runId -Worker $worker
    }
    . $addLifecycleFixtureEvent -Name SteadyOnset -RunId $null -Worker $null
    . $addLifecycleFixtureEvent -Name Completed -RunId 'normal1-g1' -Worker 1 -Data @{
        ExitCode = 0
        Quiescent = $true
    }
    [void]$lifecycleActive.Remove(1)
    . $addLifecycleFixtureEvent -Name MeasuredCompletion -RunId 'normal1-g1' -Worker 1 -Data @{
        CompletionNumber = 1
    }
    . $addLifecycleFixtureEvent -Name Injected -RunId 'injected-g1' -Worker 0 -Data @{
        AfterMeasuredCompletion = 1
    }
    . $addLifecycleFixtureEvent -Name ReplacementLaunched -RunId 'normal1-g2' -Worker 1 -Data @{
        ReplacedRunId = 'normal1-g1'
    }
    $lifecycleActive[1] = 'normal1-g2'
    . $addLifecycleFixtureEvent -Name Completed -RunId 'normal2-g1' -Worker 2 -Data @{
        ExitCode = 0
        Quiescent = $true
    }
    [void]$lifecycleActive.Remove(2)
    . $addLifecycleFixtureEvent -Name MeasuredCompletion -RunId 'normal2-g1' -Worker 2 -Data @{
        CompletionNumber = 2
    }
    . $addLifecycleFixtureEvent -Name SteadyEnd -RunId 'normal2-g1' -Worker 2 -Data @{
        MeasuredCompletions = 2
        StopReplacement = $true
    }
    . $addLifecycleFixtureEvent -Name DrainStarted -RunId $null -Worker $null -Data @{
        ReplacementsStopped = $true
    }
    foreach ($worker in @($lifecycleActive.Keys | Sort-Object)) {
        $runId = [string]$lifecycleActive[$worker]
        . $addLifecycleFixtureEvent -Name Completed -RunId $runId -Worker $worker -Data @{
            ExitCode = 0
            Quiescent = $true
            DuringDrain = $true
        }
        [void]$lifecycleActive.Remove($worker)
    }
    . $addLifecycleFixtureEvent -Name Completed -RunId 'injected-g1' -Worker 0 -Data @{
        ExitCode = 0
        Quiescent = $true
        DuringDrain = $true
    }
    . $addLifecycleFixtureEvent -Name Drained -RunId $null -Worker $null -Data @{
        FinalActiveWorkers = 0
        FinalQueueDepth = 0
        FinalActiveBuilds = 0
        FinalAllocatedNodes = 0
    }

    $lifecycleRuns = [Collections.Generic.List[object]]::new()
    $lifecycleBaseTime = [DateTimeOffset]'2026-08-12T04:00:00Z'
    foreach ($worker in 1..18) {
        $exit = if ($worker -le 2) {
            $lifecycleBaseTime.AddSeconds(5).AddMilliseconds($worker)
        }
        else {
            $lifecycleBaseTime.AddSeconds(10).AddMilliseconds($worker)
        }
        $lifecycleRuns.Add([pscustomobject]@{
            RunId = "normal$worker-g1"
            Kind = 'normal'
            Worker = $worker
            Generation = 1
            Priority = 'Normal'
            Worktree = Join-Path $testRoot "phase-one-lifecycle\worktrees\normal$worker"
            RootProcessId = 3000 + $worker
            ProcessStartUtc = $lifecycleBaseTime.AddMilliseconds($worker).ToString('O')
            ProcessExitUtc = $exit.ToString('O')
            ExitCode = 0
            Quiescent = $true
            Binlog = Join-Path $testRoot "phase-one-lifecycle\runs\normal$worker-g1.binlog"
            Command = [pscustomobject]@{ Arguments = @('/m:16', '/nodeReuse:false') }
        })
    }
    $lifecycleRuns.Add([pscustomobject]@{
        RunId = 'normal1-g2'
        Kind = 'normal'
        Worker = 1
        Generation = 2
        Priority = 'Normal'
        Worktree = Join-Path $testRoot 'phase-one-lifecycle\worktrees\normal1'
        RootProcessId = 4001
        ProcessStartUtc = $lifecycleBaseTime.AddSeconds(6).ToString('O')
        ProcessExitUtc = $lifecycleBaseTime.AddSeconds(8).ToString('O')
        ExitCode = 0
        Quiescent = $true
        Binlog = Join-Path $testRoot 'phase-one-lifecycle\runs\normal1-g2.binlog'
        Command = [pscustomobject]@{ Arguments = @('/m:16', '/nodeReuse:false') }
    })
    $lifecycleRuns.Add([pscustomobject]@{
        RunId = 'injected-g1'
        Kind = 'injected'
        Worker = 0
        Generation = 1
        Priority = 'High'
        Worktree = Join-Path $testRoot 'phase-one-lifecycle\worktrees\injected'
        RootProcessId = 5000
        ProcessStartUtc = $lifecycleBaseTime.AddSeconds(5.5).ToString('O')
        ProcessExitUtc = $lifecycleBaseTime.AddSeconds(7).ToString('O')
        ExitCode = 0
        Quiescent = $true
        Binlog = Join-Path $testRoot 'phase-one-lifecycle\runs\injected-g1.binlog'
        Command = [pscustomobject]@{ Arguments = @('/m:16', '/nodeReuse:false') }
    })
    $lifecycleReplays = @(
        $lifecycleRuns |
            ForEach-Object {
                [pscustomobject]@{
                    Path = $_.Binlog
                    Grants = @([pscustomobject]@{ Nodes = 8 })
                }
            }
    )
    $lifecycleTrace = [pscustomobject]@{
        Consistent = $true
        Errors = @()
        DeferredGrantOccurred = $true
        FinalQueueDepth = 0
        FinalActiveBuilds = 0
        FinalAllocatedNodes = 0
        Timeline = @(
            [pscustomobject]@{ QueueDepth = 0 },
            [pscustomobject]@{ QueueDepth = 16 },
            [pscustomobject]@{ QueueDepth = 0 }
        )
        Events = @([pscustomobject]@{ Event = 'Accept' })
        RootStates = @($lifecycleRuns | ForEach-Object {
            $traceStart = ConvertTo-UtcDateTimeOffset -Value $_.ProcessStartUtc
            [pscustomobject]@{
                IdentityKey = "$($_.RootProcessId)|$($traceStart.UtcTicks)"
                RunId = $_.RunId
                ProcessId = $_.RootProcessId
                RequestedNodes = 16
                GrantedNodes = 8
            }
        })
    }
    $lifecycleContract = Test-PhaseOneControllerLifecycleContract `
        -Events $lifecycleEvents.ToArray() `
        -Runs $lifecycleRuns.ToArray() `
        -Replays $lifecycleReplays `
        -Trace $lifecycleTrace `
        -InitialWorkers 18 `
        -InjectionCompletion 1 `
        -EndingCompletion 2
    Assert-True -Condition $lifecycleContract.Valid -Message 'Abbreviated real-lifecycle evidence contract accepts exact launch/replacement/injection/end/drain semantics'
    Assert-Equal -Actual $lifecycleContract.InitialLaunchCount -Expected 18 -Message 'Lifecycle contract requires exactly 18 initial launches'
    Assert-Equal -Actual $lifecycleContract.ReplacementCount -Expected 1 -Message 'Lifecycle contract records a post-quiescence replacement'
    Assert-Equal -Actual $lifecycleContract.ActiveWorkersAtEnd -Expected 0 -Message 'Lifecycle contract requires a complete Normal-worker drain'
    Assert-Equal -Actual $lifecycleContract.ValidatedGrantRunCount -Expected $lifecycleRuns.Count -Message 'Lifecycle contract binds every run, including injection, to replay and trace grants'
    $mismatchedLifecycleReplays = @(
        $lifecycleRuns |
            ForEach-Object {
                [pscustomobject]@{
                    Path = $_.Binlog
                    Grants = @([pscustomobject]@{
                        Nodes = if ($_.RunId -eq 'injected-g1') { 4 } else { 8 }
                    })
                }
            }
    )
    $mismatchedGrantContract = Test-PhaseOneControllerLifecycleContract `
        -Events $lifecycleEvents.ToArray() `
        -Runs $lifecycleRuns.ToArray() `
        -Replays $mismatchedLifecycleReplays `
        -Trace $lifecycleTrace `
        -InitialWorkers 18 `
        -InjectionCompletion 1 `
        -EndingCompletion 2
    Assert-True -Condition (-not $mismatchedGrantContract.Valid) -Message 'Lifecycle contract rejects a replay/trace grant mismatch'
    Assert-True `
        -Condition (@($mismatchedGrantContract.Errors | Where-Object { $_ -match "injected-g1.*replay grant 4.*trace grant 8" }).Count -eq 1) `
        -Message 'Mismatched injected grant rejection identifies replay and trace values'
    $lateReplacementLifecycleEvents = [Collections.Generic.List[object]]::new()
    $lateReplacementLifecycleEvents.AddRange([object[]]$lifecycleEvents.ToArray())
    $drainStartIndex = 0
    while ($lateReplacementLifecycleEvents[$drainStartIndex].Event -ne 'DrainStarted') {
        $drainStartIndex++
    }
    $lateReplacementLifecycleEvents.Insert($drainStartIndex, [pscustomobject]@{
        TimestampUtc = $lateReplacementLifecycleEvents[$drainStartIndex].TimestampUtc
        Event = 'ReplacementLaunched'
        RunId = 'normal2-g2-late'
        Worker = 2
        ReplacedRunId = 'normal2-g1'
    })
    $lateReplacementContract = Test-PhaseOneControllerLifecycleContract `
        -Events $lateReplacementLifecycleEvents.ToArray() `
        -Runs $lifecycleRuns.ToArray() `
        -Replays $lifecycleReplays `
        -Trace $lifecycleTrace `
        -InitialWorkers 18 `
        -InjectionCompletion 1 `
        -EndingCompletion 2
    Assert-True -Condition (-not $lateReplacementContract.Valid) -Message 'Lifecycle contract rejects replacement after the stop/end marker'

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
        ReviewFindingsCovered = 13
        ControllerInvalidFixtures = 2
        PreparationWorktreesValidated = 19
        ControllerMeasuredCompletions = $controllerValidation.MeasuredCompletionCount
        PhaseOneInitialWorkers = $lifecycleContract.InitialLaunchCount
        PhaseOneRetryAttemptsValidated = $retryAttempt2.Number
        PhaseOneDuplicateRefusalValidated = $true
        ResampleIterations = $estimate1.ResampleIterations
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        Write-JsonAtomic -Path $ResultPath -Value $testResult
    }
    $testResult | ConvertTo-Json
}
finally {
    if ($null -eq $savedRegistryVariable) {
        Remove-Variable `
            -Name CurrentVsFinalToolingProcessRegistry `
            -Scope Global `
            -Force `
            -ErrorAction SilentlyContinue
    }
    else {
        $restoredRegistry = [Collections.Generic.List[object]]::new()
        foreach ($entry in $savedRegistryEntries) {
            $restoredRegistry.Add($entry)
        }
        $global:CurrentVsFinalToolingProcessRegistry = $restoredRegistry
    }
    if ($null -eq $savedRegistryKeysVariable) {
        Remove-Variable `
            -Name CurrentVsFinalToolingProcessRegistryKeys `
            -Scope Global `
            -Force `
            -ErrorAction SilentlyContinue
    }
    else {
        $restoredRegistryKeys =
            [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($key in $savedRegistryKeys) {
            [void]$restoredRegistryKeys.Add([string]$key)
        }
        $global:CurrentVsFinalToolingProcessRegistryKeys = $restoredRegistryKeys
    }
    if ($null -eq $savedRegistryPathVariable) {
        Remove-Variable `
            -Name CurrentVsFinalToolingProcessRegistryPath `
            -Scope Global `
            -Force `
            -ErrorAction SilentlyContinue
    }
    else {
        $global:CurrentVsFinalToolingProcessRegistryPath = $savedRegistryPath
    }
    if (-not $KeepOutput) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
