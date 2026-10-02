package org.questcraft.veq.client.gui;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.Hud;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.network.chat.CommonComponents;
import net.minecraft.network.chat.Component;
import net.minecraft.network.chat.MutableComponent;
import net.minecraft.resources.Identifier;
import net.minecraft.world.effect.MobEffectInstance;
import net.minecraft.world.effect.MobEffectUtil;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.inventory.AbstractContainerMenu;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * Direct Vivecraft content port of VEP's {@code VRInvEffectInvScreen}.
 *
 * <p>The original class is coupled to Visor's addon/config bridge. This class
 * keeps its Minecraft 26.2 rendering and bounds behavior while exposing the
 * one feature-policy seam needed by VEQ. World placement, cursor ownership and
 * OpenXR remain the responsibility of Vivecraft's external-surface engine.</p>
 */
public abstract class VepVrInventoryEffectScreen<T extends AbstractContainerMenu>
        extends AbstractContainerScreen<T> {
    private static final Identifier EFFECT_BACKGROUND_SPRITE =
            Identifier.withDefaultNamespace("container/inventory/effect_background");
    private static final Identifier EFFECT_BACKGROUND_AMBIENT_SPRITE =
            Identifier.withDefaultNamespace("container/inventory/effect_background_ambient");

    private final List<MobEffectInstance> visibleEffects = new ArrayList<>();

    protected VepVrInventoryEffectScreen(T menu,
                                        Inventory inventory,
                                        Component title,
                                        int imageWidth,
                                        int imageHeight) {
        super(menu, inventory, title, imageWidth, imageHeight);
    }

    @Override
    public final void extractRenderState(GuiGraphicsExtractor graphics,
                                         int mouseX,
                                         int mouseY,
                                         float partialTick) {
        // External wrist surfaces are rendered through GuiRenderHelper, which
        // calls extractRenderState directly and intentionally skips Screen's
        // desktop background pass.  Draw the VEP plate here so the inventory,
        // armor and status islands never float over a transparent framebuffer.
        renderVepBackground(graphics, partialTick, mouseX, mouseY);
        graphics.nextStratum();
        renderVepContent(graphics, mouseX, mouseY, partialTick);
    }

    /** Matches VEP's screen-in-screen render ordering. */
    protected void renderVepContent(GuiGraphicsExtractor graphics,
                                    int mouseX,
                                    int mouseY,
                                    float partialTick) {
        super.extractRenderState(graphics, mouseX, mouseY, partialTick);
        renderEffects(graphics, mouseX, mouseY);
    }

    @Override
    public final void extractBackground(GuiGraphicsExtractor graphics,
                                        int mouseX,
                                        int mouseY,
                                        float partialTick) {
        renderVepBackground(graphics, partialTick, mouseX, mouseY);
    }

    protected abstract void renderVepBackground(GuiGraphicsExtractor graphics,
                                                float partialTick,
                                                int mouseX,
                                                int mouseY);

    protected abstract boolean veq$showPotionEffects();

    protected final void renderVepTooltip(GuiGraphicsExtractor graphics,
                                          int mouseX,
                                          int mouseY) {
        super.extractTooltip(graphics, mouseX, mouseY);
    }

    protected final int veq$visibleEffectCount() {
        if (!veq$showPotionEffects() || minecraft == null || minecraft.player == null) {
            return 0;
        }
        return minecraft.player.getActiveEffects().size();
    }

    protected final @Nullable EffectBounds veq$effectBounds() {
        return veq$effectBounds(veq$visibleEffectCount());
    }

    protected final @Nullable EffectBounds veq$effectBounds(int visibleEffectCount) {
        VepEffectLayout.Bounds bounds = VepEffectLayout.calculate(
                leftPos, topPos, imageWidth, width, visibleEffectCount);
        return bounds == null ? null : new EffectBounds(
                bounds.x(), bounds.y(), bounds.width(), bounds.height());
    }

    private void renderEffects(GuiGraphicsExtractor graphics, int mouseX, int mouseY) {
        List<MobEffectInstance> effects = refreshVisibleEffects();
        EffectBounds bounds = veq$effectBounds(effects.size());
        if (bounds == null) {
            return;
        }
        boolean large = bounds.width() == 120;
        int rowSpacing = effects.size() > 5 ? 132 / (effects.size() - 1) : 33;
        renderEffectBackgrounds(graphics, bounds.x(), rowSpacing, effects, large);
        renderEffectIcons(graphics, bounds.x(), rowSpacing, effects, large);
        if (large) {
            renderEffectLabels(graphics, bounds.x(), rowSpacing, effects);
        } else if (mouseX >= bounds.x() && mouseX <= bounds.x() + 32) {
            MobEffectInstance hovered = hoveredEffect(effects, mouseY, rowSpacing);
            if (hovered != null) {
                graphics.setTooltipForNextFrame(
                        font,
                        List.of(
                                effectName(hovered),
                                MobEffectUtil.formatDuration(hovered, 1.0F, tickRate())
                        ),
                        Optional.empty(),
                        mouseX,
                        mouseY
                );
            }
        }
    }

    private List<MobEffectInstance> refreshVisibleEffects() {
        visibleEffects.clear();
        if (veq$showPotionEffects() && minecraft != null && minecraft.player != null) {
            visibleEffects.addAll(minecraft.player.getActiveEffects());
            visibleEffects.sort(null);
        }
        return visibleEffects;
    }

    private void renderEffectBackgrounds(GuiGraphicsExtractor graphics,
                                         int x,
                                         int rowSpacing,
                                         Iterable<MobEffectInstance> effects,
                                         boolean large) {
        int y = topPos;
        for (MobEffectInstance effect : effects) {
            graphics.blitSprite(
                    RenderPipelines.GUI_TEXTURED,
                    effect.isAmbient()
                            ? EFFECT_BACKGROUND_AMBIENT_SPRITE
                            : EFFECT_BACKGROUND_SPRITE,
                    x,
                    y,
                    large ? 120 : 32,
                    32
            );
            y += rowSpacing;
        }
    }

    private void renderEffectIcons(GuiGraphicsExtractor graphics,
                                   int x,
                                   int rowSpacing,
                                   Iterable<MobEffectInstance> effects,
                                   boolean large) {
        int y = topPos;
        for (MobEffectInstance effect : effects) {
            graphics.blitSprite(
                    RenderPipelines.GUI_TEXTURED,
                    Hud.getMobEffectSprite(effect.getEffect()),
                    x + (large ? 6 : 7),
                    y + 7,
                    18,
                    18
            );
            y += rowSpacing;
        }
    }

    private void renderEffectLabels(GuiGraphicsExtractor graphics,
                                    int x,
                                    int rowSpacing,
                                    Iterable<MobEffectInstance> effects) {
        int y = topPos;
        for (MobEffectInstance effect : effects) {
            graphics.text(font, effectName(effect), x + 28, y + 6, 0xFFFFFF);
            graphics.text(
                    font,
                    MobEffectUtil.formatDuration(effect, 1.0F, tickRate()),
                    x + 28,
                    y + 16,
                    0x7F7F7F
            );
            y += rowSpacing;
        }
    }

    private @Nullable MobEffectInstance hoveredEffect(List<MobEffectInstance> effects,
                                                      int mouseY,
                                                      int rowSpacing) {
        int y = topPos;
        MobEffectInstance hovered = null;
        for (MobEffectInstance effect : effects) {
            if (mouseY >= y && mouseY <= y + rowSpacing) {
                hovered = effect;
            }
            y += rowSpacing;
        }
        return hovered;
    }

    private Component effectName(MobEffectInstance effect) {
        MutableComponent name = effect.getEffect().value().getDisplayName().copy();
        if (effect.getAmplifier() >= 1 && effect.getAmplifier() <= 9) {
            name.append(CommonComponents.SPACE)
                    .append(Component.translatable("enchantment.level." + (effect.getAmplifier() + 1)));
        }
        return name;
    }

    private float tickRate() {
        return minecraft != null && minecraft.level != null
                ? minecraft.level.tickRateManager().tickrate()
                : 20.0F;
    }

    protected record EffectBounds(int x, int y, int width, int height) {
    }
}
