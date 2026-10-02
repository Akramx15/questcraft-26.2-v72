package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class LabJvmNativeMemoryDiagnosticsSourceIntegrationTest {
    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }

    @Test
    public void sourceIsMarkerArmedExactLabOnlyAndBounded() throws Exception {
        String source = read(
                "src/main/java/pojlib/util/LabJvmNativeMemoryDiagnostics.java");
        int packageCheck = source.indexOf(
                "!EXPECTED_PACKAGE.equals(activity.getPackageName())");
        int prepare = source.indexOf("prepareArguments(", packageCheck);

        assertTrue(source.contains(
                "EXPECTED_PACKAGE = \"com.qcxr.qcxr.canary262\""));
        assertTrue(!source.contains("com.qcxr.qcxr.dev262"));
        assertTrue(packageCheck >= 0 && prepare > packageCheck);
        assertTrue(source.contains(
                "ENABLE_MARKER_NAME = \"enable-jvm-native-memory-probe\""));
        assertTrue(source.contains("DURATION_MINUTES = 15"));
        assertTrue(source.contains("MAX_RECORDING_MIB = 16"));
        assertTrue(source.contains("NMT_PREFIX + \"summary\""));
        assertTrue(source.contains("JFR_PREFIX +"));
    }

    @Test
    public void jreWiresProbeOnlyInsideJava25Branch() throws Exception {
        String jre = read("src/main/java/pojlib/util/JREUtils.java");
        int java25 = jre.indexOf("if(javaMajor >= 25)");
        int probe = jre.indexOf(
                "LabJvmNativeMemoryDiagnostics.addIfEligible(", java25);
        int legacy = jre.indexOf("} else {", java25);
        int minecraftArguments = jre.indexOf("userArgs.addAll(JVMArgs);", probe);

        assertTrue(java25 >= 0);
        assertTrue(probe > java25 && probe < legacy);
        assertTrue(minecraftArguments > probe);
        assertTrue(!jre.contains("JAVA_TOOL_OPTIONS"));
    }
}
