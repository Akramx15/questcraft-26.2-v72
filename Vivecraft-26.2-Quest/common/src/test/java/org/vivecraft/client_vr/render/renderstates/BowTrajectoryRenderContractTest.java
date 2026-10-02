package org.vivecraft.client_vr.render.renderstates;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class BowTrajectoryRenderContractTest {
    private static String source(String relative) throws IOException {
        return Files.readString(Path.of("src/main/java").resolve(relative)).replace("\r\n", "\n");
    }

    @Test
    void usesAStartupOverrideAndReusablePrimitivePointBuffers() throws IOException {
        String state = source("org/vivecraft/client_vr/render/renderstates/BowTrajectoryRenderState.java");
        Assertions.assertTrue(state.contains("System.getProperty(ENABLE_PROPERTY, \"true\")"));
        Assertions.assertTrue(state.contains("private final double[] pointsX"));
        Assertions.assertTrue(state.contains("private final double[] pointsY"));
        Assertions.assertTrue(state.contains("private final double[] pointsZ"));
        Assertions.assertTrue(state.contains("BowTrajectoryMath.sampleAirCenterline"));
        Assertions.assertTrue(state.contains("ClientNetworking.SERVER_HAS_VIVECRAFT ?"));
        Assertions.assertTrue(state.contains("player.getEyeY() - 0.10000000149011612D"));
        Assertions.assertFalse(state.contains("new ArrayList"),
            "the trajectory snapshot must retain primitive point storage");
    }

    @Test
    void extractsOnceAndSubmitsTheSameSnapshotForEachEye() throws IOException {
        String renderState = source("org/vivecraft/client_vr/render/renderstates/VRRenderState.java");
        String armHelper = source("org/vivecraft/client_vr/render/helpers/VRArmHelper.java");
        Assertions.assertTrue(renderState.contains("if (!dataHolder.isFirstPass) return;"));
        Assertions.assertTrue(renderState.contains("this.bowTrajectoryState.extract(player, this.armsState);"));
        Assertions.assertTrue(armHelper.contains("renderOff && !menuHandOff && vrState.bowTrajectoryState.isVisible()"));
        Assertions.assertTrue(armHelper.contains("VRRenderTypes.linesStrip()"));
        Assertions.assertTrue(armHelper.contains("VRRenderTypes.bowGuideTextured("),
            "a ribbon theme must use the resource-pack texture instead of a one-pixel line");
        Assertions.assertTrue(armHelper.contains("usesTexturedRibbon()"));
        Assertions.assertTrue(armHelper.contains("vrState.bowTrajectoryState"));
        Assertions.assertTrue(armHelper.contains("hasImpactMarker()"));
        Assertions.assertTrue(armHelper.contains("impactRenderer()"));
    }

    @Test
    void solidPreviewStopsAtTheFirstWorldCollider() throws IOException {
        String source = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/render/renderstates/BowTrajectoryRenderState.java"));
        Assertions.assertTrue(source.contains("truncateAtFirstBlock(player)"));
        Assertions.assertTrue(source.contains("clipIncludingBorder(new ClipContext("));
        Assertions.assertTrue(source.contains("ClipContext.Block.COLLIDER"));
        Assertions.assertTrue(source.contains("ClipContext.Fluid.NONE"));
        Assertions.assertTrue(source.contains("this.pointCount = i + 1"));
        Assertions.assertTrue(source.contains("this.setImpactMarker(previous, location)"));
    }

    @Test
    void exposesOffClassicAndEnergyStylesWithoutAllocatingFrameCollections() throws IOException {
        String settings = source("org/vivecraft/client_vr/settings/VRSettings.java");
        String state = source("org/vivecraft/client_vr/render/renderstates/BowTrajectoryRenderState.java");
        String themes = source("org/vivecraft/client_vr/render/renderstates/BowGuideThemes.java");
        Assertions.assertTrue(settings.contains("enum BowGuideStyle"));
        Assertions.assertTrue(settings.contains("OFF,\n        CLASSIC,\n        ENERGY"));
        Assertions.assertTrue(settings.contains("bowGuideStyle = BowGuideStyle.ENERGY"));
        Assertions.assertTrue(state.contains("BowGuideThemes.classic()"));
        Assertions.assertTrue(state.contains("BowGuideThemes.energy()"));
        Assertions.assertTrue(state.contains("this.renderRibbon(pose, consumer)"));
        Assertions.assertTrue(state.contains("private final double[] pathDistance"));
        Assertions.assertTrue(state.contains("viewY * tangentZ - viewZ * tangentY"),
            "ribbon winding must face the current eye through view x tangent");
        Assertions.assertTrue(themes.contains("volatile ThemeSet active"));
        Assertions.assertTrue(themes.contains("MAX_JSON_BYTES = 64 * 1024"));
        String shaders = source("org/vivecraft/client_vr/render/VRShaders.java");
        Assertions.assertTrue(shaders.contains("BOW_GUIDE_TEXTURED"));
        Assertions.assertTrue(shaders.contains("CompareOp.GREATER_THAN_OR_EQUAL, false"),
            "transparent ribbon texels must never write a solid quad into world depth");
        Assertions.assertTrue(shaders.contains(".withCull(false)"),
            "curved ribbon segments must be visible in both eyes");
        Assertions.assertFalse(state.contains("new ArrayList"));
        Assertions.assertFalse(state.contains("new Vector3"),
            "the ribbon hot loop must stay scalar/allocation-free");
    }
}
