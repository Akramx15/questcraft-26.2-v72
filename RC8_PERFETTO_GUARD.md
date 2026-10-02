# Exact-RC8 Perfetto guard

`scripts/quest-v71-rc8-perfetto-guard.ps1` is a narrow diagnostic for the
already-running RC8 Lab application. It is not an installer, launcher,
benchmark acceptance gate, or general-purpose device shell.

## Fixed identity

The script reads `V71_LAB_RC8.lock.json` and also checks its normalized SHA-256
before any device access. The following values are not command-line options:

- Lab package: `com.qcxr.qcxr.canary262`
- forbidden Stable package: `com.qcxr.qcxr.dev262`
- profile: `26.2`
- version: `71` / `6.0.1-26.2-vivecraft-personal.12-rc.8`
- APK: `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416`
- Core: `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`
- VEQ: `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`

Capture refuses to proceed unless Stable is stopped, the exact Lab PID and
`/proc/<pid>/stat` start time stay unchanged, exactly one `QuestCraft-JVM`
thread exists, and the installed version plus APK/Core/VEQ hashes match before
and after capture. Focus is proven against the exact immersive component
`com.qcxr.qcxr.canary262/pojlib.UnityPlayerActivity`: the one global
`mCurrentFocus`, the one global `mFocusedApp`, and exactly one display-level
`ResumedActivity` must all agree. In this contract, “one global” means exactly
one non-null, structurally valid component-bearing row; Quest may emit any
number of additional exact `mCurrentFocus=null` and `mFocusedApp=null` rows for
unfocused displays. A malformed null/non-null row is not ignored. Quest may
also expose additional task-local `topResumedActivity` rows for ControlBar,
SystemUI, or toasts on
other displays; those rows are not treated as global focus evidence. Missing,
duplicated, prefix-lookalike, launcher, Stable, or otherwise disagreeing focus
evidence is rejected.

Capture also requires an explicit, non-network ADB serial and exactly one
authorized row for it in `adb devices -l`. An unambiguous `usb:*` result from
`adb get-devpath` remains the primary transport proof. Some Windows ADB builds
return exactly `unknown` for a physical USB endpoint; only on Windows that one
result may use a fail-closed fallback requiring all of the following:

- `getprop ro.serialno` exactly matches the requested ADB serial;
- one present, `OK` PnP device whose name ends in `ADB Interface`;
- its `DEVPKEY_Device_Parent` points to one present, `OK` composite parent
  whose exact instance id is `USB\VID_2833&PID_5013\<serial>`.

Missing, stale, ambiguous, unhealthy, differently parented, or differently
identified PnP devices are rejected. `auto`, colon-shaped TCP/Wi-Fi serials,
`.local` names, and ADB mDNS service names are rejected before ADB is resolved.
The serial and PnP identifiers are never retained in the aggregate.

## Capabilities and mutations

The default `SelfTest` and `Plan` actions are Host-only and never resolve ADB.
Capture requires three independent, explicit switches:

- `-AllowDeviceRead`: fixed identity, PID, process-start, JVM, and focus reads.
- `-AllowEphemeralDeviceIo`: one randomized config and trace under
  `/data/local/tmp`, one pull, and bounded non-root deletion.
- `-AllowRootRead`: only the fixed `/debug_ramdisk/su` binary running
  shell-quoted `id -u` and a read of
  `/sys/kernel/tracing/available_events`.

The root command operand is encoded as a POSIX shell literal because `adb
shell` rebuilds a remote command line; this avoids the ambiguous bare
space-containing `su -c` argument used by the obsolete helper. No command
installs, launches, stops, kills, clears, configures, or writes to
Lab or Stable. Root is never used to write or tune the device. The application
must already be in the intended scene before capture.

## Capture scope

The fixed 30-second Perfetto config records only:

- scheduler switch/waking/wakeup;
- CPU frequency and idle;
- process/thread counters;
- `gpu_mem_total` and the available KGSL command-batch submit/retire events.

Four discoverable vendor-transition tracepoints are deliberately excluded from
the capture config: `kgsl_buslevel`, `kgsl_clk`, `kgsl_gpubusy`, and
`kgsl_pwrlevel`. The exact RC8 capture and an earlier Quest capture each
requested all four, each reported exactly four ftrace setup errors, and neither
emitted any of those four event types. Submit/retire events worked in both
captures. This is strong correlation, not per-event proof: an entry in
`available_events` proves only that tracefs lists the name, not that Perfetto can
enable it or that it must emit in a 30-second window. The guard therefore keeps
the four names in its bounded availability report but marks them false in the
separate capture-selection map. It does not label them unsupported.

It does not enable callstacks, `linux.perf`, logcat, networking, file I/O,
Binder payloads, raw syscalls, app atrace categories, package lists, or
heapprofd. The process-stats source may transiently contain system process
metadata in the raw trace; only exact-Lab-PID aggregates leave the private
temporary directory.

The retained JSON contains exact-PID scheduling, process counters, exact-PID
`gpu_mem_total`, device-global CPU frequency/idle and KGSL submit/retire totals,
fixed identity hashes, trace-health counters, and two fixed-name maps that
separate tracefs availability from actual capture selection. Thread names are
converted to a small fixed category set; unknown names become
`OtherAppThread`. No serial, PnP instance id, package name, temporary path, raw
trace hash, external PID/name, account, world, server, or network value is
retained.

