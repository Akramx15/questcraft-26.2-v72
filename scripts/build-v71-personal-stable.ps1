<# Builds Personal v71 only after both build and promotion intent are explicit. #>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Build', 'RestoreSourceAar')]
    [string] $Action = 'SelfTest',
    [string] $UnityEditor = (Join-Path $env:USERPROFILE `
        'Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe'),
    [switch] $AllowBuild,
    [switch] $AllowStablePromotion
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build-v71-integrated.ps1') `
    -Target Stable -Action $Action -UnityEditor $UnityEditor `
    -AllowBuild:$AllowBuild -AllowStablePromotion:$AllowStablePromotion
