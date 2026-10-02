<#
.SYNOPSIS
Stages one strict Vivecraft core JAR launch without replacing the APK baseline.

.DESCRIPTION
SelfTest is offline and never resolves or invokes ADB. Status is read-only.
Deploy validates a candidate locally, requires its explicit SHA-256, stages it
outside mods, and commits the strict one-shot marker last. Rollback requires
the app/JVM to be stopped and atomically restores the exact integrated RC5 core.

Normal Android shell access is always attempted first. Root is used only when
-AllowRootFallback is explicit and a read-only capability probe selected it
before a mutation. The script never reads accounts and never touches saves,
config, options, worlds, Xaero, QGO, APK installation, or app data clearing.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Deploy', 'Rollback', 'SelfTest')]
    [string] $Action = 'Status',

    [string] $JarPath,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedSha256,

    [ValidateSet('OFF', 'ON')]
    [string] $OpenXrCopyBatchMode = 'OFF',

    [ValidateRange(1, 30)]
    [int] $ExpiryMinutes = 15,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [switch] $AllowDeviceWrite,

    [switch] $AllowRootFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:HarnessId = 'questcraft-vivecraft-core-canary-v5'
$script:Package = 'com.qcxr.qcxr.canary262'
$script:BaselineLockPackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:TargetRelative = 'mods/Vivecraft.jar'
$script:FingerprintExcludedLeaves = @(
    'Vivecraft.jar',
    'Vivecraft-Essentials-Quest.jar'
)
$script:StateRelative = ".questcraft/$script:HarnessId"
$script:FabricId = 'vivecraft'
$script:MinecraftDependency = '26.2.x'
$script:JavaDependency = '>=25'
$script:MarkerSchemaVersion = 2
$script:MaxCandidateBytes = 16MB
$script:MaxArchiveBytes = 64MB
$script:MaxArchiveEntries = 4096
$script:AdbInvocationCount = 0
$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:BaselinePath = $null
$script:BaselineSha256 = $null
$script:BaselineSize = 0L

function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-OpenXrCopyBatchMode {
    param([Parameter(Mandatory)][string] $Value)
    $exact = [string]::Equals($Value, 'OFF', [StringComparison]::Ordinal) -or
            [string]::Equals($Value, 'ON', [StringComparison]::Ordinal)
    Assert-Condition $exact 'OpenXR copy-batch mode must be exactly OFF or ON.'
    return $Value
}

function ConvertTo-ShLiteral {
    param([Parameter(Mandatory)][string] $Value)
    $quote = [string][char]39
    $doubleQuote = [string][char]34
    $escaped = $quote + $doubleQuote + $quote + $doubleQuote + $quote
    return $quote + $Value.Replace($quote, $escaped) + $quote
}

function Assert-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    $normalized = $Value.ToLowerInvariant()
    if ($normalized -notmatch '^[0-9a-f]{64}$') { throw 'Invalid SHA-256.' }
    return $normalized
}

function Assert-RunId {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^[0-9a-f]{32}$') { throw 'Invalid lower-hex runId.' }
    return $Value
}

function New-RunId {
    return [guid]::NewGuid().ToString('N')
}

