package org.questcraft.veq.client.config;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.minecraft.client.Minecraft;
import org.joml.Quaternionf;
import org.joml.Quaternionfc;
import org.joml.Vector3f;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.quickactions.QuickActionDefinition;
import org.questcraft.veq.client.quickactions.QuickActionType;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.common.utils.MathUtils;

import java.io.IOException;
import java.io.Reader;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Atomic, client-only settings for the wrist UI. */
public final class WristUiConfig {
    /**
     * Schema 6 makes acquisition follow the final calibrated surface face.
     * Existing per-hand quaternion poses (including Flip Face) are retained;
     * migrating must never force a user to calibrate the panel again.
     */
    public static final int CONFIG_VERSION = 6;
    public static final int ACTION_SLOTS = 12;
    static final float MIN_OPEN_ANGLE_DEGREES = 20.0F;
    static final float MAX_OPEN_ANGLE_DEGREES = 160.0F;
    private static final float DEFAULT_HYSTERESIS_SCORE = 0.10F;
    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create();
    private static WristUiConfig instance;

    private final Path configFile;
    private final Quaternionf quaternionScratch = new Quaternionf();
    private final Vector3f eulerScratch = new Vector3f();
    private StoredConfig values;
    private StoredConfig editSnapshot;
    private long revision;
    private boolean writesEnabled = true;
    private boolean futureVersionReadOnly;

    private WristUiConfig(Path configFile) {
        this.configFile = configFile;
        values = defaults();
        load();
    }

    public static synchronized WristUiConfig getInstance() {
        if (instance == null) {
            Path path = Minecraft.getInstance().gameDirectory.toPath()
                    .resolve("config")
                    .resolve(VivecraftEssentialsQuest.MOD_ID)
                    .resolve("wrist_ui.json");
            instance = new WristUiConfig(path);
        }
        return instance;
    }

    static WristUiConfig forTest(Path path) {
        return new WristUiConfig(path);
    }

    public synchronized long revision() {
        return revision;
    }

    public synchronized boolean enabled() {
        return values.enabled;
    }

    public synchronized WristHand hand() {
        return parseEnum(values.hand, WristHand.class, WristHand.OFF_HAND);
    }

    public synchronized WristActivationMode activationMode() {
        WristActivationMode mode = parseEnum(
                values.activationMode,
                WristActivationMode.class,
                WristActivationMode.VEP_SURFACE_AIM
        );
        return mode == WristActivationMode.VEP_AIM
                ? WristActivationMode.VEP_SURFACE_AIM
                : mode;
    }

    public synchronized float activationSensitivity() {
        return values.activationSensitivity;
    }

    public synchronized PalmAxis palmAxis() {
        return parseEnum(values.palmAxis, PalmAxis.class, PalmAxis.POSITIVE_Y);
    }

    public synchronized float openThreshold() {
        return values.openThreshold;
    }

    public synchronized float openAngleDegrees() {
        return thresholdToAngle(values.openThreshold);
    }

    public synchronized float closeThreshold() {
        return values.closeThreshold;
    }

    public synchronized long openDelayMillis() {
        return values.openDelayMillis;
    }

    public synchronized long closeDelayMillis() {
        return values.closeDelayMillis;
    }

    public synchronized WristPoseProfile pose(ControllerType controller) {
        return storedPose(controller).profile();
    }

    public synchronized WristPoseProfile activePose() {
        return pose(controllerFor(hand()));
    }

    public synchronized boolean frontFaceFlipped(ControllerType controller) {
        return storedPose(controller).frontFaceFlipped;
    }

    /** Compatibility accessors used by existing settings code. */
    public synchronized float scale() {
        return storedPose(controllerFor(hand())).scale;
    }

    public synchronized float offsetX() {
        return storedPose(controllerFor(hand())).offsetX;
    }

    public synchronized float offsetY() {
        return storedPose(controllerFor(hand())).offsetY;
    }

    public synchronized float offsetZ() {
        return storedPose(controllerFor(hand())).offsetZ;
    }

    public synchronized float rotationX() {
        return activeEuler().x;
    }

