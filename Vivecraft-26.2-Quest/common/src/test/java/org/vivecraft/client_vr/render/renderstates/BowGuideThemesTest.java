package org.vivecraft.client_vr.render.renderstates;

import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.PackResources;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.server.packs.resources.ResourceManager;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Predicate;
import java.util.stream.Stream;

class BowGuideThemesTest {
    private static byte[] json(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }

    @Test
    void parsesAllSchemaOneFieldsAndStoresRgbaColors() {
        BowGuideTheme fallback = BowGuideThemes.energy();
        BowGuideTheme theme = BowGuideThemes.parse(json("""
            {
              "schema": 1,
              "mode": "line",
              "texture": "test:guide.png",
              "vMin": 0.25,
              "vMax": 0.75,
              "widthMeters": 0.02,
              "startColor": "#123456",
              "endColor": "#89ABCDE0",
              "dashOnMeters": 0.3,
              "dashOffMeters": 0.1,
              "pulseCount": 3,
              "pulseCyclesPerSecond": 2.5,
              "pulseWidth": 0.2,
              "pulseStrength": 1.25,
              "impactShape": "star",
              "impactSizeMeters": 0.08,
              "impactColor": "#10203040",
              "impactPulseCyclesPerSecond": 4.0,
              "impactPulseAmplitude": 0.5
            }
            """), fallback);

        Assertions.assertEquals(BowGuideTheme.Mode.LINE, theme.mode());
        Assertions.assertEquals(Identifier.parse("test:guide.png"), theme.texture());
        Assertions.assertEquals(0.25F, theme.vMin());
        Assertions.assertEquals(0.75F, theme.vMax());
        Assertions.assertEquals(0.02F, theme.widthMeters());
        Assertions.assertEquals(0x123456FF, theme.startColor());
        Assertions.assertEquals(0x89ABCDE0, theme.endColor());
        Assertions.assertEquals(0.3F, theme.dashOnMeters());
        Assertions.assertEquals(0.1F, theme.dashOffMeters());
        Assertions.assertEquals(3, theme.pulseCount());
        Assertions.assertEquals(2.5F, theme.pulseCyclesPerSecond());
        Assertions.assertEquals(0.2F, theme.pulseWidth());
        Assertions.assertEquals(1.25F, theme.pulseStrength());
        Assertions.assertEquals(BowGuideTheme.ImpactShape.STAR, theme.impactShape());
        Assertions.assertEquals(0.08F, theme.impactSizeMeters());
        Assertions.assertEquals(0x10203040, theme.impactColor());
        Assertions.assertEquals(4.0F, theme.impactPulseCyclesPerSecond());
        Assertions.assertEquals(0.5F, theme.impactPulseAmplitude());
    }

    @Test
    void sparseThemeOverridesOnlyNamedFields() {
        BowGuideTheme fallback = BowGuideThemes.energy();
        BowGuideTheme theme = BowGuideThemes.parse(json("""
            {"schema":1,"widthMeters":0.045,"impactShape":"ring"}
            """), fallback);

        Assertions.assertEquals(0.045F, theme.widthMeters());
        Assertions.assertEquals(BowGuideTheme.ImpactShape.RING, theme.impactShape());
        Assertions.assertEquals(fallback.texture(), theme.texture());
        Assertions.assertEquals(fallback.startColor(), theme.startColor());
        Assertions.assertEquals(fallback.pulseCount(), theme.pulseCount());
    }

