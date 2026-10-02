<#
.SYNOPSIS
Creates a fail-closed, read-only pre-upgrade backup of the fixed Stable profile.

.DESCRIPTION
The device side is pinned to com.qcxr.qcxr.dev262 and reads only the Minecraft
26.2 profile roots mods, config, options.txt, saves, Xaero, XaeroWaypoints, and
XaeroWorldMap. Stable must already be stopped. The script never launches,
stops, installs, clears, changes ownership, or writes anything on the headset.

Account/authentication/credential/token-like names are rejected before the
archive is streamed and rejected again by the Host extractor. This is stricter
than silently copying an uncertain file. An unreadable normal-shell stream can
optionally be retried through the explicitly enabled, allowlisted absolute
`/debug_ramdisk/su` binary for a uid-0 preflight and stdout-only tar stream.
Source ownership and permissions are never changed, and no device staging is
created.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Backup')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$')]
    [string] $BackupName = '',

    [switch] $AllowDeviceRead,
    [switch] $AllowRootRead,

    [string] $RootBinaryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.dev262'
$script:ExpectedVersionCode = 69
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.10'
$script:ExpectedBaseApkSha256 = `
    '05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034'
$script:ExpectedSignerSha256 = `
    'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/26.2"
$script:AllowedRoots = @(
    'mods',
    'config',
    'options.txt',
    'saves',
    'Xaero',
    'XaeroWaypoints',
    'XaeroWorldMap'
)
$script:SensitiveNamePattern = '(?i)(account|auth|credential|token)'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BackupRoot = Join-Path $script:RepoRoot 'artifacts\device-config-backups'
$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:ResolvedRootBinaryPath = ''
$script:AdbInvocationCount = 0
$script:AllowedRootBinaryPaths = @('/debug_ramdisk/su')

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Test-ExpectedFailure([Parameter(Mandatory)][scriptblock] $Operation) {
    try {
        & $Operation
        return $false
    } catch {
        return $true
    }
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [string][char]39
    return $quote + $Value.Replace($quote, $quote + '"' + $quote + '"' + $quote) + $quote
}

function Assert-AllowedRootBinaryPath([Parameter(Mandatory)][string] $Path) {
    Require (-not [string]::IsNullOrWhiteSpace($Path)) `
        'The root binary path cannot be empty.'
    Require ($Path.StartsWith('/', [StringComparison]::Ordinal)) `
        'The root binary path must be absolute.'
    Require (-not $Path.Contains('..') -and -not $Path.Contains('\\') -and
            -not $Path.Contains([char]0) -and
            $Path -cmatch '^/[A-Za-z0-9._/-]+$') `
        'The root binary path contains unsafe syntax.'
    Require ($script:AllowedRootBinaryPaths -ccontains $Path) `
        'The root binary path is not in the fixed allowlist.'
    return $Path
}

function Resolve-ValidatedRootConfiguration(
    [Parameter(Mandatory)][bool] $Authorized,
    [AllowEmptyString()][string] $ConfiguredPath
) {
    $hasPath = -not [string]::IsNullOrWhiteSpace($ConfiguredPath)
    if (-not $Authorized -and -not $hasPath) { return '' }
    Require ($Authorized -and $hasPath) `
        'Root fallback requires both -AllowRootRead and -RootBinaryPath.'
    return Assert-AllowedRootBinaryPath $ConfiguredPath
}

function Resolve-RootReadConfiguration {
    $script:ResolvedRootBinaryPath = Resolve-ValidatedRootConfiguration `
        -Authorized $AllowRootRead.IsPresent -ConfiguredPath $RootBinaryPath
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sideQuest = Join-Path $env:LOCALAPPDATA `
        'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw 'ADB was not found. Pass -AdbPath with the full adb.exe path.'
}

function Invoke-ProcessCapture(
    [Parameter(Mandatory)][string] $FileName,
    [Parameter(Mandatory)][string[]] $Arguments,
    [string] $BinaryOutputPath = ''
) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $outputStream = $null
    try {
        Require $process.Start() 'Could not start ADB.'
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ([string]::IsNullOrEmpty($BinaryOutputPath)) {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $process.WaitForExit()
            $stdout = $stdoutTask.GetAwaiter().GetResult()
        } else {
            $outputStream = [IO.FileStream]::new(
                $BinaryOutputPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None,
                1MB,
                [IO.FileOptions]::SequentialScan)
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($outputStream)
            $process.WaitForExit()
            # Task.GetAwaiter().GetResult() exposes VoidTaskResult to the
            # PowerShell pipeline unless explicitly discarded, which would turn
            # this function's result into an array and hide ExitCode/Stderr.
            $null = $copyTask.GetAwaiter().GetResult()
            $outputStream.Flush($true)
            $stdout = $null
        }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        $process.Dispose()
    }
}

function Invoke-AdbText([Parameter(Mandatory)][string[]] $Arguments) {
    $script:AdbInvocationCount++
    Invoke-ProcessCapture -FileName $script:ResolvedAdb -Arguments $Arguments
}

function Invoke-AdbArchive(
    [Parameter(Mandatory)][string[]] $Arguments,
    [Parameter(Mandatory)][string] $OutputPath
) {
    $script:AdbInvocationCount++
    Invoke-ProcessCapture -FileName $script:ResolvedAdb -Arguments $Arguments `
        -BinaryOutputPath $OutputPath
}

function Resolve-Device {
    Require $AllowDeviceRead.IsPresent 'Backup requires explicit -AllowDeviceRead.'
    $script:ResolvedAdb = Resolve-Adb
    $devices = Invoke-AdbText @('devices')
    Require ($devices.ExitCode -eq 0) 'Could not enumerate authorized ADB endpoints.'
    $connected = @($devices.Stdout -split "`r?`n" | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { [string]$Matches.serial }
    })
    if ($Serial -ceq 'auto') {
        Require ($connected.Count -eq 1) `
            'Auto selection requires exactly one authorized ADB endpoint; pass -Serial otherwise.'
        $script:ResolvedSerial = [string]$connected[0]
    } else {
        Require ($connected -ccontains $Serial) 'The requested ADB endpoint is not connected.'
        $script:ResolvedSerial = $Serial
    }

    $features = Invoke-AdbText @('-s', $script:ResolvedSerial, 'features')
    Require ($features.ExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace($features.Stderr)) `
        'Could not verify the device transport features.'
    Assert-ShellV2FeatureResponse $features.Stdout
}

