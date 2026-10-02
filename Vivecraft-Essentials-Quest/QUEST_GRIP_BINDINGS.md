# Quest Grip radial binding

## Audit result

The Quest/OpenXR defaults did **not** bind Vivecraft's radial action to Grip.
In the pinned Vivecraft 26.2 source, `common/src/main/java/org/vivecraft/client_vr/provider/openxr/XRBindings.java`,
`quest2Bindings()` assigned:

- left/right squeeze to `hotbarPrev` / `hotbarNext` in the ingame action set;
- right B to `radialMenu`;
- left/right squeeze to `vrInteract` in the contextual action set.

Therefore replacing `RadialHandler.UI` alone would still leave the add-on radial
on B and would not give it Visor-style Grip behavior.

## Minimal runtime rewrite

`XRBindingsMixin` changes only the returned Quest Touch suggested-binding set:

- removes squeeze from `hotbarPrev` and `hotbarNext`;
- removes the old B binding from `radialMenu`;
- binds `radialMenu` to both left and right squeeze values;
- leaves every contextual binding, including ImmersiveMC's `vrInteract`, intact.

The existing `RadialHandlerMixin` still cancels radial opening when an
ImmersiveMC `InteractModule` is active, so the priority remains wrist UI,
ImmersiveMC, then radial hotbar.
