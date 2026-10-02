package org.questcraft.veq.client.config;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.minecraft.client.Minecraft;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.input.QuestButtonAction;
import org.questcraft.veq.client.input.QuestButtonLayout;
import org.questcraft.veq.client.input.QuestFaceButton;

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

/** Atomic, client-only Quest Touch face-button configuration. */
public final class QuestButtonBindingsConfig {
    public static final int CONFIG_VERSION = 2;
    private static final Gson GSON = new GsonBuilder()
            .setPrettyPrinting()
            .disableHtmlEscaping()
            .create();
    private static QuestButtonBindingsConfig instance;

    private final Path configFile;
    private EnumMap<QuestFaceButton, QuestButtonAction> values;
    private EnumMap<QuestFaceButton, QuestButtonAction> editSnapshot;
    private boolean editingDirty;
    private boolean futureVersionReadOnly;
    private long revision;
    private QuestButtonLayout appliedLayout;

    private QuestButtonBindingsConfig(Path configFile) {
        this.configFile = configFile;
        this.values = mutableCopy(QuestButtonLayout.personalDefaults());
        load();
        appliedLayout = layout();
    }

    public static synchronized QuestButtonBindingsConfig getInstance() {
        if (instance == null) {
            Path path = Minecraft.getInstance().gameDirectory.toPath()
                    .resolve("config")
                    .resolve(VivecraftEssentialsQuest.MOD_ID)
                    .resolve("quest_button_bindings.json");
            instance = new QuestButtonBindingsConfig(path);
        }
        return instance;
    }

    static QuestButtonBindingsConfig forTest(Path path) {
        return new QuestButtonBindingsConfig(path);
    }

    public synchronized QuestButtonLayout layout() {
        return new QuestButtonLayout(values);
    }

    public synchronized QuestButtonAction action(QuestFaceButton button) {
        return values.get(button);
    }

    public synchronized long revision() {
        return revision;
    }

    public synchronized boolean isFutureVersionReadOnly() {
        return futureVersionReadOnly;
    }

    /** Records the exact layout frozen into the currently attached OpenXR session. */
    public synchronized QuestButtonLayout markAppliedToOpenXR() {
        appliedLayout = layout();
        return appliedLayout;
    }

    public synchronized boolean restartRequired() {
        return !layout().equals(appliedLayout);
    }

    public synchronized void beginEditing() {
        if (futureVersionReadOnly || editSnapshot != null) {
            return;
        }
        editSnapshot = new EnumMap<>(values);
        editingDirty = false;
    }

    public synchronized void setAction(QuestFaceButton button, QuestButtonAction action) {
        if (futureVersionReadOnly || button == null || action == null || !action.supports(button)) {
            return;
        }
        boolean changed = false;
        if (action.requiresUniquePhysicalSource()) {
            for (QuestFaceButton other : QuestFaceButton.values()) {
                if (other != button && values.get(other) == action) {
                    values.put(other, QuestButtonAction.NONE);
                    changed = true;
                }
            }
        }
        if (values.put(button, action) != action) {
            changed = true;
        }
        if (changed) {
            changed();
        }
    }

    public synchronized void cycle(QuestFaceButton button) {
        QuestButtonAction current = values.get(button);
        setAction(button, current == null
                ? QuestButtonLayout.personalDefaults().action(button)
                : current.nextFor(button));
    }

    public synchronized void resetPersonalDefaults() {
        replaceWith(QuestButtonLayout.personalDefaults());
    }

    public synchronized void resetVivecraftDefaults() {
        replaceWith(QuestButtonLayout.vivecraftDefaults());
    }

    /**
     * Persists the active edit transaction.
     *
     * @return {@code true} when the transaction was committed (or contained no
     * changes); {@code false} when it remains open because persistence failed.
     */
    public synchronized boolean applyEditing() {
        if (futureVersionReadOnly || editSnapshot == null) {
            return false;
        }
        if (editingDirty && !save()) {
            // Keep both the draft and its rollback snapshot so the UI can retry
            // or Cancel without silently accepting an in-memory-only layout.
            return false;
        }
        editSnapshot = null;
        editingDirty = false;
        return true;
    }

    public synchronized void cancelEditing() {
        if (editSnapshot == null) {
            return;
        }
        values = editSnapshot;
        editSnapshot = null;
        editingDirty = false;
        revision++;
    }

