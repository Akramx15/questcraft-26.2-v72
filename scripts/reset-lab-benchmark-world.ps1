<#
.SYNOPSIS
Restores the fixed FPS-Stress-Test route master in the isolated Quest Lab app.

.DESCRIPTION
This helper is deliberately pinned to com.qcxr.qcxr.canary262, profile 26.2,
and save-folder FPS-Stress-Test. It cannot target the accepted Personal app.
Reset requires an explicit write switch and refuses to run while the Lab app
is alive. The first existing Lab world is retained as a sibling rollback;
later resets replace only the known benchmark target after staging succeeds.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Status', 'Reset')]
    [string] $Action = 'Status',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [switch] $AllowDeviceWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.canary262'
$script:ForbiddenPackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:World = 'FPS-Stress-Test'
$script:MasterDirectory = 'FPS Stress Test'
$script:ExpectedMasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:MasterTar = Join-Path $script:WorkspaceRoot 'artifacts\benchmark-worlds\gamerpotion-fps-stress-3595582\masters\visor-fps-stress-26.2-route-master.tar'
$script:Adb = $null
$script:Device = $null

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [string][char]39
    $escaped = $quote + '"' + $quote + '"' + $quote
    return $quote + $Value.Replace($quote, $escaped) + $quote
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

function Get-AdbFailureClass([string[]] $Rows) {
    $joined = ($Rows -join "`n")
    if ($joined -match 'QC_RESET_FAIL:(?<step>[a-z0-9-]+)') {
        return "reset-$($Matches.step)"
    }
    if ($joined -match '(?i)chgrp') { return 'chgrp-command' }
    if ($joined -match '(?i)chmod') { return 'chmod-command' }
    if ($joined -match '(?i)find:') { return 'find-command' }
    if ($joined -match '(?i)stat:') { return 'stat-command' }
    if ($joined -match '(?i)unbound variable|parameter not set') { return 'unset-shell-variable' }
    if ($joined -match '(?i)syntax error|unexpected') { return 'shell-syntax' }
    if ($joined -match '(?i)permission denied|operation not permitted') { return 'permission-denied' }
    if ($joined -match '(?i)no such file|not found') { return 'missing-path-or-command' }
    if ($joined -match '(?i)device offline|device not found|closed|connection reset') { return 'device-transport' }
    if ([string]::IsNullOrWhiteSpace($joined)) { return 'no-device-output' }
    return 'device-command'
}

function Invoke-Adb(
    [string[]] $Arguments,
    [switch] $AllowFailure,
    [string] $Context = 'adb-command'
) {
    $rows = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        $failureClass = Get-AdbFailureClass -Rows $rows
        throw "ADB step '$Context' failed with exit code $code ($failureClass); raw device output was suppressed."
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $rows }
}

function Resolve-Device {
    $script:Adb = Resolve-Adb
    $rows = @(Invoke-Adb @('devices') -Context 'list-devices').Lines
    $devices = @($rows | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { $Matches.serial }
    })
    Require ($devices.Count -eq 1) 'Exactly one authorized ADB device is required.'
    if ($Serial -ne 'auto') {
        Require ([string]$devices[0] -eq $Serial) 'The requested serial is not the only attached device.'
    }
    $script:Device = [string]$devices[0]
}

function Invoke-Shell(
    [Parameter(Mandatory)][string] $Command,
    [switch] $AllowFailure,
    [string] $Context = 'device-shell'
) {
    return Invoke-Adb @('-s', $script:Device, 'shell', $Command) -AllowFailure:$AllowFailure -Context $Context
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
    Require ($ExitCode -eq 0) "Could not prove the PID state for $Package (exit $ExitCode)."
    $match = [regex]::Match($text, '^\s*(?<pid>[1-9][0-9]*)\s*$')
    Require $match.Success "PID response for $Package was not exactly one positive integer."
    $pidValue = [int64]::Parse($match.Groups['pid'].Value, [Globalization.CultureInfo]::InvariantCulture)
    Require ($pidValue -le [int]::MaxValue) "PID response for $Package was outside the positive Int32 range."
    return [int]$pidValue
}

