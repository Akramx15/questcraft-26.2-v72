package org.questcraft.veq.client.config;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import net.minecraft.client.Minecraft;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.vivecraft.client_vr.provider.ControllerType;

import java.io.IOException;
import java.io.Reader;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * Small, independent config for the two-surface Grip selector.
 *
 * <p>Controller values are logical (RIGHT/main and LEFT/offhand), so changing
 * Vivecraft's reverse-hands option never rewrites or swaps this file.</p>
 */
public final class GripHotbarConfig {
    public static final int CONFIG_VERSION = 2;
    /** RenderHelper emits a 1.5-wide quad before applying the surface scale. */
    public static final float QUAD_BASE_WIDTH = 1.5F;
    /**
     * A 40 cm panel at 30 cm from the opening controller is a conservative
     * midpoint toward the readable Visor selector. The old 22 cm / 35 cm
     * profile was visibly too small in the Quest capture. The panel is
     * controller-anchored, so its real HMD distance also includes the user's
     * arm/controller offset and is appreciably greater than 30 cm.
     */
    public static final float DEFAULT_PHYSICAL_WIDTH = 0.40F;
    public static final float DEFAULT_SCALE = DEFAULT_PHYSICAL_WIDTH / QUAD_BASE_WIDTH;
    public static final float DEFAULT_DISTANCE = 0.30F;
    public static final float DEFAULT_SENSITIVITY = 1.0F;

    private static final float V1_DEFAULT_SCALE = 0.22F / QUAD_BASE_WIDTH;
    private static final float V1_DEFAULT_DISTANCE = 0.35F;
    private static final float V1_MAX_UNREADABLE_WIDTH_DISTANCE_RATIO = 0.22F / 0.35F;
    private static final float MIGRATION_EPSILON = 1.0E-4F;

    private static final Gson GSON = new GsonBuilder()
            .setPrettyPrinting()
            .disableHtmlEscaping()
            .create();
    private static GripHotbarConfig instance;

    private final Path configFile;
    private StoredConfig values = defaults();
    private boolean futureVersionReadOnly;

    private GripHotbarConfig(Path configFile) {
        this.configFile = configFile;
        load();
    }

    public static synchronized GripHotbarConfig getInstance() {
        if (instance == null) {
            instance = new GripHotbarConfig(
                    Minecraft.getInstance().gameDirectory.toPath()
                            .resolve("config")
                            .resolve(VivecraftEssentialsQuest.MOD_ID)
                            .resolve("grip_hotbar.json")
            );
        }
        return instance;
    }

    static GripHotbarConfig forTest(Path path) {
        return new GripHotbarConfig(path);
    }

    public synchronized GripHotbarProfile profile(ControllerType controller) {
        StoredProfile profile = controller == ControllerType.LEFT ? values.left : values.right;
        return new GripHotbarProfile(profile.scale, profile.distance, profile.sensitivity);
    }

    public synchronized boolean isFutureVersionReadOnly() {
        return futureVersionReadOnly;
    }

    public synchronized void setProfile(ControllerType controller, GripHotbarProfile profile) {
        if (futureVersionReadOnly || controller == null || profile == null) {
            return;
        }
        StoredProfile stored = sanitize(profile);
        if (controller == ControllerType.LEFT) {
            values.left = stored;
        } else {
            values.right = stored;
        }
        save();
    }

    private void load() {
        futureVersionReadOnly = false;
        if (!Files.isRegularFile(configFile)) {
            save();
            return;
        }
        boolean rewrite = false;
        try (Reader reader = Files.newBufferedReader(configFile, StandardCharsets.UTF_8)) {
            StoredConfig stored = GSON.fromJson(reader, StoredConfig.class);
            if (stored == null) {
                rewrite = true;
            } else {
                int storedVersion = stored.version;
                boolean migrationSafe = true;
                futureVersionReadOnly = stored.version > CONFIG_VERSION;
                values.version = futureVersionReadOnly ? stored.version : CONFIG_VERSION;
                values.right = sanitize(stored.right);
                values.left = sanitize(stored.left);
                if (!futureVersionReadOnly && storedVersion < 2) {
                    // Version 1 shipped the unreadable 22 cm / 35 cm
                    // presentation. Migrate only that old default (or a
                    // clearly smaller angular profile); preserve deliberate
                    // per-hand manual edits and pointer sensitivity.
                    migrationSafe = backupV1Config();
                    if (migrationSafe) {
                        values.right = migrateV1Presentation(values.right);
                        values.left = migrateV1Presentation(values.left);
                    }
                }
                rewrite = !futureVersionReadOnly && storedVersion != CONFIG_VERSION && migrationSafe;
            }
        } catch (Exception exception) {
            VivecraftEssentialsQuest.LOGGER.warn("Could not read Grip hotbar config", exception);
            values = defaults();
            rewrite = true;
        }
        if (rewrite) {
            save();
        }
    }

