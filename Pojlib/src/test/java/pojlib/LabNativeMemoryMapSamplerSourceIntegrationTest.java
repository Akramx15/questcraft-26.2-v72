package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class LabNativeMemoryMapSamplerSourceIntegrationTest {
    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }

    @Test
    public void samplerIsExactLabOnlyBoundedAndNeverPersistsRawMaps() throws Exception {
        String source = read("src/main/java/pojlib/util/LabNativeMemoryMapSampler.java");
        int packageCheck = source.indexOf(
                "!EXPECTED_PACKAGE.equals(activity.getPackageName())");
        int prepare = source.indexOf("prepareOutputDirectory(", packageCheck);

        assertTrue(source.contains(
                "EXPECTED_PACKAGE = \"com.qcxr.qcxr.canary262\""));
        assertTrue(!source.contains("com.qcxr.qcxr.dev262"));
        assertTrue(packageCheck >= 0 && prepare > packageCheck);
        assertTrue(source.contains("SELF_SMAPS = Paths.get(\"/proc/self/smaps\")"));
        assertTrue(source.contains("ENABLE_MARKER_NAME = \"enable-memory-map-probe\""));
        assertTrue(source.contains("SAMPLE_INTERVAL_SECONDS = 60"));
        assertTrue(source.contains("MAX_FILE_MIB = 1"));
        assertTrue(source.contains("FILE_COUNT = 3"));
        assertTrue(source.contains("snapshot.toJson()"));
        assertTrue(!source.contains("Files.copy(SELF_SMAPS"));
        int sampleCall = source.indexOf("writeOneSample();");
        int sleep = source.indexOf("Thread.sleep(SAMPLE_INTERVAL_SECONDS", sampleCall);
        int sampleMethod = source.indexOf("private void writeOneSample()", sleep);
        int parse = source.indexOf(
                "snapshot = parse(input, SystemClock.elapsedRealtime())", sampleMethod);
        assertTrue(sampleCall >= 0 && sleep > sampleCall);
        assertTrue(sampleMethod > sleep && parse > sampleMethod);
        assertTrue(source.contains(
                "sleeping sampler retains no previous snapshot"));
    }

    @Test
    public void launchOwnsAndAlwaysClosesSamplerSession() throws Exception {
        String jre = read("src/main/java/pojlib/util/JREUtils.java");
        int start = jre.indexOf("LabNativeMemoryMapSampler.startIfEligible(activity, instance)");
        int launch = jre.indexOf("VMLauncher.launchJVM", start);
        int finallyBlock = jre.indexOf("finally", launch);
        int close = jre.indexOf("nativeMemoryMapSampler.close();", finallyBlock);

        assertTrue(start >= 0 && launch > start);
        assertTrue(finallyBlock > launch && close > finallyBlock);
    }
}
