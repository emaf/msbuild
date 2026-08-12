Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Campaign.Common.ps1')
. (Join-Path $PSScriptRoot 'CoordinatorTrace.ps1')

if ($null -eq ('CurrentVsFinalBenchmark.ScenarioTrackingJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CurrentVsFinalBenchmark
{
    public sealed class SuspendedScenarioProcess : IDisposable
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint GenericRead = 0x80000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint ProcThreadAttributeHandleList = 0x00020002;
        private const uint WaitObject0 = 0;
        private const uint WaitTimeout = 258;
        private const uint WaitFailed = 0xFFFFFFFF;
        private const uint Infinite = 0xFFFFFFFF;

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;

            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public uint Size;
            public IntPtr Reserved;
            public IntPtr Desktop;
            public IntPtr Title;
            public uint X;
            public uint Y;
            public uint XSize;
            public uint YSize;
            public uint XCountChars;
            public uint YCountChars;
            public uint FillAttribute;
            public uint Flags;
            public ushort ShowWindow;
            public ushort Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public uint ProcessId;
            public uint ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint Low;
            public uint High;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out IntPtr readPipe,
            out IntPtr writePipe,
            ref SecurityAttributes pipeAttributes,
            uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(
            SafeFileHandle handle,
            uint mask,
            uint flags);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SecurityAttributes securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(
            IntPtr attributeList);

        [DllImport(
            "kernel32.dll",
            EntryPoint = "CreateProcessW",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(SafeFileHandle thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(
            SafeFileHandle process,
            uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            SafeFileHandle handle,
            uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(
            SafeFileHandle process,
            out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(
            SafeFileHandle process,
            out FileTime creationTime,
            out FileTime exitTime,
            out FileTime kernelTime,
            out FileTime userTime);

        private readonly object stateLock = new object();
        private readonly Process process;
        private readonly StreamReader standardOutput;
        private readonly StreamReader standardError;
        private readonly SafeFileHandle processHandle;
        private readonly SafeFileHandle primaryThreadHandle;
        private bool resumed;
        private bool disposed;

        private SuspendedScenarioProcess(
            Process process,
            StreamReader standardOutput,
            StreamReader standardError,
            SafeFileHandle processHandle,
            SafeFileHandle primaryThreadHandle)
        {
            this.process = process;
            this.standardOutput = standardOutput;
            this.standardError = standardError;
            this.processHandle = processHandle;
            this.primaryThreadHandle = primaryThreadHandle;
        }

        public Process ManagedProcess
        {
            get
            {
                ThrowIfDisposed();
                return process;
            }
        }

        public IntPtr NativeProcessHandle
        {
            get
            {
                ThrowIfDisposed();
                return processHandle.DangerousGetHandle();
            }
        }

        public int Id { get { ThrowIfDisposed(); return process.Id; } }
        public DateTime StartTime { get { ThrowIfDisposed(); return process.StartTime; } }
        public bool HasExited
        {
            get
            {
                ThrowIfDisposed();
                uint status = WaitForSingleObject(processHandle, 0);
                if (status == WaitObject0)
                {
                    return true;
                }
                if (status == WaitTimeout)
                {
                    return false;
                }
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not query scenario process " + process.Id + ".");
            }
        }
        public DateTime ExitTime
        {
            get
            {
                ThrowIfDisposed();
                FileTime creation;
                FileTime exit;
                FileTime kernel;
                FileTime user;
                if (!GetProcessTimes(
                    processHandle,
                    out creation,
                    out exit,
                    out kernel,
                    out user))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetProcessTimes failed for scenario process " +
                            process.Id + ".");
                }
                ulong fileTime =
                    ((ulong)exit.High << 32) | (ulong)exit.Low;
                if (fileTime == 0)
                {
                    throw new InvalidOperationException(
                        "Scenario process " + process.Id +
                            " has not exited.");
                }
                return DateTime.FromFileTimeUtc(
                    checked((long)fileTime)).ToLocalTime();
            }
        }
        public int ExitCode
        {
            get
            {
                ThrowIfDisposed();
                uint exitCode;
                if (!GetExitCodeProcess(processHandle, out exitCode))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetExitCodeProcess failed for scenario process " +
                            process.Id + ".");
                }
                if (exitCode == 259 && !HasExited)
                {
                    throw new InvalidOperationException(
                        "Scenario process " + process.Id +
                            " has not exited.");
                }
                return unchecked((int)exitCode);
            }
        }
        public StreamReader StandardOutput { get { ThrowIfDisposed(); return standardOutput; } }
        public StreamReader StandardError { get { ThrowIfDisposed(); return standardError; } }
        public bool IsResumed { get { lock (stateLock) { return resumed; } } }
        public bool IsDisposed { get { lock (stateLock) { return disposed; } } }

        public static SuspendedScenarioProcess Create(ProcessStartInfo startInfo)
        {
            if (startInfo == null)
            {
                throw new ArgumentNullException("startInfo");
            }
            if (startInfo.UseShellExecute)
            {
                throw new InvalidOperationException(
                    "Suspended scenario launch does not support shell execution.");
            }
            if (!startInfo.CreateNoWindow)
            {
                throw new InvalidOperationException(
                    "Suspended scenario launch requires CreateNoWindow.");
            }
            if (!startInfo.RedirectStandardOutput ||
                !startInfo.RedirectStandardError)
            {
                throw new InvalidOperationException(
                    "Suspended scenario launch requires redirected stdout and stderr.");
            }
            if (startInfo.RedirectStandardInput)
            {
                throw new InvalidOperationException(
                    "Suspended scenario launch supplies a closed NUL stdin handle.");
            }
            if (string.IsNullOrWhiteSpace(startInfo.FileName))
            {
                throw new ArgumentException(
                    "A scenario executable is required.",
                    "startInfo");
            }

            SafeFileHandle stdoutRead = null;
            SafeFileHandle stdoutWrite = null;
            SafeFileHandle stderrRead = null;
            SafeFileHandle stderrWrite = null;
            SafeFileHandle standardInput = null;
            SafeFileHandle nativeProcess = null;
            SafeFileHandle primaryThread = null;
            Process managedProcess = null;
            FileStream outputStream = null;
            FileStream errorStream = null;
            StreamReader outputReader = null;
            StreamReader errorReader = null;
            IntPtr environment = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr handleList = IntPtr.Zero;
            bool attributeListInitialized = false;
            ProcessInformation processInformation = new ProcessInformation();

            try
            {
                CreateRedirectPipe(out stdoutRead, out stdoutWrite);
                CreateRedirectPipe(out stderrRead, out stderrWrite);
                standardInput = OpenInheritedNullInput();
                environment = CreateEnvironmentBlock(startInfo);

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    1,
                    0,
                    ref attributeListSize);
                if (attributeListSize == IntPtr.Zero)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not size the scenario process attribute list.");
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(
                    attributeList,
                    1,
                    0,
                    ref attributeListSize))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList failed.");
                }
                attributeListInitialized = true;

                handleList = Marshal.AllocHGlobal(checked(IntPtr.Size * 3));
                Marshal.WriteIntPtr(
                    handleList,
                    0,
                    standardInput.DangerousGetHandle());
                Marshal.WriteIntPtr(
                    handleList,
                    IntPtr.Size,
                    stdoutWrite.DangerousGetHandle());
                Marshal.WriteIntPtr(
                    handleList,
                    checked(IntPtr.Size * 2),
                    stderrWrite.DangerousGetHandle());
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    new IntPtr(unchecked((int)ProcThreadAttributeHandleList)),
                    handleList,
                    new IntPtr(checked(IntPtr.Size * 3)),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "PROC_THREAD_ATTRIBUTE_HANDLE_LIST setup failed.");
                }

                StartupInfoEx startupInfo = new StartupInfoEx();
                startupInfo.StartupInfo.Size =
                    checked((uint)Marshal.SizeOf<StartupInfoEx>());
                startupInfo.StartupInfo.Flags = StartfUseStdHandles;
                startupInfo.StartupInfo.StandardInput =
                    standardInput.DangerousGetHandle();
                startupInfo.StartupInfo.StandardOutput =
                    stdoutWrite.DangerousGetHandle();
                startupInfo.StartupInfo.StandardError =
                    stderrWrite.DangerousGetHandle();
                startupInfo.AttributeList = attributeList;

                StringBuilder commandLine = CreateCommandLine(startInfo);
                uint creationFlags =
                    CreateSuspended |
                    ExtendedStartupInfoPresent |
                    CreateUnicodeEnvironment |
                    CreateNoWindow;
                string workingDirectory =
                    string.IsNullOrEmpty(startInfo.WorkingDirectory)
                        ? null
                        : startInfo.WorkingDirectory;
                if (!CreateProcess(
                    startInfo.FileName,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    creationFlags,
                    environment,
                    workingDirectory,
                    ref startupInfo,
                    out processInformation))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateProcessW(CREATE_SUSPENDED) failed for '" +
                            startInfo.FileName + "'.");
                }

                nativeProcess =
                    new SafeFileHandle(processInformation.Process, true);
                primaryThread =
                    new SafeFileHandle(processInformation.Thread, true);
                processInformation.Process = IntPtr.Zero;
                processInformation.Thread = IntPtr.Zero;

                stdoutWrite.Dispose();
                stdoutWrite = null;
                stderrWrite.Dispose();
                stderrWrite = null;
                standardInput.Dispose();
                standardInput = null;

                managedProcess =
                    Process.GetProcessById(checked((int)processInformation.ProcessId));
                outputStream =
                    new FileStream(stdoutRead, FileAccess.Read, 4096, false);
                stdoutRead = null;
                errorStream =
                    new FileStream(stderrRead, FileAccess.Read, 4096, false);
                stderrRead = null;
                outputReader = new StreamReader(
                    outputStream,
                    startInfo.StandardOutputEncoding ?? Console.OutputEncoding,
                    true,
                    4096,
                    false);
                outputStream = null;
                errorReader = new StreamReader(
                    errorStream,
                    startInfo.StandardErrorEncoding ?? Console.OutputEncoding,
                    true,
                    4096,
                    false);
                errorStream = null;

                SuspendedScenarioProcess result =
                    new SuspendedScenarioProcess(
                        managedProcess,
                        outputReader,
                        errorReader,
                        nativeProcess,
                        primaryThread);
                managedProcess = null;
                outputReader = null;
                errorReader = null;
                nativeProcess = null;
                primaryThread = null;
                return result;
            }
            catch (Exception launchException)
            {
                SafeFileHandle cleanupProcess = nativeProcess;
                Exception cleanupException = null;
                if (cleanupProcess == null &&
                    processInformation.Process != IntPtr.Zero)
                {
                    cleanupProcess =
                        new SafeFileHandle(processInformation.Process, true);
                    processInformation.Process = IntPtr.Zero;
                }
                if (cleanupProcess != null && !cleanupProcess.IsInvalid)
                {
                    try
                    {
                        uint status = WaitForSingleObject(cleanupProcess, 0);
                        if (status == WaitFailed)
                        {
                            throw new Win32Exception(
                                Marshal.GetLastWin32Error(),
                                "Could not query a partially created suspended scenario process.");
                        }
                        if (status != WaitObject0)
                        {
                            if (!TerminateProcess(cleanupProcess, 1))
                            {
                                int error = Marshal.GetLastWin32Error();
                                if (WaitForSingleObject(cleanupProcess, 0) != WaitObject0)
                                {
                                    throw new Win32Exception(
                                        error,
                                        "Could not terminate a partially created suspended scenario process.");
                                }
                            }
                            uint wait = WaitForSingleObject(
                                cleanupProcess,
                                15000);
                            if (wait == WaitTimeout)
                            {
                                throw new TimeoutException(
                                    "A partially created suspended scenario process did not terminate.");
                            }
                            if (wait == WaitFailed)
                            {
                                throw new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Waiting for partial suspended-launch cleanup failed.");
                            }
                        }
                    }
                    catch (Exception exception)
                    {
                        cleanupException = exception;
                    }
                }
                cleanupProcess?.Dispose();
                if (cleanupException != null)
                {
                    throw new AggregateException(
                        "Suspended scenario launch and exact pre-resume cleanup both failed.",
                        launchException,
                        cleanupException);
                }
                throw;
            }
            finally
            {
                if (attributeListInitialized)
                {
                    DeleteProcThreadAttributeList(attributeList);
                }
                if (attributeList != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(attributeList);
                }
                if (handleList != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(handleList);
                }
                if (environment != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(environment);
                }
                stdoutRead?.Dispose();
                stdoutWrite?.Dispose();
                stderrRead?.Dispose();
                stderrWrite?.Dispose();
                standardInput?.Dispose();
                outputStream?.Dispose();
                errorStream?.Dispose();
                outputReader?.Dispose();
                errorReader?.Dispose();
                managedProcess?.Dispose();
                nativeProcess?.Dispose();
                primaryThread?.Dispose();
                if (processInformation.Process != IntPtr.Zero)
                {
                    new SafeFileHandle(
                        processInformation.Process,
                        true).Dispose();
                }
                if (processInformation.Thread != IntPtr.Zero)
                {
                    new SafeFileHandle(
                        processInformation.Thread,
                        true).Dispose();
                }
            }
        }

        public void ResumePrimaryThread()
        {
            lock (stateLock)
            {
                ThrowIfDisposed();
                if (resumed)
                {
                    throw new InvalidOperationException(
                        "The scenario process primary thread was already resumed.");
                }
                uint previousSuspendCount = ResumeThread(primaryThreadHandle);
                if (previousSuspendCount == uint.MaxValue)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "ResumeThread failed for suspended scenario process " +
                            process.Id + ".");
                }
                if (previousSuspendCount != 1)
                {
                    throw new InvalidOperationException(
                        "Suspended scenario process " + process.Id +
                            " had unexpected primary-thread suspend count " +
                            previousSuspendCount + ".");
                }
                resumed = true;
                primaryThreadHandle.Dispose();
            }
        }

        public void TerminateBeforeResume(uint exitCode)
        {
            lock (stateLock)
            {
                ThrowIfDisposed();
                if (resumed)
                {
                    throw new InvalidOperationException(
                        "TerminateBeforeResume cannot target a resumed scenario process.");
                }
                TerminateExactProcess(exitCode, 15000);
            }
        }

        public void WaitForExit()
        {
            ThrowIfDisposed();
            uint wait = WaitForSingleObject(processHandle, Infinite);
            if (wait == WaitFailed)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Waiting for scenario process " + process.Id + " failed.");
            }
        }

        public bool WaitForExit(int milliseconds)
        {
            ThrowIfDisposed();
            if (milliseconds < -1)
            {
                throw new ArgumentOutOfRangeException("milliseconds");
            }
            uint wait = WaitForSingleObject(
                processHandle,
                milliseconds == -1 ? Infinite : checked((uint)milliseconds));
            if (wait == WaitObject0)
            {
                return true;
            }
            if (wait == WaitTimeout)
            {
                return false;
            }
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Waiting for scenario process " + process.Id + " failed.");
        }

        public void Kill()
        {
            ThrowIfDisposed();
            process.Kill();
        }

        public void Kill(bool entireProcessTree)
        {
            ThrowIfDisposed();
            process.Kill(entireProcessTree);
        }

        public void Dispose()
        {
            lock (stateLock)
            {
                if (disposed)
                {
                    return;
                }
                if (!resumed &&
                    processHandle != null &&
                    !processHandle.IsClosed &&
                    !processHandle.IsInvalid)
                {
                    try
                    {
                        TerminateExactProcess(1, 15000);
                    }
                    catch
                    {
                    }
                }
                disposed = true;
                standardOutput.Dispose();
                standardError.Dispose();
                process.Dispose();
                primaryThreadHandle.Dispose();
                processHandle.Dispose();
            }
        }

        private void TerminateExactProcess(uint exitCode, uint timeoutMilliseconds)
        {
            uint status = WaitForSingleObject(processHandle, 0);
            if (status == WaitObject0)
            {
                return;
            }
            if (status == WaitFailed)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not query suspended scenario process " + process.Id + ".");
            }
            if (!TerminateProcess(processHandle, exitCode))
            {
                int error = Marshal.GetLastWin32Error();
                if (WaitForSingleObject(processHandle, 0) != WaitObject0)
                {
                    throw new Win32Exception(
                        error,
                        "TerminateProcess failed for suspended scenario process " +
                            process.Id + ".");
                }
                return;
            }
            uint wait = WaitForSingleObject(processHandle, timeoutMilliseconds);
            if (wait == WaitTimeout)
            {
                throw new TimeoutException(
                    "Suspended scenario process " + process.Id +
                        " did not exit after TerminateProcess.");
            }
            if (wait == WaitFailed)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Waiting for terminated suspended scenario process " +
                        process.Id + " failed.");
            }
        }

        private void ThrowIfDisposed()
        {
            if (disposed)
            {
                throw new ObjectDisposedException("SuspendedScenarioProcess");
            }
        }

        private static void CreateRedirectPipe(
            out SafeFileHandle parentRead,
            out SafeFileHandle childWrite)
        {
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf<SecurityAttributes>();
            attributes.InheritHandle = true;
            IntPtr readHandle;
            IntPtr writeHandle;
            if (!CreatePipe(
                out readHandle,
                out writeHandle,
                ref attributes,
                0))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreatePipe failed for suspended scenario output.");
            }
            parentRead = new SafeFileHandle(readHandle, true);
            childWrite = new SafeFileHandle(writeHandle, true);
            try
            {
                if (!SetHandleInformation(
                    parentRead,
                    HandleFlagInherit,
                    0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not make the parent scenario pipe handle non-inheritable.");
                }
            }
            catch
            {
                parentRead.Dispose();
                childWrite.Dispose();
                throw;
            }
        }

        private static SafeFileHandle OpenInheritedNullInput()
        {
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf<SecurityAttributes>();
            attributes.InheritHandle = true;
            SafeFileHandle handle = CreateFile(
                "NUL",
                GenericRead,
                FileShareRead | FileShareWrite,
                ref attributes,
                OpenExisting,
                FileAttributeNormal,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle?.Dispose();
                throw new Win32Exception(
                    error,
                    "Could not open inherited NUL input for suspended scenario launch.");
            }
            return handle;
        }

        private static StringBuilder CreateCommandLine(
            ProcessStartInfo startInfo)
        {
            StringBuilder commandLine = new StringBuilder();
            AppendArgument(commandLine, startInfo.FileName);
            if (startInfo.ArgumentList.Count > 0)
            {
                if (!string.IsNullOrEmpty(startInfo.Arguments))
                {
                    throw new InvalidOperationException(
                        "ProcessStartInfo cannot combine Arguments and ArgumentList.");
                }
                foreach (string argument in startInfo.ArgumentList)
                {
                    commandLine.Append(' ');
                    AppendArgument(commandLine, argument);
                }
            }
            else if (!string.IsNullOrEmpty(startInfo.Arguments))
            {
                commandLine.Append(' ');
                commandLine.Append(startInfo.Arguments);
            }
            return commandLine;
        }

        private static void AppendArgument(
            StringBuilder commandLine,
            string argument)
        {
            if (argument == null)
            {
                throw new ArgumentNullException("argument");
            }
            bool needsQuotes = argument.Length == 0;
            for (int index = 0;
                index < argument.Length && !needsQuotes;
                index++)
            {
                needsQuotes =
                    char.IsWhiteSpace(argument[index]) ||
                    argument[index] == '"';
            }
            if (!needsQuotes)
            {
                commandLine.Append(argument);
                return;
            }

            commandLine.Append('"');
            int backslashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    commandLine.Append(
                        '\\',
                        checked((backslashes * 2) + 1));
                    commandLine.Append('"');
                    backslashes = 0;
                    continue;
                }
                if (backslashes > 0)
                {
                    commandLine.Append('\\', backslashes);
                    backslashes = 0;
                }
                commandLine.Append(character);
            }
            commandLine.Append('\\', checked(backslashes * 2));
            commandLine.Append('"');
        }

        private static IntPtr CreateEnvironmentBlock(
            ProcessStartInfo startInfo)
        {
            List<KeyValuePair<string, string>> entries =
                new List<KeyValuePair<string, string>>();
            foreach (KeyValuePair<string, string> entry in
                startInfo.Environment)
            {
                if (string.IsNullOrEmpty(entry.Key) ||
                    entry.Key.IndexOf('\0') >= 0 ||
                    (entry.Key[0] != '=' && entry.Key.IndexOf('=') >= 0) ||
                    (entry.Key[0] == '=' &&
                        entry.Key.IndexOf('=', 1) >= 0))
                {
                    throw new InvalidOperationException(
                        "Invalid environment variable name in suspended scenario launch.");
                }
                if (entry.Value == null ||
                    entry.Value.IndexOf('\0') >= 0)
                {
                    throw new InvalidOperationException(
                        "Invalid environment variable value for '" +
                            entry.Key + "'.");
                }
                entries.Add(entry);
            }
            entries.Sort(delegate(
                KeyValuePair<string, string> left,
                KeyValuePair<string, string> right)
            {
                int comparison = string.Compare(
                    left.Key,
                    right.Key,
                    StringComparison.OrdinalIgnoreCase);
                return comparison != 0
                    ? comparison
                    : string.Compare(
                        left.Key,
                        right.Key,
                        StringComparison.Ordinal);
            });

            StringBuilder block = new StringBuilder();
            foreach (KeyValuePair<string, string> entry in entries)
            {
                block.Append(entry.Key);
                block.Append('=');
                block.Append(entry.Value);
                block.Append('\0');
            }
            block.Append('\0');
            return Marshal.StringToHGlobalUni(block.ToString());
        }
    }

    public sealed class ScenarioTrackingJob : IDisposable
    {
        private const int JobObjectBasicProcessIdListClass = 3;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int ErrorMoreData = 234;

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectExtendedLimitInformation
        {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateJobObject(
            IntPtr jobAttributes,
            string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            SafeFileHandle job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(
            SafeFileHandle job,
            IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(
            SafeFileHandle job,
            int informationClass,
            IntPtr information,
            uint informationLength,
            out uint returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(
            SafeFileHandle job,
            uint exitCode);

        private readonly SafeFileHandle handle;

        public ScenarioTrackingJob(string runId)
        {
            Name = "CurrentVsFinalScenario-" + Guid.NewGuid().ToString("N");
            RunId = runId;
            handle = CreateJobObject(IntPtr.Zero, Name);
            if (handle == null || handle.IsInvalid)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateJobObject failed for scenario run '" + runId + "'.");
            }

            try
            {
                JobObjectExtendedLimitInformation limits =
                    new JobObjectExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags =
                    JobObjectLimitKillOnJobClose;
                int size = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(limits, buffer, false);
                    if (!SetInformationJobObject(
                        handle,
                        JobObjectExtendedLimitInformationClass,
                        buffer,
                        checked((uint)size)))
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "SetInformationJobObject(KILL_ON_JOB_CLOSE) failed for scenario run '" +
                                runId + "'.");
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public string Name { get; private set; }
        public string RunId { get; private set; }
        public bool KillOnJobClose { get { return true; } }
        public bool IsClosed { get { return handle.IsClosed; } }

        private void ThrowIfClosed()
        {
            if (handle.IsClosed || handle.IsInvalid)
            {
                throw new ObjectDisposedException(
                    "ScenarioTrackingJob",
                    "The tracking job for scenario run '" + RunId + "' is closed.");
            }
        }

        public void AssignProcess(IntPtr processHandle)
        {
            ThrowIfClosed();
            if (processHandle == IntPtr.Zero ||
                !AssignProcessToJobObject(handle, processHandle))
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(
                    error,
                    "AssignProcessToJobObject failed before resume for scenario run '" +
                        RunId + "'. Nested-job assignment is unsupported or denied " +
                        "by this host; the suspended process will not be resumed.");
            }
        }

        public int[] GetProcessIds()
        {
            ThrowIfClosed();
            int capacity = 64;
            for (int attempt = 0; attempt < 16; attempt++)
            {
                int size = checked(8 + (capacity * IntPtr.Size));
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    uint returned;
                    bool succeeded = QueryInformationJobObject(
                        handle,
                        JobObjectBasicProcessIdListClass,
                        buffer,
                        checked((uint)size),
                        out returned);
                    int error = succeeded ? 0 : Marshal.GetLastWin32Error();
                    uint assigned = unchecked((uint)Marshal.ReadInt32(buffer, 0));
                    uint listed = unchecked((uint)Marshal.ReadInt32(buffer, 4));
                    if (!succeeded && error != ErrorMoreData)
                    {
                        throw new Win32Exception(
                            error,
                            "QueryInformationJobObject failed for scenario run '" +
                                RunId + "'.");
                    }
                    if (!succeeded || assigned > (uint)capacity)
                    {
                        capacity = checked((int)Math.Max(
                            assigned + 16U,
                            (uint)(capacity * 2)));
                        continue;
                    }

                    int[] processIds = new int[listed];
                    for (int index = 0; index < processIds.Length; index++)
                    {
                        long processId = Marshal.ReadIntPtr(
                            buffer,
                            checked(8 + (index * IntPtr.Size))).ToInt64();
                        processIds[index] = checked((int)processId);
                    }
                    return processIds;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            throw new InvalidOperationException(
                "Scenario job membership changed too quickly to obtain a complete census for run '" +
                    RunId + "'.");
        }

        public void Terminate(uint exitCode)
        {
            ThrowIfClosed();
            if (!TerminateJobObject(handle, exitCode))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "TerminateJobObject failed for scenario run '" + RunId + "'.");
            }
        }

        public void Dispose()
        {
            handle.Dispose();
        }
    }
}
'@
}

