#requires -Version 7.0
<#
.SYNOPSIS
Builds and audits only the persistent v71 RC7 Lab APK.

.DESCRIPTION
Host-only, fail-closed packaging for the dual-hand/background RC7 Core. The
script never invokes ADB, never accepts the Stable package, rebuilds Pojlib
twice with Unity's pinned JDK, and restores checked-in Unity inputs even when a
build fails.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Build')]
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
$lockPath = Join-Path $repo 'V71_LAB_RC7.lock.json'
$coreAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-26.2-1.3.15-quest.bin'
$veqAsset = Join-Path $pojlib 'src\main\assets\mods\vivecraft-essentials-quest.bin'
$sourceAar = Join-Path $wrapper 'Assets\Plugins\Android\Pojlib-release.aar'
$builtAar = Join-Path $pojlib 'build\outputs\aar\Pojlib-release.aar'
$verifyApk = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$builderFile = Join-Path $wrapper 'Assets\Editor\QuestCraftV71Rc7LabCliBuild.cs'
$projectSettings = Join-Path $wrapper 'ProjectSettings\ProjectSettings.asset'
$backupRoot = Join-Path $repo '.v71-rc7-lab-build-backup'
$backupAar = Join-Path $backupRoot 'Pojlib-release.aar'
$backupProjectSettings = Join-Path $backupRoot 'ProjectSettings.asset'
$firstAar = Join-Path $backupRoot 'Pojlib-release.first.aar'
$previousApk = Join-Path $backupRoot 'previous-output.apk'

$package = 'com.qcxr.qcxr.canary262'
$forbiddenStablePackage = 'com.qcxr.qcxr.dev262'
$label = 'QuestCraft Vivecraft Lab 26.2'
$versionCode = '71'
$versionName = '6.0.1-26.2-vivecraft-personal.12-rc.7'
$outputRelative = 'Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.7-integrated-local.apk'
$outputApk = Join-Path $wrapper $outputRelative
$builder = 'QuestCraftV71Rc7LabCliBuild.BuildAndroid'
$coreHash = 'A1A522C2BB949DBDC2A3AE475B900407324441DA50D94E012A7C734B32E498D3'
$coreSize = 10080472L
$coreVersion = '26.2-1.3.15+qc.v71.rc7'
$veqHash = 'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
$veqSize = 443280L
$veqVersion = '0.7.0-v71.rc6'
$pairHash = '24FBE7C7F94A07173017F2B131D6849E0B091878DEEAFF74D17BB92D4AF1EDCD'
$aarHash = '33CC5A1E33CE9AA6DEA4548CE45A6896692656D89DC4F79BAF9862342CCC083F'
$aarSize = 88735580L
$projectSettingsHash = 'E45F52C082C8E49C24C2EE12C5793D2C8E03136E4FC9E7515158AFB2995DD36E'
$lwjglHash = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
$signerHash = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_RC7_LAB_BUILD] $Message" }
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
    $coreEntries = @($versions[0].coreMods | Where-Object slug -ceq 'Vivecraft')
    Require ($coreEntries.Count -eq 1) "$Path must contain one Vivecraft core entry."
    Require ([string]$coreEntries[0].version -ceq $coreVersion -and
            [string]$coreEntries[0].sha256 -ceq $coreHash -and
            [string]$coreEntries[0].download_link -ceq
                'asset://mods/vivecraft-26.2-1.3.15-quest.bin') `
        "$Path has the wrong RC7 Core identity."
    $veqEntries = @($versions[0].defaultMods |
        Where-Object slug -ceq 'Vivecraft-Essentials-Quest')
    Require ($veqEntries.Count -eq 1) "$Path must contain one VEQ entry."
    Require ([string]$veqEntries[0].version -ceq $veqVersion -and
            [string]$veqEntries[0].sha256 -ceq $veqHash -and
            [string]$veqEntries[0].download_link -ceq
                'asset://mods/vivecraft-essentials-quest.bin') `
        "$Path has the wrong frozen VEQ identity."
}

