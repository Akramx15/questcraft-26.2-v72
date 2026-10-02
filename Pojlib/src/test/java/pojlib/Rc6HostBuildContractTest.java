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

public class Rc6HostBuildContractTest {
    private static final Path ROOT = Path.of("..");

    @Test
    public void rc6UsesANewFailClosedLabIdentityAndNeverTargetsStable() throws Exception {
        String script = read("scripts/build-v71-lab-rc6-integrated.ps1");
        String builder = read(
                "QCXR-XR-Wrapper/Assets/Editor/QuestCraftV71Rc6LabCliBuild.cs");

        assertTrue(script.contains("$package = 'com.qcxr.qcxr.canary262'"));
        assertTrue(script.contains("$forbiddenStablePackage = 'com.qcxr.qcxr.dev262'"));
        assertTrue(script.contains(
                "$versionName = '6.0.1-26.2-vivecraft-personal.12-rc.6'"));
        assertTrue(script.contains("QuestCraftV71Rc6LabCliBuild.BuildAndroid"));
        assertTrue(script.contains("for ($buildNumber = 1; $buildNumber -le 2;"));
        assertTrue(script.contains("AdbInvocations = 0"));
        assertFalse(script.contains("& adb "));
        assertFalse(script.contains("adb.exe"));

        assertTrue(builder.contains(
                "ApplicationIdentifier = \"com.qcxr.qcxr.canary262\""));
        assertTrue(builder.contains(
                "VersionName = \"6.0.1-26.2-vivecraft-personal.12-rc.6\""));
        assertTrue(builder.contains("VersionCode = \"71\""));
        assertTrue(builder.contains(
                "QuestCraft-Vivecraft-Lab-26.2-v71-rc.6-integrated-local.apk"));
        assertTrue(builder.contains("HasArgument(\"-release\")"));
    }

    @Test
    public void rc6LockPinsNewPayloadsWithoutReusingHistoricalRc5Evidence()
            throws Exception {
        JsonObject lock = JsonParser.parseString(read("V71_LAB_RC6.lock.json"))
                .getAsJsonObject();
        JsonObject target = lock.getAsJsonObject("target");
        JsonObject pair = lock.getAsJsonObject("pair");
        JsonObject core = pair.getAsJsonObject("core");
        JsonObject veq = pair.getAsJsonObject("veq");
        JsonObject predecessor = lock.getAsJsonObject("predecessor");

        assertEquals("com.qcxr.qcxr.canary262", target.get("package").getAsString());
        assertEquals("com.qcxr.qcxr.dev262",
                target.get("forbiddenStablePackage").getAsString());
        assertFalse(target.get("stableTouched").getAsBoolean());
        assertEquals("26.2-1.3.15+qc.v71.rc6",
                core.get("fabricVersion").getAsString());
        assertEquals("0.7.0-v71.rc6", veq.get("fabricVersion").getAsString());
        assertEquals(
                "ED3E2980F6B377E42BB598F5AFB1C3412F05AEECA9043534DBB21734BFD0BFD7",
                pair.get("sha256").getAsString());
        assertTrue(predecessor.get("immutableArtifactsAndReceipts").getAsBoolean());
        assertEquals(
                "AAD1B8F94DE7D4F65BF481CE65FCA83FAFFC7B0961435E95EF3F1899CF038879",
                predecessor.get("apkSha256").getAsString());
    }

    private static String read(String relative) throws Exception {
        return new String(Files.readAllBytes(ROOT.resolve(relative)), StandardCharsets.UTF_8);
    }
}
