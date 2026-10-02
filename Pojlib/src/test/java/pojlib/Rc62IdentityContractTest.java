package pojlib;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

/** Source-level guard for the isolated RC6.2 tight-space Lab identity. */
public class Rc62IdentityContractTest {
    private static final Path ROOT = Path.of("..");
    private static final String VERSION =
            "6.0.1-26.2-vivecraft-personal.12-rc.6.2";
    private static final String CORE_VERSION = "26.2-1.3.15+qc.v71.rc6.2";
    private static final String CORE_SHA256 =
            "6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF";
    private static final String VEQ_SHA256 =
            "BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD";

    @Test
    public void rc62BuilderIsExactLabOnlyAndDebugOnly() throws Exception {
        String builder = read(
                "QCXR-XR-Wrapper/Assets/Editor/QuestCraftV71Rc62LabCliBuild.cs");

        assertTrue(builder.contains(
                "ApplicationIdentifier = \"com.qcxr.qcxr.canary262\""));
        assertTrue(builder.contains(
                "ProductName = \"QuestCraft Vivecraft Lab 26.2\""));
        assertTrue(builder.contains("VersionName = \"" + VERSION + "\""));
        assertTrue(builder.contains("VersionCode = \"71\""));
        assertTrue(builder.contains(
                "Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.6.2-tight-space-local.apk"));
        assertTrue(builder.contains("HasArgument(\"-release\")"));
        assertTrue(builder.contains("QuestCraftCliBuild.BuildAndroid();"));
        assertFalse(builder.contains("com.qcxr.qcxr.dev262"));
    }

    @Test
    public void rc62ImmutableLockRetainsItsExactHistoricalPayloads() throws Exception {
        JsonObject lock = JsonParser.parseString(read("V71_LAB_RC6_2.lock.json"))
                .getAsJsonObject();
        JsonObject target = lock.getAsJsonObject("target");
        JsonObject pair = lock.getAsJsonObject("pair");
        JsonObject core = pair.getAsJsonObject("core");
        JsonObject veq = pair.getAsJsonObject("veq");

        assertTrue(lock.get("immutable").getAsBoolean());
        assertEquals(VERSION, target.get("versionName").getAsString());
        assertEquals("com.qcxr.qcxr.canary262", target.get("package").getAsString());
        assertFalse(target.get("stableTouched").getAsBoolean());
        assertEquals(CORE_VERSION, core.get("fabricVersion").getAsString());
        assertEquals(CORE_SHA256, core.get("sha256").getAsString());
        assertEquals(10_068_468L, core.get("sizeBytes").getAsLong());
        assertEquals("0.7.0-v71.rc6", veq.get("fabricVersion").getAsString());
        assertEquals(VEQ_SHA256, veq.get("sha256").getAsString());
    }

    @Test
    public void rc62IsExplicitlyAllowedByBothReleaseGates() throws Exception {
        String policy = read(
                "Pojlib/src/main/java/pojlib/LauncherResourceReleasePolicy.java");
        String launcher = read("QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");

        assertTrue(policy.contains("LAB_RC6_2_VERSION_NAME ="));
        assertTrue(policy.contains("LAB_RC6_2_VERSION_NAME.equals(versionName)"));
        assertTrue(policy.contains(VERSION));
        assertTrue(launcher.contains("LauncherResourceReleaseLabRc62Version ="));
        assertTrue(launcher.contains(
                "Application.version, LauncherResourceReleaseLabRc62Version"));
        assertTrue(launcher.contains(VERSION));
    }

    @Test
    public void verifierHasASeparateRc62HarnessBranch() throws Exception {
        String verifier = read("scripts/verify-dev-apk.ps1");
        int rc62 = verifier.indexOf("'" + VERSION + "'");
        int historicalRc6 = verifier.indexOf("$ExpectedVersionName -in @(", rc62);

        assertTrue(rc62 >= 0);
        assertTrue(historicalRc6 > rc62);
        String branch = verifier.substring(rc62, historicalRc6);
        assertTrue(branch.contains("'questcraft-vivecraft-core-canary-v7'"));
        assertTrue(branch.contains("'" + CORE_VERSION + "'"));
        assertTrue(branch.contains("'" + CORE_SHA256.toLowerCase() + "'"));
        assertTrue(branch.contains("'questcraft-veq-v71-canary-v4'"));
        assertTrue(branch.contains("'0.7.0-v71.rc6'"));
        assertTrue(branch.contains("'" + VEQ_SHA256.toLowerCase() + "'"));
    }

    private static String read(String relative) throws Exception {
        return new String(Files.readAllBytes(ROOT.resolve(relative)), StandardCharsets.UTF_8);
    }
}
