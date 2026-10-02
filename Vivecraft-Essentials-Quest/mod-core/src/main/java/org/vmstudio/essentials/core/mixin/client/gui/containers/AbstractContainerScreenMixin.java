package org.vmstudio.essentials.core.mixin.client.gui.containers;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.AbstractWidget;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.gui.screens.inventory.MenuAccess;
import net.minecraft.core.NonNullList;
import net.minecraft.network.chat.Component;
import net.minecraft.world.inventory.AbstractContainerMenu;
import net.minecraft.world.inventory.Slot;
import org.jetbrains.annotations.NotNull;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Mutable;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vmstudio.essentials.core.client.extensions.AbstractContainerScreenExtension;
import org.vmstudio.essentials.core.client.gui.ContainerSlot;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.VisorAPI;
import org.vmstudio.visor.api.client.gui.overlays.framework.screen.VROverlayScreenInScreen;
import org.vmstudio.visor.api.client.gui.overlays.framework.template.VROverlayTemplateScreenInScreen;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;

import static org.vmstudio.essentials.core.client.AddonEntryClient.MC;

/** Minecraft 26.2 slot-extraction bridge for compact VR containers. */
@Mixin(AbstractContainerScreen.class)
public abstract class AbstractContainerScreenMixin<T extends AbstractContainerMenu>
        extends Screen implements MenuAccess<T>, AbstractContainerScreenExtension {
    @Shadow @Final protected T menu;
    @Shadow protected int leftPos;
    @Shadow protected int topPos;
    @Shadow @Final @Mutable protected int imageWidth;
    @Shadow @Final @Mutable protected int imageHeight;
    @Shadow protected abstract void extractSlot(
            GuiGraphicsExtractor graphics, Slot slot, int x, int y);

    @Unique private List<ContainerSlot> visorEssentials$vrSlots;
    @Unique private LinkedHashMap<Slot, ContainerSlot> visorEssentials$vrSlotsMap;
    @Unique private boolean visorEssentials$isVrContainer;
    @Unique private int visorEssentials$edgeX = -1;
    @Unique private int visorEssentials$edgeY = -1;
    @Unique private int visorEssentials$edgeWidth = -1;
    @Unique private int visorEssentials$edgeHeight = -1;

    protected AbstractContainerScreenMixin(Component title) {
        super(title);
    }

    @Inject(method = "<init>", at = @At("TAIL"))
    private void visorEssentials$createSlotState(CallbackInfo ci) {
        visorEssentials$vrSlots = new ArrayList<>();
        visorEssentials$vrSlotsMap = new LinkedHashMap<>();
    }

    @Inject(method = "init", at = @At("HEAD"))
    private void visorEssentials$prepareVrContainer(CallbackInfo ci) {
        if (!visorEssentials$isVrContainer) return;
        visorEssentials$preInit();
        visorEssentials$rebuildSlots();
    }

    @Inject(method = "extractSlots", at = @At("HEAD"), cancellable = true)
    private void visorEssentials$extractVrSlots(GuiGraphicsExtractor graphics,
                                                int mouseX, int mouseY,
                                                CallbackInfo ci) {
        if (!visorEssentials$isVrContainer || visorEssentials$vrSlots == null) return;
        for (ContainerSlot entry : visorEssentials$vrSlots) {
            Slot slot = entry.parent();
            if (slot.isActive()) {
                extractSlot(graphics, slot, entry.vrPosX(), entry.vrPosY());
            }
        }
        ci.cancel();
    }

    /*
     * Minecraft 26.2 keeps the x/y parameters on extractSlot, but no longer
     * uses them: every item, empty-slot sprite, quick-craft tint, decoration,
     * and render seed is positioned from Slot.x/y directly. Redirect those
     * reads through the VR slot map so compact wrist layouts render at the
     * same coordinates already used by their background and hit testing.
     */
    @Redirect(method = "extractSlot", at = @At(
            value = "FIELD", target = "Lnet/minecraft/world/inventory/Slot;x:I"))
    private int visorEssentials$extractSlotX(Slot slot) {
        return visorEssentials$getSlotX(slot);
    }

    @Redirect(method = "extractSlot", at = @At(
            value = "FIELD", target = "Lnet/minecraft/world/inventory/Slot;y:I"))
    private int visorEssentials$extractSlotY(Slot slot) {
        return visorEssentials$getSlotY(slot);
    }

    @Inject(method = "getHoveredSlot", at = @At("HEAD"), cancellable = true)
    private void visorEssentials$getHoveredVrSlot(double mouseX, double mouseY,
                                                  CallbackInfoReturnable<Slot> cir) {
        if (!visorEssentials$isVrContainer || visorEssentials$vrSlots == null) return;
        for (ContainerSlot entry : visorEssentials$vrSlots) {
            Slot slot = entry.parent();
            double x = mouseX - leftPos;
            double y = mouseY - topPos;
            if (slot.isActive()
                    && x >= entry.vrPosX() - 1 && x < entry.vrPosX() + 17
                    && y >= entry.vrPosY() - 1 && y < entry.vrPosY() + 17) {
                cir.setReturnValue(slot);
                return;
            }
        }
        cir.setReturnValue(null);
    }

    @Redirect(method = "extractSlotHighlightBack", at = @At(
            value = "FIELD", target = "Lnet/minecraft/world/inventory/Slot;x:I"))
    private int visorEssentials$highlightBackX(Slot slot) {
        return visorEssentials$getSlotX(slot);
    }

    @Redirect(method = "extractSlotHighlightBack", at = @At(
            value = "FIELD", target = "Lnet/minecraft/world/inventory/Slot;y:I"))
    private int visorEssentials$highlightBackY(Slot slot) {
        return visorEssentials$getSlotY(slot);
    }

    @Redirect(method = "extractSlotHighlightFront", at = @At(
            value = "FIELD", target = "Lnet/minecraft/world/inventory/Slot;x:I"))
    private int visorEssentials$highlightFrontX(Slot slot) {
        return visorEssentials$getSlotX(slot);
    }

    @Redirect(method = "extractSlotHighlightFront", at = @At(
            value = "FIELD", target = "Lnet/minecraft/world/inventory/Slot;y:I"))
    private int visorEssentials$highlightFrontY(Slot slot) {
        return visorEssentials$getSlotY(slot);
    }

    @Redirect(method = "mouseReleased", at = @At(
            value = "INVOKE", target = "Lnet/minecraft/core/NonNullList;iterator()Ljava/util/Iterator;"),
            require = 0)
    private Iterator<Slot> visorEssentials$releaseSlotIterator(NonNullList<Slot> slots) {
        if (visorEssentials$isVrContainer && visorEssentials$vrSlotsMap != null) {
            return visorEssentials$vrSlotsMap.keySet().iterator();
        }
        return slots.iterator();
    }

    @Inject(method = "extractCarriedItem", at = @At("HEAD"), cancellable = true)
    private void visorEssentials$externalDraggedItem(GuiGraphicsExtractor graphics,
                                                     int mouseX, int mouseY,
                                                     CallbackInfo ci) {
        if (!VisorEssentials.customInventory || VisorAPI.clientState().stateMode().isNotActive()) return;
        var focused = VisorAPI.client().getGuiManager().getCursorHandler().getFocusedOverlay();
        boolean focusedHere = focused != null && focused.getId().equals("game_screen")
                && MC.gui.screen() == (Object) this;
        if (focused instanceof VROverlayScreenInScreen<?> inScreen) {
            focusedHere = inScreen.getScreen() == (Object) this;
        } else if (focused instanceof VROverlayTemplateScreenInScreen<?> inTemplate) {
            focusedHere = inTemplate.getScreen() == (Object) this;
        }
        if (!focusedHere) ci.cancel();
    }

    @Unique
    private void visorEssentials$rebuildSlots() {
        if (visorEssentials$vrSlots == null) visorEssentials$vrSlots = new ArrayList<>();
        if (visorEssentials$vrSlotsMap == null) visorEssentials$vrSlotsMap = new LinkedHashMap<>();
        visorEssentials$fillVRSlots(visorEssentials$vrSlots);
        visorEssentials$vrSlotsMap.clear();
        for (ContainerSlot entry : visorEssentials$vrSlots) {
            visorEssentials$vrSlotsMap.put(entry.parent(), entry);
        }
    }

    @Unique private int visorEssentials$getSlotX(Slot slot) {
        ContainerSlot mapped = visorEssentials$vrSlotsMap == null ? null : visorEssentials$vrSlotsMap.get(slot);
        return visorEssentials$isVrContainer && mapped != null ? mapped.vrPosX() : slot.x;
    }

    @Unique private int visorEssentials$getSlotY(Slot slot) {
        ContainerSlot mapped = visorEssentials$vrSlotsMap == null ? null : visorEssentials$vrSlotsMap.get(slot);
        return visorEssentials$isVrContainer && mapped != null ? mapped.vrPosY() : slot.y;
    }

    @Override
    public void visorEssentials$fillVRSlots(@NotNull List<ContainerSlot> slots) {
        slots.clear();
        for (Slot slot : menu.slots) {
            // The generic 26.2 fallback retains the complete native layout.
            // Dedicated compact screens override this method when they really
            // do remap or omit slots.
            slots.add(new ContainerSlot(slot, slot.x, slot.y));
        }
    }

    @Override
    public void visorEssentials$setVRContainer(boolean flag) {
        visorEssentials$isVrContainer = flag;
        if (flag && menu != null) visorEssentials$rebuildSlots();
    }

    /**
     * Keep the 26.2 fallback deliberately scoped to vanilla container
     * screens. Their native extracted layout is safe to host in the world
     * overlay even when a dedicated compact skin has not yet been supplied;
     * unknown modded screens remain normal desktop screens.
     */
    @Override
    public boolean visorEssentials$supportsVRContainer() {
        return ((Object) this).getClass().getName()
                .startsWith("net.minecraft.client.gui.screens.inventory.");
    }

    @Override public boolean visorEssentials$isVRContainer() { return visorEssentials$isVrContainer; }

    @Override
    public void visorEssentials$removeWidgetsOutsideVRPanel() {
        if (!visorEssentials$isVrContainer) return;
        // Native recipe-book/page widgets are allowed to overhang their
        // vanilla panel. Only compact addon-owned layouts should prune global
        // injected widgets.
        if (((Object) this).getClass().getName()
                .startsWith("net.minecraft.client.gui.screens.inventory.")) {
            return;
        }
        int right = leftPos + imageWidth;
        int bottom = topPos + imageHeight;
        children().stream()
                .filter(AbstractWidget.class::isInstance)
                .map(AbstractWidget.class::cast)
                .filter(widget -> widget.getX() < leftPos || widget.getY() < topPos
                        || widget.getX() + widget.getWidth() > right
                        || widget.getY() + widget.getHeight() > bottom)
                .toList()
                .forEach(this::removeWidget);
    }

    @Override public void visorEssentials$setEdgeX(int value) { visorEssentials$edgeX = value; }
    @Override public void visorEssentials$setEdgeY(int value) { visorEssentials$edgeY = value; }
    @Override public void visorEssentials$setEdgeWidth(int value) { visorEssentials$edgeWidth = value; }
    @Override public void visorEssentials$setEdgeHeight(int value) { visorEssentials$edgeHeight = value; }
    @Override public int visorEssentials$getEdgeX() {
        return visorEssentials$edgeX >= 0 ? visorEssentials$edgeX : leftPos;
    }
    @Override public int visorEssentials$getEdgeY() {
        return visorEssentials$edgeY >= 0 ? visorEssentials$edgeY : topPos;
    }
    @Override public int visorEssentials$getEdgeWidth() {
        return visorEssentials$edgeWidth >= 0 ? visorEssentials$edgeWidth : imageWidth;
    }
    @Override public int visorEssentials$getEdgeHeight() {
        return visorEssentials$edgeHeight >= 0 ? visorEssentials$edgeHeight : imageHeight;
    }
}
