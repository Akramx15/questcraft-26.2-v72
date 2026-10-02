#requires -Version 7.0
<#
.SYNOPSIS
Fail-closed rollback gate for the exact v71 RC7 Lab APK.

.DESCRIPTION
The default mode is a Host-only artifact audit and never resolves ADB. With
-Rollback, the gate accepts only the fixed Lab package and exact reviewed RC7
APK, proves the installed Lab signer before replacement, requires the Lab to
be stopped twice, invokes exactly `adb -s <serial> install -r <fixed-apk>`, and
fully verifies the pulled installed APK afterward. It has no Stable, launch,
uninstall, clear-data, downgrade, root, network-discovery, or profile path.
#>
[CmdletBinding()]
param(
    [switch] $Rollback,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [string] $ApkSignerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:LabPackage = 'com.qcxr.qcxr.canary262'
$script:ForbiddenStablePackage = 'com.qcxr.qcxr.dev262'
$script:CandidatePath = Join-Path $script:WorkspaceRoot `
    'work\agent-v70-integration\QCXR-XR-Wrapper\Builds\QuestCraft-Vivecraft-Lab-26.2-v71-rc.7-integrated-local.apk'
$script:VerifierPath = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$script:ExpectedVerifierSha256 = '98A2DF7E1C91BF259C1A789CCF7C1369EC1F69037862FCA867426579A9B5D501'
$script:ExpectedApkSha256 = '6AC3D0A1EECAE657367B427BF9A97983C68F6A0D01E166DD195694E3B0B0E7D7'
$script:ExpectedApkSizeBytes = 128468737L
$script:ExpectedVersionCode = 71
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.7'
$script:ExpectedLabel = 'QuestCraft Vivecraft Lab 26.2'
$script:ExpectedSignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedCoreSha256 = 'A1A522C2BB949DBDC2A3AE475B900407324441DA50D94E012A7C734B32E498D3'
$script:ExpectedCoreVersion = '26.2-1.3.15+qc.v71.rc7'
$script:ExpectedVeqSha256 = 'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
$script:ExpectedVeqVersion = '0.7.0-v71.rc6'
$script:ExpectedLwjglSha256 = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
$script:ResolvedAdb = $null
$script:ResolvedApkSigner = $null
$script:ResolvedSerial = $null
$script:DeviceInvocationCount = 0

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC7_LAB_ROLLBACK] $Message" }
}

function Get-CanonicalPath([Parameter(Mandatory)][string] $Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Get-Sha256([Parameter(Mandatory)][string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-NoReparsePoint([Parameter(Mandatory)][string] $Path) {
    $full = Get-CanonicalPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($part in $full.Substring($root.Length).Split(
            [IO.Path]::DirectorySeparatorChar,
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) "Protected path is a reparse point: $current"
        }
    }
}

function Invoke-ProcessCapture(
    [Parameter(Mandatory)][string] $FileName,
    [Parameter(Mandatory)][string[]] $Arguments
) {
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
        Require $process.Start() "Could not start process: $FileName"
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult()
            Stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-LabBoundary {
    Require ($script:LabPackage -ceq 'com.qcxr.qcxr.canary262') 'Lab package pin drifted.'
    Require ($script:ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262') 'Stable deny pin drifted.'
    Require ($script:LabPackage -cne $script:ForbiddenStablePackage) 'Lab and Stable packages collided.'
}

function Invoke-ApkVerifier([Parameter(Mandatory)][string] $ApkPath) {
    Require (Test-Path -LiteralPath $script:VerifierPath -PathType Leaf) 'APK verifier is missing.'
    Require ((Get-Sha256 $script:VerifierPath) -ceq $script:ExpectedVerifierSha256) `
        'APK verifier drifted from the reviewed rollback verifier.'
    $values = @(& $script:VerifierPath -ApkPath $ApkPath `
        -ExpectedPackage $script:LabPackage `
        -ExpectedVersionCode ([string]$script:ExpectedVersionCode) `
        -ExpectedVersionName $script:ExpectedVersionName `
        -ExpectedLabel $script:ExpectedLabel `
        -ExpectedVivecraftSha256 $script:ExpectedCoreSha256 `
        -ExpectedVivecraftVersion $script:ExpectedCoreVersion `
        -ExpectedAddOnSha256 $script:ExpectedVeqSha256 `
        -ExpectedAddOnVersion $script:ExpectedVeqVersion `
        -ExpectedLwjglSha256 $script:ExpectedLwjglSha256 `
        -ExpectedSignerSha256 $script:ExpectedSignerSha256)
    $objects = @($values | Where-Object {
        $null -ne $_.PSObject.Properties['Sha256'] -and
        $null -ne $_.PSObject.Properties['SignerSha256']
    })
    Require ($objects.Count -eq 1) 'APK verifier returned an ambiguous result.'
    $objects[0]
}

