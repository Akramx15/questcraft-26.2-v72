# QuestCraft Vivecraft Personal 26.2 test results

## 2026-10-02 — v72 perfbase install and QGO runtime smoke PASS

- Exact APK: `QuestCraft-Vivecraft-26.2-personal.13-perfbase-cd079c65.apk`,
  `128500669` bytes, SHA-256
  `6748C17071B90ED5DC236FBA84CA3BBC4DEAED54C802D0150CFA82B20EFA3680`.
- Same-signer `adb install -r` returned success. Pulling the installed
  `base.apk` reproduced the exact release hash; versionCode/name were
  `72` / `6.0.1-26.2-vivecraft-personal.13`.
- Existing instance, options, managed-mod tree, configuration fingerprints,
  and first-install time were preserved by the replacement.
- The live launch used QGO Apply/Launch and verified CPU `4`, GPU `4`, fixed
  `72 Hz`, FFR `4`, and `1680x1760`. Minecraft 26.2 / Fabric Loader 0.19.5,
  Vulkan, focused OpenXR, and both eye passes were observed.
- A steady post-teleport window contained 43 VrApi samples: mean `70.14 FPS`,
  median `71`, P10 `63`; all samples reported target `72`, FFR `4`, and CPU/GPU
  `4/4`. No post-entry fatal, OOM, access-denied, Mixin-apply, or crash marker
  was found.
- This proves installation and a live runtime smoke, not a controlled
  v71-versus-v72 performance gain. The latest code change documented for this
  source line includes `968cace5` and a later asset-index self-heal that is not
  in this `cd079c65` APK.

## 2026-09-11 — v72 Seed-Only Host gates PASS; device gate pending

- Seed-Only source review passed after closing concurrent profile creation,
  download-time filename races, legacy-path ambiguity, partial dependency
  installs, missing-artifact metadata, and rollback paths.
- `gradlew test` passed Debug and Release suites. Two clean
  `testReleaseUnitTest assembleRelease` runs produced the identical Pojlib AAR:
  `88751133` bytes, SHA-256
  `64B27CF1D89B506A0A203C7FC81D8E0DFE0916DCC103B649D16C18A8CEFDCF38`.
- Nested JNI descriptors for batch add, installed-artifact lookup, and remove
  match the Unity C# call sites. Embedded root/asset manifests are identical.
- Unity 2022.3.62f3 completed successfully. APK:
  `QuestCraft-Vivecraft-26.2-personal.13-local.apk`, `128492965` bytes,
  SHA-256 `DFC2A264432D44AD6D0D2A13023DF17BA03BE341C5FA74BBBD9A0D043C2A94A7`.
- APK verifier passed package `com.qcxr.qcxr.dev262`, label `Vivecraft Stable`,
  versionCode `72`, versionName `6.0.1-26.2-vivecraft-personal.13`, min/target
  SDK `29/34`, ARM64-only, current Debug signer, v2 signature, 16-KiB alignment,
  Vulkan/OpenXR payload, Core `ADDB01FA…15EAB`, VEQ `FF7F6FCF…573F9`, LWJGL
  `DD19A303…A4DC9`, and an identical 11-entry 26.2 manifest pair.
- Device install/runtime was pending because the recorded Wi-Fi ADB endpoint
  was offline; no Stable package, profile, account, world, setting, or mod file
  was changed.

## 2026-09-08 — exact RC8 Perfetto diagnostic: healthy aggregate PASS

- Exact identity gates passed before, during, and after capture: Lab package,
  APK `A8E36463…2416`, Core `ADDB01FA…5EAB`, VEQ `FF7F6FCF…73F9`, fresh PID,
  immersive multi-display focus, explicit Windows USB transport, and stopped
  Personal Stable.
- The 29.984-second trace reported zero ftrace setup errors, dropped events,
  overruns, data loss, and buffer overruns. This supersedes the earlier
  diagnostic trace for scheduler interpretation; the earlier trace remains
  retained as an explicitly unhealthy control because it had four setup
  errors.
- Aggregate app CPU was `30127.853 ms` (`100.481%` one-core equivalent), with
  `3425.027 ms` aggregate runnable wait (`11.423%`). The dominant thread used
  `64.742%` of one core; its runnable P95 was `0.070 ms` and maximum `4.571
  ms`, so this sample does not indicate broad starvation of that thread.
- Fixed categories used G1 GC `10.011%`, Sodium async `7.563%`, server
  `4.935%`, OpenAL `3.741%`, Unity frame pacing `2.057%`, and Unity runtime
  `1.330%` of one core. GPU memory averaged `810.731 MiB` and P95 was `810.883
  MiB`; KGSL submitted/retired counts were `19978/19977`.
- Only `aggregate.json` remains. Host temporary files and matching Quest
  `/data/local/tmp` files were independently verified absent; raw logcat,
  callstacks, network, file-I/O, account, world, and server data were not
  retained. Root was used only for the permitted read-only trace path.
- Aggregate path:
  `artifacts/perfetto/rc8/capture-20260908T000815Z-627569d2/aggregate.json`;
  size `30974` bytes; SHA-256
  `2ADA9EF869D866A4274FA5DA6342CF9B12A2FB4A78E830249E99AE70DD2F041D`.

**Decision:** use this only to prioritize a one-variable OpenXR allocation
A/B. It is not an FPS sample, does not accept the candidate, and does not
permit Stable promotion.

## 2026-09-07 — RC8 post-build input audit: Host PASS; manual RT pending

- The complete VEQ `:mod-core:check` suite passed on Temurin `25.0.4.1`
  against the exact locked RC8 Core asset. This includes the new
  `RightTriggerOwnershipRecoverySelfTest` and all existing Wrist, Grip,
  dual-hand, container, and Quest-binding checks.
- `scripts/test-v71-rc8-current-mining-host-audit.ps1` now pins both reviewed
  post-build mining test files and the exact Gradle test registration by
  SHA-256. The audit passes while proving that runtime sources, the locked APK,
  default install/rollback/capture safety, and the Stable boundary did not
  change.
- The independent diagnostic runner remains Host-only by default and passes
  its Fake-ADB suite with zero ADB invocations. It is not installed while the
  ordinary RC8 candidate is running.
- Static tracing finds no confirmed break in the ordinary path
  `Quest RT -> keyMainAttack(RIGHT) -> keyAttack -> Vanilla start/continue`.
  The remaining evidence gap is a real controller observation on Quest; the
  manual result stays `PENDING_USER_OBSERVATION` and Stable promotion remains
  prohibited.

## 2026-09-07 — RC8 read-only memory windows: capture PASS, absolute gate FAIL

- Exact RC8 Lab identity passed at the start and end of both captures; every
  PID/process-start/JVM fence passed. No Android write, target callback/GC,
  root, Stable query, raw log, or raw map was used.
- Window 1 (`11` samples / `10.022` minutes): total PSS
  `2937.62 -> 2964.14 MiB`, OLS `+3.15 MiB/min`; Native Heap accounted for
  `25.97 MiB` of the `26.52 MiB` increase.
- Window 2 (`11` samples / `10.028` minutes): total PSS
  `2973.06 -> 2981.08 MiB`, range `2973.06–3003.83 MiB`, OLS
  `-0.33 MiB/min`; Native Heap OLS was `+0.06 MiB/min`. GL/EGL/Gfx-device
  categories were flat.
- Combined observed span: `22` samples over `23.97` minutes. The high absolute
  plateau violates the prior `2.4 GiB` ceiling, while the flat second window
  means a continuing leak is not proven.
- Decision: `HIGH_PLATEAU / LEAK_NOT_PROVEN / ABSOLUTE_GATE_FAIL`; no runtime
  patch or Stable promotion. Exact sanitized receipt hashes and category
  summaries are pinned in `V71_RC8_MEMORY_RUNTIME_RESULT.lock.json`.
- The collector's real-device argv and Android-summary parser corrections now
  pass its SelfTest (`1339` assertions) and complete Host/Fake-ADB suite.

## 2026-09-07 — v71 RC8 Lab install/runtime: PASS; manual mining PENDING

- Guarded Lab-only install: `INSTALLED_AND_VERIFIED`; package/version/hash and
  signer matched the RC8 lock; Stable touched: `false`.
- Authenticated Quick Play launched profile `26.2` and entered
  `FPS-Stress-Test`.
- Fresh runtime snapshot: Minecraft `26.2`, Fabric Loader `0.19.4`, exact RC8
  Core and frozen VEQ, Vulkan, connected OpenXR, successful projection frame,
  and no fatal marker.
- The optional missing `libflite` narrator library is a handled Android startup
  warning. Verifier commit `15fcb132` accepts only that tightly bounded
  narrator block and continues to reject an `UnsatisfiedLinkError` elsewhere;
  its Host suite passes `16` negative fixtures.
- Receipt: `artifacts/runtime/v71-rc8-launch-20260907.json`. Raw runtime log was
  not retained.
- Read-only live config gates were `seated=false`, `aimDevice=CONTROLLER`,
  `reverseHands=false`, and `weaponCollisionNew=ON`. Those values rule out a
  seated/HMD-aim configuration regression but do not establish mining success.
- The current-state Host audit passes and proves the APK/runtime bytes did not
  drift after integration; it also keeps manual mining explicitly pending.

Manual RT/Y/controller behavior is not inferred from startup evidence and is
still pending. Stable promotion remains forbidden.

Contingency work was also checked on Host without device mutation. The
diagnostic branch completed at `d22b3f78`: its distinct versionCode `72` Lab
APK passed package, signer, ARM64, SDK 29/34, Vulkan/OpenXR, V2 signature and
16-KiB alignment checks. The APK is `128470289` bytes with SHA-256
`D278D59D48B416A97A4E092C38B4036A28E1B42092E2E355D5AD0B91E8641D76`.
Two clean Pojlib builds matched byte-for-byte at SHA-256
`2775D004A1E3F4A790B9AD479F554D9018AA79732A24F46CF516BD1611B177DD`.
It remains uninstalled and runtime-unvalidated. Defensive fallback commit
`6c30c1c8` passed `73` Gradle tasks, but is held back unless runtime evidence
proves `keyMainAttack` inactive or unbound; the ordinary RC8 candidate remains
the test subject.

Safety-tool regression also passes: exact RC7 Lab rollback rejects `11` fake
device/signature/process/post-install failures, while freshness-bound RC8 log
capture rejects `12` fake PID/inode/time/path/verifier failures and proves the
raw log is deleted. Default audits return Host-only PASS with zero device calls
and `StableTouched=false`.

The optional diagnostic classifier also passes Host-only: eight valid
transition scenarios classified, twelve malformed or unknown inputs rejected,
zero device calls, and no raw or sensitive values in its result.

## 2026-09-07 — v71 RC8 native-main mining correction: Host PASS, Quest PENDING

RC7 (`1ddd7bf2`) intercepted the native `startDestroyBlock` and
`continueDestroyBlock` calls for ordinary RT mining. The subsequent headset
test reported that blocks could not be broken. RC8 removes both wrappers and
leaves Vanilla responsible for main-hand session creation and progress; only
same-block offhand contribution and coordinated release remain custom.

| Candidate field | Audited value |
| --- | --- |
| Source / integration / artifact commits | `4d908ffe` / `35c0e373` / `e1b19c73` |
| Lab identity | `com.qcxr.qcxr.canary262`; `71`; `6.0.1-26.2-vivecraft-personal.12-rc.8` |
| Vivecraft Core | `10078822` bytes; `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB` |
| Frozen VEQ | `444150` bytes; `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9` |
| Pair digest | `F8AB021283B027CC29463E0FBADD1DA3688C74B11EFA95334BA650EB853C60AB` |
| Pojlib AAR | `88734979` bytes; `F4A7683C1C9376BA2626B2C7527878A4D47534A744227955C3BDC16A9B5A211B` |
| Lab APK | `128469341` bytes; `A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416` |
| Signer | `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A` |

Host evidence:

- Vivecraft `:common:check` and Fabric build passed. After the test-only
  coverage commit `c3781fb4`, the JUnit result is `48` suites / `194` tests,
  zero failures, errors or skips. The added cases cover native RT plus Y in
  one tick, native RT surviving Y release, different-target rejection without
  taking Vanilla ownership, and physical offhand dedupe. No runtime artifact
  bytes changed.
- VEQ Java 25 `clean check :mod-fabric:build` passed against the exact RC8
  Core. Its registered source/behavior contracts include native RT ownership,
  offhand same-target routing and reverse-hands separation. Two clean VEQ
  builds matched byte-for-byte.
- Pojlib tests and release AAR build passed: `33` suites / `143` tests, zero
  failures, errors or skips. Two clean AAR builds matched byte-for-byte.
- `scripts/test-build-v71-lab-rc8-host.ps1` returned `PASS`, `HostOnly=True`,
  `DeviceInvocations=0`, and `StableTouched=False`. It also proved the build
  rejects missing explicit authorization and pins the Lab package while
  denying the Stable package.
- The APK verifier passed exact package/version and embedded payload identity,
  ARM64-only, minSdk `29`, targetSdk `34`, required Vulkan/OpenXR libraries,
  v2 signing, signer identity and 16-KiB alignment.
- The two clean Core builds were not byte-identical. This does not invalidate
  the one locked JAR, but no general Core reproducibility claim is made.
- Independent review found one P2 in the initial correction: RT plus a physical
  main-hand collision could contribute twice in one tick. The passive native
  intent added at `4d908ffe` deduplicates that path without owning or replacing
  Vanilla start/continue. No runtime conclusion follows from the review.

The Host tests enforce these invariants: RT stays native; Y/offhand may join
only the same active block; either hand can keep that session alive after the
other releases; both released permits stop; a different target is rejected;
and reverse-hands Y is not pre-claimed as native RT.

**Decision: Host PASS; Quest/runtime/manual validation PENDING.** The APK has
not been installed or launched as part of this result. Required supervised
tests are RT-only, Y-only, simultaneous RT+Y on one block, release-right-first,
release-left-first, different targets, RT plus physical swing, reverse hands,
survival progress/finish and a basic both-eye/controller regression. No FPS,
soak, server, controller-feel or gameplay acceptance is claimed. Stable
promotion is explicitly disallowed and `com.qcxr.qcxr.dev262` remains
untouched.

