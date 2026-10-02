package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.render.helpers.ExternalOverlayRenderPolicy;

/** Rendering policy kept independent from the Minecraft screen lifecycle. */
final class GripOverlayRenderPolicy {
    private GripOverlayRenderPolicy() {
    }

    static ExternalOverlayRenderPolicy.WorldOcclusion worldOcclusion() {
        return ExternalOverlayRenderPolicy.WorldOcclusion.ALWAYS_VISIBLE;
    }
}
