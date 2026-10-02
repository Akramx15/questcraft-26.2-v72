package org.questcraft.veq.client.config;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import net.minecraft.client.Minecraft;
import org.questcraft.veq.VivecraftEssentialsQuest;

import java.io.IOException;
import java.io.Reader;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.EnumMap;
import java.util.Locale;

/**
 * Feature-only VEP settings. Wrist pose and gesture state remain in the
 * existing {@link WristUiConfig}; shortcut definitions live in
 * {@code quick_actions.json}.
 */
public final class VepFeatureConfig {
    public static final int CONFIG_VERSION = 3;

    private static final Gson GSON = new GsonBuilder()
            .setPrettyPrinting()
            .disableHtmlEscaping()
            .create();
    private static VepFeatureConfig instance;

    private final Path configFile;
    private final EnumMap<StatusMetric, Boolean> statusVisibility =
            new EnumMap<>(StatusMetric.class);
    private final EnumMap<StatusMetric, StatusPosition> statusPositions =
            new EnumMap<>(StatusMetric.class);
    private QuickActionDisplayMode quickActionDisplayMode = QuickActionDisplayMode.SIX;
    private boolean showPotionEffects = true;
    private boolean showStatusHud = true;
    private boolean showPlayerPreview;
    private boolean creativeWrist = true;
    private boolean contextualContainers = false;
    private boolean xaeroIntegration = true;
    private boolean jeiIntegration = true;
    private boolean inventoryProfilesIntegration = true;
    private long revision;
    private boolean futureVersionReadOnly;
    private boolean editing;
    private boolean editingDirty;
    private FeatureState editBackup;

    private VepFeatureConfig(Path configFile, boolean migrateLegacy) {
        this.configFile = configFile;
        resetInMemory();
        load(migrateLegacy);
    }

    public static synchronized VepFeatureConfig getInstance() {
        if (instance == null) {
            instance = new VepFeatureConfig(
                    Minecraft.getInstance().gameDirectory.toPath()
                            .resolve("config")
                            .resolve(VivecraftEssentialsQuest.MOD_ID)
                            .resolve("wrist_features.json"),
                    true
            );
        }
        return instance;
    }

    static VepFeatureConfig forTest(Path configFile) {
        return new VepFeatureConfig(configFile, false);
    }

    public synchronized long revision() {
        return revision;
    }

    /**
     * A newer schema is readable on a best-effort basis but must never be
     * rewritten by this older build. Unknown fields therefore remain intact.
     */
    public synchronized boolean isFutureVersionReadOnly() {
        return futureVersionReadOnly;
    }

    /** Starts one live-preview transaction shared by every feature control. */
    public synchronized void beginEditing() {
        if (futureVersionReadOnly || editing) {
            return;
        }
        editBackup = snapshot();
        editing = true;
        editingDirty = false;
    }

    /** Persists all draft feature changes atomically when the screen applies. */
    public synchronized void applyEditing() {
        if (futureVersionReadOnly || !editing) {
            return;
        }
        editing = false;
        editBackup = null;
        boolean shouldSave = editingDirty;
        editingDirty = false;
        if (shouldSave) {
            save();
        }
    }

    /** Restores the exact in-memory feature state present when editing began. */
    public synchronized void cancelEditing() {
        if (!editing) {
            return;
        }
        boolean shouldNotify = editingDirty;
        restore(editBackup);
        editing = false;
        editingDirty = false;
        editBackup = null;
        if (shouldNotify) {
            revision++;
        }
    }

    public synchronized QuickActionDisplayMode quickActionDisplayMode() {
        return quickActionDisplayMode;
    }

    public synchronized void setQuickActionDisplayMode(QuickActionDisplayMode value) {
        if (futureVersionReadOnly) {
            return;
        }
        QuickActionDisplayMode normalized = value == null ? QuickActionDisplayMode.SIX : value;
        if (quickActionDisplayMode != normalized) {
            quickActionDisplayMode = normalized;
            changed();
        }
    }

    public synchronized boolean showPotionEffects() {
        return showPotionEffects;
    }

    public synchronized boolean showStatusHud() {
        return showStatusHud;
    }

    public synchronized boolean showPlayerPreview() {
        return showPlayerPreview;
    }

