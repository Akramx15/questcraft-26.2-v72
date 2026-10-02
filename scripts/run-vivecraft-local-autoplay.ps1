<#
.SYNOPSIS
Arms the fixed, authenticated QuestCraft 26.2 / FPS-Stress-Test quick-play gate.

.DESCRIPTION
The gate is process-local and one-shot. This helper never installs, force-stops,
uninstalls, clears data, changes a profile, enters a PIN, changes Guardian, or
writes logcat. Before arming, it fail-closes on a PIN-locked headset or an active
Guardian/6DoF launch-check dialog using read-only CompanionService and activity
dumps. It launches only com.qcxr.qcxr.canary262, reads only the dedicated
QCVivecraftAutoplay tag in memory, and requires -AllowLaunch before contacting a
device.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'ArmAndRun', 'Cancel')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [ValidatePattern('^[A-Za-z0-9_-]*$')]
    [string] $RunId = '',

    [string] $AdbPath = 'adb',

    [ValidateSet('OFF', 'ON')]
    [string] $LauncherCameraPark = 'ON',

    [ValidateSet('OFF', 'ON')]
    [string] $LauncherResourceRelease = 'ON',

    [switch] $AllowLaunch,

    [switch] $AllowReleaseOffControl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LauncherCameraPark = $LauncherCameraPark.ToUpperInvariant()