## 2026-09-07 — exact v71 RC6.2 tight-space Lab result and manual acceptance

| Candidate field | Audited value |
| --- | --- |
| Lab identity | `com.qcxr.qcxr.canary262`; `71`; `6.0.1-26.2-vivecraft-personal.12-rc.6.2` |
| Lab APK | `128459705` bytes; `ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4` |
| Vivecraft Core | `26.2-1.3.15+qc.v71.rc6.2`; `6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF` |
| Frozen VEQ | `0.7.0-v71.rc6`; `BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD` |
| Pojlib AAR | `88724129` bytes; `6B9224C6697D00DCE363AD80EA5FA9946E90808C514517BA4EEDFEB31DB2BA89` |
| Signer | `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A` |

- Artifact verification passed package/label/version, SDK 29/34, ARM64-only,
  Vulkan/OpenXR, v2 signing, 16 KiB alignment, embedded byte equality, manifest
  parity and duplicate-mod checks. Stable was not touched.
- Fresh post-manual Host regression: `45` Vivecraft suites / `167` tests, zero
  failures, errors or skips. VEQ remained byte-frozen from RC6.
- VEQ Java 25 `check` and `:mod-fabric:build` passed with output JAR
  `BF7857E4...0F70FD`; Pojlib `test` and `assembleRelease` passed with AAR
  `6B9224C6...2BA89`; the exact RC6.2 APK verifier passed for
  `ED810E5A...FA3D4`.
- The additive Host receipt is
  `artifacts/host/v71-rc6.2-post-manual-host-regression-20260907.json`, SHA-256
  `D40E03D3EE5E934055A5C5600F936B5EF811723E335E99FB1816AD816E6D70DA`.
  It binds tested source `baa7d973` and the immutable build/runtime locks and
  manual receipt without modifying the accepted payload or runtime result.
- The legacy manifest verifier was rebound from the stale RC5 lock to the
  immutable RC6.2 lock; it now passes all four manifests and all `11` managed
  mods without changing runtime payload bytes.
- Shield/Wrist and Grip/tunnel are separate fixes. Wrist suppresses only its
  anchor-hand shield render snapshot while visible; Grip alone is
  `ALWAYS_VISIBLE` and is routed through `VrUnoccluded` in Fabulous mode.
- Exact runtime identity, launcher resource release, Vulkan/OpenXR world start,
  focus and submitted frames passed. The current saved player-self setting was
  observed as `shouldRenderSelf=false`.

### 30-minute runtime safety screen

| Metric | Result |
| --- | --- |
| Receipt | `artifacts/benchmarks/v71-rc62-live-readonly-01.json`; `BFA4632EDF153BE01E91E08EEA42339108A808FAF949BD9608597A22C7C1DE78` |
| Duration / samples | `1800.79s` / `1801` |
| FPS | mean `87.19`; P10 `85` |
| Frame time | P95 App `4.84ms`; P95 CPU+GPU `11.06ms` |
| Stale | `0.77/s` |
| Temperature | maximum `44C` |
| Runtime policy | Dynamic `73–94Hz`, mode `87Hz`; CPU mode `2`, GPU mode `7` |

This capture is valid for safety/stability only. It has no paired predecessor,
so it proves no performance improvement and makes no QGO 4/4 claim.

### Exact memory soaks

| Run | Identity / process | PSS / VmRSS max | Swap max | Min available | Slope / last 30 | Formal |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `19/19`, stable | `3275.992 / 2322.660 MiB` | `0.059 MiB` | `1514.914 MiB` | `0.134 MiB/min`; `+7.955 MiB` | `FAIL` only on absolute PSS |
| 2 | `19/19`, stable | `3172.923 / 2231.746 MiB` | `1.980 MiB` | `1645.520 MiB` | `0.308 MiB/min`; `+7.828 MiB` | `FAIL` only on absolute PSS |

- Run 1 summary/samples hashes:
  `140ABC18A9F10E9229D8B77A2A41B63883AE9E054B71E32CCDBC326FD4DAF9E9` /
  `4BD29B858AFBDBBCA28339035E265DCD761C4712BB5FAF301FEAA21584D9B30D`.
- Run 2 summary/samples hashes:
  `1E5C8EBA2E0B8CB86B9233E731CF88F25902DBA35FE79B72B0493C370CA18FE9` /
  `C0F87D3B65BEACE3137BC2FCF0F503ED44114D55F8A0A170D5A14224FC487D09`.
- Both runs kept the same PID, focus, game JVM, expected fresh log identity and
  thermal status. Maximum temperature was `43C`; no safety stop ran.
- The independent Host-only pair receipt is
  `artifacts/memory/v71-rc62-pair-supplementary.json`, SHA-256
  `3C73CDB3DDD89C338BC001E6FC6C72F69B5158CD7F24C0D9481625D3587FD4C0`.
  It reports `LEAK_STABILITY_PASS` for both runs while preserving the producer
  and absolute `2457.6 MiB` PSS results as `FAIL`.
- `V71_RC6_2_RUNTIME_RESULT.lock.json`, SHA-256
  `A0B37CCAAA67E0D0E4BA7C4E5CA80745707958F26B113638ABDEFB264788770C`,
  binds the APK/Core/VEQ/AAR/signer, runtime screen, both soak input pairs and
  the supplementary receipt. Its fail-closed Host verifier and six negative
  fixtures pass without a device command.

The current runtime log included optional LunarLabs. Its near-flat `~1207 MiB`
Graphics allocation and historical `~780 MiB` vanilla observations suggest a
large fixed texture/resource contribution, but pack state was not embedded in
the memory receipts and this was not a controlled same-build A/B. The optional
lossless pack canary (`D80AA4F...C66`) remains Host-only and uninstalled; its
`4.43 MiB` source-sheet saving cannot be presented as a GPU-atlas saving.

The user then tested the exact RC6.2 Lab candidate and confirmed the requested
standard-hand interactions passed: the shield hides only while Wrist is shown,
blocking/inventory state is unchanged, the shield returns when Wrist closes,
and Grip remains visible and selectable with both hands inside the 1x1 tunnel.
Receipt:
`artifacts/manual/v71-rc6.2-user-acceptance-20260907.json`, SHA-256
`C321B3CDE43807D68C8A6C8C942FF92FEE2DA046B90FA2F09F1664914CABA12E`.
Reverse hands was not observed in this run and is not claimed. The user also
removed the server-specific LunarLabs pack from scope; its existing Host
artifacts are historical only and will not be installed, activated, optimized,
benchmarked or bundled into a release.

**Decision:** runtime/stability screen passed; performance improvement is not
claimed. Required standard-hand manual interaction passed. Formal memory
acceptance remains `FAIL`; supplementary leak stability and manual interaction
do not override it or permit Stable promotion. Reverse hands remains unclaimed.

## 2026-09-07 — exact v71 RC5.2 prelaunch-gate Lab Host gate PASS

| Candidate field | Audited value |
| --- | --- |
| Lab identity | `com.qcxr.qcxr.canary262`; `71`; `6.0.1-26.2-vivecraft-personal.12-rc.5.2` |
| Lab APK | `128439489` bytes; `AAD1B8F94DE7D4F65BF481CE65FCA83FAFFC7B0961435E95EF3F1899CF038879` |
| Unchanged Core | `10064652` bytes; `494BC1CB9CED37C4F2193704CDA1ED4B4F3461DDFB5E75A1C3475D0124159F00` |
| Unchanged VEQ | `441660` bytes; `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B` |
| Pojlib AAR | `88706771` bytes; `5CBC6468A4E2CB4F98CB8BBE005C387AEA12E9AD43360BA5CA76167DC86D470A` |

- The ownership prelaunch gate executes before the connectivity branch, so its
  safety decision is independent of online/offline state.
- A failed, unverifiable, oversized, symlink, or non-regular-file repair fails
  closed before JVM launch; absent and already-writable files remain no-ops.
- Two clean Pojlib builds matched byte-for-byte. `24` result files contained
  `116` tests with zero failures, errors, or skips.
- The integrated artifact audit passed, and the Host build did not touch Stable
  or perform any Quest/device action.

Decision: **Host accepted only.** RC5.2 runtime identity binding, native-menu
manual behavior, lifecycle, performance, and soak are pending. RC5.1 runtime
observations cannot be reused because RC5.2 is a distinct APK/Pojlib identity.

### Optional LunarLabs pack — RC5.1 load evidence and benchmark boundary

| Pack field | Observed value |
| --- | --- |
| User-supplied source | Original archive supplied outside the repository |
| Compatible derivative | `LunarLabs-26.2-Quest-Vulkan-v2.zip`, staged outside the repository |
| Derivative SHA-256 | `227FF427604E4503BAF06A9766977EB7F926841A4325428069A40DC21FCB67D8` |
| Compatibility changes | pack format `88`; Minecraft 26.2/Vulkan shader-import adjustment |
| Lab destination | `/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/resourcepacks/LunarLabs-26.2-Quest-Vulkan-v2.zip` |

- The RC5.1 device-side archive hash matched the derivative hash exactly.
- The RC5.1 game log explicitly reloaded
  `file/LunarLabs-26.2-Quest-Vulkan-v2.zip`; the prior shader-uniform and
  incompatible-pack failures were absent.
- The pack remains optional and unmanaged. It is not part of the Pojlib mod or
  resource-pack manifest and does not establish an RC5.2 runtime result.
- An uncontrolled pack-on observation was about `+0.9 GiB` fixed PSS versus
  the prior baseline. It showed no measured growth pattern, but the observation
  is insufficient to claim either a leak or no leak.
- Performance A/B is valid only when both samples use the exact same pack state;
  pack-on and pack-off results must be reported as separate comparisons.

## 2026-09-07 — exact v71 RC5.1 ownership-repair Lab Host gate PASS

| Candidate field | Audited value |
| --- | --- |
| Lab identity | `com.qcxr.qcxr.canary262`; `71`; `6.0.1-26.2-vivecraft-personal.12-rc.5.1` |
| Lab APK | `128437825` bytes; `F53A3AED167AF2396B498F030862C01F5590C63C9E80ABE7C0D786AC5EA95EA2` |
| Unchanged Core | `10064652` bytes; `494BC1CB9CED37C4F2193704CDA1ED4B4F3461DDFB5E75A1C3475D0124159F00` |
| Unchanged VEQ | `441660` bytes; `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B` |
| Pojlib AAR | `88703720` bytes; `9B8039685C0012B6FB103C0BC79325C59626AA966C8279C8DEC10B05827E40D5` |

- Two clean Pojlib builds matched byte-for-byte; `22` result files contained
  `110` tests with zero failures, errors, or skips.
- Ownership repair tests cover absent/writable no-op, exact byte preservation,
  atomic fallback, both rollback paths, and oversize rejection.
- Manifest, build-gate, package/version, ABI, SDK, Vulkan/OpenXR, signature,
  16 KiB alignment, embedded payload, and Lab DEX gates passed.
- Host-only boundary: zero ADB calls and no Stable, live `options.txt`,
  `resourcepacks`, or user-data mutation.

Decision: **Host accepted for supervised RC5.1 Lab installation only.** Runtime,
performance, lifecycle, and Stable promotion remain pending and must not reuse
the already runtime-tested RC5 APK identity.

## 2026-09-07 — exact v71 RC5 persistent Lab Host gate PASS

| Candidate field | Audited value |
| --- | --- |
| Lab identity | `com.qcxr.qcxr.canary262`; versionCode `71`; `6.0.1-26.2-vivecraft-personal.12-rc.5` |
| Lab APK | `128430965` bytes; `4F3908599D8236A3A617EF8634C4BB2B39BDBFB3A10D2EF33C7FE00B97355661` |
| Vivecraft Core | `26.2-1.3.15+qc.v71.rc5`; `10064652` bytes; `494BC1CB9CED37C4F2193704CDA1ED4B4F3461DDFB5E75A1C3475D0124159F00` |
| Frozen VEQ | `0.7.0-v70-canary.1`; `441660` bytes; `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B` |
| Core/VEQ pair | `5B4ADB12406108D74D3F3E592857B419DD893BD3522898B06BDCF17B0F6126BB` |
| Pojlib AAR | `88697676` bytes; `4B89F803396EC8D0587187B90C15405F664D63B045FBE30C4FA9E0712675ECE6` |

- Two clean Pojlib `assembleRelease` outputs matched byte-for-byte.
- Pojlib release unit tests: `21` result files / `102` tests / `0` failures /
  `0` errors / `0` skipped.
- Manifest persistence test and the RC5 build-gate self-test passed.
- The APK audit passed SDK 29/34, ARM64-only, Vulkan/OpenXR, v2 signature,
  16 KiB alignment, exact managed payload hashes, manifest parity, and Lab DEX.
- The build was Host-only: `0` ADB invocations, no Stable mutation, and no
  access to `options.txt`, `resourcepacks`, or user data.

Decision: **Host build accepted for supervised Lab installation only.** Exact
game-log binding, Quest interactions, performance, cold starts, soak, and
Stable promotion are not claimed. RC4 artifacts and receipts remain historical
and immutable.

## 2026-09-06 — exact v71 RC4 first memory soak PASS

- Duration/samples: `90.072 minutes`, `19/19` complete samples.
- Runtime binding: exact RC4 APK/Core/VEQ, same PID/process incarnation, Lab
  focused, game JVM alive, and launcher resource-release marker bound at start.
- Memory: max PSS `2372.301 MiB`; max RSS `1800.395 MiB`; max process swap
  `26.633 MiB`; minimum MemAvailable `2069.504 MiB`.
- Shape: post-warm PSS slope `0.245 MiB/min`; final 30-minute growth
  `3.074 MiB`.
- Summary: `artifacts/memory/v71-rc4-final-soak-1-20260906-run3/summary.json`,
  SHA-256
  `FD8A093B859AD74AA60D8CF92B53B0A77B9EBC57942C0E99D556033CE93E4E9C`.
