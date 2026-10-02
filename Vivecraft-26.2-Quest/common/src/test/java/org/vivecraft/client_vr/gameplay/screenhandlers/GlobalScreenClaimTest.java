package org.vivecraft.client_vr.gameplay.screenhandlers;

import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import sun.misc.Unsafe;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

class GlobalScreenClaimTest {
    @BeforeEach
    void setUp() {
        ExternalScreenOverlayHandler.resetRegistryForTests();
        ExternalScreenOverlayHandler.setGlobalScreenCallbackDispatcherForTests(Runnable::run);
    }

    @AfterEach
    void tearDown() {
        ExternalScreenOverlayHandler.resetRegistryForTests();
    }

    @Test
    void rejectsMissingStaleAndCompetingClaims() {
        TestScreen current = createScreen(347, 219);
        TestScreen stale = createScreen(640, 360);

        Assertions.assertThrows(IllegalArgumentException.class,
            () -> ExternalScreenOverlayHandler.claimGlobalScreenAgainst(null, current, current, null));
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> ExternalScreenOverlayHandler.claimGlobalScreenAgainst("  ", current, current, null));
        Assertions.assertThrows(NullPointerException.class,
            () -> ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", null, null, null));
        Assertions.assertThrows(IllegalStateException.class,
            () -> ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", stale, current, null));

        ExternalScreenOverlayHandler.GlobalScreenClaim claim =
            ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", current, current, null);
        Assertions.assertThrows(IllegalStateException.class,
            () -> ExternalScreenOverlayHandler.claimGlobalScreenAgainst("other", current, current, null));
        Assertions.assertThrows(IllegalStateException.class,
            () -> ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", stale, stale, null));
        Assertions.assertTrue(claim.isActive());
    }

    @Test
    void repeatedOwnerAndIdentityReturnsTheSameHandle() {
        TestScreen screen = createScreen(347, 219);
        ExternalScreenOverlayHandler.GlobalScreenClaim first =
            ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", screen, screen, null);
        ExternalScreenOverlayHandler.GlobalScreenClaim second =
            ExternalScreenOverlayHandler.claimGlobalScreenAgainst(" veq ", screen, screen, null);

        Assertions.assertSame(first, second);
        Assertions.assertSame(screen, first.screen());
        Assertions.assertEquals("veq", first.ownerId());
        Assertions.assertSame(screen, ExternalScreenOverlayHandler.claimedGlobalScreen());
        Assertions.assertTrue(ExternalScreenOverlayHandler.isGlobalScreenClaimed(screen));
    }

    @Test
    void closingAHandleOnlyUnclaimsAndPreservesNativeLifecycleAndDimensions() {
        TestScreen screen = createScreen(347, 219);
        AtomicInteger callbackCount = new AtomicInteger();
        AtomicReference<ExternalScreenOverlayHandler.GlobalScreenLossReason> loss = new AtomicReference<>();
        ExternalScreenOverlayHandler.GlobalScreenClaim claim =
            ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", screen, screen, (lost, reason) -> {
                Assertions.assertSame(screen, lost);
                callbackCount.incrementAndGet();
                loss.set(reason);
            });

        claim.close();
        claim.close();

        Assertions.assertFalse(claim.isActive());
        Assertions.assertNull(ExternalScreenOverlayHandler.claimedGlobalScreen());
        Assertions.assertFalse(ExternalScreenOverlayHandler.isGlobalScreenClaimed(screen));
        Assertions.assertEquals(1, callbackCount.get());
        Assertions.assertEquals(ExternalScreenOverlayHandler.GlobalScreenLossReason.UNCLAIMED, loss.get());
        Assertions.assertEquals(0, screen.removedCalls);
        Assertions.assertEquals(0, screen.onCloseCalls);
        Assertions.assertEquals(347, screen.width);
        Assertions.assertEquals(219, screen.height);
    }

