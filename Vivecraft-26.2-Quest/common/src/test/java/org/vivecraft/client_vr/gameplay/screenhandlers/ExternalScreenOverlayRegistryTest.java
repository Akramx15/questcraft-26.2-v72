package org.vivecraft.client_vr.gameplay.screenhandlers;

import net.minecraft.SharedConstants;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.core.Holder;
import net.minecraft.core.component.DataComponentMap;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.provider.ControllerType;

import java.util.ArrayList;
import java.util.List;

class ExternalScreenOverlayRegistryTest {
    @BeforeAll
    static void bootstrapMinecraftRegistries() {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
    }

    @BeforeEach
    void setUp() {
        ExternalScreenOverlayHandler.resetRegistryForTests();
    }

    @AfterEach
    void tearDown() {
        ExternalScreenOverlayHandler.resetRegistryForTests();
    }

    @Test
    void registersIndependentSurfacesAndSortsLowToHighPriority() {
        FakeSurface high = new FakeSurface("high", 20);
        FakeSurface low = new FakeSurface("low", -5);

        ExternalScreenOverlayHandler.OverlayHandle highHandle =
            ExternalScreenOverlayHandler.registerSurface(high);
        ExternalScreenOverlayHandler.OverlayHandle lowHandle =
            ExternalScreenOverlayHandler.registerSurface(low);

        List<ExternalScreenOverlayHandler.OverlayHandle> visible = new ArrayList<>();
        ExternalScreenOverlayHandler.copyVisibleSurfaces(visible);
        Assertions.assertEquals(List.of(lowHandle, highHandle), visible);
        Assertions.assertSame(highHandle, ExternalScreenOverlayHandler.findSurface("high"));
        Assertions.assertThrows(IllegalStateException.class,
            () -> ExternalScreenOverlayHandler.registerSurface(new FakeSurface("high", 99)));

        lowHandle.close();
        Assertions.assertFalse(lowHandle.isRegistered());
        Assertions.assertEquals(List.of(highHandle), ExternalScreenOverlayHandler.surfaces());
    }

    @Test
    void resolvesFocusPerHandAndHonorsLogicalBounds() {
        FakeSurface low = new FakeSurface("low", 0);
        FakeSurface high = new FakeSurface("high", 10);
        high.bounds = new ExternalScreenOverlayHandler.SurfaceBounds(10, 10, 20, 20);
        low.cursor(ControllerType.LEFT).set(50, 50, ControllerType.LEFT, true, true, false);
        low.cursor(ControllerType.RIGHT).set(60, 60, ControllerType.RIGHT, true, true, false);
        high.cursor(ControllerType.LEFT).set(20, 20, ControllerType.LEFT, true, true, false);

        ExternalScreenOverlayHandler.OverlayHandle lowHandle =
            ExternalScreenOverlayHandler.registerSurface(low);
        ExternalScreenOverlayHandler.OverlayHandle highHandle =
            ExternalScreenOverlayHandler.registerSurface(high);
        ExternalScreenOverlayHandler.processGui();

        Assertions.assertTrue(highHandle.isFocused(ControllerType.LEFT));
        Assertions.assertFalse(lowHandle.isFocused(ControllerType.LEFT));
        Assertions.assertTrue(lowHandle.isFocused(ControllerType.RIGHT));
        Assertions.assertTrue(ExternalScreenOverlayHandler.isUsingController(ControllerType.LEFT));
        Assertions.assertTrue(ExternalScreenOverlayHandler.isUsingController(ControllerType.RIGHT));

        high.cursor(ControllerType.LEFT).set(5, 5, ControllerType.LEFT, true, true, false);
        ExternalScreenOverlayHandler.processGui();
        Assertions.assertFalse(highHandle.isFocused(ControllerType.LEFT));
        Assertions.assertTrue(lowHandle.isFocused(ControllerType.LEFT));

        low.showing = false;
        Assertions.assertFalse(ExternalScreenOverlayHandler.isUsingController(ControllerType.LEFT),
            "a hidden surface must stop cancelling that hand before the next input poll");
        ExternalScreenOverlayHandler.processGui();
        Assertions.assertFalse(lowHandle.isFocused(ControllerType.LEFT));
    }

    @Test
    void explicitSurfaceSessionOwnsControllerBeforeNextFocusPass() {
        FakeSurface surface = new FakeSurface("new-session", 10);
        surface.using[ControllerType.RIGHT.ordinal()] = true;
        ExternalScreenOverlayHandler.registerSurface(surface);

        Assertions.assertTrue(ExternalScreenOverlayHandler.isUsingController(ControllerType.RIGHT),
            "a surface opened during bindings must own its hand immediately");
        Assertions.assertFalse(ExternalScreenOverlayHandler.isUsingController(ControllerType.LEFT));

        surface.showing = false;
        Assertions.assertFalse(ExternalScreenOverlayHandler.isUsingController(ControllerType.RIGHT),
            "a hidden session must release ownership without waiting for focus refresh");
    }

