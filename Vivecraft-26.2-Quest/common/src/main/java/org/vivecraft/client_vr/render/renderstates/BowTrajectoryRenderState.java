package org.vivecraft.client_vr.render.renderstates;

import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.VertexConsumer;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.client.renderer.SubmitNodeCollector;
import net.minecraft.resources.Identifier;
import net.minecraft.util.Util;
import net.minecraft.world.level.ClipContext;
import net.minecraft.world.phys.HitResult;
import net.minecraft.world.phys.Vec3;
import org.joml.Vector3fc;
import org.vivecraft.client.network.ClientNetworking;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.gameplay.trackers.BowTracker;
import org.vivecraft.client_vr.settings.VRSettings;

import javax.annotation.Nullable;

/**
 * Per-frame bow preview snapshot and its reusable Vulkan geometry renderer.
 *
 * <p>The personal Quest canary enables this by default. It can still be
 * disabled at startup with {@code -Dvivecraft.questBowTrajectoryPreview=false}.
 * Its primitive arrays and renderer instance live for the lifetime of the VR
 * render state.</p>
 */
public final class BowTrajectoryRenderState implements SubmitNodeCollector.CustomGeometryRenderer {
    static final String ENABLE_PROPERTY = "vivecraft.questBowTrajectoryPreview";
    static final int MAX_POINTS = 33;

    private static final boolean ENABLED = parseEnabled(System.getProperty(ENABLE_PROPERTY, "true"));
    private final double[] pointsX = new double[MAX_POINTS];
    private final double[] pointsY = new double[MAX_POINTS];
    private final double[] pointsZ = new double[MAX_POINTS];
    private final double[] pathDistance = new double[MAX_POINTS];
    private final ImpactRenderer impactRenderer = new ImpactRenderer();

    private int pointCount;
    private double totalPathDistance;
    private double cameraX;
    private double cameraY;
    private double cameraZ;
    private VRSettings.BowGuideStyle style = VRSettings.BowGuideStyle.OFF;
    private BowGuideTheme theme = BowGuideThemes.energy();
    private float animationSeconds;
    private boolean impactVisible;
    private double impactX;
    private double impactY;
    private double impactZ;
    private double impactAxisAX;
    private double impactAxisAY;
    private double impactAxisAZ;
    private double impactAxisBX;
    private double impactAxisBY;
    private double impactAxisBZ;

    static boolean parseEnabled(@Nullable String value) {
        return Boolean.parseBoolean(value);
    }

    public boolean isVisible() {
        return this.style != VRSettings.BowGuideStyle.OFF && this.pointCount >= 2;
    }

    public boolean hasImpactMarker() {
        return this.impactVisible && this.theme.impactShape() != BowGuideTheme.ImpactShape.NONE;
    }

    public SubmitNodeCollector.CustomGeometryRenderer impactRenderer() {
        return this.impactRenderer;
    }

    public boolean usesTexturedRibbon() {
        return this.isVisible() && this.theme.mode() == BowGuideTheme.Mode.RIBBON;
    }

    public Identifier texture() {
        return this.theme.texture();
    }

