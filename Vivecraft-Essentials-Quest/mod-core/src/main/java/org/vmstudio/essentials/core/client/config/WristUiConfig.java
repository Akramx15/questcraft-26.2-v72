package org.vmstudio.essentials.core.client.config;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import net.minecraft.client.Minecraft;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.vmstudio.essentials.core.common.VisorEssentials;

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

/** Persistent client preferences for the VisorEssentials wrist inventory. */
public final class WristUiConfig {
    private static final int CONFIG_VERSION = 4;
    private static final Logger LOGGER = LogManager.getLogger(
            VisorEssentials.MOD_NAME + "/WristUI"
    );
    private static final Gson GSON = new GsonBuilder()
            .setPrettyPrinting()
            .disableHtmlEscaping()
            .create();
    private static final WristUiConfig INSTANCE = new WristUiConfig();

    private final Path configFile;
    private final EnumMap<WristHudMetric, Boolean> visibility =
            new EnumMap<>(WristHudMetric.class);
    private final EnumMap<WristHudMetric, WristHudPosition> positions =
            new EnumMap<>(WristHudMetric.class);

    private QuickActionDisplayMode quickActionDisplayMode;
    private boolean armInventoryEnabled;
    private boolean quickActionsOpenArmInventory;
    private boolean showPotionEffects;
    private long revision;

    private WristUiConfig() {
        configFile = Minecraft.getInstance().gameDirectory.toPath()
                .resolve("config")
                .resolve(VisorEssentials.MOD_ID)
                .resolve("wrist_ui.json");
        resetInMemory();
        load();
    }

    public static @NotNull WristUiConfig getInstance() {
        return INSTANCE;
    }

    /**
     * Monotonically increasing in-memory revision for consumers that cache
     * geometry derived from wrist UI preferences.
     */
    public synchronized long revision() {
        return revision;
    }

    public synchronized @NotNull QuickActionDisplayMode quickActionDisplayMode() {
        return quickActionDisplayMode;
    }

    public synchronized void setQuickActionDisplayMode(
            @NotNull QuickActionDisplayMode quickActionDisplayMode) {
        QuickActionDisplayMode normalized = quickActionDisplayMode == null
                ? QuickActionDisplayMode.SIX
                : quickActionDisplayMode;
        if (this.quickActionDisplayMode != normalized) {
            this.quickActionDisplayMode = normalized;
            revision++;
        }
        save();
    }

    public synchronized boolean armInventoryEnabled() {
        return armInventoryEnabled;
    }

    public synchronized void setArmInventoryEnabled(boolean armInventoryEnabled) {
        if (this.armInventoryEnabled != armInventoryEnabled) {
            this.armInventoryEnabled = armInventoryEnabled;
            revision++;
        }
        save();
    }

    public synchronized boolean quickActionsOpenArmInventory() {
        return quickActionsOpenArmInventory;
    }

    public synchronized void setQuickActionsOpenArmInventory(
            boolean quickActionsOpenArmInventory) {
        if (this.quickActionsOpenArmInventory != quickActionsOpenArmInventory) {
            this.quickActionsOpenArmInventory = quickActionsOpenArmInventory;
            revision++;
        }
        save();
    }

    public synchronized boolean showPotionEffects() {
        return showPotionEffects;
    }

    public synchronized void setShowPotionEffects(boolean showPotionEffects) {
        if (this.showPotionEffects != showPotionEffects) {
            this.showPotionEffects = showPotionEffects;
            revision++;
        }
        save();
    }

    public synchronized boolean isVisible(@NotNull WristHudMetric metric) {
        return visibility.getOrDefault(metric, true);
    }

    public synchronized void setVisible(@NotNull WristHudMetric metric,
                                        boolean visible) {
        if (isVisible(metric) != visible) {
            visibility.put(metric, visible);
            revision++;
        }
        save();
    }

    public synchronized @NotNull WristHudPosition position(
            @NotNull WristHudMetric metric) {
        return positions.getOrDefault(metric, defaultPosition(metric));
    }

    public synchronized void setPosition(@NotNull WristHudMetric metric,
                                         @NotNull WristHudPosition position) {
        WristHudPosition normalized = position == null
                ? defaultPosition(metric)
                : position;
        if (position(metric) != normalized) {
            positions.put(metric, normalized);
            revision++;
        }
        save();
    }

    public synchronized void reset() {
        resetInMemory();
        revision++;
        save();
    }

    private void resetInMemory() {
        quickActionDisplayMode = QuickActionDisplayMode.SIX;
        armInventoryEnabled = true;
        quickActionsOpenArmInventory = false;
        showPotionEffects = true;
        visibility.clear();
        positions.clear();
        for (WristHudMetric metric : WristHudMetric.values()) {
            visibility.put(metric, true);
            positions.put(metric, defaultPosition(metric));
        }
    }

