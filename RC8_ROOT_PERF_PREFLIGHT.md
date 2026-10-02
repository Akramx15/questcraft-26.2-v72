# RC8 root-assisted performance preflight

## Scope and verdict

This is a Host-only audit. No ADB command was issued and no application,
profile, device, or Stable state was changed.

Root is useful for read-only access to tracing event discovery and a small
allowlist of KGSL counters. It is not required for the current right-trigger
mining diagnosis, the existing VrApi aggregate capture, or the exact-RC8
aggregate memory collector. Root must not be used for clock, governor,
performance-hint, driver, Magisk, or property changes.

The current exact Lab identity is:

- package: `com.qcxr.qcxr.canary262`
- forbidden Stable package: `com.qcxr.qcxr.dev262`
- version: `71 / 6.0.1-26.2-vivecraft-personal.12-rc.8`
- APK SHA-256: `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416`
- Core SHA-256: `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`
- VEQ SHA-256: `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`
- signer SHA-256: `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`

Do not begin performance work until the manual R2 result is known. If R2 does
not break normally, run the transition-only mining diagnostic first. A tracing
or render-scale result must not hide an input regression.

## Existing tools

### Safe and current

`scripts/quest-v71-memory-aggregate-rc8.ps1` is correctly locked to exact RC8.
Its SelfTest and Fake-ADB suite pass with zero real ADB calls. Capture is
read-only and persists only numeric aggregates from:

- `dumpsys meminfo -a --local <pid>`;
- `/proc/meminfo`;
- optional `/proc/<pid>/smaps_rollup`.

It does not query Stable, request root, read logs/maps, invoke target-process
callbacks, or write to the device. Its exact future command is:

```powershell
$AdbPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& '.\scripts\quest-v71-memory-aggregate-rc8.ps1' `
  -Action Capture `
  -AllowDeviceRead `
  -ConfirmExactRc8Lab `
  -AllowHostOutput `
  -DurationMinutes 12 `
  -IntervalSeconds 60 `
  -Serial 'QUEST_IP_ADDRESS:5555' `
  -AdbPath $AdbPath `
  -OutputDirectory 'artifacts/memory/rc8-<new-unique-run-name>'
```

`scripts/quest-vrapi-pid-benchmark.ps1` also passed its Host SelfTest. It keeps
the PID-scoped `VrApi` rows in memory, discards them before constructing the
report, and persists aggregates only. It defaults to Stable, however, so an
RC8 invocation must explicitly specify Lab:

```powershell
$AdbPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
& '.\scripts\quest-vrapi-pid-benchmark.ps1' `
  -Package 'com.qcxr.qcxr.canary262' `
  -DynamicRefresh `
  -Seconds 60 `
  -Serial 'QUEST_IP_ADDRESS:5555' `
  -AdbPath $AdbPath `
  -OutputJson 'artifacts/benchmarks/rc8-<new-unique-run-name>.json'