- Samples: `artifacts/memory/v71-rc4-final-soak-1-20260906-run3/samples.jsonl`,
  SHA-256
  `7C9ED1ABE3E2097905F7FDD1FD813B1EDE764477E4155376D3BE81BF24B3FD2F`.
- Producer (normalized LF):
  `2D914227EC4C0343FD51C2DF2283F2447248110D40E81A290AA5879B78C78214`.

The first second-soak attempt stopped fail-closed after an ADB Wi-Fi disconnect
at sample 10 / 45.364 minutes. A later preflight produced no samples because
the replacement process did not contain the required bound launcher-release
marker. Both directories are incomplete diagnostic evidence and do not count.
The exact second soak and combined memory-runtime receipt remain pending.

Fresh Host verification also passed: Vivecraft `43/156`, Pojlib debug and
release `42/204` combined, and VEQ clean `check build` across `86` tasks with
the exact locked JAR hash. A clean Vivecraft Fabric archive reproduced all
`1308` entry contents; only timestamps on the 15 nested dependency entries
differed, so the already locked and runtime-tested Core was not replaced.

## 2026-09-06 — exact v71 RC4 Lab candidate: installed lifecycle PASS

The RC4 managed payload and exact Lab APK are installed in the Lab package. The
first normal Play reconciled the physical profile from RC3 Core to exact RC4
while retaining frozen VEQ. The formal lifecycle gate then passed three
independent game/OpenXR launches. Stable remained stopped and untouched.

| Candidate field | Locked value |
| --- | --- |
| Lab identity | `com.qcxr.qcxr.canary262`; versionCode `71`; `6.0.1-26.2-vivecraft-personal.12-rc.4` |
| Lab APK | `QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.4-integrated-local.apk`; `128434961` bytes; `8D4811174EC963FFB0DDD31196C425111D03F04A5A2EB4CF6ED7D2DEBB492FAA` |
| Vivecraft Core | `26.2-1.3.15+qc.v71.rc4`; `10068021` bytes; `289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189` |
| Frozen VEQ | `0.7.0-v70-canary.1`; `441660` bytes; `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B` |
| Core/VEQ pair | `9D2C0830A34963FF3D5F336B465A6B8D11C153E82A738D0528E8D1821F25A8B1` |
| Pojlib AAR | `88700612` bytes; `7CE62B90112B74790100F5A8685412CA477D8086167598975A67DDC9E7FD7F2F` |

Clean Host gates passed: Vivecraft 43 suites / 156 tests; VEQ 59 JavaExec
self-tests and 9 static verifiers across 86 Gradle tasks; Pojlib 21 suites /
102 tests per variant, 42 / 204 combined, with two clean AAR builds identical.
The incremental `DB1DF70F...3AA4B8` Core is explicitly rejected in favor of the
clean-reproducible `289C2705...13189` artifact.

Post-preparation Host gate audit: PASS. Commits `d3cfea5d`, `7a4e2c5a`, and
`e04e4c21` separate repository/evidence roots, restrict A/B receipts to
`artifacts/benchmarks/`, re-lock the changed producers/consumers, and correct
the documented commands. A full build then identified a real D8 compatibility
failure in the Java 25 AAR: D8 4.0.52 crashed on unnamed `MethodParameters` in
17 synthetic-bridge classes. The replacement AAR built with Unity Temurin
`11.0.14.1+1` is byte-reproducible, changes only `classes.jar`, contains zero
such attributes, and passes the exact D8 directly. Commit `a636ae61` pins this
toolchain and adds the preflight. Build-transaction tests remain `12/12`; every
documented Host producer/consumer gate passed after the relock. Lock SHAs after
the successful Lab lifecycle gate and sampler preflight fix: Lab
`A531988E...816623`; stack `EB28B3DB...D92834`; Stable acceptance
`FF3E645A...B51155`. Lifecycle receipt
`60267E64...87A6A` (`4016` bytes) was written atomically after final APK/pair
revalidation. Transparent
NTFS compression of old Codex work folders raised free space above the enforced
`10 GiB` Lab prerequisite without deleting files; Stable still requires
`15 GiB`.

The first RC4 memory-sampler start correctly found the exact live APK/Core/VEQ
pair and bounded JVM log, but PowerShell rejected the launcher's legitimate
blank separator lines before sampling. The producer now filters only empty
separator rows before the exact memory-line parser, includes a regression
self-test, and is re-locked as `8CA44B11...A898984`; no sample from the failed
preflight is retained or counted.

Exact RC4 status: Host source/payload preparation, APK build/audit, exact Lab
install, profile reconciliation, three cold starts, and lifecycle/recovery
`PASS`; manual interaction, memory runtime contract, two new 90-minute soaks, balanced
RC3-to-RC4 performance, Stable build, Stable promotion/install, three Stable
starts, and the final 30-minute Stable gate all `PENDING`.

All RC3 results below are preserved as historical diagnostics. They establish
lineage, rollback, and the rationale for the unchanged memory/release policy,
but are not exact-build evidence and do not close any RC4 acceptance gate.

RC3 soak 2 completed with a stable PID and acceptable diagnostic memory shape
(summary `BD2A4963...A3A8`, samples `4803C307...C4DB`, max PSS
`2363.526 MiB`, post-warm slope `0.379 MiB/min`, last 30 minutes
`-2.891 MiB`). It remains RC3-only. A post-soak direct receipt was not created:
the retained logcat no longer contained the original launcher marker. RC4's
producer therefore captures that marker at start and requires a final
attestation for the same PID. Both fresh RC4 soaks remain `PENDING`.

## 2026-09-06 — exact integrated v71 RC3 Lab APK and cold starts

- Artifact:
  `QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.3-integrated-local.apk`.
- Identity: `com.qcxr.qcxr.canary262`, versionCode `71`, versionName
  `6.0.1-26.2-vivecraft-personal.12-rc.3`.
- Size/SHA-256: `128431385` bytes /
  `B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F`.
- APK artifact audit: PASS.
- Pojlib AAR SHA-256:
  `D7FF9C3EE2CCB332F88DE9A44E40E5BDA38F390142DC64905AEFD720FC3ADED6`.
- Persistent managed Core SHA-256:
  `14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26`.
- Persistent managed VEQ SHA-256:
  `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.
- Three normal cold starts: PASS (`3/3`). Every start retained the exact RC3
  pair and logged `Xms=512MiB, Xmx=1536MiB (auto)`.
- Stable safety: PASS; `com.qcxr.qcxr.dev262` was not modified.

The exact-new manual VR interaction gate, balanced performance gate, and both
new 90-minute memory soaks remain false/pending. A completed 90-minute capture
from an older payload is supporting diagnostic evidence only: it does not
apply to `B8918144...9AD8F`, counts toward neither new soak, and is not an
acceptance or Stable-promotion claim.

## 2026-09-06 — v71 launcher resource-release promotion candidate

The memory diagnosis isolated retained Unity launcher resources as the dominant
long-session growth source. In the same RC3 Lab stack, release OFF grew
`443.57 MiB` over `15.21` minutes (`31.78 MiB/min` OLS), while release ON grew
only `34.09 MiB` over `47.64` minutes (`0.62 MiB/min` OLS). The last `29.386`
minutes of the ON run grew only `11.321 MiB`. Stable remained stopped and
untouched.

The policy is now fail-closed to the exact v71 Lab RC3 and exact v71 Stable
package/code/name tuples. Both exact builds default ON; authenticated Lab A/B
may request OFF, while Stable ignores intent overrides. Cleanup is
per-resource best-effort and idempotent and does not unload UnityPlayer.

- `Pojlib/gradlew.bat --no-daemon testReleaseUnitTest`: PASS, 102 tests.
- `scripts/run-vivecraft-local-autoplay.ps1 -Action SelfTest`: PASS.
- Two clean Pojlib AAR builds matched byte-for-byte: `88696931` bytes,
  SHA-256
  `D7FF9C3EE2CCB332F88DE9A44E40E5BDA38F390142DC64905AEFD720FC3ADED6`.
  GNU build-id notes were omitted because the pinned r26b/LLD Windows toolchain
  emitted different IDs for otherwise byte-identical native libraries; native
  artifact hashes remain locked.
- The 240-second watchdog covers only the pre-handoff `gameReady` wait. The
  frozen RC3 Core has no post-OpenXR-init acknowledgement, so repeated Lab
  acquisition/recovery testing remains a mandatory Stable gate.
- The acceptance launcher now defaults resource release to `ON`; an `OFF`
  control requires the explicit `-AllowReleaseOffControl` switch and the
  resolved mode remains part of the returned run record.
- The v71 build transaction passed 8/8 Host fault tests: one Git-common lock,
  kill-on-job-close child containment, exact native exit-code capture,
  rollback with/without a prior APK, interrupted archive-copy cleanup,
  verified-success archival, and atomic pending-journal recovery. APK
  lifecycle markers are checked in their real
  payloads: Java markers in DEX and Unity strings in IL2CPP global metadata.
- Core and VEQ remain byte-identical RC3 payloads. The hardened source has now
  produced exact integrated APK `B8918144...9AD8F`, whose audit and three
  repeated cold starts passed. Manual interaction, matched-refresh
  performance, and both required new long soaks remain pending before Stable
  promotion.

## 2026-09-06 — historical launcher resource-release Lab canary (Host only)

The source adds an explicit-default-OFF, authenticated one-shot release mode
for `com.qcxr.qcxr.canary262`. Stable is not eligible, and the Unity side repeats
the exact Lab package check before changing resources. The canary stops the
launcher microphone, disables launcher roots/cameras, releases camera render
targets, clears the skybox, and requests `Resources.UnloadUnusedAssets` only
after the OpenXR handoff and one-shot completion path succeed. It contains no
`UnityPlayer.unload` call.

- `Pojlib/gradlew.bat --no-daemon testReleaseUnitTest`: PASS, 91 tests,
  0 failures, 0 errors, 0 skipped.
- `scripts/run-vivecraft-local-autoplay.ps1 -Action SelfTest`: PASS under
  PowerShell 7 and Windows PowerShell 5.1.
- `scripts/build-v71-integrated.ps1 -Target Lab -Action SelfTest`: PASS,
  Host-only, 0 device invocations.

No Unity build/compile, device, APK, runtime-memory, FPS, or soak result is
claimed.

## 2026-09-06 — historical pre-hardening v71 RC3 memory-retuned cold-start gate

The memory-retuned RC3 Lab APK passed Host preparation, the integrated build,
and three fresh Quest cold starts. It passed package/version, Debug
signer, ARM64-only, SDK 29/34, 16-KiB
alignment, Vulkan/OpenXR payload, manifest, DEX gate, and exact Core/VEQ/LWJGL
hash checks. Its SHA-256 is
`260A5A14BB3DF42B538F155A064EF82CA932C3D9261A6D84858214426BE17C82`.
Its Pojlib AAR SHA-256 is
`61F09A2AEEAC348F8286E621664A3152F12F9B1D0DA9ED28E3FEEF218A69C0C8`.
All three normal launcher starts retained exact RC3, initialized Vulkan/OpenXR,
entered `FPS Stress Test`, and logged `Xms=512MiB, Xmx=1536MiB (auto)`. No
manual interaction, FPS/performance, long-memory-soak, or Stable acceptance
claim is made, and v69 Stable `com.qcxr.qcxr.dev262` has not been changed.

- Cold starts 1–3 retained Vivecraft Core SHA-256
  `14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26`
  and VEQ SHA-256
  `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.
- The pre-retune APK completed three limited cold-start smokes at Xmx `1657`,
  `1644`, and `1633 MiB`; all reached the benchmark world with Vulkan/OpenXR.
  They prove RC3 persistence but do not close the new APK's cold-start gate.
- That pre-hardening APK's three-cold-start persistence/runtime gate was
  closed independently.
  Manual VR interaction, balanced performance, two 90-minute memory soaks, and
  Stable promotion remain explicitly false/pending.

- Before the integrated RC3 build, the most recent observed Lab run was RC2.
  The earlier RC3 delivery used a
  one-shot marker; once terminal, normal Play reconciliation restored the RC2
  managed baseline. The integrated Lab build now embeds RC3 and retained it
  through three normal launcher starts without a marker.
- Locked Vivecraft Core RC3: SHA-256
  `14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26`.
- Locked VEQ: SHA-256
  `314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B`.
- The memory-retuned Pojlib AAR is `88668834` bytes with SHA-256
  `61F09A2AEEAC348F8286E621664A3152F12F9B1D0DA9ED28E3FEEF218A69C0C8`;
  two clean builds reproduced it byte-for-byte. Its integrated Lab APK passed
  Host gates and the three fresh startup/runtime smokes.
- Vivecraft common tests passed `147/147`; VEQ `clean check build` completed
  all `86` Gradle tasks. The fixed Lab and Stable build entry-point self-tests,
  all four managed manifests, and the RC3 canary gates also passed Host-side.
- The rebuilt memory policy is `Xms=512 MiB`, automatic target/minimum
  `Xmx=1536 MiB`, `1024 MiB` native headroom, and a `2048 MiB` manual hard
  maximum. The replacement AAR and APK are verified and the launcher logged
  the exact automatic value in all three new starts; long-memory acceptance is
  still pending.
- The first RC3 memory-soak attempt was stopped early at `5.036` minutes after
  PSS reached `2481.24 MiB` and RSS reached `2534.08 MiB`, exceeding the
  process-memory guardrail. It does not count toward either required 90-minute
  soak. The automatic target was therefore lowered from `1800` to `1536 MiB`.
- Android LMK evidence remains an open gate: two foreground sessions ended
  `LOW_MEMORY` after about 67m38s and 64m13s at approximately 2.78 GiB and
  2.71 GiB process size. They used a 3168 MiB JVM choice without the new cap;
  this evidence identifies memory pressure but does not prove a source leak.
- Required memory gate: two 90-minute soaks, no LMK/crash, stable PID, PSS
  `<=2.4 GiB`, and post-warm growth `<=2 MiB/min`, followed by the manual RC3
  interaction checks. Until those pass, Stable promotion is prohibited.
- The soak sampler is fail-closed: it requires 19 samples from minute 0 through
  a real minute-90 sample, a focused Lab process, a live `QuestCraft-JVM`
  thread, every required memory metric, and complete post-warm/last-30-minute
  windows. Missing parser data cannot be interpreted as a pass.
