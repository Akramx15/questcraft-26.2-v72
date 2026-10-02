#requires -Version 7.0
<#
.SYNOPSIS
Identity-locked Lab-only A/B gate for Vivecraft renderScaleFactor 1.0 <-> 0.8.

.DESCRIPTION
Status is the default and never writes to the Quest. Arm and Restore require
-AllowDeviceWrite, exact RC8 Lab APK/Core/VEQ identity, the expected signer,
and a stopped Lab process. The only remote mutations are an argv-only push to a
same-directory staging file, chmod 0660 on that exact stage, and an argv-only
mv over the one fixed Vivecraft configuration file. Stable, root, package management, launch/stop,
network, accounts, worlds, mods, and resource packs have no mutation path.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Arm', 'Restore')]
    [string] $Action = 'Status',

    [switch] $AllowDeviceWrite,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [string] $ApkSignerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:VersionCode = 71L
$script:VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'
$script:ApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$script:SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:CoreSha256 = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$script:VeqSha256 = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$script:MutexNamespace = 'QuestCraft_RC8_RenderScale_AB_PRODUCTION'
$script:GameDir = "/sdcard/Android/data/$($script:Package)/files/instances/$($script:Profile)"
$script:ConfigPath = "$($script:GameDir)/config/vivecraft-client-config.json"
$script:CorePath = "$($script:GameDir)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDir)/mods/Vivecraft-Essentials-Quest.jar"
$script:ArtifactRoot = Join-Path $script:RepoRoot 'artifacts\v71-rc8-render-scale-ab'
$script:StatePath = Join-Path $script:ArtifactRoot 'state.json'
$script:OriginalPath = Join-Path $script:ArtifactRoot 'vivecraft-client-config.original.bin'
$script:CandidatePath = Join-Path $script:ArtifactRoot 'vivecraft-client-config.scale-0.8.bin'
$script:ResolvedAdb = $null
$script:ResolvedSigner = $null
$script:ResolvedSerial = $null
$script:DeviceReadCount = 0
$script:DeviceWriteCount = 0
$script:Utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[RC8_RENDER_SCALE_AB] $Message" }
}

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string] $Path)
    [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-ContainedHostPath {
    param([Parameter(Mandatory)][string] $Path)
    $root = Get-CanonicalPath $script:ArtifactRoot
    $full = Get-CanonicalPath $Path
    Require ($full.StartsWith(
        $root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'A transaction path escaped the fixed artifact root.'
    $full
}

function Assert-NoReparseComponents {
    param([Parameter(Mandatory)][string] $Path)
    $repo = Get-CanonicalPath $script:RepoRoot
    $full = Get-CanonicalPath $Path
    Require ($full.StartsWith(
        $repo + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'A protected Host path escaped the worktree.'
    $relative = [IO.Path]::GetRelativePath($repo, $full)
    $current = $repo
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) "A protected Host path is a reparse point: $current"
        }
    }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToUpperInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-TransactionMutexName {
    # A named kernel mutex provides cross-process exclusion without creating,
    # deleting, or trusting a stale lock file. Windows releases ownership when
    # a process dies; WaitOne then reports an abandoned mutex while granting
    # ownership to the recovery caller.
    # Deliberately independent of worktree path: copies of this exact gate in
    # different worktrees still serialize access to the same Lab target.
    $identity = $script:Package + '|' + $script:Profile + '|' + $script:ConfigPath
    $digest = Get-BytesSha256 $script:Utf8NoBom.GetBytes($identity)
    "$($script:MutexNamespace)_$digest"
}

function Enter-TransactionMutex {
    $mutex = [Threading.Mutex]::new($false, (Get-TransactionMutexName))
    $acquired = $false
    $abandoned = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            # The OS has already transferred ownership to this caller. No
            # lock-file deletion or other speculative stale-lock recovery is
            # needed (or permitted).
            $acquired = $true
            $abandoned = $true
        }
        Require $acquired 'Another render-scale gate invocation is active.'
        [pscustomobject]@{
            Mutex = $mutex
            Acquired = $true
            RecoveredAbandonedOwner = $abandoned
        }
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-TransactionMutex {
    param([Parameter(Mandatory)] $Lease)
    try {
        if ([bool]$Lease.Acquired) { $Lease.Mutex.ReleaseMutex() }
    } finally { $Lease.Mutex.Dispose() }
}

function Write-AtomicHostBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][byte[]] $Bytes,
        [switch] $RefuseExisting
    )
    $full = Assert-ContainedHostPath $Path
    Assert-NoReparseComponents $script:ArtifactRoot
    if (-not (Test-Path -LiteralPath $script:ArtifactRoot)) {
        [IO.Directory]::CreateDirectory($script:ArtifactRoot) | Out-Null
    }
    Assert-NoReparseComponents $script:ArtifactRoot
    if ($RefuseExisting) {
        Require (-not (Test-Path -LiteralPath $full)) 'A protected transaction artifact already exists.'
    }
    $stage = Assert-ContainedHostPath ($full + '.next-' + [Guid]::NewGuid().ToString('N'))
    try {
        $stream = [IO.FileStream]::new($stage, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        Require ((Get-FileSha256 $stage) -ceq (Get-BytesSha256 $Bytes)) 'A Host staging write was not byte exact.'
        [IO.File]::Move($stage, $full, (-not $RefuseExisting.IsPresent))
        Require ((Get-FileSha256 $full) -ceq (Get-BytesSha256 $Bytes)) 'An atomic Host publication was not byte exact.'
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) { [IO.File]::Delete($stage) }
    }
}

