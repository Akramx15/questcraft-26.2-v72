[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$production = Join-Path $PSScriptRoot 'quest-mods-ab-lab.ps1'
$repo = Split-Path -Parent $PSScriptRoot
$workspace = if (Test-Path -LiteralPath (Join-Path $repo 'artifacts') -PathType Container) {
    $repo
} else {
    Split-Path -Parent (Split-Path -Parent $repo)
}

$artifacts = [ordered]@{
    'sodium-0.9.1' = [ordered]@{
        Baseline = Join-Path $workspace `
                'artifacts\perf-5h-20260830\candidate-jars\sodium-fabric-0.9.2-alpha.4+mc26.2.jar'
        BaselineSha = 'A6D1CED177A1C57147E8C1C8043650D5F93E1F2824C9952F3FB67AE05633A0A7'
        Candidate = Join-Path $workspace `
                'exports\QuestCraft-Visor-26.2-PC-client-mods-20260830\mods\sodium-fabric-0.9.1+mc26.2.jar'
        CandidateSha = 'DE406C7A0CA5E748DFBE44740278400882A44E3109E2584B243EC02D4003344B'
    }
    'without-lithium' = [ordered]@{
        Baseline = Join-Path $workspace 'exports\v68-device-preinstall-20260902-1845\mods\Lithium.jar'
        BaselineSha = 'FDDE92E238E8075F89AD7F701F2A3D5854AF88BA9A67657184A4407B104AC563'
    }
    'without-ferrite-core' = [ordered]@{
        Baseline = Join-Path $workspace 'exports\v68-device-preinstall-20260902-1845\mods\Ferrite-Core.jar'
        BaselineSha = '213966C72ED967ACC7392BEB28A866FBA301FF56B9976C2E7801C2DB7DE6BF22'
    }
    'without-bad-optimizations' = [ordered]@{
        Baseline = Join-Path $workspace 'exports\v68-device-preinstall-20260902-1845\mods\BadOptimizations.jar'
        BaselineSha = '06CEE46D81D3A0AFB8E993DFBE4B990A3BE92F52ABDE3590CC396490CB6EB4D2'
    }
}

foreach ($id in $artifacts.Keys) {
    if (-not (Test-Path -LiteralPath $artifacts[$id].Baseline -PathType Leaf)) {
        throw "Required preserved baseline is missing for $id."
    }
}
if (-not (Test-Path -LiteralPath $artifacts['sodium-0.9.1'].Candidate -PathType Leaf)) {
    throw 'The preserved official Sodium 0.9.1 artifact is missing.'
}
$sodiumEvidence = Join-Path $workspace `
        'exports\QuestCraft-Visor-26.2-PC-client-mods-20260830\SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $sodiumEvidence -PathType Leaf) -or
        -not (Get-Content -Raw -LiteralPath $sodiumEvidence).Contains(
        $artifacts['sodium-0.9.1'].CandidateSha)) {
    throw 'The preserved official Sodium 0.9.1 checksum evidence is missing.'
}

$passed = 0
$passed++
foreach ($id in $artifacts.Keys) {
    $entry = $artifacts[$id]
    $arguments = @{
        Action = 'SelfTest'
        Experiment = $id
        BaselineJar = $entry.Baseline
        ExpectedBaselineSha256 = $entry.BaselineSha
    }
    if ($id -ceq 'sodium-0.9.1') {
        $arguments.CandidateJar = $entry.Candidate
        $arguments.ExpectedCandidateSha256 = $entry.CandidateSha
    }
    $result = & $production @arguments
    if ($result.Result -cne 'PASS' -or $result.DeviceTouched -or
            [int]$result.AdbInvocations -ne 0 -or -not $result.StablePathRejected) {
        throw "Host SelfTest failed for $id."
    }
    $passed++
}

function Assert-FailsBeforeAdb {
    param([scriptblock] $Body, [string] $Expected)
    try {
        & $Body | Out-Null
        throw "Expected failure containing '$Expected'."
    } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape($Expected)) {
            throw "Unexpected pre-ADB failure: $($_.Exception.Message)"
        }
    }
    $script:passed++
}

$fakeAdb = Join-Path ([IO.Path]::GetTempPath()) 'mods-ab-adb-must-not-run.exe'
$sodium = $artifacts['sodium-0.9.1']
Assert-FailsBeforeAdb {
    & $production -Action Arm -Experiment sodium-0.9.1 -AdbPath $fakeAdb
} 'AllowDeviceWrite'
Assert-FailsBeforeAdb {
    & $production -Action Arm -Experiment sodium-0.9.1 -AllowDeviceWrite -AdbPath $fakeAdb
} 'BaselineJar'
Assert-FailsBeforeAdb {
    & $production -Action Arm -Experiment sodium-0.9.1 -AllowDeviceWrite `
            -BaselineJar $sodium.Baseline -AdbPath $fakeAdb
} 'ExpectedBaselineSha256'
Assert-FailsBeforeAdb {
    & $production -Action Arm -Experiment sodium-0.9.1 -AllowDeviceWrite `
            -BaselineJar $sodium.Baseline -ExpectedBaselineSha256 $sodium.BaselineSha `
            -AdbPath $fakeAdb
} 'CandidateJar'
Assert-FailsBeforeAdb {
    & $production -Action Arm -Experiment sodium-0.9.1 -AllowDeviceWrite `
            -BaselineJar $sodium.Baseline -ExpectedBaselineSha256 ('0' * 64) `
            -CandidateJar $sodium.Candidate -ExpectedCandidateSha256 $sodium.CandidateSha `
            -AdbPath $fakeAdb
} 'independently supplied SHA-256'
Assert-FailsBeforeAdb {
    & $production -Action Rollback -Experiment sodium-0.9.1 -AdbPath $fakeAdb
} 'AllowDeviceWrite'
Assert-FailsBeforeAdb {
    & $production -Action Rollback -Experiment sodium-0.9.1 -AllowDeviceWrite `
            -AdbPath $fakeAdb
} 'BaselineJar'
$lithium = $artifacts['without-lithium']
Assert-FailsBeforeAdb {
    & $production -Action Arm -Experiment without-lithium -AllowDeviceWrite `
            -BaselineJar $lithium.Baseline -ExpectedBaselineSha256 $lithium.BaselineSha `
            -CandidateJar $sodium.Candidate -ExpectedCandidateSha256 $sodium.CandidateSha `
            -AdbPath $fakeAdb
} 'do not accept a candidate JAR'

# Import the pure generators for shell syntax and transactional fault tests.
. $production -Action SelfTest | Out-Null
$lock = Resolve-ModsAbLock
Set-ExperimentContext $lock 'without-lithium'
$lithiumMarker = New-ModsAbMarker -RunId '0123456789abcdef0123456789abcdef' `
        -OtherModsFingerprintSha256 ('a' * 64) -ExpiresAtEpochMs 1800000000000
Set-ExperimentContext $lock 'sodium-0.9.1'
$crossExperimentRejected = $false
try { Assert-ModsAbMarker ([pscustomobject]$lithiumMarker) } catch {
    $crossExperimentRejected = $_.Exception.Message -match 'Marker target'
}
if (-not $crossExperimentRejected) {
    throw 'A Sodium rollback context accepted a Lithium transaction marker.'
}
$passed++
$bashCandidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe'))
$bash = @($bashCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) |
        Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$bash)) { throw 'Git Bash is required.' }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('qcmab-host-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $fixtureWindows = Join-Path $temporary 'fixture'
    [IO.Directory]::CreateDirectory($fixtureWindows) | Out-Null
    $quoted = $fixtureWindows.Replace("'", "'\''")
    $fixtureRoot = (& $bash -lc "cygpath -u '$quoted'").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fixtureRoot)) {
        throw 'Could not resolve isolated Git Bash fixture.'
    }
    $run = '0123456789abcdef0123456789abcdef'
    $utf8 = [Text.UTF8Encoding]::new($false)
    foreach ($id in $artifacts.Keys) {
        Set-ExperimentContext $lock $id
        $leaf = Split-Path -Leaf $script:TargetRelative
        $files = "$fixtureRoot/files"
        $game = "$files/instances/26.2"
        $mods = "$game/mods"
        $state = "$game/$script:StateRelative"
        $paths = [pscustomobject]@{
            Files=$files; Game=$game; Mods=$mods; State=$state; Target="$mods/$leaf";
            Marker="$state/request.json"; RejectedMarker="$state/request.rejected.json"
        }
        $marker = New-ModsAbMarker -RunId $run `
                -OtherModsFingerprintSha256 ('a' * 64) -ExpiresAtEpochMs 1800000000000
        $markerLocal = Join-Path $temporary "marker-$id.json"
        [IO.File]::WriteAllText($markerLocal, (($marker | ConvertTo-Json -Depth 4) + "`n"), $utf8)
        $markerSha = (Get-FileHash $markerLocal -Algorithm SHA256).Hash.ToLowerInvariant()
        $candidateUpload = if ($id -ceq 'sodium-0.9.1') {
            "$fixtureRoot/upload-candidate"
        } else { '' }
        foreach ($accessMode in @('Normal','Root')) {
            $shell = New-ArmCommitShell -Paths $paths -RunId $run `
                    -MarkerSha256 $markerSha -UploadMarker "$fixtureRoot/upload-marker" `
                    -UploadCandidate $candidateUpload -AccessMode $accessMode
            $shellPath = Join-Path $temporary "syntax-$id-$accessMode.sh"
            [IO.File]::WriteAllText($shellPath, $shell.Replace("`r`n", "`n") + "`n", $utf8)
            & $bash -n $shellPath
            if ($LASTEXITCODE -ne 0) {
                throw "bash -n rejected $accessMode arm shell for $id."
            }
            if ($accessMode -ceq 'Root' -and
                    ($shell -notmatch 'stat -c %u' -or $shell -notmatch 'chown' -or
                    $shell -match 'chown\s+["'']?[0-9]')) {
                throw "Root arm shell does not derive and apply ownership for $id."
            }
            $rollback = New-ModsAbRollbackShell -Paths $paths -RunId $run `
                    -UploadBaseline "$fixtureRoot/upload-baseline" `
                    -MarkerSha256 $markerSha -AccessMode $accessMode
            $rollbackPath = Join-Path $temporary "rollback-syntax-$id-$accessMode.sh"
            [IO.File]::WriteAllText($rollbackPath,
                    $rollback.Replace("`r`n", "`n") + "`n", $utf8)
            & $bash -n $rollbackPath
            if ($LASTEXITCODE -ne 0) {
                throw "bash -n rejected $accessMode rollback shell for $id."
            }
            if ($accessMode -ceq 'Root' -and
                    ($rollback -notmatch 'stat -c %u' -or $rollback -notmatch 'chown' -or
                    $rollback -match 'chown\s+["'']?[0-9]')) {
                throw "Root rollback shell does not derive and apply ownership for $id."
            }
            if ($rollback.Contains('disabled-*.jar') -or
                    -not $rollback.Contains("disabled-$run.jar")) {
                throw "Rollback cleanup is not bound to one run for $id."
            }
            $passed += 2
        }
    }

    # Execute replacement and disable transactions, including recovery from a
    # pre-commit fault and exact rollback.  Java tests cover every runtime stage.
    foreach ($id in @('sodium-0.9.1', 'without-lithium')) {
        Set-ExperimentContext $lock $id
        $entry = $artifacts[$id]
        $leaf = Split-Path -Leaf $script:TargetRelative
        $caseWindows = Join-Path $fixtureWindows ($id -replace '[^a-z0-9.-]', '-')
        $modsWindows = Join-Path $caseWindows 'files\instances\26.2\mods'
        [IO.Directory]::CreateDirectory($modsWindows) | Out-Null
        $targetWindows = Join-Path $modsWindows $leaf
        [IO.File]::Copy($entry.Baseline, $targetWindows, $true)
        $caseQuoted = $caseWindows.Replace("'", "'\''")
        $caseRoot = (& $bash -lc "cygpath -u '$caseQuoted'").Trim()
        $files = "$caseRoot/files"
        $game = "$files/instances/26.2"
        $mods = "$game/mods"
        $state = "$game/$script:StateRelative"
        $paths = [pscustomobject]@{
            Files=$files; Game=$game; Mods=$mods; State=$state; Target="$mods/$leaf";
            Marker="$state/request.json"; RejectedMarker="$state/request.rejected.json"
        }
        $marker = New-ModsAbMarker -RunId $run `
                -OtherModsFingerprintSha256 ('a' * 64) -ExpiresAtEpochMs 1800000000000
        $uploadMarkerWindows = Join-Path $caseWindows 'upload-marker'
        [IO.File]::WriteAllText($uploadMarkerWindows,
                (($marker | ConvertTo-Json -Depth 4) + "`n"), $utf8)
        $markerSha = (Get-FileHash $uploadMarkerWindows -Algorithm SHA256).Hash.ToLowerInvariant()
        $candidateUpload = ''
        if ($id -ceq 'sodium-0.9.1') {
            [IO.File]::Copy($entry.Candidate, (Join-Path $caseWindows 'upload-candidate'), $true)
            $candidateUpload = "$caseRoot/upload-candidate"
        }

        # A pre-commit fault must leave neither marker nor staged baseline.
        $faultShell = New-ArmCommitShell -Paths $paths -RunId $run -MarkerSha256 $markerSha `
                -UploadMarker "$caseRoot/upload-marker" -UploadCandidate $candidateUpload `
                -FaultStage 'after-baseline-rename'
        $faultPath = Join-Path $temporary "fault-$id.sh"
        [IO.File]::WriteAllText($faultPath, $faultShell.Replace("`r`n", "`n") + "`n", $utf8)
        $faultUnix = (& $bash -lc "cygpath -u '$($faultPath.Replace("'", "'\''"))'").Trim()
        & $bash $faultUnix | Out-Null
        if ($LASTEXITCODE -ne 1 -or (Test-Path -LiteralPath (Join-Path $caseWindows `
                'files\instances\26.2\.questcraft\questcraft-mods-ab-canary-v1\request.json'))) {
            throw "Pre-commit fault did not roll back for $id."
        }
        $passed++

        # Recreate uploads consumed by the fault cleanup, then commit.
        [IO.File]::WriteAllText($uploadMarkerWindows,
                (($marker | ConvertTo-Json -Depth 4) + "`n"), $utf8)
        if ($id -ceq 'sodium-0.9.1') {
            [IO.File]::Copy($entry.Candidate, (Join-Path $caseWindows 'upload-candidate'), $true)
        }
        $success = New-ArmCommitShell -Paths $paths -RunId $run -MarkerSha256 $markerSha `
                -UploadMarker "$caseRoot/upload-marker" -UploadCandidate $candidateUpload
        $successPath = Join-Path $temporary "success-$id.sh"
        [IO.File]::WriteAllText($successPath, $success.Replace("`r`n", "`n") + "`n", $utf8)
        $successUnix = (& $bash -lc "cygpath -u '$($successPath.Replace("'", "'\''"))'").Trim()
        & $bash $successUnix | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Arm transaction failed for $id." }
        $passed++

        $uploadBaselineWindows = Join-Path $caseWindows 'upload-baseline'
        [IO.File]::Copy($entry.Baseline, $uploadBaselineWindows, $true)
        $rollback = New-ModsAbRollbackShell -Paths $paths -RunId $run `
                -UploadBaseline "$caseRoot/upload-baseline" -MarkerSha256 $markerSha
        $rollbackPath = Join-Path $temporary "rollback-$id.sh"
        [IO.File]::WriteAllText($rollbackPath, $rollback.Replace("`r`n", "`n") + "`n", $utf8)
        $rollbackUnix = (& $bash -lc "cygpath -u '$($rollbackPath.Replace("'", "'\''"))'").Trim()
        & $bash $rollbackUnix | Out-Null
        if ($LASTEXITCODE -ne 0 -or
                (Get-FileHash $targetWindows -Algorithm SHA256).Hash -cne $entry.BaselineSha) {
            throw "Exact rollback failed for $id."
        }
        $passed++
    }
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Container) {
        [IO.Directory]::Delete($temporary, $true)
    }
}

[pscustomobject]@{
    Result='PASS'; CasesPassed=$passed; ArtifactCases=6; AuthorizationCases=8;
    CrossExperimentCases=1; BashSyntaxCases=16; TransactionFaultCases=2;
    ArmCommitCases=2; RollbackCases=2;
    PowerShellVersion=$PSVersionTable.PSVersion.ToString(); DeviceTouched=$false;
    AdbInvocations=0
}