function Assert-ShellV2FeatureResponse([Parameter(Mandatory)][string] $Text) {
    $features = @($Text -split '[,\s]+' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    Require ($features -ccontains 'shell_v2') `
        'The device does not advertise shell_v2; reliable remote exit status is required.'
}

function New-DeviceTransportArguments(
    [Parameter(Mandatory)][string] $Command,
    [ValidateSet('shell', 'root')][string] $Mode = 'shell',
    [string] $RootExecutable = ''
) {
    Require (-not [string]::IsNullOrWhiteSpace($Command)) `
        'The device shell command cannot be empty.'
    Require (-not $Command.Contains([char]0)) `
        'The device shell command cannot contain NUL.'
    Require (-not [string]::IsNullOrWhiteSpace($script:ResolvedSerial)) `
        'The ADB endpoint must be resolved before creating transport arguments.'

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-s', $script:ResolvedSerial, 'shell', '-T')) {
        $arguments.Add($value)
    }
    # `adb shell` joins the remote argv into one device-shell command. Quote the
    # complete -c operand exactly once for that join. Unlike exec-out, shell_v2
    # returns the remote exit status and keeps stderr separate while -T preserves
    # a binary-clean stdout stream. Values inside Command are still individually
    # protected by ConvertTo-ShLiteral at each command-construction site.
    $commandLiteral = ConvertTo-ShLiteral $Command
    if ($Mode -ceq 'root') {
        $validatedRootExecutable = Assert-AllowedRootBinaryPath $RootExecutable
        foreach ($value in @($validatedRootExecutable, '-c', $commandLiteral)) {
            $arguments.Add($value)
        }
    } else {
        foreach ($value in @('sh', '-c', $commandLiteral)) {
            $arguments.Add($value)
        }
    }
    return $arguments.ToArray()
}

function Invoke-DeviceText(
    [Parameter(Mandatory)][string] $Command
) {
    Invoke-AdbText (New-DeviceTransportArguments -Command $Command -Mode shell)
}

function Invoke-DeviceArchive(
    [Parameter(Mandatory)][string] $Command,
    [Parameter(Mandatory)][string] $OutputPath
) {
    $arguments = New-DeviceTransportArguments -Command $Command -Mode shell
    $result = Invoke-AdbArchive -Arguments $arguments -OutputPath $OutputPath
    Remove-FailedArchiveOutput -Result $result -OutputPath $OutputPath
    return $result
}

function Invoke-RootArchivePreflight {
    Require (-not [string]::IsNullOrWhiteSpace($script:ResolvedRootBinaryPath)) `
        'The explicit root fallback is not configured.'
    $command = New-DevicePreflightCommand -RequireRootUid
    $arguments = New-DeviceTransportArguments -Command $command -Mode root `
        -RootExecutable $script:ResolvedRootBinaryPath
    Invoke-AdbText $arguments
}

function Invoke-RootDeviceArchive(
    [Parameter(Mandatory)][string] $Command,
    [Parameter(Mandatory)][string] $OutputPath
) {
    Require (-not [string]::IsNullOrWhiteSpace($script:ResolvedRootBinaryPath)) `
        'The explicit root fallback is not configured.'
    Require ($Command -ceq (New-DeviceArchiveCommand)) `
        'Root transport is restricted to the fixed read-only tar stream.'
    $arguments = New-DeviceTransportArguments -Command $Command -Mode root `
        -RootExecutable $script:ResolvedRootBinaryPath
    $result = Invoke-AdbArchive -Arguments $arguments -OutputPath $OutputPath
    Remove-FailedArchiveOutput -Result $result -OutputPath $OutputPath
    return $result
}

function Test-ArchiveTransportSucceeded([Parameter(Mandatory)] $Result) {
    return ([int]$Result.ExitCode -eq 0 -and
        [string]::IsNullOrWhiteSpace([string]$Result.Stderr))
}

function Remove-FailedArchiveOutput(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)][string] $OutputPath
) {
    if (-not (Test-ArchiveTransportSucceeded $Result) -and
            [IO.File]::Exists($OutputPath)) {
        [IO.File]::Delete($OutputPath)
    }
}

function Read-PackageIdentity([Parameter(Mandatory)][string] $Text) {
    $versionCodes = @([regex]::Matches($Text, '(?m)^\s*versionCode=(?<v>\d+)(?:\s|$)') |
        ForEach-Object { [int64]$_.Groups['v'].Value })
    $versionNames = @([regex]::Matches($Text, '(?m)^\s*versionName=(?<v>\S+)\s*$') |
        ForEach-Object { [string]$_.Groups['v'].Value })
    Require ($versionCodes.Count -eq 1) 'Stable identity did not contain exactly one versionCode.'
    Require ($versionNames.Count -eq 1) 'Stable identity did not contain exactly one versionName.'
    [pscustomobject]@{
        VersionCode = [int64]$versionCodes[0]
        VersionName = [string]$versionNames[0]
    }
}

function Read-ExactBaseApkPath([Parameter(Mandatory)][string] $Text) {
    $rows = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) `
        'Stable must expose exactly one base APK; split or ambiguous installs are rejected.'
    $match = [regex]::Match(
        [string]$rows[0],
        '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$')
    Require $match.Success 'Stable base APK path response was malformed.'
    $path = [string]$match.Groups['path'].Value
    Require (-not $path.Contains('..') -and -not $path.Contains('\') -and
            -not $path.Contains("`0")) 'Stable base APK path was unsafe.'
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)')) `
        'Stable base APK path did not belong to the fixed Stable package.'
    return $path
}

