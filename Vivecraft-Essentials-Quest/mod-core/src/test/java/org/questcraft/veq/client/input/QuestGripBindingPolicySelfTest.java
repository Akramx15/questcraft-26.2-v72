package org.questcraft.veq.client.input;

import org.apache.commons.lang3.tuple.Pair;

import java.util.HashSet;
import java.util.Set;

public final class QuestGripBindingPolicySelfTest {
    private static final String GUI_SECONDARY_ACTION =
            "/actions/gui/in/vivecraft.key.guiRightClick";
    private static final String EXTERNAL_SECONDARY_ACTION =
            "/actions/keyboard/in/vivecraft.key.externalSecondary";

    private QuestGripBindingPolicySelfTest() {
    }

    public static void main(String[] args) {
        Set<Pair<String, String>> bindings = new HashSet<>();
        bindings.add(Pair.of(
                QuestGripBindingPolicy.HOTBAR_PREVIOUS_ACTION,
                QuestGripBindingPolicy.LEFT_SQUEEZE
        ));
        bindings.add(Pair.of(
                QuestGripBindingPolicy.HOTBAR_NEXT_ACTION,
                QuestGripBindingPolicy.RIGHT_SQUEEZE
        ));
        bindings.add(Pair.of(
                QuestGripBindingPolicy.RADIAL_ACTION,
                QuestGripBindingPolicy.RIGHT_B
        ));
        bindings.add(Pair.of(
                "/actions/global/in/key.inventory",
                QuestFaceButton.LEFT_Y.inputPath()
        ));
        bindings.add(Pair.of(
                "/actions/ingame/in/key.jump",
                QuestFaceButton.RIGHT_A.inputPath()
        ));
        bindings.add(Pair.of(
                GUI_SECONDARY_ACTION,
                QuestFaceButton.RIGHT_A.inputPath()
        ));
        bindings.add(Pair.of(
                EXTERNAL_SECONDARY_ACTION,
                QuestFaceButton.RIGHT_A.inputPath()
        ));
        bindings.add(Pair.of(
                EXTERNAL_SECONDARY_ACTION,
                QuestFaceButton.LEFT_X.inputPath()
        ));
        Pair<String, String> contextual = Pair.of(
                "/actions/contextual/in/vivecraft.key.vrInteract",
                QuestGripBindingPolicy.RIGHT_SQUEEZE
        );
        bindings.add(contextual);

        QuestGripBindingPolicy.apply(bindings);
        QuestGripBindingPolicy.apply(bindings);

        require(bindings.contains(Pair.of(
                QuestGripBindingPolicy.RADIAL_ACTION,
                QuestGripBindingPolicy.LEFT_SQUEEZE
        )), "left Grip opens radial");
        require(bindings.contains(Pair.of(
                QuestGripBindingPolicy.RADIAL_ACTION,
                QuestGripBindingPolicy.RIGHT_SQUEEZE
        )), "right Grip opens radial");
        require(bindings.stream().noneMatch(binding ->
                QuestGripBindingPolicy.HOTBAR_PREVIOUS_ACTION.equals(binding.getLeft()) ||
                        QuestGripBindingPolicy.HOTBAR_NEXT_ACTION.equals(binding.getLeft())),
                "old Grip hotbar scrolling removed");
        require(bindings.stream().noneMatch(binding ->
                QuestGripBindingPolicy.RADIAL_ACTION.equals(binding.getLeft()) &&
                        binding.getRight().contains("/b/")),
                "B radial binding removed");
        require(bindings.contains(Pair.of(
                QuestGripBindingPolicy.MAIN_USE_BUTTON_ACTION,
                QuestGripBindingPolicy.RIGHT_B
        )), "physical right B has a dedicated main-hand-use command");
        require(bindings.stream().filter(binding ->
                        QuestGripBindingPolicy.RIGHT_B.equals(binding.getRight())).count() == 1L,
                "B is bound exactly once");
        require(bindings.stream().noneMatch(binding ->
                        QuestGripBindingPolicy.OFFHAND_USE_ACTION.equals(binding.getLeft()) &&
                                QuestGripBindingPolicy.RIGHT_B.equals(binding.getRight())),
                "B never aliases the trigger action");
        require(bindings.contains(contextual), "ImmersiveMC contextual Grip remains unchanged");
        for (String trigger : new String[]{
                QuestGripBindingPolicy.LEFT_TRIGGER,
                QuestGripBindingPolicy.RIGHT_TRIGGER
        }) {
            require(bindings.contains(Pair.of(
                    QuestGripBindingPolicy.MAIN_ATTACK_ACTION, trigger
            )), "both physical triggers feed handed main attack");
            require(bindings.contains(Pair.of(
                    QuestGripBindingPolicy.OFFHAND_USE_ACTION, trigger
            )), "both physical triggers feed handed offhand use");
        }
        require(bindings.stream().noneMatch(binding ->
                QuestGripBindingPolicy.ATTACK_ACTION.equals(binding.getLeft())),
                "configurable attack never aliases global key.attack");
        require(bindings.stream().noneMatch(binding ->
                QuestGripBindingPolicy.USE_ACTION.equals(binding.getLeft())),
                "left trigger never aliases global key.use");
        require(bindings.contains(Pair.of(
                QuestGripBindingPolicy.TELEPORT_ACTION,
                QuestGripBindingPolicy.LEFT_X
        )), "X keeps Vivecraft teleport");
        require(bindings.contains(Pair.of(
                QuestGripBindingPolicy.TELEPORT_FALLBACK_ACTION,
                QuestGripBindingPolicy.LEFT_X
        )), "X keeps teleport fallback");
        require(bindings.contains(Pair.of(
                QuestButtonKeyMappings.ATTACK_BREAK_THIS_HAND_BUTTON_ACTION,
                QuestFaceButton.LEFT_Y.inputPath()
        )), "Y feeds the ownership-aware this-hand attack proxy");
        require(bindings.stream().noneMatch(binding ->
                "/actions/global/in/key.inventory".equals(binding.getLeft()) &&
                        QuestFaceButton.LEFT_Y.inputPath().equals(binding.getRight())),
                "Y no longer opens inventory in personal defaults");
        require(bindings.contains(Pair.of(
                "/actions/ingame/in/key.jump",
                QuestFaceButton.RIGHT_A.inputPath()
        )), "A keeps jump");
        require(bindings.contains(Pair.of(
                EXTERNAL_SECONDARY_ACTION,
                QuestFaceButton.RIGHT_A.inputPath()
        )), "A keeps the owner-scoped keyboard secondary action beside Jump");
        require(bindings.contains(Pair.of(
                EXTERNAL_SECONDARY_ACTION,
                QuestFaceButton.LEFT_X.inputPath()
        )), "X keeps the owner-scoped keyboard secondary action beside Teleport");
        require(bindings.contains(Pair.of(
                GUI_SECONDARY_ACTION,
                QuestFaceButton.RIGHT_A.inputPath()
        )), "the normally activated GUI set keeps its independent A secondary binding");
        require(bindings.stream().filter(binding ->
                QuestFaceButton.RIGHT_A.inputPath().equals(binding.getRight())).count() == 3L,
                "A has exactly GUI secondary, Jump, and owner-scoped keyboard secondary");
        require(bindings.stream().filter(binding ->
                QuestFaceButton.LEFT_X.inputPath().equals(binding.getRight())).count() == 3L,
                "X has exactly Teleport, fallback, and keyboard secondary");
        require(bindings.size() == 15, "rewrite is deterministic and idempotent");

        Set<Pair<String, String>> vivecraftLayout = new HashSet<>(bindings);
        QuestGripBindingPolicy.apply(vivecraftLayout, QuestButtonLayout.vivecraftDefaults());
        require(vivecraftLayout.contains(Pair.of(
                "/actions/global/in/key.inventory",
                QuestFaceButton.LEFT_Y.inputPath()
        )), "Vivecraft reset restores Y inventory");
        require(vivecraftLayout.stream().noneMatch(binding ->
                QuestButtonKeyMappings.ATTACK_BREAK_THIS_HAND_BUTTON_ACTION.equals(binding.getLeft())),
                "Vivecraft reset removes the Y attack proxy");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
