<#
.SYNOPSIS
Safely stages Vivecraft Essentials Quest JAR-only canaries on QuestCraft 26.2.

.DESCRIPTION
Status is read-only. EnableDev disables the bundled, managed VEQ slug for the
selected launcher instance and moves the exact locked managed JAR out of the
mods directory. Deploy validates a local Fabric JAR, uploads it as a temporary
file, verifies SHA-256 on Quest, then atomically promotes it to veq-dev.jar.
Rollback swaps the active development JAR with the immediately previous one.
RestoreManaged removes the development JAR from Fabric's view, re-enables the
managed slug, and restores the exact bundled baseline when its verified backup
is available.

The script resolves gameDir from instances.json. It never reads account files,
never uninstalls or clears the application, and refuses mutations while the app
or one of its child processes is running. A read-only capability probe selects
normal shell or opt-in root before a mutation starts; a partially run compound
command is never retried through a different transport.

The exact canonical-path and residual race guarantee is documented in
scripts/quest-veq-dev-safety.md.

.EXAMPLE
.\scripts\quest-veq-dev.ps1 -Action Status

.EXAMPLE
.\scripts\quest-veq-dev.ps1 -Action EnableDev

.EXAMPLE
.\scripts\quest-veq-dev.ps1 -Action Deploy -JarPath .\VivecraftEssentialsQuest.jar

.EXAMPLE
.\scripts\quest-veq-dev.ps1 -Action Rollback

.EXAMPLE
.\scripts\quest-veq-dev.ps1 -Action RestoreManaged

.EXAMPLE
.\scripts\quest-veq-dev.ps1 -Action SelfTest
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'EnableDev', 'Deploy', 'Rollback', 'RestoreManaged', 'SelfTest')]
    [string] $Action = 'Status',

    [string] $JarPath,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [ValidatePattern('^[A-Za-z0-9._]+$')]
    [string] $Package = 'com.qcxr.qcxr.dev262',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $Profile = '26.2',

    [string] $AdbPath = 'adb',

    [switch] $AllowRootFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Slug = 'Vivecraft-Essentials-Quest'
$script:ModId = 'vivecraft_essentials_quest'
$script:DevJarName = 'veq-dev.jar'
$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:DeviceRoot = "/sdcard/Android/data/$Package/files"
$script:InstancesFile = "$script:DeviceRoot/instances.json"
$script:ExpectedManagedSha256 = $null
$script:ExpectedManagedVersion = $null
$script:TransactionMarker = 'VEQ_TRANSACTION_V2'
$script:AdbInvocationCount = 0

function ConvertTo-ShLiteral {
    param([Parameter(Mandatory)][string] $Value)

    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $escapedQuote = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $escapedQuote) + $singleQuote
}

function Normalize-AndroidAbsolutePath {
    param([Parameter(Mandatory)][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not $Path.StartsWith('/', [StringComparison]::Ordinal)) {
        throw "Android path must be absolute: $Path"
    }
    if ($Path.Contains('\') -or $Path -match '[\x00-\x1F\x7F]' -or $Path.Contains('//')) {
        throw "Android path contains an unsafe separator or control character: $Path"
    }
    $segments = @($Path.TrimEnd('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "Android path contains an unsafe traversal segment: $Path"
    }
    return '/' + ($segments -join '/')
}

function Assert-AndroidPathContained {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Roots,
        [switch] $AllowRootItself
    )

    $normalized = Normalize-AndroidAbsolutePath $Path
    foreach ($rootValue in $Roots) {
        $root = Normalize-AndroidAbsolutePath $rootValue
        if (($AllowRootItself -and $normalized -eq $root) -or
                $normalized.StartsWith($root + '/', [StringComparison]::Ordinal)) {
            return $normalized
        }
    }
    throw "Android path escapes the allowed root: $Path"
}

function Assert-SafeLeafName {
    param([Parameter(Mandatory)][string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or
            [Text.Encoding]::UTF8.GetByteCount($Name) -gt 200 -or
            $Name -eq '.' -or $Name -eq '..' -or
            $Name -match '[/\\\x00-\x1F\x7F]') {
        throw "Unsafe managed-mod leaf name: $Name"
    }
    return $Name
}

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock] $Body)

    try {
        & $Body
        return $false
    } catch {
        return $true
    }
}

function Assert-Sha256Value {
    param([Parameter(Mandatory)][string] $Value)

    $normalized = $Value.ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid SHA-256 value: $Value"
    }
    return $normalized
}

function Assert-TransactionId {
    param([Parameter(Mandatory)][string] $Value)

    if ($Value -notmatch '^[0-9a-f]{32}$') {
        throw "Invalid transaction id: $Value"
    }
    return $Value
}

function Assert-TransactionOperation {
    param([Parameter(Mandatory)][string] $Value)

    if ($Value -notmatch '^[a-z][a-z0-9-]{0,39}$') {
        throw "Invalid transaction operation: $Value"
    }
    return $Value
}

function New-TransactionId {
    return [guid]::NewGuid().ToString('N')
}

function Test-ManagedSlugValue {
    param([AllowNull()][object] $Value)

    return $Value -is [string] -and
            [string]::Equals([string]$Value, $script:Slug, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-LockContract {
    $lockPath = Join-Path $script:RepoRoot 'STACK.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "STACK.lock.json is missing at $lockPath."
    }

    $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    $lockedPackage = if ($null -ne $lock.identity.PSObject.Properties['applicationId']) {
        [string]$lock.identity.applicationId
    } elseif ($null -ne $lock.identity.PSObject.Properties['package']) {
        [string]$lock.identity.package
    } else {
        throw 'STACK.lock.json identity has no applicationId/package.'
    }
    if ($lockedPackage -ne $Package) {
        throw "The lock targets package '$lockedPackage', not '$Package'."
    }
    if ([string]$lock.addOnSlot.slug -ne $script:Slug) {
        throw "The lock does not describe the expected VEQ managed slug."
    }
    $sha = ([string]$lock.addOnSlot.sha256).ToUpperInvariant()
    if ($sha -notmatch '^[0-9A-F]{64}$') {
        throw 'STACK.lock.json does not contain a valid managed VEQ SHA-256.'
    }

    $script:ExpectedManagedSha256 = $sha
    $script:ExpectedManagedVersion = [string]$lock.addOnSlot.version
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }

    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $sdkCandidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdkCandidate -PathType Leaf) {
        return $sdkCandidate
    }

    throw 'ADB was not found. Pass -AdbPath with the full adb.exe path.'
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    $script:AdbInvocationCount++
    $output = @(& $script:ResolvedAdb @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if (($exitCode -ne 0) -and -not $AllowFailure) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "ADB failed with exit code $exitCode.`n$detail"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = @($output | ForEach-Object { [string]$_ })
    }
}

function Resolve-DeviceSerial {
    if ($Serial -ne 'auto') {
        return $Serial
    }

    $result = Invoke-Adb -Arguments @('devices')
    $devices = @(
        $result.Lines | ForEach-Object {
            if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') {
                $Matches.serial
            }
        }
    )
    if ($devices.Count -eq 0) {
        throw 'No authorized ADB device is connected.'
    }
    if ($devices.Count -gt 1) {
        throw 'More than one authorized ADB device is connected. Pass -Serial explicitly.'
    }
    return [string]$devices[0]
}

function Invoke-DeviceShell {
    param(
        [Parameter(Mandatory)][string] $Command,
        [switch] $AllowFailure
    )

    # PowerShell preserves the CRLF line endings of here-strings on Windows.
    # Android's mksh treats the trailing CR as part of an option (for example
    # `set -eu\r`), so normalize every compound shell command at the transport
    # boundary before it can reach the device.
    $normalizedCommand = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
    return Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'shell', $normalizedCommand) `
            -AllowFailure:$AllowFailure
}

function Invoke-DeviceWriteShell {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [switch] $AllowFailure
    )

    # The transport is selected before a transaction begins. Never retry a
    # compound mutation under su after the normal shell may have run part of it.
    $actualCommand = if ($Mode -eq 'Root') {
        'su -c ' + (ConvertTo-ShLiteral $Command)
    } else {
        $Command
    }
    return Invoke-DeviceShell -Command $actualCommand -AllowFailure:$AllowFailure
}

function Resolve-DeviceCanonicalPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [switch] $AllowFailure
    )

    $lexical = Normalize-AndroidAbsolutePath $Path
    $result = Invoke-DeviceShell -Command "realpath $(ConvertTo-ShLiteral $lexical)" -AllowFailure
    if ($result.ExitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }
        throw "Could not resolve canonical device path: $lexical"
    }
    $lines = @($result.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -ne 1) {
        throw "realpath returned an ambiguous result for $lexical."
    }
    return Normalize-AndroidAbsolutePath $lines[0]
}

function Resolve-WriteMode {
    param([Parameter(Mandatory)][string[]] $ProbeDirectories)

    $checks = @($ProbeDirectories | ForEach-Object {
        $probe = Normalize-AndroidAbsolutePath $_
        "test -d $(ConvertTo-ShLiteral $probe) && test -w $(ConvertTo-ShLiteral $probe)"
    })
    $testCommand = $checks -join ' && '
    $normal = Invoke-DeviceShell -Command $testCommand -AllowFailure
    if ($normal.ExitCode -eq 0) {
        return 'Normal'
    }
    if (-not $AllowRootFallback) {
        throw "The normal shell cannot write the VEQ transaction directories, and root fallback was not enabled."
    }
    $root = Invoke-DeviceShell -Command ('su -c ' + (ConvertTo-ShLiteral $testCommand)) -AllowFailure
    if ($root.ExitCode -ne 0) {
        throw 'Neither the normal shell nor the opt-in root shell can write the VEQ transaction directories.'
    }
    return 'Root'
}

function Get-AppStoppedGuardShell {
    $qPackage = ConvertTo-ShLiteral $Package
    return @"
# VEQ_APP_STOPPED_GUARD
for veq_cmdline in /proc/[0-9]*/cmdline; do
  [ -r "`$veq_cmdline" ] || continue
  # Bound procfs reads: on this Quest kernel an exited task's open cmdline can
  # otherwise yield NUL bytes indefinitely and pin a `tr` child to one core.
  veq_process=`$(head -c 512 "`$veq_cmdline" 2>/dev/null | tr '\000' '\n' | sed -n '1p' || true)
  case "`$veq_process" in
    $qPackage|${qPackage}:*) exit 75 ;;
  esac
done
"@
}

function Get-StateMutationGuardShell {
    param(
        [Parameter(Mandatory)] $State,
        [string[]] $AdditionalLeaves = @()
    )

    $gameDir = Normalize-AndroidAbsolutePath $State.GameDir
    $modsDir = Assert-AndroidPathContained -Path $State.ModsDir -Roots @($gameDir)
    $stateDir = Assert-AndroidPathContained -Path $State.StateDir -Roots @($gameDir)
    $filesDir = if ($null -ne $State.PSObject.Properties['FilesDir']) {
        Normalize-AndroidAbsolutePath $State.FilesDir
    } else {
        Normalize-AndroidAbsolutePath ((Split-Path -Parent $script:InstancesFile).Replace('\', '/'))
    }
    $instancesPath = if ($null -ne $State.PSObject.Properties['InstancesPath']) {
        Assert-AndroidPathContained -Path $State.InstancesPath -Roots @($filesDir)
    } else {
        Assert-AndroidPathContained -Path $script:InstancesFile -Roots @($filesDir)
    }
    $managedPath = Assert-AndroidPathContained -Path $State.ManagedPath -Roots @($modsDir)
    $devPath = Assert-AndroidPathContained -Path $State.DevPath -Roots @($modsDir)
    $leaves = @($instancesPath, $managedPath, $devPath) + @($AdditionalLeaves)
    $leafChecks = New-Object System.Collections.Generic.List[string]
    foreach ($leafValue in $leaves) {
        $leaf = Normalize-AndroidAbsolutePath $leafValue
        $leafChecks.Add("veq_reject_symlink $(ConvertTo-ShLiteral $leaf)")
    }
    $lockGuard = ''
    if ($null -ne $State.PSObject.Properties['MutationLockToken']) {
        $lockToken = Assert-TransactionId $State.MutationLockToken
        $lockDir = Assert-AndroidPathContained -Path $State.MutationLockPath -Roots @($stateDir)
        $lockTokenPath = Assert-AndroidPathContained `
                -Path $State.MutationLockTokenPath -Roots @($lockDir)
        $lockGuard = @"
veq_require_canonical_dir $(ConvertTo-ShLiteral $lockDir) $(ConvertTo-ShLiteral $lockDir)
test -f $(ConvertTo-ShLiteral $lockTokenPath) && test ! -L $(ConvertTo-ShLiteral $lockTokenPath) || exit 69
test "`$(cat $(ConvertTo-ShLiteral $lockTokenPath))" = $(ConvertTo-ShLiteral $lockToken) || exit 69
"@
    }

    return @"
# VEQ_CANONICAL_MUTATION_GUARD
veq_require_canonical_dir() {
  veq_guard_path="`$1"
  veq_guard_expected="`$2"
  test -d "`$veq_guard_path" || exit 66
  test ! -L "`$veq_guard_path" || exit 66
  veq_guard_actual=`$(cd "`$veq_guard_path" 2>/dev/null && pwd -P) || exit 66
  test "`$veq_guard_actual" = "`$veq_guard_expected" || exit 66
}
veq_reject_symlink() { test ! -L "`$1" || exit 67; }
veq_require_canonical_dir $(ConvertTo-ShLiteral $filesDir) $(ConvertTo-ShLiteral $filesDir)
veq_require_canonical_dir $(ConvertTo-ShLiteral $gameDir) $(ConvertTo-ShLiteral $gameDir)
veq_require_canonical_dir $(ConvertTo-ShLiteral $modsDir) $(ConvertTo-ShLiteral $modsDir)
veq_require_canonical_dir $(ConvertTo-ShLiteral $stateDir) $(ConvertTo-ShLiteral $stateDir)
case $(ConvertTo-ShLiteral $gameDir) in $(ConvertTo-ShLiteral ($filesDir + '/'))*) ;; *) exit 68 ;; esac
$lockGuard
$($leafChecks -join [Environment]::NewLine)
"@
}

