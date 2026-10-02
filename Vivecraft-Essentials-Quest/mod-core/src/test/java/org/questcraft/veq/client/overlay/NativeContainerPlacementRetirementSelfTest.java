package org.questcraft.veq.client.overlay;

import java.nio.file.Files;
import java.nio.file.Path;

/** Host-only guard against restoring a second container pose/lifetime owner. */
public final class NativeContainerPlacementRetirementSelfTest {
    private NativeContainerPlacementRetirementSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        String legacy = Files.readString(sourcePath(
                "src/main/java/org/vmstudio/essentials/core/client/gui/"
                        + "NativeContainerPlacement.java"
        ));
        require(!legacy.contains("MAX_CONTAINER_DISTANCE"),
                "legacy VEQ must not own a client distance limit");
        require(!legacy.contains(".closeContainer("),
                "legacy VEQ must never close a server-owned container");
        require(legacy.contains("return false;"),
                "legacy compatibility hooks must fail closed");

        String activeRuntime = Files.readString(sourcePath(
                "src/main/java/org/questcraft/veq/client/overlay/"
                        + "VepContextualContainerRuntime.java"
        ));
        require(!activeRuntime.contains("NativeContainerPlacement"),
                "active VEQ must not call the retired Visor pose owner");
        require(activeRuntime.contains("GuiHandler.GUI_POS_ROOM")
                        && activeRuntime.contains("GuiHandler.GUI_ROTATION_ROOM")
                        && activeRuntime.contains("GuiHandler.GUI_SCALE"),
                "active VEQ must consume Vivecraft's ordinary player-relative GUI pose");

        System.out.println("NativeContainerPlacementRetirementSelfTest PASS");
    }

    private static Path sourcePath(String relative) {
        Path direct = Path.of(relative);
        if (Files.isRegularFile(direct)) {
            return direct;
        }
        Path fromRoot = Path.of("Vivecraft-Essentials-Quest", "mod-core")
                .resolve(relative);
        if (Files.isRegularFile(fromRoot)) {
            return fromRoot;
        }
        throw new IllegalStateException("Could not locate source contract: " + relative);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
