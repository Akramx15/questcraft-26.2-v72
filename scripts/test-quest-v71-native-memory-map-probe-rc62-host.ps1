#requires -Version 7.0
<# Host-only regression test for the fixed RC6.2 aggregate memory-map probe. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC6_2_NATIVE_MAP_HOST_TEST] $Message" }
}

$tool = Join-Path $PSScriptRoot 'quest-v71-native-memory-map-probe-rc62.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -Raw -LiteralPath `
    (Join-Path $repoRoot 'V71_LAB_RC6_2.lock.json') | ConvertFrom-Json
$sentinel = Join-Path $PSScriptRoot '__native-map-probe-no-adb__.exe'
Require (Test-Path -LiteralPath $tool -PathType Leaf) 'Probe tool is missing.'
Require (-not (Test-Path -LiteralPath $sentinel)) 'ADB sentinel unexpectedly exists.'

$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    $tool, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'PowerShell parser rejected the probe tool.'

$self = @(& $tool -Action SelfTest -AdbPath $sentinel)
Require ($self.Count -eq 1 -and [string]$self[0].Result -ceq 'PASS') `
    'SelfTest did not return one PASS result.'
Require ([bool]$self[0].HostOnly -and [int]$self[0].DeviceInvocations -eq 0 -and
        -not [bool]$self[0].StableTouched) `
    'SelfTest touched or resolved a device/Stable.'
Require ([int]$self[0].AggregateSchema -eq 2 -and
        [bool]$self[0].UnknownFieldFixtureRejected -and
        [bool]$self[0].LegacySchemaFixtureRejected -and
        -not [bool]$self[0].RawMappingNamesPersisted -and
        -not [bool]$self[0].RawMappingAddressesPersisted) `
    'SelfTest did not prove the aggregate-only schema boundary.'
Require (-not (Test-Path -LiteralPath $sentinel)) `
    'SelfTest attempted to resolve or create the ADB sentinel.'

$statusRejected = $false
try { & $tool -Action Status -AdbPath $sentinel | Out-Null }
catch { $statusRejected = $_.Exception.Message.Contains('-AllowDeviceRead') }
Require $statusRejected 'Status did not require explicit device-read authorization.'
Require (-not (Test-Path -LiteralPath $sentinel)) `
    'Missing-read-authorization fixture resolved ADB.'

$armRejected = $false
try { & $tool -Action Arm -AdbPath $sentinel -AllowDeviceRead | Out-Null }
catch { $armRejected = $_.Exception.Message.Contains('-AllowDeviceWrite') }
Require $armRejected 'Arm did not require explicit device-write authorization.'
Require (-not (Test-Path -LiteralPath $sentinel)) `
    'Missing-write-authorization fixture resolved ADB.'

$source = [IO.File]::ReadAllText($tool)
Require ($source.Contains("[ValidateSet('SelfTest', 'Status', 'Arm', 'Collect', 'Disarm')") -and
        $source.Contains("[string] `$Action = 'SelfTest'") -and
        $source.Contains("'com.qcxr.qcxr.canary262'") -and
        $source.Contains("'com.qcxr.qcxr.dev262'") -and
        $source.Contains('Lab must be stopped first; this tool never force-stops or launches it.') -and
        $source.Contains('Collection output must be a new directory under artifacts/memory.') -and
        $source.Contains('Unknown/raw mapping fields were not rejected.') -and
        $source.Contains('AggregateOutputsPreserved = `$true'.Replace('`$', '$'))) `
    'Fail-closed action, package, stop-state, output, or preservation boundary drifted.'

foreach ($forbidden in @(
    "'install'", "'uninstall'", "'clear'", "'force-stop'", "'am', 'start'",
    "'monkey'", '/data/data/com.qcxr.qcxr.dev262',
    '/sdcard/Android/data/com.qcxr.qcxr.dev262'
)) {
    Require (-not $source.Contains($forbidden, [StringComparison]::Ordinal)) `
        "Probe source contains forbidden device operation/path: $forbidden"
}
Require ([string]$lock.target.package -ceq 'com.qcxr.qcxr.canary262' -and
        [string]$lock.target.forbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
        [int]$lock.target.versionCode -eq 71 -and
        [string]$lock.target.versionName -ceq
            '6.0.1-26.2-vivecraft-personal.12-rc.6.2') `
    'Immutable RC6.2 identity drifted.'

# Exercise the full device-facing flow against a native-process mock. The mock
# records every requested argument so this regression test can prove that Arm,
# Collect, and Disarm remain limited to the fixed Lab marker and aggregate
# files without requiring a real Quest.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('v71-native-map-probe-host-' + [guid]::NewGuid().ToString('N'))
$artifactRelative = 'artifacts/memory/__v71-native-map-probe-host-' + `
    [guid]::NewGuid().ToString('N')
