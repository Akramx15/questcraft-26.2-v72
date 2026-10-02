package org.questcraft.veq.client.gui;

import net.minecraft.world.inventory.Slot;
import org.jetbrains.annotations.Nullable;

/**
 * Opt-in slot-coordinate bridge for a container screen rendered outside
 * Minecraft's current-screen slot. Normal container screens are untouched.
 */
public interface EmbeddedSlotLayout {
    /** Coordinates relative to AbstractContainerScreen's left/top pose. */
    @Nullable SlotPosition veq$slotPosition(Slot slot);

    boolean veq$isOverSlot(Slot slot, double mouseX, double mouseY);

    record SlotPosition(int x, int y) {
    }
}
