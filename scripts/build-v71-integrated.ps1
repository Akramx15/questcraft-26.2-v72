#requires -Version 7.0
<#
.SYNOPSIS
Builds the exact integrated QuestCraft Vivecraft v71 Lab or Personal APK.

.DESCRIPTION
SelfTest is read-only and is the default. Build requires -AllowBuild, and a
Personal build additionally requires -AllowStablePromotion. One Git-common
lock and a persisted transaction journal protect Lab and Stable builds across
worktrees. Child processes live in a kill-on-close Windows Job Object. The
script pins every identity and payload hash, builds Pojlib twice, restores the
checked-in inputs, verifies the resulting APK and never controls a device.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Lab', 'Stable')]
    [string] $Target,

    [ValidateSet('SelfTest', 'Build', 'RecoverInterruptedBuild', 'RestoreSourceAar')]
    [string] $Action = 'SelfTest',

    [string] $UnityEditor = (Join-Path $env:USERPROFILE `
        'Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe'),

    [switch] $AllowBuild,
    [switch] $AllowStablePromotion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $repo 'QCXR-XR-Wrapper'
$pojlib = Join-Path $repo 'Pojlib'
$pluginAar = Join-Path $wrapper 'Assets\Plugins\Android\Pojlib-release.aar'
$builtAar = Join-Path $pojlib 'build\outputs\aar\Pojlib-release.aar'
$coreAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-26.2-1.3.15-quest.bin'
$veqAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-essentials-quest.bin'
$verifyScript = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$rc4LockPath = Join-Path $repo 'V71_LAB_RC4.lock.json'
$stableAcceptancePath = Join-Path $repo 'V71_STABLE_RC4_ACCEPTANCE.lock.json'
$stableEvidenceGateScript = Join-Path $PSScriptRoot 'v71-rc4-stable-evidence-gate.ps1'
$memorySoakScript = Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc4.ps1'
$memoryRuntimeContractScript = Join-Path $PSScriptRoot `
    'quest-v71-memory-runtime-contract-rc4.ps1'
$performanceHarnessScript = Join-Path $PSScriptRoot 'quest-v71-rc3-rc4-ab.ps1'
$lifecycleRecoveryScript = Join-Path $PSScriptRoot `
    'quest-v71-lab-lifecycle-recovery-rc4.ps1'
$stableInstallScript = Join-Path $PSScriptRoot 'quest-v71-rc4-stable-install.ps1'
$autoplayHarnessScript = Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $repo)
$expectedCoreHash = '289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189'
$expectedCoreVersion = '26.2-1.3.15+qc.v71.rc4'
$expectedVeqHash = '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
$expectedVeqVersion = '0.7.0-v70-canary.1'
$expectedLwjglHash = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
$expectedSignerHash = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$expectedPairHash = '9D2C0830A34963FF3D5F336B465A6B8D11C153E82A738D0528E8D1821F25A8B1'
$expectedUnityJavaVersion = '11.0.14.1'
$expectedUnityJavaRuntimeMarker = 'Temurin-11.0.14.1+1'
$expectedPojlibJavaLockIdentity = 'Unity bundled Temurin 11.0.14.1+1'
$expectedD8BuilderHash = '346CA459BD3B4B3A1148F6C8AD31B69049E84F269132EDDD6D28E2D513DD360E'
$expectedD8Version = '4.0.52'
$script:Rc4Lock = $null
$script:StableEvidenceContract = $null

$identity = if ($Target -ceq 'Lab') {
    [ordered]@{
        Package = 'com.qcxr.qcxr.canary262'
        ForbiddenPackage = 'com.qcxr.qcxr.dev262'
        Label = 'QuestCraft Vivecraft Lab 26.2'
        VersionCode = '71'
        VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.4'
        Output = 'Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.4-integrated-local.apk'
        Builder = 'QuestCraftV71LabCliBuild.BuildAndroid'
        BuilderFile = 'Assets\Editor\QuestCraftV71LabCliBuild.cs'
    }
} else {
    [ordered]@{
        Package = 'com.qcxr.qcxr.dev262'
        ForbiddenPackage = 'com.qcxr.qcxr.canary262'
        Label = 'Vivecraft Stable'
        VersionCode = '71'
        VersionName = '6.0.1-26.2-vivecraft-personal.12'
        Output = 'Builds/QuestCraft-Vivecraft-26.2-personal.12-local.apk'
        Builder = 'QuestCraftPersonalV71CliBuild.BuildAndroid'
        BuilderFile = 'Assets\Editor\QuestCraftPersonalV71CliBuild.cs'
    }
}

$outputApk = Join-Path $wrapper $identity.Output
$backupDirectory = Join-Path $repo '.v71-integrated-build-backup'
$backupAar = Join-Path $backupDirectory 'Pojlib-release.aar'
$backupHashFile = Join-Path $backupDirectory 'Pojlib-release.aar.sha256'
$reproAar = Join-Path $backupDirectory 'Pojlib-release.first-build.aar'
$projectSettings = Join-Path $wrapper 'ProjectSettings\ProjectSettings.asset'
$backupProjectSettings = Join-Path $backupDirectory 'ProjectSettings.asset'
$backupProjectSettingsHashFile = Join-Path $backupDirectory 'ProjectSettings.asset.sha256'
$previousOutputApk = Join-Path $backupDirectory 'previous-output.apk'
$transactionJournal = Join-Path $backupDirectory 'transaction.json'
$legacyBackupDirectories = @(
    (Join-Path $repo '.v71-lab-build-backup'),
    (Join-Path $repo '.v71-stable-build-backup')
)
$globalBuildLockStream = $null

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-JavaIdentity {
    param([Parameter(Mandatory)][string] $JavaExecutable)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $JavaExecutable
    $startInfo.ArgumentList.Add('-version')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Require ($process.Start()) "Could not inspect Java: $JavaExecutable"
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Require ($process.ExitCode -eq 0) `
            "Java version inspection failed: $JavaExecutable"
        return ($stdout + [Environment]::NewLine + $stderr).Trim()
    } finally { $process.Dispose() }
}

function Resolve-UnityJavaToolchain {
    param([Parameter(Mandatory)][string] $JavaHome)
    Require (Test-Path -LiteralPath $JavaHome -PathType Container) `
        'Unity Android OpenJDK is missing.'
    $javaHomePath = Get-CanonicalPath $JavaHome
    $java = Join-Path $javaHomePath 'bin\java.exe'
    $javac = Join-Path $javaHomePath 'bin\javac.exe'
    Require (Test-Path -LiteralPath $java -PathType Leaf) `
        'Unity Android Java runtime is missing.'
    Require (Test-Path -LiteralPath $javac -PathType Leaf) `
        'Unity Android Java compiler is missing.'
    $identityText = Get-JavaIdentity $java
    Require ($identityText -match
            ('openjdk version "' + [regex]::Escape($expectedUnityJavaVersion) + '"') -and
            $identityText -match [regex]::Escape($expectedUnityJavaRuntimeMarker)) `
        'Pojlib and Unity require the exact bundled Temurin 11.0.14.1+1 runtime.'
    [pscustomobject]@{
        Home = $javaHomePath
        JavaExecutable = $java
        JavacExecutable = $javac
        Version = $expectedUnityJavaVersion
        Runtime = $expectedPojlibJavaLockIdentity
        Identity = ($identityText -replace "`r?`n", ' | ')
    }
}

