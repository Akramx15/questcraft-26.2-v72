#requires -Version 7.0
<#
.SYNOPSIS
Captures and verifies the exact current RC8 Lab latest.log without retention.

.DESCRIPTION
Default mode is Host-only and never resolves ADB. With -Capture, this wrapper
pins the Lab package and exact 26.2 latest.log, binds the file to the current
process incarnation using /proc start ticks and stat metadata, pulls only that
one file into a unique Temp directory, invokes the reviewed RC8 verifier, then
deletes the raw log in a finally block. It has no Stable, write, launch, root,
profile, account-file, logcat, or network-discovery path.
#>
[CmdletBinding()]
param(
    [switch] $Capture,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Package = 'com.qcxr.qcxr.canary262'
$script:ForbiddenStablePackage = 'com.qcxr.qcxr.dev262'
$script:RemoteLog = '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/logs/latest.log'
$script:Verifier = Join-Path $PSScriptRoot 'verify-v71-rc8-runtime-log.ps1'
$script:ExpectedVerifierSha256 = '4C496A7022FAFF85B25D72727154DF88D9E2217D37F93EF73AD36BB4CED56CEC'
$script:MaxLogBytes = 64MB
$script:MaxLogAgeSeconds = 600
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocationCount = 0

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC8_RUNTIME_CAPTURE] $Message" }
}

function Invoke-ProcessCapture([string] $FileName, [string[]] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        Require $process.Start() "Could not start process: $FileName"
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode=$process.ExitCode; Stdout=$stdout.GetAwaiter().GetResult(); Stderr=$stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) { return (Resolve-Path -LiteralPath $AdbPath).Path }
    $command = Get-Command $AdbPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    throw '[V71_RC8_RUNTIME_CAPTURE] ADB was not found; pass its absolute path.'
}

