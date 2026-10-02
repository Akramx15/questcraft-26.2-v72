package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

public final class HotbarHandStateSelfTest {
    private HotbarHandStateSelfTest() {
    }

    public static void main(String[] args) {
        HotbarHandState.accepted(ControllerType.RIGHT, 2);
        HotbarHandState.accepted(ControllerType.LEFT, 7);
        HotbarHandState.hovered(ControllerType.RIGHT, 3);
        HotbarHandState.hovered(ControllerType.LEFT, 8);
        require(HotbarHandState.lastChoice(ControllerType.RIGHT) == 2,
                "right choice remains independent");
        require(HotbarHandState.lastChoice(ControllerType.LEFT) == 7,
                "left choice remains independent");
        require(HotbarHandState.hovered(ControllerType.RIGHT) == 3,
                "right hover remains independent");
        require(HotbarHandState.hovered(ControllerType.LEFT) == 8,
                "left hover remains independent");

        HotbarHandState.beginSession(ControllerType.RIGHT);
        require(HotbarHandState.hovered(ControllerType.RIGHT) == -1,
                "right session clears only right hover");
        require(HotbarHandState.hovered(ControllerType.LEFT) == 8,
                "right session cannot erase pending left hover state");

        HotbarHandState.beginSession();
        for (ControllerType controller : ControllerType.values()) {
            require(!HotbarHandState.hasCurrentHover(controller),
                    controller + " release before the first tracked sample has no selection");
            HotbarHandState.updateHover(controller, true, 4);
            require(HotbarHandState.hasCurrentHover(controller),
                    controller + " pointed sample becomes selectable");
            HotbarHandState.updateHover(controller, false, 4);
            require(!HotbarHandState.hasCurrentHover(controller),
                    controller + " pointed-to-unpointed release cannot reuse the old slot");
        }

        long now = 1_000L;
        HotbarHandState.rejected(ControllerType.LEFT, 4, now);
        require(HotbarHandState.isRejected(ControllerType.LEFT, 4, now),
                "left rejection has visual feedback");
        require(!HotbarHandState.isRejected(ControllerType.RIGHT, 4, now),
                "left rejection cannot leak into right menu");
        require(HotbarHandState.rejectedSlot(ControllerType.LEFT, now) == 4,
                "rejected slot is available to the renderer");
        require(!HotbarHandState.isRejected(
                        ControllerType.LEFT, 4, now + HotbarHandState.REJECTION_NANOS),
                "rejection feedback expires");

        HotbarHandState.pending(ControllerType.LEFT, 5);
        require(HotbarHandState.isPending(ControllerType.LEFT, 5),
                "left swap is visibly pending");
        require(HotbarHandState.pendingSlot(ControllerType.LEFT) == 5,
                "pending slot is available to the yellow renderer");
        require(!HotbarHandState.isPending(ControllerType.RIGHT, 5),
                "pending state cannot leak to right menu");
        HotbarHandState.pending(ControllerType.RIGHT, 2);
        require(HotbarHandState.isPending(ControllerType.RIGHT, 2),
                "right pending state is independent");
        HotbarHandState.clearPending(ControllerType.LEFT);
        require(!HotbarHandState.isPending(ControllerType.LEFT, 5),
                "reconciliation clears only its hand");
        require(HotbarHandState.isPending(ControllerType.RIGHT, 2),
                "left reconciliation cannot clear right state");
        HotbarHandState.clearPending(ControllerType.RIGHT);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