function Normalize-AndroidPath {
    param([Parameter(Mandatory)][string] $Path)
    if (-not $Path.StartsWith('/', [StringComparison]::Ordinal) -or
            $Path.Contains('\') -or $Path.Contains('//') -or
            $Path -match '[\x00-\x1f\x7f]') {
        throw "Unsafe Android path: $Path"
    }
    $parts = @($Path.TrimEnd('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
    if ($parts.Count -eq 0 -or @($parts | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count) {
        throw "Unsafe Android path: $Path"
    }
    return '/' + ($parts -join '/')
}

function Assert-PathBelow {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root)
    $normalized = Normalize-AndroidPath $Path
    $normalizedRoot = Normalize-AndroidPath $Root
    if (-not $normalized.StartsWith($normalizedRoot + '/', [StringComparison]::Ordinal)) {
        throw "Android path escaped its exact root: $Path"
    }
    return $normalized
}

function Resolve-BaselineLock {
    $lockPath = Join-Path $script:RepoRoot 'V71_LAB_RC5.lock.json'
    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    Assert-Condition ([string]$lock.target.package -ceq $script:Package) `
            'V71_LAB_RC5.lock.json is not the isolated Lab contract.'
    Assert-Condition ([string]$lock.target.forbiddenStablePackage -ceq $script:BaselineLockPackage -and
            [bool]$lock.target.stableTouched -eq $false) `
            'The RC5 Lab lock no longer protects Personal.'
    Assert-Condition ([int64]$lock.target.versionCode -eq 71 -and
            -not [string]::IsNullOrWhiteSpace([string]$lock.target.versionName) -and
            [string]$lock.target.versionName -clike '6.0.1-26.2-vivecraft-personal.12-rc.5*' -and
            [bool]$lock.target.artifactAuditPassed) `
            'The harness requires a built and audited integrated v71 RC5 Lab lock.'
    $relative = [string]$lock.pair.core.embeddedAssetPath
    Assert-Condition ($relative -eq 'Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin') `
            'Unexpected embedded Vivecraft asset path.'
    $script:BaselinePath = Join-Path $script:RepoRoot $relative
    Assert-Condition (Test-Path -LiteralPath $script:BaselinePath -PathType Leaf) `
            'The embedded v71 RC5 Vivecraft core is missing.'
    $script:BaselineSha256 = Assert-Sha256 ([string]$lock.pair.core.sha256)
    Assert-Condition ($script:BaselineSha256 -ceq
            '494bc1cb9ced37c4f2193704cda1ed4b4f3461ddfb5e75a1c3475d0124159f00') `
            'The RC5 Vivecraft baseline hash drifted.'
    $actual = (Get-FileHash -LiteralPath $script:BaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Condition ($actual -eq $script:BaselineSha256) `
            'The embedded Vivecraft core does not match V71_LAB_RC5.lock.json.'
    $script:BaselineSize = [int64](Get-Item -LiteralPath $script:BaselinePath).Length
    Assert-Condition ($script:BaselineSize -eq [int64]$lock.pair.core.sizeBytes -and
            $script:BaselineSize -gt 0 -and $script:BaselineSize -le $script:MaxCandidateBytes) `
            'The embedded Vivecraft core is outside the fixed size limit.'
    $metadata = Get-StrictFabricMetadata -Path $script:BaselinePath
    Assert-Condition ($metadata.Id -eq $script:FabricId) 'The baseline Fabric id is not vivecraft.'
    Assert-Condition ($metadata.Version -ceq [string]$lock.pair.core.fabricVersion -and
            $metadata.Version -ceq '26.2-1.3.15+qc.v71.rc5') `
            'The baseline Fabric version is not exact RC5.'
    Assert-Condition ($metadata.MinecraftDependency -eq $script:MinecraftDependency) `
            'The baseline Minecraft dependency is not the exact 26.2 contract.'
    Assert-Condition ($metadata.JavaDependency -eq $script:JavaDependency) `
            'The baseline Java dependency is not the exact Java 25 contract.'
}

function Get-OneDependency {
    param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)][string] $Name)
    if ($Value -is [string]) { return [string]$Value }
    $values = @($Value)
    if ($values.Count -ne 1 -or $values[0] -isnot [string]) {
        throw "Fabric $Name dependency must contain one exact string."
    }
    return [string]$values[0]
}

function Test-SafeZipName {
    param([Parameter(Mandatory)][string] $Name)
    if ([string]::IsNullOrEmpty($Name) -or $Name.StartsWith('/') -or
            $Name.StartsWith('\') -or $Name.Contains('\') -or $Name.Contains(':') -or
            $Name.IndexOf([char]0) -ge 0) { return $false }
    $content = if ($Name.EndsWith('/')) { $Name.Substring(0, $Name.Length - 1) } else { $Name }
    if ([string]::IsNullOrEmpty($content)) { return $false }
    foreach ($part in $content.Split('/')) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.' -or $part -eq '..') { return $false }
    }
    return $true
}

function Get-StrictFabricMetadata {
    param([Parameter(Mandatory)][string] $Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolved
    Assert-Condition (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
            'Candidate must not be a symlink/reparse point.'
    Assert-Condition ($item.Length -gt 0 -and $item.Length -le $script:MaxCandidateBytes) `
            'Candidate is outside the fixed 16 MiB limit.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($resolved)
    try {
        Assert-Condition ($archive.Entries.Count -gt 0 -and
                $archive.Entries.Count -le $script:MaxArchiveEntries) `
                'Candidate ZIP entry count is outside the fixed limit.'
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [int64]$expanded = 0
        $fabricEntries = New-Object Collections.Generic.List[object]
        foreach ($entry in $archive.Entries) {
            Assert-Condition (Test-SafeZipName ([string]$entry.FullName)) `
                    'Candidate contains a path-traversal or unsafe ZIP entry.'
            Assert-Condition ($names.Add([string]$entry.FullName)) `
                    'Candidate contains duplicate or case-colliding ZIP entries.'
            $attributes = [uint64](([int64]$entry.ExternalAttributes) -band 0xffffffffL)
            $unixMode = ($attributes -shr 16) -band 0xffff
            Assert-Condition (($unixMode -band 0xf000) -ne 0xa000) `
                    'Candidate contains a symbolic-link ZIP entry.'
            $expanded += [int64]$entry.Length
            Assert-Condition ($expanded -le $script:MaxArchiveBytes) `
                    'Candidate ZIP expansion exceeds the fixed 64 MiB limit.'
            if ([string]$entry.FullName -ceq 'fabric.mod.json') { $fabricEntries.Add($entry) }
        }
        Assert-Condition ($fabricEntries.Count -eq 1) `
                'Candidate must contain exactly one root fabric.mod.json.'
        $fabricEntry = $fabricEntries[0]
        Assert-Condition ($fabricEntry.Length -gt 0 -and $fabricEntry.Length -le 131072) `
                'fabric.mod.json is empty or oversized.'
        $reader = [IO.StreamReader]::new($fabricEntry.Open(), [Text.UTF8Encoding]::new($false, $true))
        try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $fabric = $raw | ConvertFrom-Json
        $id = [string]$fabric.id
        $version = [string]$fabric.version
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($id)) 'Fabric id is missing.'
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($version)) 'Fabric version is missing.'
        Assert-Condition ($null -ne $fabric.depends) 'Fabric depends object is missing.'
        return [pscustomobject]@{
            Id = $id
            Version = $version
            MinecraftDependency = Get-OneDependency $fabric.depends.minecraft 'minecraft'
            JavaDependency = Get-OneDependency $fabric.depends.java 'java'
            SizeBytes = [int64]$item.Length
            Sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } finally {
        $archive.Dispose()
    }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdk -PathType Leaf) { return $sdk }
    throw 'ADB was not found.'
}

function Invoke-Adb {
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $script:AdbInvocationCount++
    $lines = @(& $script:ResolvedAdb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "ADB failed with exit code $code; device output was suppressed."
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

function Select-OnlyDevice {
    param(
        [Parameter(Mandatory)][string[]] $Rows,
        [string] $RequestedSerial = $Serial
    )
    $devices = New-Object Collections.Generic.List[object]
    foreach ($row in $Rows) {
        if ($row -match '^\s*(?<serial>\S+)\s+(?<state>device|offline|unauthorized|no permissions)(?:\s|$)') {
            $devices.Add([pscustomobject]@{ Serial = $Matches.serial; State = $Matches.state })
        }
    }
    if ($RequestedSerial -ne 'auto') {
        $requested = @($devices | Where-Object { $_.Serial -ceq $RequestedSerial })
        if ($requested.Count -ne 1) { throw 'The requested ADB serial was not found exactly once.' }
        if ($requested[0].State -ne 'device') { throw 'The requested ADB device is not authorized and online.' }
        return [string]$requested[0].Serial
    }

    if ($devices.Count -ne 1) { throw 'Exactly one attached ADB device is required in auto mode.' }
    if ($devices[0].State -ne 'device') { throw 'The only attached ADB device is not authorized and online.' }
    return [string]$devices[0].Serial
}

function Resolve-Device {
    $script:ResolvedAdb = Resolve-Adb
    # `adb devices` emits a trailing blank line on Windows.  Filter only blank
    # rows before binding to Select-OnlyDevice; the parser still receives every
    # non-empty device/status row verbatim.
    $rows = @((Invoke-Adb -Arguments @('devices')).Lines |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $script:ResolvedSerial = Select-OnlyDevice $rows -RequestedSerial $Serial
}

function Invoke-DeviceShell {
    param([Parameter(Mandatory)][string] $Command, [switch] $AllowFailure)
    $normalized = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
    return Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'shell', $normalized) `
            -AllowFailure:$AllowFailure
}

function Resolve-RemoteCanonicalPath {
    param([Parameter(Mandatory)][string] $Path)
    $lexical = Normalize-AndroidPath $Path
    $result = Invoke-DeviceShell -Command "realpath $(ConvertTo-ShLiteral $lexical)" -AllowFailure
    if ($result.ExitCode -ne 0 -and $AllowRootFallback) {
        $result = Invoke-DeviceShell -Command ('su -c ' +
                (ConvertTo-ShLiteral "realpath $(ConvertTo-ShLiteral $lexical)")) -AllowFailure
    }
    if ($result.ExitCode -ne 0) { throw "Could not resolve exact device path: $lexical" }
    $lines = @($result.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -ne 1) { throw "Canonical device path was ambiguous: $lexical" }
    return Normalize-AndroidPath $lines[0]
}

function Invoke-WriteShell {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [switch] $AllowFailure
    )
    $actual = if ($Mode -eq 'Root') { 'su -c ' + (ConvertTo-ShLiteral $Command) } else { $Command }
    return Invoke-DeviceShell -Command $actual -AllowFailure:$AllowFailure
}

function Get-DevicePaths {
    $filesLexical = "/sdcard/Android/data/$script:Package/files"
    $gameLexical = "$filesLexical/instances/$script:Profile"
    $modsLexical = "$gameLexical/mods"
    $files = Resolve-RemoteCanonicalPath $filesLexical
    $game = Resolve-RemoteCanonicalPath $gameLexical
    $mods = Resolve-RemoteCanonicalPath $modsLexical
    Assert-Condition ($game -ceq "$files/instances/$script:Profile") `
            'The canonical profile is not the exact 26.2 directory.'
    Assert-Condition ($mods -ceq "$game/mods") 'The canonical mods directory escaped the profile.'
    $state = "$game/$script:StateRelative"
    $stateCommand = "if [ -e $(ConvertTo-ShLiteral $state) ] || [ -L $(ConvertTo-ShLiteral $state) ]; then realpath $(ConvertTo-ShLiteral $state); fi"
    $stateProbe = Invoke-DeviceShell -Command $stateCommand -AllowFailure
    if ($stateProbe.ExitCode -ne 0 -and $AllowRootFallback) {
        $stateProbe = Invoke-DeviceShell -Command ('su -c ' +
                (ConvertTo-ShLiteral $stateCommand)) -AllowFailure
    }
    if ($stateProbe.ExitCode -ne 0) { throw 'Could not inspect the canary state directory.' }
    $stateRows = @($stateProbe.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($stateRows.Count -gt 1 -or ($stateRows.Count -eq 1 -and
            (Normalize-AndroidPath $stateRows[0]) -cne $state)) {
        throw 'The canary state directory is a symlink or escaped the profile.'
    }
    return [pscustomobject]@{
        Files = Normalize-AndroidPath $files
        Game = Assert-PathBelow $game $files
        Mods = Assert-PathBelow $mods $game
        State = Assert-PathBelow $state $game
        Target = Assert-PathBelow "$game/$script:TargetRelative" $mods
        Marker = Assert-PathBelow "$state/request.json" $state
        RejectedMarker = Assert-PathBelow "$state/request.rejected.json" $state
    }
}

function Get-AppStoppedShell {
    $qPackage = ConvertTo-ShLiteral $script:Package
    return @"
pidof $qPackage >/dev/null 2>&1 && exit 75 || true
for qcvc_cmdline in /proc/[0-9]*/cmdline; do
  [ -r "`$qcvc_cmdline" ] || continue
  # A disappearing procfs task can leave an already-open cmdline stream
  # producing NUL bytes indefinitely on this Quest kernel. Bound the read so
  # the stopped-app guard itself can never become a CPU-consuming process.
  qcvc_name=`$(head -c 512 "`$qcvc_cmdline" 2>/dev/null | tr '\000' '\n' | sed -n '1p' || true)
  case "`$qcvc_name" in $qPackage|${qPackage}:*) exit 75 ;; esac
done
"@
}

function Get-PathGuardShell {
    param([Parameter(Mandatory)] $Paths, [switch] $StateMustExist)
    $stateCheck = if ($StateMustExist) {
        "qcvc_dir $(ConvertTo-ShLiteral $Paths.State) $(ConvertTo-ShLiteral $Paths.State)"
    } else { '' }
    return @"
qcvc_dir() {
  test -d "`$1" && test ! -L "`$1" || exit 66
  qcvc_actual=`$(cd "`$1" 2>/dev/null && pwd -P) || exit 66
  test "`$qcvc_actual" = "`$2" || exit 66
}
qcvc_leaf() { test ! -L "`$1" || exit 67; }
qcvc_dir $(ConvertTo-ShLiteral $Paths.Files) $(ConvertTo-ShLiteral $Paths.Files)
qcvc_dir $(ConvertTo-ShLiteral $Paths.Game) $(ConvertTo-ShLiteral $Paths.Game)
qcvc_dir $(ConvertTo-ShLiteral $Paths.Mods) $(ConvertTo-ShLiteral $Paths.Mods)
$stateCheck
qcvc_leaf $(ConvertTo-ShLiteral $Paths.Target)
qcvc_leaf $(ConvertTo-ShLiteral $Paths.Marker)
qcvc_leaf $(ConvertTo-ShLiteral $Paths.RejectedMarker)
"@
}

function Resolve-WriteMode {
    param([Parameter(Mandatory)] $Paths)
    $qState = ConvertTo-ShLiteral $Paths.State
    $probe = "test -d $(ConvertTo-ShLiteral $Paths.Game) && test -w $(ConvertTo-ShLiteral $Paths.Game) && test -w $(ConvertTo-ShLiteral $Paths.Mods) && { { test ! -e $qState && test ! -L $qState; } || { test -d $qState && test ! -L $qState && test -w $qState; }; }"
    if ((Invoke-DeviceShell -Command $probe -AllowFailure).ExitCode -eq 0) { return 'Normal' }
    if (-not $AllowRootFallback) {
        throw 'Normal shell cannot write the exact profile; root fallback was not explicitly enabled.'
    }
    if ((Invoke-DeviceShell -Command ('su -c ' + (ConvertTo-ShLiteral $probe)) -AllowFailure).ExitCode -ne 0) {
        throw 'The explicit root fallback cannot write the exact profile.'
    }
    return 'Root'
}

function Get-RemotePreflightShell {
    param([Parameter(Mandatory)] $Paths)
    $guard = Get-PathGuardShell $Paths
    $excluded = @($script:FingerprintExcludedLeaves | ForEach-Object {
        Assert-Condition ($_ -match '^[A-Za-z0-9._+-]+\.jar$') `
                'A paired fingerprint exclusion is not a safe JAR leaf.'
        "    [ `"`$qcvc_file`" = $(ConvertTo-ShLiteral ($Paths.Mods + '/' + $_)) ] && continue"
    }) -join "`n"
    return @"
set -eu
$guard
test -f $(ConvertTo-ShLiteral $Paths.Target)
qcvc_size=`$(stat -c %s $(ConvertTo-ShLiteral $Paths.Target))
qcvc_sha=`$(sha256sum $(ConvertTo-ShLiteral $Paths.Target) | awk '{print tolower(`$1)}')
printf 'TARGET\t%s\t%s\n' "`$qcvc_size" "`$qcvc_sha"
(
  for qcvc_file in $(ConvertTo-ShLiteral $Paths.Mods)/*.jar; do
    [ -e "`$qcvc_file" ] || continue
$excluded
    test -f "`$qcvc_file" && test ! -L "`$qcvc_file" || exit 69
    qcvc_name=`${qcvc_file##*/}
    printf '%s' "`$qcvc_name" | LC_ALL=C grep -q '[[:cntrl:]]' && exit 70 || true
    qcvc_hash=`$(sha256sum "`$qcvc_file" | awk '{print tolower(`$1)}')
    printf '%s\t%s\n' "`$qcvc_name" "`$qcvc_hash"
  done
) | LC_ALL=C sort | sha256sum | awk '{print "FINGERPRINT\t" tolower(`$1)}'
"@
}

function Get-RemotePreflight {
    param([Parameter(Mandatory)] $Paths, [ValidateSet('Normal', 'Root')][string] $Mode = 'Normal')
    $result = if ($Mode -eq 'Root') {
        Invoke-WriteShell -Command (Get-RemotePreflightShell $Paths) -Mode Root -AllowFailure
    } else {
        Invoke-DeviceShell -Command (Get-RemotePreflightShell $Paths) -AllowFailure
    }
    if ($result.ExitCode -ne 0) { throw 'Could not verify the exact profile/core/fingerprint.' }
    $target = @($result.Lines | Where-Object { $_ -match '^TARGET\t' })
    $fingerprint = @($result.Lines | Where-Object { $_ -match '^FINGERPRINT\t' })
    Assert-Condition ($target.Count -eq 1 -and $fingerprint.Count -eq 1) `
            'Device preflight output was ambiguous.'
    $targetParts = $target[0].Split("`t")
    $fingerprintParts = $fingerprint[0].Split("`t")
    return [pscustomobject]@{
        TargetSize = [int64]$targetParts[1]
        TargetSha256 = Assert-Sha256 $targetParts[2]
        OtherModsFingerprintSha256 = Assert-Sha256 $fingerprintParts[1]
    }
}

function New-MarkerObject {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)][string] $OtherModsFingerprintSha256,
        [Parameter(Mandatory)][string] $Mode,
        [Parameter(Mandatory)][int64] $ExpiresAtEpochMs
    )
    [ordered]@{
        schemaVersion = $script:MarkerSchemaVersion
        harnessId = $script:HarnessId
        state = 'armed'
        packageName = $script:Package
        profile = $script:Profile
        target = $script:TargetRelative
        runId = Assert-RunId $RunId
        baselineSha256 = $script:BaselineSha256
        baselineSizeBytes = $script:BaselineSize
        candidateSha256 = $Candidate.Sha256
        candidateSizeBytes = $Candidate.SizeBytes
        fabricId = $Candidate.Id
        fabricVersion = $Candidate.Version
        minecraftDependency = $Candidate.MinecraftDependency
        javaDependency = $Candidate.JavaDependency
        otherModsFingerprintSha256 = Assert-Sha256 $OtherModsFingerprintSha256
        openXrCopyBatchMode = Assert-OpenXrCopyBatchMode $Mode
        expiresAtEpochMs = $ExpiresAtEpochMs
        maxLaunches = 1
    }
}