- The first memory-retuned attempt was stopped at `5.040` minutes. PID, focus,
  and the JVM thread stayed valid, but PSS rose from `2364.46 MiB` to
  `2523.72 MiB`, exceeding the `2457.6 MiB` limit by `66.12 MiB`. `/proc` RSS
  was `1968.38 MiB`, process swap `18.64 MiB`, and available memory
  `1862.63 MiB`. Graphics accounted for only about `9.3 MiB` of the
  `159.26 MiB` PSS increase; the rest was anonymous/unclassified. The sampler
  stopped without stopping the app, and this run does not count as a soak.

Test date: 2026-09-03

## Decision

The current release is v69 Stable. Its full Unity APK passed all Host artifact
gates, was installed over the exact v68 package using same-signer
`adb install -r`, and the installed `base.apk` SHA-256 matched the release file.
The user had already accepted all required functionality on the exact v69 Lab
gameplay payload with Camera Park ON. Launcher Camera Park also passed its
balanced performance, cold-start, and soak gates, so it was the only v69
candidate promoted.

The evidence boundary is deliberate: the Stable activity did not start while
unattended after installation. Consequently, this record does **not** claim a
post-install Stable runtime, cold-start, profile-reconciliation, both-eye,
controller, or soak result. Idle Throttle is absent, and autoplay remains
restricted to the Lab package.

## v69 Stable build, artifact, and install gates

- Package `com.qcxr.qcxr.dev262`, label
  `QuestCraft Vivecraft Personal 26.2`, versionCode `69`, and versionName
  `6.0.1-26.2-vivecraft-personal.10` passed the fail-closed build gate.
- Pojlib AAR: `86970097` bytes, SHA-256
  `88A172AF772E9DE600864831D617729E9F8E04DFBEB4BB30FC54B9F7407D6DD3`.
- APK: `126700777` bytes, SHA-256
  `05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034`.
- The APK verifier passed SDK 29/34, ARM64-only, APK Signature Scheme v2,
  signer `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`,
  16 KiB ZIP alignment, Vulkan/OpenXR, the locked Vivecraft and LWJGL payloads,
  eleven managed mods, and four identical manifests.
- Same-signer `adb install -r` over exact v68 succeeded without uninstall or
  data clear. The pulled installed APK hash matched the value above.
- Camera Park is enabled only after successful XR handoff. The Personal package
  cannot consume the Lab autoplay gate. Idle Throttle is not present.
- Stable launch/runtime after this installation remains pending. Manual
  functionality and performance acceptance below belong to the exact Lab
  payload and justify promotion, but do not claim Stable-package execution.

## Historical v68 Host, Unity-build, and artifact gates

- Accepted functional source/tag: `0174c883` /
  `personal-v67-rc2.7-accepted`.
- v68 packaging commits: `da42b867` and `84de53d3`; the build-tip
  `817910a2` makes the Pojlib Android stage use Unity's compatible JDK.
- VEQ release `0.7.0` built twice reproducibly with SHA-256
  `6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9`.
  Its 240 gameplay entries match the accepted rc2.7 JAR byte-for-byte; only
  release metadata and the generated Architectury injection class differ.
- Pojlib was rebuilt twice reproducibly with Unity OpenJDK 11. JDK 21 class-file
  metadata had caused Unity's bundled D8 to crash; the final 86905783-byte AAR
  passed standalone D8 and has SHA-256
  `136AC1E2C788E06F720B87B5C5A9DF5C52D363F3F862928AD6934575656E3E51`.
- Unity `2022.3.62f3` completed `QuestCraftCliBuild.BuildAndroid` with exit code
  `0`.
- The APK verifier passed package `com.qcxr.qcxr.dev262`, versionCode 68,
  versionName `6.0.1-26.2-vivecraft-personal.9`, SDK 29/34, ARM64-only, APK
  Signature Scheme v2, signer
  `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`,
  16 KiB ZIP alignment, Vulkan/OpenXR, Vivecraft
  `3638F258...D842F`, LWJGL `DD19A303...4DC9`, eleven managed mods, and four
  identical manifests.
- This is deliberately a Host result. Same-signer `adb install -r`, managed
  profile reconciliation, three cold starts, supervised controls/eyes, and the
  soak remain pending.

## Historical v67 RC1 surface-metrics and artifact gates

- Vivecraft commit `d4d35a1b` gives each overlay its real metrics: Wrist
  `1008x540 / 504x270 @2x`, Grip `392x392 / 98x98 @4x`.
- `:common:test` and `:fabric:clean :fabric:build` passed. Independent review
  found no P0/P1 correctness issue in the projection/scissor/cursor scope or its
  `finally` restoration.
- VEQ `0.7.0-rc.2.6` built with SHA-256
  `1E0019D2B9E0AED3B0D8F624C5A8608AF037548692D373C8876706792BEF73D3`.
- Vivecraft built with SHA-256
  `3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F`.
- Pojlib AAR rebuilt to SHA-256
  `146869B64C30618ED89C9FEB109DAE08F660E330DDD12A35D002D8167E387583`.
- The 126651157-byte APK passed package `com.qcxr.qcxr.dev262`, SDK 29/34,
  ARM64-only, v2 signature, expected signer, 16 KiB ZIP alignment,
  Vulkan/OpenXR payload, eleven managed mods and identical embedded manifests.
- Because Unity 2022.3.62f3 was unavailable, this APK was produced by the
  checked-in binary-preserving repack script from the exact verified v66 base.
  It is not a v67 Unity-build claim.
- Per user confirmation, the previous crash is resolved. Crash checks remain a
  regression gate only; this candidate targets Wrist crop/input alignment and
  Grip size/clarity.
- Device-side hashes match Vivecraft `3638F258...D842F` and VEQ
  `1E0019D2...F73D3`. Fabric loaded 70 mods including VEQ `0.7.0-rc.2.6`, chose
  the Adreno Vulkan backend, initialized OpenXR with two views/controllers,
  submitted at least 120 frames, and started the benchmark integrated server.
  No fatal, MixinApply or Linkage error matched. The missing `libflite.so`
  narrator warning remains the known non-fatal Android warning.
- `firstInstallTime` remained `2026-08-26 02:30:51`; no uninstall, clear-data,
  account-file read/copy was used. The pre-install backup is
  `backups/v67-rc1-preinstall-20260902-1300`.
- A same-signer versionCode-67 rollback APK containing the exact v66 payload was
  verified at SHA-256
  `5C0E8C71F8D7A9A25A57BC7B0565851C4A238208A3B7DAFF51057E17FB1C4AB4`.
- VEQ rc2.7 was subsequently hot-deployed at SHA-256
  `90D854125ACCBA23802D0FE7788A8C2FFBA24AA0CF90FBEC5A90DDB3DDE866E5`.
  The user manually accepted that JAR's gameplay. This does not change the fact
  that the v67 APK itself embeds rc2.6.

## v67 Host canary gates (no device evidence)

- `dev.1`, wrist final-surface pose/visibility:
  `099471108AC02B77EBED0C5D0ADB22B8BB2DB463F2062B174E195914BDEDF579`.
- `dev.2`, pointer plus Creative/contextual-container contracts:
  `512110AB57FBC9B0F4972E545FBE8E765D8449EE33FBB39625F991BBBA7CD422`.
- `dev.3`, independent handed Grip sessions:
  `9E255B0520C0A6AC165E498956C97FD10773B3FCFDE1182C8724561228E91440`.
- The cumulative `dev.4` JAR is
  `exports/v67-canaries/VivecraftEssentialsQuest-0.7.0-dev.4+mc26.2-fabric.jar`,
  size 385566 bytes, SHA-256
  `DA96F91807091DDE1432AA959BCBDF320BE08D8FD65020AB8A66DBAF99D00FF9`,
  from HEAD `c771acffb5ad700ab80585bc1943ba4de9b9f374`.
- Java 25 Vivecraft Fabric build: PASS. VEQ 64 tasks: PASS. Safe deployment
  self-test: PASS with `DeviceTouched=False`.
- The device was disconnected throughout these gates. No v67 deployment,
  launcher reconciliation, Fabric/OpenXR/Vulkan runtime, manual interaction,
  FPS, soak, or APK-build result is claimed. The JARs remain a supervised
  `dev.1` -> `dev.2` -> `dev.3` -> `dev.4` test queue, not a release.

## v66 corrective gates

- Host tests and independent review passed for the cropped 504x270 VEP surface,
  crop geometry/UV/input alignment, asymmetric Y mapping, full-quad fallback,
  carried-item ownership, and right-`B` handed input mapping.
- Unity produced the 126557121-byte personal.7 APK with SHA-256
  `708962B958B8373B46231F8DA6C7B2AC284593BB30B291B46C68931FD1A3A70D`.
- Same-signer `adb install -r` passed and the launcher opened. No uninstall,
  data clear, or account-file copy/read was used.
- The one-shot authenticated launch reconciled the physical profile to
  Vivecraft `917B75DA...5C85` and VEQ `F59E7204...89FB`, loaded 70 mods and VEQ
  0.6, selected Adreno Vulkan, connected OpenXR, loaded GamerPotion's FPS
  Stress Test, and submitted at least 1200 frames. No fatal, MixinApply, or
  Linkage error appeared; the missing `libflite.so` narrator library is the
  known non-fatal Android warning. Controllers were inactive, so supervised
  Wrist + `B`, both-eye, soak, and FPS acceptance remain pending.

## Historical v65 Host, build, artifact, and install gates

These results are retained for lineage and regression comparison only. v65 was
not a manually accepted release, and none of its runtime evidence validates
the current v66 binary.

- Vivecraft `:common:test :fabric:clean :fabric:build` passed 43 tests on Java 21,
  including overlay/claim tests plus bow, weapon pose, OpenXR handedness,
  buffer reuse, and runtime-owned refresh policy.
- VEQ `clean check build` passed all 53 tasks on Java 25. Coverage includes the
  VEP inventory layout, carried item, unified settings, Quick Actions,
  contextual container claim/lifecycle, deferred optional icons, per-hand Grip,
  and dual-hand policies.
- Staged SHA-256 values: Vivecraft
  `415394F749B12FD0121B4CAAA7FDF7FCF26306692CDBCAB1373438A3261CA356`,
  VEQ `766724914B2E3333E5BB3D4BE9BCDFD7B45728C2266152435EC8DF91A02A85A6`,
  and Pojlib AAR
  `A573E689D967059FD153BD8ECDF015393E9CD36D350D7E313367EC95A3E716A4`.
- Unity 2022.3.62f3 returned 0 and produced a 126527121-byte APK with SHA-256
  `EDF5A730E0F5FA1B333349C9D3029D6B4E2E32ACD097BD8C0604D009D4A6A7F0`.
- Independent verification passed package `com.qcxr.qcxr.dev262`, versionCode
  65, personal.6, SDK 29/34, ARM64-only, v2 signature, expected signer, 16 KiB
  ZIP alignment, Vulkan/OpenXR payload, eleven managed mods, and identical
  release/dev manifests.
- The installed v64 base APK was pulled read-only and had the same signer.
  `adb install -r` succeeded; `firstInstallTime` remained
  2026-08-26 02:30:51. No uninstall, data clear, or account-file copy/read was
  used. The v65 launcher process then started without a fatal/Mixin/linkage
  error.
- Device-side hashes then matched all eleven locked mods. `latest.log` records
  70 loaded mods, VEQ 0.5, Vulkan on Adreno, runtime-owned refresh policy,
  OpenXR connected, LEFT/RIGHT render targets, the FPS-Stress-Test world, and
  at least 4800 submitted frames before the soak. A captured compositor frame contained both
  eyes. No fatal/MixinApply/Linkage error appeared. Controllers were inactive;
  all hand and eye-comfort gates remain open; the stationary soak is not a
  substitute for user interaction or a balanced performance comparison.
- An intermediate APK crashed before gameplay because optional-integration
  icons constructed `ItemStack` before Minecraft components were bound. It was
  rejected, the icon lookup was made lazy in `1736ec2e`, the full chain was
  rebuilt, and only the corrected SHA above passed runtime startup.
- Commits `fc337250`, `cc925efa`, and `a4a86d43` close the final pointer-input
  P1 review: cancel never performs an inventory transaction, the exact
  screen/menu/controller owns a carried stack, the other hand remains free,
  known container subclass latches are cleared explicitly, and unknown release
  overrides fail closed. All 53 Host tasks pass and independent source/bytecode
  review reports no remaining P0/P1 in scope.

## Historical v63 Host, build, and artifact gates

- Vivecraft and VEQ Host checks pass on Java 25. Coverage includes the retained
  bow correction, wrist-pose calibration ownership, ray/cursor and carried-item
  lifecycle, handed Grip sessions, logical/physical hand mapping, calibration
  release suppression, and owned offhand-use continuation.
- Staged Vivecraft SHA-256:
  `FD4023BA52A4D1E14532F126D4E3123048BF46BAC380CFAF9FC9D8972C305D85`.
- Staged VEQ `0.4.0+mc26.2` SHA-256:
  `E9AC2FC0A91083D3DE461F207F4FE9F864730CC819A7ADA360B35DA07BA21F09`.
- Rebuilt Pojlib AAR SHA-256:
  `FA626CC955B3F0D255B2922F086363C397633F009D7F199BB090715BA6255714`.
  Its embedded manifests and Vivecraft/VEQ payloads match the staged files.
- Intended and verified identity is `com.qcxr.qcxr.dev262`, versionCode `63`,
  versionName `6.0.1-26.2-vivecraft-personal.4`.
- Unity `2022.3.62f3` produced
  `QuestCraft-Vivecraft-26.2-personal.4-local.apk`, size `126380801` bytes,
  SHA-256
  `0A65715BCD20E64285014173BCE4714073925B691122434A70B81E39BE074A69`.
- Independent verification passed package/code/name, min SDK 29, target SDK 34,
  ARM64-only ABI, APK Signature Scheme v2, signer `B9BC1922...D4CA1A`, 16 KiB
  ZIP alignment, and all embedded managed-artifact hashes.