function Get-TransactionPrelude {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $InstancesSha256,
        [Parameter(Mandatory)][string] $TransactionId,
        [Parameter(Mandatory)][string] $Operation,
        [string[]] $AdditionalLeaves = @()
    )

    $instancesSha = Assert-Sha256Value $InstancesSha256
    $transaction = Assert-TransactionId $TransactionId
    $operationName = Assert-TransactionOperation $Operation
    $instancesPath = if ($null -ne $State.PSObject.Properties['InstancesPath']) {
        Normalize-AndroidAbsolutePath $State.InstancesPath
    } else {
        Normalize-AndroidAbsolutePath $script:InstancesFile
    }
    $qInstances = ConvertTo-ShLiteral $instancesPath
    $qInstancesSha = ConvertTo-ShLiteral $instancesSha
    $markerValue = $script:TransactionMarker + ':' + $transaction + ':' + $operationName
    $qMarker = ConvertTo-ShLiteral $markerValue
    $commitDir = Assert-AndroidPathContained -Path "$($State.StateDir)/commits" -Roots @($State.StateDir)
    $commitPath = Assert-AndroidPathContained `
            -Path "$commitDir/$transaction-$operationName.committed" -Roots @($commitDir)
    $commitStage = Assert-AndroidPathContained -Path "$commitPath.tmp" -Roots @($commitDir)
    $guard = Get-AppStoppedGuardShell
    $pathGuard = Get-StateMutationGuardShell -State $State -AdditionalLeaves $AdditionalLeaves
    return @"
set -eu
umask 077
# $script:TransactionMarker
veq_sha() { sha256sum "`$1" | cut -d ' ' -f 1 | tr 'a-f' 'A-F'; }
$guard
$pathGuard
test "`$(veq_sha $qInstances)" = $qInstancesSha || exit 76
veq_transaction=$qMarker
veq_clear_commit() {
  test ! -L $(ConvertTo-ShLiteral $commitPath) || return 1
  test ! -L $(ConvertTo-ShLiteral $commitStage) || return 1
  rm -f $(ConvertTo-ShLiteral $commitStage) $(ConvertTo-ShLiteral $commitPath) || return 1
  test ! -e $(ConvertTo-ShLiteral $commitStage) && test ! -L $(ConvertTo-ShLiteral $commitStage) || return 1
  test ! -e $(ConvertTo-ShLiteral $commitPath) && test ! -L $(ConvertTo-ShLiteral $commitPath) || return 1
}
veq_record_commit() {
  test ! -L $(ConvertTo-ShLiteral $commitDir) || { veq_clear_commit; return 1; }
  if [ ! -e $(ConvertTo-ShLiteral $commitDir) ]; then mkdir $(ConvertTo-ShLiteral $commitDir) || { veq_clear_commit; return 1; }; fi
  test -d $(ConvertTo-ShLiteral $commitDir) && test ! -L $(ConvertTo-ShLiteral $commitDir) || { veq_clear_commit; return 1; }
  test "`$(cd $(ConvertTo-ShLiteral $commitDir) 2>/dev/null && pwd -P)" = $(ConvertTo-ShLiteral $commitDir) || { veq_clear_commit; return 1; }
  test ! -e $(ConvertTo-ShLiteral $commitPath) && test ! -L $(ConvertTo-ShLiteral $commitPath) || { veq_clear_commit; return 1; }
  test ! -e $(ConvertTo-ShLiteral $commitStage) && test ! -L $(ConvertTo-ShLiteral $commitStage) || { veq_clear_commit; return 1; }
  printf '%s\n' "`$veq_transaction" > $(ConvertTo-ShLiteral $commitStage) || { veq_clear_commit; return 1; }
  test "`$(cat $(ConvertTo-ShLiteral $commitStage))" = "`$veq_transaction" || { veq_clear_commit; return 1; }
  mv $(ConvertTo-ShLiteral $commitStage) $(ConvertTo-ShLiteral $commitPath) || { veq_clear_commit; return 1; }
  test ! -L $(ConvertTo-ShLiteral $commitPath) || { veq_clear_commit; return 1; }
  test "`$(cat $(ConvertTo-ShLiteral $commitPath))" = "`$veq_transaction" || { veq_clear_commit; return 1; }
}
"@
}

function Get-TransactionCommitMarkerPath {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $TransactionId,
        [Parameter(Mandatory)][string] $Operation
    )

    $transaction = Assert-TransactionId $TransactionId
    $operationName = Assert-TransactionOperation $Operation
    $commitDir = Assert-AndroidPathContained -Path "$($State.StateDir)/commits" -Roots @($State.StateDir)
    return Assert-AndroidPathContained `
            -Path "$commitDir/$transaction-$operationName.committed" -Roots @($commitDir)
}

function Invoke-DeviceTransaction {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $TransactionId,
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode
    )

    $markerPath = Get-TransactionCommitMarkerPath -State $State `
            -TransactionId $TransactionId -Operation $Operation
    $markerValue = $script:TransactionMarker + ':' + (Assert-TransactionId $TransactionId) + ':' +
            (Assert-TransactionOperation $Operation)
    $result = Invoke-DeviceWriteShell -Command $Command -Mode $Mode -AllowFailure
    if ($result.ExitCode -eq 0) {
        return $result
    }

    # Never replay a command after an ambiguous transport result. A durable
    # marker written inside the rollback trap boundary lets a later read prove
    # that the remote commit completed despite the host-side error.
    $qMarkerPath = ConvertTo-ShLiteral $markerPath
    $qMarkerValue = ConvertTo-ShLiteral $markerValue
    $probe = Invoke-DeviceWriteShell `
            -Command "test ! -L $qMarkerPath && test -f $qMarkerPath && test \"`$(cat $qMarkerPath)\" = $qMarkerValue" `
            -Mode $Mode -AllowFailure
    if ($probe.ExitCode -eq 0) {
        Write-Warning "Recovered committed '$Operation' transaction $TransactionId after an ambiguous ADB result."
        return $result
    }
    throw "Remote '$Operation' transaction $TransactionId failed or remains ambiguous (exit $($result.ExitCode)).`n$($result.Lines -join [Environment]::NewLine)"
}

function New-MutationLockAcquireCommand {
    param(
        [Parameter(Mandatory)][string] $GameDir,
        [Parameter(Mandatory)][string] $StateDir,
        [Parameter(Mandatory)][string] $LockDir,
        [Parameter(Mandatory)][string] $TokenPath,
        [Parameter(Mandatory)][string] $Token
    )

    $null = Assert-TransactionId $Token
    $normalizedGame = Normalize-AndroidAbsolutePath $GameDir
    $normalizedState = Assert-AndroidPathContained -Path $StateDir -Roots @($normalizedGame)
    $stateParent = Assert-AndroidPathContained `
            -Path ((Split-Path -Parent $normalizedState).Replace('\', '/')) -Roots @($normalizedGame)
    $normalizedLock = Assert-AndroidPathContained -Path $LockDir -Roots @($normalizedState)
    $normalizedToken = Assert-AndroidPathContained -Path $TokenPath -Roots @($normalizedLock)
    $tokenStage = Assert-AndroidPathContained -Path "$normalizedLock/token.tmp" -Roots @($normalizedLock)
    return @"
set -eu
umask 077
# VEQ_LOCK_CANONICAL_GUARD
veq_lock_require_dir() {
  test -d "`$1" || exit 70
  test ! -L "`$1" || exit 70
  test "`$(cd "`$1" 2>/dev/null && pwd -P)" = "`$2" || exit 70
}
veq_lock_require_dir $(ConvertTo-ShLiteral $normalizedGame) $(ConvertTo-ShLiteral $normalizedGame)
test ! -L $(ConvertTo-ShLiteral $stateParent) || exit 70
if [ ! -e $(ConvertTo-ShLiteral $stateParent) ]; then mkdir $(ConvertTo-ShLiteral $stateParent); fi
veq_lock_require_dir $(ConvertTo-ShLiteral $stateParent) $(ConvertTo-ShLiteral $stateParent)
test ! -L $(ConvertTo-ShLiteral $normalizedState) || exit 70
if [ ! -e $(ConvertTo-ShLiteral $normalizedState) ]; then mkdir $(ConvertTo-ShLiteral $normalizedState); fi
veq_lock_require_dir $(ConvertTo-ShLiteral $normalizedState) $(ConvertTo-ShLiteral $normalizedState)
test ! -L $(ConvertTo-ShLiteral $normalizedLock) || exit 71
test ! -L $(ConvertTo-ShLiteral $normalizedToken) || exit 71
test ! -L $(ConvertTo-ShLiteral $tokenStage) || exit 71
veq_lock_created=0
veq_lock_cleanup() {
  veq_lock_status=`$?
  trap - 0
  if [ "`$veq_lock_created" = 1 ]; then
    rm -f $(ConvertTo-ShLiteral $tokenStage) $(ConvertTo-ShLiteral $normalizedToken) 2>/dev/null || true
    rmdir $(ConvertTo-ShLiteral $normalizedLock) 2>/dev/null || true
  fi
  exit "`$veq_lock_status"
}
trap veq_lock_cleanup 0
if ! mkdir $(ConvertTo-ShLiteral $normalizedLock) 2>/dev/null; then
  veq_lock_now=`$(date +%s)
  veq_lock_mtime=`$(stat -c %Y $(ConvertTo-ShLiteral $normalizedLock) 2>/dev/null || printf '0')
  veq_lock_age=`$((veq_lock_now - veq_lock_mtime))
  if [ -d $(ConvertTo-ShLiteral $normalizedLock) ] && [ ! -L $(ConvertTo-ShLiteral $normalizedLock) ] &&
       [ ! -e $(ConvertTo-ShLiteral $normalizedToken) ] && [ ! -L $(ConvertTo-ShLiteral $normalizedToken) ] &&
       [ "`$veq_lock_age" -ge 60 ] &&
       { test ! -e $(ConvertTo-ShLiteral $tokenStage) || { test -f $(ConvertTo-ShLiteral $tokenStage) && test ! -L $(ConvertTo-ShLiteral $tokenStage); }; } &&
       rm -f $(ConvertTo-ShLiteral $tokenStage) && rmdir $(ConvertTo-ShLiteral $normalizedLock); then
    mkdir $(ConvertTo-ShLiteral $normalizedLock)
  else
    exit 72
  fi
fi
veq_lock_created=1
printf '%s\n' $(ConvertTo-ShLiteral $Token) > $(ConvertTo-ShLiteral $tokenStage)
test -f $(ConvertTo-ShLiteral $tokenStage) && test ! -L $(ConvertTo-ShLiteral $tokenStage) || exit 73
mv $(ConvertTo-ShLiteral $tokenStage) $(ConvertTo-ShLiteral $normalizedToken)
test -f $(ConvertTo-ShLiteral $normalizedToken) && test ! -L $(ConvertTo-ShLiteral $normalizedToken) || exit 73
test "`$(cat $(ConvertTo-ShLiteral $normalizedToken))" = $(ConvertTo-ShLiteral $Token) || exit 73
veq_lock_created=0
trap - 0
"@
}

function New-MutationLockReleaseCommand {
    param(
        [Parameter(Mandatory)][string] $StateDir,
        [Parameter(Mandatory)][string] $LockDir,
        [Parameter(Mandatory)][string] $TokenPath,
        [Parameter(Mandatory)][string] $Token
    )

    $null = Assert-TransactionId $Token
    $normalizedState = Normalize-AndroidAbsolutePath $StateDir
    $normalizedLock = Assert-AndroidPathContained -Path $LockDir -Roots @($normalizedState)
    $normalizedToken = Assert-AndroidPathContained -Path $TokenPath -Roots @($normalizedLock)
    $qTokenPath = ConvertTo-ShLiteral $normalizedToken
    $qToken = ConvertTo-ShLiteral $Token
    $qLockPath = ConvertTo-ShLiteral $normalizedLock
    $qStatePath = ConvertTo-ShLiteral $normalizedState
    return 'set -eu; test -d ' + $qStatePath + '; test ! -L ' + $qStatePath +
            '; test "$(cd ' + $qStatePath + ' && pwd -P)" = ' + $qStatePath +
            '; test -d ' + $qLockPath + '; test ! -L ' + $qLockPath +
            '; test "$(cd ' + $qLockPath + ' && pwd -P)" = ' + $qLockPath +
            '; test -f ' + $qTokenPath + '; test ! -L ' + $qTokenPath +
            '; test "$(cat ' + $qTokenPath + ')" = ' + $qToken +
            '; rm -f ' + $qTokenPath + '; rmdir ' + $qLockPath
}

function Enter-DeviceMutationLock {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode
    )

    $stateDir = Assert-AndroidPathContained -Path $State.StateDir -Roots @($State.GameDir)
    $token = New-TransactionId
    $lockDir = Assert-AndroidPathContained -Path "$stateDir/mutation.lock" -Roots @($stateDir)
    $tokenPath = "$lockDir/token"
    $command = New-MutationLockAcquireCommand -GameDir $State.GameDir -StateDir $stateDir -LockDir $lockDir `
            -TokenPath $tokenPath -Token $token
    $result = Invoke-DeviceWriteShell -Command $command -Mode $Mode -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "Could not acquire the exclusive VEQ mutation lock. A stale or active lock may exist.`n$($result.Lines -join [Environment]::NewLine)"
    }
    $lock = [pscustomobject]@{
        StatePath = $stateDir; Path = $lockDir; TokenPath = $tokenPath; Token = $token; Mode = $Mode
    }
    try {
        $canonicalState = Resolve-DeviceCanonicalPath $stateDir
        $canonicalState = Assert-AndroidPathContained -Path $canonicalState -Roots @($State.GameDir)
        $canonicalLock = Resolve-DeviceCanonicalPath $lockDir
        $canonicalLock = Assert-AndroidPathContained -Path $canonicalLock -Roots @($canonicalState)
        $canonicalToken = Resolve-DeviceCanonicalPath $tokenPath
        $canonicalToken = Assert-AndroidPathContained -Path $canonicalToken -Roots @($canonicalLock)
        if (-not (Test-RemoteFile $canonicalToken)) {
            throw 'The VEQ mutation lock token is not a regular file.'
        }
        return [pscustomobject]@{
            Path = $canonicalLock
            StatePath = $canonicalState
            TokenPath = $canonicalToken
            Token = $token
            Mode = $Mode
        }
    } catch {
        Exit-DeviceMutationLock -Lock $lock
        throw
    }
}

