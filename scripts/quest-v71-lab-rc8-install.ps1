#requires -Version 7.0
<#
.SYNOPSIS
Fail-closed deployment gate for the exact v71 RC8 Lab APK.

.DESCRIPTION
Without -Install this script performs a Host-only audit and never resolves or
invokes ADB. With -Install it requires one explicitly selected/auto-selected
authorized endpoint, proves the already-installed Lab APK has the expected
signer, performs exactly `adb -s <serial> install -r <fixed-apk>`, and verifies
the installed base.apk after replacement. It has no Stable, uninstall, data
clear, root, network, or launch path.
#>
[CmdletBinding()]
param(
    [switch] $Install,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [string] $ApkSignerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LabPackage = 'com.qcxr.qcxr.canary262'
$script:ForbiddenStablePackage = 'com.qcxr.qcxr.dev262'
$script:LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC8.lock.json'
$script:VerifierPath = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$script:ApkRelativePath = 'QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.8-mining-local.apk'
$script:ExpectedApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$script:ExpectedApkSizeBytes = 128469341L
$script:ExpectedVersionCode = 71
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'
$script:ExpectedLabel = 'QuestCraft Vivecraft Lab 26.2'
$script:ExpectedSignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedCoreSha256 = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$script:ExpectedCoreVersion = '26.2-1.3.15+qc.v71.rc8-mining'
$script:ExpectedVeqSha256 = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$script:ExpectedVeqVersion = '0.7.0-v71.rc6'
$script:ExpectedLwjglSha256 = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
$script:ExpectedVerifierSha256 = '98A2DF7E1C91BF259C1A789CCF7C1369EC1F69037862FCA867426579A9B5D501'

$script:ResolvedAdb = $null
$script:ResolvedApkSigner = $null
$script:ResolvedSerial = $null
$script:DeviceInvocationCount = 0

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_RC8_LAB_INSTALL] $Message" }
}

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string] $Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-PathContained {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )
    $full = Get-CanonicalPath $Path
    $fullRoot = Get-CanonicalPath $Root
    Require ($full.StartsWith(
        $fullRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) "A Host path escaped its fixed root: $full"
    return $full
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )
    $fullRoot = Get-CanonicalPath $Root
    $full = Assert-PathContained -Path $Path -Root $Root
    $relative = [IO.Path]::GetRelativePath($fullRoot, $full)
    $current = $fullRoot
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) "A protected Host path is a reparse point: $current"
        }
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-ExactValue {
    param($Actual, $Expected, [string] $Context)
    if ($Expected -is [string]) {
        Require ($Actual -is [string] -and [string]$Actual -ceq [string]$Expected) "$Context drifted."
    } else {
        Require ($Actual -eq $Expected) "$Context drifted."
    }
}

function Get-RequiredProperty {
    param($Object, [string] $Name, [string] $Context)
    Require ($null -ne $Object) "$Context is absent."
    $property = $Object.PSObject.Properties[$Name]
    Require ($null -ne $property) "$Context.$Name is absent."
    return $property.Value
}

