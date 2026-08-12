Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function ConvertTo-UtcDateTimeOffset {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        $dateTime = [DateTime]$Value
        if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
            $dateTime = [DateTime]::SpecifyKind($dateTime, [DateTimeKind]::Utc)
        }
        return [DateTimeOffset]::new($dateTime).ToUniversalTime()
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed)) {
        throw "Timestamp '$Value' is not a valid ISO-8601 instant."
    }
    return $parsed.ToUniversalTime()
}

$script:CoordinatorEnvironmentVariables = @(
    'MSBUILDUSECOORDINATOR',
    'MSBUILDCOORDINATORPIPENAME',
    'MSBUILDCOORDINATORNODEBUDGET',
    'MSBUILDCOORDINATORHEARTBEAT',
    'MSBUILDCOORDINATORSHUTDOWNTIMEOUT',
    'MSBUILDCOORDINATORGRANTID',
    'MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES',
    'MSBUILDCOORDINATORMAXNODESPERBUILD',
    'MSBUILDCOORDINATORPRIORITYAGINGTHRESHOLD',
    'MSBUILDCOORDINATORBUILDREQUESTPRIORITY',
    'MSBUILDDEBUGCOMM',
    'MSBUILDDEBUGPATH'
)

function Get-CoordinatorEnvironmentVariableNames {
    return @($script:CoordinatorEnvironmentVariables)
}

function Assert-WindowsCampaignHost {
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Windows)) {
        throw 'The current-vs-final campaign is Windows-only.'
    }
}

function Get-CampaignDefinition {
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        Name = 'dotnet-msbuild-pr14241-current-vs-final'
        Design = 'Lean representative propagated project campaign'
        WorkloadDeviation = 'Representative propagated project workloads are a limited reviewer/runtime-cost deviation; historical full-solution and node-count matrices are supporting evidence only and are never pooled.'
        MaximumProjectedCampaignHours = 4
        RuntimeProjectionSafetyFactor = 1.25
        NodeBudget = 16
        Base = [pscustomobject][ordered]@{
            Key = 'BASE'
            Repository = 'https://github.com/dotnet/msbuild'
            Commit = 'ff5b281f0c5828dec0d092fcd1b682019de7d1ca'
        }
        Final = [pscustomobject][ordered]@{
            Key = 'FINAL'
            Repository = 'https://github.com/emaf/msbuild'
            Branch = 'coordinator-priorities-main-rebase-20260811'
            Commit = '9aa319701cc70713e5f017a1a8e0cc88b1813ae1'
        }
        Repositories = @(
            [pscustomobject][ordered]@{
                Name = 'roslyn'
                Repository = 'https://github.com/dotnet/roslyn'
                Root = 'C:\perf\repos\roslyn'
                Commit = 'bc396b5e5d67af28d2aef6bfd4ab2fa8577eb44b'
                WorkRoot = 'C:\w\cvf\r'
                BuildPath = 'src\Compilers\CSharp\Portable\Microsoft.CodeAnalysis.CSharp.csproj'
                TouchPath = 'src\Compilers\CSharp\Portable\CSharpCompilationOptions.cs'
                AdditionalBuildArguments = @()
            },
            [pscustomobject][ordered]@{
                Name = 'aspire'
                Repository = 'https://github.com/dotnet/aspire'
                Root = 'C:\perf\repos\aspire'
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
                Description = 'Current Coordinator defaults; reservation, cap, and priority variables absent.'
            },
            [pscustomobject][ordered]@{
                Key = 'COMPAT'
                BootstrapRole = 'final'
                Reservation = 0
                MaximumNodes = 0
                NormalPriorityValue = 'Normal'
                Description = 'Final binary with explicit 0/0 compatibility policy; all requests Normal.'
            },
            [pscustomobject][ordered]@{
                Key = 'FINAL-N'
                BootstrapRole = 'final'
                Reservation = $null
                MaximumNodes = $null
                NormalPriorityValue = 'Normal'
                Description = 'Final computed defaults; all requests Normal.'
            },
            [pscustomobject][ordered]@{
                Key = 'FINAL-H'
                BootstrapRole = 'final'
                Reservation = $null
                MaximumNodes = $null
                NormalPriorityValue = 'Normal'
                Description = 'Final computed defaults; only the designated injected request is High.'
            }
        )
        Shapes = @(
            [pscustomobject][ordered]@{
                Key = 'isolated'
                Conditions = @('BASE', 'COMPAT', 'FINAL-N')
                WarmupBlocks = 1
                MeasuredBlocks = 6
                Seed = 20260812
                MinimumAvailableMB = 16384
            },
            [pscustomobject][ordered]@{
                Key = 'sustained'
                Conditions = @('BASE', 'COMPAT', 'FINAL-N', 'FINAL-H')
                WarmupBlocks = 1
                MeasuredBlocks = 4
                Seed = 20260814
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
            MaximumBlockAttempts = 3
            SustainedWorkers = 18
            SustainedSteadyAllocationSeconds = 30
            SustainedHandoffGapToleranceSeconds = 1
            SustainedQueueMinimum = 2
            SustainedQueueNonemptyFractionMinimum = 0.90
            SustainedInjectionCompletion = 6
            SustainedEndingCompletion = 12
            SustainedTimeoutMinutes = 10
            MaxKnownExternalNoiseCpuCoreFraction = 0.10
            MaxKnownExternalNoiseWorkingSetBytes = 4GB
        }
    }
}

function Get-ConditionDefinition {
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    $condition = (Get-CampaignDefinition).Conditions |
        Where-Object Key -eq $Key |
        Select-Object -First 1
    if ($null -eq $condition) {
        throw "Unknown campaign condition '$Key'."
    }
    return $condition
}

function Get-ShapeDefinition {
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    $shape = (Get-CampaignDefinition).Shapes |
        Where-Object Key -eq $Key |
        Select-Object -First 1
    if ($null -eq $shape) {
        throw "Unknown campaign shape '$Key'."
    }
    return $shape
}

function Get-ShapeWorktreeNames {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('isolated', 'sustained')]
        [string]$Shape
    )

    switch ($Shape) {
        'isolated' { return @('normal1') }
        'sustained' { return @((1..18 | ForEach-Object { "normal$_" }) + @('injected')) }
    }
}

function Get-ProjectOutputResetPlan {
    param(
        [Parameter(Mandatory)]
        [string]$Worktree,

        [string[]]$TrackedRelativePaths = @()
    )

    $root = [IO.Path]::GetFullPath($Worktree)
    $candidatePaths = [Collections.Generic.List[string]]::new()
    foreach ($name in @('artifacts', '.artifacts')) {
        $path = Join-Path $root $name
        if (Test-Path -LiteralPath $path -PathType Container) {
            $candidatePaths.Add([IO.Path]::GetFullPath($path))
        }
    }
    foreach ($directory in Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction Stop |
        Where-Object Name -in @('bin', 'obj')) {
        $candidatePaths.Add([IO.Path]::GetFullPath($directory.FullName))
    }
    $topLevelCandidates = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidatePaths |
        Sort-Object @{ Expression = { $_.Length } }, @{ Expression = { $_ } } -Unique) {
        $nested = $false
        foreach ($selected in $topLevelCandidates) {
            if ($candidate.StartsWith(
                $selected.TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase)) {
                $nested = $true
                break
            }
        }
        if (-not $nested) {
            $topLevelCandidates.Add($candidate)
        }
    }
    $trackedFullPaths = @(
        foreach ($relativePath in $TrackedRelativePaths) {
            [IO.Path]::GetFullPath((Join-Path $root $relativePath))
        }
    )
    $safe = [Collections.Generic.List[object]]::new()
    $unsafe = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $topLevelCandidates) {
        $candidateItem = Get-Item -LiteralPath $candidate -Force
        $insideWorktree = $candidate.StartsWith(
            $root.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase)
        $isReparsePoint =
            ($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $containsReparsePoint = @(
            Get-ChildItem -LiteralPath $candidate -Recurse -Force |
                Where-Object {
                    ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                }
        ).Count -gt 0
        $trackedUnderCandidate = @(
            $trackedFullPaths |
                Where-Object {
                    $_.Equals($candidate, [StringComparison]::OrdinalIgnoreCase) -or
                        $_.StartsWith(
                            $candidate.TrimEnd('\') + '\',
                            [StringComparison]::OrdinalIgnoreCase)
                }
        )
        $record = [pscustomobject][ordered]@{
            FullPath = $candidate
            RelativePath = [IO.Path]::GetRelativePath($root, $candidate)
            TrackedPaths = $trackedUnderCandidate
            IsInsideWorktree = $insideWorktree
            IsReparsePoint = $isReparsePoint
            ContainsReparsePoint = $containsReparsePoint
            UnsafeReason = if (-not $insideWorktree) {
                'Candidate resolves outside the worktree.'
            }
            elseif ($isReparsePoint) {
                'Candidate is a reparse point.'
            }
            elseif ($containsReparsePoint) {
                'Candidate contains a reparse point.'
            }
            elseif ($trackedUnderCandidate.Count -gt 0) {
                'Candidate contains tracked files.'
            }
            else {
                $null
            }
        }
        if (-not $insideWorktree -or
            $isReparsePoint -or
            $containsReparsePoint -or
            $trackedUnderCandidate.Count -gt 0) {
            $unsafe.Add($record)
        }
        else {
            $safe.Add($record)
        }
    }
    [pscustomobject][ordered]@{
        Worktree = $root
        SafeCandidates = $safe.ToArray()
        UnsafeCandidates = $unsafe.ToArray()
        Valid = $unsafe.Count -eq 0
    }
}

function Get-ProjectOutputContentIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Worktree,

        [string[]]$TrackedRelativePaths = @()
    )

    $root = [IO.Path]::GetFullPath($Worktree)
    $plan = Get-ProjectOutputResetPlan `
        -Worktree $root `
        -TrackedRelativePaths $TrackedRelativePaths
    if (-not $plan.Valid) {
        throw "Cannot identify project outputs because reset candidates contain tracked files: $(@($plan.UnsafeCandidates.RelativePath) -join ', ')."
    }
    $files = @(
        foreach ($candidate in $plan.SafeCandidates) {
            Get-ChildItem -LiteralPath $candidate.FullPath -Recurse -File -Force |
                ForEach-Object {
                    [pscustomobject][ordered]@{
                        RelativePath = [IO.Path]::GetRelativePath($root, $_.FullName)
                        Bytes = $_.Length
                        Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                    }
                }
        }
    )
    $files = @($files | Sort-Object RelativePath)
    $builder = [Text.StringBuilder]::new()
    foreach ($file in $files) {
        [void]$builder.Append($file.RelativePath.Replace('\', '/'))
        [void]$builder.Append([char]0)
        [void]$builder.Append($file.Bytes)
        [void]$builder.Append([char]0)
        [void]$builder.Append($file.Sha256)
        [void]$builder.Append("`n")
    }
    $contentHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($builder.ToString())))
    [pscustomobject][ordered]@{
        Worktree = $root
        OutputDirectories = @($plan.SafeCandidates.RelativePath)
        FileCount = $files.Count
        TotalBytes = if ($files.Count -eq 0) { 0 } else { ($files | Measure-Object Bytes -Sum).Sum }
        ContentSha256 = $contentHash
    }
}

