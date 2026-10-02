# QuestCraft Vivecraft Personal 26.2 status

## 2026-10-02 — v72 perfbase installed and live-verified

The release APK built from `cd079c65` is
`QuestCraft-Vivecraft-26.2-personal.13-perfbase-cd079c65.apk`, `128500669`
bytes, SHA-256
`6748C17071B90ED5DC236FBA84CA3BBC4DEAED54C802D0150CFA82B20EFA3680`.
It was installed with same-signer `adb install -r`; the pulled installed APK
matched that hash exactly. Package identity is `com.qcxr.qcxr.dev262`,
versionCode `72`, versionName `6.0.1-26.2-vivecraft-personal.13`. Profile,
settings, mods, and save fingerprints were unchanged by the replacement.

A live QGO launch applied CPU `4`, GPU `4`, fixed `72 Hz`, FFR `4`, and the
default `1680x1760` resolution. Minecraft 26.2 / Fabric Loader 0.19.5 reached
OpenXR `FOCUSED`, submitted both eye passes, and entered the stress-test world
without a post-entry fatal, OOM, access-denied, Mixin-apply, or crash marker.
The steady post-teleport window averaged `70.14 FPS` (median `71`, P10 `63`),
but it was not a controlled v71-versus-v72 A/B.

The latest code change documented for this source line includes `968cace5`,
which adds asset-index self-healing after the release build. That source change
is not present in the `cd079c65` APK and must not be
claimed as deployed. Distant Horizons, the staged performance-mod candidates,
and a laptop Minecraft server are not installed by this release.

## 2026-09-11 — Personal v72 Seed-Only Host build PASS; Quest install pending

Personal mod management is now seed-once rather than reconcile-on-Play. A new
26.2 Personal profile receives the pinned compatible defaults once; an existing
profile is migrated with metadata only. After that, ordinary Play performs no
mod or resource-pack writes. Direct add/update/remove operations are atomic,
required dependencies are resolved before commit, filename ambiguity fails
closed, and explicit Repair remains a separate user action. Lab behavior is
unchanged and strict-managed.

The four 26.2 manifests are equivalent and pin Xaero Minimap `26.5.0` at
SHA-256 `E12BBDCC…B4343`. Pojlib passed Debug and Release tests; two clean AAR
builds matched byte-for-byte at `64B27CF1…DCF38`. Unity 2022.3.62f3 returned
success and produced `Vivecraft Stable` v72 (`personal.13`), SHA-256
`DFC2A264…A94A7`. Package, version, signer, ARM64-only, SDK 29/34, Vulkan/OpenXR,
16-KiB alignment and embedded Core/VEQ/LWJGL payload gates passed. The Quest was
not reachable over ADB at the end of Host verification, so install and the
two-Play no-reconciliation proof remain pending.

## 2026-09-08 — healthy RC8 scheduler capture points to render/GC cost

The exact RC8 Lab completed a privacy-scoped 30-second Perfetto capture after
the four noisy KGSL vendor-transition events were removed from the selected
event tier. The trace is healthy: zero setup errors, dropped events, overruns,
data loss, and buffer overruns. Only the aggregate JSON was retained; the raw
Host and Quest traces were purged, Personal Stable stayed stopped, and no app
or profile mutation occurred.

The app consumed `100.481%` of one CPU core in aggregate. Its dominant generic
thread consumed `64.742%` of one core with only `0.070 ms` runnable-wait P95;
cross-run KGSL correlation and the source call chain make this very likely the
Minecraft client/render plus Vulkan-submit thread, but no code will key on the
generic Android name. The next fixed categories were G1 GC at `10.011%`, Sodium
async work at `7.563%`, the integrated server at `4.935%`, OpenAL at `3.741%`,
and Unity frame pacing at `2.057%`. Submitted and retired KGSL batches were
`19978/19977`; the one-event edge delta is not evidence of a queue leak.

This supports a one-variable test of the reviewed OpenXR input-allocation
candidate, not a release claim. That candidate removes a measured lower bound
of `142` temporary objects and `3456` bytes per frame. The exact one-shot Lab
A/B harness is Host-tested, pins USB/APK/Core/VEQ/other-mod identity, keeps
copy batching `OFF`, closes Stable-start races inside the atomic transaction,
and restores the exact RC8 Core after the candidate launch. It has not yet
been deployed. A later, separate candidate may make the two diagnostic
`poseString` calls lazy; rejected copy batching, Array Dual-Pass, history
rings, hardening, thread settings, and render scale `0.8` will not be retried.

Evidence: `artifacts/perfetto/rc8/capture-20260908T000815Z-627569d2/aggregate.json`,
SHA-256 `2ADA9EF869D866A4274FA5DA6342CF9B12A2FB4A78E830249E99AE70DD2F041D`.
Perfetto tracing is diagnostic-only and cannot accept FPS or Stable promotion.

## 2026-09-07 — RC8 remains live; Host input gates revalidated

The exact RC8 Lab candidate remains the active test target. A full Java 25 VEQ
check and the current post-build mining audit pass. The audit now fail-closes
on exact hashes for both reviewed mining tests and their Gradle registration,
while separately proving that no runtime or packaging input changed after the
locked RC8 integration. The unsafe native `/actions/ingame/in/key.attack`
fallback remains rejected; the diagnostic Lab is reserved only for a reported
manual failure.

Static tracing confirms the intended ordinary path from the logical-right
Quest trigger through `keyMainAttack`, the per-hand router, and Vanilla
`startDestroyBlock` / `continueDestroyBlock`. It cannot prove that the runtime
action is active, its origin is correct, its target is a valid block, or that
Vanilla consumed it, so manual RT mining remains the release gate and Stable
promotion is still forbidden. A follow-up artifact audit also disproved a
suspected legacy-overlay cancellation path: `mod-core` includes only
`org/questcraft/veq/**`, and the exact RC8 VEQ JAR contains no `org/vmstudio`,
`MinecraftMixin`, or Visor runtime class.

The live Lab config was read without modification and currently has
`renderScaleFactor=1.0`. A later one-variable Lab Canary at `0.8` is a bounded
performance/memory candidate, but it must not begin until RC8 mining is
accepted or diagnosed. The server resource pack remains out of scope.

## 2026-09-07 — RC8 aggregate memory follow-up: high plateau, leak not proven

Two consecutive, identity-fenced read-only captures completed against the
same running RC8 Lab candidate. The collector used only
`dumpsys meminfo -a --local`, `/proc/meminfo`, and optional
`smaps_rollup`; it did not request target GC, read runtime logs, use root,
write to Android, or access Stable. The first 10-minute window rose by
`26.52 MiB` total PSS, almost entirely Native Heap. The immediately following
window was flat by regression (`-0.33 MiB/min` total and `+0.06 MiB/min`
Native Heap) despite a bounded sawtooth. GL/EGL and Gfx-device memory were
flat throughout.

Across both windows the observed span was `23.97` minutes, total PSS ranged
from `2934.70` to `3003.83 MiB`, and the final value was `2981.08 MiB`.
That is not evidence of a continuing leak after the first ramp, but it still
exceeds the existing `2.4 GiB` acceptance ceiling and leaves RC8 in the
classification `HIGH_PLATEAU / LEAK_NOT_PROVEN / ABSOLUTE_GATE_FAIL`.
No Xmx, Vulkan, graphics, or runtime patch is justified from this evidence
alone, and Stable promotion remains prohibited. The sanitized result lock is
`V71_RC8_MEMORY_RUNTIME_RESULT.lock.json`.

The first real-ADB run also exposed two Host-fixture gaps in the new collector:
Windows adb did not preserve its compound `sh -c` program, and this Android
build labels the section `App Summary for pid ...` rather than plain
`App Summary`. Both were corrected with an argv-only `/proc/*/comm` read and
an identity-checked summary parser; the full Host/Fake-ADB suite passes after
the correction.

## 2026-09-07 — v71 RC8 installed in Lab; runtime identity PASS, mining pending

The exact locked RC8 APK was installed with `adb install -r` into
`com.qcxr.qcxr.canary262` and then pulled back and verified by the guarded
installer. Stable `com.qcxr.qcxr.dev262` was not touched. The authenticated
autoplay gate launched profile `26.2` and Quick Play entered
`FPS-Stress-Test`.

A fresh bounded `latest.log` snapshot passed the corrected Host verifier with
Minecraft `26.2`, Fabric Loader `0.19.4`, Core
`26.2-1.3.15+qc.v71.rc8-mining`, VEQ `0.7.0-v71.rc6`, Vulkan, connected
OpenXR and a submitted two-eye projection frame. The handled Android narrator
`libflite` failure is explicitly distinguished from a fatal native linkage
failure; every linkage error outside that exact narrator initialization block
still fails closed. The raw log was deleted after verification. Sanitized
evidence is in `artifacts/runtime/v71-rc8-launch-20260907.json`.

A read-only live config check while this exact Lab process remained active
also ruled out the common configuration gates: `seated=false`,
`aimDevice=CONTROLLER`, `reverseHands=false`, and `weaponCollisionNew=ON`.
This narrows any remaining RT failure to the runtime action transition or a
temporary per-hand owner; it still does not prove that a block was broken.

**Decision:** runtime identity/render startup PASS; manual RT/Y mining remains
PENDING. Stable promotion is still prohibited.

Two Host-only contingency branches are intentionally **not** part of RC8:

- `feature/v71-rc8-rt-diag-host` at `d22b3f78` provides opt-in,
  transition-only mining telemetry behind
  `-Dvivecraft.questMiningCanaryTelemetry=true`. The audited diagnostic Lab
  shell is versionCode `72`, versionName
  `6.0.1-26.2-vivecraft-personal.12-rc.8-diag.1`, size `128470289`, SHA-256
  `D278D59D48B416A97A4E092C38B4036A28E1B42092E2E355D5AD0B91E8641D76`,
  and uses the same signer as RC8. Its embedded Core and ordinary VEQ remain
  byte-identical to RC8; the one-shot diagnostic VEQ has SHA-256
  `A0F70DDF970B94F1C66C308528E71D89710B6AE202729639D23E5E13F62C8FC8`.
  The launcher hook is Lab-only, exact-hash gated, never persists the JVM
  property to the profile, and rolls back closed. It records no coordinates,
  account, world or server identity and is reserved only if the manual RC8
  test still fails. Host verification passed, but it has not been installed
  or runtime-validated.
