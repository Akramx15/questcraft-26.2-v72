# RC8 overlay/attack integration audit

## Verdict

`NO_RUNTIME_GAP`

The proposed legacy `MinecraftMixin` cancellation fix does not apply to the
exact RC8 runtime. No runtime source change is retained by this audit.

## Frozen inputs

- Source HEAD: `eab4aa673f50e2ea44eaa5acad8a33fee5849566`
- Managed Vivecraft Core SHA-256:
  `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB`
- Managed VEQ SHA-256:
  `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`
- VEQ id/version: `vivecraft_essentials_quest` / `0.7.0-v71.rc6`

## Evidence

1. `Vivecraft-Essentials-Quest/mod-core/build.gradle` includes only
   `org/questcraft/veq/**` in the main and test Java source sets.
2. The active Fabric descriptor registers only
   `vivecraft_essentials_quest.mixins.json`. That config declares package
   `org.questcraft.veq.mixin` and does not list the historical
   `org.vmstudio.essentials.core.mixin.client.MinecraftMixin`.
3. Both the managed RC8 VEQ archive and the clean Java 25 build contain 293
   ZIP entries, zero `org/vmstudio/**` entries, and zero historical
   `MinecraftMixin.class` entries.
4. The compiled VEQ hook is `MinecraftHandActionMixin`, which polls
   `HandActionContext` at `Minecraft.tick` HEAD. It does not cancel
   `Minecraft.handleKeybinds`.
5. `PerHandWorldActionRouter` gates routing through
   `HandOwnershipSnapshot`, then writes the main attack state through
   `VRInputAction.setKeyBindState`. It does not drain
   `keyAttack.consumeClick()`.
6. `HandOwnershipSnapshot` already checks per-controller ownership for Wrist,
   Bow, ImmersiveMC, climbing, external overlay use, and radial Grip before
   allowing a world action.
7. The exact Quest Vivecraft Core has scoped hooks in `handleKeybinds`, but no
   full-method overlay-focus cancellation matching the alleged legacy path.
8. The retained `org/vmstudio/**` tree and `visor_essentials.mixins.json` are
   historical attribution/reference sources. They are excluded from the
   source set and distributable JAR.

Therefore there is no downstream legacy overlay cancellation that can suppress
or replay the RC8 right-trigger route. Adding a second latch/predicate for that
dead path would increase state-machine risk without affecting the installed
runtime.

## Host verification

Environment:

- Java: Eclipse Adoptium `25.0.4.1`
- Build dependency: the exact managed Vivecraft Core hash above
- Network/device use: none

Command:

```powershell
$env:JAVA_HOME = Join-Path $env:USERPROFILE `
  '.gradle\jdks\eclipse_adoptium-25-amd64-windows.2'
$env:VIVECRAFT_FABRIC_JAR='..\Pojlib\src\main\assets\mods\vivecraft-26.2-1.3.15-quest.bin'
.\gradlew.bat --offline --no-daemon clean check :mod-fabric:build
```

Result: `BUILD SUCCESSFUL` (`88` actionable tasks; `87` executed, `1`
up-to-date).

Clean-build VEQ JAR:

- File: `VivecraftEssentialsQuest-0.7.0-v71.rc6+mc26.2-fabric.jar`
- Size: `444150` bytes
- SHA-256:
  `ADD95706C141FA7B31A0DE773511BD98C8FA8DEC3E2922109D7CB33DC0196A76`

The clean-build archive hash is not byte-identical to the managed archive.
Entry-level comparison found only the generated Architectury inject class path
changed; its generated namespace includes a build-specific token. This build
artifact is evidence only and is not a replacement candidate.

## Residual risk and next diagnostic

- If a legacy VisorEssentials/Visor JAR is deliberately reintroduced later,
  repeat this audit against the actual profile before considering a shared
  overlay latch.
- If right-trigger mining still fails in RC8, instrument the live compiled
  `org.questcraft` ownership/transition route and Vivecraft's normal
  `startAttack` lifecycle. Do not patch the excluded `org/vmstudio` source.
- Native container input remains outside this alleged cancellation path and was
  not changed.

## Diff contract

Documentation only: this report is the sole tracked change. Runtime Java,
resources, Gradle logic, manifests, managed binaries, APKs, and device state are
unchanged.
