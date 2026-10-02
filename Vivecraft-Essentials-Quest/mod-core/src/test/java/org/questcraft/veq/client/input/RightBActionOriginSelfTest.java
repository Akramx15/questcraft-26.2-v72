package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;
import org.apache.commons.lang3.tuple.Pair;
import org.vivecraft.client_vr.provider.ControllerType;

import java.util.EnumMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

/** Host-only fingerprint of physical Quest B from binding/origin to main-hand Aim. */
public final class RightBActionOriginSelfTest {
    private static final ControllerType TARGET_AIM = ControllerType.RIGHT;

    private RightBActionOriginSelfTest() {
    }

    public static void main(String[] args) {
        runAll();
    }

    static void runAll() {
        Set<Pair<String, String>> bindings = new LinkedHashSet<>();
        bindings.add(Pair.of(QuestGripBindingPolicy.RADIAL_ACTION, QuestGripBindingPolicy.RIGHT_B));
        bindings.add(Pair.of(QuestGripBindingPolicy.MAIN_ATTACK_ACTION, QuestGripBindingPolicy.RIGHT_B));
        bindings.add(Pair.of(QuestGripBindingPolicy.OFFHAND_USE_ACTION, QuestGripBindingPolicy.RIGHT_B));
        QuestGripBindingPolicy.apply(bindings);

        require(bindings.stream().filter(binding ->
                        QuestGripBindingPolicy.RIGHT_B.equals(binding.getRight())).count() == 1L,
                "physical right B must have exactly one action binding");
        require(bindings.contains(Pair.of(
                        QuestGripBindingPolicy.MAIN_USE_BUTTON_ACTION,
                        QuestGripBindingPolicy.RIGHT_B)),
                "physical right B must bind the dedicated main-hand command");

        verifyPhysicalRightB(false, ControllerType.RIGHT);
        verifyPhysicalRightB(true, ControllerType.LEFT);
    }

    private static void verifyPhysicalRightB(
            boolean reverseHands,
            ControllerType expectedSampleController
    ) {
        ActionOrigin origin = new ActionOrigin(
                0xB001L, ControllerType.RIGHT, QuestGripBindingPolicy.RIGHT_B);
        ControllerType logicalOrigin = QuestHandMapping.logicalFromPhysical(
                origin.physicalController(), reverseHands);
        Map<ControllerType, ActionState> states = new EnumMap<>(ControllerType.class);
        states.put(logicalOrigin, new ActionState(true, true, true, origin));

        SampledAction down = sampleBoundAction(states, reverseHands);
        require(down.sample() == LeftUseCapture.Sample.DOWN, "B press must sample DOWN");
        require(down.controller() == expectedSampleController,
                "B origin must occupy the expected logical subaction");
        require(down.origin() == origin, "sample must retain its physical action origin");
        require(QuestHandMapping.interactionHand(TARGET_AIM) == InteractionHand.MAIN_HAND,
                "B command target must remain MAIN_HAND");
        require(QuestHandMapping.poseIndex(TARGET_AIM) == 0,
                "B command must use logical-right Aim pose only");

        String fingerprint = origin.inputPath() +
                "|origin=" + origin.physicalController() +
                "|sample=" + down.controller() +
                "|aim=" + TARGET_AIM +
                "|hand=" + QuestHandMapping.interactionHand(TARGET_AIM) +
                "|pose=" + QuestHandMapping.poseIndex(TARGET_AIM);
        String expected = QuestGripBindingPolicy.RIGHT_B +
                "|origin=RIGHT|sample=" + expectedSampleController +
                "|aim=RIGHT|hand=MAIN_HAND|pose=0";
        require(expected.equals(fingerprint),
                "physical B fingerprint changed for reverseHands=" + reverseHands);

        states.put(logicalOrigin, new ActionState(true, true, false, origin));
        SampledAction released = sampleBoundAction(states, reverseHands);
        require(released.sample() == LeftUseCapture.Sample.RELEASED &&
                        released.controller() == expectedSampleController,
                "B release must sample on the same logical origin");
    }

    /** Mirrors runtime sampling: only an active subaction with its matching origin is accepted. */
    private static SampledAction sampleBoundAction(
            Map<ControllerType, ActionState> states,
            boolean reverseHands
    ) {
        SampledAction released = SampledAction.UNKNOWN;
        for (ControllerType controller : ControllerType.values()) {
            ActionState state = states.get(controller);
            if (state == null || !state.enabled() || !state.active()) {
                continue;
            }
            ActionOrigin origin = state.origin();
            if (origin.handle() == 0L || !QuestGripBindingPolicy.RIGHT_B.equals(origin.inputPath()) ||
                    QuestHandMapping.logicalFromPhysical(
                            origin.physicalController(), reverseHands) != controller) {
                continue;
            }
            SampledAction sampled = new SampledAction(
                    controller,
                    state.pressed() ? LeftUseCapture.Sample.DOWN : LeftUseCapture.Sample.RELEASED,
                    origin);
            if (sampled.sample() == LeftUseCapture.Sample.DOWN) {
                return sampled;
            }
            released = sampled;
        }
        return released;
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private record ActionOrigin(long handle, ControllerType physicalController, String inputPath) {
    }

    private record ActionState(boolean enabled, boolean active, boolean pressed, ActionOrigin origin) {
    }

    private record SampledAction(
            ControllerType controller,
            LeftUseCapture.Sample sample,
            ActionOrigin origin
    ) {
        private static final SampledAction UNKNOWN =
                new SampledAction(null, LeftUseCapture.Sample.UNKNOWN, null);
    }
}