- `audit/rc8-rt-fallback` at `6c30c1c8` provides a source-locked fallback from
  `keyMainAttack` to the already-bound logical-right trigger sample. It is not
  merged because archived Quest evidence already showed the primary action
  active; restoring native `key.attack` in parallel was rejected because it
  could generate duplicate clicks.

Plain RC8 must be evaluated first. Neither contingency changes the locked RC8
artifact or authorizes Stable promotion.

The current-state Host audit in
`scripts/test-v71-rc8-current-mining-host-audit.ps1` passes without contacting
a device. It pins the exact APK and runtime sources, permits only the reviewed
post-artifact mining test file, re-runs the installer/rollback/capture default
safety gates, and requires the sanitized receipt to remain
`PENDING_USER_OBSERVATION` with Stable promotion disabled.

If the opt-in diagnostic is needed, its Host parser is already available at
`scripts/analyze-v71-rc8-mining-diagnostics.ps1`. It accepts only the exact
transition schema, emits a fixed privacy-safe classification instead of raw
log content, and has no ADB path. Its self-test accepts eight valid failure
shapes and rejects twelve malformed or unsafe fixtures.

The supervised path now has two additional fail-closed Host tools. The RC7
rollback helper accepts only the exact audited Lab APK and signer, requires the
Lab process stopped twice, verifies the installed signer before mutation and
the entire pulled APK afterward, and permits only one `install -r`. The RC8
capture helper binds `latest.log` to the one live Lab PID, process start ticks,
inode and fresh timestamps, pulls only that file into Temp, runs the pinned
verifier, and deletes the raw file in `finally`. Their Fake-ADB suites pass `11`
and `12` negative scenarios respectively; both default modes make zero device
calls and hard-deny Stable.

## 2026-09-07 — v71 RC8 mining Lab built and audited on Host; Quest pending

RC7 commit `1ddd7bf2` wrapped both of Minecraft's native
`startDestroyBlock` and `continueDestroyBlock` calls and routed ordinary RT
mining through the new per-hand claim/replacement path. The user's RC7 test
then reported that blocks could not be broken. The source boundary matches the
regression: RC7 no longer left the normal Vanilla start/continue sequence
intact. RC8 removes those two wrappers instead of trying to patch their
replacement behavior.

The RC8 mining behavior is intentionally narrower:

- RT/main-hand start and progress remain the unmodified Vanilla path.
- Y/offhand can contribute only to the exact `BlockPos` owned by Vanilla's one
  active destroy session. A different offhand target fails closed and cannot
  cause START/ABORT oscillation.
- Releasing one button does not abort that exact session while the other hand
  still holds it; releasing both lets Vanilla stop it.
- Passive main-hand intent suppresses an RT plus physical-swing duplicate in
  the same tick without taking ownership of the Vanilla session.
- Native RT and routed Y targets remain separate under `reverseHands`, so a
  logical-main Y action is not consumed as if it were native RT.

The source chain is `e27327b8..e1b19c73`; Core runtime behavior is pinned at
`4d908ffe`, the final Core/VEQ integration is `35c0e373`, and the audited
artifact record is `e1b19c73`. Independent review of the first correction
found one P2 RT/physical duplicate-contribution risk; `4d908ffe` fixes that
risk and the follow-up contracts at `51990809` and `35c0e373` cover the final
native-RT and reverse-hands boundaries.

Exact Host-built Lab identity from `V71_LAB_RC8.lock.json`:

| Artifact | Version / size | SHA-256 |
| --- | --- | --- |
| Vivecraft Core | `26.2-1.3.15+qc.v71.rc8-mining`; `10078822` bytes | `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB` |
| Frozen VEQ | `0.7.0-v71.rc6`; `444150` bytes | `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9` |
| Core/VEQ pair | UTF-8 pair digest | `F8AB021283B027CC29463E0FBADD1DA3688C74B11EFA95334BA650EB853C60AB` |
| Pojlib AAR | `88734979` bytes | `F4A7683C1C9376BA2626B2C7527878A4D47534A744227955C3BDC16A9B5A211B` |
| Lab APK | `128469341` bytes | `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416` |

The APK is only `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.8`, signed by
`B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`.
The Host audit passed ARM64-only, SDK 29/34, Vulkan/OpenXR payload, APK v2
signature and 16-KiB ZIP alignment. Vivecraft reported `194` tests with zero
failures/errors/skips; VEQ `check` and Fabric build passed; Pojlib reported
`143` tests with zero failures/errors/skips; two clean VEQ builds and two clean
Pojlib AAR builds matched byte-for-byte. The two clean Core builds did **not**
match byte-for-byte, so reproducible Core output is not claimed; the one exact
Core hash above is the only accepted RC8 payload.

The post-artifact Host coverage commit `c3781fb4` adds the actual RC8 call
order for native RT plus Y in one tick, native RT continuing after Y release,
different-target fail-closed behavior without stealing Vanilla ownership, and
button-versus-physical offhand dedupe. The full `:common:test` run passed all
`48` suites / `194` tests. This test-only commit does not change the locked
Core, VEQ, AAR or APK bytes above.

**Decision:** `HOST_BUILT_AND_AUDITED` only. No ADB, root, device, runtime,
controller, stereo, performance, or Stable action is part of this evidence.
Quest validation remains `PENDING_NOT_RUN`, including RT alone, Y alone,
RT+Y on one block, releasing either hand first, different targets, physical
swing dedupe and reverse hands. Stable `com.qcxr.qcxr.dev262` remains
untouched and promotion is prohibited until those supervised checks pass.

## 2026-09-07 — exact v71 RC6.2 tight-space Lab accepted manually

RC6.2 is installed only in Lab and remains open in the benchmark world. Its
identity is `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.6.2`. The exact APK is
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.6.2-tight-space-local.apk`,
`128459705` bytes, SHA-256
`ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4`.
Stable `com.qcxr.qcxr.dev262` remains installed, stopped and untouched.

The embedded pair is Core `26.2-1.3.15+qc.v71.rc6.2`, SHA-256
`6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF`,
and frozen VEQ `0.7.0-v71.rc6`, SHA-256
`BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD`.
The Pojlib AAR is `88724129` bytes, SHA-256
`6B9224C6697D00DCE363AD80EA5FA9946E90808C514517BA4EEDFEB31DB2BA89`;
its two clean builds matched byte-for-byte. Package, signer, SDK 29/34,
ARM64-only, Vulkan/OpenXR, v2 signing and 16 KiB alignment passed. All four
managed manifests contain exactly one Core and one VEQ. The fresh post-manual
Vivecraft common regression reported `45` suites / `167` tests with zero
failures, errors or skips.

The two tight-space fixes are intentionally independent:

- While Wrist is visible, only the anchor-hand shield **render snapshot** is
  suppressed. The inventory stack, blocking/protection state and durability are
  not modified, and the model returns on the next frame after Wrist closes.
  The current saved setting is `shouldRenderSelf=false`; the separate full-body
  held-item path remains a manual regression if that option is later enabled.
- Grip alone opts into `ALWAYS_VISIBLE`. Fast/Fancy paths ignore world depth for
  that surface, and Fabulous routes it to `VrUnoccluded`, so nearby tunnel
  blocks cannot cover it or veto its ray selection. Wrist retains ordinary GUI
  depth behavior.

The exact runtime identity reached the FPS Stress Test world with OpenXR
focused and submitting frames. The 30-minute safety screen is
`artifacts/benchmarks/v71-rc62-live-readonly-01.json`, SHA-256
`BFA4632EDF153BE01E91E08EEA42339108A808FAF949BD9608597A22C7C1DE78`.
It captured `1801` samples over `1800.79s`: mean `87.19 FPS`, P10 `85`, P95
App `4.84ms`, P95 CPU+GPU `11.06ms`, stale `0.77/s`, and maximum `44C`.
Refresh was Dynamic (`73–94Hz`, mode `87Hz`) with CPU level mode `2` and GPU
level mode `7`; this is a stability screen, not a paired performance comparison
or a QGO 4/4 claim.

Both exact 90-minute memory runs completed with `19/19` samples, one stable PID,
continuous focus/game-JVM/log identity and no thermal stop:

| Run | Max PSS / VmRSS | Swap / min available | Post-warm slope | Last 30 min | Formal result |
| --- | --- | --- | --- | --- | --- |
| 1 | `3275.992 / 2322.660 MiB` | `0.059 / 1514.914 MiB` | `0.134 MiB/min` | `+7.955 MiB` | `FAIL`: only PSS exceeded `2457.6 MiB` |
| 2 | `3172.923 / 2231.746 MiB` | `1.980 / 1645.520 MiB` | `0.308 MiB/min` | `+7.828 MiB` | `FAIL`: only PSS exceeded `2457.6 MiB` |

Run 1 summary/samples SHA-256 are
`140ABC18A9F10E9229D8B77A2A41B63883AE9E054B71E32CCDBC326FD4DAF9E9` /
`4BD29B858AFBDBBCA28339035E265DCD761C4712BB5FAF301FEAA21584D9B30D`.
Run 2 summary/samples SHA-256 are
`1E5C8EBA2E0B8CB86B9233E731CF88F25902DBA35FE79B72B0493C370CA18FE9` /
`C0F87D3B65BEACE3137BC2FCF0F503ED44114D55F8A0A170D5A14224FC487D09`.
The separate pair receipt
`artifacts/memory/v71-rc62-pair-supplementary.json`, SHA-256
`3C73CDB3DDD89C338BC001E6FC6C72F69B5158CD7F24C0D9481625D3587FD4C0`,
classifies both as `LEAK_STABILITY_PASS`. That supplementary result does not
override the immutable formal PSS failure, prove that no leak of any kind can
exist, or authorize Stable promotion.

The aggregate immutable result is frozen in
`V71_RC6_2_RUNTIME_RESULT.lock.json`, SHA-256
`A0B37CCAAA67E0D0E4BA7C4E5CA80745707958F26B113638ABDEFB264788770C`.
Run `scripts/verify-v71-rc62-runtime-result.ps1` to authenticate the exact
artifact chain and all referenced evidence without issuing device commands.

The user subsequently tested the two independent tight-space fixes on this
exact RC6.2 identity and reported that everything worked. The immutable manual
receipt is
`artifacts/manual/v71-rc6.2-user-acceptance-20260907.json`, SHA-256
`C321B3CDE43807D68C8A6C8C942FF92FEE2DA046B90FA2F09F1664914CABA12E`.
It accepts shield hide/block/restore and Grip visibility/selection in the 1x1
tunnel for the standard-hand run. It does not claim reverse-hands coverage,
performance acceptance, memory acceptance, or Stable promotion.

The additive post-manual Host regression receipt is
`artifacts/host/v71-rc6.2-post-manual-host-regression-20260907.json`, SHA-256
`D40E03D3EE5E934055A5C5600F936B5EF811723E335E99FB1816AD816E6D70DA`.
It binds source commit `baa7d973`, the immutable RC6.2 build/runtime locks and
manual receipt, and the exact Core, VEQ, Pojlib AAR and APK identities. The
fresh closure passed Vivecraft `45/167`, VEQ Java 25 `check` plus
`:mod-fabric:build` with the exact locked JAR, Pojlib `test` plus
`assembleRelease` with the exact locked AAR, and the exact RC6.2 APK verifier.
This is Host-only regression evidence: it changes neither the accepted payload
nor the immutable runtime result, does not override the formal PSS failure, and
does not authorize Stable promotion.

The current runtime log names optional
`file/LunarLabs-26.2-Quest-Vulkan-v2.zip`. Graphics memory was nearly flat near
`1207 MiB`; historical vanilla-only captures were near `780 MiB`, but those are
not a controlled same-build A/B, so no causal memory claim is made. A Host-only
lossless animation canary exists at
`exports/lunarlabs-lossless-canary/LunarLabs-26.2-Quest-Vulkan-v2.lossless-frames-canary.zip`,
SHA-256 `D80AA4F918A572C2A7ABD9C52FE41F5061B2CF2CA53A2047C3EE1645FF7CBC66`.
It was not installed; it saves only `4.43 MiB` of decoded source sheets and does
not reduce logical atlas slots, so it is not expected to solve the PSS cap. On
2026-09-07 the user removed this server-specific pack from project scope. No
further optimization, A/B test, installation, activation or release bundling
will be performed for it; existing artifacts remain historical evidence only.

**Decision:** RC6.2 passed artifact, runtime-screen, bounded-growth and the
required standard-hand manual interaction checks. It still fails the unchanged
formal absolute-PSS gate, so Stable promotion remains prohibited. Reverse-hands
behavior was not observed and is not claimed.

## 2026-09-07 — v71 RC5.2 network-independent prelaunch Lab built on Host

RC5.2 is the current Host-built Lab candidate. Its exact APK is
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.5.2-integrated-local.apk`,
`128439489` bytes, SHA-256
`AAD1B8F94DE7D4F65BF481CE65FCA83FAFFC7B0961435E95EF3F1899CF038879`.
Its identity is `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.5.2`. The integrated artifact audit
passed and Stable `com.qcxr.qcxr.dev262` was not touched.

