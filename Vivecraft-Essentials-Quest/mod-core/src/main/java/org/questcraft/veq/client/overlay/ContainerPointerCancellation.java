package org.questcraft.veq.client.overlay;

import net.minecraft.client.input.MouseButtonEvent;

/** Mixin bridge for cancelling a native container gesture without a slot transaction. */
public interface ContainerPointerCancellation {
    void veq$cancelPointerGesture(MouseButtonEvent releaseEvent);
}
