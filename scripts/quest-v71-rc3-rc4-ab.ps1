<#
.SYNOPSIS
Runs a fail-closed RC3-versus-RC4 performance comparison on QuestCraft Lab.

.DESCRIPTION
This orchestrator is deliberately fixed to com.qcxr.qcxr.canary262, profile
26.2, the integrated RC4 Lab APK, the exact RC3 candidate pair, and the exact
RC4 rollback pair.  A is RC3 and B is RC4.  The counterbalanced order is
A1 -> B1 -> B2 -> A2 -> A3 -> B3 (AB/BA/AB).

SelfTest, Plan, and Aggregate are Host-only and never resolve or invoke ADB.
Run requires three independent switches before any device access.  Every
device-capable round restores the exact RC4 pair in finally, and the outer Run
does so again before returning.  Stable is never a selectable target.

Only aggregate VrApi evidence is persisted.  Device serials, raw logcat rows,
account data, and raw process rows are not written to disk.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Plan', 'Run', 'Aggregate')]
    [string] $Action = 'Plan',

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

    [switch] $AllowDeviceRead,

    [switch] $AllowDeviceWrite,

    [switch] $AllowLaunch,

    [switch] $AllowRootFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.canary262'
$script:ForbiddenStablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:World = 'FPS-Stress-Test'
$script:Order = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Rc4LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC4.lock.json'
$script:Rc4CandidateLock = Get-Content -Raw -LiteralPath $script:Rc4LockPath | ConvertFrom-Json
$script:ExpectedApkSha256 = [string]$script:Rc4CandidateLock.target.labShellApkSha256
$script:ExpectedApkSizeBytes = [int64]$script:Rc4CandidateLock.target.labShellApkSizeBytes
$script:ExpectedVersionCode = '71'
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.4'
$script:ExpectedLabel = 'QuestCraft Vivecraft Lab 26.2'
$script:ExpectedSignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedLwjglSha256 = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
$script:Rc3CoreSha256 = '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26'
$script:Rc3CoreSizeBytes = 10063450L
$script:Rc3CoreVersion = '26.2-1.3.15+qc.v71.rc3'
$script:Rc3VeqSha256 = '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
$script:Rc3VeqSizeBytes = 441660L
$script:Rc3VeqVersion = '0.7.0-v70-canary.1'
$script:Rc4CoreSha256 = '289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189'
$script:Rc4CoreSizeBytes = 10068021L
$script:Rc4CoreVersion = '26.2-1.3.15+qc.v71.rc4'
$script:Rc4VeqSha256 = '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
$script:Rc4VeqSizeBytes = 441660L
$script:Rc4VeqVersion = '0.7.0-v70-canary.1'
$script:WorldMasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$script:ExpectedCpuLevel = 4
$script:ExpectedGpuLevel = 4
$script:CpuLevelProperty = 'debug.oculus.cpuLevel'
$script:GpuLevelProperty = 'debug.oculus.gpuLevel'
$script:PreflightSeconds = 10
$script:SampleSeconds = 60
$script:MinimumCoveragePercent = 95.0
$script:MinimumLevel4Percent = 95.0
$script:MaximumStartTemperatureDeltaC = 1.0
$script:MaximumThermalPathDeltaC = 1.0
$script:MaximumRefreshDistributionDistancePercent = 5.0
$script:MaximumRefreshMeanDeltaHz = 0.5
$script:MaximumRefreshModeDeltaHz = 0.5
$script:MaximumRefreshTransitionDelta = 1
$script:MaximumPersistentRegressionPercent = 2.0
$script:ReadyTimeoutSeconds = 240
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:ArtifactsRoot = Join-Path $script:WorkspaceRoot 'artifacts\benchmarks'
$script:GlobalLockPath = Join-Path $script:ArtifactsRoot '.quest-v71-rc3-rc4-ab.global.lock'
$script:OfflineAdbSentinel = Join-Path $PSScriptRoot '__quest-v71-host-selftest-no-adb__.exe'
$script:OfflineSdkSentinel = Join-Path $PSScriptRoot '__quest-v71-host-selftest-no-sdk__'
$script:Rc3ExportRoot = Join-Path $script:WorkspaceRoot 'exports\v71-rc3-freeze-20260906'
$script:Rc3CorePath = Join-Path $script:Rc3ExportRoot 'vivecraft-26.2-1.3.15+qc.v71.rc3-fabric.jar'
$script:Rc3VeqPath = Join-Path $script:Rc3ExportRoot 'VivecraftEssentialsQuest-0.7.0-v70-canary.1+mc26.2-fabric.jar'
$script:Rc4ApkPath = Join-Path $script:RepoRoot 'QCXR-XR-Wrapper\Builds\QuestCraft-Vivecraft-Lab-26.2-v71-rc.4-integrated-local.apk'
$script:Rc3LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC3.lock.json'
$script:PairScript = Join-Path $PSScriptRoot 'quest-v70-lab-pair.ps1'
$script:CoreCanaryScript = Join-Path $PSScriptRoot 'quest-vivecraft-core-canary.ps1'
$script:VeqLabScript = Join-Path $PSScriptRoot 'quest-veq-lab.ps1'
$script:ResetScript = Join-Path $PSScriptRoot 'reset-lab-benchmark-world.ps1'
$script:AutoplayScript = Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'
$script:BenchmarkScript = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$script:ApkVerifier = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$script:ProducerHashScheme = 'sha256-utf8-normalized-lf'
$script:ExpectedProducerDependencyHashes = [ordered]@{
    'pair-harness' = '00BD9A413AB1E0C7204FE423F91A028E923D75F622E17155848A2B5897D15D45'
    'core-canary-harness' = 'E4DF30D9AB1204D412814236D9391C80F72AF4AE4EBE0BA3DE38DAEBF4398F26'
    'veq-lab-harness' = '11CE8A48E5692143AAFB93EE967BEF59AC4E0830A7DBFF6AB6E3E6B75BC6F252'
    'world-reset-harness' = 'DE0500CA3CEEBAE2A371B257F191AC09DC6746147D47F48E53F262BAAA0F4726'
    'autoplay-harness' = '261E6881B334DECD8CB41A640F1EE765E024278FC677128B472234C923CD7196'
    'vrapi-benchmark-harness' = '8FC046C6239E30823BB2B9408D1F0B3FD0B689C9A3F7B39FB8CFAFD0D211EE33'
    'apk-verifier' = '28AB72CDB15A60A3C0C8EE7061F8E251E39666DFA401EDFF1674ADBAED485DBC'
}
$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:DeviceInvocationCount = 0
$script:DeviceReady = $false
$script:CampaignMutationStarted = $false
$script:HostResolved = $false
$script:ExpectedOtherModsFingerprint = $null
$script:EffectiveWarmupSeconds = $WarmupSeconds
$script:ActiveReadinessMarker = $null
$script:ActiveProducerLineage = $null
$script:PerformanceLeaseSnapshot = $null
$script:PerformanceLeaseMutationStarted = $false
$script:PerformanceLeaseActive = $false
$script:PerformanceLeaseApplications = 0

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function ConvertTo-PerformanceLevelToken {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Value,
        [Parameter(Mandatory)][string] $Label
    )
    Require ($Value.Length -le 2 -and
            ([string]::IsNullOrEmpty($Value) -or $Value -cmatch '^[0-9]{1,2}$')) `
            "$Label is not an unset or bounded numeric performance level."
    if ([string]::IsNullOrEmpty($Value)) { return 'U' }
    return 'N' + $Value
}

function ConvertFrom-PerformanceLevelToken {
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $Label
    )
    Require ($Token -cmatch '^(?:U|N[0-9]{1,2})$') "$Label token is invalid."
    if ($Token -ceq 'U') { return '' }
    return $Token.Substring(1)
}

function Read-ExactPerformanceLevelProbe {
    param(
        [Parameter(Mandatory)][int] $ExitCode,
        [AllowEmptyCollection()][string[]] $Lines = @(),
        [Parameter(Mandatory)][string] $Label
    )
    Require ($ExitCode -eq 0) "$Label failed with exit code $ExitCode."
    $rows = @($Lines | ForEach-Object { [string]$_ })
    Require ($rows.Count -eq 1 -and
            $rows[0] -cmatch '^PERF_LEVELS\t(?<cpu>U|N[0-9]{1,2})\t(?<gpu>U|N[0-9]{1,2})$') `
            "$Label returned missing, ambiguous, or contaminated evidence."
    $cpuToken = [string]$Matches.cpu
    $gpuToken = [string]$Matches.gpu
    return [pscustomobject]@{
        Cpu = ConvertFrom-PerformanceLevelToken $cpuToken "$Label CPU"
        Gpu = ConvertFrom-PerformanceLevelToken $gpuToken "$Label GPU"
    }
}

function New-PerformanceLevelProbeCommand {
    $qCpuProperty = ConvertTo-ShLiteral $script:CpuLevelProperty
    $qGpuProperty = ConvertTo-ShLiteral $script:GpuLevelProperty
    return @(
        'set -eu'
        # Meta documents these two debug properties for temporary device-side
        # performance-level testing.  This lease intentionally does not touch
        # refresh/adaptive properties.  Reference:
        # https://developers.meta.com/horizon/documentation/native/android/ts-systemproperties/
        ('cpu=$(getprop {0})' -f $qCpuProperty)
        ('gpu=$(getprop {0})' -f $qGpuProperty)
        'encode_level() {'
        '  value=$1'
        '  case "$value" in'
        '    "") printf U ;;'
        '    *[!0-9]*|???*) exit 73 ;;'
        '    *) printf "N%s" "$value" ;;'
        '  esac'
        '}'
        'cpu_token=$(encode_level "$cpu")'
        'gpu_token=$(encode_level "$gpu")'
        'printf ''PERF_LEVELS\t%s\t%s\n'' "$cpu_token" "$gpu_token"'
    ) -join "`n"
}

function New-PerformanceLevelMutationCommand {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Cpu,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Gpu
    )
    $null = ConvertTo-PerformanceLevelToken $Cpu 'CPU performance level'
    $null = ConvertTo-PerformanceLevelToken $Gpu 'GPU performance level'
    $qCpuProperty = ConvertTo-ShLiteral $script:CpuLevelProperty
    $qGpuProperty = ConvertTo-ShLiteral $script:GpuLevelProperty
    $qCpu = ConvertTo-ShLiteral $Cpu
    $qGpu = ConvertTo-ShLiteral $Gpu
    return @(
        'set -u'
        'rc=0'
        ('setprop {0} {1} || rc=1' -f $qCpuProperty, $qCpu)
        ('setprop {0} {1} || rc=1' -f $qGpuProperty, $qGpu)
        ('cpu=$(getprop {0}) || rc=1' -f $qCpuProperty)
        ('gpu=$(getprop {0}) || rc=1' -f $qGpuProperty)
        ('if [ "$cpu" != {0} ]; then rc=1; fi' -f $qCpu)
        ('if [ "$gpu" != {0} ]; then rc=1; fi' -f $qGpu)
        'encode_level() {'
        '  value=$1'
        '  case "$value" in'
        '    "") printf U ;;'
        '    *[!0-9]*|???*) return 73 ;;'
        '    *) printf "N%s" "$value" ;;'
        '  esac'
        '}'
        'cpu_token=$(encode_level "$cpu") || rc=1'
        'gpu_token=$(encode_level "$gpu") || rc=1'
        'printf ''PERF_LEVELS\t%s\t%s\n'' "$cpu_token" "$gpu_token"'
        'exit "$rc"'
    ) -join "`n"
}

function Get-PerformanceLevelEvidence {
    param([Parameter(Mandatory)] $Snapshot)
    return [pscustomobject]@{
        OriginalCpuLevelSet = -not [string]::IsNullOrEmpty([string]$Snapshot.Cpu)
        OriginalCpuLevel = if ([string]::IsNullOrEmpty([string]$Snapshot.Cpu)) {
            $null
        } else { [int]$Snapshot.Cpu }
        OriginalGpuLevelSet = -not [string]::IsNullOrEmpty([string]$Snapshot.Gpu)
        OriginalGpuLevel = if ([string]::IsNullOrEmpty([string]$Snapshot.Gpu)) {
            $null
        } else { [int]$Snapshot.Gpu }
    }
}

function Get-ReservedPidAssignments {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast] $Ast)
    return @($Ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.AssignmentStatementAst]) {
            return $false
        }
        $left = $node.Left
        return $left -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]$left.VariablePath.UserPath -ieq 'PID'
    }, $true))
}

function Normalize-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $normalized = $Value.ToUpperInvariant()
    Require ($normalized -cmatch '^[0-9A-F]{64}$') 'Invalid SHA-256.'
    return $normalized
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
            $full.StartsWith($rootFull + '\',
            [StringComparison]::OrdinalIgnoreCase)) "$Label escapes its fixed root."
    $cursor = if (Test-Path -LiteralPath $full) { $full } else { [IO.Path]::GetDirectoryName($full) }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -Force -LiteralPath $cursor
            Require (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
                    "$Label traverses a reparse point."
        }
        if ($cursor.TrimEnd('\').Equals($rootFull,
                [StringComparison]::OrdinalIgnoreCase)) { return $full }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        Require (-not [string]::IsNullOrWhiteSpace($parent) -and
                $parent.Length -lt $cursor.Length) "$Label containment walk failed."
        $cursor = $parent
    }
    throw "$Label did not reach its fixed root."
}

function Get-NormalizedTextSha256 {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )
    $full = Assert-NoReparseContainment $Path $script:RepoRoot $Label
    Require (Test-Path -LiteralPath $full -PathType Leaf) "$Label is missing."
    $item = Get-Item -LiteralPath $full
    Require (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
            "$Label must not be a reparse point."
    try {
        $bytes = [IO.File]::ReadAllBytes($full)
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

function Get-ProducerDependencyDefinitions {
    return @(
        [pscustomobject]@{ Name = 'pair-harness'; Path = $script:PairScript; RelativePath = 'scripts/quest-v70-lab-pair.ps1' }
        [pscustomobject]@{ Name = 'core-canary-harness'; Path = $script:CoreCanaryScript; RelativePath = 'scripts/quest-vivecraft-core-canary.ps1' }
        [pscustomobject]@{ Name = 'veq-lab-harness'; Path = $script:VeqLabScript; RelativePath = 'scripts/quest-veq-lab.ps1' }
        [pscustomobject]@{ Name = 'world-reset-harness'; Path = $script:ResetScript; RelativePath = 'scripts/reset-lab-benchmark-world.ps1' }
        [pscustomobject]@{ Name = 'autoplay-harness'; Path = $script:AutoplayScript; RelativePath = 'scripts/run-vivecraft-local-autoplay.ps1' }
        [pscustomobject]@{ Name = 'vrapi-benchmark-harness'; Path = $script:BenchmarkScript; RelativePath = 'scripts/quest-vrapi-pid-benchmark.ps1' }
        [pscustomobject]@{ Name = 'apk-verifier'; Path = $script:ApkVerifier; RelativePath = 'scripts/verify-dev-apk.ps1' }
    )
}

function Get-ProducerLineageDigest {
    param([Parameter(Mandatory)][object[]] $Files)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("scheme=$script:ProducerHashScheme")
    foreach ($file in $Files) {
        $lines.Add(('{0}|{1}|{2}' -f [string]$file.Name,
                [string]$file.RelativePath, [string]$file.Sha256))
    }
    $payload = ($lines -join "`n") + "`n"
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($payload)))
}