The gameplay payload is byte-identical to RC5/RC5.1: Core
`26.2-1.3.15+qc.v71.rc5`, `10064652` bytes, SHA-256
`494BC1CB9CED37C4F2193704CDA1ED4B4F3461DDFB5E75A1C3475D0124159F00`,
and VEQ `0.7.0-v70-canary.1`, `441660` bytes, SHA-256
`314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.
Only the Pojlib prelaunch path changed. The byte-preserving ownership repair
now runs before the online/offline branch, independently of network state, and
fails closed before JVM launch when it cannot verify a safe repair. Two clean
Pojlib builds reproduced AAR
`5CBC6468A4E2CB4F98CB8BBE005C387AEA12E9AD43360BA5CA76167DC86D470A`
(`88706771` bytes); all `116/116` Host tests passed.

RC5.2 has **no Quest runtime, manual-menu, lifecycle, soak, or performance
acceptance yet**. RC5.1 runtime evidence is an immutable predecessor boundary
and cannot be reused to accept RC5.2. The authoritative identity and Host gate
are in `V71_LAB_RC5.lock.json`.

### Optional LunarLabs resource pack in the Lab profile
The user supplied the original archive outside the repository. A
Quest/Minecraft 26.2-compatible derivative was staged outside the repository
as `LunarLabs-26.2-Quest-Vulkan-v2.zip`, with
SHA-256
`227FF427604E4503BAF06A9766977EB7F926841A4325428069A40DC21FCB67D8`.
The derivative changes pack compatibility metadata to format `88` and adjusts
the ModelEngine shader import so it follows the Minecraft 26.2/Vulkan shader
contract.

The exact derivative was copied to the RC5.1 Lab profile as
`/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/resourcepacks/LunarLabs-26.2-Quest-Vulkan-v2.zip`;
its physical device SHA-256 matched the value above. The observed RC5.1 game
log contained
`Reloading ResourceManager ... file/LunarLabs-26.2-Quest-Vulkan-v2.zip` and did
not contain the prior shader-uniform or pack-compatibility failure. This proves
only that exact RC5.1 load, not RC5.2 acceptance.

The pack is optional user content and is not in a managed Pojlib manifest.
An uncontrolled play-session comparison observed about `+0.9 GiB` of largely
fixed PSS with the pack enabled. That is diagnostic only: it is not a controlled
benchmark and is not evidence of a leak. Every A/B run must therefore pin and
record the pack state; pack-on and pack-off samples must not be mixed.

## 2026-09-07 — v71 RC5.1 options-ownership Lab built on Host

RC5.1 preserves the exact RC5 Core and VEQ gameplay bytes and changes only the
Lab packaging/Pojlib path needed to repair an unwritable `options.txt` inode.
The repair is a no-op for an absent or already-writable file. Otherwise it
creates an app-owned replacement only after bounded reads, durable staging,
byte/hash verification, change detection, and a rollback-capable atomic/fallback
move. It rejects symlinks, non-regular files, and files over 4 MiB.

The Host-only output is
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.5.1-integrated-local.apk`,
`128437825` bytes, SHA-256
`F53A3AED167AF2396B498F030862C01F5590C63C9E80ABE7C0D786AC5EA95EA2`.
Identity: `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.5.1`, signer
`B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`.
Two clean Pojlib builds reproduced AAR
`9B8039685C0012B6FB103C0BC79325C59626AA966C8279C8DEC10B05827E40D5`
(`88703720` bytes), and all `110` tests passed.

The APK audit passed SDK 29/34, ARM64-only, Vulkan/OpenXR, v2 signing, 16 KiB
alignment, exact RC5 Core/VEQ/LWJGL bytes, manifest parity, and Lab DEX checks.
No ADB or device action occurred; the running Lab, Stable, live `options.txt`,
and `resourcepacks` were untouched. RC5.1 needs fresh runtime binding and manual
acceptance; no RC5/RC4 receipt is reused.

## 2026-09-07 — v71 RC5 persistent Lab built and audited on Host

RC5 is an isolated Lab successor candidate; it does not replace the accepted
RC4 evidence or authorize Stable promotion. The Host-only build produced
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.5-integrated-local.apk`:
`128430965` bytes, SHA-256
`4F3908599D8236A3A617EF8634C4BB2B39BDBFB3A10D2EF33C7FE00B97355661`.
Its identity is `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.5`; its signer remains
`B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`.

The managed payload is Core `26.2-1.3.15+qc.v71.rc5`, `10064652` bytes,
SHA-256 `494BC1CB9CED37C4F2193704CDA1ED4B4F3461DDFB5E75A1C3475D0124159F00`,
plus unchanged VEQ `0.7.0-v70-canary.1`, `441660` bytes, SHA-256
`314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.
Their ordered pair digest is
`5B4ADB12406108D74D3F3E592857B419DD893BD3522898B06BDCF17B0F6126BB`.
Two clean Pojlib builds reproduced the same AAR (`88697676` bytes,
`4B89F803396EC8D0587187B90C15405F664D63B045FBE30C4FA9E0712675ECE6`)
and its 102 unit tests passed with no failures, errors, or skips.

The independent artifact audit passed package/version/label, SDK 29/34,
ARM64-only ABI, Vulkan/OpenXR payload, v2 signature, 16 KiB alignment, exact
Core/VEQ/LWJGL hashes, identical managed manifests, and the Lab DEX gate. The
build transaction restored ProjectSettings and the checked-in AAR and made no
ADB call. It does not read or write `options.txt` or `resourcepacks`. Runtime
log binding, manual Quest validation, and all Stable gates remain pending.

## 2026-09-06 — v71 RC4 Lab runtime progress

The exact RC4 Lab APK described below is now installed and its managed Core/VEQ
pair survived reconciliation, three independent cold starts, and the formal
lifecycle/recovery gate. The lifecycle receipt is
`artifacts/acceptance/v71-lab-rc4-lifecycle-recovery-receipt.json`, SHA-256
`60267E644DBC13F2AA078086DF4244B8DC0F0196B516D3AB26A88F97B8F87A6A`.
The Stable package `com.qcxr.qcxr.dev262` remains stopped and untouched.

The first of the two required fresh 90-minute RC4 memory soaks passed with the
same PID and exact runtime identity for all 19 samples. It recorded max PSS
`2372.301 MiB`, max RSS `1800.395 MiB`, process swap `26.633 MiB`, post-warm
PSS slope `0.245 MiB/min`, and last-30-minute growth `3.074 MiB`. Its summary
and samples are, respectively,
`artifacts/memory/v71-rc4-final-soak-1-20260906-run3/summary.json`
(`FD8A093B859AD74AA60D8CF92B53B0A77B9EBC57942C0E99D556033CE93E4E9C`)
and `samples.jsonl`
(`7C9ED1ABE3E2097905F7FDD1FD813B1EDE764477E4155376D3BE81BF24B3FD2F`).
The second soak has not passed: its first attempt was invalidated by an ADB
Wi-Fi disconnect at 45.364 minutes, and the next preflight failed closed before
sampling because the newly started process had no bound launcher-release
marker. Neither attempt counts toward acceptance.

