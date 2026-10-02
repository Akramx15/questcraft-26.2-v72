# QuestCraft 26.2 Dev.2 engineering handoff

> [!IMPORTANT]
> This is a frozen historical Dev.2 handoff. It is not the source of truth for
> Personal v63. Use `PROJECT_STATUS.md`, `STACK.lock.json`, `TEST_RESULTS.md`,
> and `MODS.md` for the current Vivecraft build and acceptance gates.

Current Personal v63 identity, provided here only to prevent accidental reuse
of the historical Dev.2/v60/v61 values below:

- Branch: `feature/quest3-vivecraft-personal-v63`
- Package/version: `com.qcxr.qcxr.dev262`, code `63`,
  `6.0.1-26.2-vivecraft-personal.4`
- Output: `QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-26.2-personal.4-local.apk`
- APK SHA-256: `0A65715BCD20E64285014173BCE4714073925B691122434A70B81E39BE074A69`
- Pojlib AAR SHA-256: `FA626CC955B3F0D255B2922F086363C397633F009D7F199BB090715BA6255714`
- Vivecraft SHA-256: `FD4023BA52A4D1E14532F126D4E3123048BF46BAC380CFAF9FC9D8972C305D85`
- Vivecraft Essentials Quest SHA-256:
  `E9AC2FC0A91083D3DE461F207F4FE9F864730CC819A7ADA360B35DA07BA21F09`

Everything after this notice, including code `56` and the Dev.2 APK hash, is
deliberately historical evidence. Private branch, remote, and clone details
were removed from the public snapshot. Do not rewrite the remaining facts as
v63 instructions.

Last updated: 2026-08-28

This document is the historical Dev.2 handoff for another developer or coding
agent. Use it only when investigating that older line; consult the Personal v63
files linked above before rebuilding or touching a test headset.

## Repository snapshot

- Public repository: `https://github.com/Akramx15/questcraft-26.2-v72`
- Public branch: `main`
- The public repository begins with a squashed root commit. Historical private
  remotes, working branches, and commit ancestry are intentionally absent.
- The reference repositories are
  `https://github.com/necat101/questcraft-26.2-experiment.git` and
  `https://github.com/Vivecraft/VivecraftMod.git`. Do not push this reconstructed
  history to either reference repository.
- The separate necat101 reference repository's `main` has no shared public
  history with this snapshot; do not open a normal upstream pull request
  without first planning a manual port or rebase.
- Android package: `com.qcxr.qcxr.dev262`
- Application label: `QuestCraft Dev 26.2`
- Version code: `56`
- Version name: `6.0.1-26.2-dev.2`
- Minecraft profile: `26.2`
- Unity: `2022.3.62f3`
- ABI: ARM64 only
- Minimum/target SDK: 29/34
- Renderer: Vulkan is forced for the 26.2 profile
- XR provider: OpenXR through the Quest-custom Vivecraft build
- Local verified APK SHA-256:
  `90373325B1C30A87C969719C0BF2919301AFE00909E50C5BCE8CA266945B2EF7`

The APK is intentionally not committed. The source, bundled runtime assets,
Pojlib AAR, build verifier, checksums, and complete build instructions are in
the repository.

This historical handoff has component licenses inside the source trees but no
single top-level LICENSE/NOTICE covering the combined repository. Review the
Pojlib/QCXR and Vivecraft component licenses before changing repository
visibility or redistributing a binary publicly.

## Safety and scope

This branch is a separate development application. It must not uninstall,
replace, clear, or migrate the stable `com.qcxr.qcxr` package automatically.
The friend's Minecraft server is outside this repository and must not be
changed.

Never commit or upload:

- APK/AAB outputs or Unity/Gradle build logs;
- Microsoft/Minecraft account files, cookies, tokens, or browser state;
- Android device serials, raw logcat, OVR Metrics CSV files, worlds, or saves;
- Quest-side backups from `/sdcard/Download/QuestCraft-Dev-Backups`;
- debug or production keystores and signing passwords;
- local Unity `Library`, `Logs`, `Temp`, or generated `Builds` folders.

The root `.gitignore` covers the normal generated outputs. Run a secret scan
and `git status --short` before every push.

## Architecture and XR ownership

The build has three source trees:

