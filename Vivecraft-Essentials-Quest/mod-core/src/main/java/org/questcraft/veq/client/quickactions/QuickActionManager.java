package org.questcraft.veq.client.quickactions;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonParseException;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.ItemStack;
import org.jetbrains.annotations.Nullable;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.mixin.KeyMappingAccessor;

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
 * VEP-compatible storage and execution service for twelve wrist shortcuts.
 *
 * <p>The persisted JSON is data only. Actions may submit one Minecraft
 * command or activate one registered key mapping; they never execute an OS
 * command. The manager also owns the synthetic key-release lifecycle so a
 * shortcut behaves like a normal one-tick press.</p>
 */
public final class QuickActionManager {
    public static final int SLOT_COUNT = 12;
    public static final String DEFAULT_ICON_ID = "minecraft:barrier";

    // Schema 3 is already present on the user's v63/v64 profile. Keep that
    // identity so loading v65 never downgrades or discards the six saved
    // Inventory/Swap/Xaero actions.
    private static final int CONFIG_VERSION = 3;
    private static final Gson GSON = new GsonBuilder()
            .setPrettyPrinting()
            .disableHtmlEscaping()
            .create();
    private static QuickActionManager instance;

    private final Path configFile;
    private final List<QuickActionDefinition> actions = new ArrayList<>(SLOT_COUNT);
    private final Map<KeyMapping, PendingRelease> pendingReleases = new IdentityHashMap<>();
    private boolean futureVersionReadOnly;

    private QuickActionManager() {
        this(Minecraft.getInstance().gameDirectory.toPath()
                .resolve("config")
                .resolve(VivecraftEssentialsQuest.MOD_ID)
                .resolve("quick_actions.json"), true);
    }

    private QuickActionManager(Path configFile, boolean migrateLegacy) {
        this.configFile = configFile;
        resetInMemory();
        load(migrateLegacy);
    }

    public static synchronized QuickActionManager getInstance() {
        if (instance == null) {
            instance = new QuickActionManager();
        }
        return instance;
    }

    static QuickActionManager forTest(Path configFile) {
        return new QuickActionManager(configFile, false);
    }

    public synchronized QuickActionDefinition getAction(int slot) {
        checkSlot(slot);
        return actions.get(slot);
    }

    public synchronized QuickActionDefinition action(int slot) {
        return getAction(slot);
    }

    public synchronized boolean isConfigured(int slot) {
        return getAction(slot).isConfigured();
    }

    public synchronized void setAction(int slot, QuickActionDefinition action) {
        checkSlot(slot);
        if (futureVersionReadOnly) {
            return;
        }
        actions.set(slot, action == null ? QuickActionDefinition.empty() : action);
        save();
    }

    public synchronized boolean isFutureVersionReadOnly() {
        return futureVersionReadOnly;
    }

    public synchronized void clearAction(int slot) {
        setAction(slot, QuickActionDefinition.empty());
    }

    public synchronized ItemStack getIconStack(int slot) {
        return getIconStack(getAction(slot));
    }

