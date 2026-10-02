#requires -Version 7.0
<#
.SYNOPSIS
Safely restores the fixed FPS-Stress-Test world for the exact V71 RC8 Lab.

.DESCRIPTION
This tool is intentionally narrower than reset-lab-benchmark-world.ps1. It is
pinned to the exact RC8 Lab APK/Core/VEQ stack, package
com.qcxr.qcxr.canary262, profile 26.2, and save folder FPS-Stress-Test.

An explicitly selected USB serial is accepted even when the same headset also
appears as a Wi-Fi ADB endpoint. Auto selection still requires exactly one
authorized endpoint. Reset requires explicit read/write/identity consent and
refuses to run while either Lab or Stable is alive.

Before the first reset, the existing Lab benchmark world is archived once in a
tool-owned Lab directory and its SHA-256 is recorded and verified. If no world
exists, an exact absent marker is recorded instead. The snapshot is never
replaced by a later reset. The tool has no mutation path to Stable, accounts,
mods, configuration, or resource packs.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Status', 'Reset')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [string] $OutputJson = '',

    [switch] $AllowDeviceRead,
    [switch] $AllowDeviceWrite,
    [switch] $ConfirmExactRc8Lab,

    [switch] $AllowRootFallback,
    [switch] $AllowHostOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BuildLockPath = Join-Path $script:RepoRoot 'V71_LAB_RC8.lock.json'
$script:MasterRelativePath = `
    'artifacts\benchmark-worlds\gamerpotion-fps-stress-3595582\masters\visor-fps-stress-26.2-route-master.tar'
$script:MasterTar = Join-Path $script:RepoRoot $script:MasterRelativePath
if (-not (Test-Path -LiteralPath $script:MasterTar -PathType Leaf)) {
    $repoParent = Split-Path -Parent $script:RepoRoot
    if ([IO.Path]::GetFileName($repoParent) -ceq 'work') {
        $sharedRoot = Split-Path -Parent $repoParent
        $script:MasterTar = Join-Path $sharedRoot $script:MasterRelativePath
    }
}

$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:World = 'FPS-Stress-Test'
$script:MasterDirectory = 'FPS Stress Test'
$script:VersionCode = 71L
$script:VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'
$script:ApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$script:SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:CoreSha256 = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$script:VeqSha256 = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$script:BuildLockSha256 = 'BB5147F0B5B0A3AB5C61D7012A821F0C2583BDE76F96F963C19EDDD967177EF7'
$script:MasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$script:MasterSizeBytes = 58186240L
$script:MasterEntryCount = 126
$script:MasterFileCount = 100
$script:MasterDirectoryCount = 26
$script:MasterLevelDatSha256 = '42446BBE1195E2AFB2BE44FC90600C7ED32750BF0F02D45C0CE505F83AAD9065'

$script:LexicalFiles = "/sdcard/Android/data/$($script:Package)/files"
$script:LexicalGame = "$($script:LexicalFiles)/instances/$($script:Profile)"
$script:LexicalCore = "$($script:LexicalGame)/mods/Vivecraft.jar"
$script:LexicalVeq = "$($script:LexicalGame)/mods/Vivecraft-Essentials-Quest.jar"
$script:LexicalCanaryMarker =
    "$($script:LexicalGame)/.questcraft/questcraft-vivecraft-core-canary-v9/request.json"
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocations = 0
$script:DeviceWrites = 0
$script:HostWrites = 0
$script:Assertions = 0
$script:MutexNamespace = 'Local\QC_V71_RC8_WORLD_RESET'
$script:AccessMode = 'Normal'
$script:RootSuPath = '/debug_ramdisk/su'
$script:PerformanceArtifactRoot = Join-Path $script:RepoRoot `
    'artifacts\v71-rc8-input-performance-ab'
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:ResolvedOutputJson = $null

function Require([bool] $Condition, [string] $Message) {
    $script:Assertions++
    if (-not $Condition) { throw "[RC8_WORLD_RESET] $Message" }
}

function Test-Throws([Parameter(Mandatory)][scriptblock] $Operation) {
    try { & $Operation; return $false } catch { return $true }
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [string][char]39
    $escaped = $quote + '"' + $quote + '"' + $quote
    $quote + $Value.Replace($quote, $escaped) + $quote
}

function ConvertTo-PosixScript(
    [Parameter(Mandatory)][AllowEmptyString()][string] $Value
) {
    $Value.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-TextSha256([Parameter(Mandatory)][string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))
    } finally { $sha.Dispose() }
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-TextSha256 $text
}

function Get-FileSha256([Parameter(Mandatory)][string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-CanonicalHostPath([Parameter(Mandatory)][string] $Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-NoHostReparsePath([Parameter(Mandatory)][string] $Path) {
    $root = Get-CanonicalHostPath $script:RepoRoot
    $full = Get-CanonicalHostPath $Path
    Require ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) `
        'A Host output path escaped this worktree.'
    $cursor = $root
    $relative = [IO.Path]::GetRelativePath($root, $full)
    foreach ($part in $relative.Split([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            Require (-not ((Get-Item -LiteralPath $cursor -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint)) `
                'A Host output path contains a reparse point.'
        }
    }
}

function Resolve-PerformanceReceiptPath([Parameter(Mandatory)][string] $Path) {
    Require (-not [string]::IsNullOrWhiteSpace($Path)) `
        'Reset requires an explicit performance-receipt output path.'
    $root = Get-CanonicalHostPath $script:PerformanceArtifactRoot
    $candidate = if ([IO.Path]::IsPathRooted($Path)) {
        Get-CanonicalHostPath $Path
    } else {
        Get-CanonicalHostPath (Join-Path $script:RepoRoot $Path)
    }
    Require ($candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) `
        'The reset receipt must remain under the input-performance artifact root.'
    Require ([IO.Path]::GetFileName($candidate) -cmatch '^reset-[0-9]{2}\.json$') `
        'The reset receipt must use the exact reset-NN.json campaign name.'
    Require (-not (Test-Path -LiteralPath $candidate)) `
        'Refusing to overwrite a world-reset receipt.'
    Assert-NoHostReparsePath $candidate
    $candidate
}

function Write-JsonAtomic([Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Value) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    Assert-NoHostReparsePath $directory
    $temporary = $Path + '.next-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary,
            ($Value | ConvertTo-Json -Depth 10), $script:Utf8NoBom)
        [IO.File]::Move($temporary, $Path)
        $script:HostWrites++
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Get-TransactionMutexName {
    $identity = "$($script:Package)|$($script:Profile)|$($script:World)"
    "$($script:MutexNamespace)_$(Get-TextSha256 $identity)"
}

