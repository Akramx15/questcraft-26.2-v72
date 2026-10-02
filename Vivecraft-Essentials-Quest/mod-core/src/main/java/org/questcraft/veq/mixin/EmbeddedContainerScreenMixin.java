package org.questcraft.veq.mixin;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.network.chat.Component;
import net.minecraft.world.inventory.Slot;
import net.minecraft.world.item.ItemStack;
import org.questcraft.veq.client.gui.EmbeddedSlotLayout;
import org.questcraft.veq.client.overlay.ContainerPointerCancelGuard;
import org.questcraft.veq.client.overlay.ContainerPointerCancellation;
import org.questcraft.veq.client.overlay.ContextualContainerRenderPass;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.util.Set;

/** Slot-coordinate redirects scoped to {@link EmbeddedSlotLayout}. */
@Mixin(AbstractContainerScreen.class)
public abstract class EmbeddedContainerScreenMixin extends Screen
        implements ContainerPointerCancellation {
    @Shadow protected boolean isQuickCrafting;
    @Shadow @Final protected Set<Slot> quickCraftSlots;
    @Shadow private int quickCraftingType;
    @Shadow private int quickCraftingButton;
    @Shadow private boolean skipNextRelease;
    @Shadow private int quickCraftingRemainder;
    @Shadow private boolean doubleclick;
    @Shadow private Slot lastClickSlot;
    @Shadow private ItemStack lastQuickMoved;

    @Unique private final ContainerPointerCancelGuard veq$cancelGuard =
            new ContainerPointerCancelGuard();

    protected EmbeddedContainerScreenMixin(Component title) {
        super(title);
    }

    @Override
    public void veq$cancelPointerGesture(MouseButtonEvent releaseEvent) {
        if (releaseEvent == null) {
            return;
        }
        // This is deliberately a direct invokespecial to Screen. Calling the
        // target virtually would let a modded container subclass transact a
        // slot before AbstractContainerScreen's cancellation hook can run.
        veq$cancelGuard.cancel(
                () -> super.mouseReleased(releaseEvent),
                this::veq$resetContainerPointerGesture
        );
    }

    @Unique
    private void veq$resetContainerPointerGesture() {
        setDragging(false);
        isQuickCrafting = false;
        quickCraftSlots.clear();
        quickCraftingType = 0;
        quickCraftingButton = -1;
        quickCraftingRemainder = 0;
        skipNextRelease = false;
        doubleclick = false;
        lastClickSlot = null;
        lastQuickMoved = ItemStack.EMPTY;
    }

    @Inject(method = "extractCarriedItem", at = @At("HEAD"), cancellable = true)
    private void veq$deferContextualCarriedItem(GuiGraphicsExtractor graphics,
                                                int mouseX,
                                                int mouseY,
                                                CallbackInfo ci) {
        if (ContextualContainerRenderPass.isCarriedDeferred(this)) {
            ci.cancel();
        }
    }

    @Redirect(method = "extractSlot", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;x:I"
    ))
    private int veq$extractSlotX(Slot slot) {
        return veq$x(slot);
    }

    @Redirect(method = "extractSlot", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;y:I"
    ))
    private int veq$extractSlotY(Slot slot) {
        return veq$y(slot);
    }

    @Redirect(method = "extractSlotHighlightBack", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;x:I"
    ))
    private int veq$highlightBackX(Slot slot) {
        return veq$x(slot);
    }

    @Redirect(method = "extractSlotHighlightBack", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;y:I"
    ))
    private int veq$highlightBackY(Slot slot) {
        return veq$y(slot);
    }

    @Redirect(method = "extractSlotHighlightFront", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;x:I"
    ))
    private int veq$highlightFrontX(Slot slot) {
        return veq$x(slot);
    }

    @Redirect(method = "extractSlotHighlightFront", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;y:I"
    ))
    private int veq$highlightFrontY(Slot slot) {
        return veq$y(slot);
    }

    @Redirect(method = "isHovering(Lnet/minecraft/world/inventory/Slot;DD)Z", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;x:I"
    ))
    private int veq$isHoveringX(Slot slot) {
        return veq$x(slot);
    }

    @Redirect(method = "isHovering(Lnet/minecraft/world/inventory/Slot;DD)Z", at = @At(
            value = "FIELD",
            target = "Lnet/minecraft/world/inventory/Slot;y:I"
    ))
    private int veq$isHoveringY(Slot slot) {
        return veq$y(slot);
    }

    @Inject(method = "getHoveredSlot", at = @At("HEAD"), cancellable = true)
    private void veq$getEmbeddedHoveredSlot(double mouseX,
                                            double mouseY,
                                            CallbackInfoReturnable<Slot> cir) {
        if (!((Object) this instanceof EmbeddedSlotLayout layout)) {
            return;
        }
        AbstractContainerScreen<?> screen = (AbstractContainerScreen<?>) (Object) this;
        for (Slot slot : screen.getMenu().slots) {
            EmbeddedSlotLayout.SlotPosition position = layout.veq$slotPosition(slot);
            if (position != null
                    && slot.isActive()
                    && layout.veq$isOverSlot(slot, mouseX, mouseY)) {
                cir.setReturnValue(slot);
                return;
            }
        }
        cir.setReturnValue(null);
    }

    private int veq$x(Slot slot) {
        if ((Object) this instanceof EmbeddedSlotLayout layout) {
            EmbeddedSlotLayout.SlotPosition position = layout.veq$slotPosition(slot);
            if (position != null) {
                return position.x();
            }
        }
        return slot.x;
    }

    private int veq$y(Slot slot) {
        if ((Object) this instanceof EmbeddedSlotLayout layout) {
            EmbeddedSlotLayout.SlotPosition position = layout.veq$slotPosition(slot);
            if (position != null) {
                return position.y();
            }
        }
        return slot.y;
    }
}
