package org.vivecraft.client_vr.render.helpers;

/**
 * Keeps independently rendered add-on surfaces readable without changing the
 * depth or hand-order semantics of Minecraft's ordinary HUD and screens.
 */
public final class ExternalOverlayRenderPolicy {
    public enum WorldOcclusion {
        INHERIT_GUI,
        ALWAYS_VISIBLE
    }

    /**
     * Selects which external surfaces may be submitted by a render pass.
     * Fast/fancy rendering uses {@link #ALL}; Fabulous rendering splits the
     * surfaces between its depth-composited and always-on-top targets.
     */
    public enum CompositionPass {
        ALL,
        FABULOUS_OCCLUDED,
        FABULOUS_UNOCCLUDED
    }

    private ExternalOverlayRenderPolicy() {}

    /** Resolves an individual surface without changing ordinary UI depth. */
    public static boolean depthAlways(WorldOcclusion policy, boolean ordinaryDepthAlways) {
        return policy == WorldOcclusion.ALWAYS_VISIBLE || ordinaryDepthAlways;
    }

    /**
     * Routes an external surface to exactly one Fabulous composition target.
     * Merely disabling depth testing is insufficient in Fabulous mode because
     * the final transparency shader still depth-composites VrOccluded against
     * the world. ALWAYS_VISIBLE must therefore be submitted to VrUnoccluded.
     */
    public static boolean shouldRenderInPass(
        WorldOcclusion policy, CompositionPass pass, boolean ordinaryGuiOccluded)
    {
        return switch (pass) {
            case ALL -> true;
            case FABULOUS_OCCLUDED ->
                ordinaryGuiOccluded && policy == WorldOcclusion.INHERIT_GUI;
            case FABULOUS_UNOCCLUDED ->
                policy == WorldOcclusion.ALWAYS_VISIBLE || !ordinaryGuiOccluded;
        };
    }

}