    public void extract(@Nullable LocalPlayer player, ArmsRenderState armsState) {
        this.pointCount = 0;
        this.impactVisible = false;
        this.style = VRSettings.BowGuideStyle.OFF;
        if (!ENABLED || player == null || !player.isAlive()) {
            return;
        }

        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        this.style = dataHolder.vrSettings.bowGuideStyle;
        if (this.style == VRSettings.BowGuideStyle.OFF) {
            return;
        }
        this.theme = this.style == VRSettings.BowGuideStyle.CLASSIC ?
            BowGuideThemes.classic() : BowGuideThemes.energy();
        BowTracker bow = dataHolder.bowTracker;
        Vector3fc aim = bow.getAimVector();
        if (!bow.isDrawing() || aim == null || !Float.isFinite(aim.x()) || !Float.isFinite(aim.y()) ||
            !Float.isFinite(aim.z()) || aim.lengthSquared() < 1.0E-6F)
        {
            return;
        }

        long elapsedMillis = Math.max(0L, Util.getMillis() - bow.startDrawTime);
        int useTicks = (int) Math.min(Integer.MAX_VALUE, elapsedMillis / 50L);
        float vanillaPower = BowTrajectoryMath.vanillaPowerForTicks(useTicks);
        // BowItem does not release an arrow below this vanilla threshold.
        if (vanillaPower < 0.1F) {
            return;
        }

        double speed = BowTrajectoryMath.launchSpeed(
            vanillaPower, bow.getDrawPercent(), ClientNetworking.SERVER_HAS_VIVECRAFT);
        int arrowHand = dataHolder.vrSettings.reverseShootingEye && ClientNetworking.supportsReversedBow() ? 1 : 0;
        // ArmsRenderState already snapshots these exact controller render
        // positions for the frame; reuse it instead of allocating another
        // VRDevicePose position solely for the preview.
        Vec3 start = ClientNetworking.SERVER_HAS_VIVECRAFT ?
            (arrowHand == 0 ? armsState.mainHandWorldPos : armsState.offHandWorldPos) :
            // Vanilla servers construct the arrow at the player's ordinary
            // projectile origin even though Vivecraft temporarily sends the
            // controller aim as player yaw/pitch.
            new Vec3(player.getX(), player.getEyeY() - 0.10000000149011612D, player.getZ());
        if (start == null) {
            return;
        }
        Vec3 movement = player.getKnownMovement();

        this.pointCount = BowTrajectoryMath.sampleAirCenterline(
            start.x, start.y, start.z,
            aim.x() * speed + movement.x,
            aim.y() * speed + (player.onGround() ? 0.0D : movement.y),
            aim.z() * speed + movement.z,
            this.pointsX, this.pointsY, this.pointsZ, MAX_POINTS);
        this.animationSeconds = (Util.getMillis() % 60_000L) * 0.001F;
        this.truncateAtFirstBlock(player);
        this.updatePathDistances();
    }

    private void updatePathDistances() {
        this.totalPathDistance = 0.0D;
        if (this.pointCount == 0) {
            return;
        }
        this.pathDistance[0] = 0.0D;
        for (int i = 1; i < this.pointCount; i++) {
            double dx = this.pointsX[i] - this.pointsX[i - 1];
            double dy = this.pointsY[i] - this.pointsY[i - 1];
            double dz = this.pointsZ[i] - this.pointsZ[i - 1];
            this.totalPathDistance += Math.sqrt(dx * dx + dy * dy + dz * dz);
            this.pathDistance[i] = this.totalPathDistance;
        }
    }

    /**
     * Stops the solid preview at the first world collider.  Sampling and
     * clipping happen only in VRRenderState's first-pass extraction, then the
     * exact same snapshot is submitted to both eyes.  Entity motion, launch
     * spread and water drag remain intentionally outside this lightweight
     * Quest preview.
     */
    private void truncateAtFirstBlock(LocalPlayer player) {
        if (this.pointCount < 2) {
            return;
        }

        Vec3 previous = new Vec3(this.pointsX[0], this.pointsY[0], this.pointsZ[0]);
        for (int i = 1; i < this.pointCount; i++) {
            Vec3 next = new Vec3(this.pointsX[i], this.pointsY[i], this.pointsZ[i]);
            HitResult hit = player.level().clipIncludingBorder(new ClipContext(
                previous, next, ClipContext.Block.COLLIDER, ClipContext.Fluid.NONE, player));
            if (hit.getType() != HitResult.Type.MISS) {
                Vec3 location = hit.getLocation();
                this.pointsX[i] = location.x;
                this.pointsY[i] = location.y;
                this.pointsZ[i] = location.z;
                this.pointCount = i + 1;
                this.setImpactMarker(previous, location);
                return;
            }
            previous = next;
        }
    }

