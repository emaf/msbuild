[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$OutputRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
Assert-WindowsCampaignHost

$definition = Get-CampaignDefinition
$completionPath = Join-Path $OutputRoot 'preparation-completion.json'
$identityRecord =
    Get-Content -LiteralPath $BootstrapIdentityPath -Raw |
    ConvertFrom-Json
$base = Get-BootstrapIdentity `
    -Role base `
    -Root $identityRecord.Base.Root `
    -ExpectedCommit $definition.Base.Commit
$final = Get-BootstrapIdentity `
    -Role final `
    -Root $identityRecord.Final.Root `
    -ExpectedCommit $definition.Final.Commit
$selectedNames = @(
    Get-SustainedSelectedWorktreeNames `
        -WorkerCount $definition.Validity.EscalatedWorkerCount
)

function Test-SustainedPreparationRecord {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Record,
        [switch]$ValidateFileSystem
    )

    $errors = [Collections.Generic.List[string]]::new()
    if ([int]$Record.SchemaVersion -ne 1 -or
        -not [bool]$Record.Authoritative -or
        [int]$Record.WorkerCapacity -ne 10) {
        $errors.Add('Preparation schema, authoritative state, or worker capacity is invalid.')
    }
    if ($Record.BootstrapIdentities.Base.Commit -ne
            $definition.Base.Commit -or
        $Record.BootstrapIdentities.Final.Commit -ne
            $definition.Final.Commit -or
        $Record.BootstrapIdentities.Base.MSBuildDllSha256 -ne
            $base.MSBuildDllSha256 -or
        $Record.BootstrapIdentities.Final.MSBuildDllSha256 -ne
            $final.MSBuildDllSha256) {
        $errors.Add('Preparation bootstrap identities do not match the exact campaign.')
    }
    $identityPathMatches = try {
        [IO.Path]::GetFullPath(
            [string]$Record.BootstrapIdentityPath).Equals(
                [IO.Path]::GetFullPath($BootstrapIdentityPath),
                [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        $false
    }
    if (-not $identityPathMatches -or
        [string]$Record.BootstrapIdentitySha256 -ne
            (Get-FileHash `
                -LiteralPath $BootstrapIdentityPath `
                -Algorithm SHA256).Hash) {
        $errors.Add('Preparation bootstrap identity file path or hash changed.')
    }
    foreach ($repositoryDefinition in $definition.Repositories) {
        $repository = $Record.Repositories |
            Where-Object Name -eq $repositoryDefinition.Name |
            Select-Object -First 1
        if ($null -eq $repository) {
            $errors.Add("Preparation is missing '$($repositoryDefinition.Name)'.")
            continue
        }
        $actualNames = @(
            $repository.Worktrees.Name |
                ForEach-Object { [string]$_ } |
                Sort-Object
        )
        if (@($repository.Worktrees).Count -ne $selectedNames.Count -or
            ($actualNames -join '|') -ne
                (@($selectedNames | Sort-Object) -join '|')) {
            $errors.Add("$($repositoryDefinition.Name) does not contain exactly normal1..normal10 plus injected.")
            continue
        }
        if ($repository.Repository.ActualCommit -ne
                $repositoryDefinition.Commit -or
            $repository.BuildPath -ne $repositoryDefinition.BuildPath -or
            $repository.TouchPath -ne $repositoryDefinition.TouchPath) {
            $errors.Add("$($repositoryDefinition.Name) pinned workload identity changed.")
        }
        foreach ($worktree in $repository.Worktrees) {
            if ($null -eq $worktree.BaselineOutputIdentity -or
                [int]$worktree.BaselineOutputIdentity.FileCount -le 0 -or
                [string]$worktree.BaselineOutputIdentity.ContentSha256 -notmatch
                    '^[0-9A-Fa-f]{64}$') {
                $errors.Add("$($repositoryDefinition.Name)/$($worktree.Name) has no valid warmed baseline identity.")
                continue
            }
            if (-not $ValidateFileSystem) {
                continue
            }
            try {
                [void](Get-GitIdentity `
                    -Root $worktree.Path `
                    -ExpectedCommit $repositoryDefinition.Commit `
                    -RequireClean)
                $tracked = @(
                    Get-NativeOutput `
                        -FileName git `
                        -Arguments @(
                            '-C',
                            $worktree.Path,
                            'ls-files') `
                        -WorkingDirectory $worktree.Path
                )
                $current = Get-ProjectOutputContentIdentity `
                    -Worktree $worktree.Path `
                    -TrackedRelativePaths $tracked
                if ($current.ContentSha256 -ne
                        $worktree.BaselineOutputIdentity.ContentSha256 -or
                    [int]$current.FileCount -ne
                        [int]$worktree.BaselineOutputIdentity.FileCount -or
                    [int64]$current.TotalBytes -ne
                        [int64]$worktree.BaselineOutputIdentity.TotalBytes) {
                    $errors.Add("$($repositoryDefinition.Name)/$($worktree.Name) no longer matches its warmed baseline.")
                }
            }
            catch {
                $errors.Add($_.Exception.Message)
            }
        }
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
    }
}

if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    $existing =
        Get-Content -LiteralPath $completionPath -Raw |
        ConvertFrom-Json
    $validation = Test-SustainedPreparationRecord `
        -Record $existing `
        -ValidateFileSystem
    if (-not $validation.Valid) {
        throw "Existing sustained preparation is invalid: $($validation.Errors -join '; ')"
    }
    Write-Host "PREPARATION_COMPLETION=$completionPath"
    return
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$journal = Join-Path $OutputRoot 'commands.jsonl'
$commandOutput = Join-Path $OutputRoot 'command-output'
$prepared = [Collections.Generic.List[object]]::new()

foreach ($repository in $definition.Repositories) {
    Assert-FreeDiskSpace `
        -Path $repository.WorkRoot `
        -MinimumGiB $definition.Validity.InitialDiskSafetyGiB `
        -RecordPath (
            Join-Path $OutputRoot "disk-before-$($repository.Name).json") |
        Out-Null
    $repositoryIdentity = Get-GitIdentity `
        -Root $repository.Root `
        -ExpectedCommit $repository.Commit `
        -RequireClean
    $remoteIdentity = Get-GitRemoteIdentity `
        -Root $repository.Root `
        -RemoteName origin `
        -ExpectedUrl $repository.Repository
    $repositoryIdentity |
        Add-Member -NotePropertyName Remote -NotePropertyValue $remoteIdentity
    foreach ($relative in @($repository.BuildPath, $repository.TouchPath)) {
        if (-not (Test-Path -LiteralPath (
            Join-Path $repository.Root $relative) -PathType Leaf)) {
            throw "$($repository.Name) pinned workload path '$relative' is missing."
        }
    }

    New-Item -ItemType Directory -Force -Path $repository.WorkRoot | Out-Null
    $registered = @(
        Get-NativeOutput `
            -FileName git `
            -Arguments @(
                '-C',
                $repository.Root,
                'worktree',
                'list',
                '--porcelain') `
            -WorkingDirectory $repository.Root |
            Where-Object {
                $_.StartsWith('worktree ', [StringComparison]::Ordinal)
            } |
            ForEach-Object {
                [IO.Path]::GetFullPath($_.Substring('worktree '.Length))
            }
    )
    $allowedExistingNames = @(
        (1..18 | ForEach-Object { "normal$_" }) + @('injected')
    )
    $allowedExistingPaths = @(
        $allowedExistingNames |
            ForEach-Object {
                [IO.Path]::GetFullPath(
                    (Join-Path $repository.WorkRoot $_))
            }
    )
    $sourcePath = [IO.Path]::GetFullPath($repository.Root)
    $foreign = @(
        $registered |
            Where-Object {
                -not $_.Equals(
                    $sourcePath,
                    [StringComparison]::OrdinalIgnoreCase) -and
                $allowedExistingPaths -notcontains $_
            }
    )
    if ($foreign.Count -gt 0) {
        throw "$($repository.Name) dedicated clone has unexpected registered worktrees: $($foreign -join ', ')"
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
    $worktrees = [Collections.Generic.List[object]]::new()
    foreach ($worktreeName in $selectedNames) {
        $worktreePath = Join-Path $repository.WorkRoot $worktreeName
        if (-not (Test-Path -LiteralPath $worktreePath -PathType Container)) {
            [void](Invoke-RecordedCommand `
                -FileName git `
                -Arguments @(
                    '-C',
                    $repository.Root,
                    'worktree',
                    'add',
                    '--detach',
                    $worktreePath,
                    $repository.Commit) `
                -WorkingDirectory $repository.Root `
                -JournalPath $journal `
                -OutputDirectory $commandOutput `
                -Label "worktree-$($repository.Name)-$worktreeName")
        }
        [void](Get-GitIdentity `
            -Root $worktreePath `
            -ExpectedCommit $repository.Commit `
            -RequireClean)
        $tracked = @(
            Get-NativeOutput `
                -FileName git `
                -Arguments @('-C', $worktreePath, 'ls-files') `
                -WorkingDirectory $worktreePath
        )
        $resetPlan = Get-ProjectOutputResetPlan `
            -Worktree $worktreePath `
            -TrackedRelativePaths $tracked
        if (-not $resetPlan.Valid) {
            throw "Unsafe output reset under '$worktreePath': $(@($resetPlan.UnsafeCandidates.RelativePath) -join ', ')"
        }
        foreach ($candidate in $resetPlan.SafeCandidates) {
            Remove-Item -LiteralPath $candidate.FullPath -Recurse -Force
            Add-CommandJournalEntry `
                -JournalPath $journal `
                -Entry ([pscustomobject][ordered]@{
                    Label = "remove-preparation-output-$($repository.Name)-$worktreeName-$($candidate.RelativePath)"
                    StartedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    Operation = 'Remove-Item'
                    Path = $candidate.FullPath
                    ExitCode = 0
                })
        }
        $status = Test-GitStatusWithinProjectOutputs `
            -Worktree $worktreePath `
            -OutputDirectories @()
        if (-not $status.Valid) {
            throw "Worktree '$worktreePath' has ignored or untracked state outside removed output roots."
        }
        $restoreArguments = New-BuildArguments `
            -MSBuildDllPath $final.MSBuildDllPath `
            -BuildPath $repository.BuildPath `
            -Restore `
            -AdditionalArguments $repository.AdditionalBuildArguments
        [void](Invoke-RecordedCommand `
            -FileName $final.DotNetPath `
            -Arguments $restoreArguments `
            -WorkingDirectory $worktreePath `
            -JournalPath $journal `
            -OutputDirectory $commandOutput `
            -Label "restore-$($repository.Name)-$worktreeName" `
            -Environment $environment)
        $warmArguments = New-BuildArguments `
            -MSBuildDllPath $final.MSBuildDllPath `
            -BuildPath $repository.BuildPath `
            -AdditionalArguments $repository.AdditionalBuildArguments
        [void](Invoke-RecordedCommand `
            -FileName $final.DotNetPath `
            -Arguments $warmArguments `
            -WorkingDirectory $worktreePath `
            -JournalPath $journal `
            -OutputDirectory $commandOutput `
            -Label "warm-$($repository.Name)-$worktreeName" `
            -Environment $environment)
        $gitIdentity = Get-GitIdentity `
            -Root $worktreePath `
            -ExpectedCommit $repository.Commit `
            -RequireClean
        $baseline = Get-ProjectOutputContentIdentity `
            -Worktree $worktreePath `
            -TrackedRelativePaths $tracked
        if ($baseline.FileCount -le 0) {
            throw "Prepared worktree '$worktreePath' has no warmed output files."
        }
        $worktrees.Add([pscustomobject][ordered]@{
            Name = $worktreeName
            Path = $worktreePath
            Git = $gitIdentity
            BaselineOutputIdentity = $baseline
        })
        Assert-FreeDiskSpace `
            -Path $repository.WorkRoot `
            -MinimumGiB $definition.Validity.RawResultsReserveGiB `
            -RecordPath (
                Join-Path $OutputRoot (
                    "disk-$($repository.Name)-after-$worktreeName.json")) |
            Out-Null
    }
    $prepared.Add([pscustomobject][ordered]@{
        Name = $repository.Name
        Repository = $repositoryIdentity
        BuildPath = $repository.BuildPath
        TouchPath = $repository.TouchPath
        AdditionalBuildArguments = $repository.AdditionalBuildArguments
        WorkRoot = $repository.WorkRoot
        Worktrees = $worktrees.ToArray()
        ExistingDedicatedWorktreesNotSelected = @(
            $registered |
                Where-Object {
                    $allowedExistingPaths -contains $_ -and
                    @($worktrees.Path) -notcontains $_
                }
        )
        Restored = $true
        Warmed = $true
    })
}