    private synchronized void load() {
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
                QuickActionDisplayMode storedDisplayMode = parseOptionalEnum(
                        stored.quickActionDisplayMode,
                        QuickActionDisplayMode.class
                );
                if (storedDisplayMode != null) {
                    quickActionDisplayMode = storedDisplayMode;
                } else {
                    // Version 1 stored only a visibility boolean. Preserve its six
                    // visible buttons while the action manager independently keeps
                    // all twelve definitions intact.
                    quickActionDisplayMode = (stored.showQuickActions == null
                            || stored.showQuickActions)
                            ? QuickActionDisplayMode.SIX
                            : QuickActionDisplayMode.OFF;
                    rewrite = true;
                }
                armInventoryEnabled = stored.armInventoryEnabled == null
                        || stored.armInventoryEnabled;
                if (stored.armInventoryEnabled == null) {
                    rewrite = true;
                }
                quickActionsOpenArmInventory =
                        WristUiConfigMigration.quickActionsOpenArmInventory(
                                stored.quickActionsOpenArmInventory
                        );
                if (stored.quickActionsOpenArmInventory == null) {
                    rewrite = true;
                }
                showPotionEffects = stored.showPotionEffects == null
                        || stored.showPotionEffects;
                if (stored.showPotionEffects == null) {
                    rewrite = true;
                }
                boolean legacyAllBottom = stored.version < 2
                        && isLegacyAllBottom(stored);
                for (WristHudMetric metric : WristHudMetric.values()) {
                    StoredMetric storedMetric = stored.metric(metric);
                    visibility.put(
                            metric,
                            storedMetric == null || storedMetric.visible == null
                                    || storedMetric.visible
                    );
                    String rawPosition = storedMetric == null
                            ? null
                            : storedMetric.position;
                    WristHudPosition migratedPosition = legacyAllBottom
                            ? defaultPosition(metric)
                            : parsePosition(rawPosition, metric);
                    positions.put(metric, migratedPosition);
                    if (!isSupportedPosition(rawPosition)) {
                        rewrite = true;
                    }
                }
                rewrite |= stored.version != CONFIG_VERSION;
            }
        } catch (IOException | RuntimeException exception) {
            LOGGER.error(
                    "Could not load wrist UI settings from {}; using the last known settings",
                    configFile,
                    exception
            );
            return;
        }

        // Replace legacy JSON only after its reader has closed. Windows does
        // not reliably allow an atomic replacement while the source is open.
        if (rewrite) {
            save();
        }
    }

    private synchronized void save() {
        StoredConfig stored = new StoredConfig();
        stored.version = CONFIG_VERSION;
        stored.quickActionDisplayMode = quickActionDisplayMode.name();
        stored.armInventoryEnabled = armInventoryEnabled;
        stored.quickActionsOpenArmInventory = quickActionsOpenArmInventory;
        stored.showPotionEffects = showPotionEffects;
        stored.health = storedMetric(WristHudMetric.HEALTH);
        stored.hunger = storedMetric(WristHudMetric.HUNGER);
        stored.armor = storedMetric(WristHudMetric.ARMOR);
        stored.experience = storedMetric(WristHudMetric.EXPERIENCE);

        Path parent = configFile.getParent();
        Path temporary = configFile.resolveSibling(configFile.getFileName() + ".tmp");
        try {
            Files.createDirectories(parent);
            try (Writer writer = Files.newBufferedWriter(temporary, StandardCharsets.UTF_8)) {
                GSON.toJson(stored, writer);
            }
            try {
                Files.move(
                        temporary,
                        configFile,
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING
                );
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, configFile, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException exception) {
            LOGGER.error("Could not save wrist UI settings to {}", configFile, exception);
            try {
                Files.deleteIfExists(temporary);
            } catch (IOException ignored) {
                // Preserve the original failure.
            }
        }
    }

    private @NotNull StoredMetric storedMetric(@NotNull WristHudMetric metric) {
        StoredMetric stored = new StoredMetric();
        stored.visible = isVisible(metric);
        stored.position = position(metric).name();
        return stored;
    }

    private static @NotNull WristHudPosition defaultPosition(
            @NotNull WristHudMetric metric) {
        return metric == WristHudMetric.EXPERIENCE
                ? WristHudPosition.TOP
                : WristHudPosition.BOTTOM;
    }

    private static @NotNull WristHudPosition parsePosition(
            @Nullable String value,
            @NotNull WristHudMetric metric) {
        if (value != null) {
            if (value.equalsIgnoreCase(WristHudPosition.TOP.name())) {
                return WristHudPosition.TOP;
            }
            if (value.equalsIgnoreCase(WristHudPosition.BOTTOM.name())) {
                return WristHudPosition.BOTTOM;
            }
        }
        return defaultPosition(metric);
    }

    private static boolean isSupportedPosition(@Nullable String value) {
        return value != null
                && (value.equalsIgnoreCase(WristHudPosition.TOP.name())
                || value.equalsIgnoreCase(WristHudPosition.BOTTOM.name()));
    }

    private static boolean isLegacyAllBottom(@NotNull StoredConfig stored) {
        for (WristHudMetric metric : WristHudMetric.values()) {
            StoredMetric storedMetric = stored.metric(metric);
            String position = storedMetric == null ? null : storedMetric.position;
            if (position != null
                    && !position.equalsIgnoreCase(WristHudPosition.BOTTOM.name())) {
                return false;
            }
        }
        return true;
    }

    private static <T extends Enum<T>> @Nullable T parseOptionalEnum(
            @Nullable String value,
            @NotNull Class<T> enumType) {
        if (value == null || value.isBlank()) {
            return null;
        }
        try {
            return Enum.valueOf(enumType, value.toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    private static final class StoredConfig {
        private int version;
        private String quickActionDisplayMode;
        private Boolean armInventoryEnabled;
        private Boolean quickActionsOpenArmInventory;
        private Boolean showPotionEffects;
        /** Version 1 compatibility field. */
        private Boolean showQuickActions;
        private StoredMetric health;
        private StoredMetric hunger;
        private StoredMetric armor;
        private StoredMetric experience;

        private @Nullable StoredMetric metric(@NotNull WristHudMetric metric) {
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
