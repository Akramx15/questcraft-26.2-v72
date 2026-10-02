package org.vivecraft.client_vr.gameplay.screenhandlers;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.input.MouseButtonInfo;
import net.minecraft.client.Minecraft;
import net.minecraft.util.Mth;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.lwjgl.glfw.GLFW;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.gui.GuiRadial;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;

import java.util.Arrays;

public class RadialHandler {
    public static final ClientDataHolderVR DH = ClientDataHolderVR.getInstance();

    public static GuiRadial UI = new GuiRadial();
    public static RenderTarget FRAMEBUFFER = null;

    public static Vector3f POS_ROOM = new Vector3f();
    public static Matrix4f ROTATION_ROOM = new Matrix4f();

    private static boolean SHOWING = false;

    private static boolean POINTED_L;
    private static boolean POINTED_R;

    private static RadialSession SESSION;
    private static RadialReleaseLatch RELEASE_LATCH;
    private static Object SESSION_LEVEL;
    private static ControllerType CLICK_CONTROLLER;
    private static boolean LAST_PRESSED_CLICK_L;
    private static boolean LAST_PRESSED_CLICK_R;
    private static boolean LAST_PRESSED_SHIFT_L;
    private static boolean LAST_PRESSED_SHIFT_R;

    private static final int[] LAST_CHOICE = new int[ControllerType.values().length];
    private static final int[] CURSOR_X = new int[ControllerType.values().length];
    private static final int[] CURSOR_Y = new int[ControllerType.values().length];

    static {
        Arrays.fill(LAST_CHOICE, -1);
    }

    public static boolean setOverlayShowing(boolean showingState, ControllerType controller) {
        if (DH.kiosk) {
            return false;
        } else {
            if (DH.vrSettings.seated) {
                showingState = false;
            }

            if (showingState) {
                // A missing provider origin must never silently become RIGHT.
                if (controller == null) {
                    return false;
                }
                // The opener is immutable for the lifetime of the surface.
                // A simultaneous press from the other controller is ignored.
                if (SESSION != null) {
                    return SESSION.owns(controller);
                }
                RadialReleaseLatch releaseLatch = new RadialReleaseLatch(controller);
                if (releaseLatch.update(controller, sampleRadialRelease(controller)) !=
                    RadialReleaseLatch.Decision.KEEP_OPEN)
                {
                    return false;
                }
                UI.init(GuiHandler.SCALED_WIDTH_MAX, GuiHandler.SCALED_HEIGHT_MAX);
                SHOWING = true;
                SESSION = new RadialSession(controller, System.currentTimeMillis());
                RELEASE_LATCH = releaseLatch;
                SESSION_LEVEL = Minecraft.getInstance().level;
                orientOverlay(controller);
            } else {
                cancelSession();
            }

            return isShowing();
        }
    }

    public static void processGui() {
        POINTED_L = false;
        POINTED_R = false;

        if (!SHOWING) return;
        ControllerType activeController = getActiveController();
        if (activeController == null || DH.vr == null || DH.vrSettings.seated ||
            DH.vrPlayer == null || DH.vrPlayer.vrdata_room_pre == null ||
            !DH.vr.isControllerTracking(activeController) || ROTATION_ROOM == null ||
            !sessionRuntimeValid())
        {
            // Tracking loss and VR/world lifecycle transitions cancel the hold;
            // they must not turn into a synthetic release/selection.
            cancelSession();
            return;
        }

        // process cursors
        POINTED_R = UI.processCursor(POS_ROOM, ROTATION_ROOM, false);
        POINTED_L = UI.processCursor(POS_ROOM, ROTATION_ROOM, true);
    }

    public static void orientOverlay(ControllerType controller) {
        if (!isShowing()) return;

        VRData.VRDevicePose roomPose = DH.vrPlayer.vrdata_room_pre.hmd; // normal menu.
        float distance = 2.0F;
        int id = 0;

        if (controller == ControllerType.LEFT) {
            id = 1;
        }

        if (DH.vrSettings.radialModeHold) {
            // open with controller centered, consistent motions.
            roomPose = DH.vrPlayer.vrdata_room_pre.getController(id);
            distance = 1.2F;
        }

        Vector3f position = roomPose.getPositionF();
        Vector3f offset = roomPose.getDirection().mul(distance * 0.5F);

        POS_ROOM = position.add(offset);

        float pitch = (float) Math.asin(offset.y / offset.length());
        float yaw = Mth.PI + (float) Math.atan2(offset.x, offset.z);

        ROTATION_ROOM.rotationY(yaw);
        ROTATION_ROOM.rotateX(pitch);
    }

