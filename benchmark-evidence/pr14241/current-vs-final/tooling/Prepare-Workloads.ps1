[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [string[]]$RepositoryNames = @('roslyn', 'aspire'),
    [switch]$SkipWarm
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
Assert-WindowsCampaignHost

function Get-DirectorySizeBytes {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    [int64](
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
            Measure-Object Length -Sum
    ).Sum
}

$definition = Get-CampaignDefinition
$journal = Join-Path $OutputRoot 'commands.jsonl'
$commandOutput = Join-Path $OutputRoot 'command-output'
$completionPath = Join-Path $OutputRoot 'preparation-completion.json'
if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    Write-Host "PREPARATION_COMPLETION=$completionPath"
    return
}

$identityRecord = Get-Content -LiteralPath $BootstrapIdentityPath -Raw | ConvertFrom-Json
$base = Get-BootstrapIdentity -Role base -Root $identityRecord.Base.Root -ExpectedCommit $definition.Base.Commit
$final = Get-BootstrapIdentity -Role final -Root $identityRecord.Final.Root -ExpectedCommit $definition.Final.Commit
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$prepared = [Collections.Generic.List[object]]::new()
foreach ($name in $RepositoryNames) {
    $repository = Get-RepositoryDefinition -Name $name
    Assert-FreeDiskSpace `
        -Path $repository.WorkRoot `
        -MinimumGiB $definition.Validity.InitialDiskSafetyGiB `
        -RecordPath (Join-Path $OutputRoot "disk-before-$name.json") | Out-Null
    $repositoryIdentity = Get-GitIdentity `
        -Root $repository.Root `
        -ExpectedCommit $repository.Commit `
        -RequireClean
    $remoteIdentity = Get-GitRemoteIdentity `
        -Root $repository.Root `
        -RemoteName origin `
        -ExpectedUrl $repository.Repository
    $repositoryIdentity | Add-Member -NotePropertyName Remote -NotePropertyValue $remoteIdentity
    if (-not (Test-Path -LiteralPath (Join-Path $repository.Root $repository.BuildPath) -PathType Leaf)) {
        throw "$name build path '$($repository.BuildPath)' is missing."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repository.Root $repository.TouchPath) -PathType Leaf)) {
        throw "$name touch path '$($repository.TouchPath)' is missing."
    }

    New-Item -ItemType Directory -Force -Path $repository.WorkRoot | Out-Null
    $worktrees = [Collections.Generic.List[object]]::new()
    $worktreeNames = @((1..18 | ForEach-Object { "normal$_" }) + @('injected'))
    $desiredWorktreePaths = @($worktreeNames | ForEach-Object {
        [IO.Path]::GetFullPath((Join-Path $repository.WorkRoot $_))
    })
    $registeredWorktreePaths = @(
        Get-NativeOutput `
            -FileName git `
            -Arguments @('-C', $repository.Root, 'worktree', 'list', '--porcelain') `
            -WorkingDirectory $repository.Root |
            Where-Object { $_.StartsWith('worktree ', [StringComparison]::Ordinal) } |
            ForEach-Object { [IO.Path]::GetFullPath($_.Substring('worktree '.Length)) }
    )
    $sourceRootPath = [IO.Path]::GetFullPath($repository.Root)
    $otherRegisteredWorktrees = @(
        $registeredWorktreePaths |
            Where-Object {
                -not $_.Equals($sourceRootPath, [StringComparison]::OrdinalIgnoreCase) -and
                    $desiredWorktreePaths -notcontains $_
            }
    )
    if ($otherRegisteredWorktrees.Count -gt 0) {
        throw "$name has $($otherRegisteredWorktrees.Count) registered worktree(s) outside this campaign. Remove them before creating the strict maximum of 19: $($otherRegisteredWorktrees -join ', ')"
    }
    if (@($registeredWorktreePaths | Where-Object {
        -not $_.Equals($sourceRootPath, [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 19) {
        throw "$name already exceeds the maximum of 19 detached benchmark worktrees."
    }

    $preparationEnvironment = @{
        DOTNET_ROOT = $final.Root
        DOTNET_ROOT_X64 = $final.Root
        DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        PATH = "$($final.Root)$([IO.Path]::PathSeparator)$([Environment]::GetEnvironmentVariable('PATH', 'Process'))"
    }
    foreach ($variable in Get-CoordinatorEnvironmentVariableNames) {
        $preparationEnvironment[$variable] = $null
    }

    function Add-ProjectWorktree {
        param([string]$WorktreeName)

        $worktreePath = Join-Path $repository.WorkRoot $worktreeName
        if (-not (Test-Path -LiteralPath $worktreePath -PathType Container)) {
            [void](Invoke-RecordedCommand `
                -FileName git `
                -Arguments @('-C', $repository.Root, 'worktree', 'add', '--detach', $worktreePath, $repository.Commit) `
                -WorkingDirectory $repository.Root `
                -JournalPath $journal `
                -OutputDirectory $commandOutput `
                -Label "worktree-$name-$worktreeName")
        }
        return $worktreePath
    }

    function Invoke-ProjectRestoreAndWarm {
        param(
            [string]$WorktreeName,
            [string]$WorktreePath
        )

        [void](Get-GitIdentity `
            -Root $WorktreePath `
            -ExpectedCommit $repository.Commit `
            -RequireClean)
        $trackedFiles = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('-C', $WorktreePath, 'ls-files') `
                -WorkingDirectory $WorktreePath
        )
        $outputResetPlan = Get-ProjectOutputResetPlan `
            -Worktree $WorktreePath `
            -TrackedRelativePaths $trackedFiles
        if (-not $outputResetPlan.Valid) {
            throw "Unsafe initial project-output candidate(s) under '$WorktreePath' contain tracked files."
        }
        foreach ($candidate in $outputResetPlan.SafeCandidates) {
            Remove-Item -LiteralPath $candidate.FullPath -Recurse -Force
            Add-CommandJournalEntry -JournalPath $journal -Entry ([pscustomobject][ordered]@{
                Label = "remove-initial-project-output-$name-$WorktreeName-$($candidate.RelativePath)"
                StartedUtc = [DateTime]::UtcNow.ToString('O')
                CompletedUtc = [DateTime]::UtcNow.ToString('O')
                Operation = 'Remove-Item'
                Path = $candidate.FullPath
                ExitCode = 0
            })
        }
        $untracked = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('-C', $WorktreePath, 'status', '--porcelain=v1', '--untracked-files=all', '--ignored') `
                -WorkingDirectory $WorktreePath |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($untracked.Count -gt 0) {
            throw "Worktree '$WorktreePath' contains untracked source state outside the explicit output reset plan."
        }
        $restoreArguments = New-BuildArguments `
            -MSBuildDllPath $final.MSBuildDllPath `
            -BuildPath $repository.BuildPath `
            -Restore `
            -AdditionalArguments $repository.AdditionalBuildArguments
        [void](Invoke-RecordedCommand `
            -FileName $final.DotNetPath `
            -Arguments $restoreArguments `
            -WorkingDirectory $WorktreePath `
            -JournalPath $journal `
            -OutputDirectory $commandOutput `
            -Label "restore-$name-$WorktreeName" `
            -Environment $preparationEnvironment)
        if (-not $SkipWarm) {
            $warmArguments = New-BuildArguments `
                -MSBuildDllPath $final.MSBuildDllPath `
                -BuildPath $repository.BuildPath `
                -AdditionalArguments $repository.AdditionalBuildArguments
            [void](Invoke-RecordedCommand `
                -FileName $final.DotNetPath `
                -Arguments $warmArguments `
                -WorkingDirectory $WorktreePath `
                -JournalPath $journal `
                -OutputDirectory $commandOutput `
                -Label "warm-$name-$WorktreeName" `
                -Environment $preparationEnvironment)
        }
        [void](Get-GitIdentity `
            -Root $WorktreePath `
            -ExpectedCommit $repository.Commit `
            -RequireClean)
    }

    $firstWorktreePath = Add-ProjectWorktree -WorktreeName 'normal1'
    Invoke-ProjectRestoreAndWarm -WorktreeName 'normal1' -WorktreePath $firstWorktreePath
    $firstWorktreeBytes = Get-DirectorySizeBytes -Path $firstWorktreePath
    if ($firstWorktreeBytes -le 0) {
        throw "$name first prepared project worktree has no measurable files."
    }
    $existingDesiredCount = @(
        $desiredWorktreePaths |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    ).Count
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($repository.WorkRoot)))
    $diskProjection = Get-MeasuredWorktreeDiskProjection `
        -Repository $name `
        -FirstRestoredWarmWorktreeBytes $firstWorktreeBytes `
        -ExistingCampaignWorktreeCount $existingDesiredCount `
        -AvailableBytesBeforeExpansion $drive.AvailableFreeSpace `
        -RawResultsReserveGiB $definition.Validity.RawResultsReserveGiB
    $diskProjection | Add-Member -NotePropertyName BuildPath -NotePropertyValue $repository.BuildPath
    $diskProjection | Add-Member -NotePropertyName FirstRestoredWarmWorktree -NotePropertyValue $firstWorktreePath
    Write-JsonAtomic -Path (Join-Path $OutputRoot "disk-projection-$name.json") -Value $diskProjection
    if (-not $diskProjection.Passed) {
        throw "$name measured project-worktree disk projection requires $([Math]::Round($diskProjection.RequiredAvailableBytesBeforeExpansion / 1GB, 2)) GiB free before expansion; only $([Math]::Round($drive.AvailableFreeSpace / 1GB, 2)) GiB is available."
    }

    foreach ($worktreeName in $worktreeNames | Where-Object { $_ -ne 'normal1' }) {
        $worktreePath = Add-ProjectWorktree -WorktreeName $worktreeName
        Invoke-ProjectRestoreAndWarm -WorktreeName $worktreeName -WorktreePath $worktreePath
        Assert-FreeDiskSpace `
            -Path $repository.WorkRoot `
            -MinimumGiB $definition.Validity.RawResultsReserveGiB `
            -RecordPath (Join-Path $OutputRoot "disk-$name-after-$worktreeName.json") | Out-Null
    }
    foreach ($worktreeName in $worktreeNames) {
        $worktreePath = Join-Path $repository.WorkRoot $worktreeName
        $gitIdentity = Get-GitIdentity `
            -Root $worktreePath `
            -ExpectedCommit $repository.Commit `
            -RequireClean
        $trackedFiles = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('-C', $worktreePath, 'ls-files') `
                -WorkingDirectory $worktreePath
        )
        $baselineOutputIdentity = Get-ProjectOutputContentIdentity `
            -Worktree $worktreePath `
            -TrackedRelativePaths $trackedFiles
        if ($baselineOutputIdentity.FileCount -eq 0) {
            throw "Prepared project baseline '$worktreePath' has no output files."
        }
        $worktrees.Add([pscustomobject][ordered]@{
            Name = $worktreeName
            Path = $worktreePath
            Git = $gitIdentity
            BaselineOutputIdentity = $baselineOutputIdentity
        })
    }
    if ($worktrees.Count -ne 19) {
        throw "$name preparation did not produce exactly 19 worktrees."
    }

    Invoke-BuildServerShutdown `
        -Bootstraps @($base, $final) `
        -JournalPath $journal `
        -OutputDirectory $commandOutput
    $prepared.Add([pscustomobject][ordered]@{
        Name = $name
        Repository = $repositoryIdentity
        BuildPath = $repository.BuildPath
        TouchPath = $repository.TouchPath
        AdditionalBuildArguments = $repository.AdditionalBuildArguments
        WorkRoot = $repository.WorkRoot
        Worktrees = $worktrees.ToArray()
        DiskProjection = $diskProjection
        Restored = $true
        Warmed = -not $SkipWarm
    })
}

Write-JsonAtomic -Path $completionPath -Value ([pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTime]::UtcNow.ToString('O')
    BootstrapIdentityPath = $BootstrapIdentityPath
    PreparationBootstrapRole = 'final'
    Repositories = $prepared.ToArray()
}) -Depth 12
Write-Host "PREPARATION_COMPLETION=$completionPath"
