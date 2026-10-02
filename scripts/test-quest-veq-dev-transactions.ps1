[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mainScript = Join-Path $PSScriptRoot 'quest-veq-dev.ps1'
$bashHarness = Join-Path $PSScriptRoot 'test-quest-veq-dev-transactions.sh'
$asset = Join-Path (Split-Path -Parent $PSScriptRoot) `
        'Pojlib\src\main\assets\mods\vivecraft-essentials-quest.bin'

# Dot-source the production generator in its offline action. SelfTest is
# contractually ADB-free and leaves the command-generator functions available.
. $mainScript -Action SelfTest | Out-Null

$bashCandidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')
)
$bash = @($bashCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($bash)) {
    throw 'Git Bash is required for the local VEQ transaction fault harness.'
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('quest-veq-fault-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
try {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $instancesLocal = Join-Path $temporaryDirectory 'instances.json'
    [IO.File]::WriteAllText($instancesLocal, "{`"instances`":[]}`n", $utf8)
    $instancesSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $instancesLocal).Hash.ToUpperInvariant()
    $disabledInstancesLocal = Join-Path $temporaryDirectory 'instances-disabled.json'
    [IO.File]::WriteAllText($disabledInstancesLocal,
            "{`"instances`":[{`"disabledMods`":[`"Vivecraft-Essentials-Quest`"]}]}`n", $utf8)
    $disabledInstancesSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $disabledInstancesLocal).Hash.ToUpperInvariant()

    $fixtureRoot = "/tmp/quest-veq-fault-$PID"
    $filesDir = "$fixtureRoot/files"
    $gameDir = "$filesDir/game"
    $stateDir = "$gameDir/.questcraft/veq-dev"
    $transactionId = '0123456789abcdef0123456789abcdef'
    $state = [pscustomobject]@{
        FilesDir = $filesDir
        InstancesPath = "$filesDir/instances.json"
        GameDir = $gameDir
        ModsDir = "$gameDir/mods"
        StateDir = $stateDir
        ManagedPath = "$gameDir/mods/Vivecraft-Essentials-Quest.jar"
        DevPath = "$gameDir/mods/veq-dev.jar"
        InstancesSha256 = $instancesSha
    }
    $managedBackup = "$stateDir/managed-v66.bin"
    $lockDir = "$stateDir/mutation.lock"
    $tokenPath = "$lockDir/token"
    $fixtureLock = [pscustomobject]@{
        Path = $lockDir
        TokenPath = $tokenPath
        Token = $transactionId
    }
    $state = Set-StateMutationLockContract -State $state -Lock $fixtureLock
    $disabledState = [pscustomobject]@{
        FilesDir = $state.FilesDir
        InstancesPath = $state.InstancesPath
        GameDir = $state.GameDir
        ModsDir = $state.ModsDir
        StateDir = $state.StateDir
        ManagedPath = $state.ManagedPath
        DevPath = $state.DevPath
        InstancesSha256 = $disabledInstancesSha
    }
    $disabledState = Set-StateMutationLockContract -State $disabledState -Lock $fixtureLock

    $shaB = 'B' * 64
    $previous = "$stateDir/previous.bin"
    $previousSha = "$stateDir/previous.sha256"
    $candidateStage = "$stateDir/candidate-$transactionId.tmp"
    $restorePlan = [pscustomobject]@{
        ManagedWasPresent = $false
        ManagedBackup = $managedBackup
        ManagedCreated = $true
        DevWasPresent = $true
        DevSha256 = $shaB
        Retired = "$stateDir/retired-$($shaB.Substring(0, 12)).bin"
        RetiredExists = $false
        LauncherReconciliationRequired = $false
    }
    $commands = [ordered]@{
        'instances-commit.sh' = New-InstancesCommitCommand -State $state `
                -BeforeSha256 $instancesSha -AfterSha256 $disabledInstancesSha `
                -RemoteStage "$stateDir/instances-$transactionId.tmp" `
                -Backup "$stateDir/backups/instances-$transactionId-$instancesSha.json" `
                -BackupStage "$stateDir/backups/instances-$transactionId-$instancesSha.json.tmp" `
                -RestoreStage "$stateDir/instances-restore-$transactionId.tmp" `
                -TransactionId $transactionId
        'instances-rollback.sh' = New-InstancesRollbackCommand -State $state `
                -BeforeSha256 $instancesSha -AfterSha256 $disabledInstancesSha `
                -Backup "$stateDir/backups/instances-$transactionId-$instancesSha.json" `
                -RestoreStage "$stateDir/backups/instances-rollback-$transactionId.tmp" `
                -CurrentStage "$stateDir/backups/instances-current-$transactionId.tmp" `
                -TransactionId $transactionId
        'deploy-active.sh' = New-DeployTransactionCommand -State $state -CandidateSha256 $shaB `
                -Stage $candidateStage -CurrentSha256 $instancesSha -Previous $previous `
                -PreviousShaFile $previousSha -TransactionId $transactionId
        'deploy-empty.sh' = New-DeployTransactionCommand -State $state -CandidateSha256 $shaB `
                -Stage $candidateStage -CurrentSha256 $null -Previous $previous `
                -PreviousShaFile $previousSha -TransactionId $transactionId
        'rollback.sh' = New-RollbackTransactionCommand -State $state -CurrentSha256 $instancesSha `
                -PreviousSha256 $shaB -Previous $previous -PreviousShaFile $previousSha `
                -TransactionId $transactionId
        'restore-files.sh' = New-RestoreManagedFilesCommand -State $state -Plan $restorePlan `
                -TransactionId $transactionId
        'undo-restore.sh' = New-UndoRestoreManagedFilesCommand -State $state -Commit $restorePlan `
                -ExpectedInstancesSha256 $instancesSha -TransactionId $transactionId
        'managed-remove.sh' = New-ManagedRemoveCommand -State $state -ManagedBackup $managedBackup `
                -TransactionId $transactionId
        'managed-remove-disabled.sh' = New-ManagedRemoveCommand -State $disabledState `
                -ManagedBackup $managedBackup -TransactionId $transactionId
        'lock-acquire.sh' = New-MutationLockAcquireCommand -GameDir $gameDir -StateDir $stateDir `
                -LockDir $lockDir -TokenPath $tokenPath -Token $transactionId
    }
    $generatedShellFiles = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $commands.GetEnumerator()) {
        $path = Join-Path $temporaryDirectory $entry.Key
        [IO.File]::WriteAllText($path, [string]$entry.Value + "`n", $utf8)
        $generatedShellFiles.Add($path)
    }

    $syntaxFiles = @($bashHarness) + $generatedShellFiles.ToArray()
    foreach ($shellFile in $syntaxFiles) {
        & $bash '-n' $shellFile
        if ($LASTEXITCODE -ne 0) {
            throw "bash -n rejected $shellFile."
        }
    }

    & $bash $bashHarness $temporaryDirectory $asset $instancesLocal $disabledInstancesLocal `
            $fixtureRoot $syntaxFiles.Count
    if ($LASTEXITCODE -ne 0) {
        throw "VEQ fault harness failed with exit code $LASTEXITCODE."
    }
} finally {
    if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
        [IO.Directory]::Delete($temporaryDirectory, $true)
    }
}