Fresh Host verification after the runtime work passed again: Vivecraft common
reported `43` suites / `156` tests with zero failures, and VEQ executed its
full clean `check build` (`86` tasks, `59` executable self-tests and `9` static
contract verifiers) while reproducing the locked VEQ bytes exactly. A fresh
Vivecraft Fabric build had the same `1308` entries and identical content bytes
as the locked Core; its archive hash differed only because Gradle restamped the
15 nested dependency entries. The locked, runtime-tested Core remains the sole
accepted artifact.

Remaining promotion blockers are the second valid 90-minute soak, the combined
memory-runtime receipt, balanced RC3-to-RC4 performance evidence, and explicit
manual acceptance. No Stable build or install is allowed until all four pass.

## 2026-09-06 — exact v71 RC4 Lab candidate prepared on Host

The next persistent Lab candidate is fixed to package
`com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.4`, and output
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.4-integrated-local.apk`.
The exact APK was built successfully and independently audited on Host:
`128434961` bytes, SHA-256
`8D4811174EC963FFB0DDD31196C425111D03F04A5A2EB4CF6ED7D2DEBB492FAA`.
Unity and Gradle returned success; package/version/label, ARM64-only ABI,
min/target SDK 29/34, Vulkan/OpenXR payload, v2 signature, 16 KiB alignment,
Core, VEQ, LWJGL, manifest pair, Lab DEX gate, and lifecycle markers all passed.
It has not yet been installed or run on Quest; v69 Stable remains untouched.

The Host-prepared payload is Vivecraft Core
`26.2-1.3.15+qc.v71.rc4`, `10068021` bytes, SHA-256
`289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189`.
VEQ is deliberately frozen byte-for-byte at
`0.7.0-v70-canary.1`, `441660` bytes, SHA-256
`314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.
Their ordered pair digest is
`9D2C0830A34963FF3D5F336B465A6B8D11C153E82A738D0528E8D1821F25A8B1`.
The staged Pojlib AAR is `88700612` bytes, SHA-256
`7CE62B90112B74790100F5A8685412CA477D8086167598975A67DDC9E7FD7F2F`.
The bounded JVM policy and expected signer remain unchanged.

The previously proposed `DB1DF70F...3AA4B8` Core came from an incremental
compiler state and was not clean-reproducible. It is rejected. Two clean Core
builds reproduced the locked `289C2705...13189` artifact exactly; executable
instructions were unchanged and the observed delta was limited to debug
parameter names. Host validation passed 43 Vivecraft suites / 156 tests, 59 VEQ
executable self-tests plus 9 static verifiers, and 42 Pojlib suite executions /
204 tests across debug and release.

The RC4 Host acceptance plumbing was then corrected and re-locked in commits
`d3cfea5d`, `7a4e2c5a`, and `e04e4c21`: the evidence gate now receives the
repository and evidence roots separately, A/B receipts are accepted only from
`artifacts/benchmarks/`, the callers/tests use those same roots, and
`BUILDING.md` names the real gate commands. All current RC4 Host self-tests and
producer/consumer contract gates passed twice after that re-lock.

The first exact integrated build exposed a compiler/toolchain incompatibility.
The Java 25 Pojlib AAR reproduced exactly, but Unity's AGP 7.4.2 / D8 4.0.52
crashed at `mergeExtDexRelease` while reading unnamed `MethodParameters` on
synthetic bridge methods. Seventeen of 135 classes contained that metadata;
the class-file level was still Java 8. The source-identical AAR built with
Unity's bundled Temurin `11.0.14.1+1` contains no such attributes, differs from
the rejected artifact only in `classes.jar`, and passed D8 4.0.52 directly.
Commit `a636ae61` pins that one JDK for both Pojlib and Unity, adds a fail-closed
builder-JAR hash/version check plus standalone D8 preflight, and keeps the
transaction restoration behavior. Its transaction suite remains `12/12`.
This is Host validation only and closes no APK, Quest, performance, soak, or
Stable-promotion gate. After re-locking, all documented Host producer and
consumer gates passed. The current lock-file SHA-256 values are
`V71_LAB_RC4.lock.json=A531988E1DB7975FECF8546F77949F3054D8E353C634034868A9A39B32816623`,
`STACK.lock.json=EB28B3DB915FB83886B508EF8BB6FBDEAD592E9C4D34EE3C3647F15E39D92834`,
and
`V71_STABLE_RC4_ACCEPTANCE.lock.json=FF3E645ABFBC1ADB692CC01D55AF2D90FD21978BCB8F14EEB12360B608B51155`.
No RC4 APK was installed and neither the Quest profile nor v69 Stable was
touched. The original preflight had only `8.011 GiB` free. Transparent NTFS
compression of verified old Codex work folders—without deleting files—raised
free space above the enforced `10 GiB` Lab threshold; the `15 GiB` Stable
threshold remains mandatory later.

The Host APK build/audit gate is `PASS`. All device gates remain open: device
installation/runtime/cold starts `NOT_RUN`, manual VR interaction `PENDING`,
balanced RC3-to-RC4 performance `PENDING`, lifecycle/recovery `PENDING`, memory
runtime contract `PENDING`, both fresh 90-minute RC4 soaks `PENDING`, and Stable
build/promotion/install/runtime `PENDING`. Existing RC3 cold starts, memory
captures, soaks, and other receipts remain historical diagnostic evidence only;
none accepts this RC4 identity. v69 Stable remains untouched.

The completed RC3 soak 2 remains diagnostic-only for RC4. Its summary SHA-256
was `BD2A496363ED08407484AD2FEBF7C151D9BC3C6144F1E0CAF444D9AE02ACA3A8`
and samples SHA-256 was
`4803C30780D1ABAF6ECD41AA52CF41808D252044790150A8B1417786BE69C4DB`;
it held PID `12567`, reached max PSS `2363.526 MiB`, post-warm slope
`0.379 MiB/min`, and last-30-minute change `-2.891 MiB`. Its later direct
capture did not produce a PASS receipt because the 90-minute logcat window had
already lost the launch marker. RC4 fixes the evidence design with a start
attestation and a same-PID final attestation; no RC4 runtime result exists yet.

## 2026-09-06 — exact v71 RC3 integrated Lab cold-start gate passed

The current integrated Lab artifact is
`QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.3-integrated-local.apk`:
package `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
`6.0.1-26.2-vivecraft-personal.12-rc.3`, `128431385` bytes, and SHA-256
`B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F`.
Its APK audit passed. The embedded Pojlib AAR is
`D7FF9C3EE2CCB332F88DE9A44E40E5BDA38F390142DC64905AEFD720FC3ADED6`;
the persistent managed pair is Vivecraft Core
`14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26`
and VEQ
`314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.

Three normal cold starts passed. All three retained that exact RC3 pair and
logged `Xms=512MiB, Xmx=1536MiB (auto)`. v69 Stable
`com.qcxr.qcxr.dev262` remained untouched. This closes only the exact new
APK's build/audit and three-cold-start persistence gate. Manual VR interaction,
balanced performance, and both required new 90-minute soaks remain false and
pending.

A completed older-payload 90-minute capture is retained as supporting evidence
for the launcher-resource-release diagnosis. It does not apply to APK
`B8918144...9AD8F`, does not count as either required exact-new soak, and is
not a Stable-promotion acceptance result.

## 2026-09-06 — v71 launcher resource release promoted to exact-build candidate

The memory experiment identified retained Unity launcher resources as the
dominant source of the long-session growth. With release ON, a 47.64-minute
Lab run stayed essentially flat after warm-up instead of growing roughly
32 MiB/min. The release policy is now pinned to exact v71 Lab RC3 and v71
Stable identities; manual launches of those exact builds release by default,
authenticated Lab A/B runs may explicitly request OFF, and every other build
fails closed. The implementation is per-resource best-effort and idempotent,
does not call `UnityPlayer.unload`, and relies on the existing full-process
launcher recreation after the embedded JVM exits. The rebuilt permanent Lab
has now passed its APK audit and three normal OpenXR cold starts. Stable
promotion remains blocked on manual interaction, balanced performance, and two
new 90-minute soaks under this exact APK because the frozen RC3 Core has no
post-initialization acknowledgement.
See `LAUNCHER_RESOURCE_RELEASE_CANARY.md` for the exact contract and evidence.

## 2026-09-06 — historical v71 RC3 pre-hardening memory-retune evidence

The earlier memory-retuned persistent Lab APK was **built, Host-verified, and
passed three fresh cold starts on Quest**. Its
SHA-256 is
`260A5A14BB3DF42B538F155A064EF82CA932C3D9261A6D84858214426BE17C82`
(`128398817` bytes). v69 Stable (`com.qcxr.qcxr.dev262`) remains installed and
untouched. Each new start retained the exact RC3 pair, entered `FPS Stress
Test`, initialized Vulkan/OpenXR, and logged `Xms=512MiB, Xmx=1536MiB (auto)`.

A still earlier pre-retune startup series retained the exact managed RC3 pair:
Vivecraft Core `14B230B6...38A26` and VEQ `314D3CBD...E0D8B`. Each start reached
the `FPS Stress Test` world with Vulkan and OpenXR active. Its bounded automatic
heap selections were `1657`, `1644`, and `1633 MiB`; none exceeded the
`2048 MiB` cap. Those values describe that pre-retune APK and prove persistent
reconciliation and startup/runtime smoke only. Manual VR interaction, balanced
performance, both exact-new 90-minute memory soaks, and Stable promotion all
remain false/pending.

Before the integrated RC3 build, the previously observed Lab session loaded
RC2, not RC3. RC3 had been delivered by a one-shot marker; after that marker
reached its terminal state, a normal Play reconciliation retained/restored the
managed RC2 baseline. That explains why the later ImmersiveMC, Wrist throw, and
left-hand Y checks did not exercise the RC3 fixes. The corrective release path
now embeds RC3 as the persistent managed baseline so normal launches do not
depend on a marker.

| RC3 candidate field | Locked Host value |
| --- | --- |
| Source | `e9c5a8cbc0d5e730cc6422dfbaf6e79b9c310f4f` |
| Lab target | `com.qcxr.qcxr.canary262`, version `71` / `6.0.1-26.2-vivecraft-personal.12-rc.3` |
| Vivecraft Core | `26.2-1.3.15+qc.v71.rc3`, SHA-256 `14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26` |
| VEQ | `0.7.0-v70-canary.1`, SHA-256 `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B` |
| Pojlib AAR | `88696931` bytes, SHA-256 `D7FF9C3EE2CCB332F88DE9A44E40E5BDA38F390142DC64905AEFD720FC3ADED6`; two clean resource-release builds matched byte-for-byte |

