package org.questcraft.veq.client.wrist;

import org.questcraft.veq.client.overlay.CarriedPointerOwnership;
import org.vivecraft.client_vr.provider.ControllerType;

public final class WristInputOwnershipSelfTest {
    private WristInputOwnershipSelfTest() {
    }

    public static void main(String[] args) {
        require(owns(true, ControllerType.LEFT, false),
                "calibration owns anchor hand");
        require(owns(true, ControllerType.RIGHT, false),
                "calibration owns editing hand");
        require(!owns(false, ControllerType.LEFT, false),
                "carried stack alone must leave the non-pointer hand free");
        require(owns(false, ControllerType.RIGHT, true),
                "focused/drag owner pointer is captured");
        require(!owns(false, ControllerType.LEFT, false),
                "right pointer ownership must leave left Attack/Use free");
        require(owns(false, ControllerType.LEFT, true),
                "reverse-hands left pointer is captured");
        require(!owns(false, ControllerType.RIGHT, false),
                "reverse-hands non-pointer remains free");
        require(!WristInputOwnership.ownsController(
                        false, true, true,
                        ControllerType.RIGHT, true),
                "hidden overlay owns no input");
        require(!WristInputOwnership.ownsController(
                        true, false, true,
                        ControllerType.RIGHT, true),
                "missing view owns no input");
        carriedOwnerTruthTable();
        System.out.println("WristInputOwnershipSelfTest PASS");
    }

    private static void carriedOwnerTruthTable() {
        Object screen = new Object();
        Object menu = new Object();
        CarriedPointerOwnership<Object, Object, ControllerType> owner =
                new CarriedPointerOwnership<>();
        owner.retainOrCapture(screen, menu, ControllerType.LEFT, true);
        require(WristInputOwnership.ownsController(
                        true, true, false, ControllerType.LEFT,
                        owner.owns(screen, menu, ControllerType.LEFT)),
                "carried owner must remain OVERLAY-owned after leaving the panel");
        require(!WristInputOwnership.ownsController(
                        true, true, false, ControllerType.RIGHT,
                        owner.owns(screen, menu, ControllerType.RIGHT)),
                "non-owner hand must remain WORLD-owned while an item is carried");
        owner.refresh(screen, menu, true);
        require(owner.controller() == ControllerType.LEFT,
                "tracking loss must retain the original physical controller");
        owner.retainOrCapture(screen, menu, ControllerType.RIGHT, true);
        require(owner.controller() == ControllerType.LEFT,
                "tracking recovery on the other hand must not transfer ownership");
        owner.refresh(screen, new Object(), true);
        require(!owner.isActive(), "exact menu identity change must clear carried ownership");
    }

    private static boolean owns(
            boolean calibrating,
            ControllerType controller,
            boolean focused
    ) {
        return WristInputOwnership.ownsController(
                true, true, calibrating,
                controller, focused
        );
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
