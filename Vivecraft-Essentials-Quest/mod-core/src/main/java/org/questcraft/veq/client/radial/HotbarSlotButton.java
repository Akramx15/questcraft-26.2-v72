package org.questcraft.veq.client.radial;

import net.minecraft.client.Minecraft;
import net.minecraft.world.inventory.ContainerInput;
import net.minecraft.world.item.ItemStack;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.gameplay.screenhandlers.RadialHandler;
import org.vivecraft.client_vr.provider.ControllerType;

/**
 * Server-authoritative action behind the visual Grip selector.
 *
 * <p>The historical name is retained to keep the v63 integration surface
 * stable. v65 no longer creates desktop {@code Button} widgets: the selected
 * radial sector invokes this one-shot transaction directly on Grip release.</p>
 */
public final class HotbarSlotButton {
    private static final PendingSwapConfirmation PENDING_SWAP = new PendingSwapConfirmation();
    private static final GripSwapRejectionHandoff SWAP_REJECTION =
            new GripSwapRejectionHandoff();
    private static final OffhandAnchorState<ItemStack> OFFHAND_ANCHOR = new OffhandAnchorState<>();
    private static ItemStack expectedOffhand = ItemStack.EMPTY;
    private static ItemStack expectedHotbar = ItemStack.EMPTY;
    private static ControllerType pendingController;
    private static int pendingSlot = -1;
    private static InventorySessionIdentity pendingSession;

    private HotbarSlotButton() {
    }

    public static boolean select(ControllerType controller, int slot) {
        Minecraft minecraft = Minecraft.getInstance();
        if (slot < 0 || slot >= HotbarGridLayout.SLOT_COUNT || minecraft.player == null ||
                controller == null) {
            if (controller != null) {
                reject(controller, slot);
            }
            return false;
        }
        HotbarSelectionPolicy.Operation operation = HotbarSelectionPolicy.operationFor(controller);
        if (operation == HotbarSelectionPolicy.Operation.SELECT_MAIN_HAND) {
            minecraft.player.getInventory().setSelectedSlot(slot);
            accept(controller, slot);
            return true;
        }
        // A server-authoritative LEFT SWAP may still be reconciling, but it is
        // never a global selection lock. RIGHT remains an immediate local
        // hotbar choice; only a second LEFT transaction is rejected.
        if (GripSelectionAdmission.blockedByPendingLeftSwap(
                controller, PENDING_SWAP.isPending())) {
            reject(controller, slot);
            return false;
        }
        if (operation != HotbarSelectionPolicy.Operation.SWAP_WITH_OFFHAND ||
                !HotbarSelectionPolicy.canSwapToOffhand(
                        slot, minecraft.player.getInventory().getSelectedSlot())) {
            reject(controller, slot);
            return false;
        }
        // Selecting the currently visualized offhand is an idempotent accept,
        // not a second SWAP that would unexpectedly put it back in the hotbar.
        if (actualOffhandMarker(minecraft) == slot) {
            accept(controller, slot);
            return true;
        }
        if (minecraft.gameMode == null ||
                minecraft.player.containerMenu != minecraft.player.inventoryMenu ||
                !minecraft.player.inventoryMenu.getCarried().isEmpty()) {
            reject(controller, slot);
            return false;
        }

        InventorySessionIdentity session = currentSession(minecraft);
        if (session == null) {
            reject(controller, slot);
            return false;
        }

        ItemStack selectedBefore = minecraft.player.getInventory().getItem(slot).copy();
        ItemStack offhandBefore = minecraft.player.getOffhandItem().copy();
        HotbarSelectionPolicy.SwapPair<ItemStack> expected =
                HotbarSelectionPolicy.swapped(selectedBefore, offhandBefore);

        // Native ContainerInput.SWAP: one predicted mutation and one vanilla
        // server packet. The previous offhand stack returns to this exact slot.
        SWAP_REJECTION.clear();
        minecraft.gameMode.handleContainerInput(
                minecraft.player.inventoryMenu.containerId,
                HotbarSelectionPolicy.menuSlot(slot),
                HotbarSelectionPolicy.OFFHAND_SWAP_BUTTON,
                ContainerInput.SWAP,
                minecraft.player
        );

        // Prediction is not success. Wait for matching server contents and an
        // advanced state id before recording the independent left-hand choice.
        expectedHotbar = expected.hotbarAfter();
        expectedOffhand = expected.offhandAfter();
        pendingController = controller;
        pendingSlot = slot;
        pendingSession = session;
        PENDING_SWAP.begin();
        return true;
    }