The rebuilt RC3 Lab keeps `-Xms512M` and lowers automatic Xmx to a fixed
`1536 MiB` target/minimum while retaining `1024 MiB` native headroom. Manual RAM
settings remain hard-capped at `2048 MiB`. The checked-in Pojlib AAR was rebuilt
twice byte-for-byte with this policy; nondeterministic NDK GNU build-id notes
were omitted while the exact native-library hashes remain locked. The earlier
memory-retuned Lab APK passed package/version, signer, SDK, ARM64,
Vulkan/OpenXR, 16-KiB alignment and embedded-artifact gates. The newer exact
integrated APK `B8918144...9AD8F` has since passed its own audit and three fresh
startup/runtime smokes; the two new 90-minute memory soaks still remain
required before promotion.

Memory acceptance is still pending. The three short cold-start smokes do not
replace either required 90-minute soak. The first RC3 soak attempt was stopped
at `5.036` minutes when PSS reached `2481.24 MiB` and RSS reached
`2534.08 MiB`, crossing the process-memory guardrail. It does not count as one
of the two required soaks and prompted the automatic target reduction from
`1800` to `1536 MiB`. Android previously recorded two
foreground `LOW_MEMORY` deaths after approximately 67m38s and 64m13s, with
process sizes of about 2.78 GiB and 2.71 GiB respectively. The previous
launcher selected a 3168 MiB JVM heap with no ceiling. There is no static proof
of an unbounded
leak, so RC3 must pass two 90-minute soaks under the bounded JVM policy, with
no LMK/crash, a stable PID, PSS at or below 2.4 GiB, and post-warm growth at or
below 2 MiB/min before Stable promotion.

The first soak on the rebuilt `1536 MiB` policy also failed the guardrail and
was stopped without stopping the game. At `5.040` minutes the Lab PID, focus,
and `QuestCraft-JVM` were all still healthy, but PSS had risen from
`2364.46 MiB` to `2523.72 MiB`; `/proc` RSS was `1968.38 MiB` and swap was only
`18.64 MiB`. Graphics grew by only about `9.3 MiB`; most of the increase was
anonymous/unclassified memory. This attempt does not count toward either
required soak. Stable promotion remains blocked while that memory is
attributed and reduced without changing gameplay quality blindly.

## Current state

The current release is **v69 Stable, fully built and Host artifact verified,
then installed over the exact v68 package with same-signer `adb install -r`**.
The pulled installed `base.apk` hash matches the release APK exactly. The build
keeps the accepted Vivecraft, VEQ `0.7.0`, and eleven-mod payload and adds only
the accepted Launcher Camera Park policy. Unattended autoplay remains Lab-only,
and the unaccepted Idle Throttle change is absent.

The user manually accepted all required gameplay functions on the exact v69
Lab payload with Camera Park ON. Its three-pair A/B, three final samples, cold
starts, and 30-minute soak also passed. That evidence approved promotion of
Camera Park to Stable, but it is not evidence that the newly installed Stable
package itself ran: the Stable activity did not start while unattended after
installation. Therefore no post-install Stable cold-start, profile, eye,
controller, or soak claim is made yet.

The fail-closed Stable build gate is commit `b601c064`; Camera Park was
introduced at `90cad740`, hardened at `78b080e0`, and accepted at `640fdf5d`.
Unity `2022.3.62f3` returned exit code `0`. The final APK passed package,
version, SDK, ARM64-only, Signature Scheme v2, signer, 16 KiB ZIP alignment,
Vulkan/OpenXR, Vivecraft/LWJGL, all eleven managed mods, and four-identical-
manifest verification.

| Field | Locked value |
| --- | --- |
| Package | `com.qcxr.qcxr.dev262` |
| Label | `QuestCraft Vivecraft Personal 26.2` |
| Version | `69` / `6.0.1-26.2-vivecraft-personal.10` |
| Output | `QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-26.2-personal.10-local.apk` |
| Accepted gameplay source | `personal-v67-rc2.7-accepted` / `0174c883` |
| v69 build gate | `b601c064` |
| Camera Park | ON after successful XR handoff; `640fdf5d` accepted |
| Autoplay / Idle Throttle | Lab-only / omitted |
| Expected local signer | `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A` |
| Graphics/XR | Vulkan / OpenXR |
| Refresh policy | Runtime-owned; no application Hz or performance hint |
| APK SHA-256 | `05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034` |
| APK size | `126700777` bytes |
| Pojlib AAR | `88A172AF772E9DE600864831D617729E9F8E04DFBEB4BB30FC54B9F7407D6DD3` / `86970097` bytes |
| Vivecraft | `3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F` |
| VEQ release | `0.7.0` / `6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9` |
| LWJGL | `DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9` |

Exact artifact and mod hashes live in `STACK.lock.json`.

## Historical v68 package

The exact package replaced by v69 was versionCode `68`, versionName
`6.0.1-26.2-vivecraft-personal.9`, SHA-256
`0F218BB5542E90EA19E22E6763AE5A4D10995B6A2494439108385FC8DD2C00E1`.
Its Pojlib AAR was `86905783` bytes with SHA-256
`136AC1E2C788E06F720B87B5C5A9DF5C52D363F3F862928AD6934575656E3E51`.
Those hashes remain recorded under `runtimeEvidence.currentV68HostCandidate`
in `STACK.lock.json`; they are rollback/history values, not current v69 files.

## Historical v67 APK and accepted rc2.7 hot-deploy

The installed v67 APK is SHA-256
`021D153988265B39464F89C6CA6336302F14E9C4827950D9CB24EA7122A891F1`.
It embeds VEQ `0.7.0-rc.2.6`, SHA-256
`1E0019D2B9E0AED3B0D8F624C5A8608AF037548692D373C8876706792BEF73D3`.
It was assembled by the checked-in binary-preserving repack path from the exact
installed v66 APK because Unity was unavailable at that time; it must not be
described as a Unity-built artifact.

After that APK was installed, VEQ `0.7.0-rc.2.7`, SHA-256
`90D854125ACCBA23802D0FE7788A8C2FFBA24AA0CF90FBEC5A90DDB3DDE866E5`,
was hot-deployed and the user manually confirmed that the known problems were
resolved. That manual result belongs to the hot-deployed JAR, not to the
rc2.6 payload embedded in the v67 APK. The preserved rollback payload remains
the exact v66 content repackaged at versionCode 67 for safe `install -r`.

## v67 Host canaries (not Quest acceptance)

| Canary | Host purpose | SHA-256 |
| --- | --- | --- |
| `0.7.0-dev.1` | final-surface wrist pose and visibility | `099471108AC02B77EBED0C5D0ADB22B8BB2DB463F2062B174E195914BDEDF579` |
| `0.7.0-dev.2` | pointer, Creative and contextual-container contracts | `512110AB57FBC9B0F4972E545FBE8E765D8449EE33FBB39625F991BBBA7CD422` |
| `0.7.0-dev.3` | independent handed 98x98 Grip sessions | `9E255B0520C0A6AC165E498956C97FD10773B3FCFDE1182C8724561228E91440` |
| `0.7.0-dev.4` | per-hand world action routing and cumulative integration | `DA96F91807091DDE1432AA959BCBDF320BE08D8FD65020AB8A66DBAF99D00FF9` |

- The cumulative `dev.4` artifact is
  `exports/v67-canaries/VivecraftEssentialsQuest-0.7.0-dev.4+mc26.2-fabric.jar`,
  exactly 385566 bytes, built from HEAD
  `c771acffb5ad700ab80585bc1943ba4de9b9f374`.
- The Java 25 Vivecraft Fabric build passed, VEQ completed all 64 tasks, and
  `scripts/quest-veq-dev.ps1 -Action SelfTest` passed with
  `DeviceTouched=False`.
- These historical canaries were staged while the device was disconnected; none
  of their individual evidence is a Quest/runtime, controller, eye, soak or FPS
  result. RC1 now supersedes them and has separate evidence above.

## v66 completed gates

- The corrective Host suites and independent source review passed for the
  cropped VEP surface, asymmetric crop-to-quad Y mapping, full-quad fallback,
  carried-item ownership, and right-`B` handed input mapping.
- Unity produced versionCode 66 / personal.7. That historical APK is 126557121
  bytes with SHA-256
  `708962B958B8373B46231F8DA6C7B2AC284593BB30B291B46C68931FD1A3A70D`.
- Same-signer `adb install -r` passed without uninstalling or clearing app data.
- The one-shot authenticated launch reconciled Vivecraft to
  `917B75DA...5C85` and VEQ to `F59E7204...89FB`, loaded 70 mods, selected
  Adreno Vulkan, connected OpenXR, loaded GamerPotion's FPS Stress Test, and
  submitted at least 1200 frames. The only filtered startup error was the
  known non-fatal missing `libflite.so` narrator library. Controllers were
  inactive, so this is not a Wrist, `B`, both-eye, soak, or FPS acceptance.

## Historical v65 Host, build, artifact, and install gates

The following results belong only to the superseded v65 artifact. They are
retained for lineage and regression comparison; v65 was not a manually
accepted release and this evidence does not validate v66.

- Vivecraft's complete Host suite passes 43 tests, including the original bow,
  weapon pose, OpenXR handedness, runtime refresh policy, multi-surface overlay
  ownership, cursor/tooltips, and claimed-screen lifecycle.
- VEQ's clean `check build` passes 53 Gradle tasks. It covers the VEP inventory layout,
  carried item, Quick Actions persistence, unified feature settings, contextual
  container eligibility/lifecycle, deferred optional integration icons, per-hand
  Grip, and dual-hand input policy.
- Staged artifacts: Vivecraft
  `415394F749B12FD0121B4CAAA7FDF7FCF26306692CDBCAB1373438A3261CA356`,
  VEQ 0.5
  `766724914B2E3333E5BB3D4BE9BCDFD7B45728C2266152435EC8DF91A02A85A6`,
  and Pojlib AAR
  `A573E689D967059FD153BD8ECDF015393E9CD36D350D7E313367EC95A3E716A4`.
