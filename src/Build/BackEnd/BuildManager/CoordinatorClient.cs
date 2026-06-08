// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using Microsoft.Build.BackEnd.Logging;
using Microsoft.Build.Framework;
using Microsoft.Build.Framework.Coordinator;
using Microsoft.Build.Shared;

namespace Microsoft.Build.BackEnd;

/// <summary>
///  Client for communicating with the MSBuild build coordinator.
///  Handles connecting to (or launching) the coordinator, requesting a node grant,
///  sending heartbeats, and releasing the grant.
/// </summary>
internal sealed partial class CoordinatorClient : IDisposable
{
    private readonly NamedPipeClientStream _pipeStream;
    private readonly BinaryReader _reader;
    private readonly BinaryWriter _writer;
    private readonly Timer _heartbeatTimer;
    private readonly ICoordinatorOutput _output;
    private volatile bool _disposed;

    /// <summary>
    ///  The number of nodes granted by the coordinator.
    /// </summary>
    public int GrantedNodes { get; }

    /// <summary>
    ///  The time spent waiting for a deferred node grant, or <see langword="null"/> if no wait occurred.
    /// </summary>
    public TimeSpan? WaitDuration { get; private init; }

    private CoordinatorClient(
        NamedPipeClientStream pipeStream,
        BinaryReader reader,
        BinaryWriter writer,
        int grantedNodes,
        int heartbeatIntervalMs,
        ICoordinatorOutput output)
    {
        _pipeStream = pipeStream;
        _reader = reader;
        _writer = writer;
        _output = output;
        GrantedNodes = grantedNodes;

        _heartbeatTimer = new Timer(
            SendHeartbeat,
            state: null,
            dueTime: heartbeatIntervalMs,
            period: heartbeatIntervalMs);
    }

    /// <summary>
    ///  Releases the node grant and disconnects from the coordinator.
    /// </summary>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        // Stop heartbeat timer and wait for any in-flight callback to complete.
        // This prevents SendHeartbeat from running after resources are disposed.
        using (var disposeEvent = new ManualResetEvent(false))
        {
            _heartbeatTimer.Dispose(disposeEvent);
            disposeEvent.WaitOne();
        }

        _output.WriteLine($"CoordinatorClient: Releasing grant ({GrantedNodes} nodes)");

        try
        {
            _writer.Write(ReleaseNodesMessage.Instance);
        }
        catch (IOException)
        {
            // Pipe may already be broken.
        }

        try
        {
            _writer.Dispose();
        }
        catch (IOException)
        {
            // Flush in BinaryWriter.Dispose can throw on broken pipe.
        }

