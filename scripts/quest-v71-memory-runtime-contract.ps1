#requires -Version 7.0
<#
.SYNOPSIS
Creates a non-sensitive, write-once cross-evidence receipt for v71 memory runs.

.DESCRIPTION
SelfTest and Create are Host-only. CaptureDirectSoak2 is a separately guarded,
read-only device probe that may be run after soak 2 while its original Android
PID is still alive. The cross-evidence receipt always binds the two immutable
memory captures to the exact RC3 contract, cold-start heap observations, and
lifecycle receipt; it never promotes the unavailable historical soak-1 link
into a direct per-process claim.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Create', 'CaptureDirectSoak2')]
    [string] $Action = 'SelfTest',

    [string] $WorkspaceRoot = '',
    [string] $Soak1SummaryPath = '',
    [string] $Soak1SamplesPath = '',
    [string] $Soak1ProducerSha256 = '',
    [string] $Soak2SummaryPath = '',
    [string] $Soak2SamplesPath = '',
    [string] $Soak2ProducerSha256 = '',
    [string] $LifecycleReceiptPath = '',
    [string] $DirectSoak2ReceiptPath = '',
    [string] $OutputPath = '',
    [string] $Serial = '',
    [string] $AdbPath = '',
    [switch] $AllowReceiptWrite,
    [switch] $AllowReadOnlyDeviceProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HashScheme = 'sha256-utf8-normalized-lf'
$script:ExpectedPackage = 'com.qcxr.qcxr.canary262'
$script:ExpectedStablePackage = 'com.qcxr.qcxr.dev262'
$script:ExpectedVersionCode = 71
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.3'
$script:ExpectedApkSha256 = `
    'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F'
$script:ExpectedApkSizeBytes = 128431385L
$script:ExpectedCoreSha256 = `
    '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26'
$script:ExpectedVeqSha256 = `
    '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
$script:ExpectedSignerSha256 = `
    'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedPojlibSha256 = `
    'D7FF9C3EE2CCB332F88DE9A44E40E5BDA38F390142DC64905AEFD720FC3ADED6'
$script:ExpectedCurrentMemoryProducerSha256 = `
    'C6FE7345ACE4978599A4C15FA5AAA846A3AE664A9AB5485215F72AFD4DF41202'
$script:ExpectedLegacyMemoryProducerSha256 = `
    'FD443A5E4A1D63BDBBFA648B4BE57C694B5121BA3E98D6E25A58D8B0E8311ED9'
$script:ExpectedLifecycleProducerSha256 = `
    'E285F01F2B8F4808E01DEFA44789687EF9FD70370908D785D298247DEA07A4CF'
$script:DefaultReceiptRelativePath = `
    'artifacts/acceptance/v71-memory-runtime-contract-receipt.json'
$script:DirectReceiptRelativePath = `
    'artifacts/acceptance/v71-memory-soak2-direct-runtime-receipt.json'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_MEMORY_CONTRACT] $Message" }
}

function Get-Property($Object, [string] $Name, [string] $Context) {
    Require ($null -ne $Object) "$Context is absent."
    $property = $Object.PSObject.Properties[$Name]
    Require ($null -ne $property) "$Context.$Name is absent."
    return $property.Value
}

function ConvertTo-Sha256($Value, [string] $Context) {
    Require ($Value -is [string]) "$Context is not a string."
    $sha = ([string]$Value).ToUpperInvariant()
    Require ($sha -cmatch '^[0-9A-F]{64}$') "$Context is not a canonical SHA-256."
    return $sha
}

function Get-FileSha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-TextSha256([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    Require (-not $text.StartsWith([string][char]0xFEFF,
        [StringComparison]::Ordinal)) 'A producer contains a UTF-8 BOM.'
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($normalized)))
}

function Read-Json([string] $Path, [string] $Context) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { throw "[V71_MEMORY_CONTRACT] $Context is invalid JSON: $($_.Exception.Message)" }
}

function Assert-ContainedFile(
    [string] $Path,
    [string] $Root,
    [string] $Context
) {
    Require (-not [string]::IsNullOrWhiteSpace($Path)) "$Context path is absent."
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    Require ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) `
        "$Context is outside the workspace."
    $item = Get-Item -LiteralPath $full -Force
    Require (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        "$Context must not be a reparse point."
    return $full
}

