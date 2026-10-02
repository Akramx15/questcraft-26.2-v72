package org.questcraft.veq.client.overlay;

/** Cancel-only hook for pointer flags owned by a VEQ screen subclass. */
public interface VeqOwnedPointerCancellation {
    void veq$cancelOwnedPointerGesture();
}
