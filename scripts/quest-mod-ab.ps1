<#
.SYNOPSIS
Safely A/B tests QuestCraft profile mods on a connected Quest.

.DESCRIPTION
Status is read-only. Disable and Restore refuse to run while any process owned by
the target QuestCraft package exists. A disabled JAR is moved to a dedicated
backup directory and replaced by a valid empty ZIP/JAR with no fabric.mod.json.
An adjacent marker records its fixed SHA-256. File.exists() remains true for the
launcher while Fabric ignores the placeholder. Restore refuses if either the
marker or the placeholder hash differs, including when the launcher replaced it.

The script never edits instances.json. Its SHA-256 is checked before and after
every toggle. It never force-stops, uninstalls, clears, or launches the app.

Measure reads only Meta's VrApi tag into memory and emits aggregate values.
Quest firmware may log VrApi performance rows under either the QuestCraft PID or
com.oculus.vrshell. The script tracks both as separate timelines, accepts only
their observed PIDs, reports the actual metric owner, and requires at least 95%
app presence so Home/launcher samples are not mistaken for game performance.
No raw log or account data is persisted.

.EXAMPLE
.\scripts\quest-mod-ab.ps1 -Action Status

.EXAMPLE
.\scripts\quest-mod-ab.ps1 -Action Disable -Mod 'EntityCulling.jar'

.EXAMPLE
.\scripts\quest-mod-ab.ps1 -Action Measure -Seconds 60

.EXAMPLE
.\scripts\quest-mod-ab.ps1 -Action Restore -Mod 'EntityCulling.jar'

.EXAMPLE
.\scripts\quest-mod-ab.ps1 -Action SelfTest
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Disable', 'Restore', 'Measure', 'SelfTest')]
    [string]$Action = 'Status',

    [string]$Mod,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string]$Serial = 'auto',

    [ValidatePattern('^[A-Za-z0-9._]+$')]
    [string]$Package = 'com.qcxr.qcxr.dev262',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Profile = '26.2',

    [ValidateRange(10, 1800)]
    [int]$Seconds = 60,

    [ValidateRange(1, 10)]
    [int]$PollSeconds = 1,

    [string]$AdbPath = 'adb'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:DeviceRoot = "/sdcard/Android/data/$Package/files"
$script:ModsDir = "$script:DeviceRoot/instances/$Profile/mods"
$script:InstancesFile = "$script:DeviceRoot/instances.json"
$script:BackupRoot = "/sdcard/Download/QuestCraft-Dev-Backups/mod-ab/$Package/$Profile"
$script:PlaceholderBase64 = 'UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA=='
$script:PlaceholderSha256 = '8739c76e681f900923b900c9df0ef75cf421d39cabb54650c4b9ad19b6a76d85'
$script:MarkerVersion = 'quest-mod-ab-placeholder-v2'

function ConvertTo-ShLiteral {
    param([Parameter(Mandatory)][string]$Value)

    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $escapedQuote = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $escapedQuote) + $singleQuote
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }

    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $sdkCandidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdkCandidate -PathType Leaf) {
        return $sdkCandidate
    }

    throw "ADB was not found. Pass -AdbPath with the full adb.exe path."
}

function Resolve-DeviceSerial {
    if ($Serial -ne 'auto') {
        return $Serial
    }

    $result = Invoke-Adb -Arguments @('devices')
    $devices = @(
        $result.Lines | ForEach-Object {
            if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') {
                $Matches.serial
            }
        }
    )

    if ($devices.Count -eq 0) {
        throw "No authorized ADB device is connected. Connect one or pass -Serial explicitly."
    }
    if ($devices.Count -gt 1) {
        throw "More than one authorized ADB device is connected. Pass -Serial explicitly."
    }

    return [string]$devices[0]
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& $script:ResolvedAdb @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if (($exitCode -ne 0) -and -not $AllowFailure) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "ADB failed with exit code $exitCode.`n$detail"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = @($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-DeviceShell {
    param(
        [Parameter(Mandatory)][string]$Command,
        [switch]$AllowFailure
    )

    return Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'shell', $Command) -AllowFailure:$AllowFailure
}

function Assert-DeviceReady {
    $state = Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'get-state')
    if ((($state.Lines -join '').Trim()) -ne 'device') {
        throw "Device $script:ResolvedSerial is not in the ADB 'device' state."
    }
}

function Get-ProcessSnapshot {
    $result = Invoke-DeviceShell -Command 'ps -A -o PID,NAME,ARGS'
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($line in $result.Lines) {
        if ($line -match '^\s*(?<pid>\d+)\s+(?<name>\S+)(?:\s+(?<args>.*))?$') {
            $rows.Add([pscustomobject]@{
                Pid = [int]$Matches.pid
                Name = [string]$Matches.name
                Args = [string]$Matches.args
            })
        }
    }

    return $rows.ToArray()
}