function Invoke-Adb([string[]] $Arguments) {
    $script:DeviceInvocationCount++
    $result = Invoke-ProcessCapture $script:Adb $Arguments
    Require ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($result.Stderr)) `
        'A read-only ADB probe failed; raw output was suppressed.'
    $result.Stdout
}

function Resolve-ExactDevice {
    $script:Adb = Resolve-Adb
    $deviceText = Invoke-Adb @('devices')
    $rows = @($deviceText -split "`r?`n")
    Require ($rows.Count -ge 1 -and $rows[0].Trim() -ceq 'List of devices attached') 'ADB device list was malformed.'
    $records = @($rows | Select-Object -Skip 1 | ForEach-Object {
        if ($_ -match '^(?<serial>\S+)\s+(?<state>\S+)(?:\s+.*)?$') {
            [pscustomobject]@{Serial=$Matches.serial;State=$Matches.state}
        }
    })
    if ($Serial -ceq 'auto') {
        Require ($records.Count -eq 1) 'Auto mode requires exactly one endpoint.'
        $selected = $records[0]
    } else {
        $matches = @($records | Where-Object {$_.Serial -ceq $Serial})
        Require ($matches.Count -eq 1) 'Requested endpoint was not present exactly once.'
        $selected = $matches[0]
    }
    Require ([string]$selected.State -ceq 'device') 'Selected endpoint is not authorized and ready.'
    $script:Device = [string]$selected.Serial
    Require ((Invoke-Adb @('-s',$script:Device,'get-state')).Trim() -ceq 'device') 'Selected endpoint state drifted.'
}

function Get-ExactPid {
    $script:DeviceInvocationCount++
    $result = Invoke-ProcessCapture $script:Adb @('-s',$script:Device,'shell','pidof',$script:Package)
    Require ([string]::IsNullOrWhiteSpace($result.Stderr)) 'Lab PID probe emitted stderr.'
    $pids = @($result.Stdout -split '\s+' | Where-Object { $_ })
    Require ($result.ExitCode -eq 0 -and $pids.Count -eq 1 -and
        $pids[0] -cmatch '^[1-9][0-9]*$') 'Lab must have exactly one running PID.'
    [int]$pids[0]
}

function Read-StartTicks([string] $StatLine) {
    $row = $StatLine.Trim()
    $end = $row.LastIndexOf(') ',[StringComparison]::Ordinal)
    Require ($end -gt 0) '/proc process stat was malformed.'
    $suffix = @($row.Substring($end+2) -split '\s+')
    Require ($suffix.Count -ge 20 -and $suffix[19] -cmatch '^[0-9]+$') '/proc process starttime was malformed.'
    [uint64]$suffix[19]
}

function Get-ProcessAnchor([int] $ProcessId) {
    $ticks = [int64](Invoke-Adb @('-s',$script:Device,'shell','getconf','CLK_TCK')).Trim()
    $uptimeText = ((Invoke-Adb @('-s',$script:Device,'shell','cat','/proc/uptime')).Trim() -split '\s+')[0]
    [double]$uptime = 0
    Require ([double]::TryParse($uptimeText,[Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,[ref]$uptime)) 'Device uptime was malformed.'
    $epoch = [int64](Invoke-Adb @('-s',$script:Device,'shell','date','+%s')).Trim()
    $startTicks = Read-StartTicks (Invoke-Adb @('-s',$script:Device,'shell','cat',"/proc/$ProcessId/stat"))
    Require ($ticks -gt 0 -and $uptime -gt 0 -and $epoch -gt 0) 'Process anchor values were invalid.'
    $startEpoch = [double]$epoch - $uptime + ([double]$startTicks/[double]$ticks)
    Require ($startEpoch -gt 0 -and $startEpoch -le ($epoch+2)) 'Process start epoch was impossible.'
    [pscustomobject]@{ProcessId=$ProcessId;StartTicks=$startTicks;StartEpoch=$startEpoch;DeviceEpoch=$epoch}
}

function Get-LogMetadata {
    $text = (Invoke-Adb @('-s',$script:Device,'shell','stat','-c','%F_%s_%Y_%Z_%i',$script:RemoteLog)).Trim()
    $match = [regex]::Match($text,'^(?<type>[^_]+)_(?<size>[0-9]+)_(?<mtime>[0-9]+)_(?<ctime>[0-9]+)_(?<inode>[0-9]+)$')
    Require $match.Success 'latest.log metadata was malformed.'
    Require ($match.Groups['type'].Value -ceq 'regular file') 'latest.log is absent, non-regular, or a symlink.'
    $size = [int64]$match.Groups['size'].Value
    Require ($size -gt 0 -and $size -le $script:MaxLogBytes) 'latest.log size is invalid or exceeds 64 MiB.'
    [pscustomobject]@{
        Size=$size; Modified=[int64]$match.Groups['mtime'].Value
        Changed=[int64]$match.Groups['ctime'].Value; Inode=[uint64]$match.Groups['inode'].Value
    }
}

function Assert-LogBoundToProcess($Metadata, $Anchor, [string] $Context) {
    Require ($Metadata.Modified -ge [math]::Floor($Anchor.StartEpoch-2) -and
        $Metadata.Changed -ge [math]::Floor($Anchor.StartEpoch-2) -and
        $Metadata.Modified -le ($Anchor.DeviceEpoch+2) -and
        $Metadata.Changed -le ($Anchor.DeviceEpoch+2)) `
        "$Context latest.log was not bound to the current Lab process."
    Require (($Anchor.DeviceEpoch-$Metadata.Modified) -le $script:MaxLogAgeSeconds) `
        "$Context latest.log is older than the ten-minute runtime freshness window."
}

function New-SafeTempDirectory {
    $root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $path = Join-Path $root ('quest-v71-rc8-runtime-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $path
}

function Remove-SafeTempDirectory([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    Require ($full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('quest-v71-rc8-runtime-',[StringComparison]::Ordinal)) `
        'Raw-log cleanup target escaped its unique Temp directory.'
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Force)) {
        Require (-not $item.PSIsContainer) 'Runtime Temp unexpectedly contains a directory.'
        Remove-Item -LiteralPath $item.FullName -Force
    }
    Remove-Item -LiteralPath $full -Force
}

