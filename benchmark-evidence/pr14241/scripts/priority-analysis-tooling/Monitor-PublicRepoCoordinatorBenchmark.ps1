<#
.SYNOPSIS
Captures Windows system and process telemetry for Coordinator benchmarks.

.DESCRIPTION
This Windows-only monitor runs independently from the benchmark harness control
loop. The main process samples system counters while separate child monitors
sample the complete process table and launch responsiveness. A stop file ends
all loops.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputRoot,

    [Parameter(Mandatory)]
    [string]$StopFile,

    [Parameter(Mandatory)]
    [string]$ReadyFile,

    [int]$SampleIntervalSeconds = 1,
    [int]$ProcessIntervalSeconds = 5,
    [int]$ProbeIntervalSeconds = 5,
    [switch]$ProcessWorker,
    [switch]$ProbeWorker
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'Monitor-PublicRepoCoordinatorBenchmark.ps1 is Windows-only.'
}
if ($SampleIntervalSeconds -le 0 -or $ProcessIntervalSeconds -le 0 -or $ProbeIntervalSeconds -le 0) {
    throw 'Sample intervals must be positive.'
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$culture = [Globalization.CultureInfo]::InvariantCulture
$systemPath = Join-Path $OutputRoot 'system.csv'
$processPath = Join-Path $OutputRoot 'processes.csv'
$probePath = Join-Path $OutputRoot 'probes.csv'
$errorPath = Join-Path $OutputRoot 'monitor-errors.log'
$processErrorPath = Join-Path $OutputRoot 'process-monitor-errors.log'
$probeErrorPath = Join-Path $OutputRoot 'probe-monitor-errors.log'
$processReadyFile = Join-Path $OutputRoot 'process-monitor-ready'
$probeReadyFile = Join-Path $OutputRoot 'probe-monitor-ready'

$benchmarkProcessNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($name in @(
    'dotnet.exe',
    'MSBuild.exe',
    'MSBuild.Coordinator.exe',
    'csc.exe',
    'vbc.exe',
    'VBCSCompiler.exe',
    'node.exe',
    'nuget.exe'
)) {
    [void]$benchmarkProcessNames.Add($name)
}

$noiseProcessNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($name in @(
    'MsMpEng.exe',
    'MpDefenderCoreService.exe',
    'MsSense.exe',
    'NisSrv.exe',
    'SecurityHealthService.exe',
    'SearchHost.exe',
    'SearchIndexer.exe',
    'SearchProtocolHost.exe',
    'SearchFilterHost.exe',
    'MoUsoCoreWorker.exe',
    'TiWorker.exe',
    'TrustedInstaller.exe',
    'UsoClient.exe',
    'WaaSMedicAgent.exe'
)) {
    [void]$noiseProcessNames.Add($name)
}

function ConvertTo-CsvField {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    if ($text.Contains('"')) {
        $text = $text.Replace('"', '""')
    }

    return '"' + $text + '"'
}

function ConvertTo-InvariantNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([double]$Value).ToString('0.###', $culture)
}

function Measure-LaunchLatencyMilliseconds {
    $startInfo = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $startInfo.ArgumentList.Add('/d')
    $startInfo.ArgumentList.Add('/c')
    $startInfo.ArgumentList.Add('exit')
    $startInfo.ArgumentList.Add('0')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    $timer.Stop()
    $process.Dispose()
    return $timer.Elapsed.TotalMilliseconds
}

