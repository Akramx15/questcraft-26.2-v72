package org.vmstudio.essentials.core.client.compat;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.resources.Identifier;
import net.minecraft.util.ARGB;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.ModLoader;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Optional bridge for Overloaded Armor Bar's configured armor tiers.
 *
 * <p>The mod does not expose a formal renderer API, so this class probes only
 * the small public calculation result used by its own overlay. No optional mod
 * types appear in VisorEssentials' class signatures.</p>
 */
public final class OverloadedArmorBarCompat {
    private static final String MOD_ID = "overloadedarmorbar";
    private static final int ARMOR_ICON_COUNT = 10;
    private static final int ARMOR_ICON_SPACING = 8;
    private static final int ARMOR_ICON_SIZE = 9;
    private static final Identifier ARMOR_EMPTY =
            Identifier.fromNamespaceAndPath("minecraft", "hud/armor_empty");
    private static final Identifier ARMOR_HALF =
            Identifier.fromNamespaceAndPath("minecraft", "hud/armor_half");
    private static final Identifier ARMOR_FULL =
            Identifier.fromNamespaceAndPath("minecraft", "hud/armor_full");
    private static final Logger LOGGER = LogManager.getLogger(
            VisorEssentials.MOD_NAME + "/OverloadedArmorBarCompat"
    );
    private static final AtomicBoolean FAILURE_LOGGED = new AtomicBoolean();
    private static final boolean MOD_LOADED = isModLoaded();

    private static volatile boolean disabled;

    private OverloadedArmorBarCompat() {
        throw new UnsupportedOperationException("Utility class");
    }

    /**
     * Draws ten horizontal armor positions using Overloaded Armor Bar's live
     * tier colors, including its split-color half icon above twenty armor.
     *
     * @return {@code true} when this bridge handled the armor row, or
     *         {@code false} when the caller should render its normal fallback
     */
    public static boolean drawHorizontalArmor(@NotNull GuiGraphicsExtractor graphics,
                                              int armorValue,
                                              int x,
                                              int y) {
        if (!MOD_LOADED || disabled) {
            return false;
        }

        Backend backend = BackendHolder.INSTANCE;
        if (backend == null || disabled) {
            return false;
        }

        try {
            int safeArmorValue = Math.max(0, armorValue);
            Object calculated = backend.calculateArmorIcons().invoke(
                    null,
                    safeArmorValue
            );
            if (!(calculated instanceof Object[] icons)
                    || icons.length < ARMOR_ICON_COUNT) {
                throw new IllegalStateException(
                        "Overloaded Armor Bar returned an unexpected icon array"
                );
            }

            for (int slot = 0; slot < ARMOR_ICON_COUNT; slot++) {
                Object icon = icons[slot];
                if (icon == null) {
                    throw new IllegalStateException(
                            "Overloaded Armor Bar returned a null armor icon"
                    );
                }

                Object type = backend.iconType().get(icon);
                String typeName = type instanceof Enum<?> enumValue
                        ? enumValue.name()
                        : String.valueOf(type);
                Color primary = backend.readPrimaryColor(icon);
                int drawX = x + slot * ARMOR_ICON_SPACING;

                switch (typeName) {
                    case "NONE" -> {
                        if (safeArmorValue > 20) {
                            drawTintedSprite(graphics, ARMOR_FULL, drawX, y, primary);
                        } else {
                            drawTintedSprite(graphics, ARMOR_EMPTY, drawX, y, primary);
                        }
                    }
                    case "HALF" -> {
                        drawTintedSprite(graphics, ARMOR_HALF, drawX, y, primary);
                        if (safeArmorValue > 20) {
                            Color secondary = backend.readSecondaryColor(icon);
                            graphics.blitSprite(
                                    RenderPipelines.GUI_TEXTURED,
                                    ARMOR_FULL,
                                    ARMOR_ICON_SIZE,
                                    ARMOR_ICON_SIZE,
                                    5,
                                    0,
                                    drawX + 5,
                                    y,
                                    4,
                                    ARMOR_ICON_SIZE,
                                    secondary.asArgb()
                            );
                        }
                    }
                    case "FULL" -> drawTintedSprite(
                            graphics,
                            ARMOR_FULL,
                            drawX,
                            y,
                            primary
                    );
                    default -> throw new IllegalStateException(
                            "Unknown Overloaded Armor Bar icon type: " + typeName
                    );
                }
            }
            return true;
        } catch (ReflectiveOperationException | RuntimeException | LinkageError exception) {
            disable("rendering the wrist armor row", exception);
            return false;
        }
    }

    private static void drawTintedSprite(@NotNull GuiGraphicsExtractor graphics,
                                         @NotNull Identifier sprite,
                                         int x,
                                         int y,
                                         @NotNull Color color) {
        graphics.blitSprite(
                RenderPipelines.GUI_TEXTURED,
                sprite,
                x,
                y,
                ARMOR_ICON_SIZE,
                ARMOR_ICON_SIZE,
                color.asArgb()
        );
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
            ClassLoader loader = OverloadedArmorBarCompat.class.getClassLoader();
            Class<?> armorBarClass = Class.forName(
                    "tfar.overloadedarmorbar.overlay.ArmorBar",
                    false,
                    loader
            );
            Class<?> armorIconClass = Class.forName(
                    "tfar.overloadedarmorbar.overlay.ArmorIcon",
                    false,
                    loader
            );
            Class<?> colorClass = Class.forName(
                    "tfar.overloadedarmorbar.overlay.ArmorIconColor",
                    false,
                    loader
            );

            return new Backend(
                    armorBarClass.getMethod("calculateArmorIcons", int.class),
                    armorIconClass.getField("armorIconType"),
                    armorIconClass.getField("primaryArmorIconColor"),
                    armorIconClass.getField("secondaryArmorIconColor"),
                    colorClass.getField("Red"),
                    colorClass.getField("Green"),
                    colorClass.getField("Blue"),
                    colorClass.getField("Alpha")
            );
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
                    "Disabling optional Overloaded Armor Bar wrist compatibility after an error while {}",
                    operation,
                    exception
            );
        }
    }

    private record Color(float red, float green, float blue, float alpha) {
        private Color {
            red = normalized(red);
            green = normalized(green);
            blue = normalized(blue);
            alpha = normalized(alpha);
        }

        private static float normalized(float value) {
            return Float.isFinite(value)
                    ? Math.max(0.0F, Math.min(1.0F, value))
                    : 1.0F;
        }

        private int asArgb() {
            return ARGB.colorFromFloat(alpha, red, green, blue);
        }
    }

    private record Backend(Method calculateArmorIcons,
                           Field iconType,
                           Field primaryColor,
                           Field secondaryColor,
                           Field red,
                           Field green,
                           Field blue,
                           Field alpha) {
        private @NotNull Color readPrimaryColor(@NotNull Object icon)
                throws IllegalAccessException {
            return readColor(primaryColor.get(icon));
        }

        private @NotNull Color readSecondaryColor(@NotNull Object icon)
                throws IllegalAccessException {
            return readColor(secondaryColor.get(icon));
        }

        private @NotNull Color readColor(@Nullable Object color)
                throws IllegalAccessException {
            if (color == null) {
                return new Color(1.0F, 1.0F, 1.0F, 1.0F);
            }
            return new Color(
                    red.getFloat(color),
                    green.getFloat(color),
                    blue.getFloat(color),
                    alpha.getFloat(color)
            );
        }
    }

    private static final class BackendHolder {
        private static final @Nullable Backend INSTANCE = createBackend();

        private BackendHolder() {
        }
    }
}
