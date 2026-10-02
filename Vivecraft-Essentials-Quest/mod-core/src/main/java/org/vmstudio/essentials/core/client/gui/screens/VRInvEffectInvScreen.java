package org.vmstudio.essentials.core.client.gui.screens;

import lombok.Getter;
import net.minecraft.client.gui.Hud;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.input.MouseButtonInfo;
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
import org.vmstudio.essentials.core.client.config.WristUiConfig;
import org.vmstudio.essentials.core.platform.ClientEffectHooks;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.function.Predicate;

public abstract class VRInvEffectInvScreen extends AbstractContainerScreen<AbstractContainerMenu> {

    private static final Identifier EFFECT_BACKGROUND_LARGE_SPRITE =
            Identifier.withDefaultNamespace("container/inventory/effect_background_large");
    private static final Identifier EFFECT_BACKGROUND_SMALL_SPRITE =
            Identifier.withDefaultNamespace("container/inventory/effect_background_small");

    @Getter
    protected boolean fullInventory;
    private final SortedVisibleCache<MobEffectInstance> visibleEffectCache =
            new SortedVisibleCache<>();

    public VRInvEffectInvScreen(AbstractContainerMenu menu,
                                Inventory inventory,
                                Component component) {
        super(menu, inventory, component, 258, 156);
    }

    /**
     * Minecraft 26.2 extracts GUI render state instead of invoking the old
     * immediate-mode render hook. Keep the addon's established render path as
     * a compatibility layer while submitting everything through the new
     * extractor.
     */
    @Override
    public final void extractRenderState(GuiGraphicsExtractor guiGraphics,
                                         int mouseX,
                                         int mouseY,
                                         float partialTick) {
        render(guiGraphics, mouseX, mouseY, partialTick);
    }

    public void render(GuiGraphicsExtractor guiGraphics, int mouseX, int mouseY, float partialTick) {
        super.extractRenderState(guiGraphics, mouseX, mouseY, partialTick);
        this.renderEffects(guiGraphics, mouseX, mouseY);
    }

    @Override
    public final void extractBackground(GuiGraphicsExtractor guiGraphics,
                                        int mouseX,
                                        int mouseY,
                                        float partialTick) {
        renderBg(guiGraphics, partialTick, mouseX, mouseY);
    }