function New-SuspendedScenarioProcess {
    param(
        [Parameter(Mandatory)]
        [Diagnostics.ProcessStartInfo]$StartInfo
    )

    return [CurrentVsFinalBenchmark.SuspendedScenarioProcess]::Create($StartInfo)
}

function Resume-SuspendedScenarioProcess {
    param(
        [Parameter(Mandatory)]
        [CurrentVsFinalBenchmark.SuspendedScenarioProcess]$Process
    )

    $Process.ResumePrimaryThread()
}

function Stop-SuspendedScenarioProcessBeforeResume {
    param(
        [Parameter(Mandatory)]
        [CurrentVsFinalBenchmark.SuspendedScenarioProcess]$Process
    )

    $Process.TerminateBeforeResume(1)
}

function New-ScenarioTrackingJob {
    param(
        [Parameter(Mandatory)]
        [string]$RunId
    )

    return [CurrentVsFinalBenchmark.ScenarioTrackingJob]::new($RunId)
}

function Add-ProcessToScenarioTrackingJob {
    param(
        [Parameter(Mandatory)]
        [object]$Job,

        [Parameter(Mandatory)]
        [object]$Process
    )

    $processHandle = if ($Process -is [Diagnostics.Process]) {
        $Process.Handle
    }
    elseif ($Process -is [CurrentVsFinalBenchmark.SuspendedScenarioProcess]) {
        $Process.NativeProcessHandle
    }
    else {
        throw "Unsupported process wrapper '$($Process.GetType().FullName)' for scenario job assignment."
    }
    $Job.AssignProcess($processHandle)
}

