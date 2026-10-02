[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$production = Join-Path $PSScriptRoot 'quest-v71-rc8-input-canary.ps1'
. $production -Action SelfTest | Out-Null

$script:FakeShell = [Collections.Generic.Queue[object]]::new()
$script:FakeAdb = [Collections.Generic.Queue[object]]::new()
$script:FakeAdbCalls = 0
$script:FakePnpApiCalls = 0
$script:FakePnpSerial = ''
function Invoke-DeviceShell {
    param([string] $Command, [switch] $AllowFailure)
    $script:FakeAdbCalls++
    if ($script:FakeShell.Count -eq 0) { throw 'Unexpected fake device-shell call.' }
    return $script:FakeShell.Dequeue()
}

function Add-FakeShell([int] $ExitCode, [string[]] $Lines) {
    $script:FakeShell.Enqueue([pscustomobject]@{ ExitCode=$ExitCode; Lines=@($Lines) })
}

function Add-FakeAdb([string[]] $ExpectedArguments, [string[]] $Lines) {
    $script:FakeAdb.Enqueue([pscustomobject]@{
        ExpectedArguments = @($ExpectedArguments)
        Result = [pscustomobject]@{ ExitCode=0; Lines=@($Lines) }
    })
}

function Expect-Failure([scriptblock] $Body, [string] $Message) {
    $failed = $false
    try { & $Body | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw $Message }
}

$passed = 0

Add-FakeShell 0 @("APK`t71`t6.0.1-26.2-vivecraft-personal.12-rc.8`t$script:ExpectedLabApkSha256")
$identity = Get-ExactLabIdentity
if ($identity.VersionCode -cne '71' -or $identity.ApkSha256 -cne $script:ExpectedLabApkSha256) {
    throw 'Exact APK identity fixture was rejected.'
}
$passed++

Add-FakeShell 0 @("APK`t72`t6.0.1-26.2-vivecraft-personal.12-rc.8`t$script:ExpectedLabApkSha256")
Expect-Failure { Get-ExactLabIdentity } 'Wrong versionCode was accepted.'
$passed++

Add-FakeShell 0 @("APK`t71`t6.0.1-26.2-vivecraft-personal.12-rc.8`t$('0' * 64)")
Expect-Failure { Get-ExactLabIdentity } 'Wrong APK hash was accepted.'
$passed++

Add-FakeShell 0 @('1234')
Expect-Failure { Assert-StableStopped } 'Running Personal Stable was accepted.'
Add-FakeShell 1 @()
Assert-StableStopped
$passed += 2

$preflight = [pscustomobject]@{
    VeqSha256=$script:ExpectedVeqSha256
    VeqSize=$script:ExpectedVeqSize
}
Assert-ExactPair $preflight
$preflight.VeqSize++
Expect-Failure { Assert-ExactPair $preflight } 'Wrong VEQ size was accepted.'
$preflight.VeqSize=$script:ExpectedVeqSize
$preflight.VeqSha256=('f' * 64)
Expect-Failure { Assert-ExactPair $preflight } 'Wrong VEQ hash was accepted.'
$passed += 3

$script:Serial = 'auto'
Expect-Failure { Resolve-Device } 'Auto device selection was accepted.'
$script:Serial = '192.0.2.5:5555'
Expect-Failure { Resolve-Device } 'Network ADB endpoint was accepted.'
$passed += 2

$fixtureSerial = 'QUEST_USB_FIXTURE'
$fixtureParent = $script:QuestUsbParentPrefix + $fixtureSerial
$fixtureChild = [pscustomobject][ordered]@{
    InstanceId='USB\VID_2833&PID_5013&MI_01\FIXTURE_CHILD'
    FriendlyName='Fixture Composite ADB Interface'
    Status='OK'; Present=$true; ParentInstanceId=$fixtureParent
}

# These functions shadow the Windows PnpDevice module in this Host-only test
# process. They expose generic records only and never inspect the live Host.
function Get-PnpDevice {
    [CmdletBinding()]
    param([switch] $PresentOnly, [string] $InstanceId)
    $script:FakePnpApiCalls++
    if (-not $PresentOnly.IsPresent -or
            [string]::IsNullOrWhiteSpace($script:FakePnpSerial)) {
        throw 'Fake PnP fixture was invoked outside its exact contract.'
    }
    $parent = 'USB\VID_2833&PID_5013\' + $script:FakePnpSerial
    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        return [pscustomobject]@{
            InstanceId=$parent; FriendlyName='Fixture USB Composite Device'
            Status='OK'; Present=$true
        }
    }
    return [pscustomobject]@{
        InstanceId='USB\VID_2833&PID_5013&MI_03\FIXTURE_ADB_CHILD'
        FriendlyName='Fixture Composite ADB Interface'
        Status='OK'; Present=$true
    }
}

