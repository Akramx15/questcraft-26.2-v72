<#
.SYNOPSIS
Host-only fault tests for the v71 build transaction and shared lock.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$buildScript = Join-Path $PSScriptRoot 'build-v71-integrated.ps1'
$buildSelfTest = . $buildScript -Target Lab -Action SelfTest

function Assert-Test {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Set-CasePaths {
    param([Parameter(Mandatory)][string] $Root)
    $script:backupDirectory = Join-Path $Root 'guard'
    $script:backupAar = Join-Path $backupDirectory 'Pojlib-release.aar'
    $script:backupHashFile = Join-Path $backupDirectory 'Pojlib-release.aar.sha256'
    $script:reproAar = Join-Path $backupDirectory 'Pojlib-release.first-build.aar'
    $script:backupProjectSettings = Join-Path $backupDirectory 'ProjectSettings.asset'
    $script:backupProjectSettingsHashFile =
        Join-Path $backupDirectory 'ProjectSettings.asset.sha256'
    $script:previousOutputApk = Join-Path $backupDirectory 'previous-output.apk'
    $script:transactionJournal = Join-Path $backupDirectory 'transaction.json'
    $script:pluginAar = Join-Path $Root 'live.aar'
    $script:projectSettings = Join-Path $Root 'ProjectSettings.asset'
    $script:outputApk = Join-Path $Root 'output.apk'
}

function New-TestJournal {
    param([bool] $PreviousOutputPresent)
    $previousHash = if ($PreviousOutputPresent) { Get-Sha256 $outputApk } else { $null }
    $previousSize = if ($PreviousOutputPresent) {
        (Get-Item -LiteralPath $outputApk).Length
    } else { 0 }
    [ordered]@{
        schemaVersion = 1
        repo = Get-CanonicalPath $repo
        target = 'Lab'
        outputApk = Get-CanonicalPath $outputApk
        phase = 'prepared'
        sourceAar = [ordered]@{
            path = Get-CanonicalPath $pluginAar
            sha256 = Get-Sha256 $pluginAar
            sizeBytes = (Get-Item -LiteralPath $pluginAar).Length
        }
        projectSettings = [ordered]@{
            path = Get-CanonicalPath $projectSettings
            sha256 = Get-Sha256 $projectSettings
            sizeBytes = (Get-Item -LiteralPath $projectSettings).Length
        }
        previousOutput = [ordered]@{
            present = $PreviousOutputPresent
            sha256 = $previousHash
            sizeBytes = $previousSize
        }
        newOutput = [ordered]@{
            verified = $false
            sha256 = $null
            sizeBytes = 0
        }
    }
}

function Initialize-Case {
    param(
        [Parameter(Mandatory)][string] $Root,
        [bool] $PreviousOutputPresent
    )
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    Set-CasePaths $Root
    [IO.File]::WriteAllText($pluginAar, 'ORIGINAL_AAR')
    [IO.File]::WriteAllText($projectSettings, 'ORIGINAL_SETTINGS')
    if ($PreviousOutputPresent) { [IO.File]::WriteAllText($outputApk, 'OLD_APK') }
    $journal = New-TestJournal $PreviousOutputPresent
    [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
    Write-TransactionJournal $journal
    [IO.File]::Copy($pluginAar, $backupAar, $false)
    [IO.File]::Copy($projectSettings, $backupProjectSettings, $false)
    if ($PreviousOutputPresent) { [IO.File]::Move($outputApk, $previousOutputApk) }
    $journal
}

$temporaryRoot = Get-CanonicalPath (Join-Path $env:TEMP `
    ('questcraft-v71-build-transaction-test-' + [guid]::NewGuid().ToString('N')))
$canonicalTemp = Get-CanonicalPath $env:TEMP
Assert-Test ($temporaryRoot.StartsWith(
    $canonicalTemp + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) 'Refusing an unsafe self-test directory.'
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

$tests = [Collections.Generic.List[string]]::new()
try {
    Assert-Test ([string]$buildSelfTest.PojlibJavaVersion -ceq '11.0.14.1' -and
            [string]$buildSelfTest.PojlibJavaRuntime -ceq
                'Unity bundled Temurin 11.0.14.1+1' -and
            [string]$buildSelfTest.UnityJavaVersion -ceq '11.0.14.1' -and
            [bool]$buildSelfTest.SharedPojlibAndUnityJdk -and
            [string]$buildSelfTest.D8Version -ceq '4.0.52' -and
            [string]$buildSelfTest.D8BuilderSha256 -ceq
                '346CA459BD3B4B3A1148F6C8AD31B69049E84F269132EDDD6D28E2D513DD360E') `
        'The build plan did not pin bundled Temurin 11 and Unity D8 4.0.52.'
    $tests.Add('pinned-unity-jdk11')

    $wrongJdkRejected = $false
    $savedExpectedUnityJavaVersion = $script:expectedUnityJavaVersion
    try {
        $script:expectedUnityJavaVersion = '99.0.0-test-rejected'
        $null = Resolve-UnityJavaToolchain ([string]$buildSelfTest.UnityJavaHome)
    } catch {
        $wrongJdkRejected = $_.Exception.Message -like
            '*exact bundled Temurin 11.0.14.1+1 runtime*'
    } finally {
        $script:expectedUnityJavaVersion = $savedExpectedUnityJavaVersion
    }
    Assert-Test $wrongJdkRejected `
        'The exact compiler gate accepted a non-Unity JDK.'
    $tests.Add('wrong-jdk-rejected')

    # CreateProcessW receives a null environment block, so prove build children
    # inherit each phase-specific JAVA_HOME/PATH transition.
    $javaEnvironmentProbe = Join-Path $temporaryRoot 'java-environment-probe.ps1'
    [IO.File]::WriteAllText($javaEnvironmentProbe, @'
param([Parameter(Mandatory)][string] $ExpectedHome)
$expectedBin = Join-Path $ExpectedHome 'bin'
$pathEntries = @($env:PATH -split ';')
if ($env:JAVA_HOME -ine $ExpectedHome -or
    -not ($pathEntries -icontains $expectedBin)) { exit 97 }
'@)
    $savedJavaHomeForProbe = $env:JAVA_HOME
    $savedPathForProbe = $env:PATH
    try {
        foreach ($phase in @(
            [pscustomobject]@{
                Name = 'Pojlib-and-Unity'
                Home = [string]$buildSelfTest.UnityJavaHome
            }
        )) {
            $env:JAVA_HOME = $phase.Home
            $env:PATH = (Join-Path $phase.Home 'bin') + ';' + $savedPathForProbe
            $probeJob = [QuestCraftV71BuildJob]::new()
            $probeChild = $probeJob.Start(
                (Join-Path $PSHOME 'pwsh.exe'),
                @('-NoProfile', '-File', $javaEnvironmentProbe,
                    '-ExpectedHome', $phase.Home),
                $temporaryRoot)
            try {
                $probeChild.WaitForExit()
                Assert-Test ($probeChild.ExitCode -eq 0) `
                    ("The {0} child did not inherit its phase-specific Java environment." -f
                        $phase.Name)
            } finally {
                $probeChild.Dispose()
                $probeJob.Dispose()
            }
        }
    } finally {
        $env:JAVA_HOME = $savedJavaHomeForProbe
        $env:PATH = $savedPathForProbe
    }
    $tests.Add('child-java-environment-routing')

    # The same Git-common lock excludes both same-target and cross-target builds.
    $firstLock = Enter-GlobalBuildLock
    try {
        $secondRejected = $false
        try {
            $secondLock = Enter-GlobalBuildLock
            $secondLock.Dispose()
        } catch {
            $secondRejected = $_.Exception.Message -like '*shared build lock*'
        }
        Assert-Test $secondRejected 'The shared build lock allowed a second owner.'
    } finally { $firstLock.Dispose() }
    $tests.Add('shared-lock')

    # The Stable evidence gate cannot be replaced between its hash check and load.
    $gateReadLock = Enter-ScriptReadLock $stableEvidenceGateScript
    try {
        $gateWriteRejected = $false
        try {
            $gateWriteProbe = [IO.File]::Open($stableEvidenceGateScript,
                [IO.FileMode]::Open, [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite)
            $gateWriteProbe.Dispose()
        } catch [IO.IOException] { $gateWriteRejected = $true }
        Assert-Test $gateWriteRejected `
            'The Stable evidence-gate read lock allowed concurrent mutation.'
    } finally { $gateReadLock.Dispose() }
    $tests.Add('stable-gate-load-locked')

    # Closing the Job Object terminates the direct child and its process tree.
    $job = [QuestCraftV71BuildJob]::new()
    $child = $job.Start(
        $env:ComSpec,
        @('/d', '/c', 'ping', '127.0.0.1', '-n', '30'),
        $temporaryRoot)
    try {
        Start-Sleep -Milliseconds 150
        $job.Dispose()
        Assert-Test ($child.WaitForExit(5000)) `
            'Closing the build Job Object did not terminate its child tree.'
    } finally {
        $job.Dispose()
        $child.Dispose()
    }
    $tests.Add('kill-on-job-close')

    # The retained native process handle reports the real exit code after exit.
    $exitJob = [QuestCraftV71BuildJob]::new()
    $exitChild = $exitJob.Start(
        $env:ComSpec,
        @('/d', '/c', 'exit', '7'),
        $temporaryRoot)
    try {
        $exitChild.WaitForExit()
        Assert-Test ($exitChild.ExitCode -eq 7) `
            'The build process wrapper did not retain the native exit code.'
    } finally {
        $exitChild.Dispose()
        $exitJob.Dispose()
    }
    $tests.Add('native-exit-code')

    # Failure with a prior APK restores all three exact inputs and is idempotent.
    $case = Join-Path $temporaryRoot 'rollback-prior'
    $journal = Initialize-Case $case $true
    [IO.File]::WriteAllText($pluginAar, 'MUTATED_AAR')
    [IO.File]::WriteAllText($projectSettings, 'MUTATED_SETTINGS')
    [IO.File]::WriteAllText($outputApk, 'PARTIAL_APK')
    $read = Read-TransactionJournal
    Restore-CheckedInInputs $read
    Restore-PreviousOutput $read
    Remove-CompletedTransactionGuard
    Assert-Test ((Get-Sha256 $pluginAar) -ceq [string]$journal.sourceAar.sha256) `
        'Rollback did not restore the source AAR.'
    Assert-Test ((Get-Sha256 $projectSettings) -ceq
        [string]$journal.projectSettings.sha256) `
        'Rollback did not restore ProjectSettings.'
    Assert-Test ((Get-Sha256 $outputApk) -ceq
        [string]$journal.previousOutput.sha256) `
        'Rollback did not restore the previous APK.'
    Assert-Test ((Restore-SourceAar).Result -ceq 'ALREADY_CLEAN') `
        'A second rollback was not idempotent.'
    $tests.Add('rollback-prior')

    # Failure with no prior APK removes only the partial canonical output.
    $case = Join-Path $temporaryRoot 'rollback-absent'
    $journal = Initialize-Case $case $false
    [IO.File]::WriteAllText($outputApk, 'PARTIAL_APK')
    $read = Read-TransactionJournal
    Restore-CheckedInInputs $read
    Restore-PreviousOutput $read
    Remove-CompletedTransactionGuard
    Assert-Test (-not (Test-Path -LiteralPath $outputApk)) `
        'Rollback retained an output that the journal recorded as initially absent.'
    $tests.Add('rollback-absent')

    # A hard stop during archive copy cannot poison the deterministic final archive.
    $case = Join-Path $temporaryRoot 'rollback-partial-archive'
    $journal = Initialize-Case $case $true
    [IO.File]::WriteAllText($outputApk, 'NEW_APK_BEFORE_INTERRUPTION')
    $archive = Get-PreviousOutputArchivePath ([string]$journal.previousOutput.sha256)
    [IO.File]::WriteAllText($archive + '.next', 'PARTIAL_ARCHIVE')
    $read = Read-TransactionJournal
    Restore-CheckedInInputs $read
    Restore-PreviousOutput $read
    Remove-CompletedTransactionGuard
    Assert-Test ((Get-Sha256 $outputApk) -ceq
        [string]$journal.previousOutput.sha256) `
        'Archive-copy interruption did not restore the previous APK.'
    Assert-Test (-not (Test-Path -LiteralPath ($archive + '.next'))) `
        'Archive-copy interruption left its transaction-owned partial file.'
    $tests.Add('rollback-partial-archive')

    # A verified success keeps the new APK and archives the authenticated prior APK.
    $case = Join-Path $temporaryRoot 'success-prior'
    $journal = Initialize-Case $case $true
    [IO.File]::WriteAllText($outputApk, 'NEW_VERIFIED_APK')
    $newHash = Get-Sha256 $outputApk
    $journal.newOutput.verified = $true
    $journal.newOutput.sha256 = $newHash
    $journal.newOutput.sizeBytes = (Get-Item -LiteralPath $outputApk).Length
    $journal.phase = 'verified'
    Write-TransactionJournal $journal
    Restore-CheckedInInputs $journal
    Archive-PreviousOutput $journal
    $archive = Get-PreviousOutputArchivePath ([string]$journal.previousOutput.sha256)
    Remove-CompletedTransactionGuard
    Assert-Test ((Get-Sha256 $outputApk) -ceq $newHash) `
        'Success finalization replaced the verified new APK.'
    Assert-Test ((Get-Sha256 $archive) -ceq [string]$journal.previousOutput.sha256) `
        'Success finalization did not archive the prior APK exactly.'
    $tests.Add('success-prior')

    # A complete atomic .next journal can be promoted after an interrupted swap.
    $case = Join-Path $temporaryRoot 'next-journal'
    $journal = Initialize-Case $case $false
    [IO.File]::Move($transactionJournal, $transactionJournal + '.next')
    $promoted = Read-TransactionJournal
    Assert-Test ([string]$promoted.phase -ceq 'prepared') `
        'A complete pending journal was not promoted.'
    Restore-CheckedInInputs $promoted
    Restore-PreviousOutput $promoted
    Remove-CompletedTransactionGuard
    $tests.Add('next-journal')

    [pscustomobject]@{
        Result = 'PASS'
        TestsPassed = $tests.Count
        Tests = @($tests)
        HostOnly = $true
        DeviceInvocations = 0
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = Get-CanonicalPath $temporaryRoot
        Assert-Test ($resolved.StartsWith(
            $canonicalTemp + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) `
            'Refusing unsafe recursive self-test cleanup.'
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
