# RC8 aggregate-memory collector safety contract

`quest-v71-memory-aggregate-rc8.ps1` is a supplementary, read-only diagnostic
for the exact RC8 Lab build. It cannot accept evidence from Stable or another
Lab candidate.

## Fixed identity

- Lab package: `com.qcxr.qcxr.canary262`
- forbidden Stable package: `com.qcxr.qcxr.dev262`
- version: `71 / 6.0.1-26.2-vivecraft-personal.12-rc.8`
- APK SHA-256: `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416`
- signer SHA-256: `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`
- Core SHA-256: `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`
- VEQ SHA-256: `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`
- normalized-LF build-lock SHA-256:
  `BB5147F0B5B0A3AB5C61D7012A821F0C2583BDE76F96F963C19EDDD967177EF7`

The installed signer is transitively bound by the exact APK digest, while the
expected signer is independently pinned in the build lock. The collector
fails before sampling if the installed APK, Core, VEQ, package, or version
does not match.

## Host-only modes

The default `SelfTest` and explicit `Status` actions resolve no ADB executable,
make zero device calls, and create no output:

```powershell
.\scripts\quest-v71-memory-aggregate-rc8.ps1
.\scripts\quest-v71-memory-aggregate-rc8.ps1 -Action Status
```

## Explicit read-only capture

Capture requires all three consent gates. The output must be a new child under
`artifacts/memory`:

```powershell
.\scripts\quest-v71-memory-aggregate-rc8.ps1 `
  -Action Capture `
  -AllowDeviceRead `
  -ConfirmExactRc8Lab `
  -AllowHostOutput `
  -Serial 'PASTE_USB_SERIAL_HERE' `
  -AdbPath 'C:\path\to\adb.exe' `
  -OutputDirectory 'artifacts/memory/PASTE_NEW_RC8_RUN_DIRECTORY_HERE'
```

The 10-to-15-minute capture uses only read queries. It does not install,
launch, stop, clear, root, arm, or write to a device. It never queries the
Stable package. It samples:

- `dumpsys meminfo -a --local <pid>` for allowlisted aggregate categories;
- `/proc/meminfo` for four system totals;
- `/proc/<pid>/smaps_rollup` when Android exposes it to shell.

`smaps_rollup` is already aggregate-only and contains no individual mapping
names. It is optional: permission denial records `available=false` and does
not request root or fail the otherwise valid capture.

Raw `smaps`, `maps`, `latest.log`, logcat, JFR, paths, device identifiers,
account names, world names, and server addresses are never persisted. Raw
command responses exist only in process memory until strict parsing finishes.
The only temporary Host file contains sanitized JSON and is removed on failure.

JFR is deliberately not armed by this collector. RC8 would need a device-side
marker write before launch, which violates this tool's read-only scope. The
existing Host JFR summarizer remains useful only for a separately authorized,
already-created recording.

## Validation

Run the Host regression suite:

```powershell
.\scripts\test-quest-v71-memory-aggregate-rc8-host.ps1
```

It uses a temporary Fake-ADB executable and verifies fail-closed rejection of
wrong version, APK, Core, and VEQ identities. It also proves the default and
Status modes make zero ADB calls, no Stable package is queried, no prohibited
device mutation command is emitted, and no raw log/map/JFR read is attempted.

This tool and its tests have not been run against a real device by the Host-only
author. A successful Host test is not runtime, memory-leak, performance, or
Stable-promotion evidence.