    private void setImpactMarker(Vec3 previous, Vec3 impact) {
        double directionX = impact.x - previous.x;
        double directionY = impact.y - previous.y;
        double directionZ = impact.z - previous.z;
        double directionLength = Math.sqrt(
            directionX * directionX + directionY * directionY + directionZ * directionZ);
        if (!(directionLength > 1.0E-6D)) {
            return;
        }
        directionX /= directionLength;
        directionY /= directionLength;
        directionZ /= directionLength;

        double referenceX = Math.abs(directionY) > 0.9D ? 1.0D : 0.0D;
        double referenceY = Math.abs(directionY) > 0.9D ? 0.0D : 1.0D;
        double axisAX = directionY * 0.0D - directionZ * referenceY;
        double axisAY = directionZ * referenceX - directionX * 0.0D;
        double axisAZ = directionX * referenceY - directionY * referenceX;
        double axisALength = Math.sqrt(axisAX * axisAX + axisAY * axisAY + axisAZ * axisAZ);
        if (!(axisALength > 1.0E-6D)) {
            return;
        }
        axisAX /= axisALength;
        axisAY /= axisALength;
        axisAZ /= axisALength;

        this.impactX = impact.x;
        this.impactY = impact.y;
        this.impactZ = impact.z;
        this.impactAxisAX = axisAX;
        this.impactAxisAY = axisAY;
        this.impactAxisAZ = axisAZ;
        this.impactAxisBX = directionY * axisAZ - directionZ * axisAY;
        this.impactAxisBY = directionZ * axisAX - directionX * axisAZ;
        this.impactAxisBZ = directionX * axisAY - directionY * axisAX;
        this.impactVisible = true;
    }

    public void setCameraPosition(Vec3 cameraPosition) {
        this.cameraX = cameraPosition.x;
        this.cameraY = cameraPosition.y;
        this.cameraZ = cameraPosition.z;
    }

    @Override
    public void render(PoseStack.Pose pose, VertexConsumer consumer) {
        if (this.theme.mode() == BowGuideTheme.Mode.RIBBON) {
            this.renderRibbon(pose, consumer);
        } else {
            this.renderLine(pose, consumer);
        }
    }

    private void renderLine(PoseStack.Pose pose, VertexConsumer consumer) {
        for (int i = 0; i < this.pointCount; i++) {
            float pathPosition = this.normalizedDistance(i);
            float pulse = this.themePulse(pathPosition);
            consumer.addVertex(pose,
                    (float) (this.pointsX[i] - this.cameraX),
                    (float) (this.pointsY[i] - this.cameraY),
                    (float) (this.pointsZ[i] - this.cameraZ))
                .setColor(
                    this.colorChannel(pathPosition, pulse, 24),
                    this.colorChannel(pathPosition, pulse, 16),
                    this.colorChannel(pathPosition, pulse, 8),
                    this.alphaChannel(pathPosition, pulse));
        }
    }

