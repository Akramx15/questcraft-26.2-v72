<#
.SYNOPSIS
Runs a fail-closed lifecycle/recovery gate for the exact integrated v71 RC4 Lab APK.

.DESCRIPTION
SelfTest and Plan are Host-only and never resolve or invoke ADB. Run is fixed to
com.qcxr.qcxr.canary262, the exact APK recorded by V71_LAB_RC4.lock.json,
profile 26.2, and the exact RC4 Core/frozen-VEQ pair. It refuses to begin if
Stable or Lab is active,
which prevents interrupting a manual session or the long-memory sampler.

Run performs only deterministic ActivityManager lifecycle operations: a clean
autoplay/OpenXR launch, a full-process stop and recovery launch, then a plain
launcher-only start, interruption, and final autoplay/OpenXR recovery launch.
It sends no controller, touch, key, UI-automation, or random input. It never
installs, uninstalls, clears data, edits the profile, or writes account/save files.
The app itself may perform its normal runtime persistence while the fixed
FPS-Stress-Test world is running.

This gate cannot prove the narrow gameReady-to-OpenXR-init window because Unity
and the embedded JVM share one Android PID and frozen RC4 has no post-init ACK.
That limitation is returned explicitly and documented in the companion safety file.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Plan', 'Run')]
    [string] $Action = 'Plan',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [switch] $AllowDeviceRead,
    [switch] $AllowDeviceWrite,
    [switch] $AllowForceStop,
    [switch] $AllowLaunch,
    [switch] $AllowLauncherInterruption,
    [switch] $ConfirmNoActiveSoakOrManualSession
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:World = 'FPS-Stress-Test'
$script:Component = "$($script:Package)/pojlib.UnityPlayerActivity"
$script:ExpectedVersionCode = '71'
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.4'
$script:ExpectedCoreSha256 = '289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189'
$script:ExpectedCoreSizeBytes = 10068021L
$script:ExpectedCoreVersion = '26.2-1.3.15+qc.v71.rc4'
$script:ExpectedVeqSha256 = '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
$script:ExpectedVeqSizeBytes = 441660L
$script:ExpectedVeqVersion = '0.7.0-v70-canary.1'
$script:ExpectedSignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedAutoplaySha256 = '261E6881B334DECD8CB41A640F1EE765E024278FC677128B472234C923CD7196'
$script:ProducerHashScheme = 'sha256-utf8-normalized-lf'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:ApkPath = Join-Path $script:RepoRoot `
    'QCXR-XR-Wrapper\Builds\QuestCraft-Vivecraft-Lab-26.2-v71-rc.4-integrated-local.apk'
$script:CoreArtifactPath = Join-Path $script:RepoRoot `
    'Pojlib\src\main\assets\mods\vivecraft-26.2-1.3.15-quest.bin'
$script:VeqArtifactPath = Join-Path $script:RepoRoot `
    'Pojlib\src\main\assets\mods\vivecraft-essentials-quest.bin'
$script:LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC4.lock.json'
$script:CandidateLock = Get-Content -Raw -LiteralPath $script:LockPath | ConvertFrom-Json
$script:ExpectedApkSha256 = [string]$script:CandidateLock.target.labShellApkSha256
$script:ExpectedApkSizeBytes = [int64]$script:CandidateLock.target.labShellApkSizeBytes
$script:AutoplayPath = Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'
$script:RuntimeLockPath = Join-Path $script:WorkspaceRoot `
    'artifacts\runtime\.quest-v71-lab-lifecycle-recovery.global.lock'
