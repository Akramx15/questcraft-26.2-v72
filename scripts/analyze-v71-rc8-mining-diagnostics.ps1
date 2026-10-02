[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Test-OneOf([string] $Value, [string[]] $Allowed) {
    return $Allowed -ccontains $Value
}

function Convert-DiagnosticFields([string] $Body, [string[]] $ExpectedKeys) {
    Require ($Body.Length -le 2048) 'A diagnostic transition exceeds the length limit.'
    Require ($Body -cmatch '^[\x20-\x7E]+$') 'A diagnostic transition contains non-ASCII/control data.'
    $tokens = @($Body -csplit ' ' | Where-Object { $_.Length -gt 0 })
    Require ($tokens.Count -eq (1 + $ExpectedKeys.Count)) 'Malformed diagnostic transition field count.'
    $channel = $tokens[0]
    $fields = @{}
    for ($index = 1; $index -lt $tokens.Count; $index++) {
        Require ($tokens[$index] -cmatch '^([A-Za-z][A-Za-z0-9_]*)=([A-Z0-9_]+|true|false)$') `
            'Malformed diagnostic transition token.'
        $key = $Matches[1]
        $value = $Matches[2]
        Require (-not $fields.ContainsKey($key)) 'Duplicate diagnostic transition field.'
        $fields[$key] = $value
    }
    Require ($fields.Count -eq $ExpectedKeys.Count) 'Malformed diagnostic transition schema.'
    foreach ($key in $ExpectedKeys) {
        Require ($fields.ContainsKey($key)) 'Missing diagnostic transition field.'
    }
    foreach ($key in $fields.Keys) {
        Require ($ExpectedKeys -ccontains $key) 'Unknown diagnostic transition field.'
    }
    return [pscustomobject]@{ Channel = $channel; Fields = $fields }
}

function Require-Bool([hashtable] $Fields, [string[]] $Keys) {
    foreach ($key in $Keys) {
        Require (($Fields[$key] -ceq 'true') -or ($Fields[$key] -ceq 'false')) `
            'Invalid diagnostic boolean.'
    }
}

Require ([IO.Path]::IsPathFullyQualified($LogPath)) 'LogPath must be an explicit absolute local filesystem path.'
Require (-not $LogPath.StartsWith('\\', [StringComparison]::Ordinal)) 'UNC/network LogPath is not allowed.'
Require (-not $LogPath.Contains('://', [StringComparison]::Ordinal)) 'URI LogPath is not allowed.'
$item = Get-Item -LiteralPath $LogPath -Force
Require (-not $item.PSIsContainer) 'LogPath must name one file.'
Require ($item.PSProvider.Name -ceq 'FileSystem') 'LogPath must use the local filesystem provider.'
Require ($item.Length -gt 0 -and $item.Length -le 67108864) 'Log file size is outside the accepted range.'

$text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($item.FullName))
$prefix = '[QuestMiningDiag]'
$events = [Collections.Generic.List[object]]::new()