        _reader.Dispose();
        _pipeStream.Dispose();
    }

    /// <summary>
    ///  Attempts to connect to the coordinator and request a node grant.
    ///  Returns null if the coordinator is not available or an error occurs.
    /// </summary>
    /// <param name="requestedNodes">The maximum number of nodes to request from the coordinator.</param>
    /// <param name="settings">Coordinator connection settings (pipe name, timeouts, etc.).</param>
    /// <param name="loggingService">The MSBuild logging service used to emit user-visible messages.</param>
    /// <returns>
    ///  A connected <see cref="CoordinatorClient"/> instance, or <see langword="null"/> if the coordinator is not available.
    /// </returns>
    public static CoordinatorClient? TryConnect(int requestedNodes, CoordinatorSettings settings, ILoggingService loggingService)
    {
        ICoordinatorOutput output = DefaultOutput.Instance;

        NamedPipeClientStream? pipeStream = null;

        try
        {
#pragma warning disable CA2000 // pipeStream is disposed in finally or transferred to CoordinatorClient by TryNegotiate.
            pipeStream = CreatePipeStream(settings);
#pragma warning restore CA2000

            output.WriteLine($"CoordinatorClient: Connecting to pipe '{settings.PipeName}' (timeout {settings.InitialConnectionTimeoutMs}ms)");

            // Try to connect to an existing coordinator.
            if (!TryConnectToPipe(pipeStream, settings.InitialConnectionTimeoutMs))
            {
                output.WriteLine("CoordinatorClient: No coordinator running, attempting to launch");

                pipeStream.Dispose();
                pipeStream = null;
                pipeStream = TryLaunchAndConnect(settings, loggingService, output);

                if (pipeStream is null)
                {
                    return null;
                }
            }

            output.WriteLine("CoordinatorClient: Connected to coordinator");

            CoordinatorClient? client = TryNegotiate(pipeStream, requestedNodes, settings, output, loggingService);
            pipeStream = null; // Ownership transferred unconditionally; TryNegotiate disposes on failure.
            return client;
        }
        catch (Exception ex) when (!Debugger.IsAttached)
        {
            output.WriteLine($"CoordinatorClient: Exception during connect: {ex.Message}");

            // Any failure in coordinator communication should not break the build.
            return null;
        }
        finally
        {
            pipeStream?.Dispose();
        }
    }

    /// <summary>
    ///  Acquires a named mutex to serialize coordinator launches, then either launches
    ///  the coordinator or connects to one that was launched by another client.
    /// </summary>
    /// <param name="settings">Coordinator connection settings.</param>
    /// <param name="loggingService">The MSBuild logging service for user-visible messages.</param>
    /// <param name="output">Debug trace output.</param>
    /// <param name="operations">Launch and pipe operations. Tests can replace these to exercise launch races deterministically.</param>
    /// <returns>
    ///  A connected pipe stream, or <see langword="null"/> if the coordinator could not be started or reached.
    /// </returns>
    private static NamedPipeClientStream? TryLaunchAndConnect(
        CoordinatorSettings settings,
        ILoggingService? loggingService,
        ICoordinatorOutput output,
        CoordinatorLaunchOperations? operations = null)
    {
        operations ??= CoordinatorLaunchOperations.Default;

        if (!TryEnsureCoordinatorProcess(settings, loggingService, output, operations, out CoordinatorProcessState coordinatorState))
        {
            return null;
        }

        NamedPipeClientStream? pipeStream = null;

        try
        {
            // At this point either this client launched the coordinator or the server
            // mutex says another coordinator process is responsible for opening the pipe.
            // The launch mutex has been released: pipe connection is a readiness wait,
            // not an existence probe, and concurrent clients can wait in parallel.
            pipeStream = operations.CreatePipeStream(settings);

            output.WriteLine($"CoordinatorClient: Connecting to pipe '{settings.PipeName}' (timeout {settings.ConnectionTimeoutMs}ms)");

            if (!operations.TryConnectToPipe(pipeStream, settings.ConnectionTimeoutMs))
            {
                CoordinatorProcessState stateAfterFailedConnect = operations.GetCoordinatorProcessState(settings, output);

                if (stateAfterFailedConnect == CoordinatorProcessState.DoesNotExist)
                {
                    output.WriteLine("CoordinatorClient: Coordinator process exited before opening pipe, attempting relaunch");

                    if (!TryEnsureCoordinatorProcess(settings, loggingService, output, operations, out coordinatorState))
                    {
                        return null;
                    }

                    pipeStream.Dispose();
                    pipeStream = operations.CreatePipeStream(settings);

                    output.WriteLine($"CoordinatorClient: Connecting to pipe '{settings.PipeName}' (timeout {settings.ConnectionTimeoutMs}ms)");

                    if (operations.TryConnectToPipe(pipeStream, settings.ConnectionTimeoutMs))
                    {
                        output.WriteLine("CoordinatorClient: Coordinator launched successfully");
                        NamedPipeClientStream relaunched = pipeStream;
                        pipeStream = null; // Ownership transferred to caller.
                        return relaunched;
                    }
                }

                output.WriteLine("CoordinatorClient: Failed to connect to coordinator");
                loggingService?.LogComment(BuildEventContext.Invalid, MessageImportance.Normal, "CoordinatorFailedToConnect");
                return null;
            }

            output.WriteLine(coordinatorState switch
            {
                CoordinatorProcessState.Exists => "CoordinatorClient: Connected to existing coordinator process",
                CoordinatorProcessState.Unknown => "CoordinatorClient: Connected to coordinator after unknown process state",
                _ => "CoordinatorClient: Coordinator launched successfully",
            });
            NamedPipeClientStream connected = pipeStream;
            pipeStream = null; // Ownership transferred to caller.
            return connected;
        }
        finally
        {
            pipeStream?.Dispose();
        }
    }

    private static bool TryEnsureCoordinatorProcess(
        CoordinatorSettings settings,
        ILoggingService? loggingService,
        ICoordinatorOutput output,
        CoordinatorLaunchOperations operations,
        out CoordinatorProcessState coordinatorState)
    {
        coordinatorState = CoordinatorProcessState.Unknown;

        // Acquire a launch mutex so only one client decides whether to launch the
        // coordinator. Release it before the full pipe readiness wait so racing
        // clients do not serialize on a slow or hung coordinator pipe.
        using Mutex launchMutex = new(initiallyOwned: false, settings.LaunchMutexName);
        bool ownsLaunchMutex = false;

        try
        {
            if (!launchMutex.WaitOne(settings.LaunchMutexTimeoutMs))
            {
                output.WriteLine("CoordinatorClient: Timed out waiting for launch mutex");
                loggingService?.LogComment(BuildEventContext.Invalid, MessageImportance.Normal, "CoordinatorLaunchTimedOut");
                return false;
            }

            ownsLaunchMutex = true;
        }
        catch (AbandonedMutexException)
        {
            // The previous holder crashed — we now own the mutex and should proceed.
            ownsLaunchMutex = true;
            output.WriteLine("CoordinatorClient: Acquired abandoned launch mutex");
        }

        try
        {
            coordinatorState = operations.GetCoordinatorProcessState(settings, output);

            if (coordinatorState == CoordinatorProcessState.Exists)
            {
                return true;
            }

            // Unknown state is allowed to launch. The coordinator process also has
            // its own single-instance guard, so this favors liveness without risking
            // two active coordinators for the same pipe.
            using ICoordinatorProcess? launchedProcess = operations.TryLaunchCoordinator(loggingService, output);

            if (launchedProcess is null)
            {
                output.WriteLine("CoordinatorClient: Failed to launch coordinator");

                return coordinatorState != CoordinatorProcessState.DoesNotExist;
            }

            coordinatorState = operations.WaitForCoordinatorProcessState(settings, output, launchedProcess);
            return coordinatorState != CoordinatorProcessState.DoesNotExist;
        }
        finally
        {
            if (ownsLaunchMutex)
            {
                launchMutex.ReleaseMutex();
            }
        }
    }

    internal static CoordinatorProcessState GetCoordinatorProcessState(CoordinatorSettings settings, ICoordinatorOutput output)
        => GetCoordinatorProcessState(settings, output, logResult: true);

    private static CoordinatorProcessState GetCoordinatorProcessState(CoordinatorSettings settings, ICoordinatorOutput output, bool logResult)
    {
        try
        {
            if (Mutex.TryOpenExisting(settings.ServerMutexName, out Mutex? existingServerMutex))
            {
                existingServerMutex.Dispose();

                if (logResult)
                {
                    output.WriteLine("CoordinatorClient: Coordinator server mutex exists");
                }

                return CoordinatorProcessState.Exists;
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            if (logResult)
            {
                output.WriteLine($"CoordinatorClient: Failed to inspect coordinator server mutex: {ex.Message}");
            }

            return CoordinatorProcessState.Unknown;
        }

        if (logResult)
        {
            output.WriteLine("CoordinatorClient: Coordinator server mutex does not exist");
        }

        return CoordinatorProcessState.DoesNotExist;
    }

    internal static CoordinatorProcessState WaitForCoordinatorProcessState(CoordinatorSettings settings, ICoordinatorOutput output, ICoordinatorProcess? launchedProcess)
        => WaitForCoordinatorProcessState(
            settings,
            output,
            launchedProcess,
            () => GetCoordinatorProcessState(settings, output, logResult: false));

    internal static CoordinatorProcessState WaitForCoordinatorProcessState(
        CoordinatorSettings settings,
        ICoordinatorOutput output,
        ICoordinatorProcess? launchedProcess,
        Func<CoordinatorProcessState> getCoordinatorProcessState)
    {
        Stopwatch stopwatch = Stopwatch.StartNew();

        while (stopwatch.ElapsedMilliseconds < settings.StartupTimeoutMs)
        {
            CoordinatorProcessState state = getCoordinatorProcessState();

            if (state != CoordinatorProcessState.DoesNotExist)
            {
                output.WriteLine(state == CoordinatorProcessState.Exists
                    ? "CoordinatorClient: Coordinator server mutex appeared"
                    : "CoordinatorClient: Coordinator server mutex state became unknown during startup");

                return state;
            }

            if (launchedProcess?.HasExited == true)
            {
                output.WriteLine($"CoordinatorClient: Launched coordinator process {launchedProcess.Id} exited before advertising server mutex");
                return CoordinatorProcessState.DoesNotExist;
            }

            Thread.Sleep(Math.Min(50, Math.Max(1, settings.StartupTimeoutMs - (int)stopwatch.ElapsedMilliseconds)));
        }

        output.WriteLine($"CoordinatorClient: Timed out waiting {settings.StartupTimeoutMs}ms for coordinator server mutex");

        CoordinatorProcessState finalState = getCoordinatorProcessState();

        if (finalState != CoordinatorProcessState.DoesNotExist)
        {
            output.WriteLine(finalState == CoordinatorProcessState.Exists
                ? "CoordinatorClient: Coordinator server mutex appeared before startup timeout recovery"
                : "CoordinatorClient: Coordinator server mutex state became unknown before startup timeout recovery");

            return finalState;
        }

        if (launchedProcess is not null && !launchedProcess.HasExited)
        {
            TerminateLaunchedCoordinatorProcess(launchedProcess, output);
        }

        return CoordinatorProcessState.DoesNotExist;
    }

    private static void TerminateLaunchedCoordinatorProcess(ICoordinatorProcess launchedProcess, ICoordinatorOutput output)
    {
        try
        {
            output.WriteLine($"CoordinatorClient: Terminating coordinator process {launchedProcess.Id} after startup timeout");
            launchedProcess.Kill();

            if (!launchedProcess.WaitForExit(milliseconds: 1_000))
            {
                output.WriteLine($"CoordinatorClient: Coordinator process {launchedProcess.Id} did not exit promptly after termination request");
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
        {
            output.WriteLine($"CoordinatorClient: Failed to terminate coordinator process {launchedProcess.Id}: {ex.Message}");
        }
    }

    /// <summary>
    ///  Performs the request/response negotiation over an already-connected pipe.
    ///  On failure, disposes the pipe and returns null.
    /// </summary>
    /// <param name="pipeStream">The connected named pipe stream.</param>
    /// <param name="requestedNodes">The number of nodes to request.</param>
    /// <param name="settings">Coordinator settings including heartbeat interval and process ID.</param>
    /// <param name="output">Debug trace output for diagnostic logging.</param>
    /// <param name="loggingService">Optional MSBuild logging service for user-visible messages.</param>
    /// <returns>
    ///  A connected <see cref="CoordinatorClient"/> instance, or <see langword="null"/> if negotiation fails.
    /// </returns>
    private static CoordinatorClient? TryNegotiate(
        NamedPipeClientStream pipeStream,
        int requestedNodes,
        CoordinatorSettings settings,
        ICoordinatorOutput output,
        ILoggingService? loggingService)
    {
        var reader = new BinaryReader(pipeStream, Encoding.UTF8, leaveOpen: true);
        var writer = new BinaryWriter(pipeStream, Encoding.UTF8, leaveOpen: true);

        try
        {
            // Send the node request.
            output.WriteLine($"CoordinatorClient: Requesting {requestedNodes} nodes (PID {settings.ProcessId})");
            writer.Write(new RequestNodesMessage(requestedNodes, settings.ProcessId));

            // Read the response.
            ServerMessage response = reader.ReadServerMessage();

            switch (response)
            {
                case NodeGrantMessage grant:
                    output.WriteLine($"CoordinatorClient: Granted {grant.GrantedNodes} nodes");
                    loggingService?.LogComment(BuildEventContext.Invalid, MessageImportance.Normal, "CoordinatorNodeGrantReceived", grant.GrantedNodes);

                    var client = new CoordinatorClient(pipeStream, reader, writer, grant.GrantedNodes, settings.HeartbeatIntervalMs, output);

                    // Ownership transferred to client
                    reader = null;
                    writer = null;

                    return client;

                case WaitMessage:
                    output.WriteLine("CoordinatorClient: Received WaitMessage, waiting for deferred grant");
                    loggingService?.LogComment(BuildEventContext.Invalid, MessageImportance.High, "CoordinatorWaitingForNodes");

                    var waitTimer = Stopwatch.StartNew();

                    // Send heartbeats while waiting so the server doesn't consider us stale.
                    using (Timer heartbeatPump = CreateHeartbeatPump(writer, settings.HeartbeatIntervalMs))
                    {
                        ServerMessage grantAfterWait = reader.ReadServerMessage();

                        if (grantAfterWait is NodeGrantMessage deferredGrant)
                        {
                            waitTimer.Stop();

                            output.WriteLine($"CoordinatorClient: Deferred grant received: {deferredGrant.GrantedNodes} nodes (waited {waitTimer.Elapsed.TotalSeconds:F2}s)");
                            loggingService?.LogComment(BuildEventContext.Invalid, MessageImportance.Normal, "CoordinatorNodeGrantReceived", deferredGrant.GrantedNodes);

                            var deferredClient = new CoordinatorClient(pipeStream, reader, writer, deferredGrant.GrantedNodes, settings.HeartbeatIntervalMs, output)
                            {
                                WaitDuration = waitTimer.Elapsed,
                            };

                            // Ownership transferred to deferred client
                            reader = null;
                            writer = null;

                            return deferredClient;
                        }

                        output.WriteLine($"CoordinatorClient: Unexpected response after wait: {grantAfterWait.GetType().Name} (waited {waitTimer.Elapsed.TotalSeconds:F1}s)");
                    }

                    return null;

                default:
                    output.WriteLine($"CoordinatorClient: Unexpected response: {response.GetType().Name}");
                    return null;
            }
        }
        finally
        {
            // On success paths, reader/writer are set to null to indicate ownership
            // was transferred to the CoordinatorClient instance, which will dispose them.
            reader?.Dispose();
            writer?.Dispose();

            // If either reader or writer is still non-null, negotiation failed and
            // no CoordinatorClient took ownership of the pipe stream.
            if (reader is not null || writer is not null)
            {
                pipeStream.Dispose();
            }
        }
    }

    /// <summary>
    ///  Creates a heartbeat pump that periodically writes a heartbeat message to the given writer.
    ///  Dispose the returned timer to stop the pump.
    /// </summary>
    /// <param name="writer">The binary writer connected to the coordinator pipe.</param>
    /// <param name="intervalMs">The interval in milliseconds between heartbeats.</param>
    /// <returns>
    ///  A <see cref="Timer"/> that sends heartbeats. Dispose it to stop the pump.
    /// </returns>
    private static Timer CreateHeartbeatPump(BinaryWriter writer, int intervalMs)
        => new(
            static state =>
            {
                try
                {
                    if (state is BinaryWriter w)
                    {
                        w.Write(HeartbeatMessage.Instance);
                    }
                }
                catch
                {
                    // Pipe may be broken; swallow and let the next read detect it.
                }
            },
            state: writer,
            dueTime: intervalMs,
            period: intervalMs);

    internal static NamedPipeClientStream CreatePipeStream(CoordinatorSettings settings)
        => new(".", settings.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);

    internal static bool TryConnectToPipe(NamedPipeClientStream pipeStream, int timeoutMs)
    {
        try
        {
            pipeStream.Connect(timeoutMs);
            return true;
        }
        catch (TimeoutException)
        {
            return false;
        }
    }

    internal static ICoordinatorProcess? TryLaunchCoordinator(ILoggingService? loggingService, ICoordinatorOutput output)
    {
        try
        {
            ProcessStartInfo? startInfo = TryGetStartInfo();

            if (startInfo is null)
            {
                return null;
            }

            output.WriteLine($"CoordinatorClient: Launching coordinator: {startInfo.FileName} {startInfo.Arguments}");

            Process? process = Process.Start(startInfo);
            return process is null ? null : new CoordinatorProcessHandle(process);
        }
        catch (Exception ex) when (!Debugger.IsAttached)
        {
            output.WriteLine($"CoordinatorClient: Exception during launch: {ex}");
            loggingService?.LogComment(BuildEventContext.Invalid, MessageImportance.Normal, "CoordinatorFailedToLaunch");
            return null;
        }
    }

    private static ProcessStartInfo? TryGetStartInfo()
    {
        string msbuildDir = BuildEnvironmentHelper.Instance.CurrentMSBuildToolsDirectory;

        // Try the .dll form first (dotnet exec), then .exe.
        string coordinatorDll = Path.Combine(msbuildDir, "MSBuild.Coordinator.dll");
        string coordinatorExe = Path.Combine(msbuildDir, "MSBuild.Coordinator.exe");

        if (File.Exists(coordinatorDll) &&
            CurrentHost.GetCurrentHost() is string dotnetHost)
        {
            return new ProcessStartInfo
            {
                FileName = dotnetHost,
                Arguments = $"\"{coordinatorDll}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
        }

        // Full Framework — fall back to the native .exe if available.
        if (File.Exists(coordinatorExe))
        {
            return new ProcessStartInfo
            {
                FileName = coordinatorExe,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
        }

        return null;
    }

    private void SendHeartbeat(object? state)
    {
        if (_disposed)
        {
            return;
        }

        try
        {
            _writer.Write(HeartbeatMessage.Instance);
        }
        catch (IOException)
        {
            _output.WriteLine("CoordinatorClient: Heartbeat failed (pipe broken)");

            // Pipe broken — nothing we can do. The build continues
            // with whatever nodes were already granted.
        }
    }
}
