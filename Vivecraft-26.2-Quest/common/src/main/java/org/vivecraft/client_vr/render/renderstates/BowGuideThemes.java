package org.vivecraft.client_vr.render.renderstates;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.server.packs.resources.ResourceManager;
import org.vivecraft.client_vr.settings.VRSettings;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Objects;
import java.util.Optional;

/**
 * Reload-time resource-pack loader for the two bow-guide styles.
 *
 * <p>{@link ResourceManager#getResource(Identifier)} selects the highest
 * priority pack. A missing, oversized or invalid override falls back to a
 * known-good built-in value. Reload publishes both immutable themes with one
 * volatile write, so render-time reads need no locks or JSON work.</p>
 */
public final class BowGuideThemes {
    static final int SCHEMA = 1;
    static final int MAX_JSON_BYTES = 64 * 1024;

    static final Identifier CLASSIC_RESOURCE =
        Identifier.fromNamespaceAndPath("vivecraft", "bow_guide_styles/classic.json");
    static final Identifier ENERGY_RESOURCE =
        Identifier.fromNamespaceAndPath("vivecraft", "bow_guide_styles/energy.json");
    private static final Identifier DEFAULT_TEXTURE =
        Identifier.fromNamespaceAndPath("vivecraft", "textures/misc/bow_guide_atlas.png");

    private static final BowGuideTheme DEFAULT_CLASSIC = new BowGuideTheme(
        BowGuideTheme.Mode.LINE,
        DEFAULT_TEXTURE,
        0.0F,
        0.25F,
        0.012F,
        0x40FFA0DC,
        0x40FFA0DC,
        0.0F,
        0.0F,
        0,
        0.0F,
        0.12F,
        0.0F,
        BowGuideTheme.ImpactShape.NONE,
        0.045F,
        0x60EEFFE6,
        0.0F,
        0.0F);

    private static final BowGuideTheme DEFAULT_ENERGY = new BowGuideTheme(
        BowGuideTheme.Mode.RIBBON,
        DEFAULT_TEXTURE,
        0.001F,
        0.249F,
        0.075F,
        0xFFE0B8F2,
        0xB8F4FFF2,
        0.0F,
        0.0F,
        2,
        1.10F,
        0.12F,
        0.90F,
        BowGuideTheme.ImpactShape.DIAMOND,
        0.060F,
        0x60EEFFF0,
        1.10F,
        0.18F);

    private static volatile ThemeSet active = new ThemeSet(DEFAULT_CLASSIC, DEFAULT_ENERGY);

    private BowGuideThemes() {
    }

    public static BowGuideTheme classic() {
        return active.classic();
    }

    public static BowGuideTheme energy() {
        return active.energy();
    }

    /**
     * Loads the highest-priority resource for each style and atomically
     * publishes a complete pair. Invalid pack data never escapes this method.
     */
    public static void reload(ResourceManager resourceManager) {
        Objects.requireNonNull(resourceManager, "resourceManager");
        BowGuideTheme classic = load(resourceManager, CLASSIC_RESOURCE, DEFAULT_CLASSIC);
        BowGuideTheme energy = load(resourceManager, ENERGY_RESOURCE, DEFAULT_ENERGY);
        active = new ThemeSet(classic, energy);
    }

    static BowGuideTheme load(
        ResourceManager resourceManager, Identifier resourceId, BowGuideTheme fallback)
    {
        Optional<Resource> resource = resourceManager.getResource(resourceId);
        if (resource.isEmpty()) {
            VRSettings.LOGGER.warn("Vivecraft: bow guide theme '{}' is missing; using built-in defaults", resourceId);
            return fallback;
        }

        try (InputStream stream = resource.get().open()) {
            BowGuideTheme parsed = parse(readBounded(stream), fallback);
            if (parsed.mode() == BowGuideTheme.Mode.RIBBON &&
                resourceManager.getResource(parsed.texture()).isEmpty())
            {
                throw new IllegalArgumentException("ribbon texture is missing: " + parsed.texture());
            }
            return parsed;
        } catch (IOException | RuntimeException exception) {
            VRSettings.LOGGER.warn(
                "Vivecraft: bow guide theme '{}' is invalid; using built-in defaults ({})",
                resourceId, exception.getMessage());
            return fallback;
        }
    }