- `adb install -r` succeeded from v62 to v63 with the same signer. The original
  `firstInstallTime`, physical profile, and preserved v62 rollback APK remained
  intact. A selected `mods/config/options/saves/Xaero` backup with per-file
  SHA-256 was created without account or Microsoft files.
- A launch was requested after waking and dismissing the keyguard, but Meta's
  Guardian/volumetric-placement service timed out before QuestCraft obtained a
  process. This is not an application crash and is not runtime evidence.
- With the package stopped, the exact staged Vivecraft and VEQ JARs were copied
  through Android's external-storage shell path and atomically replaced only
  after their SHA-256 values matched. A device-side audit then matched all
  eleven physical profile JARs to `STACK.lock.json`; no temporary candidate
  remained. The game has not loaded these JARs yet, so runtime gates remain
  pending.

## Historical v61 Host and artifact gates (not v63 evidence)

- Vivecraft and VEQ Host checks pass on Java 25. VEQ coverage includes overlay
  lifecycle/math, layout and input rules, pointer-focus Grip arbitration,
  schema migration, quick actions, and the compact 3x3 Grip grid.
- Staged Vivecraft SHA-256:
  `574C45923BA8EBB598B17F4E1D8641068590A619B4E9748597F9811FBE510FEE`.
- Staged VEQ `0.2.0+mc26.2` SHA-256:
  `1419CCFA78FF390EC38E2A448F1051365075D64A96CF94F6A2EA997C2CAA8A1E`.
- Intended identity is `com.qcxr.qcxr.dev262`, versionCode `61`, versionName
  `6.0.1-26.2-vivecraft-personal.2`.
- Pojlib AAR SHA-256:
  `89CC26FCCD60ECA6A06091063D17E821F459B15D4102559FFFDD6A881CFEA7AB`.
- Final APK is 126,319,325 bytes, SHA-256
  `A5142D3C556FAE9C1A487E460ED314D5E6957161E742F506CC54B270D2F88198`.
- The verifier passed package/code/name, min SDK 29, target SDK 34, ARM64-only,
  v2 signature, signer `B9BC1922...D4CA1A`, and 16 KiB ZIP alignment.
- The first build attempt exposed a manifest/embedded-asset hash mismatch. The
  verifier was strengthened to compare those values, the mismatched attempt was
  rejected, and only the final APK above is accepted.

## Historical v61 unattended Quest smoke (not v63 evidence)

- `adb install -r` succeeded with no uninstall or clear data.
- The physical profile reconciled to Vivecraft
  `574C45923BA8EBB598B17F4E1D8641068590A619B4E9748597F9811FBE510FEE`
  and VEQ
  `1419CCFA78FF390EC38E2A448F1051365075D64A96CF94F6A2EA997C2CAA8A1E`.
- Wrist configuration migrated to schema 2 and `activationMode=VEP_AIM`; the
  v1 backup file is present.
- Fabric Loader 0.19.4 loaded VEQ 0.2. Vulkan and OpenXR initialized `LEFT` and
  `RIGHT` render targets and created the independent External Screen Overlay
  render target.
- `FPS-Stress-Test` started its integrated server and reached 100% spawn;
  OpenXR submitted at least 4200 frames.
- The filtered runtime check found no fatal, Mixin-apply, or LinkageError.
- A 60-second VrApi capture contained 61 samples with exact PID and focus at
  100%: mean `77.2` FPS, median `77`, P10 `73`. The helper reported
  `ValidForComparison=true`; raw logs were not persisted.
  It is a compatibility/stability sample only; no balanced v61 A/B or visible
  overlay-cost measurement exists, so it supports no performance-gain claim.
- Controllers were inactive. This proves startup/render lifecycle compatibility,
  not wrist gesture/input, Grip, reverse-hands, or both-eye correctness.

## Previous v60 Quest smoke (not v61 evidence)

- Signer matched the installed Dev build; `adb install -r` succeeded. No
  uninstall, data clear, or account-file copy/read was used.
- The managed `26.2` profile reconciled to eleven exact JARs.
- Fabric loaded 70 mods, including Vivecraft, Vivecraft Essentials Quest,
  ImmersiveMC, Xaero, and the candidate performance-mod set. This was a
  combined compatibility smoke, not an isolated performance acceptance for
  Sodium, Lithium, FerriteCore, or BadOptimizations.
- Vulkan was forced on the Adreno driver; OpenXR initialized and submitted
  `LEFT` and `RIGHT` Dual-Pass views.
- The benchmark world loaded and its integrated server started. No crash,
  `LinkageError`, fatal Mixin error, or OpenXR fatal appeared.
- The final VEQ `0.1.1` settings/climbing build was installed in place and the
  physical profile reconciled to Vivecraft SHA-256
  `200568FF0FB8555405EB69B3884FA96C0535477DEF6EB6B8AF988913336209DA`
  and VEQ SHA-256
  `D716B84BC096DE9D423106A68246134CE6A9FA761AADFF00C657FF0F3AEDC54E`.
  Fabric reported 70 mods, loaded VEQ `0.1.1`, started `FPS-Stress-Test`, and
  OpenXR submitted at least 600 frames. No fatal, Mixin-apply, or linkage error
  matched the filtered log. At `50 C`, this final run was a compatibility smoke
  only and did not add an FPS result.
- Nonfatal warnings retained for diagnosis: missing narrator `libflite.so`,
  Xaero's generic “No Vivecraft!” compatibility message, an optional Sodium
  staged-buffer Mixin target, and a Vulkan MAILBOX surface warning.
- The separate Visor rollback application remained stopped at version `59` /
  `6.0.1-26.2-visor.3-perf.2`; its installed base APK matched SHA-256
  `F5AB99F1AC991229A16005849364B50D7219EFA0654D4BF3037E4F5823C5B69B`.
  This check was read-only and did not touch the Visor profile or application
  data.

## Previous v60 QGO Dynamic samples

> Measurement lineage: this section, the 20-minute soak, Perfetto, rejected
> OpenXR A/B tests, and the three cold starts were captured against the
> pre-VEQ-`0.1.1` baseline APK `72AC7664...2081F` with VEQ
> `CE07FE18...F9C78` and Pojlib `5BFCAC4C...9D068`. They are not performance or
> cold-start results for final APK `1A40872C...F5A4A`.

All three 60-second samples were restricted to the exact app PID, remained
focused for the full capture, used QGO Dynamic with CPU/GPU levels `4/4`, and
did not persist raw logcat.

| Sample | Mean FPS | Median | P10 | App GPU P95 | Temperature |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 72.92 | 73 | 70 | — | — |
| 2 | 74.53 | 73 | 71 | 6.10 ms | 43 C |
| 3 | 76.02 | 76 | 72 | 6.05 ms | 43 C |

