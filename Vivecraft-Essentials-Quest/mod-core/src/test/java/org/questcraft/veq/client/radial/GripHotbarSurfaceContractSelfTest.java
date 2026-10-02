package org.questcraft.veq.client.radial;

import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.render.helpers.ExternalOverlayRenderPolicy;

public final class GripHotbarSurfaceContractSelfTest {
    private GripHotbarSurfaceContractSelfTest() {
    }

    public static void main(String[] args) {
        require(GripHotbarOverlay.LOGICAL_SIZE == 98, "Grip surface is logically 98x98");
        require(GripHotbarOverlay.RENDER_SIZE == 392,
                "surface matches Visor's integer 4x raster density");
        require(HotbarGridLayout.panelLeft(98) == 0 && HotbarGridLayout.panelTop(98) == 0,
                "the hotbar fills its surface instead of a global GUI framebuffer");
        require(Math.abs(
                        org.questcraft.veq.client.config.GripHotbarConfig.DEFAULT_SCALE *
                                org.questcraft.veq.client.config.GripHotbarConfig.QUAD_BASE_WIDTH -
                                org.questcraft.veq.client.config.GripHotbarConfig.DEFAULT_PHYSICAL_WIDTH
                ) < 1.0E-6F,
                "default rendered physical width is approximately 0.40m");
        require(Math.abs(org.questcraft.veq.client.config.GripHotbarConfig.DEFAULT_DISTANCE - 0.30F) < 1.0E-6F,
                "default distance is 0.30m");
        require(WristOverlayHandler.SURFACE_PRIORITY > GripHotbarOverlay.SURFACE_PRIORITY,
                "Wrist focus can take a hand away from Grip");
        require(GripOverlayRenderPolicy.worldOcclusion() ==
                        ExternalOverlayRenderPolicy.WorldOcclusion.ALWAYS_VISIBLE,
                "Grip remains visible against nearby cave blocks");
        require(HotbarRadialScreen.showsOffhandMarker(ControllerType.LEFT),
                "LEFT renders the confirmed offhand marker");
        require(!HotbarRadialScreen.showsOffhandMarker(ControllerType.RIGHT),
                "RIGHT never renders the offhand marker");

        Matrix4f rotation = new Matrix4f();
        Vector3f scratch = new Vector3f();
        require(GripSurfacePoseMath.orientTowardViewer(
                        new Vector3f(0.0F, 0.0F, -1.0F),
                        new Vector3f(),
                        scratch,
                        rotation),
                "a separated panel can face the viewer");
        Vector3f normal = rotation.transformDirection(new Vector3f(0.0F, 0.0F, 1.0F));
        require(normal.distance(new Vector3f(0.0F, 0.0F, 1.0F)) < 1.0E-5F,
                "the visible +Z face points from the panel to the viewer");
        require(!GripSurfacePoseMath.orientTowardViewer(
                        new Vector3f(),
                        new Vector3f(),
                        scratch,
                        rotation),
                "a degenerate viewer distance falls back safely");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