function Invoke-ProcessWorker {
    $writer = [IO.StreamWriter]::new($processPath, $false, [Text.UTF8Encoding]::new($false))
    try {
        $writer.WriteLine('timestampUtc,elapsedSec,processId,parentProcessId,processStartUtc,name,category,workingSetBytes,privateBytes,cpuSeconds,readTransferBytes,writeTransferBytes,executablePath,commandLine')
        $writer.Flush()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $ready = $false

        while (-not (Test-Path -LiteralPath $StopFile)) {
            $iteration = [Diagnostics.Stopwatch]::StartNew()
            $timestampUtc = [DateTime]::UtcNow.ToString('O', $culture)
            try {
                $processes = Get-CimInstance Win32_Process
                foreach ($process in $processes) {
                    $name = [string]$process.Name
                    $category = if ($benchmarkProcessNames.Contains($name)) {
                        'benchmark-known'
                    }
                    elseif ($noiseProcessNames.Contains($name)) {
                        'external-noise-known'
                    }
                    else {
                        'other'
                    }
                    $processStartUtc = if ($null -ne $process.CreationDate) {
                        ([DateTime]$process.CreationDate).ToUniversalTime().ToString('O', $culture)
                    }
                    else {
                        ''
                    }
                    $cpuSeconds = (([int64]$process.KernelModeTime + [int64]$process.UserModeTime) / 10000000.0)
                    $fields = @(
                        (ConvertTo-CsvField $timestampUtc),
                        (ConvertTo-InvariantNumber $timer.Elapsed.TotalSeconds),
                        (ConvertTo-CsvField $process.ProcessId),
                        (ConvertTo-CsvField $process.ParentProcessId),
                        (ConvertTo-CsvField $processStartUtc),
                        (ConvertTo-CsvField $name),
                        (ConvertTo-CsvField $category),
                        (ConvertTo-CsvField $process.WorkingSetSize),
                        (ConvertTo-CsvField $process.PrivatePageCount),
                        (ConvertTo-InvariantNumber $cpuSeconds),
                        (ConvertTo-CsvField $process.ReadTransferCount),
                        (ConvertTo-CsvField $process.WriteTransferCount),
                        (ConvertTo-CsvField $process.ExecutablePath),
                        (ConvertTo-CsvField $process.CommandLine)
                    )
                    $writer.WriteLine($fields -join ',')
                }
                $writer.Flush()
                if (-not $ready) {
                    New-Item -ItemType File -Force -Path $processReadyFile | Out-Null
                    $ready = $true
                }
            }
            catch {
                Add-Content -Path $processErrorPath -Value "$timestampUtc process snapshot failed: $($_.Exception.Message)"
            }

            $sleepMilliseconds = [Math]::Max(
                0,
                ($ProcessIntervalSeconds * 1000) - [int]$iteration.Elapsed.TotalMilliseconds)
            if ($sleepMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $sleepMilliseconds
            }
        }
    }
    finally {
        $writer.Dispose()
    }
}

function Invoke-ProbeWorker {
    $writer = [IO.StreamWriter]::new($probePath, $false, [Text.UTF8Encoding]::new($false))
    try {
        $writer.WriteLine('timestampUtc,elapsedSec,probeLatencyMs,monitorIterationMs')
        $writer.Flush()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $ready = $false

        while (-not (Test-Path -LiteralPath $StopFile)) {
            $iteration = [Diagnostics.Stopwatch]::StartNew()
            $timestampUtc = [DateTime]::UtcNow.ToString('O', $culture)
            try {
                $probeLatency = Measure-LaunchLatencyMilliseconds
                $fields = @(
                    (ConvertTo-CsvField $timestampUtc),
                    (ConvertTo-InvariantNumber $timer.Elapsed.TotalSeconds),
                    (ConvertTo-InvariantNumber $probeLatency),
                    (ConvertTo-InvariantNumber $iteration.Elapsed.TotalMilliseconds)
                )
                $writer.WriteLine($fields -join ',')
                $writer.Flush()
                if (-not $ready) {
                    New-Item -ItemType File -Force -Path $probeReadyFile | Out-Null
                    $ready = $true
                }
            }
            catch {
                Add-Content -Path $probeErrorPath -Value "$timestampUtc responsiveness probe failed: $($_.Exception.Message)"
            }

            $sleepMilliseconds = [Math]::Max(
                0,
                ($ProbeIntervalSeconds * 1000) - [int]$iteration.Elapsed.TotalMilliseconds)
            if ($sleepMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $sleepMilliseconds
            }
        }
    }
    finally {
        $writer.Dispose()
    }
}

if ($ProcessWorker) {
    Invoke-ProcessWorker
    return
}
if ($ProbeWorker) {
    Invoke-ProbeWorker
    return
}