function Enter-TransactionMutex {
    $mutex = [Threading.Mutex]::new($false, (Get-TransactionMutexName))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        Require $acquired 'Another RC8 benchmark-world reset/status invocation is active.'
        [pscustomobject]@{ Mutex = $mutex; Acquired = $true }
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-TransactionMutex([Parameter(Mandatory)] $Lease) {
    try {
        if ([bool]$Lease.Acquired) { $Lease.Mutex.ReleaseMutex() }
    } finally { $Lease.Mutex.Dispose() }
}

function Get-NonBlankRows(
    [AllowEmptyString()][AllowEmptyCollection()][string[]] $Lines = @()
) {
    @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-SafeArchiveEntries(
    [Parameter(Mandatory)][string[]] $Entries,
    [Parameter(Mandatory)][string] $ExpectedRoot,
    [int] $ExpectedCount = 0
) {
    $rows = @(Get-NonBlankRows $Entries)
    Require ($rows.Count -gt 1) 'An archive listing was empty or implausibly small.'
    if ($ExpectedCount -gt 0) {
        Require ($rows.Count -eq $ExpectedCount) 'The fixed master archive entry count drifted.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $levelFound = $false
    foreach ($raw in $rows) {
        $entry = $raw.Replace('\', '/')
        Require (-not $entry.StartsWith('/', [StringComparison]::Ordinal)) `
            'An archive entry was absolute.'
        Require (-not $entry.Contains("`0") -and -not $entry.Contains("`n") -and
                -not $entry.Contains("`r")) 'An archive entry contained control data.'
        $parts = @($entry.Split('/') | Where-Object { $_.Length -gt 0 })
        Require ($parts.Count -gt 0 -and $parts[0] -ceq $ExpectedRoot) `
            'An archive entry escaped the fixed world root.'
        Require (@($parts | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -eq 0) `
            'An archive entry contained path traversal.'
        Require ($seen.Add($entry)) 'An archive contained a duplicate entry.'
        if ($entry -ceq "$ExpectedRoot/level.dat") { $levelFound = $true }
    }
    Require $levelFound 'The archive did not contain the fixed world level.dat.'
    [pscustomobject]@{ Entries = $rows.Count; LevelDatPresent = $true }
}

function Assert-RegularArchiveEntryTypes(
    [Parameter(Mandatory)][string[]] $Rows,
    [int] $ExpectedCount = 0
) {
    $entries = @(Get-NonBlankRows $Rows)
    Require ($entries.Count -gt 1) 'An archive type listing was empty or implausibly small.'
    if ($ExpectedCount -gt 0) {
        Require ($entries.Count -eq $ExpectedCount) 'An archive type count drifted.'
    }
    foreach ($row in $entries) {
        Require ($row.Length -gt 0 -and $row[0] -cin @('-', 'd')) `
            'An archive contained a link or special entry.'
    }
    $entries.Count
}

function Assert-HostContract {
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262' -and
            $script:StablePackage -ceq 'com.qcxr.qcxr.dev262' -and
            $script:Package -cne $script:StablePackage) 'The Lab/Stable boundary drifted.'
    Require ($script:Profile -ceq '26.2' -and $script:World -ceq 'FPS-Stress-Test') `
        'The fixed profile/world contract drifted.'
    Require (Test-Path -LiteralPath $script:BuildLockPath -PathType Leaf) `
        'The exact RC8 build lock is missing.'
    Require ((Get-NormalizedTextSha256 $script:BuildLockPath) -ceq $script:BuildLockSha256) `
        'The exact RC8 build lock bytes drifted.'
    $lock = Get-Content -Raw -LiteralPath $script:BuildLockPath | ConvertFrom-Json -Depth 30
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

    Require (Test-Path -LiteralPath $script:MasterTar -PathType Leaf) `
        'The fixed FPS Stress Test master is missing.'
    Require ((Get-Item -LiteralPath $script:MasterTar).Length -eq $script:MasterSizeBytes) `
        'The fixed world master size drifted.'
    Require ((Get-FileSha256 $script:MasterTar) -ceq $script:MasterSha256) `
        'The fixed world master hash drifted.'
    $entries = @(& tar -tf $script:MasterTar 2>$null | ForEach-Object { [string]$_ })
    Require ($LASTEXITCODE -eq 0) 'The fixed world master could not be listed.'
    $archive = Assert-SafeArchiveEntries -Entries $entries `
        -ExpectedRoot $script:MasterDirectory -ExpectedCount $script:MasterEntryCount
    $files = @($entries | Where-Object { -not ([string]$_).EndsWith('/') }).Count
    $directories = @($entries | Where-Object { ([string]$_).EndsWith('/') }).Count
    Require ($files -eq $script:MasterFileCount -and
            $directories -eq $script:MasterDirectoryCount) `
        'The fixed master file/directory contract drifted.'
    $verboseEntries = @(& tar -tvf $script:MasterTar 2>$null |
        ForEach-Object { [string]$_ })
    Require ($LASTEXITCODE -eq 0) 'The fixed master type listing failed.'
    $null = Assert-RegularArchiveEntryTypes -Rows $verboseEntries `
        -ExpectedCount $script:MasterEntryCount
    $archive
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdk -PathType Leaf) { return $sdk }
    throw '[RC8_WORLD_RESET] ADB was not found.'
}

function Invoke-Adb(
    [Parameter(Mandatory)][string[]] $Arguments,
    [switch] $AllowFailure,
    [switch] $Write,
    [string] $Context = 'adb'
) {
    if ($Write) {
        Require $AllowDeviceWrite.IsPresent 'A device write was attempted without -AllowDeviceWrite.'
        $script:DeviceWrites++
    }
    $script:DeviceInvocations++
    $lastArgument = if ($Arguments.Count -gt 0) { [string]$Arguments[-1] } else { '' }
    Write-Verbose ("ADB step={0} argc={1} lastArgLength={2} lastArgSha256={3}" -f
        $Context, $Arguments.Count, $lastArgument.Length, (Get-TextSha256 $lastArgument))
    $rows = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    Write-Verbose ("ADB result step={0} exit={1} rows={2}" -f
        $Context, $exitCode, $rows.Count)
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "[RC8_WORLD_RESET] ADB step '$Context' failed ($exitCode); output suppressed."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $rows }
}

function Invoke-AdbWithStandardInput(
    [Parameter(Mandatory)][string[]] $Arguments,
    [Parameter(Mandatory)][AllowEmptyString()][string] $StandardInput,
    [switch] $AllowFailure,
    [switch] $Write,
    [string] $Context = 'adb-stdin'
) {
    if ($Write) {
        Require $AllowDeviceWrite.IsPresent 'A device write was attempted without -AllowDeviceWrite.'
        $script:DeviceWrites++
    }
    $script:DeviceInvocations++
    $normalized = ConvertTo-PosixScript $StandardInput
    Write-Verbose ("ADB stdin step={0} argc={1} bytes={2} sha256={3}" -f
        $Context, $Arguments.Count,
        [Text.Encoding]::UTF8.GetByteCount($normalized), (Get-TextSha256 $normalized))
    $rows = @($normalized | & $script:Adb @Arguments 2>&1 |
        ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    Write-Verbose ("ADB stdin result step={0} exit={1} rows={2}" -f
        $Context, $exitCode, $rows.Count)
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "[RC8_WORLD_RESET] ADB stdin step '$Context' failed ($exitCode); output suppressed."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $rows }
}

function Get-AuthorizedDeviceRecords(
    [AllowEmptyString()][AllowEmptyCollection()][string[]] $Lines = @()
) {
    @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_,
            '^\s*(?<serial>\S+)\s+device(?<details>(?:\s+.*)?)$')
        if ($match.Success) {
            [pscustomobject]@{
                Serial = [string]$match.Groups['serial'].Value
                Details = [string]$match.Groups['details'].Value
            }
        }
    })
}

function Resolve-Device {
    $script:Adb = Resolve-Adb
    $listing = Invoke-Adb @('devices', '-l') -Context 'list-devices'
    $records = @(Get-AuthorizedDeviceRecords ([string[]]$listing.Lines))
    Require ($records.Count -gt 0) 'No authorized ADB device was found.'
    if ($Serial -ceq 'auto') {
        Require ($records.Count -eq 1) `
            'Auto selection requires exactly one authorized ADB endpoint.'
        $script:Device = [string]$records[0].Serial
    } else {
        $matches = @($records | Where-Object { $_.Serial -ceq $Serial })
        Require ($matches.Count -eq 1) `
            'The explicitly requested ADB serial was missing or ambiguous.'
        $script:Device = $Serial
    }
    Require ($script:Device -cmatch '^[A-Za-z0-9._:-]+$') 'The selected serial was unsafe.'
    $state = Invoke-Adb @('-s', $script:Device, 'get-state') -Context 'get-device-state'
    $rows = @(Get-NonBlankRows ([string[]]$state.Lines))
    Require ($rows.Count -eq 1 -and $rows[0] -ceq 'device') `
        'The selected ADB endpoint was not ready.'
}

function Invoke-NormalShellScript(
    [Parameter(Mandatory)][AllowEmptyString()][string] $Script,
    [switch] $AllowFailure,
    [switch] $Write,
    [string] $Context = 'normal-device-shell-script'
) {
    # `adb shell sh -c <script>` passed as separate Windows argv entries loses
    # the quoting boundary when adb reconstructs the remote command. Send one
    # already POSIX-quoted remote command so the entire script is the -c body.
    $normalizedScript = ConvertTo-PosixScript $Script
    $remoteCommand = 'sh -c ' + (ConvertTo-ShLiteral $normalizedScript)
    Invoke-Adb @('-s', $script:Device, 'shell', $remoteCommand) `
        -AllowFailure:$AllowFailure -Write:$Write -Context $Context
}

function Invoke-RootShellScript(
    [Parameter(Mandatory)][AllowEmptyString()][string] $Script,
    [switch] $AllowFailure,
    [switch] $Write,
    [string] $Context = 'root-device-shell-script'
) {
    Require $AllowRootFallback.IsPresent `
        'Root execution requires explicit -AllowRootFallback.'
    $normalizedScript = ConvertTo-PosixScript $Script
    Invoke-AdbWithStandardInput `
        -Arguments @('-s', $script:Device, 'shell', $script:RootSuPath, '-c', 'sh') `
        -StandardInput $normalizedScript -AllowFailure:$AllowFailure `
        -Write:$Write -Context $Context
}

