#requires -Version 7.0
<# Host-only regression and mutation-surface audit for the RC6.2 pack A/B harness. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) {
        throw "[V71_RC6_2_PACK_MEMORY_AB_HOST_TEST] $Message"
    }
}

$harness = Join-Path $PSScriptRoot 'quest-v71-rc62-resource-pack-memory-ab.ps1'
$sentinel = Join-Path $PSScriptRoot '__quest-v71-rc62-pack-ab-host-test-no-adb__.exe'
Require (Test-Path -LiteralPath $harness -PathType Leaf) 'The pack A/B harness is missing.'
Require (-not (Test-Path -LiteralPath $sentinel)) 'The ADB sentinel unexpectedly exists.'

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $harness, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'The PowerShell parser rejected the pack A/B harness.'

$selfTestValues = @(& $harness -Action SelfTest -Serial 'offline-proof' -AdbPath $sentinel)
$selfTest = @($selfTestValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($selfTest.Count -eq 1 -and [string]$selfTest[0].Result -ceq 'PASS') `
    'SelfTest did not return one PASS record.'
Require ([bool]$selfTest[0].HostOnly -and [int]$selfTest[0].DeviceInvocations -eq 0 -and
    -not [bool]$selfTest[0].DeviceMutationCapability -and
    -not [bool]$selfTest[0].WrapperInvokesSampler) `
    'SelfTest did not preserve its Host-only, non-mutating boundary.'
Require ([bool]$selfTest[0].MissingAmbiguousOrMalformedAtlasRejected -and
    [bool]$selfTest[0].BlocksAtlasParsedAtBothFences -and
    [bool]$selfTest[0].AtlasDimensionsAreObservedNotInferred -and
    [bool]$selfTest[0].MultipleAndUnknownPackStatesRejected -and
    [bool]$selfTest[0].MismatchedAndMidRunReloadsRejected -and
    [bool]$selfTest[0].PhysicalNonVanillaHashRequired -and
    [bool]$selfTest[0].SamplerTamperCasesRejected -and
    [bool]$selfTest[0].HalfGe256IdentityAndCompareFixturesPassed -and
    [bool]$selfTest[0].ReusedOrSameConditionCompareRejected -and
    [bool]$selfTest[0].ReceiptTamperCasesRejected) `
    'SelfTest did not exercise the condition/atlas/sampler tamper boundary.'
$conditionNames = @($selfTest[0].Conditions)
Require ($conditionNames.Count -eq 5 -and
    $conditionNames[0] -ceq 'Vanilla' -and $conditionNames[1] -ceq 'Original' -and
    $conditionNames[2] -ceq 'Probe512' -and $conditionNames[3] -ceq 'HalfGe256' -and
    $conditionNames[4] -ceq 'Cap128') `
    'The exact five-condition A/B identity set drifted.'
Require (-not (Test-Path -LiteralPath $sentinel)) `
    'Host SelfTest resolved, invoked, or created the ADB sentinel.'

foreach ($deviceAction in @('Begin', 'Finalize')) {
    $rejectedBeforeAdb = $false
    try {
        & $harness -Action $deviceAction -Condition Original -Serial 'offline-proof' `
            -AdbPath $sentinel -OutputDirectory `
            'artifacts/memory/__rc62-pack-ab-host-test-never-created__' | Out-Null
    } catch {
        $rejectedBeforeAdb = $_.Exception.Message.Contains(
            'explicit -AllowDeviceRead', [StringComparison]::Ordinal)
    }
    Require $rejectedBeforeAdb `
        "$deviceAction did not require explicit -AllowDeviceRead before resolving ADB."
    Require (-not (Test-Path -LiteralPath $sentinel)) `
        "$deviceAction resolved, invoked, or created the ADB sentinel without authorization."
}

$denyFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-ReadOnlyShellCommand'
        }, $true))
Require ($denyFunction.Count -eq 1) 'The read-only device-command guard was missing or ambiguous.'
$denyStart = $denyFunction[0].Extent.StartOffset
$denyEnd = $denyFunction[0].Extent.EndOffset
$riskPattern = '(?i)(?:\bam\s+(?:start|startservice|force-stop|kill)\b|' +
    '\bpm\s+(?:install|uninstall|clear|enable|disable)\b|' +
    '\bcmd\s+package\b|\badb\s+(?:install|uninstall|push)\b|' +
    '(?:^|\s)push(?:\s|$)|\bmonkey\b|\binput\s+(?:tap|swipe|text|keyevent)\b|' +
    '\bsettings\s+put\b|\bsetprop\b|options\.txt)'
$unsafeStrings = @($ast.FindAll({
            param($node)
            ($node -is [Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
            -not ($node.Extent.StartOffset -ge $denyStart -and
                $node.Extent.EndOffset -le $denyEnd) -and
            $node.Value -match $riskPattern
        }, $true))
Require ($unsafeStrings.Count -eq 0) `
    'A device-mutating install/clear/stop/push/options/launch string escaped the deny guard.'

$directRiskyCommands = @('Start-Process', 'Invoke-Expression', 'Remove-Item',
    'Move-Item', 'Copy-Item', 'Set-Content', 'Add-Content', 'Out-File',
    'Set-ItemProperty', 'Remove-ItemProperty')
$unsafeCommands = @($ast.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
            $name = $node.GetCommandName()
            return $null -ne $name -and $directRiskyCommands -ccontains $name
        }, $true))
