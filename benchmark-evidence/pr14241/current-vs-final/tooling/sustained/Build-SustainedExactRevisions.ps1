[CmdletBinding()]
param(
    [string]$SourceRepositoryRoot = 'C:\perf\repos\msbuild-current-vs-final',
    [string]$BuildWorktreeRoot = 'C:\perf\worktrees\msbuild-current-vs-final',
    [string]$BootstrapStagingRoot = 'C:\perf\bootstraps\current-vs-final',
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [switch]$SkipFetch
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')
Assert-WindowsCampaignHost

$definition = Get-CampaignDefinition
$journal = Join-Path $OutputRoot 'commands.jsonl'
$commandOutput = Join-Path $OutputRoot 'command-output'
$identityPath = Join-Path $OutputRoot 'bootstrap-identities.json'
if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    if ($existing.Base.ExpectedCommit -ne $definition.Base.Commit -or
        $existing.Final.ExpectedCommit -ne $definition.Final.Commit) {
        throw "Existing exact-build identity '$identityPath' targets different revisions."
    }
    foreach ($role in @(
        [pscustomobject]@{ Name = 'base'; Identity = $existing.Base },
        [pscustomobject]@{ Name = 'final'; Identity = $existing.Final }
    )) {
        [void](Get-BootstrapIdentity `
            -Role $role.Name `
            -Root $role.Identity.Root `
            -ExpectedCommit $role.Identity.ExpectedCommit)
        [void](Test-ImmutableBootstrapStage `
            -Root $role.Identity.Root `
            -RecordPath (Join-Path $OutputRoot "$($role.Name)-resume-integrity.json"))
    }
    Write-Host "BOOTSTRAP_IDENTITIES=$identityPath"
    return
}

New-Item -ItemType Directory -Force -Path $OutputRoot,$BuildWorktreeRoot | Out-Null
Assert-FreeDiskSpace `
    -Path $BuildWorktreeRoot `
    -MinimumGiB $definition.Validity.InitialDiskSafetyGiB `
    -RecordPath (Join-Path $OutputRoot 'disk-before-build.json') | Out-Null

if (-not (Test-Path -LiteralPath $SourceRepositoryRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path (
        Split-Path -Parent $SourceRepositoryRoot) | Out-Null
    [void](Invoke-RecordedCommand `
        -FileName git `
        -Arguments @(
            'clone',
            '--no-checkout',
            $definition.Base.Repository,
            $SourceRepositoryRoot) `
        -WorkingDirectory (Split-Path -Parent $SourceRepositoryRoot) `
        -JournalPath $journal `
        -OutputDirectory $commandOutput `
        -Label 'clone-msbuild-source')
}

$insideWorkTree = @(
    Get-NativeOutput `
        -FileName git `
        -Arguments @(
            '-C',
            $SourceRepositoryRoot,
            'rev-parse',
            '--is-inside-work-tree') `
        -WorkingDirectory $SourceRepositoryRoot
)[0]
if ($insideWorkTree -ne 'true') {
    throw "'$SourceRepositoryRoot' is not a git worktree."
}
$baseRemoteIdentity = Get-GitRemoteIdentity `
    -Root $SourceRepositoryRoot `
    -RemoteName origin `
    -ExpectedUrl $definition.Base.Repository
$remotes = @(
    Get-NativeOutput `
        -FileName git `
        -Arguments @('-C', $SourceRepositoryRoot, 'remote') `
        -WorkingDirectory $SourceRepositoryRoot
)
if ($remotes -notcontains 'final') {
    [void](Invoke-RecordedCommand `
        -FileName git `
        -Arguments @(
            '-C',
            $SourceRepositoryRoot,
            'remote',
            'add',
            'final',
            $definition.Final.Repository) `
        -WorkingDirectory $SourceRepositoryRoot `
        -JournalPath $journal `
        -OutputDirectory $commandOutput `
        -Label 'add-final-remote')
}
$finalRemoteIdentity = Get-GitRemoteIdentity `
    -Root $SourceRepositoryRoot `
    -RemoteName final `
    -ExpectedUrl $definition.Final.Repository

if (-not $SkipFetch) {
    [void](Invoke-RecordedCommand `
        -FileName git `
        -Arguments @(
            '-C',
            $SourceRepositoryRoot,
            'fetch',
            '--no-tags',
            'origin',
            $definition.Base.Commit) `
        -WorkingDirectory $SourceRepositoryRoot `
        -JournalPath $journal `
        -OutputDirectory $commandOutput `
        -Label 'fetch-base')
    [void](Invoke-RecordedCommand `
        -FileName git `
        -Arguments @(
            '-C',
            $SourceRepositoryRoot,
            'fetch',
            '--no-tags',
            'final',
            "$($definition.Final.Branch):refs/remotes/final/$($definition.Final.Branch)") `
        -WorkingDirectory $SourceRepositoryRoot `
        -JournalPath $journal `
        -OutputDirectory $commandOutput `
        -Label 'fetch-final')
}

$finalBranchCommit = @(
    Get-NativeOutput `
        -FileName git `
        -Arguments @(
            '-C',
            $SourceRepositoryRoot,
            'rev-parse',
            "refs/remotes/final/$($definition.Final.Branch)^{commit}") `
        -WorkingDirectory $SourceRepositoryRoot
)[0].Trim()
if ($finalBranchCommit -ne $definition.Final.Commit) {
    throw "Final branch '$($definition.Final.Branch)' resolves to '$finalBranchCommit'; expected '$($definition.Final.Commit)'."
}
foreach ($commit in @($definition.Base.Commit, $definition.Final.Commit)) {
    $resolved = @(
        Get-NativeOutput `
            -FileName git `
            -Arguments @('-C', $SourceRepositoryRoot, 'rev-parse', "$commit^{commit}") `
            -WorkingDirectory $SourceRepositoryRoot
    )[0].Trim()
    if ($resolved -ne $commit) {
        throw "Source repository did not resolve exact commit '$commit'."
    }
}

$roles = @(
    [pscustomobject]@{
        Role = 'base'
        Commit = $definition.Base.Commit
    },
    [pscustomobject]@{
        Role = 'final'
        Commit = $definition.Final.Commit
    }
)
$buildArguments = @(Get-ExactBootstrapBuildArguments)
$built = [ordered]@{}
$roleActions = [Collections.Generic.List[object]]::new()

foreach ($role in $roles) {
    $worktree = Join-Path $BuildWorktreeRoot (
        "$($role.Role)-$($role.Commit.Substring(0, 12))")
    $stageCandidates = @(
        Get-ImmutableBootstrapStageCandidates `
            -StagingRoot $BootstrapStagingRoot `
            -ExpectedCommit $role.Commit
    )
    $reusableStages = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $stageCandidates) {
        $stageRoot = Join-Path $candidate.FullName 'core'
        try {
            $identity = Get-BootstrapIdentity `
                -Role $role.Role `
                -Root $stageRoot `
                -ExpectedCommit $role.Commit
            $integrity = Test-ImmutableBootstrapStage `
                -Root $stageRoot `
                -RecordPath (
                    Join-Path $OutputRoot (
                        "$($role.Role)-candidate-$($candidate.Name)-integrity.json"))
            $reusableStages.Add([pscustomobject]@{
                Identity = $identity
                Integrity = $integrity
            })
        }
        catch {
            throw "Immutable $($role.Role) stage candidate '$stageRoot' failed validation and will not be silently replaced: $($_.Exception.Message)"
        }
    }
    if ($reusableStages.Count -gt 1) {
        throw "Found $($reusableStages.Count) independently valid immutable stages for exact $($role.Role) commit '$($role.Commit)'; unambiguous reuse is required."
    }

    if ($reusableStages.Count -eq 1) {
        $stagedIdentity = $reusableStages[0].Identity
        $sourceGit = if (Test-Path -LiteralPath $worktree -PathType Container) {
            Get-GitIdentity `
                -Root $worktree `
                -ExpectedCommit $role.Commit `
                -RequireClean
        }
        else {
            [pscustomobject][ordered]@{
                Root = $null
                ExpectedCommit = $role.Commit
                ActualCommit = $role.Commit
                Clean = $null
                Verified = $true
                Verification = 'Exact commit object and immutable staged ProductVersion/content identity.'
            }
        }
        $built[$role.Role] = [pscustomobject][ordered]@{
            Source = $stagedIdentity
            Staged = $stagedIdentity
            SourceWorktree = if (Test-Path -LiteralPath $worktree) {
                $worktree
            }
            else {
                $null
            }
            SourceGit = $sourceGit
        }
        $roleActions.Add([pscustomobject][ordered]@{
            Role = $role.Role
            Commit = $role.Commit
            Action = 'Reused'
            Reused = $true
            Built = $false
            StageRoot = $stagedIdentity.Root
            IntegrityValidated = $true
        })
        continue
    }

    if (-not (Test-Path -LiteralPath $worktree -PathType Container)) {
        [void](Invoke-RecordedCommand `
            -FileName git `
            -Arguments @(
                '-C',
                $SourceRepositoryRoot,
                'worktree',
                'add',
                '--detach',
                $worktree,
                $role.Commit) `
            -WorkingDirectory $SourceRepositoryRoot `
            -JournalPath $journal `
            -OutputDirectory $commandOutput `
            -Label "create-$($role.Role)-worktree")
    }
    [void](Get-GitIdentity `
        -Root $worktree `
        -ExpectedCommit $role.Commit `
        -RequireClean)
    [void](Invoke-RecordedCommand `
        -FileName git `
        -Arguments @('-C', $worktree, 'clean', '-xffd') `
        -WorkingDirectory $worktree `
        -JournalPath $journal `
        -OutputDirectory $commandOutput `
        -Label "clean-$($role.Role)-worktree")
    [void](Get-GitIdentity `
        -Root $worktree `
        -ExpectedCommit $role.Commit `
        -RequireClean)

    $buildStarted = [DateTime]::UtcNow
    Add-CommandJournalEntry `
        -JournalPath $journal `
        -Entry ([pscustomobject][ordered]@{
            Label = "build-$($role.Role)"
            StartedUtc = $buildStarted.ToString('O')
            FileName = (Join-Path $worktree 'build.cmd')
            Arguments = $buildArguments
            WorkingDirectory = $worktree
            EnvironmentOverrides = [ordered]@{
                DOTNET_CLI_TELEMETRY_OPTOUT = '1'
            }
            Status = 'Started'
            Note = 'Output is inherited by the durable launcher and is not piped.'
        })
    $environmentNames = @(
        (Get-CoordinatorEnvironmentVariableNames) +
            @('DOTNET_CLI_TELEMETRY_OPTOUT')
    )
    $oldEnvironment = @{}
    foreach ($name in $environmentNames) {
        $oldEnvironment[$name] =
            [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        foreach ($name in Get-CoordinatorEnvironmentVariableNames) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        [Environment]::SetEnvironmentVariable(
            'DOTNET_CLI_TELEMETRY_OPTOUT',
            '1',
            'Process')
        Push-Location $worktree
        try {
            & (Join-Path $worktree 'build.cmd') @buildArguments
            $buildExitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $oldEnvironment[$name],
                'Process')
        }
    }
    Add-CommandJournalEntry `
        -JournalPath $journal `
        -Entry ([pscustomobject][ordered]@{
            Label = "build-$($role.Role)"
            StartedUtc = $buildStarted.ToString('O')
            CompletedUtc = [DateTime]::UtcNow.ToString('O')
            FileName = (Join-Path $worktree 'build.cmd')
            Arguments = $buildArguments
            WorkingDirectory = $worktree
            ExitCode = $buildExitCode
            Status = if ($buildExitCode -eq 0) {
                'Succeeded'
            }
            else {
                'Failed'
            }
        })
    if ($buildExitCode -ne 0) {
        throw "Exact $($role.Role) build failed with exit code $buildExitCode."
    }

    $sourceBootstrapRoot = Join-Path $worktree 'artifacts\bin\bootstrap\core'
    $sourceIdentity = Get-BootstrapIdentity `
        -Role $role.Role `
        -Root $sourceBootstrapRoot `
        -ExpectedCommit $role.Commit
    $stagedIdentity = Publish-ImmutableBootstrap `
        -Identity $sourceIdentity `
        -StagingRoot $BootstrapStagingRoot
    [void](Test-ImmutableBootstrapStage `
        -Root $stagedIdentity.Root `
        -RecordPath (
            Join-Path $OutputRoot "$($role.Role)-built-stage-integrity.json"))
    $built[$role.Role] = [pscustomobject][ordered]@{
        Source = $sourceIdentity
        Staged = $stagedIdentity
        SourceWorktree = $worktree
        SourceGit = Get-GitIdentity `
            -Root $worktree `
            -ExpectedCommit $role.Commit
    }
    $roleActions.Add([pscustomobject][ordered]@{
        Role = $role.Role
        Commit = $role.Commit
        Action = 'Built'
        Reused = $false
        Built = $true
        StageRoot = $stagedIdentity.Root
        IntegrityValidated = $true
    })
}

if ($built.base.Staged.SdkVersion -ne $built.final.Staged.SdkVersion) {
    throw "Exact builds produced different SDK versions: BASE=$($built.base.Staged.SdkVersion), FINAL=$($built.final.Staged.SdkVersion)."
}
$baseIsAncestor = $false
& git -C $SourceRepositoryRoot merge-base --is-ancestor `
    $definition.Base.Commit `
    $definition.Final.Commit
if ($LASTEXITCODE -eq 0) {
    $baseIsAncestor = $true
}
elseif ($LASTEXITCODE -ne 1) {
    throw "git merge-base --is-ancestor failed with exit code $LASTEXITCODE."
}
if (-not $baseIsAncestor) {
    throw 'The exact BASE commit is not an ancestor of the exact FINAL commit.'
}

$record = [pscustomobject][ordered]@{
    SchemaVersion = 2
    CompletedUtc = [DateTime]::UtcNow.ToString('O')
    Campaign = [pscustomobject][ordered]@{
        Base = $definition.Base
        Final = $definition.Final
    }
    BuildCommand = @('.\build.cmd') + $buildArguments
    RoleActions = $roleActions.ToArray()
    ReusedRoles = @(
        $roleActions |
            Where-Object Reused |
            Select-Object -ExpandProperty Role
    )
    BuiltRoles = @(
        $roleActions |
            Where-Object Built |
            Select-Object -ExpandProperty Role
    )
    PerRoleImmutableReuse = $true
    IdenticalBuildSettings = $true
    BaseIsAncestorOfFinal = $baseIsAncestor
    Base = $built.base.Staged
    Final = $built.final.Staged
    Sources = [pscustomobject]@{
        Base = $built.base.SourceGit
        Final = $built.final.SourceGit
    }
    SourceRemotes = @($baseRemoteIdentity, $finalRemoteIdentity)
}
Write-JsonAtomic -Path $identityPath -Value $record -Depth 14
Write-Host "BOOTSTRAP_IDENTITIES=$identityPath"
