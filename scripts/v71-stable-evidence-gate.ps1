#requires -Version 7.0
<#
.SYNOPSIS
Validates the evidence required before building v71 Stable.

.DESCRIPTION
This file has no ADB, build, mutation, or receipt-generation path. It checks
evidence produced elsewhere and locked by path and SHA-256. The manual receipt
must be recorded from an explicit user confirmation; this validator can check
that receipt but cannot create the user's claim.
#>

Set-StrictMode -Version Latest

$script:V71ExpectedMemoryProducerSha256 = `
    'C6FE7345ACE4978599A4C15FA5AAA846A3AE664A9AB5485215F72AFD4DF41202'
$script:V71LegacyRoundOneMemoryProducerSha256 = `
    'FD443A5E4A1D63BDBBFA648B4BE57C694B5121BA3E98D6E25A58D8B0E8311ED9'
$script:V71LegacyRoundOneTrustedStart = `
    [DateTimeOffset]::Parse('2026-09-06T09:16:23+03:00')
$script:V71ExpectedPerformanceProducerSha256 = `
    '85989A3DE0DB2509CC093145F103E1AB6FE6FB88E0048C361662EB6F274428F7'
$script:V71ExpectedMemoryContractProducerSha256 = `
    'FAC04DEAE071822EE1B0BD817DB11667DE58E4A72147BD58C1EB92D5942D1C7C'
$script:V71ExpectedLifecycleProducerSha256 = `
    'E285F01F2B8F4808E01DEFA44789687EF9FD70370908D785D298247DEA07A4CF'
$script:V71PerformanceProducerHashScheme = 'sha256-utf8-normalized-lf'
$script:V71ExpectedPerformanceDependencyHashes = [ordered]@{
    'pair-harness' = '00BD9A413AB1E0C7204FE423F91A028E923D75F622E17155848A2B5897D15D45'
    'core-canary-harness' = '65A3747FFA684CB1DA2EB185ED775CFE6FD96FA91B929D5D22746003EF13933A'
    'veq-lab-harness' = '3FC8993C2BD6C94921344C8D104CD481DF388CB0B77FF7D238D3B45D851368F5'
    'world-reset-harness' = 'DE0500CA3CEEBAE2A371B257F191AC09DC6746147D47F48E53F262BAAA0F4726'
    'autoplay-harness' = '261E6881B334DECD8CB41A640F1EE765E024278FC677128B472234C923CD7196'
    'vrapi-benchmark-harness' = '8FC046C6239E30823BB2B9408D1F0B3FD0B689C9A3F7B39FB8CFAFD0D211EE33'
    'apk-verifier' = 'C84E0CB9179D0D04086C8C5A2AC623BCA670040D58D0289E7174AE5A49130CA5'
}
$script:V71ExpectedLifecycleDependencyHashes = [ordered]@{
    'autoplay-harness' = '261E6881B334DECD8CB41A640F1EE765E024278FC677128B472234C923CD7196'
}

function Require-V71Evidence {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_STABLE_EVIDENCE] $Message" }
}

function Get-V71EvidenceProperty {
    param($Object, [string] $Name, [string] $Context)
    Require-V71Evidence ($null -ne $Object) "$Context is absent."
    $property = $Object.PSObject.Properties[$Name]
    Require-V71Evidence ($null -ne $property) "$Context.$Name is absent."
    return $property.Value
}

function ConvertTo-V71Sha256 {
    param($Value, [string] $Context)
    Require-V71Evidence ($Value -is [string]) "$Context is not a string."
    $normalized = ([string]$Value).ToUpperInvariant()
    Require-V71Evidence ($normalized -cmatch '^[0-9A-F]{64}$') `
        "$Context is not a canonical SHA-256."
    return $normalized
}

function Get-V71FileSha256 {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-V71TextProducerSha256 {
    param([string] $Path, [string] $Context = 'text producer')
    Require-V71Evidence (Test-Path -LiteralPath $Path -PathType Leaf) `
        "$Context file is missing."
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw "[V71_STABLE_EVIDENCE] $Context is not strict UTF-8 text: $($_.Exception.Message)"
    }
    Require-V71Evidence (-not $text.StartsWith([string][char]0xFEFF,
        [StringComparison]::Ordinal)) "$Context must not contain a UTF-8 BOM."
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($normalized)))
}

