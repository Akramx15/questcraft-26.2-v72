package org.questcraft.veq.mixin;

import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import org.questcraft.veq.client.overlay.ContainerSubclassLatchPolicy;
import org.questcraft.veq.client.overlay.VeqOwnedPointerCancellation;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;

/** Clears Creative's private scrollbar latch without dispatching mouseReleased virtually. */
@Mixin(CreativeModeInventoryScreen.class)
public abstract class CreativeScrollCancelMixin implements VeqOwnedPointerCancellation {
    @Shadow private boolean scrolling;

    @Override
    public void veq$cancelOwnedPointerGesture() {
        this.scrolling = ContainerSubclassLatchPolicy.clear(this.scrolling);
    }
}