    public synchronized float rotationY() {
        return activeEuler().y;
    }

    public synchronized float rotationZ() {
        return activeEuler().z;
    }

    public synchronized boolean showPotionEffects() {
        return values.showPotionEffects;
    }

    public synchronized QuickActionDisplayMode quickActionDisplayMode() {
        return parseEnum(values.quickActionDisplayMode, QuickActionDisplayMode.class, QuickActionDisplayMode.SIX);
    }

    public synchronized boolean radialHotbarEnabled() {
        return values.radialHotbarEnabled;
    }

    public synchronized boolean isEditing() {
        return editSnapshot != null;
    }

    public synchronized boolean isFutureVersionReadOnly() {
        return futureVersionReadOnly;
    }

    /** Starts an all-or-nothing settings draft. Nested calls are harmless. */
    public synchronized void beginEditing() {
        if (editSnapshot == null) {
            editSnapshot = copy(values);
        }
    }

    public synchronized void applyEditing() {
        if (editSnapshot == null) {
            return;
        }
        editSnapshot = null;
        revision++;
        save();
    }

    public synchronized void cancelEditing() {
        if (editSnapshot == null) {
            return;
        }
        values = editSnapshot;
        editSnapshot = null;
        revision++;
    }

    public synchronized QuickActionDefinition quickAction(int slot) {
        checkActionSlot(slot);
        StoredAction action = values.actions.get(slot);
        return new QuickActionDefinition(
                parseEnum(action.type, QuickActionType.class, QuickActionType.EMPTY),
                action.displayName,
                action.iconItemId,
                action.value
        );
    }

    public synchronized List<QuickActionDefinition> quickActions() {
        List<QuickActionDefinition> result = new ArrayList<>(ACTION_SLOTS);
        for (int i = 0; i < ACTION_SLOTS; i++) {
            result.add(quickAction(i));
        }
        return List.copyOf(result);
    }

    public synchronized void setEnabled(boolean value) {
        values.enabled = value;
        changed();
    }

    public synchronized void setHand(WristHand value) {
        values.hand = (value == null ? WristHand.OFF_HAND : value).name();
        changed();
    }

    public synchronized void setActivationSensitivity(float value) {
        values.activationSensitivity = clamp(value, 0.0F, 1.0F);
        changed();
    }

    public synchronized void setOpenAngleDegrees(float value) {
        float previousGap = values.openThreshold - values.closeThreshold;
        if (!Float.isFinite(previousGap) || previousGap <= 0.0F) {
            previousGap = DEFAULT_HYSTERESIS_SCORE;
        }
        float openThreshold = angleToThreshold(value);
        values.openThreshold = openThreshold;
        values.closeThreshold = clamp(openThreshold - previousGap, -0.95F, openThreshold);
        changed();
    }

    public synchronized void setPose(
            ControllerType controller,
            Vector3f offset,
            Quaternionfc rotation,
            float scale
    ) {
        StoredPose pose = storedPose(controller);
        pose.offsetX = clamp(offset.x, -0.50F, 0.50F);
        pose.offsetY = clamp(offset.y, -0.50F, 0.50F);
        pose.offsetZ = clamp(offset.z, -0.50F, 0.50F);
        Quaternionf normalized = quaternionScratch.set(rotation);
        if (!finite(normalized) || normalized.lengthSquared() < 1.0E-8F) {
            normalized.identity();
        } else {
            normalized.normalize();
        }
        storeRenderedRotation(pose, normalized);
        pose.scale = clamp(scale, 0.20F, 1.25F);
        pose.invalidateProfile();
        changed();
    }

    public synchronized void setScale(float value) {
        StoredPose pose = storedPose(controllerFor(hand()));
        pose.scale = clamp(value, 0.20F, 1.25F);
        pose.invalidateProfile();
        changed();
    }

    public synchronized void setOffset(float x, float y, float z) {
        StoredPose pose = storedPose(controllerFor(hand()));
        pose.offsetX = clamp(x, -0.50F, 0.50F);
        pose.offsetY = clamp(y, -0.50F, 0.50F);
        pose.offsetZ = clamp(z, -0.50F, 0.50F);
        pose.invalidateProfile();
        changed();
    }

