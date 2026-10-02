package org.questcraft.veq.fabric;

import com.terraformersmc.modmenu.api.ConfigScreenFactory;
import com.terraformersmc.modmenu.api.ModMenuApi;
import org.questcraft.veq.client.gui.WristSettingsScreen;

/** Gives the installed Mod Menu a direct, controller-accessible settings entry. */
public final class VeqModMenu implements ModMenuApi {
    @Override
    public ConfigScreenFactory<?> getModConfigScreenFactory() {
        return WristSettingsScreen::new;
    }
}