The GPU has substantial nominal headroom, but these runs repeatedly reported
roughly `Stale=1..6` in one-second VrApi rows. Meta defines `Stale` as a missed
delivery deadline where the previous frame is redisplayed, and specifically
warns that values above zero but below the refresh rate indicate uneven frame
delivery. Therefore good FPS and app-GPU time do not close the performance gate.
See [Meta's VrApi definitions](https://developers.meta.com/horizon/documentation/unreal/ts-logcat-stats/)
and [FrameSync guidance](https://developers.meta.com/horizon/essentials/framesync/).

The benchmark helper now reports prediction time, latency mode, VSync interval,
stale streaks, stale values grouped by actual refresh, and stale values on a
refresh transition versus a stable refresh. Device serial and raw rows are not
persisted.

### Longer baseline and diagnostic trace

- A stationary 20-minute run produced 1,201 exact-PID samples: mean `73.81`
  FPS, median `73`, P10 `71`, with full focus and no persisted raw logcat.
- A separate 120-second aggregate capture confirmed that QGO refresh changes
  make stale delivery somewhat worse, but are not the primary cause: stable
  72 Hz samples still had non-zero stale values in most one-second rows.
- A 15-second root-assisted Perfetto capture was used for measurement only. It
  found short runnable waits on the Minecraft render thread, including three
  waits at least 4 ms and a maximum of 8.095 ms. No priority, affinity,
  overclock, driver, or Magisk setting was changed.
- The trace is kept outside Git. SHA-256:
  `953CA52C8603B8B8E1EB3833822843AA4019C11B986146D02C33099697DDFEAE`.

### OpenXR per-frame telemetry A/B

A one-variable canary moved expensive diagnostic action scans and pose-string
formatting behind their 600-frame logging gate. The APK was identical to the
baseline stack except for `MCOpenXR.class`, was installed with the same signer,
and was tested as `A x3 -> B x3 -> A-after` under QGO Dynamic 4/4.

| Group | Mean stale/s | P10 FPS | App P95 | CPU+GPU P95 |
| --- | ---: | ---: | ---: | ---: |
| Baseline A1-A3, pooled | 3.713 | 73 / 73 / 73 | 6.03-6.15 ms | 12.31-12.63 ms |
| Telemetry canary B1-B3, pooled | 4.088 | 73 / 72 / 72 | 5.89-6.16 ms | 12.29-12.65 ms |
| Baseline A-after | 3.74 | 75 | 5.81 ms | 12.07 ms |

Because QGO varied the actual display refresh, the acceptance decision used
exact-Hz matched bins. Across all matched A/B samples, stale delivery changed
from `3.721` to `4.077` per second: **9.6% worse**. Frame-time P95 was unchanged
and normalized FPS did not improve. The canary is therefore rejected as a
performance change and is not part of the installed or source-integration
baseline.

### OpenXR renderer-thread settings A/B

An isolated canary registered the Minecraft render thread through
`XR_KHR_android_thread_settings` only after verifying the actual render thread.
Its JNI path used the existing Quest loader to obtain the Linux thread ID; it
did not change affinity, clocks, priority directly, refresh policy, or the mod
stack. The extension call passed its runtime gate and the same benchmark world
loaded without a crash.

Three canary samples were compared against all four baseline samples by exact
actual-refresh bins. Stale delivery changed from `3.790` to `4.007` per second,
or **5.7% worse**. Raw pooled stale delivery was `3.719 -> 3.973` per second.
Normalized FPS deficit was effectively unchanged (`0.349 -> 0.353 Hz`), App
P95 was `6.03 -> 6.05 ms`, and CPU+GPU P95 improved only `0.6%`
(`12.42 -> 12.34 ms`), below the `2%` gate.

The canary runs were hotter (`43.6-45 C` versus `41-42 C`) and the order was not
randomized, so this test does not prove that thread registration caused the
regression. It does prove that the measured run did not produce a repeatable
benefit. The canary is rejected, remains isolated, and baseline v60 was
restored.

### Cold-start and persistence gate

- Three baseline cold starts launched through the matching QGO profile, passed
  authenticated profile reconciliation, entered `FPS-Stress-Test`, and reached
  active Vulkan/OpenXR rendering without a crash.
- SHA-256 remained unchanged across the sequence for `options.txt`, the active
  Vivecraft client config, Sodium options, and ImmersiveMC client config.
- No account file was read or copied, and no uninstall or data clear occurred.

## Array Dual-Pass canary

- Isolated branch: `agent/vivecraft-array-dual-pass-v60`.
- Commit: `0b7cd4a8d83f4a60e5c1c0d92ec03af48d655dde`.
- JAR SHA-256:
  `4923F8449202F7A1D4F222254C9857583CF4B3167F0A40E4A53B6D710F7BCDBC`.
- Packaged host branch/commit: `agent/vivecraft-array-apk-v60` /
  `7efb183d56525a0725aea19eca5dc969e972bb3f`.
- APK SHA-256:
  `AA5DC9EA6D79549BDB0D042FB46E5E1FC8918EDE0C34E67D012D6E7ABF6E2213`.
  Pojlib AAR SHA-256:
  `581C161C71F30028054632220ABADF50FF4C8C46A4C299E64FB5CFD6FDE7FE2D`.
- Host tests/build and the final APK verifier passed. The canary uses one
  two-layer swapchain and one Vulkan copy command buffer but still draws the
  world twice.
- It was installed with the existing signer and reconciled the physical
  Vivecraft JAR to the exact canary hash. Runtime logs proved
  `renderMode=array_dual_pass`, `swapchains=1`, `arraySize=2`, successful frame
  submission, and benchmark-world startup with no matched fallback or fatal.
- One exact-PID 60-second screening sample at `45 C` produced mean/P10 FPS
  `70.15/68`, App P95 `6.15 ms`, CPU+GPU P95 `14.68 ms`, and mean stale
  `5.34/s`. The immediate baseline-after run was hotter (`46 C`) and degraded
  sharply, so neither run is a valid performance comparison.
- It is absent from baseline v60 and is not True Multiview. The manual
  independent-eye/HUD/particles/transparency gate and a cooled, balanced A/B
  remain mandatory.

## Historical pending v68 gates at build time

The exact v68 APK was later installed and became the base replaced by v69.
The list below preserves what was still pending when the v68 artifact was
first locked; it is not the current release checklist.

- First verify the installed v67 signer, then use matching-signer
  `adb install -r`; no v68 installation or profile reconciliation is claimed
  yet.
- Confirm that the launcher reconciles the physical profile to VEQ release
  `0.7.0` and the locked Vivecraft hash, without a leftover development JAR.
- Re-run the focused regression gate: complete uncropped Wrist, pointer/slot
  alignment, drag/carried item, and full-size clear Grip in both eyes. The same
  gameplay payload already passed manually as rc2.7, but the full v68 package
  still requires revalidation.
- Run three v68 cold starts and verify settings/world persistence; the older
  cold-start records above do not transfer to the new binary.
- Palm turn/open/close hysteresis and reverse hands.
- Wrist drag/drop/crafting, potion sprites/timers, Quick Actions, and Xaero in
  both eyes.
- The default World Map Quick Action requires the separate Xaero World Map mod;
  the historical eleven-JAR v65 stack intentionally contained only Xaero Minimap.
  The baseline fallback may match Xaero Minimap's `toggle_map`, so that action
  must not be called an accepted World Map implementation.
- Grip radial versus ImmersiveMC bag/container/climbing priority.
- Native Vivecraft teleport, passive shield, fast placement/breaking particles,
  haptics, pause/resume, and system recenter.
- A movement-based 20-minute soak after the stale-frame cause is isolated.

## VEQ deployment transaction safety (2026-09-01, offline)

- `quest-veq-dev.ps1 -Action SelfTest` passed under PowerShell 7 and Windows
  PowerShell 5.1; both parsers accepted the script and `DeviceTouched` remained
  `false`.
- The committed `test-quest-veq-dev-transactions.ps1` harness passed **12/12**
  local fault cases and `bash -n` accepted **11/11** generated/committed shell
  programs. Coverage includes EnableDev `rm` fail-after-operation compensation,
  commit-marker fail-after-promotion cleanup, lock-token promotion failure,
  stale and young tokenless locks, final-leaf symlink simulation, canonical
  parent-swap simulation, and ambiguous post-commit marker recovery.
- No ADB, headset, APK, account file, uninstall, or data-clear operation was
  used by these tests.

## v69 Lab one-variable A/B (2026-09-02, Quest 3)

The isolated Lab package `com.qcxr.qcxr.canary262` ran the official
`FPS-Stress-Test` world under QGO Dynamic with CPU/GPU levels `4/4`. Every
group below contains three 60-second exact-PID samples with full focus and no
persisted raw logcat. All samples resolved to a 72 Hz display mode and reached
at most 43 C. The accepted Personal package was not changed.

| Core | Mean FPS | Mean run-P10 | Stale/s | P95 App | P95 CPU+GPU | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| v68 baseline `3638F258...D842F` | 69.64 | 66.67 | 5.27 | 7.90 ms | 15.20 ms | Reference |
| Primitive history rings `0F428CB2...BC9D` | 68.66 | 65.33 | 6.09 | 7.69 ms | 15.81 ms | Reject |
| OpenXR input allocation `B19B5BB2...338F` | 70.03 | 68.00 | 5.24 | 7.29 ms | 14.63 ms | Accept as isolated canary |
| OpenXR hardening `11892F61...DD6D` | 68.53 | 65.67 | 6.52 | 7.60 ms | 15.43 ms | Reject for integration |

Relative to v68, primitive history rings reduced mean FPS by `1.41%`, reduced
P10 by `2.00%`, increased stale delivery by `15.56%`, and worsened P95
CPU+GPU time by `3.99%`; its Host allocation win therefore does not justify
integration. OpenXR input allocation improved P10 by `2.00%`, P95 App time by
`7.65%`, and P95 CPU+GPU time by `3.77%`, with no thermal, refresh, or stale
regression, so it advances to an integration canary. OpenXR hardening reduced
FPS by `1.60%`, reduced P10 by `1.50%`, and increased stale delivery by
`23.72%`; dependent timing/copy/zero-render candidates remain blocked until
the hardening regression is split or explained.

The run order was baseline groups followed by each candidate group, not a
fully counterbalanced `B->A / A->B` sequence. These results are sufficient to
reject the two regressions and to promote input allocation only to the next
integration gate; they are not a final v69 release claim. After every group,
the Lab world was saved, the app/JVM was stopped, the one-shot transaction was
rolled back to the exact v68 hash, and the same world was relaunched. The Lab
was left running in the benchmark world on the exact v68 baseline.

## v69 OpenXR input confirmation (2026-09-03, Quest 3)

The confirmation run used a fixed route master with SHA-256
`9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90`.
Each attempt restored that master before a cold autoplay launch, warmed for
five minutes, captured a separate ten-second thermal preflight, and then
captured one aggregate-only 60-second exact-PID sample. QGO remained Dynamic
at CPU/GPU `4/4`; the accepted Personal package remained untouched.

The first uncontrolled continuation sample in
`artifacts/benchmarks/v69-input-confirm/invalid-A0-uncontrolled-continuation.json`
is excluded by method because it did not begin from the fixed route master.
The subsequent manual A1/B1 pair was not promoted because its Dynamic-refresh
distributions were not sufficiently matched.

The guarded counterbalanced run then exhausted all three allowed Pair 1
attempts. Start temperatures always differed by at most `1 C`, but QGO chose
different Dynamic-refresh distributions:

| Attempt | Refresh TV distance | Mean Hz delta | B FPS change | B P10 change | B stale improvement | B P95 improvement | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 70.60% | 5.28 Hz | -6.20% | -4.11% | +43.61% | -16.58% | Excluded |
| 2 | 36.15% | 1.14 Hz | +6.32% | +10.94% | +41.82% | +15.32% | Excluded |
| 3 | 11.40% | 0.19 Hz | -0.58% | -1.57% | -29.79% | -0.07% | Excluded |

The protocol limit was `5%` total-variation distance and `0.5 Hz` mean delta.
Even the closest attempt failed the refresh gate, exceeded the one-percent P10
guardrail, increased stale frames, and did not improve P95. Therefore
`B19B5BB2...338F` is **rejected for v69 integration** rather than promoted from
its earlier provisional result. The harness restored the exact v68 core
`3638F258...D842F`, removed the one-shot marker, stopped Lab, and did not write
raw logcat or touch Stable.

The deterministic reset and A/B prerequisites are committed as `d1ee0e5b`;
the aggregate/thermal orchestrator is `58f1876e`; resume and exclusion-record
hardening is `80c6eb60`. Their offline SelfTests pass on PowerShell 7 and
Windows PowerShell 5.1.

## v69 VEQ corrected Frame Snapshot harness (2026-09-02, Host only)

- Added the fixed Lab-only lock `VEQ_LAB_CANARY.lock.json` and deployment entry
  point `scripts/quest-veq-lab.ps1`. They have no package/profile override and
  accept only `com.qcxr.qcxr.canary262`, profile `26.2`, baseline
  `6575A2A4...1696B9`, and corrected candidate commit `ee3f6144` / SHA-256
  `2AB6B702...7C36`.
- Superseded commit `1047f873` and its JAR hash
  `35B71C9C...0095` are explicitly blacklisted. The preserved corrected JAR
  passed bounded ZIP and exact Fabric id/version/environment/entrypoint/mixin/
  dependency validation.
- The Pojlib one-shot transaction now accepts an exact per-gate Fabric contract
  and candidate SHA allowlist. The VEQ gate promotes only after normal managed
  reconciliation, uses atomic moves, publishes only a process-local permit,
  restores the baseline on transaction or unattended-stack failure, and
  restores it on the next prelaunch after a consumed attempt.
- PowerShell 7 and Windows PowerShell 5.1 SelfTests passed with
  `DeviceTouched=False`, `AdbInvocations=0`, and an explicit negative Stable
  path test. The Host guard suite passed 6/6, and the generated VEQ transaction
  suite passed five deploy fault boundaries, one exact rollback case, one
  fingerprint case, and seven Bash syntax checks.
- Pojlib `testReleaseUnitTest` passed 35/35, including exact allowlist rejection,
  invalid-runId restore containment, promotion, and source-integration checks.
  No ADB, headset, package,
  profile, APK, account, save, world, QGO, or Magisk mutation occurred. Runtime,
  interaction, both-eye, and performance gates remain pending.

## v69 VEQ corrected Frame Snapshot screening (2026-09-03, Quest 3)

The corrected candidate `ee3f6144` / `2AB6B702...7C36` completed three
five-minute warm-ups and three 60-second exact-PID samples against accepted VEQ
`6575A2A4...1696B9`. The split transaction proof correctly accepted a consumed
candidate marker with one unchanged run id; this fixed the earlier harness
failure without weakening the core/mod marker gates. Both candidates remained
on exact v68 core `3638F258...D842F`, the fixed benchmark-world snapshot, the
same config and non-VEQ mod fingerprints, and CPU/GPU level `4/4`.

QGO Dynamic did not produce one comparable pair within three attempts. All
three pairs exceeded the `5%` refresh-distribution limit and the one-transition
exposure limit, so none is eligible for an acceptance claim:

| Attempt | A/B mean Hz | Refresh TV | Transition delta | B P95 change | B stable-stale change | B FPS / P10 change | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 72.82 / 72.08 | 29.55% | 26 | -9.29% | -75.00% | -3.01% / -4.23% | Excluded |
| 2 | 73.36 / 72.08 | 45.90% | 31 | -14.06% | -18.04% | -3.03% / -4.23% | Excluded |
| 3 | 72.00 / 72.41 | 19.65% | 17 | +13.46% | +40.00% | +3.08% / +4.48% | Excluded |

The sign reverses with QGO's refresh behavior, so the candidate has no
reproducible measured win. It is **not promoted to v69**. This is an
inconclusive/reject-for-release decision rather than proof that the source
optimization is intrinsically slower. A future retry needs a measured hidden/
visible duty-cycle marker or a fixed-refresh diagnostic series before a manual
visible-Wrist gate. Evidence is under
`artifacts/benchmarks/v69-veq-hidden-screen2-20260903/excluded`; no raw logcat
was retained. The Lab app was stopped, accepted VEQ was restored exactly, the
VEQ/core/mod transaction markers were absent, and Stable was not touched.

## v69 same-JAR copy-batch mode gate (2026-09-03, Host only)

- The strict Vivecraft canary marker is schema 2 and requires exact uppercase
  `OFF` or `ON`. Pojlib inserts one fixed
  `-Dvivecraft.openxrCopyBatch=<mode>` argument before the Minecraft classpath;
  any absent, repeated, mismatched, or invalid process-local claim resolves to
  `OFF`.
- `testReleaseUnitTest` passed offline with the Unity-bundled OpenJDK and
  Android SDK. This compiled the Pojlib changes and ran the transaction and
  source-integration tests; it did not assemble an AAR or APK.
- The core transaction, transaction fault harness, Lab build source gate,
  autoplay source gate, and same-JAR A/B SelfTests all passed under both
  PowerShell 7 and Windows PowerShell 5.1 with zero device invocations.
- A/B `Plan` passed under both PowerShell hosts for the exact candidate
  `A7298DFD1EA6BE238CB1AA815E46E774295A4FCBA771EB1345BA1B361EB33F2F`.
  A maps to `OFF`, B maps to `ON`, and both map to that same JAR.
- The device-capable A/B path now has a pre-round installed-APK provenance
  gate: it requires the exact Lab package/source-pinned version and accepted
  signer, runs the full APK/DEX verifier on a temporary pulled `base.apk`, and
  binds its SHA-256, size, version, and signer into the manifest and reports.
- No Unity process, APK/AAR build, ADB command, headset action, account/profile
  access, or Stable-package action was performed in this Host-only test pass.

## v69 OpenXR Copy Batch screening (2026-09-03, Quest 3)

The Lab APK was `com.qcxr.qcxr.canary262` versionCode `69`, signed by the
accepted signer. The same candidate JAR
`A7298DFD1EA6BE238CB1AA815E46E774295A4FCBA771EB1345BA1B361EB33F2F`
was launched with the one-shot runtime gate set to exact `OFF` and `ON`.
The first ON smoke reached the fixed benchmark world, emitted the exact
`dual_swapchain_single_command_buffer` marker, and rendered both eyes without
a fatal Vulkan/OpenXR error.

The earlier ADB failures were harness failures, not runtime failures. They were
traced to CRLF text in the multiline Android shell command used by the
post-launch core-state proof. Commit `cc0581d8` normalizes every device-shell
command to LF; the next run passed that proof and entered the five-minute
warm-up normally. Commit `a17c8f7e` then tightened the screen to AB/BA/AB,
95-percent sample and CPU/GPU-level-4 coverage, stable-refresh stale, matched
refresh-transition exposure, matched in-sample thermal paths, and per-pair as
well as aggregate FPS/P10 guardrails.

Two complete attempts were excluded from an acceptance comparison because QGO
Dynamic selected materially different refresh distributions. They remain valid
negative/dominance evidence because ON received the lower/easier refresh load
yet was consistently slower:

| Attempt | OFF mean Hz / transitions | ON mean Hz / transitions | OFF -> ON P95 | OFF -> ON FPS | OFF -> ON P10 | Stable stale |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 74.33 / 41 | 72.13 / 6 | 13.47 -> 14.73 ms | 73.79 -> 70.56 | 71 -> 68 | 3.55 -> 3.40 |
| 2 | 73.56 / 37 | 72.08 / 4 | 12.79 -> 15.12 ms | 72.98 -> 70.69 | 71 -> 68 | 3.12 -> 3.60 |

CPU/GPU level 4 coverage was 100 percent and the measured thermal path was
within the one-degree limit (attempt 2 was exactly 42 C for both conditions).
The third attempt was stopped after its first warm-up because the candidate was
already dominated twice and source review explained the regression: v68's two
encoders already feed one Vulkan queue submission, so this candidate removes
neither a queue submit nor either blit. It instead serializes both eye copies
and broad `ALL_COMMANDS` barriers in one command buffer. The current Copy Batch
implementation is therefore **rejected for v69**. A future redesign would need
batched pre-barriers, both blits, batched post-barriers, and GPU timestamps, or
an array/direct-to-swapchain path.

Aggregate evidence is under
`artifacts/benchmarks/v69-copy-batch-screen3-20260903/excluded`; no raw logcat
was persisted. Lab was stopped, its exact v68 core
`3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F`
was restored, the one-shot marker was absent, and Stable was not touched.

## v69 managed-mod screening (2026-09-03, Quest 3)

All comparisons used only `com.qcxr.qcxr.canary262`, the fixed benchmark-world
master `9E9875E5...31B90`, exact v68 core `3638F258...D842F`, accepted VEQ
`6575A2A4...1696B9`, CPU/GPU level `4/4`, five-minute warm-ups, ten-second
thermal preflights, and exact-PID 60-second samples. The Personal v68 package
was never started, written, or replaced. QGO Dynamic prevented a release-grade
three-pair comparison for every candidate, so no result below is claimed as a
new performance win.

### Sodium 0.9.1 versus 0.9.2-alpha.4

Three attempts failed the Dynamic-refresh matching gate. Across the excluded
directional evidence, 0.9.1 averaged about `1.24%` worse P95 CPU+GPU time,
`20.77%` worse stable-refresh stale delivery, and `0.08%` lower FPS; stale
delivery regressed in all three attempts. The decision is **keep Sodium
0.9.2-alpha.4**. Evidence is under
`artifacts/benchmarks/v69-mods-sodium091-screen1-20260903`.

### Removing BadOptimizations

All three attempts were refresh-incomparable and the sign was not perfectly
stable, but removal averaged about `7.16%` worse P95 CPU+GPU time, `13.13%`
worse stable-refresh stale delivery, `1.67%` lower FPS, and `1.45%` lower P10.
The decision is **keep BadOptimizations 2.4.1**. Evidence is under
`artifacts/benchmarks/v69-mods-without-badopt-screen1-20260903`.

### Removing Lithium

One pair had identical `72 Hz` exposure, zero refresh transitions, and matching
`45 C` thermal paths. With Lithium it measured `68.45 FPS`, P10 `64`, P95
`16.55 ms`, and `5.63` stable stale/s; without Lithium it measured `64.32 FPS`,
P10 `61`, P95 `17.34 ms`, and `10.07` stale/s. Later attempts were excluded by
refresh-transition exposure and reversed with QGO behavior, so the formal
screen decision remains `INCONCLUSIVE_DYNAMIC_REFRESH`; the conservative stack
decision is **keep Lithium 0.25.3**. Evidence is under
`artifacts/benchmarks/v69-mods-without-lithium-screen1-20260903`.

### Removing FerriteCore

The first pair was fully matched at `72 Hz`, zero transitions, and `45 C`.
With FerriteCore it measured `67.43 FPS`, P10 `63`, P95 `15.99 ms`, and `6.41`
stable stale/s; without it the result was `66.18 FPS`, P10 `63`, P95 `15.95
ms`, and `7.64` stale/s. Removal therefore lost `1.85%` FPS and worsened stale
delivery by `19.19%` for only a noise-sized `0.25%` P95 improvement. Because
the per-pair FPS guardrail was already violated, the remaining pairs could not
make this candidate releasable and were stopped. The decision is **keep
FerriteCore 9.0.0 — early reject by guardrail**, not a completed three-pair
performance claim. Evidence is under
`artifacts/benchmarks/v69-mods-without-ferrite-screen1-20260903`.

After every screen the managed mod, core, VEQ, config snapshot, and transaction
markers were restored to their exact baseline state. Lab was stopped and no raw
logcat, account data, or device identifier was retained.

## v69 Array Dual-Pass v1/v2 screening — invalidated (2026-09-03, Quest 3)

Both candidates ran only in Lab package `com.qcxr.qcxr.canary262`; they did not
replace or modify Stable. This path still renders the world twice and changes
the OpenXR/Vulkan swapchain layout, so it is **Array Dual-Pass, not True
Multiview**.

These initial ON screens are **INVALIDATED / EXCLUDED**. A stale rollback shell
from the Lab harness left a `tr` process consuming about `91%` of one CPU core.
It started after the v1 OFF capture and remained active through the v1 and v2
ON captures. The per-capture `ValidForComparison=true` field covered only the
exact app PID, focus, sample coverage, and refresh checks; it did not detect
external CPU contention. The later cross-process audit therefore overrides
that field for these ON samples.

v1 used commit `85813037` and exact JAR SHA-256
`C3CCF6F5A1BDD7992DA348E3319A8DE7ED8452E92A1A46BDD2B04DDF3B5B41D0`.
The same JAR was selected through the one-shot gate as `OFF` (`dual_pass`, two
swapchains of array size one) and `ON` (`array_dual_pass`, one swapchain of
array size two). The original 60-second exact-PID screens are retained only as
invalidated diagnostic history:

| v1 mode | Evidence status | FPS | P10 | P95 CPU+GPU | Stable stale/s | Mean stale/s | Mean Hz | Temperature |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| OFF / `dual_pass` | Pre-contamination standalone; not a complete pair | 71.05 | 69 | 14.78 ms | 2.62 | 2.83 | 72.13 | 44 -> 45 C |
| ON / `array_dual_pass` | **INVALIDATED / EXCLUDED: external `tr` load** | 64.75 | 62 | 16.46 ms | 9.83 | 9.83 | 72.00 | 45 -> 45 C |

The numerical differences between these rows must not be used as an A/B result:
the OFF row preceded the runaway process while the ON row was measured under
the extra load.

v2 isolated a barrier-batching revision at commit `2a6aa9fa`, exact JAR
SHA-256
`43C815363AD3700E5A92615B7886EAB7432A0649E1B7D1BACFE143114292C0C8`.
Its invalidated ON screen at exact `72 Hz` produced `63.8 FPS`, P10 `59`, P95
CPU+GPU `18.34 ms`, and both stable and mean stale delivery of `10.35/s`;
temperature moved from `46` to `45 C`. It is **EXCLUDED** because the same
external `tr` load was active, and it has no clean same-JAR OFF partner in this
screening group.

The invalidated evidence is retained under
`artifacts/benchmarks/v69-array-smoke-20260903` for diagnostic provenance only.

## v69 Array Dual-Pass v2 clean retest — rejected (2026-09-03, Quest 3)

The barrier-batched v2 JAR was retested cleanly after terminating the runaway
`tr` process and bounding both harness procfs reads. The comparison used the
same JAR SHA-256
`43C815363AD3700E5A92615B7886EAB7432A0649E1B7D1BACFE143114292C0C8`,
changing only its one-shot `OFF`/`ON` mode. Each run restored world master
`9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90`,
used a five-minute warm-up, and captured the exact focused Lab PID for 60
seconds. All four captures were 100% at 72 Hz with zero refresh transitions,
CPU/GPU levels 4/4, and pairwise temperatures within one degree.

| Pair | Mode | FPS | P10 | P95 CPU+GPU | Stable stale/s | Temperature |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 1 | OFF / `dual_pass` | 66.45 | 63 | 16.21 ms | 7.52 | 45 -> 46 C |
| 1 | ON / `array_dual_pass` | 69.26 | 62 | 16.58 ms | 4.30 | 45 -> 45 C |
| 2 | ON / `array_dual_pass` | 64.73 | 61 | 16.24 ms | 9.13 | 45 -> 46 C |
| 2 | OFF / `dual_pass` | 67.28 | 63 | 15.53 ms | 6.49 | 46 -> 46 C |

Pair 1 improved mean FPS by `4.23%` and stale delivery by `42.82%`, but failed
the P10 guardrail and worsened P95 CPU+GPU by `2.28%`. Pair 2 failed every
gate: FPS `-3.79%`, P10 `-3.17%`, P95 CPU+GPU `-4.57%` (worse), and stale
delivery `-40.68%` (worse). Across both pairs, ON changed FPS by `+0.19%`, P10
by `-2.38%`, P95 CPU+GPU by `-3.40%` (worse), and stale delivery by `+4.14%`.

**Decision: rejected for v69.** Both comparable pairs violate the required P10
guardrail and Pair 2 also violates the FPS guardrail. Because the protocol
requires every pair to pass those guardrails, a third pair cannot make this
candidate eligible. Evidence is under
`artifacts/benchmarks/v69-array-clean-retest-20260903`. Lab was stopped and
atomically restored to the exact v68 core; Stable was not started or modified.

## v69 Launcher Camera Park A/B and hardening (2026-09-03, Quest 3)

Launcher Camera Park was evaluated only in Lab package
`com.qcxr.qcxr.canary262`; Stable v68 was not started, installed over, or
modified. The initial implementation is commit `90cad740`, and the fail-closed
lifecycle/one-shot hardening is commit `78b080e0`. The hardened Lab artifact is
versionCode `69`, versionName
`6.0.1-26.2-vivecraft-personal.10-rc.1`, signed by
`B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`.

| Artifact | SHA-256 |
| --- | --- |
| Hardened Lab APK | `0C4F73FB08FDF0584E6D0DD342813AA4D07A060BE090141C92BF3147E3CE9099` |
| Hardened Pojlib AAR | `24F9CA1E47D276D6672C738C371E91823C0DA86F22DC6D7C38BA2F9805670D90` |
| Baseline Vivecraft core | `3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F` |
| Accepted VEQ | `6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9` |

The first same-device OFF/ON campaign used three interleaved pairs. Every
sample held exactly `72 Hz`, began and ended at `42 C`, retained the focused
Lab PID, and passed the harness load guard. All three pairs passed the release
guardrails.

| Mode | Mean FPS | P10 | P95 CPU+GPU | Stable stale/s |
| --- | ---: | ---: | ---: | ---: |
| Camera Park OFF | 70.34 | 68 | 14.71 ms | 4.89 |
| Camera Park ON | 71.51 | 70 | 13.61 ms | 2.26 |
| ON improvement | +1.66% | +2.94% | 7.48% better | 53.78% fewer |

The initial ON build also completed a 30-minute soak at `71.8 FPS`, P10 `70`,
P95 CPU+GPU `13.54 ms`, and `1.64 stale/s`. Temperature never exceeded `42 C`,
and there was no crash, PID/focus loss, or XR-session loss.

The hardened build then completed three valid final samples:

| Sample | FPS | P10 | P95 CPU+GPU | Stable stale/s |
| --- | ---: | ---: | ---: | ---: |
| 1 | 72.21 | 71 | 11.09 ms | 1.44 |
| 2 | 72.05 | 71 | 12.05 ms | 1.38 |
| 3 | 72.13 | 71 | 12.36 ms | 1.23 |
| Mean | 72.13 | 71 | 11.83 ms | 1.35 |

All three final samples were exact `72 Hz` / `42 C`. Three cold starts reached
the world, proved exactly three known launcher cameras were parked after XR
handoff, and proved the explicit OFF/ON override was cleared on completion.
A separate cold `OFF -> ON` sequence passed: OFF reached the world without
parking any launcher camera and completed its override, then ON reached the
world, parked exactly three cameras, and completed its own override. This
proves the comparison mode does not leak into a later process launch.
The hardened final 30-minute soak was also valid: 1,801 VrApi samples averaged
`72.16 FPS`, P10 `71`, P95 CPU+GPU `12.13 ms`, `1.28 stale/s`, and P95 App
`5.61 ms`. Refresh was exactly `72 Hz` for the entire capture; temperature was
`42 C` initially, `41 C` finally, and never exceeded `42 C`. Exact PID and
focus coverage were both 100%, no standalone `tr` appeared, and no crash or
session loss occurred. The aggregate report SHA-256 is
`CA1CF7BF2260D42023DC70F4D82E5151E20926E734AEFA16CAC67FCDA93458E1`.
The candidate passed the performance, soak, and automated lifecycle gates. The
user then manually accepted the exact Lab payload with Camera Park ON,
including the required gameplay and interaction checks. This approved its
promotion to Stable source. It does not assert that the newly installed Stable
package ran after installation; that separate runtime gate remains pending.

Aggregate-only evidence is stored outside Git under
`artifacts/benchmarks/v69-launcher-camera-park-20260903` and
`artifacts/benchmarks/v69-launcher-camera-park-final-20260903`; raw logcat and
device/account data are not included.

## v70 retained-Wrist and player-follow container screening (2026-09-04, Quest 3)

The combined Lab-only candidate used Vivecraft commit `54b787ff` and VEQ
`0.7.0-v70-canary.1`.  The exact deployed payloads were:

| Payload | SHA-256 |
| --- | --- |
| Vivecraft core | `965FCC5EB860EC9CFA4865926FCCCA0F9FCF1DAA61327606A36736885392A30E` |
| VEQ | `39F3FF5537C44E0B4BE4AA5BD58590929F4196A720BFDF1A7A5FCF39FCEDA41F` |

Both one-shot markers were consumed, the launcher entered GamerPotion's FPS
Stress Test, and the runtime loaded Fabric Loader `0.19.4`, Sodium
`0.9.2-alpha.4`, Lithium `0.25.3`, FerriteCore `9.0.0`, BadOptimizations
`2.4.1`, ImmersiveMC `1.6.0-alpha4.1`, Xaero Minimap `26.4.2`, the exact core,
and the exact VEQ candidate.  Vulkan/OpenXR submitted two views at
`1680x1760`; no crash, ANR, native fatal, or post-initialization XR failure was
observed.

The new core follows native world-backed container menus from the current HMD
position without replacing Minecraft's screen or movement input.  It also
routes an idle, empty-carried Wrist pointer through a direct textured-quad
pipeline instead of the full GUI extractor/renderer.  Host tests, clean core
and VEQ builds, artifact checks, and the Lab-only transaction gates all passed
before deployment.

The current Quest screen is a **promising performance screen, not final
release acceptance**.  The Wrist-visible interval was bracketed by the
runtime action-state count changing from 19 to 22.  Restricting both captures
to actual 72 Hz rows gives:

| Capture | Samples | FPS | P10 | Stale/s | App GPU | Temperature |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Previous confirmed Wrist interval | 86 | 65.76 | 61 | 9.06 | 6.39 ms | 41 C |
| Direct-pointer Wrist interval | 24 | 67.71 | 64 | 8.29 | 5.44 ms | 43 C |

The directional change is `+2.97%` FPS, `+3` P10, `8.5%` fewer stale frames,
and `14.87%` lower app-GPU time despite the newer run being two degrees hotter.
Within the newer run, the nearest eight hidden 72 Hz rows averaged `69.38 FPS`
versus `67.71 FPS` while visible, a `1.67 FPS` visible-Wrist cost.  That clears
the two-FPS screen threshold, but the short sample, rain/scene movement, and
different cross-run thermal path prevent a final causal claim.

The test also exercised repeated right-hand Grip and movement.  It did not
produce a trustworthy native-container open/close marker, so the new
player-follow container behavior still requires one short supervised chest
test.  Lab was stopped after the capture and the candidate was retained only
in `com.qcxr.qcxr.canary262`; Stable was neither started nor modified.  No raw
logcat, account data, device identifier, or captured image is committed here.

## v71 pre-RC dual-hand, bow trajectory, and retained carried-item smoke (2026-09-04, Quest 3)

The next candidate remained Lab-only in `com.qcxr.qcxr.canary262`; Stable was
not started, installed over, or modified.  Host tests and builds passed before
deploying this exact pair:

| Payload | SHA-256 |
| --- | --- |
| Vivecraft core | `CC2636DFE2E9FC143BDF7991B72BC4828934923E4AA603F618FAF8B2C907B800` |
| VEQ | `C53C81E1F7AF4E060D7537739456E7DBC5BFFD93FF6AEFE09F1EA7C1CA6C40DD` |

The core adds B-close support for player Inventory and Creative inventory,
negotiated per-hand attack-strength clocks with attack-speed modifiers from
the physical offhand item, and an optional block-aware bow centerline.  VEQ
routes a negotiated melee-capable offhand trigger to the independent clock
and retains the carried Wrist item in the content target instead of running
the full GUI extractor at headset rate.  The direct Wrist pointer remains a
separate headset-rate overlay.

Both deployment markers were consumed.  Runtime loaded Minecraft `26.2`,
Fabric Loader `0.19.4`, the exact core and VEQ pair, and the unchanged 70-mod
stack.  It entered `GamerPotion's FPS Stress Test` on the Adreno Vulkan driver;
OpenXR stayed `FOCUSED`, submitted two views, and retained valid HMD and both
controller poses.  Gameplay continued through a recorded bow kill.  No crash,
ANR, native fatal, or XR-session failure was observed.

The latest chronological 60-second VrApi screen produced `69.77 FPS`, P10
`66`, P95 CPU+GPU `15.84 ms`, and `4.62 stale/s`; temperature remained `50 C`
and QGO reported CPU/GPU levels `4/4`.  Against the documented v68 reference
(`69.64 FPS`, P10 `66.67`, P95 `15.20 ms`, `5.27 stale/s`), FPS and stale are
roughly neutral-to-slightly better while P95 is about `4.2%` worse.  This was
an uncontrolled gameplay/bow window with actual refresh varying from 72 to 75
Hz, so it is a smoke screen only and cannot accept or reject the candidate.
Around one observed Wrist transition, FPS changed from about `70.7` to `69.8`
and stale from `4.0` to `5.9/s`; the increase was brief rather than a proven
sustained carried-item cost.

**Decision: retained as a supervised Lab canary, not promoted.**  Host and
runtime safety gates pass.  Manual confirmation is still required for B close
on the normal Inventory, left-trigger offhand melee, per-hand cooldown feel,
the trajectory line in both eyes, and the Wrist carried-item presentation.
No raw logcat, account data, device identifier, or captured image is committed.

## v71 Lab RC1 corrected Wrist, dual-hand combat, Paired Strike and Energy Bow (2026-09-05)

This candidate is confined to Lab package `com.qcxr.qcxr.canary262`. Stable
`com.qcxr.qcxr.dev262` remained stopped and unchanged. Source is commit
`f33647e5f5288b76c4fa50737bf08d207e3a1b59`, tagged locally as
`v71-lab-rc1`. Evidence is frozen in follow-up commit
`67e9959640781b600d654772c3c8a2c0b6c1c4c3` and tag
`v71-lab-rc1-evidence`.

| Payload | SHA-256 | Scope |
| --- | --- | --- |
| Vivecraft Fabric JAR | `0661CB8877BD55B21C2A6D9F3759A66C74910F816934D4B8E72341C7946398D9` | `8,440,058`; Quest client and matching Fabric 26.2 server |
| VEQ Fabric JAR | `8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A` | `435,540`; Quest client only |
| Installed Lab base APK | `B40988DFB668FEE151969395E82CCEFE38FDA4F89BBE081B79B88F1F24695102` | `126,701,141`; existing v70 Lab host shell, not a v71 APK |
| Source bundle | `3FA3C8F732323B678924899F0DA38921BA4FBD628DFDF59AC8574B00866E5780` | `117,568,001`; code through `f33647e5`, excluding later evidence commit |

Host verification passed:

- `:common:test` and `:fabric:build` for Vivecraft.
- VEQ `check`, all registered self-tests, and `:mod-fabric:build`.
- Fabric mod IDs/versions and archive structure for both JARs.
- Paired JAR deployment self-test, transaction test, Stable-package deny gate,
  exact-hash allowlist, atomic promotion, and compensating rollback.
- Independent integrated review reported no P0 or P1 blocker. A broad old-peer
  offhand gate found during review was narrowed to entity attack/mining so
  ordinary offhand roomscale interactions continue to work.

Before deployment, the installed Lab APK was pulled and verified independently:
package `com.qcxr.qcxr.canary262`, versionCode `70`, versionName
`6.0.1-26.2-vivecraft-personal.11-rc.1`, ARM64 only, minSdk 29, targetSdk 34,
v2 signature present, 16-KiB ZIP alignment valid, and signer
`B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`.
The Lab profile was first returned to its exact v70 baseline. The candidate
pair was then deployed atomically, Play reconciliation consumed both one-shot
markers, and the physical profile hashes matched the table above. No root,
uninstall, clear-data, account-file read, or Stable-package mutation was used.

Runtime smoke passed on the Quest 3. The launcher entered the fixed
`FPS-Stress-Test` world; Fabric reported 70 mods, the exact Vivecraft and VEQ
payloads loaded, Vulkan selected the Qualcomm Adreno driver, OpenXR reached
`FOCUSED`, view count was two, and more than 3,600 frames were submitted. No
new crash, ANR, native fatal, Mixin-apply failure, `LinkageError`, or XR-session
loss was observed. Paired Strike protocol and server logic are present on the
integrated server; remote-server negotiation is not claimed.

The smoke retained three known nonfatal warnings: optional narrator
`libflite.so` was unavailable, Sodium emitted its retained target/workaround
warning, and surface-extent configuration warnings appeared. Startup free
memory was about `0.2 GiB`, so no memory-stability or soak claim follows. A
later aggregate-only 60-second Dynamic-refresh safety capture kept exact PID
and focus coverage at 100%, was valid, and measured mean `74.93 FPS`, median
`75`, and P10 `73`. This is a single uncontrolled safety sample, not a
counterbalanced performance result.

The corrected functional scope is:

- exact retained Wrist behavior from `d92ad5c2`, including live carried-item
  rendering; its known approximately four-FPS visible cost is accepted here;
- B closes normal Inventory/Creative directly but not Wrist, Chat, or Pause;
  world-backed containers retain their release/neutral guard;
- Y resolves the left controller to real offhand attack/break, while LT remains
  left use/place, RT remains main attack, and B remains main use outside GUIs;
- physical combat and same-block mining use per-hand routing and guards;
- Paired Strike requires the opposite hand, same target, a four-tick window,
  both charges at least 0.9, and one-shot scoped hurt-immunity bypass; PvP is
  disabled by default;
- Energy Bow reuses the existing trajectory snapshot and primitive buffers for
  a gold-to-cyan arc, moving pulse, and collision diamond. Off and Classic
  remain selectable.

**Decision: runtime-safe Lab RC1; manual acceptance pending.** It is not v71
Stable and has no performance claim. Required manual checks are B on normal
Inventory/Creative; Wrist pickup/drag/drop/carried item; Y and physical
left-hand combat; thirty alternating strikes; two axes on one target; two
pickaxes on the same block; both-eye Energy Bow; and regressions for shield,
teleport, ImmersiveMC, Grip and reverse hands. Remote Paired Strike additionally
requires installing the exact universal JAR on the Fabric 26.2 server and a
20-minute Tailscale test. Three cold starts and a 30-minute soak also remain.
The startup/XR smoke specifically does not prove Y or physical left-hand
offhand routing; those controls still require manual headset confirmation.

## v71 Lab RC2 Host gate: raw B close and pack-driven Energy Bow (2026-09-05)

RC2 source is commit
`9b725fcacdd49846b87cf5c103df6768134b158a`; the focused raw Quest-B close
fix is `eb3018d126b872cf74638489cd0b7108b0713961`. The stage began Host-only,
then the exact pair was atomically deployed to Lab. Stable
`com.qcxr.qcxr.dev262` remained untouched.

| Artifact | Version / size | SHA-256 |
| --- | --- | --- |
| Vivecraft Core | `26.2-1.3.15+qc.v71.rc2`; `10,062,636` bytes | `AAC5852BD1495AA0121A078F87312A644608F209A9190AE539CDC4F7763CD8FC` |
| Unchanged VEQ | `0.7.0-v70-canary.1`; `435,540` bytes | `8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A` |
| Existing v70 Lab APK | `versionCode 70`; `126,701,141` bytes | `B40988DFB668FEE151969395E82CCEFE38FDA4F89BBE081B79B88F1F24695102` |
| Bow atlas inside Core | `1,620,298` bytes | `971D0518655FCE01A692DBF5766CDA38273F09BB42EC71D971D0012A71C7360E` |

The exact pair digest is
`9952EA068712375E2364C0DF0EDBD9F876620D2E8EE10EF10106D6F6DEC6EBBE`,
calculated as SHA-256 over UTF-8
`core=<uppercase-sha256>\nveq=<uppercase-sha256>\n`.

The Vivecraft common suite reported `143` tests, zero failures, zero errors,
and zero skipped tests. The Fabric JAR built successfully, exposes the exact
RC2 Fabric version, and contains both default style JSON resources plus the
atlas. The tests cover style parsing and validation, fallback behavior,
immutable snapshot publication, render-contract preservation, and the
corrected raw-B close policy. This is not a Quest runtime result.

Optional resource-pack artifacts were built separately:

| Pack | Size | SHA-256 |
| --- | ---: | --- |
| Arcane Rift | `660` bytes | `6F3607227BAF001AA46CD9B5FBE943C1194DE3683B5DBD0A88B03BEEEAC9E323` |
| Frost Crystal | `651` bytes | `3E09F7A76673B65979496DDE552CC067F8887AAA8DA1465DC1EC0323581580F6` |
| Emerald Pulse | `662` bytes | `04D540115512ACFD62FC3CEE023B89BFAD07F9ADA524274925379128050B52F7` |

The packs are samples only. They were not added to a managed manifest or
enabled. They were copied to the Lab-only `instances/26.2/resourcepacks/`
directory after their physical hashes were verified. `options.txt` remained
`resourcePacks:["vanilla"]`; activation is a manual Minecraft resource-pack
choice.

The Lab deployment consumed the Core and VEQ markers and verified physical
SHA-256 values `AAC5852B...D8FC` and `8EB67999...427A`. The one-shot autoplay
entered `GamerPotion's FPS Stress Test`. Runtime evidence confirmed Minecraft
26.2, Vulkan on Adreno 740, OpenXR initialized, `viewCount=2`, and stereo frame
submission without a fatal or Mixin crash.

**Decision: RC2 runtime smoke passed; manual acceptance pending.** Before
promotion it still requires normal Inventory/Creative/chest B-close checks,
the default Energy and optional pack visuals in both eyes, the existing v71
dual-hand regression suite, and performance/cold-start/soak gates. No v71
Stable APK exists.

## Lab pre-JVM connectivity regression (2026-09-05)

The reported QuestCraft-logo hang occurred before Minecraft/Fabric startup.
The active Singularity kill-switch VPN had no DNS and Pojlib's metadata request
had no timeout. Stopping only that VPN restored connectivity; the same Lab
installation then loaded 70 mods, initialized Vulkan/OpenXR, reported two
views, and continuously submitted stereo frames without a fatal.

The bounded-probe fix at `b32fc3ca` passed all 63 Pojlib unit tests and a release
AAR build. The full Lab APK verifier passed package
`com.qcxr.qcxr.canary262`, versionCode 70, ARM64, minSdk 29, targetSdk 34,
v2 signature, 16-KiB alignment, required payload, and Lab-only dex gates. The
resulting APK SHA-256 is
`228301B630CC199666D6385F52533DFFCF9512242A6DF68F5021C6A4FFA74ABA`.
It remains Host-only and was not installed, so a blocked-network runtime test
 of this new APK remains pending. The running headset session was not stopped.

## 2026-09-08 — RC8 render-scale 0.8 long A/B: rejected

The exact installed RC8 Lab identity was measured in the fixed
`FPS-Stress-Test` world with QGO Dynamic.  Stable
`com.qcxr.qcxr.dev262` remained stopped and untouched.  The device's observed
performance levels were pinned in every receipt as CPU `8` / GPU `7`; the
application requested neither a refresh rate nor a performance hint.  Root
was not used during any acceptance capture.

The counterbalanced order was `A1→B1→B2→A2→A3→B3`, where A is the accepted
`renderScaleFactor=1.0` and B is the single-field `0.8` candidate.  Every arm
used a 180-second aggregate-only capture, and each restart was preceded by a
five-minute warm-up.  All six captures retained exact package, APK, signer,
Core, VEQ, PID, focus and declared-scale identity; no raw VrApi or Logcat data
was retained.

The primary analysis matched only identical observed-refresh strata.  It was
`INCONCLUSIVE` under the preregistered 50% overlap gate because pairs 1 and 2
had 46.4% and 42.5% overlap respectively; pair 3 had 75.1–75.6% overlap and
was comparable.  A separate, explicitly labelled 40% overlap sensitivity
analysis made all three pairs comparable and returned `REJECT`:

- combined matched P95 CPU+GPU improvement: `-1.29%` (B was worse);
- combined matched mean FPS change: `+1.07%`;
- combined matched P10 FPS change: `+0.77%`;
- combined stale change: B was worse by `0.876/s`, or `-53.83%` improvement;
- B increased stale frames in all three pairs: `1.526→2.661/s`,
  `1.871→2.662/s`, and `1.552→2.316/s`.

**Decision: reject render scale 0.8 and retain 1.0.**  Its small average-FPS
increase does not compensate for materially worse stale-frame pacing or the
mixed P95 result.  After the campaign the Lab was stopped and the original
configuration was restored byte-for-byte to SHA-256
`EDC270B10B16AD35166565755E76BABB7A5A2F28635C7878DF43989778611E8E`.
The primary analysis receipt SHA-256 is
`D68857871F9A9B8010E79A5C61EB1754E5E02EA65BB10A00961E571D587A1B9C`;
the labelled sensitivity receipt SHA-256 is
`B29ADC2A9D51E7A0A6796858A4AA603F9F01CFCA92EACC54053B47D04453BB7A`.
Neither result permits Stable promotion.