function Get-PnpDeviceProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $InstanceId,
        [Parameter(Mandatory)][string] $KeyName
    )
    $script:FakePnpApiCalls++
    if ($KeyName -cne 'DEVPKEY_Device_Parent' -or
            $InstanceId -cne 'USB\VID_2833&PID_5013&MI_03\FIXTURE_ADB_CHILD') {
        throw 'Fake PnP property fixture received an unexpected query.'
    }
    [pscustomobject]@{
        KeyName=$KeyName
        Data=('USB\VID_2833&PID_5013\' + $script:FakePnpSerial)
    }
}
$fixtureParentRecord = [pscustomobject][ordered]@{
    InstanceId=$fixtureParent; Status='OK'; Present=$true
}
if (-not (Assert-WindowsUsbPnpSnapshot -ExpectedSerial $fixtureSerial `
        -Children @($fixtureChild) -Parents @($fixtureParentRecord))) {
    throw 'Exact input-helper Windows PnP fixture was rejected.'
}
$passed++
foreach ($invalidSnapshot in @(
    [pscustomobject]@{
        Name='wrong-parent'
        Children=@([pscustomobject]@{
            InstanceId=$fixtureChild.InstanceId; FriendlyName=$fixtureChild.FriendlyName
            Status='OK'; Present=$true
            ParentInstanceId='USB\VID_2833&PID_5013\OTHER_FIXTURE'
        })
        Parents=@($fixtureParentRecord)
    },
    [pscustomobject]@{
        Name='child-not-present'
        Children=@([pscustomobject]@{
            InstanceId=$fixtureChild.InstanceId; FriendlyName=$fixtureChild.FriendlyName
            Status='OK'; Present=$false; ParentInstanceId=$fixtureParent
        })
        Parents=@($fixtureParentRecord)
    },
    [pscustomobject]@{
        Name='parent-not-present'; Children=@($fixtureChild)
        Parents=@([pscustomobject]@{ InstanceId=$fixtureParent; Status='OK'; Present=$false })
    },
    [pscustomobject]@{
        Name='missing-child'; Children=@(); Parents=@($fixtureParentRecord)
    },
    [pscustomobject]@{
        Name='duplicate-parent'; Children=@($fixtureChild)
        Parents=@($fixtureParentRecord, $fixtureParentRecord)
    },
    [pscustomobject]@{
        Name='duplicate-child'; Children=@($fixtureChild, $fixtureChild)
        Parents=@($fixtureParentRecord)
    },
    [pscustomobject]@{
        Name='parent-error'; Children=@($fixtureChild)
        Parents=@([pscustomobject]@{
            InstanceId=$fixtureParent; Status='Error'; Present=$true
        })
    },
    [pscustomobject]@{
        Name='child-error'
        Children=@([pscustomobject]@{
            InstanceId=$fixtureChild.InstanceId; FriendlyName=$fixtureChild.FriendlyName
            Status='Error'; Present=$true; ParentInstanceId=$fixtureParent
        })
        Parents=@($fixtureParentRecord)
    },
    [pscustomobject]@{
        Name='wrong-vid-pid'; Children=@($fixtureChild)
        Parents=@([pscustomobject]@{
            InstanceId='USB\VID_0000&PID_0000\QUEST_USB_FIXTURE'
            Status='OK'; Present=$true
        })
    }
)) {
    Expect-Failure {
        Assert-WindowsUsbPnpSnapshot -ExpectedSerial $fixtureSerial `
            -Children ([object[]]@($invalidSnapshot.Children)) `
            -Parents ([object[]]@($invalidSnapshot.Parents)) | Out-Null
    } "Input helper accepted invalid PnP fixture: $($invalidSnapshot.Name)."
    $passed++
}

$script:Serial = 'USB123'
function Resolve-Adb { 'C:\fake\adb.exe' }
function Invoke-Adb {
    param([string[]] $Arguments, [switch] $AllowFailure)
    $script:FakeAdbCalls++
    if ($script:FakeAdb.Count -eq 0) { throw 'Unexpected fake ADB call.' }
    $next = $script:FakeAdb.Dequeue()
    if (($Arguments -join "`u{1f}") -cne
            (@($next.ExpectedArguments) -join "`u{1f}")) {
        throw "Unexpected fake ADB arguments: $($Arguments -join ' ')."
    }
    return $next.Result
}
$script:FakePnpSerial = 'USB123'
Add-FakeAdb @('devices','-l') @(
    'List of devices attached',
    'USB123 device product:hollywood model:Quest_3 device:hollywood')