```

This helper is suitable for one-variable A/B acceptance, but it lacks an
exact-RC8 identity gate. Prefer wrapping it with the RC8 lock before a campaign;
never rely on its default package value.

### Do not run unchanged on RC8

`scripts/quest-v69-perfetto-hotspots.ps1` is locked to obsolete v68 Core SHA
`3638F258...D842F`. Its fail-closed identity check would reject exact RC8.
Create an RC8-specific copy or wrapper rather than weakening that historical
lock.

The historical steady-state trace proves that this Quest kernel exposed these
useful events:

```text
gpu_mem/gpu_mem_total
kgsl/adreno_cmdbatch_submitted
kgsl/adreno_cmdbatch_retired
kgsl/kgsl_buslevel
kgsl/kgsl_clk
kgsl/kgsl_gpubusy
kgsl/kgsl_pwrlevel
power/cpu_frequency
power/cpu_idle
sched/sched_switch
sched/sched_waking
sched/sched_wakeup
```

But it also recorded `ftrace_setup_errors=4` and
`perf_samples_skipped=2870`. All sampled native leaf frames were unknown.
Therefore the first RC8 trace must omit `-IncludeCallstacks`; root availability
does not turn those old samples into useful symbols. Trace health must report
`ftrace_setup_errors`, `ftrace_dropped_events`, `perf_samples_skipped`, and
data-loss stats explicitly.

The historical GPU-memory SQL also mixed system and unrelated PID tracks. For
RC8, pivot the `gpu_mem_total` arguments and retain only `pid=<captured Lab
pid>`. The old trace measured approximately `816.8 MiB` mean and `842.0 MiB`
maximum for its app PID, while the aggregate report did not label that PID
clearly. External process names and PIDs should not be persisted.

## Minimal root read contract

Run these only after exact RC8, focus, PID/start-time, and stopped-Stable gates
pass. The commands are presented for a future guarded script; this audit did
not execute them.

Root capability:

```text
su -c 'id -u'
```

Accept exactly one line containing `0`. Do not record the endpoint or any
other `id` fields.

Discover tracing events from a fixed file and fixed allowlist only:

```text
cat /sys/kernel/tracing/available_events
```

If shell cannot read it, use the same literal command through `su -c`. Parse
in memory and retain only booleans for the allowlisted event names above. Do
not persist the full event list.

Probe only these fixed KGSL files; do not use `find`, recursive `ls`, or a
device-derived path:

```text
/sys/class/kgsl/kgsl-3d0/gpubusy
/sys/class/kgsl/kgsl-3d0/devfreq/cur_freq
/sys/class/kgsl/kgsl-3d0/gpuclk
/sys/class/kgsl/kgsl-3d0/pwrlevel
/sys/class/kgsl/kgsl-3d0/num_pwrlevels
```

For every file, use `[ -r <literal-path> ]` followed by `cat`; retain only
availability and strictly parsed non-negative numeric values. Prefer
`devfreq/cur_freq`, with `gpuclk` as a fallback. Treat `gpubusy` as a pair
`busy total` only when both are integers and `0 <= busy <= total`, then report
`100 * busy / total`. Treat `pwrlevel` as an opaque ordinal unless
`num_pwrlevels` is also valid; a lower ordinal commonly means a higher level
but that must not be assumed in an acceptance decision.

Thermal reads need no root:

```text
dumpsys battery
dumpsys thermalservice
```

Parse in memory and retain only `temperature` divided by ten, battery status,
and the single `Thermal Status` integer. Do not persist raw dumps. VrApi `Temp`
remains the comparable path-temperature field for A/B.

The root telemetry should run as a separate diagnostic at no more than 1 Hz.
Do not poll sysfs over a new ADB round-trip every frame, and do not combine its
overhead with an acceptance-quality VrApi sample unless the identical sampler
is active in both A and B.

## Minimal privacy-scoped Perfetto capture

Perfetto necessarily creates an ephemeral config and trace under
`/data/local/tmp`; that is device I/O, not a literally read-only filesystem
operation. It is acceptable only with a separate explicit ephemeral-I/O gate,
randomized fixed-prefix paths, a `finally` cleanup, and no app/profile writes.

The first RC8 configuration should contain only:

- a 64 MiB ring buffer;
- 30-second duration and five-second flush;
- scheduler wake/switch events;
- CPU frequency/idle;
- the supported KGSL command, power, clock, busy, and GPU-memory events;
- process stats needed to associate threads to the already captured Lab PID;
- no `linux.perf` callstacks initially.

Exclude `android.log`, Android package lists, Binder payloads, raw syscalls,
network events, file-I/O events, heapprofd, and broad atrace categories. Avoid
`atrace_apps` until a code trace section is specifically needed. Delete the raw
trace after aggregate SQL unless a separate `KeepTrace` decision is made.

Persist only these fields:

- exact-identity booleans, duration, sample coverage, PID/start/focus gates;
- app total CPU and per-thread CPU share;
- per-thread runnable wait total, P95, maximum, and counts above 1/2/4 ms;
- CPU-frequency distribution by CPU;
- app-PID-only GPU-memory mean/P95/max;
- KGSL submitted/retired counts and unmatched-count delta, without interpreting
  undocumented GPU timestamp units;
- trace health counters described above;
- no external process names, serial, account text, world name, server address,
  raw trace rows, or raw log text.

Perfetto is diagnostic-only. Promotion still requires a fresh counterbalanced
VrApi A/B with matched actual refresh and temperature.

## Safe order after the mining result

1. Re-establish ADB after the root reboot and verify exact RC8 read-only.
2. Obtain the manual R2 result. Diagnose mining first on failure.
3. If mining passes, record a 60-second VrApi baseline without root telemetry.
4. Run one 30-second RC8 Perfetto diagnostic without callstacks; inspect trace
   health before using scheduler/KGSL findings.
5. Run the 12-minute exact-RC8 aggregate-memory collector if memory attribution
   is still needed.
6. Only then run the already prepared `renderScaleFactor 1.0 -> 0.8` Lab A/B.
7. Stable remains untouched throughout.

Never issue `setprop`, `resetprop`, `settings put`, `cmd power`, `chmod`,
`chown`, `mount`, governor/clock writes, `echo >`, `tee`, `kill`, `am
force-stop`, package installation/removal, or Magisk module changes from the
root measurement path.
