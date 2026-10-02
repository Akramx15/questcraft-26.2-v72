package org.questcraft.veq.client.input;

import java.util.List;

/**
 * Safe actions that can be suggested directly to a Quest Touch face button.
 *
 * <p>Bindings are installed once while OpenXR creates its action sets. The
 * configuration UI therefore persists changes immediately but the active XR
 * session must be restarted before a different action receives the button.</p>
 */
public enum QuestButtonAction {
    ATTACK_BREAK_THIS_HAND(
            "vivecraft_essentials_quest.quest_action.attack_break_this_hand",
            List.of(QuestButtonKeyMappings.ATTACK_BREAK_THIS_HAND_BUTTON_ACTION)
    ),
    INVENTORY(
            "vivecraft_essentials_quest.quest_action.inventory",
            List.of("/actions/global/in/key.inventory")
    ),
    JUMP(
            "vivecraft_essentials_quest.quest_action.jump",
            List.of("/actions/ingame/in/key.jump")
    ),
    MAIN_HAND_USE(
            "vivecraft_essentials_quest.quest_action.main_hand_use",
            List.of(QuestGripBindingPolicy.MAIN_USE_BUTTON_ACTION)
    ),
    TELEPORT(
            "vivecraft_essentials_quest.quest_action.teleport",
            List.of(
                    QuestGripBindingPolicy.TELEPORT_ACTION,
                    QuestGripBindingPolicy.TELEPORT_FALLBACK_ACTION
            )
    ),
    SNEAK(
            "vivecraft_essentials_quest.quest_action.sneak",
            List.of("/actions/ingame/in/key.sneak")
    ),
    NONE(
            "vivecraft_essentials_quest.quest_action.none",
            List.of()
    );

    private final String translationKey;
    private final List<String> actionPaths;

    QuestButtonAction(String translationKey, List<String> actionPaths) {
        this.translationKey = translationKey;
        this.actionPaths = actionPaths;
    }

    public String translationKey() {
        return translationKey;
    }

    public List<String> actionPaths() {
        return actionPaths;
    }

    /**
     * These routed actions use the physical origin to enforce per-hand UI and
     * world ownership. Sharing one action between face buttons would erase
     * that identity when two buttons are held at once.
     */
    public boolean requiresUniquePhysicalSource() {
        return this == ATTACK_BREAK_THIS_HAND || this == MAIN_HAND_USE;
    }

    public boolean supports(QuestFaceButton button) {
        return button != null;
    }

    public QuestButtonAction nextFor(QuestFaceButton button) {
        QuestButtonAction[] actions = values();
        for (int offset = 1; offset <= actions.length; offset++) {
            QuestButtonAction candidate = actions[(ordinal() + offset) % actions.length];
            if (candidate.supports(button)) {
                return candidate;
            }
        }
        return NONE;
    }
}