- Unity 2022.3.62f3 returned code 0. Independent verification passed package,
  version 65/personal.6, SDK 29/34, ARM64-only, APK Signature Scheme v2,
  expected signer, 16 KiB ZIP alignment, Vulkan/OpenXR payload, all eleven
  managed mods, and identical manifests. The final-P1 APK is 126527121 bytes
  with SHA-256 `EDF5A730E0F5FA1B333349C9D3029D6B4E2E32ACD097BD8C0604D009D4A6A7F0`.
- The installed base was pulled read-only and its signer matched v65.
  `adb install -r` succeeded, `firstInstallTime` stayed 2026-08-26 02:30:51,
  and no uninstall, data clear, or account-file copy/read occurred.
- The selected final pre-install backup is
  `backups/v65-p1-final-preinstall-20260901-183844`; its manifest SHA-256 is
  `87871F3678214166C0F9C54EDADE134E7E6BC4199BDD60BE935A5BE1764B71C9`.
  Its complete saves archive is
  `F1818B61EB49540C96F3D0FD6C592E2CAFA6CF319580C12C6FAF7339AFCC06B2`.
- The one-shot authenticated autoplay gate reconciled all eleven physical JARs,
  loaded 70 Fabric mods and VEQ 0.5, selected the Adreno Vulkan backend,
  initialized Vivecraft OpenXR with LEFT/RIGHT passes, entered FPS-Stress-Test,
  and submitted at least 4800 frames before the soak without a fatal,
  MixinApply, or Linkage
  error. Controllers were inactive; this is not a manual interaction or FPS
  acceptance result. The missing Android `libflite.so` narrator warning is
  non-fatal and unrelated to VEQ.
- An intermediate build exposed an early-start `Components not bound yet`
  exception while resolving optional Xaero icons. That candidate was rejected.
  Commit `1736ec2e` now resolves and caches those icons only after Minecraft
  components bind; the corrected APK above passed world startup and is the only
  v65 artifact that passed that historical unattended startup gate. This did
  not make v65 an accepted release.
- Three focused P1 commits (`fc337250`, `cc925efa`, `a4a86d43`) make pointer
  cancellation transaction-free, retain one exact carried-stack owner without
  stealing the other hand, clear Creative/Loom/Stonecutter/Merchant drag
  latches, and fail closed for unknown container release overrides. Java 25
  clean checks pass all 53 tasks. Independent source/bytecode review reports
  zero remaining P0/P1 in this scope.

## Historical v63 completed Host, build, and artifact gates

- Vivecraft and VEQ Host suites pass on Java 25 for the bow fix, wrist pose and
  cursor lifecycle, carried-item handling, handed Grip sessions, and owned
  offhand-use continuation.
- The staged Vivecraft artifact is
  `FD4023BA52A4D1E14532F126D4E3123048BF46BAC380CFAF9FC9D8972C305D85`.
  VEQ `0.4.0+mc26.2` is
  `E9AC2FC0A91083D3DE461F207F4FE9F864730CC819A7ADA360B35DA07BA21F09`.
- All four Pojlib manifests agree on those versions and hashes. The rebuilt
  Pojlib AAR is
  `FA626CC955B3F0D255B2922F086363C397633F009D7F199BB090715BA6255714`,
  and its embedded manifests and mod payloads match the staged files.
- Unity `2022.3.62f3` built
  `QuestCraft-Vivecraft-26.2-personal.4-local.apk`. Independent artifact
  verification passed package `com.qcxr.qcxr.dev262`, code `63`, name
  `6.0.1-26.2-vivecraft-personal.4`, min SDK 29, target SDK 34, ARM64-only,
  APK Signature Scheme v2, signer `B9BC1922...D4CA1A`, and 16 KiB ZIP
  alignment. The verified APK is `126380801` bytes with SHA-256
  `0A65715BCD20E64285014173BCE4714073925B691122434A70B81E39BE074A69`.
- `adb install -r` upgraded v62 to v63 with the same signer. `firstInstallTime`,
  the physical `26.2` data, and the preserved v62 rollback APK all remained
  intact; no uninstall, data clear, or account-file copy/read was used.
- The selected `mods/config/options/saves/Xaero` backup is recorded at
  `backups/v63-preinstall-20260901-0032`. The launch attempt reached the Meta
  Guardian/volumetric-placement gate before QuestCraft started. With the app
  stopped, Vivecraft and VEQ were then replaced atomically through the Android
  external-storage shell path after staging and hash verification. A final
  device-side audit matched all eleven physical JARs to `STACK.lock.json`, and
  temporary staging files were removed. This proves profile contents only; no
  runtime smoke, manual input, FPS, or both-eye acceptance is claimed yet.

## Historical v61 completed gates (not v63 evidence)

- Personal v61 Unity identity and CLI output contract are defined.
- Pojlib records `disabledMods` and validates every managed download before an
  atomic replacement.
- The staged Vivecraft artifact is
  `574C45923BA8EBB598B17F4E1D8641068590A619B4E9748597F9811FBE510FEE`.
  VEQ `0.2.0+mc26.2` is
  `1419CCFA78FF390EC38E2A448F1051365075D64A96CF94F6A2EA997C2CAA8A1E`.
- VEQ Host checks pass for the independent wrist overlay, VEP-style inventory
  layout, pointer-focus arbitration, schema migration, and compact 3x3 Grip
  grid.
- All four manifests contain the same eleven-component managed stack.
- Pojlib AAR
  `89CC26FCCD60ECA6A06091063D17E821F459B15D4102559FFFDD6A881CFEA7AB`
  and the final APK were rebuilt successfully.
- The final verifier passed package `com.qcxr.qcxr.dev262`, code `61`, name
  `6.0.1-26.2-vivecraft-personal.2`, min SDK 29, target SDK 34, ARM64-only,
  APK Signature Scheme v2, signer `B9BC1922...D4CA1A`, and 16 KiB ZIP alignment.
- A manifest/embedded-asset mismatch found during the first attempt caused the
  verifier to be strengthened. That attempt was rejected; only final APK
  `A5142D3C...F88198` is accepted.
- `adb install -r` succeeded with no uninstall or data clear. The physical
  profile reconciled to Vivecraft `574C4592...0FEE` and VEQ
  `1419CCFA...8A1E`.
- Wrist configuration migrated to schema 2 with `activationMode=VEP_AIM`, and
  the v1 backup was retained.
- Fabric Loader 0.19.4 loaded VEQ 0.2. Vulkan/OpenXR initialized `LEFT` and
  `RIGHT` targets, created the independent External Screen Overlay render
  target, started `FPS-Stress-Test`, reached 100% spawn, and submitted at least
  4200 frames. The filtered check found no fatal, Mixin-apply, or LinkageError.
- A PID-owned, fully focused 60-second compatibility sample contained 61 rows:
  mean `77.2` FPS, median `77`, and P10 `73`. The helper marked it
  `ValidForComparison=true`; raw logs were not persisted. This
  is not a gain claim or a measurement of the visible overlay's cost because no
  balanced v61 A/B exists.
- This unattended smoke is not a manual wrist/Grip/reverse-hands/eye claim.

## Previous v60 evidence
- The optional local quick-play helper is default-off, package/profile/save
  folder constrained, account-gated, exact-stack-hash-gated, two-phase,
  one-shot, visible for five seconds, and circuit-breaks after use. It targets
  profile `26.2` and save folder `FPS-Stress-Test`; it does not bypass login.
- The PID-scoped VrApi benchmark supports QGO Dynamic, keeps raw logcat only in
  memory, omits the device serial, and correlates stale frames with actual
  refresh transitions.
- The previous v60 Pojlib AAR was
  `EA1FD9281F4912B20804B7DB45BAED5F5E8478D4B022AB2C894F3A7B9CB8B917`.
- Unity `2022.3.62f3` built v60 successfully. APK inspection passed package/version,
  ARM64-only ABI, min SDK 29, target SDK 34, v2 signature, the existing signer,
  16 KiB ZIP alignment, and all embedded stack hashes.
- For the final VEQ `0.1.1` refresh, Pojlib was rebuilt with Unity's bundled
  OpenJDK and the generated Unity Android project completed Gradle
  `assembleRelease`. The original low-disk export attempt was not treated as
  success; only the independently verified final APK is locked here.
- `adb install -r` succeeded without uninstalling or clearing data. The launcher
  reconciled the `26.2` profile, loaded the benchmark world, and reached active
  Vulkan/OpenXR Dual-Pass with Vivecraft, the wrist add-on, ImmersiveMC, Xaero,
  and the candidate performance-mod set. No fatal, Mixin failure, or linkage
  error appeared; this combined smoke is not a per-mod performance acceptance.
- The final `0.1.1` wrist-settings candidate was then installed with the same
  signer and reconciled in place. The physical Quest profile hashes matched the
  locked Vivecraft and VEQ artifacts, Fabric loaded VEQ `0.1.1`, the integrated
  `FPS-Stress-Test` server started, and OpenXR submitted at least 600 frames
  while the filtered log matched no fatal, Mixin-apply, or linkage error. The
  headset was at `50 C`, so this was deliberately one compatibility smoke, not
  a performance or cold-start revalidation.
- The three 60-second samples, 20-minute soak, Perfetto trace, rejected OpenXR
  A/B tests, and three cold starts below belong to the immediately preceding
  v60 measurement baseline: APK `72AC7664...2081F`, VEQ `CE07FE18...F9C78`,
  and Pojlib `5BFCAC4C...9D068`. They remain useful lineage evidence but are not
  attributed to the final APK `1A40872C...F5A4A`.
- The separate Visor rollback remains installed and stopped as
  `com.qcxr.visor.dev262`, version `59` / `6.0.1-26.2-visor.3-perf.2`. A
  root-assisted read-only hash of its installed base APK matched
  `F5AB99F1...C5B69B`; neither its profile nor its data was changed.
- Three one-minute QGO Dynamic samples were PID-owned and fully focused. Their
  P10 application FPS values were `70`, `71`, and `72`; app GPU P95 was about
  `6.1 ms`, CPU/GPU levels were `4/4`, and temperature remained `43 C`.
- A later 20-minute stationary soak completed with 1,201 exact-PID samples,
  mean `73.81` FPS, median `73`, and P10 `71`. Root-assisted Perfetto was used
  for measurement only and found several short render-thread scheduling waits;
  it did not change affinity, priority, clocks, drivers, or Magisk settings.
