package org.vivecraft.client_vr.render.helpers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Guards the two render paths that can draw a local held item.  Wrist shield
 * suppression belongs to the controller-arm snapshot; the optional first
 * person avatar must not introduce a second, unsuppressed held-item copy.
 */
class HeldItemOverlayRegressionContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void controllerArmSuppressionOnlyReplacesRenderSnapshots() throws IOException {
        String extract = method(source(
                "org/vivecraft/client_vr/render/renderstates/ArmsRenderState.java"),
            "public void extract(",
            "\n    }");

        int mainExtract = extract.indexOf(
            "this.mainHandRenderItem = VRArmHelper.extractHandRenderItem(player, InteractionHand.MAIN_HAND);");
        int offExtract = extract.indexOf(
            "this.offHandRenderItem = VRArmHelper.extractHandRenderItem(player, InteractionHand.OFF_HAND);");
        int mainPolicy = extract.indexOf(
            "ControllerType.RIGHT, this.mainHandRenderItem");
        int offPolicy = extract.indexOf(
            "ControllerType.LEFT, this.offHandRenderItem");

        Assertions.assertTrue(mainExtract >= 0 && mainPolicy > mainExtract,
            "main-hand policy must inspect the extracted render snapshot");
        Assertions.assertTrue(offExtract >= 0 && offPolicy > offExtract,
            "offhand policy must inspect the extracted render snapshot");
        Assertions.assertFalse(extract.contains("setItemInHand("));
        Assertions.assertFalse(extract.contains("containerMenu"));
        Assertions.assertFalse(extract.contains("releaseUsingItem("));
        Assertions.assertFalse(extract.contains("stopUsingItem("));
    }

    @Test
    void optionalFirstPersonAvatarCannotDuplicateOrdinaryHeldItems() throws IOException {
        String mixin = source(
            "org/vivecraft/mixin/client/renderer/entity/state/ArmedEntityRenderStateMixin.java");
        String wrapper = method(mixin,
            "private static ItemStack vivecraft$noItemsInFirstPerson(",
            "\n    }");

        Assertions.assertTrue(wrapper.contains(
            "VREffectsHelper.isRenderingFirstPersonPlayer(renderState)"));
        Assertions.assertTrue(wrapper.contains("return ItemStack.EMPTY;"),
            "the local avatar item layer must stay empty in first person");
        Assertions.assertTrue(wrapper.contains("ViveItems.isClimbingClaws(itemStack)"),
            "the only retained exception is the existing complete-arm climbing-claw path");
        Assertions.assertFalse(wrapper.contains("ShieldItem"),
            "a shield must never bypass first-person item suppression through the avatar path");
        Assertions.assertFalse(wrapper.contains("VIVECRAFT_SHIELDS"),
            "tagged shields must not gain an avatar-only exception");
    }

    @Test
    void openXrMapsPhysicalHandsIntoLogicalSlotsBeforeConsumersReadThem() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java");
        String update = method(provider, "private void updatePose()", "\n    public void readNewData(");

        int refresh = update.indexOf("this.refreshHandMapping(this.dh.vrSettings.reverseHands);");
        int mapping = update.indexOf(
            "int physical = OpenXRHandedness.physicalIndex(logical, this.reverseHandsForFrame);");
        int gripRead = update.indexOf("this.gripActions[physical], logicalController");
        int aimRead = update.indexOf("this.aimActions[physical], logicalController");
        int logicalGripPose = update.indexOf("this.gripLocationFlags[logical]");

        Assertions.assertTrue(refresh >= 0 && mapping > refresh,
            "reverse-hands mapping must be frozen before the frame reads either hand");
        Assertions.assertTrue(gripRead > mapping && aimRead > mapping,
            "physical OpenXR actions must be read into logical controller identities");
        Assertions.assertTrue(logicalGripPose > mapping,
            "located poses must be published to logical slots used by Wrist and held-item rendering");
    }

    private static String method(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        Assertions.assertTrue(from >= 0 && to > from,
            () -> "method markers not found: " + start + " -> " + end);
        return source.substring(from, to);
    }

    private static String source(String relative) throws IOException {
        return Files.readString(MAIN.resolve(relative));
    }
}
