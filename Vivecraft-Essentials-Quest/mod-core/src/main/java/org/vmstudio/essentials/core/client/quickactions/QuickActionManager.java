package org.vmstudio.essentials.core.client.quickactions;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonParseException;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.ItemStack;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.essentials.core.mixin.client.accessor.KeyMappingAccessor;

import java.io.IOException;
import java.io.Reader;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Client-side storage and execution service for the twelve inventory quick actions.
 *
 * <p>The JSON file contains descriptions only. Execution is deliberately
 * limited to Minecraft commands sent through the active client connection and
 * registered {@link KeyMapping}s; it never invokes the operating-system shell.</p>
 */
public final class QuickActionManager {
    public static final int SLOT_COUNT = 12;
    public static final String DEFAULT_ICON_ID = "minecraft:barrier";

    private static final int CONFIG_VERSION = 2;
    private static final Logger LOGGER = LogManager.getLogger(VisorEssentials.MOD_NAME + "/QuickActions");
    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create();
    private static final QuickActionManager INSTANCE = new QuickActionManager();

    private final Path configFile;
    private final List<QuickActionDefinition> actions = new ArrayList<>(SLOT_COUNT);
    private final Map<KeyMapping, PendingRelease> pendingReleases = new IdentityHashMap<>();

    private QuickActionManager() {
        this.configFile = Minecraft.getInstance().gameDirectory.toPath()
                .resolve("config")
                .resolve(VisorEssentials.MOD_ID)
                .resolve("quick_actions.json");
        resetInMemory();
        load();
    }

    public static @NotNull QuickActionManager getInstance() {
        return INSTANCE;
    }

    public synchronized @NotNull QuickActionDefinition getAction(int slot) {
        checkSlot(slot);
        return actions.get(slot);
    }

    public synchronized boolean isConfigured(int slot) {
        return getAction(slot).isConfigured();
    }

    /** Replaces one slot and immediately persists the complete twelve-slot set. */
    public synchronized void setAction(int slot, @NotNull QuickActionDefinition action) {
        checkSlot(slot);
        actions.set(slot, action == null ? QuickActionDefinition.empty() : action);
        save();
    }

    public synchronized void clearAction(int slot) {
        setAction(slot, QuickActionDefinition.empty());
    }

    public synchronized @NotNull ItemStack getIconStack(int slot) {
        return getIconStack(getAction(slot));
    }

    public @NotNull ItemStack getIconStack(@NotNull QuickActionDefinition action) {
        if (!action.isConfigured()) {
            return ItemStack.EMPTY;
        }

        Identifier id = Identifier.tryParse(action.iconItemId());
        if (id != null) {
            Optional<net.minecraft.world.item.Item> item = BuiltInRegistries.ITEM.getOptional(id);
            if (item.isPresent()) {
                return new ItemStack(item.get());
            }
        }

        return BuiltInRegistries.ITEM.getOptional(Identifier.parse(DEFAULT_ICON_ID))
                .map(ItemStack::new)
                .orElse(ItemStack.EMPTY);
    }

    public synchronized @NotNull Component getTooltip(int slot) {
        QuickActionDefinition action = getAction(slot);
        if (!action.isConfigured()) {
            return Component.literal("Add quick action");
        }
        if (!action.displayName().isBlank()) {
            return Component.literal(action.displayName());
        }
        return action.type() == QuickActionType.COMMAND
                ? Component.literal("/" + action.value())
                : getKeybindDisplayName(action.value());
    }

    /** Executes a slot on the Minecraft client thread. */
    public boolean execute(int slot) {
        QuickActionDefinition action = getAction(slot);
        if (!action.isConfigured()) {
            return false;
        }

        Minecraft minecraft = Minecraft.getInstance();
        if (!minecraft.isSameThread()) {
            minecraft.execute(() -> executeNow(action));
            return true;
        }
        return executeNow(action);
    }

    /**
     * Advances synthetic key presses and releases them after one complete game
     * tick. Call once at the tail of {@code Minecraft.tick()}.
     */
    public synchronized void tick() {
        var iterator = pendingReleases.entrySet().iterator();
        while (iterator.hasNext()) {
            Map.Entry<KeyMapping, PendingRelease> entry = iterator.next();
            PendingRelease pending = entry.getValue().nextTick();
            if (pending.ticksRemaining() > 0) {
                entry.setValue(pending);
                continue;
            }

            if (!pending.wasAlreadyDown()) {
                entry.getKey().setDown(false);
            }
            iterator.remove();
        }
    }

