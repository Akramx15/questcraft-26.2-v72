#requires -Version 7.0
<#
.SYNOPSIS
Captures and analyzes aggregate-only, exact-RC8 Lab render-scale A/B evidence.

.DESCRIPTION
SelfTest is the default and performs no ADB call. Status is Host-only. Capture
is read-only on Quest: it proves the exact RC8 Lab APK/Core/VEQ identity,
proves Stable is stopped, verifies the declared 1.0 or 0.8 render scale, and
invokes quest-vrapi-pid-benchmark.ps1 for the fixed Lab package with QGO
Dynamic refresh semantics. It never installs, launches, stops, roots, or
changes an Android file. Analyze consumes six aggregate receipts in the fixed
AB/BA/AB order and compares only overlapping *observed* refresh-rate strata.
Insufficient refresh overlap or mismatched temperature fails closed.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Status', 'Capture', 'Analyze')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [ValidateRange(10, 300)]
    [int] $Seconds = 60,

    [ValidateRange(1, 6)]
    [int] $SequenceIndex = 1,

    [ValidateSet('', 'A', 'B')]
    [string] $Condition = '',

    [ValidateSet('', '1.0', '0.8')]
    [string] $DeclaredRenderScale = '',

    [ValidateRange(0, 15)]
    [int] $ExpectedCpuLevel = 4,

    [ValidateRange(0, 15)]
    [int] $ExpectedGpuLevel = 4,

    [string] $OutputDirectory = '',
    [string] $InputDirectory = '',
    [string] $OutputJson = '',

    [ValidateRange(10.0, 100.0)]
    [double] $MinimumOverlapPercentPerArm = 50.0,

    [ValidateRange(6, 300)]
    [int] $MinimumOverlapSamplesPerPair = 24,

    [ValidateRange(1, 30)]
    [int] $MinimumSamplesPerStratum = 3,

    [ValidateRange(0.1, 2.0)]
    [double] $MaximumStartTemperatureDeltaC = 1.0,

    [ValidateRange(0.1, 3.0)]
    [double] $MaximumMatchedTemperatureDeltaC = 1.5,

    [switch] $AllowDeviceRead,
    [switch] $ConfirmExactRc8Lab,
    [switch] $AllowHostOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BuildLockPath = Join-Path $script:RepoRoot 'V71_LAB_RC8.lock.json'
$script:BenchmarkPath = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$script:ArtifactRoot = Join-Path $script:RepoRoot 'artifacts\v71-rc8-performance-ab'
$script:BuildLockSha256 = 'BB5147F0B5B0A3AB5C61D7012A821F0C2583BDE76F96F963C19EDDD967177EF7'
$script:BenchmarkSha256 = '7971AADCDBD1E9F8D62F5F58E131326E60310E38124879EB76CDB5A76606EC73'
$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:VersionCode = 71L
$script:VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'
$script:ApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$script:SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:CoreSha256 = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$script:VeqSha256 = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/$($script:Profile)"
$script:CorePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:ConfigPath = "$($script:GameDirectory)/config/vivecraft-client-config.json"
$script:Order = @('A', 'B', 'B', 'A', 'A', 'B')
$script:ScaleByCondition = @{ A = '1.0'; B = '0.8' }
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocations = 0
$script:HostWrites = 0
$script:Assertions = 0
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Require([bool] $ConditionValue, [string] $Message) {
    $script:Assertions++
    if (-not $ConditionValue) { throw "[RC8_PERF_AB] $Message" }
}

function Test-Throws([Parameter(Mandatory)][scriptblock] $Operation) {
    try { & $Operation; return $false } catch { return $true }
}

function Get-TextSha256([Parameter(Mandatory)][string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))
    } finally { $sha.Dispose() }
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-TextSha256 $text
}

