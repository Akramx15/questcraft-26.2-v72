package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.provider.ControllerType;

class RadialSessionTest {
    @Test
    void openerIsImmutableAndOtherHandCannotOwnRelease() {
        RadialSession session = new RadialSession(ControllerType.LEFT, 42L);
        Assertions.assertSame(ControllerType.LEFT, session.opener());
        Assertions.assertTrue(session.owns(ControllerType.LEFT));
        Assertions.assertFalse(session.owns(ControllerType.RIGHT));
        Assertions.assertFalse(session.owns(null));
    }

    @Test
    void nullOriginFailsClosed() {
        Assertions.assertThrows(NullPointerException.class, () -> new RadialSession(null, 42L));
    }
}
