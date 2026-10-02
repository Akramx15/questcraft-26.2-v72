#requires -Version 7.0
<#
.SYNOPSIS
Builds and audits only the persistent v71 RC6 Lab APK.

.DESCRIPTION
This is an RC6-only Host gate. It never invokes ADB, never accepts the Stable
package, builds Pojlib twice with Unity's pinned JDK, and restores the checked-in
source AAR even when Gradle or Unity fails. Historical RC4/RC5 locks, APKs and
receipts are deliberately not consumed or modified.
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
$pojlib = Join-Path $repo 'Pojlib'
$wrapper = Join-Path $repo 'QCXR-XR-Wrapper'
$lockPath = Join-Path $repo 'V71_LAB_RC6.lock.json'
$coreAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-26.2-1.3.15-quest.bin'
$veqAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-essentials-quest.bin'
$sourceAar = Join-Path $wrapper 'Assets\Plugins\Android\Pojlib-release.aar'
$builtAar = Join-Path $pojlib 'build\outputs\aar\Pojlib-release.aar'
$verifyApk = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$builderFile = Join-Path $wrapper 'Assets\Editor\QuestCraftV71Rc6LabCliBuild.cs'
$projectSettings = Join-Path $wrapper 'ProjectSettings\ProjectSettings.asset'
$backupRoot = Join-Path $repo '.v71-rc6-lab-build-backup'
$backupAar = Join-Path $backupRoot 'Pojlib-release.aar'
$backupProjectSettings = Join-Path $backupRoot 'ProjectSettings.asset'
$firstAar = Join-Path $backupRoot 'Pojlib-release.first.aar'
$previousApk = Join-Path $backupRoot 'previous-output.apk'

$package = 'com.qcxr.qcxr.canary262'
$forbiddenStablePackage = 'com.qcxr.qcxr.dev262'
$label = 'QuestCraft Vivecraft Lab 26.2'
$versionCode = '71'
$versionName = '6.0.1-26.2-vivecraft-personal.12-rc.6'
$outputRelative = 'Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.6-integrated-local.apk'
$outputApk = Join-Path $wrapper $outputRelative
$builder = 'QuestCraftV71Rc6LabCliBuild.BuildAndroid'
$coreHash = '8FE9804CC041CFCE45C9B4F49F361065D62DC41D14B05CC49680BB9A6F0FF079'
$coreSize = 10067011L
$coreVersion = '26.2-1.3.15+qc.v71.rc6'
$veqHash = 'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
$veqSize = 443280L
$veqVersion = '0.7.0-v71.rc6'
$pairHash = 'ED3E2980F6B377E42BB598F5AFB1C3412F05AEECA9043534DBB21734BFD0BFD7'
$aarHash = '9A69B2A568919AEDAB5F1774028BDEE879B10D7ADD13B0152600A9713FBAFF1A'
$aarSize = 88709880L
$projectSettingsHash = 'E45F52C082C8E49C24C2EE12C5793D2C8E03136E4FC9E7515158AFB2995DD36E'
$lwjglHash = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
$signerHash = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_RC6_LAB_BUILD] $Message" }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-NormalizedTextSha256 {
    param([Parameter(Mandatory)][string] $Path)
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n" -replace "`r", "`n"
    [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}