function Get-ProducerLineageSnapshot {
    $files = [Collections.Generic.List[object]]::new()
    $harnessHash = Get-NormalizedTextSha256 $PSCommandPath 'A/B orchestrator'
    $files.Add([pscustomobject]@{
        Name = 'orchestrator'
        RelativePath = 'scripts/quest-v71-rc3-rc4-ab.ps1'
        Sha256 = $harnessHash
    })
    foreach ($definition in @(Get-ProducerDependencyDefinitions)) {
        $actual = Get-NormalizedTextSha256 $definition.Path `
                "A/B producer dependency $($definition.Name)"
        $expected = Normalize-Sha256 `
                ([string]$script:ExpectedProducerDependencyHashes[$definition.Name])
        Require ($actual -ceq $expected) `
                "A/B producer dependency '$($definition.Name)' drifted."
        $files.Add([pscustomobject]@{
            Name = [string]$definition.Name
            RelativePath = [string]$definition.RelativePath
            Sha256 = $actual
        })
    }
    $snapshotFiles = $files.ToArray()
    return [pscustomobject]@{
        SchemaVersion = 1
        HashScheme = $script:ProducerHashScheme
        DigestSha256 = Get-ProducerLineageDigest $snapshotFiles
        Files = $snapshotFiles
    }
}

function Assert-ProducerLineageObject {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Label
    )
    Require ([int]$Actual.SchemaVersion -eq 1 -and
            [string]$Actual.HashScheme -ceq $script:ProducerHashScheme) `
            "$Label producer-lineage schema drifted."
    $actualFiles = @($Actual.Files)
    $expectedFiles = @($Expected.Files)
    Require ($actualFiles.Count -eq $expectedFiles.Count) `
            "$Label producer-lineage file count drifted."
    for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
        Require ([string]$actualFiles[$index].Name -ceq
                    [string]$expectedFiles[$index].Name -and
                [string]$actualFiles[$index].RelativePath -ceq
                    [string]$expectedFiles[$index].RelativePath -and
                (Normalize-Sha256 ([string]$actualFiles[$index].Sha256)) -ceq
                    (Normalize-Sha256 ([string]$expectedFiles[$index].Sha256))) `
                "$Label producer-lineage entry $index drifted."
    }
    $actualDigest = Normalize-Sha256 ([string]$Actual.DigestSha256)
    Require ($actualDigest -ceq (Get-ProducerLineageDigest $actualFiles) -and
            $actualDigest -ceq (Normalize-Sha256 ([string]$Expected.DigestSha256))) `
            "$Label producer-lineage digest drifted."
}

function Assert-ProducerLineageUnchanged {
    param([string] $Label = 'A/B producer')
    Require ($null -ne $script:ActiveProducerLineage) `
            "$Label lineage was not initialized."
    $current = Get-ProducerLineageSnapshot
    Assert-ProducerLineageObject $current $script:ActiveProducerLineage $Label
}

function Enter-ProducerReadLocks {
    $streams = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        $paths = @($PSCommandPath) + @(
            Get-ProducerDependencyDefinitions | ForEach-Object { $_.Path })
        foreach ($path in $paths) {
            $full = Assert-NoReparseContainment $path $script:RepoRoot `
                    'A/B producer read lock'
            $streams.Add([IO.File]::Open($full, [IO.FileMode]::Open,
                    [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        Assert-ProducerLineageUnchanged 'locked A/B producer'
        return $streams
    } catch {
        foreach ($stream in $streams) { $stream.Dispose() }
        throw
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
    return [pscustomobject]@{ Path = $item.FullName; SizeBytes = [int64]$item.Length; Sha256 = $sha }
}

function Get-FabricMetadata {
    param([Parameter(Mandatory)][string] $Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'fabric.mod.json' })
        Require ($entries.Count -eq 1) 'Fabric candidate must contain one root fabric.mod.json.'
        $reader = [IO.StreamReader]::new($entries[0].Open(), [Text.UTF8Encoding]::new($false, $true))
        try { $fabric = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    return [pscustomobject]@{
        Id = [string]$fabric.id
        Version = [string]$fabric.version
        Minecraft = [string](@($fabric.depends.minecraft)[0])
        Java = [string](@($fabric.depends.java)[0])
    }
}

function Invoke-OfflineApkVerification {
    param([Parameter(Mandatory)][string] $Path)
    Assert-ProducerLineageUnchanged 'before APK verification'
    $values = @(& $script:ApkVerifier -ApkPath $Path `
            -ExpectedPackage $script:Package `
            -ExpectedVersionCode $script:ExpectedVersionCode `
            -ExpectedVersionName $script:ExpectedVersionName `
            -ExpectedLabel $script:ExpectedLabel `
            -ExpectedVivecraftSha256 $script:Rc4CoreSha256 `
            -ExpectedVivecraftVersion $script:Rc4CoreVersion `
            -ExpectedAddOnSha256 $script:Rc4VeqSha256 `
            -ExpectedAddOnVersion $script:Rc4VeqVersion `
            -ExpectedLwjglSha256 $script:ExpectedLwjglSha256 `
            -ExpectedSignerSha256 $script:ExpectedSignerSha256)
    $result = Get-ExactObject $values 'Package' 'APK verifier'
    Require ([string]$result.Package -ceq $script:Package) 'APK verifier returned the wrong package.'
    Require ((Normalize-Sha256 ([string]$result.Sha256)) -ceq $script:ExpectedApkSha256) `
            'APK verifier returned the wrong integrated RC4 APK.'
    Assert-ProducerLineageUnchanged 'after APK verification'
    return $result
}

function Invoke-OfflineHelperSelfTest {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Label)
    Assert-ProducerLineageUnchanged "before $Label Host SelfTest"
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Label helper is missing."
    Require (-not (Test-Path -LiteralPath $script:OfflineAdbSentinel)) `
            'The Host-only impossible-ADB sentinel unexpectedly exists.'
    $savedPath = $env:PATH
    $savedLocalAppData = $env:LOCALAPPDATA
    $savedAndroidHome = $env:ANDROID_HOME
    $savedAndroidSdkRoot = $env:ANDROID_SDK_ROOT
    try {
        # Child coordinator SelfTests may invoke their own child scripts without
        # forwarding -AdbPath. Remove only PATH entries that expose an adb
        # executable, retaining tar/Java used by legitimate offline validators.
        $separator = [string][IO.Path]::PathSeparator
        $filteredPath = @($savedPath -split [regex]::Escape($separator) | Where-Object {
            $entry = [string]$_
            if ([string]::IsNullOrWhiteSpace($entry)) { return $false }
            foreach ($name in @('adb.exe', 'adb.cmd', 'adb.bat', 'adb')) {
                if (Test-Path -LiteralPath (Join-Path $entry $name) -PathType Leaf) { return $false }
            }
            return $true
        }) -join $separator
        $env:PATH = $filteredPath
        $env:LOCALAPPDATA = $script:OfflineSdkSentinel
        $env:ANDROID_HOME = $script:OfflineSdkSentinel
        $env:ANDROID_SDK_ROOT = $script:OfflineSdkSentinel
        Require ($null -eq (Get-Command adb -ErrorAction SilentlyContinue)) `
                "$Label Host SelfTest could still discover a real ADB command."
        $values = @(& $Path -Action SelfTest -AdbPath $script:OfflineAdbSentinel `
                -Serial 'offline-proof')
    } finally {
        $env:PATH = $savedPath
        $env:LOCALAPPDATA = $savedLocalAppData
        $env:ANDROID_HOME = $savedAndroidHome
        $env:ANDROID_SDK_ROOT = $savedAndroidSdkRoot
    }
    $result = Get-ExactObject $values 'Result' "$Label SelfTest"
    Require ([string]$result.Result -ceq 'PASS') "$Label SelfTest failed."
    if ($null -ne $result.PSObject.Properties['DeviceTouched']) {
        Require (-not [bool]$result.DeviceTouched) "$Label SelfTest touched a device."
    }
    if ($null -ne $result.PSObject.Properties['AdbInvocations']) {
        Require ([int]$result.AdbInvocations -eq 0) "$Label SelfTest invoked ADB."
    }
    Assert-ProducerLineageUnchanged "after $Label Host SelfTest"
    return $result
}

function Resolve-HostContract {
    param([switch] $AllowPendingApk)
    if ($script:HostResolved) { return }
    $before = $script:DeviceInvocationCount
    foreach ($path in @($script:PairScript, $script:CoreCanaryScript,
            $script:VeqLabScript, $script:ResetScript, $script:AutoplayScript,
            $script:BenchmarkScript, $script:ApkVerifier, $script:Rc4LockPath,
            $script:Rc3LockPath)) {
        Require (Test-Path -LiteralPath $path -PathType Leaf) "Required Host contract is missing: $path"
    }
    $script:ActiveProducerLineage = Get-ProducerLineageSnapshot
    $hostProducerLocks = @(Enter-ProducerReadLocks)
    try {

    $rc3Core = Get-FileIdentity $script:Rc3CorePath $script:Rc3CoreSha256 `
            $script:Rc3CoreSizeBytes 'RC3 Core'
    $rc3Veq = Get-FileIdentity $script:Rc3VeqPath $script:Rc3VeqSha256 `
            $script:Rc3VeqSizeBytes 'RC3 VEQ'
    $apkReady = $script:ExpectedApkSha256 -cmatch '^[0-9A-F]{64}$' -and
        $script:ExpectedApkSha256 -cnotmatch '^0{64}$' -and
        $script:ExpectedApkSizeBytes -gt 0 -and
        [bool]$script:Rc4CandidateLock.target.artifactAuditPassed
    if ($apkReady) {
        $null = Get-FileIdentity $script:Rc4ApkPath $script:ExpectedApkSha256 `
                $script:ExpectedApkSizeBytes 'integrated RC4 Lab APK'
    } else {
        Require $AllowPendingApk.IsPresent `
            'The exact RC4 Lab APK is pending build and artifact audit.'
        Require ($script:ExpectedApkSha256 -ceq ('0' * 64) -and
            $script:ExpectedApkSizeBytes -eq 0 -and
            -not [bool]$script:Rc4CandidateLock.target.artifactAuditPassed) `
            'The RC4 pending-APK state is ambiguous.'
    }

    $coreMetadata = Get-FabricMetadata $rc3Core.Path
    Require ($coreMetadata.Id -ceq 'vivecraft' -and
            $coreMetadata.Version -ceq $script:Rc3CoreVersion -and
            $coreMetadata.Minecraft -ceq '26.2.x' -and
            $coreMetadata.Java -ceq '>=25') 'RC3 Core Fabric metadata mismatch.'
    $veqMetadata = Get-FabricMetadata $rc3Veq.Path
    Require ($veqMetadata.Id -ceq 'vivecraft_essentials_quest' -and
            $veqMetadata.Version -ceq $script:Rc3VeqVersion -and
            $veqMetadata.Minecraft -ceq '26.2' -and
            $veqMetadata.Java -ceq '>=25') 'RC3 VEQ Fabric metadata mismatch.'

    $rc4Lock = Get-Content -Raw -LiteralPath $script:Rc4LockPath | ConvertFrom-Json
    Require ([string]$rc4Lock.target.package -ceq $script:Package) 'RC4 lock package mismatch.'
    Require ([string]$rc4Lock.target.forbiddenStablePackage -ceq $script:ForbiddenStablePackage -and
            -not [bool]$rc4Lock.target.stableTouched) 'RC4 lock no longer protects Stable.'
    Require ((Normalize-Sha256 ([string]$rc4Lock.target.labShellApkSha256)) -ceq
            $script:ExpectedApkSha256) 'RC4 lock APK hash mismatch.'
    Require ([int64]$rc4Lock.target.labShellApkSizeBytes -eq $script:ExpectedApkSizeBytes) `
            'RC4 lock APK size mismatch.'
    Require ((Normalize-Sha256 ([string]$rc4Lock.pair.core.sha256)) -ceq $script:Rc4CoreSha256 -and
            [int64]$rc4Lock.pair.core.sizeBytes -eq $script:Rc4CoreSizeBytes -and
            [string]$rc4Lock.pair.core.fabricVersion -ceq $script:Rc4CoreVersion) `
            'RC4 Core lock mismatch.'
    Require ((Normalize-Sha256 ([string]$rc4Lock.pair.veq.sha256)) -ceq $script:Rc4VeqSha256 -and
            [int64]$rc4Lock.pair.veq.sizeBytes -eq $script:Rc4VeqSizeBytes -and
            [string]$rc4Lock.pair.veq.fabricVersion -ceq $script:Rc4VeqVersion) `
            'RC4 VEQ lock mismatch.'

    $rc3Lock = Get-Content -Raw -LiteralPath $script:Rc3LockPath | ConvertFrom-Json
    Require ([string]$rc3Lock.target.package -ceq $script:Package -and
            [string]$rc3Lock.target.forbiddenStablePackage -ceq $script:ForbiddenStablePackage -and
            -not [bool]$rc3Lock.target.stableTouched) 'RC3 lock no longer protects Stable.'
    Require ((Normalize-Sha256 ([string]$rc3Lock.pair.core.sha256)) -ceq $script:Rc3CoreSha256 -and
            [int64]$rc3Lock.pair.core.sizeBytes -eq $script:Rc3CoreSizeBytes) 'RC3 Core lock mismatch.'
    Require ((Normalize-Sha256 ([string]$rc3Lock.pair.veq.sha256)) -ceq $script:Rc3VeqSha256 -and
            [int64]$rc3Lock.pair.veq.sizeBytes -eq $script:Rc3VeqSizeBytes) 'RC3 VEQ lock mismatch.'

    $null = Invoke-OfflineHelperSelfTest $script:PairScript 'paired Core/VEQ'
    $null = Invoke-OfflineHelperSelfTest $script:ResetScript 'benchmark-world reset'
    $null = Invoke-OfflineHelperSelfTest $script:AutoplayScript 'autoplay'
    $benchmarkSelfTest = Invoke-OfflineHelperSelfTest $script:BenchmarkScript 'VrApi benchmark'
    Require ([bool]$benchmarkSelfTest.ReservedLastExitCodeAssignmentGuard) `
            'VrApi benchmark SelfTest did not prove its reserved-variable assignment guard.'
    if ($apkReady) { $null = Invoke-OfflineApkVerification $script:Rc4ApkPath }
    Assert-ProducerLineageUnchanged 'Host-contract A/B producer'
    Require ($script:DeviceInvocationCount -eq $before) 'Host contract resolution invoked a device command.'
    $script:HostResolved = $true
    } finally {
        foreach ($stream in $hostProducerLocks) { $stream.Dispose() }
    }
}

function Assert-RunAuthorization {
    param([bool] $Read, [bool] $Write, [bool] $Launch)
    Require $Read 'Run is disabled until -AllowDeviceRead is explicit.'
    Require $Write 'Run is disabled until -AllowDeviceWrite is explicit.'
    Require $Launch 'Run is disabled until -AllowLaunch is explicit.'
}