$LauncherResourceRelease = $LauncherResourceRelease.ToUpperInvariant()
$package = 'com.qcxr.qcxr.canary262'
$component = "$package/pojlib.UnityPlayerActivity"
$armAction = "$package.action.UNATTENDED_ARM"
$executeAction = "$package.action.UNATTENDED_EXECUTE"
$cancelAction = "$package.action.UNATTENDED_CANCEL"
$tag = 'QCVivecraftAutoplay'
$root = Split-Path -Parent $PSScriptRoot

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-SelfTest {
    $gate = Get-Content -Raw -LiteralPath (Join-Path $root 'Pojlib/src/main/java/pojlib/UnattendedLocalTestGate.java')
    $core = Get-Content -Raw -LiteralPath (Join-Path $root 'Pojlib/src/main/java/pojlib/UnattendedStackVerifier.java')
    $api = Get-Content -Raw -LiteralPath (Join-Path $root 'Pojlib/src/main/java/pojlib/API.java')
    $handler = Get-Content -Raw -LiteralPath (Join-Path $root 'Pojlib/src/main/java/pojlib/InstanceHandler.java')
    $jre = Get-Content -Raw -LiteralPath (Join-Path $root 'Pojlib/src/main/java/pojlib/util/JREUtils.java')
    $activity = Get-Content -Raw -LiteralPath (Join-Path $root 'Pojlib/src/main/java/pojlib/UnityPlayerActivity.java')
    $launcher = Get-Content -Raw -LiteralPath (Join-Path $root 'QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs')

    Require ($gate.Contains('EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262"')) 'Package gate changed.'
    Require ($gate.Contains('byte[] challengeBytes = new byte[32]')) 'Challenge is not 256-bit.'
    Require ($gate.Contains('MessageDigest.isEqual')) 'Challenge comparison is not constant-time.'
    Require ($gate.Contains('ARM_TTL_MS = 60_000L')) 'Arm TTL changed.'
    Require ($gate.Contains('PENDING_TTL_MS = 5 * 60_000L')) 'Pending TTL changed.'
    Require ($gate.Contains('circuitOpen = true')) 'One-shot circuit breaker is absent.'
    Require ($gate.Contains('ACTION_CANCEL')) 'Countdown cancellation path is absent.'
    Require ($gate.Contains('EXTRA_LAUNCHER_CAMERA_PARK = "launcher_camera_park"')) `
        'Launcher camera-park mode is not carried by the authenticated gate.'
    Require ($gate.Contains('normalizeCameraParkMode')) `
        'Launcher camera-park mode is not validated fail-closed.'
    Require ($gate.Contains('EXTRA_LAUNCHER_RESOURCE_RELEASE = "launcher_resource_release"')) `
        'Launcher resource-release mode is not carried by the authenticated gate.'
    Require ($gate.Contains('normalizeResourceReleaseMode')) `
        'Launcher resource-release mode is not validated fail-closed.'
    Require ($api.Contains('isLauncherCameraParkEnabled')) `
        'The launcher cannot read the consumed camera-park mode.'
    Require ($api.Contains('shouldReleaseLauncherResources')) `
        'The launcher cannot read the consumed resource-release mode.'
    Require ($api.Contains('abortConsumedUnattendedLocalTestRequest')) `
        'A failed consumed autoplay run cannot clear its camera-park override.'
    Require ($api.Contains('completeConsumedUnattendedLocalTestRequest')) `
        'A completed autoplay run can leak its camera-park override.'
    Require ($core.Contains('PROFILE = "26.2"')) 'Core verifier profile is not fixed.'
    Require ($core.Contains('activity.getAssets().open("mods.json")')) 'Stack verifier does not use the APK manifest.'
    Require ($core.Contains('for(ProjectInfo project : version.coreMods)')) 'Core artifacts are not verified.'
    Require ($core.Contains('for(ProjectInfo project : version.defaultMods)')) 'Default artifacts are not verified.'
    Require ($core.Contains('intentionally ignores disabledMods')) 'Unattended exact-stack policy is undocumented.'
    Require ($api.Contains('account == null')) 'Authenticated account gate is absent.'
    Require ($handler.Contains('launchArgs.add("--quickPlaySingleplayer")')) 'Minecraft Quick Play is absent.'
    Require ($handler.Contains('launchArgs.add("FPS-Stress-Test")')) 'Quick Play save-folder id is not fixed.'
    Require ($handler.Contains(
            'OPENXR_COPY_BATCH_PROPERTY = "-Dvivecraft.openxrCopyBatch="')) `
            'The fixed OpenXR copy-batch JVM property is absent.'
    Require ($handler.Contains('VivecraftCoreCanaryGate.takeOpenXrCopyBatchMode')) `
            'The one-shot OpenXR copy-batch mode claim is absent.'
    Require ($activity.Contains('UnattendedLocalTestGate.handleIntent(this, getIntent())')) 'Cold-start arm is absent.'
    Require ($activity.Contains('UnattendedLocalTestGate.handleIntent(this, intent)')) 'singleTask arm is absent.'
    Require ($launcher.Contains('UnattendedCountdownSeconds = 5')) 'Visible five-second countdown is absent.'
    Require ($launcher.Contains('UnattendedWorld = "FPS-Stress-Test"')) 'Unity save-folder gate is not fixed.'
    Require ($launcher.Contains('JNIStorage.accountObj == null')) 'Unity account readiness gate is absent.'
    Require ($launcher.Contains('verifyUnattendedStackArtifacts')) 'Post-sync full-stack hash gate is absent.'
    Require ($launcher.Contains('ParkLauncherCamerasIfRequested();')) `
        'The post-handoff camera-park hook is absent.'
    Require ($launcher.Contains('Camera.allCameras')) `
        'The camera-park hook does not enumerate active Unity cameras.'
    Require ($launcher.Contains('"DesktopCamera", "Main Camera", "Quester renderer"')) `
        'The camera-park hook is not restricted to the three known launcher cameras.'
    Require ($launcher.Contains('camera.enabled = true;')) `
        'The camera-park hook lacks partial-failure rollback.'
    Require ($launcher.Contains('LauncherResourceReleaseLabPackage = "com.qcxr.qcxr.canary262"')) `
        'The launcher resource release is not pinned to the Lab package.'
    Require ($launcher.Contains('ReleaseLauncherResourcesAfterHandoff();')) `
        'The post-handoff launcher resource-release hook is absent.'
    Require ($launcher.Contains('Resources.UnloadUnusedAssets();')) `
        'The launcher resource-release hook does not request unused-asset release.'
    Require (-not $launcher.Contains('mUnityPlayer.unload')) `
        'The Lab canary must not unload UnityPlayer.'
    Require (-not $jre.Contains('System.out.println(JVMArgs)')) 'Minecraft access token arguments can still be printed.'
    Require ($jre.Contains('Minecraft launch arguments prepared:')) 'Redacted launch diagnostic is absent.'
    $helper = Get-Content -Raw -LiteralPath $PSCommandPath
    Require ($helper.Contains('function Get-NewGateRows')) 'Autoplay does not isolate fresh gate rows.'
    Require ($helper.Contains('function Assert-DeviceLaunchPreflight')) `
            'Autoplay lacks the read-only device launch preflight.'
    Require ($helper.Contains('function Test-PinUnlockEvidence')) `
            'Autoplay does not fail closed on an unclassified PIN state.'
    Require ($helper.Contains("'dumpsys', 'CompanionService'")) `
            'Autoplay does not inspect CompanionService before arming.'
    Require ($helper.Contains("'dumpsys', 'activity', 'activities'")) `
            'Autoplay does not inspect active activities before arming.'
    Require ($helper.Contains('LaunchCheckRequires6dof')) `
            'Autoplay does not recognize the Quest 6DoF launch-check dialog.'
    Require ($helper.Contains('Finding\s+position\s+in\s+(?:the\s+)?room')) `
            'Autoplay does not recognize the Quest room-position dialog.'
    Require ($helper.Contains('QC_AUTOPLAY_ACCEPTED runId=')) `
            'Autoplay does not prove execute acceptance.'
    Require ($helper.Contains("[string] `$LauncherResourceRelease = 'ON'")) `
            'Acceptance runs no longer default to launcher resource release ON.'
    Require ($helper.Contains('AllowReleaseOffControl')) `
            'Release-OFF A/B control runs are not explicitly authorized.'
    $globalClearToken = "'logcat', " + "'-c'"
    Require (-not $helper.Contains($globalClearToken)) 'Autoplay must not clear global logcat.'

    [pscustomobject]@{
        Result = 'PASS'
        Package = $package
        Profile = '26.2'
        World = 'FPS-Stress-Test'
        CountdownSeconds = 5
        DefaultState = 'Camera Park manual Lab ON; Resource Release exact v71 Lab/Stable ON; authenticated Lab A/B can override'
        RawLogsPersisted = $false
    }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sdkAdb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdkAdb -PathType Leaf) { return $sdkAdb }
    throw 'ADB was not found.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $output = @(& $script:Adb @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "ADB failed with exit code $exitCode; output was suppressed."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = @($output | ForEach-Object { [string]$_ }) }
}

function Resolve-Serial {
    if ($Serial -ne 'auto') { return $Serial }
    $devices = @((Invoke-Adb @('devices')).Lines | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { $Matches.serial }
    })
    if ($devices.Count -ne 1) { throw 'Exactly one authorized ADB device is required, or pass -Serial.' }
    return [string]$devices[0]
}

function Get-GateRows {
    $result = Invoke-Adb @('-s', $script:Device, 'logcat', '-d', '-v', 'brief', '-s', "$tag`:I", '*:S') -AllowFailure
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Lines | Where-Object { $_ -match [regex]::Escape($tag) })
}