function Resolve-PinnedD8Builder {
    param([Parameter(Mandatory)][string] $JavaExecutable)
    $gradleHome = if (-not [string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) {
        Get-CanonicalPath $env:GRADLE_USER_HOME
    } else {
        Get-CanonicalPath (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gradle')
    }
    $builderRoot = Join-Path $gradleHome `
        'caches\modules-2\files-2.1\com.android.tools.build\builder\7.4.2'
    Require (Test-Path -LiteralPath $builderRoot -PathType Container) `
        'The exact AGP 7.4.2 builder cache required for the D8 preflight is missing.'
    $candidates = @(Get-ChildItem -LiteralPath $builderRoot `
        -Filter 'builder-7.4.2.jar' -File -Recurse -ErrorAction Stop)
    Require ($candidates.Count -eq 1) `
        'The exact AGP 7.4.2 D8 preflight requires one unambiguous builder JAR.'
    $builder = Get-CanonicalPath $candidates[0].FullName
    Require ((Get-Sha256 $builder) -ceq $expectedD8BuilderHash) `
        'The AGP builder JAR does not match the pinned D8 4.0.52 artifact.'

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $JavaExecutable
    foreach ($argument in @('-cp', $builder, 'com.android.tools.r8.D8', '--version')) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Require ($process.Start()) 'Could not inspect the pinned D8 runtime.'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Require ($process.ExitCode -eq 0) 'Pinned D8 version inspection failed.'
        $identityText = ($stdout + [Environment]::NewLine + $stderr).Trim()
        Require ($identityText -match
                ('(?m)^D8 ' + [regex]::Escape($expectedD8Version) + '\b')) `
            'The AGP builder did not expose the expected D8 4.0.52 runtime.'
    } finally { $process.Dispose() }
    [pscustomobject]@{
        Path = $builder
        Sha256 = $expectedD8BuilderHash
        Version = $expectedD8Version
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-NormalizedTextSha256 {
    param([Parameter(Mandatory)][string] $Path)
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) |
            ForEach-Object ToString x2) -join '').ToUpperInvariant()
    } finally { $sha.Dispose() }
}

function Enter-ScriptReadLock {
    param([Parameter(Mandatory)][string] $Path)
    Require (Test-Path -LiteralPath $Path -PathType Leaf) `
        "Script read-lock target is missing: $Path"
    $item = Get-Item -LiteralPath $Path -Force
    Require (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        "Script read-lock target must not be a reparse point: $Path"
    [IO.File]::Open($item.FullName, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string] $Path)
    [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Enter-GlobalBuildLock {
    $gitCommon = (& git -C $repo rev-parse --git-common-dir 2>$null)
    Require ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitCommon)) `
        'Could not resolve the shared Git directory for the v71 build lock.'
    if (-not [IO.Path]::IsPathRooted($gitCommon)) {
        $gitCommon = Join-Path $repo $gitCommon
    }
    $canonicalCommon = Get-CanonicalPath $gitCommon
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $lockKey = (($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($canonicalCommon.ToUpperInvariant())) |
            ForEach-Object ToString x2) -join '').Substring(0, 24)
    } finally { $sha.Dispose() }
    $lockPath = Join-Path $env:TEMP ("questcraft-v71-build-$lockKey.lock")
    try {
        $stream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another v71 Lab/Stable build or recovery owns the shared build lock.'
    }
    try {
        $stream.SetLength(0)
        $writer = [IO.StreamWriter]::new(
            $stream, [Text.UTF8Encoding]::new($false), 1024, $true)
        try {
            $writer.WriteLine("pid=$PID target=$Target action=$Action")
            $writer.Flush()
            $stream.Flush($true)
        } finally { $writer.Dispose() }
        $stream.Position = 0
        $stream
    } catch {
        $stream.Dispose()
        throw
    }
}

if (-not ('QuestCraftV71BuildJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public sealed class QuestCraftV71BuildProcess : IDisposable
{
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const uint INFINITE = 0xFFFFFFFF;
    private IntPtr process;
    private bool exitCodeCaptured;
    private int exitCode;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    internal QuestCraftV71BuildProcess(IntPtr process, uint processId)
    {
        if (process == IntPtr.Zero) throw new ArgumentException("Invalid process handle.", nameof(process));
        this.process = process;
        Id = checked((int)processId);
    }

    public int Id { get; }

    public int ExitCode
    {
        get
        {
            EnsureNotDisposed();
            if (!exitCodeCaptured)
            {
                uint waitResult = WaitForSingleObject(process, 0);
                if (waitResult == WAIT_TIMEOUT)
                    throw new InvalidOperationException("The process has not exited.");
                if (waitResult == WAIT_FAILED)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed.");
                if (waitResult != WAIT_OBJECT_0)
                    throw new InvalidOperationException("WaitForSingleObject returned an unexpected result.");
                CaptureExitCode();
            }
            return exitCode;
        }
    }

    public void WaitForExit()
    {
        WaitForExitCore(INFINITE);
    }

    public bool WaitForExit(int milliseconds)
    {
        if (milliseconds < -1) throw new ArgumentOutOfRangeException(nameof(milliseconds));
        return WaitForExitCore(milliseconds == -1 ? INFINITE : checked((uint)milliseconds));
    }

    private bool WaitForExitCore(uint milliseconds)
    {
        EnsureNotDisposed();
        uint waitResult = WaitForSingleObject(process, milliseconds);
        if (waitResult == WAIT_TIMEOUT) return false;
        if (waitResult == WAIT_FAILED)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed.");
        if (waitResult != WAIT_OBJECT_0)
            throw new InvalidOperationException("WaitForSingleObject returned an unexpected result.");
        CaptureExitCode();
        return true;
    }

    private void CaptureExitCode()
    {
        if (exitCodeCaptured) return;
        uint nativeExitCode;
        if (!GetExitCodeProcess(process, out nativeExitCode))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed.");
        exitCode = unchecked((int)nativeExitCode);
        exitCodeCaptured = true;
    }

    private void EnsureNotDisposed()
    {
        if (process == IntPtr.Zero)
            throw new ObjectDisposedException(nameof(QuestCraftV71BuildProcess));
    }

    public void Dispose()
    {
        if (process == IntPtr.Zero) return;
        CloseHandle(process);
        process = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }

    ~QuestCraftV71BuildProcess() { Dispose(); }
}

public sealed class QuestCraftV71BuildJob : IDisposable
{
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const int JobObjectExtendedLimitInformation = 9;
    private IntPtr job;

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFO
    {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
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
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int infoClass,
        IntPtr info,
        uint infoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public QuestCraftV71BuildJob()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            throw new PlatformNotSupportedException("The v71 build transaction requires Windows.");
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                    buffer, checked((uint)size)))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "SetInformationJobObject failed.");
        }
        catch
        {
            CloseHandle(job);
            job = IntPtr.Zero;
            throw;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public QuestCraftV71BuildProcess Start(
        string executable,
        string[] arguments,
        string workingDirectory)
    {
        if (job == IntPtr.Zero) throw new ObjectDisposedException(nameof(QuestCraftV71BuildJob));
        var commandLine = new StringBuilder(Quote(executable));
        foreach (string argument in arguments)
            commandLine.Append(' ').Append(Quote(argument ?? String.Empty));
        var startup = new STARTUPINFO { cb = checked((uint)Marshal.SizeOf<STARTUPINFO>()) };
        PROCESS_INFORMATION info;
        if (!CreateProcessW(executable, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                CREATE_SUSPENDED, IntPtr.Zero, workingDirectory, ref startup, out info))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess failed.");
        bool processHandleTransferred = false;
        try
        {
            if (!AssignProcessToJobObject(job, info.hProcess))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "AssignProcessToJobObject failed.");
            if (ResumeThread(info.hThread) == UInt32.MaxValue)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread failed.");
            }
            var process = new QuestCraftV71BuildProcess(info.hProcess, info.dwProcessId);
            processHandleTransferred = true;
            return process;
        }
        catch
        {
            TerminateProcess(info.hProcess, 1);
            throw;
        }
        finally
        {
            CloseHandle(info.hThread);
            if (!processHandleTransferred) CloseHandle(info.hProcess);
        }
    }

    private static string Quote(string value)
    {
        if (value.Length == 0) return "\"\"";
        if (value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '\"' }) < 0) return value;
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '\"')
            {
                result.Append('\\', slashes * 2 + 1).Append(c);
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('\"');
        return result.ToString();
    }

    public void Dispose()
    {
        if (job == IntPtr.Zero) return;
        CloseHandle(job);
        job = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }

    ~QuestCraftV71BuildJob() { Dispose(); }
}
'@
}