function Assert-ExactRc7Apk(
    [Parameter(Mandatory)][string] $Path,
    [string] $Context,
    [switch] $RequireFixedCandidatePath
) {
    Assert-LabBoundary
    $full = Get-CanonicalPath $Path
    if ($RequireFixedCandidatePath.IsPresent) {
        Require ($full -ceq (Get-CanonicalPath $script:CandidatePath)) "$Context path drifted."
    }
    Assert-NoReparsePoint $full
    Require (Test-Path -LiteralPath $full -PathType Leaf) "$Context is missing."
    Require ((Get-Item -LiteralPath $full).Length -eq $script:ExpectedApkSizeBytes) "$Context size mismatched."
    Require ((Get-Sha256 $full) -ceq $script:ExpectedApkSha256) "$Context SHA-256 mismatched."
    $verified = Invoke-ApkVerifier $full
    Require ([string]$verified.Package -ceq $script:LabPackage) "$Context package mismatched."
    Require ([int]$verified.VersionCode -eq $script:ExpectedVersionCode) "$Context versionCode mismatched."
    Require ([string]$verified.VersionName -ceq $script:ExpectedVersionName) "$Context versionName mismatched."
    Require (([string]$verified.SignerSha256).ToUpperInvariant() -ceq $script:ExpectedSignerSha256) "$Context signer mismatched."
    Require ([bool]$verified.SignatureV2 -and [bool]$verified.Zipalign16KiB) "$Context signature/alignment failed."
    [pscustomobject]@{
        Path = $full
        Sha256 = ([string]$verified.Sha256).ToUpperInvariant()
        Package = [string]$verified.Package
        VersionCode = [int]$verified.VersionCode
        VersionName = [string]$verified.VersionName
        SignerSha256 = ([string]$verified.SignerSha256).ToUpperInvariant()
    }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) { return (Resolve-Path -LiteralPath $AdbPath).Path }
    $command = Get-Command $AdbPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    throw '[V71_RC7_LAB_ROLLBACK] ADB was not found; pass its absolute path.'
}

function Resolve-ApkSigner {
    if (-not [string]::IsNullOrWhiteSpace($ApkSignerPath)) {
        Require (Test-Path -LiteralPath $ApkSignerPath -PathType Leaf) 'Requested apksigner is missing.'
        return (Resolve-Path -LiteralPath $ApkSignerPath).Path
    }
    $command = Get-Command 'apksigner.bat' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    $sdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools'
    $candidate = @(Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $tool = Join-Path $_.FullName 'apksigner.bat'
            if (Test-Path -LiteralPath $tool -PathType Leaf) {
                [pscustomobject]@{ Version = [version]$_.Name; Path = $tool }
            }
        } | Sort-Object Version -Descending | Select-Object -First 1)
    Require ($candidate.Count -eq 1) 'Android SDK apksigner was not found.'
    [string]$candidate[0].Path
}

function Invoke-AdbRaw([Parameter(Mandatory)][string[]] $Arguments) {
    Require (-not [string]::IsNullOrWhiteSpace([string]$script:ResolvedAdb)) 'ADB is unresolved.'
    $script:DeviceInvocationCount++
    Invoke-ProcessCapture $script:ResolvedAdb $Arguments
}

