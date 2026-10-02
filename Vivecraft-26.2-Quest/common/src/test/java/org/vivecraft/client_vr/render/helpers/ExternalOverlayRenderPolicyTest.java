package org.vivecraft.client_vr.render.helpers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class ExternalOverlayRenderPolicyTest {
    @Test
    void ordinaryUiPreservesItsDepthPolicy() {
        Assertions.assertFalse(ExternalOverlayRenderPolicy.depthAlways(
            ExternalOverlayRenderPolicy.WorldOcclusion.INHERIT_GUI, false));
        Assertions.assertTrue(ExternalOverlayRenderPolicy.depthAlways(
            ExternalOverlayRenderPolicy.WorldOcclusion.INHERIT_GUI, true));
    }

    @Test
    void optedInSurfaceNeverUsesWorldDepthOcclusion() {
        Assertions.assertTrue(ExternalOverlayRenderPolicy.depthAlways(
            ExternalOverlayRenderPolicy.WorldOcclusion.ALWAYS_VISIBLE, false));
        Assertions.assertTrue(ExternalOverlayRenderPolicy.depthAlways(
            ExternalOverlayRenderPolicy.WorldOcclusion.ALWAYS_VISIBLE, true));
    }

    @Test
    void fabulousOccludedGuiSplitsInheritedAndAlwaysVisibleSurfaces() {
        Assertions.assertTrue(ExternalOverlayRenderPolicy.shouldRenderInPass(
            ExternalOverlayRenderPolicy.WorldOcclusion.INHERIT_GUI,
            ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_OCCLUDED, true));
        Assertions.assertFalse(ExternalOverlayRenderPolicy.shouldRenderInPass(
            ExternalOverlayRenderPolicy.WorldOcclusion.INHERIT_GUI,
            ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_UNOCCLUDED, true));
        Assertions.assertFalse(ExternalOverlayRenderPolicy.shouldRenderInPass(
            ExternalOverlayRenderPolicy.WorldOcclusion.ALWAYS_VISIBLE,
            ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_OCCLUDED, true));
        Assertions.assertTrue(ExternalOverlayRenderPolicy.shouldRenderInPass(
            ExternalOverlayRenderPolicy.WorldOcclusion.ALWAYS_VISIBLE,
            ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_UNOCCLUDED, true));
    }

    @Test
    void fabulousUnoccludedGuiKeepsEverySurfaceOnUnoccludedTarget() {
        for (ExternalOverlayRenderPolicy.WorldOcclusion policy :
            ExternalOverlayRenderPolicy.WorldOcclusion.values())
        {
            Assertions.assertFalse(ExternalOverlayRenderPolicy.shouldRenderInPass(policy,
                ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_OCCLUDED, false));
            Assertions.assertTrue(ExternalOverlayRenderPolicy.shouldRenderInPass(policy,
                ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_UNOCCLUDED, false));
        }
    }

    @Test
    void nonFabulousPassRendersEverySurface() {
        for (ExternalOverlayRenderPolicy.WorldOcclusion policy :
            ExternalOverlayRenderPolicy.WorldOcclusion.values())
        {
            Assertions.assertTrue(ExternalOverlayRenderPolicy.shouldRenderInPass(policy,
                ExternalOverlayRenderPolicy.CompositionPass.ALL, false));
            Assertions.assertTrue(ExternalOverlayRenderPolicy.shouldRenderInPass(policy,
                ExternalOverlayRenderPolicy.CompositionPass.ALL, true));
        }
    }
}
