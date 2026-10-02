package org.questcraft.veq.mixin;

import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Narrows Creative's private outside-click latch to VEQ's interaction bounds. */
@Mixin(CreativeModeInventoryScreen.class)
public interface CreativeOutsideClickAccessor {
    @Accessor("hasClickedOutside")
    void veq$setHasClickedOutside(boolean outside);
}