1. `QCXR-XR-Wrapper/` is the Unity launcher and initial XR environment.
2. `Pojlib/` installs the Java runtime, Minecraft libraries, native Android
   compatibility layer, managed mods, and starts the JVM.
3. `Vivecraft-26.2-Quest/` owns VR inside Minecraft.

Unity does not own the gameplay OpenXR session. During launch,
`InstanceButton.CompleteOpenXRHandoff()` calls `JNIStorage.CloseXR()`, Unity
releases OpenXR, and Pojlib releases the handoff gate. Vivecraft then creates
the gameplay `XrInstance` and `XrSession` in `MCOpenXR`. Any gameplay OpenXR
feature, refresh-rate, reference-space, or processor-performance change belongs
in `MCOpenXR`, not in the Unity launcher.

For Minecraft 26.2, Pojlib appends `--graphicsBackend vulkan`. Changing an old
launcher renderer selector does not override that argument.

## Implemented Dev.2 work

The review branch contains separate commits for:

- removing four confirmed orphaned Unity `.meta` files;
- preventing launch before Microsoft authentication is ready;
- stabilizing the Quest 3 Vulkan/LWJGL runtime path;
- placing title, connection, loading, message, and death screens in front of
  the current headset pose when opened, without moving the player or world;
- preserving profile settings and applying invalid-option migration only when
  needed instead of rewriting user settings every launch;
- updating Fabric Loader and the managed 26.2 mod set;
- building and verifying the separate Dev.2 APK.

The Vulkan/LWJGL stabilization commit specifically restores the Pojav/FCL
Vulkan ABI exports, resolves Android's Vulkan loader safely, guards a missing
`POJAV_RENDERER` environment variable, seeds the required Quest Vulkan
extensions, and expands the JVM only to the Linux cpuset permitted to the app.
It then passes that effective count through `-XX:ActiveProcessorCount`; it does
not set Quest CPU/GPU clock levels.

The settings fix seeds bundled defaults only when their destination files are
absent. Its one-time marker is
`.questcraft-26.2-options-default-fix-v1`; before changing an affected existing
file it preserves `options.txt.before-26.2-default-fix`. The migration changes
only these exact old defaults: `gamma:-0.2` to `gamma:0.5`,
`simulationDistance:4` to `simulationDistance:5`, and the obsolete
`["vanilla","fabric"]` resource-pack list to `["vanilla"]`. User music,
render-distance, Sodium, and Vivecraft choices are not rewritten. Only the
platform-required Vulkan/OpenXR launch/config fields remain enforced.

The VR menu change does not recenter the world. With
`menuAlwaysFollowFace=false`, supported menu-room screens are placed once in
front of the current HMD pose when opened; with `true`, the menu follows the
face continuously. `DeathScreen` receives its own front-of-head placement even
when it replaces another screen. Player coordinates, `roomOrigin`, and OpenXR
app space are untouched.

`UnityPlayerActivity.reinitUnity()` still starts a fresh launcher activity and
immediately calls `Process.killProcess()`. Do not redesign that lifecycle from
the old music report alone: revisit it only if the pending three-run test
reproduces settings loss after a clean JVM exit.

See `git log --oneline --reverse 8b0100c3..HEAD` for the exact Dev.2 commit
sequence in a fresh clone. `BUILDING.md`, `MODS.md`, `CHECKSUMS.sha256`, and
`scripts/verify-dev-apk.ps1` contain the reproducible details.

## Runtime validation completed

The Dev.2 APK was installed on an authorized Quest 3 without replacing stable
QuestCraft. The following smoke checks completed:

- the launcher, Java runtime, Vulkan path, and Vivecraft OpenXR session start;
- the `26.2` profile reaches Minecraft and joins an existing multiplayer
  server through Tailscale;
- Fabric reported the expected managed mod graph when the full pack was
  present, and reported the reduced graph when optional mods were disabled;
- ImmersiveMC loaded on the client and server entry succeeded, although its
  multiplayer features still require a compatible server-side installation;
- the music setting was observed as `soundCategory_music:0.0` after a later
  run, but the full three-cold-start persistence gate is not complete;
- Vulkan/OpenXR and Quest 3 identity were confirmed from runtime logs;
- no thermal throttling was present during the measured sessions.

This is not a final acceptance result. The normalized full-mod soak test and
several interaction checks listed below remain open.

