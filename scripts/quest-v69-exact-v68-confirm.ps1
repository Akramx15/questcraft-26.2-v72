<#
.SYNOPSIS
Confirms OpenXR Copy Batch ON against the exact accepted v68 core on Lab only.

.DESCRIPTION
The counterbalanced protocol is A1 -> B1 -> B2 -> A2 -> A3 -> B3 (AB/BA/AB).
A is the exact accepted v68 rollback JAR and deliberately has no copy-batch
mode marker. B is the pinned v68-only Copy Batch candidate deployed with the
exact ON marker. Every round stops only com.qcxr.qcxr.canary262, restores the
v68 rollback core, deploys B only when required, restores the fixed benchmark world, cold-launches
the authenticated one-shot quick-play gate, warms for at least five minutes,
captures an aggregate-only thermal preflight, and then captures one 60-second
PID-owned VrApi sample.  A pair is retained only when its start temperature and
actual dynamic-refresh distributions match.  Rejected attempts are kept as
aggregate JSON so an operator can audit exclusions without retaining raw logs.

Run is disabled unless -AllowDeviceWrite is explicit.  SelfTest, Plan, and
Aggregate never resolve or invoke ADB.  The accepted Personal package is not a
parameter and cannot be selected by this script.

.EXAMPLE
.\scripts\quest-v69-exact-v68-confirm.ps1 -Action SelfTest

.EXAMPLE
pwsh -NoProfile -File .\scripts\quest-v69-exact-v68-confirm.ps1 -Action SelfTest

.EXAMPLE
powershell.exe -NoProfile -File .\scripts\quest-v69-exact-v68-confirm.ps1 -Action SelfTest

.EXAMPLE
.\scripts\quest-v69-exact-v68-confirm.ps1 -Action Plan `
  -CandidateJar ..\..\artifacts\v69-openxr-copy-batch-v68-only-20260903\vivecraft-26.2-1.3.15-openxr-copy-batch-v68-only.jar `
  -CandidateSha256 A7298DFD1EA6BE238CB1AA815E46E774295A4FCBA771EB1345BA1B361EB33F2F

.EXAMPLE
.\scripts\quest-v69-exact-v68-confirm.ps1 -Action Run -AllowDeviceWrite `
  -Serial 192.0.2.2:5555 -AdbPath C:\Android\platform-tools\adb.exe `
  -CandidateJar C:\canaries\vivecraft-copy-batch.jar `
  -CandidateSha256 A7298DFD1EA6BE238CB1AA815E46E774295A4FCBA771EB1345BA1B361EB33F2F
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
$script:ExpectedBaselineSha256 = '3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F'
$script:ExpectedCopyBatchJarSha256 = 'A7298DFD1EA6BE238CB1AA815E46E774295A4FCBA771EB1345BA1B361EB33F2F'
$script:BaselineMode = 'V68_DEFAULT'
$script:OnMode = 'ON'
$script:CandidateOffRuntimeMarker = 'Vivecraft: OpenXR eye copy submission=per_eye openxrCopyBatch=OFF'
$script:OnRuntimeMarker = 'Vivecraft: OpenXR eye copy submission=dual_swapchain_single_command_buffer openxrCopyBatch=ON'
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
$script:FinalP95ImprovementPercent = 3.0
$script:FinalStaleImprovementPercent = 10.0
$script:RequiredSignalPairWins = 2
$script:ReadyTimeoutSeconds = 240
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:BenchmarkScript = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$script:ResetScript = Join-Path $PSScriptRoot 'reset-lab-benchmark-world.ps1'
$script:CoreScript = Join-Path $PSScriptRoot 'quest-vivecraft-core-canary.ps1'
$script:AutoplayScript = Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'
$script:ApkVerifier = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$script:LabBuilder = Join-Path $script:RepoRoot `
        'QCXR-XR-Wrapper\Assets\Editor\QuestCraftLabCliBuild.cs'
$script:BaselineSha256 = $null
$script:BaselinePath = $null
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