function Test-GitStatusWithinProjectOutputs {
    param(
        [Parameter(Mandatory)]
        [string]$Worktree,

        [Parameter(Mandatory)]
        [string[]]$OutputDirectories
    )

    $root = [IO.Path]::GetFullPath($Worktree)
    $allowedRoots = @(
        foreach ($relativePath in $OutputDirectories) {
            $fullPath = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
            if (-not $fullPath.StartsWith(
                $root.TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase)) {
                throw "Output directory '$relativePath' resolves outside '$root'."
            }
            $fullPath.TrimEnd('\')
        }
    )
    $status = @(
        Get-NativeOutput `
            -FileName git `
            -Arguments @(
                '-C', $root,
                'status',
                '--porcelain=v1',
                '--untracked-files=all',
                '--ignored'
            ) `
            -WorkingDirectory $root |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $unexpected = [Collections.Generic.List[object]]::new()
    foreach ($line in $status) {
        $relativePath = $null
        if ($line.Length -ge 4) {
            $relativePath = $line.Substring(3)
            if ($relativePath.StartsWith('"', [StringComparison]::Ordinal) -and
                $relativePath.EndsWith('"', [StringComparison]::Ordinal)) {
                try {
                    $relativePath = [string]($relativePath | ConvertFrom-Json)
                }
                catch {
                    $relativePath = $null
                }
            }
        }
        $fullPath = $null
        $allowed = $false
        if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
            try {
                $fullPath = [IO.Path]::GetFullPath(
                    (Join-Path $root $relativePath.Replace('/', '\').TrimEnd('\')))
                $allowed = @(
                    $allowedRoots |
                        Where-Object {
                            $fullPath.Equals(
                                $_,
                                [StringComparison]::OrdinalIgnoreCase) -or
                                $fullPath.StartsWith(
                                    $_ + '\',
                                    [StringComparison]::OrdinalIgnoreCase)
                        }
                ).Count -gt 0
            }
            catch {
                $allowed = $false
            }
        }
        if (-not $allowed) {
            $unexpected.Add([pscustomobject][ordered]@{
                Status = $line.Substring(0, [Math]::Min(2, $line.Length))
                RelativePath = $relativePath
                Raw = $line
            })
        }
    }

    [pscustomobject][ordered]@{
        Valid = $unexpected.Count -eq 0
        StatusEntries = $status
        UnexpectedEntries = $unexpected.ToArray()
        OutputDirectories = $OutputDirectories
    }
}

function Test-PreparationCompletionRecord {
    param(
        [Parameter(Mandatory)]
        [object]$Record,
        [Parameter(Mandatory)]
        [object]$BaseBootstrap,
        [Parameter(Mandatory)]
        [object]$FinalBootstrap,
        [Parameter(Mandatory)]
        [object[]]$RepositoryDefinitions,
        [string]$BootstrapIdentityPath,
        [switch]$ValidateFileSystem
    )

    $errors = [Collections.Generic.List[string]]::new()
    if ($null -eq $Record.PSObject.Properties['SchemaVersion'] -or
        [int]$Record.SchemaVersion -ne 2) {
        $errors.Add('Preparation completion schema must be exactly version 2.')
    }
    if ($null -eq $Record.PSObject.Properties['CompletedUtc']) {
        $errors.Add('Preparation completion has no completion timestamp.')
    }
    else {
        try {
            [void](ConvertTo-UtcDateTimeOffset -Value $Record.CompletedUtc)
        }
        catch {
            $errors.Add("Preparation completion timestamp is invalid: $($_.Exception.Message)")
        }
    }
    if ($null -eq $Record.PSObject.Properties['Authoritative'] -or
        -not (ConvertTo-StrictBoolean -Value $Record.Authoritative)) {
        $errors.Add('Preparation completion is not authoritative.')
    }
    if ([string]$Record.PreparationBootstrapRole -ne 'final') {
        $errors.Add('Preparation completion did not use the exact FINAL bootstrap.')
    }
    if (-not [string]::IsNullOrWhiteSpace($BootstrapIdentityPath)) {
        $identityPathMatches = try {
            [IO.Path]::GetFullPath([string]$Record.BootstrapIdentityPath).Equals(
                [IO.Path]::GetFullPath($BootstrapIdentityPath),
                [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
        if (-not $identityPathMatches -or
            -not (Test-Path -LiteralPath $BootstrapIdentityPath -PathType Leaf) -or
            [string]$Record.BootstrapIdentitySha256 -ne
                (Get-FileHash -LiteralPath $BootstrapIdentityPath -Algorithm SHA256).Hash) {
            $errors.Add('Preparation bootstrap identity file changed.')
        }
    }

    $recordedBootstraps = $Record.PSObject.Properties['BootstrapIdentities']
    if ($null -eq $recordedBootstraps) {
        $errors.Add('Preparation completion has no bootstrap identities.')
    }
    else {
        foreach ($expectedBootstrap in @(
            [pscustomobject]@{ Name = 'Base'; Value = $BaseBootstrap },
            [pscustomobject]@{ Name = 'Final'; Value = $FinalBootstrap }
        )) {
            $recordedProperty = $recordedBootstraps.Value.PSObject.Properties[$expectedBootstrap.Name]
            if ($null -eq $recordedProperty) {
                $errors.Add("Preparation completion has no $($expectedBootstrap.Name) bootstrap identity.")
                continue
            }
            $recorded = $recordedProperty.Value
            $expected = $expectedBootstrap.Value
            $rootMatches = try {
                [IO.Path]::GetFullPath([string]$recorded.Root).Equals(
                    [IO.Path]::GetFullPath([string]$expected.Root),
                    [StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $false
            }
            if (-not $rootMatches -or
                [string]$recorded.Commit -ne [string]$expected.ExpectedCommit -or
                [string]$recorded.MSBuildDllSha256 -ne [string]$expected.MSBuildDllSha256) {
                $errors.Add("Preparation completion $($expectedBootstrap.Name) bootstrap identity changed.")
            }
        }
    }

    $expectedRepositoryNames = @($RepositoryDefinitions.Name | Sort-Object)
    $recordedRepositories = @($Record.Repositories)
    $actualRepositoryNames = @($recordedRepositories.Name | ForEach-Object { [string]$_ } | Sort-Object)
    if (($expectedRepositoryNames -join '|') -ne ($actualRepositoryNames -join '|')) {
        $errors.Add("Preparation repositories '$($actualRepositoryNames -join ',')' do not match '$($expectedRepositoryNames -join ',')'.")
    }

    $expectedWorktreeNames = @((1..18 | ForEach-Object { "normal$_" }) + @('injected') | Sort-Object)
    foreach ($definition in $RepositoryDefinitions) {
        $repository = $recordedRepositories |
            Where-Object Name -eq $definition.Name |
            Select-Object -First 1
        if ($null -eq $repository) {
            continue
        }
        if (-not (ConvertTo-StrictBoolean -Value $repository.Restored) -or
            -not (ConvertTo-StrictBoolean -Value $repository.Warmed)) {
            $errors.Add("Preparation repository '$($definition.Name)' is not restored and warmed.")
        }
        $recordedIdentity = $repository.PSObject.Properties['Repository']
        if ($null -eq $recordedIdentity) {
            $errors.Add("Preparation repository '$($definition.Name)' has no source identity.")
        }
        else {
            $rootMatches = try {
                [IO.Path]::GetFullPath([string]$recordedIdentity.Value.Root).Equals(
                    [IO.Path]::GetFullPath([string]$definition.Root),
                    [StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $false
            }
            if (-not $rootMatches -or
                [string]$recordedIdentity.Value.ActualCommit -ne [string]$definition.Commit -or
                [string]$recordedIdentity.Value.ExpectedCommit -ne [string]$definition.Commit -or
                -not (ConvertTo-StrictBoolean -Value $recordedIdentity.Value.Clean) -or
                -not (ConvertTo-StrictBoolean -Value $recordedIdentity.Value.Verified)) {
                $errors.Add("Preparation repository '$($definition.Name)' source identity changed.")
            }
            $remote = $recordedIdentity.Value.PSObject.Properties['Remote']
            if ($null -eq $remote -or
                [string]$remote.Value.ExpectedUrl -ne [string]$definition.Repository -or
                -not (ConvertTo-StrictBoolean -Value $remote.Value.Verified)) {
                $errors.Add("Preparation repository '$($definition.Name)' remote identity is invalid.")
            }
        }
        if ([string]$repository.BuildPath -ne [string]$definition.BuildPath -or
            [string]$repository.TouchPath -ne [string]$definition.TouchPath) {
            $errors.Add("Preparation repository '$($definition.Name)' workload paths changed.")
        }
        $workRootMatches = try {
            [IO.Path]::GetFullPath([string]$repository.WorkRoot).Equals(
                [IO.Path]::GetFullPath([string]$definition.WorkRoot),
                [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
        if (-not $workRootMatches -or
            (@($repository.AdditionalBuildArguments) -join '|') -ne
                (@($definition.AdditionalBuildArguments) -join '|')) {
            $errors.Add("Preparation repository '$($definition.Name)' work root or build arguments changed.")
        }

        $worktrees = @($repository.Worktrees)
        $actualWorktreeNames = @($worktrees.Name | ForEach-Object { [string]$_ } | Sort-Object)
        if ($worktrees.Count -ne 19 -or
            ($actualWorktreeNames -join '|') -ne ($expectedWorktreeNames -join '|')) {
            $errors.Add("Preparation repository '$($definition.Name)' does not contain the exact 19 worktrees.")
            continue
        }
        foreach ($worktree in $worktrees) {
            $expectedPath = [IO.Path]::GetFullPath((Join-Path $definition.WorkRoot ([string]$worktree.Name)))
            $pathMatches = try {
                [IO.Path]::GetFullPath([string]$worktree.Path).Equals(
                    $expectedPath,
                    [StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $false
            }
            if (-not $pathMatches) {
                $errors.Add("Prepared worktree '$($definition.Name)/$($worktree.Name)' path changed.")
                continue
            }
            if ($null -eq $worktree.PSObject.Properties['Git'] -or
                [string]$worktree.Git.ActualCommit -ne [string]$definition.Commit -or
                [string]$worktree.Git.ExpectedCommit -ne [string]$definition.Commit -or
                -not (ConvertTo-StrictBoolean -Value $worktree.Git.Clean) -or
                -not (ConvertTo-StrictBoolean -Value $worktree.Git.Verified)) {
                $errors.Add("Prepared worktree '$($definition.Name)/$($worktree.Name)' recorded Git identity is invalid.")
            }
            $baseline = $worktree.PSObject.Properties['BaselineOutputIdentity']
            if ($null -eq $baseline -or
                [string]$baseline.Value.ContentSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
                [int]$baseline.Value.FileCount -le 0) {
                $errors.Add("Prepared worktree '$($definition.Name)/$($worktree.Name)' has no valid baseline output identity.")
                continue
            }
            if (-not $ValidateFileSystem) {
                continue
            }
            try {
                [void](Get-GitIdentity `
                    -Root $expectedPath `
                    -ExpectedCommit $definition.Commit `
                    -RequireClean)
                $trackedFiles = @(
                    Get-NativeOutput `
                        -FileName git `
                        -Arguments @('-C', $expectedPath, 'ls-files') `
                        -WorkingDirectory $expectedPath
                )
                $current = Get-ProjectOutputContentIdentity `
                    -Worktree $expectedPath `
                    -TrackedRelativePaths $trackedFiles
                $statusValidation = Test-GitStatusWithinProjectOutputs `
                    -Worktree $expectedPath `
                    -OutputDirectories @($current.OutputDirectories)
                if (-not $statusValidation.Valid) {
                    $unexpectedPaths = @(
                        $statusValidation.UnexpectedEntries |
                            ForEach-Object {
                                if ([string]::IsNullOrWhiteSpace([string]$_.RelativePath)) {
                                    [string]$_.Raw
                                }
                                else {
                                    [string]$_.RelativePath
                                }
                            }
                    )
                    $errors.Add(
                        "Prepared worktree '$($definition.Name)/$($worktree.Name)' has ignored or untracked state outside explicitly hashed/reset output roots: $($unexpectedPaths -join ', ').")
                }
                if ([string]$current.ContentSha256 -ne [string]$baseline.Value.ContentSha256 -or
                    [int]$current.FileCount -ne [int]$baseline.Value.FileCount -or
                    [int64]$current.TotalBytes -ne [int64]$baseline.Value.TotalBytes -or
                    (@($current.OutputDirectories) -join '|') -ne
                        (@($baseline.Value.OutputDirectories) -join '|')) {
                    $errors.Add("Prepared worktree '$($definition.Name)/$($worktree.Name)' baseline output identity changed.")
                }
            }
            catch {
                $errors.Add("Prepared worktree '$($definition.Name)/$($worktree.Name)' validation failed: $($_.Exception.Message)")
            }
        }

        if ($ValidateFileSystem) {
            try {
                [void](Get-GitIdentity `
                    -Root $definition.Root `
                    -ExpectedCommit $definition.Commit `
                    -RequireClean)
                [void](Get-GitRemoteIdentity `
                    -Root $definition.Root `
                    -RemoteName origin `
                    -ExpectedUrl $definition.Repository)
            }
            catch {
                $errors.Add("Preparation repository '$($definition.Name)' current identity failed: $($_.Exception.Message)")
            }
        }
    }

    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        RepositoryCount = $recordedRepositories.Count
        WorktreeCount = @($recordedRepositories | ForEach-Object { @($_.Worktrees).Count } | Measure-Object -Sum).Sum
    }
}

function Test-WorktreeResetCheckpointRecord {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Record,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Shape
    )

    $expectedNames = @(Get-ShapeWorktreeNames -Shape $Shape | Sort-Object)
    $actualNames = @($Record.AffectedWorktrees | ForEach-Object { [string]$_.Name } | Sort-Object)
    $errors = [Collections.Generic.List[string]]::new()
    if ($Record.Repository -ne $Repository -or $Record.Shape -ne $Shape) {
        $errors.Add('Reset checkpoint repository or shape does not match.')
    }
    if (-not $Record.Completed -or -not $Record.NoOverlap -or -not $Record.BaselineRestored) {
        $errors.Add('Reset checkpoint does not prove completion, no overlap, and baseline restoration.')
    }
    if ([string]$Record.PreparationSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        $errors.Add('Reset checkpoint does not identify the prepared baseline by SHA-256.')
    }
    foreach ($worktree in $Record.AffectedWorktrees) {
        if (-not $worktree.RestoreCompleted -or
            -not $worktree.WarmCompleted -or
            -not $worktree.BaselineOutputIdentityMatched -or
            $worktree.Retouched) {
            $errors.Add("Reset checkpoint worktree '$($worktree.Name)' was not restored/warmed without retouch.")
        }
    }
    if (($expectedNames -join '|') -ne ($actualNames -join '|')) {
        $errors.Add("Reset checkpoint worktrees '$($actualNames -join ',')' do not match '$($expectedNames -join ',')'.")
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        ExpectedWorktrees = $expectedNames
        ActualWorktrees = $actualNames
    }
}

function Get-RepositoryDefinition {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $repository = (Get-CampaignDefinition).Repositories |
        Where-Object Name -eq $Name |
        Select-Object -First 1
    if ($null -eq $repository) {
        throw "Unknown campaign repository '$Name'."
    }
    return $repository
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [int]$Depth = 12
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $temporaryPath = "$Path.incomplete-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        $Value |
            ConvertTo-Json -Depth $Depth |
            Set-Content -LiteralPath $temporaryPath -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-StrictBoolean {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    $parsed = $false
    if (-not [bool]::TryParse([string]$Value, [ref]$parsed)) {
        throw "Value '$Value' is not an exact Boolean."
    }
    return $parsed
}

function New-BlockRunIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Shape,
        [Parameter(Mandatory)]
        [string]$Repository,
        [Parameter(Mandatory)]
        [int]$BlockNumber,
        [Parameter(Mandatory)]
        [int]$AttemptNumber
    )

    return "$Shape|$Repository|block=$BlockNumber|attempt=$AttemptNumber"
}

function New-ScenarioRunIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Shape,
        [Parameter(Mandatory)]
        [string]$Repository,
        [Parameter(Mandatory)]
        [string]$Condition,
        [Parameter(Mandatory)]
        [int]$BlockNumber,
        [Parameter(Mandatory)]
        [int]$AttemptNumber,
        [Parameter(Mandatory)]
        [int]$OrderIndex
    )

    $blockIdentity = New-BlockRunIdentity `
        -Shape $Shape `
        -Repository $Repository `
        -BlockNumber $BlockNumber `
        -AttemptNumber $AttemptNumber
    return "$blockIdentity|order=$OrderIndex|condition=$Condition"
}

function Test-ScenarioEvidenceIdentity {
    param(
        [Parameter(Mandatory)]
        [object]$PlanRow,
        [Parameter(Mandatory)]
        [object]$BlockCompletion,
        [Parameter(Mandatory)]
        [object]$Validation,
        [Parameter(Mandatory)]
        [object]$Metrics
    )

    $errors = [Collections.Generic.List[string]]::new()
    try {
        $expected = [ordered]@{
            Shape = [string]$PlanRow.Shape
            Repository = [string]$PlanRow.Repository
            Condition = [string]$PlanRow.Condition
            BlockNumber = [int]$PlanRow.BlockNumber
            AnalysisBlockNumber = [int]$PlanRow.AnalysisBlockNumber
            IsWarmup = ConvertTo-StrictBoolean -Value $PlanRow.IsWarmup
            AttemptNumber = [int]$BlockCompletion.AttemptNumber
            OrderIndex = [int]$PlanRow.OrderIndex
        }
        $expectedBlockIdentity = New-BlockRunIdentity `
            -Shape $expected.Shape `
            -Repository $expected.Repository `
            -BlockNumber $expected.BlockNumber `
            -AttemptNumber $expected.AttemptNumber
        $expectedRunIdentity = New-ScenarioRunIdentity `
            -Shape $expected.Shape `
            -Repository $expected.Repository `
            -Condition $expected.Condition `
            -BlockNumber $expected.BlockNumber `
            -AttemptNumber $expected.AttemptNumber `
            -OrderIndex $expected.OrderIndex

        foreach ($field in @('Shape', 'Repository', 'BlockNumber', 'AnalysisBlockNumber', 'IsWarmup', 'AttemptNumber')) {
            $property = $BlockCompletion.PSObject.Properties[$field]
            if ($null -eq $property) {
                $errors.Add("Block completion is missing identity field '$field'.")
                continue
            }
            $actual = if ($field -eq 'IsWarmup') {
                ConvertTo-StrictBoolean -Value $property.Value
            }
            elseif ($field -in @('BlockNumber', 'AnalysisBlockNumber', 'AttemptNumber')) {
                [int]$property.Value
            }
            else {
                [string]$property.Value
            }
            if ($actual -ne $expected[$field]) {
                $errors.Add("Block completion $field '$actual' does not match plan '$($expected[$field])'.")
            }
        }
        $blockIdentityProperty = $BlockCompletion.PSObject.Properties['BlockRunIdentity']
        if ($null -eq $blockIdentityProperty -or
            [string]$blockIdentityProperty.Value -ne $expectedBlockIdentity) {
            $errors.Add("Block completion run identity does not match '$expectedBlockIdentity'.")
        }

        foreach ($artifact in @(
            [pscustomobject]@{ Name = 'validation'; Value = $Validation },
            [pscustomobject]@{ Name = 'metrics'; Value = $Metrics }
        )) {
            foreach ($field in $expected.Keys) {
                $property = $artifact.Value.PSObject.Properties[$field]
                if ($null -eq $property) {
                    $errors.Add("Scenario $($artifact.Name) is missing identity field '$field'.")
                    continue
                }
                $actual = if ($field -eq 'IsWarmup') {
                    ConvertTo-StrictBoolean -Value $property.Value
                }
                elseif ($field -in @('BlockNumber', 'AnalysisBlockNumber', 'AttemptNumber', 'OrderIndex')) {
                    [int]$property.Value
                }
                else {
                    [string]$property.Value
                }
                if ($actual -ne $expected[$field]) {
                    $errors.Add("Scenario $($artifact.Name) $field '$actual' does not match plan '$($expected[$field])'.")
                }
            }
            $runIdentityProperty = $artifact.Value.PSObject.Properties['RunIdentity']
            if ($null -eq $runIdentityProperty -or
                [string]$runIdentityProperty.Value -ne $expectedRunIdentity) {
                $errors.Add("Scenario $($artifact.Name) run identity does not match '$expectedRunIdentity'.")
            }
        }
    }
    catch {
        $errors.Add("Scenario identity could not be validated: $($_.Exception.Message)")
    }

    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
    }
}

function Write-ScenarioTerminalOutcome {
    param(
        [Parameter(Mandatory)]
        [string]$ScenarioRoot,
        [Parameter(Mandatory)]
        [string]$OutcomeType,
        [Parameter(Mandatory)]
        [string]$Disposition,
        [Parameter(Mandatory)]
        [string[]]$Errors
    )

    $path = Join-Path $ScenarioRoot 'scenario-terminal-outcome.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return Get-ScenarioTerminalOutcome -ScenarioRoot $ScenarioRoot
    }
    $record = [pscustomobject][ordered]@{
        SchemaVersion = 1
        EstablishedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        OutcomeType = $OutcomeType
        Disposition = $Disposition
        RetryAllowed = $false
        Errors = $Errors
    }
    Write-JsonAtomic -Path $path -Value $record
    return $record
}

function Get-ScenarioTerminalOutcome {
    param(
        [Parameter(Mandatory)]
        [string]$ScenarioRoot
    )

    $path = Join-Path $ScenarioRoot 'scenario-terminal-outcome.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([int]$record.SchemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$record.OutcomeType) -or
        [string]::IsNullOrWhiteSpace([string]$record.Disposition) -or
        (ConvertTo-StrictBoolean -Value $record.RetryAllowed)) {
        throw "Scenario terminal outcome '$path' is invalid."
    }
    [void](ConvertTo-UtcDateTimeOffset -Value $record.EstablishedUtc)
    return $record
}

function Get-InterruptedAttemptTerminalPromotion {
    param(
        [Parameter(Mandatory)]
        [string]$AttemptRoot,

        [Parameter(Mandatory)]
        [ValidateSet('Pilot', 'MeasuredBlock')]
        [string]$ResumeScope
    )

    if (-not (Test-Path -LiteralPath $AttemptRoot -PathType Container)) {
        return $null
    }
    $terminalPaths = @(
        Get-ChildItem `
            -LiteralPath $AttemptRoot `
            -Recurse `
            -File `
            -Filter 'scenario-terminal-outcome.json' `
            -ErrorAction Stop |
            Sort-Object FullName
    )
    if ($terminalPaths.Count -eq 0) {
        return $null
    }

    $outcomes = [Collections.Generic.List[object]]::new()
    foreach ($terminalPath in $terminalPaths) {
        $scenarioRoot = $terminalPath.DirectoryName
        $outcome = Get-ScenarioTerminalOutcome -ScenarioRoot $scenarioRoot
        $outcomes.Add([pscustomobject][ordered]@{
            Scenario = [IO.Path]::GetRelativePath($AttemptRoot, $scenarioRoot)
            OutcomeType = [string]$outcome.OutcomeType
            Disposition = [string]$outcome.Disposition
            RetryAllowed = $false
            Errors = @($outcome.Errors)
        })
    }

    $dispositions = @($outcomes.Disposition)
    $promotedDisposition = if ($dispositions -contains 'CampaignAbilityGateFailure') {
        'CampaignAbilityGateFailure'
    }
    elseif ($dispositions -contains 'TestedConditionPolicyOutcome') {
        'TestedConditionPolicyOutcome'
    }
    else {
        'NonRetryableHarnessFailure'
    }
    $promotionMarkerName = if ($ResumeScope -eq 'Pilot') {
        'pilot-nonretriable-failure.json'
    }
    else {
        switch ($promotedDisposition) {
            'CampaignAbilityGateFailure' { 'block-ability-gate-failure.json' }
            'TestedConditionPolicyOutcome' { 'block-policy-outcome.json' }
            default { 'block-nonretriable-harness-failure.json' }
        }
    }
    $errors = @(
        foreach ($outcome in $outcomes) {
            $detail = @($outcome.Errors) -join '; '
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = 'No terminal error detail was recorded.'
            }
            "$($outcome.Scenario): terminal disposition '$($outcome.Disposition)' ($($outcome.OutcomeType)): $detail"
        }
    )

    [pscustomobject][ordered]@{
        ResumeScope = $ResumeScope
        Disposition = $promotedDisposition
        RetryAllowed = $false
        PromotionMarkerName = $promotionMarkerName
        Errors = $errors
        TerminalOutcomes = $outcomes.ToArray()
    }
}