function Assert-Aar {
    param([Parameter(Mandatory)][string] $Path)
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "Pojlib AAR is missing: $Path"
    Require ((Get-Sha256 $Path) -ceq $aarHash) 'Pojlib AAR hash drifted.'
    Require ((Get-Item -LiteralPath $Path).Length -eq $aarSize) 'Pojlib AAR size drifted.'
    Require ((Get-ZipEntrySha256 $Path `
                'assets/mods/vivecraft-26.2-1.3.15-quest.bin') -ceq $coreHash) `
        'Pojlib AAR does not embed exact RC7 Vivecraft.'
    Require ((Get-ZipEntrySha256 $Path `
                'assets/mods/vivecraft-essentials-quest.bin') -ceq $veqHash) `
        'Pojlib AAR does not embed frozen VEQ.'
}

function Assert-AllowedDirtyPaths {
    param([Parameter(Mandatory)] $Lock)
    $allowed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Lock.source.packagingFiles) {
        [void]$allowed.Add(([string]$file.path).Replace('\', '/'))
    }
    foreach ($path in @(
        'V71_LAB_RC7.lock.json',
        'scripts/build-v71-lab-rc7-integrated.ps1',
        'scripts/test-build-v71-lab-rc7-host.ps1',
        'scripts/quest-v71-native-memory-map-probe-rc62.ps1',
        'scripts/test-quest-v71-native-memory-map-probe-rc62-host.ps1')) {
        [void]$allowed.Add($path)
    }

    $status = @(git -C $repo status --porcelain=v1 --untracked-files=all)
    Require ($LASTEXITCODE -eq 0) 'Could not inspect the worktree.'
    foreach ($line in $status) {
        Require ($line.Length -ge 4) "Malformed git status entry: $line"
        $path = $line.Substring(3).Trim('"').Replace('\', '/')
        Require (-not $path.Contains(' -> ')) 'Renames are forbidden during RC7 packaging.'
        Require ($allowed.Contains($path)) "Unrelated dirty path blocks RC7 packaging: $path"
    }
}

function Assert-Source {
    Require (Test-Path -LiteralPath $lockPath -PathType Leaf) `
        'The independent V71_LAB_RC7.lock.json is missing.'
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    Require ([int]$lock.schemaVersion -eq 1) 'RC7 lock schema drifted.'
    Require ([string]$lock.status -in @('HOST_BUILD_PENDING', 'HOST_BUILT_AND_AUDITED')) `
        'RC7 lock status is invalid.'
    Require ([string]$lock.source.scriptHashScheme -ceq 'sha256-utf8-normalized-lf') `
        'RC7 lock script hash scheme drifted.'
    Require ([string]$lock.source.buildScriptSha256 -ceq
            (Get-NormalizedTextSha256 $PSCommandPath)) 'RC7 build script drifted.'
    Require ([string]$lock.source.coreCommit -ceq
            '68893e6a1a0d101337e0a6000dfeec7c42ed21ab') 'RC7 Core commit drifted.'
    & git -C $repo cat-file -e ([string]$lock.source.coreCommit + '^{commit}')
    Require ($LASTEXITCODE -eq 0) 'RC7 Core commit is unavailable.'
    & git -C $repo diff --quiet ([string]$lock.source.coreCommit) HEAD -- `
        Vivecraft-26.2-Quest/common/src Vivecraft-26.2-Quest/fabric/src `
        Vivecraft-26.2-Quest/build.gradle Vivecraft-26.2-Quest/settings.gradle
    Require ($LASTEXITCODE -eq 0) 'Committed Vivecraft source drifted after RC7 Core commit.'
    & git -C $repo diff --quiet HEAD -- `
        Vivecraft-26.2-Quest/common/src Vivecraft-26.2-Quest/fabric/src `
        Vivecraft-26.2-Quest/build.gradle Vivecraft-26.2-Quest/settings.gradle
    Require ($LASTEXITCODE -eq 0) 'Uncommitted Vivecraft gameplay source blocks RC7 packaging.'

    Require ([string]$lock.target.package -ceq $package -and
            [string]$lock.target.forbiddenStablePackage -ceq $forbiddenStablePackage -and
            [bool]$lock.target.stableTouched -eq $false) `
        'RC7 lock no longer confines the build to Lab.'
    Require ([int]$lock.target.versionCode -eq 71 -and
            [string]$lock.target.versionName -ceq $versionName -and
            [string]$lock.target.apkPath -ceq ('QCXR-XR-Wrapper/' + $outputRelative)) `
        'RC7 Lab identity drifted.'
    Require ([string]$lock.pair.sha256 -ceq $pairHash) 'RC7 pair digest drifted.'
    Require ([string]$lock.pair.core.sha256 -ceq $coreHash -and
            [int64]$lock.pair.core.sizeBytes -eq $coreSize -and
            [string]$lock.pair.core.fabricVersion -ceq $coreVersion) `
        'RC7 Core lock drifted.'
    Require ([string]$lock.pair.veq.sha256 -ceq $veqHash -and
            [int64]$lock.pair.veq.sizeBytes -eq $veqSize -and
            [string]$lock.pair.veq.fabricVersion -ceq $veqVersion) `
        'RC7 VEQ lock drifted.'
    Require ([string]$lock.pojlibAar.sha256 -ceq $aarHash -and
            [int64]$lock.pojlibAar.sizeBytes -eq $aarSize -and
            [bool]$lock.pojlibAar.cleanBuildsMatchedByteForByte) `
        'RC7 AAR lock drifted.'

    foreach ($file in $lock.source.packagingFiles) {
        $path = Join-Path $repo ([string]$file.path)
        Require (Test-Path -LiteralPath $path -PathType Leaf) `
            "Locked packaging file is missing: $($file.path)"
        Require ((Get-Sha256 $path) -ceq [string]$file.sha256) `
            "Locked packaging file drifted: $($file.path)"
    }
    Assert-AllowedDirtyPaths $lock

    Require ((Get-Sha256 $coreAsset) -ceq $coreHash -and
            (Get-Item -LiteralPath $coreAsset).Length -eq $coreSize) `
        'Managed RC7 Core asset drifted.'
    Require ((Get-Sha256 $veqAsset) -ceq $veqHash -and
            (Get-Item -LiteralPath $veqAsset).Length -eq $veqSize) `
        'Managed frozen VEQ asset drifted.'
    foreach ($manifest in @(
        (Join-Path $pojlib 'mods.json'),
        (Join-Path $pojlib 'devmods.json'),
        (Join-Path $pojlib 'src\main\assets\mods.json'),
        (Join-Path $pojlib 'src\main\assets\devmods.json'))) {
        Assert-Manifest $manifest
    }
    Assert-Aar $sourceAar
    Require ((Get-Sha256 $projectSettings) -ceq $projectSettingsHash) `
        'Unity ProjectSettings drifted from the RC7 source baseline.'

    $builderSource = Get-Content -Raw -LiteralPath $builderFile
    Require ($builderSource.Contains("ApplicationIdentifier = `"$package`"") -and
            $builderSource.Contains("VersionName = `"$versionName`"") -and
            $builderSource.Contains("VersionCode = `"$versionCode`"") -and
            $builderSource.Contains($outputRelative) -and
            $builderSource.Contains('HasArgument("-release")') -and
            -not $builderSource.Contains($forbiddenStablePackage)) `
        'RC7 Unity identity guard drifted.'

    if ([string]$lock.status -ceq 'HOST_BUILT_AND_AUDITED') {
        Require (Test-Path -LiteralPath $outputApk -PathType Leaf) `
            'Locked RC7 APK is missing.'
        Require ((Get-Sha256 $outputApk) -ceq [string]$lock.target.apkSha256 -and
                (Get-Item -LiteralPath $outputApk).Length -eq
                    [int64]$lock.target.apkSizeBytes) 'Locked RC7 APK drifted.'
    }
    return $lock
}

$lock = Assert-Source
if ($Action -ceq 'SelfTest') {
    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        AdbInvocations = 0
        Package = $package
        ForbiddenStablePackage = $forbiddenStablePackage
        VersionCode = $versionCode
        VersionName = $versionName
        CoreSha256 = $coreHash
        VeqSha256 = $veqHash
        PojlibAarSha256 = $aarHash
        LockStatus = [string]$lock.status
        DebugSignerOnly = $true
    }
    return
}

Require $AllowBuild 'Build requires explicit -AllowBuild.'
Require (Test-Path -LiteralPath $UnityEditor -PathType Leaf) `
    'Unity 2022.3.62f3 was not found.'
Require (-not (Test-Path -LiteralPath $backupRoot)) `
    'An interrupted RC7 build backup exists.'
Require ((Get-PSDrive C).Free -ge 8GB) 'RC7 Lab build requires at least 8 GiB free.'

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
    'RC7 requires Unity bundled Temurin 11.0.14.1+1.'

$oldJavaHome = $env:JAVA_HOME
$oldAndroidHome = $env:ANDROID_HOME
$oldAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$oldPath = $env:PATH
$logPath = Join-Path $env:TEMP `
    ('questcraft-v71-rc7-lab-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.log')
$backupReady = $false
$previousOutputQuarantined = $false
$outputVerified = $false
try {
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
    Copy-Item -LiteralPath $sourceAar -Destination $backupAar
    Copy-Item -LiteralPath $projectSettings -Destination $backupProjectSettings
    Require ((Get-Sha256 $backupAar) -ceq $aarHash) 'Could not lock source RC7 AAR.'
    Require ((Get-Sha256 $backupProjectSettings) -ceq $projectSettingsHash) `
        'Could not lock RC7 ProjectSettings.'
    $backupReady = $true

    $canonicalWrapper = [IO.Path]::GetFullPath($wrapper)
    $canonicalOutput = [IO.Path]::GetFullPath($outputApk)
    Require ($canonicalOutput.StartsWith(
            $canonicalWrapper + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) 'RC7 output escaped the wrapper project.'
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
            & '.\gradlew.bat' --offline --no-daemon clean testReleaseUnitTest assembleRelease
            Require ($LASTEXITCODE -eq 0) "Pojlib AAR build $buildNumber failed."
        } finally { Pop-Location }
        Assert-Aar $builtAar
        if ($buildNumber -eq 1) {
            Copy-Item -LiteralPath $builtAar -Destination $firstAar
        }
    }
    Require ((Get-Sha256 $firstAar) -ceq (Get-Sha256 $builtAar)) `
        'Two clean RC7 Pojlib builds were not byte-for-byte reproducible.'
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
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $UnityEditor
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $unityArguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Require ($process.Start()) 'Unity RC7 Lab process could not be started.'
        $process.WaitForExit()
        $unityExitCode = $process.ExitCode
    } finally { $process.Dispose() }
    Require ($unityExitCode -eq 0) "Unity RC7 Lab build failed; inspect $logPath"
    Require (Test-Path -LiteralPath $outputApk -PathType Leaf) `
        'Unity produced no RC7 Lab APK.'

    & $verifyApk -ApkPath $outputApk -ExpectedPackage $package `
        -ExpectedVersionCode $versionCode -ExpectedVersionName $versionName `
        -ExpectedLabel $label -ExpectedVivecraftSha256 $coreHash `
        -ExpectedVivecraftVersion $coreVersion -ExpectedAddOnSha256 $veqHash `
        -ExpectedAddOnVersion $veqVersion -ExpectedLwjglSha256 $lwjglHash `
        -ExpectedSignerSha256 $signerHash
    Require ($LASTEXITCODE -eq 0) 'RC7 APK artifact audit failed.'
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
    if ($backupReady -and
            (Test-Path -LiteralPath $backupProjectSettings -PathType Leaf) -and
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
