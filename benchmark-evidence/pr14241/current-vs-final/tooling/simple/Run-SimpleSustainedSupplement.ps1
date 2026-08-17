[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SupplementalRoot,

    [Parameter(Mandatory)]
    [string]$OriginalRoot,

    [string]$PreparationPath =
        'C:\perf\results\current-vs-final-sustained-pilot-20260813\preparation\preparation-completion.json'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolingRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolingRoot 'Campaign.Common.ps1')

if (Test-Path -LiteralPath $SupplementalRoot) {
    throw "Fresh supplemental root '$SupplementalRoot' already exists."
}
New-Item -ItemType Directory -Path $SupplementalRoot | Out-Null
$SupplementalRoot = (Resolve-Path -LiteralPath $SupplementalRoot).Path

$startedUtc = [DateTimeOffset]::UtcNow
$deadlineUtc = $startedUtc.AddHours(4)
$statusPath = Join-Path $SupplementalRoot 'status.json'
$blocks = @(
    [pscustomobject][ordered]@{
        AnalysisBlock = 2
        Conditions = @('FINAL-N', 'FINAL-H', 'BASE')
    },
    [pscustomobject][ordered]@{
        AnalysisBlock = 3
        Conditions = @('FINAL-H', 'BASE', 'FINAL-N')
    }
)

function Set-SupplementalStatus {
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
            SupplementalRoot = $SupplementalRoot
            OriginalRoot = $OriginalRoot
            Step = $Step
            Detail = $Detail
            WorkerCount = 8
            HardDeadlineUtc = $deadlineUtc.ToString('O')
            AutomaticRelaunch = $false
        })
}

function Assert-SupplementalDeadline {
    if ([DateTimeOffset]::UtcNow -ge $deadlineUtc) {
        throw 'The supplemental campaign reached its hard four-hour deadline.'
    }
}

$originalPlan = @(Import-Csv -LiteralPath (Join-Path $OriginalRoot 'matrix-plan.csv'))
foreach ($block in $blocks) {
    $expected = @(
        $originalPlan |
            Where-Object {
                $_.Repository -eq 'aspire' -and
                [int]$_.AnalysisBlock -eq $block.AnalysisBlock -and
                $_.IsWarmup -eq 'False'
            } |
            Sort-Object { [int]$_.Position } |
            Select-Object -ExpandProperty Condition
    )
    if (($expected -join ',') -ne ($block.Conditions -join ',')) {
        throw "Original Aspire block $($block.AnalysisBlock) order changed."
    }
}

$originalValid = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $OriginalRoot 'measured') `
        -Filter scenario-validation.json `
        -Recurse `
        -File |
        ForEach-Object {
            $record = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            if ($record.Valid) {
                [pscustomobject]@{
                    Path = $_.FullName
                    Repository = $record.Repository
                    Condition = $record.Condition
                }
            }
        }
)
if (@($originalValid | Where-Object Repository -eq roslyn).Count -ne 9 -or
    @($originalValid | Where-Object Repository -eq aspire).Count -ne 3) {
    throw 'Original accepted measured block set is incomplete or duplicated.'
}

Write-JsonAtomic `
    -Path (Join-Path $SupplementalRoot 'supplemental-metadata.json') `
    -Value ([pscustomobject][ordered]@{
        SchemaVersion = 1
        StartedUtc = $startedUtc.ToString('O')
        HardDeadlineUtc = $deadlineUtc.ToString('O')
        OriginalRoot = $OriginalRoot
        PreparationPath = $PreparationPath
        Repository = 'aspire'
        RepositoryCommit = '110a63da8357af437a00d9efc5887ffdcbdfbb3c'
        WorkerCount = 8
        WindowSeconds = 480
        InjectionOffsetSeconds = 240
        Blocks = $blocks
        MaximumAttemptsPerWholeBlock = 2
        ExcludedOriginalPartial =
            Join-Path $OriginalRoot 'measured\aspire\block-02\attempt-01\01-FINAL-N'
        NoPartialScenarioReuse = $true
        AutomaticRelaunch = $false
    }) `
    -Depth 10

try {
    foreach ($block in $blocks) {
        $blockRoot =
            Join-Path $SupplementalRoot (
                "measured\aspire\block-$('{0:D2}' -f $block.AnalysisBlock)")
        New-Item -ItemType Directory -Force -Path $blockRoot | Out-Null
        $blockSucceeded = $false
        $attemptErrors = [Collections.Generic.List[string]]::new()
        foreach ($attempt in 1..2) {
            Assert-SupplementalDeadline
            $attemptRoot =
                Join-Path $blockRoot "attempt-$('{0:D2}' -f $attempt)"
            New-Item -ItemType Directory -Path $attemptRoot | Out-Null
            $attemptSucceeded = $true
            for ($position = 0; $position -lt $block.Conditions.Count; $position++) {
                Assert-SupplementalDeadline
                $condition = $block.Conditions[$position]
                Set-SupplementalStatus `
                    -Step "aspire-block-$($block.AnalysisBlock)-attempt-$attempt-$condition" `
                    -Detail "Running full original block row, position $($position + 1) of 3."
                $scenarioRoot =
                    Join-Path $attemptRoot (
                        "$('{0:D2}' -f ($position + 1))-$condition")
                try {
                    [void](
                        & (Join-Path $PSScriptRoot 'Invoke-SimpleSustainedScenario.ps1') `
                            -RepositoryName aspire `
                            -Condition $condition `
                            -WorkerCount 8 `
                            -ScenarioRoot $scenarioRoot `
                            -PreparationPath $PreparationPath `
                            -WindowSeconds 480 `
                            -InjectionOffsetSeconds 240 `
                            -OnsetTimeoutSeconds 900)
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
                        Repository = 'aspire'
                        AnalysisBlock = $block.AnalysisBlock
                        Attempt = $attempt
                        Conditions = $block.Conditions
                        CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    })
                break
            }
        }
        if (-not $blockSucceeded) {
            throw "Aspire block $($block.AnalysisBlock) failed twice: $($attemptErrors -join '; ')"
        }
    }

    Set-SupplementalStatus `
        -Step complete `
        -Detail 'Aspire measured blocks 2 and 3 completed as full accepted rows.' `
        -Status Succeeded
}
catch {
    Set-SupplementalStatus `
        -Step failed `
        -Detail $_.Exception.ToString() `
        -Status Failed
    throw
}

[pscustomobject][ordered]@{
    Valid = $true
    OriginalRoot = $OriginalRoot
    SupplementalRoot = $SupplementalRoot
    CompletedUtc = [DateTimeOffset]::UtcNow.ToString('O')
}
