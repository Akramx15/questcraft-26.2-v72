package org.questcraft.veq.client.overlay;

import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;

/** Host-only regression for identity-safe carried-stack ownership. */
public final class CarriedPointerOwnershipSelfTest {
    private CarriedPointerOwnershipSelfTest() {
    }

    public static void main(String[] args) {
        Object screenA = new Object();
        Object screenB = new Object();
        Object menuA = new Object();
        Object menuB = new Object();
        CarriedPointerOwnership<Object, Object, String> owner =
                new CarriedPointerOwnership<>();

        require(owner.retainOrCapture(screenA, menuA, "LEFT", true),
                "physical-up carrying state must latch its controller");
        require(owner.owns(screenA, menuA, "LEFT"),
                "the pointer hand must retain the vanilla carried cursor");
        require(!owner.owns(screenA, menuA, "RIGHT"),
                "the non-pointer hand must stay free");

        owner.refresh(screenA, menuA, true);
        require(owner.owns(screenA, menuA, "LEFT"),
                "temporary ray loss must not clear or transfer carried ownership");
        owner.retainOrCapture(screenA, menuA, "RIGHT", true);
        require(owner.owns(screenA, menuA, "LEFT")
                        && !owner.owns(screenA, menuA, "RIGHT"),
                "another hand must never steal the same vanilla cursor");

        owner.refresh(screenA, menuA, false);
        require(!owner.isActive(), "an empty carried stack must clear ownership");
        owner.retainOrCapture(screenA, menuA, "RIGHT", true);
        owner.refresh(screenA, menuB, true);
        require(!owner.isActive(), "menu identity change must clear ownership");
        owner.retainOrCapture(screenA, menuA, "RIGHT", true);
        owner.refresh(screenB, menuA, true);
        require(!owner.isActive(), "screen identity change must clear ownership");
        owner.retainOrCapture(screenA, menuA, "RIGHT", true);
        owner.clear();
        require(!owner.isActive(), "hard close must clear ownership");

        acceptedPickupPinsOwnerBeforeOtherController();
        System.out.println("CarriedPointerOwnershipSelfTest PASS");
    }

    private static void acceptedPickupPinsOwnerBeforeOtherController() {
        Object screen = new Object();
        Object menu = new Object();
        Object right = new Object();
        Object left = new Object();
        CarriedPointerOwnership<Object, Object, Object> owner =
                new CarriedPointerOwnership<>();

        // RIGHT's accepted mouse-down picked up a stack. Ownership must be
        // visible before LEFT is processed later in the same input frame.
        require(owner.pinAfterAcceptedPress(screen, menu, right, true),
                "accepted pickup did not immediately pin its controller");
        require(owner.owns(screen, menu, right),
                "pickup owner was not visible to the next controller");
        require(!WristPointerPressPolicy.accepts(
                        true,
                        true,
                        owner.owns(screen, menu, left),
                        true,
                        200.0D,
                        100.0D,
                        504,
                        270,
                        true,
                        ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "the other controller entered between pickup down and release");
        require(!owner.pinAfterAcceptedPress(screen, menu, left, true),
                "an interleaved controller stole the carried stack");
        require(owner.owns(screen, menu, right),
                "interleaving changed the original controller owner");

        // RIGHT's accepted outside mouse-down dropped the stack. Clearing is
        // equally synchronous, so a later clean pickup can choose either hand.
        require(!owner.pinAfterAcceptedPress(screen, menu, right, false),
                "empty carried state reported a live owner");
        require(!owner.isActive(),
                "accepted outside drop did not clear ownership immediately");
        require(owner.pinAfterAcceptedPress(screen, menu, left, true),
                "new pickup could not choose a controller after the drop");
        require(owner.owns(screen, menu, left),
                "post-drop pickup retained the stale controller");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
