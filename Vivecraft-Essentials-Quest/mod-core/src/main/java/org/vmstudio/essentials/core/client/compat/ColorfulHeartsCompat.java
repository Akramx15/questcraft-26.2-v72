package org.vmstudio.essentials.core.client.compat;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.resources.Identifier;
import net.minecraft.util.Mth;
import net.minecraft.world.entity.player.Player;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.ModLoader;

import java.lang.reflect.Method;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Optional bridge for Colorful Hearts' configured heart drawings.
 *
 * <p>All references to Colorful Hearts remain reflective so the addon keeps a
 * clean class path when that mod is absent. A failed signature probe or render
 * permanently disables this bridge for the current session and lets the
 * caller use its normal VisorEssentials fallback.</p>
 */
public final class ColorfulHeartsCompat {
    private static final String MOD_ID = "colorfulhearts";
    private static final int HEART_COUNT = 10;
    private static final int HEART_SPACING = 8;
    private static final int HEART_SIZE = 9;
    private static final Identifier HEART_CONTAINER =
            Identifier.fromNamespaceAndPath("minecraft", "hud/heart/container");
    private static final Logger LOGGER = LogManager.getLogger(
            VisorEssentials.MOD_NAME + "/ColorfulHeartsCompat"
    );
    private static final AtomicBoolean FAILURE_LOGGED = new AtomicBoolean();
    private static final boolean MOD_LOADED = isModLoaded();

    private static volatile boolean disabled;

    private ColorfulHeartsCompat() {
        throw new UnsupportedOperationException("Utility class");
    }

    /**
     * Draws ten horizontal heart positions using Colorful Hearts' current
     * palette and status-effect overlay.
     *
     * <p>Absorption is deliberately excluded here. The wrist HUD keeps its
     * existing absorption treatment and tooltip, avoiding a second heart row
     * that would not fit the compact wrist layout.</p>
     *
     * @return {@code true} when this bridge handled the heart row, or
     *         {@code false} when the caller should render its normal fallback
     */
    public static boolean drawHorizontalHealth(@NotNull GuiGraphicsExtractor graphics,
                                               @NotNull Player player,
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
            Object optionalOverlay = backend.getOverlayHeartForPlayer()
                    .invoke(null, player);
            if (!(optionalOverlay instanceof Optional<?> optional)) {
                throw new IllegalStateException(
                        "Colorful Hearts returned an unexpected overlay value"
                );
            }

            int currentHealth = Math.max(0, Mth.ceil(player.getHealth()));
            int maximumHealth = Math.max(
                    currentHealth,
                    Math.max(0, Mth.ceil(player.getMaxHealth()))
            );
            Object calculated = backend.calculateHearts().invoke(
                    null,
                    optional.orElse(null),
                    currentHealth,
                    maximumHealth,
                    0
            );
            if (!(calculated instanceof Object[] hearts)) {
                throw new IllegalStateException(
                        "Colorful Hearts returned an unexpected heart array"
                );
            }

            boolean hardcore = player.level().getLevelData().isHardcore();
            for (int slot = 0; slot < HEART_COUNT; slot++) {
                int drawX = x + slot * HEART_SPACING;
                graphics.blitSprite(
                        RenderPipelines.GUI_TEXTURED,
                        HEART_CONTAINER,
                        drawX,
                        y,
                        HEART_SIZE,
                        HEART_SIZE
                );

                if (slot < hearts.length && hearts[slot] != null) {
                    backend.drawHeart().invoke(
                            hearts[slot],
                            graphics,
                            drawX,
                            y,
                            hardcore,
                            false,
                            false
                    );
                }
            }
            return true;
        } catch (ReflectiveOperationException | RuntimeException | LinkageError exception) {
            disable("rendering the wrist heart row", exception);
            return false;
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
            ClassLoader loader = ColorfulHeartsCompat.class.getClassLoader();
            Class<?> heartsClass = Class.forName(
                    "terrails.colorfulhearts.api.heart.Hearts",
                    false,
                    loader
            );
            Class<?> overlayHeartClass = Class.forName(
                    "terrails.colorfulhearts.api.heart.drawing.OverlayHeart",
                    false,
                    loader
            );
            Class<?> heartClass = Class.forName(
                    "terrails.colorfulhearts.api.heart.drawing.Heart",
                    false,
                    loader
            );
            Class<?> heartUtilsClass = Class.forName(
                    "terrails.colorfulhearts.render.HeartUtils",
                    false,
                    loader
            );

            return new Backend(
                    heartsClass.getMethod("getOverlayHeartForPlayer", Player.class),
                    heartUtilsClass.getMethod(
                            "calculateHearts",
                            overlayHeartClass,
                            int.class,
                            int.class,
                            int.class
                    ),
                    heartClass.getMethod(
                            "draw",
                            GuiGraphicsExtractor.class,
                            int.class,
                            int.class,
                            boolean.class,
                            boolean.class,
                            boolean.class
                    )
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
                    "Disabling optional Colorful Hearts wrist compatibility after an error while {}",
                    operation,
                    exception
            );
        }
    }

    private record Backend(Method getOverlayHeartForPlayer,
                           Method calculateHearts,
                           Method drawHeart) {
    }

    private static final class BackendHolder {
        private static final @Nullable Backend INSTANCE = createBackend();

        private BackendHolder() {
        }
    }
}
