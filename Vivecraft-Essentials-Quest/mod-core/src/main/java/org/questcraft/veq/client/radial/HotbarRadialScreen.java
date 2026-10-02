/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package org.questcraft.veq.client.radial;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.ItemStack;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.gui.GuiRadial;
import org.vivecraft.client_vr.provider.ControllerType;

/** 98x98 Visor-style Grip hotbar rendered by Vivecraft's existing radial surface. */
public final class HotbarRadialScreen extends GuiRadial {
    private static final String TEXTURE_ROOT = "textures/gui/hotbar/";
    private static final int PENDING_FILL = 0x68FFD54F;
    private static final int PENDING_BORDER = 0xFFFFD54F;
    private static final int REJECTED_FILL = 0x78D62929;
    private static final int REJECTED_BORDER = 0xFFFF4545;
    private static final Component PENDING_TEXT = Component.translatable(
            "vivecraft_essentials_quest.grip.syncing");

    private static final Identifier[] BACKGROUNDS = {
            texture("default.png"),
            texture("top.png"),
            texture("top_right.png"),
            texture("right.png"),
            texture("bottom_right.png"),
            texture("bottom.png"),
            texture("bottom_left.png"),
            texture("left.png"),
            texture("top_left.png")
    };
    private static final Identifier MAIN_SELECTED_OUTER = texture("hotbar_main_selected0.png");
    private static final Identifier MAIN_SELECTED_CENTER = texture("hotbar_main_selected1.png");
    private static final Identifier OFFHAND_SELECTED_OUTER = texture("hotbar_offhand_selected0.png");
    private static final Identifier OFFHAND_SELECTED_CENTER = texture("hotbar_offhand_selected1.png");
    private final GripFeedbackState feedback;
    private ControllerType sessionController = ControllerType.RIGHT;

    HotbarRadialScreen(GripFeedbackState feedback) {
        this.feedback = feedback;
    }

    public void beginSession(ControllerType controller) {
        this.sessionController = controller == null ? ControllerType.RIGHT : controller;
        init(HotbarGridLayout.PANEL_SIZE, HotbarGridLayout.PANEL_SIZE);
    }

    @Override
    public void init() {
        // Selection is angular and handled as one surface. Desktop widgets
        // would turn the 98px image into nine oversized rectangular buttons.
        clearWidgets();
        HotbarHandState.beginSession(this.sessionController);
    }

    /** Called from the exact 98x98 surface before release handling. */
    public void updateSelection(
            ControllerType controller,
            boolean pointed,
            double cursorX,
            double cursorY
    ) {
        if (controller == null) {
            return;
        }
        if (!pointed) {
            HotbarHandState.updateHover(controller, false, -1);
            return;
        }
        if (!Double.isFinite(cursorX) || !Double.isFinite(cursorY)) {
            HotbarHandState.updateHover(controller, false, -1);
            return;
        }
        double x = cursorX - HotbarGridLayout.PANEL_SIZE * 0.5D;
        double y = cursorY - HotbarGridLayout.PANEL_SIZE * 0.5D;
        int previous = HotbarHandState.hovered(controller);
        int selected = HotbarRadialSelector.select(x, y, previous);
        if (selected == previous) {
            return;
        }
        HotbarHandState.updateHover(controller, true, selected);
        if (selected >= 0) {
            ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
            if (dataHolder.vr != null) {
                dataHolder.vr.triggerHapticPulse(controller, 0.008F, 180.0F, 0.22F);
            }
        }
    }

    @Override
    public void extractRenderState(
            GuiGraphicsExtractor graphics,
            int mouseX,
            int mouseY,
            float partialTick
    ) {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.player == null) {
            return;
        }
        ControllerType controller = this.sessionController;
        int hovered = HotbarHandState.hovered(controller);
        int backgroundSlot = validSlot(hovered) ? hovered : 0;
        int left = HotbarGridLayout.panelLeft(width);
        int top = HotbarGridLayout.panelTop(height);

        graphics.blit(
                RenderPipelines.GUI_TEXTURED,
                BACKGROUNDS[backgroundSlot],
                left,
                top,
                0.0F,
                0.0F,
                HotbarGridLayout.PANEL_SIZE,
                HotbarGridLayout.PANEL_SIZE,
                HotbarGridLayout.PANEL_SIZE,
                HotbarGridLayout.PANEL_SIZE
        );

