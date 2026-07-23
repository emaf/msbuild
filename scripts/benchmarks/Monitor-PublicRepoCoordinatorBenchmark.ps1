<#
.SYNOPSIS
Captures Windows system and process telemetry for Coordinator benchmarks.

.DESCRIPTION
This Windows-only monitor runs independently from the benchmark harness control
loop. The main process samples system counters while a child monitor samples the
complete process table, including process/parent identity and known background
noise categories. A stop file ends both loops.
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
    [switch]$ProcessWorker
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [Runtime.InteropServices.OSPlatform]::Windows)) {
    throw 'Monitor-PublicRepoCoordinatorBenchmark.ps1 is Windows-only.'
}
if ($SampleIntervalSeconds -le 0 -or $ProcessIntervalSeconds -le 0) {
    throw 'Sample intervals must be positive.'
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$culture = [Globalization.CultureInfo]::InvariantCulture
$systemPath = Join-Path $OutputRoot 'system.csv'
$processPath = Join-Path $OutputRoot 'processes.csv'
$errorPath = Join-Path $OutputRoot 'monitor-errors.log'
$processErrorPath = Join-Path $OutputRoot 'process-monitor-errors.log'
$processReadyFile = Join-Path $OutputRoot 'process-monitor-ready'

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

if ($ProcessWorker) {
    Invoke-ProcessWorker
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
    BenchmarkProcessNames = @($benchmarkProcessNames | Sort-Object)
    ExternalNoiseProcessNames = @($noiseProcessNames | Sort-Object)
} | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutputRoot 'monitor-metadata.json') -Encoding UTF8

$pwshPath = (Get-Command pwsh).Source
$workerStartInfo = [Diagnostics.ProcessStartInfo]::new($pwshPath)
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
    '-ProcessWorker'
)) {
    $workerStartInfo.ArgumentList.Add($argument)
}
$workerStartInfo.UseShellExecute = $false
$workerStartInfo.CreateNoWindow = $true
$processWorkerProcess = [Diagnostics.Process]::Start($workerStartInfo)

$systemWriter = [IO.StreamWriter]::new($systemPath, $false, [Text.UTF8Encoding]::new($false))
try {
    $systemWriter.WriteLine('timestampUtc,elapsedSec,cpuPercent,committedBytes,commitLimitBytes,availableMB,processorQueueLength,contextSwitchesPerSec,diskBytesPerSec,diskReadBytesPerSec,diskWriteBytesPerSec,diskQueueLength,probeLatencyMs,monitorIterationMs')
    $systemWriter.Flush()

    $readyTimer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $processReadyFile)) {
        if ($processWorkerProcess.HasExited) {
            throw "Process monitor exited before readiness with code $($processWorkerProcess.ExitCode)."
        }
        if ($readyTimer.Elapsed.TotalSeconds -gt 30) {
            throw 'Process monitor did not become ready within 30 seconds.'
        }
        Start-Sleep -Milliseconds 100
    }

    $overallTimer = [Diagnostics.Stopwatch]::StartNew()
    $sampleNumber = 0
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

        $probeLatency = $null
        if (($sampleNumber % $ProcessIntervalSeconds) -eq 0) {
            try {
                $probeLatency = Measure-LaunchLatencyMilliseconds
            }
            catch {
                Add-Content -Path $errorPath -Value "$timestampUtc responsiveness probe failed: $($_.Exception.Message)"
            }
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
            (ConvertTo-InvariantNumber $probeLatency),
            (ConvertTo-InvariantNumber $iterationTimer.Elapsed.TotalMilliseconds)
        )
        $systemWriter.WriteLine($fields -join ',')
        $systemWriter.Flush()

        $sampleNumber++
        $sleepMilliseconds = [Math]::Max(
            0,
            ($SampleIntervalSeconds * 1000) - [int]$iterationTimer.Elapsed.TotalMilliseconds)
        if ($sleepMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $sleepMilliseconds
        }
    }
}
finally {
    $systemWriter.Dispose()
    $workerTimedOut = -not $processWorkerProcess.WaitForExit(30000)
    if ($workerTimedOut) {
        Stop-Process -Id $processWorkerProcess.Id
        [void]$processWorkerProcess.WaitForExit(5000)
    }
    $workerExitCode = $processWorkerProcess.ExitCode
    $processWorkerProcess.Dispose()
    if ($workerTimedOut -or $workerExitCode -ne 0) {
        $message = "Process monitor failed (timedOut=$workerTimedOut, exitCode=$workerExitCode)."
        Add-Content -Path $processErrorPath -Value "$([DateTime]::UtcNow.ToString('O')) $message"
        throw $message
    }
}