function Resolve-ExactDevice {
    $script:ResolvedAdb = Resolve-Adb
    $result = Invoke-AdbRaw @('devices')
    Require ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stderr)) 'ADB device enumeration failed.'
    $records = @($result.Stdout -split "`r?`n" | ForEach-Object {
        if ($_ -match '^(?<serial>\S+)\s+(?<state>\S+)(?:\s+.*)?$' -and $_ -notmatch '^List of devices') {
            [pscustomobject]@{ Serial = $Matches.serial; State = $Matches.state }
        }
    })
    if ($Serial -ceq 'auto') {
        Require ($records.Count -eq 1) 'Auto mode requires exactly one endpoint.'
        $chosen = $records[0]
    } else {
        $matches = @($records | Where-Object { $_.Serial -ceq $Serial })
        Require ($matches.Count -eq 1) 'Requested endpoint was not present exactly once.'
        $chosen = $matches[0]
    }
    Require ([string]$chosen.State -ceq 'device') 'Selected endpoint is not authorized and ready.'
    $script:ResolvedSerial = [string]$chosen.Serial
    $state = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'get-state')
    Require ($state.ExitCode -eq 0 -and $state.Stdout.Trim() -ceq 'device' -and
        [string]::IsNullOrWhiteSpace($state.Stderr)) 'Selected endpoint state check failed.'
}

function Assert-LabStopped {
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'shell','pidof',$script:LabPackage)
    Require ([string]::IsNullOrWhiteSpace($result.Stderr)) 'Lab process check emitted stderr.'
    $pids = @($result.Stdout -split '\s+' | Where-Object { $_ })
    if ($result.ExitCode -eq 1 -and $pids.Count -eq 0) { return }
    if ($result.ExitCode -eq 0 -and $pids.Count -ge 1 -and
        @($pids | Where-Object { $_ -cnotmatch '^[0-9]+$' }).Count -eq 0) {
        throw '[V71_RC7_LAB_ROLLBACK] Lab is running; the user must exit before rollback.'
    }
    throw '[V71_RC7_LAB_ROLLBACK] Lab process state was ambiguous.'
}

function Read-InstalledBaseApkPath {
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'shell','pm','path',$script:LabPackage)
    Require ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stderr)) 'Lab base.apk lookup failed.'
    $rows = @($result.Stdout -split "`r?`n" | Where-Object { $_ })
    Require ($rows.Count -eq 1) 'Lab package is absent, split, or ambiguous.'
    $match = [regex]::Match($rows[0], '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$')
    Require $match.Success 'Lab base.apk path was malformed.'
    $path = $match.Groups['path'].Value
    Require ($path -cmatch ('/' + [regex]::Escape($script:LabPackage) + '(?:-|/)') -and
        -not $path.Contains('..') -and -not $path.Contains('\')) 'Lab base.apk path escaped package boundary.'
    $path
}

function Invoke-Pull([string] $Remote, [string] $Local) {
    Require (-not (Test-Path -LiteralPath $Local)) 'Pull destination already exists.'
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'pull',$Remote,$Local)
    Require ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $Local -PathType Leaf) -and
        (Get-Item -LiteralPath $Local).Length -gt 0) 'Installed APK pull failed.'
}

function Get-InstalledSigner([string] $ApkPath) {
    $result = Invoke-ProcessCapture $script:ResolvedApkSigner @('verify','--verbose','--print-certs',(Get-CanonicalPath $ApkPath))
    Require ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stderr)) 'apksigner rejected installed Lab APK.'
    $certificateMatches = [regex]::Matches($result.Stdout,
        '(?im)^Signer #(?<index>[0-9]+) certificate SHA-256 digest:\s*(?<sha>[0-9a-f]{64})\s*$')
    Require ($certificateMatches.Count -eq 1 -and
        $certificateMatches.Item(0).Groups['index'].Value -ceq '1') 'Installed signer was ambiguous.'
    Require ($result.Stdout -cmatch '(?m)^Verified using v2 scheme \(APK Signature Scheme v2\): true\s*$') 'Installed APK lacks v2 verification.'
    $certificateMatches.Item(0).Groups['sha'].Value.ToUpperInvariant()
}

