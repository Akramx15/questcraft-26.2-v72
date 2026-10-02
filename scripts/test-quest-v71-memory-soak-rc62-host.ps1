#requires -Version 7.0
<# Host-only profile-binding regression test for the fixed RC6.2 memory sampler. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC6_2_MEMORY_SOAK_HOST_TEST] $Message" }
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($text)))
}

$sampler = Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc62.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'V71_LAB_RC6_2.lock.json') | ConvertFrom-Json
$evidenceLock = Get-Content -Raw -LiteralPath `
    (Join-Path $repoRoot 'V71_RC6_2_EVIDENCE_PRODUCERS.lock.json') | ConvertFrom-Json
$manualTemplate = Get-Content -Raw -LiteralPath `
    (Join-Path $repoRoot 'V71_MANUAL_RC6_2_ACCEPTANCE.template.json') | ConvertFrom-Json
$sentinel = Join-Path $PSScriptRoot '__quest-v71-memory-soak-rc62-host-test-no-adb__.exe'
Require (Test-Path -LiteralPath $sampler -PathType Leaf) 'The RC6.2 memory sampler is missing.'
Require (-not (Test-Path -LiteralPath $sentinel)) 'The ADB sentinel unexpectedly exists.'

$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    $sampler, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'The PowerShell parser rejected the RC6.2 memory sampler.'

$selfTestValues = @(& $sampler -Action SelfTest -Serial 'offline-proof' -AdbPath $sentinel)
$selfTest = @($selfTestValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($selfTest.Count -eq 1 -and [string]$selfTest[0].Result -ceq 'PASS') `
    'SelfTest did not return one PASS record.'
Require ([bool]$selfTest[0].HostOnly -and [int]$selfTest[0].DeviceInvocations -eq 0) `
    'SelfTest touched or resolved a device.'
Require ([bool]$selfTest[0].BatteryAndThermalStatusRecordedEverySample -and
        [double]$selfTest[0].DefaultMaxBatteryTemperatureC -eq 47.0 -and
        [int]$selfTest[0].DefaultMaxThermalStatus -eq 2 -and
        [bool]$selfTest[0].ThermalLimitFixturesPassed -and
        [int]$selfTest[0].ThermalSafetyStopInvocations -eq 0 -and
        [string]$selfTest[0].ThermalSafetyStopTarget -ceq
            'com.qcxr.qcxr.canary262') `
    'SelfTest did not prove the Lab-only thermal safety contract.'
Require ([bool]$selfTest[0].ExpectedGameLogPathBound -and
        [bool]$selfTest[0].ExpectedGameLogIdentityAtStartAndFinal -and
        [bool]$selfTest[0].ExpectedGameLogFreshnessEverySample) `
    'SelfTest did not prove the complete expected-profile game-log boundary.'
Require ([bool]$selfTest[0].WrongProfileFixtureRejected -and
        [bool]$selfTest[0].StaleGameLogFixtureRejected -and
        [bool]$selfTest[0].WrongVersionFixturesRejected) `
    'SelfTest did not exercise all fail-closed profile/version/freshness fixtures.'
Require (-not [bool]$selfTest[0].RawGameLogDataPersisted) `
    'SelfTest reported that raw game-log data is persisted.'
Require (-not (Test-Path -LiteralPath $sentinel)) `
    'The Host-only test attempted to create or use the ADB sentinel.'
$sampleRejectedBeforeAdb = $false
try {
    & $sampler -Action Sample -Serial 'offline-proof' -AdbPath $sentinel `
        -AllowDeviceRead | Out-Null
} catch {
    $sampleRejectedBeforeAdb = $_.Exception.Message.Contains(
        'explicit -AllowThermalSafetyStop', [StringComparison]::Ordinal)
}
Require $sampleRejectedBeforeAdb `
    'Sample mode did not require the explicit thermal safety-stop authorization.'
Require (-not (Test-Path -LiteralPath $sentinel)) `
    'The missing-safety-authorization fixture resolved or invoked ADB.'

