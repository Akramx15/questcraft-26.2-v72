package org.questcraft.veq.mixin;

import org.apache.commons.lang3.tuple.Pair;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.config.QuestButtonBindingsConfig;
import org.questcraft.veq.client.input.QuestButtonLayout;
import org.questcraft.veq.client.input.QuestFaceButton;
import org.questcraft.veq.client.input.QuestGripBindingPolicy;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vivecraft.client_vr.provider.openxr.XRBindings;

import java.util.HashSet;

@Mixin(value = XRBindings.class, remap = false)
public abstract class XRBindingsMixin {
    @Inject(method = "quest2Bindings", at = @At("RETURN"), remap = false)
    private static void veq$bindRadialToQuestGrip(
            CallbackInfoReturnable<HashSet<Pair<String, String>>> callback
    ) {
        QuestButtonLayout layout = QuestButtonBindingsConfig.getInstance().markAppliedToOpenXR();
        QuestGripBindingPolicy.apply(callback.getReturnValue(), layout);
        VivecraftEssentialsQuest.LOGGER.info(
                "Quest face buttons: X={}, Y={}, A={}, B={}",
                layout.action(QuestFaceButton.LEFT_X),
                layout.action(QuestFaceButton.LEFT_Y),
                layout.action(QuestFaceButton.RIGHT_A),
                layout.action(QuestFaceButton.RIGHT_B)
        );
    }
}
