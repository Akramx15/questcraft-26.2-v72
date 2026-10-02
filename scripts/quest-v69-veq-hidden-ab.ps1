<#
.SYNOPSIS
Screens corrected VEQ Frame Snapshot against accepted VEQ on Lab only.

.DESCRIPTION
The counterbalanced protocol is A1 -> B1 -> B2 -> A2 -> A3 -> B3 (AB/BA/AB).
A is accepted VEQ 0.7.0 and B is the corrected ee3f6144 Frame Snapshot JAR.
Every round uses quest-veq-lab.ps1, the fixed benchmark-world reset, autoplay,
at least five minutes of warm-up, and one aggregate-only 60-second PID-owned
VrApi sample. The exact v68 Vivecraft core, all non-VEQ mods, the full config
tree fingerprint, and absence of pending core/mod markers must stay fixed.
The VEQ one-shot transaction is checked separately: absent for baseline rounds,
and consumed with one unchanged run id for candidate rounds.

Run is disabled unless -AllowDeviceWrite is explicit. SelfTest, Plan, and
Aggregate never resolve or invoke ADB. This hidden-Wrist series is screening
only: no telemetry proves Wrist stayed hidden, so a supervised visibility
proof is required before any final acceptance. Stable cannot be selected.

.EXAMPLE
.\scripts\quest-v69-veq-hidden-ab.ps1 -Action SelfTest

.EXAMPLE
pwsh -NoProfile -File .\scripts\quest-v69-veq-hidden-ab.ps1 -Action SelfTest

.EXAMPLE
powershell.exe -NoProfile -File .\scripts\quest-v69-veq-hidden-ab.ps1 -Action SelfTest

.EXAMPLE
.\scripts\quest-v69-veq-hidden-ab.ps1 -Action Plan `
  -CandidateJar ..\..\exports\v69-host-canaries-20260902\VivecraftEssentialsQuest-v69-frame-snapshot-ee3f6144.jar `
  -CandidateSha256 2AB6B70242CBB45B77FECEC81B3D7CCA9A45AD82C59EF28F12FDFB0070FF7C36

.EXAMPLE
.\scripts\quest-v69-veq-hidden-ab.ps1 -Action Run -AllowDeviceWrite `
  -Serial 192.0.2.2:5555 -AdbPath C:\Android\platform-tools\adb.exe `
  -CandidateJar C:\canaries\VivecraftEssentialsQuest-frame-snapshot.jar `
  -CandidateSha256 2AB6B70242CBB45B77FECEC81B3D7CCA9A45AD82C59EF28F12FDFB0070FF7C36
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Plan', 'Run', 'Aggregate')]
    [string] $Action = 'Plan',

    [string] $CandidateJar,

    [ValidatePattern('^$|^[0-9a-fA-F]{64}$')]
    [string] $CandidateSha256 = '',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [string] $OutputDirectory = '',

    [ValidateRange(300, 900)]
    [int] $WarmupSeconds = 300,

    [ValidateRange(1, 3)]
    [int] $MaximumPairAttempts = 3,

    [ValidateRange(0, 600)]
    [int] $InterRoundCooldownSeconds = 60,

    [ValidateRange(0.0, 5.0)]
    [double] $MaximumStartTemperatureDeltaC = 1.0,

    [ValidateRange(0.0, 50.0)]
    [double] $MaximumRefreshDistributionDistancePercent = 5.0,

    [ValidateRange(0.0, 5.0)]
    [double] $MaximumRefreshMeanDeltaHz = 0.5,

    [ValidateRange(0.0, 1.0)]
    [double] $MaximumGuardrailRegressionPercent = 1.0,

    [switch] $Resume,

    [switch] $AllowDeviceWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.canary262'
$script:Profile = '26.2'
$script:World = 'FPS-Stress-Test'
$script:WorldMasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$script:ExpectedCoreSha256 = '3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F'
$script:ExpectedBaselineVeqSha256 = '6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9'
$script:ExpectedCandidateVeqSha256 = '2AB6B70242CBB45B77FECEC81B3D7CCA9A45AD82C59EF28F12FDFB0070FF7C36'
$script:ExpectedRejectedVeqSha256 = '35B71C9C432B42AF067D65BEEB1E966C2242181D085449C411B230F568800095'
$script:ExpectedVeqHarnessId = 'questcraft-veq-frame-snapshot-canary-v1'
$script:ExpectedCpuLevel = 4
$script:ExpectedGpuLevel = 4
$script:PreflightSeconds = 10
$script:SampleSeconds = 60
$script:MinimumSampleCoveragePercent = 95.0
$script:MinimumPerformanceLevelPercent = 95.0
$script:MaximumThermalPathDeltaC = 1.0
$script:MaximumRefreshTransitionDelta = 1
$script:P95PairSignalFloorPercent = 0.5
$script:StalePairSignalFloorPercent = 2.0
$script:ScreeningP95ImprovementPercent = 3.0
$script:ScreeningStaleImprovementPercent = 10.0
$script:RequiredSignalPairWins = 2
$script:ReadyTimeoutSeconds = 240
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:BenchmarkScript = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$script:ResetScript = Join-Path $PSScriptRoot 'reset-lab-benchmark-world.ps1'
$script:VeqScript = Join-Path $PSScriptRoot 'quest-veq-lab.ps1'
$script:AutoplayScript = Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'
$script:ApkVerifier = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$script:LabBuilder = Join-Path $script:RepoRoot `
        'QCXR-XR-Wrapper\Assets\Editor\QuestCraftLabCliBuild.cs'
$script:BaselineVeqSha256 = $null
$script:BaselineVeqPath = $null
$script:ExpectedConfigFingerprintSha256 = $null
$script:ExpectedOtherModsFingerprintSha256 = $null
$script:ExpectedLabVersionCode = $null
$script:ExpectedLabVersionName = $null
$script:ExpectedLabLabel = $null
$script:ExpectedLabSignerSha256 = $null
$script:ExpectedVivecraftSha256 = $null
$script:ExpectedLwjglSha256 = $null
$script:LabApkIdentity = $null
$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:DeviceInvocationCount = 0
$script:PowerShellExecutable = $null
$script:RunLockStream = $null

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Normalize-Sha256([Parameter(Mandatory)][string] $Value) {
    $normalized = $Value.ToUpperInvariant()
    Require ($normalized -match '^[0-9A-F]{64}$') 'Invalid SHA-256.'
    return $normalized
}

function Round-Value($Value, [int] $Digits = 2) {
    if ($null -eq $Value) { return $null }
    return [Math]::Round([double]$Value, $Digits)
}

function Get-CSharpStringConstant {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Name
    )
    $pattern = 'public\s+const\s+string\s+' + [regex]::Escape($Name) +
            '\s*=\s*"(?<value>[^"\r\n]+)"\s*;'
    $matches = [regex]::Matches($Source, $pattern)
    Require ($matches.Count -eq 1) "Lab builder constant '$Name' is missing or ambiguous."
    return $matches[0].Groups['value'].Value
}

function Assert-LabApkIdentityContract {
    param(
        [Parameter(Mandatory)] $Identity,
        $ExpectedIdentity = $null
    )
    Require ([string]$Identity.Package -ceq $script:Package) `
            'Lab APK identity package mismatch.'
    Require ([string]$Identity.VersionCode -ceq $script:ExpectedLabVersionCode) `
            'Lab APK identity versionCode mismatch.'
    Require ([string]$Identity.VersionName -ceq $script:ExpectedLabVersionName) `
            'Lab APK identity versionName mismatch.'
    Require ((Normalize-Sha256 ([string]$Identity.BaseApkSha256)) -ceq
            [string]$Identity.BaseApkSha256) `
            'Lab APK identity SHA-256 is not canonical.'
    Require ([int64]$Identity.BaseApkSizeBytes -gt 0) `
            'Lab APK identity size is invalid.'
    Require ((Normalize-Sha256 ([string]$Identity.SignerSha256)) -ceq
            $script:ExpectedLabSignerSha256 -and
            [string]$Identity.SignerSha256 -ceq $script:ExpectedLabSignerSha256) `
            'Lab APK signer mismatch or non-canonical signer digest.'
    Require ([string]$Identity.Verification -ceq 'full-host-apk-verifier') `
            'Lab APK identity lacks full Host verification provenance.'
    if ($null -ne $ExpectedIdentity) {
        Require ([string]$Identity.Package -ceq [string]$ExpectedIdentity.Package -and
                [string]$Identity.VersionCode -ceq [string]$ExpectedIdentity.VersionCode -and
                [string]$Identity.VersionName -ceq [string]$ExpectedIdentity.VersionName -and
                [string]$Identity.BaseApkSha256 -ceq [string]$ExpectedIdentity.BaseApkSha256 -and
                [int64]$Identity.BaseApkSizeBytes -eq [int64]$ExpectedIdentity.BaseApkSizeBytes -and
                [string]$Identity.SignerSha256 -ceq [string]$ExpectedIdentity.SignerSha256 -and
                [string]$Identity.Verification -ceq [string]$ExpectedIdentity.Verification) `
                'Lab APK identity changed within the A/B protocol.'
    }
}

function Copy-LabApkIdentity([Parameter(Mandatory)] $Identity) {
    Assert-LabApkIdentityContract $Identity
    return [pscustomobject]@{
        Package = [string]$Identity.Package
        VersionCode = [string]$Identity.VersionCode
        VersionName = [string]$Identity.VersionName
        BaseApkSha256 = [string]$Identity.BaseApkSha256
        BaseApkSizeBytes = [int64]$Identity.BaseApkSizeBytes
        SignerSha256 = [string]$Identity.SignerSha256
        Verification = [string]$Identity.Verification
    }
}

function Get-CurrentPowerShellExecutable {
    $name = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $candidate = Join-Path $PSHOME $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    throw 'Could not resolve the current PowerShell host.'
}

function Resolve-HostContract {
    Require ($MaximumStartTemperatureDeltaC -le 1.0) `
            'VEQ screening cannot weaken the one-degree start-temperature gate.'
    Require ($MaximumRefreshDistributionDistancePercent -le 5.0) `
            'VEQ screening cannot weaken the refresh-distribution gate.'
    Require ($MaximumRefreshMeanDeltaHz -le 0.5) `
            'VEQ screening cannot weaken the refresh-mean gate.'
    Require ($MaximumGuardrailRegressionPercent -le 1.0) `
            'VEQ screening cannot weaken the FPS/P10 guardrail.'
    foreach ($path in @($script:BenchmarkScript, $script:ResetScript, $script:VeqScript,
            $script:AutoplayScript, $script:ApkVerifier, $script:LabBuilder)) {
        Require (Test-Path -LiteralPath $path -PathType Leaf) "Required helper is missing: $path"
    }

    $stackLock = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'STACK.lock.json') |
            ConvertFrom-Json
    Require ([int64]$stackLock.identity.versionCode -eq 68) `
            'STACK.lock.json is not the accepted v68 baseline.'
    $coreRelative = [string]$stackLock.bundledArtifacts.vivecraft.path
    Require ($coreRelative -ceq 'Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin') `
            'The accepted Vivecraft asset path changed.'
    $corePath = Join-Path $script:RepoRoot $coreRelative
    Require (Test-Path -LiteralPath $corePath -PathType Leaf) `
            'The exact v68 Vivecraft core asset is missing.'
    $script:ExpectedVivecraftSha256 = Normalize-Sha256 ([string]$stackLock.bundledArtifacts.vivecraft.sha256)
    Require ($script:ExpectedVivecraftSha256 -ceq $script:ExpectedCoreSha256) `
            'STACK.lock.json is not pinned to the exact accepted v68 core.'
    Require ((Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash.ToUpperInvariant() -ceq
            $script:ExpectedCoreSha256) 'The accepted v68 core asset hash changed.'
    $script:ExpectedLwjglSha256 = Normalize-Sha256 ([string]$stackLock.bundledArtifacts.lwjgl.sha256)
    $script:ExpectedLabSignerSha256 = Normalize-Sha256 ([string]$stackLock.identity.expectedSignerSha256)

    $veqLock = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'VEQ_LAB_CANARY.lock.json') | ConvertFrom-Json
    Require ([int]$veqLock.schemaVersion -eq 1) 'VEQ Lab lock schema changed.'
    Require ([string]$veqLock.harness.package -ceq $script:Package -and
            [string]$veqLock.harness.profile -ceq $script:Profile) `
            'VEQ Lab lock escaped the fixed Lab package/profile.'
    Require ([string]$veqLock.harness.target -ceq
            'mods/Vivecraft-Essentials-Quest.jar') `
            'VEQ Lab target changed.'
    Require ([string]$veqLock.baseline.sha256 -ceq $script:ExpectedBaselineVeqSha256) `
            'VEQ Lab lock baseline hash changed.'
    Require (@($veqLock.allowedCandidates).Count -eq 1 -and
            [string]$veqLock.allowedCandidates[0].sourceCommit -ceq
            'ee3f61449a6cb1730b45b4956921a090e3120dfd' -and
            [string]$veqLock.allowedCandidates[0].sha256 -ceq
            $script:ExpectedCandidateVeqSha256) `
            'VEQ Lab lock is not pinned to the corrected ee3f6144 candidate.'
    Require (@($veqLock.rejectedCandidates).Count -eq 1 -and
            [string]$veqLock.rejectedCandidates[0].sha256 -ceq
            $script:ExpectedRejectedVeqSha256) `
            'VEQ Lab lock no longer blacklists the superseded candidate.'
    $script:BaselineVeqPath = Join-Path $script:RepoRoot ([string]$veqLock.baseline.assetPath)
    Require (Test-Path -LiteralPath $script:BaselineVeqPath -PathType Leaf) `
            'The accepted VEQ baseline asset is missing.'
    $script:BaselineVeqSha256 = Normalize-Sha256 ([string]$veqLock.baseline.sha256)
    Require ((Get-FileHash -LiteralPath $script:BaselineVeqPath -Algorithm SHA256).Hash.ToUpperInvariant() -ceq
            $script:BaselineVeqSha256) 'The accepted VEQ baseline asset hash changed.'

    $resetSource = Get-Content -Raw -LiteralPath $script:ResetScript
    $veqSource = Get-Content -Raw -LiteralPath $script:VeqScript
    $autoplaySource = Get-Content -Raw -LiteralPath $script:AutoplayScript
    $benchmarkSource = Get-Content -Raw -LiteralPath $script:BenchmarkScript
    $labBuilderSource = Get-Content -Raw -LiteralPath $script:LabBuilder
    Require ((Get-CSharpStringConstant $labBuilderSource 'ApplicationIdentifier') -ceq
            $script:Package) 'Lab builder package identity drifted.'
    $script:ExpectedLabVersionCode = Get-CSharpStringConstant $labBuilderSource 'VersionCode'
    Require ($script:ExpectedLabVersionCode -ceq '69') 'Lab builder versionCode is not 69.'
    $script:ExpectedLabVersionName = Get-CSharpStringConstant $labBuilderSource 'VersionName'
    Require ($script:ExpectedLabVersionName -match
            '^6\.0\.1-26\.2-vivecraft-[a-z0-9.-]+$') `
            'Lab builder versionName is outside the fixed v69 namespace.'
    $script:ExpectedLabLabel = Get-CSharpStringConstant $labBuilderSource 'ProductName'
    Require ($script:ExpectedLabLabel -ceq 'QuestCraft Vivecraft Lab 26.2') `
            'Lab builder product label drifted.'
    Require ($resetSource.Contains('$script:Package = ''com.qcxr.qcxr.canary262''')) `
            'Benchmark-world reset is not pinned to the Lab package.'
    Require ($veqSource.Contains('$script:Package = ''com.qcxr.qcxr.canary262''')) `
            'VEQ helper is not pinned to the Lab package.'
    $expectedStableBinding = '$script:ForbiddenPackage = ''com.qcxr.qcxr.' + 'dev262'''
    Require ($veqSource.Contains($expectedStableBinding)) `
            'VEQ helper lost its Stable-package denylist.'
    Require ($autoplaySource.Contains('$package = ''com.qcxr.qcxr.canary262''')) `
            'Autoplay helper is not pinned to the Lab package.'
    Require ($benchmarkSource.Contains('[string]$Package')) `
            'VrApi benchmark no longer accepts an explicit package.'
    Require ($benchmarkSource.Contains('FirstTempC') -and
            $benchmarkSource.Contains('LastTempC') -and
            $benchmarkSource.Contains('MeanStaleAtStableRefresh')) `
            'VrApi benchmark lacks the required aggregate quality metrics.'
}

