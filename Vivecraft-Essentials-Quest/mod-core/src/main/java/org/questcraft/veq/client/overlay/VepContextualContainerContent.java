package org.questcraft.veq.client.overlay;

import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.world.inventory.AbstractContainerMenu;
import org.questcraft.veq.client.gui.VepWristInventoryScreen;

import java.util.Objects;

/**
 * UI-only wrapper for a native or modded container screen. Pose selection and
 * source block/entity tracking belong to the Vivecraft surface adapter.
 */
public final class VepContextualContainerContent implements VepScreenContent {
    public static final String SURFACE_ID = "vep_contextual_container";

    private final AbstractContainerScreen<?> screen;
    private final VepWristInventoryScreen.Bounds bounds;
    private final Runnable closeAction;

    public VepContextualContainerContent(AbstractContainerScreen<?> screen,
                                         VepWristInventoryScreen.Bounds bounds,
                                         Runnable closeAction) {
        this.screen = Objects.requireNonNull(screen, "screen");
        this.bounds = Objects.requireNonNull(bounds, "bounds");
        this.closeAction = closeAction == null ? () -> { } : closeAction;
    }

    @Override
    public AbstractContainerScreen<?> screen() {
        return screen;
    }

    @Override
    public VepWristInventoryScreen.Bounds contentBounds() {
        return bounds;
    }

    @Override
    public boolean containsInteractionPoint(double x, double y) {
        return x >= bounds.x() && x < bounds.x() + bounds.width()
                && y >= bounds.y() && y < bounds.y() + bounds.height();
    }

    @Override
    public AbstractContainerMenu menu() {
        return screen.getMenu();
    }

    @Override
    public void hardClose() {
        closeAction.run();
    }
}
