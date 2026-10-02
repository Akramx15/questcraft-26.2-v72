# Building the QuestCraft 26.2 Dev APK locally

The current accepted Host artifact is the Personal seed-only v72 build:

- Application ID: `com.qcxr.qcxr.dev262`
- Product name: `Vivecraft Stable`
- Version name: `6.0.1-26.2-vivecraft-personal.13`
- Version code: `72`
- Default APK: `QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-26.2-personal.13-local.apk`

The development application ID is intentionally separate from the normal
QuestCraft package, so installing this build does not replace the normal app.

Personal v72 seeds compatible default mods once when a new 26.2 profile is
created. Existing Personal profiles migrate by metadata only. After ownership
is recorded, ordinary Play never reconciles, downloads, restores, deletes, or
renames mod/resource-pack artifacts. Mod changes are direct user operations;
the explicit Repair action is separate. Lab remains strict-managed.

The verified Pojlib AAR is `88751133` bytes with SHA-256
`64B27CF1D89B506A0A203C7FC81D8E0DFE0916DCC103B649D16C18A8CEFDCF38`.
The verified APK is `128492965` bytes with SHA-256
`DFC2A264432D44AD6D0D2A13023DF17BA03BE341C5FA74BBBD9A0D043C2A94A7`.

## Exact v71 RC5.1 ownership-repair Lab candidate

The current Host-built Lab identity is `com.qcxr.qcxr.canary262`, versionCode
`71`, versionName `6.0.1-26.2-vivecraft-personal.12-rc.5.1`, with output
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.5.1-integrated-local.apk`.
It keeps RC5 Core and VEQ byte-for-byte and adds only the Pojlib options-inode
ownership repair plus the exact RC5.1 launcher identity allowlist.

Use the existing fail-closed gate:

```powershell
pwsh -NoProfile -File scripts/build-v71-lab-rc5-integrated.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/build-v71-lab-rc5-integrated.ps1 -Action Build -AllowBuild
```

The Host transaction never invokes ADB or reads/writes a live `options.txt` or
`resourcepacks`. It builds Pojlib twice, requires byte-identical AARs and passing
tests, restores source AAR/ProjectSettings in `finally`, and audits the resulting
APK. RC5's prior APK remains a separately named immutable predecessor.

## Exact v71 RC5 persistent Lab candidate

RC5 has its own immutable lock and Host-only transaction; RC4 locks, APKs, and
runtime receipts are historical inputs and must not be rewritten. Its identity
is `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.5`, with output
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.5-integrated-local.apk`.

The exact RC5 inputs and audited output are recorded in
`V71_LAB_RC5.lock.json`. Run the Host-only gates with:

```powershell
pwsh -NoProfile -File scripts/build-v71-lab-rc5-integrated.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/build-v71-lab-rc5-integrated.ps1 -Action Build -AllowBuild
```

The Build action performs two clean Pojlib builds, byte-reproducibility and
unit-test checks, Unity build, and the APK artifact audit. It backs up and
restores the exact checked-in AAR and ProjectSettings and quarantines any prior
output until success. It never invokes ADB and does not read or write
`options.txt`, `resourcepacks`, or Quest user data. A successful Host build
allows supervised Lab installation only; runtime and Stable promotion require
fresh RC5 evidence.

## Exact v71 RC4 Lab candidate

RC4 is a Lab-only candidate until every exact-candidate gate passes. Its fixed
identity is:

- Application ID: `com.qcxr.qcxr.canary262`
- Version code: `71`
- Version name: `6.0.1-26.2-vivecraft-personal.12-rc.4`
- Output: `QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.4-integrated-local.apk`
- Expected signer: `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`

The exact Host-prepared inputs are:

- Vivecraft Core `26.2-1.3.15+qc.v71.rc4`: `10068021` bytes,
  SHA-256 `289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189`.