function Exit-DeviceMutationLock {
    param([Parameter(Mandatory)] $Lock)

    $command = New-MutationLockReleaseCommand -StateDir $Lock.StatePath -LockDir $Lock.Path `
            -TokenPath $Lock.TokenPath -Token $Lock.Token
    $result = Invoke-DeviceWriteShell -Command $command -Mode $Lock.Mode -AllowFailure
    if ($result.ExitCode -ne 0) {
        Write-Warning "The VEQ mutation lock could not be released; future writes will fail closed."
    }
}

function Set-StateMutationLockContract {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Lock
    )

    $State | Add-Member -NotePropertyName MutationLockPath -NotePropertyValue $Lock.Path -Force
    $State | Add-Member -NotePropertyName MutationLockTokenPath -NotePropertyValue $Lock.TokenPath -Force
    $State | Add-Member -NotePropertyName MutationLockToken -NotePropertyValue $Lock.Token -Force
    return $State
}

function Assert-DeviceReady {
    $state = Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'get-state')
    if ((($state.Lines -join '').Trim()) -ne 'device') {
        throw "Device $script:ResolvedSerial is not in the ADB device state."
    }
}

function Get-ProcessSnapshot {
    $result = Invoke-DeviceShell -Command 'ps -A -o PID,NAME,ARGS'
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $result.Lines) {
        if ($line -match '^\s*(?<pid>\d+)\s+(?<name>\S+)(?:\s+(?<args>.*))?$') {
            $rows.Add([pscustomobject]@{
                Pid = [int]$Matches.pid
                Name = [string]$Matches.name
                Args = [string]$Matches.args
            })
        }
    }
    return $rows.ToArray()
}

function Assert-AppStopped {
    $running = @(
        Get-ProcessSnapshot | Where-Object {
            $_.Name -eq $Package -or $_.Name.StartsWith("${Package}:") -or
            $_.Args -match ('(^|\s)' + [regex]::Escape($Package) + '(:\S+)?(\s|$)')
        }
    )
    if ($running.Count -gt 0) {
        $description = ($running | ForEach-Object { "$($_.Pid):$($_.Name)" }) -join ', '
        throw "Refusing to change VEQ while $Package is running ($description). Exit it normally first."
    }
}

function Test-RemoteFile {
    param([Parameter(Mandatory)][string] $Path)

    $result = Invoke-DeviceShell -Command "test -f $(ConvertTo-ShLiteral $Path)" -AllowFailure
    return $result.ExitCode -eq 0
}

function Test-RemoteDirectory {
    param([Parameter(Mandatory)][string] $Path)

    $result = Invoke-DeviceShell -Command "test -d $(ConvertTo-ShLiteral $Path)" -AllowFailure
    return $result.ExitCode -eq 0
}

function Get-DeviceSha256 {
    param([Parameter(Mandatory)][string] $Path)

    $result = Invoke-DeviceShell -Command "sha256sum $(ConvertTo-ShLiteral $Path)"
    $text = $result.Lines -join ' '
    if ($text -notmatch '(?i)\b(?<sha>[0-9a-f]{64})\b') {
        throw "Could not parse SHA-256 for $Path."
    }
    return $Matches.sha.ToUpperInvariant()
}

function Get-DeviceText {
    param([Parameter(Mandatory)][string] $Path)

    $result = Invoke-DeviceShell -Command "cat $(ConvertTo-ShLiteral $Path)"
    return ($result.Lines -join "`n")
}

function Get-LeafName {
    param([Parameter(Mandatory)][string] $Path)

    return (($Path.TrimEnd('/') -split '/')[-1])
}

function Read-InstanceState {
    if (-not (Test-RemoteFile $script:InstancesFile)) {
        throw "instances.json is missing at $script:InstancesFile."
    }

    $raw = Get-DeviceText $script:InstancesFile
    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        throw "instances.json is not valid JSON: $($_.Exception.Message)"
    }
    $instances = @($json.instances)
    $matches = @(
        $instances | Where-Object {
            [string]$_.instanceName -eq $Profile -or
            [string]$_.versionName -eq $Profile -or
            (-not [string]::IsNullOrWhiteSpace([string]$_.gameDir) -and
                (Get-LeafName ([string]$_.gameDir)) -eq $Profile)
        }
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one '$Profile' instance, found $($matches.Count)."
    }

    $instance = $matches[0]
    $gameDir = ([string]$instance.gameDir).TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($gameDir)) {
        throw "The '$Profile' instance has no gameDir."
    }
    $allowedRoots = @(
        "/sdcard/Android/data/$Package/files",
        "/storage/emulated/0/Android/data/$Package/files"
    )
    $gameDir = Assert-AndroidPathContained -Path $gameDir -Roots $allowedRoots

    $canonicalRoots = @(
        $allowedRoots | ForEach-Object {
            Resolve-DeviceCanonicalPath -Path $_ -AllowFailure
        } | Where-Object { $null -ne $_ } | Select-Object -Unique
    )
    if ($canonicalRoots.Count -eq 0) {
        throw 'Could not resolve the selected package files directory canonically.'
    }
    $canonicalGameDir = Resolve-DeviceCanonicalPath $gameDir
    $canonicalGameDir = Assert-AndroidPathContained -Path $canonicalGameDir -Roots $canonicalRoots
    $matchingCanonicalRoots = @($canonicalRoots | Where-Object {
        $canonicalGameDir.StartsWith($_ + '/', [StringComparison]::Ordinal)
    })
    if ($matchingCanonicalRoots.Count -ne 1) {
        throw 'The selected instance does not have one unambiguous canonical files root.'
    }
    $canonicalFilesDir = $matchingCanonicalRoots[0]
    $canonicalInstancesPath = Assert-AndroidPathContained `
            -Path "$canonicalFilesDir/instances.json" -Roots @($canonicalFilesDir)
    $canonicalModsDir = Resolve-DeviceCanonicalPath "$canonicalGameDir/mods"
    $canonicalModsDir = Assert-AndroidPathContained -Path $canonicalModsDir -Roots @($canonicalGameDir)

    $disabledProperty = $instance.PSObject.Properties['disabledMods']
    $disabled = if ($null -eq $disabledProperty -or $null -eq $disabledProperty.Value) {
        @()
    } else {
        @($disabledProperty.Value)
    }
    $projectsProperty = $instance.PSObject.Properties['extProjects']
    $projects = if ($null -eq $projectsProperty -or $null -eq $projectsProperty.Value) {
        @()
    } else {
        @($projectsProperty.Value)
    }
    $managedProjects = @(
        $projects | Where-Object {
            $null -ne $_ -and [string]$_.slug -eq $script:Slug
        }
    )
    if ($managedProjects.Count -gt 1) {
        throw "The instance contains duplicate $script:Slug extProjects entries."
    }

    $managedFileName = "$script:Slug.jar"
    if ($managedProjects.Count -eq 1 -and
            $null -ne $managedProjects[0].PSObject.Properties['fileName'] -and
            -not [string]::IsNullOrWhiteSpace([string]$managedProjects[0].fileName)) {
        $managedBaseName = Assert-SafeLeafName ([string]$managedProjects[0].fileName)
        $managedFileName = $managedBaseName + '.jar'
    }
    $null = Assert-SafeLeafName $managedFileName
    $stateParent = "$canonicalGameDir/.questcraft"
    if (Test-RemoteDirectory $stateParent) {
        $stateParent = Assert-AndroidPathContained `
                -Path (Resolve-DeviceCanonicalPath $stateParent) -Roots @($canonicalGameDir)
    }
    $stateDir = "$stateParent/veq-dev"
    if (Test-RemoteDirectory $stateDir) {
        $stateDir = Assert-AndroidPathContained `
                -Path (Resolve-DeviceCanonicalPath $stateDir) -Roots @($canonicalGameDir)
    }
    $managedPath = Assert-AndroidPathContained -Path "$canonicalModsDir/$managedFileName" -Roots @($canonicalModsDir)
    $devPath = Assert-AndroidPathContained -Path "$canonicalModsDir/$script:DevJarName" -Roots @($canonicalModsDir)

    return [pscustomobject]@{
        Json = $json
        Instance = $instance
        FilesDir = $canonicalFilesDir
        InstancesPath = $canonicalInstancesPath
        GameDir = $canonicalGameDir
        ModsDir = $canonicalModsDir
        StateDir = $stateDir
        InstancesSha256 = Get-DeviceSha256 $canonicalInstancesPath
        Disabled = @($disabled | Where-Object { Test-ManagedSlugValue $_ }).Count -gt 0
        ManagedProjectPresent = $managedProjects.Count -eq 1
        ManagedFileName = $managedFileName
        ManagedPath = $managedPath
        DevPath = $devPath
    }
}

function Set-DisabledState {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][bool] $Disabled
    )

    $property = $State.Instance.PSObject.Properties['disabledMods']
    $original = if ($null -eq $property -or $null -eq $property.Value) {
        @()
    } else {
        @($property.Value)
    }
    $values = New-Object System.Collections.Generic.List[object]
    foreach ($value in $original) {
        if (Test-ManagedSlugValue $value) {
            continue
        }
        # Preserve unrelated entries byte-for-byte, including blanks, casing,
        # order, and duplicates. This mutation owns only the VEQ slug.
        $values.Add($value)
    }
    if ($Disabled) {
        $values.Add($script:Slug)
    }

    if ($null -eq $property) {
        $State.Instance | Add-Member -NotePropertyName disabledMods -NotePropertyValue $values.ToArray()
    } else {
        $State.Instance.disabledMods = $values.ToArray()
    }
}

function Push-File {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $LocalPath,
        [Parameter(Mandatory)][string] $RemotePath,
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [Parameter(Mandatory)][string] $TransactionId,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode
    )

    $expected = Assert-Sha256Value $ExpectedSha256
    $null = Assert-TransactionId $TransactionId
    $remote = Assert-AndroidPathContained -Path $RemotePath `
            -Roots @($State.StateDir, $State.ModsDir)
    $transportStage = "/data/local/tmp/quest-veq-upload-$TransactionId.tmp"
    $importDir = Assert-AndroidPathContained `
            -Path "$($State.StateDir)/import-$TransactionId" -Roots @($State.StateDir)
    $importPayload = Assert-AndroidPathContained -Path "$importDir/payload" -Roots @($importDir)
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $State.InstancesSha256 `
            -TransactionId $TransactionId -Operation 'stage-import' `
            -AdditionalLeaves @($remote, $importDir, $importPayload)
    $directoryCleanupGuard = Get-StateMutationGuardShell -State $State -AdditionalLeaves @($importDir)
    $command = @"
$prelude
# VEQ_TRANSPORT_STAGE_IMPORT
test "`$(veq_sha $(ConvertTo-ShLiteral $transportStage))" = $(ConvertTo-ShLiteral $expected) || exit 77
test ! -e $(ConvertTo-ShLiteral $remote) && test ! -L $(ConvertTo-ShLiteral $remote) || exit 78
test ! -e $(ConvertTo-ShLiteral $importDir) && test ! -L $(ConvertTo-ShLiteral $importDir) || exit 78
mkdir $(ConvertTo-ShLiteral $importDir)
test ! -L $(ConvertTo-ShLiteral $importDir) || exit 78
test "`$(cd $(ConvertTo-ShLiteral $importDir) && pwd -P)" = $(ConvertTo-ShLiteral $importDir) || exit 78
(cd $(ConvertTo-ShLiteral $importDir) && cp $(ConvertTo-ShLiteral $transportStage) ./payload)
test ! -L $(ConvertTo-ShLiteral $importPayload) || exit 79
test "`$(veq_sha $(ConvertTo-ShLiteral $importPayload))" = $(ConvertTo-ShLiteral $expected) || exit 79
mv $(ConvertTo-ShLiteral $importPayload) $(ConvertTo-ShLiteral $remote)
test -f $(ConvertTo-ShLiteral $remote) && test ! -L $(ConvertTo-ShLiteral $remote) || exit 79
chmod 0644 $(ConvertTo-ShLiteral $remote)
rmdir $(ConvertTo-ShLiteral $importDir)
test ! -L $(ConvertTo-ShLiteral $remote) || exit 79
test "`$(veq_sha $(ConvertTo-ShLiteral $remote))" = $(ConvertTo-ShLiteral $expected) || exit 79
"@
    try {
        # Both transports upload only to shell-owned /data/local/tmp. The
        # selected normal/root transaction then imports through a newly-created
        # private directory and atomically renames a verified regular file.
        Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'push', $LocalPath, $transportStage) | Out-Null
        Invoke-DeviceWriteShell -Command $command -Mode $Mode | Out-Null
    } finally {
        Invoke-DeviceShell -Command "rm -f $(ConvertTo-ShLiteral $transportStage)" -AllowFailure | Out-Null
        Remove-RemoteFiles -Paths @($importPayload) -Mode $Mode
        Invoke-DeviceWriteShell -Command ($directoryCleanupGuard + "`nrmdir " +
                (ConvertTo-ShLiteral $importDir) + ' 2>/dev/null || true') `
                -Mode $Mode -AllowFailure | Out-Null
    }
}

function Remove-RemoteFiles {
    param(
        [Parameter(Mandatory)][string[]] $Paths,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode
    )

    if ($Paths.Count -eq 0) {
        return
    }
    $cleanupLines = New-Object System.Collections.Generic.List[string]
    foreach ($pathValue in $Paths) {
        $path = Normalize-AndroidAbsolutePath $pathValue
        $parent = Normalize-AndroidAbsolutePath ((Split-Path -Parent $path).Replace('\', '/'))
        $qPath = ConvertTo-ShLiteral $path
        $qParent = ConvertTo-ShLiteral $parent
        $cleanupLines.Add(@"
test ! -L $qParent || exit 67
if [ -e $qParent ]; then
  test -d $qParent || exit 67
  test "`$(cd $qParent 2>/dev/null && pwd -P)" = $qParent || exit 67
  test ! -L $qPath || exit 67
  rm -f $qPath
fi
"@)
    }
    $command = "set -eu`n# VEQ_CANONICAL_CLEANUP_GUARD`n" +
            ($cleanupLines -join [Environment]::NewLine)
    Invoke-DeviceWriteShell -Command $command -Mode $Mode -AllowFailure | Out-Null
}

function New-InstancesCommitCommand {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $BeforeSha256,
        [Parameter(Mandatory)][string] $AfterSha256,
        [Parameter(Mandatory)][string] $RemoteStage,
        [Parameter(Mandatory)][string] $Backup,
        [Parameter(Mandatory)][string] $BackupStage,
        [Parameter(Mandatory)][string] $RestoreStage,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $before = Assert-Sha256Value $BeforeSha256
    $after = Assert-Sha256Value $AfterSha256
    $null = Assert-TransactionId $TransactionId
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $before `
            -TransactionId $TransactionId -Operation 'instances-commit'
    $qInstances = ConvertTo-ShLiteral $State.InstancesPath
    $qBefore = ConvertTo-ShLiteral $before
    $qAfter = ConvertTo-ShLiteral $after
    $qStage = ConvertTo-ShLiteral $RemoteStage
    $qBackup = ConvertTo-ShLiteral $Backup
    $qBackupStage = ConvertTo-ShLiteral $BackupStage
    $qRestore = ConvertTo-ShLiteral $RestoreStage
    $qBackupDir = ConvertTo-ShLiteral (Split-Path -Parent $Backup).Replace('\', '/')
    return @"
$prelude
# VEQ_INSTANCES_ATOMIC_COMMIT
for veq_leaf in $qStage $qBackup $qBackupStage $qRestore; do veq_reject_symlink "`$veq_leaf"; done
test "`$(veq_sha $qStage)" = $qAfter || exit 77
test ! -L $qBackupDir || exit 78
if [ ! -e $qBackupDir ]; then mkdir $qBackupDir; fi
test -d $qBackupDir && test ! -L $qBackupDir || exit 78
test "`$(cd $qBackupDir 2>/dev/null && pwd -P)" = $qBackupDir || exit 78
for veq_temp in $qBackup $qBackupStage $qRestore; do test ! -e "`$veq_temp" && test ! -L "`$veq_temp" || exit 78; done
cp $qInstances $qBackupStage
test "`$(veq_sha $qBackupStage)" = $qBefore || exit 79
mv -f $qBackupStage $qBackup
test "`$(veq_sha $qBackup)" = $qBefore || exit 80
veq_instances_changed=0
veq_instances_restore() {
  veq_restore_status=0
  if [ "`$veq_instances_changed" = 1 ]; then
    cp $qBackup $qRestore && test "`$(veq_sha $qRestore)" = $qBefore && mv -f $qRestore $qInstances && chmod 0644 $qInstances && test "`$(veq_sha $qInstances)" = $qBefore || veq_restore_status=1
  fi
  return "`$veq_restore_status"
}
trap 'veq_status=`$?; trap - 0; if [ "`$veq_status" -ne 0 ]; then veq_clear_commit || exit 89; veq_instances_restore || exit 89; fi; exit "`$veq_status"' 0
veq_instances_changed=1
mv -f $qStage $qInstances
test -f $qInstances && test ! -L $qInstances || exit 81
chmod 0644 $qInstances
test "`$(veq_sha $qInstances)" = $qAfter || exit 81
veq_record_commit || exit 82
trap - 0
"@
}