function Assert-StrictMarkerObject {
    param([Parameter(Mandatory)] $Marker)
    $expected = @('schemaVersion','harnessId','state','packageName','profile','target','runId',
        'baselineSha256','baselineSizeBytes','candidateSha256','candidateSizeBytes','fabricId',
        'fabricVersion','minecraftDependency','javaDependency','otherModsFingerprintSha256',
        'openXrCopyBatchMode','expiresAtEpochMs','maxLaunches')
    $actual = @($Marker.PSObject.Properties.Name)
    Assert-Condition ($actual.Count -eq $expected.Count) 'Marker field count is not exact.'
    foreach ($name in $actual) { Assert-Condition ($expected -ccontains $name) "Unknown marker field: $name" }
    foreach ($name in @('harnessId','state','packageName','profile','target','runId',
            'baselineSha256','candidateSha256','fabricId','fabricVersion','minecraftDependency',
            'javaDependency','otherModsFingerprintSha256','openXrCopyBatchMode')) {
        Assert-Condition ($Marker.$name -is [string]) "Marker field '$name' must be a JSON string."
    }
    foreach ($name in @('schemaVersion','baselineSizeBytes','candidateSizeBytes',
            'expiresAtEpochMs','maxLaunches')) {
        $value = $Marker.$name
        $isInteger = $value -is [sbyte] -or $value -is [byte] -or $value -is [int16] -or
                $value -is [uint16] -or $value -is [int32] -or $value -is [uint32] -or
                $value -is [int64] -or $value -is [uint64]
        Assert-Condition $isInteger "Marker field '$name' must be a JSON integer."
    }
    Assert-Condition ([int]$Marker.schemaVersion -eq $script:MarkerSchemaVersion) `
            'Marker schema mismatch.'
    Assert-Condition ([string]$Marker.harnessId -ceq $script:HarnessId) 'Marker harness mismatch.'
    Assert-Condition (@('armed','attempting','consumed','expired') -ccontains
            [string]$Marker.state) 'Marker state is unknown.'
    Assert-Condition ([string]$Marker.packageName -ceq $script:Package) 'Marker package mismatch.'
    Assert-Condition ([string]$Marker.profile -ceq $script:Profile) 'Marker profile mismatch.'
    Assert-Condition ([string]$Marker.target -ceq $script:TargetRelative) 'Marker target mismatch.'
    Assert-RunId ([string]$Marker.runId) | Out-Null
    $baselineHash = Assert-Sha256 ([string]$Marker.baselineSha256)
    Assert-Condition ($baselineHash -eq $script:BaselineSha256) 'Marker baseline hash mismatch.'
    Assert-Condition ([int64]$Marker.baselineSizeBytes -eq $script:BaselineSize) `
            'Marker baseline size mismatch.'
    Assert-Sha256 ([string]$Marker.candidateSha256) | Out-Null
    Assert-Sha256 ([string]$Marker.otherModsFingerprintSha256) | Out-Null
    Assert-Condition ([int64]$Marker.candidateSizeBytes -gt 0 -and
            [int64]$Marker.candidateSizeBytes -le $script:MaxCandidateBytes) `
            'Marker candidate size is outside the fixed limit.'
    Assert-Condition ([string]$Marker.fabricId -ceq $script:FabricId) 'Marker Fabric id mismatch.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$Marker.fabricVersion) -and
            [string]$Marker.fabricVersion -ceq ([string]$Marker.fabricVersion).Trim()) `
            'Marker Fabric version is invalid.'
    Assert-Condition ([string]$Marker.minecraftDependency -ceq $script:MinecraftDependency) `
            'Marker Minecraft dependency mismatch.'
    Assert-Condition ([string]$Marker.javaDependency -ceq $script:JavaDependency) `
            'Marker Java dependency mismatch.'
    Assert-OpenXrCopyBatchMode ([string]$Marker.openXrCopyBatchMode) | Out-Null
    Assert-Condition ([int64]$Marker.expiresAtEpochMs -gt 0) 'Marker expiry is invalid.'
    Assert-Condition ([int]$Marker.maxLaunches -eq 1) 'Marker is not one-shot.'
}

