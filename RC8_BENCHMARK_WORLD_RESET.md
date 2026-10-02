# RC8 benchmark-world reset audit

## Outcome

The historical `scripts/reset-lab-benchmark-world.ps1` is not suitable for the
current two-endpoint Quest setup. It insists that `adb devices` contain exactly
one authorized endpoint even when `-Serial` is supplied, so one physical Quest
listed over USB and Wi-Fi is rejected. It also predates the exact V71 RC8
APK/Core/VEQ identity fence, does not reject a running Stable process, and its
`.v69-route-original` directory is not accompanied by an independently checked
digest.

The RC8-specific replacement is:

`scripts/quest-v71-rc8-benchmark-world-reset.ps1`

The historical helper remains unchanged because older evidence gates pin its
hash. New RC8 work should use only the RC8-specific tool.

The current `run-vivecraft-local-autoplay.ps1` passed its Host self-test and is
already fixed to the Lab package, profile `26.2`, and `FPS-Stress-Test`. An
explicit serial is passed directly to ADB, so a second Wi-Fi endpoint does not
create selection ambiguity. Its job is authenticated one-shot launch and
post-sync stack verification, however; it is not the authority for the exact
RC8 host lock or for the save snapshot. For an RC8 benchmark, run this reset
gate first and pass the same explicit USB serial to autoplay. Neither helper
claims deterministic player coordinates or route phase.

## Fixed scope and safety contract

The replacement is fixed to:

- Lab package `com.qcxr.qcxr.canary262`;
- forbidden Stable package `com.qcxr.qcxr.dev262`;
- profile `26.2`;
- save folder `FPS-Stress-Test`;
- V71 RC8 version, APK, Core, VEQ, signer-by-exact-APK, and build-lock hashes;
- route master SHA-256
  `9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90`.

`Status` and `Reset` require explicit read and identity consent. `Reset` also
requires `-AllowDeviceWrite`, `-AllowHostOutput`, a bounded `reset-NN.json`
receipt path, and an explicit non-network USB serial. When the
same headset is listed a second time as `ip:5555`, the named USB row is selected
exactly and the Wi-Fi row is ignored. Before writing, the tool also requires
Android's `ro.serialno` to match that explicit serial; this rejects a Wi-Fi mDNS
endpoint whose name does not contain `:port`. `auto` still fails closed unless
there is one authorized endpoint.

Normal world access is attempted first. If and only if `-AllowRootFallback` is
explicit, the tool may select the fixed `/debug_ramdisk/su` entrypoint before
the first mutation. Root scripts are streamed through standard input to
`su -c sh`; they are not nested in fragile shell quoting. A root cache miss is
staged and hash-checked under `/data/local/tmp` before root publishes it into
the tool-owned Lab cache. The selected access mode is fixed for the operation
and recorded in the reset receipt.

Before any replacement, the tool proves that Stable and Lab are both stopped.
The same two process checks run inside the snapshot and swap transactions. The
tool never stops either app itself.

The canonical `saves` directory is resolved independently and must equal the
fixed Lab/profile path. Snapshot creation and the swap transaction repeat the
non-symlink and canonical-path checks immediately before writing. This remains
mandatory even when an immutable original snapshot already exists, so a
symlinked `saves` ancestor cannot redirect staging, rollback, or deletion into
another package or directory.

The first live Lab benchmark world is preserved once as a tar plus a separate
SHA-256 record under the tool-owned Lab directory
`.questcraft-benchmark-rc8`. If the world did not exist, an exact absent marker
is stored instead. Every later reset validates that immutable contract and
validates the archive root and `level.dat` before touching the live world. The
snapshot is not silently replaced by a later master. It is intentionally not
auto-restored; recovery should be a separate reviewed operation.

The mutation surface is restricted to that tool-owned cache/snapshot directory
and the fixed Lab save folder. There is no path to Stable, account files,
configuration, mods, or resource packs. The resource pack previously used for
a server is outside this workflow.

The live-world swap keeps the previous directory at an unpredictable,
tool-owned rollback path until the promoted world is validated. A failed
promotion restores only into an absent destination, validates the rollback
before and after the move, and fails explicitly if restoration cannot be
proved. An unexpectedly occupied destination is never deleted, overwritten, or
quarantined; the rollback is retained for manual inspection. Successful cleanup
also revalidates the rollback before recursively removing that exact path.

