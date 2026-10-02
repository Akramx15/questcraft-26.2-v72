package org.questcraft.veq.client.overlay;

import org.vivecraft.client_vr.provider.ControllerType;

/** Pure policy for hiding only an anchor-hand shield behind the wrist UI. */
final class WristHeldItemRenderPolicy {
    private WristHeldItemRenderPolicy() {
    }

    static boolean shouldHide(
        boolean surfaceVisible, ControllerType anchorController,
        ControllerType itemController, boolean shieldLike)
    {
        return surfaceVisible && shieldLike && anchorController != null &&
            anchorController == itemController;
    }
}
