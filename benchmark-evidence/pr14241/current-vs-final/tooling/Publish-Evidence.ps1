[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot,
    [Parameter(Mandatory)]
    [string]$DestinationRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')

if (-not (Test-Path -LiteralPath (Join-Path $RunRoot 'analysis\analysis-validation.json') -PathType Leaf)) {
    throw "Run '$RunRoot' has no validated analysis."
}
$analysisValidation = Get-Content -LiteralPath (Join-Path $RunRoot 'analysis\analysis-validation.json') -Raw | ConvertFrom-Json
if (-not $analysisValidation.Valid) {
    throw 'Analysis is not valid and cannot be packaged.'
}
$allowedTopLevelDirectories = @(
    (Get-CampaignDefinition).Shapes.Key + @('analysis', '_setup', '_checkpoints')
)
$unsupportedShapeDirectories = @(
    Get-ChildItem -LiteralPath $RunRoot -Directory |
        Where-Object { $allowedTopLevelDirectories -notcontains $_.Name }
)
if ($unsupportedShapeDirectories.Count -gt 0) {
    throw "Unsupported contemporaneous result directories must not be published: $(@($unsupportedShapeDirectories.Name) -join ', ')."
}
if (Test-Path -LiteralPath $DestinationRoot) {
    throw "Destination '$DestinationRoot' already exists."
}
New-Item -ItemType Directory -Path $DestinationRoot | Out-Null

$replacements = [ordered]@{
    ([IO.Path]::GetFullPath($RunRoot)) = '%RESULT_ROOT%'
    ([IO.Path]::GetFullPath($PSScriptRoot)) = '%TOOLING_ROOT%'
    'C:\perf' = '%PERF_ROOT%'
    'C:\w\cvf' = '%WORKTREE_ROOT%'
}
$runMetadataPath = Join-Path $RunRoot 'run-metadata.json'
if (Test-Path -LiteralPath $runMetadataPath -PathType Leaf) {
    $runMetadata = Get-Content -LiteralPath $runMetadataPath -Raw | ConvertFrom-Json
    foreach ($propertyName in @('SourceRepositoryRoot', 'BuildWorktreeRoot', 'BootstrapStagingRoot', 'ToolingRoot')) {
        $property = $runMetadata.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $replacements[[string]$property.Value] = "%$($propertyName.ToUpperInvariant())%"
        }
    }
}
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $replacements[$env:USERPROFILE] = '%USERPROFILE%'
}
if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
    $replacements[$env:USERNAME] = '<user>'
}
if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
    $replacements[$env:COMPUTERNAME] = '<host>'
}

