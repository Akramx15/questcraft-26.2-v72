package org.questcraft.veq.client.radial;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.util.Mth;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.questcraft.veq.client.config.GripHotbarConfig;
import org.questcraft.veq.client.config.GripHotbarProfile;
import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.client.input.GripRuntimeGate;
import org.questcraft.veq.client.wrist.WristSurfaceMath;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;
import org.vivecraft.client_vr.render.helpers.ExternalOverlayRenderPolicy;

import java.util.Locale;

/**
 * One independently registered 98x98 Grip surface for one logical hand.
 *
 * <p>RIGHT and LEFT deliberately own different surface instances, screens,
 * cursors, poses and feedback state. Both can therefore be visible at once;
 * closing or selecting one hand cannot queue, transfer, or hide the other.</p>
 */
public final class GripHotbarOverlay implements ExternalScreenOverlayHandler.OverlaySurface {
    public static final String SURFACE_ID = "vivecraft_essentials_quest:grip_hotbar";
    public static final int LOGICAL_SIZE = HotbarGridLayout.PANEL_SIZE;
    /** Match Visor's GUI-scale-4 raster density while retaining 98px input coordinates. */
    public static final int RENDER_SIZE = LOGICAL_SIZE * 4;
    public static final int SURFACE_PRIORITY = 40;
    private static final GripHotbarOverlay RIGHT = new GripHotbarOverlay(ControllerType.RIGHT);
    private static final GripHotbarOverlay LEFT = new GripHotbarOverlay(ControllerType.LEFT);

    private final ControllerType owner;
    private final GripSurfaceSession session;
    private final GripFeedbackState feedback = new GripFeedbackState();
    private final HotbarRadialScreen screen = new HotbarRadialScreen(this.feedback);
    private final Vector3f roomPosition = new Vector3f();
    private final Matrix4f roomRotation = new Matrix4f();
    private final Vector3f hmdToPanel = new Vector3f();
    private final Vector3f rayNormal = new Vector3f();
    private final Vector3f rayRight = new Vector3f();
    private final Vector3f rayUp = new Vector3f();
    private final Vector3f rayTopLeft = new Vector3f();
    private final Vector3f rayDelta = new Vector3f();
    private final Vector3f rayIntersection = new Vector3f();
    private final Vector2f rayUv = new Vector2f();
    private final ExternalScreenOverlayHandler.RenderCursor cursor =
            new ExternalScreenOverlayHandler.RenderCursor();

    private boolean installed;
    private float scale = GripHotbarConfig.DEFAULT_SCALE;
    private Object sessionLevel;
    private Object sessionPlayer;
    private Object sessionInventory;
    private Object sessionMenu;

    private GripHotbarOverlay(ControllerType owner) {
        this.owner = owner;
        this.session = new GripSurfaceSession(owner);
    }

    public static void install() {
        RIGHT.installInternal();
        LEFT.installInternal();
    }

    public static boolean requestOpen(ControllerType controller) {
        install();
        GripHotbarOverlay surface = surface(controller);
        return surface != null && surface.requestOpenInternal();
    }

    /** Cancels both surfaces only for an explicit global/lifecycle close. */
    public static void cancel() {
        RIGHT.closeSurface();
        LEFT.closeSurface();
        HotbarSlotButton.cancelSession();
    }

    public static void tick() {
        if (!WristUiConfig.getInstance().radialHotbarEnabled()) {
            cancel();
            return;
        }
        RIGHT.tickInternal();
        LEFT.tickInternal();
    }

    public static boolean ownsSession(ControllerType controller) {
        GripHotbarOverlay surface = surface(controller);
        return surface != null && surface.session.owns(controller);
    }

    @Override
    public String id() {
        return SURFACE_ID + "/" + this.owner.name().toLowerCase(Locale.ROOT);
    }

    @Override
    public String name() {
        return "Vivecraft Essentials Quest Grip Hotbar " + this.owner.name();
    }

    @Override
    public Screen screen() {
        return this.screen;
    }

    @Override
    public boolean isShowing() {
        return this.session.isShowing();
    }

    @Override
    public Vector3fc roomPosition() {
        return this.roomPosition;
    }

    @Override
    public Matrix4fc roomRotation() {
        return this.roomRotation;
    }

    @Override
    public float scale() {
        return this.scale;
    }

    @Override
    public int priority() {
        // Wrist must be able to take this same hand from an open Grip surface.
        return SURFACE_PRIORITY;
    }