- Frozen VEQ `0.7.0-v70-canary.1`: `441660` bytes,
  SHA-256 `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.
- Ordered Core/VEQ pair digest:
  `9D2C0830A34963FF3D5F336B465A6B8D11C153E82A738D0528E8D1821F25A8B1`.
- Pojlib AAR: `88700612` bytes,
  SHA-256 `7CE62B90112B74790100F5A8685412CA477D8086167598975A67DDC9E7FD7F2F`.

This exact RC4 AAR and Unity's Android Gradle stage both use Unity's bundled
Temurin `11.0.14.1+1`. A newer Java 25 compiler adds unnamed
`MethodParameters` entries to synthetic bridge methods; Unity 2022.3's pinned
D8 `4.0.52` crashes while reading that bytecode. The bundled JDK 11 artifact
passes the same D8 directly and is reproducible. Do not upgrade Gradle, D8, or
substitute another JDK while reproducing RC4.

Before Unity runs, the build harness extracts `classes.jar` from the second
clean Pojlib build and dexes it with the exact AGP `7.4.2` builder JAR
(`346CA459...DD360E`, D8 `4.0.52`). A missing, ambiguous, changed, or failing
D8 artifact stops the transaction before the checked-in AAR can be replaced.

The earlier incremental Core `DB1DF70F...3AA4B8` is rejected. Two clean builds
instead reproduced `289C2705...13189` byte-for-byte; the difference was stale
debug parameter metadata, not executable instructions. RC4 therefore locks
only the clean-reproducible artifact. Vivecraft passed 43 suites / 156 tests,
VEQ passed 59 executable self-tests plus 9 static verifiers across 86 Gradle
tasks, and both Pojlib variants passed 21 suites / 102 tests each (42 / 204
combined).

Do not substitute RC3 receipts for RC4 validation. The exact RC4 APK build and
audit, profile reconciliation, three normal cold starts, lifecycle/recovery,
and the first of two 90-minute memory soaks are now `PASS`. Manual interaction,
the second valid 90-minute soak, the combined memory contract, balanced
performance, and all Stable gates remain `PENDING/NOT_RUN`. The memory policy
remains Xms `512 MiB`, automatic Xmx `1536 MiB`, native headroom `1024 MiB`,
and manual/automatic hard maximum `2048 MiB`. The Stable package, final version
identity, signer, and frozen VEQ bytes must not change while preparing the Lab
candidate.

Keep `V71_LAB_RC3.lock.json` and its receipts immutable. RC4 uses
`V71_LAB_RC4.lock.json`, `V71_STABLE_RC4_ACCEPTANCE.lock.json`, and only RC4-
namespaced producers. Unknown APK and runtime-evidence hashes remain null rather
than being inferred from RC3. The memory producer captures its launcher marker
at soak start and binds the final attestation to the same PID, because logcat
retention across a 90-minute soak is not an acceptance primitive.

The RC4 Host-only gates are:

```powershell
pwsh -NoProfile -File scripts/build-v71-lab-rc4-integrated.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/build-v71-personal-stable.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-v71-build-transaction.ps1
pwsh -NoProfile -File scripts/run-vivecraft-local-autoplay.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/quest-v71-lab-lifecycle-recovery-rc4.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-v71-lab-lifecycle-recovery-rc4-host.ps1
pwsh -NoProfile -File scripts/quest-v71-memory-soak-rc4.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/quest-v71-memory-runtime-contract-rc4.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/quest-v71-rc3-rc4-ab.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-v71-rc3-rc4-ab-host.ps1
pwsh -NoProfile -File scripts/test-v71-rc4-stable-evidence-gate.ps1
pwsh -NoProfile -File scripts/quest-v71-rc4-stable-install.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-v71-rc4-stable-install-host.ps1
```

Only `build-v71-lab-rc4-integrated.ps1 -Action Build -AllowBuild` may build the
pending Lab APK. It is Host-only but intentionally requires a clean worktree
and Unity. Runtime and Stable actions remain blocked until the exact APK and
all fresh RC4 evidence are locked and independently reviewed.

## Locked Personal v69 Stable artifacts

- Pojlib AAR SHA-256:
  `88A172AF772E9DE600864831D617729E9F8E04DFBEB4BB30FC54B9F7407D6DD3`
  (`86970097` bytes).
- Vivecraft SHA-256:
  `3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F`.
- Vivecraft Essentials Quest SHA-256:
  `6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9`.
- APK SHA-256:
  `05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034`
  (`126700777` bytes).

The VEQ release JAR contains the user-accepted `rc.2.7` gameplay payload; its
only JAR-entry differences are release metadata and the generated Architectury
injection class. The full Unity build returned exit code `0`, and the APK passed
the Host artifact verifier. Same-signer `adb install -r` over exact v68 passed,
and the installed `base.apk` hash matched. The Stable activity itself did not
start after installation, so `TEST_RESULTS.md` intentionally makes no
post-install Stable runtime claim. Camera Park is enabled only after XR handoff,
autoplay is Lab-only, and Idle Throttle is absent.

## Historical Personal v68 artifacts

The exact v68 APK replaced by Stable v69 was versionCode `68`, versionName
`6.0.1-26.2-vivecraft-personal.9`, SHA-256
`0F218BB5542E90EA19E22E6763AE5A4D10995B6A2494439108385FC8DD2C00E1`
(`126641877` bytes). Its checked-in Pojlib AAR was SHA-256
`136AC1E2C788E06F720B87B5C5A9DF5C52D363F3F862928AD6934575656E3E51`
(`86905783` bytes). These are audit/rollback values, not current build inputs.

## Isolated v70 Core + VEQ Lab canary

`VEQ_LAB_CANARY.lock.json` and `scripts/quest-veq-lab.ps1` define the v70 VEQ
one-shot contract. They are fixed to package `com.qcxr.qcxr.canary262`, profile
`26.2`, the embedded VEQ baseline, and Fabric version
`0.7.0-v70-canary.1`. Each candidate hash must be supplied explicitly by the
Host and is bound into the strict marker; no future v70 hash is baked into
source. The superseded `1047f873` artifact remains explicitly rejected. The
helper has no package/profile override. Deploy requires both `-ExpectedSha256` and
`-AllowDeviceWrite`; rollback requires explicit `-AllowDeviceWrite`. See
`scripts/quest-veq-lab-safety.md` for the one-shot atomic promotion and
automatic baseline-restoration contract.

The Host checks are:

```powershell
pwsh -NoProfile -File scripts/quest-veq-lab.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-veq-lab-host.ps1
pwsh -NoProfile -File scripts/quest-v70-lab-pair.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-v70-lab-pair-host.ps1
```

These commands do not resolve ADB. Building the Lab APK still requires the
normal `scripts/build-v70-lab-canary.ps1 -Action Build -AllowBuild` path so the
new Pojlib gate is rebuilt and verified in `classes*.dex`; do not reuse the
checked-in Personal v69 AAR as a Lab build result.

## Historical Personal v61 result

Personal v61 used Pojlib AAR
`89CC26FCCD60ECA6A06091063D17E821F459B15D4102559FFFDD6A881CFEA7AB`
and APK
`A5142D3C556FAE9C1A487E460ED314D5E6957161E742F506CC54B270D2F88198`
(`126319325` bytes). Those values are retained only as a rollback/audit
baseline and must not be used to verify v66.

An initial build exposed a mismatch between the mod SHA stored in the manifest
and the artifact embedded in the APK. The verifier now compares both values and
must reject such a mismatch. Only the final verified APK above is accepted.

## Prerequisites

- Git LFS, with all LFS objects materialized.
- Unity `2022.3.62f3`.
- Unity Android Build Support, including its SDK, NDK and OpenJDK components.
- Unity's bundled OpenJDK for the Pojlib/Android and Unity stages.
- JDK 17 or newer to launch the Vivecraft Gradle wrapper. Its checked-in Foojay
  resolver downloads the required JDK 25 compiler toolchain when needed.
- PowerShell on Windows.

Use a short checkout path such as `C:\src\questcraft` on Windows. Some bundled
Unity/PICO assets have long names and may exceed legacy path-length limits in a
deep user directory.

Confirm that `QCXR-XR-Wrapper/ProjectSettings/ProjectVersion.txt` still names
Unity `2022.3.62f3`. Do not open and resave the project with a different Unity
major version merely to produce a build.

## Fabric Loader pin and fallback

Minecraft 26.2 deliberately pins Fabric Loader `0.19.4`. Fabric currently marks
that version as a canary, so it must not be replaced with an automatically
selected "latest" loader.

If device testing proves that `0.19.4` caused a regression, the explicit
fallback is `0.19.3`. Change `FABRIC_LOADER_26_2` in the two Pojlib files and
`fabric_loader_version` in the Vivecraft properties file, rebuild both
components, and retest the same instance:

- `Pojlib/src/main/java/pojlib/InstanceHandler.java`
- `Pojlib/src/main/java/pojlib/install/Installer.java`
- `Vivecraft-26.2-Quest/gradle.properties`

This rollback is manual by design. The launcher must not silently downgrade a
tested instance at runtime.

## Build and stage Vivecraft

Build the Fabric release JAR before building Pojlib. Gradle resolves the JDK 25
compiler toolchain automatically. Pojlib packages that JAR as an instance
asset, so the build order matters:

```powershell
$env:JAVA_HOME = "<path-to-JDK-17-or-newer>"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