function ConvertFrom-StrictMarkerJson {
    param([Parameter(Mandatory)][string] $Raw)
    # The contract is deliberately flat. Count raw member names before
    # ConvertFrom-Json can collapse a duplicate into its last value.
    $matches = [regex]::Matches($Raw, '"(?<name>(?:\\.|[^"\\])*)"\s*:')
    $names = @($matches | ForEach-Object { $_.Groups['name'].Value })
    $expected = @('schemaVersion','harnessId','state','packageName','profile','target','runId',
        'baselineSha256','baselineSizeBytes','candidateSha256','candidateSizeBytes','fabricId',
        'fabricVersion','minecraftDependency','javaDependency','otherModsFingerprintSha256',
        'openXrCopyBatchMode','expiresAtEpochMs','maxLaunches')
    Assert-Condition ($names.Count -eq $expected.Count) 'Marker JSON member count is not exact.'
    foreach ($name in $expected) {
        Assert-Condition (@($names | Where-Object { $_ -ceq $name }).Count -eq 1) `
                "Marker JSON is missing or duplicates '$name'."
    }
    $marker = $Raw | ConvertFrom-Json
    Assert-StrictMarkerObject $marker
    return $marker
}

function New-DeployCommitShell {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)] $Candidate,
        [Parameter(Mandatory)][string] $MarkerSha256,
        [Parameter(Mandatory)][string] $UploadCandidate,
        [Parameter(Mandatory)][string] $UploadMarker,
        [string] $FaultStage = ''
    )
    $run = Assert-RunId $RunId
    $state = $Paths.State
    $candidateUpload = "$state/candidate-$run.upload"
    $candidateFinal = "$state/candidate-$run.jar"
    $markerUpload = "$state/request-$run.upload"
    $fault = if ([string]::IsNullOrEmpty($FaultStage)) {
        'qcvc_fault() { return 0; }'
    } else {
        'qcvc_fault() { [ "$1" = ' + (ConvertTo-ShLiteral $FaultStage) +
                ' ] && return 1 || return 0; }'
    }
    $guard = Get-PathGuardShell $Paths
    $appStopped = Get-AppStoppedShell
    return @"
set -eu
$appStopped
$guard
$fault
qcvc_committed=0
qcvc_cleanup() {
  qcvc_status=`$?
  rm -f $(ConvertTo-ShLiteral $UploadCandidate) $(ConvertTo-ShLiteral $UploadMarker) $(ConvertTo-ShLiteral $candidateUpload) $(ConvertTo-ShLiteral $markerUpload)
  if [ "`$qcvc_committed" -eq 0 ]; then rm -f $(ConvertTo-ShLiteral $candidateFinal); fi
  exit "`$qcvc_status"
}
trap qcvc_cleanup EXIT HUP INT TERM
test -f $(ConvertTo-ShLiteral $Paths.Target) && test ! -L $(ConvertTo-ShLiteral $Paths.Target)
test "`$(stat -c %s $(ConvertTo-ShLiteral $Paths.Target))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $Paths.Target) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
test ! -e $(ConvertTo-ShLiteral $Paths.Marker) && test ! -L $(ConvertTo-ShLiteral $Paths.Marker)
test ! -e $(ConvertTo-ShLiteral $Paths.RejectedMarker) && test ! -L $(ConvertTo-ShLiteral $Paths.RejectedMarker)
mkdir -p $(ConvertTo-ShLiteral $state)
test -d $(ConvertTo-ShLiteral $state) && test ! -L $(ConvertTo-ShLiteral $state)
test "`$(cd $(ConvertTo-ShLiteral $state) && pwd -P)" = $(ConvertTo-ShLiteral $state)
test -f $(ConvertTo-ShLiteral $UploadCandidate) && test ! -L $(ConvertTo-ShLiteral $UploadCandidate)
test -f $(ConvertTo-ShLiteral $UploadMarker) && test ! -L $(ConvertTo-ShLiteral $UploadMarker)
cp $(ConvertTo-ShLiteral $UploadCandidate) $(ConvertTo-ShLiteral $candidateUpload)
cp $(ConvertTo-ShLiteral $UploadMarker) $(ConvertTo-ShLiteral $markerUpload)
qcvc_fault after-copy
test "`$(stat -c %s $(ConvertTo-ShLiteral $candidateUpload))" = $(ConvertTo-ShLiteral ([string]$Candidate.SizeBytes))
test "`$(sha256sum $(ConvertTo-ShLiteral $candidateUpload) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $Candidate.Sha256)
test "`$(sha256sum $(ConvertTo-ShLiteral $markerUpload) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $MarkerSha256)
test ! -e $(ConvertTo-ShLiteral $candidateFinal) && test ! -L $(ConvertTo-ShLiteral $candidateFinal)
mv $(ConvertTo-ShLiteral $candidateUpload) $(ConvertTo-ShLiteral $candidateFinal)
qcvc_fault after-candidate-rename
test "`$(sha256sum $(ConvertTo-ShLiteral $candidateFinal) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $Candidate.Sha256)
qcvc_fault before-marker-commit
$appStopped
mv $(ConvertTo-ShLiteral $markerUpload) $(ConvertTo-ShLiteral $Paths.Marker)
qcvc_committed=1
qcvc_fault after-marker-commit
test "`$(sha256sum $(ConvertTo-ShLiteral $Paths.Marker) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $MarkerSha256)
trap - EXIT HUP INT TERM
rm -f $(ConvertTo-ShLiteral $UploadCandidate) $(ConvertTo-ShLiteral $UploadMarker)
printf 'COMMITTED\n'
"@
}