    @Test
    void secondaryPriorityDoesNotStealWorldButtonsFromNonPointerOverlays() {
        FakeSurface obscuredPointer = new FakeSurface("obscured-pointer", 5);
        obscuredPointer.using[ControllerType.RIGHT.ordinal()] = true;
        ExternalScreenOverlayHandler.registerSurface(obscuredPointer);

        FakeSurface grip = new FakeSurface("grip", 10) {
            @Override
            public boolean handlesPointerEvents() {
                return false;
            }
        };
        grip.using[ControllerType.RIGHT.ordinal()] = true;
        ExternalScreenOverlayHandler.registerSurface(grip);

        Assertions.assertTrue(ExternalScreenOverlayHandler.isUsingController(ControllerType.RIGHT));
        Assertions.assertFalse(
            ExternalScreenOverlayHandler.isUsingPointerController(ControllerType.RIGHT),
            "a higher-priority Grip-style surface must leave A/Jump live");
        ExternalScreenOverlayHandler.processGui();
        Assertions.assertFalse(
            ExternalScreenOverlayHandler.isUsingPointerController(ControllerType.RIGHT),
            "resolved non-pointer focus must not fall through to an obscured pointer surface");

        FakeSurface wrist = new FakeSurface("wrist", 20);
        wrist.using[ControllerType.LEFT.ordinal()] = true;
        ExternalScreenOverlayHandler.registerSurface(wrist);
        Assertions.assertTrue(
            ExternalScreenOverlayHandler.isUsingPointerController(ControllerType.LEFT),
            "an explicit pointer session must suppress X Teleport before its next focus pass");
        Assertions.assertFalse(
            ExternalScreenOverlayHandler.isUsingPointerController(ControllerType.RIGHT),
            "the opposite pointer hand must not suppress A/Jump");
    }

    @Test
    void pressedSurfaceOwnsDragAndReleaseWhenFocusMoves() {
        FakeSurface first = new FakeSurface("first", 0);
        FakeSurface second = new FakeSurface("second", 10);
        second.showing = false;
        first.cursor(ControllerType.LEFT).set(10, 10, ControllerType.LEFT, true, true, false);
        second.cursor(ControllerType.LEFT).set(20, 20, ControllerType.LEFT, true, true, false);

        ExternalScreenOverlayHandler.registerSurface(first);
        ExternalScreenOverlayHandler.registerSurface(second);
        ExternalScreenOverlayHandler.processGui();
        ExternalScreenOverlayHandler.processPointerButton(ControllerType.LEFT, true, true);
        Assertions.assertEquals(1, first.pressCount);
        Assertions.assertTrue(ExternalScreenOverlayHandler.isUsingController(ControllerType.LEFT));

        second.showing = true;
        first.cursor(ControllerType.LEFT).set(14, 12, ControllerType.LEFT, true, true, true);
        ExternalScreenOverlayHandler.processGui();
        Assertions.assertEquals(1, first.dragCount);
        Assertions.assertEquals(0, second.dragCount);

        ExternalScreenOverlayHandler.processPointerButton(ControllerType.LEFT, false, false);
        Assertions.assertEquals(1, first.releaseCount);
        Assertions.assertEquals(0, second.releaseCount);
    }

    @Test
    void preservesButtonIdentityOutsideBoundsAndCancelsInvalidTracking() {
        FakeSurface surface = new FakeSurface("buttons", 0);
        surface.cursor(ControllerType.LEFT).set(20, 20, ControllerType.LEFT, true, true, false);
        ExternalScreenOverlayHandler.registerSurface(surface);
        ExternalScreenOverlayHandler.processGui();

        ExternalScreenOverlayHandler.processPointerButton(
            ControllerType.LEFT, ExternalScreenOverlayHandler.PointerButton.SECONDARY, true, true);
        Assertions.assertEquals(List.of(ExternalScreenOverlayHandler.PointerButton.SECONDARY),
            surface.pressedButtons);

        surface.cursor(ControllerType.LEFT).set(-25, 140, ControllerType.LEFT, true, false, true);
        ExternalScreenOverlayHandler.processGui();
        Assertions.assertEquals(List.of(ExternalScreenOverlayHandler.PointerButton.SECONDARY),
            surface.draggedButtons, "drag must keep its button outside logical bounds");
        ExternalScreenOverlayHandler.processPointerButton(
            ControllerType.LEFT, ExternalScreenOverlayHandler.PointerButton.SECONDARY, false, false);
        Assertions.assertEquals(List.of(ExternalScreenOverlayHandler.PointerButton.SECONDARY),
            surface.releasedButtons);
        Assertions.assertEquals(-25.0D, surface.lastReleaseX,
            "release must use the real off-bounds coordinate");

        surface.cursor(ControllerType.LEFT).set(30, 30, ControllerType.LEFT, true, true, false);
        ExternalScreenOverlayHandler.processGui();
        ExternalScreenOverlayHandler.processPointerButton(
            ControllerType.LEFT, ExternalScreenOverlayHandler.PointerButton.MIDDLE, true, true);
        surface.cursor(ControllerType.LEFT).setInvalid();
        ExternalScreenOverlayHandler.processGui();
        Assertions.assertEquals(List.of(ExternalScreenOverlayHandler.PointerButton.MIDDLE),
            surface.cancelledButtons, "tracking loss must cancel instead of replaying a slot");
        Assertions.assertEquals(1, surface.releaseCount,
            "tracking cancellation must not synthesize another release");
    }