    public static void processBindings() {
        if (!isShowing()) return;

        if (!sessionRuntimeValid()) {
            cancelSession();
            return;
        }

        // TODO: this is the cause for issue https://github.com/Vivecraft/VivecraftMod/issues/240

        if (POINTED_L && GuiHandler.KEY_KEYBOARD_SHIFT.consumeClick(ControllerType.LEFT)) {
            UI.setShift(true);
            LAST_PRESSED_SHIFT_L = true;
        }

        if (!GuiHandler.KEY_KEYBOARD_SHIFT.isDown(ControllerType.LEFT) && LAST_PRESSED_SHIFT_L) {
            UI.setShift(false);
            LAST_PRESSED_SHIFT_L = false;
        }

        if (POINTED_R && GuiHandler.KEY_KEYBOARD_SHIFT.consumeClick(ControllerType.RIGHT)) {
            UI.setShift(true);
            LAST_PRESSED_SHIFT_R = true;
        }

        if (!GuiHandler.KEY_KEYBOARD_SHIFT.isDown(ControllerType.RIGHT) && LAST_PRESSED_SHIFT_R) {
            UI.setShift(false);
            LAST_PRESSED_SHIFT_R = false;
        }

        // scale virtual cursor coords to actual screen coords
        float uiScaleX = (float) UI.width / (float) GuiHandler.GUI_WIDTH;
        float uiScaleY = (float) UI.height / (float) GuiHandler.GUI_HEIGHT;

        int x1 = (int) (Math.min(Math.max((int) UI.cursorX1, 0), GuiHandler.GUI_WIDTH) * uiScaleX);
        int y1 = (int) (Math.min(Math.max((int) UI.cursorY1, 0), GuiHandler.GUI_HEIGHT) * uiScaleY);
        int x2 = (int) (Math.min(Math.max((int) UI.cursorX2, 0), GuiHandler.GUI_WIDTH) * uiScaleX);
        int y2 = (int) (Math.min(Math.max((int) UI.cursorY2, 0), GuiHandler.GUI_HEIGHT) * uiScaleY);
        CURSOR_X[ControllerType.LEFT.ordinal()] = x1;
        CURSOR_Y[ControllerType.LEFT.ordinal()] = y1;
        CURSOR_X[ControllerType.RIGHT.ordinal()] = x2;
        CURSOR_Y[ControllerType.RIGHT.ordinal()] = y2;

        if (DH.vrSettings.radialModeHold) {
            ControllerType activeController = getActiveController();
            if (activeController == null || RELEASE_LATCH == null) {
                cancelSession();
                return;
            }

            RadialReleaseLatch.Decision releaseDecision = RELEASE_LATCH.update(
                activeController, sampleRadialRelease(activeController));
            if (releaseDecision == RadialReleaseLatch.Decision.CANCEL) {
                cancelSession();
                return;
            }
            if (releaseDecision == RadialReleaseLatch.Decision.SELECT_AND_CLOSE) {
                int activeX = getCursorX(activeController);
                int activeY = getCursorY(activeController);

                // Personal Grip deliberately has no repeat-on-empty behavior:
                // every validated release represents at most one currently
                // visible selection. An off-surface release only closes.
                if (isUsingController(activeController)) {
                    click(activeController, activeX, activeY);
                }

                setOverlayShowing(false, null);
            }
        } else {
            ControllerType activeController = getActiveController();
            if (activeController == ControllerType.LEFT && POINTED_L &&
                GuiHandler.KEY_KEYBOARD_CLICK.consumeClick(ControllerType.LEFT))
            {
                click(ControllerType.LEFT, x1, y1);
                LAST_PRESSED_CLICK_L = true;
            }

            if (!GuiHandler.KEY_KEYBOARD_CLICK.isDown(ControllerType.LEFT) && LAST_PRESSED_CLICK_L) {
                release(x1, y1);
                LAST_PRESSED_CLICK_L = false;
            }

            if (activeController == ControllerType.RIGHT && POINTED_R &&
                GuiHandler.KEY_KEYBOARD_CLICK.consumeClick(ControllerType.RIGHT))
            {
                click(ControllerType.RIGHT, x2, y2);
                LAST_PRESSED_CLICK_R = true;
            }

            if (!GuiHandler.KEY_KEYBOARD_CLICK.isDown(ControllerType.RIGHT) && LAST_PRESSED_CLICK_R) {
                release(x2, y2);
                LAST_PRESSED_CLICK_R = false;
            }
        }
    }

