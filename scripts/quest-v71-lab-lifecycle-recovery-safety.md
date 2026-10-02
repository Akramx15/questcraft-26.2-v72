# v71 RC3 Lab lifecycle/recovery gate

`quest-v71-lab-lifecycle-recovery.ps1` is fixed to the exact integrated Lab
artifact and cannot target Stable:

- Lab: `com.qcxr.qcxr.canary262`
- forbidden Stable: `com.qcxr.qcxr.dev262`
- APK SHA-256: `B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F`
- Core SHA-256: `14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26`
- VEQ SHA-256: `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`

`SelfTest` and `Plan` are Host-only and issue zero ADB commands. `Run` requires
six independent switches, rejects any active Stable PID, and refuses to begin
while Lab is running. This last check is the guard against interrupting a
manual session or either 90-minute memory soak.

The sequence's mutating operations use ActivityManager only; its other device
operations are read-only identity, process, thread, log-metadata, and hash probes. It sends no key, touch,
controller, `monkey`, UI-automation, or random input. It proves:

1. a clean authenticated autoplay reaches exact RC3, the benchmark world,
   OpenXR `FOCUSED`, and submitted frame 120;
2. a complete-process stop after that live OpenXR state can recover to the
   same evidence;
3. a plain component start remains launcher-only (`UnityMain` present,
   `QuestCraft-JVM` absent, Minecraft log unchanged), can be interrupted, and
   can recover through authenticated autoplay;
4. the exact Core/VEQ pair remains unchanged and the final Lab state is stopped.

The gate never installs/uninstalls, clears data, directly edits profile files,
or writes account/save files through ADB. Minecraft can perform ordinary runtime saves
while its fixed test world is active. Raw logcat and `latest.log` contents are
never persisted. After final cleanup and an exact installed-APK/Core/VEQ
recheck, a successful `Run` atomically publishes one write-once JSON receipt at
`artifacts/acceptance/v71-lab-lifecycle-recovery-receipt.json`. The receipt is
limited to timestamps, exact public artifact identities, producer lineage and
hashes, and boolean phase/final-state proofs. It excludes the device serial,
PIDs, raw logs, log excerpts, absolute host paths, account data, and save data.

## Deliberate evidence boundary

Frozen RC3 has no post-OpenXR-initialization acknowledgement, and Unity plus the
embedded JVM live in one Android PID. Therefore it is not safe or technically
possible to kill only the launcher after JVM handoff, nor can this helper prove
the narrow interval between Unity `gameReady` and OpenXR initialization. It
does not claim that result. A true proof needs either a new Core/launcher ACK or
an instrumented build, which would change the frozen RC3 bytes and must be a
separate candidate.

## Commands

Host-only:

```powershell
.\scripts\quest-v71-lab-lifecycle-recovery.ps1 -Action SelfTest
.\scripts\quest-v71-lab-lifecycle-recovery.ps1 -Action Plan
.\scripts\test-quest-v71-lab-lifecycle-recovery-host.ps1
```

After both long soaks are finished, Lab is stopped, and no one is playing:

```powershell
.\scripts\quest-v71-lab-lifecycle-recovery.ps1 -Action Run `
  -Serial 'PASTE_USB_SERIAL_HERE' `
  -AdbPath 'C:\path\to\adb.exe' `
  -AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowLaunch `
  -AllowLauncherInterruption -ConfirmNoActiveSoakOrManualSession
```

Do not run this command during a memory soak. It intentionally leaves Lab
stopped, never touches Stable, and makes no manual-eye/controller, performance,
or memory-soak acceptance claim. On PASS, review the returned receipt SHA-256
and producer SHA-256 before deliberately locking both into
`V71_STABLE_ACCEPTANCE.lock.json`; `Run` never edits that acceptance lock.
