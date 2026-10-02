# RC8 Lab render-scale A/B safety contract

This is a one-variable, Lab-only experiment. It changes only the top-level
Vivecraft `renderScaleFactor` string from `"1.0"` to `"0.8"`, preserving every
other byte in `vivecraft-client-config.json`. In Vivecraft this value is an
area/pixel-count multiplier: the renderer applies its square root to each
linear eye dimension, so `0.8` is about `89.4%` width and height, not `80%` per
dimension.

## Fixed identity

- Package: `com.qcxr.qcxr.canary262`
- Forbidden Stable package: `com.qcxr.qcxr.dev262`
- Profile: `26.2`
- Version: `71` / `6.0.1-26.2-vivecraft-personal.12-rc.8`
- APK SHA-256: `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416`
- Signer SHA-256: `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`
- Core SHA-256: `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`
- VEQ SHA-256: `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`
- Only mutable device file:
  `/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/config/vivecraft-client-config.json`

Every identity field and the installed APK signer must match before a write.
The Lab must already be stopped. The tool never stops or launches it.

Every invocation, including read-only `Status`, first acquires one deterministic
named kernel mutex for this package/profile/config identity. Its name does not
depend on the worktree, so exact tool copies serialize the same Lab target. A
second process fails before resolving or calling ADB. If an owner process dies,
Windows transfers abandoned-mutex ownership to the next caller; the tool does
not delete or guess about stale lock files. The mutex creates no persistent
Host artifact and does not change the device-read-only meaning of `Status`.

## Actions

`Status` is the default. It reads identity, signer, config scale/hash, process
state, and any local transaction receipt. It performs no device write.
Native ADB may print a successful `pull` summary or progress on either stdout
or stderr. The gate accepts only bounded, recognized transfer chatter after a
zero exit code, a nonempty local file, and an exact local/remote SHA-256 match;
it discards the chatter without displaying or persisting it.

```powershell
pwsh -NoProfile -File scripts/quest-v71-rc8-render-scale-ab.ps1 -Action Status -Serial 'PASTE_USB_SERIAL_HERE' -AdbPath 'C:\path\to\adb.exe'
```

`Arm` requires the explicit write switch. It rejects anything other than an
exact string value `1.0`, writes byte-exact original and candidate copies plus
SHA-256-bound state under the gitignored
`artifacts/v71-rc8-render-scale-ab/`, pushes only a random same-directory
staging file, verifies it, rechecks stopped/identity/current bytes, then uses
`chmod 0660` on that exact verified staging file, re-verifies the staged digest
and mode after all slower probes, and uses one `mv` to replace the config
atomically. The mode correction is required because `adb push` creates
the scoped-storage file as the shell uid with mode `0644`; publishing that
mode would make Vivecraft's next in-game save fail with `Permission denied`.
Native ADB push progress is accepted on stdout or stderr only when it is
bounded and recognized; the staged remote SHA-256 is still verified before
the live config can be replaced, and transport chatter is never retained.
After a successful byte-exact `Restore`, `Arm` may reuse the same locked
original/candidate files for the final AB/BA/AB pair. It revalidates the full
transaction identity and live source bytes rather than deleting audit evidence.

```powershell
pwsh -NoProfile -File scripts/quest-v71-rc8-render-scale-ab.ps1 -Action Arm -AllowDeviceWrite -Serial 'PASTE_USB_SERIAL_HERE' -AdbPath 'C:\path\to\adb.exe'
```

`Restore` requires the same explicit switch, exact identity, stopped Lab,
untampered local backup/state, and either the exact armed candidate or an
already recovered original. It atomically restores the exact original bytes
and verifies their SHA-256. It refuses to overwrite unknown config drift.

```powershell
pwsh -NoProfile -File scripts/quest-v71-rc8-render-scale-ab.ps1 -Action Restore -AllowDeviceWrite -Serial 'PASTE_USB_SERIAL_HERE' -AdbPath 'C:\path\to\adb.exe'
```

## Explicitly impossible through this tool

- Stable access or mutation
- root/Magisk, install/uninstall, clear-data, force-stop, launch, reboot, or
  remount
- network/download commands
- account, authentication, world/save, mod, or resource-pack mutation
- arbitrary package, profile, path, scale, digest, or signer overrides

The only device-write argv sites are `adb push <local> <fixed-config>.next-*`,
`adb shell chmod 0660 <fixed-config>.next-*`, and
`adb shell mv <fixed-config>.next-* <fixed-config>`. If post-move digest
verification fails while the live file is still the exact candidate, the
still-authorized transaction attempts one atomic byte-exact emergency restore
and records `RECOVERED`. An unknown digest is preserved as possible external
drift; the tool keeps the original backup and refuses a speculative overwrite.

## Limitations

- This tool prepares the A/B state; it does not launch Minecraft, collect
  performance samples, judge image quality, or promote Stable.
- The transaction keeps its local evidence after restore and supports re-arm
  only from an exact `RESTORED` state on the same endpoint. Archive the evidence
  deliberately before starting an unrelated A/B campaign.
- A transport failure can leave an ignored `.next-*` staging file beside the
  config. The tool never removes remote files; Vivecraft does not load that
  name. The live config remains protected by pre/post SHA checks.
- `0.8` must be tested manually for both-eye clarity and compared at matching
  refresh/thermal conditions before any default-setting decision.

## Host-only regression suite

Run:

```powershell
pwsh -NoProfile -File scripts/test-quest-v71-rc8-render-scale-ab-host.ps1
```

The suite uses a fake ADB and fake apksigner only. It covers the default
read-only path, explicit authorization, running/race rejection, every RC8
identity component, exact one-field patching, atomic Arm/Restore, backup
tampering, config drift, staged corruption, mode-correction failure, move
failure, late staged corruption, post-move mode loss, and emergency
recovery. It executes a copied gate inside a unique temporary repository, so
it cannot delete or alter a real transaction receipt. The copied gate receives
a unique, non-runtime-overridable test mutex namespace so parallel Host suites
do not block a production gate or one another. It also covers
cross-process exclusion for simultaneous Status/Arm/Restore and deterministic
recovery after a mutex owner is killed. It records `RealAdbInvocations = 0`.
The pull and push transfer tests include realistic stdout, stderr, and
carriage-return progress, silent success, nonzero exit, missing/wrong local
bytes, malformed text, and oversized chatter. Re-arm from `RESTORED` is also
covered without deleting or rewriting the original backup.