Known engine/runtime names are normalized to purpose labels rather than copied
to the report:

| Input family | Retained category |
| --- | --- |
| G1 concurrent workers and the existing JVM daemon families | `GarbageCollector` |
| Sodium async chunk work (including the Linux-truncated name) | `SodiumAsyncWorker` |
| Unity choreographer, including the Linux-truncated name | `UnityFramePacer` |
| Unity runtime main | `UnityRuntimeMain` |
| FMOD streaming and mixing workers | `FmodStreamAudio` / `FmodMixerAudio` |
| OpenAL Soft mixer | `OpenAlMixerAudio` |

The generic Java name `Thread-13` deliberately remains `OtherAppThread`.
Thread numbers can change across launches, and the retained aggregate has no
second, privacy-safe identity signal that proves its role. A dominant unknown
row must therefore stay unknown rather than being labeled as the render thread.

## Raw trace lifetime

Device filenames use one unpredictable 128-bit run id. Both are checked absent
before use and deleted in `finally`, with a second bounded regular-shell retry
and absence/symlink checks. Host config, SQL, and trace files live in one
randomized system-temp directory. Host deletion is attempted twice and absence
of the directory is proven before any aggregate may be published. The outer
`finally` retries on earlier failures. There is deliberately no `KeepTrace`
option. If Host or device deletion cannot be proven, the command fails and
publishes no aggregate; manual inspection would then be required before another
capture.

## Usage

Host-only checks:

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-perfetto-guard.ps1 -Action SelfTest
pwsh -NoProfile -File .\scripts\test-quest-v71-rc8-perfetto-guard-host.ps1
```

After a human has independently stopped Stable, started exact RC8 Lab, entered
the intended scene, and kept Lab focused, the deliberate capture shape is:

```powershell
pwsh -NoProfile -File .\scripts\quest-v71-rc8-perfetto-guard.ps1 `
  -Action Capture -Seconds 30 -Serial 'PASTE_USB_SERIAL_HERE' `
  -AdbPath 'C:\path\to\adb.exe' `
  -TraceProcessorPath 'C:\path\to\trace_processor_shell.exe' `
  -AllowDeviceRead -AllowEphemeralDeviceIo -AllowRootRead
```

Only `artifacts/perfetto/rc8/capture-*/aggregate.json` remains. The directory is
ignored by Git.

## Interpretation and limits

- This trace is diagnostic overhead, never FPS or release-acceptance evidence.
- `gpu_mem_total` is exact-PID scoped. CPU frequency/idle and KGSL totals are
  device-global aggregates and must not be attributed to the app alone.
- `power/cpu_frequency` is transition-driven. An empty CPU-frequency table can
  simply mean that no transition occurred while clocks were fixed; it does not
  prove event or kernel non-support.
- The signer is transitively bound by the exact whole-APK digest and the locked
  signer record; the guard does not export or persist the installed certificate.
- A nonzero ftrace setup-error, dropped-event, data-loss, or buffer-overrun
  count marks scheduler conclusions unusable in the retained report. Perfetto
  v58.2 per-CPU dropped-event, commit-overrun and overrun deltas are included.
- Summed runnable wait is reported in one-core equivalents. It can exceed 100%
  when several app threads are runnable; it is not a wall-time percentage.
- SQL was Host-validated with the pinned Perfetto v58.2 trace processor and a
  historical Quest trace. A supervised exact-RC8 capture is still required to
  validate current-device event availability.
- Performance acceptance still requires the separate, counterbalanced,
  matched-refresh VrApi A/B procedure.

### Current exact-RC8 aggregate

The already-purged exact-RC8 capture cannot be retroactively recategorized.
Its largest row remains `OtherAppThread` at `65.524%` of one core with
`366.483 ms` of summed runnable wait. The next two unknown rows are also left
unidentified; prior observations are not enough to bind their identities in
this capture. The fixed categories that did survive show `ServerThread` at
`4.774%` of one core, `ChunkRender` at `0.161%`, and the four retained
`GarbageCollector` rows together at about `0.406%`.

The capture reports `97.319%` app CPU and `9.043%` summed runnable wait in
one-core equivalents, but its four ftrace setup errors make
`UsableForSchedulerConclusions=false`. Those figures are diagnostic context,
not a scheduler conclusion or evidence for accepting a performance change.
Future healthy captures will gain the additional fixed categories above; the
old aggregate remains immutable and privacy-safe.

For a concise Host-only category roll-up of any retained aggregate, without
accessing a device or raw trace:

```powershell
$report = Get-Content -Raw .\aggregate.json | ConvertFrom-Json -Depth 20
$report.AppScheduling.Threads |
  Group-Object Category |
  ForEach-Object {
    [pscustomobject]@{
      Category = $_.Name
      RankedThreads = $_.Count
      CpuMs = [math]::Round((($_.Group | Measure-Object CpuMs -Sum).Sum), 3)
      RunnableWaitMs = [math]::Round((($_.Group | Measure-Object RunnableWaitMs -Sum).Sum), 3)
    }
  } |
  Sort-Object CpuMs -Descending
```

This rolls up only the retained ranked rows (currently at most 64), not every
thread reported by `Coverage.AppThreadCount`.
