package org.questcraft.veq.client.input;

import org.apache.commons.lang3.tuple.Pair;

import java.util.Objects;
import java.util.Set;

/** Rewrites only Quest Touch suggested bindings; contextual actions remain untouched. */
public final class QuestGripBindingPolicy {
    public static final String RADIAL_ACTION = "/actions/ingame/in/vivecraft.key.radialMenu";
    public static final String HOTBAR_PREVIOUS_ACTION = "/actions/ingame/in/vivecraft.key.hotbarPrev";
    public static final String HOTBAR_NEXT_ACTION = "/actions/ingame/in/vivecraft.key.hotbarNext";
    public static final String ATTACK_ACTION = "/actions/ingame/in/key.attack";
    public static final String USE_ACTION = "/actions/ingame/in/key.use";
    public static final String MAIN_ATTACK_ACTION = "/actions/ingame/in/vivecraft.key.mainAttack";
    public static final String OFFHAND_USE_ACTION = "/actions/ingame/in/vivecraft.key.offhandUse";
    /** Legacy core path retained for ABI stability; v67 routes it to MAIN_HAND. */
    public static final String MAIN_USE_BUTTON_ACTION =
            "/actions/ingame/in/vivecraft.key.offhandUseButton";
    public static final String TELEPORT_ACTION = "/actions/ingame/in/vivecraft.key.teleport";
    public static final String TELEPORT_FALLBACK_ACTION =
            "/actions/ingame/in/vivecraft.key.teleportFallback";
    public static final String LEFT_SQUEEZE = "/user/hand/left/input/squeeze/value";
    public static final String RIGHT_SQUEEZE = "/user/hand/right/input/squeeze/value";
    public static final String LEFT_TRIGGER = "/user/hand/left/input/trigger/value";
    public static final String RIGHT_TRIGGER = "/user/hand/right/input/trigger/value";
    public static final String LEFT_X = "/user/hand/left/input/x/click";
    public static final String RIGHT_B = "/user/hand/right/input/b/click";

    private QuestGripBindingPolicy() {
    }

    public static void apply(Set<Pair<String, String>> bindings) {
        apply(bindings, QuestButtonLayout.personalDefaults());
    }

    public static void apply(
            Set<Pair<String, String>> bindings,
            QuestButtonLayout layout
    ) {
        Objects.requireNonNull(bindings, "bindings");
        Objects.requireNonNull(layout, "layout");
        bindings.removeIf(binding -> {
            String action = binding.getLeft();
            String input = binding.getRight();
            boolean squeeze = LEFT_SQUEEZE.equals(input) || RIGHT_SQUEEZE.equals(input);
            boolean oldHotbarScroll = HOTBAR_PREVIOUS_ACTION.equals(action) || HOTBAR_NEXT_ACTION.equals(action);
            boolean personalControl = ATTACK_ACTION.equals(action) || USE_ACTION.equals(action) ||
                    MAIN_ATTACK_ACTION.equals(action) || OFFHAND_USE_ACTION.equals(action) ||
                    MAIN_USE_BUTTON_ACTION.equals(action) ||
                    TELEPORT_ACTION.equals(action) || TELEPORT_FALLBACK_ACTION.equals(action);
            boolean faceButtonWorldOrGlobal = isWorldOrGlobalAction(action) && isFaceButton(input);
            // Remove every old world/global face-button suggestion, then rebuild
            // all four from one immutable config snapshot. GUI bindings remain
            // untouched, so trigger clicks continue to operate menus.
            return RADIAL_ACTION.equals(action) || squeeze && oldHotbarScroll || personalControl ||
                    faceButtonWorldOrGlobal;
        });
        bindings.add(Pair.of(RADIAL_ACTION, LEFT_SQUEEZE));
        bindings.add(Pair.of(RADIAL_ACTION, RIGHT_SQUEEZE));
        // Each handed action must be suggested on both physical paths. OpenXR
        // applies reverseHands exactly once when it resolves the logical
        // subaction; gameplay consumes RIGHT for main and LEFT for offhand.
        bindings.add(Pair.of(MAIN_ATTACK_ACTION, LEFT_TRIGGER));
        bindings.add(Pair.of(MAIN_ATTACK_ACTION, RIGHT_TRIGGER));
        bindings.add(Pair.of(OFFHAND_USE_ACTION, RIGHT_TRIGGER));
        bindings.add(Pair.of(OFFHAND_USE_ACTION, LEFT_TRIGGER));
        for (QuestFaceButton button : QuestFaceButton.values()) {
            for (String actionPath : layout.action(button).actionPaths()) {
                bindings.add(Pair.of(actionPath, button.inputPath()));
            }
        }
    }

    private static boolean isWorldOrGlobalAction(String action) {
        return action != null && (action.startsWith("/actions/ingame/in/") ||
                action.startsWith("/actions/global/in/") ||
                action.startsWith("/actions/mod/in/"));
    }

    private static boolean isFaceButton(String input) {
        if (input == null) {
            return false;
        }
        for (QuestFaceButton button : QuestFaceButton.values()) {
            if (button.inputPath().equals(input)) {
                return true;
            }
        }
        return false;
    }
}
