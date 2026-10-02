package org.vmstudio.essentials.core.mixin.client.gui.containers;

import org.vmstudio.essentials.core.client.extensions.AbstractContainerScreenExtension;
import org.vmstudio.essentials.core.common.VisorEssentials;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.screens.inventory.AnvilScreen;
import net.minecraft.client.gui.screens.inventory.ItemCombinerScreen;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.inventory.AnvilMenu;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(AnvilScreen.class)
public abstract class AnvilScreenMixin
        extends ItemCombinerScreen<AnvilMenu>
        implements AbstractContainerScreenExtension {
    @Unique
    private static final Identifier visorEssentials$VrTexture = Identifier.fromNamespaceAndPath(
            VisorEssentials.MOD_ID,
            "textures/gui/container/anvil.png"
    );

    public AnvilScreenMixin(AnvilMenu menu, Inventory playerInventory, Component title, Identifier menuResource) {
        super(menu, playerInventory, title, menuResource);
    }


    @Override
    public void visorEssentials$preInit() {
        imageWidth = 176;
        imageHeight = 89;
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
    @Redirect(method = "renderBg", at = @At(value = "INVOKE", target = "Lnet/minecraft/client/gui/GuiGraphicsExtractor;blitSprite(Lnet/minecraft/resources/Identifier;IIII)V"))
    private void visorEssentials$background2(GuiGraphicsExtractor instance, Identifier sprite, int x, int y, int width, int height){
        if(visorEssentials$isVRContainer()) {
            instance.blitSprite(sprite,
                    this.leftPos + 59,
                    this.topPos + 20,
                    width, height);

            return;
        }
        instance.blitSprite(sprite, x, y, width, height);

    }

    @Override
    public boolean visorEssentials$supportsVRContainer() {
        return true;
    }
}