        // The blue offhand anchor belongs only to the LEFT/offhand session.
        // RIGHT must never display or substitute the offhand into its grid.
        int offhandMarker = showsOffhandMarker(controller)
                ? HotbarSlotButton.actualOffhandMarker(minecraft)
                : -1;
        for (int slot = 0; slot < HotbarGridLayout.SLOT_COUNT; slot++) {
            ItemStack stack = controller == ControllerType.LEFT && slot == offhandMarker
                    ? minecraft.player.getOffhandItem()
                    : minecraft.player.getInventory().getItem(slot);
            if (stack.isEmpty()) {
                continue;
            }
            int itemX = HotbarGridLayout.itemX(width, slot);
            int itemY = HotbarGridLayout.itemY(height, slot);
            graphics.item(stack, itemX, itemY);
            graphics.itemDecorations(minecraft.font, stack, itemX, itemY);
        }

        drawSelection(
                graphics,
                minecraft.player.getInventory().getSelectedSlot(),
                MAIN_SELECTED_OUTER,
                MAIN_SELECTED_CENTER
        );
        drawSelection(
                graphics,
                offhandMarker,
                OFFHAND_SELECTED_OUTER,
                OFFHAND_SELECTED_CENTER
        );
        drawFeedback(graphics, minecraft, controller);
    }

    @Override
    public void setShift(boolean shift) {
        // The Grip hotbar has exactly one stable layer.
    }

    private void drawSelection(
            GuiGraphicsExtractor graphics,
            int slot,
            Identifier outer,
            Identifier center
    ) {
        if (!validSlot(slot)) {
            return;
        }
        Identifier texture = slot == 0 ? center : outer;
        graphics.blit(
                RenderPipelines.GUI_TEXTURED,
                texture,
                HotbarGridLayout.selectionX(width, slot),
                HotbarGridLayout.selectionY(height, slot),
                0.0F,
                0.0F,
                HotbarGridLayout.SELECTION_SIZE,
                HotbarGridLayout.SELECTION_SIZE,
                HotbarGridLayout.SELECTION_SIZE,
                HotbarGridLayout.SELECTION_SIZE
        );
    }

    private void drawFeedback(
            GuiGraphicsExtractor graphics,
            Minecraft minecraft,
            ControllerType controller
    ) {
        int pendingSlot = HotbarHandState.pendingSlot(controller);
        if (validSlot(pendingSlot)) {
            drawSlotOverlay(graphics, pendingSlot, PENDING_FILL, PENDING_BORDER);
            int textWidth = minecraft.font.width(PENDING_TEXT);
            int textX = HotbarGridLayout.panelLeft(width) +
                    (HotbarGridLayout.PANEL_SIZE - textWidth) / 2;
            int textY = HotbarGridLayout.panelTop(height) +
                    (HotbarGridLayout.PANEL_SIZE - minecraft.font.lineHeight) / 2;
            graphics.fill(
                    textX - 2,
                    textY - 1,
                    textX + textWidth + 2,
                    textY + minecraft.font.lineHeight,
                    0xD0202020
            );
            graphics.text(minecraft.font, PENDING_TEXT, textX, textY, PENDING_BORDER, false);
            return;
        }

        int rejectedSlot = this.feedback.rejectedSlot(controller);
        if (validSlot(rejectedSlot)) {
            drawSlotOverlay(graphics, rejectedSlot, REJECTED_FILL, REJECTED_BORDER);
        }
    }

    private void drawSlotOverlay(
            GuiGraphicsExtractor graphics,
            int slot,
            int fill,
            int border
    ) {
        int x = HotbarGridLayout.selectionX(width, slot);
        int y = HotbarGridLayout.selectionY(height, slot);
        graphics.fill(x, y, x + HotbarGridLayout.SELECTION_SIZE,
                y + HotbarGridLayout.SELECTION_SIZE, fill);
        graphics.outline(x, y, HotbarGridLayout.SELECTION_SIZE,
                HotbarGridLayout.SELECTION_SIZE, border);
    }

    private static boolean validSlot(int slot) {
        return slot >= 0 && slot < HotbarGridLayout.SLOT_COUNT;
    }

    static boolean showsOffhandMarker(ControllerType controller) {
        return controller == ControllerType.LEFT;
    }

    private static Identifier texture(String fileName) {
        return Identifier.fromNamespaceAndPath(
                "vivecraft_essentials_quest",
                TEXTURE_ROOT + fileName
        );
    }
}
