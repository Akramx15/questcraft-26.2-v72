<# Archived RC3 entry point. RC3 evidence is immutable and must not be rebuilt through RC4. #>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Build', 'RestoreSourceAar')]
    [string] $Action = 'SelfTest',
    [string] $UnityEditor = (Join-Path $env:USERPROFILE `
        'Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe'),
    [switch] $AllowBuild
)

$ErrorActionPreference = 'Stop'
throw 'The RC3 build entry point is archived. Use build-v71-lab-rc4-integrated.ps1 for the pending RC4 candidate; historical RC3 evidence must remain immutable.'
