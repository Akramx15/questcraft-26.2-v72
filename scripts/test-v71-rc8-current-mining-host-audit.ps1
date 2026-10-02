#requires -Version 7.0
<#
.SYNOPSIS
Audits the current post-artifact RC8 mining state without contacting a device.

.DESCRIPTION
The locked RC8 build gate intentionally pins the integration tree and therefore
rejects the later test-only mining coverage commit. This audit proves that the
only Vivecraft/VEQ changes after integration are the exact reviewed test file
and its exact Gradle test registration, that all runtime sources and locked APK
bytes remain unchanged, and that the install, rollback, runtime-capture, and
runtime-verifier default paths remain Host-only. It cannot establish controller
or block-breaking behavior.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC8_CURRENT_MINING_HOST_AUDIT] $Message" }
}

function Get-OneResult([string] $Path, [string] $ExpectedResult) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "Required Host tool is missing: $Path"
    $values = @(& $Path)
    $matches = @($values | Where-Object {
        $null -ne $_.PSObject.Properties['Result'] -and
        [string]$_.Result -ceq $ExpectedResult
    })
    Require ($matches.Count -eq 1) "$Path did not return one $ExpectedResult result."
    $matches[0]
}

function Get-NormalizedTextSha256([string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

$repo = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $repo)
$integrationCommit = '35c0e373b8227520554be311fa83bfa6e3d03987'
$expectedTests = [ordered]@{
    'Vivecraft-26.2-Quest/common/src/test/java/org/vivecraft/client_vr/gameplay/ClientHandActionTickGuardTest.java' =
        '81D71D908EBC8A7E926DE9322AC97E261DDDABF0B959F4961EF7F7D759B588D5'
    'Vivecraft-Essentials-Quest/mod-core/src/test/java/org/questcraft/veq/client/input/RightTriggerOwnershipRecoverySelfTest.java' =
        '8F75D9845E55079D4B0271A22873B93D0EA715E3D67F27825336B7F82ED21701'
}
$expectedTestBuildScriptPath = 'Vivecraft-Essentials-Quest/mod-core/build.gradle'
$expectedTestBuildScriptSha256 = '6338BCC3519BBA941528D437ECAE9C479882C11604D5FABEFE48B698CB0CF9D0'
$expectedApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$expectedCoreSha256 = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$expectedVeqSha256 = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$veqAssetPath = Join-Path $repo 'Pojlib\src\main\assets\mods\vivecraft-essentials-quest.bin'
$apkRelative = 'QCXR-XR-Wrapper\Builds\QuestCraft-Vivecraft-Lab-26.2-v71-rc.8-mining-local.apk'
$apkCandidates = @(
    (Join-Path $repo $apkRelative),
    (Join-Path $workspaceRoot ('work\agent-v71-rc8-mining\' + $apkRelative))
) | Select-Object -Unique
$existingApks = @($apkCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
Require ($existingApks.Count -ge 1) 'Locked RC8 Lab APK is missing from both fixed Host artifact locations.'
$apk = [string]$existingApks[0]
$lockPath = Join-Path $repo 'V71_LAB_RC8.lock.json'
$receiptPath = Join-Path $repo 'artifacts\runtime\v71-rc8-launch-20260907.json'
$authoritativeToolRepo = Join-Path $workspaceRoot 'work\agent-v71-rc8-mining'
if (-not (Test-Path -LiteralPath $authoritativeToolRepo -PathType Container)) {
    $authoritativeToolRepo = $repo
}
$authoritativeScripts = Join-Path $authoritativeToolRepo 'scripts'

& git -C $repo cat-file -e ($integrationCommit + '^{commit}')
Require ($LASTEXITCODE -eq 0) 'Locked RC8 integration commit is unavailable.'

# Runtime and packaging inputs after integration must be byte-identical in Git.
$runtimePaths = @(
    'Vivecraft-26.2-Quest/common/src/main',
    'Vivecraft-26.2-Quest/fabric/src/main',
    'Vivecraft-26.2-Quest/build.gradle',
    'Vivecraft-26.2-Quest/settings.gradle',
    'Vivecraft-Essentials-Quest/mod-core/src/main',
    'Vivecraft-Essentials-Quest/mod-fabric/src/main',
    'Vivecraft-Essentials-Quest/mod-fabric/build.gradle',
    'Vivecraft-Essentials-Quest/settings.gradle'
)
& git -C $repo diff --quiet $integrationCommit HEAD -- @runtimePaths
Require ($LASTEXITCODE -eq 0) 'A Vivecraft/VEQ runtime or packaging source changed after RC8 integration.'

$testPaths = @(
    'Vivecraft-26.2-Quest/common/src/test',
    'Vivecraft-Essentials-Quest/mod-core/src/test',
    'Vivecraft-Essentials-Quest/mod-fabric/src/test'
)
$changedTests = @(& git -C $repo diff --name-only $integrationCommit HEAD -- @testPaths |
    ForEach-Object { ([string]$_).Replace('\','/') } | Where-Object { $_ } | Sort-Object)
Require ($LASTEXITCODE -eq 0) 'Could not enumerate post-integration mining tests.'
$expectedTestPaths = @($expectedTests.Keys | Sort-Object)
$testPathDelta = @(Compare-Object -ReferenceObject $expectedTestPaths -DifferenceObject $changedTests)
Require ($testPathDelta.Count -eq 0) `
    'Post-integration test changes are not the exact reviewed mining coverage files.'
foreach ($expectedTestPath in $expectedTestPaths) {
    $testFile = Join-Path $repo ($expectedTestPath.Replace('/',[IO.Path]::DirectorySeparatorChar))
    Require ((Get-NormalizedTextSha256 -Path $testFile) -ceq
        [string]$expectedTests[$expectedTestPath]) "Reviewed post-artifact test bytes drifted: $expectedTestPath"
}
$testBuildScript = Join-Path $repo $expectedTestBuildScriptPath
Require ((Get-NormalizedTextSha256 -Path $testBuildScript) -ceq
    $expectedTestBuildScriptSha256) 'Reviewed post-artifact Gradle test registration drifted.'

foreach ($candidateApk in $existingApks) {
    Require ((Get-FileHash -LiteralPath $candidateApk -Algorithm SHA256).Hash.ToUpperInvariant() -ceq
        $expectedApkSha256) 'A fixed RC8 Lab APK location contains drifted bytes.'
}
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json -Depth 30
Require ([string]$lock.target.package -ceq 'com.qcxr.qcxr.canary262' -and
    [string]$lock.target.forbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
    [string]$lock.target.apkSha256 -ceq $expectedApkSha256 -and
    [string]$lock.pair.core.sha256 -ceq $expectedCoreSha256 -and
    [string]$lock.pair.veq.sha256 -ceq $expectedVeqSha256 -and
    -not [bool]$lock.acceptance.stablePromotionAllowed) 'RC8 identity or promotion lock drifted.'

# Audit the bytes that actually ship. Historical Visor/VEP sources remain in
# the repository for provenance, but mod-core deliberately excludes them.
Require (Test-Path -LiteralPath $veqAssetPath -PathType Leaf) 'Locked RC8 VEQ asset is missing.'
Require ((Get-FileHash -LiteralPath $veqAssetPath -Algorithm SHA256).Hash.ToUpperInvariant() -ceq
    $expectedVeqSha256) 'Locked RC8 VEQ asset drifted.'
$veqArchive = [IO.Compression.ZipFile]::OpenRead($veqAssetPath)
try {
    $veqEntries = @($veqArchive.Entries | ForEach-Object { [string]$_.FullName })
    Require (-not ($veqEntries | Where-Object {
        $_.StartsWith('org/vmstudio/', [StringComparison]::Ordinal) -or
        $_ -ceq 'org/questcraft/veq/mixin/MinecraftMixin.class'
    })) 'Exact RC8 VEQ artifact unexpectedly contains legacy Visor runtime code.'
    $mixinEntry = $veqArchive.GetEntry('vivecraft_essentials_quest.mixins.json')
    Require ($null -ne $mixinEntry) 'Exact RC8 VEQ artifact lacks its mixin manifest.'
    $mixinReader = [IO.StreamReader]::new($mixinEntry.Open(), [Text.Encoding]::UTF8, $true)
    try {
        $mixinText = $mixinReader.ReadToEnd()
    } finally {
        $mixinReader.Dispose()
    }
    Require (-not $mixinText.Contains('org.vmstudio', [StringComparison]::Ordinal) -and
        -not $mixinText.Contains('MinecraftMixin', [StringComparison]::Ordinal)) `
        'Exact RC8 mixin manifest references excluded legacy Visor code.'
} finally {
    $veqArchive.Dispose()
}

$install = Get-OneResult (Join-Path $authoritativeScripts 'quest-v71-lab-rc8-install.ps1') 'AUDIT_PASS'
$rollback = Get-OneResult (Join-Path $authoritativeScripts 'quest-v71-lab-rc7-rollback.ps1') 'AUDIT_PASS'
$capture = Get-OneResult (Join-Path $authoritativeScripts 'capture-verify-v71-rc8-runtime-log.ps1') 'PLAN_PASS'
foreach ($result in @($install,$rollback,$capture)) {
    Require ([bool]$result.HostOnly -and [int]$result.DeviceInvocations -eq 0 -and
        -not [bool]$result.StableTouched) 'A safety-tool default path crossed its Host/Stable boundary.'
}
Require (-not [bool]$capture.RawLogPersisted) 'Runtime capture default path claims raw-log retention.'

$verifierTest = Get-OneResult (Join-Path $authoritativeScripts 'test-verify-v71-rc8-runtime-log-host.ps1') 'PASS'
Require ([bool]$verifierTest.HostOnly -and [int]$verifierTest.DeviceInvocations -eq 0 -and
    [int]$verifierTest.NegativeFixturesRejected -ge 17 -and
    [bool]$verifierTest.ManualMiningAcceptancePreserved -and
    [bool]$verifierTest.StablePromotionPreserved) 'RC8 runtime verifier regression boundary failed.'

Require (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'Sanitized RC8 runtime receipt is missing.'
$receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json -Depth 20
Require ([string]$receipt.package -ceq 'com.qcxr.qcxr.canary262' -and
    [string]$receipt.apkSha256 -ceq $expectedApkSha256 -and
    [string]$receipt.runtimeLogSnapshot.vivecraft -ceq '26.2-1.3.15+qc.v71.rc8-mining' -and
    [string]$receipt.runtimeLogSnapshot.graphicsBackend -ceq 'Vulkan' -and
    [string]$receipt.runtimeLogSnapshot.xrRuntime -ceq 'OpenXR' -and
    -not [bool]$receipt.runtimeLogSnapshot.rawLogPersisted -and
    -not [bool]$receipt.liveConfigObservation.seated -and
    [string]$receipt.liveConfigObservation.aimDevice -ceq 'CONTROLLER' -and
    -not [bool]$receipt.liveConfigObservation.reverseHands -and
    [string]$receipt.liveConfigObservation.weaponCollisionNew -ceq 'ON' -and
    [string]$receipt.manualAcceptance.mining -ceq 'PENDING_USER_OBSERVATION' -and
    -not [bool]$receipt.manualAcceptance.stablePromotionAllowed) `
    'Sanitized runtime receipt overclaims mining or drifted from exact RC8.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    StableTouched = $false
    LockedApkSha256 = $expectedApkSha256
    RuntimeSourceUnchangedAfterIntegration = $true
    ExactPostArtifactMiningTestOnly = $true
    ExactArtifactExcludesLegacyVisorSource = $true
    InstallDefaultSafe = $true
    RollbackDefaultSafe = $true
    CaptureDefaultSafe = $true
    RuntimeIdentityReceiptBound = $true
    ManualMiningAcceptance = 'PENDING_USER_OBSERVATION'
    StablePromotionAllowed = $false
}