Invoke-BuildServerShutdown `
    -Bootstraps @($base, $final) `
    -JournalPath $journal `
    -OutputDirectory $commandOutput
$record = [pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Authoritative = $true
    WorkerCapacity = 10
    SelectedWorktreeNames = $selectedNames
    BootstrapIdentityPath = [IO.Path]::GetFullPath($BootstrapIdentityPath)
    BootstrapIdentitySha256 =
        (Get-FileHash -LiteralPath $BootstrapIdentityPath -Algorithm SHA256).Hash
    BootstrapIdentities = [pscustomobject][ordered]@{
        Base = [pscustomobject][ordered]@{
            Root = $base.Root
            Commit = $base.ExpectedCommit
            MSBuildDllSha256 = $base.MSBuildDllSha256
        }
        Final = [pscustomobject][ordered]@{
            Root = $final.Root
            Commit = $final.ExpectedCommit
            MSBuildDllSha256 = $final.MSBuildDllSha256
        }
    }
    PreparationBootstrapRole = 'final'
    Repositories = $prepared.ToArray()
}
$validation = Test-SustainedPreparationRecord -Record $record -ValidateFileSystem
if (-not $validation.Valid) {
    throw "Generated sustained preparation is invalid: $($validation.Errors -join '; ')"
}
Write-JsonAtomic -Path $completionPath -Value $record -Depth 12
Write-Host "PREPARATION_COMPLETION=$completionPath"
