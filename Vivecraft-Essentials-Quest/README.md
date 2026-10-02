# Vivecraft Essentials Quest

An LGPL-3.0-or-later Fabric client mod for Minecraft 26.2 and Vivecraft. This
MVP provides a palm-up wrist inventory, vanilla potion-effect rendering, six or
twelve configurable quick actions, and a nine-slot radial hotbar.

The implementation uses Vivecraft's public tracker API and its existing GUI
framebuffer. It does not contain Visor engine classes and does not create an
additional OpenXR layer or framebuffer.

## Requirements

- Minecraft 26.2
- Java 25
- Fabric Loader 0.19.3 or newer
- Fabric API 0.158.0+26.2 or a compatible newer release
- Vivecraft for Minecraft 26.2

## Configuration

The first launch creates
`config/vivecraft_essentials_quest/wrist_ui.json`. The in-game settings screen
can change the active logical hand, scale, position, rotation, potion display,
open angle, quick-action count, and radial-hotbar state. Logical hand selection
follows Vivecraft's reversed-hands option. With Mod Menu installed, its Configure
button opens this screen directly. The same screen is also listed in
Vivecraft Settings before Vivecraft's first category header, so Mod Menu remains
an optional fallback rather than the only in-game route. In VR the settings
screen stays attached to the selected wrist, so hand, scale, offset, rotation,
and reset changes preview on the next tracker tick.

Quick actions are defined in the same JSON file. The first default action tries
to invoke Xaero's world-map key mapping when that mapping is present.

The radial UI reuses Vivecraft's handed radial action and renders one compact
98x98 logical square per hand at a 392x392 physical raster. On Quest Touch, the add-on moves that action from B to
both squeeze/Grip inputs and removes the old Grip hotbar scroll bindings. Each
logical hand retains independent selection state: right Grip selects the main
hotbar, while left Grip performs one server-authoritative vanilla offhand swap.
The default square is about 0.40m wide at 0.30m from its opening controller and
faces the HMD when it opens, so the 3x3 contents remain readable without
foreshortening. Per-hand scale,
distance, and cursor sensitivity live in
`config/vivecraft_essentials_quest/grip_hotbar.json`. Both surfaces may be
visible at once; closing or selecting one hand does not block the other. While
ImmersiveMC reports an active interaction module, the radial is suppressed so
the interaction keeps priority. Vivecraft climbing also owns Grip while latched or while its
controller-specific climb action is enabled, preventing the radial from
opening on a climb grab.

## Building

Set `VIVECRAFT_FABRIC_JAR` to a compatible Vivecraft 26.2 Fabric JAR (or pass
`-Plocal_vivecraft_fabric_jar=C:\\path\\to\\Vivecraft.jar`) and run with Java 25:

```text
./gradlew clean check
```

The distributable JAR is written to `mod-fabric/build/libs`.

This code is derived from the LGPL-licensed VisorEssentialsPlus project only at
the feature/UI level. Visor engine and MPL-licensed runtime files are not copied
or packaged. See `DEPENDENCY_PROVENANCE.md` for the pinned build dependency.

## Current MVP limitations

- Quest runtime behavior still requires supervised testing on real hardware.
- Palm axis and wrist pose defaults may need one-time per-user calibration.
- Quick-action definitions are edited in JSON; the settings screen selects 6/12.
- The live preview edits the panel pose, but it does not visualize the palm
  open/close threshold while the settings screen is forced visible.