## Performance root cause found on the test headset

The large frame-rate regression was primarily a system performance-profile
problem, not enough evidence to blame a specific mod.

Quest Games Optimizer (QGO) had applied its Home profile while the Dev package
had no explicit processor profile. Android debug overrides therefore forced:

```text
debug.oculus.cpuLevel=2
debug.oculus.gpuLevel=0
debug.oculus.adaclocks.force=1
```

These debug properties force the runtime performance levels and would override
any current or future app hint. Dev.2 itself does not call
`xrPerfSettingsSetPerformanceLevelEXT`. In a VrApi line such as
`CPU4/GPU=2/0`, the `4` after `CPU` is the measured core number; the actual
CPU/GPU levels are `2/0`.

The user created a QGO profile for `com.qcxr.qcxr.dev262` with CPU level 4 and
GPU level 4. QGO correctly restores its Home `2/0` profile after the app exits,
so the Dev build must be launched through the matching QGO profile for this
controlled test. Do not persist clock overrides through Magisk, and do not use
the unsafe `8/7` profile.

### Measured core-only comparison

Both samples used Fabric API, Sodium `0.9.2-alpha.4`, Lithium, and the custom
Vivecraft core; the ten optional candidates were disabled. Values are one-minute
OVR Metrics windows from the same multiplayer cave scene.

| Metric | Forced `CPU2/GPU0` | Forced `CPU4/GPU4` |
| --- | ---: | ---: |
| Mean FPS | 51.69 | 91.48 |
| Median FPS | 56 | 92 |
| P10 FPS | 19 | 86 |
| Mean app GPU time | 9.05 ms | 4.61 ms |
| Mean CPU utilization | 87.96% | 80.32% |
| Mean GPU utilization | 56.84% | 52.18% |
| Maximum battery temperature | 45 C | 45 C |
| Power-level state | 0 (no throttle) | 0 (no throttle) |

This proves that the processor override was a major bottleneck, but it is not a
strict mod benchmark: the `2/0` run was fixed at 72 Hz, while the `4/4` run had
no refresh-rate override and the display varied around 90 Hz. Repeat all mod
comparisons at one fixed refresh rate, preferably 72 Hz.

## Refresh-rate behavior

`MCOpenXR.initDisplayRefreshRate()` currently enumerates the available rates
and requests the last (highest) value unconditionally. When QGO leaves
`debug.oculus.refreshRate` unset, current Quest firmware may use a variable
display mode; the measured `4/4` session moved roughly between 78 and 102 Hz.

Before accepting performance results, choose one of these approaches:

1. set the Dev QGO profile to a fixed 72 Hz for repeatable tests; or
2. implement a Vivecraft setting that requests an explicit user-selected rate.

Do not interpret a variable-refresh session as an apples-to-apples comparison
with a fixed 72 Hz session.

## Mod state and A/B harness

The source manifests contain the 14-component set documented in `MODS.md`.
The last device operation restored all 14 real JARs and removed all temporary
disable markers, but the full set has not yet been benchmarked at normalized
`CPU4/GPU4` and fixed 72 Hz.

The minimum core set is:

- Vivecraft;
- Fabric API;
- Sodium `0.9.2-alpha.4`;
- Lithium `0.25.3`.

The ten independently managed candidates are:

- BadOptimizations;
- Cloth Config;
- EntityCulling;
- FerriteCore;
- ImmediatelyFast;
- ImmersiveMC;
- Krypton;
- Mod Menu;
- MoreCulling;
- Text Placeholder API.

Use `scripts/quest-mod-ab.ps1` instead of deleting JARs manually. The launcher
recreates managed files, so manual deletion is not a durable test. The script
moves the original JAR to a device backup, installs a valid 22-byte empty ZIP
placeholder that Fabric ignores, preserves the launcher-visible filename, and
verifies `instances.json` before and after every toggle.

```powershell
# One connected, authorized ADB device is detected automatically.
.\scripts\quest-mod-ab.ps1 -Action Status
.\scripts\quest-mod-ab.ps1 -Action Disable -Mod 'ImmediatelyFast.jar'
.\scripts\quest-mod-ab.ps1 -Action Restore -Mod 'ImmediatelyFast.jar'
.\scripts\quest-mod-ab.ps1 -Action Measure -Seconds 60

# When more than one ADB device is connected:
.\scripts\quest-mod-ab.ps1 -Action Status -Serial '<adb-serial>'
```

