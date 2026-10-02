#requires -Version 7.0
<#
.SYNOPSIS
Verifies a user-supplied local Minecraft log for the exact V71 RC8 runtime.

.DESCRIPTION
This verifier is intentionally read-only and Host-only. It accepts one explicit,
absolute local file path, reads that file, and checks the exact Minecraft/Fabric/
Vivecraft/VEQ identity plus live Vulkan/OpenXR markers. It does not discover,
copy, pull, launch, install, or write runtime evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prefix = '[V71_RC8_RUNTIME_LOG]'
$script:Expected = [ordered]@{
    Minecraft = '26.2'
    FabricLoader = '0.19.4'
    Vivecraft = '26.2-1.3.15+qc.v71.rc8-mining'
    Veq = '0.7.0-v71.rc6'
}

function Fail([Parameter(Mandatory)][string] $Message) {
    throw "$($script:Prefix) $Message"
}

function Require([bool] $Condition, [Parameter(Mandatory)][string] $Message) {
    if (-not $Condition) { Fail $Message }
}

function Has([Parameter(Mandatory)][string] $Text, [Parameter(Mandatory)][string] $Pattern) {
    return [regex]::IsMatch($Text, $Pattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::Multiline)
}

# An explicit local filesystem path is part of the evidence boundary. In
# particular, reject relative paths, URI syntax and UNC paths rather than
# letting provider or current-directory resolution widen the verifier's scope.
Require ([IO.Path]::IsPathFullyQualified($LogPath)) `
    'LogPath must be an explicit absolute local filesystem path.'
Require (-not $LogPath.StartsWith('\\', [StringComparison]::Ordinal)) `
    'UNC/network paths are not accepted.'
Require (-not $LogPath.Contains('://', [StringComparison]::Ordinal)) `
    'URI paths are not accepted.'

$item = Get-Item -LiteralPath $LogPath -Force -ErrorAction Stop
Require (-not $item.PSIsContainer) 'LogPath must name one file, not a directory.'
Require ($item.PSProvider.Name -ceq 'FileSystem') 'LogPath must use the local filesystem provider.'
Require ($item.Length -gt 0) 'The runtime log is empty.'
Require ($item.Length -le 64MB) 'The runtime log exceeds the 64 MiB safety limit.'

$resolvedPath = $item.FullName
$text = [IO.File]::ReadAllText($resolvedPath)

# Minecraft's Linux narrator probe is optional on Quest. The stock client logs
# one handled ERROR block when libflite is absent and then continues normally.
# Exempt that tightly bounded Narrator InitializeException block from only the
# generic linkage scan; all other fatal scans still inspect the original log,
# and an UnsatisfiedLinkError anywhere else remains fatal.
$optionalNarratorFlitePattern = '(?ms)^\[[^\r\n]+\] \[Render thread/ERROR\]: Error while loading the narrator\r?\ncom\.mojang\.text2speech\.Narrator\$InitializeException: Failed to load library flite\r?\n(?:(?!^\[[^\r\n]+\] \[[^\r\n]+\]:).)*(?=^\[[^\r\n]+\] \[[^\r\n]+\]:|\z)'
$optionalNarratorFliteLinePattern = '(?m)^\s*(?:Caused by:\s+|Suppressed:\s+)?java\.lang\.UnsatisfiedLinkError:\s+(?:Unable to load library ''flite'':|dlopen failed: library "libflite\.so" not found)\s*$'
$optionalNarratorFliteIgnored = $false
$narratorBlockRegex = [regex]::new($optionalNarratorFlitePattern)
$narratorFliteLineRegex = [regex]::new($optionalNarratorFliteLinePattern)
$linkageScanText = $narratorBlockRegex.Replace($text, {
    param($match)
    $sanitized = $narratorFliteLineRegex.Replace(
        $match.Value, '[allowed optional Quest narrator flite linkage]')
    if ($sanitized.Length -ne $match.Value.Length) {
        $script:optionalNarratorFliteIgnored = $true
    }
    return $sanitized
})

$fatalPatterns = [ordered]@{
    FatalLevel = '(?m)^.*\[(?:[^]\r\n]+/)?FATAL\](?:\s*:)?\s*.+$'
    JavaFatal = 'A fatal error has been detected by the Java Runtime Environment'
    CrashReport = '(?:----\s+Minecraft Crash Report\s+----|Minecraft (?:has )?crashed|Crash report saved to:)'
    UncaughtThread = 'Exception in thread\s+"(?:main|Render thread|Client thread)"'
    FailedExit = '(?:Process|Minecraft).{0,40}(?:exited|finished).{0,20}(?:exit\s*)?code\s*[:=]?\s*-[1-9]\d*|(?:Process|Minecraft).{0,40}(?:exited|finished).{0,20}(?:exit\s*)?code\s*[:=]?\s*[1-9]\d*'
    Linkage = '\b(?:java\.lang\.)?(?:LinkageError|NoSuchMethodError|NoSuchFieldError|AbstractMethodError|IncompatibleClassChangeError|UnsatisfiedLinkError)\b'
    MixinFailure = '\b(?:MixinApplyError|MixinTransformerError|InvalidMixinException|InjectionError)\b|Critical injection failure|Mixin (?:apply|transformation) failed|Mixin\s+\S+\s+from\s+mod\s+\S+\s+failed'
}
foreach ($entry in $fatalPatterns.GetEnumerator()) {
    $scanText = if ($entry.Key -ceq 'Linkage') { $linkageScanText } else { $text }
    Require (-not (Has $scanText $entry.Value)) "Runtime log contains a $($entry.Key) failure marker."
}

$minecraftPattern = "Loading Minecraft\s+$([regex]::Escape($script:Expected.Minecraft))\s+with Fabric Loader\s+$([regex]::Escape($script:Expected.FabricLoader))(?:\s|$)"
Require (Has $text $minecraftPattern) `
    "Missing exact Minecraft $($script:Expected.Minecraft) / Fabric Loader $($script:Expected.FabricLoader) startup marker."

