# RC8 OpenXR-input one-variable Lab A/B

## Fixed scope

This harness compares only the integrated RC8 Vivecraft core with the reviewed
OpenXR-input allocation candidate. It is permanently pinned to:

- Lab package `com.qcxr.qcxr.canary262`, profile `26.2`;
- versionCode `71`, versionName `6.0.1-26.2-vivecraft-personal.12-rc.8`;
- APK SHA-256 `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416`;
- baseline core `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`;
- VEQ `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`;
- candidate core `9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD`;
- Pojlib transaction namespace `questcraft-vivecraft-core-canary-v9`.

`com.qcxr.qcxr.dev262` is forbidden. The helper checks that Personal Stable is
stopped before either mutation. It has no install, uninstall, clear-data,
account, config, saves, options, Xaero, QGO, Magisk, property, affinity, or
governor path. Copy batching is fixed at `OFF`, so the candidate changes only
the reviewed input hot path.

## Host-only gates

These commands never resolve or invoke ADB:

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-canary.ps1 -Action Plan
pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-canary.ps1 -Action SelfTest
pwsh -NoProfile -File .\scripts\test-quest-v71-rc8-input-canary-host.ps1
pwsh -NoProfile -File .\scripts\test-quest-v71-rc8-input-canary-transactions.ps1
pwsh -NoProfile -File .\scripts\capture-verify-v71-rc8-input-runtime-log.ps1
```

## Supervised Quest sequence

Use the explicit USB serial, never `auto` or a `host:port` endpoint. The Lab
and Personal Stable apps must both be stopped before Deploy.

Both the transaction helper and bounded runtime-capture wrapper prove the same
USB transport before any device action. An exact `usb:*` value from
`adb -s <serial> get-devpath` is preferred. Because Windows ADB can return the
exact value `unknown` for a real Quest USB connection, that value alone is not
accepted: the tool also requires `ro.serialno` to equal the explicit serial,
one present/OK `USB\VID_2833&PID_5013\<serial>` PnP parent, and exactly one
present/OK USB ADB child whose `DEVPKEY_Device_Parent` equals that parent.
Every other devpath, network-shaped serial, duplicate authorized row, serial
mismatch or ambiguous/unhealthy PnP chain fails closed.

1. Record baseline status. Add `-AllowRootFallback` only if normal shell access
   cannot inspect the exact Lab profile. The mode is selected before mutation
   and is never retried at another privilege after a partial write.

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-canary.ps1 `
     -Action Status -Serial <USB-SERIAL> -AdbPath <ADB.EXE>
   ```

   Require exact APK/Core/VEQ hashes, `BaselineExact=True`, no marker, and save
   the reported other-mod fingerprint for both A and B.

2. Run baseline A with the existing RC8 APK and no canary marker. Use the fixed
   autoplay/world and the existing matched-refresh capture protocol. Stop Lab
   normally after the retained aggregate is complete.

3. Arm B. Deploy never launches the app. It stages the candidate outside
   `mods`, commits the v9 one-shot marker last, and returns one `RunId`.

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-canary.ps1 `
     -Action Deploy -Serial <USB-SERIAL> -AdbPath <ADB.EXE> -AllowDeviceWrite `
     -JarPath "<WORK>\agent-v71-rc8-openxr-input\Vivecraft-26.2-Quest\build\libs\vivecraft-26.2-1.3.15+qc.v71.rc8-input.1-fabric.jar" `
     -ExpectedSha256 9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD
   ```

4. Confirm Status is `armed`, with that exact RunId, baseline target, exact
   VEQ and the same other-mod fingerprint. Then perform exactly one autoplay
   launch; do not relaunch a failed B marker.

   ```powershell
   pwsh -NoProfile -File .\scripts\run-vivecraft-local-autoplay.ps1 `
     -Action ArmAndRun -Serial <USB-SERIAL> -AdbPath <ADB.EXE> -AllowLaunch `
     -LauncherCameraPark ON -LauncherResourceRelease ON
   ```

5. When OpenXR frames are visible, require Status `consumed`, target SHA equal
   to the candidate, the same RunId/fingerprint and a fresh Lab PID. Capture
   the bounded runtime proof. The capture binds `latest.log` to PID start ticks
   and inode, verifies exact candidate/VEQ/Vulkan/OpenXR markers, and deletes
   its temporary raw log in `finally`.

   ```powershell
   pwsh -NoProfile -File .\scripts\capture-verify-v71-rc8-input-runtime-log.ps1 `
     -Capture -Serial <USB-SERIAL> -AdbPath <ADB.EXE>
   ```

6. Perform manual input regression checks before interpreting performance:
   right trigger/Y, reverse hands, Wrist, both Grip menus, bow, haptics,
   tracking loss and an interaction-profile reconnect. This Host work does not
   claim those passed.

7. Stop Lab, then restore the exact RC8 baseline atomically:

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-canary.ps1 `
     -Action Rollback -Serial <USB-SERIAL> -AdbPath <ADB.EXE> -AllowDeviceWrite
   ```

   Final Status must report baseline SHA/size, exact VEQ, no marker and the same
   other-mod fingerprint. If any identity, marker, PID, fingerprint, freshness,
   or rollback check fails, reject B and do not promote Stable.

## Measurement boundary

Use the existing fixed benchmark world, warm-up and matched-refresh aggregator.
Compare `A1→B1→B2→A2→A3→B3`, discarding windows with PID/focus/refresh drift.
Accept only if the predeclared P95/stale improvement is reproduced without the
FPS/P10 guardrails failing. This harness supplies transaction and runtime
identity; it intentionally does not invent an FPS claim or promote Stable.

