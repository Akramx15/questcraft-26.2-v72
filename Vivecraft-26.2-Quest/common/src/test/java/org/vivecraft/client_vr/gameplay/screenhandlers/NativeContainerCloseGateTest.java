package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class NativeContainerCloseGateTest {
    @Test
    void heldOpeningPressCannotImmediatelyCloseContainer() {
        NativeContainerCloseGate gate = new NativeContainerCloseGate();
        Object screen = new Object();
        Object menu = new Object();

        Assertions.assertFalse(gate.update(true, screen, menu, true, true));
        Assertions.assertFalse(gate.update(true, screen, menu, true, true));
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertFalse(gate.isArmed(), "one neutral sample cannot arm close");
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertTrue(gate.isArmed(), "two active neutral samples arm close");
        Assertions.assertTrue(gate.update(true, screen, menu, true, true));
        Assertions.assertFalse(gate.update(true, screen, menu, true, true),
            "one held press produces exactly one close request");
    }

    @Test
    void inactiveSamplesAndResumeHeldDoNotCountAsRelease() {
        NativeContainerCloseGate gate = new NativeContainerCloseGate();
        Object screen = new Object();
        Object menu = new Object();

        gate.update(true, screen, menu, true, true);
        Assertions.assertFalse(gate.update(true, screen, menu, false, false));
        Assertions.assertFalse(gate.update(true, screen, menu, true, true),
            "a held B after Home/Guardian cannot close");
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertFalse(gate.update(true, screen, menu, false, false));
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertTrue(gate.update(true, screen, menu, true, true));
    }

    @Test
    void activeNeutralEntryCountsAsTheFirstOfTwoSamples() {
        NativeContainerCloseGate gate = new NativeContainerCloseGate();
        Object screen = new Object();
        Object menu = new Object();

        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertFalse(gate.isArmed());
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertTrue(gate.isArmed());
        Assertions.assertTrue(gate.update(true, screen, menu, true, true));
    }

    @Test
    void rawPressClosesWithoutASyntheticKeyMappingClick() {
        NativeContainerCloseGate gate = new NativeContainerCloseGate();
        Object inventoryScreen = new Object();
        Object inventoryMenu = new Object();

        // The gate deliberately receives only provider raw-action state. This
        // models an OpenXR GUI action-set handoff where KeyMapping#clickCount
        // was suppressed but the B action is active and has a fresh edge.
        Assertions.assertFalse(gate.update(true, inventoryScreen, inventoryMenu, true, false));
        Assertions.assertFalse(gate.update(true, inventoryScreen, inventoryMenu, true, false));
        Assertions.assertTrue(gate.update(true, inventoryScreen, inventoryMenu, true, true));
        Assertions.assertFalse(gate.update(true, inventoryScreen, inventoryMenu, true, true),
            "the same raw press may close the pinned inventory only once");
    }

    @Test
    void screenOrMenuReplacementStartsANewHandoff() {
        NativeContainerCloseGate gate = new NativeContainerCloseGate();
        Object firstScreen = new Object();
        Object firstMenu = new Object();
        Object secondScreen = new Object();
        Object secondMenu = new Object();

        arm(gate, firstScreen, firstMenu);
        Assertions.assertFalse(gate.update(true, secondScreen, secondMenu, true, true));
        Assertions.assertFalse(gate.owns(firstScreen, firstMenu));
        Assertions.assertTrue(gate.owns(secondScreen, secondMenu));
        Assertions.assertFalse(gate.update(true, secondScreen, secondMenu, true, false));
        Assertions.assertFalse(gate.update(true, secondScreen, secondMenu, true, false));
        Assertions.assertTrue(gate.update(true, secondScreen, secondMenu, true, true));
    }

    @Test
    void ineligibleScreensClearTheExactContext() {
        NativeContainerCloseGate gate = new NativeContainerCloseGate();
        Object screen = new Object();
        Object menu = new Object();

        arm(gate, screen, menu);
        Assertions.assertFalse(gate.update(false, screen, menu, true, true));
        Assertions.assertFalse(gate.owns(screen, menu));
        Assertions.assertFalse(gate.isArmed());
    }

    private static void arm(NativeContainerCloseGate gate, Object screen, Object menu) {
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertFalse(gate.update(true, screen, menu, true, false));
        Assertions.assertTrue(gate.isArmed());
    }
}
