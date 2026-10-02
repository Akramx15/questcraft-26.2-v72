<#
.SYNOPSIS
Builds the isolated QuestCraft Vivecraft Lab v71 APK without targeting Personal.

.DESCRIPTION
SelfTest is read-only and is the default. Build requires -AllowBuild, rebuilds
Pojlib locally, temporarily swaps only the Unity project's Pojlib AAR, invokes
the fail-closed QuestCraftV70LabCliBuild entry point, restores the exact checked-in
AAR in finally, and verifies the resulting APK. It never invokes ADB.
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
$stablePackage = 'com.qcxr.qcxr.dev262'
$labLabel = 'QuestCraft Vivecraft Lab 26.2'
$labVersionCode = '71'
$labVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.2'
$labOutputRelative = 'Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.2-integrated-local.apk'
$copyBatchJvmArgumentPrefix = '-Dvivecraft.openxrCopyBatch='
$labOutput = Join-Path $wrapper $labOutputRelative
$pluginAar = Join-Path $wrapper 'Assets\Plugins\Android\Pojlib-release.aar'
$builtAar = Join-Path $pojlib 'build\outputs\aar\Pojlib-release.aar'
$backupDirectory = Join-Path $repo '.lab-build-backup'
$backupAar = Join-Path $backupDirectory 'Pojlib-release.aar'
$stackLockPath = Join-Path $repo 'STACK.lock.json'
$rc2LockPath = Join-Path $repo 'V71_LAB_RC2.lock.json'
$script:Rc2Lock = $null

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

