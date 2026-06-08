// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.IO.Pipes;
using Microsoft.Build.BackEnd;
using Microsoft.Build.Framework.Coordinator;
using Shouldly;
using Xunit;

namespace Microsoft.Build.Coordinator.UnitTests;

public class CoordinatorClient_Tests(ITestOutputHelper testOutput) : IDisposable
{
    // Use fake PIDs that won't collide with each other or the real process.
    // The coordinator server only uses PIDs for keying connections and liveness checks.
    private const int Pid1 = 90001;
    private const int Pid2 = 90002;

    private readonly string _pipeName = NamedPipeUtil.GetPlatformSpecificPipeName($"msbuild-coordinator-test-{Guid.NewGuid():N}");

    private readonly CancellationTokenSource _cts = new();

    private readonly TestCoordinatorOutput _output = new(testOutput);

    private CoordinatorSettings DefaultSettings => CoordinatorSettings.Default with
    {
        PipeName = _pipeName,
        ShutdownTimeoutMs = Timeout.Infinite,
    };

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }

    [Fact]
    public Task TryConnect_ReceivesNodeGrant()
    {
        using CoordinatorServer server = CreateServer(totalNodeBudget: 16);
        Task serverTask = server.RunAsync(_cts.Token);

        using CoordinatorClient? client = TryConnectToServer(requestedNodes: 8, processId: Pid1);

        client.ShouldNotBeNull();
        client.GrantedNodes.ShouldBe(8);

        client.Dispose();
        _cts.Cancel();

        return serverTask;
    }

    [Fact]
    public Task TryConnect_GrantCapsToRequestedNodes()
    {
        using CoordinatorServer server = CreateServer(totalNodeBudget: 16);
        Task serverTask = server.RunAsync(_cts.Token);

        using CoordinatorClient? client = TryConnectToServer(requestedNodes: 4, processId: Pid1);

        client.ShouldNotBeNull();
        client.GrantedNodes.ShouldBe(4);

        client.Dispose();
        _cts.Cancel();

        return serverTask;
    }

    [Fact]
    public Task TryConnect_GrantCapsToTotalBudget()
    {
        using CoordinatorServer server = CreateServer(totalNodeBudget: 4);
        Task serverTask = server.RunAsync(_cts.Token);

        using CoordinatorClient? client = TryConnectToServer(requestedNodes: 16, processId: Pid1);

        client.ShouldNotBeNull();
        client.GrantedNodes.ShouldBe(4);

        client.Dispose();
        _cts.Cancel();

        return serverTask;
    }

    [Fact]
    public void TryConnect_NoServer_ReturnsNull()
    {
        // Use a pipe name that no server is listening on.
        CoordinatorClient? client = TryConnectToServer(
            requestedNodes: 8,
            CoordinatorSettings.Default with
            {
                PipeName = NamedPipeUtil.GetPlatformSpecificPipeName($"msbuild-coordinator-nonexistent-{Guid.NewGuid():N}"),
                ProcessId = Pid1,
                ConnectionTimeoutMs = 500,
            });

        client.ShouldBeNull();
    }

    [Fact]
    public void TryLaunchAndConnect_NoCoordinatorProcess_LaunchesAndWaitsForPipeReadiness()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings();
        int launchAttempts = 0;
        int connectTimeoutMs = 0;

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                GetCoordinatorProcessState = (_, _) => CoordinatorProcessState.DoesNotExist,
                TryLaunchCoordinator = (_, _) =>
                {
                    launchAttempts++;
                    return new TestCoordinatorProcess();
                },
                WaitForCoordinatorProcessState = (_, _, _) => CoordinatorProcessState.Exists,
                CreatePipeStream = CreatePipeStream,
                TryConnectToPipe = (_, timeoutMs) =>
                {
                    connectTimeoutMs = timeoutMs;
                    return true;
                },
            });

        stream.ShouldNotBeNull();
        launchAttempts.ShouldBe(1);
        connectTimeoutMs.ShouldBe(settings.ConnectionTimeoutMs);
    }

    [Fact]
    public void TryLaunchAndConnect_CoordinatorProcessExists_DoesNotLaunchAndWaitsForPipeReadiness()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings();
        int launchAttempts = 0;
        int connectTimeoutMs = 0;

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                GetCoordinatorProcessState = (_, _) => CoordinatorProcessState.Exists,
                TryLaunchCoordinator = (_, _) =>
                {
                    launchAttempts++;
                    return new TestCoordinatorProcess();
                },
                CreatePipeStream = CreatePipeStream,
                TryConnectToPipe = (_, timeoutMs) =>
                {
                    connectTimeoutMs = timeoutMs;
                    return true;
                },
            });

        stream.ShouldNotBeNull();
        launchAttempts.ShouldBe(0);
        connectTimeoutMs.ShouldBe(settings.ConnectionTimeoutMs);
    }

    [Fact]
    public void TryLaunchAndConnect_UnknownCoordinatorProcessState_LaunchesAndWaitsForPipeReadiness()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings();
        int launchAttempts = 0;

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                GetCoordinatorProcessState = (_, _) => CoordinatorProcessState.Unknown,
                TryLaunchCoordinator = (_, _) =>
                {
                    launchAttempts++;
                    return new TestCoordinatorProcess();
                },
                WaitForCoordinatorProcessState = (_, _, _) => CoordinatorProcessState.Exists,
                CreatePipeStream = CreatePipeStream,
                TryConnectToPipe = (_, _) => true,
            });

        stream.ShouldNotBeNull();
        launchAttempts.ShouldBe(1);
    }

    [Fact]
    public void TryLaunchAndConnect_CoordinatorProcessExists_ReleasesLaunchMutexBeforePipeReadinessWait()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings();
        bool anotherThreadAcquiredLaunchMutex = false;

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                GetCoordinatorProcessState = (_, _) => CoordinatorProcessState.Exists,
                TryLaunchCoordinator = (_, _) => throw new InvalidOperationException("Coordinator should not be launched when server mutex exists."),
                CreatePipeStream = CreatePipeStream,
                TryConnectToPipe = (_, _) =>
                {
                    var probeThread = new Thread(() =>
                    {
                        using Mutex mutex = new(initiallyOwned: false, settings.LaunchMutexName);
                        anotherThreadAcquiredLaunchMutex = mutex.WaitOne(0);

                        if (anotherThreadAcquiredLaunchMutex)
                        {
                            mutex.ReleaseMutex();
                        }
                    });

                    probeThread.Start();
                    probeThread.Join(TimeSpan.FromSeconds(5)).ShouldBeTrue();
                    return true;
                },
            });

        stream.ShouldNotBeNull();
        anotherThreadAcquiredLaunchMutex.ShouldBeTrue();
    }

    [Fact]
    public async Task TryLaunchAndConnect_ConcurrentLaunchers_DoNotLaunchTwiceWhileServerMutexIsPending()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings() with
        {
            LaunchMutexTimeoutMs = 5_000,
        };

        using var firstClientWaitingForServerMutex = new ManualResetEventSlim();
        using var releaseServerMutexWait = new ManualResetEventSlim();
        using var secondClientStarted = new ManualResetEventSlim();

        bool serverMutexExists = false;
        int launchAttempts = 0;
        int connectAttempts = 0;

        CoordinatorLaunchOperations operations = new()
        {
            GetCoordinatorProcessState = (_, _) => Volatile.Read(ref serverMutexExists)
                ? CoordinatorProcessState.Exists
                : CoordinatorProcessState.DoesNotExist,
            TryLaunchCoordinator = (_, _) =>
            {
                Interlocked.Increment(ref launchAttempts);
                return new TestCoordinatorProcess();
            },
            WaitForCoordinatorProcessState = (_, _, _) =>
            {
                firstClientWaitingForServerMutex.Set();
                releaseServerMutexWait.Wait(TimeSpan.FromSeconds(5)).ShouldBeTrue();
                Volatile.Write(ref serverMutexExists, true);
                return CoordinatorProcessState.Exists;
            },
            CreatePipeStream = CreatePipeStream,
            TryConnectToPipe = (_, _) =>
            {
                Interlocked.Increment(ref connectAttempts);
                return true;
            },
        };

        Task<bool> firstClient = Task.Run(() =>
        {
            using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(settings, _output, operations);
            return stream is not null;
        });

        firstClientWaitingForServerMutex.Wait(TimeSpan.FromSeconds(5)).ShouldBeTrue();

        Task<bool> secondClient = Task.Run(() =>
        {
            secondClientStarted.Set();
            using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(settings, _output, operations);
            return stream is not null;
        });

        secondClientStarted.Wait(TimeSpan.FromSeconds(5)).ShouldBeTrue();
        secondClient.Wait(millisecondsTimeout: 100).ShouldBeFalse();

        releaseServerMutexWait.Set();

        (await firstClient).ShouldBeTrue();
        (await secondClient).ShouldBeTrue();
        launchAttempts.ShouldBe(1);
        connectAttempts.ShouldBe(2);
    }

    [Fact]
    public void TryLaunchAndConnect_ExistingCoordinatorExitsBeforeReadiness_RelaunchesOnce()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings();
        var coordinatorStates = new Queue<CoordinatorProcessState>(new[] { CoordinatorProcessState.Exists, CoordinatorProcessState.DoesNotExist, CoordinatorProcessState.DoesNotExist });
        var connectResults = new Queue<bool>(new[] { false, true });
        int launchAttempts = 0;
        int connectAttempts = 0;

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                GetCoordinatorProcessState = (_, _) => coordinatorStates.Count > 0 ? coordinatorStates.Dequeue() : CoordinatorProcessState.DoesNotExist,
                TryLaunchCoordinator = (_, _) =>
                {
                    launchAttempts++;
                    return new TestCoordinatorProcess();
                },
                WaitForCoordinatorProcessState = (_, _, _) => CoordinatorProcessState.Exists,
                CreatePipeStream = CreatePipeStream,
                TryConnectToPipe = (_, _) =>
                {
                    connectAttempts++;
                    return connectResults.Dequeue();
                },
            });

        stream.ShouldNotBeNull();
        launchAttempts.ShouldBe(1);
        connectAttempts.ShouldBe(2);
    }

    [Fact]
    public void TryLaunchAndConnect_LaunchedCoordinatorExitsBeforeReadiness_RelaunchesOnce()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings();
        var coordinatorStates = new Queue<CoordinatorProcessState>(new[] { CoordinatorProcessState.DoesNotExist, CoordinatorProcessState.DoesNotExist, CoordinatorProcessState.DoesNotExist });
        var connectResults = new Queue<bool>(new[] { false, true });
        int launchAttempts = 0;
        int connectAttempts = 0;

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                GetCoordinatorProcessState = (_, _) => coordinatorStates.Count > 0 ? coordinatorStates.Dequeue() : CoordinatorProcessState.DoesNotExist,
                TryLaunchCoordinator = (_, _) =>
                {
                    launchAttempts++;
                    return new TestCoordinatorProcess();
                },
                WaitForCoordinatorProcessState = (_, _, _) => CoordinatorProcessState.Exists,
                CreatePipeStream = CreatePipeStream,
                TryConnectToPipe = (_, _) =>
                {
                    connectAttempts++;
                    return connectResults.Dequeue();
                },
            });

        stream.ShouldNotBeNull();
        launchAttempts.ShouldBe(2);
        connectAttempts.ShouldBe(2);
    }

    [Fact]
    public void TryLaunchAndConnect_LaunchMutexTimeout_ReturnsNullWithoutInspectingState()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings() with
        {
            LaunchMutexTimeoutMs = 50,
        };

        using var mutexAcquired = new ManualResetEventSlim();
        using var releaseMutex = new ManualResetEventSlim();
        Exception? holderException = null;

        var holderThread = new Thread(() =>
        {
            using Mutex mutex = new(initiallyOwned: false, settings.LaunchMutexName);

            try
            {
                mutex.WaitOne();
                mutexAcquired.Set();
                releaseMutex.Wait();
                mutex.ReleaseMutex();
            }
            catch (Exception ex)
            {
                holderException = ex;
                mutexAcquired.Set();
            }
        })
        {
            IsBackground = true,
        };

        holderThread.Start();
        mutexAcquired.Wait(TimeSpan.FromSeconds(5)).ShouldBeTrue();

        try
        {
            using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
                settings,
                _output,
                new CoordinatorLaunchOperations
                {
                    GetCoordinatorProcessState = (_, _) => throw new InvalidOperationException("State should not be inspected after launch mutex timeout."),
                    TryLaunchCoordinator = (_, _) => throw new InvalidOperationException("Coordinator should not be launched after launch mutex timeout."),
                    CreatePipeStream = CreatePipeStream,
                    TryConnectToPipe = (_, _) => true,
                });

            stream.ShouldBeNull();
        }
        finally
        {
            releaseMutex.Set();
            holderThread.Join(TimeSpan.FromSeconds(5)).ShouldBeTrue();
        }

        holderException.ShouldBeNull();
    }

    [Fact]
    public void WaitForCoordinatorProcessState_ServerMutexAppearsDuringTimeoutRecovery_DoesNotTerminateProcess()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings() with
        {
            StartupTimeoutMs = 10,
        };

        using var launchedProcess = new TestCoordinatorProcess();
        int stateReads = 0;

        CoordinatorProcessState state = CoordinatorClient.TestAccessor.WaitForCoordinatorProcessState(
            settings,
            _output,
            launchedProcess,
            () =>
            {
                if (Interlocked.Increment(ref stateReads) == 1)
                {
                    Thread.Sleep(settings.StartupTimeoutMs + 5);
                    return CoordinatorProcessState.DoesNotExist;
                }

                return CoordinatorProcessState.Exists;
            });

        state.ShouldBe(CoordinatorProcessState.Exists);
        launchedProcess.WasKilled.ShouldBeFalse();
    }

    [Fact]
    public void TryLaunchAndConnect_LaunchedCoordinatorExitsBeforeAdvertising_ReturnsNull()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings();
        using var launchedProcess = new TestCoordinatorProcess { HasExited = true };

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                TryLaunchCoordinator = (_, _) => launchedProcess,
                CreatePipeStream = _ => throw new InvalidOperationException("Pipe should not be created after coordinator startup failure."),
                TryConnectToPipe = (_, _) => throw new InvalidOperationException("Pipe should not be connected after coordinator startup failure."),
            });

        stream.ShouldBeNull();
        launchedProcess.WasKilled.ShouldBeFalse();
    }

    [Fact]
    public void TryLaunchAndConnect_LaunchedCoordinatorDoesNotAdvertiseBeforeStartupTimeout_TerminatesProcessAndReturnsNull()
    {
        CoordinatorSettings settings = CreateLaunchTestSettings() with
        {
            StartupTimeoutMs = 10,
        };

        using var launchedProcess = new TestCoordinatorProcess();

        using NamedPipeClientStream? stream = CoordinatorClient.TestAccessor.TryLaunchAndConnect(
            settings,
            _output,
            new CoordinatorLaunchOperations
            {
                TryLaunchCoordinator = (_, _) => launchedProcess,
                CreatePipeStream = _ => throw new InvalidOperationException("Pipe should not be created after coordinator startup timeout."),
                TryConnectToPipe = (_, _) => throw new InvalidOperationException("Pipe should not be connected after coordinator startup timeout."),
            });

        stream.ShouldBeNull();
        launchedProcess.WasKilled.ShouldBeTrue();
        launchedProcess.HasExited.ShouldBeTrue();
    }

    [Fact]
    public Task TryConnect_CustomSettings_UsesSettingsPipeName()
    {
        using CoordinatorServer server = CreateServer(totalNodeBudget: 16);
        Task serverTask = server.RunAsync(_cts.Token);

        using CoordinatorClient? client = TryConnectToServer(
            requestedNodes: 8,
            DefaultSettings with
            {
                ProcessId = Pid1,
                HeartbeatIntervalMs = 50,
            });

        client.ShouldNotBeNull();
        client.GrantedNodes.ShouldBe(8);

        client.Dispose();
        _cts.Cancel();

        return serverTask;
    }

    [Fact]
    public async Task Dispose_ReleasesGrant_SecondClientGetsNodes()
    {
        using CoordinatorServer server = CreateServer(totalNodeBudget: 4);
        Task serverTask = server.RunAsync(_cts.Token);

        // First client takes the full budget.
        CoordinatorClient? client1 = TryConnectToServer(requestedNodes: 4, processId: Pid1);
        client1.ShouldNotBeNull();
        client1.GrantedNodes.ShouldBe(4);

        // Second client will be queued (different PID so the server tracks it separately).
        Task<CoordinatorClient?> client2Task = Task.Run(() =>
            TryConnectToServer(requestedNodes: 4, processId: Pid2));

        // Give the second client time to connect and be queued.
        await Task.Delay(200);

        // Release the first client's grant. This should unblock the second client.
        client1.Dispose();

        CoordinatorClient? client2 = await client2Task;
        client2.ShouldNotBeNull();
        client2.GrantedNodes.ShouldBeGreaterThan(0);

        client2.Dispose();
        _cts.Cancel();

        await serverTask;
    }

    [Fact]
    public Task Dispose_SendsReleaseMessage()
    {
        using CoordinatorServer server = CreateServer(totalNodeBudget: 8);
        Task serverTask = server.RunAsync(_cts.Token);

        CoordinatorClient? client = TryConnectToServer(requestedNodes: 8, processId: Pid1);
        client.ShouldNotBeNull();
        client.GrantedNodes.ShouldBe(8);

        // Dispose sends ReleaseNodesMessage. Verify it doesn't throw.
        client.Dispose();

        // Disposing again should be a no-op.
        client.Dispose();

        _cts.Cancel();

        return serverTask;
    }

    [Fact]
    public Task MultipleClients_FairShare()
    {
        using CoordinatorServer server = CreateServer(totalNodeBudget: 8);
        Task serverTask = server.RunAsync(_cts.Token);

        // First client connects and gets all 8.
        CoordinatorClient? client1 = TryConnectToServer(requestedNodes: 8, processId: Pid1);
        client1.ShouldNotBeNull();
        client1.GrantedNodes.ShouldBe(8);

        // Release first client so second can get nodes.
        client1.Dispose();

        // Second client connects and should also get up to 8.
        using CoordinatorClient? client2 = TryConnectToServer(requestedNodes: 8, processId: Pid2);
        client2.ShouldNotBeNull();
        client2.GrantedNodes.ShouldBe(8);

        client2.Dispose();
        _cts.Cancel();

        return serverTask;
    }

    private CoordinatorServer CreateServer(int totalNodeBudget)
        => new(DefaultSettings with { TotalNodeBudget = totalNodeBudget }, _output);

    private CoordinatorSettings CreateLaunchTestSettings()
        => DefaultSettings with
        {
            PipeName = NamedPipeUtil.GetPlatformSpecificPipeName($"msbuild-coordinator-launch-test-{Guid.NewGuid():N}"),
            ConnectionTimeoutMs = 123,
            StartupTimeoutMs = 123,
            LaunchMutexTimeoutMs = 456,
        };

    private static NamedPipeClientStream CreatePipeStream(CoordinatorSettings settings)
        => new(".", settings.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);

    private CoordinatorClient? TryConnectToServer(int requestedNodes, int processId)
        => TryConnectToServer(requestedNodes, DefaultSettings with { ProcessId = processId });

    private CoordinatorClient? TryConnectToServer(int requestedNodes, CoordinatorSettings settings)
        => CoordinatorClient.TestAccessor.TryConnectToServer(requestedNodes, settings, _output);

    private sealed class TestCoordinatorProcess : ICoordinatorProcess
    {
        public int Id { get; } = 12345;

        public bool HasExited { get; set; }

        public bool WasKilled { get; private set; }

        public void Kill()
        {
            WasKilled = true;
            HasExited = true;
        }

        public bool WaitForExit(int milliseconds)
            => HasExited;

        public void Dispose()
        {
        }
    }
}
