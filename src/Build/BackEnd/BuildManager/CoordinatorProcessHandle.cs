// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Diagnostics;

namespace Microsoft.Build.BackEnd;

internal interface ICoordinatorProcess : IDisposable
{
    int Id { get; }

    bool HasExited { get; }

    void Kill();

    bool WaitForExit(int milliseconds);
}

internal sealed class CoordinatorProcessHandle : ICoordinatorProcess
{
    private readonly Process _process;

    public CoordinatorProcessHandle(Process process)
    {
        _process = process;
        Id = process.Id;
    }

    public int Id { get; }

    public bool HasExited
    {
        get
        {
            try
            {
                return _process.HasExited;
            }
            catch (InvalidOperationException)
            {
                return true;
            }
        }
    }

    public void Kill()
        => _process.Kill();

    public bool WaitForExit(int milliseconds)
        => _process.WaitForExit(milliseconds);

    public void Dispose()
        => _process.Dispose();
}