    @Test
    void rejectsUnknownSchemaMalformedValuesAndOversizedDocuments() {
        BowGuideTheme fallback = BowGuideThemes.energy();
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> BowGuideThemes.parse(json("{\"schema\":2}"), fallback));
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> BowGuideThemes.parse(json("{\"schema\":1,\"vMin\":0.9,\"vMax\":0.2}"), fallback));
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> BowGuideThemes.parse(json("{\"schema\":1,\"startColor\":\"pink\"}"), fallback));
        Assertions.assertThrows(IllegalArgumentException.class,
            () -> BowGuideThemes.parse(new byte[BowGuideThemes.MAX_JSON_BYTES + 1], fallback));
    }

    @Test
    void bundledResourcesExactlyReproduceKnownGoodFallbacks() throws IOException {
        Path root = Path.of("src/main/resources/assets/vivecraft/bow_guide_styles");
        BowGuideTheme classic = BowGuideThemes.classic();
        BowGuideTheme energy = BowGuideThemes.energy();

        Assertions.assertEquals(classic,
            BowGuideThemes.parse(Files.readAllBytes(root.resolve("classic.json")), classic));
        Assertions.assertEquals(energy,
            BowGuideThemes.parse(Files.readAllBytes(root.resolve("energy.json")), energy));
        Assertions.assertTrue(Files.size(root.resolve("classic.json")) <= BowGuideThemes.MAX_JSON_BYTES);
        Assertions.assertTrue(Files.size(root.resolve("energy.json")) <= BowGuideThemes.MAX_JSON_BYTES);
    }

    @Test
    void highestResourceIsReadOnceAndInvalidOrMissingDataFallsBack() {
        BowGuideTheme fallback = BowGuideThemes.energy();
        AtomicInteger opens = new AtomicInteger();
        ResourceManager validManager = resourceManager(json("""
            {"schema":1,"widthMeters":0.05,"impactShape":"ring"}
            """), opens);
        BowGuideTheme loaded = BowGuideThemes.load(
            validManager, BowGuideThemes.ENERGY_RESOURCE, fallback);
        Assertions.assertEquals(0.05F, loaded.widthMeters());
        Assertions.assertEquals(BowGuideTheme.ImpactShape.RING, loaded.impactShape());
        Assertions.assertEquals(1, opens.get(), "the selected highest-priority resource is opened once");

        Assertions.assertSame(fallback, BowGuideThemes.load(
            resourceManager(json("{\"schema\":99}"), new AtomicInteger()),
            BowGuideThemes.ENERGY_RESOURCE, fallback));
        Assertions.assertSame(fallback, BowGuideThemes.load(
            resourceManager(null, new AtomicInteger()), BowGuideThemes.ENERGY_RESOURCE, fallback));
        Assertions.assertSame(fallback, BowGuideThemes.load(
            resourceManager(new byte[BowGuideThemes.MAX_JSON_BYTES + 1], new AtomicInteger()),
            BowGuideThemes.ENERGY_RESOURCE, fallback));
    }

    @Test
    void exposedThemeSnapshotsAreImmutableRecordsAndLockFreeReferences() {
        BowGuideTheme first = BowGuideThemes.energy();
        BowGuideTheme second = BowGuideThemes.energy();
        Assertions.assertSame(first, second);
        Assertions.assertTrue(BowGuideTheme.class.isRecord());
        Assertions.assertEquals(0xFFE0B8F2, first.startColor());
        Assertions.assertEquals(0xB8F4FFF2, first.endColor());
    }

    @Test
    void exampleResourcePacksAllCompileToDistinctSafeRibbonThemes() throws IOException {
        Path examples = Path.of("..", "examples", "resourcepacks");
        String[] names = {"bow-guide-arcane", "bow-guide-frost", "bow-guide-emerald"};
        float previousBand = -1.0F;
        for (String name : names) {
            Path style = examples.resolve(name)
                .resolve("assets/vivecraft/bow_guide_styles/energy.json");
            BowGuideTheme parsed = BowGuideThemes.parse(Files.readAllBytes(style), BowGuideThemes.energy());
            Assertions.assertEquals(BowGuideTheme.Mode.RIBBON, parsed.mode());
            Assertions.assertTrue(parsed.widthMeters() >= 0.06F);
            Assertions.assertTrue(parsed.vMin() > previousBand,
                "each sample pack must select its own atlas band");
            previousBand = parsed.vMin();
        }
    }

    private static ResourceManager resourceManager(byte[] content, AtomicInteger opens) {
        Resource resource = content == null ? null : new Resource(packResources(), () -> {
            opens.incrementAndGet();
            return new ByteArrayInputStream(content);
        });
        return new ResourceManager() {
            @Override
            public Optional<Resource> getResource(Identifier identifier) {
                return Optional.ofNullable(resource);
            }

            @Override
            public Set<String> getNamespaces() {
                return Set.of("vivecraft");
            }

            @Override
            public List<Resource> getResourceStack(Identifier identifier) {
                throw new AssertionError("loader must use the ResourceManager highest-resource API");
            }

            @Override
            public Map<Identifier, Resource> listResources(
                String path, Predicate<Identifier> predicate)
            {
                return Map.of();
            }

            @Override
            public Map<Identifier, List<Resource>> listResourceStacks(
                String path, Predicate<Identifier> predicate)
            {
                return Map.of();
            }

            @Override
            public Stream<PackResources> listPacks() {
                return Stream.empty();
            }
        };
    }

    private static PackResources packResources() {
        return (PackResources) Proxy.newProxyInstance(
            PackResources.class.getClassLoader(),
            new Class<?>[]{PackResources.class},
            (proxy, method, args) -> switch (method.getName()) {
                case "packId" -> "bow-theme-test";
                case "close" -> null;
                case "toString" -> "BowThemeTestPack";
                default -> throw new UnsupportedOperationException(method.getName());
            });
    }
}
