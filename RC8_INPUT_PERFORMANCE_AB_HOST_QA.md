# RC8 OpenXR-input performance A/B — Host QA

Date: 2026-09-08

Status: **HOST PASS; QUEST NOT CONTACTED; NO PERFORMANCE CLAIM**

## Reviewed artifacts

The following are byte SHA-256 values from the reviewed worktree:

- `scripts/quest-v71-rc8-input-performance-ab.ps1`
  - SHA-256: `ADBF097882BC0F2419490B4AE1C16689B7E5C58574F7D9ABD7761798AA3D95FD`
- `scripts/test-quest-v71-rc8-input-performance-ab-host.ps1`
  - SHA-256: `4E50364996E03145F55567118CB48E8E8B2C7883445A467B1D0ADF183AC4AC83`
- `scripts/quest-v71-rc8-input-performance-ab-runbook.md`
  - SHA-256: `19A6C44B6FFC38C3478F25792ADA9A5DF77B2EFD04DD00F890F8E3205D28E5FE`
- `scripts/quest-vrapi-pid-benchmark.ps1`
  - SHA-256: `DAA183A1FC8323248D2C1D6751BF0E78248215BC9325BAD33AF7114FE0764816`
- `scripts/quest-v71-rc8-benchmark-world-reset.ps1`
  - SHA-256: `999436374865E01FDCD88E15FC12E844F005CFCABE1601EC6F7B62BFE8820CD8`
- `scripts/test-quest-v71-rc8-benchmark-world-reset-host.ps1`
  - SHA-256: `900182C28D16078673281080DCB8F6F6BB279D83AB373F990B7B3D45959052B4`
- `scripts/quest-v71-rc8-input-canary.ps1`
  - SHA-256: `E956EE77E18C6B978D83D1582667B666459114D4B5D02BFBEA43232CFF00D060`
- `RC8_INPUT_AB.lock.json`
  - SHA-256: `4FC1F4E85F4777533E8EDFC4FD44823863B55E7DF39F5BE199C567652AC0C859`

The performance wrapper pins normalized-text SHA-256 values so CRLF/LF checkout
policy cannot change the contract:

- benchmark: `419672CB4C7D6939A84DB933FE83A5D988249074B1DC2E3EBE891CDFD5684CD5`
- world-reset producer: `15B5B5D73D7B6195EA4F69962A510D10E26DDA9A7BC342CA0D6181BFA9B19723`
- input canary: `560388F0B659B585AFC7A7318C8505B4A36AF4A29E8390E7670051AE351DA3A5`
- input lock: `BE67D44004FC23B569DA5BD80B6AAC1FD633CED7EAEB78F330B3466A6E7C7F6F`

## Executed Host gates

- PowerShell 7 parser: PASS, zero errors for the performance wrapper, benchmark,
  reset producer, input canary, and all three related Host/fault suites.
- performance wrapper `SelfTest`: PASS, 19,564 assertions, zero ADB calls and
  zero Host evidence writes.
- performance wrapper `Status`: PASS, zero ADB calls and zero Host writes.
- `quest-vrapi-pid-benchmark.ps1 -Action SelfTest`: PASS, 48 assertions.
- performance fake-ADB end-to-end/fault suite: PASS, 248 fake calls, zero real
  ADB calls, zero device writes.
- world-reset `SelfTest`: PASS, zero device invocations, zero device writes,
  and zero Host writes.
- world-reset fake-ADB suite: PASS, 193 assertions, 33 fail-closed scenarios,
  three durable reset receipts, zero real ADB calls.
- input-canary `Plan` and `SelfTest`: PASS, zero ADB calls.
- input-canary fake-ADB Host suite: PASS, 43 cases, 25 fake device calls,
  20 Windows PnP fixtures, eight transport-resolution cases, zero real ADB.
- input-canary offline transaction/fault suite: PASS, seven cases (five deploy
  faults, one rollback, one fingerprint), seven Bash syntax checks, zero ADB.
- `git diff --check`: PASS (line-ending notices only; no whitespace errors).

The performance fake suite exercises the fixed `A1 B1 B2 A2 A3 B3` order,
capture/reset SHA chain, exact reset/run/device/snapshot identity, final B3
rollback receipt, six fresh process identities, three fresh B transaction IDs,
strict JSON booleans, immutable acceptance thresholds, unrounded 2%/-1%
boundaries, aggregate-only retention, and rejection when Stable appears during
a timed capture poll. It also rejects wrong version/APK/Core/VEQ/config,
copy-batching ON, marker symlinks, wrong levels, invalid serials, and changed
other-mod fingerprints.

The reset and canary suites exercise normal/root transaction boundaries,
fixed root stdin transport, rollback fault recovery, marker-last deployment,
baseline restoration, explicit USB-only selection, and Windows Quest USB parent
proof for deploy and rollback.

## Evidence and acceptance boundary

- Each arm requires exact RC8 Lab APK/VEQ, exact A or B Core, render scale 1.0,
  copy batching OFF, QGO Dynamic operator confirmation, one fresh process, a
  five-minute warm-up, a fixed 180-second request, matched observed refresh
  strata, complete thermal samples, one CPU/GPU level pair, and Stable stopped
  at both fences and every one-second runtime poll.
- Each arm is bound to a fresh reset receipt produced while both apps are
  stopped. A reset proves exact A/no marker, the fixed world/master, immutable
  original snapshot, access mode, USB transport, completion time, and a salted
  serial-free device binding.
- Analysis requires all six captures, all six resets, and the final exact-A/no-
  marker rollback receipt. It never auto-promotes; every result fixes
  `stablePromotionAllowed=false`.
- No Quest/ADB/network contact occurred in this work. No APK, mod, profile,
  config, account, world, QGO, root, or Stable mutation occurred.
- This validates the Host tool only and makes no device-performance claim.
