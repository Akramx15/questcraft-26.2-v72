package org.questcraft.veq.client.config;

import org.vivecraft.client_vr.provider.ControllerType;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class GripHotbarConfigSelfTest {
    private GripHotbarConfigSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("veq-grip-config-");
        Path file = directory.resolve("grip_hotbar.json");
        try {
            GripHotbarConfig config = GripHotbarConfig.forTest(file);
            GripHotbarProfile rightDefault = config.profile(ControllerType.RIGHT);
            GripHotbarProfile leftDefault = config.profile(ControllerType.LEFT);
            require(rightDefault.equals(leftDefault), "hands start from equal but independent defaults");

            GripHotbarProfile right = new GripHotbarProfile(0.30F, 0.70F, 1.35F);
            config.setProfile(ControllerType.RIGHT, right);
            require(config.profile(ControllerType.RIGHT).equals(right), "right profile updates");
            require(config.profile(ControllerType.LEFT).equals(leftDefault),
                    "right edit cannot mutate left profile");

            GripHotbarConfig reloaded = GripHotbarConfig.forTest(file);
            require(reloaded.profile(ControllerType.RIGHT).equals(right),
                    "right profile survives a cold reload");
            require(reloaded.profile(ControllerType.LEFT).equals(leftDefault),
                    "left profile survives a cold reload");

            Files.writeString(file, """
                    {
                      "version": 1,
                      "right": {"scale": 0.14666667, "distance": 0.35, "sensitivity": 0.75},
                      "left": {"scale": 0.30, "distance": 0.70, "sensitivity": 1.80}
                    }
                    """, StandardCharsets.UTF_8);
            String versionOneSource = Files.readString(file, StandardCharsets.UTF_8);
            GripHotbarConfig migrated = GripHotbarConfig.forTest(file);
            require(migrated.profile(ControllerType.RIGHT).equals(
                            new GripHotbarProfile(
                                    GripHotbarConfig.DEFAULT_SCALE,
                                    GripHotbarConfig.DEFAULT_DISTANCE,
                                    0.75F)),
                    "version 1 default right presentation migrates to readable defaults");
            require(migrated.profile(ControllerType.LEFT).equals(
                            new GripHotbarProfile(0.30F, 0.70F, 1.80F)),
                    "version 1 custom left presentation remains independent");
            require(Files.readString(file, StandardCharsets.UTF_8).contains("\"version\": 2"),
                    "version 1 migration persists exactly once");
            Path backup = file.resolveSibling(file.getFileName() + ".v1.bak");
            require(Files.readString(backup, StandardCharsets.UTF_8).equals(versionOneSource),
                    "version 1 source is preserved before migration");
            GripHotbarConfig migratedReload = GripHotbarConfig.forTest(file);
            require(migratedReload.profile(ControllerType.RIGHT).equals(
                            migrated.profile(ControllerType.RIGHT)) &&
                            migratedReload.profile(ControllerType.LEFT).equals(
                                    migrated.profile(ControllerType.LEFT)),
                    "cold reload does not reapply version 1 migration");

            Path tinyFile = directory.resolve("grip_hotbar_tiny.json");
            Files.writeString(tinyFile, """
                    {
                      "version": 1,
                      "right": {"scale": 0.10, "distance": 1.25, "sensitivity": 1.25},
                      "left": {"scale": 0.45, "distance": 0.25, "sensitivity": 1.50}
                    }
                    """, StandardCharsets.UTF_8);
            GripHotbarConfig tinyMigrated = GripHotbarConfig.forTest(tinyFile);
            require(tinyMigrated.profile(ControllerType.RIGHT).equals(
                            new GripHotbarProfile(
                                    GripHotbarConfig.DEFAULT_SCALE,
                                    GripHotbarConfig.DEFAULT_DISTANCE,
                                    1.25F)),
                    "pathologically tiny version 1 profile migrates safely");
            require(tinyMigrated.profile(ControllerType.LEFT).equals(
                            new GripHotbarProfile(0.45F, 0.25F, 1.50F)),
                    "large version 1 profile is not overwritten");
            Files.deleteIfExists(tinyFile.resolveSibling(tinyFile.getFileName() + ".v1.bak"));
            Files.deleteIfExists(tinyFile);

            Files.writeString(file, """
                    {
                      "version": 2,
                      "right": {"scale": 9.0, "distance": -1.0, "sensitivity": 0.1},
                      "left": {"scale": "NaN", "distance": 0.8, "sensitivity": 9.0}
                    }
                    """, StandardCharsets.UTF_8);
            GripHotbarConfig sanitized = GripHotbarConfig.forTest(file);
            require(sanitized.profile(ControllerType.RIGHT).equals(
                            new GripHotbarProfile(0.45F, 0.25F, 0.50F)),
                    "unsafe version 2 right values clamp to documented limits");
            GripHotbarProfile safeLeft = sanitized.profile(ControllerType.LEFT);
            require(safeLeft.scale() == GripHotbarConfig.DEFAULT_SCALE,
                    "non-finite version 2 left scale falls back safely");
            require(safeLeft.distance() == 0.8F && safeLeft.sensitivity() == 2.0F,
                    "valid version 2 left distance survives while sensitivity clamps");

            Path futureFile = directory.resolve("grip_hotbar_future.json");
            String futureSource = """
                    {
                      "version": 99,
                      "futureField": {"keep": true},
                      "right": {"scale": 0.31, "distance": 0.41, "sensitivity": 1.10},
                      "left": {"scale": 0.32, "distance": 0.42, "sensitivity": 1.20}
                    }
                    """;
            Files.writeString(futureFile, futureSource, StandardCharsets.UTF_8);
            GripHotbarConfig future = GripHotbarConfig.forTest(futureFile);
            require(future.isFutureVersionReadOnly(),
                    "future config is read-only");
            future.setProfile(ControllerType.RIGHT, new GripHotbarProfile(0.40F, 0.30F, 1.0F));
            require(Files.readString(futureFile, StandardCharsets.UTF_8).equals(futureSource),
                    "future config and unknown fields remain byte-identical");
            Files.deleteIfExists(futureFile);
        } finally {
            Files.deleteIfExists(directory.resolve("grip_hotbar_future.json"));
            Files.deleteIfExists(directory.resolve("grip_hotbar_tiny.json.v1.bak"));
            Files.deleteIfExists(directory.resolve("grip_hotbar_tiny.json.tmp"));
            Files.deleteIfExists(directory.resolve("grip_hotbar_tiny.json"));
            Files.deleteIfExists(file.resolveSibling(file.getFileName() + ".tmp"));
            Files.deleteIfExists(file.resolveSibling(file.getFileName() + ".v1.bak"));
            Files.deleteIfExists(file);
            Files.deleteIfExists(directory);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
