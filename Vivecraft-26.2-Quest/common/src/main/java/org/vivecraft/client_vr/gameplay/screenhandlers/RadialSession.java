package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.vivecraft.client_vr.provider.ControllerType;

import java.util.Objects;

/**
 * Immutable identity for one radial-menu hold. The controller that opened the
 * surface is the only controller allowed to select or close it by release.
 */
public record RadialSession(ControllerType opener, long openedAtMillis) {
    public RadialSession {
        Objects.requireNonNull(opener, "opener");
    }

    public boolean owns(ControllerType controller) {
        return this.opener == controller;
    }
}