function Enter-GlobalCampaignLock {
    $lockPath = Assert-NoReparseContainment $script:GlobalLockPath `
            $script:WorkspaceRoot 'global campaign lock'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lockPath)) | Out-Null
    $null = Assert-NoReparseContainment ([IO.Path]::GetDirectoryName($lockPath)) `
            $script:WorkspaceRoot 'global campaign-lock directory'
    try {
        # OpenOrCreate avoids a stale-file bypass; FileShare.None is the actual
        # machine-wide exclusion and remains valid across all output folders.
        return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw '[FATAL_GLOBAL_LOCK] Another v71 RC3/RC4 campaign owns the fixed global lock.'
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
    throw 'ADB was not found. Pass -AdbPath with the exact adb.exe path.'
}

function Invoke-Adb {
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $script:DeviceInvocationCount++
    $lines = @(& $script:ResolvedAdb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $operation = @(
            Get-PSCallStack | ForEach-Object { [string]$_.FunctionName } |
                Where-Object {
                    $_ -notin @('Invoke-Adb', 'Invoke-DeviceShell', '<ScriptBlock>', 'script')
                }
        ) | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($operation)) { $operation = 'unknown-operation' }
        throw "ADB failed in $operation with exit code $exitCode; device output was suppressed."
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Resolve-Device {
    $script:ResolvedAdb = Resolve-Adb
    if ($Serial -ne 'auto') {
        $script:ResolvedSerial = $Serial
    } else {
        $probe = Invoke-Adb @('devices')
        $devices = @($probe.Lines | ForEach-Object {
            if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { $Matches.serial }
        })
        Require ($devices.Count -eq 1) 'Exactly one authorized ADB device is required, or pass -Serial.'
        $script:ResolvedSerial = [string]$devices[0]
    }
    $state = Invoke-Adb @('-s', $script:ResolvedSerial, 'get-state')
    Require (($state.Lines -join '').Trim() -ceq 'device') 'The selected ADB target is not ready.'
    $script:DeviceReady = $true
}

function ConvertTo-ShLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    $quote = [string][char]39
    $double = [string][char]34
    return $quote + $Value.Replace($quote, ($quote + $double + $quote + $double + $quote)) + $quote
}

function Invoke-DeviceShell {
    param([Parameter(Mandatory)][string] $Command, [switch] $AllowFailure)
    return Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'shell', $Command) `
            -AllowFailure:$AllowFailure
}

function Get-DevicePerformanceLevels {
    param([Parameter(Mandatory)][string] $Label)
    $result = Invoke-DeviceShell -Command (New-PerformanceLevelProbeCommand) -AllowFailure
    return Read-ExactPerformanceLevelProbe -ExitCode $result.ExitCode `
            -Lines @($result.Lines) -Label $Label
}

function Initialize-PerformanceLevelLease {
    Require ($null -eq $script:PerformanceLeaseSnapshot) `
            'The performance-level lease was already initialized.'
    Assert-StableStopped
    Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
            'Lab became active before the exact performance-level snapshot.'
    $snapshot = Get-DevicePerformanceLevels 'performance-level lease snapshot'
    Assert-StableStopped
    Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
            'Lab became active while taking the exact performance-level snapshot.'
    $script:PerformanceLeaseSnapshot = $snapshot
    return Get-PerformanceLevelEvidence $snapshot
}

function Enter-PerformanceLevelLease {
    param(
        [Parameter(Mandatory)][int] $ExpectedPid,
        [Parameter(Mandatory)][string] $Label
    )
    Require ($null -ne $script:PerformanceLeaseSnapshot) `
            "$Label has no exact pre-campaign performance-level snapshot."
    Require (-not $script:PerformanceLeaseActive) "$Label attempted to overlap a performance-level lease."
    Assert-StableStopped
    Require ((Get-ExactPid $script:Package) -eq $ExpectedPid) `
            "$Label changed PID before applying CPU/GPU 4/4."
    $script:PerformanceLeaseMutationStarted = $true
    $command = New-PerformanceLevelMutationCommand `
            ([string]$script:ExpectedCpuLevel) ([string]$script:ExpectedGpuLevel)
    $result = Invoke-DeviceShell -Command $command -AllowFailure
    $actual = Read-ExactPerformanceLevelProbe -ExitCode $result.ExitCode `
            -Lines @($result.Lines) -Label "$Label CPU/GPU 4/4 application"
    Require ([string]$actual.Cpu -ceq ([string]$script:ExpectedCpuLevel) -and
            [string]$actual.Gpu -ceq ([string]$script:ExpectedGpuLevel)) `
            "$Label could not verify exact CPU/GPU 4/4."
    Assert-StableStopped
    Require ((Get-ExactPid $script:Package) -eq $ExpectedPid) `
            "$Label changed PID while applying CPU/GPU 4/4."
    $script:PerformanceLeaseActive = $true
    $script:PerformanceLeaseApplications++
    return [pscustomobject]@{
        AppliedAfterWorldReady = $true
        VerifiedBeforeWarmup = $true
        CpuLevel = [int]$actual.Cpu
        GpuLevel = [int]$actual.Gpu
        RefreshPropertiesModified = $false
        AdaptivePropertiesModified = $false
    }
}

function Restore-PerformanceLevelLeaseFailClosed {
    param([Parameter(Mandatory)][string] $Context)
    if (-not $script:PerformanceLeaseMutationStarted) { return }
    Require ($null -ne $script:PerformanceLeaseSnapshot) `
            "[FATAL_PERFORMANCE_LEASE] $Context lost its exact original-level snapshot."
    $command = New-PerformanceLevelMutationCommand `
            ([string]$script:PerformanceLeaseSnapshot.Cpu) `
            ([string]$script:PerformanceLeaseSnapshot.Gpu)
    $result = Invoke-DeviceShell -Command $command -AllowFailure
    try {
        $actual = Read-ExactPerformanceLevelProbe -ExitCode $result.ExitCode `
                -Lines @($result.Lines) -Label "$Context performance-level restoration"
        Require ([string]$actual.Cpu -ceq [string]$script:PerformanceLeaseSnapshot.Cpu -and
                [string]$actual.Gpu -ceq [string]$script:PerformanceLeaseSnapshot.Gpu) `
                "$Context did not restore both original performance levels exactly."
    } catch {
        throw "[FATAL_PERFORMANCE_LEASE] $($_.Exception.Message)"
    }
    $script:PerformanceLeaseActive = $false
}

function Read-ExactPidProbe {
    param(
        [Parameter(Mandatory)][int] $ExitCode,
        [AllowEmptyCollection()][string[]] $Lines = @(),
        [switch] $AllowMissing,
        [Parameter(Mandatory)][string] $Package
    )
    $text = (@($Lines | ForEach-Object { [string]$_ }) -join "`n")
    if ($ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($text)) {
        if ($AllowMissing) { return $null }
        throw "No PID was found for $Package."
    }
    Require ($ExitCode -eq 0) `
        "Could not prove the PID state for $Package (exit $ExitCode)."
    $match = [regex]::Match($text, '^\s*(?<pid>[1-9][0-9]*)\s*$')
    Require $match.Success `
        "PID response for $Package was empty, multiple, or contaminated."
    [long] $pidValue = 0
    Require ([long]::TryParse($match.Groups['pid'].Value, [ref]$pidValue) -and
            $pidValue -le [int]::MaxValue) `
        "PID response for $Package was outside the positive Int32 range."
    return [int]$pidValue
}

function Get-ExactPid {
    param([Parameter(Mandatory)][string] $Package, [switch] $AllowMissing)
    $probe = Invoke-DeviceShell -Command ('pidof ' + (ConvertTo-ShLiteral $Package)) -AllowFailure
    return Read-ExactPidProbe -ExitCode $probe.ExitCode -Lines @($probe.Lines) `
            -AllowMissing:$AllowMissing -Package $Package
}

function Test-LabFocused {
    $result = Invoke-DeviceShell -Command 'dumpsys activity activities' -AllowFailure
    if ($result.ExitCode -ne 0) { return $false }
    $active = $result.Lines | Where-Object { $_ -match 'topResumedActivity' } | Select-Object -First 1
    if ($null -eq $active) {
        $active = $result.Lines | Where-Object { $_ -match '(?:mResumedActivity|ResumedActivity)' } |
                Select-Object -First 1
    }
    return $null -ne $active -and
            [string]$active -match ([regex]::Escape($script:Package) + '/')
}

function Assert-InitialDeviceState {
    Require ($null -eq (Get-ExactPid $script:ForbiddenStablePackage -AllowMissing)) `
            'Stable is running. Stop it manually; this Lab orchestrator will not touch it.'
    Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
            'Lab is already running. Stop the supervised session or memory soak before Run.'
}

function Assert-StableStopped {
    Require ($null -eq (Get-ExactPid $script:ForbiddenStablePackage -AllowMissing)) `
            '[FATAL_STABLE_ACTIVE] Stable became active during the Lab campaign. It was not touched.'
}

function Get-ExactPmBaseApkPath {
    param([Parameter(Mandatory)][string[]] $Lines)
    Require ($Lines.Count -eq 1) `
            'pm path must return exactly one line; split or contaminated installs are rejected.'
    $row = [string]$Lines[0]
    Require ($row -cmatch '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$') `
            'pm path did not return one exact /data/app/.../base.apk row.'
    $path = [string]$Matches.path
    Require (-not $path.Contains('..') -and -not $path.Contains('\\') -and
            -not $path.Contains("`0")) 'Installed base.apk path is unsafe.'
    return $path
}