function Add-CommandJournalEntry {
    param(
        [Parameter(Mandatory)]
        [string]$JournalPath,

        [Parameter(Mandatory)]
        [object]$Entry
    )

    $parent = Split-Path -Parent $JournalPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $json = $Entry | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::AppendAllText(
        $JournalPath,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
}

function Invoke-RecordedCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$JournalPath,

        [Parameter(Mandatory)]
        [string]$Label,

        [string]$OutputDirectory,

        [hashtable]$Environment = @{},

        [switch]$AllowFailure
    )

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path (Split-Path -Parent $JournalPath) 'command-output'
    }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '-'
    $ordinal = @(
        Get-ChildItem -LiteralPath $OutputDirectory -Filter "$safeLabel-*.stdout.log" -ErrorAction SilentlyContinue
    ).Count + 1
    $stdoutPath = Join-Path $OutputDirectory "$safeLabel-$('{0:D3}' -f $ordinal).stdout.log"
    $stderrPath = Join-Path $OutputDirectory "$safeLabel-$('{0:D3}' -f $ordinal).stderr.log"
    $startedUtc = [DateTime]::UtcNow
    $startInfo = [Diagnostics.ProcessStartInfo]::new($FileName)
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($item in $Environment.GetEnumerator()) {
        if ($null -eq $item.Value) {
            [void]$startInfo.Environment.Remove([string]$item.Key)
        }
        else {
            $startInfo.Environment[[string]$item.Key] = [string]$item.Value
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $exitCode = $null
    $startError = $null
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($stdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderrPath, $stderr, [Text.UTF8Encoding]::new($false))
        $exitCode = $process.ExitCode
    }
    catch {
        $startError = $_.Exception.ToString()
        [IO.File]::WriteAllText($stdoutPath, '', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderrPath, $startError, [Text.UTF8Encoding]::new($false))
    }
    finally {
        $process.Dispose()
    }

    $entry = [pscustomobject][ordered]@{
        Label = $Label
        StartedUtc = $startedUtc.ToString('O')
        CompletedUtc = [DateTime]::UtcNow.ToString('O')
        FileName = $FileName
        Arguments = $Arguments
        WorkingDirectory = $WorkingDirectory
        EnvironmentOverrides = $Environment
        ExitCode = $exitCode
        StartError = $startError
        Stdout = $stdoutPath
        Stderr = $stderrPath
    }
    Add-CommandJournalEntry -JournalPath $JournalPath -Entry $entry
    if (($null -ne $startError -or $exitCode -ne 0) -and -not $AllowFailure) {
        $failureKind = if ($null -eq $exitCode) { 'failed to start' } else { "failed with exit code $exitCode" }
        throw "'$Label' $failureKind. See '$stderrPath'."
    }
    return $entry
}