function Assert-HostContract {
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262' -and
            $script:StablePackage -ceq 'com.qcxr.qcxr.dev262' -and
            $script:Package -cne $script:StablePackage) `
        'The fixed Lab/Stable boundary drifted.'
    Require (Test-Path -LiteralPath $script:BuildLockPath -PathType Leaf) `
        'The exact RC8 build lock is missing.'
    Require ((Get-NormalizedTextSha256 $script:BuildLockPath) -ceq
            $script:BuildLockSha256) 'The exact RC8 build lock bytes drifted.'
    $lock = Get-Content -Raw -LiteralPath $script:BuildLockPath | ConvertFrom-Json
    Require ([string]$lock.target.package -ceq $script:Package -and
            [string]$lock.target.forbiddenStablePackage -ceq $script:StablePackage -and
            [string]$lock.target.profile -ceq $script:Profile -and
            [int64]$lock.target.versionCode -eq $script:VersionCode -and
            [string]$lock.target.versionName -ceq $script:VersionName -and
            [string]$lock.target.apkSha256 -ceq $script:ApkSha256 -and
            [string]$lock.target.signerSha256 -ceq $script:SignerSha256 -and
            [string]$lock.pair.core.sha256 -ceq $script:CoreSha256 -and
            [string]$lock.pair.veq.sha256 -ceq $script:VeqSha256) `
        'The exact RC8 identity lock drifted.'
    Require (Test-Path -LiteralPath $script:BenchmarkPath -PathType Leaf) `
        'The aggregate VrApi benchmark is missing.'
    Require ((Get-NormalizedTextSha256 $script:BenchmarkPath) -ceq
            $script:BenchmarkSha256) 'The aggregate VrApi benchmark bytes drifted.'
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    if ($AdbPath -cne 'adb') { throw '[RC8_PERF_AB] Explicit ADB path was not found.' }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdk -PathType Leaf) { return $sdk }
    throw '[RC8_PERF_AB] ADB was not found.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $script:DeviceInvocations++
    $lines = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "[RC8_PERF_AB] A read-only ADB probe failed ($exitCode); output suppressed."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Resolve-Device {
    $script:Adb = Resolve-Adb
    $result = Invoke-Adb @('devices')
    $devices = @($result.Lines | ForEach-Object {
        if ([string]$_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') {
            [string]$Matches.serial
        }
    })
    if ($Serial -ceq 'auto') {
        Require ($devices.Count -eq 1) 'Auto selection requires one authorized device.'
        $script:Device = [string]$devices[0]
    } else {
        Require ($devices -ccontains $Serial) 'The requested device is not authorized.'
        $script:Device = $Serial
    }
    $state = Invoke-Adb @('-s', $script:Device, 'get-state')
    Require ((@($state.Lines) -join '').Trim() -ceq 'device') `
        'The selected device is not ready.'
}

function Invoke-Shell([string[]] $Arguments, [switch] $AllowFailure) {
    Invoke-Adb (@('-s', $script:Device, 'shell') + $Arguments) `
        -AllowFailure:$AllowFailure
}