function Get-ScenarioTrackingJobProcessIds {
    param(
        [Parameter(Mandatory)]
        [object]$Job
    )

    return @($Job.GetProcessIds())
}

function Stop-ScenarioTrackingJob {
    param(
        [Parameter(Mandatory)]
        [object]$Job
    )

    $Job.Terminate(1)
}

function Close-ScenarioTrackingJob {
    param(
        [Parameter(Mandatory)]
        [object]$Job
    )

    $Job.Dispose()
}

function Test-MSBuildCoordinatorProcess {
    param(
        [AllowEmptyString()]
        [string]$Name,

        [AllowNull()]
        [string]$CommandLine
    )

    if ([string]::Equals(
        $Name,
        'MSBuild.Coordinator.exe',
        [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if (-not [string]::Equals(
        $Name,
        'dotnet.exe',
        [StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    $tokens = @(
        [regex]::Matches($CommandLine, '"[^"]*"|[^\s]+') |
            ForEach-Object {
                $_.Value.Trim('"')
            }
    )
    if ($tokens.Count -lt 2) {
        return $false
    }
    $arguments = @($tokens | Select-Object -Skip 1)
    $index = 0
    if ($arguments[0].Equals('exec', [StringComparison]::OrdinalIgnoreCase)) {
        $index++
    }
    $optionsWithValues = @(
        '--additional-deps',
        '--additionalprobingpath',
        '--depsfile',
        '--runtimeconfig',
        '--fx-version',
        '--roll-forward',
        '--runtime',
        '--property'
    )
    while ($index -lt $arguments.Count) {
        $argument = [string]$arguments[$index]
        if ($optionsWithValues -contains $argument.ToLowerInvariant()) {
            $index += 2
            continue
        }
        if ($argument.StartsWith('-', [StringComparison]::Ordinal)) {
            $index++
            continue
        }
        return [string]::Equals(
            [IO.Path]::GetFileName($argument),
            'MSBuild.Coordinator.dll',
            [StringComparison]::OrdinalIgnoreCase)
    }
    return $false
}

function Start-ScenarioMonitor {
    param(
        [Parameter(Mandatory)]
        [string]$MonitorRoot
    )

    $stopFile = Join-Path $MonitorRoot 'stop'
    $readyFile = Join-Path $MonitorRoot 'ready'
    New-Item -ItemType Directory -Force -Path $MonitorRoot | Out-Null
    Remove-Item -LiteralPath $stopFile,$readyFile -Force -ErrorAction SilentlyContinue
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'Monitor-Campaign.ps1'),
        '-OutputRoot', $MonitorRoot,
        '-StopFile', $stopFile,
        '-ReadyFile', $readyFile,
        '-SampleIntervalSeconds', '1',
        '-ProcessIntervalSeconds', '5',
        '-ProbeIntervalSeconds', '5'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $processStartUtc = $null
    try {
        [void]$process.Start()
        $processIdentity = Register-StartedProcess `
            -Process $process `
            -Kind 'resource-monitor' `
            -Source $MonitorRoot
        $processStartUtc =
            ConvertTo-UtcDateTimeOffset -Value $processIdentity.ProcessStartUtc
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $readyFile)) {
            if ($process.HasExited) {
                throw "Resource monitor exited before readiness with code $($process.ExitCode)."
            }
            if ($timer.Elapsed.TotalSeconds -gt 30) {
                throw 'Resource monitor did not become ready within 30 seconds.'
            }
            Start-Sleep -Milliseconds 100
        }
        $readyObservedUtc = [DateTimeOffset]::UtcNow
        [void](Register-ProcessTreeDescendants `
            -RootProcessId $process.Id `
            -Kind 'resource-monitor-worker' `
            -Source $MonitorRoot)
        return [pscustomobject]@{
            Process = $process
            ProcessStartUtc = $processStartUtc
            ReadyObservedUtc = $readyObservedUtc
            StopFile = $stopFile
            ReadyFile = $readyFile
        }
    }
    catch {
        $startupException = $_.Exception
        $stop = if ($null -eq $processStartUtc) {
            [pscustomobject]@{
                Succeeded = $false
                Errors = @('Monitor start identity was not captured.')
            }
        }
        else {
            Stop-VerifiedProcessTree `
                -RootProcessId $process.Id `
                -RootProcessStartUtc $processStartUtc
        }
        $process.Dispose()
        if (-not $stop.Succeeded) {
            throw [AggregateException]::new(
                'Resource monitor startup and cleanup failed.',
                [Exception[]]@(
                    $startupException,
                    [InvalidOperationException]::new(($stop.Errors -join '; '))
                ))
        }
        throw $startupException
    }
}

function Stop-ScenarioMonitor {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Monitor
    )

    $errors = [Collections.Generic.List[string]]::new()
    try {
        try {
            [void](Register-ProcessTreeDescendants `
                -RootProcessId $Monitor.Process.Id `
                -Kind 'resource-monitor-descendant' `
                -Source $Monitor.StopFile)
        }
        catch {
            $errors.Add("Resource monitor descendant capture failed: $($_.Exception.Message)")
        }
        $stopRequestedUtc = [DateTimeOffset]::UtcNow
        $Monitor | Add-Member `
            -NotePropertyName StopRequestedUtc `
            -NotePropertyValue $stopRequestedUtc `
            -Force
        New-Item -ItemType File -Force -Path $Monitor.StopFile | Out-Null
        $Monitor | Add-Member `
            -NotePropertyName StopFileObservedUtc `
            -NotePropertyValue ([DateTimeOffset]::UtcNow) `
            -Force
        if (-not $Monitor.Process.WaitForExit(30000)) {
            $stop = Stop-VerifiedProcessTree `
                -RootProcessId $Monitor.Process.Id `
                -RootProcessStartUtc $Monitor.ProcessStartUtc
            foreach ($message in $stop.Errors) {
                $errors.Add($message)
            }
        }
        if (-not $Monitor.Process.HasExited) {
            $errors.Add('Resource monitor remained live after targeted shutdown.')
        }
        elseif ($Monitor.Process.ExitCode -ne 0) {
            $errors.Add("Resource monitor exited with code $($Monitor.Process.ExitCode).")
        }
        $Monitor | Add-Member `
            -NotePropertyName ProcessExitObservedUtc `
            -NotePropertyValue ([DateTimeOffset]::UtcNow) `
            -Force
    }
    catch {
        $errors.Add($_.Exception.Message)
    }
    finally {
        $Monitor.Process.Dispose()
    }
    if ($errors.Count -gt 0) {
        throw ($errors -join '; ')
    }
}

function ConvertTo-RunRecord {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    [pscustomobject][ordered]@{
        RunId = $Run.RunId
        Kind = $Run.Kind
        Worker = $Run.Worker
        Generation = $Run.Generation
        Priority = $Run.Priority
        Worktree = $Run.Worktree
        RootProcessId = $Run.RootProcessId
        ProcessStartUtc = $Run.ProcessStartUtc.ToString('O')
        ProcessExitUtc = if ($null -eq $Run.ProcessExitUtc) { $null } else { $Run.ProcessExitUtc.ToString('O') }
        StartOffsetSeconds = $Run.StartOffsetSeconds
        DurationSeconds = if ($null -eq $Run.ProcessExitUtc) {
            $null
        }
        else {
            ($Run.ProcessExitUtc - $Run.ProcessStartUtc).TotalSeconds
        }
        ExitCode = $Run.ExitCode
        Quiescent = $Run.Quiescent
        EnvironmentPath = $Run.EnvironmentPath
        Stdout = $Run.Stdout
        Stderr = $Run.Stderr
        Binlog = $Run.Binlog
        Command = $Run.Command
        TrackingJobName = $Run.TrackingJobName
        TrackingJobClosed = $Run.TrackingJobClosed
        JobCensusFailed = $Run.JobCensusFailed
        JobMembershipQueryCount = $Run.JobMembershipQueryCount
        JobMemberIdentities = @($Run.JobMemberIdentities)
        CoordinatorIdentities = @($Run.CoordinatorIdentities)
        DescendantIdentities = @($Run.DescendantIdentities)
    }
}

function Test-ScenarioRunTrackingJobOpen {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    $jobProperty = $Run.PSObject.Properties['TrackingJob']
    if ($null -eq $jobProperty -or $null -eq $jobProperty.Value) {
        return $false
    }
    return -not [bool]$jobProperty.Value.IsClosed
}

function Add-ScenarioJobCensusError {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($null -eq $Run.PSObject.Properties['JobCensusFailed']) {
        $Run | Add-Member -NotePropertyName JobCensusFailed -NotePropertyValue $true
    }
    else {
        $Run.JobCensusFailed = $true
    }
    if ($null -eq $Run.PSObject.Properties['JobCensusErrors']) {
        $Run | Add-Member `
            -NotePropertyName JobCensusErrors `
            -NotePropertyValue ([Collections.Generic.List[string]]::new())
    }
    $Run.JobCensusErrors.Add($Message)
}

function Get-ScenarioRunJobProcessIds {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    if (-not (Test-ScenarioRunTrackingJobOpen -Run $Run)) {
        return @()
    }
    try {
        $processIds = @(
            Get-ScenarioTrackingJobProcessIds -Job $Run.TrackingJob |
                Sort-Object -Unique
        )
        if ($null -ne $Run.PSObject.Properties['JobMembershipQueryCount']) {
            $Run.JobMembershipQueryCount++
            $Run.JobMembershipLastQueryUtc = [DateTimeOffset]::UtcNow
        }
        return [int[]]@($processIds)
    }
    catch {
        $message =
            "Tracking job membership query failed for '$($Run.RunId)': $($_.Exception.Message)"
        Add-ScenarioJobCensusError -Run $Run -Message $message
        throw $message
    }
}

function Close-ScenarioRunTrackingJob {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    if (-not (Test-ScenarioRunTrackingJobOpen -Run $Run)) {
        return
    }
    Close-ScenarioTrackingJob -Job $Run.TrackingJob
    $Run.TrackingJobClosed = $true
    $Run.TrackingJobClosedUtc = [DateTimeOffset]::UtcNow
    $Run.CurrentJobProcessIds = [int[]]@()
    $Run.CurrentNonCoordinatorJobProcessIds = [int[]]@()
    $Run.CurrentCoordinatorJobProcessIds = [int[]]@()
    $Run.CurrentCoordinatorRootJobProcessIds = [int[]]@()
    $Run.CurrentCoordinatorInfrastructureJobProcessIds = [int[]]@()
}

function Get-ScenarioProcessRow {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [hashtable]$ByProcessId,

        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    if ($ByProcessId.ContainsKey($ProcessId)) {
        return $ByProcessId[$ProcessId]
    }

    $queryError = $null
    try {
        $rows = @(
            Get-CimInstance `
                Win32_Process `
                -Filter "ProcessId = $ProcessId" `
                -OperationTimeoutSec 5 `
                -ErrorAction Stop
        )
        if ($rows.Count -eq 1) {
            return $rows[0]
        }
    }
    catch {
        $queryError = $_.Exception
    }

    $currentIds = @(Get-ScenarioRunJobProcessIds -Run $Run)
    if ($currentIds -notcontains $ProcessId) {
        return $null
    }
    if ($null -ne $queryError) {
        throw "PID $ProcessId remained in tracking job '$($Run.TrackingJobName)' but its process metadata query failed: $($queryError.Message)"
    }
    throw "PID $ProcessId remained in tracking job '$($Run.TrackingJobName)' but Win32_Process returned no metadata."
}

function Test-ScenarioCoordinatorProcessRow {
    param(
        [Parameter(Mandatory)]
        [object]$ProcessRow,

        [Parameter(Mandatory)]
        [string]$Context
    )

    $nameProperty = $ProcessRow.PSObject.Properties['Name']
    if ($null -eq $nameProperty -or
        [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
        throw "$Context has no process name for Coordinator classification."
    }
    $name = [string]$nameProperty.Value
    $commandLineProperty = $ProcessRow.PSObject.Properties['CommandLine']
    $commandLine = if ($null -eq $commandLineProperty) {
        $null
    }
    else {
        [string]$commandLineProperty.Value
    }
    if ([string]::Equals(
        $name,
        'dotnet.exe',
        [StringComparison]::OrdinalIgnoreCase) -and
        [string]::IsNullOrWhiteSpace($commandLine)) {
        throw "$Context is dotnet.exe but has no command line for Coordinator classification."
    }
    return [bool](Test-MSBuildCoordinatorProcess `
        -Name $name `
        -CommandLine $commandLine)
}

function Resolve-ScenarioJobMemberClassifications {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$ProcessIds,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ProcessRows,

        [string]$Context = 'scenario tracking job'
    )

    $jobProcessIds = [Collections.Generic.HashSet[int]]::new()
    foreach ($processId in @($ProcessIds)) {
        if ($processId -le 0) {
            throw "$Context contains invalid PID '$processId'."
        }
        if (-not $jobProcessIds.Add([int]$processId)) {
            throw "$Context contains duplicate PID '$processId'."
        }
    }

    $metadataByProcessId = @{}
    $coordinatorRootIds = [Collections.Generic.HashSet[int]]::new()
    foreach ($row in @($ProcessRows)) {
        if ($null -eq $row) {
            throw "$Context contains null process metadata."
        }
        $processIdProperty = $row.PSObject.Properties['ProcessId']
        if ($null -eq $processIdProperty -or
            $null -eq $processIdProperty.Value) {
            throw "$Context contains process metadata without ProcessId."
        }
        try {
            $processId = [int]$processIdProperty.Value
        }
        catch {
            throw "$Context contains an invalid process metadata PID '$($processIdProperty.Value)'."
        }
        if (-not $jobProcessIds.Contains($processId)) {
            throw "$Context returned metadata for non-member PID $processId."
        }
        if ($metadataByProcessId.ContainsKey($processId)) {
            throw "$Context returned duplicate metadata for PID $processId."
        }

        $parentProperty = $row.PSObject.Properties['ParentProcessId']
        if ($null -eq $parentProperty -or $null -eq $parentProperty.Value) {
            throw "$Context PID $processId has no ParentProcessId for ancestry classification."
        }
        try {
            $parentProcessId = [int]$parentProperty.Value
        }
        catch {
            throw "$Context PID $processId has invalid ParentProcessId '$($parentProperty.Value)'."
        }
        if ($parentProcessId -lt 0) {
            throw "$Context PID $processId has invalid ParentProcessId '$parentProcessId'."
        }

        $coordinatorRoot = Test-ScenarioCoordinatorProcessRow `
            -ProcessRow $row `
            -Context "$Context PID $processId"
        $metadataByProcessId[$processId] = [pscustomobject]@{
            ProcessId = $processId
            ParentProcessId = $parentProcessId
            ProcessRow = $row
            CoordinatorRoot = [bool]$coordinatorRoot
        }
        if ($coordinatorRoot) {
            [void]$coordinatorRootIds.Add($processId)
        }
    }
    foreach ($processId in $jobProcessIds) {
        if (-not $metadataByProcessId.ContainsKey($processId)) {
            throw "$Context has no process metadata for member PID $processId."
        }
    }

    foreach ($processId in @($ProcessIds)) {
        $metadata = $metadataByProcessId[[int]$processId]
        $classification = if ($metadata.CoordinatorRoot) {
            'CoordinatorRoot'
        }
        else {
            $visited = [Collections.Generic.HashSet[int]]::new()
            $cursor = [int]$processId
            $resolved = $null
            while ($null -eq $resolved) {
                if (-not $visited.Add($cursor)) {
                    throw "$Context contains a parent cycle reaching PID $cursor from PID $processId."
                }
                if (-not $metadataByProcessId.ContainsKey($cursor)) {
                    throw "$Context lacks ancestry metadata for member PID $cursor."
                }
                $parentProcessId =
                    [int]$metadataByProcessId[$cursor].ParentProcessId
                if ($coordinatorRootIds.Contains($parentProcessId)) {
                    $resolved = 'CoordinatorInfrastructure'
                    continue
                }
                if (-not $jobProcessIds.Contains($parentProcessId)) {
                    $resolved = 'Client'
                    continue
                }
                $cursor = $parentProcessId
            }
            $resolved
        }

        [pscustomobject][ordered]@{
            ProcessId = [int]$processId
            ParentProcessId = [int]$metadata.ParentProcessId
            Classification = $classification
            ProcessRow = $metadata.ProcessRow
        }
    }
}

function Get-ScenarioProcessStartUtc {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run,

        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [object]$ProcessRow
    )

    if ($ProcessId -eq $Run.RootProcessId) {
        return ConvertTo-UtcDateTimeOffset -Value $Run.ProcessStartUtc
    }

    $creationDateProperty = $ProcessRow.PSObject.Properties['CreationDate']
    if ($null -ne $creationDateProperty -and
        $null -ne $creationDateProperty.Value) {
        return ConvertTo-UtcDateTimeOffset -Value $creationDateProperty.Value
    }

    $queriedProcess = $null
    try {
        $queriedProcess = [Diagnostics.Process]::GetProcessById($ProcessId)
        return ConvertTo-UtcDateTimeOffset -Value $queriedProcess.StartTime
    }
    catch {
        $currentIds = @(Get-ScenarioRunJobProcessIds -Run $Run)
        if ($currentIds -notcontains $ProcessId) {
            return $null
        }
        throw "PID $ProcessId remained in tracking job '$($Run.TrackingJobName)' but its exact start identity could not be captured: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $queriedProcess) {
            $queriedProcess.Dispose()
        }
    }
}

function Register-ScenarioJobMember {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run,

        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [object]$ProcessRow,

        [Parameter(Mandatory)]
        [ValidateSet('Client', 'CoordinatorRoot', 'CoordinatorInfrastructure')]
        [string]$Classification
    )

    $start = Get-ScenarioProcessStartUtc `
        -Run $Run `
        -ProcessId $ProcessId `
        -ProcessRow $ProcessRow
    if ($null -eq $start) {
        return $null
    }
    $identity = "$ProcessId|$($start.ToString('O'))"
    [void]$Run.JobMemberIdentities.Add($identity)

    $coordinator = $Classification -ne 'Client'
    if ($coordinator) {
        [void]$Run.CoordinatorIdentities.Add($identity)
        foreach ($descendantIdentity in @($Run.DescendantIdentities)) {
            if ([string]$descendantIdentity -like "$ProcessId|*") {
                [void]$Run.DescendantIdentities.Remove(
                    [string]$descendantIdentity)
            }
        }
        [void](Register-ProcessIdentity `
            -ProcessId $ProcessId `
            -ProcessStartUtc $start `
            -Kind $(if ($Classification -eq 'CoordinatorRoot') {
                'scenario-coordinator'
            }
            else {
                'scenario-coordinator-infrastructure'
            }) `
            -Source $Run.RunId)
    }
    elseif ($ProcessId -ne $Run.RootProcessId) {
        [void]$Run.DescendantIdentities.Add($identity)
        [void](Register-ProcessIdentity `
            -ProcessId $ProcessId `
            -ProcessStartUtc $start `
            -Kind "scenario-build-descendant/$($Run.RunId)" `
            -Source $Run.RunId)
    }

    return [pscustomobject]@{
        ProcessId = $ProcessId
        Identity = $identity
        Coordinator = $coordinator
        Classification = $Classification
    }
}

function Update-ScenarioJobMembership {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run,

        [Parameter(Mandatory)]
        [hashtable]$ByProcessId
    )

    $jobRequiredProperty = $Run.PSObject.Properties['TrackingJobRequired']
    $jobRequired =
        $null -ne $jobRequiredProperty -and [bool]$jobRequiredProperty.Value
    if (-not (Test-ScenarioRunTrackingJobOpen -Run $Run)) {
        if ($jobRequired -and -not [bool]$Run.TrackingJobClosed) {
            $message = "Scenario run '$($Run.RunId)' has no open dedicated tracking job."
            Add-ScenarioJobCensusError -Run $Run -Message $message
            throw $message
        }
        return
    }

    try {
        foreach ($censusAttempt in 1..16) {
            $processIds = @(Get-ScenarioRunJobProcessIds -Run $Run)
            $processRows = [Collections.Generic.List[object]]::new()
            $metadataChanged = $false
            foreach ($processId in $processIds) {
                $row = Get-ScenarioProcessRow `
                    -ProcessId ([int]$processId) `
                    -ByProcessId $ByProcessId `
                    -Run $Run
                if ($null -eq $row) {
                    $metadataChanged = $true
                    break
                }
                $processRows.Add($row)
            }
            if ($metadataChanged) {
                Start-Sleep -Milliseconds 10
                continue
            }

            $metadataConfirmedProcessIds =
                @(Get-ScenarioRunJobProcessIds -Run $Run)
            if (($processIds -join ',') -ne
                ($metadataConfirmedProcessIds -join ',')) {
                Start-Sleep -Milliseconds 10
                continue
            }
            $classifications = @(
                Resolve-ScenarioJobMemberClassifications `
                    -ProcessIds ([int[]]@($processIds)) `
                    -ProcessRows $processRows.ToArray() `
                    -Context "tracking job '$($Run.TrackingJobName)'"
            )
            $confirmedProcessIds = @(Get-ScenarioRunJobProcessIds -Run $Run)
            if (($processIds -join ',') -ne
                ($confirmedProcessIds -join ',')) {
                Start-Sleep -Milliseconds 10
                continue
            }

            $members = [Collections.Generic.List[object]]::new()
            $registrationChanged = $false
            foreach ($classification in $classifications) {
                $member = Register-ScenarioJobMember `
                    -Run $Run `
                    -ProcessId ([int]$classification.ProcessId) `
                    -ProcessRow $classification.ProcessRow `
                    -Classification ([string]$classification.Classification)
                if ($null -eq $member) {
                    $registrationChanged = $true
                    break
                }
                $members.Add($member)
            }
            if ($registrationChanged) {
                Start-Sleep -Milliseconds 10
                continue
            }

            $finalProcessIds = @(Get-ScenarioRunJobProcessIds -Run $Run)
            if (($processIds -join ',') -eq ($finalProcessIds -join ',')) {
                $nonCoordinatorIds = @(
                    $members |
                        Where-Object Classification -eq 'Client' |
                        Select-Object -ExpandProperty ProcessId
                )
                $coordinatorRootIds = @(
                    $members |
                        Where-Object Classification -eq 'CoordinatorRoot' |
                        Select-Object -ExpandProperty ProcessId
                )
                $coordinatorInfrastructureIds = @(
                    $members |
                        Where-Object Classification -eq 'CoordinatorInfrastructure' |
                        Select-Object -ExpandProperty ProcessId
                )
                $Run.CurrentJobProcessIds =
                    [int[]]@($finalProcessIds)
                $Run.CurrentNonCoordinatorJobProcessIds =
                    [int[]]@($nonCoordinatorIds)
                $Run.CurrentCoordinatorJobProcessIds =
                    [int[]]@(
                        @($coordinatorRootIds) +
                            @($coordinatorInfrastructureIds)
                    )
                $Run.CurrentCoordinatorRootJobProcessIds =
                    [int[]]@($coordinatorRootIds)
                $Run.CurrentCoordinatorInfrastructureJobProcessIds =
                    [int[]]@($coordinatorInfrastructureIds)
                return
            }
            Start-Sleep -Milliseconds 10
        }
        throw "Tracking job membership for '$($Run.RunId)' did not stabilize during census."
    }
    catch {
        if (-not [bool]$Run.JobCensusFailed) {
            Add-ScenarioJobCensusError `
                -Run $Run `
                -Message "Tracking job census failed for '$($Run.RunId)': $($_.Exception.Message)"
        }
        throw
    }
}

function Start-ScenarioBuild {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Bootstrap,

        [Parameter(Mandatory)]
        [pscustomobject]$Repository,

        [Parameter(Mandatory)]
        [string]$Worktree,

        [Parameter(Mandatory)]
        [string]$Condition,

        [Parameter(Mandatory)]
        [string]$PipeName,

        [Parameter(Mandatory)]
        [string]$DebugPath,

        [Parameter(Mandatory)]
        [string]$ScenarioRoot,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [int]$Worker,

        [Parameter(Mandatory)]
        [int]$Generation,

        [Parameter(Mandatory)]
        [DateTimeOffset]$ScenarioStartedUtc,

        [switch]$Injected
    )

    $runRoot = Join-Path $ScenarioRoot "runs\$RunId"
    if (Test-Path -LiteralPath $runRoot) {
        throw "Run root '$runRoot' already exists."
    }
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $stdout = Join-Path $runRoot 'stdout.log'
    $stderr = Join-Path $runRoot 'stderr.log'
    $binlog = Join-Path $runRoot 'build.binlog'
    $environmentPath = Join-Path $runRoot 'environment.json'
    $environment = New-ConditionEnvironment `
        -Condition $Condition `
        -PipeName $PipeName `
        -DotNetRoot $Bootstrap.Root `
        -Injected:$Injected `
        -EnableDebugTrace `
        -DebugPath $DebugPath
    Assert-ConditionEnvironmentContract -Condition $Condition -Environment $environment -Injected:$Injected
    $environmentRecord = Get-EnvironmentContractRecord -Environment $environment
    Write-JsonAtomic -Path $environmentPath -Value $environmentRecord

    $arguments = New-BuildArguments `
        -MSBuildDllPath $Bootstrap.MSBuildDllPath `
        -BuildPath $Repository.BuildPath `
        -BinlogPath $binlog `
        -AdditionalArguments $Repository.AdditionalBuildArguments
    $startInfo = [Diagnostics.ProcessStartInfo]::new($Bootstrap.DotNetPath)
    foreach ($argument in $arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.WorkingDirectory = $Worktree
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($item in $environment.GetEnumerator()) {
        if ($null -eq $item.Value) {
            [void]$startInfo.Environment.Remove([string]$item.Key)
        }
        else {
            $startInfo.Environment[[string]$item.Key] = [string]$item.Value
        }
    }
    $process = $null
    $processStartUtc = $null
    $trackingJob = $null
    $processCreated = $false
    $processResumed = $false
    $jobAssigned = $false
    $trackingFailureRecorded = $false
    $stdoutTask = $null
    $stderrTask = $null
    try {
        try {
            $trackingJob = New-ScenarioTrackingJob -RunId $RunId
        }
        catch {
            $trackingFailureRecorded = $true
            [void](Write-ScenarioTerminalOutcome `
                -ScenarioRoot $ScenarioRoot `
                -OutcomeType 'ScenarioTrackingJobStartupFailure' `
                -Disposition 'NonRetryableHarnessFailure' `
                -Errors @(
                    "Dedicated KILL_ON_JOB_CLOSE tracking job creation failed for build '$RunId': $($_.Exception.Message)"
                ))
            throw
        }
        try {
            $process = New-SuspendedScenarioProcess -StartInfo $startInfo
            $processCreated = $true
        }
        catch {
            $trackingFailureRecorded = $true
            [void](Write-ScenarioTerminalOutcome `
                -ScenarioRoot $ScenarioRoot `
                -OutcomeType 'ScenarioSuspendedLaunchFailure' `
                -Disposition 'NonRetryableHarnessFailure' `
                -Errors @(
                    "CREATE_SUSPENDED launch failed for build '$RunId'; no unsuspended fallback is allowed: $($_.Exception.Message)"
                ))
            throw
        }
        try {
            Add-ProcessToScenarioTrackingJob `
                -Job $trackingJob `
                -Process $process
            $jobAssigned = $true
        }
        catch {
            $trackingFailureRecorded = $true
            [void](Write-ScenarioTerminalOutcome `
                -ScenarioRoot $ScenarioRoot `
                -OutcomeType 'ScenarioTrackingJobStartupFailure' `
                -Disposition 'NonRetryableHarnessFailure' `
                -Errors @(
                    "Assignment of suspended build '$RunId' to its dedicated KILL_ON_JOB_CLOSE tracking job failed before resume; nested-job assignment may be unsupported: $($_.Exception.Message)"
                ))
            throw
        }
        try {
            $processIdentity = Register-StartedProcess `
                -Process $process.ManagedProcess `
                -Kind "scenario-build/$RunId" `
                -Source $ScenarioRoot
            $processStartUtc =
                ConvertTo-UtcDateTimeOffset -Value $processIdentity.ProcessStartUtc
            $rootIdentity = "$($process.Id)|$($processStartUtc.ToString('O'))"
            $jobMemberIdentities =
                [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            [void]$jobMemberIdentities.Add($rootIdentity)
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            Resume-SuspendedScenarioProcess -Process $process
            $processResumed = $true
        }
        catch {
            $trackingFailureRecorded = $true
            [void](Write-ScenarioTerminalOutcome `
                -ScenarioRoot $ScenarioRoot `
                -OutcomeType 'ScenarioSuspendedLaunchFailure' `
                -Disposition 'NonRetryableHarnessFailure' `
                -Errors @(
                    "Pre-resume identity registration or ResumeThread failed for build '$RunId': $($_.Exception.Message)"
                ))
            throw
        }
        return [pscustomobject][ordered]@{
            RunId = $RunId
            Kind = $Kind
            Worker = $Worker
            Generation = $Generation
            Priority = if ($Condition -eq 'FINAL-H' -and $Injected) { 'High' } else { 'Normal' }
            Injected = [bool]$Injected
            Worktree = $Worktree
            Process = $process
            RootProcessId = $process.Id
            ProcessStartUtc = $processStartUtc
            ProcessExitUtc = $null
            StartOffsetSeconds = ($processStartUtc - $ScenarioStartedUtc).TotalSeconds
            ExitCode = $null
            Quiescent = $null
            Completed = $false
            CompletionEventWritten = $false
            StdoutTask = $stdoutTask
            StderrTask = $stderrTask
            Stdout = $stdout
            Stderr = $stderr
            Binlog = $binlog
            EnvironmentPath = $environmentPath
            Command = [pscustomobject]@{
                FileName = $Bootstrap.DotNetPath
                Arguments = $arguments
                WorkingDirectory = $Worktree
            }
            DescendantIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            CoordinatorIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            JobMemberIdentities = $jobMemberIdentities
            CurrentJobProcessIds = [int[]]@($process.Id)
            CurrentNonCoordinatorJobProcessIds = [int[]]@($process.Id)
            CurrentCoordinatorJobProcessIds = [int[]]@()
            CurrentCoordinatorRootJobProcessIds = [int[]]@()
            CurrentCoordinatorInfrastructureJobProcessIds = [int[]]@()
            TrackingJobRequired = $true
            TrackingJob = $trackingJob
            TrackingJobName = $trackingJob.Name
            TrackingJobClosed = $false
            TrackingJobClosedUtc = $null
            JobMembershipQueryCount = 0
            JobMembershipLastQueryUtc = $null
            JobCensusFailed = $false
            JobCensusErrors = [Collections.Generic.List[string]]::new()
        }
    }
    catch {
        $startException = $_.Exception
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        if ($null -ne $trackingJob) {
            if ($jobAssigned -and -not $trackingJob.IsClosed) {
                try {
                    Stop-ScenarioTrackingJob -Job $trackingJob
                }
                catch {
                    $cleanupErrors.Add(
                        "Tracking job termination failed: $($_.Exception.Message)")
                }
            }
        }
        if ($processCreated) {
            try {
                if (-not $process.HasExited) {
                    if (-not $processResumed) {
                        Stop-SuspendedScenarioProcessBeforeResume -Process $process
                    }
                    else {
                        $process.Kill($true)
                    }
                    if (-not $process.WaitForExit(15000)) {
                        $cleanupErrors.Add(
                            "Build '$RunId' did not exit within 15 seconds after startup cleanup.")
                    }
                }
            }
            catch {
                $cleanupErrors.Add(
                    "Direct-reference startup cleanup failed: $($_.Exception.Message)")
            }
        }
        if ($null -ne $trackingJob -and -not $trackingJob.IsClosed) {
            try {
                Close-ScenarioTrackingJob -Job $trackingJob
            }
            catch {
                $cleanupErrors.Add(
                    "Tracking job close failed: $($_.Exception.Message)")
            }
        }
        if (-not $trackingFailureRecorded -and $cleanupErrors.Count -gt 0) {
            [void](Write-ScenarioTerminalOutcome `
                -ScenarioRoot $ScenarioRoot `
                -OutcomeType 'LiveBuildStartupCleanupFailure' `
                -Disposition 'NonRetryableHarnessFailure' `
                -Errors $cleanupErrors.ToArray())
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
        if ($cleanupErrors.Count -gt 0) {
            throw [AggregateException]::new(
                "Build '$RunId' startup and targeted cleanup failed.",
                [Exception[]]@(
                    $startException,
                    [InvalidOperationException]::new(
                        ($cleanupErrors.ToArray() -join '; '))
                ))
        }
        throw $startException
    }
}

function Update-ScenarioProcessTrees {
    param(
        [Parameter(Mandatory)]
        [object[]]$Runs,

        [object[]]$Processes
    )

    $activeRuns = @(
        $Runs |
            Where-Object {
                -not $_.Completed -or
                (Test-ScenarioRunTrackingJobOpen -Run $_)
            }
    )
    if ($activeRuns.Count -eq 0) {
        return
    }
    try {
        $processes = if ($PSBoundParameters.ContainsKey('Processes')) {
            @($Processes)
        }
        else {
            @(
                Get-CimInstance `
                    Win32_Process `
                    -OperationTimeoutSec 5 `
                    -ErrorAction Stop
            )
        }
    }
    catch {
        foreach ($run in $activeRuns) {
            if (Test-ScenarioRunTrackingJobOpen -Run $run) {
                Add-ScenarioJobCensusError `
                    -Run $run `
                    -Message "Process metadata census failed for '$($run.RunId)': $($_.Exception.Message)"
            }
        }
        throw
    }
    $children = @{}
    $byPid = @{}
    foreach ($process in $processes) {
        $processIdValue = [int]$process.ProcessId
        $byPid[$processIdValue] = $process
        $parent = [int]$process.ParentProcessId
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = [Collections.Generic.List[int]]::new()
        }
        $children[$parent].Add($processIdValue)
    }
    foreach ($run in $activeRuns) {
        Update-ScenarioJobMembership `
            -Run $run `
            -ByProcessId $byPid
        if ($null -eq $run.PSObject.Properties['CoordinatorIdentities']) {
            $run | Add-Member `
                -NotePropertyName CoordinatorIdentities `
                -NotePropertyValue (
                    [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::Ordinal))
        }
        $currentCoordinatorJobIds =
            [Collections.Generic.HashSet[int]]::new()
        $currentCoordinatorRootJobIds =
            [Collections.Generic.HashSet[int]]::new()
        $currentCoordinatorInfrastructureJobIds =
            [Collections.Generic.HashSet[int]]::new()
        foreach ($propertyAndSet in @(
            [pscustomobject]@{
                Name = 'CurrentCoordinatorJobProcessIds'
                Set = $currentCoordinatorJobIds
            },
            [pscustomobject]@{
                Name = 'CurrentCoordinatorRootJobProcessIds'
                Set = $currentCoordinatorRootJobIds
            },
            [pscustomobject]@{
                Name = 'CurrentCoordinatorInfrastructureJobProcessIds'
                Set = $currentCoordinatorInfrastructureJobIds
            }
        )) {
            $property = $run.PSObject.Properties[$propertyAndSet.Name]
            if ($null -ne $property) {
                foreach ($processId in @($property.Value)) {
                    [void]$propertyAndSet.Set.Add([int]$processId)
                }
            }
        }
        $coordinatorTreeIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($processId in $currentCoordinatorJobIds) {
            [void]$coordinatorTreeIds.Add($processId)
        }
        $queue = [Collections.Generic.Queue[int]]::new()
        $seen = [Collections.Generic.HashSet[int]]::new()
        $queue.Enqueue($run.RootProcessId)
        [void]$seen.Add($run.RootProcessId)
        while ($queue.Count -gt 0) {
            $parent = $queue.Dequeue()
            if (-not $children.ContainsKey($parent)) {
                continue
            }
            foreach ($child in $children[$parent]) {
                if (-not $seen.Add($child)) {
                    continue
                }
                $queue.Enqueue($child)
                $process = $byPid[$child]
                $knownCoordinatorJobMember =
                    $currentCoordinatorJobIds.Contains($child)
                $coordinatorRoot =
                    $currentCoordinatorRootJobIds.Contains($child)
                if (-not $coordinatorRoot) {
                    $coordinatorRoot = Test-ScenarioCoordinatorProcessRow `
                        -ProcessRow $process `
                        -Context "scenario ancestry PID $child"
                }
                $coordinatorInfrastructure =
                    -not $coordinatorRoot -and (
                        $currentCoordinatorInfrastructureJobIds.Contains(
                            $child) -or
                        $coordinatorTreeIds.Contains($parent) -or
                        ($knownCoordinatorJobMember -and
                            -not $currentCoordinatorRootJobIds.Contains(
                                $child))
                    )
                if ($coordinatorRoot -or $coordinatorInfrastructure) {
                    [void]$coordinatorTreeIds.Add($child)
                    foreach ($descendantIdentity in @(
                        $run.DescendantIdentities
                    )) {
                        if ([string]$descendantIdentity -like "$child|*") {
                            [void]$run.DescendantIdentities.Remove(
                                [string]$descendantIdentity)
                        }
                    }
                    if ($knownCoordinatorJobMember) {
                        continue
                    }
                    $start = Get-ScenarioProcessStartUtc `
                        -Run $run `
                        -ProcessId $child `
                        -ProcessRow $process
                    if ($null -eq $start) {
                        continue
                    }
                    $identity = "$child|$($start.ToString('O'))"
                    [void]$run.CoordinatorIdentities.Add($identity)
                    [void](Register-ProcessIdentity `
                        -ProcessId $child `
                        -ProcessStartUtc $start `
                        -Kind $(if ($coordinatorRoot) {
                            'scenario-coordinator'
                        }
                        else {
                            'scenario-coordinator-infrastructure'
                        }) `
                        -Source $run.RunId)
                    continue
                }

                $created = if ($null -eq $process.CreationDate) {
                    ''
                }
                else {
                    (ConvertTo-UtcDateTimeOffset -Value $process.CreationDate).ToString('O')
                }
                [void]$run.DescendantIdentities.Add("$child|$created")
                [void](Register-ProcessIdentity `
                    -ProcessId $child `
                    -ProcessStartUtc $created `
                    -Kind "scenario-build-descendant/$($run.RunId)" `
                    -Source $run.RunId)
            }
        }
    }
}

function Test-RunDescendantsExited {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run
    )

    $censusFailureProperty = $Run.PSObject.Properties['JobCensusFailed']
    if ($null -ne $censusFailureProperty -and
        [bool]$censusFailureProperty.Value) {
        return $false
    }
    $currentMemberProperty =
        $Run.PSObject.Properties['CurrentNonCoordinatorJobProcessIds']
    if ($null -ne $currentMemberProperty -and
        @($currentMemberProperty.Value).Count -gt 0) {
        return $false
    }
    $coordinatorIdentityProperty =
        $Run.PSObject.Properties['CoordinatorIdentities']
    $coordinatorIdentities = if ($null -eq $coordinatorIdentityProperty) {
        @()
    }
    else {
        @($coordinatorIdentityProperty.Value)
    }
    foreach ($identity in $Run.DescendantIdentities) {
        if ($coordinatorIdentities -contains $identity) {
            continue
        }
        $parts = $identity -split '\|', 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
            return $false
        }
        $status = Get-VerifiedProcessIdentityStatus `
            -ProcessId ([int]$parts[0]) `
            -ProcessStartUtc $parts[1]
        if ($status.Status -eq 'QueryFailed') {
            throw "Could not verify captured descendant '$identity': $($status.Error)"
        }
        if ($status.Live) {
            return $false
        }
    }
    return $true
}