    public synchronized boolean creativeWrist() {
        return creativeWrist;
    }

    public synchronized boolean contextualContainers() {
        return contextualContainers;
    }

    public synchronized boolean xaeroIntegration() {
        return xaeroIntegration;
    }

    public synchronized boolean jeiIntegration() {
        return jeiIntegration;
    }

    public synchronized boolean inventoryProfilesIntegration() {
        return inventoryProfilesIntegration;
    }

    public synchronized boolean statusVisible(StatusMetric metric) {
        return showStatusHud && statusVisibility.getOrDefault(metric, true);
    }

    public synchronized StatusPosition statusPosition(StatusMetric metric) {
        return statusPositions.getOrDefault(metric, defaultPosition(metric));
    }

    public synchronized void setShowPotionEffects(boolean value) {
        if (futureVersionReadOnly) {
            return;
        }
        if (showPotionEffects != value) {
            showPotionEffects = value;
            changed();
        }
    }

    public synchronized void setShowStatusHud(boolean value) {
        if (futureVersionReadOnly) {
            return;
        }
        if (showStatusHud != value) {
            showStatusHud = value;
            changed();
        }
    }

    public synchronized void setShowPlayerPreview(boolean value) {
        if (futureVersionReadOnly) {
            return;
        }
        if (showPlayerPreview != value) {
            showPlayerPreview = value;
            changed();
        }
    }

    public synchronized void setCreativeWrist(boolean value) {
        if (futureVersionReadOnly) {
            return;
        }
        if (creativeWrist != value) {
            creativeWrist = value;
            changed();
        }
    }

    public synchronized void setContextualContainers(boolean value) {
        if (futureVersionReadOnly) {
            return;
        }
        if (contextualContainers != value) {
            contextualContainers = value;
            changed();
        }
    }

    public synchronized void setIntegration(OptionalIntegration integration, boolean value) {
        if (futureVersionReadOnly || integration == null) {
            return;
        }
        boolean changed = switch (integration) {
            case XAERO -> xaeroIntegration != value;
            case JEI -> jeiIntegration != value;
            case INVENTORY_PROFILES_NEXT -> inventoryProfilesIntegration != value;
        };
        if (!changed) {
            return;
        }
        switch (integration) {
            case XAERO -> xaeroIntegration = value;
            case JEI -> jeiIntegration = value;
            case INVENTORY_PROFILES_NEXT -> inventoryProfilesIntegration = value;
        }
        changed();
    }

    public synchronized void setStatusVisible(StatusMetric metric, boolean value) {
        if (futureVersionReadOnly || metric == null) {
            return;
        }
        if (statusVisibility.getOrDefault(metric, true) != value) {
            statusVisibility.put(metric, value);
            changed();
        }
    }

    public synchronized void setStatusPosition(StatusMetric metric, StatusPosition value) {
        if (futureVersionReadOnly || metric == null) {
            return;
        }
        StatusPosition normalized = value == null ? defaultPosition(metric) : value;
        if (statusPosition(metric) != normalized) {
            statusPositions.put(metric, normalized);
            changed();
        }
    }

    private void resetInMemory() {
        quickActionDisplayMode = QuickActionDisplayMode.SIX;
        showPotionEffects = true;
        showStatusHud = true;
        showPlayerPreview = false;
        creativeWrist = true;
        contextualContainers = false;
        xaeroIntegration = true;
        jeiIntegration = true;
        inventoryProfilesIntegration = true;
        statusVisibility.clear();
        statusPositions.clear();
        for (StatusMetric metric : StatusMetric.values()) {
            statusVisibility.put(metric, true);
            statusPositions.put(metric, defaultPosition(metric));
        }
    }