function Get-NonBlankRows([string[]] $Lines) {
    @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-StableStopped {
    $probe = Invoke-Shell @('pidof', $script:StablePackage) -AllowFailure
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($probe.ExitCode -eq 1 -and $rows.Count -eq 0) `
        'Stable must be conclusively stopped; it is never stopped by this tool.'
}

function Read-PackageIdentity([string[]] $Lines) {
    $codes = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionCode=(?<v>[0-9]+)(?:\s|$)')
        if ($match.Success) { [int64]$match.Groups['v'].Value }
    })
    $names = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionName=(?<v>\S+)\s*$')
        if ($match.Success) { [string]$match.Groups['v'].Value }
    })
    Require ($codes.Count -eq 1 -and $names.Count -eq 1) `
        'Installed Lab identity was incomplete or ambiguous.'
    [pscustomobject]@{ VersionCode = $codes[0]; VersionName = $names[0] }
}

function Read-BaseApkPath([string[]] $Lines) {
    $rows = @(Get-NonBlankRows $Lines)
    Require ($rows.Count -eq 1 -and $rows[0] -cmatch
        '^package:(?<p>/data/app/(?:[A-Za-z0-9._~+=-]+/)+base\.apk)$') `
        'Installed Lab did not expose one safe base APK.'
    $path = [string]$Matches.p
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)') -and
            -not $path.Contains('/../', [StringComparison]::Ordinal)) `
        'The base APK path was not bound to Lab.'
    $path
}

function Read-RemoteSha256([string] $Path) {
    $result = Invoke-Shell @('sha256sum', $Path)
    $rows = @(Get-NonBlankRows ([string[]]$result.Lines))
    Require ($rows.Count -eq 1) 'A remote digest was ambiguous.'
    $match = [regex]::Match($rows[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require ($match.Success -and [string]$match.Groups['path'].Value -ceq $Path) `
        'A remote digest named unexpected data.'
    ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RenderScale {
    $result = Invoke-Shell @('cat', $script:ConfigPath)
    $text = @($result.Lines) -join "`n"
    try { $config = $text | ConvertFrom-Json -Depth 100 } catch {
        throw '[RC8_PERF_AB] The Vivecraft configuration was not valid JSON.'
    }
    Require ([regex]::Matches($text,
            '"renderScaleFactor"\s*:',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1) `
        'renderScaleFactor did not occur exactly once in the configuration.'
    $properties = @($config.PSObject.Properties | Where-Object {
        $_.Name -ceq 'renderScaleFactor'
    })
    Require ($properties.Count -eq 1 -and $properties[0].Value -is [string] -and
            [string]$properties[0].Value -cin @('1.0', '0.8')) `
        'renderScaleFactor was missing, duplicated, or outside the fixed A/B pair.'
    [string]$properties[0].Value
}

function Assert-ExactDeviceIdentity([string] $ExpectedScale) {
    Assert-StableStopped
    $package = Invoke-Shell @('dumpsys', 'package', $script:Package)
    $identity = Read-PackageIdentity ([string[]]$package.Lines)
    Require ($identity.VersionCode -eq $script:VersionCode -and
            $identity.VersionName -ceq $script:VersionName) `
        'Installed application is not exact RC8 Lab.'
    $path = Read-BaseApkPath ([string[]](Invoke-Shell @('pm', 'path', $script:Package)).Lines)
    Require ((Read-RemoteSha256 $path) -ceq $script:ApkSha256) `
        'Installed APK is not exact RC8.'
    Require ((Read-RemoteSha256 $script:CorePath) -ceq $script:CoreSha256) `
        'Persistent Core is not exact RC8.'
    Require ((Read-RemoteSha256 $script:VeqPath) -ceq $script:VeqSha256) `
        'Persistent VEQ is not exact RC8.'
    Require ((Read-RenderScale) -ceq $ExpectedScale) `
        'The live render scale does not match the declared A/B condition.'
    [pscustomobject]@{ AllMatched = $true; StableStopped = $true }
}

function Get-CanonicalPath([string] $Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-NoReparsePath([string] $Path) {
    $root = Get-CanonicalPath $script:RepoRoot
    $full = Get-CanonicalPath $Path
    Require ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'A Host path escaped this worktree.'
    $cursor = $root
    $relative = [IO.Path]::GetRelativePath($root, $full)
    foreach ($part in $relative.Split([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            Require (-not ((Get-Item -LiteralPath $cursor -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) 'A Host path contains a reparse point.'
        }
    }
}

function Resolve-ArtifactChild([string] $Path, [switch] $MayBeMissing) {
    Require (-not [string]::IsNullOrWhiteSpace($Path)) 'An explicit artifact path is required.'
    $root = Get-CanonicalPath $script:ArtifactRoot
    $candidate = if ([IO.Path]::IsPathRooted($Path)) {
        Get-CanonicalPath $Path
    } else { Get-CanonicalPath (Join-Path $script:RepoRoot $Path) }
    Require ($candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) `
        'Artifacts must remain under artifacts/v71-rc8-performance-ab.'
    if (-not $MayBeMissing) {
        Require (Test-Path -LiteralPath $candidate) 'The requested artifact path is missing.'
    }
    Assert-NoReparsePath $candidate
    $candidate
}

function Write-JsonAtomic([string] $Path, $Value) {
    Require (-not (Test-Path -LiteralPath $Path)) 'Refusing to overwrite aggregate evidence.'
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    Assert-NoReparsePath $directory
    $temp = $Path + '.next-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temp,
            ($Value | ConvertTo-Json -Depth 15), $script:Utf8NoBom)
        [IO.File]::Move($temp, $Path)
        $script:HostWrites++
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { [IO.File]::Delete($temp) }
    }
}

function Get-RequiredProperty($Object, [string] $Name, [string] $Context) {
    $properties = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    Require ($properties.Count -eq 1) "$Context omitted or duplicated $Name."
    $properties[0].Value
}

function Get-ExactDouble($Value, [string] $Context) {
    Require ($Value -is [ValueType]) "$Context is not numeric."
    [double]$result = 0
    Require ([double]::TryParse([string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$result) -and [double]::IsFinite($result)) "$Context is invalid."
    $result
}

function Get-ReceiptStrata($Receipt, [string] $Context) {
    $aggregate = Get-RequiredProperty $Receipt 'aggregate' $Context
    $strata = @(Get-RequiredProperty $aggregate 'RefreshMetricStrata' "$Context aggregate")
    Require ($strata.Count -gt 0) "$Context lacks per-refresh aggregate strata."
    $map = [ordered]@{}
    foreach ($stratum in $strata) {
        $hz = Get-ExactDouble (Get-RequiredProperty $stratum 'Hz' $Context) "$Context Hz"
        $key = $hz.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
        Require (-not $map.Contains($key)) "$Context repeated a refresh stratum."
        [int]$samples = Get-ExactDouble (Get-RequiredProperty $stratum 'Samples' $Context) `
            "$Context Samples"
        Require ($samples -gt 0) "$Context has an empty refresh stratum."
        $row = [pscustomobject]@{
            Hz = $hz
            Samples = $samples
            MeanAppFps = Get-ExactDouble (Get-RequiredProperty $stratum 'MeanAppFps' $Context) "$Context MeanAppFps"
            P10AppFps = Get-ExactDouble (Get-RequiredProperty $stratum 'P10AppFps' $Context) "$Context P10AppFps"
            MeanStalePerSecond = Get-ExactDouble (Get-RequiredProperty $stratum 'MeanStalePerSecond' $Context) "$Context stale"
            P95CpuAndGpuMs = Get-ExactDouble (Get-RequiredProperty $stratum 'P95CpuAndGpuMs' $Context) "$Context P95CpuAndGpuMs"
            MeanTempC = Get-ExactDouble (Get-RequiredProperty $stratum 'MeanTempC' $Context) "$Context MeanTempC"
        }
        Require ($row.Hz -gt 0 -and $row.MeanAppFps -gt 0 -and
                $row.P10AppFps -gt 0 -and $row.P95CpuAndGpuMs -gt 0 -and
                $row.MeanStalePerSecond -ge 0 -and
                $row.MeanTempC -ge 0 -and $row.MeanTempC -le 100) `
            "$Context contains an impossible aggregate metric."
        $map[$key] = $row
    }
    $map
}

function Get-WeightedMean([object[]] $Rows, [string] $Property) {
    [double]$weighted = 0
    [double]$weight = 0
    foreach ($row in $Rows) {
        $w = [double]$row.Weight
        $weighted += $w * [double]$row.$Property
        $weight += $w
    }
    Require ($weight -gt 0) 'A weighted metric had no overlap.'
    $weighted / $weight
}

function Compare-MatchedRefreshPair($A, $B, [int] $PairIndex) {
    $aMap = Get-ReceiptStrata $A "Pair $PairIndex A"
    $bMap = Get-ReceiptStrata $B "Pair $PairIndex B"
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($key in @($aMap.Keys)) {
        if (-not $bMap.Contains($key)) { continue }
        $aStratum = $aMap[$key]; $bStratum = $bMap[$key]
        $overlap = [Math]::Min([int]$aStratum.Samples, [int]$bStratum.Samples)
        if ($overlap -lt $MinimumSamplesPerStratum) { continue }
        $rows.Add([pscustomobject][ordered]@{
            Hz = [double]$aStratum.Hz
            Weight = $overlap
            ACount = [int]$aStratum.Samples
            BCount = [int]$bStratum.Samples
            P95ImprovementPercent = 100.0 * ($aStratum.P95CpuAndGpuMs - $bStratum.P95CpuAndGpuMs) / $aStratum.P95CpuAndGpuMs
            MeanFpsChangePercent = 100.0 * ($bStratum.MeanAppFps - $aStratum.MeanAppFps) / $aStratum.MeanAppFps
            P10FpsChangePercent = 100.0 * ($bStratum.P10AppFps - $aStratum.P10AppFps) / $aStratum.P10AppFps
            StaleA = [double]$aStratum.MeanStalePerSecond
            StaleB = [double]$bStratum.MeanStalePerSecond
            StaleDeltaPerSecond = [double]$aStratum.MeanStalePerSecond - [double]$bStratum.MeanStalePerSecond
            TemperatureDeltaC = [Math]::Abs([double]$aStratum.MeanTempC - [double]$bStratum.MeanTempC)
        })
    }
    $overlapSamples = 0
    foreach ($row in $rows) { $overlapSamples += [int]$row.Weight }
    $aTotal = [int](Get-ExactDouble (Get-RequiredProperty $A.aggregate 'VrApiSamples' 'A aggregate') 'A samples')
    $bTotal = [int](Get-ExactDouble (Get-RequiredProperty $B.aggregate 'VrApiSamples' 'B aggregate') 'B samples')
    $overlapA = 100.0 * $overlapSamples / $aTotal
    $overlapB = 100.0 * $overlapSamples / $bTotal
    $startDelta = [Math]::Abs(
        (Get-ExactDouble (Get-RequiredProperty $A.aggregate 'FirstTempC' 'A aggregate') 'A first temp') -
        (Get-ExactDouble (Get-RequiredProperty $B.aggregate 'FirstTempC' 'B aggregate') 'B first temp'))
    $matchedTempDelta = if ($rows.Count -gt 0) {
        Get-WeightedMean $rows.ToArray() 'TemperatureDeltaC'
    } else { [double]::PositiveInfinity }
    $comparable = $rows.Count -gt 0 -and
        $overlapSamples -ge $MinimumOverlapSamplesPerPair -and
        $overlapA -ge $MinimumOverlapPercentPerArm -and
        $overlapB -ge $MinimumOverlapPercentPerArm -and
        $startDelta -le $MaximumStartTemperatureDeltaC -and
        $matchedTempDelta -le $MaximumMatchedTemperatureDeltaC

    [pscustomobject][ordered]@{
        PairIndex = $PairIndex
        Order = if ([int]$A.sequenceIndex -lt [int]$B.sequenceIndex) { 'AB' } else { 'BA' }
        Comparable = $comparable
        MatchedRefreshStrata = @($rows | ForEach-Object { $_.Hz })
        MatchedStratumCount = $rows.Count
        OverlapSamples = $overlapSamples
        OverlapPercentA = [Math]::Round($overlapA, 1)
        OverlapPercentB = [Math]::Round($overlapB, 1)
        StartTemperatureDeltaC = [Math]::Round($startDelta, 2)
        MatchedTemperatureDeltaC = if ([double]::IsFinite($matchedTempDelta)) {
            [Math]::Round($matchedTempDelta, 2)
        } else { $null }
        MatchedP95CpuAndGpuImprovementPercent = if ($rows.Count -gt 0) {
            [Math]::Round((Get-WeightedMean $rows.ToArray() 'P95ImprovementPercent'), 2)
        } else { $null }
        MatchedMeanAppFpsChangePercent = if ($rows.Count -gt 0) {
            [Math]::Round((Get-WeightedMean $rows.ToArray() 'MeanFpsChangePercent'), 2)
        } else { $null }
        MatchedP10AppFpsChangePercent = if ($rows.Count -gt 0) {
            [Math]::Round((Get-WeightedMean $rows.ToArray() 'P10FpsChangePercent'), 2)
        } else { $null }
        MatchedStaleDeltaPerSecond = if ($rows.Count -gt 0) {
            [Math]::Round((Get-WeightedMean $rows.ToArray() 'StaleDeltaPerSecond'), 3)
        } else { $null }
        MatchedStaleA = if ($rows.Count -gt 0) {
            [Math]::Round((Get-WeightedMean $rows.ToArray() 'StaleA'), 3)
        } else { $null }
        MatchedStaleB = if ($rows.Count -gt 0) {
            [Math]::Round((Get-WeightedMean $rows.ToArray() 'StaleB'), 3)
        } else { $null }
        Strata = $rows.ToArray()
    }
}

function Assert-Receipt($Receipt, [int] $Index) {
    Require ([int](Get-RequiredProperty $Receipt 'schemaVersion' "Receipt $Index") -eq 2 -and
            [string](Get-RequiredProperty $Receipt 'receiptType' "Receipt $Index") -ceq
                'V71_RC8_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE') `
        "Receipt $Index schema drifted."
    $expectedCondition = $script:Order[$Index - 1]
    Require ([int](Get-RequiredProperty $Receipt 'sequenceIndex' "Receipt $Index") -eq $Index -and
            [string](Get-RequiredProperty $Receipt 'condition' "Receipt $Index") -ceq $expectedCondition -and
            [string](Get-RequiredProperty $Receipt 'renderScaleFactor' "Receipt $Index") -ceq
                $script:ScaleByCondition[$expectedCondition]) "Receipt $Index order/condition drifted."
    $identity = Get-RequiredProperty $Receipt 'identityFence' "Receipt $Index"
    foreach ($field in @('exactBuildLock','exactApk','signerBoundByExactApk','exactCore','exactVeq','stableStoppedAtBothFences')) {
        Require ([bool](Get-RequiredProperty $identity $field "Receipt $Index identity")) `
            "Receipt $Index failed identity field $field."
    }
    Require ([bool](Get-RequiredProperty $Receipt 'validForComparison' "Receipt $Index")) `
        "Receipt $Index was invalidated by the PID/focus/VrApi gate."
    Require ([string](Get-RequiredProperty $Receipt 'refreshPolicy' "Receipt $Index") -ceq 'Dynamic') `
        "Receipt $Index was not captured with Dynamic refresh."
    $benchmarkGate = Get-RequiredProperty $Receipt 'benchmarkGate' "Receipt $Index"
    $cpuLevel = [int](Get-RequiredProperty $benchmarkGate 'expectedCpuLevel' "Receipt $Index benchmark gate")
    $gpuLevel = [int](Get-RequiredProperty $benchmarkGate 'expectedGpuLevel' "Receipt $Index benchmark gate")
    Require ($cpuLevel -ge 0 -and $cpuLevel -le 15 -and
            $gpuLevel -ge 0 -and $gpuLevel -le 15) `
        "Receipt $Index contains invalid expected performance levels."
    Require ([double](Get-RequiredProperty $benchmarkGate 'cpuExpectedLevelPercent' "Receipt $Index benchmark gate") -ge 95.0 -and
            [double](Get-RequiredProperty $benchmarkGate 'gpuExpectedLevelPercent' "Receipt $Index benchmark gate") -ge 95.0) `
        "Receipt $Index did not remain at its declared performance levels."
    $null = Get-ReceiptStrata $Receipt "Receipt $Index"
}

function Analyze-Receipts([object[]] $Receipts) {
    Require ($Receipts.Count -eq 6) 'Exactly six receipts are required.'
    for ($i = 1; $i -le 6; $i++) { Assert-Receipt $Receipts[$i - 1] $i }
    $expectedCpuLevels = @($Receipts | ForEach-Object { [int]$_.benchmarkGate.expectedCpuLevel } | Select-Object -Unique)
    $expectedGpuLevels = @($Receipts | ForEach-Object { [int]$_.benchmarkGate.expectedGpuLevel } | Select-Object -Unique)
    Require ($expectedCpuLevels.Count -eq 1 -and $expectedGpuLevels.Count -eq 1) `
        'All six receipts must use the same declared CPU/GPU performance levels.'
    $pairs = @(
        Compare-MatchedRefreshPair $Receipts[0] $Receipts[1] 1
        Compare-MatchedRefreshPair $Receipts[3] $Receipts[2] 2
        Compare-MatchedRefreshPair $Receipts[4] $Receipts[5] 3
    )
    $comparable = @($pairs | Where-Object { $_.Comparable }).Count -eq 3
    $weightedRows = @($pairs | ForEach-Object {
        if ($_.Comparable) {
            [pscustomobject]@{
                Weight = $_.OverlapSamples
                P95 = $_.MatchedP95CpuAndGpuImprovementPercent
                MeanFps = $_.MatchedMeanAppFpsChangePercent
                P10 = $_.MatchedP10AppFpsChangePercent
                StaleDelta = $_.MatchedStaleDeltaPerSecond
                StaleA = $_.MatchedStaleA
                StaleB = $_.MatchedStaleB
            }
        }
    })
    $p95 = if ($comparable) { Get-WeightedMean $weightedRows 'P95' } else { $null }
    $meanFps = if ($comparable) { Get-WeightedMean $weightedRows 'MeanFps' } else { $null }
    $p10 = if ($comparable) { Get-WeightedMean $weightedRows 'P10' } else { $null }
    $staleDelta = if ($comparable) { Get-WeightedMean $weightedRows 'StaleDelta' } else { $null }
    $staleA = if ($comparable) { Get-WeightedMean $weightedRows 'StaleA' } else { $null }
    $staleB = if ($comparable) { Get-WeightedMean $weightedRows 'StaleB' } else { $null }
    $staleImprovement = if ($null -ne $staleA -and $staleA -gt 0.0001) {
        100.0 * ($staleA - $staleB) / $staleA
    } else { $null }
    $positivePairs = if ($comparable) {
        @($pairs | Where-Object { $_.MatchedP95CpuAndGpuImprovementPercent -gt 0 }).Count
    } else { 0 }
    $performanceGate = $comparable -and $positivePairs -ge 2 -and $p95 -ge 2.0 -and
        $meanFps -ge -1.0 -and $p10 -ge -1.0
    [pscustomobject][ordered]@{
        schemaVersion = 2
        result = if (-not $comparable) { 'INCONCLUSIVE' } elseif ($performanceGate) {
            'PERFORMANCE_CANDIDATE'
        } else { 'REJECT' }
        comparison = 'renderScaleFactor 1.0 (A) versus 0.8 (B)'
        order = 'A1-B1 / B2-A2 / A3-B3'
        dynamicRefresh = $true
        matchedObservedRefreshOnly = $true
        allPairsComparable = $comparable
        pairs = $pairs
        combined = [pscustomobject][ordered]@{
            matchedP95CpuAndGpuImprovementPercent = if ($null -ne $p95) { [Math]::Round($p95, 2) } else { $null }
            matchedMeanAppFpsChangePercent = if ($null -ne $meanFps) { [Math]::Round($meanFps, 2) } else { $null }
            matchedP10AppFpsChangePercent = if ($null -ne $p10) { [Math]::Round($p10, 2) } else { $null }
            matchedStaleDeltaPerSecond = if ($null -ne $staleDelta) { [Math]::Round($staleDelta, 3) } else { $null }
            matchedStaleImprovementPercent = if ($null -ne $staleImprovement) { [Math]::Round($staleImprovement, 2) } else { $null }
            positiveP95Pairs = $positivePairs
        }
        gates = [pscustomobject][ordered]@{
            expectedCpuLevel = [int]$expectedCpuLevels[0]
            expectedGpuLevel = [int]$expectedGpuLevels[0]
            minimumOverlapPercentPerArm = $MinimumOverlapPercentPerArm
            minimumOverlapSamplesPerPair = $MinimumOverlapSamplesPerPair
            minimumSamplesPerStratum = $MinimumSamplesPerStratum
            maximumStartTemperatureDeltaC = $MaximumStartTemperatureDeltaC
            maximumMatchedTemperatureDeltaC = $MaximumMatchedTemperatureDeltaC
            performanceGatePassed = $performanceGate
            stereoClarityStillRequiresManualReview = $true
            stablePromotionAllowed = $false
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            aggregateOnly = $true
            rawLogsPersisted = $false
            deviceInvocations = 0
            deviceWrites = 0
            configOrProfileMutation = $false
            stableMutation = $false
            rootUsed = $false
        }
    }
}

function New-FixtureReceipt([int] $Index, [double[]] $Counts, [double] $P95Shift,
        [double] $TempShift = 0.0) {
    $condition = $script:Order[$Index - 1]
    $isB = $condition -ceq 'B'
    $strata = @()
    $hz = @(72.0, 80.0, 90.0)
    for ($i = 0; $i -lt 3; $i++) {
        $strata += [pscustomobject]@{
            Hz = $hz[$i]; Samples = [int]$Counts[$i]
            MeanAppFps = if ($isB) { $hz[$i] * 0.985 } else { $hz[$i] * 0.98 }
            P10AppFps = if ($isB) { $hz[$i] * 0.95 } else { $hz[$i] * 0.945 }
            MeanStalePerSecond = if ($isB) { 1.0 } else { 1.3 }
            P95CpuAndGpuMs = if ($isB) { 13.0 - $P95Shift } else { 13.0 }
            MeanTempC = 42.0 + $TempShift
        }
    }
    [pscustomobject][ordered]@{
        schemaVersion = 2
        receiptType = 'V71_RC8_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE'
        sequenceIndex = $Index
        condition = $condition
        renderScaleFactor = $script:ScaleByCondition[$condition]
        refreshPolicy = 'Dynamic'
        validForComparison = $true
        identityFence = [pscustomobject]@{
            exactBuildLock=$true; exactApk=$true; signerBoundByExactApk=$true
            exactCore=$true; exactVeq=$true; stableStoppedAtBothFences=$true
        }
        benchmarkGate = [pscustomobject]@{
            expectedCpuLevel=4; expectedGpuLevel=4
            cpuExpectedLevelPercent=100.0; gpuExpectedLevelPercent=100.0
        }
        aggregate = [pscustomobject]@{
            VrApiSamples = [int](($Counts | Measure-Object -Sum).Sum)
            FirstTempC = 42.0 + $TempShift
            RefreshMetricStrata = $strata
        }
    }
}

function Invoke-SelfTest {
    $fixtures = @(
        New-FixtureReceipt 1 @(25,20,15) 0.5
        New-FixtureReceipt 2 @(20,25,15) 0.5 0.2
        New-FixtureReceipt 3 @(22,18,20) 0.5 0.3
        New-FixtureReceipt 4 @(18,22,20) 0.5 0.1
        New-FixtureReceipt 5 @(20,20,20) 0.5
        New-FixtureReceipt 6 @(24,18,18) 0.5 0.2
    )
    $accepted = Analyze-Receipts $fixtures
    Require ($accepted.result -ceq 'PERFORMANCE_CANDIDATE' -and
            $accepted.allPairsComparable -and
            $accepted.combined.positiveP95Pairs -eq 3) `
        'Matched-refresh fixture was not accepted.'

    $badOrder = @($fixtures)
    $badOrder[1] = $fixtures[0]
    Require (Test-Throws { Analyze-Receipts $badOrder | Out-Null }) `
        'A non-counterbalanced sequence was accepted.'

    $noOverlap = @($fixtures | ForEach-Object { $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json })
    $noOverlap[1].aggregate.RefreshMetricStrata = @(
        [pscustomobject]@{ Hz=120.0; Samples=60; MeanAppFps=118.0; P10AppFps=115.0; MeanStalePerSecond=1.0; P95CpuAndGpuMs=12.5; MeanTempC=42.0 })
    $noOverlap[1].aggregate.VrApiSamples = 60
    $inconclusive = Analyze-Receipts $noOverlap
    Require ($inconclusive.result -ceq 'INCONCLUSIVE' -and
            -not $inconclusive.allPairsComparable) `
        'Insufficient observed-refresh overlap was accepted.'

    $hot = @($fixtures | ForEach-Object { $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json })
    $hot[1].aggregate.FirstTempC = 45.0
    $thermal = Analyze-Receipts $hot
    Require ($thermal.result -ceq 'INCONCLUSIVE') `
        'A start-temperature mismatch was accepted.'

    Require ($script:DeviceInvocations -eq 0 -and $script:HostWrites -eq 0) `
        'SelfTest touched ADB or wrote Host evidence.'
    [pscustomobject][ordered]@{
        Result = 'PASS'; HostOnly = $true; Assertions = $script:Assertions
        DeviceInvocations = 0; HostWrites = 0
        DynamicRefreshStratification = $true
        CounterbalancedOrder = 'AB/BA/AB'; StableTouched = $false
    }
}

Assert-HostContract

if ($Action -ceq 'SelfTest') { Invoke-SelfTest; return }
if ($Action -ceq 'Status') {
    Require (-not $AllowDeviceRead -and -not $AllowHostOutput) `
        'Host-only Status rejects runtime authorization switches.'
    [pscustomobject][ordered]@{
        Result='PASS'; HostOnly=$true; ExactRc8Lock=$true
        PackageClass='LAB_ONLY'; DynamicRefresh=$true
        RequiredOrder='A1-B1 / B2-A2 / A3-B3'
        DeviceInvocations=0; HostWrites=0; StableTouched=$false
    }
    return
}

if ($Action -ceq 'Analyze') {
    Require (-not $AllowDeviceRead -and -not $ConfirmExactRc8Lab) `
        'Analyze is Host-only and rejects device authorization.'
    $directory = Resolve-ArtifactChild $InputDirectory
    Require (Test-Path -LiteralPath $directory -PathType Container) `
        'Analyze input must be a directory.'
    $receipts = @()
    for ($index = 1; $index -le 6; $index++) {
        $expectedCondition = $script:Order[$index - 1]
        $path = Join-Path $directory ('{0:D2}-{1}.json' -f $index, $expectedCondition)
        Require (Test-Path -LiteralPath $path -PathType Leaf) `
            "Missing aggregate receipt $([IO.Path]::GetFileName($path))."
        $receipts += Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 20
    }
    $analysis = Analyze-Receipts $receipts
    if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
        Require $AllowHostOutput.IsPresent 'Writing analysis requires -AllowHostOutput.'
        $output = Resolve-ArtifactChild $OutputJson -MayBeMissing
        Require ([IO.Path]::GetExtension($output) -ceq '.json') 'Analysis output must be JSON.'
        Write-JsonAtomic $output $analysis
    } else {
        Require (-not $AllowHostOutput) 'Unused -AllowHostOutput was rejected.'
    }
    $analysis
    return
}