Push-Location ".\Vivecraft-26.2-Quest"
try {
    .\gradlew.bat --no-daemon `
        -Pproject.build.excludeForge=true `
        -Pproject.build.excludeNeoforge=true `
        :common:test
    if ($LASTEXITCODE -ne 0) { throw "Vivecraft common tests failed." }

    .\gradlew.bat --no-daemon `
        -Pproject.build.excludeForge=true `
        -Pproject.build.excludeNeoforge=true `
        :fabric:clean :fabric:build
    if ($LASTEXITCODE -ne 0) { throw "Vivecraft Fabric build failed." }
} finally {
    Pop-Location
}

$VivecraftJar = ".\Vivecraft-26.2-Quest\build\libs\vivecraft-26.2-1.3.15-fabric.jar"
$VivecraftAsset = ".\Pojlib\src\main\assets\mods\vivecraft-26.2-1.3.15-quest.bin"
if (-not (Test-Path -LiteralPath $VivecraftJar -PathType Leaf)) {
    throw "Expected Fabric release JAR was not produced: $VivecraftJar"
}
Copy-Item -LiteralPath $VivecraftJar -Destination $VivecraftAsset -Force
```

The `.bin` suffix is intentional; its contents are the Fabric release JAR.
Update only its existing entry in `CHECKSUMS.sha256`, preserving the other
artifact checksums:

```powershell
$ChecksumFile = ".\CHECKSUMS.sha256"
$ChecksumAssetPath = "Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin"
$VivecraftHash = (Get-FileHash -LiteralPath $VivecraftAsset -Algorithm SHA256).Hash
$ChecksumPattern = "^[0-9a-fA-F]{64}  $([regex]::Escape($ChecksumAssetPath))$"
$ChecksumLines = @(Get-Content -LiteralPath $ChecksumFile)
$MatchingChecksumLines = @($ChecksumLines | Where-Object { $_ -match $ChecksumPattern })
if ($MatchingChecksumLines.Count -ne 1) {
    throw "Expected exactly one Vivecraft entry in CHECKSUMS.sha256."
}
$UpdatedLines = $ChecksumLines | ForEach-Object {
    if ($_ -match $ChecksumPattern) { "$VivecraftHash  $ChecksumAssetPath" } else { $_ }
}
[System.IO.File]::WriteAllLines(
    (Resolve-Path -LiteralPath $ChecksumFile).Path,
    $UpdatedLines,
    [System.Text.UTF8Encoding]::new($false)
)
```

## Build Pojlib

From the repository root, select the Android SDK and Unity-bundled JDK for the
current PowerShell session, then build the release AAR:

```powershell
$UnityRoot = "<path-to-Unity-2022.3.62f3>\Editor"
$env:JAVA_HOME = Join-Path $UnityRoot "Data\PlaybackEngines\AndroidPlayer\OpenJDK"
$env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

