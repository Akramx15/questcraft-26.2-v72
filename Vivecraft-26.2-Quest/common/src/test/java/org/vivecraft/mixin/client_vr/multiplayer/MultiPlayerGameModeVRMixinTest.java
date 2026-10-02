package org.vivecraft.mixin.client_vr.multiplayer;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.spongepowered.asm.mixin.Unique;
import org.vivecraft.api.data.VRBodyPart;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Map;

class MultiPlayerGameModeVRMixinTest {
    @Test
    void onlyExplicitItemHandsPinTheDestroyingItemCheck() throws Exception {
        Method helper = MultiPlayerGameModeVRMixin.class.getDeclaredMethod(
            "vivecraft$hasPinnedDestroyOwner", VRBodyPart.class);
        Assertions.assertTrue(Modifier.isPrivate(helper.getModifiers()),
            "Mixin helper methods must be private to pass runtime validation");
        Assertions.assertTrue(Modifier.isStatic(helper.getModifiers()));
        Assertions.assertTrue(helper.isAnnotationPresent(Unique.class));
        helper.setAccessible(true);

        Assertions.assertTrue((boolean) helper.invoke(null, VRBodyPart.MAIN_HAND));
        Assertions.assertTrue((boolean) helper.invoke(null, VRBodyPart.OFF_HAND));

        Assertions.assertFalse((boolean) helper.invoke(null, new Object[] {null}));
        Assertions.assertFalse((boolean) helper.invoke(null, VRBodyPart.HEAD));
        Assertions.assertFalse((boolean) helper.invoke(null, VRBodyPart.RIGHT_FOOT));
        Assertions.assertFalse((boolean) helper.invoke(null, VRBodyPart.LEFT_FOOT));
    }

    @Test
    void nativeRtToolSwapCannotBorrowMatchingOldToolFromOffhand() throws Exception {
        Method resolver = MultiPlayerGameModeVRMixin.class.getDeclaredMethod(
            "vivecraft$resolvePinnedDestroyOwner", VRBodyPart.class, VRBodyPart.class);
        Assertions.assertTrue(Modifier.isPrivate(resolver.getModifiers()),
            "Mixin helper methods must be private to pass runtime validation");
        Assertions.assertTrue(Modifier.isStatic(resolver.getModifiers()));
        Assertions.assertTrue(resolver.isAnnotationPresent(Unique.class));
        resolver.setAccessible(true);

        String originalRtTool = "diamond_pickaxe";
        Map<VRBodyPart, String> currentTools = Map.of(
            VRBodyPart.MAIN_HAND, "iron_pickaxe",
            VRBodyPart.OFF_HAND, originalRtTool);

        // Vanilla RT begins without BODY_PART_CLIENT_OVERRIDE. The coordinator
        // nevertheless pins MAIN_HAND for the lifetime of the destroy session.
        VRBodyPart owner = (VRBodyPart) resolver.invoke(
            null, null, VRBodyPart.MAIN_HAND);
        Assertions.assertEquals(VRBodyPart.MAIN_HAND, owner);
        Assertions.assertNotEquals(originalRtTool, currentTools.get(owner),
            "changing the RT tool must end the main-hand destroy session");

        Assertions.assertEquals(originalRtTool, currentTools.get(VRBodyPart.OFF_HAND),
            "the fixture must retain the old RT tool in offhand");
        Assertions.assertTrue(currentTools.values().contains(originalRtTool),
            "the former either-hand fallback would falsely keep this session alive");
    }

    @Test
    void explicitScopedOwnerStillWinsCoordinatorFallback() throws Exception {
        Method resolver = MultiPlayerGameModeVRMixin.class.getDeclaredMethod(
            "vivecraft$resolvePinnedDestroyOwner", VRBodyPart.class, VRBodyPart.class);
        resolver.setAccessible(true);

        Assertions.assertEquals(VRBodyPart.OFF_HAND,
            resolver.invoke(null, VRBodyPart.OFF_HAND, VRBodyPart.MAIN_HAND));
        Assertions.assertNull(resolver.invoke(null, VRBodyPart.HEAD, VRBodyPart.LEFT_FOOT));
    }
}