    private boolean backupV1Config() {
        Path backup = configFile.resolveSibling(configFile.getFileName() + ".v1.bak");
        if (Files.exists(backup)) {
            return true;
        }
        try {
            // Plain copy is intentionally used: Android/Pojlib filesystems may
            // reject COPY_ATTRIBUTES even when ordinary file copying works.
            Files.copy(configFile, backup);
            return true;
        } catch (IOException exception) {
            VivecraftEssentialsQuest.LOGGER.warn("Could not back up version 1 Grip hotbar config", exception);
            return false;
        }
    }

    private void save() {
        if (futureVersionReadOnly) {
            return;
        }
        Path temporary = configFile.resolveSibling(configFile.getFileName() + ".tmp");
        try {
            Files.createDirectories(configFile.getParent());
            values.version = CONFIG_VERSION;
            try (Writer writer = Files.newBufferedWriter(temporary, StandardCharsets.UTF_8)) {
                GSON.toJson(values, writer);
            }
            try {
                Files.move(temporary, configFile,
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, configFile, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException exception) {
            VivecraftEssentialsQuest.LOGGER.warn("Could not save Grip hotbar config", exception);
            try {
                Files.deleteIfExists(temporary);
            } catch (IOException ignored) {
                // The original config remains intact.
            }
        }
    }

    private static StoredConfig defaults() {
        StoredConfig config = new StoredConfig();
        config.version = CONFIG_VERSION;
        config.right = defaultProfile();
        config.left = defaultProfile();
        return config;
    }

    private static StoredProfile defaultProfile() {
        StoredProfile profile = new StoredProfile();
        profile.scale = DEFAULT_SCALE;
        profile.distance = DEFAULT_DISTANCE;
        profile.sensitivity = DEFAULT_SENSITIVITY;
        return profile;
    }

    private static StoredProfile sanitize(GripHotbarProfile profile) {
        StoredProfile stored = new StoredProfile();
        stored.scale = profile.scale();
        stored.distance = profile.distance();
        stored.sensitivity = profile.sensitivity();
        return sanitize(stored);
    }

    private static StoredProfile migrateV1Presentation(StoredProfile previous) {
        float physicalWidth = previous.scale * QUAD_BASE_WIDTH;
        boolean oldDefault = Math.abs(previous.scale - V1_DEFAULT_SCALE) <= MIGRATION_EPSILON &&
                Math.abs(previous.distance - V1_DEFAULT_DISTANCE) <= MIGRATION_EPSILON;
        boolean pathologicallySmall = physicalWidth / previous.distance <=
                V1_MAX_UNREADABLE_WIDTH_DISTANCE_RATIO + MIGRATION_EPSILON;
        if (!oldDefault && !pathologicallySmall) {
            return previous;
        }
        StoredProfile migrated = defaultProfile();
        migrated.sensitivity = previous.sensitivity;
        return migrated;
    }

    private static StoredProfile sanitize(StoredProfile input) {
        StoredProfile safe = input == null ? defaultProfile() : input;
        safe.scale = finiteClamp(safe.scale, 0.10F, 0.45F, DEFAULT_SCALE);
        safe.distance = finiteClamp(safe.distance, 0.25F, 1.25F, DEFAULT_DISTANCE);
        safe.sensitivity = finiteClamp(safe.sensitivity, 0.50F, 2.00F, DEFAULT_SENSITIVITY);
        return safe;
    }

    private static float finiteClamp(float value, float minimum, float maximum, float fallback) {
        return Float.isFinite(value) ? Math.max(minimum, Math.min(maximum, value)) : fallback;
    }

    private static final class StoredConfig {
        private int version;
        private StoredProfile right;
        private StoredProfile left;
    }

    private static final class StoredProfile {
        private float scale;
        private float distance;
        private float sensitivity;
    }
}