    @Test
    void dispatchesScrollOnlyToFocusedController() {
        FakeSurface surface = new FakeSurface("scroll", 0);
        surface.cursor(ControllerType.RIGHT).set(45, 55, ControllerType.RIGHT, true, true, false);
        ExternalScreenOverlayHandler.registerSurface(surface);
        ExternalScreenOverlayHandler.processGui();

        ExternalScreenOverlayHandler.processPointerScroll(ControllerType.RIGHT, -4.0D);
        ExternalScreenOverlayHandler.processPointerScroll(ControllerType.LEFT, 4.0D);

        Assertions.assertEquals(List.of(-4.0D), surface.scrollAmounts);
        Assertions.assertEquals(List.of(ControllerType.RIGHT), surface.scrollControllers);
    }

    @Test
    void legacySingleSurfaceApiStillResolvesPrimaryOverlay() {
        LegacySurface legacy = new LegacySurface("legacy", 0);
        ExternalScreenOverlayHandler.register(legacy);
        Assertions.assertSame(legacy, ExternalScreenOverlayHandler.overlay());
        ExternalScreenOverlayHandler.unregister(legacy);
        Assertions.assertNull(ExternalScreenOverlayHandler.overlay());
    }

    @Test
    void heldItemSuppressionRequiresAVisibleRegisteredSurfaceMatchingHandAndItem() {
        ItemStack shield = stackForPolicy(Items.SHIELD);
        ItemStack stone = stackForPolicy(Items.STONE);

        FakeSurface defaultSurface = new FakeSurface("default", 0);
        ExternalScreenOverlayHandler.registerSurface(defaultSurface);
        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.LEFT, shield), "default registered surfaces preserve every held item");

        FakeSurface wrist = new FakeSurface("wrist", 1);
        wrist.hiddenItemController = ControllerType.LEFT;
        wrist.hiddenItem = Items.SHIELD;
        ExternalScreenOverlayHandler.OverlayHandle wristHandle =
            ExternalScreenOverlayHandler.registerSurface(wrist);

        Assertions.assertTrue(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.LEFT, shield), "a visible Wrist may suppress its anchor-hand shield snapshot");
        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.RIGHT, shield), "the same shield remains visible in the opposite hand");
        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.LEFT, stone), "a non-shield stack in the anchor hand remains visible");
        Assertions.assertTrue(shield.is(Items.SHIELD));
        Assertions.assertEquals(1, shield.getCount(),
            "querying render suppression must not mutate the gameplay stack");

        wrist.showing = false;
        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.LEFT, shield), "a hidden Wrist cannot suppress a held-item snapshot");

        wrist.showing = true;
        wristHandle.close();
        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.LEFT, shield), "an unregistered Wrist cannot suppress a held-item snapshot");

        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            null, shield), "a missing controller never suppresses a held item");
        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.LEFT, null), "a missing render snapshot is preserved safely");
        Assertions.assertFalse(ExternalScreenOverlayHandler.shouldHideHeldItem(
            ControllerType.LEFT, ItemStack.EMPTY), "empty render snapshots are never suppressed");
    }

    private static ItemStack stackForPolicy(Item item) {
        // Host tests do not bootstrap a world registry. A direct holder keeps
        // the vanilla item identity while avoiding unrelated component data.
        return new ItemStack(Holder.direct(item, DataComponentMap.EMPTY));
    }

    @Test
    void defaultSurfaceInheritsOrdinaryWorldOcclusion() {
        FakeSurface surface = new FakeSurface("default-depth", 0);
        Assertions.assertEquals(
            org.vivecraft.client_vr.render.helpers.ExternalOverlayRenderPolicy.WorldOcclusion.INHERIT_GUI,
            surface.worldOcclusion());
    }

    private static class FakeSurface implements ExternalScreenOverlayHandler.OverlaySurface {
        private final String id;
        private final int priority;
        private final Matrix4f rotation = new Matrix4f();
        private final Vector3f position = new Vector3f();
        private final ExternalScreenOverlayHandler.RenderCursor[] cursors = {
            new ExternalScreenOverlayHandler.RenderCursor(),
            new ExternalScreenOverlayHandler.RenderCursor()
        };
        private final boolean[] using = new boolean[ControllerType.values().length];
        private ExternalScreenOverlayHandler.SurfaceBounds bounds =
            ExternalScreenOverlayHandler.SurfaceBounds.full();
        private boolean showing = true;
        private ControllerType hiddenItemController;
        private Item hiddenItem;
        private int pressCount;
        private int dragCount;
        private int releaseCount;
        private double lastReleaseX;
        private final List<ExternalScreenOverlayHandler.PointerButton> pressedButtons = new ArrayList<>();
        private final List<ExternalScreenOverlayHandler.PointerButton> draggedButtons = new ArrayList<>();
        private final List<ExternalScreenOverlayHandler.PointerButton> releasedButtons = new ArrayList<>();
        private final List<ExternalScreenOverlayHandler.PointerButton> cancelledButtons = new ArrayList<>();
        private final List<Double> scrollAmounts = new ArrayList<>();
        private final List<ControllerType> scrollControllers = new ArrayList<>();

        private FakeSurface(String id, int priority) {
            this.id = id;
            this.priority = priority;
        }

        @Override
        public String id() {
            return this.id;
        }

        @Override
        public String name() {
            return this.id;
        }

        @Override
        public Screen screen() {
            return null;
        }

        @Override
        public boolean hasCustomRenderer() {
            return true;
        }

        @Override
        public boolean isShowing() {
            return this.showing;
        }

        @Override
        public Vector3fc roomPosition() {
            return this.position;
        }

        @Override
        public Matrix4fc roomRotation() {
            return this.rotation;
        }

        @Override
        public float scale() {
            return 1.0F;
        }

        @Override
        public int priority() {
            return this.priority;
        }

        @Override
        public ExternalScreenOverlayHandler.SurfaceBounds bounds() {
            return this.bounds;
        }

        @Override
        public int scaledWidth() {
            return 100;
        }

        @Override
        public int scaledHeight() {
            return 100;
        }

        @Override
        public ExternalScreenOverlayHandler.RenderCursor cursor(ControllerType controller) {
            return this.cursors[controller.ordinal()];
        }

        @Override
        public boolean isUsingController(ControllerType controller) {
            return controller != null && this.using[controller.ordinal()];
        }

        @Override
        public boolean shouldHideHeldItem(ControllerType controller, ItemStack stack) {
            return controller == this.hiddenItemController && this.hiddenItem != null &&
                stack != null && stack.is(this.hiddenItem);
        }

        @Override
        public boolean handlesPointerEvents() {
            return true;
        }

        @Override
        public void pointerPressed(ControllerType controller,
                                   ExternalScreenOverlayHandler.RenderCursor cursor,
                                   ExternalScreenOverlayHandler.PointerButton button) {
            this.pressCount++;
            this.pressedButtons.add(button);
        }

        @Override
        public void pointerDragged(ControllerType controller,
                                   ExternalScreenOverlayHandler.RenderCursor cursor,
                                   ExternalScreenOverlayHandler.PointerButton button,
                                   double deltaX, double deltaY) {
            this.dragCount++;
            this.draggedButtons.add(button);
        }

        @Override
        public void pointerReleased(ControllerType controller,
                                    ExternalScreenOverlayHandler.RenderCursor cursor,
                                    ExternalScreenOverlayHandler.PointerButton button) {
            this.releaseCount++;
            this.releasedButtons.add(button);
            this.lastReleaseX = cursor.x();
        }

        @Override
        public void pointerCancelled(ControllerType controller,
                                     ExternalScreenOverlayHandler.PointerButton button) {
            this.cancelledButtons.add(button);
        }

        @Override
        public void pointerScrolled(ControllerType controller,
                                    ExternalScreenOverlayHandler.RenderCursor cursor,
                                    double amount) {
            this.scrollControllers.add(controller);
            this.scrollAmounts.add(amount);
        }
    }

    private static final class LegacySurface extends FakeSurface
        implements ExternalScreenOverlayHandler.Overlay
    {
        private LegacySurface(String id, int priority) {
            super(id, priority);
        }
    }
}
