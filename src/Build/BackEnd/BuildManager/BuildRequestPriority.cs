// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace Microsoft.Build.Execution
{
    /// <summary>
    /// Specifies how the build coordinator should prioritize a build request when it is queued.
    /// </summary>
    public enum BuildRequestPriority
    {
        /// <summary>
        /// Background or opportunistic work that should yield to more latency-sensitive builds.
        /// </summary>
        Low = 0,

        /// <summary>
        /// Standard build work. This is the default priority.
        /// </summary>
        Normal = 1,

        /// <summary>
        /// Latency-sensitive work that should be scheduled ahead of normal and low priority queued builds.
        /// </summary>
        High = 2,
    }
}