function Get-CandidateContract {
    Require (-not [string]::IsNullOrWhiteSpace($CandidateJar)) `
            '-CandidateJar is required for Plan or Run.'
    Require (-not [string]::IsNullOrWhiteSpace($CandidateSha256)) `
            '-CandidateSha256 is required for Plan or Run.'
    $path = (Resolve-Path -LiteralPath $CandidateJar).Path
    $item = Get-Item -LiteralPath $path
    Require (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
            'Candidate must not be a symlink or reparse point.'
    Require ($item.Length -gt 0 -and $item.Length -le 2MB) `
            'Candidate size is outside the 2 MiB VEQ canary limit.'
    $expected = Normalize-Sha256 $CandidateSha256
    Require ($expected -ceq $script:ExpectedCandidateVeqSha256) `
            'Candidate is not the exact corrected ee3f6144 VEQ JAR.'
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($actual -ceq $expected) 'Candidate JAR does not match -CandidateSha256.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'fabric.mod.json' })
        Require ($entries.Count -eq 1) 'Candidate must have exactly one root fabric.mod.json.'
        $reader = [IO.StreamReader]::new($entries[0].Open(),
                [Text.UTF8Encoding]::new($false, $true))
        try { $fabric = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        Require ([string]$fabric.id -ceq 'vivecraft_essentials_quest') `
                'Candidate Fabric id is not vivecraft_essentials_quest.'
        Require ([string]$fabric.version -ceq '0.7.0-v69-frame-snapshot.2') `
                'Candidate Fabric version is not the corrected snapshot build.'
        $minecraft = @($fabric.depends.minecraft)
        $java = @($fabric.depends.java)
        Require ($minecraft.Count -eq 1 -and [string]$minecraft[0] -ceq '26.2') `
                'Candidate Minecraft dependency is not exactly 26.2.'
        Require ($java.Count -eq 1 -and [string]$java[0] -ceq '>=25') `
                'Candidate Java dependency is not exactly >=25.'
        return [pscustomobject]@{
            Path = $path
            Sha256 = $actual
            SizeBytes = [int64]$item.Length
            FabricVersion = [string]$fabric.version
            SourceCommit = 'ee3f61449a6cb1730b45b4956921a090e3120dfd'
        }
    } finally {
        $archive.Dispose()
    }
}

function Save-JsonAtomic {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)][string] $Path,
        [switch] $Replace
    )
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    if ((Test-Path -LiteralPath $full) -and -not $Replace) {
        throw "Refusing to overwrite JSON: $full"
    }
    $temporary = "$full.tmp-$([guid]::NewGuid().ToString('N'))"
    $backup = "$full.replace-backup-$([guid]::NewGuid().ToString('N'))"
    try {
        $json = ($Value | ConvertTo-Json -Depth 12) + "`n"
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $full) {
            [IO.File]::Replace($temporary, $full, $backup, $true)
            if (Test-Path -LiteralPath $backup) { [IO.File]::Delete($backup) }
        } else {
            [IO.File]::Move($temporary, $full)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
        if (Test-Path -LiteralPath $backup) { [IO.File]::Delete($backup) }
    }
    return $full
}