function New-RollbackShell {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $UploadBaseline
    )
    $run = Assert-RunId $RunId
    $state = $Paths.State
    $stage = "$($Paths.Mods)/.vivecraft-rollback-$run.tmp"
    $guard = Get-PathGuardShell $Paths
    $appStopped = Get-AppStoppedShell
    return @"
set -eu
$appStopped
$guard
test -f $(ConvertTo-ShLiteral $UploadBaseline) && test ! -L $(ConvertTo-ShLiteral $UploadBaseline)
test "`$(stat -c %s $(ConvertTo-ShLiteral $UploadBaseline))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $UploadBaseline) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
cp $(ConvertTo-ShLiteral $UploadBaseline) $(ConvertTo-ShLiteral $stage)
test -f $(ConvertTo-ShLiteral $stage) && test ! -L $(ConvertTo-ShLiteral $stage)
test "`$(sha256sum $(ConvertTo-ShLiteral $stage) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
$appStopped
mv $(ConvertTo-ShLiteral $stage) $(ConvertTo-ShLiteral $Paths.Target)
test "`$(stat -c %s $(ConvertTo-ShLiteral $Paths.Target))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $Paths.Target) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
if [ -d $(ConvertTo-ShLiteral $state) ] && [ ! -L $(ConvertTo-ShLiteral $state) ]; then
  rm -f $(ConvertTo-ShLiteral $Paths.Marker) $(ConvertTo-ShLiteral $Paths.RejectedMarker) $(ConvertTo-ShLiteral ($state + '/baseline.jar')) $(ConvertTo-ShLiteral ($state + '/prelaunch.lock'))
  for qcvc_candidate in $(ConvertTo-ShLiteral $state)/candidate-*.jar $(ConvertTo-ShLiteral $state)/candidate-*.upload $(ConvertTo-ShLiteral $state)/request-*.tmp $(ConvertTo-ShLiteral $state)/request-*.upload; do
    [ -e "`$qcvc_candidate" ] || [ -L "`$qcvc_candidate" ] || continue
    test ! -L "`$qcvc_candidate" || exit 67
    rm -f "`$qcvc_candidate"
  done