function Join-PosixCommand([Parameter(Mandatory)][string[]] $Arguments) {
    Require ($Arguments.Count -gt 0) 'A device command cannot be empty.'
    (@($Arguments | ForEach-Object { ConvertTo-ShLiteral ([string]$_) }) -join ' ')
}

function Invoke-Shell(
    [Parameter(Mandatory)][string[]] $Arguments,
    [switch] $AllowFailure,
    [switch] $Write,
    [string] $Context = 'device-shell'
) {
    if ($script:AccessMode -ceq 'Root') {
        return Invoke-RootShellScript -Script (Join-PosixCommand $Arguments) `
            -AllowFailure:$AllowFailure -Write:$Write -Context $Context
    }
    Require ($script:AccessMode -ceq 'Normal') 'The selected device access mode is invalid.'
    Invoke-Adb (@('-s', $script:Device, 'shell') + $Arguments) `
        -AllowFailure:$AllowFailure -Write:$Write -Context $Context
}

function Invoke-ShellScript(
    [Parameter(Mandatory)][AllowEmptyString()][string] $Script,
    [switch] $AllowFailure,
    [switch] $Write,
    [string] $Context = 'device-shell-script'
) {
    if ($script:AccessMode -ceq 'Root') {
        return Invoke-RootShellScript -Script $Script -AllowFailure:$AllowFailure `
            -Write:$Write -Context $Context
    }
    Require ($script:AccessMode -ceq 'Normal') 'The selected device access mode is invalid.'
    Invoke-NormalShellScript -Script $Script -AllowFailure:$AllowFailure `
        -Write:$Write -Context $Context
}

function Read-PidState([Parameter(Mandatory)][string] $Package) {
    $probe = Invoke-Shell @('pidof', $Package) -AllowFailure -Context "pid-$Package"
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    if ($probe.ExitCode -eq 1 -and $rows.Count -eq 0) { return $null }
    Require ($probe.ExitCode -eq 0 -and $rows.Count -eq 1 -and
            $rows[0] -cmatch '^[1-9][0-9]*$') `
        "The PID state for $Package was ambiguous."
    [int64]$rows[0]
}

function Assert-StableStopped {
    Require ($null -eq (Read-PidState $script:StablePackage)) `
        'Stable is running. This tool never stops or changes Stable.'
}

function Assert-LabStopped {
    Require ($null -eq (Read-PidState $script:Package)) `
        'Lab must be stopped before the benchmark world is reset.'
}

function Assert-SelectedUsbSerial {
    $probe = Invoke-Shell @('getprop', 'ro.serialno') -Context 'verify-usb-device-serial'
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($rows.Count -eq 1 -and $rows[0] -ceq $Serial) `
        'The selected endpoint is not the explicitly named USB device serial.'
}

function Get-WorldAccessProbeScript([Parameter(Mandatory)] $Paths) {
    $qWorld = ConvertTo-ShLiteral $Paths.World
    @"
# QC_RC8_WORLD_ACCESS_PROBE
set -u
world=$qWorld
if [ -L "`$world" ]; then
  exit 12
elif [ ! -e "`$world" ]; then
  echo QC_RC8_WORLD_ACCESS_OK:MISSING
elif [ -d "`$world" ] && [ -f "`$world/level.dat" ]; then
  sha256sum "`$world/level.dat" >/dev/null 2>&1 || exit 11
  echo QC_RC8_WORLD_ACCESS_OK:PRESENT
else
  exit 13
fi
"@
}

function Test-ExactWorldAccessResult([Parameter(Mandatory)] $Result) {
    $rows = @(Get-NonBlankRows ([string[]]$Result.Lines))
    $Result.ExitCode -eq 0 -and $rows.Count -eq 1 -and
        $rows[0] -cin @('QC_RC8_WORLD_ACCESS_OK:MISSING',
            'QC_RC8_WORLD_ACCESS_OK:PRESENT')
}

function Select-WorldAccessMode([Parameter(Mandatory)] $Paths) {
    Require ($script:DeviceWrites -eq 0) `
        'Device access mode must be selected before the first mutation.'
    $script:AccessMode = 'Normal'
    $probeScript = Get-WorldAccessProbeScript $Paths
    $normal = Invoke-NormalShellScript -Script $probeScript -AllowFailure `
        -Context 'probe-normal-world-access'
    if (Test-ExactWorldAccessResult $normal) {
        return 'Normal'
    }
    Require $AllowRootFallback.IsPresent `
        'Normal Android shell cannot read the benchmark world; explicit root fallback was not authorized.'
    $suProbe = Invoke-Adb @('-s', $script:Device, 'shell', 'test', '-x',
        $script:RootSuPath) -AllowFailure -Context 'probe-fixed-root-entrypoint'
    Require ($suProbe.ExitCode -eq 0 -and
            @(Get-NonBlankRows ([string[]]$suProbe.Lines)).Count -eq 0) `
        'The fixed Magisk root entrypoint is unavailable.'
    $rootPreamble = @'
set -eu
test "$(id -u)" = 0
'@
    $root = Invoke-RootShellScript -Script ($rootPreamble + "`n" + $probeScript) -AllowFailure `
        -Context 'probe-root-world-access'
    Require (Test-ExactWorldAccessResult $root) `
        'Root could not prove safe read access to the exact benchmark world.'
    $script:AccessMode = 'Root'
    'Root'
}

function Read-PackageIdentity(
    [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]] $Lines
) {
    $codes = @($Lines | ForEach-Object {
        $m = [regex]::Match([string]$_, '^\s*versionCode=(?<v>[0-9]+)(?:\s|$)')
        if ($m.Success) { [int64]$m.Groups['v'].Value }
    })
    $names = @($Lines | ForEach-Object {
        $m = [regex]::Match([string]$_, '^\s*versionName=(?<v>\S+)\s*$')
        if ($m.Success) { [string]$m.Groups['v'].Value }
    })
    Require ($codes.Count -eq 1 -and $names.Count -eq 1) `
        'The installed Lab package identity was incomplete or ambiguous.'
    [pscustomobject]@{ VersionCode = $codes[0]; VersionName = $names[0] }
}

function Read-BaseApkPath(
    [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]] $Lines
) {
    $rows = @(Get-NonBlankRows $Lines)
    Require ($rows.Count -eq 1 -and $rows[0] -cmatch
        '^package:(?<p>/data/app/(?:[A-Za-z0-9._~+=-]+/)+base\.apk)$') `
        'The installed Lab did not expose one safe base APK.'
    $path = [string]$Matches.p
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)') -and
            -not $path.Contains('/../', [StringComparison]::Ordinal)) `
        'The base APK path was not bound to the Lab package.'
    $path
}

function Read-RemoteSha256([Parameter(Mandatory)][string] $Path, [switch] $AllowMissing) {
    $qPath = ConvertTo-ShLiteral $Path
    $command = @"
# QC_RC8_HASH_PROBE
path=$qPath
if [ -L "`$path" ]; then
  echo INVALID_SYMLINK
elif [ -f "`$path" ]; then
  sha256sum "`$path"
elif [ ! -e "`$path" ]; then
  echo MISSING
else
  echo INVALID_LAYOUT
fi
"@
    $hashTarget = if ($Path -ceq $script:LexicalCore) {
        'core'
    } elseif ($Path -ceq $script:LexicalVeq) {
        'veq'
    } elseif ($Path.EndsWith('/base.apk', [StringComparison]::Ordinal)) {
        'apk'
    } elseif ($AllowMissing) {
        'optional-tool-cache'
    } else {
        'fixed-tool-file'
    }
    Write-Verbose ("Hash target={0} pathLength={1} pathSha256={2}" -f
        $hashTarget, $Path.Length, (Get-TextSha256 $Path))
    $probe = Invoke-ShellScript $command -Context "read-remote-sha256-$hashTarget"
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    if ($AllowMissing -and $probe.ExitCode -eq 0 -and $rows.Count -eq 1 -and
            $rows[0] -ceq 'MISSING') { return $null }
    Require ($probe.ExitCode -eq 0 -and $rows.Count -eq 1) `
        'A remote SHA-256 response was missing or ambiguous.'
    $m = [regex]::Match($rows[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require ($m.Success -and [string]$m.Groups['path'].Value -ceq $Path) `
        'A remote SHA-256 response named unexpected data.'
    ([string]$m.Groups['sha'].Value).ToUpperInvariant()
}