$selfTestJson = $selfTest[0] | ConvertTo-Json -Depth 6 -Compress
Require ($selfTestJson -notmatch
        '(?i)account@example|serverAddress|worldName|private-world|/sdcard/|Loading Minecraft') `
    'The public SelfTest result exposed raw log, device-path, account, server, or world data.'

$source = [IO.File]::ReadAllText($sampler)
Require ((Get-NormalizedTextSha256 $sampler) -ceq
        [string]$evidenceLock.producers.memorySoakScriptSha256) `
    'The RC6.2 memory sampler does not match its immutable producer lock.'
Require ([string]$evidenceLock.historicalClone.sourcePath -ceq
        'scripts/quest-v71-memory-soak-rc5.ps1' -and
        [string]$evidenceLock.historicalClone.sourceNormalizedSha256 -ceq
            '5F07BA4A71A3886077A3C34CFA876C05254C8095C6C28BE689B9B03040C10547' -and
        [bool]$evidenceLock.historicalClone.sourceRemainsImmutable) `
    'The historical RC5 clone boundary drifted.'
$historicalSampler = Join-Path $repoRoot `
    ([string]$evidenceLock.historicalClone.sourcePath)
Require (Test-Path -LiteralPath $historicalSampler -PathType Leaf) `
    'The historical RC5 memory sampler is missing.'
Require ((Get-NormalizedTextSha256 $historicalSampler) -ceq
        [string]$evidenceLock.historicalClone.sourceNormalizedSha256) `
    'The historical RC5 memory sampler bytes changed.'
Require ([string]$selfTest[0].Package -ceq [string]$buildLock.target.package -and
    [string]$selfTest[0].Profile -ceq [string]$buildLock.target.profile -and
    [string]$selfTest[0].ExpectedGameLogRelativePath -ceq
        [string]$buildLock.runtimeBinding.expectedGameLogRelativePath -and
    [string]$selfTest[0].ExpectedGameLogMinecraftVersion -ceq
        [string]$buildLock.runtimeBinding.expectedGameLogMinecraftVersion -and
    [string]$selfTest[0].ExpectedGameLogCoreVersion -ceq
        [string]$buildLock.runtimeBinding.expectedGameLogCoreVersion -and
    [string]$selfTest[0].ExpectedGameLogVeqVersion -ceq
        [string]$buildLock.runtimeBinding.expectedGameLogVeqVersion) `
    'The dynamically locked expected-profile path or runtime versions drifted.'
Require ($source.Contains('Get-ExpectedGameLogIdentityObservation') -and
    $source.Contains('Get-ExpectedGameLogFreshnessObservation') -and
    $source.Contains('expectedGameLogEvidenceOnlyBooleansAndTimestamps')) `
    'The sampler no longer exposes the expected safe game-log boundary.'
Require ($source.Contains("Invoke-ReadShell 'dumpsys battery'") -and
        $source.Contains("Invoke-ReadShell 'dumpsys thermalservice'") -and
        $source.Contains("'shell', 'am', 'force-stop',") -and
        $source.Contains("'com.qcxr.qcxr.canary262')") -and
        -not $source.Contains("'force-stop', 'com.qcxr.qcxr.dev262'")) `
    'The thermal probes or exact Lab-only safety stop drifted.'
Require ([string]$buildLock.target.package -ceq 'com.qcxr.qcxr.canary262' -and
        [int]$buildLock.target.versionCode -eq 71 -and
        [string]$buildLock.target.versionName -ceq
            '6.0.1-26.2-vivecraft-personal.12-rc.6.2' -and
        [string]$buildLock.target.apkSha256 -ceq
            'ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4' -and
        [string]$buildLock.pair.core.sha256 -ceq
            '6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF' -and
        [string]$buildLock.pair.veq.sha256 -ceq
            'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD' -and
        [string]$buildLock.pojlibAar.sha256 -ceq
            '6B9224C6697D00DCE363AD80EA5FA9946E90808C514517BA4EEDFEB31DB2BA89' -and
        [string]$buildLock.target.signerSha256 -ceq
            'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A') `
    'The immutable RC6.2 Lab identity or artifact hashes drifted.'