$script:EvidenceReceiptRelativePath = `
    'artifacts/acceptance/v71-lab-rc4-lifecycle-recovery-receipt.json'
$script:EvidenceReceiptPath = Join-Path $script:WorkspaceRoot `
    ($script:EvidenceReceiptRelativePath.Replace('/', `
        [IO.Path]::DirectorySeparatorChar))
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/$($script:Profile)"
$script:CoreDevicePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqDevicePath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:MinecraftLogPath = "$($script:GameDirectory)/logs/latest.log"
$script:ReadyTimeoutSeconds = 240
$script:LauncherOnlyTimeoutSeconds = 30
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocationCount = 0
$script:HostContractResolved = $false
$script:DeviceResolved = $false
$script:MutationStarted = $false

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-AssignmentTargetVariable {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast] $Expression)

    $currentExpression = $Expression
    while ($null -ne $currentExpression) {
        if ($currentExpression -is [Management.Automation.Language.VariableExpressionAst]) {
            return $currentExpression
        }
        if ($currentExpression -is [Management.Automation.Language.ConvertExpressionAst] -or
                $currentExpression -is [Management.Automation.Language.AttributedExpressionAst]) {
            $currentExpression = $currentExpression.Child
            continue
        }
        if ($currentExpression -is [Management.Automation.Language.MemberExpressionAst]) {
            $currentExpression = $currentExpression.Expression
            continue
        }
        if ($currentExpression -is [Management.Automation.Language.IndexExpressionAst]) {
            $currentExpression = $currentExpression.Target
            continue
        }
        return $null
    }
    return $null
}

function Get-ReadOnlyAutomaticVariableCollisions {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast] $Tree)

    # `$null = ...` is PowerShell's supported output sink, so it is deliberately
    # absent. These names are automatic variables whose Constant/ReadOnly
    # semantics make a case-insensitive local assignment or parameter unsafe.
    $blockedNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($blockedName in @(
        '?', 'EnabledExperimentalFeatures', 'Error', 'ExecutionContext',
        'false', 'HOME', 'Host', 'IsCoreCLR', 'IsLinux', 'IsMacOS',
        'IsWindows', 'PID', 'PSCulture', 'PSEdition', 'PSHOME', 'PSStyle',
        'PSUICulture', 'PSVersionTable', 'ShellId', 'true')) {
        [void]$blockedNames.Add($blockedName)
    }

    $collisions = [Collections.Generic.List[object]]::new()
    foreach ($parameterNode in @($Tree.FindAll({
        param($candidateNode)
        $candidateNode -is [Management.Automation.Language.ParameterAst]
    }, $true))) {
        $name = $parameterNode.Name.VariablePath.UserPath.Split(':')[-1]
        if ($blockedNames.Contains($name)) {
            $collisions.Add([pscustomobject]@{
                Kind = 'Parameter'
                Name = $name
                Line = $parameterNode.Extent.StartLineNumber
            })
        }
    }

    foreach ($assignmentNode in @($Tree.FindAll({
        param($candidateNode)
        $candidateNode -is [Management.Automation.Language.AssignmentStatementAst]
    }, $true))) {
        $targetVariable = Get-AssignmentTargetVariable $assignmentNode.Left
        if ($null -eq $targetVariable) { continue }
        $name = $targetVariable.VariablePath.UserPath.Split(':')[-1]
        if ($blockedNames.Contains($name)) {
            $collisions.Add([pscustomobject]@{
                Kind = 'Assignment'
                Name = $name
                Line = $assignmentNode.Extent.StartLineNumber
            })
        }
    }

    foreach ($forEachNode in @($Tree.FindAll({
        param($candidateNode)
        $candidateNode -is [Management.Automation.Language.ForEachStatementAst]
    }, $true))) {
        $name = $forEachNode.Variable.VariablePath.UserPath.Split(':')[-1]
        if ($blockedNames.Contains($name)) {
            $collisions.Add([pscustomobject]@{
                Kind = 'ForEachVariable'
                Name = $name
                Line = $forEachNode.Variable.Extent.StartLineNumber
            })
        }
    }
    return @($collisions)
}

function Normalize-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $valueUpper = $Value.ToUpperInvariant()
    Require ($valueUpper -cmatch '^[0-9A-F]{64}$') 'Invalid SHA-256 value.'
    return $valueUpper
}

function Get-NormalizedTextSha256 {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Label is missing."
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw "$Label is not strict UTF-8 text: $($_.Exception.Message)"
    }
    Require (-not $text.StartsWith([string][char]0xFEFF,
        [StringComparison]::Ordinal)) "$Label must not contain a UTF-8 BOM."
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($normalized)))
}

function Enter-ProducerReadLock {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Label is missing."
    $item = Get-Item -Force -LiteralPath $Path
    Require (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
        "$Label must not be a reparse point."
    try {
        return [IO.File]::Open($item.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
    } catch {
        throw "Could not lock $Label for the complete lifecycle run."
    }
}

function Get-ProducerLineageDigest {
    param([Parameter(Mandatory)][object[]] $Files)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("scheme=$script:ProducerHashScheme")
    foreach ($file in $Files) {
        $lines.Add(('{0}|{1}|{2}' -f [string]$file.name,
            [string]$file.relativePath, (Normalize-Sha256 ([string]$file.sha256))))
    }
    $payload = ($lines -join "`n") + "`n"
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($payload)))
}

function Get-LifecycleProducerLineage {
    $files = @(
        [pscustomobject][ordered]@{
            name = 'lifecycle-orchestrator'
            relativePath = 'scripts/quest-v71-lab-lifecycle-recovery-rc4.ps1'
            sha256 = Get-NormalizedTextSha256 $PSCommandPath `
                'lifecycle/recovery producer'
        }
        [pscustomobject][ordered]@{
            name = 'autoplay-harness'
            relativePath = 'scripts/run-vivecraft-local-autoplay.ps1'
            sha256 = Get-NormalizedTextSha256 $script:AutoplayPath `
                'fixed Lab autoplay dependency'
        }
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        hashScheme = $script:ProducerHashScheme
        digestSha256 = Get-ProducerLineageDigest $files
        files = $files
    }
}

function Assert-NoReparseContainment {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Label
    )
    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    Require ($full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) `
        "$Label escapes its fixed root."
    $cursor = if (Test-Path -LiteralPath $full) { $full } else { [IO.Path]::GetDirectoryName($full) }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -Force -LiteralPath $cursor
            Require (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
                "$Label traverses a reparse point."
        }
        if ($cursor.TrimEnd('\').Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            return $full
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        Require (-not [string]::IsNullOrWhiteSpace($parent) -and $parent.Length -lt $cursor.Length) `
            "$Label containment walk failed."
        $cursor = $parent
    }
    throw "$Label did not reach its fixed root."
}

function Get-FileIdentity {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [Parameter(Mandatory)][int64] $ExpectedSizeBytes,
        [Parameter(Mandatory)][string] $Label
    )
    $full = Assert-NoReparseContainment $Path $script:WorkspaceRoot $Label
    Require (Test-Path -LiteralPath $full -PathType Leaf) "$Label is missing."
    $item = Get-Item -LiteralPath $full
    Require (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
        "$Label must not be a reparse point."
    Require ([int64]$item.Length -eq $ExpectedSizeBytes) "$Label size mismatch."
    $sha = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($sha -ceq (Normalize-Sha256 $ExpectedSha256)) "$Label SHA-256 mismatch."
    return [pscustomobject]@{
        Path = $item.FullName
        SizeBytes = [int64]$item.Length
        Sha256 = $sha
    }
}

function Get-ExactObject {
    param(
        [Parameter(Mandatory)][object[]] $Values,
        [Parameter(Mandatory)][string] $Property,
        [Parameter(Mandatory)][string] $Label
    )
    $matches = @($Values | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties[$Property]
    })
    Require ($matches.Count -eq 1) "$Label returned an ambiguous result."
    return $matches[0]
}

function Resolve-HostContract {
    if ($script:HostContractResolved) { return }
    $before = $script:DeviceInvocationCount

    Require ($script:ExpectedApkSha256 -cmatch '^[0-9A-F]{64}$' -and
        $script:ExpectedApkSha256 -cnotmatch '^0{64}$' -and
        $script:ExpectedApkSizeBytes -gt 0 -and
        [bool]$script:CandidateLock.target.artifactAuditPassed -and
        [bool]$script:CandidateLock.hostVerification.currentIntegratedApkArtifactAuditPassed) `
        'The exact RC4 Lab APK is pending build and artifact audit.'

    $null = Get-FileIdentity $script:ApkPath $script:ExpectedApkSha256 `
        $script:ExpectedApkSizeBytes 'integrated v71 RC4 Lab APK'
    $null = Get-FileIdentity $script:CoreArtifactPath $script:ExpectedCoreSha256 `
        $script:ExpectedCoreSizeBytes 'embedded v71 RC4 Core asset'
    $null = Get-FileIdentity $script:VeqArtifactPath $script:ExpectedVeqSha256 `
        $script:ExpectedVeqSizeBytes 'embedded v71 RC4 VEQ asset'

    Require (Test-Path -LiteralPath $script:LockPath -PathType Leaf) 'V71 RC4 lock is missing.'
    $lock = Get-Content -Raw -LiteralPath $script:LockPath | ConvertFrom-Json
    Require ([string]$lock.target.package -ceq $script:Package) 'Lock package drifted.'
    Require ([string]$lock.target.forbiddenStablePackage -ceq $script:StablePackage -and
        -not [bool]$lock.target.stableTouched) 'Lock no longer protects Stable.'
    Require ((Normalize-Sha256 ([string]$lock.target.labShellApkSha256)) -ceq
        $script:ExpectedApkSha256 -and
        [int64]$lock.target.labShellApkSizeBytes -eq $script:ExpectedApkSizeBytes) `
        'Lock APK identity drifted.'
    Require ([int]$lock.target.labShellVersionCode -eq [int]$script:ExpectedVersionCode -and
        [string]$lock.target.labShellVersionName -ceq $script:ExpectedVersionName) `
        'Lock APK version drifted.'
    Require ((Normalize-Sha256 ([string]$lock.pair.core.sha256)) -ceq
        $script:ExpectedCoreSha256 -and
        [int64]$lock.pair.core.sizeBytes -eq $script:ExpectedCoreSizeBytes -and
        [string]$lock.pair.core.fabricVersion -ceq $script:ExpectedCoreVersion) `
        'Lock Core identity drifted.'
    Require ((Normalize-Sha256 ([string]$lock.pair.veq.sha256)) -ceq
        $script:ExpectedVeqSha256 -and
        [int64]$lock.pair.veq.sizeBytes -eq $script:ExpectedVeqSizeBytes -and
        [string]$lock.pair.veq.fabricVersion -ceq $script:ExpectedVeqVersion) `
        'Lock VEQ identity drifted.'
    Require ([bool]$lock.hostVerification.currentIntegratedApkArtifactAuditPassed) `
        'The integrated APK audit is not locked as passed.'

    Require (Test-Path -LiteralPath $script:AutoplayPath -PathType Leaf) `
        'The fixed Lab autoplay helper is missing.'
    $producerLineage = Get-LifecycleProducerLineage
    Require ([string]$lock.source.lifecycleRecoveryScriptSha256 -ceq
            [string]$producerLineage.files[0].sha256) `
        'The lifecycle/recovery producer drifted from the RC4 lock.'
    Require ([string]$lock.source.autoplayHarnessScriptSha256 -ceq
            [string]$producerLineage.files[1].sha256 -and
            [string]$producerLineage.files[1].sha256 -ceq
            $script:ExpectedAutoplaySha256) `
        'The fixed Lab autoplay dependency drifted from the RC4 lock.'
    $autoplayValues = @(& $script:AutoplayPath -Action SelfTest `
        -Serial 'offline-proof' -AdbPath (Join-Path $PSScriptRoot '__v71-no-adb__.exe'))
    $autoplay = Get-ExactObject $autoplayValues 'Result' 'autoplay Host self-test'
    Require ([string]$autoplay.Result -ceq 'PASS' -and
        [string]$autoplay.Package -ceq $script:Package -and
        [string]$autoplay.World -ceq $script:World) 'Autoplay Host contract drifted.'
    Require ($script:DeviceInvocationCount -eq $before) 'Host contract resolution invoked ADB.'
    $script:HostContractResolved = $true
}

function Assert-RunAuthorization {
    Require $AllowDeviceRead.IsPresent 'Run requires explicit -AllowDeviceRead.'
    Require $AllowDeviceWrite.IsPresent 'Run requires explicit -AllowDeviceWrite.'
    Require $AllowForceStop.IsPresent 'Run requires explicit -AllowForceStop.'
    Require $AllowLaunch.IsPresent 'Run requires explicit -AllowLaunch.'
    Require $AllowLauncherInterruption.IsPresent `
        'Run requires explicit -AllowLauncherInterruption.'
    Require $ConfirmNoActiveSoakOrManualSession.IsPresent `
        'Run requires explicit -ConfirmNoActiveSoakOrManualSession.'
}

function Enter-RuntimeLock {
    $lockPath = Assert-NoReparseContainment $script:RuntimeLockPath `
        $script:WorkspaceRoot 'lifecycle/recovery lock'
    $parent = [IO.Path]::GetDirectoryName($lockPath)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $null = Assert-NoReparseContainment $parent $script:WorkspaceRoot `
        'lifecycle/recovery lock directory'
    try {
        return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw 'Another v71 lifecycle/recovery run owns the fixed Host lock.'
    }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sideQuest = Join-Path $env:LOCALAPPDATA `
        'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw 'ADB was not found. Pass -AdbPath with the full adb.exe path.'
}

function Invoke-Adb {
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $script:DeviceInvocationCount++
    $rows = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "ADB failed with exit code $code; device output was suppressed."
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $rows }
}

function Resolve-Device {
    $script:Adb = Resolve-Adb
    $devicesProbe = Invoke-Adb @('devices')
    $devices = @($devicesProbe.Lines | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { [string]$Matches.serial }
    })
    if ($Serial -ceq 'auto') {
        Require ($devices.Count -eq 1) `
            'Auto selection requires exactly one authorized ADB endpoint; pass -Serial otherwise.'
        $script:Device = [string]$devices[0]
    } else {
        Require ($devices -ccontains $Serial) 'The requested ADB endpoint is not connected.'
        $script:Device = $Serial
    }
    $state = Invoke-Adb @('-s', $script:Device, 'get-state')
    Require (($state.Lines -join '').Trim() -ceq 'device') 'The selected ADB endpoint is not ready.'
    $script:DeviceResolved = $true
}

function ConvertTo-ShLiteral {
    param([Parameter(Mandatory)][string] $Value)
    $quote = [string][char]39
    return $quote + $Value.Replace($quote, $quote + '"' + $quote + '"' + $quote) + $quote
}

function Invoke-DeviceShell {
    param([Parameter(Mandatory)][string] $Command, [switch] $AllowFailure)
    return Invoke-Adb -Arguments @('-s', $script:Device, 'shell', $Command) `
        -AllowFailure:$AllowFailure
}

function Get-ExactPid {
    param([Parameter(Mandatory)][string] $Package, [switch] $AllowMissing)
    $qPackage = ConvertTo-ShLiteral $Package
    $command = "out=`$(pidof $qPackage); rc=`$?; " +
        'if [ "$rc" -eq 0 ]; then printf ''PID\t%s\n'' "$out"; ' +
        'elif [ "$rc" -eq 1 ]; then printf ''ABSENT\n''; else exit "$rc"; fi'
    $probe = Invoke-DeviceShell -Command $command
    $rows = @($probe.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) "PID probe for $Package was ambiguous."
    if ($rows[0] -ceq 'ABSENT') {
        if ($AllowMissing) { return $null }
        throw "Expected exactly one PID for $Package."
    }
    Require ($rows[0] -cmatch '^PID\t(?<pids>[0-9]+(?:\s+[0-9]+)*)$') `
        "PID probe for $Package was malformed."
    $pids = @(([string]$Matches.pids) -split '\s+')
    Require ($pids.Count -eq 1) "Expected exactly one PID for $Package."
    return [int]$pids[0]
}

function Assert-StableStopped {
    Require ($null -eq (Get-ExactPid $script:StablePackage -AllowMissing)) `
        '[FATAL_STABLE_ACTIVE] Stable is active; this Lab-only gate will not touch it.'
}

function Test-LabFocused {
    $result = Invoke-DeviceShell -Command 'dumpsys activity activities' -AllowFailure
    if ($result.ExitCode -ne 0) { return $false }
    $active = $result.Lines | Where-Object { $_ -match 'topResumedActivity' } |
        Select-Object -First 1
    if ($null -eq $active) {
        $active = $result.Lines | Where-Object { $_ -match '(?:mResumedActivity|ResumedActivity)' } |
            Select-Object -First 1
    }
    return $null -ne $active -and
        [string]$active -match ([regex]::Escape($script:Package) + '/')
}

function Get-ThreadNames {
    param([Parameter(Mandatory)][int] $ProcessId)
    $command = 'for f in /proc/' + $ProcessId + '/task/*/comm; do [ -r "$f" ] && cat "$f" 2>/dev/null || true; done'
    $probe = Invoke-DeviceShell -Command $command
    return @($probe.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ExactPmBaseApkPath {
    param([Parameter(Mandatory)][string[]] $Lines)
    Require ($Lines.Count -eq 1) `
        'pm path must return exactly one row; split or contaminated installs are rejected.'
    $row = [string]$Lines[0]
    Require ($row -cmatch '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$') `
        'pm path did not return one exact /data/app/.../base.apk row.'
    $path = [string]$Matches.path
    Require (-not $path.Contains('..') -and -not $path.Contains('\') -and
        -not $path.Contains("`0")) 'Installed base.apk path is unsafe.'
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)')) `
        'Installed base.apk path does not belong to the fixed Lab package.'
    return $path
}

