package pojlib;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class LauncherResourceReleasePolicyTest {
    @Test
    public void onlyExactV71AndV72BuildIdentitiesAreEligible() {
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC4,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.4"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.5"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.5.1"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.5.2"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.6"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.6.1"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.STABLE_V71,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.dev262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.dev262", 69L,
                        "6.0.1-26.2-vivecraft-personal.10"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr", 71L,
                        "6.0.1-26.2-vivecraft-personal.12"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.3"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.5.3"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.6.2"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.7"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.8"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.7.1"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 71L,
                        "6.0.1-26.2-vivecraft-personal.12-rc.8.1"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.STABLE_V72,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.dev262", 72L,
                        "6.0.1-26.2-vivecraft-personal.13"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.dev262", 71L,
                        "6.0.1-26.2-vivecraft-personal.13"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.dev262", 72L,
                        "6.0.1-26.2-vivecraft-personal.12"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(
                        "com.qcxr.qcxr.canary262", 72L,
                        "6.0.1-26.2-vivecraft-personal.13"));
        assertEquals(LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE,
                LauncherResourceReleasePolicy.resolveIdentity(null, 71L, null));
    }

    @Test
    public void absentModeDefaultsOffAndUnsafeModeIsRejected() {
        assertEquals("OFF", LauncherResourceReleasePolicy.normalizeOptionalMode(null));
        assertEquals("OFF", LauncherResourceReleasePolicy.normalizeOptionalMode("  "));
        assertEquals("OFF", LauncherResourceReleasePolicy.normalizeOptionalMode("off"));
        assertEquals("ON", LauncherResourceReleasePolicy.normalizeOptionalMode(" ON "));
        assertNull(LauncherResourceReleasePolicy.normalizeOptionalMode("ON\nforged"));
        assertNull(LauncherResourceReleasePolicy.normalizeOptionalMode("AUTO"));
    }

    @Test
    public void manualLabAndStableRunsReleaseByDefault() {
        LauncherResourceReleasePolicy.State state = new LauncherResourceReleasePolicy.State();

        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC4));
        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5));
        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.STABLE_V71));
        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.STABLE_V72));
        assertFalse(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE));
    }

    @Test
    public void explicitLabOffDisablesOnlyLabRelease() {
        LauncherResourceReleasePolicy.State state = new LauncherResourceReleasePolicy.State();
        state.activate("lab-run", "OFF");

        assertTrue(state.hasActiveOverride());
        assertFalse(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC4));
        assertFalse(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5));
        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.STABLE_V71));
        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.STABLE_V72));
    }

    @Test
    public void explicitLabOnEnablesRelease() {
        LauncherResourceReleasePolicy.State state = new LauncherResourceReleasePolicy.State();
        state.activate("lab-run", "ON");

        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC4));
        assertTrue(state.shouldRelease(
                LauncherResourceReleasePolicy.BuildIdentity.LAB_V71_RC5));
    }

    @Test(expected = IllegalArgumentException.class)
    public void invalidConsumedModeIsRejected() {
        new LauncherResourceReleasePolicy.State().activate("lab-run", "ON;rm");
    }
}
