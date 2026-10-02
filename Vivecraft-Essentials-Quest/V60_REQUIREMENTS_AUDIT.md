# VEQ v60 requirements audit

Audited against integration commit `50ea009e`. This branch is host-only and
has not been installed or run on Quest.

## Implemented in the integration baseline

- Palm-up wrist inventory uses the vanilla 26.2 `InventoryScreen`, Vivecraft's
  logical main/off-hand pose, `0.20/0.10` hysteresis, and 150 ms open/close
  delays. Logical hands follow Vivecraft's reversed-hands mapping.
- Potion effects use Minecraft 26.2's native inventory sprites and duration
  labels instead of the old VEP texture paths.
- Six/twelve quick-action layouts, item icons, custom labels, commands, and key
  mappings are represented in the persisted JSON and rendered on the wrist.
- The wrist UI is drawn through Vivecraft's existing GUI framebuffer. It does
  not add an OpenXR layer or duplicate Vivecraft's HUD renderer.
- The radial contains nine real hotbar stacks. Quest bindings remove squeeze
  from hotbar previous/next, move the radial off B and onto both Grip inputs,
  and preserve the contextual `vrInteract` bindings.
- Grip arbitration suppresses the radial while the wrist screen is open or a
  Vivecraft/ImmersiveMC interaction module is active.

## Closed by this canary

- Adds an open-angle editor while retaining a nonzero close hysteresis.
- Makes the settings screen itself a live wrist-pose preview, updated from the
  Fabric client tick so it also works when single-player is paused.
- Exposes the settings screen through Mod Menu while keeping Mod Menu optional
  and outside the distributable JAR.
- Inserts the same screen into Vivecraft Settings using one return-value mixin
  on `VivecraftMainSettings.getEntries`. The bridge copies the returned list
  and inserts before the first category, so it does not patch Vivecraft's
  option API or rely on a fixed VR-screen row.
- Prevents the Grip radial from opening while Vivecraft is latched to a
  climbable or its controller-specific climb action owns the pending grab.
- Confirms that radial sector changes already produce one light pulse through
  Vivecraft's `TwoHandedScreen`; VEQ deliberately does not add a second pulse.
- Prevents a missing Xaero World Map from silently turning the `World Map`
  quick action into Xaero Minimap's `Toggle Minimap` action.

## Still partial or missing

- Quick-action names/icons/key mappings are editable only in JSON. There is no
  in-game quick-action editor in the Quest adapter.
- Palm-axis selection and open/close delays remain JSON-only. The live preview
  shows pose edits but intentionally forces the settings screen visible, so it
  cannot preview the gesture threshold itself.
- The radial inherits selection-on-Grip-release from Vivecraft's default
  `radialModeHold=true`.
- Wrist arbitration treats an open wrist inventory as focused; it does not
  distinguish whether the pointer is inside the inventory rectangle.
- Xaero Minimap is merely rendered by the existing Vivecraft HUD path. VEQ has
  no dedicated minimap placement editor, so this canary does not expose a fake
  map toggle that cannot control Xaero safely. The first quick action remains
  the World Map route, but full-screen World Map requires the separate Xaero
  World Map mod; v60 currently bundles only Minimap.
- Hardware gates remain mandatory: both-eye rendering, palm calibration,
  drag/drop, reverse hands, Grip/ImmersiveMC precedence, and potion background.

The canary is suitable for a supervised post-v60 feature test. It should not be
merged into the already measured v60 APK without a short hand/eye interaction
test because the settings screen now follows the selected wrist.
