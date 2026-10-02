package org.questcraft.veq.client.input;

import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.phys.Vec3;
import org.questcraft.veq.VivecraftEssentialsQuest;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collection;
import java.util.List;

/** Optional cached bridge; VEQ remains loadable when ImmersiveMC is absent. */
public final class ImmersiveMcInputAdapter {
    private static boolean initialized;
    private static boolean available;
    private static boolean failureLogged;
    private static List<?> immersives;
    private static Method getTrackedObjects;
    private static Method getSlotHovered;
    private static Method getDragHitbox;
    private static Method boundingBoxContains;

    private ImmersiveMcInputAdapter() {
    }

    public static boolean claimsHand(InteractionHand hand, Vec3 handPosition) {
        initialize();
        if (!available || hand == null || handPosition == null) {
            return false;
        }
        try {
            for (Object immersive : immersives) {
                Collection<?> infos = (Collection<?>) getTrackedObjects.invoke(immersive);
                for (Object info : infos) {
                    if ((int) getSlotHovered.invoke(info, hand.ordinal()) >= 0) {
                        return true;
                    }
                    Object dragHitbox = getDragHitbox.invoke(immersive, info);
                    if (dragHitbox != null &&
                            (boolean) boundingBoxContains.invoke(null, dragHitbox, handPosition)) {
                        return true;
                    }
                }
            }
        } catch (ReflectiveOperationException | RuntimeException | LinkageError exception) {
            disable(exception);
        }
        return false;
    }

    private static synchronized void initialize() {
        if (initialized) {
            return;
        }
        initialized = true;
        if (!FabricLoader.getInstance().isModLoaded("immersivemc")) {
            return;
        }
        try {
            Class<?> immersivesClass = Class.forName(
                    "com.hammy275.immersivemc.client.immersive.Immersives");
            Class<?> immersiveClass = Class.forName(
                    "com.hammy275.immersivemc.api.client.immersive.Immersive");
            Class<?> infoClass = Class.forName(
                    "com.hammy275.immersivemc.api.client.immersive.ImmersiveInfo");
            Class<?> boundingBoxClass = Class.forName(
                    "com.hammy275.immersivemc.api.common.hitbox.BoundingBox");
            Field allImmersives = immersivesClass.getField("ALL_IMMERSIVES");
            immersives = (List<?>) allImmersives.get(null);
            getTrackedObjects = immersiveClass.getMethod("getTrackedObjects");
            getSlotHovered = infoClass.getMethod("getSlotHovered", int.class);
            getDragHitbox = immersiveClass.getMethod("getDragHitbox", infoClass);
            boundingBoxContains = boundingBoxClass.getMethod("contains", boundingBoxClass, Vec3.class);
            available = true;
        } catch (ReflectiveOperationException | RuntimeException | LinkageError exception) {
            disable(exception);
        }
    }

    private static void disable(Throwable throwable) {
        available = false;
        if (!failureLogged) {
            failureLogged = true;
            VivecraftEssentialsQuest.LOGGER.warn(
                    "ImmersiveMC hand-ownership adapter disabled; Grip remains fail-safe", throwable);
        }
    }
}
