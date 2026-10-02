package org.vivecraft.common.network;

import org.vivecraft.api.data.VRBodyPart;

/** Shared client/server negotiation policy for independent hand attack clocks. */
public final class IndependentHandCooldownPolicy {
    private IndependentHandCooldownPolicy() {
    }

    public static boolean negotiated(
        boolean dualWieldingEnabled,
        NetworkVersion negotiatedVersion)
    {
        return dualWieldingEnabled && negotiatedVersion != null &&
            NetworkVersion.INDEPENDENT_HAND_COOLDOWN.accepts(negotiatedVersion);
    }

    public static boolean usesOffhandClock(
        boolean dualWieldingEnabled,
        NetworkVersion negotiatedVersion,
        VRBodyPart activeBodyPart)
    {
        return negotiated(dualWieldingEnabled, negotiatedVersion) &&
            activeBodyPart == VRBodyPart.OFF_HAND;
    }
}