function Test-IsPackageProcess {
    param(
        [Parameter(Mandatory)]$Process,
        [Parameter(Mandatory)][string]$PackageName
    )

    if (($Process.Name -eq $PackageName) -or $Process.Name.StartsWith("${PackageName}:")) {
        return $true
    }

    $firstArg = (($Process.Args -split '\s+', 2)[0])
    return (($firstArg -eq $PackageName) -or $firstArg.StartsWith("${PackageName}:"))
}

function Get-PackageProcesses {
    param([Parameter(Mandatory)][object[]]$Snapshot)

    return @($Snapshot | Where-Object { Test-IsPackageProcess -Process $_ -PackageName $Package })
}

function Get-VrShellProcesses {
    param([Parameter(Mandatory)][object[]]$Snapshot)

    # Do not infer the compositor from the QuestCraft PID. VrApi metrics are
    # emitted by this exact Meta shell process on current Quest firmware.
    return @($Snapshot | Where-Object { Test-IsPackageProcess -Process $_ -PackageName 'com.oculus.vrshell' })
}

function Assert-AppStopped {
    $appProcesses = @(Get-PackageProcesses -Snapshot (Get-ProcessSnapshot))
    if ($appProcesses.Count -gt 0) {
        $description = ($appProcesses | ForEach-Object { "$($_.Pid):$($_.Name)" }) -join ', '
        throw "Refusing to change mods while $Package is running ($description). Exit QuestCraft normally, then retry. The script will not force-stop it."
    }
}

function Get-DeviceSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $quotedPath = ConvertTo-ShLiteral $Path
    $result = Invoke-DeviceShell -Command "sha256sum $quotedPath"
    $text = $result.Lines -join ' '
    if ($text -notmatch '(?i)\b(?<sha>[0-9a-f]{64})\b') {
        throw "Could not parse SHA-256 for $Path."
    }
    return $Matches.sha.ToLowerInvariant()
}

function Get-ModStatus {
    $mods = ConvertTo-ShLiteral $script:ModsDir
    $backups = ConvertTo-ShLiteral $script:BackupRoot
    $command = @"
if [ ! -d $mods ]; then
  echo 'ERROR|mods directory is missing'
  exit 22
fi
for p in $mods/*.jar; do
  [ -e "`$p" ] || continue
  n=`${p##*/}
  if [ -f "`$p" ]; then
    echo "FILE|`$n"
  elif [ -d "`$p" ]; then
    echo "DIRMARKER|`$n"
  fi
done
for p in $mods/*.jar.codex-ab-disabled; do
  [ -f "`$p" ] || continue
  n=`${p##*/}
  n=`${n%.codex-ab-disabled}
  echo "SIDEMARKER|`$n"
done
if [ -d $backups ]; then
  for p in $backups/*.jar; do
    [ -f "`$p" ] || continue
    n=`${p##*/}
    echo "BACKUP|`$n"
  done
fi
"@

    $result = Invoke-DeviceShell -Command $command
    $stateByName = @{}
    foreach ($line in $result.Lines) {
        if ($line -notmatch '^(FILE|DIRMARKER|SIDEMARKER|BACKUP)\|(.+\.jar)$') {
            continue
        }

        $kind = $Matches[1]
        $name = $Matches[2]
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._+() -]*\.jar$') {
            Write-Warning "Ignoring unsupported JAR filename returned by device: $name"
            continue
        }

        $key = $name.ToLowerInvariant()
        if (-not $stateByName.ContainsKey($key)) {
            $stateByName[$key] = [ordered]@{
                Mod = $name
                HasFile = $false
                HasDirMarker = $false
                HasSideMarker = $false
                HasBackup = $false
            }
        }
        switch ($kind) {
            'FILE' { $stateByName[$key].HasFile = $true }
            'DIRMARKER' { $stateByName[$key].HasDirMarker = $true }
            'SIDEMARKER' { $stateByName[$key].HasSideMarker = $true }
            'BACKUP' { $stateByName[$key].HasBackup = $true }
        }
    }

    $rows = foreach ($entry in $stateByName.Values) {
        $state = if ($entry.HasDirMarker) {
            'Legacy directory marker (unsafe; launcher can replace it)'
        } elseif ($entry.HasFile -and $entry.HasSideMarker -and $entry.HasBackup) {
            $placeholderPath = "$script:ModsDir/$($entry.Mod)"
            $markerPath = "$placeholderPath.codex-ab-disabled"
            $markerResult = Invoke-DeviceShell -Command "cat $(ConvertTo-ShLiteral $markerPath)"
            $actualMarker = (($markerResult.Lines -join '').Trim())
            $expectedMarker = "$script:MarkerVersion|$($entry.Mod)|$script:PlaceholderSha256"
            if ($actualMarker -ne $expectedMarker) {
                'Unsafe: side marker mismatch'
            } elseif ((Get-DeviceSha256 $placeholderPath) -ne $script:PlaceholderSha256) {
                'Unsafe: launcher replaced placeholder'
            } else {
                'Disabled'
            }
        } elseif ($entry.HasFile -and $entry.HasSideMarker) {
            'Invalid: side marker without managed backup'
        } elseif ($entry.HasFile -and $entry.HasBackup) {
            'Invalid: enabled file+backup without side marker'
        } elseif ($entry.HasFile) {
            'Enabled'
        } elseif ($entry.HasSideMarker) {
            'Invalid: side marker without placeholder'
        } elseif ($entry.HasBackup) {
            'Orphan backup'
        } else {
            'Unknown'
        }

        [pscustomobject]@{
            Mod = $entry.Mod
            State = $state
            ManagedBackup = [bool]$entry.HasBackup
        }
    }

    return @($rows | Sort-Object Mod)
}

