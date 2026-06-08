// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using Microsoft.Build.Framework;
using Microsoft.Build.Framework.Coordinator;
using Microsoft.Build.UnitTests;
using Shouldly;
using Xunit;

namespace Microsoft.Build.Coordinator.UnitTests;

public class CoordinatorSettings_Tests(ITestOutputHelper output)
{
    [Fact]
    public void CoordinatorSettings_CustomValues_AreUsed()
    {
        CoordinatorSettings settings = CoordinatorSettings.Default with
        {
            PipeName = "custom-pipe",
            HeartbeatIntervalMs = 123,
            MissedHeartbeatsThreshold = 4,
            TotalNodeBudget = 7,
            ShutdownTimeoutMs = 456,
            InitialConnectionTimeoutMs = 321,
            ConnectionTimeoutMs = 654,
            StartupTimeoutMs = 876,
            LaunchMutexTimeoutMs = 765,
            ProcessId = 43210,
        };

        settings.PipeName.ShouldContain("custom-pipe");
        settings.HeartbeatIntervalMs.ShouldBe(123);
        settings.MissedHeartbeatsThreshold.ShouldBe(4);
        settings.TotalNodeBudget.ShouldBe(7);
        settings.ShutdownTimeoutMs.ShouldBe(456);
        settings.InitialConnectionTimeoutMs.ShouldBe(321);
        settings.ConnectionTimeoutMs.ShouldBe(654);
        settings.StartupTimeoutMs.ShouldBe(876);
        settings.LaunchMutexTimeoutMs.ShouldBe(765);
        settings.ProcessId.ShouldBe(43210);
    }

    [Fact]
    public void CoordinatorSettings_FromEnvironment_DefaultPipeNameContainsBase()
    {
        string pipeName = CoordinatorSettings.FromEnvironment().PipeName;
        pipeName.ShouldContain(CoordinatorSettings.PipeNameBase);
    }

    [Fact]
    public void CoordinatorSettings_FromEnvironment_DefaultPipeNameContainsUserName()
    {
        string pipeName = CoordinatorSettings.FromEnvironment().PipeName;
        pipeName.ShouldContain(Environment.UserName);
    }

    [Fact]
    public void CoordinatorSettings_FromEnvironment_UsesEnvironmentOverrides()
    {
        using TestEnvironment env = TestEnvironment.Create(output);

        env.SetEnvironmentVariable(Traits.CoordinatorPipeNameEnvVarName, "coordinator-env-test-pipe");
        env.SetEnvironmentVariable(Traits.CoordinatorHeartbeatIntervalEnvVarName, "1234");
        env.SetEnvironmentVariable(Traits.CoordinatorInitialConnectionTimeoutEnvVarName, "4321");
        env.SetEnvironmentVariable(Traits.CoordinatorConnectionTimeoutEnvVarName, "5432");
        env.SetEnvironmentVariable(Traits.CoordinatorStartupTimeoutEnvVarName, "8765");
        env.SetEnvironmentVariable(Traits.CoordinatorLaunchMutexTimeoutEnvVarName, "6543");
        env.SetEnvironmentVariable(Traits.CoordinatorNodeBudgetEnvVarName, "7");
        env.SetEnvironmentVariable(Traits.CoordinatorShutdownTimeoutEnvVarName, "9876");

        CoordinatorSettings settings = CoordinatorSettings.FromEnvironment();

        settings.PipeName.ShouldContain("coordinator-env-test-pipe");
        settings.HeartbeatIntervalMs.ShouldBe(1234);
        settings.MissedHeartbeatsThreshold.ShouldBe(CoordinatorSettings.DefaultMissedHeartbeatsThreshold);
        settings.TotalNodeBudget.ShouldBe(7);
        settings.ShutdownTimeoutMs.ShouldBe(9876);
        settings.InitialConnectionTimeoutMs.ShouldBe(4321);
        settings.ConnectionTimeoutMs.ShouldBe(5432);
        settings.StartupTimeoutMs.ShouldBe(8765);
        settings.LaunchMutexTimeoutMs.ShouldBe(6543);
        settings.ProcessId.ShouldBe(EnvironmentUtilities.CurrentProcessId);
    }

    [Fact]
    public void CoordinatorSettings_FromEnvironment_DefaultLaunchMutexTimeoutTracksStartupTimeout()
    {
        using TestEnvironment env = TestEnvironment.Create(output);

        env.SetEnvironmentVariable(Traits.CoordinatorStartupTimeoutEnvVarName, "7000");

        CoordinatorSettings settings = CoordinatorSettings.FromEnvironment();

        settings.StartupTimeoutMs.ShouldBe(7000);
        settings.LaunchMutexTimeoutMs.ShouldBe(15000);
    }
}