function Get-ZipEntrySha256 {
    param([string] $ArchivePath, [string] $EntryPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $archive.GetEntry($EntryPath)
        Require ($null -ne $entry) "Archive entry is missing: $EntryPath"
        $stream = $entry.Open()
        try {
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
}

function Assert-Manifest {
    param([Parameter(Mandatory)][string] $Path)
    $json = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $versions = @($json.versions | Where-Object name -ceq '26.2')
    Require ($versions.Count -eq 1) "$Path must contain one exact 26.2 profile."
    $entries = @($versions[0].coreMods | Where-Object slug -ceq 'Vivecraft')
    Require ($entries.Count -eq 1) "$Path must contain one exact Vivecraft core entry."
    $entry = $entries[0]
    Require ([string]$entry.version -ceq $coreVersion) "$Path has the wrong RC6 version."
    Require ([string]$entry.sha256 -ceq $coreHash) "$Path has the wrong RC6 SHA-256."
    Require ([string]$entry.download_link -ceq
            'asset://mods/vivecraft-26.2-1.3.15-quest.bin') `
        "$Path has the wrong managed RC6 asset path."
}

function Assert-Aar {
    param([Parameter(Mandatory)][string] $Path)
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "Pojlib AAR is missing: $Path"
    Require ((Get-Sha256 $Path) -ceq $aarHash) 'Pojlib AAR hash drifted.'
    Require ((Get-Item -LiteralPath $Path).Length -eq $aarSize) 'Pojlib AAR size drifted.'
    Require ((Get-ZipEntrySha256 $Path `
                'assets/mods/vivecraft-26.2-1.3.15-quest.bin') -ceq $coreHash) `
        'Pojlib AAR does not embed exact RC6 Vivecraft.'
    Require ((Get-ZipEntrySha256 $Path `
                'assets/mods/vivecraft-essentials-quest.bin') -ceq $veqHash) `
        'Pojlib AAR does not embed the frozen VEQ payload.'
}

function Assert-Source {
    Require (Test-Path -LiteralPath $lockPath -PathType Leaf) `
        'The independent V71_LAB_RC6.lock.json is missing.'
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    Require ([int]$lock.schemaVersion -eq 1) 'RC6 lock schema drifted.'
    Require ([string]$lock.status -in @('host-integration-pending-rebuild',
            'host-integrated-build-pending',
            'host-built-and-audited')) 'RC6 lock status is invalid.'
    Require ([string]$lock.source.scriptHashScheme -ceq 'sha256-utf8-normalized-lf') `
        'RC6 lock script hash scheme drifted.'
    Require ([string]$lock.source.buildScriptSha256 -ceq
            (Get-NormalizedTextSha256 $PSCommandPath)) 'RC6 build script drifted.'
    Require ([string]$lock.target.package -ceq $package -and
            [string]$lock.target.forbiddenStablePackage -ceq $forbiddenStablePackage -and
            [bool]$lock.target.stableTouched -eq $false) `
        'RC6 lock no longer confines the build to Lab.'
    Require ([int]$lock.target.versionCode -eq 71 -and
            [string]$lock.target.versionName -ceq $versionName -and
            [string]$lock.target.apkPath -ceq
                ('QCXR-XR-Wrapper/' + $outputRelative)) 'RC6 Lab identity drifted.'
    Require ([string]$lock.pair.sha256 -ceq $pairHash) 'RC6 pair digest drifted.'
    Require ([string]$lock.pair.core.sha256 -ceq $coreHash -and
            [int64]$lock.pair.core.sizeBytes -eq $coreSize -and
            [string]$lock.pair.core.fabricVersion -ceq $coreVersion) `
        'RC6 Core lock drifted.'
    Require ([string]$lock.pair.veq.sha256 -ceq $veqHash -and
            [int64]$lock.pair.veq.sizeBytes -eq $veqSize -and
            [string]$lock.pair.veq.fabricVersion -ceq $veqVersion) `
        'RC6 VEQ lock drifted.'
    Require ([string]$lock.pojlibAar.sha256 -ceq $aarHash -and
            [int64]$lock.pojlibAar.sizeBytes -eq $aarSize -and
            [bool]$lock.pojlibAar.cleanBuildsMatchedByteForByte) `
        'RC6 AAR lock drifted.'
    Require ([string]$lock.unitySource.projectSettingsPath -ceq
            'QCXR-XR-Wrapper/ProjectSettings/ProjectSettings.asset' -and
            [string]$lock.unitySource.projectSettingsSha256 -ceq $projectSettingsHash -and
            [bool]$lock.unitySource.restoredAfterEveryBuildAttempt) `
        'RC6 Unity source restoration contract drifted.'

    $integrationCommit = [string]$lock.source.payloadIntegrationCommit
    Require ($integrationCommit -cmatch '^[0-9a-f]{40}$') `
        'RC6 payload integration commit is not canonical.'
    & git -C $repo merge-base --is-ancestor $integrationCommit HEAD
    Require ($LASTEXITCODE -eq 0) 'RC6 payload integration is not an ancestor of HEAD.'
    & git -C $repo diff --quiet $integrationCommit HEAD -- `
        Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin `
        Pojlib/src/main/assets/mods/vivecraft-essentials-quest.bin `
        Pojlib/mods.json Pojlib/devmods.json `
        Pojlib/src/main/assets/mods.json Pojlib/src/main/assets/devmods.json `
        Pojlib/src/main/java/pojlib/VivecraftCoreCanaryGate.java
    Require ($LASTEXITCODE -eq 0) 'RC6 managed payload drifted after integration.'

    $optionsRepairCommit = [string]$lock.source.optionsOwnershipRepairCommit
    Require ($optionsRepairCommit -cmatch '^[0-9a-f]{40}$') `
        'The inherited options ownership repair commit is not canonical.'
    & git -C $repo merge-base --is-ancestor $optionsRepairCommit HEAD
    Require ($LASTEXITCODE -eq 0) 'The options ownership repair is not an ancestor of HEAD.'
    & git -C $repo diff --quiet $optionsRepairCommit HEAD -- `
        Pojlib/src/main/java/pojlib/API.java `
        Pojlib/src/main/java/pojlib/install/Installer.java `
        Pojlib/src/main/java/pojlib/install/OptionsFileOwnershipRepair.java `
        Pojlib/src/main/java/pojlib/install/OptionsOwnershipPrelaunchGate.java
    Require ($LASTEXITCODE -eq 0) 'The options ownership prelaunch gate source drifted.'

    Require ((Get-Sha256 $coreAsset) -ceq $coreHash -and
            (Get-Item -LiteralPath $coreAsset).Length -eq $coreSize) `
        'Managed RC6 Core asset drifted.'
    Require ((Get-Sha256 $veqAsset) -ceq $veqHash -and
            (Get-Item -LiteralPath $veqAsset).Length -eq $veqSize) `
        'Managed VEQ asset drifted.'
    foreach ($manifest in @(
        (Join-Path $pojlib 'mods.json'),
        (Join-Path $pojlib 'devmods.json'),
        (Join-Path $pojlib 'src\main\assets\mods.json'),
        (Join-Path $pojlib 'src\main\assets\devmods.json'))) {
        Assert-Manifest $manifest
    }
    Assert-Aar $sourceAar
    Require ((Get-Sha256 $projectSettings) -ceq $projectSettingsHash) `
        'Unity ProjectSettings drifted from the RC6 source baseline.'

    $gate = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\VivecraftCoreCanaryGate.java')
    Require ($gate.Contains('questcraft-vivecraft-core-canary-v6') -and
            $gate.Contains($coreVersion) -and
            $gate.Contains($coreHash.ToLowerInvariant())) `
        'RC6 runtime baseline gate drifted.'
    $builderSource = Get-Content -Raw -LiteralPath $builderFile
    Require ($builderSource.Contains("ApplicationIdentifier = `"$package`"") -and
            $builderSource.Contains("VersionName = `"$versionName`"") -and
            $builderSource.Contains("VersionCode = `"$versionCode`"") -and
            $builderSource.Contains($outputRelative) -and
            $builderSource.Contains('HasArgument("-release")')) `
        'RC6 Unity identity guard drifted.'
    $releasePolicy = Get-Content -Raw -LiteralPath (Join-Path $pojlib `
        'src\main\java\pojlib\LauncherResourceReleasePolicy.java')
    $launcher = Get-Content -Raw -LiteralPath (Join-Path $wrapper `
        'Assets\Scripts\InstanceButton.cs')
    Require ($releasePolicy.Contains($versionName) -and $launcher.Contains($versionName)) `
        'RC6 launcher resource release identity is missing.'
    return $lock
}

