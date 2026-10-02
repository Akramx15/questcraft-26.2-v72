#requires -Version 7.0
<#
.SYNOPSIS
Authenticates the exact RC6.2 inputs for the Personal v71 Stable build.

.DESCRIPTION
This is a Host-only, fail-closed build-admission gate. SelfTest authenticates
the exact source trees, managed payload, Pojlib AAR, Lab APK, Unity editor,
manual receipt, and immutable runtime-result receipt. Build performs the same
checks and then requires the immutable receipt to authorize promotion.

The currently locked RC6.2 receipt records a formal memory failure and denies
Stable promotion, so Build must stop before Unity or any filesystem mutation.
There is deliberately no force, skip, or override parameter.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Build')]
    [string] $Action = 'SelfTest',

    [string] $UnityEditor = (Join-Path $env:USERPROFILE `
        'Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prefix = '[V71_RC62_STABLE_BUILD]'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DeviceInvocations = 0
$script:UnityInvocations = 0

$script:Expected = [ordered]@{
    SourceBaseCommit = 'baa7d97393e126e87649ee499e15817aba5428d2'
    SourceTrees = [ordered]@{
        'Pojlib' = 'c17471c69ea478222573fd16b531508d903b4cac'
        'QCXR-XR-Wrapper' = '14dffd58d8c9b1ff636277d3d090ba657c6daa77'
        'Vivecraft-26.2-Quest' = '3cffa5a265296e33ab8281f403da0b57ddaf6f11'
        'Vivecraft-Essentials-Quest' = '5a78be9c43baa3816655ad8b56e20456b75ddf77'
    }
    VerifyApkNormalizedSha256 =
        'C6F5A77ABE9B313B95FE0BBBE8884C02209F735833BC087E7D8F1C9464119D99'
    ProjectSettingsSha256 =
        'E45F52C082C8E49C24C2EE12C5793D2C8E03136E4FC9E7515158AFB2995DD36E'
    PersonalBuilderSha256 =
        'C6E6D99E8C1D8047F48AFBE2A285438FFF8341E2570F8FA30043208EBC51CF85'
    GenericBuilderSha256 =
        '26A007099977E862446E4CDB54B9EDBF8EDEFA47CE26BED5E3ECE62E3B636B13'
    UnityEditorSha256 =
        '02E80B2C1D7F983375C97B612655BE9F8ED852121E3A4EEDF1570701C48EA5CD'
    UnityProductVersion = '2022.3.62f3_96770f904ca7'
    BuildLockPath = 'V71_LAB_RC6_2.lock.json'
    BuildLockSha256 =
        '7DD25F7703A4E2B1F2857FD8EB552CB303CB3A1870779ADBD5708B3F5D1B7E45'
    RuntimeReceiptPath = 'V71_RC6_2_RUNTIME_RESULT.lock.json'
    RuntimeReceiptSha256 =
        'A0B37CCAAA67E0D0E4BA7C4E5CA80745707958F26B113638ABDEFB264788770C'
    ManualReceiptPath =
        'artifacts/manual/v71-rc6.2-user-acceptance-20260907.json'
    ManualReceiptSha256 =
        'C321B3CDE43807D68C8A6C8C942FF92FEE2DA046B90FA2F09F1664914CABA12E'
    LabApkPath =
        'QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.6.2-tight-space-local.apk'
    LabApkSha256 =
        'ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4'
    LabApkSizeBytes = 128459705L
    LabPackage = 'com.qcxr.qcxr.canary262'
    LabLabel = 'QuestCraft Vivecraft Lab 26.2'
    LabVersionCode = '71'
    LabVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.6.2'
    StablePackage = 'com.qcxr.qcxr.dev262'
    StableLabel = 'QuestCraft Vivecraft Personal 26.2'
    StableVersionCode = '71'
    StableVersionName = '6.0.1-26.2-vivecraft-personal.12'
    StableOutput = 'Builds/QuestCraft-Vivecraft-26.2-personal.12-local.apk'
    SignerSha256 =
        'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
    CorePath = 'Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin'
    CoreSha256 =
        '6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF'
    CoreSizeBytes = 10068468L
    CoreVersion = '26.2-1.3.15+qc.v71.rc6.2'
    VeqPath = 'Pojlib/src/main/assets/mods/vivecraft-essentials-quest.bin'
    VeqSha256 =
        'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
    VeqSizeBytes = 443280L
    VeqVersion = '0.7.0-v71.rc6'
    PairSha256 =
        'EA2E063BF3B2B38B3B8EB28CA014C5D6144DC61BFC37BE4F3042CDE27FE8C30A'
    AarPath = 'QCXR-XR-Wrapper/Assets/Plugins/Android/Pojlib-release.aar'
    AarSha256 =
        '6B9224C6697D00DCE363AD80EA5FA9946E90808C514517BA4EEDFEB31DB2BA89'
    AarSizeBytes = 88724129L
    LwjglSha256 =
        'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'
}

function Fail([Parameter(Mandatory)][string] $Message) {
    throw "$($script:Prefix) $Message"
}

function Require([bool] $Condition, [Parameter(Mandatory)][string] $Message) {
    if (-not $Condition) { Fail $Message }
}

function Resolve-RepoFile([Parameter(Mandatory)][string] $RelativePath) {
    Require (-not [IO.Path]::IsPathRooted($RelativePath)) `
        "Repository path must be relative: $RelativePath"
    $root = [IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    Require ($candidate.StartsWith(
            $root + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) `
        "Repository path escaped the root: $RelativePath"
    return $candidate
}

function Get-Sha256([Parameter(Mandatory)][string] $Path) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "Required file is missing: $Path"
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "Required text file is missing: $Path"
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($text)))
}

function Get-RequiredProperty(
    [Parameter(Mandatory)][object] $Object,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Context) {
    $property = $Object.PSObject.Properties[$Name]
    Require ($null -ne $property -and $null -ne $property.Value) `
        "$Context is missing '$Name'."
    return $property.Value
}

function Read-ExactJson(
    [Parameter(Mandatory)][string] $RelativePath,
    [Parameter(Mandatory)][string] $ExpectedSha256,
    [Parameter(Mandatory)][string] $Label) {
    $path = Resolve-RepoFile $RelativePath
    Require ((Get-Sha256 $path) -ceq $ExpectedSha256) "$Label SHA-256 drifted."
    try {
        return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    } catch {
        Fail "$Label is not valid JSON: $($_.Exception.Message)"
    }
}

function Invoke-GitLine([Parameter(Mandatory)][string[]] $Arguments) {
    $output = @(& git -C $script:RepoRoot @Arguments 2>$null)
    Require ($LASTEXITCODE -eq 0 -and $output.Count -eq 1) `
        "Git command failed: git $($Arguments -join ' ')"
    return ([string]$output[0]).Trim()
}

function Assert-SourceTrees {
    $base = $script:Expected.SourceBaseCommit
    & git -C $script:RepoRoot cat-file -e ($base + '^{commit}') 2>$null
    Require ($LASTEXITCODE -eq 0) 'The audited RC6.2 source-base commit is unavailable.'
    & git -C $script:RepoRoot merge-base --is-ancestor $base HEAD 2>$null
    Require ($LASTEXITCODE -eq 0) 'The audited RC6.2 source base is not an ancestor of HEAD.'

    $criticalPaths = @($script:Expected.SourceTrees.Keys)
    foreach ($relativePath in $criticalPaths) {
        $actualTree = Invoke-GitLine @('rev-parse', "HEAD:$relativePath")
        Require ($actualTree -ceq [string]$script:Expected.SourceTrees[$relativePath]) `
            "Committed source tree drifted: $relativePath"
    }

    & git -C $script:RepoRoot diff --quiet -- @criticalPaths
    Require ($LASTEXITCODE -eq 0) 'Tracked critical source has unstaged changes.'
    & git -C $script:RepoRoot diff --cached --quiet -- @criticalPaths
    Require ($LASTEXITCODE -eq 0) 'Tracked critical source has staged changes.'
    $untracked = @(& git -C $script:RepoRoot ls-files --others --exclude-standard -- @criticalPaths)
    Require ($LASTEXITCODE -eq 0 -and $untracked.Count -eq 0) `
        'Critical source contains untracked files.'

    $verifyPath = Resolve-RepoFile 'scripts/verify-dev-apk.ps1'
    Require ((Get-NormalizedTextSha256 $verifyPath) -ceq
            $script:Expected.VerifyApkNormalizedSha256) `
        'The APK verifier drifted from the audited RC6.2 verifier.'
}

function Assert-FileIdentity(
    [Parameter(Mandatory)][string] $RelativePath,
    [Parameter(Mandatory)][string] $ExpectedSha256,
    [Parameter(Mandatory)][long] $ExpectedSize,
    [Parameter(Mandatory)][string] $Label) {
    $path = Resolve-RepoFile $RelativePath
    Require ((Get-Sha256 $path) -ceq $ExpectedSha256) "$Label SHA-256 drifted."
    Require ((Get-Item -LiteralPath $path).Length -eq $ExpectedSize) "$Label size drifted."
    return $path
}

function Get-ZipEntrySha256(
    [Parameter(Mandatory)][string] $ArchivePath,
    [Parameter(Mandatory)][string] $EntryName) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @($archive.Entries | Where-Object FullName -ceq $EntryName)
        Require ($entries.Count -eq 1) `
            "Archive must contain exactly one '$EntryName' entry."
        $stream = $entries[0].Open()
        try {
            return [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($stream))
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
}

function Assert-Manifest([Parameter(Mandatory)][string] $RelativePath) {
    $path = Resolve-RepoFile $RelativePath
    try {
        $manifest = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    } catch {
        Fail "$RelativePath is not valid JSON: $($_.Exception.Message)"
    }
    $profiles = @($manifest.versions | Where-Object name -ceq '26.2')
    Require ($profiles.Count -eq 1) "$RelativePath must contain one 26.2 profile."
    $mods = @($profiles[0].coreMods) + @($profiles[0].defaultMods)
    $expectedSlugs = @(
        'BadOptimizations', 'Fabric-API', 'Ferrite-Core', 'ImmersiveMC',
        'Lithium', 'Mod-Menu', 'Placeholder-API', 'Sodium', 'Vivecraft',
        'Vivecraft-Essentials-Quest', 'Xaero-Minimap'
    ) | Sort-Object
    $actualSlugs = @($mods | ForEach-Object { [string]$_.slug }) | Sort-Object
    Require (@(Compare-Object $expectedSlugs $actualSlugs).Count -eq 0) `
        "$RelativePath has an unexpected managed-mod set."
    foreach ($mod in $mods) {
        Require ([string]$mod.sha256 -cmatch '^[0-9A-F]{64}$') `
            "$RelativePath has an invalid SHA-256 for $($mod.slug)."
    }
    $core = @($mods | Where-Object slug -ceq 'Vivecraft')
    Require ($core.Count -eq 1 -and
            [string]$core[0].version -ceq $script:Expected.CoreVersion -and
            [string]$core[0].sha256 -ceq $script:Expected.CoreSha256 -and
            [string]$core[0].download_link -ceq
                'asset://mods/vivecraft-26.2-1.3.15-quest.bin') `
        "$RelativePath does not pin exact RC6.2 Core."
    $veq = @($mods | Where-Object slug -ceq 'Vivecraft-Essentials-Quest')
    Require ($veq.Count -eq 1 -and
            [string]$veq[0].version -ceq $script:Expected.VeqVersion -and
            [string]$veq[0].sha256 -ceq $script:Expected.VeqSha256 -and
            [string]$veq[0].download_link -ceq
                'asset://mods/vivecraft-essentials-quest.bin') `
        "$RelativePath does not pin exact RC6 VEQ."
    return $profiles[0] | ConvertTo-Json -Depth 30 -Compress
}

function Assert-ManagedPayload {
    $corePath = Assert-FileIdentity $script:Expected.CorePath `
        $script:Expected.CoreSha256 $script:Expected.CoreSizeBytes 'RC6.2 Core'
    $veqPath = Assert-FileIdentity $script:Expected.VeqPath `
        $script:Expected.VeqSha256 $script:Expected.VeqSizeBytes 'RC6 VEQ'
    $pairText = "core=$($script:Expected.CoreSha256)`nveq=$($script:Expected.VeqSha256)`n"
    $pairHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($pairText)))
    Require ($pairHash -ceq $script:Expected.PairSha256) 'Core/VEQ pair digest drifted.'

    $manifestBlocks = @(
        Assert-Manifest 'Pojlib/mods.json'
        Assert-Manifest 'Pojlib/devmods.json'
        Assert-Manifest 'Pojlib/src/main/assets/mods.json'
        Assert-Manifest 'Pojlib/src/main/assets/devmods.json'
    )
    Require (@($manifestBlocks | Sort-Object -Unique).Count -eq 1) `
        'The four managed 26.2 manifest blocks are not identical.'

    $aarPath = Assert-FileIdentity $script:Expected.AarPath `
        $script:Expected.AarSha256 $script:Expected.AarSizeBytes 'RC6.2 Pojlib AAR'
    Require ((Get-ZipEntrySha256 $aarPath `
                'assets/mods/vivecraft-26.2-1.3.15-quest.bin') -ceq
            $script:Expected.CoreSha256) 'Pojlib AAR Core payload drifted.'
    Require ((Get-ZipEntrySha256 $aarPath `
                'assets/mods/vivecraft-essentials-quest.bin') -ceq
            $script:Expected.VeqSha256) 'Pojlib AAR VEQ payload drifted.'

    return [pscustomobject]@{
        CorePath = $corePath
        VeqPath = $veqPath
        AarPath = $aarPath
        ManifestCount = $manifestBlocks.Count
    }
}

function Assert-BuildLock {
    $lock = Read-ExactJson $script:Expected.BuildLockPath `
        $script:Expected.BuildLockSha256 'RC6.2 Lab build lock'
    Require ([bool]$lock.immutable) 'RC6.2 Lab build lock is not immutable.'
    Require ([string]$lock.target.package -ceq $script:Expected.LabPackage -and
            [string]$lock.target.forbiddenStablePackage -ceq
                $script:Expected.StablePackage -and
            [int]$lock.target.versionCode -eq 71 -and
            [string]$lock.target.versionName -ceq $script:Expected.LabVersionName) `
        'RC6.2 Lab build identity drifted.'
    Require ([string]$lock.target.apkSha256 -ceq $script:Expected.LabApkSha256 -and
            [int64]$lock.target.apkSizeBytes -eq $script:Expected.LabApkSizeBytes -and
            [string]$lock.target.signerSha256 -ceq $script:Expected.SignerSha256) `
        'RC6.2 Lab APK identity drifted in its build lock.'
    Require ([string]$lock.pair.sha256 -ceq $script:Expected.PairSha256 -and
            [string]$lock.pair.core.sha256 -ceq $script:Expected.CoreSha256 -and
            [string]$lock.pair.core.fabricVersion -ceq $script:Expected.CoreVersion -and
            [string]$lock.pair.veq.sha256 -ceq $script:Expected.VeqSha256 -and
            [string]$lock.pair.veq.fabricVersion -ceq $script:Expected.VeqVersion) `
        'RC6.2 build-lock payload pair drifted.'
    Require ([string]$lock.pojlibAar.sha256 -ceq $script:Expected.AarSha256 -and
            [int64]$lock.pojlibAar.sizeBytes -eq $script:Expected.AarSizeBytes -and
            [bool]$lock.pojlibAar.cleanBuildsMatchedByteForByte) `
        'RC6.2 build-lock Pojlib AAR drifted.'
    return $lock
}

function Assert-Receipts {
    $runtime = Read-ExactJson $script:Expected.RuntimeReceiptPath `
        $script:Expected.RuntimeReceiptSha256 'immutable RC6.2 runtime receipt'
    Require ([int]$runtime.schemaVersion -eq 1 -and
            [string]$runtime.receiptType -ceq 'V71_RC6_2_RUNTIME_RESULT' -and
            [bool]$runtime.immutable) 'Runtime receipt identity drifted.'
    Require ([string]$runtime.candidate.package -ceq $script:Expected.LabPackage -and
            [int]$runtime.candidate.versionCode -eq 71 -and
            [string]$runtime.candidate.versionName -ceq $script:Expected.LabVersionName) `
        'Runtime receipt candidate identity drifted.'
    Require ([string]$runtime.candidate.apk.sha256 -ceq $script:Expected.LabApkSha256 -and
            [string]$runtime.candidate.apk.signerSha256 -ceq
                $script:Expected.SignerSha256 -and
            [string]$runtime.candidate.core.sha256 -ceq $script:Expected.CoreSha256 -and
            [string]$runtime.candidate.veq.sha256 -ceq $script:Expected.VeqSha256 -and
            [string]$runtime.candidate.pojlibAar.sha256 -ceq $script:Expected.AarSha256) `
        'Runtime receipt artifact identity drifted.'
    Require ([bool]$runtime.decision.runtimeSafetyScreenPassed) `
        'Runtime safety screen is not recorded as passed.'
    Require ([string]$runtime.memory.formalResult -ceq 'FAIL' -and
            [string]$runtime.decision.formalMemoryAcceptance -ceq 'FAIL' -and
            [string]$runtime.memory.formalFailedCriterion -ceq
                'absolutePssAtMost2457Point6Mib') `
        'The immutable formal-memory failure changed unexpectedly.'
    Require ([string]$runtime.decision.supplementaryLeakStability -ceq
            'LEAK_STABILITY_PASS') 'Supplementary leak-stability result drifted.'
    Require (-not [bool]$runtime.decision.stablePromotionAllowed) `
        'The immutable runtime receipt unexpectedly authorizes Stable.'
    $soaks = @($runtime.memory.soaks)
    Require ($soaks.Count -eq 2 -and
            @($soaks | Where-Object formalResult -cne 'FAIL').Count -eq 0) `
        'The runtime receipt no longer binds two formally failed memory soaks.'

    $manual = Read-ExactJson $script:Expected.ManualReceiptPath `
        $script:Expected.ManualReceiptSha256 'RC6.2 manual receipt'
    Require ([int]$manual.schemaVersion -eq 1 -and
            [string]$manual.receiptType -ceq 'V71_RC6_2_MANUAL_VR_INTERACTION' -and
            [string]$manual.status -ceq 'PASS_REQUIRED_STANDARD_HAND_CHECKS' -and
            [bool]$manual.userConfirmed) 'Manual receipt identity or result drifted.'
    Require ([string]$manual.identity.package -ceq $script:Expected.LabPackage -and
            [int]$manual.identity.versionCode -eq 71 -and
            [string]$manual.identity.versionName -ceq $script:Expected.LabVersionName -and
            [string]$manual.identity.apkSha256 -ceq $script:Expected.LabApkSha256 -and
            [string]$manual.identity.coreSha256 -ceq $script:Expected.CoreSha256 -and
            [string]$manual.identity.veqSha256 -ceq $script:Expected.VeqSha256) `
        'Manual receipt candidate identity drifted.'
    Require ([bool]$manual.scope.manualFunctionalAcceptance -and
            -not [bool]$manual.scope.formalMemoryAccepted -and
            -not [bool]$manual.scope.performanceAccepted -and
            -not [bool]$manual.scope.stablePromotionAuthorized) `
        'Manual receipt scope drifted or improperly authorizes promotion.'

    return [pscustomobject]@{ Runtime = $runtime; Manual = $manual }
}

function Assert-UnityIdentity([Parameter(Mandatory)][string] $EditorPath) {
    Require (Test-Path -LiteralPath $EditorPath -PathType Leaf) `
        'Unity 2022.3.62f3 editor is missing.'
    Require ((Get-Sha256 $EditorPath) -ceq $script:Expected.UnityEditorSha256) `
        'Unity editor SHA-256 drifted from the audited 2022.3.62f3 binary.'
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($EditorPath)
    Require ([string]$version.ProductVersion -ceq $script:Expected.UnityProductVersion -and
            [string]$version.CompanyName -ceq 'Unity Technologies') `
        'Unity editor product identity drifted.'

    $projectSettings = Resolve-RepoFile `
        'QCXR-XR-Wrapper/ProjectSettings/ProjectSettings.asset'
    $personalBuilder = Resolve-RepoFile `
        'QCXR-XR-Wrapper/Assets/Editor/QuestCraftPersonalV71CliBuild.cs'
    $genericBuilder = Resolve-RepoFile `
        'QCXR-XR-Wrapper/Assets/Editor/QuestCraftCliBuild.cs'
    Require ((Get-Sha256 $projectSettings) -ceq $script:Expected.ProjectSettingsSha256) `
        'Unity ProjectSettings drifted.'
    Require ((Get-Sha256 $personalBuilder) -ceq $script:Expected.PersonalBuilderSha256) `
        'Personal v71 Unity builder drifted.'
    Require ((Get-Sha256 $genericBuilder) -ceq $script:Expected.GenericBuilderSha256) `
        'Generic Unity build gate drifted.'
    $personalSource = [IO.File]::ReadAllText($personalBuilder)
    foreach ($marker in @(
        $script:Expected.StablePackage,
        $script:Expected.StableLabel,
        $script:Expected.StableVersionCode,
        $script:Expected.StableVersionName,
        $script:Expected.StableOutput,
        'QuestCraftCliBuild.BuildAcceptedPersonalV71Android()',
        'HasArgument("-release")')) {
        Require ($personalSource.Contains([string]$marker)) `
            "Personal Unity builder lost required marker: $marker"
    }
    $genericSource = [IO.File]::ReadAllText($genericBuilder)
    Require ($genericSource.Contains(
            'AcceptedPersonalApplicationIdentifier = "com.qcxr.qcxr.dev262"') -and
            $genericSource.Contains('BuildAcceptedPersonalV71Android') -and
            $genericSource.Contains('PlayerSettings.Android.useCustomKeystore = false')) `
        'Generic Unity gate no longer enforces the Personal Debug identity.'
}

function Assert-LabApk {
    $apkPath = Assert-FileIdentity $script:Expected.LabApkPath `
        $script:Expected.LabApkSha256 $script:Expected.LabApkSizeBytes 'RC6.2 Lab APK'
    $verifyPath = Resolve-RepoFile 'scripts/verify-dev-apk.ps1'
    $audit = @(& $verifyPath -ApkPath $apkPath `
        -ExpectedPackage $script:Expected.LabPackage `
        -ExpectedVersionCode $script:Expected.LabVersionCode `
        -ExpectedVersionName $script:Expected.LabVersionName `
        -ExpectedLabel $script:Expected.LabLabel `
        -ExpectedVivecraftSha256 $script:Expected.CoreSha256 `
        -ExpectedVivecraftVersion $script:Expected.CoreVersion `
        -ExpectedAddOnSha256 $script:Expected.VeqSha256 `
        -ExpectedAddOnVersion $script:Expected.VeqVersion `
        -ExpectedLwjglSha256 $script:Expected.LwjglSha256 `
        -ExpectedSignerSha256 $script:Expected.SignerSha256)
    Require ($audit.Count -eq 1) 'The APK verifier returned an unexpected result count.'
    Require ([string]$audit[0].Sha256 -ceq $script:Expected.LabApkSha256 -and
            [string]$audit[0].Package -ceq $script:Expected.LabPackage -and
            ([string]$audit[0].SignerSha256).ToUpperInvariant() -ceq
                $script:Expected.SignerSha256 -and
            [string]$audit[0].Abis -ceq 'arm64-v8a' -and
            [bool]$audit[0].Zipalign16KiB) 'The RC6.2 Lab APK audit drifted.'
    return $audit[0]
}

