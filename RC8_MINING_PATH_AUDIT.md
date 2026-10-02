# RC8 right-trigger mining path audit

## Verdict

No RC8-specific break is proven in the ordinary path from the physical Quest
right trigger to Vanilla block breaking. The path is internally complete when
the action is active and bound to the logical right origin, the hand is owned
by the world, the controller ray has a valid block target, and Minecraft reaches
its ordinary keybind handling.

One initially suspected cancellation path was disproved against the exact
artifact. A legacy `org/vmstudio/.../MinecraftMixin.java` exists in the source
tree, but `mod-core/build.gradle` includes only `org/questcraft/veq/**`. The
locked RC8 VEQ JAR contains no `org/vmstudio`, `MinecraftMixin`, or Visor API
class, and its loaded mixin configuration does not register that source.

## Ordinary path

1. `QuestGripBindingPolicy` removes the original Quest trigger suggestion for
   `key.attack` and binds the private handed action `keyMainAttack` to the two
   physical triggers.
2. `XRBindingsMixin` applies that policy to the Quest Touch interaction
   profile.
3. `keyMainAttack` is a registered hidden in-game `HandedKeyBinding`; OpenXR
   creates and attaches the corresponding action.
4. `PerHandWorldActionRouter` samples logical `RIGHT`, checks lifecycle and
   per-hand ownership, captures the right controller target, updates
   `minecraft.hitResult`, emits one `keyAttack` click on a fresh press, and
   holds `keyAttack` down while the trigger remains held.
5. The router runs after the OpenXR poll and pose update but before Vanilla
   `handleKeybinds`. Vivecraft prevents the later pick pass from replacing the
   routed target.
6. Vanilla consumes the click in `startAttack()` and uses the held state in
   `continueAttack()`, which call `startDestroyBlock` and
   `continueDestroyBlock` respectively.
7. RC8 removed the RC7 start/continue interception. Its remaining mining guard
   only coordinates duplicate physical/offhand contributions and does not own
   the Vanilla main-hand session.

## Intentional gates

RT mining is fail-closed when any of these is true:

- the OpenXR action is absent, inactive, disabled, unbound, or has a mismatched
  origin;
- a higher-priority interaction, climbing, or keyboard action owns the origin;
- the player/world/game mode/VR identity changes, a screen is open, tracking or
  pose is lost, seated mode is active, the bow owns both hands, or the hand is
  busy using an item;
- Wrist, ImmersiveMC, climbing, Grip, or another declared per-hand owner holds
  the hand;
- B main-use wins on the same tick;
- the ray is a miss, entity, air, a different block, or outside allowed reach;
- Vanilla or the server rejects the target.

After an unknown sample, lifecycle replacement, or ownership loss, a held
trigger must be physically released before a new press may start mining. This
is deliberate protection against stale-target actions.

## Rejected overlay hypothesis

Do not patch the historical Visor `MinecraftMixin` or add a Visor API dependency
to RC8. Neither is present in the compiled artifact, so such a change would not
repair the running code and would expand the runtime surface incorrectly.

The actual compiled overlay ownership paths are the Quest implementations in
`HandOwnershipSnapshot`, `WristOverlayHandler`,
`ExternalScreenOverlayHandler`, and `RadialHandler`. Their declared ownership
gates remain valid candidates for diagnostic classification, but no additional
downstream `handleKeybinds` cancellation has been found in the exact RC8 JAR.

## Evidence boundary and next decision

Host tests prove policy, ownership latches, and the static call chain. They do
not prove the live action state, origin, target, ownership, or Vanilla call on
a Quest controller. The locked diagnostic Lab is therefore the next step only
if the ordinary RC8 manual test reports `no start` or `starts then stops`.

Use the existing transition-only diagnostic to distinguish:

- action/binding/origin failure;
- lifecycle or ownership suppression;
- a routed `keyAttack` with no Vanilla START/CONTINUE;
- target/game-mode rejection; or
- a healthy Vanilla mining flow.

Do not consider the main-attack mux fallback unless diagnostics prove that
`keyMainAttack` is `UNKNOWN` while the logical-right proxy action follows the
physical trigger correctly.