function Write-TransactionJournal {
    param([Parameter(Mandatory)] $State)
    $temporary = $transactionJournal + '.next'
    $json = $State | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $transactionJournal, $true)
}

function Read-TransactionJournal {
    $temporary = $transactionJournal + '.next'
    if (-not (Test-Path -LiteralPath $transactionJournal -PathType Leaf) -and
            (Test-Path -LiteralPath $temporary -PathType Leaf)) {
        # A fully written .next file is the recoverable side of the atomic journal swap.
        $candidate = Get-Content -Raw -LiteralPath $temporary | ConvertFrom-Json
        Require ([int]$candidate.schemaVersion -eq 1) `
            'The pending interrupted v71 transaction journal is invalid.'
        [IO.File]::Move($temporary, $transactionJournal, $false)
    }
    Require (Test-Path -LiteralPath $transactionJournal -PathType Leaf) `
        'The interrupted v71 transaction journal is missing.'
    $journal = Get-Content -Raw -LiteralPath $transactionJournal | ConvertFrom-Json
    Require ([int]$journal.schemaVersion -eq 1) 'Unsupported v71 transaction journal schema.'
    Require ([string]$journal.repo -ceq (Get-CanonicalPath $repo)) `
        'The interrupted journal belongs to a different repository.'
    Require ([string]$journal.target -ceq $Target) `
        "The interrupted transaction belongs to $($journal.target), not $Target."
    Require ([string]$journal.outputApk -ceq (Get-CanonicalPath $outputApk)) `
        'The interrupted journal names an unexpected output APK.'
    Require ([string]$journal.sourceAar.path -ceq (Get-CanonicalPath $pluginAar) -and
            [string]$journal.projectSettings.path -ceq (Get-CanonicalPath $projectSettings)) `
        'The interrupted journal names an unexpected checked-in input.'
    foreach ($hash in @(
        [string]$journal.sourceAar.sha256,
        [string]$journal.projectSettings.sha256
    )) {
        Require ($hash -cmatch '^[0-9A-F]{64}$') `
            'The interrupted journal contains an invalid checked-in input hash.'
    }
    if ([bool]$journal.previousOutput.present) {
        Require ([string]$journal.previousOutput.sha256 -cmatch '^[0-9A-F]{64}$' -and
                [int64]$journal.previousOutput.sizeBytes -gt 0) `
            'The interrupted journal contains invalid previous-output provenance.'
    }
    $journal
}

function Restore-CheckedInInputs {
    param([Parameter(Mandatory)] $Journal)
    $errors = [Collections.Generic.List[string]]::new()
    $pairs = @(
        [pscustomobject]@{
            Name = 'Pojlib AAR'
            Live = $pluginAar
            Backup = $backupAar
            Expected = ([string]$Journal.sourceAar.sha256).ToUpperInvariant()
        },
        [pscustomobject]@{
            Name = 'Unity ProjectSettings'
            Live = $projectSettings
            Backup = $backupProjectSettings
            Expected = ([string]$Journal.projectSettings.sha256).ToUpperInvariant()
        }
    )
    foreach ($pair in $pairs) {
        try {
            if (Test-Path -LiteralPath $pair.Backup -PathType Leaf) {
                Require ((Get-Sha256 $pair.Backup) -ceq $pair.Expected) `
                    "The $($pair.Name) backup does not match its journal hash."
                [IO.File]::Copy($pair.Backup, $pair.Live, $true)
            }
            Require (Test-Path -LiteralPath $pair.Live -PathType Leaf) `
                "The $($pair.Name) live file and backup are both missing."
            Require ((Get-Sha256 $pair.Live) -ceq $pair.Expected) `
                "The exact checked-in $($pair.Name) could not be restored."
        } catch {
            $errors.Add($_.Exception.Message)
        }
    }
    if ($errors.Count -gt 0) {
        throw ('Checked-in input recovery failed: ' + ($errors -join ' | '))
    }
}

function Get-PreviousOutputArchivePath {
    param([Parameter(Mandatory)][string] $Hash)
    $outputApk + '.previous-' + $Hash.Substring(0, 12) + '.apk'
}

function Restore-PreviousOutput {
    param([Parameter(Mandatory)] $Journal)
    if (-not [bool]$Journal.previousOutput.present) {
        if (Test-Path -LiteralPath $outputApk -PathType Leaf) {
            Remove-Item -LiteralPath $outputApk -Force
        }
        Require (-not (Test-Path -LiteralPath $previousOutputApk)) `
            'A previous-output backup exists although the journal records no previous APK.'
        return
    }

    $expected = ([string]$Journal.previousOutput.sha256).ToUpperInvariant()
    $expectedSize = [int64]$Journal.previousOutput.sizeBytes
    $archive = Get-PreviousOutputArchivePath $expected
    $archiveNext = $archive + '.next'
    $source = $null
    if (Test-Path -LiteralPath $previousOutputApk -PathType Leaf) {
        $source = $previousOutputApk
    } elseif (Test-Path -LiteralPath $archive -PathType Leaf) {
        $source = $archive
    } elseif ((Test-Path -LiteralPath $outputApk -PathType Leaf) -and
            (Get-Sha256 $outputApk) -ceq $expected -and
            (Get-Item -LiteralPath $outputApk).Length -eq $expectedSize) {
        if (Test-Path -LiteralPath $archiveNext -PathType Leaf) {
            Remove-Item -LiteralPath $archiveNext -Force
        }
        return
    }
    Require ($null -ne $source) `
        'The previous APK cannot be authenticated or restored; the journal was preserved.'
    Require ((Get-Sha256 $source) -ceq $expected -and
            (Get-Item -LiteralPath $source).Length -eq $expectedSize) `
        'The previous APK backup does not match its journal provenance.'
    if (Test-Path -LiteralPath $outputApk -PathType Leaf) {
        Remove-Item -LiteralPath $outputApk -Force
    }
    [IO.File]::Copy($source, $outputApk, $true)
    Require ((Get-Sha256 $outputApk) -ceq $expected -and
            (Get-Item -LiteralPath $outputApk).Length -eq $expectedSize) `
        'The previous APK could not be restored exactly.'
    if (Test-Path -LiteralPath $archiveNext -PathType Leaf) {
        Remove-Item -LiteralPath $archiveNext -Force
    }
}

function Archive-PreviousOutput {
    param([Parameter(Mandatory)] $Journal)
    if (-not [bool]$Journal.previousOutput.present) {
        Require (-not (Test-Path -LiteralPath $previousOutputApk)) `
            'Unexpected previous-output backup for an absent pre-build APK.'
        return
    }
    $expected = ([string]$Journal.previousOutput.sha256).ToUpperInvariant()
    $expectedSize = [int64]$Journal.previousOutput.sizeBytes
    $archive = Get-PreviousOutputArchivePath $expected
    $archiveNext = $archive + '.next'
    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        Require ((Get-Sha256 $archive) -ceq $expected -and
                (Get-Item -LiteralPath $archive).Length -eq $expectedSize) `
            'A different APK occupies the locked previous-output archive path.'
        if (Test-Path -LiteralPath $previousOutputApk -PathType Leaf) {
            Require ((Get-Sha256 $previousOutputApk) -ceq $expected -and
                    (Get-Item -LiteralPath $previousOutputApk).Length -eq $expectedSize) `
                'The duplicate previous-output backup drifted before archival.'
        }
        if (Test-Path -LiteralPath $archiveNext -PathType Leaf) {
            Remove-Item -LiteralPath $archiveNext -Force
        }
    } else {
        Require (Test-Path -LiteralPath $previousOutputApk -PathType Leaf) `
            'The authenticated previous-output backup is missing during success finalization.'
        Require ((Get-Sha256 $previousOutputApk) -ceq $expected -and
                (Get-Item -LiteralPath $previousOutputApk).Length -eq $expectedSize) `
            'The previous-output backup drifted before archival.'
        if (Test-Path -LiteralPath $archiveNext -PathType Leaf) {
            Remove-Item -LiteralPath $archiveNext -Force
        }
        [IO.File]::Copy($previousOutputApk, $archiveNext, $false)
        Require ((Get-Sha256 $archiveNext) -ceq $expected -and
                (Get-Item -LiteralPath $archiveNext).Length -eq $expectedSize) `
            'The temporary previous APK archive could not be verified.'
        [IO.File]::Move($archiveNext, $archive, $false)
        Require ((Get-Sha256 $archive) -ceq $expected -and
                (Get-Item -LiteralPath $archive).Length -eq $expectedSize) `
            'The previous APK archive could not be verified after its atomic move.'
    }
}

