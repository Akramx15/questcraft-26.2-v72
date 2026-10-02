package org.vivecraft.common.network;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.api.data.VRBodyPart;

class IndependentHandCooldownPolicyTest {
    @Test
    void capabilityIsAppendOnlyAndRoundTripsProtocolNumber() {
        Assertions.assertEquals(
            NetworkVersion.CLIMBEY_JUMP.ordinal() + 1,
            NetworkVersion.INDEPENDENT_HAND_COOLDOWN.ordinal());
        Assertions.assertEquals(
            NetworkVersion.INDEPENDENT_HAND_COOLDOWN,
            NetworkVersion.fromProtocolVersion(
                NetworkVersion.INDEPENDENT_HAND_COOLDOWN.protocolVersion()));
        Assertions.assertEquals(
            NetworkVersion.INDEPENDENT_HAND_COOLDOWN.ordinal() + 1,
            NetworkVersion.PAIRED_STRIKE.ordinal());
        Assertions.assertEquals(
            NetworkVersion.PAIRED_STRIKE,
            NetworkVersion.fromProtocolVersion(NetworkVersion.PAIRED_STRIKE.protocolVersion()));
    }

    @Test
    void oldAndVanillaPeersKeepTheSharedClock() {
        Assertions.assertFalse(IndependentHandCooldownPolicy.negotiated(
            true, NetworkVersion.CLIMBEY_JUMP));
        Assertions.assertFalse(IndependentHandCooldownPolicy.negotiated(
            false, NetworkVersion.INDEPENDENT_HAND_COOLDOWN));
        Assertions.assertFalse(IndependentHandCooldownPolicy.usesOffhandClock(
            true, NetworkVersion.CLIMBEY_JUMP, VRBodyPart.OFF_HAND));
    }

    @Test
    void onlyNegotiatedOffhandSelectsTheSecondClock() {
        Assertions.assertTrue(IndependentHandCooldownPolicy.usesOffhandClock(
            true, NetworkVersion.INDEPENDENT_HAND_COOLDOWN, VRBodyPart.OFF_HAND));
        Assertions.assertFalse(IndependentHandCooldownPolicy.usesOffhandClock(
            true, NetworkVersion.INDEPENDENT_HAND_COOLDOWN, VRBodyPart.MAIN_HAND));
        Assertions.assertFalse(IndependentHandCooldownPolicy.usesOffhandClock(
            true, NetworkVersion.INDEPENDENT_HAND_COOLDOWN, VRBodyPart.HEAD));
    }
}