    public static void reconcilePending(Minecraft minecraft) {
        InventorySessionIdentity currentSession = currentSession(minecraft);
        reconcileOffhandAnchor(minecraft, currentSession);
        if (!PENDING_SWAP.isPending()) {
            return;
        }
        if (currentSession == null || pendingSession == null ||
                !pendingSession.sameOwner(currentSession) ||
                minecraft.player.containerMenu != minecraft.player.inventoryMenu ||
                pendingController == null || pendingSlot < 0) {
            clearPendingTransaction();
            return;
        }
        ItemStack actualOffhand = minecraft.player.getOffhandItem();
        ItemStack actualHotbar = minecraft.player.getInventory().getItem(pendingSlot);
        boolean contentsMatch = sameStack(actualOffhand, expectedOffhand) &&
                sameStack(actualHotbar, expectedHotbar);
        boolean serverAdvanced = pendingSession.advancedTo(currentSession);
        finishPending(PENDING_SWAP.update(contentsMatch, serverAdvanced), currentSession);
    }

    public static boolean hasPendingSwap() {
        return PENDING_SWAP.isPending();
    }

    static GripSwapRejectionHandoff.Rejection consumePendingRejection() {
        return SWAP_REJECTION.consume();
    }

    /** Returns a marker only for the same live inventory session and logical item. */
    public static int actualOffhandMarker(Minecraft minecraft) {
        InventorySessionIdentity currentSession = currentSession(minecraft);
        if (currentSession == null || minecraft.player == null) {
            OFFHAND_ANCHOR.clear();
            return -1;
        }
        return OFFHAND_ANCHOR.actualSlot(
                currentSession,
                minecraft.player.getOffhandItem(),
                HotbarSlotButton::sameLogicalItem
        );
    }

    /** Cancels transaction feedback and markers without dispatching another inventory action. */
    public static void cancelSession() {
        clearPendingTransaction();
        SWAP_REJECTION.clear();
        OFFHAND_ANCHOR.clear();
        HotbarHandState.clearTransient();
    }

    private static void finishPending(
            PendingSwapConfirmation.Result result,
            InventorySessionIdentity currentSession
    ) {
        if (result == PendingSwapConfirmation.Result.PENDING ||
                result == PendingSwapConfirmation.Result.NONE) {
            return;
        }
        ControllerType controller = pendingController;
        int slot = pendingSlot;
        SWAP_REJECTION.reconciled(result, controller, slot);
        if (result == PendingSwapConfirmation.Result.CONFIRMED && currentSession != null) {
            OFFHAND_ANCHOR.confirm(currentSession, slot, expectedOffhand.copy());
            accept(controller, slot);
        } else {
            reject(controller, slot);
        }
        clearPendingTransaction();
    }

    private static void clearPendingTransaction() {
        ControllerType controller = pendingController;
        PENDING_SWAP.clear();
        HotbarHandState.clearPending(controller);
        expectedOffhand = ItemStack.EMPTY;
        expectedHotbar = ItemStack.EMPTY;
        pendingController = null;
        pendingSlot = -1;
        pendingSession = null;
    }

    private static void reconcileOffhandAnchor(
            Minecraft minecraft,
            InventorySessionIdentity currentSession
    ) {
        if (currentSession == null || minecraft.player == null) {
            OFFHAND_ANCHOR.clear();
            return;
        }
        OFFHAND_ANCHOR.actualSlot(
                currentSession,
                minecraft.player.getOffhandItem(),
                HotbarSlotButton::sameLogicalItem
        );
    }

    private static InventorySessionIdentity currentSession(Minecraft minecraft) {
        if (minecraft == null || minecraft.level == null || minecraft.player == null ||
                minecraft.player.getInventory() == null || minecraft.player.inventoryMenu == null) {
            return null;
        }
        return InventorySessionIdentity.capture(
                minecraft.level,
                minecraft.player,
                minecraft.player.getInventory(),
                minecraft.player.inventoryMenu,
                minecraft.player.inventoryMenu.getStateId()
        );
    }

    private static boolean sameStack(ItemStack actual, ItemStack expected) {
        if (actual.isEmpty() || expected.isEmpty()) {
            return actual.isEmpty() && expected.isEmpty();
        }
        return actual.getCount() == expected.getCount() &&
                ItemStack.isSameItemSameComponents(actual, expected);
    }

    private static boolean sameLogicalItem(ItemStack actual, ItemStack expected) {
        if (actual.isEmpty() || expected.isEmpty()) {
            return actual.isEmpty() && expected.isEmpty();
        }
        // Count and damage/components can legitimately change while the same
        // offhand item is used. Only the logical item type owns the marker.
        return ItemStack.isSameItem(actual, expected);
    }

    private static void accept(ControllerType controller, int slot) {
        if (controller == null) {
            return;
        }
        HotbarHandState.accepted(controller, slot);
        RadialHandler.recordChoice(controller, slot);
        haptic(controller, 0.025F, 160.0F, 0.35F);
    }

    private static void reject(ControllerType controller, int slot) {
        if (controller == null) {
            return;
        }
        HotbarHandState.rejected(controller, slot, System.nanoTime());
        haptic(controller, 0.08F, 80.0F, 0.8F);
    }

    private static void haptic(
            ControllerType controller,
            float duration,
            float frequency,
            float amplitude
    ) {
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        if (dataHolder.vr != null && controller != null) {
            dataHolder.vr.triggerHapticPulse(controller, duration, frequency, amplitude);
        }
    }

}