function Invoke-Rc8RuntimeCapture {
    $script:DeviceInvocationCount = 0
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262' -and
        $script:ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
        $script:RemoteLog -ceq '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/logs/latest.log') `
        'Lab/runtime path boundary drifted.'
    Require (Test-Path -LiteralPath $script:Verifier -PathType Leaf) 'RC8 runtime verifier is missing.'
    Require (((Get-FileHash -LiteralPath $script:Verifier -Algorithm SHA256).Hash.ToUpperInvariant()) -ceq
        $script:ExpectedVerifierSha256) 'RC8 runtime verifier drifted from the reviewed verifier.'
    if (-not $Capture.IsPresent) {
        return [pscustomobject]@{
            Result='PLAN_PASS'; HostOnly=$true; CaptureRequested=$false
            Package=$script:Package; ForbiddenStablePackage=$script:ForbiddenStablePackage
            RemoteLog=$script:RemoteLog; DeviceInvocations=0; RawLogPersisted=$false
            StableTouched=$false
        }
    }

    Resolve-ExactDevice
    $processId = Get-ExactPid
    $beforeAnchor = Get-ProcessAnchor $processId
    $before = Get-LogMetadata
    Assert-LogBoundToProcess $before $beforeAnchor 'Before capture'
    $temp = New-SafeTempDirectory
    $local = Join-Path $temp 'latest.log'
    try {
        $pull = Invoke-ProcessCapture $script:Adb @('-s',$script:Device,'pull',$script:RemoteLog,$local)
        $script:DeviceInvocationCount++
        Require ($pull.ExitCode -eq 0 -and (Test-Path -LiteralPath $local -PathType Leaf)) `
            'Exact latest.log pull failed.'
        $pulledBytes = (Get-Item -LiteralPath $local).Length
        Require ($pulledBytes -ge $before.Size -and $pulledBytes -le $script:MaxLogBytes) `
            'Pulled latest.log was truncated or exceeded the bounded size.'
        $verification = @(& $script:Verifier -LogPath $local | Where-Object { $_.Result -ceq 'PASS' })
        Require ($verification.Count -eq 1) 'RC8 runtime verifier did not return one PASS result.'
        $afterProcessId = Get-ExactPid
        Require ($afterProcessId -eq $processId) 'Lab PID changed during runtime capture.'
        $afterAnchor = Get-ProcessAnchor $afterProcessId
        Require ($afterAnchor.StartTicks -eq $beforeAnchor.StartTicks) 'Lab process incarnation changed during capture.'
        $after = Get-LogMetadata
        Require ($after.Inode -eq $before.Inode -and $after.Size -ge $pulledBytes -and
            $after.Modified -ge $before.Modified -and $after.Changed -ge $before.Changed) `
            'latest.log was replaced, truncated, or rewound during capture.'
        Assert-LogBoundToProcess $after $afterAnchor 'After capture'
        [pscustomobject]@{
            Result='CAPTURE_VERIFIED_AND_PURGED'; HostOnly=$false; Package=$script:Package
            ForbiddenStablePackage=$script:ForbiddenStablePackage; Pid=$processId
            ProcessStartTicks=[uint64]$beforeAnchor.StartTicks; LogInode=[uint64]$before.Inode
            LogSha256=[string]$verification[0].LogSha256; Minecraft=[string]$verification[0].Minecraft
            Vivecraft=[string]$verification[0].Vivecraft; Veq=[string]$verification[0].Veq
            GraphicsBackend=[string]$verification[0].GraphicsBackend
            XrRuntime=[string]$verification[0].XrRuntime
            DeviceInvocations=$script:DeviceInvocationCount; RawLogPersisted=$false
            StableTouched=$false; ManualMiningAcceptance='PENDING_USER_OBSERVATION'
        }
    } finally {
        Remove-SafeTempDirectory $temp
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Rc8RuntimeCapture }