function ConvertTo-PublicText {
    param([string]$Text)

    $sanitized = $Text
    foreach ($replacement in $replacements.GetEnumerator()) {
        $sanitized = $sanitized.Replace(
            [string]$replacement.Key,
            [string]$replacement.Value,
            [StringComparison]::OrdinalIgnoreCase)
        $escapedKey = ([string]$replacement.Key).Replace('\', '\\')
        $sanitized = $sanitized.Replace(
            $escapedKey,
            [string]$replacement.Value,
            [StringComparison]::OrdinalIgnoreCase)
    }
    $sanitized = [regex]::Replace(
        $sanitized,
        'https://[^/@\s]+:[^@\s]+@',
        'https://',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $sanitized = [regex]::Replace(
        $sanitized,
        '(?<name>token|sig|signature|key|password|passwd|secret)=[^&\s"''<>]+',
        '${name}=<redacted>',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $sanitized = [regex]::Replace(
        $sanitized,
        '[A-Za-z]:\\Users\\[^\\\s"'']+',
        '%USERPROFILE%',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $sanitized
}

$allowlist = [Collections.Generic.List[string]]::new()
foreach ($relative in @(
    'run-metadata.json',
    'machine.json',
    'matrix-plan.csv',
    'matrix-plan.json',
    'plan-validation.json',
    'completion.json',
    '_setup\exact-build\bootstrap-identities.json',
    '_setup\tooling-validation\completion.json',
    '_setup\preflight\completion.json',
    '_setup\preparation\preparation-completion.json',
    '_setup\direct-project-smoke\completion.json',
    '_setup\project-timing-gate\completion.json',
    'analysis\analysis.json',
    'analysis\analysis-validation.json',
    'analysis\paired-values.csv',
    'analysis\comparisons.csv',
    'analysis\pr-facing-table.csv',
    'analysis\declared-exclusions.csv',
    'analysis\report.md'
)) {
    $source = Join-Path $RunRoot $relative
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        $allowlist.Add($source)
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RunRoot '_setup\preparation') -File -Filter 'disk-projection-*.json' -ErrorAction SilentlyContinue) {
        $allowlist.Add($file.FullName)
    }
}
foreach ($name in @('scenario-metrics.json', 'scenario-validation.json', 'controller-summary.json', 'block-completion.json')) {
    foreach ($file in Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter $name) {
        if ($file.FullName -notmatch '\\_setup\\') {
            $allowlist.Add($file.FullName)
        }
    }
}
foreach ($name in @('summary.json', 'events.csv', 'timeline.csv')) {
    foreach ($file in Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter $name) {
        if ($file.FullName -match '\\parsed-trace\\') {
            $allowlist.Add($file.FullName)
        }
    }
}
foreach ($file in Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Filter 'reset-completion.json') {
    $allowlist.Add($file.FullName)
}

$manifest = [Collections.Generic.List[object]]::new()
foreach ($source in $allowlist | Sort-Object -Unique) {
    if ($source -match '\.(binlog|dll|exe|pdb)$' -or
        $source -match '\\monitor\\|\\coordinator-debug\\|\\_tooling\\|\\runs\\') {
        throw "Raw or compiled artifact '$source' entered the public allowlist."
    }
    $relative = [IO.Path]::GetRelativePath($RunRoot, $source)
    $destination = Join-Path $DestinationRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    $text = Get-Content -LiteralPath $source -Raw
    [IO.File]::WriteAllText(
        $destination,
        (ConvertTo-PublicText -Text $text),
        [Text.UTF8Encoding]::new($false))
    $manifest.Add([pscustomobject][ordered]@{
        Path = $relative
        Bytes = (Get-Item -LiteralPath $destination).Length
        Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        SourceKind = 'sanitized-summary-allowlist'
    })
}
$manifest | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $DestinationRoot 'manifest.csv')
$sumLines = @(
    $manifest |
        Sort-Object Path |
        ForEach-Object { "$($_.Sha256)  $($_.Path.Replace('\', '/'))" }
)
[IO.File]::WriteAllLines(
    (Join-Path $DestinationRoot 'SHA256SUMS.txt'),
    $sumLines,
    [Text.UTF8Encoding]::new($false))

$scanErrors = [Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $DestinationRoot -Recurse -File) {
    if ($file.Extension -in @('.dll', '.exe', '.pdb', '.binlog')) {
        $scanErrors.Add("Forbidden public artifact '$($file.FullName)'.")
        continue
    }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and
        $text.Contains($env:USERNAME, [StringComparison]::OrdinalIgnoreCase)) {
        $scanErrors.Add("Username remains in '$($file.FullName)'.")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and
        $text.Contains($env:COMPUTERNAME, [StringComparison]::OrdinalIgnoreCase)) {
        $scanErrors.Add("Computer name remains in '$($file.FullName)'.")
    }
    if ($text -match 'https://[^/@\s]+:[^@\s]+@' -or
        $text -match '(?i)(token|sig|signature|password|passwd|secret)=[^<\s&]+' -or
        $text -match '(?i)[A-Za-z]:\\(?:\\)?Users\\') {
        $scanErrors.Add("Credential or machine-path pattern remains in '$($file.FullName)'.")
    }
}
Write-JsonAtomic -Path (Join-Path $DestinationRoot 'sanitization-report.json') -Value ([pscustomobject][ordered]@{
    CompletedUtc = [DateTime]::UtcNow.ToString('O')
    Valid = $scanErrors.Count -eq 0
    Errors = $scanErrors.ToArray()
    FileCount = $manifest.Count
    RawOriginalsMutated = $false
    ExcludedKinds = @('binlogs', 'raw telemetry', 'raw traces', 'stdout/stderr', 'generated worktrees', 'compiled grant scanner')
})
if ($scanErrors.Count -gt 0) {
    throw "Sanitization failed: $($scanErrors -join '; ')"
}
Write-Host "EVIDENCE_ROOT=$DestinationRoot"
