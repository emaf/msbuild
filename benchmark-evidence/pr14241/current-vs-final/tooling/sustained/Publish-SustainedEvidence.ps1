[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot,
    [string]$DestinationRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SustainedCampaign.Common.ps1')

$evidenceParent = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\sustained'))
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $DestinationRoot = Join-Path $evidenceParent (
        Split-Path -Leaf ([IO.Path]::GetFullPath($RunRoot)))
}
$destination = [IO.Path]::GetFullPath($DestinationRoot)
if (-not $destination.StartsWith(
    $evidenceParent.TrimEnd('\') + '\',
    [StringComparison]::OrdinalIgnoreCase)) {
    throw "Sanitized sustained evidence must be packaged below '$evidenceParent'."
}
$analysisValidationPath =
    Join-Path $RunRoot 'analysis\analysis-validation.json'
if (-not (Test-Path -LiteralPath $analysisValidationPath -PathType Leaf)) {
    throw "Run '$RunRoot' has no sustained analysis validation."
}
$analysisValidation =
    Get-Content -LiteralPath $analysisValidationPath -Raw |
    ConvertFrom-Json
if (-not $analysisValidation.Valid) {
    throw 'Invalid sustained analysis cannot be packaged.'
}
if (Test-Path -LiteralPath $destination) {
    throw "Destination '$destination' already exists."
}
New-Item -ItemType Directory -Path $destination | Out-Null

$replacements = [ordered]@{
    ([IO.Path]::GetFullPath($RunRoot)) = '%RESULT_ROOT%'
    ([IO.Path]::GetFullPath($PSScriptRoot)) = '%TOOLING_ROOT%'
    'C:\perf' = '%PERF_ROOT%'
    'C:\w\cvf' = '%WORKTREE_ROOT%'
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

function ConvertTo-SustainedPublicText {
    param([Parameter(Mandatory)][string]$Text)

    $sanitized = $Text
    foreach ($replacement in $replacements.GetEnumerator()) {
        $sanitized = $sanitized.Replace(
            [string]$replacement.Key,
            [string]$replacement.Value,
            [StringComparison]::OrdinalIgnoreCase)
        $sanitized = $sanitized.Replace(
            ([string]$replacement.Key).Replace('\', '\\'),
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
    '_setup\preparation\preparation-completion.json',
    '_setup\pilots\pilot-completion.json',
    'analysis\analysis.json',
    'analysis\analysis-validation.json',
    'analysis\raw-metrics.csv',
    'analysis\raw-metrics.json',
    'analysis\paired-values.csv',
    'analysis\comparisons.csv',
    'analysis\comparisons.json',
    'analysis\formulas.json',
    'analysis\pr-facing-table.csv',
    'analysis\declared-exclusions.csv',
    'analysis\report.md'
)) {
    $source = Join-Path $RunRoot $relative
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        $allowlist.Add($source)
    }
}
foreach ($name in @(
    'scenario-metrics.json',
    'scenario-validation.json',
    'controller-summary.json',
    'block-completion.json'
)) {
    foreach ($file in Get-ChildItem `
        -LiteralPath $RunRoot `
        -Recurse `
        -File `
        -Filter $name) {
        if ($file.FullName -notmatch '\\_setup\\pilots\\workers-\d+\\.*\\scenario\\runs\\') {
            $allowlist.Add($file.FullName)
        }
    }
}
foreach ($name in @('summary.json', 'events.csv', 'timeline.csv')) {
    foreach ($file in Get-ChildItem `
        -LiteralPath $RunRoot `
        -Recurse `
        -File `
        -Filter $name) {
        if ($file.FullName -match '\\parsed-trace\\') {
            $allowlist.Add($file.FullName)
        }
    }
}

$manifest = [Collections.Generic.List[object]]::new()
foreach ($source in $allowlist | Sort-Object -Unique) {
    if ($source -match '\.(binlog|dll|exe|pdb)$' -or
        $source -match '\\monitor\\|\\coordinator-debug\\|\\_tooling\\|\\runs\\|\\command-output\\' -or
        [IO.Path]::GetFileName($source) -in @(
            'stdout.log',
            'stderr.log',
            'environment.json',
            'commands.jsonl')) {
        throw "Raw or compiled artifact '$source' entered the sustained public allowlist."
    }
    $relative = [IO.Path]::GetRelativePath($RunRoot, $source)
    $target = Join-Path $destination $relative
    New-Item -ItemType Directory -Force -Path (
        Split-Path -Parent $target) | Out-Null
    [IO.File]::WriteAllText(
        $target,
        (ConvertTo-SustainedPublicText `
            -Text (Get-Content -LiteralPath $source -Raw)),
        [Text.UTF8Encoding]::new($false))
    $manifest.Add([pscustomobject][ordered]@{
        Path = $relative
        Bytes = (Get-Item -LiteralPath $target).Length
        Sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        SourceKind = 'sanitized-sustained-summary-allowlist'
    })
}
$manifest |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $destination 'manifest.csv')
[IO.File]::WriteAllLines(
    (Join-Path $destination 'SHA256SUMS.txt'),
    @(
        $manifest |
            Sort-Object Path |
            ForEach-Object {
                "$($_.Sha256)  $($_.Path.Replace('\', '/'))"
            }
    ),
    [Text.UTF8Encoding]::new($false))

$scanErrors = [Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $destination -Recurse -File) {
    if ($file.Extension -in @('.dll', '.exe', '.pdb', '.binlog')) {
        $scanErrors.Add("Forbidden public artifact '$($file.FullName)'.")
        continue
    }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ((-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and
            $text.Contains(
                $env:USERNAME,
                [StringComparison]::OrdinalIgnoreCase)) -or
        (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and
            $text.Contains(
                $env:COMPUTERNAME,
                [StringComparison]::OrdinalIgnoreCase)) -or
        $text -match 'https://[^/@\s]+:[^@\s]+@' -or
        $text -match
            '(?i)(token|sig|signature|password|passwd|secret)=[^<\s&]+' -or
        $text -match '(?i)[A-Za-z]:\\(?:\\)?Users\\') {
        $scanErrors.Add("Sensitive machine or credential pattern remains in '$($file.FullName)'.")
    }
}
$report = [pscustomobject][ordered]@{
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Valid = $scanErrors.Count -eq 0
    Errors = $scanErrors.ToArray()
    FileCount = $manifest.Count
    DestinationRoot = $destination
    DestinationConstrainedBelow =
        $evidenceParent
    RawOriginalsMutated = $false
    ExcludedKinds = @(
        'binlogs',
        'raw telemetry',
        'raw debug traces',
        'stdout/stderr',
        'environment dumps',
        'generated worktrees',
        'compiled grant scanner'
    )
}
Write-JsonAtomic `
    -Path (Join-Path $destination 'sanitization-report.json') `
    -Value $report
if ($scanErrors.Count -gt 0) {
    throw "Sustained sanitization failed: $($scanErrors -join '; ')"
}
Write-Host "SUSTAINED_EVIDENCE_ROOT=$destination"
