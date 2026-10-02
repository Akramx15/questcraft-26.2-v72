package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class VeqCanarySourceIntegrationTest {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";
    private static final String BASELINE =
            "ff7f6fcfda21895764b69f3316ce7e9ebd8d890df675c1e8007835b3814573f9";
    @Test
    public void veqGateIsFixedToLabProfileTargetAndMarkerBoundV71Candidate() throws Exception {
        String gate = read("src/main/java/pojlib/VeqCanaryGate.java");

        assertTrue(gate.contains("EXPECTED_PACKAGE = \"" + LAB_PACKAGE + "\""));
        assertTrue(!gate.contains("EXPECTED_PACKAGE = \"" + STABLE_PACKAGE + "\""));
        assertTrue(gate.contains("PROFILE = \"26.2\""));
        assertTrue(gate.contains("TARGET = \"mods/Vivecraft-Essentials-Quest.jar\""));
        assertTrue(gate.contains(BASELINE));
        assertTrue(gate.contains("HARNESS_ID = \"questcraft-veq-v71-canary-v5\""));
        assertTrue(gate.contains("EXPECTED_FABRIC_VERSION = \"0.7.0-v71.rc6\""));
        assertTrue(gate.contains("? Collections.singleton(requested.candidateSha256)"));
        assertTrue(!gate.contains("APPROVED_CANDIDATE_SHA256"));
        assertTrue(gate.contains(
                "35b71c9c432b42af067d65beeb1e966c2242181d085449c411b230f568800095"));
        assertTrue(gate.contains("version.defaultMods"));

        int packageGuard = gate.indexOf(
                "if(!EXPECTED_PACKAGE.equals(activity.getPackageName()))");
        int profilePath = gate.indexOf("Paths.get(instance.gameDir)");
        int markerProbe = gate.indexOf("Files.exists(marker");
        assertTrue(packageGuard >= 0);
        assertTrue(profilePath > packageGuard);
        assertTrue(markerProbe > packageGuard);
    }

    @Test
    public void veqPromotionRunsAtTheEndOfPrelaunchAndVerifierCanRestoreIt() throws Exception {
        String api = read("src/main/java/pojlib/API.java");
        int config = api.indexOf("MinecraftInstances.CheckVivecraftConfig(instance);");
        int core = api.indexOf("VivecraftCoreCanaryGate.prepare(activity, instance)", config);
        int veq = api.indexOf("VeqCanaryGate.prepare(activity, instance)", core);
        int success = api.indexOf("return true;", veq);
        assertTrue(config >= 0);
        assertTrue(core > config);
        assertTrue(veq > core);
        assertTrue(success > veq);

        String verifier = read("src/main/java/pojlib/UnattendedStackVerifier.java");
        assertTrue(verifier.contains("VeqCanaryGate.verifyVeqArtifact"));
        assertTrue(verifier.contains("VeqCanaryGate.abortPromotedCandidate()"));
        assertTrue(verifier.contains("veqCanaryPermitPresent && !verified"));

        String gate = read("src/main/java/pojlib/VeqCanaryGate.java");
        int priorPermitRestore = gate.indexOf(
                "processPermit != null && !abortPromotedCandidate()");
        int markerProbe = gate.indexOf("Files.exists(marker");
        assertTrue(priorPermitRestore >= 0);
        assertTrue(markerProbe > priorPermitRestore);
        assertTrue(api.contains("if(VeqCanaryGate.hasProcessPermit())"));
    }

    @Test
    public void pairedCoreAndVeqPermitsUseTheSameTwoTargetFingerprint() throws Exception {
        String core = read("src/main/java/pojlib/VivecraftCoreCanaryGate.java");
        String veq = read("src/main/java/pojlib/VeqCanaryGate.java");
        String api = read("src/main/java/pojlib/API.java");
        String verifier = read("src/main/java/pojlib/UnattendedStackVerifier.java");
        String modsAb = read("src/main/java/pojlib/ModsAbCanaryGate.java");

        assertTrue(core.contains("gameDirectory.resolve(VeqCanaryGate.TARGET)"));
        assertTrue(veq.contains("gameDirectory.resolve(VivecraftCoreCanaryGate.TARGET)"));
        assertTrue(!veq.contains("concurrent canary permits are forbidden"));
        int veqFailure = api.indexOf("if(!VeqCanaryGate.prepare(activity, instance))");
        int abortCore = api.indexOf("VivecraftCoreCanaryGate.abortPromotedCandidate()", veqFailure);
        assertTrue(veqFailure >= 0 && abortCore > veqFailure);
        assertTrue(verifier.indexOf("VivecraftCoreCanaryGate.abortPromotedCandidate()") <
                verifier.indexOf("VeqCanaryGate.abortPromotedCandidate()"));
        assertTrue(modsAb.contains(
                "VivecraftCoreCanaryGate.hasProcessPermit() || VeqCanaryGate.hasProcessPermit()"));
        int modsPrepare = api.indexOf("ModsAbCanaryGate.prepare(activity, instance)", veqFailure);
        assertTrue(modsPrepare > veqFailure);
    }

    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }
}
