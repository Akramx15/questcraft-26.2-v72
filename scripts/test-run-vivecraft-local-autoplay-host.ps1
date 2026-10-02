#requires -Version 7.0
<# Host-only Fake-ADB regression tests for the local autoplay preflight. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[AUTOPLAY_HOST_TEST] $Message" }
}

$production = Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('quest-autoplay-host-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$fakePs1 = Join-Path $testRoot 'fake-adb.ps1'
$fakeCommand = if ($IsWindows) {
    Join-Path $testRoot 'fake-adb.cmd'
} else {
    Join-Path $testRoot 'fake-adb'
}
$callLog = Join-Path $testRoot 'adb-calls.jsonl'
$utf8 = [Text.UTF8Encoding]::new($false)

$fakeSource = @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $FakeArgs)
$ErrorActionPreference = 'Stop'
$entry = [ordered]@{ Arguments = @($FakeArgs) } | ConvertTo-Json -Compress
[IO.File]::AppendAllText($env:QC_AUTOPLAY_FAKE_LOG, $entry + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$scenario = [string]$env:QC_AUTOPLAY_FAKE_SCENARIO

if ($FakeArgs.Count -eq 1 -and $FakeArgs[0] -ceq 'devices') {
    Write-Output 'List of devices attached'
    Write-Output "QUEST_FAKE`tdevice product:fake model:Quest_3"
    exit 0
}
if ($FakeArgs.Count -eq 6 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[1] -ceq 'QUEST_FAKE' -and $FakeArgs[2] -ceq 'shell' -and
        $FakeArgs[3] -ceq 'pm' -and $FakeArgs[4] -ceq 'path' -and
        $FakeArgs[5] -ceq 'com.qcxr.qcxr.canary262') {
    Write-Output 'package:/data/app/fake/base.apk'
    exit 0
}
if ($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[1] -ceq 'QUEST_FAKE' -and $FakeArgs[2] -ceq 'shell' -and
        $FakeArgs[3] -ceq 'dumpsys' -and $FakeArgs[4] -ceq 'CompanionService') {
    if ($scenario -ceq 'companion-failure') { exit 41 }
    if ($scenario -ceq 'companion-empty') { exit 0 }
    if ($scenario -ceq 'companion-unavailable') {
        Write-Output "Can't find service: CompanionService"
        exit 0
    }
    if ($scenario -ceq 'companion-unclassified') {
        Write-Output 'Battery: 100'
        exit 0
    }
    switch ($scenario) {
        'pin-spaced-locked' {
            Write-Output 'PIN configured: true'
            Write-Output 'PIN locked: true'
        }
        'pin-spaced-unlocked' {
            Write-Output 'PIN configured: true'
            Write-Output 'PIN locked: false'
        }
        'pin-m-is' { Write-Output 'mIsPinLocked = true' }
        'pin-device' { Write-Output 'deviceLocked: locked' }
        'pin-message' { Write-Output 'Please enter your PIN' }
        'pin-showing-lockscreen' { Write-Output 'mShowingLockscreen=true' }
        default {
            Write-Output 'CompanionService state:'
            Write-Output '  mIsPinLocked=false'
            Write-Output '  keyguardShowing=0'
        }
    }
    exit 0
}
if ($FakeArgs.Count -eq 6 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[1] -ceq 'QUEST_FAKE' -and $FakeArgs[2] -ceq 'shell' -and
        $FakeArgs[3] -ceq 'dumpsys' -and $FakeArgs[4] -ceq 'activity' -and
        $FakeArgs[5] -ceq 'activities') {
    if ($scenario -ceq 'activity-failure') { exit 42 }
    if ($scenario -ceq 'activity-empty') { exit 0 }
    if ($scenario -ceq 'activity-denied') {
        Write-Output 'Permission Denial: cannot dump ActivityManager'
        exit 0
    }
    if ($scenario -ceq 'activity-unclassified') {
        Write-Output 'ACTIVITY MANAGER ACTIVITIES'
        exit 0
    }
    switch ($scenario) {
        'pin-active' {
            Write-Output 'topResumedActivity=ActivityRecord{1 com.oculus.systemux/.ConfirmLockPassword}'
        }
        'guardian-requires6dof' {
            Write-Output 'topResumedActivity=ActivityRecord{2 com.oculus.vrshell/.LaunchCheckRequires6dof}'
        }
        'guardian-room-position' {
            Write-Output 'mResumedActivity: ActivityRecord{3 com.oculus.vrshell/.MainActivity Finding position in the room}'
        }
        'guardian-active' {
            Write-Output 'mCurrentFocus=Window{4 com.oculus.guardian/.GuardianBoundaryActivity}'
        }
        'stale-inactive-records' {
            Write-Output 'topResumedActivity=ActivityRecord{5 com.oculus.vrshell/.MainActivity}'
            Write-Output '* Hist #1: ActivityRecord{6 com.oculus.vrshell/.LaunchCheckRequires6dof}'
            Write-Output '* Hist #2: ActivityRecord{7 com.oculus.systemux/.ConfirmLockPassword}'
        }
        default {
            Write-Output 'topResumedActivity=ActivityRecord{5 com.oculus.vrshell/.MainActivity}'
        }
    }
    exit 0
}
if ($FakeArgs.Count -ge 3 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[1] -ceq 'QUEST_FAKE' -and $FakeArgs[2] -ceq 'logcat') {
    $calls = @(Get-Content -LiteralPath $env:QC_AUTOPLAY_FAKE_LOG | ForEach-Object {
        ConvertFrom-Json $_
    })
    $logcatCount = @($calls | Where-Object { @($_.Arguments) -ccontains 'logcat' }).Count
    if ($logcatCount -ge 2) {
        Write-Output 'I/QCVivecraftAutoplay: QC_AUTOPLAY_CHALLENGE runId=fake_run challenge=fake_challenge'
    }
    if ($logcatCount -ge 4) {
        Write-Output 'I/QCVivecraftAutoplay: QC_AUTOPLAY_ACCEPTED runId=fake_run launcherCameraPark=ON launcherResourceRelease=ON'
    }
    exit 0
}
if ($FakeArgs.Count -ge 8 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[1] -ceq 'QUEST_FAKE' -and $FakeArgs[2] -ceq 'shell' -and
        $FakeArgs[3] -ceq 'am' -and $FakeArgs[4] -ceq 'start' -and
        $FakeArgs[5] -ceq '-n' -and
        $FakeArgs[6] -ceq 'com.qcxr.qcxr.canary262/pojlib.UnityPlayerActivity') {
    exit 0
}
Write-Error ('Unexpected fake ADB argv: ' + ($FakeArgs -join ' | '))
exit 91
'@

[IO.File]::WriteAllText($fakePs1, $fakeSource, $utf8)
if ($IsWindows) {
    [IO.File]::WriteAllText($fakeCommand,
        "@echo off`r`npwsh -NoLogo -NoProfile -NonInteractive -File `"%~dp0fake-adb.ps1`" %*`r`n",
        [Text.Encoding]::ASCII)
} else {
    [IO.File]::WriteAllText($fakeCommand,
        "#!/bin/sh`nexec pwsh -NoLogo -NoProfile -NonInteractive -File `"`$(dirname `"`$0`")/fake-adb.ps1`" `"`$@`"`n",
        $utf8)
    [IO.File]::SetUnixFileMode($fakeCommand,
        [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor
        [IO.UnixFileMode]::UserExecute)
}

function Read-Calls {
    if (-not (Test-Path -LiteralPath $callLog)) { return @() }
    return @(Get-Content -LiteralPath $callLog | ForEach-Object {
        $parsed = ConvertFrom-Json $_
        [pscustomobject]@{ Arguments = @($parsed.Arguments) }
    })
}

function Invoke-Scenario([string] $Name) {
    $env:QC_AUTOPLAY_FAKE_SCENARIO = $Name
    if (Test-Path -LiteralPath $callLog) { Remove-Item -LiteralPath $callLog -Force }
    $output = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $production `
        -Action ArmAndRun -Serial auto -AdbPath $fakeCommand -AllowLaunch 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = ($output -join "`n")
        Calls = @(Read-Calls)
    }
}

function Assert-NoArm([psobject] $Result, [string] $Name) {
    Require ($Result.ExitCode -ne 0) "$Name unexpectedly succeeded."
    Require (@($Result.Calls | Where-Object {
        @($_.Arguments) -ccontains 'am'
    }).Count -eq 0) "$Name reached am start before failing."
    Require (@($Result.Calls | Where-Object {
        @($_.Arguments) -ccontains 'logcat'
    }).Count -eq 0) "$Name reached gate-log polling before failing."
}

function Assert-ReadOnlyAndLabOnly([object[]] $Calls) {
    foreach ($call in $Calls) {
        $argv = @($call.Arguments)
        $joined = ' ' + ($argv -join ' ').ToLowerInvariant() + ' '
        foreach ($forbidden in @(
            'com.qcxr.qcxr.dev262', ' input ', ' tap ', ' keyevent ', ' swipe ',
            ' settings ', ' setprop ', ' guardian ', ' boundary ', ' install ',
            ' uninstall ', ' pm clear ', ' force-stop ', ' monkey ', ' su '
        )) {
            Require (-not $joined.Contains($forbidden)) `
                "Observed forbidden fake-ADB command token '$forbidden' in: $joined"
        }
        if ($argv -ccontains 'am') {
            Require ($argv -ccontains 'com.qcxr.qcxr.canary262/pojlib.UnityPlayerActivity') `
                'An activity start was not fixed to the Lab component.'
        }
    }
}

$savedLog = $env:QC_AUTOPLAY_FAKE_LOG
$savedScenario = $env:QC_AUTOPLAY_FAKE_SCENARIO
$passed = 0
try {
    $env:QC_AUTOPLAY_FAKE_LOG = $callLog

    # SelfTest must remain a zero-device default even when given an executable fake.
    if (Test-Path -LiteralPath $callLog) { Remove-Item -LiteralPath $callLog -Force }
    $selfTest = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $production `
        -Action SelfTest -AdbPath $fakeCommand 2>&1)
    Require ($LASTEXITCODE -eq 0 -and ($selfTest -join "`n") -match 'PASS') `
        'Production SelfTest failed.'
    Require (-not (Test-Path -LiteralPath $callLog)) 'SelfTest invoked fake ADB.'
    $passed++

    $failureCases = @(
        @{ Name='companion-failure'; Pattern='could not read CompanionService' },
        @{ Name='companion-empty'; Pattern='empty CompanionService dump' },
        @{ Name='companion-unavailable'; Pattern='unavailable CompanionService dump' },
        @{ Name='companion-unclassified'; Pattern='could not determine the Quest PIN lock state' },
        @{ Name='activity-failure'; Pattern='could not read activity' },
        @{ Name='activity-empty'; Pattern='empty activity dump' },
        @{ Name='activity-denied'; Pattern='unavailable activity dump' },
        @{ Name='activity-unclassified'; Pattern='could not identify an active activity' },
        @{ Name='pin-m-is'; Pattern='PIN/keyguard is locked' },
        @{ Name='pin-spaced-locked'; Pattern='PIN/keyguard is locked' },
        @{ Name='pin-device'; Pattern='PIN/keyguard is locked' },
        @{ Name='pin-message'; Pattern='PIN/keyguard is locked' },
        @{ Name='pin-showing-lockscreen'; Pattern='PIN/keyguard is locked' },
        @{ Name='pin-active'; Pattern='PIN/keyguard is locked' },
        @{ Name='guardian-requires6dof'; Pattern='Guardian/6DoF launch check is active' },
        @{ Name='guardian-room-position'; Pattern='Guardian/6DoF launch check is active' },
        @{ Name='guardian-active'; Pattern='Guardian/6DoF launch check is active' }
    )
    $allCalls = @()
    foreach ($case in $failureCases) {
        $result = Invoke-Scenario $case.Name
        Assert-NoArm $result $case.Name
        Require ($result.Text -match $case.Pattern) `
            "$($case.Name) did not surface its clear refusal: $($result.Text)"
        $allCalls += @($result.Calls)
        $passed++
    }

    $success = Invoke-Scenario 'success'
    Require ($success.ExitCode -eq 0) "Clean fake state failed: $($success.Text)"
    Require ($success.Text -match 'ARMED') 'Clean fake state did not arm.'
    $amCalls = @($success.Calls | Where-Object { @($_.Arguments) -ccontains 'am' })
    Require ($amCalls.Count -eq 2) 'Clean fake state did not send exactly arm and execute.'
    Require (@($amCalls | Where-Object {
        @($_.Arguments) -ccontains 'com.qcxr.qcxr.canary262.action.UNATTENDED_ARM'
    }).Count -eq 1 -and @($amCalls | Where-Object {
        @($_.Arguments) -ccontains 'com.qcxr.qcxr.canary262.action.UNATTENDED_EXECUTE'
    }).Count -eq 1) 'Clean fake state did not send the exact Lab arm and execute actions.'
    $companionIndex = -1
    $activityIndex = -1
    $armIndex = -1
    for ($i = 0; $i -lt $success.Calls.Count; $i++) {
        $argv = @($success.Calls[$i].Arguments)
        if ($argv -ccontains 'CompanionService') { $companionIndex = $i }
        if ($argv -ccontains 'activities') { $activityIndex = $i }
        if ($argv -ccontains 'am' -and $armIndex -lt 0) { $armIndex = $i }
    }
    Require ($companionIndex -ge 0 -and $activityIndex -gt $companionIndex -and
        $armIndex -gt $activityIndex) 'Read-only preflight did not complete before arming.'
    Require (@($success.Calls | Where-Object {
        @($_.Arguments) -ccontains 'CompanionService'
    }).Count -eq 1 -and @($success.Calls | Where-Object {
        @($_.Arguments) -ccontains 'activities'
    }).Count -eq 1) 'Clean fake state did not take exactly one snapshot from each dump source.'
    $allCalls += @($success.Calls)
    Assert-ReadOnlyAndLabOnly $allCalls
    $passed++

    # This is the exact spaced CompanionService syntax observed on Quest 3.
    # In particular, "PIN locked: false" must never match the natural-language
    # fallback that recognizes a bare "PIN locked" sentence.
    $spacedUnlocked = Invoke-Scenario 'pin-spaced-unlocked'
    Require ($spacedUnlocked.ExitCode -eq 0 -and $spacedUnlocked.Text -match 'ARMED') `
        "The Quest spaced unlocked PIN state was rejected: $($spacedUnlocked.Text)"
    Assert-ReadOnlyAndLabOnly $spacedUnlocked.Calls
    $passed++

    $stale = Invoke-Scenario 'stale-inactive-records'
    Require ($stale.ExitCode -eq 0 -and $stale.Text -match 'ARMED') `
        "Inactive historical activity records were misclassified as active: $($stale.Text)"
    Assert-ReadOnlyAndLabOnly $stale.Calls
    $passed++

    $source = [IO.File]::ReadAllText($production)
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $production, [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0) 'PowerShell parser rejected the production helper.'
    foreach ($required in @(
        'Assert-DeviceLaunchPreflight', "'dumpsys', 'CompanionService'",
        "'dumpsys', 'activity', 'activities'", 'LaunchCheckRequires6dof',
        'Finding\s+position\s+in\s+(?:the\s+)?room', 'never enters a PIN',
        'never clicks or changes Guardian'
    )) {
        Require ($source.Contains($required)) "Missing production guard: $required"
    }
    foreach ($forbidden in @(
        "'input'", "'keyevent'", "'tap'", "'swipe'", "'settings'", "'setprop'",
        "'pm', 'clear'", "'uninstall'", "'am', 'force-stop'",
        'com.qcxr.qcxr.dev262'
    )) {
        Require (-not $source.Contains($forbidden)) `
            "Production helper contains forbidden token: $forbidden"
    }
    $passed++
} finally {
    [Environment]::SetEnvironmentVariable('QC_AUTOPLAY_FAKE_LOG', $savedLog, 'Process')
    [Environment]::SetEnvironmentVariable('QC_AUTOPLAY_FAKE_SCENARIO', $savedScenario, 'Process')
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $fullTestRoot = [IO.Path]::GetFullPath($testRoot)
    Require ($fullTestRoot.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($fullTestRoot).StartsWith('quest-autoplay-host-',
            [StringComparison]::Ordinal)) 'Refused to clean an unexpected test directory.'
    Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
}

[pscustomobject]@{
    Result = 'PASS'
    CasesPassed = $passed
    FailureScenarios = $failureCases.Count
    RealAdbInvocations = 0
    HostOnly = $true
    PreflightBeforeArm = $true
    PinEntryAbsent = $true
    GuardianMutationAbsent = $true
    StableTouched = $false
}