    private synchronized void load(boolean migrateLegacy) {
        futureVersionReadOnly = false;
        if (!Files.isRegularFile(configFile)) {
            if (migrateLegacy) {
                WristUiConfig legacy = WristUiConfig.getInstance();
                quickActionDisplayMode = legacy.quickActionDisplayMode();
                showPotionEffects = legacy.showPotionEffects();
            }
            save();
            return;
        }
        boolean rewrite = false;
        try (Reader reader = Files.newBufferedReader(configFile, StandardCharsets.UTF_8)) {
            StoredConfig stored = GSON.fromJson(reader, StoredConfig.class);
            if (stored == null) {
                rewrite = true;
            } else {
                quickActionDisplayMode = parse(
                        stored.quickActionDisplayMode,
                        QuickActionDisplayMode.class,
                        QuickActionDisplayMode.SIX
                );
                showPotionEffects = stored.showPotionEffects == null || stored.showPotionEffects;
                showStatusHud = stored.showStatusHud == null || stored.showStatusHud;
                showPlayerPreview = Boolean.TRUE.equals(stored.showPlayerPreview);
                creativeWrist = stored.creativeWrist == null || stored.creativeWrist;
                // Contextual containers were enabled implicitly in schema 1.
                // Make native Minecraft screens the safe schema-2 default;
                // users can still opt in explicitly from a schema-2 config.
                contextualContainers = stored.version >= 2
                        && Boolean.TRUE.equals(stored.contextualContainers);
                xaeroIntegration = stored.xaeroIntegration == null || stored.xaeroIntegration;
                jeiIntegration = stored.jeiIntegration == null || stored.jeiIntegration;
                inventoryProfilesIntegration = stored.inventoryProfilesIntegration == null
                        || stored.inventoryProfilesIntegration;
                for (StatusMetric metric : StatusMetric.values()) {
                    StoredMetric entry = stored.metric(metric);
                    statusVisibility.put(metric, entry == null || entry.visible == null || entry.visible);
                    statusPositions.put(metric, parse(
                            entry == null ? null : entry.position,
                            StatusPosition.class,
                            defaultPosition(metric)
                    ));
                }
                futureVersionReadOnly = stored.version > CONFIG_VERSION;
                rewrite = stored.version < CONFIG_VERSION
                        && backupLegacyConfigOnce(stored.version);
            }
        } catch (IOException | RuntimeException exception) {
            VivecraftEssentialsQuest.LOGGER.error(
                    "Could not load VEP feature settings from {}",
                    configFile,
                    exception
            );
            return;
        }
        if (rewrite) {
            save();
        }
    }

    private boolean backupLegacyConfigOnce(int storedVersion) {
        Path backup = configFile.resolveSibling(
                configFile.getFileName() + ".v" + storedVersion + ".bak");
        if (Files.isRegularFile(backup)) {
            return true;
        }
        if (Files.exists(backup)) {
            VivecraftEssentialsQuest.LOGGER.warn(
                    "VEP feature config backup target is not a regular file: {}", backup);
            return false;
        }
        try {
            Files.copy(configFile, backup, StandardCopyOption.COPY_ATTRIBUTES);
            return true;
        } catch (IOException attributesFailure) {
            try {
                Files.deleteIfExists(backup);
                Files.copy(configFile, backup);
                return true;
            } catch (IOException exception) {
                VivecraftEssentialsQuest.LOGGER.error(
                        "Could not create one-time VEP feature config backup {}",
                        backup,
                        exception
                );
                return false;
            }
        }
    }

