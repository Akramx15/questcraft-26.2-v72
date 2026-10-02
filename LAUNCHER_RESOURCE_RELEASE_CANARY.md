# Launcher resource-release v71 contract

The release is enabled only for these exact build identities:

- Lab: `com.qcxr.qcxr.canary262`, code `71`, name
  `6.0.1-26.2-vivecraft-personal.12-rc.3`.
- Stable: `com.qcxr.qcxr.dev262`, code `71`, name
  `6.0.1-26.2-vivecraft-personal.12`.

Every other package/version tuple fails closed. Exact Lab and Stable manual
launches release by default. An authenticated one-shot Lab A/B run may request
`OFF` or `ON`; intent data can never override Stable. The v71 autoplay helper
defaults acceptance runs to `ON`; `OFF` additionally requires the explicit
`-AllowReleaseOffControl` switch and is reserved for labeled A/B controls.

After the Unity-to-OpenXR handoff latch succeeds, the launcher stops its
microphone loop, disables every camera and root in the launcher scene, detaches
and releases distinct camera render targets, clears the skybox, and requests
`Resources.UnloadUnusedAssets`. Each resource is handled independently so a
single cleanup failure produces a degraded marker without skipping the rest.
It deliberately does not call `UnityPlayer.unload`; the existing full-process
QuestCraft recreation remains the recovery path when Minecraft exits.

Known gate: the frozen RC3 Core raises `gameReady` immediately before its
OpenXR loader initialization, not after a post-initialization acknowledgement.
The 240-second watchdog therefore protects the pre-handoff wait, while an
early JVM exit requests a coalesced full-process restart; it cannot by itself
prove that Minecraft acquired OpenXR after the latch opened. Stable promotion
remains blocked until repeated Lab cold starts and failure/recovery checks show
that this handoff is reliable on the target Quest.

Host validation does not contact a headset:

```powershell
pwsh -NoProfile -File scripts/run-vivecraft-local-autoplay.ps1 -Action SelfTest
Push-Location Pojlib
try {
    $env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    .\gradlew.bat --no-daemon testReleaseUnitTest
}
finally { Pop-Location }
```

The diagnosis run with release OFF grew by roughly `443.57 MiB` in `15.21`
minutes (`31.78 MiB/min` OLS). The corresponding release-ON world window lasted
`47.64` minutes and grew only `34.09 MiB` (`0.62 MiB/min` OLS); its last
`29.386` minutes grew `11.321 MiB`. This is strong Lab evidence, not Stable
acceptance. The rebuilt permanent Lab still requires repeated cold starts,
manual VR interaction, matched-refresh performance, and the required long
memory soaks before Stable promotion.