    private void replaceWith(QuestButtonLayout layout) {
        if (futureVersionReadOnly || layout.equals(layout())) {
            return;
        }
        values = mutableCopy(layout);
        changed();
    }

    private void changed() {
        revision++;
        if (editSnapshot != null) {
            editingDirty = true;
        } else {
            save();
        }
    }

    private void load() {
        if (!Files.isRegularFile(configFile)) {
            return;
        }
        boolean rewriteCurrentVersion = false;
        try (Reader reader = Files.newBufferedReader(configFile, StandardCharsets.UTF_8)) {
            JsonObject root = JsonParser.parseReader(reader).getAsJsonObject();
            int version = root.has("version") ? root.get("version").getAsInt() : 0;
            futureVersionReadOnly = version > CONFIG_VERSION;
            for (QuestFaceButton button : QuestFaceButton.values()) {
                String field = fieldName(button);
                if (!root.has(field) || !root.get(field).isJsonPrimitive()) {
                    continue;
                }
                QuestButtonAction parsed = parseAction(root.get(field).getAsString());
                if (parsed != null && parsed.supports(button)) {
                    values.put(button, parsed);
                }
            }
            boolean normalized = normalizeUniqueSources();
            rewriteCurrentVersion = version < CONFIG_VERSION ||
                    normalized && version == CONFIG_VERSION;
        } catch (IOException | RuntimeException exception) {
            VivecraftEssentialsQuest.LOGGER.error(
                    "Could not load Quest button bindings from {}",
                    configFile,
                    exception
            );
            return;
        }
        // Close the source file before atomically replacing it. This matters on
        // Windows and keeps migrations on the same failure-safe save path.
        if (rewriteCurrentVersion) {
            save();
        }
    }

    private boolean save() {
        if (futureVersionReadOnly) {
            return false;
        }
        JsonObject root = new JsonObject();
        root.addProperty("version", CONFIG_VERSION);
        for (QuestFaceButton button : QuestFaceButton.values()) {
            root.addProperty(fieldName(button), values.get(button).name());
        }

        Path temporary = configFile.resolveSibling(configFile.getFileName() + ".tmp");
        try {
            Files.createDirectories(configFile.getParent());
            try (Writer writer = Files.newBufferedWriter(temporary, StandardCharsets.UTF_8)) {
                GSON.toJson(root, writer);
            }
            try {
                Files.move(temporary, configFile,
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, configFile, StandardCopyOption.REPLACE_EXISTING);
            }
            return true;
        } catch (IOException exception) {
            VivecraftEssentialsQuest.LOGGER.error(
                    "Could not save Quest button bindings to {}",
                    configFile,
                    exception
            );
            try {
                Files.deleteIfExists(temporary);
            } catch (IOException ignored) {
                // Keep the original config untouched when cleanup also fails.
            }
            return false;
        }
    }

    private static QuestButtonAction parseAction(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        if ("ATTACK_BREAK".equalsIgnoreCase(value.trim())) {
            return QuestButtonAction.ATTACK_BREAK_THIS_HAND;
        }
        try {
            return QuestButtonAction.valueOf(value.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    private boolean normalizeUniqueSources() {
        boolean changed = false;
        for (QuestButtonAction action : QuestButtonAction.values()) {
            if (!action.requiresUniquePhysicalSource()) {
                continue;
            }
            boolean claimed = false;
            for (QuestFaceButton button : QuestFaceButton.values()) {
                if (values.get(button) != action) {
                    continue;
                }
                if (!claimed) {
                    claimed = true;
                } else {
                    values.put(button, QuestButtonAction.NONE);
                    changed = true;
                }
            }
        }
        return changed;
    }

    private static String fieldName(QuestFaceButton button) {
        return switch (button) {
            case LEFT_X -> "leftX";
            case LEFT_Y -> "leftY";
            case RIGHT_A -> "rightA";
            case RIGHT_B -> "rightB";
        };
    }

    private static EnumMap<QuestFaceButton, QuestButtonAction> mutableCopy(
            QuestButtonLayout layout
    ) {
        EnumMap<QuestFaceButton, QuestButtonAction> copy =
                new EnumMap<>(QuestFaceButton.class);
        copy.putAll(layout.actions());
        return copy;
    }
}
