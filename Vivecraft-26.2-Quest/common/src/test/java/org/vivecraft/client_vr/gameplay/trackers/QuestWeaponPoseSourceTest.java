package org.vivecraft.client_vr.gameplay.trackers;

import org.joml.Vector3f;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.Vector3fHistory;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class QuestWeaponPoseSourceTest {
    @Test
    void gripPoseKeepsItsOwnOriginWhileSwingUsesVisibleAimPose() throws IOException {
        String vrData = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/VRData.java"));
        String swingTracker = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/gameplay/trackers/SwingTracker.java"));
        String poseMath = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/provider/openxr/OpenXRPoseMath.java"));

        Assertions.assertTrue(vrData.contains("mcVR.getHandSource(0)"));
        Assertions.assertTrue(vrData.contains("mcVR.getHandSource(1)"));
        Assertions.assertTrue(swingTracker.contains("vrdata_world_pre.getController(c)"));
        Assertions.assertTrue(swingTracker.contains("vrdata_room_pre.getController(c)"));
        Assertions.assertFalse(swingTracker.contains("vrdata_world_pre.getHand(c)"));
        Assertions.assertFalse(swingTracker.contains("vrdata_room_pre.getHand(c)"));
        Assertions.assertFalse(poseMath.contains("setTranslation(0.0F, 0.0F, 0.0F)"));
    }

    @Test
    void trackingLossClearsVelocityAndCollisionStateBeforeReacquisition() throws IOException {
        Vector3fHistory history = new Vector3fHistory();
        history.add(new Vector3f(0.0F, 0.0F, 0.0F));
        history.add(new Vector3f(4.0F, 0.0F, 0.0F));
        Assertions.assertFalse(history.isEmpty());

        history.clear();

        Assertions.assertTrue(history.isEmpty());
        Assertions.assertEquals(0.0F, history.averageSpeed(0.33D));
        Assertions.assertEquals(new Vector3f(), history.netMovement(0.33D));

        String swingTracker = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/gameplay/trackers/SwingTracker.java"));
        int invalidAim = swingTracker.indexOf(
            "if (isHand && !this.dh.vr.isControllerAimTracking(c)) {");
        int reset = swingTracker.indexOf("this.resetTransientState(i);", invalidAim);
        int invalidAimContinue = swingTracker.indexOf("continue;", invalidAim);
        Assertions.assertTrue(invalidAim >= 0);
        Assertions.assertTrue(reset > invalidAim && reset < invalidAimContinue);
        Assertions.assertTrue(swingTracker.contains("this.attackingPoint[tracker] = null;"));
        Assertions.assertTrue(swingTracker.contains("this.weaponTip[tracker] = null;"));
        Assertions.assertTrue(swingTracker.contains("this.lastHitEntities[tracker] = Collections.emptyList();"));
        Assertions.assertTrue(swingTracker.contains("this.lastWeaponSolid[tracker] = false;"));
        Assertions.assertTrue(swingTracker.contains("this.baseHistory[tracker].clear();"));
        Assertions.assertTrue(swingTracker.contains("this.tipHistory[tracker].clear();"));
        Assertions.assertTrue(swingTracker.contains("this.tipDirHistory[tracker].clear();"));
    }
}
