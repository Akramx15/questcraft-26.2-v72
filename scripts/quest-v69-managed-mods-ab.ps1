<#
.SYNOPSIS
Runs one fail-closed, counterbalanced managed-mod A/B experiment on Quest Lab.

.DESCRIPTION
The package, profile, benchmark world, exact v68 core, accepted VEQ, installed
Lab APK and the selected experiment are immutable. Run alone may invoke ADB.
SelfTest, Plan and Aggregate are offline. The order is AB/BA/AB; every round
restores the fixed world, cold-starts through the one-shot autoplay gate, warms
for five minutes, captures a 10-second preflight and a 60-second aggregate-only
PID sample. Candidate markers are expected to be consumed, not absent.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest','Plan','Run','Aggregate')]
    [string] $Action = 'Plan',

    [ValidateSet('sodium-0.9.1','without-lithium','without-ferrite-core',
            'without-bad-optimizations')]
    [string] $Experiment = 'sodium-0.9.1',

    [string] $BaselineJar,
    [ValidatePattern('^$|^[0-9a-fA-F]{64}$')]
    [string] $BaselineSha256 = '',
    [string] $CandidateJar,
    [ValidatePattern('^$|^[0-9a-fA-F]{64}$')]
    [string] $CandidateSha256 = '',
    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',
    [string] $AdbPath = 'adb',
    [string] $OutputDirectory = '',
    [ValidateRange(300,900)][int] $WarmupSeconds = 300,
    [ValidateRange(1,3)][int] $MaximumPairAttempts = 3,
    [ValidateRange(0,600)][int] $InterRoundCooldownSeconds = 60,
    [ValidateRange(0.0,1.0)][double] $MaximumStartTemperatureDeltaC = 1.0,
    [ValidateRange(0.0,5.0)][double] $MaximumRefreshDistributionDistancePercent = 5.0,
    [ValidateRange(0.0,0.5)][double] $MaximumRefreshMeanDeltaHz = 0.5,
    [ValidateRange(0.0,1.0)][double] $MaximumGuardrailRegressionPercent = 1.0,
    [switch] $Resume,
    [switch] $AllowDeviceWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.canary262'
$script:Profile = '26.2'
$script:World = 'FPS-Stress-Test'
$script:WorldMasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$script:ExpectedCoreSha256 = '3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F'
$script:ExpectedVeqSha256 = '6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9'
$script:ExpectedApkSha256 = '5250F75B59DDC49B6FCCCDDAE68F88FA9D1529E0F2792A77BB29ADD7ABB4F54A'
$script:ExpectedSignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedVersionCode = '69'
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.10-rc.1'
$script:ExpectedLabel = 'QuestCraft Vivecraft Lab 26.2'
$script:ExpectedLwjglSha256 = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
$script:ModsHarnessId = 'questcraft-mods-ab-canary-v1'
$script:BenchmarkStateId = 'questcraft-v69-managed-mods-benchmark-v1'
$script:BenchmarkStateRelative = ".questcraft/$script:BenchmarkStateId"
$script:ExpectedCpuLevel = 4
$script:ExpectedGpuLevel = 4
$script:PreflightSeconds = 10
$script:SampleSeconds = 60
$script:MinimumCoveragePercent = 95.0
$script:MinimumLevel4Percent = 95.0
$script:MaximumThermalPathDeltaC = 1.0
$script:MaximumRefreshTransitionDelta = 1
$script:P95PairFloorPercent = 0.5
$script:StalePairFloorPercent = 2.0
$script:AcceptanceP95Percent = 3.0
$script:AcceptanceStalePercent = 10.0
$script:RequiredPairWins = 2
$script:ReadyTimeoutSeconds = 240
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:LockPath = Join-Path $script:RepoRoot 'MODS_AB_LAB.lock.json'
$script:TransactionScript = Join-Path $PSScriptRoot 'quest-mods-ab-lab.ps1'
$script:ResetScript = Join-Path $PSScriptRoot 'reset-lab-benchmark-world.ps1'
$script:AutoplayScript = Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'
$script:BenchmarkScript = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$script:ApkVerifier = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:PowerShellExe = $null
$script:DeviceInvocationCount = 0
$script:RunLockStream = $null
$script:Selected = $null
$script:DeviceAccessAllowed = $Action -ceq 'Run' -and [bool]$AllowDeviceWrite
$script:ExpectedOtherModsFingerprint = $null
$script:ExpectedConfigFingerprint = $null
$script:LabApk = $null
$script:BenchmarkRunId = $null
$script:RunManifest = $null

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Normalize-Sha([Parameter(Mandatory)][string] $Value) {
    $value = $Value.ToUpperInvariant()
    Require ($value -cmatch '^[0-9A-F]{64}$') 'Invalid SHA-256.'
    return $value
}

function Round-Value($Value, [int] $Digits = 2) {
    if ($null -eq $Value) { return $null }
    return [Math]::Round([double]$Value, $Digits)
}

function Test-IntegerValue($Value) {
    return $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or
            $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64]
}

function Get-Json([Parameter(Mandatory)][string] $Path) {
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Save-JsonAtomic($Value, [string] $Path, [switch] $Replace) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    if ((Test-Path -LiteralPath $full) -and -not $Replace) {
        throw "Refusing to overwrite $full"
    }
    $temp = "$full.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temp, (($Value | ConvertTo-Json -Depth 14) + "`n"),
                [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $full) {
            $backup = "$full.bak-$([guid]::NewGuid().ToString('N'))"
            [IO.File]::Replace($temp, $full, $backup, $true)
            [IO.File]::Delete($backup)
        } else { [IO.File]::Move($temp, $full) }
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}

function Get-PowerShellExe {
    $name = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $local = Join-Path $PSHOME $name
    if (Test-Path -LiteralPath $local) { return $local }
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    throw 'Could not resolve the current PowerShell executable.'
}

function Get-ExpectedExperiments {
    [ordered]@{
        'sodium-0.9.1' = [ordered]@{ Operation='replace'; Target='mods/Sodium.jar';
            Baseline='A6D1CED177A1C57147E8C1C8043650D5F93E1F2824C9952F3FB67AE05633A0A7';
            Candidate='DE406C7A0CA5E748DFBE44740278400882A44E3109E2584B243EC02D4003344B' }
        'without-lithium' = [ordered]@{ Operation='disable'; Target='mods/Lithium.jar';
            Baseline='FDDE92E238E8075F89AD7F701F2A3D5854AF88BA9A67657184A4407B104AC563';
            Candidate=('E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') }
        'without-ferrite-core' = [ordered]@{ Operation='disable'; Target='mods/Ferrite-Core.jar';
            Baseline='213966C72ED967ACC7392BEB28A866FBA301FF56B9976C2E7801C2DB7DE6BF22';
            Candidate=('E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') }
        'without-bad-optimizations' = [ordered]@{ Operation='disable'; Target='mods/BadOptimizations.jar';
            Baseline='06CEE46D81D3A0AFB8E993DFBE4B990A3BE92F52ABDE3590CC396490CB6EB4D2';
            Candidate=('E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') }
    }
}

function Resolve-HostContract {
    foreach ($path in @($script:LockPath,$script:TransactionScript,$script:ResetScript,
            $script:AutoplayScript,$script:BenchmarkScript,$script:ApkVerifier)) {
        Require (Test-Path -LiteralPath $path -PathType Leaf) "Missing helper: $path"
    }
    $expected = Get-ExpectedExperiments
    $lock = Get-Json $script:LockPath
    Require ([int]$lock.schemaVersion -eq 1) 'Managed-mod lock schema changed.'
    Require ([string]$lock.harness.id -ceq $script:ModsHarnessId -and
            [string]$lock.harness.package -ceq $script:Package -and
            [string]$lock.harness.profile -ceq $script:Profile) 'Managed-mod lock escaped Lab.'
    Require (@($lock.experiments).Count -eq 4) 'Managed-mod lock experiment count changed.'
    foreach ($id in $expected.Keys) {
        $entry = @($lock.experiments | Where-Object { [string]$_.id -ceq $id })
        Require ($entry.Count -eq 1) "Experiment $id is absent or duplicated."
        $fixed = $expected[$id]
        Require ([string]$entry[0].operation -ceq $fixed.Operation -and
                [string]$entry[0].target -ceq $fixed.Target -and
                (Normalize-Sha ([string]$entry[0].baseline.sha256)) -ceq $fixed.Baseline -and
                (Normalize-Sha ([string]$entry[0].candidate.sha256)) -ceq $fixed.Candidate) `
                ("Experiment {0} drifted: op={1}/{2}; target={3}/{4}; base={5}/{6}; candidate={7}/{8}." -f
                    $id,[string]$entry[0].operation,$fixed.Operation,[string]$entry[0].target,$fixed.Target,
                    (Normalize-Sha ([string]$entry[0].baseline.sha256)),$fixed.Baseline,
                    (Normalize-Sha ([string]$entry[0].candidate.sha256)),$fixed.Candidate)
    }
    $selected = @($lock.experiments | Where-Object { [string]$_.id -ceq $Experiment })
    Require ($selected.Count -eq 1) 'Selected experiment did not resolve uniquely.'
    $script:Selected = $selected[0]

    $transactionSource = Get-Content -Raw -LiteralPath $script:TransactionScript
    $resetSource = Get-Content -Raw -LiteralPath $script:ResetScript
    $autoplaySource = Get-Content -Raw -LiteralPath $script:AutoplayScript
    Require ($transactionSource.Contains("`$script:Package = '$script:Package'") -and
            $transactionSource.Contains("`$script:Profile = '$script:Profile'")) `
            'Managed-mod transaction helper is no longer fixed to Lab.'
    Require ($transactionSource.Contains('function Invoke-ModsAbStatus') -and
            $transactionSource.Contains("printf 'MARKER\tpresent\n'") -and
            $transactionSource.Contains("printf 'MARKER\tabsent\n'") -and
            $transactionSource.Contains("'armed','attempting','consumed','expired'")) `
            'Managed-mod transaction/status semantics changed without review.'
    Require ($resetSource.Contains("`$script:Package = '$script:Package'") -and
            $autoplaySource.Contains("`$package = '$script:Package'")) `
            'Reset/autoplay helper is no longer fixed to Lab.'
    Require ($MaximumStartTemperatureDeltaC -le 1.0 -and
            $MaximumRefreshDistributionDistancePercent -le 5.0 -and
            $MaximumRefreshMeanDeltaHz -le 0.5 -and
            $MaximumGuardrailRegressionPercent -le 1.0) 'Quality gates were weakened.'
    Require ($WarmupSeconds -eq 300) 'The managed-mod protocol requires exactly five minutes of warm-up.'
    return $lock
}

function Assert-LocalArtifacts {
    Require (-not [string]::IsNullOrWhiteSpace($BaselineJar) -and
            -not [string]::IsNullOrWhiteSpace($BaselineSha256)) `
            'BaselineJar and BaselineSha256 are required.'
    $baseline = (Resolve-Path -LiteralPath $BaselineJar).Path
    $baseActual = (Get-FileHash -LiteralPath $baseline -Algorithm SHA256).Hash.ToUpperInvariant()
    Require ($baseActual -ceq (Normalize-Sha $BaselineSha256) -and
            $baseActual -ceq (Normalize-Sha ([string]$script:Selected.baseline.sha256))) `
            'Baseline JAR does not match the selected immutable experiment.'
    $candidate = $null
    if ([string]$script:Selected.operation -ceq 'replace') {
        Require (-not [string]::IsNullOrWhiteSpace($CandidateJar) -and
                -not [string]::IsNullOrWhiteSpace($CandidateSha256)) `
                'The Sodium replacement requires CandidateJar and CandidateSha256.'
        $candidate = (Resolve-Path -LiteralPath $CandidateJar).Path
        $candidateActual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToUpperInvariant()
        Require ($candidateActual -ceq (Normalize-Sha $CandidateSha256) -and
                $candidateActual -ceq (Normalize-Sha ([string]$script:Selected.candidate.sha256))) `
                'Candidate is not the locked official Sodium 0.9.1 artifact.'
    } else {
        Require ([string]::IsNullOrWhiteSpace($CandidateJar) -and
                [string]::IsNullOrWhiteSpace($CandidateSha256)) `
                'Disable experiments do not accept a candidate JAR.'
    }
    [pscustomobject]@{ BaselinePath=$baseline; BaselineSha256=$baseActual;
        CandidatePath=$candidate; CandidateSha256=(Normalize-Sha ([string]$script:Selected.candidate.sha256));
        Target=[string]$script:Selected.target; Operation=[string]$script:Selected.operation }
}