    @Override
    public ExternalOverlayRenderPolicy.WorldOcclusion worldOcclusion() {
        return GripOverlayRenderPolicy.worldOcclusion();
    }

    @Override
    public int renderWidth() {
        return RENDER_SIZE;
    }

    @Override
    public int renderHeight() {
        return RENDER_SIZE;
    }

    @Override
    public int scaledWidth() {
        return LOGICAL_SIZE;
    }

    @Override
    public int scaledHeight() {
        return LOGICAL_SIZE;
    }

    @Override
    public void resize(int scaledWidth, int scaledHeight) {
        this.screen.init(LOGICAL_SIZE, LOGICAL_SIZE);
    }

    @Override
    public ExternalScreenOverlayHandler.RenderCursor cursor(ControllerType controller) {
        return this.session.owns(controller)
                ? this.cursor
                : ExternalScreenOverlayHandler.RenderCursor.invalid();
    }

    @Override
    public ExternalScreenOverlayHandler.RenderCursor renderCursor() {
        return this.session.isShowing()
                ? this.cursor
                : ExternalScreenOverlayHandler.RenderCursor.invalid();
    }

    @Override
    public boolean isUsingController(ControllerType controller) {
        return this.session.owns(controller);
    }

    @Override
    public void processGui() {
        if (!this.session.isShowing() || !runtimeValid() ||
                !GripRuntimeGate.allowRadialContinuation(this.owner)) {
            closeSurface();
            return;
        }
        updateCursor();
    }

    @Override
    public void processBindings() {
        if (!this.session.isShowing()) {
            return;
        }
        // Recheck at the exact release boundary. A Wrist, ImmersiveMC, climb,
        // bow, or lifecycle takeover closes this hand only and never clicks.
        if (!runtimeValid() || !GripRuntimeGate.allowRadialContinuation(this.owner)) {
            closeSurface();
            return;
        }

        GripSample sample = sampleGrip();
        if (sample == GripSample.DOWN) {
            return;
        }
        if (sample != GripSample.RELEASED) {
            closeSurface();
            return;
        }

        int selected = HotbarHandState.hovered(this.owner);
        if (this.cursor.valid() && selected >= 0) {
            HotbarSlotButton.select(this.owner, selected);
        }

        // A LEFT Vanilla SWAP reconciles passively after this point. The
        // released surface never remains as a read-only spinner and never
        // blocks RIGHT from opening or selecting immediately.
        closeSurface();
    }

    private void installInternal() {
        if (!this.installed) {
            ExternalScreenOverlayHandler.registerSurface(this);
            this.installed = true;
        }
    }

    private boolean requestOpenInternal() {
        boolean continuing = this.session.isShowing();
        boolean ownershipAllowed = continuing
                ? GripRuntimeGate.allowRadialContinuation(this.owner)
                : GripRuntimeGate.allowRadial(this.owner);
        if (!WristUiConfig.getInstance().radialHotbarEnabled() ||
                sampleGrip() != GripSample.DOWN || !ownershipAllowed) {
            return false;
        }
        if (continuing) {
            return true;
        }

        Minecraft minecraft = Minecraft.getInstance();
        this.sessionLevel = minecraft.level;
        this.sessionPlayer = minecraft.player;
        this.sessionInventory = minecraft.player == null
                ? null
                : minecraft.player.getInventory();
        this.sessionMenu = minecraft.player == null
                ? null
                : minecraft.player.inventoryMenu;
        if (!this.session.open(this.owner, true)) {
            clearSessionIdentity();
            return false;
        }
        beginVisibleSession();
        return this.session.isShowing();
    }

    private void tickInternal() {
        if (this.session.isShowing() && (!runtimeValid() ||
                !GripRuntimeGate.allowRadialContinuation(this.owner))) {
            closeSurface();
        }
    }