Require $AllowDeviceRead.IsPresent 'Capture requires -AllowDeviceRead.'
Require $ConfirmExactRc8Lab.IsPresent 'Capture requires -ConfirmExactRc8Lab.'
Require $AllowHostOutput.IsPresent 'Capture requires -AllowHostOutput.'
$expectedCondition = $script:Order[$SequenceIndex - 1]
Require ($Condition -ceq $expectedCondition) 'Condition does not match AB/BA/AB order.'
$expectedScale = [string]$script:ScaleByCondition[$Condition]
Require ($DeclaredRenderScale -ceq $expectedScale) `
    'Declared render scale does not match the fixed condition.'
$directory = Resolve-ArtifactChild $OutputDirectory -MayBeMissing
if (-not (Test-Path -LiteralPath $directory)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
Require (Test-Path -LiteralPath $directory -PathType Container) `
    'Capture output must be a directory.'
$finalPath = Join-Path $directory ('{0:D2}-{1}.json' -f $SequenceIndex, $Condition)
Require (-not (Test-Path -LiteralPath $finalPath)) 'This sequence receipt already exists.'
Resolve-Device
$initial = Assert-ExactDeviceIdentity $expectedScale
$temporary = Join-Path $directory ('.vrapi-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    $benchmarkResult = & $script:BenchmarkPath -Action Capture `
        -Package $script:Package -Serial $script:Device -AdbPath $script:Adb `
        -Seconds $Seconds -ExpectedRefreshHz 72 -DynamicRefresh `
        -MinimumSampleCoveragePercent 60 -PollSeconds 1 -OutputJson $temporary
    Require (Test-Path -LiteralPath $temporary -PathType Leaf) `
        'The aggregate benchmark did not publish its receipt.'
    $rawAggregate = Get-Content -Raw -LiteralPath $temporary | ConvertFrom-Json -Depth 20
    $benchmarkReasons = @($rawAggregate.InvalidReasons | ForEach-Object { [string]$_ })
    Require ([string]$rawAggregate.Package -ceq $script:Package -and
            [string]$rawAggregate.RefreshPolicy -ceq 'Dynamic' -and
            [bool]$rawAggregate.ValidForComparison -and
            -not [bool]$rawAggregate.RawLogsPersisted -and
            -not [bool]$rawAggregate.RawProcessRowsPersisted) `
        ('The aggregate VrApi benchmark did not pass its read-only quality gates: ' +
            ($benchmarkReasons -join '; '))
    Require (@($rawAggregate.Aggregate.RefreshMetricStrata).Count -gt 0) `
        'The benchmark omitted matched-refresh metrics.'
    $strataProbe = [pscustomobject]@{ aggregate = $rawAggregate.Aggregate }
    $null = Get-ReceiptStrata $strataProbe 'Captured aggregate'
    $cpuExpectedRows = @($rawAggregate.Aggregate.CpuLevelDistribution | Where-Object {
        [int]$_.Level -eq $ExpectedCpuLevel
    })
    $gpuExpectedRows = @($rawAggregate.Aggregate.GpuLevelDistribution | Where-Object {
        [int]$_.Level -eq $ExpectedGpuLevel
    })
    Require ($cpuExpectedRows.Count -le 1 -and $gpuExpectedRows.Count -le 1) `
        'The CPU/GPU performance-level distribution was ambiguous.'
    $cpuExpectedPercent = if ($cpuExpectedRows.Count -eq 1) {
        [double]$cpuExpectedRows[0].PercentOfVrApiSamples
    } else { 0.0 }
    $gpuExpectedPercent = if ($gpuExpectedRows.Count -eq 1) {
        [double]$gpuExpectedRows[0].PercentOfVrApiSamples
    } else { 0.0 }
    Require ([double]$rawAggregate.Aggregate.CpuLevelCoveragePercent -ge 95.0 -and
            [double]$rawAggregate.Aggregate.GpuLevelCoveragePercent -ge 95.0 -and
            $cpuExpectedPercent -ge 95.0 -and $gpuExpectedPercent -ge 95.0) `
        "The capture did not remain at declared CPU/GPU levels $ExpectedCpuLevel/$ExpectedGpuLevel with sufficient telemetry coverage."
    $final = Assert-ExactDeviceIdentity $expectedScale
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 2
        receiptType = 'V71_RC8_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE'
        sequenceIndex = $SequenceIndex
        condition = $Condition
        renderScaleFactor = $expectedScale
        refreshPolicy = 'Dynamic'
        durationSeconds = $Seconds
        validForComparison = $true
        identityFence = [pscustomobject][ordered]@{
            exactBuildLock = $true; exactApk = $true
            signerBoundByExactApk = $true; signerSha256 = $script:SignerSha256
            exactCore = $true; exactVeq = $true
            stableStoppedAtBothFences = [bool]($initial.StableStopped -and $final.StableStopped)
            renderScaleMatchedAtBothFences = $true
        }
        benchmarkGate = [pscustomobject][ordered]@{
            exactPid = ([double]$rawAggregate.ExactPidPollPercent -eq 100.0)
            focusPercent = [double]$rawAggregate.FocusedPollPercent
            sampleCoveragePercent = [double]$rawAggregate.SampleCoveragePercent
            expectedCpuLevel = $ExpectedCpuLevel
            expectedGpuLevel = $ExpectedGpuLevel
            cpuExpectedLevelPercent = $cpuExpectedPercent
            gpuExpectedLevelPercent = $gpuExpectedPercent
            externalProcessGuard = $rawAggregate.ExternalProcessGuard
        }
        aggregate = $rawAggregate.Aggregate
        evidenceBoundary = [pscustomobject][ordered]@{
            aggregateOnly = $true; rawLogsPersisted = $false
            rawProcessRowsPersisted = $false; deviceReadsOnly = $true
            deviceWrites = 0; installLaunchStopRoot = $false
            configOrProfileMutation = $false; stableMutation = $false
        }
    }
    Write-JsonAtomic $finalPath $receipt
    [pscustomobject][ordered]@{
        Result='PASS'; SequenceIndex=$SequenceIndex; Condition=$Condition
        RenderScaleFactor=$expectedScale; RefreshPolicy='Dynamic'
        AggregateFileName=[IO.Path]::GetFileName($finalPath)
        ValidForComparison=$true; DeviceReadsOnly=$true
        DeviceWrites=0; StableTouched=$false; RawLogsPersisted=$false
    }
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        [IO.File]::Delete($temporary)
    }
}