function Resolve-OutputDirectory([string] $Requested, [switch] $GenerateDefault) {
    $root = [IO.Path]::GetFullPath((Join-Path $script:WorkspaceRoot 'artifacts\benchmarks'))
    $path = if ([string]::IsNullOrWhiteSpace($Requested)) {
        Require $GenerateDefault '-OutputDirectory is required.'
        Join-Path $root ("v69-mods-$Experiment-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    } else { [IO.Path]::GetFullPath($Requested) }
    $full = [IO.Path]::GetFullPath($path)
    Require ($full.StartsWith($root.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase)) `
            'Output must stay below artifacts\benchmarks.'
    return $full
}

function Resolve-Adb {
    Require $script:DeviceAccessAllowed 'ADB resolution is forbidden outside an authorized Run.'
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    throw 'ADB was not found.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    Require $script:DeviceAccessAllowed 'ADB invocation is forbidden outside an authorized Run.'
    $script:DeviceInvocationCount++
    $rows = @(& $script:ResolvedAdb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "ADB failed with exit code $code; output suppressed."
    }
    [pscustomobject]@{ ExitCode=$code; Lines=$rows }
}

function Resolve-Device {
    $script:ResolvedAdb = Resolve-Adb
    $rows = @(Invoke-Adb @('devices')).Lines
    $devices = @($rows | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { $Matches.serial }
    })
    Require ($devices.Count -eq 1) 'Exactly one authorized ADB device is required.'
    if ($Serial -cne 'auto') { Require ([string]$devices[0] -ceq $Serial) 'ADB serial mismatch.' }
    $script:ResolvedSerial = [string]$devices[0]
}

function ConvertTo-ShLiteral([string] $Value) {
    $q = [string][char]39
    return $q + $Value.Replace($q, $q + '"' + $q + '"' + $q) + $q
}

function Invoke-Shell([string] $Command, [switch] $AllowFailure) {
    $normalized = $Command.Replace("`r`n","`n").Replace("`r","`n")
    Invoke-Adb @('-s',$script:ResolvedSerial,'shell',$normalized) -AllowFailure:$AllowFailure
}

function Invoke-Helper([string] $Path, [string[]] $Arguments) {
    $prefix = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Path)
    $rows = @(& $script:PowerShellExe @prefix @Arguments 2>&1 |
            ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Helper $([IO.Path]::GetFileName($Path)) failed ($code)." }
    return $rows
}

function ConvertTo-PsLiteral([string] $Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-HelperObject([string] $Path, [string[]] $Arguments) {
    $argumentSource = [Collections.Generic.List[string]]::new()
    foreach ($argument in $Arguments) {
        if ($argument -cmatch '^-[A-Za-z][A-Za-z0-9]*$') {
            $argumentSource.Add($argument)
        } else {
            $argumentSource.Add((ConvertTo-PsLiteral ([string]$argument)))
        }
    }
    $payload = '$ErrorActionPreference=''Stop'';$result=& ' +
            (ConvertTo-PsLiteral $Path) + ' ' + ($argumentSource -join ' ') + ';' +
            '$result|ConvertTo-Json -Compress -Depth 8'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    $hostArgs = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
            '-EncodedCommand',$encoded)
    $rows = @(& $script:PowerShellExe @hostArgs 2>&1 |
            ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Helper $([IO.Path]::GetFileName($Path)) failed ($code)." }
    $jsonRows = @($rows | Where-Object {
        $trim = $_.Trim(); $trim.StartsWith('{') -and $trim.EndsWith('}')
    })
    Require ($jsonRows.Count -eq 1) 'Helper did not return exactly one JSON object.'
    try { return $jsonRows[0] | ConvertFrom-Json }
    catch { throw 'Helper returned invalid JSON.' }
}

function Invoke-OfflineHelperContracts($Artifacts = $null) {
    $script:PowerShellExe = Get-PowerShellExe
    foreach ($helper in @($script:ResetScript,$script:AutoplayScript,$script:BenchmarkScript)) {
        $result = Invoke-HelperObject $helper @('-Action','SelfTest')
        Require ([string]$result.Result -ceq 'PASS') `
                "Offline contract failed for $([IO.Path]::GetFileName($helper))."
    }
    $args = @('-Action','SelfTest','-Experiment',$Experiment)
    if ($null -ne $Artifacts) {
        $args += @('-BaselineJar',$Artifacts.BaselinePath,
                '-ExpectedBaselineSha256',$Artifacts.BaselineSha256)
        if ($Artifacts.Operation -ceq 'replace') {
            $args += @('-CandidateJar',$Artifacts.CandidatePath,
                    '-ExpectedCandidateSha256',$Artifacts.CandidateSha256)
        }
    }
    $transaction = Invoke-HelperObject $script:TransactionScript $args
    Require ([string]$transaction.Result -ceq 'PASS' -and
            [bool]$transaction.HostOnly -and -not [bool]$transaction.DeviceTouched -and
            [int]$transaction.AdbInvocations -eq 0) `
            'Managed-mod offline transaction contract failed.'
}

function Assert-PosixShellSyntax([string]$Source,[string]$Label) {
    $shell=$null
    foreach($candidate in @('C:\Program Files\Git\usr\bin\sh.exe',
            'C:\Program Files\Git\bin\bash.exe')){
        if(Test-Path -LiteralPath $candidate -PathType Leaf){$shell=$candidate;break}
    }
    Require ($null-ne$shell) 'Git POSIX shell is required for offline shell syntax tests.'
    $temp=Join-Path ([IO.Path]::GetTempPath()) ("qcmab-shell-$([guid]::NewGuid().ToString('N')).sh")
    try{
        [IO.File]::WriteAllText($temp,$Source,[Text.UTF8Encoding]::new($false))
        $output=@(& $shell -n $temp 2>&1|ForEach-Object{[string]$_})
        Require ($LASTEXITCODE-eq0) ("$Label shell syntax failed: "+($output-join' '))
    }finally{if(Test-Path -LiteralPath $temp){[IO.File]::Delete($temp)}}
}

function Stop-Lab {
    $null = Invoke-Shell "am force-stop $(ConvertTo-ShLiteral $script:Package)"
    for ($i=0; $i -lt 20; $i++) {
        $probe = Invoke-Shell "pidof $(ConvertTo-ShLiteral $script:Package)" -AllowFailure
        if ($probe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($probe.Lines -join ''))) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'Lab did not stop in the bounded window.'
}

function Stop-LabWithRetry {
    $failure = $null
    for ($attempt=1; $attempt -le 3; $attempt++) {
        try { Stop-Lab; return } catch { $failure = $_ }
        if ($attempt -lt 3) { Start-Sleep -Seconds 1 }
    }
    throw $failure
}

function Test-LabFocused {
    $result = Invoke-Shell 'dumpsys activity activities' -AllowFailure
    if ($result.ExitCode -ne 0) { return $false }
    $active = $result.Lines | Where-Object { $_ -match 'topResumedActivity' } | Select-Object -First 1
    if ($null -eq $active) {
        $active = $result.Lines | Where-Object { $_ -match '(mResumedActivity|ResumedActivity)' } |
                Select-Object -First 1
    }
    return $null -ne $active -and $active -match ([regex]::Escape($script:Package) + '/')
}

function Invoke-WorldReset {
    $result = Invoke-HelperObject $script:ResetScript @('-Action','Reset','-Serial',$script:ResolvedSerial,
        '-AdbPath',$script:ResolvedAdb,'-AllowDeviceWrite')
    Require ([string]$result.Result -ceq 'RESET' -and
            [string]$result.Package -ceq $script:Package -and
            [string]$result.Profile -ceq $script:Profile -and
            [string]$result.World -ceq $script:World -and
            (Normalize-Sha ([string]$result.MasterSha256)) -ceq $script:WorldMasterSha256 -and
            -not [bool]$result.RawLogsPersisted) `
            'Benchmark reset helper returned the wrong package/profile/world/master.'
}

function Start-Autoplay {
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $result = Invoke-HelperObject $script:AutoplayScript @('-Action','ArmAndRun','-Serial',
        $script:ResolvedSerial,'-AdbPath',$script:ResolvedAdb,'-AllowLaunch')
    Require ([string]$result.Result -ceq 'ARMED' -and
            [string]$result.Package -ceq $script:Package -and
            [string]$result.Profile -ceq $script:Profile -and
            [string]$result.World -ceq $script:World -and
            [int]$result.CountdownSeconds -eq 5 -and
            [string]$result.CancellationRunId -cmatch '^[A-Za-z0-9_-]+$' -and
            -not [bool]$result.RawLogsPersisted) `
            'Autoplay helper returned the wrong package/profile/world contract.'
    return $epoch
}

function Wait-WorldReady([int64] $LaunchEpoch) {
    $log = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/logs/latest.log"
    $deadline = [DateTime]::UtcNow.AddSeconds($script:ReadyTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $command = ('pidof {0} >/dev/null 2>&1 && test -f {1} && ' +
            'test "$(stat -c %Y {1})" -ge {2} && ' +
            'test "$(grep -c -E ''Loaded [0-9]+ advancements'' {1})" -ge 2') -f
            (ConvertTo-ShLiteral $script:Package),(ConvertTo-ShLiteral $log),$LaunchEpoch
        if ((Invoke-Shell $command -AllowFailure).ExitCode -eq 0 -and (Test-LabFocused)) { return }
        Start-Sleep -Seconds 1
    }
    throw 'Lab did not reach the fresh focused benchmark world.'
}

function Wait-Healthy([int] $Seconds, [string] $Label) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        $probe = Invoke-Shell "pidof $(ConvertTo-ShLiteral $script:Package)" -AllowFailure
        Require ($probe.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($probe.Lines -join ''))) `
                "Lab exited during $Label."
        Require (Test-LabFocused) "Lab lost focus during $Label."
        Start-Sleep -Seconds ([Math]::Min(5,[Math]::Max(1,$Seconds-[int]$watch.Elapsed.TotalSeconds)))
    }
}

function Get-InstalledApkIdentity {
    $pathRows = @((Invoke-Shell "pm path $(ConvertTo-ShLiteral $script:Package)").Lines |
            Where-Object { $_ -match '^package:' })
    Require ($pathRows.Count -eq 1) 'Lab must have one monolithic installed APK.'
    $remote = $pathRows[0].Substring(8)
    Require ($remote -match '^/data/app/[^\r\n]+/base\.apk$') 'Unexpected installed APK path.'
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('qcmab-apk-' + [guid]::NewGuid().ToString('N'))
    $apk = Join-Path $dir 'base.apk'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    try {
        $null = Invoke-Adb @('-s',$script:ResolvedSerial,'pull',$remote,$apk)
        $sha = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToUpperInvariant()
        Require ($sha -ceq $script:ExpectedApkSha256) 'Installed Lab APK bytes changed.'
        $verifyArgs = @{
            ApkPath = $apk
            ExpectedPackage = $script:Package
            ExpectedVersionCode = $script:ExpectedVersionCode
            ExpectedVersionName = $script:ExpectedVersionName
            ExpectedLabel = $script:ExpectedLabel
            ExpectedVivecraftSha256 = $script:ExpectedCoreSha256
            ExpectedLwjglSha256 = $script:ExpectedLwjglSha256
            ExpectedSignerSha256 = $script:ExpectedSignerSha256
        }
        $rows = @(& $script:ApkVerifier @verifyArgs)
        Require ($rows.Count -eq 1 -and [bool]$rows[0].SignatureV2 -and
                [bool]$rows[0].Zipalign16KiB -and [string]$rows[0].LabDexGate -ceq 'verified') `
                'Installed Lab APK failed full verification.'
        [pscustomobject]@{ Package=$script:Package; VersionCode=$script:ExpectedVersionCode;
            VersionName=$script:ExpectedVersionName; BaseApkSha256=$sha;
            BaseApkSizeBytes=(Get-Item $apk).Length; SignerSha256=$script:ExpectedSignerSha256;
            Verification='full-host-apk-verifier' }
    } finally { if (Test-Path $dir) { [IO.Directory]::Delete($dir,$true) } }
}

function New-StackProbe {
    $files = "/sdcard/Android/data/$script:Package/files"
    $game = "$files/instances/$script:Profile"
    $targetRelative = [string]$script:Selected.target
    $lines = @(
        'set -eu',
        ('files=$(realpath {0})' -f (ConvertTo-ShLiteral $files)),
        ('game=$(realpath {0})' -f (ConvertTo-ShLiteral $game)),
        ('test "$game" = "$files/instances/{0}"' -f $script:Profile),
        'mods="$game/mods"; config="$game/config"; options="$game/options.txt"',
        'test -d "$mods" && test ! -L "$mods" && test -d "$config" && test ! -L "$config"',
        'test -f "$options" && test ! -L "$options"',
        'core="$mods/Vivecraft.jar"; veq="$mods/Vivecraft-Essentials-Quest.jar"',
        'test -f "$core" && test ! -L "$core" && test -f "$veq" && test ! -L "$veq"',
        'printf ''CORE\t%s\n'' "$(sha256sum "$core" | awk ''{print toupper($1)}'')"',
        'printf ''VEQ\t%s\n'' "$(sha256sum "$veq" | awk ''{print toupper($1)}'')"',
        ('target="$game/{0}"' -f $targetRelative),
        'if [ -f "$target" ] && [ ! -L "$target" ]; then printf ''TARGET\t%s\n'' "$(sha256sum "$target" | awk ''{print toupper($1)}'')"; elif [ ! -e "$target" ] && [ ! -L "$target" ]; then printf ''TARGET\tABSENT\n''; else exit 67; fi',
        '(',
        ' for file in "$mods"/*.jar; do [ -e "$file" ] || continue; [ "$file" = "$target" ] && continue; test -f "$file" && test ! -L "$file"; printf ''%s\t%s\n'' "$(basename "$file")" "$(sha256sum "$file" | awk ''{print tolower($1)}'')"; done',
        ') | LC_ALL=C sort | sha256sum | awk ''{print "OTHERMODS\t" toupper($1)}''',
        'test -z "$(find "$config" -type l -print -quit)"',
        '( printf ''options.txt\t%s\n'' "$(sha256sum "$options" | awk ''{print toupper($1)}'')"; cd "$config"; find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do printf ''%s\t%s\n'' "$file" "$(sha256sum "$file" | awk ''{print toupper($1)}'')"; done ) | sha256sum | awk ''{print "CONFIG\t" toupper($1)}''',
        'core_marker="$game/.questcraft/questcraft-vivecraft-core-canary-v1/request.json"',
        'veq_marker="$game/.questcraft/questcraft-veq-frame-snapshot-canary-v1/request.json"',
        'test ! -e "$core_marker" && test ! -e "$veq_marker"',
        'printf ''FOREIGNMARKERS\tABSENT\n'''
    )
    $lines -join ([string][char]10)
}

function Get-StackState {
    $result = Invoke-Shell (New-StackProbe)
    $values = @{}
    foreach ($line in $result.Lines) {
        if ($line -match '^(CORE|VEQ|TARGET|OTHERMODS|CONFIG)\t([0-9A-F]{64}|ABSENT)$') {
            Require (-not $values.ContainsKey($Matches[1])) "Duplicate stack field $($Matches[1])."
            $values[$Matches[1]] = $Matches[2]
        }
    }
    foreach ($name in @('CORE','VEQ','TARGET','OTHERMODS','CONFIG')) {
        Require ($values.ContainsKey($name)) "Missing stack field $name."
    }
    Require (@($result.Lines | Where-Object { $_ -ceq "FOREIGNMARKERS`tABSENT" }).Count -eq 1) `
            'A core or VEQ canary marker is present.'
    [pscustomobject]@{ CoreSha256=$values.CORE; VeqSha256=$values.VEQ;
        TargetState=$values.TARGET; OtherModsFingerprint=$values.OTHERMODS;
        ConfigFingerprint=$values.CONFIG; ForeignMarkersAbsent=$true }
}

function Get-ConfigSnapshotStatus {
    $files = "/sdcard/Android/data/$script:Package/files"
    $game = "$files/instances/$script:Profile"
    $state = "$game/$script:BenchmarkStateRelative"
    $stagePrefix = ".$script:BenchmarkStateId-stage-"
    $result = Invoke-Shell @"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files))
game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
quest="`$game/.questcraft"
state=$(ConvertTo-ShLiteral $state)
if [ -e "`$quest" ] || [ -L "`$quest" ]; then
  test -d "`$quest" && test ! -L "`$quest"
  test "`$(realpath "`$quest")" = "`$game/.questcraft"
  for stage in "`$quest"/$stagePrefix*; do
    [ -e "`$stage" ] || [ -L "`$stage" ] || continue
    printf 'STAGE\t%s\n' "`$(basename "`$stage")"
  done
fi
if [ ! -e "`$state" ] && [ ! -L "`$state" ]; then
  printf 'BENCHMARK_STATE\tABSENT\n'
  exit 0
fi
test -d "`$state" && test ! -L "`$state"
test "`$(realpath "`$state")" = "`$game/$script:BenchmarkStateRelative"
contract="`$state/contract.txt"
snapshot="`$state/snapshot"
test -f "`$contract" && test ! -L "`$contract"
test "`$(stat -c %s "`$contract")" -gt 0
test "`$(stat -c %s "`$contract")" -le 1024
test -d "`$snapshot" && test ! -L "`$snapshot"
test -d "`$snapshot/config" && test ! -L "`$snapshot/config"
test -f "`$snapshot/options.txt" && test ! -L "`$snapshot/options.txt"
test -z "`$(find "`$state" -type l -print -quit)"
test -z "`$(find "`$state" ! -type d ! -type f -print -quit)"
for top in "`$state"/.[!.]* "`$state"/..?* "`$state"/*; do
  [ -e "`$top" ] || continue
  name=`$(basename "`$top")
  case "`$name" in contract.txt|snapshot|restore-*) ;; *) exit 67 ;; esac
done
restore_count=0
for work in "`$state"/restore-*; do
  [ -e "`$work" ] || continue
  test -d "`$work" && test ! -L "`$work"
  restore_count=`$((restore_count + 1))
  printf 'RESTORE_WORK\t%s\n' "`$(basename "`$work")"
done
test "`$restore_count" -le 1
fingerprint=`$( ( printf 'options.txt\t%s\n' "`$(sha256sum "`$snapshot/options.txt" | awk '{print toupper(`$1)}')"; cd "`$snapshot/config"; find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do printf '%s\t%s\n' "`$file" "`$(sha256sum "`$file" | awk '{print toupper(`$1)}')"; done ) | sha256sum | awk '{print toupper(`$1)}')
printf 'BENCHMARK_STATE\tPRESENT\n'
printf 'SNAPSHOT_FINGERPRINT\t%s\n' "`$fingerprint"
printf 'CONTRACT_BASE64\t'
base64 "`$contract" | tr -d '\n'
printf '\n'
"@
    $stateRows = @($result.Lines | Where-Object { $_ -match '^BENCHMARK_STATE\t' })
    Require ($stateRows.Count -eq 1) 'Benchmark config state status is ambiguous.'
    $stageRows = @($result.Lines | Where-Object { $_ -match '^STAGE\t' })
    $workRows = @($result.Lines | Where-Object { $_ -match '^RESTORE_WORK\t' })
    if ($stateRows[0] -ceq "BENCHMARK_STATE`tABSENT") {
        return [pscustomobject]@{State='absent';StageNames=@($stageRows|ForEach-Object{$_.Substring(6)});
            RestoreWorkNames=@();RunId=$null;ConfigFingerprint=$null;Contract=$null}
    }
    Require ($stateRows[0] -ceq "BENCHMARK_STATE`tPRESENT") 'Unknown benchmark config state.'
    $fingerprints = @($result.Lines | Where-Object { $_ -cmatch '^SNAPSHOT_FINGERPRINT\t[0-9A-F]{64}$' })
    $contracts = @($result.Lines | Where-Object { $_ -cmatch '^CONTRACT_BASE64\t[A-Za-z0-9+/]+={0,2}$' })
    Require ($fingerprints.Count -eq 1 -and $contracts.Count -eq 1) `
            'Benchmark config snapshot proof is incomplete.'
    try {
        $raw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($contracts[0].Substring(16)))
    } catch { throw 'Benchmark config contract is not strict UTF-8.' }
    $rows = @($raw.Replace("`r`n","`n").TrimEnd("`n").Split("`n"))
    Require ($rows.Count -eq 5) 'Benchmark config contract field count changed.'
    $contract = @{}
    foreach($row in $rows){
        Require ($row -cmatch '^(?<key>[A-Za-z][A-Za-z0-9]*)=(?<value>[^\r\n]*)$') `
                'Benchmark config contract syntax changed.'
        Require (-not $contract.ContainsKey($Matches.key)) `
                'Benchmark config contract contains a duplicate field.'
        $contract[$Matches.key]=$Matches.value
    }
    foreach($key in @('schema','package','profile','runId','configFingerprint')){
        Require $contract.ContainsKey($key) "Benchmark config contract lacks $key."
    }
    Require ($contract.Count -eq 5) 'Benchmark config contract has unknown fields.'
    [pscustomobject]@{State='present';StageNames=@($stageRows|ForEach-Object{$_.Substring(6)});
        RestoreWorkNames=@($workRows|ForEach-Object{$_.Substring(13)});
        RunId=[string]$contract.runId;ConfigFingerprint=$fingerprints[0].Substring(21);
        Contract=[pscustomobject]$contract}
}

function Assert-ConfigSnapshotContract($Status,$Manifest,[switch]$AllowInterruptedRestore) {
    Require ([string]$Status.State -ceq 'present' -and @($Status.StageNames).Count -eq 0) `
            'Exact benchmark config snapshot is absent or has a staging remainder.'
    Require ([string]$Status.Contract.schema -ceq '1' -and
            [string]$Status.Contract.package -ceq $script:Package -and
            [string]$Status.Contract.profile -ceq $script:Profile -and
            [string]$Status.RunId -ceq [string]$Manifest.BenchmarkRunId -and
            [string]$Status.Contract.runId -ceq [string]$Manifest.BenchmarkRunId -and
            (Normalize-Sha ([string]$Status.ConfigFingerprint)) -ceq
                (Normalize-Sha ([string]$Manifest.ConfigSnapshotFingerprint)) -and
            (Normalize-Sha ([string]$Status.Contract.configFingerprint)) -ceq
                (Normalize-Sha ([string]$Manifest.ConfigSnapshotFingerprint))) `
            'Benchmark config snapshot escaped its fixed Lab contract.'
    $works=@($Status.RestoreWorkNames)
    if($AllowInterruptedRestore){
        Require ($works.Count -le 1 -and ($works.Count -eq 0 -or
                [string]$works[0] -ceq "restore-$($Manifest.BenchmarkRunId)")) `
                'Benchmark config state contains foreign restore work.'
    }else{Require ($works.Count -eq 0) 'Interrupted config restore work remains.'}
}

function Invoke-CreateConfigSnapshot($Manifest,[switch]$BuildOnly) {
    $runId=[string]$Manifest.BenchmarkRunId
    Require ($runId -cmatch '^[0-9a-f]{32}$') 'Benchmark run id is invalid.'
    $expected=Normalize-Sha ([string]$Manifest.ConfigSnapshotFingerprint)
    $files="/sdcard/Android/data/$script:Package/files"
    $game="$files/instances/$script:Profile"
    $state="$game/$script:BenchmarkStateRelative"
    $stage="$game/.questcraft/.$script:BenchmarkStateId-stage-$runId"
    $command=@"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files))
game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
! pidof $(ConvertTo-ShLiteral $script:Package) >/dev/null 2>&1
config="`$game/config"; options="`$game/options.txt"; quest="`$game/.questcraft"
test -d "`$config" && test ! -L "`$config"
test -f "`$options" && test ! -L "`$options"
test -z "`$(find "`$config" -type l -print -quit)"
if [ ! -e "`$quest" ] && [ ! -L "`$quest" ]; then mkdir "`$quest"; fi
test -d "`$quest" && test ! -L "`$quest"
test "`$(realpath "`$quest")" = "`$game/.questcraft"
state="`$game/$script:BenchmarkStateRelative"
stage="`$game/.questcraft/.$script:BenchmarkStateId-stage-$runId"
test ! -e "`$state" && test ! -L "`$state"
for found in "`$quest"/.$script:BenchmarkStateId-stage-*; do
  [ -e "`$found" ] || [ -L "`$found" ] || continue
  test "`$found" = "`$stage"
  test -d "`$found" && test ! -L "`$found"
  test "`$(realpath "`$found")" = "`$stage"
  test -z "`$(find "`$found" -type l -print -quit)"
  test -z "`$(find "`$found" ! -type d ! -type f -print -quit)"
  rm -r -- "`$found"
done
cleanup_stage() {
  if [ -e "`$stage" ] || [ -L "`$stage" ]; then
    test -d "`$stage" && test ! -L "`$stage"
    test "`$(realpath "`$stage")" = "`$stage"
    test -z "`$(find "`$stage" -type l -print -quit)"
    rm -r -- "`$stage"
  fi
}
trap cleanup_stage EXIT HUP INT TERM
mkdir "`$stage"; mkdir "`$stage/snapshot"
cp -a "`$config" "`$stage/snapshot/config"
cp -p "`$options" "`$stage/snapshot/options.txt"
test -z "`$(find "`$stage/snapshot" -type l -print -quit)"
test -z "`$(find "`$stage/snapshot" ! -type d ! -type f -print -quit)"
fingerprint=`$( ( printf 'options.txt\t%s\n' "`$(sha256sum "`$stage/snapshot/options.txt" | awk '{print toupper(`$1)}')"; cd "`$stage/snapshot/config"; find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do printf '%s\t%s\n' "`$file" "`$(sha256sum "`$file" | awk '{print toupper(`$1)}')"; done ) | sha256sum | awk '{print toupper(`$1)}')
test "`$fingerprint" = $(ConvertTo-ShLiteral $expected)
printf 'schema=1\npackage=%s\nprofile=%s\nrunId=%s\nconfigFingerprint=%s\n' $(ConvertTo-ShLiteral $script:Package) $(ConvertTo-ShLiteral $script:Profile) $(ConvertTo-ShLiteral $runId) $(ConvertTo-ShLiteral $expected) > "`$stage/contract.txt"
mv "`$stage" "`$state"
trap - EXIT HUP INT TERM
printf 'SNAPSHOT_CREATED\n'
"@
    if($BuildOnly){return $command}
    $result=Invoke-Shell $command -AllowFailure
    Require ($result.ExitCode -eq 0 -and
            @($result.Lines|Where-Object{$_-ceq'SNAPSHOT_CREATED'}).Count -eq 1) `
            'Atomic benchmark config snapshot creation failed.'
}

function Invoke-RestoreConfigSnapshot($Manifest,[switch]$BuildOnly) {
    $runId=[string]$Manifest.BenchmarkRunId
    $expected=Normalize-Sha ([string]$Manifest.ConfigSnapshotFingerprint)
    $files="/sdcard/Android/data/$script:Package/files"
    $game="$files/instances/$script:Profile"
    $state="$game/$script:BenchmarkStateRelative"
    $work="$state/restore-$runId"
    $command=@"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files)); game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
! pidof $(ConvertTo-ShLiteral $script:Package) >/dev/null 2>&1
state="`$game/$script:BenchmarkStateRelative"; work="`$state/restore-$runId"
test -d "`$state" && test ! -L "`$state"
test "`$(realpath "`$state")" = "`$game/$script:BenchmarkStateRelative"
snapshot="`$state/snapshot"; config="`$game/config"; options="`$game/options.txt"
test -d "`$snapshot/config" && test ! -L "`$snapshot/config"
test -f "`$snapshot/options.txt" && test ! -L "`$snapshot/options.txt"
cleanup_tree() { test -d "`$1" && test ! -L "`$1"; test -z "`$(find "`$1" -type l -print -quit)"; rm -r -- "`$1"; }
recover_work() {
  [ -e "`$work" ] || [ -L "`$work" ] || return 0
  test -d "`$work" && test ! -L "`$work"
  test "`$(realpath "`$work")" = "`$state/restore-$runId"
  test -z "`$(find "`$work" -type l -print -quit)"
  test -z "`$(find "`$work" ! -type d ! -type f -print -quit)"
  for entry in "`$work"/.[!.]* "`$work"/..?* "`$work"/*; do [ -e "`$entry" ] || continue; case "`$(basename "`$entry")" in config.new|options.new|config.old|options.old|config.failed|options.failed|phase) ;; *) exit 67 ;; esac; done
  if [ -d "`$work/config.old" ]; then
    if [ -e "`$config" ] || [ -L "`$config" ]; then test -d "`$config" && test ! -L "`$config"; mv "`$config" "`$work/config.failed"; fi
    mv "`$work/config.old" "`$config"
  fi
  if [ -f "`$work/options.old" ]; then
    if [ -e "`$options" ] || [ -L "`$options" ]; then test -f "`$options" && test ! -L "`$options"; mv "`$options" "`$work/options.failed"; fi
    mv "`$work/options.old" "`$options"
  fi
  cleanup_tree "`$work"
}
recover_work
test -d "`$config" && test ! -L "`$config"; test -f "`$options" && test ! -L "`$options"
mkdir "`$work"; trap 'recover_work' EXIT HUP INT TERM
cp -a "`$snapshot/config" "`$work/config.new"; cp -p "`$snapshot/options.txt" "`$work/options.new"
test -z "`$(find "`$work/config.new" -type l -print -quit)"
stagefp=`$( ( printf 'options.txt\t%s\n' "`$(sha256sum "`$work/options.new" | awk '{print toupper(`$1)}')"; cd "`$work/config.new"; find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do printf '%s\t%s\n' "`$file" "`$(sha256sum "`$file" | awk '{print toupper(`$1)}')"; done ) | sha256sum | awk '{print toupper(`$1)}')
test "`$stagefp" = $(ConvertTo-ShLiteral $expected)
printf 'PREPARED\n' > "`$work/phase"
mv "`$config" "`$work/config.old"; mv "`$work/config.new" "`$config"; printf 'CONFIG_NEW\n' > "`$work/phase"
mv "`$options" "`$work/options.old"; mv "`$work/options.new" "`$options"; printf 'OPTIONS_NEW\n' > "`$work/phase"
actual=`$( ( printf 'options.txt\t%s\n' "`$(sha256sum "`$options" | awk '{print toupper(`$1)}')"; cd "`$config"; find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do printf '%s\t%s\n' "`$file" "`$(sha256sum "`$file" | awk '{print toupper(`$1)}')"; done ) | sha256sum | awk '{print toupper(`$1)}')
test "`$actual" = $(ConvertTo-ShLiteral $expected)
printf 'COMMITTED\n' > "`$work/phase"
trap - EXIT HUP INT TERM
cleanup_tree "`$work"
printf 'CONFIG_RESTORED\n'
"@
    if($BuildOnly){return $command}
    $status=Get-ConfigSnapshotStatus
    Assert-ConfigSnapshotContract $status $Manifest -AllowInterruptedRestore
    $result=Invoke-Shell $command -AllowFailure
    Require ($result.ExitCode -eq 0 -and
            @($result.Lines|Where-Object{$_-ceq'CONFIG_RESTORED'}).Count -eq 1) `
            'Atomic benchmark config restore failed.'
    $after=Get-StackState
    Require ((Normalize-Sha $after.ConfigFingerprint)-ceq$expected) `
            'Restored config/options fingerprint is not canonical.'
    Assert-ConfigSnapshotContract (Get-ConfigSnapshotStatus) $Manifest
}

function Invoke-EnsureConfigSnapshot([string]$ManifestPath,$Manifest) {
    $state=[string]$Manifest.ConfigSnapshotState
    Require ($state-ceq'pending'-or$state-ceq'ready') `
            'Unknown host config snapshot state.'
    $status=Get-ConfigSnapshotStatus
    if($state-ceq'pending'){
        if([string]$status.State-ceq'absent'){
            $expectedStage=".$script:BenchmarkStateId-stage-$($Manifest.BenchmarkRunId)"
            $stages=@($status.StageNames)
            Require ($stages.Count-le1-and($stages.Count-eq0-or
                    [string]$stages[0]-ceq$expectedStage)) `
                    'Pending snapshot has foreign staging state.'
            $current=Get-StackState
            Assert-StackContract $current A
            Invoke-CreateConfigSnapshot $Manifest
        }else{
            Assert-ConfigSnapshotContract $status $Manifest
        }
        $status=Get-ConfigSnapshotStatus
        Assert-ConfigSnapshotContract $status $Manifest
        $Manifest.ConfigSnapshotState='ready'
        Save-JsonAtomic $Manifest $ManifestPath -Replace
    }else{
        Assert-ConfigSnapshotContract $status $Manifest -AllowInterruptedRestore
    }
    Invoke-RestoreConfigSnapshot $Manifest
    return $Manifest
}

function Invoke-CleanupConfigSnapshot($Manifest,[switch]$BuildOnly) {
    $files="/sdcard/Android/data/$script:Package/files"
    $game="$files/instances/$script:Profile"
    $state="$game/$script:BenchmarkStateRelative"
    $command=@"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files)); game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
! pidof $(ConvertTo-ShLiteral $script:Package) >/dev/null 2>&1
state="`$game/$script:BenchmarkStateRelative"
test -d "`$state" && test ! -L "`$state"
test "`$(realpath "`$state")" = "`$game/$script:BenchmarkStateRelative"
test -f "`$state/contract.txt" && test ! -L "`$state/contract.txt"
test -d "`$state/snapshot/config" && test ! -L "`$state/snapshot/config"
test -f "`$state/snapshot/options.txt" && test ! -L "`$state/snapshot/options.txt"
test -z "`$(find "`$state" -type l -print -quit)"
test -z "`$(find "`$state" ! -type d ! -type f -print -quit)"
for top in "`$state"/.[!.]* "`$state"/..?* "`$state"/*; do [ -e "`$top" ] || continue; case "`$(basename "`$top")" in contract.txt|snapshot) ;; *) exit 67 ;; esac; done
rm -r -- "`$state"
test ! -e "`$state" && test ! -L "`$state"
printf 'CONFIG_STATE_CLEAN\n'
"@
    if($BuildOnly){return $command}
    $current=Get-StackState
    Assert-StackContract $current A
    Assert-TransactionContract (Get-ModTransactionStatus) A $current.OtherModsFingerprint
    $status=Get-ConfigSnapshotStatus
    Assert-ConfigSnapshotContract $status $Manifest
    $result=Invoke-Shell $command -AllowFailure
    Require ($result.ExitCode-eq0-and
            @($result.Lines|Where-Object{$_-ceq'CONFIG_STATE_CLEAN'}).Count-eq1) `
            'Final benchmark config-state cleanup failed.'
    $afterStatus=Get-ConfigSnapshotStatus
    Require ([string]$afterStatus.State-ceq'absent'-and
            @($afterStatus.StageNames).Count-eq0) `
            'Final cleanup left benchmark config state/stages.'
    $after=Get-StackState
    Assert-StackContract $after A
    Assert-TransactionContract (Get-ModTransactionStatus) A $after.OtherModsFingerprint
}

function Get-ModTransactionStatus {
    $game = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile"
    $marker = "$game/.questcraft/$script:ModsHarnessId/request.json"
    $result = Invoke-Shell @"
set -eu
marker=$(ConvertTo-ShLiteral $marker)
if [ -f `$marker ] && [ ! -L `$marker ]; then
  test "`$(stat -c %s `$marker)" -gt 0
  test "`$(stat -c %s `$marker)" -le 16384
  printf 'MARKER_PRESENT\n'
  base64 `$marker | tr -d '\n'
  printf '\n'
elif [ ! -e `$marker ] && [ ! -L `$marker ]; then printf 'MARKER_ABSENT\n';
else exit 67; fi
"@
    $present = @($result.Lines | Where-Object { $_ -ceq 'MARKER_PRESENT' })
    $absent = @($result.Lines | Where-Object { $_ -ceq 'MARKER_ABSENT' })
    Require (($present.Count + $absent.Count) -eq 1) 'Managed-mod marker status is ambiguous.'
    if ($absent.Count -eq 1) {
        return [pscustomobject]@{ MarkerState='absent'; RunId=$null; Marker=$null; RawSha256=$null }
    }
    $encoded = @($result.Lines | Where-Object { $_ -cmatch '^[A-Za-z0-9+/]+={0,2}$' })
    Require ($encoded.Count -eq 1) 'Managed-mod marker payload is ambiguous.'
    try {
        $raw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded[0]))
        $markerObject = $raw | ConvertFrom-Json
    } catch { throw 'Managed-mod marker is not strict UTF-8 JSON.' }
    $expectedFields = @('schemaVersion','harnessId','state','packageName','profile','target','runId',
        'baselineSha256','baselineSizeBytes','candidateSha256','candidateSizeBytes','fabricId',
        'fabricVersion','minecraftDependency','javaDependency','otherModsFingerprintSha256',
        'openXrCopyBatchMode','expiresAtEpochMs','maxLaunches')
    $names = @([regex]::Matches($raw,'"(?<n>(?:\\.|[^"\\])*)"\s*:') |
            ForEach-Object { $_.Groups['n'].Value })
    Require ($names.Count -eq $expectedFields.Count) 'Managed-mod marker member count changed.'
    foreach ($field in $expectedFields) {
        Require (@($names | Where-Object { $_ -ceq $field }).Count -eq 1) `
                "Managed-mod marker field $field is missing or duplicated."
    }
    [pscustomobject]@{ MarkerState=[string]$markerObject.state;
        RunId=[string]$markerObject.runId; Marker=$markerObject;
        RawSha256=(Get-Sha256Text $raw) }
}

function Get-ModTransactionStatePresence {
    $files="/sdcard/Android/data/$script:Package/files"
    $game="$files/instances/$script:Profile"
    $state="$game/.questcraft/$script:ModsHarnessId"
    $result=Invoke-Shell @"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files)); game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
state="`$game/.questcraft/$script:ModsHarnessId"
if [ ! -e "`$state" ] && [ ! -L "`$state" ]; then printf 'MOD_STATE\tABSENT\n'; exit 0; fi
test -d "`$state" && test ! -L "`$state"
test "`$(realpath "`$state")" = "`$game/.questcraft/$script:ModsHarnessId"
printf 'MOD_STATE\tPRESENT\n'
"@
    $rows=@($result.Lines|Where-Object{$_-match'^MOD_STATE\t'})
    Require ($rows.Count-eq1-and($rows[0]-ceq"MOD_STATE`tABSENT"-or
            $rows[0]-ceq"MOD_STATE`tPRESENT")) 'Mod transaction state presence is ambiguous.'
    if($rows[0]-ceq"MOD_STATE`tPRESENT"){'present'}else{'absent'}
}

function Get-Sha256Text([string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','') }
    finally { $sha.Dispose() }
}

function Assert-TransactionContract($Status, [ValidateSet('A','B')][string] $Condition,
        [string] $OtherModsFingerprint) {
    if ($Condition -ceq 'A') {
        Require ([string]$Status.MarkerState -ceq 'absent' -and
                [string]::IsNullOrWhiteSpace([string]$Status.RunId)) `
                'Baseline condition requires no managed-mod marker or run id.'
        return
    }
    $marker = $Status.Marker
    Require ([string]$Status.MarkerState -ceq 'consumed' -and
            [string]$Status.RunId -cmatch '^[0-9a-f]{32}$') `
            'Candidate marker must be consumed with one strict run id.'
    Require ([int]$marker.schemaVersion -eq 2 -and
            [string]$marker.harnessId -ceq $script:ModsHarnessId -and
            [string]$marker.packageName -ceq $script:Package -and
            [string]$marker.profile -ceq $script:Profile -and
            [string]$marker.target -ceq [string]$script:Selected.target) `
            'Candidate marker escaped the fixed experiment identity.'
    Require ((Normalize-Sha ([string]$marker.baselineSha256)) -ceq
            (Normalize-Sha ([string]$script:Selected.baseline.sha256)) -and
            (Normalize-Sha ([string]$marker.candidateSha256)) -ceq
            (Normalize-Sha ([string]$script:Selected.candidate.sha256))) `
            'Candidate marker artifact hashes changed.'
    Require ((Normalize-Sha ([string]$marker.otherModsFingerprintSha256)) -ceq
            (Normalize-Sha $OtherModsFingerprint)) 'Candidate marker other-mod fingerprint changed.'
    Require ([int64]$marker.baselineSizeBytes -eq [int64]$script:Selected.baseline.sizeBytes -and
            [int64]$marker.candidateSizeBytes -eq [int64]$script:Selected.candidate.sizeBytes -and
            [string]$marker.fabricId -ceq [string]$script:Selected.candidate.fabricId -and
            [string]$marker.fabricVersion -ceq [string]$script:Selected.candidate.fabricVersion -and
            [string]$marker.minecraftDependency -ceq [string]$script:Selected.candidate.minecraftDependency -and
            [string]$marker.javaDependency -ceq [string]$script:Selected.candidate.javaDependency) `
            'Candidate marker metadata changed from the selected lock.'
    Require ([string]$marker.openXrCopyBatchMode -ceq 'OFF' -and
            [int]$marker.maxLaunches -eq 1) 'Candidate marker weakened runtime isolation.'
    Require ((Test-IntegerValue $marker.expiresAtEpochMs) -and
            [int64]$marker.expiresAtEpochMs -gt
                [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) `
            'Candidate marker expiry is not an unexpired JSON integer.'
}

function Get-ExpectedTargetState([ValidateSet('A','B')][string] $Condition) {
    if ($Condition -ceq 'A') { return Normalize-Sha ([string]$script:Selected.baseline.sha256) }
    if ([string]$script:Selected.operation -ceq 'disable') { return 'ABSENT' }
    return Normalize-Sha ([string]$script:Selected.candidate.sha256)
}

function Assert-StackContract($State, [ValidateSet('A','B')][string] $Condition) {
    Require ((Normalize-Sha ([string]$State.CoreSha256)) -ceq $script:ExpectedCoreSha256) `
            'Exact v68 core changed.'
    Require ((Normalize-Sha ([string]$State.VeqSha256)) -ceq $script:ExpectedVeqSha256) `
            'Accepted VEQ changed.'
    Require ([string]$State.TargetState -ceq (Get-ExpectedTargetState $Condition)) `
            'Selected managed-mod target does not match the condition.'
    Require ((Normalize-Sha ([string]$State.OtherModsFingerprint)) -ceq
            $script:ExpectedOtherModsFingerprint) 'A non-selected mod changed.'
    Require ((Normalize-Sha ([string]$State.ConfigFingerprint)) -ceq
            $script:ExpectedConfigFingerprint) 'Config/options fingerprint changed.'
    Require ([bool]$State.ForeignMarkersAbsent) 'A core or VEQ marker is pending.'
}

function Test-EmergencyStateAllowed($Artifacts, [string] $TargetState) {
    if ($Artifacts.Operation -ceq 'replace') {
        return $TargetState -ceq $Artifacts.CandidateSha256
    }
    return $Artifacts.Operation -ceq 'disable' -and $TargetState -ceq 'ABSENT'
}

function Get-RollbackRecoveryMode([bool]$StatusReadable,[string]$MarkerState,
        [string]$TargetState,$Artifacts) {
    if($StatusReadable-and$MarkerState-cne'absent'){return 'NORMAL_ROLLBACK'}
    if($TargetState-ceq$Artifacts.BaselineSha256){return 'CLEAN_BASELINE_STATE'}
    if(Test-EmergencyStateAllowed $Artifacts $TargetState){return 'EMERGENCY_RESTORE'}
    return 'REFUSE'
}

function Invoke-ExactBaselineStateCleanup($Artifacts,[switch]$BuildOnly) {
    $files="/sdcard/Android/data/$script:Package/files"
    $game="$files/instances/$script:Profile"
    $state="$game/.questcraft/$script:ModsHarnessId"
    $target="$game/$($script:Selected.target)"
    $ownedNames=@('baseline.jar','prelaunch.lock','request.json','request.rejected.json',
        'candidate-*.jar','candidate-*.upload','disabled-*.jar','request-*.tmp',
        'request-*.upload','baseline-*.upload')
    $casePatterns=($ownedNames-join'|')+')'
    $command=@"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files)); game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
! pidof $(ConvertTo-ShLiteral $script:Package) >/dev/null 2>&1
target="`$game/$($script:Selected.target)"; state="`$game/.questcraft/$script:ModsHarnessId"
test -f "`$target" && test ! -L "`$target"
test "`$(stat -c %s "`$target")" = $([int64]$script:Selected.baseline.sizeBytes)
test "`$(sha256sum "`$target" | awk '{print toupper(`$1)}')" = $(ConvertTo-ShLiteral $Artifacts.BaselineSha256)
if [ -e "`$state" ] || [ -L "`$state" ]; then
  test -d "`$state" && test ! -L "`$state"
  test "`$(realpath "`$state")" = "`$game/.questcraft/$script:ModsHarnessId"
  test -z "`$(find "`$state" -mindepth 1 ! -type f -print -quit)"
  for owned in "`$state"/.[!.]* "`$state"/..?* "`$state"/*; do
    [ -e "`$owned" ] || continue
    test -f "`$owned" && test ! -L "`$owned"
    case "`$(basename "`$owned")" in $casePatterns ;; *) exit 67 ;; esac
  done
  for owned in "`$state"/.[!.]* "`$state"/..?* "`$state"/*; do [ -e "`$owned" ] || continue; rm -f -- "`$owned"; done
  rmdir "`$state"
fi
printf 'BASELINE_STATE_CLEAN\n'
"@
    if($BuildOnly){return $command}
    Require ($null-ne$script:ExpectedOtherModsFingerprint-and
            $null-ne$script:ExpectedConfigFingerprint) `
            'Exact baseline cleanup requires pinned non-selected mods/config.'
    $before=Get-StackState
    Assert-StackContract $before A
    $result=Invoke-Shell $command -AllowFailure
    Require ($result.ExitCode-eq0-and
            @($result.Lines|Where-Object{$_-ceq'BASELINE_STATE_CLEAN'}).Count-eq1) `
            'Exact baseline transaction-state cleanup failed.'
    $after=Get-StackState
    Assert-StackContract $after A
    Require ([string](Get-ModTransactionStatus).MarkerState-ceq'absent') `
            'Exact baseline cleanup did not prove an absent marker.'
}

function Invoke-EmergencyScratchCleanup([string]$Upload,[string]$StageName,[switch]$BuildOnly) {
    Require ($Upload-cmatch'^/data/local/tmp/qcmab-emergency-[0-9a-f]{32}-baseline\.upload$'-and
            $StageName-cmatch'^\.mods-ab-emergency-[0-9a-f]{32}\.tmp$') `
            'Emergency scratch cleanup path escaped its owned namespace.'
    $files="/sdcard/Android/data/$script:Package/files"
    $game="$files/instances/$script:Profile"
    $command=@"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files)); game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
! pidof $(ConvertTo-ShLiteral $script:Package) >/dev/null 2>&1
mods=`$(realpath "`$game/mods"); stage="`$mods/$StageName"; upload=$(ConvertTo-ShLiteral $Upload)
test -d "`$mods" && test ! -L "`$mods"
if [ -e "`$stage" ] || [ -L "`$stage" ]; then
  test -f "`$stage" && test ! -L "`$stage"
  test "`$(realpath "`$(dirname "`$stage")")" = "`$mods"
  rm -f -- "`$stage"
fi
if [ -e "`$upload" ] || [ -L "`$upload" ]; then
  test -f "`$upload" && test ! -L "`$upload"
  test "`$(realpath "`$(dirname "`$upload")")" = '/data/local/tmp'
  rm -f -- "`$upload"
fi
test ! -e "`$stage" && test ! -L "`$stage"
test ! -e "`$upload" && test ! -L "`$upload"
printf 'EMERGENCY_SCRATCH_CLEAN\n'
"@
    if($BuildOnly){return $command}
    for($attempt=1;$attempt-le3;$attempt++){
        $result=Invoke-Shell $command -AllowFailure
        if($result.ExitCode-eq0-and
                @($result.Lines|Where-Object{$_-ceq'EMERGENCY_SCRATCH_CLEAN'}).Count-eq1){return}
        if($attempt-lt3){Start-Sleep -Milliseconds 250}
    }
    throw 'Emergency scratch cleanup failed after three bounded attempts.'
}

function Invoke-CleanupEmergencyStageNamespace([switch]$BuildOnly) {
    $files="/sdcard/Android/data/$script:Package/files"
    $game="$files/instances/$script:Profile"
    $command=@"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files)); game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
! pidof $(ConvertTo-ShLiteral $script:Package) >/dev/null 2>&1
mods=`$(realpath "`$game/mods")
test -d "`$mods" && test ! -L "`$mods"
for stage in "`$mods"/.mods-ab-emergency-*.tmp; do
  if [ ! -e "`$stage" ] && [ ! -L "`$stage" ]; then continue; fi
  name=`$(basename "`$stage")
  printf '%s\n' "`$name" | grep -Eq '^\.mods-ab-emergency-[0-9a-f]{32}\.tmp$'
  test -f "`$stage" && test ! -L "`$stage"
  test "`$(realpath "`$(dirname "`$stage")")" = "`$mods"
  rm -f -- "`$stage"
done
for stage in "`$mods"/.mods-ab-emergency-*.tmp; do
  if [ -e "`$stage" ] || [ -L "`$stage" ]; then exit 68; fi
done
printf 'EMERGENCY_STAGE_NAMESPACE_CLEAN\n'
"@
    if($BuildOnly){return $command}
    for($attempt=1;$attempt-le3;$attempt++){
        $result=Invoke-Shell $command -AllowFailure
        if($result.ExitCode-eq0-and
                @($result.Lines|Where-Object{$_-ceq'EMERGENCY_STAGE_NAMESPACE_CLEAN'}).Count-eq1){return}
        if($attempt-lt3){Start-Sleep -Milliseconds 250}
    }
    throw 'Emergency stage namespace cleanup failed after three bounded attempts.'
}

function Invoke-EmergencyBaselineRecovery($Artifacts, [string] $Reason,[switch]$BuildOnly) {

    $run = [guid]::NewGuid().ToString('N')
    $upload = "/data/local/tmp/qcmab-emergency-$run-baseline.upload"
    $files = "/sdcard/Android/data/$script:Package/files"
    $game = "$files/instances/$script:Profile"
    $targetRelative = [string]$script:Selected.target
    $stateRelative = ".questcraft/$script:ModsHarnessId"
    $stageName = ".mods-ab-emergency-$run.tmp"
    $candidateGuard = if ($Artifacts.Operation -ceq 'replace') {
        'test -f "$target" && test ! -L "$target"; ' +
        ('test "$(stat -c %s "$target")" = {0}; ' -f [string]$script:Selected.candidate.sizeBytes) +
        ('test "$(sha256sum "$target" | awk ''{{print toupper($1)}}'')" = {0}' -f
            (ConvertTo-ShLiteral $Artifacts.CandidateSha256))
    } else { 'test ! -e "$target" && test ! -L "$target"' }
    $ownedNames = @(
        'baseline.jar','prelaunch.lock','request.json','request.rejected.json',
        'candidate-*.jar','candidate-*.upload','disabled-*.jar','request-*.tmp',
        'request-*.upload','baseline-*.upload')
    $casePatterns = ($ownedNames -join '|') + ')'
    $command = @"
set -eu
files=`$(realpath $(ConvertTo-ShLiteral $files))
game=`$(realpath $(ConvertTo-ShLiteral $game))
test "`$game" = "`$files/instances/$script:Profile"
mods="`$game/mods"
target="`$game/$targetRelative"
state="`$game/$stateRelative"
stage="`$mods/$stageName"
upload=$(ConvertTo-ShLiteral $upload)
! pidof $(ConvertTo-ShLiteral $script:Package) >/dev/null 2>&1
test -d "`$mods" && test ! -L "`$mods"
cleanup_emergency() {
  if [ -e "`$stage" ] || [ -L "`$stage" ]; then test -f "`$stage" && test ! -L "`$stage"; rm -f -- "`$stage"; fi
  if [ -e "`$upload" ] || [ -L "`$upload" ]; then test -f "`$upload" && test ! -L "`$upload"; rm -f -- "`$upload"; fi
}
trap cleanup_emergency EXIT HUP INT TERM
$candidateGuard
test -f "`$upload" && test ! -L "`$upload"
test "`$(stat -c %s "`$upload")" = $([int64]$script:Selected.baseline.sizeBytes)
test "`$(sha256sum "`$upload" | awk '{print toupper(`$1)}')" = $(ConvertTo-ShLiteral $Artifacts.BaselineSha256)
if [ -e "`$state" ] || [ -L "`$state" ]; then
  test -d "`$state" && test ! -L "`$state"
  test "`$(realpath "`$state")" = "`$game/$stateRelative"
  test -z "`$(find "`$state" -mindepth 1 ! -type f -print -quit)"
  for owned in "`$state"/.[!.]* "`$state"/..?* "`$state"/*; do
    [ -e "`$owned" ] || continue
    test -f "`$owned" && test ! -L "`$owned"
    name=`$(basename "`$owned")
    case "`$name" in $casePatterns ;; *) exit 67 ;; esac
  done
fi
test ! -e "`$stage" && test ! -L "`$stage"
cp "`$upload" "`$stage"
test "`$(stat -c %s "`$stage")" = $([int64]$script:Selected.baseline.sizeBytes)
test "`$(sha256sum "`$stage" | awk '{print toupper(`$1)}')" = $(ConvertTo-ShLiteral $Artifacts.BaselineSha256)
mv "`$stage" "`$target"
test "`$(stat -c %s "`$target")" = $([int64]$script:Selected.baseline.sizeBytes)
test "`$(sha256sum "`$target" | awk '{print toupper(`$1)}')" = $(ConvertTo-ShLiteral $Artifacts.BaselineSha256)
if [ -d "`$state" ]; then
  for owned in "`$state"/.[!.]* "`$state"/..?* "`$state"/*; do [ -e "`$owned" ] || continue; rm -f -- "`$owned"; done
  rmdir "`$state"
fi
cleanup_emergency
test ! -e "`$stage" && test ! -L "`$stage"
test ! -e "`$upload" && test ! -L "`$upload"
trap - EXIT HUP INT TERM
printf 'RECOVERED\n'
"@
    if($BuildOnly){return $command}
    $stateBefore = Get-StackState
    Require ((Normalize-Sha $stateBefore.CoreSha256) -ceq $script:ExpectedCoreSha256 -and
            (Normalize-Sha $stateBefore.VeqSha256) -ceq $script:ExpectedVeqSha256) `
            'Emergency recovery refused a changed core or VEQ.'
    Require ($null-ne$script:ExpectedOtherModsFingerprint-and
            $null-ne$script:ExpectedConfigFingerprint-and
            (Normalize-Sha $stateBefore.OtherModsFingerprint) -ceq
                $script:ExpectedOtherModsFingerprint -and
            (Normalize-Sha $stateBefore.ConfigFingerprint) -ceq
                $script:ExpectedConfigFingerprint) `
            'Emergency recovery refused changed/unpinned non-selected mods/config.'
    $allowedBrokenState = Test-EmergencyStateAllowed $Artifacts ([string]$stateBefore.TargetState)
    Require $allowedBrokenState `
            'Emergency recovery is allowed only from the exact candidate/ABSENT state.'
    try {
        $null = Invoke-Adb @('-s',$script:ResolvedSerial,'push',$Artifacts.BaselinePath,$upload)
        $result = Invoke-Shell $command -AllowFailure
        Require ($result.ExitCode -eq 0 -and
                @($result.Lines | Where-Object { $_ -ceq 'RECOVERED' }).Count -eq 1) `
                "Emergency baseline recovery failed after $Reason."
    } finally {
        Invoke-EmergencyScratchCleanup $upload $stageName
    }
    $after = Get-StackState
    Require ([string]$after.TargetState -ceq $Artifacts.BaselineSha256) `
            'Emergency recovery did not restore the exact baseline.'
    Require ([string](Get-ModTransactionStatus).MarkerState -ceq 'absent') `
            'Emergency recovery left a managed-mod marker.'
    Assert-StackContract $after A
}

function Invoke-ModRollback($Artifacts) {
    $status = $null
    $statusFailure = $null
    try { $status = Get-ModTransactionStatus } catch { $statusFailure = $_ }
    $state=Get-StackState
    $mode=Get-RollbackRecoveryMode ($null-ne$status) `
            $(if($null-eq$status){''}else{[string]$status.MarkerState}) `
            ([string]$state.TargetState) $Artifacts
    if($mode-ceq'CLEAN_BASELINE_STATE'){Invoke-ExactBaselineStateCleanup $Artifacts;return}
    if($mode-ceq'EMERGENCY_RESTORE'){
        $reason=if($null-eq$status){'a corrupt/unreadable marker'}else{'a missing marker'}
        Invoke-EmergencyBaselineRecovery $Artifacts $reason;return
    }
    Require ($mode-ceq'NORMAL_ROLLBACK') `
            'Rollback refused an unknown target/marker state.'
    $null = Invoke-Helper $script:TransactionScript @('-Action','Rollback','-Experiment',$Experiment,
        '-BaselineJar',$Artifacts.BaselinePath,'-ExpectedBaselineSha256',$Artifacts.BaselineSha256,
        '-Serial',$script:ResolvedSerial,'-AdbPath',$script:ResolvedAdb,'-AllowDeviceWrite')
    $after = Get-ModTransactionStatus
    Require ([string]$after.MarkerState -ceq 'absent') 'Rollback left a managed-mod marker.'
    Invoke-ExactBaselineStateCleanup $Artifacts
}

function Invoke-ModArm($Artifacts) {
    $args = @('-Action','Arm','-Experiment',$Experiment,'-BaselineJar',$Artifacts.BaselinePath,
        '-ExpectedBaselineSha256',$Artifacts.BaselineSha256,'-Serial',$script:ResolvedSerial,
        '-AdbPath',$script:ResolvedAdb,'-AllowDeviceWrite','-ExpiryMinutes','15')
    if ([string]$Artifacts.Operation -ceq 'replace') {
        $args += @('-CandidateJar',$Artifacts.CandidatePath,
                '-ExpectedCandidateSha256',$Artifacts.CandidateSha256)
    }
    $null = Invoke-Helper $script:TransactionScript $args
    $armed = Get-ModTransactionStatus
    Require ([string]$armed.MarkerState -ceq 'armed') 'Candidate transaction did not arm.'
}

function Invoke-Capture([int] $Seconds) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("qcmab-vrapi-$([guid]::NewGuid().ToString('N')).json")
    try {
        $null = Invoke-Helper $script:BenchmarkScript @('-Action','Capture','-Package',$script:Package,
            '-Serial',$script:ResolvedSerial,'-AdbPath',$script:ResolvedAdb,'-Seconds',[string]$Seconds,
            '-DynamicRefresh','-PollSeconds','1','-MinimumSampleCoveragePercent',
            [string]$script:MinimumCoveragePercent,'-OutputJson',$temp)
        Require (Test-Path -LiteralPath $temp) 'Benchmark helper produced no aggregate JSON.'
        return Get-Json $temp
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}

function Assert-Capture($Report, [string] $Label, [int] $ExpectedSeconds) {
    Require ([string]$Report.Package -ceq $script:Package -and [bool]$Report.ValidForComparison) `
            "$Label failed package/PID/focus validity."
    Require ([string]$Report.RefreshPolicy -ceq 'Dynamic' -and
            [double]$Report.SampleCoveragePercent -ge $script:MinimumCoveragePercent) `
            "$Label failed Dynamic refresh or 95-percent coverage."
    Require ([int]$Report.DurationRequestedSeconds -eq $ExpectedSeconds -and
            [double]$Report.DurationWallSeconds -ge (0.95 * $ExpectedSeconds) -and
            [double]$Report.DurationWallSeconds -le ($ExpectedSeconds + 15.0)) `
            "$Label duration is not the exact requested bounded capture."
    Require ([int]$Report.Aggregate.CpuLevelMode -eq 4 -and
            [int]$Report.Aggregate.GpuLevelMode -eq 4 -and
            [double]$Report.Aggregate.CpuLevel4Percent -ge $script:MinimumLevel4Percent -and
            [double]$Report.Aggregate.GpuLevel4Percent -ge $script:MinimumLevel4Percent) `
            "$Label failed CPU/GPU level-4 coverage."
    foreach ($name in @('MeanAppFps','P10AppFps','P95CpuAndGpuMs','MeanStalePerSecond',
            'MeanStaleAtStableRefresh','MeanDisplayRefreshHz','DisplayRefreshModeHz',
            'RefreshTransitionCount','FirstTempC','MeanTempC','LastTempC','MaxTempC')) {
        Require ($null -ne $Report.Aggregate.$name) "$Label lacks metric $name."
    }
}

function Copy-ApkIdentity($Identity) {
    [pscustomobject]@{ Package=$Identity.Package; VersionCode=$Identity.VersionCode;
        VersionName=$Identity.VersionName; BaseApkSha256=$Identity.BaseApkSha256;
        BaseApkSizeBytes=$Identity.BaseApkSizeBytes; SignerSha256=$Identity.SignerSha256;
        Verification=$Identity.Verification }
}

function Invoke-Round([ValidateSet('A','B')][string] $Condition, [int] $Pair,
        [int] $Attempt, $Artifacts) {
    Stop-LabWithRetry
    Invoke-RestoreConfigSnapshot $script:RunManifest
    Invoke-ModRollback $Artifacts
    Invoke-WorldReset
    if ($Condition -ceq 'B') { Invoke-ModArm $Artifacts }
    $launchEpoch = Start-Autoplay
    Wait-WorldReady $launchEpoch
    $before = Get-StackState
    Assert-StackContract $before $Condition
    $transactionBefore = Get-ModTransactionStatus
    Assert-TransactionContract $transactionBefore $Condition $before.OtherModsFingerprint
    Wait-Healthy $WarmupSeconds "warm-up $Condition$Pair"
    $preflight = Invoke-Capture $script:PreflightSeconds
    Assert-Capture $preflight "preflight $Condition$Pair" $script:PreflightSeconds
    $sample = Invoke-Capture $script:SampleSeconds
    Assert-Capture $sample "sample $Condition$Pair" $script:SampleSeconds
    $after = Get-StackState
    Assert-StackContract $after $Condition
    $transactionAfter = Get-ModTransactionStatus
    Assert-TransactionContract $transactionAfter $Condition $after.OtherModsFingerprint
    Require ([string]$transactionAfter.MarkerState -ceq [string]$transactionBefore.MarkerState -and
            [string]$transactionAfter.RunId -ceq [string]$transactionBefore.RunId -and
            [string]$transactionAfter.RawSha256 -ceq [string]$transactionBefore.RawSha256) `
            'Candidate transaction changed during sampling.'
    if ($Condition -ceq 'B') {
        Require ([int64]$transactionAfter.Marker.expiresAtEpochMs -eq
                [int64]$transactionBefore.Marker.expiresAtEpochMs) `
                'Candidate marker expiry changed during sampling.'
    }
    Require ([string]$before.OtherModsFingerprint -ceq [string]$after.OtherModsFingerprint -and
            [string]$before.ConfigFingerprint -ceq [string]$after.ConfigFingerprint) `
            'Fixed mod/config state changed during sampling.'
    $sample | Add-Member -NotePropertyName Protocol -NotePropertyValue ([pscustomobject]@{
        SchemaVersion=1; Series='V69_MANAGED_MOD_AB'; Experiment=$Experiment;
        Condition=$Condition; Pair=$Pair; Attempt=$Attempt; CoreSha256=$after.CoreSha256;
        VeqSha256=$after.VeqSha256; TargetState=$after.TargetState;
        OtherModsFingerprint=$after.OtherModsFingerprint; ConfigFingerprint=$after.ConfigFingerprint;
        BenchmarkRunId=$script:RunManifest.BenchmarkRunId;
        ConfigSnapshotFingerprint=$script:RunManifest.ConfigSnapshotFingerprint;
        ForeignMarkersAbsent=$after.ForeignMarkersAbsent;
        ModsMarkerState=[string]$transactionAfter.MarkerState;
        ModsRunId=if([string]::IsNullOrWhiteSpace([string]$transactionAfter.RunId)){$null}else{$transactionAfter.RunId};
        ModsExpiresAtEpochMs=if($Condition -ceq 'A'){$null}else{[int64]$transactionAfter.Marker.expiresAtEpochMs};
        ModsMarkerUnexpiredAtCapture=($Condition -ceq 'A' -or
            [int64]$transactionAfter.Marker.expiresAtEpochMs -gt
                [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds());
        ModsTransactionPolicySatisfied=$true; LabApk=Copy-ApkIdentity $script:LabApk;
        WorldMasterSha256=$script:WorldMasterSha256; WorldResetBeforeLaunch=$true;
        ColdLaunch=$true; WarmupSeconds=$WarmupSeconds; PreflightSeconds=$script:PreflightSeconds;
        SampleSeconds=$script:SampleSeconds;
        StartTemperatureC=[double]$preflight.Aggregate.LastTempC;
        CapturedAtUtc=[DateTime]::UtcNow.ToString('o') })
    return $sample
}

function Get-RefreshMap($Report) {
    $map = @{}
    foreach ($bucket in @($Report.Aggregate.DisplayRefreshDistribution)) {
        $key = ([double]$bucket.Hz).ToString('F1',[Globalization.CultureInfo]::InvariantCulture)
        $map[$key] = [double]$bucket.Percent
    }
    return $map
}

function Compare-Refresh($A, $B) {
    $left=Get-RefreshMap $A; $right=Get-RefreshMap $B
    $keys=@($left.Keys+$right.Keys|Sort-Object -Unique); $distance=0.0
    foreach($key in $keys){
        $av=if($left.ContainsKey($key)){[double]$left[$key]}else{0.0}
        $bv=if($right.ContainsKey($key)){[double]$right[$key]}else{0.0}
        $distance += [Math]::Abs($av-$bv)
    }
    $distance *= 0.5
    $mean=[Math]::Abs([double]$A.Aggregate.MeanDisplayRefreshHz-[double]$B.Aggregate.MeanDisplayRefreshHz)
    $mode=[Math]::Abs([double]$A.Aggregate.DisplayRefreshModeHz-[double]$B.Aggregate.DisplayRefreshModeHz)
    $transitions=[Math]::Abs([int]$A.Aggregate.RefreshTransitionCount-[int]$B.Aggregate.RefreshTransitionCount)
    [pscustomobject]@{ TotalVariationPercent=Round-Value $distance; MeanDeltaHz=Round-Value $mean;
        ModeDeltaHz=Round-Value $mode; TransitionCountDelta=$transitions;
        Matched=($distance -le $MaximumRefreshDistributionDistancePercent -and
            $mean -le $MaximumRefreshMeanDeltaHz -and $mode -le 0.5 -and
            $transitions -le $script:MaximumRefreshTransitionDelta) }
}

function Lower-Better($A,$B) { if([double]$A -eq 0){return 0}; 100.0*([double]$A-[double]$B)/[double]$A }
function Higher-Better($A,$B) { if([double]$A -eq 0){return 0}; 100.0*([double]$B-[double]$A)/[double]$A }

function Compare-Pair($A,$B) {
    $refresh=Compare-Refresh $A $B
    $start=[Math]::Abs([double]$A.Protocol.StartTemperatureC-[double]$B.Protocol.StartTemperatureC)
    $thermal=@('FirstTempC','MeanTempC','LastTempC','MaxTempC') | ForEach-Object {
        [Math]::Abs([double]$A.Aggregate.$_-[double]$B.Aggregate.$_)
    }
    $maxThermal=[double](($thermal|Measure-Object -Maximum).Maximum)
    $reasons=[Collections.Generic.List[string]]::new()
    if(-not $refresh.Matched){$reasons.Add('Dynamic refresh distributions differ.')}
    if($start -gt $MaximumStartTemperatureDeltaC){$reasons.Add('Start temperatures differ by more than one degree.')}
    if($maxThermal -gt $script:MaximumThermalPathDeltaC){$reasons.Add('Thermal paths differ by more than one degree.')}
    if([int]$A.Protocol.Attempt -ne [int]$B.Protocol.Attempt){$reasons.Add('Pair attempts differ.')}
    foreach($name in @('CoreSha256','VeqSha256','OtherModsFingerprint','ConfigFingerprint',
            'BenchmarkRunId','ConfigSnapshotFingerprint')){
        if([string]$A.Protocol.$name -cne [string]$B.Protocol.$name){$reasons.Add("Fixed field $name changed.")}
    }
    [pscustomobject]@{ Comparable=$reasons.Count -eq 0; InvalidReasons=$reasons.ToArray();
        Refresh=$refresh; StartTemperatureDeltaC=Round-Value $start 1;
        MaximumThermalPathDeltaC=Round-Value $maxThermal 1;
        P95ImprovementPercent=Lower-Better $A.Aggregate.P95CpuAndGpuMs $B.Aggregate.P95CpuAndGpuMs;
        StaleImprovementPercent=Lower-Better $A.Aggregate.MeanStaleAtStableRefresh $B.Aggregate.MeanStaleAtStableRefresh;
        MeanFpsChangePercent=Higher-Better $A.Aggregate.MeanAppFps $B.Aggregate.MeanAppFps;
        P10ChangePercent=Higher-Better $A.Aggregate.P10AppFps $B.Aggregate.P10AppFps }
}

function Assert-Report($Report,[string]$Condition,[int]$Pair,$Apk) {
    Require ([string]$Report.Package -ceq $script:Package -and [bool]$Report.ValidForComparison -and
            -not [bool]$Report.RawLogsPersisted) 'Retained report failed base validity.'
    Require ([int]$Report.Protocol.SchemaVersion -eq 1 -and
            [string]$Report.Protocol.Series -ceq 'V69_MANAGED_MOD_AB' -and
            [string]$Report.Protocol.Experiment -ceq $Experiment -and
            [string]$Report.Protocol.Condition -ceq $Condition -and
            [int]$Report.Protocol.Pair -eq $Pair) 'Retained report protocol identity changed.'
    Require ((Normalize-Sha ([string]$Report.Protocol.CoreSha256)) -ceq $script:ExpectedCoreSha256 -and
            (Normalize-Sha ([string]$Report.Protocol.VeqSha256)) -ceq $script:ExpectedVeqSha256 -and
            [string]$Report.Protocol.TargetState -ceq (Get-ExpectedTargetState $Condition)) `
            'Retained report stack identity changed.'
    Require ((Normalize-Sha ([string]$Report.Protocol.OtherModsFingerprint)) -ceq
            $script:ExpectedOtherModsFingerprint -and
            (Normalize-Sha ([string]$Report.Protocol.ConfigFingerprint)) -ceq
            $script:ExpectedConfigFingerprint -and
            [string]$Report.Protocol.BenchmarkRunId -ceq [string]$script:BenchmarkRunId -and
            (Normalize-Sha ([string]$Report.Protocol.ConfigSnapshotFingerprint)) -ceq
                $script:ExpectedConfigFingerprint) 'Retained report fixed fingerprint changed.'
    $markerExpected=if($Condition -ceq 'A'){'absent'}else{'consumed'}
    Require ([string]$Report.Protocol.ModsMarkerState -ceq $markerExpected -and
            [bool]$Report.Protocol.ModsTransactionPolicySatisfied -and
            [bool]$Report.Protocol.ForeignMarkersAbsent) 'Retained report transaction contract changed.'
    if($Condition -ceq 'A'){
        Require ([string]::IsNullOrWhiteSpace([string]$Report.Protocol.ModsRunId) -and
                $null -eq $Report.Protocol.ModsExpiresAtEpochMs) `
                'Baseline has candidate marker metadata.'
    }
    else{
        $capturedAt=[DateTimeOffset]::MinValue
        Require ([DateTimeOffset]::TryParse([string]$Report.Protocol.CapturedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$capturedAt)) `
                'Candidate capture timestamp is invalid.'
        Require ([string]$Report.Protocol.ModsRunId -cmatch '^[0-9a-f]{32}$' -and
            (Test-IntegerValue $Report.Protocol.ModsExpiresAtEpochMs) -and
            [int64]$Report.Protocol.ModsExpiresAtEpochMs -gt $capturedAt.ToUnixTimeMilliseconds() -and
            [bool]$Report.Protocol.ModsMarkerUnexpiredAtCapture) `
            'Candidate lacks a stable, unexpired integer marker expiry.'
    }
    Require ([string]$Report.Protocol.LabApk.BaseApkSha256 -ceq $script:ExpectedApkSha256 -and
            [string]$Report.Protocol.LabApk.BaseApkSha256 -ceq [string]$Apk.BaseApkSha256 -and
            [string]$Report.Protocol.LabApk.Package -ceq $script:Package -and
            [string]$Report.Protocol.LabApk.VersionCode -ceq $script:ExpectedVersionCode -and
            [string]$Report.Protocol.LabApk.VersionName -ceq $script:ExpectedVersionName -and
            [string]$Report.Protocol.LabApk.SignerSha256 -ceq $script:ExpectedSignerSha256 -and
            [string]$Report.Protocol.LabApk.Verification -ceq 'full-host-apk-verifier') `
            'Retained report APK identity changed.'
    Require ([string]$Report.Protocol.WorldMasterSha256 -ceq $script:WorldMasterSha256 -and
            [bool]$Report.Protocol.WorldResetBeforeLaunch -and [bool]$Report.Protocol.ColdLaunch -and
            [int]$Report.Protocol.WarmupSeconds -eq $WarmupSeconds -and
            [int]$Report.Protocol.PreflightSeconds -eq $script:PreflightSeconds -and
            [int]$Report.Protocol.SampleSeconds -eq $script:SampleSeconds) `
            'Retained report benchmark protocol changed.'
    Assert-Capture $Report 'retained report' $script:SampleSeconds
}

function Mean-Metric($Reports,[string]$Name) {
    $values=@($Reports|ForEach-Object{[double]$_.Aggregate.$Name})
    Require ($values.Count -eq 3) "Metric $Name count changed."
    [double](($values|Measure-Object -Average).Average)
}

function Get-Decision([object[]]$A,[object[]]$B,$Apk) {
    Require ($A.Count -eq 3 -and $B.Count -eq 3) 'Exactly three A/B pairs are required.'
    $pairs=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt 3;$i++){
        Assert-Report $A[$i] A ($i+1) $Apk; Assert-Report $B[$i] B ($i+1) $Apk
        $pair=Compare-Pair $A[$i] $B[$i]
        $pairs.Add([pscustomobject]@{Pair=$i+1;Comparable=$pair.Comparable;
            InvalidReasons=$pair.InvalidReasons;Refresh=$pair.Refresh;
            StartTemperatureDeltaC=$pair.StartTemperatureDeltaC;
            MaximumThermalPathDeltaC=$pair.MaximumThermalPathDeltaC;
            P95ImprovementPercent=Round-Value $pair.P95ImprovementPercent;
            StaleImprovementPercent=Round-Value $pair.StaleImprovementPercent;
            MeanFpsChangePercent=Round-Value $pair.MeanFpsChangePercent;
            P10ChangePercent=Round-Value $pair.P10ChangePercent})
    }
    $aP95=Mean-Metric $A 'P95CpuAndGpuMs';$bP95=Mean-Metric $B 'P95CpuAndGpuMs'
    $aStale=Mean-Metric $A 'MeanStaleAtStableRefresh';$bStale=Mean-Metric $B 'MeanStaleAtStableRefresh'
    $aFps=Mean-Metric $A 'MeanAppFps';$bFps=Mean-Metric $B 'MeanAppFps'
    $aP10=Mean-Metric $A 'P10AppFps';$bP10=Mean-Metric $B 'P10AppFps'
    $p95=Lower-Better $aP95 $bP95;$stale=Lower-Better $aStale $bStale
    $fps=Higher-Better $aFps $bFps;$p10=Higher-Better $aP10 $bP10
    $p95Wins=@($pairs|Where-Object{$_.P95ImprovementPercent-ge$script:P95PairFloorPercent}).Count
    $staleWins=@($pairs|Where-Object{$_.StaleImprovementPercent-ge$script:StalePairFloorPercent}).Count
    $allComparable=@($pairs|Where-Object{-not $_.Comparable}).Count -eq 0
    $pairGuard=@($pairs|Where-Object{$_.MeanFpsChangePercent-lt(-$MaximumGuardrailRegressionPercent)-or
        $_.P10ChangePercent-lt(-$MaximumGuardrailRegressionPercent)}).Count -eq 0
    $aggregateGuard=$fps-ge(-$MaximumGuardrailRegressionPercent)-and$p10-ge(-$MaximumGuardrailRegressionPercent)
    $signal=($p95-ge$script:AcceptanceP95Percent-and$p95Wins-ge$script:RequiredPairWins)-or
        ($stale-ge$script:AcceptanceStalePercent-and$staleWins-ge$script:RequiredPairWins)
    $pass=$allComparable-and$pairGuard-and$aggregateGuard-and$signal
    [pscustomobject]@{SchemaVersion=1;GeneratedAtUtc=[DateTime]::UtcNow.ToString('o');
        Package=$script:Package;Profile=$script:Profile;World=$script:World;Experiment=$Experiment;
        Order='A1-B1-B2-A2-A3-B3';PairComparisons=$pairs.ToArray();
        Aggregate=[pscustomobject]@{BaselineP95=Round-Value $aP95;CandidateP95=Round-Value $bP95;
            P95ImprovementPercent=Round-Value $p95;P95PairWins=$p95Wins;
            BaselineStableStale=Round-Value $aStale;CandidateStableStale=Round-Value $bStale;
            StaleImprovementPercent=Round-Value $stale;StalePairWins=$staleWins;
            BaselineMeanFps=Round-Value $aFps;CandidateMeanFps=Round-Value $bFps;
            MeanFpsChangePercent=Round-Value $fps;BaselineP10=Round-Value $aP10;
            CandidateP10=Round-Value $bP10;P10ChangePercent=Round-Value $p10};
        Gates=[pscustomobject]@{AllPairsComparable=$allComparable;PerPairGuardrailsPass=$pairGuard;
            AggregateGuardrailsPass=$aggregateGuard;SignalPass=$signal;AcceptancePass=$pass;
            Decision=if($pass){'ACCEPT_CANDIDATE'}else{'REJECT_OR_REPEAT'}};
        RawLogsPersisted=$false}
}

function Test-PairComparable($A,$B){(Compare-Pair $A $B).Comparable}

function Save-Excluded($Directory,[int]$Pair,[int]$Attempt,$A,$B,$Reasons){
    $dir=Join-Path $Directory 'excluded';[IO.Directory]::CreateDirectory($dir)|Out-Null
    Save-JsonAtomic $A (Join-Path $dir "pair$Pair-attempt$Attempt-A.json")
    Save-JsonAtomic $B (Join-Path $dir "pair$Pair-attempt$Attempt-B.json")
    Save-JsonAtomic ([pscustomobject]@{Pair=$Pair;Attempt=$Attempt;Reasons=$Reasons}) `
            (Join-Path $dir "pair$Pair-attempt$Attempt-reason.json")
}

function Get-ExcludedAttemptSet($Directory,[int]$Pair,$Apk) {
    Require ($Pair-ge1-and$Pair-le3) 'Excluded-attempt pair escaped the fixed protocol.'
    $dir=Join-Path $Directory 'excluded'
    if(-not(Test-Path -LiteralPath $dir)){
        return [pscustomobject]@{Pair=$Pair;CompletedAttempts=@();Records=@();
            Exhausted=$false;DynamicRefreshOnly=$false}
    }
    Require (Test-Path -LiteralPath $dir -PathType Container) `
            'Excluded-attempt path is not a directory.'
    $entries=@(Get-ChildItem -Force -LiteralPath $dir)
    foreach($entry in $entries){
        Require (-not($entry.Attributes-band[IO.FileAttributes]::ReparsePoint)-and
                -not$entry.PSIsContainer-and
                $entry.Name-cmatch'^pair([1-3])-attempt([1-3])-(A|B|reason)\.json$') `
                "Excluded-attempt directory contains an unowned entry: $($entry.Name)"
        $match=[regex]::Match($entry.Name,
                '^pair([1-3])-attempt([1-3])-(A|B|reason)\.json$',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        Require ([int]$match.Groups[2].Value-le$MaximumPairAttempts) `
                'Excluded attempt exceeds the pinned maximum.'
    }
    $records=[Collections.Generic.List[object]]::new()
    $completed=[Collections.Generic.List[int]]::new()
    for($attempt=1;$attempt-le$MaximumPairAttempts;$attempt++){
        $aPath=Join-Path $dir "pair$Pair-attempt$Attempt-A.json"
        $bPath=Join-Path $dir "pair$Pair-attempt$Attempt-B.json"
        $reasonPath=Join-Path $dir "pair$Pair-attempt$Attempt-reason.json"
        $present=@($aPath,$bPath,$reasonPath|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf})
        Require ($present.Count-eq0-or$present.Count-eq3) `
                "Excluded pair $Pair attempt $attempt is partial."
        if($present.Count-eq0){continue}
        $a=Get-Json $aPath;$b=Get-Json $bPath;$reason=Get-Json $reasonPath
        Assert-Report $a A $Pair $Apk;Assert-Report $b B $Pair $Apk
        Require ([int]$a.Protocol.Attempt-eq$attempt-and
                [int]$b.Protocol.Attempt-eq$attempt) `
                "Excluded pair $Pair attempt identity changed."
        $propertyNames=@($reason.PSObject.Properties.Name|Sort-Object)
        Require (($propertyNames-join',')-ceq'Attempt,Pair,Reasons'-and
                [int]$reason.Pair-eq$Pair-and[int]$reason.Attempt-eq$attempt) `
                "Excluded pair $Pair reason identity changed."
        $comparison=Compare-Pair $a $b
        Require (-not[bool]$comparison.Comparable) `
                "Excluded pair $Pair attempt $attempt became comparable."
        $savedReasons=@($reason.Reasons|ForEach-Object{[string]$_})
        $computedReasons=@($comparison.InvalidReasons|ForEach-Object{[string]$_})
        Require ($savedReasons.Count-eq$computedReasons.Count-and
                ($savedReasons-join"`n")-ceq($computedReasons-join"`n")) `
                "Excluded pair $Pair attempt $attempt reasons were tampered."
        $completed.Add($attempt)
        $records.Add([pscustomobject]@{Pair=$Pair;Attempt=$attempt;Reasons=$computedReasons;
            APath=$aPath;BPath=$bPath;ReasonPath=$reasonPath;Comparison=$comparison})
    }
    for($index=0;$index-lt$completed.Count;$index++){
        Require ($completed[$index]-eq($index+1)) `
                "Excluded pair $Pair attempts are not a contiguous prefix."
    }
    $exhausted=$completed.Count-eq$MaximumPairAttempts
    $dynamicOnly=$exhausted-and@($records|Where-Object{
        @($_.Reasons).Count-ne1-or[string]$_.Reasons[0]-cne'Dynamic refresh distributions differ.'}).Count-eq0
    [pscustomobject]@{Pair=$Pair;CompletedAttempts=$completed.ToArray();Records=$records.ToArray();
        Exhausted=$exhausted;DynamicRefreshOnly=$dynamicOnly}
}

function Get-ExcludedEvidence($AttemptSet,$Directory) {
    $root=[IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $evidence=[Collections.Generic.List[object]]::new()
    foreach($record in @($AttemptSet.Records)){
        foreach($kind in @('A','B','Reason')){
            $path=[IO.Path]::GetFullPath([string]$record.("${kind}Path"))
            Require ($path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase)) `
                    'Excluded evidence escaped the output directory.'
            $relative=$path.Substring($root.Length+1).Replace('\','/')
            $evidence.Add([pscustomobject]@{RelativePath=$relative;
                Sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash})
        }
    }
    return $evidence.ToArray()
}

function New-DynamicRefreshInconclusive($AttemptSet,$Directory) {
    Require ([bool]$AttemptSet.Exhausted-and[bool]$AttemptSet.DynamicRefreshOnly) `
            'Dynamic-refresh terminal decision requires exhausted refresh-only evidence.'
    [pscustomobject]@{SchemaVersion=1;GeneratedAtUtc=[DateTime]::UtcNow.ToString('o');
        Package=$script:Package;Profile=$script:Profile;World=$script:World;Experiment=$Experiment;
        Order='A1-B1-B2-A2-A3-B3';TerminalPair=[int]$AttemptSet.Pair;
        CompletedAttempts=@($AttemptSet.CompletedAttempts);ExcludedEvidence=Get-ExcludedEvidence $AttemptSet $Directory;
        PairComparisons=@($AttemptSet.Records|ForEach-Object{$_.Comparison});Aggregate=$null;
        Gates=[pscustomobject]@{AllPairsComparable=$false;PerPairGuardrailsPass=$false;
            AggregateGuardrailsPass=$false;SignalPass=$false;AcceptancePass=$false;
            Decision='INCONCLUSIVE_DYNAMIC_REFRESH'};RawLogsPersisted=$false}
}

function Assert-DynamicRefreshInconclusive($Decision,$Directory,$Apk) {
    Require ([int]$Decision.SchemaVersion-eq1-and[string]$Decision.Package-ceq$script:Package-and
            [string]$Decision.Profile-ceq$script:Profile-and[string]$Decision.World-ceq$script:World-and
            [string]$Decision.Experiment-ceq$Experiment-and
            [string]$Decision.Order-ceq'A1-B1-B2-A2-A3-B3'-and
            [int]$Decision.TerminalPair-ge1-and[int]$Decision.TerminalPair-le3-and
            -not[bool]$Decision.RawLogsPersisted) `
            'Inconclusive comparison identity changed.'
    Require ([string]$Decision.Gates.Decision-ceq'INCONCLUSIVE_DYNAMIC_REFRESH'-and
            -not[bool]$Decision.Gates.AcceptancePass-and-not[bool]$Decision.Gates.AllPairsComparable-and
            -not[bool]$Decision.Gates.PerPairGuardrailsPass-and
            -not[bool]$Decision.Gates.AggregateGuardrailsPass-and-not[bool]$Decision.Gates.SignalPass) `
            'Inconclusive comparison was changed into an acceptance path.'
    $set=Get-ExcludedAttemptSet $Directory ([int]$Decision.TerminalPair) $Apk
    Require ([bool]$set.Exhausted-and[bool]$set.DynamicRefreshOnly-and
            (@($Decision.CompletedAttempts)-join',')-ceq(@($set.CompletedAttempts)-join',')) `
            'Inconclusive comparison lacks exact exhausted refresh-only attempts.'
    $expectedComparisons=@($set.Records|ForEach-Object{$_.Comparison})
    $actualComparisons=@($Decision.PairComparisons)
    Require ($null-eq$Decision.Aggregate-and
            $actualComparisons.Count-eq$expectedComparisons.Count-and
            (($actualComparisons|ConvertTo-Json -Depth 10 -Compress)-ceq
                ($expectedComparisons|ConvertTo-Json -Depth 10 -Compress))) `
            'Inconclusive pair-comparison evidence changed.'
    $expected=@(Get-ExcludedEvidence $set $Directory)
    $actual=@($Decision.ExcludedEvidence)
    Require ($actual.Count-eq$expected.Count) 'Inconclusive evidence count changed.'
    for($i=0;$i-lt$expected.Count;$i++){
        Require ([string]$actual[$i].RelativePath-ceq[string]$expected[$i].RelativePath-and
                (Normalize-Sha ([string]$actual[$i].Sha256))-ceq
                    (Normalize-Sha ([string]$expected[$i].Sha256))) `
                'Inconclusive evidence path or hash changed.'
    }
    for($pair=([int]$Decision.TerminalPair+1);$pair-le3;$pair++){
        Require (-not(Test-Path -LiteralPath (Join-Path $Directory "A$pair.json"))-and
                -not(Test-Path -LiteralPath (Join-Path $Directory "B$pair.json"))) `
                'Pair artifacts exist after the terminal inconclusive pair.'
        $later=Get-ExcludedAttemptSet $Directory $pair $Apk
        Require (@($later.CompletedAttempts).Count-eq0) `
                'Excluded attempts exist after the terminal inconclusive pair.'
    }
    return $set
}

function Get-CanonicalComparisonProof($Value) {
    $json=$Value|ConvertTo-Json -Depth 14 -Compress
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}
    finally{$sha.Dispose()}
    [pscustomobject]@{Json=$json;Sha256=$hash}
}

function Assert-PersistedComparison($Decision,$Directory,$Apk) {
    $generated=[DateTimeOffset]::MinValue
    Require ([DateTimeOffset]::TryParse([string]$Decision.GeneratedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$generated)) `
            'Persisted comparison timestamp is invalid.'
    $kind=[string]$Decision.Gates.Decision
    if($kind-ceq'INCONCLUSIVE_DYNAMIC_REFRESH'){
        $set=Assert-DynamicRefreshInconclusive $Decision $Directory $Apk
        $expected=New-DynamicRefreshInconclusive $set $Directory
    }elseif($kind-ceq'ACCEPT_CANDIDATE'-or$kind-ceq'REJECT_OR_REPEAT'){
        $expected=Get-ReportSet $Directory $Apk
        Require ([string]$expected.Gates.Decision-ceq$kind) `
                'Persisted normal comparison decision differs from the retained reports.'
    }else{throw 'Persisted comparison has an unknown decision.'}
    # Preserve ConvertFrom-Json's runtime timestamp type (PS 7 may materialize
    # ISO timestamps as DateTime while Windows PowerShell keeps a string) so
    # the reconstructed canonical document is identical on both engines.
    $expected.GeneratedAtUtc=$Decision.GeneratedAtUtc
    $actualProof=Get-CanonicalComparisonProof $Decision
    $expectedProof=Get-CanonicalComparisonProof $expected
    Require ([string]$actualProof.Json-ceq[string]$expectedProof.Json-and
            [string]$actualProof.Sha256-ceq[string]$expectedProof.Sha256) `
            ("Persisted comparison differs from its canonical retained-report reconstruction " +
            "(actual=$($actualProof.Sha256), expected=$($expectedProof.Sha256)).")
    return $Decision
}

function Invoke-Pair([int]$Pair,$Artifacts,$Directory){
    $order=if($Pair-eq2){@('B','A')}else{@('A','B')}
    $existing=Get-ExcludedAttemptSet $Directory $Pair $script:LabApk
    for($attempt=1;$attempt-le$MaximumPairAttempts;$attempt++){
        if(@($existing.CompletedAttempts)-contains$attempt){continue}
        $reports=@{}
        foreach($condition in $order){
            if($InterRoundCooldownSeconds-gt0){Start-Sleep -Seconds $InterRoundCooldownSeconds}
            $reports[$condition]=Invoke-Round $condition $Pair $attempt $Artifacts
        }
        $comparison=Compare-Pair $reports.A $reports.B
        if($comparison.Comparable){
            Save-JsonAtomic $reports.A (Join-Path $Directory "A$Pair.json")
            Save-JsonAtomic $reports.B (Join-Path $Directory "B$Pair.json")
            return [pscustomobject]@{Status='COMPARABLE';Pair=$Pair}
        }
        Save-Excluded $Directory $Pair $attempt $reports.A $reports.B $comparison.InvalidReasons
        $existing=Get-ExcludedAttemptSet $Directory $Pair $script:LabApk
    }
    $terminal=Get-ExcludedAttemptSet $Directory $Pair $script:LabApk
    if([bool]$terminal.Exhausted-and[bool]$terminal.DynamicRefreshOnly){
        return [pscustomobject]@{Status='INCONCLUSIVE_DYNAMIC_REFRESH';Pair=$Pair;AttemptSet=$terminal}
    }
    throw "Pair $Pair failed all bounded comparability attempts for non-refresh reasons."
}

function New-Manifest($Artifacts) {
    [pscustomobject]@{SchemaVersion=1;Package=$script:Package;Profile=$script:Profile;
        World=$script:World;WorldMasterSha256=$script:WorldMasterSha256;Experiment=$Experiment;
        BenchmarkStateId=$script:BenchmarkStateId;BenchmarkRunId=$script:BenchmarkRunId;
        ConfigSnapshotState='pending';ConfigSnapshotFingerprint=$script:ExpectedConfigFingerprint;
        Operation=$Artifacts.Operation;Target=$Artifacts.Target;
        BaselineSha256=$Artifacts.BaselineSha256;CandidateSha256=$Artifacts.CandidateSha256;
        CoreSha256=$script:ExpectedCoreSha256;VeqSha256=$script:ExpectedVeqSha256;
        OtherModsFingerprint=$script:ExpectedOtherModsFingerprint;
        ConfigFingerprint=$script:ExpectedConfigFingerprint;LabApk=Copy-ApkIdentity $script:LabApk;
        Order=@('A1','B1','B2','A2','A3','B3');WarmupSeconds=$WarmupSeconds;
        PreflightSeconds=$script:PreflightSeconds;SampleSeconds=$script:SampleSeconds;
        MaximumPairAttempts=$MaximumPairAttempts;InterRoundCooldownSeconds=$InterRoundCooldownSeconds;
        MaximumStartTemperatureDeltaC=$MaximumStartTemperatureDeltaC;
        MaximumThermalPathDeltaC=$script:MaximumThermalPathDeltaC;
        MaximumRefreshDistributionDistancePercent=$MaximumRefreshDistributionDistancePercent;
        MaximumRefreshMeanDeltaHz=$MaximumRefreshMeanDeltaHz;
        MaximumRefreshTransitionDelta=$script:MaximumRefreshTransitionDelta;
        MinimumCoveragePercent=$script:MinimumCoveragePercent;
        MinimumCpuGpuLevel4Percent=$script:MinimumLevel4Percent;
        P95AcceptancePercent=$script:AcceptanceP95Percent;
        StaleAcceptancePercent=$script:AcceptanceStalePercent;
        MaximumGuardrailRegressionPercent=$MaximumGuardrailRegressionPercent;
        CandidateMarkerState='consumed';InitialAndFinalMarkerState='absent';
        OtherCanaryMarkersRequiredAbsent=$true;OneSelectedExperimentOnly=$true;
        QgoPolicy='Dynamic CPU4/GPU4; app requests neither refresh nor performance hint';
        SerialPersisted=$false;RawLogsPersisted=$false}
}

function Assert-Manifest($Manifest) {
    Require ([int]$Manifest.SchemaVersion-eq1-and[string]$Manifest.Package-ceq$script:Package-and
            [string]$Manifest.Profile-ceq$script:Profile-and[string]$Manifest.World-ceq$script:World) `
            'Manifest identity changed.'
    Require ([string]$Manifest.BenchmarkStateId-ceq$script:BenchmarkStateId-and
            [string]$Manifest.BenchmarkRunId-cmatch'^[0-9a-f]{32}$'-and
            ([string]$Manifest.ConfigSnapshotState-ceq'pending'-or
                [string]$Manifest.ConfigSnapshotState-ceq'ready')-and
            (Normalize-Sha ([string]$Manifest.ConfigSnapshotFingerprint))-ceq
                $script:ExpectedConfigFingerprint) `
            'Manifest benchmark config snapshot contract changed.'
    Require ([string]$Manifest.Experiment-ceq$Experiment-and
            [string]$Manifest.Operation-ceq[string]$script:Selected.operation-and
            [string]$Manifest.Target-ceq[string]$script:Selected.target) 'Manifest experiment changed.'
    Require ((Normalize-Sha ([string]$Manifest.BaselineSha256))-ceq
                (Normalize-Sha ([string]$script:Selected.baseline.sha256))-and
            (Normalize-Sha ([string]$Manifest.CandidateSha256))-ceq
                (Normalize-Sha ([string]$script:Selected.candidate.sha256))) `
            'Manifest artifact hashes changed.'
    Require ((Normalize-Sha ([string]$Manifest.CoreSha256))-ceq$script:ExpectedCoreSha256-and
            (Normalize-Sha ([string]$Manifest.VeqSha256))-ceq$script:ExpectedVeqSha256-and
            (Normalize-Sha ([string]$Manifest.OtherModsFingerprint))-ceq$script:ExpectedOtherModsFingerprint-and
            (Normalize-Sha ([string]$Manifest.ConfigFingerprint))-ceq$script:ExpectedConfigFingerprint) `
            'Manifest fixed-stack fingerprints changed.'
    Require ([string]$Manifest.LabApk.Package-ceq$script:Package-and
            [string]$Manifest.LabApk.BaseApkSha256-ceq$script:ExpectedApkSha256-and
            [string]$Manifest.LabApk.SignerSha256-ceq$script:ExpectedSignerSha256-and
            [string]$Manifest.LabApk.VersionCode-ceq$script:ExpectedVersionCode-and
            [string]$Manifest.LabApk.VersionName-ceq$script:ExpectedVersionName-and
            [string]$Manifest.LabApk.Verification-ceq'full-host-apk-verifier') `
            'Manifest APK identity changed.'
    Require ((@($Manifest.Order)-join '-')-ceq'A1-B1-B2-A2-A3-B3'-and
            [int]$Manifest.WarmupSeconds-eq$WarmupSeconds-and
            [int]$Manifest.PreflightSeconds-eq10-and[int]$Manifest.SampleSeconds-eq60) `
            'Manifest timing/order changed.'
    Require ([int]$Manifest.MaximumPairAttempts-eq$MaximumPairAttempts-and
            [int]$Manifest.InterRoundCooldownSeconds-eq$InterRoundCooldownSeconds) `
            'Manifest retry/cooldown protocol changed.'
    Require ([double]$Manifest.MaximumStartTemperatureDeltaC-eq$MaximumStartTemperatureDeltaC-and
            [double]$Manifest.MaximumThermalPathDeltaC-eq$script:MaximumThermalPathDeltaC-and
            [double]$Manifest.MaximumRefreshDistributionDistancePercent-eq
                $MaximumRefreshDistributionDistancePercent-and
            [double]$Manifest.MaximumRefreshMeanDeltaHz-eq$MaximumRefreshMeanDeltaHz-and
            [int]$Manifest.MaximumRefreshTransitionDelta-eq$script:MaximumRefreshTransitionDelta-and
            [double]$Manifest.MinimumCoveragePercent-eq$script:MinimumCoveragePercent-and
            [double]$Manifest.MinimumCpuGpuLevel4Percent-eq$script:MinimumLevel4Percent-and
            [double]$Manifest.P95AcceptancePercent-eq$script:AcceptanceP95Percent-and
            [double]$Manifest.StaleAcceptancePercent-eq$script:AcceptanceStalePercent-and
            [double]$Manifest.MaximumGuardrailRegressionPercent-eq$MaximumGuardrailRegressionPercent) `
            'Manifest quality thresholds changed.'
    Require ([string]$Manifest.CandidateMarkerState-ceq'consumed'-and
            [string]$Manifest.InitialAndFinalMarkerState-ceq'absent'-and
            [bool]$Manifest.OtherCanaryMarkersRequiredAbsent-and
            [bool]$Manifest.OneSelectedExperimentOnly) 'Manifest transaction policy changed.'
    Require ([string]$Manifest.WorldMasterSha256-ceq$script:WorldMasterSha256-and
            [string]$Manifest.QgoPolicy-ceq
                'Dynamic CPU4/GPU4; app requests neither refresh nor performance hint'-and
            -not [bool]$Manifest.SerialPersisted-and-not [bool]$Manifest.RawLogsPersisted) `
            'Manifest world/QGO/privacy contract changed.'
}

function Acquire-Lock($Directory){
    [IO.Directory]::CreateDirectory($Directory)|Out-Null
    $benchmarkRoot=[IO.Path]::GetFullPath((Join-Path $script:WorkspaceRoot 'artifacts\benchmarks'))
    [IO.Directory]::CreateDirectory($benchmarkRoot)|Out-Null
    $path=Join-Path $benchmarkRoot '.quest-v69-managed-mods-device.lock'
    try{
        $script:RunLockStream=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write,[IO.FileShare]::None)
        $script:RunLockStream.SetLength(0)
        $bytes=[Text.Encoding]::UTF8.GetBytes("host lock; device serial omitted`n")
        $script:RunLockStream.Write($bytes,0,$bytes.Length);$script:RunLockStream.Flush($true)
        return $path
    }catch{throw 'Another managed-mod A/B experiment already owns the global Lab lock.'}
}

function Release-Lock($Path){
    if($null-ne$script:RunLockStream){$script:RunLockStream.Dispose();$script:RunLockStream=$null}
    if(Test-Path -LiteralPath $Path){[IO.File]::Delete($Path)}
}

function Get-ReportSet($Directory,$Apk){
    $a=@();$b=@()
    for($i=1;$i-le3;$i++){
        foreach($c in @('A','B')){Require (Test-Path -LiteralPath (Join-Path $Directory "$c$i.json")) "Missing $c$i.json."}
        $a+=Get-Json (Join-Path $Directory "A$i.json");$b+=Get-Json (Join-Path $Directory "B$i.json")
    }
    Get-Decision $a $b $Apk
}

function New-SyntheticApk {
    [pscustomobject]@{Package=$script:Package;VersionCode=$script:ExpectedVersionCode;
        VersionName=$script:ExpectedVersionName;BaseApkSha256=$script:ExpectedApkSha256;
        BaseApkSizeBytes=123456789;SignerSha256=$script:ExpectedSignerSha256;
        Verification='full-host-apk-verifier'}
}

function New-SyntheticReport([string]$Condition,[int]$Pair,[double]$Fps,[double]$P10,
        [double]$Stale,[double]$P95,[double]$Temp,[double]$Hz=72.0){
    [pscustomobject]@{Package=$script:Package;ValidForComparison=$true;RawLogsPersisted=$false;
        RefreshPolicy='Dynamic';SampleCoveragePercent=100.0;DurationRequestedSeconds=60;
        DurationWallSeconds=60.2;
        Aggregate=[pscustomobject]@{MeanAppFps=$Fps;P10AppFps=$P10;MeanStalePerSecond=$Stale;
            MeanStaleAtStableRefresh=$Stale;P95CpuAndGpuMs=$P95;CpuLevelMode=4;GpuLevelMode=4;
            CpuLevel4Percent=100.0;GpuLevel4Percent=100.0;MeanDisplayRefreshHz=$Hz;
            DisplayRefreshModeHz=$Hz;DisplayRefreshDistribution=@([pscustomobject]@{Hz=$Hz;Count=60;Percent=100.0});
            RefreshTransitionCount=0;FirstTempC=$Temp;MeanTempC=$Temp;LastTempC=$Temp;MaxTempC=$Temp};
        Protocol=[pscustomobject]@{SchemaVersion=1;Series='V69_MANAGED_MOD_AB';Experiment=$Experiment;
            Condition=$Condition;Pair=$Pair;Attempt=1;CoreSha256=$script:ExpectedCoreSha256;
            VeqSha256=$script:ExpectedVeqSha256;TargetState=Get-ExpectedTargetState $Condition;
            OtherModsFingerprint=$script:ExpectedOtherModsFingerprint;
            ConfigFingerprint=$script:ExpectedConfigFingerprint;
            BenchmarkRunId=$script:BenchmarkRunId;
            ConfigSnapshotFingerprint=$script:ExpectedConfigFingerprint;ForeignMarkersAbsent=$true;
            ModsMarkerState=if($Condition-ceq'A'){'absent'}else{'consumed'};
            ModsRunId=if($Condition-ceq'A'){$null}else{'0123456789abcdef0123456789abcdef'};
            ModsExpiresAtEpochMs=if($Condition-ceq'A'){$null}else{1900000000000L};
            ModsMarkerUnexpiredAtCapture=$true;
            ModsTransactionPolicySatisfied=$true;LabApk=Copy-ApkIdentity $script:LabApk;
            WorldMasterSha256=$script:WorldMasterSha256;WorldResetBeforeLaunch=$true;
            ColdLaunch=$true;WarmupSeconds=$WarmupSeconds;PreflightSeconds=10;SampleSeconds=60;
            StartTemperatureC=$Temp;CapturedAtUtc=[DateTime]::UtcNow.ToString('o')}}
}

function Invoke-SelfTest {
    $before=$script:DeviceInvocationCount
    $null=Resolve-HostContract
    Invoke-OfflineHelperContracts
    $script:ExpectedOtherModsFingerprint=('A'*64);$script:ExpectedConfigFingerprint=('B'*64)
    $script:LabApk=New-SyntheticApk
    $source=Get-Content -Raw -LiteralPath $PSCommandPath
    foreach($forbidden in @('pm'+' clear','unin'+'stall','su '+'-c')){
        Require (-not $source.Contains($forbidden)) "Forbidden operation $forbidden appeared."
    }
    foreach($requiredRecoveryToken in @(
        '! pidof $(ConvertTo-ShLiteral $script:Package)',
        'test "`$game" = "`$files/instances/$script:Profile"',
        'test "`$(realpath "`$state")" = "`$game/$stateRelative"',
        'mv "`$stage" "`$target"',
        'function Invoke-ExactBaselineStateCleanup',
        'trap cleanup_stage EXIT HUP INT TERM',
        "trap 'recover_work' EXIT HUP INT TERM",
        'trap cleanup_emergency EXIT HUP INT TERM',
        'for($attempt=1;$attempt-le3;$attempt++)',
        'config-initial:',
        'mod-initial:',
        'config-retry:',
        'mod-retry:',
        'PRESERVE_READY_FOR_RESUME',
        'CLEAN_AFTER_COMPLETE',
        'Invoke-CleanupEmergencyStageNamespace',
        'EMERGENCY_STAGE_NAMESPACE_CLEAN',
        'INCONCLUSIVE_DYNAMIC_REFRESH',
        'Get-ExcludedAttemptSet',
        'Invoke-RestoreConfigSnapshot $script:RunManifest',
        'A prior benchmark config transaction exists',
        'Emergency recovery is allowed only from the exact candidate/ABSENT state.')) {
        Require ($source.Contains($requiredRecoveryToken)) `
                "Emergency recovery source contract lost token: $requiredRecoveryToken"
    }
    Require (-not $source.Contains('rm '+'-rf')) 'Emergency recovery introduced recursive deletion.'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
    Require ($errors.Count-eq0) ('PowerShell parser errors: '+(($errors|ForEach-Object{$_.Message})-join'; '))
    $parameters=@($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
    Require ($parameters-cnotcontains'Package'-and$parameters-cnotcontains'Profile') `
            'Package/profile override is exposed.'
    $baseline=[pscustomobject]@{MarkerState='absent';RunId=$null;Marker=$null}
    Assert-TransactionContract $baseline A $script:ExpectedOtherModsFingerprint
    $candidateMarker=[pscustomobject]@{schemaVersion=2;harnessId=$script:ModsHarnessId;state='consumed';
        packageName=$script:Package;profile=$script:Profile;target=[string]$script:Selected.target;
        runId='0123456789abcdef0123456789abcdef';baselineSha256=[string]$script:Selected.baseline.sha256;
        candidateSha256=[string]$script:Selected.candidate.sha256;
        baselineSizeBytes=[int64]$script:Selected.baseline.sizeBytes;
        candidateSizeBytes=[int64]$script:Selected.candidate.sizeBytes;
        fabricId=[string]$script:Selected.candidate.fabricId;
        fabricVersion=[string]$script:Selected.candidate.fabricVersion;
        minecraftDependency=[string]$script:Selected.candidate.minecraftDependency;
        javaDependency=[string]$script:Selected.candidate.javaDependency;
        otherModsFingerprintSha256=$script:ExpectedOtherModsFingerprint;openXrCopyBatchMode='OFF';
        expiresAtEpochMs=1900000000000L;maxLaunches=1}
    $candidate=[pscustomobject]@{MarkerState='consumed';RunId=$candidateMarker.runId;Marker=$candidateMarker}
    Assert-TransactionContract $candidate B $script:ExpectedOtherModsFingerprint
    $syntheticArtifacts=[pscustomobject]@{
        Operation=[string]$script:Selected.operation
        Target=[string]$script:Selected.target
        BaselineSha256=Normalize-Sha ([string]$script:Selected.baseline.sha256)
        CandidateSha256=Normalize-Sha ([string]$script:Selected.candidate.sha256)
    }
    $emergencyAllowed=if($syntheticArtifacts.Operation-ceq'replace'){
        $syntheticArtifacts.CandidateSha256
    }else{'ABSENT'}
    Require (Test-EmergencyStateAllowed $syntheticArtifacts $emergencyAllowed) `
            'Exact candidate/ABSENT emergency state was rejected.'
    Require (-not (Test-EmergencyStateAllowed $syntheticArtifacts $syntheticArtifacts.BaselineSha256)) `
            'Emergency recovery accepted an already-baseline state.'
    Require (-not (Test-EmergencyStateAllowed $syntheticArtifacts ('C'*64))) `
            'Emergency recovery accepted an unknown target hash.'
    if($syntheticArtifacts.Operation-ceq'replace'){
        Require (-not (Test-EmergencyStateAllowed $syntheticArtifacts 'ABSENT')) `
                'Replace recovery accepted an absent target.'
    }else{
        Require (-not (Test-EmergencyStateAllowed $syntheticArtifacts $syntheticArtifacts.CandidateSha256)) `
                'Disable recovery accepted a synthetic candidate hash.'
    }
    Require ((Get-RollbackRecoveryMode $false '' $syntheticArtifacts.BaselineSha256 $syntheticArtifacts)-ceq
            'CLEAN_BASELINE_STATE') 'Corrupt-marker exact baseline did not select owned-state cleanup.'
    Require ((Get-RollbackRecoveryMode $true 'absent' $syntheticArtifacts.BaselineSha256 $syntheticArtifacts)-ceq
            'CLEAN_BASELINE_STATE') 'Marker-absent exact baseline did not select owned-state cleanup.'
    Require ((Get-RollbackRecoveryMode $false '' $emergencyAllowed $syntheticArtifacts)-ceq
            'EMERGENCY_RESTORE') 'Corrupt-marker exact candidate/ABSENT did not select emergency restore.'
    Require ((Get-RollbackRecoveryMode $true 'absent' ('C'*64) $syntheticArtifacts)-ceq'REFUSE') `
            'Unknown target did not fail closed.'
    Require ((Get-RollbackRecoveryMode $true 'consumed' $emergencyAllowed $syntheticArtifacts)-ceq
            'NORMAL_ROLLBACK') 'Readable consumed marker did not select audited rollback.'
    $script:BenchmarkRunId='fedcba9876543210fedcba9876543210'
    $manifest=New-Manifest $syntheticArtifacts
    Assert-Manifest $manifest
    foreach($shellCase in @(
        @('config snapshot create',(Invoke-CreateConfigSnapshot $manifest -BuildOnly)),
        @('interrupted config restore',(Invoke-RestoreConfigSnapshot $manifest -BuildOnly)),
        @('config snapshot cleanup',(Invoke-CleanupConfigSnapshot $manifest -BuildOnly)),
        @('exact baseline state cleanup',(Invoke-ExactBaselineStateCleanup $syntheticArtifacts -BuildOnly)),
        @('emergency atomic restore',(Invoke-EmergencyBaselineRecovery $syntheticArtifacts 'selftest' -BuildOnly)),
        @('emergency bounded scratch cleanup',(Invoke-EmergencyScratchCleanup `
            '/data/local/tmp/qcmab-emergency-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-baseline.upload' `
            '.mods-ab-emergency-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tmp' -BuildOnly)),
        @('emergency stage namespace cleanup',(Invoke-CleanupEmergencyStageNamespace -BuildOnly)))){
        Assert-PosixShellSyntax ([string]$shellCase[1]) ([string]$shellCase[0])
    }
    Require ((Get-FinalConfigDisposition $false $false $true)-ceq
            'PRESERVE_READY_FOR_RESUME') `
            'Pair-exhaustion failure would delete the ready config snapshot.'
    Require ((Get-FinalConfigDisposition $false $true $true)-ceq
            'PRESERVE_READY_FOR_RESUME') `
            'An incomplete run with a comparison artifact would delete the resume snapshot.'
    Require ((Get-FinalConfigDisposition $true $false $true)-ceq
            'PRESERVE_READY_FOR_RESUME') `
            'A run without a persisted comparison would delete the resume snapshot.'
    Require ((Get-FinalConfigDisposition $true $true $true)-ceq
            'CLEAN_AFTER_COMPLETE') `
            'A completed resumed run would not permanently clean its config snapshot.'
    Require ((Get-FinalConfigDisposition $false $false $false)-ceq'NONE') `
            'A pre-snapshot failure acquired config cleanup ownership.'
    foreach($mutation in @(
        @('Operation','foreign-operation'),@('Target','mods/Foreign.jar'),
        @('BaselineSha256',('C'*64)),@('CandidateSha256',('D'*64)),
        @('MaximumPairAttempts',($MaximumPairAttempts+1)),
        @('InterRoundCooldownSeconds',($InterRoundCooldownSeconds+1)),
        @('WorldMasterSha256',('E'*64)),@('QgoPolicy','unlocked'),
        @('BenchmarkRunId','foreign'),@('ConfigSnapshotFingerprint',('F'*64)),
        @('SerialPersisted',$true),@('RawLogsPersisted',$true))) {
        $changed=($manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json)
        $changed.($mutation[0])=$mutation[1]
        $manifestRejected=$false
        try{Assert-Manifest $changed}catch{$manifestRejected=$true}
        Require $manifestRejected "Manifest mutation $($mutation[0]) was accepted."
    }
    $snapshotStatus=[pscustomobject]@{State='present';StageNames=@();
        RestoreWorkNames=@("restore-$($manifest.BenchmarkRunId)");
        RunId=$manifest.BenchmarkRunId;ConfigFingerprint=$manifest.ConfigSnapshotFingerprint;
        Contract=[pscustomobject]@{schema='1';package=$script:Package;profile=$script:Profile;
            runId=$manifest.BenchmarkRunId;configFingerprint=$manifest.ConfigSnapshotFingerprint}}
    Assert-ConfigSnapshotContract $snapshotStatus $manifest -AllowInterruptedRestore
    $interruptedRejected=$false
    try{Assert-ConfigSnapshotContract $snapshotStatus $manifest}catch{$interruptedRejected=$true}
    Require $interruptedRejected 'Interrupted restore work was treated as a clean snapshot.'
    $foreignWork=$snapshotStatus.PSObject.Copy();$foreignWork.RestoreWorkNames=@('restore-foreign')
    $foreignRejected=$false
    try{Assert-ConfigSnapshotContract $foreignWork $manifest -AllowInterruptedRestore}catch{$foreignRejected=$true}
    Require $foreignRejected 'Foreign interrupted restore work was accepted.'
    $startupState=[pscustomobject]@{CoreSha256=$script:ExpectedCoreSha256;
        VeqSha256=$script:ExpectedVeqSha256;TargetState=$syntheticArtifacts.BaselineSha256;
        OtherModsFingerprint=$script:ExpectedOtherModsFingerprint;ConfigFingerprint=('C'*64);
        ForeignMarkersAbsent=$true}
    $driftRejected=$false;try{Assert-StackContract $startupState A}catch{$driftRejected=$true}
    Require $driftRejected 'Startup-written config drift was accepted as canonical.'
    $cleanBaseline=$startupState.PSObject.Copy();$cleanBaseline.ConfigFingerprint=$script:ExpectedConfigFingerprint
    Assert-StackContract $cleanBaseline A
    $candidateBaseline=$cleanBaseline.PSObject.Copy();$candidateBaseline.TargetState=$emergencyAllowed
    $candidateCleanupRejected=$false
    try{Assert-StackContract $candidateBaseline A}catch{$candidateCleanupRejected=$true}
    Require $candidateCleanupRejected 'Exact baseline cleanup policy accepted a candidate/ABSENT target.'
    $wrongMarker=$candidateMarker.PSObject.Copy();$wrongMarker.state='armed'
    $wrongRejected=$false;try{Assert-TransactionContract ([pscustomobject]@{
        MarkerState='armed';RunId=$wrongMarker.runId;Marker=$wrongMarker}) B `
        $script:ExpectedOtherModsFingerprint}catch{$wrongRejected=$true}
    Require $wrongRejected 'An armed candidate marker was accepted after launch.'
    $a=@();$b=@();for($i=1;$i-le3;$i++){$a+=New-SyntheticReport A $i 70 68 5 15 42;$b+=New-SyntheticReport B $i 70.2 68.2 4 14.4 42}
    $decision=Get-Decision $a $b $script:LabApk
    Require ([bool]$decision.Gates.AcceptancePass) 'Synthetic winning candidate was not accepted.'
    $badDuration=$b[0].PSObject.Copy();$badDuration.DurationRequestedSeconds=59
    $rejected=$false;try{Assert-Report $badDuration B 1 $script:LabApk}catch{$rejected=$true}
    Require $rejected 'A retained candidate report not bound to 60 seconds was accepted.'
    $expired=$b[0].PSObject.Copy();$expired.Protocol=$b[0].Protocol.PSObject.Copy()
    $expired.Protocol.ModsExpiresAtEpochMs=1L
    $rejected=$false;try{Assert-Report $expired B 1 $script:LabApk}catch{$rejected=$true}
    Require $rejected 'A candidate marker expired before capture was accepted.'
    $weakLevels=$b[0].PSObject.Copy();$weakLevels.Aggregate=$b[0].Aggregate.PSObject.Copy();
    $weakLevels.Aggregate.CpuLevel4Percent=94.9
    # Replace only the report under test; avoid mutating the winning fixture.
    $weakSet=@($weakLevels,$b[1],$b[2]);$rejected=$false
    try{Get-Decision $a $weakSet $script:LabApk|Out-Null}catch{$rejected=$true}
    Require $rejected 'Sub-95-percent CPU level coverage was accepted.'
    $refresh=@();for($i=1;$i-le3;$i++){$refresh+=New-SyntheticReport B $i 70.2 68.2 4 14.4 42 73.0}
    Require (-not [bool](Get-Decision $a $refresh $script:LabApk).Gates.AcceptancePass) `
            'Mismatched Dynamic refresh was accepted.'
    $excludedRoot=Join-Path ([IO.Path]::GetTempPath()) `
            "qcmab-excluded-selftest-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($excludedRoot)|Out-Null
    try{
        for($attempt=1;$attempt-le$MaximumPairAttempts;$attempt++){
            $ea=New-SyntheticReport A 1 70 68 5 15 42 72.0
            $eb=New-SyntheticReport B 1 70.2 68.2 4 14.4 42 73.0
            $ea.Protocol.Attempt=$attempt;$eb.Protocol.Attempt=$attempt
            $excludedComparison=Compare-Pair $ea $eb
            Require (-not$excludedComparison.Comparable-and
                    @($excludedComparison.InvalidReasons).Count-eq1-and
                    [string]$excludedComparison.InvalidReasons[0]-ceq
                        'Dynamic refresh distributions differ.') `
                    'Synthetic excluded attempt is not refresh-only.'
            Save-Excluded $excludedRoot 1 $attempt $ea $eb $excludedComparison.InvalidReasons
        }
        $exhausted=Get-ExcludedAttemptSet $excludedRoot 1 $script:LabApk
        Require ([bool]$exhausted.Exhausted-and[bool]$exhausted.DynamicRefreshOnly-and
                @($exhausted.CompletedAttempts).Count-eq$MaximumPairAttempts) `
                'Pair exhaustion was not classified as refresh-only inconclusive.'
        $resumed=Get-ExcludedAttemptSet $excludedRoot 1 $script:LabApk
        Require ((@($resumed.CompletedAttempts)-join',')-ceq'1,2,3') `
                'Resume did not recognize and skip the complete excluded attempts.'
        $terminal=New-DynamicRefreshInconclusive $resumed $excludedRoot
        Require ([string]$terminal.Gates.Decision-ceq'INCONCLUSIVE_DYNAMIC_REFRESH'-and
                -not[bool]$terminal.Gates.AcceptancePass) `
                'Refresh-only exhaustion entered an acceptance path.'
        $null=Assert-DynamicRefreshInconclusive $terminal $excludedRoot $script:LabApk
        $interruptedComparisonPath=Join-Path $excludedRoot 'comparison.json'
        Save-JsonAtomic $terminal $interruptedComparisonPath
        $interruptedPersisted=Get-Json $interruptedComparisonPath
        $resumedPersisted=Assert-PersistedComparison $interruptedPersisted $excludedRoot $script:LabApk
        Require ([string]$resumedPersisted.Gates.Decision-ceq'INCONCLUSIVE_DYNAMIC_REFRESH'-and
                -not[bool]$resumedPersisted.Gates.AcceptancePass-and
                (Get-CanonicalComparisonProof $resumedPersisted).Sha256-ceq
                    (Get-CanonicalComparisonProof $interruptedPersisted).Sha256) `
                'Resume did not reuse the exact comparison written before completion flags.'
        $tamperedPersisted=$interruptedPersisted|ConvertTo-Json -Depth 14|ConvertFrom-Json
        $tamperedPersisted.PairComparisons[0].Refresh.MeanDeltaHz=999.0
        $persistedTamperRejected=$false
        try{Assert-PersistedComparison $tamperedPersisted $excludedRoot $script:LabApk|Out-Null}
        catch{$persistedTamperRejected=$true}
        Require $persistedTamperRejected `
                'Resume accepted a comparison that differs from canonical retained evidence.'
        $duplicateRejected=$false
        try{Save-Excluded $excludedRoot 1 1 $ea $eb $excludedComparison.InvalidReasons}
        catch{$duplicateRejected=$true}
        Require $duplicateRejected 'Resume overwrote an existing excluded attempt.'
        $reasonPath=Join-Path $excludedRoot 'excluded\pair1-attempt2-reason.json'
        $originalReason=Get-Json $reasonPath
        $badReason=[pscustomobject]@{Pair=1;Attempt=2;Reasons=@('Thermal paths differ by more than one degree.')}
        Save-JsonAtomic $badReason $reasonPath -Replace
        $tamperRejected=$false
        try{Get-ExcludedAttemptSet $excludedRoot 1 $script:LabApk|Out-Null}catch{$tamperRejected=$true}
        Require $tamperRejected 'Tampered excluded reasons were accepted on Resume.'
        Save-JsonAtomic $originalReason $reasonPath -Replace
        $b3=Join-Path $excludedRoot 'excluded\pair1-attempt3-B.json'
        $b3Value=Get-Json $b3;[IO.File]::Delete($b3)
        $partialRejected=$false
        try{Get-ExcludedAttemptSet $excludedRoot 1 $script:LabApk|Out-Null}catch{$partialRejected=$true}
        Require $partialRejected 'Partial excluded attempt was accepted on Resume.'
        Save-JsonAtomic $b3Value $b3
        $tamperedTerminal=($terminal|ConvertTo-Json -Depth 14|ConvertFrom-Json)
        $tamperedTerminal.ExcludedEvidence[0].Sha256=('C'*64)
        $terminalTamperRejected=$false
        try{Assert-DynamicRefreshInconclusive $tamperedTerminal $excludedRoot $script:LabApk|Out-Null}
        catch{$terminalTamperRejected=$true}
        Require $terminalTamperRejected 'Tampered terminal evidence was accepted.'
        Require ((Get-FinalConfigDisposition $true $true $true)-ceq'CLEAN_AFTER_COMPLETE') `
                'Terminal inconclusive completion would preserve its snapshot instead of cleaning it.'
    }finally{
        if(Test-Path -LiteralPath $excludedRoot){[IO.Directory]::Delete($excludedRoot,$true)}
    }
    $hot=@();for($i=1;$i-le3;$i++){$hot+=New-SyntheticReport B $i 70.2 68.2 4 14.4 44}
    Require (-not [bool](Get-Decision $a $hot $script:LabApk).Gates.AcceptancePass) `
            'Mismatched thermal path was accepted.'
    $slow=@();for($i=1;$i-le3;$i++){$slow+=New-SyntheticReport B $i 68.5 67.0 3 14.0 42}
    Require (-not [bool](Get-Decision $a $slow $script:LabApk).Gates.AcceptancePass) `
            'FPS/P10 regression was accepted.'
    $wrongApk=New-SyntheticApk;$wrongApk.BaseApkSha256=('C'*64)
    $rejected=$false;try{Get-Decision $a $b $wrongApk|Out-Null}catch{$rejected=$true}
    Require $rejected 'Changed installed APK identity was accepted.'
    $normalRoot=Join-Path ([IO.Path]::GetTempPath()) `
            "qcmab-normal-comparison-selftest-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($normalRoot)|Out-Null
    try{
        for($i=1;$i-le3;$i++){
            Save-JsonAtomic $a[$i-1] (Join-Path $normalRoot "A$i.json")
            Save-JsonAtomic $b[$i-1] (Join-Path $normalRoot "B$i.json")
        }
        $normalDecision=Get-Decision $a $b $script:LabApk
        $normalComparisonPath=Join-Path $normalRoot 'comparison.json'
        Save-JsonAtomic $normalDecision $normalComparisonPath
        $normalPersisted=Get-Json $normalComparisonPath
        $normalResumed=Assert-PersistedComparison $normalPersisted $normalRoot $script:LabApk
        Require ([string]$normalResumed.Gates.Decision-ceq'ACCEPT_CANDIDATE'-and
                [bool]$normalResumed.Gates.AcceptancePass) `
                'Resume did not reuse an exact normal comparison written before completion flags.'
        $normalTampered=$normalPersisted|ConvertTo-Json -Depth 14|ConvertFrom-Json
        $normalTampered.Aggregate.P95ImprovementPercent=999.0
        $normalTamperRejected=$false
        try{Assert-PersistedComparison $normalTampered $normalRoot $script:LabApk|Out-Null}
        catch{$normalTamperRejected=$true}
        Require $normalTamperRejected 'Resume accepted a tampered normal comparison.'
    }finally{
        if(Test-Path -LiteralPath $normalRoot){[IO.Directory]::Delete($normalRoot,$true)}
    }
    Require ($script:DeviceInvocationCount-eq$before) 'SelfTest invoked ADB.'
    [pscustomobject]@{Result='PASS';HostOnly=$true;DeviceTouched=$false;
        AdbInvocations=$script:DeviceInvocationCount-$before;Package=$script:Package;
        Profile=$script:Profile;Experiment=$Experiment;Order='AB/BA/AB';Assertions=120;
        CandidateConsumedMarkerValidated=$true;AutomaticRollback=$true}
}

function Invoke-Plan($Artifacts){
    $before=$script:DeviceInvocationCount
    Invoke-OfflineHelperContracts $Artifacts
    Require ($script:DeviceInvocationCount-eq$before) 'Plan invoked ADB.'
    [pscustomobject]@{Result='PLAN';DeviceTouched=$false;Package=$script:Package;Profile=$script:Profile;
        World=$script:World;Experiment=$Experiment;Operation=$Artifacts.Operation;Target=$Artifacts.Target;
        BaselineSha256=$Artifacts.BaselineSha256;CandidateSha256=$Artifacts.CandidateSha256;
        CoreSha256=$script:ExpectedCoreSha256;VeqSha256=$script:ExpectedVeqSha256;
        LabApkSha256=$script:ExpectedApkSha256;Order='A1-B1-B2-A2-A3-B3';
        WarmupSeconds=$WarmupSeconds;PreflightSeconds=$script:PreflightSeconds;
        SampleSeconds=$script:SampleSeconds;
        CandidateMarkerPolicy='consumed with unchanged strict run id';
        Acceptance='P95 >=3% or stable-refresh stale >=10%; >=2/3 pair wins; FPS/P10 loss <=1% per pair and aggregate';
        StableSelectable=$false;RawLogsPersisted=$false}
}

function Get-FinalConfigDisposition([bool]$RunCompleted,[bool]$ComparisonPersisted,
        [bool]$SnapshotReady) {
    if(-not$SnapshotReady){return 'NONE'}
    if($RunCompleted-and$ComparisonPersisted){return 'CLEAN_AFTER_COMPLETE'}
    return 'PRESERVE_READY_FOR_RESUME'
}

function Invoke-FinalRecovery($Artifacts,[bool]$RunCompleted,[bool]$ComparisonPersisted) {
    $errors=[Collections.Generic.List[string]]::new()
    try{Stop-LabWithRetry}catch{$errors.Add("stop: $($_.Exception.Message)")}
    $configReady=$null-ne$script:RunManifest-and
            [string]$script:RunManifest.ConfigSnapshotState-ceq'ready'
    $configDisposition=Get-FinalConfigDisposition $RunCompleted $ComparisonPersisted $configReady
    $configRestored=-not$configReady
    $modRestored=$false
    if($configReady){
        try{Invoke-RestoreConfigSnapshot $script:RunManifest;$configRestored=$true}
        catch{$errors.Add("config-initial: $($_.Exception.Message)")}
    }
    try{Invoke-ModRollback $Artifacts;$modRestored=$true}
    catch{$errors.Add("mod-initial: $($_.Exception.Message)")}
    if($configReady-and-not$configRestored){
        try{Stop-LabWithRetry;Invoke-RestoreConfigSnapshot $script:RunManifest;$configRestored=$true}
        catch{$errors.Add("config-retry: $($_.Exception.Message)")}
    }
    if(-not$modRestored){
        try{Stop-LabWithRetry;Invoke-ModRollback $Artifacts;$modRestored=$true}
        catch{$errors.Add("mod-retry: $($_.Exception.Message)")}
    }
    $scratchClean=$false
    try{Stop-LabWithRetry;Invoke-CleanupEmergencyStageNamespace;$scratchClean=$true}
    catch{$errors.Add("emergency-stage-cleanup: $($_.Exception.Message)")}
    $verified=$false
    if($configRestored-and$modRestored-and$scratchClean){
        try{
            $final=Get-StackState
            Assert-StackContract $final A
            Assert-TransactionContract (Get-ModTransactionStatus) A $final.OtherModsFingerprint
            if($configReady){
                Assert-ConfigSnapshotContract (Get-ConfigSnapshotStatus) $script:RunManifest
            }
            $verified=$true
        }catch{$errors.Add("verify: $($_.Exception.Message)")}
    }
    if($verified-and$configReady-and$configDisposition-ceq'CLEAN_AFTER_COMPLETE'){
        try{Invoke-CleanupConfigSnapshot $script:RunManifest}
        catch{$errors.Add("config-state-cleanup: $($_.Exception.Message)");$verified=$false}
    }
    if($verified-and$configReady-and$configDisposition-ceq'PRESERVE_READY_FOR_RESUME'){
        try{Assert-ConfigSnapshotContract (Get-ConfigSnapshotStatus) $script:RunManifest}
        catch{$errors.Add("config-state-preserve: $($_.Exception.Message)");$verified=$false}
    }
    if(-not$verified){
        $summary=if($errors.Count){$errors-join' | '}else{'final state was not verified'}
        throw "Final Lab recovery incomplete: $summary"
    }
}

function Invoke-Run($Artifacts){
    if(-not$AllowDeviceWrite){throw 'Run requires -AllowDeviceWrite.'}
    $directory=Resolve-OutputDirectory $OutputDirectory -GenerateDefault
    $lockPath=Acquire-Lock $directory
    $manifestPath=Join-Path $directory 'run-manifest.json'
    $rollbackPermitted=$false
    $comparisonPersisted=$false
    $runCompleted=$false
    try{
        $script:PowerShellExe=Get-PowerShellExe;Resolve-Device;$script:LabApk=Get-InstalledApkIdentity
        $manifest=$null
        if(Test-Path -LiteralPath $manifestPath){
            Require $Resume 'Output exists; use -Resume only after inspection.'
            $manifest=Get-Json $manifestPath
            $script:ExpectedOtherModsFingerprint=Normalize-Sha ([string]$manifest.OtherModsFingerprint)
            $script:ExpectedConfigFingerprint=Normalize-Sha ([string]$manifest.ConfigFingerprint)
            $script:BenchmarkRunId=[string]$manifest.BenchmarkRunId
            Assert-Manifest $manifest
        }else{
            $unexpected=@(Get-ChildItem -Force $directory|Where-Object{$_.FullName-cne$lockPath})
            Require ($unexpected.Count-eq0) 'New run output directory is not empty.'
        }
        Stop-LabWithRetry
        $snapshotStatus=Get-ConfigSnapshotStatus
        if($null-eq$script:ExpectedOtherModsFingerprint){
            Require ([string]$snapshotStatus.State-ceq'absent'-and
                    @($snapshotStatus.StageNames).Count-eq0) `
                    'A prior benchmark config transaction exists; resume its exact output instead of bootstrapping drift.'
            $preRollback=Get-StackState
            Require ((Normalize-Sha $preRollback.CoreSha256)-ceq$script:ExpectedCoreSha256-and
                    (Normalize-Sha $preRollback.VeqSha256)-ceq$script:ExpectedVeqSha256-and
                    [string]$preRollback.TargetState-ceq$Artifacts.BaselineSha256-and
                    [bool]$preRollback.ForeignMarkersAbsent) `
                    'A new run requires the exact clean baseline core/VEQ/target.'
            $cleanTransaction=Get-ModTransactionStatus
            Require ([string]$cleanTransaction.MarkerState-ceq'absent'-and
                    (Get-ModTransactionStatePresence)-ceq'absent') `
                    'A prior mod transaction exists; resume its pinned run instead of bootstrapping drift.'
            $script:ExpectedOtherModsFingerprint=Normalize-Sha $preRollback.OtherModsFingerprint
            $script:ExpectedConfigFingerprint=Normalize-Sha $preRollback.ConfigFingerprint
        }
        $rollbackPermitted=$true
        if($null-ne$manifest-and[string]$snapshotStatus.State-cne'absent'){
            $script:RunManifest=Invoke-EnsureConfigSnapshot $manifestPath $manifest
        }
        Invoke-ModRollback $Artifacts
        $initial=Get-StackState
        Require ([string]$initial.TargetState-ceq$Artifacts.BaselineSha256) 'Initial target is not baseline.'
        Require ((Normalize-Sha $initial.CoreSha256)-ceq$script:ExpectedCoreSha256-and
                (Normalize-Sha $initial.VeqSha256)-ceq$script:ExpectedVeqSha256) 'Initial core/VEQ mismatch.'
        Assert-StackContract $initial A
        Assert-TransactionContract (Get-ModTransactionStatus) A $initial.OtherModsFingerprint
        if(-not(Test-Path -LiteralPath $manifestPath)){
            $script:BenchmarkRunId=[guid]::NewGuid().ToString('N')
            $manifest=New-Manifest $Artifacts
            Save-JsonAtomic $manifest $manifestPath
        }
        if($null-eq$script:RunManifest){
            $script:RunManifest=Invoke-EnsureConfigSnapshot $manifestPath $manifest
        }
        $comparisonPath=Join-Path $directory 'comparison.json'
        if(Test-Path -LiteralPath $comparisonPath){
            Require $Resume 'An existing comparison requires explicit -Resume validation.'
            $persistedDecision=Get-Json $comparisonPath
            $decision=Assert-PersistedComparison $persistedDecision $directory $script:LabApk
            $comparisonPersisted=$true
            $runCompleted=$true
        }else{
            $terminalInconclusive=$null
            for($pair=1;$pair-le3;$pair++){
                if((Test-Path (Join-Path $directory "A$pair.json"))-or(Test-Path (Join-Path $directory "B$pair.json"))){
                    Require ($Resume-and(Test-Path (Join-Path $directory "A$pair.json"))-and
                        (Test-Path (Join-Path $directory "B$pair.json"))) "Pair $pair is partial."
                    continue
                }
                $pairResult=Invoke-Pair $pair $Artifacts $directory
                if([string]$pairResult.Status-ceq'INCONCLUSIVE_DYNAMIC_REFRESH'){
                    $terminalInconclusive=$pairResult
                    break
                }
                Require ([string]$pairResult.Status-ceq'COMPARABLE') `
                        "Pair $pair returned an unknown terminal state."
            }
            $decision=if($null-ne$terminalInconclusive){
                New-DynamicRefreshInconclusive $terminalInconclusive.AttemptSet $directory
            }else{
                Get-ReportSet $directory $script:LabApk
            }
            Save-JsonAtomic $decision $comparisonPath
            $persistedDecision=Get-Json $comparisonPath
            $decision=Assert-PersistedComparison $persistedDecision $directory $script:LabApk
            $comparisonPersisted=$true
            $runCompleted=$true
        }
        [pscustomobject]@{Result='COMPLETE';OutputDirectory=$directory;
            Decision=$decision.Gates.Decision;AcceptancePass=$decision.Gates.AcceptancePass;
            LabLeftStoppedOnBaseline=$true;StableTouched=$false}
    }finally{
        try{
            if($rollbackPermitted-and$null-ne$script:ResolvedAdb){
                try{Stop-LabWithRetry}catch{}
                $preRecoveryErrors=[Collections.Generic.List[string]]::new()
                if($null-eq$script:RunManifest-and(Test-Path -LiteralPath $manifestPath)){
                    try{
                        $recoveryManifest=Get-Json $manifestPath
                        Assert-Manifest $recoveryManifest
                        if([string]$recoveryManifest.ConfigSnapshotState-ceq'ready'){
                            Assert-ConfigSnapshotContract (Get-ConfigSnapshotStatus) `
                                    $recoveryManifest -AllowInterruptedRestore
                            $script:RunManifest=$recoveryManifest
                        }
                    }catch{$preRecoveryErrors.Add("manifest-recovery: $($_.Exception.Message)")}
                }
                $finalRecoveryError=$null
                try{Invoke-FinalRecovery $Artifacts $runCompleted $comparisonPersisted}
                catch{$finalRecoveryError=$_.Exception.Message}
                if($preRecoveryErrors.Count-or$null-ne$finalRecoveryError){
                    $parts=@($preRecoveryErrors)
                    if($null-ne$finalRecoveryError){$parts+=$finalRecoveryError}
                    throw ('Final recovery reported: '+($parts-join' | '))
                }
            }
        }finally{Release-Lock $lockPath}
    }
}

$null=Resolve-HostContract
if($Action-ceq'SelfTest'){Invoke-SelfTest;return}
if($Action-ceq'Aggregate'){
    $before=$script:DeviceInvocationCount
    $directory=Resolve-OutputDirectory $OutputDirectory
    $manifest=Get-Json (Join-Path $directory 'run-manifest.json')
    $script:ExpectedOtherModsFingerprint=Normalize-Sha ([string]$manifest.OtherModsFingerprint)
    $script:ExpectedConfigFingerprint=Normalize-Sha ([string]$manifest.ConfigFingerprint)
    $script:BenchmarkRunId=[string]$manifest.BenchmarkRunId
    $script:LabApk=$manifest.LabApk
    Assert-Manifest $manifest
    $comparisonPath=Join-Path $directory 'comparison.json'
    $persisted=if(Test-Path -LiteralPath $comparisonPath){Get-Json $comparisonPath}else{$null}
    $result=if($null-ne$persisted){
        Assert-PersistedComparison $persisted $directory $script:LabApk
    }else{
        Get-ReportSet $directory $script:LabApk
    }
    Require ($script:DeviceInvocationCount-eq$before) 'Aggregate invoked ADB.'
    $result;return
}
$artifacts=Assert-LocalArtifacts
if($Action-ceq'Plan'){Invoke-Plan $artifacts;return}
Invoke-Run $artifacts