if ($Action -ceq 'RestoreSourceAar') {
    Require (Test-Path -LiteralPath $backupAar -PathType Leaf) `
        'No interrupted RC6 source AAR backup exists.'
    Require ((Get-Sha256 $backupAar) -ceq $aarHash) `
        'Interrupted-build backup is not the locked RC6 AAR.'
    Copy-Item -LiteralPath $backupAar -Destination $sourceAar -Force
    if (Test-Path -LiteralPath $backupProjectSettings -PathType Leaf) {
        Require ((Get-Sha256 $backupProjectSettings) -ceq $projectSettingsHash) `
            'Interrupted-build ProjectSettings backup is not the locked RC6 source.'
        Copy-Item -LiteralPath $backupProjectSettings -Destination $projectSettings -Force
    }
    Get-ChildItem -LiteralPath $backupRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $backupRoot -Force
    [pscustomobject]@{ Result = 'SOURCE_AAR_RESTORED'; HostOnly = $true; AdbInvocations = 0 }
    return
}

$lock = Assert-Source
if ($Action -ceq 'SelfTest') {
    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        AdbInvocations = 0
        Lock = 'V71_LAB_RC6.lock.json'
        Package = $package
        ForbiddenStablePackage = $forbiddenStablePackage
        VersionCode = $versionCode
        VersionName = $versionName
        CoreSha256 = $coreHash
        VeqSha256 = $veqHash
        PojlibAarSha256 = $aarHash
        DebugSignerOnly = $true
    }
    return
}

Require $AllowBuild 'Build requires explicit -AllowBuild.'
Require (Test-Path -LiteralPath $UnityEditor -PathType Leaf) `
    'Unity 2022.3.62f3 was not found.'
Require (-not (Test-Path -LiteralPath $backupRoot)) `
    'An interrupted RC6 build backup exists; use RestoreSourceAar first.'
$dirty = @(git -C $repo status --porcelain --untracked-files=all)
Require ($LASTEXITCODE -eq 0) 'Could not inspect the RC6 worktree.'
Require ($dirty.Count -eq 0) `
    ('RC6 build requires a completely clean worktree; entries: ' + ($dirty -join ', '))
Require ((Get-PSDrive C).Free -ge 8GB) 'RC6 build requires at least 8 GiB free.'

$unityRoot = Split-Path -Parent $UnityEditor
$androidRoot = Join-Path $unityRoot 'Data\PlaybackEngines\AndroidPlayer'
$javaHome = Join-Path $androidRoot 'OpenJDK'
$androidSdk = Join-Path $androidRoot 'SDK'
$java = Join-Path $javaHome 'bin\java.exe'
Require (Test-Path -LiteralPath $java -PathType Leaf) 'Unity bundled JDK is missing.'
Require (Test-Path -LiteralPath $androidSdk -PathType Container) 'Unity Android SDK is missing.'
$javaIdentity = (& $java -version 2>&1 | Out-String)
Require ($LASTEXITCODE -eq 0 -and $javaIdentity.Contains('11.0.14.1') -and
        $javaIdentity.Contains('Temurin-11.0.14.1+1')) `
    'RC6 requires Unity bundled Temurin 11.0.14.1+1.'

$oldJavaHome = $env:JAVA_HOME
$oldAndroidHome = $env:ANDROID_HOME
$oldAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$oldPath = $env:PATH
$logPath = Join-Path $env:TEMP `
    ('questcraft-v71-rc6-lab-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.log')
$backupReady = $false
$previousOutputQuarantined = $false
$outputVerified = $false
try {
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
    Copy-Item -LiteralPath $sourceAar -Destination $backupAar
    Require ((Get-Sha256 $backupAar) -ceq $aarHash) 'Could not lock the source RC6 AAR.'
    Copy-Item -LiteralPath $projectSettings -Destination $backupProjectSettings
    Require ((Get-Sha256 $backupProjectSettings) -ceq $projectSettingsHash) `
        'Could not lock the source RC6 ProjectSettings.'
    $backupReady = $true
    $canonicalWrapper = [IO.Path]::GetFullPath($wrapper)
    $canonicalOutput = [IO.Path]::GetFullPath($outputApk)
    Require ($canonicalOutput.StartsWith(
            $canonicalWrapper + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) 'RC6 output escaped the wrapper project.'
    if (Test-Path -LiteralPath $outputApk -PathType Leaf) {
        Move-Item -LiteralPath $outputApk -Destination $previousApk
        $previousOutputQuarantined = $true
    }

    $env:JAVA_HOME = $javaHome
    $env:ANDROID_HOME = $androidSdk
    $env:ANDROID_SDK_ROOT = $androidSdk
    $env:PATH = (Join-Path $javaHome 'bin') + ';' + $oldPath
    for ($buildNumber = 1; $buildNumber -le 2; $buildNumber++) {
        Push-Location $pojlib
        try {
            & '.\gradlew.bat' --no-daemon clean testReleaseUnitTest assembleRelease
            Require ($LASTEXITCODE -eq 0) "Pojlib AAR build $buildNumber failed."
        } finally { Pop-Location }
        Assert-Aar $builtAar
        if ($buildNumber -eq 1) {
            Copy-Item -LiteralPath $builtAar -Destination $firstAar
        }
    }
    Require ((Get-Sha256 $firstAar) -ceq (Get-Sha256 $builtAar)) `
        'Two clean RC6 Pojlib AAR builds were not byte-for-byte reproducible.'
    Copy-Item -LiteralPath $builtAar -Destination $sourceAar -Force

    $unityArguments = @(
        '-batchmode', '-nographics', '-quit',
        '-projectPath', $wrapper,
        '-executeMethod', $builder,
        '-applicationIdentifier', $package,
        '-productName', $label,
        '-versionName', $versionName,
        '-versionCode', $versionCode,
        '-outputPath', $outputRelative,
        '-logFile', $logPath
    )
    $unityStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $unityStartInfo.FileName = $UnityEditor
    $unityStartInfo.UseShellExecute = $false
    $unityStartInfo.CreateNoWindow = $true
    foreach ($argument in $unityArguments) {
        [void]$unityStartInfo.ArgumentList.Add([string]$argument)
    }
    $unityProcess = [Diagnostics.Process]::new()
    $unityProcess.StartInfo = $unityStartInfo
    try {
        Require ($unityProcess.Start()) 'Unity RC6 Lab process could not be started.'
        $unityProcess.WaitForExit()
        $unityExitCode = $unityProcess.ExitCode
    } finally { $unityProcess.Dispose() }
    Require ($unityExitCode -eq 0) "Unity RC6 Lab build failed; inspect $logPath"
    Require (Test-Path -LiteralPath $outputApk -PathType Leaf) `
        'Unity produced no RC6 Lab APK.'

    & $verifyApk -ApkPath $outputApk -ExpectedPackage $package `
        -ExpectedVersionCode $versionCode -ExpectedVersionName $versionName `
        -ExpectedLabel $label -ExpectedVivecraftSha256 $coreHash `
        -ExpectedVivecraftVersion $coreVersion -ExpectedAddOnSha256 $veqHash `
        -ExpectedAddOnVersion $veqVersion -ExpectedLwjglSha256 $lwjglHash `
        -ExpectedSignerSha256 $signerHash
    Require ($LASTEXITCODE -eq 0) 'RC6 APK artifact audit failed.'
    $outputVerified = $true

    [pscustomobject]@{
        Result = 'BUILT_AND_VERIFIED'
        HostOnly = $true
        AdbInvocations = 0
        Apk = $outputApk
        ApkSha256 = Get-Sha256 $outputApk
        ApkSizeBytes = (Get-Item -LiteralPath $outputApk).Length
        Package = $package
        VersionCode = $versionCode
        VersionName = $versionName
        CoreSha256 = $coreHash
        VeqSha256 = $veqHash
        PojlibAarSha256 = Get-Sha256 $builtAar
        PojlibReproducible = $true
        SignerSha256 = $signerHash
        BuildLog = $logPath
    }
} finally {
    $env:JAVA_HOME = $oldJavaHome
    $env:ANDROID_HOME = $oldAndroidHome
    $env:ANDROID_SDK_ROOT = $oldAndroidSdkRoot
    $env:PATH = $oldPath
    if ($backupReady -and (Test-Path -LiteralPath $backupAar -PathType Leaf) -and
            (Get-Sha256 $backupAar) -ceq $aarHash) {
        Copy-Item -LiteralPath $backupAar -Destination $sourceAar -Force
    }
    if ($backupReady -and (Test-Path -LiteralPath $backupProjectSettings -PathType Leaf) -and
            (Get-Sha256 $backupProjectSettings) -ceq $projectSettingsHash) {
        Copy-Item -LiteralPath $backupProjectSettings -Destination $projectSettings -Force
    }
    if (-not $outputVerified -and (Test-Path -LiteralPath $outputApk -PathType Leaf)) {
        Remove-Item -LiteralPath $outputApk -Force
    }
    if (-not $outputVerified -and $previousOutputQuarantined -and
            (Test-Path -LiteralPath $previousApk -PathType Leaf)) {
        Move-Item -LiteralPath $previousApk -Destination $outputApk
    }
    if (Test-Path -LiteralPath $backupRoot) {
        Get-ChildItem -LiteralPath $backupRoot -File | Remove-Item -Force
        Remove-Item -LiteralPath $backupRoot -Force
    }
}