function Write-AtomicState {
    param([Parameter(Mandatory)] $State, [switch] $RefuseExisting)
    $json = $State | ConvertTo-Json -Depth 12
    Write-AtomicHostBytes -Path $script:StatePath `
        -Bytes $script:Utf8NoBom.GetBytes($json + [Environment]::NewLine) `
        -RefuseExisting:$RefuseExisting
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    Assert-NoReparseComponents $script:StatePath
    try {
        $text = $script:Utf8Strict.GetString([IO.File]::ReadAllBytes($script:StatePath))
        $state = $text | ConvertFrom-Json -Depth 20
    } catch {
        throw "[RC8_RENDER_SCALE_AB] The local transaction state is invalid: $($_.Exception.Message)"
    }
    Require ([int]$state.schemaVersion -eq 1) 'The local transaction schema drifted.'
    Require ([string]$state.package -ceq $script:Package -and
        [string]$state.stablePackageDenied -ceq $script:StablePackage -and
        [string]$state.profile -ceq $script:Profile) 'The local transaction identity drifted.'
    Require ([int64]$state.versionCode -eq $script:VersionCode -and
        [string]$state.versionName -ceq $script:VersionName -and
        [string]$state.apkSha256 -ceq $script:ApkSha256 -and
        [string]$state.signerSha256 -ceq $script:SignerSha256 -and
        [string]$state.coreSha256 -ceq $script:CoreSha256 -and
        [string]$state.veqSha256 -ceq $script:VeqSha256 -and
        [string]$state.configRemotePath -ceq $script:ConfigPath) `
        'The transaction artifact identity drifted.'
    Require ([string]$state.serial -cmatch '^[A-Za-z0-9._:-]+$') 'The transaction serial is malformed.'
    Require ([string]$state.sourceScale -ceq '1.0' -and
        [string]$state.candidateScale -ceq '0.8') 'The transaction scale pair drifted.'
    Require ([string]$state.sourceSha256 -cmatch '^[0-9A-F]{64}$' -and
        [string]$state.candidateSha256 -cmatch '^[0-9A-F]{64}$') 'The transaction digest is malformed.'
    Require ([string]$state.status -cin @('BACKUP_READY','ARMED','RECOVERED','RESTORED')) `
        'The transaction status is not recognized.'
    Require ([string]$state.onlySemanticChange -ceq 'renderScaleFactor:1.0->0.8' -and
        -not [bool]$state.stableTouched -and
        -not [bool]$state.rootUsed -and
        -not [bool]$state.packageManagerUsed -and
        -not [bool]$state.accountWorldModResourcePackTouched) `
        'The transaction safety boundary drifted.'
    $state
}

function Invoke-ProcessCapture {
    param([Parameter(Mandatory)][string] $FileName, [Parameter(Mandatory)][string[]] $Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Require $process.Start() "Could not start: $FileName"
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult()
            Stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    if ($AdbPath -cne 'adb') { throw '[RC8_RENDER_SCALE_AB] The requested ADB executable was not found.' }
    $sideQuest = Join-Path $env:LOCALAPPDATA `
        'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw '[RC8_RENDER_SCALE_AB] ADB was not found. Pass -AdbPath explicitly.'
}

function Resolve-ApkSigner {
    if (-not [string]::IsNullOrWhiteSpace($ApkSignerPath)) {
        Require (Test-Path -LiteralPath $ApkSignerPath -PathType Leaf) 'The requested apksigner is absent.'
        return (Resolve-Path -LiteralPath $ApkSignerPath).Path
    }
    $command = Get-Command 'apksigner.bat' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -Unique
    $candidate = @(
        foreach ($sdkRoot in $sdkRoots) {
            $buildTools = Join-Path $sdkRoot 'build-tools'
            if (Test-Path -LiteralPath $buildTools -PathType Container) {
                Get-ChildItem -LiteralPath $buildTools -Directory | ForEach-Object {
                    $tool = Join-Path $_.FullName 'apksigner.bat'
                    if (Test-Path -LiteralPath $tool -PathType Leaf) {
                        try { $version = [version]$_.Name } catch { $version = [version]'0.0' }
                        [pscustomobject]@{ Version = $version; Path = $tool }
                    }
                }
            }
        }
    ) | Sort-Object Version -Descending | Select-Object -First 1
    Require ($null -ne $candidate) 'Android SDK apksigner was not found.'
    [string]$candidate.Path
}