function New-InstancesRollbackCommand {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $BeforeSha256,
        [Parameter(Mandatory)][string] $AfterSha256,
        [Parameter(Mandatory)][string] $Backup,
        [Parameter(Mandatory)][string] $RestoreStage,
        [Parameter(Mandatory)][string] $CurrentStage,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $before = Assert-Sha256Value $BeforeSha256
    $after = Assert-Sha256Value $AfterSha256
    $null = Assert-TransactionId $TransactionId
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $after `
            -TransactionId $TransactionId -Operation 'instances-rollback'
    $qInstances = ConvertTo-ShLiteral $State.InstancesPath
    $qBefore = ConvertTo-ShLiteral $before
    $qAfter = ConvertTo-ShLiteral $after
    $qBackup = ConvertTo-ShLiteral $Backup
    $qRestore = ConvertTo-ShLiteral $RestoreStage
    $qCurrent = ConvertTo-ShLiteral $CurrentStage
    return @"
$prelude
# VEQ_INSTANCES_ROLLBACK
for veq_leaf in $qBackup $qRestore $qCurrent; do veq_reject_symlink "`$veq_leaf"; done
test "`$(veq_sha $qBackup)" = $qBefore || exit 90
for veq_temp in $qRestore $qCurrent; do test ! -e "`$veq_temp" && test ! -L "`$veq_temp" || exit 91; done
cp $qInstances $qCurrent
test "`$(veq_sha $qCurrent)" = $qAfter || exit 92
cp $qBackup $qRestore
test "`$(veq_sha $qRestore)" = $qBefore || exit 93
veq_instances_changed=0
veq_instances_recover_after() {
  veq_restore_status=0
  if [ "`$veq_instances_changed" = 1 ]; then
    mv -f $qCurrent $qInstances && chmod 0644 $qInstances && test "`$(veq_sha $qInstances)" = $qAfter || veq_restore_status=1
  fi
  return "`$veq_restore_status"
}
trap 'veq_status=`$?; trap - 0; if [ "`$veq_status" -ne 0 ]; then veq_clear_commit || exit 99; veq_instances_recover_after || exit 99; fi; exit "`$veq_status"' 0
veq_instances_changed=1
mv -f $qRestore $qInstances
test -f $qInstances && test ! -L $qInstances || exit 94
chmod 0644 $qInstances
test "`$(veq_sha $qInstances)" = $qBefore || exit 94
veq_record_commit || exit 95
trap - 0
"@
}

function Write-InstancesAtomically {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $before = Get-DeviceSha256 $State.InstancesPath
    if ($before -ne $State.InstancesSha256) {
        throw "instances.json changed since it was read. Expected $($State.InstancesSha256), got $before."
    }

    $null = Assert-TransactionId $TransactionId
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('quest-veq-' + (New-TransactionId))
    [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    $local = Join-Path $temporaryDirectory 'instances.json'
    $remoteStage = Assert-AndroidPathContained `
            -Path "$($State.StateDir)/instances-$TransactionId.tmp" -Roots @($State.StateDir)
    $backupDir = "$($State.StateDir)/backups"
    $backup = Assert-AndroidPathContained `
            -Path "$backupDir/instances-$TransactionId-$before.json" -Roots @($State.StateDir)
    $backupStage = "$backup.tmp"
    $restoreStage = Assert-AndroidPathContained `
            -Path "$($State.StateDir)/instances-restore-$TransactionId.tmp" -Roots @($State.StateDir)
    try {
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($local, (($State.Json | ConvertTo-Json -Depth 100) + [Environment]::NewLine), $utf8)
        $localSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $local).Hash.ToUpperInvariant()
        Push-File -State $State -LocalPath $local -RemotePath $remoteStage `
                -ExpectedSha256 $localSha -TransactionId $TransactionId -Mode $Mode
        if ((Get-DeviceSha256 $remoteStage) -ne $localSha) {
            throw 'The staged instances.json failed SHA-256 verification.'
        }
        Assert-AppStopped
        $command = New-InstancesCommitCommand -State $State -BeforeSha256 $before -AfterSha256 $localSha `
                -RemoteStage $remoteStage -Backup $backup -BackupStage $backupStage `
                -RestoreStage $restoreStage -TransactionId $TransactionId
        Invoke-DeviceTransaction -State $State -TransactionId $TransactionId `
                -Operation 'instances-commit' -Command $command -Mode $Mode | Out-Null
        return [pscustomobject]@{ Before = $before; After = $localSha; Backup = $backup }
    } finally {
        Remove-RemoteFiles -Paths @($remoteStage, $backupStage, $restoreStage) -Mode $Mode
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            Remove-Item -LiteralPath $local -Force
        }
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
            Remove-Item -LiteralPath $temporaryDirectory -Force
        }
    }
}

function Restore-InstancesBackup {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Change,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [Parameter(Mandatory)][string] $TransactionId
    )

    Assert-AppStopped
    $null = Assert-TransactionId $TransactionId
    $backupParent = (Split-Path -Parent $Change.Backup).Replace('\', '/')
    $restoreStage = Assert-AndroidPathContained `
            -Path "$backupParent/instances-rollback-$TransactionId.tmp" -Roots @($backupParent)
    $currentStage = Assert-AndroidPathContained `
            -Path "$backupParent/instances-current-$TransactionId.tmp" -Roots @($backupParent)
    $command = New-InstancesRollbackCommand -State $State -BeforeSha256 $Change.Before `
            -AfterSha256 $Change.After -Backup $Change.Backup -RestoreStage $restoreStage `
            -CurrentStage $currentStage -TransactionId $TransactionId
    try {
        Invoke-DeviceTransaction -State $State -TransactionId $TransactionId `
                -Operation 'instances-rollback' -Command $command -Mode $Mode | Out-Null
    } finally {
        Remove-RemoteFiles -Paths @($restoreStage, $currentStage) -Mode $Mode
    }
}

function Get-FabricJarInfo {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JAR not found: $Path"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -eq 'fabric.mod.json' })
        if ($entries.Count -ne 1) {
            throw "Expected exactly one root fabric.mod.json, found $($entries.Count)."
        }
        $reader = [IO.StreamReader]::new($entries[0].Open(), [Text.Encoding]::UTF8, $true)
        try {
            $fabric = ($reader.ReadToEnd() | ConvertFrom-Json)
        } finally {
            $reader.Dispose()
        }
    } finally {
        $archive.Dispose()
    }

    if ([string]$fabric.id -ne $script:ModId) {
        throw "The candidate mod id is '$($fabric.id)', expected '$script:ModId'."
    }
    return [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $Path).Path
        Id = [string]$fabric.id
        Version = [string]$fabric.version
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
        Length = (Get-Item -LiteralPath $Path).Length
    }
}

function Get-RemoteJarInfo {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-RemoteFile $Path)) {
        return $null
    }
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('quest-veq-inspect-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    $local = Join-Path $temporaryDirectory ([IO.Path]::GetFileName($Path))
    try {
        Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'pull', $Path, $local) | Out-Null
        $info = Get-FabricJarInfo $local
        $deviceSha = Get-DeviceSha256 $Path
        if ($deviceSha -ne $info.Sha256) {
            throw "Pulled JAR hash differs from the device hash for $Path."
        }
        return [pscustomobject]@{
            Path = $Path
            Id = $info.Id
            Version = $info.Version
            Sha256 = $deviceSha
            Length = $info.Length
        }
    } finally {
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            Remove-Item -LiteralPath $local -Force
        }
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
            Remove-Item -LiteralPath $temporaryDirectory -Force
        }
    }
}

function Get-ManagedBackupPath {
    param([Parameter(Mandatory)] $State)

    # Keep the established v66 backup location so an existing verified backup
    # remains restorable after upgrading this helper.
    $leaf = Assert-SafeLeafName 'managed-v66.bin'
    return Assert-AndroidPathContained -Path "$($State.StateDir)/$leaf" -Roots @($State.StateDir)
}

function Ensure-ManagedBackup {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $backup = Get-ManagedBackupPath $State
    if (Test-RemoteFile $backup) {
        if ((Get-DeviceSha256 $backup) -ne $script:ExpectedManagedSha256) {
            throw 'The existing managed VEQ backup has an unexpected SHA-256.'
        }
        return $backup
    }
    if (-not (Test-RemoteFile $State.ManagedPath)) {
        return $null
    }
    if ((Get-DeviceSha256 $State.ManagedPath) -ne $script:ExpectedManagedSha256) {
        throw 'Refusing to back up a managed VEQ JAR whose hash differs from the lock.'
    }
    $null = Assert-TransactionId $TransactionId
    $stage = Assert-AndroidPathContained -Path "$backup.$TransactionId.tmp" -Roots @($State.StateDir)
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $State.InstancesSha256 `
            -TransactionId $TransactionId -Operation 'managed-backup'
    $command = @"
$prelude
# VEQ_MANAGED_BACKUP_PREPARE
veq_reject_symlink $(ConvertTo-ShLiteral $backup)
veq_reject_symlink $(ConvertTo-ShLiteral $stage)
test ! -e $(ConvertTo-ShLiteral $backup) && test ! -L $(ConvertTo-ShLiteral $backup) || exit 83
test ! -e $(ConvertTo-ShLiteral $stage) && test ! -L $(ConvertTo-ShLiteral $stage) || exit 84
test "`$(veq_sha $(ConvertTo-ShLiteral $State.ManagedPath))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 85
cp $(ConvertTo-ShLiteral $State.ManagedPath) $(ConvertTo-ShLiteral $stage)
test "`$(veq_sha $(ConvertTo-ShLiteral $stage))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 86
mv -f $(ConvertTo-ShLiteral $stage) $(ConvertTo-ShLiteral $backup)
test "`$(veq_sha $(ConvertTo-ShLiteral $backup))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 87
"@
    try {
        Assert-AppStopped
        Invoke-DeviceWriteShell -Command $command -Mode $Mode | Out-Null
        if ((Get-DeviceSha256 $backup) -ne $script:ExpectedManagedSha256) {
            throw 'Managed VEQ backup verification failed.'
        }
        return $backup
    } finally {
        Remove-RemoteFiles -Paths @($stage) -Mode $Mode
    }
}

function New-ManagedRemoveCommand {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $ManagedBackup,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $backup = Assert-AndroidPathContained -Path $ManagedBackup -Roots @($State.StateDir)
    $restoreStage = Assert-AndroidPathContained `
            -Path "$($State.ModsDir)/.veq-enable-restore-$TransactionId.tmp" -Roots @($State.ModsDir)
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $State.InstancesSha256 `
            -TransactionId $TransactionId -Operation 'managed-remove' `
            -AdditionalLeaves @($backup, $restoreStage)
    return @"
$prelude
# VEQ_MANAGED_REMOVE_COMMIT
test "`$(veq_sha $(ConvertTo-ShLiteral $backup))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 82
test "`$(veq_sha $(ConvertTo-ShLiteral $State.ManagedPath))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 83
test ! -e $(ConvertTo-ShLiteral $restoreStage) && test ! -L $(ConvertTo-ShLiteral $restoreStage) || exit 84
veq_managed_removed=0
veq_enable_restore_managed() {
  veq_restore_status=0
  if [ "`$veq_managed_removed" = 1 ]; then
    cp $(ConvertTo-ShLiteral $backup) $(ConvertTo-ShLiteral $restoreStage) &&
      test ! -L $(ConvertTo-ShLiteral $restoreStage) &&
      test "`$(veq_sha $(ConvertTo-ShLiteral $restoreStage))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) &&
      mv -f $(ConvertTo-ShLiteral $restoreStage) $(ConvertTo-ShLiteral $State.ManagedPath) &&
      chmod 0644 $(ConvertTo-ShLiteral $State.ManagedPath) &&
      test ! -L $(ConvertTo-ShLiteral $State.ManagedPath) &&
      test "`$(veq_sha $(ConvertTo-ShLiteral $State.ManagedPath))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || veq_restore_status=1
  fi
  return "`$veq_restore_status"
}
trap 'veq_status=`$?; trap - 0; if [ "`$veq_status" -ne 0 ]; then veq_clear_commit || exit 89; veq_enable_restore_managed || exit 89; fi; exit "`$veq_status"' 0
veq_managed_removed=1
rm $(ConvertTo-ShLiteral $State.ManagedPath)
test ! -e $(ConvertTo-ShLiteral $State.ManagedPath) && test ! -L $(ConvertTo-ShLiteral $State.ManagedPath) || exit 85
veq_record_commit || exit 86
trap - 0
"@
}

