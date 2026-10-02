package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class NativeContainerLocomotionTest {
    @Test
    void acceptsOnlyAliveWorldBackedNativeContainers() {
        Assertions.assertTrue(allow(true, true, true, true,
            false, false, true, false));

        Assertions.assertFalse(allow(false, true, true, true,
            false, false, true, false));
        Assertions.assertFalse(allow(true, false, true, true,
            false, false, true, false));
        Assertions.assertFalse(allow(true, true, false, false,
            false, false, false, false));
        Assertions.assertFalse(allow(true, true, true, false,
            false, false, true, false));
        Assertions.assertFalse(allow(true, true, true, true,
            true, false, true, true));
        Assertions.assertFalse(allow(true, true, true, true,
            false, true, true, true));
        Assertions.assertFalse(allow(true, true, true, true,
            false, false, false, false));
        Assertions.assertFalse(allow(true, true, true, true,
            false, false, true, true));
    }

    private static boolean allow(
        boolean vrRunning,
        boolean worldPresent,
        boolean playerPresent,
        boolean playerAlive,
        boolean playerInventory,
        boolean creativeInventory,
        boolean playerOwnsMenu,
        boolean inventoryMenu
    ) {
        return NativeContainerLocomotion.shouldAllow(
            vrRunning,
            worldPresent,
            playerPresent,
            playerAlive,
            playerInventory,
            creativeInventory,
            playerOwnsMenu,
            inventoryMenu
        );
    }
}
