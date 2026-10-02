#requires -Version 7.0
<#
.SYNOPSIS
Captures one privacy-scoped, aggregate-only Perfetto diagnostic for exact RC8 Lab.

.DESCRIPTION
SelfTest is the default and is Host-only. Capture is pinned to the exact
V71_LAB_RC8.lock.json identity and refuses to run unless Lab is already alive,
focused, and unchanged while Stable is conclusively stopped. It does not
install, launch, stop, configure, or otherwise mutate either application.

Capture needs three independent capabilities: read-only device inspection,
ephemeral /data/local/tmp I/O for Perfetto's config/trace, and root read access
for the fixed available_events probe. The raw trace exists only in randomized
temporary paths and is deleted from device and Host in finally blocks. Only a
sanitized aggregate JSON is retained. No callstacks, logcat, network, file-I/O,
Binder, atrace application categories, heap profiler, package list, account,
world, or server data is captured.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Plan', 'Capture')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [string] $TraceProcessorPath = '',

    [ValidateRange(20, 45)]
    [int] $Seconds = 30,

    [switch] $AllowDeviceRead,
    [switch] $AllowEphemeralDeviceIo,
    [switch] $AllowRootRead
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BuildLockPath = Join-Path $script:RepoRoot 'V71_LAB_RC8.lock.json'
$script:ExpectedBuildLockSha256 =
    'BB5147F0B5B0A3AB5C61D7012A821F0C2583BDE76F96F963C19EDDD967177EF7'
$script:LockedPackage = 'com.qcxr.qcxr.canary262'
$script:LockedStablePackage = 'com.qcxr.qcxr.dev262'
$script:LockedProfile = '26.2'
$script:LockedVersionCode = 71
$script:LockedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'
$script:LockedApkSha256 =
    'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$script:LockedSignerSha256 =
    'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:LockedCoreSha256 =
    'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$script:LockedVeqSha256 =
    'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$script:LockedImmersiveActivity = 'pojlib.UnityPlayerActivity'
$script:RootBinary = '/debug_ramdisk/su'
$script:Device = $null
$script:Adb = $null
$script:UsbTransportProofMethod = $null
$script:DeviceInvocations = 0
$script:Assertions = 0
$script:QuestUsbParentPrefix = 'USB\VID_2833&PID_5013\'

$script:MandatoryFtraceEvents = @(
    'sched/sched_switch',
    'sched/sched_waking',
    'sched/sched_wakeup',
    'power/cpu_frequency',
    'power/cpu_idle'
)
$script:CapturedOptionalGpuFtraceEvents = @(
    'gpu_mem/gpu_mem_total',
    'kgsl/adreno_cmdbatch_submitted',
    'kgsl/adreno_cmdbatch_retired'
)
# These tracepoints are discoverable on the current Quest kernel, but two
# separate captures requested all four, reported exactly four setup failures,
# and emitted none of the four. That correlation does not prove which event
# failed or that the kernel can never emit it. Keep the names in the bounded
# availability report, but do not risk poisoning the scheduler capture with
# vendor telemetry that has not demonstrated a successful setup.
$script:ExcludedVendorGpuFtraceEvents = @(
    'kgsl/kgsl_buslevel',
    'kgsl/kgsl_clk',
    'kgsl/kgsl_gpubusy',
    'kgsl/kgsl_pwrlevel'
)
$script:DiscoverableGpuFtraceEvents = @(
    $script:CapturedOptionalGpuFtraceEvents +
    $script:ExcludedVendorGpuFtraceEvents
)

function Require([bool] $Condition, [string] $Message) {
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function Test-Throws([Parameter(Mandatory)][scriptblock] $Operation) {
    try {
        & $Operation
        return $false
    } catch {
        return $true
    }
}

function Get-Sha256Text([Parameter(Mandatory)][string] $Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return -join @($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('X2') })
    } finally {
        $algorithm.Dispose()
    }
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-Sha256Text $text
}

