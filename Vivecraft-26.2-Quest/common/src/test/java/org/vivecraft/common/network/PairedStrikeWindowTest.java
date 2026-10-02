package org.vivecraft.common.network;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.api.data.VRBodyPart;

import java.util.UUID;

class PairedStrikeWindowTest {
    private static final UUID TARGET = UUID.fromString("01234567-89ab-cdef-0123-456789abcdef");
    private static final UUID OTHER_TARGET = UUID.fromString("fedcba98-7654-3210-fedc-ba9876543210");

    @Test
    void acceptsOnlyChargedOppositeHandHitOnSameTargetInsideWindow() {
        PairedStrikeWindow window = new PairedStrikeWindow();
        Assertions.assertTrue(window.record(TARGET, VRBodyPart.MAIN_HAND, 100L, 0.9F, 0.9F));

        Assertions.assertFalse(canPair(window, TARGET, VRBodyPart.MAIN_HAND, 101L, 1.0F));
        Assertions.assertFalse(canPair(window, OTHER_TARGET, VRBodyPart.OFF_HAND, 101L, 1.0F));
        Assertions.assertFalse(canPair(window, TARGET, VRBodyPart.OFF_HAND, 101L, 0.899F));
        Assertions.assertFalse(canPair(window, TARGET, VRBodyPart.OFF_HAND, 101L, Float.NaN));
        Assertions.assertTrue(canPair(window, TARGET, VRBodyPart.OFF_HAND, 104L, 0.9F));
        Assertions.assertFalse(canPair(window, TARGET, VRBodyPart.OFF_HAND, 105L, 1.0F));
    }

    @Test
    void capabilityTargetAndItemGatesFailClosed() {
        PairedStrikeWindow window = new PairedStrikeWindow();
        Assertions.assertTrue(window.record(TARGET, VRBodyPart.OFF_HAND, 10L, 1.0F, 0.9F));

        Assertions.assertFalse(window.canPair(
            TARGET, VRBodyPart.MAIN_HAND, 11L, 4, 1.0F, 0.9F,
            false, true, true));
        Assertions.assertFalse(window.canPair(
            TARGET, VRBodyPart.MAIN_HAND, 11L, 4, 1.0F, 0.9F,
            true, false, true));
        Assertions.assertFalse(window.canPair(
            TARGET, VRBodyPart.MAIN_HAND, 11L, 4, 1.0F, 0.9F,
            true, true, false));
        Assertions.assertFalse(window.canPair(
            TARGET, VRBodyPart.HEAD, 11L, 4, 1.0F, 0.9F,
            true, true, true));
        Assertions.assertFalse(window.canPair(
            TARGET, VRBodyPart.MAIN_HAND, 9L, 4, 1.0F, 0.9F,
            true, true, true));
    }

    @Test
    void maintenanceAndExplicitCleanupDisarmEveryInvalidState() {
        PairedStrikeWindow window = new PairedStrikeWindow();

        window.record(TARGET, VRBodyPart.MAIN_HAND, 20L, 1.0F, 0.9F);
        Assertions.assertTrue(window.maintain(24L, 4, true, true));
        Assertions.assertFalse(window.maintain(25L, 4, true, true));
        Assertions.assertFalse(window.armed());

        window.record(TARGET, VRBodyPart.MAIN_HAND, 20L, 1.0F, 0.9F);
        Assertions.assertFalse(window.maintain(21L, 4, false, true));

        window.record(TARGET, VRBodyPart.MAIN_HAND, 20L, 1.0F, 0.9F);
        Assertions.assertFalse(window.maintain(21L, 4, true, false));

        window.record(TARGET, VRBodyPart.MAIN_HAND, 20L, 1.0F, 0.9F);
        Assertions.assertFalse(window.maintain(19L, 4, true, true));

        window.record(TARGET, VRBodyPart.MAIN_HAND, 20L, 1.0F, 0.9F);
        window.clear();
        Assertions.assertFalse(window.armed());
        Assertions.assertNull(window.hand());
    }

    @Test
    void invalidFirstHitNeverArmsWindow() {
        PairedStrikeWindow window = new PairedStrikeWindow();

        window.record(null, VRBodyPart.MAIN_HAND, 1L, 1.0F, 0.9F);
        Assertions.assertFalse(window.armed());
        window.record(TARGET, VRBodyPart.HEAD, 1L, 1.0F, 0.9F);
        Assertions.assertFalse(window.armed());
    }

    @Test
    void weakFirstHitNeverArmsAndStoredChargeMustMeetCurrentPolicy() {
        PairedStrikeWindow window = new PairedStrikeWindow();

        Assertions.assertFalse(window.record(TARGET, VRBodyPart.MAIN_HAND, 1L, 0.89F, 0.9F));
        Assertions.assertFalse(window.armed());

        Assertions.assertTrue(window.record(TARGET, VRBodyPart.MAIN_HAND, 1L, 0.9F, 0.9F));
        Assertions.assertFalse(window.canPair(
            TARGET, VRBodyPart.OFF_HAND, 2L, 4, 1.0F, 0.95F,
            true, true, true));
    }

    @Test
    void consumingSuccessfulPairCannotStartAnAlternatingChain() {
        PairedStrikeWindow window = new PairedStrikeWindow();
        window.record(TARGET, VRBodyPart.MAIN_HAND, 30L, 1.0F, 0.9F);

        Assertions.assertTrue(canPair(window, TARGET, VRBodyPart.OFF_HAND, 31L, 1.0F));
        window.clear();
        Assertions.assertFalse(canPair(window, TARGET, VRBodyPart.MAIN_HAND, 32L, 1.0F));
    }

    private static boolean canPair(
        PairedStrikeWindow window, UUID target, VRBodyPart hand, long tick, float charge)
    {
        return window.canPair(
            target, hand, tick, 4, charge, 0.9F,
            true, true, true);
    }
}
