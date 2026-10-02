package org.vivecraft.client_vr.gameplay.screenhandlers;

import java.util.IdentityHashMap;
import java.util.Map;

/**
 * Requires an active, released sample before an input can fire after a native
 * container closes. Identity keys are intentional: two input actions can
 * share a key mapping but still have independent OpenXR state.
 */
public final class NativeContainerFreshPressLatch<T> {
    private final Map<T, Integer> waitingForRelease = new IdentityHashMap<>();
    private final Map<T, Integer> neutralOnce = new IdentityHashMap<>();

    public void arm(T action, int slots) {
        if (action == null || slots == 0) {
            throw new IllegalArgumentException("action and at least one slot are required");
        }
        this.waitingForRelease.put(action, slots);
        this.neutralOnce.remove(action);
    }

    /**
     * @return true while this action slot must remain suppressed
     */
    public boolean suppressUntilReleased(T action, int slot, boolean active, boolean pressed) {
        Integer waiting = this.waitingForRelease.get(action);
        if (waiting == null || (waiting & slot) == 0) {
            return false;
        }

        // An inactive action set is not proof of a physical release. Wait for
        // one active neutral sample so a held trigger cannot reappear later.
        if (!active || pressed) {
            this.clearNeutralSample(action, slot);
            return true;
        }

        int sampledNeutral = this.neutralOnce.getOrDefault(action, 0);
        if ((sampledNeutral & slot) == 0) {
            // Action-set replacement can briefly report active + neutral even
            // while a trigger remains physically held. Require a second
            // consecutive neutral sample before accepting the release.
            this.neutralOnce.put(action, sampledNeutral | slot);
            return true;
        }

        int remaining = waiting & ~slot;
        this.clearNeutralSample(action, slot);
        if (remaining == 0) {
            this.waitingForRelease.remove(action);
        } else {
            this.waitingForRelease.put(action, remaining);
        }
        return false;
    }

    public boolean isWaiting(T action, int slot) {
        Integer waiting = this.waitingForRelease.get(action);
        return waiting != null && (waiting & slot) != 0;
    }

    public void clear() {
        this.waitingForRelease.clear();
        this.neutralOnce.clear();
    }

    private void clearNeutralSample(T action, int slot) {
        int sampledNeutral = this.neutralOnce.getOrDefault(action, 0) & ~slot;
        if (sampledNeutral == 0) {
            this.neutralOnce.remove(action);
        } else {
            this.neutralOnce.put(action, sampledNeutral);
        }
    }
}
