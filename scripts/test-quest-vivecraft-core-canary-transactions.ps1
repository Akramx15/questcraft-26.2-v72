[CmdletBinding()]
param(
    [ValidateSet('VivecraftCore', 'VeqFrameSnapshot')]
    [string] $Harness = 'VivecraftCore'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$production = Join-Path $PSScriptRoot $(if ($Harness -eq 'VeqFrameSnapshot') {
    'quest-veq-lab.ps1'
} else {
    'quest-vivecraft-core-canary.ps1'
})
. $production -Action SelfTest | Out-Null

$bashCandidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')
)
$bash = @($bashCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) |
        Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($bash)) { throw 'Git Bash is required.' }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('qcvc-host-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $run = '0123456789abcdef0123456789abcdef'
    $fixtureWindows = Join-Path $temporary 'fixture'
    [IO.Directory]::CreateDirectory($fixtureWindows) | Out-Null
    $quotedFixture = $fixtureWindows.Replace("'", "'\''")
    $fixtureRoot = (& $bash -lc "cygpath -u '$quotedFixture'").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fixtureRoot)) {
        throw 'Could not resolve the isolated shell fixture.'
    }
    $files = "$fixtureRoot/files"
    $game = "$files/instances/26.2"
    $mods = "$game/mods"
    $state = "$game/.questcraft/$script:HarnessId"
    $targetLeaf = Split-Path -Leaf $script:TargetRelative
    $paths = [pscustomobject]@{
        Files = $files
        Game = $game
        Mods = $mods
        State = $state
        Target = "$mods/$targetLeaf"
        Marker = "$state/request.json"
        RejectedMarker = "$state/request.rejected.json"
    }
    $candidate = Get-StrictFabricMetadata $script:BaselinePath
    $marker = New-MarkerObject -RunId $run -Candidate $candidate `
            -OtherModsFingerprintSha256 ('a' * 64) -Mode 'OFF' `
            -ExpiresAtEpochMs 1800000000000
    $markerLocal = Join-Path $temporary 'marker.json'
    [IO.File]::WriteAllText($markerLocal, (($marker | ConvertTo-Json -Depth 3) + "`n"),
            [Text.UTF8Encoding]::new($false))
    $markerSha = (Get-FileHash -LiteralPath $markerLocal -Algorithm SHA256).Hash.ToLowerInvariant()

    $uploadCandidate = "$fixtureRoot/upload-candidate"
    $uploadMarker = "$fixtureRoot/upload-marker"
    $modsWindows = Join-Path $fixtureWindows 'files\instances\26.2\mods'
    $targetWindows = Join-Path $modsWindows $targetLeaf
    $uploadCandidateWindows = Join-Path $fixtureWindows 'upload-candidate'
    $uploadMarkerWindows = Join-Path $fixtureWindows 'upload-marker'
    $utf8 = [Text.UTF8Encoding]::new($false)
    $cases = @(
        [pscustomobject]@{ Name = 'after-copy'; ExpectedCode = 1; Committed = $false },
        [pscustomobject]@{ Name = 'after-candidate-rename'; ExpectedCode = 1; Committed = $false },
        [pscustomobject]@{ Name = 'before-marker-commit'; ExpectedCode = 1; Committed = $false },
        [pscustomobject]@{ Name = 'after-marker-commit'; ExpectedCode = 1; Committed = $true },
        [pscustomobject]@{ Name = ''; ExpectedCode = 0; Committed = $true }
    )
    $passed = 0
    foreach ($case in $cases) {
        if (Test-Path -LiteralPath $fixtureWindows -PathType Container) {
            [IO.Directory]::Delete($fixtureWindows, $true)
        }
        [IO.Directory]::CreateDirectory($modsWindows) | Out-Null
        [IO.File]::Copy($script:BaselinePath, $targetWindows, $true)
        [IO.File]::Copy($script:BaselinePath, $uploadCandidateWindows, $true)
        [IO.File]::Copy($markerLocal, $uploadMarkerWindows, $true)
        $shell = New-DeployCommitShell -Paths $paths -RunId $run -Candidate $candidate `
                -MarkerSha256 $markerSha -UploadCandidate $uploadCandidate `
                -UploadMarker $uploadMarker -FaultStage $case.Name
        $shellName = if ($case.Name) { $case.Name + '.sh' } else { 'success.sh' }
        $shellPath = Join-Path $temporary $shellName
        [IO.File]::WriteAllText($shellPath, $shell.Replace("`r`n", "`n") + "`n", $utf8)
        & $bash -n $shellPath
        if ($LASTEXITCODE -ne 0) { throw "bash -n rejected $($case.Name)." }
        $shellUnix = (& $bash -lc "cygpath -u '$($shellPath.Replace("'", "'\\''"))'").Trim()
        & $bash $shellUnix | Out-Null
        $actualCode = $LASTEXITCODE
        if ($actualCode -ne $case.ExpectedCode) {
            throw "Fault '$($case.Name)' returned $actualCode, expected $($case.ExpectedCode)."
        }
        $probe = if ($case.Committed) {
            'test -f ' + (ConvertTo-ShLiteral $paths.Marker) +
                    ' && test -f ' + (ConvertTo-ShLiteral "$state/candidate-$run.jar") +
                    ' && test "$(sha256sum ' + (ConvertTo-ShLiteral $paths.Marker) +
                    ' | awk ''{print tolower($1)}'')" = ' + (ConvertTo-ShLiteral $markerSha)
        } else {
            'test ! -e ' + (ConvertTo-ShLiteral $paths.Marker) +
                    ' && test ! -e ' + (ConvertTo-ShLiteral "$state/candidate-$run.jar")
        }
        $probePath = Join-Path $temporary ("probe-$passed.sh")
        [IO.File]::WriteAllText($probePath, $probe + "`n", $utf8)
        $probeUnix = (& $bash -lc "cygpath -u '$($probePath.Replace("'", "'\\''"))'").Trim()
        & $bash $probeUnix
        if ($LASTEXITCODE -ne 0) { throw "Fault '$($case.Name)' left an invalid transaction state." }
        $passed++
    }

    $uploadBaselineWindows = Join-Path $fixtureWindows 'upload-baseline'
    [IO.File]::Copy($script:BaselinePath, $uploadBaselineWindows, $true)
    [IO.File]::WriteAllText($targetWindows, 'candidate', $utf8)
    $rollback = New-RollbackShell -Paths $paths -RunId $run `
            -UploadBaseline "$fixtureRoot/upload-baseline"
    $rollbackPath = Join-Path $temporary 'rollback.sh'
    [IO.File]::WriteAllText($rollbackPath, $rollback.Replace("`r`n", "`n") + "`n", $utf8)
    & $bash -n $rollbackPath
    if ($LASTEXITCODE -ne 0) { throw 'bash -n rejected rollback.' }
    $rollbackUnix = (& $bash -lc "cygpath -u '$($rollbackPath.Replace("'", "'\\''"))'").Trim()
    & $bash $rollbackUnix | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Rollback shell failed.' }
    $rollbackProbe = 'test "$(sha256sum ' + (ConvertTo-ShLiteral $paths.Target) +
            ' | awk ''{print tolower($1)}'')" = ' + (ConvertTo-ShLiteral $script:BaselineSha256) +
            ' && test ! -e ' + (ConvertTo-ShLiteral $paths.Marker)
    $rollbackProbePath = Join-Path $temporary 'rollback-probe.sh'
    [IO.File]::WriteAllText($rollbackProbePath, $rollbackProbe + "`n", $utf8)
    $rollbackProbeUnix = (& $bash -lc "cygpath -u '$($rollbackProbePath.Replace("'", "'\\''"))'").Trim()
    & $bash $rollbackProbeUnix
    if ($LASTEXITCODE -ne 0) { throw 'Rollback did not restore the exact baseline.' }
    $passed++

    [IO.File]::WriteAllText((Join-Path $modsWindows 'A.jar'), 'alpha', $utf8)
    [IO.File]::WriteAllText((Join-Path $modsWindows 'z.jar'), 'zeta', $utf8)
    $preflightPath = Join-Path $temporary 'preflight.sh'
    [IO.File]::WriteAllText($preflightPath,
            (Get-RemotePreflightShell $paths).Replace("`r`n", "`n") + "`n", $utf8)
    & $bash -n $preflightPath
    if ($LASTEXITCODE -ne 0) { throw 'bash -n rejected preflight.' }
    $preflightUnix = (& $bash -lc "cygpath -u '$($preflightPath.Replace("'", "'\\''"))'").Trim()
    $preflightRows = @(& $bash $preflightUnix)
    if ($LASTEXITCODE -ne 0) { throw 'Preflight fingerprint shell failed.' }
    $actualFingerprint = @($preflightRows | Where-Object { $_ -match '^FINGERPRINT\t' })
    if ($actualFingerprint.Count -ne 1) { throw 'Preflight fingerprint output was ambiguous.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $alphaSha = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('alpha')))).Replace('-', '').ToLowerInvariant()
        $zetaSha = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('zeta')))).Replace('-', '').ToLowerInvariant()
        $canonicalRows = "A.jar`t$alphaSha`nz.jar`t$zetaSha`n"
        $expectedFingerprint = ([BitConverter]::ToString(
                $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalRows)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    if ($actualFingerprint[0].Split("`t")[1] -cne $expectedFingerprint) {
        throw 'Shell fingerprint does not match sorted filename+SHA canonicalization.'
    }
    $passed++

    [pscustomobject]@{
        Result = 'PASS'
        Harness = $Harness
        CasesPassed = $passed
        DeployFaultCases = $cases.Count
        RollbackCases = 1
        FingerprintCases = 1
        BashSyntaxPassed = $cases.Count + 2
        DeviceTouched = $false
        AdbInvocations = $script:AdbInvocationCount
    }
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Container) {
        [IO.Directory]::Delete($temporary, $true)
    }
}