The device shell deliberately uses plain `find`, whose Android Toybox default
does not follow symbolic links; Toybox exposes `-H` and `-L`, not GNU `-P`.
The tool separately rejects the root and every discovered symbolic link. This
keeps the transaction compatible with Quest's Android shell while retaining the
no-link contract. The relevant Android source is
[Toybox `find`](https://android.googlesource.com/platform/external/toybox/+/8324c7148a4f34b790c5a9fa42663569ba1e538f/toys/posix/find.c).

## Commands

Host-only checks:

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-benchmark-world-reset.ps1 `
  -Action SelfTest

pwsh -NoProfile -File .\scripts\test-quest-v71-rc8-benchmark-world-reset-host.ps1
```

Read-only status with USB selected while Wi-Fi ADB is also listed:

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-benchmark-world-reset.ps1 `
  -Action Status -Serial 'PASTE_USB_SERIAL_HERE' `
  -AllowDeviceRead -ConfirmExactRc8Lab
```

After the operator has stopped Lab and confirmed Stable is stopped:

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-benchmark-world-reset.ps1 `
  -Action Reset -Serial 'PASTE_USB_SERIAL_HERE' `
  -AllowDeviceRead -AllowDeviceWrite `
  -ConfirmExactRc8Lab -AllowHostOutput `
  -OutputJson artifacts/v71-rc8-input-performance-ab/world-reset-only/reset-01.json
```

Add `-AllowRootFallback` only when that exact reviewed fallback is intended.
The non-overwriting receipt includes the actual internal reset GUID, completion
time, reset-producer SHA-256, salted device binding, exact identity/master/
activation values, immutable snapshot state/hash, access mode, and final
Lab/Stable fences. It also proves that exact baseline Core and no v9 candidate
marker existed before the reset.

Only after a successful reset should the existing authenticated autoplay helper
be armed for `FPS-Stress-Test`.

## What is reproducible

The master has 126 entries: 100 files and 26 directories. Its archive is
path-safe, has one fixed top-level directory, and its `level.dat` SHA-256 is
`42446BBE1195E2AFB2BE44FC90600C7ED32750BF0F02D45C0CE505F83AAD9065`.
The reset therefore gives every arm the same on-disk save payload immediately
before launch. It also restores the saved entity/region data, world metadata,
and the player record present when the master was captured.

This is useful and materially better than continuing in an already-running
world, but it is not a complete deterministic scene reset:

- the master contains player data for one identity while its stats directory
  contains records for two identities; a different authenticated UUID may not
  inherit the captured position, inventory, or vehicle state;
- `session.lock` is rewritten when Minecraft opens the world;
- world ticks, entities, weather, redstone, and the minecart route advance as
  soon as the integrated server starts, so their phase after a wall-clock
  warm-up is scheduler-dependent;
- the filesystem reset does not restore HMD pose, boundary/recenter state,
  player view yaw, world scale, QGO refresh decisions, thermal state, JIT state,
  or renderer/chunk caches;
- authenticated autoplay proves the fixed profile/world and stack, but it does
  not currently assert player coordinates, view direction, minecart occupancy,
  entity phase, or a scene checksum before capture.

Consequently, results should still use counterbalanced order, matched observed
refresh strata, equivalent thermal start, and the same warm-up. A future fully
deterministic harness needs a small in-game benchmark marker that verifies (or
sets) dimension, player position/yaw, minecart seat/route phase, and a ready
scene checkpoint before recording. Until that exists, the reset is a verified
disk-state reset, not proof of identical rendered frames.

## Live USB validation status

The first real Windows/Quest read-only `Status` run exposed two Host assumptions
that the fake ADB fixture did not model: empty output rows from a stopped
`pidof`, and CRLF bytes inside a multiline `sh -c` body. The gate now accepts
blank rows only where its explicit parser subsequently proves the expected
cardinality, and normalizes every remote script to LF before POSIX quoting it.
The exact USB endpoint, package identity, APK, Core, VEQ, and canonical
Lab/profile paths then verified successfully without a device write.

Android scoped-storage ownership can deny ordinary shell access to the Lab
world. The current tool therefore has the explicit, fixed-entrypoint root
fallback described above, including standard-input transport and verified
rollback. This Host review did not repeat any live reset; its validation used
SelfTest and fake ADB only. A performance campaign may claim the disk reset
only when it retains the exact reset receipt required by the A/B runbook.

## Test evidence

The Host test uses only a fake ADB implementation. It covers simultaneous
USB/Wi-Fi rows, ambiguous/missing serials, absent write authorization, rejected
IP and mDNS Wi-Fi writes, Stable/Lab running, wrong version/package path,
escaped files/profile paths, APK/Core/VEQ hashes and symlinks, invalid world
layout, snapshot digest mismatch, unsafe snapshot entries, wrong/symlinked
master cache, canonical/non-symlinked `saves`, backup-before-swap ordering,
verified rollback restoration, and preservation when a rollback destination is
unexpectedly occupied. It also covers normal/root durable receipts, exact root
push target and ordering, marker-present refusal, path escape/no-overwrite, and
no receipt after a failed transaction. The existing autoplay Host self-test also passes.
No Quest, real ADB process, Stable data, account data, or resource pack was
accessed while producing this change.