Require ([bool]$buildLock.immutable -and [bool]$evidenceLock.immutable -and
        [string]$evidenceLock.candidateBuildLockPath -ceq
            'V71_LAB_RC6_2.lock.json') `
    'An RC6.2 lock is mutable or points at another candidate.'
foreach ($artifact in @(
    [pscustomobject]@{
        Path = 'Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin'
        Sha256 = [string]$buildLock.pair.core.sha256
        SizeBytes = [int64]$buildLock.pair.core.sizeBytes
    },
    [pscustomobject]@{
        Path = 'Pojlib/src/main/assets/mods/vivecraft-essentials-quest.bin'
        Sha256 = [string]$buildLock.pair.veq.sha256
        SizeBytes = [int64]$buildLock.pair.veq.sizeBytes
    },
    [pscustomobject]@{
        Path = 'QCXR-XR-Wrapper/Assets/Plugins/Android/Pojlib-release.aar'
        Sha256 = [string]$buildLock.pojlibAar.sha256
        SizeBytes = [int64]$buildLock.pojlibAar.sizeBytes
    })) {
    $path = Join-Path $repoRoot ([string]$artifact.Path)
    Require (Test-Path -LiteralPath $path -PathType Leaf) `
        "Locked artifact is missing: $($artifact.Path)."
    Require ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq
            [string]$artifact.Sha256 -and
            (Get-Item -LiteralPath $path).Length -eq [int64]$artifact.SizeBytes) `
        "Locked artifact bytes drifted: $($artifact.Path)."
}
$pairText = "core=$([string]$buildLock.pair.core.sha256)`n" +
    "veq=$([string]$buildLock.pair.veq.sha256)`n"
$pairSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes($pairText)))
Require ($pairSha256 -ceq [string]$buildLock.pair.sha256) `
    'The locked Core/VEQ pair digest is invalid.'
$checksums = Get-Content -LiteralPath (Join-Path $repoRoot 'CHECKSUMS.sha256')
$apkChecksumLine = [string]$buildLock.target.apkSha256 + '  ' +
    [string]$buildLock.target.apkPath
Require (@($checksums | Where-Object { [string]$_ -ceq $apkChecksumLine }).Count -eq 1) `
    'CHECKSUMS.sha256 does not contain the one exact RC6.2 APK binding.'
$requiredManualFields = @(
    'shield_hidden_only_while_wrist_visible',
    'shield_blocking_and_inventory_unchanged',
    'shield_returns_on_close',
    'grip_visible_over_blocks_in_1x1_tunnel',
    'grip_selectable_both_hands',
    'reverseHands'
)
foreach ($field in $requiredManualFields) {
    Require ($null -ne $manualTemplate.observations.PSObject.Properties[$field]) `
        "Manual RC6.2 observation is missing: $field."
}
foreach ($field in $requiredManualFields | Where-Object { $_ -cne 'reverseHands' }) {
    Require ([string]$manualTemplate.observations.$field -ceq
            'PENDING_USER_OBSERVATION') `
        "Manual RC6.2 observation was pre-accepted: $field."
}
Require ([string]$manualTemplate.observations.reverseHands.applicability -ceq
        'PENDING_USER_SELECTION' -and
        [string]$manualTemplate.observations.reverseHands.resultIfApplicable -ceq
            'PENDING_USER_OBSERVATION') `
    'The reverse-hands observation is not explicitly pending when applicable.'
Require ([string]$manualTemplate.status -ceq 'PENDING_USER_OBSERVATION' -and
        -not [bool]$manualTemplate.userConfirmed -and
        [string]$manualTemplate.evidenceRules.source -ceq 'USER_OBSERVATION_ONLY' -and
        -not [bool]$manualTemplate.evidenceRules.mayInferFromLogs) `
    'The manual RC6.2 receipt can be inferred or is pre-accepted.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    PowerShellParsePassed = $true
    ExpectedProfilePathBound = $true
    ExactRuntimeVersionsBound = $true
    EverySampleFreshnessBound = $true
    ThermalSafetyContractBound = $true
    ImmutableLocksBound = $true
    HistoricalRc5SourceVerified = $true
    LockedArtifactBytesVerified = $true
    ManualUserObservationTemplateBound = $true
    FailClosedFixturesPassed = $true
    RawGameLogDataPersisted = $false
}
