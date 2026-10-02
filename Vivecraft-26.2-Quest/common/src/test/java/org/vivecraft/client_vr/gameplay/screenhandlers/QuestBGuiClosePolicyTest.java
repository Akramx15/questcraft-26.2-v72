package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class QuestBGuiClosePolicyTest {
    @Test
    void acceptsOnlyOwnedNativeOrPlayerInventoryScreens() {
        Assertions.assertTrue(QuestBGuiClosePolicy.isEligible(true, false, false, false, true, false));
        Assertions.assertTrue(QuestBGuiClosePolicy.isEligible(false, true, false, false, true, true));
        Assertions.assertTrue(QuestBGuiClosePolicy.isEligible(false, false, true, false, false, true),
            "Creative owns its ItemPickerMenu while the player remains on inventoryMenu");

        Assertions.assertFalse(QuestBGuiClosePolicy.isEligible(false, false, false, false, true, true),
            "chat, pause and external/wrist overlays are not eligible screens");
        Assertions.assertFalse(QuestBGuiClosePolicy.isEligible(true, false, false, false, false, false),
            "a stale world-container screen cannot close a replacement menu");
        Assertions.assertFalse(QuestBGuiClosePolicy.isEligible(false, true, false, false, false, true),
            "a stale inventory screen cannot close a replacement menu");
        Assertions.assertFalse(QuestBGuiClosePolicy.isEligible(false, false, true, false, false, false),
            "Creative cannot close after the player leaves inventoryMenu");
        Assertions.assertFalse(QuestBGuiClosePolicy.isEligible(false, false, false, false, false, true),
            "inventoryMenu ownership alone cannot make an unrelated screen eligible");
        Assertions.assertFalse(QuestBGuiClosePolicy.isEligible(false, true, false, true, true, true),
            "a Wrist-owned InventoryScreen must never close from B");
        Assertions.assertFalse(QuestBGuiClosePolicy.isEligible(false, false, true, true, false, true),
            "a Wrist-owned Creative inventory must never close from B");
        Assertions.assertTrue(QuestBGuiClosePolicy.isEligible(true, false, false, true, true, false),
            "a contextual overlay may own rendering while Minecraft retains native-container lifecycle");
    }
}