$invalidArtifactRelative = $artifactRelative + '-invalid'
$artifactPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $artifactRelative))
$invalidArtifactPath = [IO.Path]::GetFullPath(
    (Join-Path $repoRoot $invalidArtifactRelative))
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts\memory'))
$artifactPrefix = $artifactRoot.TrimEnd('\') + '\'
Require ($artifactPath.StartsWith($artifactPrefix,
        [StringComparison]::OrdinalIgnoreCase) -and
        $invalidArtifactPath.StartsWith($artifactPrefix,
            [StringComparison]::OrdinalIgnoreCase)) `
    'Mock collection target escaped artifacts/memory.'
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

$mockCommand = Join-Path $fixtureRoot 'mock-adb.cmd'
$mockCommandSource = @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
>>"%V71_NATIVE_MAP_MOCK_ROOT%\invocations.log" echo %*
if "%~1"=="devices" goto devices
if not "%~1"=="-s" exit /b 90
if not "%~2"=="fixture-quest" exit /b 91
if "%~3"=="exec-out" goto execout
if not "%~3"=="shell" exit /b 92
if "%~4"=="dumpsys" goto dumpsys
if "%~4"=="pm" goto pmpath
if "%~4"=="sha256sum" goto sha256
if "%~4"=="pidof" goto pidof
if "%~4"=="test" goto testfile
if "%~4"=="mkdir" exit /b 0
if "%~4"=="touch" goto touch
if "%~4"=="chmod" exit /b 0
if "%~4"=="rm" goto remove
if "%~4"=="stat" goto statfile
exit /b 99

:devices
echo List of devices attached
echo fixture-quest device product:fixture
exit /b 0

:dumpsys
if not "%~5"=="package" exit /b 93
if not "%~6"=="com.qcxr.qcxr.canary262" exit /b 94
echo   versionCode=%V71_NATIVE_MAP_MOCK_VERSION_CODE% minSdk=29 targetSdk=34
echo   versionName=%V71_NATIVE_MAP_MOCK_VERSION_NAME%
exit /b 0

:pmpath
if not "%~5"=="path" exit /b 95
if not "%~6"=="com.qcxr.qcxr.canary262" exit /b 96
echo package:/data/app/~~fixture/com.qcxr.qcxr.canary262-fixture/base.apk
exit /b 0

:sha256
if "%~5"=="/data/app/~~fixture/com.qcxr.qcxr.canary262-fixture/base.apk" (
  echo %V71_NATIVE_MAP_MOCK_APK_SHA%  %~5
  exit /b 0
)
if "%~5"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft.jar" (
  echo %V71_NATIVE_MAP_MOCK_CORE_SHA%  %~5
  exit /b 0
)
if "%~5"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft-Essentials-Quest.jar" (
  echo %V71_NATIVE_MAP_MOCK_VEQ_SHA%  %~5
  exit /b 0
)
exit /b 1

:pidof
if exist "%V71_NATIVE_MAP_MOCK_ROOT%\running" (
  echo 4242
  exit /b 0
)
exit /b 1

:testfile
if not "%~5"=="-f" exit /b 97
if "%~6"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/.questcraft-lab/enable-memory-map-probe" (
  if exist "%V71_NATIVE_MAP_MOCK_ROOT%\armed" exit /b 0
  exit /b 1
)
if "%~6"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/.questcraft-lab/native-memory-maps/smaps-aggregates.jsonl" (
  if exist "%V71_NATIVE_MAP_MOCK_ROOT%\smaps-aggregates.jsonl" exit /b 0
)
exit /b 1

:touch
if not "%~5"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/.questcraft-lab/enable-memory-map-probe" exit /b 98
type nul >"%V71_NATIVE_MAP_MOCK_ROOT%\armed"
exit /b 0

:remove
if not "%~5"=="-f" exit /b 98
if not "%~6"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/.questcraft-lab/enable-memory-map-probe" exit /b 98
del /q "%V71_NATIVE_MAP_MOCK_ROOT%\armed" >nul 2>nul
exit /b 0

:statfile
if not "%~7"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/.questcraft-lab/native-memory-maps/smaps-aggregates.jsonl" exit /b 1
if not exist "%V71_NATIVE_MAP_MOCK_ROOT%\smaps-aggregates.jsonl" exit /b 1
for %%I in ("%V71_NATIVE_MAP_MOCK_ROOT%\smaps-aggregates.jsonl") do echo %%~zI
exit /b 0

:execout
if not "%~4"=="cat" exit /b 1
if not "%~5"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/.questcraft-lab/native-memory-maps/smaps-aggregates.jsonl" exit /b 1
if not exist "%V71_NATIVE_MAP_MOCK_ROOT%\smaps-aggregates.jsonl" exit /b 1
type "%V71_NATIVE_MAP_MOCK_ROOT%\smaps-aggregates.jsonl"
exit /b 0
'@

$metrics = [ordered]@{}
foreach ($field in @(
    'mappings', 'sizeKiB', 'rssKiB', 'pssKiB', 'privateCleanKiB',
    'privateDirtyKiB', 'sharedCleanKiB', 'sharedDirtyKiB', 'anonymousKiB',
    'swapKiB', 'swapPssKiB'
)) { $metrics[$field] = 0 }
$metrics.mappings = 1
$metrics.sizeKiB = 2048
$metrics.rssKiB = 1024
$metrics.pssKiB = 896
$validFixture = [ordered]@{
    schema = 2
    elapsedRealtimeMs = 60000
    total = $metrics
    categories = [ordered]@{ anonymousPrivate = $metrics }
    sizeBuckets = [ordered]@{ '1MiBTo16MiB' = $metrics }
    categorySizeBuckets = [ordered]@{
        anonymousPrivate = [ordered]@{ '1MiBTo16MiB' = $metrics }
    }
    topAnonymousPrivateMappings = @([ordered]@{
        sizeKiB = 2048; rssKiB = 1024; pssKiB = 896
        privateDirtyKiB = 768; anonymousKiB = 1024; swapKiB = 0
        permissions = 'rw-p'
    })
}
$validLine = $validFixture | ConvertTo-Json -Depth 20 -Compress

$oldMockRoot = $env:V71_NATIVE_MAP_MOCK_ROOT
$oldVersionCode = $env:V71_NATIVE_MAP_MOCK_VERSION_CODE
$oldVersionName = $env:V71_NATIVE_MAP_MOCK_VERSION_NAME
$oldApkSha = $env:V71_NATIVE_MAP_MOCK_APK_SHA
$oldCoreSha = $env:V71_NATIVE_MAP_MOCK_CORE_SHA
$oldVeqSha = $env:V71_NATIVE_MAP_MOCK_VEQ_SHA
try {
    [IO.File]::WriteAllText($mockCommand, $mockCommandSource + "`r`n",
        [Text.ASCIIEncoding]::new())
    [IO.File]::WriteAllText(
        (Join-Path $fixtureRoot 'smaps-aggregates.jsonl'), $validLine + "`n",
        [Text.UTF8Encoding]::new($false))
    $env:V71_NATIVE_MAP_MOCK_ROOT = $fixtureRoot
    $env:V71_NATIVE_MAP_MOCK_VERSION_CODE = [string]$lock.target.versionCode
    $env:V71_NATIVE_MAP_MOCK_VERSION_NAME = [string]$lock.target.versionName
    $env:V71_NATIVE_MAP_MOCK_APK_SHA = [string]$lock.target.apkSha256
    $env:V71_NATIVE_MAP_MOCK_CORE_SHA = [string]$lock.pair.core.sha256
    $env:V71_NATIVE_MAP_MOCK_VEQ_SHA = [string]$lock.pair.veq.sha256

    $mockBoot = @(& $mockCommand devices 2>&1 | ForEach-Object { [string]$_ })
    Require ($LASTEXITCODE -eq 0 -and $mockBoot -contains 'fixture-quest device product:fixture') `
        ('Native mock bootstrap failed: ' + ([string]::Join(' | ', $mockBoot)))

    $status = @(& $tool -Action Status -AdbPath $mockCommand `
        -Serial fixture-quest -AllowDeviceRead)
    Require ($status.Count -eq 1 -and [string]$status[0].Result -ceq 'PASS' -and
            -not [bool]$status[0].Armed -and -not [bool]$status[0].StableTouched) `
        'Mock Status failed its exact Lab/unarmed contract.'

    $arm = @(& $tool -Action Arm -AdbPath $mockCommand -Serial fixture-quest `
        -AllowDeviceRead -AllowDeviceWrite)
    Require ($arm.Count -eq 1 -and [string]$arm[0].Result -ceq 'PASS' -and
            (Test-Path -LiteralPath (Join-Path $fixtureRoot 'armed')) -and
            -not [bool]$arm[0].AppLaunched -and -not [bool]$arm[0].AppStopped) `
        'Mock Arm did not create only the exact fixed marker.'

    $collect = @(& $tool -Action Collect -AdbPath $mockCommand `
        -Serial fixture-quest -AllowDeviceRead -OutputDirectory $artifactRelative)
    Require ($collect.Count -eq 1 -and [string]$collect[0].Result -ceq 'PASS' -and
            [int]$collect[0].SampleCount -eq 1 -and
            (Test-Path -LiteralPath $artifactPath -PathType Container)) `
        'Mock Collect did not persist one validated aggregate sample.'
    $receipt = Get-Content -Raw -LiteralPath `
        (Join-Path $artifactPath 'COLLECTION_RECEIPT.json') | ConvertFrom-Json
    Require ([string]$receipt.status -ceq 'COLLECTED_VALIDATED_AGGREGATE_ONLY' -and
            [bool]$receipt.validation.aggregateOnly -and
            -not [bool]$receipt.validation.rawMappingNamesPersisted -and
            -not [bool]$receipt.validation.rawMappingAddressesPersisted -and
            -not [bool]$receipt.validation.stableTouched) `
        'Mock collection receipt weakened the privacy or Stable boundary.'

    $invalid = $validFixture | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
    $invalid | Add-Member -NotePropertyName rawMappingPath `
        -NotePropertyValue '/data/private/secret-map'
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'smaps-aggregates.jsonl'),
        (($invalid | ConvertTo-Json -Depth 20 -Compress) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $invalidRejected = $false
    try {
        & $tool -Action Collect -AdbPath $mockCommand -Serial fixture-quest `
            -AllowDeviceRead -OutputDirectory $invalidArtifactRelative | Out-Null
    } catch { $invalidRejected = $true }
    Require ($invalidRejected -and -not (Test-Path -LiteralPath $invalidArtifactPath)) `
        'Mock Collect persisted an unknown/raw mapping field.'

    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'running'), '4242')
    $runningRejected = $false
    try {
        & $tool -Action Disarm -AdbPath $mockCommand -Serial fixture-quest `
            -AllowDeviceRead -AllowDeviceWrite | Out-Null
    } catch { $runningRejected = $_.Exception.Message.Contains('must be stopped first') }
    Require ($runningRejected -and
            (Test-Path -LiteralPath (Join-Path $fixtureRoot 'armed'))) `
        'Disarm did not fail closed while mock Lab was running.'
    Remove-Item -LiteralPath (Join-Path $fixtureRoot 'running') -Force

    $disarm = @(& $tool -Action Disarm -AdbPath $mockCommand `
        -Serial fixture-quest -AllowDeviceRead -AllowDeviceWrite)
    Require ($disarm.Count -eq 1 -and [string]$disarm[0].Result -ceq 'PASS' -and
            -not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'armed')) -and
            [bool]$disarm[0].AggregateOutputsPreserved -and
            (Test-Path -LiteralPath (Join-Path $fixtureRoot 'smaps-aggregates.jsonl'))) `
        'Mock Disarm removed more than the fixed marker or failed.'

    $invocations = [IO.File]::ReadAllText((Join-Path $fixtureRoot 'invocations.log'))
    Require ($invocations -notmatch
            '(?i)(?:^|\s)(install|uninstall|clear|force-stop|monkey)(?:\s|$)' -and
            -not $invocations.Contains('com.qcxr.qcxr.dev262',
                [StringComparison]::Ordinal)) `
        'Mock ADB log contained a destructive command or Stable package.'
} catch {
    $tracePath = Join-Path $fixtureRoot 'invocations.log'
    $trace = if (Test-Path -LiteralPath $tracePath -PathType Leaf) {
        [IO.File]::ReadAllText($tracePath)
    } else { '<no mock invocation log>' }
    throw "Mock device-flow fixture failed. Invocations:`n$trace`n$($_.Exception.Message)"
} finally {
    $env:V71_NATIVE_MAP_MOCK_ROOT = $oldMockRoot
    $env:V71_NATIVE_MAP_MOCK_VERSION_CODE = $oldVersionCode
    $env:V71_NATIVE_MAP_MOCK_VERSION_NAME = $oldVersionName
    $env:V71_NATIVE_MAP_MOCK_APK_SHA = $oldApkSha
    $env:V71_NATIVE_MAP_MOCK_CORE_SHA = $oldCoreSha
    $env:V71_NATIVE_MAP_MOCK_VEQ_SHA = $oldVeqSha
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        Require ($resolvedFixture.StartsWith(
            [IO.Path]::GetFullPath([IO.Path]::GetTempPath()),
            [StringComparison]::OrdinalIgnoreCase)) `
            'Refusing to remove mock fixture outside the Temp directory.'
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
    foreach ($path in @($artifactPath, $invalidArtifactPath)) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            Require ($path.StartsWith($artifactPrefix,
                    [StringComparison]::OrdinalIgnoreCase)) `
                'Refusing to remove mock artifact outside artifacts/memory.'
            Remove-Item -LiteralPath $path -Recurse -Force
        }
        Get-ChildItem -LiteralPath $artifactRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like ([IO.Path]::GetFileName($path) + '.partial-*') } |
            ForEach-Object {
                Require ($_.FullName.StartsWith($artifactPrefix,
                        [StringComparison]::OrdinalIgnoreCase)) `
                    'Refusing to remove partial mock artifact outside artifacts/memory.'
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
            }
    }
}

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    PowerShellParsePassed = $true
    DefaultSelfTestPassed = $true
    MissingReadAuthorizationRejectedBeforeAdb = $true
    MissingWriteAuthorizationRejectedBeforeAdb = $true
    LabOnlyIdentityBound = $true
    AggregateSchema2Only = $true
    UnknownAndRawFieldsRejected = $true
    OutputRestrictedToArtifactsMemory = $true
    MarkerOnlyDeviceWrite = $true
    AggregateOutputsPreservedOnDisarm = $true
    FullMockStatusArmCollectDisarmPassed = $true
    RunningLabRejected = $true
    RawFieldCollectionRejectedWithoutArtifact = $true
    MockAdbLogContainsNoStableOrDestructiveCommand = $true
    InstallLaunchStopClearOperationsAbsent = $true
    StableTouched = $false
}
