Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ControllerValidation.ps1')

function Get-PhaseOneRecordProperty {
    param(
        [AllowNull()]
        [object]$Record,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Record) {
        return $null
    }
    $property = $Record.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-PhaseOneCanonicalPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $pathRoot
    }
    return $fullPath.TrimEnd('\')
}

function Get-PhaseOnePhysicalPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = Get-PhaseOneCanonicalPath -Path $Path
    $root = [IO.Path]::GetPathRoot($fullPath)
    $relative = $fullPath.Substring($root.Length)
    $components = @($relative -split '[\\/]' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    $current = $root
    for ($index = 0; $index -lt $components.Count; $index++) {
        $candidate = Join-Path $current $components[$index]
        if (-not (Test-Path -LiteralPath $candidate)) {
            for ($remaining = $index; $remaining -lt $components.Count; $remaining++) {
                $current = Join-Path $current $components[$remaining]
            }
            break
        }
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $target = $item.ResolveLinkTarget($true)
            if ($null -eq $target) {
                throw "Cannot resolve reparse point '$candidate'."
            }
            $current = $target.FullName
        }
        else {
            $current = $item.FullName
        }
    }
    return Get-PhaseOneCanonicalPath -Path $current
}

function Test-PhaseOnePathOverlap {
    param(
        [Parameter(Mandatory)]
        [string]$First,

        [Parameter(Mandatory)]
        [string]$Second
    )

    $firstPath = Get-PhaseOnePhysicalPath -Path $First
    $secondPath = Get-PhaseOnePhysicalPath -Path $Second
    $firstPrefix = if ($firstPath.EndsWith('\')) { $firstPath } else { "$firstPath\" }
    $secondPrefix = if ($secondPath.EndsWith('\')) { $secondPath } else { "$secondPath\" }
    return $firstPath.Equals($secondPath, [StringComparison]::OrdinalIgnoreCase) -or
        $firstPath.StartsWith($secondPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $secondPath.StartsWith($firstPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Read-PhaseOneBootstrapIdentityInput {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'BootstrapIdentityPath must be an exact fully qualified path.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Bootstrap identity '$Path' does not exist."
    }
    $physicalPath = Get-PhaseOnePhysicalPath -Path $Path
    $bytes = [IO.File]::ReadAllBytes($physicalPath)
    if ($bytes.Length -eq 0) {
        throw "Bootstrap identity '$physicalPath' is empty."
    }
    $memory = [IO.MemoryStream]::new($bytes, $false)
    $reader = [IO.StreamReader]::new(
        $memory,
        [Text.UTF8Encoding]::new($false, $true),
        $true)
    try {
        $json = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $memory.Dispose()
    }
    try {
        $record = $json | ConvertFrom-Json
    }
    catch {
        throw "Bootstrap identity '$physicalPath' is invalid JSON: $($_.Exception.Message)"
    }
    foreach ($role in @('Base', 'Final')) {
        $bootstrap = Get-PhaseOneRecordProperty -Record $record -Name $role
        $source = Get-PhaseOneRecordProperty `
            -Record (Get-PhaseOneRecordProperty -Record $record -Name Sources) `
            -Name $role
        foreach ($required in @(
            [pscustomobject]@{ Name = "$role bootstrap"; Value = $bootstrap },
            [pscustomobject]@{ Name = "$role source"; Value = $source }
        )) {
            if ($null -eq $required.Value -or
                [string]::IsNullOrWhiteSpace([string]$required.Value.Root) -or
                -not [IO.Path]::IsPathFullyQualified([string]$required.Value.Root)) {
                throw "Bootstrap identity has no fully qualified $($required.Name) root."
            }
        }
    }
    [pscustomobject][ordered]@{
        SourcePath = $physicalPath
        SourceDirectory = Get-PhaseOnePhysicalPath -Path (Split-Path -Parent $physicalPath)
        SourceSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes))
        Bytes = $bytes
        Record = $record
    }
}

function New-PhaseOneBootstrapIdentitySnapshot {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$IdentityInput,

        [Parameter(Mandatory)]
        [string]$AttemptRoot
    )

    $snapshotDirectory = Join-Path $AttemptRoot 'inputs'
    New-Item -ItemType Directory -Path $snapshotDirectory | Out-Null
    $snapshotPath = Join-Path $snapshotDirectory 'bootstrap-identities.json'
    $stream = [IO.File]::Open(
        $snapshotPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read)
    try {
        $stream.Write($IdentityInput.Bytes, 0, $IdentityInput.Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    (Get-Item -LiteralPath $snapshotPath).IsReadOnly = $true
    [pscustomobject][ordered]@{
        CreatedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        SourcePath = $IdentityInput.SourcePath
        SourceSha256 = $IdentityInput.SourceSha256
        SnapshotPath = Get-PhaseOnePhysicalPath -Path $snapshotPath
        SnapshotSha256 = $IdentityInput.SourceSha256
        SnapshotReadOnly = (Get-Item -LiteralPath $snapshotPath).IsReadOnly
        CreateMode = 'CreateNew'
        NeverOverwrite = $true
    }
}

function Test-PhaseOneBootstrapIdentityBinding {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$SourceSha256,

        [Parameter(Mandatory)]
        [string]$SnapshotPath,

        [Parameter(Mandatory)]
        [string]$SnapshotSha256
    )

    $errors = [Collections.Generic.List[string]]::new()
    $actualSourceHash = $null
    $actualSnapshotHash = $null
    try {
        $actualSnapshotHash =
            (Get-FileHash -LiteralPath $SnapshotPath -Algorithm SHA256).Hash
        if ($actualSnapshotHash -ne $SnapshotSha256) {
            $errors.Add('Immutable bootstrap identity snapshot hash changed.')
        }
        if (-not (Get-Item -LiteralPath $SnapshotPath).IsReadOnly) {
            $errors.Add('Immutable bootstrap identity snapshot is no longer read-only.')
        }
    }
    catch {
        $errors.Add("Immutable bootstrap identity snapshot cannot be verified: $($_.Exception.Message)")
    }
    try {
        $actualSourceHash =
            (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        if ($actualSourceHash -ne $SourceSha256) {
            $errors.Add('Source bootstrap identity changed after the attempt snapshot.')
        }
    }
    catch {
        $errors.Add("Source bootstrap identity cannot be verified: $($_.Exception.Message)")
    }
    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        SourcePath = $SourcePath
        SourceExpectedSha256 = $SourceSha256
        SourceActualSha256 = $actualSourceHash
        SourceUnchanged = $actualSourceHash -eq $SourceSha256
        SnapshotPath = $SnapshotPath
        SnapshotExpectedSha256 = $SnapshotSha256
        SnapshotActualSha256 = $actualSnapshotHash
        SnapshotValid = $actualSnapshotHash -eq $SnapshotSha256
        Errors = $errors.ToArray()
    }
}

function Test-PhaseOneOutputRootSafety {
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [pscustomobject]$IdentityInput,

        [string]$ToolingRoot = $PSScriptRoot,

        [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..\..\..\..')
    )

    $errors = [Collections.Generic.List[string]]::new()
    $protected = [Collections.Generic.List[object]]::new()
    $overlaps = [Collections.Generic.List[object]]::new()
    if (-not [IO.Path]::IsPathFullyQualified($OutputRoot)) {
        $errors.Add('OutputRoot must be one fixed fully qualified path.')
        return [pscustomobject][ordered]@{
            Valid = $false
            ValidatedBeforeWrites = $true
            WritesPerformed = $false
            Errors = $errors.ToArray()
        }
    }

    $output = Get-PhaseOnePhysicalPath -Path $OutputRoot
    if (Test-Path -LiteralPath $output -PathType Leaf) {
        $errors.Add("OutputRoot '$output' is an existing file.")
    }
    foreach ($item in @(
        [pscustomobject]@{ Kind = 'identity-file'; Path = $IdentityInput.SourcePath },
        [pscustomobject]@{ Kind = 'identity-directory'; Path = $IdentityInput.SourceDirectory },
        [pscustomobject]@{ Kind = 'tooling-root'; Path = $ToolingRoot },
        [pscustomobject]@{ Kind = 'repository-root'; Path = $RepositoryRoot }
    )) {
        $protected.Add([pscustomobject]@{
            Kind = $item.Kind
            Path = Get-PhaseOnePhysicalPath -Path $item.Path
        })
    }
    $sources = Get-PhaseOneRecordProperty -Record $IdentityInput.Record -Name Sources
    foreach ($role in @('Base', 'Final')) {
        $bootstrap =
            Get-PhaseOneRecordProperty -Record $IdentityInput.Record -Name $role
        $source = Get-PhaseOneRecordProperty -Record $sources -Name $role
        $protected.Add([pscustomobject]@{
            Kind = "$($role.ToLowerInvariant())-bootstrap-root"
            Path = Get-PhaseOnePhysicalPath -Path ([string]$bootstrap.Root)
        })
        $protected.Add([pscustomobject]@{
            Kind = "$($role.ToLowerInvariant())-source-worktree"
            Path = Get-PhaseOnePhysicalPath -Path ([string]$source.Root)
        })
    }
    foreach ($item in @($protected | Sort-Object Kind,Path -Unique)) {
        if (Test-PhaseOnePathOverlap -First $output -Second $item.Path) {
            $overlaps.Add([pscustomobject]@{
                ProtectedKind = $item.Kind
                ProtectedPath = $item.Path
            })
            $errors.Add(
                "OutputRoot overlaps protected $($item.Kind) '$($item.Path)'.")
        }
    }

    $probe = $output
    while (-not (Test-Path -LiteralPath $probe -PathType Container)) {
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($probe, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $probe = $parent
    }
    $gitMarker = $null
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        $candidateMarker = Join-Path $probe '.git'
        if (Test-Path -LiteralPath $candidateMarker) {
            $gitMarker = Get-PhaseOnePhysicalPath -Path $candidateMarker
            break
        }
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($probe, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $probe = $parent
    }
    if ($null -ne $gitMarker) {
        $errors.Add("OutputRoot is inside a git worktree identified by '$gitMarker'.")
    }

    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        ValidatedBeforeWrites = $true
        WritesPerformed = $false
        OutputRoot = $output
        InsideGitWorktree = $null -ne $gitMarker
        GitMarkerPath = $gitMarker
        ProtectedPaths = $protected.ToArray()
        ProtectedPathOverlapCount = $overlaps.Count
        Overlaps = $overlaps.ToArray()
        SourceBootstrapIdentityPath = $IdentityInput.SourcePath
        SourceBootstrapIdentitySha256 = $IdentityInput.SourceSha256
        Errors = $errors.ToArray()
    }
}

function Get-PhaseOneRootMutexName {
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot
    )

    $canonical = (Get-PhaseOneCanonicalPath -Path $OutputRoot).ToUpperInvariant()
    $digest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($canonical)))
    return "Local\MSBuild-PR14241-PhaseOne-$($digest.Substring(0, 32))"
}

function Enter-PhaseOneRootLock {
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot
    )

    $root = Get-PhaseOneCanonicalPath -Path $OutputRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $mutexName = Get-PhaseOneRootMutexName -OutputRoot $root
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $mutexOwned = $false
    $stream = $null
    try {
        try {
            $mutexOwned = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $mutexOwned = $true
        }
        if (-not $mutexOwned) {
            throw "PHASE_ONE_DUPLICATE_INVOCATION: another process owns '$root'."
        }

        $lockPath = Join-Path $root '.phase-one-preflight.lock'
        try {
            $stream = [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
        }
        catch {
            throw "PHASE_ONE_DUPLICATE_INVOCATION: the exclusive root lock '$lockPath' is held."
        }
        $owner = [pscustomobject][ordered]@{
            AcquiredUtc = [DateTimeOffset]::UtcNow.ToString('O')
            ProcessId = $PID
            ProcessStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')
            OutputRoot = $root
            MutexName = $mutexName
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(
            (($owner | ConvertTo-Json -Compress) + [Environment]::NewLine))
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        return [pscustomobject]@{
            OutputRoot = $root
            MutexName = $mutexName
            LockPath = $lockPath
            Mutex = $mutex
            MutexOwned = $true
            Stream = $stream
            Owner = $owner
        }
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($mutexOwned) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        throw
    }
}

function Exit-PhaseOneRootLock {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Lock
    )

    if ($null -ne $Lock.Stream) {
        $Lock.Stream.Dispose()
    }
    if ($Lock.MutexOwned) {
        $Lock.Mutex.ReleaseMutex()
        $Lock.MutexOwned = $false
    }
    $Lock.Mutex.Dispose()
}

function New-PhaseOneAttemptRoot {
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot
    )

    $root = Get-PhaseOneCanonicalPath -Path $OutputRoot
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $maximum = 0
    foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop) {
        if ($directory.Name -match '^attempt-(?<number>\d{4})$') {
            $maximum = [Math]::Max($maximum, [int]$Matches.number)
        }
    }
    $number = $maximum + 1
    if ($number -gt 9999) {
        throw "Phase 1 attempt numbering is exhausted under '$root'."
    }
    $relativePath = 'attempt-{0:D4}' -f $number
    $path = Join-Path $root $relativePath
    New-Item -ItemType Directory -Path $path | Out-Null
    [pscustomobject][ordered]@{
        Number = $number
        RelativePath = $relativePath
        Path = $path
    }
}

