// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.IO.Pipes;
using Microsoft.Build.BackEnd.Logging;
using Microsoft.Build.Framework.Coordinator;

namespace Microsoft.Build.BackEnd;

internal sealed class CoordinatorLaunchOperations
{
    public static CoordinatorLaunchOperations Default { get; } = new();

    public Func<CoordinatorSettings, ICoordinatorOutput, CoordinatorProcessState> GetCoordinatorProcessState { get; init; } = CoordinatorClient.GetCoordinatorProcessState;

    public Func<ILoggingService?, ICoordinatorOutput, ICoordinatorProcess?> TryLaunchCoordinator { get; init; } = CoordinatorClient.TryLaunchCoordinator;

    public Func<CoordinatorSettings, ICoordinatorOutput, ICoordinatorProcess?, CoordinatorProcessState> WaitForCoordinatorProcessState { get; init; } = CoordinatorClient.WaitForCoordinatorProcessState;

    public Func<CoordinatorSettings, NamedPipeClientStream> CreatePipeStream { get; init; } = CoordinatorClient.CreatePipeStream;

    public Func<NamedPipeClientStream, int, bool> TryConnectToPipe { get; init; } = CoordinatorClient.TryConnectToPipe;
}
