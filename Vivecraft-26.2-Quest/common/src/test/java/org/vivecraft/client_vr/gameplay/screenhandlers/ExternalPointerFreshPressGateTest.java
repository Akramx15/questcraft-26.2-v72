package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.provider.ControllerType;

class ExternalPointerFreshPressGateTest {
    private static final long RIGHT_A_ORIGIN = 0xA001L;
    private static final long LEFT_X_ORIGIN = 0xB001L;

    @Test
    void heldInputAndDrainedStaleEdgesWaitForAFreshRelease() {
        ExternalPointerFreshPressGate gate = new ExternalPointerFreshPressGate();
        Object wrist = new Object();

        assertIdle(gate.update(ControllerType.RIGHT, null, true, RIGHT_A_ORIGIN, true));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, false));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true),
            "one transient neutral sample must not admit a held/stale press");
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, false));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, false));

        ExternalPointerFreshPressGate.Routing fresh =
            gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true);
        Assertions.assertTrue(fresh.pressedEdge());
        Assertions.assertTrue(fresh.buttonDown());
    }

    @Test
    void routesExactlyOneDownThenHoldReleaseAndNextDown() {
        ExternalPointerFreshPressGate gate = armedGate(ControllerType.RIGHT, RIGHT_A_ORIGIN);
        Object wrist = OWNER;

        ExternalPointerFreshPressGate.Routing down =
            gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true);
        Assertions.assertTrue(down.pressedEdge());
        Assertions.assertTrue(down.buttonDown());

        ExternalPointerFreshPressGate.Routing hold =
            gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true);
        Assertions.assertFalse(hold.pressedEdge());
        Assertions.assertTrue(hold.buttonDown());

        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, false),
            "release is represented by buttonDown=false without another press edge");

        ExternalPointerFreshPressGate.Routing secondDown =
            gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true);
        Assertions.assertTrue(secondDown.pressedEdge());
        Assertions.assertTrue(secondDown.buttonDown());
    }

    @Test
    void ownershipAndHandsRemainIndependentAcrossASwitch() {
        ExternalPointerFreshPressGate gate = armedGate(ControllerType.RIGHT, RIGHT_A_ORIGIN);
        Object wrist = OWNER;
        Assertions.assertTrue(gate.update(
            ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true).pressedEdge());

        assertIdle(gate.update(ControllerType.RIGHT, null, true, RIGHT_A_ORIGIN, true),
            "losing pointer ownership must drop the old hand's routed down state");
        assertIdle(gate.update(ControllerType.LEFT, wrist, true, LEFT_X_ORIGIN, true),
            "the new owner cannot inherit a button held before its ownership");
        assertIdle(gate.update(ControllerType.LEFT, wrist, true, LEFT_X_ORIGIN, false));
        assertIdle(gate.update(ControllerType.LEFT, wrist, true, LEFT_X_ORIGIN, false));

        ExternalPointerFreshPressGate.Routing leftDown =
            gate.update(ControllerType.LEFT, wrist, true, LEFT_X_ORIGIN, true);
        Assertions.assertTrue(leftDown.pressedEdge());
        Assertions.assertTrue(leftDown.buttonDown());
    }

    @Test
    void rawOriginChangeForcesReleaseAndFreshPressAfterReverseMapping() {
        ExternalPointerFreshPressGate gate = armedGate(ControllerType.RIGHT, RIGHT_A_ORIGIN);
        Object wrist = OWNER;
        Assertions.assertTrue(gate.update(
            ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true).buttonDown());

        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, LEFT_X_ORIGIN, true),
            "an origin change must release the old capture and suppress the remapped held input");
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, LEFT_X_ORIGIN, false));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, LEFT_X_ORIGIN, false));
        Assertions.assertTrue(gate.update(
            ControllerType.RIGHT, wrist, true, LEFT_X_ORIGIN, true).pressedEdge());
    }

    @Test
    void inactiveActionSetNeverCountsAsARelease() {
        ExternalPointerFreshPressGate gate = new ExternalPointerFreshPressGate();
        Object wrist = new Object();

        assertIdle(gate.update(ControllerType.RIGHT, wrist, false, 0L, false));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, false, 0L, false));
        assertIdle(gate.update(ControllerType.RIGHT, wrist, true, RIGHT_A_ORIGIN, true),
            "inactive samples must not arm a physically held face button");
    }

    private static final Object OWNER = new Object();

    private static ExternalPointerFreshPressGate armedGate(ControllerType controller, long origin) {
        ExternalPointerFreshPressGate gate = new ExternalPointerFreshPressGate();
        assertIdle(gate.update(controller, OWNER, true, origin, false));
        assertIdle(gate.update(controller, OWNER, true, origin, false));
        return gate;
    }

    private static void assertIdle(ExternalPointerFreshPressGate.Routing routing) {
        assertIdle(routing, "sample must not route a button");
    }

    private static void assertIdle(ExternalPointerFreshPressGate.Routing routing, String message) {
        Assertions.assertFalse(routing.pressedEdge(), message);
        Assertions.assertFalse(routing.buttonDown(), message);
    }
}
