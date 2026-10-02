package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

class ExternalOverlayConsumerContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void noConsumerStillSelectsTheLegacySingletonForRendering() throws IOException {
        List<String> forbidden = List.of(
            "ExternalScreenOverlayHandler.overlay()",
            "ExternalScreenOverlayHandler.framebuffer()",
            "ExternalScreenOverlayHandler.ensureFramebuffer()",
            "ExternalScreenOverlayHandler.destroyFramebuffer()"
        );
        try (var files = Files.walk(MAIN)) {
            for (Path path : files.filter(it -> it.toString().endsWith(".java")).toList()) {
                if (path.getFileName().toString().equals("ExternalScreenOverlayHandler.java")) {
                    continue;
                }
                String source = Files.readString(path);
                for (String oldCall : forbidden) {
                    Assertions.assertFalse(source.contains(oldCall),
                        () -> path + " still uses singular overlay call " + oldCall);
                }
            }
        }
    }

    @Test
    void stereoPathRecordsOnceAndSubmitsEverySnapshottedSurface() throws IOException {
        assertContains("org/vivecraft/client_vr/render/helpers/VRPassHelper.java",
            "ExternalScreenOverlayHandler.render2D();");
        assertContains("org/vivecraft/client_vr/render/renderstates/VRRenderState.java",
            "ExternalScreenOverlayHandler.copyVisibleSurfaces(this.externalScreenOverlays);");
        assertContains("org/vivecraft/client_vr/render/helpers/VREffectsHelper.java",
            "for (ExternalScreenOverlayHandler.OverlayHandle handle : vrState.externalScreenOverlays)");
        assertContains("org/vivecraft/client_vr/provider/VRRenderer.java",
            "ExternalScreenOverlayHandler.ensureFramebuffers();");
        assertContains("org/vivecraft/client_vr/provider/VRRenderer.java",
            "ExternalScreenOverlayHandler.destroyFramebuffers();");
        assertContains("org/vivecraft/client_vr/gameplay/VRPlayer.java",
            "ExternalScreenOverlayHandler.isUsingController(ControllerType.LEFT)");
        assertContains("org/vivecraft/client_vr/gameplay/VRPlayer.java",
            "ExternalScreenOverlayHandler.isUsingController(ControllerType.RIGHT)");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/GuiHandler.java",
            "ExternalScreenOverlayHandler.isUsingController(type)");
        assertContains("org/vivecraft/client_vr/provider/MCVR.java",
            "ExternalScreenOverlayHandler.processBindings();");
        assertContains("org/vivecraft/client_vr/render/renderstates/ArmsRenderState.java",
            "ExternalScreenOverlayHandler.isShowing()");
        assertContains("org/vivecraft/client_vr/gameplay/trackers/BowTracker.java",
            "ExternalScreenOverlayHandler.isUsingController(CONTROLLERS[arrowHand])");
        assertContains("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java",
            "action.isButtonPressed() && action.isEnabled()");
    }

    @Test
    void externalSurfacesNeverBecomeTheGlobalMinecraftGui() throws IOException {
        String handler = Files.readString(MAIN.resolve(
            "org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java"));
        Assertions.assertFalse(handler.contains(".setScreen("));
        Assertions.assertFalse(handler.contains("claim.screen.onClose("));
        Assertions.assertFalse(handler.contains("claim.screen.removed("));
        Assertions.assertFalse(handler.contains("GUI_POS_ROOM ="));
        Assertions.assertFalse(handler.contains("GUI_ROTATION_ROOM ="));
    }

    @Test
    void claimedGlobalScreenHasOneLifecycleOwnerAndOnePointerOwner() throws IOException {
        assertContains("org/vivecraft/mixin/client_vr/gui/GuiVRMixin.java",
            "ExternalScreenOverlayHandler.onGlobalScreenChanging(this.screen, guiScreen);");
        assertContains("org/vivecraft/mixin/client_vr/gui/GuiVRMixin.java",
            "@WrapWithCondition(");
        assertContains("org/vivecraft/mixin/client_vr/gui/GuiVRMixin.java",
            "return !ExternalScreenOverlayHandler.isGlobalScreenClaimed(instance);");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/GuiHandler.java",
            "ExternalScreenOverlayHandler.ownsPointerInput()");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/GuiHandler.java",
            "releaseSimulatedPointerButtons();");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java",
            "processGlobalPointerButton(GuiHandler.KEY_RIGHT_CLICK");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java",
            "processGlobalPointerScroll(GuiHandler.KEY_SCROLL_UP");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java",
            "minecraft.isSameThread()");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java",
            "minecraft.execute(callback)");
    }

    @Test
    void externalSecondaryIsHandedKeyboardOnlyAndDrainsBeforeRawRouting() throws IOException {
        Assertions.assertTrue(Files.readString(Path.of("..", "gradle.properties")).contains(
            "mod_version=1.3.15+qc.v71.rc6.2"),
            "RC6 input bytes must have a distinct Fabric version");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/GuiHandler.java",
            "KEY_EXTERNAL_SECONDARY = new HandedKeyBinding(");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/GuiHandler.java",
            "VivecraftVRMod.INSTANCE.categoryKeyboard");
        assertContains("org/vivecraft/client_vr/gameplay/screenhandlers/GuiHandler.java",
            "ExternalScreenOverlayHandler.isUsingPointerController(type)");
        assertContains("org/vivecraft/client/VivecraftVRMod.java",
            "hiddenKeyBindingSet.add(GuiHandler.KEY_EXTERNAL_SECONDARY)");
        assertContains("org/vivecraft/client_vr/provider/MCVR.java",
            "getInputAction(GuiHandler.KEY_EXTERNAL_SECONDARY).setPriority(50)");
        assertContains("org/vivecraft/client_vr/provider/MCVR.java",
            "addActionParams(map, GuiHandler.KEY_EXTERNAL_SECONDARY, \"suggested\", \"boolean\", null)");

        String handler = Files.readString(MAIN.resolve(
            "org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java"));
        Assertions.assertTrue(handler.contains(
            "while (GuiHandler.KEY_EXTERNAL_SECONDARY.consumeClick(controller))"));
        Assertions.assertTrue(handler.contains("secondaryAction.isActive(controller)"));
        Assertions.assertTrue(handler.contains("secondaryAction.getLastOrigin(controller)"));
        Assertions.assertTrue(handler.contains("secondaryAction.isButtonPressed(controller)"));
        Assertions.assertTrue(handler.contains("PointerButton.SECONDARY"));
        Assertions.assertTrue(handler.contains("PointerSource.HANDED_SECONDARY"));
    }

    @Test
    void questFaceMappingsCoexistWithJumpAndTeleportWithoutGuiActivation() throws IOException {
        String bindings = Files.readString(MAIN.resolve(
            "org/vivecraft/client_vr/provider/openxr/XRBindings.java"));
        Assertions.assertTrue(bindings.contains(
            "\"/actions/keyboard/in/vivecraft.key.externalSecondary\", \"/user/hand/right/input/a/click\""));
        Assertions.assertTrue(bindings.contains(
            "\"/actions/keyboard/in/vivecraft.key.externalSecondary\", \"/user/hand/left/input/x/click\""));
        Assertions.assertTrue(bindings.contains(
            "\"/actions/ingame/in/key.jump\", \"/user/hand/right/input/a/click\""));
        Assertions.assertTrue(bindings.contains(
            "\"/actions/ingame/in/vivecraft.key.teleport\", \"/user/hand/left/input/x/click\""));
        Assertions.assertTrue(bindings.contains(
            "\"/actions/ingame/in/vivecraft.key.teleportFallback\", \"/user/hand/left/input/x/click\""));

        String provider = Files.readString(MAIN.resolve(
            "org/vivecraft/client_vr/provider/openxr/MCOpenXR.java"));
        Assertions.assertFalse(provider.contains(
            "ExternalScreenOverlayHandler.ownsPointerInput()"),
            "Core must not activate the GUI or any action set for external overlays");
    }

    private static void assertContains(String relative, String expected) throws IOException {
        String source = Files.readString(MAIN.resolve(relative));
        Assertions.assertTrue(source.contains(expected), () -> relative + " is missing " + expected);
    }
}
