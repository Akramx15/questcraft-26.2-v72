package org.vivecraft.common.network;

/**
 * Shared client policy for attributing handless Vanilla attack/mining packets
 * to the negotiated offhand through Vivecraft's active-body-part protocol.
 */
public final class OffhandAttackRoutingPolicy {
    private OffhandAttackRoutingPolicy() {
    }

    public static boolean negotiated(
        boolean serverHasVivecraft,
        boolean serverWantsData,
        boolean dualWieldingEnabled,
        NetworkVersion negotiatedVersion)
    {
        return serverHasVivecraft && serverWantsData && dualWieldingEnabled &&
            negotiatedVersion != null &&
            NetworkVersion.DUAL_WIELDING.accepts(negotiatedVersion);
    }
}