Push-Location ".\Pojlib"
try {
    .\gradlew.bat --no-daemon clean assembleRelease
    if ($LASTEXITCODE -ne 0) { throw "Pojlib build failed." }
} finally {
    Pop-Location
}
```

The accepted v69 AAR was built with Unity's bundled OpenJDK 11. Do
not substitute JDK 21 for this Android stage: its newer class-file metadata made
Unity's bundled D8 crash. The final AAR passed a standalone D8 check before the
Unity build.

Copy the generated AAR into Unity without deleting its existing `.meta` file:

```powershell
Copy-Item `
    ".\Pojlib\build\outputs\aar\Pojlib-release.aar" `
    ".\QCXR-XR-Wrapper\Assets\Plugins\Android\Pojlib-release.aar" `
    -Force
```

Update the existing AAR entry in `CHECKSUMS.sha256` before building Unity:

```powershell
$Aar = ".\QCXR-XR-Wrapper\Assets\Plugins\Android\Pojlib-release.aar"
$AarPath = "QCXR-XR-Wrapper/Assets/Plugins/Android/Pojlib-release.aar"
$AarHash = (Get-FileHash -LiteralPath $Aar -Algorithm SHA256).Hash
$Lines = @(Get-Content -LiteralPath ".\CHECKSUMS.sha256")
$Matches = @($Lines | Where-Object { $_ -match "^[0-9a-fA-F]{64}  $([regex]::Escape($AarPath))$" })
if ($Matches.Count -ne 1) { throw "Expected exactly one Pojlib AAR checksum entry." }
$Lines = $Lines | ForEach-Object {
    if ($_ -match "^[0-9a-fA-F]{64}  $([regex]::Escape($AarPath))$") {
        "$AarHash  $AarPath"
    } else {
        $_
    }
}
[System.IO.File]::WriteAllLines(
    (Resolve-Path -LiteralPath ".\CHECKSUMS.sha256").Path,
    $Lines,
    [System.Text.UTF8Encoding]::new($false)
)
```