function Get-ExactLabPid([switch] $AllowMissing, [string] $Context = 'probe-lab-pid') {
    $probe = Invoke-Shell "pidof $(ConvertTo-ShLiteral $script:Package)" -AllowFailure -Context $Context
    return Read-ExactPidProbe -ExitCode $probe.ExitCode -Lines @($probe.Lines) `
            -AllowMissing:$AllowMissing -Package $script:Package
}

function Get-MasterContract {
    Require (Test-Path -LiteralPath $script:MasterTar -PathType Leaf) 'The fixed route-master tar is missing.'
    $actual = (Get-FileHash -LiteralPath $script:MasterTar -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($actual -eq $script:ExpectedMasterSha256) 'The route-master tar hash changed.'
    $entries = @(& tar -tf $script:MasterTar)
    Require ($LASTEXITCODE -eq 0) 'Could not list the route-master tar.'
    Require ($entries.Count -gt 10) 'The route-master tar is unexpectedly small.'
    foreach ($entry in $entries) {
        Require (-not [string]::IsNullOrWhiteSpace($entry)) 'The route-master tar contains an empty entry.'
        Require (-not $entry.StartsWith('/') -and -not $entry.StartsWith('\')) 'The route-master tar contains an absolute path.'
        $parts = @($entry.Replace('\', '/').Split('/') | Where-Object { $_ })
        Require (@($parts | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -eq 0) 'The route-master tar contains path traversal.'
        Require ($parts[0] -ceq $script:MasterDirectory) 'The route-master tar has an unexpected top-level directory.'
    }
    Require ($entries -contains "$script:MasterDirectory/level.dat") 'The route-master tar has no level.dat.'
    return [pscustomobject]@{ Sha256 = $actual; Entries = $entries.Count; Path = $script:MasterTar }
}

function Get-RemotePaths {
    $lexicalFiles = "/sdcard/Android/data/$script:Package/files"
    $lexicalSaves = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/saves"
    Require (-not $lexicalSaves.Contains($script:ForbiddenPackage)) 'Forbidden package appeared in the Lab path.'
    $resolved = Invoke-Shell "realpath $(ConvertTo-ShLiteral $lexicalSaves)" -Context 'resolve-lab-saves-path'
    $rows = @($resolved.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Require ($rows.Count -eq 1) 'The Lab saves path could not be resolved unambiguously.'
    $saves = [string]$rows[0]
    $suffix = "/Android/data/$script:Package/files/instances/$script:Profile/saves"
    Require ($saves.EndsWith($suffix, [StringComparison]::Ordinal)) 'The canonical saves path escaped the fixed Lab package/profile.'
    return [pscustomobject]@{
        Files = $saves.Substring(0, $saves.Length - "/instances/$script:Profile/saves".Length)
        Saves = $saves
        World = "$saves/$script:World"
        Original = "$saves/.v69-route-original"
        MasterCache = $saves.Substring(0, $saves.Length - "/instances/$script:Profile/saves".Length) + '/.questcraft-benchmark/route-master.tar'
    }
}

function Invoke-SelfTest {
    $contract = Get-MasterContract
    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    Require ($source.Contains("`$script:Package = 'com.qcxr.qcxr.canary262'")) 'Lab package pin is absent.'
    Require ($source.Contains("`$script:ForbiddenPackage = 'com.qcxr.qcxr.dev262'")) 'Stable-package guard is absent.'
    $forbiddenDataClear = 'pm' + ' clear'
    $forbiddenUninstall = 'unin' + 'stall'
    Require (-not $source.Contains($forbiddenDataClear)) 'Data-clear command must not exist.'
    Require (-not $source.Contains($forbiddenUninstall)) 'Uninstall command must not exist.'
    $implicitErrexit = 'set -e' + 'u'
    Require (-not $source.Contains($implicitErrexit)) 'Implicit shell errexit must not control reset transactions.'
    Require ((Get-AdbFailureClass @('QC_RESET_FAIL:promote-world-stage')) -eq 'reset-promote-world-stage') 'Reset failure token classification failed.'
    Require ((Get-AdbFailureClass @('operation not permitted')) -eq 'permission-denied') 'Permission failure classification failed.'
    Require ((Get-AdbFailureClass @('device offline')) -eq 'device-transport') 'Transport failure classification failed.'
    Require ((Get-AdbFailureClass @()) -eq 'no-device-output') 'Empty failure classification failed.'
    Require ((Read-ExactPidProbe -ExitCode 0 -Lines @('1234') -Package 'synthetic.present') -eq 1234) 'One exact PID was rejected.'
    Require ($null -eq (Read-ExactPidProbe -ExitCode 1 -Lines @() -AllowMissing -Package 'synthetic.missing')) 'Exact PID absence was rejected.'
    foreach ($badProbe in @(
        @{ ExitCode = 0; Lines = @('1234 5678'); Label = 'multiple PIDs' },
        @{ ExitCode = 0; Lines = @('1234 warning'); Label = 'contaminated output' },
        @{ ExitCode = 1; Lines = @('transport error'); Label = 'failed PID probe with output' },
        @{ ExitCode = 2; Lines = @(); Label = 'unexpected PID exit code' },
        @{ ExitCode = 0; Lines = @(); Label = 'empty success' },
        @{ ExitCode = 0; Lines = @('2147483648'); Label = 'Int32 overflow' },
        @{ ExitCode = 0; Lines = @('0'); Label = 'zero PID' }
    )) {
        $rejected = $false
        try {
            $null = Read-ExactPidProbe -ExitCode $badProbe.ExitCode -Lines @($badProbe.Lines) `
                    -AllowMissing -Package 'synthetic.bad'
        } catch { $rejected = $true }
        Require $rejected "PID parser accepted $($badProbe.Label)."
    }
    $requiredResetTokens = @(
        'stat-files-group',
        'empty-files-group',
        'chgrp-stage',
        'chmod-stage-directories',
        'chmod-stage-files',
        'read-stage-level',
        'preserve-original-world',
        'remove-live-world',
        'live-world-remains',
        'promote-world-stage',
        'remove-empty-stage-root',
        'validate-live-world',
        'lab-running-during-swap',
        'ambiguous-lab-pid-during-swap'
    )
    foreach ($token in $requiredResetTokens) {
        Require ($source.Contains("QC_RESET_FAIL:$token")) "Reset failure token '$token' is absent."
    }
    return [pscustomobject]@{
        Result = 'PASS'
        Package = $script:Package
        Profile = $script:Profile
        World = $script:World
        MasterSha256 = $contract.Sha256
        FailureClassTests = 4
        PidProbeTests = 9
        ResetFailureTokens = $requiredResetTokens.Count
        DeviceTouched = $false
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    exit 0
}

$master = Get-MasterContract
Resolve-Device
$paths = Get-RemotePaths
$running = $null -ne (Get-ExactLabPid -AllowMissing -Context 'probe-lab-pid')

if ($Action -eq 'Status') {
    $probe = Invoke-Shell "if [ -f $(ConvertTo-ShLiteral ($paths.World + '/level.dat')) ]; then echo present; else echo missing; fi" -Context 'probe-benchmark-world'
    [pscustomobject]@{
        Result = 'STATUS'
        Package = $script:Package
        Running = $running
        WorldState = (($probe.Lines -join '').Trim())
        MasterSha256 = $master.Sha256
        ReadOnly = $true
    }
    exit 0
}

if (-not $AllowDeviceWrite) { throw 'Reset is disabled by default. Re-run with -AllowDeviceWrite.' }
Require (-not $running) 'Stop the Lab app before restoring its benchmark world.'

$runId = [guid]::NewGuid().ToString('N')
$remoteStage = "$($paths.Saves)/.v69-route-stage-$runId"
$remoteCacheRoot = $paths.MasterCache.Substring(0, $paths.MasterCache.LastIndexOf('/'))
$remoteCachePart = "$($paths.MasterCache).part-$runId"

try {
    $null = Invoke-Shell "mkdir -p $(ConvertTo-ShLiteral $remoteCacheRoot)" -Context 'create-master-cache-directory'
    $cacheProbe = Invoke-Shell "if [ -f $(ConvertTo-ShLiteral $paths.MasterCache) ]; then sha256sum $(ConvertTo-ShLiteral $paths.MasterCache); fi" -AllowFailure -Context 'probe-master-cache'
    $cacheHash = if ($cacheProbe.ExitCode -eq 0 -and ($cacheProbe.Lines -join ' ') -match '(?i)(?<sha>[0-9a-f]{64})') {
        $Matches.sha.ToUpperInvariant()
    } else { '' }
    if ($cacheHash -ne $script:ExpectedMasterSha256) {
        $null = Invoke-Shell "rm -f -- $(ConvertTo-ShLiteral $remoteCachePart)" -Context 'remove-stale-master-cache-part'
        $null = Invoke-Adb @('-s', $script:Device, 'push', $script:MasterTar, $remoteCachePart) -Context 'push-master-cache-part'
        $partHashResult = Invoke-Shell "sha256sum $(ConvertTo-ShLiteral $remoteCachePart)" -Context 'hash-master-cache-part'
        Require (($partHashResult.Lines -join ' ') -match '(?i)(?<sha>[0-9a-f]{64})') 'The staged route master could not be hashed.'
        Require ($Matches.sha.ToUpperInvariant() -eq $script:ExpectedMasterSha256) 'The staged route-master hash does not match.'
        $null = Invoke-Shell "mv $(ConvertTo-ShLiteral $remoteCachePart) $(ConvertTo-ShLiteral $paths.MasterCache)" -Context 'promote-master-cache'
    }

    $null = Invoke-Shell "mkdir $(ConvertTo-ShLiteral $remoteStage)" -Context 'create-world-stage'
    $extract = "tar -xf $(ConvertTo-ShLiteral $paths.MasterCache) -C $(ConvertTo-ShLiteral $remoteStage)"
    $null = Invoke-Shell $extract -Context 'extract-world-stage'
    $stagedWorld = "$remoteStage/$script:MasterDirectory"
    $null = Invoke-Shell "test -f $(ConvertTo-ShLiteral ($stagedWorld + '/level.dat'))" -Context 'validate-world-stage'

    # adb shell owns files extracted from the cached tar.  Preserve Android's
    # external-data group and grant the Lab app group read/write traversal
    # before the staged world becomes live.  Derive the group from the fixed
    # package directory instead of assuming an Android-specific numeric gid.
    $permissionFix = @"
set -u
files=$(ConvertTo-ShLiteral $paths.Files)
stage=$(ConvertTo-ShLiteral $stagedWorld)
access_group=`$(stat -c %g "`$files") || { echo QC_RESET_FAIL:stat-files-group >&2; exit 21; }
test -n "`$access_group" || { echo QC_RESET_FAIL:empty-files-group >&2; exit 22; }
chgrp -R "`$access_group" "`$stage" || { echo QC_RESET_FAIL:chgrp-stage >&2; exit 23; }
find "`$stage" -type d -exec chmod 2770 {} + || { echo QC_RESET_FAIL:chmod-stage-directories >&2; exit 24; }
find "`$stage" -type f -exec chmod 660 {} + || { echo QC_RESET_FAIL:chmod-stage-files >&2; exit 25; }
test -r "`$stage/level.dat" || { echo QC_RESET_FAIL:read-stage-level >&2; exit 26; }
"@
    $null = Invoke-Shell $permissionFix -Context 'normalize-world-stage-permissions'

    Require ($null -eq (Get-ExactLabPid -AllowMissing -Context 'recheck-lab-pid-before-world-swap')) `
            'Lab started while the benchmark reset was staged; the live world was not changed.'

    $swap = @"
set -u
package=$(ConvertTo-ShLiteral $script:Package)
world=$(ConvertTo-ShLiteral $paths.World)
original=$(ConvertTo-ShLiteral $paths.Original)
stage=$(ConvertTo-ShLiteral $stagedWorld)
stage_root=$(ConvertTo-ShLiteral $remoteStage)
assert_lab_stopped() {
  pid_output=`$(pidof "`$package" 2>&1)
  pid_code=`$?
  if [ "`$pid_code" -eq 1 ] && [ -z "`$pid_output" ]; then return 0; fi
  if [ "`$pid_code" -eq 0 ] && [ -n "`$pid_output" ]; then
    echo QC_RESET_FAIL:lab-running-during-swap >&2
    exit 37
  fi
  echo QC_RESET_FAIL:ambiguous-lab-pid-during-swap >&2
  exit 38
}
assert_lab_stopped
if [ -e "`$world" ] || [ -L "`$world" ]; then
  if [ ! -e "`$original" ] && [ ! -L "`$original" ]; then
    mv "`$world" "`$original" || { echo QC_RESET_FAIL:preserve-original-world >&2; exit 31; }
  else
    rm -rf -- "`$world" || { echo QC_RESET_FAIL:remove-live-world >&2; exit 32; }
    { [ ! -e "`$world" ] && [ ! -L "`$world" ]; } || { echo QC_RESET_FAIL:live-world-remains >&2; exit 33; }
  fi
fi
mv "`$stage" "`$world" || { echo QC_RESET_FAIL:promote-world-stage >&2; exit 34; }
rmdir "`$stage_root" || { echo QC_RESET_FAIL:remove-empty-stage-root >&2; exit 35; }
test -f "`$world/level.dat" || { echo QC_RESET_FAIL:validate-live-world >&2; exit 36; }
assert_lab_stopped
"@
    $null = Invoke-Shell $swap -Context 'activate-world-stage'
} catch {
    $null = Invoke-Shell "rm -rf -- $(ConvertTo-ShLiteral $remoteStage)" -AllowFailure -Context 'cleanup-world-stage'
    $null = Invoke-Shell "rm -f -- $(ConvertTo-ShLiteral $remoteCachePart)" -AllowFailure -Context 'cleanup-master-cache-part'
    throw
}

[pscustomobject]@{
    Result = 'RESET'
    Package = $script:Package
    Profile = $script:Profile
    World = $script:World
    OriginalPreserved = $true
    MasterSha256 = $master.Sha256
    RawLogsPersisted = $false
}
