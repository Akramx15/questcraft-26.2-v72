package org.vivecraft.client_vr.render.helpers;

import net.minecraft.client.renderer.state.WindowRenderState;

import javax.annotation.Nullable;
import java.util.Objects;

/**
 * Render-thread scope for an external GUI surface's independent raster and
 * logical dimensions.
 *
 * <p>Each registered surface owns and reuses one instance. Entering a scope
 * only swaps primitive state and an existing reference, so recording a
 * surface does not allocate. Nested scopes are supported as long as each
 * level uses a different surface instance.</p>
 */
public final class SurfaceGuiMetrics {
    @Nullable
    private static SurfaceGuiMetrics active;

    private int physicalWidth;
    private int physicalHeight;
    private int logicalWidth;
    private int logicalHeight;
    private int rasterScale;
    private boolean mipmapsEnabled = true;

    @Nullable
    private SurfaceGuiMetrics previous;
    @Nullable
    private WindowRenderState windowState;
    @Nullable
    private GuiScaleState guiScaleState;
    private int previousWindowWidth;
    private int previousWindowHeight;
    private int previousWindowGuiScale;
    private int previousGuiHandlerScale;
    private int previousGuiHandlerMaxScale;

    /** Updates this reusable instance when its surface target is resized. */
    public void configure(int physicalWidth, int physicalHeight, int logicalWidth, int logicalHeight) {
        configure(physicalWidth, physicalHeight, logicalWidth, logicalHeight, true);
    }

    /** Updates dimensions and the exact mipmap policy of the active target. */
    public void configure(
        int physicalWidth,
        int physicalHeight,
        int logicalWidth,
        int logicalHeight,
        boolean mipmapsEnabled)
    {
        if (this.windowState != null) {
            throw new IllegalStateException("Cannot resize active surface GUI metrics");
        }
        if (physicalWidth <= 0 || physicalHeight <= 0 || logicalWidth <= 0 || logicalHeight <= 0) {
            throw new IllegalArgumentException("Surface GUI dimensions must be positive");
        }

        int rasterScale = ceilDiv(physicalWidth, logicalWidth);
        if (ceilDiv(physicalWidth, rasterScale) != logicalWidth ||
            ceilDiv(physicalHeight, rasterScale) != logicalHeight)
        {
            throw new IllegalArgumentException(
                "Surface physical and logical dimensions must share one integer raster scale");
        }

        this.physicalWidth = physicalWidth;
        this.physicalHeight = physicalHeight;
        this.logicalWidth = logicalWidth;
        this.logicalHeight = logicalHeight;
        this.rasterScale = rasterScale;
        this.mipmapsEnabled = mipmapsEnabled;
    }

    /**
     * Activates this surface and gives vanilla GUI projection/scissor code its
     * physical target size and raster scale.
     */
    public void enter(WindowRenderState windowState, GuiScaleState guiScaleState) {
        Objects.requireNonNull(windowState, "Window render state cannot be null");
        Objects.requireNonNull(guiScaleState, "GUI scale state cannot be null");
        if (this.rasterScale <= 0) {
            throw new IllegalStateException("Surface GUI metrics have not been configured");
        }
        if (this.windowState != null) {
            throw new IllegalStateException("Surface GUI metrics are already active");
        }

        this.previous = active;
        this.windowState = windowState;
        this.guiScaleState = guiScaleState;
        this.previousWindowWidth = windowState.width;
        this.previousWindowHeight = windowState.height;
        this.previousWindowGuiScale = windowState.guiScale;
        this.previousGuiHandlerScale = guiScaleState.guiScale();
        this.previousGuiHandlerMaxScale = guiScaleState.maxGuiScale();
        windowState.width = this.physicalWidth;
        windowState.height = this.physicalHeight;
        windowState.guiScale = this.rasterScale;
        // A few Vivecraft/add-on extraction paths still read these values
        // directly instead of going through Window. Keep both branches on the
        // active surface scale, then restore them with the window state.
        guiScaleState.setGuiScale(this.rasterScale);
        guiScaleState.setMaxGuiScale(this.rasterScale);
        active = this;
    }

    /** Restores the previous surface and the exact prior vanilla window state. */
    public void exit() {
        WindowRenderState scopedWindowState = this.windowState;
        GuiScaleState scopedGuiScaleState = this.guiScaleState;
        if (scopedWindowState == null || scopedGuiScaleState == null || active != this) {
            throw new IllegalStateException("Surface GUI metrics are not the active scope");
        }

        scopedWindowState.width = this.previousWindowWidth;
        scopedWindowState.height = this.previousWindowHeight;
        scopedWindowState.guiScale = this.previousWindowGuiScale;
        scopedGuiScaleState.setGuiScale(this.previousGuiHandlerScale);
        scopedGuiScaleState.setMaxGuiScale(this.previousGuiHandlerMaxScale);
        active = this.previous;
        this.previous = null;
        this.windowState = null;
        this.guiScaleState = null;
    }

    @Nullable
    public static SurfaceGuiMetrics active() {
        return active;
    }

    public int physicalWidth() {
        return this.physicalWidth;
    }

    public int physicalHeight() {
        return this.physicalHeight;
    }

    public int logicalWidth() {
        return this.logicalWidth;
    }

    public int logicalHeight() {
        return this.logicalHeight;
    }

    public int rasterScale() {
        return this.rasterScale;
    }

    /** Whether the currently scoped target owns a mip chain that needs updating. */
    public boolean mipmapsEnabled() {
        return this.mipmapsEnabled;
    }

    private static int ceilDiv(int value, int divisor) {
        return 1 + (value - 1) / divisor;
    }

    /** Mutable scale seam shared with direct Vivecraft/add-on readers. */
    public interface GuiScaleState {
        int guiScale();

        int maxGuiScale();

        void setGuiScale(int guiScale);

        void setMaxGuiScale(int guiScale);
    }
}