    /** Stores deterministic local {@code Rz * Ry * Rx} composition as a quaternion. */
    public synchronized void setRotation(float x, float y, float z) {
        setRotation(controllerFor(hand()), x, y, z);
    }

    public synchronized void setRotation(ControllerType controller, float x, float y, float z) {
        StoredPose pose = storedPose(controller);
        Quaternionf rotation = quaternionScratch.rotationZYX(
                normalizeRadians(z),
                normalizeRadians(y),
                normalizeRadians(x)
        ).normalize();
        storeRenderedRotation(pose, rotation);
        pose.invalidateProfile();
        changed();
    }

    /** Applies small local-axis quaternion deltas without an Euler round-trip. */
    public synchronized void rotate(float xDelta, float yDelta, float zDelta) {
        StoredPose pose = storedPose(controllerFor(hand()));
        Quaternionf rotation = pose.renderedRotation(quaternionScratch);
        if (Float.isFinite(xDelta) && xDelta != 0.0F) {
            rotation.rotateX(xDelta);
        }
        if (Float.isFinite(yDelta) && yDelta != 0.0F) {
            rotation.rotateY(yDelta);
        }
        if (Float.isFinite(zDelta) && zDelta != 0.0F) {
            rotation.rotateZ(zDelta);
        }
        rotation.normalize();
        storeRenderedRotation(pose, rotation);
        pose.invalidateProfile();
        changed();
    }

    public synchronized void flipFace(ControllerType controller) {
        StoredPose pose = storedPose(controller);
        pose.frontFaceFlipped = !pose.frontFaceFlipped;
        pose.invalidateProfile();
        changed();
    }

    public synchronized void resetPose(ControllerType controller) {
        setStoredPose(controller, defaultPose(controller));
        changed();
    }

    public synchronized void setShowPotionEffects(boolean value) {
        values.showPotionEffects = value;
        changed();
    }

    public synchronized void setQuickActionDisplayMode(QuickActionDisplayMode value) {
        values.quickActionDisplayMode = (value == null ? QuickActionDisplayMode.SIX : value).name();
        changed();
    }

    public synchronized void setRadialHotbarEnabled(boolean value) {
        values.radialHotbarEnabled = value;
        changed();
    }

    public synchronized void setQuickAction(int slot, QuickActionDefinition definition) {
        checkActionSlot(slot);
        QuickActionDefinition safe = definition == null ? QuickActionDefinition.empty() : definition;
        StoredAction stored = new StoredAction();
        stored.type = safe.type().name();
        stored.displayName = safe.displayName();
        stored.iconItemId = safe.iconItemId();
        stored.value = safe.value();
        values.actions.set(slot, stored);
        changed();
    }

    public synchronized void reset() {
        values = defaults();
        changed();
    }

    private Vector3f activeEuler() {
        StoredPose pose = storedPose(controllerFor(hand()));
        return MathUtils.getEulerAnglesZYX(pose.renderedRotation(quaternionScratch), eulerScratch);
    }

    private void changed() {
        revision++;
        if (editSnapshot == null) {
            save();
        }
    }

