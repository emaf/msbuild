[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunRoot,

    [Parameter(Mandatory)]
    [ValidateSet(8, 10)]
    [int]$WorkerCount,

    [string]$PreparationPath =
        'C:\perf\results\current-vs-final-sustained-pilot-20260813\preparation\preparation-completion.json'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolingRoot = Split-Path -Parent $PSScriptRoot
$sustainedRoot = Join-Path $toolingRoot 'sustained'
. (Join-Path $toolingRoot 'Campaign.Common.ps1')
. (Join-Path $sustainedRoot 'SustainedCampaign.Common.ps1')

if (Test-Path -LiteralPath $RunRoot) {
    throw "Fresh measured root '$RunRoot' already exists."
}
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$startedUtc = [DateTimeOffset]::UtcNow
$hardDeadlineUtc = $startedUtc.AddHours(8)
$statusPath = Join-Path $RunRoot 'status.json'

function Set-SimpleCampaignStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Step,
        [string]$Detail,
        [ValidateSet('Running', 'Succeeded', 'Failed')]
        [string]$Status = 'Running'
    )

    Write-JsonAtomic `
        -Path $statusPath `
        -Value ([pscustomobject][ordered]@{
            UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('O')
            Status = $Status
            ProcessId = $PID
            ProcessStartUtc =
                (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('O')
            RunRoot = $RunRoot
            Step = $Step
            Detail = $Detail
            WorkerCount = $WorkerCount
            HardDeadlineUtc = $hardDeadlineUtc.ToString('O')
            AutomaticRelaunch = $false
        })
}

function Assert-SimpleDeadline {
    if ([DateTimeOffset]::UtcNow -ge $hardDeadlineUtc) {
        throw 'The measured campaign reached its hard eight-hour deadline.'
    }
}

