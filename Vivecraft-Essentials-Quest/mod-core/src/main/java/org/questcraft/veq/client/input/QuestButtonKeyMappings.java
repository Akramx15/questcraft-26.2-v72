package org.questcraft.veq.client.input;

import org.jetbrains.annotations.Nullable;
import org.vivecraft.client_vr.provider.HandedKeyBinding;

/** Runtime-owned proxy actions for configurable Quest controller buttons. */
public final class QuestButtonKeyMappings {
    public static final String ATTACK_BREAK_THIS_HAND_BUTTON_NAME =
            "key.vivecraft_essentials_quest.attack_break_this_hand_button";
    public static final String ATTACK_BREAK_THIS_HAND_BUTTON_ACTION =
            "/actions/mod/in/" + ATTACK_BREAK_THIS_HAND_BUTTON_NAME;

    private static HandedKeyBinding attackBreakThisHandButton;

    private QuestButtonKeyMappings() {
    }

    public static synchronized void registerAttackBreakThisHandButton(HandedKeyBinding mapping) {
        if (attackBreakThisHandButton != null && attackBreakThisHandButton != mapping) {
            throw new IllegalStateException("Quest this-hand attack proxy already registered");
        }
        attackBreakThisHandButton = mapping;
    }

    public static synchronized @Nullable HandedKeyBinding attackBreakThisHandButton() {
        return attackBreakThisHandButton;
    }
}