$corePattern = "(?m)^[^\r\n]*-\s+vivecraft\s+$([regex]::Escape($script:Expected.Vivecraft))\s*$"
$veqPattern = "(?m)^[^\r\n]*-\s+vivecraft_essentials_quest\s+$([regex]::Escape($script:Expected.Veq))\s*$"
Require (Has $text $corePattern) "Missing exact Vivecraft $($script:Expected.Vivecraft) mod-list entry."
Require (Has $text $veqPattern) "Missing exact VEQ $($script:Expected.Veq) mod-list entry."

# Fail closed if a stale managed core appears anywhere alongside RC8. The
# negative look-ahead prevents rc8 itself from being mistaken for an old core.
$staleCorePattern = '\b26\.2-1\.3\.15\+qc\.v71\.rc(?:6(?:\.\d+)?|7)(?![0-9A-Za-z.+-])'
Require (-not (Has $text $staleCorePattern)) 'Runtime log contains a forbidden RC6/RC7 Vivecraft core.'

$vulkanPattern = 'Using graphics backend\s+Vulkan(?:,|\s|$)'
$openXrConnectedPattern = 'Vivecraft:\s+OpenXR initialized\s*&\s*VR connected\.'
$openXrSubmittedPattern = 'Vivecraft:\s+OpenXR submitted frame\s+\d+[^\r\n]*projectionLayer=true'
Require (Has $text $vulkanPattern) 'Missing live Vulkan backend marker.'
Require (Has $text $openXrConnectedPattern) 'Missing connected Vivecraft OpenXR initialization marker.'
Require (Has $text $openXrSubmittedPattern) 'Missing successful OpenXR projection-frame submission marker.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    LogPath = $resolvedPath
    LogSha256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToUpperInvariant()
    Minecraft = $script:Expected.Minecraft
    FabricLoader = $script:Expected.FabricLoader
    Vivecraft = $script:Expected.Vivecraft
    Veq = $script:Expected.Veq
    GraphicsBackend = 'Vulkan'
    XrRuntime = 'OpenXR'
    ProjectionFrameSubmitted = $true
    OptionalNarratorFliteFailureIgnored = $optionalNarratorFliteIgnored
    CrashMarkersFound = 0
    ManualMiningAcceptance = 'PENDING_USER_OBSERVATION'
    StablePromotionAllowed = $false
}
