package org.questcraft.veq.client.gui;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;
import org.questcraft.veq.client.config.QuickActionDisplayMode;
import org.questcraft.veq.client.config.VepFeatureConfig;
import org.questcraft.veq.client.config.WristHand;
import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.questcraft.veq.client.wrist.WristCalibrationMode;
import org.vivecraft.client_vr.provider.ControllerType;

import java.util.Locale;
import java.util.function.DoubleConsumer;
import java.util.function.DoubleSupplier;

/** Transactional, live wrist-pose editor. Nothing is persisted before Apply. */
public final class WristSettingsScreen extends Screen {
    private static final int ROW_HEIGHT = 24;
    private final Screen parent;
    private final WristUiConfig config = WristUiConfig.getInstance();
    private final VepFeatureConfig features = VepFeatureConfig.getInstance();
    private EditorTab editorTab = EditorTab.POSITION;
    private boolean transactionStarted;
    private boolean completed;

    public WristSettingsScreen(Screen parent) {
        super(Component.translatable("vivecraft_essentials_quest.settings"));
        this.parent = parent;
    }

    @Override
    protected void init() {
        if (!transactionStarted) {
            config.beginEditing();
            features.beginEditing();
            transactionStarted = true;
        }
        WristOverlayHandler.beginCalibration(calibrationMode());
        WristOverlayHandler.refreshCalibrationPreview();

        int center = width / 2;
        int y = 38;
        addRenderableWidget(button(center - 154, y, 150, toggleLabel("enabled", config.enabled()), () -> {
            config.setEnabled(!config.enabled());
            rebuildWidgets();
        }));
        addRenderableWidget(button(center + 4, y, 150, Component.translatable(
                "vivecraft_essentials_quest.hand",
                Component.translatable(config.hand() == WristHand.OFF_HAND
                        ? "vivecraft_essentials_quest.off_hand"
                        : "vivecraft_essentials_quest.main_hand")
        ), () -> {
            editPose(() -> config.setHand(config.hand().next()));
            rebuildWidgets();
        }));
        y += ROW_HEIGHT;

        addRenderableWidget(button(center - 154, y, 150, toggleLabel("radial", config.radialHotbarEnabled()), () -> {
            config.setRadialHotbarEnabled(!config.radialHotbarEnabled());
            rebuildWidgets();
        }));
        addRenderableWidget(button(center + 4, y, 150, valueLabel(
                "sensitivity",
                config.activationSensitivity()
        ), () -> {
            float next = config.activationSensitivity() + 0.10F;
            config.setActivationSensitivity(next > 1.0F ? 0.0F : next);
            rebuildWidgets();
        }));
        y += ROW_HEIGHT + 2;

        EditorTab[] tabs = EditorTab.values();
        for (int index = 0; index < tabs.length; index++) {
            EditorTab tab = tabs[index];
            addRenderableWidget(button(
                    center - 154 + index * 78,
                    y,
                    74,
                    tabLabel(tab),
                    () -> selectTab(tab)
            ));
        }
        y += ROW_HEIGHT + 2;

        if (editorTab == EditorTab.FEATURES) {
            y = addFeatureRows(center, y);
        } else {
            switch (editorTab) {
                case POSITION -> {
                    y = addAdjustRow(center, y, "offset_x", config::offsetX,
                            value -> config.setOffset((float) value, config.offsetY(), config.offsetZ()), 0.005);
                    y = addAdjustRow(center, y, "offset_y", config::offsetY,
                            value -> config.setOffset(config.offsetX(), (float) value, config.offsetZ()), 0.005);
                    y = addAdjustRow(center, y, "offset_z", config::offsetZ,
                            value -> config.setOffset(config.offsetX(), config.offsetY(), (float) value), 0.005);
                }
                case ROTATION -> {
                    float radiansStep = (float) Math.toRadians(2.5);
                    y = addRotationRow(center, y, "rotation_x", config::rotationX,
                            () -> config.rotate(-radiansStep, 0.0F, 0.0F),
                            () -> config.rotate(radiansStep, 0.0F, 0.0F));
                    y = addRotationRow(center, y, "rotation_y", config::rotationY,
                            () -> config.rotate(0.0F, -radiansStep, 0.0F),
                            () -> config.rotate(0.0F, radiansStep, 0.0F));
                    y = addRotationRow(center, y, "rotation_z", config::rotationZ,
                            () -> config.rotate(0.0F, 0.0F, -radiansStep),
                            () -> config.rotate(0.0F, 0.0F, radiansStep));
                }
                case SCALE -> y = addAdjustRow(center, y, "scale", config::scale,
                        value -> config.setScale((float) value), 0.025);
                case FEATURES -> throw new IllegalStateException("Features tab handled separately");
            }

            y += 2;
            addRenderableWidget(button(center - 154, y, 150,
                    Component.translatable("vivecraft_essentials_quest.reset_pose"), () -> {
                        editPose(() -> config.resetPose(activeController()));
                        rebuildWidgets();
                    }));
            addRenderableWidget(button(center + 4, y, 150,
                    Component.translatable("vivecraft_essentials_quest.flip_face"), () -> {
                        editPose(() -> config.flipFace(activeController()));
                        rebuildWidgets();
                    }));
        }

        int bottom = Math.min(height - 28, y + ROW_HEIGHT + 4);
        addRenderableWidget(button(center - 154, bottom, 150,
                Component.translatable("vivecraft_essentials_quest.cancel"), this::cancel));
        Button apply = button(center + 4, bottom, 150,
                Component.translatable("vivecraft_essentials_quest.apply"), this::apply);
        apply.active = !isReadOnly();
        addRenderableWidget(apply);
    }

