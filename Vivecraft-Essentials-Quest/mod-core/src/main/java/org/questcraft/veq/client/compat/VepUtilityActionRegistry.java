package org.questcraft.veq.client.compat;

import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.ItemStack;
import org.questcraft.veq.client.quickactions.QuickActionDefinition;
import org.questcraft.veq.client.quickactions.QuickActionManager;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.function.Predicate;
import java.util.function.Supplier;

/** Extensible VEP utility-button registry with no hard optional-mod links. */
public final class VepUtilityActionRegistry {
    private static final VepUtilityActionRegistry INSTANCE = new VepUtilityActionRegistry();
    private static final Predicate<UtilityAction> IS_VISIBLE =
            action -> action.visible().getAsBoolean();

    private final Map<String, UtilityAction> actions = new LinkedHashMap<>();
    private final VepVisibleListCache<UtilityAction> visibleActionCache =
            new VepVisibleListCache<>();
    private volatile List<UtilityAction> visibleActionSnapshot = List.of();
    private volatile long visibleActionRevision;
    private long lastFeatureRevision = Long.MIN_VALUE;
    private int lastKeyMappingCount = -1;

    private VepUtilityActionRegistry() {
    }

    public static VepUtilityActionRegistry getInstance() {
        return INSTANCE;
    }

    public synchronized void register(String id,
                                      ItemStack icon,
                                      Component tooltip,
                                      BooleanSupplier visible,
                                      BooleanSupplier toggled,
                                      Runnable action) {
        ItemStack safeIcon = icon == null ? ItemStack.EMPTY : icon.copy();
        register(id, () -> safeIcon, tooltip, visible, toggled, action);
    }

    private synchronized void register(String id,
                                       Supplier<ItemStack> icon,
                                       Component tooltip,
                                       BooleanSupplier visible,
                                       BooleanSupplier toggled,
                                       Runnable action) {
        if (id == null || id.isBlank()) {
            throw new IllegalArgumentException("Utility action id is blank");
        }
        actions.put(id, new UtilityAction(
                icon == null ? () -> ItemStack.EMPTY : icon,
                tooltip == null ? Component.literal(id) : tooltip,
                visible == null ? () -> true : visible,
                toggled == null ? () -> false : toggled,
                action == null ? () -> { } : action
        ));
    }

    public synchronized void unregister(String id) {
        actions.remove(id);
    }

    public List<UtilityAction> visibleActions() {
        return visibleActionSnapshot;
    }

    /**
     * Monotonic generation for bounds that depend on visible utility rows.
     * Refreshing here also observes arbitrary registered visibility suppliers;
     * unchanged membership reuses the same immutable list without allocation.
     */
    public long visibleLayoutRevision() {
        return visibleActionRevision;
    }

    /** Registers key-mapping backed helpers for optional mods that are present. */
    public synchronized void discoverOptionalActions() {
        for (VepOptionalIntegrations.Integration integration
                : VepOptionalIntegrations.Integration.values()) {
            VepOptionalIntegrations.Availability availability =
                    VepOptionalIntegrations.find(integration);
            String id = integration.name().toLowerCase(java.util.Locale.ROOT);
            if (!availability.available()) {
                actions.remove(id);
                continue;
            }
            String itemId = switch (integration) {
                case XAERO_MINIMAP -> "minecraft:map";
                case XAERO_WORLD_MAP -> "minecraft:filled_map";
                case JEI -> "minecraft:knowledge_book";
                case INVENTORY_PROFILES_NEXT -> "minecraft:chest";
            };
            Identifier iconId = Identifier.parse(itemId);
            Supplier<ItemStack> icon = deferUntilReady(
                    () -> BuiltInRegistries.ITEM.get(iconId)
                            .map(holder -> holder.areComponentsBound())
                            .orElse(true),
                    () -> BuiltInRegistries.ITEM.get(iconId)
                            .map(ItemStack::new)
                            .orElse(ItemStack.EMPTY),
                    ItemStack.EMPTY
            );
            String mapping = availability.keyMappingName();
            register(
                    id,
                    icon,
                    Component.literal(integration.name().replace('_', ' ')),
                    () -> VepOptionalIntegrations.isEnabled(integration),
                    () -> false,
                    () -> QuickActionManager.getInstance().execute(
                            QuickActionDefinition.keybind(
                                    integration.name(),
                                    itemId,
                                    mapping
                            )
                    )
            );
        }
        var minecraft = net.minecraft.client.Minecraft.getInstance();
        lastFeatureRevision = org.questcraft.veq.client.config.VepFeatureConfig.getInstance().revision();
        lastKeyMappingCount = minecraft.options == null ? -1 : minecraft.options.keyMappings.length;
        refreshVisibleSnapshot();
    }

    /** Refreshes after settings edits or late optional-mod key registration. */
    public synchronized void refreshOptionalActionsIfNeeded() {
        var minecraft = net.minecraft.client.Minecraft.getInstance();
        long revision = org.questcraft.veq.client.config.VepFeatureConfig.getInstance().revision();
        int keyMappingCount = minecraft.options == null ? -1 : minecraft.options.keyMappings.length;
        if (revision != lastFeatureRevision || keyMappingCount != lastKeyMappingCount) {
            discoverOptionalActions();
        } else {
            // Visibility suppliers may depend on gameplay state rather than a
            // config generation. Evaluate them once per client tick here,
            // never from the per-frame Wrist bounds/render path.
            refreshVisibleSnapshot();
        }
    }

    private void refreshVisibleSnapshot() {
        visibleActionSnapshot = visibleActionCache.refresh(actions.values(), IS_VISIBLE);
        visibleActionRevision = visibleActionCache.revision();
    }

    /**
     * Defers a value until its explicit readiness predicate succeeds, then
     * resolves and caches it exactly once. In 26.2 an Item holder can be
     * registered before its data components are bound; this gate prevents an
     * early ItemStack constructor from throwing during client initialization.
     */
    static <T> Supplier<T> deferUntilReady(BooleanSupplier ready,
                                           Supplier<T> factory,
                                           T fallback) {
        return new Supplier<>() {
            private boolean resolved;
            private T value;

            @Override
            public synchronized T get() {
                if (!resolved && ready.getAsBoolean()) {
                    value = factory.get();
                    resolved = true;
                }
                return resolved ? value : fallback;
            }
        };
    }

    public record UtilityAction(Supplier<ItemStack> iconSupplier,
                                Component tooltip,
                                BooleanSupplier visible,
                                BooleanSupplier toggled,
                                Runnable action) {
        public ItemStack icon() {
            ItemStack icon = iconSupplier.get();
            return icon == null ? ItemStack.EMPTY : icon;
        }
    }
}
