package org.vivecraft.client_vr.render.helpers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class ExternalOverlayRenderOrderingContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void externalSurfacesKeepTheOrdinaryGuiOrdering() throws IOException {
        String method = method(source("org/vivecraft/client_vr/render/helpers/VREffectsHelper.java"),
            "private static int renderGuiAndShadow(",
            "private static int renderExternalScreenOverlays(");

        Assertions.assertTrue(method.contains("renderGuiLayer("));
        Assertions.assertTrue(method.contains("vrState.keyboardType"));
        Assertions.assertTrue(method.contains("vrState.radialShowing"));
        Assertions.assertTrue(method.contains(
            "renderExternalScreenOverlays(output, cameraState, vrState, poseStack, depthAlways, order,"),
            "external surfaces must retain their established GUI composition point");
    }

    @Test
    void externalRendererResolvesDepthPerSurface() throws IOException {
        String method = method(source("org/vivecraft/client_vr/render/helpers/VREffectsHelper.java"),
            "private static int renderExternalScreenOverlays(",
            "public static int renderVrShadow(");

        Assertions.assertTrue(method.contains("handle.surface().worldOcclusion()"));
        Assertions.assertTrue(method.contains("shouldRenderInPass("));
        Assertions.assertTrue(method.contains("compositionPass"));
        Assertions.assertTrue(method.contains("ordinaryDepthAlways"));
        Assertions.assertTrue(method.contains("renderScreen("));
        Assertions.assertTrue(method.contains("depthAlways"));
    }

    @Test
    void fabulousRoutesOptedInSurfacesAfterSwitchingToUnoccludedTarget() throws IOException {
        String fabulous = method(source("org/vivecraft/client_vr/render/helpers/VREffectsHelper.java"),
            "public static void renderVRFabulous(",
            "public static void renderVrFast(");

        int unoccludedTarget = fabulous.indexOf(
            "VRRenderTypes.VR_OUTPUT_TARGET = VRRenderTypes.UNOCCLUDED_TARGET;");
        int optedInPass = fabulous.indexOf(
            "ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_UNOCCLUDED", unoccludedTarget);
        int selfEffects = fabulous.indexOf("renderVRSelfEffects(", unoccludedTarget);
        Assertions.assertTrue(unoccludedTarget >= 0 && optedInPass > unoccludedTarget,
            "always-visible surfaces must be submitted only after selecting VrUnoccluded");
        Assertions.assertTrue(selfEffects > optedInPass,
            "the split overlay pass must preserve its established order ahead of self effects");
        Assertions.assertTrue(fabulous.contains(
            "ExternalOverlayRenderPolicy.CompositionPass.FABULOUS_OCCLUDED"));
    }

    @Test
    void nonFabulousWorldPathsDoNotAddANewPostHandExternalPass() throws IOException {
        String source = source("org/vivecraft/client_vr/render/helpers/VREffectsHelper.java");

        Assertions.assertFalse(method(source, "public static void renderVrFast(",
            "public static boolean shouldOccludeGui(").contains("renderExternalScreenOverlays("));
        Assertions.assertFalse(method(source, "public static void renderFaceOverlay(",
            "public static int renderFaceInBlock(").contains("renderExternalScreenOverlays("));
    }

    @Test
    void handsSecondRetainsExternalAndOrdinaryUiSemantics() throws IOException {
        String arms = source("org/vivecraft/client_vr/render/renderstates/ArmsRenderState.java");
        Assertions.assertTrue(arms.contains(
            "RadialHandler.isShowing() || KeyboardHandler.SHOWING ||"));
        Assertions.assertTrue(arms.contains(
            "ExternalScreenOverlayHandler.isShowing() || mc.gui.screen() != null"));
        Assertions.assertTrue(arms.contains("this.mainHandRenderItem = ItemStack.EMPTY;"));
        Assertions.assertTrue(arms.contains("this.offHandRenderItem = ItemStack.EMPTY;"));

        String registry = source(
            "org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java");
        Assertions.assertTrue(registry.contains(
            "handle.isVisible() && handle.surface.shouldHideHeldItem(controller, stack)"),
            "held-item suppression must exist only while the requesting surface is visible");
    }

    @Test
    void heldItemSuppressionChangesOnlyTheExtractedRenderSnapshots() throws IOException {
        String extract = method(source(
                "org/vivecraft/client_vr/render/renderstates/ArmsRenderState.java"),
            "public void extract(",
            "\n    }");
        String mainSuppression = bracedBlock(extract,
            "if (ExternalScreenOverlayHandler.shouldHideHeldItem(\n" +
                "            ControllerType.RIGHT, this.mainHandRenderItem))");
        String offhandSuppression = bracedBlock(extract,
            "if (ExternalScreenOverlayHandler.shouldHideHeldItem(\n" +
                "            ControllerType.LEFT, this.offHandRenderItem))");

        Assertions.assertTrue(extract.contains(
            "this.mainHandRenderItem = VRArmHelper.extractHandRenderItem(player, InteractionHand.MAIN_HAND);"));
        Assertions.assertTrue(extract.contains(
            "this.offHandRenderItem = VRArmHelper.extractHandRenderItem(player, InteractionHand.OFF_HAND);"));
        Assertions.assertEquals(1, occurrences(extract,
            "this.mainHandRenderItem = ItemStack.EMPTY;"),
            "main-hand suppression must only replace the extracted render snapshot once");
        Assertions.assertEquals(1, occurrences(extract,
            "this.offHandRenderItem = ItemStack.EMPTY;"),
            "offhand suppression must only replace the extracted render snapshot once");
        Assertions.assertEquals("{this.mainHandRenderItem=ItemStack.EMPTY;}",
            mainSuppression.replaceAll("\\s+", ""),
            "main-hand suppression must not alter its arm, inventory or gameplay state");
        Assertions.assertEquals("{this.offHandRenderItem=ItemStack.EMPTY;}",
            offhandSuppression.replaceAll("\\s+", ""),
            "offhand suppression must not alter its arm, inventory or gameplay state");

        Assertions.assertFalse(extract.contains("setItemInHand("),
            "render suppression must not mutate either gameplay hand");
        Assertions.assertFalse(extract.contains("getInventory("),
            "render suppression must not access or mutate the inventory");
        Assertions.assertFalse(extract.contains("containerMenu"),
            "render suppression must not perform a container transaction");
        Assertions.assertFalse(extract.contains("gameMode."),
            "render suppression must not invoke a world/gameplay action");
        Assertions.assertFalse(extract.contains("swing("),
            "render suppression must not animate or attack with either arm");
        Assertions.assertFalse(extract.contains("releaseUsingItem("));
        Assertions.assertFalse(extract.contains("stopUsingItem("));
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        int offset = 0;
        while ((offset = source.indexOf(needle, offset)) >= 0) {
            count++;
            offset += needle.length();
        }
        return count;
    }

    private static String bracedBlock(String source, String marker) {
        int markerIndex = source.indexOf(marker);
        Assertions.assertTrue(markerIndex >= 0, () -> "block marker not found: " + marker);
        int open = source.indexOf('{', markerIndex + marker.length());
        Assertions.assertTrue(open >= 0, () -> "opening brace not found: " + marker);
        int depth = 0;
        for (int index = open; index < source.length(); index++) {
            char character = source.charAt(index);
            if (character == '{') {
                depth++;
            } else if (character == '}' && --depth == 0) {
                return source.substring(open, index + 1);
            }
        }
        throw new AssertionError("closing brace not found: " + marker);
    }

    private static String method(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        Assertions.assertTrue(from >= 0 && to > from,
            () -> "method markers not found: " + start + " -> " + end);
        return source.substring(from, to);
    }

    private static String source(String relative) throws IOException {
        return Files.readString(MAIN.resolve(relative)).replace("\r\n", "\n");
    }
}
