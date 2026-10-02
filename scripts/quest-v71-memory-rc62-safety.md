# v71 RC6.2 memory evidence safety contract

RC6.2 has its own immutable Lab identity and runtime-evidence producer locks:

- candidate: `V71_LAB_RC6_2.lock.json`
- producer: `V71_RC6_2_EVIDENCE_PRODUCERS.lock.json`
- sampler: `scripts/quest-v71-memory-soak-rc62.ps1`
- manual receipt: `V71_MANUAL_RC6_2_ACCEPTANCE.template.json`

The sampler is cloned from the hardened RC5 sampler and binds the exact RC6.2
APK, Core, frozen RC6 VEQ, bounded JVM policy, launcher-release marker,
focused process, `QuestCraft-JVM` thread, and fresh `26.2` game log. RC6 and
RC5 receipts remain immutable diagnostics and cannot accept RC6.2.

All device probes are read-only. Samples retain only parsed memory, battery
temperature, battery status, Android thermal status, timestamps, and boolean
identity fences; raw device output, logs, paths, serials, and account/world/
server data are not written. Host JSON/JSONL is the only normal output.

The sole device mutation is an explicitly authorized thermal fail-safe. Sample
mode requires `-AllowThermalSafetyStop`; if battery temperature exceeds the
configured limit or Android thermal status exceeds its configured limit, the
sampler issues exactly `adb shell am force-stop com.qcxr.qcxr.canary262`,
marks the run failed, and stops sampling. It cannot stop Stable. Defaults are
47 C and thermal status 2 (`MODERATE`); configured limits cannot exceed 50 C
or status 3 (`SEVERE`), so `CRITICAL` always triggers the stop.

Host-only verification makes zero device calls:

```powershell
pwsh -NoProfile -File scripts/quest-v71-memory-soak-rc62.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-v71-memory-soak-rc62-host.ps1
```

A real sample additionally requires
`-Action Sample -AllowDeviceRead -AllowThermalSafetyStop`. Do not run it
without explicit device authorization.