    @Override
    public void extractRenderState(GuiGraphicsExtractor graphics, int mouseX, int mouseY, float partialTick) {
        extractBackground(graphics, mouseX, mouseY, partialTick);
        graphics.centeredText(font, title, width / 2, 10, 0xFFFFFFFF);
        graphics.centeredText(
                font,
                Component.translatable(
                        editorTab == EditorTab.SCALE
                                ? "vivecraft_essentials_quest.calibrate_scale_hint"
                                : "vivecraft_essentials_quest.calibrate_move_hint"
                ),
                width / 2,
                23,
                isReadOnly() ? 0xFFFF8080 : 0xFF80E080
        );
        super.extractRenderState(graphics, mouseX, mouseY, partialTick);
    }

    @Override
    public void onClose() {
        cancel();
    }

    @Override
    public boolean isPauseScreen() {
        // Calibration needs live controller poses and a live preview surface.
        return false;
    }

    @Override
    public void removed() {
        if (!completed) {
            config.cancelEditing();
            features.cancelEditing();
            WristOverlayHandler.endCalibration();
            WristOverlayHandler.forceHide();
        }
        super.removed();
    }

    private void selectTab(EditorTab next) {
        editorTab = next;
        WristOverlayHandler.cancelCalibrationGrab();
        WristOverlayHandler.setCalibrationMode(calibrationMode());
        WristOverlayHandler.refreshCalibrationPreview();
        rebuildWidgets();
    }

    private WristCalibrationMode calibrationMode() {
        return editorTab == EditorTab.SCALE
                ? WristCalibrationMode.SCALE
                : WristCalibrationMode.MOVE_ROTATE;
    }

    private ControllerType activeController() {
        return config.hand() == WristHand.OFF_HAND ? ControllerType.LEFT : ControllerType.RIGHT;
    }

    private void apply() {
        if (isReadOnly()) {
            return;
        }
        config.applyEditing();
        features.applyEditing();
        completed = true;
        WristOverlayHandler.endCalibration();
        WristOverlayHandler.forceHide();
        minecraft.gui.setScreen(parent);
    }

    private void cancel() {
        config.cancelEditing();
        features.cancelEditing();
        completed = true;
        WristOverlayHandler.endCalibration();
        WristOverlayHandler.forceHide();
        minecraft.gui.setScreen(parent);
    }

    private int addFeatureRows(int center, int y) {
        addRenderableWidget(button(center - 154, y, 150,
                toggleLabel("effects", features.showPotionEffects()), () -> {
                    features.setShowPotionEffects(!features.showPotionEffects());
                    rebuildWidgets();
                }));
        addRenderableWidget(button(center + 4, y, 150, Component.translatable(
                "vivecraft_essentials_quest.actions",
                features.quickActionDisplayMode().name().toLowerCase(Locale.ROOT)
        ), () -> {
            QuickActionDisplayMode next = features.quickActionDisplayMode().next();
            features.setQuickActionDisplayMode(next);
            rebuildWidgets();
        }));
        y += ROW_HEIGHT;

        addRenderableWidget(button(center - 154, y, 150,
                toggleLabel("status_hud", features.showStatusHud()), () -> {
                    features.setShowStatusHud(!features.showStatusHud());
                    rebuildWidgets();
                }));
        addRenderableWidget(button(center + 4, y, 150,
                toggleLabel("contextual_containers", features.contextualContainers()), () -> {
                    features.setContextualContainers(!features.contextualContainers());
                    rebuildWidgets();
                }));
        y += ROW_HEIGHT;

        addRenderableWidget(button(center - 154, y, 150,
                toggleLabel("xaero", features.xaeroIntegration()), () -> {
                    features.setIntegration(
                            VepFeatureConfig.OptionalIntegration.XAERO,
                            !features.xaeroIntegration()
                    );
                    rebuildWidgets();
                }));
        addRenderableWidget(button(center + 4, y, 150,
                toggleLabel("jei", features.jeiIntegration()), () -> {
                    features.setIntegration(
                            VepFeatureConfig.OptionalIntegration.JEI,
                            !features.jeiIntegration()
                    );
                    rebuildWidgets();
                }));
        y += ROW_HEIGHT;

        addRenderableWidget(button(center - 154, y, 150,
                toggleLabel("inventory_profiles", features.inventoryProfilesIntegration()), () -> {
                    features.setIntegration(
                            VepFeatureConfig.OptionalIntegration.INVENTORY_PROFILES_NEXT,
                            !features.inventoryProfilesIntegration()
                    );
                    rebuildWidgets();
                }));
        addRenderableWidget(button(center + 4, y, 150,
                toggleLabel("player_preview", features.showPlayerPreview()), () -> {
                    features.setShowPlayerPreview(!features.showPlayerPreview());
                    rebuildWidgets();
                }));
        return y + ROW_HEIGHT;
    }