function Remove-ManagedJarAfterDisable {
    param(
        [Parameter(Mandatory)] $State,
        [AllowNull()][string] $ManagedBackup,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [Parameter(Mandatory)][string] $TransactionId
    )

    if (-not (Test-RemoteFile $State.ManagedPath)) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($ManagedBackup)) {
        throw 'A verified managed backup is required before removing the managed JAR.'
    }
    $restoreStage = Assert-AndroidPathContained `
            -Path "$($State.ModsDir)/.veq-enable-restore-$TransactionId.tmp" -Roots @($State.ModsDir)
    Assert-AppStopped
    $command = New-ManagedRemoveCommand -State $State -ManagedBackup $ManagedBackup `
            -TransactionId $TransactionId
    try {
        Invoke-DeviceTransaction -State $State -TransactionId $TransactionId `
                -Operation 'managed-remove' -Command $command -Mode $Mode | Out-Null
        if (Test-RemoteFile $State.ManagedPath) {
            throw 'Managed VEQ is still visible after the disable commit.'
        }
    } finally {
        Remove-RemoteFiles -Paths @($restoreStage) -Mode $Mode
    }
}

function Restore-ManagedJarAfterEnableFailure {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $ManagedBackup,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $backup = Assert-AndroidPathContained -Path $ManagedBackup -Roots @($State.StateDir)
    $restoreStage = Assert-AndroidPathContained `
            -Path "$($State.ModsDir)/.veq-enable-compensate-$TransactionId.tmp" -Roots @($State.ModsDir)
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $State.InstancesSha256 `
            -TransactionId $TransactionId -Operation 'managed-compensate' `
            -AdditionalLeaves @($backup, $restoreStage)
    $command = @"
$prelude
# VEQ_ENABLE_MANAGED_COMPENSATION
test "`$(veq_sha $(ConvertTo-ShLiteral $backup))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 82
test ! -L $(ConvertTo-ShLiteral $State.ManagedPath) || exit 83
if [ -e $(ConvertTo-ShLiteral $State.ManagedPath) ]; then
  test -f $(ConvertTo-ShLiteral $State.ManagedPath) || exit 83
  test "`$(veq_sha $(ConvertTo-ShLiteral $State.ManagedPath))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 83
else
  test ! -e $(ConvertTo-ShLiteral $restoreStage) && test ! -L $(ConvertTo-ShLiteral $restoreStage) || exit 84
  cp $(ConvertTo-ShLiteral $backup) $(ConvertTo-ShLiteral $restoreStage)
  test ! -L $(ConvertTo-ShLiteral $restoreStage) || exit 84
  test "`$(veq_sha $(ConvertTo-ShLiteral $restoreStage))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 84
  mv -f $(ConvertTo-ShLiteral $restoreStage) $(ConvertTo-ShLiteral $State.ManagedPath)
  chmod 0644 $(ConvertTo-ShLiteral $State.ManagedPath)
  test ! -L $(ConvertTo-ShLiteral $State.ManagedPath) || exit 85
  test "`$(veq_sha $(ConvertTo-ShLiteral $State.ManagedPath))" = $(ConvertTo-ShLiteral $script:ExpectedManagedSha256) || exit 85
fi
"@
    try {
        Assert-AppStopped
        Invoke-DeviceWriteShell -Command $command -Mode $Mode | Out-Null
    } finally {
        Remove-RemoteFiles -Paths @($restoreStage) -Mode $Mode
    }
}

function New-DeployTransactionCommand {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $CandidateSha256,
        [Parameter(Mandatory)][string] $Stage,
        [AllowNull()][string] $CurrentSha256,
        [Parameter(Mandatory)][string] $Previous,
        [Parameter(Mandatory)][string] $PreviousShaFile,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $candidate = Assert-Sha256Value $CandidateSha256
    $null = Assert-TransactionId $TransactionId
    $currentExists = -not [string]::IsNullOrWhiteSpace($CurrentSha256)
    $current = if ($currentExists) { Assert-Sha256Value $CurrentSha256 } else { $null }
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $State.InstancesSha256 `
            -TransactionId $TransactionId -Operation 'deploy'
    $null = Assert-AndroidPathContained -Path $Stage -Roots @($State.StateDir)
    $null = Assert-AndroidPathContained -Path $Previous -Roots @($State.StateDir)
    $null = Assert-AndroidPathContained -Path $PreviousShaFile -Roots @($State.StateDir)
    $currentBackup = Assert-AndroidPathContained -Path "$($State.StateDir)/active-$TransactionId.bak" -Roots @($State.StateDir)
    $oldPrevious = Assert-AndroidPathContained -Path "$($State.StateDir)/old-previous-$TransactionId.bak" -Roots @($State.StateDir)
    $oldSidecar = Assert-AndroidPathContained -Path "$($State.StateDir)/old-previous-$TransactionId.sha" -Roots @($State.StateDir)
    $newPrevious = Assert-AndroidPathContained -Path "$($State.StateDir)/new-previous-$TransactionId.tmp" -Roots @($State.StateDir)
    $newSidecar = Assert-AndroidPathContained -Path "$($State.StateDir)/new-previous-$TransactionId.sha.tmp" -Roots @($State.StateDir)
    $restoreDev = Assert-AndroidPathContained -Path "$($State.ModsDir)/.veq-dev-restore-$TransactionId.tmp" -Roots @($State.ModsDir)
    $restorePrevious = Assert-AndroidPathContained -Path "$($State.StateDir)/restore-previous-$TransactionId.tmp" -Roots @($State.StateDir)
    $restoreSidecar = Assert-AndroidPathContained -Path "$($State.StateDir)/restore-previous-$TransactionId.sha.tmp" -Roots @($State.StateDir)
    $qDev = ConvertTo-ShLiteral $State.DevPath
    $qStage = ConvertTo-ShLiteral $Stage
    $qCandidate = ConvertTo-ShLiteral $candidate
    $qPrevious = ConvertTo-ShLiteral $Previous
    $qPreviousSha = ConvertTo-ShLiteral $PreviousShaFile
    $qCurrentBackup = ConvertTo-ShLiteral $currentBackup
    $qOldPrevious = ConvertTo-ShLiteral $oldPrevious
    $qOldSidecar = ConvertTo-ShLiteral $oldSidecar
    $qNewPrevious = ConvertTo-ShLiteral $newPrevious
    $qNewSidecar = ConvertTo-ShLiteral $newSidecar
    $qRestoreDev = ConvertTo-ShLiteral $restoreDev
    $qRestorePrevious = ConvertTo-ShLiteral $restorePrevious
    $qRestoreSidecar = ConvertTo-ShLiteral $restoreSidecar
    $qTemps = (@(
        $currentBackup, $oldPrevious, $oldSidecar, $newPrevious, $newSidecar,
        $restoreDev, $restorePrevious, $restoreSidecar
    ) | ForEach-Object { ConvertTo-ShLiteral $_ }) -join ' '
    $currentPreparation = if ($currentExists) {
        $qCurrent = ConvertTo-ShLiteral $current
        @"
test "`$(veq_sha $qDev)" = $qCurrent || exit 85
cp $qDev $qCurrentBackup
test "`$(veq_sha $qCurrentBackup)" = $qCurrent || exit 86
cp $qCurrentBackup $qNewPrevious
test "`$(veq_sha $qNewPrevious)" = $qCurrent || exit 87
printf '%s\n' $qCurrent > $qNewSidecar
test "`$(cat $qNewSidecar | tr -d '\r\n')" = $qCurrent || exit 88
"@
    } else {
        "test ! -e $qDev && test ! -L $qDev || exit 85"
    }
    $previousCommit = if ($currentExists) {
        @"
veq_previous_changed=1
mv -f $qNewPrevious $qPrevious
test "`$(veq_sha $qPrevious)" = $(ConvertTo-ShLiteral $current) || exit 89
veq_sidecar_changed=1
mv -f $qNewSidecar $qPreviousSha
test "`$(cat $qPreviousSha | tr -d '\r\n')" = $(ConvertTo-ShLiteral $current) || exit 90
"@
    } else {
        @"
if [ "`$veq_had_previous" = 1 ]; then veq_previous_changed=1; rm -f $qPrevious; test ! -e $qPrevious || exit 89; fi
if [ "`$veq_had_sidecar" = 1 ]; then veq_sidecar_changed=1; rm -f $qPreviousSha; test ! -e $qPreviousSha || exit 90; fi
"@
    }
    $activeRollback = if ($currentExists) {
        @"
    cp $qCurrentBackup $qRestoreDev && test "`$(veq_sha $qRestoreDev)" = $qCurrent && mv -f $qRestoreDev $qDev && chmod 0644 $qDev && test "`$(veq_sha $qDev)" = $qCurrent || veq_restore_status=1
"@
    } else {
        "    rm -f $qDev && test ! -e $qDev || veq_restore_status=1"
    }
    return @"
$prelude
# VEQ_DEPLOY_ATOMIC_COMMIT
for veq_leaf in $qStage $qPrevious $qPreviousSha; do veq_reject_symlink "`$veq_leaf"; done
test "`$(veq_sha $qStage)" = $qCandidate || exit 83
test ! -e $(ConvertTo-ShLiteral $State.ManagedPath) && test ! -L $(ConvertTo-ShLiteral $State.ManagedPath) || exit 83
for veq_temp in $qTemps; do test ! -e "`$veq_temp" && test ! -L "`$veq_temp" || exit 84; done
$currentPreparation
veq_had_previous=0
veq_had_sidecar=0
veq_candidate_committed=0
veq_previous_changed=0
veq_sidecar_changed=0
if [ -e $qPrevious ]; then
  test -f $qPrevious || exit 91
  cp $qPrevious $qOldPrevious
  test "`$(veq_sha $qOldPrevious)" = "`$(veq_sha $qPrevious)" || exit 91
  veq_had_previous=1
fi
if [ -e $qPreviousSha ]; then
  test -f $qPreviousSha || exit 92
  cp $qPreviousSha $qOldSidecar
  test "`$(veq_sha $qOldSidecar)" = "`$(veq_sha $qPreviousSha)" || exit 92
  veq_had_sidecar=1
fi
veq_deploy_rollback() {
  veq_restore_status=0
  if [ "`$veq_candidate_committed" = 1 ]; then
$activeRollback
  fi
  if [ "`$veq_previous_changed" = 1 ]; then
    if [ "`$veq_had_previous" = 1 ]; then
      cp $qOldPrevious $qRestorePrevious && test "`$(veq_sha $qRestorePrevious)" = "`$(veq_sha $qOldPrevious)" && mv -f $qRestorePrevious $qPrevious && test "`$(veq_sha $qPrevious)" = "`$(veq_sha $qOldPrevious)" || veq_restore_status=1
    else
      rm -f $qPrevious && test ! -e $qPrevious || veq_restore_status=1
    fi
  fi
  if [ "`$veq_sidecar_changed" = 1 ]; then
    if [ "`$veq_had_sidecar" = 1 ]; then
      cp $qOldSidecar $qRestoreSidecar && test "`$(veq_sha $qRestoreSidecar)" = "`$(veq_sha $qOldSidecar)" && mv -f $qRestoreSidecar $qPreviousSha && test "`$(veq_sha $qPreviousSha)" = "`$(veq_sha $qOldSidecar)" || veq_restore_status=1
    else
      rm -f $qPreviousSha && test ! -e $qPreviousSha || veq_restore_status=1
    fi
  fi
  return "`$veq_restore_status"
}
trap 'veq_status=`$?; trap - 0; if [ "`$veq_status" -ne 0 ]; then veq_clear_commit || exit 109; veq_deploy_rollback || exit 109; fi; exit "`$veq_status"' 0
veq_candidate_committed=1
mv -f $qStage $qDev
chmod 0644 $qDev
test "`$(veq_sha $qDev)" = $qCandidate || exit 86
$previousCommit
veq_record_commit || exit 93
trap - 0
"@
}

function New-RollbackTransactionCommand {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][string] $CurrentSha256,
        [Parameter(Mandatory)][string] $PreviousSha256,
        [Parameter(Mandatory)][string] $Previous,
        [Parameter(Mandatory)][string] $PreviousShaFile,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $current = Assert-Sha256Value $CurrentSha256
    $expected = Assert-Sha256Value $PreviousSha256
    $null = Assert-TransactionId $TransactionId
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $State.InstancesSha256 `
            -TransactionId $TransactionId -Operation 'rollback'
    $null = Assert-AndroidPathContained -Path $Previous -Roots @($State.StateDir)
    $null = Assert-AndroidPathContained -Path $PreviousShaFile -Roots @($State.StateDir)
    $currentBackup = Assert-AndroidPathContained -Path "$($State.StateDir)/rollback-current-$TransactionId.bak" -Roots @($State.StateDir)
    $candidateBackup = Assert-AndroidPathContained -Path "$($State.StateDir)/rollback-candidate-$TransactionId.bak" -Roots @($State.StateDir)
    $sidecarBackup = Assert-AndroidPathContained -Path "$($State.StateDir)/rollback-sidecar-$TransactionId.bak" -Roots @($State.StateDir)
    $candidateStage = Assert-AndroidPathContained -Path "$($State.ModsDir)/.veq-rollback-$TransactionId.tmp" -Roots @($State.ModsDir)
    $newPrevious = Assert-AndroidPathContained -Path "$($State.StateDir)/rollback-new-previous-$TransactionId.tmp" -Roots @($State.StateDir)
    $newSidecar = Assert-AndroidPathContained -Path "$($State.StateDir)/rollback-new-previous-$TransactionId.sha.tmp" -Roots @($State.StateDir)
    $restoreDev = Assert-AndroidPathContained -Path "$($State.ModsDir)/.veq-rollback-restore-$TransactionId.tmp" -Roots @($State.ModsDir)
    $restorePrevious = Assert-AndroidPathContained -Path "$($State.StateDir)/rollback-restore-previous-$TransactionId.tmp" -Roots @($State.StateDir)
    $restoreSidecar = Assert-AndroidPathContained -Path "$($State.StateDir)/rollback-restore-sidecar-$TransactionId.tmp" -Roots @($State.StateDir)
    $qDev = ConvertTo-ShLiteral $State.DevPath
    $qPrevious = ConvertTo-ShLiteral $Previous
    $qPreviousSha = ConvertTo-ShLiteral $PreviousShaFile
    $qCurrent = ConvertTo-ShLiteral $current
    $qExpected = ConvertTo-ShLiteral $expected
    $qCurrentBackup = ConvertTo-ShLiteral $currentBackup
    $qCandidateBackup = ConvertTo-ShLiteral $candidateBackup
    $qSidecarBackup = ConvertTo-ShLiteral $sidecarBackup
    $qCandidateStage = ConvertTo-ShLiteral $candidateStage
    $qNewPrevious = ConvertTo-ShLiteral $newPrevious
    $qNewSidecar = ConvertTo-ShLiteral $newSidecar
    $qRestoreDev = ConvertTo-ShLiteral $restoreDev
    $qRestorePrevious = ConvertTo-ShLiteral $restorePrevious
    $qRestoreSidecar = ConvertTo-ShLiteral $restoreSidecar
    $qTemps = (@(
        $currentBackup, $candidateBackup, $sidecarBackup, $candidateStage,
        $newPrevious, $newSidecar, $restoreDev, $restorePrevious, $restoreSidecar
    ) | ForEach-Object { ConvertTo-ShLiteral $_ }) -join ' '
    return @"
$prelude
# VEQ_ROLLBACK_ATOMIC_COMMIT
for veq_leaf in $qPrevious $qPreviousSha; do veq_reject_symlink "`$veq_leaf"; done
test "`$(veq_sha $qDev)" = $qCurrent || exit 90
test "`$(veq_sha $qPrevious)" = $qExpected || exit 91
test "`$(cat $qPreviousSha | tr 'a-f' 'A-F' | tr -d '\r\n')" = $qExpected || exit 92
for veq_temp in $qTemps; do test ! -e "`$veq_temp" && test ! -L "`$veq_temp" || exit 93; done
cp $qDev $qCurrentBackup
cp $qPrevious $qCandidateBackup
cp $qPreviousSha $qSidecarBackup
test "`$(veq_sha $qCurrentBackup)" = $qCurrent || exit 94
test "`$(veq_sha $qCandidateBackup)" = $qExpected || exit 95
test "`$(veq_sha $qSidecarBackup)" = "`$(veq_sha $qPreviousSha)" || exit 96
cp $qCandidateBackup $qCandidateStage
cp $qCurrentBackup $qNewPrevious
printf '%s\n' $qCurrent > $qNewSidecar
test "`$(veq_sha $qCandidateStage)" = $qExpected || exit 97
test "`$(veq_sha $qNewPrevious)" = $qCurrent || exit 98
test "`$(cat $qNewSidecar | tr -d '\r\n')" = $qCurrent || exit 99
veq_active_changed=0
veq_previous_changed=0
veq_sidecar_changed=0
veq_rollback_restore() {
  veq_restore_status=0
  if [ "`$veq_active_changed" = 1 ]; then
    cp $qCurrentBackup $qRestoreDev && test "`$(veq_sha $qRestoreDev)" = $qCurrent && mv -f $qRestoreDev $qDev && chmod 0644 $qDev && test "`$(veq_sha $qDev)" = $qCurrent || veq_restore_status=1
  fi
  if [ "`$veq_previous_changed" = 1 ]; then
    cp $qCandidateBackup $qRestorePrevious && test "`$(veq_sha $qRestorePrevious)" = $qExpected && mv -f $qRestorePrevious $qPrevious && test "`$(veq_sha $qPrevious)" = $qExpected || veq_restore_status=1
  fi
  if [ "`$veq_sidecar_changed" = 1 ]; then
    cp $qSidecarBackup $qRestoreSidecar && test "`$(veq_sha $qRestoreSidecar)" = "`$(veq_sha $qSidecarBackup)" && mv -f $qRestoreSidecar $qPreviousSha && test "`$(veq_sha $qPreviousSha)" = "`$(veq_sha $qSidecarBackup)" || veq_restore_status=1
  fi
  return "`$veq_restore_status"
}
trap 'veq_status=`$?; trap - 0; if [ "`$veq_status" -ne 0 ]; then veq_clear_commit || exit 119; veq_rollback_restore || exit 119; fi; exit "`$veq_status"' 0
veq_active_changed=1
mv -f $qCandidateStage $qDev
chmod 0644 $qDev
test "`$(veq_sha $qDev)" = $qExpected || exit 100
veq_previous_changed=1
mv -f $qNewPrevious $qPrevious
test "`$(veq_sha $qPrevious)" = $qCurrent || exit 101
veq_sidecar_changed=1
mv -f $qNewSidecar $qPreviousSha
test "`$(cat $qPreviousSha | tr -d '\r\n')" = $qCurrent || exit 102
veq_record_commit || exit 103
trap - 0
"@
}