function Get-NativeOutput {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        $output = @(& $FileName @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0) {
        throw "'$FileName $($Arguments -join ' ')' failed with exit code $exitCode`: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-ExactBootstrapBuildArguments {
    return @(
        '-configuration', 'Release',
        '-msbuildEngine', 'dotnet',
        '-verbosity', 'quiet',
        '/p:CreateTlb=false',
        '/p:RuntimeOutputTargetFrameworks=net11.0'
    )
}

function Get-GrantReplayBuildArguments {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,
        [Parameter(Mandatory)]
        [string]$ScannerRoot,
        [Parameter(Mandatory)]
        [string]$MSBuildAssembliesRoot
    )

    $intermediateRoot = Join-Path $ScannerRoot 'intermediate'
    $baseIntermediate = "$([IO.Path]::GetFullPath($intermediateRoot).TrimEnd('\'))\"
    return @(
        'build',
        [IO.Path]::GetFullPath($ProjectPath),
        '--configuration', 'Release',
        '--output', [IO.Path]::GetFullPath($ScannerRoot),
        '--nologo',
        '/v:q',
        "/p:MSBuildAssembliesRoot=$([IO.Path]::GetFullPath($MSBuildAssembliesRoot))",
        "/p:MSBuildProjectExtensionsPath=$($baseIntermediate)project-extensions\",
        "/p:BaseIntermediateOutputPath=$baseIntermediate",
        "/p:IntermediateOutputPath=$($baseIntermediate)configuration\"
    )
}

function Get-ImmutableBootstrapStageCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$StagingRoot,

        [Parameter(Mandatory)]
        [string]$ExpectedCommit
    )

    if ($ExpectedCommit.Length -lt 12) {
        throw 'Expected bootstrap commit must contain at least 12 characters.'
    }
    if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
        return @()
    }
    return @(
        Get-ChildItem -LiteralPath $StagingRoot -Directory -Filter "$($ExpectedCommit.Substring(0, 12))-*" |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'core') -PathType Container) -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'staging-metadata.json') -PathType Leaf)
            }
    )
}

function Assert-FreeDiskSpace {
    param(
        [string]$Path = 'C:\',
        [int]$MinimumGiB = 20,
        [string]$RecordPath
    )

    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    $drive = [IO.DriveInfo]::new($root)
    $freeGiB = $drive.AvailableFreeSpace / 1GB
    $record = [pscustomobject][ordered]@{
        CheckedUtc = [DateTime]::UtcNow.ToString('O')
        Root = $root
        AvailableBytes = $drive.AvailableFreeSpace
        AvailableGiB = [Math]::Round($freeGiB, 3)
        RequiredGiB = $MinimumGiB
        Passed = $freeGiB -ge $MinimumGiB
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordPath)) {
        Write-JsonAtomic -Path $RecordPath -Value $record
    }
    if (-not $record.Passed) {
        throw "Disk guard failed: $($record.AvailableGiB) GiB available on '$root'; at least $MinimumGiB GiB is required."
    }
    return $record
}

