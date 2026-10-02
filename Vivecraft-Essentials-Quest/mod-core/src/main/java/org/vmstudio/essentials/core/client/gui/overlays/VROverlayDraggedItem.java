package org.vmstudio.essentials.core.client.gui.overlays;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.world.inventory.ContainerInput;
import net.minecraft.world.item.ItemStack;
import org.jetbrains.annotations.NotNull;
import org.joml.Vector3f;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.VisorAPI;
import org.vmstudio.visor.api.client.events.render.HandRenderStateVREvent;
import org.vmstudio.visor.api.client.gui.overlays.VROverlay;
import org.vmstudio.visor.api.client.gui.overlays.VROverlayHelper;
import org.vmstudio.visor.api.client.gui.overlays.framework.VROverlayScreen;
import org.vmstudio.visor.api.client.gui.overlays.framework.screen.VROverlayScreenInScreen;
import org.vmstudio.visor.api.client.gui.overlays.framework.template.VROverlayTemplateScreenInScreen;
import org.vmstudio.visor.api.client.player.pose.PlayerPoseType;
import org.vmstudio.visor.api.client.player.pose.PoseAnchor;
import org.vmstudio.visor.api.client.render.decoration.hand.HandRenderState;
import org.vmstudio.visor.api.common.HandType;
import org.vmstudio.visor.api.common.addon.VisorAddon;
import org.vmstudio.visor.api.common.addon.component.ComponentPriority;
import org.vmstudio.visor.api.common.eventbus.listener.VREventHandler;
import org.vmstudio.visor.api.common.eventbus.listener.VREventListener;


public class VROverlayDraggedItem extends VROverlayScreen
        implements VREventListener {
    public static final String ID = "dragged_item";

    private Vector3f orientPosOffset = new Vector3f(0,0,-0.6f);
    private Vector3f orientRotationOffset = new Vector3f(0,0,0);

    public VROverlayDraggedItem(@NotNull VisorAddon owner,
                                @NotNull String id) {
        super(owner, id, ComponentPriority.HIGHER, 0.1f);
        setEnabled(true);
        cursorBoundsX = width/2 - 8;
        cursorBoundsY = height/2 - 8;
        cursorBoundsWidth = 16;
        cursorBoundsHeight = 16;
        VisorAPI.eventBus().registerListener(owner,this);
    }

    @VREventHandler
    public void onHandRenderState(HandRenderStateVREvent event) {
        if(!isVisible()){
            return;
        }
        var hand = event.getHandType();
        if (hand == VisorAPI.client().getGuiManager().getCursorHandler()
                .getCursorHand()) {
            event.setState(HandRenderState.GUI_HAND);
        }
    }


    @Override
    protected void onRender(GuiGraphicsExtractor guiGraphics, int mouseX, int mouseY, float partialTicks) {
        renderFloatingItem(
                guiGraphics,
                minecraft.player.containerMenu.getCarried(),
                width/2 - 8,height/2 - 8,
                null
        );
    }

    @Override
    public boolean updateVisibility() {
        if(!VisorEssentials.customInventory){
            return false;
        }
        if(!isDraggingItem()) {
            return false;
        }
        var cursorHandler = VisorAPI.client().getGuiManager().getCursorHandler();
        if(!VisorAPI.client().getVRLocalPlayer().getRawController(
                     cursorHandler.getCursorHand()
                ).isTracking()){
            return false;
        }

        // Query the current controller ray instead of cached focus. Cached focus
        // may still point at the inventory after the hand has moved outside it,
        // which would otherwise prevent this drop target from ever appearing.
        var cursorResult = cursorHandler.getCursorResult(
                cursorHandler.getCursorHand(),
                VisorAPI.client().getVRLocalPlayer().getPoseData(PlayerPoseType.RENDER),
                it -> it != this,
                false
        );
        return !supportsDragging(cursorResult.focusedOverlay());
    }



    @Override
    public void onUpdatePose(float partialTicks) {
        PoseAnchor anchor =  VisorAPI.client().getGuiManager().getCursorHandler()
                .getCursorHand() == HandType.MAIN
                ? PoseAnchor.MAIN_HAND
                : PoseAnchor.OFFHAND;
        VROverlayHelper.applyPose(
                this,
                anchor,
                anchor,
                1.0f,
                true,
                orientPosOffset,
                orientRotationOffset
        );
    }


    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubleClick) {
        int i = event.button();
        if(minecraft.player.containerMenu instanceof CreativeModeInventoryScreen.ItemPickerMenu itemPickerMenu){
            if (i == 0) {
                this.minecraft.player.drop(itemPickerMenu.getCarried(), true);
                this.minecraft.gameMode.handleCreativeModeItemDrop(itemPickerMenu.getCarried());
                itemPickerMenu.setCarried(ItemStack.EMPTY);
            }

            if (i == 1) {
                ItemStack itemstack5 = itemPickerMenu.getCarried().split(1);
                this.minecraft.player.drop(itemstack5, true);
                this.minecraft.gameMode.handleCreativeModeItemDrop(itemstack5);
            }
        }else {
            this.minecraft.gameMode.handleContainerInput(
                    minecraft.player.containerMenu.containerId,
                    -999, i, ContainerInput.PICKUP, this.minecraft.player
            );
        }
        return true;
    }


    private void renderFloatingItem(GuiGraphicsExtractor guiGraphics,
                                    ItemStack itemStack,
                                    int posX, int posY,
                                    String string) {
        guiGraphics.pose().pushMatrix();
        guiGraphics.item(itemStack, posX, posY);
        guiGraphics.itemDecorations(
                this.font,
                itemStack,
                posX, posY, string
        );
        guiGraphics.pose().popMatrix();
    }

    private boolean supportsDragging(VROverlay overlay){
        if(overlay != null
                && overlay.getId().equals("game_screen")){
            if(minecraft.gui.screen() instanceof AbstractContainerScreen<?>){
                return true;
            }
        }
        if(overlay instanceof VROverlayScreenInScreen<?> screenInScreen){
            if(screenInScreen.getScreen() instanceof AbstractContainerScreen<?>){
                return true;
            }
        }
        if(overlay instanceof VROverlayTemplateScreenInScreen<?> screenInScreen){
            if(screenInScreen.getScreen() instanceof AbstractContainerScreen<?>){
                return true;
            }
        }
        return false;
    }
    public static boolean isDraggingItem(){
        Minecraft mc = Minecraft.getInstance();
        return mc.level != null
                && mc.player != null
                && mc.player.containerMenu != null
                && mc.player.containerMenu.getCarried() != null
                && !mc.player.containerMenu.getCarried().isEmpty();
    }
}
