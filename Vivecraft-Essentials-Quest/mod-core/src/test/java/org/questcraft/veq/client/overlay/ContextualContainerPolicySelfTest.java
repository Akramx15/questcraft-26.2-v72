package org.questcraft.veq.client.overlay;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/** Host-only decision-table coverage for contextual container claiming. */
public final class ContextualContainerPolicySelfTest {
    private ContextualContainerPolicySelfTest() {
    }

    public static void main(String[] args) throws IOException {
        require(claim(true, true, true, true, true, false, false, true, false),
                "a live tracked server-owned container should be claimable");
        require(!claim(false, true, true, true, true, false, false, true, false),
                "disabled contextual containers must stay native");
        require(!claim(true, false, true, true, true, false, false, true, false),
                "world loss must release the claim");
        require(!claim(true, true, false, true, true, false, false, true, false),
                "death must release the claim");
        require(!claim(true, true, true, false, true, false, false, true, false),
                "tracking loss must release the claim");
        require(!claim(true, true, true, true, false, false, false, true, false),
                "non-container screens are never claimed");
        require(!claim(true, true, true, true, true, true, false, true, true),
                "the ordinary player inventory stays on the wrist inventory path");
        require(!claim(true, true, true, true, true, false, true, true, false),
                "the native creative inventory stays on the creative wrist path");
        require(!claim(true, true, true, true, true, false, false, false, false),
                "a stale screen/menu pair must not be claimed");
        require(!claim(true, true, true, true, true, false, false, true, true),
                "the player inventory menu must not masquerade as contextual");
        pointerOwnershipContract();
        exactGlobalScreenContract();
        containerCancelGuardContract();
        contextualCancelCapabilityContract();
        subclassLatchCancellationContract();
        subclassLatchMixinBytecodeContract();
        trackingClaimContract();
        containerCancelSourceContract();
        System.out.println("ContextualContainerPolicySelfTest PASS");
    }

    private static void contextualCancelCapabilityContract() {
        String base = "net.minecraft.client.gui.screens.inventory.AbstractContainerScreen";
        String creative = "net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen";
        String loom = "net.minecraft.client.gui.screens.inventory.LoomScreen";
        String stonecutter = "net.minecraft.client.gui.screens.inventory.StonecutterScreen";
        String merchant = "net.minecraft.client.gui.screens.inventory.MerchantScreen";

        require(ContextualCancelCapability.isSafeReleaseOwner(base, "", true, false),
                "a container using only AbstractContainerScreen release needs no subclass hook");
        require(!ContextualCancelCapability.isSafeReleaseOwner(base, "", false, false),
                "a missing base container cancel bridge must fail closed");
        for (String knownOwner : List.of(creative, loom, stonecutter, merchant)) {
            require(ContextualCancelCapability.isSafeReleaseOwner(
                            knownOwner, knownOwner, true, true),
                    "known release owner must be accepted with its cancel-only hook: " + knownOwner);
            require(!ContextualCancelCapability.isSafeReleaseOwner(
                            knownOwner, "", true, false),
                    "known release owner must fail closed when its mixin hook is missing: " + knownOwner);
        }
        require(!ContextualCancelCapability.isSafeReleaseOwner(
                        "example.mod.inventory.CustomDragScreen", "", true, false),
                "an unknown mouseReleased override without a cancel hook must fail closed");
        require(!ContextualCancelCapability.isSafeReleaseOwner(
                        "example.mod.inventory.CustomDragScreen", loom, true, true),
                "inheriting a known hook cannot make an unknown override safe");
        require(ContextualCancelCapability.isSafeReleaseOwner(
                        "example.mod.inventory.CustomDragScreen",
                        "example.mod.inventory.CustomDragScreen",
                        true,
                        true),
                "an unknown release owner may opt in only with its own explicit cancel hook");
        require(!ContextualCancelCapability.isSafeReleaseOwner(
                        "example.mod.inventory.CustomDragScreen",
                        "example.mod.inventory.CustomDragScreen",
                        true,
                        false),
                "a coincidental method name without the cancel interface is not a capability");
    }