function Get-MeasuredWorktreeDiskProjection {
    param(
        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [int64]$FirstRestoredWarmWorktreeBytes,

        [Parameter(Mandatory)]
        [ValidateRange(1, 19)]
        [int]$ExistingCampaignWorktreeCount,

        [Parameter(Mandatory)]
        [int64]$AvailableBytesBeforeExpansion,

        [int]$TargetWorktreeCount = 19,

        [int]$RawResultsReserveGiB = 25
    )

    if ($FirstRestoredWarmWorktreeBytes -le 0) {
        throw 'The first restored/warm project worktree must have a positive measured size.'
    }
    if ($TargetWorktreeCount -ne 19) {
        throw 'The lean sustained design requires exactly 19 project worktrees per repository.'
    }
    $missing = $TargetWorktreeCount - $ExistingCampaignWorktreeCount
    $projectedAdditional = [int64]$FirstRestoredWarmWorktreeBytes * $missing
    $rawReserve = [int64]$RawResultsReserveGiB * 1GB
    $required = $projectedAdditional + $rawReserve
    [pscustomobject][ordered]@{
        CheckedUtc = [DateTime]::UtcNow.ToString('O')
        Repository = $Repository
        WorkloadKind = 'representative-propagated-project'
        FirstRestoredWarmWorktreeBytes = $FirstRestoredWarmWorktreeBytes
        FirstRestoredWarmWorktreeGiB = $FirstRestoredWarmWorktreeBytes / 1GB
        ExistingCampaignWorktreeCount = $ExistingCampaignWorktreeCount
        MissingCampaignWorktreeCount = $missing
        TargetCampaignWorktreeCount = $TargetWorktreeCount
        ProjectedNineteenWorktreeBytes =
            [int64]$FirstRestoredWarmWorktreeBytes * $TargetWorktreeCount
        ProjectedAdditionalBytes = $projectedAdditional
        RawResultsReserveBytes = $rawReserve
        RequiredAvailableBytesBeforeExpansion = $required
        ActualAvailableBytesBeforeExpansion = $AvailableBytesBeforeExpansion
        Passed = $AvailableBytesBeforeExpansion -ge $required
    }
}

function Get-GitIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$ExpectedCommit,

        [switch]$RequireClean,

        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        if ($AllowMissing) {
            return [pscustomobject][ordered]@{
                Root = $Root
                ExpectedCommit = $ExpectedCommit
                ActualCommit = $null
                Clean = $null
                Verified = $false
                Deferred = $true
            }
        }
        throw "Git root '$Root' does not exist."
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $commit = @(
        Get-NativeOutput -FileName git -Arguments @('-C', $resolvedRoot, 'rev-parse', 'HEAD') -WorkingDirectory $resolvedRoot
    )[0].Trim()
    $status = @(Get-NativeOutput -FileName git -Arguments @('-C', $resolvedRoot, 'status', '--porcelain=v1', '--untracked-files=no') -WorkingDirectory $resolvedRoot)
    $clean = @($status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
    if (-not $commit.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Git root '$resolvedRoot' is at '$commit'; expected '$ExpectedCommit'."
    }
    if ($RequireClean -and -not $clean) {
        throw "Git root '$resolvedRoot' has tracked changes."
    }
    [pscustomobject][ordered]@{
        Root = $resolvedRoot
        ExpectedCommit = $ExpectedCommit
        ActualCommit = $commit
        Clean = $clean
        Verified = $true
        Deferred = $false
    }
}

function Get-GitRemoteIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RemoteName,

        [Parameter(Mandatory)]
        [string]$ExpectedUrl
    )

    $actualUrl = @(
        Get-NativeOutput `
            -FileName git `
            -Arguments @('-C', $Root, 'remote', 'get-url', $RemoteName) `
            -WorkingDirectory $Root
    )[0].Trim()
    $normalize = {
        param([string]$Url)

        $value = $Url.Trim().TrimEnd('/')
        $value = $value -replace '\.git$', ''
        $value = $value -replace '^https?://', ''
        $value = $value -replace '^ssh://git@', ''
        $value = $value -replace '^git@([^:]+):', '$1/'
        return $value.ToLowerInvariant()
    }
    $actualIdentity = & $normalize $actualUrl
    $expectedIdentity = & $normalize $ExpectedUrl
    if ($actualIdentity -ne $expectedIdentity) {
        throw "Remote '$RemoteName' under '$Root' is '$actualUrl'; expected '$ExpectedUrl'."
    }
    [pscustomobject][ordered]@{
        Name = $RemoteName
        Url = $actualUrl
        NormalizedIdentity = $actualIdentity
        ExpectedUrl = $ExpectedUrl
        Verified = $true
    }
}

function Get-BootstrapIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Role,

        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$ExpectedCommit,

        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        if ($AllowMissing) {
            return [pscustomobject][ordered]@{
                Role = $Role
                Root = $Root
                ExpectedCommit = $ExpectedCommit
                Verified = $false
                Deferred = $true
            }
        }
        throw "$Role bootstrap root '$Root' does not exist."
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $dotnetPath = Join-Path $resolvedRoot 'dotnet.exe'
    $sdk = Get-ChildItem -LiteralPath (Join-Path $resolvedRoot 'sdk') -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not (Test-Path -LiteralPath $dotnetPath -PathType Leaf) -or $null -eq $sdk) {
        throw "$Role bootstrap '$resolvedRoot' is incomplete."
    }
    $msbuildPath = Join-Path $sdk.FullName 'MSBuild.dll'
    if (-not (Test-Path -LiteralPath $msbuildPath -PathType Leaf)) {
        throw "$Role bootstrap is missing '$msbuildPath'."
    }
    $version = (Get-Item -LiteralPath $msbuildPath).VersionInfo
    if (-not $version.ProductVersion.Contains($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Role ProductVersion '$($version.ProductVersion)' does not contain '$ExpectedCommit'."
    }

    $trackedPaths = [Collections.Generic.List[string]]::new()
    $trackedPaths.Add($dotnetPath)
    foreach ($name in @('MSBuild.dll', 'Microsoft.Build.dll', 'Microsoft.Build.Framework.dll')) {
        $path = Join-Path $sdk.FullName $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$Role bootstrap tracked binary '$path' is missing."
        }
        $trackedPaths.Add($path)
    }
    $coordinatorPaths = @(
        Get-ChildItem -LiteralPath $sdk.FullName -File |
            Where-Object Name -like '*Coordinator*' |
            Sort-Object Name
    )
    if (@($coordinatorPaths | Where-Object Name -eq 'MSBuild.Coordinator.dll').Count -ne 1) {
        throw "$Role bootstrap must contain exactly one MSBuild.Coordinator.dll."
    }
    foreach ($file in $coordinatorPaths) {
        $trackedPaths.Add($file.FullName)
    }
    $trackedFiles = @(
        foreach ($path in $trackedPaths | Select-Object -Unique) {
            [pscustomobject][ordered]@{
                Name = [IO.Path]::GetFileName($path)
                RelativePath = [IO.Path]::GetRelativePath($resolvedRoot, $path)
                Path = $path
                Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
        }
    )

    $oldDotNetRoot = $env:DOTNET_ROOT
    $oldDotNetRootX64 = $env:DOTNET_ROOT_X64
    $oldTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
    try {
        $env:DOTNET_ROOT = $resolvedRoot
        $env:DOTNET_ROOT_X64 = $resolvedRoot
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        $dotnetInfo = @(Get-NativeOutput -FileName $dotnetPath -Arguments @('--info') -WorkingDirectory $resolvedRoot)
    }
    finally {
        $env:DOTNET_ROOT = $oldDotNetRoot
        $env:DOTNET_ROOT_X64 = $oldDotNetRootX64
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldTelemetry
    }

    [pscustomobject][ordered]@{
        Role = $Role
        Root = $resolvedRoot
        ExpectedCommit = $ExpectedCommit
        Verified = $true
        Deferred = $false
        DotNetPath = $dotnetPath
        SdkVersion = $sdk.Name
        SdkRoot = $sdk.FullName
        MSBuildDllPath = $msbuildPath
        ProductVersion = $version.ProductVersion
        FileVersion = $version.FileVersion
        DotNetSha256 = ($trackedFiles | Where-Object Name -eq 'dotnet.exe' | Select-Object -First 1).Sha256
        MSBuildDllSha256 = ($trackedFiles | Where-Object Name -eq 'MSBuild.dll' | Select-Object -First 1).Sha256
        TrackedFiles = $trackedFiles
        DotNetInfo = $dotnetInfo
    }
}

function Get-DirectoryContentManifest {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $files = @(
        Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    RelativePath = [IO.Path]::GetRelativePath($resolvedRoot, $_.FullName)
                    Bytes = $_.Length
                    Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                }
            }
    )
    if ($files.Count -eq 0) {
        throw "Directory '$resolvedRoot' has no files to content-address."
    }
    $builder = [Text.StringBuilder]::new()
    foreach ($file in $files) {
        [void]$builder.Append($file.RelativePath.Replace('\', '/'))
        [void]$builder.Append([char]0)
        [void]$builder.Append($file.Bytes)
        [void]$builder.Append([char]0)
        [void]$builder.Append($file.Sha256)
        [void]$builder.Append("`n")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $contentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    [pscustomobject][ordered]@{
        Root = $resolvedRoot
        FileCount = $files.Count
        TotalBytes = ($files | Measure-Object Bytes -Sum).Sum
        ContentSha256 = $contentHash
        Files = $files
    }
}

function Test-ImmutableBootstrapStage {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$RecordPath
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $metadataPath = Join-Path (Split-Path -Parent $resolvedRoot) 'staging-metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Immutable bootstrap '$resolvedRoot' has no staging metadata."
    }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $actual = Get-DirectoryContentManifest -Root $resolvedRoot
    $valid = $actual.ContentSha256 -eq $metadata.ContentSha256 -and
        $actual.FileCount -eq [int]$metadata.FileCount -and
        [int64]$actual.TotalBytes -eq [int64]$metadata.TotalBytes
    $result = [pscustomobject][ordered]@{
        CheckedUtc = [DateTime]::UtcNow.ToString('O')
        Root = $resolvedRoot
        MetadataPath = $metadataPath
        ExpectedContentSha256 = $metadata.ContentSha256
        ActualContentSha256 = $actual.ContentSha256
        ExpectedFileCount = [int]$metadata.FileCount
        ActualFileCount = $actual.FileCount
        ExpectedTotalBytes = [int64]$metadata.TotalBytes
        ActualTotalBytes = [int64]$actual.TotalBytes
        Valid = $valid
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordPath)) {
        Write-JsonAtomic -Path $RecordPath -Value $result
    }
    if (-not $valid) {
        throw "Immutable bootstrap '$resolvedRoot' no longer matches its complete content identity."
    }
    return $result
}

