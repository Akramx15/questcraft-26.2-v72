package org.vmstudio.essentials.core.mixin.client;

import com.llamalad7.mixinextras.injector.ModifyExpressionValue;
import com.llamalad7.mixinextras.injector.WrapWithCondition;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.VisorAPI;
import org.vmstudio.essentials.core.client.gui.overlays.VROverlayContainer;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;
import org.vmstudio.essentials.core.client.tasks.BowItemTask;
import org.vmstudio.essentials.core.client.quickactions.QuickActionManager;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Options;
import net.minecraft.client.gui.Gui;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.HasCustomInventoryScreen;
import net.minecraft.world.entity.npc.InventoryCarrier;
import net.minecraft.world.entity.vehicle.ContainerEntity;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.HitResult;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.Slice;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.gen.Invoker;

@Mixin(Minecraft.class)
public abstract class MinecraftMixin {

    @Unique
    private boolean visorEssentials$handledNativeContainerInput;

    @Invoker("handleKeybinds")
    public abstract void visorEssentials$invokeHandleKeybinds();

    @Inject(method = "tick", at = @At("HEAD"))
    private void visorEssentials$resetNativeContainerInput(CallbackInfo ci) {
        visorEssentials$handledNativeContainerInput = false;
    }

    /**
     * Gui.tick is the last stable point before vanilla's screen gates. Run the
     * gameplay input pass exactly once here for an anchored container instead
     * of competing with Baritone's redirect of the second Gui.screen call.
     */
    @Inject(
            method = "tick",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/gui/Gui;tick()V",
                    shift = At.Shift.AFTER
            )
    )
    private void visorEssentials$runNativeContainerInput(CallbackInfo ci) {
        if (!NativeContainerPlacement.isActive() || gui.overlay() != null) {
            return;
        }

        visorEssentials$handledNativeContainerInput = true;
        missTime = 0;
        visorEssentials$invokeHandleKeybinds();
    }

    /**
     * Baritone may make vanilla reach the later call. Suppress it at the
     * callsite so other mods' handleKeybinds HEAD hooks cannot run twice.
     */
    @WrapWithCondition(
            method = "tick",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/Minecraft;handleKeybinds()V"
            ),
            require = 1
    )
    private boolean visorEssentials$avoidDuplicateNativeContainerInput(Minecraft instance) {
        return !visorEssentials$handledNativeContainerInput;
    }

    @Inject(method = "tick", at = @At("TAIL"))
    private void visorEssentials$tickQuickActions(CallbackInfo ci) {
        if (visorEssentials$handledNativeContainerInput) {
            // Vanilla sets this to 10000 when a Screen exists after our pass.
            missTime = 0;
        }
        visorEssentials$handledNativeContainerInput = false;
        NativeContainerPlacement.tickDistanceClose();
        QuickActionManager.getInstance().tick();
    }

    /** Keep held attack/use behaviour available after handleKeybinds starts. */
    @ModifyExpressionValue(
            method = "handleKeybinds",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/gui/Gui;screen()Lnet/minecraft/client/gui/screens/Screen;"
            ),
            require = 2
    )
    private Screen visorEssentials$passWorldContainerHeldInput(Screen original) {
        return NativeContainerPlacement.isActive() ? null : original;
    }

    @Shadow
    @Final
    public Options options;

    @Shadow
    @Final
    public Gui gui;

    @Shadow
    public HitResult hitResult;

    @Shadow
    public LocalPlayer player;

    @Shadow
    protected int missTime;


    /**
     * Suppresses normal mouse keybind handling while a VR overlay has focus
     * and closes an active container overlay when its holder is targeted.
     */
    @Inject(method = "handleKeybinds", at = @At(value = "INVOKE", target = "Lnet/minecraft/client/player/LocalPlayer;isUsingItem()Z", shift = At.Shift.BEFORE, ordinal = 0), cancellable = true)
    private void visorEssentials$mouseAndOverlays(CallbackInfo ci) {
        if(VisorAPI.clientState().stateMode().isNotActive()) return;

        if (VisorAPI.client().getGuiManager().getCursorHandler().getFocusedOverlay() != null) {
            ci.cancel();
        }
        var container = VisorAPI.client().getGuiManager()
                .getOverlayManager()
                .getOverlay("container", VROverlayContainer.class);


        if (System.currentTimeMillis() < container.getLastManualClose() + 200) {
            // consume all key usages
            // if too small-time left after overlay close
            // it fixes accidental opening of same menu
            while (this.options.keyUse.consumeClick()) {
            }
            ci.cancel();
            return;
        }
        if (container.isEnabled()) {
            boolean isBlock = hitResult != null
                    && (hitResult.getType() == HitResult.Type.BLOCK);
            boolean isEntity = hitResult instanceof EntityHitResult
                    && (((EntityHitResult) hitResult).getEntity() instanceof ContainerEntity
                    || ((EntityHitResult) hitResult).getEntity() instanceof InventoryCarrier
                    || ((EntityHitResult) hitResult).getEntity() instanceof HasCustomInventoryScreen);

            if (isEntity) {
                EntityHitResult entityHitResult = (EntityHitResult) hitResult;
                Entity entity = entityHitResult.getEntity();
                if (container.getSourceEntity() == entity) {
                    boolean b = false;
                    // consume all key usages
                    // if too small-time left after overlay close
                    // it fixes accidental opening of same menu
                    while (this.options.keyUse.consumeClick()) {
                        b = true;
                    }
                    if (b) {
                        //close container attached to an entity
                        container.setLastManualClose(System.currentTimeMillis());
                        container.setEnabled(false);
                        ci.cancel();
                    }
                }
            } else if (isBlock) {
                BlockHitResult blockHitResult = (BlockHitResult) hitResult;
                BlockPos blockPos = blockHitResult.getBlockPos();
                if (container.isAttachedTo(blockPos)) {
                    boolean b = false;
                    //consume all key usages
                    // if too small-time left after overlay close
                    //if fixes accidental opening of same menu
                    while (this.options.keyUse.consumeClick()) {
                        b = true;
                    }
                    if (b) {
                        //close container attached to block
                        container.setLastManualClose(System.currentTimeMillis());
                        container.setEnabled(false);
                        ci.cancel();
                    }
                }
            }

        }
    }


    @Redirect(method = "handleKeybinds",
            slice = @Slice(from = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/player/LocalPlayer;isUsingItem()Z",
                    ordinal = 0
            )),
            at = @At(value = "INVOKE",
                    target = "Lnet/minecraft/client/KeyMapping;isDown()Z",
                    ordinal = 0))
    private boolean visorEssentials$keepBowUse(KeyMapping instance) {
        if (VisorAPI.clientState().stateMode().isNotActive()) {
            return instance.isDown();
        }
        BowItemTask bow = BowItemTask.getInstance();
        if (bow != null
                && bow.isActive(this.player)
                && bow.isNotched()) {
            return true;
        }
        return instance.isDown();
    }

}