Add-FakeAdb @('-s','USB123','get-devpath') @('unknown')
Add-FakeAdb @('-s','USB123','shell','getprop','ro.serialno') @('USB123')
Resolve-Device
if ($script:ResolvedSerial -cne 'USB123' -or
        $script:UsbTransportProofMethod -cne 'windows-pnp-parent' -or
        $script:FakePnpApiCalls -ne 3) {
    throw 'Exact Windows PnP fallback was not retained.'
}
$passed++

Add-FakeAdb @('devices','-l') @(
    'List of devices attached',
    'USB123 device product:hollywood model:Quest_3 device:hollywood')
Add-FakeAdb @('-s','USB123','get-devpath') @('usb:1-2')
Resolve-Device
if ($script:UsbTransportProofMethod -cne 'adb-devpath' -or
        $script:FakePnpApiCalls -ne 3) {
    throw 'Direct ADB USB proof did not remain the primary path.'
}
$passed++

Add-FakeAdb @('devices','-l') @(
    'List of devices attached',
    'USB123 device product:hollywood model:Quest_3 device:hollywood')
Add-FakeAdb @('-s','USB123','get-devpath') @('unknown')
Add-FakeAdb @('-s','USB123','shell','getprop','ro.serialno') @('OTHER123')
Expect-Failure { Resolve-Device } 'Mismatched Android hardware serial was accepted.'
$passed++

Add-FakeAdb @('devices','-l') @(
    'List of devices attached',
    'USB123 device product:hollywood model:Quest_3 device:hollywood',
    'USB123 device product:hollywood model:Quest_3 device:hollywood')
Expect-Failure { Resolve-Device } 'Duplicate exact authorized ADB rows were accepted.'
$passed++

$candidate = Get-ExactCandidateContract
if ($candidate.Sha256 -cne $script:ExpectedCandidateSha256 -or
        $candidate.FabricVersion -cne $script:ExpectedCandidateVersion) {
    throw 'Exact candidate fixture was rejected.'
}
$passed++

$runtimeVerifier = Join-Path $PSScriptRoot 'verify-v71-rc8-input-runtime-log.ps1'
$tempLog = Join-Path ([IO.Path]::GetTempPath()) ('rc8-input-runtime-' + [guid]::NewGuid().ToString('N') + '.log')
$validLog = @'
[00:00:00] [main/INFO]: Loading Minecraft 26.2 with Fabric Loader 0.19.4
[00:00:00] [main/INFO]: - vivecraft 26.2-1.3.15+qc.v71.rc8-input.1
[00:00:00] [main/INFO]: - vivecraft_essentials_quest 0.7.0-v71.rc6
[00:00:01] [Render thread/INFO]: Using graphics backend Vulkan, preferredGraphicsBackend:vulkan
[00:00:02] [Render thread/INFO]: Vivecraft: OpenXR initialized & VR connected.
[00:00:03] [Render thread/INFO]: Vivecraft: OpenXR submitted frame 120 projectionLayer=true
'@
try {
    [IO.File]::WriteAllText($tempLog, $validLog, [Text.UTF8Encoding]::new($false))
    $verified = @(& $runtimeVerifier -LogPath $tempLog)
    if ($verified.Count -ne 1 -or $verified[0].Result -cne 'PASS') {
        throw 'Exact input-canary runtime fixture was rejected.'
    }
    [IO.File]::WriteAllText($tempLog,
            $validLog.Replace('rc8-input.1','rc8-mining'), [Text.UTF8Encoding]::new($false))
    Expect-Failure { & $runtimeVerifier -LogPath $tempLog } 'Baseline runtime was accepted as input canary.'
    [IO.File]::WriteAllText($tempLog,
            $validLog + "`nException in thread `"Render thread`"", [Text.UTF8Encoding]::new($false))
    Expect-Failure { & $runtimeVerifier -LogPath $tempLog } 'Fatal runtime fixture was accepted.'
} finally {
    Remove-Item -LiteralPath $tempLog -Force -ErrorAction SilentlyContinue
}
$passed += 3

$source = Get-Content -Raw -LiteralPath $production
foreach ($required in @(
    "HarnessId = 'questcraft-vivecraft-core-canary-v9'",
    "Package = 'com.qcxr.qcxr.canary262'",
    "BaselineLockPackage = 'com.qcxr.qcxr.dev262'",
    "ExpectedLabVersionCode = '71'",
    "ExpectedLabVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'",
    "ExpectedCandidateVersion = '26.2-1.3.15+qc.v71.rc8-input.1'",
    "Assert-StableStopped",
    "@('devices', '-l')",
    "'get-devpath'",
    "'getprop', 'ro.serialno'",
    "'DEVPKEY_Device_Parent'",
    "'USB\VID_2833&PID_5013\'",
    "Assert-WindowsUsbPnpTransport",
    "pidof `$qStablePackage",
    "`${qStablePackage}:*) exit 76",
    "RC8 input A/B fixes OpenXR copy-batch mode at OFF"
)) {
    if (-not $source.Contains($required)) { throw "Missing fixed source guard: $required" }
}
foreach ($forbidden in @(' install -r ', ' uninstall ', ' pm clear ', ' clear data ')) {
    if ($source.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Production helper contains forbidden mutation token: $forbidden"
    }
}
$passed++