function Reset-SimpleScenarioWorktrees {
    param(
        [Parameter(Mandatory)]
        [string]$Repository,
        [Parameter(Mandatory)]
        [string]$OutputRoot,
        [Parameter(Mandatory)]
        [string]$Reason
    )

    & (Join-Path $sustainedRoot 'Reset-SustainedWorktrees.ps1') `
        -BootstrapIdentityPath $preparation.BootstrapIdentityPath `
        -PreparationPath $PreparationPath `
        -RepositoryName $Repository `
        -WorkerCount $WorkerCount `
        -Reason $Reason `
        -OutputRoot $OutputRoot `
        -AllowContentHashDrift
}

function Invoke-SimpleScenario {
    param(
        [Parameter(Mandatory)]
        [string]$Repository,
        [Parameter(Mandatory)]
        [string]$Condition,
        [Parameter(Mandatory)]
        [string]$ScenarioRoot
    )

    & (Join-Path $PSScriptRoot 'Invoke-SimpleSustainedScenario.ps1') `
        -RepositoryName $Repository `
        -Condition $Condition `
        -WorkerCount $WorkerCount `
        -ScenarioRoot $ScenarioRoot `
        -PreparationPath $PreparationPath `
        -WindowSeconds 480 `
        -InjectionOffsetSeconds 240 `
        -OnsetTimeoutSeconds 900
}

Set-SimpleCampaignStatus `
    -Step 'initializing' `
    -Detail 'Validating immutable stages, preparation, and the fixed campaign plan.'

$preparation =
    Get-Content -LiteralPath $PreparationPath -Raw |
    ConvertFrom-Json
if (-not $preparation.Authoritative -or
    [int]$preparation.WorkerCapacity -lt $WorkerCount -or
    $preparation.BootstrapIdentities.Base.Commit -ne
        'ff5b281f0c5828dec0d092fcd1b682019de7d1ca' -or
    $preparation.BootstrapIdentities.Final.Commit -ne
        '432466e41a95f9bbb25cad7ff9bd1b89b4a6bcef') {
    throw 'Preserved preparation does not match the exact campaign.'
}

$stageRecords = [Collections.Generic.List[object]]::new()
foreach ($stageRoot in @(
    'C:\perf\bootstraps\current-vs-final\ff5b281f0c58-2E843FFB6575',
    'C:\perf\bootstraps\current-vs-final\432466e41a95-3B4AF511ED65'
)) {
    $stageMetadata =
        Get-Content `
            -LiteralPath (Join-Path $stageRoot 'staging-metadata.json') `
            -Raw |
        ConvertFrom-Json
    $actual = Get-DirectoryContentManifest -Root (Join-Path $stageRoot 'core')
    if ($actual.ContentSha256 -ne $stageMetadata.ContentSha256 -or
        $actual.FileCount -ne $stageMetadata.FileCount -or
        $actual.TotalBytes -ne $stageMetadata.TotalBytes) {
        throw "Immutable stage '$stageRoot' failed full manifest validation."
    }
    $stageRecords.Add([pscustomobject][ordered]@{
        Role = $stageMetadata.Role
        ExpectedCommit = $stageMetadata.ExpectedCommit
        ProductVersion = $stageMetadata.ProductVersion
        Root = Join-Path $stageRoot 'core'
        ContentSha256 = $actual.ContentSha256
        FileCount = $actual.FileCount
        TotalBytes = $actual.TotalBytes
        DotNetSha256 =
            ($stageMetadata.TrackedIdentityFiles |
                Where-Object Name -eq 'dotnet.exe' |
                Select-Object -First 1).Sha256
        MSBuildSha256 =
            ($stageMetadata.TrackedIdentityFiles |
                Where-Object Name -eq 'MSBuild.dll' |
                Select-Object -First 1).Sha256
        DotNetInfo = @(
            & (Join-Path $stageRoot 'core\dotnet.exe') --info
        )
    })
}

& git merge-base --is-ancestor `
    ff5b281f0c5828dec0d092fcd1b682019de7d1ca `
    432466e41a95f9bbb25cad7ff9bd1b89b4a6bcef
if ($LASTEXITCODE -ne 0) {
    throw 'BASE is not an ancestor of FINAL.'
}

$orders = @(
    [pscustomobject]@{
        AnalysisBlock = 0
        IsWarmup = $true
        Conditions = @('BASE', 'FINAL-N', 'FINAL-H')
    },
    [pscustomobject]@{
        AnalysisBlock = 1
        IsWarmup = $false
        Conditions = @('BASE', 'FINAL-N', 'FINAL-H')
    },
    [pscustomobject]@{
        AnalysisBlock = 2
        IsWarmup = $false
        Conditions = @('FINAL-N', 'FINAL-H', 'BASE')
    },
    [pscustomobject]@{
        AnalysisBlock = 3
        IsWarmup = $false
        Conditions = @('FINAL-H', 'BASE', 'FINAL-N')
    }
)
$planRows = [Collections.Generic.List[object]]::new()
foreach ($repository in @('roslyn', 'aspire')) {
    foreach ($block in $orders) {
        for ($position = 0; $position -lt 3; $position++) {
            $planRows.Add([pscustomobject][ordered]@{
                Repository = $repository
                AnalysisBlock = $block.AnalysisBlock
                IsWarmup = $block.IsWarmup
                Position = $position + 1
                Condition = $block.Conditions[$position]
            })
        }
    }
}
$planRows |
    Export-Csv `
        -NoTypeInformation `
        -LiteralPath (Join-Path $RunRoot 'matrix-plan.csv')
Write-JsonAtomic `
    -Path (Join-Path $RunRoot 'run-metadata.json') `
    -Value ([pscustomobject][ordered]@{
        SchemaVersion = 1
        StartedUtc = $startedUtc.ToString('O')
        HardDeadlineUtc = $hardDeadlineUtc.ToString('O')
        WorkerCount = $WorkerCount
        WindowSeconds = 480
        InjectionOffsetSeconds = 240
        BaseCommit = 'ff5b281f0c5828dec0d092fcd1b682019de7d1ca'
        FinalCommit = '432466e41a95f9bbb25cad7ff9bd1b89b4a6bcef'
        PreparationPath = $PreparationPath
        Stages = $stageRecords.ToArray()
        Plan = $planRows.ToArray()
        MaximumAttemptsPerBlock = 2
        AutomaticRelaunch = $false
    }) `
    -Depth 16

$campaignError = $null
try {
    foreach ($repository in @('roslyn', 'aspire')) {
        foreach ($block in $orders) {
            Assert-SimpleDeadline
            $kind = if ($block.IsWarmup) { 'warmup' } else { 'measured' }
            $blockRoot =
                Join-Path $RunRoot (
                    "$kind\$repository\block-$('{0:D2}' -f $block.AnalysisBlock)")
            New-Item -ItemType Directory -Force -Path $blockRoot | Out-Null
            $blockSucceeded = $false
            $attemptErrors = [Collections.Generic.List[string]]::new()
            foreach ($attempt in 1..2) {
                Assert-SimpleDeadline
                $attemptRoot =
                    Join-Path $blockRoot "attempt-$('{0:D2}' -f $attempt)"
                New-Item -ItemType Directory -Path $attemptRoot | Out-Null
                $attemptSucceeded = $true
                for ($position = 0; $position -lt 3; $position++) {
                    Assert-SimpleDeadline
                    $condition = $block.Conditions[$position]
                    Set-SimpleCampaignStatus `
                        -Step "$kind-$repository-block-$($block.AnalysisBlock)-attempt-$attempt-$condition" `
                        -Detail "Running fixed eight-minute position $($position + 1) of 3."
                    $scenarioRoot =
                        Join-Path $attemptRoot (
                            "$('{0:D2}' -f ($position + 1))-$condition")
                    try {
                        [void](Invoke-SimpleScenario `
                            -Repository $repository `
                            -Condition $condition `
                            -ScenarioRoot $scenarioRoot)
                    }
                    catch {
                        $attemptSucceeded = $false
                        $attemptErrors.Add(
                            "Attempt $attempt position $($position + 1) $condition failed: $($_.Exception.Message)")
                        break
                    }
                }
                if ($attemptSucceeded) {
                    $blockSucceeded = $true
                    Write-JsonAtomic `
                        -Path (Join-Path $blockRoot 'block-completion.json') `
                        -Value ([pscustomobject][ordered]@{
                            Valid = $true
                            Repository = $repository
                            AnalysisBlock = $block.AnalysisBlock
                            IsWarmup = $block.IsWarmup
                            Attempt = $attempt
                            Conditions = $block.Conditions
                            CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                        })
                    break
                }
            }
            if (-not $blockSucceeded) {
                throw "$kind $repository block $($block.AnalysisBlock) failed twice: $($attemptErrors -join '; ')"
            }
        }
    }

    Set-SimpleCampaignStatus `
        -Step 'analysis' `
        -Detail 'Computing paired n=3 directional estimates and evidence indexes.'
    & (Join-Path $PSScriptRoot 'Analyze-SimpleSustainedCampaign.ps1') `
        -RunRoot $RunRoot
    Set-SimpleCampaignStatus `
        -Step 'complete' `
        -Detail 'All warmup and measured blocks completed and analysis was generated.' `
        -Status Succeeded
}
catch {
    $campaignError = $_.Exception.ToString()
    Set-SimpleCampaignStatus `
        -Step 'failed' `
        -Detail $campaignError `
        -Status Failed
    throw
}

[pscustomobject][ordered]@{
    Valid = $null -eq $campaignError
    RunRoot = $RunRoot
    WorkerCount = $WorkerCount
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
    AnalysisRoot = Join-Path $RunRoot 'analysis'
}