fi
rm -f $(ConvertTo-ShLiteral $UploadBaseline)
printf 'ROLLED_BACK\n'
"@
}

function Push-LocalFile {
    param([Parameter(Mandatory)][string] $LocalPath, [Parameter(Mandatory)][string] $RemotePath)
    $result = Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'push', $LocalPath, $RemotePath) -AllowFailure
    if ($result.ExitCode -ne 0) { throw 'ADB push failed; device output was suppressed.' }
}

function Assert-PackageInstalled {
    $installed = Invoke-DeviceShell -Command "pm path $(ConvertTo-ShLiteral $script:Package)" -AllowFailure
    if ($installed.ExitCode -ne 0 -or
            @($installed.Lines | Where-Object { $_ -match '^package:' }).Count -ne 1) {
        throw 'The exact monolithic QuestCraft Dev package is not installed.'
    }
}

function Invoke-Status {
    Assert-PackageInstalled
    $paths = Get-DevicePaths
    $running = (Invoke-DeviceShell -Command "pidof $(ConvertTo-ShLiteral $script:Package)" -AllowFailure)
    $mode = 'Normal'
    $preflight = $null
    try { $preflight = Get-RemotePreflight $paths } catch {
        if (-not $AllowRootFallback) { throw }
        $mode = 'Root'
        $preflight = Get-RemotePreflight $paths Root
    }
    $qMarker = ConvertTo-ShLiteral $paths.Marker
    $readMarker = 'test -f ' + $qMarker + ' && test "$(stat -c %s ' + $qMarker +
            ')" -le 16384 && cat ' + $qMarker
    $markerResult = if ($mode -eq 'Root') {
        Invoke-WriteShell -Mode Root -Command $readMarker -AllowFailure
    } else {
        Invoke-DeviceShell -Command $readMarker -AllowFailure
    }
    if ($markerResult.ExitCode -ne 0 -and $mode -eq 'Normal' -and $AllowRootFallback) {
        $rootMarkerResult = Invoke-WriteShell -Mode Root -Command $readMarker -AllowFailure
        if ($rootMarkerResult.ExitCode -eq 0) {
            $markerResult = $rootMarkerResult
            $mode = 'Root'
        }
    }
    $markerState = 'absent'
    $runId = $null
    $markerCopyBatchMode = 'OFF'
    if ($markerResult.ExitCode -eq 0) {
        $parsed = ConvertFrom-StrictMarkerJson ($markerResult.Lines -join "`n")
        $markerState = [string]$parsed.state
        $runId = [string]$parsed.runId
        $markerCopyBatchMode = [string]$parsed.openXrCopyBatchMode
    }
    [pscustomobject]@{
        Result = 'STATUS'
        Package = $script:Package
        Profile = $script:Profile
        HarnessId = $script:HarnessId
        Running = $running.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($running.Lines -join ''))
        AccessMode = $mode
        TargetSha256 = $preflight.TargetSha256
        TargetSizeBytes = $preflight.TargetSize
        BaselineExact = $preflight.TargetSha256 -eq $script:BaselineSha256 -and $preflight.TargetSize -eq $script:BaselineSize
        OtherModsFingerprintSha256 = $preflight.OtherModsFingerprintSha256
        MarkerState = $markerState
        RunId = $runId
        OpenXrCopyBatchMode = $markerCopyBatchMode
        ReadOnly = $true
    }
}