function Remove-CompletedTransactionGuard {
    $knownPaths = @(
        $backupAar,
        $backupHashFile,
        $reproAar,
        $backupProjectSettings,
        $backupProjectSettingsHashFile,
        $previousOutputApk,
        ($transactionJournal + '.next'),
        $transactionJournal
    )
    if ([IO.Directory]::Exists($backupDirectory)) {
        $knownCanonical = @($knownPaths | ForEach-Object { Get-CanonicalPath $_ })
        $unexpected = @([IO.Directory]::GetFileSystemEntries($backupDirectory) |
            Where-Object { (Get-CanonicalPath $_) -cnotin $knownCanonical })
        Require ($unexpected.Count -eq 0) `
            'The v71 transaction guard contains unexpected files and was preserved.'
    }
    foreach ($path in $knownPaths) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if ([IO.Directory]::Exists($backupDirectory)) {
        Require ([IO.Directory]::GetFileSystemEntries($backupDirectory).Length -eq 0) `
            'The completed v71 transaction guard could not be emptied.'
        [IO.Directory]::Delete($backupDirectory)
    }
}

function Get-ZipEntrySha256 {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $EntryName
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $archive.GetEntry($EntryName)
        Require ($null -ne $entry) "Missing archive entry: $EntryName"
        $stream = $entry.Open()
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                (($sha.ComputeHash($stream) | ForEach-Object ToString x2) -join '').ToUpperInvariant()
            } finally { $sha.Dispose() }
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
}