Disable/restore operations refuse to run while the target package has any
process. The script never force-stops, launches, uninstalls, or clears the app.
Raw logs are not persisted. On firmware where a timestamped Logcat query
returns no VrApi rows, use the OVR Metrics CSV only as a local fallback and do
not commit that CSV.

The Sodium `0.9.1` rollback was tested once and performed worse in that session,
but the later QGO discovery means the test was not normalized. Retain
`0.9.2-alpha.4` for now and repeat a fixed `4/4`, 72 Hz A/B before drawing a
final Sodium conclusion.

## Open items and known issues

1. Run the full 14-component pack for 15-20 minutes at fixed 72 Hz and
   `CPU4/GPU4`, then run a final 30-minute multiplayer soak.
2. Establish the core baseline under the same settings, then add candidates in
   the order in `MODS.md`. Inspect both eyes after each culling change.
3. Complete three cold-start settings-persistence runs, including music,
   render distance, simulation distance, and one Sodium option.
4. Complete title/world/multiplayer/connect/loading/death placement tests after
   moving at least three metres from the initial room origin. Confirm hand rays
   and clicks remain aligned.
5. Boundary/world recenter remains out of scope for Dev.2. Do not alter
   `VRPlayer.roomOrigin`, OpenXR app space, or player coordinates as a shortcut.
6. Measure Tailscale `direct` versus `DERP`. Do not add an HTTP proxy,
   `portproxy`, or firewall rule without a separate reason and authorization.
7. ImmersiveMC multiplayer features require server support. Do not modify the
   friend's server from this repository.
8. There is no ADB intent that directly launches the `26.2` profile. The green
   Play action still requires launcher UI interaction.
9. Guardian/boundary world recenter and a Visor port for 26.2 are not
   implemented in Dev.2.

ViveMonkeCraft was rejected and is absent from the manifests and packaged
defaults. Xaero's Minimap is recorded only in `optional-mods.json`; no Xaero JAR
is committed or enabled by default.

## Optional source-level performance improvement

Vivecraft currently relies on the OpenXR runtime default performance level.
For explicit behavior, `MCOpenXR` can request the optional
`XR_EXT_performance_settings` extension and, after each successful
`xrBeginSession`, request `SUSTAINED_HIGH` for CPU and GPU. The calls must be
guarded by extension availability and failures must be logged without aborting
startup. Never use a sustained Boost hint.

This source change is not implemented in Dev.2. QGO/debug system properties
would override such a hint, so first validate the normalized QGO profile. If
the patch is later adopted, increment the custom Vivecraft revision from `r2`
to `r3`, rebuild Vivecraft, stage it into Pojlib, rebuild the AAR and APK, and
update all manifests, checksums, documentation, and verifier expectations.

## Reproducibility and CI limits

The source is complete, but the build is not fully hermetic. Vivecraft pins
`fabric_loom=1.15-SNAPSHOT`; both Gradle wrappers download distributions without
checked-in `distributionSha256Sum` values; and Foojay may download the JDK 25
toolchain. Record resolved dependency/tool versions when producing a release.

GitHub Actions currently runs Vivecraft common tests and builds its Fabric JAR.
It does not rebuild Pojlib or Unity, assemble an APK, verify Android metadata,
or run Quest hardware tests. A green workflow is therefore a component check,
not proof that the complete APK is reproducible or accepted on-device.

## Clone and continue

```powershell
git lfs install
git clone --single-branch --branch main `
  https://github.com/Akramx15/questcraft-26.2-v72.git
Set-Location questcraft-26.2-v72
git lfs pull
git status --short --branch
```

Recommended reading order for another coding agent:

1. `AGENTS.md`
2. `AI_HANDOFF.md`
3. `BUILDING.md`
4. `MODS.md`
5. `CHECKSUMS.sha256`
6. `scripts/verify-dev-apk.ps1`
7. `scripts/quest-mod-ab.ps1`

Create a new branch from `main` for additional work. Keep reference remotes
read-only, keep APK/log/device data out of Git, and do not claim a runtime
acceptance result until the pending gates above pass.