foreach ($line in ($text -split "`r?`n")) {
    $marker = $line.IndexOf($prefix, [StringComparison]::Ordinal)
    if ($marker -lt 0) { continue }
    Require ($line.IndexOf($prefix, $marker + $prefix.Length, [StringComparison]::Ordinal) -lt 0) `
        'A line contains duplicate diagnostic markers.'
    $body = $line.Substring($marker + $prefix.Length).Trim()
    Require ($body.Length -gt 0) 'Empty diagnostic transition.'
    $channel = ($body -csplit ' ', 2)[0]
    $event = $null
    switch -CaseSensitive ($channel) {
        { $_ -cin @('RT_INPUT', 'Y_INPUT') } {
            $event = Convert-DiagnosticFields $body @('sample','selected','expected','reason','provider','action','handed','enabled','active','originPresent','originMatches','pressed')
            Require-Bool $event.Fields @('provider','action','handed','enabled','active','originPresent','originMatches','pressed')
            Require (Test-OneOf $event.Fields.sample @('DOWN','RELEASED','UNKNOWN')) 'Invalid input sample.'
            Require (Test-OneOf $event.Fields.selected @('LEFT','RIGHT','NONE')) 'Invalid selected controller.'
            Require (Test-OneOf $event.Fields.expected @('LEFT','RIGHT','NONE')) 'Invalid expected controller.'
            Require (Test-OneOf $event.Fields.reason @('NO_PROVIDER','NO_ACTION','NOT_HANDED','DISABLED','INACTIVE','NO_ORIGIN','ORIGIN_MISMATCH','DOWN','RELEASED','UNKNOWN')) 'Invalid input reason.'
        }
        'OWNERSHIP' {
            $event = Convert-DiagnosticFields $body @('lifecycle','runtimeReady','bowOwnsBoth','rightTracking','rightPose','rightOwner','leftTracking','leftPose','leftOwner')
            Require-Bool $event.Fields @('runtimeReady','bowOwnsBoth','rightTracking','rightPose','leftTracking','leftPose')
            Require (Test-OneOf $event.Fields.lifecycle @('INACTIVE','ENTERED','STABLE','REPLACED','LOST','NONE')) 'Invalid ownership lifecycle.'
            foreach ($key in @('rightOwner','leftOwner')) { Require (Test-OneOf $event.Fields[$key] @('WRIST','TRACKER','IMMERSIVE','CLIMBING','GRIP','WORLD','NONE')) 'Invalid hand owner.' }
        }
        'RT_ROUTE' {
            $event = Convert-DiagnosticFields $body @('sample','lifecycle','worldAllowed','inputEnabled','useConflict','routed','target','keyAttackDown','destroying','reason')
            Require-Bool $event.Fields @('lifecycle','worldAllowed','inputEnabled','useConflict','routed','keyAttackDown','destroying')
            Require (Test-OneOf $event.Fields.sample @('DOWN','RELEASED','UNKNOWN')) 'Invalid RT route sample.'
            Require (Test-OneOf $event.Fields.target @('NONE','MISS','BLOCK','ENTITY')) 'Invalid RT target kind.'
            Require (Test-OneOf $event.Fields.reason @('LIFECYCLE','OWNERSHIP_OR_PLAYER_STATE','INPUT_DISABLED','MAIN_USE_CONFLICT','NOT_HELD','LATCH_SUPPRESSED','NO_TARGET','KEY_ATTACK_NOT_RAISED','READY')) 'Invalid RT route reason.'
        }
        'Y_ROUTE' {
            $event = Convert-DiagnosticFields $body @('sample','controller','hand','lifecycle','worldAllowed','inputEnabled','protocolAllowed','useConflict','held','pressed','target','destroying','reason')
            Require-Bool $event.Fields @('lifecycle','worldAllowed','inputEnabled','protocolAllowed','useConflict','held','pressed','destroying')
            Require (Test-OneOf $event.Fields.sample @('DOWN','RELEASED','UNKNOWN')) 'Invalid Y route sample.'
            Require (Test-OneOf $event.Fields.controller @('LEFT','RIGHT','NONE')) 'Invalid Y route controller.'
            Require (Test-OneOf $event.Fields.hand @('MAIN_HAND','OFF_HAND','NONE')) 'Invalid Y route hand.'
            Require (Test-OneOf $event.Fields.target @('NONE','MISS','BLOCK','ENTITY')) 'Invalid Y target kind.'
            Require (Test-OneOf $event.Fields.reason @('NO_BOUND_ORIGIN','LIFECYCLE','OWNERSHIP_OR_PLAYER_STATE','INPUT_DISABLED','PROTOCOL_OR_POLICY','USE_OR_RT_CONFLICT','LATCH_SUPPRESSED','NO_TARGET','READY')) 'Invalid Y route reason.'
        }
        { $_ -cin @('START','CONTINUE') } {
            $event = Convert-DiagnosticFields $body @('source','beforeDestroying','beforeSameTarget','result','afterDestroying','afterSameTarget')
            Require-Bool $event.Fields @('beforeDestroying','beforeSameTarget','result','afterDestroying','afterSameTarget')
            Require (Test-OneOf $event.Fields.source @('DISABLED','NATIVE_OR_SWING','ROUTED_Y')) 'Invalid mining-call source.'
        }
        'STOP' {
            $event = Convert-DiagnosticFields $body @('source','beforeDestroying','afterDestroying')
            Require-Bool $event.Fields @('beforeDestroying','afterDestroying')
            Require (Test-OneOf $event.Fields.source @('DISABLED','NATIVE_OR_SWING','ROUTED_Y')) 'Invalid stop source.'
        }
        'MINING_FLOW' {
            $event = Convert-DiagnosticFields $body @('native_or_y_call_since_previous_router_tick')
            Require-Bool $event.Fields @('native_or_y_call_since_previous_router_tick')
        }
        default { throw 'Unknown diagnostic transition channel.' }
    }
    $events.Add($event)
}

Require ($events.Count -gt 0) 'No Quest mining diagnostic transitions were found.'
Require ($events.Count -le 100000) 'Too many diagnostic transitions.'

$input = @($events | Where-Object { $_.Channel -in @('RT_INPUT','Y_INPUT') })
$ownership = @($events | Where-Object { $_.Channel -ceq 'OWNERSHIP' })
$routes = @($events | Where-Object { $_.Channel -in @('RT_ROUTE','Y_ROUTE') })
$starts = @($events | Where-Object { $_.Channel -ceq 'START' })
$continues = @($events | Where-Object { $_.Channel -ceq 'CONTINUE' })
$stops = @($events | Where-Object { $_.Channel -ceq 'STOP' })
$flows = @($events | Where-Object { $_.Channel -ceq 'MINING_FLOW' })
$release = @($input | Where-Object { $_.Fields.sample -ceq 'RELEASED' })

$bindingFailures = @($input | Where-Object { $_.Fields.reason -in @('NO_PROVIDER','NO_ACTION','NOT_HANDED','DISABLED','INACTIVE','NO_ORIGIN','ORIGIN_MISMATCH','UNKNOWN') }).Count
$ownershipBlocked = @($ownership | Where-Object {
    $_.Fields.runtimeReady -ceq 'false' -or $_.Fields.bowOwnsBoth -ceq 'true' -or
    $_.Fields.rightTracking -ceq 'false' -or $_.Fields.rightPose -ceq 'false' -or
    $_.Fields.leftTracking -ceq 'false' -or $_.Fields.leftPose -ceq 'false' -or
    $_.Fields.rightOwner -cne 'WORLD' -or $_.Fields.leftOwner -cne 'WORLD'
}).Count
$routeReady = @($routes | Where-Object { $_.Fields.reason -ceq 'READY' }).Count
$startAccepted = @($starts | Where-Object { $_.Fields.result -ceq 'true' }).Count
$continueAccepted = @($continues | Where-Object { $_.Fields.result -ceq 'true' }).Count
$flowObserved = @($flows | Where-Object { $_.Fields.native_or_y_call_since_previous_router_tick -ceq 'true' }).Count

$classification = if ($bindingFailures -gt 0 -and $routeReady -eq 0) { 'BINDING_OR_ACTION_SET' }
elseif ($ownershipBlocked -gt 0 -and $routeReady -eq 0) { 'OWNERSHIP_BLOCKED' }
elseif ($routeReady -eq 0) { 'VANILLA_ROUTE_NOT_READY' }
elseif ($starts.Count -eq 0) { 'VANILLA_START_NOT_OBSERVED' }
elseif ($startAccepted -eq 0) { 'VANILLA_START_REJECTED' }
elseif ($continues.Count -eq 0 -or $continueAccepted -eq 0) { 'VANILLA_CONTINUE_NOT_ACCEPTED' }
elseif ($stops.Count -gt 0 -and $release.Count -eq 0) { 'STOP_WITHOUT_INPUT_RELEASE' }
else { 'VANILLA_MINING_FLOW_OBSERVED' }

[pscustomobject]@{
    Result = 'PASS'
    Classification = $classification
    DiagnosticLines = $events.Count
    Counts = [ordered]@{
        BindingActionSet = $input.Count
        BindingFailures = $bindingFailures
        Ownership = $ownership.Count
        OwnershipBlocked = $ownershipBlocked
        VanillaRoute = $routes.Count
        VanillaRouteReady = $routeReady
        VanillaStart = $starts.Count
        VanillaStartAccepted = $startAccepted
        VanillaContinue = $continues.Count
        VanillaContinueAccepted = $continueAccepted
        Stop = $stops.Count
        Release = $release.Count
        FlowObserved = $flowObserved
    }
    HostOnly = $true
    DeviceInvocations = 0
    RawLogPersisted = $false
    SensitiveValuesEmitted = $false
}