function New-RestoreManagedFilesCommand {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $null = Assert-TransactionId $TransactionId
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $State.InstancesSha256 `
            -TransactionId $TransactionId -Operation 'restore-files'
    $qManaged = ConvertTo-ShLiteral $State.ManagedPath
    $qDev = ConvertTo-ShLiteral $State.DevPath
    $qExpectedManaged = ConvertTo-ShLiteral $script:ExpectedManagedSha256
    $managedStage = Assert-AndroidPathContained -Path "$($State.ModsDir)/.veq-managed-$TransactionId.tmp" -Roots @($State.ModsDir)
    $retiredStage = Assert-AndroidPathContained -Path "$($State.StateDir)/retired-$TransactionId.tmp" -Roots @($State.StateDir)
    $restoreDev = Assert-AndroidPathContained -Path "$($State.ModsDir)/.veq-restore-dev-$TransactionId.tmp" -Roots @($State.ModsDir)
    $qManagedStage = ConvertTo-ShLiteral $managedStage
    $qRetiredStage = ConvertTo-ShLiteral $retiredStage
    $qRestoreDev = ConvertTo-ShLiteral $restoreDev
    $qTemps = (@($managedStage, $retiredStage, $restoreDev) |
            ForEach-Object { ConvertTo-ShLiteral $_ }) -join ' '

    $managedPrepare = if ($Plan.ManagedWasPresent) {
        'test "$(veq_sha ' + $qManaged + ')" = ' + $qExpectedManaged + ' || exit 121'
    } elseif ($Plan.ManagedCreated) {
        $qBackup = ConvertTo-ShLiteral $Plan.ManagedBackup
        @"
veq_reject_symlink $qBackup
test ! -e $qManaged && test ! -L $qManaged || exit 121
test "`$(veq_sha $qBackup)" = $qExpectedManaged || exit 122
cp $qBackup $qManagedStage
test "`$(veq_sha $qManagedStage)" = $qExpectedManaged || exit 123
veq_managed_created=1
mv -f $qManagedStage $qManaged
chmod 0644 $qManaged
test "`$(veq_sha $qManaged)" = $qExpectedManaged || exit 124
"@
    } else {
        "test ! -e $qManaged && test ! -L $qManaged || exit 121"
    }

    $devRetire = if ($Plan.DevWasPresent) {
        $devSha = Assert-Sha256Value $Plan.DevSha256
        $qDevSha = ConvertTo-ShLiteral $devSha
        $qRetired = ConvertTo-ShLiteral $Plan.Retired
        $retiredPrepare = if ($Plan.RetiredExists) {
            'veq_reject_symlink ' + $qRetired + [Environment]::NewLine +
                    'test "$(veq_sha ' + $qRetired + ')" = ' + $qDevSha + ' || exit 125'
        } else {
        @"
veq_reject_symlink $qRetired
test ! -e $qRetired && test ! -L $qRetired || exit 125
cp $qDev $qRetiredStage
test "`$(veq_sha $qRetiredStage)" = $qDevSha || exit 126
mv -f $qRetiredStage $qRetired
test "`$(veq_sha $qRetired)" = $qDevSha || exit 127
"@
        }
        @"
test "`$(veq_sha $qDev)" = $qDevSha || exit 125
$retiredPrepare
veq_dev_retired=1
rm -f $qDev
test ! -e $qDev || exit 128
"@
    } else {
        "test ! -e $qDev && test ! -L $qDev || exit 125"
    }

    $devRollback = if ($Plan.DevWasPresent) {
        $qRetired = ConvertTo-ShLiteral $Plan.Retired
        $qDevSha = ConvertTo-ShLiteral (Assert-Sha256Value $Plan.DevSha256)
        @"
    cp $qRetired $qRestoreDev && test "`$(veq_sha $qRestoreDev)" = $qDevSha && mv -f $qRestoreDev $qDev && chmod 0644 $qDev && test "`$(veq_sha $qDev)" = $qDevSha || veq_restore_status=1
"@
    } else {
        '# development JAR was originally absent'
    }

    return @"
$prelude
# VEQ_RESTORE_FILES_TRANSACTION
for veq_temp in $qTemps; do test ! -e "`$veq_temp" && test ! -L "`$veq_temp" || exit 120; done
veq_managed_created=0
veq_dev_retired=0
veq_restore_files_rollback() {
  veq_restore_status=0
  if [ "`$veq_dev_retired" = 1 ]; then
$devRollback
  fi
  if [ "`$veq_managed_created" = 1 ]; then
    rm -f $qManaged && test ! -e $qManaged || veq_restore_status=1
  fi
  return "`$veq_restore_status"
}
trap 'veq_status=`$?; trap - 0; if [ "`$veq_status" -ne 0 ]; then veq_clear_commit || exit 139; veq_restore_files_rollback || exit 139; fi; exit "`$veq_status"' 0
$managedPrepare
$devRetire
veq_record_commit || exit 129
trap - 0
"@
}

function Commit-RestoreManagedFiles {
    param(
        [Parameter(Mandatory)] $State,
        [AllowNull()][string] $ManagedBackup,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $managedWasPresent = Test-RemoteFile $State.ManagedPath
    if ($managedWasPresent -and (Get-DeviceSha256 $State.ManagedPath) -ne $script:ExpectedManagedSha256) {
        throw 'The existing managed VEQ path has an unexpected hash.'
    }
    $hasManagedBackup = -not [string]::IsNullOrWhiteSpace($ManagedBackup)
    if (-not $managedWasPresent -and $hasManagedBackup -and
            (Get-DeviceSha256 $ManagedBackup) -ne $script:ExpectedManagedSha256) {
        throw 'The stored managed VEQ baseline no longer matches the lock.'
    }
    $devWasPresent = Test-RemoteFile $State.DevPath
    $devSha = if ($devWasPresent) { Get-DeviceSha256 $State.DevPath } else { $null }
    $retired = if ($devWasPresent) {
        Assert-AndroidPathContained `
                -Path "$($State.StateDir)/retired-$($devSha.Substring(0, 12)).bin" -Roots @($State.StateDir)
    } else {
        $null
    }
    $retiredExists = $devWasPresent -and (Test-RemoteFile $retired)
    if ($retiredExists -and (Get-DeviceSha256 $retired) -ne $devSha) {
        throw 'A conflicting retired VEQ backup already exists.'
    }
    $plan = [pscustomobject]@{
        ManagedWasPresent = $managedWasPresent
        ManagedBackup = $ManagedBackup
        ManagedCreated = -not $managedWasPresent -and $hasManagedBackup
        DevWasPresent = $devWasPresent
        DevSha256 = $devSha
        Retired = $retired
        RetiredExists = $retiredExists
        LauncherReconciliationRequired = -not $managedWasPresent -and -not $hasManagedBackup
    }
    $command = New-RestoreManagedFilesCommand -State $State -Plan $plan -TransactionId $TransactionId
    $cleanup = @(
        "$($State.ModsDir)/.veq-managed-$TransactionId.tmp",
        "$($State.StateDir)/retired-$TransactionId.tmp",
        "$($State.ModsDir)/.veq-restore-dev-$TransactionId.tmp"
    )
    try {
        Assert-AppStopped
        Invoke-DeviceTransaction -State $State -TransactionId $TransactionId `
                -Operation 'restore-files' -Command $command -Mode $Mode | Out-Null
        return $plan
    } finally {
        Remove-RemoteFiles -Paths $cleanup -Mode $Mode
    }
}

function New-UndoRestoreManagedFilesCommand {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Commit,
        [Parameter(Mandatory)][string] $ExpectedInstancesSha256,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $expectedInstances = Assert-Sha256Value $ExpectedInstancesSha256
    $null = Assert-TransactionId $TransactionId
    $prelude = Get-TransactionPrelude -State $State -InstancesSha256 $expectedInstances `
            -TransactionId $TransactionId -Operation 'undo-restore'
    $qManaged = ConvertTo-ShLiteral $State.ManagedPath
    $qDev = ConvertTo-ShLiteral $State.DevPath
    $qExpectedManaged = ConvertTo-ShLiteral $script:ExpectedManagedSha256
    $restoreDev = Assert-AndroidPathContained -Path "$($State.ModsDir)/.veq-undo-dev-$TransactionId.tmp" -Roots @($State.ModsDir)
    $managedBackup = Assert-AndroidPathContained -Path "$($State.StateDir)/undo-managed-$TransactionId.bak" -Roots @($State.StateDir)
    $managedRestore = Assert-AndroidPathContained -Path "$($State.ModsDir)/.veq-undo-managed-$TransactionId.tmp" -Roots @($State.ModsDir)
    $qRestoreDev = ConvertTo-ShLiteral $restoreDev
    $qManagedBackup = ConvertTo-ShLiteral $managedBackup
    $qManagedRestore = ConvertTo-ShLiteral $managedRestore
    $qTemps = (@($restoreDev, $managedBackup, $managedRestore) |
            ForEach-Object { ConvertTo-ShLiteral $_ }) -join ' '
    $managedPrepare = if ($Commit.ManagedCreated) {
        @"
test "`$(veq_sha $qManaged)" = $qExpectedManaged || exit 141
cp $qManaged $qManagedBackup
test "`$(veq_sha $qManagedBackup)" = $qExpectedManaged || exit 142
"@
    } elseif ($Commit.ManagedWasPresent) {
        'test "$(veq_sha ' + $qManaged + ')" = ' + $qExpectedManaged + ' || exit 141'
    } else {
        "test ! -e $qManaged && test ! -L $qManaged || exit 141"
    }
    $devPrepare = if ($Commit.DevWasPresent) {
        $qRetired = ConvertTo-ShLiteral $Commit.Retired
        $qDevSha = ConvertTo-ShLiteral (Assert-Sha256Value $Commit.DevSha256)
        @"
veq_reject_symlink $qRetired
test ! -e $qDev && test ! -L $qDev || exit 143
test "`$(veq_sha $qRetired)" = $qDevSha || exit 144
cp $qRetired $qRestoreDev
test "`$(veq_sha $qRestoreDev)" = $qDevSha || exit 145
"@
    } else {
        "test ! -e $qDev && test ! -L $qDev || exit 143"
    }
    $removeManaged = if ($Commit.ManagedCreated) {
        @"
veq_managed_removed=1
rm -f $qManaged
test ! -e $qManaged || exit 146
"@
    } else {
        '# managed JAR already had its original state'
    }
    $restoreDevCommit = if ($Commit.DevWasPresent) {
        $qDevSha = ConvertTo-ShLiteral (Assert-Sha256Value $Commit.DevSha256)
        @"
veq_dev_restored=1
mv -f $qRestoreDev $qDev
chmod 0644 $qDev
test "`$(veq_sha $qDev)" = $qDevSha || exit 147
"@
    } else {
        '# development JAR was originally absent'
    }
    return @"
$prelude
# VEQ_RESTORE_FILES_ROLLBACK
for veq_temp in $qTemps; do test ! -e "`$veq_temp" && test ! -L "`$veq_temp" || exit 140; done
$managedPrepare
$devPrepare
veq_managed_removed=0
veq_dev_restored=0
veq_undo_restore_rollback() {
  veq_restore_status=0
  if [ "`$veq_dev_restored" = 1 ]; then
    rm -f $qDev && test ! -e $qDev || veq_restore_status=1
  fi
  if [ "`$veq_managed_removed" = 1 ]; then
    cp $qManagedBackup $qManagedRestore && test "`$(veq_sha $qManagedRestore)" = $qExpectedManaged && mv -f $qManagedRestore $qManaged && chmod 0644 $qManaged && test "`$(veq_sha $qManaged)" = $qExpectedManaged || veq_restore_status=1
  fi
  return "`$veq_restore_status"
}
trap 'veq_status=`$?; trap - 0; if [ "`$veq_status" -ne 0 ]; then veq_clear_commit || exit 159; veq_undo_restore_rollback || exit 159; fi; exit "`$veq_status"' 0
$removeManaged
$restoreDevCommit
veq_record_commit || exit 148
trap - 0
"@
}

