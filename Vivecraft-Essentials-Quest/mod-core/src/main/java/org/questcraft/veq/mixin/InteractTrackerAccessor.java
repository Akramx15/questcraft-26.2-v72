package org.questcraft.veq.mixin;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
import org.vivecraft.api.client.InteractModule;
import org.vivecraft.client_vr.gameplay.trackers.InteractTracker;

@Mixin(InteractTracker.class)
public interface InteractTrackerAccessor {
    @Accessor("activeModules")
    InteractModule[] veq$getActiveModules();
}