- A one-variable OpenXR diagnostic-allocation canary was rejected. Exact-Hz
  matched stale delivery became `9.6%` worse (`3.721 -> 4.077` per second),
  while App and CPU+GPU P95 did not improve. Baseline v60 was restored with the
  existing signer and its Vivecraft hash was reconciled back to
  `200568FF0FB8555405EB69B3884FA96C0535477DEF6EB6B8AF988913336209DA`.
- The isolated `XR_KHR_android_thread_settings` renderer-thread canary also
  completed its runtime gate, but was rejected as a performance change.
  Exact-Hz matched stale delivery changed from `3.790` to `4.007` per second
  (`5.7%` worse), normalized FPS did not improve, and CPU+GPU P95 improved only
  `0.6%`, below the `2%` acceptance gate. Its hotter, non-randomized run order
  prevents blaming the extension itself, but it provides no evidence to merge.
- Three baseline cold starts entered the fixed benchmark world and retained the
  exact hashes of `options.txt`, Vivecraft, Sodium, and ImmersiveMC settings.
  Login data was neither read nor copied.
- A correctly packaged Array Dual-Pass APK passed host verification and an
  unattended Quest runtime smoke. The runtime reported one swapchain with
  `arraySize=2`, submitted frames in `array_dual_pass`, loaded the benchmark
  world, and showed no logged fallback or fatal. Its single 60-second sample
  was thermally/order confounded and the two eyes were not manually inspected,
  so it remains an isolated Canary and is not included in baseline v60.

## v69 Lab screening and Stable promotion (2026-09-03)

- During screening, Stable v68 remained untouched and every experiment ran
  only in `com.qcxr.qcxr.canary262`. After the user accepted the exact Lab
  gameplay payload with Camera Park ON, that single accepted change was
  promoted to v69 Stable; no other screened canary was promoted.
- Launcher Camera Park is the first v69 performance candidate to clear the
  primary Quest A/B gate. The implementation started at `90cad740` and was
  hardened at `78b080e0`; the final Lab APK is versionCode `69`, versionName
  `6.0.1-26.2-vivecraft-personal.10-rc.1`, SHA-256
  `0C4F73FB08FDF0584E6D0DD342813AA4D07A060BE090141C92BF3147E3CE9099`.
  Its Pojlib AAR is
  `24F9CA1E47D276D6672C738C371E91823C0DA86F22DC6D7C38BA2F9805670D90`;
  the v68 Vivecraft and VEQ payload hashes remain unchanged.
- In the initial three-pair 72 Hz / 42 C A/B, OFF averaged `70.34 FPS`, P10
  `68`, P95 CPU+GPU `14.71 ms`, and `4.89 stale/s`; ON averaged `71.51 FPS`,
  P10 `70`, P95 `13.61 ms`, and `2.26 stale/s`. That is `+1.66%` FPS,
  `+2.94%` P10, `7.48%` better P95, and `53.78%` fewer stale frames, with all
  three pairs passing the gate. A 30-minute pre-hardening ON soak held
  `71.8 FPS`, P10 `70`, P95 `13.54 ms`, and `1.64 stale/s`, with maximum
  temperature `42 C` and no crash.
- The hardened final candidate completed three valid 72 Hz / 42 C samples,
  averaging `72.13 FPS`, P10 `71`, P95 CPU+GPU `11.83 ms`, and `1.35 stale/s`.
  Three cold starts also completed the XR handoff with exactly three launcher
  cameras parked and the one-shot override cleared after each handoff. A final
  `OFF -> ON` cold sequence also proved that the explicit OFF override was
  cleared and did not leak into the next ON launch. The
  hardened 30-minute soak then held `72.16 FPS`, P10 `71`, P95 CPU+GPU
  `12.13 ms`, and `1.28 stale/s` across 1,801 samples. Refresh stayed exactly
  `72 Hz`, temperature fell from `42 C` to `41 C` (maximum `42 C`), and PID and
  focus coverage were both 100% with no crash or contaminating `tr` process.
  The user subsequently passed the manual Wrist/Grip/controller, both-eye,
  Home/recenter and gameplay gate on this exact Lab payload. This approved
  Stable promotion; it does not replace a post-install runtime check of the
  Stable package.
- OpenXR Input, History Rings, OpenXR Hardening, corrected VEQ Frame Snapshot,
  and the current Copy Batch implementation are not promoted. Input and VEQ
  could not reproduce their provisional signal under the Dynamic-refresh
  gate; the others regressed frame pacing or were directly dominated.
- Sodium `0.9.1` is not promoted. The conservative retained renderer is
  `0.9.2-alpha.4`.
- Lithium `0.25.3`, FerriteCore `9.0.0`, and BadOptimizations `2.4.1` remain in
  the stack. Removing them produced no eligible win; the fully matched Ferrite
  pair violated the FPS guardrail and worsened stable stale delivery.
- The original v69 Vivecraft Array Dual-Pass ON screens are **invalidated and
  excluded**. A stale rollback shell from the Lab harness left `tr` consuming
  about `91%` of one CPU core after the v1 OFF sample and throughout both the
  v1 and barrier-batched v2 ON samples. Their apparent regressions therefore
  cannot support rejection or promotion. The clean same-JAR v2 retest then
  produced two comparable 72 Hz pairs. Pair 1 improved stale delivery but
  failed the P10 guardrail; Pair 2 regressed FPS, P10, P95 CPU+GPU, and stale
  delivery. Across both pairs, ON changed FPS by `+0.19%`, P10 by `-2.38%`,
  P95 CPU+GPU by `-3.40%` (worse), and stale delivery by `+4.14%`. Array v2 is
  therefore rejected for v69. This is Array Dual-Pass work, not True
  Multiview evidence.

## Still required to close v69 Stable runtime evidence

1. Start the installed Stable package once and prove launcher reconciliation
   leaves VEQ `0.7.0`, the locked Vivecraft payload, and no stale development
   JAR. Installation and exact installed hash are already proven.
2. Re-run a short Stable-package both-eye and controller smoke. The exact Lab
   payload passed the user's full manual interaction gate, but that is not a
   post-install Stable-package runtime record.
3. If a complete Stable designation is needed, record three Stable cold starts
   and one supervised movement soak without changing the stack or QGO policy.
4. Keep OpenXR Input, History Rings, OpenXR Hardening, VEQ Frame Snapshot, Copy
   Batch, Array Dual-Pass, and Idle Throttle out of v69. They were rejected,
   inconclusive, or explicitly unaccepted as documented in `TEST_RESULTS.md`.
5. Retain the exact v68 mod set. None of the one-variable mod screens met the
   release gate for a replacement or removal.

The v69 full Unity build, APK artifact gates, same-signer replacement install,
and exact installed-root hash passed. General native-ELF compatibility and
post-install Stable runtime remain outside the current claim until separately
recorded.

## Local test helpers

- `scripts/quest-veq-dev.ps1 -Action SelfTest`
- `scripts/test-quest-veq-dev-transactions.ps1`
- `scripts/quest-veq-lab.ps1 -Action SelfTest`
- `scripts/test-quest-veq-lab-host.ps1`
- `scripts/test-quest-vivecraft-core-canary-transactions.ps1 -Harness VeqFrameSnapshot`
- `scripts/test-vivecraft-v60-manifest.ps1 -Action SelfTest`
- `scripts/run-vivecraft-local-autoplay.ps1 -Action SelfTest`
- `scripts/quest-vrapi-pid-benchmark.ps1 -Action SelfTest`
- `scripts/verify-dev-apk.ps1 -ApkPath <apk>`

Device-capable helper modes require explicit switches. None installs, uninstalls,
clears application data, edits the profile, or reads Microsoft credential files.

The v69 VEQ helper is additionally fixed to
`com.qcxr.qcxr.canary262` / `26.2`, reads
`VEQ_LAB_CANARY.lock.json`, requires an independently supplied SHA-256 plus
explicit device-write authorization for deployment, and permits only corrected
frame-snapshot commit `ee3f6144`. Commit `1047f873` is permanently blacklisted.
This is a Host-only harness result; no VEQ candidate deployment or Quest
acceptance is claimed.

## Current v70 Lab status (2026-09-04)

- Stable `com.qcxr.qcxr.dev262` remains unchanged and stopped.  All current
  work is confined to Lab `com.qcxr.qcxr.canary262`.
- The v70 Lab source head is `54b787ff`.  It contains player-follow native
  container placement (`a910b7d9`) and a GPU-direct idle Wrist pointer
  (`54b787ff`) on top of the retained Wrist surface work.
- The exact hot-deployed pair is Vivecraft
  `965FCC5EB860EC9CFA4865926FCCCA0F9FCF1DAA61327606A36736885392A30E`
  plus VEQ
  `39F3FF5537C44E0B4BE4AA5BD58590929F4196A720BFDF1A7A5FCF39FCEDA41F`.
  Both markers were consumed and the pair entered the benchmark world without
  a crash or XR failure.
- The first visible-Wrist screen is provisionally positive: at actual 72 Hz it
  averaged `67.71 FPS`, P10 `64`, `8.29 stale/s`, and `5.44 ms` app-GPU time.
  This is `+2.97%` FPS and `14.87%` lower app-GPU time than the previous
  confirmed Wrist interval.  Its within-run visible cost was `1.67 FPS` versus
  the nearest hidden rows, but the sample is too short for final promotion.
- Required before v70 promotion: a focused native chest test that proves
  movement, smooth follow, pointer alignment, and B/L2 behavior; then one
  repeat visible/hidden Wrist capture.  No further renderer rewrite is
  justified unless that repeat exceeds the two-FPS/two-percent gate.

## Superseded v71 pre-RC screen (2026-09-04)

- The active Lab-only source head is `f8689c63`.  It keeps the accepted v70
  UI/container work and adds B-close support for normal Inventory/Creative,
  negotiated independent hand attack cooldowns, physical-offhand attack-speed
  evaluation, a block-aware bow trajectory preview, and retained carried-item
  rendering for Wrist.
- The exact deployed pair is Vivecraft
  `CC2636DFE2E9FC143BDF7991B72BC4828934923E4AA603F618FAF8B2C907B800`
  plus VEQ
  `C53C81E1F7AF4E060D7537739456E7DBC5BFFD93FF6AEFE09F1EA7C1CA6C40DD`.
  Both one-shot markers were consumed and the pair entered the benchmark world
  on Vulkan/OpenXR without a crash or fatal error.
