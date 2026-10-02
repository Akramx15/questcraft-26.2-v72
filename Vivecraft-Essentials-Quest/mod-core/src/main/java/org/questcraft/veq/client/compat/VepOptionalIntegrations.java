package org.questcraft.veq.client.compat;

import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import org.questcraft.veq.client.config.VepFeatureConfig;

import java.util.Arrays;
import java.util.EnumMap;
import java.util.Locale;
import java.util.Map;

/**
 * Soft, key-mapping based discovery for optional Xaero, JEI and IPN features.
 * No optional-mod classes are linked, so their absence can never prevent VEQ
 * from loading.
 */
public final class VepOptionalIntegrations {
    private VepOptionalIntegrations() {
    }

    public static Map<Integration, Availability> detect() {
        EnumMap<Integration, Availability> result = new EnumMap<>(Integration.class);
        for (Integration integration : Integration.values()) {
            result.put(integration, find(integration));
        }
        return Map.copyOf(result);
    }

    public static Availability find(Integration integration) {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.options == null || !isEnabled(integration)) {
            return Availability.unavailable();
        }
        KeyMapping mapping = integration.findMapping(minecraft.options.keyMappings);
        return mapping == null
                ? Availability.unavailable()
                : new Availability(true, mapping.getName());
    }

    static boolean isEnabled(Integration integration) {
        VepFeatureConfig config = VepFeatureConfig.getInstance();
        return switch (integration) {
            case XAERO_MINIMAP, XAERO_WORLD_MAP -> config.xaeroIntegration();
            case JEI -> config.jeiIntegration();
            case INVENTORY_PROFILES_NEXT -> config.inventoryProfilesIntegration();
        };
    }

    public enum Integration {
        XAERO_MINIMAP(
                new String[]{"gui.xaero_toggle_map", "gui.xaero_minimap_settings"},
                "xaero", "minimap"),
        XAERO_WORLD_MAP(
                new String[]{"key.xaero_open_map", "gui.xaero_world_map", "gui.xaero_enlarge_map"},
                "xaero", "world", "map"),
        JEI(new String[0], "jei"),
        INVENTORY_PROFILES_NEXT(new String[0], "inventory", "profiles");

        private final String[] knownNames;
        private final String[] tokens;

        Integration(String[] knownNames, String... tokens) {
            this.knownNames = knownNames;
            this.tokens = tokens;
        }

        boolean matches(String mappingName) {
            String normalized = mappingName == null
                    ? ""
                    : mappingName.toLowerCase(Locale.ROOT);
            for (String knownName : knownNames) {
                if (normalized.equals(knownName)) {
                    return true;
                }
            }
            for (String token : tokens) {
                if (!normalized.contains(token)) {
                    return false;
                }
            }
            return true;
        }

        private KeyMapping findMapping(KeyMapping[] mappings) {
            // Prefer the concrete IDs shipped by Xaero over fuzzy aliases.
            // Key-mapping array order is not an API and can vary by loader.
            for (String knownName : knownNames) {
                KeyMapping exact = Arrays.stream(mappings)
                        .filter(candidate -> knownName.equalsIgnoreCase(candidate.getName()))
                        .findFirst()
                        .orElse(null);
                if (exact != null) {
                    return exact;
                }
            }
            return Arrays.stream(mappings)
                    .filter(candidate -> matches(candidate.getName()))
                    .findFirst()
                    .orElse(null);
        }
    }

    public record Availability(boolean available, String keyMappingName) {
        public static Availability unavailable() {
            return new Availability(false, "");
        }
    }
}
