package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class NativeContainerLocomotionContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void openXrUsesDedicatedGuiActionWithoutActivatingIngame() throws IOException {
        String source = source("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java");
        Assertions.assertTrue(source.contains("supportsNativeContainerLocomotion()"));
        Assertions.assertFalse(source.contains(
            "|| NativeContainerLocomotion.isActive(this.mc)"),
            "container locomotion must not activate the whole in-game action set");
        Assertions.assertTrue(source.contains("!this.isNativeContainerLocomotionActive()"),
            "the user GUI option must not reactivate world actions in a native container");
        Assertions.assertTrue(source.contains("this.requireFreshWorldPresses()"),
            "closing a container must reject held world actions until a fresh edge");
        Assertions.assertTrue(source.contains(
            "this.unpressedSetKeys.get(VRInputActionSet.INGAME).clear()"),
            "the legacy action-set repress markers must be discarded on close");
        Assertions.assertTrue(source.contains(
            "this.unpressedSetKeys.get(VRInputActionSet.CONTEXTUAL).clear()"),
            "held contextual actions must also require a fresh press after close");

        String bindings = source("org/vivecraft/client_vr/provider/openxr/XRBindings.java");
        Assertions.assertTrue(bindings.contains(
            "/actions/gui/in/vivecraft.key.containerMoveStrafe"));
        Assertions.assertTrue(bindings.contains(
            "/user/hand/left/input/thumbstick"));
        Assertions.assertTrue(bindings.contains(
            "/actions/gui/in/vivecraft.key.containerClose"));
        Assertions.assertTrue(bindings.contains(
            "/user/hand/right/input/b/click"));
    }

    @Test
    void movementUsesOnlyLeftStickAndDoesNotCloseContainer() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/MCVR.java");
        Assertions.assertTrue(provider.contains(
            "gui && !nativeContainerLocomotion && !sleeping"));
        Assertions.assertTrue(provider.contains(
            "this.mc.gui.screen() == null || nativeContainerLocomotion"));
        Assertions.assertTrue(provider.contains("else if (!suppressContainerWorldAxes)"),
            "right-stick and fallback movement must stay disabled while GUI owns those inputs");
        Assertions.assertTrue(provider.contains("this.getInputAction(MOD.keyFlickStick)"),
            "right-stick turning must not race GUI scrolling");
        Assertions.assertTrue(provider.contains("this.isMovement && !nativeContainerLocomotion"),
            "native-container movement must not synthesize inactive INGAME direction keys");

        String keyboard = source("org/vivecraft/mixin/client_vr/KeyboardInputVRMixin.java");
        Assertions.assertTrue(keyboard.contains("NativeContainerMovementInput.shouldDriveMoveVector"));
        Assertions.assertTrue(keyboard.contains("vr.isNativeContainerLocomotionActive()"));

        String locomotion = source(
            "org/vivecraft/client_vr/gameplay/screenhandlers/NativeContainerLocomotion.java");
        Assertions.assertTrue(locomotion.contains(
            "screen instanceof AbstractContainerScreen<?> container"));
        Assertions.assertTrue(locomotion.contains(
            "player.containerMenu == container.getMenu()"));
        Assertions.assertFalse(locomotion.contains("ExternalScreenOverlayHandler"),
            "a contextual renderer must not disable movement for the same native menu");
    }

    @Test
    void providerBaseFailsClosedAndMovementReadsDedicatedAction() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/MCVR.java");
        Assertions.assertTrue(provider.contains("protected boolean supportsNativeContainerLocomotion()"));
        Assertions.assertTrue(provider.contains("return false;"));
        Assertions.assertTrue(provider.contains("keyContainerMoveStrafe : VivecraftVRMod.INSTANCE.keyFreeMoveStrafe"));
        Assertions.assertTrue(provider.contains(
            "MOD.keyContainerMoveStrafe, \"optional\", \"vector2\", VRInputActionSet.GUI"));
        Assertions.assertTrue(provider.contains(
            "MOD.keyContainerClose, \"optional\", \"boolean\", VRInputActionSet.GUI"));
    }

    @Test
    void closeUsesExactScreenAndMenuWithoutGlobalEscape() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/MCVR.java");
        Assertions.assertTrue(provider.contains("processNativeContainerClose"));
        Assertions.assertTrue(provider.contains("container instanceof InventoryScreen"));
        Assertions.assertTrue(provider.contains("container instanceof CreativeModeInventoryScreen"));
        Assertions.assertTrue(provider.contains("QuestBGuiClosePolicy.isEligible"));
        Assertions.assertTrue(provider.contains("while (MOD.keyContainerClose.consumeClick())"),
            "synthetic clickCount must be drained so it cannot leak into a later GUI");
        Assertions.assertFalse(provider.contains("discreteCloseRequested"),
            "Inventory and Creative must not depend on a suppressible synthetic click edge");
        Assertions.assertTrue(provider.contains("action.isActive()"));
        Assertions.assertTrue(provider.contains("action.isButtonPressed()"));
        Assertions.assertTrue(provider.contains("this.nativeContainerCloseGate.update("),
            "all eligible screens must use the raw-action neutral gate");
        Assertions.assertTrue(provider.contains(
            "ExternalScreenOverlayHandler.isGlobalScreenClaimed(container)"),
            "B must distinguish Wrist-owned inventories from contextual native-container rendering");
        Assertions.assertTrue(provider.contains("this.mc.player.containerMenu == this.mc.player.inventoryMenu"));
        Assertions.assertTrue(provider.contains("this.mc.gui.screen() != container"));
        Assertions.assertTrue(provider.contains("container.getMenu() != menu"));
        Assertions.assertTrue(provider.contains("container.onClose()"));
        Assertions.assertFalse(provider.contains(
            "keyContainerClose.consumeClick() && MOD.keyMenuButton.consumeClick()"),
            "container B must never alias the global Escape/menu action");

        String mod = source("org/vivecraft/client/VivecraftVRMod.java");
        Assertions.assertTrue(mod.contains("keyContainerClose"));
        Assertions.assertTrue(mod.contains("this.hiddenKeyBindingSet.add(this.keyContainerClose)"));
    }

    @Test
    void rightAxisHandoffSurvivesRuntimeSuspension() throws IOException {
        String source = source("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java");
        Assertions.assertTrue(source.contains("this.nativeContainerAxisLatch.suspend()"));
        Assertions.assertTrue(source.contains("this.isAxisNeutral(GuiHandler.KEY_SCROLL_AXIS)"));
        Assertions.assertTrue(source.contains("this.trackpadSwipeSamplers.clear()"));
        Assertions.assertTrue(source.contains("this.nativeContainerWorldAxesSuppressed"));
    }

    private static String source(String relative) throws IOException {
        return Files.readString(MAIN.resolve(relative));
    }
}