function Read-Sha256Sum(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $ExpectedPath
) {
    $rows = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'Device SHA-256 returned an unexpected number of rows.'
    $match = [regex]::Match(
        [string]$rows[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require $match.Success 'Device SHA-256 response was malformed.'
    Require ([string]$match.Groups['path'].Value -ceq $ExpectedPath) `
        'Device SHA-256 response named an unexpected file.'
    return ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RemoteSha256([Parameter(Mandatory)][string] $Path) {
    $command = 'sha256sum ' + (ConvertTo-ShLiteral $Path)
    $normal = Invoke-DeviceText -Command $command
    if ($normal.ExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace($normal.Stderr)) {
        return Read-Sha256Sum -Text $normal.Stdout -ExpectedPath $Path
    }
    throw 'The installed Stable APK could not be hashed read-only.'
}

function Assert-StableSourceReady {
    $package = Invoke-DeviceText `
        ('dumpsys package ' + (ConvertTo-ShLiteral $script:Package))
    Require ($package.ExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace($package.Stderr)) `
        'Could not read the Stable package identity.'
    $identity = Read-PackageIdentity $package.Stdout
    Require ($identity.VersionCode -eq $script:ExpectedVersionCode) `
        'Stable versionCode is not the locked v69 pre-upgrade source.'
    Require ($identity.VersionName -ceq $script:ExpectedVersionName) `
        'Stable versionName is not the locked v69 pre-upgrade source.'

    $base = Invoke-DeviceText ('pm path ' + (ConvertTo-ShLiteral $script:Package))
    Require ($base.ExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace($base.Stderr)) `
        'Could not resolve the installed Stable base APK.'
    $basePath = Read-ExactBaseApkPath $base.Stdout
    $baseSha256 = Read-RemoteSha256 $basePath
    Require ($baseSha256 -ceq $script:ExpectedBaseApkSha256) `
        'Installed Stable base APK does not match the locked v69 artifact.'

    Assert-StableStopped
    [pscustomobject]@{
        VersionCode = $identity.VersionCode
        VersionName = $identity.VersionName
        BaseApkSha256 = $baseSha256
        # Exact APK bytes cryptographically bind the already audited signer.
        # No account data or device-side certificate extraction is required.
        SignerSha256 = $script:ExpectedSignerSha256
        SignerProof = 'exact-apk-sha256-bound-to-host-audited-signer'
    }
}

function Assert-StableStopped {
    # $PID is a read-only PowerShell automatic variable (names are
    # case-insensitive), so keep the remote probe under a distinct name.
    $pidProbe = Invoke-DeviceText ('pidof ' + (ConvertTo-ShLiteral $script:Package))
    Assert-PidofProvesStopped $pidProbe
}

function Assert-PidofProvesStopped([Parameter(Mandatory)] $Result) {
    # Toybox pidof proves absence only with status 1 and no output on either
    # stream. Status 0 without a PID, diagnostic stderr, or command-not-found
    # are inconclusive and must not authorize a Stable backup.
    Require ([int]$Result.ExitCode -eq 1 -and
            [string]::IsNullOrWhiteSpace([string]$Result.Stdout) -and
            [string]::IsNullOrWhiteSpace([string]$Result.Stderr)) `
        'Could not prove that Stable is stopped.'
}

function New-DevicePreflightCommand([switch] $RequireRootUid) {
    $qGame = ConvertTo-ShLiteral $script:GameDirectory
    $allowed = ($script:AllowedRoots | ForEach-Object { ConvertTo-ShLiteral $_ }) -join ' '
    $rootUidGate = if ($RequireRootUid.IsPresent) {
@'
uid=$(id -u)
test "$uid" = '0'
'@
    } else {
        ''
    }
    $readyLabel = if ($RequireRootUid.IsPresent) { 'ROOT_READY' } else { 'READY' }
    @"
set -eu
$rootUidGate
lexical_game=$qGame
test -d "`$lexical_game"
test ! -L "`$lexical_game"
canonical_game=`$(realpath "`$lexical_game")
canonical_files=`$(realpath "`$lexical_game/../..")
test "`$canonical_game" = "`$canonical_files/instances/26.2"
found=0
for name in $allowed; do
  path="`$canonical_game/`$name"
  if test -e "`$path" || test -L "`$path"; then
    test ! -L "`$path"
    test "`$(realpath "`$path")" = "`$path"
    links=`$(find "`$path" -type l -print -quit)
    test -z "`$links"
    forbidden=`$(find "`$path" -mindepth 1 \( -iname '*account*' -o -iname '*auth*' -o -iname '*credential*' -o -iname '*token*' \) -print -quit)
    test -z "`$forbidden"
    found=`$((found + 1))
  fi
done
test "`$found" -gt 0
printf '$($readyLabel):%s\n' "`$found"
"@
}

function New-DeviceArchiveCommand {
    $qGame = ConvertTo-ShLiteral $script:GameDirectory
    $allowed = ($script:AllowedRoots | ForEach-Object { ConvertTo-ShLiteral $_ }) -join ' '
    @"
set -eu
lexical_game=$qGame
test -d "`$lexical_game"
test ! -L "`$lexical_game"
game=`$(realpath "`$lexical_game")
files=`$(realpath "`$lexical_game/../..")
test "`$game" = "`$files/instances/26.2"
set --
for name in $allowed; do
  path="`$game/`$name"
  if test -e "`$path" || test -L "`$path"; then
    test ! -L "`$path"
    test "`$(realpath "`$path")" = "`$path"
    links=`$(find "`$path" -type l -print -quit)
    test -z "`$links"
    forbidden=`$(find "`$path" -mindepth 1 \( -iname '*account*' -o -iname '*auth*' -o -iname '*credential*' -o -iname '*token*' \) -print -quit)
    test -z "`$forbidden"
    set -- "`$@" "`$name"
  fi
done
test "`$#" -gt 0
cd "`$game"
exec tar -c -f - "`$@"
"@
}

function Resolve-ReadMode {
    $command = New-DevicePreflightCommand
    $normal = Invoke-DeviceText -Command $command
    if ($normal.ExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace($normal.Stderr) -and
            $normal.Stdout -cmatch '^READY:\d+\s*$') {
        return 'shell'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedRootBinaryPath)) {
        $root = Invoke-RootArchivePreflight
        if ($root.ExitCode -eq 0 -and
                [string]::IsNullOrWhiteSpace($root.Stderr) -and
                $root.Stdout -cmatch '^ROOT_READY:\d+\s*$') {
            return 'root'
        }
    }
    throw 'The fixed Stable profile did not pass the read-only path/symlink/sensitive-name preflight.'
}

function Assert-SafeBackupLeaf([Parameter(Mandatory)][string] $Name) {
    Require ($Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$') `
        'BackupName must be a short ASCII leaf.'
    Require ($Name -cne '.' -and $Name -cne '..') 'BackupName cannot be dot or dot-dot.'
    Require (-not $Name.EndsWith('.') -and -not $Name.EndsWith(' ')) `
        'BackupName cannot end with a dot or space on Windows.'
    Require (-not (Test-WindowsReservedLeaf $Name)) `
        'BackupName cannot use a reserved Windows device name.'
    return $Name
}

function Get-FullPath([Parameter(Mandatory)][string] $Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Assert-LocalPathContained(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Root
) {
    $fullRoot = Get-FullPath $Root
    $full = Get-FullPath $Path
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    Require ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) `
        'A local backup path escaped the fixed backup root.'
    return $full
}

function Assert-NoExistingReparsePoint(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Root
) {
    $fullRoot = Get-FullPath $Root
    $full = Get-FullPath $Path
    Require ($full -eq $fullRoot -or
            $full.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) `
        'The path used for the reparse-point check escaped its root.'
    $current = $fullRoot
    if (Test-Path -LiteralPath $current) {
        Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) 'The backup root is a reparse point.'
    }
    if ($full -eq $fullRoot) { return }
    $relative = [IO.Path]::GetRelativePath($fullRoot, $full)
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint)) `
                'An existing backup path component is a reparse point.'
        }
    }
}

function Test-WindowsReservedLeaf([Parameter(Mandatory)][string] $Name) {
    $base = $Name.Split('.')[0]
    $base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
}

function Normalize-ArchiveEntryName([Parameter(Mandatory)][string] $Name) {
    Require (-not [string]::IsNullOrWhiteSpace($Name)) 'Archive entry has an empty name.'
    Require (-not $Name.Contains('\')) 'Archive entry uses a Windows separator.'
    Require (-not $Name.StartsWith('/')) 'Archive entry is absolute.'
    Require (-not $Name.Contains("`0")) 'Archive entry contains NUL.'
    Require (-not ($Name.ToCharArray() | Where-Object { [char]::IsControl($_) } |
            Select-Object -First 1)) 'Archive entry contains a control character.'
    while ($Name.StartsWith('./', [StringComparison]::Ordinal)) { $Name = $Name.Substring(2) }
    $Name = $Name.TrimEnd('/')
    Require (-not [string]::IsNullOrWhiteSpace($Name)) 'Archive entry normalized to an empty name.'
    $parts = $Name.Split('/')
    Require ($parts.Count -gt 0 -and $script:AllowedRoots -ccontains $parts[0]) `
        'Archive entry is outside the fixed allowlist.'
    foreach ($part in $parts) {
        Require (-not [string]::IsNullOrEmpty($part) -and $part -cne '.' -and $part -cne '..') `
            'Archive entry contains an unsafe path segment.'
        Require ($part -notmatch $script:SensitiveNamePattern) `
            'Archive entry has an account/authentication/credential/token-like name.'
        Require ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0) `
            'Archive entry cannot be represented safely on the Host filesystem.'
        Require (-not $part.EndsWith(' ') -and -not $part.EndsWith('.')) `
            'Archive entry has an ambiguous Windows leaf.'
        Require (-not (Test-WindowsReservedLeaf $part)) `
            'Archive entry uses a reserved Windows leaf.'
    }
    return ($parts -join '/')
}