function Get-ConditionMode([Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition) {
    if ($Condition -ceq 'A') { return $script:BaselineMode }
    if ($Condition -ceq 'B') { return $script:OnMode }
    throw 'Condition must be exactly A or B.'
}

function Get-ModeRuntimeMarker([Parameter(Mandatory)][string] $Mode) {
    if ($Mode -ceq $script:BaselineMode) { return $null }
    if ($Mode -ceq $script:OnMode) { return $script:OnRuntimeMarker }
    throw 'Exact-v68 confirmation mode must be V68_DEFAULT or ON.'
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
            'Exact-v68 confirmation cannot weaken the one-degree start-temperature gate.'
    Require ($MaximumRefreshDistributionDistancePercent -le 5.0) `
            'Exact-v68 confirmation cannot weaken the refresh-distribution gate.'
    Require ($MaximumRefreshMeanDeltaHz -le 0.5) `
            'Exact-v68 confirmation cannot weaken the refresh-mean gate.'
    Require ($MaximumGuardrailRegressionPercent -le 1.0) `
            'Exact-v68 confirmation cannot weaken the FPS/P10 guardrail.'
    foreach ($path in @($script:BenchmarkScript, $script:ResetScript, $script:CoreScript,
            $script:AutoplayScript, $script:ApkVerifier, $script:LabBuilder)) {
        Require (Test-Path -LiteralPath $path -PathType Leaf) "Required helper is missing: $path"
    }

    $lockPath = Join-Path $script:RepoRoot 'STACK.lock.json'
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    Require ([int64]$lock.identity.versionCode -eq 68) 'STACK.lock.json is not the v68 baseline.'
    $relative = [string]$lock.bundledArtifacts.vivecraft.path
    Require ($relative -ceq 'Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin') `
            'The baseline Vivecraft asset path changed.'
    $script:BaselinePath = Join-Path $script:RepoRoot $relative
    Require (Test-Path -LiteralPath $script:BaselinePath -PathType Leaf) `
            'The v68 Vivecraft baseline is missing.'
    $script:BaselineSha256 = Normalize-Sha256 ([string]$lock.bundledArtifacts.vivecraft.sha256)
    Require ($script:BaselineSha256 -eq $script:ExpectedBaselineSha256) `
            'STACK.lock.json is not the exact accepted v68 Vivecraft baseline.'
    $actual = (Get-FileHash -LiteralPath $script:BaselinePath -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($actual -eq $script:BaselineSha256) 'The v68 Vivecraft baseline hash changed.'
    $script:ExpectedVivecraftSha256 = Normalize-Sha256 `
            ([string]$lock.bundledArtifacts.vivecraft.sha256)
    $script:ExpectedLwjglSha256 = Normalize-Sha256 `
            ([string]$lock.bundledArtifacts.lwjgl.sha256)
    $script:ExpectedLabSignerSha256 = Normalize-Sha256 `
            ([string]$lock.identity.expectedSignerSha256)

    $resetSource = Get-Content -Raw -LiteralPath $script:ResetScript
    $coreSource = Get-Content -Raw -LiteralPath $script:CoreScript
    $autoplaySource = Get-Content -Raw -LiteralPath $script:AutoplayScript
    $benchmarkSource = Get-Content -Raw -LiteralPath $script:BenchmarkScript
    $labBuilderSource = Get-Content -Raw -LiteralPath $script:LabBuilder
    Require ((Get-CSharpStringConstant $labBuilderSource 'ApplicationIdentifier') -ceq
            $script:Package) 'Lab builder package identity drifted.'
    $script:ExpectedLabVersionCode = Get-CSharpStringConstant $labBuilderSource 'VersionCode'
    Require ($script:ExpectedLabVersionCode -ceq '69') 'Lab builder versionCode is not 69.'
    $script:ExpectedLabVersionName = Get-CSharpStringConstant $labBuilderSource 'VersionName'
    Require ($script:ExpectedLabVersionName -match '^6\.0\.1-26\.2-vivecraft-[a-z0-9.-]+$') `
            'Lab builder versionName is outside the fixed v69 namespace.'
    $script:ExpectedLabLabel = Get-CSharpStringConstant $labBuilderSource 'ProductName'
    Require ($script:ExpectedLabLabel -ceq 'QuestCraft Vivecraft Lab 26.2') `
            'Lab builder product label drifted.'
    Require ($resetSource.Contains("`$script:Package = '$script:Package'")) `
            'Benchmark-world reset is not pinned to the Lab package.'
    Require ($coreSource.Contains("`$script:Package = '$script:Package'")) `
            'Core canary helper is not pinned to the Lab package.'
    Require ($coreSource.Contains("[string] `$OpenXrCopyBatchMode = 'OFF'")) `
            'Core canary helper does not default copy batching to OFF.'
    Require ($coreSource.Contains('openXrCopyBatchMode')) `
            'Core canary helper does not bind copy-batch mode into its marker.'
    Require ($coreSource.Contains('MarkerSchemaVersion = 2')) `
            'Core canary helper is not on strict marker schema 2.'
    Require ($autoplaySource.Contains("`$package = '$script:Package'")) `
            'Autoplay helper is not pinned to the Lab package.'
    Require ($benchmarkSource.Contains('[string]$Package')) `
            'VrApi benchmark no longer accepts an explicit package.'
    Require ($benchmarkSource.Contains('FirstTempC') -and $benchmarkSource.Contains('LastTempC')) `
            'VrApi benchmark lacks aggregate-only sample-edge temperatures.'
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
    Require ($item.Length -gt 0 -and $item.Length -le 16MB) `
            'Candidate size is outside the 16 MiB canary limit.'
    $expected = Normalize-Sha256 $CandidateSha256
    Require ($expected -ceq $script:ExpectedCopyBatchJarSha256) `
            'Candidate is not the exact v68-only OpenXR copy-batch JAR.'
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($actual -eq $expected) 'Candidate JAR does not match -CandidateSha256.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'fabric.mod.json' })
        Require ($entries.Count -eq 1) 'Candidate must have exactly one root fabric.mod.json.'
        $reader = New-Object IO.StreamReader($entries[0].Open(), (New-Object Text.UTF8Encoding($false, $true)))
        try { $fabric = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        Require ([string]$fabric.id -ceq 'vivecraft') 'Candidate Fabric id is not vivecraft.'
        $minecraft = @($fabric.depends.minecraft)
        $java = @($fabric.depends.java)
        Require ($minecraft.Count -eq 1 -and [string]$minecraft[0] -ceq '26.2.x') `
                'Candidate Minecraft dependency is not exactly 26.2.x.'
        Require ($java.Count -eq 1 -and [string]$java[0] -ceq '>=25') `
                'Candidate Java dependency is not exactly >=25.'
        return [pscustomobject]@{
            Path = $path
            Sha256 = $actual
            SizeBytes = [int64]$item.Length
            FabricVersion = [string]$fabric.version
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
        Join-Path $artifactRoot ('v69-exact-v68-confirm-' +
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
        [Parameter(Mandatory)][string] $ExpectedCoreSha256,
        [Parameter(Mandatory)][string] $ExpectedMode,
        [Parameter(Mandatory)] $ExpectedLabApkIdentity
    )
    Require ([string]$Report.Package -ceq $script:Package) 'A retained report is not from the Lab package.'
    Require ([bool]$Report.ValidForComparison) 'A retained report failed its PID/focus/sample gates.'
    Require (-not [bool]$Report.RawLogsPersisted) 'A retained report claims raw logs were persisted.'
    Require ($null -ne $Report.Protocol) 'A retained report has no v69 protocol metadata.'
    Require ([int]$Report.Protocol.SchemaVersion -eq 3 -and
            [bool]$Report.Protocol.ExactV68Comparison -and
            -not [bool]$Report.Protocol.SameJarBothConditions) `
            'Retained report is not from the exact-v68 schema-3 protocol.'
    Require ([string]$Report.Protocol.Condition -ceq $Condition) 'Retained report condition mismatch.'
    Require ([int]$Report.Protocol.Pair -eq $Pair) 'Retained report pair mismatch.'
    Require ([int]$Report.Protocol.Attempt -ge 1 -and
            [int]$Report.Protocol.Attempt -le $MaximumPairAttempts) `
            'Retained report attempt is outside the bounded protocol.'
    Require ((Normalize-Sha256 ([string]$Report.Protocol.CoreSha256)) -eq $ExpectedCoreSha256) `
            'Retained report core hash mismatch.'
    Require ([string]$Report.Protocol.OpenXrCopyBatchMode -ceq $ExpectedMode) `
            'Retained report copy-batch mode mismatch.'
    if ($ExpectedMode -ceq $script:BaselineMode) {
        Require ($null -eq $Report.Protocol.RuntimeModeMarker) `
                'The exact v68 report must not claim a copy-batch runtime marker.'
    } else {
        Require ([string]$Report.Protocol.RuntimeModeMarker -ceq
                (Get-ModeRuntimeMarker $ExpectedMode)) `
                'Candidate report lacks the exact Copy Batch ON runtime marker.'
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
    Require ([string]$Report.Protocol.OtherModsFingerprintSha256 -match '^[0-9A-Fa-f]{64}$') `
            'Retained report has no valid one-variable stack fingerprint.'
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
    $thermalPathRawDeltas = New-Object Collections.Generic.List[double]
    foreach ($metric in @('FirstTempC', 'MeanTempC', 'LastTempC', 'MaxTempC')) {
        $rawDelta = [Math]::Abs(
                [double]$A.Aggregate.$metric - [double]$B.Aggregate.$metric)
        $thermalPathRawDeltas.Add($rawDelta)
        $thermalPathDeltas[$metric] = Round-Value $rawDelta 1
    }
    $maximumThermalPathDelta = [double](($thermalPathRawDeltas |
            Measure-Object -Maximum).Maximum)
    $reasons = New-Object Collections.Generic.List[string]
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
    if ([string]$A.Protocol.OtherModsFingerprintSha256 -cne
            [string]$B.Protocol.OtherModsFingerprintSha256) {
        $reasons.Add('The non-Vivecraft mod fingerprint changed inside the pair.')
    }
    return [pscustomobject]@{
        Comparable = $reasons.Count -eq 0
        InvalidReasons = $reasons.ToArray()
        StartTemperatureDeltaC = Round-Value $temperatureDelta 1
        ThermalPathDeltaC = [pscustomobject]$thermalPathDeltas
        MaximumThermalPathDeltaC = Round-Value $maximumThermalPathDelta 1
        Refresh = $refresh
        P95CpuAndGpuImprovementPercent = Get-LowerIsBetterImprovementPercent `
                $A.Aggregate.P95CpuAndGpuMs $B.Aggregate.P95CpuAndGpuMs
        StaleImprovementPercent = Get-LowerIsBetterImprovementPercent `
                $A.Aggregate.MeanStaleAtStableRefresh $B.Aggregate.MeanStaleAtStableRefresh
        OverallStaleImprovementPercent = Get-LowerIsBetterImprovementPercent `
                $A.Aggregate.MeanStalePerSecond $B.Aggregate.MeanStalePerSecond
        MeanFpsChangePercent = Get-HigherIsBetterChangePercent `
                $A.Aggregate.MeanAppFps $B.Aggregate.MeanAppFps
        P10ChangePercent = Get-HigherIsBetterChangePercent `
                $A.Aggregate.P10AppFps $B.Aggregate.P10AppFps
    }
}

function Get-AbDecision {
    param(
        [Parameter(Mandatory)][object[]] $AReports,
        [Parameter(Mandatory)][object[]] $BReports,
        [Parameter(Mandatory)][string] $ExpectedBaselineSha256,
        [Parameter(Mandatory)][string] $ExpectedCandidateSha256,
        [Parameter(Mandatory)] $ExpectedLabApkIdentity
    )
    Require ($AReports.Count -eq 3 -and $BReports.Count -eq 3) `
            'Exactly three A and three B reports are required.'
    Require ((Normalize-Sha256 $ExpectedBaselineSha256) -eq $script:BaselineSha256) `
            'Decision baseline is not the exact accepted v68 core.'
    Require ((Normalize-Sha256 $ExpectedCandidateSha256) -eq
            $script:ExpectedCopyBatchJarSha256) `
            'Decision candidate is not the pinned Copy Batch JAR.'

    $fingerprints = @($AReports + $BReports | ForEach-Object {
            [string]$_.Protocol.OtherModsFingerprintSha256
        } | Sort-Object -Unique)
    Require ($fingerprints.Count -eq 1 -and $fingerprints[0] -match '^[0-9A-Fa-f]{64}$') `
            'The one-variable stack fingerprint changed across retained reports.'

    $pairs = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt 3; $index++) {
        $pair = $index + 1
        Assert-RetainedReport $AReports[$index] 'A' $pair $ExpectedBaselineSha256 `
                $script:BaselineMode $ExpectedLabApkIdentity
        Assert-RetainedReport $BReports[$index] 'B' $pair $ExpectedCandidateSha256 `
                $script:OnMode $ExpectedLabApkIdentity
        $comparison = Compare-Pair $AReports[$index] $BReports[$index]
        $pairs.Add([pscustomobject]@{
            Pair = $pair
            Comparable = $comparison.Comparable
            InvalidReasons = $comparison.InvalidReasons
            StartTemperatureDeltaC = $comparison.StartTemperatureDeltaC
            ThermalPathDeltaC = $comparison.ThermalPathDeltaC
            MaximumThermalPathDeltaC = $comparison.MaximumThermalPathDeltaC
            Refresh = $comparison.Refresh
            P95CpuAndGpuImprovementPercent = $comparison.P95CpuAndGpuImprovementPercent
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
    $p95Final = $p95Improvement -ge $script:FinalP95ImprovementPercent -and
            $p95PairWins -ge $script:RequiredSignalPairWins
    $staleFinal = $staleImprovement -ge $script:FinalStaleImprovementPercent -and
            $stalePairWins -ge $script:RequiredSignalPairWins
    $finalPass = $allComparable -and $guardrailsPass -and ($p95Final -or $staleFinal)

    $reasons = New-Object Collections.Generic.List[string]
    if (-not $allComparable) {
        $reasons.Add('One or more retained A/B pairs are not comparable.')
    }
    if (-not $aggregateGuardrailsPass) {
        $reasons.Add('Aggregate mean FPS or P10 regressed beyond one percent.')
    }
    if (-not $everyPairGuardrailsPass) {
        $reasons.Add('At least one pair regressed mean FPS or P10 beyond one percent.')
    }
    if (-not ($p95Final -or $staleFinal)) {
        $reasons.Add(
                'Neither P95 >=3% nor stable-refresh stale >=10% also won at least two of three pairs.')
    }

    return [pscustomobject]@{
        SchemaVersion = 3
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Package = $script:Package
        Profile = $script:Profile
        World = $script:World
        Order = 'A1-B1-B2-A2-A3-B3'
        ComparisonPurpose = 'exact-v68-vs-copy-batch-on'
        ExactV68Comparison = $true
        SameJarBothConditions = $false
        BaselineSha256 = $ExpectedBaselineSha256
        CandidateSha256 = $ExpectedCandidateSha256
        ConditionModes = [pscustomobject]@{
            A = $script:BaselineMode
            B = $script:OnMode
        }
        LabApk = Copy-LabApkIdentity $ExpectedLabApkIdentity
        PairComparisons = $pairs.ToArray()
        Aggregate = [pscustomobject]@{
            V68MeanFps = Round-Value $aMean 2
            CandidateMeanFps = Round-Value $bMean 2
            MeanFpsChangePercent = Round-Value $meanChange 2
            V68MeanP10Fps = Round-Value $aP10 2
            CandidateMeanP10Fps = Round-Value $bP10 2
            P10ChangePercent = Round-Value $p10Change 2
            V68StableRefreshStalePerSecond = Round-Value $aStale 2
            CandidateStableRefreshStalePerSecond = Round-Value $bStale 2
            StableRefreshStaleImprovementPercent = Round-Value $staleImprovement 2
            StableRefreshStalePairWins = $stalePairWins
            V68OverallStalePerSecond = Round-Value $aOverallStale 2
            CandidateOverallStalePerSecond = Round-Value $bOverallStale 2
            OverallStaleImprovementPercent = Round-Value `
                    (Get-LowerIsBetterImprovementPercent $aOverallStale $bOverallStale) 2
            V68P95CpuAndGpuMs = Round-Value $aP95 2
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
            FinalV69P95ThresholdPercent = $script:FinalP95ImprovementPercent
            FinalV69StableRefreshStaleThresholdPercent =
                    $script:FinalStaleImprovementPercent
            FinalV69PerformanceGatePass = $finalPass
            Decision = if ($finalPass) {
                'ACCEPT_COPY_BATCH_FOR_V69'
            } else {
                'REJECT_OR_REPEAT'
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

function New-SyntheticReport {
    param(
        [string] $Condition, [int] $Pair, [string] $CoreSha,
        [double] $MeanFps, [double] $P10, [double] $Stale, [double] $P95,
        [double] $Temp, [double] $Hz = 72.0
    )
    $mode = Get-ConditionMode $Condition
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
            DisplayRefreshDistribution = @([pscustomobject]@{ Hz = $Hz; Count = 60; Percent = 100.0 })
            RefreshTransitionCount = 0
            FirstTempC = $Temp
            MeanTempC = $Temp
            LastTempC = $Temp
            MaxTempC = $Temp
        }
        Protocol = [pscustomobject]@{
            SchemaVersion = 3
            Condition = $Condition
            Pair = $Pair
            Attempt = 1
            CoreSha256 = $CoreSha
            OpenXrCopyBatchMode = $mode
            RuntimeModeMarker = Get-ModeRuntimeMarker $mode
            ExactV68Comparison = $true
            SameJarBothConditions = $false
            LabApk = Copy-LabApkIdentity $script:LabApkIdentity
            OtherModsFingerprintSha256 = ('C' * 64)
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
    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $forbiddenStable = 'com.qcxr.qcxr.' + 'dev262'
    $forbiddenClear = 'pm' + ' clear'
    $forbiddenRemoval = 'unin' + 'stall'
    $forbiddenRootShell = 'su ' + '-c'
    Require (-not $source.Contains($forbiddenStable)) `
            'The accepted Personal package appeared in the exact-v68 orchestrator.'
    Require (-not $source.Contains($forbiddenClear)) 'A data-clear command appeared in the orchestrator.'
    Require (-not $source.Contains($forbiddenRemoval)) `
            'A package-removal command appeared in the orchestrator.'
    Require (-not $source.Contains($forbiddenRootShell)) 'A root command appeared in the orchestrator.'
    Require ($source.Contains("if (`$Condition -ceq 'B')")) `
            'The round runner does not isolate candidate deployment to condition B.'
    Require ($source.Contains('Invoke-CoreDeploy $Candidate $script:OnMode')) `
            'Condition B does not deploy the exact ON candidate.'
    Require ($source.Contains('$expectedCore = $script:BaselineSha256')) `
            'Condition A is not pinned to the exact v68 rollback core.'
    Require ($source.Contains(
            'Wait-LabWorldReady $launchEpoch $script:BaselineMode')) `
            'Condition A does not prove that candidate runtime markers are absent.'
    Require ($source.Contains('Wait-LabWorldReady $launchEpoch $script:OnMode')) `
            'Condition B does not require the exact Copy Batch ON runtime marker.'
    Require ($source.Contains("'-OpenXrCopyBatchMode', `$Mode")) `
            'Candidate deployment does not pass the exact one-shot mode.'
    Require ($source.Contains('! grep -F -q $qOppositeMarker')) `
            'Candidate runtime proof does not reject the opposite marker.'

    $apkGateIndex = $source.IndexOf(
            '$script:LabApkIdentity = Get-InstalledLabApkIdentity',
            [StringComparison]::Ordinal)
    $manifestIndex = $source.IndexOf('$manifest = New-RunManifest', $apkGateIndex,
            [StringComparison]::Ordinal)
    $roundIndex = $source.IndexOf('Invoke-Pair $pair', $manifestIndex,
            [StringComparison]::Ordinal)
    Require ($apkGateIndex -ge 0 -and $manifestIndex -gt $apkGateIndex -and
            $roundIndex -gt $manifestIndex) `
            'Run does not verify the installed Lab APK before manifest creation and rounds.'
    Require ($source.Contains('LabApk = Copy-LabApkIdentity')) `
            'Exact-v68 evidence does not bind the installed Lab APK identity.'
    Require ($source.Contains('-ExpectedSignerSha256 $script:ExpectedLabSignerSha256')) `
            'Installed Lab APK verification does not pin the accepted signer.'
    Require ($source.Contains("`$conditionOrder = if (`$Pair -eq 2) { @('B', 'A') }")) `
            'Exact-v68 A/B order is not counterbalanced AB/BA/AB.'

    $normalizedShell = ConvertTo-DeviceShellCommand "set -eu`r`nprintf 'ok'`r"
    Require (-not $normalizedShell.Contains("`r") -and
            $normalizedShell -ceq "set -eu`nprintf 'ok'`n") `
            'Device shell command normalization did not remove CR line endings.'
    $stageTagged = $false
    try { Invoke-AbStage 'synthetic-stage' { throw 'synthetic failure' } | Out-Null }
    catch {
        $stageTagged = $_.Exception.Message -ceq `
                "A/B stage 'synthetic-stage' failed. synthetic failure"
    }
    Require $stageTagged 'A/B stage failures are not labeled without raw device output.'

    $allowedOutput = Join-Path $script:WorkspaceRoot 'artifacts\benchmarks\selftest-exact-v68'
    Require ((Resolve-OutputDirectory $allowedOutput) -eq [IO.Path]::GetFullPath($allowedOutput)) `
            'The aggregate-output allowlist rejected its fixed artifact root.'
    $sourceOutputRejected = $false
    try { Resolve-OutputDirectory (Join-Path $script:RepoRoot 'forbidden-results') | Out-Null }
    catch { $sourceOutputRejected = $true }
    Require $sourceOutputRejected 'Aggregate output inside the source worktree was accepted.'

    $baseline = $script:BaselineSha256
    $candidate = $script:ExpectedCopyBatchJarSha256
    $a = @()
    $b = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $temperature = 42.0 + ($pair * 0.1)
        $a += New-SyntheticReport A $pair $baseline 70.0 67.0 5.0 15.0 $temperature
        $b += New-SyntheticReport B $pair $candidate 70.2 67.2 4.4 14.5 ($temperature + 0.3)
    }
    $decision = Get-AbDecision $a $b $baseline $candidate $script:LabApkIdentity
    Require $decision.Gates.FinalV69PerformanceGatePass `
            'A valid exact-v68 Copy Batch win was rejected.'
    Require ($decision.Gates.Decision -ceq 'ACCEPT_COPY_BATCH_FOR_V69') `
            'A valid exact-v68 win did not receive the final acceptance decision.'
    Require ($decision.Aggregate.P95CpuAndGpuPairWins -eq 3 -and
            $decision.Aggregate.StableRefreshStalePairWins -eq 3) `
            'Synthetic metric signal-win counts are wrong.'
    Require ($decision.BaselineSha256 -eq $baseline -and
            $decision.CandidateSha256 -eq $candidate) `
            'Decision evidence did not preserve distinct baseline/candidate hashes.'
    Require ($decision.ConditionModes.A -ceq $script:BaselineMode -and
            $decision.ConditionModes.B -ceq $script:OnMode -and
            -not $decision.SameJarBothConditions) `
            'The exact-v68 A/B condition mapping changed.'
    Assert-LabApkIdentityContract $decision.LabApk $script:LabApkIdentity

    $syntheticCandidate = [pscustomobject]@{
        Path = 'host-only-selftest.jar'
        Sha256 = $candidate
        SizeBytes = 8389098
        FabricVersion = '26.2-1.3.15'
    }
    $manifest = New-RunManifest $syntheticCandidate
    Assert-RunManifest $manifest $syntheticCandidate
    Require ([int]$manifest.SchemaVersion -eq 3 -and
            [string]$manifest.BaselineSha256 -ceq $baseline -and
            [string]$manifest.CandidateSha256 -ceq $candidate -and
            -not [bool]$manifest.ConditionARuntimeMarkerRequired -and
            [string]$manifest.ConditionBRuntimeMarker -ceq $script:OnRuntimeMarker) `
            'Run manifest did not encode the exact-v68/no-marker versus candidate/ON contract.'

    $p95OnlyB = @()
    $staleOnlyB = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $temperature = 42.3 + ($pair * 0.1)
        $p95OnlyB += New-SyntheticReport B $pair $candidate 70.1 67.1 5.0 14.4 `
                $temperature
        $staleOnlyB += New-SyntheticReport B $pair $candidate 70.1 67.1 4.4 15.0 `
                $temperature
    }
    Require (Get-AbDecision $a $p95OnlyB $baseline $candidate `
            $script:LabApkIdentity).Gates.FinalV69PerformanceGatePass `
            'The independent >=3-percent P95 acceptance path was rejected.'
    Require (Get-AbDecision $a $staleOnlyB $baseline $candidate `
            $script:LabApkIdentity).Gates.FinalV69PerformanceGatePass `
            'The independent >=10-percent stable-refresh stale path was rejected.'

    $roundedOnlyB = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $roundedOnlyB += New-SyntheticReport B $pair $candidate 70.0 67.0 5.0 `
                14.55015 (42.3 + ($pair * 0.1))
    }
    Require (-not (Get-AbDecision $a $roundedOnlyB $baseline $candidate `
            $script:LabApkIdentity).Gates.FinalV69PerformanceGatePass) `
            'A sub-three-percent P95 result was accepted after display rounding.'

    $mismatched = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4 90.0
    Require (-not (Compare-Pair $a[0] $mismatched).Comparable) `
            'A mismatched refresh distribution was accepted.'
    $hot = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 44.0
    Require (-not (Compare-Pair $a[0] $hot).Comparable) `
            'A mismatched start temperature was accepted.'
    $transitionMismatch = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $transitionMismatch.Aggregate.RefreshTransitionCount = 3
    Require (-not (Compare-Pair $a[0] $transitionMismatch).Comparable) `
            'A mismatched Dynamic-refresh transition exposure was accepted.'
    $thermalMismatch = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $thermalMismatch.Aggregate.MaxTempC = 44.0
    Require (-not (Compare-Pair $a[0] $thermalMismatch).Comparable) `
            'A mismatched in-sample thermal path was accepted.'
    $thermalRoundingEdge = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.1
    $thermalRoundingEdge.Aggregate.MaxTempC = 43.14
    Require (-not (Compare-Pair $a[0] $thermalRoundingEdge).Comparable) `
            'An over-limit thermal path was accepted after display rounding.'
    $attemptMismatch = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $attemptMismatch.Protocol.Attempt = 2
    Require (-not (Compare-Pair $a[0] $attemptMismatch).Comparable) `
            'Reports from different bounded attempts were paired.'

    $oneSignalB = @(
        (New-SyntheticReport B 1 $candidate 70.0 67.0 4.9 12.0 42.4),
        (New-SyntheticReport B 2 $candidate 70.0 67.0 4.9 15.2 42.5),
        (New-SyntheticReport B 3 $candidate 70.0 67.0 4.9 15.2 42.6)
    )
    Require (-not (Get-AbDecision $a $oneSignalB $baseline $candidate `
            $script:LabApkIdentity).Gates.FinalV69PerformanceGatePass) `
            'A strong aggregate with fewer than two P95 signal wins was accepted.'

    $pairRegressionB = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $fps = if ($pair -eq 1) { 69.0 } else { 70.7 }
        $p10 = if ($pair -eq 1) { 66.0 } else { 67.7 }
        $pairRegressionB += New-SyntheticReport B $pair $candidate $fps $p10 4.3 14.3 `
                (42.3 + ($pair * 0.1))
    }
    $pairRegression = Get-AbDecision $a $pairRegressionB $baseline $candidate `
            $script:LabApkIdentity
    Require (-not $pairRegression.Gates.FinalV69PerformanceGatePass -and
            -not $pairRegression.Gates.EveryPairGuardrailsPass) `
            'A candidate violating a per-pair FPS/P10 guardrail was accepted.'

    $aggregateRegressionB = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $aggregateRegressionB += New-SyntheticReport B $pair $candidate 69.0 66.0 4.3 14.3 `
                (42.3 + ($pair * 0.1))
    }
    $aggregateRegression = Get-AbDecision $a $aggregateRegressionB $baseline $candidate `
            $script:LabApkIdentity
    Require (-not $aggregateRegression.Gates.FinalV69PerformanceGatePass -and
            -not $aggregateRegression.Gates.AggregateGuardrailsPass) `
            'A candidate violating aggregate FPS/P10 guardrails was accepted.'

    $wrongBaseline = New-SyntheticReport A 1 $candidate 70.0 67.0 5.0 15.0 42.1
    $wrongBaselineRejected = $false
    try {
        Assert-RetainedReport $wrongBaseline 'A' 1 $baseline $script:BaselineMode `
                $script:LabApkIdentity
    } catch { $wrongBaselineRejected = $true }
    Require $wrongBaselineRejected 'Condition A accepted a non-v68 core hash.'

    $wrongCandidate = New-SyntheticReport B 1 $baseline 70.2 67.2 4.4 14.5 42.4
    $wrongCandidateRejected = $false
    try {
        Assert-RetainedReport $wrongCandidate 'B' 1 $candidate $script:OnMode `
                $script:LabApkIdentity
    } catch { $wrongCandidateRejected = $true }
    Require $wrongCandidateRejected 'Condition B accepted a non-candidate core hash.'

    $baselineWithMarker = New-SyntheticReport A 1 $baseline 70.0 67.0 5.0 15.0 42.1
    $baselineWithMarker.Protocol.RuntimeModeMarker = $script:OnRuntimeMarker
    $baselineMarkerRejected = $false
    try {
        Assert-RetainedReport $baselineWithMarker 'A' 1 $baseline $script:BaselineMode `
                $script:LabApkIdentity
    } catch { $baselineMarkerRejected = $true }
    Require $baselineMarkerRejected 'Condition A accepted a candidate runtime marker.'

    $candidateWithoutMarker = New-SyntheticReport B 1 $candidate 70.2 67.2 4.4 14.5 42.4
    $candidateWithoutMarker.Protocol.RuntimeModeMarker = $null
    $candidateMarkerRejected = $false
    try {
        Assert-RetainedReport $candidateWithoutMarker 'B' 1 $candidate $script:OnMode `
                $script:LabApkIdentity
    } catch { $candidateMarkerRejected = $true }
    Require $candidateMarkerRejected 'Condition B accepted a missing ON runtime marker.'

    $wrongApk = New-SyntheticReport A 1 $baseline 70.0 67.0 5.0 15.0 42.1
    $wrongApk.Protocol.LabApk.BaseApkSha256 = ('E' * 64)
    $wrongApkRejected = $false
    try {
        Assert-RetainedReport $wrongApk 'A' 1 $baseline $script:BaselineMode `
                $script:LabApkIdentity
    } catch { $wrongApkRejected = $true }
    Require $wrongApkRejected 'A report from a different installed Lab APK was accepted.'

    $weakCoverage = New-SyntheticReport A 1 $baseline 70.0 67.0 5.0 15.0 42.1
    $weakCoverage.SampleCoveragePercent = 94.9
    $weakCoverageRejected = $false
    try {
        Assert-RetainedReport $weakCoverage 'A' 1 $baseline $script:BaselineMode `
                $script:LabApkIdentity
    } catch { $weakCoverageRejected = $true }
    Require $weakCoverageRejected 'A report below 95-percent sample coverage was accepted.'

    $weakLevels = New-SyntheticReport A 1 $baseline 70.0 67.0 5.0 15.0 42.1
    $weakLevels.Aggregate.GpuLevel4Percent = 94.9
    $weakLevelsRejected = $false
    try {
        Assert-RetainedReport $weakLevels 'A' 1 $baseline $script:BaselineMode `
                $script:LabApkIdentity
    } catch { $weakLevelsRejected = $true }
    Require $weakLevelsRejected `
            'A report below 95-percent CPU/GPU level-4 coverage was accepted.'

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ('quest-v69-exact-v68-selftest-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $lockPath = $null
    try {
        for ($pair = 1; $pair -le 3; $pair++) {
            Save-JsonAtomic $a[$pair - 1] (Join-Path $temporaryRoot "A$pair.json") | Out-Null
            Save-JsonAtomic $b[$pair - 1] (Join-Path $temporaryRoot "B$pair.json") | Out-Null
        }
        $roundTrip = Get-ReportSet $temporaryRoot $baseline $candidate $script:LabApkIdentity
        Require $roundTrip.Gates.FinalV69PerformanceGatePass `
                'Aggregate JSON round-trip changed the final exact-v68 decision.'
        Save-ExcludedAttempt $temporaryRoot 1 1 $null $null @('first synthetic exclusion')
        Save-ExcludedAttempt $temporaryRoot 1 1 $null $null @('resumed synthetic exclusion')
        $excludedRecords = @(Get-ChildItem -LiteralPath (Join-Path $temporaryRoot 'excluded') `
                -Filter 'pair1-attempt1*-rejection.json')
        Require ($excludedRecords.Count -eq 2 -and
                @($excludedRecords.Name | Where-Object {
                    $_ -match '-rerun1-rejection\.json$'
                }).Count -eq 1) `
                'Resumed exclusions overwrote earlier aggregate evidence.'

        $staleLock = Join-Path $temporaryRoot '.quest-v69-exact-v68.lock'
        [IO.File]::WriteAllText($staleLock, 'stale', (New-Object Text.UTF8Encoding($false)))
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

    Require ($script:DeviceInvocationCount -eq $before) 'SelfTest invoked a device command.'
    return [pscustomobject]@{
        Result = 'PASS'
        Assertions = 48
        Package = $script:Package
        Order = 'A1-B1-B2-A2-A3-B3'
        ConditionA = 'exact-v68-no-mode-marker'
        ConditionB = 'copy-batch-candidate-on'
        BaselineSha256 = $baseline
        CandidateSha256 = $candidate
        PairTemperatureLimitC = $MaximumStartTemperatureDeltaC
        RefreshDistributionLimitPercent = $MaximumRefreshDistributionDistancePercent
        FinalP95ThresholdPercent = $script:FinalP95ImprovementPercent
        FinalStableRefreshStaleThresholdPercent = $script:FinalStaleImprovementPercent
        RequiredSignalPairWins = $script:RequiredSignalPairWins
        GuardrailPercent = $MaximumGuardrailRegressionPercent
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

function Invoke-CoreRollback {
    $arguments = @('-Action', 'Rollback', '-Serial', $script:ResolvedSerial,
        '-AdbPath', $script:ResolvedAdb, '-AllowDeviceWrite')
    $null = Invoke-Helper $script:CoreScript $arguments
}

function Invoke-CoreDeploy(
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)][string] $Mode) {
    $null = Get-ModeRuntimeMarker $Mode
    $arguments = @('-Action', 'Deploy', '-Serial', $script:ResolvedSerial,
        '-AdbPath', $script:ResolvedAdb, '-AllowDeviceWrite', '-JarPath', $Candidate.Path,
        '-ExpectedSha256', $Candidate.Sha256, '-OpenXrCopyBatchMode', $Mode,
        '-ExpiryMinutes', '15')
    $null = Invoke-Helper $script:CoreScript $arguments
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

function Wait-LabWorldReady([int64] $LaunchEpoch, [string] $Mode = '') {
    $log = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/logs/latest.log"
    $expectedMarker = $null
    $oppositeMarker = $null
    $baselineWithoutMarker = $Mode -ceq $script:BaselineMode
    if ($Mode -ceq $script:OnMode) {
        $expectedMarker = Get-ModeRuntimeMarker $Mode
        $oppositeMarker = $script:CandidateOffRuntimeMarker
    } elseif (-not $baselineWithoutMarker -and
            -not [string]::IsNullOrWhiteSpace($Mode)) {
        throw 'World-ready mode must be empty, V68_DEFAULT, or ON.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($script:ReadyTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $qPackage = ConvertTo-ShLiteral $script:Package
        $qLog = ConvertTo-ShLiteral $log
        $command = "pidof $qPackage >/dev/null 2>&1 && test -f $qLog && " +
                "test `"`$(stat -c %Y $qLog)`" -ge $LaunchEpoch && " +
                "test `"`$(grep -c -E 'Loaded [0-9]+ advancements' $qLog)`" -ge 2"
        if ($null -ne $expectedMarker) {
            $qExpectedMarker = ConvertTo-ShLiteral $expectedMarker
            $qOppositeMarker = ConvertTo-ShLiteral $oppositeMarker
            $command += " && grep -F -q $qExpectedMarker $qLog" +
                    " && ! grep -F -q $qOppositeMarker $qLog"
        } elseif ($baselineWithoutMarker) {
            $qOnMarker = ConvertTo-ShLiteral $script:OnRuntimeMarker
            $qOffMarker = ConvertTo-ShLiteral $script:CandidateOffRuntimeMarker
            $command += " && ! grep -F -q $qOnMarker $qLog" +
                    " && ! grep -F -q $qOffMarker $qLog"
        }
        $ready = Invoke-DeviceShell $command -AllowFailure
        if ($ready.ExitCode -eq 0 -and (Test-LabFocused)) { return $expectedMarker }
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

function Get-LabCoreState {
    $files = "/sdcard/Android/data/$script:Package/files"
    $game = "$files/instances/$script:Profile"
    $mods = "$game/mods"
    $target = "$mods/Vivecraft.jar"
    $command = @"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files))
game=`$(realpath $(ConvertTo-ShLiteral $game))
mods=`$(realpath $(ConvertTo-ShLiteral $mods))
test "`$game" = "`$files/instances/$script:Profile"
test "`$mods" = "`$game/mods"
target="`$mods/Vivecraft.jar"
test -f "`$target" && test ! -L "`$target"
printf 'TARGET\t%s\n' "`$(sha256sum "`$target" | awk '{print toupper(`$1)}')"
(
  for file in "`$mods"/*.jar; do
    [ -e "`$file" ] || continue
    [ "`$file" = "`$target" ] && continue
    test -f "`$file" && test ! -L "`$file"
    name=`${file##*/}
    hash=`$(sha256sum "`$file" | awk '{print toupper(`$1)}')
    printf '%s\t%s\n' "`$name" "`$hash"
  done
) | LC_ALL=C sort | sha256sum | awk '{print "FINGERPRINT\t" toupper(`$1)}'
"@
    $result = Invoke-DeviceShell $command
    $targetRow = @($result.Lines | Where-Object { $_ -match '^TARGET\t(?<sha>[0-9A-F]{64})$' })
    Require ($targetRow.Count -eq 1) 'Could not resolve the exact Lab Vivecraft hash.'
    $null = $targetRow[0] -match '^TARGET\t(?<sha>[0-9A-F]{64})$'
    $targetSha = $Matches.sha
    $fingerprintRow = @($result.Lines | Where-Object { $_ -match '^FINGERPRINT\t(?<sha>[0-9A-F]{64})$' })
    Require ($fingerprintRow.Count -eq 1) 'Could not resolve the Lab other-mod fingerprint.'
    $null = $fingerprintRow[0] -match '^FINGERPRINT\t(?<sha>[0-9A-F]{64})$'
    return [pscustomobject]@{ TargetSha256 = $targetSha; OtherModsFingerprintSha256 = $Matches.sha }
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
    Invoke-AbStage 'core-rollback' { Invoke-CoreRollback } | Out-Null
    Invoke-AbStage 'world-reset' { Invoke-WorldReset } | Out-Null
    $mode = Get-ConditionMode $Condition
    $expectedCore = $script:BaselineSha256
    if ($Condition -ceq 'B') {
        Invoke-AbStage 'core-deploy-on' {
            Invoke-CoreDeploy $Candidate $script:OnMode
        } | Out-Null
        $expectedCore = $Candidate.Sha256
    }
    $launchEpoch = Invoke-AbStage 'autoplay-launch' { Start-LabAutoplay }
    $runtimeModeMarker = if ($Condition -ceq 'B') {
        Invoke-AbStage 'world-ready-on-marker' {
            Wait-LabWorldReady $launchEpoch $script:OnMode
        }
    } else {
        Invoke-AbStage 'world-ready-v68-no-marker' {
            Wait-LabWorldReady $launchEpoch $script:BaselineMode
        }
    }
    $core = Invoke-AbStage 'core-state' { Get-LabCoreState }
    Require ($core.TargetSha256 -eq $expectedCore) `
            'The running Lab process did not load the intended core hash.'
    Invoke-AbStage 'warmup' { Wait-HealthyInterval $WarmupSeconds "Warm-up $Condition$Pair" } | Out-Null
    $preflight = Invoke-AbStage 'thermal-preflight' {
        Invoke-AggregateCapture $script:PreflightSeconds
    }
    Assert-CaptureGate $preflight "Thermal preflight $Condition$Pair"
    $sample = Invoke-AbStage 'sample-capture' {
        Invoke-AggregateCapture $script:SampleSeconds
    }
    Assert-CaptureGate $sample "Sample $Condition$Pair"
    $sample | Add-Member -NotePropertyName Protocol -NotePropertyValue ([pscustomobject]@{
        SchemaVersion = 3
        Condition = $Condition
        Pair = $Pair
        Attempt = $Attempt
        CoreSha256 = $expectedCore
        OpenXrCopyBatchMode = $mode
        RuntimeModeMarker = $runtimeModeMarker
        ExactV68Comparison = $true
        SameJarBothConditions = $false
        LabApk = Copy-LabApkIdentity $script:LabApkIdentity
        OtherModsFingerprintSha256 = $core.OtherModsFingerprintSha256
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
                    Invoke-AbStage 'inter-round-rollback' { Invoke-CoreRollback } | Out-Null
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
            try { Invoke-CoreRollback } catch { Write-Warning 'Could not prove baseline rollback during cleanup.' }
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
        SchemaVersion = 3
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Package = $script:Package
        Profile = $script:Profile
        World = $script:World
        WorldMasterSha256 = $script:WorldMasterSha256
        Order = @('A1','B1','B2','A2','A3','B3')
        ComparisonPurpose = 'exact-v68-vs-copy-batch-on'
        ExactV68Comparison = $true
        SameJarBothConditions = $false
        BaselineSha256 = $script:BaselineSha256
        CandidateSha256 = $Candidate.Sha256
        PinnedCopyBatchJarSha256 = $script:ExpectedCopyBatchJarSha256
        ConditionModes = [pscustomobject]@{
            A = $script:BaselineMode
            B = $script:OnMode
        }
        ConditionARuntimeMarkerRequired = $false
        ConditionBRuntimeMarker = $script:OnRuntimeMarker
        LabApk = Copy-LabApkIdentity $script:LabApkIdentity
        CandidateSizeBytes = $Candidate.SizeBytes
        CandidateFabricVersion = $Candidate.FabricVersion
        WarmupSeconds = $WarmupSeconds
        PreflightSeconds = $script:PreflightSeconds
        SampleSeconds = $script:SampleSeconds
        MaximumStartTemperatureDeltaC = $MaximumStartTemperatureDeltaC
        MaximumRefreshDistributionDistancePercent =
                $MaximumRefreshDistributionDistancePercent
        MaximumRefreshMeanDeltaHz = $MaximumRefreshMeanDeltaHz
        MaximumRefreshTransitionDelta = $script:MaximumRefreshTransitionDelta
        MaximumThermalPathDeltaC = $script:MaximumThermalPathDeltaC
        MinimumSampleCoveragePercent = $script:MinimumSampleCoveragePercent
        MinimumPerformanceLevelPercent = $script:MinimumPerformanceLevelPercent
        P95PairSignalFloorPercent = $script:P95PairSignalFloorPercent
        StableRefreshStalePairSignalFloorPercent = $script:StalePairSignalFloorPercent
        RequiredSignalPairWins = $script:RequiredSignalPairWins
        FinalP95ImprovementPercent = $script:FinalP95ImprovementPercent
        FinalStableRefreshStaleImprovementPercent =
                $script:FinalStaleImprovementPercent
        MaximumGuardrailRegressionPercent = $MaximumGuardrailRegressionPercent
        QgoPolicy = 'Dynamic CPU4/GPU4'
        SerialPersisted = $false
        RawLogsPersisted = $false
    }
}

function Assert-RunManifest([Parameter(Mandatory)] $Manifest, [Parameter(Mandatory)] $Candidate) {
    Require ([int]$Manifest.SchemaVersion -eq 3) 'Run manifest schema mismatch.'
    Require ([string]$Manifest.ComparisonPurpose -ceq
            'exact-v68-vs-copy-batch-on' -and
            [bool]$Manifest.ExactV68Comparison -and
            -not [bool]$Manifest.SameJarBothConditions) `
            'Run manifest is not an exact-v68 final confirmation.'
    Require ([string]$Manifest.Package -ceq $script:Package) 'Run manifest package mismatch.'
    Require ([string]$Manifest.Profile -ceq $script:Profile) 'Run manifest profile mismatch.'
    Require ([string]$Manifest.World -ceq $script:World) 'Run manifest world mismatch.'
    Require ((@($Manifest.Order) -join '-') -ceq 'A1-B1-B2-A2-A3-B3') `
            'Run manifest is not counterbalanced AB/BA/AB.'
    Require ((Normalize-Sha256 ([string]$Manifest.BaselineSha256)) -eq
            $script:BaselineSha256) 'Run manifest exact-v68 baseline mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.CandidateSha256)) -eq
            $Candidate.Sha256) 'Run manifest candidate mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.PinnedCopyBatchJarSha256)) -eq
            $script:ExpectedCopyBatchJarSha256) `
            'Run manifest Copy Batch candidate pin mismatch.'
    Require ([int64]$Manifest.CandidateSizeBytes -eq [int64]$Candidate.SizeBytes -and
            [string]$Manifest.CandidateFabricVersion -ceq
            [string]$Candidate.FabricVersion) `
            'Run manifest candidate metadata mismatch.'
    Require ([string]$Manifest.ConditionModes.A -ceq $script:BaselineMode -and
            [string]$Manifest.ConditionModes.B -ceq $script:OnMode -and
            -not [bool]$Manifest.ConditionARuntimeMarkerRequired -and
            [string]$Manifest.ConditionBRuntimeMarker -ceq
            $script:OnRuntimeMarker) `
            'Run manifest A/B runtime mapping changed.'
    Assert-LabApkIdentityContract $Manifest.LabApk $script:LabApkIdentity
    Require ([int]$Manifest.WarmupSeconds -eq $WarmupSeconds -and
            [int]$Manifest.PreflightSeconds -eq $script:PreflightSeconds -and
            [int]$Manifest.SampleSeconds -eq $script:SampleSeconds) `
            'Run manifest timing mismatch.'
    Require ([string]$Manifest.WorldMasterSha256 -ceq $script:WorldMasterSha256) `
            'Run manifest world-master mismatch.'
    Require ([double]$Manifest.MaximumStartTemperatureDeltaC -eq
            $MaximumStartTemperatureDeltaC -and
            [double]$Manifest.MaximumRefreshDistributionDistancePercent -eq
            $MaximumRefreshDistributionDistancePercent -and
            [double]$Manifest.MaximumRefreshMeanDeltaHz -eq
            $MaximumRefreshMeanDeltaHz -and
            [int]$Manifest.MaximumRefreshTransitionDelta -eq
            $script:MaximumRefreshTransitionDelta -and
            [double]$Manifest.MaximumThermalPathDeltaC -eq
            $script:MaximumThermalPathDeltaC) `
            'Run manifest refresh/thermal comparison thresholds changed.'
    Require ([double]$Manifest.MinimumSampleCoveragePercent -eq
            $script:MinimumSampleCoveragePercent -and
            [double]$Manifest.MinimumPerformanceLevelPercent -eq
            $script:MinimumPerformanceLevelPercent -and
            [double]$Manifest.P95PairSignalFloorPercent -eq
            $script:P95PairSignalFloorPercent -and
            [double]$Manifest.StableRefreshStalePairSignalFloorPercent -eq
            $script:StalePairSignalFloorPercent -and
            [int]$Manifest.RequiredSignalPairWins -eq
            $script:RequiredSignalPairWins) `
            'Run manifest report-quality/signal gates changed.'
    Require ([double]$Manifest.FinalP95ImprovementPercent -eq
            $script:FinalP95ImprovementPercent -and
            [double]$Manifest.FinalStableRefreshStaleImprovementPercent -eq
            $script:FinalStaleImprovementPercent -and
            [double]$Manifest.MaximumGuardrailRegressionPercent -eq
            $MaximumGuardrailRegressionPercent) `
            'Run manifest final acceptance thresholds changed.'
}


function Acquire-RunLock([string] $Directory) {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $lockPath = Join-Path $Directory '.quest-v69-exact-v68.lock'
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
        ComparisonPurpose = 'exact-v68-vs-copy-batch-on'
        ExactV68Comparison = $true
        SameJarBothConditions = $false
        ConditionA = 'exact accepted v68 rollback; no copy-batch mode marker'
        BaselineSha256 = $script:BaselineSha256
        ConditionB = 'pinned candidate; OpenXR Copy Batch ON marker required'
        CandidateSha256 = $Candidate.Sha256
        PinnedCopyBatchJarSha256 = $script:ExpectedCopyBatchJarSha256
        ExpectedLabApk = [pscustomobject]@{
            Package = $script:Package
            VersionCode = $script:ExpectedLabVersionCode
            VersionName = $script:ExpectedLabVersionName
            SignerSha256 = $script:ExpectedLabSignerSha256
            RequiredGate = 'installed base.apk full Host verification before manifest/rounds'
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
        FinalGate = 'P95 >=3% or stable-refresh stale >=10%, with signal wins in >=2/3 pairs'
        Guardrail = "Mean FPS and P10 each no worse than -$MaximumGuardrailRegressionPercent percent in every pair and aggregate"
        StableSelectable = $true
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
        $manifest = New-RunManifest $Candidate
        if (Test-Path -LiteralPath $manifestPath) {
            Require $Resume 'Output directory already has a run manifest; use -Resume after inspection.'
            Assert-RunManifest (Get-Json $manifestPath) $Candidate
        } else {
            $unexpected = @(Get-ChildItem -Force -LiteralPath $directory |
                    Where-Object { $_.FullName -cne $lockPath })
            Require ($unexpected.Count -eq 0) `
                    'A new run requires an empty aggregate directory (apart from a stale host lock).'
            Save-JsonAtomic $manifest $manifestPath | Out-Null
        }
        for ($pair = 1; $pair -le 3; $pair++) {
            $aPath = Join-Path $directory "A$pair.json"
            $bPath = Join-Path $directory "B$pair.json"
            if ((Test-Path -LiteralPath $aPath) -or (Test-Path -LiteralPath $bPath)) {
                Require $Resume "Pair $pair output already exists; use -Resume only after inspecting it."
                Require ((Test-Path -LiteralPath $aPath) -and (Test-Path -LiteralPath $bPath)) `
                        "Pair $pair is partial; archive it before resuming."
                continue
            }
            Invoke-Pair $pair $Candidate $directory | Out-Null
        }
        $decision = Get-ReportSet $directory $script:BaselineSha256 `
                $Candidate.Sha256 $script:LabApkIdentity
        Save-JsonAtomic $decision (Join-Path $directory 'comparison.json') -Replace | Out-Null

        Stop-Lab
        Invoke-CoreRollback
        Invoke-WorldReset
        $launchEpoch = Start-LabAutoplay
        Wait-LabWorldReady $launchEpoch
        $readyCore = Get-LabCoreState
        Require ($readyCore.TargetSha256 -eq $script:BaselineSha256) `
                'Final ready state is not the exact v68 baseline.'
        return [pscustomobject]@{
            Result = 'COMPLETE'
            OutputDirectory = $directory
            Decision = $decision.Gates.Decision
            FinalV69PerformanceGatePass = $decision.Gates.FinalV69PerformanceGatePass
            LabApk = Copy-LabApkIdentity $script:LabApkIdentity
            LabLeftRunningOnBaseline = $true
            StableTouched = $false
            RawLogsPersisted = $false
        }
    } catch {
        try { Stop-Lab } catch { Write-Warning 'Lab stop failed during failure recovery.' }
        try { Invoke-CoreRollback } catch { Write-Warning 'Baseline rollback failed during failure recovery.' }
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
    $MaximumStartTemperatureDeltaC = [double]$manifest.MaximumStartTemperatureDeltaC
    $MaximumRefreshDistributionDistancePercent =
            [double]$manifest.MaximumRefreshDistributionDistancePercent
    $MaximumRefreshMeanDeltaHz = [double]$manifest.MaximumRefreshMeanDeltaHz
    $MaximumGuardrailRegressionPercent = [double]$manifest.MaximumGuardrailRegressionPercent
    Require ($WarmupSeconds -ge 300 -and
            $MaximumStartTemperatureDeltaC -le 1.0 -and
            $MaximumRefreshDistributionDistancePercent -le 5.0 -and
            $MaximumRefreshMeanDeltaHz -le 0.5 -and
            $MaximumGuardrailRegressionPercent -le 1.0) `
            'Aggregate manifest weakens the fixed exact-v68 quality gates.'
    Require ([int]$manifest.SchemaVersion -eq 3) 'Aggregate manifest schema mismatch.'
    Require ([string]$manifest.ComparisonPurpose -ceq
            'exact-v68-vs-copy-batch-on' -and
            [bool]$manifest.ExactV68Comparison -and
            -not [bool]$manifest.SameJarBothConditions -and
            (@($manifest.Order) -join '-') -ceq 'A1-B1-B2-A2-A3-B3') `
            'Aggregate manifest is not the counterbalanced exact-v68 confirmation.'
    $baseline = Normalize-Sha256 ([string]$manifest.BaselineSha256)
    Require ($baseline -eq $script:BaselineSha256) `
            'Aggregate manifest exact-v68 baseline mismatch.'
    $candidate = Normalize-Sha256 ([string]$manifest.CandidateSha256)
    Require ($candidate -eq $script:ExpectedCopyBatchJarSha256) `
            'Aggregate manifest is not pinned to the exact Copy Batch candidate.'
    Require ((Normalize-Sha256 ([string]$manifest.PinnedCopyBatchJarSha256)) -eq
            $script:ExpectedCopyBatchJarSha256) `
            'Aggregate manifest copy-batch pin mismatch.'
    Require ([string]$manifest.ConditionModes.A -ceq $script:BaselineMode -and
            [string]$manifest.ConditionModes.B -ceq $script:OnMode -and
            -not [bool]$manifest.ConditionARuntimeMarkerRequired -and
            [string]$manifest.ConditionBRuntimeMarker -ceq
            $script:OnRuntimeMarker) `
            'Aggregate manifest A/B runtime mapping changed.'
    Require ([double]$manifest.FinalP95ImprovementPercent -eq
            $script:FinalP95ImprovementPercent -and
            [double]$manifest.FinalStableRefreshStaleImprovementPercent -eq
            $script:FinalStaleImprovementPercent -and
            [int]$manifest.RequiredSignalPairWins -eq
            $script:RequiredSignalPairWins) `
            'Aggregate manifest final thresholds changed.'
    Assert-LabApkIdentityContract $manifest.LabApk
    Get-ReportSet $aggregateDirectory $baseline $candidate $manifest.LabApk
    return
}

$candidateContract = Get-CandidateContract
if ($Action -eq 'Plan') {
    Invoke-Plan $candidateContract
    return
}
Invoke-Run $candidateContract