    private synchronized void save() {
        if (futureVersionReadOnly) {
            return;
        }
        StoredConfig stored = new StoredConfig();
        stored.version = CONFIG_VERSION;
        stored.quickActionDisplayMode = quickActionDisplayMode.name();
        stored.showPotionEffects = showPotionEffects;
        stored.showStatusHud = showStatusHud;
        stored.showPlayerPreview = showPlayerPreview;
        stored.creativeWrist = creativeWrist;
        stored.contextualContainers = contextualContainers;
        stored.xaeroIntegration = xaeroIntegration;
        stored.jeiIntegration = jeiIntegration;
        stored.inventoryProfilesIntegration = inventoryProfilesIntegration;
        stored.health = metric(StatusMetric.HEALTH);
        stored.hunger = metric(StatusMetric.HUNGER);
        stored.armor = metric(StatusMetric.ARMOR);
        stored.experience = metric(StatusMetric.EXPERIENCE);

        Path temporary = configFile.resolveSibling(configFile.getFileName() + ".tmp");
        try {
            Files.createDirectories(configFile.getParent());
            try (Writer writer = Files.newBufferedWriter(temporary, StandardCharsets.UTF_8)) {
                GSON.toJson(stored, writer);
            }
            try {
                Files.move(temporary, configFile,
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, configFile, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException exception) {
            VivecraftEssentialsQuest.LOGGER.error(
                    "Could not save VEP feature settings to {}",
                    configFile,
                    exception
            );
            try {
                Files.deleteIfExists(temporary);
            } catch (IOException ignored) {
                // Preserve the original failure.
            }
        }
    }

    private StoredMetric metric(StatusMetric metric) {
        StoredMetric stored = new StoredMetric();
        stored.visible = statusVisibility.getOrDefault(metric, true);
        stored.position = statusPositions.getOrDefault(metric, defaultPosition(metric)).name();
        return stored;
    }

    private void changed() {
        revision++;
        if (editing) {
            editingDirty = true;
        } else {
            save();
        }
    }

    private FeatureState snapshot() {
        return new FeatureState(
                quickActionDisplayMode,
                showPotionEffects,
                showStatusHud,
                showPlayerPreview,
                creativeWrist,
                contextualContainers,
                xaeroIntegration,
                jeiIntegration,
                inventoryProfilesIntegration,
                new EnumMap<>(statusVisibility),
                new EnumMap<>(statusPositions)
        );
    }

    private void restore(FeatureState state) {
        if (state == null) {
            return;
        }
        quickActionDisplayMode = state.quickActionDisplayMode();
        showPotionEffects = state.showPotionEffects();
        showStatusHud = state.showStatusHud();
        showPlayerPreview = state.showPlayerPreview();
        creativeWrist = state.creativeWrist();
        contextualContainers = state.contextualContainers();
        xaeroIntegration = state.xaeroIntegration();
        jeiIntegration = state.jeiIntegration();
        inventoryProfilesIntegration = state.inventoryProfilesIntegration();
        statusVisibility.clear();
        statusVisibility.putAll(state.statusVisibility());
        statusPositions.clear();
        statusPositions.putAll(state.statusPositions());
    }

    private static StatusPosition defaultPosition(StatusMetric metric) {
        return metric == StatusMetric.EXPERIENCE ? StatusPosition.TOP : StatusPosition.BOTTOM;
    }

    private static <T extends Enum<T>> T parse(String raw, Class<T> type, T fallback) {
        if (raw == null || raw.isBlank()) {
            return fallback;
        }
        try {
            return Enum.valueOf(type, raw.toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ignored) {
            return fallback;
        }
    }

    public enum StatusMetric {
        HEALTH,
        HUNGER,
        ARMOR,
        EXPERIENCE
    }

    public enum StatusPosition {
        TOP,
        BOTTOM
    }

    public enum OptionalIntegration {
        XAERO,
        JEI,
        INVENTORY_PROFILES_NEXT
    }

    private record FeatureState(
            QuickActionDisplayMode quickActionDisplayMode,
            boolean showPotionEffects,
            boolean showStatusHud,
            boolean showPlayerPreview,
            boolean creativeWrist,
            boolean contextualContainers,
            boolean xaeroIntegration,
            boolean jeiIntegration,
            boolean inventoryProfilesIntegration,
            EnumMap<StatusMetric, Boolean> statusVisibility,
            EnumMap<StatusMetric, StatusPosition> statusPositions
    ) {
    }

    private static final class StoredConfig {
        private int version;
        private String quickActionDisplayMode;
        private Boolean showPotionEffects;
        private Boolean showStatusHud;
        private Boolean showPlayerPreview;
        private Boolean creativeWrist;
        private Boolean contextualContainers;
        private Boolean xaeroIntegration;
        private Boolean jeiIntegration;
        private Boolean inventoryProfilesIntegration;
        private StoredMetric health;
        private StoredMetric hunger;
        private StoredMetric armor;
        private StoredMetric experience;

        private StoredMetric metric(StatusMetric metric) {
            return switch (metric) {
                case HEALTH -> health;
                case HUNGER -> hunger;
                case ARMOR -> armor;
                case EXPERIENCE -> experience;
            };
        }
    }

    private static final class StoredMetric {
        private Boolean visible;
        private String position;
    }
}
