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

/** Historical guard for the immutable, Lab-only RC7 identity. */
public class Rc7IdentityContractTest {
    private static final Path ROOT = Path.of("..");
    private static final String VERSION =
            "6.0.1-26.2-vivecraft-personal.12-rc.7";
    private static final String CORE_VERSION = "26.2-1.3.15+qc.v71.rc7";
    private static final String CORE_SHA256 =
            "A1A522C2BB949DBDC2A3AE475B900407324441DA50D94E012A7C734B32E498D3";

    @Test
    public void rc7BuilderRemainsExactLabOnlyAndDebugOnly() throws Exception {
        String builder = read(
                "QCXR-XR-Wrapper/Assets/Editor/QuestCraftV71Rc7LabCliBuild.cs");
        assertTrue(builder.contains(
                "ApplicationIdentifier = \"com.qcxr.qcxr.canary262\""));
        assertTrue(builder.contains("VersionName = \"" + VERSION + "\""));
        assertTrue(builder.contains("VersionCode = \"71\""));
        assertTrue(builder.contains("HasArgument(\"-release\")"));
        assertFalse(builder.contains("com.qcxr.qcxr.dev262"));
    }

    @Test
    public void rc7HistoricalLockRemainsPinned() throws Exception {
        JsonObject lock = JsonParser.parseString(read("V71_LAB_RC7.lock.json"))
                .getAsJsonObject();
        JsonObject target = lock.getAsJsonObject("target");
        JsonObject core = lock.getAsJsonObject("pair").getAsJsonObject("core");
        assertEquals("com.qcxr.qcxr.canary262", target.get("package").getAsString());
        assertEquals("com.qcxr.qcxr.dev262",
                target.get("forbiddenStablePackage").getAsString());
        assertEquals(VERSION, target.get("versionName").getAsString());
        assertEquals(CORE_VERSION, core.get("fabricVersion").getAsString());
        assertEquals(CORE_SHA256, core.get("sha256").getAsString());
        assertFalse(target.get("stableTouched").getAsBoolean());
    }

    @Test
    public void rc7RemainsAllowlistedButCannotMasqueradeAsRc8() throws Exception {
        String policy = read("Pojlib/src/main/java/pojlib/LauncherResourceReleasePolicy.java");
        String launcher = read("QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");
        String verifier = read("scripts/verify-dev-apk.ps1");
        assertTrue(policy.contains("LAB_RC7_VERSION_NAME.equals(versionName)"));
        assertTrue(launcher.contains("LauncherResourceReleaseLabRc7Version"));
        assertTrue(verifier.contains("'questcraft-vivecraft-core-canary-v8'"));
        assertTrue(verifier.contains("'" + CORE_VERSION + "'"));
        assertTrue(verifier.contains("'" + CORE_SHA256.toLowerCase() + "'"));
    }

    private static String read(String relative) throws Exception {
        return new String(Files.readAllBytes(ROOT.resolve(relative)), StandardCharsets.UTF_8);
    }
}