    private void load() {
        if (!Files.isRegularFile(configFile)) {
            save();
            return;
        }
        try {
            JsonObject raw;
            try (Reader reader = Files.newBufferedReader(configFile, StandardCharsets.UTF_8)) {
                JsonElement element = JsonParser.parseReader(reader);
                raw = element != null && element.isJsonObject() ? element.getAsJsonObject() : null;
            }
            StoredConfig stored = raw == null ? null : GSON.fromJson(raw, StoredConfig.class);
            int storedVersion = readInt(raw, "version", CONFIG_VERSION);
            if (stored != null && storedVersion > 0 && storedVersion < CONFIG_VERSION) {
                writesEnabled = backupLegacyConfigOnce(storedVersion);
            }
            if (stored != null && storedVersion <= 2) {
                StoredPose migrated = legacyPose(raw);
                WristHand migratedHand = parseEnum(stored.hand, WristHand.class, WristHand.OFF_HAND);
                stored.rightPose = defaultPose(ControllerType.RIGHT);
                stored.leftPose = defaultPose(ControllerType.LEFT);
                if (controllerFor(migratedHand) == ControllerType.LEFT) {
                    stored.leftPose = migrated;
                } else {
                    stored.rightPose = migrated;
                }
            }
            if (stored != null && storedVersion == 4) {
                // Retire pointer-only acquisition, but preserve the exact
                // calibrated quaternion/Flip encoded by the user's two poses.
                // Visibility now consumes that final pose instead of resetting
                // it to compensate for an obsolete gesture basis.
                stored.activationMode = WristActivationMode.VEP_SURFACE_AIM.name();
            }
            if (storedVersion > CONFIG_VERSION) {
                futureVersionReadOnly = true;
                writesEnabled = false;
                VivecraftEssentialsQuest.LOGGER.warn(
                        "Reading future wrist config schema {} without rewriting {}",
                        storedVersion,
                        configFile
                );
            }
            values = sanitize(stored);
            if (!futureVersionReadOnly && (stored == null || storedVersion != CONFIG_VERSION)) {
                save();
            }
        } catch (IOException | RuntimeException exception) {
            VivecraftEssentialsQuest.LOGGER.error("Could not load {}", configFile, exception);
        }
    }

    private boolean backupLegacyConfigOnce(int storedVersion) {
        Path backup = configFile.resolveSibling(configFile.getFileName() + ".v" + storedVersion + ".bak");
        if (Files.isRegularFile(backup)) {
            return true;
        }
        if (Files.exists(backup)) {
            VivecraftEssentialsQuest.LOGGER.warn("Wrist config backup target is not a regular file: {}", backup);
            return false;
        }
        try {
            Files.copy(configFile, backup, StandardCopyOption.COPY_ATTRIBUTES);
            return true;
        } catch (IOException exception) {
            try {
                Files.deleteIfExists(backup);
                Files.copy(configFile, backup);
                return true;
            } catch (IOException fallbackException) {
                fallbackException.addSuppressed(exception);
                VivecraftEssentialsQuest.LOGGER.warn(
                        "Could not create one-time wrist config backup {}",
                        backup,
                        fallbackException
                );
                return false;
            }
        }
    }

