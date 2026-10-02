[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$parser = Join-Path $PSScriptRoot 'analyze-v71-rc8-mining-diagnostics.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('quest-mining-parser-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$utf8 = [Text.UTF8Encoding]::new($false)
$accepted = 0
$rejected = 0

function Write-Fixture([string] $Name, [string[]] $Lines) {
    $path = Join-Path $root $Name
    [IO.File]::WriteAllLines($path, $Lines, $utf8)
    return $path
}

function Test-Accept([string] $Name, [string[]] $Lines, [string] $Expected) {
    $path = Write-Fixture $Name $Lines
    $values = @(& $parser -LogPath $path)
    Require ($values.Count -eq 1) 'Parser emitted an unexpected number of result objects.'
    $result = $values[0]
    Require ($result.Result -ceq 'PASS' -and $result.Classification -ceq $Expected) 'Unexpected compact classification.'
    Require ([bool]$result.HostOnly -and [int]$result.DeviceInvocations -eq 0 -and -not [bool]$result.RawLogPersisted -and -not [bool]$result.SensitiveValuesEmitted) 'Privacy/host-only contract failed.'
    $serialized = $result | ConvertTo-Json -Depth 5 -Compress
    foreach ($secret in @('account@example.test','SecretWorld','192.0.2.40','diamond_pickaxe','latest.log',$path)) {
        Require (-not $serialized.Contains($secret, [StringComparison]::OrdinalIgnoreCase)) 'Result disclosed fixture or path data.'
    }
    $script:accepted++
}

function Test-Reject([string] $Name, [string[]] $Lines) {
    $path = Write-Fixture $Name $Lines
    $failed = $false
    try { & $parser -LogPath $path | Out-Null } catch { $failed = $true }
    Require $failed 'Malformed or unknown diagnostic input was accepted.'
    $script:rejected++
}

$prefix = '[12:00:00] [Render thread/INFO] [test]: [QuestMiningDiag]'
$goodInput = "$prefix RT_INPUT sample=DOWN selected=RIGHT expected=RIGHT reason=DOWN provider=true action=true handed=true enabled=true active=true originPresent=true originMatches=true pressed=true"
$goodOwner = "$prefix OWNERSHIP lifecycle=STABLE runtimeReady=true bowOwnsBoth=false rightTracking=true rightPose=true rightOwner=WORLD leftTracking=true leftPose=true leftOwner=WORLD"
$goodRoute = "$prefix RT_ROUTE sample=DOWN lifecycle=true worldAllowed=true inputEnabled=true useConflict=false routed=true target=BLOCK keyAttackDown=true destroying=false reason=READY"
$goodStart = "$prefix START source=NATIVE_OR_SWING beforeDestroying=false beforeSameTarget=false result=true afterDestroying=true afterSameTarget=true"
$goodContinue = "$prefix CONTINUE source=NATIVE_OR_SWING beforeDestroying=true beforeSameTarget=true result=true afterDestroying=true afterSameTarget=true"
$goodRelease = "$prefix RT_INPUT sample=RELEASED selected=RIGHT expected=RIGHT reason=RELEASED provider=true action=true handed=true enabled=true active=true originPresent=true originMatches=true pressed=false"
$goodStop = "$prefix STOP source=NATIVE_OR_SWING beforeDestroying=true afterDestroying=false"
$goodFlow = "$prefix MINING_FLOW native_or_y_call_since_previous_router_tick=true"

try {
    Test-Accept 'binding.log' @("$prefix RT_INPUT sample=UNKNOWN selected=NONE expected=RIGHT reason=NO_ACTION provider=true action=false handed=false enabled=false active=false originPresent=false originMatches=false pressed=false") 'BINDING_OR_ACTION_SET'
    Test-Accept 'ownership.log' @($goodInput, "$prefix OWNERSHIP lifecycle=STABLE runtimeReady=true bowOwnsBoth=false rightTracking=true rightPose=true rightOwner=GRIP leftTracking=true leftPose=true leftOwner=WORLD") 'OWNERSHIP_BLOCKED'
    Test-Accept 'route.log' @($goodInput, $goodOwner, "$prefix RT_ROUTE sample=DOWN lifecycle=true worldAllowed=true inputEnabled=true useConflict=false routed=false target=BLOCK keyAttackDown=false destroying=false reason=KEY_ATTACK_NOT_RAISED") 'VANILLA_ROUTE_NOT_READY'
    Test-Accept 'start-missing.log' @($goodInput, $goodOwner, $goodRoute) 'VANILLA_START_NOT_OBSERVED'
    Test-Accept 'start-rejected.log' @($goodInput, $goodOwner, $goodRoute, "$prefix START source=NATIVE_OR_SWING beforeDestroying=false beforeSameTarget=false result=false afterDestroying=false afterSameTarget=false") 'VANILLA_START_REJECTED'
    Test-Accept 'continue-missing.log' @($goodInput, $goodOwner, $goodRoute, $goodStart) 'VANILLA_CONTINUE_NOT_ACCEPTED'
    Test-Accept 'stop-without-release.log' @($goodInput, $goodOwner, $goodRoute, $goodStart, $goodContinue, $goodStop) 'STOP_WITHOUT_INPUT_RELEASE'
    Test-Accept 'healthy.log' @('unrelated account@example.test SecretWorld 192.0.2.40 diamond_pickaxe', $goodInput, $goodOwner, $goodRoute, $goodStart, $goodContinue, $goodRelease, $goodStop, $goodFlow) 'VANILLA_MINING_FLOW_OBSERVED'

    Test-Reject 'none.log' @('ordinary log only')
    Test-Reject 'unknown.log' @("$prefix FUTURE channel=true")
    Test-Reject 'wrong-case.log' @("$prefix rt_input sample=DOWN selected=RIGHT expected=RIGHT reason=DOWN provider=true action=true handed=true enabled=true active=true originPresent=true originMatches=true pressed=true")
    Test-Reject 'missing.log' @("$prefix STOP source=NATIVE_OR_SWING beforeDestroying=true")
    Test-Reject 'extra.log' @("$prefix MINING_FLOW native_or_y_call_since_previous_router_tick=true item=DIAMOND")
    Test-Reject 'duplicate.log' @("$prefix MINING_FLOW native_or_y_call_since_previous_router_tick=true native_or_y_call_since_previous_router_tick=false")
    Test-Reject 'invalid-bool.log' @("$prefix MINING_FLOW native_or_y_call_since_previous_router_tick=yes")
    Test-Reject 'invalid-enum.log' @("$prefix START source=FUTURE beforeDestroying=false beforeSameTarget=false result=true afterDestroying=true afterSameTarget=true")
    Test-Reject 'unicode.log' @("$prefix MINING_FLOW native_or_y_call_since_previous_router_tick=true حساب")
    Test-Reject 'double-marker.log' @("$prefix MINING_FLOW native_or_y_call_since_previous_router_tick=true [QuestMiningDiag]")

    $relativeRejected = $false
    try { & $parser -LogPath 'relative.log' | Out-Null } catch { $relativeRejected = $true }
    Require $relativeRejected 'Relative LogPath was accepted.'
    $rejected++

    $uncRejected = $false
    try { & $parser -LogPath '\\invalid-host\share\latest.log' | Out-Null } catch { $uncRejected = $true }
    Require $uncRejected 'UNC LogPath was accepted.'
    $rejected++

    $source = [IO.File]::ReadAllText($parser, [Text.UTF8Encoding]::new($false, $true))
    foreach ($unsafe in @('adb.exe','adb ', 'com.qcxr.qcxr.dev262','Start-Process','Invoke-WebRequest','Set-Content','Add-Content','WriteAllText','WriteAllLines')) {
        Require (-not $source.Contains($unsafe, [StringComparison]::OrdinalIgnoreCase)) 'Parser contains a device, network, stable, or persistence primitive.'
    }

    [pscustomobject]@{
        Result = 'PASS'
        AcceptedScenarios = $accepted
        RejectedFixtures = $rejected
        HostOnly = $true
        DeviceInvocations = 0
        RawLogPersisted = $false
        SensitiveValuesEmitted = $false
    }
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
