package org.questcraft.veq.client.input;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;

/** Deterministic RC8 audit of the complete right-trigger ownership handoff. */
public final class RightTriggerOwnershipRecoverySelfTest {
    private RightTriggerOwnershipRecoverySelfTest() {
    }

    public static void main(String[] args) {
        ownerTransitionsRequireReleaseAndRecover();
        lifecycleTransitionsRequireReleaseAndRecover();
        oppositeHandOwnershipDoesNotSuppressRightTrigger();
        System.out.println("RightTriggerOwnershipRecoverySelfTest PASS");
    }

    private static void ownerTransitionsRequireReleaseAndRecover() {
        HandActionPriority.Owner[] blockingOwners = {
            HandActionPriority.Owner.WRIST,
            HandActionPriority.Owner.TRACKER,
            HandActionPriority.Owner.IMMERSIVE,
            HandActionPriority.Owner.CLIMBING,
            HandActionPriority.Owner.GRIP
        };
        for (HandActionPriority.Owner owner : blockingOwners) {
            IndependentAttackLatch latch = new IndependentAttackLatch();
            require(!route(latch, RELEASED, owner, true, false), owner + " neutral setup");
            require(!route(latch, DOWN, owner, true, false), owner + " suppresses its press");
            require(!route(latch, DOWN, HandActionPriority.Owner.WORLD, true, false),
                    owner + " cannot replay a held press after ownership returns");
            require(!route(latch, RELEASED, HandActionPriority.Owner.WORLD, true, false),
                    owner + " release rearms without attacking");
            require(route(latch, DOWN, HandActionPriority.Owner.WORLD, true, false),
                    owner + " fresh post-release press reaches world");
        }
    }

    private static void lifecycleTransitionsRequireReleaseAndRecover() {
        IndependentAttackLatch latch = new IndependentAttackLatch();
        require(!route(latch, DOWN, HandActionPriority.Owner.WORLD, false, false),
                "GUI/session-not-ready press is suppressed");
        require(!route(latch, DOWN, HandActionPriority.Owner.WORLD, true, false),
                "held press cannot leak after GUI/session resumes");
        require(!route(latch, RELEASED, HandActionPriority.Owner.WORLD, true, false),
                "post-resume release rearms");
        require(route(latch, DOWN, HandActionPriority.Owner.WORLD, true, false),
                "fresh press after resume reaches world");

        IndependentAttackLatch bowLatch = new IndependentAttackLatch();
        require(!route(bowLatch, DOWN, HandActionPriority.Owner.TRACKER, true, true),
                "armed bow owns both hands");
        require(!route(bowLatch, DOWN, HandActionPriority.Owner.WORLD, true, false),
                "held draw trigger cannot become mining");
        require(!route(bowLatch, RELEASED, HandActionPriority.Owner.WORLD, true, false),
                "bow release rearms without mining");
        require(route(bowLatch, DOWN, HandActionPriority.Owner.WORLD, true, false),
                "fresh trigger after bow release mines");
    }

    private static void oppositeHandOwnershipDoesNotSuppressRightTrigger() {
        IndependentAttackLatch latch = new IndependentAttackLatch();
        HandActionPriority.Owner rightOwner = HandActionPriority.choose(
                false, false, false, false, false);
        require(route(latch, DOWN, rightOwner, true, false),
                "an owner on the opposite hand does not change the right-hand snapshot");
    }

    private static boolean route(
            IndependentAttackLatch latch,
            LeftUseCapture.Sample sample,
            HandActionPriority.Owner owner,
            boolean runtimeReady,
            boolean bowOwnsBothHands
    ) {
        boolean allowed = HandOwnershipSnapshot.worldAllowed(
                runtimeReady, true, true, owner, bowOwnsBothHands);
        return latch.update(sample, allowed, RELEASED, false);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
