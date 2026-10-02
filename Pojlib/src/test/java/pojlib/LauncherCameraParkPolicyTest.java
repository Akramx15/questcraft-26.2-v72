package pojlib;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class LauncherCameraParkPolicyTest {
    @Test
    public void onlyLabAndPersonalPackagesCanParkLauncherCameras() {
        assertTrue(LauncherCameraParkPolicy.isEligiblePackage("com.qcxr.qcxr.canary262"));
        assertTrue(LauncherCameraParkPolicy.isEligiblePackage("com.qcxr.qcxr.dev262"));
        assertFalse(LauncherCameraParkPolicy.isEligiblePackage("com.qcxr.qcxr"));
        assertFalse(LauncherCameraParkPolicy.isEligiblePackage("com.example.other"));
        assertFalse(LauncherCameraParkPolicy.isEligiblePackage(null));
    }

    @Test
    public void manualLaunchDefaultsOnOnlyInsideEligiblePackage() {
        LauncherCameraParkPolicy.State state = new LauncherCameraParkPolicy.State();

        assertTrue(state.isEnabled(true));
        assertFalse(state.isEnabled(false));
        assertEquals("manual", state.getRunIdForLog());
        assertEquals("ON", state.getModeForLog());
    }

    @Test
    public void consumedAutoplayModeOverridesManualDefaultUntilAbort() {
        LauncherCameraParkPolicy.State state = new LauncherCameraParkPolicy.State();

        state.activate("off-run", "off");
        assertFalse(state.isEnabled(true));
        assertEquals("off-run", state.getRunIdForLog());
        assertEquals("OFF", state.getModeForLog());

        state.abort();
        assertFalse(state.hasActiveOverride());
        assertTrue(state.isEnabled(true));

        state.activate("on-run", " ON ");
        assertTrue(state.isEnabled(true));
        assertTrue(state.hasActiveOverride());
        assertEquals("on-run", state.getRunIdForLog());
        assertEquals("ON", state.getModeForLog());
    }

    @Test
    public void completedOffOverrideDoesNotLeakIntoLaterManualPlay() {
        LauncherCameraParkPolicy.State state = new LauncherCameraParkPolicy.State();
        state.activate("off-run", "OFF");
        assertFalse(state.isEnabled(true));

        state.complete();

        assertFalse(state.hasActiveOverride());
        assertTrue(state.isEnabled(true));
        assertEquals("manual", state.getRunIdForLog());
        assertEquals("ON", state.getModeForLog());
    }

    @Test
    public void completedOnOverrideDoesNotLeakItsRunIntoLaterManualPlay() {
        LauncherCameraParkPolicy.State state = new LauncherCameraParkPolicy.State();
        state.activate("on-run", "ON");
        assertTrue(state.isEnabled(true));

        state.complete();

        assertFalse(state.hasActiveOverride());
        assertTrue(state.isEnabled(true));
        assertEquals("manual", state.getRunIdForLog());
        assertEquals("ON", state.getModeForLog());
    }

    @Test
    public void modeNormalizationRequiresAnExplicitSafeValue() {
        assertEquals("ON", LauncherCameraParkPolicy.normalizeMode("on"));
        assertEquals("OFF", LauncherCameraParkPolicy.normalizeMode(" OFF "));
        assertNull(LauncherCameraParkPolicy.normalizeMode(null));
        assertNull(LauncherCameraParkPolicy.normalizeMode(""));
        assertNull(LauncherCameraParkPolicy.normalizeMode("ON\nforged"));
        assertNull(LauncherCameraParkPolicy.normalizeMode("AUTO"));
    }

    @Test
    public void resultIsAllowlistedAndCorrelatedWithRunAndMode() {
        LauncherCameraParkPolicy.State state = new LauncherCameraParkPolicy.State();
        state.activate("run-123", "ON");

        LauncherCameraParkPolicy.Result applied = state.createResult(" applied ", 3);
        assertEquals("run-123", applied.runId);
        assertEquals("ON", applied.mode);
        assertEquals("APPLIED", applied.status);
        assertEquals(3, applied.cameraCount);

        LauncherCameraParkPolicy.Result failed = state.createResult("failed", -7);
        assertEquals("FAILED", failed.status);
        assertEquals(0, failed.cameraCount);

        assertNull(state.createResult("UNKNOWN", 0));
        assertNull(state.createResult("APPLIED", 0));
        assertNull(state.createResult("NO_CAMERAS", 1));
    }

    @Test
    public void offOverrideCannotReportAnAppliedResult() {
        LauncherCameraParkPolicy.State state = new LauncherCameraParkPolicy.State();
        state.activate("off-run", "OFF");

        assertNull(state.createResult("APPLIED", 3));
        assertNull(state.createResult("FAILED", 0));
    }

    @Test(expected = IllegalArgumentException.class)
    public void stateRejectsMissingRunId() {
        new LauncherCameraParkPolicy.State().activate("", "ON");
    }

    @Test(expected = IllegalArgumentException.class)
    public void stateRejectsUnsafeMode() {
        new LauncherCameraParkPolicy.State().activate("run", "ON;rm");
    }
}