function Get-FileSha256([Parameter(Mandatory)][string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-ExactRc8Lock {
    Require (Test-Path -LiteralPath $script:BuildLockPath -PathType Leaf) `
        'The exact RC8 build lock is missing.'
    Require ((Get-NormalizedTextSha256 $script:BuildLockPath) -ceq
            $script:ExpectedBuildLockSha256) 'The exact RC8 build lock bytes drifted.'
    $lock = Get-Content -Raw -LiteralPath $script:BuildLockPath | ConvertFrom-Json
    Require (
        [string]$lock.status -ceq 'HOST_BUILT_AND_AUDITED' -and
        [string]$lock.target.package -ceq $script:LockedPackage -and
        [string]$lock.target.forbiddenStablePackage -ceq $script:LockedStablePackage -and
        [string]$lock.target.profile -ceq $script:LockedProfile -and
        [int64]$lock.target.versionCode -eq $script:LockedVersionCode -and
        [string]$lock.target.versionName -ceq $script:LockedVersionName -and
        [string]$lock.target.apkSha256 -ceq $script:LockedApkSha256 -and
        [string]$lock.target.signerSha256 -ceq $script:LockedSignerSha256 -and
        [string]$lock.pair.core.sha256 -ceq $script:LockedCoreSha256 -and
        [string]$lock.pair.veq.sha256 -ceq $script:LockedVeqSha256 -and
        [string]$lock.pair.core.fabricVersion -ceq
            '26.2-1.3.15+qc.v71.rc8-mining' -and
        [string]$lock.pair.veq.fabricVersion -ceq '0.7.0-v71.rc6'
    ) 'The exact RC8 identity contract drifted.'
    return $lock
}

$script:BuildLock = Assert-ExactRc8Lock
$script:Package = [string]$script:BuildLock.target.package
$script:StablePackage = [string]$script:BuildLock.target.forbiddenStablePackage
$script:ImmersiveComponent =
    "$($script:Package)/$($script:LockedImmersiveActivity)"
$script:GameDirectory =
    "/sdcard/Android/data/$($script:Package)/files/instances/$($script:LockedProfile)"
$script:CorePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:ArtifactRoot = Join-Path $script:RepoRoot 'artifacts\perfetto\rc8'

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    if ($AdbPath -cne 'adb') {
        throw 'The explicitly requested ADB executable was not found.'
    }
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    throw 'ADB was not found. Pass -AdbPath with the full adb executable path.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $script:DeviceInvocations++
    $lines = @(& $script:Adb @Arguments 2>&1 |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "An ADB operation failed with exit code $exitCode; device output was suppressed."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Test-ExplicitNonNetworkAdbSerial(
    [AllowNull()][AllowEmptyString()][string] $Candidate
) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate -ceq 'auto') {
        return $false
    }
    if ($Candidate -cnotmatch '^[A-Za-z0-9._-]+$' -or $Candidate.Contains(':') -or
            $Candidate.Contains('/') -or $Candidate.Contains('\')) {
        return $false
    }
    if ($Candidate -match '(?i)(?:^adb-|\.local$|_adb(?:-tls)?-connect\._tcp$|_adb\._tcp$)') {
        return $false
    }
    return $true
}

function Read-AdbDeviceRows([Parameter(Mandatory)][string[]] $Lines) {
    @($Lines | ForEach-Object {
        $line = ([string]$_).Trim()
        if ($line -match '^(?<serial>\S+)\s+(?<state>\S+)(?:\s+(?<details>.*))?$' -and
                [string]$Matches.serial -cne 'List') {
            [pscustomobject][ordered]@{
                Serial = [string]$Matches.serial
                State = [string]$Matches.state
                Details = [string]$Matches.details
            }
        }
    })
}

function Get-RecordProperty(
    [Parameter(Mandatory)][object] $Record,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Context
) {
    $property = $Record.PSObject.Properties[$Name]
    Require ($null -ne $property) "$Context omitted $Name."
    return $property.Value
}

function Assert-WindowsUsbPnpSnapshot(
    [Parameter(Mandatory)][string] $ExpectedSerial,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Children,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Parents
) {
    Require (Test-ExplicitNonNetworkAdbSerial $ExpectedSerial) `
        'The Windows USB proof received a network-shaped ADB serial.'
    $expectedParent = $script:QuestUsbParentPrefix + $ExpectedSerial

    $validParents = @($Parents | Where-Object {
        $instanceId = [string](Get-RecordProperty $_ 'InstanceId' 'PnP parent')
        $status = [string](Get-RecordProperty $_ 'Status' 'PnP parent')
        $present = Get-RecordProperty $_ 'Present' 'PnP parent'
        $present -is [bool] -and [bool]$present -and $status -ceq 'OK' -and
            $instanceId.Equals($expectedParent,
                [StringComparison]::OrdinalIgnoreCase)
    })
    Require ($validParents.Count -eq 1) `
        'Windows did not expose one exact present and healthy Quest USB parent.'

    $validChildren = @($Children | Where-Object {
        $instanceId = [string](Get-RecordProperty $_ 'InstanceId' 'PnP child')
        $friendlyName = [string](Get-RecordProperty $_ 'FriendlyName' 'PnP child')
        $status = [string](Get-RecordProperty $_ 'Status' 'PnP child')
        $present = Get-RecordProperty $_ 'Present' 'PnP child'
        $parentInstanceId =
            [string](Get-RecordProperty $_ 'ParentInstanceId' 'PnP child')
        $present -is [bool] -and [bool]$present -and $status -ceq 'OK' -and
            $instanceId -cmatch '^USB\\' -and
            $friendlyName -match '(?i)(?:^|\s)ADB Interface$' -and
            $parentInstanceId.Equals($expectedParent,
                [StringComparison]::OrdinalIgnoreCase)
    })
    Require ($validChildren.Count -eq 1) `
        'Windows did not expose one exact present and healthy ADB child of the Quest USB parent.'
    return $true
}

function Get-WindowsUsbPnpSnapshot([Parameter(Mandatory)][string] $ExpectedSerial) {
    Require ($IsWindows) 'Windows PnP USB proof is unavailable on this Host.'
    Require ($null -ne (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) -and
            $null -ne (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) `
        'Windows PnP inspection commands are unavailable.'

    $expectedParent = $script:QuestUsbParentPrefix + $ExpectedSerial
    try {
        # PnpDevice 1.0 does not accept wildcards for -FriendlyName. Enumerate
        # present devices and apply the strict suffix predicate in memory.
        $pnpDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
        $adbChildren = @($pnpDevices | Where-Object {
            $nameProperty = $_.PSObject.Properties['FriendlyName']
            $instanceProperty = $_.PSObject.Properties['InstanceId']
            $null -ne $nameProperty -and $null -ne $instanceProperty -and
                [string]$nameProperty.Value -match '(?i)(?:^|\s)ADB Interface$' -and
                [string]$instanceProperty.Value -cmatch '^USB\\'
        } | ForEach-Object {
            $child = $_
            $parentProperties = @(Get-PnpDeviceProperty `
                -InstanceId ([string]$child.InstanceId) `
                -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop)
            Require ($parentProperties.Count -eq 1 -and
                    $null -ne $parentProperties[0].PSObject.Properties['Data']) `
                'An ADB child did not expose one PnP parent property.'
            $presentProperty = $child.PSObject.Properties['Present']
            [pscustomobject][ordered]@{
                InstanceId = [string]$child.InstanceId
                FriendlyName = [string]$child.FriendlyName
                Status = [string]$child.Status
                Present = if ($null -ne $presentProperty) {
                    [bool]$presentProperty.Value
                } else {
                    # -PresentOnly is the source of truth on Windows versions
                    # whose PnpDevice object does not expose Present.
                    $true
                }
                ParentInstanceId = [string]$parentProperties[0].Data
            }
        })
        $parents = @(Get-PnpDevice -PresentOnly -InstanceId $expectedParent `
            -ErrorAction Stop | ForEach-Object {
            $presentProperty = $_.PSObject.Properties['Present']
            [pscustomobject][ordered]@{
                InstanceId = [string]$_.InstanceId
                Status = [string]$_.Status
                Present = if ($null -ne $presentProperty) {
                    [bool]$presentProperty.Value
                } else {
                    $true
                }
            }
        })
    } catch {
        throw 'Windows PnP could not prove the requested USB transport.'
    }
    [pscustomobject][ordered]@{ Children = $adbChildren; Parents = $parents }
}

function Assert-WindowsUsbPnpTransport([Parameter(Mandatory)][string] $ExpectedSerial) {
    $snapshot = Get-WindowsUsbPnpSnapshot $ExpectedSerial
    Assert-WindowsUsbPnpSnapshot -ExpectedSerial $ExpectedSerial `
        -Children ([object[]]@($snapshot.Children)) `
        -Parents ([object[]]@($snapshot.Parents)) | Out-Null
}

function Resolve-Device {
    Require (Test-ExplicitNonNetworkAdbSerial $Serial) `
        'Capture requires an explicit USB ADB serial; auto selection is forbidden.'
    $script:Adb = Resolve-Adb
    $result = Invoke-Adb @('devices', '-l')
    $matchingRows = @(Read-AdbDeviceRows ([string[]]@($result.Lines)) |
        Where-Object { $_.Serial -ceq $Serial })
    Require ($matchingRows.Count -eq 1 -and $matchingRows[0].State -ceq 'device') `
        'The explicitly requested ADB endpoint is not connected and authorized.'
    $script:Device = $Serial
    $transport = Invoke-Adb @('-s', $script:Device, 'get-devpath')
    $transportRows = @($transport.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($transportRows.Count -eq 1 -and
            $transportRows[0] -cmatch '^usb:[A-Za-z0-9._:/-]+$') {
        $script:UsbTransportProofMethod = 'adb-devpath'
        return
    }
    Require ($IsWindows -and $transportRows.Count -eq 1 -and
            $transportRows[0] -ceq 'unknown') `
        'The explicitly requested endpoint is not a proven USB transport.'

    $deviceSerialResult = Invoke-Adb @(
        '-s', $script:Device, 'shell', 'getprop', 'ro.serialno')
    $deviceSerialRows = @($deviceSerialResult.Lines |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($deviceSerialRows.Count -eq 1 -and
            $deviceSerialRows[0] -ceq $Serial) `
        'Android did not confirm the exact requested hardware serial.'
    Assert-WindowsUsbPnpTransport $Serial
    $script:UsbTransportProofMethod = 'windows-pnp-parent'
}

function Invoke-Shell([string[]] $Arguments, [switch] $AllowFailure) {
    Invoke-Adb (@('-s', $script:Device, 'shell') + $Arguments) `
        -AllowFailure:$AllowFailure
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [char]39
    return $quote + $Value.Replace([string]$quote,
        $quote + '"' + $quote + '"' + $quote) + $quote
}

function Invoke-RootRead([Parameter(Mandatory)][ValidateSet('Uid', 'Events')][string] $Probe) {
    Require $AllowRootRead.IsPresent 'Root inspection requires explicit -AllowRootRead.'
    $command = if ($Probe -ceq 'Uid') {
        'id -u'
    } else {
        'cat /sys/kernel/tracing/available_events'
    }
    # adb shell reconstructs one remote shell command from its argv. Supplying
    # an explicit POSIX literal here preserves the full Magisk -c operand; a
    # bare argv value containing spaces is not a reliable transport contract.
    Invoke-Shell @($script:RootBinary, '-c', (ConvertTo-ShLiteral $command))
}

function Read-OneUnsignedInteger(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $Context
) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1 -and $rows[0] -cmatch '^[0-9]+$') `
        "$Context returned a malformed value."
    return [uint64]$rows[0]
}

function Get-Pid([Parameter(Mandatory)][string] $ExpectedPackage, [switch] $AllowMissing) {
    $result = Invoke-Shell @('pidof', $ExpectedPackage) -AllowFailure
    $rows = @($result.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($result.ExitCode -eq 1 -and $rows.Count -eq 0 -and $AllowMissing) {
        return $null
    }
    Require ($result.ExitCode -eq 0 -and $rows.Count -eq 1 -and
            $rows[0] -cmatch '^[0-9]+$') 'A process PID was absent or ambiguous.'
    return [int]$rows[0]
}

function Read-ProcessStartTicks([Parameter(Mandatory)][string[]] $Lines) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'The process stat probe was ambiguous.'
    $row = [string]$rows[0]
    $commEnd = $row.LastIndexOf(') ', [StringComparison]::Ordinal)
    Require ($commEnd -gt 0) 'The process stat probe was malformed.'
    $suffix = @($row.Substring($commEnd + 2) -split '\s+')
    Require ($suffix.Count -ge 20 -and $suffix[19] -cmatch '^[0-9]+$') `
        'The process stat probe omitted a valid start time.'
    return [uint64]$suffix[19]
}

function Get-ProcessStartTicks([int] $ProcessId) {
    $result = Invoke-Shell @('cat', "/proc/$ProcessId/stat")
    Read-ProcessStartTicks ([string[]]@($result.Lines))
}

function Test-GameJvm([int] $ProcessId) {
    $result = Invoke-Shell @('cat', "/proc/$ProcessId/task/*/comm")
    return @($result.Lines | Where-Object {
        ([string]$_).Trim() -ceq 'QuestCraft-JVM'
    }).Count -eq 1
}

function Read-SingleActivityComponent([Parameter(Mandatory)][string] $Line) {
    # Parse one Android flattened component without accepting package-prefix
    # lookalikes. Focus rows should name exactly one component; more than one is
    # ambiguous and therefore cannot prove foreground ownership.
    $pattern = '(?<![A-Za-z0-9._])' +
        '(?<package>[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)/' +
        '(?<activity>\.?[A-Za-z_$][A-Za-z0-9_.$]*)' +
        '(?![A-Za-z0-9_.$])'
    $matches = [regex]::Matches($Line, $pattern,
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($matches.Count -ne 1) { return $null }

    $package = [string]$matches[0].Groups['package'].Value
    $activity = [string]$matches[0].Groups['activity'].Value
    if ($activity.StartsWith('.', [StringComparison]::Ordinal)) {
        $activity = $package + $activity
    } elseif (-not $activity.Contains('.', [StringComparison]::Ordinal)) {
        $activity = $package + '.' + $activity
    }
    [pscustomobject][ordered]@{
        Package = $package
        Canonical = "$package/$activity"
    }
}

function Test-ExactLabFocusSnapshot(
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Lines
) {
    # Quest exposes several displays. Oculus ControlBar/SystemUI/toast tasks may
    # each contribute topResumedActivity rows even while the immersive display
    # belongs to Minecraft, so those task-local rows are deliberately ignored.
    # The global window/app focus pair and one display-level resumed record must
    # instead agree on the exact locked immersive component.
    $currentFocusRows = @($Lines | Where-Object {
        [string]$_ -cmatch '^\s*mCurrentFocus\s*='
    })
    $focusedAppRows = @($Lines | Where-Object {
        [string]$_ -cmatch '^\s*mFocusedApp\s*='
    })
    $currentFocusNonNull = @($currentFocusRows | Where-Object {
        [string]$_ -cnotmatch '^\s*mCurrentFocus\s*=\s*null\s*$'
    })
    $focusedAppNonNull = @($focusedAppRows | Where-Object {
        [string]$_ -cnotmatch '^\s*mFocusedApp\s*=\s*null\s*$'
    })
    # Quest emits one focus row per display. Unfocused displays use the exact
    # literal null; they are harmless. Every other row is evidence-bearing (or
    # malformed) and exactly one of each kind must remain.
    if ($currentFocusRows.Count -eq 0 -or $focusedAppRows.Count -eq 0 -or
            $currentFocusNonNull.Count -ne 1 -or
            $focusedAppNonNull.Count -ne 1) {
        return $false
    }
    if ([string]$currentFocusNonNull[0] -cnotmatch
            '^\s*mCurrentFocus\s*=\s*Window\{[^{}\r\n]+\}\s*$' -or
            [string]$focusedAppNonNull[0] -cnotmatch
            '^\s*mFocusedApp\s*=\s*ActivityRecord\{[^{}\r\n]+\}\s*$') {
        return $false
    }

    $windowComponent =
        Read-SingleActivityComponent ([string]$currentFocusNonNull[0])
    $appComponent =
        Read-SingleActivityComponent ([string]$focusedAppNonNull[0])
    if ($null -eq $windowComponent -or $null -eq $appComponent -or
            $windowComponent.Canonical -cne $script:ImmersiveComponent -or
            $appComponent.Canonical -cne $script:ImmersiveComponent) {
        return $false
    }

    $currentDisplay = $null
    $labDisplayResumed = [Collections.Generic.List[object]]::new()
    foreach ($rawLine in $Lines) {
        $line = [string]$rawLine
        $displayMatch = [regex]::Match($line,
            '^\s*Display #(?<id>[0-9]+)\b',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if ($displayMatch.Success) {
            $currentDisplay = [string]$displayMatch.Groups['id'].Value
            continue
        }
        if ($line -cmatch '^\s*ActivityTaskSupervisor\b') {
            $currentDisplay = $null
            continue
        }
        if ($null -eq $currentDisplay -or
                $line -cnotmatch '^\s*(?:mResumedActivity|ResumedActivity)\s*[:=]') {
            continue
        }

        $component = Read-SingleActivityComponent $line
        if ($null -eq $component) { continue }
        if ($component.Package -ceq $script:StablePackage) { return $false }
        if ($component.Canonical -ceq $script:ImmersiveComponent) {
            $labDisplayResumed.Add([pscustomobject]@{
                Display = $currentDisplay
                Component = $component.Canonical
            })
        }
    }

    return $labDisplayResumed.Count -eq 1 -and
        $labDisplayResumed[0].Component -ceq $windowComponent.Canonical -and
        $labDisplayResumed[0].Component -ceq $appComponent.Canonical
}

function Test-LabFocused {
    $result = Invoke-Shell @('dumpsys', 'activity', 'activities')
    return Test-ExactLabFocusSnapshot ([string[]]@($result.Lines))
}

function Assert-StableStopped([string] $Context) {
    Require ($null -eq (Get-Pid -ExpectedPackage $script:StablePackage -AllowMissing)) `
        "$Context Stable is running; this diagnostic refuses to continue."
}

function Assert-RuntimeFence(
    [int] $ExpectedPid,
    [uint64] $ExpectedStartTicks,
    [string] $Context
) {
    Assert-StableStopped $Context
    Require ((Get-Pid -ExpectedPackage $script:Package) -eq $ExpectedPid) `
        "$Context Lab PID changed."
    Require ((Get-ProcessStartTicks $ExpectedPid) -eq $ExpectedStartTicks) `
        "$Context Lab process incarnation changed."
    Require (Test-GameJvm $ExpectedPid) "$Context game JVM disappeared."
    Require (Test-LabFocused) "$Context Lab is not the focused resumed activity."
}

function Read-PackageIdentity([Parameter(Mandatory)][string[]] $Lines) {
    $versionCodes = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_,
            '^\s*versionCode=(?<value>[0-9]+)(?:\s|$)')
        if ($match.Success) { [int64]$match.Groups['value'].Value }
    })
    $versionNames = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_,
            '^\s*versionName=(?<value>\S+)\s*$')
        if ($match.Success) { [string]$match.Groups['value'].Value }
    })
    Require ($versionCodes.Count -eq 1 -and $versionNames.Count -eq 1) `
        'The installed application identity was incomplete or ambiguous.'
    [pscustomobject]@{
        VersionCode = [int64]$versionCodes[0]
        VersionName = [string]$versionNames[0]
    }
}

function Read-ExactBaseApkPath([Parameter(Mandatory)][string[]] $Lines) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1 -and
            $rows[0] -cmatch
                '^package:(?<path>/data/app/(?:[A-Za-z0-9._~+=-]+/)+base\.apk)$') `
        'The Lab package did not expose exactly one safe base APK.'
    $path = [string]$Matches.path
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)') -and
            -not $path.Contains('/../', [StringComparison]::Ordinal) -and
            -not $path.Contains('/./', [StringComparison]::Ordinal)) `
        'The base APK path was not bound to the isolated Lab package.'
    return $path
}

function Read-Sha256Sum(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $ExpectedPath
) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'A digest probe was ambiguous.'
    $match = [regex]::Match($rows[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require ($match.Success -and
            [string]$match.Groups['path'].Value -ceq $ExpectedPath) `
        'A digest probe named unexpected data.'
    return ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RemoteSha256([Parameter(Mandatory)][string] $Path) {
    $result = Invoke-Shell @('sha256sum', $Path)
    Read-Sha256Sum ([string[]]@($result.Lines)) $Path
}

function Assert-ExactDeviceIdentity {
    $packageResult = Invoke-Shell @('dumpsys', 'package', $script:Package)
    $identity = Read-PackageIdentity ([string[]]@($packageResult.Lines))
    Require ($identity.VersionCode -eq $script:LockedVersionCode -and
            $identity.VersionName -ceq $script:LockedVersionName) `
        'The installed Lab application is not exact RC8.'
    $basePath = Read-ExactBaseApkPath ([string[]]@(
        (Invoke-Shell @('pm', 'path', $script:Package)).Lines))
    Require ((Read-RemoteSha256 $basePath) -ceq $script:LockedApkSha256) `
        'The installed Lab APK is not the exact locked RC8 APK.'
    Require ((Read-RemoteSha256 $script:CorePath) -ceq $script:LockedCoreSha256) `
        'The physical Core is not exact RC8.'
    Require ((Read-RemoteSha256 $script:VeqPath) -ceq $script:LockedVeqSha256) `
        'The physical companion is not exact RC8.'
    [pscustomobject][ordered]@{
        VersionMatched = $true
        ApkMatched = $true
        CoreMatched = $true
        CompanionMatched = $true
        SignerBoundByExactApk = $true
        AllMatched = $true
    }
}

function Get-SupportedFtraceEvents {
    $uid = Read-OneUnsignedInteger ([string[]]@((Invoke-RootRead Uid).Lines)) `
        'The root capability probe'
    Require ($uid -eq 0) 'Magisk root read capability was not available.'
    $result = Invoke-RootRead Events
    $available = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($token in (($result.Lines -join "`n") -split '\s+')) {
        if ($token -cmatch '^(?<group>[A-Za-z0-9_.-]+):(?<event>[A-Za-z0-9_.-]+)$') {
            [void]$available.Add("$($Matches.group)/$($Matches.event)")
        }
    }
    Require ($available.Count -gt 0) 'Root tracing-event discovery returned no valid events.'
    foreach ($event in $script:MandatoryFtraceEvents) {
        Require $available.Contains($event) "Required tracepoint $event is unavailable."
    }
    $gpu = @($script:CapturedOptionalGpuFtraceEvents | Where-Object {
        $available.Contains($_)
    })
    $availableFixed = @(
        $script:MandatoryFtraceEvents + $script:DiscoverableGpuFtraceEvents |
            Where-Object { $available.Contains($_) }
    )
    $excludedAvailable = @($script:ExcludedVendorGpuFtraceEvents |
        Where-Object { $available.Contains($_) })
    [pscustomobject]@{
        Enabled = @($script:MandatoryFtraceEvents + $gpu)
        AvailableFixed = $availableFixed
        CapturedGpu = $gpu
        ExcludedAvailableByPolicy = $excludedAvailable
        DiscoverySucceeded = $true
    }
}

function New-TraceConfig(
    [Parameter(Mandatory)][string[]] $FtraceEvents,
    [Parameter(Mandatory)][int] $DurationSeconds
) {
    $allowed = @(
        $script:MandatoryFtraceEvents + $script:CapturedOptionalGpuFtraceEvents)
    Require (@($FtraceEvents | Where-Object { $_ -cnotin $allowed }).Count -eq 0) `
        'The trace requested an event outside the fixed privacy allowlist.'
    foreach ($required in $script:MandatoryFtraceEvents) {
        Require ($FtraceEvents -ccontains $required) `
            "The trace omitted required event $required."
    }
    $rows = ($FtraceEvents | Sort-Object -Unique | ForEach-Object {
        '      ftrace_events: "' + $_ + '"'
    }) -join "`n"
    $config = @"
buffers {
  size_kb: 65536
  fill_policy: RING_BUFFER
}
data_sources {
  config {
    name: "linux.ftrace"
    target_buffer: 0
    ftrace_config {
$rows
      drain_period_ms: 250
      symbolize_ksyms: false
    }
  }
}
data_sources {
  config {
    name: "linux.process_stats"
    target_buffer: 0
    process_stats_config {
      scan_all_processes_on_start: true
      proc_stats_poll_ms: 1000
      record_thread_names: true
    }
  }
}
duration_ms: $($DurationSeconds * 1000)
flush_period_ms: 5000
compression_type: COMPRESSION_TYPE_DEFLATE
"@
    foreach ($forbidden in @(
        'linux.perf', 'callstack', 'atrace_', 'android.log',
        'android.packages_list', 'binder', 'raw_syscalls', 'heapprofd',
        'ftrace_events: "net/', 'ftrace_events: "block/',
        'ftrace_events: "filemap/', 'sys_enter', 'sys_exit'
    )) {
        Require (-not $config.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) `
            "The trace config contains forbidden source token $forbidden."
    }
    return $config
}

function Assert-SafeDevicePath([Parameter(Mandatory)][string] $Path) {
    Require ($Path -cmatch
            '^/data/local/tmp/qc-rc8-perfetto-[0-9a-f]{32}\.(?:pbtxt|pftrace)$') `
        'An ephemeral device path escaped the fixed randomized namespace.'
    return $Path
}

function Test-DevicePathAbsent([Parameter(Mandatory)][string] $Path) {
    $null = Assert-SafeDevicePath $Path
    $fileAbsent = Invoke-Shell @('test', '!', '-e', $Path) -AllowFailure
    $linkAbsent = Invoke-Shell @('test', '!', '-L', $Path) -AllowFailure
    return $fileAbsent.ExitCode -eq 0 -and $linkAbsent.ExitCode -eq 0
}

function Remove-EphemeralDeviceFiles(
    [Parameter(Mandatory)][string] $DeviceConfig,
    [Parameter(Mandatory)][string] $DeviceTrace
) {
    $null = Assert-SafeDevicePath $DeviceConfig
    $null = Assert-SafeDevicePath $DeviceTrace
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $remove = Invoke-Shell @('rm', '-f', $DeviceConfig, $DeviceTrace) `
            -AllowFailure
        if ($remove.ExitCode -eq 0 -and
                (Test-DevicePathAbsent $DeviceConfig) -and
                (Test-DevicePathAbsent $DeviceTrace)) {
            return $true
        }
    }
    return $false
}

function Read-PerfettoPid([Parameter(Mandatory)][string[]] $Lines) {
    $pids = @($Lines | ForEach-Object {
        $row = ([string]$_).Trim()
        if ($row -cmatch '^(?:pid\s*[:=]\s*)?(?<pid>[0-9]+)$') {
            [int]$Matches.pid
        }
    } | Sort-Object -Unique)
    Require ($pids.Count -eq 1 -and $pids[0] -gt 1) `
        'Perfetto did not return one unambiguous background PID.'
    return [int]$pids[0]
}

function Read-RemoteSize([Parameter(Mandatory)][string] $Path) {
    $result = Invoke-Shell @('stat', '-c', '%s', $Path)
    $value = Read-OneUnsignedInteger ([string[]]@($result.Lines)) 'The trace-size probe'
    Require ($value -le 268435456) 'The raw trace exceeded the 256 MiB safety ceiling.'
    return [uint64]$value
}

function Wait-ForPerfetto(
    [int] $PerfettoPid,
    [int] $ExpectedLabPid,
    [uint64] $ExpectedLabStartTicks,
    [int] $DurationSeconds
) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $polls = 0
    while ($true) {
        $alive = Invoke-Shell @('test', '-d', "/proc/$PerfettoPid") -AllowFailure
        if ($alive.ExitCode -ne 0) { break }
        Assert-RuntimeFence $ExpectedLabPid $ExpectedLabStartTicks 'During capture:'
        $polls++
        Require ($deadline.Elapsed.TotalSeconds -le ($DurationSeconds + 15)) `
            'Perfetto exceeded its bounded duration; cleanup will run.'
        Start-Sleep -Milliseconds 2000
    }
    Assert-RuntimeFence $ExpectedLabPid $ExpectedLabStartTicks 'After capture:'
    return $polls
}

function New-PrivateHostTemp {
    $path = Join-Path ([IO.Path]::GetTempPath()) `
        ('qc-rc8-perfetto-' + [guid]::NewGuid().ToString('N'))
    Require (-not (Test-Path -LiteralPath $path)) 'The randomized Host temp path exists.'
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Remove-PrivateHostTemp(
    [Parameter(Mandatory)][string] $Path,
    [scriptblock] $DeleteOperation = $null
) {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    Require ($resolved.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolved) -cmatch '^qc-rc8-perfetto-[0-9a-f]{32}$') `
        'Refusing to clean an unexpected Host directory.'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            if (Test-Path -LiteralPath $resolved) {
                if ($null -eq $DeleteOperation) {
                    [IO.Directory]::Delete($resolved, $true)
                } else {
                    & $DeleteOperation $resolved
                }
            }
        } catch {
            # The caller receives a fail-closed Boolean after both bounded tries.
        }
        if (-not (Test-Path -LiteralPath $resolved)) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Capture-RawTrace(
    [Parameter(Mandatory)][string] $Config,
    [Parameter(Mandatory)][string] $HostTemp,
    [int] $ExpectedPid,
    [uint64] $ExpectedStartTicks
) {
    Require $AllowEphemeralDeviceIo.IsPresent `
        'Capture requires explicit -AllowEphemeralDeviceIo.'
    $runId = [guid]::NewGuid().ToString('N')
    $deviceConfig = Assert-SafeDevicePath `
        "/data/local/tmp/qc-rc8-perfetto-$runId.pbtxt"
    $deviceTrace = Assert-SafeDevicePath `
        "/data/local/tmp/qc-rc8-perfetto-$runId.pftrace"
    $hostConfig = Join-Path $HostTemp 'capture.pbtxt'
    $hostTrace = Join-Path $HostTemp 'capture.pftrace'
    $cleanupAttempted = $false
    try {
        Require ((Test-DevicePathAbsent $deviceConfig) -and
                (Test-DevicePathAbsent $deviceTrace)) `
            'The randomized device paths unexpectedly exist.'
        [IO.File]::WriteAllText($hostConfig, $Config, [Text.UTF8Encoding]::new($false))
        $hostConfigSha = Get-FileSha256 $hostConfig
        $push = Invoke-Adb @('-s', $script:Device, 'push', $hostConfig, $deviceConfig) `
            -AllowFailure
        Require ($push.ExitCode -eq 0) 'The ephemeral Perfetto config push failed.'
        Require ((Read-RemoteSha256 $deviceConfig) -ceq $hostConfigSha) `
            'The ephemeral Perfetto config did not verify after transfer.'

        Assert-RuntimeFence $ExpectedPid $ExpectedStartTicks 'Immediately before capture:'
        $start = Invoke-Shell @(
            'perfetto', '--background-wait', '--txt',
            '-c', $deviceConfig, '-o', $deviceTrace
        )
        $perfettoPid = Read-PerfettoPid ([string[]]@($start.Lines))
        $pollCount = Wait-ForPerfetto $perfettoPid $ExpectedPid $ExpectedStartTicks $Seconds

        $firstSize = Read-RemoteSize $deviceTrace
        Start-Sleep -Milliseconds 750
        $secondSize = Read-RemoteSize $deviceTrace
        Require ($firstSize -eq $secondSize -and $secondSize -ge 4096) `
            'The Perfetto trace was absent, too small, or still changing.'
        $remoteTraceSha = Read-RemoteSha256 $deviceTrace
        $pull = Invoke-Adb @('-s', $script:Device, 'pull', $deviceTrace, $hostTrace) `
            -AllowFailure
        Require ($pull.ExitCode -eq 0 -and
                (Test-Path -LiteralPath $hostTrace -PathType Leaf)) `
            'The ephemeral Perfetto trace pull failed.'
        Require (([uint64](Get-Item -LiteralPath $hostTrace).Length) -eq $secondSize -and
                (Get-FileSha256 $hostTrace) -ceq $remoteTraceSha) `
            'The pulled Perfetto trace failed byte identity verification.'
        [pscustomobject]@{
            HostTrace = $hostTrace
            PollCount = $pollCount
            DeviceCleanupSucceeded = $false
        }
    } finally {
        $cleanupAttempted = $true
        $clean = Remove-EphemeralDeviceFiles $deviceConfig $deviceTrace
        if (Test-Path -LiteralPath $hostConfig) {
            Remove-Item -LiteralPath $hostConfig -Force
        }
        Require ($cleanupAttempted -and $clean) `
            'Ephemeral device cleanup failed; no aggregate report was accepted.'
    }
}

function Find-KnownTraceProcessor {
    $cursor = $script:RepoRoot
    for ($i = 0; $i -lt 8 -and $null -ne $cursor; $i++) {
        $candidate = Join-Path $cursor `
            'backups\20260831-vivecraft-v60-perfetto\tools\trace_processor'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { break }
        $cursor = $parent
    }
    return $null
}

function Resolve-TraceProcessor {
    if (-not [string]::IsNullOrWhiteSpace($TraceProcessorPath)) {
        Require (Test-Path -LiteralPath $TraceProcessorPath -PathType Leaf) `
            'The explicitly requested trace processor is missing.'
        return (Resolve-Path -LiteralPath $TraceProcessorPath).Path
    }
    foreach ($name in @('trace_processor_shell', 'trace_processor')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    $known = Find-KnownTraceProcessor
    Require ($null -ne $known) `
        'trace_processor was not found. Pass -TraceProcessorPath.'
    return (Resolve-Path -LiteralPath $known).Path
}

function Invoke-ProcessCapture(
    [Parameter(Mandatory)][string] $FileName,
    [Parameter(Mandatory)][string[]] $Arguments
) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $extension = [IO.Path]::GetExtension($FileName)
    if ($extension -ceq '.ps1') {
        $psi.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        [void]$psi.ArgumentList.Add('-NoLogo')
        [void]$psi.ArgumentList.Add('-NoProfile')
        [void]$psi.ArgumentList.Add('-NonInteractive')
        [void]$psi.ArgumentList.Add('-File')
        [void]$psi.ArgumentList.Add($FileName)
    } elseif ($extension -notin @('.exe', '.cmd', '.bat', '.com')) {
        $psi.FileName = (Get-Command python -ErrorAction Stop).Source
        [void]$psi.ArgumentList.Add($FileName)
    } else {
        $psi.FileName = $FileName
    }
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        Require $process.Start() 'Could not start trace_processor.'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        Require ($process.ExitCode -eq 0) `
            "trace_processor exited with code $($process.ExitCode); output was suppressed."
        return [pscustomobject]@{ Stdout = $stdout; StderrPresent =
            -not [string]::IsNullOrWhiteSpace($stderr) }
    } finally {
        $process.Dispose()
    }
}

function Invoke-TraceQuery(
    [Parameter(Mandatory)][string] $Processor,
    [Parameter(Mandatory)][string] $Trace,
    [Parameter(Mandatory)][string] $Sql,
    [Parameter(Mandatory)][string] $QueryName,
    [Parameter(Mandatory)][string] $HostTemp
) {
    Require ($QueryName -cmatch '^[A-Z_]+$') 'An unsafe query name was supplied.'
    $query = Join-Path $HostTemp ("query-$($QueryName.ToLowerInvariant()).sql")
    try {
        [IO.File]::WriteAllText($query, "-- QC_QUERY: $QueryName`n$Sql",
            [Text.UTF8Encoding]::new($false))
        $capture = Invoke-ProcessCapture $Processor @('query', '-f', $query, $Trace)
        $text = [string]$capture.Stdout
        Require (-not [string]::IsNullOrWhiteSpace($text)) `
            "Trace query $QueryName returned no CSV header."
        return @($text | ConvertFrom-Csv)
    } finally {
        if (Test-Path -LiteralPath $query) { Remove-Item -LiteralPath $query -Force }
    }
}

function Convert-NullableDouble($Value) {
    if ($null -eq $Value -or [string]$Value -eq '[NULL]' -or
            [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    [double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Convert-NullableInt64($Value) {
    if ($null -eq $Value -or [string]$Value -eq '[NULL]' -or
            [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    [int64]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Convert-AppThreadLabel([AllowEmptyString()][string] $Name) {
    switch -Regex ($Name) {
        '^QuestCraft-JVM$' { return 'QuestCraftJVM' }
        '^Render thread$' { return 'RenderThread' }
        '^Server thread$' { return 'ServerThread' }
        '^OpenXR' { return 'OpenXR' }
        '^Netty Client IO' { return 'NettyClientIO' }
        '^Worker-Main' { return 'WorkerMain' }
        '^ForkJoinPool' { return 'ForkJoinPool' }
        '^Chunk Render' { return 'ChunkRender' }
        '^Sodium Async Cu$' { return 'SodiumAsyncWorker' }
        '^Sodium Async Chunk Builder(?: #[0-9]+)?$' { return 'SodiumAsyncWorker' }
        '^UnityChoreograp(?:her)?$' { return 'UnityFramePacer' }
        '^UnityMain$' { return 'UnityRuntimeMain' }
        '^FMOD stream(?: thread)?$' { return 'FmodStreamAudio' }
        '^FMOD mixer(?: thread)?$' { return 'FmodMixerAudio' }
        '^alsoft-mixer$' { return 'OpenAlMixerAudio' }
        '^Sound engine$' { return 'SoundEngine' }
        '^(?:C[0-9]+ CompilerThread|Jit thread pool)' { return 'JitCompiler' }
        '^(?:G1 Conc#[0-9]+|GC Thread|HeapTaskDaemon|ReferenceQueueDaemon)' {
            return 'GarbageCollector'
        }
        default { return 'OtherAppThread' }
    }
}

function Analyze-Trace(
    [Parameter(Mandatory)][string] $Trace,
    [Parameter(Mandatory)][int] $CapturedPid,
    [Parameter(Mandatory)][string] $HostTemp
) {
    $processor = Resolve-TraceProcessor
    $summarySql = @"
WITH b AS (SELECT start_ts, end_ts, end_ts - start_ts AS dur_ns FROM trace_bounds),
app AS (SELECT upid FROM process WHERE pid = $CapturedPid),
app_cpu AS (
  SELECT COALESCE(SUM(s.dur), 0) AS ns, COUNT(*) AS rows
  FROM sched s JOIN thread t USING(utid) WHERE t.upid IN app AND s.dur > 0
),
app_wait AS (
  SELECT COALESCE(SUM(ts.dur), 0) AS ns
  FROM thread_state ts JOIN thread t USING(utid)
  WHERE t.upid IN app AND ts.state IN ('R','R+') AND ts.dur > 0
)
SELECT ROUND((SELECT dur_ns FROM b) / 1e9, 3) AS trace_seconds,
       (SELECT COUNT(*) FROM app) AS app_upid_count,
       (SELECT rows FROM app_cpu) AS sched_rows,
       ROUND((SELECT ns FROM app_cpu) / 1e6, 3) AS app_cpu_ms,
       ROUND(100.0 * (SELECT ns FROM app_cpu) / (SELECT dur_ns FROM b), 3) AS app_one_core_percent,
       ROUND((SELECT ns FROM app_wait) / 1e6, 3) AS runnable_wait_ms,
       ROUND(100.0 * (SELECT ns FROM app_wait) / (SELECT dur_ns FROM b), 3) AS runnable_wait_one_core_percent,
       (SELECT COUNT(*) FROM thread WHERE upid IN app) AS app_thread_count,
       (SELECT COUNT(*) FROM counter c JOIN process_counter_track pct ON c.track_id = pct.id WHERE pct.upid IN app) AS process_counter_samples;
"@
    $threadsSql = @"
WITH b AS (SELECT end_ts - start_ts AS dur_ns FROM trace_bounds),
app AS (SELECT upid FROM process WHERE pid = $CapturedPid),
cpu AS (
  SELECT t.utid, COALESCE(t.name, '') AS thread_name, SUM(s.dur) AS cpu_ns
  FROM sched s JOIN thread t USING(utid)
  WHERE t.upid IN app AND s.dur > 0 GROUP BY t.utid, t.name
),
total AS (SELECT COALESCE(SUM(cpu_ns), 0) AS ns FROM cpu),
waits AS (
  SELECT t.utid,
    SUM(CASE WHEN ts.state IN ('R','R+') AND ts.dur > 0 THEN ts.dur ELSE 0 END) AS wait_ns,
    PERCENTILE(CASE WHEN ts.state IN ('R','R+') AND ts.dur > 0 THEN ts.dur / 1e6 END, 95) AS p95_ms,
    MAX(CASE WHEN ts.state IN ('R','R+') AND ts.dur > 0 THEN ts.dur ELSE 0 END) AS max_ns,
    SUM(CASE WHEN ts.state IN ('R','R+') AND ts.dur >= 1000000 THEN 1 ELSE 0 END) AS ge1,
    SUM(CASE WHEN ts.state IN ('R','R+') AND ts.dur >= 2000000 THEN 1 ELSE 0 END) AS ge2,
    SUM(CASE WHEN ts.state IN ('R','R+') AND ts.dur >= 4000000 THEN 1 ELSE 0 END) AS ge4
  FROM thread_state ts JOIN thread t USING(utid)
  WHERE t.upid IN app GROUP BY t.utid
)
SELECT cpu.thread_name,
       ROUND(cpu.cpu_ns / 1e6, 3) AS cpu_ms,
       ROUND(100.0 * cpu.cpu_ns / NULLIF(total.ns, 0), 3) AS app_cpu_percent,
       ROUND(100.0 * cpu.cpu_ns / b.dur_ns, 3) AS one_core_percent,
       ROUND(COALESCE(waits.wait_ns, 0) / 1e6, 3) AS runnable_wait_ms,
       ROUND(waits.p95_ms, 3) AS runnable_p95_ms,
       ROUND(COALESCE(waits.max_ns, 0) / 1e6, 3) AS runnable_max_ms,
       COALESCE(waits.ge1, 0) AS waits_ge_1ms,
       COALESCE(waits.ge2, 0) AS waits_ge_2ms,
       COALESCE(waits.ge4, 0) AS waits_ge_4ms
FROM cpu CROSS JOIN total CROSS JOIN b LEFT JOIN waits USING(utid)
ORDER BY cpu.cpu_ns DESC LIMIT 64;
"@
    $frequencySql = @"
WITH b AS (SELECT start_ts, end_ts FROM trace_bounds), samples AS (
  SELECT ct.cpu, CAST(c.value AS INT) AS freq_khz, c.ts,
         LEAD(c.ts, 1, (SELECT end_ts FROM b)) OVER
             (PARTITION BY ct.cpu ORDER BY c.ts) AS next_ts
  FROM cpu_counter_track ct JOIN counter c ON c.track_id = ct.id
  WHERE ct.name = 'cpufreq'
)
SELECT cpu, freq_khz, COUNT(*) AS samples,
       ROUND(SUM(MAX(0, MIN(next_ts, (SELECT end_ts FROM b)) - MAX(ts, (SELECT start_ts FROM b)))) / 1e6, 3) AS duration_ms
FROM samples WHERE freq_khz >= 0 GROUP BY cpu, freq_khz ORDER BY cpu, freq_khz;
"@
    $idleSql = @"
WITH b AS (SELECT start_ts, end_ts FROM trace_bounds), samples AS (
  SELECT ct.cpu, CAST(c.value AS INT) AS idle_state, c.ts,
         LEAD(c.ts, 1, (SELECT end_ts FROM b)) OVER
             (PARTITION BY ct.cpu ORDER BY c.ts) AS next_ts
  FROM cpu_counter_track ct JOIN counter c ON c.track_id = ct.id
  WHERE ct.name = 'cpuidle'
)
SELECT cpu, idle_state, COUNT(*) AS samples,
       ROUND(SUM(MAX(0, MIN(next_ts, (SELECT end_ts FROM b)) - MAX(ts, (SELECT start_ts FROM b)))) / 1e6, 3) AS duration_ms
FROM samples GROUP BY cpu, idle_state ORDER BY cpu, idle_state;
"@
    $processCountersSql = @"
WITH app AS (SELECT upid FROM process WHERE pid = $CapturedPid)
SELECT CASE pct.name
         WHEN 'mem.rss' THEN 'RssBytes'
         WHEN 'mem.virt' THEN 'VirtualBytes'
         WHEN 'mem.swap' THEN 'SwapBytes'
         WHEN 'oom_score_adj' THEN 'OomScoreAdjustment'
       END AS metric,
       COUNT(*) AS samples, ROUND(AVG(c.value), 3) AS mean_value,
       ROUND(PERCENTILE(c.value, 95), 3) AS p95_value,
       ROUND(MAX(c.value), 3) AS max_value
FROM process_counter_track pct JOIN counter c ON c.track_id = pct.id
WHERE pct.upid IN app AND pct.name IN ('mem.rss','mem.virt','mem.swap','oom_score_adj')
GROUP BY pct.name ORDER BY metric;
"@
    $gpuMemorySql = @"
WITH rows AS (
  SELECT CAST(EXTRACT_ARG(r.arg_set_id, 'pid') AS INT) AS pid,
         CAST(EXTRACT_ARG(r.arg_set_id, 'size') AS DOUBLE) AS bytes
  FROM raw r WHERE r.name = 'gpu_mem_total'
), app AS (SELECT bytes FROM rows WHERE pid = $CapturedPid AND bytes >= 0)
SELECT COUNT(*) AS samples,
       ROUND(AVG(bytes) / 1048576.0, 3) AS mean_mib,
       ROUND(PERCENTILE(bytes / 1048576.0, 95), 3) AS p95_mib,
       ROUND(MAX(bytes) / 1048576.0, 3) AS max_mib
FROM app;
"@
    $kgslSql = @"
WITH normalized AS (
  SELECT CASE name
         WHEN 'kgsl_adreno_cmdbatch_submitted' THEN 'Submitted'
         WHEN 'adreno_cmdbatch_submitted' THEN 'Submitted'
         WHEN 'kgsl_adreno_cmdbatch_retired' THEN 'Retired'
         WHEN 'adreno_cmdbatch_retired' THEN 'Retired'
        END AS metric
  FROM raw
  WHERE name IN ('kgsl_adreno_cmdbatch_submitted','adreno_cmdbatch_submitted',
                  'kgsl_adreno_cmdbatch_retired','adreno_cmdbatch_retired')
)
SELECT metric, COUNT(*) AS occurrences FROM normalized
WHERE metric IS NOT NULL GROUP BY metric ORDER BY metric;
"@
    $healthSql = @"
SELECT
  COALESCE(SUM(CASE WHEN name = 'ftrace_setup_errors' AND value > 0 THEN value ELSE 0 END), 0) AS ftrace_setup_errors,
  COALESCE(SUM(CASE WHEN name IN ('ftrace_dropped_events','ftrace_cpu_dropped_events_delta') AND value > 0 THEN value ELSE 0 END), 0) AS ftrace_dropped_events,
  COALESCE(SUM(CASE WHEN name IN ('ftrace_cpu_commit_overrun_delta','ftrace_cpu_overrun_delta') AND value > 0 THEN value ELSE 0 END), 0) AS ftrace_overruns,
  COALESCE(SUM(CASE WHEN name = 'perf_samples_skipped' AND value > 0 THEN value ELSE 0 END), 0) AS perf_samples_skipped,
  COALESCE(SUM(CASE WHEN severity = 'data_loss' AND value > 0 THEN value ELSE 0 END), 0) AS data_loss,
  COALESCE(SUM(CASE WHEN name IN ('traced_buf_buffer_overruns','traced_buf_data_loss_overwrite') AND value > 0 THEN value ELSE 0 END), 0) AS buffer_overruns
FROM stats;
"@

    $summaryRows = @(Invoke-TraceQuery $processor $Trace $summarySql 'SUMMARY' $HostTemp)
    Require ($summaryRows.Count -eq 1) 'The trace summary was absent or ambiguous.'
    $summary = $summaryRows[0]
    $actualSeconds = Convert-NullableDouble $summary.trace_seconds
    $upidCount = Convert-NullableInt64 $summary.app_upid_count
    $schedRows = Convert-NullableInt64 $summary.sched_rows
    Require ($null -ne $actualSeconds -and $actualSeconds -ge ($Seconds - 2) -and
            $actualSeconds -le ($Seconds + 5)) 'Trace duration fell outside the bounded window.'
    Require ($upidCount -eq 1 -and $schedRows -gt 0) `
        'The trace did not bind one schedulable process to the captured Lab PID.'

    $threadRows = @(Invoke-TraceQuery $processor $Trace $threadsSql 'THREADS' $HostTemp)
    Require ($threadRows.Count -gt 0) 'The captured Lab PID had no app thread rows.'
    $rank = 0
    $threads = @($threadRows | ForEach-Object {
        $rank++
        [ordered]@{
            Rank = $rank
            Category = Convert-AppThreadLabel ([string]$_.thread_name)
            CpuMs = Convert-NullableDouble $_.cpu_ms
            AppCpuPercent = Convert-NullableDouble $_.app_cpu_percent
            OneCorePercent = Convert-NullableDouble $_.one_core_percent
            RunnableWaitMs = Convert-NullableDouble $_.runnable_wait_ms
            RunnableP95Ms = Convert-NullableDouble $_.runnable_p95_ms
            RunnableMaxMs = Convert-NullableDouble $_.runnable_max_ms
            RunnableAtLeast1Ms = Convert-NullableInt64 $_.waits_ge_1ms
            RunnableAtLeast2Ms = Convert-NullableInt64 $_.waits_ge_2ms
            RunnableAtLeast4Ms = Convert-NullableInt64 $_.waits_ge_4ms
        }
    })
    $frequencies = @(Invoke-TraceQuery $processor $Trace $frequencySql 'CPU_FREQUENCY' $HostTemp |
        ForEach-Object {
            [ordered]@{
                Cpu = [int]$_.cpu
                FrequencyKhz = Convert-NullableInt64 $_.freq_khz
                Samples = Convert-NullableInt64 $_.samples
                DurationMs = Convert-NullableDouble $_.duration_ms
            }
        })
    $idle = @(Invoke-TraceQuery $processor $Trace $idleSql 'CPU_IDLE' $HostTemp |
        ForEach-Object {
            [ordered]@{
                Cpu = [int]$_.cpu
                State = Convert-NullableInt64 $_.idle_state
                Samples = Convert-NullableInt64 $_.samples
                DurationMs = Convert-NullableDouble $_.duration_ms
            }
        })
    $processCounters = @(Invoke-TraceQuery $processor $Trace $processCountersSql `
        'PROCESS_COUNTERS' $HostTemp | ForEach-Object {
            Require ([string]$_.metric -cin @(
                'RssBytes','VirtualBytes','SwapBytes','OomScoreAdjustment')) `
                'An unapproved process-counter label escaped the aggregate query.'
            [ordered]@{
                Metric = [string]$_.metric
                Samples = Convert-NullableInt64 $_.samples
                Mean = Convert-NullableDouble $_.mean_value
                P95 = Convert-NullableDouble $_.p95_value
                Max = Convert-NullableDouble $_.max_value
            }
        })
    $gpuRows = @(Invoke-TraceQuery $processor $Trace $gpuMemorySql 'GPU_MEMORY' $HostTemp)
    Require ($gpuRows.Count -eq 1) 'The PID-scoped GPU-memory summary was ambiguous.'
    $gpu = $gpuRows[0]
    $kgslRows = @(Invoke-TraceQuery $processor $Trace $kgslSql 'KGSL_EVENTS' $HostTemp)
    $kgsl = [ordered]@{
        Submitted = 0L
        Retired = 0L
        UnmatchedDelta = 0L
    }
    foreach ($row in $kgslRows) {
        $metric = [string]$row.metric
        Require ($metric -cin @($kgsl.Keys)) `
            'An unapproved KGSL event label escaped the aggregate query.'
        $kgsl[$metric] = Convert-NullableInt64 $row.occurrences
    }
    $kgsl.UnmatchedDelta = [int64]$kgsl.Submitted - [int64]$kgsl.Retired

    $healthRows = @(Invoke-TraceQuery $processor $Trace $healthSql 'TRACE_HEALTH' $HostTemp)
    Require ($healthRows.Count -eq 1) 'Trace-health metrics were absent or ambiguous.'
    $healthRow = $healthRows[0]
    $health = [ordered]@{
        FtraceSetupErrors = Convert-NullableInt64 $healthRow.ftrace_setup_errors
        FtraceDroppedEvents = Convert-NullableInt64 $healthRow.ftrace_dropped_events
        FtraceOverruns = Convert-NullableInt64 $healthRow.ftrace_overruns
        PerfSamplesSkipped = Convert-NullableInt64 $healthRow.perf_samples_skipped
        DataLoss = Convert-NullableInt64 $healthRow.data_loss
        BufferOverruns = Convert-NullableInt64 $healthRow.buffer_overruns
    }
    $health.UsableForSchedulerConclusions =
        [int64]$health.FtraceSetupErrors -eq 0 -and
        [int64]$health.FtraceDroppedEvents -eq 0 -and
        [int64]$health.FtraceOverruns -eq 0 -and
        [int64]$health.DataLoss -eq 0 -and
        [int64]$health.BufferOverruns -eq 0

    [ordered]@{
        ActualDurationSeconds = $actualSeconds
        SchedRows = $schedRows
        AppCpuMs = Convert-NullableDouble $summary.app_cpu_ms
        AppOneCorePercent = Convert-NullableDouble $summary.app_one_core_percent
        AppRunnableWaitMs = Convert-NullableDouble $summary.runnable_wait_ms
        AppRunnableWaitOneCorePercent =
            Convert-NullableDouble $summary.runnable_wait_one_core_percent
        AppThreadCount = Convert-NullableInt64 $summary.app_thread_count
        ProcessCounterSamples = Convert-NullableInt64 $summary.process_counter_samples
        Threads = $threads
        CpuFrequencyDistribution = $frequencies
        CpuIdleDistribution = $idle
        ProcessCounters = $processCounters
        GpuMemory = [ordered]@{
            Samples = Convert-NullableInt64 $gpu.samples
            MeanMiB = Convert-NullableDouble $gpu.mean_mib
            P95MiB = Convert-NullableDouble $gpu.p95_mib
            MaxMiB = Convert-NullableDouble $gpu.max_mib
        }
        KgslEvents = $kgsl
        TraceHealth = $health
    }
}

function New-ArtifactDirectory {
    [IO.Directory]::CreateDirectory($script:ArtifactRoot) | Out-Null
    $leaf = 'capture-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $script:ArtifactRoot $leaf
    Require (-not (Test-Path -LiteralPath $path)) 'The aggregate output path exists.'
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Write-JsonAtomic(
    [Parameter(Mandatory)] $Value,
    [Parameter(Mandatory)][string] $Path
) {
    Require (-not (Test-Path -LiteralPath $Path)) 'Refusing to overwrite a report.'
    $temp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
                ($Value | ConvertTo-Json -Depth 10))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        Move-Item -LiteralPath $temp -Destination $Path
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Invoke-SelfTest {
    $events = @($script:MandatoryFtraceEvents + @(
        'gpu_mem/gpu_mem_total',
        'kgsl/adreno_cmdbatch_submitted',
        'kgsl/adreno_cmdbatch_retired'
    ))
    $config = New-TraceConfig $events 30
    foreach ($event in $events) {
        Require $config.Contains('ftrace_events: "' + $event + '"',
            [StringComparison]::Ordinal) "SelfTest config omitted $event."
    }
    foreach ($event in $script:ExcludedVendorGpuFtraceEvents) {
        Require (-not $config.Contains('ftrace_events: "' + $event + '"',
                [StringComparison]::Ordinal)) `
            "SelfTest enabled excluded vendor event $event."
    }
    Require (Test-Throws {
        New-TraceConfig ([string[]]@($events +
            $script:ExcludedVendorGpuFtraceEvents[0])) 30 | Out-Null
    }) 'SelfTest allowed an excluded vendor event into the capture config.'
    foreach ($forbidden in @(
        'linux.perf', 'atrace_', 'android.log', 'android.packages_list',
        'binder', 'raw_syscalls', 'heapprofd', 'sys_enter', 'sys_exit'
    )) {
        Require (-not $config.Contains($forbidden,
                [StringComparison]::OrdinalIgnoreCase)) `
            "SelfTest found forbidden config token $forbidden."
    }
    Require ($config.Contains('duration_ms: 30000', [StringComparison]::Ordinal)) `
        'SelfTest generated the wrong duration.'
    $null = Assert-SafeDevicePath `
        '/data/local/tmp/qc-rc8-perfetto-0123456789abcdef0123456789abcdef.pbtxt'
    Require (Test-Throws {
        Assert-SafeDevicePath '/data/local/tmp/../bad.pftrace'
    }) 'Unsafe device path was accepted.'
    Require ((ConvertTo-ShLiteral 'id -u') -ceq "'id -u'" -and
            (ConvertTo-ShLiteral 'cat /sys/kernel/tracing/available_events') -ceq
                "'cat /sys/kernel/tracing/available_events'") `
        'The fixed Magisk command operands were not shell-quoted atomically.'
    $threadLabelFixtures = [ordered]@{
        'Render thread' = 'RenderThread'
        'Server thread' = 'ServerThread'
        'G1 Conc#0' = 'GarbageCollector'
        'Sodium Async Cu' = 'SodiumAsyncWorker'
        'Sodium Async Chunk Builder #2' = 'SodiumAsyncWorker'
        'UnityChoreograp' = 'UnityFramePacer'
        'UnityChoreographer' = 'UnityFramePacer'
        'UnityMain' = 'UnityRuntimeMain'
        'FMOD stream' = 'FmodStreamAudio'
        'FMOD stream thread' = 'FmodStreamAudio'
        'FMOD mixer' = 'FmodMixerAudio'
        'FMOD mixer thread' = 'FmodMixerAudio'
        'alsoft-mixer' = 'OpenAlMixerAudio'
        'Thread-13' = 'OtherAppThread'
        'private-user@example.com' = 'OtherAppThread'
    }
    foreach ($fixture in $threadLabelFixtures.GetEnumerator()) {
        Require ((Convert-AppThreadLabel ([string]$fixture.Key)) -ceq
                [string]$fixture.Value) `
            "Thread-label privacy mapping failed for a fixed fixture."
    }

    $labComponent = $script:ImmersiveComponent
    $stableComponent =
        "$($script:StablePackage)/$($script:LockedImmersiveActivity)"
    $liveMultiDisplayFocus = @(
        'Display #0 (activities from top to bottom):',
        '  topResumedActivity=ActivityRecord{10 u0 com.oculus.vrshell/.MainActivity t10}',
        '  ResumedActivity: ActivityRecord{10 u0 com.oculus.vrshell/.MainActivity t10}',
        'Display #2 (activities from top to bottom):',
        "  topResumedActivity=ActivityRecord{12 u0 $labComponent t12}",
        "  ResumedActivity: ActivityRecord{12 u0 $labComponent t12}",
        'Display #3 (activities from top to bottom):',
        '  topResumedActivity=ActivityRecord{13 u0 com.oculus.systemux/.ControlBarActivity t13}',
        '  ResumedActivity: ActivityRecord{13 u0 com.oculus.systemux/.ControlBarActivity t13}',
        'Display #4 (activities from top to bottom):',
        '  topResumedActivity=ActivityRecord{14 u0 com.oculus.toasts/.ToastActivity t14}',
        '  ResumedActivity: ActivityRecord{14 u0 com.oculus.toasts/.ToastActivity t14}',
        'Display #5 (activities from top to bottom):',
        '  topResumedActivity=ActivityRecord{15 u0 com.oculus.vrshell/.MainActivity t15}',
        'Display #7 (activities from top to bottom):',
        '  topResumedActivity=ActivityRecord{17 u0 com.oculus.systemux/.SystemUiActivity t17}',
        "Resumed: ActivityRecord{12 u0 $labComponent t12}",
        'ActivityTaskSupervisor state:',
        '  mCurrentFocus=null',
        '  mCurrentFocus = null',
        '  mCurrentFocus=null',
        '  mCurrentFocus=null',
        '  mCurrentFocus=null',
        "  mCurrentFocus=Window{12 u0 $labComponent}",
        '  mFocusedApp=null',
        '  mFocusedApp = null',
        '  mFocusedApp=null',
        '  mFocusedApp=null',
        '  mFocusedApp=null',
        "  mFocusedApp=ActivityRecord{12 u0 $labComponent t12}"
    )
    Require (Test-ExactLabFocusSnapshot $liveMultiDisplayFocus) `
        'SelfTest rejected the live-shaped multi-display Lab focus proof.'

    $wrongGlobal = @($liveMultiDisplayFocus | ForEach-Object {
        if ([string]$_ -cmatch '^\s*mCurrentFocus\s*=\s*Window\{') {
            '  mCurrentFocus=Window{90 u0 com.example.other/.MainActivity}'
        } else { [string]$_ }
    })
    $stableGlobal = @($liveMultiDisplayFocus | ForEach-Object {
        if ([string]$_ -cmatch '^\s*mFocusedApp\s*=\s*ActivityRecord\{') {
            "  mFocusedApp=ActivityRecord{91 u0 $stableComponent t91}"
        } else { [string]$_ }
    })
    $duplicateDisplay = @($liveMultiDisplayFocus | ForEach-Object {
        [string]$_
        if ([string]$_ -cmatch ('^\s*ResumedActivity\s*:\s*ActivityRecord\{' +
                '.*' + [regex]::Escape($labComponent))) {
            "  ResumedActivity: ActivityRecord{18 u0 $labComponent t18}"
        }
    })
    $ambiguousGlobal = @($liveMultiDisplayFocus +
        "  mCurrentFocus=Window{14 u0 $labComponent}")
    $malformedNonNull = @($liveMultiDisplayFocus | ForEach-Object {
        if ([string]$_ -cmatch '^\s*mCurrentFocus\s*=\s*Window\{') {
            "  mCurrentFocus=null Window{15 u0 $labComponent}"
        } else { [string]$_ }
    })
    $nullOnly = @($liveMultiDisplayFocus | ForEach-Object {
        if ([string]$_ -cmatch '^\s*mCurrentFocus\s*=\s*Window\{') {
            '  mCurrentFocus=null'
        } elseif ([string]$_ -cmatch
                '^\s*mFocusedApp\s*=\s*ActivityRecord\{') {
            '  mFocusedApp=null'
        } else { [string]$_ }
    })
    $launcherInsteadOfImmersive = @($liveMultiDisplayFocus | ForEach-Object {
        ([string]$_).Replace($labComponent,
            "$($script:Package)/.MainActivity", [StringComparison]::Ordinal)
    })
    foreach ($invalidFocus in @(
        [pscustomobject]@{ Name='wrong-global-package'; Lines=$wrongGlobal },
        [pscustomobject]@{ Name='stable-global-focus'; Lines=$stableGlobal },
        [pscustomobject]@{ Name='duplicate-lab-display'; Lines=$duplicateDisplay },
        [pscustomobject]@{ Name='ambiguous-global-focus'; Lines=$ambiguousGlobal },
        [pscustomobject]@{ Name='malformed-non-null'; Lines=$malformedNonNull },
        [pscustomobject]@{ Name='null-only'; Lines=$nullOnly },
        [pscustomobject]@{ Name='launcher-not-immersive'; Lines=$launcherInsteadOfImmersive }
    )) {
        Require (-not (Test-ExactLabFocusSnapshot `
                ([string[]]@($invalidFocus.Lines)))) `
            "SelfTest accepted invalid focus case: $($invalidFocus.Name)."
    }

    $fixtureSerial = 'QUEST_USB_FIXTURE'
    $fixtureParent = $script:QuestUsbParentPrefix + $fixtureSerial
    $fixtureChild = [pscustomobject][ordered]@{
        InstanceId = 'USB\VID_2833&PID_5013&MI_01\FIXTURE_CHILD'
        FriendlyName = 'Fixture Composite ADB Interface'
        Status = 'OK'
        Present = $true
        ParentInstanceId = $fixtureParent
    }
    $fixtureParentRecord = [pscustomobject][ordered]@{
        InstanceId = $fixtureParent
        Status = 'OK'
        Present = $true
    }
    Require (Test-ExplicitNonNetworkAdbSerial $fixtureSerial) `
        'SelfTest rejected a local USB-shaped serial.'
    foreach ($networkSerial in @(
        'auto', '192.0.2.10:5555', 'host.example:5555',
        'adb-QUEST._adb-tls-connect._tcp', 'quest.local', 'BAD:SERIAL')) {
        Require (-not (Test-ExplicitNonNetworkAdbSerial $networkSerial)) `
            'SelfTest accepted a network-shaped serial.'
    }
    Require (Assert-WindowsUsbPnpSnapshot -ExpectedSerial $fixtureSerial `
            -Children @($fixtureChild) -Parents @($fixtureParentRecord)) `
        'SelfTest rejected an exact Windows USB PnP chain.'
    foreach ($invalidSnapshot in @(
        [pscustomobject]@{
            Name = 'wrong-parent'
            Children = @([pscustomobject]@{
                InstanceId = $fixtureChild.InstanceId
                FriendlyName = $fixtureChild.FriendlyName
                Status = 'OK'; Present = $true
                ParentInstanceId = 'USB\VID_2833&PID_5013\OTHER_FIXTURE'
            })
            Parents = @($fixtureParentRecord)
        },
        [pscustomobject]@{
            Name = 'child-not-present'
            Children = @([pscustomobject]@{
                InstanceId = $fixtureChild.InstanceId
                FriendlyName = $fixtureChild.FriendlyName
                Status = 'OK'; Present = $false
                ParentInstanceId = $fixtureParent
            })
            Parents = @($fixtureParentRecord)
        },
        [pscustomobject]@{
            Name = 'parent-not-present'
            Children = @($fixtureChild)
            Parents = @([pscustomobject]@{
                InstanceId = $fixtureParent; Status = 'OK'; Present = $false
            })
        },
        [pscustomobject]@{
            Name = 'missing-adb-child'
            Children = @()
            Parents = @($fixtureParentRecord)
        },
        [pscustomobject]@{
            Name = 'wrong-vid-pid'
            Children = @($fixtureChild)
            Parents = @([pscustomobject]@{
                InstanceId = 'USB\VID_0000&PID_0000\QUEST_USB_FIXTURE'
                Status = 'OK'; Present = $true
            })
        }
    )) {
        Require (Test-Throws {
            Assert-WindowsUsbPnpSnapshot -ExpectedSerial $fixtureSerial `
                -Children ([object[]]@($invalidSnapshot.Children)) `
                -Parents ([object[]]@($invalidSnapshot.Parents)) | Out-Null
        }) "SelfTest accepted invalid Windows USB PnP case: $($invalidSnapshot.Name)."
    }
    $cleanupProbe = New-PrivateHostTemp
    try {
        [IO.File]::WriteAllBytes((Join-Path $cleanupProbe 'raw.pftrace'),
            [byte[]](1, 2, 3, 4))
        $failedClosed = Remove-PrivateHostTemp $cleanupProbe -DeleteOperation {
            param([string] $Target)
            throw "Synthetic deletion failure for $Target"
        }
        Require (-not $failedClosed -and (Test-Path -LiteralPath $cleanupProbe)) `
            'Host cleanup did not fail closed under a synthetic deletion failure.'
    } finally {
        Require (Remove-PrivateHostTemp $cleanupProbe) `
            'SelfTest could not purge its bounded Host cleanup probe.'
    }
    Require ($script:DeviceInvocations -eq 0) 'SelfTest invoked ADB.'
    [pscustomobject][ordered]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        Assertions = $script:Assertions
        ExactRc8Lock = $true
        WindowsUsbPnpCases = 'PASS'
        MultiDisplayFocusCases = 'PASS'
        HostCleanupFailureFailsClosed = $true
        RawTraceRetentionSupported = $false
        StableTouched = $false
    }
}

function Get-Plan {
    [pscustomobject][ordered]@{
        Result = 'PLAN_ONLY'
        HostOnly = $true
        DeviceInvocations = 0
        ExactRc8Only = $true
        ExplicitUsbTransportRequired = $true
        WindowsUnknownDevpathFallback =
            'Exact Android serial plus present/OK ADB-child-to-Quest-USB-parent PnP proof.'
        StableMustAlreadyBeStopped = $true
        DurationSeconds = $Seconds
        RequiredCapabilities = @(
            'AllowDeviceRead', 'AllowEphemeralDeviceIo', 'AllowRootRead')
        Trace = 'Scheduler wake/switch, CPU frequency/idle, process stats, gpu_mem, and proven KGSL submit/retire tracepoints.'
        ExcludedVendorTelemetry =
            'Discoverable KGSL buslevel/clk/gpubusy/pwrlevel are reported as available but excluded from capture by fixed policy.'
        Excluded = 'Callstacks, logcat, network, file I/O, Binder, atrace app categories, heapprofd, and package lists.'
        RawTracePolicy = 'Randomized Temp only; always deleted from device and Host.'
        Acceptance = 'Diagnostic only; a matched-refresh VrApi A/B remains required.'
    }
}

if ($Action -ceq 'SelfTest') {
    Invoke-SelfTest
    return
}
if ($Action -ceq 'Plan') {
    Get-Plan
    return
}

Require $AllowDeviceRead.IsPresent 'Capture requires explicit -AllowDeviceRead.'
Require $AllowEphemeralDeviceIo.IsPresent `
    'Capture requires explicit -AllowEphemeralDeviceIo.'
Require $AllowRootRead.IsPresent 'Capture requires explicit -AllowRootRead.'
Require ($Seconds -eq 30) 'The first exact-RC8 diagnostic is fixed to 30 seconds.'

$hostTemp = $null
$artifactDirectory = $null
$reportPath = $null
try {
    Resolve-Device
    Assert-StableStopped 'Before preflight:'
    $initialIdentity = Assert-ExactDeviceIdentity
    $labPid = Get-Pid -ExpectedPackage $script:Package
    $startTicks = Get-ProcessStartTicks $labPid
    Assert-RuntimeFence $labPid $startTicks 'Before event discovery:'
    $support = Get-SupportedFtraceEvents
    Assert-RuntimeFence $labPid $startTicks 'After event discovery:'
    $config = New-TraceConfig ([string[]]$support.Enabled) $Seconds

    $hostTemp = New-PrivateHostTemp
    $capture = Capture-RawTrace $config $hostTemp $labPid $startTicks
    Assert-RuntimeFence $labPid $startTicks 'Before analysis:'
    $analysis = Analyze-Trace $capture.HostTrace $labPid $hostTemp
    Assert-RuntimeFence $labPid $startTicks 'After analysis:'
    $finalIdentity = Assert-ExactDeviceIdentity
    Assert-RuntimeFence $labPid $startTicks 'Final fence:'

    $eventAvailability = [ordered]@{}
    $eventCaptureSelection = [ordered]@{}
    foreach ($event in $script:MandatoryFtraceEvents +
            $script:DiscoverableGpuFtraceEvents) {
        $key = ($event -replace '[^A-Za-z0-9]+', '_').Trim('_')
        $eventAvailability[$key] =
            [bool]($support.AvailableFixed -ccontains $event)
        $eventCaptureSelection[$key] = [bool]($support.Enabled -ccontains $event)
    }
    $report = [ordered]@{
        SchemaVersion = 3
        EvidenceClass = 'diagnostic-only-not-an-ab-performance-sample'
        Contract = [ordered]@{
            BuildLockNormalizedSha256 = $script:ExpectedBuildLockSha256
            VersionCode = $script:LockedVersionCode
            VersionName = $script:LockedVersionName
            ApkSha256 = $script:LockedApkSha256
            SignerSha256BoundByExactApk = $script:LockedSignerSha256
            CoreSha256 = $script:LockedCoreSha256
            CompanionSha256 = $script:LockedVeqSha256
        }
        Identity = [ordered]@{
            ExactRc8Lock = $true
            UsbTransportProven = $true
            UsbTransportProofMethod = $script:UsbTransportProofMethod
            VersionMatchedBeforeAndAfter =
                $initialIdentity.VersionMatched -and $finalIdentity.VersionMatched
            ApkMatchedBeforeAndAfter =
                $initialIdentity.ApkMatched -and $finalIdentity.ApkMatched
            CoreMatchedBeforeAndAfter =
                $initialIdentity.CoreMatched -and $finalIdentity.CoreMatched
            CompanionMatchedBeforeAndAfter =
                $initialIdentity.CompanionMatched -and $finalIdentity.CompanionMatched
            SignerBoundByExactApk = $true
            CapturedPid = $labPid
            ProcessStartTicks = $startTicks
            ProcessIncarnationStable = $true
            FocusedBeforeDuringAndAfter = $true
            StableStoppedBeforeDuringAndAfter = $true
        }
        Coverage = [ordered]@{
            RequestedDurationSeconds = $Seconds
            ActualDurationSeconds = $analysis.ActualDurationSeconds
            RuntimeFencePollsDuringCapture = $capture.PollCount
            SchedRows = $analysis.SchedRows
            AppThreadCount = $analysis.AppThreadCount
            ProcessCounterSamples = $analysis.ProcessCounterSamples
        }
        AppScheduling = [ordered]@{
            CpuMs = $analysis.AppCpuMs
            OneCorePercent = $analysis.AppOneCorePercent
            RunnableWaitMs = $analysis.AppRunnableWaitMs
            RunnableWaitOneCorePercent = $analysis.AppRunnableWaitOneCorePercent
            Threads = $analysis.Threads
        }
        CpuFrequencyDistribution = $analysis.CpuFrequencyDistribution
        CpuIdleDistribution = $analysis.CpuIdleDistribution
        ProcessCounters = $analysis.ProcessCounters
        GpuMemory = $analysis.GpuMemory
        KgslEvents = $analysis.KgslEvents
        EventAvailability = $eventAvailability
        EventCaptureSelection = $eventCaptureSelection
        EventSelectionPolicy = [ordered]@{
            Profile = 'scheduler-core-with-proven-gpu-lifecycle'
            ExcludedVendorTransitionEvents = @(
                $script:ExcludedVendorGpuFtraceEvents)
            Reason = 'Two captures correlated four setup failures with zero events from these four optional tracepoints; correlation is not proof of per-event failure or permanent kernel non-support.'
        }
        MeasurementScopes = [ordered]@{
            AppScheduling = 'exact-captured-pid'
            ProcessCounters = 'exact-captured-pid'
            GpuMemory = 'exact-captured-pid'
            CpuFrequency = 'device-global-no-process-identity'
            CpuIdle = 'device-global-no-process-identity'
            KgslEvents = 'device-global-no-process-identity'
        }
        TraceHealth = $analysis.TraceHealth
        Privacy = [ordered]@{
            RawTraceRetained = $false
            RawLogcatCaptured = $false
            CallstacksCaptured = $false
            NetworkCaptured = $false
            FileIoCaptured = $false
            BinderPayloadCaptured = $false
            AtraceAppCategoriesCaptured = $false
            HeapProfileCaptured = $false
            ExternalProcessNamesOrPidsPersisted = $false
            AccountWorldOrServerDataRead = $false
            ApplicationOrProfileMutationPerformed = $false
            EphemeralDeviceFilesDeleted = $true
            HostRawTempPurgedBeforePublish = $true
        }
        Interpretation = @(
            'This trace identifies scheduler and fixed GPU-memory/KGSL candidates only.',
            'Thread categories are privacy-normalized; unknown app thread names are not persisted.',
            'Summed runnable wait is expressed in one-core equivalents and may exceed 100% across threads.',
            'Tracing overhead makes this result ineligible for FPS or release acceptance.',
            'Only a fresh counterbalanced matched-refresh VrApi A/B may accept a performance change.'
            'Tracefs availability proves only that an event name was listed; it does not prove that Perfetto can enable it or that it will emit in a fixed window.'
            'An empty CPU-frequency distribution can mean no frequency transition occurred during capture and is not evidence that the tracepoint is unsupported.'
        )
    }
    Require (Remove-PrivateHostTemp $hostTemp) `
        'Host raw-trace cleanup failed; no aggregate report was accepted.'
    Require (-not (Test-Path -LiteralPath $hostTemp)) `
        'Host raw-trace cleanup could not be proven; no aggregate report was accepted.'
    $hostTemp = $null
    $artifactDirectory = New-ArtifactDirectory
    $reportPath = Join-Path $artifactDirectory 'aggregate.json'
    Write-JsonAtomic $report $reportPath
    [pscustomobject][ordered]@{
        Result = 'CAPTURED_ANALYZED_AND_PURGED'
        AggregateReport = $reportPath
        ExactRc8 = $true
        TraceHealthy = [bool]$analysis.TraceHealth.UsableForSchedulerConclusions
        RawTraceRetained = $false
        StableTouched = $false
        ApplicationOrProfileMutationPerformed = $false
    }
} finally {
    if ($null -ne $hostTemp -and (Test-Path -LiteralPath $hostTemp)) {
        Require (Remove-PrivateHostTemp $hostTemp) `
            'Host raw-trace cleanup failed; no aggregate report was accepted.'
    }
}