function Invoke-VerifyInstalledRc4Apk {
    $paths = Invoke-DeviceShell -Command ('pm path ' + (ConvertTo-ShLiteral $script:Package))
    $remote = Get-ExactPmBaseApkPath ([string[]]@($paths.Lines))
    $temporaryRoot = Join-Path $script:ArtifactsRoot `
            ('installed-apk-proof-' + [guid]::NewGuid().ToString('N'))
    $null = Assert-NoReparseContainment $temporaryRoot $script:WorkspaceRoot `
            'installed APK proof directory'
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    $null = Assert-NoReparseContainment $temporaryRoot $script:WorkspaceRoot `
            'created installed APK proof directory'
    $local = Join-Path $temporaryRoot 'base.apk'
    try {
        $null = Invoke-Adb @('-s', $script:ResolvedSerial, 'pull', $remote, $local)
        $identity = Get-FileIdentity $local $script:ExpectedApkSha256 `
                $script:ExpectedApkSizeBytes 'installed integrated RC4 Lab APK'
        $verified = Invoke-OfflineApkVerification $identity.Path
        return [pscustomobject]@{
            Package = [string]$verified.Package
            VersionCode = [string]$verified.VersionCode
            VersionName = [string]$verified.VersionName
            Sha256 = (Normalize-Sha256 ([string]$verified.Sha256))
            SignerSha256 = (Normalize-Sha256 ([string]$verified.SignerSha256))
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            $null = Assert-NoReparseContainment $temporaryRoot $script:ArtifactsRoot `
                    'installed APK proof cleanup directory'
            [IO.Directory]::Delete($temporaryRoot, $true)
        }
    }
}

function Stop-Lab {
    $null = Invoke-DeviceShell -Command ('am force-stop ' + (ConvertTo-ShLiteral $script:Package))
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ($null -eq (Get-ExactPid $script:Package -AllowMissing)) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'Lab app/JVM did not stop in the bounded window.'
}

function Get-PairArguments {
    $arguments = @{
        Serial = $script:ResolvedSerial
        AdbPath = $script:ResolvedAdb
        ExpiryMinutes = 15
    }
    if ($AllowRootFallback) { $arguments.AllowRootFallback = $true }
    return $arguments
}

function Invoke-PairedRollback {
    Assert-ProducerLineageUnchanged 'before paired rollback'
    $arguments = Get-PairArguments
    $values = @(& $script:PairScript -Action Rollback -AllowDeviceWrite @arguments)
    $result = Get-ExactObject $values 'Result' 'paired rollback'
    Require ([string]$result.Result -ceq 'PAIRED_ROLLBACK_COMPLETE') `
            'Paired rollback did not restore both RC4 baselines.'
    Assert-ProducerLineageUnchanged 'after paired rollback'
    return $result
}

function Invoke-PairedDeployRc3 {
    Assert-ProducerLineageUnchanged 'before paired RC3 deployment'
    $arguments = Get-PairArguments
    $values = @(& $script:PairScript -Action Deploy `
            -CoreJarPath $script:Rc3CorePath -CoreExpectedSha256 $script:Rc3CoreSha256 `
            -VeqJarPath $script:Rc3VeqPath -VeqExpectedSha256 $script:Rc3VeqSha256 `
            -AllowDeviceWrite @arguments)
    $result = Get-ExactObject $values 'Result' 'paired RC3 deployment'
    Require ([string]$result.Result -ceq 'PAIRED_ARMED') 'RC3 pair was not armed atomically.'
    Require ((Normalize-Sha256 ([string]$result.Core.CandidateSha256)) -ceq $script:Rc3CoreSha256 -and
            (Normalize-Sha256 ([string]$result.Veq.CandidateSha256)) -ceq $script:Rc3VeqSha256) `
            'Paired deployment armed the wrong RC3 artifacts.'
    Assert-ProducerLineageUnchanged 'after paired RC3 deployment'
    return $result
}

function Get-PairedStatus {
    Assert-ProducerLineageUnchanged 'before paired status'
    $arguments = Get-PairArguments
    $values = @(& $script:PairScript -Action Status @arguments)
    $result = Get-ExactObject $values 'Result' 'paired status'
    Require ([string]$result.Result -ceq 'PAIRED_STATUS' -and
            [string]$result.Package -ceq $script:Package) 'Paired status returned the wrong target.'
    Assert-ProducerLineageUnchanged 'after paired status'
    return $result
}

function Assert-PairedRuntimeState {
    param([Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition)
    $status = Get-PairedStatus
    $expectedCore = if ($Condition -ceq 'A') { $script:Rc3CoreSha256 } else { $script:Rc4CoreSha256 }
    $expectedVeq = if ($Condition -ceq 'A') { $script:Rc3VeqSha256 } else { $script:Rc4VeqSha256 }
    $expectedMarker = if ($Condition -ceq 'A') { 'consumed' } else { 'absent' }
    Require ((Normalize-Sha256 ([string]$status.Core.TargetSha256)) -ceq $expectedCore -and
            (Normalize-Sha256 ([string]$status.Veq.TargetSha256)) -ceq $expectedVeq) `
            "Condition $Condition loaded the wrong Core/VEQ pair."
    Require ([string]$status.Core.MarkerState -ceq $expectedMarker -and
            [string]$status.Veq.MarkerState -ceq $expectedMarker) `
            "Condition $Condition has the wrong one-shot marker state."
    Require ([string]$status.Core.OtherModsFingerprintSha256 -ceq
            [string]$status.Veq.OtherModsFingerprintSha256) `
            'Core and VEQ disagree about the other-mod fingerprint.'
    $fingerprint = Normalize-Sha256 ([string]$status.Core.OtherModsFingerprintSha256)
    if ($null -eq $script:ExpectedOtherModsFingerprint) {
        $script:ExpectedOtherModsFingerprint = $fingerprint
    } else {
        Require ($fingerprint -ceq $script:ExpectedOtherModsFingerprint) `
                'The non-Core/VEQ mod fingerprint changed during A/B.'
    }
    return [pscustomobject]@{
        CoreSha256 = $expectedCore
        VeqSha256 = $expectedVeq
        OtherModsFingerprintSha256 = $fingerprint
        MarkerState = $expectedMarker
    }
}

function Restore-Rc4FailClosed {
    param([Parameter(Mandatory)][string] $Context, $Freshness = $null)

    if ($null -eq $Freshness) { $Freshness = $script:ActiveReadinessMarker }

    # Each cleanup operation is attempted independently. In particular, an ADB
    # failure while stopping Lab must not skip the exact paired rollback attempt.
    $errors = [Collections.Generic.List[string]]::new()
    try {
        Stop-Lab
    } catch {
        $errors.Add("stop failed: $($_.Exception.Message)")
    }
    try {
        Remove-WorldReadinessMarker $Freshness
    } catch {
        $errors.Add("readiness-marker cleanup failed: $($_.Exception.Message)")
    }
    try {
        $null = Invoke-PairedRollback
    } catch {
        $errors.Add("paired RC4 rollback failed: $($_.Exception.Message)")
    }
    try {
        Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
                'Lab is still running after cleanup.'
        $null = Assert-PairedRuntimeState B
    } catch {
        $errors.Add("final RC4 verification failed: $($_.Exception.Message)")
    }
    if ($errors.Count -gt 0) {
        throw "[FATAL_CLEANUP] $Context did not finish on stopped, exact RC4: $($errors -join ' ')"
    }
}

function Restore-RoundAndLeaseFailClosed {
    param([Parameter(Mandatory)][string] $Context, $Freshness = $null)
    $errors = [Collections.Generic.List[string]]::new()
    try {
        Restore-Rc4FailClosed $Context $Freshness
    } catch {
        $errors.Add("RC4 cleanup failed: $($_.Exception.Message)")
    }
    try {
        Restore-PerformanceLevelLeaseFailClosed $Context
    } catch {
        $errors.Add("performance-level cleanup failed: $($_.Exception.Message)")
    }
    try {
        Assert-StableStopped
    } catch {
        $errors.Add("Stable-stop proof failed: $($_.Exception.Message)")
    }
    if ($errors.Count -gt 0) {
        throw "[FATAL_CLEANUP] $Context cleanup was incomplete: $($errors -join ' ')"
    }
}

function Invoke-WorldReset {
    Assert-ProducerLineageUnchanged 'before benchmark-world reset'
    $values = @(& $script:ResetScript -Action Reset -Serial $script:ResolvedSerial `
            -AdbPath $script:ResolvedAdb -AllowDeviceWrite)
    $result = Get-ExactObject $values 'Result' 'benchmark-world reset'
    Require ([string]$result.Result -ceq 'RESET' -and
            (Normalize-Sha256 ([string]$result.MasterSha256)) -ceq $script:WorldMasterSha256) `
            'Benchmark-world reset did not restore the exact master.'
    Assert-ProducerLineageUnchanged 'after benchmark-world reset'
}

function New-WorldReadinessMarker {
    $token = [guid]::NewGuid().ToString('N')
    $files = "/sdcard/Android/data/$script:Package/files"
    $canonicalFiles = "/storage/emulated/0/Android/data/$script:Package/files"
    $log = "$files/instances/$script:Profile/logs/latest.log"
    $state = "$files/.questcraft/v71-ab-readiness"
    $marker = "$state/round-$token.marker"
    $script:ActiveReadinessMarker = [pscustomobject]@{
        Token = $token
        MarkerPath = $marker
    }
    $qFiles = ConvertTo-ShLiteral $files
    $qCanonicalFiles = ConvertTo-ShLiteral $canonicalFiles
    $qLog = ConvertTo-ShLiteral $log
    $qState = ConvertTo-ShLiteral $state
    $qMarker = ConvertTo-ShLiteral $marker
    $qToken = ConvertTo-ShLiteral $token
    $command = @(
        'set -eu'
        ('files=$(realpath {0})' -f $qFiles)
        ('test "$files" = {0} || test "$files" = {1}' -f $qFiles, $qCanonicalFiles)
        ('log={0}' -f $qLog)
        ('state={0}' -f $qState)
        ('marker={0}' -f $qMarker)
        'mkdir -p "$state"'
        'test -d "$state" && test ! -L "$state"'
        'test ! -e "$marker" && test ! -e "$marker.tmp"'
        'baseline_inode=ABSENT'
        'baseline_size=0'
        'baseline_prefix_bytes=0'
        'baseline_prefix=ABSENT'
        'if [ -e "$log" ]; then'
        '  test -f "$log" && test ! -L "$log"'
        '  baseline_inode=$(stat -c %i "$log")'
        '  baseline_size=$(stat -c %s "$log")'
        '  if [ "$baseline_size" -gt 0 ]; then'
        '    baseline_prefix_bytes=$baseline_size'
        '    if [ "$baseline_prefix_bytes" -gt 4096 ]; then baseline_prefix_bytes=4096; fi'
        '    baseline_prefix=$(head -c "$baseline_prefix_bytes" "$log" | sha256sum | cut -d " " -f 1)'
        '  else baseline_prefix=EMPTY; fi'
        'fi'
        ('printf ''%s\n'' {0} > "$marker.tmp"' -f $qToken)
        'mv "$marker.tmp" "$marker"'
        'test -f "$marker" && test ! -L "$marker"'
        'marker_mtime=$(stat -c %Y "$marker")'
        'printf ''FRESH_BASELINE\t%s\t%s\t%s\t%s\t%s\n'' "$baseline_inode" "$baseline_size" "$baseline_prefix_bytes" "$baseline_prefix" "$marker_mtime"'
    ) -join "`n"
    $result = Invoke-DeviceShell -Command $command
    $rows = @($result.Lines | Where-Object {
        $_ -cmatch '^FRESH_BASELINE\t(?:ABSENT|[0-9]+)\t[0-9]+\t[0-9]+\t(?:ABSENT|EMPTY|[0-9a-f]{64})\t[0-9]+$'
    })
    Require ($rows.Count -eq 1) 'Device readiness marker did not return one strict baseline row.'
    $null = $rows[0] -cmatch '^FRESH_BASELINE\t(?<inode>ABSENT|[0-9]+)\t(?<size>[0-9]+)\t(?<prefixBytes>[0-9]+)\t(?<prefix>ABSENT|EMPTY|[0-9a-f]{64})\t(?<mtime>[0-9]+)$'
    $proof = [pscustomobject]@{
        Token = $token
        MarkerPath = $marker
        MarkerMtime = [int64]$Matches.mtime
        BaselineInode = [string]$Matches.inode
        BaselineSize = [int64]$Matches.size
        BaselinePrefixBytes = [int]$Matches.prefixBytes
        BaselinePrefixSha256 = [string]$Matches.prefix
    }
    $script:ActiveReadinessMarker = $proof
    return $proof
}

function Remove-WorldReadinessMarker {
    param($Freshness)
    if ($null -eq $Freshness) { return }
    $expectedPrefix = "/sdcard/Android/data/$script:Package/files/.questcraft/v71-ab-readiness/round-"
    Require ([string]$Freshness.MarkerPath -cmatch ('^' + [regex]::Escape($expectedPrefix) +
            '[0-9a-f]{32}\.marker$')) 'Refusing to remove an unexpected readiness-marker path.'
    $qMarker = ConvertTo-ShLiteral ([string]$Freshness.MarkerPath)
    $result = Invoke-DeviceShell -Command "rm -f $qMarker $qMarker.tmp; test ! -e $qMarker"
    Require ($result.ExitCode -eq 0) 'Could not remove the bounded readiness marker.'
    $script:ActiveReadinessMarker = $null
}

function Start-LabAutoplay {
    Assert-ProducerLineageUnchanged 'before Lab autoplay'
    $values = @(& $script:AutoplayScript -Action ArmAndRun -Serial $script:ResolvedSerial `
            -AdbPath $script:ResolvedAdb -LauncherCameraPark ON -AllowLaunch)
    $result = Get-ExactObject $values 'Result' 'Lab autoplay'
    Require ([string]$result.Result -ceq 'ARMED' -and
            [string]$result.Package -ceq $script:Package -and
            [string]$result.World -ceq $script:World) 'Autoplay armed the wrong target.'
    Require ([string]$result.CancellationRunId -cmatch '^[A-Za-z0-9_-]+$') `
            'Autoplay did not return its fresh process-local run marker.'
    Assert-ProducerLineageUnchanged 'after Lab autoplay'
    return $result
}

function Wait-LabWorldReady {
    param(
        [Parameter(Mandatory)] $Freshness,
        [Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition
    )
    $log = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/logs/latest.log"
    $coreVersion = if ($Condition -ceq 'A') { $script:Rc3CoreVersion } else { $script:Rc4CoreVersion }
    $qLog = ConvertTo-ShLiteral $log
    $qMarker = ConvertTo-ShLiteral ([string]$Freshness.MarkerPath)
    $qToken = ConvertTo-ShLiteral ([string]$Freshness.Token)
    $qCoreVersion = ConvertTo-ShLiteral $coreVersion
    $qVeqVersion = ConvertTo-ShLiteral $script:Rc4VeqVersion
    $baselineInode = [string]$Freshness.BaselineInode
    $baselinePrefix = [string]$Freshness.BaselinePrefixSha256
    $baselinePrefixBytes = [int]$Freshness.BaselinePrefixBytes
    $baselineSize = [int64]$Freshness.BaselineSize
    $markerMtime = [int64]$Freshness.MarkerMtime
    $deadline = [DateTime]::UtcNow.AddSeconds($script:ReadyTimeoutSeconds)
    $firstObservedPid = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        Assert-StableStopped
        $observedPid = Get-ExactPid $script:Package -AllowMissing
        if ($null -eq $observedPid) {
            Require ($null -eq $firstObservedPid) `
                    'Lab PID disappeared after autoplay began; refusing cross-launch readiness evidence.'
            Start-Sleep -Seconds 1
            continue
        }
        if ($null -eq $firstObservedPid) {
            $firstObservedPid = [int]$observedPid
        } else {
            Require ([int]$observedPid -eq [int]$firstObservedPid) `
                    'Lab PID changed after autoplay began; refusing cross-launch readiness evidence.'
        }
        $command = @(
            'set -eu'
            ('log={0}' -f $qLog)
            ('marker={0}' -f $qMarker)
            'test -f "$marker" && test ! -L "$marker"'
            ('test "$(cat "$marker")" = {0}' -f $qToken)
            ('test "$(stat -c %Y "$marker")" -eq {0}' -f $markerMtime)
            'test -f "$log" && test ! -L "$log"'
            'log_mtime=$(stat -c %Y "$log")'
            ('test "$log_mtime" -gt {0}' -f $markerMtime)
            'inode=$(stat -c %i "$log")'
            'size=$(stat -c %s "$log")'
            'start=1'
            'slice=NEW_FILE'
            ('if [ {0} != ABSENT ] && [ "$inode" = {0} ] && [ "$size" -ge {1} ]; then' -f $baselineInode, $baselineSize)
            ('  if [ {0} -gt 0 ]; then prefix=$(head -c {0} "$log" | sha256sum | cut -d " " -f 1); else prefix=EMPTY; fi' -f $baselinePrefixBytes)
            ('  if [ "$prefix" = {0} ]; then start={1}; slice=APPEND; fi' -f $baselinePrefix, ($baselineSize + 1))
            'fi'
            'adv=$(tail -c +"$start" "$log" | grep -c -E ''Loaded [0-9]+ advancements'' || true)'
            ('core=$(tail -c +"$start" "$log" | grep -F -c {0} || true)' -f $qCoreVersion)
            ('veq=$(tail -c +"$start" "$log" | grep -F -c {0} || true)' -f $qVeqVersion)
            'terminal=$(tail -c +"$start" "$log" | grep -c -E ''(^|[^[:alpha:]])Stopping!|---- Minecraft Crash Report ----|ReportedException|Minecraft has crashed|Game crashed'' || true)'
            'printf ''FRESH_READY\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n'' "$inode" "$size" "$start" "$slice" "$adv" "$core" "$veq" "$terminal" "$log_mtime"'
        ) -join "`n"
        $ready = Invoke-DeviceShell -Command $command -AllowFailure
        if ($ready.ExitCode -eq 0) {
            $rows = @($ready.Lines | Where-Object {
                $_ -cmatch '^FRESH_READY\t[0-9]+\t[0-9]+\t[0-9]+\t(?:APPEND|NEW_FILE)\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+$'
            })
            if ($rows.Count -eq 1 -and (Test-LabFocused)) {
                $null = $rows[0] -cmatch '^FRESH_READY\t(?<inode>[0-9]+)\t(?<size>[0-9]+)\t(?<start>[0-9]+)\t(?<slice>APPEND|NEW_FILE)\t(?<adv>[0-9]+)\t(?<core>[0-9]+)\t(?<veq>[0-9]+)\t(?<terminal>[0-9]+)\t(?<mtime>[0-9]+)$'
                if ([int]$Matches.adv -ge 2 -and [int]$Matches.core -ge 1 -and
                        [int]$Matches.veq -ge 1 -and [int]$Matches.terminal -eq 0) {
                    $proof = [pscustomobject]@{
                        Pid = [int]$observedPid
                        LogInode = [int64]$Matches.inode
                        LogSize = [int64]$Matches.size
                        SliceMode = [string]$Matches.slice
                        FreshByteStart = [int64]$Matches.start
                        AdvancementMarkers = [int]$Matches.adv
                        CoreVersionMarkers = [int]$Matches.core
                        VeqVersionMarkers = [int]$Matches.veq
                        MarkerMtime = $markerMtime
                        LogMtime = [int64]$Matches.mtime
                    }
                    Require ((Get-ExactPid $script:Package) -eq $observedPid) `
                            'Lab PID changed while accepting fresh world-ready evidence.'
                    return $proof
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    throw 'Lab did not produce device-marker-bounded fresh world/runtime-version evidence before timeout.'
}

function Assert-WorldSessionStillLive {
    param(
        [Parameter(Mandatory)] $Readiness,
        [Parameter(Mandatory)][int] $ExpectedPid,
        [Parameter(Mandatory)][string] $Label
    )
    Assert-StableStopped
    Require ((Get-ExactPid $script:Package) -eq $ExpectedPid) `
            "$Label changed PID after world readiness."
    $log = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/logs/latest.log"
    $qLog = ConvertTo-ShLiteral $log
    $freshStart = [int64]$Readiness.FreshByteStart
    $expectedInode = [int64]$Readiness.LogInode
    $minimumSize = [int64]$Readiness.LogSize
    Require ($freshStart -ge 1 -and $expectedInode -gt 0 -and $minimumSize -ge 0) `
            "$Label has invalid readiness bounds."
    $command = @(
        'set -eu'
        ('log={0}' -f $qLog)
        'test -f "$log" && test ! -L "$log"'
        'inode=$(stat -c %i "$log")'
        'size=$(stat -c %s "$log")'
        ('test "$inode" -eq {0}' -f $expectedInode)
        ('test "$size" -ge {0}' -f $minimumSize)
        ('terminal=$(tail -c +{0} "$log" | grep -c -E ''(^|[^[:alpha:]])Stopping!|---- Minecraft Crash Report ----|ReportedException|Minecraft has crashed|Game crashed'' || true)' -f $freshStart)
        'printf ''WORLD_LIVE\t%s\t%s\t%s\n'' "$inode" "$size" "$terminal"'
    ) -join "`n"
    $result = Invoke-DeviceShell -Command $command -AllowFailure
    Require ($result.ExitCode -eq 0) "$Label lost its original fresh world log."
    $rows = @($result.Lines | Where-Object {
        $_ -cmatch '^WORLD_LIVE\t[0-9]+\t[0-9]+\t[0-9]+$'
    })
    Require ($rows.Count -eq 1) "$Label returned ambiguous world-liveness evidence."
    $null = $rows[0] -cmatch '^WORLD_LIVE\t(?<inode>[0-9]+)\t(?<size>[0-9]+)\t(?<terminal>[0-9]+)$'
    Require ([int64]$Matches.inode -eq $expectedInode -and
            [int64]$Matches.size -ge $minimumSize -and
            [int]$Matches.terminal -eq 0) `
            "$Label contains terminal/crash evidence or a replaced world log."
    Require (Test-LabFocused) "$Label is no longer foreground-focused."
}

function Wait-HealthyWarmup {
    param(
        [Parameter(Mandatory)][int] $Seconds,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][int] $ExpectedPid
    )
    Assert-StableStopped
    Require ((Get-ExactPid $script:Package) -eq $ExpectedPid) `
            "$Label did not begin on its pinned round PID."
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        $remaining = $Seconds - [int]$watch.Elapsed.TotalSeconds
        Start-Sleep -Seconds ([Math]::Min(5, [Math]::Max(1, $remaining)))
        Assert-StableStopped
        Require ((Get-ExactPid $script:Package) -eq $ExpectedPid) "$Label changed PID during warm-up."
        Require (Test-LabFocused) "$Label lost foreground focus during warm-up."
    }
}

function Invoke-BenchmarkCapture {
    param(
        [Parameter(Mandatory)][int] $Seconds,
        [Parameter(Mandatory)][int] $ExpectedPid,
        [Parameter(Mandatory)][string] $Label
    )
    Assert-StableStopped
    Assert-ProducerLineageUnchanged "before $Label VrApi capture"
    Require ((Get-ExactPid $script:Package) -eq $ExpectedPid) `
            "$Label did not begin on the pinned round PID."
    $job = Start-Job -ScriptBlock {
        param($Helper, $Package, $Serial, $Adb, $Duration, $Coverage)
        & $Helper -Action Capture -Package $Package -Serial $Serial -AdbPath $Adb `
                -Seconds $Duration -DynamicRefresh -PollSeconds 1 `
                -MinimumSampleCoveragePercent $Coverage
    } -ArgumentList $script:BenchmarkScript, $script:Package, $script:ResolvedSerial,
            $script:ResolvedAdb, $Seconds, $script:MinimumCoveragePercent
    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            Start-Sleep -Seconds 1
            Assert-StableStopped
            Require ((Get-ExactPid $script:Package) -eq $ExpectedPid) `
                    "$Label changed PID while the VrApi helper was capturing."
            $null = Get-Job -Id $job.Id
        }
        Require ($job.State -ceq 'Completed') "$Label VrApi helper did not complete successfully."
        $values = @(Receive-Job -Job $job -ErrorAction Stop)
        $report = Get-ExactObject $values 'ValidForComparison' "$Label VrApi capture"
        Assert-StableStopped
        Require ((Get-ExactPid $script:Package) -eq $ExpectedPid -and
                [int]$report.AppPid -eq $ExpectedPid) `
                "$Label did not retain the pinned round PID across capture."
        Assert-ProducerLineageUnchanged "after $Label VrApi capture"
        return $report
    } finally {
        if ($job.State -in @('NotStarted', 'Running')) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Assert-CaptureGate {
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)][string] $Label,
        [int] $ExpectedPid = 0
    )
    Require ([string]$Report.Package -ceq $script:Package) "$Label used the wrong package."
    Require ([bool]$Report.ValidForComparison) "$Label failed PID/focus/sample/process gates."
    Require ([string]$Report.RefreshPolicy -ceq 'Dynamic') "$Label did not use Dynamic refresh."
    Require ([double]$Report.ExactPidPollPercent -eq 100.0) "$Label did not retain one exact PID."
    if ($ExpectedPid -gt 0) {
        Require ([int]$Report.AppPid -eq $ExpectedPid) "$Label used a different PID than its round."
    }
    Require ([double]$Report.FocusedPollPercent -ge 95.0) "$Label focus coverage is below 95 percent."
    Require ([double]$Report.SampleCoveragePercent -ge $script:MinimumCoveragePercent) `
            "$Label VrApi sample coverage is below 95 percent."
    Require ([int]$Report.Aggregate.CpuLevelMode -eq $script:ExpectedCpuLevel -and
            [int]$Report.Aggregate.GpuLevelMode -eq $script:ExpectedGpuLevel) `
            "$Label did not use QGO CPU/GPU 4/4."
    Require ([double]$Report.Aggregate.CpuLevel4Percent -ge $script:MinimumLevel4Percent -and
            [double]$Report.Aggregate.GpuLevel4Percent -ge $script:MinimumLevel4Percent) `
            "$Label did not retain QGO CPU/GPU 4 for 95 percent of samples."
    Require ($null -ne $Report.Aggregate.MeanDisplayRefreshHz -and
            $null -ne $Report.Aggregate.DisplayRefreshModeHz -and
            @($Report.Aggregate.DisplayRefreshDistribution).Count -gt 0) `
            "$Label has no actual-refresh distribution."
    foreach ($metric in @('MeanAppFps', 'P10AppFps', 'P95CpuAndGpuMs',
            'MeanStaleAtStableRefresh', 'MeanStalePerSecond', 'RefreshTransitionCount',
            'FirstTempC', 'MeanTempC', 'LastTempC', 'MaxTempC')) {
        Require ($null -ne $Report.Aggregate.$metric) "$Label is missing metric '$metric'."
    }
}

function Round-Value {
    param($Value, [int] $Digits = 2)
    if ($null -eq $Value) { return $null }
    return [Math]::Round([double]$Value, $Digits)
}

function Get-RefreshMap {
    param([Parameter(Mandatory)] $Report)
    $map = @{}
    foreach ($bucket in @($Report.Aggregate.DisplayRefreshDistribution)) {
        $key = ([double]$bucket.Hz).ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
        $map[$key] = [double]$bucket.Percent
    }
    return $map
}

function Compare-RefreshDistribution {
    param([Parameter(Mandatory)] $A, [Parameter(Mandatory)] $B)
    $left = Get-RefreshMap $A
    $right = Get-RefreshMap $B
    $distance = 0.0
    foreach ($key in @($left.Keys + $right.Keys | Sort-Object -Unique)) {
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
        TotalVariationPercent = Round-Value $distance
        MeanDeltaHz = Round-Value $meanDelta
        ModeDeltaHz = Round-Value $modeDelta
        TransitionCountDelta = $transitionDelta
        Matched = $distance -le $script:MaximumRefreshDistributionDistancePercent -and
                $meanDelta -le $script:MaximumRefreshMeanDeltaHz -and
                $modeDelta -le $script:MaximumRefreshModeDeltaHz -and
                $transitionDelta -le $script:MaximumRefreshTransitionDelta
    }
}

function Get-HigherIsBetterChangePercent {
    param($Baseline, $Candidate)
    $a = [double]$Baseline
    $b = [double]$Candidate
    if ($a -eq 0.0) { return $(if ($b -eq 0.0) { 0.0 } else { 100.0 }) }
    return 100.0 * ($b - $a) / $a
}

function Get-LowerIsBetterRegressionPercent {
    param($Baseline, $Candidate)
    $a = [double]$Baseline
    $b = [double]$Candidate
    if ($a -eq 0.0) { return $(if ($b -eq 0.0) { 0.0 } else { 100.0 }) }
    return 100.0 * ($b - $a) / $a
}

function Assert-RetainedReport {
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition,
        [Parameter(Mandatory)][int] $Pair
    )
    Assert-CaptureGate $Report "$Condition$Pair retained sample"
    Require (-not [bool]$Report.RawLogsPersisted) 'Retained sample claims raw logs were persisted.'
    Require ($null -ne $Report.Protocol -and [int]$Report.Protocol.SchemaVersion -eq 2) `
            'Retained sample has the wrong protocol schema.'
    Assert-ProducerLineageObject $Report.Protocol.ProducerLineage `
            $script:ActiveProducerLineage 'retained sample'
    Require ([string]$Report.Protocol.Condition -ceq $Condition -and
            [int]$Report.Protocol.Pair -eq $Pair) 'Retained sample condition/pair mismatch.'
    $expectedCore = if ($Condition -ceq 'A') { $script:Rc3CoreSha256 } else { $script:Rc4CoreSha256 }
    $expectedVeq = if ($Condition -ceq 'A') { $script:Rc3VeqSha256 } else { $script:Rc4VeqSha256 }
    Require ((Normalize-Sha256 ([string]$Report.Protocol.CoreSha256)) -ceq $expectedCore -and
            (Normalize-Sha256 ([string]$Report.Protocol.VeqSha256)) -ceq $expectedVeq) `
            'Retained sample pair hashes mismatch.'
    Require ((Normalize-Sha256 ([string]$Report.Protocol.InstalledApkSha256)) -ceq
            $script:ExpectedApkSha256) 'Retained sample was not captured under integrated RC4 APK.'
    Require ((Normalize-Sha256 ([string]$Report.Protocol.WorldMasterSha256)) -ceq
            $script:WorldMasterSha256 -and [bool]$Report.Protocol.WorldResetBeforeLaunch -and
            [bool]$Report.Protocol.ColdLaunch) 'Retained sample world/start contract mismatch.'
    Require ([int]$Report.Protocol.WarmupSeconds -eq $script:EffectiveWarmupSeconds -and
            [int]$Report.Protocol.PreflightSeconds -eq $script:PreflightSeconds) `
            'Retained sample timing contract mismatch.'
    Require ([int]$Report.Protocol.RoundPid -gt 0 -and
            [int]$Report.AppPid -eq [int]$Report.Protocol.RoundPid) `
            'Retained sample is not bound to one pinned round PID.'
    Require ([string]$Report.Protocol.FreshnessProof.Source -ceq
            'device marker + fresh latest.log byte slice' -and
            [int]$Report.Protocol.FreshnessProof.AdvancementMarkers -ge 2 -and
            [int]$Report.Protocol.FreshnessProof.CoreVersionMarkers -ge 1 -and
            [int]$Report.Protocol.FreshnessProof.VeqVersionMarkers -ge 1 -and
            [int64]$Report.Protocol.FreshnessProof.LogMtime -gt
            [int64]$Report.Protocol.FreshnessProof.MarkerMtime) `
            'Retained sample lacks strict device-side freshness/runtime-version proof.'
    Require ([string]$Report.Protocol.OtherModsFingerprintSha256 -cmatch '^[0-9A-F]{64}$') `
            'Retained sample lacks the other-mod fingerprint.'
    $lease = $Report.Protocol.PerformanceLevelLease
    Require ($null -ne $lease -and [bool]$lease.AppliedAfterWorldReady -and
            [bool]$lease.VerifiedBeforeWarmup -and
            [int]$lease.CpuLevel -eq 4 -and [int]$lease.GpuLevel -eq 4 -and
            -not [bool]$lease.RefreshPropertiesModified -and
            -not [bool]$lease.AdaptivePropertiesModified) `
            'Retained sample lacks verified per-round CPU/GPU 4/4 lease evidence.'
}

function Compare-Pair {
    param([Parameter(Mandatory)] $A, [Parameter(Mandatory)] $B)
    Assert-RetainedReport $A A ([int]$A.Protocol.Pair)
    Assert-RetainedReport $B B ([int]$B.Protocol.Pair)
    Require ([int]$A.Protocol.Pair -eq [int]$B.Protocol.Pair -and
            [int]$A.Protocol.Attempt -eq [int]$B.Protocol.Attempt) `
            'Pair combined different pair/attempt numbers.'
    $refresh = Compare-RefreshDistribution $A $B
    $startTemperatureDelta = [Math]::Abs([double]$A.Protocol.StartTemperatureC -
            [double]$B.Protocol.StartTemperatureC)
    $thermalDeltas = [ordered]@{}
    $thermalRaw = [Collections.Generic.List[double]]::new()
    foreach ($metric in @('FirstTempC', 'MeanTempC', 'LastTempC', 'MaxTempC')) {
        $delta = [Math]::Abs([double]$A.Aggregate.$metric - [double]$B.Aggregate.$metric)
        $thermalRaw.Add($delta)
        $thermalDeltas[$metric] = Round-Value $delta 1
    }
    $maximumThermalDelta = [double](($thermalRaw | Measure-Object -Maximum).Maximum)
    $reasons = [Collections.Generic.List[string]]::new()
    if (-not $refresh.Matched) { $reasons.Add('Actual Dynamic-refresh distributions did not match.') }
    if ($startTemperatureDelta -gt $script:MaximumStartTemperatureDeltaC) {
        $reasons.Add('Sample-start temperatures differed by more than 1 C.')
    }
    if ($maximumThermalDelta -gt $script:MaximumThermalPathDeltaC) {
        $reasons.Add('In-sample thermal paths differed by more than 1 C.')
    }
    if ([string]$A.Protocol.OtherModsFingerprintSha256 -cne
            [string]$B.Protocol.OtherModsFingerprintSha256) {
        $reasons.Add('The non-Core/VEQ mod fingerprint changed inside the pair.')
    }
    $fpsChange = Get-HigherIsBetterChangePercent $A.Aggregate.MeanAppFps $B.Aggregate.MeanAppFps
    $p10Change = Get-HigherIsBetterChangePercent $A.Aggregate.P10AppFps $B.Aggregate.P10AppFps
    $p95Regression = Get-LowerIsBetterRegressionPercent $A.Aggregate.P95CpuAndGpuMs `
            $B.Aggregate.P95CpuAndGpuMs
    $staleRegression = Get-LowerIsBetterRegressionPercent $A.Aggregate.MeanStaleAtStableRefresh `
            $B.Aggregate.MeanStaleAtStableRefresh
    return [pscustomobject]@{
        Pair = [int]$A.Protocol.Pair
        Comparable = $reasons.Count -eq 0
        InvalidReasons = $reasons.ToArray()
        Refresh = $refresh
        StartTemperatureDeltaC = Round-Value $startTemperatureDelta 1
        ThermalPathDeltaC = [pscustomobject]$thermalDeltas
        MaximumThermalPathDeltaC = Round-Value $maximumThermalDelta 1
        MeanFpsChangePercent = Round-Value $fpsChange
        P10ChangePercent = Round-Value $p10Change
        P95CpuAndGpuRegressionPercent = Round-Value $p95Regression
        StableRefreshStaleRegressionPercent = Round-Value $staleRegression
        GuardrailsPass = $fpsChange -ge (-1.0 * $script:MaximumPersistentRegressionPercent) -and
                $p10Change -ge (-1.0 * $script:MaximumPersistentRegressionPercent) -and
                $p95Regression -le $script:MaximumPersistentRegressionPercent -and
                $staleRegression -le $script:MaximumPersistentRegressionPercent
    }
}

function Get-MeanMetric {
    param([Parameter(Mandatory)][object[]] $Reports, [Parameter(Mandatory)][string] $Name)
    $values = @($Reports | ForEach-Object { $_.Aggregate.$Name } |
            Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    Require ($values.Count -eq $Reports.Count) "Metric '$Name' is absent."
    return [double](($values | Measure-Object -Average).Average)
}

function Get-Decision {
    param([Parameter(Mandatory)][object[]] $AReports, [Parameter(Mandatory)][object[]] $BReports)
    Require ($AReports.Count -eq 3 -and $BReports.Count -eq 3) 'Decision requires three retained A/B pairs.'
    $pairs = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $a = @($AReports | Where-Object { [int]$_.Protocol.Pair -eq $pair })
        $b = @($BReports | Where-Object { [int]$_.Protocol.Pair -eq $pair })
        Require ($a.Count -eq 1 -and $b.Count -eq 1) "Pair $pair is missing or duplicated."
        $comparison = Compare-Pair $a[0] $b[0]
        Require ([bool]$comparison.Comparable) "Pair $pair is not refresh/thermal comparable."
        $pairs += $comparison
    }

    $aFps = Get-MeanMetric $AReports 'MeanAppFps'
    $bFps = Get-MeanMetric $BReports 'MeanAppFps'
    $aP10 = Get-MeanMetric $AReports 'P10AppFps'
    $bP10 = Get-MeanMetric $BReports 'P10AppFps'
    $aP95 = Get-MeanMetric $AReports 'P95CpuAndGpuMs'
    $bP95 = Get-MeanMetric $BReports 'P95CpuAndGpuMs'
    $aStale = Get-MeanMetric $AReports 'MeanStaleAtStableRefresh'
    $bStale = Get-MeanMetric $BReports 'MeanStaleAtStableRefresh'
    $fpsChange = Get-HigherIsBetterChangePercent $aFps $bFps
    $p10Change = Get-HigherIsBetterChangePercent $aP10 $bP10
    $p95Regression = Get-LowerIsBetterRegressionPercent $aP95 $bP95
    $staleRegression = Get-LowerIsBetterRegressionPercent $aStale $bStale
    $aggregatePass = $fpsChange -ge (-1.0 * $script:MaximumPersistentRegressionPercent) -and
            $p10Change -ge (-1.0 * $script:MaximumPersistentRegressionPercent) -and
            $p95Regression -le $script:MaximumPersistentRegressionPercent -and
            $staleRegression -le $script:MaximumPersistentRegressionPercent
    $pairPassCount = @($pairs | Where-Object { $_.GuardrailsPass }).Count
    $persistentMetricRegression =
            @($pairs | Where-Object { $_.MeanFpsChangePercent -lt -2.0 }).Count -ge 2 -or
            @($pairs | Where-Object { $_.P10ChangePercent -lt -2.0 }).Count -ge 2 -or
            @($pairs | Where-Object { $_.P95CpuAndGpuRegressionPercent -gt 2.0 }).Count -ge 2 -or
            @($pairs | Where-Object { $_.StableRefreshStaleRegressionPercent -gt 2.0 }).Count -ge 2
    $passed = $aggregatePass -and $pairPassCount -ge 2 -and -not $persistentMetricRegression
    return [pscustomobject]@{
        SchemaVersion = 1
        Result = if ($passed) { 'PASS_RC4_NO_PERSISTENT_REGRESSION' } else { 'FAIL_RC4_PERFORMANCE_GATE' }
        PerformanceGatePassed = $passed
        ConditionA = 'RC3 Core+VEQ under integrated RC4 Lab APK'
        ConditionB = 'integrated RC4 Core+VEQ under the same RC4 Lab APK'
        InstalledApkSha256 = $script:ExpectedApkSha256
        ProducerLineageSha256 = $script:ActiveProducerLineage.DigestSha256
        Order = $script:Order
        Pairs = $pairs
        Aggregate = [pscustomobject]@{
            Rc3MeanFps = Round-Value $aFps
            Rc4MeanFps = Round-Value $bFps
            MeanFpsChangePercent = Round-Value $fpsChange
            Rc3P10Fps = Round-Value $aP10
            Rc4P10Fps = Round-Value $bP10
            P10ChangePercent = Round-Value $p10Change
            Rc3P95CpuAndGpuMs = Round-Value $aP95
            Rc4P95CpuAndGpuMs = Round-Value $bP95
            P95CpuAndGpuRegressionPercent = Round-Value $p95Regression
            Rc3StableRefreshStalePerSecond = Round-Value $aStale
            Rc4StableRefreshStalePerSecond = Round-Value $bStale
            StableRefreshStaleRegressionPercent = Round-Value $staleRegression
            AggregateGuardrailsPass = $aggregatePass
            PairGuardrailPassCount = $pairPassCount
            PersistentMetricRegression = $persistentMetricRegression
            MaximumRegressionPercent = $script:MaximumPersistentRegressionPercent
        }
        StableTouched = $false
        RawLogsPersisted = $false
    }
}

function Save-JsonAtomic {
    param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)][string] $Path)
    $full = Assert-NoReparseContainment $Path $script:WorkspaceRoot 'aggregate JSON output'
    Require (-not (Test-Path -LiteralPath $full)) "Refusing to overwrite aggregate evidence: $full"
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    $null = Assert-NoReparseContainment ([IO.Path]::GetDirectoryName($full)) `
            $script:WorkspaceRoot 'aggregate JSON parent'
    $temporary = "$full.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 16) + "`n"),
                [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $full)
    } finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
    }
}

function Resolve-OutputDirectory {
    param([string] $Requested, [switch] $GenerateDefault)
    $artifactRoot = [IO.Path]::GetFullPath($script:ArtifactsRoot)
    $path = if ([string]::IsNullOrWhiteSpace($Requested)) {
        Require $GenerateDefault 'Aggregate requires -OutputDirectory.'
        Join-Path $artifactRoot ('v71-rc3-rc4-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    } else { [IO.Path]::GetFullPath($Requested) }
    $full = [IO.Path]::GetFullPath($path)
    Require ($full.StartsWith($artifactRoot.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase)) `
            'Output must stay below workspace artifacts\benchmarks.'
    Require (-not $full.StartsWith([IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase)) 'Output must not be inside the source worktree.'
    return Assert-NoReparseContainment $full $script:WorkspaceRoot 'A/B output directory'
}

function New-RunManifest {
    param([Parameter(Mandatory)] $InstalledApk)
    Require ($null -ne $script:PerformanceLeaseSnapshot) `
            'Run manifest requires an exact pre-mutation performance-level snapshot.'
    $originalLevels = Get-PerformanceLevelEvidence $script:PerformanceLeaseSnapshot
    return [pscustomobject]@{
        SchemaVersion = 2
        Package = $script:Package
        ForbiddenStablePackage = $script:ForbiddenStablePackage
        Profile = $script:Profile
        World = $script:World
        WorldMasterSha256 = $script:WorldMasterSha256
        InstalledApk = $InstalledApk
        ConditionA = [pscustomobject]@{ Name = 'RC3'; CoreSha256 = $script:Rc3CoreSha256; VeqSha256 = $script:Rc3VeqSha256 }
        ConditionB = [pscustomobject]@{ Name = 'RC4'; CoreSha256 = $script:Rc4CoreSha256; VeqSha256 = $script:Rc4VeqSha256 }
        ProducerLineage = $script:ActiveProducerLineage
        Order = $script:Order
        WarmupSeconds = $script:EffectiveWarmupSeconds
        PreflightSeconds = $script:PreflightSeconds
        SampleSeconds = $script:SampleSeconds
        MaximumPairAttempts = $MaximumPairAttempts
        InterRoundCooldownSeconds = $InterRoundCooldownSeconds
        Gates = [pscustomobject]@{
            MinimumCoveragePercent = $script:MinimumCoveragePercent
            MinimumLevel4Percent = $script:MinimumLevel4Percent
            CpuLevel = $script:ExpectedCpuLevel
            GpuLevel = $script:ExpectedGpuLevel
            MaximumStartTemperatureDeltaC = $script:MaximumStartTemperatureDeltaC
            MaximumThermalPathDeltaC = $script:MaximumThermalPathDeltaC
            MaximumRefreshDistributionDistancePercent = $script:MaximumRefreshDistributionDistancePercent
            MaximumRefreshMeanDeltaHz = $script:MaximumRefreshMeanDeltaHz
            MaximumRefreshModeDeltaHz = $script:MaximumRefreshModeDeltaHz
            MaximumRefreshTransitionDelta = $script:MaximumRefreshTransitionDelta
            MaximumPersistentRegressionPercent = $script:MaximumPersistentRegressionPercent
        }
        PerformanceLevelLease = [pscustomobject]@{
            Scope = 'Lab campaign only'
            TargetCpuLevel = $script:ExpectedCpuLevel
            TargetGpuLevel = $script:ExpectedGpuLevel
            OriginalCpuLevelSet = [bool]$originalLevels.OriginalCpuLevelSet
            OriginalCpuLevel = $originalLevels.OriginalCpuLevel
            OriginalGpuLevelSet = [bool]$originalLevels.OriginalGpuLevelSet
            OriginalGpuLevel = $originalLevels.OriginalGpuLevel
            ApplyAfterWorldReady = $true
            VerifyBeforeWarmup = $true
            RestoreEveryRoundAndOuterFinally = $true
            RefreshPropertiesModified = $false
            AdaptivePropertiesModified = $false
        }
        QgoContract = 'Dynamic refresh; CPU/GPU 4/4; application requests neither refresh nor performance hint'
        FinalState = 'Lab stopped on exact RC4 Core+VEQ pair; original CPU/GPU levels restored'
        StableTouched = $false
        RawLogsPersisted = $false
    }
}

function Assert-RunManifest {
    param([Parameter(Mandatory)] $Manifest)
    Require ([int]$Manifest.SchemaVersion -eq 2 -and
            [string]$Manifest.Package -ceq $script:Package -and
            [string]$Manifest.ForbiddenStablePackage -ceq $script:ForbiddenStablePackage) `
            'Run manifest package contract mismatch.'
    Require ((@($Manifest.Order) -join '-') -ceq ($script:Order -join '-')) `
            'Run manifest order mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.InstalledApk.Sha256)) -ceq
            $script:ExpectedApkSha256) 'Run manifest APK mismatch.'
    Require ((Normalize-Sha256 ([string]$Manifest.ConditionA.CoreSha256)) -ceq $script:Rc3CoreSha256 -and
            (Normalize-Sha256 ([string]$Manifest.ConditionA.VeqSha256)) -ceq $script:Rc3VeqSha256 -and
            (Normalize-Sha256 ([string]$Manifest.ConditionB.CoreSha256)) -ceq $script:Rc4CoreSha256 -and
            (Normalize-Sha256 ([string]$Manifest.ConditionB.VeqSha256)) -ceq $script:Rc4VeqSha256) `
            'Run manifest pair hashes mismatch.'
    Assert-ProducerLineageObject $Manifest.ProducerLineage `
            $script:ActiveProducerLineage 'run manifest'
    Require ([int]$Manifest.WarmupSeconds -eq $script:EffectiveWarmupSeconds -and
            [int]$Manifest.PreflightSeconds -eq $script:PreflightSeconds -and
            [int]$Manifest.SampleSeconds -eq $script:SampleSeconds -and
            [int]$Manifest.MaximumPairAttempts -ge 1 -and
            [int]$Manifest.MaximumPairAttempts -le 3) 'Run manifest timing contract mismatch.'
    Require ([double]$Manifest.Gates.MinimumCoveragePercent -eq $script:MinimumCoveragePercent -and
            [double]$Manifest.Gates.MinimumLevel4Percent -eq $script:MinimumLevel4Percent -and
            [int]$Manifest.Gates.CpuLevel -eq 4 -and [int]$Manifest.Gates.GpuLevel -eq 4) `
            'Run manifest PID/coverage/QGO contract mismatch.'
    $lease = $Manifest.PerformanceLevelLease
    Require ($null -ne $lease -and [string]$lease.Scope -ceq 'Lab campaign only' -and
            [int]$lease.TargetCpuLevel -eq 4 -and [int]$lease.TargetGpuLevel -eq 4 -and
            [bool]$lease.ApplyAfterWorldReady -and [bool]$lease.VerifyBeforeWarmup -and
            [bool]$lease.RestoreEveryRoundAndOuterFinally -and
            -not [bool]$lease.RefreshPropertiesModified -and
            -not [bool]$lease.AdaptivePropertiesModified) `
            'Run manifest performance-level lease contract mismatch.'
}

function Save-ExcludedAttempt {
    param([string] $Directory, [int] $Pair, [int] $Attempt, $A, $B, [string[]] $Reasons)
    $excluded = Join-Path $Directory 'excluded'
    [IO.Directory]::CreateDirectory($excluded) | Out-Null
    $stem = "pair$Pair-attempt$Attempt"
    if ($null -ne $A) { Save-JsonAtomic $A (Join-Path $excluded "$stem-A.json") }
    if ($null -ne $B) { Save-JsonAtomic $B (Join-Path $excluded "$stem-B.json") }
    Save-JsonAtomic ([pscustomobject]@{
        Pair = $Pair; Attempt = $Attempt; Reasons = $Reasons
        StableTouched = $false; RawLogsPersisted = $false
    }) (Join-Path $excluded "$stem-rejection.json")
}

function Get-ConditionOrderForPair {
    param([Parameter(Mandatory)][ValidateRange(1, 3)][int] $Pair)
    if ($Pair -eq 2) { return @('B', 'A') }
    return @('A', 'B')
}

function Invoke-OneRound {
    param(
        [Parameter(Mandatory)][ValidateSet('A', 'B')][string] $Condition,
        [Parameter(Mandatory)][int] $Pair,
        [Parameter(Mandatory)][int] $Attempt
    )
    $freshness = $null
    $performanceLeaseEvidence = $null
    try {
        Assert-StableStopped
        Stop-Lab
        Assert-StableStopped
        $null = Invoke-PairedRollback
        Assert-StableStopped
        Invoke-WorldReset
        Assert-StableStopped
        if ($Condition -ceq 'A') {
            $null = Invoke-PairedDeployRc3
            Assert-StableStopped
        }
        $freshness = New-WorldReadinessMarker
        Assert-StableStopped
        $null = Start-LabAutoplay
        $ready = Wait-LabWorldReady $freshness $Condition
        $roundPid = [int]$ready.Pid
        $state = Assert-PairedRuntimeState $Condition
        Assert-WorldSessionStillLive $ready $roundPid "$Condition$Pair before warm-up"
        $performanceLeaseEvidence = Enter-PerformanceLevelLease $roundPid "$Condition$Pair"
        Assert-WorldSessionStillLive $ready $roundPid `
                "$Condition$Pair after CPU/GPU 4/4 verification"
        Wait-HealthyWarmup $script:EffectiveWarmupSeconds "$Condition$Pair" $roundPid
        Assert-WorldSessionStillLive $ready $roundPid "$Condition$Pair after warm-up"
        $preflight = Invoke-BenchmarkCapture $script:PreflightSeconds $roundPid `
                "$Condition$Pair thermal preflight"
        Assert-CaptureGate $preflight "$Condition$Pair thermal preflight" $roundPid
        Assert-WorldSessionStillLive $ready $roundPid "$Condition$Pair after thermal preflight"
        $sample = Invoke-BenchmarkCapture $script:SampleSeconds $roundPid "$Condition$Pair sample"
        Assert-CaptureGate $sample "$Condition$Pair sample" $roundPid
        Assert-WorldSessionStillLive $ready $roundPid "$Condition$Pair after sample"
        Require ([Math]::Abs([double]$preflight.Aggregate.LastTempC -
                [double]$sample.Aggregate.FirstTempC) -le 1.0) `
                "$Condition$Pair temperature moved by more than 1 C between preflight and sample."
        $sample | Add-Member -NotePropertyName Protocol -NotePropertyValue ([pscustomobject]@{
            SchemaVersion = 2
            Condition = $Condition
            Pair = $Pair
            Attempt = $Attempt
            CoreSha256 = $state.CoreSha256
            VeqSha256 = $state.VeqSha256
            InstalledApkSha256 = $script:ExpectedApkSha256
            ProducerLineage = $script:ActiveProducerLineage
            OtherModsFingerprintSha256 = $state.OtherModsFingerprintSha256
            MarkerState = $state.MarkerState
            WorldMasterSha256 = $script:WorldMasterSha256
            WorldResetBeforeLaunch = $true
            ColdLaunch = $true
            WarmupSeconds = $script:EffectiveWarmupSeconds
            PreflightSeconds = $script:PreflightSeconds
            StartTemperatureC = [double]$preflight.Aggregate.LastTempC
            RoundPid = $roundPid
            FreshnessProof = [pscustomobject]@{
                Source = 'device marker + fresh latest.log byte slice'
                SliceMode = $ready.SliceMode
                FreshByteStart = $ready.FreshByteStart
                LogInode = $ready.LogInode
                MinimumLogSize = $ready.LogSize
                AdvancementMarkers = $ready.AdvancementMarkers
                CoreVersionMarkers = $ready.CoreVersionMarkers
                VeqVersionMarkers = $ready.VeqVersionMarkers
                MarkerMtime = $ready.MarkerMtime
                LogMtime = $ready.LogMtime
            }
            QgoExpected = 'Dynamic CPU4/GPU4'
            PerformanceLevelLease = $performanceLeaseEvidence
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            DeviceSelection = 'resolved locally; serial not persisted'
        })
        return $sample
    } finally {
        if ($script:CampaignMutationStarted) {
            $cleanupFreshness = if ($null -ne $freshness) {
                $freshness
            } else {
                $script:ActiveReadinessMarker
            }
            Restore-RoundAndLeaseFailClosed "$Condition$Pair attempt $Attempt" $cleanupFreshness
        }
    }
}

function Invoke-Pair {
    param([Parameter(Mandatory)][int] $Pair, [Parameter(Mandatory)][string] $Directory)
    $conditionOrder = @(Get-ConditionOrderForPair $Pair)
    for ($attempt = 1; $attempt -le $MaximumPairAttempts; $attempt++) {
        $a = $null
        $b = $null
        try {
            foreach ($condition in $conditionOrder) {
                $report = Invoke-OneRound $condition $Pair $attempt
                if ($condition -ceq 'A') { $a = $report } else { $b = $report }
                if ($condition -cne $conditionOrder[-1] -and $InterRoundCooldownSeconds -gt 0) {
                    Start-Sleep -Seconds $InterRoundCooldownSeconds
                }
            }
            $comparison = Compare-Pair $a $b
            if ($comparison.Comparable) {
                Save-JsonAtomic $a (Join-Path $Directory "A$Pair.json")
                Save-JsonAtomic $b (Join-Path $Directory "B$Pair.json")
                return $comparison
            }
            Save-ExcludedAttempt $Directory $Pair $attempt $a $b $comparison.InvalidReasons
        } catch {
            $message = [string]$_.Exception.Message
            Save-ExcludedAttempt $Directory $Pair $attempt $a $b @($message)
            if ($message.StartsWith('[FATAL_', [StringComparison]::Ordinal)) {
                throw
            }
        }
        if ($attempt -lt $MaximumPairAttempts -and $InterRoundCooldownSeconds -gt 0) {
            Start-Sleep -Seconds $InterRoundCooldownSeconds
        }
    }
    throw "Pair $Pair did not produce a matched result after $MaximumPairAttempts attempts."
}

function Get-ReportsFromDirectory {
    param([Parameter(Mandatory)][string] $Directory)
    $a = @()
    $b = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $aPath = Join-Path $Directory "A$pair.json"
        $bPath = Join-Path $Directory "B$pair.json"
        $aPath = Assert-NoReparseContainment $aPath $script:WorkspaceRoot "A$pair report"
        $bPath = Assert-NoReparseContainment $bPath $script:WorkspaceRoot "B$pair report"
        Require (Test-Path -LiteralPath $aPath -PathType Leaf) "Missing A$pair.json."
        Require (Test-Path -LiteralPath $bPath -PathType Leaf) "Missing B$pair.json."
        $aReport = Get-Content -Raw -LiteralPath $aPath | ConvertFrom-Json
        $bReport = Get-Content -Raw -LiteralPath $bPath | ConvertFrom-Json
        Assert-RetainedReport $aReport A $pair
        Assert-RetainedReport $bReport B $pair
        $a += $aReport
        $b += $bReport
    }
    return [pscustomobject]@{ A = $a; B = $b }
}

function New-SyntheticReport {
    param(
        [ValidateSet('A', 'B')][string] $Condition,
        [int] $Pair,
        [double] $Fps,
        [double] $P10,
        [double] $P95,
        [double] $Stale,
        [double] $Temperature,
        [double] $Refresh = 72.0
    )
    $core = if ($Condition -ceq 'A') { $script:Rc3CoreSha256 } else { $script:Rc4CoreSha256 }
    $veq = if ($Condition -ceq 'A') { $script:Rc3VeqSha256 } else { $script:Rc4VeqSha256 }
    return [pscustomobject]@{
        SchemaVersion = 1
        Package = $script:Package
        AppPid = 12345
        RefreshPolicy = 'Dynamic'
        ExactPidPollPercent = 100.0
        FocusedPollPercent = 100.0
        SampleCoveragePercent = 100.0
        ValidForComparison = $true
        InvalidReasons = @()
        RawLogsPersisted = $false
        Aggregate = [pscustomobject]@{
            MeanAppFps = $Fps
            P10AppFps = $P10
            P95CpuAndGpuMs = $P95
            MeanStaleAtStableRefresh = $Stale
            MeanStalePerSecond = $Stale
            MeanDisplayRefreshHz = $Refresh
            DisplayRefreshModeHz = $Refresh
            DisplayRefreshDistribution = @([pscustomobject]@{ Hz = $Refresh; Count = 60; Percent = 100.0 })
            RefreshTransitionCount = 0
            CpuLevelMode = 4
            GpuLevelMode = 4
            CpuLevel4Percent = 100.0
            GpuLevel4Percent = 100.0
            FirstTempC = $Temperature
            MeanTempC = $Temperature
            LastTempC = $Temperature
            MaxTempC = $Temperature
        }
        Protocol = [pscustomobject]@{
            SchemaVersion = 2
            Condition = $Condition
            Pair = $Pair
            Attempt = 1
            CoreSha256 = $core
            VeqSha256 = $veq
            InstalledApkSha256 = $script:ExpectedApkSha256
            ProducerLineage = $script:ActiveProducerLineage
            OtherModsFingerprintSha256 = ('C' * 64)
            MarkerState = $(if ($Condition -ceq 'A') { 'consumed' } else { 'absent' })
            WorldMasterSha256 = $script:WorldMasterSha256
            WorldResetBeforeLaunch = $true
            ColdLaunch = $true
            WarmupSeconds = $script:EffectiveWarmupSeconds
            PreflightSeconds = $script:PreflightSeconds
            StartTemperatureC = $Temperature
            RoundPid = 12345
            FreshnessProof = [pscustomobject]@{
                Source = 'device marker + fresh latest.log byte slice'
                SliceMode = 'NEW_FILE'
                FreshByteStart = 1
                AdvancementMarkers = 2
                CoreVersionMarkers = 1
                VeqVersionMarkers = 1
                MarkerMtime = 100
                LogMtime = 101
            }
            PerformanceLevelLease = [pscustomobject]@{
                AppliedAfterWorldReady = $true
                VerifiedBeforeWarmup = $true
                CpuLevel = 4
                GpuLevel = 4
                RefreshPropertiesModified = $false
                AdaptivePropertiesModified = $false
            }
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
}

function Invoke-SelfTest {
    $before = $script:DeviceInvocationCount
    Resolve-HostContract -AllowPendingApk
    Require (($script:Order -join '-') -ceq 'A1-B1-B2-A2-A3-B3') `
            'Counterbalanced order drifted.'
    $implementedOrder = @(
        for ($pair = 1; $pair -le 3; $pair++) {
            foreach ($condition in @(Get-ConditionOrderForPair $pair)) { "$condition$pair" }
        }
    )
    Require (($implementedOrder -join '-') -ceq ($script:Order -join '-')) `
            'Implemented round order drifted from the locked counterbalance.'
    $authorizationRejected = $false
    try { Assert-RunAuthorization $false $false $false } catch { $authorizationRejected = $true }
    Require $authorizationRejected 'Run did not require explicit device authorization.'

    foreach ($value in @('', '0', '00', '4', '99')) {
        $token = ConvertTo-PerformanceLevelToken $value 'synthetic level'
        Require ((ConvertFrom-PerformanceLevelToken $token 'synthetic level') -ceq $value) `
                'Performance-level token encoding did not preserve an exact value.'
    }
    $badTokenRejected = $false
    try { $null = ConvertFrom-PerformanceLevelToken 'N-1' 'synthetic bad token' } `
    catch { $badTokenRejected = $true }
    Require $badTokenRejected 'A nonnumeric performance-level token was accepted.'
    $parsedLevels = Read-ExactPerformanceLevelProbe -ExitCode 0 `
            -Lines @("PERF_LEVELS`tN2`tU") -Label 'synthetic property probe'
    Require ([string]$parsedLevels.Cpu -ceq '2' -and [string]$parsedLevels.Gpu -ceq '') `
            'The performance-level parser lost numeric/unset state.'
    foreach ($badProbe in @(
        @{ ExitCode = 0; Lines = @("PERF_LEVELS`tN4`tN4", 'warning') },
        @{ ExitCode = 0; Lines = @("PERF_LEVELS`tN4`tN-1") },
        @{ ExitCode = 1; Lines = @("PERF_LEVELS`tN4`tN4") }
    )) {
        $rejected = $false
        try {
            $null = Read-ExactPerformanceLevelProbe -ExitCode $badProbe.ExitCode `
                    -Lines @($badProbe.Lines) -Label 'synthetic bad property probe'
        } catch { $rejected = $true }
        Require $rejected 'A failed or contaminated performance-level probe was accepted.'
    }
    $probeCommand = New-PerformanceLevelProbeCommand
    $mutationCommand = New-PerformanceLevelMutationCommand '4' ''
    Require (-not $probeCommand.Contains('setprop') -and
            $probeCommand.Contains("getprop '$script:CpuLevelProperty'") -and
            $probeCommand.Contains("getprop '$script:GpuLevelProperty'")) `
            'The pure performance-level probe command is mutating or incomplete.'
    Require ([regex]::Matches($mutationCommand, '(?m)^setprop ').Count -eq 2 -and
            $mutationCommand.Contains("setprop '$script:CpuLevelProperty' '4'") -and
            $mutationCommand.Contains("setprop '$script:GpuLevelProperty' ''") -and
            -not $mutationCommand.Contains('refresh') -and
            -not $mutationCommand.Contains('adaptive')) `
            'The performance-level mutation command escaped its two-property boundary.'

    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,
            [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0) 'PowerShell parser rejected the orchestrator.'
    Require (@(Get-ReservedPidAssignments $ast).Count -eq 0) `
            'The orchestrator assigns PowerShell reserved automatic variable $PID.'
    $syntheticPidTokens = $null
    $syntheticPidErrors = $null
    $syntheticPidAst = [Management.Automation.Language.Parser]::ParseInput(
            '$PiD = 123', [ref]$syntheticPidTokens, [ref]$syntheticPidErrors)
    Require ($syntheticPidErrors.Count -eq 0 -and
            @(Get-ReservedPidAssignments $syntheticPidAst).Count -eq 1) `
            'The reserved-PID assignment guard is not case-insensitive.'
    $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Require ($parameterNames -cnotcontains 'Package' -and $parameterNames -cnotcontains 'Profile') `
            'The orchestrator exposes a package/profile override.'
    Require ($source.Contains("`$script:Package = '$script:Package'") -and
            $source.Contains("`$script:ForbiddenStablePackage = '$script:ForbiddenStablePackage'")) `
            'Lab/Stable constants drifted.'
    Require (-not $source.Contains(('pm' + ' clear')) -and
            -not $source.Contains(('unin' + 'stall'))) 'Destructive package commands are present.'
    Require ($source.Contains('finally {') -and
            $source.Contains("Restore-RoundAndLeaseFailClosed '$('outer Run cleanup')'") -and
            $source.Contains('$null = Invoke-PairedRollback')) `
            'RC4 rollback is not structurally present in fail-closed cleanup.'
    $roundStart = $source.IndexOf('function Invoke-OneRound {', [StringComparison]::Ordinal)
    $roundEnd = $source.IndexOf('function Invoke-Pair {', $roundStart,
            [StringComparison]::Ordinal)
    Require ($roundStart -ge 0 -and $roundEnd -gt $roundStart) `
            'Could not isolate the per-round implementation.'
    $roundSource = $source.Substring($roundStart, $roundEnd - $roundStart)
    $readyIndex = $roundSource.IndexOf('Wait-LabWorldReady', [StringComparison]::Ordinal)
    $leaseIndex = $roundSource.IndexOf('Enter-PerformanceLevelLease', [StringComparison]::Ordinal)
    $warmupIndex = $roundSource.IndexOf('Wait-HealthyWarmup', [StringComparison]::Ordinal)
    Require ($readyIndex -ge 0 -and $leaseIndex -gt $readyIndex -and
            $warmupIndex -gt $leaseIndex) `
            'CPU/GPU 4/4 is not applied after world readiness and before warm-up.'
    Require ($source.Contains('Restore-PerformanceLevelLeaseFailClosed') -and
            $source.Contains('$script:PerformanceLeaseMutationStarted = $true') -and
            $source.Contains('Restore-RoundAndLeaseFailClosed')) `
            'The exact performance-level restoration is not structurally fail-closed.'
    Require ($source.Contains('$script:CampaignMutationStarted = $false') -and
            $source.Contains('if ($script:CampaignMutationStarted)') -and
            $source.Contains('Lab became active before the first campaign mutation.')) `
            'A read-only preflight failure could trigger device cleanup/mutation.'
    Require ($source.Contains('[FATAL_CLEANUP]') -and
            $source.Contains("StartsWith('[FATAL_', [StringComparison]::Ordinal)")) `
            'Fatal cleanup failures are not guaranteed to abort the campaign.'
    $runSource = $source.Substring($source.IndexOf('function Invoke-Run {',
            [StringComparison]::Ordinal))
    Require ($source.Contains("`$script:GlobalLockPath = Join-Path `$script:ArtifactsRoot") -and
            $source.Contains('[IO.FileShare]::None') -and
            $runSource.IndexOf('$globalLockStream = Enter-GlobalCampaignLock',
                    [StringComparison]::Ordinal) -ge 0 -and
            $runSource.IndexOf('$globalLockStream = Enter-GlobalCampaignLock',
                    [StringComparison]::Ordinal) -lt
            $runSource.IndexOf('Resolve-Device', [StringComparison]::Ordinal)) `
            'The fixed cross-output global campaign lock is absent or late.'
    Require ($source.Contains("@('adb.exe', 'adb.cmd', 'adb.bat', 'adb')") -and
            $source.Contains('$env:PATH = $filteredPath') -and
            $source.Contains("-AdbPath `$script:OfflineAdbSentinel") -and
            $source.Contains("-Serial 'offline-proof'")) `
            'Helper SelfTests are not process-isolated from ADB discovery.'
    Require ($source.Contains('RoundPid = $roundPid') -and
            $source.Contains('[int]$report.AppPid -eq $ExpectedPid') -and
            $source.Contains('Start-Job -ScriptBlock')) `
            'One exact PID is not pinned across warm-up/preflight/sample capture.'
    Require ($source.Contains('New-WorldReadinessMarker') -and
            $source.Contains('tail -c +"$start" "$log"') -and
            $source.Contains('CoreVersionMarkers') -and
            -not $source.Contains(('ToUnix' + 'TimeSeconds'))) `
            'World freshness is not device-marker/new-byte-slice based.'
    Require ($script:ActiveProducerLineage.SchemaVersion -eq 1 -and
            [string]$script:ActiveProducerLineage.HashScheme -ceq
                'sha256-utf8-normalized-lf' -and
            @($script:ActiveProducerLineage.Files).Count -eq 8 -and
            [string]$script:ActiveProducerLineage.Files[0].Name -ceq 'orchestrator') `
            'The complete A/B producer lineage was not captured.'
    $tamperedLineage = $script:ActiveProducerLineage | ConvertTo-Json -Depth 8 |
            ConvertFrom-Json
    $tamperedLineage.Files[1].Sha256 = 'F' * 64
    $lineageTamperRejected = $false
    try {
        Assert-ProducerLineageObject $tamperedLineage `
                $script:ActiveProducerLineage 'synthetic tamper'
    } catch { $lineageTamperRejected = $true }
    Require $lineageTamperRejected 'A changed producer dependency was accepted.'

    $producerLocks = @(Enter-ProducerReadLocks)
    try {
        $writeRejected = $false
        try {
            $writeProbe = [IO.File]::Open($script:BenchmarkScript,
                    [IO.FileMode]::Open, [IO.FileAccess]::Write,
                    [IO.FileShare]::ReadWrite)
            $writeProbe.Dispose()
        } catch [IO.IOException] { $writeRejected = $true }
        Require $writeRejected 'Producer read locks allowed a helper to be opened for writing.'
    } finally {
        foreach ($stream in $producerLocks) { $stream.Dispose() }
    }

    $singlePid = Read-ExactPidProbe -ExitCode 0 -Lines @('1234') `
            -Package 'synthetic.present'
    Require ($singlePid -eq 1234) 'One exact PID was rejected or unwrapped.'
    $missingPid = Read-ExactPidProbe -ExitCode 1 -Lines @() -AllowMissing `
            -Package 'synthetic.missing'
    Require ($null -eq $missingPid) 'Exact pidof absence was not accepted.'
    foreach ($badProbe in @(
        @{ ExitCode = 0; Lines = @('1234 5678'); Label = 'multiple PIDs' },
        @{ ExitCode = 0; Lines = @('1234 warning'); Label = 'contaminated output' },
        @{ ExitCode = 0; Lines = @(); Label = 'blank success' },
        @{ ExitCode = 1; Lines = @('permission denied'); Label = 'error text on absence' },
        @{ ExitCode = 127; Lines = @(); Label = 'transport/shell failure' },
        @{ ExitCode = 0; Lines = @('2147483648'); Label = 'Int32 overflow' },
        @{ ExitCode = 0; Lines = @('0'); Label = 'zero PID' }
    )) {
        $rejected = $false
        try {
            $null = Read-ExactPidProbe -ExitCode $badProbe.ExitCode `
                    -Lines @($badProbe.Lines) -AllowMissing -Package 'synthetic.bad'
        } catch { $rejected = $true }
        Require $rejected "PID parser accepted $($badProbe.Label)."
    }

    $pmPath = Get-ExactPmBaseApkPath @('package:/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk')
    Require ($pmPath -ceq '/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk') `
            'One strict monolithic pm path was rejected.'
    $multiPmRejected = $false
    try {
        $null = Get-ExactPmBaseApkPath @(
            'package:/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk',
            'package:/data/app/~~abc/com.qcxr.qcxr.canary262-def/split_config.arm64_v8a.apk')
    } catch { $multiPmRejected = $true }
    Require $multiPmRejected 'Multiple pm path rows were accepted.'
    $contaminatedPmRejected = $false
    try {
        $null = Get-ExactPmBaseApkPath @(
            'warning', 'package:/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk')
    } catch { $contaminatedPmRejected = $true }
    Require $contaminatedPmRejected 'A contaminated pm path response was accepted.'

    $a = @()
    $b = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $a += New-SyntheticReport A $pair 70.0 67.0 15.0 5.0 (42.0 + $pair / 10.0)
        $b += New-SyntheticReport B $pair 69.8 66.8 15.1 5.05 (42.2 + $pair / 10.0)
    }
    $decision = Get-Decision $a $b
    Require ($decision.PerformanceGatePassed -and
            $decision.Result -ceq 'PASS_RC4_NO_PERSISTENT_REGRESSION') `
            'A valid no-regression campaign was rejected.'

    $badB = @()
    for ($pair = 1; $pair -le 3; $pair++) {
        $badP95 = if ($pair -le 2) { 15.6 } else { 15.1 }
        $badB += New-SyntheticReport B $pair 69.8 66.8 $badP95 5.05 `
                (42.2 + $pair / 10.0)
    }
    Require (-not (Get-Decision $a $badB).PerformanceGatePassed) `
            'A persistent P95 regression was accepted.'

    $refreshMismatch = New-SyntheticReport B 1 69.8 66.8 15.1 5.05 42.3 90.0
    Require (-not (Compare-Pair $a[0] $refreshMismatch).Comparable) `
            'A refresh-mismatched pair was accepted.'
    $thermalMismatch = New-SyntheticReport B 1 69.8 66.8 15.1 5.05 44.0 72.0
    Require (-not (Compare-Pair $a[0] $thermalMismatch).Comparable) `
            'A thermal-mismatched pair was accepted.'
    $badFocus = New-SyntheticReport A 1 70.0 67.0 15.0 5.0 42.1
    $badFocus.FocusedPollPercent = 94.9
    $focusRejected = $false
    try { Assert-CaptureGate $badFocus 'synthetic focus' } catch { $focusRejected = $true }
    Require $focusRejected 'Focus coverage below 95 percent was accepted.'
    $badQgo = New-SyntheticReport A 1 70.0 67.0 15.0 5.0 42.1
    $badQgo.Aggregate.GpuLevelMode = 3
    $qgoRejected = $false
    try { Assert-CaptureGate $badQgo 'synthetic QGO' } catch { $qgoRejected = $true }
    Require $qgoRejected 'A non-4/4 QGO sample was accepted.'
    $badPid = New-SyntheticReport A 1 70.0 67.0 15.0 5.0 42.1
    $badPid.Protocol.RoundPid = 54321
    $pidRejected = $false
    try { Assert-RetainedReport $badPid A 1 } catch { $pidRejected = $true }
    Require $pidRejected 'A report crossing round PIDs was accepted.'
    $staleFreshness = New-SyntheticReport A 1 70.0 67.0 15.0 5.0 42.1
    $staleFreshness.Protocol.FreshnessProof.CoreVersionMarkers = 0
    $freshnessRejected = $false
    try { Assert-RetainedReport $staleFreshness A 1 } catch { $freshnessRejected = $true }
    Require $freshnessRejected 'A report without fresh runtime-version evidence was accepted.'
    Require ($script:DeviceInvocationCount -eq $before) 'SelfTest invoked ADB.'

    return [pscustomobject]@{
        Result = 'PASS'
        Assertions = 63
        Package = $script:Package
        ForbiddenPackage = $script:ForbiddenStablePackage
        InstalledApkSha256 = $script:ExpectedApkSha256
        Rc3CoreSha256 = $script:Rc3CoreSha256
        Rc3VeqSha256 = $script:Rc3VeqSha256
        Rc4CoreSha256 = $script:Rc4CoreSha256
        Rc4VeqSha256 = $script:Rc4VeqSha256
        Order = $script:Order -join '-'
        AlwaysRollbackRc4 = $true
        GlobalCampaignLock = 'artifacts/benchmarks/.quest-v71-rc3-rc4-ab.global.lock'
        PinnedPidPerRound = $true
        DeviceMarkerFreshSlices = $true
        RuntimeFabricVersionMarkers = $true
        StrictSingleLinePmPath = $true
        StrictPidProbe = $true
        ReservedPidAssignmentGuard = $true
        BenchmarkReservedLastExitCodeGuard = $true
        HelperSelfTestsAdbIsolated = $true
        ProducerLineageSha256 = $script:ActiveProducerLineage.DigestSha256
        ProducerFilesPinned = @($script:ActiveProducerLineage.Files).Count
        ProducerFilesReadLockedDuringRun = $true
        PerformanceLevelLease = 'snapshot exact; Lab rounds CPU4/GPU4; restore every round and outer finally'
        PerformanceLevelLeasePureCommandTests = $true
        RefreshOrAdaptivePropertiesModified = $false
        ExplicitDeviceSwitches = @('AllowDeviceRead', 'AllowDeviceWrite', 'AllowLaunch')
        DeviceTouched = $false
        DeviceInvocations = 0
        RawLogsPersisted = $false
    }
}