    private static void subclassLatchCancellationContract() {
        for (String owner : List.of(
                "CreativeModeInventoryScreen.scrolling",
                "LoomScreen.scrolling",
                "StonecutterScreen.scrolling",
                "MerchantScreen.isDragging"
        )) {
            PointerPressOwnership<Object, String, String> press = new PointerPressOwnership<>();
            Object screen = new Object();
            SubclassLatchProbe probe = new SubclassLatchProbe();

            require(press.capture(screen, "LEFT", "PRIMARY", true),
                    owner + " must capture the scrollbar/merchant down edge");
            var cancel = press.cancel();
            require(cancel.disposition() == PointerPressOwnership.Disposition.CANCEL,
                    owner + " off-plane/tracking teardown must cancel");
            probe.complete(cancel);

            require(!probe.latched, owner + " cancel-only hook must clear the private latch");
            require(probe.subclassReleaseCalls == 0,
                    owner + " cancel must not invoke the virtual subclass mouseReleased");
            require(probe.slotPackets == 0,
                    owner + " cancel must not transact a slot or emit a packet");
            var physicalUp = press.finish(screen, "LEFT", true);
            require(physicalUp.disposition() == PointerPressOwnership.Disposition.NONE,
                    owner + " physical up after cancel must be a no-op");
            probe.complete(physicalUp);

            probe.unrelatedDrag();
            require(probe.unrelatedDragEffects == 0,
                    owner + " next unrelated slot drag must not inherit the old latch");
        }
    }

    private static final class SubclassLatchProbe {
        private boolean latched = true;
        private int subclassReleaseCalls;
        private int slotPackets;
        private int unrelatedDragEffects;

        private void complete(PointerPressOwnership.Completion<Object, String, String> completion) {
            if (completion.disposition() == PointerPressOwnership.Disposition.CANCEL) {
                latched = ContainerSubclassLatchPolicy.clear(latched);
            } else if (completion.disposition() == PointerPressOwnership.Disposition.RELEASE) {
                virtualSubclassRelease();
            }
        }

        private void virtualSubclassRelease() {
            subclassReleaseCalls++;
            slotPackets++;
            latched = false;
        }

        private void unrelatedDrag() {
            if (latched) {
                unrelatedDragEffects++;
            }
        }
    }

    private static void subclassLatchMixinBytecodeContract() throws IOException {
        String[][] mixins = {
                {"org/questcraft/veq/mixin/CreativeScrollCancelMixin.class", "scrolling"},
                {"org/questcraft/veq/mixin/LoomScrollCancelMixin.class", "scrolling"},
                {"org/questcraft/veq/mixin/StonecutterScrollCancelMixin.class", "scrolling"},
                {"org/questcraft/veq/mixin/MerchantDragCancelMixin.class", "isDragging"}
        };
        for (String[] mixin : mixins) {
            byte[] bytecode;
            try (InputStream stream = ContextualContainerPolicySelfTest.class
                    .getClassLoader().getResourceAsStream(mixin[0])) {
                require(stream != null, "missing compiled cancel mixin: " + mixin[0]);
                bytecode = stream.readAllBytes();
            }
            String constants = new String(bytecode, StandardCharsets.ISO_8859_1);
            require(constants.contains("veq$cancelOwnedPointerGesture"),
                    mixin[0] + " is missing the cancel-only interface method");
            require(constants.contains(mixin[1]),
                    mixin[0] + " is missing its exact private latch field");
            require(constants.contains("ContainerSubclassLatchPolicy")
                            && constants.contains("clear"),
                    mixin[0] + " must clear through the idempotent cancel policy");
            require(!constants.contains("mouseReleased"),
                    mixin[0] + " must not invoke or override virtual mouseReleased");
        }

        String mixinConfig = Files.readString(sourcePath(
                "src/main/resources/vivecraft_essentials_quest.mixins.json"
        ));
        for (String[] mixin : mixins) {
            String simpleName = mixin[0].substring(
                    mixin[0].lastIndexOf('/') + 1,
                    mixin[0].length() - ".class".length()
            );
            require(mixinConfig.contains('"' + simpleName + '"'),
                    "mixin config must register cancel hook: " + simpleName);
        }
    }

