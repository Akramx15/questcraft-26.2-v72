package org.questcraft.veq.client.overlay;

/** Idempotent cancel policy for vanilla container subclass drag latches. */
public final class ContainerSubclassLatchPolicy {
    private ContainerSubclassLatchPolicy() {
    }

    public static boolean clear(boolean ignoredCurrentValue) {
        return false;
    }
}
