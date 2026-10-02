package org.vmstudio.essentials.core.client.gui;

import net.minecraft.client.gui.screens.Screen;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.HitResult;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.vmstudio.visor.api.client.gui.overlays.VROverlay;

/**
 * Retired Visor compatibility shim.
 *
 * <p>Quest's active VEQ artifact compiles only {@code org.questcraft.veq} and
 * delegates contextual-container placement to Vivecraft's ordinary
 * player-relative GUI plane. This historical namespace is retained for LGPL
 * attribution and source compatibility only. It must never create a second
 * pose owner or close a server-owned menu by client distance.</p>
 *
 * @deprecated Vivecraft's native screen is the sole placement and lifecycle
 * owner.
 */
@Deprecated(forRemoval = true)
public final class NativeContainerPlacement {
    private NativeContainerPlacement() {
        throw new UnsupportedOperationException("Utility class");
    }

    public static void rememberInteraction(@NotNull BlockHitResult blockHit) {
    }

    public static void rememberInteraction(@NotNull EntityHitResult entityHit) {
    }

    public static void clearPendingInteraction() {
    }

    public static boolean attach(@NotNull Screen nativeScreen, @Nullable HitResult hitResult) {
        return false;
    }

    public static void retarget(@NotNull Screen nativeScreen) {
    }

    public static void clear() {
    }

    public static boolean isActive() {
        return false;
    }

    public static boolean isActiveFor(@Nullable Screen candidate) {
        return false;
    }

    public static void tickDistanceClose() {
        // Server menu validity owns lifetime. Never call closeContainer here.
    }

    public static boolean applyTo(@NotNull VROverlay gameScreen, float partialTick) {
        return false;
    }
}