    @Test
    void replacementUnclaimsExactlyOnceBeforeLeavingLifecycleToVanilla() {
        TestScreen claimed = createScreen(347, 219);
        TestScreen replacement = createScreen(640, 360);
        AtomicInteger callbackCount = new AtomicInteger();
        AtomicReference<ExternalScreenOverlayHandler.GlobalScreenLossReason> loss = new AtomicReference<>();
        ExternalScreenOverlayHandler.GlobalScreenClaim claim =
            ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", claimed, claimed, (lost, reason) -> {
                Assertions.assertSame(claimed, lost);
                callbackCount.incrementAndGet();
                loss.set(reason);
            });

        ExternalScreenOverlayHandler.onGlobalScreenChanging(claimed, replacement);
        ExternalScreenOverlayHandler.onGlobalScreenChanging(claimed, replacement);

        Assertions.assertFalse(claim.isActive());
        Assertions.assertEquals(1, callbackCount.get());
        Assertions.assertEquals(ExternalScreenOverlayHandler.GlobalScreenLossReason.REPLACED, loss.get());
        Assertions.assertEquals(0, claimed.removedCalls);
        Assertions.assertEquals(0, claimed.onCloseCalls);
        Assertions.assertEquals(347, claimed.width);
        Assertions.assertEquals(219, claimed.height);
    }

    @Test
    void closingGlobalScreenReportsClosedButSettingSameIdentityKeepsClaim() {
        TestScreen screen = createScreen(347, 219);
        AtomicReference<ExternalScreenOverlayHandler.GlobalScreenLossReason> loss = new AtomicReference<>();
        ExternalScreenOverlayHandler.GlobalScreenClaim claim =
            ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", screen, screen,
                (lost, reason) -> loss.set(reason));

        ExternalScreenOverlayHandler.onGlobalScreenChanging(screen, screen);
        Assertions.assertTrue(claim.isActive());
        Assertions.assertNull(loss.get());

        ExternalScreenOverlayHandler.onGlobalScreenChanging(screen, null);
        Assertions.assertFalse(claim.isActive());
        Assertions.assertEquals(ExternalScreenOverlayHandler.GlobalScreenLossReason.CLOSED, loss.get());
        Assertions.assertEquals(0, screen.removedCalls);
        Assertions.assertEquals(0, screen.onCloseCalls);
    }

    @Test
    void listenerUsesConfiguredClientThreadDispatcher() {
        TestScreen screen = createScreen(347, 219);
        List<Runnable> queuedCallbacks = new ArrayList<>();
        AtomicInteger callbackCount = new AtomicInteger();
        ExternalScreenOverlayHandler.setGlobalScreenCallbackDispatcherForTests(queuedCallbacks::add);
        ExternalScreenOverlayHandler.GlobalScreenClaim claim =
            ExternalScreenOverlayHandler.claimGlobalScreenAgainst("veq", screen, screen,
                (lost, reason) -> callbackCount.incrementAndGet());

        claim.close();

        Assertions.assertFalse(claim.isActive(), "ownership must be released synchronously");
        Assertions.assertEquals(0, callbackCount.get());
        Assertions.assertEquals(1, queuedCallbacks.size());
        queuedCallbacks.getFirst().run();
        Assertions.assertEquals(1, callbackCount.get());
    }

    private static TestScreen createScreen(int width, int height) {
        try {
            Field field = Unsafe.class.getDeclaredField("theUnsafe");
            field.setAccessible(true);
            TestScreen screen = (TestScreen) ((Unsafe) field.get(null)).allocateInstance(TestScreen.class);
            screen.width = width;
            screen.height = height;
            return screen;
        } catch (ReflectiveOperationException exception) {
            throw new AssertionError("Could not allocate a lifecycle-only Screen test double", exception);
        }
    }

    private static final class TestScreen extends Screen {
        private int removedCalls;
        private int onCloseCalls;

        private TestScreen() {
            super(Component.empty());
        }

        @Override
        public void removed() {
            this.removedCalls++;
        }

        @Override
        public void onClose() {
            this.onCloseCalls++;
        }
    }
}
