[CmdletBinding()]
param(
    [string] $CandidateJar,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedCandidateSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$harness = Join-Path $PSScriptRoot 'quest-veq-lab.ps1'
$repo = Split-Path -Parent $PSScriptRoot
$baseline = Join-Path $repo 'Pojlib\src\main\assets\mods\vivecraft-essentials-quest.bin'
$syntheticSha = '4C0FC01A3752A531A53F06C85A14C1E3F9510E1784A9160456699C8D8B9F7E72'
$rejectedSha = '35B71C9C432B42AF067D65BEEB1E966C2242181D085449C411B230F568800095'
$fakeAdb = Join-Path ([IO.Path]::GetTempPath()) 'quest-veq-lab-adb-must-not-run.exe'

if (-not [string]::IsNullOrWhiteSpace($CandidateJar) -and
        [string]::IsNullOrWhiteSpace($ExpectedCandidateSha256)) {
    throw 'CandidateJar requires an independently supplied ExpectedCandidateSha256.'
}

$selfTestArguments = @{ Action = 'SelfTest' }
if (-not [string]::IsNullOrWhiteSpace($CandidateJar)) {
    $selfTestArguments.JarPath = $CandidateJar
    $selfTestArguments.ExpectedSha256 = $ExpectedCandidateSha256
}
$selfTest = & $harness @selfTestArguments
if ($selfTest.Result -cne 'PASS' -or $selfTest.DeviceTouched -or
        [int]$selfTest.AdbInvocations -ne 0 -or -not $selfTest.StablePathRejected -or
        $selfTest.CandidateHashPolicy -cne 'explicit-expected-sha256-per-deploy') {
    throw 'VEQ v70 Lab SelfTest did not prove its Host-only fixed-path contract.'
}

function Assert-FailsBeforeAdb {
    param(
        [Parameter(Mandatory)][scriptblock] $Body,
        [Parameter(Mandatory)][string] $ExpectedMessage
    )
    try {
        & $Body | Out-Null
        throw "Expected failure containing '$ExpectedMessage'."
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape($ExpectedMessage)) {
            throw "Unexpected failure: $($_.Exception.Message)"
        }
    }
}

Assert-FailsBeforeAdb {
    & $harness -Action Deploy -JarPath $baseline -ExpectedSha256 $syntheticSha -AdbPath $fakeAdb
} 'AllowDeviceWrite'
Assert-FailsBeforeAdb {
    & $harness -Action Deploy -JarPath $baseline -AllowDeviceWrite -AdbPath $fakeAdb
} 'ExpectedSha256'
Assert-FailsBeforeAdb {
    & $harness -Action Deploy -JarPath $baseline -ExpectedSha256 $syntheticSha `
            -AllowDeviceWrite -AdbPath $fakeAdb
} 'ExpectedSha256'
Assert-FailsBeforeAdb {
    & $harness -Action Rollback -AdbPath $fakeAdb
} 'AllowDeviceWrite'

# Dot-sourcing SelfTest is contractually ADB-free and exposes the pure lock
# policy so marker-bound and permanently rejected hashes can be tested.
. $harness -Action SelfTest | Out-Null
$rejected = $false
try {
    Assert-NotBlacklistedCandidateHash $rejectedSha | Out-Null
} catch {
    $rejected = $_.Exception.Message -match '1047f873' -and
            $_.Exception.Message -match 'blacklisted'
}
if (-not $rejected) {
    throw 'The superseded v69 frame-snapshot candidate was not explicitly blacklisted.'
}
$acceptedSynthetic = Assert-NotBlacklistedCandidateHash $syntheticSha
if ($acceptedSynthetic -cne $syntheticSha) {
    throw 'A non-blacklisted, explicitly supplied v70 candidate hash was not accepted.'
}
if (@($script:VeqLock.candidatePolicy.bakedCandidateHashes).Count -ne 0) {
    throw 'The v70 VEQ Lab policy baked a not-yet-built candidate hash.'
}

# Prove that a previously unknown hash is accepted only when its actual JAR
# has the exact shared v70 Fabric contract and matches the independently
# supplied hash. This remains entirely Host-local.
$candidateRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ('quest-veq-v70-host-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($candidateRoot) | Out-Null
$syntheticJar = Join-Path $candidateRoot 'veq-v70-synthetic.jar'
try {
    $stream = [IO.File]::Create($syntheticJar)
    $zip = [IO.Compression.ZipArchive]::new(
            $stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $fabricEntry = $zip.CreateEntry('fabric.mod.json')
        $fabric = '{"schemaVersion":1,"id":"vivecraft_essentials_quest","version":"0.7.0-v70-canary.1","environment":"client","entrypoints":{"client":["org.questcraft.veq.fabric.VeqFabricClient"]},"mixins":["vivecraft_essentials_quest.mixins.json"],"depends":{"fabricloader":">=0.19.3","fabric-api":">=0.158.0","minecraft":"26.2","java":">=25","vivecraft":"*"}}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($fabric)
        $entryStream = $fabricEntry.Open()
        try { $entryStream.Write($bytes, 0, $bytes.Length) } finally { $entryStream.Dispose() }
        $payloadEntry = $zip.CreateEntry('org/questcraft/veq/fabric/VeqFabricClient.class')
        $payload = [byte[]](1, 2, 3, 4)
        $entryStream = $payloadEntry.Open()
        try { $entryStream.Write($payload, 0, $payload.Length) } finally { $entryStream.Dispose() }
    } finally {
        $zip.Dispose()
        $stream.Dispose()
    }
    $syntheticJarSha = (Get-FileHash -LiteralPath $syntheticJar -Algorithm SHA256).Hash
    $syntheticResult = & $harness -Action SelfTest -JarPath $syntheticJar `
            -ExpectedSha256 $syntheticJarSha
    if ($syntheticResult.Result -cne 'PASS' -or $syntheticResult.DeviceTouched -or
            [int]$syntheticResult.AdbInvocations -ne 0) {
        throw 'The exact synthetic v70 candidate did not pass marker-bound Host validation.'
    }
} finally {
    [IO.Directory]::Delete($candidateRoot, $true)
}

[pscustomobject]@{
    Result = 'PASS'
    CasesPassed = 9
    CandidateArtifactValidated = $true
    CallerArtifactValidated = -not [string]::IsNullOrWhiteSpace($CandidateJar)
    ExpectedSha256RequiredBeforeAdb = $true
    MismatchedShaRejectedBeforeAdb = $true
    AllowDeviceWriteRequiredBeforeAdb = $true
    RejectedCommitBlacklisted = $true
    MarkerBoundUnknownHashAccepted = $true
    NoBakedCandidateHashes = $true
    StablePathRejected = $true
    DeviceTouched = $false
    AdbInvocations = 0
}
