package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;
import org.vivecraft.client_vr.provider.ControllerType;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.UNKNOWN;
import static org.questcraft.veq.client.input.HandActionPriority.Owner.IMMERSIVE;

/** Host-only contracts for the optional ImmersiveMC handed attack bridge. */
public final class ImmersiveAttackStateSelfTest {
    private ImmersiveAttackStateSelfTest() {
    }

    public static void main(String[] args) {
        unknownSamplesFailOpen();
        onlyImmersiveOwnerCanObserveAttack();
        suppressedHandsCannotSeeTheOtherGlobalAttack();
        handsRemainIndependent();
        downWinsSharedBindingMerge();
        pressBeforeAndInsideHitboxRemainVisible();
        releaseEndsDragEvenWhenGlobalKeyIsStuck();
        immersiveOwnershipNeverReopensTheWorldAction();
        trackingAndLifecycleLossClearState();
        reverseHandsIsAppliedExactlyOnceBeforeTheBridge();
    }

    private static void unknownSamplesFailOpen() {
        ImmersiveAttackState.clear();
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, true),
                "unknown main hand preserves a true original key");
        require(!ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "unknown main hand preserves a false original key");
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, UNKNOWN, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, true),
                "an unavailable action remains fail-open");
        require(ImmersiveAttackState.resolve(null, true),
                "an uncaptured optional-mod hand remains fail-open");
    }

    private static void onlyImmersiveOwnerCanObserveAttack() {
        for (HandActionPriority.Owner owner : HandActionPriority.Owner.values()) {
            ImmersiveAttackState.beginFrame();
            ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, DOWN, owner);
            if (owner == IMMERSIVE) {
                require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                        "ImmersiveMC owner receives its handed attack sample");
            } else if (owner == HandActionPriority.Owner.WORLD) {
                require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, true),
                        "WORLD preserves ImmersiveMC's original key behavior");
            } else {
                require(!ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, true),
                        owner + " ownership suppresses the handed attack and global key");
            }
        }
    }

    private static void suppressedHandsCannotSeeTheOtherGlobalAttack() {
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(
                InteractionHand.MAIN_HAND, DOWN, HandActionPriority.Owner.IMMERSIVE);
        ImmersiveAttackState.observe(
                InteractionHand.OFF_HAND, DOWN, HandActionPriority.Owner.WRIST);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "main immersive hand retains its own press");
        require(!ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, true),
                "suppressed offhand cannot inherit the main/global press");

        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(
                InteractionHand.MAIN_HAND, DOWN, HandActionPriority.Owner.GRIP);
        ImmersiveAttackState.observe(
                InteractionHand.OFF_HAND, DOWN, HandActionPriority.Owner.IMMERSIVE);
        require(!ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, true),
                "suppressed main hand cannot inherit the offhand/global press");
        require(ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, false),
                "offhand immersive hand retains its own press");

        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.suppress(InteractionHand.OFF_HAND);
        require(!ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, true),
                "invalid tracking forces release instead of UNKNOWN fallback");
    }

    private static void handsRemainIndependent() {
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, DOWN, IMMERSIVE);
        ImmersiveAttackState.observe(InteractionHand.OFF_HAND, RELEASED, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "right/main trigger reaches the main-hand immersive");
        require(!ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, true),
                "a global main-hand key cannot activate the released offhand");

        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, RELEASED, IMMERSIVE);
        ImmersiveAttackState.observe(InteractionHand.OFF_HAND, DOWN, IMMERSIVE);
        require(!ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, true),
                "released main hand is isolated from the offhand press");
        require(ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, false),
                "Y/offhand attack reaches the offhand immersive");
    }

    private static void downWinsSharedBindingMerge() {
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, RELEASED, IMMERSIVE);
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, DOWN, IMMERSIVE);
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, RELEASED, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "one down sample wins when two actions resolve to the same hand");
    }

    private static void pressBeforeAndInsideHitboxRemainVisible() {
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, DOWN, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "press before entering survives global world-key suppression");

        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, DOWN, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "held press is still visible after the immersive takes ownership");

        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.OFF_HAND, DOWN, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, false),
                "a press beginning inside a trigger-only hitbox is visible immediately");
    }

    private static void releaseEndsDragEvenWhenGlobalKeyIsStuck() {
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.OFF_HAND, DOWN, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, false),
                "offhand drag begins from its handed press");
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.OFF_HAND, RELEASED, IMMERSIVE);
        require(!ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, true),
                "offhand release ends drag even if the other/global key is down");
    }

    private static void immersiveOwnershipNeverReopensTheWorldAction() {
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, DOWN, IMMERSIVE);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "ImmersiveMC sees its handed trigger modifier");
        require(!HandOwnershipSnapshot.worldAllowed(
                        true, true, true,
                        HandActionPriority.Owner.IMMERSIVE, false),
                "the same trigger cannot attack or break the world behind the immersive");
    }

    private static void trackingAndLifecycleLossClearState() {
        ImmersiveAttackState.beginFrame();
        ImmersiveAttackState.observe(InteractionHand.MAIN_HAND, DOWN, IMMERSIVE);
        ImmersiveAttackState.observe(InteractionHand.OFF_HAND, DOWN, IMMERSIVE);
        ImmersiveAttackState.clear(InteractionHand.OFF_HAND);
        require(ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "one tracked hand survives the other hand's tracking loss");
        require(!ImmersiveAttackState.resolve(InteractionHand.OFF_HAND, false),
                "lost offhand falls back instead of retaining a stale press");
        ImmersiveAttackState.clear();
        require(!ImmersiveAttackState.resolve(InteractionHand.MAIN_HAND, false),
                "world/VR lifecycle reset clears the remaining press");
    }

    private static void reverseHandsIsAppliedExactlyOnceBeforeTheBridge() {
        for (boolean reverseHands : new boolean[]{false, true}) {
            ControllerType logical = QuestHandMapping.logicalFromPhysical(
                    ControllerType.LEFT, reverseHands);
            InteractionHand expected = QuestHandMapping.interactionHand(logical);
            for (HandActionPriority.Owner owner : HandActionPriority.Owner.values()) {
                ImmersiveAttackState.beginFrame();
                ImmersiveAttackState.observe(expected, DOWN, owner);
                boolean expectedValue = owner == IMMERSIVE ||
                        owner == HandActionPriority.Owner.WORLD;
                require(ImmersiveAttackState.resolve(expected, true) == expectedValue,
                        owner + " obeys ownership after the provider maps reverseHands=" +
                                reverseHands);
                InteractionHand other = expected == InteractionHand.MAIN_HAND
                        ? InteractionHand.OFF_HAND
                        : InteractionHand.MAIN_HAND;
                require(!ImmersiveAttackState.resolve(other, false),
                        "bridge must not apply reverseHands a second time");
            }
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
