package org.vivecraft.common.network;

import io.netty.buffer.Unpooled;
import net.minecraft.network.FriendlyByteBuf;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.common.network.packet.s2c.PairedStrikePayloadS2C;
import org.vivecraft.common.network.packet.s2c.VivecraftPayloadS2C;

class PairedStrikePayloadTest {
    @Test
    void roundTripsNegotiatedPolicyThroughSharedS2cCodec() {
        FriendlyByteBuf buffer = new FriendlyByteBuf(Unpooled.buffer());
        try {
            PairedStrikePayloadS2C expected = new PairedStrikePayloadS2C(true, 4, 0.9F, false);
            expected.write(buffer);

            VivecraftPayloadS2C decoded = VivecraftPayloadS2C.readPacket(buffer);
            Assertions.assertTrue(decoded instanceof PairedStrikePayloadS2C);
            Assertions.assertEquals(expected, decoded);
            Assertions.assertEquals(0, buffer.readableBytes());
        } finally {
            buffer.release();
        }
    }
}