- The 60-second runtime screen was near the v68 reference in FPS/stale but was
  not a controlled A/B: `69.77 FPS`, P10 `66`, P95 CPU+GPU `15.84 ms`, and
  `4.62 stale/s` at `50 C`, with actual refresh varying between 72 and 75 Hz.
- Stable remains untouched.  Before promotion, the user must confirm the new
  B/left-axe/trajectory/Wrist behavior visually and the candidate must pass a
  counterbalanced fixed-refresh performance comparison.

## Current v71 Lab RC1 status (2026-09-05)

- Source is pinned at `f33647e5f5288b76c4fa50737bf08d207e3a1b59`
  on `feature/quest3-v71-dual-hand-bow`, with local tag `v71-lab-rc1`.
  Evidence is frozen separately at `67e9959640781b600d654772c3c8a2c0b6c1c4c3`
  under tag `v71-lab-rc1-evidence`.
  Stable `com.qcxr.qcxr.dev262` was not launched, installed over, or modified.
- The Wrist implementation is restored to the accepted `d92ad5c2` retained
  RGBA path, including live cursor and carried-item drawing through
  `renderPointerWithCarriedAbove`. Its known cost of about four FPS is accepted
  for this functional release; no newer Wrist optimization is present.
- The Lab pair is:
  - Vivecraft universal client/server JAR:
    `0661CB8877BD55B21C2A6D9F3759A66C74910F816934D4B8E72341C7946398D9`
    (`8,440,058` bytes).
  - Vivecraft Essentials Quest client JAR:
    `8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A`
    (`435,540` bytes).
- Host gates passed: all Vivecraft common tests, Fabric build, VEQ `check`, VEQ
  Fabric build, artifact identity checks, and the paired atomic deployment and
  rollback self-tests. Independent review found no P0/P1 blocker.
- The installed Lab base APK was independently pulled before deployment and
  verified as `com.qcxr.qcxr.canary262`, versionCode `70`, versionName
  `6.0.1-26.2-vivecraft-personal.11-rc.1`, ARM64, minSdk 29, targetSdk 34,
  v2-signed, and 16-KiB ZIP-aligned. It is the existing v70 Lab shell, not a
  newly built v71 APK. Its size is `126,701,141` bytes and SHA-256 is
  `B40988DFB668FEE151969395E82CCEFE38FDA4F89BBE081B79B88F1F24695102`;
  signer SHA-256 is
  `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`.
- Exact baseline rollback was proven before deployment. The two candidate
  markers were then armed, consumed by launcher reconciliation, and the exact
  JAR hashes above were observed in the physical `26.2` Lab profile.
- Runtime smoke passed: Minecraft 26.2 loaded 70 mods, Vulkan used the Adreno
  driver, OpenXR reached `FOCUSED`, submitted two views for more than 3,600
  frames, and the fixed `FPS-Stress-Test` world started. No new crash, ANR,
  Mixin failure, `LinkageError`, native fatal, or XR-session failure was seen.
  Retained nonfatal warnings were the optional narrator `libflite.so`, a Sodium
  target/workaround warning, and surface-extent configure warnings. Startup
  free memory was only about `0.2 GiB`, so this smoke is not a memory-stability
  or soak claim.
- A later aggregate-only 60-second Dynamic-refresh safety capture retained the
  exact PID and focus for 100% of polls and was valid: mean `74.93 FPS`, median
  `75`, and P10 `73`. It is one uncontrolled sample, not an A/B performance
  acceptance claim.
- Implemented in RC1: direct B-close for Inventory/Creative while retaining the
  container release gate; controller-resolved Y offhand attack/break; per-hand
  physical attack cooldown/item routing; same-block two-hand mining with
  different-target fail-closed behavior; negotiated Paired Strike; and the
  optional Off/Classic/Energy bow guide, defaulting to Energy.
- Paired Strike is active on the integrated server. A remote Fabric 26.2 server
  must run the exact universal JAR above to negotiate it. Old or Vanilla peers
  fail closed to ordinary Vivecraft behavior.
- This is still a supervised Lab canary, not v71 Stable. Manual headset checks
  remain required for Wrist/carried item, B-close, Y/physical left-hand attack,
  two-axe damage and durability, same-block mining, both-eye Energy Bow, and
  regression checks for shield, teleport, ImmersiveMC, Grip and reverse hands.
  No FPS, 20-minute Tailscale, three-cold-start, or 30-minute soak claim is made.
  In particular, startup/XR smoke did not prove that Y or the physical left hand
  used the offhand item; that requires the user's controller test.

## Current v71 Lab RC2 Host status (2026-09-05)

- RC2 source is pinned at
  `9b725fcacdd49846b87cf5c103df6768134b158a`. It adds the raw Quest-B
  Inventory/Creative close correction from
  `eb3018d126b872cf74638489cd0b7108b0713961` and the resource-pack-driven
  Energy Bow ribbon. Stable `com.qcxr.qcxr.dev262` remains untouched.
- RC2 is a JAR-pair candidate for the existing v70 Lab shell, not a new APK:
  - Core `26.2-1.3.15+qc.v71.rc2`: `10,062,636` bytes, SHA-256
    `AAC5852BD1495AA0121A078F87312A644608F209A9190AE539CDC4F7763CD8FC`.
  - Unchanged RC1 VEQ `0.7.0-v70-canary.1`: `435,540` bytes, SHA-256
    `8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A`.
  - Pair digest: `9952EA068712375E2364C0DF0EDBD9F876620D2E8EE10EF10106D6F6DEC6EBBE`.
  - Existing Lab APK: `126,701,141` bytes, SHA-256
    `B40988DFB668FEE151969395E82CCEFE38FDA4F89BBE081B79B88F1F24695102`.
- All `143` Vivecraft common tests passed with zero failures, errors, or
  skipped tests, and the Fabric RC2 artifact built successfully. Its bundled
  bow atlas is `1,620,298` bytes with SHA-256
  `971D0518655FCE01A692DBF5766CDA38273F09BB42EC71D971D0012A71C7360E`.
- Bow styles now load as validated immutable snapshots from
  `vivecraft:bow_guide_styles/classic.json` and `energy.json`. The ribbon uses
  the bundled atlas and the same first-pass trajectory snapshot for both eyes;
  resource packs can change presentation but not trajectory physics, damage,
  collision, or sample count.
- Three optional sample packs were copied to the Lab profile and remain
  disabled: Arcane
  `6F3607227BAF001AA46CD9B5FBE943C1194DE3683B5DBD0A88B03BEEEAC9E323`,
  Frost
  `3E09F7A76673B65979496DDE552CC067F8887AAA8DA1465DC1EC0323581580F6`,
  and Emerald
  `04D540115512ACFD62FC3CEE023B89BFAD07F9ADA524274925379128050B52F7`.
  They are under the Lab profile's `resourcepacks/` directory and must be
  enabled manually. They are absent from managed manifests, and `options.txt`
  still contains only `resourcePacks:["vanilla"]`.
- The exact lock is `V71_LAB_RC2.lock.json`. The guarded pair deployment
  consumed both one-shot markers and verified the physical Core and VEQ hashes.
  Lab then loaded Minecraft 26.2, the exact RC2 Core and unchanged VEQ, entered
  `GamerPotion's FPS Stress Test`, forced Vulkan on the Adreno 740, initialized
  OpenXR, and submitted stereo frames with `viewCount=2`. This is a runtime
  smoke pass only: B-close behavior, the bow in both eyes, manual pack switching,
  performance, cold starts, remote server, and soak acceptance remain pending.

## Lab launcher-logo hang correction (2026-09-05)

- A Lab launch remained on the QuestCraft logo before the JVM was dispatched.
  The Minecraft log did not advance and no native, Fabric, Vivecraft, or VEQ
  fatal was present. Device diagnostics found an active Singularity kill-switch
  VPN routing all traffic through `tun0` without DNS.
- Pojlib's Mojang metadata probe used an unbounded `HttpURLConnection`, so that
  network state could hold `prelaunch()` indefinitely. Commit `b32fc3ca` adds
  3-second connect/read timeouts, guaranteed disconnect, a 15-second
  synchronized monotonic result cache, accurate Mojang diagnostics, and the
  existing authenticated offline continuation. It does not bypass account or
  ownership checks.
- After only the kill-switch app was stopped and the stuck Lab process was
  restarted, the same physical RC2 pair launched Minecraft, loaded 70 mods,
  reached OpenXR `FOCUSED`, and continued stereo submission with `viewCount=2`.
  Stable, Tailscale, QGO, accounts, profiles, saves, and managed mod files were
  not changed.
- Host validation passed: 63 Pojlib unit tests and `assembleRelease`. A complete
  replacement Lab APK was built and verified but deliberately not installed
  while the user was playing. APK SHA-256 is
  `228301B630CC199666D6385F52533DFFCF9512242A6DF68F5021C6A4FFA74ABA`;
  embedded Pojlib AAR SHA-256 is
  `AB4AEA7B3AD831A4DD58CF9CDB6CFFC7B44F322F173D4AAEC36D943B8D072C47`.

## 2026-09-08 — Render scale remains 1.0; 0.8 rejected on frame pacing

The exact RC8 Lab completed a counterbalanced `6×180s` A/B campaign in the
fixed benchmark world at the device's observed QGO levels CPU `8` / GPU `7`.
The candidate changed only Vivecraft `renderScaleFactor` from `1.0` to `0.8`.
Under identical observed-refresh matching, the strict analysis was
inconclusive because two pairs missed the preregistered 50% overlap threshold.
The separately labelled 40% sensitivity analysis included all three pairs and
rejected 0.8: matched P95 CPU+GPU was `1.29%` worse and stale frames were
`53.83%` worse, while average FPS rose only `1.07%`.  All three pairs showed
more stale frames at 0.8.

The Lab is stopped and its original `1.0` configuration was restored
byte-for-byte to SHA-256
`EDC270B10B16AD35166565755E76BABB7A5A2F28635C7878DF43989778611E8E`.
Stable remained stopped and untouched; root was not used inside the captures.
RC8 therefore keeps render scale `1.0`, and no promotion decision follows from
this performance experiment.