function Read-OneCanonicalPath([Parameter(Mandatory)][string] $LexicalPath) {
    $probe = Invoke-Shell @('realpath', $LexicalPath) -Context 'resolve-fixed-path'
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($rows.Count -eq 1) 'A fixed Lab path did not resolve unambiguously.'
    [string]$rows[0]
}

function Assert-ExactRc8Identity {
    Assert-StableStopped
    $identity = Read-PackageIdentity ([string[]](
        Invoke-Shell @('dumpsys', 'package', $script:Package) `
            -Context 'read-lab-package').Lines)
    Require ($identity.VersionCode -eq $script:VersionCode -and
            $identity.VersionName -ceq $script:VersionName) `
        'The installed app is not exact V71 RC8 Lab.'
    $base = Read-BaseApkPath ([string[]](
        Invoke-Shell @('pm', 'path', $script:Package) -Context 'read-base-apk-path').Lines)
    Require ((Read-RemoteSha256 $base) -ceq $script:ApkSha256) `
        'The installed Lab APK hash is not exact RC8.'
    Require ((Read-RemoteSha256 $script:LexicalCore) -ceq $script:CoreSha256) `
        'The persistent Vivecraft Core hash is not exact RC8.'
    Require ((Read-RemoteSha256 $script:LexicalVeq) -ceq $script:VeqSha256) `
        'The persistent VEQ hash is not exact RC8.'
    Require ($null -eq (Read-RemoteSha256 $script:LexicalCanaryMarker -AllowMissing)) `
        'The exact baseline reset requires the v9 candidate marker to be absent.'

    $files = Read-OneCanonicalPath $script:LexicalFiles
    $game = Read-OneCanonicalPath $script:LexicalGame
    $expectedFiles = "/storage/emulated/0/Android/data/$($script:Package)/files"
    Require ($files -ceq $expectedFiles) `
        'The canonical Lab files path escaped its package.'
    Require ($game -ceq "$files/instances/$($script:Profile)") `
        'The canonical Lab game directory escaped profile 26.2.'
    $saves = Read-OneCanonicalPath "$game/saves"
    Require ($saves -ceq "$game/saves") `
        'The canonical Lab saves directory escaped profile 26.2.'
    [pscustomobject]@{
        Files = $files
        Game = $game
        Saves = $saves
        World = "$saves/$($script:World)"
        StateRoot = "$files/.questcraft-benchmark-rc8"
        MasterCache = "$files/.questcraft-benchmark-rc8/route-master-$($script:MasterSha256).tar"
        Snapshot = "$files/.questcraft-benchmark-rc8/original-$($script:World).tar"
        SnapshotDigest = "$files/.questcraft-benchmark-rc8/original-$($script:World).sha256"
        AbsentMarker = "$files/.questcraft-benchmark-rc8/original-$($script:World).absent"
    }
}

function Get-WorldState([Parameter(Mandatory)] $Paths) {
    $qWorld = ConvertTo-ShLiteral $Paths.World
    $command = @"
# QC_RC8_WORLD_PROBE
set -u
world=$qWorld
if [ -L "`$world" ]; then
  echo INVALID_SYMLINK
elif [ ! -e "`$world" ]; then
  echo MISSING
elif [ -d "`$world" ] && [ -f "`$world/level.dat" ]; then
  sha=`$(sha256sum "`$world/level.dat" 2>/dev/null | awk '{print toupper(`$1)}')
  test -n "`$sha" || exit 11
  echo "PRESENT:`$sha"
else
  echo INVALID_LAYOUT
fi
"@
    $probe = Invoke-ShellScript $command -Context 'probe-world-state'
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($rows.Count -eq 1) 'The benchmark world state was ambiguous.'
    if ($rows[0] -ceq 'MISSING') {
        return [pscustomobject]@{ State = 'MISSING'; LevelDatSha256 = $null }
    }
    Require ($rows[0] -cmatch '^PRESENT:(?<sha>[0-9A-F]{64})$') `
        'The benchmark target was not a safe world directory.'
    [pscustomobject]@{ State = 'PRESENT'; LevelDatSha256 = [string]$Matches.sha }
}

function Get-SnapshotState([Parameter(Mandatory)] $Paths) {
    $qState = ConvertTo-ShLiteral $Paths.StateRoot
    $qSnapshot = ConvertTo-ShLiteral $Paths.Snapshot
    $qDigest = ConvertTo-ShLiteral $Paths.SnapshotDigest
    $qAbsent = ConvertTo-ShLiteral $Paths.AbsentMarker
    $markerValue = "$($script:World):ABSENT:$($script:MasterSha256)"
    $qMarkerValue = ConvertTo-ShLiteral $markerValue
    $command = @"
# QC_RC8_SNAPSHOT_PROBE
set -u
state=$qState
snapshot=$qSnapshot
digest=$qDigest
absent=$qAbsent
expected_absent=$qMarkerValue
if [ -L "`$state" ] || { [ -e "`$state" ] && [ ! -d "`$state" ]; }; then
  echo INVALID_PARENT
elif [ -L "`$snapshot" ] || [ -L "`$digest" ] || [ -L "`$absent" ]; then
  echo INVALID_SYMLINK
elif [ -f "`$snapshot" ] && [ -f "`$digest" ] && [ ! -e "`$absent" ]; then
  actual=`$(sha256sum "`$snapshot" 2>/dev/null | awk '{print toupper(`$1)}')
  recorded=`$(tr -d '\r\n' < "`$digest" 2>/dev/null)
  echo "SNAPSHOT:`$actual:`$recorded"
elif [ ! -e "`$snapshot" ] && [ ! -e "`$digest" ] && [ -f "`$absent" ]; then
  marker=`$(tr -d '\r\n' < "`$absent" 2>/dev/null)
  if [ "`$marker" = "`$expected_absent" ]; then echo ABSENT_MARKER; else echo INVALID_MARKER; fi
elif [ ! -e "`$snapshot" ] && [ ! -e "`$digest" ] && [ ! -e "`$absent" ]; then
  echo UNINITIALIZED
else
  echo INVALID_LAYOUT
fi
"@
    $probe = Invoke-ShellScript $command -Context 'probe-original-snapshot'
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($rows.Count -eq 1) 'The original-world snapshot state was ambiguous.'
    if ($rows[0] -ceq 'UNINITIALIZED') {
        return [pscustomobject]@{ State = 'UNINITIALIZED'; Sha256 = $null }
    }
    if ($rows[0] -ceq 'ABSENT_MARKER') {
        return [pscustomobject]@{ State = 'ABSENT_MARKER'; Sha256 = $null }
    }
    Require ($rows[0] -cmatch
        '^SNAPSHOT:(?<actual>[0-9A-F]{64}):(?<recorded>[0-9A-Fa-f]{64})$') `
        'The original-world snapshot contract was invalid.'
    $actual = [string]$Matches.actual
    $recorded = ([string]$Matches.recorded).ToUpperInvariant()
    Require ($actual -ceq $recorded) 'The original-world snapshot digest no longer matches.'
    $listing = Invoke-Shell @('tar', '-tf', $Paths.Snapshot) `
        -Context 'list-original-snapshot'
    $contract = Assert-SafeArchiveEntries -Entries ([string[]]$listing.Lines) `
        -ExpectedRoot $script:World
    $typeListing = Invoke-Shell @('tar', '-tvf', $Paths.Snapshot) `
        -Context 'list-original-snapshot-types'
    $null = Assert-RegularArchiveEntryTypes -Rows ([string[]]$typeListing.Lines) `
        -ExpectedCount $contract.Entries
    [pscustomobject]@{ State = 'SNAPSHOT'; Sha256 = $actual; Entries = $contract.Entries }
}

function New-OriginalSnapshot([Parameter(Mandatory)] $Paths, [Parameter(Mandatory)][string] $RunId) {
    $snapshotPart = "$($Paths.Snapshot).part-$RunId"
    $digestPart = "$($Paths.SnapshotDigest).part-$RunId"
    $absentPart = "$($Paths.AbsentMarker).part-$RunId"
    $qState = ConvertTo-ShLiteral $Paths.StateRoot
    $qSaves = ConvertTo-ShLiteral $Paths.Saves
    $qWorld = ConvertTo-ShLiteral $Paths.World
    $qSnapshot = ConvertTo-ShLiteral $Paths.Snapshot
    $qSnapshotPart = ConvertTo-ShLiteral $snapshotPart
    $qDigest = ConvertTo-ShLiteral $Paths.SnapshotDigest
    $qDigestPart = ConvertTo-ShLiteral $digestPart
    $qAbsent = ConvertTo-ShLiteral $Paths.AbsentMarker
    $qAbsentPart = ConvertTo-ShLiteral $absentPart
    $qLab = ConvertTo-ShLiteral $script:Package
    $qStable = ConvertTo-ShLiteral $script:StablePackage
    $qWorldName = ConvertTo-ShLiteral $script:World
    $markerValue = "$($script:World):ABSENT:$($script:MasterSha256)"
    $qMarkerValue = ConvertTo-ShLiteral $markerValue
    $command = @"
# QC_RC8_SNAPSHOT_CREATE
set -u
state=$qState
saves=$qSaves
world=$qWorld
snapshot=$qSnapshot
snapshot_part=$qSnapshotPart
digest=$qDigest
digest_part=$qDigestPart
absent=$qAbsent
absent_part=$qAbsentPart
lab=$qLab
stable=$qStable
world_name=$qWorldName
fail() { echo "QC_RC8_RESET_FAIL:`$1" >&2; exit "`$2"; }
assert_stopped() {
  for package in "`$lab" "`$stable"; do
    pids=`$(pidof "`$package" 2>&1); code=`$?
    if [ "`$code" -eq 1 ] && [ -z "`$pids" ]; then continue; fi
    fail process-state-changed 21
  done
}
assert_stopped
test -d "`$saves" && test ! -L "`$saves" || fail unsafe-saves-root 22
resolved_saves=`$(realpath "`$saves") || fail resolve-saves-root 22
test "`$resolved_saves" = "`$saves" || fail escaped-saves-root 22
mkdir -p "`$state" || fail create-state-root 23
test ! -L "`$state" || fail state-root-symlink 24
test ! -e "`$snapshot" && test ! -e "`$digest" && test ! -e "`$absent" || fail snapshot-already-initialized 25
if [ ! -e "`$world" ]; then
  printf '%s\n' $qMarkerValue > "`$absent_part" || fail write-absent-marker 26
  mv "`$absent_part" "`$absent" || fail publish-absent-marker 27
  echo QC_RC8_SNAPSHOT_CREATED:ABSENT_MARKER
  exit 0
fi
test -d "`$world" && test ! -L "`$world" || fail unsafe-live-world 28
links=`$(find "`$world" -type l -print) || fail scan-live-world-links 29
test -z "`$links" || fail live-world-has-symlink 30
tar -cf "`$snapshot_part" -C "`$saves" "`$world_name" || fail archive-original-world 30
test -f "`$snapshot_part" && test ! -L "`$snapshot_part" || fail snapshot-stage-invalid 31
tar -tf "`$snapshot_part" | grep -Fqx "`$world_name/level.dat" || fail snapshot-missing-level 32
sha=`$(sha256sum "`$snapshot_part" | awk '{print toupper(`$1)}')
echo "`$sha" | grep -Eq '^[0-9A-F]{64}$' || fail snapshot-hash-invalid 33
printf '%s\n' "`$sha" > "`$digest_part" || fail write-snapshot-digest 34
mv "`$snapshot_part" "`$snapshot" || fail publish-snapshot 35
mv "`$digest_part" "`$digest" || fail publish-snapshot-digest 36
assert_stopped
echo "QC_RC8_SNAPSHOT_CREATED:SNAPSHOT:`$sha"
"@
    $result = Invoke-ShellScript $command -Write `
        -Context 'create-original-snapshot'
    $rows = @(Get-NonBlankRows ([string[]]$result.Lines))
    Require ($rows.Count -eq 1 -and
        ($rows[0] -ceq 'QC_RC8_SNAPSHOT_CREATED:ABSENT_MARKER' -or
         $rows[0] -cmatch '^QC_RC8_SNAPSHOT_CREATED:SNAPSHOT:[0-9A-F]{64}$')) `
        'The original-world snapshot creation receipt was invalid.'
}

function Ensure-MasterCache([Parameter(Mandatory)] $Paths, [Parameter(Mandatory)][string] $RunId) {
    $current = Read-RemoteSha256 $Paths.MasterCache -AllowMissing
    if ($null -ne $current) {
        Require ($current -ceq $script:MasterSha256) `
            'The tool-owned master cache exists with an unexpected hash.'
        return 'VERIFIED'
    }
    $stateRoot = Invoke-Shell @('test', '-d', $Paths.StateRoot) `
        -Context 'verify-master-cache-root'
    $null = $stateRoot
    if ($script:AccessMode -ceq 'Root') {
        Require ($RunId -cmatch '^[0-9a-f]{32}$') 'The cache transaction run ID was invalid.'
        $stage = "/data/local/tmp/qc-rc8-route-master-$RunId.tar"
        $qStage = ConvertTo-ShLiteral $stage
        $qCache = ConvertTo-ShLiteral $Paths.MasterCache
        $qLab = ConvertTo-ShLiteral $script:Package
        $qStable = ConvertTo-ShLiteral $script:StablePackage
        $qExpected = ConvertTo-ShLiteral $script:MasterSha256
        $stageProbe = Invoke-Adb @('-s', $script:Device, 'shell', 'test', '!', '-e', $stage) `
            -AllowFailure -Context 'verify-root-upload-stage-absent'
        Require ($stageProbe.ExitCode -eq 0 -and
                @(Get-NonBlankRows ([string[]]$stageProbe.Lines)).Count -eq 0) `
            'The bounded root upload stage already exists.'
        $push = Invoke-Adb @('-s', $script:Device, 'push', $script:MasterTar, $stage) `
            -Write -Context 'push-master-cache-stage'
        Require ($push.ExitCode -eq 0) 'The fixed world master upload failed.'
        try {
            Require ((Read-RemoteSha256 $stage) -ceq $script:MasterSha256) `
                'The uploaded world master hash was not exact.'
            $publish = @"
# QC_RC8_MASTER_CACHE_PUBLISH
set -u
stage=$qStage
cache=$qCache
lab=$qLab
stable=$qStable
expected=$qExpected
fail() { echo "QC_RC8_RESET_FAIL:`$1" >&2; exit "`$2"; }
for package in "`$lab" "`$stable"; do
  pids=`$(pidof "`$package" 2>&1); code=`$?
  if [ "`$code" -eq 1 ] && [ -z "`$pids" ]; then continue; fi
  fail process-state-changed 21
done
test -f "`$stage" && test ! -L "`$stage" || fail upload-stage-invalid 41
test ! -e "`$cache" && test ! -L "`$cache" || fail cache-destination-occupied 42
actual=`$(sha256sum "`$stage" | awk '{print toupper(`$1)}')
test "`$actual" = "`$expected" || fail upload-stage-hash 43
mv "`$stage" "`$cache" || fail publish-master-cache 44
published=`$(sha256sum "`$cache" | awk '{print toupper(`$1)}')
test "`$published" = "`$expected" || fail published-master-cache-hash 45
echo "QC_RC8_MASTER_CACHE_PUBLISHED:`$published"
"@
            $result = Invoke-ShellScript $publish -Write -Context 'publish-master-cache'
            $rows = @(Get-NonBlankRows ([string[]]$result.Lines))
            Require ($rows.Count -eq 1 -and
                    $rows[0] -ceq "QC_RC8_MASTER_CACHE_PUBLISHED:$($script:MasterSha256)") `
                'The root master-cache publication receipt was invalid.'
        } finally {
            $cleanup = @"
stage=$qStage
if [ ! -e "`$stage" ]; then exit 0; fi
test -f "`$stage" && test ! -L "`$stage" || exit 46
rm -f -- "`$stage"
"@
            $cleanupResult = Invoke-RootShellScript -Script $cleanup -Write -AllowFailure `
                -Context 'cleanup-root-upload-stage'
            Require ($cleanupResult.ExitCode -eq 0) `
                'The bounded root upload stage could not be cleaned safely.'
        }
        Require ((Read-RemoteSha256 $Paths.MasterCache) -ceq $script:MasterSha256) `
            'The published world master hash was not exact.'
        return 'CREATED'
    }
    $stage = "$($Paths.MasterCache).part-$RunId"
    $push = Invoke-Adb @('-s', $script:Device, 'push', $script:MasterTar, $stage) `
        -Write -Context 'push-master-cache-stage'
    Require ($push.ExitCode -eq 0) 'The fixed world master upload failed.'
    Require ((Read-RemoteSha256 $stage) -ceq $script:MasterSha256) `
        'The uploaded world master hash was not exact.'
    $move = Invoke-Shell @('mv', $stage, $Paths.MasterCache) -Write `
        -Context 'publish-master-cache'
    $null = $move
    Require ((Read-RemoteSha256 $Paths.MasterCache) -ceq $script:MasterSha256) `
        'The published world master hash was not exact.'
    'CREATED'
}

function Invoke-WorldReset([Parameter(Mandatory)] $Paths, [Parameter(Mandatory)][string] $RunId) {
    $stageRoot = "$($Paths.Saves)/.rc8-world-stage-$RunId"
    $rollback = "$($Paths.StateRoot)/rollback-$RunId"
    $qStageRoot = ConvertTo-ShLiteral $stageRoot
    $qMasterDirectory = ConvertTo-ShLiteral $script:MasterDirectory
    $qMaster = ConvertTo-ShLiteral $Paths.MasterCache
    $qSaves = ConvertTo-ShLiteral $Paths.Saves
    $qWorld = ConvertTo-ShLiteral $Paths.World
    $qRollback = ConvertTo-ShLiteral $rollback
    $qState = ConvertTo-ShLiteral $Paths.StateRoot
    $qFiles = ConvertTo-ShLiteral $Paths.Files
    $qLab = ConvertTo-ShLiteral $script:Package
    $qStable = ConvertTo-ShLiteral $script:StablePackage
    $qMasterSha = ConvertTo-ShLiteral $script:MasterSha256
    $qLevelSha = ConvertTo-ShLiteral $script:MasterLevelDatSha256
    $command = @"
# QC_RC8_WORLD_STAGE_AND_SWAP
set -u
stage_root=$qStageRoot
master_dir=$qMasterDirectory
master=$qMaster
saves=$qSaves
world=$qWorld
rollback=$qRollback
state=$qState
files=$qFiles
lab=$qLab
stable=$qStable
expected_master=$qMasterSha
expected_level=$qLevelSha
fail() { echo "QC_RC8_RESET_FAIL:`$1" >&2; exit "`$2"; }
assert_stopped() {
  for package in "`$lab" "`$stable"; do
    pids=`$(pidof "`$package" 2>&1); code=`$?
    if [ "`$code" -eq 1 ] && [ -z "`$pids" ]; then continue; fi
    fail process-state-changed 41
  done
}
assert_stopped
test -d "`$saves" && test ! -L "`$saves" || fail unsafe-saves-root 42
resolved_saves=`$(realpath "`$saves") || fail resolve-saves-root 42
test "`$resolved_saves" = "`$saves" || fail escaped-saves-root 42
test -d "`$state" && test ! -L "`$state" || fail unsafe-state-root 42
test -f "`$master" && test ! -L "`$master" || fail master-cache-invalid 42
master_sha=`$(sha256sum "`$master" | awk '{print toupper(`$1)}')
test "`$master_sha" = "`$expected_master" || fail master-cache-hash 43
test ! -e "`$stage_root" && test ! -L "`$stage_root" || fail stage-path-exists 44
test ! -e "`$rollback" && test ! -L "`$rollback" || fail rollback-path-exists 44
mkdir "`$stage_root" || fail create-world-stage 45
tar -xf "`$master" -C "`$stage_root" || fail extract-world-master 46
staged="`$stage_root/`$master_dir"
test -d "`$staged" && test ! -L "`$staged" || fail staged-world-invalid 47
links=`$(find "`$staged" -type l -print) || fail scan-staged-world-links 48
test -z "`$links" || fail staged-world-has-symlink 49
file_rows=`$(find "`$staged" -type f -print) || fail count-staged-files 49
directory_rows=`$(find "`$staged" -type d -print) || fail count-staged-directories 50
file_count=`$(printf '%s\n' "`$file_rows" | wc -l | tr -d ' ')
directory_count=`$(printf '%s\n' "`$directory_rows" | wc -l | tr -d ' ')
test "`$file_count" = "$($script:MasterFileCount)" || fail staged-file-count 49
test "`$directory_count" = "$($script:MasterDirectoryCount)" || fail staged-directory-count 50
level_sha=`$(sha256sum "`$staged/level.dat" | awk '{print toupper(`$1)}')
test "`$level_sha" = "`$expected_level" || fail staged-level-hash 51
access_group=`$(stat -c %g "`$files") || fail files-group 52
echo "`$access_group" | grep -Eq '^[0-9]+$' || fail files-group-invalid 53
chgrp -R "`$access_group" "`$staged" || fail stage-group 54
find "`$staged" -type d -exec chmod 2770 {} + || fail stage-directory-mode 55
find "`$staged" -type f -exec chmod 660 {} + || fail stage-file-mode 56
test -r "`$staged/level.dat" || fail staged-level-unreadable 57
assert_stopped
had_world=0
rollback_level=''
if [ -e "`$world" ] || [ -L "`$world" ]; then
  test -d "`$world" && test ! -L "`$world" && test -f "`$world/level.dat" || fail live-world-invalid 58
  live_links=`$(find "`$world" -type l -print) || fail scan-live-world-links 58
  test -z "`$live_links" || fail live-world-has-symlink 58
  rollback_level=`$(sha256sum "`$world/level.dat" | awk '{print toupper(`$1)}')
  echo "`$rollback_level" | grep -Eq '^[0-9A-F]{64}$' || fail live-world-level-hash 58
  mv "`$world" "`$rollback" || fail move-live-to-rollback 59
  test -d "`$rollback" && test ! -L "`$rollback" || fail rollback-after-move-invalid 59
  rollback_check=`$(sha256sum "`$rollback/level.dat" | awk '{print toupper(`$1)}')
  test "`$rollback_check" = "`$rollback_level" || fail rollback-after-move-hash 59
  had_world=1
fi
restore_rollback_or_fail() {
  restore_code="`$1"
  test "`$had_world" -eq 1 || fail rollback-not-available "`$restore_code"
  test ! -e "`$world" && test ! -L "`$world" || fail rollback-destination-occupied "`$restore_code"
  test -d "`$rollback" && test ! -L "`$rollback" || fail rollback-source-invalid "`$restore_code"
  rollback_links=`$(find "`$rollback" -type l -print) || fail rollback-source-link-scan "`$restore_code"
  test -z "`$rollback_links" || fail rollback-source-has-symlink "`$restore_code"
  rollback_check=`$(sha256sum "`$rollback/level.dat" | awk '{print toupper(`$1)}')
  test "`$rollback_check" = "`$rollback_level" || fail rollback-source-hash "`$restore_code"
  mv "`$rollback" "`$world" || fail rollback-restore-move "`$restore_code"
  test -d "`$world" && test ! -L "`$world" || fail rollback-restored-layout "`$restore_code"
  restored_links=`$(find "`$world" -type l -print) || fail rollback-restored-link-scan "`$restore_code"
  test -z "`$restored_links" || fail rollback-restored-has-symlink "`$restore_code"
  restored_level=`$(sha256sum "`$world/level.dat" | awk '{print toupper(`$1)}')
  test "`$restored_level" = "`$rollback_level" || fail rollback-restored-hash "`$restore_code"
}
if ! mv "`$staged" "`$world"; then
  if [ "`$had_world" -eq 1 ]; then restore_rollback_or_fail 64; fi
  fail promote-staged-world 60
fi
level_sha=`$(sha256sum "`$world/level.dat" | awk '{print toupper(`$1)}')
if [ "`$level_sha" != "`$expected_level" ]; then
  # The destination is occupied by data that failed validation. Do not delete,
  # quarantine, or overwrite an unknown target; preserve rollback for review.
  fail promoted-level-hash 61
fi
rmdir "`$stage_root" || fail remove-empty-stage-root 62
assert_stopped
if [ "`$had_world" -eq 1 ]; then
  test -d "`$rollback" && test ! -L "`$rollback" || fail cleanup-rollback-invalid 63
  rollback_links=`$(find "`$rollback" -type l -print) || fail cleanup-rollback-link-scan 63
  test -z "`$rollback_links" || fail cleanup-rollback-has-symlink 63
  rollback_check=`$(sha256sum "`$rollback/level.dat" | awk '{print toupper(`$1)}')
  test "`$rollback_check" = "`$rollback_level" || fail cleanup-rollback-hash 63
  rm -rf -- "`$rollback" || fail remove-transaction-rollback 63
fi
echo "QC_RC8_WORLD_RESET:PASS:`$level_sha:`$file_count:`$directory_count"
"@
    $result = Invoke-ShellScript $command -Write `
        -Context 'activate-fixed-world-master'
    $rows = @(Get-NonBlankRows ([string[]]$result.Lines))
    $expected = "QC_RC8_WORLD_RESET:PASS:$($script:MasterLevelDatSha256):$($script:MasterFileCount):$($script:MasterDirectoryCount)"
    Require ($rows.Count -eq 1 -and $rows[0] -ceq $expected) `
        'The fixed-world activation receipt was invalid.'
}

function Invoke-SelfTest {
    $archive = Assert-HostContract
    $blankRows = @(Get-NonBlankRows @('', '  ', 'device', "`t"))
    Require ($blankRows.Count -eq 1 -and $blankRows[0] -ceq 'device') `
        'Blank ADB output rows were not normalized safely.'
    $posixScript = ConvertTo-PosixScript "first`r`nsecond`rthird`n"
    Require ($posixScript -ceq "first`nsecond`nthird`n" -and
            -not $posixScript.Contains("`r", [StringComparison]::Ordinal)) `
        'Windows line endings were not normalized before remote sh -c execution.'
    $quotedPath = ConvertTo-ShLiteral "/safe/path/with'quote"
    $joined = Join-PosixCommand @('sha256sum', "/safe/path/with'quote")
    Require ($joined -ceq ((ConvertTo-ShLiteral 'sha256sum') + ' ' + $quotedPath)) `
        'Root simple-command quoting drifted.'
    $accessFixture = [pscustomobject]@{
        World = '/storage/emulated/0/Android/data/lab/files/saves/FPS-Stress-Test'
    }
    $accessProbe = Get-WorldAccessProbeScript $accessFixture
    Require ($accessProbe.Contains('QC_RC8_WORLD_ACCESS_PROBE',
                [StringComparison]::Ordinal) -and
            $accessProbe.Contains((ConvertTo-ShLiteral $accessFixture.World),
                [StringComparison]::Ordinal) -and
            $accessProbe.Contains('sha256sum "$world/level.dat"',
                [StringComparison]::Ordinal)) `
        'The bounded world-access probe drifted.'
    Require (Test-ExactWorldAccessResult ([pscustomobject]@{
            ExitCode = 0; Lines = @('QC_RC8_WORLD_ACCESS_OK:PRESENT')
        })) 'A valid world-access result was rejected.'
    Require (-not (Test-ExactWorldAccessResult ([pscustomobject]@{
            ExitCode = 11; Lines = @()
        }))) 'A denied world-access result was accepted.'
    $blankIdentity = Read-PackageIdentity @(
        '', "  versionCode=$($script:VersionCode) minSdk=29 targetSdk=34", ' ',
        "  versionName=$($script:VersionName)", '')
    Require ($blankIdentity.VersionCode -eq $script:VersionCode -and
            $blankIdentity.VersionName -ceq $script:VersionName) `
        'Blank dumpsys rows were not tolerated around the exact package identity.'
    $blankBase = Read-BaseApkPath @(
        '', 'package:/data/app/~~token/com.qcxr.qcxr.canary262-token/base.apk', '')
    Require ($blankBase -ceq
            '/data/app/~~token/com.qcxr.qcxr.canary262-token/base.apk') `
        'Blank pm-path rows were not tolerated around the exact Lab APK path.'
    $safe = Assert-SafeArchiveEntries -Entries @(
        'FPS-Stress-Test/', 'FPS-Stress-Test/level.dat') -ExpectedRoot 'FPS-Stress-Test'
    Require ($safe.Entries -eq 2) 'The safe archive parser fixture failed.'
    Require ((Assert-RegularArchiveEntryTypes -Rows @(
            'drwxr-xr-x 0 owner group 0 date FPS-Stress-Test/',
            '-rw-r--r-- 0 owner group 1 date FPS-Stress-Test/level.dat')) -eq 2) `
        'The regular archive type fixture failed.'
    Require (Test-Throws {
        $null = Assert-RegularArchiveEntryTypes -Rows @(
            'drwxr-xr-x 0 owner group 0 date FPS-Stress-Test/',
            'lrwxrwxrwx 0 owner group 0 date FPS-Stress-Test/link')
    }) 'A symbolic-link archive fixture was accepted.'
    foreach ($bad in @(
        @('/absolute', 'FPS-Stress-Test/level.dat'),
        @('FPS-Stress-Test/', 'FPS-Stress-Test/../escape', 'FPS-Stress-Test/level.dat'),
        @('Wrong/', 'Wrong/level.dat'),
        @('FPS-Stress-Test/', 'FPS-Stress-Test/no-level'),
        @('FPS-Stress-Test/', 'FPS-Stress-Test/level.dat', 'FPS-Stress-Test/level.dat')
    )) {
        Require (Test-Throws {
            $null = Assert-SafeArchiveEntries -Entries ([string[]]$bad) `
                -ExpectedRoot 'FPS-Stress-Test'
        }) 'An unsafe archive parser fixture was accepted.'
    }
    $records = @(Get-AuthorizedDeviceRecords @(
        'List of devices attached',
        'USB123 device product:eureka model:Quest_3 transport_id:1',
        '192.0.2.10:5555 device product:eureka model:Quest_3 transport_id:2',
        'OFFLINE offline'))
    Require ($records.Count -eq 2 -and $records[0].Serial -ceq 'USB123' -and
            $records[1].Serial -ceq '192.0.2.10:5555') `
        'Authorized ADB endpoint parsing failed.'
    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $forbiddenClear = 'pm' + ' clear'
    $forbiddenUninstall = 'unin' + 'stall'
    Require (-not $source.Contains($forbiddenClear) -and
            -not $source.Contains($forbiddenUninstall)) `
        'A forbidden package/data mutation command exists in the reset tool.'
    $forbiddenForceStop = 'am force' + '-stop'
    Require (-not $source.Contains($forbiddenForceStop)) `
        'The reset tool must not stop either app itself.'
    $forbiddenFindNoFollow = 'find' + ' -P'
    Require (-not $source.Contains($forbiddenFindNoFollow)) `
        'The reset tool uses an unsupported GNU find no-follow flag.'
    Require ($source.Contains('$saves = Read-OneCanonicalPath "$game/saves"') -and
            $source.Contains('test "`$resolved_saves" = "`$saves"')) `
        'The canonical saves-ancestor fence is absent.'
    $rootArgvContract = "-Arguments @('-s', `$script:Device, 'shell', `$script:RootSuPath, '-c', 'sh')"
    $forbiddenRootQuoted = "'su" + " -c '"
    Require ($source.Contains($rootArgvContract) -and
            $source.Contains('-StandardInput `$normalizedScript') -and
            -not $source.Contains($forbiddenRootQuoted)) `
        'The root path must stream the script through stdin instead of fragile su quoting.'
    $unverifiedRollback = '||' + ' true'
    $quarantineVariable = 'failed_' + 'promoted'
    Require ($source.Contains('restore_rollback_or_fail()') -and
            $source.Contains('rollback-destination-occupied') -and
            $source.Contains('rollback-source-hash') -and
            $source.Contains('rollback-restored-hash') -and
            -not $source.Contains($unverifiedRollback) -and
            -not $source.Contains($quarantineVariable)) `
        'The verified fail-closed rollback contract drifted.'
    $selfTestReceiptDirectory = 'selftest-' + [Guid]::NewGuid().ToString('N')
    $receiptFixture = Join-Path $script:PerformanceArtifactRoot `
        "$selfTestReceiptDirectory\reset-01.json"
    Require ((Resolve-PerformanceReceiptPath $receiptFixture) -ceq
            (Get-CanonicalHostPath $receiptFixture)) `
        'The bounded performance receipt path was rejected.'
    Require (Test-Throws {
        Resolve-PerformanceReceiptPath (Join-Path $script:RepoRoot 'reset-01.json') |
            Out-Null
    }) 'A reset receipt outside the performance artifact root was accepted.'
    Require (Test-Throws {
        Resolve-PerformanceReceiptPath (Join-Path $script:PerformanceArtifactRoot `
            "$selfTestReceiptDirectory\wrong.json") | Out-Null
    }) 'A reset receipt with a non-campaign name was accepted.'
    Require ($source.Contains('resetProducerSha256 = $producerSha256') -and
            $source.Contains('resetRunId = $runId') -and
            $source.Contains('Read-RemoteSha256 $script:LexicalCanaryMarker -AllowMissing') -and
            $source.Contains('Write-JsonAtomic $script:ResolvedOutputJson $receipt')) `
        'The durable reset receipt contract drifted.'
    Require ($script:DeviceInvocations -eq 0 -and $script:DeviceWrites -eq 0 -and
            $script:HostWrites -eq 0) `
        'SelfTest contacted a device or wrote Host evidence.'
    [pscustomobject][ordered]@{
        Result = 'PASS'
        Package = $script:Package
        StablePackageDenied = $script:StablePackage
        Profile = $script:Profile
        World = $script:World
        MasterSha256 = $script:MasterSha256
        MasterEntries = $archive.Entries
        ExplicitSerialSupportsMultipleEndpoints = $true
        ResetRequiresExplicitUsbSerial = $true
        CanonicalSavesAncestor = $true
        VerifiedRollbackRestore = $true
        SnapshotContract = 'immutable first-world tar+sha256 or exact absent marker'
        DurableResetReceipt = $true
        DeviceInvocations = 0
        DeviceWrites = 0
        HostWrites = 0
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    exit 0
}

$null = Assert-HostContract
Require $AllowDeviceRead.IsPresent 'Status/Reset requires -AllowDeviceRead.'
Require $ConfirmExactRc8Lab.IsPresent 'Status/Reset requires -ConfirmExactRc8Lab.'
if ($Action -eq 'Reset') {
    Require $AllowDeviceWrite.IsPresent 'Reset requires -AllowDeviceWrite.'
    Require $AllowHostOutput.IsPresent `
        'Reset requires -AllowHostOutput for its mandatory evidence receipt.'
    Require ($Serial -cne 'auto' -and -not $Serial.Contains(':')) `
        'Reset requires an explicitly supplied USB ADB serial (not auto or Wi-Fi).'
    $script:ResolvedOutputJson = Resolve-PerformanceReceiptPath $OutputJson
} else {
    Require (-not $AllowDeviceWrite.IsPresent) 'Status rejects an unused write authorization.'
    Require ([string]::IsNullOrWhiteSpace($OutputJson) -and
            -not $AllowHostOutput.IsPresent) `
        'Status rejects Host-output authorization.'
}

function Invoke-SelectedDeviceAction {
    Resolve-Device
    if ($Action -eq 'Reset') { Assert-SelectedUsbSerial }
    $paths = Assert-ExactRc8Identity
    if ($Action -eq 'Reset') { Assert-LabStopped }
    $accessMode = Select-WorldAccessMode $paths
    Assert-StableStopped
    if ($Action -eq 'Reset') { Assert-LabStopped }
    $worldState = Get-WorldState $paths
    $snapshotState = Get-SnapshotState $paths

    if ($Action -eq 'Status') {
        return [pscustomobject][ordered]@{
            Result = 'STATUS'
            Package = $script:Package
            StablePackageDenied = $script:StablePackage
            Profile = $script:Profile
            World = $script:World
            ExactRc8Identity = $true
            StableStopped = $true
            LabRunning = ($null -ne (Read-PidState $script:Package))
            WorldState = $worldState.State
            WorldLevelDatMatchesMaster = ($worldState.State -ceq 'PRESENT' -and
                $worldState.LevelDatSha256 -ceq $script:MasterLevelDatSha256)
            OriginalSnapshotState = $snapshotState.State
            OriginalSnapshotSha256 = $snapshotState.Sha256
            MasterSha256 = $script:MasterSha256
            AccessMode = $accessMode
            RootUsed = ($accessMode -ceq 'Root')
            ReadOnly = $true
            DeviceWrites = 0
            SerialPersisted = $false
        }
    }

    Assert-LabStopped
    $preflightCacheSha = Read-RemoteSha256 $paths.MasterCache -AllowMissing
    Require ($null -eq $preflightCacheSha -or
            $preflightCacheSha -ceq $script:MasterSha256) `
        'The tool-owned master cache exists with an unexpected hash.'
    $runId = [Guid]::NewGuid().ToString('N')
    if ($snapshotState.State -ceq 'UNINITIALIZED') {
        New-OriginalSnapshot -Paths $paths -RunId $runId
        $snapshotState = Get-SnapshotState $paths
    }
    Require ($snapshotState.State -cin @('SNAPSHOT', 'ABSENT_MARKER')) `
        'The immutable original-world snapshot contract was not established.'
    Assert-StableStopped
    Assert-LabStopped
    $cacheResult = Ensure-MasterCache -Paths $paths -RunId $runId
    Assert-StableStopped
    Assert-LabStopped
    Invoke-WorldReset -Paths $paths -RunId $runId
    $after = Get-WorldState $paths
    Require ($after.State -ceq 'PRESENT' -and
            $after.LevelDatSha256 -ceq $script:MasterLevelDatSha256) `
        'The activated benchmark world did not match the fixed master level.dat.'
    Assert-StableStopped
    Assert-LabStopped

    $completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $producerSha256 = Get-NormalizedTextSha256 $PSCommandPath
    $deviceBindingSha256 = Get-TextSha256 (
        "rc8-world-reset-v1`nserial=$($script:Device)`nrunId=$runId`nmaster=$($script:MasterSha256)")
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC8_INPUT_PERFORMANCE_WORLD_RESET'
        result = 'RESET'
        resetRunId = $runId
        completedAtUtc = $completedAtUtc
        resetProducerSha256 = $producerSha256
        deviceBindingSha256 = $deviceBindingSha256
        package = $script:Package
        profile = $script:Profile
        world = $script:World
        exactRc8Identity = $true
        apkSha256 = $script:ApkSha256
        coreSha256 = $script:CoreSha256
        veqSha256 = $script:VeqSha256
        masterSha256 = $script:MasterSha256
        worldLevelDatSha256 = $after.LevelDatSha256
        worldResetActivationReceipt =
            "QC_RC8_WORLD_RESET:PASS:$($script:MasterLevelDatSha256):$($script:MasterFileCount):$($script:MasterDirectoryCount)"
        originalSnapshotState = $snapshotState.State
        originalSnapshotSha256 = $snapshotState.Sha256
        masterCache = $cacheResult
        stableStoppedAtAllFences = $true
        labStoppedAtAllFences = $true
        backupVerifiedBeforeSwap = $true
        canaryMarkerAbsent = $true
        usbTransportConfirmed = $true
        accessMode = $accessMode
        rootUsed = ($accessMode -ceq 'Root')
        serialPersisted = $false
        deviceWrites = $script:DeviceWrites
    }
    Write-JsonAtomic $script:ResolvedOutputJson $receipt
    $receiptSha256 = Get-FileSha256 $script:ResolvedOutputJson
    [pscustomobject][ordered]@{
        Result = 'RESET'
        Package = $script:Package
        StablePackageDenied = $script:StablePackage
        Profile = $script:Profile
        World = $script:World
        ExactRc8Identity = $true
        MasterSha256 = $script:MasterSha256
        AccessMode = $accessMode
        RootUsed = ($accessMode -ceq 'Root')
        MasterCache = $cacheResult
        WorldLevelDatSha256 = $after.LevelDatSha256
        OriginalSnapshotState = $snapshotState.State
        OriginalSnapshotSha256 = $snapshotState.Sha256
        BackupVerifiedBeforeSwap = $true
        UsbTransportConfirmed = $true
        StableTouched = $false
        AccountTouched = $false
        ModsConfigOrResourcePacksTouched = $false
        SerialPersisted = $false
        DeviceWrites = $script:DeviceWrites
        ResetRunId = $runId
        CompletedAtUtc = $completedAtUtc
        ResetProducerSha256 = $producerSha256
        DeviceBindingSha256 = $deviceBindingSha256
        ReceiptFileName = [IO.Path]::GetFileName($script:ResolvedOutputJson)
        ReceiptSha256 = $receiptSha256
        HostWrites = $script:HostWrites
    }
}

$lease = Enter-TransactionMutex
try {
    Invoke-SelectedDeviceAction
} finally {
    Exit-TransactionMutex $lease
}
