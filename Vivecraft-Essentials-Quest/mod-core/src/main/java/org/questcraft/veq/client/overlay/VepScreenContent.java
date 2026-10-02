package org.questcraft.veq.client.overlay;

import net.minecraft.client.gui.screens.Screen;
import net.minecraft.world.inventory.AbstractContainerMenu;
import org.jetbrains.annotations.Nullable;
import org.questcraft.veq.client.gui.VepWristInventoryScreen;

/** UI feature contract consumed by the Vivecraft multi-surface adapter. */
public interface VepScreenContent {
    Screen screen();

    VepWristInventoryScreen.Bounds contentBounds();

    /**
     * Visual crop bounds for the submitted overlay surface. Interaction stays
     * tied to {@link #contentBounds()} and {@link #containsInteractionPoint}
     * so decorative padding can never capture world input.
     */
    default VepWristInventoryScreen.Bounds visualBounds() {
        return contentBounds();
    }

    /**
     * Monotonic generation for geometry that contributes to
     * {@link #visualBounds()}. Static content may keep the default value; the
     * overlay also keys its cache by content/screen identity and dimensions.
     */
    default long visualLayoutRevision() {
        return 0L;
    }

    boolean containsInteractionPoint(double x, double y);

    default int hoverKey(double x, double y) {
        // Custom VEP inventory content overrides this with semantic slot and
        // action ids. Native Creative and contextual/modded screens do not
        // expose a safe semantic target here. Keep their key stable so normal
        // pointer jitter cannot force a full 1008x540 base redraw each frame;
        // the retained-content safety refresh still updates them every 50 ms.
        return -1;
    }

    default @Nullable AbstractContainerMenu menu() {
        return null;
    }

    default boolean canSoftHide() {
        AbstractContainerMenu menu = menu();
        return menu == null || menu.getCarried().isEmpty();
    }

    /** Mirrors VEP's per-client-tick embedded Screen lifecycle. */
    default void tick() {
        screen().tick();
    }

    default void hardClose() {
    }
}
