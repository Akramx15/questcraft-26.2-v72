package org.questcraft.veq.mixin;

import net.minecraft.client.gui.screens.inventory.StonecutterScreen;
import org.questcraft.veq.client.overlay.ContainerSubclassLatchPolicy;
import org.questcraft.veq.client.overlay.VeqOwnedPointerCancellation;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;

/** Clears Stonecutter's private scrollbar latch through the cancel-only hook. */
@Mixin(StonecutterScreen.class)
public abstract class StonecutterScrollCancelMixin implements VeqOwnedPointerCancellation {
    @Shadow private boolean scrolling;

    @Override
    public void veq$cancelOwnedPointerGesture() {
        this.scrolling = ContainerSubclassLatchPolicy.clear(this.scrolling);
    }
}