    private static void trackingClaimContract() {
        require(ContextualTrackingClaimPolicy.retain(false, true, true),
                "tracking loss must retain an exact active carried owner");
        require(!ContextualTrackingClaimPolicy.retain(false, true, false),
                "tracking loss without a carried owner must release the claim");
        require(!ContextualTrackingClaimPolicy.retain(false, false, true),
                "death/menu/world invalidation must not retain the claim");
        require(!ContextualTrackingClaimPolicy.retain(true, true, true),
                "normal tracking does not need the retention exception");
    }

    private static void exactGlobalScreenContract() {
        Object screenA = new Object();
        Object screenB = new Object();
        require(ExactScreenClaim.isCurrent(
                        screenA, screenA, screenA, screenA, true),
                "the exact active/feature/global screen should remain claimed");
        require(!ExactScreenClaim.isCurrent(
                        screenA, screenA, screenA, screenB, true),
                "a synchronous global screen transition must invalidate the old press");
        PointerPressOwnership<Object, String, String> press = new PointerPressOwnership<>();
        require(press.capture(screenA, "LEFT", "PRIMARY", true),
                "global-mismatch gesture must start captured");
        Object current = ExactScreenClaim.isCurrent(
                screenA, screenA, screenA, screenB, true) ? screenA : null;
        require(press.finish(current, "LEFT", true).disposition()
                        == PointerPressOwnership.Disposition.CANCEL,
                "global Minecraft screen mismatch must cancel before release");
        require(!ExactScreenClaim.isCurrent(
                        screenA, screenA, screenB, screenA, true),
                "feature-layer transition must invalidate the old press");
        require(!ExactScreenClaim.isCurrent(
                        screenA, screenA, screenA, screenA, false),
                "an inactive claim must invalidate the old press");
    }

    private static void containerCancelGuardContract() {
        ContainerPointerCancelGuard guard = new ContainerPointerCancelGuard();
        int[] widgetRelease = {0};
        int[] reset = {0};
        int[] slotTransactions = {0};
        require(guard.cancel(() -> {
            widgetRelease[0]++;
            require(!guard.cancel(
                            () -> slotTransactions[0]++,
                            () -> reset[0]++),
                    "reentrant cancellation must be rejected");
        }, () -> reset[0]++), "first cancellation must run");
        require(widgetRelease[0] == 1,
                "cancel must deliver one physical-up to Screen widgets");
        require(reset[0] == 1,
                "cancel must reset container gesture state exactly once");
        require(slotTransactions[0] == 0,
                "cancel-only path must not run a slot transaction callback");
        require(!guard.isCancelling(), "cancel guard leaked after completion");
    }

    private static void pointerOwnershipContract() {
        Object screenA = new Object();
        Object screenB = new Object();
        PointerPressOwnership<Object, String, String> press = new PointerPressOwnership<>();

        require(press.capture(screenA, "LEFT", "PRIMARY", true),
                "accepted down edge must capture its exact owner");
        var outside = press.finish(screenA, "LEFT", true);
        require(outside.disposition() == PointerPressOwnership.Disposition.RELEASE,
                "an exact current plane coordinate must release normally, even outside bounds");
        require(outside.screen() == screenA && "LEFT".equals(outside.controller())
                        && "PRIMARY".equals(outside.button()),
                "release must retain screen/controller/button identity");
        require(press.finish(screenA, "LEFT", true).disposition()
                        == PointerPressOwnership.Disposition.NONE,
                "physical up after completion must be a no-op");

        require(press.capture(screenA, "RIGHT", "SECONDARY", true),
                "second gesture should capture after completion");
        var transition = press.finish(screenB, "RIGHT", true);
        require(transition.disposition() == PointerPressOwnership.Disposition.CANCEL
                        && transition.screen() == screenA,
                "screen transition must cancel the old owner, never release the new screen");

        require(press.capture(screenA, "RIGHT", "PRIMARY", true),
                "tracking-loss gesture should capture");
        var trackingLoss = press.finish(screenA, "RIGHT", false);
        require(trackingLoss.disposition() == PointerPressOwnership.Disposition.CANCEL,
                "missing exact coordinates must cancel instead of replaying a stale slot");

        require(press.capture(screenA, "LEFT", "PRIMARY", true),
                "teardown gesture should capture");
        var teardown = press.cancel();
        require(teardown.disposition() == PointerPressOwnership.Disposition.CANCEL
                        && teardown.screen() == screenA,
                "teardown must cancel the exact pressed screen");
        require(press.cancel().disposition() == PointerPressOwnership.Disposition.NONE,
                "teardown cancellation must be one-shot");

        require(press.capture(screenA, "LEFT", "PRIMARY", true),
                "wrong-hand scenario should capture");
        require(press.finish(screenA, "RIGHT", true).disposition()
                        == PointerPressOwnership.Disposition.CANCEL,
                "another hand cannot steal or finish the gesture");
        require(!press.capture(screenA, "LEFT", "PRIMARY", false),
                "a rejected click must never create release ownership");
    }