    private void save() {
        if (!writesEnabled) {
            return;
        }
        Path parent = configFile.getParent();
        Path temporary = configFile.resolveSibling(configFile.getFileName() + ".tmp");
        try {
            Files.createDirectories(parent);
            try (Writer writer = Files.newBufferedWriter(temporary, StandardCharsets.UTF_8)) {
                GSON.toJson(values, writer);
            }
            try {
                Files.move(temporary, configFile, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, configFile, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException exception) {
            VivecraftEssentialsQuest.LOGGER.error("Could not save {}", configFile, exception);
            try {
                Files.deleteIfExists(temporary);
            } catch (IOException ignored) {
                // Preserve the original failure.
            }
        }
    }

    private static StoredConfig sanitize(StoredConfig input) {
        StoredConfig safe = input == null ? defaults() : input;
        int sourceVersion = safe.version;
        safe.version = CONFIG_VERSION;
        safe.hand = parseEnum(safe.hand, WristHand.class, WristHand.OFF_HAND).name();
        WristActivationMode activationMode = parseEnum(
                safe.activationMode,
                WristActivationMode.class,
                WristActivationMode.VEP_SURFACE_AIM
        );
        safe.activationMode = (activationMode == WristActivationMode.VEP_AIM
                ? WristActivationMode.VEP_SURFACE_AIM
                : activationMode).name();
        if (sourceVersion < 2 || !Float.isFinite(safe.activationSensitivity)) {
            safe.activationSensitivity = sensitivityFromLegacyThreshold(safe.openThreshold);
        }
        safe.activationSensitivity = clamp(safe.activationSensitivity, 0.0F, 1.0F);
        safe.palmAxis = parseEnum(safe.palmAxis, PalmAxis.class, PalmAxis.POSITIVE_Y).name();
        safe.openThreshold = clamp(safe.openThreshold, -0.95F, 0.95F);
        safe.closeThreshold = clamp(safe.closeThreshold, -0.95F, safe.openThreshold);
        safe.openDelayMillis = clamp(safe.openDelayMillis, 0L, 1000L);
        if (sourceVersion > 0 && sourceVersion < 6 && safe.closeDelayMillis == 150L) {
            // v6 adopts the VEP close dwell while retaining explicitly tuned
            // non-default values from older documents.
            safe.closeDelayMillis = 200L;
        }
        safe.closeDelayMillis = clamp(safe.closeDelayMillis, 0L, 1000L);
        safe.rightPose = sanitizePose(safe.rightPose, ControllerType.RIGHT);
        safe.leftPose = sanitizePose(safe.leftPose, ControllerType.LEFT);
        safe.quickActionDisplayMode = parseEnum(
                safe.quickActionDisplayMode,
                QuickActionDisplayMode.class,
                QuickActionDisplayMode.SIX
        ).name();
        if (safe.actions == null) {
            safe.actions = new ArrayList<>();
        }
        while (safe.actions.size() < ACTION_SLOTS) {
            safe.actions.add(new StoredAction());
        }
        if (safe.actions.size() > ACTION_SLOTS) {
            safe.actions = new ArrayList<>(safe.actions.subList(0, ACTION_SLOTS));
        }
        for (int i = 0; i < safe.actions.size(); i++) {
            StoredAction action = safe.actions.get(i);
            if (action == null) {
                action = new StoredAction();
                safe.actions.set(i, action);
            }
            QuickActionDefinition normalized = new QuickActionDefinition(
                    parseEnum(action.type, QuickActionType.class, QuickActionType.EMPTY),
                    action.displayName,
                    action.iconItemId,
                    action.value
            );
            action.type = normalized.type().name();
            action.displayName = normalized.displayName();
            action.iconItemId = normalized.iconItemId();
            action.value = normalized.value();
        }
        return safe;
    }

    private static StoredPose sanitizePose(StoredPose input, ControllerType controller) {
        StoredPose pose = input == null ? defaultPose(controller) : input;
        pose.offsetX = clamp(pose.offsetX, -0.50F, 0.50F);
        pose.offsetY = clamp(pose.offsetY, -0.50F, 0.50F);
        pose.offsetZ = clamp(pose.offsetZ, -0.50F, 0.50F);
        Quaternionf rotation = pose.rotation(new Quaternionf());
        if (!finite(rotation) || rotation.lengthSquared() < 1.0E-8F) {
            rotation.identity();
        } else {
            rotation.normalize();
        }
        pose.rotationX = rotation.x;
        pose.rotationY = rotation.y;
        pose.rotationZ = rotation.z;
        pose.rotationW = rotation.w;
        pose.scale = clamp(pose.scale, 0.20F, 1.25F);
        pose.invalidateProfile();
        return pose;
    }

    /** Stores a rendered/local pose without baking the independent face flag twice. */
    private static void storeRenderedRotation(StoredPose pose, Quaternionf renderedRotation) {
        renderedRotation.normalize();
        if (pose.frontFaceFlipped) {
            renderedRotation.rotateY((float) -Math.PI).normalize();
        }
        pose.rotationX = renderedRotation.x;
        pose.rotationY = renderedRotation.y;
        pose.rotationZ = renderedRotation.z;
        pose.rotationW = renderedRotation.w;
    }

    private static StoredConfig defaults() {
        StoredConfig config = new StoredConfig();
        config.version = CONFIG_VERSION;
        config.enabled = true;
        config.hand = WristHand.OFF_HAND.name();
        config.activationMode = WristActivationMode.VEP_SURFACE_AIM.name();
        config.activationSensitivity = 0.55F;
        config.palmAxis = PalmAxis.POSITIVE_Y.name();
        config.openThreshold = 0.20F;
        config.closeThreshold = 0.10F;
        config.openDelayMillis = 150L;
        config.closeDelayMillis = 200L;
        config.rightPose = defaultPose(ControllerType.RIGHT);
        config.leftPose = defaultPose(ControllerType.LEFT);
        config.showPotionEffects = true;
        config.quickActionDisplayMode = QuickActionDisplayMode.SIX.name();
        config.radialHotbarEnabled = true;
        config.actions = new ArrayList<>(ACTION_SLOTS);
        for (int i = 0; i < ACTION_SLOTS; i++) {
            config.actions.add(new StoredAction());
        }
        StoredAction map = config.actions.get(0);
        map.type = QuickActionType.KEYBIND.name();
        map.displayName = "World Map";
        map.iconItemId = "minecraft:filled_map";
        map.value = "key.xaero_open_map";
        return config;
    }

    private static StoredPose defaultPose(ControllerType controller) {
        Quaternionf rotation = new Quaternionf().rotationZYX(
                (float) Math.PI,
                (float) (Math.PI / 2.0),
                0.0F
        );
        StoredPose pose = new StoredPose();
        pose.offsetX = -0.07F;
        pose.offsetY = -0.081F;
        pose.offsetZ = 0.20F;
        pose.rotationX = rotation.x;
        pose.rotationY = rotation.y;
        pose.rotationZ = rotation.z;
        pose.rotationW = rotation.w;
        pose.scale = 0.50F;
        if (controller == ControllerType.RIGHT) {
            // Mirror the proven left/off-hand default across controller-local
            // YZ. M*R*M maps quaternion (x,y,z,w) to (x,-y,-z,w).
            pose.offsetX = -pose.offsetX;
            pose.rotationY = -pose.rotationY;
            pose.rotationZ = -pose.rotationZ;
        }
        return pose;
    }

    private static StoredPose legacyPose(JsonObject raw) {
        StoredPose pose = new StoredPose();
        pose.offsetX = readFloat(raw, "offsetX", -0.07F);
        pose.offsetY = readFloat(raw, "offsetY", -0.081F);
        pose.offsetZ = readFloat(raw, "offsetZ", 0.20F);
        float x = readFloat(raw, "rotationX", 0.0F);
        float y = readFloat(raw, "rotationY", (float) (Math.PI / 2.0));
        float z = readFloat(raw, "rotationZ", (float) Math.PI);
        // Schema 2 was evaluated by Matrix4f.rotateX().rotateY().rotateZ(),
        // i.e. Rx * Ry * Rz. Preserve that exact effective orientation while
        // schema 3 and its editor use the new deterministic Rz * Ry * Rx form.
        Quaternionf rotation = new Quaternionf().rotationXYZ(x, y, z).normalize();
        pose.rotationX = rotation.x;
        pose.rotationY = rotation.y;
        pose.rotationZ = rotation.z;
        pose.rotationW = rotation.w;
        pose.scale = readFloat(raw, "scale", 0.50F);
        return sanitizePose(pose, ControllerType.LEFT);
    }

    private StoredPose storedPose(ControllerType controller) {
        return controller == ControllerType.LEFT ? values.leftPose : values.rightPose;
    }

    private void setStoredPose(ControllerType controller, StoredPose pose) {
        pose.invalidateProfile();
        if (controller == ControllerType.LEFT) {
            values.leftPose = pose;
        } else {
            values.rightPose = pose;
        }
    }

    private static ControllerType controllerFor(WristHand hand) {
        return hand == WristHand.OFF_HAND ? ControllerType.LEFT : ControllerType.RIGHT;
    }

    private static StoredConfig copy(StoredConfig source) {
        return GSON.fromJson(GSON.toJson(source), StoredConfig.class);
    }

    private static int readInt(JsonObject object, String key, int fallback) {
        try {
            return object != null && object.has(key) ? object.get(key).getAsInt() : fallback;
        } catch (RuntimeException ignored) {
            return fallback;
        }
    }

    private static float readFloat(JsonObject object, String key, float fallback) {
        try {
            return object != null && object.has(key) ? object.get(key).getAsFloat() : fallback;
        } catch (RuntimeException ignored) {
            return fallback;
        }
    }

    private static <T extends Enum<T>> T parseEnum(String raw, Class<T> type, T fallback) {
        if (raw != null) {
            try {
                return Enum.valueOf(type, raw.toUpperCase(Locale.ROOT));
            } catch (IllegalArgumentException ignored) {
                // Use fallback.
            }
        }
        return fallback;
    }

    private static boolean finite(Quaternionfc value) {
        return Float.isFinite(value.x()) && Float.isFinite(value.y())
                && Float.isFinite(value.z()) && Float.isFinite(value.w());
    }

    private static float clamp(float value, float minimum, float maximum) {
        if (!Float.isFinite(value)) {
            return minimum;
        }
        return Math.max(minimum, Math.min(maximum, value));
    }

    private static long clamp(long value, long minimum, long maximum) {
        return Math.max(minimum, Math.min(maximum, value));
    }

    private static float normalizeRadians(float value) {
        if (!Float.isFinite(value)) {
            return 0.0F;
        }
        float twoPi = (float) (Math.PI * 2.0);
        float normalized = value % twoPi;
        return normalized > Math.PI ? normalized - twoPi : normalized < -Math.PI ? normalized + twoPi : normalized;
    }

    static float angleToThreshold(float angleDegrees) {
        float normalized = clamp(angleDegrees, MIN_OPEN_ANGLE_DEGREES, MAX_OPEN_ANGLE_DEGREES);
        return (float) Math.cos(Math.toRadians(normalized));
    }

    static float thresholdToAngle(float threshold) {
        float normalized = clamp(threshold, -0.95F, 0.95F);
        return (float) Math.toDegrees(Math.acos(normalized));
    }

    static float sensitivityFromLegacyThreshold(float threshold) {
        float angle = thresholdToAngle(threshold);
        return clamp((angle - 35.0F) / 85.0F, 0.0F, 1.0F);
    }

    private static void checkActionSlot(int slot) {
        if (slot < 0 || slot >= ACTION_SLOTS) {
            throw new IndexOutOfBoundsException("Quick-action slot " + slot);
        }
    }

    private static final class StoredConfig {
        private int version;
        private boolean enabled;
        private String hand;
        private String activationMode;
        private float activationSensitivity;
        private String palmAxis;
        private float openThreshold;
        private float closeThreshold;
        private long openDelayMillis;
        private long closeDelayMillis;
        private StoredPose rightPose;
        private StoredPose leftPose;
        private boolean showPotionEffects;
        private String quickActionDisplayMode;
        private boolean radialHotbarEnabled;
        private List<StoredAction> actions;
    }

    private static final class StoredPose {
        private float offsetX;
        private float offsetY;
        private float offsetZ;
        private float rotationX;
        private float rotationY;
        private float rotationZ;
        private float rotationW = 1.0F;
        private boolean frontFaceFlipped;
        private float scale;
        private transient WristPoseProfile cachedProfile;

        private Quaternionf rotation(Quaternionf destination) {
            return destination.set(rotationX, rotationY, rotationZ, rotationW);
        }

        private Quaternionf renderedRotation(Quaternionf destination) {
            rotation(destination).normalize();
            if (frontFaceFlipped) {
                destination.rotateY((float) Math.PI);
            }
            return destination;
        }

        private WristPoseProfile profile() {
            if (cachedProfile == null) {
                cachedProfile = new WristPoseProfile(
                        offsetX, offsetY, offsetZ,
                        rotationX, rotationY, rotationZ, rotationW,
                        frontFaceFlipped,
                        scale
                );
            }
            return cachedProfile;
        }

        private void invalidateProfile() {
            cachedProfile = null;
        }

        private StoredPose copy() {
            StoredPose copy = new StoredPose();
            copy.offsetX = offsetX;
            copy.offsetY = offsetY;
            copy.offsetZ = offsetZ;
            copy.rotationX = rotationX;
            copy.rotationY = rotationY;
            copy.rotationZ = rotationZ;
            copy.rotationW = rotationW;
            copy.frontFaceFlipped = frontFaceFlipped;
            copy.scale = scale;
            return copy;
        }
    }

    private static final class StoredAction {
        private String type = QuickActionType.EMPTY.name();
        private String displayName = "";
        private String iconItemId = "";
        private String value = "";
    }
}