function Publish-ImmutableBootstrap {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Identity,

        [Parameter(Mandatory)]
        [string]$StagingRoot
    )

    if (-not $Identity.Verified) {
        throw "Cannot stage unverified $($Identity.Role) bootstrap."
    }
    $sourceManifest = Get-DirectoryContentManifest -Root $Identity.Root
    $key = '{0}-{1}' -f $Identity.ExpectedCommit.Substring(0, 12), $sourceManifest.ContentSha256.Substring(0, 12)
    $parent = Join-Path $StagingRoot $key
    $destination = Join-Path $parent 'core'
    $metadataPath = Join-Path $parent 'staging-metadata.json'
    New-Item -ItemType Directory -Force -Path $StagingRoot | Out-Null
    $lockPath = Join-Path $StagingRoot "$key.lock"
    $lock = $null
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if (-not (Test-Path -LiteralPath $parent)) {
            $temporaryParent = "$parent.incomplete-$PID-$([guid]::NewGuid().ToString('N'))"
            $temporaryDestination = Join-Path $temporaryParent 'core'
            try {
                New-Item -ItemType Directory -Force -Path $temporaryDestination | Out-Null
                & robocopy $Identity.Root $temporaryDestination /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) {
                    throw "Robocopy failed while staging $($Identity.Role) with exit code $LASTEXITCODE."
                }
                Write-JsonAtomic -Path (Join-Path $temporaryParent 'staging-metadata.json') -Value ([pscustomobject][ordered]@{
                    SchemaVersion = 1
                    CreatedUtc = [DateTime]::UtcNow.ToString('O')
                    Role = $Identity.Role
                    ExpectedCommit = $Identity.ExpectedCommit
                    ProductVersion = $Identity.ProductVersion
                    SourceRoot = $Identity.Root
                    ContentKey = $key
                    ContentSha256 = $sourceManifest.ContentSha256
                    FileCount = $sourceManifest.FileCount
                    TotalBytes = $sourceManifest.TotalBytes
                    Files = $sourceManifest.Files
                    TrackedIdentityFiles = $Identity.TrackedFiles
                }) -Depth 10
                Move-Item -LiteralPath $temporaryParent -Destination $parent
            }
            finally {
                Remove-Item -LiteralPath $temporaryParent -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not (Test-Path -LiteralPath $destination -PathType Container) -or
            -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            throw "Immutable stage '$parent' is incomplete and will not be mutated."
        }
        $stagingMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        if ($stagingMetadata.ContentSha256 -ne $sourceManifest.ContentSha256 -or
            [int]$stagingMetadata.FileCount -ne $sourceManifest.FileCount) {
            throw "Immutable stage '$parent' metadata does not match the complete source content."
        }
        $stagedFiles = @(Get-ChildItem -LiteralPath $destination -Recurse -File)
        if ($stagedFiles.Count -ne $sourceManifest.FileCount) {
            throw "Immutable stage '$destination' contains $($stagedFiles.Count) files; expected $($sourceManifest.FileCount)."
        }
        foreach ($file in $sourceManifest.Files) {
            $path = Join-Path $destination $file.RelativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Immutable stage is missing '$path'."
            }
            $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ((Get-Item -LiteralPath $path).Length -ne $file.Bytes -or $actualHash -ne $file.Sha256) {
                throw "Immutable stage hash mismatch for '$path'."
            }
        }
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
    $stagedIdentity = Get-BootstrapIdentity -Role $Identity.Role -Root $destination -ExpectedCommit $Identity.ExpectedCommit
    $stagedIdentity | Add-Member -NotePropertyName StagingContentSha256 -NotePropertyValue $sourceManifest.ContentSha256
    $stagedIdentity | Add-Member -NotePropertyName StagingContentKey -NotePropertyValue $key
    $stagedIdentity | Add-Member -NotePropertyName StagingMetadataPath -NotePropertyValue $metadataPath
    return $stagedIdentity
}

function Get-WilliamsDesign {
    param(
        [Parameter(Mandatory)]
        [string[]]$Items
    )

    if ($Items.Count -eq 0) {
        throw 'A Williams design requires at least one item.'
    }
    if (@($Items | Sort-Object -Unique).Count -ne $Items.Count) {
        throw 'Williams design items must be unique.'
    }
    if ($Items.Count -eq 1) {
        return ,([pscustomobject]@{ DesignRow = 0; Items = @($Items) })
    }
    $first = [Collections.Generic.List[int]]::new()
    $first.Add(0)
    for ($position = 1; $position -lt $Items.Count; $position++) {
        $index = if (($position % 2) -eq 1) {
            [int](($position + 1) / 2)
        }
        else {
            $Items.Count - [int]($position / 2)
        }
        $first.Add($index)
    }
    $orders = [Collections.Generic.List[object]]::new()
    for ($shift = 0; $shift -lt $Items.Count; $shift++) {
        $orders.Add([pscustomobject]@{
            DesignRow = $orders.Count
            Items = @($first | ForEach-Object { $Items[($_ + $shift) % $Items.Count] })
        })
    }
    if (($Items.Count % 2) -eq 1) {
        for ($row = 0; $row -lt $Items.Count; $row++) {
            $orders.Add([pscustomobject]@{
                DesignRow = $orders.Count
                Items = @($orders[$row].Items[($Items.Count - 1)..0])
            })
        }
    }
    return $orders.ToArray()
}

function Get-CampaignShapeOrders {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('isolated', 'sustained')]
        [string]$Shape
    )

    $shapeDefinition = Get-ShapeDefinition -Key $Shape
    $design = @(Get-WilliamsDesign -Items $shapeDefinition.Conditions)
    $rowIndexes = if ($Shape -eq 'isolated') {
        @(0, 1, 2, 3, 4, 5)
    }
    elseif ($Shape -eq 'sustained') {
        @(0, 1, 2, 3)
    }
    if ($rowIndexes.Count -ne $shapeDefinition.MeasuredBlocks) {
        throw "Internal schedule error for '$Shape'."
    }
    @(
        for ($index = 0; $index -lt $rowIndexes.Count; $index++) {
            $designRow = $design[$rowIndexes[$index]]
            [pscustomobject][ordered]@{
                BlockNumber = $index + 2
                AnalysisBlockNumber = $index + 1
                IsWarmup = $false
                DesignRow = $designRow.DesignRow
                Items = @($designRow.Items)
            }
        }
    )
}

function Get-OrderDiagnostics {
    param(
        [Parameter(Mandatory)]
        [object[]]$Orders,

        [Parameter(Mandatory)]
        [string[]]$Items
    )

    $positionCounts = @{}
    $carryoverCounts = @{}
    foreach ($item in $Items) {
        $positionCounts[$item] = [int[]]::new($Items.Count)
        foreach ($next in $Items) {
            if ($next -ne $item) {
                $carryoverCounts["$item->$next"] = 0
            }
        }
    }
    foreach ($orderRecord in $Orders) {
        $order = @($orderRecord.Items)
        if ($order.Count -ne $Items.Count -or @($order | Sort-Object -Unique).Count -ne $Items.Count) {
            throw "Invalid order '$($order -join ',')'."
        }
        for ($position = 0; $position -lt $order.Count; $position++) {
            $positionCounts[$order[$position]][$position]++
            if ($position -gt 0) {
                $carryoverCounts["$($order[$position - 1])->$($order[$position])"]++
            }
        }
    }
    $positionValues = [int[]]@($positionCounts.Values | ForEach-Object { $_ })
    $carryoverValues = [int[]]@($carryoverCounts.Values)
    [pscustomobject][ordered]@{
        PositionCounts = $positionCounts
        CarryoverCounts = $carryoverCounts
        PositionImbalance = ($positionValues | Measure-Object -Maximum).Maximum -
            ($positionValues | Measure-Object -Minimum).Minimum
        CarryoverImbalance = ($carryoverValues | Measure-Object -Maximum).Maximum -
            ($carryoverValues | Measure-Object -Minimum).Minimum
    }
}

function New-CampaignPlan {
    $definition = Get-CampaignDefinition
    $rows = [Collections.Generic.List[object]]::new()
    $diagnostics = [ordered]@{}
    foreach ($shape in $definition.Shapes) {
        $design = @(Get-WilliamsDesign -Items $shape.Conditions)
        $warmupOrder = $design[0]
        foreach ($repository in $definition.Repositories) {
            for ($position = 0; $position -lt $warmupOrder.Items.Count; $position++) {
                $rows.Add([pscustomobject][ordered]@{
                    Shape = $shape.Key
                    Repository = $repository.Name
                    BlockNumber = 1
                    AnalysisBlockNumber = 0
                    IsWarmup = $true
                    DesignRow = $warmupOrder.DesignRow
                    OrderIndex = $position + 1
                    Condition = $warmupOrder.Items[$position]
                })
            }
            foreach ($order in @(Get-CampaignShapeOrders -Shape $shape.Key)) {
                for ($position = 0; $position -lt $order.Items.Count; $position++) {
                    $rows.Add([pscustomobject][ordered]@{
                        Shape = $shape.Key
                        Repository = $repository.Name
                        BlockNumber = $order.BlockNumber
                        AnalysisBlockNumber = $order.AnalysisBlockNumber
                        IsWarmup = $false
                        DesignRow = $order.DesignRow
                        OrderIndex = $position + 1
                        Condition = $order.Items[$position]
                    })
                }
            }
        }
        $orders = @(Get-CampaignShapeOrders -Shape $shape.Key)
        $diagnostics[$shape.Key] = Get-OrderDiagnostics -Orders $orders -Items $shape.Conditions
    }
    [pscustomobject][ordered]@{
        Rows = $rows.ToArray()
        Diagnostics = [pscustomobject]$diagnostics
    }
}

