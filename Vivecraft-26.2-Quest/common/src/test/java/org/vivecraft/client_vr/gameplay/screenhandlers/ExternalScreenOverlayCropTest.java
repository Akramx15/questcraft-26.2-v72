package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class ExternalScreenOverlayCropTest {
    @Test
    void resolvesDynamicContentBoundsAndNormalizedTextureCoordinates() {
        ExternalScreenOverlayHandler.ResolvedSurfaceBounds crop =
            new ExternalScreenOverlayHandler.SurfaceBounds(109, 40, 262, 190)
                .resolve(480, 270);
        Assertions.assertEquals(109, crop.x());
        Assertions.assertEquals(40, crop.y());
        Assertions.assertEquals(262, crop.width());
        Assertions.assertEquals(190, crop.height());
        Assertions.assertEquals(109.0F / 480.0F, crop.u0(480));
        Assertions.assertEquals(40.0F / 270.0F, crop.v0(270));
        Assertions.assertEquals(371.0F / 480.0F, crop.u1(480));
        Assertions.assertEquals(230.0F / 270.0F, crop.v1(270));
    }

    @Test
    void clampsOversizedBoundsAndFallsBackForEmptyIntersection() {
        ExternalScreenOverlayHandler.ResolvedSurfaceBounds clamped =
            new ExternalScreenOverlayHandler.SurfaceBounds(470, 260, 40, 30)
                .resolve(480, 270);
        Assertions.assertEquals(470, clamped.x());
        Assertions.assertEquals(260, clamped.y());
        Assertions.assertEquals(10, clamped.width());
        Assertions.assertEquals(10, clamped.height());

        ExternalScreenOverlayHandler.ResolvedSurfaceBounds fallback =
            new ExternalScreenOverlayHandler.SurfaceBounds(700, 700, 10, 10)
                .resolve(480, 270);
        Assertions.assertEquals(0, fallback.x());
        Assertions.assertEquals(0, fallback.y());
        Assertions.assertEquals(480, fallback.width());
        Assertions.assertEquals(270, fallback.height());
    }

    @Test
    void mapsAsymmetricScreenCropOntoInvertedRenderTarget() {
        ExternalScreenOverlayHandler.ResolvedSurfaceBounds crop =
            new ExternalScreenOverlayHandler.SurfaceBounds(10, 20, 100, 70)
                .resolve(504, 270);
        Assertions.assertEquals(20.0F / 270.0F, crop.v0(270));
        Assertions.assertEquals(90.0F / 270.0F, crop.v1(270));
        Assertions.assertEquals(180.0F / 270.0F, crop.quadVBottom(270), 0.000001F);
        Assertions.assertEquals(250.0F / 270.0F, crop.quadVTop(270), 0.000001F);

        ExternalScreenOverlayHandler.ResolvedSurfaceBounds full =
            ExternalScreenOverlayHandler.SurfaceBounds.full().resolve(504, 270);
        Assertions.assertEquals(0.0F, full.quadVBottom(270));
        Assertions.assertEquals(1.0F, full.quadVTop(270));
    }
}