function Get-Json([Parameter(Mandatory)][string] $Path) {
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Resolve-OutputDirectory([string] $Requested, [switch] $GenerateDefault) {
    $artifactRoot = [IO.Path]::GetFullPath((Join-Path $script:WorkspaceRoot 'artifacts\benchmarks'))
    $path = if ([string]::IsNullOrWhiteSpace($Requested)) {
        Require $GenerateDefault '-OutputDirectory is required for this action.'
        Join-Path $artifactRoot ('v69-veq-hidden-screening-' +
                [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    } else { [IO.Path]::GetFullPath($Requested) }
    $full = [IO.Path]::GetFullPath($path)
    $prefix = $artifactRoot.TrimEnd('\') + '\'
    Require ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) `
            'Aggregate output must stay below the workspace artifacts\benchmarks directory.'
    return $full
}

function Get-RefreshDistributionMap([Parameter(Mandatory)] $Report) {
    $map = @{}
    foreach ($bucket in @($Report.Aggregate.DisplayRefreshDistribution)) {
        $key = ([double]$bucket.Hz).ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
        $map[$key] = [double]$bucket.Percent
    }
    return $map
}

function Compare-RefreshDistribution {
    param([Parameter(Mandatory)] $A, [Parameter(Mandatory)] $B)
    $left = Get-RefreshDistributionMap $A
    $right = Get-RefreshDistributionMap $B
    $keys = @($left.Keys + $right.Keys | Sort-Object -Unique)
    $distance = 0.0
    foreach ($key in $keys) {
        $aValue = if ($left.ContainsKey($key)) { [double]$left[$key] } else { 0.0 }
        $bValue = if ($right.ContainsKey($key)) { [double]$right[$key] } else { 0.0 }
        $distance += [Math]::Abs($aValue - $bValue)
    }
    $distance *= 0.5
    $meanDelta = [Math]::Abs([double]$A.Aggregate.MeanDisplayRefreshHz -
            [double]$B.Aggregate.MeanDisplayRefreshHz)
    $modeDelta = [Math]::Abs([double]$A.Aggregate.DisplayRefreshModeHz -
            [double]$B.Aggregate.DisplayRefreshModeHz)
    $transitionDelta = [Math]::Abs([int]$A.Aggregate.RefreshTransitionCount -
            [int]$B.Aggregate.RefreshTransitionCount)
    return [pscustomobject]@{
        TotalVariationPercent = Round-Value $distance 2
        MeanDeltaHz = Round-Value $meanDelta 2
        ModeDeltaHz = Round-Value $modeDelta 2
        TransitionCountA = [int]$A.Aggregate.RefreshTransitionCount
        TransitionCountB = [int]$B.Aggregate.RefreshTransitionCount
        TransitionCountDelta = $transitionDelta
        Matched = $distance -le $MaximumRefreshDistributionDistancePercent -and
                $meanDelta -le $MaximumRefreshMeanDeltaHz -and $modeDelta -le 0.5 -and
                $transitionDelta -le $script:MaximumRefreshTransitionDelta
    }
}

function Get-LowerIsBetterImprovementPercent($Baseline, $Candidate) {
    if ($null -eq $Baseline -or $null -eq $Candidate) { return $null }
    $a = [double]$Baseline
    $b = [double]$Candidate
    if ($a -eq 0.0) {
        if ($b -eq 0.0) { return 0.0 }
        return -100.0
    }
    return 100.0 * ($a - $b) / $a
}

function Get-HigherIsBetterChangePercent($Baseline, $Candidate) {
    if ($null -eq $Baseline -or $null -eq $Candidate) { return $null }
    $a = [double]$Baseline
    $b = [double]$Candidate
    if ($a -eq 0.0) {
        if ($b -eq 0.0) { return 0.0 }
        return 100.0
    }
    return 100.0 * ($b - $a) / $a
}

function Get-MeanMetric([object[]] $Reports, [string] $Name) {
    $values = @($Reports | ForEach-Object { $_.Aggregate.$Name } |
            Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    Require ($values.Count -eq $Reports.Count) "Metric '$Name' is absent from a retained report."
    return [double](($values | Measure-Object -Average).Average)
}

function Assert-RetainedReport {
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)][string] $Condition,
        [Parameter(Mandatory)][int] $Pair,
        [Parameter(Mandatory)][string] $ExpectedVeqSha256,
        [Parameter(Mandatory)] $ExpectedLabApkIdentity
    )
    Require ([string]$Report.Package -ceq $script:Package) `
            'A retained report is not from the Lab package.'
    Require ([bool]$Report.ValidForComparison) `
            'A retained report failed its PID/focus/sample gates.'
    Require (-not [bool]$Report.RawLogsPersisted) `
            'A retained report claims raw logs were persisted.'
    Require ($null -ne $Report.Protocol) 'A retained report has no v69 protocol metadata.'
    Require ([int]$Report.Protocol.SchemaVersion -eq 4 -and
            [string]$Report.Protocol.Series -ceq 'VEQ_HIDDEN_SCREENING' -and
            [bool]$Report.Protocol.ScreeningOnly -and
            -not [bool]$Report.Protocol.HiddenStateTelemetryAvailable -and
            -not [bool]$Report.Protocol.WristHiddenProven -and
            -not [bool]$Report.Protocol.FinalAcceptanceEligible) `
            'Retained report is not from the VEQ hidden screening protocol.'
    Require ([string]$Report.Protocol.Condition -ceq $Condition) `
            'Retained report condition mismatch.'
    Require ([int]$Report.Protocol.Pair -eq $Pair) 'Retained report pair mismatch.'
    Require ([int]$Report.Protocol.Attempt -ge 1 -and
            [int]$Report.Protocol.Attempt -le $MaximumPairAttempts) `
            'Retained report attempt is outside the bounded protocol.'
    Require ((Normalize-Sha256 ([string]$Report.Protocol.CoreSha256)) -ceq
            $script:ExpectedCoreSha256) `
            'Retained report is not using the exact accepted v68 core.'
    Require ((Normalize-Sha256 ([string]$Report.Protocol.VeqSha256)) -ceq
            $ExpectedVeqSha256) 'Retained report VEQ hash mismatch.'
    Require ([bool]$Report.Protocol.NoPendingCoreMarker -and
            [bool]$Report.Protocol.NoPendingModsMarker) `
            'Retained report had a pending core/mod canary transaction marker.'
    Require ([bool]$Report.Protocol.VeqTransactionPolicySatisfied) `
            'Retained report did not satisfy its VEQ transaction contract.'
    $expectedMarkerState = if ($Condition -ceq 'A') { 'absent' } else { 'consumed' }
    Require ([string]$Report.Protocol.VeqMarkerState -ceq $expectedMarkerState) `
            'Retained report VEQ marker state does not match its condition.'
    if ($Condition -ceq 'A') {
        Require ([string]::IsNullOrWhiteSpace([string]$Report.Protocol.VeqRunId)) `
                'Baseline report retained a VEQ transaction run id.'
    } else {
        Require ([string]$Report.Protocol.VeqRunId -cmatch '^[0-9a-f]{32}$') `
                'Candidate report lacks a strict consumed VEQ transaction run id.'
    }
    Assert-LabApkIdentityContract $Report.Protocol.LabApk $ExpectedLabApkIdentity
    Require ([string]$Report.Protocol.WorldMasterSha256 -ceq $script:WorldMasterSha256) `
            'Retained report world-master mismatch.'
    Require ([bool]$Report.Protocol.WorldResetBeforeLaunch -and
            [bool]$Report.Protocol.ColdLaunch -and
            [int]$Report.Protocol.WarmupSeconds -eq $WarmupSeconds -and
            [int]$Report.Protocol.PreflightSeconds -eq $script:PreflightSeconds) `
            'Retained report did not use the fixed cold-launch benchmark protocol.'
    Require (-not [string]::IsNullOrWhiteSpace([string]$Report.Protocol.CapturedAtUtc)) `
            'Retained report has no capture timestamp.'
    Require ((Normalize-Sha256 ([string]$Report.Protocol.OtherModsFingerprintSha256)) -ceq
            $script:ExpectedOtherModsFingerprintSha256) `
            'Retained report has a changed non-VEQ mod fingerprint.'
    Require ((Normalize-Sha256 ([string]$Report.Protocol.ConfigFingerprintSha256)) -ceq
            $script:ExpectedConfigFingerprintSha256) `
            'Retained report has a changed config-tree fingerprint.'
    Require ($null -ne $Report.Protocol.StartTemperatureC) `
            'Retained report has no sample-start temperature.'
    Require ([int]$Report.Aggregate.CpuLevelMode -eq $script:ExpectedCpuLevel -and
            [int]$Report.Aggregate.GpuLevelMode -eq $script:ExpectedGpuLevel) `
            'Retained report is not QGO CPU/GPU 4/4.'
    Require ([double]$Report.SampleCoveragePercent -ge $script:MinimumSampleCoveragePercent) `
            'Retained report has insufficient VrApi sample coverage.'
    Require ([double]$Report.Aggregate.CpuLevel4Percent -ge
            $script:MinimumPerformanceLevelPercent -and
            [double]$Report.Aggregate.GpuLevel4Percent -ge
            $script:MinimumPerformanceLevelPercent) `
            'Retained report did not hold CPU/GPU level 4 for at least 95 percent of samples.'
    Require ($null -ne $Report.Aggregate.MeanDisplayRefreshHz -and
            $null -ne $Report.Aggregate.DisplayRefreshModeHz -and
            @($Report.Aggregate.DisplayRefreshDistribution).Count -gt 0) `
            'Retained report has no actual-refresh distribution.'
    foreach ($metric in @('MeanAppFps', 'P10AppFps', 'MeanStalePerSecond',
            'MeanStaleAtStableRefresh', 'P95CpuAndGpuMs', 'RefreshTransitionCount',
            'FirstTempC', 'MeanTempC', 'LastTempC', 'MaxTempC')) {
        Require ($null -ne $Report.Aggregate.$metric) "Required metric '$metric' is absent."
    }
}

function Compare-Pair {
    param([Parameter(Mandatory)] $A, [Parameter(Mandatory)] $B)
    $refresh = Compare-RefreshDistribution $A $B
    $aTemp = [double]$A.Protocol.StartTemperatureC
    $bTemp = [double]$B.Protocol.StartTemperatureC
    $temperatureDelta = [Math]::Abs($aTemp - $bTemp)
    $thermalPathDeltas = [ordered]@{}
    $thermalPathRawDeltas = [Collections.Generic.List[double]]::new()
    foreach ($metric in @('FirstTempC', 'MeanTempC', 'LastTempC', 'MaxTempC')) {
        $rawDelta = [Math]::Abs(
                [double]$A.Aggregate.$metric - [double]$B.Aggregate.$metric)
        $thermalPathRawDeltas.Add($rawDelta)
        $thermalPathDeltas[$metric] = Round-Value $rawDelta 1
    }
    $maximumThermalPathDelta = [double](($thermalPathRawDeltas |
            Measure-Object -Maximum).Maximum)
    $reasons = [Collections.Generic.List[string]]::new()
    if (-not $refresh.Matched) {
        $reasons.Add('Actual dynamic-refresh distributions did not match.')
    }
    if ($temperatureDelta -gt $MaximumStartTemperatureDeltaC) {
        $reasons.Add('Sample-start temperatures differed by more than the protocol limit.')
    }
    if ($maximumThermalPathDelta -gt $script:MaximumThermalPathDeltaC) {
        $reasons.Add('The in-sample thermal paths differed by more than the protocol limit.')
    }
    if ([int]$A.Protocol.Attempt -ne [int]$B.Protocol.Attempt) {
        $reasons.Add('The pair combined reports from different bounded attempts.')
    }
    if ([string]$A.Protocol.CoreSha256 -cne [string]$B.Protocol.CoreSha256) {
        $reasons.Add('The exact v68 core changed inside the pair.')
    }
    if ([string]$A.Protocol.OtherModsFingerprintSha256 -cne
            [string]$B.Protocol.OtherModsFingerprintSha256) {
        $reasons.Add('The non-VEQ mod fingerprint changed inside the pair.')
    }
    if ([string]$A.Protocol.ConfigFingerprintSha256 -cne
            [string]$B.Protocol.ConfigFingerprintSha256) {
        $reasons.Add('The config-tree fingerprint changed inside the pair.')
    }
    return [pscustomobject]@{
        Comparable = $reasons.Count -eq 0
        InvalidReasons = $reasons.ToArray()
        StartTemperatureDeltaC = Round-Value $temperatureDelta 1
        ThermalPathDeltaC = [pscustomobject]$thermalPathDeltas
        MaximumThermalPathDeltaC = Round-Value $maximumThermalPathDelta 1
        Refresh = $refresh
        P95CpuAndGpuImprovementPercent = (Get-LowerIsBetterImprovementPercent $A.Aggregate.P95CpuAndGpuMs $B.Aggregate.P95CpuAndGpuMs)
        StaleImprovementPercent = (Get-LowerIsBetterImprovementPercent $A.Aggregate.MeanStaleAtStableRefresh $B.Aggregate.MeanStaleAtStableRefresh)
        OverallStaleImprovementPercent = (Get-LowerIsBetterImprovementPercent $A.Aggregate.MeanStalePerSecond $B.Aggregate.MeanStalePerSecond)
        MeanFpsChangePercent = (Get-HigherIsBetterChangePercent $A.Aggregate.MeanAppFps $B.Aggregate.MeanAppFps)
        P10ChangePercent = (Get-HigherIsBetterChangePercent $A.Aggregate.P10AppFps $B.Aggregate.P10AppFps)
    }
}

function Get-AbDecision {
    param(
        [Parameter(Mandatory)][object[]] $AReports,
        [Parameter(Mandatory)][object[]] $BReports,
        [Parameter(Mandatory)][string] $ExpectedBaselineVeqSha256,
        [Parameter(Mandatory)][string] $ExpectedCandidateVeqSha256,
        [Parameter(Mandatory)] $ExpectedLabApkIdentity
    )
    Require ($AReports.Count -eq 3 -and $BReports.Count -eq 3) `
            'Exactly three A and three B reports are required.'
    Require ((Normalize-Sha256 $ExpectedBaselineVeqSha256) -ceq
            $script:BaselineVeqSha256) `
            'Decision baseline is not the exact accepted VEQ.'
    Require ((Normalize-Sha256 $ExpectedCandidateVeqSha256) -ceq
            $script:ExpectedCandidateVeqSha256) `
            'Decision candidate is not the corrected ee3f6144 VEQ.'

    $coreHashes = @($AReports + $BReports | ForEach-Object {
            [string]$_.Protocol.CoreSha256
        } | Sort-Object -Unique)
    Require ($coreHashes.Count -eq 1 -and
            (Normalize-Sha256 $coreHashes[0]) -ceq $script:ExpectedCoreSha256) `
            'The exact accepted v68 core did not remain fixed.'
    $fingerprints = @($AReports + $BReports | ForEach-Object {
            [string]$_.Protocol.OtherModsFingerprintSha256
        } | Sort-Object -Unique)
    Require ($fingerprints.Count -eq 1 -and
            (Normalize-Sha256 $fingerprints[0]) -ceq
            $script:ExpectedOtherModsFingerprintSha256) `
            'The one-variable non-VEQ mod fingerprint changed.'
    $configFingerprints = @($AReports + $BReports | ForEach-Object {
            [string]$_.Protocol.ConfigFingerprintSha256
        } | Sort-Object -Unique)
    Require ($configFingerprints.Count -eq 1 -and
            (Normalize-Sha256 $configFingerprints[0]) -ceq
            $script:ExpectedConfigFingerprintSha256) `
            'The config-tree fingerprint changed across retained reports.'

    $pairs = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 3; $index++) {
        $pairNumber = $index + 1
        Assert-RetainedReport -Report $AReports[$index] -Condition A -Pair $pairNumber -ExpectedVeqSha256 $ExpectedBaselineVeqSha256 -ExpectedLabApkIdentity $ExpectedLabApkIdentity
        Assert-RetainedReport -Report $BReports[$index] -Condition B -Pair $pairNumber -ExpectedVeqSha256 $ExpectedCandidateVeqSha256 -ExpectedLabApkIdentity $ExpectedLabApkIdentity
        $comparison = Compare-Pair $AReports[$index] $BReports[$index]
        $pairs.Add([pscustomobject]@{
            Pair = $pairNumber
            Comparable = $comparison.Comparable
            InvalidReasons = $comparison.InvalidReasons
            StartTemperatureDeltaC = $comparison.StartTemperatureDeltaC
            ThermalPathDeltaC = $comparison.ThermalPathDeltaC
            MaximumThermalPathDeltaC = $comparison.MaximumThermalPathDeltaC
            Refresh = $comparison.Refresh
            P95CpuAndGpuImprovementPercent =
                    $comparison.P95CpuAndGpuImprovementPercent
            StableRefreshStaleImprovementPercent = $comparison.StaleImprovementPercent
            OverallStaleImprovementPercent = $comparison.OverallStaleImprovementPercent
            MeanFpsChangePercent = $comparison.MeanFpsChangePercent
            P10ChangePercent = $comparison.P10ChangePercent
        })
    }

    $aP95 = Get-MeanMetric $AReports 'P95CpuAndGpuMs'
    $bP95 = Get-MeanMetric $BReports 'P95CpuAndGpuMs'
    $aStale = Get-MeanMetric $AReports 'MeanStaleAtStableRefresh'
    $bStale = Get-MeanMetric $BReports 'MeanStaleAtStableRefresh'
    $aOverallStale = Get-MeanMetric $AReports 'MeanStalePerSecond'
    $bOverallStale = Get-MeanMetric $BReports 'MeanStalePerSecond'
    $aMean = Get-MeanMetric $AReports 'MeanAppFps'
    $bMean = Get-MeanMetric $BReports 'MeanAppFps'
    $aP10 = Get-MeanMetric $AReports 'P10AppFps'
    $bP10 = Get-MeanMetric $BReports 'P10AppFps'

    $p95Improvement = Get-LowerIsBetterImprovementPercent $aP95 $bP95
    $staleImprovement = Get-LowerIsBetterImprovementPercent $aStale $bStale
    $meanChange = Get-HigherIsBetterChangePercent $aMean $bMean
    $p10Change = Get-HigherIsBetterChangePercent $aP10 $bP10
    $p95PairWins = @($pairs | Where-Object {
            $_.P95CpuAndGpuImprovementPercent -ge $script:P95PairSignalFloorPercent
        }).Count
    $stalePairWins = @($pairs | Where-Object {
            $_.StableRefreshStaleImprovementPercent -ge $script:StalePairSignalFloorPercent
        }).Count
    $allComparable = @($pairs | Where-Object { -not $_.Comparable }).Count -eq 0
    $aggregateGuardrailsPass =
            $meanChange -ge (-1.0 * $MaximumGuardrailRegressionPercent) -and
            $p10Change -ge (-1.0 * $MaximumGuardrailRegressionPercent)
    $everyPairGuardrailsPass = @($pairs | Where-Object {
            $_.MeanFpsChangePercent -lt (-1.0 * $MaximumGuardrailRegressionPercent) -or
            $_.P10ChangePercent -lt (-1.0 * $MaximumGuardrailRegressionPercent)
        }).Count -eq 0
    $guardrailsPass = $aggregateGuardrailsPass -and $everyPairGuardrailsPass
    $p95Signal = $p95Improvement -ge $script:ScreeningP95ImprovementPercent -and
            $p95PairWins -ge $script:RequiredSignalPairWins
    $staleSignal = $staleImprovement -ge $script:ScreeningStaleImprovementPercent -and
            $stalePairWins -ge $script:RequiredSignalPairWins
    $screeningPass = $allComparable -and $guardrailsPass -and
            ($p95Signal -or $staleSignal)

    $reasons = [Collections.Generic.List[string]]::new()
    if (-not $allComparable) {
        $reasons.Add('One or more retained A/B pairs are not comparable.')
    }
    if (-not $aggregateGuardrailsPass) {
        $reasons.Add('Aggregate mean FPS or P10 regressed beyond one percent.')
    }
    if (-not $everyPairGuardrailsPass) {
        $reasons.Add('At least one pair regressed mean FPS or P10 beyond one percent.')
    }
    if (-not ($p95Signal -or $staleSignal)) {
        $reasons.Add(
                'Neither P95 >=3% nor stable-refresh stale >=10% also won at least two pairs.')
    }

    return [pscustomobject]@{
        SchemaVersion = 4
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Package = $script:Package
        Profile = $script:Profile
        World = $script:World
        Order = 'A1-B1-B2-A2-A3-B3'
        ComparisonPurpose = 'veq-frame-snapshot-hidden-screening'
        ScreeningOnly = $true
        HiddenStateTelemetryAvailable = $false
        WristHiddenProven = $false
        FinalAcceptanceEligible = $false
        StableSelectable = $false
        RequiredFollowUp = 'Supervised Wrist-hidden visibility proof, then visible-Wrist functional/performance A/B.'
        BaselineVeqSha256 = $ExpectedBaselineVeqSha256
        CandidateVeqSha256 = $ExpectedCandidateVeqSha256
        FixedCoreSha256 = $script:ExpectedCoreSha256
        FixedOtherModsFingerprintSha256 = $script:ExpectedOtherModsFingerprintSha256
        FixedConfigFingerprintSha256 = $script:ExpectedConfigFingerprintSha256
        LabApk = Copy-LabApkIdentity $ExpectedLabApkIdentity
        PairComparisons = $pairs.ToArray()
        Aggregate = [pscustomobject]@{
            BaselineMeanFps = Round-Value $aMean 2
            CandidateMeanFps = Round-Value $bMean 2
            MeanFpsChangePercent = Round-Value $meanChange 2
            BaselineMeanP10Fps = Round-Value $aP10 2
            CandidateMeanP10Fps = Round-Value $bP10 2
            P10ChangePercent = Round-Value $p10Change 2
            BaselineStableRefreshStalePerSecond = Round-Value $aStale 2
            CandidateStableRefreshStalePerSecond = Round-Value $bStale 2
            StableRefreshStaleImprovementPercent = Round-Value $staleImprovement 2
            StableRefreshStalePairWins = $stalePairWins
            BaselineOverallStalePerSecond = Round-Value $aOverallStale 2
            CandidateOverallStalePerSecond = Round-Value $bOverallStale 2
            OverallStaleImprovementPercent = (Round-Value (Get-LowerIsBetterImprovementPercent $aOverallStale $bOverallStale) 2)
            BaselineP95CpuAndGpuMs = Round-Value $aP95 2
            CandidateP95CpuAndGpuMs = Round-Value $bP95 2
            P95CpuAndGpuImprovementPercent = Round-Value $p95Improvement 2
            P95CpuAndGpuPairWins = $p95PairWins
        }
        Gates = [pscustomobject]@{
            AllPairsComparable = $allComparable
            GuardrailsPass = $guardrailsPass
            AggregateGuardrailsPass = $aggregateGuardrailsPass
            EveryPairGuardrailsPass = $everyPairGuardrailsPass
            MaximumGuardrailRegressionPercent = $MaximumGuardrailRegressionPercent
            P95PairSignalFloorPercent = $script:P95PairSignalFloorPercent
            StableRefreshStalePairSignalFloorPercent = $script:StalePairSignalFloorPercent
            RequiredSignalPairWins = $script:RequiredSignalPairWins
            ScreeningP95ThresholdPercent = $script:ScreeningP95ImprovementPercent
            ScreeningStableRefreshStaleThresholdPercent =
                    $script:ScreeningStaleImprovementPercent
            MetricScreeningGatePass = $screeningPass
            FinalAcceptancePass = $false
            Decision = if ($screeningPass) {
                'SCREENING_PROMISING_REQUIRES_VISIBILITY_PROOF'
            } else {
                'SCREENING_REJECT_OR_REPEAT'
            }
            Reasons = $reasons.ToArray()
        }
        RawLogsPersisted = $false
    }
}

function New-SyntheticLabApkIdentity {
    return [pscustomobject]@{
        Package = $script:Package
        VersionCode = $script:ExpectedLabVersionCode
        VersionName = $script:ExpectedLabVersionName
        BaseApkSha256 = ('D' * 64)
        BaseApkSizeBytes = 123456789
        SignerSha256 = $script:ExpectedLabSignerSha256
        Verification = 'full-host-apk-verifier'
    }
}

function New-SyntheticVeqTransactionStatus {
    param(
        [Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition,
        [Parameter(Mandatory)][string] $VeqSha256
    )
    return [pscustomobject]@{
        Result = 'STATUS'
        Package = $script:Package
        Profile = $script:Profile
        HarnessId = $script:ExpectedVeqHarnessId
        Running = $true
        AccessMode = 'Normal'
        TargetSha256 = $VeqSha256
        BaselineExact = $Condition -ceq 'A'
        MarkerState = if ($Condition -ceq 'A') { 'absent' } else { 'consumed' }
        RunId = if ($Condition -ceq 'A') { $null } else {
            '0123456789abcdef0123456789abcdef'
        }
        OpenXrCopyBatchMode = 'OFF'
        ReadOnly = $true
    }
}

function New-SyntheticReport {
    param(
        [string] $Condition,
        [int] $Pair,
        [string] $VeqSha,
        [double] $MeanFps,
        [double] $P10,
        [double] $Stale,
        [double] $P95,
        [double] $Temp,
        [double] $Hz = 72.0
    )
    return [pscustomobject]@{
        Package = $script:Package
        ValidForComparison = $true
        RawLogsPersisted = $false
        SampleCoveragePercent = 100.0
        Aggregate = [pscustomobject]@{
            MeanAppFps = $MeanFps
            P10AppFps = $P10
            MeanStalePerSecond = $Stale
            MeanStaleAtStableRefresh = $Stale
            P95CpuAndGpuMs = $P95
            CpuLevelMode = 4
            GpuLevelMode = 4
            CpuLevel4Percent = 100.0
            GpuLevel4Percent = 100.0
            MeanDisplayRefreshHz = $Hz
            DisplayRefreshModeHz = $Hz
            DisplayRefreshDistribution =
                    @([pscustomobject]@{ Hz = $Hz; Count = 60; Percent = 100.0 })
            RefreshTransitionCount = 0
            FirstTempC = $Temp
            MeanTempC = $Temp
            LastTempC = $Temp
            MaxTempC = $Temp
        }
        Protocol = [pscustomobject]@{
            SchemaVersion = 4
            Series = 'VEQ_HIDDEN_SCREENING'
            ScreeningOnly = $true
            HiddenStateTelemetryAvailable = $false
            WristHiddenProven = $false
            FinalAcceptanceEligible = $false
            Condition = $Condition
            Pair = $Pair
            Attempt = 1
            CoreSha256 = $script:ExpectedCoreSha256
            VeqSha256 = $VeqSha
            NoPendingCoreMarker = $true
            NoPendingModsMarker = $true
            VeqMarkerState = if ($Condition -ceq 'A') { 'absent' } else { 'consumed' }
            VeqRunId = if ($Condition -ceq 'A') { $null } else {
                '0123456789abcdef0123456789abcdef'
            }
            VeqTransactionPolicySatisfied = $true
            LabApk = Copy-LabApkIdentity $script:LabApkIdentity
            OtherModsFingerprintSha256 = $script:ExpectedOtherModsFingerprintSha256
            ConfigFingerprintSha256 = $script:ExpectedConfigFingerprintSha256
            StartTemperatureC = $Temp
            WorldMasterSha256 = $script:WorldMasterSha256
            WorldResetBeforeLaunch = $true
            ColdLaunch = $true
            WarmupSeconds = $WarmupSeconds
            PreflightSeconds = $script:PreflightSeconds
            CapturedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
}

function Invoke-SelfTest {
    $before = $script:DeviceInvocationCount
    Resolve-HostContract
    $script:LabApkIdentity = New-SyntheticLabApkIdentity
    $script:ExpectedConfigFingerprintSha256 = ('A' * 64)
    $script:ExpectedOtherModsFingerprintSha256 = ('B' * 64)

    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $forbiddenStable = 'com.qcxr.qcxr.' + 'dev262'
    $forbiddenClear = 'pm' + ' clear'
    $forbiddenRemoval = 'unin' + 'stall'
    $forbiddenRoot = 'su ' + '-c'
    Require (-not $source.Contains($forbiddenStable)) `
            'The accepted Personal package appeared in the VEQ orchestrator.'
    Require (-not $source.Contains($forbiddenClear)) `
            'A data-clear command appeared in the orchestrator.'
    Require (-not $source.Contains($forbiddenRemoval)) `
            'A package-removal command appeared in the orchestrator.'
    Require (-not $source.Contains($forbiddenRoot)) `
            'A root command appeared in the orchestrator.'
    Require ($source.Contains('if ($Condition -ceq ''B'')')) `
            'Candidate deployment is not isolated to condition B.'
    Require ($source.Contains('Invoke-VeqDeploy $Candidate')) `
            'Condition B does not use quest-veq-lab deployment.'
    Require ($source.Contains('Invoke-VeqRollback')) `
            'The protocol has no explicit accepted-VEQ rollback.'
    Require ($source.Contains('$script:ExpectedCoreSha256')) `
            'The exact v68 core is not pinned.'
    Require ($source.Contains('NoPendingCoreMarker') -and
            $source.Contains('NoPendingModsMarker') -and
            $source.Contains('VeqTransactionPolicySatisfied') -and
            $source.Contains('Get-VeqTransactionStatus') -and
            $source.Contains('Assert-VeqTransactionContract')) `
            'Transaction markers are not checked by the split fail-closed contract.'
    Require ($source.Contains('ConfigFingerprintSha256') -and
            $source.Contains('options="$game/options.txt"')) `
            'The config/options fingerprint is not bound to evidence.'
    Require ($source.Contains('$conditionOrder = if ($Pair -eq 2) { @(''B'', ''A'') }')) `
            'A/B order is not counterbalanced AB/BA/AB.'
    Require ($source.Contains('HiddenStateTelemetryAvailable = $false') -and
            $source.Contains('FinalAcceptancePass = $false')) `
            'Hidden screening can be mislabeled as final acceptance.'

    $probeCommand = New-LabStackProbeCommand
    Require ($probeCommand.Contains('/sdcard/Android/data/com.qcxr.qcxr.canary262/files') -and
            -not $probeCommand.Contains($forbiddenStable)) `
            'The generated stack probe escaped the fixed Lab package.'
    foreach ($requiredProbeToken in @('Vivecraft.jar',
            'Vivecraft-Essentials-Quest.jar', 'options.txt',
            'questcraft-vivecraft-core-canary-v1/request.json',
            'questcraft-mods-ab-canary-v1/request.json')) {
        Require ($probeCommand.Contains($requiredProbeToken)) `
                "The generated stack probe is missing '$requiredProbeToken'."
    }
    Require (-not $probeCommand.Contains(
            'questcraft-veq-frame-snapshot-canary-v1/request.json')) `
            'The generic stack probe still rejects the legitimate consumed VEQ marker.'

    $baselineTransaction = New-SyntheticVeqTransactionStatus A $script:BaselineVeqSha256
    Assert-VeqTransactionContract $baselineTransaction A $script:BaselineVeqSha256
    $candidateTransaction = New-SyntheticVeqTransactionStatus B $script:ExpectedCandidateVeqSha256
    Assert-VeqTransactionContract $candidateTransaction B $script:ExpectedCandidateVeqSha256
    $wrongCandidateState = New-SyntheticVeqTransactionStatus B $script:ExpectedCandidateVeqSha256
    $wrongCandidateState.MarkerState = 'absent'
    $wrongCandidateRejected = $false
    try {
        Assert-VeqTransactionContract $wrongCandidateState B $script:ExpectedCandidateVeqSha256
    } catch { $wrongCandidateRejected = $true }
    Require $wrongCandidateRejected `
            'Condition B accepted an absent VEQ marker instead of consumed.'
    $wrongBaselineRun = New-SyntheticVeqTransactionStatus A $script:BaselineVeqSha256
    $wrongBaselineRun.RunId = '0123456789abcdef0123456789abcdef'
    $wrongBaselineRejected = $false
    try {
        Assert-VeqTransactionContract $wrongBaselineRun A $script:BaselineVeqSha256
    } catch { $wrongBaselineRejected = $true }
    Require $wrongBaselineRejected 'Condition A accepted a retained VEQ run id.'

    $apkGateIndex = $source.IndexOf(
            '$script:LabApkIdentity = Get-InstalledLabApkIdentity',
            [StringComparison]::Ordinal)
    $configGateIndex = $source.IndexOf(
            '$script:ExpectedConfigFingerprintSha256 =',
            $apkGateIndex, [StringComparison]::Ordinal)
    $manifestIndex = $source.IndexOf('$manifest = New-RunManifest',
            $configGateIndex, [StringComparison]::Ordinal)
    $roundIndex = $source.IndexOf('Invoke-Pair $pair', $manifestIndex,
            [StringComparison]::Ordinal)
    Require ($apkGateIndex -ge 0 -and $configGateIndex -gt $apkGateIndex -and
            $manifestIndex -gt $configGateIndex -and $roundIndex -gt $manifestIndex) `
            'Run does not lock APK/config identity before manifest creation and rounds.'
    Require ($source.Contains('-ExpectedSignerSha256 $script:ExpectedLabSignerSha256')) `
            'Installed Lab APK verification does not pin the accepted signer.'

    $cr = [string][char]13
    $lf = [string][char]10
    $normalizedShell = ConvertTo-DeviceShellCommand ("set -eu" + $cr + $lf +
            "printf 'ok'" + $cr)
    Require (-not $normalizedShell.Contains($cr) -and
            $normalizedShell -ceq ("set -eu" + $lf + "printf 'ok'" + $lf)) `
            'Device shell normalization did not remove CR line endings.'
    $stageTagged = $false
    try { Invoke-AbStage 'synthetic-stage' { throw 'synthetic failure' } | Out-Null }
    catch {
        $stageTagged = $_.Exception.Message -ceq
                "A/B stage 'synthetic-stage' failed. synthetic failure"
    }
    Require $stageTagged 'A/B failures are not stage-labeled.'

    $allowedOutput = Join-Path $script:WorkspaceRoot 'artifacts\benchmarks\selftest-veq-hidden'
    Require ((Resolve-OutputDirectory $allowedOutput) -eq
            [IO.Path]::GetFullPath($allowedOutput)) `
            'The aggregate-output allowlist rejected its artifact root.'
    $sourceOutputRejected = $false
    try { Resolve-OutputDirectory (Join-Path $script:RepoRoot 'forbidden-results') | Out-Null }
    catch { $sourceOutputRejected = $true }
    Require $sourceOutputRejected 'Output inside the source worktree was accepted.'

    $baseline = $script:BaselineVeqSha256
    $candidate = $script:ExpectedCandidateVeqSha256
    $a = @()
    $b = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $temperature = 42.0 + ($pair * 0.1)
        $a += New-SyntheticReport A $pair $baseline 70.0 67.0 5.0 15.0 $temperature
        $b += New-SyntheticReport B $pair $candidate 70.2 67.2 4.4 14.5 ($temperature + 0.3)
    }
    $decision = Get-AbDecision $a $b $baseline $candidate $script:LabApkIdentity
    Require $decision.Gates.MetricScreeningGatePass `
            'A valid VEQ screening signal was rejected.'
    Require ($decision.Gates.Decision -ceq
            'SCREENING_PROMISING_REQUIRES_VISIBILITY_PROOF') `
            'A screening win was mislabeled or lost its visibility-proof requirement.'
    Require (-not $decision.Gates.FinalAcceptancePass -and
            -not $decision.FinalAcceptanceEligible -and
            -not $decision.WristHiddenProven) `
            'A hidden screening result became final acceptance.'
    Require ($decision.Aggregate.P95CpuAndGpuPairWins -eq 3 -and
            $decision.Aggregate.StableRefreshStalePairWins -eq 3) `
            'Synthetic metric signal-win counts are wrong.'

    $syntheticCandidate = [pscustomobject]@{
        Path = 'host-only-selftest.jar'
        Sha256 = $candidate
        SizeBytes = 425792
        FabricVersion = '0.7.0-v69-frame-snapshot.2'
        SourceCommit = 'ee3f61449a6cb1730b45b4956921a090e3120dfd'
    }
    $manifest = New-RunManifest $syntheticCandidate
    Assert-RunManifest $manifest $syntheticCandidate
    Require ([int]$manifest.SchemaVersion -eq 4 -and
            [string]$manifest.ComparisonPurpose -ceq
            'veq-frame-snapshot-hidden-screening' -and
            -not [bool]$manifest.HiddenStateTelemetryAvailable -and
            -not [bool]$manifest.FinalAcceptanceEligible) `
            'Run manifest can overclaim the hidden series.'

    $roundedOnlyB = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $roundedOnlyB += New-SyntheticReport B $pair $candidate 70.0 67.0 5.0 14.55015 (42.3 + ($pair * 0.1))
    }
    $roundedDecision = Get-AbDecision $a $roundedOnlyB $baseline $candidate $script:LabApkIdentity
    Require (-not $roundedDecision.Gates.MetricScreeningGatePass) `
            'A sub-three-percent P95 result passed after display rounding.'

    $mismatched = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4 90.0
    Require (-not (Compare-Pair $a[0] $mismatched).Comparable) `
            'A mismatched refresh distribution was accepted.'
    $hot = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 44.0
    Require (-not (Compare-Pair $a[0] $hot).Comparable) `
            'A mismatched start temperature was accepted.'
    $transition = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $transition.Aggregate.RefreshTransitionCount = 3
    Require (-not (Compare-Pair $a[0] $transition).Comparable) `
            'A mismatched refresh-transition exposure was accepted.'
    $thermal = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $thermal.Aggregate.MaxTempC = 44.0
    Require (-not (Compare-Pair $a[0] $thermal).Comparable) `
            'A mismatched in-sample thermal path was accepted.'
    $configMismatch = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $configMismatch.Protocol.ConfigFingerprintSha256 = ('C' * 64)
    Require (-not (Compare-Pair $a[0] $configMismatch).Comparable) `
            'A changed config tree was accepted.'
    $modsMismatch = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $modsMismatch.Protocol.OtherModsFingerprintSha256 = ('D' * 64)
    Require (-not (Compare-Pair $a[0] $modsMismatch).Comparable) `
            'A changed non-VEQ mod stack was accepted.'

    $pairRegressionB = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $fps = if ($pair -eq 1) { 69.0 } else { 70.7 }
        $p10 = if ($pair -eq 1) { 66.0 } else { 67.7 }
        $pairRegressionB += New-SyntheticReport B $pair $candidate $fps $p10 4.3 14.3 (42.3 + ($pair * 0.1))
    }
    $pairRegression = Get-AbDecision $a $pairRegressionB $baseline $candidate $script:LabApkIdentity
    Require (-not $pairRegression.Gates.MetricScreeningGatePass -and
            -not $pairRegression.Gates.EveryPairGuardrailsPass) `
            'A candidate violating a per-pair guardrail passed screening.'

    $wrongCore = New-SyntheticReport A 1 $baseline 70.0 67.0 5.0 15.0 42.1
    $wrongCore.Protocol.CoreSha256 = ('E' * 64)
    $wrongCoreRejected = $false
    try {
        Assert-RetainedReport -Report $wrongCore -Condition A -Pair 1 -ExpectedVeqSha256 $baseline -ExpectedLabApkIdentity $script:LabApkIdentity
    } catch { $wrongCoreRejected = $true }
    Require $wrongCoreRejected 'A report using a non-v68 core was accepted.'

    $wrongVeq = New-SyntheticReport B 1 $baseline 70.2 67.2 4.4 14.5 42.4
    $wrongVeqRejected = $false
    try {
        Assert-RetainedReport -Report $wrongVeq -Condition B -Pair 1 -ExpectedVeqSha256 $candidate -ExpectedLabApkIdentity $script:LabApkIdentity
    } catch { $wrongVeqRejected = $true }
    Require $wrongVeqRejected 'Condition B accepted the wrong VEQ hash.'

    $marker = New-SyntheticReport A 1 $baseline 70.0 67.0 5.0 15.0 42.1
    $marker.Protocol.NoPendingCoreMarker = $false
    $markerRejected = $false
    try {
        Assert-RetainedReport -Report $marker -Condition A -Pair 1 -ExpectedVeqSha256 $baseline -ExpectedLabApkIdentity $script:LabApkIdentity
    } catch { $markerRejected = $true }
    Require $markerRejected 'A pending transaction marker was accepted.'

    $wrongVeqMarker = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $wrongVeqMarker.Protocol.VeqMarkerState = 'armed'
    $wrongVeqMarkerRejected = $false
    try {
        Assert-RetainedReport -Report $wrongVeqMarker -Condition B -Pair 1 -ExpectedVeqSha256 $candidate -ExpectedLabApkIdentity $script:LabApkIdentity
    } catch { $wrongVeqMarkerRejected = $true }
    Require $wrongVeqMarkerRejected 'A non-consumed condition-B VEQ marker was accepted.'

    $weakCoverage = New-SyntheticReport A 1 $baseline 70.0 67.0 5.0 15.0 42.1
    $weakCoverage.SampleCoveragePercent = 94.9
    $weakRejected = $false
    try {
        Assert-RetainedReport -Report $weakCoverage -Condition A -Pair 1 -ExpectedVeqSha256 $baseline -ExpectedLabApkIdentity $script:LabApkIdentity
    } catch { $weakRejected = $true }
    Require $weakRejected 'A report below 95-percent sample coverage was accepted.'

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('quest-v69-veq-hidden-selftest-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $lockPath = $null
    try {
        for ($pair = 1; $pair -le 3; $pair++) {
            Save-JsonAtomic $a[$pair - 1] (Join-Path $temporaryRoot "A$pair.json") | Out-Null
            Save-JsonAtomic $b[$pair - 1] (Join-Path $temporaryRoot "B$pair.json") | Out-Null
        }
        $roundTrip = Get-ReportSet $temporaryRoot $baseline $candidate $script:LabApkIdentity
        Require $roundTrip.Gates.MetricScreeningGatePass `
                'Aggregate JSON round-trip changed the screening decision.'
        Save-ExcludedAttempt $temporaryRoot 1 1 $null $null @('first exclusion')
        Save-ExcludedAttempt $temporaryRoot 1 1 $null $null @('resumed exclusion')
        Require (@(Get-ChildItem (Join-Path $temporaryRoot 'excluded') -Filter 'pair1-attempt1*-rejection.json').Count -eq 2) `
                'Resumed exclusions overwrote evidence.'

        $staleLock = Join-Path $temporaryRoot '.quest-v69-veq-hidden.lock'
        [IO.File]::WriteAllText($staleLock, 'stale', [Text.UTF8Encoding]::new($false))
        $lockPath = Acquire-RunLock $temporaryRoot
        $concurrentRejected = $false
        try {
            $second = [IO.File]::Open($lockPath, [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $second.Dispose()
        } catch { $concurrentRejected = $true }
        Require $concurrentRejected 'A concurrent host lock was not rejected.'
    } finally {
        if ($null -ne $lockPath) { Release-RunLock $lockPath }
        if (Test-Path -LiteralPath $temporaryRoot) {
            [IO.Directory]::Delete($temporaryRoot, $true)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CandidateJar)) {
        Get-CandidateContract | Out-Null
    }
    Require ($script:DeviceInvocationCount -eq $before) `
            'SelfTest invoked ADB or touched a device.'
    return [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        Assertions = 42
        Package = $script:Package
        Order = 'A1-B1-B2-A2-A3-B3'
        BaselineVeqSha256 = $baseline
        CandidateVeqSha256 = $candidate
        FixedCoreSha256 = $script:ExpectedCoreSha256
        ScreeningOnly = $true
        HiddenStateTelemetryAvailable = $false
        WristHiddenProven = $false
        FinalAcceptanceEligible = $false
        VisibilityProofRequired = $true
        DeviceTouched = $false
        DeviceInvocations = $script:DeviceInvocationCount - $before
        RawLogsPersisted = $false
    }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    throw 'ADB was not found.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $script:DeviceInvocationCount++
    $rows = @(& $script:ResolvedAdb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "ADB failed with exit code $code; device output was suppressed."
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $rows }
}

function Resolve-Device {
    $script:ResolvedAdb = Resolve-Adb
    $rows = @(Invoke-Adb @('devices')).Lines
    $devices = New-Object Collections.Generic.List[object]
    foreach ($row in $rows) {
        if ($row -match '^\s*(?<serial>\S+)\s+(?<state>device|offline|unauthorized|no permissions)(?:\s|$)') {
            $devices.Add([pscustomobject]@{ Serial = $Matches.serial; State = $Matches.state })
        }
    }
    if ($Serial -ne 'auto') {
        $selected = @($devices | Where-Object { $_.Serial -ceq $Serial })
        Require ($selected.Count -eq 1 -and $selected[0].State -eq 'device') `
                'The requested ADB transport is not uniquely online.'
        $script:ResolvedSerial = [string]$selected[0].Serial
    } else {
        $online = @($devices | Where-Object { $_.State -eq 'device' })
        Require ($online.Count -eq 1) 'Exactly one online ADB device is required in auto mode.'
        $script:ResolvedSerial = [string]$online[0].Serial
    }
    $state = Invoke-Adb @('-s', $script:ResolvedSerial, 'get-state')
    Require ((($state.Lines -join '').Trim()) -eq 'device') 'Selected ADB transport is not ready.'
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [string][char]39
    $escaped = $quote + '"' + $quote + '"' + $quote
    return $quote + $Value.Replace($quote, $escaped) + $quote
}

function ConvertTo-DeviceShellCommand([Parameter(Mandatory)][string] $Command) {
    # adb shell parses LF-delimited command text. PowerShell here-strings inherit
    # the Host checkout's CRLF line endings, and toybox otherwise sees the CR as
    # part of commands such as `set -eu`.
    return $Command.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Invoke-DeviceShell([string] $Command, [switch] $AllowFailure) {
    $normalized = ConvertTo-DeviceShellCommand $Command
    return Invoke-Adb @('-s', $script:ResolvedSerial, 'shell', $normalized) `
            -AllowFailure:$AllowFailure
}

function Get-InstalledLabApkIdentity {
    $qPackage = ConvertTo-ShLiteral $script:Package
    $pathResult = Invoke-DeviceShell "pm path $qPackage"
    $packageRows = @($pathResult.Lines | ForEach-Object { $_.Trim() } |
            Where-Object { $_.StartsWith('package:', [StringComparison]::Ordinal) })
    Require ($packageRows.Count -eq 1) `
            'The Lab package must have exactly one monolithic installed APK.'
    $deviceApk = $packageRows[0].Substring('package:'.Length)
    Require ($deviceApk -match '^/data/app/[^\r\n]+/base\.apk$') `
            'The installed Lab base APK path is unexpected.'

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ('quest-v69-installed-lab-' + [guid]::NewGuid().ToString('N'))
    $temporaryApk = Join-Path $temporaryRoot 'base.apk'
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    try {
        $null = Invoke-Adb @('-s', $script:ResolvedSerial, 'pull', $deviceApk, $temporaryApk)
        Require (Test-Path -LiteralPath $temporaryApk -PathType Leaf) `
                'ADB did not return the installed Lab base APK.'
        $size = (Get-Item -LiteralPath $temporaryApk).Length
        Require ($size -gt 0) 'The installed Lab base APK is empty.'
        $verification = @(& $script:ApkVerifier `
                -ApkPath $temporaryApk `
                -ExpectedPackage $script:Package `
                -ExpectedVersionCode $script:ExpectedLabVersionCode `
                -ExpectedVersionName $script:ExpectedLabVersionName `
                -ExpectedLabel $script:ExpectedLabLabel `
                -ExpectedVivecraftSha256 $script:ExpectedVivecraftSha256 `
                -ExpectedLwjglSha256 $script:ExpectedLwjglSha256 `
                -ExpectedSignerSha256 $script:ExpectedLabSignerSha256)
        Require ($verification.Count -eq 1) `
                'The installed Lab APK verifier returned ambiguous output.'
        $verified = $verification[0]
        Require ([bool]$verified.SignatureV2 -and [bool]$verified.Zipalign16KiB -and
                [string]$verified.LabDexGate -ceq 'verified') `
                'The installed Lab APK failed its signature/alignment/DEX provenance gate.'
        $identity = [pscustomobject]@{
            Package = [string]$verified.Package
            VersionCode = [string]$verified.VersionCode
            VersionName = [string]$verified.VersionName
            BaseApkSha256 = (Normalize-Sha256 ([string]$verified.Sha256))
            BaseApkSizeBytes = [int64]$size
            SignerSha256 = (Normalize-Sha256 ([string]$verified.SignerSha256))
            Verification = 'full-host-apk-verifier'
        }
        Assert-LabApkIdentityContract $identity
        return Copy-LabApkIdentity $identity
    } finally {
        if ([IO.File]::Exists($temporaryApk)) { [IO.File]::Delete($temporaryApk) }
        if ([IO.Directory]::Exists($temporaryRoot) -and
                [IO.Directory]::GetFileSystemEntries($temporaryRoot).Length -eq 0) {
            [IO.Directory]::Delete($temporaryRoot)
        }
    }
}

function Invoke-Helper {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string[]] $Arguments)
    $rows = @(& $script:PowerShellExecutable '-NoLogo' '-NoProfile' '-NonInteractive' `
            '-ExecutionPolicy' 'Bypass' '-File' $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Helper '$([IO.Path]::GetFileName($Path))' failed with exit code $code." }
    return $rows
}

function Stop-Lab {
    $null = Invoke-DeviceShell "am force-stop $(ConvertTo-ShLiteral $script:Package)"
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $probe = Invoke-DeviceShell "pidof $(ConvertTo-ShLiteral $script:Package)" -AllowFailure
        if ($probe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($probe.Lines -join ''))) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'Lab app/JVM did not stop in the bounded window.'
}

function Invoke-VeqRollback {
    $arguments = @('-Action', 'Rollback', '-Serial', $script:ResolvedSerial,
        '-AdbPath', $script:ResolvedAdb, '-AllowDeviceWrite')
    $null = Invoke-Helper $script:VeqScript $arguments
}

function Invoke-VeqDeploy([Parameter(Mandatory)] $Candidate) {
    $arguments = @('-Action', 'Deploy', '-Serial', $script:ResolvedSerial,
        '-AdbPath', $script:ResolvedAdb, '-AllowDeviceWrite',
        '-JarPath', $Candidate.Path, '-ExpectedSha256', $Candidate.Sha256,
        '-ExpiryMinutes', '15')
    $null = Invoke-Helper $script:VeqScript $arguments
}

function Get-VeqTransactionStatus {
    $arguments = @('-Action', 'Status', '-Serial', $script:ResolvedSerial,
        '-AdbPath', $script:ResolvedAdb, '-Json')
    $rows = @(Invoke-Helper $script:VeqScript $arguments)
    $jsonRows = @($rows | Where-Object {
        $trimmed = ([string]$_).Trim()
        $trimmed.StartsWith('{', [StringComparison]::Ordinal) -and
                $trimmed.EndsWith('}', [StringComparison]::Ordinal)
    })
    Require ($jsonRows.Count -eq 1) `
            'VEQ Lab status did not return exactly one compact JSON object.'
    try {
        $status = ([string]$jsonRows[0]) | ConvertFrom-Json
    } catch {
        throw "VEQ Lab status returned invalid JSON. $($_.Exception.Message)"
    }
    Require ([string]$status.Result -ceq 'STATUS' -and
            [string]$status.Package -ceq $script:Package -and
            [string]$status.Profile -ceq $script:Profile -and
            [string]$status.HarnessId -ceq $script:ExpectedVeqHarnessId -and
            [bool]$status.ReadOnly) `
            'VEQ Lab status escaped the fixed read-only transaction contract.'
    return $status
}

function Assert-VeqTransactionContract {
    param(
        [Parameter(Mandatory)] $Status,
        [Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition,
        [Parameter(Mandatory)][string] $ExpectedVeqSha256
    )
    $expected = Normalize-Sha256 $ExpectedVeqSha256
    Require ((Normalize-Sha256 ([string]$Status.TargetSha256)) -ceq $expected) `
            'VEQ transaction target hash does not match the selected condition.'
    Require ([string]$Status.OpenXrCopyBatchMode -ceq 'OFF') `
            'VEQ transaction unexpectedly changed OpenXR Copy Batch mode.'
    if ($Condition -ceq 'A') {
        Require ([bool]$Status.BaselineExact -and
                [string]$Status.MarkerState -ceq 'absent' -and
                [string]::IsNullOrWhiteSpace([string]$Status.RunId)) `
                'Baseline VEQ transaction must be exact with no marker or run id.'
    } else {
        Require (-not [bool]$Status.BaselineExact -and
                [string]$Status.MarkerState -ceq 'consumed' -and
                [string]$Status.RunId -cmatch '^[0-9a-f]{32}$') `
                'Candidate VEQ transaction must be consumed with one strict run id.'
    }
}

function Invoke-WorldReset {
    $arguments = @('-Action', 'Reset', '-Serial', $script:ResolvedSerial,
        '-AdbPath', $script:ResolvedAdb, '-AllowDeviceWrite')
    $null = Invoke-Helper $script:ResetScript $arguments
}

function Start-LabAutoplay {
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $arguments = @('-Action', 'ArmAndRun', '-Serial', $script:ResolvedSerial,
        '-AdbPath', $script:ResolvedAdb, '-AllowLaunch')
    $null = Invoke-Helper $script:AutoplayScript $arguments
    return $epoch
}

function Test-LabFocused {
    $result = Invoke-DeviceShell 'dumpsys activity activities' -AllowFailure
    if ($result.ExitCode -ne 0) { return $false }
    $active = $result.Lines | Where-Object { $_ -match 'topResumedActivity' } | Select-Object -First 1
    if ($null -eq $active) {
        $active = $result.Lines | Where-Object { $_ -match '(?:mResumedActivity|ResumedActivity)' } |
                Select-Object -First 1
    }
    return $null -ne $active -and $active -match ([regex]::Escape($script:Package) + '/')
}

function Wait-LabWorldReady([int64] $LaunchEpoch) {
    $log = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/logs/latest.log"
    $deadline = [DateTime]::UtcNow.AddSeconds($script:ReadyTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $qPackage = ConvertTo-ShLiteral $script:Package
        $qLog = ConvertTo-ShLiteral $log
        $clauses = @(
            "pidof $qPackage >/dev/null 2>&1",
            "test -f $qLog",
            ('test "$(stat -c %Y {0})" -ge {1}' -f $qLog, $LaunchEpoch),
            ('test "$(grep -c -E ''Loaded [0-9]+ advancements'' {0})" -ge 2' -f $qLog)
        )
        $ready = Invoke-DeviceShell ($clauses -join ' && ') -AllowFailure
        if ($ready.ExitCode -eq 0 -and (Test-LabFocused)) { return }
        Start-Sleep -Seconds 1
    }
    throw 'Lab did not reach a fresh, focused benchmark world before timeout.'
}

function Wait-HealthyInterval([int] $Seconds, [string] $Label) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $nextProgress = 60
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        $appPidProbe = Invoke-DeviceShell "pidof $(ConvertTo-ShLiteral $script:Package)" -AllowFailure
        Require ($appPidProbe.ExitCode -eq 0 -and
                -not [string]::IsNullOrWhiteSpace(($appPidProbe.Lines -join ''))) `
                "Lab exited during $Label."
        Require (Test-LabFocused) "Lab lost foreground focus during $Label."
        $remaining = $Seconds - [int]$watch.Elapsed.TotalSeconds
        Start-Sleep -Seconds ([Math]::Min(5, [Math]::Max(1, $remaining)))
        if ($watch.Elapsed.TotalSeconds -ge $nextProgress) {
            Write-Host "${Label}: $nextProgress seconds completed."
            $nextProgress += 60
        }
    }
}

function New-LabStackProbeCommand {
    $files = "/sdcard/Android/data/$script:Package/files"
    $game = "$files/instances/$script:Profile"
    $mods = "$game/mods"
    $config = "$game/config"
    $lines = @(
        'set -eu',
        ('files=$(realpath {0})' -f (ConvertTo-ShLiteral $files)),
        ('game=$(realpath {0})' -f (ConvertTo-ShLiteral $game)),
        ('mods=$(realpath {0})' -f (ConvertTo-ShLiteral $mods)),
        ('config=$(realpath {0})' -f (ConvertTo-ShLiteral $config)),
        ('test "$game" = "$files/instances/{0}"' -f $script:Profile),
        'test "$mods" = "$game/mods"',
        'test "$config" = "$game/config"',
        'options="$game/options.txt"',
        'test -f "$options" && test ! -L "$options"',
        'core="$mods/Vivecraft.jar"',
        'veq="$mods/Vivecraft-Essentials-Quest.jar"',
        'test -f "$core" && test ! -L "$core"',
        'test -f "$veq" && test ! -L "$veq"',
        'printf ''CORE\t%s\n'' "$(sha256sum "$core" | awk ''{print toupper($1)}'')"',
        'printf ''VEQ\t%s\n'' "$(sha256sum "$veq" | awk ''{print toupper($1)}'')"',
        '(',
        '  for file in "$mods"/*.jar; do',
        '    [ -e "$file" ] || continue',
        '    [ "$file" = "$core" ] && continue',
        '    [ "$file" = "$veq" ] && continue',
        '    test -f "$file" && test ! -L "$file"',
        '    name=$(basename "$file")',
        '    hash=$(sha256sum "$file" | awk ''{print toupper($1)}'')',
        '    printf ''%s\t%s\n'' "$name" "$hash"',
        '  done',
        ') | LC_ALL=C sort | sha256sum | awk ''{print "MODS\t" toupper($1)}''',
        'test -z "$(find "$config" -type l -print -quit)"',
        '(',
        '  options_hash=$(sha256sum "$options" | awk ''{print toupper($1)}'')',
        '  printf ''options.txt\t%s\n'' "$options_hash"',
        '  cd "$config"',
        '  find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do',
        '    hash=$(sha256sum "$file" | awk ''{print toupper($1)}'')',
        '    printf ''%s\t%s\n'' "$file" "$hash"',
        '  done',
        ') | sha256sum | awk ''{print "CONFIG\t" toupper($1)}''',
        'core_marker="$game/.questcraft/questcraft-vivecraft-core-canary-v1/request.json"',
        'mods_marker="$game/.questcraft/questcraft-mods-ab-canary-v1/request.json"',
        'test ! -e "$core_marker"',
        'test ! -e "$mods_marker"',
        'printf ''MARKERS\tABSENT\n'''
    )
    return $lines -join ([string][char]10)
}

function Get-LabStackState {
    $result = Invoke-DeviceShell (New-LabStackProbeCommand)
    $values = @{}
    foreach ($row in @($result.Lines)) {
        if ($row -match '^(?<name>CORE|VEQ|MODS|CONFIG)\t(?<sha>[0-9A-F]{64})$') {
            Require (-not $values.ContainsKey($Matches.name)) `
                    "Duplicate Lab stack row '$($Matches.name)'."
            $values[$Matches.name] = $Matches.sha
        }
    }
    foreach ($name in @('CORE', 'VEQ', 'MODS', 'CONFIG')) {
        Require ($values.ContainsKey($name)) "Could not resolve Lab stack field '$name'."
    }
    $markerRow = 'MARKERS' + [char]9 + 'ABSENT'
    Require (@($result.Lines | Where-Object { $_ -ceq $markerRow }).Count -eq 1) `
            'One or more pending canary transaction markers exist.'
    return [pscustomobject]@{
        CoreSha256 = [string]$values.CORE
        VeqSha256 = [string]$values.VEQ
        OtherModsFingerprintSha256 = [string]$values.MODS
        ConfigFingerprintSha256 = [string]$values.CONFIG
        NoPendingCoreMarker = $true
        NoPendingModsMarker = $true
    }
}

function Assert-LabStackContract {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $ExpectedVeqSha256
    )
    Require ((Normalize-Sha256 ([string]$State.CoreSha256)) -ceq
            $script:ExpectedCoreSha256) 'Lab core is not exact accepted v68.'
    Require ((Normalize-Sha256 ([string]$State.VeqSha256)) -ceq
            $ExpectedVeqSha256) 'Lab VEQ JAR does not match the selected condition.'
    Require ((Normalize-Sha256 ([string]$State.OtherModsFingerprintSha256)) -ceq
            $script:ExpectedOtherModsFingerprintSha256) `
            'The non-VEQ mod fingerprint changed.'
    Require ((Normalize-Sha256 ([string]$State.ConfigFingerprintSha256)) -ceq
            $script:ExpectedConfigFingerprintSha256) `
            'The config-tree fingerprint changed.'
    Require ([bool]$State.NoPendingCoreMarker -and
            [bool]$State.NoPendingModsMarker) `
            'A pending core/mod canary transaction marker was present.'
}

function Invoke-AggregateCapture([int] $Seconds) {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) `
            "quest-v69-vrapi-$([guid]::NewGuid().ToString('N')).json"
    try {
        $arguments = @('-Action', 'Capture', '-Package', $script:Package,
            '-Serial', $script:ResolvedSerial, '-AdbPath', $script:ResolvedAdb,
            '-Seconds', [string]$Seconds, '-DynamicRefresh', '-PollSeconds', '1',
            '-MinimumSampleCoveragePercent', [string]$script:MinimumSampleCoveragePercent,
            '-OutputJson', $temporary)
        $null = Invoke-Helper $script:BenchmarkScript $arguments
        Require (Test-Path -LiteralPath $temporary -PathType Leaf) `
                'VrApi helper did not write an aggregate report.'
        return Get-Json $temporary
    } finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
    }
}

function Assert-CaptureGate([Parameter(Mandatory)] $Report, [string] $Label) {
    Require ([string]$Report.Package -ceq $script:Package) "$Label used the wrong package."
    Require ([bool]$Report.ValidForComparison) "$Label failed PID/focus/sample coverage."
    Require ([string]$Report.RefreshPolicy -ceq 'Dynamic') "$Label did not use Dynamic refresh."
    Require ([int]$Report.Aggregate.CpuLevelMode -eq $script:ExpectedCpuLevel -and
            [int]$Report.Aggregate.GpuLevelMode -eq $script:ExpectedGpuLevel) `
            "$Label did not hold QGO CPU/GPU 4/4."
    Require ([double]$Report.SampleCoveragePercent -ge $script:MinimumSampleCoveragePercent) `
            "$Label did not reach 95 percent VrApi sample coverage."
    Require ([double]$Report.Aggregate.CpuLevel4Percent -ge
            $script:MinimumPerformanceLevelPercent -and
            [double]$Report.Aggregate.GpuLevel4Percent -ge
            $script:MinimumPerformanceLevelPercent) `
            "$Label did not hold QGO CPU/GPU level 4 for 95 percent of samples."
    Require ($null -ne $Report.Aggregate.LastTempC) "$Label has no edge temperature."
}

function Invoke-OneRound {
    param(
        [Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition,
        [Parameter(Mandatory)][int] $Pair,
        [Parameter(Mandatory)][int] $Attempt,
        [Parameter(Mandatory)] $Candidate
    )
    Invoke-AbStage 'stop-lab' { Stop-Lab } | Out-Null
    Invoke-AbStage 'veq-rollback' { Invoke-VeqRollback } | Out-Null
    Invoke-AbStage 'world-reset' { Invoke-WorldReset } | Out-Null
    $expectedVeq = $script:BaselineVeqSha256
    if ($Condition -ceq 'B') {
        Invoke-AbStage 'veq-deploy-candidate' { Invoke-VeqDeploy $Candidate } | Out-Null
        $expectedVeq = $Candidate.Sha256
    }
    $launchEpoch = Invoke-AbStage 'autoplay-launch' { Start-LabAutoplay }
    Invoke-AbStage 'world-ready' { Wait-LabWorldReady $launchEpoch } | Out-Null
    $stateBefore = Invoke-AbStage 'stack-state-before-warmup' { Get-LabStackState }
    Assert-LabStackContract $stateBefore $expectedVeq
    $transactionBefore = Invoke-AbStage 'veq-transaction-before-warmup' {
        Get-VeqTransactionStatus
    }
    Assert-VeqTransactionContract $transactionBefore $Condition $expectedVeq

    Invoke-AbStage 'warmup' {
        Wait-HealthyInterval $WarmupSeconds "Warm-up $Condition$Pair"
    } | Out-Null
    $preflight = Invoke-AbStage 'thermal-preflight' {
        Invoke-AggregateCapture $script:PreflightSeconds
    }
    Assert-CaptureGate $preflight "Thermal preflight $Condition$Pair"
    $sample = Invoke-AbStage 'sample-capture' {
        Invoke-AggregateCapture $script:SampleSeconds
    }
    Assert-CaptureGate $sample "Sample $Condition$Pair"

    $stateAfter = Invoke-AbStage 'stack-state-after-sample' { Get-LabStackState }
    Assert-LabStackContract $stateAfter $expectedVeq
    $transactionAfter = Invoke-AbStage 'veq-transaction-after-sample' {
        Get-VeqTransactionStatus
    }
    Assert-VeqTransactionContract $transactionAfter $Condition $expectedVeq
    Require ([string]$transactionAfter.MarkerState -ceq
            [string]$transactionBefore.MarkerState -and
            [string]$transactionAfter.RunId -ceq [string]$transactionBefore.RunId) `
            'VEQ transaction state or run id changed during the benchmark round.'
    Require ([string]$stateAfter.ConfigFingerprintSha256 -ceq
            [string]$stateBefore.ConfigFingerprintSha256) `
            'Config fingerprint changed during the benchmark round.'
    Require ([string]$stateAfter.OtherModsFingerprintSha256 -ceq
            [string]$stateBefore.OtherModsFingerprintSha256) `
            'Non-VEQ mod fingerprint changed during the benchmark round.'

    $sample | Add-Member -NotePropertyName Protocol -NotePropertyValue ([pscustomobject]@{
        SchemaVersion = 4
        Series = 'VEQ_HIDDEN_SCREENING'
        ScreeningOnly = $true
        HiddenStateTelemetryAvailable = $false
        WristHiddenProven = $false
        FinalAcceptanceEligible = $false
        Condition = $Condition
        Pair = $Pair
        Attempt = $Attempt
        CoreSha256 = $stateAfter.CoreSha256
        VeqSha256 = $stateAfter.VeqSha256
        NoPendingCoreMarker = $stateAfter.NoPendingCoreMarker
        NoPendingModsMarker = $stateAfter.NoPendingModsMarker
        VeqMarkerState = [string]$transactionAfter.MarkerState
        VeqRunId = if ([string]::IsNullOrWhiteSpace([string]$transactionAfter.RunId)) {
            $null
        } else {
            [string]$transactionAfter.RunId
        }
        VeqTransactionPolicySatisfied = $true
        LabApk = Copy-LabApkIdentity $script:LabApkIdentity
        OtherModsFingerprintSha256 = $stateAfter.OtherModsFingerprintSha256
        ConfigFingerprintSha256 = $stateAfter.ConfigFingerprintSha256
        WorldMasterSha256 = $script:WorldMasterSha256
        WorldResetBeforeLaunch = $true
        ColdLaunch = $true
        WarmupSeconds = $WarmupSeconds
        PreflightSeconds = $script:PreflightSeconds
        StartTemperatureC = [double]$preflight.Aggregate.LastTempC
        PreflightRefreshDistribution = $preflight.Aggregate.DisplayRefreshDistribution
        QgoExpected = 'Dynamic CPU4/GPU4; application owns neither refresh nor performance hints'
        DeviceSelection = 'Resolved locally; serial intentionally not persisted'
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    })
    return $sample
}

function Save-ExcludedAttempt {
    param([string] $Directory, [int] $Pair, [int] $Attempt, $A, $B, [string[]] $Reasons)
    $excluded = Join-Path $Directory 'excluded'
    [IO.Directory]::CreateDirectory($excluded) | Out-Null

    # A resumed run may revisit the same numeric attempt after an interrupted
    # host-side failure.  Never overwrite the earlier aggregate evidence; use
    # one collision-free stem for the A report, B report, and rejection record.
    $stem = "pair$Pair-attempt$Attempt"
    $collision = 0
    while ((Test-Path -LiteralPath (Join-Path $excluded "$stem-A.json")) -or
            (Test-Path -LiteralPath (Join-Path $excluded "$stem-B.json")) -or
            (Test-Path -LiteralPath (Join-Path $excluded "$stem-rejection.json"))) {
        $collision++
        $stem = "pair$Pair-attempt$Attempt-rerun$collision"
    }
    if ($null -ne $A) {
        Save-JsonAtomic $A (Join-Path $excluded "$stem-A.json") | Out-Null
    }
    if ($null -ne $B) {
        Save-JsonAtomic $B (Join-Path $excluded "$stem-B.json") | Out-Null
    }
    $record = [pscustomobject]@{
        Pair = $Pair
        Attempt = $Attempt
        Reasons = $Reasons
        DeviceSelection = 'Resolved locally; serial intentionally not persisted'
        RawLogsPersisted = $false
    }
    Save-JsonAtomic $record (Join-Path $excluded "$stem-rejection.json") | Out-Null
}

function Get-SanitizedFailure([Management.Automation.ErrorRecord] $Failure) {
    $message = [string]$Failure.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedSerial)) {
        $message = $message.Replace($script:ResolvedSerial, '<device>')
    }
    return "$($Failure.Exception.GetType().Name): $message"
}

function Invoke-AbStage {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9-]+$')]
        [string] $Stage,

        [Parameter(Mandatory)]
        [scriptblock] $Operation
    )
    try {
        return & $Operation
    } catch {
        # Keep device output suppressed, but retain the bounded protocol stage so
        # a transport or shell failure can be diagnosed without saving raw logs.
        throw [InvalidOperationException]::new(
                "A/B stage '$Stage' failed. $($_.Exception.Message)", $_.Exception)
    }
}

function Invoke-Pair {
    param([int] $Pair, [Parameter(Mandatory)] $Candidate, [string] $Directory)
    $conditionOrder = if ($Pair -eq 2) { @('B', 'A') } else { @('A', 'B') }
    for ($attempt = 1; $attempt -le $MaximumPairAttempts; $attempt++) {
        $a = $null
        $b = $null
        try {
            for ($conditionIndex = 0; $conditionIndex -lt $conditionOrder.Count;
                    $conditionIndex++) {
                $condition = $conditionOrder[$conditionIndex]
                Write-Host "Starting $condition$Pair (attempt $attempt)."
                $report = Invoke-OneRound $condition $Pair $attempt $Candidate
                if ($condition -ceq 'A') { $a = $report } else { $b = $report }
                if ($conditionIndex -lt ($conditionOrder.Count - 1)) {
                    Invoke-AbStage 'inter-round-stop' { Stop-Lab } | Out-Null
                    Invoke-AbStage 'inter-round-rollback' { Invoke-VeqRollback } | Out-Null
                    if ($InterRoundCooldownSeconds -gt 0) {
                        Wait-HealthyCooldown $InterRoundCooldownSeconds
                    }
                }
            }
            $comparison = Compare-Pair $a $b
            if (-not $comparison.Comparable) {
                Save-ExcludedAttempt $Directory $Pair $attempt $a $b $comparison.InvalidReasons
                Write-Warning "Pair $Pair attempt $attempt was excluded by thermal/refresh matching."
            } else {
                Save-JsonAtomic $a (Join-Path $Directory "A$Pair.json") | Out-Null
                Save-JsonAtomic $b (Join-Path $Directory "B$Pair.json") | Out-Null
                return $comparison
            }
        } catch {
            $failure = Get-SanitizedFailure $_
            Save-ExcludedAttempt $Directory $Pair $attempt $a $b @($failure)
            Write-Warning "Pair $Pair attempt $attempt failed and was excluded."
        } finally {
            try { Stop-Lab } catch { Write-Warning 'Could not confirm Lab stop during cleanup.' }
            try { Invoke-VeqRollback } catch { Write-Warning 'Could not prove baseline rollback during cleanup.' }
        }
        if ($attempt -lt $MaximumPairAttempts -and $InterRoundCooldownSeconds -gt 0) {
            Wait-HealthyCooldown $InterRoundCooldownSeconds
        }
    }
    throw "Pair $Pair did not produce a comparable A/B result after $MaximumPairAttempts attempts."
}

function Wait-HealthyCooldown([int] $Seconds) {
    if ($Seconds -le 0) { return }
    $remaining = $Seconds
    while ($remaining -gt 0) {
        $slice = [Math]::Min(10, $remaining)
        Start-Sleep -Seconds $slice
        $remaining -= $slice
    }
}

function New-RunManifest([Parameter(Mandatory)] $Candidate) {
    return [pscustomobject]@{
        SchemaVersion = 4
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Package = $script:Package
        Profile = $script:Profile
        World = $script:World
        WorldMasterSha256 = $script:WorldMasterSha256
        Order = @('A1','B1','B2','A2','A3','B3')
        ComparisonPurpose = 'veq-frame-snapshot-hidden-screening'
        ScreeningOnly = $true
        HiddenStateTelemetryAvailable = $false
        WristHiddenProven = $false
        FinalAcceptanceEligible = $false
        VisibilityProofRequired = $true
        BaselineVeqSha256 = $script:BaselineVeqSha256
        CandidateVeqSha256 = $Candidate.Sha256
        CandidateSourceCommit = $Candidate.SourceCommit
        FixedCoreSha256 = $script:ExpectedCoreSha256
        FixedOtherModsFingerprintSha256 = $script:ExpectedOtherModsFingerprintSha256
        FixedConfigFingerprintSha256 = $script:ExpectedConfigFingerprintSha256
        NoPendingCoreMarkerRequired = $true
        NoPendingModsMarkerRequired = $true
        InitialAndFinalVeqMarkerAbsentRequired = $true
        BaselineVeqMarkerState = 'absent'
        CandidateVeqMarkerState = 'consumed'
        CandidateVeqRunIdMustRemainStable = $true
        LabApk = Copy-LabApkIdentity $script:LabApkIdentity
        CandidateSizeBytes = $Candidate.SizeBytes
        CandidateFabricVersion = $Candidate.FabricVersion
        WarmupSeconds = $WarmupSeconds
        PreflightSeconds = $script:PreflightSeconds
        SampleSeconds = $script:SampleSeconds
        MaximumPairAttempts = $MaximumPairAttempts
        InterRoundCooldownSeconds = $InterRoundCooldownSeconds
        MaximumStartTemperatureDeltaC = $MaximumStartTemperatureDeltaC
        MaximumRefreshDistributionDistancePercent = $MaximumRefreshDistributionDistancePercent
        MaximumRefreshMeanDeltaHz = $MaximumRefreshMeanDeltaHz
        MaximumRefreshTransitionDelta = $script:MaximumRefreshTransitionDelta
        MaximumThermalPathDeltaC = $script:MaximumThermalPathDeltaC
        MinimumSampleCoveragePercent = $script:MinimumSampleCoveragePercent
        MinimumPerformanceLevelPercent = $script:MinimumPerformanceLevelPercent
        P95PairSignalFloorPercent = $script:P95PairSignalFloorPercent
        StableRefreshStalePairSignalFloorPercent = $script:StalePairSignalFloorPercent
        RequiredSignalPairWins = $script:RequiredSignalPairWins
        ScreeningP95ImprovementPercent = $script:ScreeningP95ImprovementPercent
        ScreeningStableRefreshStaleImprovementPercent = $script:ScreeningStaleImprovementPercent
        MaximumGuardrailRegressionPercent = $MaximumGuardrailRegressionPercent
        QgoPolicy = 'Dynamic CPU4/GPU4'
        SerialPersisted = $false
        RawLogsPersisted = $false
    }
}

function Assert-RunManifest {
    param([Parameter(Mandatory)] $Manifest, [Parameter(Mandatory)] $Candidate)
    Require ([int]$Manifest.SchemaVersion -eq 4) 'Run manifest schema mismatch.'
    Require ([string]$Manifest.ComparisonPurpose -ceq 'veq-frame-snapshot-hidden-screening' -and
            [bool]$Manifest.ScreeningOnly -and
            -not [bool]$Manifest.HiddenStateTelemetryAvailable -and
            -not [bool]$Manifest.WristHiddenProven -and
            -not [bool]$Manifest.FinalAcceptanceEligible -and
            [bool]$Manifest.VisibilityProofRequired) `
            'Run manifest can overclaim hidden-Wrist screening.'
    Require ([string]$Manifest.Package -ceq $script:Package) 'Run manifest package mismatch.'
    Require ([string]$Manifest.Profile -ceq $script:Profile) 'Run manifest profile mismatch.'
    Require ([string]$Manifest.World -ceq $script:World) 'Run manifest world mismatch.'
    Require ((@($Manifest.Order) -join '-') -ceq 'A1-B1-B2-A2-A3-B3') `
            'Run manifest is not counterbalanced AB/BA/AB.'
    Require ((Normalize-Sha256 ([string]$Manifest.BaselineVeqSha256)) -ceq
            $script:BaselineVeqSha256) 'Run manifest accepted-VEQ baseline mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.CandidateVeqSha256)) -ceq
            $Candidate.Sha256) 'Run manifest candidate mismatch.'
    Require ([string]$Manifest.CandidateSourceCommit -ceq $Candidate.SourceCommit -and
            [int64]$Manifest.CandidateSizeBytes -eq [int64]$Candidate.SizeBytes -and
            [string]$Manifest.CandidateFabricVersion -ceq [string]$Candidate.FabricVersion) `
            'Run manifest candidate metadata mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.FixedCoreSha256)) -ceq
            $script:ExpectedCoreSha256) 'Run manifest core pin mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.FixedOtherModsFingerprintSha256)) -ceq
            $script:ExpectedOtherModsFingerprintSha256) `
            'Run manifest non-VEQ mod fingerprint mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.FixedConfigFingerprintSha256)) -ceq
            $script:ExpectedConfigFingerprintSha256) `
            'Run manifest config fingerprint mismatch.'
    Require ([bool]$Manifest.NoPendingCoreMarkerRequired -and
            [bool]$Manifest.NoPendingModsMarkerRequired -and
            [bool]$Manifest.InitialAndFinalVeqMarkerAbsentRequired -and
            [string]$Manifest.BaselineVeqMarkerState -ceq 'absent' -and
            [string]$Manifest.CandidateVeqMarkerState -ceq 'consumed' -and
            [bool]$Manifest.CandidateVeqRunIdMustRemainStable) `
            'Run manifest weakened transaction-marker gates.'
    Assert-LabApkIdentityContract $Manifest.LabApk $script:LabApkIdentity
    Require ([int]$Manifest.WarmupSeconds -eq $WarmupSeconds -and
            [int]$Manifest.PreflightSeconds -eq $script:PreflightSeconds -and
            [int]$Manifest.SampleSeconds -eq $script:SampleSeconds) `
            'Run manifest timing mismatch.'
    Require ([int]$Manifest.MaximumPairAttempts -eq $MaximumPairAttempts -and
            [int]$Manifest.InterRoundCooldownSeconds -eq $InterRoundCooldownSeconds) `
            'Run manifest attempt/cooldown protocol changed.'
    Require ([string]$Manifest.WorldMasterSha256 -ceq $script:WorldMasterSha256) `
            'Run manifest world-master mismatch.'
    Require ([double]$Manifest.MaximumStartTemperatureDeltaC -eq $MaximumStartTemperatureDeltaC -and
            [double]$Manifest.MaximumRefreshDistributionDistancePercent -eq
            $MaximumRefreshDistributionDistancePercent -and
            [double]$Manifest.MaximumRefreshMeanDeltaHz -eq $MaximumRefreshMeanDeltaHz -and
            [int]$Manifest.MaximumRefreshTransitionDelta -eq
            $script:MaximumRefreshTransitionDelta -and
            [double]$Manifest.MaximumThermalPathDeltaC -eq $script:MaximumThermalPathDeltaC) `
            'Run manifest refresh/thermal thresholds changed.'
    Require ([double]$Manifest.MinimumSampleCoveragePercent -eq
            $script:MinimumSampleCoveragePercent -and
            [double]$Manifest.MinimumPerformanceLevelPercent -eq
            $script:MinimumPerformanceLevelPercent -and
            [double]$Manifest.P95PairSignalFloorPercent -eq $script:P95PairSignalFloorPercent -and
            [double]$Manifest.StableRefreshStalePairSignalFloorPercent -eq
            $script:StalePairSignalFloorPercent -and
            [int]$Manifest.RequiredSignalPairWins -eq $script:RequiredSignalPairWins) `
            'Run manifest report-quality/signal gates changed.'
    Require ([double]$Manifest.ScreeningP95ImprovementPercent -eq
            $script:ScreeningP95ImprovementPercent -and
            [double]$Manifest.ScreeningStableRefreshStaleImprovementPercent -eq
            $script:ScreeningStaleImprovementPercent -and
            [double]$Manifest.MaximumGuardrailRegressionPercent -eq
            $MaximumGuardrailRegressionPercent) `
            'Run manifest screening thresholds changed.'
}


function Acquire-RunLock([string] $Directory) {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $lockPath = Join-Path $Directory '.quest-v69-veq-hidden.lock'
    try {
        # OpenOrCreate plus FileShare.None distinguishes a live owner from a
        # harmless stale file left by a terminated host process.
        $script:RunLockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
        $script:RunLockStream.SetLength(0)
        $bytes = [Text.Encoding]::UTF8.GetBytes("host-lock; serial-not-persisted`n")
        $script:RunLockStream.Write($bytes, 0, $bytes.Length)
        $script:RunLockStream.Flush($true)
        return $lockPath
    } catch {
        throw 'Another run lock exists. Inspect it before removing or resuming.'
    }
}

function Release-RunLock([string] $Path) {
    if ($null -ne $script:RunLockStream) {
        $script:RunLockStream.Dispose()
        $script:RunLockStream = $null
    }
    if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
}

function Get-ReportSet {
    param(
        [string] $Directory,
        [string] $BaselineSha,
        [string] $CandidateSha,
        $ExpectedLabApkIdentity
    )
    $a = @()
    $b = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $aPath = Join-Path $Directory "A$pair.json"
        $bPath = Join-Path $Directory "B$pair.json"
        Require (Test-Path -LiteralPath $aPath -PathType Leaf) "Missing A$pair.json."
        Require (Test-Path -LiteralPath $bPath -PathType Leaf) "Missing B$pair.json."
        $a += Get-Json $aPath
        $b += Get-Json $bPath
    }
    return Get-AbDecision $a $b $BaselineSha $CandidateSha $ExpectedLabApkIdentity
}

function Invoke-Plan([Parameter(Mandatory)] $Candidate) {
    return [pscustomobject]@{
        Result = 'PLAN'
        DeviceTouched = $false
        Package = $script:Package
        Profile = $script:Profile
        World = $script:World
        Order = 'A1-B1-B2-A2-A3-B3'
        ComparisonPurpose = 'veq-frame-snapshot-hidden-screening'
        ConditionA = 'accepted VEQ 0.7.0 baseline'
        BaselineVeqSha256 = $script:BaselineVeqSha256
        ConditionB = 'corrected ee3f6144 VEQ Frame Snapshot candidate'
        CandidateVeqSha256 = $Candidate.Sha256
        CandidateSourceCommit = $Candidate.SourceCommit
        FixedCoreSha256 = $script:ExpectedCoreSha256
        ExpectedLabApk = [pscustomobject]@{
            Package = $script:Package
            VersionCode = $script:ExpectedLabVersionCode
            VersionName = $script:ExpectedLabVersionName
            SignerSha256 = $script:ExpectedLabSignerSha256
            RequiredGate = 'installed base.apk full Host verification before rounds'
        }
        CandidateFabricVersion = $Candidate.FabricVersion
        WarmupSecondsPerRound = $WarmupSeconds
        PreflightSecondsPerRound = $script:PreflightSeconds
        SampleSecondsPerRound = $script:SampleSeconds
        PairTemperatureLimitC = $MaximumStartTemperatureDeltaC
        InSampleThermalPathLimitC = $script:MaximumThermalPathDeltaC
        RefreshDistributionLimitPercent = $MaximumRefreshDistributionDistancePercent
        RefreshMeanDeltaLimitHz = $MaximumRefreshMeanDeltaHz
        RefreshTransitionCountDeltaLimit = $script:MaximumRefreshTransitionDelta
        MinimumSampleCoveragePercent = $script:MinimumSampleCoveragePercent
        MinimumCpuGpuLevel4Percent = $script:MinimumPerformanceLevelPercent
        ScreeningGate = 'P95 >=3% or stable-refresh stale >=10%, with signal wins in >=2/3 pairs'
        Guardrail = "Mean FPS and P10 each no worse than -$MaximumGuardrailRegressionPercent percent in every pair and aggregate"
        ScreeningOnly = $true
        HiddenStateTelemetryAvailable = $false
        WristHiddenProven = $false
        FinalAcceptanceEligible = $false
        VisibilityProofRequired = $true
        StableSelectable = $false
        RawLogsPersisted = $false
    }
}


function Invoke-Run([Parameter(Mandatory)] $Candidate) {
    if (-not $AllowDeviceWrite) {
        throw 'Run is disabled by default. Re-run with -AllowDeviceWrite.'
    }
    $directory = Resolve-OutputDirectory $OutputDirectory -GenerateDefault
    $lockPath = Acquire-RunLock $directory
    $manifestPath = Join-Path $directory 'run-manifest.json'
    try {
        $script:PowerShellExecutable = Get-CurrentPowerShellExecutable
        Resolve-Device
        $script:LabApkIdentity = Get-InstalledLabApkIdentity

        Stop-Lab
        Invoke-VeqRollback
        $initialState = Get-LabStackState
        $initialTransaction = Get-VeqTransactionStatus
        Require ((Normalize-Sha256 ([string]$initialState.CoreSha256)) -ceq
                $script:ExpectedCoreSha256) `
                'Initial Lab core is not exact accepted v68.'
        Require ((Normalize-Sha256 ([string]$initialState.VeqSha256)) -ceq
                $script:BaselineVeqSha256) `
                'Initial Lab VEQ is not the accepted baseline.'
        Require ([bool]$initialState.NoPendingCoreMarker -and
                [bool]$initialState.NoPendingModsMarker) `
                'Initial Lab state has a pending core/mod transaction marker.'
        Assert-VeqTransactionContract $initialTransaction A $script:BaselineVeqSha256

        if (Test-Path -LiteralPath $manifestPath) {
            Require $Resume `
                    'Output directory already has a run manifest; use -Resume after inspection.'
            $existingManifest = Get-Json $manifestPath
            $script:ExpectedConfigFingerprintSha256 = Normalize-Sha256 ([string]$existingManifest.FixedConfigFingerprintSha256)
            $script:ExpectedOtherModsFingerprintSha256 = Normalize-Sha256 ([string]$existingManifest.FixedOtherModsFingerprintSha256)
            Assert-LabStackContract $initialState $script:BaselineVeqSha256
            Assert-RunManifest $existingManifest $Candidate
        } else {
            $unexpected = @(Get-ChildItem -Force -LiteralPath $directory |
                    Where-Object { $_.FullName -cne $lockPath })
            Require ($unexpected.Count -eq 0) `
                    'A new run requires an empty aggregate directory apart from the host lock.'
            $script:ExpectedConfigFingerprintSha256 = Normalize-Sha256 ([string]$initialState.ConfigFingerprintSha256)
            $script:ExpectedOtherModsFingerprintSha256 = Normalize-Sha256 ([string]$initialState.OtherModsFingerprintSha256)
            Assert-LabStackContract $initialState $script:BaselineVeqSha256
            $manifest = New-RunManifest $Candidate
            Save-JsonAtomic $manifest $manifestPath | Out-Null
        }

        for ($pair = 1; $pair -le 3; $pair++) {
            $aPath = Join-Path $directory "A$pair.json"
            $bPath = Join-Path $directory "B$pair.json"
            if ((Test-Path -LiteralPath $aPath) -or (Test-Path -LiteralPath $bPath)) {
                Require $Resume `
                        "Pair $pair output already exists; use -Resume only after inspecting it."
                Require ((Test-Path -LiteralPath $aPath) -and
                        (Test-Path -LiteralPath $bPath)) `
                        "Pair $pair is partial; archive it before resuming."
                continue
            }
            Invoke-Pair $pair $Candidate $directory | Out-Null
        }

        $decision = Get-ReportSet $directory $script:BaselineVeqSha256 $Candidate.Sha256 $script:LabApkIdentity
        Save-JsonAtomic $decision (Join-Path $directory 'comparison.json') -Replace |
                Out-Null

        Stop-Lab
        Invoke-VeqRollback
        $finalState = Get-LabStackState
        Assert-LabStackContract $finalState $script:BaselineVeqSha256
        $finalTransaction = Get-VeqTransactionStatus
        Assert-VeqTransactionContract $finalTransaction A $script:BaselineVeqSha256
        return [pscustomobject]@{
            Result = 'COMPLETE'
            OutputDirectory = $directory
            Decision = $decision.Gates.Decision
            MetricScreeningGatePass = $decision.Gates.MetricScreeningGatePass
            FinalAcceptancePass = $false
            VisibilityProofRequired = $true
            LabApk = Copy-LabApkIdentity $script:LabApkIdentity
            LabLeftStoppedOnBaseline = $true
            StableTouched = $false
            RawLogsPersisted = $false
        }
    } catch {
        try { Stop-Lab } catch { Write-Warning 'Lab stop failed during recovery.' }
        try { Invoke-VeqRollback }
        catch { Write-Warning 'Accepted VEQ rollback failed during recovery.' }
        throw
    } finally {
        Release-RunLock $lockPath
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    return
}

Resolve-HostContract
if ($Action -eq 'Aggregate') {
    Require (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) `
            '-OutputDirectory is required for Aggregate.'
    $aggregateDirectory = Resolve-OutputDirectory $OutputDirectory
    $manifest = Get-Json (Join-Path $aggregateDirectory 'run-manifest.json')
    $WarmupSeconds = [int]$manifest.WarmupSeconds
    $MaximumStartTemperatureDeltaC =
            [double]$manifest.MaximumStartTemperatureDeltaC
    $MaximumRefreshDistributionDistancePercent =
            [double]$manifest.MaximumRefreshDistributionDistancePercent
    $MaximumRefreshMeanDeltaHz = [double]$manifest.MaximumRefreshMeanDeltaHz
    $MaximumGuardrailRegressionPercent =
            [double]$manifest.MaximumGuardrailRegressionPercent
    Require ($WarmupSeconds -ge 300 -and
            $MaximumStartTemperatureDeltaC -le 1.0 -and
            $MaximumRefreshDistributionDistancePercent -le 5.0 -and
            $MaximumRefreshMeanDeltaHz -le 0.5 -and
            $MaximumGuardrailRegressionPercent -le 1.0) `
            'Aggregate manifest weakens fixed quality gates.'
    Require ([int]$manifest.SchemaVersion -eq 4 -and
            [string]$manifest.ComparisonPurpose -ceq
            'veq-frame-snapshot-hidden-screening' -and
            [bool]$manifest.ScreeningOnly -and
            -not [bool]$manifest.HiddenStateTelemetryAvailable -and
            -not [bool]$manifest.FinalAcceptanceEligible -and
            (@($manifest.Order) -join '-') -ceq 'A1-B1-B2-A2-A3-B3') `
            'Aggregate manifest is not the counterbalanced VEQ hidden screening.'
    $baseline = Normalize-Sha256 ([string]$manifest.BaselineVeqSha256)
    $candidateSha = Normalize-Sha256 ([string]$manifest.CandidateVeqSha256)
    Require ($baseline -ceq $script:BaselineVeqSha256) `
            'Aggregate manifest accepted-VEQ baseline mismatch.'
    Require ($candidateSha -ceq $script:ExpectedCandidateVeqSha256) `
            'Aggregate manifest candidate mismatch.'
    $script:ExpectedConfigFingerprintSha256 = Normalize-Sha256 ([string]$manifest.FixedConfigFingerprintSha256)
    $script:ExpectedOtherModsFingerprintSha256 = Normalize-Sha256 ([string]$manifest.FixedOtherModsFingerprintSha256)
    $script:LabApkIdentity = $manifest.LabApk
    $manifestCandidate = [pscustomobject]@{
        Path = 'aggregate-only'
        Sha256 = $candidateSha
        SizeBytes = [int64]$manifest.CandidateSizeBytes
        FabricVersion = [string]$manifest.CandidateFabricVersion
        SourceCommit = [string]$manifest.CandidateSourceCommit
    }
    Assert-RunManifest $manifest $manifestCandidate
    Get-ReportSet $aggregateDirectory $baseline $candidateSha $manifest.LabApk
    return
}

$candidateContract = Get-CandidateContract
if ($Action -eq 'Plan') {
    Invoke-Plan $candidateContract
    return
}
Invoke-Run $candidateContract
