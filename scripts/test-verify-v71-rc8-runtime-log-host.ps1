#requires -Version 7.0
<# Host-only synthetic tests for the V71 RC8 runtime-log verifier. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prefix = '[V71_RC8_RUNTIME_LOG_SELF_TEST]'
$script:Verifier = Join-Path $PSScriptRoot 'verify-v71-rc8-runtime-log.ps1'

function Require([bool] $Condition, [Parameter(Mandatory)][string] $Message) {
    if (-not $Condition) { throw "$($script:Prefix) $Message" }
}

function Write-Fixture(
    [Parameter(Mandatory)][string] $Directory,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Text
) {
    $path = Join-Path $Directory ($Name + '.log')
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
    return $path
}

function Assert-Rejected(
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Directory
) {
    $path = Write-Fixture $Directory $Name $Text
    $rejected = $false
    try {
        & $script:Verifier -LogPath $path | Out-Null
    } catch {
        $rejected = $_.Exception.Message.Contains(
            '[V71_RC8_RUNTIME_LOG]', [StringComparison]::Ordinal)
    }
    Require $rejected "Fail-closed fixture was accepted: $Name"
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $script:Verifier, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'PowerShell rejected the verifier source.'

$commandNames = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ })
$forbiddenCommands = @($commandNames | Where-Object {
        $_ -match '^(?:adb|curl|wget|Invoke-WebRequest|Invoke-RestMethod|Start-Process|Remove-Item|Set-Content|Add-Content|Out-File|Copy-Item|Move-Item|New-Item)$'
    })
Require ($forbiddenCommands.Count -eq 0) `
    "Verifier contains a forbidden device/network/write command: $($forbiddenCommands -join ', ')"

$passLog = @'
[10:00:00] [main/INFO]: Loading Minecraft 26.2 with Fabric Loader 0.19.4
	- fabricloader 0.19.4
	- minecraft 26.2
	- vivecraft 26.2-1.3.15+qc.v71.rc8-mining
	- vivecraft_essentials_quest 0.7.0-v71.rc6
[10:00:05] [Render thread/ERROR]: Error while loading the narrator
com.mojang.text2speech.Narrator$InitializeException: Failed to load library flite
	at knot//com.mojang.text2speech.Narrator.getNarrator(Narrator.java:41)
Caused by: java.lang.UnsatisfiedLinkError: Unable to load library 'flite':
dlopen failed: library "libflite.so" not found
	Suppressed: java.lang.UnsatisfiedLinkError: dlopen failed: library "libflite.so" not found
[10:00:10] [Render thread/INFO]: Using graphics backend Vulkan, using drivers: Quest test driver
[10:00:20] [Render thread/INFO]: Vivecraft: OpenXR initialized & VR connected.
[10:00:21] [Render thread/INFO]: Vivecraft: OpenXR submitted frame 120 predictedTime=1 shouldRender=true projectionLayer=true
'@

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'v71-rc8-runtime-log-self-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $passPath = Write-Fixture $tempRoot 'pass' $passLog
    $values = @(& $script:Verifier -LogPath $passPath)
    $result = @($values | Where-Object { $null -ne $_.PSObject.Properties['Result'] })
    Require ($result.Count -eq 1 -and [string]$result[0].Result -ceq 'PASS') `
        'Canonical synthetic fixture did not return one PASS.'
    Require ([bool]$result[0].HostOnly -and [int]$result[0].DeviceInvocations -eq 0 -and
            [string]$result[0].Vivecraft -ceq '26.2-1.3.15+qc.v71.rc8-mining' -and
            [string]$result[0].Veq -ceq '0.7.0-v71.rc6' -and
            [string]$result[0].GraphicsBackend -ceq 'Vulkan' -and
            [string]$result[0].XrRuntime -ceq 'OpenXR' -and
            [bool]$result[0].OptionalNarratorFliteFailureIgnored -and
            [bool]$result[0].ProjectionFrameSubmitted -and
            [string]$result[0].ManualMiningAcceptance -ceq 'PENDING_USER_OBSERVATION' -and
            -not [bool]$result[0].StablePromotionAllowed) `
        'PASS result weakened the Host-only or manual-acceptance boundary.'

    $cases = [ordered]@{
        missing_minecraft = $passLog.Replace('Minecraft 26.2', 'Minecraft 26.1.2')
        wrong_loader = $passLog.Replace('Fabric Loader 0.19.4', 'Fabric Loader 0.19.3')
        missing_core = $passLog.Replace('vivecraft 26.2-1.3.15+qc.v71.rc8-mining', 'vivecraft 26.2-1.3.15')
        stale_rc7_core = $passLog + "`n`t- vivecraft 26.2-1.3.15+qc.v71.rc7`n"
        stale_rc6_core = $passLog + "`n`t- vivecraft 26.2-1.3.15+qc.v71.rc6.2`n"
        missing_veq = $passLog.Replace('vivecraft_essentials_quest 0.7.0-v71.rc6', 'vivecraft_essentials_quest 0.7.0-v71.rc5')
        missing_vulkan = $passLog.Replace('Using graphics backend Vulkan', 'Using graphics backend OpenGL')
        missing_openxr = $passLog.Replace('OpenXR initialized & VR connected.', 'VR initialization skipped.')
        missing_submission = $passLog.Replace('projectionLayer=true', 'projectionLayer=false')
        fatal = $passLog + "`n[10:00:22] [Render thread/FATAL]: Renderer stopped`n"
        crash = $passLog + "`n---- Minecraft Crash Report ----`n"
        linkage = $passLog + "`njava.lang.NoSuchMethodError: broken ABI`n"
        non_narrator_flite_linkage = $passLog + "`n[10:00:22] [Render thread/ERROR]: Renderer load failed`njava.lang.UnsatisfiedLinkError: Unable to load library 'flite':`n"
        linkage_inside_narrator = $passLog.Replace(
            '[10:00:10] [Render thread/INFO]',
            "java.lang.NoSuchMethodError: unrelated ABI failure`n[10:00:10] [Render thread/INFO]")
        mixin_failure = $passLog + "`norg.spongepowered.asm.mixin.throwables.MixinApplyError: failed`n"
    }
    foreach ($entry in $cases.GetEnumerator()) {
        Assert-Rejected $entry.Key $entry.Value $tempRoot
    }

    $relativeRejected = $false
    Push-Location $tempRoot
    try {
        & $script:Verifier -LogPath 'pass.log' | Out-Null
    } catch {
        $relativeRejected = $_.Exception.Message.Contains(
            '[V71_RC8_RUNTIME_LOG]', [StringComparison]::Ordinal)
    } finally {
        Pop-Location
    }
    Require $relativeRejected 'Relative LogPath was accepted.'

    $uncRejected = $false
    try {
        & $script:Verifier -LogPath '\\invalid-host\share\latest.log' | Out-Null
    } catch {
        $uncRejected = $_.Exception.Message.Contains(
            '[V71_RC8_RUNTIME_LOG]', [StringComparison]::Ordinal)
    }
    Require $uncRejected 'UNC/network LogPath was accepted.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    CanonicalFixtureAccepted = $true
    NegativeFixturesRejected = 17
    VerifierWriteCommands = 0
    ManualMiningAcceptancePreserved = $true
    StablePromotionPreserved = $true
}
