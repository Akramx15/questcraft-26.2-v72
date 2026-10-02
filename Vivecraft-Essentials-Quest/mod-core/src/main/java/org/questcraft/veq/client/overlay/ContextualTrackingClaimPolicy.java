package org.questcraft.veq.client.overlay;

/** Keeps one claimed carried cursor stable through temporary tracking loss. */
public final class ContextualTrackingClaimPolicy {
    private ContextualTrackingClaimPolicy() {
    }

    public static boolean retain(boolean controllersTracked,
                                 boolean otherwiseEligible,
                                 boolean carriedOwnerActive) {
        return !controllersTracked && otherwiseEligible && carriedOwnerActive;
    }
}
