# RC8 dynamic-refresh performance A/B safety contract

`quest-v71-rc8-performance-ab.ps1` is an aggregate-only measurement and
analysis gate for the exact RC8 Lab build. Its default `SelfTest` and `Status`
actions are Host-only and do not resolve ADB.

## Fixed identity and boundary

- Lab package: `com.qcxr.qcxr.canary262`
- Stable package (read only for stopped-state proof):
  `com.qcxr.qcxr.dev262`
- Version: `71` / `6.0.1-26.2-vivecraft-personal.12-rc.8`
- APK SHA-256:
  `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416`
- Signer SHA-256, bound through the exact audited APK digest:
  `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`
- Core SHA-256:
  `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`
- VEQ SHA-256:
  `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`
- Conditions: A is `renderScaleFactor=1.0`; B is `0.8`.
- Capture order: `A1 -> B1 -> B2 -> A2 -> A3 -> B3` (`AB/BA/AB`).
- CPU/GPU performance levels are explicit capture declarations. They default
  to `4/4`, but a rooted QGO profile that reports a different stable pair may
  be measured with `-ExpectedCpuLevel` and `-ExpectedGpuLevel`. At least 95%
  of every receipt must report that exact pair, and all six receipts must use
  the same pair; the analyzer rejects mixed profiles.

Capture reads package identity, installed APK/Core/VEQ hashes, the fixed
render-scale field, foreground/PID state, the Stable PID absence, aggregate
process counts, and PID-scoped VrApi rows. It never installs, launches,
force-stops, roots, reboots, clears, uninstalls, pushes, pulls, or changes any
Android file. Stable is only queried with `pidof` and must already be stopped.

The separate render-scale transaction tool is responsible for switching and
restoring the config while Lab is stopped. This measurement tool cannot make
that change. The user/orchestrator must launch Lab and place the player in the
same benchmark scene before each capture.

## Aggregate capture

Capture requires all three explicit switches and a new/partially populated
child directory under `artifacts/v71-rc8-performance-ab/`:

```powershell
pwsh -NoProfile -File scripts/quest-v71-rc8-performance-ab.ps1 `
  -Action Capture -SequenceIndex 1 -Condition A `
  -DeclaredRenderScale 1.0 -Seconds 60 `
  -ExpectedCpuLevel 4 -ExpectedGpuLevel 4 `
  -OutputDirectory artifacts/v71-rc8-performance-ab/run-001 `
  -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput `
  -Serial 'PASTE_USB_SERIAL_HERE' -AdbPath 'C:\path\to\adb.exe'
```

The underlying `quest-vrapi-pid-benchmark.ps1` is invoked with the exact Lab
package and `-DynamicRefresh`. Raw logcat/process rows stay in memory and are
discarded. The receipt contains only aggregate metrics, including aggregate
performance metrics stratified by the *observed* display refresh rate.

## Matched-refresh analysis

After all six captures:

```powershell
pwsh -NoProfile -File scripts/quest-v71-rc8-performance-ab.ps1 `
  -Action Analyze `
  -InputDirectory artifacts/v71-rc8-performance-ab/run-001
```

Each AB/BA/AB pair is normalized to A=1.0 and B=0.8 and only common actual
refresh strata contribute. A stratum needs at least three observations in
each arm. By default each pair needs 24 overlapping observations and at least
50% overlap in both arms. Starting temperature must differ by no more than
1.0 C, and overlap-weighted temperature by no more than 1.5 C. A dynamic QGO
run which hunts rates but has enough common 72/80/90/etc. observations remains
comparable; disjoint or thin distributions are `INCONCLUSIVE` rather than
being averaged together.

The performance result is still not a Stable decision. A `PERFORMANCE_CANDIDATE`
requires at least two positive P95 pairs, a combined matched-strata P95 gain of
at least 2%, and no mean/P10 FPS loss over 1%. Stereo clarity and image quality
remain manual gates, and every report fixes `stablePromotionAllowed=false`.

## Host-only regression

```powershell
pwsh -NoProfile -File scripts/test-quest-v71-rc8-performance-ab-host.ps1
```

The suite runs the default SelfTest, the underlying parser SelfTest, and an
end-to-end aggregate capture through an explicit fake ADB. It also rejects a
running Stable package, wrong version/APK/Core/VEQ identity, and a mislabeled
render scale; scans every fake call for device-write/root/package-management
commands; and reports `RealAdbInvocations=0`.
