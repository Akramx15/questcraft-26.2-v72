# RC8 native right-trigger fallback audit

## Verdict

The native `/actions/ingame/in/key.attack` fallback is **rejected** for RC8.
No runtime implementation is retained in this branch. The safe result of this
Host-only audit is to keep exact RC8
`ea2177498bea46fd949e70ae5382ef2387c86531`, collect its RT classifier evidence,
and select a transport only after the classifier identifies the failing layer.

The upstream Quest binding is useful evidence, but not a drop-in fix. Official
Vivecraft binds native `key.attack` to the physical right trigger. Personal
QuestCraft moved RT to the private handed `vivecraft.key.mainAttack` action so
Wrist, Grip, ImmersiveMC, B/Y, reverse-hands, dual-hand mining, and lifecycle
ownership can be arbitrated together before the Vanilla key is written.

## Why the Host prototype was rejected

A temporary, default-off prototype was compiled and exercised with deterministic
tests, then removed. It selected exactly one native physical trigger, removed the
private proxy in that mode, fixed reverse-hands for the OpenXR session, used a
fresh ownership snapshot plus an exact-identity prior-tick route permit, blocked
simultaneous B, and kept the router target-only so there was one steady-state
press/click writer.

Those checks passed, but they cannot establish runtime safety because the
provider and router do not share one transition state machine:

1. `MCOpenXR.processInputs()` runs at the render/OpenXR poll boundary, while the
   VEQ router runs at `Minecraft.tick()` HEAD. A previous-tick permit can prove
   runtime identity, but not physical-release history for the current provider
   action.
2. OpenXR core records an ingame action in `unpressedSetKeys` when its action set
   becomes inactive. Core may later re-press that still-held raw action when the
   key is up.
3. Therefore this concrete sequence is unsafe: hold RT, enter a GUI/owner that
   rejects world attack, leave the GUI while still holding RT, let routing become
   ready. The stale core re-press marker can synthesize an attack without a new
   physical press, while the router's own latch is still waiting for release;
   the target can consequently be stale.
4. Releasing and draining `minecraft.options.keyAttack` is global. It cannot
   prove that the removed click belongs to native RT rather than a concurrent
   hardware or mod producer.
5. An unhanded OpenXR action can aggregate origins. Suggested bindings provide
   one Quest origin, but Host tests cannot prove that runtime rebinding/profile
   behavior preserves that cardinality and origin identity.
6. A provider-private mixin adds a default-off compatibility surface. Host
   compilation proves its current signature, not its runtime application order
   or behavior across non-Quest profiles.

Accordingly, “one writer in controlled steady state” is proven; “no unintended
attack across transitions” is not. That is enough to reject deployment.

## RC8 versus mux fallback `6c30c1c8`

The mux is narrower and safer than the native prototype because raw-source
selection, ownership, target refresh, synthetic Vanilla key press, and release
remain in the existing router state machine. It locks the selected raw source
for a full press and suppresses source changes until release.

It is not a universal fix: a sampled dedicated action remains authoritative. If
that action reports a healthy DOWN but the manually synthesized Vanilla edge is
what fails, the mux deliberately does not switch to its fallback.

| RC8 classifier evidence | Decision |
| --- | --- |
| `VANILLA_MINING_FLOW_OBSERVED` | Keep RC8. The transport worked; inspect target, mode, tool, reach, ownership, or server response. |
| `OWNERSHIP_BLOCKED` | Keep RC8. Repair the owner/release transition; changing transports would bypass safety. |
| Target/ray not ready or mismatched | Keep RC8. Repair logical-right target capture. |
| Dedicated `keyMainAttack` absent, inactive, unbound, or UNKNOWN while logical-right `keyOffhandUse` follows RT correctly | Consider mux `6c30c1c8` in a supervised Lab A/B. |
| Dedicated action DOWN and route READY, but no Vanilla start is observed | Native transport is a useful diagnosis, not an approved fallback. Instrument the Vanilla edge before changing transport. |
| `VANILLA_START_REJECTED` or `VANILLA_CONTINUE_NOT_ACCEPTED` | Neither fallback. Inspect game mode, destroy session, block target, and server acceptance. |
| `STOP_WITHOUT_INPUT_RELEASE` | Neither fallback. Repair lifecycle/ownership release first. |

## Minimum design required before revisiting native RT

A future implementation must satisfy all of these in one supervised Lab-only
change:

- a canary-owned `SUPPRESSED_UNTIL_PHYSICAL_NEUTRAL` state that is updated at the
  provider poll boundary;
- removal or bypass of the matching `unpressedSetKeys` auto-repress marker;
- exact ownership of the native click edge, without draining the shared global
  `KeyMapping` queue;
- one Quest/Pico origin only, verified from live bound sources, with a fail-closed
  response to extra origins or a live reverse-hands change;
- release on seated/view-only, stopped session, tracking loss, GUI/Wrist/Grip,
  bow, climbing, ImmersiveMC, world/player/game-mode replacement, and teardown;
- actual mixin/hook ordering verification on the packaged Quest runtime;
- packet-level proof that RT, Y, and physical swings cannot duplicate
  `startAttack`, `startDestroyBlock`, or `continueDestroyBlock`;
- a held-RT GUI round trip proving that no attack occurs until release and a new
  press.

Until those runtime tests exist, RC8 plus its classifier is the production-safe
choice, and mux `6c30c1c8` is the only bounded fallback candidate when the
classifier specifically proves a missing dedicated raw action.

## Host evidence

- Base inspected: `ea2177498bea46fd949e70ae5382ef2387c86531`.
- Mux compared: `6c30c1c80bee8b15280b472ab263409314978615`.
- Original native Quest binding inspected in
  `Vivecraft-26.2-Quest/common/src/main/java/org/vivecraft/client_vr/provider/openxr/XRBindings.java`.
- Provider re-press behavior inspected in
  `Vivecraft-26.2-Quest/common/src/main/java/org/vivecraft/client_vr/provider/openxr/MCOpenXR.java`.
- The discarded prototype completed Java 25 offline `check`: 83 actionable
  tasks, BUILD SUCCESSFUL. This establishes compilation and deterministic
  model checks only; it is explicitly not Quest/runtime evidence.
- Final retained tree has no runtime/source/test modification relative to RC8.
- No APK, ADB, device, profile, Stable, or root operation was performed.