function Assert-HostChain([Parameter(Mandatory)][string] $EditorPath) {
    Assert-SourceTrees
    $payload = Assert-ManagedPayload
    $buildLock = Assert-BuildLock
    $receipts = Assert-Receipts
    Assert-UnityIdentity $EditorPath
    $apkAudit = Assert-LabApk
    return [pscustomobject]@{
        Payload = $payload
        BuildLock = $buildLock
        Receipts = $receipts
        ApkAudit = $apkAudit
    }
}

$chain = Assert-HostChain $UnityEditor
$runtimeDecision = $chain.Receipts.Runtime.decision

if ($Action -ceq 'Build') {
    $formalMemory = [string]$runtimeDecision.formalMemoryAcceptance
    $promotionAllowed = [bool]$runtimeDecision.stablePromotionAllowed
    if ($formalMemory -cne 'PASS' -or -not $promotionAllowed) {
        Fail ("Stable Build prohibited after all source/artifact checks passed: " +
            "formalMemoryAcceptance=$formalMemory; " +
            "stablePromotionAllowed=$($promotionAllowed.ToString().ToLowerInvariant()). " +
            'No override is supported.')
    }
    Fail 'Stable Build lacks a separately reviewed RC6.2 authorization receipt.'
}

[pscustomobject]@{
    Result = 'PASS_SOURCE_AND_ARTIFACTS_PROMOTION_BLOCKED'
    HostOnly = $true
    DeviceInvocations = $script:DeviceInvocations
    UnityInvocations = $script:UnityInvocations
    SourceBaseCommit = $script:Expected.SourceBaseCommit
    SourceTreesVerified = $script:Expected.SourceTrees.Count
    ManifestsVerified = $chain.Payload.ManifestCount
    LabApkSha256 = [string]$chain.ApkAudit.Sha256
    CoreSha256 = $script:Expected.CoreSha256
    VeqSha256 = $script:Expected.VeqSha256
    PojlibAarSha256 = $script:Expected.AarSha256
    SignerSha256 = $script:Expected.SignerSha256
    UnityProductVersion = $script:Expected.UnityProductVersion
    StablePackage = $script:Expected.StablePackage
    StableVersionCode = $script:Expected.StableVersionCode
    StableVersionName = $script:Expected.StableVersionName
    StableOutput = $script:Expected.StableOutput
    ManualAcceptance = [string]$chain.Receipts.Manual.status
    FormalMemoryAcceptance = [string]$runtimeDecision.formalMemoryAcceptance
    StablePromotionAllowed = [bool]$runtimeDecision.stablePromotionAllowed
    BuildActionAvailable = $false
}
