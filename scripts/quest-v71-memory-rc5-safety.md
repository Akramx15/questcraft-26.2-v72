# v71 RC5 memory evidence safety contract

RC5 uses its own memory producers and receipts:

- sampler: `quest-v71-memory-soak-rc5.ps1`
- validator: `quest-v71-memory-runtime-contract-rc5.ps1`
- two fresh 90-minute runs are required for the exact RC5 APK
- RC4 captures and receipts remain immutable, diagnostic-only evidence

The sampler binds the installed Lab package, version, APK, Core, frozen VEQ,
bounded JVM policy, launcher-release mode, focused process, and
`QuestCraft-JVM` thread. At the beginning of each soak it records a minimal
start attestation tied to the exact PID while the launcher marker is still in
logcat. At completion it records a second attestation and requires the same PID
to remain alive. This avoids pretending that a 90-minute logcat retention
window is reliable.

Neither receipt stores raw logcat, raw game logs, account names, server
addresses, world paths, device serials, or authentication files. Evidence is
strict UTF-8 JSON/JSONL, published atomically, and hash-bound to the producer.

The fixed acceptance limits remain: no LMK/crash, one PID, PSS at most
`2.4 GiB`, post-warm slope at most `2 MiB/min`, and final 30-minute growth at
most `128 MiB`. Missing samples, missing start/final attestations, a PID change,
or a pending/unaudited RC5 APK is a failure, never an inferred pass.

Host-only verification:

```powershell
pwsh -NoProfile -File scripts/quest-v71-memory-soak-rc5.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/quest-v71-memory-runtime-contract-rc5.ps1 -Action SelfTest
```

These SelfTests use synthetic fixtures and make zero device calls. Runtime
actions require explicit authorization and must reject pending candidate
metadata before resolving ADB.