function Get-NewGateRows([string[]] $BaselineRows) {
    return @(Get-GateRows | Where-Object {
        $row = [string]$_
        $BaselineRows -cnotcontains $row
    })
}

function Get-CheckedDumpText {
    param(
        [Parameter(Mandatory)][psobject] $Result,
        [Parameter(Mandatory)][string] $Name
    )
    if ($Result.ExitCode -ne 0) {
        throw "Device launch preflight could not read $Name; refusing to arm."
    }
    $text = (@($Result.Lines) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Device launch preflight received an empty $Name dump; refusing to arm."
    }
    if ($text -match "(?im)^\s*(?:can't find service|service .+ not found|unknown service|permission denial|error:)") {
        throw "Device launch preflight received an unavailable $Name dump; refusing to arm."
    }
    return $text
}

function Test-PinLockEvidence {
    param([Parameter(Mandatory)][string] $Text)
    $statePatterns = @(
        '(?im)\b(?:pin|device|headset|hmd|keyguard|lock_?screen|lockscreen)\s+locked\s*[:=]\s*(?:true|1|yes|locked)\b',
        '(?im)\bm?(?:is)?(?:pin|device|headset|hmd|keyguard|lock_?screen|lockscreen)[A-Za-z0-9_.-]*locked\s*[:=]\s*(?:true|1|yes|locked)\b',
        '(?im)\bm?(?:is)?(?:keyguard|lock_?screen|lockscreen)[A-Za-z0-9_.-]*showing\s*[:=]\s*(?:true|1|yes|showing)\b',
        '(?im)\bmShowingLockscreen\s*[:=]\s*(?:true|1|yes|showing)\b',
        '(?im)\b(?:pin|device|headset|hmd|keyguard|lock\s*screen|lockscreen)\s+(?:is\s+)?(?:locked|showing|active)\b(?!\s*[:=])',
        '(?im)\b(?:enter|verify|confirm)\s+(?:your\s+)?pin\b'
    )
    return @($statePatterns | Where-Object { $Text -match $_ }).Count -gt 0
}

