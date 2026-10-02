# Vivecraft core canary harness

This is a **Host-verified, disabled-by-default development harness** for a
separate Lab package built from the accepted Personal v69 source baseline. It cannot
target or mutate the accepted Personal v69 package, and it does not claim
Quest runtime, stereo, stability, or performance acceptance.

## Fixed scope

- Android package: `com.qcxr.qcxr.canary262`
- application label: `QuestCraft Vivecraft Lab 26.2`
- profile and Minecraft version: `26.2`
- managed target: `mods/Vivecraft.jar`
- harness id: `questcraft-vivecraft-core-canary-v1`
- marker schema: `2`; required copy-batch mode: exact `OFF` or `ON`
- embedded baseline SHA-256:
  `3638f258c7daab8391975db8c39ae254f67a1fd96aa540650d07e5318a0d842f`
- candidate limit: 16 MiB; archive expansion limit: 64 MiB
- maximum arm lifetime: 30 minutes; `maxLaunches` must be `1`

The state directory is
`26.2/.questcraft/questcraft-vivecraft-core-canary-v1`. A candidate remains in
that directory, outside `mods`, until Pojlib has completed normal managed-mod
reconciliation and the Java gate atomically renames it over the exact baseline.
There is no non-atomic promotion fallback.

The state path intentionally retains the `v1` harness id while the marker is
schema 2. This makes an old schema-1 request visible to the new gate so it is
rejected, quarantined, and restored to baseline instead of being orphaned in a
different directory.

With no `request.json`, the gate returns immediately and does not modify the
profile. A successful promotion creates only an in-process permit. The
persistent JSON marker alone can never make `UnattendedStackVerifier` accept a
different Vivecraft hash or enable copy batching. The fixed embedded-JVM
property defaults to `-Dvivecraft.openxrCopyBatch=OFF`; only a validated,
process-local Permit can supply exact `ON`, and that mode claim is consumed
once before the JVM starts.

Android gives the Lab package a different external-files root, so its
`instances/26.2` profile, accounts, configuration, worlds, and managed mods are
isolated from `com.qcxr.qcxr.dev262`. This harness never reads or writes the
stable package path. Initial Lab account/profile/world setup is therefore a
separate, manual device prerequisite; account files are never copied.

The Lab branch pins the same identity in Unity `ProjectSettings`, the normal
CLI builder defaults, the fail-closed Lab builder, Android Resolver metadata,
PICO metadata, the Pojlib core gate, and the unattended action gate. The
normal builder explicitly refuses `com.qcxr.qcxr.dev262`; the strict Lab entry
point additionally requires every identity argument and refuses `-release`.

## One-shot transaction

1. `Deploy` validates the local archive, its explicit expected SHA-256, one
   root `fabric.mod.json`, `id=vivecraft`, its exact version, Minecraft
   dependency `26.2.x`, and Java dependency `>=25`.
2. Path traversal, duplicate/case-colliding ZIP names, ZIP symlink entries,
   oversized archives, and multiple connected ADB devices are rejected.
3. The script fingerprints every other regular `*.jar` except the exact Core
   and VEQ managed targets as sorted
   `filename<TAB>lower-sha256<LF>` rows. The SHA-256 of those rows is stored in
   the marker and rechecked after launcher reconciliation.
4. The candidate is staged outside `mods`; `request.json` is committed last by
   a same-directory rename. Device writes require `-AllowDeviceWrite`.
5. Pojlib accepts only the exact package/profile/target/harness, lower-hex
   32-character run id, baseline and candidate hashes and sizes, Fabric
   metadata, other-mod fingerprint, expiry, and `maxLaunches=1`. The marker is
   a flat, all-fields-required schema 2 that also requires
   `openXrCopyBatchMode` to be exact uppercase `OFF` or `ON`. Unknown, missing,
   duplicate, mistyped, lowercase, or trailing JSON is rejected.
6. Pojlib atomically changes `armed -> attempting`, atomically promotes the
   candidate, verifies it again, changes the marker to `consumed`, and only
   then publishes the process-local permit.
7. `attempting`, `consumed`, `expired`, invalid, and unknown states never
   promote. They restore the exact APK baseline (when needed) and either remain
   terminal or are atomically quarantined.
8. A transaction failure after attempting, or an unattended full-stack
   verification failure after promotion, restores the exact baseline and
   aborts the launch. The next prelaunch also restores the baseline before it
   can continue, so a canary is never automatically retried.

The gate can restore a baseline while offline because it materializes the
verified APK asset into the private harness directory before promotion. Normal
online reconciliation normally restores that same asset first; the gate still
requires the exact baseline immediately before promotion.

## Commands

All examples are run from the repository root. First verify the fixed Lab
identity without building or contacting a device:

```powershell
.\scripts\build-v70-lab-canary.ps1 -Action SelfTest
```

The explicit Host-only build path is:

```powershell
.\scripts\build-v70-lab-canary.ps1 -Action Build -AllowBuild
```

