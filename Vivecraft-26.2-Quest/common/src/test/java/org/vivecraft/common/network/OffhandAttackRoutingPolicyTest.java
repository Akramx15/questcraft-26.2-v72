package org.vivecraft.common.network;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class OffhandAttackRoutingPolicyTest {
    @Test
    void exactIndependentPeerSupportsRouting() {
        Assertions.assertTrue(OffhandAttackRoutingPolicy.negotiated(
            true, true, true, NetworkVersion.INDEPENDENT_HAND_COOLDOWN));
        Assertions.assertTrue(OffhandAttackRoutingPolicy.negotiated(
            true, true, true, NetworkVersion.PAIRED_STRIKE));
    }

    @Test
    void olderDualWieldPeerSupportsRoutingWithItsSharedClock() {
        Assertions.assertTrue(OffhandAttackRoutingPolicy.negotiated(
            true, true, true, NetworkVersion.DUAL_WIELDING));
        Assertions.assertTrue(OffhandAttackRoutingPolicy.negotiated(
            true, true, true, NetworkVersion.CLIMBEY_JUMP));
        Assertions.assertFalse(IndependentHandCooldownPolicy.negotiated(
            true, NetworkVersion.CLIMBEY_JUMP));
    }

    @Test
    void vanillaAndIncompleteNegotiationsFailClosed() {
        Assertions.assertFalse(OffhandAttackRoutingPolicy.negotiated(
            false, false, false, NetworkVersion.LEGACY));
        Assertions.assertFalse(OffhandAttackRoutingPolicy.negotiated(
            true, false, true, NetworkVersion.CLIMBEY_JUMP));
        Assertions.assertFalse(OffhandAttackRoutingPolicy.negotiated(
            true, true, false, NetworkVersion.CLIMBEY_JUMP));
        Assertions.assertFalse(OffhandAttackRoutingPolicy.negotiated(
            true, true, true, NetworkVersion.LEGACY));
        Assertions.assertFalse(OffhandAttackRoutingPolicy.negotiated(
            true, true, true, null));
    }
}