function Get-InstalledIdentity {
    $pathProbe = Invoke-DeviceShell -Command `
        ('pm path ' + (ConvertTo-ShLiteral $script:Package))
    $basePath = Get-ExactPmBaseApkPath ([string[]]@($pathProbe.Lines))
    $qPath = ConvertTo-ShLiteral $basePath
    $identityProbe = Invoke-DeviceShell -Command (
        "set -eu; test -f $qPath; test ! -L $qPath; " +
        "sha=`$(sha256sum $qPath | cut -d ' ' -f 1); size=`$(stat -c %s $qPath); " +
        "printf 'APK\t%s\t%s\n' `"`$sha`" `"`$size`"")
    $rows = @($identityProbe.Lines | Where-Object {
        $_ -cmatch '^APK\t[0-9a-f]{64}\t[0-9]+$'
    })
    Require ($rows.Count -eq 1) 'Installed APK identity response was ambiguous.'
    $null = $rows[0] -cmatch '^APK\t(?<sha>[0-9a-f]{64})\t(?<size>[0-9]+)$'
    $sha = $Matches.sha.ToUpperInvariant()
    $size = [int64]$Matches.size
    Require ($sha -ceq $script:ExpectedApkSha256 -and
        $size -eq $script:ExpectedApkSizeBytes) 'Installed Lab APK is not exact integrated RC4.'

    $packageProbe = Invoke-DeviceShell -Command (
        'dumpsys package ' + (ConvertTo-ShLiteral $script:Package))
    $text = $packageProbe.Lines -join "`n"
    $codes = @([regex]::Matches($text, '(?m)^\s*versionCode=(?<v>[0-9]+)\b') |
        ForEach-Object { $_.Groups['v'].Value } | Sort-Object -Unique)
    $names = @([regex]::Matches($text, '(?m)^\s*versionName=(?<v>[^\r\n]+)$') |
        ForEach-Object { $_.Groups['v'].Value.Trim() } | Sort-Object -Unique)
    Require ($codes.Count -eq 1 -and $codes[0] -ceq $script:ExpectedVersionCode) `
        'Installed Lab versionCode mismatch.'
    Require ($names.Count -eq 1 -and $names[0] -ceq $script:ExpectedVersionName) `
        'Installed Lab versionName mismatch.'
    return [pscustomobject]@{
        Package = $script:Package
        VersionCode = $codes[0]
        VersionName = $names[0]
        ApkSha256 = $sha
        ApkSizeBytes = $size
    }
}