function Undo-RestoreManagedFiles {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Commit,
        [Parameter(Mandatory)][string] $ExpectedInstancesSha256,
        [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $Mode,
        [Parameter(Mandatory)][string] $TransactionId
    )

    $command = New-UndoRestoreManagedFilesCommand -State $State -Commit $Commit `
            -ExpectedInstancesSha256 $ExpectedInstancesSha256 -TransactionId $TransactionId
    $cleanup = @(
        "$($State.ModsDir)/.veq-undo-dev-$TransactionId.tmp",
        "$($State.StateDir)/undo-managed-$TransactionId.bak",
        "$($State.ModsDir)/.veq-undo-managed-$TransactionId.tmp"
    )
    try {
        Assert-AppStopped
        Invoke-DeviceTransaction -State $State -TransactionId $TransactionId `
                -Operation 'undo-restore' -Command $command -Mode $Mode | Out-Null
    } finally {
        Remove-RemoteFiles -Paths $cleanup -Mode $Mode
    }
}

function Show-Status {
    $state = Read-InstanceState
    $managed = Get-RemoteJarInfo $state.ManagedPath
    $dev = Get-RemoteJarInfo $state.DevPath
    [pscustomobject]@{
        Package = $Package
        Profile = $Profile
        GameDir = $state.GameDir
        InstancesSha256 = $state.InstancesSha256
        ManagedSlugDisabled = $state.Disabled
        ManagedProjectTracked = $state.ManagedProjectPresent
        ManagedFile = if ($null -eq $managed) { 'absent' } else { $managed.Path }
        ManagedVersion = if ($null -eq $managed) { $null } else { $managed.Version }
        ManagedSha256 = if ($null -eq $managed) { $null } else { $managed.Sha256 }
        DevFile = if ($null -eq $dev) { 'absent' } else { $dev.Path }
        DevVersion = if ($null -eq $dev) { $null } else { $dev.Version }
        DevSha256 = if ($null -eq $dev) { $null } else { $dev.Sha256 }
        ContractManagedVersion = $script:ExpectedManagedVersion
        ContractManagedSha256 = $script:ExpectedManagedSha256
    }
}