function Get-LeanCampaignProjection {
    param(
        [Parameter(Mandatory)]
        [object[]]$RepositoryTimings,

        [Parameter(Mandatory)]
        [double]$SetupElapsedSeconds
    )

    $campaign = Get-CampaignDefinition
    $requiredConditions = @('BASE', 'FINAL-N', 'FINAL-H')
    $expectedPilotCount = $campaign.Repositories.Count * $requiredConditions.Count
    if ($RepositoryTimings.Count -ne $expectedPilotCount) {
        throw "Runtime projection requires BASE, FINAL-N, and FINAL-H sustained pilots per repository; found $($RepositoryTimings.Count), expected $expectedPilotCount."
    }
    $isolated = Get-ShapeDefinition -Key isolated
    $sustained = Get-ShapeDefinition -Key sustained
    $isolatedScenarios =
        ($isolated.WarmupBlocks + $isolated.MeasuredBlocks) * $isolated.Conditions.Count
    $sustainedScenarios =
        ($sustained.WarmupBlocks + $sustained.MeasuredBlocks) * $sustained.Conditions.Count
    $conditionScenarios = $isolatedScenarios + $sustainedScenarios
    $projectedMatrixSeconds = 0.0
    $abilityProjectionPassed = $true
    $repositoryUpperBounds = [Collections.Generic.List[object]]::new()
    foreach ($repository in $campaign.Repositories) {
        $repositoryPilots = @($RepositoryTimings | Where-Object Repository -eq $repository.Name)
        if ($repositoryPilots.Count -ne $requiredConditions.Count -or
            @($repositoryPilots.Condition | Sort-Object -Unique).Count -ne $requiredConditions.Count) {
            throw "Runtime projection pilots for '$($repository.Name)' do not contain exactly BASE, FINAL-N, and FINAL-H."
        }
        foreach ($condition in $requiredConditions) {
            if ($repositoryPilots.Condition -notcontains $condition) {
                throw "Runtime projection pilot '$($repository.Name)/$condition' is missing."
            }
        }
        foreach ($pilot in $repositoryPilots) {
            if ([double]$pilot.TotalWallSeconds -le 0 -or
                [int]$pilot.MeasuredNormalCompletions -ne $campaign.Validity.SustainedEndingCompletion -or
                [double]$pilot.SteadyWindowSeconds -gt ($campaign.Validity.SustainedTimeoutMinutes * 60)) {
                $abilityProjectionPassed = $false
            }
        }
        $basePilot = $repositoryPilots | Where-Object Condition -eq BASE | Select-Object -First 1
        $finalNormalPilot = $repositoryPilots | Where-Object Condition -eq 'FINAL-N' | Select-Object -First 1
        $finalHighPilot = $repositoryPilots | Where-Object Condition -eq 'FINAL-H' | Select-Object -First 1
        $baseObservedWall = [double]$basePilot.TotalWallSeconds
        $finalNormalObservedWall = [double]$finalNormalPilot.TotalWallSeconds
        $finalHighObservedWall = [double]$finalHighPilot.TotalWallSeconds
        $baseWall = $baseObservedWall * $campaign.RuntimeProjectionSafetyFactor
        $finalNormalWall = $finalNormalObservedWall * $campaign.RuntimeProjectionSafetyFactor
        $finalHighWall = $finalHighObservedWall * $campaign.RuntimeProjectionSafetyFactor
        $compatUpperWall = [Math]::Max($baseWall, [Math]::Max($finalNormalWall, $finalHighWall))
        $repositoryProjectedSeconds =
            (12 * $baseWall) +
            (12 * $finalNormalWall) +
            (5 * $finalHighWall) +
            (12 * $compatUpperWall) +
            ($conditionScenarios * $campaign.Validity.CooldownSeconds)
        $projectedMatrixSeconds += $repositoryProjectedSeconds
        $repositoryUpperBounds.Add([pscustomobject][ordered]@{
            Repository = $repository.Name
            RuntimeSafetyFactor = $campaign.RuntimeProjectionSafetyFactor
            BaseObservedPilotWallSeconds = $baseObservedWall
            FinalNormalObservedPilotWallSeconds = $finalNormalObservedWall
            FinalHighObservedPilotWallSeconds = $finalHighObservedWall
            BaseScenarioUpperBoundSeconds = $baseWall
            FinalNormalScenarioUpperBoundSeconds = $finalNormalWall
            FinalHighScenarioUpperBoundSeconds = $finalHighWall
            CompatScenarioUpperBoundSeconds = $compatUpperWall
            ProjectedMatrixSeconds = $repositoryProjectedSeconds
        })
    }
    $projectedTotalSeconds = $SetupElapsedSeconds + $projectedMatrixSeconds
    [pscustomobject][ordered]@{
        IsolatedScenariosPerRepository = $isolatedScenarios
        SustainedScenariosPerRepository = $sustainedScenarios
        ConditionScenariosPerRepository = $conditionScenarios
        RequiredPilotConditions = $requiredConditions
        PilotCount = $RepositoryTimings.Count
        RepositoryUpperBounds = $repositoryUpperBounds.ToArray()
        SetupElapsedSeconds = $SetupElapsedSeconds
        ProjectedMatrixSeconds = $projectedMatrixSeconds
        ProjectedTotalSeconds = $projectedTotalSeconds
        ProjectedTotalHours = $projectedTotalSeconds / 3600.0
        MaximumProjectedCampaignHours = $campaign.MaximumProjectedCampaignHours
        RuntimeProjectionPassed =
            ($projectedTotalSeconds / 3600.0) -le $campaign.MaximumProjectedCampaignHours
        SustainedAbilityProjectionPassed = $abilityProjectionPassed
        Passed =
            (($projectedTotalSeconds / 3600.0) -le $campaign.MaximumProjectedCampaignHours) -and
            $abilityProjectionPassed
    }
}

function New-ConditionEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$Condition,

        [Parameter(Mandatory)]
        [string]$PipeName,

        [Parameter(Mandatory)]
        [string]$DotNetRoot,

        [switch]$Injected,

        [switch]$EnableDebugTrace,

        [string]$DebugPath
    )

    $definition = Get-ConditionDefinition -Key $Condition
    $environment = [ordered]@{}
    foreach ($name in $script:CoordinatorEnvironmentVariables) {
        $environment[$name] = $null
    }
    $environment['DOTNET_ROOT'] = $DotNetRoot
    $environment['DOTNET_ROOT_X64'] = $DotNetRoot
    $environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
    $environment['PATH'] = "$DotNetRoot$([IO.Path]::PathSeparator)$([Environment]::GetEnvironmentVariable('PATH', 'Process'))"
    $environment['MSBUILDUSECOORDINATOR'] = '1'
    $environment['MSBUILDCOORDINATORPIPENAME'] = $PipeName
    $environment['MSBUILDCOORDINATORNODEBUDGET'] = '16'
    if ($null -ne $definition.Reservation) {
        $environment['MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES'] = [string]$definition.Reservation
    }
    if ($null -ne $definition.MaximumNodes) {
        $environment['MSBUILDCOORDINATORMAXNODESPERBUILD'] = [string]$definition.MaximumNodes
    }
    if ($definition.BootstrapRole -eq 'final') {
        $environment['MSBUILDCOORDINATORPRIORITYAGINGTHRESHOLD'] = '3'
        $environment['MSBUILDCOORDINATORBUILDREQUESTPRIORITY'] =
            if ($Condition -eq 'FINAL-H' -and $Injected) { 'High' } else { 'Normal' }
    }
    if ($EnableDebugTrace) {
        if ([string]::IsNullOrWhiteSpace($DebugPath)) {
            throw 'DebugPath is required when Coordinator debug tracing is enabled.'
        }
        $environment['MSBUILDDEBUGCOMM'] = '1'
        $environment['MSBUILDDEBUGPATH'] = $DebugPath
    }
    return $environment
}

function Get-EnvironmentContractRecord {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Environment
    )

    $names = @(
        $script:CoordinatorEnvironmentVariables +
            @('DOTNET_ROOT', 'DOTNET_ROOT_X64', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'PATH') |
            Sort-Object -Unique
    )
    @(
        foreach ($name in $names) {
            $value = if ($Environment.Contains($name)) { $Environment[$name] } else { $null }
            [pscustomobject][ordered]@{
                Name = $name
                Present = $null -ne $value
                Value = $value
            }
        }
    )
}