    private void beginVisibleSession() {
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        if (dataHolder.vrPlayer == null || dataHolder.vrPlayer.vrdata_room_pre == null) {
            closeSurface();
            return;
        }
        VRData.VRDevicePose pose = dataHolder.vrPlayer.vrdata_room_pre
                .getController(this.owner.ordinal());
        if (pose == null) {
            closeSurface();
            return;
        }
        GripHotbarProfile profile = GripHotbarConfig.getInstance().profile(this.owner);
        Vector3f direction = pose.getDirection();
        this.roomPosition.set(pose.getPositionF()).fma(profile.distance(), direction);
        // Freeze the surface on open, but face its visible +Z side toward the
        // HMD. Keeping it perpendicular to controller Aim made the square look
        // foreshortened (and therefore smaller/blurrier) from the user's eyes.
        // The center remains exactly on the opening controller's ray, so its
        // selection geometry and per-hand ownership do not change.
        if (!GripSurfacePoseMath.orientTowardViewer(
                this.roomPosition,
                dataHolder.vrPlayer.vrdata_room_pre.hmd.getPositionF(),
                this.hmdToPanel,
                this.roomRotation
        )) {
            float pitch = (float) Math.asin(Mth.clamp(direction.y, -1.0F, 1.0F));
            float yaw = Mth.PI + (float) Math.atan2(direction.x, direction.z);
            this.roomRotation.identity().rotationY(yaw).rotateX(pitch);
        }
        this.scale = profile.scale();
        this.feedback.clear();
        // beginSession deliberately clears only this logical owner's hover.
        this.screen.beginSession(this.owner);
        this.cursor.setInvalid();
    }

    private void updateCursor() {
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        VRData.VRDevicePose pointer = dataHolder.vrPlayer.vrdata_room_pre
                .getController(this.owner.ordinal());
        GripHotbarProfile profile = GripHotbarConfig.getInstance().profile(this.owner);
        boolean intersects = pointer != null && WristSurfaceMath.rayToUv(
                pointer.getPositionF(),
                pointer.getDirection(),
                this.roomPosition,
                this.roomRotation,
                this.scale,
                1.0F,
                this.rayUv,
                this.rayNormal,
                this.rayRight,
                this.rayUp,
                this.rayTopLeft,
                this.rayDelta,
                this.rayIntersection
        );
        if (intersects) {
            float u = 0.5F + (this.rayUv.x - 0.5F) * profile.sensitivity();
            float v = 0.5F + (this.rayUv.y - 0.5F) * profile.sensitivity();
            intersects = u >= 0.0F && u <= 1.0F && v >= 0.0F && v <= 1.0F;
            if (intersects) {
                this.cursor.set(u * LOGICAL_SIZE, v * LOGICAL_SIZE,
                        this.owner, true, true, true);
                this.screen.updateSelection(
                        this.owner, true, this.cursor.x(), this.cursor.y());
            }
        }
        if (!intersects) {
            this.cursor.setInvalid();
            this.screen.updateSelection(this.owner, false, -1.0D, -1.0D);
        }
    }

    private boolean runtimeValid() {
        Minecraft minecraft = Minecraft.getInstance();
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        return dataHolder.vr != null && dataHolder.vrPlayer != null &&
                dataHolder.vrPlayer.vrdata_room_pre != null &&
                dataHolder.vr.isControllerTracking(this.owner) &&
                minecraft.player != null && minecraft.player.isAlive() &&
                minecraft.level != null && minecraft.level == this.sessionLevel &&
                minecraft.player == this.sessionPlayer &&
                minecraft.player.getInventory() == this.sessionInventory &&
                minecraft.player.inventoryMenu == this.sessionMenu &&
                minecraft.gui.screen() == null && !minecraft.isPaused();
    }

    /** Closes exactly this logical hand; passive inventory reconciliation survives. */
    private void closeSurface() {
        this.session.close();
        this.feedback.clear();
        this.cursor.setInvalid();
        HotbarHandState.updateHover(this.owner, false, -1);
        clearSessionIdentity();
    }

    private void clearSessionIdentity() {
        this.sessionLevel = null;
        this.sessionPlayer = null;
        this.sessionInventory = null;
        this.sessionMenu = null;
    }

    private GripSample sampleGrip() {
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        if (dataHolder.vr == null) {
            return GripSample.UNKNOWN;
        }
        VRInputAction action = dataHolder.vr.getInputAction(VivecraftVRMod.INSTANCE.keyRadialMenu);
        if (action == null || !action.isHanded() || !action.isEnabledRaw(this.owner) ||
                !action.isActive(this.owner)) {
            return GripSample.UNKNOWN;
        }
        long origin = action.getLastOrigin(this.owner);
        if (origin == 0L || dataHolder.vr.getOriginControllerType(origin) != this.owner) {
            return GripSample.UNKNOWN;
        }
        return action.isButtonPressed(this.owner) ? GripSample.DOWN : GripSample.RELEASED;
    }

    private static GripHotbarOverlay surface(ControllerType controller) {
        if (controller == ControllerType.RIGHT) {
            return RIGHT;
        }
        if (controller == ControllerType.LEFT) {
            return LEFT;
        }
        return null;
    }

    private enum GripSample {
        DOWN,
        RELEASED,
        UNKNOWN
    }
}
