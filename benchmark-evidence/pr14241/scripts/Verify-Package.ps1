[CmdletBinding()]
param(
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$errors = [Collections.Generic.List[string]]::new()
$manifestPath = Join-Path $PackageRoot 'manifest.csv'
$manifest = @(Import-Csv -LiteralPath $manifestPath)
foreach ($row in $manifest) {
    $path = Join-Path $PackageRoot ($row.Path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing manifest file '$($row.Path)'.")
        continue
    }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -ne [int64]$row.Bytes) {
        $errors.Add("Length mismatch for '$($row.Path)'.")
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $row.SHA256) {
        $errors.Add("Hash mismatch for '$($row.Path)'.")
    }
}

$reportPath = Join-Path $PackageRoot 'validated-report.md'
$report = Get-Content -LiteralPath $reportPath -Raw
foreach ($match in [regex]::Matches($report, '\]\(([^)]+)\)')) {
    $target = $match.Groups[1].Value
    if ($target -match '^(https?://|#)') {
        continue
    }
    $path = Join-Path $PackageRoot ($target -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) {
        $errors.Add("Broken report link '$target'.")
    }
}

$grantValidation = Get-Content (Join-Path $PackageRoot 'evidence\idle-burst\grant-validation.json') -Raw | ConvertFrom-Json
if (-not [bool]$grantValidation.Valid -or
    [int]$grantValidation.BinlogsReplayed -ne 200 -or
    [int]$grantValidation.GrantEvents -ne 200) {
    $errors.Add('Idle-burst grant validation does not record 200 valid one-grant binlogs.')
}

$comparisonRows = @(Import-Csv (Join-Path $PackageRoot 'recomputed-comparisons.csv'))
if ($comparisonRows.Count -ne 49) {
    $errors.Add("Expected 49 recomputed comparison rows; found $($comparisonRows.Count).")
}

if ($errors.Count -gt 0) {
    throw "Package verification failed:`n$($errors -join [Environment]::NewLine)"
}

Write-Host "PACKAGE_VALID=True"
Write-Host "MANIFEST_FILES=$($manifest.Count)"
Write-Host "COMPARISON_ROWS=$($comparisonRows.Count)"
Write-Host "RAW_BINLOGS=Indexed but intentionally not committed"