function Complete-ExitedScenarioBuild {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run,

        [int]$QuiescenceTimeoutSeconds = 60
    )

    if ($Run.Completed -or -not $Run.Process.HasExited) {
        return $false
    }
    $completionError = $null
    try {
        $Run.Process.WaitForExit()
        $Run.ProcessExitUtc = ConvertTo-UtcDateTimeOffset -Value $Run.Process.ExitTime
        $Run.ExitCode = $Run.Process.ExitCode
        # The job census is authoritative; ancestry sampling remains defense in depth.
        foreach ($captureAttempt in 1..10) {
            Update-ScenarioProcessTrees -Runs @($Run)
            if ($captureAttempt -lt 10) {
                Start-Sleep -Milliseconds 100
            }
        }
        if (-not $Run.StdoutTask.Wait([TimeSpan]::FromSeconds($QuiescenceTimeoutSeconds)) -or
            -not $Run.StderrTask.Wait([TimeSpan]::FromSeconds($QuiescenceTimeoutSeconds))) {
            $Run.Quiescent = $false
        }
        else {
            [IO.File]::WriteAllText(
                $Run.Stdout,
                $Run.StdoutTask.GetAwaiter().GetResult(),
                [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText(
                $Run.Stderr,
                $Run.StderrTask.GetAwaiter().GetResult(),
                [Text.UTF8Encoding]::new($false))
            $timer = [Diagnostics.Stopwatch]::StartNew()
            do {
                Update-ScenarioProcessTrees -Runs @($Run)
                $descendantsExited = Test-RunDescendantsExited -Run $Run
                if ($descendantsExited -or
                    $timer.Elapsed.TotalSeconds -gt $QuiescenceTimeoutSeconds) {
                    break
                }
                Start-Sleep -Milliseconds 100
            } while ($true)
            Update-ScenarioProcessTrees -Runs @($Run)
            $Run.Quiescent = Test-RunDescendantsExited -Run $Run
            if ($Run.Quiescent -and
                (Test-ScenarioRunTrackingJobOpen -Run $Run)) {
                if (@($Run.CurrentJobProcessIds).Count -eq 0) {
                    Close-ScenarioRunTrackingJob -Run $Run
                }
            }
        }
    }
    catch {
        $Run.Quiescent = $false
        $completionError = $_.Exception
    }
    finally {
        $Run.Completed = $true
        $Run.Process.Dispose()
    }
    if ($null -ne $completionError) {
        throw $completionError
    }
    return $true
}

function Stop-UnfinishedScenarioBuilds {
    param(
        [Parameter(Mandatory)]
        [object[]]$Runs,
        [int]$TimeoutSeconds = 15
    )

    $errors = [Collections.Generic.List[string]]::new()
    $liveRunIds = [Collections.Generic.List[string]]::new()
    $quiescenceUncertainRunIds = [Collections.Generic.List[string]]::new()
    $cleanupRuns = @(
        $Runs |
            Where-Object {
                -not $_.Completed -or
                $_.Quiescent -ne $true -or
                (Test-ScenarioRunTrackingJobOpen -Run $_) -or
                ($null -ne $_.PSObject.Properties['JobCensusFailed'] -and
                    [bool]$_.JobCensusFailed)
            }
    )
    if ($cleanupRuns.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Errors = @()
            LiveRunIds = @()
            QuiescenceUncertainRunIds = @()
        }
    }

    foreach ($run in $cleanupRuns) {
        try {
            Update-ScenarioProcessTrees -Runs @($run)
        }
        catch {
            $errors.Add(
                "$($run.RunId): final tracking-job/process-tree census failed: $($_.Exception.Message)")
            if (-not $quiescenceUncertainRunIds.Contains([string]$run.RunId)) {
                $quiescenceUncertainRunIds.Add([string]$run.RunId)
            }
        }
    }
    foreach ($run in $cleanupRuns) {
        $wasCompleted = [bool]$run.Completed
        $runId = [string]$run.RunId
        $censusFailureProperty = $run.PSObject.Properties['JobCensusFailed']
        if ($null -ne $censusFailureProperty -and
            [bool]$censusFailureProperty.Value) {
            if ($null -ne $run.PSObject.Properties['JobCensusErrors']) {
                foreach ($message in @($run.JobCensusErrors)) {
                    $qualified = "${runId}: $message"
                    if (-not $errors.Contains($qualified)) {
                        $errors.Add($qualified)
                    }
                }
            }
            if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                $quiescenceUncertainRunIds.Add($runId)
            }
        }
        if ($wasCompleted -and $run.Quiescent -ne $true) {
            $errors.Add("${runId}: root completed without proven redirected-stream/descendant quiescence.")
            if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                $quiescenceUncertainRunIds.Add($runId)
            }
        }

        $jobRequiredProperty =
            $run.PSObject.Properties['TrackingJobRequired']
        $jobRequired =
            $null -ne $jobRequiredProperty -and
            [bool]$jobRequiredProperty.Value
        $jobClosedProperty = $run.PSObject.Properties['TrackingJobClosed']
        $jobWasClosed =
            $null -ne $jobClosedProperty -and
            [bool]$jobClosedProperty.Value
        $jobOpen = Test-ScenarioRunTrackingJobOpen -Run $run
        if ($jobRequired -and -not $jobOpen -and -not $jobWasClosed) {
            $errors.Add("${runId}: dedicated tracking job is missing before terminal cleanup.")
            if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                $quiescenceUncertainRunIds.Add($runId)
            }
        }

        if ($jobOpen) {
            try {
                Stop-ScenarioTrackingJob -Job $run.TrackingJob
            }
            catch {
                $errors.Add(
                    "${runId}: exact tracking-job termination failed: $($_.Exception.Message)")
                if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                    $quiescenceUncertainRunIds.Add($runId)
                }
            }
            $jobDrainTimer = [Diagnostics.Stopwatch]::StartNew()
            $remainingJobMembers = @()
            do {
                try {
                    $remainingJobMembers =
                        @(Get-ScenarioRunJobProcessIds -Run $run)
                }
                catch {
                    $errors.Add(
                        "${runId}: post-termination tracking-job membership query failed: $($_.Exception.Message)")
                    if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                        $quiescenceUncertainRunIds.Add($runId)
                    }
                    break
                }
                if ($remainingJobMembers.Count -eq 0 -or
                    $jobDrainTimer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    break
                }
                Start-Sleep -Milliseconds 100
            } while ($true)
            if ($remainingJobMembers.Count -gt 0) {
                $errors.Add(
                    "${runId}: tracking job retained PIDs $($remainingJobMembers -join ', ') after termination.")
                if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                    $quiescenceUncertainRunIds.Add($runId)
                }
            }
        }
        elseif (-not $jobRequired) {
            $stop = Stop-VerifiedProcessTree `
                -RootProcessId $run.RootProcessId `
                -RootProcessStartUtc $run.ProcessStartUtc `
                -DescendantIdentities @($run.DescendantIdentities) `
                -TimeoutSeconds $TimeoutSeconds
            foreach ($message in $stop.Errors) {
                $errors.Add("${runId}: $message")
                if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                    $quiescenceUncertainRunIds.Add($runId)
                }
            }
        }
        if (-not $wasCompleted) {
            try {
                if (-not $run.Process.HasExited) {
                    [void]$run.Process.WaitForExit($TimeoutSeconds * 1000)
                }
                if ($run.Process.HasExited) {
                    [void](Complete-ExitedScenarioBuild `
                        -Run $run `
                        -QuiescenceTimeoutSeconds $TimeoutSeconds)
                    if (-not $run.Quiescent) {
                        $errors.Add("${runId}: redirected streams or captured job members did not quiesce.")
                        if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                            $quiescenceUncertainRunIds.Add($runId)
                        }
                    }
                }
                else {
                    $errors.Add("${runId}: root remained live after tracking-job termination.")
                    if (-not $liveRunIds.Contains($runId)) {
                        $liveRunIds.Add($runId)
                    }
                }
            }
            catch {
                $errors.Add("${runId}: process completion failed: $($_.Exception.Message)")
                if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                    $quiescenceUncertainRunIds.Add($runId)
                }
                if (-not $run.Completed) {
                    $run.Process.Dispose()
                }
            }
        }

        if (Test-ScenarioRunTrackingJobOpen -Run $run) {
            try {
                $remainingBeforeClose =
                    @(Get-ScenarioRunJobProcessIds -Run $run)
                if ($remainingBeforeClose.Count -gt 0) {
                    $errors.Add(
                        "${runId}: closing tracking job with undrained PIDs $($remainingBeforeClose -join ', ').")
                    if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                        $quiescenceUncertainRunIds.Add($runId)
                    }
                }
            }
            catch {
                $errors.Add(
                    "${runId}: final tracking-job drain query failed: $($_.Exception.Message)")
                if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                    $quiescenceUncertainRunIds.Add($runId)
                }
            }
            finally {
                try {
                    Close-ScenarioRunTrackingJob -Run $run
                }
                catch {
                    $errors.Add(
                        "${runId}: tracking-job handle close failed: $($_.Exception.Message)")
                    if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                        $quiescenceUncertainRunIds.Add($runId)
                    }
                }
            }
        }

        if (-not $run.Completed) {
            try {
                if (-not $run.Process.HasExited) {
                    [void]$run.Process.WaitForExit($TimeoutSeconds * 1000)
                }
                if ($run.Process.HasExited) {
                    [void](Complete-ExitedScenarioBuild `
                        -Run $run `
                        -QuiescenceTimeoutSeconds $TimeoutSeconds)
                }
                else {
                    $run.Process.Dispose()
                }
            }
            catch {
                $errors.Add(
                    "${runId}: post-close process completion failed: $($_.Exception.Message)")
                if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                    $quiescenceUncertainRunIds.Add($runId)
                }
                if (-not $run.Completed) {
                    $run.Process.Dispose()
                }
            }
        }

        $capturedIdentities =
            [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$capturedIdentities.Add(
            "$($run.RootProcessId)|$((ConvertTo-UtcDateTimeOffset -Value $run.ProcessStartUtc).ToString('O'))")
        foreach ($propertyName in @(
            'JobMemberIdentities',
            'DescendantIdentities',
            'CoordinatorIdentities'
        )) {
            $property = $run.PSObject.Properties[$propertyName]
            if ($null -ne $property) {
                foreach ($identity in @($property.Value)) {
                    [void]$capturedIdentities.Add([string]$identity)
                }
            }
        }
        $identityTimer = [Diagnostics.Stopwatch]::StartNew()
        $liveIdentities = @()
        $queryFailures = @()
        do {
            $statuses = @(
                foreach ($identity in $capturedIdentities) {
                    $parts = [string]$identity -split '\|', 2
                    if ($parts.Count -ne 2 -or
                        [string]::IsNullOrWhiteSpace($parts[1])) {
                        [pscustomobject]@{
                            Status = 'QueryFailed'
                            Error = "Captured identity '$identity' is incomplete."
                            Identity = $identity
                        }
                        continue
                    }
                    try {
                        $status = Get-VerifiedProcessIdentityStatus `
                            -ProcessId ([int]$parts[0]) `
                            -ProcessStartUtc $parts[1]
                        $status | Add-Member `
                            -NotePropertyName Identity `
                            -NotePropertyValue $identity `
                            -Force
                        $status
                    }
                    catch {
                        [pscustomobject]@{
                            Status = 'QueryFailed'
                            Error = $_.Exception.ToString()
                            Identity = $identity
                        }
                    }
                }
            )
            $liveIdentities = @($statuses | Where-Object Status -eq 'Live')
            $queryFailures =
                @($statuses | Where-Object Status -eq 'QueryFailed')
            if (($liveIdentities.Count -eq 0 -and
                $queryFailures.Count -eq 0) -or
                $identityTimer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                break
            }
            Start-Sleep -Milliseconds 100
        } while ($true)
        foreach ($failure in $queryFailures) {
            $errors.Add(
                "${runId}: captured member verification failed for '$($failure.Identity)': $($failure.Error)")
            if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                $quiescenceUncertainRunIds.Add($runId)
            }
        }
        if ($liveIdentities.Count -gt 0) {
            if (-not $liveRunIds.Contains($runId)) {
                $liveRunIds.Add($runId)
            }
            if (-not $quiescenceUncertainRunIds.Contains($runId)) {
                $quiescenceUncertainRunIds.Add($runId)
            }
            $errors.Add(
                "${runId}: captured job members remained live after exact job cleanup: $(@($liveIdentities.Identity) -join ', ').")
        }
    }

    [pscustomobject][ordered]@{
        Succeeded =
            $errors.Count -eq 0 -and
            $liveRunIds.Count -eq 0 -and
            $quiescenceUncertainRunIds.Count -eq 0
        Errors = $errors.ToArray()
        LiveRunIds = $liveRunIds.ToArray()
        QuiescenceUncertainRunIds = $quiescenceUncertainRunIds.ToArray()
    }
}

function Write-ScenarioCleanupTerminalOutcome {
    param(
        [Parameter(Mandatory)]
        [string]$ScenarioRoot,

        [Parameter(Mandatory)]
        [pscustomobject]$Cleanup
    )

    if ($Cleanup.Succeeded) {
        return $null
    }
    $liveRunIds = @(
        if ($null -ne $Cleanup.PSObject.Properties['LiveRunIds']) {
            $Cleanup.LiveRunIds
        }
    )
    $uncertainRunIds = @(
        if ($null -ne $Cleanup.PSObject.Properties['QuiescenceUncertainRunIds']) {
            $Cleanup.QuiescenceUncertainRunIds
        }
    )
    $terminalErrors = [Collections.Generic.List[string]]::new()
    foreach ($message in @($Cleanup.Errors)) {
        $terminalErrors.Add([string]$message)
    }
    if ($liveRunIds.Count -gt 0) {
        $terminalErrors.Add(
            "Build process identities remained live after cleanup: $($liveRunIds -join ', ').")
    }
    if ($uncertainRunIds.Count -gt 0) {
        $terminalErrors.Add(
            "Build quiescence could not be established without forced or uncertain cleanup: $($uncertainRunIds -join ', ').")
    }
    if ($terminalErrors.Count -eq 0) {
        $terminalErrors.Add('Scenario build cleanup failed without proving process quiescence.')
    }

    Write-ScenarioTerminalOutcome `
        -ScenarioRoot $ScenarioRoot `
        -OutcomeType $(if ($liveRunIds.Count -gt 0) {
            'LiveBuildCleanupFailure'
        }
        else {
            'BuildQuiescenceFailure'
        }) `
        -Disposition 'NonRetryableHarnessFailure' `
        -Errors $terminalErrors.ToArray()
}

function Wait-ScenarioBuilds {
    param(
        [Parameter(Mandatory)]
        [object[]]$Runs,

        [int]$TimeoutMinutes = 10
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastProcessTreeSampleUtc = [DateTimeOffset]::MinValue
    while (@($Runs | Where-Object { -not $_.Completed }).Count -gt 0) {
        if (([DateTimeOffset]::UtcNow - $lastProcessTreeSampleUtc).TotalSeconds -ge 5) {
            Update-ScenarioProcessTrees -Runs $Runs
            $lastProcessTreeSampleUtc = [DateTimeOffset]::UtcNow
        }
        foreach ($run in @($Runs | Where-Object { -not $_.Completed })) {
            [void](Complete-ExitedScenarioBuild -Run $run)
        }
        if ($timer.Elapsed.TotalMinutes -gt $TimeoutMinutes) {
            throw "Timed out draining scenario builds after $TimeoutMinutes minutes."
        }
        Start-Sleep -Milliseconds 100
    }
}

function Get-ScenarioResourceMetrics {
    param(
        [Parameter(Mandatory)]
        [string]$MonitorRoot,

        [Parameter(Mandatory)]
        [object[]]$RunRecords,

        [DateTimeOffset]$WindowStartUtc,

        [DateTimeOffset]$WindowEndUtc
    )

    $systemRows = @(Import-Csv -LiteralPath (Join-Path $MonitorRoot 'system.csv'))
    if ($PSBoundParameters.ContainsKey('WindowStartUtc')) {
        $systemRows = @(
            $systemRows |
                Where-Object {
                    $timestamp = ConvertTo-UtcDateTimeOffset -Value $_.timestampUtc
                    $timestamp -ge $WindowStartUtc.ToUniversalTime() -and
                        $timestamp -le $WindowEndUtc.ToUniversalTime()
                }
        )
    }
    $processRows = @(Import-Csv -LiteralPath (Join-Path $MonitorRoot 'processes.csv'))
    $rootWindows = @(
        foreach ($run in $RunRecords) {
            [pscustomobject]@{
                ProcessId = [int]$run.RootProcessId
                StartUtc = ConvertTo-UtcDateTimeOffset -Value $run.ProcessStartUtc
                ExitUtc = if ([string]::IsNullOrWhiteSpace([string]$run.ProcessExitUtc)) {
                    [DateTimeOffset]::MaxValue
                }
                else {
                    ConvertTo-UtcDateTimeOffset -Value $run.ProcessExitUtc
                }
            }
        }
    )
    $peakWorkingSet = [int64]0
    $peakPrivate = [int64]0
    $peakCount = 0
    $peakNoiseWorkingSet = [int64]0
    $cpuByIdentity = @{}
    $noiseCpuByIdentity = @{}
    $foreignConflictingIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($snapshot in $processRows | Group-Object timestampUtc) {
        $timestamp = ConvertTo-UtcDateTimeOffset -Value $snapshot.Name
        if ($PSBoundParameters.ContainsKey('WindowStartUtc') -and
            ($timestamp -lt $WindowStartUtc.ToUniversalTime() -or $timestamp -gt $WindowEndUtc.ToUniversalTime())) {
            continue
        }
        $byPid = @{}
        foreach ($row in $snapshot.Group) {
            $byPid[[int]$row.processId] = $row
            if (Test-MSBuildCoordinatorProcess `
                -Name ([string]$row.name) `
                -CommandLine ([string]$row.commandLine)) {
                [void](Register-ProcessIdentity `
                    -ProcessId ([int]$row.processId) `
                    -ProcessStartUtc ([string]$row.processStartUtc) `
                    -Kind 'scenario-coordinator' `
                    -Source $MonitorRoot `
                    -IdentityCaptureError $(if ([string]::IsNullOrWhiteSpace(
                        [string]$row.processStartUtc)) {
                        'Process telemetry did not provide the Coordinator start identity.'
                    }
                    else {
                        $null
                    }))
            }
        }
        $descendantIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($row in $snapshot.Group) {
            $candidate = [int]$row.processId
            if (Test-MSBuildCoordinatorProcess `
                -Name ([string]$row.name) `
                -CommandLine ([string]$row.commandLine)) {
                continue
            }
            $visited = [Collections.Generic.HashSet[int]]::new()
            while ($visited.Add($candidate)) {
                $root = $rootWindows |
                    Where-Object {
                        $_.ProcessId -eq $candidate -and
                            $timestamp -ge $_.StartUtc.AddSeconds(-2) -and
                            $timestamp -le $_.ExitUtc.AddSeconds(2)
                    } |
                    Select-Object -First 1
                if ($null -ne $root) {
                    [void]$descendantIds.Add([int]$row.processId)
                    break
                }
                if (-not $byPid.ContainsKey($candidate)) {
                    break
                }
                $entry = $byPid[$candidate]
                $candidate = [int]$entry.parentProcessId
            }
        }
        $workingSet = [int64]0
        $private = [int64]0
        foreach ($row in $snapshot.Group) {
            $processIdValue = [int]$row.processId
            $identity = "$processIdValue|$($row.processStartUtc)"
            if ($descendantIds.Contains($processIdValue)) {
                $workingSet += [int64]$row.workingSetBytes
                $private += [int64]$row.privateBytes
                $cpu = [double]$row.cpuSeconds
                if (-not $cpuByIdentity.ContainsKey($identity)) {
                    $cpuByIdentity[$identity] = [pscustomobject]@{ Minimum = $cpu; Maximum = $cpu }
                }
                else {
                    $cpuByIdentity[$identity].Minimum = [Math]::Min($cpuByIdentity[$identity].Minimum, $cpu)
                    $cpuByIdentity[$identity].Maximum = [Math]::Max($cpuByIdentity[$identity].Maximum, $cpu)
                }
            }
            elseif ($row.name -in @('MSBuild.exe', 'csc.exe', 'vbc.exe', 'VBCSCompiler.exe') -or
                ($row.name -eq 'dotnet.exe' -and $row.commandLine -match 'MSBuild\.dll')) {
                [void]$foreignConflictingIdentities.Add($identity)
            }
            if ($row.category -eq 'external-noise-known') {
                $noiseCpu = [double]$row.cpuSeconds
                if (-not $noiseCpuByIdentity.ContainsKey($identity)) {
                    $noiseCpuByIdentity[$identity] = [pscustomobject]@{ Minimum = $noiseCpu; Maximum = $noiseCpu }
                }
                else {
                    $noiseCpuByIdentity[$identity].Minimum = [Math]::Min($noiseCpuByIdentity[$identity].Minimum, $noiseCpu)
                    $noiseCpuByIdentity[$identity].Maximum = [Math]::Max($noiseCpuByIdentity[$identity].Maximum, $noiseCpu)
                }
            }
        }
        $noiseWorkingSet = [int64](
            $snapshot.Group |
                Where-Object category -eq 'external-noise-known' |
                Measure-Object workingSetBytes -Sum
        ).Sum
        $peakWorkingSet = [Math]::Max($peakWorkingSet, $workingSet)
        $peakPrivate = [Math]::Max($peakPrivate, $private)
        $peakCount = [Math]::Max($peakCount, $descendantIds.Count)
        $peakNoiseWorkingSet = [Math]::Max($peakNoiseWorkingSet, $noiseWorkingSet)
    }
    $descendantCpu = 0.0
    foreach ($range in $cpuByIdentity.Values) {
        $descendantCpu += $range.Maximum - $range.Minimum
    }
    $noiseCpu = 0.0
    foreach ($range in $noiseCpuByIdentity.Values) {
        $noiseCpu += $range.Maximum - $range.Minimum
    }
    $averageCpu = if ($systemRows.Count -eq 0) {
        $null
    }
    else {
        ($systemRows | Measure-Object cpuPercent -Average).Average
    }
    [pscustomobject][ordered]@{
        SystemSampleCount = $systemRows.Count
        AverageSystemCpuPercent = $averageCpu
        PeakCommittedBytes = if ($systemRows.Count -eq 0) { $null } else { ($systemRows | Measure-Object committedBytes -Maximum).Maximum }
        MinimumAvailableMB = if ($systemRows.Count -eq 0) { $null } else { ($systemRows | Measure-Object availableMB -Minimum).Minimum }
        PeakProcessorQueueLength = if ($systemRows.Count -eq 0) { $null } else { ($systemRows | Measure-Object processorQueueLength -Maximum).Maximum }
        PeakDescendantWorkingSetBytes = $peakWorkingSet
        PeakDescendantPrivateBytes = $peakPrivate
        PeakDescendantProcessCount = $peakCount
        DescendantCpuSeconds = $descendantCpu
        KnownExternalNoiseCpuSeconds = $noiseCpu
        PeakKnownExternalNoiseWorkingSetBytes = $peakNoiseWorkingSet
        ForeignConflictingProcessCount = $foreignConflictingIdentities.Count
        ForeignConflictingProcessIdentities = @($foreignConflictingIdentities)
    }
}

