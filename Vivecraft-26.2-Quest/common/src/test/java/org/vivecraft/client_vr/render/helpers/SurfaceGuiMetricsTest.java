package org.vivecraft.client_vr.render.helpers;

import net.minecraft.client.renderer.state.WindowRenderState;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class SurfaceGuiMetricsTest {
    @Test
    void wristUsesItsPhysicalLogicalAndRasterDimensions() {
        SurfaceGuiMetrics wrist = metrics(1008, 540, 504, 270);
        WindowRenderState window = window(1280, 720, 3);
        TestGuiScaleState guiScale = new TestGuiScaleState(3, 3);

        wrist.enter(window, guiScale);
        try {
            Assertions.assertSame(wrist, SurfaceGuiMetrics.active());
            Assertions.assertEquals(1008, wrist.physicalWidth());
            Assertions.assertEquals(540, wrist.physicalHeight());
            Assertions.assertEquals(504, wrist.logicalWidth());
            Assertions.assertEquals(270, wrist.logicalHeight());
            Assertions.assertEquals(2, wrist.rasterScale());
            assertProjectionAndScissorMatch(wrist, window);
        } finally {
            wrist.exit();
        }

        assertWindow(window, 1280, 720, 3);
        Assertions.assertNull(SurfaceGuiMetrics.active());
    }

    @Test
    void gripUsesItsPhysicalLogicalAndRasterDimensions() {
        SurfaceGuiMetrics grip = metrics(392, 392, 98, 98);
        WindowRenderState window = window(1280, 720, 3);
        TestGuiScaleState guiScale = new TestGuiScaleState(3, 3);

        grip.enter(window, guiScale);
        try {
            Assertions.assertEquals(4, grip.rasterScale());
            assertProjectionAndScissorMatch(grip, window);
        } finally {
            grip.exit();
        }

        assertWindow(window, 1280, 720, 3);
        Assertions.assertNull(SurfaceGuiMetrics.active());
    }

    @Test
    void ordinaryGuiKeepsItsCeilScaledDimensionsAndRestoresExactly() {
        SurfaceGuiMetrics ordinary = metrics(1280, 720, 427, 240);
        WindowRenderState window = window(2560, 1440, 6);
        TestGuiScaleState guiScale = new TestGuiScaleState(6, 6);

        Assertions.assertNull(SurfaceGuiMetrics.active());
        assertWindow(window, 2560, 1440, 6);
        Assertions.assertEquals(3, ordinary.rasterScale(),
            "1280 / 427 must use Minecraft's ceil-scaled raster factor");

        ordinary.enter(window, guiScale);
        ordinary.exit();

        assertWindow(window, 2560, 1440, 6);
        Assertions.assertNull(SurfaceGuiMetrics.active());
    }

    @Test
    void nestedScopeRestoresOuterAndExceptionRestoresOrdinaryWindow() {
        SurfaceGuiMetrics wrist = metrics(1008, 540, 504, 270);
        SurfaceGuiMetrics grip = metrics(392, 392, 98, 98);
        WindowRenderState window = window(1280, 720, 3);
        TestGuiScaleState guiScale = new TestGuiScaleState(3, 3);

        RuntimeException failure = Assertions.assertThrows(RuntimeException.class, () -> {
            wrist.enter(window, guiScale);
            try {
                assertWindow(window, 1008, 540, 2);
                assertGuiScales(guiScale, 2);
                grip.enter(window, guiScale);
                try {
                    assertWindow(window, 392, 392, 4);
                    assertGuiScales(guiScale, 4);
                    throw new RuntimeException("render failure");
                } finally {
                    grip.exit();
                    Assertions.assertSame(wrist, SurfaceGuiMetrics.active());
                    assertWindow(window, 1008, 540, 2);
                    assertGuiScales(guiScale, 2);
                }
            } finally {
                wrist.exit();
            }
        });

        Assertions.assertEquals("render failure", failure.getMessage());
        assertWindow(window, 1280, 720, 3);
        assertGuiScales(guiScale, 3);
        Assertions.assertNull(SurfaceGuiMetrics.active());
    }

    @Test
    void rejectsDimensionsThatCannotShareOneIntegerRasterScale() {
        SurfaceGuiMetrics metrics = new SurfaceGuiMetrics();
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> metrics.configure(1008, 540, 504, 180));
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> metrics.configure(0, 540, 504, 270));
    }

    @Test
    void carriesTheSurfaceMipmapPolicyWithoutChangingLegacyDefault() {
        SurfaceGuiMetrics ordinary = metrics(1280, 720, 427, 240);
        Assertions.assertTrue(ordinary.mipmapsEnabled());

        SurfaceGuiMetrics wrist = new SurfaceGuiMetrics();
        wrist.configure(1008, 540, 504, 270, false);
        Assertions.assertFalse(wrist.mipmapsEnabled());
    }

    private static SurfaceGuiMetrics metrics(
        int physicalWidth, int physicalHeight, int logicalWidth, int logicalHeight)
    {
        SurfaceGuiMetrics metrics = new SurfaceGuiMetrics();
        metrics.configure(physicalWidth, physicalHeight, logicalWidth, logicalHeight);
        return metrics;
    }

    private static WindowRenderState window(int width, int height, int guiScale) {
        WindowRenderState window = new WindowRenderState();
        window.width = width;
        window.height = height;
        window.guiScale = guiScale;
        return window;
    }

    private static void assertProjectionAndScissorMatch(
        SurfaceGuiMetrics metrics, WindowRenderState window)
    {
        assertWindow(window, metrics.physicalWidth(), metrics.physicalHeight(), metrics.rasterScale());
        Assertions.assertEquals(metrics.logicalWidth(), ceilDiv(window.width, window.guiScale));
        Assertions.assertEquals(metrics.logicalHeight(), ceilDiv(window.height, window.guiScale));
        Assertions.assertEquals(metrics.physicalWidth(), metrics.logicalWidth() * metrics.rasterScale());
        Assertions.assertEquals(metrics.physicalHeight(), metrics.logicalHeight() * metrics.rasterScale());
    }

    private static void assertWindow(WindowRenderState window, int width, int height, int guiScale) {
        Assertions.assertEquals(width, window.width);
        Assertions.assertEquals(height, window.height);
        Assertions.assertEquals(guiScale, window.guiScale);
    }

    private static void assertGuiScales(TestGuiScaleState state, int guiScale) {
        Assertions.assertEquals(guiScale, state.guiScale());
        Assertions.assertEquals(guiScale, state.maxGuiScale());
    }

    private static int ceilDiv(int value, int divisor) {
        return 1 + (value - 1) / divisor;
    }

    private static final class TestGuiScaleState implements SurfaceGuiMetrics.GuiScaleState {
        private int guiScale;
        private int maxGuiScale;

        private TestGuiScaleState(int guiScale, int maxGuiScale) {
            this.guiScale = guiScale;
            this.maxGuiScale = maxGuiScale;
        }

        @Override
        public int guiScale() {
            return this.guiScale;
        }

        @Override
        public int maxGuiScale() {
            return this.maxGuiScale;
        }

        @Override
        public void setGuiScale(int guiScale) {
            this.guiScale = guiScale;
        }

        @Override
        public void setMaxGuiScale(int guiScale) {
            this.maxGuiScale = guiScale;
        }
    }
}
