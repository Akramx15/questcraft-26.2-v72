package org.questcraft.veq.client.gui;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.events.GuiEventListener;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.client.resources.sounds.SimpleSoundInstance;
import net.minecraft.network.chat.Component;
import net.minecraft.sounds.SoundEvents;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.inventory.AbstractContainerMenu;
import org.questcraft.veq.client.config.VepFeatureConfig;
import org.questcraft.veq.client.overlay.VepScreenContent;
import org.questcraft.veq.mixin.CreativeOutsideClickAccessor;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;

/**
 * Direct Vivecraft host of VEP's original creative wrist content. Native
 * creative tabs/search/scroll remain owned by Minecraft; only the two VEP
 * overlay controls and its exact interaction bounds are adapted here.
 */
public final class VepCreativeWristScreen extends CreativeModeInventoryScreen
        implements VepScreenContent {
    private static final int TAB_OVERHANG = 32;
    private static final int PAGE_BUTTON_OVERHANG = 50;
    private static final int CONTROL_HEIGHT = 18;
    private static final int CONTROL_GAP = 4;
    private static final int CONTROL_ROW_GAP = 2;
    private static final int EFFECT_PANEL_WIDTH = 124;

    private static final Component POPOUT_LABEL = Component.translatable(
            "visor_essentials.inventory.creative.popout");
    private static final Component POPOUT_TOOLTIP = Component.translatable(
            "visor_essentials.inventory.creative.popout.tooltip");
    private static final Component BACK_LABEL = Component.translatable(
            "visor_essentials.inventory.creative.back");
    private static final Component BACK_TOOLTIP = Component.translatable(
            "visor_essentials.inventory.creative.back.tooltip");

    private final Runnable popoutAction;
    private final Runnable backAction;
    private final LocalPlayer player;
    private final VepScreenLayoutRevision layoutRevisionTracker =
            new VepScreenLayoutRevision();
    private Set<GuiEventListener> nativeWidgets = Set.of();
    private boolean hardClosed;

    public VepCreativeWristScreen(LocalPlayer player,
                                  FeatureFlagSet enabledFeatures,
                                  boolean displayOperatorCreativeTab,
                                  Runnable popoutAction,
                                  Runnable backAction) {
        super(player, enabledFeatures, displayOperatorCreativeTab);
        this.player = player;
        this.popoutAction = popoutAction == null ? () -> { } : popoutAction;
        this.backAction = backAction == null ? () -> { } : backAction;
    }

    @Override
    protected void init() {
        Set<GuiEventListener> preInitWidgets = Collections.newSetFromMap(new IdentityHashMap<>());
        preInitWidgets.addAll(children());
        super.init();
        Set<GuiEventListener> widgets = Collections.newSetFromMap(new IdentityHashMap<>());
        widgets.addAll(children());
        widgets.removeAll(preInitWidgets);
        nativeWidgets = widgets;
    }

    /** Keep only Minecraft's native search box/page controls in the embedded screen. */
    public void removeInjectedWidgets() {
        children().stream()
                .filter(widget -> !nativeWidgets.contains(widget))
                .toList()
                .forEach(this::removeWidget);
    }

    @Override
    public boolean showsActiveEffects() {
        return VepFeatureConfig.getInstance().showPotionEffects()
                && super.showsActiveEffects();
    }

    @Override
    public void extractRenderState(GuiGraphicsExtractor graphics,
                                   int mouseX,
                                   int mouseY,
                                   float partialTick) {
        // GuiRenderHelper hosts external surfaces by calling this method
        // directly, so Creative's normal Screen background pass is skipped.
        // Render Minecraft's own tabs, search field, scrollbar and selected
        // tab texture, then render slots/widgets above. The inherited full
        // screen dim is suppressed below so pixels outside those elements
        // remain transparent on the wrist surface.
        super.extractBackground(graphics, mouseX, mouseY, partialTick);
        graphics.nextStratum();
        super.extractRenderState(graphics, mouseX, mouseY, partialTick);
        renderControl(graphics, getPopoutX(), getControlsY(), getPopoutWidth(),
                POPOUT_LABEL, POPOUT_TOOLTIP, mouseX, mouseY);
        renderControl(graphics, getBackX(), getControlsY(), getBackWidth(),
                BACK_LABEL, BACK_TOOLTIP, mouseX, mouseY);
        // Pointer and carried-item ordering is owned by WristOverlayHandler.
    }

    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubled) {
        if (event.button() == 0 && isOverControl(
                event.x(), event.y(), getPopoutX(), getControlsY(), getPopoutWidth())) {
            playClick();
            popoutAction.run();
            return true;
        }
        if (event.button() == 0 && isOverControl(
                event.x(), event.y(), getBackX(), getControlsY(), getBackWidth())) {
            playClick();
            backAction.run();
            return true;
        }
        if (isOverControl(
                event.x(), event.y(), getPopoutX(), getControlsY(), getPopoutWidth())
                || isOverControl(
                event.x(), event.y(), getBackX(), getControlsY(), getBackWidth())
                || isOverEffectExtension(event.x(), event.y())) {
            // Non-primary control presses and the passive effect strip must
            // never fall through to Creative's outside-slot THROW behavior.
            return true;
        }
        return super.mouseClicked(event, doubled);
    }

    @Override
    protected boolean hasClickedOutside(double mouseX,
                                        double mouseY,
                                        int guiLeft,
                                        int guiTop) {
        // Creative's implementation performs native tab/drop bookkeeping;
        // always invoke it before narrowing its outside result to VEQ's full
        // interaction rectangle.
        boolean vanillaOutside = super.hasClickedOutside(
                mouseX, mouseY, guiLeft, guiTop);
        VepExtendedContainerInput.CreativeOutsideDecision decision =
                VepExtendedContainerInput.creativeOutsideDecision(
                vanillaOutside,
                mouseX,
                mouseY,
                getInteractionX(),
                getInteractionY(),
                getInteractionWidth(),
                getInteractionHeight()
        );
        // slotClicked reads this private Creative latch again on mouse-up.
        // Keep true outside/tab semantics from super, but clear the panel-only
        // outside result for VEQ controls and the passive effects extension.
        ((CreativeOutsideClickAccessor) (Object) this)
                .veq$setHasClickedOutside(decision.creativeLatch());
        return decision.outside();
    }

    @Override
    public boolean containsInteractionPoint(double x, double y) {
        int interactionX = getInteractionX();
        int interactionY = getInteractionY();
        return x >= interactionX && x < interactionX + getInteractionWidth()
                && y >= interactionY && y < interactionY + getInteractionHeight();
    }

    @Override
    public VepCreativeWristScreen screen() {
        return this;
    }

    @Override
    public AbstractContainerMenu menu() {
        return getMenu();
    }

    @Override
    public void hardClose() {
        if (hardClosed) {
            return;
        }
        hardClosed = true;
        removed();
        if (player.containerMenu == getMenu()) {
            player.containerMenu = player.inventoryMenu;
        }
    }

    @Override
    public VepWristInventoryScreen.Bounds contentBounds() {
        return new VepWristInventoryScreen.Bounds(
                getInteractionX(), getInteractionY(), getInteractionWidth(), getInteractionHeight());
    }

    @Override
    public VepWristInventoryScreen.Bounds visualBounds() {
        return VepSurfaceBackdrop.visualBounds(contentBounds(), width, height);
    }

    @Override
    public long visualLayoutRevision() {
        boolean effectsVisible = showsActiveEffects();
        int effectCount = effectsVisible && minecraft != null && minecraft.player != null
                ? minecraft.player.getActiveEffects().size()
                : 0;
        return layoutRevisionTracker.update(
                leftPos,
                topPos,
                width,
                height,
                VepFeatureConfig.getInstance().revision(),
                effectCount,
                0L,
                effectsVisible ? 1 : 0
        );
    }

    @Override
    public boolean isPauseScreen() {
        return false;
    }

    @Override
    public boolean isInGameUi() {
        return true;
    }

    @Override
    public void extractTransparentBackground(GuiGraphicsExtractor graphics) {
        // This Screen lives in an already-cleared transparent RenderTarget,
        // not in Minecraft's global GUI. A canvas-wide dim would turn the
        // cropped wrist quad into the opaque rectangle seen in the headset.
    }

    private int getInteractionX() {
        return leftPos;
    }

    private int getInteractionY() {
        return Math.max(0, Math.min(topPos - TAB_OVERHANG, topPos - PAGE_BUTTON_OVERHANG));
    }

    private int getInteractionWidth() {
        int widthWithEffects = showsActiveEffects() ? imageWidth + EFFECT_PANEL_WIDTH : imageWidth;
        return Math.min(width - leftPos, widthWithEffects);
    }

    private int getInteractionHeight() {
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
        boolean hovered = isOverControl(mouseX, mouseY, x, y, controlWidth);
        int background = hovered ? 0xEA454545 : 0xDA202020;
        int border = hovered ? 0xFFFFFFFF : 0xFF9A9A9A;
        graphics.fill(x, y, x + controlWidth, y + CONTROL_HEIGHT, background);
        graphics.fill(x, y, x + controlWidth, y + 1, border);
        graphics.fill(x, y + CONTROL_HEIGHT - 1, x + controlWidth, y + CONTROL_HEIGHT, border);
        graphics.fill(x, y, x + 1, y + CONTROL_HEIGHT, border);
        graphics.fill(x + controlWidth - 1, y, x + controlWidth, y + CONTROL_HEIGHT, border);
        graphics.centeredText(font, label, x + controlWidth / 2,
                y + (CONTROL_HEIGHT - 8) / 2, 0xFFFFFFFF);
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

    private boolean isOverEffectExtension(double mouseX, double mouseY) {
        int effectX = leftPos + imageWidth;
        int interactionRight = getInteractionX() + getInteractionWidth();
        return showsActiveEffects() && VepExtendedContainerInput.contains(
                mouseX,
                mouseY,
                effectX,
                getInteractionY(),
                interactionRight - effectX,
                getInteractionHeight()
        );
    }

    private void playClick() {
        if (minecraft != null) {
            minecraft.getSoundManager().play(
                    SimpleSoundInstance.forUI(SoundEvents.UI_BUTTON_CLICK, 1.0F));
        }
    }
}