function Enter-V71ProducerReadLock {
    param([string] $Path, [string] $Context = 'producer')
    Require-V71Evidence (Test-Path -LiteralPath $Path -PathType Leaf) `
        "$Context file is missing."
    $item = Get-Item -LiteralPath $Path -Force
    Require-V71Evidence (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        "$Context must not be a reparse point."
    try {
        return [IO.File]::Open($item.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
    } catch {
        throw "[V71_STABLE_EVIDENCE] Failed to lock $Context for reading: $($_.Exception.Message)"
    }
}

function Get-V71ProducerLineageDigest {
    param([object[]] $Files)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("scheme=$script:V71PerformanceProducerHashScheme")
    foreach ($file in $Files) {
        $name = [string](Get-V71EvidenceProperty $file 'Name' 'producer-lineage file')
        $path = [string](Get-V71EvidenceProperty $file 'RelativePath' 'producer-lineage file')
        $sha = ConvertTo-V71Sha256 `
            (Get-V71EvidenceProperty $file 'Sha256' 'producer-lineage file') `
            "producer-lineage file $name SHA-256"
        $lines.Add(('{0}|{1}|{2}' -f $name, $path, $sha))
    }
    $payload = ($lines -join "`n") + "`n"
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($payload)))
}

function Assert-V71PerformanceProducerLineage {
    param($Lineage, [string] $ExpectedOrchestratorSha256, [string] $Context)
    $schema = [int](Get-V71EvidenceProperty $Lineage 'SchemaVersion' $Context)
    $scheme = [string](Get-V71EvidenceProperty $Lineage 'HashScheme' $Context)
    Require-V71Evidence ($schema -eq 1 -and
        $scheme -ceq $script:V71PerformanceProducerHashScheme) `
        "$Context schema/hash scheme drifted."
    $files = @(Get-V71EvidenceProperty $Lineage 'Files' $Context)
    $expected = @(
        [pscustomobject]@{ Name = 'orchestrator'; RelativePath = 'scripts/quest-v71-rc2-rc3-ab.ps1'; Sha256 = (ConvertTo-V71Sha256 $ExpectedOrchestratorSha256 'expected A/B orchestrator SHA-256') }
        [pscustomobject]@{ Name = 'pair-harness'; RelativePath = 'scripts/quest-v70-lab-pair.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['pair-harness'] }
        [pscustomobject]@{ Name = 'core-canary-harness'; RelativePath = 'scripts/quest-vivecraft-core-canary.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['core-canary-harness'] }
        [pscustomobject]@{ Name = 'veq-lab-harness'; RelativePath = 'scripts/quest-veq-lab.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['veq-lab-harness'] }
        [pscustomobject]@{ Name = 'world-reset-harness'; RelativePath = 'scripts/reset-lab-benchmark-world.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['world-reset-harness'] }
        [pscustomobject]@{ Name = 'autoplay-harness'; RelativePath = 'scripts/run-vivecraft-local-autoplay.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['autoplay-harness'] }
        [pscustomobject]@{ Name = 'vrapi-benchmark-harness'; RelativePath = 'scripts/quest-vrapi-pid-benchmark.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['vrapi-benchmark-harness'] }
        [pscustomobject]@{ Name = 'apk-verifier'; RelativePath = 'scripts/verify-dev-apk.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['apk-verifier'] }
    )
    Require-V71Evidence ($files.Count -eq $expected.Count) `
        "$Context does not contain the complete producer closure."
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $actual = $files[$index]
        $name = [string](Get-V71EvidenceProperty $actual 'Name' "$Context file[$index]")
        $path = [string](Get-V71EvidenceProperty $actual 'RelativePath' "$Context file[$index]")
        $sha = ConvertTo-V71Sha256 `
            (Get-V71EvidenceProperty $actual 'Sha256' "$Context file[$index]") `
            "$Context file[$index] SHA-256"
        Require-V71Evidence ($name -ceq [string]$expected[$index].Name -and
            $path -ceq [string]$expected[$index].RelativePath -and
            $sha -ceq [string]$expected[$index].Sha256) `
            "$Context file[$index] drifted from the reviewed producer closure."
    }
    $digest = ConvertTo-V71Sha256 `
        (Get-V71EvidenceProperty $Lineage 'DigestSha256' $Context) `
        "$Context digest SHA-256"
    Require-V71Evidence ($digest -ceq (Get-V71ProducerLineageDigest $files)) `
        "$Context digest does not match its producer files."
    return $digest
}

function Assert-V71LifecycleProducerLineage {
    param($Lineage, [string] $ExpectedOrchestratorSha256, [string] $Context)
    $schema = [int](Get-V71EvidenceProperty $Lineage 'schemaVersion' $Context)
    $scheme = [string](Get-V71EvidenceProperty $Lineage 'hashScheme' $Context)
    Require-V71Evidence ($schema -eq 1 -and
        $scheme -ceq $script:V71PerformanceProducerHashScheme) `
        "$Context schema/hash scheme drifted."
    $files = @(Get-V71EvidenceProperty $Lineage 'files' $Context)
    $expected = @(
        [pscustomobject]@{
            Name = 'lifecycle-orchestrator'
            RelativePath = 'scripts/quest-v71-lab-lifecycle-recovery.ps1'
            Sha256 = ConvertTo-V71Sha256 $ExpectedOrchestratorSha256 `
                'expected lifecycle/recovery orchestrator SHA-256'
        }
        [pscustomobject]@{
            Name = 'autoplay-harness'
            RelativePath = 'scripts/run-vivecraft-local-autoplay.ps1'
            Sha256 = $script:V71ExpectedLifecycleDependencyHashes['autoplay-harness']
        }
    )
    Require-V71Evidence ($files.Count -eq $expected.Count) `
        "$Context does not contain the complete producer closure."
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $actual = $files[$index]
        $name = [string](Get-V71EvidenceProperty $actual 'name' "$Context file[$index]")
        $path = [string](Get-V71EvidenceProperty $actual 'relativePath' "$Context file[$index]")
        $sha = ConvertTo-V71Sha256 `
            (Get-V71EvidenceProperty $actual 'sha256' "$Context file[$index]") `
            "$Context file[$index] SHA-256"
        Require-V71Evidence ($name -ceq [string]$expected[$index].Name -and
            $path -ceq [string]$expected[$index].RelativePath -and
            $sha -ceq [string]$expected[$index].Sha256) `
            "$Context file[$index] drifted from the reviewed producer closure."
    }
    $digest = ConvertTo-V71Sha256 `
        (Get-V71EvidenceProperty $Lineage 'digestSha256' $Context) `
        "$Context digest SHA-256"
    Require-V71Evidence ($digest -ceq (Get-V71ProducerLineageDigest $files)) `
        "$Context digest does not match its producer files."
    return $digest
}

function Read-V71EvidenceJson {
    param([string] $Path, [string] $Context)
    try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        throw "[V71_STABLE_EVIDENCE] $Context is not valid JSON: $($_.Exception.Message)"
    }
}

function Read-V71EvidenceJsonText {
    param([string] $Text, [string] $Context)
    try {
        return $Text | ConvertFrom-Json
    } catch {
        throw "[V71_STABLE_EVIDENCE] $Context is not valid JSON: $($_.Exception.Message)"
    }
}

function Test-V71ExactTrue { param($Value); return $Value -is [bool] -and $Value }
function Test-V71ExactFalse { param($Value); return $Value -is [bool] -and -not $Value }

function Assert-V71Timestamp {
    param($Value, [string] $Context)
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]([DateTime]$Value) }
    Require-V71Evidence ($Value -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$Value)) "$Context is absent."
    $parsed = [DateTimeOffset]::MinValue
    $valid = [DateTimeOffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed)
    Require-V71Evidence $valid "$Context is not an ISO-8601 timestamp."
    return $parsed
}

function Assert-V71NoReparsePath {
    param([string] $Path, [string] $Root, [string] $Context)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    Require-V71Evidence ($pathFull.StartsWith(
        $rootFull + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) "$Context escapes the evidence root."
    $cursor = Get-Item -LiteralPath $pathFull -Force
    while ($null -ne $cursor -and
            $cursor.FullName.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        Require-V71Evidence (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
            "$Context traverses a reparse point."
        if ($cursor.FullName -ceq $rootFull) { break }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
}

function Resolve-V71LockedEvidenceFile {
    param(
        [string] $WorkspaceRoot,
        $RelativePath,
        $ExpectedSha256,
        [string[]] $RequiredPrefix,
        [string] $RequiredLeaf,
        [string] $Context
    )
    Require-V71Evidence ($RelativePath -is [string]) "$Context path is absent."
    $relative = [string]$RelativePath
    Require-V71Evidence ($relative -cmatch '^(?:artifacts|work/agent-v70-integration/artifacts)/[A-Za-z0-9._/-]+\.jsonl?$' -and
        -not $relative.Contains('\') -and -not $relative.Contains('//')) `
        "$Context path is not a canonical workspace-relative JSON path."
    $segments = @($relative.Split('/'))
    Require-V71Evidence (@($segments | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -eq 0) `
        "$Context path contains traversal."
    $prefixMatched = @($RequiredPrefix | Where-Object {
        $relative.StartsWith($_, [StringComparison]::Ordinal)
    }).Count -gt 0
    Require-V71Evidence ($prefixMatched -and
        [IO.Path]::GetFileName($relative) -ceq $RequiredLeaf) `
        "$Context path is outside its dedicated evidence area."
    $full = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot ($relative -replace '/', '\')))
    Require-V71Evidence (Test-Path -LiteralPath $full -PathType Leaf) "$Context file is missing."
    Assert-V71NoReparsePath -Path $full -Root $WorkspaceRoot -Context $Context
    $lockedHash = ConvertTo-V71Sha256 -Value $ExpectedSha256 -Context "$Context SHA-256"
    $readLock = $null
    try {
        $readLock = [IO.File]::Open($full, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $length = $readLock.Length
        Require-V71Evidence ($length -ge 0 -and $length -le 64MB) `
            "$Context exceeds the evidence size limit."
        $bytes = [byte[]]::new([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $readLock.Read($bytes, $offset, $bytes.Length - $offset)
            Require-V71Evidence ($count -gt 0) "$Context ended while reading locked bytes."
            $offset += $count
        }
        $actualHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes))
        Require-V71Evidence ($actualHash -ceq $lockedHash) `
            "$Context changed after it was locked."
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        } catch {
            throw "[V71_STABLE_EVIDENCE] $Context is not strict UTF-8: $($_.Exception.Message)"
        }
        Require-V71Evidence (-not $text.StartsWith([string][char]0xFEFF,
            [StringComparison]::Ordinal)) "$Context must not contain a UTF-8 BOM."
        return [pscustomobject]@{
            Path = $full
            Sha256 = $lockedHash
            RelativePath = $relative
            Text = $text
            ReadLock = $readLock
        }
    } catch {
        if ($null -ne $readLock) { $readLock.Dispose() }
        throw
    }
}

function Assert-V71LabIdentityContract {
    param($Identity)
    $package = [string]$(Get-V71EvidenceProperty $Identity 'package' 'labIdentity')
    $stable = [string]$(Get-V71EvidenceProperty $Identity 'forbiddenStablePackage' 'labIdentity')
    $versionCode = [int]$(Get-V71EvidenceProperty $Identity 'versionCode' 'labIdentity')
    $versionName = [string]$(Get-V71EvidenceProperty $Identity 'versionName' 'labIdentity')
    $apkHash = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $Identity 'apkSha256' 'labIdentity') 'Lab APK SHA-256'
    $apkSize = [int64]$(Get-V71EvidenceProperty $Identity 'apkSizeBytes' 'labIdentity')
    $coreHash = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $Identity 'coreSha256' 'labIdentity') 'Core SHA-256'
    $veqHash = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $Identity 'veqSha256' 'labIdentity') 'VEQ SHA-256'
    $signer = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $Identity 'signerSha256' 'labIdentity') 'Signer SHA-256'
    Require-V71Evidence ($package -ceq 'com.qcxr.qcxr.canary262') 'Lab package identity drifted.'
    Require-V71Evidence ($stable -ceq 'com.qcxr.qcxr.dev262') 'Stable package guard drifted.'
    Require-V71Evidence ($versionCode -eq 71) 'Lab versionCode drifted.'
    Require-V71Evidence ($versionName -ceq '6.0.1-26.2-vivecraft-personal.12-rc.3') `
        'Lab versionName drifted.'
    Require-V71Evidence ($apkHash -ceq 'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F') `
        'Lab APK identity drifted.'
    Require-V71Evidence ($apkSize -eq 128431385L) 'Lab APK size drifted.'
    Require-V71Evidence ($coreHash -ceq '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26') `
        'Vivecraft RC3 identity drifted.'
    Require-V71Evidence ($veqHash -ceq '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B') `
        'VEQ identity drifted.'
    Require-V71Evidence ($signer -ceq 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A') `
        'Lab signer identity drifted.'
}

function Assert-V71StableAcceptanceManifestContract {
    param($Manifest, [switch] $RequireAccepted)
    $schema = [int]$(Get-V71EvidenceProperty $Manifest 'schemaVersion' 'acceptance manifest')
    Require-V71Evidence ($schema -eq 1) 'Unsupported Stable acceptance schema.'
    $identity = Get-V71EvidenceProperty $Manifest 'labIdentity' 'acceptance manifest'
    Assert-V71LabIdentityContract $identity
    $status = [string]$(Get-V71EvidenceProperty $Manifest 'status' 'acceptance manifest')
    if ($RequireAccepted) {
        Require-V71Evidence ($status -ceq 'ACCEPTED_FOR_STABLE_BUILD') `
            'Stable evidence status is not ACCEPTED_FOR_STABLE_BUILD.'
    } else {
        Require-V71Evidence ($status -cin @('PENDING_EVIDENCE', 'ACCEPTED_FOR_STABLE_BUILD')) `
            'Stable evidence status is invalid.'
    }
    $producers = Get-V71EvidenceProperty $Manifest 'producerScripts' 'acceptance manifest'
    foreach ($name in @(
        'memorySoakSha256', 'memoryRuntimeContractSha256', 'performanceHarnessSha256',
        'lifecycleRecoverySha256')) {
        $value = Get-V71EvidenceProperty $producers $name 'producerScripts'
        if ($RequireAccepted) {
            $null = ConvertTo-V71Sha256 $value "producerScripts.$name"
        } elseif ($null -ne $value) {
            $null = ConvertTo-V71Sha256 $value "producerScripts.$name"
        }
    }
    $soaks = @(Get-V71EvidenceProperty $Manifest 'memorySoaks' 'acceptance manifest')
    Require-V71Evidence ($soaks.Count -eq 2) 'Exactly two memory-soak locks are required.'
    for ($index = 0; $index -lt $soaks.Count; $index++) {
        $producer = Get-V71EvidenceProperty $soaks[$index] 'producerSha256' `
            "memorySoaks[$index]"
        if ($RequireAccepted) {
            $null = ConvertTo-V71Sha256 $producer "memorySoaks[$index].producerSha256"
        } elseif ($null -ne $producer) {
            $null = ConvertTo-V71Sha256 $producer "memorySoaks[$index].producerSha256"
        }
    }
    $performance = Get-V71EvidenceProperty $Manifest 'performance' 'acceptance manifest'
    $reports = @(Get-V71EvidenceProperty $performance 'reports' 'performance')
    Require-V71Evidence ($reports.Count -eq 6) 'Exactly six retained A/B report locks are required.'
    $lifecycle = Get-V71EvidenceProperty $Manifest 'lifecycleRecovery' `
        'acceptance manifest'
    $memoryContract = Get-V71EvidenceProperty $Manifest 'memoryRuntimeContract' `
        'acceptance manifest'
    $manual = Get-V71EvidenceProperty $Manifest 'manual' 'acceptance manifest'
    if ($RequireAccepted) {
        foreach ($entry in $soaks) {
            foreach ($pair in @(
                @('summaryPath', 'summarySha256'),
                @('samplesPath', 'samplesSha256'))) {
                $path = Get-V71EvidenceProperty $entry $pair[0] 'memorySoak'
                $hash = Get-V71EvidenceProperty $entry $pair[1] 'memorySoak'
                Require-V71Evidence ($path -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($path)) `
                    "A memory-soak field $($pair[0]) is pending."
                $null = ConvertTo-V71Sha256 $hash "memory-soak $($pair[1])"
            }
        }
        foreach ($field in @('runManifestPath', 'runManifestSha256',
                'comparisonPath', 'comparisonSha256')) {
            $value = Get-V71EvidenceProperty $performance $field 'performance'
            Require-V71Evidence ($null -ne $value) "Performance evidence field $field is pending."
        }
        foreach ($field in @('receiptPath', 'receiptSha256')) {
            $value = Get-V71EvidenceProperty $lifecycle $field 'lifecycleRecovery'
            Require-V71Evidence ($null -ne $value) `
                "Lifecycle/recovery evidence field $field is pending."
        }
        foreach ($field in @('receiptPath', 'receiptSha256')) {
            $value = Get-V71EvidenceProperty $memoryContract $field `
                'memoryRuntimeContract'
            Require-V71Evidence ($null -ne $value) `
                "Memory runtime contract field $field is pending."
        }
        foreach ($field in @('receiptPath', 'receiptSha256')) {
            $value = Get-V71EvidenceProperty $manual $field 'manual'
            Require-V71Evidence ($null -ne $value) "Manual evidence field $field is pending."
        }
        foreach ($report in $reports) {
            $path = Get-V71EvidenceProperty $report 'path' 'performance report'
            $hash = Get-V71EvidenceProperty $report 'sha256' 'performance report'
            Require-V71Evidence ($path -is [string] -and
                -not [string]::IsNullOrWhiteSpace($path)) `
                'A retained A/B report path is pending.'
            $null = ConvertTo-V71Sha256 $hash 'retained A/B report SHA-256'
        }
    }
}

function Assert-V71MemorySummary {
    param($Summary, [string] $Context)
    $schema = [int]$(Get-V71EvidenceProperty $Summary 'schemaVersion' $Context)
    $package = [string]$(Get-V71EvidenceProperty $Summary 'package' $Context)
    $duration = [int]$(Get-V71EvidenceProperty $Summary 'requestedDurationMinutes' $Context)
    $interval = [int]$(Get-V71EvidenceProperty $Summary 'intervalSeconds' $Context)
    $samples = [int]$(Get-V71EvidenceProperty $Summary 'samples' $Context)
    $minimum = [int]$(Get-V71EvidenceProperty $Summary 'minimumExpectedSamples' $Context)
    $complete = [int]$(Get-V71EvidenceProperty $Summary 'completeMetricSamples' $Context)
    $processId = [int]$(Get-V71EvidenceProperty $Summary 'initialPid' $Context)
    Require-V71Evidence ($schema -eq 1 -and $package -ceq 'com.qcxr.qcxr.canary262') `
        "$Context identity/schema drifted."
    Require-V71Evidence ($duration -eq 90 -and $interval -eq 300) `
        "$Context did not run the locked 90-minute/5-minute protocol."
    Require-V71Evidence ($samples -eq 19 -and $minimum -eq 19 -and $complete -eq $samples) `
        "$Context is incomplete."
    Require-V71Evidence ($processId -gt 0) "$Context has no valid initial PID."
    foreach ($field in @('pidStable', 'focusStayedOnLab', 'gameJvmStayedAlive')) {
        $value = Get-V71EvidenceProperty $Summary $field $Context
        Require-V71Evidence (Test-V71ExactTrue $value) "$Context failed $field."
    }
    $provenance = Get-V71EvidenceProperty $Summary 'provenance' $Context
    foreach ($field in @('installedIdentityMatched', 'baseApkMatched',
            'persistentCoreMatched', 'persistentVeqMatched', 'allMatched')) {
        $value = Get-V71EvidenceProperty $provenance $field "$Context.provenance"
        Require-V71Evidence (Test-V71ExactTrue $value) "$Context provenance failed $field."
    }
    $started = Assert-V71Timestamp $(Get-V71EvidenceProperty $Summary 'startedUtc' $Context) `
        "$Context.startedUtc"
    $null = Assert-V71Timestamp $(Get-V71EvidenceProperty $provenance 'verifiedUtc' "$Context.provenance") `
        "$Context.provenance.verifiedUtc"
    $deviceReads = [int]$(Get-V71EvidenceProperty $Summary 'deviceInvocations' $Context)
    Require-V71Evidence ($deviceReads -gt 0) "$Context contains no device-read evidence."
    $maxPss = ConvertTo-V71FiniteNumber $(Get-V71EvidenceProperty $Summary 'maxPssMib' $Context) "$Context maxPssMib"
    $maxRss = ConvertTo-V71FiniteNumber $(Get-V71EvidenceProperty $Summary 'maxRssMib' $Context) "$Context maxRssMib"
    $maxSwap = ConvertTo-V71FiniteNumber $(Get-V71EvidenceProperty $Summary 'maxProcessSwapMib' $Context) "$Context maxProcessSwapMib"
    $slope = ConvertTo-V71FiniteNumber $(Get-V71EvidenceProperty $Summary 'postWarmPssSlopeMibPerMinute' $Context) "$Context post-warm slope" -AllowNegative
    $lastThirty = ConvertTo-V71FiniteNumber $(Get-V71EvidenceProperty $Summary 'lastThirtyMinutesGrowthMib' $Context) "$Context last-30-minute growth" -AllowNegative
    Require-V71Evidence ($maxPss -le 2457.6) "$Context exceeded the 2.4-GiB PSS guardrail."
    Require-V71Evidence ($maxRss -le 2457.6) "$Context exceeded the 2.4-GiB RSS guardrail."
    Require-V71Evidence ($maxSwap -le 512.0) "$Context exceeded the process-swap guardrail."
    Require-V71Evidence ($slope -le 2.0) "$Context exceeded the post-warm growth guardrail."
    Require-V71Evidence ($lastThirty -le 128.0) "$Context exceeded the final-30-minute guardrail."
    $acceptance = Get-V71EvidenceProperty $Summary 'acceptance' $Context
    foreach ($field in @('completedDuration', 'sampleCountComplete',
            'allRequiredMetricsPresent', 'focusStayedOnLab', 'gameJvmStayedAlive',
            'postWarmSamplesComplete', 'lastThirtySamplesComplete',
            'maxPssAtMost2457Point6Mib', 'maxRssAtMost2457Point6Mib',
            'processSwapAtMost512Mib', 'slopeAtMost2MibPerMinute',
            'lastThirtyGrowthAtMost128Mib', 'passed')) {
        $value = Get-V71EvidenceProperty $acceptance $field "$Context.acceptance"
        Require-V71Evidence (Test-V71ExactTrue $value) "$Context acceptance failed $field."
    }
    return $started
}

function ConvertTo-V71FiniteNumber {
    param($Value, [string] $Context, [switch] $AllowNegative)
    Require-V71Evidence ($null -ne $Value) "$Context is null."
    $isJsonNumber = $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
    Require-V71Evidence $isJsonNumber "$Context is not a JSON number."
    try { $number = [double]$Value } catch {
        throw "[V71_STABLE_EVIDENCE] $Context is not numeric."
    }
    Require-V71Evidence (-not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number)) "$Context is not finite."
    if (-not $AllowNegative) {
        Require-V71Evidence ($number -ge 0.0) "$Context is negative."
    }
    return $number
}

function Get-V71PssSlope {
    param([object[]] $Samples)
    Require-V71Evidence ($Samples.Count -ge 2) 'Too few samples for a PSS slope.'
    $meanX = ($Samples | Measure-Object elapsedMinutes -Average).Average
    $meanY = ($Samples | ForEach-Object { $_.totalPssKib / 1024.0 } |
        Measure-Object -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    foreach ($sample in $Samples) {
        $dx = [double]$sample.elapsedMinutes - $meanX
        $dy = ([double]$sample.totalPssKib / 1024.0) - $meanY
        $numerator += $dx * $dy
        $denominator += $dx * $dx
    }
    Require-V71Evidence ($denominator -gt 0.0) 'Memory sample times cannot produce a slope.'
    return [math]::Round($numerator / $denominator, 3)
}

function Assert-V71RoundedEqual {
    param($Reported, [double] $Recomputed, [string] $Context)
    $reportedNumber = ConvertTo-V71FiniteNumber $Reported $Context -AllowNegative
    Require-V71Evidence ([math]::Abs($reportedNumber - $Recomputed) -le 0.0011) `
        "$Context does not match the locked raw samples."
}

function Assert-V71MemorySummaryAgainstSamples {
    param($Summary, [string] $SamplesText, [string] $Context)
    $lines = @($SamplesText -split "`r?`n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    $summaryCount = [int]$(Get-V71EvidenceProperty $Summary 'samples' $Context)
    Require-V71Evidence ($lines.Count -eq 19 -and $lines.Count -eq $summaryCount) `
        "$Context raw sample count does not match its summary."
    $expectedPid = [int]$(Get-V71EvidenceProperty $Summary 'initialPid' $Context)
    $summaryStarted = Assert-V71Timestamp `
        $(Get-V71EvidenceProperty $Summary 'startedUtc' $Context) "$Context.startedUtc"
    $requiredMetrics = @(
        'totalPssKib', 'totalRssKib', 'javaHeapKib', 'nativeHeapKib',
        'graphicsKib', 'vmRssKib', 'vmSwapKib', 'memAvailableKib', 'swapFreeKib')
    $samples = [Collections.Generic.List[object]]::new()
    $previousElapsed = -1.0
    $previousTimestamp = [DateTimeOffset]::MinValue
    for ($index = 0; $index -lt $lines.Count; $index++) {
        try { $raw = $lines[$index] | ConvertFrom-Json } catch {
            throw "[V71_STABLE_EVIDENCE] $Context sample $index is invalid JSON."
        }
        $elapsed = ConvertTo-V71FiniteNumber `
            $(Get-V71EvidenceProperty $raw 'elapsedMinutes' "$Context sample $index") `
            "$Context sample $index elapsedMinutes"
        $timestamp = Assert-V71Timestamp `
            $(Get-V71EvidenceProperty $raw 'timestampUtc' "$Context sample $index") `
            "$Context sample $index timestampUtc"
        $timestampElapsed = ($timestamp - $summaryStarted).TotalMinutes
        Require-V71Evidence ([math]::Abs($timestampElapsed - $elapsed) -le 0.05) `
            "$Context sample $index timestamp and elapsedMinutes identify different captures."
        Require-V71Evidence ($elapsed -gt $previousElapsed -and $timestamp -gt $previousTimestamp) `
            "$Context sample order is not strictly monotonic."
        $previousElapsed = $elapsed
        $previousTimestamp = $timestamp
        $samplePid = [int]$(Get-V71EvidenceProperty $raw 'pid' "$Context sample $index")
        Require-V71Evidence ($samplePid -eq $expectedPid -and
            (Test-V71ExactTrue $(Get-V71EvidenceProperty $raw 'pidStable' "$Context sample $index")) -and
            [string]$(Get-V71EvidenceProperty $raw 'focus' "$Context sample $index") -ceq 'focused' -and
            (Test-V71ExactTrue $(Get-V71EvidenceProperty $raw 'gameJvmAlive' "$Context sample $index"))) `
            "$Context sample $index lost PID, focus, or the game JVM."
        $normalized = [ordered]@{ elapsedMinutes = $elapsed }
        foreach ($metric in $requiredMetrics) {
            $normalized[$metric] = ConvertTo-V71FiniteNumber `
                $(Get-V71EvidenceProperty $raw $metric "$Context sample $index") `
                "$Context sample $index $metric"
        }
        Require-V71Evidence ($normalized.totalPssKib -gt 0.0 -and
            $normalized.totalRssKib -gt 0.0 -and $normalized.vmRssKib -gt 0.0 -and
            $normalized.memAvailableKib -gt 0.0) `
            "$Context sample $index contains impossible zero process/system memory."
        $samples.Add([pscustomobject]$normalized)
    }
    Require-V71Evidence ($samples[0].elapsedMinutes -le 1.0 -and
        $samples[-1].elapsedMinutes -ge 90.0) `
        "$Context raw samples do not span the full 90-minute protocol."
    $postWarm = @($samples | Where-Object elapsedMinutes -ge 15.0)
    $lastThirty = @($samples | Where-Object elapsedMinutes -ge 60.0)
    Require-V71Evidence ($postWarm.Count -ge 16 -and $lastThirty.Count -ge 7) `
        "$Context raw analysis windows are incomplete."
    $maxPss = [math]::Round((($samples | Measure-Object totalPssKib -Maximum).Maximum / 1024.0), 3)
    $maxRss = [math]::Round((($samples | Measure-Object vmRssKib -Maximum).Maximum / 1024.0), 3)
    $maxSwap = [math]::Round((($samples | Measure-Object vmSwapKib -Maximum).Maximum / 1024.0), 3)
    $minAvailable = [math]::Round((($samples | Measure-Object memAvailableKib -Minimum).Minimum / 1024.0), 3)
    $minSwapFree = [math]::Round((($samples | Measure-Object swapFreeKib -Minimum).Minimum / 1024.0), 3)
    $slope = Get-V71PssSlope $postWarm
    $lastGrowth = [math]::Round(
        ($lastThirty[-1].totalPssKib - $lastThirty[0].totalPssKib) / 1024.0, 3)
    Assert-V71RoundedEqual $(Get-V71EvidenceProperty $Summary 'maxPssMib' $Context) $maxPss "$Context maxPssMib"
    Assert-V71RoundedEqual $(Get-V71EvidenceProperty $Summary 'maxRssMib' $Context) $maxRss "$Context maxRssMib"
    Assert-V71RoundedEqual $(Get-V71EvidenceProperty $Summary 'maxProcessSwapMib' $Context) $maxSwap "$Context maxProcessSwapMib"
    Assert-V71RoundedEqual $(Get-V71EvidenceProperty $Summary 'minMemAvailableMib' $Context) $minAvailable "$Context minMemAvailableMib"
    Assert-V71RoundedEqual $(Get-V71EvidenceProperty $Summary 'minSwapFreeMib' $Context) $minSwapFree "$Context minSwapFreeMib"
    Assert-V71RoundedEqual $(Get-V71EvidenceProperty $Summary 'postWarmPssSlopeMibPerMinute' $Context) $slope "$Context postWarm slope"
    Assert-V71RoundedEqual $(Get-V71EvidenceProperty $Summary 'lastThirtyMinutesGrowthMib' $Context) $lastGrowth "$Context last-30-minute growth"
    Require-V71Evidence ($maxPss -le 2457.6 -and $maxRss -le 2457.6 -and
        $maxSwap -le 512.0 -and $slope -le 2.0 -and $lastGrowth -le 128.0) `
        "$Context recomputed raw metrics fail a Stable memory guardrail."
}

function Assert-V71PerformanceEvidence {
    param($Manifest, $Comparison, [string] $ExpectedPerformanceProducerSha256)
    $schema = [int]$(Get-V71EvidenceProperty $Manifest 'SchemaVersion' 'A/B manifest')
    $package = [string]$(Get-V71EvidenceProperty $Manifest 'Package' 'A/B manifest')
    $stable = [string]$(Get-V71EvidenceProperty $Manifest 'ForbiddenStablePackage' 'A/B manifest')
    $profile = [string]$(Get-V71EvidenceProperty $Manifest 'Profile' 'A/B manifest')
    $world = [string]$(Get-V71EvidenceProperty $Manifest 'World' 'A/B manifest')
    Require-V71Evidence ($schema -eq 2 -and $package -ceq 'com.qcxr.qcxr.canary262' -and
        $stable -ceq 'com.qcxr.qcxr.dev262' -and $profile -ceq '26.2' -and
        $world -ceq 'FPS-Stress-Test') 'A/B manifest identity drifted.'
    $worldHash = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $Manifest 'WorldMasterSha256' 'A/B manifest') 'A/B world SHA-256'
    Require-V71Evidence ($worldHash -ceq '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90') `
        'A/B benchmark world drifted.'
    $installed = Get-V71EvidenceProperty $Manifest 'InstalledApk' 'A/B manifest'
    $installedPackage = [string]$(Get-V71EvidenceProperty $installed 'Package' 'A/B installed APK')
    $versionCode = [string]$(Get-V71EvidenceProperty $installed 'VersionCode' 'A/B installed APK')
    $versionName = [string]$(Get-V71EvidenceProperty $installed 'VersionName' 'A/B installed APK')
    $apkHash = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $installed 'Sha256' 'A/B installed APK') 'A/B APK SHA-256'
    $signer = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $installed 'SignerSha256' 'A/B installed APK') 'A/B signer SHA-256'
    Require-V71Evidence ($installedPackage -ceq 'com.qcxr.qcxr.canary262' -and
        $versionCode -ceq '71' -and
        $versionName -ceq '6.0.1-26.2-vivecraft-personal.12-rc.3' -and
        $apkHash -ceq 'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F' -and
        $signer -ceq 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A') `
        'A/B installed APK identity drifted.'
    $a = Get-V71EvidenceProperty $Manifest 'ConditionA' 'A/B manifest'
    $b = Get-V71EvidenceProperty $Manifest 'ConditionB' 'A/B manifest'
    $aCore = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $a 'CoreSha256' 'A/B condition A') 'RC2 Core SHA-256'
    $aVeq = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $a 'VeqSha256' 'A/B condition A') 'RC2 VEQ SHA-256'
    $bCore = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $b 'CoreSha256' 'A/B condition B') 'RC3 Core SHA-256'
    $bVeq = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $b 'VeqSha256' 'A/B condition B') 'RC3 VEQ SHA-256'
    Require-V71Evidence ($aCore -ceq 'AAC5852BD1495AA0121A078F87312A644608F209A9190AE539CDC4F7763CD8FC' -and
        $aVeq -ceq '8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A' -and
        $bCore -ceq '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26' -and
        $bVeq -ceq '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B') `
        'A/B condition payloads drifted.'
    $producerLineageDigest = Assert-V71PerformanceProducerLineage `
        (Get-V71EvidenceProperty $Manifest 'ProducerLineage' 'A/B manifest') `
        $ExpectedPerformanceProducerSha256 'A/B manifest producer lineage'
    $order = @(Get-V71EvidenceProperty $Manifest 'Order' 'A/B manifest') -join '-'
    $warmup = [int]$(Get-V71EvidenceProperty $Manifest 'WarmupSeconds' 'A/B manifest')
    $preflight = [int]$(Get-V71EvidenceProperty $Manifest 'PreflightSeconds' 'A/B manifest')
    $sample = [int]$(Get-V71EvidenceProperty $Manifest 'SampleSeconds' 'A/B manifest')
    Require-V71Evidence ($order -ceq 'A1-B1-B2-A2-A3-B3' -and $warmup -ge 300 -and
        $preflight -eq 10 -and $sample -eq 60) 'A/B order or timing contract drifted.'
    $gates = Get-V71EvidenceProperty $Manifest 'Gates' 'A/B manifest'
    $minimumCoverage = [double]$(Get-V71EvidenceProperty $gates 'MinimumCoveragePercent' 'A/B gates')
    $minimumLevel4 = [double]$(Get-V71EvidenceProperty $gates 'MinimumLevel4Percent' 'A/B gates')
    $cpuLevel = [int]$(Get-V71EvidenceProperty $gates 'CpuLevel' 'A/B gates')
    $gpuLevel = [int]$(Get-V71EvidenceProperty $gates 'GpuLevel' 'A/B gates')
    $maximumRegression = [double]$(Get-V71EvidenceProperty $gates 'MaximumPersistentRegressionPercent' 'A/B gates')
    Require-V71Evidence ($minimumCoverage -eq 95.0 -and $minimumLevel4 -eq 95.0 -and
        $cpuLevel -eq 4 -and $gpuLevel -eq 4 -and $maximumRegression -eq 2.0) `
        'A/B coverage, QGO, or regression gate drifted.'
    $lease = Get-V71EvidenceProperty $Manifest 'PerformanceLevelLease' 'A/B manifest'
    $leaseScope = [string]$(Get-V71EvidenceProperty $lease 'Scope' 'A/B performance-level lease')
    $targetCpu = [int]$(Get-V71EvidenceProperty $lease 'TargetCpuLevel' 'A/B performance-level lease')
    $targetGpu = [int]$(Get-V71EvidenceProperty $lease 'TargetGpuLevel' 'A/B performance-level lease')
    $originalCpuSet = Get-V71EvidenceProperty $lease 'OriginalCpuLevelSet' 'A/B performance-level lease'
    $originalGpuSet = Get-V71EvidenceProperty $lease 'OriginalGpuLevelSet' 'A/B performance-level lease'
    $originalCpu = Get-V71EvidenceProperty $lease 'OriginalCpuLevel' 'A/B performance-level lease'
    $originalGpu = Get-V71EvidenceProperty $lease 'OriginalGpuLevel' 'A/B performance-level lease'
    Require-V71Evidence ($leaseScope -ceq 'Lab campaign only' -and
        $targetCpu -eq 4 -and $targetGpu -eq 4 -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $lease 'ApplyAfterWorldReady' 'A/B performance-level lease')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $lease 'VerifyBeforeWarmup' 'A/B performance-level lease')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $lease 'RestoreEveryRoundAndOuterFinally' 'A/B performance-level lease')) -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $lease 'RefreshPropertiesModified' 'A/B performance-level lease')) -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $lease 'AdaptivePropertiesModified' 'A/B performance-level lease'))) `
        'A/B performance-level lease escaped its fixed Lab-only 4/4 boundary.'
    foreach ($entry in @(
        [pscustomobject]@{ Set = $originalCpuSet; Value = $originalCpu; Name = 'CPU' },
        [pscustomobject]@{ Set = $originalGpuSet; Value = $originalGpu; Name = 'GPU' }
    )) {
        if (Test-V71ExactTrue $entry.Set) {
            $level = ConvertTo-V71FiniteNumber $entry.Value "A/B original $($entry.Name) level"
            Require-V71Evidence ($level -ge 0.0 -and $level -le 99.0 -and
                [Math]::Floor($level) -eq $level) `
                "A/B original $($entry.Name) level is not a bounded integer."
        } else {
            Require-V71Evidence ((Test-V71ExactFalse $entry.Set) -and $null -eq $entry.Value) `
                "A/B unset original $($entry.Name) level was not represented as null."
        }
    }
    $qgo = [string]$(Get-V71EvidenceProperty $Manifest 'QgoContract' 'A/B manifest')
    $finalState = [string]$(Get-V71EvidenceProperty $Manifest 'FinalState' 'A/B manifest')
    Require-V71Evidence ($qgo -ceq 'Dynamic refresh; CPU/GPU 4/4; application requests neither refresh nor performance hint' -and
        $finalState -ceq 'Lab stopped on exact RC3 Core+VEQ pair; original CPU/GPU levels restored') `
        'A/B QGO or final-state contract drifted.'
    Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty $Manifest 'StableTouched' 'A/B manifest')) `
        'A/B manifest reports Stable was touched.'
    Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty $Manifest 'RawLogsPersisted' 'A/B manifest')) `
        'A/B manifest unexpectedly persisted raw logs.'

    $comparisonSchema = [int]$(Get-V71EvidenceProperty $Comparison 'SchemaVersion' 'A/B comparison')
    $result = [string]$(Get-V71EvidenceProperty $Comparison 'Result' 'A/B comparison')
    $passed = Get-V71EvidenceProperty $Comparison 'PerformanceGatePassed' 'A/B comparison'
    $comparisonApk = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $Comparison 'InstalledApkSha256' 'A/B comparison') 'A/B comparison APK SHA-256'
    $comparisonLineage = ConvertTo-V71Sha256 `
        $(Get-V71EvidenceProperty $Comparison 'ProducerLineageSha256' 'A/B comparison') `
        'A/B comparison producer-lineage SHA-256'
    $comparisonOrder = @(Get-V71EvidenceProperty $Comparison 'Order' 'A/B comparison') -join '-'
    Require-V71Evidence ($comparisonSchema -eq 1 -and
        $result -ceq 'PASS_RC3_NO_PERSISTENT_REGRESSION' -and
        (Test-V71ExactTrue $passed) -and
        $comparisonApk -ceq 'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F' -and
        $comparisonLineage -ceq $producerLineageDigest -and
        $comparisonOrder -ceq 'A1-B1-B2-A2-A3-B3') 'A/B comparison did not pass the exact RC3 gate.'
    $pairs = @(Get-V71EvidenceProperty $Comparison 'Pairs' 'A/B comparison')
    Require-V71Evidence ($pairs.Count -eq 3) 'A/B comparison does not contain three pairs.'
    $pairNumbers = @()
    $computedPairPasses = 0
    foreach ($pair in $pairs) {
        $pairNumbers += [int]$(Get-V71EvidenceProperty $pair 'Pair' 'A/B pair')
        $comparable = Get-V71EvidenceProperty $pair 'Comparable' 'A/B pair'
        Require-V71Evidence (Test-V71ExactTrue $comparable) 'An A/B pair is not comparable.'
        $guardrail = Get-V71EvidenceProperty $pair 'GuardrailsPass' 'A/B pair'
        if (Test-V71ExactTrue $guardrail) { $computedPairPasses++ }
    }
    Require-V71Evidence ((@($pairNumbers | Sort-Object -Unique) -join '-') -ceq '1-2-3') `
        'A/B pair numbering is missing or duplicated.'
    $aggregate = Get-V71EvidenceProperty $Comparison 'Aggregate' 'A/B comparison'
    $aggregatePass = Get-V71EvidenceProperty $aggregate 'AggregateGuardrailsPass' 'A/B aggregate'
    $pairPasses = [int]$(Get-V71EvidenceProperty $aggregate 'PairGuardrailPassCount' 'A/B aggregate')
    $persistent = Get-V71EvidenceProperty $aggregate 'PersistentMetricRegression' 'A/B aggregate'
    $threshold = [double]$(Get-V71EvidenceProperty $aggregate 'MaximumRegressionPercent' 'A/B aggregate')
    Require-V71Evidence ((Test-V71ExactTrue $aggregatePass) -and $pairPasses -ge 2 -and
        $pairPasses -eq $computedPairPasses -and
        (Test-V71ExactFalse $persistent) -and $threshold -eq 2.0) `
        'A/B aggregate or persistent-regression guardrail failed.'
    Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty $Comparison 'StableTouched' 'A/B comparison')) `
        'A/B comparison reports Stable was touched.'
    Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty $Comparison 'RawLogsPersisted' 'A/B comparison')) `
        'A/B comparison unexpectedly persisted raw logs.'
    return $producerLineageDigest
}