    /**
     * Emits a camera-facing textured ribbon. The trajectory and theme were
     * snapshotted once during first-pass extraction; only the per-eye camera
     * subtraction/billboard axis happens here. No collections or temporary
     * vectors are allocated in this hot path.
     */
    private void renderRibbon(PoseStack.Pose pose, VertexConsumer consumer) {
        double halfWidth = this.theme.widthMeters() * 0.5D;
        for (int i = 0; i + 1 < this.pointCount; i++) {
            double midpointDistance = (this.pathDistance[i] + this.pathDistance[i + 1]) * 0.5D;
            if (!this.isDashVisible(midpointDistance)) {
                continue;
            }

            double x0 = this.pointsX[i];
            double y0 = this.pointsY[i];
            double z0 = this.pointsZ[i];
            double x1 = this.pointsX[i + 1];
            double y1 = this.pointsY[i + 1];
            double z1 = this.pointsZ[i + 1];
            double tangentX = x1 - x0;
            double tangentY = y1 - y0;
            double tangentZ = z1 - z0;
            double midpointX = (x0 + x1) * 0.5D;
            double midpointY = (y0 + y1) * 0.5D;
            double midpointZ = (z0 + z1) * 0.5D;
            double viewX = this.cameraX - midpointX;
            double viewY = this.cameraY - midpointY;
            double viewZ = this.cameraZ - midpointZ;

            // The GUI-textured pipeline is back-face culled. Use view x
            // tangent so the quad order below produces a normal pointing at
            // the current eye, never the invisible back face.
            double sideX = viewY * tangentZ - viewZ * tangentY;
            double sideY = viewZ * tangentX - viewX * tangentZ;
            double sideZ = viewX * tangentY - viewY * tangentX;
            double sideLength = Math.sqrt(sideX * sideX + sideY * sideY + sideZ * sideZ);
            if (!(sideLength > 1.0E-8D)) {
                // Looking exactly along a segment is rare, but it must not
                // collapse the guide or produce NaNs.
                sideX = -tangentZ;
                sideY = 0.0D;
                sideZ = tangentX;
                sideLength = Math.sqrt(sideX * sideX + sideZ * sideZ);
                if (!(sideLength > 1.0E-8D)) {
                    sideX = 1.0D;
                    sideY = 0.0D;
                    sideZ = 0.0D;
                    sideLength = 1.0D;
                }
            }
            sideX = sideX / sideLength * halfWidth;
            sideY = sideY / sideLength * halfWidth;
            sideZ = sideZ / sideLength * halfWidth;

            float t0 = this.normalizedDistance(i);
            float t1 = this.normalizedDistance(i + 1);
            float pulse0 = this.themePulse(t0);
            float pulse1 = this.themePulse(t1);
            this.addRibbonVertex(pose, consumer, x0 - sideX, y0 - sideY, z0 - sideZ,
                t0, this.theme.vMax(), t0, pulse0);
            this.addRibbonVertex(pose, consumer, x1 - sideX, y1 - sideY, z1 - sideZ,
                t1, this.theme.vMax(), t1, pulse1);
            this.addRibbonVertex(pose, consumer, x1 + sideX, y1 + sideY, z1 + sideZ,
                t1, this.theme.vMin(), t1, pulse1);
            this.addRibbonVertex(pose, consumer, x0 + sideX, y0 + sideY, z0 + sideZ,
                t0, this.theme.vMin(), t0, pulse0);
        }
    }

    private void addRibbonVertex(
        PoseStack.Pose pose, VertexConsumer consumer, double x, double y, double z,
        float u, float v, float pathPosition, float pulse)
    {
        consumer.addVertex(pose,
                (float) (x - this.cameraX),
                (float) (y - this.cameraY),
                (float) (z - this.cameraZ))
            .setUv(u, v)
            .setColor(
                this.colorChannel(pathPosition, pulse, 24),
                this.colorChannel(pathPosition, pulse, 16),
                this.colorChannel(pathPosition, pulse, 8),
                this.alphaChannel(pathPosition, pulse));
    }

    private float normalizedDistance(int index) {
        return this.totalPathDistance > 1.0E-8D ?
            (float) (this.pathDistance[index] / this.totalPathDistance) : 0.0F;
    }

    private boolean isDashVisible(double distance) {
        float on = this.theme.dashOnMeters();
        float off = this.theme.dashOffMeters();
        if (!(on > 0.0F) || !(off > 0.0F)) {
            return true;
        }
        double period = on + off;
        return distance - Math.floor(distance / period) * period < on;
    }

    private float themePulse(float pathPosition) {
        int count = this.theme.pulseCount();
        float width = this.theme.pulseWidth();
        float cycles = this.theme.pulseCyclesPerSecond();
        if (count <= 0 || !(width > 0.0F) || !(cycles > 0.0F) || !(this.theme.pulseStrength() > 0.0F)) {
            return 0.0F;
        }
        float phase = fractional(this.animationSeconds * cycles);
        float strongest = 0.0F;
        for (int i = 0; i < count; i++) {
            float center = fractional(phase + i / (float) count);
            float distance = Math.abs(pathPosition - center);
            distance = Math.min(distance, 1.0F - distance);
            strongest = Math.max(strongest, Math.max(0.0F, 1.0F - distance / width));
        }
        return strongest * this.theme.pulseStrength();
    }

