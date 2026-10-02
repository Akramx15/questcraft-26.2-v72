package org.vmstudio.essentials.core.client.compat;

import net.minecraft.client.Minecraft;
import net.minecraft.network.chat.Component;
import net.minecraft.world.inventory.AbstractContainerMenu;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.vmstudio.essentials.core.client.gui.overlays.VROverlayInventory;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.ModLoader;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicBoolean;

/** Optional, wrist-only bridge to Inventory Profiles Next's sorting actions. */
public final class InventoryProfilesNextCompat {
    private static final String MOD_ID = "inventoryprofilesnext";
    private static final String ACTION_PREFIX = "inventoryprofilesnext:";
    private static final Logger LOGGER = LogManager.getLogger(
            VisorEssentials.MOD_NAME + "/InventoryProfilesNextCompat"
    );
    private static final AtomicBoolean FAILURE_LOGGED = new AtomicBoolean();
    private static final boolean MOD_LOADED = isModLoaded();

    private static volatile boolean disabled;

    private InventoryProfilesNextCompat() {
        throw new UnsupportedOperationException("Utility class");
    }

    /**
     * Adds only IPN's three player-inventory sort actions to the custom wrist.
     * IPN's normal screen injection is deliberately not initialized here, so
     * its desktop editor/profile widgets (and unrelated overlays such as JEI)
     * cannot leak into the embedded wrist screen.
     */
    public static void registerWristActions(@NotNull VROverlayInventory overlay) {
        if (!MOD_LOADED || BackendHolder.INSTANCE == null || disabled) {
            return;
        }

        try {
            // Construct every icon first so component-binding failures cannot
            // leave a partially registered group of buttons.
            ItemStack regularIcon = new ItemStack(Items.COMPASS);
            ItemStack columnsIcon = new ItemStack(Items.IRON_BARS);
            ItemStack rowsIcon = new ItemStack(Items.LADDER);

            overlay.setUtilityAction(
                    ACTION_PREFIX + "sort",
                    regularIcon,
                    Component.translatable("inventoryprofiles.tooltip.sort_button"),
                    InventoryProfilesNextCompat::canSortPlayerInventory,
                    () -> sort(SortMode.REGULAR)
            );
            overlay.setUtilityAction(
                    ACTION_PREFIX + "columns",
                    columnsIcon,
                    Component.translatable("inventoryprofiles.tooltip.sort_columns_button"),
                    InventoryProfilesNextCompat::canSortPlayerInventory,
                    () -> sort(SortMode.COLUMNS)
            );
            overlay.setUtilityAction(
                    ACTION_PREFIX + "rows",
                    rowsIcon,
                    Component.translatable("inventoryprofiles.tooltip.sort_rows_button"),
                    InventoryProfilesNextCompat::canSortPlayerInventory,
                    () -> sort(SortMode.ROWS)
            );
        } catch (RuntimeException | LinkageError exception) {
            // Optional compatibility must never abort Visor initialization.
            disable("registering wrist buttons", exception);
        }
    }

    private static boolean canSortPlayerInventory() {
        Minecraft minecraft = Minecraft.getInstance();
        return !disabled
                && minecraft.player != null
                && minecraft.player.containerMenu == minecraft.player.inventoryMenu;
    }

    private static void sort(@NotNull SortMode mode) {
        Backend backend = BackendHolder.INSTANCE;
        Minecraft minecraft = Minecraft.getInstance();
        if (disabled || backend == null || minecraft.player == null) {
            return;
        }

        AbstractContainerMenu menu = minecraft.player.inventoryMenu;
        if (minecraft.player.containerMenu != menu) {
            return;
        }

        try {
            mode.method(backend).invoke(backend.instance(), menu, true, true);
        } catch (ReflectiveOperationException | RuntimeException | LinkageError exception) {
            disable("sorting the wrist inventory", exception);
        }
    }

    private static boolean isModLoaded() {
        try {
            return ModLoader.get().isModLoaded(MOD_ID);
        } catch (RuntimeException | LinkageError ignored) {
            return false;
        }
    }

    private static @Nullable Backend createBackend() {
        if (!MOD_LOADED) {
            return null;
        }

        try {
            Class<?> actionsClass = Class.forName(
                    "org.anti_ad.mc.ipnext.inventory.GeneralInventoryActions",
                    false,
                    InventoryProfilesNextCompat.class.getClassLoader()
            );
            Field instanceField = actionsClass.getField("INSTANCE");
            Object instance = instanceField.get(null);
            Method regular = actionsClass.getMethod(
                    "doSort", AbstractContainerMenu.class,
                    boolean.class, boolean.class
            );
            Method columns = actionsClass.getMethod(
                    "doSortInColumns", AbstractContainerMenu.class,
                    boolean.class, boolean.class
            );
            Method rows = actionsClass.getMethod(
                    "doSortInRows", AbstractContainerMenu.class,
                    boolean.class, boolean.class
            );
            return new Backend(instance, regular, columns, rows);
        } catch (ReflectiveOperationException | RuntimeException | LinkageError exception) {
            disable("initializing the compatibility bridge", exception);
            return null;
        }
    }

    private static void disable(@NotNull String operation,
                                @NotNull Throwable exception) {
        disabled = true;
        if (FAILURE_LOGGED.compareAndSet(false, true)) {
            LOGGER.warn(
                    "Disabling optional Inventory Profiles Next wrist compatibility after an error while {}",
                    operation,
                    exception
            );
        }
    }

    private enum SortMode {
        REGULAR,
        COLUMNS,
        ROWS;

        private Method method(@NotNull Backend backend) {
            return switch (this) {
                case REGULAR -> backend.regular();
                case COLUMNS -> backend.columns();
                case ROWS -> backend.rows();
            };
        }
    }

    private record Backend(Object instance,
                           Method regular,
                           Method columns,
                           Method rows) {
    }

    private static final class BackendHolder {
        private static final @Nullable Backend INSTANCE = createBackend();

        private BackendHolder() {
        }
    }
}