function New-SafeTempDirectory {
    $root = Get-CanonicalPath ([IO.Path]::GetTempPath())
    $path = Join-Path $root ('quest-v71-rc7-rollback-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $path
}

function Remove-SafeTempDirectory([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $root = Get-CanonicalPath ([IO.Path]::GetTempPath())
    $full = Get-CanonicalPath $Path
    Require ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'Temp cleanup escaped Temp.'
    Require ([IO.Path]::GetFileName($full).StartsWith('quest-v71-rc7-rollback-',
        [StringComparison]::Ordinal)) 'Temp cleanup target was unexpected.'
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Force)) {
        Require (-not $item.PSIsContainer) 'Rollback Temp unexpectedly contains a directory.'
        Remove-Item -LiteralPath $item.FullName -Force
    }
    Remove-Item -LiteralPath $full -Force
}

function Invoke-Rc7RollbackGate {
    $script:DeviceInvocationCount = 0
    Assert-LabBoundary
    $candidate = Assert-ExactRc7Apk $script:CandidatePath 'RC7 rollback APK' -RequireFixedCandidatePath
    if (-not $Rollback.IsPresent) {
        return [pscustomobject]@{
            Result = 'AUDIT_PASS'; HostOnly = $true; RollbackRequested = $false
            Package = $candidate.Package; ForbiddenStablePackage = $script:ForbiddenStablePackage
            VersionCode = $candidate.VersionCode; VersionName = $candidate.VersionName
            ApkPath = $candidate.Path; ApkSha256 = $candidate.Sha256
            SignerSha256 = $candidate.SignerSha256; DeviceInvocations = 0
            StableTouched = $false; Launched = $false
        }
    }

    $readLock = [IO.File]::Open($candidate.Path,[IO.FileMode]::Open,
        [IO.FileAccess]::Read,[IO.FileShare]::Read)
    $temp = $null
    try {
        Resolve-ExactDevice
        Assert-LabStopped
        $script:ResolvedApkSigner = Resolve-ApkSigner
        $temp = New-SafeTempDirectory
        $before = Join-Path $temp 'installed-before.apk'
        Invoke-Pull (Read-InstalledBaseApkPath) $before
        Require ((Get-InstalledSigner $before) -ceq $script:ExpectedSignerSha256) `
            'Installed Lab signer mismatched; rollback blocked before mutation.'
        Assert-LabStopped
        Require ($readLock.Length -eq $script:ExpectedApkSizeBytes) 'Locked RC7 APK size drifted.'
        $readLock.Position = 0
        $lockedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($readLock))
        $readLock.Position = 0
        Require ($lockedHash -ceq $script:ExpectedApkSha256) 'Locked RC7 APK bytes drifted.'
        $install = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'install','-r',$candidate.Path)
        Require ($install.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($install.Stderr) -and
            @($install.Stdout -split "`r?`n" | Where-Object { $_.Trim() -ceq 'Success' }).Count -eq 1) `
            'Android rejected exact RC7 install -r.'
        $after = Join-Path $temp 'installed-after.apk'
        Invoke-Pull (Read-InstalledBaseApkPath) $after
        $afterAudit = Assert-ExactRc7Apk $after 'Post-rollback installed Lab APK'
        [pscustomobject]@{
            Result = 'ROLLED_BACK_AND_VERIFIED'; HostOnly = $false; RollbackRequested = $true
            Package = $afterAudit.Package; ForbiddenStablePackage = $script:ForbiddenStablePackage
            VersionCode = $afterAudit.VersionCode; VersionName = $afterAudit.VersionName
            ApkSha256 = $afterAudit.Sha256; SignerSha256 = $afterAudit.SignerSha256
            DeviceInvocations = $script:DeviceInvocationCount; StableTouched = $false; Launched = $false
            InstallCommand = 'adb install -r only'
        }
    } finally {
        if ($null -ne $temp) { Remove-SafeTempDirectory $temp }
        $readLock.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Rc7RollbackGate }
