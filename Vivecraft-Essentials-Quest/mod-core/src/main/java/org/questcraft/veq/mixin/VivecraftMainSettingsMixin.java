package org.questcraft.veq.mixin;

import org.questcraft.veq.client.gui.QuestButtonBindingsScreen;
import org.questcraft.veq.client.gui.WristSettingsScreen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vivecraft.client.gui.framework.widgets.SettingsList;
import org.vivecraft.client.gui.settings.VivecraftMainSettings;

import java.util.ArrayList;
import java.util.List;

/** Adds the add-on's existing screen to Vivecraft's settings navigation. */
@Mixin(value = VivecraftMainSettings.class, remap = false)
public abstract class VivecraftMainSettingsMixin {
    @Inject(method = "getEntries", at = @At("RETURN"), cancellable = true, remap = false)
    private void veq$addWristSettings(
            CallbackInfoReturnable<List<SettingsList.BaseEntry>> callback
    ) {
        List<SettingsList.BaseEntry> original = callback.getReturnValue();
        if (original == null) {
            return;
        }

        // Work on a copy so this remains safe if Vivecraft later returns an
        // immutable list. Put VEQ with the other screens, before the first
        // category header, instead of hard-coding a row in the VR layout.
        List<SettingsList.BaseEntry> entries = new ArrayList<>(original);
        int insertionIndex = entries.size();
        for (int i = 0; i < entries.size(); i++) {
            if (entries.get(i) instanceof SettingsList.CategoryEntry) {
                insertionIndex = i;
                break;
            }
        }
        entries.add(insertionIndex, new SettingsList.ScreenEntry(
                "vivecraft_essentials_quest.settings",
                WristSettingsScreen::new
        ));
        entries.add(insertionIndex + 1, new SettingsList.ScreenEntry(
                "vivecraft_essentials_quest.quest_controls",
                QuestButtonBindingsScreen::new
        ));
        callback.setReturnValue(entries);
    }
}