function Get-PhaseOneFinalBootstrapRehashBindingSha256 {
    param(
        [Parameter(Mandatory)]
        [object]$Record
    )

    $payload = [ordered]@{
        SchemaVersion =
            Get-PhaseOneRecordProperty -Record $Record -Name SchemaVersion
        Kind = Get-PhaseOneRecordProperty -Record $Record -Name Kind
        Valid = Get-PhaseOneRecordProperty -Record $Record -Name Valid
        ManagedOnly =
            Get-PhaseOneRecordProperty -Record $Record -Name ManagedOnly
        NativeProcessCount =
            Get-PhaseOneRecordProperty -Record $Record -Name NativeProcessCount
    }
    foreach ($roleName in @('Base', 'Final')) {
        $role = Get-PhaseOneRecordProperty -Record $Record -Name $roleName
        $stage = Get-PhaseOneRecordProperty -Record $role -Name ImmutableStage
        $tracked = @(
            foreach ($file in @(
                Get-PhaseOneRecordProperty -Record $role -Name TrackedBinaries
            ) | Sort-Object RelativePath) {
                [pscustomobject][ordered]@{
                    Name = Get-PhaseOneRecordProperty -Record $file -Name Name
                    RelativePath =
                        Get-PhaseOneRecordProperty -Record $file -Name RelativePath
                    Path = Get-PhaseOneRecordProperty -Record $file -Name Path
                    Bytes = Get-PhaseOneRecordProperty -Record $file -Name Bytes
                    Sha256 = Get-PhaseOneRecordProperty -Record $file -Name Sha256
                }
            }
        )
        $payload[$roleName] = [pscustomobject][ordered]@{
            Role = Get-PhaseOneRecordProperty -Record $role -Name Role
            Commit = Get-PhaseOneRecordProperty -Record $role -Name Commit
            ProductVersion =
                Get-PhaseOneRecordProperty -Record $role -Name ProductVersion
            BootstrapRoot =
                Get-PhaseOneRecordProperty -Record $role -Name BootstrapRoot
            DotNetSha256 =
                Get-PhaseOneRecordProperty -Record $role -Name DotNetSha256
            MSBuildDllSha256 =
                Get-PhaseOneRecordProperty -Record $role -Name MSBuildDllSha256
            TrackedBinarySetSha256 =
                Get-PhaseOneRecordProperty `
                    -Record $role `
                    -Name TrackedBinarySetSha256
            TrackedBinaries = $tracked
            ImmutableStage = [pscustomobject][ordered]@{
                Root = Get-PhaseOneRecordProperty -Record $stage -Name Root
                MetadataPath =
                    Get-PhaseOneRecordProperty -Record $stage -Name MetadataPath
                ExpectedContentSha256 =
                    Get-PhaseOneRecordProperty `
                        -Record $stage `
                        -Name ExpectedContentSha256
                ActualContentSha256 =
                    Get-PhaseOneRecordProperty `
                        -Record $stage `
                        -Name ActualContentSha256
                ExpectedFileCount =
                    Get-PhaseOneRecordProperty -Record $stage -Name ExpectedFileCount
                ActualFileCount =
                    Get-PhaseOneRecordProperty -Record $stage -Name ActualFileCount
                ExpectedTotalBytes =
                    Get-PhaseOneRecordProperty -Record $stage -Name ExpectedTotalBytes
                ActualTotalBytes =
                    Get-PhaseOneRecordProperty -Record $stage -Name ActualTotalBytes
                Valid = Get-PhaseOneRecordProperty -Record $stage -Name Valid
            }
            Valid = Get-PhaseOneRecordProperty -Record $role -Name Valid
        }
    }
    $json = [pscustomobject]$payload | ConvertTo-Json -Depth 20 -Compress
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($json)))
}