$counters = @(
    '\Processor(_Total)\% Processor Time',
    '\Memory\Committed Bytes',
    '\Memory\Commit Limit',
    '\Memory\Available MBytes',
    '\System\Processor Queue Length',
    '\System\Context Switches/sec',
    '\PhysicalDisk(_Total)\Disk Bytes/sec',
    '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
    '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
    '\PhysicalDisk(_Total)\Current Disk Queue Length'
)

$machine = Get-CimInstance Win32_ComputerSystem
$operatingSystem = Get-CimInstance Win32_OperatingSystem
$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
[ordered]@{
    StartedUtc = [DateTime]::UtcNow.ToString('O')
    ComputerName = $env:COMPUTERNAME
    OperatingSystem = $operatingSystem.Caption
    Processor = $processor.Name
    LogicalProcessors = $processor.NumberOfLogicalProcessors
    TotalPhysicalMemoryBytes = [int64]$machine.TotalPhysicalMemory
    SampleIntervalSeconds = $SampleIntervalSeconds
    ProcessIntervalSeconds = $ProcessIntervalSeconds
    ProbeIntervalSeconds = $ProbeIntervalSeconds
    BenchmarkProcessNames = @($benchmarkProcessNames | Sort-Object)
    ExternalNoiseProcessNames = @($noiseProcessNames | Sort-Object)
} | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutputRoot 'monitor-metadata.json') -Encoding UTF8

function Start-MonitorWorker {
    param([string]$Mode)

    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-OutputRoot', $OutputRoot,
        '-StopFile', $StopFile,
        '-ReadyFile', $ReadyFile,
        '-SampleIntervalSeconds', [string]$SampleIntervalSeconds,
        '-ProcessIntervalSeconds', [string]$ProcessIntervalSeconds,
        '-ProbeIntervalSeconds', [string]$ProbeIntervalSeconds,
        "-$Mode"
    )) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($startInfo)
}

