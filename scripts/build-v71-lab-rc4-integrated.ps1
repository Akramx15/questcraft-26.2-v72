<# Builds the exact isolated v71 RC4 Lab APK through the shared fail-closed gate. #>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Build', 'RestoreSourceAar')]
    [string] $Action = 'SelfTest',
    [string] $UnityEditor = (Join-Path $env:USERPROFILE `
        'Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe'),
    [switch] $AllowBuild
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build-v71-integrated.ps1') `
    -Target Lab -Action $Action -UnityEditor $UnityEditor -AllowBuild:$AllowBuild
