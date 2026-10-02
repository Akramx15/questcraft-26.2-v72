package org.vivecraft.client_vr.provider.nullvr;


import net.minecraft.client.Minecraft;
import net.minecraft.client.resources.sounds.SimpleSoundInstance;
import net.minecraft.client.resources.sounds.SoundInstance;
import net.minecraft.core.particles.ParticleTypes;
import net.minecraft.sounds.SoundEvents;
import net.minecraft.sounds.SoundSource;
import net.minecraft.world.phys.Vec3;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.HapticScheduler;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.function.Consumer;

public class NullVRHapticScheduler extends HapticScheduler {

    private final List<Haptic> haptics;

    public NullVRHapticScheduler() {
        this(new ArrayList<>());
    }

    NullVRHapticScheduler(List<Haptic> haptics) {
        this.haptics = Objects.requireNonNull(haptics);
    }

    @Override
    public void queueHapticPulse(
        ControllerType controller, float durationSeconds, float frequency, float amplitude, float delaySeconds)
    {
        if (!this.isShutdown() && ClientDataHolderVR.getInstance().vrSettings.nullvrHaptics) {
            this.enqueueHaptic(new Haptic(controller.ordinal(),
                System.currentTimeMillis() + (long) (delaySeconds * 1000),
                (long) (durationSeconds * 1000), frequency, amplitude));
        }
    }

    public void tick() {
        this.drainHaptics(System.currentTimeMillis(), NullVRHapticScheduler::emitHaptic);
    }

    boolean enqueueHaptic(Haptic haptic) {
        Objects.requireNonNull(haptic);
        return this.runIfActive(() -> this.haptics.add(haptic));
    }

    boolean drainHaptics(long nowMillis, Consumer<Haptic> emitter) {
        Objects.requireNonNull(emitter);
        return this.runIfActive(() -> {
            for (Haptic haptic : this.haptics) {
                if (nowMillis > haptic.startTime) {
                    emitter.accept(haptic);
                }
            }
            this.haptics.removeIf(haptic -> nowMillis > haptic.startTime + haptic.durationMillis);
        });
    }

    @Override
    protected void onShutdown() {
        this.haptics.clear();
    }

    private static void emitHaptic(Haptic haptic) {
        Vec3 pos = ClientDataHolderVR.getInstance().vrPlayer.getVRDataWorld().getController(haptic.controller)
            .getPosition();
        float freq = Math.min(haptic.frequency / 1000F, 1.0F);
        SoundInstance sound = new SimpleSoundInstance(SoundEvents.NOTE_BLOCK_HAT.value(), SoundSource.AMBIENT,
            freq, haptic.amplitude, SoundInstance.createUnseededRandom(), pos.x, pos.y, pos.z);
        Minecraft.getInstance().getSoundManager().play(sound);
        if (Minecraft.getInstance().level != null) {
            Minecraft.getInstance().particleEngine.createParticle(ParticleTypes.NOTE, pos.x, pos.y, pos.z,
                haptic.frequency, 0, 0);
        }
    }

    public record Haptic(int controller, long startTime, long durationMillis, float frequency, float amplitude) {}
}