$processWorkerProcess = $null
$probeWorkerProcess = $null
$systemWriter = $null
try {
    $processWorkerProcess = Start-MonitorWorker -Mode 'ProcessWorker'
    $probeWorkerProcess = Start-MonitorWorker -Mode 'ProbeWorker'
    $systemWriter = [IO.StreamWriter]::new($systemPath, $false, [Text.UTF8Encoding]::new($false))
    $systemWriter.WriteLine('timestampUtc,elapsedSec,cpuPercent,committedBytes,commitLimitBytes,availableMB,processorQueueLength,contextSwitchesPerSec,diskBytesPerSec,diskReadBytesPerSec,diskWriteBytesPerSec,diskQueueLength,monitorIterationMs')
    $systemWriter.Flush()

    $readyTimer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $processReadyFile) -or
        -not (Test-Path -LiteralPath $probeReadyFile)) {
        if ($processWorkerProcess.HasExited) {
            throw "Process monitor exited before readiness with code $($processWorkerProcess.ExitCode)."
        }
        if ($probeWorkerProcess.HasExited) {
            throw "Probe monitor exited before readiness with code $($probeWorkerProcess.ExitCode)."
        }
        if ($readyTimer.Elapsed.TotalSeconds -gt 30) {
            throw 'Process/probe monitors did not become ready within 30 seconds.'
        }
        Start-Sleep -Milliseconds 100
    }

    $overallTimer = [Diagnostics.Stopwatch]::StartNew()
    New-Item -ItemType File -Force -Path $ReadyFile | Out-Null

    while (-not (Test-Path -LiteralPath $StopFile)) {
        $iterationTimer = [Diagnostics.Stopwatch]::StartNew()
        $timestampUtc = [DateTime]::UtcNow.ToString('O', $culture)
        $values = @{}

        try {
            $counterSet = Get-Counter -Counter $counters
            foreach ($sample in $counterSet.CounterSamples) {
                $path = $sample.Path.ToLowerInvariant()
                if ($path.EndsWith('\processor(_total)\% processor time')) {
                    $values.cpuPercent = $sample.CookedValue
                }
                elseif ($path.EndsWith('\memory\committed bytes')) {
                    $values.committedBytes = $sample.CookedValue
                }
                elseif ($path.EndsWith('\memory\commit limit')) {
                    $values.commitLimitBytes = $sample.CookedValue
                }
                elseif ($path.EndsWith('\memory\available mbytes')) {
                    $values.availableMB = $sample.CookedValue
                }
                elseif ($path.EndsWith('\system\processor queue length')) {
                    $values.processorQueueLength = $sample.CookedValue
                }
                elseif ($path.EndsWith('\system\context switches/sec')) {
                    $values.contextSwitchesPerSec = $sample.CookedValue
                }
                elseif ($path.EndsWith('\physicaldisk(_total)\disk bytes/sec')) {
                    $values.diskBytesPerSec = $sample.CookedValue
                }
                elseif ($path.EndsWith('\physicaldisk(_total)\disk read bytes/sec')) {
                    $values.diskReadBytesPerSec = $sample.CookedValue
                }
                elseif ($path.EndsWith('\physicaldisk(_total)\disk write bytes/sec')) {
                    $values.diskWriteBytesPerSec = $sample.CookedValue
                }
                elseif ($path.EndsWith('\physicaldisk(_total)\current disk queue length')) {
                    $values.diskQueueLength = $sample.CookedValue
                }
            }
        }
        catch {
            Add-Content -Path $errorPath -Value "$timestampUtc counter sample failed: $($_.Exception.Message)"
        }

        $fields = @(
            (ConvertTo-CsvField $timestampUtc),
            (ConvertTo-InvariantNumber $overallTimer.Elapsed.TotalSeconds),
            (ConvertTo-InvariantNumber $values.cpuPercent),
            (ConvertTo-InvariantNumber $values.committedBytes),
            (ConvertTo-InvariantNumber $values.commitLimitBytes),
            (ConvertTo-InvariantNumber $values.availableMB),
            (ConvertTo-InvariantNumber $values.processorQueueLength),
            (ConvertTo-InvariantNumber $values.contextSwitchesPerSec),
            (ConvertTo-InvariantNumber $values.diskBytesPerSec),
            (ConvertTo-InvariantNumber $values.diskReadBytesPerSec),
            (ConvertTo-InvariantNumber $values.diskWriteBytesPerSec),
            (ConvertTo-InvariantNumber $values.diskQueueLength),
            (ConvertTo-InvariantNumber $iterationTimer.Elapsed.TotalMilliseconds)
        )
        $systemWriter.WriteLine($fields -join ',')
        $systemWriter.Flush()

        $sleepMilliseconds = [Math]::Max(
            0,
            ($SampleIntervalSeconds * 1000) - [int]$iterationTimer.Elapsed.TotalMilliseconds)
        if ($sleepMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $sleepMilliseconds
        }
    }
}
finally {
    if ($null -ne $systemWriter) {
        $systemWriter.Dispose()
    }
    New-Item -ItemType File -Force -Path $StopFile | Out-Null
    $workerFailures = [Collections.Generic.List[string]]::new()
    foreach ($worker in @(
        [pscustomobject]@{ Name = 'Process'; Process = $processWorkerProcess; ErrorPath = $processErrorPath },
        [pscustomobject]@{ Name = 'Probe'; Process = $probeWorkerProcess; ErrorPath = $probeErrorPath }
    )) {
        if ($null -eq $worker.Process) {
            continue
        }
        $workerTimedOut = -not $worker.Process.WaitForExit(30000)
        if ($workerTimedOut) {
            Stop-Process -Id $worker.Process.Id
            [void]$worker.Process.WaitForExit(5000)
        }
        $workerExitCode = $worker.Process.ExitCode
        $worker.Process.Dispose()
        if ($workerTimedOut -or $workerExitCode -ne 0) {
            $message = "$($worker.Name) monitor failed (timedOut=$workerTimedOut, exitCode=$workerExitCode)."
            Add-Content -Path $worker.ErrorPath -Value "$([DateTime]::UtcNow.ToString('O')) $message"
            $workerFailures.Add($message)
        }
    }
    if ($workerFailures.Count -gt 0) {
        throw ($workerFailures -join ' ')
    }
}