function Invoke-Deploy {
    if (-not $AllowDeviceWrite) { throw 'Deploy is disabled until -AllowDeviceWrite is explicit.' }
    if ([string]::IsNullOrWhiteSpace($JarPath)) { throw 'Deploy requires -JarPath.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        throw 'Deploy requires an explicit -ExpectedSha256.'
    }
    $candidatePath = (Resolve-Path -LiteralPath $JarPath).Path
    $candidate = Get-StrictFabricMetadata $candidatePath
    $expected = Assert-Sha256 $ExpectedSha256
    Assert-Condition ($candidate.Sha256 -eq $expected) 'Candidate does not match -ExpectedSha256.'
    Assert-Condition ($candidate.Id -eq $script:FabricId) 'Candidate Fabric id is not vivecraft.'
    Assert-Condition ($candidate.MinecraftDependency -eq $script:MinecraftDependency) `
            'Candidate does not declare the exact Minecraft 26.2 dependency.'
    Assert-Condition ($candidate.JavaDependency -eq $script:JavaDependency) `
            'Candidate does not declare the exact Java 25 dependency.'

    Assert-PackageInstalled
    $paths = Get-DevicePaths
    $mode = Resolve-WriteMode $paths
    $preflight = Get-RemotePreflight $paths $mode
    Assert-Condition ($preflight.TargetSha256 -eq $script:BaselineSha256 -and
            $preflight.TargetSize -eq $script:BaselineSize) `
            'Deploy requires the exact embedded v71 RC5 baseline in mods.'
    $run = New-RunId
    $expires = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ($ExpiryMinutes * 60L * 1000L)
    $marker = New-MarkerObject -RunId $run -Candidate $candidate `
            -OtherModsFingerprintSha256 $preflight.OtherModsFingerprintSha256 `
            -Mode $OpenXrCopyBatchMode `
            -ExpiresAtEpochMs $expires
    $markerPath = Join-Path ([IO.Path]::GetTempPath()) "qcvc-marker-$run.json"
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($markerPath, (($marker | ConvertTo-Json -Depth 3) + "`n"), $utf8)
    try {
        $roundTrip = ConvertFrom-StrictMarkerJson (Get-Content -Raw -LiteralPath $markerPath)
        $markerSha = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $uploadCandidate = "/data/local/tmp/qcvc-$run-candidate.upload"
        $uploadMarker = "/data/local/tmp/qcvc-$run-marker.upload"
        try {
            Push-LocalFile $candidatePath $uploadCandidate
            Push-LocalFile $markerPath $uploadMarker
            $command = New-DeployCommitShell -Paths $paths -RunId $run -Candidate $candidate `
                    -MarkerSha256 $markerSha -UploadCandidate $uploadCandidate -UploadMarker $uploadMarker
            $result = Invoke-WriteShell -Command $command -Mode $mode -AllowFailure
            if ($result.ExitCode -ne 0) {
                $status = Invoke-Status
                if ($status.MarkerState -ne 'armed' -or $status.RunId -ne $run -or
                        $status.OpenXrCopyBatchMode -cne $OpenXrCopyBatchMode) {
                    throw 'Deploy failed before an exact committed marker could be proven.'
                }
            }
        } catch {
            Invoke-WriteShell -Mode $mode -Command "rm -f $(ConvertTo-ShLiteral $uploadCandidate) $(ConvertTo-ShLiteral $uploadMarker)" -AllowFailure | Out-Null
            throw
        }
    } finally {
        [IO.File]::Delete($markerPath)
    }
    [pscustomobject]@{
        Result = 'ARMED'
        Package = $script:Package
        Profile = $script:Profile
        HarnessId = $script:HarnessId
        RunId = $run
        CandidateSha256 = $candidate.Sha256
        CandidateSizeBytes = $candidate.SizeBytes
        FabricVersion = $candidate.Version
        OpenXrCopyBatchMode = $OpenXrCopyBatchMode
        ExpiresAtEpochMs = $expires
        MaxLaunches = 1
        CandidateOutsideMods = $true
        MarkerCommittedLast = $true
        AccessMode = $mode
    }
}

function Invoke-Rollback {
    if (-not $AllowDeviceWrite) { throw 'Rollback is disabled until -AllowDeviceWrite is explicit.' }
    Assert-PackageInstalled
    $paths = Get-DevicePaths
    $mode = Resolve-WriteMode $paths
    $run = New-RunId
    $upload = "/data/local/tmp/qcvc-$run-baseline.upload"
    try {
        Push-LocalFile $script:BaselinePath $upload
        $result = Invoke-WriteShell -Mode $mode -Command (New-RollbackShell $paths $run $upload) -AllowFailure
        if ($result.ExitCode -ne 0) { throw 'Rollback failed; exact baseline restoration was not proven.' }
    } catch {
        Invoke-WriteShell -Mode $mode -Command "rm -f $(ConvertTo-ShLiteral $upload)" -AllowFailure | Out-Null
        throw
    }
    $after = Get-RemotePreflight $paths $mode
    Assert-Condition ($after.TargetSha256 -eq $script:BaselineSha256 -and
            $after.TargetSize -eq $script:BaselineSize) 'Rollback verification failed.'
    [pscustomobject]@{
        Result = 'ROLLED_BACK'
        Package = $script:Package
        Profile = $script:Profile
        TargetSha256 = $after.TargetSha256
        TargetSizeBytes = $after.TargetSize
        AppAndJvmWereRequiredStopped = $true
        AccessMode = $mode
    }
}

function Invoke-SelfTest {
    $before = $script:AdbInvocationCount
    Resolve-BaselineLock
    $metadata = Get-StrictFabricMetadata $script:BaselinePath
    $candidate = [pscustomobject]@{
        Id = $metadata.Id
        Version = $metadata.Version
        MinecraftDependency = $metadata.MinecraftDependency
        JavaDependency = $metadata.JavaDependency
        SizeBytes = $metadata.SizeBytes
        Sha256 = $metadata.Sha256
    }
    $marker = New-MarkerObject -RunId '0123456789abcdef0123456789abcdef' `
            -Candidate $candidate -OtherModsFingerprintSha256 ('a' * 64) `
            -Mode 'OFF' `
            -ExpiresAtEpochMs 1800000000000
    Assert-StrictMarkerObject ([pscustomobject]$marker)
    ConvertFrom-StrictMarkerJson (($marker | ConvertTo-Json -Depth 3) + "`n") | Out-Null
    Assert-Condition ([string]$marker.openXrCopyBatchMode -ceq 'OFF') `
            'The marker default test is not exact OFF.'
    $onMarker = New-MarkerObject -RunId 'fedcba9876543210fedcba9876543210' `
            -Candidate $candidate -OtherModsFingerprintSha256 ('b' * 64) `
            -Mode 'ON' -ExpiresAtEpochMs 1800000000000
    Assert-StrictMarkerObject ([pscustomobject]$onMarker)
    Assert-Condition ([string]$onMarker.openXrCopyBatchMode -ceq 'ON') `
            'The exact ON marker was not retained.'
    $testGame = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile"
    $testPaths = [pscustomobject]@{
        Files = "/sdcard/Android/data/$script:Package/files"
        Game = $testGame
        Mods = "$testGame/mods"
        State = "$testGame/$script:StateRelative"
        Target = "$testGame/$script:TargetRelative"
        Marker = "$testGame/$script:StateRelative/request.json"
        RejectedMarker = "$testGame/$script:StateRelative/request.rejected.json"
    }
    $preflightShell = Get-RemotePreflightShell $testPaths
    foreach ($leaf in @('Vivecraft.jar', 'Vivecraft-Essentials-Quest.jar')) {
        $exactSkip = "[ `"`$qcvc_file`" = '$($testPaths.Mods)/$leaf' ] && continue"
        Assert-Condition ($preflightShell.Contains($exactSkip)) `
                "Shared paired fingerprint does not exclude exactly $leaf."
    }
    Assert-Condition (@($script:FingerprintExcludedLeaves).Count -eq 2) `
            'Shared paired fingerprint must exclude exactly the two managed targets.'
    $duplicateRejected = $false
    try {
        ConvertFrom-StrictMarkerJson ((($marker | ConvertTo-Json -Depth 3) -replace '^\{',
                '{"schemaVersion":2,')) | Out-Null
    } catch { $duplicateRejected = $true }
    Assert-Condition $duplicateRejected 'Duplicate marker JSON field was not rejected.'
    foreach ($invalidMode in @('on', 'OFF ', '-Dvivecraft.openxrCopyBatch=ON')) {
        $invalidMarker = ($marker | ConvertTo-Json -Depth 3) | ConvertFrom-Json
        $invalidMarker.openXrCopyBatchMode = $invalidMode
        $invalidRejected = $false
        try { Assert-StrictMarkerObject $invalidMarker } catch { $invalidRejected = $true }
        Assert-Condition $invalidRejected "Invalid copy-batch mode '$invalidMode' was accepted."
    }
    $missingMode = ($marker | ConvertTo-Json -Depth 3) | ConvertFrom-Json
    $missingMode.PSObject.Properties.Remove('openXrCopyBatchMode')
    $missingRejected = $false
    try { Assert-StrictMarkerObject $missingMode } catch { $missingRejected = $true }
    Assert-Condition $missingRejected 'A marker without copy-batch mode was accepted.'
    $oldSchema = ($marker | ConvertTo-Json -Depth 3) | ConvertFrom-Json
    $oldSchema.schemaVersion = 1
    $oldSchemaRejected = $false
    try { Assert-StrictMarkerObject $oldSchema } catch { $oldSchemaRejected = $true }
    Assert-Condition $oldSchemaRejected 'A schema-1 marker was accepted by schema 2.'
    Assert-Condition (Test-SafeZipName 'fabric.mod.json') 'Safe ZIP name rejected.'
    Assert-Condition (-not (Test-SafeZipName '../escape')) 'Traversal ZIP name accepted.'
    Assert-Condition (-not (Test-SafeZipName 'a\b')) 'Backslash ZIP name accepted.'
    $zipRoot = Join-Path ([IO.Path]::GetTempPath()) ('qcvc-zip-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($zipRoot) | Out-Null
    function New-QcvcSelfTestJar {
        param([string] $Path, [string[]] $ExtraNames, [string] $SymlinkName = '')
        $stream = [IO.File]::Create($Path)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entries = @('fabric.mod.json', 'payload.txt') + $ExtraNames
            foreach ($name in $entries) {
                $entry = $zip.CreateEntry($name)
                if ($name -eq $SymlinkName) {
                    $entry.ExternalAttributes = [BitConverter]::ToInt32(
                            [byte[]](0x00, 0x00, 0xFF, 0xA1), 0)
                }
                $bytes = if ($name -eq 'fabric.mod.json') {
                    [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"id":"vivecraft","version":"26.2-test","depends":{"minecraft":["26.2.x"],"java":">=25"}}')
                } else { [Text.Encoding]::UTF8.GetBytes($name) }
                $entryStream = $entry.Open()
                try { $entryStream.Write($bytes, 0, $bytes.Length) } finally { $entryStream.Dispose() }
            }
        } finally {
            $zip.Dispose()
            $stream.Dispose()
        }
    }
    try {
        $safeJar = Join-Path $zipRoot 'safe.jar'
        New-QcvcSelfTestJar $safeJar @('data/ok.class')
        Assert-Condition ((Get-StrictFabricMetadata $safeJar).Id -eq 'vivecraft') `
                'Safe self-test JAR was rejected.'
        foreach ($bad in @(
            [pscustomobject]@{ Name = 'traversal.jar'; Entries = @('../escape'); Link = '' },
            [pscustomobject]@{ Name = 'duplicate.jar'; Entries = @('data/A.class','data/a.class'); Link = '' },
            [pscustomobject]@{ Name = 'symlink.jar'; Entries = @('data/link'); Link = 'data/link' }
        )) {
            $badJar = Join-Path $zipRoot $bad.Name
            New-QcvcSelfTestJar $badJar $bad.Entries $bad.Link
            $rejected = $false
            try { Get-StrictFabricMetadata $badJar | Out-Null } catch { $rejected = $true }
            Assert-Condition $rejected "Unsafe archive '$($bad.Name)' was accepted."
        }
    } finally {
        [IO.Directory]::Delete($zipRoot, $true)
    }
    Assert-Condition ((Select-OnlyDevice @('List of devices attached', 'only-device device') `
            -RequestedSerial auto) -eq 'only-device') `
            'Single-device selection failed.'
    $multipleRejected = $false
    try {
        Select-OnlyDevice @('one device', 'two device') -RequestedSerial auto | Out-Null
    } catch { $multipleRejected = $true }
    Assert-Condition $multipleRejected 'Multiple ADB devices were not rejected.'
    Assert-Condition ((Select-OnlyDevice @('usb-device offline', '192.0.2.5:5555 device') `
            -RequestedSerial '192.0.2.5:5555') -eq '192.0.2.5:5555') `
            'An explicit online serial could not be selected beside an offline transport.'
    $offlineRequestedRejected = $false
    try {
        Select-OnlyDevice @('usb-device offline', '192.0.2.5:5555 device') `
                -RequestedSerial 'usb-device' | Out-Null
    } catch { $offlineRequestedRejected = $true }
    Assert-Condition $offlineRequestedRejected 'An explicitly requested offline transport was accepted.'
    $source = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot `
            'Pojlib/src/main/java/pojlib/VivecraftCoreCanaryGate.java')
    Assert-Condition ($source.Contains("HARNESS_ID = `"$script:HarnessId`"")) 'Java harness id drifted.'
    Assert-Condition ($source.Contains("EXPECTED_PACKAGE = `"$script:Package`"")) 'Java package drifted.'
    Assert-Condition ($source.Contains("TARGET = `"$script:TargetRelative`"")) 'Java target drifted.'
    $helperSource = Get-Content -Raw -LiteralPath $PSCommandPath
    Assert-Condition ($helperSource.Contains('head -c 512')) `
            'The procfs stopped-app scan is not bounded.'
    $unboundedProcReader = "tr '\000' '\n' " + '<'
    Assert-Condition (-not $helperSource.Contains($unboundedProcReader)) `
            'An unbounded procfs cmdline reader is present.'
    Assert-Condition ($script:AdbInvocationCount -eq $before) 'SelfTest invoked ADB.'
    [pscustomobject]@{
        Result = 'PASS'
        DeviceTouched = $false
        AdbInvocations = $script:AdbInvocationCount - $before
        HarnessId = $script:HarnessId
        Package = $script:Package
        Profile = $script:Profile
        BaselineSha256 = $script:BaselineSha256
        BaselineSizeBytes = $script:BaselineSize
        CandidateLimitBytes = $script:MaxCandidateBytes
        ExpiryMaximumMinutes = 30
        MarkerSchemaVersion = $script:MarkerSchemaVersion
        DefaultOpenXrCopyBatchMode = 'OFF'
    }
}

$OpenXrCopyBatchMode = Assert-OpenXrCopyBatchMode $OpenXrCopyBatchMode
if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    return
}

Resolve-BaselineLock
Resolve-Device
switch ($Action) {
    'Status' { Invoke-Status }
    'Deploy' { Invoke-Deploy }
    'Rollback' { Invoke-Rollback }
}
