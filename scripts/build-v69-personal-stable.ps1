<#
.SYNOPSIS
Builds the exact QuestCraft Vivecraft Personal v69 APK without using ADB.

.DESCRIPTION
SelfTest is read-only and is the default. Build requires -AllowBuild, rebuilds
Pojlib, temporarily stages that AAR in Unity, calls the fail-closed Personal
v69 entry point, restores the checked-in AAR in finally, and verifies the APK.
The script never invokes ADB and cannot target an arbitrary package or output.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Build', 'RestoreSourceAar')]
    [string] $Action = 'SelfTest',

    [string] $UnityEditor = (Join-Path $env:USERPROFILE `
        'Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe'),

    [switch] $AllowBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $repo 'QCXR-XR-Wrapper'
$pojlib = Join-Path $repo 'Pojlib'
$labPackage = 'com.qcxr.qcxr.canary262'
$personalPackage = 'com.qcxr.qcxr.dev262'
$personalLabel = 'QuestCraft Vivecraft Personal 26.2'
$personalVersionCode = '69'
$personalVersionName = '6.0.1-26.2-vivecraft-personal.10'
$personalOutputRelative = 'Builds/QuestCraft-Vivecraft-26.2-personal.10-local.apk'
$personalOutput = Join-Path $wrapper $personalOutputRelative
$pluginAar = Join-Path $wrapper 'Assets\Plugins\Android\Pojlib-release.aar'
$builtAar = Join-Path $pojlib 'build\outputs\aar\Pojlib-release.aar'
$backupDirectory = Join-Path $repo '.personal-v69-build-backup'
$backupAar = Join-Path $backupDirectory 'Pojlib-release.aar'
$stackLockPath = Join-Path $repo 'STACK.lock.json'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-StreamBytes {
    param([Parameter(Mandatory)][IO.Stream] $Stream)
    $memory = [IO.MemoryStream]::new()
    try {
        $Stream.CopyTo($memory)
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
    }
}

function Test-ByteSequence {
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][string] $Text)
    $needle = [Text.Encoding]::UTF8.GetBytes($Text)
    for ($offset = 0; $offset -le $Bytes.Length - $needle.Length; $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $needle.Length; $index++) {
            if ($Bytes[$offset + $index] -ne $needle[$index]) {
                $matches = $false
                break
            }
        }
        if ($matches) { return $true }
    }
    return $false
}

function Assert-PersonalSource {
    $lock = Get-Content -Raw -LiteralPath $stackLockPath | ConvertFrom-Json
    Require ([string]$lock.identity.applicationId -ceq $personalPackage) `
        'The source lock is not rooted in the accepted Personal package.'
    Require ([int]$lock.identity.versionCode -eq 69) `
        'The source lock is not the accepted v69 Stable release.'

    & git -C $repo merge-base --is-ancestor 640fdf5d HEAD
    Require ($LASTEXITCODE -eq 0) `
        'Personal v69 must descend from accepted Camera Park commit 640fdf5d.'
    & git -C $repo merge-base --is-ancestor e1b5458c HEAD
    Require ($LASTEXITCODE -ne 0) `
        'The unaccepted Idle Throttle commit must not enter Personal v69.'

    $baseBuilder = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Editor\QuestCraftCliBuild.cs')
    $labBuilder = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Editor\QuestCraftLabCliBuild.cs')
    $personalBuilder = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Editor\QuestCraftPersonalV69CliBuild.cs')
    $projectSettings = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'ProjectSettings\ProjectSettings.asset')
    $resolverSettings = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'ProjectSettings\AndroidResolverDependencies.xml')
    $picoSettings = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Resources\PicoSdkPCConfig.json')
    $cameraPolicy = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\LauncherCameraParkPolicy.java')
    $autoplayGate = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\UnattendedLocalTestGate.java')

    foreach ($pair in @(
        @('ApplicationIdentifier', $personalPackage),
        @('ProductName', $personalLabel),
        @('VersionName', $personalVersionName),
        @('VersionCode', $personalVersionCode),
        @('OutputPath', $personalOutputRelative)
    )) {
        Require ($personalBuilder.Contains($pair[1])) `
            "The Personal builder lost its exact $($pair[0])."
    }
    Require ($personalBuilder.Contains('QuestCraftCliBuild.BuildAcceptedPersonalV69Android();')) `
        'The Personal builder no longer delegates through the exact internal gate.'
    Require ($personalBuilder.Contains('HasArgument("-release")')) `
        'The Personal builder no longer rejects release signing.'
    Require ($baseBuilder.Contains("DefaultApplicationIdentifier = `"$labPackage`"")) `
        'The ordinary builder is no longer pinned to Lab.'
    Require ($baseBuilder.Contains("AcceptedPersonalApplicationIdentifier = `"$personalPackage`"")) `
        'The ordinary builder no longer rejects Personal.'
    Require ($labBuilder.Contains("ApplicationIdentifier = `"$labPackage`"")) `
        'The Lab builder identity drifted.'
    Require (-not $labBuilder.Contains($personalPackage)) `
        'The Lab builder can target Personal.'

    Require ($projectSettings.Contains("Android: $personalPackage")) `
        'Unity ProjectSettings are not pinned to Personal.'
    Require ($projectSettings.Contains("productName: $personalLabel")) `
        'Unity ProjectSettings do not use the Personal label.'
    Require ($projectSettings.Contains("bundleVersion: $personalVersionName")) `
        'Unity ProjectSettings do not use the Personal v69 version.'
    Require ($projectSettings.Contains("AndroidBundleVersionCode: $personalVersionCode")) `
        'Unity ProjectSettings do not use versionCode 69.'
    Require ($resolverSettings.Contains("bundleId`" value=`"$personalPackage`"")) `
        'Android Resolver is not pinned to Personal.'
    Require ($picoSettings.Contains("`"package_name`": `"$personalPackage`"")) `
        'PICO settings are not pinned to Personal.'
    Require ($picoSettings.Contains("`"package_version_name`": `"$personalVersionName`"")) `
        'PICO settings do not use the Personal v69 version.'

    Require ($cameraPolicy.Contains("PERSONAL_PACKAGE = `"$personalPackage`"")) `
        'Camera Park is not enabled for the accepted Personal package.'
    Require ($cameraPolicy.Contains("LAB_PACKAGE = `"$labPackage`"")) `
        'Camera Park no longer supports the isolated Lab package.'
    Require ($autoplayGate.Contains("EXPECTED_PACKAGE = `"$labPackage`"")) `
        'The autoplay gate is no longer fixed to Lab.'
    Require (-not $autoplayGate.Contains($personalPackage)) `
        'The autoplay gate can target Personal.'
    Require (-not (Test-Path -LiteralPath (Join-Path $pojlib `
            'src\main\java\pojlib\LauncherIdleThrottlePolicy.java'))) `
        'The unaccepted Idle Throttle source is present.'
    return $lock
}

function Test-BuiltPojlibPolicy {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $aarArchive = [IO.Compression.ZipFile]::OpenRead($builtAar)
    try {
        $classesEntry = $aarArchive.GetEntry('classes.jar')
        Require ($null -ne $classesEntry) 'Built Pojlib AAR has no classes.jar.'
        $classesStream = $classesEntry.Open()
        try { $classesBytes = Get-StreamBytes $classesStream } finally { $classesStream.Dispose() }
    } finally {
        $aarArchive.Dispose()
    }

    $classesMemory = [IO.MemoryStream]::new($classesBytes, $false)
    $classesArchive = [IO.Compression.ZipArchive]::new(
        $classesMemory, [IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        $policyEntry = $classesArchive.GetEntry('pojlib/LauncherCameraParkPolicy.class')
        Require ($null -ne $policyEntry) 'Built Pojlib lacks LauncherCameraParkPolicy.'
        $policyStream = $policyEntry.Open()
        try { $policyBytes = Get-StreamBytes $policyStream } finally { $policyStream.Dispose() }
        Require (Test-ByteSequence $policyBytes $labPackage) `
            'Built Camera Park policy lost the Lab package.'
        Require (Test-ByteSequence $policyBytes $personalPackage) `
            'Built Camera Park policy does not include Personal.'

        $autoplayEntry = $classesArchive.GetEntry('pojlib/UnattendedLocalTestGate.class')
        Require ($null -ne $autoplayEntry) 'Built Pojlib lacks the autoplay gate.'
        $autoplayStream = $autoplayEntry.Open()
        try { $autoplayBytes = Get-StreamBytes $autoplayStream } finally { $autoplayStream.Dispose() }
        Require (Test-ByteSequence $autoplayBytes $labPackage) `
            'Built autoplay gate lost the Lab package.'
        Require (-not (Test-ByteSequence $autoplayBytes $personalPackage)) `
            'Built autoplay gate can target Personal.'
    } finally {
        $classesArchive.Dispose()
        $classesMemory.Dispose()
    }
}

if ($Action -eq 'SelfTest') {
    $lock = Assert-PersonalSource
    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        AdbInvocations = 0
        Package = $personalPackage
        Label = $personalLabel
        VersionCode = $personalVersionCode
        VersionName = $personalVersionName
        Output = $personalOutput
        CameraPark = 'ON_AFTER_SUCCESSFUL_XR_HANDOFF'
        Autoplay = 'LAB_ONLY'
        IdleThrottle = 'ABSENT'
        DebugSignerOnly = $true
    }
    return
}

if (-not $AllowBuild) {
    throw 'Source/build mutation is disabled until -AllowBuild is explicit.'
}
if ($Action -eq 'RestoreSourceAar') {
    Require (Test-Path -LiteralPath $backupAar -PathType Leaf) `
        'There is no interrupted-build AAR backup to restore.'
    $lock = Get-Content -Raw -LiteralPath $stackLockPath | ConvertFrom-Json
    $expected = ([string]$lock.bundledArtifacts.pojlibAar.sha256).ToUpperInvariant()
    Require ((Get-Sha256 $backupAar) -ceq $expected) `
        'The backup does not match the checked-in v69 Stable AAR.'
    [IO.File]::Copy($backupAar, $pluginAar, $true)
    Require ((Get-Sha256 $pluginAar) -ceq $expected) `
        'The checked-in AAR could not be restored exactly.'
    [IO.File]::Delete($backupAar)
    if ([IO.Directory]::Exists($backupDirectory) -and
            [IO.Directory]::GetFileSystemEntries($backupDirectory).Length -eq 0) {
        [IO.Directory]::Delete($backupDirectory)
    }
    [pscustomobject]@{ Result = 'SOURCE_AAR_RESTORED'; HostOnly = $true; Sha256 = $expected }
    return
}

Require (Test-Path -LiteralPath $UnityEditor -PathType Leaf) `
    'Unity 2022.3.62f3 was not found.'
$lock = Assert-PersonalSource
$dirty = @(git -C $repo status --porcelain --untracked-files=all)
Require ($LASTEXITCODE -eq 0 -and $dirty.Count -eq 0) `
    'Build requires a clean worktree so the AAR restore can be proven.'
Require ((Get-PSDrive -Name C).Free -ge 10GB) `
    'A cold Unity import/build requires at least 10 GiB free.'
Require (-not (Test-Path -LiteralPath $backupAar)) `
    "A prior interrupted build left the guarded AAR backup: $backupAar"

$unityRoot = Split-Path -Parent $UnityEditor
$javaHome = Join-Path $unityRoot 'Data\PlaybackEngines\AndroidPlayer\OpenJDK'
$androidSdk = Join-Path $unityRoot 'Data\PlaybackEngines\AndroidPlayer\SDK'
Require (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe') -PathType Leaf) `
    'Unity Android OpenJDK is missing.'
Require (Test-Path -LiteralPath $androidSdk -PathType Container) `
    'Unity Android SDK is missing.'

$oldJavaHome = $env:JAVA_HOME
$oldAndroidHome = $env:ANDROID_HOME
$oldAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$oldPath = $env:PATH
$originalAarHash = Get-Sha256 $pluginAar
$logPath = Join-Path $env:TEMP `
    ('questcraft-v69-personal-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.log')
try {
    $env:JAVA_HOME = $javaHome
    $env:ANDROID_HOME = $androidSdk
    $env:ANDROID_SDK_ROOT = $androidSdk
    $env:PATH = (Join-Path $javaHome 'bin') + ';' + $oldPath

    Push-Location $pojlib
    try {
        & '.\gradlew.bat' --no-daemon clean testReleaseUnitTest assembleRelease
        if ($LASTEXITCODE -ne 0) { throw 'Pojlib release AAR build failed.' }
    } finally {
        Pop-Location
    }
    Require (Test-Path -LiteralPath $builtAar -PathType Leaf) `
        'Pojlib release AAR was not produced.'
    Test-BuiltPojlibPolicy
    $builtAarHash = Get-Sha256 $builtAar

    [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
    [IO.File]::Copy($pluginAar, $backupAar, $false)
    Require ((Get-Sha256 $backupAar) -ceq $originalAarHash) `
        'Could not lock the checked-in AAR backup.'
    [IO.File]::Copy($builtAar, $pluginAar, $true)

    $arguments = @(
        '-batchmode', '-nographics', '-quit',
        '-projectPath', $wrapper,
        '-executeMethod', 'QuestCraftPersonalV69CliBuild.BuildAndroid',
        '-applicationIdentifier', $personalPackage,
        '-productName', $personalLabel,
        '-versionName', $personalVersionName,
        '-versionCode', $personalVersionCode,
        '-outputPath', $personalOutputRelative,
        '-logFile', $logPath
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $UnityEditor
    $startInfo.UseShellExecute = $false
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    Require ($null -ne $process) 'Unity Personal v69 build could not be started.'
    try {
        $process.WaitForExit()
        $unityExitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($unityExitCode -ne 0) { throw "Unity build failed; inspect $logPath" }
    Require (Test-Path -LiteralPath $personalOutput -PathType Leaf) `
        'Unity produced no Personal v69 APK.'

    & (Join-Path $PSScriptRoot 'verify-dev-apk.ps1') `
        -ApkPath $personalOutput `
        -ExpectedPackage $personalPackage `
        -ExpectedVersionCode $personalVersionCode `
        -ExpectedVersionName $personalVersionName `
        -ExpectedLabel $personalLabel `
        -ExpectedVivecraftSha256 ([string]$lock.bundledArtifacts.vivecraft.sha256) `
        -ExpectedLwjglSha256 ([string]$lock.bundledArtifacts.lwjgl.sha256) `
        -ExpectedSignerSha256 ([string]$lock.identity.expectedSignerSha256)
    if ($LASTEXITCODE -ne 0) { throw 'Personal v69 APK verification failed.' }

    [pscustomobject]@{
        Result = 'BUILT_AND_VERIFIED'
        HostOnly = $true
        AdbInvocations = 0
        Apk = $personalOutput
        Sha256 = Get-Sha256 $personalOutput
        Package = $personalPackage
        VersionCode = $personalVersionCode
        VersionName = $personalVersionName
        BuiltPojlibAarSha256 = $builtAarHash
        BuildLog = $logPath
    }
} finally {
    if (Test-Path -LiteralPath $backupAar -PathType Leaf) {
        [IO.File]::Copy($backupAar, $pluginAar, $true)
        if ((Get-Sha256 $pluginAar) -cne $originalAarHash) {
            throw 'CRITICAL: the checked-in Pojlib AAR could not be restored.'
        }
        [IO.File]::Delete($backupAar)
        if ([IO.Directory]::Exists($backupDirectory) -and
                [IO.Directory]::GetFileSystemEntries($backupDirectory).Length -eq 0) {
            [IO.Directory]::Delete($backupDirectory)
        }
    }
    $env:JAVA_HOME = $oldJavaHome
    $env:ANDROID_HOME = $oldAndroidHome
    $env:ANDROID_SDK_ROOT = $oldAndroidSdkRoot
    $env:PATH = $oldPath
}