function Test-PinUnlockEvidence {
    param([Parameter(Mandatory)][string] $Text)
    $statePatterns = @(
        '(?im)\b(?:pin|device|headset|hmd|keyguard|lock_?screen|lockscreen)\s+locked\s*[:=]\s*(?:false|0|no|unlocked)\b',
        '(?im)\bm?(?:is)?(?:pin|device|headset|hmd|keyguard|lock_?screen|lockscreen)[A-Za-z0-9_.-]*locked\s*[:=]\s*(?:false|0|no|unlocked)\b',
        '(?im)\bm?(?:is)?(?:keyguard|lock_?screen|lockscreen)[A-Za-z0-9_.-]*showing\s*[:=]\s*(?:false|0|no|hidden)\b',
        '(?im)\bmShowingLockscreen\s*[:=]\s*(?:false|0|no|hidden)\b',
        '(?im)\b(?:pin|device|headset|hmd|keyguard|lock\s*screen|lockscreen)\s+(?:is\s+)?(?:unlocked|hidden|inactive)\b'
    )
    return @($statePatterns | Where-Object { $Text -match $_ }).Count -gt 0
}

function Test-ActivePinActivityEvidence {
    param([Parameter(Mandatory)][string] $Text)
    $activeRows = @($Text -split "`r?`n" | Where-Object {
        $_ -match '(?i)topResumedActivity|mResumedActivity|ResumedActivity|mCurrentFocus|mFocusedApp'
    })
    return @($activeRows | Where-Object {
        $_ -match '(?i)(?:pinlock|pinunlock|confirmlockpassword|confirmdevicecredential|keyguard|lockscreen)'
    }).Count -gt 0
}

function Test-GuardianLaunchCheckEvidence {
    param([Parameter(Mandatory)][string] $Text)
    $activeRows = @($Text -split "`r?`n" | Where-Object {
        $_ -match '(?i)topResumedActivity|mResumedActivity|ResumedActivity|mCurrentFocus|mFocusedApp'
    })
    return @($activeRows | Where-Object {
        $_ -match '(?i)(?:LaunchCheckRequires6dof|Finding\s+position\s+in\s+(?:the\s+)?room|guardian|boundary|requires6dof|launchcheck)'
    }).Count -gt 0
}

function Assert-DeviceLaunchPreflight {
    $companion = Invoke-Adb @('-s', $script:Device, 'shell',
        'dumpsys', 'CompanionService') -AllowFailure
    $companionText = Get-CheckedDumpText -Result $companion -Name 'CompanionService'

    $activities = Invoke-Adb @('-s', $script:Device, 'shell',
        'dumpsys', 'activity', 'activities') -AllowFailure
    $activityText = Get-CheckedDumpText -Result $activities -Name 'activity'
    if ($activityText -notmatch
            '(?i)topResumedActivity|mResumedActivity|ResumedActivity|mCurrentFocus|mFocusedApp') {
        throw 'Device launch preflight could not identify an active activity; refusing to arm.'
    }

    if ((Test-PinLockEvidence $companionText) -or
            (Test-PinLockEvidence $activityText) -or
            (Test-ActivePinActivityEvidence $activityText)) {
        throw ('Quest PIN/keyguard is locked. Unlock it in the headset, return to a safe ' +
            'Home view, and retry; this helper never enters a PIN.')
    }
    if (-not (Test-PinUnlockEvidence $companionText) -and
            -not (Test-PinUnlockEvidence $activityText)) {
        throw ('Device launch preflight could not determine the Quest PIN lock state from ' +
            'the read-only dumps; refusing to arm.')
    }
    if (Test-GuardianLaunchCheckEvidence $activityText) {
        throw ('Quest Guardian/6DoF launch check is active. Finish room-position or boundary ' +
            'setup in the headset and retry; this helper never clicks or changes Guardian.')
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    exit 0
}
if (-not $AllowLaunch) {
    throw 'Device launch is disabled by default. Re-run with -AllowLaunch.'
}
if ($Action -eq 'ArmAndRun' -and $LauncherResourceRelease -ceq 'OFF' -and
        -not $AllowReleaseOffControl) {
    throw 'Release OFF is reserved for an explicitly authorized A/B control run.'
}

$script:Adb = Resolve-Adb
$script:Device = Resolve-Serial
$installed = Invoke-Adb @('-s', $script:Device, 'shell', 'pm', 'path', $package) -AllowFailure
if ($installed.ExitCode -ne 0 -or @($installed.Lines | Where-Object { $_ -match '^package:' }).Count -eq 0) {
    throw "$package is not installed on the selected device."
}

if ($Action -eq 'Cancel') {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw '-RunId is required for Cancel.' }
    $null = Invoke-Adb @('-s', $script:Device, 'shell', 'am', 'start', '-n', $component,
        '-a', $cancelAction, '--es', 'run_id', $RunId)
    [pscustomobject]@{ Result = 'CANCEL_SENT'; Package = $package; RawLogsPersisted = $false }
    exit 0
}

