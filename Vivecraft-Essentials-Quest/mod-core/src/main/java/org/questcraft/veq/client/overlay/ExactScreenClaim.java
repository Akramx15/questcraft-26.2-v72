package org.questcraft.veq.client.overlay;

/** Identity policy for a screen claimed from Minecraft's global GUI. */
public final class ExactScreenClaim {
    private ExactScreenClaim() {
    }

    public static <S> boolean isCurrent(S captured,
                                        S active,
                                        S featureLayer,
                                        S global,
                                        boolean claimActive) {
        return captured != null
                && claimActive
                && captured == active
                && captured == featureLayer
                && captured == global;
    }
}
