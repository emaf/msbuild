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
    [ValidateSet('isolated', 'sustained')]
    [string]$Shape,
    [Parameter(Mandatory)]
    [string]$Reason,
    [Parameter(Mandatory)]
    [string]$OutputRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
Assert-WindowsCampaignHost

$campaign = Get-CampaignDefinition
$repositoryDefinition = Get-RepositoryDefinition -Name $RepositoryName
$preparation = Get-Content -LiteralPath $PreparationPath -Raw | ConvertFrom-Json
$preparedRepository = $preparation.Repositories |
    Where-Object Name -eq $RepositoryName |
    Select-Object -First 1
if ($null -eq $preparedRepository) {
    throw "Preparation metadata does not contain '$RepositoryName'."
}
$identityRecord = Get-Content -LiteralPath $BootstrapIdentityPath -Raw | ConvertFrom-Json
$base = Get-BootstrapIdentity -Role base -Root $identityRecord.Base.Root -ExpectedCommit $campaign.Base.Commit
$final = Get-BootstrapIdentity -Role final -Root $identityRecord.Final.Root -ExpectedCommit $campaign.Final.Commit
$worktreeNames = @(Get-ShapeWorktreeNames -Shape $Shape)
$worktrees = @(
    foreach ($name in $worktreeNames) {
        $worktree = $preparedRepository.Worktrees |
            Where-Object Name -eq $name |
            Select-Object -First 1
        if ($null -eq $worktree) {
            throw "Prepared worktree '$name' is missing for '$RepositoryName'."
        }
        if ($null -eq $worktree.BaselineOutputIdentity) {
            throw "Prepared worktree '$name' has no recorded output baseline identity."
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
    $existing = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
    $currentPreparationSha256 = (Get-FileHash -LiteralPath $PreparationPath -Algorithm SHA256).Hash
    if ($existing.PreparationSha256 -ne $currentPreparationSha256) {
        throw 'Existing reset checkpoint targets a different prepared baseline identity.'
    }
    $checkpoint = Test-WorktreeResetCheckpointRecord `
        -Record $existing `
        -Repository $RepositoryName `
        -Shape $Shape
    if (-not $checkpoint.Valid) {
        throw "Existing reset checkpoint is invalid: $($checkpoint.Errors -join '; ')"
    }
    foreach ($worktree in $worktrees) {
        [void](Get-GitIdentity -Root $worktree.Path -ExpectedCommit $repositoryDefinition.Commit -RequireClean)
        $trackedFiles = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('-C', $worktree.Path, 'ls-files') `
                -WorkingDirectory $worktree.Path
        )
        $currentOutputIdentity = Get-ProjectOutputContentIdentity `
            -Worktree $worktree.Path `
            -TrackedRelativePaths $trackedFiles
        $recordedWorktree = $existing.AffectedWorktrees |
            Where-Object Name -eq $worktree.Name |
            Select-Object -First 1
        if ($null -eq $recordedWorktree -or
            $currentOutputIdentity.ContentSha256 -ne $recordedWorktree.RestoredBaselineOutputIdentity.ContentSha256) {
            throw "Existing reset checkpoint no longer matches worktree '$($worktree.Name)' output state."
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
            $referencesAffectedWorktree =
                -not [string]::IsNullOrWhiteSpace([string]$processRecord.CommandLine) -and
                @($worktrees | Where-Object {
                    ([string]$processRecord.CommandLine).Contains($_.Path, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
            $isBuildProcess =
                $processRecord.Name -in @(
                    'MSBuild.exe',
                    'MSBuild.Coordinator.exe',
                    'csc.exe',
                    'vbc.exe',
                    'VBCSCompiler.exe'
                ) -or
                ($processRecord.Name -eq 'dotnet.exe' -and
                    $processRecord.CommandLine -match 'MSBuild\.dll')
            if ([int]$processRecord.ProcessId -ne $PID -and
                ($referencesAffectedWorktree -or $isBuildProcess)) {
                $processRecord
            }
        } |
        Select-Object ProcessId, ParentProcessId, CreationDate, Name, ExecutablePath, CommandLine
)
if ($activeConflicts.Count -gt 0) {
    throw "Refusing baseline reset because $($activeConflicts.Count) process(es) still reference affected worktrees."
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
$resetRecords = [Collections.Generic.List[object]]::new()
foreach ($worktree in $worktrees) {
    [void](Get-GitIdentity -Root $worktree.Path -ExpectedCommit $repositoryDefinition.Commit -RequireClean)
    $trackedFiles = @(
        Get-NativeOutput `
            -FileName git `
            -Arguments @('-C', $worktree.Path, 'ls-files') `
            -WorkingDirectory $worktree.Path
    )
    $resetPlan = Get-ProjectOutputResetPlan `
        -Worktree $worktree.Path `
        -TrackedRelativePaths $trackedFiles
    if (-not $resetPlan.Valid) {
        throw "Unsafe output reset candidate(s) under '$($worktree.Path)' contain tracked files: $(@($resetPlan.UnsafeCandidates.RelativePath) -join ', ')."
    }
    $removed = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $resetPlan.SafeCandidates) {
        $bytes = [int64](
            Get-ChildItem -LiteralPath $candidate.FullPath -Recurse -File -Force |
                Measure-Object Length -Sum
        ).Sum
        Remove-Item -LiteralPath $candidate.FullPath -Recurse -Force
        $removalRecord = [pscustomobject][ordered]@{
            RemovedUtc = [DateTime]::UtcNow.ToString('O')
            FullPath = $candidate.FullPath
            RelativePath = $candidate.RelativePath
            Bytes = $bytes
            TrackedFileCount = 0
        }
        $removed.Add($removalRecord)
        Add-CommandJournalEntry -JournalPath $journal -Entry ([pscustomobject][ordered]@{
            Label = "remove-project-output-$RepositoryName-$($worktree.Name)-$($candidate.RelativePath)"
            StartedUtc = $removalRecord.RemovedUtc
            CompletedUtc = [DateTime]::UtcNow.ToString('O')
            Operation = 'Remove-Item'
            Path = $candidate.FullPath
            ExitCode = 0
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
    $gitIdentity = Get-GitIdentity `
        -Root $worktree.Path `
        -ExpectedCommit $repositoryDefinition.Commit `
        -RequireClean
    $restoredOutputIdentity = Get-ProjectOutputContentIdentity `
        -Worktree $worktree.Path `
        -TrackedRelativePaths $trackedFiles
    $expectedOutputIdentity = $worktree.BaselineOutputIdentity
    if ($restoredOutputIdentity.ContentSha256 -ne $expectedOutputIdentity.ContentSha256 -or
        [int]$restoredOutputIdentity.FileCount -ne [int]$expectedOutputIdentity.FileCount -or
        [int64]$restoredOutputIdentity.TotalBytes -ne [int64]$expectedOutputIdentity.TotalBytes) {
        throw "Reset output baseline for '$($worktree.Path)' does not match the recorded prepared/restored/warmed identity."
    }
    $resetRecords.Add([pscustomobject][ordered]@{
        Name = $worktree.Name
        Path = $worktree.Path
        RemovedOutputDirectories = $removed.ToArray()
        RestoreCompleted = $true
        WarmCompleted = $true
        ExpectedBaselineOutputIdentity = $expectedOutputIdentity
        RestoredBaselineOutputIdentity = $restoredOutputIdentity
        BaselineOutputIdentityMatched = $true
        Git = $gitIdentity
        Retouched = $false
    })
}

Invoke-BuildServerShutdown `
    -Bootstraps @($base, $final) `
    -JournalPath $journal `
    -OutputDirectory $commandOutput
$record = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTime]::UtcNow.ToString('O')
    Completed = $true
    Repository = $RepositoryName
    RepositoryCommit = $repositoryDefinition.Commit
    Shape = $Shape
    Reason = $Reason
    PreparationPath = $PreparationPath
    PreparationSha256 = (Get-FileHash -LiteralPath $PreparationPath -Algorithm SHA256).Hash
    AffectedWorktrees = $resetRecords.ToArray()
    NoOverlap = $true
    BaselineRestored = @($resetRecords | Where-Object {
        -not $_.RestoreCompleted -or -not $_.WarmCompleted -or $_.Retouched
    }).Count -eq 0
    UsedGitClean = $false
    RetouchOccursOnlyInsideScenario = $true
}
$checkpoint = Test-WorktreeResetCheckpointRecord `
    -Record $record `
    -Repository $RepositoryName `
    -Shape $Shape
if (-not $checkpoint.Valid) {
    throw "Generated reset checkpoint is invalid: $($checkpoint.Errors -join '; ')"
}
Write-JsonAtomic -Path $completionPath -Value $record -Depth 12
Write-Host "RESET_COMPLETION=$completionPath"