function Get-PhaseOneFinalBootstrapRehash {
    param(
        [Parameter(Mandatory)]
        [object]$BootstrapIdentityEvidence
    )

    $roles = [ordered]@{}
    foreach ($roleName in @('Base', 'Final')) {
        $expected =
            Get-PhaseOneRecordProperty -Record $BootstrapIdentityEvidence -Name $roleName
        if ($null -eq $expected) {
            throw "Final rehash has no $roleName bootstrap identity."
        }
        $root = Get-PhaseOneCanonicalPath -Path ([string](
            Get-PhaseOneRecordProperty -Record $expected -Name BootstrapRoot))
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Final rehash $roleName bootstrap '$root' is missing."
        }
        $rootPrefix = "$($root.TrimEnd('\'))\"
        $expectedTracked = @(
            Get-PhaseOneRecordProperty -Record $expected -Name TrackedBinaries
        )
        if ($expectedTracked.Count -eq 0) {
            throw "Final rehash $roleName bootstrap has no tracked binary identity."
        }

        $actualTracked = [Collections.Generic.List[object]]::new()
        $relativePaths =
            [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $expectedTracked | Sort-Object RelativePath) {
            $relativePath = [string](
                Get-PhaseOneRecordProperty -Record $file -Name RelativePath)
            if ([string]::IsNullOrWhiteSpace($relativePath) -or
                [IO.Path]::IsPathFullyQualified($relativePath)) {
                throw "Final rehash $roleName tracked binary path '$relativePath' is invalid."
            }
            $path = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
            if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not $relativePaths.Add($relativePath)) {
                throw "Final rehash $roleName tracked binary path '$relativePath' escapes or duplicates its immutable stage."
            }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Final rehash $roleName tracked binary '$relativePath' is missing."
            }
            $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $expectedHash = [string](
                Get-PhaseOneRecordProperty -Record $file -Name Sha256)
            if ($actualHash -ne $expectedHash) {
                throw "Final rehash detected a changed $roleName tracked binary '$relativePath'."
            }
            [void]$actualTracked.Add([pscustomobject][ordered]@{
                Name = [IO.Path]::GetFileName($path)
                RelativePath = $relativePath
                Path = $path
                Bytes = (Get-Item -LiteralPath $path).Length
                Sha256 = $actualHash
            })
        }

        $dotnet = @(
            $actualTracked |
                Where-Object {
                    [string]$_.RelativePath -eq 'dotnet.exe'
                }
        )
        $msbuild = @(
            $actualTracked |
                Where-Object {
                    [string]$_.Name -eq 'MSBuild.dll'
                }
        )
        if ($dotnet.Count -ne 1 -or $msbuild.Count -ne 1) {
            throw "Final rehash $roleName identity must contain exactly one root dotnet.exe and one MSBuild.dll."
        }
        $productVersion = (Get-Item -LiteralPath $msbuild[0].Path).VersionInfo.ProductVersion
        $expectedVersion = [string](
            Get-PhaseOneRecordProperty -Record $expected -Name ProductVersion)
        $expectedCommit = [string](
            Get-PhaseOneRecordProperty -Record $expected -Name Commit)
        if ([string]::IsNullOrWhiteSpace($productVersion) -or
            $productVersion -ne $expectedVersion -or
            -not $productVersion.Contains(
                $expectedCommit,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Final rehash $roleName ProductVersion '$productVersion' no longer proves exact commit '$expectedCommit'."
        }
        if ([string]$dotnet[0].Sha256 -ne [string](
            Get-PhaseOneRecordProperty -Record $expected -Name DotNetSha256) -or
            [string]$msbuild[0].Sha256 -ne [string](
                Get-PhaseOneRecordProperty -Record $expected -Name MSBuildDllSha256)) {
            throw "Final rehash $roleName primary binary identity changed."
        }

        $stage = Test-ImmutableBootstrapStage -Root $root
        $expectedStage =
            Get-PhaseOneRecordProperty -Record $expected -Name ImmutableStage
        if ($null -eq $expectedStage -or
            [string]$stage.ActualContentSha256 -ne [string](
                Get-PhaseOneRecordProperty `
                    -Record $expectedStage `
                    -Name ActualContentSha256)) {
            throw "Final rehash detected changed full immutable $roleName stage content."
        }
        $metadata =
            Get-Content -LiteralPath $stage.MetadataPath -Raw |
            ConvertFrom-Json
        if ([string]$metadata.Role -ne [string](
            Get-PhaseOneRecordProperty -Record $expected -Name Role) -or
            [string]$metadata.ExpectedCommit -ne $expectedCommit -or
            [string]$metadata.ProductVersion -ne $productVersion) {
            throw "Final rehash $roleName immutable-stage metadata identity changed."
        }

        $trackedBuilder = [Text.StringBuilder]::new()
        foreach ($file in $actualTracked | Sort-Object RelativePath) {
            [void]$trackedBuilder.Append($file.RelativePath.Replace('\', '/'))
            [void]$trackedBuilder.Append([char]0)
            [void]$trackedBuilder.Append($file.Bytes)
            [void]$trackedBuilder.Append([char]0)
            [void]$trackedBuilder.Append($file.Sha256)
            [void]$trackedBuilder.Append("`n")
        }
        $trackedSetHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($trackedBuilder.ToString())))
        $roles[$roleName] = [pscustomobject][ordered]@{
            Role = [string](Get-PhaseOneRecordProperty -Record $expected -Name Role)
            Commit = $expectedCommit
            ProductVersion = $productVersion
            BootstrapRoot = $root
            DotNetSha256 = $dotnet[0].Sha256
            MSBuildDllSha256 = $msbuild[0].Sha256
            TrackedBinarySetSha256 = $trackedSetHash
            TrackedBinaries = $actualTracked.ToArray()
            ImmutableStage = $stage
            Valid = $true
        }
    }

    $record = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Kind = 'PhaseOneFinalBootstrapRehash'
        Valid = $true
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        ManagedOnly = $true
        NativeProcessCount = 0
        Base = $roles.Base
        Final = $roles.Final
    }
    $record | Add-Member `
        -NotePropertyName BindingSha256 `
        -NotePropertyValue (Get-PhaseOneFinalBootstrapRehashBindingSha256 -Record $record)
    return $record
}

