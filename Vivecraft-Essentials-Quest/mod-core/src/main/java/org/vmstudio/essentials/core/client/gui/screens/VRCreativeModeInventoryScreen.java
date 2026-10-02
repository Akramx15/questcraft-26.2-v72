package org.vmstudio.essentials.core.client.gui.screens;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.events.GuiEventListener;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.client.resources.sounds.SimpleSoundInstance;
import net.minecraft.network.chat.Component;
import net.minecraft.sounds.SoundEvents;
import net.minecraft.world.flag.FeatureFlagSet;
import org.jetbrains.annotations.NotNull;
import org.vmstudio.essentials.core.client.config.WristUiConfig;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;

/**
 * Minecraft's native creative inventory hosted directly by the wrist overlay.
 *
 * <p>This deliberately keeps the native creative menu and its dynamic slot
 * list untouched. Creative tabs replace that list at runtime, so applying the
 * normal wrist slot remapper here would leave rendering and click hitboxes out
 * of sync.</p>
 */
public final class VRCreativeModeInventoryScreen
        extends CreativeModeInventoryScreen {
    private static final int TAB_OVERHANG = 32;
    private static final int PAGE_BUTTON_OVERHANG = 50;
    private static final int CONTROL_HEIGHT = 18;
    private static final int CONTROL_GAP = 4;
    // The native panel is vertically centered in Visor's usual 240px logical
    // target. A two-pixel gap leaves the full 18px row visible immediately
    // below the bottom tabs (52 + 136 + 32 + 2 + 18 = 240).
    private static final int CONTROL_ROW_GAP = 2;
    private static final int EFFECT_PANEL_WIDTH = 124;

    private static final Component POPOUT_LABEL = Component.translatable(
            "visor_essentials.inventory.creative.popout"
    );
    private static final Component POPOUT_TOOLTIP = Component.translatable(
            "visor_essentials.inventory.creative.popout.tooltip"
    );
    private static final Component BACK_LABEL = Component.translatable(
            "visor_essentials.inventory.creative.back"
    );
    private static final Component BACK_TOOLTIP = Component.translatable(
            "visor_essentials.inventory.creative.back.tooltip"
    );

    private final Runnable popoutAction;
    private final Runnable backAction;
    private Set<GuiEventListener> nativeWidgets = Set.of();

    public VRCreativeModeInventoryScreen(@NotNull LocalPlayer player,
                                         @NotNull FeatureFlagSet enabledFeatures,
                                         boolean displayOperatorCreativeTab,
                                         @NotNull Runnable popoutAction,
                                         @NotNull Runnable backAction) {
        super(player, enabledFeatures, displayOperatorCreativeTab);
        this.popoutAction = popoutAction;
        this.backAction = backAction;
    }

    @Override
    protected void init() {
        // NeoForge posts ScreenEvent.Init.Pre before calling this method.
        // Remember those externally injected widgets separately so they are
        // never mistaken for Minecraft's native search box or page arrows.
        Set<GuiEventListener> preInitWidgets = Collections.newSetFromMap(
                new IdentityHashMap<>()
        );
        preInitWidgets.addAll(children());

        super.init();

        // Screen.init(Minecraft, width, height) posts Init.Post after this
        // method returns. Whitelist only widgets created by the native screen;
        // remove both pre- and post-init additions once public init completes.
        Set<GuiEventListener> widgets = Collections.newSetFromMap(
                new IdentityHashMap<>()
        );
        widgets.addAll(children());
        widgets.removeAll(preInitWidgets);
        nativeWidgets = widgets;
    }

    /** Removes only non-native widgets added by global screen-init hooks. */
    public void removeInjectedWidgets() {
        children().stream()
                .filter(widget -> !nativeWidgets.contains(widget))
                .toList()
                .forEach(this::removeWidget);
    }

    /**
     * Keep the creative container artwork while omitting the full-screen dim
     * pass that would otherwise become a dark rectangle in the world overlay.
     */
    @Override
    public void extractBackground(GuiGraphicsExtractor graphics,
                                  int mouseX,
                                  int mouseY,
                                  float partialTick) {
        super.extractBackground(graphics, mouseX, mouseY, partialTick);
    }

    @Override
    public boolean showsActiveEffects() {
        return WristUiConfig.getInstance().showPotionEffects()
                && super.showsActiveEffects();
    }

    @Override
    public void extractRenderState(GuiGraphicsExtractor graphics,
                                   int mouseX,
                                   int mouseY,
                                   float partialTick) {
        super.extractRenderState(graphics, mouseX, mouseY, partialTick);
        renderControl(
                graphics,
                getPopoutX(),
                getControlsY(),
                getPopoutWidth(),
                POPOUT_LABEL,
                POPOUT_TOOLTIP,
                mouseX,
                mouseY
        );
        renderControl(
                graphics,
                getBackX(),
                getControlsY(),
                getBackWidth(),
                BACK_LABEL,
                BACK_TOOLTIP,
                mouseX,
                mouseY
        );
    }

    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubled) {
        double mouseX = event.x();
        double mouseY = event.y();
        int button = event.button();
        if (button == 0 && isOverControl(
                mouseX,
                mouseY,
                getPopoutX(),
                getControlsY(),
                getPopoutWidth()
        )) {
            playClick();
            popoutAction.run();
            return true;
        }
        if (button == 0 && isOverControl(
                mouseX,
                mouseY,
                getBackX(),
                getControlsY(),
                getBackWidth()
        )) {
            playClick();
            backAction.run();
            return true;
        }
        return super.mouseClicked(event, doubled);
    }

    public int getInteractionX() {
        return leftPos;
    }

    public int getInteractionY() {
        int nativeTabsTop = topPos - TAB_OVERHANG;
        int pageButtonsTop = topPos - PAGE_BUTTON_OVERHANG;
        return Math.max(0, Math.min(nativeTabsTop, pageButtonsTop));
    }

    public int getInteractionWidth() {
        int widthWithEffects = showsActiveEffects()
                ? imageWidth + EFFECT_PANEL_WIDTH
                : imageWidth;
        return Math.min(width - leftPos, widthWithEffects);
    }

    public int getInteractionHeight() {
        int nativeBottom = topPos + imageHeight + TAB_OVERHANG;
        int controlsBottom = getControlsY() + CONTROL_HEIGHT;
        return Math.max(nativeBottom, controlsBottom) - getInteractionY();
    }

    private void renderControl(GuiGraphicsExtractor graphics,
                               int x,
                               int y,
                               int controlWidth,
                               Component label,
                               Component tooltip,
                               int mouseX,
                               int mouseY) {
        boolean hovered = isOverControl(
                mouseX,
                mouseY,
                x,
                y,
                controlWidth
        );
        int background = hovered ? 0xEA454545 : 0xDA202020;
        int border = hovered ? 0xFFFFFFFF : 0xFF9A9A9A;

        graphics.fill(x, y, x + controlWidth, y + CONTROL_HEIGHT, background);
        graphics.fill(x, y, x + controlWidth, y + 1, border);
        graphics.fill(
                x,
                y + CONTROL_HEIGHT - 1,
                x + controlWidth,
                y + CONTROL_HEIGHT,
                border
        );
        graphics.fill(x, y, x + 1, y + CONTROL_HEIGHT, border);
        graphics.fill(
                x + controlWidth - 1,
                y,
                x + controlWidth,
                y + CONTROL_HEIGHT,
                border
        );
        graphics.centeredText(
                font,
                label,
                x + controlWidth / 2,
                y + (CONTROL_HEIGHT - 8) / 2,
                0xFFFFFFFF
        );
        if (hovered) {
            graphics.setTooltipForNextFrame(font, tooltip, mouseX, mouseY);
        }
    }

    private int getControlsY() {
        return topPos + imageHeight + TAB_OVERHANG + CONTROL_ROW_GAP;
    }

    private int getPopoutX() {
        return leftPos;
    }

    private int getPopoutWidth() {
        return (imageWidth - CONTROL_GAP) / 2;
    }

    private int getBackX() {
        return getPopoutX() + getPopoutWidth() + CONTROL_GAP;
    }

    private int getBackWidth() {
        return imageWidth - CONTROL_GAP - getPopoutWidth();
    }

    private boolean isOverControl(double mouseX,
                                  double mouseY,
                                  int x,
                                  int y,
                                  int controlWidth) {
        return mouseX >= x && mouseX < x + controlWidth
                && mouseY >= y && mouseY < y + CONTROL_HEIGHT;
    }

    private void playClick() {
        if (minecraft != null) {
            minecraft.getSoundManager().play(
                    SimpleSoundInstance.forUI(SoundEvents.UI_BUTTON_CLICK, 1.0F)
            );
        }
    }
}