function Invoke-AdbRaw {
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $Write)
    Require (-not [string]::IsNullOrWhiteSpace([string]$script:ResolvedAdb)) 'ADB is unresolved.'
    if ($Write) {
        Require ($Action -cin @('Arm','Restore') -and $AllowDeviceWrite.IsPresent) `
            'A device mutation was attempted without explicit authorization.'
        $script:DeviceWriteCount++
    } else { $script:DeviceReadCount++ }
    Invoke-ProcessCapture -FileName $script:ResolvedAdb -Arguments $Arguments
}

function Assert-AdbSuccess {
    param([Parameter(Mandatory)] $Result, [string] $Context, [switch] $AllowOutput)
    Require ([int]$Result.ExitCode -eq 0) "$Context failed."
    Require ([string]::IsNullOrWhiteSpace([string]$Result.Stderr)) "$Context emitted stderr."
    if (-not $AllowOutput) {
        Require ([string]::IsNullOrWhiteSpace([string]$Result.Stdout)) "$Context emitted unexpected output."
    }
}

function Resolve-ExactDevice {
    $script:ResolvedAdb = Resolve-Adb
    $result = Invoke-AdbRaw @('devices')
    Assert-AdbSuccess $result 'ADB device enumeration' -AllowOutput
    $records = @($result.Stdout -split "`r?`n" | ForEach-Object {
        if ($_ -cmatch '^(?<serial>\S+)\s+(?<state>\S+)(?:\s+.*)?$' -and
            [string]$Matches.serial -cne 'List') {
            [pscustomobject]@{ Serial = [string]$Matches.serial; State = [string]$Matches.state }
        }
    })
    if ($Serial -ceq 'auto') {
        Require ($records.Count -eq 1 -and [string]$records[0].State -ceq 'device') `
            'Auto selection requires exactly one authorized device.'
        $script:ResolvedSerial = [string]$records[0].Serial
    } else {
        $matches = @($records | Where-Object { [string]$_.Serial -ceq $Serial })
        Require ($matches.Count -eq 1 -and [string]$matches[0].State -ceq 'device') `
            'The requested ADB endpoint is not uniquely authorized.'
        $script:ResolvedSerial = $Serial
    }
    Require ($script:ResolvedSerial -cmatch '^[A-Za-z0-9._:-]+$') 'The resolved serial is unsafe.'
    $state = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'get-state')
    Assert-AdbSuccess $state 'ADB state check' -AllowOutput
    Require ($state.Stdout.Trim() -ceq 'device') 'The selected endpoint is not ready.'
}

function Invoke-ShellRead {
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $result = Invoke-AdbRaw (@('-s',$script:ResolvedSerial,'shell') + $Arguments)
    if (-not $AllowFailure) { Assert-AdbSuccess $result 'Read-only device probe' -AllowOutput }
    $result
}

function Read-RemoteSha256 {
    param([Parameter(Mandatory)][string] $Path)
    $result = Invoke-ShellRead @('sha256sum',$Path)
    $rows = @($result.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'A remote digest was ambiguous.'
    $match = [regex]::Match($rows[0], '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require ($match.Success -and [string]$match.Groups['path'].Value -ceq $Path) `
        'A remote digest named an unexpected path.'
    ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-InstalledBasePath {
    $result = Invoke-ShellRead @('pm','path',$script:Package)
    $rows = @($result.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1 -and $rows[0] -cmatch
        '^package:(?<path>/data/app/(?:[A-Za-z0-9._~+=-]+/)+base\.apk)$') `
        'The Lab package did not expose one safe base APK.'
    $path = [string]$Matches.path
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)') -and
        -not $path.Contains('/../')) 'The base APK path is not bound to Lab.'
    $path
}

function Read-PackageIdentity {
    $result = Invoke-ShellRead @('dumpsys','package',$script:Package)
    $codes = @($result.Stdout -split "`r?`n" | ForEach-Object {
        if ($_ -cmatch '^\s*versionCode=(?<v>[0-9]+)(?:\s|$)') { [int64]$Matches.v }
    })
    $names = @($result.Stdout -split "`r?`n" | ForEach-Object {
        if ($_ -cmatch '^\s*versionName=(?<v>\S+)\s*$') { [string]$Matches.v }
    })
    Require ($codes.Count -eq 1 -and $names.Count -eq 1) 'The installed Lab identity is incomplete.'
    Require ($codes[0] -eq $script:VersionCode -and $names[0] -ceq $script:VersionName) `
        'The installed package is not exact RC8.'
}

function New-SafeTempDirectory {
    $root = Get-CanonicalPath ([IO.Path]::GetTempPath())
    $path = Join-Path $root ('qc-rc8-render-scale-' + [Guid]::NewGuid().ToString('N'))
    Require ((Get-CanonicalPath $path).StartsWith(
        $root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'A temporary path escaped Temp.'
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $path
}

function Remove-SafeTempDirectory {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $root = Get-CanonicalPath ([IO.Path]::GetTempPath())
    $full = Get-CanonicalPath $Path
    Require ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('qc-rc8-render-scale-',
            [StringComparison]::Ordinal)) 'Refused to remove an unexpected temporary path.'
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Force)) {
        Require (-not $item.PSIsContainer) 'The temporary directory unexpectedly contains a directory.'
        [IO.File]::Delete($item.FullName)
    }
    [IO.Directory]::Delete($full)
}

