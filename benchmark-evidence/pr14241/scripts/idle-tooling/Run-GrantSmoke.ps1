[CmdletBinding()]
param(
    [string]$BootstrapRoot = 'C:\perf\coordinator-bootstrap-staging\dcf76ee0204f-F8B91508ED12\core',
    [string]$OutputRoot = 'C:\perf\results\idle-node-burst-functional-smoke'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$dotnet = Join-Path $BootstrapRoot 'dotnet.exe'
$sdk = Get-ChildItem -LiteralPath (Join-Path $BootstrapRoot 'sdk') -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
$msbuild = Join-Path $sdk.FullName 'MSBuild.dll'
$project = Join-Path $PSScriptRoot 'Smoke.proj'
$scanner = Join-Path $PSScriptRoot 'GrantScan\bin\Release\net10.0\GrantScan.dll'
$coordinatorVariables = @(
    'MSBUILDUSECOORDINATOR',
    'MSBUILDCOORDINATORPIPENAME',
    'MSBUILDCOORDINATORNODEBUDGET',
    'MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES',
    'MSBUILDCOORDINATORMAXNODESPERBUILD',
    'MSBUILDCOORDINATORPRIORITYAGINGTHRESHOLD',
    'MSBUILDCOORDINATORBUILDREQUESTPRIORITY'
)

function Start-SmokeBuild {
    param(
        [string]$ScenarioRoot,
        [string]$PipeName,
        [string]$Label,
        [string]$Priority,
        [int]$HoldSeconds,
        [bool]$AutomaticPolicy,
        [int]$Slice,
        [int]$Reservation
    )

    $stdout = Join-Path $ScenarioRoot "$Label.stdout.log"
    $stderr = Join-Path $ScenarioRoot "$Label.stderr.log"
    $binlog = Join-Path $ScenarioRoot "$Label.binlog"
    $startInfo = [Diagnostics.ProcessStartInfo]::new($dotnet)
    foreach ($argument in @(
        $msbuild,
        $project,
        '/m:16',
        '/v:n',
        '/nodeReuse:false',
        "/p:HoldSeconds=$HoldSeconds",
        "/bl:$binlog;ProjectImports=None"
    )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in $coordinatorVariables) {
        [void]$startInfo.Environment.Remove($name)
    }
    $startInfo.Environment['DOTNET_ROOT'] = $BootstrapRoot
    $startInfo.Environment['DOTNET_ROOT_X64'] = $BootstrapRoot
    $startInfo.Environment['MSBUILDUSECOORDINATOR'] = '1'
    $startInfo.Environment['MSBUILDCOORDINATORPIPENAME'] = $PipeName
    $startInfo.Environment['MSBUILDCOORDINATORNODEBUDGET'] = '16'
    $startInfo.Environment['MSBUILDCOORDINATORPRIORITYAGINGTHRESHOLD'] = '3'
    $startInfo.Environment['MSBUILDCOORDINATORBUILDREQUESTPRIORITY'] = $Priority
    if (-not $AutomaticPolicy) {
        $startInfo.Environment['MSBUILDCOORDINATORHIGHPRIORITYRESERVEDNODES'] = [string]$Reservation
        $startInfo.Environment['MSBUILDCOORDINATORMAXNODESPERBUILD'] = [string]$Slice
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    [pscustomobject]@{
        Label = $Label
        Process = $process
        RootProcessId = $process.Id
        StartTimeUtc = $process.StartTime.ToUniversalTime()
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
        Stdout = $stdout
        Stderr = $stderr
        Binlog = $binlog
    }
}

function Complete-SmokeBuild {
    param([pscustomobject]$Run)

    $Run.Process.WaitForExit()
    $stdout = $Run.StdoutTask.GetAwaiter().GetResult()
    $stderr = $Run.StderrTask.GetAwaiter().GetResult()
    Set-Content -LiteralPath $Run.Stdout -Value $stdout -Encoding UTF8
    Set-Content -LiteralPath $Run.Stderr -Value $stderr -Encoding UTF8
    [pscustomobject]@{
        Label = $Run.Label
        RootProcessId = $Run.RootProcessId
        StartTimeUtc = $Run.StartTimeUtc.ToString('O')
        ExitTimeUtc = $Run.Process.ExitTime.ToUniversalTime().ToString('O')
        ExitCode = $Run.Process.ExitCode
        Stdout = $Run.Stdout
        Stderr = $Run.Stderr
        Binlog = $Run.Binlog
    }
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [bool]$AutomaticPolicy,
        [int]$Slice,
        [int]$Reservation,
        [object[]]$Builds
    )

    $scenarioRoot = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Force -Path $scenarioRoot | Out-Null
    $pipeName = "idle-burst-smoke-$PID-$Name"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $runs = [Collections.Generic.List[object]]::new()
    foreach ($build in $Builds) {
        while ($timer.Elapsed.TotalSeconds -lt [double]$build.DelaySeconds) {
            Start-Sleep -Milliseconds 50
        }
        $runs.Add((Start-SmokeBuild `
            -ScenarioRoot $scenarioRoot `
            -PipeName $pipeName `
            -Label $build.Label `
            -Priority $build.Priority `
            -HoldSeconds $build.HoldSeconds `
            -AutomaticPolicy $AutomaticPolicy `
            -Slice $Slice `
            -Reservation $Reservation))
    }

    $completed = @($runs | ForEach-Object { Complete-SmokeBuild -Run $_ })
    foreach ($run in $completed) {
        if ($run.ExitCode -ne 0) {
            throw "$Name/$($run.Label) failed with exit code $($run.ExitCode)."
        }
    }
    $binlogs = @($completed.Binlog)
    $scanJson = & $dotnet $scanner @binlogs
    if ($LASTEXITCODE -ne 0) {
        throw "Grant scanner failed for $Name."
    }
    $scans = @($scanJson | ConvertFrom-Json)
    $rows = for ($index = 0; $index -lt $completed.Count; $index++) {
        $grant = @($scans[$index].Grants)
        [pscustomobject]@{
            Scenario = $Name
            Label = $completed[$index].Label
            Priority = $Builds[$index].Priority
            DelaySeconds = $Builds[$index].DelaySeconds
            RootProcessId = $completed[$index].RootProcessId
            ProcessStartUtc = $completed[$index].StartTimeUtc
            ProcessExitUtc = $completed[$index].ExitTimeUtc
            ExitCode = $completed[$index].ExitCode
            GrantCount = $grant.Count
            GrantedNodes = if ($grant.Count -eq 1) { [int]$grant[0].Nodes } else { $null }
            GrantTimestampUtc = if ($grant.Count -eq 1) { $grant[0].TimestampUtc } else { $null }
            Binlog = $completed[$index].Binlog
            Stderr = $completed[$index].Stderr
        }
    }
    $rows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $scenarioRoot 'grants.csv')
    return $rows
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$allRows = [Collections.Generic.List[object]]::new()

$scenarioRows = Invoke-Scenario -Name 'auto-three-normal' -AutomaticPolicy $true -Slice 4 -Reservation 4 -Builds @(
    [pscustomobject]@{ Label = 'normal1'; Priority = 'Normal'; DelaySeconds = 0.0; HoldSeconds = 7 },
    [pscustomobject]@{ Label = 'normal2'; Priority = 'Normal'; DelaySeconds = 0.7; HoldSeconds = 5 },
    [pscustomobject]@{ Label = 'normal3'; Priority = 'Normal'; DelaySeconds = 1.4; HoldSeconds = 1 }
)
$allRows.AddRange([object[]]$scenarioRows)

$scenarioRows = Invoke-Scenario -Name 'auto-delayed-high' -AutomaticPolicy $true -Slice 4 -Reservation 4 -Builds @(
    [pscustomobject]@{ Label = 'normal1'; Priority = 'Normal'; DelaySeconds = 0.0; HoldSeconds = 5 },
    [pscustomobject]@{ Label = 'high1'; Priority = 'High'; DelaySeconds = 0.7; HoldSeconds = 1 }
)
$allRows.AddRange([object[]]$scenarioRows)

foreach ($control in @(
    [pscustomobject]@{ Name = 'fixed-4-4'; Slice = 4; Reservation = 4; Expected = 4 },
    [pscustomobject]@{ Name = 'compat-0-0'; Slice = 0; Reservation = 0; Expected = 16 },
    [pscustomobject]@{ Name = 'literal-cap-8'; Slice = 8; Reservation = 4; Expected = 8 }
)) {
    $scenarioRows = Invoke-Scenario -Name $control.Name -AutomaticPolicy $false -Slice $control.Slice -Reservation $control.Reservation -Builds @(
        [pscustomobject]@{ Label = 'normal1'; Priority = 'Normal'; DelaySeconds = 0.0; HoldSeconds = 1 }
    )
    $allRows.AddRange([object[]]$scenarioRows)
}

$allRows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $OutputRoot 'grant-summary.csv')
$allRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'grant-summary.json') -Encoding UTF8
$allRows | Format-Table Scenario,Label,Priority,ExitCode,GrantCount,GrantedNodes,GrantTimestampUtc -AutoSize
