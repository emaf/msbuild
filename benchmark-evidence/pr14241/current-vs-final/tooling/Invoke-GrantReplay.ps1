[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapRoot,
    [Parameter(Mandatory)]
    [string[]]$Binlog,
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [Parameter(Mandatory)]
    [string]$WorkRoot,
    [string]$JournalPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')

if ($Binlog.Count -eq 0) {
    throw 'At least one binlog is required.'
}
foreach ($path in $Binlog) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
        throw "Binlog '$path' is missing or empty."
    }
}
$definition = Get-CampaignDefinition
$sdk = Get-ChildItem -LiteralPath (Join-Path $BootstrapRoot 'sdk') -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
if ($null -eq $sdk) {
    throw "Bootstrap '$BootstrapRoot' has no SDK."
}
$productVersion = (Get-Item -LiteralPath (Join-Path $sdk.FullName 'MSBuild.dll')).VersionInfo.ProductVersion
$role = if ($productVersion.Contains($definition.Final.Commit, [StringComparison]::OrdinalIgnoreCase)) {
    'final'
}
else {
    'base'
}
$expectedCommit = if ($role -eq 'final') { $definition.Final.Commit } else { $definition.Base.Commit }
$bootstrap = Get-BootstrapIdentity -Role $role -Root $BootstrapRoot -ExpectedCommit $expectedCommit
if ([string]::IsNullOrWhiteSpace($JournalPath)) {
    $JournalPath = Join-Path $WorkRoot 'commands.jsonl'
}
New-Item -ItemType Directory -Force -Path $WorkRoot,(Split-Path -Parent $OutputPath) | Out-Null
$scannerRoot = Join-Path $WorkRoot "grant-replay-$($bootstrap.MSBuildDllSha256.Substring(0, 12))"
$scannerDll = Join-Path $scannerRoot 'GrantReplay.dll'
$buildMarker = Join-Path $scannerRoot 'build-identity.json'
if (-not (Test-Path -LiteralPath $scannerDll -PathType Leaf)) {
    New-Item -ItemType Directory -Force -Path $scannerRoot | Out-Null
    $project = Join-Path $PSScriptRoot 'GrantReplay\GrantReplay.csproj'
    $scannerEnvironment = @{
        DOTNET_ROOT = $bootstrap.Root
        DOTNET_ROOT_X64 = $bootstrap.Root
        DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        PATH = "$($bootstrap.Root)$([IO.Path]::PathSeparator)$([Environment]::GetEnvironmentVariable('PATH', 'Process'))"
    }
    foreach ($variable in Get-CoordinatorEnvironmentVariableNames) {
        $scannerEnvironment[$variable] = $null
    }
    $buildArguments = Get-GrantReplayBuildArguments `
        -ProjectPath $project `
        -ScannerRoot $scannerRoot `
        -MSBuildAssembliesRoot $bootstrap.SdkRoot
    [void](Invoke-RecordedCommand `
        -FileName $bootstrap.DotNetPath `
        -Arguments $buildArguments `
        -WorkingDirectory $scannerRoot `
        -JournalPath $JournalPath `
        -OutputDirectory (Join-Path $WorkRoot 'command-output') `
        -Label 'build-grant-replay' `
        -Environment $scannerEnvironment)
    Write-JsonAtomic -Path $buildMarker -Value ([pscustomobject][ordered]@{
        BuiltUtc = [DateTime]::UtcNow.ToString('O')
        BootstrapCommit = $bootstrap.ExpectedCommit
        BootstrapMSBuildSha256 = $bootstrap.MSBuildDllSha256
        ScannerSha256 = (Get-FileHash -LiteralPath $scannerDll -Algorithm SHA256).Hash
    })
}
else {
    if (-not (Test-Path -LiteralPath $buildMarker -PathType Leaf)) {
        throw "Grant replay scanner '$scannerRoot' has no build identity."
    }
    $marker = Get-Content -LiteralPath $buildMarker -Raw | ConvertFrom-Json
    if ($marker.BootstrapMSBuildSha256 -ne $bootstrap.MSBuildDllSha256 -or
        $marker.ScannerSha256 -ne (Get-FileHash -LiteralPath $scannerDll -Algorithm SHA256).Hash) {
        throw 'Existing grant replay scanner identity is invalid.'
    }
}

$listPath = Join-Path $WorkRoot "binlogs-$PID-$([guid]::NewGuid().ToString('N')).txt"
try {
    $replayEnvironment = @{
        DOTNET_ROOT = $bootstrap.Root
        DOTNET_ROOT_X64 = $bootstrap.Root
        DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        PATH = "$($bootstrap.Root)$([IO.Path]::PathSeparator)$([Environment]::GetEnvironmentVariable('PATH', 'Process'))"
    }
    foreach ($variable in Get-CoordinatorEnvironmentVariableNames) {
        $replayEnvironment[$variable] = $null
    }
    [IO.File]::WriteAllLines($listPath, $Binlog, [Text.UTF8Encoding]::new($false))
    [void](Invoke-RecordedCommand `
        -FileName $bootstrap.DotNetPath `
        -Arguments @($scannerDll, '--output', $OutputPath, '--list', $listPath) `
        -WorkingDirectory $WorkRoot `
        -JournalPath $JournalPath `
        -OutputDirectory (Join-Path $WorkRoot 'command-output') `
        -Label 'replay-grants' `
        -Environment $replayEnvironment)
}
finally {
    Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue
}

$results = @(Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json)
if ($results.Count -ne $Binlog.Count) {
    throw "Grant replay returned $($results.Count) result(s) for $($Binlog.Count) binlog(s)."
}
$results