function Get-GrantMetricsForRun {
    param(
        [Parameter(Mandatory)]
        [object]$Run,

        [Parameter(Mandatory)]
        [object]$Replay,

        [Parameter(Mandatory)]
        [object]$TraceState
    )

    $grants = @($Replay.Grants)
    $waits = @($Replay.Waits)
    $traceGrant = ConvertTo-UtcDateTimeOffset -Value $TraceState.GrantedUtc
    $start = ConvertTo-UtcDateTimeOffset -Value $Run.ProcessStartUtc
    $exit = ConvertTo-UtcDateTimeOffset -Value $Run.ProcessExitUtc
    $grant = if ($grants.Count -eq 1) { $grants[0] } else { $null }
    $grantUtc = if ($null -eq $grant) { $null } else { ConvertTo-UtcDateTimeOffset -Value $grant.TimestampUtc }
    $waitStarted = if ($waits.Count -gt 0) {
        ConvertTo-UtcDateTimeOffset -Value $waits[0].TimestampUtc
    }
    elseif ($null -ne $TraceState.QueuedUtc) {
        ConvertTo-UtcDateTimeOffset -Value $TraceState.QueuedUtc
    }
    else {
        $traceGrant
    }
    [pscustomobject][ordered]@{
        RunId = $Run.RunId
        RootProcessId = [int]$Run.RootProcessId
        GrantCount = $grants.Count
        GrantedNodes = if ($null -eq $grant) { $null } else { [int]$grant.Nodes }
        GrantTimestampUtc = if ($null -eq $grantUtc) { $null } else { $grantUtc.ToString('O') }
        TraceGrantTimestampUtc = $traceGrant.ToString('O')
        TraceAndBinlogGrantDeltaSeconds = if ($null -eq $grantUtc) { $null } else { [Math]::Abs(($traceGrant - $grantUtc).TotalSeconds) }
        RequestToGrantSeconds = if ($null -eq $grantUtc) { $null } else { ($grantUtc - $start).TotalSeconds }
        QueueWaitSeconds = if ($null -eq $grantUtc) { $null } else { [Math]::Max(0, ($grantUtc - $waitStarted).TotalSeconds) }
        RequestToCompletionSeconds = ($exit - $start).TotalSeconds
        CoordinatorNegotiationSeconds = ($traceGrant - (ConvertTo-UtcDateTimeOffset -Value $TraceState.ConnectedUtc)).TotalSeconds
        BinlogErrorCount = [int]$Replay.ErrorCount
        BinlogWarningCount = [int]$Replay.WarningCount
    }
}

function Get-TraceFiles {
    param(
        [Parameter(Mandatory)]
        [string]$DebugPath
    )

    @(
        Get-ChildItem -LiteralPath $DebugPath -Filter 'MSBuild_CoordinatorTrace_PID_*.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            Select-Object -ExpandProperty FullName
    )
}

function Get-StateAtTimestamp {
    param(
        [Parameter(Mandatory)]
        [object[]]$Timeline,

        [Parameter(Mandatory)]
        [DateTimeOffset]$TimestampUtc
    )

    $state = [pscustomobject]@{ QueueDepth = 0; ActiveBuilds = 0; AllocatedNodes = 0 }
    foreach ($row in $Timeline | Sort-Object { ConvertTo-UtcDateTimeOffset -Value $_.TimestampUtc }, Sequence) {
        if ((ConvertTo-UtcDateTimeOffset -Value $row.TimestampUtc) -gt $TimestampUtc.ToUniversalTime()) {
            break
        }
        $state = $row
    }
    return $state
}