    public ItemStack getIconStack(QuickActionDefinition action) {
        if (action == null || !action.isConfigured()) {
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

    public synchronized Component getTooltip(int slot) {
        QuickActionDefinition action = getAction(slot);
        if (!action.isConfigured()) {
            return Component.translatable("vivecraft_essentials_quest.quick_action.empty");
        }
        if (!action.displayName().isBlank()) {
            return Component.literal(action.displayName());
        }
        return action.type() == QuickActionType.COMMAND
                ? Component.literal("/" + action.value())
                : getKeybindDisplayName(action.value());
    }

    public boolean execute(int slot) {
        return execute(getAction(slot));
    }

    public boolean execute(QuickActionDefinition action) {
        if (action == null || !action.isConfigured()) {
            return false;
        }
        Minecraft minecraft = Minecraft.getInstance();
        if (!minecraft.isSameThread()) {
            minecraft.execute(() -> executeNow(action));
            return true;
        }
        return executeNow(action);
    }

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

    public @Nullable KeyMapping findKeyMapping(String mappingName) {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.options == null || mappingName == null || mappingName.isBlank()) {
            return null;
        }
        return Arrays.stream(minecraft.options.keyMappings)
                .filter(mapping -> mappingName.equals(mapping.getName()))
                .findFirst()
                .orElseGet(() -> xaeroFallback(minecraft, mappingName));
    }

    public List<KeybindOption> getAvailableKeyMappings() {
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
                .sorted(Comparator.comparing(
                        option -> option.displayName().getString(),
                        String.CASE_INSENSITIVE_ORDER
                ))
                .toList();
    }

    public boolean isRegisteredItem(String itemId) {
        Identifier id = Identifier.tryParse(itemId);
        return id != null && BuiltInRegistries.ITEM.containsKey(id);
    }

    private boolean executeNow(QuickActionDefinition action) {
        return switch (action.type()) {
            case COMMAND -> executeCommand(action.value());
            case KEYBIND -> executeKeybind(action.value());
            case EMPTY -> false;
        };
    }

    private boolean executeCommand(String rawCommand) {
        Minecraft minecraft = Minecraft.getInstance();
        String command = QuickActionDefinition.normalizeCommand(rawCommand);
        if (command.isBlank() || minecraft.player == null || minecraft.getConnection() == null) {
            return false;
        }
        minecraft.getConnection().sendCommand(command);
        return true;
    }

    private synchronized boolean executeKeybind(String mappingName) {
        KeyMapping mapping = findKeyMapping(mappingName);
        if (mapping == null) {
            VivecraftEssentialsQuest.LOGGER.warn(
                    "Quick action key mapping '{}' is not installed",
                    mappingName
            );
            return false;
        }
        PendingRelease existing = pendingReleases.get(mapping);
        boolean wasAlreadyDown = existing != null ? existing.wasAlreadyDown() : mapping.isDown();
        mapping.setDown(true);
        KeyMappingAccessor accessor = (KeyMappingAccessor) (Object) mapping;
        int currentClicks = accessor.veq$getClickCount();
        if (currentClicks < Integer.MAX_VALUE) {
            accessor.veq$setClickCount(currentClicks + 1);
        }
        pendingReleases.put(mapping, new PendingRelease(wasAlreadyDown, 2));
        return true;
    }

    private Component getKeybindDisplayName(String mappingName) {
        KeyMapping mapping = findKeyMapping(mappingName);
        return mapping == null
                ? Component.literal(mappingName)
                : Component.translatable(mapping.getName());
    }

    private static @Nullable KeyMapping xaeroFallback(Minecraft minecraft, String mappingName) {
        if (!"key.xaero_open_map".equalsIgnoreCase(mappingName)) {
            return null;
        }
        return Arrays.stream(minecraft.options.keyMappings)
                .filter(mapping -> isXaeroWorldMapMapping(mapping.getName()))
                .findFirst()
                .orElse(null);
    }

    static boolean isXaeroWorldMapMapping(String mappingName) {
        if (mappingName == null) {
            return false;
        }
        String name = mappingName.toLowerCase(java.util.Locale.ROOT);
        // Xaero's Minimap exposes gui.xaero_toggle_map. It must not satisfy a
        // button labelled World Map when the separate World Map mod is absent.
        return name.contains("xaero")
                && !name.contains("minimap")
                && (name.contains("open_map") || name.contains("world_map"));
    }

    private void load(boolean migrateLegacy) {
        futureVersionReadOnly = false;
        if (!Files.isRegularFile(configFile)) {
            if (migrateLegacy) {
                migrateLegacyActions();
            }
            save();
            return;
        }
        boolean rewrite;
        try (Reader reader = Files.newBufferedReader(configFile, StandardCharsets.UTF_8)) {
            StoredConfig stored = GSON.fromJson(reader, StoredConfig.class);
            if (stored == null || stored.actions == null) {
                throw new JsonParseException("Missing actions array");
            }
            futureVersionReadOnly = stored.version > CONFIG_VERSION;
            rewrite = !futureVersionReadOnly &&
                    (stored.version < CONFIG_VERSION || stored.actions.size() != SLOT_COUNT);
            List<QuickActionDefinition> loaded = new ArrayList<>(SLOT_COUNT);
            for (int slot = 0; slot < SLOT_COUNT; slot++) {
                StoredAction entry = slot < stored.actions.size() ? stored.actions.get(slot) : null;
                loaded.add(fromStored(entry));
            }
            actions.clear();
            actions.addAll(loaded);
        } catch (IOException | RuntimeException exception) {
            VivecraftEssentialsQuest.LOGGER.error(
                    "Could not load quick actions from {}; keeping current actions",
                    configFile,
                    exception
            );
            return;
        }
        if (rewrite) {
            save();
        }
    }

    private void migrateLegacyActions() {
        WristUiConfig legacy = WristUiConfig.getInstance();
        for (int slot = 0; slot < SLOT_COUNT; slot++) {
            QuickActionDefinition action = legacy.quickAction(slot);
            actions.set(slot, action == null ? QuickActionDefinition.empty() : action);
        }
    }

    private synchronized void save() {
        if (futureVersionReadOnly) {
            return;
        }
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
            VivecraftEssentialsQuest.LOGGER.error("Could not save quick actions to {}", configFile, exception);
            try {
                Files.deleteIfExists(temporary);
            } catch (IOException ignored) {
                // Preserve the original failure.
            }
        }
    }

    private void resetInMemory() {
        actions.clear();
        actions.addAll(Collections.nCopies(SLOT_COUNT, QuickActionDefinition.empty()));
    }

    private static QuickActionDefinition fromStored(@Nullable StoredAction stored) {
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

    private static StoredAction toStored(QuickActionDefinition action) {
        StoredAction stored = new StoredAction();
        stored.type = action.type().name();
        stored.displayName = action.displayName();
        stored.iconItemId = action.iconItemId();
        stored.value = action.value();
        return stored;
    }

    private static void checkSlot(int slot) {
        if (slot < 0 || slot >= SLOT_COUNT) {
            throw new IndexOutOfBoundsException(
                    "Quick action slot must be between 0 and " + (SLOT_COUNT - 1)
            );
        }
    }

    public record KeybindOption(String id, Component displayName, Component boundKey) {
    }

    private record PendingRelease(boolean wasAlreadyDown, int ticksRemaining) {
        private PendingRelease nextTick() {
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
