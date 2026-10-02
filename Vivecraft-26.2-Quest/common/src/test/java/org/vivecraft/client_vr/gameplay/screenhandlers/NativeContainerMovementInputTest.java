package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class NativeContainerMovementInputTest {
    @Test
    void digitalContainerMovementUsesDirectVector() {
        Assertions.assertTrue(NativeContainerMovementInput.shouldDriveMoveVector(
            true, false, true, false));
    }

    @Test
    void preservesNormalAnalogPolicyAndCompatibilityBlock() {
        Assertions.assertTrue(NativeContainerMovementInput.shouldDriveMoveVector(
            true, true, false, false));
        Assertions.assertFalse(NativeContainerMovementInput.shouldDriveMoveVector(
            true, false, false, false));
        Assertions.assertFalse(NativeContainerMovementInput.shouldDriveMoveVector(
            true, false, true, true));
        Assertions.assertFalse(NativeContainerMovementInput.shouldDriveMoveVector(
            false, true, true, false));
    }
}
