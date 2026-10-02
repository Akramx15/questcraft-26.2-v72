package org.vmstudio.essentials.core.mixin.client.gui.containers;

import org.vmstudio.essentials.core.client.extensions.AbstractContainerScreenExtension;
import org.vmstudio.essentials.core.common.VisorEssentials;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.screens.inventory.ItemCombinerScreen;
import net.minecraft.client.gui.screens.inventory.SmithingScreen;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.inventory.SmithingMenu;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(SmithingScreen.class)
public abstract class SmithingScreenMixin
        extends ItemCombinerScreen<SmithingMenu>
        implements AbstractContainerScreenExtension {
    @Unique
    private static final Identifier visorEssentials$VrTexture = Identifier.fromNamespaceAndPath(
            VisorEssentials.MOD_ID,
            "textures/gui/container/smithing.png"
    );

    public SmithingScreenMixin(SmithingMenu menu, Inventory playerInventory, Component title, Identifier menuResource) {
        super(menu, playerInventory, title, menuResource);
    }

    @Override
    public void visorEssentials$preInit() {
        imageWidth = 176;
        imageHeight = 82;
    }

    @Inject(method = "subInit", at = @At("TAIL"))
    private void visorEssentials$updateEdges(CallbackInfo ci){

        visorEssentials$setEdgeX(leftPos);
        visorEssentials$setEdgeY(topPos);
        visorEssentials$setEdgeWidth(imageWidth);
        visorEssentials$setEdgeHeight(imageHeight);
    }

    @Redirect(method = "renderBg", at = @At(value = "INVOKE", target = "Lnet/minecraft/client/gui/screens/inventory/ItemCombinerScreen;renderBg(Lnet/minecraft/client/gui/GuiGraphicsExtractor;FII)V"))
    private void visorEssentials$background(ItemCombinerScreen instance, GuiGraphicsExtractor guiGraphics, float partialTick, int mouseX, int mouseY){
        if(visorEssentials$isVRContainer()) {
            guiGraphics.blit(visorEssentials$VrTexture, this.leftPos, this.topPos, 0, 0, this.imageWidth, this.imageHeight);
            this.renderErrorIcon(guiGraphics, this.leftPos, this.topPos);
            return;
        }
        super.renderBg(guiGraphics, partialTick, mouseX, mouseY);

    }

    @Override
    public boolean visorEssentials$supportsVRContainer() {
        return true;
    }
}
