package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/** Guards the player-relative container pose captured when a native menu opens. */
class NativeContainerFollowPlacementContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void nativeMenusUseTheOrdinaryPlayerRelativeGuiPlane() throws IOException {
        String gui = source("org/vivecraft/client_vr/gameplay/screenhandlers/GuiHandler.java");
        Assertions.assertFalse(gui.contains("WorldContainerGuiAnchor"));
        Assertions.assertFalse(gui.contains("MC.hitResult"),
            "container placement must not remain attached to the opening target");
        Assertions.assertTrue(gui.contains("ordinary room-relative plane"));
        Assertions.assertTrue(gui.contains("GUI_POS_ROOM = new Vector3f("));
        Assertions.assertTrue(gui.contains(
            "VRPlayer.roomToWorldPos(GUI_POS_ROOM, DH.vrPlayer.vrdata_world_render)"),
            "the room-space plane must travel with the player's interpolated world origin");

        Assertions.assertFalse(gui.contains("NativeContainerGuiFollow"));
        Assertions.assertFalse(gui.contains("updateNativeContainerGuiFollow"));
        Assertions.assertTrue(gui.contains(
            "Capture the pose once\n            // when the screen opens"));

        int processGui = gui.indexOf("public static void processGui()");
        int pointer = gui.indexOf("processGuiPointer();", processGui);
        int nextMethod = gui.indexOf("private static void processGuiPointer()", processGui);
        Assertions.assertTrue(processGui >= 0 && pointer > processGui && nextMethod > pointer);
        String processGuiBody = gui.substring(processGui, nextMethod);
        Assertions.assertFalse(processGuiBody.contains("hmd"),
            "turning the HMD must not republish a container GUI pose each frame");

        int openPlacement = gui.indexOf("if ((newScreen != null");
        int openPosition = gui.indexOf("GUI_POS_ROOM = new Vector3f(", openPlacement);
        int openRotation = gui.indexOf("GUI_ROTATION_ROOM = new Matrix4f().rotationY(yaw);", openPosition);
        Assertions.assertTrue(openPlacement >= 0 && openPosition > openPlacement && openRotation > openPosition,
            "the native GUI pose must be captured atomically when its screen opens");

        String player = source("org/vivecraft/client_vr/gameplay/VRPlayer.java");
        Assertions.assertFalse(player.contains("refreshWorldContainerAnchorForRenderFrame"));
    }

    @Test
    void interactionAndPacketsNoLongerCreateWorldAnchorState() throws IOException {
        String gameMode = source(
            "org/vivecraft/mixin/client_vr/multiplayer/MultiPlayerGameModeVRMixin.java");
        Assertions.assertFalse(gameMode.contains("rememberBlockInteraction("));
        Assertions.assertFalse(gameMode.contains("rememberEntityInteraction("));

        String packets = source(
            "org/vivecraft/mixin/client_vr/multiplayer/ClientPacketListenerVRMixin.java");
        Assertions.assertFalse(packets.contains("expectOpenScreen("));
        Assertions.assertFalse(packets.contains("expectMountScreen("));

        Assertions.assertFalse(resource("fabric", "vivecraft.fabric.mixins.json")
            .contains("FabricClientNetworkingVRMixin"));
        Assertions.assertFalse(resource("forge", "vivecraft.forge.mixins.json")
            .contains("ForgeOpenContainerVRMixin"));
        Assertions.assertFalse(resource("neoforge", "vivecraft.neoforge.mixins.json")
            .contains("NeoForgeOpenContainerVRMixin"));
    }

    @Test
    void locomotionDependsOnTheExactNativeMenuNotItsRenderer() throws IOException {
        String locomotion = source(
            "org/vivecraft/client_vr/gameplay/screenhandlers/NativeContainerLocomotion.java");
        Assertions.assertTrue(locomotion.contains(
            "screen instanceof AbstractContainerScreen<?> container"));
        Assertions.assertTrue(locomotion.contains(
            "player.containerMenu == container.getMenu()"));
        Assertions.assertTrue(locomotion.contains(
            "player.inventoryMenu != container.getMenu()"));
        Assertions.assertTrue(locomotion.contains("screen instanceof InventoryScreen"));
        Assertions.assertTrue(locomotion.contains("screen instanceof CreativeModeInventoryScreen"));
        Assertions.assertFalse(locomotion.contains("WorldContainerGuiAnchor"));
        Assertions.assertFalse(locomotion.contains("ExternalScreenOverlayHandler"),
            "a rendering claim must not disable native-container locomotion");
    }

    private static String source(String relative) throws IOException {
        return normalizeNewlines(Files.readString(MAIN.resolve(relative)));
    }

    private static String resource(String module, String name) throws IOException {
        Path sibling = Path.of("..", module, "src", "main", "resources", name);
        if (Files.isRegularFile(sibling)) {
            return normalizeNewlines(Files.readString(sibling));
        }
        Path root = Path.of(module, "src", "main", "resources", name);
        if (Files.isRegularFile(root)) {
            return normalizeNewlines(Files.readString(root));
        }
        return normalizeNewlines(Files.readString(Path.of("Vivecraft-26.2-Quest").resolve(root)));
    }

    private static String normalizeNewlines(String value) {
        return value.replace("\r\n", "\n");
    }
}