function Assert-ConditionEnvironmentContract {
    param(
        [Parameter(Mandatory)]
        [string]$Condition,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Environment,

        [switch]$Injected
    )

    $get = {
        param([string]$Name)
        if ($Environment.Contains($Name)) {
            return $Environment[$Name]
        }
        return $null
    }
    if ((& $get 'MSBUILDUSECOORDINATOR') -ne '1' -or
        (& $get 'MSBUILDCOORDINATORNODEBUDGET') -ne '16') {
        throw "$Condition does not have the required Coordinator enablement and node budget."
    }
    $dotnetRoot = & $get 'DOTNET_ROOT'
    if ([string]::IsNullOrWhiteSpace($dotnetRoot) -or
        (& $get 'DOTNET_ROOT_X64') -ne $dotnetRoot -or
        -not ([string](& $get 'PATH')).StartsWith(
            "$dotnetRoot$([IO.Path]::PathSeparator)",
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Condition does not have matching DOTNET roots first on PATH."
    }
    $reservation = & $get 'MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES'
    $maximum = & $get 'MSBUILDCOORDINATORMAXNODESPERBUILD'
    $priority = & $get 'MSBUILDCOORDINATORBUILDREQUESTPRIORITY'
    switch ($Condition) {
        'BASE' {
            if ($null -ne $reservation -or $null -ne $maximum -or $null -ne $priority) {
                throw 'BASE must have genuine reservation, cap, and priority environment absence.'
            }
        }
        'COMPAT' {
            if ($reservation -ne '0' -or $maximum -ne '0' -or $priority -ne 'Normal') {
                throw 'COMPAT must explicitly set reservation=0, max=0, and Normal priority.'
            }
        }
        'FINAL-N' {
            if ($null -ne $reservation -or $null -ne $maximum -or $priority -ne 'Normal') {
                throw 'FINAL-N must have genuine reservation/max absence and Normal priority.'
            }
        }
        'FINAL-H' {
            $expectedPriority = if ($Injected) { 'High' } else { 'Normal' }
            if ($null -ne $reservation -or $null -ne $maximum -or $priority -ne $expectedPriority) {
                throw "FINAL-H must have genuine reservation/max absence and $expectedPriority priority for this request."
            }
        }
    }
}

function New-BuildArguments {
    param(
        [Parameter(Mandatory)]
        [string]$MSBuildDllPath,

        [Parameter(Mandatory)]
        [string]$BuildPath,

        [string]$BinlogPath,

        [switch]$Restore,

        [string[]]$AdditionalArguments = @()
    )

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add($MSBuildDllPath)
    $arguments.Add($BuildPath)
    if ($Restore) {
        $arguments.Add('/t:Restore')
    }
    foreach ($argument in @('/m:16', '/v:q', '/nodeReuse:false', '/p:UseSharedCompilation=false')) {
        $arguments.Add($argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($BinlogPath)) {
        $arguments.Add("/bl:$BinlogPath;ProjectImports=None")
    }
    foreach ($argument in $AdditionalArguments) {
        $arguments.Add($argument)
    }
    return $arguments.ToArray()
}

function Touch-CampaignInput {
    param(
        [Parameter(Mandatory)]
        [string]$Worktree,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $path = Join-Path $Worktree $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Propagated input '$path' is missing."
    }
    (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow
    return [pscustomobject][ordered]@{
        Path = $path
        TouchedUtc = (Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('O')
    }
}

function Invoke-BuildServerShutdown {
    param(
        [Parameter(Mandatory)]
        [object[]]$Bootstraps,

        [Parameter(Mandatory)]
        [string]$JournalPath,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    foreach ($bootstrap in $Bootstraps) {
        if (-not $bootstrap.Verified) {
            throw "Cannot shut down build servers with an unverified $($bootstrap.Role) bootstrap."
        }
        $shutdownEnvironment = @{
            DOTNET_ROOT = $bootstrap.Root
            DOTNET_ROOT_X64 = $bootstrap.Root
            DOTNET_CLI_TELEMETRY_OPTOUT = '1'
            PATH = "$($bootstrap.Root)$([IO.Path]::PathSeparator)$([Environment]::GetEnvironmentVariable('PATH', 'Process'))"
        }
        foreach ($variable in Get-CoordinatorEnvironmentVariableNames) {
            $shutdownEnvironment[$variable] = $null
        }
        [void](Invoke-RecordedCommand `
            -FileName $bootstrap.DotNetPath `
            -Arguments @('build-server', 'shutdown') `
            -WorkingDirectory $bootstrap.Root `
            -JournalPath $JournalPath `
            -OutputDirectory $OutputDirectory `
            -Label "shutdown-$($bootstrap.Role)" `
            -Environment $shutdownEnvironment)
    }
}

function Wait-ForMachineIdle {
    param(
        [Parameter(Mandatory)]
        [string]$RecordPath,

        [Parameter(Mandatory)]
        [int]$MinimumAvailableMB,

        [int]$TimeoutSeconds = 300
    )

    Assert-WindowsCampaignHost
    $definition = Get-CampaignDefinition
    $validity = $definition.Validity
    $records = [Collections.Generic.List[object]]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $consecutive = 0
    while ($timer.Elapsed.TotalSeconds -le $TimeoutSeconds) {
        $timestamp = [DateTime]::UtcNow
        $cpu = $null
        $queue = $null
        $available = $null
        $sampleError = $null
        try {
            $samples = (Get-Counter -Counter @(
                '\Processor(_Total)\% Processor Time',
                '\Memory\Available MBytes',
                '\System\Processor Queue Length'
            )).CounterSamples
            foreach ($sample in $samples) {
                $path = $sample.Path.ToLowerInvariant()
                if ($path.EndsWith('\processor(_total)\% processor time')) {
                    $cpu = [double]$sample.CookedValue
                }
                elseif ($path.EndsWith('\memory\available mbytes')) {
                    $available = [double]$sample.CookedValue
                }
                elseif ($path.EndsWith('\system\processor queue length')) {
                    $queue = [double]$sample.CookedValue
                }
            }
        }
        catch {
            $sampleError = $_.Exception.Message
        }
        $conflicting = @(
            Get-CimInstance Win32_Process |
                Where-Object {
                    [int]$_.ProcessId -ne $PID -and
                    ($_.Name -in @(
                        'MSBuild.exe',
                        'MSBuild.Coordinator.exe',
                        'csc.exe',
                        'vbc.exe',
                        'VBCSCompiler.exe'
                    ) -or
                    ($_.Name -eq 'dotnet.exe' -and
                        $_.CommandLine -match 'MSBuild\.dll') -or
                    ($_.Name -eq 'pwsh.exe' -and
                        $_.CommandLine -match '(Invoke-Scenario|Run-Campaign|Monitor-Campaign)\.ps1'))
                } |
                Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine
        )
        $accepted = $null -eq $sampleError -and
            $null -ne $cpu -and $cpu -le $validity.IdleCpuMaximumPercent -and
            $null -ne $queue -and $queue -le $validity.IdleQueueMaximum -and
            $null -ne $available -and $available -ge $MinimumAvailableMB -and
            $conflicting.Count -eq 0
        $consecutive = if ($accepted) { $consecutive + 1 } else { 0 }
        $records.Add([pscustomobject][ordered]@{
            TimestampUtc = $timestamp.ToString('O')
            ElapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
            CpuPercent = $cpu
            ProcessorQueueLength = $queue
            AvailableMB = $available
            MinimumAvailableMB = $MinimumAvailableMB
            ConflictingProcessCount = $conflicting.Count
            ConflictingProcesses = $conflicting
            Accepted = $accepted
            ConsecutiveAccepted = $consecutive
            Error = $sampleError
        })
        Write-JsonAtomic -Path $RecordPath -Value $records.ToArray() -Depth 8
        if ($consecutive -ge $validity.IdleConsecutiveSamples) {
            return
        }
        Start-Sleep -Seconds $validity.IdleSampleSeconds
    }
    throw "Machine did not pass the idle gate within $TimeoutSeconds seconds. See '$RecordPath'."
}

function Enable-CampaignKeepAwake {
    if (-not ('CurrentVsFinalPower' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class CurrentVsFinalPower
{
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@
    }
    $previous = [CurrentVsFinalPower]::SetThreadExecutionState([uint32]2147483649)
    if ($previous -eq 0) {
        throw 'SetThreadExecutionState failed to request system-awake execution.'
    }
    [pscustomobject]@{
        RequestedUtc = [DateTime]::UtcNow.ToString('O')
        PreviousExecutionState = $previous
    }
}

function Disable-CampaignKeepAwake {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $result = [CurrentVsFinalPower]::SetThreadExecutionState([uint32]2147483648)
    [pscustomobject][ordered]@{
        RequestedUtc = $State.RequestedUtc
        PreviousExecutionState = $State.PreviousExecutionState
        RestoredUtc = [DateTime]::UtcNow.ToString('O')
        RestoreResult = $result
        Restored = $result -ne 0
    }
}

function Get-MaxTimestampGapSeconds {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows
    )

    $maximum = 0.0
    for ($index = 1; $index -lt $Rows.Count; $index++) {
        $current = ConvertTo-UtcDateTimeOffset -Value $Rows[$index].timestampUtc
        $previous = ConvertTo-UtcDateTimeOffset -Value $Rows[$index - 1].timestampUtc
        $gap = ($current - $previous).TotalSeconds
        if ($gap -gt $maximum) {
            $maximum = $gap
        }
    }
    return $maximum
}

function Test-TelemetryContinuity {
    param(
        [Parameter(Mandatory)]
        [string]$MonitorRoot
    )

    $validity = (Get-CampaignDefinition).Validity
    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $statistics = [ordered]@{}
    foreach ($stream in @(
        [pscustomobject]@{ Name = 'system'; File = 'system.csv'; Hard = $validity.SystemGapHardSeconds; Group = $false },
        [pscustomobject]@{ Name = 'process'; File = 'processes.csv'; Hard = $validity.ProcessGapHardSeconds; Group = $true },
        [pscustomobject]@{ Name = 'probe'; File = 'probes.csv'; Hard = $validity.ProbeGapHardSeconds; Group = $false }
    )) {
        $path = Join-Path $MonitorRoot $stream.File
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            $errors.Add("$($stream.File) is missing or empty.")
            continue
        }
        $rows = @(Import-Csv -LiteralPath $path)
        if ($stream.Group) {
            $rows = @($rows | Group-Object timestampUtc | ForEach-Object { $_.Group[0] })
        }
        if ($rows.Count -lt 2) {
            $errors.Add("$($stream.File) has fewer than two samples.")
            continue
        }
        $maximum = Get-MaxTimestampGapSeconds -Rows $rows
        $warningGaps = @(
            if ($stream.Name -eq 'system') {
                for ($index = 1; $index -lt $rows.Count; $index++) {
                    $current = ConvertTo-UtcDateTimeOffset -Value $rows[$index].timestampUtc
                    $previous = ConvertTo-UtcDateTimeOffset -Value $rows[$index - 1].timestampUtc
                    $gap = ($current - $previous).TotalSeconds
                    if ($gap -gt $validity.SystemGapWarningSeconds) {
                        $gap
                    }
                }
            }
        )
        $statistics[$stream.Name] = [pscustomobject]@{
            MaximumGapSeconds = $maximum
            HardLimitSeconds = $stream.Hard
            SampleCount = $rows.Count
            WarningThresholdSeconds = if ($stream.Name -eq 'system') { $validity.SystemGapWarningSeconds } else { $null }
            WarningCount = $warningGaps.Count
            WarningMaximumSeconds = if ($warningGaps.Count -eq 0) { $null } else { ($warningGaps | Measure-Object -Maximum).Maximum }
        }
        if ($stream.Name -eq 'system' -and $warningGaps.Count -gt 0) {
            $warnings.Add("$($warningGaps.Count) system counter gap(s) exceeded the $($validity.SystemGapWarningSeconds)s warning threshold; maximum $([Math]::Round(($warningGaps | Measure-Object -Maximum).Maximum, 3))s.")
        }
        if ($maximum -gt $stream.Hard) {
            $errors.Add("$($stream.Name) telemetry gap $([Math]::Round($maximum, 3))s exceeded the $($stream.Hard)s hard limit.")
        }
    }
    foreach ($name in @('monitor-errors.log', 'process-monitor-errors.log', 'probe-monitor-errors.log')) {
        $path = Join-Path $MonitorRoot $name
        if ((Test-Path -LiteralPath $path) -and
            -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $path -Raw))) {
            $errors.Add("$name is nonempty.")
        }
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Statistics = [pscustomobject]$statistics
        Warnings = $warnings.ToArray()
        Errors = $errors.ToArray()
    }
}

function Get-FileSha256Record {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$RelativeTo
    )

    [pscustomobject][ordered]@{
        Path = if ([string]::IsNullOrWhiteSpace($RelativeTo)) {
            $Path
        }
        else {
            [IO.Path]::GetRelativePath($RelativeTo, $Path)
        }
        Bytes = (Get-Item -LiteralPath $Path).Length
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}