    private int colorChannel(float pathPosition, float pulse, int shift) {
        int start = this.theme.startColor() >>> shift & 0xFF;
        int end = this.theme.endColor() >>> shift & 0xFF;
        return energyChannel(start, end, pathPosition, pulse);
    }

    private int alphaChannel(float pathPosition, float pulse) {
        int start = this.theme.startColor() & 0xFF;
        int end = this.theme.endColor() & 0xFF;
        float base = start + (end - start) * Math.max(0.0F, Math.min(1.0F, pathPosition));
        return Math.round(Math.min(255.0F, base + (255.0F - base) * Math.max(0.0F, Math.min(1.0F, pulse))));
    }

    private static float fractional(float value) {
        return value - (float) Math.floor(value);
    }

    static float pulseStrength(float pathPosition, float pulsePosition) {
        float distance = Math.abs(pathPosition - pulsePosition);
        return Math.max(0.0F, 1.0F - distance * 9.0F);
    }

    static int energyChannel(int start, int end, float pathPosition, float pulse) {
        float clampedPath = Math.max(0.0F, Math.min(1.0F, pathPosition));
        float clampedPulse = Math.max(0.0F, Math.min(1.0F, pulse));
        float base = start + (end - start) * clampedPath;
        return Math.round(base + (255.0F - base) * clampedPulse);
    }

    private final class ImpactRenderer implements SubmitNodeCollector.CustomGeometryRenderer {
        @Override
        public void render(PoseStack.Pose pose, VertexConsumer consumer) {
            double pulse = 1.0D + theme.impactPulseAmplitude() *
                Math.sin(animationSeconds * theme.impactPulseCyclesPerSecond() * Math.PI * 2.0D);
            double size = theme.impactSizeMeters() * pulse;
            switch (theme.impactShape()) {
                case DIAMOND -> {
                    addImpactVertex(pose, consumer, impactAxisAX, impactAxisAY, impactAxisAZ, size);
                    addImpactVertex(pose, consumer, impactAxisBX, impactAxisBY, impactAxisBZ, size);
                    addImpactVertex(pose, consumer, -impactAxisAX, -impactAxisAY, -impactAxisAZ, size);
                    addImpactVertex(pose, consumer, -impactAxisBX, -impactAxisBY, -impactAxisBZ, size);
                    addImpactVertex(pose, consumer, impactAxisAX, impactAxisAY, impactAxisAZ, size);
                }
                case RING -> {
                    for (int i = 0; i <= 16; i++) {
                        double angle = i * Math.PI * 2.0D / 16.0D;
                        double axisA = Math.cos(angle);
                        double axisB = Math.sin(angle);
                        addImpactVertex(pose, consumer,
                            impactAxisAX * axisA + impactAxisBX * axisB,
                            impactAxisAY * axisA + impactAxisBY * axisB,
                            impactAxisAZ * axisA + impactAxisBZ * axisB, size);
                    }
                }
                case STAR -> {
                    for (int i = 0; i <= 10; i++) {
                        int point = i % 10;
                        double angle = point * Math.PI / 5.0D - Math.PI * 0.5D;
                        double radius = (point & 1) == 0 ? 1.0D : 0.42D;
                        double axisA = Math.cos(angle) * radius;
                        double axisB = Math.sin(angle) * radius;
                        addImpactVertex(pose, consumer,
                            impactAxisAX * axisA + impactAxisBX * axisB,
                            impactAxisAY * axisA + impactAxisBY * axisB,
                            impactAxisAZ * axisA + impactAxisBZ * axisB, size);
                    }
                }
                case NONE -> {
                }
            }
        }

        private void addImpactVertex(
            PoseStack.Pose pose, VertexConsumer consumer, double axisX, double axisY, double axisZ, double size)
        {
            int color = theme.impactColor();
            consumer.addVertex(pose,
                    (float) (impactX + axisX * size - cameraX),
                    (float) (impactY + axisY * size - cameraY),
                    (float) (impactZ + axisZ * size - cameraZ))
                .setColor(color >>> 24 & 0xFF, color >>> 16 & 0xFF, color >>> 8 & 0xFF, color & 0xFF);
        }
    }
}