It rebuilds Pojlib, temporarily stages that AAR in the Unity project, invokes
`QuestCraftV70LabCliBuild.BuildAndroid` with an exact Debug-only identity, restores
the checked-in AAR in `finally`, and runs the full APK verifier. The verifier
also proves the Lab action, harness, schema-2 mode, and fixed
`-Dvivecraft.openxrCopyBatch=` prefix reached `classes*.dex`, and rejects the
Personal unattended action. The build result records both the Git
HEAD and rebuilt Pojlib AAR SHA-256. It never uses ADB and refuses to start a
cold Unity build with less than 10 GiB free or with any tracked or untracked
worktree input. Its
only accepted output is
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v70-rc.1-local.apk`
with package `com.qcxr.qcxr.canary262`, label
`QuestCraft Vivecraft Lab 26.2`, versionCode `70`, and versionName
`6.0.1-26.2-vivecraft-personal.11-rc.1`, equal to the exact
`QuestCraftV70LabCliBuild.VersionName` source constant.

If the Host process is killed so forcefully that `finally` cannot run, the
backup at repository-root `.lab-build-backup/Pojlib-release.aar` is retained
outside Unity `Assets`, and later builds refuse to proceed.
Restore it only through the exact-hash recovery action:

```powershell
.\scripts\build-v70-lab-canary.ps1 -Action RestoreSourceAar -AllowBuild
```

`Status` is read-only:

```powershell
.\scripts\quest-vivecraft-core-canary.ps1 -Action Status
```

Deploy requires the candidate hash to be supplied independently:

```powershell
$jar = 'C:\absolute\path\vivecraft-canary.jar'
$sha = (Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash
.\scripts\quest-vivecraft-core-canary.ps1 `
  -Action Deploy `
  -JarPath $jar `
  -ExpectedSha256 $sha `
  -OpenXrCopyBatchMode OFF `
  -ExpiryMinutes 15 `
  -AllowDeviceWrite
```

The copy-batch comparison is pinned to the v68-only JAR below. Both A and B
deploy this exact SHA; A passes `OFF` and B passes `ON`:

```powershell
$jar = Join-Path $PWD `
  'artifacts\candidate\vivecraft-26.2-1.3.15-openxr-copy-batch-v68-only.jar'
& .\scripts\quest-v69-core-ab.ps1 -Action Plan `
  -CandidateJar $jar `
  -CandidateSha256 'A7298DFD1EA6BE238CB1AA815E46E774295A4FCBA771EB1345BA1B361EB33F2F'
```

The device-capable `Run` action remains disabled without
`-AllowDeviceWrite`. Every retained OFF/ON report must contain the same JAR
SHA, the exact requested mode, and a fresh Vivecraft runtime marker. A report
is rejected if the opposite mode marker also appears. Each sample uses a cold
app/JVM because Vivecraft reads the property once when its renderer class is
initialized.

Before creating a run manifest or starting any round, `Run` resolves only the
fixed Lab package and requires exactly one installed `base.apk`. It pulls that
APK to a fresh Host temporary directory, runs the full APK verifier against
the exact package, source-pinned versionCode/versionName/label, accepted signer
SHA-256, bundled assets, and Lab DEX gates, records the APK SHA-256, size,
version, and signer in the manifest and every retained report, then deletes the
temporary APK in `finally`. Resume rejects a different installed APK, and
offline `Aggregate` rejects reports whose APK identity differs from the
manifest. No APK bytes or device path are retained with benchmark evidence.

Run this only after the Lab package has created its own `26.2` profile and
while its app/JVM are stopped. Do not copy the Personal profile or account into
Lab. The candidate is not embedded in the Lab APK: the one-shot harness stages
it outside `mods`, normal reconciliation restores the embedded v69 core first,
and prelaunch then atomically promotes the candidate for one process only.

Rollback requires the QuestCraft package and its JVM to be stopped. It stages
the checked-in v69 asset, atomically replaces only `mods/Vivecraft.jar`, proves
its exact hash and size, and removes only harness-owned files:

```powershell
.\scripts\quest-vivecraft-core-canary.ps1 -Action Rollback -AllowDeviceWrite
```

Normal shell is probed first. If normal shell cannot access the exact profile,
root is still unavailable unless `-AllowRootFallback` is explicit. The write
transport is chosen before a compound mutation and is never retried through a
different privilege level after partial execution.

## Host tests

None of the commands below resolves ADB:

```powershell
.\scripts\quest-vivecraft-core-canary.ps1 -Action SelfTest
.\scripts\test-quest-vivecraft-core-canary-transactions.ps1
.\scripts\build-v70-lab-canary.ps1 -Action SelfTest
.\scripts\run-vivecraft-local-autoplay.ps1 -Action SelfTest
.\scripts\quest-v69-core-ab.ps1 -Action SelfTest
```

The Java suite covers strict marker parsing, archive traversal/duplicate/
symlink rejection, terminal recovery, exact post-promotion rollback, failures
injected after every transaction stage, and concurrent prelaunch locking. The
PowerShell/Bash suite covers every deployment commit boundary, ambiguous
post-marker completion, exact rollback, shell syntax, and zero ADB calls.

## Deliberate exclusions and residual device gates

- The harness never installs/uninstalls an APK, clears data, changes
  QGO/Magisk, or reads/copies accounts, saves, `config`, `options.txt`, or
  Xaero data. The supervised A/B runner starts/stops only the fixed Lab app,
  resets only its fixed benchmark world, and reads a temporary copy of its
  installed `base.apk` solely for Host verification.
- `Deploy` and `Rollback` refuse a mutation if the package/JVM is running; the
  user or the supervised test runner owns app lifecycle.
- A native/JVM failure after Pojlib has handed control to Minecraft cannot be
  synchronously reported back through the current launcher API. The marker is
  already terminal, so the next prelaunch restores v69 and never retries it.
- Android filesystem `ATOMIC_MOVE`, actual launcher/JVM lifecycle, both eyes,
  controller behavior, crash recovery after process death, and FPS remain
  device-only gates. Do not call a candidate accepted until the supervised
  one-variable Quest test passes and this harness has restored v69 afterward.