function Get-V71CanonicalJson {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 32 -Compress)
}

function Assert-V71PerformanceReaggregation {
    param(
        [string] $PerformanceHarnessPath,
        [string] $CampaignDirectory,
        $LockedComparison,
        [string] $ExpectedPerformanceProducerSha256
    )
    $expected = ConvertTo-V71Sha256 $ExpectedPerformanceProducerSha256 `
        'expected A/B producer SHA-256 for reaggregation'
    $producerLock = Enter-V71ProducerReadLock $PerformanceHarnessPath `
        'A/B producer during reaggregation'
    try {
        Require-V71Evidence ((Get-V71TextProducerSha256 $PerformanceHarnessPath `
            'A/B producer before reaggregation') -ceq $expected) `
            'The A/B producer drifted before reaggregation.'
        $values = @(& $PerformanceHarnessPath -Action Aggregate `
            -OutputDirectory $CampaignDirectory)
        $decisions = @($values | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties['PerformanceGatePassed']
        })
        Require-V71Evidence ($decisions.Count -eq 1) `
            'The pinned A/B producer did not return one recomputed decision.'
        $recomputed = $decisions[0]
        Require-V71Evidence ((Get-V71CanonicalJson $recomputed) -ceq
            (Get-V71CanonicalJson $LockedComparison)) `
            'The locked A/B comparison differs from a fresh aggregation of its raw reports.'
        Require-V71Evidence ((Get-V71TextProducerSha256 $PerformanceHarnessPath `
            'A/B producer after reaggregation') -ceq $expected) `
            'The A/B producer drifted during reaggregation.'
    } finally {
        $producerLock.Dispose()
    }
}

function Assert-V71RawPerformanceReports {
    param(
        [object[]] $ResolvedReports,
        [string] $ExpectedPerformanceProducerSha256,
        [string] $ExpectedProducerLineageSha256
    )
    $expectedNames = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
    Require-V71Evidence ($ResolvedReports.Count -eq $expectedNames.Count) `
        'The raw A/B report set is incomplete.'
    $otherModsFingerprint = $null
    for ($index = 0; $index -lt $expectedNames.Count; $index++) {
        $name = $expectedNames[$index]
        $report = Read-V71EvidenceJsonText $ResolvedReports[$index].Text `
            "A/B raw report $name"
        Require-V71Evidence ([int]$(Get-V71EvidenceProperty $report 'SchemaVersion' "A/B raw report $name") -eq 1 -and
            [string]$(Get-V71EvidenceProperty $report 'Package' "A/B raw report $name") -ceq
                'com.qcxr.qcxr.canary262' -and
            (Test-V71ExactTrue $(Get-V71EvidenceProperty $report 'ValidForComparison' "A/B raw report $name")) -and
            (Test-V71ExactFalse $(Get-V71EvidenceProperty $report 'RawLogsPersisted' "A/B raw report $name"))) `
            "A/B raw report $name is not a retained exact-Lab comparison sample."
        foreach ($field in @('ExactPidPollPercent', 'FocusedPollPercent', 'SampleCoveragePercent')) {
            $coverage = ConvertTo-V71FiniteNumber `
                $(Get-V71EvidenceProperty $report $field "A/B raw report $name") `
                "A/B raw report $name $field"
            Require-V71Evidence ($coverage -ge 95.0 -and $coverage -le 100.0) `
                "A/B raw report $name failed $field."
        }
        $protocol = Get-V71EvidenceProperty $report 'Protocol' "A/B raw report $name"
        $condition = $name.Substring(0, 1)
        $pair = [int]$name.Substring(1, 1)
        Require-V71Evidence ([int]$(Get-V71EvidenceProperty $protocol 'SchemaVersion' "A/B raw report $name protocol") -eq 2 -and
            [string]$(Get-V71EvidenceProperty $protocol 'Condition' "A/B raw report $name protocol") -ceq $condition -and
            [int]$(Get-V71EvidenceProperty $protocol 'Pair' "A/B raw report $name protocol") -eq $pair) `
            "A/B raw report $name protocol identity drifted."
        $reportLineageDigest = Assert-V71PerformanceProducerLineage `
            (Get-V71EvidenceProperty $protocol 'ProducerLineage' `
                "A/B raw report $name protocol") `
            $ExpectedPerformanceProducerSha256 `
            "A/B raw report $name producer lineage"
        Require-V71Evidence ($reportLineageDigest -ceq $ExpectedProducerLineageSha256) `
            "A/B raw report $name was produced by a different helper closure."
        $expectedCore = if ($condition -ceq 'A') {
            'AAC5852BD1495AA0121A078F87312A644608F209A9190AE539CDC4F7763CD8FC'
        } else { '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26' }
        $expectedVeq = if ($condition -ceq 'A') {
            '8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A'
        } else { '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B' }
        $core = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $protocol 'CoreSha256' "A/B raw report $name protocol") `
            "A/B raw report $name Core SHA-256"
        $veq = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $protocol 'VeqSha256' "A/B raw report $name protocol") `
            "A/B raw report $name VEQ SHA-256"
        Require-V71Evidence ($core -ceq $expectedCore -and $veq -ceq $expectedVeq) `
            "A/B raw report $name payload identity drifted."
        $fingerprint = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $protocol 'OtherModsFingerprintSha256' "A/B raw report $name protocol") `
            "A/B raw report $name other-mod fingerprint"
        if ($null -eq $otherModsFingerprint) { $otherModsFingerprint = $fingerprint }
        Require-V71Evidence ($fingerprint -ceq $otherModsFingerprint) `
            'The retained A/B reports did not use one identical other-mod stack.'
        $lease = Get-V71EvidenceProperty $protocol 'PerformanceLevelLease' `
            "A/B raw report $name protocol"
        Require-V71Evidence (
            (Test-V71ExactTrue $(Get-V71EvidenceProperty $lease 'AppliedAfterWorldReady' "A/B raw report $name lease")) -and
            (Test-V71ExactTrue $(Get-V71EvidenceProperty $lease 'VerifiedBeforeWarmup' "A/B raw report $name lease")) -and
            [int]$(Get-V71EvidenceProperty $lease 'CpuLevel' "A/B raw report $name lease") -eq 4 -and
            [int]$(Get-V71EvidenceProperty $lease 'GpuLevel' "A/B raw report $name lease") -eq 4 -and
            (Test-V71ExactFalse $(Get-V71EvidenceProperty $lease 'RefreshPropertiesModified' "A/B raw report $name lease")) -and
            (Test-V71ExactFalse $(Get-V71EvidenceProperty $lease 'AdaptivePropertiesModified' "A/B raw report $name lease"))) `
            "A/B raw report $name lacks the verified per-round Lab 4/4 lease."

        $aggregate = Get-V71EvidenceProperty $report 'Aggregate' "A/B raw report $name"
        $numbers = @{}
        foreach ($field in @(
            'MeanAppFps', 'P10AppFps', 'P95CpuAndGpuMs',
            'MeanStaleAtStableRefresh', 'MeanStalePerSecond',
            'MeanDisplayRefreshHz', 'DisplayRefreshModeHz', 'RefreshTransitionCount',
            'CpuLevelMode', 'GpuLevelMode', 'CpuLevel4Percent', 'GpuLevel4Percent',
            'FirstTempC', 'MeanTempC', 'LastTempC', 'MaxTempC')) {
            $numbers[$field] = ConvertTo-V71FiniteNumber `
                $(Get-V71EvidenceProperty $aggregate $field "A/B raw report $name aggregate") `
                "A/B raw report $name $field"
        }
        Require-V71Evidence ($numbers.MeanAppFps -gt 0.0 -and $numbers.P10AppFps -gt 0.0 -and
            $numbers.P95CpuAndGpuMs -gt 0.0 -and $numbers.MeanDisplayRefreshHz -gt 0.0 -and
            $numbers.DisplayRefreshModeHz -gt 0.0 -and
            $numbers.CpuLevelMode -eq 4.0 -and $numbers.GpuLevelMode -eq 4.0 -and
            $numbers.CpuLevel4Percent -ge 95.0 -and $numbers.CpuLevel4Percent -le 100.0 -and
            $numbers.GpuLevel4Percent -ge 95.0 -and $numbers.GpuLevel4Percent -le 100.0 -and
            $numbers.FirstTempC -gt 0.0 -and $numbers.MeanTempC -gt 0.0 -and
            $numbers.LastTempC -gt 0.0 -and $numbers.MaxTempC -gt 0.0) `
            "A/B raw report $name contains an impossible or out-of-contract aggregate metric."
    }
}

function Assert-V71MemoryRuntimeContractReceipt {
    param(
        $Receipt,
        [string] $ExpectedProducerSha256,
        [object[]] $ResolvedSoaks,
        [string] $LifecycleReceiptSha256
    )
    $schema = ConvertTo-V71FiniteNumber `
        $(Get-V71EvidenceProperty $Receipt 'schemaVersion' 'memory runtime contract') `
        'memory runtime contract.schemaVersion'
    $type = [string]$(Get-V71EvidenceProperty $Receipt 'receiptType' `
        'memory runtime contract')
    $result = [string]$(Get-V71EvidenceProperty $Receipt 'result' `
        'memory runtime contract')
    Require-V71Evidence ($schema -eq 1.0 -and [Math]::Floor($schema) -eq $schema -and
        $type -ceq 'V71_MEMORY_RUNTIME_CONTRACT' -and $result -ceq 'PASS') `
        'Memory runtime contract schema, type, or result drifted.'
    $null = Assert-V71Timestamp $(Get-V71EvidenceProperty $Receipt 'createdUtc' `
        'memory runtime contract') 'memory runtime contract.createdUtc'
    Assert-V71LabIdentityContract $(Get-V71EvidenceProperty $Receipt `
        'labIdentity' 'memory runtime contract')

    $producer = Get-V71EvidenceProperty $Receipt 'producer' 'memory runtime contract'
    $scheme = [string]$(Get-V71EvidenceProperty $producer 'hashScheme' `
        'memory runtime contract producer')
    $producerSha = ConvertTo-V71Sha256 `
        $(Get-V71EvidenceProperty $producer 'sha256' 'memory runtime contract producer') `
        'memory runtime contract producer SHA-256'
    Require-V71Evidence ($scheme -ceq $script:V71PerformanceProducerHashScheme -and
        $producerSha -ceq $ExpectedProducerSha256) `
        'Memory runtime contract producer identity drifted.'

    $policy = Get-V71EvidenceProperty $Receipt 'memoryPolicy' 'memory runtime contract'
    foreach ($field in @(
        [pscustomobject]@{ Name = 'xmsMiB'; Expected = 512 },
        [pscustomobject]@{ Name = 'automaticXmxMiB'; Expected = 1536 },
        [pscustomobject]@{ Name = 'manualXmxHardCapMiB'; Expected = 2048 },
        [pscustomobject]@{ Name = 'exactColdStartObservations'; Expected = 3 }
    )) {
        $number = ConvertTo-V71FiniteNumber `
            $(Get-V71EvidenceProperty $policy $field.Name 'memory runtime contract policy') `
            "memory runtime contract policy.$($field.Name)"
        Require-V71Evidence ([Math]::Floor($number) -eq $number -and
            $number -eq [double]$field.Expected) `
            "Memory runtime contract policy $($field.Name) drifted."
    }
    $pojlib = ConvertTo-V71Sha256 `
        $(Get-V71EvidenceProperty $policy 'pojlibAarSha256' `
            'memory runtime contract policy') `
        'memory runtime contract Pojlib SHA-256'
    Require-V71Evidence ($pojlib -ceq
        'D7FF9C3EE2CCB332F88DE9A44E40E5BDA38F390142DC64905AEFD720FC3ADED6') `
        'Memory runtime contract belongs to another Pojlib memory policy.'
    Require-V71Evidence (
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $policy `
            'allColdStartsObservedAutomatic1536' 'memory runtime contract policy')) -and
        [string]$(Get-V71EvidenceProperty $policy 'evidenceBasis' `
            'memory runtime contract policy') -ceq
            'exact-apk-contract-plus-three-observed-cold-starts' -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $policy `
            'perSoakJvmArgumentObservedDirectly' 'memory runtime contract policy'))) `
        'Memory runtime contract overclaims or does not bind the cold-start heap evidence.'

    $release = Get-V71EvidenceProperty $Receipt 'launcherResourceRelease' `
        'memory runtime contract'
    $lockedLifecycle = ConvertTo-V71Sha256 `
        $(Get-V71EvidenceProperty $release 'lifecycleReceiptSha256' `
            'memory runtime contract launcher release') `
        'memory runtime contract lifecycle receipt SHA-256'
    Require-V71Evidence (
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $release 'exactBuildDefaultOn' `
            'memory runtime contract launcher release')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $release `
            'lifecycleProducerRequestsOn' 'memory runtime contract launcher release')) -and
        $lockedLifecycle -ceq $LifecycleReceiptSha256 -and
        [string]$(Get-V71EvidenceProperty $release 'evidenceBasis' `
            'memory runtime contract launcher release') -ceq
            'exact-apk-default-on-policy-plus-reviewed-on-lifecycle-producer' -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $release `
            'perSoakAppliedMarkerObservedDirectly' `
            'memory runtime contract launcher release'))) `
        'Memory runtime contract overclaims or does not bind launcher resource release.'

    $soaks = @(Get-V71EvidenceProperty $Receipt 'soaks' 'memory runtime contract')
    Require-V71Evidence ($soaks.Count -eq 2 -and $ResolvedSoaks.Count -eq 2) `
        'Memory runtime contract must bind exactly two captures.'
    for ($index = 0; $index -lt 2; $index++) {
        $entry = $soaks[$index]
        $receiptIndex = ConvertTo-V71FiniteNumber `
            $(Get-V71EvidenceProperty $entry 'index' "memory contract soak[$index]") `
            "memory contract soak[$index].index"
        $summarySha = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $entry 'summarySha256' `
                "memory contract soak[$index]") `
            "memory contract soak[$index] summary SHA-256"
        $samplesSha = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $entry 'samplesSha256' `
                "memory contract soak[$index]") `
            "memory contract soak[$index] samples SHA-256"
        $captureProducer = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $entry 'producerSha256' `
                "memory contract soak[$index]") `
            "memory contract soak[$index] producer SHA-256"
        $started = Assert-V71Timestamp `
            $(Get-V71EvidenceProperty $entry 'startedUtc' `
                "memory contract soak[$index]") `
            "memory contract soak[$index].startedUtc"
        $initialPid = ConvertTo-V71FiniteNumber `
            $(Get-V71EvidenceProperty $entry 'initialPid' `
                "memory contract soak[$index]") `
            "memory contract soak[$index].initialPid"
        Require-V71Evidence ($receiptIndex -eq ($index + 1) -and
            [Math]::Floor($receiptIndex) -eq $receiptIndex) `
            "Memory runtime contract soak[$index] index drifted."
        Require-V71Evidence ($summarySha -ceq
            [string]($ResolvedSoaks[$index].SummarySha256)) `
            "Memory runtime contract soak[$index] summary hash drifted."
        Require-V71Evidence ($samplesSha -ceq
            [string]($ResolvedSoaks[$index].SamplesSha256)) `
            "Memory runtime contract soak[$index] samples hash drifted."
        Require-V71Evidence ($captureProducer -ceq
            [string]($ResolvedSoaks[$index].ProducerSha256)) `
            ("Memory runtime contract soak[{0}] producer drifted ({1} versus {2})." -f `
                $index, $captureProducer,
                [string]($ResolvedSoaks[$index].ProducerSha256))
        Require-V71Evidence ($started.ToUniversalTime() -eq
            [DateTimeOffset]($ResolvedSoaks[$index].StartedUtc)) `
            "Memory runtime contract soak[$index] start time drifted."
        Require-V71Evidence ([Math]::Floor($initialPid) -eq $initialPid -and
            $initialPid -eq [double]($ResolvedSoaks[$index].InitialPid)) `
            "Memory runtime contract soak[$index] PID drifted."
    }

    $direct = @(Get-V71EvidenceProperty $Receipt 'directObservations' `
        'memory runtime contract')
    Require-V71Evidence ($direct.Count -eq 2) `
        'Memory runtime contract must state direct-observation availability for both soaks.'
    Require-V71Evidence (
        [int]$(Get-V71EvidenceProperty $direct[0] 'index' `
            'memory runtime contract direct soak 1') -eq 1 -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $direct[0] 'available' `
            'memory runtime contract direct soak 1')) -and
        [string]$(Get-V71EvidenceProperty $direct[0] 'reason' `
            'memory runtime contract direct soak 1') -ceq
            'historical-process-ended-before-reviewed-direct-observer') `
        'Memory runtime contract overclaims direct observation for historical soak 1.'
    $directSoak2Available = Get-V71EvidenceProperty $direct[1] 'available' `
        'memory runtime contract direct soak 2'
    Require-V71Evidence ([int]$(Get-V71EvidenceProperty $direct[1] 'index' `
        'memory runtime contract direct soak 2') -eq 2 -and
        $directSoak2Available -is [bool]) `
        'Memory runtime contract direct soak-2 availability is malformed.'
    if ([bool]$directSoak2Available) {
        $directReceiptSha = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $direct[1] 'receiptSha256' `
                'memory runtime contract direct soak 2') `
            'memory runtime contract direct soak-2 receipt SHA-256'
        Require-V71Evidence (-not [string]::IsNullOrWhiteSpace($directReceiptSha) -and
            (Test-V71ExactTrue $(Get-V71EvidenceProperty $direct[1] `
                'sameAndroidPid' 'memory runtime contract direct soak 2')) -and
            [int]$(Get-V71EvidenceProperty $direct[1] 'initialPid' `
                'memory runtime contract direct soak 2') -eq
                [int]($ResolvedSoaks[1].InitialPid) -and
            [int]$(Get-V71EvidenceProperty $direct[1] 'xmsMiB' `
                'memory runtime contract direct soak 2') -eq 512 -and
            [int]$(Get-V71EvidenceProperty $direct[1] 'xmxMiB' `
                'memory runtime contract direct soak 2') -eq 1536 -and
            [string]$(Get-V71EvidenceProperty $direct[1] 'xmxSource' `
                'memory runtime contract direct soak 2') -ceq 'auto' -and
            (Test-V71ExactTrue $(Get-V71EvidenceProperty $direct[1] `
                'launcherResourceReleaseApplied' `
                'memory runtime contract direct soak 2'))) `
            'Memory runtime contract direct soak-2 observation is incomplete or detached.'
    } else {
        Require-V71Evidence ([string]$(Get-V71EvidenceProperty $direct[1] 'reason' `
            'memory runtime contract direct soak 2') -ceq
            'not-captured-before-process-exit-or-marker-unavailable') `
            'Memory runtime contract direct soak-2 unavailability reason drifted.'
    }

    $boundary = Get-V71EvidenceProperty $Receipt 'evidenceBoundary' `
        'memory runtime contract'
    Require-V71Evidence (
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $boundary `
            'crossEvidenceContractNotPerProcessAttestation' `
            'memory runtime contract boundary')) -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $boundary `
            'directPerSoakJvmArgumentClaim' 'memory runtime contract boundary')) -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $boundary `
            'directPerSoakResourceReleaseMarkerClaim' `
            'memory runtime contract boundary'))) `
        'Memory runtime contract does not preserve its cross-evidence trust boundary.'
    foreach ($field in @(
        'rawLogsPersisted', 'logSnippetsPersisted', 'deviceSerialPersisted',
        'accountDataPersisted', 'hostAbsolutePathsPersisted')) {
        Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty `
            $boundary $field 'memory runtime contract boundary')) `
            "Memory runtime contract persisted forbidden evidence field $field."
    }
}

function Assert-V71LifecycleRecoveryReceipt {
    param($Receipt, [string] $ExpectedLifecycleProducerSha256)
    $schema = [int]$(Get-V71EvidenceProperty $Receipt 'schemaVersion' `
        'lifecycle/recovery receipt')
    $type = [string]$(Get-V71EvidenceProperty $Receipt 'receiptType' `
        'lifecycle/recovery receipt')
    $result = [string]$(Get-V71EvidenceProperty $Receipt 'result' `
        'lifecycle/recovery receipt')
    Require-V71Evidence ($schema -eq 1 -and
        $type -ceq 'V71_LAB_LIFECYCLE_RECOVERY' -and $result -ceq 'PASS') `
        'Lifecycle/recovery receipt schema, type, or result drifted.'
    Assert-V71LabIdentityContract $(Get-V71EvidenceProperty $Receipt `
        'labIdentity' 'lifecycle/recovery receipt')
    $started = Assert-V71Timestamp $(Get-V71EvidenceProperty $Receipt `
        'startedUtc' 'lifecycle/recovery receipt') `
        'lifecycle/recovery receipt.startedUtc'
    $completed = Assert-V71Timestamp $(Get-V71EvidenceProperty $Receipt `
        'completedUtc' 'lifecycle/recovery receipt') `
        'lifecycle/recovery receipt.completedUtc'
    $duration = ($completed - $started).TotalMinutes
    Require-V71Evidence ($duration -ge 0.0 -and $duration -le 120.0) `
        'Lifecycle/recovery receipt timestamps are reversed or implausibly far apart.'
    $lineageDigest = Assert-V71LifecycleProducerLineage `
        $(Get-V71EvidenceProperty $Receipt 'producerLineage' `
            'lifecycle/recovery receipt') `
        $ExpectedLifecycleProducerSha256 `
        'lifecycle/recovery receipt producer lineage'

    $phases = @(Get-V71EvidenceProperty $Receipt 'phases' `
        'lifecycle/recovery receipt')
    $expectedNames = @(
        'preflight-exact-lab-and-rc3',
        'clean-cold-openxr',
        'post-openxr-process-stop-recovery',
        'launcher-only-interruption',
        'post-launcher-interruption-recovery',
        'final-stopped-exact-rc3')
    Require-V71Evidence ($phases.Count -eq $expectedNames.Count) `
        'Lifecycle/recovery receipt does not contain every required phase exactly once.'
    for ($index = 0; $index -lt $expectedNames.Count; $index++) {
        $phase = $phases[$index]
        $name = [string]$(Get-V71EvidenceProperty $phase 'name' `
            "lifecycle phase[$index]")
        $phaseResult = [string]$(Get-V71EvidenceProperty $phase 'result' `
            "lifecycle phase[$index]")
        Require-V71Evidence ($name -ceq $expectedNames[$index] -and
            $phaseResult -ceq 'PASS') `
            "Lifecycle phase[$index] is missing, reordered, or failed."
    }
    foreach ($field in @(
        'labInitiallyStopped', 'stableStopped', 'installedApkMatched',
        'exactRc3PairBefore')) {
        Require-V71Evidence (Test-V71ExactTrue $(Get-V71EvidenceProperty `
            $phases[0] $field 'lifecycle preflight')) `
            "Lifecycle preflight failed $field."
    }
    foreach ($phaseIndex in @(1, 2, 4)) {
        foreach ($field in @(
            'exactRc3VersionRows', 'openXrFocused',
            'openXrFrame120Submitted', 'benchmarkWorldLoaded', 'gameJvmAlive')) {
            Require-V71Evidence (Test-V71ExactTrue $(Get-V71EvidenceProperty `
                $phases[$phaseIndex] $field "lifecycle phase[$phaseIndex]")) `
                "Lifecycle phase[$phaseIndex] failed $field."
        }
    }
    Require-V71Evidence (
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $phases[1] `
            'startedFromStopped' 'clean lifecycle phase')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $phases[2] `
            'liveOpenXrProcessStoppedBeforeRecovery' 'post-OpenXR recovery phase')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $phases[2] `
            'recoveryStartedFromStopped' 'post-OpenXR recovery phase')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $phases[4] `
            'launcherInterruptedBeforeRecovery' 'post-launcher recovery phase')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $phases[4] `
            'recoveryStartedFromStopped' 'post-launcher recovery phase'))) `
        'A lifecycle interruption/recovery boundary was not proven from stopped state.'
    foreach ($field in @(
        'startedFromStopped', 'launcherOnlyProven', 'unityMainPresent',
        'gameJvmAbsent', 'minecraftLogUntouched', 'interruptedByForceStop')) {
        Require-V71Evidence (Test-V71ExactTrue $(Get-V71EvidenceProperty `
            $phases[3] $field 'launcher-only interruption phase')) `
            "Launcher-only interruption failed $field."
    }
    Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty `
        $phases[3] 'randomInputSent' 'launcher-only interruption phase')) `
        'Launcher-only interruption reports synthetic input.'
    foreach ($field in @(
        'labStopped', 'stableStopped', 'exactRc3PairAfter',
        'installedLabApkUnchanged', 'hostArtifactsUnchanged')) {
        Require-V71Evidence (Test-V71ExactTrue $(Get-V71EvidenceProperty `
            $phases[5] $field 'final lifecycle phase')) `
            "Final lifecycle phase failed $field."
    }

    $finalState = Get-V71EvidenceProperty $Receipt 'finalState' `
        'lifecycle/recovery receipt'
    Require-V71Evidence (
        [string]$(Get-V71EvidenceProperty $finalState 'lab' `
            'lifecycle final state') -ceq 'stopped' -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $finalState `
            'exactRc3Pair' 'lifecycle final state')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $finalState `
            'installedLabApkUnchanged' 'lifecycle final state')) -and
        (Test-V71ExactTrue $(Get-V71EvidenceProperty $finalState `
            'stablePidAbsent' 'lifecycle final state')) -and
        (Test-V71ExactFalse $(Get-V71EvidenceProperty $finalState `
            'stableTouched' 'lifecycle final state'))) `
        'Lifecycle/recovery final state is not stopped exact RC3 with Stable untouched.'

    $boundary = Get-V71EvidenceProperty $Receipt 'evidenceBoundary' `
        'lifecycle/recovery receipt'
    foreach ($field in @(
        'rawLogsPersisted', 'logSnippetsPersisted', 'deviceSerialPersisted',
        'processIdsPersisted', 'hostAbsolutePathsPersisted',
        'accountDataPersisted', 'saveDataPersistedByGate', 'randomInputSent',
        'manualInteractionClaim', 'performanceClaim', 'memorySoakClaim',
        'postInitAcknowledgementProven')) {
        Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty `
            $boundary $field 'lifecycle evidence boundary')) `
            "Lifecycle receipt violates its non-sensitive boundary at $field."
    }
    $limitation = [string]$(Get-V71EvidenceProperty $boundary `
        'postInitAcknowledgementLimitation' 'lifecycle evidence boundary')
    Require-V71Evidence ($limitation -ceq
        'Frozen RC3 has no ACK; Unity launcher and JVM share one Android PID.') `
        'Lifecycle receipt no longer preserves the frozen-RC3 evidence limitation.'
    return $lineageDigest
}

function Assert-V71ManualReceipt {
    param($Receipt)
    $schema = [int]$(Get-V71EvidenceProperty $Receipt 'schemaVersion' 'manual receipt')
    $type = [string]$(Get-V71EvidenceProperty $Receipt 'receiptType' 'manual receipt')
    $status = [string]$(Get-V71EvidenceProperty $Receipt 'status' 'manual receipt')
    Require-V71Evidence ($schema -eq 1 -and $type -ceq 'V71_MANUAL_VR_INTERACTION') `
        'Manual receipt schema/type drifted.'
    Require-V71Evidence ($status -ceq 'PASS_CONFIRMED_BY_USER') `
        'Manual VR interaction is still pending.'
    Assert-V71LabIdentityContract $(Get-V71EvidenceProperty $Receipt 'labIdentity' 'manual receipt')
    $confirmation = Get-V71EvidenceProperty $Receipt 'confirmation' 'manual receipt'
    $source = [string]$(Get-V71EvidenceProperty $confirmation 'source' 'manual confirmation')
    $recordedBy = [string]$(Get-V71EvidenceProperty $confirmation 'recordedBy' 'manual confirmation')
    $statement = [string]$(Get-V71EvidenceProperty $confirmation 'statement' 'manual confirmation')
    $userQuote = [string]$(Get-V71EvidenceProperty $confirmation 'userQuote' 'manual confirmation')
    Require-V71Evidence ($source -ceq 'explicit-user-message' -and
        $recordedBy -ceq 'human-recorded-from-explicit-user-confirmation') `
        'Manual confirmation provenance is not explicit-user evidence.'
    $requiredStatement = 'I manually tested the exact v71 RC3 Lab build in the headset and confirm every required interaction passed.'
    Require-V71Evidence ($statement -ceq $requiredStatement) `
        'Manual confirmation statement is absent or changed.'
    Require-V71Evidence (-not [string]::IsNullOrWhiteSpace($userQuote) -and
        $userQuote.Length -ge 3 -and $userQuote.Length -le 1000 -and
        -not $userQuote.Contains("`r") -and -not $userQuote.Contains("`n")) `
        'Manual confirmation needs one short exact user quote from the explicit message.'
    $null = Assert-V71Timestamp $(Get-V71EvidenceProperty $confirmation 'confirmedUtc' 'manual confirmation') `
        'manual confirmation.confirmedUtc'
    $checks = Get-V71EvidenceProperty $Receipt 'checks' 'manual receipt'
    foreach ($name in @(
        'immersiveMcPickupBothHands', 'wristThrowFullStackOutside',
        'wristThrowSingleItemOutside', 'wristOtherHandCannotStealCarriedItem',
        'yUsesLeftHandItemOnLegacyServer', 'bContainerAndInventoryBehavior',
        'movingContainerMenus', 'gripBothHands', 'bow', 'shield', 'teleport')) {
        $value = [string]$(Get-V71EvidenceProperty $checks $name 'manual checks')
        Require-V71Evidence ($value -ceq 'PASS') "Manual check $name is not PASS."
    }
    Require-V71Evidence (Test-V71ExactFalse $(Get-V71EvidenceProperty $Receipt 'stableTouched' 'manual receipt')) `
        'Manual receipt reports Stable was touched.'
}

function Assert-V71StableAcceptanceEvidenceCore {
    [CmdletBinding()]
    param(
        [string] $ManifestPath,
        [string] $WorkspaceRoot,
        [string] $MemorySamplerPath,
        [string] $PerformanceHarnessPath,
        [string] $LifecycleHarnessPath,
        [string] $ExpectedMemoryProducerSha256,
        [string] $ExpectedMemoryContractProducerSha256,
        [string] $ExpectedPerformanceProducerSha256,
        [string] $ExpectedLifecycleProducerSha256,
        [string] $LegacyRoundOneMemoryProducerSha256
    )
    Require-V71Evidence (Test-Path -LiteralPath $ManifestPath -PathType Leaf) `
        'V71_STABLE_ACCEPTANCE.lock.json is missing.'
    $evidenceReadLocks = [Collections.Generic.List[IDisposable]]::new()
    $acceptanceReadLock = Enter-V71ProducerReadLock $ManifestPath `
        'Stable acceptance manifest'
    $evidenceReadLocks.Add($acceptanceReadLock)
    try {
    $manifestSha256 = Get-V71FileSha256 $ManifestPath
    $manifest = Read-V71EvidenceJson $ManifestPath 'Stable acceptance manifest'
    Assert-V71StableAcceptanceManifestContract $manifest -RequireAccepted

    $producers = Get-V71EvidenceProperty $manifest 'producerScripts' 'acceptance manifest'
    $memoryProducer = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $producers 'memorySoakSha256' 'producerScripts') 'memory-soak producer SHA-256'
    $performanceProducer = ConvertTo-V71Sha256 $(Get-V71EvidenceProperty $producers 'performanceHarnessSha256' 'producerScripts') 'performance producer SHA-256'
    $memoryContractProducer = ConvertTo-V71Sha256 `
        $(Get-V71EvidenceProperty $producers 'memoryRuntimeContractSha256' `
            'producerScripts') 'memory runtime contract producer SHA-256'
    $lifecycleProducer = ConvertTo-V71Sha256 `
        $(Get-V71EvidenceProperty $producers 'lifecycleRecoverySha256' `
            'producerScripts') 'lifecycle/recovery producer SHA-256'
    $pinnedMemoryProducer = ConvertTo-V71Sha256 $ExpectedMemoryProducerSha256 `
        'pinned memory-soak producer SHA-256'
    $pinnedPerformanceProducer = ConvertTo-V71Sha256 $ExpectedPerformanceProducerSha256 `
        'pinned A/B producer SHA-256'
    $pinnedMemoryContractProducer = ConvertTo-V71Sha256 `
        $ExpectedMemoryContractProducerSha256 `
        'pinned memory runtime contract producer SHA-256'
    $pinnedLifecycleProducer = ConvertTo-V71Sha256 $ExpectedLifecycleProducerSha256 `
        'pinned lifecycle/recovery producer SHA-256'
    $pinnedLegacyRoundOneProducer = ConvertTo-V71Sha256 `
        $LegacyRoundOneMemoryProducerSha256 'pinned legacy round-one memory producer SHA-256'
    Require-V71Evidence ($memoryProducer -ceq $pinnedMemoryProducer) `
        'The acceptance manifest does not identify the reviewed memory-soak producer.'
    Require-V71Evidence ($performanceProducer -ceq $pinnedPerformanceProducer) `
        'The acceptance manifest does not identify the reviewed A/B producer.'
    Require-V71Evidence ($memoryContractProducer -ceq $pinnedMemoryContractProducer) `
        'The acceptance manifest does not identify the reviewed memory runtime contract producer.'
    Require-V71Evidence ($lifecycleProducer -ceq $pinnedLifecycleProducer) `
        'The acceptance manifest does not identify the reviewed lifecycle/recovery producer.'
    Require-V71Evidence (Test-Path -LiteralPath $MemorySamplerPath -PathType Leaf) `
        'The memory-soak producer is missing.'
    Require-V71Evidence ((Get-V71TextProducerSha256 $MemorySamplerPath `
        'memory-soak producer') -ceq $memoryProducer) `
        'The memory-soak producer no longer matches the locked evidence.'
    Require-V71Evidence (Test-Path -LiteralPath $PerformanceHarnessPath -PathType Leaf) `
        'The A/B producer is missing.'
    Require-V71Evidence ((Get-V71TextProducerSha256 $PerformanceHarnessPath `
        'A/B producer') -ceq $performanceProducer) `
        'The A/B producer no longer matches the locked evidence.'
    Require-V71Evidence (Test-Path -LiteralPath $LifecycleHarnessPath -PathType Leaf) `
        'The lifecycle/recovery producer is missing.'
    $lifecycleProducerReadLock = Enter-V71ProducerReadLock $LifecycleHarnessPath `
        'lifecycle/recovery producer'
    $evidenceReadLocks.Add($lifecycleProducerReadLock)
    Require-V71Evidence ((Get-V71TextProducerSha256 $LifecycleHarnessPath `
        'lifecycle/recovery producer') -ceq $lifecycleProducer) `
        'The lifecycle/recovery producer no longer matches the locked evidence.'
    $memoryContractProducerPath = Join-Path `
        ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LifecycleHarnessPath))) `
        'quest-v71-memory-runtime-contract.ps1'
    Require-V71Evidence (Test-Path -LiteralPath $memoryContractProducerPath -PathType Leaf) `
        'The memory runtime contract producer is missing.'
    $memoryContractProducerReadLock = Enter-V71ProducerReadLock `
        $memoryContractProducerPath 'memory runtime contract producer'
    $evidenceReadLocks.Add($memoryContractProducerReadLock)
    Require-V71Evidence ((Get-V71TextProducerSha256 $memoryContractProducerPath `
        'memory runtime contract producer') -ceq $memoryContractProducer) `
        'The memory runtime contract producer no longer matches the locked evidence.'
    $lifecycleDependencyPath = Join-Path `
        ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LifecycleHarnessPath))) `
        'run-vivecraft-local-autoplay.ps1'
    Require-V71Evidence (Test-Path -LiteralPath $lifecycleDependencyPath -PathType Leaf) `
        'The lifecycle/recovery autoplay dependency is missing.'
    $lifecycleDependencyReadLock = Enter-V71ProducerReadLock `
        $lifecycleDependencyPath 'lifecycle/recovery autoplay dependency'
    $evidenceReadLocks.Add($lifecycleDependencyReadLock)
    Require-V71Evidence ((Get-V71TextProducerSha256 $lifecycleDependencyPath `
        'lifecycle/recovery autoplay dependency') -ceq
        $script:V71ExpectedLifecycleDependencyHashes['autoplay-harness']) `
        'The lifecycle/recovery autoplay dependency drifted from the reviewed closure.'

    $soakLocks = @(Get-V71EvidenceProperty $manifest 'memorySoaks' 'acceptance manifest')
    $resolvedSoaks = @()
    $startedTimes = @()
    for ($index = 0; $index -lt 2; $index++) {
        $entry = $soakLocks[$index]
        $soakProducer = ConvertTo-V71Sha256 `
            $(Get-V71EvidenceProperty $entry 'producerSha256' "memorySoaks[$index]") `
            "memorySoaks[$index].producerSha256"
        $usesLegacyRoundOneProducer = $soakProducer -ceq $pinnedLegacyRoundOneProducer
        if ($index -eq 0) {
            Require-V71Evidence ($soakProducer -ceq $pinnedMemoryProducer -or
                $usesLegacyRoundOneProducer) `
                'Memory soak 1 was not captured by a reviewed producer.'
        } else {
            Require-V71Evidence ($soakProducer -ceq $pinnedMemoryProducer) `
                'Memory soak 2 must use the current reviewed producer.'
        }
        $resolved = Resolve-V71LockedEvidenceFile `
            -WorkspaceRoot $WorkspaceRoot `
            -RelativePath $(Get-V71EvidenceProperty $entry 'summaryPath' "memorySoaks[$index]") `
            -ExpectedSha256 $(Get-V71EvidenceProperty $entry 'summarySha256' "memorySoaks[$index]") `
            -RequiredPrefix @('artifacts/memory/', 'work/agent-v70-integration/artifacts/memory/') `
            -RequiredLeaf 'summary.json' `
            -Context "memory soak $($index + 1)"
        $evidenceReadLocks.Add($resolved.ReadLock)
        $samplesFile = Resolve-V71LockedEvidenceFile `
            -WorkspaceRoot $WorkspaceRoot `
            -RelativePath $(Get-V71EvidenceProperty $entry 'samplesPath' "memorySoaks[$index]") `
            -ExpectedSha256 $(Get-V71EvidenceProperty $entry 'samplesSha256' "memorySoaks[$index]") `
            -RequiredPrefix @('artifacts/memory/', 'work/agent-v70-integration/artifacts/memory/') `
            -RequiredLeaf 'samples.jsonl' `
            -Context "memory soak $($index + 1) raw samples"
        $evidenceReadLocks.Add($samplesFile.ReadLock)
        Require-V71Evidence ([IO.Path]::GetDirectoryName($resolved.Path) -ceq
            [IO.Path]::GetDirectoryName($samplesFile.Path)) `
            "Memory soak $($index + 1) summary and samples are not one capture."
        $summary = Read-V71EvidenceJsonText $resolved.Text `
            "memory soak $($index + 1)"
        $started = Assert-V71MemorySummary $summary "memory soak $($index + 1)"
        if ($usesLegacyRoundOneProducer) {
            Require-V71Evidence ($index -eq 0 -and
                [math]::Abs(($started - $script:V71LegacyRoundOneTrustedStart).TotalSeconds) -le 60.0) `
                'The legacy producer is allowed only for the already-running 2026-09-06 09:16:23 +03:00 first soak.'
        }
        Assert-V71MemorySummaryAgainstSamples $summary $samplesFile.Text `
            "memory soak $($index + 1)"
        $resolvedSoaks += [pscustomobject]@{
            RelativePath = $resolved.RelativePath
            SummarySha256 = $resolved.Sha256
            SamplesSha256 = $samplesFile.Sha256
            ProducerSha256 = $soakProducer
            StartedUtc = $started.ToUniversalTime()
            InitialPid = [int]$(Get-V71EvidenceProperty $summary 'initialPid' `
                "memory soak $($index + 1)")
        }
        $startedTimes += $started
    }
    Require-V71Evidence ($resolvedSoaks[0].RelativePath -cne $resolvedSoaks[1].RelativePath -and
        $resolvedSoaks[0].SummarySha256 -cne $resolvedSoaks[1].SummarySha256 -and
        $resolvedSoaks[0].SamplesSha256 -cne $resolvedSoaks[1].SamplesSha256) `
        'The two required memory soaks are not distinct captures.'
    Require-V71Evidence ([math]::Abs(($startedTimes[1] - $startedTimes[0]).TotalMinutes) -ge 80.0) `
        'The memory-soak start times do not represent two separate rounds.'

    $performanceLock = Get-V71EvidenceProperty $manifest 'performance' 'acceptance manifest'
    $runManifestFile = Resolve-V71LockedEvidenceFile `
        -WorkspaceRoot $WorkspaceRoot `
        -RelativePath $(Get-V71EvidenceProperty $performanceLock 'runManifestPath' 'performance') `
        -ExpectedSha256 $(Get-V71EvidenceProperty $performanceLock 'runManifestSha256' 'performance') `
        -RequiredPrefix 'artifacts/benchmarks/' `
        -RequiredLeaf 'run-manifest.json' `
        -Context 'A/B run manifest'
    $evidenceReadLocks.Add($runManifestFile.ReadLock)
    $comparisonFile = Resolve-V71LockedEvidenceFile `
        -WorkspaceRoot $WorkspaceRoot `
        -RelativePath $(Get-V71EvidenceProperty $performanceLock 'comparisonPath' 'performance') `
        -ExpectedSha256 $(Get-V71EvidenceProperty $performanceLock 'comparisonSha256' 'performance') `
        -RequiredPrefix 'artifacts/benchmarks/' `
        -RequiredLeaf 'comparison.json' `
        -Context 'A/B comparison'
    $evidenceReadLocks.Add($comparisonFile.ReadLock)
    Require-V71Evidence ([IO.Path]::GetDirectoryName($runManifestFile.Path) -ceq
        [IO.Path]::GetDirectoryName($comparisonFile.Path)) `
        'A/B manifest and comparison do not belong to one campaign directory.'
    $runManifest = Read-V71EvidenceJsonText $runManifestFile.Text 'A/B run manifest'
    $comparison = Read-V71EvidenceJsonText $comparisonFile.Text 'A/B comparison'
    $performanceLineageDigest = Assert-V71PerformanceEvidence `
        $runManifest $comparison $performanceProducer
    $reportLocks = @(Get-V71EvidenceProperty $performanceLock 'reports' 'performance')
    $requiredReports = @('A1.json', 'B1.json', 'B2.json', 'A2.json', 'A3.json', 'B3.json')
    $resolvedReports = @()
    for ($index = 0; $index -lt $requiredReports.Count; $index++) {
        $reportLock = $reportLocks[$index]
        $reportFile = Resolve-V71LockedEvidenceFile `
            -WorkspaceRoot $WorkspaceRoot `
            -RelativePath $(Get-V71EvidenceProperty $reportLock 'path' "performance reports[$index]") `
            -ExpectedSha256 $(Get-V71EvidenceProperty $reportLock 'sha256' "performance reports[$index]") `
            -RequiredPrefix 'artifacts/benchmarks/' `
            -RequiredLeaf $requiredReports[$index] `
            -Context "A/B raw report $($requiredReports[$index])"
        $evidenceReadLocks.Add($reportFile.ReadLock)
        Require-V71Evidence ([IO.Path]::GetDirectoryName($reportFile.Path) -ceq
            [IO.Path]::GetDirectoryName($comparisonFile.Path)) `
            "A/B raw report $($requiredReports[$index]) is outside the locked campaign directory."
        $resolvedReports += $reportFile
    }
    Require-V71Evidence ((@($resolvedReports.RelativePath | Sort-Object -Unique)).Count -eq 6 -and
        (@($resolvedReports.Sha256 | Sort-Object -Unique)).Count -eq 6) `
        'The six retained A/B reports are not distinct locked files.'
    Assert-V71RawPerformanceReports $resolvedReports $performanceProducer `
        $performanceLineageDigest
    Assert-V71PerformanceReaggregation `
        -PerformanceHarnessPath $PerformanceHarnessPath `
        -CampaignDirectory ([IO.Path]::GetDirectoryName($comparisonFile.Path)) `
        -LockedComparison $comparison `
        -ExpectedPerformanceProducerSha256 $performanceProducer

    $lifecycleLock = Get-V71EvidenceProperty $manifest 'lifecycleRecovery' `
        'acceptance manifest'
    $lifecycleFile = Resolve-V71LockedEvidenceFile `
        -WorkspaceRoot $WorkspaceRoot `
        -RelativePath $(Get-V71EvidenceProperty $lifecycleLock 'receiptPath' `
            'lifecycleRecovery') `
        -ExpectedSha256 $(Get-V71EvidenceProperty $lifecycleLock 'receiptSha256' `
            'lifecycleRecovery') `
        -RequiredPrefix 'artifacts/acceptance/' `
        -RequiredLeaf 'v71-lab-lifecycle-recovery-receipt.json' `
        -Context 'Lab lifecycle/recovery receipt'
    $evidenceReadLocks.Add($lifecycleFile.ReadLock)
    $lifecycleReceipt = Read-V71EvidenceJsonText $lifecycleFile.Text `
        'Lab lifecycle/recovery receipt'
    $lifecycleLineageDigest = Assert-V71LifecycleRecoveryReceipt `
        $lifecycleReceipt $lifecycleProducer

    $memoryContractLock = Get-V71EvidenceProperty $manifest `
        'memoryRuntimeContract' 'acceptance manifest'
    $memoryContractFile = Resolve-V71LockedEvidenceFile `
        -WorkspaceRoot $WorkspaceRoot `
        -RelativePath $(Get-V71EvidenceProperty $memoryContractLock 'receiptPath' `
            'memoryRuntimeContract') `
        -ExpectedSha256 $(Get-V71EvidenceProperty $memoryContractLock 'receiptSha256' `
            'memoryRuntimeContract') `
        -RequiredPrefix 'artifacts/acceptance/' `
        -RequiredLeaf 'v71-memory-runtime-contract-receipt.json' `
        -Context 'memory runtime contract receipt'
    $evidenceReadLocks.Add($memoryContractFile.ReadLock)
    $memoryContractReceipt = Read-V71EvidenceJsonText $memoryContractFile.Text `
        'memory runtime contract receipt'
    Assert-V71MemoryRuntimeContractReceipt `
        -Receipt $memoryContractReceipt `
        -ExpectedProducerSha256 $memoryContractProducer `
        -ResolvedSoaks $resolvedSoaks `
        -LifecycleReceiptSha256 $lifecycleFile.Sha256

    $manualLock = Get-V71EvidenceProperty $manifest 'manual' 'acceptance manifest'
    $manualFile = Resolve-V71LockedEvidenceFile `
        -WorkspaceRoot $WorkspaceRoot `
        -RelativePath $(Get-V71EvidenceProperty $manualLock 'receiptPath' 'manual') `
        -ExpectedSha256 $(Get-V71EvidenceProperty $manualLock 'receiptSha256' 'manual') `
        -RequiredPrefix 'artifacts/acceptance/' `
        -RequiredLeaf 'v71-manual-vr-receipt.json' `
        -Context 'manual VR receipt'
    $evidenceReadLocks.Add($manualFile.ReadLock)
    $manualReceipt = Read-V71EvidenceJsonText $manualFile.Text 'manual VR receipt'
    Assert-V71ManualReceipt $manualReceipt

    return [pscustomobject]@{
        Result = 'PASS'
        ManifestSha256 = $manifestSha256
        MemorySoakSummarySha256 = @($resolvedSoaks | ForEach-Object SummarySha256)
        MemorySoakSamplesSha256 = @($resolvedSoaks | ForEach-Object SamplesSha256)
        MemorySoakProducerSha256 = @($resolvedSoaks | ForEach-Object ProducerSha256)
        PerformanceRunManifestSha256 = $runManifestFile.Sha256
        PerformanceComparisonSha256 = $comparisonFile.Sha256
        PerformanceReportSha256 = @($resolvedReports | ForEach-Object Sha256)
        LifecycleRecoveryReceiptSha256 = $lifecycleFile.Sha256
        LifecycleRecoveryProducerSha256 = $lifecycleProducer
        LifecycleRecoveryAutoplaySha256 = `
            $script:V71ExpectedLifecycleDependencyHashes['autoplay-harness']
        LifecycleRecoveryLineageSha256 = $lifecycleLineageDigest
        MemoryRuntimeContractReceiptSha256 = $memoryContractFile.Sha256
        MemoryRuntimeContractProducerSha256 = $memoryContractProducer
        ManualReceiptSha256 = $manualFile.Sha256
        ExactLabApkSha256 = 'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F'
        ExactCoreSha256 = '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26'
        ExactVeqSha256 = '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
        ManualReceiptTrustBoundary = 'Human authorship is not cryptographically provable; this gate validates the locked receipt, exact identity, quote, timestamp, and checks only.'
    }
    } finally {
        for ($index = $evidenceReadLocks.Count - 1; $index -ge 0; $index--) {
            $evidenceReadLocks[$index].Dispose()
        }
    }
}

function Assert-V71StableAcceptanceEvidence {
    [CmdletBinding()]
    param(
        [string] $ManifestPath,
        [string] $WorkspaceRoot,
        [string] $MemorySamplerPath,
        [string] $PerformanceHarnessPath,
        [string] $LifecycleHarnessPath
    )
    Assert-V71StableAcceptanceEvidenceCore `
        -ManifestPath $ManifestPath `
        -WorkspaceRoot $WorkspaceRoot `
        -MemorySamplerPath $MemorySamplerPath `
        -PerformanceHarnessPath $PerformanceHarnessPath `
        -LifecycleHarnessPath $LifecycleHarnessPath `
        -ExpectedMemoryProducerSha256 $script:V71ExpectedMemoryProducerSha256 `
        -ExpectedMemoryContractProducerSha256 `
            $script:V71ExpectedMemoryContractProducerSha256 `
        -ExpectedPerformanceProducerSha256 $script:V71ExpectedPerformanceProducerSha256 `
        -ExpectedLifecycleProducerSha256 $script:V71ExpectedLifecycleProducerSha256 `
        -LegacyRoundOneMemoryProducerSha256 $script:V71LegacyRoundOneMemoryProducerSha256
}
