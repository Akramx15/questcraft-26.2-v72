# v70 Core + VEQ Lab harness

This disabled-by-default harness tests the three planned v70 stages only in
`com.qcxr.qcxr.canary262`, profile `26.2`. It cannot target Personal/Stable
`com.qcxr.qcxr.dev262`, exposes no package/profile override, never installs an
APK, and never starts or stops the app.

## Fixed contract

- VEQ target: `mods/Vivecraft-Essentials-Quest.jar`
- Core target: `mods/Vivecraft.jar`
- embedded VEQ rollback SHA-256:
  `6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9`
- VEQ Fabric id/version: `vivecraft_essentials_quest` /
  `0.7.0-v70-canary.1`
- Minecraft/Java dependencies: `26.2` / `>=25`
- one launch, maximum marker lifetime 30 minutes
- the old `1047f873` VEQ artifact remains permanently blacklisted

Unknown v70 candidate hashes are not embedded in source. Every deployment
must provide the candidate path and an independently obtained SHA-256. The
Host verifies that hash, the bounded JAR structure, exact Fabric metadata, and
then places that exact hash/size in the strict marker. Runtime accepts the hash
from that marker only for the current process.

## Paired safety model

Core and VEQ each retain their own atomic same-directory promotion, permit,
artifact verification, and exact rollback source. Their shared surrounding-mod
fingerprint excludes exactly these two managed targets—nothing else—so the
first promotion cannot invalidate the second. Each excluded target remains
independently hash/size/metadata-verified by its own permit and by the full
stack verifier.

`quest-v70-lab-pair.ps1` validates VEQ before Core can be armed. It then arms
Core followed by VEQ. If the second arm fails, it restores Core then VEQ and
surfaces any partial rollback as a hard failure. At runtime, a VEQ prepare or
full-stack verification failure aborts Core first and then VEQ. A single Core
or VEQ marker is still supported safely. Managed Mods-A/B experiments remain
mutually exclusive with either permit.

The transaction is atomic per target, with compensating rollback across the
pair; Android does not provide a two-file filesystem transaction. Do not call
the pair promoted until both runtime permits and both artifacts pass full-stack
verification.

## Host-only checks

These commands do not resolve or invoke ADB:

```powershell
pwsh -NoProfile -File scripts/quest-vivecraft-core-canary.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/quest-veq-lab.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/quest-v70-lab-pair.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-veq-lab-host.ps1
pwsh -NoProfile -File scripts/test-quest-v70-lab-pair-host.ps1
pwsh -NoProfile -File scripts/build-v70-lab-canary.ps1 -Action SelfTest
```

To validate a real VEQ candidate without a device:

```powershell
$veq = '<absolute path to the v70 VEQ JAR>'
$veqSha = (Get-FileHash -LiteralPath $veq -Algorithm SHA256).Hash
pwsh -NoProfile -File scripts/test-quest-veq-lab-host.ps1 `
  -CandidateJar $veq -ExpectedCandidateSha256 $veqSha
```

## Supervised pair deployment

Only after the Lab app and JVM are stopped:

```powershell
$core = '<absolute path to the matching v70 Vivecraft JAR>'
$veq = '<absolute path to the matching v70 VEQ JAR>'
$coreSha = (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash
$veqSha = (Get-FileHash -LiteralPath $veq -Algorithm SHA256).Hash

pwsh -NoProfile -File scripts/quest-v70-lab-pair.ps1 `
  -Action Deploy `
  -CoreJarPath $core -CoreExpectedSha256 $coreSha `
  -VeqJarPath $veq -VeqExpectedSha256 $veqSha `
  -AllowDeviceWrite
```

After the one supervised launch, stop the Lab app/JVM and prove both embedded
baselines are restored:

```powershell
pwsh -NoProfile -File scripts/quest-v70-lab-pair.ps1 `
  -Action Rollback -AllowDeviceWrite
```

Normal Android shell is always attempted first. Root fallback is unavailable
unless `-AllowRootFallback` is explicit and a read-only probe selects it before
mutation. The scripts never copy account files or alter Stable, saves, worlds,
QGO, Magisk, configuration, or APK installation state.

## Lab APK build

The build is Host-only and starts no ADB process:

```powershell
pwsh -NoProfile -File scripts/build-v70-lab-canary.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/build-v70-lab-canary.ps1 -Action Build -AllowBuild
```

It is locked to the accepted v69 source stack and produces only:

- package: `com.qcxr.qcxr.canary262`
- versionCode: `70`
- versionName: `6.0.1-26.2-vivecraft-personal.11-rc.1`
- output: `QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v70-rc.1-local.apk`
- Debug signer only

The script rebuilds/tests Pojlib, temporarily swaps the Unity AAR, restores the
checked-in v69 AAR in `finally`, and runs the full APK verifier. Unity and full
Gradle builds remain explicit `-AllowBuild` operations.