function Assert-ManifestPair {
    $manifestPaths = @(
        'mods.json',
        'devmods.json',
        'src\main\assets\mods.json',
        'src\main\assets\devmods.json'
    )
    foreach ($relativePath in $manifestPaths) {
        $path = Join-Path $pojlib $relativePath
        Require (Test-Path -LiteralPath $path -PathType Leaf) "Missing manifest: $relativePath"
        $manifest = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $versions = @($manifest.versions | Where-Object name -ceq '26.2')
        Require ($versions.Count -eq 1) "$relativePath must contain exactly one 26.2 block."
        $mods = @($versions[0].coreMods) + @($versions[0].defaultMods)
        $core = @($mods | Where-Object slug -ceq 'Vivecraft')
        $veq = @($mods | Where-Object slug -ceq 'Vivecraft-Essentials-Quest')
        Require ($core.Count -eq 1 -and $veq.Count -eq 1) `
            "$relativePath must contain one Vivecraft and one VEQ entry."
        Require ([string]$core[0].version -ceq $expectedCoreVersion) `
            "$relativePath has the wrong Vivecraft version."
        Require ([string]$core[0].sha256 -ceq $expectedCoreHash) `
            "$relativePath has the wrong Vivecraft hash."
        Require ([string]$veq[0].version -ceq $expectedVeqVersion) `
            "$relativePath has the wrong VEQ version."
        Require ([string]$veq[0].sha256 -ceq $expectedVeqHash) `
            "$relativePath has the wrong VEQ hash."
    }
}

function Assert-AarPayload {
    param([Parameter(Mandatory)][string] $AarPath)
    Require (Test-Path -LiteralPath $AarPath -PathType Leaf) "Missing Pojlib AAR: $AarPath"
    Require ((Get-ZipEntrySha256 $AarPath 'assets/mods/vivecraft-26.2-1.3.15-quest.bin') `
            -ceq $expectedCoreHash) 'The Pojlib AAR does not embed exact RC4 Vivecraft.'
    Require ((Get-ZipEntrySha256 $AarPath 'assets/mods/vivecraft-essentials-quest.bin') `
            -ceq $expectedVeqHash) 'The Pojlib AAR does not embed frozen RC4 VEQ.'
}

function Assert-D8Compatibility {
    param(
        [Parameter(Mandatory)][string] $AarPath,
        [Parameter(Mandatory)] $JavaToolchain,
        [Parameter(Mandatory)] $BuildJob
    )
    $d8 = Resolve-PinnedD8Builder $JavaToolchain.JavaExecutable
    $tempRoot = Get-CanonicalPath (Join-Path $env:TEMP `
        ('questcraft-v71-d8-preflight-' + [guid]::NewGuid().ToString('N')))
    $canonicalTemp = Get-CanonicalPath $env:TEMP
    Require ($tempRoot.StartsWith(
            $canonicalTemp + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) `
        'Refusing an unsafe D8 preflight directory.'
    $classesJar = Join-Path $tempRoot 'classes.jar'
    $dexDirectory = Join-Path $tempRoot 'dex'
    try {
        [IO.Directory]::CreateDirectory($dexDirectory) | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($AarPath)
        try {
            $entry = $archive.GetEntry('classes.jar')
            Require ($null -ne $entry) 'The Pojlib AAR does not contain classes.jar.'
            $source = $entry.Open()
            try {
                $destination = [IO.File]::Open(
                    $classesJar, [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $source.CopyTo($destination) } finally { $destination.Dispose() }
            } finally { $source.Dispose() }
        } finally { $archive.Dispose() }

        $process = $BuildJob.Start(
            $JavaToolchain.JavaExecutable,
            @('-cp', $d8.Path, 'com.android.tools.r8.D8',
                '--release', '--min-api', '29', '--output', $dexDirectory, $classesJar),
            $tempRoot)
        try {
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        } finally { $process.Dispose() }
        Require ($exitCode -eq 0) `
            'The exact Pojlib runtime bytecode is incompatible with Unity D8 4.0.52.'
        Require (Test-Path -LiteralPath (Join-Path $dexDirectory 'classes.dex') -PathType Leaf) `
            'The D8 compatibility preflight produced no classes.dex.'
    } finally {
        if ([IO.Directory]::Exists($tempRoot)) {
            [IO.Directory]::Delete($tempRoot, $true)
        }
    }
}

function Assert-ApkLifecycleMarkers {
    param([Parameter(Mandatory)][string] $ApkPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $javaMarkers = @(
        'shouldReleaseLauncherResources',
        'QC_JVM_LAUNCH_DISPATCH_REJECTED'
    )
    $unityMarkers = @(
        'QC_OPENXR_HANDOFF_READY_TIMEOUT',
        'QC_LAUNCHER_RESOURCE_RELEASE_'
    )
    $javaFound = @{}
    $unityFound = @{}
    foreach ($marker in $javaMarkers) { $javaFound[$marker] = $false }
    foreach ($marker in $unityMarkers) { $unityFound[$marker] = $false }
    $archive = [IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $dexEntries = @($archive.Entries | Where-Object {
            $_.FullName -match '^classes(?:[0-9]+)?\.dex$'
        })
        Require ($dexEntries.Count -gt 0) 'The built APK contains no DEX payload.'
        foreach ($entry in $dexEntries) {
            $stream = $entry.Open()
            try {
                $memory = [IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($memory)
                    $text = [Text.Encoding]::ASCII.GetString($memory.ToArray())
                    foreach ($marker in $javaMarkers) {
                        if (-not $javaFound[$marker] -and $text.Contains($marker)) {
                            $javaFound[$marker] = $true
                        }
                    }
                } finally { $memory.Dispose() }
            } finally { $stream.Dispose() }
        }

        $metadata = $archive.GetEntry('assets/bin/Data/Managed/Metadata/global-metadata.dat')
        Require ($null -ne $metadata) 'The built APK contains no IL2CPP global metadata.'
        $metadataStream = $metadata.Open()
        try {
            $memory = [IO.MemoryStream]::new()
            try {
                $metadataStream.CopyTo($memory)
                $text = [Text.Encoding]::ASCII.GetString($memory.ToArray())
                foreach ($marker in $unityMarkers) {
                    if ($text.Contains($marker)) { $unityFound[$marker] = $true }
                }
            } finally { $memory.Dispose() }
        } finally { $metadataStream.Dispose() }
    } finally { $archive.Dispose() }
    foreach ($marker in $javaMarkers) {
        Require ([bool]$javaFound[$marker]) `
            "The built APK DEX payload is missing the locked v71 Java marker: $marker"
    }
    foreach ($marker in $unityMarkers) {
        Require ([bool]$unityFound[$marker]) `
            "The built APK IL2CPP metadata is missing the locked v71 Unity marker: $marker"
    }
}

function Assert-Source {
    Require (Test-Path -LiteralPath $rc4LockPath -PathType Leaf) `
        'The integrated V71_LAB_RC4.lock.json contract is missing.'
    $rc4 = Get-Content -Raw -LiteralPath $rc4LockPath | ConvertFrom-Json
    $integrationCommit = [string]$rc4.source.integrationBuildCommit
    Require ($integrationCommit -cmatch '^[0-9a-f]{40}$') `
        'The RC4 lock does not contain a canonical integration commit.'
    & git -C $repo cat-file -e ($integrationCommit + '^{commit}') 2>$null
    Require ($LASTEXITCODE -eq 0) 'The locked launcher integration commit is unavailable.'
    & git -C $repo merge-base --is-ancestor $integrationCommit HEAD
    Require ($LASTEXITCODE -eq 0) `
        'The locked launcher integration commit is not an ancestor of HEAD.'
    $criticalSourcePaths = @(
        'Pojlib',
        'QCXR-XR-Wrapper',
        'scripts/verify-dev-apk.ps1'
    )
    & git -C $repo diff --quiet $integrationCommit HEAD -- @criticalSourcePaths
    Require ($LASTEXITCODE -eq 0) `
        'Critical v71 source drifted from the reviewed launcher integration commit.'
    Require ([string]$rc4.source.scriptHashScheme -ceq 'sha256-utf8-normalized-lf') `
        'The v71 script hash scheme drifted.'
    Require ([string]$rc4.source.buildScriptSha256 -ceq
            (Get-NormalizedTextSha256 $PSCommandPath)) `
        'The v71 build script drifted from its locked SHA-256.'
    Require (Test-Path -LiteralPath $stableEvidenceGateScript -PathType Leaf) `
        'The fail-closed v71 Stable evidence validator is missing.'
    $stableGateReadLock = Enter-ScriptReadLock $stableEvidenceGateScript
    try {
        Require ([string]$rc4.source.stableEvidenceGateScriptSha256 -ceq
                (Get-NormalizedTextSha256 $stableEvidenceGateScript)) `
            'The fail-closed v71 Stable evidence validator drifted from its locked SHA-256.'
        . $stableEvidenceGateScript
    } finally { $stableGateReadLock.Dispose() }
    Require ($null -ne (Get-Command Assert-V71Rc4StableAcceptanceEvidence `
            -CommandType Function -ErrorAction SilentlyContinue)) `
        'The fail-closed v71 Stable evidence validator did not load.'
    Require (Test-Path -LiteralPath $lifecycleRecoveryScript -PathType Leaf) `
        'The required v71 Lab lifecycle/recovery producer is missing.'
    $lifecycleReadLock = Enter-ScriptReadLock $lifecycleRecoveryScript
    $autoplayReadLock = $null
    try {
        Require ([string]$rc4.source.lifecycleRecoveryScriptSha256 -ceq
                (Get-NormalizedTextSha256 $lifecycleRecoveryScript)) `
            'The v71 Lab lifecycle/recovery producer drifted from its locked SHA-256.'
        Require (Test-Path -LiteralPath $autoplayHarnessScript -PathType Leaf) `
            'The lifecycle/recovery autoplay dependency is missing.'
        $autoplayReadLock = Enter-ScriptReadLock $autoplayHarnessScript
        Require ([string]$rc4.source.autoplayHarnessScriptSha256 -ceq
                (Get-NormalizedTextSha256 $autoplayHarnessScript)) `
            'The lifecycle/recovery autoplay dependency drifted from its locked SHA-256.'
    } finally {
        if ($null -ne $autoplayReadLock) { $autoplayReadLock.Dispose() }
        $lifecycleReadLock.Dispose()
    }
    $lockedProducers = @(
        [pscustomobject]@{ Path = $memorySoakScript; Field = 'memorySoakScriptSha256'; Label = 'RC4 memory sampler' },
        [pscustomobject]@{ Path = $memoryRuntimeContractScript; Field = 'memoryRuntimeContractScriptSha256'; Label = 'RC4 memory runtime contract' },
        [pscustomobject]@{ Path = $performanceHarnessScript; Field = 'performanceHarnessScriptSha256'; Label = 'RC3/RC4 performance harness' },
        [pscustomobject]@{ Path = $stableInstallScript; Field = 'stableInstallScriptSha256'; Label = 'RC4 Stable install gate' }
    )
    foreach ($producer in $lockedProducers) {
        Require (Test-Path -LiteralPath $producer.Path -PathType Leaf) `
            ("The {0} is missing." -f $producer.Label)
        $producerReadLock = Enter-ScriptReadLock $producer.Path
        try {
            $lockedHash = [string]$rc4.source.($producer.Field)
            Require ($lockedHash -ceq (Get-NormalizedTextSha256 $producer.Path)) `
                ("The {0} drifted from its locked SHA-256." -f $producer.Label)
        } finally { $producerReadLock.Dispose() }
    }
    Require (Test-Path -LiteralPath $stableAcceptancePath -PathType Leaf) `
        'V71_STABLE_RC4_ACCEPTANCE.lock.json is missing.'
    $stableEvidenceContract = Get-Content -Raw -LiteralPath $stableAcceptancePath |
        ConvertFrom-Json
    $null = Assert-V71Rc4StableAcceptanceManifestContract $stableEvidenceContract
    $script:StableEvidenceContract = $stableEvidenceContract
    Require ([string]$rc4.target.package -ceq 'com.qcxr.qcxr.canary262') `
        'The RC4 lock does not target the isolated Lab package.'
    Require ([string]$rc4.target.forbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
            [bool]$rc4.target.stableTouched -eq $false) `
        'The RC4 lock no longer protects the installed Personal package.'
    Require ([int]$rc4.target.labShellVersionCode -eq 71 -and
            [string]$rc4.target.labShellVersionName -ceq
            '6.0.1-26.2-vivecraft-personal.12-rc.4') `
        'The RC4 lock identity does not match the integrated Lab shell.'
    Require ([string]$rc4.pair.sha256 -ceq $expectedPairHash) `
        'The RC4 lock pair digest drifted.'
    Require ([string]$rc4.pair.core.sha256 -ceq $expectedCoreHash -and
            [string]$rc4.pair.core.fabricVersion -ceq $expectedCoreVersion -and
            [int64]$rc4.pair.core.sizeBytes -eq 10068021) `
        'The RC4 lock does not pin the exact Vivecraft payload.'
    Require ([string]$rc4.pair.veq.sha256 -ceq $expectedVeqHash -and
            [string]$rc4.pair.veq.fabricVersion -ceq $expectedVeqVersion -and
            [int64]$rc4.pair.veq.sizeBytes -eq 441660) `
        'The RC4 lock does not pin the exact frozen VEQ payload.'
    Require ([int]$rc4.memoryPolicy.xmsMiB -eq 512 -and
            [int]$rc4.memoryPolicy.automaticXmxTargetMiB -eq 1536 -and
            [int]$rc4.memoryPolicy.additionalNativeHeadroomMiB -eq 1024 -and
            [int]$rc4.memoryPolicy.automaticXmxMinMiB -eq 1536 -and
            [int]$rc4.memoryPolicy.xmxMaxMiB -eq 2048 -and
            [int]$rc4.memoryPolicy.manualXmxMaxMiB -eq 2048) `
        'The RC4 lock does not pin the bounded Quest JVM memory policy.'
    Require ([string]$rc4.pojlibAar.sha256 -ceq (Get-Sha256 $pluginAar) -and
            [int64]$rc4.pojlibAar.sizeBytes -eq
                (Get-Item -LiteralPath $pluginAar).Length -and
            [bool]$rc4.pojlibAar.cleanBuildsMatchedByteForByte -eq $true -and
            [string]$rc4.pojlibAar.jdk -ceq $expectedPojlibJavaLockIdentity) `
        'The checked-in Pojlib AAR does not match the reproducible RC4 lock.'
    Require ([bool]$rc4.hostVerification.vivecraftCommonTestsPassed -eq $true -and
            [int]$rc4.hostVerification.vivecraftCommonTestsPassedCount -gt 0 -and
            [bool]$rc4.hostVerification.veqCleanCheckBuildPassed -eq $true -and
            [int]$rc4.hostVerification.veqGradleTasksExecuted -eq 86) `
        'The RC4 lock does not contain the completed Vivecraft and VEQ Host gates.'
    Require ([bool]$rc4.hostVerification.buildTransactionSelfTestsPassed -eq $true -and
            [int]$rc4.hostVerification.buildTransactionSelfTestsPassedCount -gt 0 -and
            [bool]$rc4.hostVerification.sharedBuildLockPassed -eq $true -and
            [bool]$rc4.hostVerification.killOnJobClosePassed -eq $true -and
            [bool]$rc4.hostVerification.nativeExitCodePassed -eq $true) `
        'The RC4 lock does not contain the completed build-transaction Host gates.'
    $script:Rc4Lock = $rc4

    Require (Test-Path -LiteralPath $coreAsset -PathType Leaf) 'The managed Vivecraft asset is missing.'
    Require (Test-Path -LiteralPath $veqAsset -PathType Leaf) 'The managed VEQ asset is missing.'
    Require ((Get-Sha256 $coreAsset) -ceq $expectedCoreHash) `
        'The managed Vivecraft asset is not exact RC4.'
    Require ((Get-Sha256 $veqAsset) -ceq $expectedVeqHash) `
        'The managed VEQ asset is not the exact accepted payload.'
    Assert-ManifestPair
    Assert-AarPayload $pluginAar

    $builderPath = Join-Path $wrapper $identity.BuilderFile
    $builder = Get-Content -Raw -LiteralPath $builderPath
    foreach ($required in @(
        $identity.Package, $identity.Label, $identity.VersionCode,
        $identity.VersionName, $identity.Output, 'HasArgument("-release")'
    )) {
        Require ($builder.Contains([string]$required)) `
            "The $Target builder lost required pinned value: $required"
    }
    Require (-not $builder.Contains([string]$identity.ForbiddenPackage)) `
        "The $Target builder contains the forbidden package identity."

    $generic = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Editor\QuestCraftCliBuild.cs')
    Require ($generic.Contains('DefaultApplicationIdentifier = "com.qcxr.qcxr.canary262"')) `
        'The generic builder no longer defaults to isolated Lab.'
    Require ($generic.Contains('AcceptedPersonalApplicationIdentifier = "com.qcxr.qcxr.dev262"')) `
        'The generic builder no longer protects Personal.'
    Require ($generic.Contains('BuildAcceptedPersonalV71Android')) `
        'The exact internal Personal v71 gate is missing.'
    Require (Test-Path -LiteralPath $verifyScript -PathType Leaf) 'The APK verifier is missing.'
}

function Restore-SourceAar {
    if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        return [pscustomobject]@{
            Result = 'ALREADY_CLEAN'
            Target = $Target
            DeviceInvocations = 0
        }
    }
    if ([IO.Directory]::GetFileSystemEntries($backupDirectory).Length -eq 0) {
        [IO.Directory]::Delete($backupDirectory)
        return [pscustomobject]@{
            Result = 'EMPTY_GUARD_REMOVED'
            Target = $Target
            DeviceInvocations = 0
        }
    }
    $journal = Read-TransactionJournal
    Restore-CheckedInInputs $journal
    Restore-PreviousOutput $journal
    Remove-CompletedTransactionGuard
    [pscustomobject]@{
        Result = 'INTERRUPTED_BUILD_ROLLED_BACK'
        Target = $Target
        SourceAarSha256 = [string]$journal.sourceAar.sha256
        PreviousOutputPresent = [bool]$journal.previousOutput.present
        DeviceInvocations = 0
    }
}

$globalBuildLockStream = Enter-GlobalBuildLock
try {
    if ($Action -ceq 'RecoverInterruptedBuild' -or $Action -ceq 'RestoreSourceAar') {
        Restore-SourceAar
        return
    }

    Assert-Source
    $unityRoot = Split-Path -Parent $UnityEditor
    $unityJavaHome = Join-Path $unityRoot `
        'Data\PlaybackEngines\AndroidPlayer\OpenJDK'
    $unityJava = Resolve-UnityJavaToolchain $unityJavaHome
    $pojlibJava = $unityJava
    $pinnedD8 = Resolve-PinnedD8Builder $unityJava.JavaExecutable
    if ($Action -ceq 'SelfTest') {
        [pscustomobject]@{
            Result = 'PASS'
            HostOnly = $true
            DeviceInvocations = 0
            Target = $Target
            Package = $identity.Package
            VersionCode = $identity.VersionCode
            VersionName = $identity.VersionName
            Output = $outputApk
            CoreSha256 = $expectedCoreHash
            VeqSha256 = $expectedVeqHash
            DebugSignerOnly = $true
            SharedBuildLock = $true
            PojlibJavaHome = $pojlibJava.Home
            PojlibJavaVersion = $pojlibJava.Version
            PojlibJavaRuntime = $pojlibJava.Runtime
            UnityJavaHome = $unityJava.Home
            UnityJavaVersion = $unityJava.Version
            UnityJavaIdentity = $unityJava.Identity
            SharedPojlibAndUnityJdk =
                ($pojlibJava.Home -ceq $unityJava.Home)
            D8Version = $pinnedD8.Version
            D8BuilderSha256 = $pinnedD8.Sha256
            StableEvidenceGateStatus = [string]$script:StableEvidenceContract.status
            StableEvidenceManifestSha256 = Get-Sha256 $stableAcceptancePath
        }
        return
    }

    Require ($AllowBuild.IsPresent) 'Build requires the explicit -AllowBuild switch.'
    if ($Target -ceq 'Stable') {
        Require ($AllowStablePromotion.IsPresent) `
            'Stable build requires explicit -AllowStablePromotion after Lab acceptance.'
        # Assert-Source already hash-verified and loaded this exact gate into
        # memory. Do not source the mutable path a second time.
        $stableEvidenceReceipt = Assert-V71Rc4StableAcceptanceEvidence `
            -ManifestPath $stableAcceptancePath `
            -RepoRoot $repo `
            -EvidenceRoot $workspaceRoot `
            -MemorySamplerPath $memorySoakScript `
            -MemoryRuntimeContractPath $memoryRuntimeContractScript `
            -PerformanceHarnessPath $performanceHarnessScript `
            -LifecycleHarnessPath $lifecycleRecoveryScript
        Require ([string]$stableEvidenceReceipt.Result -ceq 'PASS') `
            'Stable promotion evidence validation did not return PASS.'
    }
    Require (Test-Path -LiteralPath $UnityEditor -PathType Leaf) `
        'Unity 2022.3.62f3 was not found.'
    Require (-not (Test-Path -LiteralPath $backupDirectory)) `
        "An interrupted Lab/Stable build transaction already exists: $backupDirectory"
    $legacyGuards = @($legacyBackupDirectories | Where-Object {
        Test-Path -LiteralPath $_ -PathType Container
    })
    Require ($legacyGuards.Count -eq 0) `
        ('A legacy interrupted build guard must be audited before building: ' +
            ($legacyGuards -join ', '))
    $dirty = @(git -C $repo status --porcelain --untracked-files=all)
    Require ($LASTEXITCODE -eq 0 -and $dirty.Count -eq 0) `
        'Build requires a clean worktree so artifact restoration is provable.'
    $requiredFreeBytes = if ($Target -ceq 'Stable') { 15GB } else { 10GB }
    Require ((Get-PSDrive -Name C).Free -ge $requiredFreeBytes) `
        ("A v71 {0} build requires at least {1} GiB free." -f `
            $Target, [int]($requiredFreeBytes / 1GB))

    $androidSdk = Join-Path $unityRoot 'Data\PlaybackEngines\AndroidPlayer\SDK'
    Require ($pojlibJava.Home -ceq $unityJava.Home) `
        'Pojlib and Unity must use the exact same bundled Temurin 11 toolchain.'
    Require (Test-Path -LiteralPath $androidSdk -PathType Container) `
        'Unity Android SDK is missing.'
    $sdkManagers = @(Get-ChildItem -LiteralPath (Join-Path $androidSdk 'cmdline-tools') `
        -Filter sdkmanager.bat -File -Recurse -ErrorAction SilentlyContinue)
    Require ($sdkManagers.Count -gt 0) `
        'Unity Android SDK command-line tools are missing; use the complete Unity installation.'

    $oldJavaHome = $env:JAVA_HOME
    $oldAndroidHome = $env:ANDROID_HOME
    $oldAndroidSdkRoot = $env:ANDROID_SDK_ROOT
    $oldPath = $env:PATH
    $headBeforeBuild = (& git -C $repo rev-parse HEAD).Trim()
    Require ($LASTEXITCODE -eq 0) 'Could not snapshot the pre-build Git revision.'
    $sourceAarHash = Get-Sha256 $pluginAar
    $sourceProjectSettingsHash = Get-Sha256 $projectSettings
    $previousOutputPresent = Test-Path -LiteralPath $outputApk -PathType Leaf
    $previousOutputHash = if ($previousOutputPresent) { Get-Sha256 $outputApk } else { $null }
    $previousOutputSize = if ($previousOutputPresent) {
        (Get-Item -LiteralPath $outputApk).Length
    } else { 0 }
    $outputVerified = $false
    $buildResult = $null
    $buildJob = $null
    $primaryError = $null
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    $logPath = Join-Path $env:TEMP `
        ('questcraft-v71-' + $Target.ToLowerInvariant() + '-' +
            [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.log')
    $transaction = [ordered]@{
        schemaVersion = 1
        repo = Get-CanonicalPath $repo
        target = $Target
        outputApk = Get-CanonicalPath $outputApk
        phase = 'prepared'
        sourceAar = [ordered]@{
            path = Get-CanonicalPath $pluginAar
            sha256 = $sourceAarHash
            sizeBytes = (Get-Item -LiteralPath $pluginAar).Length
        }
        projectSettings = [ordered]@{
            path = Get-CanonicalPath $projectSettings
            sha256 = $sourceProjectSettingsHash
            sizeBytes = (Get-Item -LiteralPath $projectSettings).Length
        }
        previousOutput = [ordered]@{
            present = $previousOutputPresent
            sha256 = $previousOutputHash
            sizeBytes = $previousOutputSize
        }
        newOutput = [ordered]@{
            verified = $false
            sha256 = $null
            sizeBytes = 0
        }
    }

    try {
        [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
        Write-TransactionJournal $transaction
        [IO.File]::Copy($pluginAar, $backupAar, $false)
        Require ((Get-Sha256 $backupAar) -ceq $sourceAarHash) `
            'Could not lock the source AAR backup.'
        [IO.File]::WriteAllText(
            $backupHashFile, $sourceAarHash + [Environment]::NewLine)
        [IO.File]::Copy($projectSettings, $backupProjectSettings, $false)
        Require ((Get-Sha256 $backupProjectSettings) -ceq $sourceProjectSettingsHash) `
            'Could not lock the Unity ProjectSettings backup.'
        [IO.File]::WriteAllText(
            $backupProjectSettingsHashFile,
            $sourceProjectSettingsHash + [Environment]::NewLine)
        $transaction.phase = 'backups-ready'
        Write-TransactionJournal $transaction

        if ($previousOutputPresent) {
            [IO.File]::Move($outputApk, $previousOutputApk)
            Require (-not (Test-Path -LiteralPath $outputApk)) `
                'Could not quarantine the pre-existing APK before the build.'
            Require ((Get-Sha256 $previousOutputApk) -ceq $previousOutputHash -and
                    (Get-Item -LiteralPath $previousOutputApk).Length -eq $previousOutputSize) `
                'The quarantined pre-existing APK drifted.'
        }
        $transaction.phase = 'output-quarantined'
        Write-TransactionJournal $transaction

        $env:JAVA_HOME = $pojlibJava.Home
        $env:ANDROID_HOME = $androidSdk
        $env:ANDROID_SDK_ROOT = $androidSdk
        $env:PATH = (Join-Path $pojlibJava.Home 'bin') + ';' + $oldPath

        $buildJob = [QuestCraftV71BuildJob]::new()
        $javaExecutable = $pojlibJava.JavaExecutable
        $gradleWrapperJar = Join-Path $pojlib 'gradle\wrapper\gradle-wrapper.jar'
        Require (Test-Path -LiteralPath $gradleWrapperJar -PathType Leaf) `
            'The pinned Gradle wrapper JAR is missing.'
        $gradleArguments = @(
            '-Xmx64m',
            '-Xms64m',
            '-Dorg.gradle.appname=gradlew',
            '-classpath',
            $gradleWrapperJar,
            'org.gradle.wrapper.GradleWrapperMain',
            '--no-daemon',
            'clean',
            'testReleaseUnitTest',
            'assembleRelease'
        )
        for ($buildNumber = 1; $buildNumber -le 2; $buildNumber++) {
            $gradle = $buildJob.Start($javaExecutable, $gradleArguments, $pojlib)
            try {
                $gradle.WaitForExit()
                $gradleExitCode = $gradle.ExitCode
            } finally { $gradle.Dispose() }
            Require ($gradleExitCode -eq 0) `
                "Pojlib AAR build $buildNumber failed."
            Assert-AarPayload $builtAar
            if ($buildNumber -eq 1) {
                [IO.File]::Copy($builtAar, $reproAar, $false)
            }
        }

        $firstAarHash = Get-Sha256 $reproAar
        $secondAarHash = Get-Sha256 $builtAar
        Require ($firstAarHash -ceq $secondAarHash) `
            'Two clean Pojlib AAR builds were not byte-for-byte reproducible.'
        $lockedAarHash = ([string]$script:Rc4Lock.pojlibAar.sha256).ToUpperInvariant()
        $lockedAarSize = [int64]$script:Rc4Lock.pojlibAar.sizeBytes
        Require ($secondAarHash -ceq $lockedAarHash -and
                (Get-Item -LiteralPath $builtAar).Length -eq $lockedAarSize) `
            'The reproducible Pojlib AAR drifted from the exact v71 RC4 lock.'
        Assert-D8Compatibility $builtAar $unityJava $buildJob
        [IO.File]::Copy($builtAar, $pluginAar, $true)

        # Pojlib and Unity deliberately share Unity's exact bundled Temurin 11.
        # Newer javac output adds unnamed MethodParameters entries to synthetic
        # bridge methods, which crashes Unity 2022.3's pinned D8 4.0.52.
        $env:JAVA_HOME = $unityJava.Home
        $env:PATH = (Join-Path $unityJava.Home 'bin') + ';' + $oldPath

        $transaction.phase = 'unity-building'
        Write-TransactionJournal $transaction
        $arguments = @(
            '-batchmode', '-nographics', '-quit',
            '-projectPath', $wrapper,
            '-executeMethod', $identity.Builder,
            '-applicationIdentifier', $identity.Package,
            '-productName', $identity.Label,
            '-versionName', $identity.VersionName,
            '-versionCode', $identity.VersionCode,
            '-outputPath', $identity.Output,
            '-logFile', $logPath
        )
        $process = $buildJob.Start($UnityEditor, $arguments, $wrapper)
        try {
            $process.WaitForExit()
            $unityExitCode = $process.ExitCode
        } finally { $process.Dispose() }
        Require ($unityExitCode -eq 0) "Unity v71 build failed; inspect $logPath"
        Require (Test-Path -LiteralPath $outputApk -PathType Leaf) `
            'Unity produced no v71 APK.'

        & $verifyScript `
            -ApkPath $outputApk `
            -ExpectedPackage $identity.Package `
            -ExpectedVersionCode $identity.VersionCode `
            -ExpectedVersionName $identity.VersionName `
            -ExpectedLabel $identity.Label `
            -ExpectedVivecraftSha256 $expectedCoreHash `
            -ExpectedVivecraftVersion $expectedCoreVersion `
            -ExpectedAddOnSha256 $expectedVeqHash `
            -ExpectedAddOnVersion $expectedVeqVersion `
            -ExpectedLwjglSha256 $expectedLwjglHash `
            -ExpectedSignerSha256 $expectedSignerHash
        if ($LASTEXITCODE -ne 0) { throw 'The v71 APK verifier failed.' }
        Assert-ApkLifecycleMarkers $outputApk

        $headAfterBuild = (& git -C $repo rev-parse HEAD).Trim()
        Require ($LASTEXITCODE -eq 0 -and $headAfterBuild -ceq $headBeforeBuild) `
            'The Git revision changed while the v71 build was running.'
        $allowedBuildChanges = @(
            'QCXR-XR-Wrapper/Assets/Plugins/Android/Pojlib-release.aar',
            'QCXR-XR-Wrapper/ProjectSettings/ProjectSettings.asset'
        )
        $changedPaths = @(
            @(git -C $repo diff --name-only),
            @(git -C $repo diff --cached --name-only),
            @(git -C $repo ls-files --others --exclude-standard)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        $unexpectedChanges = @($changedPaths | Where-Object { $_ -cnotin $allowedBuildChanges })
        Require ($unexpectedChanges.Count -eq 0) `
            ('Unexpected source changes appeared during the v71 build: ' +
                ($unexpectedChanges -join ', '))

        $newOutputHash = Get-Sha256 $outputApk
        $newOutputSize = (Get-Item -LiteralPath $outputApk).Length
        $transaction.newOutput.verified = $true
        $transaction.newOutput.sha256 = $newOutputHash
        $transaction.newOutput.sizeBytes = $newOutputSize
        $transaction.phase = 'verified'
        Write-TransactionJournal $transaction
        $outputVerified = $true
        $buildResult = [pscustomobject]@{
            Result = 'BUILT_AND_VERIFIED'
            HostOnly = $true
            DeviceInvocations = 0
            Target = $Target
            Apk = $outputApk
            ApkSha256 = $newOutputHash
            ApkSizeBytes = $newOutputSize
            Package = $identity.Package
            VersionCode = $identity.VersionCode
            VersionName = $identity.VersionName
            PojlibAarSha256 = $secondAarHash
            PojlibReproducible = $true
            SignerSha256 = $expectedSignerHash
            BuildLog = $logPath
        }
    } catch {
        $primaryError = $_
    } finally {
        if ($null -ne $buildJob) {
            try { $buildJob.Dispose() } catch { $cleanupErrors.Add($_.Exception.Message) }
            $buildJob = $null
        }
        if (Test-Path -LiteralPath $backupDirectory -PathType Container) {
            if ([IO.Directory]::GetFileSystemEntries($backupDirectory).Length -eq 0) {
                try { [IO.Directory]::Delete($backupDirectory) } catch {
                    $cleanupErrors.Add($_.Exception.Message)
                }
            } else {
                $cleanupStartCount = $cleanupErrors.Count
                $journal = $null
                try { $journal = Read-TransactionJournal } catch {
                    $cleanupErrors.Add($_.Exception.Message)
                }
                if ($null -ne $journal) {
                    try { Restore-CheckedInInputs $journal } catch {
                        $cleanupErrors.Add($_.Exception.Message)
                    }
                    try {
                        if ($outputVerified -and [bool]$journal.newOutput.verified) {
                            $expectedNew =
                                ([string]$journal.newOutput.sha256).ToUpperInvariant()
                            Require ($expectedNew -cmatch '^[0-9A-F]{64}$' -and
                                    (Get-Sha256 $outputApk) -ceq $expectedNew -and
                                    (Get-Item -LiteralPath $outputApk).Length -eq
                                        [int64]$journal.newOutput.sizeBytes) `
                                'The verified new APK drifted during success finalization.'
                            Archive-PreviousOutput $journal
                        } else {
                            Restore-PreviousOutput $journal
                        }
                    } catch { $cleanupErrors.Add($_.Exception.Message) }
                    if ($cleanupErrors.Count -eq $cleanupStartCount) {
                        try { Remove-CompletedTransactionGuard } catch {
                            $cleanupErrors.Add($_.Exception.Message)
                        }
                    }
                }
            }
        }
        try { $env:JAVA_HOME = $oldJavaHome } catch { $cleanupErrors.Add($_.Exception.Message) }
        try { $env:ANDROID_HOME = $oldAndroidHome } catch { $cleanupErrors.Add($_.Exception.Message) }
        try { $env:ANDROID_SDK_ROOT = $oldAndroidSdkRoot } catch { $cleanupErrors.Add($_.Exception.Message) }
        try { $env:PATH = $oldPath } catch { $cleanupErrors.Add($_.Exception.Message) }
    }

    if ($null -ne $primaryError) {
        $message = $primaryError.Exception.Message
        if ($cleanupErrors.Count -gt 0) {
            $message += ' | Recovery errors: ' + ($cleanupErrors -join ' | ')
        }
        throw [InvalidOperationException]::new($message, $primaryError.Exception)
    }
    if ($cleanupErrors.Count -gt 0) {
        throw ('The build completed, but transaction finalization failed: ' +
            ($cleanupErrors -join ' | '))
    }
    $buildResult
} finally {
    if ($null -ne $globalBuildLockStream) {
        $globalBuildLockStream.Dispose()
        $globalBuildLockStream = $null
    }
}
