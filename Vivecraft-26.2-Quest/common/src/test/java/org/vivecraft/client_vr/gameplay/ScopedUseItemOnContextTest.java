package org.vivecraft.client_vr.gameplay;

import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.provider.ControllerType;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class ScopedUseItemOnContextTest {
    private static final double EPSILON = 1.0E-6D;

    @Test
    void translatedMenuUseRetainsLogicalLeftAndExactHit() {
        Vec3 origin = new Vec3(1.0D, 2.0D, 3.0D);
        Vec3 direction = new Vec3(2.0D, 0.0D, 0.0D);
        BlockHitResult hit = new BlockHitResult(
            new Vec3(4.0D, 2.5D, 3.0D), Direction.WEST,
            new BlockPos(4, 2, 3), false);

        Assertions.assertNull(ScopedUseItemOnContext.current());
        try (ScopedUseItemOnContext.Scope ignored =
                 ScopedUseItemOnContext.openTranslatedLeft(
                     ControllerType.LEFT, origin, direction, hit)) {
            ScopedUseItemOnContext.Snapshot snapshot = ScopedUseItemOnContext.current();
            Assertions.assertNotNull(snapshot);
            Assertions.assertEquals(ControllerType.LEFT, snapshot.logicalController());
            Assertions.assertEquals(origin, snapshot.rayOrigin());
            Assertions.assertEquals(new Vec3(1.0D, 0.0D, 0.0D), snapshot.rayDirection());
            Assertions.assertEquals(hit.getLocation(), snapshot.hitLocation());
            Assertions.assertEquals(hit.getBlockPos(), snapshot.blockPosition());
            Assertions.assertEquals(Direction.WEST, snapshot.hitFace());

            var look = snapshot.lookDirection(new Vec3(1.0D, 2.5D, 3.0D));
            Assertions.assertEquals(1.0D, look.x(), EPSILON);
            Assertions.assertEquals(0.0D, look.y(), EPSILON);
            Assertions.assertEquals(0.0D, look.z(), EPSILON);
        }
        Assertions.assertNull(ScopedUseItemOnContext.current(),
            "the translated controller ray must never leak past useItemOn");
    }

    @Test
    void scopeRestoresAfterExceptionAndRejectsAnyOtherController() {
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> ScopedUseItemOnContext.openTranslatedLeft(
                ControllerType.RIGHT, Vec3.ZERO, new Vec3(0.0D, 0.0D, 1.0D),
                BlockHitResult.miss(Vec3.ZERO, Direction.UP, BlockPos.ZERO)));

        Assertions.assertThrows(IllegalStateException.class, () -> {
            try (ScopedUseItemOnContext.Scope ignored =
                     ScopedUseItemOnContext.openTranslatedLeft(
                         ControllerType.LEFT, Vec3.ZERO,
                         new Vec3(0.0D, 0.0D, 1.0D),
                         BlockHitResult.miss(Vec3.ZERO, Direction.UP, BlockPos.ZERO))) {
                throw new IllegalStateException("synthetic useItemOn failure");
            }
        });
        Assertions.assertNull(ScopedUseItemOnContext.current());
    }

    @Test
    void useItemOnMixinPrefersScopedRayAndRestoresLookInFinally() throws IOException {
        String source = Files.readString(Path.of(
            "src", "main", "java", "org", "vivecraft", "mixin", "client_vr",
            "multiplayer", "MultiPlayerGameModeVRMixin.java"));
        int useOn = source.indexOf("vivecraft$useOnLookOverride");
        int scopedLookup = source.indexOf("ScopedUseItemOnContext.current()", useOn);
        int scopedLook = source.indexOf("translated.lookDirection", scopedLookup);
        int ordinalFallback = source.indexOf("hand.ordinal()", scopedLook);
        Assertions.assertTrue(useOn >= 0 && scopedLookup > useOn &&
            scopedLook > scopedLookup && ordinalFallback > scopedLook,
            "translated useItemOn must prefer its immutable scoped ray before hand fallback");

        int wrapper = source.indexOf("vivecraft$wrapWithLookOverride");
        int finallyBlock = source.indexOf("finally", wrapper);
        int restore = source.indexOf("ClientNetworking.restoreLook()", finallyBlock);
        Assertions.assertTrue(finallyBlock > wrapper && restore > finallyBlock,
            "server look override must be cleared even when useItemOn throws");
    }
}