function Assert-ExactLabIdentity($Identity, [string] $Context) {
    Require ([string](Get-Property $Identity 'package' $Context) -ceq
        $script:ExpectedPackage) "$Context package drifted."
    $stableProperty = $Identity.PSObject.Properties['forbiddenStablePackage']
    if ($null -ne $stableProperty) {
        Require ([string]$stableProperty.Value -ceq $script:ExpectedStablePackage) `
            "$Context Stable guard drifted."
    }
    Require ([int](Get-Property $Identity 'versionCode' $Context) -eq
        $script:ExpectedVersionCode) "$Context versionCode drifted."
    Require ([string](Get-Property $Identity 'versionName' $Context) -ceq
        $script:ExpectedVersionName) "$Context versionName drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'apkSha256' $Context) `
            "$Context APK SHA-256") -ceq $script:ExpectedApkSha256) `
        "$Context APK drifted."
    Require ([int64](Get-Property $Identity 'apkSizeBytes' $Context) -eq
        $script:ExpectedApkSizeBytes) "$Context APK size drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'coreSha256' $Context) `
            "$Context Core SHA-256") -ceq $script:ExpectedCoreSha256) `
        "$Context Core drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'veqSha256' $Context) `
            "$Context VEQ SHA-256") -ceq $script:ExpectedVeqSha256) `
        "$Context VEQ drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'signerSha256' $Context) `
            "$Context signer SHA-256") -ceq $script:ExpectedSignerSha256) `
        "$Context signer drifted."
}

function Assert-Rc3Contract($Lock) {
    Require ([int](Get-Property $Lock 'schemaVersion' 'RC3 lock') -eq 1) `
        'RC3 lock schema drifted.'
    $target = Get-Property $Lock 'target' 'RC3 lock'
    $pair = Get-Property $Lock 'pair' 'RC3 lock'
    $identity = [pscustomobject][ordered]@{
        package = Get-Property $target 'package' 'RC3 target'
        forbiddenStablePackage = Get-Property $target 'forbiddenStablePackage' 'RC3 target'
        versionCode = Get-Property $target 'labShellVersionCode' 'RC3 target'
        versionName = Get-Property $target 'labShellVersionName' 'RC3 target'
        apkSha256 = Get-Property $target 'labShellApkSha256' 'RC3 target'
        apkSizeBytes = Get-Property $target 'labShellApkSizeBytes' 'RC3 target'
        coreSha256 = Get-Property (Get-Property $pair 'core' 'RC3 pair') 'sha256' 'RC3 Core'
        veqSha256 = Get-Property (Get-Property $pair 'veq' 'RC3 pair') 'sha256' 'RC3 VEQ'
        signerSha256 = $script:ExpectedSignerSha256
    }
    Assert-ExactLabIdentity $identity 'RC3 lock identity'

    $policy = Get-Property $Lock 'memoryPolicy' 'RC3 lock'
    Require ([int](Get-Property $policy 'xmsMiB' 'memory policy') -eq 512 -and
        [int](Get-Property $policy 'automaticXmxTargetMiB' 'memory policy') -eq 1536 -and
        [int](Get-Property $policy 'automaticXmxMinMiB' 'memory policy') -eq 1536 -and
        [int](Get-Property $policy 'xmxMaxMiB' 'memory policy') -eq 2048 -and
        [int](Get-Property $policy 'manualXmxMaxMiB' 'memory policy') -eq 2048) `
        'The bounded RC3 JVM memory policy drifted.'

    $cold = Get-Property $Lock 'coldStartRuntimeEvidence' 'RC3 lock'
    Require ([string](Get-Property $cold 'result' 'cold-start evidence') -ceq
        'passed-exact-current-integrated-launcher-resource-release-lab' -and
        [int](Get-Property $cold 'normalLauncherStartCount' 'cold-start evidence') -eq 3 -and
        (Get-Property $cold 'allThreeRetainedExactRc3' 'cold-start evidence') -is [bool] -and
        [bool](Get-Property $cold 'allThreeRetainedExactRc3' 'cold-start evidence')) `
        'The exact-build three-cold-start evidence is absent.'
    $observed = @(Get-Property $cold 'effectiveXmxMiBByStart' 'cold-start evidence')
    Require ($observed.Count -eq 3 -and
        @($observed | Where-Object { [int]$_ -ne 1536 }).Count -eq 0) `
        'The three cold starts did not all observe Xmx=1536 MiB.'
    Require ([string](Get-Property $cold 'launcherMemoryLog' 'cold-start evidence') -ceq
        'Xms=512MiB, Xmx=1536MiB (auto)') `
        'The cold-start JVM memory log contract drifted.'
    Require ((ConvertTo-Sha256 (Get-Property $cold 'appliesToApkSha256' `
                'cold-start evidence') 'cold-start APK SHA-256') -ceq
        $script:ExpectedApkSha256) 'Cold-start evidence belongs to another APK.'
    Require ((ConvertTo-Sha256 (Get-Property $cold 'persistentManagedCoreSha256' `
                'cold-start evidence') 'cold-start Core SHA-256') -ceq
        $script:ExpectedCoreSha256) 'Cold-start evidence belongs to another Core.'
    Require ((ConvertTo-Sha256 (Get-Property $cold 'persistentManagedVeqSha256' `
                'cold-start evidence') 'cold-start VEQ SHA-256') -ceq
        $script:ExpectedVeqSha256) 'Cold-start evidence belongs to another VEQ.'
    Require ((ConvertTo-Sha256 (Get-Property $cold 'appliesToPojlibAarSha256' `
                'cold-start evidence') 'cold-start Pojlib SHA-256') -ceq
        $script:ExpectedPojlibSha256) 'Cold-start evidence belongs to another Pojlib AAR.'

    $release = Get-Property $Lock 'launcherResourceReleaseEvidence' 'RC3 lock'
    Require ([string](Get-Property $release 'policy' 'launcher release evidence') -ceq
        'default-on-only-for-exact-v71-lab-and-stable-identities-lab-authenticated-ab-may-override') `
        'The exact-build launcher-resource-release policy drifted.'
}

function Get-SoakEvidence(
    [string] $SummaryPath,
    [string] $SamplesPath,
    [string] $ProducerSha256,
    [int] $Index
) {
    $summary = Read-Json $SummaryPath "soak $Index summary"
    Require ([int](Get-Property $summary 'schemaVersion' "soak $Index summary") -eq 1 -and
        [string](Get-Property $summary 'package' "soak $Index summary") -ceq
            $script:ExpectedPackage) "Soak $Index summary identity drifted."
    $acceptance = Get-Property $summary 'acceptance' "soak $Index summary"
    Require ((Get-Property $acceptance 'passed' "soak $Index acceptance") -is [bool] -and
        [bool](Get-Property $acceptance 'passed' "soak $Index acceptance")) `
        "Soak $Index is not a passing capture."
    $provenance = Get-Property $summary 'provenance' "soak $Index summary"
    foreach ($field in @('installedIdentityMatched', 'baseApkMatched',
            'persistentCoreMatched', 'persistentVeqMatched', 'allMatched')) {
        $value = Get-Property $provenance $field "soak $Index provenance"
        Require ($value -is [bool] -and [bool]$value) `
            "Soak $Index provenance failed $field."
    }
    $producer = ConvertTo-Sha256 $ProducerSha256 "soak $Index producer SHA-256"
    Require ($producer -ceq $script:ExpectedCurrentMemoryProducerSha256 -or
        ($Index -eq 1 -and $producer -ceq $script:ExpectedLegacyMemoryProducerSha256)) `
        "Soak $Index did not use an allowed reviewed producer."
    $sampleRows = @(Get-Content -LiteralPath $SamplesPath | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    Require ($sampleRows.Count -eq 19) "Soak $Index raw sample count drifted."
    $last = $sampleRows[-1] | ConvertFrom-Json
    Require ([int](Get-Property $last 'pid' "soak $Index final sample") -eq
        [int](Get-Property $summary 'initialPid' "soak $Index summary") -and
        [bool](Get-Property $last 'pidStable' "soak $Index final sample") -and
        [bool](Get-Property $last 'gameJvmAlive' "soak $Index final sample")) `
        "Soak $Index final sample is not the original live JVM."
    return [pscustomobject][ordered]@{
        index = $Index
        summarySha256 = Get-FileSha256 $SummaryPath
        samplesSha256 = Get-FileSha256 $SamplesPath
        producerSha256 = $producer
        startedUtc = [DateTimeOffset]::Parse(
            [string](Get-Property $summary 'startedUtc' "soak $Index summary")).ToUniversalTime().ToString('o')
        finalSampleUtc = [DateTimeOffset]::Parse(
            [string](Get-Property $last 'timestampUtc' "soak $Index final sample")).ToUniversalTime().ToString('o')
        initialPid = [int](Get-Property $summary 'initialPid' "soak $Index summary")
    }
}

function Assert-DirectSoak2Receipt(
    $Receipt,
    [string] $ReceiptSha256,
    $Soak2,
    [string] $ExpectedProducerSha256
) {
    Require ([int](Get-Property $Receipt 'schemaVersion' 'direct soak-2 receipt') -eq 1 -and
        [string](Get-Property $Receipt 'receiptType' 'direct soak-2 receipt') -ceq
            'V71_MEMORY_SOAK2_DIRECT_RUNTIME' -and
        [string](Get-Property $Receipt 'result' 'direct soak-2 receipt') -ceq 'PASS') `
        'The direct soak-2 receipt is not a PASS receipt.'
    $producer = Get-Property $Receipt 'producer' 'direct soak-2 receipt'
    Require ([string](Get-Property $producer 'hashScheme' 'direct soak-2 producer') -ceq
        $script:HashScheme -and
        (ConvertTo-Sha256 (Get-Property $producer 'sha256' 'direct soak-2 producer') `
            'direct soak-2 producer SHA-256') -ceq $ExpectedProducerSha256) `
        'The direct soak-2 receipt came from another producer.'
    $capture = Get-Property $Receipt 'capture' 'direct soak-2 receipt'
    Require ([int](Get-Property $capture 'index' 'direct soak-2 capture') -eq 2 -and
        (ConvertTo-Sha256 (Get-Property $capture 'summarySha256' `
            'direct soak-2 capture') 'direct soak-2 summary SHA-256') -ceq
            [string]$Soak2.summarySha256 -and
        (ConvertTo-Sha256 (Get-Property $capture 'samplesSha256' `
            'direct soak-2 capture') 'direct soak-2 samples SHA-256') -ceq
            [string]$Soak2.samplesSha256 -and
        (ConvertTo-Sha256 (Get-Property $capture 'producerSha256' `
            'direct soak-2 capture') 'direct soak-2 sampler SHA-256') -ceq
            [string]$Soak2.producerSha256 -and
        [int](Get-Property $capture 'initialPid' 'direct soak-2 capture') -eq
            [int]$Soak2.initialPid) `
        'The direct receipt is detached from the immutable soak-2 capture.'
    $observed = Get-Property $Receipt 'observed' 'direct soak-2 receipt'
    foreach ($field in @(
        'sameAndroidPidStillAlive', 'currentProcessLatestlog',
        'exactJvmMemoryLineObserved', 'launcherResourceReleaseAppliedObserved')) {
        $value = Get-Property $observed $field 'direct soak-2 observation'
        Require ($value -is [bool] -and [bool]$value) `
            "Direct soak-2 observation failed $field."
    }
    Require ([int](Get-Property $observed 'xmsMiB' 'direct soak-2 observation') -eq 512 -and
        [int](Get-Property $observed 'xmxMiB' 'direct soak-2 observation') -eq 1536 -and
        [string](Get-Property $observed 'xmxSource' 'direct soak-2 observation') -ceq
            'auto' -and
        [int](Get-Property $observed 'jvmMemoryLineCount' `
            'direct soak-2 observation') -eq 1 -and
        [int](Get-Property $observed 'launcherReleaseAppliedMarkerCount' `
            'direct soak-2 observation') -ge 1 -and
        [int](Get-Property $observed 'launcherReleaseDegradedMarkerCount' `
            'direct soak-2 observation') -eq 0) `
        'Direct soak-2 memory or launcher-release values drifted.'
    $boundary = Get-Property $Receipt 'evidenceBoundary' 'direct soak-2 receipt'
    foreach ($field in @('rawLogsPersisted', 'logSnippetsPersisted',
            'deviceSerialPersisted', 'accountDataPersisted', 'hostAbsolutePathsPersisted')) {
        $value = Get-Property $boundary $field 'direct soak-2 boundary'
        Require ($value -is [bool] -and -not [bool]$value) `
            "Direct soak-2 receipt persisted forbidden field $field."
    }
    $directReceiptSha = ConvertTo-Sha256 $ReceiptSha256 `
        'direct soak-2 receipt SHA-256'
    return [pscustomobject][ordered]@{
        index = 2
        available = $true
        receiptSha256 = $directReceiptSha
        sameAndroidPid = $true
        initialPid = [int]$Soak2.initialPid
        xmsMiB = 512
        xmxMiB = 1536
        xmxSource = 'auto'
        launcherResourceReleaseApplied = $true
    }
}

function Invoke-ReadOnlyAdb([string[]] $Arguments) {
    $values = @(& $script:DirectAdb @Arguments 2>&1 | ForEach-Object {
        [string]$_
    })
    $exitCode = $LASTEXITCODE
    Require ($exitCode -eq 0) `
        "A read-only device probe failed with exit code $exitCode."
    $script:DirectDeviceInvocationCount++
    return $values
}

function New-MemoryRuntimeContractReceipt(
    $Rc3Lock,
    [object[]] $Soaks,
    $LifecycleReceipt,
    [string] $LifecycleReceiptSha256,
    $DirectSoak2Receipt,
    [string] $DirectSoak2ReceiptSha256,
    [string] $ProducerSha256,
    [DateTimeOffset] $CreatedUtc
) {
    Assert-Rc3Contract $Rc3Lock
    Require ($Soaks.Count -eq 2) 'Exactly two memory captures are required.'
    Require ([string](Get-Property $LifecycleReceipt 'receiptType' 'lifecycle receipt') -ceq
        'V71_LAB_LIFECYCLE_RECOVERY' -and
        [string](Get-Property $LifecycleReceipt 'result' 'lifecycle receipt') -ceq 'PASS') `
        'The lifecycle receipt is not a PASS v71 lifecycle receipt.'
    Assert-ExactLabIdentity (Get-Property $LifecycleReceipt 'labIdentity' 'lifecycle receipt') `
        'lifecycle receipt identity'
    $lineage = Get-Property $LifecycleReceipt 'producerLineage' 'lifecycle receipt'
    $lineageFiles = @(Get-Property $lineage 'files' 'lifecycle producer lineage')
    Require ($lineageFiles.Count -ge 1 -and
        (ConvertTo-Sha256 (Get-Property $lineageFiles[0] 'sha256' `
                'lifecycle producer') 'lifecycle producer SHA-256') -ceq
            $script:ExpectedLifecycleProducerSha256) `
        'The lifecycle receipt was produced by an unreviewed orchestrator.'
    $sensitiveBoundary = Get-Property $LifecycleReceipt 'evidenceBoundary' 'lifecycle receipt'
    Require ((Get-Property $sensitiveBoundary 'deviceSerialPersisted' `
            'lifecycle evidence boundary') -is [bool] -and
        -not [bool](Get-Property $sensitiveBoundary 'deviceSerialPersisted' `
            'lifecycle evidence boundary')) 'Lifecycle receipt persisted a device serial.'
    $directSoak2 = if ($null -eq $DirectSoak2Receipt) {
        [pscustomobject][ordered]@{
            index = 2
            available = $false
            reason = 'not-captured-before-process-exit-or-marker-unavailable'
        }
    } else {
        Assert-DirectSoak2Receipt `
            -Receipt $DirectSoak2Receipt `
            -ReceiptSha256 $DirectSoak2ReceiptSha256 `
            -Soak2 $Soaks[1] `
            -ExpectedProducerSha256 $ProducerSha256
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_MEMORY_RUNTIME_CONTRACT'
        result = 'PASS'
        createdUtc = $CreatedUtc.ToUniversalTime().ToString('o')
        producer = [pscustomobject][ordered]@{
            hashScheme = $script:HashScheme
            sha256 = ConvertTo-Sha256 $ProducerSha256 'memory-contract producer SHA-256'
        }
        labIdentity = [pscustomobject][ordered]@{
            package = $script:ExpectedPackage
            forbiddenStablePackage = $script:ExpectedStablePackage
            versionCode = $script:ExpectedVersionCode
            versionName = $script:ExpectedVersionName
            apkSha256 = $script:ExpectedApkSha256
            apkSizeBytes = $script:ExpectedApkSizeBytes
            coreSha256 = $script:ExpectedCoreSha256
            veqSha256 = $script:ExpectedVeqSha256
            signerSha256 = $script:ExpectedSignerSha256
        }
        memoryPolicy = [pscustomobject][ordered]@{
            xmsMiB = 512
            automaticXmxMiB = 1536
            manualXmxHardCapMiB = 2048
            pojlibAarSha256 = $script:ExpectedPojlibSha256
            exactColdStartObservations = 3
            allColdStartsObservedAutomatic1536 = $true
            evidenceBasis = 'exact-apk-contract-plus-three-observed-cold-starts'
            perSoakJvmArgumentObservedDirectly = $false
        }
        launcherResourceRelease = [pscustomobject][ordered]@{
            exactBuildDefaultOn = $true
            lifecycleProducerRequestsOn = $true
            lifecycleReceiptSha256 = ConvertTo-Sha256 $LifecycleReceiptSha256 `
                'lifecycle receipt SHA-256'
            evidenceBasis = 'exact-apk-default-on-policy-plus-reviewed-on-lifecycle-producer'
            perSoakAppliedMarkerObservedDirectly = $false
        }
        soaks = $Soaks
        directObservations = @(
            [pscustomobject][ordered]@{
                index = 1
                available = $false
                reason = 'historical-process-ended-before-reviewed-direct-observer'
            },
            $directSoak2
        )
        evidenceBoundary = [pscustomobject][ordered]@{
            crossEvidenceContractNotPerProcessAttestation = $true
            directPerSoakJvmArgumentClaim = $false
            directPerSoakResourceReleaseMarkerClaim = $false
            rawLogsPersisted = $false
            logSnippetsPersisted = $false
            deviceSerialPersisted = $false
            accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
}

function Write-AtomicWriteOnceJson($Value, [string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    Require (-not (Test-Path -LiteralPath $full)) `
        'The fixed memory-contract receipt already exists; archive and relock it first.'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    $temporary = $full + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $full)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return [pscustomobject]@{
        Path = $full
        Sha256 = Get-FileSha256 $full
        SizeBytes = (Get-Item -LiteralPath $full).Length
    }
}

if ($Action -ceq 'SelfTest') {
    Require ($script:ExpectedPackage -ceq 'com.qcxr.qcxr.canary262') 'Lab package drifted.'
    Require ($script:ExpectedStablePackage -ceq 'com.qcxr.qcxr.dev262') 'Stable guard drifted.'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    Require ($parseErrors.Count -eq 0) 'The Host-only producer has parser errors.'
    $commandNames = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    Require (@($commandNames | Where-Object { $_ -cin @('adb', 'adb.exe') }).Count -eq 0) `
        'The Host-only producer invokes a device command.'
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v71-memory-contract-' +
        [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    try {
        $path = Join-Path $tempRoot 'receipt.json'
        $fixture = [pscustomobject][ordered]@{ schemaVersion = 1; result = 'PASS' }
        $first = Write-AtomicWriteOnceJson $fixture $path
        Require ((Get-FileSha256 $path) -ceq [string]$first.Sha256) `
            'Atomic receipt hash self-test failed.'
        $rejected = $false
        try { $null = Write-AtomicWriteOnceJson $fixture $path } catch { $rejected = $true }
        Require $rejected 'Write-once receipt accepted an overwrite.'
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
    $selfSha = Get-TextSha256 $PSCommandPath
    $fixtureSoaks = @(
        [pscustomobject][ordered]@{
            index = 1; summarySha256 = '1' * 64; samplesSha256 = '2' * 64
            producerSha256 = $script:ExpectedLegacyMemoryProducerSha256
            startedUtc = '2026-09-06T06:16:23.0000000+00:00'
            finalSampleUtc = '2026-09-06T07:46:23.0000000+00:00'; initialPid = 111
        },
        [pscustomobject][ordered]@{
            index = 2; summarySha256 = '3' * 64; samplesSha256 = '4' * 64
            producerSha256 = $script:ExpectedCurrentMemoryProducerSha256
            startedUtc = '2026-09-06T08:16:23.0000000+00:00'
            finalSampleUtc = '2026-09-06T09:46:23.0000000+00:00'; initialPid = 222
        }
    )
    $fixtureIdentity = [pscustomobject][ordered]@{
        package = $script:ExpectedPackage
        forbiddenStablePackage = $script:ExpectedStablePackage
        versionCode = $script:ExpectedVersionCode
        versionName = $script:ExpectedVersionName
        apkSha256 = $script:ExpectedApkSha256
        apkSizeBytes = $script:ExpectedApkSizeBytes
        coreSha256 = $script:ExpectedCoreSha256
        veqSha256 = $script:ExpectedVeqSha256
        signerSha256 = $script:ExpectedSignerSha256
    }
    $fixtureLifecycle = [pscustomobject][ordered]@{
        receiptType = 'V71_LAB_LIFECYCLE_RECOVERY'; result = 'PASS'
        labIdentity = $fixtureIdentity
        producerLineage = [pscustomobject][ordered]@{
            files = @([pscustomobject][ordered]@{
                sha256 = $script:ExpectedLifecycleProducerSha256
            })
        }
        evidenceBoundary = [pscustomobject][ordered]@{ deviceSerialPersisted = $false }
    }
    $fixtureLifecycleSha = '5' * 64
    $crossOnly = New-MemoryRuntimeContractReceipt `
        -Rc3Lock (Read-Json (Join-Path (Split-Path -Parent $PSScriptRoot) `
            'V71_LAB_RC3.lock.json') 'RC3 lock') `
        -Soaks $fixtureSoaks `
        -LifecycleReceipt $fixtureLifecycle `
        -LifecycleReceiptSha256 $fixtureLifecycleSha `
        -DirectSoak2Receipt $null `
        -DirectSoak2ReceiptSha256 '' `
        -ProducerSha256 $selfSha `
        -CreatedUtc ([DateTimeOffset]::UtcNow)
    Require (-not [bool]$crossOnly.directObservations[0].available -and
        -not [bool]$crossOnly.directObservations[1].available) `
        'Cross-evidence-only receipt availability is incorrect.'
    $fixtureDirect = [pscustomobject][ordered]@{
        schemaVersion = 1; receiptType = 'V71_MEMORY_SOAK2_DIRECT_RUNTIME'
        result = 'PASS'
        producer = [pscustomobject][ordered]@{
            hashScheme = $script:HashScheme; sha256 = $selfSha
        }
        capture = [pscustomobject][ordered]@{
            index = 2; summarySha256 = $fixtureSoaks[1].summarySha256
            samplesSha256 = $fixtureSoaks[1].samplesSha256
            producerSha256 = $fixtureSoaks[1].producerSha256; initialPid = 222
        }
        observed = [pscustomobject][ordered]@{
            sameAndroidPidStillAlive = $true; currentProcessLatestlog = $true
            exactJvmMemoryLineObserved = $true; launcherResourceReleaseAppliedObserved = $true
            xmsMiB = 512; xmxMiB = 1536; xmxSource = 'auto'; jvmMemoryLineCount = 1
            launcherReleaseAppliedMarkerCount = 1; launcherReleaseDegradedMarkerCount = 0
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            rawLogsPersisted = $false; logSnippetsPersisted = $false
            deviceSerialPersisted = $false; accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
    $withDirect = New-MemoryRuntimeContractReceipt `
        -Rc3Lock (Read-Json (Join-Path (Split-Path -Parent $PSScriptRoot) `
            'V71_LAB_RC3.lock.json') 'RC3 lock') `
        -Soaks $fixtureSoaks `
        -LifecycleReceipt $fixtureLifecycle `
        -LifecycleReceiptSha256 $fixtureLifecycleSha `
        -DirectSoak2Receipt $fixtureDirect `
        -DirectSoak2ReceiptSha256 ('6' * 64) `
        -ProducerSha256 $selfSha `
        -CreatedUtc ([DateTimeOffset]::UtcNow)
    Require ([bool]$withDirect.directObservations[1].available -and
        [int]$withDirect.directObservations[1].initialPid -eq 222) `
        'Valid direct same-process soak-2 evidence was not retained.'
    [pscustomobject]@{
        Result = 'PASS'
        SelfTestHostOnly = $true
        CreateHostOnly = $true
        DeviceInvocations = 0
        AtomicWriteOnce = $true
        ExplicitCrossEvidenceBoundary = $true
        DirectCaptureRequiresExplicitReadOnlyAuthorization = $true
        CrossEvidenceReceiptValidated = $true
        DirectSoak2ReceiptValidated = $true
        ProducerSha256 = $selfSha
    }
    return
}

if ($Action -ceq 'CaptureDirectSoak2') {
    Require $AllowReadOnlyDeviceProbe.IsPresent `
        'CaptureDirectSoak2 requires explicit -AllowReadOnlyDeviceProbe.'
    Require (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) `
        'CaptureDirectSoak2 requires an explicit workspace root.'
    $root = [IO.Path]::GetFullPath($WorkspaceRoot)
    $summary2 = Assert-ContainedFile $Soak2SummaryPath $root 'soak 2 summary'
    $samples2 = Assert-ContainedFile $Soak2SamplesPath $root 'soak 2 samples'
    $soak2 = Get-SoakEvidence $summary2 $samples2 $Soak2ProducerSha256 2
    Require (-not [string]::IsNullOrWhiteSpace($AdbPath) -and
        (Test-Path -LiteralPath $AdbPath -PathType Leaf)) `
        'CaptureDirectSoak2 requires an explicit ADB executable path.'
    Require ($Serial -cmatch '^[A-Za-z0-9._:-]{1,128}$') `
        'CaptureDirectSoak2 requires one explicit safe device serial.'
    $script:DirectAdb = [IO.Path]::GetFullPath($AdbPath)
    $script:DirectDeviceInvocationCount = 0
    $state = @(Invoke-ReadOnlyAdb @('-s', $Serial, 'get-state') | Where-Object {
        $_ -ceq 'device'
    })
    Require ($state.Count -eq 1) 'The explicitly selected device is not ready.'
    $pidRows = @(Invoke-ReadOnlyAdb @('-s', $Serial, 'shell', 'pidof',
        $script:ExpectedPackage) | Where-Object { $_ -cmatch '^\s*[0-9]+\s*$' })
    Require ($pidRows.Count -eq 1) 'The exact Lab package does not have one live PID.'
    $currentPid = [int]$pidRows[0].Trim()
    Require ($currentPid -eq [int]$soak2.initialPid) `
        'The live Android PID is not the PID retained throughout soak 2.'

    $memoryProbe = @(Invoke-ReadOnlyAdb @(
        '-s', $Serial, 'shell', 'sh', '-c',
        ('set -eu; log=/sdcard/Android/data/{0}/files/latestlog.txt; ' +
         'test -f "$log" && test ! -L "$log"; ' +
         'count=$(grep -F -x -c -e ''Setting JVM memory: Xms=512MiB, Xmx=1536MiB (auto)'' "$log" || true); ' +
         'size=$(stat -c %s "$log"); printf ''DIRECTMEM\t%s\t%s\n'' "$count" "$size"' -f
            $script:ExpectedPackage)) | Where-Object {
                $_ -cmatch '^DIRECTMEM\t[0-9]+\t[0-9]+$'
            })
    Require ($memoryProbe.Count -eq 1) `
        'The current-process launcher log memory probe was ambiguous.'
    $null = $memoryProbe[0] -cmatch '^DIRECTMEM\t(?<count>[0-9]+)\t(?<size>[0-9]+)$'
    $memoryLineCount = [int]$Matches.count
    $launcherLogSize = [int64]$Matches.size
    Require ($memoryLineCount -eq 1 -and $launcherLogSize -gt 0) `
        'The current process did not record exactly Xms=512/Xmx=1536(auto).'

    $logcat = @(Invoke-ReadOnlyAdb @('-s', $Serial, 'logcat', '-d', '-v',
        'epoch', "--pid=$currentPid"))
    $appliedCount = @($logcat | Where-Object {
        $_.Contains('QC_LAUNCHER_RESOURCE_RELEASE_APPLIED',
            [StringComparison]::Ordinal)
    }).Count
    $degradedCount = @($logcat | Where-Object {
        $_.Contains('QC_LAUNCHER_RESOURCE_RELEASE_DEGRADED',
            [StringComparison]::Ordinal)
    }).Count
    Require ($appliedCount -ge 1 -and $degradedCount -eq 0) `
        'The current PID has no retained successful launcher-resource-release marker.'

    $directReceipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_MEMORY_SOAK2_DIRECT_RUNTIME'
        result = 'PASS'
        createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
        producer = [pscustomobject][ordered]@{
            hashScheme = $script:HashScheme
            sha256 = Get-TextSha256 $PSCommandPath
        }
        capture = [pscustomobject][ordered]@{
            index = 2
            summarySha256 = $soak2.summarySha256
            samplesSha256 = $soak2.samplesSha256
            producerSha256 = $soak2.producerSha256
            startedUtc = $soak2.startedUtc
            initialPid = $soak2.initialPid
        }
        observed = [pscustomobject][ordered]@{
            sameAndroidPidStillAlive = $true
            currentProcessLatestlog = $true
            exactJvmMemoryLineObserved = $true
            xmsMiB = 512
            xmxMiB = 1536
            xmxSource = 'auto'
            jvmMemoryLineCount = $memoryLineCount
            launcherResourceReleaseAppliedObserved = $true
            launcherReleaseAppliedMarkerCount = $appliedCount
            launcherReleaseDegradedMarkerCount = $degradedCount
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            readOnlyDeviceProbe = $true
            processIdPersistedForSameProcessBinding = $true
            rawLogsPersisted = $false
            logSnippetsPersisted = $false
            deviceSerialPersisted = $false
            accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $root $script:DirectReceiptRelativePath
    }
    $directOutput = [IO.Path]::GetFullPath($OutputPath)
    $directAcceptanceRoot = [IO.Path]::GetFullPath(
        (Join-Path $root 'artifacts/acceptance')).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
    Require ($directOutput.StartsWith($directAcceptanceRoot,
            [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($directOutput) -ceq
            'v71-memory-soak2-direct-runtime-receipt.json') `
        'Direct receipt must use the fixed non-sensitive acceptance path.'
    $directIdentity = Write-AtomicWriteOnceJson $directReceipt $directOutput
    [pscustomobject]@{
        Result = 'PASS'
        ReceiptPath = $directIdentity.Path
        ReceiptSha256 = $directIdentity.Sha256
        ReceiptSizeBytes = $directIdentity.SizeBytes
        DeviceInvocations = $script:DirectDeviceInvocationCount
        DeviceMutations = 0
        SameProcessPid = $currentPid
        XmsMiB = 512
        XmxMiB = 1536
        LauncherResourceReleaseApplied = $true
    }
    return
}

Require $AllowReceiptWrite.IsPresent 'Create requires explicit -AllowReceiptWrite.'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = Split-Path -Parent $PSScriptRoot
}
$root = [IO.Path]::GetFullPath($WorkspaceRoot)
$rc3LockPath = Assert-ContainedFile (Join-Path $root 'V71_LAB_RC3.lock.json') `
    $root 'RC3 lock'
$summary1 = Assert-ContainedFile $Soak1SummaryPath $root 'soak 1 summary'
$samples1 = Assert-ContainedFile $Soak1SamplesPath $root 'soak 1 samples'
$summary2 = Assert-ContainedFile $Soak2SummaryPath $root 'soak 2 summary'
$samples2 = Assert-ContainedFile $Soak2SamplesPath $root 'soak 2 samples'
$lifecyclePath = Assert-ContainedFile $LifecycleReceiptPath $root 'lifecycle receipt'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root $script:DefaultReceiptRelativePath
}
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$acceptanceRoot = [IO.Path]::GetFullPath(
    (Join-Path $root 'artifacts/acceptance')).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
Require ($outputFull.StartsWith($acceptanceRoot, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($outputFull) -ceq
        'v71-memory-runtime-contract-receipt.json') `
    'Receipt output must use the fixed non-sensitive acceptance path.'

$soaks = @(
    Get-SoakEvidence $summary1 $samples1 $Soak1ProducerSha256 1
    Get-SoakEvidence $summary2 $samples2 $Soak2ProducerSha256 2
)
Require ([DateTimeOffset]::Parse([string]$soaks[1].startedUtc) -
        [DateTimeOffset]::Parse([string]$soaks[0].startedUtc) -ge
        [TimeSpan]::FromMinutes(80)) 'The memory captures are not distinct rounds.'
$lifecycleReceipt = Read-Json $lifecyclePath 'lifecycle receipt'
$directSoak2Receipt = $null
$directSoak2ReceiptSha256 = ''
if (-not [string]::IsNullOrWhiteSpace($DirectSoak2ReceiptPath)) {
    $directPath = Assert-ContainedFile $DirectSoak2ReceiptPath $root `
        'direct soak-2 receipt'
    $directSoak2Receipt = Read-Json $directPath 'direct soak-2 receipt'
    $directSoak2ReceiptSha256 = Get-FileSha256 $directPath
}
$receipt = New-MemoryRuntimeContractReceipt `
    -Rc3Lock (Read-Json $rc3LockPath 'RC3 lock') `
    -Soaks $soaks `
    -LifecycleReceipt $lifecycleReceipt `
    -LifecycleReceiptSha256 (Get-FileSha256 $lifecyclePath) `
    -DirectSoak2Receipt $directSoak2Receipt `
    -DirectSoak2ReceiptSha256 $directSoak2ReceiptSha256 `
    -ProducerSha256 (Get-TextSha256 $PSCommandPath) `
    -CreatedUtc ([DateTimeOffset]::UtcNow)
$identity = Write-AtomicWriteOnceJson $receipt $outputFull
[pscustomobject]@{
    Result = 'PASS'
    ReceiptPath = $identity.Path
    ReceiptSha256 = $identity.Sha256
    ReceiptSizeBytes = $identity.SizeBytes
    DeviceInvocations = 0
    DirectPerSoakJvmArgumentClaim = $false
    DirectPerSoakResourceReleaseMarkerClaim = $false
}
