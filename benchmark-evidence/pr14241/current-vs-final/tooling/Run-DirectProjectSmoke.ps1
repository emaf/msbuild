[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootstrapIdentityPath,
    [Parameter(Mandatory)]
    [string]$PreparationPath,
    [Parameter(Mandatory)]
    [string]$OutputRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')

$campaign = Get-CampaignDefinition
$completionPath = Join-Path $OutputRoot 'completion.json'
if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json
    if (-not $existing.Valid -or @($existing.Smokes).Count -ne $campaign.Repositories.Count) {
        throw "Existing direct-project smoke checkpoint '$completionPath' is invalid."
    }
    Write-Host "DIRECT_PROJECT_SMOKE=$completionPath"
    return
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$smokes = [Collections.Generic.List[object]]::new()
foreach ($repository in $campaign.Repositories) {
    $repositoryRoot = Join-Path $OutputRoot $repository.Name
    $repositoryCompletion = Join-Path $repositoryRoot 'smoke-completion.json'
    if (Test-Path -LiteralPath $repositoryCompletion -PathType Leaf) {
        $smokes.Add((Get-Content -LiteralPath $repositoryCompletion -Raw | ConvertFrom-Json))
        continue
    }
    New-Item -ItemType Directory -Force -Path $repositoryRoot | Out-Null
    $existingAttempts = @(
        Get-ChildItem -LiteralPath $repositoryRoot -Directory -Filter 'attempt-*' -ErrorAction SilentlyContinue
    ).Count
    $validSmoke = $null
    for ($attempt = $existingAttempts + 1;
        $attempt -le $campaign.Validity.MaximumBlockAttempts;
        $attempt++) {
        $attemptRoot = Join-Path $repositoryRoot "attempt-$('{0:D2}' -f $attempt)"
        New-Item -ItemType Directory -Path $attemptRoot | Out-Null
        if ($attempt -gt 1) {
            & (Join-Path $PSScriptRoot 'Reset-PreparedWorktrees.ps1') `
                -BootstrapIdentityPath $BootstrapIdentityPath `
                -PreparationPath $PreparationPath `
                -RepositoryName $repository.Name `
                -Shape isolated `
                -Reason "Direct isolated project smoke retry $attempt after interrupted or externally invalid attempt." `
                -OutputRoot (Join-Path $attemptRoot 'prepared-baseline-reset')
        }
        $scenarioRoot = Join-Path $attemptRoot 'scenario'
        try {
            $validation = @(
                & (Join-Path $PSScriptRoot 'Invoke-Scenario.ps1') `
                    -BootstrapIdentityPath $BootstrapIdentityPath `
                    -PreparationPath $PreparationPath `
                    -Shape isolated `
                    -RepositoryName $repository.Name `
                    -Condition FINAL-N `
                    -BlockNumber 0 `
                    -AttemptNumber $attempt `
                    -OrderIndex 1 `
                    -ScenarioRoot $scenarioRoot
            ) | Select-Object -Last 1
        }
        catch {
            $validation = [pscustomobject]@{
                Disposition = 'InvalidRetryable'
                HarnessErrors = @($_.Exception.Message)
                ExternalValidityErrors = @()
            }
        }
        if ($validation.Disposition -eq 'TestedConditionPolicyOutcome') {
            throw "Direct $($repository.Name) project smoke produced a non-retriable tested-condition outcome."
        }
        if ($validation.Disposition -ne 'Valid') {
            Write-JsonAtomic -Path (Join-Path $attemptRoot 'invalid-attempt.json') -Value ([pscustomobject][ordered]@{
                CompletedUtc = [DateTime]::UtcNow.ToString('O')
                Disposition = 'InvalidRetryable'
                Errors = @($validation.HarnessErrors + $validation.ExternalValidityErrors)
            })
            continue
        }
        $metricsPath = Join-Path $scenarioRoot 'scenario-metrics.json'
        $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
        if ([int]$metrics.GrantedNodes -ne 8 -or [double]$metrics.EndToEndSeconds -le 0) {
            throw "Direct $($repository.Name) FINAL-N project smoke did not prove an 8-node isolated grant and positive duration."
        }
        $validSmoke = [pscustomobject][ordered]@{
            CompletedUtc = [DateTime]::UtcNow.ToString('O')
            Valid = $true
            Repository = $repository.Name
            RepositoryCommit = $repository.Commit
            BuildPath = $repository.BuildPath
            TouchPath = $repository.TouchPath
            Condition = 'FINAL-N'
            GrantedNodes = [int]$metrics.GrantedNodes
            EndToEndSeconds = [double]$metrics.EndToEndSeconds
            ExcludedFromMeasuredAnalysis = $true
            AttemptNumber = $attempt
            ScenarioRoot = $scenarioRoot
            MetricsSha256 = (Get-FileHash -LiteralPath $metricsPath -Algorithm SHA256).Hash
        }
        Write-JsonAtomic -Path (Join-Path $attemptRoot 'valid-attempt.json') -Value $validSmoke
        Write-JsonAtomic -Path $repositoryCompletion -Value $validSmoke
        break
    }
    if ($null -eq $validSmoke) {
        throw "Direct $($repository.Name) project smoke exhausted all validity attempts."
    }
    $smokes.Add($validSmoke)
}
Write-JsonAtomic -Path $completionPath -Value ([pscustomobject][ordered]@{
    SchemaVersion = 1
    CompletedUtc = [DateTime]::UtcNow.ToString('O')
    Valid = $true
    WorkloadKind = 'representative-propagated-project-isolated-smoke'
    SmokesExcluded = $true
    Smokes = $smokes.ToArray()
}) -Depth 8
Write-Host "DIRECT_PROJECT_SMOKE=$completionPath"