## Build synchronization invariants

Do not edit one source tree and leave a previously generated binary in the next
tree. Preserve this chain on every source change:

1. A `Vivecraft-26.2-Quest/` change requires the exact Fabric test/build above,
   copying the resulting release JAR to
   `Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin`, updating that
   entry in `CHECKSUMS.sha256`, rebuilding Pojlib, and restaging its AAR in
   Unity.
2. A `Pojlib/jre_lwjgl3glfw/src/` change first requires this task from
   `Pojlib/`, before `assembleRelease`:

   ```powershell
   .\gradlew.bat --no-daemon :jre_lwjgl3glfw:mergeLwjglRuntime
   ```

   Commit the regenerated `src/main/assets/lwjgl/lwjgl-glfw-classes.bin` and
   `src/main/assets/lwjgl/version` together with the source change.
3. Any other Pojlib Java/native/assets change requires `assembleRelease`, then
   copying `Pojlib-release.aar` into
   `QCXR-XR-Wrapper/Assets/Plugins/Android/` without removing its `.meta`, and
   updating the AAR checksum. The staged AAR is tracked by Git LFS.
4. The combined `coreMods` and `defaultMods` entries in the `26.2` blocks of
   `Pojlib/mods.json`, `Pojlib/devmods.json`,
   `Pojlib/src/main/assets/mods.json`, and
   `Pojlib/src/main/assets/devmods.json` must remain identical. Together they
    contain the same eleven managed entries, including the pinned local
    Vivecraft Essentials Quest artifact. `scripts/pin-vivecraft-essentials-quest.ps1`
    updates that real hashed add-on in all four manifests together; never add a
    placeholder that cannot launch. The script validates the archive, Fabric
    mod id, exact version and Minecraft environment before changing files. It
    stages every replacement atomically and restores all earlier targets if a
    later write fails.

Finally rebuild Unity and run the APK verifier. A source-only change with stale
embedded JAR/AAR output is not a complete QuestCraft build.

## Build the Unity APK

Close any Unity Editor session that already has the project open. Then run the
checked-in fail-closed build helper. `SelfTest` is read-only; `Build` rebuilds
Pojlib, stages it only for the Unity build, verifies the APK, and restores the
checked-in AAR in `finally`:

```powershell
.\scripts\build-v69-personal-stable.ps1 -Action SelfTest
.\scripts\build-v69-personal-stable.ps1 `
    -Action Build `
    -AllowBuild `
    -UnityEditor "<path-to-Unity-2022.3.62f3>\Editor\Unity.exe"
```

The underlying Unity entry point is
`QuestCraftPersonalV69CliBuild.BuildAndroid`. It requires the exact Personal
package, label, version and output arguments and rejects release-signing mode.

The default is a locally debug-signed APK. Do not commit local keystores,
passwords, build logs, or generated APKs. Release signing credentials must never
be passed on the command line because Unity records its command line in logs.

For Personal v69, Unity `2022.3.62f3` completed this build with exit code `0`.
The resulting `126700777`-byte APK has SHA-256
`05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034`.
It passed Host gates and exact-hash installation. It does not record a
post-install Stable cold-start, controller, eye-comfort, soak, or FPS result.

### Historical locked v67 RC1 repack fallback

Unity 2022.3.62f3 was not installed when the historical v67 RC1 was assembled.
For that personal canary only, `scripts/repack-v67-local-canary.ps1` rebuilds
from the exact verified installed v66 base with SHA-256
`708962B958B8373B46231F8DA6C7B2AC284593BB30B291B46C68931FD1A3A70D`.
It patches equal-length version metadata and replaces only the two embedded
manifests plus Vivecraft and VEQ assets, then repeats identity, signer, ZIP and
payload checks. This does not replace the canonical Unity build procedure and
must never be described as a Unity-built v67 artifact.

Before installing v67, also build the rollback payload with
`scripts/build-v67-v66-payload-rollback.ps1`. It preserves the exact v66 payload
but reports versionCode 67 so Android can accept a same-signer `install -r`
rollback without an uninstall or data clear. Its file name, not its Android
version label, distinguishes it from the v67 candidate.

## Verify the output

Run the repository verifier before installing the APK. It checks 16 KiB ZIP
alignment, the APK signature, package/version/SDK metadata, the ARM64-only ABI,
the required Quest/OpenXR payload, and reports the APK SHA-256:

```powershell
$Apk = Join-Path $PWD "QCXR-XR-Wrapper\Builds\QuestCraft-Vivecraft-26.2-personal.10-local.apk"
.\scripts\verify-dev-apk.ps1 `
    -ApkPath $Apk `
    -ExpectedPackage "com.qcxr.qcxr.dev262" `
    -ExpectedVersionCode "69" `
    -ExpectedVersionName "6.0.1-26.2-vivecraft-personal.10" `
    -ExpectedLabel "QuestCraft Vivecraft Personal 26.2" `
    -ExpectedVivecraftSha256 "3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F" `
    -ExpectedSignerSha256 "b9bc192248354c7330eae3781c39a5b569407f0dccbcaf354c706dee14d4ca1a"
```