    private static void containerCancelSourceContract() throws IOException {
        Path mixin = sourcePath(
                "src/main/java/org/questcraft/veq/mixin/EmbeddedContainerScreenMixin.java"
        );
        String source = Files.readString(mixin);
        String[] required = {
                "veq$cancelGuard.cancel(",
                "() -> super.mouseReleased(releaseEvent)",
                "setDragging(false)",
                "isQuickCrafting = false",
                "quickCraftSlots.clear()",
                "skipNextRelease = false",
                "doubleclick = false",
                "lastClickSlot = null",
                "lastQuickMoved = ItemStack.EMPTY"
        };
        for (String marker : required) {
            require(source.contains(marker), "container cancellation is missing: " + marker);
        }
        require(!source.contains("slotClicked("),
                "cancel must not synthesize a container transaction");
        require(!source.contains("getCarried("),
                "cancel must not alter or inspect the carried stack");
        require(!source.contains("connection.send("),
                "cancel must not send a packet");
        require(!source.contains("((AbstractContainerScreen"),
                "cancel must not dispatch a virtual container release");
        require(!source.contains("@Inject(method = \"mouseReleased\""),
                "cancel-only bridge must not hook ordinary native releases");

        String safeRelease = Files.readString(sourcePath(
                "src/main/java/org/questcraft/veq/client/overlay/SafeScreenPointerRelease.java"
        ));
        int subclassCancel = safeRelease.indexOf("ownedCancellation.veq$cancelOwnedPointerGesture()");
        int baseCancel = safeRelease.indexOf("cancellation.veq$cancelPointerGesture(event)");
        require(subclassCancel >= 0 && baseCancel > subclassCancel,
                "subclass latch cleanup must run before direct Screen/base cancellation");
        require(safeRelease.contains("if (screen instanceof AbstractContainerScreen<?>)")
                        && safeRelease.contains("return;"),
                "a missing base cancellation bridge must fail closed");

        String wrist = Files.readString(sourcePath(
                "src/main/java/org/questcraft/veq/client/gui/VepWristInventoryScreen.java"
        ));
        require(wrist.contains("implements EmbeddedSlotLayout, VepScreenContent, "
                        + "VeqOwnedPointerCancellation"),
                "VEQ screen must expose an explicit cancel-only flag hook");
        require(wrist.contains("void veq$cancelOwnedPointerGesture()")
                        && wrist.contains("quickActionPress = false")
                        && wrist.contains("utilityActionPress = false"),
                "VEQ-owned press flags must clear without virtual release");
    }

    private static Path sourcePath(String relative) {
        Path direct = Path.of(relative);
        if (Files.isRegularFile(direct)) {
            return direct;
        }
        Path fromRoot = Path.of("Vivecraft-Essentials-Quest", "mod-core").resolve(relative);
        if (Files.isRegularFile(fromRoot)) {
            return fromRoot;
        }
        throw new IllegalStateException("Could not locate source contract: " + relative);
    }

    private static boolean claim(boolean featureEnabled,
                                 boolean worldPresent,
                                 boolean playerAlive,
                                 boolean controllersTracked,
                                 boolean isContainerScreen,
                                 boolean isPlayerInventoryScreen,
                                 boolean isCreativeInventoryScreen,
                                 boolean menuMatchesPlayer,
                                 boolean isPlayerInventoryMenu) {
        return ContextualContainerPolicy.shouldClaim(
                featureEnabled,
                worldPresent,
                playerAlive,
                controllersTracked,
                isContainerScreen,
                isPlayerInventoryScreen,
                isCreativeInventoryScreen,
                menuMatchesPlayer,
                isPlayerInventoryMenu
        );
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
