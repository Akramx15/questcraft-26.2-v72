package org.questcraft.veq.mixin;

import net.minecraft.client.gui.screens.inventory.MerchantScreen;
import org.questcraft.veq.client.overlay.ContainerSubclassLatchPolicy;
import org.questcraft.veq.client.overlay.VeqOwnedPointerCancellation;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;

/** Clears Merchant's private scrollbar drag latch through the cancel-only hook. */
@Mixin(MerchantScreen.class)
public abstract class MerchantDragCancelMixin implements VeqOwnedPointerCancellation {
    @Shadow private boolean isDragging;

    @Override
    public void veq$cancelOwnedPointerGesture() {
        this.isDragging = ContainerSubclassLatchPolicy.clear(this.isDragging);
    }
}