function Invoke-Plan {
    Resolve-HostContract -AllowPendingApk
    return [pscustomobject]@{
        Result = 'PLAN'
        Package = $script:Package
        ForbiddenPackage = $script:ForbiddenStablePackage
        InstalledApkSha256 = $script:ExpectedApkSha256
        ConditionA = "RC3 $script:Rc3CoreSha256 / $script:Rc3VeqSha256"
        ConditionB = "RC4 $script:Rc4CoreSha256 / $script:Rc4VeqSha256"
        Order = $script:Order -join '-'
        WarmupSeconds = $script:EffectiveWarmupSeconds
        PreflightSeconds = $script:PreflightSeconds
        SampleSeconds = $script:SampleSeconds
        RefreshGate = 'TV<=5%; mean/mode delta<=0.5Hz; transition delta<=1'
        ThermalGate = 'start and First/Mean/Last/Max deltas<=1C'
        RuntimeGate = 'exact PID; focus/coverage>=95%; QGO CPU/GPU 4/4>=95%'
        PerformanceLevelLease = 'Lab only; snapshot exact values; set/verify CPU4/GPU4 after world-ready; restore every round and outer finally'
        RefreshOrAdaptivePropertiesModified = $false
        FreshnessGate = 'device marker + only new latest.log bytes + exact Fabric version rows'
        ConcurrencyGate = 'one fixed cross-output FileShare.None campaign lock'
        FinalGate = 'aggregate <=2% regression, >=2/3 pair guardrails, no persistent metric regression'
        FinalState = 'Lab stopped on exact RC4 pair'
        DeviceTouched = $false
        RawLogsPersisted = $false
    }
}