function Assert-LabSource {
    $lock = Get-Content -Raw -LiteralPath $stackLockPath | ConvertFrom-Json
    $rc2 = Get-Content -Raw -LiteralPath $rc2LockPath | ConvertFrom-Json
    Require ([string]$lock.identity.applicationId -ceq $stablePackage) `
        'The source lock is not the accepted Personal v69 baseline.'
    Require ([int]$lock.identity.versionCode -eq 69) `
        'The source lock is not versionCode 69.'
    Require ([string]$lock.identity.versionName -ceq
            '6.0.1-26.2-vivecraft-personal.10') `
        'The source lock is not the exact accepted Personal v69 identity.'
    Require ((Get-Sha256 $pluginAar) -ceq
            ([string]$lock.bundledArtifacts.pojlibAar.sha256).ToUpperInvariant()) `
        'The checked-in Pojlib AAR does not match the v69 lock.'
    Require ([string]$rc2.target.package -ceq $labPackage -and
            [string]$rc2.target.forbiddenStablePackage -ceq $stablePackage -and
            [bool]$rc2.target.stableTouched -eq $false -and
            [string]$rc2.target.delivery -ceq 'integrated-managed-baseline' -and
            [int]$rc2.target.labShellVersionCode -eq 71 -and
            [string]$rc2.target.labShellVersionName -ceq $labVersionName) `
        'The v71 RC2 lock does not match the integrated Lab identity.'
    Require ([int64]$rc2.pair.core.sizeBytes -eq 10062636 -and
            [int64]$rc2.pair.veq.sizeBytes -eq 435540 -and
            [string]$rc2.pair.sha256 -ceq
            '9952EA068712375E2364C0DF0EDBD9F876620D2E8EE10EF10106D6F6DEC6EBBE') `
        'The locked v71 RC2 pair size or pair digest drifted.'
    $coreAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-26.2-1.3.15-quest.bin'
    $veqAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-essentials-quest.bin'
    Require ((Get-Sha256 $coreAsset) -ceq
            ([string]$rc2.pair.core.sha256).ToUpperInvariant()) `
        'The managed Vivecraft asset is not the locked v71 RC2 core.'
    Require ((Get-Sha256 $veqAsset) -ceq
            ([string]$rc2.pair.veq.sha256).ToUpperInvariant()) `
        'The managed VEQ asset is not the locked accepted Wrist payload.'

    $coreGate = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\VivecraftCoreCanaryGate.java')
    $veqGate = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\VeqCanaryGate.java')
    $modsAbGate = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\ModsAbCanaryGate.java')
    $coreTransaction = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\VivecraftCoreCanaryTransaction.java')
    $instanceHandler = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\InstanceHandler.java')
    $localGate = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\UnattendedLocalTestGate.java')
    $labBuilder = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Editor\QuestCraftV70LabCliBuild.cs')
    $normalizedLabBuilder = $labBuilder -replace '\s+', ' '
    $baseBuilder = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Editor\QuestCraftCliBuild.cs')
    $projectSettings = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'ProjectSettings\ProjectSettings.asset')
    $resolverSettings = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'ProjectSettings\AndroidResolverDependencies.xml')
    $picoSettings = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Resources\PicoSdkPCConfig.json')
    $coreScript = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot `
        'quest-vivecraft-core-canary.ps1')
    $veqScript = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot `
        'quest-veq-lab.ps1')
    $modsAbScript = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot `
        'quest-mods-ab-lab.ps1')
    $veqLock = Get-Content -Raw -LiteralPath (Join-Path $repo `
        'VEQ_LAB_CANARY.lock.json') | ConvertFrom-Json
    $modsAbLock = Get-Content -Raw -LiteralPath (Join-Path $repo `
        'MODS_AB_LAB.lock.json') | ConvertFrom-Json
    $autoplay = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot `
        'run-vivecraft-local-autoplay.ps1')
    $launcher = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Scripts\InstanceButton.cs')

    Require ($coreGate.Contains("EXPECTED_PACKAGE = `"$labPackage`"")) `
        'The core canary gate does not target the Lab package.'
    Require (-not $coreGate.Contains("EXPECTED_PACKAGE = `"$stablePackage`"")) `
        'The core canary gate can still target Personal.'
    Require ($veqGate.Contains("EXPECTED_PACKAGE = `"$labPackage`"")) `
        'The VEQ canary gate does not target the Lab package.'
    Require (-not $veqGate.Contains("EXPECTED_PACKAGE = `"$stablePackage`"")) `
        'The VEQ canary gate can still target Personal.'
    Require ($coreGate.Contains('questcraft-vivecraft-core-canary-v2')) `
        'The Core runtime gate still uses the stale v1 state namespace.'
    Require ($veqGate.Contains('questcraft-veq-v71-canary-v2') -and
            $veqGate.Contains('0.7.0-v70-canary.1')) `
        'The VEQ runtime gate is not the exact v71 marker-bound contract.'
    Require ($veqGate.Contains(
            '8eb67999fa9334cf3b18f250b420668b912a2ee4f2b201db51ee1e265744427a')) `
        'The VEQ runtime gate does not pin the integrated RC2 baseline.'
    Require ($veqGate.Contains('? Collections.singleton(requested.candidateSha256)')) `
        'The VEQ runtime gate no longer accepts only the marker-bound candidate hash.'
    Require ($veqGate.Contains(
            '35b71c9c432b42af067d65beeb1e966c2242181d085449c411b230f568800095')) `
        'The VEQ runtime gate no longer rejects the retired v69 candidate.'
    Require (-not $veqGate.Contains(
            '2ab6b70242cbb45b77fecec81b3d7cca9a45ad82c59ef28f12fdfb0070ff7c36')) `
        'The VEQ runtime gate still bakes a retired v69 candidate hash.'
    Require ($modsAbGate.Contains("EXPECTED_PACKAGE = `"$labPackage`"")) `
        'The managed-mod A/B gate does not target the Lab package.'
    Require (-not $modsAbGate.Contains("EXPECTED_PACKAGE = `"$stablePackage`"")) `
        'The managed-mod A/B gate can still target Personal.'
    Require ($modsAbGate.Contains(
            'de406c7a0ca5e748dfbe44740278400882a44e3109e2584b243ec02d4003344b')) `
        'The managed-mod A/B gate does not pin official Sodium 0.9.1.'
    Require ($coreGate.Contains('static synchronized String takeOpenXrCopyBatchMode')) `
        'The one-shot copy-batch JVM mode claim is absent.'
    Require ($coreTransaction.Contains('SCHEMA_VERSION = 2')) `
        'The core canary marker is not schema 2.'
    Require ($coreTransaction.Contains('"openXrCopyBatchMode"')) `
        'The strict marker does not carry the copy-batch mode.'
    Require ($instanceHandler.Contains(
            "OPENXR_COPY_BATCH_PROPERTY = `"$copyBatchJvmArgumentPrefix`"")) `
        'The fixed copy-batch JVM property is absent.'
    Require ($instanceHandler.Contains('int classpathIndex = launchArgs.indexOf("-cp");') -and
            $instanceHandler.Contains(
            'launchArgs.add(classpathIndex, OPENXR_COPY_BATCH_PROPERTY +')) `
        'The copy-batch property is not inserted before the Minecraft classpath.'
    Require ($localGate.Contains("EXPECTED_PACKAGE = `"$labPackage`"")) `
        'The unattended gate does not target the Lab package.'
    Require ($localGate.Contains("$labPackage.action.UNATTENDED_ARM")) `
        'The Lab unattended action identity drifted.'
    Require ($labBuilder.Contains("ApplicationIdentifier = `"$labPackage`"")) `
        'The Unity Lab package identity drifted.'
    Require ($labBuilder.Contains("ProductName = `"$labLabel`"")) `
        'The Unity Lab label drifted.'
    Require ($labBuilder.Contains("VersionCode = `"$labVersionCode`"")) `
        'The Unity Lab versionCode drifted.'
    Require ($labBuilder.Contains("VersionName = `"$labVersionName`"")) `
        'The Unity Lab versionName drifted.'
    Require ($normalizedLabBuilder.Contains(
            "public const string OutputPath = `"$labOutputRelative`";")) `
        'The Unity Lab output path drifted.'
    Require ($labBuilder.Contains('QuestCraftCliBuild.BuildAndroid();')) `
        'The Lab identity guard no longer delegates to the known builder.'
    Require ($labBuilder.Contains('HasArgument("-release")')) `
        'The Lab builder no longer rejects release signing.'
    Require ($baseBuilder.Contains("DefaultApplicationIdentifier = `"$labPackage`"")) `
        'The generic Unity builder does not default to the Lab package.'
    Require ($baseBuilder.Contains("AcceptedPersonalApplicationIdentifier = `"$stablePackage`"")) `
        'The Unity builder no longer blocks the accepted Personal package.'
    Require ($projectSettings.Contains("Android: $stablePackage")) `
        'The release branch ProjectSettings are not pinned to Personal.'
    Require ($projectSettings.Contains("productName: QuestCraft Vivecraft Personal 26.2")) `
        'The release branch ProjectSettings do not use the Personal label.'
    Require ($resolverSettings.Contains("bundleId`" value=`"$stablePackage`"")) `
        'The release branch Android Resolver settings are not pinned to Personal.'
    Require ($picoSettings.Contains("`"package_name`": `"$stablePackage`"")) `
        'The release branch PICO settings are not pinned to Personal.'
    Require ($coreScript.Contains("`$script:Package = '$labPackage'")) `
        'The core deployment helper does not target Lab.'
    Require ($veqScript.Contains("`$script:Package = '$labPackage'")) `
        'The VEQ deployment helper does not target Lab.'
    Require (-not $veqScript.Contains('[string] $Package')) `
        'The VEQ deployment helper exposes a package override.'
    Require ([string]$veqLock.harness.package -ceq $labPackage) `
        'The VEQ canary lock does not target Lab.'
    Require ([string]$veqLock.harness.forbiddenPackage -ceq $stablePackage) `
        'The VEQ canary lock no longer forbids Personal.'
    Require ([int]$veqLock.schemaVersion -eq 2 -and
            [string]$veqLock.harness.id -ceq 'questcraft-veq-v71-canary-v2' -and
            [string]$veqLock.harness.fabricVersion -ceq '0.7.0-v70-canary.1') `
        'The VEQ canary lock is not the v71 contract.'
    Require (@($veqLock.candidatePolicy.bakedCandidateHashes).Count -eq 0 -and
            [string]$veqLock.candidatePolicy.hashBinding -ceq
            'explicit-expected-sha256-per-deploy') `
        'The VEQ canary lock no longer requires an explicit marker-bound candidate hash.'
    Require (@($veqLock.candidatePolicy.pairedOtherModsFingerprintExcludesExactly).Count -eq 2) `
        'The VEQ/Core shared fingerprint does not exclude exactly both managed targets.'
    Require ($modsAbScript.Contains("`$script:Package = '$labPackage'")) `
        'The managed-mod A/B helper does not target Lab.'
    Require (-not $modsAbScript.Contains('[string] $Package') -and
            -not $modsAbScript.Contains('[string] $Profile')) `
        'The managed-mod A/B helper exposes a package/profile override.'
    Require ([string]$modsAbLock.harness.package -ceq $labPackage -and
            [string]$modsAbLock.harness.forbiddenPackage -ceq $stablePackage) `
        'The managed-mod A/B lock lost its fixed package boundary.'
    Require (@($modsAbLock.experiments).Count -eq 4) `
        'The managed-mod A/B lock does not contain exactly four experiments.'
    Require ($autoplay.Contains("`$package = '$labPackage'")) `
        'The local autoplay helper does not target Lab.'
    Require ($localGate.Contains(
            'EXTRA_LAUNCHER_CAMERA_PARK = "launcher_camera_park"')) `
        'The Lab gate does not carry the camera-park experiment mode.'
    Require ($localGate.Contains('normalizeCameraParkMode')) `
        'The Lab gate does not reject invalid camera-park modes.'
    Require ($autoplay.Contains("[string] `$LauncherCameraPark = 'ON'")) `
        'The accepted Lab camera-park policy does not default to ON.'
    Require ($launcher.Contains('ParkLauncherCamerasIfRequested();') -and
            $launcher.Contains('Camera.allCameras') -and
            $launcher.Contains('camera.enabled = true;')) `
        'The launcher camera-park hook or its partial-failure rollback is absent.'
    Require ($launcher.Contains('OpenXRHandoffFadeTimeoutSeconds') -and
            $launcher.Contains('The OpenXR handoff fade timed out.')) `
        'The OpenXR handoff fade lacks a fail-closed timeout.'
    $script:Rc2Lock = $rc2
    return $lock
}

function Invoke-LabSelfTest {
    $lock = Assert-LabSource
    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        AdbInvocations = 0
        SourceBaselinePackage = [string]$lock.identity.applicationId
        LabPackage = $labPackage
        LabLabel = $labLabel
        VersionCode = $labVersionCode
        VersionName = $labVersionName
        Output = $labOutput
        DebugSignerOnly = $true
        IsolatedStorageRoot = "/sdcard/Android/data/$labPackage/files"
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-LabSelfTest
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
        'The interrupted-build AAR backup does not match the accepted v69 lock.'
    [IO.File]::Copy($backupAar, $pluginAar, $true)
    Require ((Get-Sha256 $pluginAar) -ceq $expected) `
        'The accepted source AAR could not be restored exactly.'
    [IO.File]::Delete($backupAar)
    if ([IO.Directory]::Exists($backupDirectory) -and
            [IO.Directory]::GetFileSystemEntries($backupDirectory).Length -eq 0) {
        [IO.Directory]::Delete($backupDirectory)
    }
    [pscustomobject]@{
        Result = 'SOURCE_AAR_RESTORED'
        HostOnly = $true
        AdbInvocations = 0
        Path = $pluginAar
        Sha256 = $expected
    }
    return
}
if (Test-Path -LiteralPath $backupAar) {
    throw "A prior interrupted build left the guarded AAR backup: $backupAar"
}
Require (Test-Path -LiteralPath $UnityEditor -PathType Leaf) 'Unity 2022.3.62f3 was not found.'
$lock = Assert-LabSource
$dirty = @(git -C $repo status --porcelain --untracked-files=all)
Require ($LASTEXITCODE -eq 0 -and $dirty.Count -eq 0) `
    'Build requires a clean tracked worktree so the AAR restore can be proven.'
# The first failed cold build showed about 4.4 GiB of reproducible build output.
# Keep almost twice that amount available. Requiring 10 GiB unnecessarily blocks
# machines whose system-managed page file has already grown and reserved space.
Require ((Get-PSDrive -Name C).Free -ge 8GB) `
    'A cold Unity import/build requires at least 8 GiB free.'

$unityRoot = Split-Path -Parent $UnityEditor
$javaHome = Join-Path $unityRoot 'Data\PlaybackEngines\AndroidPlayer\OpenJDK'
$androidSdk = Join-Path $unityRoot 'Data\PlaybackEngines\AndroidPlayer\SDK'
Require (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe') -PathType Leaf) `
    'Unity Android OpenJDK is missing.'
Require (Test-Path -LiteralPath $androidSdk -PathType Container) 'Unity Android SDK is missing.'

$oldJavaHome = $env:JAVA_HOME
$oldAndroidHome = $env:ANDROID_HOME
$oldAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$oldPath = $env:PATH
$originalAarHash = Get-Sha256 $pluginAar
$gitHead = (git -C $repo rev-parse HEAD).Trim()
Require ($LASTEXITCODE -eq 0 -and $gitHead -match '^[0-9a-f]{40}$') `
    'Could not resolve the exact Lab source commit.'
$logPath = Join-Path $env:TEMP `
    ('questcraft-v71-lab-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.log')
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
    Require (Test-Path -LiteralPath $builtAar -PathType Leaf) 'Pojlib release AAR was not produced.'
    $builtAarHash = Get-Sha256 $builtAar

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $aarArchive = [IO.Compression.ZipFile]::OpenRead($builtAar)
    try {
        $classesEntry = $aarArchive.GetEntry('classes.jar')
        Require ($null -ne $classesEntry) 'Built Pojlib AAR has no classes.jar.'
        $classesStream = $classesEntry.Open()
        try { $classesBytes = Get-StreamBytes $classesStream } finally { $classesStream.Dispose() }
    } finally { $aarArchive.Dispose() }
    $classesMemory = [IO.MemoryStream]::new($classesBytes, $false)
    $classesArchive = [IO.Compression.ZipArchive]::new(
        $classesMemory, [IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        foreach ($className in @(
            'pojlib/VivecraftCoreCanaryGate.class',
            'pojlib/VeqCanaryGate.class',
            'pojlib/ModsAbCanaryGate.class',
            'pojlib/UnattendedLocalTestGate.class'
        )) {
            $classEntry = $classesArchive.GetEntry($className)
            Require ($null -ne $classEntry) "Built Pojlib is missing $className."
            $classStream = $classEntry.Open()
            try { $classBytes = Get-StreamBytes $classStream } finally { $classStream.Dispose() }
            Require (Test-ByteSequence $classBytes $labPackage) `
                "Built $className does not contain the Lab package gate."
            Require (-not (Test-ByteSequence $classBytes $stablePackage)) `
                "Built $className can still target the accepted Personal package."
        }
        $cameraPolicyEntry = $classesArchive.GetEntry(
            'pojlib/LauncherCameraParkPolicy.class')
        Require ($null -ne $cameraPolicyEntry) `
            'Built Pojlib is missing LauncherCameraParkPolicy.class.'
        $cameraPolicyStream = $cameraPolicyEntry.Open()
        try { $cameraPolicyBytes = Get-StreamBytes $cameraPolicyStream } `
        finally { $cameraPolicyStream.Dispose() }
        Require ((Test-ByteSequence $cameraPolicyBytes 'APPLIED') -and
                (Test-ByteSequence $cameraPolicyBytes 'NO_CAMERAS') -and
                (Test-ByteSequence $cameraPolicyBytes 'FAILED') -and
                (Test-ByteSequence $cameraPolicyBytes 'manual')) `
            'Built Pojlib lacks the allowlisted Lab camera-park policy.'
        $handlerEntry = $classesArchive.GetEntry('pojlib/InstanceHandler.class')
        Require ($null -ne $handlerEntry) 'Built Pojlib is missing InstanceHandler.class.'
        $handlerStream = $handlerEntry.Open()
        try { $handlerBytes = Get-StreamBytes $handlerStream } finally { $handlerStream.Dispose() }
        Require (Test-ByteSequence $handlerBytes $copyBatchJvmArgumentPrefix) `
            'Built InstanceHandler does not contain the fixed copy-batch JVM property.'
        Require (Test-ByteSequence $handlerBytes 'takeOpenXrCopyBatchMode') `
            'Built InstanceHandler does not call the one-shot copy-batch mode claim.'

        $transactionEntry = $classesArchive.GetEntry(
            'pojlib/VivecraftCoreCanaryTransaction.class')
        Require ($null -ne $transactionEntry) `
            'Built Pojlib is missing VivecraftCoreCanaryTransaction.class.'
        $transactionStream = $transactionEntry.Open()
        try { $transactionBytes = Get-StreamBytes $transactionStream } `
        finally { $transactionStream.Dispose() }
        Require (Test-ByteSequence $transactionBytes 'openXrCopyBatchMode') `
            'Built Pojlib transaction does not carry the strict copy-batch mode.'
    } finally {
        $classesArchive.Dispose()
        $classesMemory.Dispose()
    }

    [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
    [IO.File]::Copy($pluginAar, $backupAar, $false)
    Require ((Get-Sha256 $backupAar) -ceq $originalAarHash) 'Could not lock the source AAR backup.'
    [IO.File]::Copy($builtAar, $pluginAar, $true)

    $arguments = @(
        '-batchmode', '-nographics', '-quit',
        '-projectPath', $wrapper,
        '-executeMethod', 'QuestCraftV70LabCliBuild.BuildAndroid',
        '-applicationIdentifier', $labPackage,
        '-productName', $labLabel,
        '-versionName', $labVersionName,
        '-versionCode', $labVersionCode,
        '-outputPath', $labOutputRelative,
        '-logFile', $logPath
    )
    $unityStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $unityStartInfo.FileName = $UnityEditor
    $unityStartInfo.UseShellExecute = $false
    foreach ($argument in $arguments) {
        [void]$unityStartInfo.ArgumentList.Add([string]$argument)
    }
    $unityProcess = [Diagnostics.Process]::Start($unityStartInfo)
    Require ($null -ne $unityProcess) 'Unity Lab build process could not be started.'
    try {
        $unityProcess.WaitForExit()
        $unityExitCode = $unityProcess.ExitCode
    } finally {
        $unityProcess.Dispose()
    }
    if ($unityExitCode -ne 0) { throw "Unity Lab build failed; inspect $logPath" }
    Require (Test-Path -LiteralPath $labOutput -PathType Leaf) 'Unity produced no Lab APK.'

    & (Join-Path $PSScriptRoot 'verify-dev-apk.ps1') `
        -ApkPath $labOutput `
        -ExpectedPackage $labPackage `
        -ExpectedVersionCode $labVersionCode `
        -ExpectedVersionName $labVersionName `
        -ExpectedLabel $labLabel `
        -ExpectedVivecraftSha256 ([string]$script:Rc2Lock.pair.core.sha256) `
        -ExpectedVivecraftVersion ([string]$script:Rc2Lock.pair.core.fabricVersion) `
        -ExpectedAddOnSha256 ([string]$script:Rc2Lock.pair.veq.sha256) `
        -ExpectedAddOnVersion ([string]$script:Rc2Lock.pair.veq.fabricVersion) `
        -ExpectedLwjglSha256 ([string]$lock.bundledArtifacts.lwjgl.sha256) `
        -ExpectedSignerSha256 ([string]$lock.identity.expectedSignerSha256)
    if ($LASTEXITCODE -ne 0) { throw 'Lab APK verification failed.' }

    [pscustomobject]@{
        Result = 'BUILT_AND_VERIFIED'
        HostOnly = $true
        AdbInvocations = 0
        Apk = $labOutput
        Sha256 = Get-Sha256 $labOutput
        Package = $labPackage
        Label = $labLabel
        VersionCode = $labVersionCode
        VersionName = $labVersionName
        GitHead = $gitHead
        BuiltPojlibAarSha256 = $builtAarHash
        BuildLog = $logPath
    }
} finally {
    if (Test-Path -LiteralPath $backupAar -PathType Leaf) {
        [IO.File]::Copy($backupAar, $pluginAar, $true)
        if ((Get-Sha256 $pluginAar) -cne $originalAarHash) {
            throw 'CRITICAL: the exact checked-in Pojlib AAR could not be restored.'
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
