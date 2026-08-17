[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$PreparationPath,
    [Parameter(Mandatory)]
    [ValidateSet('roslyn', 'aspire')]
    [string]$RepositoryName,
    [Parameter(Mandatory)]
    [ValidateSet(8, 10)]
    [int]$WorkerCount,
    [Parameter(Mandatory)]
    [string]$Reason,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [switch]$AllowContentHashDrift
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
Assert-WindowsCampaignHost

$campaign = Get-CampaignDefinition
$repositoryDefinition = Get-RepositoryDefinition -Name $RepositoryName
$preparation =
    Get-Content -LiteralPath $PreparationPath -Raw |
    ConvertFrom-Json
$preparedRepository = $preparation.Repositories |
    Where-Object Name -eq $RepositoryName |
    Select-Object -First 1
if ($null -eq $preparedRepository) {
    throw "Preparation metadata does not contain '$RepositoryName'."
}
$identityRecord =
    Get-Content -LiteralPath $BootstrapIdentityPath -Raw |
    ConvertFrom-Json
$base = Get-BootstrapIdentity `
    -Role base `
    -Root $identityRecord.Base.Root `
    -ExpectedCommit $campaign.Base.Commit
$final = Get-BootstrapIdentity `
    -Role final `
    -Root $identityRecord.Final.Root `
    -ExpectedCommit $campaign.Final.Commit
$worktreeNames = @(
    Get-SustainedSelectedWorktreeNames -WorkerCount $WorkerCount
)
$worktrees = @(
    foreach ($name in $worktreeNames) {
        $worktree = $preparedRepository.Worktrees |
            Where-Object Name -eq $name |
            Select-Object -First 1
        if ($null -eq $worktree -or
            $null -eq $worktree.BaselineOutputIdentity) {
            throw "Prepared worktree '$name' or its baseline is missing for '$RepositoryName'."
        }
        [pscustomobject]@{
            Name = $name
            Path = [IO.Path]::GetFullPath([string]$worktree.Path)
            BaselineOutputIdentity = $worktree.BaselineOutputIdentity
        }
    }
)

$completionPath = Join-Path $OutputRoot 'reset-completion.json'
if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    $existing =
        Get-Content -LiteralPath $completionPath -Raw |
        ConvertFrom-Json
    if ($existing.PreparationSha256 -ne
            (Get-FileHash -LiteralPath $PreparationPath -Algorithm SHA256).Hash -or
        [int]$existing.WorkerCount -ne $WorkerCount -or
        -not [bool]$existing.BaselineRestored) {
        throw "Existing reset checkpoint '$completionPath' is invalid."
    }
    foreach ($worktree in $worktrees) {
        [void](Get-GitIdentity `
            -Root $worktree.Path `
            -ExpectedCommit $repositoryDefinition.Commit `
            -RequireClean)
        $tracked = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('-C', $worktree.Path, 'ls-files') `
                -WorkingDirectory $worktree.Path
        )
        $current = Get-ProjectOutputContentIdentity `
            -Worktree $worktree.Path `
            -TrackedRelativePaths $tracked
        $recorded = $existing.AffectedWorktrees |
            Where-Object Name -eq $worktree.Name |
            Select-Object -First 1
        if ($null -eq $recorded -or
            -not $recorded.BaselineMatched -or
            (-not $AllowContentHashDrift -and
                $current.ContentSha256 -ne
                    $recorded.RestoredBaselineOutputIdentity.ContentSha256) -or
            [int]$current.FileCount -ne
                [int]$recorded.RestoredBaselineOutputIdentity.FileCount -or
            [int64]$current.TotalBytes -ne
                [int64]$recorded.RestoredBaselineOutputIdentity.TotalBytes) {
            throw "Existing reset checkpoint no longer matches '$RepositoryName/$($worktree.Name)'."
        }
    }
    Write-Host "RESET_COMPLETION=$completionPath"
    return
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$journal = Join-Path $OutputRoot 'commands.jsonl'
$commandOutput = Join-Path $OutputRoot 'command-output'
Invoke-BuildServerShutdown `
    -Bootstraps @($base, $final) `
    -JournalPath $journal `
    -OutputDirectory $commandOutput
Wait-ForMachineIdle `
    -RecordPath (Join-Path $OutputRoot 'pre-reset-idle-gate.json') `
    -MinimumAvailableMB 16384

$activeConflicts = @(
    Get-CimInstance Win32_Process |
        ForEach-Object {
            $processRecord = $_
            $referencesWorktree =
                -not [string]::IsNullOrWhiteSpace(
                    [string]$processRecord.CommandLine) -and
                @(
                    $worktrees |
                        Where-Object {
                            ([string]$processRecord.CommandLine).Contains(
                                $_.Path,
                                [StringComparison]::OrdinalIgnoreCase)
                        }
                ).Count -gt 0
            if ([int]$processRecord.ProcessId -ne $PID -and
                $referencesWorktree) {
                $processRecord
            }
        } |
        Select-Object ProcessId,ParentProcessId,CreationDate,Name,CommandLine
)
if ($activeConflicts.Count -gt 0) {
    throw "Refusing reset because $($activeConflicts.Count) process(es) still reference selected worktrees."
}

$environment = @{
    DOTNET_ROOT = $final.Root
    DOTNET_ROOT_X64 = $final.Root
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    PATH = "$($final.Root)$([IO.Path]::PathSeparator)$([Environment]::GetEnvironmentVariable('PATH', 'Process'))"
}
foreach ($variable in Get-CoordinatorEnvironmentVariableNames) {
    $environment[$variable] = $null
}
$records = [Collections.Generic.List[object]]::new()
foreach ($worktree in $worktrees) {
    [void](Get-GitIdentity `
        -Root $worktree.Path `
        -ExpectedCommit $repositoryDefinition.Commit `
        -RequireClean)
    $tracked = @(
        Get-NativeOutput `
            -FileName git `
            -Arguments @('-C', $worktree.Path, 'ls-files') `
            -WorkingDirectory $worktree.Path
    )
    $plan = Get-ProjectOutputResetPlan `
        -Worktree $worktree.Path `
        -TrackedRelativePaths $tracked
    if (-not $plan.Valid) {
        throw "Unsafe output reset under '$($worktree.Path)': $(@($plan.UnsafeCandidates.RelativePath) -join ', ')"
    }
    $removed = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $plan.SafeCandidates) {
        $bytes = [int64](
            Get-ChildItem `
                -LiteralPath $candidate.FullPath `
                -Recurse `
                -File `
                -Force |
            Measure-Object Length -Sum).Sum
        Remove-Item -LiteralPath $candidate.FullPath -Recurse -Force
        $removed.Add([pscustomobject][ordered]@{
            RelativePath = $candidate.RelativePath
            Bytes = $bytes
        })
    }
    $restoreArguments = New-BuildArguments `
        -MSBuildDllPath $final.MSBuildDllPath `
        -BuildPath $repositoryDefinition.BuildPath `
        -Restore `
        -AdditionalArguments $repositoryDefinition.AdditionalBuildArguments
    [void](Invoke-RecordedCommand `
        -FileName $final.DotNetPath `
        -Arguments $restoreArguments `
        -WorkingDirectory $worktree.Path `
        -JournalPath $journal `
        -OutputDirectory $commandOutput `
        -Label "restore-reset-$RepositoryName-$($worktree.Name)" `
        -Environment $environment)
    $warmArguments = New-BuildArguments `
        -MSBuildDllPath $final.MSBuildDllPath `
        -BuildPath $repositoryDefinition.BuildPath `
        -AdditionalArguments $repositoryDefinition.AdditionalBuildArguments
    [void](Invoke-RecordedCommand `
        -FileName $final.DotNetPath `
        -Arguments $warmArguments `
        -WorkingDirectory $worktree.Path `
        -JournalPath $journal `
        -OutputDirectory $commandOutput `
        -Label "warm-reset-$RepositoryName-$($worktree.Name)" `
        -Environment $environment)
    $git = Get-GitIdentity `
        -Root $worktree.Path `
        -ExpectedCommit $repositoryDefinition.Commit `
        -RequireClean
    $current = Get-ProjectOutputContentIdentity `
        -Worktree $worktree.Path `
        -TrackedRelativePaths $tracked
    $expected = $worktree.BaselineOutputIdentity
    $contentHashMatched =
        $current.ContentSha256 -eq $expected.ContentSha256
    if ((-not $AllowContentHashDrift -and -not $contentHashMatched) -or
        [int]$current.FileCount -ne [int]$expected.FileCount -or
        [int64]$current.TotalBytes -ne [int64]$expected.TotalBytes) {
        throw "Restored '$RepositoryName/$($worktree.Name)' does not match its prepared baseline."
    }
    $records.Add([pscustomobject][ordered]@{
        Name = $worktree.Name
        Path = $worktree.Path
        RemovedOutputDirectories = $removed.ToArray()
        Git = $git
        RestoredBaselineOutputIdentity = $current
        BaselineMatched = $true
        BaselineContentHashMatched = $contentHashMatched
        ContentHashDriftAllowed = [bool]$AllowContentHashDrift
        Retouched = $false
    })
}
Invoke-BuildServerShutdown `
    -Bootstraps @($base, $final) `
    -JournalPath $journal `
    -OutputDirectory $commandOutput
$record = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Repository = $RepositoryName
    RepositoryCommit = $repositoryDefinition.Commit
    WorkerCount = $WorkerCount
    Reason = $Reason
    PreparationPath = [IO.Path]::GetFullPath($PreparationPath)
    PreparationSha256 =
        (Get-FileHash -LiteralPath $PreparationPath -Algorithm SHA256).Hash
    AffectedWorktrees = $records.ToArray()
    NoOverlap = $true
    BaselineRestored = $true
    BaselineShapeRestored = $true
    ContentHashDriftAllowed = [bool]$AllowContentHashDrift
    UsedGitClean = $false
    RetouchOccursOnlyInsideScenario = $true
}
Write-JsonAtomic -Path $completionPath -Value $record -Depth 12
Write-Host "RESET_COMPLETION=$completionPath"