function Test-PhaseOneRootCompletionRecord {
    param(
        [Parameter(Mandatory)]
        [object]$Record,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$BootstrapIdentityPath,

        [Parameter(Mandatory)]
        [string]$BootstrapIdentitySha256,

        [Parameter(Mandatory)]
        [string]$SourceBootstrapIdentityPath,

        [Parameter(Mandatory)]
        [string]$SourceBootstrapIdentitySha256,

        [switch]$ValidateFileSystem
    )

    $errors = [Collections.Generic.List[string]]::new()
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
    if ([int](Get-PhaseOneRecordProperty -Record $Record -Name SchemaVersion) -ne 1) {
        $errors.Add('Root completion schema must be exactly version 1.')
    }
    if ([string](Get-PhaseOneRecordProperty -Record $Record -Name Kind) -ne
        'PhaseOneDisposablePreflight') {
        $errors.Add('Root completion kind is invalid.')
    }
    if ((Get-PhaseOneRecordProperty -Record $Record -Name Valid) -ne $true) {
        $errors.Add('Root completion is not valid.')
    }
    if ((Get-PhaseOneRecordProperty -Record $Record -Name Synchronous) -ne $true -or
        (Get-PhaseOneRecordProperty -Record $Record -Name DetachedCampaignLaunched) -ne $false) {
        $errors.Add('Root completion does not prove strict synchronous execution.')
    }
    if ((Get-PhaseOneRecordProperty -Record $Record -Name RawArtifactsOutsideGit) -ne $true) {
        $errors.Add('Root completion does not prove that raw artifacts stayed outside git.')
    }

    try {
        if (-not (Get-PhaseOneCanonicalPath -Path ([string](
            Get-PhaseOneRecordProperty -Record $Record -Name OutputRoot))).Equals(
                (Get-PhaseOneCanonicalPath -Path $OutputRoot),
                [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('Root completion output root changed.')
        }
    }
    catch {
        $errors.Add("Root completion output root is invalid: $($_.Exception.Message)")
    }
    try {
        if (-not (Get-PhaseOneCanonicalPath -Path ([string](
            Get-PhaseOneRecordProperty -Record $Record -Name BootstrapIdentityPath))).Equals(
                (Get-PhaseOneCanonicalPath -Path $BootstrapIdentityPath),
                [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('Root completion bootstrap identity path changed.')
        }
    }
    catch {
        $errors.Add("Root completion bootstrap identity path is invalid: $($_.Exception.Message)")
    }
    if ([string](Get-PhaseOneRecordProperty -Record $Record -Name BootstrapIdentitySha256) -ne
        $BootstrapIdentitySha256) {
        $errors.Add('Root completion bootstrap identity hash changed.')
    }
    try {
        if (-not (Get-PhaseOneCanonicalPath -Path ([string](
            Get-PhaseOneRecordProperty -Record $Record -Name SourceBootstrapIdentityPath))).Equals(
                (Get-PhaseOneCanonicalPath -Path $SourceBootstrapIdentityPath),
                [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('Root completion source bootstrap identity path changed.')
        }
    }
    catch {
        $errors.Add(
            "Root completion source bootstrap identity path is invalid: $($_.Exception.Message)")
    }
    if ([string](Get-PhaseOneRecordProperty `
        -Record $Record `
        -Name SourceBootstrapIdentitySha256) -ne $SourceBootstrapIdentitySha256) {
        $errors.Add('Root completion source bootstrap identity hash changed.')
    }
    $finalRehash =
        Get-PhaseOneRecordProperty -Record $Record -Name FinalBootstrapRehash
    $finalRehashSha256 = [string](
        Get-PhaseOneRecordProperty -Record $Record -Name FinalBootstrapRehashSha256)
    if ($null -eq $finalRehash -or
        [int](Get-PhaseOneRecordProperty -Record $finalRehash -Name SchemaVersion) -ne 1 -or
        [string](Get-PhaseOneRecordProperty -Record $finalRehash -Name Kind) -ne
            'PhaseOneFinalBootstrapRehash' -or
        (Get-PhaseOneRecordProperty -Record $finalRehash -Name Valid) -ne $true -or
        (Get-PhaseOneRecordProperty -Record $finalRehash -Name ManagedOnly) -ne $true -or
        [int](Get-PhaseOneRecordProperty -Record $finalRehash -Name NativeProcessCount) -ne 0) {
        $errors.Add('Root completion has no valid managed-only final bootstrap rehash.')
    }
    else {
        try {
            $computedFinalRehashSha256 =
                Get-PhaseOneFinalBootstrapRehashBindingSha256 -Record $finalRehash
            if ([string](Get-PhaseOneRecordProperty `
                -Record $finalRehash `
                -Name BindingSha256) -ne $computedFinalRehashSha256 -or
                $finalRehashSha256 -ne $computedFinalRehashSha256) {
                $errors.Add('Root completion final bootstrap rehash binding changed.')
            }
            foreach ($roleName in @('Base', 'Final')) {
                $role = Get-PhaseOneRecordProperty -Record $finalRehash -Name $roleName
                if ($null -eq $role -or
                    (Get-PhaseOneRecordProperty -Record $role -Name Valid) -ne $true) {
                    $errors.Add("Root completion final $roleName bootstrap rehash is invalid.")
                }
            }
        }
        catch {
            $errors.Add(
                "Root completion final bootstrap rehash cannot be verified: $($_.Exception.Message)")
        }
    }

    $attemptNumber = [int](Get-PhaseOneRecordProperty -Record $Record -Name AttemptNumber)
    $attemptRelativePath = [string](
        Get-PhaseOneRecordProperty -Record $Record -Name AttemptRelativePath)
    if ($attemptNumber -le 0 -or
        $attemptRelativePath -ne ('attempt-{0:D4}' -f $attemptNumber)) {
        $errors.Add('Root completion attempt identity is invalid.')
    }
    $components = Get-PhaseOneRecordProperty -Record $Record -Name Components
    foreach ($name in $requiredComponents) {
        $component = if ($null -eq $components) {
            $null
        }
        else {
            Get-PhaseOneRecordProperty -Record $components -Name $name
        }
        if ($null -eq $component -or
            (Get-PhaseOneRecordProperty -Record $component -Name Valid) -ne $true) {
            $errors.Add("Root completion component '$name' is missing or invalid.")
        }
    }

    if ($ValidateFileSystem -and $attemptNumber -gt 0) {
        $expectedSnapshotPath = Join-Path `
            (Join-Path $OutputRoot $attemptRelativePath) `
            'inputs\bootstrap-identities.json'
        try {
            if (-not (Get-PhaseOneCanonicalPath -Path $BootstrapIdentityPath).Equals(
                (Get-PhaseOneCanonicalPath -Path $expectedSnapshotPath),
                [StringComparison]::OrdinalIgnoreCase)) {
                $errors.Add('Root completion snapshot path is outside its immutable attempt input.')
            }
            elseif (-not (Test-Path -LiteralPath $BootstrapIdentityPath -PathType Leaf)) {
                $errors.Add("Root completion snapshot '$BootstrapIdentityPath' is missing.")
            }
            elseif ((Get-FileHash `
                -LiteralPath $BootstrapIdentityPath `
                -Algorithm SHA256).Hash -ne $BootstrapIdentitySha256) {
                $errors.Add('Root completion snapshot content hash changed.')
            }
            elseif (-not (Get-Item -LiteralPath $BootstrapIdentityPath).IsReadOnly) {
                $errors.Add('Root completion snapshot is no longer read-only.')
            }
        }
        catch {
            $errors.Add("Root completion snapshot cannot be verified: $($_.Exception.Message)")
        }
        try {
            if (-not (Test-Path -LiteralPath $SourceBootstrapIdentityPath -PathType Leaf) -or
                (Get-FileHash `
                    -LiteralPath $SourceBootstrapIdentityPath `
                    -Algorithm SHA256).Hash -ne $SourceBootstrapIdentitySha256) {
                $errors.Add('Root completion source bootstrap identity no longer matches.')
            }
        }
        catch {
            $errors.Add(
                "Root completion source bootstrap identity cannot be verified: $($_.Exception.Message)")
        }
        $attemptCompletionRelativePath = [string](
            Get-PhaseOneRecordProperty -Record $Record -Name AttemptCompletionRelativePath)
        $expectedRelativePath = Join-Path $attemptRelativePath 'completion.json'
        if ($attemptCompletionRelativePath -ne $expectedRelativePath) {
            $errors.Add('Root completion attempt-completion path is invalid.')
        }
        else {
            $attemptCompletionPath = Join-Path $OutputRoot $attemptCompletionRelativePath
            if (-not (Test-Path -LiteralPath $attemptCompletionPath -PathType Leaf)) {
                $errors.Add("Attempt completion '$attemptCompletionPath' is missing.")
            }
            else {
                $actualHash = (Get-FileHash -LiteralPath $attemptCompletionPath -Algorithm SHA256).Hash
                if ($actualHash -ne [string](
                    Get-PhaseOneRecordProperty -Record $Record -Name AttemptCompletionSha256)) {
                    $errors.Add('Attempt completion hash changed.')
                }
                try {
                    $attemptCompletion =
                        Get-Content -LiteralPath $attemptCompletionPath -Raw |
                        ConvertFrom-Json
                    if ($attemptCompletion.Valid -ne $true -or
                        [int]$attemptCompletion.AttemptNumber -ne $attemptNumber -or
                        [string](Get-PhaseOneRecordProperty `
                            -Record $attemptCompletion `
                            -Name Kind) -ne 'PhaseOneDisposablePreflightAttempt' -or
                        (Get-PhaseOneRecordProperty `
                            -Record $attemptCompletion `
                            -Name Synchronous) -ne $true -or
                        (Get-PhaseOneRecordProperty `
                            -Record $attemptCompletion `
                            -Name DetachedCampaignLaunched) -ne $false) {
                        $errors.Add('Attempt completion content is invalid.')
                    }
                    try {
                        if (-not (Get-PhaseOneCanonicalPath -Path ([string](
                            Get-PhaseOneRecordProperty `
                                -Record $attemptCompletion `
                                -Name BootstrapIdentityPath))).Equals(
                                    (Get-PhaseOneCanonicalPath -Path $BootstrapIdentityPath),
                                    [StringComparison]::OrdinalIgnoreCase) -or
                            [string](Get-PhaseOneRecordProperty `
                                -Record $attemptCompletion `
                                -Name BootstrapIdentitySha256) -ne
                                    $BootstrapIdentitySha256 -or
                            -not (Get-PhaseOneCanonicalPath -Path ([string](
                                Get-PhaseOneRecordProperty `
                                    -Record $attemptCompletion `
                                    -Name SourceBootstrapIdentityPath))).Equals(
                                        (Get-PhaseOneCanonicalPath `
                                            -Path $SourceBootstrapIdentityPath),
                                        [StringComparison]::OrdinalIgnoreCase) -or
                            [string](Get-PhaseOneRecordProperty `
                                -Record $attemptCompletion `
                                -Name SourceBootstrapIdentitySha256) -ne
                                    $SourceBootstrapIdentitySha256) {
                            $errors.Add(
                                'Attempt completion bootstrap snapshot/source binding changed.')
                        }
                    }
                    catch {
                        $errors.Add(
                            "Attempt completion bootstrap binding is invalid: $($_.Exception.Message)")
                    }
                    $attemptFinalRehash = Get-PhaseOneRecordProperty `
                        -Record $attemptCompletion `
                        -Name FinalBootstrapRehash
                    $attemptFinalRehashSha256 = [string](
                        Get-PhaseOneRecordProperty `
                            -Record $attemptCompletion `
                            -Name FinalBootstrapRehashSha256)
                    try {
                        if ($null -eq $attemptFinalRehash -or
                            $attemptFinalRehashSha256 -ne $finalRehashSha256 -or
                            [string](Get-PhaseOneRecordProperty `
                                -Record $attemptFinalRehash `
                                -Name BindingSha256) -ne $finalRehashSha256 -or
                            (Get-PhaseOneFinalBootstrapRehashBindingSha256 `
                                -Record $attemptFinalRehash) -ne $finalRehashSha256) {
                            $errors.Add(
                                'Attempt completion final bootstrap rehash binding changed.')
                        }
                    }
                    catch {
                        $errors.Add(
                            "Attempt completion final bootstrap rehash cannot be verified: $($_.Exception.Message)")
                    }
                    $attemptComponents =
                        Get-PhaseOneRecordProperty `
                            -Record $attemptCompletion `
                            -Name Components
                    foreach ($name in $requiredComponents) {
                        $attemptComponent = if ($null -eq $attemptComponents) {
                            $null
                        }
                        else {
                            Get-PhaseOneRecordProperty `
                                -Record $attemptComponents `
                                -Name $name
                        }
                        if ($null -eq $attemptComponent -or
                            (Get-PhaseOneRecordProperty `
                                -Record $attemptComponent `
                                -Name Valid) -ne $true) {
                            $errors.Add(
                                "Attempt completion component '$name' is missing or invalid.")
                        }
                    }
                    $attemptPromotion = Get-PhaseOneRecordProperty `
                        -Record $attemptComponents `
                        -Name PromotionRevalidation
                    if ($null -eq $attemptPromotion -or
                        [string](Get-PhaseOneRecordProperty `
                            -Record $attemptPromotion `
                            -Name FinalBootstrapRehashSha256) -ne $finalRehashSha256 -or
                        (Get-PhaseOneRecordProperty `
                            -Record $attemptPromotion `
                            -Name ManagedOnlyAfterFinalProcessAudit) -ne $true -or
                        [int](Get-PhaseOneRecordProperty `
                            -Record $attemptPromotion `
                            -Name NativeCallsAfterRehash) -ne 0 -or
                        [int](Get-PhaseOneRecordProperty `
                            -Record $attemptPromotion `
                            -Name RegistryEntryCountBeforeFinalRehash) -ne
                        [int](Get-PhaseOneRecordProperty `
                            -Record $attemptPromotion `
                            -Name RegistryEntryCountAfterFinalRehash)) {
                        $errors.Add(
                            'Attempt completion promotion component is not bound to the final bootstrap rehash.')
                    }
                    $attemptSafety = Get-PhaseOneRecordProperty `
                        -Record $attemptComponents `
                        -Name OutputRootSafety
                    if ($null -eq $attemptSafety -or
                        (Get-PhaseOneRecordProperty `
                            -Record $attemptSafety `
                            -Name ValidatedBeforeWrites) -ne $true -or
                        (Get-PhaseOneRecordProperty `
                            -Record $attemptSafety `
                            -Name InsideGitWorktree) -ne $false -or
                        [int](Get-PhaseOneRecordProperty `
                            -Record $attemptSafety `
                            -Name ProtectedPathOverlapCount) -ne 0) {
                        $errors.Add(
                            'Attempt completion does not prove output-root safety before writes.')
                    }
                    $attemptProcessAudit = Get-PhaseOneRecordProperty `
                        -Record $attemptComponents `
                        -Name ProcessCleanupAudit
                    if ($null -ne $attemptPromotion -and
                        $null -ne $attemptProcessAudit -and
                        ([string](Get-PhaseOneRecordProperty `
                            -Record $attemptPromotion `
                            -Name FinalProcessCleanupRegistrySha256) -ne
                        [string](Get-PhaseOneRecordProperty `
                            -Record $attemptProcessAudit `
                            -Name RegistrySha256) -or
                        [int](Get-PhaseOneRecordProperty `
                            -Record $attemptPromotion `
                            -Name RegistryEntryCountBeforeFinalRehash) -ne
                        [int](Get-PhaseOneRecordProperty `
                            -Record $attemptProcessAudit `
                            -Name RegistryEntryCount))) {
                        $errors.Add(
                            'Final bootstrap rehash is not bound to the final process audit registry.')
                    }
                    $expectedRegistryPath = Join-Path `
                        (Join-Path $OutputRoot $attemptRelativePath) `
                        'process-registry.jsonl'
                    try {
                        if ($null -eq $attemptProcessAudit -or
                            -not (Get-PhaseOneCanonicalPath -Path ([string](
                                Get-PhaseOneRecordProperty `
                                    -Record $attemptProcessAudit `
                                    -Name RegistryPath))).Equals(
                                        (Get-PhaseOneCanonicalPath `
                                            -Path $expectedRegistryPath),
                                        [StringComparison]::OrdinalIgnoreCase) -or
                            -not (Test-Path `
                                -LiteralPath $expectedRegistryPath `
                                -PathType Leaf) -or
                            [string](Get-PhaseOneRecordProperty `
                                -Record $attemptProcessAudit `
                                -Name RegistrySha256) -ne
                                    (Get-FileHash `
                                        -LiteralPath $expectedRegistryPath `
                                        -Algorithm SHA256).Hash) {
                            $errors.Add(
                                'Attempt completion process registry path/hash changed.')
                        }
                    }
                    catch {
                        $errors.Add(
                            "Attempt completion process registry cannot be verified: $($_.Exception.Message)")
                    }
                }
                catch {
                    $errors.Add("Attempt completion cannot be read: $($_.Exception.Message)")
                }
            }
        }
    }

    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        AttemptNumber = $attemptNumber
        RequiredComponents = $requiredComponents
    }
}

function Test-PhaseOneControllerLifecycleContract {
    param(
        [Parameter(Mandatory)]
        [object[]]$Events,

        [Parameter(Mandatory)]
        [object[]]$Runs,

        [Parameter(Mandatory)]
        [object[]]$Replays,

        [Parameter(Mandatory)]
        [pscustomobject]$Trace,

        [int]$InitialWorkers = 18,

        [int]$InjectionCompletion = 1,

        [int]$EndingCompletion = 2
    )

    $errors = [Collections.Generic.List[string]]::new()
    $controller = Test-SustainedControllerEvents `
        -Events $Events `
        -InitialWorkers $InitialWorkers `
        -InjectionCompletion $InjectionCompletion `
        -EndingCompletion $EndingCompletion
    foreach ($message in @($controller.Errors)) {
        $errors.Add([string]$message)
    }

    $eventIndexes = @{}
    for ($index = 0; $index -lt $Events.Count; $index++) {
        $name = [string](Get-PhaseOneRecordProperty -Record $Events[$index] -Name Event)
        if (-not $eventIndexes.ContainsKey($name)) {
            $eventIndexes[$name] = [Collections.Generic.List[int]]::new()
        }
        $eventIndexes[$name].Add($index)
    }
    foreach ($name in @('SteadyOnset', 'Injected', 'SteadyEnd', 'DrainStarted', 'Drained')) {
        if (-not $eventIndexes.ContainsKey($name) -or $eventIndexes[$name].Count -ne 1) {
            $errors.Add("Controller lifecycle requires exactly one '$name' event.")
        }
    }

    if ($eventIndexes.ContainsKey('SteadyOnset') -and
        $eventIndexes.ContainsKey('SteadyEnd') -and
        $eventIndexes.ContainsKey('DrainStarted') -and
        $eventIndexes.ContainsKey('Drained')) {
        $onsetIndex = $eventIndexes.SteadyOnset[0]
        $endIndex = $eventIndexes.SteadyEnd[0]
        $drainStartIndex = $eventIndexes.DrainStarted[0]
        $drainedIndex = $eventIndexes.Drained[0]
        if ($onsetIndex -ge $endIndex -or
            $endIndex -ge $drainStartIndex -or
            $drainStartIndex -ge $drainedIndex) {
            $errors.Add('Controller onset, end, and drain markers are out of order.')
        }
        $replacementIndexes = @(
            if ($eventIndexes.ContainsKey('ReplacementLaunched')) {
                $eventIndexes.ReplacementLaunched
            }
        )
        if ($replacementIndexes.Count -lt 1) {
            $errors.Add('Controller lifecycle did not launch a replacement.')
        }
        elseif (@($replacementIndexes | Where-Object {
            $_ -le $onsetIndex -or $_ -ge $endIndex
        }).Count -gt 0) {
            $errors.Add('A replacement occurred before onset or after replacement stop.')
        }
        foreach ($replacementIndex in $replacementIndexes) {
            $replacement = $Events[$replacementIndex]
            $replacedRunId = [string](
                Get-PhaseOneRecordProperty -Record $replacement -Name ReplacedRunId)
            $predecessors = @(
                for ($eventIndex = 0; $eventIndex -lt $replacementIndex; $eventIndex++) {
                    $candidate = $Events[$eventIndex]
                    if ([string](Get-PhaseOneRecordProperty -Record $candidate -Name Event) -eq
                        'Completed' -and
                        [string](Get-PhaseOneRecordProperty -Record $candidate -Name RunId) -eq
                        $replacedRunId) {
                        $candidate
                    }
                }
            )
            if ($predecessors.Count -ne 1 -or
                [int](Get-PhaseOneRecordProperty -Record $predecessors[0] -Name ExitCode) -ne 0 -or
                (Get-PhaseOneRecordProperty -Record $predecessors[0] -Name Quiescent) -ne $true -or
                [int](Get-PhaseOneRecordProperty -Record $predecessors[0] -Name Worker) -ne
                    [int](Get-PhaseOneRecordProperty -Record $replacement -Name Worker)) {
                $errors.Add(
                    "Replacement '$([string]$replacement.RunId)' does not follow one successful quiescent completion of '$replacedRunId'.")
            }
        }
    }
    if ($eventIndexes.ContainsKey('Injected') -and
        $eventIndexes.Injected.Count -eq 1) {
        $injected = $Events[$eventIndexes.Injected[0]]
        if ([int](Get-PhaseOneRecordProperty -Record $injected -Name AfterMeasuredCompletion) -ne
            $InjectionCompletion) {
            $errors.Add(
                "Injection marker does not record predeclared completion $InjectionCompletion.")
        }
    }
    if ([int]$controller.ActiveWorkersAtEnd -ne 0) {
        $errors.Add("Controller drain left $($controller.ActiveWorkersAtEnd) active Normal worker(s).")
    }

    $initialRuns = @(
        $Runs |
            Where-Object {
                [string](Get-PhaseOneRecordProperty -Record $_ -Name Kind) -eq 'normal' -and
                [int](Get-PhaseOneRecordProperty -Record $_ -Name Generation) -eq 1 -and
                [int](Get-PhaseOneRecordProperty -Record $_ -Name Worker) -gt 0
            }
    )
    $initialWorkerIds = @(
        $initialRuns |
            ForEach-Object { [int](Get-PhaseOneRecordProperty -Record $_ -Name Worker) } |
            Sort-Object -Unique
    )
    if ($initialRuns.Count -ne $InitialWorkers -or
        $initialWorkerIds.Count -ne $InitialWorkers -or
        ($initialWorkerIds -join ',') -ne ((1..$InitialWorkers) -join ',')) {
        $errors.Add("Run evidence does not contain exactly workers 1..$InitialWorkers as initial Normal builds.")
    }
    $initialWorktrees = @(
        $initialRuns |
            ForEach-Object {
                Get-PhaseOneCanonicalPath -Path ([string](
                    Get-PhaseOneRecordProperty -Record $_ -Name Worktree))
            } |
            Sort-Object -Unique
    )
    if ($initialWorktrees.Count -ne $InitialWorkers) {
        $errors.Add('Initial Normal builds did not use unique worktrees.')
    }
    foreach ($run in $initialRuns) {
        $arguments = @(
            Get-PhaseOneRecordProperty `
                -Record (Get-PhaseOneRecordProperty -Record $run -Name Command) `
                -Name Arguments
        )
        if ($arguments -notcontains '/m:16') {
            $errors.Add("Initial run '$($run.RunId)' did not request the full 16-node budget.")
        }
        if ([string](Get-PhaseOneRecordProperty -Record $run -Name Priority) -ne 'Normal') {
            $errors.Add("Initial run '$($run.RunId)' was not Normal priority.")
        }
    }

    $runIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($run in $Runs) {
        $runId = [string](Get-PhaseOneRecordProperty -Record $run -Name RunId)
        if (-not $runIds.Add($runId)) {
            $errors.Add("Run '$runId' appears more than once.")
        }
        if ([int](Get-PhaseOneRecordProperty -Record $run -Name ExitCode) -ne 0 -or
            (Get-PhaseOneRecordProperty -Record $run -Name Quiescent) -ne $true) {
            $errors.Add("Run '$runId' was not a successful quiescent completion.")
        }
    }
    foreach ($worktreeGroup in $Runs | Group-Object {
        Get-PhaseOneCanonicalPath -Path ([string](
            Get-PhaseOneRecordProperty -Record $_ -Name Worktree))
    }) {
        $ordered = @($worktreeGroup.Group | Sort-Object {
            [DateTimeOffset](Get-PhaseOneRecordProperty -Record $_ -Name ProcessStartUtc)
        })
        for ($index = 1; $index -lt $ordered.Count; $index++) {
            $previousExit = [DateTimeOffset](
                Get-PhaseOneRecordProperty -Record $ordered[$index - 1] -Name ProcessExitUtc)
            $currentStart = [DateTimeOffset](
                Get-PhaseOneRecordProperty -Record $ordered[$index] -Name ProcessStartUtc)
            if ($currentStart -lt $previousExit -or
                (Get-PhaseOneRecordProperty -Record $ordered[$index - 1] -Name Quiescent) -ne $true) {
                $errors.Add("Worktree '$($worktreeGroup.Name)' has overlapping run intervals.")
            }
        }
    }

    if ($Replays.Count -ne $Runs.Count) {
        $errors.Add("Grant replay returned $($Replays.Count) records for $($Runs.Count) runs.")
    }
    $validatedGrantRunIds =
        [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($run in $Runs) {
        $runId = [string](Get-PhaseOneRecordProperty -Record $run -Name RunId)
        $runPath = Get-PhaseOneCanonicalPath -Path ([string](
            Get-PhaseOneRecordProperty -Record $run -Name Binlog))
        $replayMatches = @(
            $Replays |
                Where-Object {
                    (Get-PhaseOneCanonicalPath -Path ([string](
                        Get-PhaseOneRecordProperty -Record $_ -Name Path))).Equals(
                            $runPath,
                            [StringComparison]::OrdinalIgnoreCase)
                }
        )
        $runProcessId = [int](
            Get-PhaseOneRecordProperty -Record $run -Name RootProcessId)
        $runStart = ConvertTo-UtcDateTimeOffset -Value (
            Get-PhaseOneRecordProperty -Record $run -Name ProcessStartUtc)
        $identityKey = "$runProcessId|$($runStart.UtcTicks)"
        $traceMatches = @(
            $Trace.RootStates |
                Where-Object {
                    [string](Get-PhaseOneRecordProperty `
                        -Record $_ `
                        -Name IdentityKey) -eq $identityKey -and
                    [string](Get-PhaseOneRecordProperty `
                        -Record $_ `
                        -Name RunId) -eq $runId -and
                    [int](Get-PhaseOneRecordProperty `
                        -Record $_ `
                        -Name ProcessId) -eq $runProcessId
                }
        )
        $replayGrants = if ($replayMatches.Count -eq 1) {
            @(Get-PhaseOneRecordProperty -Record $replayMatches[0] -Name Grants)
        }
        else {
            @()
        }
        if ($replayMatches.Count -ne 1 -or $replayGrants.Count -ne 1) {
            $errors.Add("Run '$runId' does not have exactly one replayed grant.")
            continue
        }
        if ($traceMatches.Count -ne 1) {
            $errors.Add(
                "Run '$runId' does not map by run/PID/start identity to exactly one strict trace root.")
            continue
        }
        $traceState = $traceMatches[0]
        $replayNodes = [int](
            Get-PhaseOneRecordProperty -Record $replayGrants[0] -Name Nodes)
        $traceGrantedNodes = [int](
            Get-PhaseOneRecordProperty -Record $traceState -Name GrantedNodes)
        if ($replayNodes -ne $traceGrantedNodes) {
            $errors.Add(
                "Run '$runId' replay grant $replayNodes does not match trace grant $traceGrantedNodes.")
            continue
        }
        $requestedArguments = @(
            Get-PhaseOneRecordProperty `
                -Record (Get-PhaseOneRecordProperty -Record $run -Name Command) `
                -Name Arguments |
                Where-Object { [string]$_ -match '^/m:(?<nodes>\d+)$' }
        )
        if ($requestedArguments.Count -ne 1) {
            $errors.Add("Run '$runId' does not declare exactly one requested node count.")
            continue
        }
        [void]([string]$requestedArguments[0] -match '^/m:(?<nodes>\d+)$')
        $requestedNodes = [int]$Matches.nodes
        $traceRequestedNodes = [int](
            Get-PhaseOneRecordProperty -Record $traceState -Name RequestedNodes)
        if ($requestedNodes -ne $traceRequestedNodes) {
            $errors.Add(
                "Run '$runId' requested $requestedNodes nodes but trace recorded $traceRequestedNodes.")
            continue
        }
        [void]$validatedGrantRunIds.Add($runId)
    }
    $injectedRuns = @(
        $Runs |
            Where-Object {
                [string](Get-PhaseOneRecordProperty -Record $_ -Name Kind) -eq 'injected'
            }
    )
    if ($injectedRuns.Count -ne 1 -or
        -not $validatedGrantRunIds.Contains([string]$injectedRuns[0].RunId)) {
        $errors.Add('The injected run does not have a matching replay/trace grant identity.')
    }

    if ($Trace.Consistent -ne $true) {
        $errors.Add("Strict Coordinator trace is inconsistent: $(@($Trace.Errors) -join '; ')")
    }
    if ($Trace.DeferredGrantOccurred -ne $true) {
        $errors.Add('Coordinator trace did not contain a deferred grant.')
    }
    if ([int]$Trace.FinalQueueDepth -ne 0 -or
        [int]$Trace.FinalActiveBuilds -ne 0 -or
        [int]$Trace.FinalAllocatedNodes -ne 0) {
        $errors.Add('Coordinator trace did not finish with zero queue, active builds, and allocation.')
    }
    $maximumQueueDepth = @($Trace.Timeline.QueueDepth | Measure-Object -Maximum).Maximum
    if ($null -eq $maximumQueueDepth -or [int]$maximumQueueDepth -lt 1) {
        $errors.Add('Coordinator trace did not exercise queue behavior.')
    }
    $acceptCount = @($Trace.Events | Where-Object Event -eq 'Accept').Count
    if ($acceptCount -ne 1) {
        $errors.Add("Coordinator trace contains $acceptCount server accept events; expected one unique coordinator.")
    }
    if (@($Trace.RootStates).Count -ne $Runs.Count) {
        $errors.Add("Coordinator trace mapped $(@($Trace.RootStates).Count) roots for $($Runs.Count) runs.")
    }

    $drained = if ($eventIndexes.ContainsKey('Drained')) {
        $Events[$eventIndexes.Drained[0]]
    }
    else {
        $null
    }
    if ($null -ne $drained -and
        ([int](Get-PhaseOneRecordProperty -Record $drained -Name FinalActiveWorkers) -ne 0 -or
        [int](Get-PhaseOneRecordProperty -Record $drained -Name FinalQueueDepth) -ne 0 -or
        [int](Get-PhaseOneRecordProperty -Record $drained -Name FinalAllocatedNodes) -ne 0)) {
        $errors.Add('Drained marker does not record a zero final state.')
    }

    [pscustomobject][ordered]@{
        Valid = $errors.Count -eq 0
        Errors = $errors.ToArray()
        ControllerValidation = $controller
        InitialLaunchCount = @($Events | Where-Object Event -eq 'Launched').Count
        ReplacementCount = @($Events | Where-Object Event -eq 'ReplacementLaunched').Count
        MeasuredCompletionCount = [int]$controller.MeasuredCompletionCount
        InjectionAfterCompletion = $InjectionCompletion
        EndingCompletion = $EndingCompletion
        RunCount = $Runs.Count
        ReplayCount = $Replays.Count
        ValidatedGrantRunCount = $validatedGrantRunIds.Count
        MaximumQueueDepth = $maximumQueueDepth
        FinalQueueDepth = [int]$Trace.FinalQueueDepth
        FinalActiveBuilds = [int]$Trace.FinalActiveBuilds
        FinalAllocatedNodes = [int]$Trace.FinalAllocatedNodes
        ActiveWorkersAtEnd = [int]$controller.ActiveWorkersAtEnd
    }
}

function Get-PhaseOneProcessCleanupAudit {
    param(
        [object[]]$RegistryEntries = @(),
        [object[]]$RootIdentities = @(),
        [string[]]$DescendantIdentities = @(),
        [scriptblock]$ProcessQuery
    )

    $records = [Collections.Generic.List[object]]::new()
    foreach ($entry in $RegistryEntries) {
        if ($null -eq $entry) {
            continue
        }
        if ((Get-PhaseOneRecordProperty `
            -Record $entry `
            -Name VerifiedStartIdentity) -ne $true -or
            [string]::IsNullOrWhiteSpace([string]$entry.ProcessStartUtc)) {
            $records.Add([pscustomobject]@{
                Kind = [string]$entry.Kind
                ProcessId = [int]$entry.ProcessId
                ProcessStartUtc = $null
                Status = 'UnverifiableStartIdentity'
                Live = $null
                Error = [string]$entry.IdentityCaptureError
            })
            continue
        }
        $status = Get-VerifiedProcessIdentityStatus `
            -ProcessId ([int]$entry.ProcessId) `
            -ProcessStartUtc $entry.ProcessStartUtc `
            -ProcessQuery $ProcessQuery
        $records.Add([pscustomobject]@{
            Kind = [string]$entry.Kind
            ProcessId = [int]$entry.ProcessId
            ProcessStartUtc = [string]$entry.ProcessStartUtc
            Status = $status.Status
            Live = $status.Live
            Error = $status.Error
        })
    }
    foreach ($identity in $RootIdentities) {
        if ($null -eq $identity) {
            continue
        }
        $status = Get-VerifiedProcessIdentityStatus `
            -ProcessId ([int]$identity.ProcessId) `
            -ProcessStartUtc $identity.ProcessStartUtc `
            -ProcessQuery $ProcessQuery
        $records.Add([pscustomobject]@{
            Kind = [string]$identity.Kind
            ProcessId = [int]$identity.ProcessId
            ProcessStartUtc = [string]$identity.ProcessStartUtc
            Status = $status.Status
            Live = $status.Live
            Error = $status.Error
        })
    }
    foreach ($identity in $DescendantIdentities | Sort-Object -Unique) {
        $parts = $identity -split '\|', 2
        if ($parts.Count -ne 2) {
            $records.Add([pscustomobject]@{
                Kind = 'captured-descendant'
                ProcessId = $null
                ProcessStartUtc = $null
                Status = 'InvalidIdentity'
                Live = $null
                Error = "Invalid captured identity '$identity'."
            })
            continue
        }
        $status = Get-VerifiedProcessIdentityStatus `
            -ProcessId ([int]$parts[0]) `
            -ProcessStartUtc $parts[1] `
            -ProcessQuery $ProcessQuery
        $records.Add([pscustomobject]@{
            Kind = 'captured-descendant'
            ProcessId = [int]$parts[0]
            ProcessStartUtc = $parts[1]
            Status = $status.Status
            Live = $status.Live
            Error = $status.Error
        })
    }
    $failures = @(
        $records |
            Where-Object {
                $_.Status -notin @('ConfirmedAbsent', 'IdentityMismatch')
            }
    )
    [pscustomobject][ordered]@{
        Valid = $failures.Count -eq 0
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        CapturedIdentityCount = $records.Count
        LiveIdentityCount = @($records | Where-Object Live).Count
        QueryFailureCount = @($records | Where-Object Status -eq 'QueryFailed').Count
        UnverifiableIdentityCount = @(
            $records |
                Where-Object Status -in @(
                    'QueryFailed',
                    'UnverifiableStartIdentity',
                    'InvalidIdentity')
        ).Count
        Identities = $records.ToArray()
    }
}

function Invoke-PhaseOneRegisteredProcessAudit {
    param(
        [Parameter(Mandatory)]
        [string]$RegistryPath,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 15
    )

    $entries = @(Get-ToolingProcessRegistry)
    $stop = Stop-RegisteredProcessTrees `
        -Entries $entries `
        -TimeoutSeconds $TimeoutSeconds
    $audit = Get-PhaseOneProcessCleanupAudit -RegistryEntries $entries
    $registryExists = Test-Path -LiteralPath $RegistryPath -PathType Leaf
    $persistedEntryCount = if ($registryExists) {
        @(
            Get-Content -LiteralPath $RegistryPath |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        ).Count
    }
    else {
        0
    }
    [pscustomobject][ordered]@{
        Valid =
            $stop.Succeeded -and
            $audit.Valid -and
            $registryExists -and
            $persistedEntryCount -eq $entries.Count
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        RegistryPath = $RegistryPath
        RegistrySha256 = if ($registryExists) {
            (Get-FileHash -LiteralPath $RegistryPath -Algorithm SHA256).Hash
        }
        else {
            $null
        }
        RegistryEntryCount = $entries.Count
        PersistedRegistryEntryCount = $persistedEntryCount
        VerifiedStop = $stop
        Audit = $audit
    }
}