function Resolve-ModEntry {
    param(
        [Parameter(Mandatory)][object[]]$Status,
        [Parameter(Mandatory)][string]$Requested
    )

    if (($Requested.Contains('/')) -or ($Requested.Contains('\')) -or ($Requested.Contains('..'))) {
        throw '-Mod must be a JAR basename or a unique part of one; paths are not accepted.'
    }

    $exact = @($Status | Where-Object { $_.Mod.Equals($Requested, [StringComparison]::OrdinalIgnoreCase) })
    if ($exact.Count -eq 1) {
        return $exact[0]
    }

    $matches = @($Status | Where-Object { $_.Mod.IndexOf($Requested, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($matches.Count -eq 0) {
        throw "No mod matched '$Requested'. Run -Action Status for exact names."
    }
    if ($matches.Count -gt 1) {
        throw "'$Requested' is ambiguous: $(($matches.Mod) -join ', '). Use the exact JAR name."
    }
    return $matches[0]
}

function Assert-InstancesUnchanged {
    param([Parameter(Mandatory)][string]$BeforeHash)

    $afterHash = Get-DeviceSha256 $script:InstancesFile
    if ($afterHash -ne $BeforeHash) {
        throw "Safety check failed: instances.json changed during the toggle. The script never writes it. Inspect external writers before another test. Before=$BeforeHash After=$afterHash"
    }
}

function Disable-Mod {
    if ([string]::IsNullOrWhiteSpace($Mod)) {
        throw '-Mod is required for Disable.'
    }

    Assert-AppStopped
    $status = Get-ModStatus
    $entry = Resolve-ModEntry -Status $status -Requested $Mod
    if ($entry.State -ne 'Enabled') {
        throw "$($entry.Mod) is not in the Enabled state (current: $($entry.State))."
    }

    $instancesBefore = Get-DeviceSha256 $script:InstancesFile
    $source = "$script:ModsDir/$($entry.Mod)"
    $backup = "$script:BackupRoot/$($entry.Mod)"
    $sidecar = "$backup.sha256"
    $placeholderTemp = "$source.codex-ab-placeholder.tmp"
    $marker = "$source.codex-ab-disabled"
    $markerTemp = "$marker.tmp"
    $sourceHash = Get-DeviceSha256 $source
    $markerContent = "$script:MarkerVersion|$($entry.Mod)|$script:PlaceholderSha256"

    $qSource = ConvertTo-ShLiteral $source
    $qBackup = ConvertTo-ShLiteral $backup
    $qSidecar = ConvertTo-ShLiteral $sidecar
    $qSidecarTemp = ConvertTo-ShLiteral "$sidecar.tmp"
    $qPlaceholderTemp = ConvertTo-ShLiteral $placeholderTemp
    $qMarker = ConvertTo-ShLiteral $marker
    $qMarkerTemp = ConvertTo-ShLiteral $markerTemp
    $qBackupRoot = ConvertTo-ShLiteral $script:BackupRoot
    $qName = ConvertTo-ShLiteral $entry.Mod
    $qHash = ConvertTo-ShLiteral $sourceHash
    $qPlaceholderBase64 = ConvertTo-ShLiteral $script:PlaceholderBase64
    $qPlaceholderHash = ConvertTo-ShLiteral $script:PlaceholderSha256
    $qMarkerContent = ConvertTo-ShLiteral $markerContent

    $command = @"
set -eu
test -f $qSource
command -v base64 >/dev/null
mkdir -p $qBackupRoot
test ! -e $qBackup
test ! -e $qSidecar
test ! -e $qSidecarTemp
test ! -e $qPlaceholderTemp
test ! -e $qMarker
test ! -e $qMarkerTemp
printf '%s' $qPlaceholderBase64 | base64 -d > $qPlaceholderTemp
generated=`$(sha256sum $qPlaceholderTemp)
test "`$`{generated%% *}" = $qPlaceholderHash
printf '%s\n' $qMarkerContent > $qMarkerTemp
printf '%s  %s\n' $qHash $qName > $qSidecarTemp
if ! mv $qSource $qBackup; then
  rm -f $qPlaceholderTemp $qMarkerTemp $qSidecarTemp
  exit 40
fi
if ! mv $qPlaceholderTemp $qSource; then
  mv $qBackup $qSource
  rm -f $qPlaceholderTemp $qMarkerTemp $qSidecarTemp
  exit 41
fi
if ! mv $qMarkerTemp $qMarker; then
  rm -f $qSource
  mv $qBackup $qSource
  rm -f $qPlaceholderTemp $qMarkerTemp $qSidecarTemp
  exit 42
fi
if ! mv $qSidecarTemp $qSidecar; then
  rm -f $qSource $qMarker
  mv $qBackup $qSource
  rm -f $qPlaceholderTemp $qMarkerTemp $qSidecarTemp
  exit 43
fi
"@

    Invoke-DeviceShell -Command $command | Out-Null

    $verify = Invoke-DeviceShell -Command "test -f $qSource && test -f $qMarker && test -f $qBackup"
    $null = $verify
    $backupHash = Get-DeviceSha256 $backup
    if ($backupHash -ne $sourceHash) {
        throw "Backup verification failed for $($entry.Mod): expected $sourceHash, got $backupHash."
    }
    $placeholderHash = Get-DeviceSha256 $source
    if ($placeholderHash -ne $script:PlaceholderSha256) {
        throw "Placeholder verification failed for $($entry.Mod): expected $script:PlaceholderSha256, got $placeholderHash."
    }
    $markerResult = Invoke-DeviceShell -Command "cat $qMarker"
    if ((($markerResult.Lines -join '').Trim()) -ne $markerContent) {
        throw "Side marker verification failed for $($entry.Mod)."
    }
    Assert-InstancesUnchanged -BeforeHash $instancesBefore

    [pscustomobject]@{
        Action = 'Disabled'
        Mod = $entry.Mod
        OriginalSha256 = $sourceHash
        PlaceholderSha256 = $placeholderHash
        Backup = $backup
        Placeholder = $source
        SideMarker = $marker
        InstancesJsonSha256 = $instancesBefore
    }
}

function Restore-Mod {
    if ([string]::IsNullOrWhiteSpace($Mod)) {
        throw '-Mod is required for Restore.'
    }

    Assert-AppStopped
    $status = Get-ModStatus
    $entry = Resolve-ModEntry -Status $status -Requested $Mod
    if ($entry.State -ne 'Disabled') {
        throw "$($entry.Mod) is not in the managed Disabled state (current: $($entry.State)). Restore accepts only backups created by this script."
    }

    $instancesBefore = Get-DeviceSha256 $script:InstancesFile
    $destination = "$script:ModsDir/$($entry.Mod)"
    $backup = "$script:BackupRoot/$($entry.Mod)"
    $sidecar = "$backup.sha256"
    $marker = "$destination.codex-ab-disabled"
    $placeholderTemp = "$destination.codex-ab-restore.tmp"
    $expectedMarker = "$script:MarkerVersion|$($entry.Mod)|$script:PlaceholderSha256"
    $qDestination = ConvertTo-ShLiteral $destination
    $qBackup = ConvertTo-ShLiteral $backup
    $qSidecar = ConvertTo-ShLiteral $sidecar
    $qMarker = ConvertTo-ShLiteral $marker
    $qPlaceholderTemp = ConvertTo-ShLiteral $placeholderTemp

    $currentPlaceholderHash = Get-DeviceSha256 $destination
    if ($currentPlaceholderHash -ne $script:PlaceholderSha256) {
        throw "Refusing restore: current $($entry.Mod) is not our placeholder. Expected $script:PlaceholderSha256, got $currentPlaceholderHash. The launcher may have replaced it; no file was changed."
    }
    $markerResult = Invoke-DeviceShell -Command "test -f $qMarker && cat $qMarker"
    $actualMarker = (($markerResult.Lines -join '').Trim())
    if ($actualMarker -ne $expectedMarker) {
        throw "Refusing restore: side marker does not match the placeholder contract for $($entry.Mod). No file was changed."
    }

    $sidecarResult = Invoke-DeviceShell -Command "test -f $qSidecar && head -n 1 $qSidecar"
    $sidecarText = $sidecarResult.Lines -join ' '
    if ($sidecarText -notmatch '(?i)^\s*(?<sha>[0-9a-f]{64})\b') {
        throw "Managed SHA-256 sidecar is missing or malformed for $($entry.Mod)."
    }
    $expectedHash = $Matches.sha.ToLowerInvariant()
    $actualHash = Get-DeviceSha256 $backup
    if ($actualHash -ne $expectedHash) {
        throw "Refusing restore: backup hash mismatch for $($entry.Mod). Expected $expectedHash, got $actualHash."
    }

    $command = @"
set -eu
test -f $qDestination
test -f $qMarker
test -f $qBackup
test ! -e $qPlaceholderTemp
mv $qDestination $qPlaceholderTemp
if ! mv $qBackup $qDestination; then
  mv $qPlaceholderTemp $qDestination
  exit 42
fi
rm $qPlaceholderTemp $qMarker $qSidecar
"@

    Invoke-DeviceShell -Command $command | Out-Null
    $restoredHash = Get-DeviceSha256 $destination
    if ($restoredHash -ne $expectedHash) {
        throw "Restore verification failed for $($entry.Mod): expected $expectedHash, got $restoredHash."
    }
    Assert-InstancesUnchanged -BeforeHash $instancesBefore

    [pscustomobject]@{
        Action = 'Restored'
        Mod = $entry.Mod
        Sha256 = $restoredHash
        Destination = $destination
        InstancesJsonSha256 = $instancesBefore
    }
}

function ConvertFrom-VrApiLine {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[int]]$AllowedPids
    )

    if ($Line -notmatch '^\s*\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+(?<pid>\d+)\s+\d+\s+[VDIWEF]\s+VrApi\s*:\s*(?<message>.*)$') {
        return $null
    }

    $parsedPid = [int]$Matches.pid
    $message = $Matches.message
    if (-not $AllowedPids.Contains($parsedPid)) {
        return $null
    }
    if ($message -notmatch '\bFPS=(?<fps>[0-9]+(?:\.[0-9]+)?)/(?<target>[0-9]+(?:\.[0-9]+)?)') {
        return $null
    }

    $sample = [ordered]@{
        Pid = $parsedPid
        Fps = [double]$Matches.fps
        TargetFps = [double]$Matches.target
        Stale = $null
        AppMs = $null
        GpuPercent = $null
        CpuPercent = $null
        TempC = $null
        FreeMB = $null
    }

    if ($message -match '\bStale=(?<value>[0-9]+)') {
        $sample.Stale = [int]$Matches.value
    }
    if ($message -match '\bApp=(?<value>[0-9]+(?:\.[0-9]+)?)ms') {
        $sample.AppMs = [double]$Matches.value
    }
    if ($message -match '\bGPU%=(?<value>[0-9]+(?:\.[0-9]+)?)') {
        $rawGpu = [double]$Matches.value
        $sample.GpuPercent = if ($rawGpu -le 1.5) { $rawGpu * 100.0 } else { $rawGpu }
    }
    if ($message -match '\bCPU%=(?<value>[0-9]+(?:\.[0-9]+)?)') {
        $rawCpu = [double]$Matches.value
        $sample.CpuPercent = if ($rawCpu -le 1.5) { $rawCpu * 100.0 } else { $rawCpu }
    }
    if ($message -match '\bTemp=(?<value>-?[0-9]+(?:\.[0-9]+)?)C') {
        $sample.TempC = [double]$Matches.value
    }
    if ($message -match '\bFree=(?<value>[0-9]+)MB') {
        $sample.FreeMB = [int]$Matches.value
    }

    return [pscustomobject]$sample
}

function Get-Percentile {
    param(
        [Parameter(Mandatory)][double[]]$Values,
        [Parameter(Mandatory)][ValidateRange(0.0, 1.0)][double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return $null
    }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [double]$sorted[0]
    }

    $position = ($sorted.Count - 1) * $Percentile
    $lower = [int][Math]::Floor($position)
    $upper = [int][Math]::Ceiling($position)
    if ($lower -eq $upper) {
        return [double]$sorted[$lower]
    }
    $weight = $position - $lower
    return ([double]$sorted[$lower] * (1.0 - $weight)) + ([double]$sorted[$upper] * $weight)
}

function Get-MeanOrNull {
    param([object[]]$Values)

    $present = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($present.Count -eq 0) {
        return $null
    }
    return [double](($present | Measure-Object -Average).Average)
}

function Get-VrApiSummary {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Samples
    )

    if ($Samples.Count -eq 0) {
        throw 'No VrApi FPS rows were captured from the observed QuestCraft or vrshell PID(s).'
    }

    $fps = [double[]]@($Samples | ForEach-Object { $_.Fps })
    $targetGroup = $Samples | Group-Object TargetFps | Sort-Object Count -Descending | Select-Object -First 1
    $staleValues = @($Samples | Where-Object { $null -ne $_.Stale } | ForEach-Object { [int]$_.Stale })

    return [ordered]@{
        VrApiSamples = $Samples.Count
        TargetFps = [Math]::Round([double]$targetGroup.Name, 2)
        MeanFps = [Math]::Round((Get-MeanOrNull $fps), 2)
        MedianFps = [Math]::Round((Get-Percentile -Values $fps -Percentile 0.50), 2)
        P10Fps = [Math]::Round((Get-Percentile -Values $fps -Percentile 0.10), 2)
        StaleTotal = if ($staleValues.Count -gt 0) { [int](($staleValues | Measure-Object -Sum).Sum) } else { $null }
        MeanAppMs = [Math]::Round((Get-MeanOrNull @($Samples.AppMs)), 2)
        MeanGpuPercent = [Math]::Round((Get-MeanOrNull @($Samples.GpuPercent)), 1)
        MeanCpuPercent = [Math]::Round((Get-MeanOrNull @($Samples.CpuPercent)), 1)
        MeanTempC = [Math]::Round((Get-MeanOrNull @($Samples.TempC)), 1)
        MeanFreeMB = [Math]::Round((Get-MeanOrNull @($Samples.FreeMB)), 0)
        MinFreeMB = if (@($Samples.FreeMB | Where-Object { $null -ne $_ }).Count -gt 0) {
            [int](($Samples.FreeMB | Where-Object { $null -ne $_ } | Measure-Object -Minimum).Minimum)
        } else { $null }
    }
}

function Get-MetricOwnerInfo {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Samples,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[int]]$AppPids,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[int]]$VrShellPids
    )

    $ownerPids = New-Object 'System.Collections.Generic.HashSet[int]'
    $hasAppOwner = $false
    $hasVrShellOwner = $false
    foreach ($sample in $Samples) {
        $samplePid = [int]$sample.Pid
        $null = $ownerPids.Add($samplePid)
        if ($AppPids.Contains($samplePid)) { $hasAppOwner = $true }
        if ($VrShellPids.Contains($samplePid)) { $hasVrShellOwner = $true }
    }

    $ownerType = if ($hasAppOwner -and $hasVrShellOwner) {
        'Mixed: QuestCraft app + com.oculus.vrshell'
    } elseif ($hasAppOwner) {
        'QuestCraft app'
    } elseif ($hasVrShellOwner) {
        'com.oculus.vrshell'
    } else {
        'Unknown (rejected ownership set)'
    }

    return [pscustomobject]@{
        Type = $ownerType
        Pids = (@($ownerPids) | Sort-Object) -join ','
    }
}

function ConvertFrom-CapturedVrApiLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[int]]$AppPids,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[int]]$VrShellPids
    )

    # This pure parser also accepts a previously captured in-memory/file line
    # array; callers must supply the PIDs observed during that capture.
    $allowedPids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($observedPid in $AppPids) { $null = $allowedPids.Add([int]$observedPid) }
    foreach ($observedPid in $VrShellPids) { $null = $allowedPids.Add([int]$observedPid) }

    $samples = New-Object System.Collections.Generic.List[object]
    foreach ($line in $Lines) {
        $sample = ConvertFrom-VrApiLine -Line $line -AllowedPids $allowedPids
        if ($null -ne $sample) { $samples.Add($sample) }
    }
    return $samples.ToArray()
}

function Measure-QuestCraft {
    $initialSnapshot = Get-ProcessSnapshot
    $initialApp = @(Get-PackageProcesses -Snapshot $initialSnapshot)
    if ($initialApp.Count -eq 0) {
        throw "$Package is not running. Start QuestCraft, enter the same test scene, then run Measure."
    }

    $startResult = Invoke-DeviceShell -Command "date '+%m-%d %H:%M:%S.%3N'"
    $logcatStart = (($startResult.Lines -join '').Trim())
    if ($logcatStart -notmatch '^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$') {
        throw "Could not read a logcat-compatible device timestamp: $logcatStart"
    }

    $observedAppPids = New-Object 'System.Collections.Generic.HashSet[int]'
    $observedVrShellPids = New-Object 'System.Collections.Generic.HashSet[int]'
    $appPidTimeline = New-Object System.Collections.Generic.List[string]
    $lastAppKey = $null
    $lastVrShellKey = $null
    $polls = 0
    $appPresentPolls = 0
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        $snapshot = Get-ProcessSnapshot
        $app = @(Get-PackageProcesses -Snapshot $snapshot)
        $vrShell = @(Get-VrShellProcesses -Snapshot $snapshot)
        $polls++
        if ($app.Count -gt 0) {
            $appPresentPolls++
        }

        foreach ($process in $app) { $null = $observedAppPids.Add([int]$process.Pid) }
        foreach ($process in $vrShell) { $null = $observedVrShellPids.Add([int]$process.Pid) }

        $appKey = (@($app.Pid | Sort-Object) -join ',')
        $vrShellKey = (@($vrShell.Pid | Sort-Object) -join ',')
        if (($appKey -ne $lastAppKey) -or ($vrShellKey -ne $lastVrShellKey)) {
            $elapsed = [Math]::Round($Seconds - [Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalSeconds), 1)
            $appPidTimeline.Add("+${elapsed}s app=[$appKey] vrshell=[$vrShellKey]")
            $lastAppKey = $appKey
            $lastVrShellKey = $vrShellKey
        }

        $remainingMs = [Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -gt 0) {
            Start-Sleep -Milliseconds ([int][Math]::Min($PollSeconds * 1000, $remainingMs))
        }
    }

    # One final process sample closes a PID transition at the end of the window.
    $finalSnapshot = Get-ProcessSnapshot
    foreach ($process in (Get-PackageProcesses -Snapshot $finalSnapshot)) { $null = $observedAppPids.Add([int]$process.Pid) }
    foreach ($process in (Get-VrShellProcesses -Snapshot $finalSnapshot)) { $null = $observedVrShellPids.Add([int]$process.Pid) }

    # Only the VrApi tag is read, only into memory. Firmware has emitted these
    # rows under both the app and vrshell across sessions, so use the union of
    # observed PIDs and report which owner(s) actually supplied samples.
    $logResult = Invoke-Adb -Arguments @(
        '-s', $script:ResolvedSerial, 'logcat', '-d', '-v', 'threadtime', '-T', $logcatStart,
        'VrApi:I', '*:S'
    )

    $samples = @(ConvertFrom-CapturedVrApiLines -Lines $logResult.Lines -AppPids $observedAppPids -VrShellPids $observedVrShellPids)

    $summary = Get-VrApiSummary -Samples $samples
    $metricOwner = Get-MetricOwnerInfo -Samples $samples -AppPids $observedAppPids -VrShellPids $observedVrShellPids
    $presencePercent = if ($polls -gt 0) { 100.0 * $appPresentPolls / $polls } else { 0.0 }
    $summary.DurationSeconds = $Seconds
    $summary.AppPresencePercent = [Math]::Round($presencePercent, 1)
    $summary.ValidForComparison = (($presencePercent -ge 95.0) -and ($samples.Count -ge [Math]::Max(5, [Math]::Floor($Seconds * 0.60))))
    $summary.AppPidsObserved = (@($observedAppPids) | Sort-Object) -join ','
    $summary.VrShellPidsObserved = (@($observedVrShellPids) | Sort-Object) -join ','
    $summary.MetricOwnerPids = $metricOwner.Pids
    $summary.MetricOwnerType = $metricOwner.Type
    $summary.PidTimeline = $appPidTimeline -join '; '
    $summary.MetricSource = 'VrApi rows restricted to observed QuestCraft app OR com.oculus.vrshell PID(s)'
    $summary.RawLogsPersisted = $false

    if ($presencePercent -lt 95.0) {
        Write-Warning "QuestCraft was present for only $([Math]::Round($presencePercent, 1))% of polls. Do not compare this run as an in-world benchmark."
    }

    return [pscustomobject]$summary
}

function Invoke-SelfTest {
    $appOwners = New-Object 'System.Collections.Generic.HashSet[int]'
    $null = $appOwners.Add(17986)
    $vrShellOwners = New-Object 'System.Collections.Generic.HashSet[int]'
    $null = $vrShellOwners.Add(20918)
    $lines = @(
        '08-28 01:00:01.000 17986 100 I VrApi   : FPS=40/72,Stale=2,Free=3900MB,Temp=42.0C/0.0C,App=12.00ms,GPU%=0.78,CPU%=0.57(W12)',
        '08-28 01:00:02.000 17986 100 I VrApi   : FPS=50/72,Stale=1,Free=3800MB,Temp=43.0C/0.0C,App=10.00ms,GPU%=0.80,CPU%=0.60(W10)',
        '08-28 01:00:03.000 20918 100 I VrApi   : FPS=55/72,Stale=0,Free=3700MB,Temp=44.0C/0.0C,App=8.00ms,GPU%=0.82,CPU%=0.63(W8)',
        '08-28 01:00:04.000 20918 100 I VrApi   : FPS=60/72,Stale=0,Free=3600MB,Temp=45.0C/0.0C,App=6.00ms,GPU%=0.84,CPU%=0.66(W6)',
        '08-28 01:00:05.000 99999 100 I VrApi   : FPS=1/72,Stale=99,Free=1MB,Temp=99.0C/0.0C,App=99.00ms,GPU%=1.00,CPU%=1.00(W99)'
    )

    $samples = @(ConvertFrom-CapturedVrApiLines -Lines $lines -AppPids $appOwners -VrShellPids $vrShellOwners)
    $summary = Get-VrApiSummary -Samples $samples
    $mixedOwner = Get-MetricOwnerInfo -Samples $samples -AppPids $appOwners -VrShellPids $vrShellOwners
    $appOwner = Get-MetricOwnerInfo -Samples @($samples | Where-Object Pid -eq 17986) -AppPids $appOwners -VrShellPids $vrShellOwners
    $vrShellOwner = Get-MetricOwnerInfo -Samples @($samples | Where-Object Pid -eq 20918) -AppPids $appOwners -VrShellPids $vrShellOwners
    $emptySamples = @(ConvertFrom-CapturedVrApiLines -Lines ([string[]]@()) -AppPids $appOwners -VrShellPids $vrShellOwners)
    if ($emptySamples.Count -ne 0) {
        throw "SelfTest failed: an empty Logcat capture produced $($emptySamples.Count) sample(s)."
    }
    $emptySummaryRejected = $false
    try {
        $null = Get-VrApiSummary -Samples ([object[]]@())
    } catch {
        if ($_.Exception.Message -ne 'No VrApi FPS rows were captured from the observed QuestCraft or vrshell PID(s).') {
            throw
        }
        $emptySummaryRejected = $true
    }
    if (-not $emptySummaryRejected) {
        throw 'SelfTest failed: an empty VrApi sample set was not rejected with the intended diagnostic.'
    }
    $assertions = @(
        @{ Name = 'PID scope'; Actual = $samples.Count; Expected = 4 },
        @{ Name = 'Target FPS'; Actual = $summary.TargetFps; Expected = 72.0 },
        @{ Name = 'Mean FPS'; Actual = $summary.MeanFps; Expected = 51.25 },
        @{ Name = 'Median FPS'; Actual = $summary.MedianFps; Expected = 52.5 },
        @{ Name = 'P10 FPS'; Actual = $summary.P10Fps; Expected = 43.0 },
        @{ Name = 'Stale total'; Actual = $summary.StaleTotal; Expected = 3 },
        @{ Name = 'Mean App ms'; Actual = $summary.MeanAppMs; Expected = 9.0 },
        @{ Name = 'Mean GPU percent'; Actual = $summary.MeanGpuPercent; Expected = 81.0 },
        @{ Name = 'Mean CPU percent'; Actual = $summary.MeanCpuPercent; Expected = 61.5 },
        @{ Name = 'Mean temperature'; Actual = $summary.MeanTempC; Expected = 43.5 },
        @{ Name = 'Minimum free MB'; Actual = $summary.MinFreeMB; Expected = 3600 }
    )

    foreach ($assertion in $assertions) {
        if ([double]$assertion.Actual -ne [double]$assertion.Expected) {
            throw "SelfTest failed: $($assertion.Name). Expected $($assertion.Expected), got $($assertion.Actual)."
        }
    }
    if (($mixedOwner.Type -ne 'Mixed: QuestCraft app + com.oculus.vrshell') -or ($mixedOwner.Pids -ne '17986,20918')) {
        throw "SelfTest failed: mixed metric ownership was '$($mixedOwner.Type)' PIDs '$($mixedOwner.Pids)'."
    }
    if (($appOwner.Type -ne 'QuestCraft app') -or ($appOwner.Pids -ne '17986')) {
        throw "SelfTest failed: app-owned metric path was '$($appOwner.Type)' PIDs '$($appOwner.Pids)'."
    }
    if (($vrShellOwner.Type -ne 'com.oculus.vrshell') -or ($vrShellOwner.Pids -ne '20918')) {
        throw "SelfTest failed: vrshell-owned metric path was '$($vrShellOwner.Type)' PIDs '$($vrShellOwner.Pids)'."
    }

    $quoted = ConvertTo-ShLiteral "a'b"
    if ($quoted -ne "'a'`"'`"'b'") {
        throw "SelfTest failed: shell quoting result was $quoted"
    }

    $placeholderBytes = [Convert]::FromBase64String($script:PlaceholderBase64)
    if (($placeholderBytes.Length -ne 22) -or ($placeholderBytes[0] -ne 0x50) -or ($placeholderBytes[1] -ne 0x4b)) {
        throw 'SelfTest failed: placeholder is not the expected minimal ZIP container.'
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $computedPlaceholderHash = ([BitConverter]::ToString($sha256.ComputeHash($placeholderBytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    if ($computedPlaceholderHash -ne $script:PlaceholderSha256) {
        throw "SelfTest failed: placeholder hash expected $script:PlaceholderSha256, got $computedPlaceholderHash."
    }

    Add-Type -AssemblyName System.IO.Compression
    $memoryStream = New-Object IO.MemoryStream(,$placeholderBytes)
    try {
        $zip = New-Object IO.Compression.ZipArchive($memoryStream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            if ($zip.Entries.Count -ne 0) {
                throw 'SelfTest failed: placeholder ZIP must contain no entries, especially no fabric.mod.json.'
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $memoryStream.Dispose()
    }

    [pscustomobject]@{
        Result = 'PASS'
        Assertions = $assertions.Count + 9
        PlaceholderSha256 = $script:PlaceholderSha256
        RawLogsPersisted = $false
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    exit 0
}

$script:ResolvedAdb = Resolve-Adb
$script:ResolvedSerial = Resolve-DeviceSerial
Assert-DeviceReady

switch ($Action) {
    'Status' {
        Get-ModStatus | Format-Table -AutoSize
    }
    'Disable' {
        Disable-Mod | Format-List
    }
    'Restore' {
        Restore-Mod | Format-List
    }
    'Measure' {
        Measure-QuestCraft | Format-List
    }
}