function Assert-LabBoundary {
    param([Parameter(Mandatory)][string] $Package)
    Require ($Package -ceq 'com.qcxr.qcxr.canary262') 'Only the fixed Lab package is permitted.'
    Require ($Package -cne 'com.qcxr.qcxr.dev262') 'Stable package access is forbidden.'
    Require ($script:LabPackage -ceq 'com.qcxr.qcxr.canary262') 'The internal Lab package pin drifted.'
    Require ($script:ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262') 'The Stable deny pin drifted.'
}

function Get-ExpectedIdentity {
    return [pscustomobject]@{
        Package = $script:LabPackage
        VersionCode = $script:ExpectedVersionCode
        VersionName = $script:ExpectedVersionName
        Label = $script:ExpectedLabel
        ApkSha256 = $script:ExpectedApkSha256
        ApkSizeBytes = $script:ExpectedApkSizeBytes
        SignerSha256 = $script:ExpectedSignerSha256
        CoreSha256 = $script:ExpectedCoreSha256
        CoreVersion = $script:ExpectedCoreVersion
        VeqSha256 = $script:ExpectedVeqSha256
        VeqVersion = $script:ExpectedVeqVersion
    }
}

function Assert-LockContract {
    Require (Test-Path -LiteralPath $script:LockPath -PathType Leaf) 'The RC8 lock is missing.'
    Assert-NoReparsePoint -Path $script:LockPath -Root $script:RepoRoot
    try {
        $lock = [IO.File]::ReadAllText(
            $script:LockPath,
            [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -Depth 30
    } catch {
        throw "[V71_RC8_LAB_INSTALL] The RC8 lock is not strict parseable UTF-8 JSON: $($_.Exception.Message)"
    }

    Assert-ExactValue (Get-RequiredProperty $lock 'schemaVersion' 'RC8 lock') 1 'RC8 lock schemaVersion'
    Assert-ExactValue (Get-RequiredProperty $lock 'status' 'RC8 lock') 'HOST_BUILT_AND_AUDITED' 'RC8 lock status'
    $target = Get-RequiredProperty $lock 'target' 'RC8 lock'
    Assert-ExactValue (Get-RequiredProperty $target 'package' 'RC8 target') $script:LabPackage 'RC8 target package'
    Assert-ExactValue (Get-RequiredProperty $target 'forbiddenStablePackage' 'RC8 target') $script:ForbiddenStablePackage 'RC8 Stable deny package'
    Assert-ExactValue (Get-RequiredProperty $target 'versionCode' 'RC8 target') $script:ExpectedVersionCode 'RC8 target versionCode'
    Assert-ExactValue (Get-RequiredProperty $target 'versionName' 'RC8 target') $script:ExpectedVersionName 'RC8 target versionName'
    Assert-ExactValue (Get-RequiredProperty $target 'apkPath' 'RC8 target') $script:ApkRelativePath 'RC8 target APK path'
    Assert-ExactValue (Get-RequiredProperty $target 'apkSha256' 'RC8 target') $script:ExpectedApkSha256 'RC8 target APK hash'
    Assert-ExactValue (Get-RequiredProperty $target 'apkSizeBytes' 'RC8 target') $script:ExpectedApkSizeBytes 'RC8 target APK size'
    Assert-ExactValue (Get-RequiredProperty $target 'signerSha256' 'RC8 target') $script:ExpectedSignerSha256 'RC8 target signer'
    Require (-not [bool](Get-RequiredProperty $target 'stableTouched' 'RC8 target')) 'The RC8 lock says Stable was touched.'

    $acceptance = Get-RequiredProperty $lock 'acceptance' 'RC8 lock'
    Require ([bool](Get-RequiredProperty $acceptance 'hostApkAuditPassed' 'RC8 acceptance')) 'The RC8 Host APK audit is not accepted.'
    Require (-not [bool](Get-RequiredProperty $acceptance 'stablePromotionAllowed' 'RC8 acceptance')) 'The RC8 lock unexpectedly permits Stable promotion.'
    $boundary = Get-RequiredProperty $lock 'evidenceBoundary' 'RC8 lock'
    foreach ($field in @('deviceTouched','adbUsed','rootUsed','networkUsed','stableTouched')) {
        Require (-not [bool](Get-RequiredProperty $boundary $field 'RC8 evidence boundary')) "The RC8 evidence boundary marks $field as true."
    }
    return $lock
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory)][string] $FileName,
        [Parameter(Mandatory)][string[]] $Arguments
    )
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
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-ApkVerifier {
    param([Parameter(Mandatory)][string] $ApkPath)
    Require (Test-Path -LiteralPath $script:VerifierPath -PathType Leaf) 'The APK verifier is missing.'
    Assert-NoReparsePoint -Path $script:VerifierPath -Root $script:RepoRoot
    Require ((Get-Sha256 $script:VerifierPath) -ceq $script:ExpectedVerifierSha256) 'The APK verifier drifted from the reviewed RC8 verifier.'
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
    Require ($objects.Count -eq 1) 'The APK verifier did not return one structured result.'
    return $objects[0]
}

function Assert-ExactApkBytes {
    param([Parameter(Mandatory)][string] $Path, [string] $Context)
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    Require ((Get-Item -LiteralPath $Path).Length -eq $script:ExpectedApkSizeBytes) "$Context size mismatched."
    Require ((Get-Sha256 $Path) -ceq $script:ExpectedApkSha256) "$Context SHA-256 mismatched."
}

function Enter-CandidateReadLock {
    param([Parameter(Mandatory)][string] $Path)
    $fixedCandidate = Get-CanonicalPath (Join-Path $script:RepoRoot `
        ($script:ApkRelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    Require ((Get-CanonicalPath $Path) -ceq $fixedCandidate) 'Candidate lock path drifted.'
    Assert-NoReparsePoint -Path $fixedCandidate -Root $script:RepoRoot
    try {
        # FileShare.Read lets adb read the reviewed APK while denying writes,
        # replacement, and deletion for the complete device transaction.
        return [IO.File]::Open(
            $fixedCandidate,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
    } catch {
        throw "[V71_RC8_LAB_INSTALL] Could not acquire the candidate APK read lock: $($_.Exception.Message)"
    }
}

function Assert-CandidateReadLock {
    param([Parameter(Mandatory)][IO.FileStream] $Stream, [string] $Context)
    Require ($Stream.CanRead -and $Stream.Length -eq $script:ExpectedApkSizeBytes) "$Context size mismatched under lock."
    $Stream.Position = 0
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream))
    $Stream.Position = 0
    Require ($sha -ceq $script:ExpectedApkSha256) "$Context SHA-256 mismatched under lock."
}

function Assert-HostApkArtifact {
    param([Parameter(Mandatory)][string] $Path, [string] $Context)
    Assert-ExactApkBytes -Path $Path -Context $Context
    $verified = Invoke-ApkVerifier -ApkPath $Path
    Require ([string]$verified.Package -ceq $script:LabPackage) "$Context package mismatched."
    Require ([int]$verified.VersionCode -eq $script:ExpectedVersionCode) "$Context versionCode mismatched."
    Require ([string]$verified.VersionName -ceq $script:ExpectedVersionName) "$Context versionName mismatched."
    Require (([string]$verified.SignerSha256).ToUpperInvariant() -ceq $script:ExpectedSignerSha256) "$Context signer mismatched."
    Require ([bool]$verified.SignatureV2 -and [bool]$verified.Zipalign16KiB) "$Context signature/alignment proof failed."
    return [pscustomobject]@{
        Path = Get-CanonicalPath $Path
        Sha256 = ([string]$verified.Sha256).ToUpperInvariant()
        SizeBytes = [int64](Get-Item -LiteralPath $Path).Length
        Package = [string]$verified.Package
        VersionCode = [int]$verified.VersionCode
        VersionName = [string]$verified.VersionName
        SignerSha256 = ([string]$verified.SignerSha256).ToUpperInvariant()
    }
}

function Get-CandidateAudit {
    Assert-LabBoundary -Package $script:LabPackage
    $null = Assert-LockContract
    $candidatePath = Join-Path $script:RepoRoot ($script:ApkRelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $candidatePath = Assert-PathContained -Path $candidatePath -Root $script:RepoRoot
    Assert-NoReparsePoint -Path $candidatePath -Root $script:RepoRoot
    $expectedPath = Get-CanonicalPath (Join-Path $script:RepoRoot ($script:ApkRelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    Require ($candidatePath -ceq $expectedPath) 'The candidate APK did not resolve to its exact fixed path.'
    return Assert-HostApkArtifact -Path $candidatePath -Context 'RC8 Lab candidate APK'
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    $sideQuest = Join-Path $env:LOCALAPPDATA 'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw '[V71_RC8_LAB_INSTALL] ADB was not found. Pass -AdbPath with the full adb executable path.'
}

function Resolve-ApkSigner {
    if (-not [string]::IsNullOrWhiteSpace($ApkSignerPath)) {
        Require (Test-Path -LiteralPath $ApkSignerPath -PathType Leaf) 'The requested apksigner executable is missing.'
        return (Resolve-Path -LiteralPath $ApkSignerPath).Path
    }
    $command = Get-Command 'apksigner.bat' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Select-Object -Unique
    $candidate = @(
        foreach ($sdkRoot in $sdkRoots) {
            $buildTools = Join-Path $sdkRoot 'build-tools'
            if (Test-Path -LiteralPath $buildTools -PathType Container) {
                Get-ChildItem -LiteralPath $buildTools -Directory | ForEach-Object {
                    $tool = Join-Path $_.FullName 'apksigner.bat'
                    if (Test-Path -LiteralPath $tool -PathType Leaf) {
                        [pscustomobject]@{ Version = [version]$_.Name; Path = $tool }
                    }
                }
            }
        }
    ) | Sort-Object Version -Descending | Select-Object -First 1
    Require ($null -ne $candidate) 'Android SDK apksigner was not found.'
    return [string]$candidate.Path
}

function Invoke-AdbRaw {
    param([Parameter(Mandatory)][string[]] $Arguments)
    Require (-not [string]::IsNullOrWhiteSpace([string]$script:ResolvedAdb)) 'ADB was not resolved.'
    $script:DeviceInvocationCount++
    return Invoke-ProcessCapture -FileName $script:ResolvedAdb -Arguments $Arguments
}

function Assert-AdbResult {
    param($Result, [string] $Context, [switch] $AllowOutput)
    Require ([int]$Result.ExitCode -eq 0) "$Context failed."
    Require ([string]::IsNullOrWhiteSpace([string]$Result.Stderr)) "$Context emitted stderr and was rejected."
    if (-not $AllowOutput.IsPresent) {
        Require ([string]::IsNullOrWhiteSpace([string]$Result.Stdout)) "$Context emitted unexpected stdout."
    }
}

function Resolve-ExactDevice {
    $script:ResolvedAdb = Resolve-Adb
    $result = Invoke-AdbRaw @('devices')
    Assert-AdbResult $result 'ADB endpoint enumeration' -AllowOutput
    $lines = @($result.Stdout -split "`r?`n")
    Require ($lines.Count -ge 1 -and $lines[0].Trim() -ceq 'List of devices attached') 'ADB devices output had no exact header.'
    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line, '^(?<serial>\S+)\s+(?<state>\S+)(?:\s+.*)?$')
        Require $match.Success 'ADB devices output contained a malformed endpoint row.'
        $records.Add([pscustomobject]@{
            Serial = [string]$match.Groups['serial'].Value
            State = [string]$match.Groups['state'].Value
        })
    }
    if ($Serial -ceq 'auto') {
        Require ($records.Count -eq 1) 'Auto selection requires exactly one ADB endpoint.'
        Require ([string]$records[0].State -ceq 'device') 'The only ADB endpoint is not authorized and ready.'
        $script:ResolvedSerial = [string]$records[0].Serial
    } else {
        $matches = @($records | Where-Object { [string]$_.Serial -ceq $Serial })
        Require ($matches.Count -eq 1) 'The requested ADB serial is not present exactly once.'
        Require ([string]$matches[0].State -ceq 'device') 'The requested ADB endpoint is not authorized and ready.'
        $script:ResolvedSerial = $Serial
    }
    Require ($script:ResolvedSerial -cmatch '^[A-Za-z0-9._:-]+$') 'The selected ADB serial was unsafe.'
    $state = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'get-state')
    Assert-AdbResult $state 'ADB endpoint state check' -AllowOutput
    Require ($state.Stdout.Trim() -ceq 'device') 'The selected ADB endpoint is not ready.'
}

function Read-InstalledBaseApkPath {
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'shell','pm','path',$script:LabPackage)
    Assert-AdbResult $result 'Installed Lab base.apk lookup' -AllowOutput
    $rows = @($result.Stdout -split "`r?`n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    Require ($rows.Count -eq 1) 'The Lab package is absent, split, or returned an ambiguous base.apk path.'
    $match = [regex]::Match($rows[0], '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$')
    Require $match.Success 'The installed Lab base.apk path was malformed.'
    $path = [string]$match.Groups['path'].Value
    Require (-not $path.Contains('..') -and -not $path.Contains('\') -and -not $path.Contains([char]0)) 'The installed Lab base.apk path was unsafe.'
    Require ($path -cmatch ('/' + [regex]::Escape($script:LabPackage) + '(?:-|/)')) 'The installed base.apk does not belong to the Lab package.'
    return $path
}

function Assert-LabStopped {
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'shell','pidof',$script:LabPackage)
    Require ([string]::IsNullOrWhiteSpace([string]$result.Stderr)) 'Lab process-state check emitted stderr and was rejected.'
    $pids = @($result.Stdout -split '\s+' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ([int]$result.ExitCode -eq 1 -and $pids.Count -eq 0) {
        return
    }
    if ([int]$result.ExitCode -eq 0 -and $pids.Count -ge 1 -and
        @($pids | Where-Object { $_ -cnotmatch '^[0-9]+$' }).Count -eq 0) {
        throw '[V71_RC8_LAB_INSTALL] Lab is running; stop it manually before -Install.'
    }
    throw '[V71_RC8_LAB_INSTALL] Lab process-state result was ambiguous; install was blocked.'
}

function Invoke-PullInstalledApk {
    param([Parameter(Mandatory)][string] $RemotePath, [Parameter(Mandatory)][string] $Destination)
    Require (-not (Test-Path -LiteralPath $Destination)) 'The installed APK pull destination already exists.'
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'pull',$RemotePath,$Destination)
    Require ([int]$result.ExitCode -eq 0) 'The installed base.apk pull failed.'
    Require (Test-Path -LiteralPath $Destination -PathType Leaf) 'ADB reported a pull without producing base.apk.'
    Require ((Get-Item -LiteralPath $Destination).Length -gt 0) 'The pulled base.apk was empty.'
}

function Get-ApkSignerSha256 {
    param([Parameter(Mandatory)][string] $ApkPath)
    $result = Invoke-ProcessCapture -FileName $script:ResolvedApkSigner `
        -Arguments @('verify','--verbose','--print-certs',(Get-CanonicalPath $ApkPath))
    Require ([int]$result.ExitCode -eq 0) 'apksigner rejected the installed Lab base.apk.'
    Require ([string]::IsNullOrWhiteSpace([string]$result.Stderr)) 'apksigner emitted stderr and was rejected.'
    $signerMatches = @([regex]::Matches(
        $result.Stdout,
        '(?im)^Signer #(?<index>[0-9]+) certificate SHA-256 digest:\s*(?<sha>[0-9a-f]{64})\s*$'))
    Require ($signerMatches.Count -eq 1 -and
        [string]$signerMatches[0].Groups['index'].Value -ceq '1') `
        'apksigner returned multiple or ambiguous signer digests.'
    Require ($result.Stdout -cmatch '(?m)^Verified using v2 scheme \(APK Signature Scheme v2\): true\s*$') 'The installed Lab APK is not verified with signature scheme v2.'
    return $signerMatches[0].Groups['sha'].Value.ToUpperInvariant()
}

function New-InstallArguments {
    param([Parameter(Mandatory)][string] $CandidatePath)
    Assert-LabBoundary -Package $script:LabPackage
    Require ($Install.IsPresent) 'Package replacement requires explicit -Install.'
    Require (-not [string]::IsNullOrWhiteSpace([string]$script:ResolvedSerial)) 'The ADB serial is unresolved.'
    $fixedCandidate = Get-CanonicalPath (Join-Path $script:RepoRoot ($script:ApkRelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    Require ((Get-CanonicalPath $CandidatePath) -ceq $fixedCandidate) 'Only the exact fixed RC8 APK path can be installed.'
    return @('-s',$script:ResolvedSerial,'install','-r',$fixedCandidate)
}

function Assert-InstallResult {
    param($Result)
    Require ([int]$Result.ExitCode -eq 0) 'Android rejected the Lab install -r operation.'
    Require ([string]::IsNullOrWhiteSpace([string]$Result.Stderr)) 'Lab install emitted stderr and was rejected.'
    $rows = @($Result.Stdout -split "`r?`n" | ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require (@($rows | Where-Object { $_ -ceq 'Success' }).Count -eq 1) 'Lab install did not return one exact Success row.'
    Require (@($rows | Where-Object { $_ -match '(?i)failure|error|exception' }).Count -eq 0) 'Lab install output contained a failure marker.'
}

function New-SafeTempDirectory {
    $root = Get-CanonicalPath ([IO.Path]::GetTempPath())
    $path = Join-Path $root ('quest-v71-rc8-lab-install-' + [guid]::NewGuid().ToString('N'))
    Require ((Get-CanonicalPath $path).StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Temporary directory escaped the system Temp root.'
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Remove-SafeTempDirectory {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $root = Get-CanonicalPath ([IO.Path]::GetTempPath())
    $full = Get-CanonicalPath $Path
    Require ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Refused to clean a path outside system Temp.'
    Require ([IO.Path]::GetFileName($full).StartsWith('quest-v71-rc8-lab-install-', [StringComparison]::Ordinal)) 'Refused to clean an unexpected Temp directory.'
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Force)) {
        Require (-not $item.PSIsContainer) 'The RC8 temporary directory unexpectedly contained a subdirectory.'
        Remove-Item -LiteralPath $item.FullName -Force
    }
    Remove-Item -LiteralPath $full -Force
}

function Invoke-DeviceInstall {
    param([Parameter(Mandatory)] $CandidateAudit)
    Assert-LabBoundary -Package $script:LabPackage
    Require ($Install.IsPresent) 'Actual deployment is disabled unless -Install is explicit.'
    $fixedCandidate = Get-CanonicalPath (Join-Path $script:RepoRoot `
        ($script:ApkRelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    Require ([string]$CandidateAudit.Path -ceq $fixedCandidate) 'Candidate audit path drifted.'
    Require ([string]$CandidateAudit.Sha256 -ceq $script:ExpectedApkSha256) 'Candidate audit hash drifted.'
    Require ([string]$CandidateAudit.Package -ceq $script:LabPackage) 'Candidate audit package drifted.'
    Require ([int]$CandidateAudit.VersionCode -eq $script:ExpectedVersionCode) 'Candidate audit versionCode drifted.'
    Require ([string]$CandidateAudit.VersionName -ceq $script:ExpectedVersionName) 'Candidate audit versionName drifted.'
    Require ([string]$CandidateAudit.SignerSha256 -ceq $script:ExpectedSignerSha256) 'Candidate audit signer drifted.'

    $candidateReadLock = Enter-CandidateReadLock -Path ([string]$CandidateAudit.Path)
    $tempDirectory = $null
    try {
        Assert-CandidateReadLock -Stream $candidateReadLock -Context 'RC8 candidate before device preflight'
        Resolve-ExactDevice
        Assert-LabStopped
        $script:ResolvedApkSigner = Resolve-ApkSigner
        $tempDirectory = New-SafeTempDirectory
        $beforePath = Join-Path $tempDirectory 'installed-before.apk'
        $beforeRemote = Read-InstalledBaseApkPath
        Invoke-PullInstalledApk -RemotePath $beforeRemote -Destination $beforePath
        $installedSigner = Get-ApkSignerSha256 -ApkPath $beforePath
        Require ($installedSigner -ceq $script:ExpectedSignerSha256) 'Installed Lab signer mismatched; install was blocked before mutation.'

        # Recheck immediately before the only mutating command; never stop the
        # Lab automatically if it became active during the preflight.
        Assert-LabStopped
        Assert-CandidateReadLock -Stream $candidateReadLock -Context 'RC8 candidate immediately before install'
        $installResult = Invoke-AdbRaw (New-InstallArguments -CandidatePath ([string]$CandidateAudit.Path))
        Assert-InstallResult $installResult
        Assert-CandidateReadLock -Stream $candidateReadLock -Context 'RC8 candidate immediately after install'

        $afterPath = Join-Path $tempDirectory 'installed-after.apk'
        $afterRemote = Read-InstalledBaseApkPath
        Invoke-PullInstalledApk -RemotePath $afterRemote -Destination $afterPath
        $afterAudit = Assert-HostApkArtifact -Path $afterPath -Context 'post-install Lab base.apk'
        return [pscustomobject]@{
            Result = 'INSTALLED_AND_VERIFIED'
            DryRun = $false
            InstallRequested = $true
            Package = $script:LabPackage
            ForbiddenStablePackage = $script:ForbiddenStablePackage
            Serial = $script:ResolvedSerial
            VersionCode = $afterAudit.VersionCode
            VersionName = $afterAudit.VersionName
            ApkSha256 = $afterAudit.Sha256
            SignerSha256 = $afterAudit.SignerSha256
            InstallCommand = 'adb install -r only'
            Launched = $false
            DeviceInvocations = $script:DeviceInvocationCount
            StableTouched = $false
        }
    } finally {
        if ($null -ne $tempDirectory) {
            Remove-SafeTempDirectory -Path $tempDirectory
        }
        $candidateReadLock.Dispose()
    }
}

function Invoke-Rc8LabInstallGate {
    $script:DeviceInvocationCount = 0
    $script:ResolvedAdb = $null
    $script:ResolvedApkSigner = $null
    $script:ResolvedSerial = $null
    $candidate = Get-CandidateAudit
    if (-not $Install.IsPresent) {
        return [pscustomobject]@{
            Result = 'AUDIT_PASS'
            DryRun = $true
            InstallRequested = $false
            HostOnly = $true
            Package = $candidate.Package
            ForbiddenStablePackage = $script:ForbiddenStablePackage
            VersionCode = $candidate.VersionCode
            VersionName = $candidate.VersionName
            ApkPath = $candidate.Path
            ApkSha256 = $candidate.Sha256
            SignerSha256 = $candidate.SignerSha256
            InstallCommand = 'adb install -r only'
            Launched = $false
            DeviceInvocations = 0
            StableTouched = $false
        }
    }
    return Invoke-DeviceInstall -CandidateAudit $candidate
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Rc8LabInstallGate
}
