package org.questcraft.veq.mixin;

import net.minecraft.client.gui.Hud;
import net.minecraft.resources.Identifier;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Accesses the vanilla GUI-atlas crosshair identifier without duplicating it. */
@Mixin(Hud.class)
public interface HudAccessor {
    @Accessor("CROSSHAIR_SPRITE")
    static Identifier veq$getCrosshairSprite() {
        throw new AssertionError("Mixin accessor was not transformed");
    }
}
