# Managed-mod A/B Lab harness

This harness prepares four one-variable experiments for the isolated QuestCraft
Lab package. It is disabled by default and cannot accept a package or profile
override.

- package: `com.qcxr.qcxr.canary262`
- forbidden package: `com.qcxr.qcxr.dev262`
- profile and Minecraft version: `26.2`
- transaction state: `.questcraft/questcraft-mods-ab-canary-v1`
- fixed contract: `MODS_AB_LAB.lock.json`

The allowed order is:

1. `sodium-0.9.1`: replace the exact Sodium `0.9.2-alpha.4` baseline with the
   exact preserved official `0.9.1` JAR.
2. `without-lithium`: hold only `mods/Lithium.jar` outside `mods`.
3. `without-ferrite-core`: hold only `mods/Ferrite-Core.jar` outside `mods`.
4. `without-bad-optimizations`: hold only `mods/BadOptimizations.jar` outside
   `mods`.

ImmersiveMC, Xaero, VEQ, and all other managed artifacts remain hash-exact.
Only one marker exists at a time. The runtime refuses concurrent Vivecraft/VEQ
canary permits.

## Safety and transaction behavior

`Arm` and `Rollback` require `-AllowDeviceWrite`, a local baseline JAR, and an
independently supplied baseline SHA-256. Sodium replacement also requires the
candidate path and its independently supplied SHA-256. Artifact hashing,
bounded ZIP checks, root `fabric.mod.json`, metadata, and the fixed allowlist
are validated before ADB is resolved. Disable experiments reject any candidate
file.

The Host arm transaction requires the app/JVM to be stopped and the selected
target to equal the locked baseline. It copies that baseline into harness state,
stages the optional Sodium candidate outside `mods`, and commits `request.json`
last with an atomic rename. Pojlib runs the gate after normal mod reconciliation:

1. validate the exact Lab package/profile, marker, baseline, other-mod
   fingerprint, and bundled `mods.json` lock;
2. commit `attempting` atomically;
3. either atomically replace Sodium or atomically move one selected JAR into a
   reversible held location;
4. verify the resulting hash/absence, commit `consumed`, and publish a
   process-local permit;
5. restore the exact baseline on any transaction or unattended-stack failure;
6. restore before reconciliation on the next Play, including another Play in
   the same launcher process.

There is no non-atomic rename fallback. A crash after `attempting` is recovered
from the exact staged/held baseline on the next prelaunch. Explicit `Rollback`
uploads the independently checked baseline, replaces only the selected target
by same-directory atomic rename, verifies it, and removes only harness-owned
state for the marker's exact run. Rollback first reads the bounded marker and
requires its target/run to match the selected experiment; it refuses a
cross-experiment cleanup and never uses broad candidate/disabled globs. It
never installs/uninstalls an APK, clears app data, starts the app,
touches worlds/configuration/accounts, or modifies Stable.

## Host-only verification

The implementation used only the already preserved artifacts. These commands
do not resolve or invoke ADB:

```powershell
pwsh -NoProfile -File scripts/quest-mods-ab-lab.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-mods-ab-lab-host.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File scripts/test-quest-mods-ab-lab-host.ps1
```

## Supervised A/B use

For each experiment, first collect A with no armed marker and the exact current
baseline. Then arm B once, press Play once, collect the sample, and explicitly
rollback before returning to A or selecting another experiment. The automatic
next-prelaunch restore is an additional safety net, not a substitute for
checking `Status` and running `Rollback` between candidates.

Example for Sodium (paths may point to any local copies that match the fixed
hashes):

```powershell
$alpha4 = '<absolute path to sodium-fabric-0.9.2-alpha.4+mc26.2.jar>'
$official091 = '<absolute path to sodium-fabric-0.9.1+mc26.2.jar>'

pwsh -NoProfile -File scripts/quest-mods-ab-lab.ps1 `
  -Action Arm -Experiment sodium-0.9.1 `
  -BaselineJar $alpha4 `
  -ExpectedBaselineSha256 A6D1CED177A1C57147E8C1C8043650D5F93E1F2824C9952F3FB67AE05633A0A7 `
  -CandidateJar $official091 `
  -ExpectedCandidateSha256 DE406C7A0CA5E748DFBE44740278400882A44E3109E2584B243EC02D4003344B `
  -AllowDeviceWrite
```

Example for one removal candidate:

```powershell
$lithium = '<absolute path to the locked Lithium.jar>'
pwsh -NoProfile -File scripts/quest-mods-ab-lab.ps1 `
  -Action Arm -Experiment without-lithium `
  -BaselineJar $lithium `
  -ExpectedBaselineSha256 FDDE92E238E8075F89AD7F701F2A3D5854AF88BA9A67657184A4407B104AC563 `
  -AllowDeviceWrite
```

Rollback uses the same selected experiment, baseline path, independent hash,
and `-AllowDeviceWrite`, and requires that experiment's valid marker to still
be present. `Status` is read-only. Canonical `/storage/emulated/0` is accepted
only as the proven `realpath` result of the fixed `/sdcard` Lab root. Root
fallback remains disabled unless `-AllowRootFallback` is explicit and the
normal-shell capability probe fails before a mutation begins; when selected,
ownership and modes are derived from the existing Lab game directory and
baseline file, applied to new state, and verified rather than using hard-coded
Android IDs.