Assert-DeviceLaunchPreflight
$beforeArm = @(Get-GateRows)
$null = Invoke-Adb @('-s', $script:Device, 'shell', 'am', 'start', '-n', $component, '-a', $armAction)
$challengeMatch = $null
for ($attempt = 0; $attempt -lt 20 -and $null -eq $challengeMatch; $attempt++) {
    Start-Sleep -Milliseconds 250
    $rows = @(Get-NewGateRows $beforeArm)
    if (@($rows | Where-Object { $_ -match 'QC_AUTOPLAY_(?:REJECTED|CIRCUIT_OPEN)' }).Count -gt 0) {
        throw 'The fresh autoplay arm request was rejected by the process-local gate.'
    }
    $challengeRows = @($rows | Where-Object { $_ -match 'QC_AUTOPLAY_CHALLENGE' })
    if ($challengeRows.Count -gt 0) {
        $candidate = [regex]::Match($challengeRows[-1],
            'runId=(?<run>[A-Za-z0-9_-]+) challenge=(?<challenge>[A-Za-z0-9_-]+)')
        if ($candidate.Success) { $challengeMatch = $candidate }
    }
}
if ($null -eq $challengeMatch) { throw 'The process-local autoplay challenge was not observed.' }

$armedRunId = $challengeMatch.Groups['run'].Value
$challenge = $challengeMatch.Groups['challenge'].Value
$beforeExecute = @(Get-GateRows)
$null = Invoke-Adb @('-s', $script:Device, 'shell', 'am', 'start', '-n', $component,
    '-a', $executeAction, '--es', 'run_id', $armedRunId, '--es', 'challenge', $challenge,
    '--es', 'launcher_camera_park', $LauncherCameraPark,
    '--es', 'launcher_resource_release', $LauncherResourceRelease)
$challenge = $null

$accepted = $false
$acceptedPattern = 'QC_AUTOPLAY_ACCEPTED runId=' + [regex]::Escape($armedRunId) +
        '\s+launcherCameraPark=' + [regex]::Escape($LauncherCameraPark) +
        '\s+launcherResourceRelease=' + [regex]::Escape($LauncherResourceRelease) + '(?:\s|$)'
for ($attempt = 0; $attempt -lt 40 -and -not $accepted; $attempt++) {
    Start-Sleep -Milliseconds 250
    $rows = @(Get-NewGateRows $beforeExecute)
    if (@($rows | Where-Object { $_ -match 'QC_AUTOPLAY_(?:REJECTED|CIRCUIT_OPEN)' }).Count -gt 0) {
        throw 'The fresh autoplay execute request was rejected by the process-local gate.'
    }
    $accepted = @($rows | Where-Object { $_ -match $acceptedPattern }).Count -gt 0
}
if (-not $accepted) { throw 'The fresh autoplay execute request was not accepted.' }

[pscustomobject]@{
    Result = 'ARMED'
    Package = $package
    Profile = '26.2'
    World = 'FPS-Stress-Test'
    CountdownSeconds = 5
    LauncherCameraPark = $LauncherCameraPark
    LauncherResourceRelease = $LauncherResourceRelease
    CancellationRunId = $armedRunId
    RawLogsPersisted = $false
}