function Remove-SafeLocalTree(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Root
) {
    $full = Assert-LocalPathContained -Path $Path -Root $Root
    if (-not [IO.Directory]::Exists($full)) { return }
    Assert-NoExistingReparsePoint -Path $full -Root $Root
    [IO.Directory]::Delete($full, $true)
}

function Expand-ValidatedArchive(
    [Parameter(Mandatory)][string] $ArchivePath,
    [Parameter(Mandatory)][string] $Destination,
    [Parameter(Mandatory)][string] $ContainmentRoot
) {
    $destinationFull = Assert-LocalPathContained -Path $Destination -Root $ContainmentRoot
    Require (-not (Test-Path -LiteralPath $destinationFull)) `
        'The extraction staging directory already exists.'
    [IO.Directory]::CreateDirectory($destinationFull) | Out-Null
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [Collections.Generic.List[object]]::new()
    $archive = [IO.File]::OpenRead($ArchivePath)
    $reader = [System.Formats.Tar.TarReader]::new($archive, $false)
    try {
        while ($null -ne ($entry = $reader.GetNextEntry())) {
            $relative = Normalize-ArchiveEntryName $entry.Name
            Require $seen.Add($relative) 'Archive contains duplicate or case-colliding paths.'
            $nativeRelative = $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $target = Assert-LocalPathContained `
                -Path (Join-Path $destinationFull $nativeRelative) -Root $destinationFull
            switch ($entry.EntryType) {
                ([System.Formats.Tar.TarEntryType]::Directory) {
                    Require (-not [IO.File]::Exists($target)) `
                        'Archive directory collides with an extracted file.'
                    [IO.Directory]::CreateDirectory($target) | Out-Null
                }
                { $_ -eq [System.Formats.Tar.TarEntryType]::RegularFile -or
                        $_ -eq [System.Formats.Tar.TarEntryType]::V7RegularFile -or
                        $_ -eq [System.Formats.Tar.TarEntryType]::ContiguousFile } {
                    Require ($entry.Length -ge 0) 'Archive file has an invalid length.'
                    $parent = Split-Path -Parent $target
                    Assert-LocalPathContained -Path $parent -Root $destinationFull | Out-Null
                    [IO.Directory]::CreateDirectory($parent) | Out-Null
                    Require (-not (Test-Path -LiteralPath $target)) `
                        'Archive file collides with an existing path.'
                    $output = [IO.FileStream]::new(
                        $target,
                        [IO.FileMode]::CreateNew,
                        [IO.FileAccess]::Write,
                        [IO.FileShare]::None,
                        1MB,
                        [IO.FileOptions]::SequentialScan)
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try {
                        $buffer = [byte[]]::new(1MB)
                        $written = [int64]0
                        while (($count = $entry.DataStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $output.Write($buffer, 0, $count)
                            $sha.TransformBlock($buffer, 0, $count, $null, 0) | Out-Null
                            $written += $count
                        }
                        $sha.TransformFinalBlock([byte[]]::new(0), 0, 0) | Out-Null
                        $output.Flush($true)
                        Require ($written -eq $entry.Length) `
                            'Archive file length changed during extraction.'
                        $digest = [Convert]::ToHexString($sha.Hash)
                    } finally {
                        $sha.Dispose()
                        $output.Dispose()
                    }
                    $files.Add([ordered]@{
                        path = $relative
                        sizeBytes = $written
                        sha256 = $digest
                    })
                }
                default {
                    throw "Archive contains forbidden entry type: $($entry.EntryType)."
                }
            }
        }
    } finally {
        $reader.Dispose()
        $archive.Dispose()
    }
    Require ($seen.Count -gt 0 -and $files.Count -gt 0) `
        'Archive did not contain any approved regular files.'
    # Keep a one-file backup as object[1] instead of letting PowerShell unwrap
    # its ordered manifest record into a scalar dictionary.
    return ,$files.ToArray()
}

function Write-BackupManifests(
    [Parameter(Mandatory)][string] $Directory,
    [Parameter(Mandatory)][object[]] $Files,
    [Parameter(Mandatory)][object] $Identity,
    [Parameter(Mandatory)][string] $ReadMode
) {
    $orderedFiles = @($Files | Sort-Object { [string]$_.path })
    $shaLines = @($orderedFiles | ForEach-Object { "$($_.sha256) *$($_.path)" })
    [IO.File]::WriteAllLines(
        (Join-Path $Directory 'SHA256SUMS.sha256'),
        $shaLines,
        [Text.UTF8Encoding]::new($false))
    $manifest = [ordered]@{
        schemaVersion = 1
        createdUtc = [DateTime]::UtcNow.ToString('o')
        sourcePackage = $script:Package
        sourceVersionCode = $Identity.VersionCode
        sourceVersionName = $Identity.VersionName
        sourceBaseApkSha256 = $Identity.BaseApkSha256
        sourceSignerSha256 = $Identity.SignerSha256
        sourceSignerProof = $Identity.SignerProof
        sourceProfile = '26.2'
        readMode = if ($ReadMode -ceq 'root') { 'su-read-fallback' } else { 'shell' }
        deviceMutated = $false
        accountOrAuthenticationFilesIncluded = $false
        allowlistedRoots = $script:AllowedRoots
        sensitiveNamePolicy = 'fail-before-stream-and-reject-on-host'
        fileCount = $orderedFiles.Count
        totalSizeBytes = [int64](($orderedFiles | Measure-Object sizeBytes -Sum).Sum)
        files = $orderedFiles
    }
    [IO.File]::WriteAllText(
        (Join-Path $Directory 'BACKUP_MANIFEST.json'),
        ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    return $manifest
}

function Invoke-Backup {
    $identity = Assert-StableSourceReady
    $mode = Resolve-ReadMode

    $repoFull = Get-FullPath $script:RepoRoot
    $backupRootFull = Get-FullPath $script:BackupRoot
    Require ($backupRootFull.StartsWith(
            $repoFull + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) `
        'The fixed backup root escaped the repository worktree.'
    Assert-NoExistingReparsePoint -Path (Split-Path -Parent $backupRootFull) `
        -Root $repoFull
    if (-not (Test-Path -LiteralPath $backupRootFull)) {
        [IO.Directory]::CreateDirectory($backupRootFull) | Out-Null
    }
    Assert-NoExistingReparsePoint -Path $backupRootFull -Root $repoFull

    if ([string]::IsNullOrWhiteSpace($BackupName)) {
        $leaf = 'v71-stable-preupgrade-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    } else {
        $leaf = Assert-SafeBackupLeaf $BackupName
    }
    $final = Assert-LocalPathContained -Path (Join-Path $backupRootFull $leaf) `
        -Root $backupRootFull
    Require (-not (Test-Path -LiteralPath $final)) 'The requested backup already exists.'

    $transaction = [Guid]::NewGuid().ToString('N')
    $archivePath = Assert-LocalPathContained `
        -Path (Join-Path $backupRootFull ".$leaf.partial-$transaction.tar") `
        -Root $backupRootFull
    $staging = Assert-LocalPathContained `
        -Path (Join-Path $backupRootFull ".$leaf.partial-$transaction") `
        -Root $backupRootFull
    $committed = $false
    try {
        $archiveCommand = New-DeviceArchiveCommand
        if ($mode -ceq 'root') {
            $stream = Invoke-RootDeviceArchive -Command $archiveCommand `
                -OutputPath $archivePath
        } else {
            $stream = Invoke-DeviceArchive -Command $archiveCommand `
                -OutputPath $archivePath
        }
        if (-not (Test-ArchiveTransportSucceeded $stream) -and
                $mode -ceq 'shell' -and
                -not [string]::IsNullOrWhiteSpace($script:ResolvedRootBinaryPath)) {
            if ([IO.File]::Exists($archivePath)) { [IO.File]::Delete($archivePath) }
            $rootPreflight = Invoke-RootArchivePreflight
            Require ($rootPreflight.ExitCode -eq 0 -and
                    [string]::IsNullOrWhiteSpace($rootPreflight.Stderr) -and
                    $rootPreflight.Stdout -cmatch '^ROOT_READY:\d+\s*$') `
                'Normal reading failed and the explicit uid-0 root fallback did not pass preflight.'
            $mode = 'root'
            $stream = Invoke-RootDeviceArchive -Command $archiveCommand `
                -OutputPath $archivePath
        }
        Require (Test-ArchiveTransportSucceeded $stream) `
            'The shell_v2 archive stream failed or emitted stderr; device output was suppressed.'
        Require ([IO.File]::Exists($archivePath) -and
                (Get-Item -LiteralPath $archivePath).Length -gt 0) `
            'The device archive stream was empty.'

        # Close the upgrade/start race before parsing or committing any Host
        # output: the package identity, exact installed APK bytes, and stopped
        # process state must still match the pre-stream snapshot.
        $identityAfterStream = Assert-StableSourceReady
        Require ($identityAfterStream.VersionCode -eq $identity.VersionCode -and
                $identityAfterStream.VersionName -ceq $identity.VersionName -and
                $identityAfterStream.BaseApkSha256 -ceq $identity.BaseApkSha256 -and
                $identityAfterStream.SignerSha256 -ceq $identity.SignerSha256) `
            'Stable identity changed while the backup stream was in progress.'

        $files = Expand-ValidatedArchive -ArchivePath $archivePath `
            -Destination $staging -ContainmentRoot $backupRootFull
        # Refuse to commit a potentially inconsistent snapshot if Stable was
        # launched while the read-only stream was in progress.
        Assert-StableStopped
        $manifest = Write-BackupManifests -Directory $staging -Files $files `
            -Identity $identity -ReadMode $mode
        Require (-not (@($manifest.files | Where-Object {
            $_.path -match $script:SensitiveNamePattern
        }).Count)) 'The final manifest unexpectedly contains a sensitive-looking path.'
        [IO.Directory]::Move($staging, $final)
        $committed = $true
        [pscustomobject]@{
            Result = 'PASS'
            Package = $script:Package
            VersionCode = $identity.VersionCode
            VersionName = $identity.VersionName
            BackupDirectory = $final
            ReadMode = $manifest.readMode
            FileCount = $manifest.fileCount
            TotalSizeBytes = $manifest.totalSizeBytes
            Sha256Manifest = Join-Path $final 'SHA256SUMS.sha256'
            JsonManifest = Join-Path $final 'BACKUP_MANIFEST.json'
            DeviceMutated = $false
        }
    } finally {
        if ([IO.File]::Exists($archivePath)) { [IO.File]::Delete($archivePath) }
        if (-not $committed -and [IO.Directory]::Exists($staging)) {
            Remove-SafeLocalTree -Path $staging -Root $backupRootFull
        }
    }
}

function New-TestTar(
    [Parameter(Mandatory)][string] $Path,
    [ValidateSet('None', 'Symbolic', 'Hard')]
    [string] $LinkType = 'None'
) {
    $stream = [IO.File]::Create($Path)
    $writer = [System.Formats.Tar.TarWriter]::new($stream, $false)
    try {
        $data = [Text.Encoding]::UTF8.GetBytes('host-only-fixture')
        $entry = [System.Formats.Tar.PaxTarEntry]::new(
            [System.Formats.Tar.TarEntryType]::RegularFile,
            'mods/example.jar')
        $entry.DataStream = [IO.MemoryStream]::new($data, $false)
        try { $writer.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        if ($LinkType -cne 'None') {
            $link = [System.Formats.Tar.PaxTarEntry]::new(
                $(if ($LinkType -ceq 'Symbolic') {
                    [System.Formats.Tar.TarEntryType]::SymbolicLink
                } else {
                    [System.Formats.Tar.TarEntryType]::HardLink
                }),
                'config/link')
            $link.LinkName = if ($LinkType -ceq 'Symbolic') {
                '../../outside'
            } else {
                'mods/example.jar'
            }
            $writer.WriteEntry($link)
        }
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Invoke-SelfTest {
    $adbBefore = $script:AdbInvocationCount
    Require ((Normalize-ArchiveEntryName './mods/a.jar') -ceq 'mods/a.jar') `
        'A valid allowlisted archive path was rejected.'
    foreach ($operation in @(
        { Normalize-ArchiveEntryName '../mods/a.jar' },
        { Normalize-ArchiveEntryName 'mods/../../outside' },
        { Normalize-ArchiveEntryName '/mods/a.jar' },
        { Normalize-ArchiveEntryName 'mods\a.jar' },
        { Normalize-ArchiveEntryName 'logs/a.txt' },
        { Normalize-ArchiveEntryName 'config/auth.json' },
        { Normalize-ArchiveEntryName 'saves/world/Tokens.dat' },
        { Normalize-ArchiveEntryName 'mods/CON' },
        { Assert-SafeBackupLeaf '..' },
        { Assert-SafeBackupLeaf 'CON' },
        { Assert-SafeBackupLeaf 'AUX.txt' },
        { Assert-SafeBackupLeaf 'valid-looking.' },
        { Assert-SafeBackupLeaf 'safe;touch' },
        { Assert-SafeBackupLeaf 'safe$(id)' },
        { Assert-LocalPathContained -Path 'C:\escape' -Root 'C:\safe' }
    )) {
        Require (Test-ExpectedFailure $operation) `
            'An unsafe archive, destination, or backup leaf passed validation.'
    }

    Require ((Assert-AllowedRootBinaryPath '/debug_ramdisk/su') -ceq
            '/debug_ramdisk/su') 'The fixed root binary path was rejected.'
    foreach ($unsafeRootPath in @(
        '', 'su', '/system/bin/su', '/system/xbin/su',
        '/debug_ramdisk/../su', '/debug_ramdisk/su;id',
        '/debug_ramdisk/su --mount-master', '\debug_ramdisk\su'
    )) {
        Require (Test-ExpectedFailure {
            Assert-AllowedRootBinaryPath $unsafeRootPath | Out-Null
        }) "Unsafe or non-allowlisted root path passed: $unsafeRootPath"
    }
    Require ([string]::IsNullOrEmpty([string](
            Resolve-ValidatedRootConfiguration -Authorized $false -ConfiguredPath ''))) `
        'Root fallback was not disabled by default.'
    foreach ($invalidRootConfiguration in @(
        { Resolve-ValidatedRootConfiguration -Authorized $true -ConfiguredPath '' | Out-Null },
        { Resolve-ValidatedRootConfiguration -Authorized $false `
            -ConfiguredPath '/debug_ramdisk/su' | Out-Null }
    )) {
        Require (Test-ExpectedFailure $invalidRootConfiguration) `
            'A partially enabled root fallback configuration passed.'
    }

    $preflight = New-DevicePreflightCommand
    $rootPreflight = New-DevicePreflightCommand -RequireRootUid
    $archiveCommand = New-DeviceArchiveCommand
    foreach ($command in @($preflight, $rootPreflight, $archiveCommand)) {
        Require ($command.Contains((ConvertTo-ShLiteral $script:GameDirectory))) `
            'A device read command is not pinned to the Stable game directory.'
        Require ($command -notmatch '(?i)\b(chown|chmod|install|uninstall|rm|mv|cp|mkdir|touch|truncate|force-stop|monkey)\b') `
            'A device read command contains a mutation primitive.'
        Require ($command -notmatch '[^2]>' -and $command -notmatch '>>') `
            'A device read command contains a filesystem redirection.'
    }
    Require ($archiveCommand -match 'exec tar -c -f -') `
        'The archive command does not stream to stdout.'
    Require ($rootPreflight -cmatch 'uid=\$\(id -u\)' -and
            $rootPreflight -cmatch 'test "\$uid" = ''0''' -and
            $rootPreflight -cmatch "printf 'ROOT_READY:%s") `
        'The root preflight no longer proves uid=0 before authorizing the tar stream.'

    $literalInjectionFixture = "safe'; printf PWNED; #"
    Require ((ConvertTo-ShLiteral $literalInjectionFixture) -ceq
            "'safe'`"'`"'`; printf PWNED; #'") `
        'POSIX literal escaping no longer contains embedded shell syntax.'
    Assert-ShellV2FeatureResponse 'abb,cmd,shell_v2,stat_v2'
    Require (Test-ExpectedFailure {
        Assert-ShellV2FeatureResponse 'abb,cmd,stat_v2'
    }) 'A device without shell_v2 passed the transport feature gate.'

    Assert-PidofProvesStopped ([pscustomobject]@{
        ExitCode = 1
        Stdout = ''
        Stderr = ''
    })
    foreach ($pidResult in @(
        [pscustomobject]@{ ExitCode = 0; Stdout = '1234'; Stderr = '' },
        [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = '' },
        [pscustomobject]@{ ExitCode = 1; Stdout = ''; Stderr = 'pidof failed' },
        [pscustomobject]@{ ExitCode = 127; Stdout = ''; Stderr = 'not found' }
    )) {
        Require (Test-ExpectedFailure {
            Assert-PidofProvesStopped $pidResult
        }) 'An inconclusive or running pidof result authorized a Stable backup.'
    }

    $transportRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('qc-v71-transport-selftest-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($transportRoot) | Out-Null
    try {
        $resolvedRootBeforePolicyTest = $script:ResolvedRootBinaryPath
        $script:ResolvedRootBinaryPath = '/debug_ramdisk/su'
        try {
            Require (Test-ExpectedFailure {
                Invoke-RootDeviceArchive -Command 'id' `
                    -OutputPath (Join-Path $transportRoot 'forbidden-root-command.tar') |
                    Out-Null
            }) 'Root transport accepted a command other than the fixed tar stream.'
        } finally {
            $script:ResolvedRootBinaryPath = $resolvedRootBeforePolicyTest
        }

        $probePath = Join-Path $transportRoot 'argv-probe.ps1'
        [IO.File]::WriteAllText(
            $probePath,
            '[Console]::Out.Write((@($args) | ConvertTo-Json -Compress))',
            [Text.UTF8Encoding]::new($false))

        $fakeBin = Join-Path $transportRoot 'bin'
        [IO.Directory]::CreateDirectory($fakeBin) | Out-Null
        $fakeAdbPath = Join-Path $transportRoot 'fake-adb.sh'
        $fakeSuPath = Join-Path $fakeBin 'su'
        $fakeAdbSource = @'
#!/bin/sh
set -eu
test "$#" -eq 7
test "$1" = '-s'
test "$2" = 'host-only-selftest'
test "$3" = 'shell'
test "$4" = '-T'
shift 4
script_dir=${0%/*}
test "$script_dir" != "$0" || script_dir=.
script_dir=$(CDPATH= cd -- "$script_dir" && pwd)
PATH="$script_dir/bin:/usr/bin:/bin:$PATH"
export PATH
if test "$1" = '/debug_ramdisk/su'; then
  remote="$script_dir/bin/su"
else
  remote=$1
fi
shift
for argument
do
  remote="$remote $argument"
done
exec sh -c "$remote"
'@
        $fakeSuSource = @'
#!/bin/sh
set -eu
test "$#" -eq 2
test "$1" = '-c'
QC_V71_SELFTEST_ROOT=1
export QC_V71_SELFTEST_ROOT
exec sh -c "$2"
'@
        [IO.File]::WriteAllText(
            $fakeAdbPath,
            $fakeAdbSource.Replace("`r`n", "`n"),
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            $fakeSuPath,
            $fakeSuSource.Replace("`r`n", "`n"),
            [Text.UTF8Encoding]::new($false))

        $hostShellCommand = Get-Command sh -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $hostShellCommand) {
            $gitCommand = Get-Command git -CommandType Application `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $gitCommand) {
                $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCommand.Source)
                foreach ($candidate in @(
                    (Join-Path $gitRoot 'usr\bin\sh.exe'),
                    (Join-Path $gitRoot 'bin\sh.exe')
                )) {
                    if ([IO.File]::Exists($candidate)) {
                        $hostShellCommand = [pscustomobject]@{ Source = $candidate }
                        break
                    }
                }
            }
        }
        Require ($null -ne $hostShellCommand -and
                [IO.File]::Exists([string]$hostShellCommand.Source)) `
            'A POSIX shell is required for the nested shell-v2 Host test.'
        $hostShell = [string]$hostShellCommand.Source
        $fakeAdbShellPath = $fakeAdbPath.Replace('\', '/')

        $sentinelLeaf = '.qc-v71-host-injection-' + [Guid]::NewGuid().ToString('N')
        $sentinelPath = Join-Path (Get-Location).Path $sentinelLeaf
        $transportFixture =
            "line one`nline 'two' `$HOME; `$(touch $sentinelLeaf)"
        $semanticCommand = 'value=' + (ConvertTo-ShLiteral $transportFixture) +
            "`nprintf '%s' `"`$value`""
        $hostExecutable = [Environment]::ProcessPath
        Require (-not [string]::IsNullOrWhiteSpace($hostExecutable) -and
                [IO.File]::Exists($hostExecutable)) `
            'Could not resolve the current PowerShell executable for the argv probe.'
        $serialBeforeTransportTest = $script:ResolvedSerial
        $script:ResolvedSerial = 'host-only-selftest'
        try {
            foreach ($mode in @('shell', 'root')) {
                $rootArgument = if ($mode -ceq 'root') {
                    @{ RootExecutable = '/debug_ramdisk/su' }
                } else {
                    @{}
                }
                $arguments = @(
                    New-DeviceTransportArguments -Command $semanticCommand -Mode $mode `
                        @rootArgument
                )
                Require ($arguments.Count -eq 7) `
                    'ADB transport split one multiline script into multiple logical arguments.'
                Require ($arguments[0] -ceq '-s' -and
                        $arguments[1] -ceq $script:ResolvedSerial -and
                        $arguments[2] -ceq 'shell' -and
                        $arguments[3] -ceq '-T' -and
                        $arguments[5] -ceq '-c') `
                    'ADB transport prefix drifted.'
                $expectedTool = if ($mode -ceq 'root') {
                    '/debug_ramdisk/su'
                } else {
                    'sh'
                }
                Require ($arguments[4] -ceq $expectedTool) `
                    'ADB transport selected the wrong shell.'
                Require ($arguments[6] -ceq (ConvertTo-ShLiteral $semanticCommand)) `
                    'ADB shell transport did not quote the complete -c script exactly once.'

                # Exercise the same ProcessStartInfo.ArgumentList path used for
                # ADB, first through an inert argv probe and then through an ADB
                # join emulator plus two nested POSIX shells.
                $probeArguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $probePath
                ) + $arguments
                $capture = Invoke-ProcessCapture -FileName $hostExecutable `
                    -Arguments $probeArguments
                Require ($capture.ExitCode -eq 0 -and
                        [string]::IsNullOrWhiteSpace($capture.Stderr)) `
                    "The $mode Host argv probe failed."
                $capturedArguments = @($capture.Stdout | ConvertFrom-Json)
                Require ($capturedArguments.Count -eq $arguments.Count) `
                    "The $mode Host argv probe changed the argument count."
                for ($index = 0; $index -lt $arguments.Count; $index++) {
                    Require ([string]$capturedArguments[$index] -ceq
                            [string]$arguments[$index]) `
                        "The $mode Host argv probe changed argument $index."
                }

                $nested = Invoke-ProcessCapture -FileName $hostShell `
                    -Arguments (@($fakeAdbShellPath) + $arguments)
                Require ($nested.ExitCode -eq 0 -and
                        [string]::IsNullOrWhiteSpace($nested.Stderr)) `
                    ("The $mode nested shell-v2 execution probe failed " +
                    "(exit=$($nested.ExitCode), stderr=$($nested.Stderr.Trim())).")
                Require ($nested.Stdout -ceq $transportFixture) `
                    "The $mode nested shell-v2 execution changed the protected payload."
                Require (-not [IO.File]::Exists($sentinelPath)) `
                    "The $mode transport allowed command execution on the Host."

                $failureCommand =
                    "printf 'partial-output'; printf 'remote-error' >&2; exit 7"
                $failureArguments = @(
                    New-DeviceTransportArguments -Command $failureCommand -Mode $mode `
                        @rootArgument
                )
                $failure = Invoke-ProcessCapture -FileName $hostShell `
                    -Arguments (@($fakeAdbShellPath) + $failureArguments)
                Require ($failure.ExitCode -eq 7 -and
                        $failure.Stdout -ceq 'partial-output' -and
                        $failure.Stderr -ceq 'remote-error') `
                    "The $mode shell-v2 probe lost remote status or mixed stderr into stdout."

                $binaryPath = Join-Path $transportRoot "$mode-binary.bin"
                $binaryCommand = "printf '\000\015\012\014\177'"
                $binaryArguments = @(
                    New-DeviceTransportArguments -Command $binaryCommand -Mode $mode `
                        @rootArgument
                )
                $binary = Invoke-ProcessCapture -FileName $hostShell `
                    -Arguments (@($fakeAdbShellPath) + $binaryArguments) `
                    -BinaryOutputPath $binaryPath
                Require ($binary.ExitCode -eq 0 -and
                        [string]::IsNullOrWhiteSpace($binary.Stderr)) `
                    "The $mode binary shell-v2 probe failed."
                $binaryBytes = [IO.File]::ReadAllBytes($binaryPath)
                Require ([Convert]::ToHexString($binaryBytes) -ceq '000D0A0C7F') `
                    "The $mode shell-v2 transport changed binary stdout."
            }

            $permissionCommand = @'
if test "${QC_V71_SELFTEST_ROOT:-0}" = '1'; then
  printf 'READY:root'
else
  printf 'permission denied' >&2
  exit 13
fi
'@
            $normalPermission = Invoke-ProcessCapture -FileName $hostShell `
                -Arguments (@($fakeAdbShellPath) + @(
                    New-DeviceTransportArguments -Command $permissionCommand -Mode shell
                ))
            $rootPermission = Invoke-ProcessCapture -FileName $hostShell `
                -Arguments (@($fakeAdbShellPath) + @(
                    New-DeviceTransportArguments -Command $permissionCommand -Mode root `
                        -RootExecutable '/debug_ramdisk/su'
                ))
            Require ($normalPermission.ExitCode -eq 13 -and
                    $normalPermission.Stderr -ceq 'permission denied' -and
                    $rootPermission.ExitCode -eq 0 -and
                    $rootPermission.Stdout -ceq 'READY:root') `
                'The read-only normal-to-root transport fallback contract failed.'

            $partialArchivePath = Join-Path $transportRoot 'partial.tar'
            [IO.File]::WriteAllBytes($partialArchivePath, [byte[]](1, 2, 3, 4))
            $failedArchiveResult = [pscustomobject]@{
                ExitCode = 7
                Stdout = $null
                Stderr = 'remote tar failed'
            }
            Remove-FailedArchiveOutput -Result $failedArchiveResult `
                -OutputPath $partialArchivePath
            Require (-not [IO.File]::Exists($partialArchivePath)) `
                'A partial archive survived a failed shell-v2 transport.'

            $stderrArchivePath = Join-Path $transportRoot 'stderr.tar'
            [IO.File]::WriteAllBytes($stderrArchivePath, [byte[]](1, 2, 3, 4))
            $stderrArchiveResult = [pscustomobject]@{
                ExitCode = 0
                Stdout = $null
                Stderr = 'unexpected tar warning'
            }
            Remove-FailedArchiveOutput -Result $stderrArchiveResult `
                -OutputPath $stderrArchivePath
            Require (-not [IO.File]::Exists($stderrArchivePath)) `
                'An archive that emitted stderr survived the fail-closed transport gate.'

            Require (Test-ExpectedFailure {
                New-DeviceTransportArguments -Command ("printf safe" + [char]0) `
                    -Mode shell | Out-Null
            }) 'ADB transport accepted a NUL-bearing shell command.'
        } finally {
            $script:ResolvedSerial = $serialBeforeTransportTest
            if ([IO.File]::Exists($sentinelPath)) {
                [IO.File]::Delete($sentinelPath)
            }
        }
    } finally {
        if ([IO.Directory]::Exists($transportRoot)) {
            [IO.Directory]::Delete($transportRoot, $true)
        }
    }

    $identityFixture = Read-PackageIdentity @'
  versionCode=69 minSdk=29 targetSdk=34
  versionName=6.0.1-26.2-vivecraft-personal.10
'@
    Require ($identityFixture.VersionCode -eq $script:ExpectedVersionCode -and
            $identityFixture.VersionName -ceq $script:ExpectedVersionName) `
        'Stable identity parser rejected the locked fixture.'
    $basePathFixture = '/data/app/~~abc/com.qcxr.qcxr.dev262-def/base.apk'
    Require ((Read-ExactBaseApkPath "package:$basePathFixture") -ceq $basePathFixture) `
        'Stable base APK path parser rejected the locked fixture.'
    Require (Test-ExpectedFailure {
        Read-ExactBaseApkPath "package:$basePathFixture`npackage:/data/app/split.apk" | Out-Null
    }) 'Stable base APK path parser accepted an ambiguous install.'
    Require ((Read-Sha256Sum `
            -Text ($script:ExpectedBaseApkSha256.ToLowerInvariant() + "  $basePathFixture") `
            -ExpectedPath $basePathFixture) -ceq $script:ExpectedBaseApkSha256) `
        'Stable APK SHA-256 parser rejected the locked fixture.'
    Require (Test-ExpectedFailure {
        Read-Sha256Sum -Text (('0' * 64) + "  /data/app/other/base.apk") `
            -ExpectedPath $basePathFixture | Out-Null
    }) 'Stable APK SHA-256 parser accepted a response for another path.'

    $selfTestRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('qc-v71-stable-backup-selftest-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($selfTestRoot) | Out-Null
    try {
        $safeTar = Join-Path $selfTestRoot 'safe.tar'
        $safeOut = Join-Path $selfTestRoot 'safe-out'
        New-TestTar -Path $safeTar
        $files = Expand-ValidatedArchive -ArchivePath $safeTar -Destination $safeOut `
            -ContainmentRoot $selfTestRoot
        Require ($files.Count -eq 1 -and $files[0].path -ceq 'mods/example.jar') `
            'The safe archive extraction fixture failed.'
        Require ([IO.File]::ReadAllText((Join-Path $safeOut 'mods\example.jar')) -ceq
                'host-only-fixture') 'The safe archive payload changed during extraction.'

        foreach ($linkType in @('Symbolic', 'Hard')) {
            $linkTar = Join-Path $selfTestRoot "$($linkType.ToLowerInvariant())-link.tar"
            $linkOut = Join-Path $selfTestRoot "$($linkType.ToLowerInvariant())-link-out"
            New-TestTar -Path $linkTar -LinkType $linkType
            Require (Test-ExpectedFailure {
                Expand-ValidatedArchive -ArchivePath $linkTar -Destination $linkOut `
                    -ContainmentRoot $selfTestRoot | Out-Null
            }) "A $linkType-link archive entry passed validation."
        }
    } finally {
        if ([IO.Directory]::Exists($selfTestRoot)) {
            [IO.Directory]::Delete($selfTestRoot, $true)
        }
    }

    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$tokens, [ref]$errors) | Out-Null
    Require ($errors.Count -eq 0) 'PowerShell parser errors were found.'
    Require ($script:AdbInvocationCount -eq $adbBefore) `
        'Host-only SelfTest unexpectedly invoked ADB.'
    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        Package = $script:Package
        AllowedRoots = $script:AllowedRoots -join ', '
        SensitiveNamesRejected = $true
        PathContainment = $true
        SymlinkAndHardlinkEntriesRejected = $true
        DeviceMutationPrimitivesAbsent = $true
        ShellAndRootArgvRoundTrip = $true
        RootFallbackDisabledByDefault = $true
        AbsoluteRootBinaryAllowlist = '/debug_ramdisk/su'
        RootUidPreflightRequired = $true
        RootTransportRestrictedToTar = $true
        HostCommandInjectionRejected = $true
        ShellV2StatusAndStderrVerified = $true
        BinaryStreamRoundTripVerified = $true
        FailedArchiveRemoved = $true
        PidofAbsenceProofFailClosed = $true
    }
}

if ($Action -ceq 'SelfTest') {
    Invoke-SelfTest
    return
}

Resolve-RootReadConfiguration
Resolve-Device
Invoke-Backup