    private static void click(ControllerType controller, int x, int y) {
        if (controller == null || SESSION == null || !SESSION.owns(controller)) {
            return;
        }
        CLICK_CONTROLLER = controller;
        try {
            UI.mouseClicked(new MouseButtonEvent(x, y, new MouseButtonInfo(GLFW.GLFW_MOUSE_BUTTON_LEFT, 0)), false);
        } finally {
            CLICK_CONTROLLER = null;
        }
    }

    private static void release(int x, int y) {
        UI.mouseReleased(new MouseButtonEvent(x, y, new MouseButtonInfo(GLFW.GLFW_MOUSE_BUTTON_LEFT, 0)));
    }

    public static boolean isShowing() {
        return SHOWING;
    }

    public static ControllerType getActiveController() {
        return SESSION == null ? null : SESSION.opener();
    }

    public static ControllerType getClickController() {
        return CLICK_CONTROLLER;
    }

    public static void recordChoice(ControllerType controller, int slot) {
        if (controller != null && slot >= 0 && slot < 9) {
            LAST_CHOICE[controller.ordinal()] = slot;
        }
    }

    public static int getLastChoice(ControllerType controller) {
        return controller == null ? -1 : LAST_CHOICE[controller.ordinal()];
    }

    public static int getCursorX(ControllerType controller) {
        return controller == null ? 0 : CURSOR_X[controller.ordinal()];
    }

    public static int getCursorY(ControllerType controller) {
        return controller == null ? 0 : CURSOR_Y[controller.ordinal()];
    }

    /** Close without dispatching a selection; safe for lifecycle transitions. */
    public static void cancelSession() {
        SHOWING = false;
        SESSION = null;
        RELEASE_LATCH = null;
        SESSION_LEVEL = null;
        CLICK_CONTROLLER = null;
        POINTED_L = false;
        POINTED_R = false;
        LAST_PRESSED_CLICK_L = false;
        LAST_PRESSED_CLICK_R = false;
        LAST_PRESSED_SHIFT_L = false;
        LAST_PRESSED_SHIFT_R = false;
    }

    public static boolean isUsingController(ControllerType controller) {
        return SESSION != null && SESSION.owns(controller) &&
            (controller == ControllerType.LEFT ? POINTED_L : POINTED_R);
    }

    private static boolean sessionRuntimeValid() {
        Minecraft minecraft = Minecraft.getInstance();
        return minecraft.level != null && minecraft.level == SESSION_LEVEL &&
            minecraft.player != null && minecraft.player.isAlive() &&
            minecraft.gui.screen() == null && !minecraft.isPaused();
    }

    private static RadialReleaseLatch.Sample sampleRadialRelease(ControllerType controller) {
        if (controller == null || DH.vr == null) {
            return RadialReleaseLatch.Sample.UNKNOWN;
        }
        VRInputAction action = DH.vr.getInputAction(VivecraftVRMod.INSTANCE.keyRadialMenu);
        if (action == null || !action.isHanded()) {
            return RadialReleaseLatch.Sample.UNKNOWN;
        }
        long origin = action.getLastOrigin(controller);
        boolean originPresent = origin != 0L;
        boolean originMatches = originPresent && DH.vr.getOriginControllerType(origin) == controller;
        return RadialReleaseLatch.sample(
            true,
            action.isEnabled(controller),
            action.isActive(controller),
            originPresent,
            originMatches,
            action.isButtonPressed(controller));
    }
}