    private boolean isReadOnly() {
        return config.isFutureVersionReadOnly() || features.isFutureVersionReadOnly();
    }

    private int addAdjustRow(
            int center,
            int y,
            String key,
            DoubleSupplier getter,
            DoubleConsumer setter,
            double step
    ) {
        addRenderableWidget(button(center - 154, y, 32, Component.literal("−"), () -> {
            editPose(() -> setter.accept(getter.getAsDouble() - step));
            rebuildWidgets();
        }));
        Button value = button(center - 118, y, 236, valueLabel(key, getter.getAsDouble()), () -> {
        });
        value.active = false;
        addRenderableWidget(value);
        addRenderableWidget(button(center + 122, y, 32, Component.literal("+"), () -> {
            editPose(() -> setter.accept(getter.getAsDouble() + step));
            rebuildWidgets();
        }));
        return y + ROW_HEIGHT;
    }

    private int addRotationRow(
            int center,
            int y,
            String key,
            DoubleSupplier getter,
            Runnable decrement,
            Runnable increment
    ) {
        addRenderableWidget(button(center - 154, y, 32, Component.literal("−"), () -> {
            editPose(decrement);
            rebuildWidgets();
        }));
        Button value = button(center - 118, y, 236, valueLabel(key, getter.getAsDouble()), () -> {
        });
        value.active = false;
        addRenderableWidget(value);
        addRenderableWidget(button(center + 122, y, 32, Component.literal("+"), () -> {
            editPose(increment);
            rebuildWidgets();
        }));
        return y + ROW_HEIGHT;
    }

    /**
     * Fine controls and direct Grip grabs edit one shared draft. Cancel a live
     * grab first so its cached start transform cannot overwrite a button edit,
     * then immediately re-compose the preview used by render, hit-test and
     * visibility. Persistence still happens only in {@link #apply()}.
     */
    private void editPose(Runnable mutation) {
        WristOverlayHandler.cancelCalibrationGrab();
        mutation.run();
        WristOverlayHandler.refreshCalibrationPreview();
    }

    private Component tabLabel(EditorTab tab) {
        String marker = tab == editorTab ? "● " : "";
        return Component.literal(marker).append(Component.translatable(tab.translationKey));
    }

    private static Component valueLabel(String key, double value) {
        boolean rotation = key.startsWith("rotation_");
        double display = rotation ? Math.toDegrees(value) : value;
        String formatted = rotation
                ? String.format(Locale.ROOT, "%.1f°", display)
                : String.format(Locale.ROOT, "%.3f", display);
        return Component.translatable("vivecraft_essentials_quest." + key, formatted);
    }

    private static Component toggleLabel(String key, boolean value) {
        return Component.translatable(
                "vivecraft_essentials_quest." + key,
                Component.translatable(value
                        ? "vivecraft_essentials_quest.on"
                        : "vivecraft_essentials_quest.off")
        );
    }

    private static Button button(int x, int y, int width, Component label, Runnable action) {
        return Button.builder(label, ignored -> action.run()).bounds(x, y, width, 20).build();
    }

    private enum EditorTab {
        POSITION("vivecraft_essentials_quest.position"),
        ROTATION("vivecraft_essentials_quest.rotation"),
        SCALE("vivecraft_essentials_quest.size"),
        FEATURES("vivecraft_essentials_quest.features");

        private final String translationKey;

        EditorTab(String translationKey) {
            this.translationKey = translationKey;
        }
    }
}