Require ($unsafeCommands.Count -eq 0) `
    'The harness exposed an unexpected Host or process mutation command.'

$dynamicInvocations = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq
                [Management.Automation.Language.TokenKind]::Ampersand
        }, $true))
$dynamicTexts = @($dynamicInvocations | ForEach-Object { $_.Extent.Text.Trim() })
Require ($dynamicTexts.Count -eq 2 -and
    $dynamicTexts -ccontains '& $Operation' -and
    $dynamicTexts -ccontains '& $script:Adb @Arguments 2>&1') `
    'The dynamic invocation surface escaped the internal fixture/device-read boundary.'

$source = [IO.File]::ReadAllText($harness)
foreach ($required in @(
        'ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4',
        '6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF',
        'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD',
        '227FF427604E4503BAF06A9766977EB7F926841A4325428069A40DC21FCB67D8',
        '47DD0C418556E9DC5FEF6B92A2553F51D6BBAB1DFE8968E63AF046527E920D40',
        'CAA755B12CA9D716E31C90ED6AECEE2163D0638FA67133D1EF841FE20C104C4A',
        '48B33A0061B320FBD5A587D371CAE872ECF937D0949E6D7632015351B48DE05D',
        '75F5D720A3FC6396109D6D96820F2F75AE8A8327F317A41AE811CBBF781CD433',
        'Get-FilteredLatestLogEvidence',
        'Get-BlocksAtlasObservationFromLine',
        'minimumConditionMinutes = 30',
        'accountWorldOrServerDataPersisted = $false')) {
    Require ($source.Contains($required, [StringComparison]::Ordinal)) `
        "A required exact identity/evidence-boundary literal drifted: $required"
}
Require ($source -notmatch '(?i)/(?:worlds?|servers?|accounts?)(?:/|\b)' -and
    $source -notmatch '(?i)servers\.dat|launcher_accounts|usercache\.json') `
    'The harness exposed an account, world, or server data path.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    PowerShellParsePassed = $true
    MockedConditionAndAtlasTamperCasesPassed = $true
    MockedSamplerTamperCasesPassed = $true
    ExplicitAllowDeviceReadPreflightPassed = $true
    InstallUninstallClearSurface = $false
    ForceStopSurface = $false
    PushOrOptionsWriteSurface = $false
    AppLaunchSurface = $false
    AccountWorldOrServerReadSurface = $false
    WrapperInvokesSampler = $false
}
