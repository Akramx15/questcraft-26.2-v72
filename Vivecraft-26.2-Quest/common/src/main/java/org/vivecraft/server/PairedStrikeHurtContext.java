package org.vivecraft.server;

import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.LivingEntity;

/**
 * Server-thread scope for one paired-strike hurt-immunity read. The target and
 * attacker must both match, and the exception is consumed at most once before
 * the enclosing {@code Player.attack} returns.
 */
public final class PairedStrikeHurtContext {
    private static final ThreadLocal<Context> LOCAL = ThreadLocal.withInitial(Context::new);

    private PairedStrikeHurtContext() {
    }

    public static boolean begin(ServerPlayer attacker, LivingEntity target, boolean bypassAllowed) {
        Context context = LOCAL.get();
        if (context.active) {
            return false;
        }
        context.active = true;
        context.attacker = attacker;
        context.target = target;
        context.bypassAllowed = bypassAllowed;
        context.bypassConsumed = false;
        context.hurtSucceeded = false;
        return true;
    }

    public static int modifyInvulnerableTime(
        LivingEntity target, DamageSource source, int originalInvulnerableTime)
    {
        Context context = LOCAL.get();
        if (context.active && context.bypassAllowed && !context.bypassConsumed &&
            context.target == target && source.getEntity() == context.attacker)
        {
            context.bypassConsumed = true;
            return 0;
        }
        return originalInvulnerableTime;
    }

    public static void recordHurtResult(LivingEntity target, DamageSource source, boolean successful) {
        Context context = LOCAL.get();
        if (context.active && context.target == target && source.getEntity() == context.attacker) {
            context.hurtSucceeded |= successful;
        }
    }

    public static boolean hurtSucceeded() {
        Context context = LOCAL.get();
        return context.active && context.hurtSucceeded;
    }

    public static void end() {
        Context context = LOCAL.get();
        context.active = false;
        context.attacker = null;
        context.target = null;
        context.bypassAllowed = false;
        context.bypassConsumed = false;
        context.hurtSucceeded = false;
    }

    private static final class Context {
        private boolean active;
        private ServerPlayer attacker;
        private LivingEntity target;
        private boolean bypassAllowed;
        private boolean bypassConsumed;
        private boolean hurtSucceeded;
    }
}