    static BowGuideTheme parse(byte[] json, BowGuideTheme fallback) {
        Objects.requireNonNull(json, "json");
        Objects.requireNonNull(fallback, "fallback");
        if (json.length > MAX_JSON_BYTES) {
            throw new IllegalArgumentException("theme exceeds 64 KiB");
        }

        JsonElement root = JsonParser.parseString(new String(json, StandardCharsets.UTF_8));
        if (!root.isJsonObject()) {
            throw new IllegalArgumentException("theme root must be an object");
        }
        JsonObject object = root.getAsJsonObject();
        JsonElement schema = object.get("schema");
        if (schema == null || !schema.isJsonPrimitive() || !schema.getAsJsonPrimitive().isNumber() ||
            schema.getAsInt() != SCHEMA || schema.getAsDouble() != SCHEMA)
        {
            throw new IllegalArgumentException("unsupported or missing schema");
        }

        BowGuideTheme.Mode mode = enumValue(object, "mode", BowGuideTheme.Mode.class, fallback.mode());
        Identifier texture = identifierValue(object, "texture", fallback.texture());
        float vMin = floatValue(object, "vMin", fallback.vMin(), 0.0F, 1.0F);
        float vMax = floatValue(object, "vMax", fallback.vMax(), 0.0F, 1.0F);
        if (!(vMax > vMin)) {
            throw new IllegalArgumentException("vMax must be greater than vMin");
        }
        float widthMeters = floatValue(object, "widthMeters", fallback.widthMeters(), 0.001F, 0.25F);
        int startColor = colorValue(object, "startColor", fallback.startColor());
        int endColor = colorValue(object, "endColor", fallback.endColor());
        float dashOnMeters = floatValue(object, "dashOnMeters", fallback.dashOnMeters(), 0.0F, 10.0F);
        float dashOffMeters = floatValue(object, "dashOffMeters", fallback.dashOffMeters(), 0.0F, 10.0F);
        if (dashOnMeters == 0.0F && dashOffMeters > 0.0F) {
            throw new IllegalArgumentException("dashOnMeters must be positive when dashOffMeters is positive");
        }
        int pulseCount = intValue(object, "pulseCount", fallback.pulseCount(), 0, 16);
        float pulseCyclesPerSecond = floatValue(
            object, "pulseCyclesPerSecond", fallback.pulseCyclesPerSecond(), 0.0F, 20.0F);
        float pulseWidth = floatValue(object, "pulseWidth", fallback.pulseWidth(), 0.001F, 1.0F);
        float pulseStrength = floatValue(object, "pulseStrength", fallback.pulseStrength(), 0.0F, 2.0F);
        BowGuideTheme.ImpactShape impactShape = enumValue(
            object, "impactShape", BowGuideTheme.ImpactShape.class, fallback.impactShape());
        float impactSizeMeters = floatValue(
            object, "impactSizeMeters", fallback.impactSizeMeters(), 0.0F, 0.5F);
        if (impactShape != BowGuideTheme.ImpactShape.NONE && !(impactSizeMeters > 0.0F)) {
            throw new IllegalArgumentException("impactSizeMeters must be positive for a visible impact shape");
        }
        int impactColor = colorValue(object, "impactColor", fallback.impactColor());
        float impactPulseCyclesPerSecond = floatValue(
            object, "impactPulseCyclesPerSecond", fallback.impactPulseCyclesPerSecond(), 0.0F, 20.0F);
        float impactPulseAmplitude = floatValue(
            object, "impactPulseAmplitude", fallback.impactPulseAmplitude(), 0.0F, 1.0F);

        return new BowGuideTheme(
            mode, texture, vMin, vMax, widthMeters, startColor, endColor,
            dashOnMeters, dashOffMeters, pulseCount, pulseCyclesPerSecond,
            pulseWidth, pulseStrength, impactShape, impactSizeMeters,
            impactColor, impactPulseCyclesPerSecond, impactPulseAmplitude);
    }

    private static byte[] readBounded(InputStream stream) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(4096);
        byte[] buffer = new byte[4096];
        int total = 0;
        int read;
        while ((read = stream.read(buffer)) != -1) {
            total += read;
            if (total > MAX_JSON_BYTES) {
                throw new IOException("theme exceeds 64 KiB");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    private static Identifier identifierValue(JsonObject object, String name, Identifier fallback) {
        JsonElement value = object.get(name);
        if (value == null) {
            return fallback;
        }
        if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isString()) {
            throw new IllegalArgumentException(name + " must be a resource identifier string");
        }
        String text = value.getAsString();
        if (text.isBlank()) {
            throw new IllegalArgumentException(name + " must not be blank");
        }
        return Identifier.parse(text);
    }

    private static float floatValue(
        JsonObject object, String name, float fallback, float minimum, float maximum)
    {
        JsonElement value = object.get(name);
        if (value == null) {
            return fallback;
        }
        if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isNumber()) {
            throw new IllegalArgumentException(name + " must be a number");
        }
        float number = value.getAsFloat();
        if (!Float.isFinite(number) || number < minimum || number > maximum) {
            throw new IllegalArgumentException(name + " is outside the supported range");
        }
        return number;
    }

    private static int intValue(JsonObject object, String name, int fallback, int minimum, int maximum) {
        JsonElement value = object.get(name);
        if (value == null) {
            return fallback;
        }
        if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isNumber()) {
            throw new IllegalArgumentException(name + " must be an integer");
        }
        double raw = value.getAsDouble();
        int number = value.getAsInt();
        if (!Double.isFinite(raw) || raw != number || number < minimum || number > maximum) {
            throw new IllegalArgumentException(name + " is outside the supported integer range");
        }
        return number;
    }

    private static int colorValue(JsonObject object, String name, int fallback) {
        JsonElement value = object.get(name);
        if (value == null) {
            return fallback;
        }
        if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isString()) {
            throw new IllegalArgumentException(name + " must use #RRGGBB or #RRGGBBAA");
        }
        String text = value.getAsString();
        if (!text.startsWith("#") || (text.length() != 7 && text.length() != 9)) {
            throw new IllegalArgumentException(name + " must use #RRGGBB or #RRGGBBAA");
        }
        try {
            long rgbOrRgba = Long.parseUnsignedLong(text.substring(1), 16);
            return text.length() == 7 ? (int) (rgbOrRgba << 8 | 0xFFL) : (int) rgbOrRgba;
        } catch (NumberFormatException exception) {
            throw new IllegalArgumentException(name + " contains invalid hexadecimal digits", exception);
        }
    }

    private static <E extends Enum<E>> E enumValue(
        JsonObject object, String name, Class<E> type, E fallback)
    {
        JsonElement value = object.get(name);
        if (value == null) {
            return fallback;
        }
        if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isString()) {
            throw new IllegalArgumentException(name + " must be a string");
        }
        try {
            return Enum.valueOf(type, value.getAsString().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException exception) {
            throw new IllegalArgumentException(name + " has an unsupported value", exception);
        }
    }

    private record ThemeSet(BowGuideTheme classic, BowGuideTheme energy) {
    }
}
