# RC8 OpenXR-input performance A/B runbook

This is a supervised Lab-only campaign. It measures one code difference: the
integrated RC8 Vivecraft Core (A) versus the reviewed OpenXR-input allocation
Core (B). It never authorizes Stable promotion.

## Fixed contract

- Lab: `com.qcxr.qcxr.canary262`; Stable deny target:
  `com.qcxr.qcxr.dev262`
- RC8 APK SHA-256:
  `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416`
- A Core SHA-256:
  `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`
- B Core SHA-256:
  `9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD`
- VEQ SHA-256 in every arm:
  `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`
- Fixed world master SHA-256:
  `9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90`
- `renderScaleFactor=1.0`; OpenXR copy batching `OFF`; QGO Dynamic
- exact order: `A1 B1 B2 A2 A3 B3`
- one fresh Lab launch per arm; five-minute warm-up; 180-second aggregate
- one actual VrApi CPU/GPU level pair across all arms. With user QGO CPU/GPU
  settings 4/4 this has historically appeared as VrApi levels 8/7; use the
  values actually observed, but never mix them within a campaign.

Every capture is SHA-chained to the previous capture and to one fresh reset
receipt. The reset receipt binds the reset producer, internal reset GUID,
fixed-world activation receipt, immutable original-world snapshot contract,
device, and completion time. All six receipts bind one other-mod fingerprint.
Each B also binds a distinct consumed v9 canary run ID. Analysis rejects gaps,
branches, reordered timestamps, reused process tokens, or relaxed thresholds.

## Host-only gates

These commands do not resolve or invoke ADB:

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-performance-ab.ps1
pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-performance-ab.ps1 -Action Status
pwsh -NoProfile -File .\scripts\quest-v71-rc8-benchmark-world-reset.ps1 -Action SelfTest
pwsh -NoProfile -File .\scripts\test-quest-v71-rc8-benchmark-world-reset-host.ps1
pwsh -NoProfile -File .\scripts\test-quest-v71-rc8-input-performance-ab-host.ps1
```

The Host suites use fake ADB only. Do not continue if any gate fails.

## Execute each arm

Create one empty campaign directory under
`artifacts/v71-rc8-input-performance-ab/`. For index `NN`, use the matching
condition from `A1 B1 B2 A2 A3 B3`; never rename or replace a receipt.

1. Stop Lab normally and confirm Stable is stopped. The tools never stop,
   launch, install, clear, or modify Stable. Before every arm, persistent state
   must be exact A with no v9 marker. After a B, perform the rollback in step 6
   before starting the next arm.

2. With both apps stopped, reset the fixed world. This creates the mandatory
   `reset-NN.json`. Normal access is attempted first; add
   `-AllowRootFallback` only when the fixed root path is intentionally allowed.

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-benchmark-world-reset.ps1 `
     -Action Reset -Serial <USB-SERIAL> -AdbPath <ADB.EXE> `
     -OutputJson artifacts/v71-rc8-input-performance-ab/run-001/reset-NN.json `
     -AllowDeviceRead -AllowDeviceWrite -ConfirmExactRc8Lab -AllowHostOutput
   ```

   The reset refuses candidate Core state, a remaining canary marker, a running
   Lab/Stable process, an unproven USB transport, or a changed snapshot/master.

3. For A, leave exact A untouched. For B only, deploy the candidate after the
   reset and before launch. Deploy begins from exact A, stages outside `mods`,
   commits the one-shot marker last, and proves the USB transport. Add
   `-AllowRootFallback` only if intentionally authorized.

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-canary.ps1 `
     -Action Deploy -Serial <USB-SERIAL> -AdbPath <ADB.EXE> -AllowDeviceWrite `
     -OpenXrCopyBatchMode OFF `
     -JarPath <EXACT-B-CANDIDATE-JAR> `
     -ExpectedSha256 9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD
   ```

4. Launch Lab exactly once into `FPS-Stress-Test`. Do not relaunch an armed or
   failed B transaction. Keep Lab focused and Stable stopped. Wait at least
   five minutes after that process starts. Confirm QGO remains Dynamic, scale
   remains 1.0, copy batching remains OFF, and thermal conditions are suitable.

5. Capture exactly 180 seconds. The command is read-only on Quest and retains
   aggregate JSON only. It checks the same PID/start ticks at both fences,
   focus and Stable on every timed poll, actual refresh strata, temperature
   coverage, and the declared VrApi levels.

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-performance-ab.ps1 `
     -Action Capture -SequenceIndex NN -Condition <A-OR-B> `
     -DeclaredRenderScale 1.0 -Seconds 180 `
     -ExpectedCpuLevel 8 -ExpectedGpuLevel 7 `
     -OutputDirectory artifacts/v71-rc8-input-performance-ab/run-001 `
     -Serial <USB-SERIAL> -AdbPath <ADB.EXE> `
     -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic -AllowHostOutput
   ```

6. Stop Lab normally. After every B—including B1 before B2—immediately restore
   exact A/no marker:

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-canary.ps1 `
     -Action Rollback -Serial <USB-SERIAL> -AdbPath <ADB.EXE> -AllowDeviceWrite
   ```

   The next reset proves that rollback for B1/B2 because it refuses anything
   except exact A/no marker. After B3 rollback, create the final read-only
   rollback receipt while both apps remain stopped:

   ```powershell
   pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-performance-ab.ps1 `
     -Action Finalize `
     -OutputDirectory artifacts/v71-rc8-input-performance-ab/run-001 `
     -Serial <USB-SERIAL> -AdbPath <ADB.EXE> `
     -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput
   ```

Any failure invalidates that arm. Do not overwrite evidence, skip an index,
reuse a launch, auto-promote, or continue from uncertain device state.

## Analyze all six

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-input-performance-ab.ps1 `
  -Action Analyze `
  -InputDirectory artifacts/v71-rc8-input-performance-ab/run-001 `
  -OutputJson artifacts/v71-rc8-input-performance-ab/run-001/analysis.json `
  -AllowHostOutput
```

All three pairs must be comparable using only common observed refresh-rate
strata: at least 24 overlap samples, at least 50% overlap in both arms, start
temperature delta at most 1.0 C, matched delta at most 1.5 C, complete thermal
coverage, identical declared VrApi levels, and valid focus/PID/Stable gates.

`PERFORMANCE_CANDIDATE` requires either at least two positive P95 pairs and a
combined P95 improvement of at least 2%, or at least two positive stale-rate
pairs and a combined stale improvement of at least 2%. Mean FPS and P10 must
both be no worse than -1%. Decisions use unrounded values. Missing evidence is
`INCONCLUSIVE`; complete evidence below threshold is `REJECT`. Every output
sets `stablePromotionAllowed=false`; manual input, stereo, and interaction-
profile review remains a separate requirement.

No receipt contains raw logcat, raw process rows, account/world contents,
network addresses, or the device serial. Root use and access mode are recorded.
