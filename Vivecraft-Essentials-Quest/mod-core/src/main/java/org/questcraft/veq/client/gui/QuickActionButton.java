package org.questcraft.veq.client.gui;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.input.InputWithModifiers;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import org.questcraft.veq.client.quickactions.QuickActionDefinition;

public final class QuickActionButton extends Button {
    private final Runnable action;
    private final ItemStack icon;

    public QuickActionButton(int x, int y, int size, QuickActionDefinition definition, Runnable action) {
        super(
                x,
                y,
                size,
                size,
                definition.displayName().isBlank()
                        ? Component.translatable("vivecraft_essentials_quest.quick_action.empty")
                        : Component.literal(definition.displayName()),
                ignored -> action.run(),
                DEFAULT_NARRATION
        );
        this.action = action;
        this.icon = resolveIcon(definition.iconItemId());
        this.active = definition.isConfigured();
        setTooltip(Tooltip.create(getMessage()));
    }

    @Override
    public void onPress(InputWithModifiers input) {
        if (active) {
            action.run();
        }
    }

    @Override
    protected void extractContents(GuiGraphicsExtractor graphics, int mouseX, int mouseY, float partialTick) {
        if (!icon.isEmpty()) {
            int itemX = getX() + (getWidth() - 16) / 2;
            int itemY = getY() + (getHeight() - 16) / 2;
            graphics.item(icon, itemX, itemY);
            graphics.itemDecorations(Minecraft.getInstance().font, icon, itemX, itemY);
        } else {
            graphics.centeredText(
                    Minecraft.getInstance().font,
                    getMessage(),
                    getX() + getWidth() / 2,
                    getY() + (getHeight() - 9) / 2,
                    active ? 0xFFFFFFFF : 0xFF777777
            );
        }
    }

    private static ItemStack resolveIcon(String itemId) {
        if (itemId == null || itemId.isBlank()) {
            return ItemStack.EMPTY;
        }
        Identifier identifier = Identifier.tryParse(itemId);
        if (identifier == null) {
            return ItemStack.EMPTY;
        }
        Item item = BuiltInRegistries.ITEM.getValue(identifier);
        return item == null || item == Items.AIR ? ItemStack.EMPTY : new ItemStack(item);
    }
}