if ($script:FakeShell.Count -ne 0) { throw 'Unused fake device-shell responses remain.' }
if ($script:FakeAdb.Count -ne 0) { throw 'Unused fake ADB responses remain.' }

# Load the bounded runtime-capture wrapper as a library and prove that its
# separately implemented USB gate accepts and rejects the same fake PnP chain.
$captureWrapper = Join-Path $PSScriptRoot 'capture-verify-v71-rc8-input-runtime-log.ps1'
. $captureWrapper
$captureFixtureSerial = 'CAPTURE_USB_FIXTURE'
$captureFixtureParent = $script:QuestUsbParentPrefix + $captureFixtureSerial
$captureFixtureChild = [pscustomobject][ordered]@{
    InstanceId='USB\VID_2833&PID_5013&MI_03\CAPTURE_CHILD'
    FriendlyName='Fixture Composite ADB Interface'
    Status='OK'; Present=$true; ParentInstanceId=$captureFixtureParent
}
$captureFixtureParentRecord = [pscustomobject][ordered]@{
    InstanceId=$captureFixtureParent; Status='OK'; Present=$true
}
Require (Assert-WindowsUsbPnpSnapshot -ExpectedSerial $captureFixtureSerial `
        -Children @($captureFixtureChild) -Parents @($captureFixtureParentRecord)) `
    'Exact capture-wrapper Windows PnP fixture was rejected.'
$passed++
foreach ($invalidSnapshot in @(
    [pscustomobject]@{
        Name='wrong-parent'
        Children=@([pscustomobject]@{
            InstanceId=$captureFixtureChild.InstanceId
            FriendlyName=$captureFixtureChild.FriendlyName
            Status='OK'; Present=$true
            ParentInstanceId='USB\VID_2833&PID_5013\OTHER_CAPTURE'
        })
        Parents=@($captureFixtureParentRecord)
    },
    [pscustomobject]@{
        Name='child-not-present'
        Children=@([pscustomobject]@{
            InstanceId=$captureFixtureChild.InstanceId
            FriendlyName=$captureFixtureChild.FriendlyName
            Status='OK'; Present=$false; ParentInstanceId=$captureFixtureParent
        })
        Parents=@($captureFixtureParentRecord)
    },
    [pscustomobject]@{
        Name='parent-not-present'; Children=@($captureFixtureChild)
        Parents=@([pscustomobject]@{
            InstanceId=$captureFixtureParent; Status='OK'; Present=$false
        })
    },
    [pscustomobject]@{
        Name='missing-child'; Children=@(); Parents=@($captureFixtureParentRecord)
    },
    [pscustomobject]@{
        Name='duplicate-parent'; Children=@($captureFixtureChild)
        Parents=@($captureFixtureParentRecord, $captureFixtureParentRecord)
    },
    [pscustomobject]@{
        Name='duplicate-child'; Children=@($captureFixtureChild, $captureFixtureChild)
        Parents=@($captureFixtureParentRecord)
    },
    [pscustomobject]@{
        Name='parent-error'; Children=@($captureFixtureChild)
        Parents=@([pscustomobject]@{
            InstanceId=$captureFixtureParent; Status='Error'; Present=$true
        })
    },
    [pscustomobject]@{
        Name='child-error'
        Children=@([pscustomobject]@{
            InstanceId=$captureFixtureChild.InstanceId
            FriendlyName=$captureFixtureChild.FriendlyName
            Status='Error'; Present=$true; ParentInstanceId=$captureFixtureParent
        })
        Parents=@($captureFixtureParentRecord)
    },
    [pscustomobject]@{
        Name='wrong-vid-pid'; Children=@($captureFixtureChild)
        Parents=@([pscustomobject]@{
            InstanceId='USB\VID_0000&PID_0000\CAPTURE_USB_FIXTURE'
            Status='OK'; Present=$true
        })
    }
)) {
    Expect-Failure {
        Assert-WindowsUsbPnpSnapshot -ExpectedSerial $captureFixtureSerial `
            -Children ([object[]]@($invalidSnapshot.Children)) `
            -Parents ([object[]]@($invalidSnapshot.Parents)) | Out-Null
    } "Capture wrapper accepted invalid PnP fixture: $($invalidSnapshot.Name)."
    $passed++
}

$script:CaptureFakeAdb = [Collections.Generic.Queue[object]]::new()
function Add-CaptureFakeAdb([string[]] $ExpectedArguments, [string] $Stdout) {
    $script:CaptureFakeAdb.Enqueue([pscustomobject]@{
        ExpectedArguments=@($ExpectedArguments); Stdout=$Stdout
    })
}
function Resolve-Adb { 'C:\fake\capture-adb.exe' }
function Invoke-Adb([string[]] $Arguments) {
    $script:FakeAdbCalls++
    if ($script:CaptureFakeAdb.Count -eq 0) { throw 'Unexpected capture fake ADB call.' }
    $next = $script:CaptureFakeAdb.Dequeue()
    if (($Arguments -join "`u{1f}") -cne
            (@($next.ExpectedArguments) -join "`u{1f}")) {
        throw "Unexpected capture fake ADB arguments: $($Arguments -join ' ')."
    }
    return [string]$next.Stdout
}
$script:Serial = 'CAPTUREUSB'
$script:FakePnpSerial = 'CAPTUREUSB'
Add-CaptureFakeAdb @('devices','-l') "List of devices attached`nCAPTUREUSB device product:hollywood model:Quest_3"
Add-CaptureFakeAdb @('-s','CAPTUREUSB','get-devpath') 'unknown'
Add-CaptureFakeAdb @('-s','CAPTUREUSB','shell','getprop','ro.serialno') 'CAPTUREUSB'
Add-CaptureFakeAdb @('-s','CAPTUREUSB','get-state') 'device'
Resolve-ExactDevice
if ($script:Device -cne 'CAPTUREUSB' -or
        $script:UsbTransportProofMethod -cne 'windows-pnp-parent' -or
        $script:FakePnpApiCalls -ne 6) {
    throw 'Capture wrapper did not retain the exact Windows PnP fallback.'
}
$passed++

Add-CaptureFakeAdb @('devices','-l') "List of devices attached`nCAPTUREUSB device product:hollywood model:Quest_3"
Add-CaptureFakeAdb @('-s','CAPTUREUSB','get-devpath') 'usb:1-2'
Add-CaptureFakeAdb @('-s','CAPTUREUSB','get-state') 'device'
Resolve-ExactDevice
if ($script:UsbTransportProofMethod -cne 'adb-devpath' -or
        $script:FakePnpApiCalls -ne 6) {
    throw 'Capture wrapper did not retain direct ADB USB proof as primary.'
}
$passed++

Add-CaptureFakeAdb @('devices','-l') "List of devices attached`nCAPTUREUSB device product:hollywood model:Quest_3"
Add-CaptureFakeAdb @('-s','CAPTUREUSB','get-devpath') 'unknown'
Add-CaptureFakeAdb @('-s','CAPTUREUSB','shell','getprop','ro.serialno') 'OTHERUSB'
Expect-Failure { Resolve-ExactDevice } 'Capture accepted a mismatched Android hardware serial.'
$passed++

Add-CaptureFakeAdb @('devices','-l') `
    "List of devices attached`nCAPTUREUSB device model:Quest_3`nCAPTUREUSB device model:Quest_3"
Expect-Failure { Resolve-ExactDevice } 'Capture accepted duplicate exact authorized ADB rows.'
$passed++
if ($script:CaptureFakeAdb.Count -ne 0) { throw 'Unused capture fake ADB responses remain.' }

[pscustomobject]@{
    Result='PASS'
    CasesPassed=$passed
    FakeDeviceCalls=$script:FakeAdbCalls
    RealAdbInvocations=0
    FakePnpApiCalls=$script:FakePnpApiCalls
    DeviceTouched=$false
    ExactUsbRequired=$true
    WindowsUsbPnpFixtureCases=20
    TransportResolutionCases=8
    StableMutationAllowed=$false
}
