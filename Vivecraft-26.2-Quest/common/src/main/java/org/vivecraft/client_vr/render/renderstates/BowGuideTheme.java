package org.vivecraft.client_vr.render.renderstates;

import net.minecraft.resources.Identifier;

import java.util.Objects;

/**
 * Immutable, reload-time description of a bow guide.
 *
 * <p>Colors use {@code 0xRRGGBBAA}. Geometry and animation values are
 * validated by {@link BowGuideThemes} before a theme reaches the renderer.</p>
 */
public record BowGuideTheme(
    Mode mode,
    Identifier texture,
    float vMin,
    float vMax,
    float widthMeters,
    int startColor,
    int endColor,
    float dashOnMeters,
    float dashOffMeters,
    int pulseCount,
    float pulseCyclesPerSecond,
    float pulseWidth,
    float pulseStrength,
    ImpactShape impactShape,
    float impactSizeMeters,
    int impactColor,
    float impactPulseCyclesPerSecond,
    float impactPulseAmplitude)
{
    public BowGuideTheme {
        Objects.requireNonNull(mode, "mode");
        Objects.requireNonNull(texture, "texture");
        Objects.requireNonNull(impactShape, "impactShape");
    }

    public enum Mode {
        LINE,
        RIBBON
    }

    public enum ImpactShape {
        NONE,
        DIAMOND,
        RING,
        STAR
    }
}
