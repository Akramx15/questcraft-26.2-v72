# RC8 OpenXR-input A/B Host QA

Date: 2026-09-08

## Result

`HOST_PASS / QUEST_NOT_RUN / STABLE_PROMOTION_FORBIDDEN`

Root review additionally closed two portability/race gaps before any Quest
deployment: every mutating shell now rechecks both Lab and Personal Stable at
entry and immediately before promotion, and explicit serial selection must be
proven as USB. `adb get-devpath` remains the primary proof. On Windows only,
the exact `unknown` result may fall back to an exact Android hardware serial
and one present/healthy `USB\VID_2833&PID_5013\<serial>` parent with exactly one
present/healthy ADB child whose PnP parent relation matches. A network-shaped
serial, missing/duplicate authorized row, mismatched hardware serial, unhealthy
device or ambiguous PnP relation fails closed. The runtime verifier is
authenticated with a strict UTF-8/LF canonical digest so Windows checkout line
endings cannot create a false drift failure.

The harness is a one-variable Lab transaction around the reviewed
`rc8-input.1` core. OpenXR copy batching is locked `OFF`; APK, baseline core,
VEQ, candidate metadata and candidate SHA-256 are exact. Other managed mods are
bound through the sorted filename+SHA-256 fingerprint written into the v9
one-shot marker.

## Tests

- PowerShell parse: 5 files passed.
- Host-only Plan: passed, 0 ADB calls.
- Low-level helper SelfTest: passed, 0 ADB calls.
- Identity/boundary/runtime fixtures: 43 passed, 0 real ADB calls.
- Fake Windows PnP snapshots: 20 cases passed across the deploy helper and
  runtime-capture wrapper (2 valid, 18 rejected), including unhealthy and
  duplicate parent/child relations.
- Fake PnP API integration: 6 calls passed across the two Windows fallback
  resolutions; no live PnP query occurred.
- Fake transport resolution: 8 cases passed across both tools, including
  direct `usb:` devpath, Windows `unknown` fallback, serial mismatch and
  duplicate-row rejection.
- Transaction shell: 5 injected deploy boundaries passed.
- Exact rollback: 1 passed.
- Other-mod fingerprint canonicalization: 1 passed.
- Bash syntax: 7 generated scripts passed.
- Runtime capture default Plan: passed, 0 ADB calls.
- Lock-file artifact hashes: all 6 references passed.

## Safety boundary

No device, ADB, root, profile, APK, Stable, account, config, save, options,
Xaero, QGO or network action occurred. Device writes require
`-AllowDeviceWrite`, one explicit non-network USB serial and an exact stopped
Lab/Stable state. Root fallback is disabled by default and, when explicitly
selected, is chosen by a read-only capability probe before the compound
mutation. A failed normal mutation is never retried as root.

The Windows transport fallback was tested with in-memory PnP records and fake
ADB responses only. Host QA made zero real ADB, PnP-device, device, root or
network calls.

The raw runtime log capture is bounded to the exact Lab `latest.log`, binds it
to PID start ticks/inode, and deletes the Host copy in `finally`. It retains no
raw log and makes no controller, stereo or FPS claim.

## Remaining Quest gates

- exact installed APK/signature and on-device file access;
- v9 marker consumption and process-local candidate promotion;
- fresh PID, exact candidate/VEQ/Vulkan/OpenXR runtime log;
- right trigger/Y, reverse hands, Grip/Wrist, bow, haptics, tracking loss and
  interaction-profile reconnect;
- matched-refresh A/B result;
- exact RC8 baseline restoration after the one B launch.