function Assert-BoundedPullChatter {
    param(
        [AllowEmptyString()][string] $Stdout,
        [AllowEmptyString()][string] $Stderr
    )
    $combinedLength = $Stdout.Length + $Stderr.Length
    Require ($combinedLength -le 65536) 'ADB pull emitted oversized transfer chatter.'
    $rows = @((($Stdout + "`n" + $Stderr) -replace "`r", "`n") -split "`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -le 512) 'ADB pull emitted too many transfer progress rows.'
    foreach ($row in $rows) {
        Require ($row.Length -le 4096 -and $row -cnotmatch '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') `
            'ADB pull emitted malformed transfer chatter.'
        $summary = $row -match '(?i)^(?:.+?:\s*)?1\s+file\s+pulled(?:,\s*0\s+skipped)?\.?(?:\s+[0-9]+(?:\.[0-9]+)?\s+(?:[KMGT]?B/s)\s+\([0-9]+\s+bytes\s+in\s+[0-9]+(?:\.[0-9]+)?s\))?\s*$'
        $progress = $row -match '^\[\s*(?:100|[0-9]{1,2})%\]\s+\S.{0,4080}$'
        Require ($summary -or $progress) 'ADB pull emitted unrecognized transfer chatter.'
    }
}

function Read-RemoteMode {
    param([Parameter(Mandatory)][string] $Path)
    $result = Invoke-ShellRead @('stat','-c','%a',$Path)
    $rows = @($result.Stdout -split "`r?`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1 -and $rows[0] -cmatch '^[0-7]{3,4}$') `
        'The remote file mode probe was malformed.'
    [string]$rows[0]
}

function Assert-BoundedPushChatter {
    param(
        [AllowEmptyString()][string] $Stdout,
        [AllowEmptyString()][string] $Stderr
    )
    $combinedLength = $Stdout.Length + $Stderr.Length
    Require ($combinedLength -le 65536) 'ADB push emitted oversized transfer chatter.'
    $rows = @((($Stdout + "`n" + $Stderr) -replace "`r", "`n") -split "`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -le 512) 'ADB push emitted too many transfer progress rows.'
    foreach ($row in $rows) {
        Require ($row.Length -le 4096 -and $row -cnotmatch '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') `
            'ADB push emitted malformed transfer chatter.'
        $summary = $row -match '(?i)^(?:.+?:\s*)?1\s+file\s+pushed(?:,\s*0\s+skipped)?\.?(?:\s+[0-9]+(?:\.[0-9]+)?\s+(?:[KMGT]?B/s)\s+\([0-9]+\s+bytes\s+in\s+[0-9]+(?:\.[0-9]+)?s\))?\s*$'
        $progress = $row -match '^\[\s*(?:100|[0-9]{1,2})%\]\s+\S.{0,4080}$'
        Require ($summary -or $progress) 'ADB push emitted unrecognized transfer chatter.'
    }
}

function Invoke-PullReadOnly {
    param(
        [Parameter(Mandatory)][string] $Remote,
        [Parameter(Mandatory)][string] $Local,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')]
        [string] $ExpectedSha256
    )
    Require (-not (Test-Path -LiteralPath $Local)) 'A pull destination already exists.'
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'pull',$Remote,$Local)
    Require ([int]$result.ExitCode -eq 0) 'A read-only pull failed.'
    Require ((Test-Path -LiteralPath $Local -PathType Leaf) -and
        (Get-Item -LiteralPath $Local).Length -gt 0) `
        'A successful pull did not produce one nonempty local file.'
    Require ((Get-FileSha256 $Local) -ceq $ExpectedSha256) `
        'The pulled local file digest did not match the observed remote bytes.'
    # Native adb commonly emits its successful transfer summary/progress on
    # stderr. Validate and discard only bounded transfer chatter after exit,
    # file, and digest checks; never echo or persist it.
    Assert-BoundedPullChatter -Stdout ([string]$result.Stdout) -Stderr ([string]$result.Stderr)
}

function Read-SignerFromApk {
    param([Parameter(Mandatory)][string] $Apk)
    if ($null -eq $script:ResolvedSigner) { $script:ResolvedSigner = Resolve-ApkSigner }
    $result = Invoke-ProcessCapture -FileName $script:ResolvedSigner `
        -Arguments @('verify','--verbose','--print-certs',(Get-CanonicalPath $Apk))
    Require ([int]$result.ExitCode -eq 0 -and
        [string]::IsNullOrWhiteSpace([string]$result.Stderr)) 'apksigner rejected the installed Lab APK.'
    $signerMatches = @([regex]::Matches($result.Stdout,
        '(?im)^Signer #(?<n>[0-9]+) certificate SHA-256 digest:\s*(?<sha>[0-9a-f]{64})\s*$'))
    Require ($signerMatches.Count -eq 1 -and [string]$signerMatches[0].Groups['n'].Value -ceq '1') `
        'The installed APK signer result is ambiguous.'
    Require ($result.Stdout -cmatch '(?m)^Verified using v2 scheme \(APK Signature Scheme v2\): true\s*$') `
        'The installed APK lacks a verified v2 signature.'
    ([string]$signerMatches[0].Groups['sha'].Value).ToUpperInvariant()
}

function Assert-ExactRc8Identity {
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262' -and
        $script:StablePackage -ceq 'com.qcxr.qcxr.dev262' -and
        $script:Package -cne $script:StablePackage) 'The Lab/Stable boundary drifted.'
    Read-PackageIdentity
    $base = Read-InstalledBasePath
    Require ((Read-RemoteSha256 $base) -ceq $script:ApkSha256) 'The installed Lab APK digest is not exact RC8.'
    Require ((Read-RemoteSha256 $script:CorePath) -ceq $script:CoreSha256) 'The persistent Core is not exact RC8.'
    Require ((Read-RemoteSha256 $script:VeqPath) -ceq $script:VeqSha256) 'The persistent VEQ is not exact RC8.'
    $temp = New-SafeTempDirectory
    try {
        $apk = Join-Path $temp 'installed-base.apk'
        Invoke-PullReadOnly -Remote $base -Local $apk -ExpectedSha256 $script:ApkSha256
        Require ((Read-SignerFromApk $apk) -ceq $script:SignerSha256) `
            'The installed Lab signer is not the locked RC8 signer.'
    } finally { Remove-SafeTempDirectory $temp }
}

function Assert-LabStopped {
    $result = Invoke-ShellRead @('pidof',$script:Package) -AllowFailure
    Require ([string]::IsNullOrWhiteSpace([string]$result.Stderr)) 'The Lab process probe emitted stderr.'
    $pids = @($result.Stdout -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ([int]$result.ExitCode -eq 1 -and $pids.Count -eq 0) { return }
    if ([int]$result.ExitCode -eq 0 -and $pids.Count -ge 1 -and
        @($pids | Where-Object { $_ -cnotmatch '^[0-9]+$' }).Count -eq 0) {
        throw '[RC8_RENDER_SCALE_AB] Lab is running; stop it manually before changing render scale.'
    }
    throw '[RC8_RENDER_SCALE_AB] The Lab process state is ambiguous.'
}

function Read-RemoteFileBytes {
    param([Parameter(Mandatory)][string] $RemotePath)
    $temp = New-SafeTempDirectory
    try {
        $local = Join-Path $temp 'remote.bin'
        $remoteSha = Read-RemoteSha256 $RemotePath
        Invoke-PullReadOnly -Remote $RemotePath -Local $local -ExpectedSha256 $remoteSha
        [IO.File]::ReadAllBytes($local)
    } finally { Remove-SafeTempDirectory $temp }
}

function Get-ScaleValueFromBytes {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    try {
        $text = $script:Utf8Strict.GetString($Bytes)
        $json = $text | ConvertFrom-Json -Depth 100
    } catch {
        throw "[RC8_RENDER_SCALE_AB] Vivecraft config is not strict UTF-8 JSON: $($_.Exception.Message)"
    }
    $property = $json.PSObject.Properties['renderScaleFactor']
    Require ($null -ne $property -and $property.Value -is [string]) `
        'renderScaleFactor is absent or is not a string.'
    [string]$property.Value
}

function New-Scale08Candidate {
    param([Parameter(Mandatory)][byte[]] $Original)
    $text = $script:Utf8Strict.GetString($Original)
    Require ((Get-ScaleValueFromBytes $Original) -ceq '1.0') `
        'Arm requires renderScaleFactor to be exactly 1.0.'
    $pattern = '(?<prefix>"renderScaleFactor"\s*:\s*)"1\.0"'
    $matches = @([regex]::Matches($text, $pattern,
        [Text.RegularExpressions.RegexOptions]::CultureInvariant))
    Require ($matches.Count -eq 1) 'The exact renderScaleFactor field was absent or ambiguous.'
    $candidateText = [regex]::Replace($text, $pattern, '${prefix}"0.8"', 1)
    $candidate = $script:Utf8NoBom.GetBytes($candidateText)
    # A BOM would make a byte-preserving single-field transaction ambiguous.
    Require ($Original.Length -eq $candidate.Length) 'The candidate changed the config byte length.'
    Require ((Get-ScaleValueFromBytes $candidate) -ceq '0.8') 'The candidate scale did not parse as 0.8.'
    $roundTrip = [regex]::Replace($candidateText,
        '(?<prefix>"renderScaleFactor"\s*:\s*)"0\.8"', '${prefix}"1.0"', 1)
    Require ($roundTrip -ceq $text) 'The candidate changed bytes outside renderScaleFactor.'
    $candidate
}

function Invoke-PushWrite {
    param([Parameter(Mandatory)][string] $Local, [Parameter(Mandatory)][string] $Remote)
    Require ($Remote -cmatch ('^' + [regex]::Escape($script:ConfigPath) +
            '\.next-[0-9a-f]{32}$')) `
        'A push target escaped the fixed config staging namespace.'
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'push',$Local,$Remote) -Write
    Require ([int]$result.ExitCode -eq 0) 'The config staging push failed.'
    # Native adb commonly reports a successful push on stderr. The staged
    # digest is verified immediately by Publish-RemoteReplacement; accept only
    # bounded, recognized transfer progress and never surface or persist it.
    Assert-BoundedPushChatter -Stdout ([string]$result.Stdout) -Stderr ([string]$result.Stderr)
}

function Invoke-AtomicMoveWrite {
    param([Parameter(Mandatory)][string] $RemoteStage)
    Require ($RemoteStage -cmatch ('^' + [regex]::Escape($script:ConfigPath) +
            '\.next-[0-9a-f]{32}$')) `
        'An atomic source escaped the fixed config staging namespace.'
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'shell','mv',$RemoteStage,$script:ConfigPath) -Write
    Assert-AdbSuccess $result 'The same-directory atomic config replacement'
}

function Invoke-StageModeWrite {
    param([Parameter(Mandatory)][string] $RemoteStage)
    Require ($RemoteStage -cmatch ('^' + [regex]::Escape($script:ConfigPath) +
            '\.next-[0-9a-f]{32}$')) `
        'A mode target escaped the fixed config staging namespace.'
    # adb push creates scoped-storage files as the shell uid with mode 0644.
    # The Quest process then cannot rewrite Vivecraft's configuration. Make
    # only our verified staging file group-writable before the atomic move;
    # Android already assigns the fixed ext_data_rw group to this directory.
    $result = Invoke-AdbRaw @(
        '-s',$script:ResolvedSerial,'shell','chmod','0660',$RemoteStage) -Write
    Assert-AdbSuccess $result 'The staged config mode correction'
    Require ((Read-RemoteMode $RemoteStage).TrimStart('0') -ceq '660') `
        'The staged config did not become group-writable.'
}

function New-RemoteStagePath {
    "$($script:ConfigPath).next-$([Guid]::NewGuid().ToString('N'))"
}

function New-LocalPushFile {
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][string] $Leaf)
    $temp = New-SafeTempDirectory
    $path = Join-Path $temp $Leaf
    [IO.File]::WriteAllBytes($path, $Bytes)
    [pscustomobject]@{ Directory = $temp; Path = $path }
}

function Publish-RemoteReplacement {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $ExpectedCurrentSha,
        [Parameter(Mandatory)][string] $ExpectedNewSha
    )
    $push = New-LocalPushFile -Bytes $Bytes -Leaf 'replacement.bin'
    $stage = New-RemoteStagePath
    try {
        Invoke-PushWrite -Local $push.Path -Remote $stage
        Require ((Read-RemoteSha256 $stage) -ceq $ExpectedNewSha) `
            'The staged config digest mismatched before atomic replacement.'
        Invoke-StageModeWrite -RemoteStage $stage
        Assert-LabStopped
        Assert-ExactRc8Identity
        Require ((Read-RemoteSha256 $script:ConfigPath) -ceq $ExpectedCurrentSha) `
            'The live config changed before atomic replacement.'
        # Revalidate the exact stage after every slow identity/current-file
        # probe. A different ADB actor must not be able to alter the staged
        # bytes or mode in the interval between the initial checks and publish.
        Require ((Read-RemoteSha256 $stage) -ceq $ExpectedNewSha) `
            'The staged config changed before atomic replacement.'
        Require ((Read-RemoteMode $stage).TrimStart('0') -ceq '660') `
            'The staged config lost its writable mode before atomic replacement.'
        # Narrow the manual-launch race after the final stage probes. The user
        # must still leave Lab stopped for the transaction.
        Assert-LabStopped
        Invoke-AtomicMoveWrite -RemoteStage $stage
        Require ((Read-RemoteSha256 $script:ConfigPath) -ceq $ExpectedNewSha) `
            'The live config digest mismatched after atomic replacement.'
        Require ((Read-RemoteMode $script:ConfigPath).TrimStart('0') -ceq '660') `
            'The live config lost its writable mode after atomic replacement.'
    } finally { Remove-SafeTempDirectory $push.Directory }
}

function New-TransactionState {
    param([string] $Status, [string] $SourceSha, [string] $CandidateSha)
    [ordered]@{
        schemaVersion = 1
        status = $Status
        package = $script:Package
        stablePackageDenied = $script:StablePackage
        profile = $script:Profile
        serial = $script:ResolvedSerial
        versionCode = $script:VersionCode
        versionName = $script:VersionName
        apkSha256 = $script:ApkSha256
        signerSha256 = $script:SignerSha256
        coreSha256 = $script:CoreSha256
        veqSha256 = $script:VeqSha256
        configRemotePath = $script:ConfigPath
        sourceScale = '1.0'
        candidateScale = '0.8'
        sourceSha256 = $SourceSha
        candidateSha256 = $CandidateSha
        onlySemanticChange = 'renderScaleFactor:1.0->0.8'
        stableTouched = $false
        rootUsed = $false
        packageManagerUsed = $false
        accountWorldModResourcePackTouched = $false
    }
}

function Assert-TransactionFiles {
    param([Parameter(Mandatory)] $State)
    Require (Test-Path -LiteralPath $script:OriginalPath -PathType Leaf) 'The byte-exact original backup is missing.'
    Require (Test-Path -LiteralPath $script:CandidatePath -PathType Leaf) 'The byte-exact candidate is missing.'
    Assert-NoReparseComponents $script:OriginalPath
    Assert-NoReparseComponents $script:CandidatePath
    Require ((Get-FileSha256 $script:OriginalPath) -ceq [string]$State.sourceSha256) `
        'The original backup digest mismatched.'
    Require ((Get-FileSha256 $script:CandidatePath) -ceq [string]$State.candidateSha256) `
        'The candidate backup digest mismatched.'
    Require ((Get-ScaleValueFromBytes ([IO.File]::ReadAllBytes($script:OriginalPath))) -ceq '1.0') `
        'The original backup no longer contains scale 1.0.'
    Require ((Get-ScaleValueFromBytes ([IO.File]::ReadAllBytes($script:CandidatePath))) -ceq '0.8') `
        'The candidate backup no longer contains scale 0.8.'
}

function Assert-TransactionStateIdentity {
    param([Parameter(Mandatory)] $State)
    Require ([int]$State.schemaVersion -eq 1 -and
        [string]$State.package -ceq $script:Package -and
        [string]$State.stablePackageDenied -ceq $script:StablePackage -and
        [string]$State.profile -ceq $script:Profile -and
        [string]$State.serial -ceq $script:ResolvedSerial -and
        [int64]$State.versionCode -eq $script:VersionCode -and
        [string]$State.versionName -ceq $script:VersionName -and
        [string]$State.apkSha256 -ceq $script:ApkSha256 -and
        [string]$State.signerSha256 -ceq $script:SignerSha256 -and
        [string]$State.coreSha256 -ceq $script:CoreSha256 -and
        [string]$State.veqSha256 -ceq $script:VeqSha256 -and
        [string]$State.configRemotePath -ceq $script:ConfigPath -and
        [string]$State.sourceScale -ceq '1.0' -and
        [string]$State.candidateScale -ceq '0.8' -and
        [string]$State.onlySemanticChange -ceq 'renderScaleFactor:1.0->0.8' -and
        -not [bool]$State.stableTouched -and -not [bool]$State.rootUsed -and
        -not [bool]$State.packageManagerUsed -and
        -not [bool]$State.accountWorldModResourcePackTouched) `
        'The local render-scale transaction identity drifted.'
}

function Invoke-Status {
    Resolve-ExactDevice
    Assert-ExactRc8Identity
    $runningProbe = Invoke-ShellRead @('pidof',$script:Package) -AllowFailure
    $running = [int]$runningProbe.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$runningProbe.Stdout)
    Require (($running -and $runningProbe.Stdout.Trim() -cmatch '^[0-9]+(?:\s+[0-9]+)*$') -or
        (-not $running -and [int]$runningProbe.ExitCode -eq 1 -and
            [string]::IsNullOrWhiteSpace([string]$runningProbe.Stdout))) `
        'The Lab process state is ambiguous.'
    $bytes = Read-RemoteFileBytes $script:ConfigPath
    $scale = Get-ScaleValueFromBytes $bytes
    $hash = Get-BytesSha256 $bytes
    $mode = Read-RemoteMode $script:ConfigPath
    $state = Read-State
    $transaction = if ($null -eq $state) { 'NONE' } else { [string]$state.status }
    if ($null -ne $state) {
        Assert-TransactionStateIdentity $state
        Assert-TransactionFiles $state
    }
    [pscustomobject][ordered]@{
        Result = 'STATUS_OK'
        Action = 'Status'
        Package = $script:Package
        ForbiddenStablePackage = $script:StablePackage
        VersionCode = $script:VersionCode
        VersionName = $script:VersionName
        ApkSha256 = $script:ApkSha256
        SignerSha256 = $script:SignerSha256
        CoreSha256 = $script:CoreSha256
        VeqSha256 = $script:VeqSha256
        LabRunning = $running
        RenderScaleFactor = $scale
        ConfigSha256 = $hash
        ConfigMode = $mode
        Transaction = $transaction
        DeviceWrites = 0
        StableTouched = $false
    }
}

function Invoke-Arm {
    Require $AllowDeviceWrite.IsPresent 'Arm requires explicit -AllowDeviceWrite.'
    $existingState = Read-State
    if ($null -ne $existingState) {
        Require ([string]$existingState.status -ceq 'RESTORED') `
            'An active render-scale transaction already exists; use Status/Restore.'
        Resolve-ExactDevice
        Assert-TransactionStateIdentity $existingState
        Assert-TransactionFiles $existingState
        Assert-LabStopped
        Assert-ExactRc8Identity
        $live = Read-RemoteFileBytes $script:ConfigPath
        Require ((Get-BytesSha256 $live) -ceq [string]$existingState.sourceSha256 -and
            (Get-ScaleValueFromBytes $live) -ceq '1.0') `
            'Re-arm requires the byte-exact restored source config.'
        $rearmCandidate = [IO.File]::ReadAllBytes($script:CandidatePath)
        Publish-RemoteReplacement -Bytes $rearmCandidate `
            -ExpectedCurrentSha ([string]$existingState.sourceSha256) `
            -ExpectedNewSha ([string]$existingState.candidateSha256)
        $existingState.status = 'ARMED'
        Write-AtomicState $existingState
        return [pscustomobject][ordered]@{
            Result = 'ARMED'; Action = 'Arm'; Package = $script:Package
            RenderScaleFactor = '0.8'
            OriginalSha256 = [string]$existingState.sourceSha256
            ActiveSha256 = [string]$existingState.candidateSha256
            BackupPath = $script:OriginalPath
            DeviceWrites = $script:DeviceWriteCount; StableTouched = $false
        }
    }
    Require (-not (Test-Path -LiteralPath $script:OriginalPath) -and
        -not (Test-Path -LiteralPath $script:CandidatePath)) `
        'Transaction artifacts exist without a state file; Arm refused.'
    Resolve-ExactDevice
    Assert-LabStopped
    Assert-ExactRc8Identity
    $original = Read-RemoteFileBytes $script:ConfigPath
    $sourceSha = Get-BytesSha256 $original
    Require ((Read-RemoteSha256 $script:ConfigPath) -ceq $sourceSha) `
        'The pulled original did not match the current remote config.'
    $candidate = New-Scale08Candidate $original
    $candidateSha = Get-BytesSha256 $candidate
    Require ($candidateSha -cne $sourceSha) 'The candidate unexpectedly equals the original.'
    Write-AtomicHostBytes -Path $script:OriginalPath -Bytes $original -RefuseExisting
    Write-AtomicHostBytes -Path $script:CandidatePath -Bytes $candidate -RefuseExisting
    $state = New-TransactionState -Status 'BACKUP_READY' -SourceSha $sourceSha -CandidateSha $candidateSha
    Write-AtomicState $state -RefuseExisting
    Assert-TransactionFiles (Read-State)
    try {
        Publish-RemoteReplacement -Bytes $candidate -ExpectedCurrentSha $sourceSha `
            -ExpectedNewSha $candidateSha
        $state.status = 'ARMED'
        Write-AtomicState $state
    } catch {
        $armError = $_
        $current = $null
        try { $current = Read-RemoteSha256 $script:ConfigPath } catch { }
        # Recover automatically only from our exact candidate. An unknown
        # digest may be an external edit; even during an authorized Arm it is
        # safer to preserve those bytes and retain the exact local backup than
        # to overwrite drift speculatively.
        if ($null -ne $current -and $current -ceq $candidateSha) {
            try {
                Publish-RemoteReplacement -Bytes $original -ExpectedCurrentSha $candidateSha `
                    -ExpectedNewSha $sourceSha
                $state.status = 'RECOVERED'
                Write-AtomicState $state
            } catch {
                throw "[RC8_RENDER_SCALE_AB] Arm failed and emergency restore also failed. Original backup: $script:OriginalPath. Arm error: $($armError.Exception.Message); restore error: $($_.Exception.Message)"
            }
        } elseif ($null -ne $current -and $current -cne $sourceSha) {
            throw "[RC8_RENDER_SCALE_AB] Arm failed and the live config has unknown drift; automatic restore refused. Original backup: $script:OriginalPath. Arm error: $($armError.Exception.Message)"
        }
        throw $armError
    }
    [pscustomobject][ordered]@{
        Result = 'ARMED'
        Action = 'Arm'
        Package = $script:Package
        RenderScaleFactor = '0.8'
        OriginalSha256 = $sourceSha
        ActiveSha256 = $candidateSha
        BackupPath = $script:OriginalPath
        DeviceWrites = $script:DeviceWriteCount
        StableTouched = $false
    }
}

function Invoke-Restore {
    Require $AllowDeviceWrite.IsPresent 'Restore requires explicit -AllowDeviceWrite.'
    $state = Read-State
    Require ($null -ne $state) 'There is no render-scale transaction to restore.'
    Require ([string]$state.status -cin @('ARMED','BACKUP_READY','RECOVERED')) `
        'Restore requires an active or recoverable transaction.'
    Assert-TransactionFiles $state
    Resolve-ExactDevice
    Assert-TransactionStateIdentity $state
    Assert-LabStopped
    Assert-ExactRc8Identity
    $current = Read-RemoteFileBytes $script:ConfigPath
    $currentSha = Get-BytesSha256 $current
    $original = [IO.File]::ReadAllBytes($script:OriginalPath)
    if ($currentSha -ceq [string]$state.sourceSha256 -and
            (Get-ScaleValueFromBytes $current) -ceq '1.0') {
        # Failed/pre-move Arm or emergency recovery already left exact source
        # bytes active. Explicit Restore reconciles state without device writes.
    } elseif ($currentSha -ceq [string]$state.candidateSha256 -and
            (Get-ScaleValueFromBytes $current) -ceq '0.8') {
        Publish-RemoteReplacement -Bytes $original `
            -ExpectedCurrentSha ([string]$state.candidateSha256) `
            -ExpectedNewSha ([string]$state.sourceSha256)
    } else {
        throw '[RC8_RENDER_SCALE_AB] The active config drifted; Restore refused to overwrite unknown bytes.'
    }
    $roundTrip = Read-RemoteFileBytes $script:ConfigPath
    Require ((Get-BytesSha256 $roundTrip) -ceq [string]$state.sourceSha256 -and
        [Convert]::ToBase64String($roundTrip) -ceq [Convert]::ToBase64String($original)) `
        'Restore did not reproduce the exact original bytes.'
    $state.status = 'RESTORED'
    Write-AtomicState $state
    [pscustomobject][ordered]@{
        Result = 'RESTORED'
        Action = 'Restore'
        Package = $script:Package
        RenderScaleFactor = '1.0'
        RestoredSha256 = [string]$state.sourceSha256
        ByteExact = $true
        DeviceWrites = $script:DeviceWriteCount
        StableTouched = $false
    }
}

function Invoke-Rc8RenderScaleAb {
    $script:DeviceReadCount = 0
    $script:DeviceWriteCount = 0
    $script:ResolvedAdb = $null
    $script:ResolvedSigner = $null
    $script:ResolvedSerial = $null
    Require ($script:ConfigPath -ceq
        '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/config/vivecraft-client-config.json') `
        'The fixed config target drifted.'
    Require (-not $script:ConfigPath.Contains($script:StablePackage,
        [StringComparison]::Ordinal)) 'Stable appeared in the mutation target.'
    switch ($Action) {
        'Status' {
            Require (-not $AllowDeviceWrite.IsPresent) `
                'Status rejects -AllowDeviceWrite so its read-only boundary is explicit.'
            Invoke-Status
        }
        'Arm' { Invoke-Arm }
        'Restore' { Invoke-Restore }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $lease = Enter-TransactionMutex
    try { Invoke-Rc8RenderScaleAb }
    finally { Exit-TransactionMutex $lease }
}