    protected abstract void renderBg(GuiGraphicsExtractor guiGraphics,
                                     float partialTick,
                                     int mouseX,
                                     int mouseY);

    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubled) {
        return mouseClicked(event.x(), event.y(), event.button());
    }

    public boolean mouseClicked(double mouseX, double mouseY, int button) {
        return super.mouseClicked(
                new MouseButtonEvent(
                        mouseX,
                        mouseY,
                        new MouseButtonInfo(button, 0)
                ),
                false
        );
    }

    protected final void renderTooltip(GuiGraphicsExtractor guiGraphics,
                                       int mouseX,
                                       int mouseY) {
        super.extractTooltip(guiGraphics, mouseX, mouseY);
    }

    private void renderEffects(GuiGraphicsExtractor guiGraphics, int mouseX, int mouseY) {
        List<MobEffectInstance> effects = visorEssentials$getVisibleEffects();
        EffectBounds effectBounds = visorEssentials$getEffectBounds(effects.size());
        if (effectBounds == null) {
            return;
        }

        int startPos = effectBounds.x();
        boolean large = effectBounds.width() == 120;
        int rowSpacing = effects.size() > 5
                ? 132 / (effects.size() - 1)
                : 33;

        this.renderBackgrounds(guiGraphics, startPos, rowSpacing, effects, large);
        this.renderIcons(guiGraphics, startPos, rowSpacing, effects, large);
        if (large) {
            this.renderLabels(guiGraphics, startPos, rowSpacing, effects);
        } else if (mouseX >= startPos && mouseX <= startPos + 32) {
            int effectY = this.topPos;
            MobEffectInstance hoveredEffect = null;

            for (MobEffectInstance effect : effects) {
                if (mouseY >= effectY && mouseY <= effectY + rowSpacing) {
                    hoveredEffect = effect;
                }

                effectY += rowSpacing;
            }

            if (hoveredEffect != null) {
                List<Component> tooltip = List.of(
                        this.getEffectName(hoveredEffect),
                        MobEffectUtil.formatDuration(
                                hoveredEffect,
                                1.0F,
                                visorEssentials$getTickRate()
                        )
                );
                guiGraphics.setTooltipForNextFrame(
                        this.font,
                        tooltip,
                        Optional.empty(),
                        mouseX,
                        mouseY
                );
            }
        }
    }

    /**
     * Returns the exact status-effect rectangle rendered beside the wrist
     * inventory. Computing this from current state keeps cursor focus bounds
     * in sync even before the next render pass.
     */
    protected @Nullable EffectBounds visorEssentials$getEffectBounds() {
        return visorEssentials$getEffectBounds(
                visorEssentials$getVisibleEffectCount()
        );
    }

    /**
     * Counts effect rows without materializing the sorted render list. Bounds
     * consumers only need the row count, while the render path still owns the
     * actual ordered instances.
     */
    protected final int visorEssentials$getVisibleEffectCount() {
        if (!WristUiConfig.getInstance().showPotionEffects()
                || this.minecraft == null
                || this.minecraft.player == null) {
            return 0;
        }

        int visibleEffects = 0;
        for (MobEffectInstance effect : this.minecraft.player.getActiveEffects()) {
            if (ClientEffectHooks.shouldRenderEffect(effect)) {
                visibleEffects++;
            }
        }
        return visibleEffects;
    }

    protected final @Nullable EffectBounds visorEssentials$getEffectBounds(
            int visibleEffectCount
    ) {
        if (visibleEffectCount <= 0) {
            return null;
        }

        // The simplified inventory is 80 px narrower, so bring the effects
        // 36 px left to sit just beyond its visible right edge.
        int startPos = this.leftPos + this.imageWidth + 2
                - (fullInventory ? 0 : 36);
        int availableWidth = this.width - startPos;
        if (availableWidth < 32) {
            return null;
        }

        int effectWidth = availableWidth >= 120 ? 120 : 32;
        int rowSpacing = visibleEffectCount > 5
                ? 132 / (visibleEffectCount - 1)
                : 33;
        int effectHeight = 32 + (visibleEffectCount - 1) * rowSpacing;
        return new EffectBounds(startPos, this.topPos, effectWidth, effectHeight);
    }

    private List<MobEffectInstance> visorEssentials$getVisibleEffects() {
        boolean enabled = WristUiConfig.getInstance().showPotionEffects()
                && this.minecraft != null
                && this.minecraft.player != null;
        return visibleEffectCache.refresh(
                enabled,
                enabled ? this.minecraft.player.getActiveEffects() : List.of(),
                ClientEffectHooks::shouldRenderEffect
        );
    }

    //---Nothing modified below
    private void renderBackgrounds(GuiGraphicsExtractor guiGraphics, int renderX, int yOffset, Iterable<MobEffectInstance> effects, boolean large) {
        int i = this.topPos;

        for(MobEffectInstance mobEffectInstance : effects) {
            if (large) {
                guiGraphics.blitSprite(RenderPipelines.GUI_TEXTURED,
                        EFFECT_BACKGROUND_LARGE_SPRITE, renderX, i, 120, 32);
            } else {
                guiGraphics.blitSprite(RenderPipelines.GUI_TEXTURED,
                        EFFECT_BACKGROUND_SMALL_SPRITE, renderX, i, 32, 32);
            }

            i += yOffset;
        }

    }

    private void renderIcons(GuiGraphicsExtractor guiGraphics, int renderX, int yOffset, Iterable<MobEffectInstance> effects, boolean isSmall) {
        int i = this.topPos;

        for(MobEffectInstance mobEffectInstance : effects) {
            guiGraphics.blitSprite(
                    RenderPipelines.GUI_TEXTURED,
                    Hud.getMobEffectSprite(mobEffectInstance.getEffect()),
                    renderX + (isSmall ? 6 : 7), i + 7, 18, 18
            );
            i += yOffset;
        }

    }

    private void renderLabels(GuiGraphicsExtractor guiGraphics, int renderX, int yOffset, Iterable<MobEffectInstance> effects) {
        int i = this.topPos;

        for(MobEffectInstance mobEffectInstance : effects) {
            Component component = this.getEffectName(mobEffectInstance);
            guiGraphics.text(this.font, component, renderX + 10 + 18, i + 6, 16777215);
            Component component2 = MobEffectUtil.formatDuration(
                    mobEffectInstance,
                    1.0F,
                    visorEssentials$getTickRate()
            );
            guiGraphics.text(this.font, component2, renderX + 10 + 18, i + 6 + 10, 8355711);
            i += yOffset;
        }

    }

    private Component getEffectName(MobEffectInstance effect) {
        MutableComponent mutableComponent = effect.getEffect().value().getDisplayName().copy();
        if (effect.getAmplifier() >= 1 && effect.getAmplifier() <= 9) {
            MutableComponent var10000 = mutableComponent.append(CommonComponents.SPACE);
            int var10001 = effect.getAmplifier();
            var10000.append(Component.translatable("enchantment.level." + (var10001 + 1)));
        }

        return mutableComponent;
    }

    private float visorEssentials$getTickRate() {
        return this.minecraft != null && this.minecraft.level != null
                ? this.minecraft.level.tickRateManager().tickrate()
                : 20.0F;
    }

    protected record EffectBounds(int x, int y, int width, int height) {}

    static final class SortedVisibleCache<T extends Comparable<? super T>> {
        private final List<T> values = new ArrayList<>();

        List<T> refresh(boolean enabled,
                        Iterable<? extends T> candidates,
                        Predicate<? super T> visible) {
            values.clear();
            if (enabled) {
                for (T candidate : candidates) {
                    if (visible.test(candidate)) {
                        values.add(candidate);
                    }
                }
                values.sort(null);
            }
            return values;
        }
    }
}