    public @Nullable KeyMapping findKeyMapping(@NotNull String mappingName) {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.options == null || mappingName == null || mappingName.isBlank()) {
            return null;
        }
        for (KeyMapping mapping : minecraft.options.keyMappings) {
            if (mappingName.equals(mapping.getName())) {
                return mapping;
            }
        }
        return null;
    }

    public @NotNull List<KeybindOption> getAvailableKeyMappings() {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.options == null) {
            return List.of();
        }

        return Arrays.stream(minecraft.options.keyMappings)
                .map(mapping -> new KeybindOption(
                        mapping.getName(),
                        Component.translatable(mapping.getName()),
                        mapping.getTranslatedKeyMessage()
                ))
                .sorted(Comparator.comparing(option -> option.displayName().getString(), String.CASE_INSENSITIVE_ORDER))
                .toList();
    }

    public boolean isRegisteredItem(@NotNull String itemId) {
        Identifier id = Identifier.tryParse(itemId);
        return id != null && BuiltInRegistries.ITEM.containsKey(id);
    }

    private boolean executeNow(@NotNull QuickActionDefinition action) {
        Minecraft minecraft = Minecraft.getInstance();
        return switch (action.type()) {
            case COMMAND -> executeCommand(minecraft, action.value());
            case KEYBIND -> executeKeybind(action.value());
            case EMPTY -> false;
        };
    }

    private boolean executeCommand(@NotNull Minecraft minecraft, @NotNull String rawCommand) {
        String command = QuickActionDefinition.normalizeCommand(rawCommand);
        if (command.isBlank() || minecraft.player == null || minecraft.getConnection() == null) {
            return false;
        }
        minecraft.getConnection().sendCommand(command);
        return true;
    }

    private synchronized boolean executeKeybind(@NotNull String mappingName) {
        KeyMapping mapping = findKeyMapping(mappingName);
        if (mapping == null) {
            return false;
        }

        PendingRelease existing = pendingReleases.get(mapping);
        boolean wasAlreadyDown = existing != null ? existing.wasAlreadyDown() : mapping.isDown();
        mapping.setDown(true);
        // Increment this registered mapping directly. KeyMapping.click(key)
        // operates on a physical-key lookup and can activate a different or
        // additional mapping when mods share a binding. Direct clickCount is
        // also what makes a named mapping usable if it is currently unbound.
        KeyMappingAccessor accessor = (KeyMappingAccessor) (Object) mapping;
        int currentClicks = accessor.visorEssentials$getClickCount();
        if (currentClicks < Integer.MAX_VALUE) {
            accessor.visorEssentials$setClickCount(currentClicks + 1);
        }
        // Two tail ticks guarantee the mapping remains down through at least one
        // complete client tick regardless of whether the click originated in a
        // render callback just before or just after Minecraft.tick().
        pendingReleases.put(mapping, new PendingRelease(wasAlreadyDown, 2));
        return true;
    }

    private @NotNull Component getKeybindDisplayName(@NotNull String mappingName) {
        KeyMapping mapping = findKeyMapping(mappingName);
        return mapping == null
                ? Component.literal(mappingName)
                : Component.translatable(mapping.getName());
    }

    private void load() {
        if (!Files.isRegularFile(configFile)) {
            save();
            return;
        }

        boolean rewrite = false;
        try (Reader reader = Files.newBufferedReader(configFile, StandardCharsets.UTF_8)) {
            StoredConfig stored = GSON.fromJson(reader, StoredConfig.class);
            if (stored == null || stored.actions == null) {
                throw new JsonParseException("Missing actions array");
            }

            List<QuickActionDefinition> loaded = new ArrayList<>(SLOT_COUNT);
            rewrite = stored.version != CONFIG_VERSION
                    || stored.actions.size() != SLOT_COUNT;
            // Version-one files contain six entries. Retain those slots in
            // order and initialize each newly added slot as an empty action.
            for (int slot = 0; slot < SLOT_COUNT; slot++) {
                StoredAction entry = slot < stored.actions.size() ? stored.actions.get(slot) : null;
                loaded.add(fromStored(entry));
            }
            actions.clear();
            actions.addAll(loaded);
        } catch (IOException | RuntimeException exception) {
            LOGGER.error("Could not load quick actions from {}; keeping the current configuration", configFile, exception);
            return;
        }

        if (rewrite) {
            save();
        }
    }

    private void save() {
        StoredConfig stored = new StoredConfig();
        stored.version = CONFIG_VERSION;
        stored.actions = actions.stream().map(QuickActionManager::toStored).toList();

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
            LOGGER.error("Could not save quick actions to {}", configFile, exception);
            try {
                Files.deleteIfExists(temporary);
            } catch (IOException ignored) {
                // Preserve the original error; a stale temporary file is harmless.
            }
        }
    }

    private void resetInMemory() {
        actions.clear();
        actions.addAll(Collections.nCopies(SLOT_COUNT, QuickActionDefinition.empty()));
    }

    private static @NotNull QuickActionDefinition fromStored(@Nullable StoredAction stored) {
        if (stored == null) {
            return QuickActionDefinition.empty();
        }

        QuickActionType type;
        try {
            type = stored.type == null
                    ? QuickActionType.EMPTY
                    : QuickActionType.valueOf(stored.type.toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException ignored) {
            type = QuickActionType.EMPTY;
        }

        return new QuickActionDefinition(type, stored.displayName, stored.iconItemId, stored.value);
    }

    private static @NotNull StoredAction toStored(@NotNull QuickActionDefinition action) {
        StoredAction stored = new StoredAction();
        stored.type = action.type().name();
        stored.displayName = action.displayName();
        stored.iconItemId = action.iconItemId();
        stored.value = action.value();
        return stored;
    }

    private static void checkSlot(int slot) {
        if (slot < 0 || slot >= SLOT_COUNT) {
            throw new IndexOutOfBoundsException("Quick action slot must be between 0 and " + (SLOT_COUNT - 1));
        }
    }

    public record KeybindOption(
            @NotNull String id,
            @NotNull Component displayName,
            @NotNull Component boundKey
    ) {
    }

    private record PendingRelease(boolean wasAlreadyDown, int ticksRemaining) {
        private @NotNull PendingRelease nextTick() {
            return new PendingRelease(wasAlreadyDown, ticksRemaining - 1);
        }
    }

    private static final class StoredConfig {
        private int version;
        private List<StoredAction> actions;
    }

    private static final class StoredAction {
        private String type;
        private String displayName;
        private String iconItemId;
        private String value;
    }
}