function Get-PhysicalPair {
    $qCore = ConvertTo-ShLiteral $script:CoreDevicePath
    $qVeq = ConvertTo-ShLiteral $script:VeqDevicePath
    $command = @(
        'set -eu'
        "test -f $qCore && test ! -L $qCore"
        "test -f $qVeq && test ! -L $qVeq"
        "core_sha=`$(sha256sum $qCore | cut -d ' ' -f 1)"
        "core_size=`$(stat -c %s $qCore)"
        "veq_sha=`$(sha256sum $qVeq | cut -d ' ' -f 1)"
        "veq_size=`$(stat -c %s $qVeq)"
        'printf ''PAIR\t%s\t%s\t%s\t%s\n'' "$core_sha" "$core_size" "$veq_sha" "$veq_size"'
    ) -join "`n"
    $probe = Invoke-DeviceShell -Command $command
    $rows = @($probe.Lines | Where-Object {
        $_ -cmatch '^PAIR\t[0-9a-f]{64}\t[0-9]+\t[0-9a-f]{64}\t[0-9]+$'
    })
    Require ($rows.Count -eq 1) 'Physical Core/VEQ identity response was ambiguous.'
    $null = $rows[0] -cmatch `
        '^PAIR\t(?<core>[0-9a-f]{64})\t(?<coreSize>[0-9]+)\t(?<veq>[0-9a-f]{64})\t(?<veqSize>[0-9]+)$'
    $coreSha = $Matches.core.ToUpperInvariant()
    $veqSha = $Matches.veq.ToUpperInvariant()
    $coreSize = [int64]$Matches.coreSize
    $veqSize = [int64]$Matches.veqSize
    Require ($coreSha -ceq $script:ExpectedCoreSha256 -and
        $coreSize -eq $script:ExpectedCoreSizeBytes) 'Physical Core is not exact RC4.'
    Require ($veqSha -ceq $script:ExpectedVeqSha256 -and
        $veqSize -eq $script:ExpectedVeqSizeBytes) 'Physical VEQ is not exact RC4.'
    return [pscustomobject]@{
        CoreSha256 = $coreSha
        CoreSizeBytes = $coreSize
        VeqSha256 = $veqSha
        VeqSizeBytes = $veqSize
    }
}

function Get-LogSnapshot {
    $qLog = ConvertTo-ShLiteral $script:MinecraftLogPath
    $command = @(
        'set -eu'
        "log=$qLog"
        'if [ ! -e "$log" ]; then printf ''LOG\tABSENT\t0\t0\tABSENT\t0\n''; exit 0; fi'
        'test -f "$log" && test ! -L "$log"'
        'inode=$(stat -c %i "$log")'
        'size=$(stat -c %s "$log")'
        'mtime=$(stat -c %Y "$log")'
        'n=$size; if [ "$n" -gt 4096 ]; then n=4096; fi'
        'if [ "$n" -eq 0 ]; then prefix=EMPTY; else prefix=$(head -c "$n" "$log" | sha256sum | cut -d " " -f 1); fi'
        'printf ''LOG\t%s\t%s\t%s\t%s\t%s\n'' "$inode" "$size" "$n" "$prefix" "$mtime"'
    ) -join "`n"
    $probe = Invoke-DeviceShell -Command $command
    $rows = @($probe.Lines | Where-Object {
        $_ -cmatch '^LOG\t(?:ABSENT|[0-9]+)\t[0-9]+\t[0-9]+\t(?:ABSENT|EMPTY|[0-9a-f]{64})\t[0-9]+$'
    })
    Require ($rows.Count -eq 1) 'Minecraft log snapshot response was ambiguous.'
    $null = $rows[0] -cmatch `
        '^LOG\t(?<inode>ABSENT|[0-9]+)\t(?<size>[0-9]+)\t(?<bytes>[0-9]+)\t(?<prefix>ABSENT|EMPTY|[0-9a-f]{64})\t(?<mtime>[0-9]+)$'
    return [pscustomobject]@{
        Inode = [string]$Matches.inode
        SizeBytes = [int64]$Matches.size
        PrefixBytes = [int]$Matches.bytes
        PrefixSha256 = [string]$Matches.prefix
        Mtime = [int64]$Matches.mtime
    }
}

function Test-LogSnapshotEqual {
    param([Parameter(Mandatory)] $Left, [Parameter(Mandatory)] $Right)
    return [string]$Left.Inode -ceq [string]$Right.Inode -and
        [int64]$Left.SizeBytes -eq [int64]$Right.SizeBytes -and
        [int]$Left.PrefixBytes -eq [int]$Right.PrefixBytes -and
        [string]$Left.PrefixSha256 -ceq [string]$Right.PrefixSha256 -and
        [int64]$Left.Mtime -eq [int64]$Right.Mtime
}

function New-LifecycleEvidenceReceipt {
    param(
        [Parameter(Mandatory)] $InstalledBefore,
        [Parameter(Mandatory)] $InstalledAfter,
        [Parameter(Mandatory)] $PairBefore,
        [Parameter(Mandatory)] $ColdOpenXr,
        [Parameter(Mandatory)] $PostOpenXrRecovery,
        [Parameter(Mandatory)] $LauncherOnly,
        [Parameter(Mandatory)] $PostLauncherRecovery,
        [Parameter(Mandatory)] $PairAfter,
        [Parameter(Mandatory)] $ProducerLineage,
        [Parameter(Mandatory)][DateTimeOffset] $StartedUtc,
        [Parameter(Mandatory)][DateTimeOffset] $CompletedUtc
    )
    Require ($CompletedUtc -ge $StartedUtc) `
        'Lifecycle receipt completion precedes its start.'
    $exactPairBefore = [string]$PairBefore.CoreSha256 -ceq
        $script:ExpectedCoreSha256 -and [string]$PairBefore.VeqSha256 -ceq
        $script:ExpectedVeqSha256
    $exactPairAfter = [string]$PairAfter.CoreSha256 -ceq
        $script:ExpectedCoreSha256 -and [string]$PairAfter.VeqSha256 -ceq
        $script:ExpectedVeqSha256
    Require ($exactPairBefore -and $exactPairAfter) `
        'Lifecycle receipt cannot represent a non-RC4 pair.'
    $installedApkUnchanged =
        [string]$InstalledBefore.Package -ceq [string]$InstalledAfter.Package -and
        [string]$InstalledBefore.VersionCode -ceq [string]$InstalledAfter.VersionCode -and
        [string]$InstalledBefore.VersionName -ceq [string]$InstalledAfter.VersionName -and
        [string]$InstalledBefore.ApkSha256 -ceq [string]$InstalledAfter.ApkSha256 -and
        [int64]$InstalledBefore.ApkSizeBytes -eq [int64]$InstalledAfter.ApkSizeBytes
    Require $installedApkUnchanged `
        'Lifecycle receipt cannot represent a changed installed Lab APK.'

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_LAB_RC4_LIFECYCLE_RECOVERY'
        result = 'PASS'
        startedUtc = $StartedUtc.ToUniversalTime().ToString('o')
        completedUtc = $CompletedUtc.ToUniversalTime().ToString('o')
        producerLineage = $ProducerLineage
        labIdentity = [pscustomobject][ordered]@{
            package = $script:Package
            forbiddenStablePackage = $script:StablePackage
            versionCode = [int]$InstalledAfter.VersionCode
            versionName = [string]$InstalledAfter.VersionName
            apkSha256 = [string]$InstalledAfter.ApkSha256
            apkSizeBytes = [int64]$InstalledAfter.ApkSizeBytes
            coreSha256 = $script:ExpectedCoreSha256
            veqSha256 = $script:ExpectedVeqSha256
            signerSha256 = $script:ExpectedSignerSha256
        }
        phases = @(
            [pscustomobject][ordered]@{
                name = 'preflight-exact-lab-and-rc4'
                result = 'PASS'
                labInitiallyStopped = $true
                stableStopped = $true
                installedApkMatched = $true
                exactRc4PairBefore = $exactPairBefore
            }
            [pscustomobject][ordered]@{
                name = 'clean-cold-openxr'
                result = [string]$ColdOpenXr.Result
                startedFromStopped = $true
                exactRc4VersionRows = [bool]$ColdOpenXr.ExactRc4VersionRows
                openXrFocused = [bool]$ColdOpenXr.OpenXrFocused
                openXrFrame120Submitted = [bool]$ColdOpenXr.OpenXrFrame120Submitted
                benchmarkWorldLoaded = [bool]$ColdOpenXr.BenchmarkWorldLoaded
                gameJvmAlive = [bool]$ColdOpenXr.GameJvmAlive
            }
            [pscustomobject][ordered]@{
                name = 'post-openxr-process-stop-recovery'
                result = [string]$PostOpenXrRecovery.Result
                liveOpenXrProcessStoppedBeforeRecovery = $true
                recoveryStartedFromStopped = $true
                exactRc4VersionRows = [bool]$PostOpenXrRecovery.ExactRc4VersionRows
                openXrFocused = [bool]$PostOpenXrRecovery.OpenXrFocused
                openXrFrame120Submitted = [bool]$PostOpenXrRecovery.OpenXrFrame120Submitted
                benchmarkWorldLoaded = [bool]$PostOpenXrRecovery.BenchmarkWorldLoaded
                gameJvmAlive = [bool]$PostOpenXrRecovery.GameJvmAlive
            }
            [pscustomobject][ordered]@{
                name = 'launcher-only-interruption'
                result = [string]$LauncherOnly.Result
                startedFromStopped = $true
                launcherOnlyProven = [bool]$LauncherOnly.LauncherOnlyProven
                unityMainPresent = [bool]$LauncherOnly.UnityMainPresent
                gameJvmAbsent = [bool]$LauncherOnly.GameJvmAbsent
                minecraftLogUntouched = [bool]$LauncherOnly.MinecraftLogUntouched
                interruptedByForceStop = $true
                randomInputSent = [bool]$LauncherOnly.RandomInputSent
            }
            [pscustomobject][ordered]@{
                name = 'post-launcher-interruption-recovery'
                result = [string]$PostLauncherRecovery.Result
                launcherInterruptedBeforeRecovery = $true
                recoveryStartedFromStopped = $true
                exactRc4VersionRows = [bool]$PostLauncherRecovery.ExactRc4VersionRows
                openXrFocused = [bool]$PostLauncherRecovery.OpenXrFocused
                openXrFrame120Submitted = [bool]$PostLauncherRecovery.OpenXrFrame120Submitted
                benchmarkWorldLoaded = [bool]$PostLauncherRecovery.BenchmarkWorldLoaded
                gameJvmAlive = [bool]$PostLauncherRecovery.GameJvmAlive
            }
            [pscustomobject][ordered]@{
                name = 'final-stopped-exact-rc4'
                result = 'PASS'
                labStopped = $true
                stableStopped = $true
                exactRc4PairAfter = $exactPairAfter
                installedLabApkUnchanged = $installedApkUnchanged
                hostArtifactsUnchanged = $true
            }
        )
        finalState = [pscustomobject][ordered]@{
            lab = 'stopped'
            exactRc4Pair = $exactPairAfter
            installedLabApkUnchanged = $installedApkUnchanged
            stablePidAbsent = $true
            stableTouched = $false
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            rawLogsPersisted = $false
            logSnippetsPersisted = $false
            deviceSerialPersisted = $false
            processIdsPersisted = $false
            hostAbsolutePathsPersisted = $false
            accountDataPersisted = $false
            saveDataPersistedByGate = $false
            randomInputSent = $false
            manualInteractionClaim = $false
            performanceClaim = $false
            memorySoakClaim = $false
            postInitAcknowledgementProven = $false
            postInitAcknowledgementLimitation = `
                'Frozen RC4 has no ACK; Unity launcher and JVM share one Android PID.'
        }
    }
}

function Assert-EvidenceReceiptDestinationAvailable {
    $full = Assert-NoReparseContainment $script:EvidenceReceiptPath `
        $script:WorkspaceRoot 'lifecycle/recovery evidence receipt'
    Require (-not (Test-Path -LiteralPath $full)) `
        ('The fixed lifecycle/recovery receipt already exists. Archive it and ' +
        'update the acceptance lock deliberately before another Run.')
}

function Write-AtomicEvidenceReceipt {
    param([Parameter(Mandatory)] $Receipt)
    $full = Assert-NoReparseContainment $script:EvidenceReceiptPath `
        $script:WorkspaceRoot 'lifecycle/recovery evidence receipt'
    $parent = [IO.Path]::GetDirectoryName($full)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $null = Assert-NoReparseContainment $parent $script:WorkspaceRoot `
        'lifecycle/recovery evidence directory'
    Require (-not (Test-Path -LiteralPath $full)) `
        'The fixed lifecycle/recovery evidence receipt is write-once.'

    $json = ($Receipt | ConvertTo-Json -Depth 16) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    Require ($bytes.Length -gt 0 -and $bytes.Length -le 128KB) `
        'Lifecycle/recovery evidence receipt size is invalid.'
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) +
        '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $null = Assert-NoReparseContainment $temporary $script:WorkspaceRoot `
        'lifecycle/recovery temporary receipt'
    $published = $false
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096,
            [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $full)
        $published = $true
        $item = Get-Item -Force -LiteralPath $full
        Require (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and
            [int64]$item.Length -eq [int64]$bytes.Length) `
            'Published lifecycle/recovery receipt identity drifted.'
        $sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
        return [pscustomobject]@{
            RelativePath = $script:EvidenceReceiptRelativePath
            Sha256 = $sha256
            SizeBytes = [int64]$item.Length
            AtomicWrite = $true
            WriteOnce = $true
        }
    } catch {
        if ($published -and (Test-Path -LiteralPath $full -PathType Leaf)) {
            [IO.File]::Delete($full)
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Stop-Lab {
    Assert-StableStopped
    $null = Invoke-DeviceShell -Command `
        ('am force-stop ' + (ConvertTo-ShLiteral $script:Package))
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($null -eq (Get-ExactPid $script:Package -AllowMissing)) {
            Assert-StableStopped
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Lab process did not stop in the bounded window.'
}

function Stop-LabCleanup {
    if (-not $script:DeviceResolved -or -not $script:MutationStarted) { return }
    $stop = Invoke-DeviceShell -Command `
        ('am force-stop ' + (ConvertTo-ShLiteral $script:Package)) -AllowFailure
    Require ($stop.ExitCode -eq 0) 'Lab cleanup force-stop failed.'
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($null -eq (Get-ExactPid $script:Package -AllowMissing)) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'Lab PID remained after the bounded cleanup window.'
}

function Start-LabAutoplay {
    Assert-StableStopped
    Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
        'Autoplay requires a stopped Lab process.'
    $values = @(& $script:AutoplayPath -Action ArmAndRun -Serial $script:Device `
        -AdbPath $script:Adb -LauncherCameraPark ON -LauncherResourceRelease ON -AllowLaunch)
    $result = Get-ExactObject $values 'Result' 'Lab autoplay'
    Require ([string]$result.Result -ceq 'ARMED' -and
        [string]$result.Package -ceq $script:Package -and
        [string]$result.World -ceq $script:World -and
        [string]$result.LauncherResourceRelease -ceq 'ON') `
        'Autoplay did not arm exact Lab RC4 with resource release ON.'
}

function Wait-RuntimeReady {
    param(
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)][string] $Phase
    )
    $qLog = ConvertTo-ShLiteral $script:MinecraftLogPath
    $qCoreVersion = ConvertTo-ShLiteral $script:ExpectedCoreVersion
    $qVeqVersion = ConvertTo-ShLiteral $script:ExpectedVeqVersion
    $deadline = [DateTime]::UtcNow.AddSeconds($script:ReadyTimeoutSeconds)
    $firstPid = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        Assert-StableStopped
        $labProcessId = Get-ExactPid $script:Package -AllowMissing
        if ($null -eq $labProcessId) {
            Require ($null -eq $firstPid) "$Phase Lab PID disappeared after launch began."
            Start-Sleep -Seconds 1
            continue
        }
        if ($null -eq $firstPid) { $firstPid = [int]$labProcessId }
        Require ([int]$labProcessId -eq [int]$firstPid) `
            "$Phase crossed Android process identities."

        $baselineInode = [string]$Baseline.Inode
        $baselineSize = [int64]$Baseline.SizeBytes
        $baselinePrefixBytes = [int]$Baseline.PrefixBytes
        $baselinePrefix = [string]$Baseline.PrefixSha256
        $baselineMtime = [int64]$Baseline.Mtime
        $command = @(
            'set -eu'
            "log=$qLog"
            'test -f "$log" && test ! -L "$log"'
            'inode=$(stat -c %i "$log")'
            'size=$(stat -c %s "$log")'
            'mtime=$(stat -c %Y "$log")'
            'start=1; mode=NEW_FILE'
            ("if [ '{0}' != ABSENT ] && [ `"`$inode`" = '{0}' ] && [ `"`$size`" -ge {1} ]; then" -f $baselineInode, $baselineSize)
            ("  if [ {0} -eq 0 ]; then prefix=EMPTY; else prefix=`$(head -c {0} `"`$log`" | sha256sum | cut -d `" `" -f 1); fi" -f $baselinePrefixBytes)
            ("  if [ `"`$prefix`" = '{0}' ]; then start={1}; mode=APPEND; fi" -f $baselinePrefix, ($baselineSize + 1))
            'fi'
            'if [ "$start" -le "$size" ]; then'
            '  adv=$(tail -c +"$start" "$log" | grep -c -E ''Loaded [0-9]+ advancements'' || true)'
            ("  core=`$(tail -c +`"`$start`" `"`$log`" | grep -F -c {0} || true)" -f $qCoreVersion)
            ("  veq=`$(tail -c +`"`$start`" `"`$log`" | grep -F -c {0} || true)" -f $qVeqVersion)
            '  focused=$(tail -c +"$start" "$log" | grep -F -c ''Vivecraft: OpenXR session state changed to FOCUSED'' || true)'
            '  frame=$(tail -c +"$start" "$log" | grep -F -c ''Vivecraft: OpenXR submitted frame 120 '' || true)'
            '  terminal=$(tail -c +"$start" "$log" | grep -c -E -e ''---- Minecraft Crash Report ----|ReportedException|Minecraft has crashed|Game crashed|MixinApplyError|LinkageError'' || true)'
            'else adv=0; core=0; veq=0; focused=0; frame=0; terminal=0; fi'
            ("fresh=`$((size-start+1)); if [ `"`$fresh`" -lt 0 ]; then fresh=0; fi; if [ `"`$mtime`" -lt {0} ]; then exit 9; fi" -f $baselineMtime)
            'printf ''READY\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n'' "$inode" "$size" "$start" "$mode" "$fresh" "$adv" "$core" "$veq" "$focused" "$frame:$terminal"'
        ) -join "`n"
        $probe = Invoke-DeviceShell -Command $command -AllowFailure
        if ($probe.ExitCode -eq 0) {
            $rows = @($probe.Lines | Where-Object {
                $_ -cmatch '^READY\t[0-9]+\t[0-9]+\t[0-9]+\t(?:APPEND|NEW_FILE)\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+:[0-9]+$'
            })
            if ($rows.Count -eq 1) {
                $null = $rows[0] -cmatch `
                    '^READY\t(?<inode>[0-9]+)\t(?<size>[0-9]+)\t(?<start>[0-9]+)\t(?<mode>APPEND|NEW_FILE)\t(?<fresh>[0-9]+)\t(?<adv>[0-9]+)\t(?<core>[0-9]+)\t(?<veq>[0-9]+)\t(?<focused>[0-9]+)\t(?<frame>[0-9]+):(?<terminal>[0-9]+)$'
                if ([int]$Matches.terminal -gt 0) { throw "$Phase observed a terminal runtime marker." }
                $threads = Get-ThreadNames ([int]$labProcessId)
                $gameJvm = @($threads | Where-Object { $_ -ceq 'QuestCraft-JVM' }).Count -eq 1
                if ([int64]$Matches.fresh -gt 0 -and [int]$Matches.adv -ge 1 -and
                    [int]$Matches.core -ge 1 -and [int]$Matches.veq -ge 1 -and
                    [int]$Matches.focused -ge 1 -and [int]$Matches.frame -ge 1 -and
                    $gameJvm -and (Test-LabFocused)) {
                    Require ((Get-ExactPid $script:Package) -eq [int]$labProcessId) `
                        "$Phase PID changed during acceptance."
                    return [pscustomobject]@{
                        Result = 'PASS'
                        Phase = $Phase
                        NewPidProven = $true
                        ExactRc4VersionRows = $true
                        OpenXrFocused = $true
                        OpenXrFrame120Submitted = $true
                        BenchmarkWorldLoaded = $true
                        GameJvmAlive = $true
                        FreshLogBytes = [int64]$Matches.fresh
                        LogSliceMode = [string]$Matches.mode
                    }
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    throw "$Phase did not reach exact RC4 + benchmark world + OpenXR frame 120 in time."
}

function Invoke-RuntimeCycle {
    param([Parameter(Mandatory)][string] $Phase)
    Assert-StableStopped
    Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
        "$Phase did not start from a stopped Lab process."
    $baseline = Get-LogSnapshot
    Start-Sleep -Milliseconds 1100
    Start-LabAutoplay
    $proof = Wait-RuntimeReady $baseline $Phase
    $null = Get-PhysicalPair
    Assert-StableStopped
    return $proof
}

function Start-LauncherOnlyAndWait {
    param([Parameter(Mandatory)] $MinecraftLogBaseline)
    Assert-StableStopped
    Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
        'Launcher-only phase requires a stopped Lab process.'
    $null = Invoke-Adb @('-s', $script:Device, 'shell', 'am', 'start', '-n', $script:Component)
    $deadline = [DateTime]::UtcNow.AddSeconds($script:LauncherOnlyTimeoutSeconds)
    $firstPid = $null
    $consecutiveLauncherOnly = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        Assert-StableStopped
        $labProcessId = Get-ExactPid $script:Package -AllowMissing
        if ($null -eq $labProcessId) {
            Start-Sleep -Seconds 1
            continue
        }
        if ($null -eq $firstPid) { $firstPid = [int]$labProcessId }
        Require ([int]$labProcessId -eq [int]$firstPid) `
            'Launcher-only phase changed PID.'
        $threads = Get-ThreadNames ([int]$labProcessId)
        $hasGameJvm = @($threads | Where-Object { $_ -ceq 'QuestCraft-JVM' }).Count -gt 0
        if ($hasGameJvm) {
            throw 'Plain component start dispatched the game JVM; launcher-only interruption is not safe.'
        }
        $hasUnityMain = @($threads | Where-Object { $_ -ceq 'UnityMain' }).Count -gt 0
        $after = Get-LogSnapshot
        $logUnchanged = Test-LogSnapshotEqual $MinecraftLogBaseline $after
        if ($hasUnityMain -and $logUnchanged -and (Test-LabFocused)) {
            $consecutiveLauncherOnly++
        } else {
            $consecutiveLauncherOnly = 0
        }
        if ($consecutiveLauncherOnly -ge 3) {
            return [pscustomobject]@{
                Result = 'PASS'
                LauncherOnlyProven = $true
                UnityMainPresent = $true
                GameJvmAbsent = $true
                MinecraftLogUntouched = $true
                RandomInputSent = $false
            }
        }
        Start-Sleep -Seconds 1
    }
    throw 'Could not prove a focused launcher-only state without a game JVM.'
}

function Get-PlanRecord {
    $producerLineage = Get-LifecycleProducerLineage
    return [pscustomobject]@{
        Result = 'PLAN'
        DeviceTouched = $false
        Package = $script:Package
        ForbiddenStablePackage = $script:StablePackage
        InstalledApkSha256Required = $script:ExpectedApkSha256
        CandidateBuildState = $(if ($script:ExpectedApkSha256 -ceq ('0' * 64) -or
            $script:ExpectedApkSizeBytes -le 0) { 'PENDING_NOT_BUILT' } else { 'LOCKED' })
        RequiredInitialState = 'Stable stopped; Lab stopped; no active soak or manual session'
        Authorization = @(
            '-AllowDeviceRead', '-AllowDeviceWrite', '-AllowForceStop', '-AllowLaunch',
            '-AllowLauncherInterruption', '-ConfirmNoActiveSoakOrManualSession')
        Phases = @(
            'clean stopped -> authenticated autoplay -> exact RC4/OpenXR frame 120',
            'stop live OpenXR process -> authenticated autoplay recovery -> exact RC4/OpenXR frame 120',
            'plain launcher-only start -> prove UnityMain/no QuestCraft-JVM/no log change -> force-stop',
            'authenticated autoplay after launcher interruption -> exact RC4/OpenXR frame 120',
            'final stopped Lab + unchanged installed APK + exact RC4 pair')
        Never = @(
            'Stable package lifecycle', 'APK install/uninstall', 'pm clear', 'direct ADB profile mutation',
            'account/saves ADB writes', 'controller/touch/key/random input', 'root')
        ExplicitlyNotProven = @(
            'separate launcher-process death after JVM handoff (Unity and JVM share one PID)',
            'the narrow gameReady-to-OpenXR-init interval (frozen RC4 has no post-init ACK)',
            'manual eye/controller correctness', 'memory-soak or performance acceptance')
        FinalState = 'Lab stopped; Stable untouched'
        EvidenceReceiptPath = $script:EvidenceReceiptRelativePath
        EvidenceReceiptPublication = 'atomic write-once strict-UTF8 JSON; lock path and SHA-256 in V71_STABLE_RC4_ACCEPTANCE.lock.json'
        ProducerHashScheme = $script:ProducerHashScheme
        ProducerSha256 = [string]$producerLineage.files[0].sha256
        ProducerLineageSha256 = [string]$producerLineage.digestSha256
        RawLogsPersisted = $false
    }
}

function Invoke-SelfTest {
    $before = $script:DeviceInvocationCount
    Require (Test-Path -LiteralPath $script:LockPath -PathType Leaf) `
        'V71 RC4 lock is missing.'
    $lock = Get-Content -Raw -LiteralPath $script:LockPath | ConvertFrom-Json
    Require ([string]$lock.target.package -ceq $script:Package -and
        [string]$lock.target.forbiddenStablePackage -ceq $script:StablePackage -and
        -not [bool]$lock.target.stableTouched -and
        [int]$lock.target.labShellVersionCode -eq [int]$script:ExpectedVersionCode -and
        [string]$lock.target.labShellVersionName -ceq $script:ExpectedVersionName) `
        'RC4 lock target identity drifted.'
    Require ((Normalize-Sha256 ([string]$lock.pair.core.sha256)) -ceq
            $script:ExpectedCoreSha256 -and
        [int64]$lock.pair.core.sizeBytes -eq $script:ExpectedCoreSizeBytes -and
        [string]$lock.pair.core.fabricVersion -ceq $script:ExpectedCoreVersion) `
        'RC4 lock Core identity drifted.'
    Require ((Normalize-Sha256 ([string]$lock.pair.veq.sha256)) -ceq
            $script:ExpectedVeqSha256 -and
        [int64]$lock.pair.veq.sizeBytes -eq $script:ExpectedVeqSizeBytes -and
        [string]$lock.pair.veq.fabricVersion -ceq $script:ExpectedVeqVersion) `
        'RC4 lock frozen VEQ identity drifted.'
    $null = Get-FileIdentity $script:CoreArtifactPath $script:ExpectedCoreSha256 `
        $script:ExpectedCoreSizeBytes 'embedded v71 RC4 Core asset'
    $null = Get-FileIdentity $script:VeqArtifactPath $script:ExpectedVeqSha256 `
        $script:ExpectedVeqSizeBytes 'embedded frozen v71 VEQ asset'
    Require (Test-Path -LiteralPath $script:AutoplayPath -PathType Leaf) `
        'The fixed Lab autoplay helper is missing.'
    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,
        [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0) 'PowerShell parser rejected the lifecycle/recovery gate.'
    $automaticVariableCollisions = @(Get-ReadOnlyAutomaticVariableCollisions $ast)
    Require ($automaticVariableCollisions.Count -eq 0) `
        ('Lifecycle executable paths assign to or bind a Constant/ReadOnly ' +
        'automatic variable: ' +
        (($automaticVariableCollisions | ForEach-Object {
            "$($_.Kind):$($_.Name):$($_.Line)"
        }) -join ', '))

    $fixtureTokens = $null
    $fixtureErrors = $null
    $fixtureAst = [Management.Automation.Language.Parser]::ParseInput(@'
function Invoke-AutomaticVariableCollisionFixture {
    param([string] $hOmE)
    $PiD = 123
}
'@, [ref]$fixtureTokens, [ref]$fixtureErrors)
    Require ($fixtureErrors.Count -eq 0) `
        'The automatic-variable collision regression fixture did not parse.'
    $fixtureCollisions = @(Get-ReadOnlyAutomaticVariableCollisions $fixtureAst)
    Require ($fixtureCollisions.Count -eq 2 -and
        @($fixtureCollisions | Where-Object {
            $_.Kind -ceq 'Parameter' -and $_.Name -ceq 'hOmE'
        }).Count -eq 1 -and
        @($fixtureCollisions | Where-Object {
            $_.Kind -ceq 'Assignment' -and $_.Name -ceq 'PiD'
        }).Count -eq 1) `
        'The AST regression did not detect case-insensitive automatic-variable collisions.'
    $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
        $_.Name.VariablePath.UserPath
    })
    Require ($parameterNames -cnotcontains 'Package' -and
        $parameterNames -cnotcontains 'Profile' -and
        $parameterNames -cnotcontains 'ApkPath') `
        'The gate exposes a target-identity override.'
    Require ($source.Contains("`$script:Package = '$script:Package'") -and
        $source.Contains("`$script:StablePackage = '$script:StablePackage'") -and
        $source.Contains("`$script:LockPath = Join-Path `$script:RepoRoot 'V71_LAB_RC4.lock.json'") -and
        $source.Contains('currentIntegratedApkArtifactAuditPassed')) `
        'The exact Lab/Stable/APK pins are absent.'
    foreach ($forbiddenPattern in @(
        '(?i)[''"]pm[''"]\s*,\s*[''"](?:clear|uninstall)[''"]',
        '(?i)[''"]adb[''"]\s*,\s*[''"]install(?:-multiple)?[''"]',
        '(?i)[''"]input[''"]\s*,\s*[''"](?:keyevent|tap|swipe|text)[''"]',
        '(?i)[''"](?:sendevent|monkey|uiautomator|run-as)[''"]\s*,',
        '(?i)\brm\s+-rf\b',
        '(?i)\bsu\s+-c\b')) {
        Require (-not ($source -match $forbiddenPattern)) `
            "Forbidden device-command pattern is present: $forbiddenPattern"
    }
    Require ($source.Contains('Plain component start dispatched the game JVM; launcher-only interruption is not safe.')) `
        'Launcher-only fail-closed JVM gate is absent.'
    Require ($source.Contains('ExplicitlyNotProven') -and
        $source.Contains('frozen RC4 has no post-init ACK')) `
        'The untestable post-handoff window is not documented in Plan.'
    Require ($source.Contains('Require ($null -eq (Get-ExactPid $script:Package -AllowMissing))') -and
        $source.Contains('ConfirmNoActiveSoakOrManualSession')) `
        'Run does not refuse an active Lab/soak session.'
    Require ($source.Contains("'am', 'start', '-n', `$script:Component")) `
        'Launcher interruption is not an explicit component start.'
    Require ($source.Contains('[IO.FileMode]::CreateNew') -and
        $source.Contains('[IO.FileOptions]::WriteThrough') -and
        $source.Contains('[IO.File]::Move($temporary, $full)')) `
        'Lifecycle evidence publication is no longer atomic and write-once.'
    $authorizationRejected = $false
    try { Assert-RunAuthorization } catch { $authorizationRejected = $true }
    Require $authorizationRejected 'Run authorization unexpectedly passed without switches.'
    $pmPath = Get-ExactPmBaseApkPath @(
        'package:/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk')
    Require ($pmPath -ceq '/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk') `
        'Strict monolithic pm path was rejected.'
    $multiRejected = $false
    try {
        $null = Get-ExactPmBaseApkPath @(
            'package:/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk',
            'package:/data/app/~~abc/com.qcxr.qcxr.canary262-def/split_config.arm64_v8a.apk')
    } catch { $multiRejected = $true }
    Require $multiRejected 'Split/ambiguous pm path was accepted.'
    $snapshotA = [pscustomobject]@{
        Inode='10'; SizeBytes=100L; PrefixBytes=100; PrefixSha256=('A' * 64); Mtime=5L
    }
    $snapshotB = [pscustomobject]@{
        Inode='10'; SizeBytes=100L; PrefixBytes=100; PrefixSha256=('A' * 64); Mtime=5L
    }
    Require (Test-LogSnapshotEqual $snapshotA $snapshotB) 'Equal log snapshots were rejected.'
    $snapshotB.SizeBytes = 101L
    Require (-not (Test-LogSnapshotEqual $snapshotA $snapshotB)) `
        'A changed Minecraft log was accepted as launcher-only.'
    $producerLineage = Get-LifecycleProducerLineage
    $expectedLifecycleProducerSha256 = Get-NormalizedTextSha256 $PSCommandPath `
        'lifecycle/recovery producer'
    Require ([int]$producerLineage.schemaVersion -eq 1 -and
        [string]$producerLineage.hashScheme -ceq $script:ProducerHashScheme -and
        @($producerLineage.files).Count -eq 2 -and
        [string]$producerLineage.files[0].name -ceq 'lifecycle-orchestrator' -and
        [string]$producerLineage.files[0].relativePath -ceq
            'scripts/quest-v71-lab-lifecycle-recovery-rc4.ps1' -and
        [string]$producerLineage.files[0].sha256 -ceq $expectedLifecycleProducerSha256 -and
        [string]$producerLineage.files[1].name -ceq 'autoplay-harness' -and
        [string]$producerLineage.files[1].relativePath -ceq
            'scripts/run-vivecraft-local-autoplay.ps1' -and
        [string]$producerLineage.files[1].sha256 -ceq $script:ExpectedAutoplaySha256 -and
        [string]$producerLineage.digestSha256 -ceq
            (Get-ProducerLineageDigest @($producerLineage.files))) `
        'Lifecycle producer lineage is incomplete or inconsistent.'
    $fixtureRuntimeProof = [pscustomobject]@{
        Result='PASS'; ExactRc4VersionRows=$true; OpenXrFocused=$true
        OpenXrFrame120Submitted=$true; BenchmarkWorldLoaded=$true; GameJvmAlive=$true
    }
    $fixtureLauncherProof = [pscustomobject]@{
        Result='PASS'; LauncherOnlyProven=$true; UnityMainPresent=$true
        GameJvmAbsent=$true; MinecraftLogUntouched=$true; RandomInputSent=$false
    }
    $fixturePair = [pscustomobject]@{
        CoreSha256=$script:ExpectedCoreSha256; VeqSha256=$script:ExpectedVeqSha256
    }
    $fixtureApkSha256 = 'A' * 64
    $fixtureApkSizeBytes = 123456L
    $fixtureInstalled = [pscustomobject]@{
        Package=$script:Package; VersionCode=$script:ExpectedVersionCode
        VersionName=$script:ExpectedVersionName
        ApkSha256=$fixtureApkSha256; ApkSizeBytes=$fixtureApkSizeBytes
    }
    $fixtureStarted = [DateTimeOffset]::Parse('2026-09-06T00:00:00Z')
    $fixtureReceipt = New-LifecycleEvidenceReceipt `
        -InstalledBefore $fixtureInstalled -InstalledAfter $fixtureInstalled `
        -PairBefore $fixturePair `
        -ColdOpenXr $fixtureRuntimeProof -PostOpenXrRecovery $fixtureRuntimeProof `
        -LauncherOnly $fixtureLauncherProof -PostLauncherRecovery $fixtureRuntimeProof `
        -PairAfter $fixturePair -ProducerLineage $producerLineage `
        -StartedUtc $fixtureStarted -CompletedUtc $fixtureStarted.AddMinutes(1)
    $fixtureJson = $fixtureReceipt | ConvertTo-Json -Depth 16 -Compress
    Require (@($fixtureReceipt.phases).Count -eq 6 -and
        [string]$fixtureReceipt.finalState.lab -ceq 'stopped' -and
        [bool]$fixtureReceipt.finalState.exactRc4Pair -and
        -not [bool]$fixtureReceipt.finalState.stableTouched -and
        -not $fixtureJson.Contains('offline-proof') -and
        -not $fixtureJson.Contains($script:EvidenceReceiptPath)) `
        'Lifecycle receipt fixture is incomplete or contains endpoint/absolute-path data.'
    $fixtureChangedInstalled = [pscustomobject]@{
        Package=$script:Package; VersionCode=$script:ExpectedVersionCode
        VersionName=$script:ExpectedVersionName; ApkSha256=('0' * 64)
        ApkSizeBytes=$fixtureApkSizeBytes
    }
    $changedInstalledRejected = $false
    try {
        $null = New-LifecycleEvidenceReceipt `
            -InstalledBefore $fixtureInstalled -InstalledAfter $fixtureChangedInstalled `
            -PairBefore $fixturePair -ColdOpenXr $fixtureRuntimeProof `
            -PostOpenXrRecovery $fixtureRuntimeProof `
            -LauncherOnly $fixtureLauncherProof `
            -PostLauncherRecovery $fixtureRuntimeProof `
            -PairAfter $fixturePair -ProducerLineage $producerLineage `
            -StartedUtc $fixtureStarted -CompletedUtc $fixtureStarted.AddMinutes(1)
    } catch { $changedInstalledRejected = $true }
    Require $changedInstalledRejected `
        'A changed final installed Lab identity was accepted for a PASS receipt.'
    Require ($script:DeviceInvocationCount -eq $before) 'SelfTest invoked ADB.'
    return [pscustomobject]@{
        Result = 'PASS'
        Assertions = 30
        DeviceTouched = $false
        DeviceInvocationCount = $script:DeviceInvocationCount - $before
        AutomaticVariableCollisionScan = $true
        AutomaticVariableCollisionCount = $automaticVariableCollisions.Count
        AutomaticVariableCaseFixtureRejected = $true
        Package = $script:Package
        ForbiddenStablePackage = $script:StablePackage
        InstalledApkSha256 = 'PENDING_FROM_V71_LAB_RC4_LOCK'
        EvidenceReceiptPath = $script:EvidenceReceiptRelativePath
        ProducerSha256 = [string]$producerLineage.files[0].sha256
        ProducerLineageSha256 = [string]$producerLineage.digestSha256
        AtomicWriteOnceReceipt = $true
        FinalInstalledIdentityRecheck = $true
        TestableRecovery = 'full-process and pre-JVM launcher interruption'
        UntestableRecovery = 'gameReady-to-OpenXR-init without a frozen-Core ACK'
        RawLogsPersisted = $false
    }
}

function Invoke-Run {
    Assert-RunAuthorization
    $runtimeLock = $null
    $producerReadLocks = [Collections.Generic.List[IDisposable]]::new()
    $runResult = $null
    $primaryError = $null
    $receiptPublished = $false
    $startedUtc = [DateTimeOffset]::UtcNow
    $finalizationErrors = [Collections.Generic.List[string]]::new()
    try {
        $producerReadLocks.Add((Enter-ProducerReadLock $PSCommandPath `
            'lifecycle/recovery producer'))
        $producerReadLocks.Add((Enter-ProducerReadLock $script:AutoplayPath `
            'fixed Lab autoplay dependency'))
        Resolve-HostContract
        $producerLineage = Get-LifecycleProducerLineage
        $runtimeLock = Enter-RuntimeLock
        Assert-EvidenceReceiptDestinationAvailable
        Resolve-Device
        Assert-StableStopped
        Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
            'Lab is active. Finish the soak/manual session and stop Lab before Run.'

        $installed = Get-InstalledIdentity
        $pairBefore = Get-PhysicalPair
        Assert-StableStopped
        $script:MutationStarted = $true

        # A redundant fixed-package stop establishes a clean ActivityManager state.
        Stop-Lab
        $cold = Invoke-RuntimeCycle 'clean-cold-openxr'

        # Stop a proven live OpenXR process, then prove a complete-process recovery.
        Stop-Lab
        $postOpenXrStopRecovery = Invoke-RuntimeCycle 'post-openxr-process-stop-recovery'
        Stop-Lab

        # Start only the Unity launcher, prove no game JVM/log dispatch, interrupt it,
        # then prove the exact Lab can recover without synthetic UI input.
        $launcherBaseline = Get-LogSnapshot
        $launcherOnly = Start-LauncherOnlyAndWait $launcherBaseline
        Stop-Lab
        $postLauncherInterruption = Invoke-RuntimeCycle 'post-launcher-interruption-recovery'
        Stop-Lab
        Assert-StableStopped
        Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
            'Lab was not stopped after the recovery gate.'

        $null = Get-FileIdentity $script:ApkPath $script:ExpectedApkSha256 `
            $script:ExpectedApkSizeBytes 'post-run integrated v71 RC4 Lab APK'
        $null = Get-FileIdentity $script:CoreArtifactPath $script:ExpectedCoreSha256 `
            $script:ExpectedCoreSizeBytes 'post-run embedded v71 RC4 Core asset'
        $null = Get-FileIdentity $script:VeqArtifactPath $script:ExpectedVeqSha256 `
            $script:ExpectedVeqSizeBytes 'post-run embedded v71 RC4 VEQ asset'

        # Complete the fail-closed cleanup before publishing a PASS receipt. On
        # success, the outer finally no longer needs to mutate the device.
        Stop-LabCleanup
        $script:MutationStarted = $false
        Assert-StableStopped
        Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
            'Lab was not stopped at evidence publication.'
        $installedAfter = Get-InstalledIdentity
        $pairAfter = Get-PhysicalPair
        Require ([string]$installed.Package -ceq [string]$installedAfter.Package -and
            [string]$installed.VersionCode -ceq [string]$installedAfter.VersionCode -and
            [string]$installed.VersionName -ceq [string]$installedAfter.VersionName -and
            [string]$installed.ApkSha256 -ceq [string]$installedAfter.ApkSha256 -and
            [int64]$installed.ApkSizeBytes -eq [int64]$installedAfter.ApkSizeBytes) `
            'Installed Lab APK identity changed during lifecycle/recovery Run.'

        $receipt = New-LifecycleEvidenceReceipt `
            -InstalledBefore $installed -InstalledAfter $installedAfter `
            -PairBefore $pairBefore -ColdOpenXr $cold `
            -PostOpenXrRecovery $postOpenXrStopRecovery `
            -LauncherOnly $launcherOnly `
            -PostLauncherRecovery $postLauncherInterruption `
            -PairAfter $pairAfter -ProducerLineage $producerLineage `
            -StartedUtc $startedUtc -CompletedUtc ([DateTimeOffset]::UtcNow)
        $receiptIdentity = Write-AtomicEvidenceReceipt $receipt
        $receiptPublished = $true
        $runResult = [pscustomobject]@{
            Result = 'PASS'
            Package = $installedAfter.Package
            VersionCode = $installedAfter.VersionCode
            VersionName = $installedAfter.VersionName
            InstalledApkSha256 = $installedAfter.ApkSha256
            ExactPairBefore = ($pairBefore.CoreSha256 -ceq $script:ExpectedCoreSha256 -and
                $pairBefore.VeqSha256 -ceq $script:ExpectedVeqSha256)
            ExactPairAfter = ($pairAfter.CoreSha256 -ceq $script:ExpectedCoreSha256 -and
                $pairAfter.VeqSha256 -ceq $script:ExpectedVeqSha256)
            ColdOpenXr = $cold
            PostOpenXrProcessStopRecovery = $postOpenXrStopRecovery
            LauncherOnlyInterruption = $launcherOnly
            PostLauncherInterruptionRecovery = $postLauncherInterruption
            StablePidAbsentThroughout = $true
            FinalLabState = 'stopped'
            StableTouched = $false
            DirectProfileFileWritesByGate = $false
            NormalRuntimeMayPersistProfileOrWorld = $true
            RandomInputSent = $false
            AccountOrSaveFilesWrittenByAdb = $false
            PostInitAcknowledgementProven = $false
            PostInitAcknowledgementLimitation = `
                'Frozen RC4 has no ACK; Unity launcher and JVM share one Android PID.'
            EvidenceReceiptPath = [string]$receiptIdentity.RelativePath
            EvidenceReceiptSha256 = [string]$receiptIdentity.Sha256
            EvidenceReceiptSizeBytes = [int64]$receiptIdentity.SizeBytes
            EvidenceReceiptAtomicWrite = [bool]$receiptIdentity.AtomicWrite
            EvidenceReceiptWriteOnce = [bool]$receiptIdentity.WriteOnce
            ProducerSha256 = [string]$producerLineage.files[0].sha256
            ProducerLineageSha256 = [string]$producerLineage.digestSha256
            RawLogsPersisted = $false
        }
    } catch {
        $primaryError = $_
    } finally {
        if ($script:MutationStarted -and $script:DeviceResolved) {
            try { Stop-LabCleanup } catch {
                $finalizationErrors.Add('Lab final force-stop: ' + $_.Exception.Message)
            }
        }
        if ($null -ne $runtimeLock) {
            try { $runtimeLock.Dispose() } catch {
                $finalizationErrors.Add('runtime lock disposal: ' + $_.Exception.Message)
            }
        }
        for ($index = $producerReadLocks.Count - 1; $index -ge 0; $index--) {
            try { $producerReadLocks[$index].Dispose() } catch {
                $finalizationErrors.Add('producer read-lock disposal: ' + $_.Exception.Message)
            }
        }
        if ($receiptPublished -and
                ($null -ne $primaryError -or $finalizationErrors.Count -gt 0)) {
            try {
                $publishedPath = Assert-NoReparseContainment `
                    $script:EvidenceReceiptPath $script:WorkspaceRoot `
                    'failed lifecycle/recovery evidence receipt'
                if (Test-Path -LiteralPath $publishedPath -PathType Leaf) {
                    [IO.File]::Delete($publishedPath)
                }
            } catch {
                $finalizationErrors.Add('failed receipt removal: ' + $_.Exception.Message)
            }
        }
    }
    if ($finalizationErrors.Count -gt 0) {
        $message = '[FATAL_CLEANUP] ' + ($finalizationErrors -join '; ')
        if ($null -ne $primaryError) {
            $message += '; primary failure: ' + $primaryError.Exception.Message
        }
        throw $message
    }
    if ($null -ne $primaryError) { throw $primaryError }
    Require ($null -ne $runResult) 'Lifecycle gate ended without a result.'
    return $runResult
}

switch ($Action) {
    'SelfTest' { Invoke-SelfTest; break }
    'Plan' {
        $before = $script:DeviceInvocationCount
        Require ($script:DeviceInvocationCount -eq $before) 'Plan invoked ADB.'
        Get-PlanRecord
        break
    }
    'Run' { Invoke-Run; break }
}