That signer digest is the checked local Dev baseline. Treat a mismatch as a
different signing identity and investigate it before replacing or updating an
installed Dev build. The verifier also requires package
`com.qcxr.qcxr.dev262`, version code `69`, and version name
`6.0.1-26.2-vivecraft-personal.10`. The application label is
`QuestCraft Vivecraft Personal 26.2`.
It additionally verifies that each managed manifest hash matches the embedded
asset; matching the manifest alone is not sufficient.

The digest above belongs only to Akram's locally signed Dev lineage. A developer
building from a fork should pass its own expected signer digest, inspect and
record the verifier's reported signer, then keep using that digest
for later builds from the same key. A fork's differently signed APK cannot
update the already installed Akram-signed package even when the application ID
matches; do not uninstall or clear the existing app automatically to work
around that protection.

Install only on an authorized test headset. Do not uninstall another QuestCraft
package or clear application data as part of verification.

## Historical Dev.2 validation baseline

The 2026-08-28 local candidate completed these checks:

- Fabric Loader `0.19.4` and every pinned 26.2 Modrinth version were confirmed
  as the newest matching candidates available on that date.
- Vivecraft `clean :fabric:build` passed with the menu-placement change and
  Fabric Loader `0.19.4`; `:common:test` and `ShaderPatchingTest` also passed.
- Pojlib `assembleRelease` passed after staging the rebuilt Vivecraft asset.
- Unity `2022.3.62f3` completed `QuestCraftCliBuild.BuildAndroid` successfully.
- `scripts/verify-dev-apk.ps1` passed for package, label, versions, SDK levels,
  ARM64-only ABI, APK Signature Scheme v2, the known Dev signer, 16 KiB ZIP
  alignment, OpenXR/Vulkan-support payloads, its 14 managed 26.2 entries, and
  the embedded Vivecraft/LWJGL hashes.
- Local APK SHA-256:
  `90373325B1C30A87C969719C0BF2919301AFE00909E50C5BCE8CA266945B2EF7`.

The APK was subsequently installed on an authorized Quest 3 under the separate
Dev package. Vulkan/OpenXR startup, Minecraft entry, and multiplayer entry over
Tailscale passed smoke testing. A later performance investigation found that a
QGO Home profile had forced the Dev package to CPU level 2 and GPU level 0.
After assigning the Dev package a CPU 4/GPU 4 profile, a one-minute core-only
sample improved from 51.69 mean FPS to 91.48 mean FPS with no thermal throttle.
Those two samples used different refresh-rate behavior, so they prove the
processor-profile bottleneck but are not a normalized mod comparison.

The ten optional JARs were restored after that investigation. That historical
14-entry pack did not pass a normalized CPU4/GPU4 soak and is not the v60
default. Three cold
settings-persistence runs, complete death/loading interaction tests, stereo
culling inspection, Tailscale direct-versus-DERP measurement, and the final
30-minute multiplayer run also remain gates. See `AI_HANDOFF.md` for exact
measurements and current device-test status. Do not describe the canary
combination as runtime-accepted until those checks pass.

The checked-in GitHub workflow validates only the Vivecraft common tests and
Fabric artifact. It does not build Pojlib or Unity and does not test an APK on
Quest hardware. The build also resolves `fabric_loom=1.15-SNAPSHOT`, Gradle
distributions without pinned distribution hashes, and a Foojay JDK 25
toolchain, so archive resolved versions/hashes when producing a formal release.