function Enable-DevMode {
    Assert-AppStopped
    $initial = Read-InstanceState
    $mode = Resolve-WriteMode -ProbeDirectories @($script:DeviceRoot, $initial.GameDir, $initial.ModsDir)
    $lock = Enter-DeviceMutationLock -State $initial -Mode $mode
    try {
        Assert-AppStopped
        $state = Read-InstanceState
        $state = Set-StateMutationLockContract -State $state -Lock $lock
        if ($state.InstancesSha256 -ne $initial.InstancesSha256) {
            throw 'instances.json changed before EnableDev acquired its transaction lock.'
        }
        $transactionId = New-TransactionId
        $managedWasPresent = Test-RemoteFile $state.ManagedPath
        $managedBackup = Ensure-ManagedBackup -State $state -Mode $mode -TransactionId $transactionId
        $change = $null
        if (-not $state.Disabled) {
            Set-DisabledState -State $state -Disabled $true
            $change = Write-InstancesAtomically -State $state -Mode $mode -TransactionId $transactionId
            $state = Read-InstanceState
            $state = Set-StateMutationLockContract -State $state -Lock $lock
        }
        try {
            Remove-ManagedJarAfterDisable -State $state -ManagedBackup $managedBackup `
                    -Mode $mode -TransactionId $transactionId
        } catch {
            $originalFailure = $_
            $rollbackFailures = New-Object System.Collections.Generic.List[string]
            $managedReadyForJsonRollback = $true
            if ($managedWasPresent) {
                try {
                    Restore-ManagedJarAfterEnableFailure -State $state -ManagedBackup $managedBackup `
                            -Mode $mode -TransactionId $transactionId
                } catch {
                    $managedReadyForJsonRollback = $false
                    $rollbackFailures.Add("managed JAR: $($_.Exception.Message)")
                }
            }
            if ($managedReadyForJsonRollback -and $null -ne $change) {
                try {
                    Restore-InstancesBackup -State $state -Change $change -Mode $mode `
                            -TransactionId $transactionId
                } catch {
                    $rollbackFailures.Add("instances.json: $($_.Exception.Message)")
                }
            }
            if ($rollbackFailures.Count -gt 0) {
                throw "EnableDev failed ($($originalFailure.Exception.Message)); rollback also failed: $($rollbackFailures -join ' | ')"
            }
            throw $originalFailure
        }
        $verified = Read-InstanceState
        if (-not $verified.Disabled -or (Test-RemoteFile $verified.ManagedPath)) {
            throw 'EnableDev did not commit a disabled slug with the managed JAR outside mods.'
        }
        [pscustomobject]@{
            Action = 'EnableDev'
            GameDir = $verified.GameDir
            ManagedSlugDisabled = $verified.Disabled
            InstancesBefore = if ($null -eq $change) { $verified.InstancesSha256 } else { $change.Before }
            InstancesAfter = $verified.InstancesSha256
            InstancesBackup = if ($null -eq $change) { $null } else { $change.Backup }
            ManagedJarBackup = $managedBackup
            DevDestination = $verified.DevPath
            WriteMode = $mode
        }
    } finally {
        Exit-DeviceMutationLock -Lock $lock
    }
}

function Deploy-DevJar {
    if ([string]::IsNullOrWhiteSpace($JarPath)) {
        throw '-JarPath is required for Deploy.'
    }
    $candidate = Get-FabricJarInfo $JarPath
    Assert-AppStopped
    $initial = Read-InstanceState
    $mode = Resolve-WriteMode -ProbeDirectories @($initial.GameDir, $initial.ModsDir)
    $lock = Enter-DeviceMutationLock -State $initial -Mode $mode
    $transactionId = New-TransactionId
    $cleanup = New-Object System.Collections.Generic.List[string]
    try {
        Assert-AppStopped
        $state = Read-InstanceState
        $state = Set-StateMutationLockContract -State $state -Lock $lock
        if ($state.InstancesSha256 -ne $initial.InstancesSha256) {
            throw 'instances.json changed before Deploy acquired its transaction lock.'
        }
        if (-not $state.Disabled) {
            throw 'Run EnableDev first. Deploy will not silently alter instances.json.'
        }
        $managedBackup = Ensure-ManagedBackup -State $state -Mode $mode -TransactionId $transactionId
        Remove-ManagedJarAfterDisable -State $state -ManagedBackup $managedBackup `
                -Mode $mode -TransactionId $transactionId

        $stage = "$($state.StateDir)/candidate-$transactionId.tmp"
        $previous = "$($state.StateDir)/previous.bin"
        $previousShaFile = "$($state.StateDir)/previous.sha256"
        $cleanup.Add($stage)
        foreach ($path in @(
            "$($state.StateDir)/active-$transactionId.bak",
            "$($state.StateDir)/old-previous-$transactionId.bak",
            "$($state.StateDir)/old-previous-$transactionId.sha",
            "$($state.StateDir)/new-previous-$transactionId.tmp",
            "$($state.StateDir)/new-previous-$transactionId.sha.tmp",
            "$($state.ModsDir)/.veq-dev-restore-$transactionId.tmp",
            "$($state.StateDir)/restore-previous-$transactionId.tmp",
            "$($state.StateDir)/restore-previous-$transactionId.sha.tmp"
        )) { $cleanup.Add($path) }
        Push-File -State $state -LocalPath $candidate.Path -RemotePath $stage `
                -ExpectedSha256 $candidate.Sha256 -TransactionId $transactionId -Mode $mode
        if ((Get-DeviceSha256 $stage) -ne $candidate.Sha256) {
            throw 'The uploaded VEQ candidate failed SHA-256 verification.'
        }
        $currentSha = if (Test-RemoteFile $state.DevPath) {
            Get-DeviceSha256 $state.DevPath
        } else {
            $null
        }
        Assert-AppStopped
        $command = New-DeployTransactionCommand -State $state -CandidateSha256 $candidate.Sha256 `
                -Stage $stage -CurrentSha256 $currentSha -Previous $previous `
                -PreviousShaFile $previousShaFile -TransactionId $transactionId
        Invoke-DeviceTransaction -State $state -TransactionId $transactionId `
                -Operation 'deploy' -Command $command -Mode $mode | Out-Null
        $deployed = Get-RemoteJarInfo $state.DevPath
        if ($deployed.Sha256 -ne $candidate.Sha256) {
            throw 'The promoted VEQ JAR does not match the local candidate.'
        }
        [pscustomobject]@{
            Action = 'Deploy'
            Version = $deployed.Version
            Sha256 = $deployed.Sha256
            DevicePath = $deployed.Path
            PreviousAvailable = Test-RemoteFile $previous
            ManagedSlugDisabled = $true
            WriteMode = $mode
            TransactionId = $transactionId
        }
    } finally {
        Remove-RemoteFiles -Paths $cleanup.ToArray() -Mode $mode
        Exit-DeviceMutationLock -Lock $lock
    }
}

function Rollback-DevJar {
    Assert-AppStopped
    $initial = Read-InstanceState
    $mode = Resolve-WriteMode -ProbeDirectories @($initial.GameDir, $initial.ModsDir)
    $lock = Enter-DeviceMutationLock -State $initial -Mode $mode
    $transactionId = New-TransactionId
    $cleanup = New-Object System.Collections.Generic.List[string]
    try {
        Assert-AppStopped
        $state = Read-InstanceState
        $state = Set-StateMutationLockContract -State $state -Lock $lock
        if ($state.InstancesSha256 -ne $initial.InstancesSha256) {
            throw 'instances.json changed before Rollback acquired its transaction lock.'
        }
        if (-not $state.Disabled) {
            throw 'Rollback is available only while the managed VEQ slug is disabled.'
        }
        $previous = "$($state.StateDir)/previous.bin"
        $previousShaFile = "$($state.StateDir)/previous.sha256"
        if (-not (Test-RemoteFile $state.DevPath) -or -not (Test-RemoteFile $previous) -or
                -not (Test-RemoteFile $previousShaFile)) {
            throw 'A complete active/previous VEQ pair is not available.'
        }
        $expectedPrevious = (Get-DeviceText $previousShaFile).Trim().ToUpperInvariant()
        if ($expectedPrevious -notmatch '^[0-9A-F]{64}$' -or
                (Get-DeviceSha256 $previous) -ne $expectedPrevious) {
            throw 'The previous VEQ JAR or its SHA-256 sidecar is invalid.'
        }
        $currentSha = Get-DeviceSha256 $state.DevPath
        foreach ($path in @(
            "$($state.StateDir)/rollback-current-$transactionId.bak",
            "$($state.StateDir)/rollback-candidate-$transactionId.bak",
            "$($state.StateDir)/rollback-sidecar-$transactionId.bak",
            "$($state.ModsDir)/.veq-rollback-$transactionId.tmp",
            "$($state.StateDir)/rollback-new-previous-$transactionId.tmp",
            "$($state.StateDir)/rollback-new-previous-$transactionId.sha.tmp",
            "$($state.ModsDir)/.veq-rollback-restore-$transactionId.tmp",
            "$($state.StateDir)/rollback-restore-previous-$transactionId.tmp",
            "$($state.StateDir)/rollback-restore-sidecar-$transactionId.tmp"
        )) { $cleanup.Add($path) }
        Assert-AppStopped
        $command = New-RollbackTransactionCommand -State $state -CurrentSha256 $currentSha `
                -PreviousSha256 $expectedPrevious -Previous $previous `
                -PreviousShaFile $previousShaFile -TransactionId $transactionId
        Invoke-DeviceTransaction -State $state -TransactionId $transactionId `
                -Operation 'rollback' -Command $command -Mode $mode | Out-Null
        $active = Get-RemoteJarInfo $state.DevPath
        if ($active.Sha256 -ne $expectedPrevious -or
                (Get-DeviceSha256 $previous) -ne $currentSha -or
                (Get-DeviceText $previousShaFile).Trim().ToUpperInvariant() -ne $currentSha) {
            throw 'Rollback did not commit a verified active/previous pair.'
        }
        [pscustomobject]@{
            Action = 'Rollback'
            ActiveVersion = $active.Version
            ActiveSha256 = $active.Sha256
            PreviousSha256 = $currentSha
            DevicePath = $state.DevPath
            WriteMode = $mode
            TransactionId = $transactionId
        }
    } finally {
        Remove-RemoteFiles -Paths $cleanup.ToArray() -Mode $mode
        Exit-DeviceMutationLock -Lock $lock
    }
}

function Restore-ManagedMode {
    Assert-AppStopped
    $initial = Read-InstanceState
    $mode = Resolve-WriteMode -ProbeDirectories @($script:DeviceRoot, $initial.GameDir, $initial.ModsDir)
    $lock = Enter-DeviceMutationLock -State $initial -Mode $mode
    $transactionId = New-TransactionId
    try {
        Assert-AppStopped
        $state = Read-InstanceState
        $state = Set-StateMutationLockContract -State $state -Lock $lock
        if ($state.InstancesSha256 -ne $initial.InstancesSha256) {
            throw 'instances.json changed before RestoreManaged acquired its transaction lock.'
        }
        $managedBackup = Ensure-ManagedBackup -State $state -Mode $mode -TransactionId $transactionId
        $fileCommit = Commit-RestoreManagedFiles -State $state -ManagedBackup $managedBackup `
                -Mode $mode -TransactionId $transactionId
        $change = $null
        try {
            if ($state.Disabled) {
                Set-DisabledState -State $state -Disabled $false
                $change = Write-InstancesAtomically -State $state -Mode $mode -TransactionId $transactionId
            }
            $final = Read-InstanceState
            if ($final.Disabled -or (Test-RemoteFile $final.DevPath)) {
                throw 'RestoreManaged did not commit the managed profile state.'
            }
            $managedPresent = Test-RemoteFile $final.ManagedPath
            if (-not $fileCommit.LauncherReconciliationRequired -and
                    (-not $managedPresent -or
                        (Get-DeviceSha256 $final.ManagedPath) -ne $script:ExpectedManagedSha256)) {
                throw 'RestoreManaged did not leave the verified managed baseline active.'
            }
        } catch {
            $originalFailure = $_
            $rollbackFailures = New-Object System.Collections.Generic.List[string]
            $instancesReadyForFileUndo = $true
            if ($null -ne $change) {
                try {
                    Restore-InstancesBackup -State $state -Change $change -Mode $mode `
                            -TransactionId $transactionId
                } catch {
                    $instancesReadyForFileUndo = $false
                    $rollbackFailures.Add("instances.json: $($_.Exception.Message)")
                }
            }
            if ($instancesReadyForFileUndo) {
                try {
                    Undo-RestoreManagedFiles -State $state -Commit $fileCommit `
                            -ExpectedInstancesSha256 $state.InstancesSha256 `
                            -Mode $mode -TransactionId $transactionId
                } catch {
                    $rollbackFailures.Add("managed files: $($_.Exception.Message)")
                }
            }
            if ($rollbackFailures.Count -gt 0) {
                throw "RestoreManaged failed ($($originalFailure.Exception.Message)); rollback also failed: $($rollbackFailures -join ' | ')"
            }
            throw $originalFailure
        }

        $managedPresent = Test-RemoteFile $final.ManagedPath
        [pscustomobject]@{
            Action = 'RestoreManaged'
            ManagedSlugDisabled = $false
            ManagedSha256 = if ($managedPresent) { Get-DeviceSha256 $final.ManagedPath } else { $null }
            RetiredDevJar = $fileCommit.Retired
            InstancesBefore = if ($null -eq $change) { $final.InstancesSha256 } else { $change.Before }
            InstancesAfter = $final.InstancesSha256
            LauncherReconciliationRequired = -not $managedPresent
            WriteMode = $mode
            TransactionId = $transactionId
        }
    } finally {
        Exit-DeviceMutationLock -Lock $lock
    }
}

function Invoke-SelfTest {
    $adbCallsBefore = $script:AdbInvocationCount
    $helperSource = Get-Content -Raw -LiteralPath $PSCommandPath
    if (-not $helperSource.Contains('head -c 512')) {
        throw 'The procfs stopped-app scan is not bounded.'
    }
    $unboundedProcReader = "tr '\000' '\n' " + '<'
    if ($helperSource.Contains($unboundedProcReader)) {
        throw 'An unbounded procfs cmdline reader is present.'
    }
    Resolve-LockContract
    $asset = Join-Path $script:RepoRoot 'Pojlib\src\main\assets\mods\vivecraft-essentials-quest.bin'
    $jar = Get-FabricJarInfo $asset
    if ($jar.Sha256 -ne $script:ExpectedManagedSha256) {
        throw 'The bundled VEQ asset differs from STACK.lock.json.'
    }

    $fake = '{"instances":[{"instanceName":"26.2","versionName":"26.2","gameDir":"/sdcard/Android/data/com.qcxr.qcxr.dev262/files/instances/26.2","disabledMods":["Keep-Me","","  ","keep-me","Keep-Me","vivecraft-essentials-quest","VIVECRAFT-ESSENTIALS-QUEST"],"unknown":{"preserve":true}}]}' | ConvertFrom-Json
    $state = [pscustomobject]@{ Instance = $fake.instances[0] }
    $preserved = @('Keep-Me', '', '  ', 'keep-me', 'Keep-Me')
    Set-DisabledState -State $state -Disabled $true
    $expectedEnabled = @($preserved) + @($script:Slug)
    $actualEnabled = @($state.Instance.disabledMods)
    if ($actualEnabled.Count -ne $expectedEnabled.Count) {
        throw 'Self-test changed the number of unrelated disabledMods entries.'
    }
    for ($index = 0; $index -lt $expectedEnabled.Count; $index++) {
        if (-not [string]::Equals([string]$actualEnabled[$index], [string]$expectedEnabled[$index],
                [StringComparison]::Ordinal)) {
            throw "Self-test changed disabledMods entry $index."
        }
    }
    Set-DisabledState -State $state -Disabled $true
    if (@($state.Instance.disabledMods | Where-Object { Test-ManagedSlugValue $_ }).Count -ne 1) {
        throw 'Self-test introduced a duplicate managed slug.'
    }
    Set-DisabledState -State $state -Disabled $false
    $actualDisabled = @($state.Instance.disabledMods)
    if ($actualDisabled.Count -ne $preserved.Count) {
        throw 'Self-test failed to retain every unrelated disabledMods entry.'
    }
    for ($index = 0; $index -lt $preserved.Count; $index++) {
        if (-not [string]::Equals([string]$actualDisabled[$index], [string]$preserved[$index],
                [StringComparison]::Ordinal)) {
            throw "Self-test changed retained disabledMods entry $index."
        }
    }
    $roundTrip = ($fake | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    if (-not $roundTrip.instances[0].unknown.preserve) {
        throw 'Self-test failed to remove the slug while preserving unknown fields.'
    }

    $filesRoot = '/sdcard/Android/data/com.qcxr.qcxr.dev262/files'
    $gameDir = "$filesRoot/instances/26.2"
    if ((Normalize-AndroidAbsolutePath $gameDir) -ne $gameDir -or
            (Assert-AndroidPathContained -Path $gameDir -Roots @($filesRoot)) -ne $gameDir -or
            (Assert-SafeLeafName 'VEQ candidate.jar') -ne 'VEQ candidate.jar') {
        throw 'Safe Android path or leaf validation rejected a valid value.'
    }
    $invalidPathTests = @(
        { Normalize-AndroidAbsolutePath 'relative/path' },
        { Normalize-AndroidAbsolutePath '/safe//child' },
        { Normalize-AndroidAbsolutePath '/safe/../escape' },
        { Normalize-AndroidAbsolutePath "/safe/$([char]1)bad" },
        { Normalize-AndroidAbsolutePath '/safe\child' },
        { Assert-AndroidPathContained -Path '/sdcard/Android/data/com.qcxr.qcxr.dev262/files-evil/x' -Roots @($filesRoot) },
        { Assert-AndroidPathContained -Path $filesRoot -Roots @($filesRoot) },
        { Assert-SafeLeafName '..' },
        { Assert-SafeLeafName 'nested/name' },
        { Assert-SafeLeafName 'nested\name' },
        { Assert-SafeLeafName (('é' * 101)) }
    )
    foreach ($invalidPathTest in $invalidPathTests) {
        if (-not (Test-ExpectedFailure $invalidPathTest)) {
            throw 'Unsafe Android path or leaf name passed validation.'
        }
    }

    $expectedShellLiteral = -join @(
        [char]39, 'a', [char]39, [char]34, [char]39,
        [char]34, [char]39, 'b', [char]39
    )
    if ((ConvertTo-ShLiteral "a'b") -ne $expectedShellLiteral) {
        throw 'POSIX shell literal escaping self-test failed.'
    }

    $transactionId = '0123456789abcdef0123456789abcdef'
    $otherTransactionId = 'fedcba9876543210fedcba9876543210'
    $lockDir = "$gameDir/.questcraft/veq-dev/mutation.lock"
    $lockToken = "$lockDir/token"
    $lockCommand = New-MutationLockAcquireCommand -GameDir $gameDir `
            -StateDir "$gameDir/.questcraft/veq-dev" `
            -LockDir $lockDir -TokenPath $lockToken -Token $transactionId
    $unlockCommand = New-MutationLockReleaseCommand -StateDir "$gameDir/.questcraft/veq-dev" -LockDir $lockDir `
            -TokenPath $lockToken -Token $transactionId
    if ($lockCommand -notmatch [regex]::Escape("mkdir $(ConvertTo-ShLiteral $lockDir)") -or
            $lockCommand -match [regex]::Escape("mkdir -p $(ConvertTo-ShLiteral $lockDir)") -or
            $lockCommand -notmatch [regex]::Escape('# VEQ_LOCK_CANONICAL_GUARD') -or
            $lockCommand -notmatch [regex]::Escape('token.tmp') -or
            $lockCommand -notmatch [regex]::Escape('veq_lock_cleanup') -or
            $lockCommand -notmatch [regex]::Escape('veq_lock_age') -or
            $unlockCommand -notmatch [regex]::Escape('test "$(cat ') -or
            $unlockCommand -notmatch $transactionId) {
        throw 'Exclusive mutation-lock command self-test failed.'
    }
    $writeAst = (Get-Command Invoke-DeviceWriteShell -CommandType Function).ScriptBlock.Ast
    $writeShellCalls = @($writeAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Invoke-DeviceShell'
    }, $true))
    if ($writeShellCalls.Count -ne 1 -or
            $writeAst.Extent.Text -match '\$AllowRootFallback') {
        throw 'A write transport could retry a partially executed compound command.'
    }

    $shaA = 'A' * 64
    $shaB = 'B' * 64
    $offlineState = [pscustomobject]@{
        FilesDir = $filesRoot
        InstancesPath = "$filesRoot/instances.json"
        GameDir = $gameDir
        ModsDir = "$gameDir/mods"
        StateDir = "$gameDir/.questcraft/veq-dev"
        ManagedPath = "$gameDir/mods/Vivecraft-Essentials-Quest.jar"
        DevPath = "$gameDir/mods/veq-dev.jar"
        InstancesSha256 = $shaA
    }
    $offlineLock = [pscustomobject]@{
        Path = $lockDir
        TokenPath = $lockToken
        Token = $transactionId
    }
    $offlineState = Set-StateMutationLockContract -State $offlineState -Lock $offlineLock
    $previous = "$($offlineState.StateDir)/previous.bin"
    $previousSha = "$($offlineState.StateDir)/previous.sha256"
    $candidateStage = "$($offlineState.StateDir)/candidate-$transactionId.tmp"
    $commands = @(
        New-InstancesCommitCommand -State $offlineState -BeforeSha256 $shaA -AfterSha256 $shaB `
                -RemoteStage "$($offlineState.StateDir)/instances-$transactionId.tmp" `
                -Backup "$($offlineState.StateDir)/backups/instances-$transactionId-$shaA.json" `
                -BackupStage "$($offlineState.StateDir)/backups/instances-$transactionId-$shaA.json.tmp" `
                -RestoreStage "$($offlineState.StateDir)/instances-restore-$transactionId.tmp" `
                -TransactionId $transactionId
        New-InstancesRollbackCommand -State $offlineState -BeforeSha256 $shaA -AfterSha256 $shaB `
                -Backup "$($offlineState.StateDir)/backups/instances-$transactionId-$shaA.json" `
                -RestoreStage "$($offlineState.StateDir)/backups/instances-rollback-$transactionId.tmp" `
                -CurrentStage "$($offlineState.StateDir)/backups/instances-current-$transactionId.tmp" `
                -TransactionId $transactionId
        New-DeployTransactionCommand -State $offlineState -CandidateSha256 $shaB `
                -Stage $candidateStage -CurrentSha256 $shaA -Previous $previous `
                -PreviousShaFile $previousSha -TransactionId $transactionId
        New-DeployTransactionCommand -State $offlineState -CandidateSha256 $shaB `
                -Stage $candidateStage -CurrentSha256 $null -Previous $previous `
                -PreviousShaFile $previousSha -TransactionId $transactionId
        New-RollbackTransactionCommand -State $offlineState -CurrentSha256 $shaA `
                -PreviousSha256 $shaB -Previous $previous -PreviousShaFile $previousSha `
                -TransactionId $transactionId
        New-ManagedRemoveCommand -State $offlineState `
                -ManagedBackup "$($offlineState.StateDir)/managed-v66.bin" `
                -TransactionId $transactionId
    )
    $restorePlan = [pscustomobject]@{
        ManagedWasPresent = $false
        ManagedBackup = "$($offlineState.StateDir)/managed-$($script:ExpectedManagedSha256.Substring(0, 16)).bin"
        ManagedCreated = $true
        DevWasPresent = $true
        DevSha256 = $shaB
        Retired = "$($offlineState.StateDir)/retired-$($shaB.Substring(0, 12)).bin"
        RetiredExists = $false
        LauncherReconciliationRequired = $false
    }
    $commands += New-RestoreManagedFilesCommand -State $offlineState -Plan $restorePlan `
            -TransactionId $transactionId
    $commands += New-UndoRestoreManagedFilesCommand -State $offlineState -Commit $restorePlan `
            -ExpectedInstancesSha256 $shaA -TransactionId $transactionId
    $instancesCasNeedle = 'test "$(veq_sha ' + (ConvertTo-ShLiteral $offlineState.InstancesPath) + ')"'
    foreach ($command in $commands) {
        if ($command -notmatch [regex]::Escape("# $script:TransactionMarker") -or
                $command -notmatch [regex]::Escape('# VEQ_APP_STOPPED_GUARD') -or
                $command -notmatch [regex]::Escape('# VEQ_CANONICAL_MUTATION_GUARD') -or
                $command -notmatch [regex]::Escape($transactionId) -or
                $command -match [regex]::Escape($otherTransactionId) -or
                $command -notmatch [regex]::Escape($instancesCasNeedle) -or
                $command -notmatch [regex]::Escape("cat $(ConvertTo-ShLiteral $lockToken)") -or
                $command -notmatch [regex]::Escape('veq_record_commit') -or
                $command -notmatch [regex]::Escape('trap - 0')) {
            throw 'Offline transaction command lacks its app guard, CAS, unique id, or rollback trap.'
        }
    }
    $enableText = (Get-Command Enable-DevMode -CommandType Function).ScriptBlock.Ast.Extent.Text
    $managedCompensationIndex = $enableText.IndexOf('Restore-ManagedJarAfterEnableFailure', [StringComparison]::Ordinal)
    $instancesCompensationIndex = $enableText.IndexOf('Restore-InstancesBackup', [StringComparison]::Ordinal)
    if ($managedCompensationIndex -lt 0 -or $instancesCompensationIndex -lt 0 -or
            $managedCompensationIndex -ge $instancesCompensationIndex) {
        throw 'EnableDev does not compensate the managed JAR before instances.json.'
    }
    $pushText = (Get-Command Push-File -CommandType Function).ScriptBlock.Ast.Extent.Text
    if ($pushText -notmatch [regex]::Escape('/data/local/tmp/quest-veq-upload-') -or
            $pushText -notmatch [regex]::Escape('# VEQ_TRANSPORT_STAGE_IMPORT') -or
            $pushText -match 'cp\s+[^\r\n]+\$RemotePath') {
        throw 'Upload staging could copy directly into an unverified destination leaf.'
    }
    if ((New-TransactionId) -eq (New-TransactionId)) {
        throw 'Transaction identifiers were not unique.'
    }
    if ($script:AdbInvocationCount -ne $adbCallsBefore) {
        throw 'SelfTest invoked ADB or touched a device.'
    }

    [pscustomobject]@{
        Result = 'PASS'
        Actions = 'Status, EnableDev, Deploy, Rollback, RestoreManaged'
        ModId = $jar.Id
        ManagedVersion = $jar.Version
        ManagedSha256 = $jar.Sha256
        JsonRoundTripPreservesUnknownFields = $true
        PreservesUnrelatedDisabledModsExactly = $true
        PathContainmentAndLeafValidation = $true
        ExclusiveLockAndUniqueStages = $true
        TokenFailureRecoveryAndEnableCompensation = $true
        CanonicalTransactionGuardAndNoSymlinkLeaves = $true
        DurableCommitMarkerWithoutReplay = $true
        CasAppGuardAndTransactionalRollback = $true
        PartialRootRetryPrevented = $true
        DeviceTouched = $false
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    return
}

Resolve-LockContract
$script:ResolvedAdb = Resolve-Adb
$script:ResolvedSerial = Resolve-DeviceSerial
Assert-DeviceReady

switch ($Action) {
    'Status' { Show-Status }
    'EnableDev' { Enable-DevMode }
    'Deploy' { Deploy-DevJar }
    'Rollback' { Rollback-DevJar }
    'RestoreManaged' { Restore-ManagedMode }
}
