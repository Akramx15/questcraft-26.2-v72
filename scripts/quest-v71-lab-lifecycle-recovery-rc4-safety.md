# v71 RC4 Lab lifecycle/recovery safety contract

`quest-v71-lab-lifecycle-recovery-rc4.ps1` is the only lifecycle producer for
the exact RC4 Lab candidate. It is separate from the RC3 producer and receipt;
RC3 evidence is historical diagnostic evidence and cannot satisfy this gate.

## Fixed scope

- Lab package: `com.qcxr.qcxr.canary262`
- forbidden Stable package: `com.qcxr.qcxr.dev262`
- profile: `26.2`
- version: `71` / `6.0.1-26.2-vivecraft-personal.12-rc.4`
- Core: `289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189`
- frozen VEQ: `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`
- receipt: `artifacts/acceptance/v71-lab-rc4-lifecycle-recovery-receipt.json`

The APK hash, size, and audit flag come only from `V71_LAB_RC4.lock.json`.
While those values are pending, `Run` fails before resolving ADB. `SelfTest`
and `Plan` are Host-only and perform zero device calls.

## Authorized behavior

`Run` requires every explicit read/write/launch/force-stop authorization switch.
It may stop and start only the Lab package, run the fixed autoplay helper, and
verify cold start, recovery after a live OpenXR stop, and recovery after the
testable pre-JVM launcher interruption. It never installs an APK, clears data,
uses root, synthesizes controller input, or targets Stable.

The final state must be a stopped Lab process with the installed APK and
Core/VEQ pair unchanged. The receipt is strict UTF-8, atomic, write-once, and
contains no raw logs, account data, server address, world path, or device
serial.

## Explicit limitation

The Unity launcher and embedded JVM share one Android PID. The frozen RC4 Core
has no post-initialization acknowledgement, so the narrow
`gameReady`-to-OpenXR-init interruption window cannot be proven safely. The
receipt states this limitation and does not imply manual eye/controller,
performance, or memory-soak acceptance.

## Host checks

```powershell
pwsh -NoProfile -File scripts/quest-v71-lab-lifecycle-recovery-rc4.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-v71-lab-lifecycle-recovery-rc4-host.ps1
```

These commands must succeed while an intentionally nonexistent ADB path remains
untouched.