function Invoke-Aggregate {
    Resolve-HostContract
    $directory = Resolve-OutputDirectory $OutputDirectory
    $manifestPath = Assert-NoReparseContainment (Join-Path $directory 'run-manifest.json') `
            $script:WorkspaceRoot 'run manifest'
    Require (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'Run manifest is missing.'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    Require ([int]$manifest.WarmupSeconds -ge 300 -and [int]$manifest.WarmupSeconds -le 900) `
            'Run manifest warm-up is outside the locked range.'
    $script:EffectiveWarmupSeconds = [int]$manifest.WarmupSeconds
    Assert-RunManifest $manifest
    $reports = Get-ReportsFromDirectory $directory
    return Get-Decision $reports.A $reports.B
}

function Invoke-Run {
    Assert-RunAuthorization ([bool]$AllowDeviceRead) ([bool]$AllowDeviceWrite) ([bool]$AllowLaunch)
    Resolve-HostContract
    $globalLockStream = Enter-GlobalCampaignLock
    $producerLockStreams = $null
    try {
        # Hold shared-read handles for the complete producer closure. Other
        # readers (including child PowerShell invocations) remain allowed,
        # while replacement or mutation is denied for the entire campaign.
        $producerLockStreams = @(Enter-ProducerReadLocks)
        Assert-ProducerLineageUnchanged 'A/B campaign start'
        $directory = Resolve-OutputDirectory $OutputDirectory -GenerateDefault
        Require (-not (Test-Path -LiteralPath $directory)) 'Run requires a new output directory.'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $null = Assert-NoReparseContainment $directory $script:WorkspaceRoot 'created A/B output directory'
        $lockPath = Join-Path $directory '.quest-v71-rc3-rc4-ab.lock'
        $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Resolve-Device
            Assert-InitialDeviceState
            $installedApk = Invoke-VerifyInstalledRc4Apk
            $null = Initialize-PerformanceLevelLease
            $manifest = New-RunManifest $installedApk
            Assert-RunManifest $manifest
            Save-JsonAtomic $manifest (Join-Path $directory 'run-manifest.json')

            Assert-StableStopped
            Require ($null -eq (Get-ExactPid $script:Package -AllowMissing)) `
                    'Lab became active before the first campaign mutation.'
            $script:CampaignMutationStarted = $true
            $null = Invoke-PairedRollback
            $baselineState = Assert-PairedRuntimeState B
            $script:ExpectedOtherModsFingerprint = $baselineState.OtherModsFingerprintSha256
            for ($pair = 1; $pair -le 3; $pair++) {
                $null = Invoke-Pair $pair $directory
            }
            $reports = Get-ReportsFromDirectory $directory
            $decision = Get-Decision $reports.A $reports.B
            Save-JsonAtomic $decision (Join-Path $directory 'comparison.json')
            Assert-ProducerLineageUnchanged 'A/B campaign result'
            return [pscustomobject]@{
                Result = 'COMPLETE'
                OutputDirectory = $directory
                Decision = $decision.Result
                PerformanceGatePassed = $decision.PerformanceGatePassed
                FinalPair = 'RC4'
                LabLeftRunning = $false
                StableTouched = $false
                PerformanceLevelLeaseApplications = $script:PerformanceLeaseApplications
                OriginalPerformanceLevelsRestored = $true
                RawLogsPersisted = $false
            }
        } finally {
            try {
                if ($script:CampaignMutationStarted) {
                    Restore-RoundAndLeaseFailClosed 'outer Run cleanup'
                }
            } finally {
                $lockStream.Dispose()
                if (Test-Path -LiteralPath $lockPath) { [IO.File]::Delete($lockPath) }
            }
        }
    } finally {
        try {
            if ($null -ne $producerLockStreams) {
                Assert-ProducerLineageUnchanged 'A/B campaign finalization'
            }
        } finally {
            foreach ($stream in @($producerLockStreams)) {
                if ($null -ne $stream) { $stream.Dispose() }
            }
            $globalLockStream.Dispose()
        }
    }
}

switch ($Action) {
    'SelfTest' { Invoke-SelfTest }
    'Plan' { Invoke-Plan }
    'Aggregate' { Invoke-Aggregate }
    'Run' { Invoke-Run }
}
