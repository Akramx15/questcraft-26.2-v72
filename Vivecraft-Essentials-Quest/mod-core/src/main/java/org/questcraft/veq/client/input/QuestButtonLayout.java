package org.questcraft.veq.client.input;

import java.util.EnumMap;
import java.util.EnumSet;
import java.util.Map;
import java.util.Objects;

/** Immutable Quest face-button layout consumed during OpenXR initialization. */
public record QuestButtonLayout(Map<QuestFaceButton, QuestButtonAction> actions) {
    public QuestButtonLayout {
        Objects.requireNonNull(actions, "actions");
        EnumMap<QuestFaceButton, QuestButtonAction> copy =
                new EnumMap<>(QuestFaceButton.class);
        EnumSet<QuestButtonAction> uniqueSources = EnumSet.noneOf(QuestButtonAction.class);
        for (QuestFaceButton button : QuestFaceButton.values()) {
            QuestButtonAction action = actions.get(button);
            if (action == null || !action.supports(button)) {
                throw new IllegalArgumentException("Unsupported action for " + button + ": " + action);
            }
            if (action.requiresUniquePhysicalSource() && !uniqueSources.add(action)) {
                throw new IllegalArgumentException(
                        "Action requires one physical source: " + action);
            }
            copy.put(button, action);
        }
        actions = Map.copyOf(copy);
    }

    public QuestButtonAction action(QuestFaceButton button) {
        return actions.get(Objects.requireNonNull(button, "button"));
    }

    /** Personal Quest layout requested by the user. */
    public static QuestButtonLayout personalDefaults() {
        EnumMap<QuestFaceButton, QuestButtonAction> actions =
                new EnumMap<>(QuestFaceButton.class);
        actions.put(QuestFaceButton.LEFT_X, QuestButtonAction.TELEPORT);
        actions.put(QuestFaceButton.LEFT_Y, QuestButtonAction.ATTACK_BREAK_THIS_HAND);
        actions.put(QuestFaceButton.RIGHT_A, QuestButtonAction.JUMP);
        actions.put(QuestFaceButton.RIGHT_B, QuestButtonAction.MAIN_HAND_USE);
        return new QuestButtonLayout(actions);
    }

    /** Compatibility preset that restores Y to Inventory without undoing VEQ's Grip/B layout. */
    public static QuestButtonLayout vivecraftDefaults() {
        EnumMap<QuestFaceButton, QuestButtonAction> actions =
                new EnumMap<>(QuestFaceButton.class);
        actions.put(QuestFaceButton.LEFT_X, QuestButtonAction.TELEPORT);
        actions.put(QuestFaceButton.LEFT_Y, QuestButtonAction.INVENTORY);
        actions.put(QuestFaceButton.RIGHT_A, QuestButtonAction.JUMP);
        // VEQ uses Grip for its radial; retaining main-hand use on B avoids
        // reintroducing the old Radial/B conflict during a reset.
        actions.put(QuestFaceButton.RIGHT_B, QuestButtonAction.MAIN_HAND_USE);
        return new QuestButtonLayout(actions);
    }
}
