package org.vivecraft.common.network.packet.s2c;

import net.minecraft.network.FriendlyByteBuf;
import org.vivecraft.common.network.packet.PayloadIdentifier;

/**
 * Negotiated server policy for the paired-strike follow-up window.
 *
 * @param enabled       whether the server allows paired strikes
 * @param windowTicks   maximum ticks between the two successful attacks
 * @param minimumCharge minimum independent attack-strength charge required for each strike
 * @param pvpAllowed    whether player targets may receive the scoped exception
 */
public record PairedStrikePayloadS2C(
    boolean enabled,
    int windowTicks,
    float minimumCharge,
    boolean pvpAllowed) implements VivecraftPayloadS2C
{
    @Override
    public PayloadIdentifier payloadId() {
        return PayloadIdentifier.PAIRED_STRIKE;
    }

    @Override
    public void write(FriendlyByteBuf buffer) {
        buffer.writeByte(payloadId().ordinal());
        buffer.writeBoolean(this.enabled);
        buffer.writeVarInt(this.windowTicks);
        buffer.writeFloat(this.minimumCharge);
        buffer.writeBoolean(this.pvpAllowed);
    }

    public static PairedStrikePayloadS2C read(FriendlyByteBuf buffer) {
        return new PairedStrikePayloadS2C(
            buffer.readBoolean(),
            buffer.readVarInt(),
            buffer.readFloat(),
            buffer.readBoolean());
    }
}
