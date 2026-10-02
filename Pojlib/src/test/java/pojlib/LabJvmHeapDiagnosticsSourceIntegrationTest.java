package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class LabJvmHeapDiagnosticsSourceIntegrationTest {
    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }

    @Test
    public void diagnosticIsExactLabOnlyBoundedAndContainsNoSensitiveSelectors()
            throws Exception {
        String source = read("src/main/java/pojlib/util/LabJvmHeapDiagnostics.java");

        int packageCheck = source.indexOf(
                "!EXPECTED_PACKAGE.equals(activity.getPackageName())");
        int instanceCheck = source.indexOf("instance == null", packageCheck);
        int prepare = source.indexOf("prepareArgument(", instanceCheck);
        assertTrue(source.contains(
                "EXPECTED_PACKAGE = \"com.qcxr.qcxr.canary262\""));
        assertTrue(!source.contains("com.qcxr.qcxr.dev262"));
        assertTrue(packageCheck >= 0);
        assertTrue(instanceCheck > packageCheck);
        assertTrue(prepare > instanceCheck);
        assertTrue(source.contains("DIAGNOSTIC_DIRECTORY = \".questcraft-lab/jvm-heap\""));
        assertTrue(source.contains("XLOG_PREFIX = \"-Xlog:gc+heap=debug:file=\""));
        assertTrue(source.contains("LOG_FILE_COUNT = 3"));
        assertTrue(source.contains("LOG_FILE_SIZE_MIB = 2"));
        assertTrue(!source.contains("StartFlightRecording"));
        assertTrue(!source.contains("jdk.ExecutionSample"));
        assertTrue(!source.contains("jdk.Socket"));
    }

    @Test
    public void jreAddsDiagnosticBeforeMinecraftClasspathAndOnlyForJava25Path()
            throws Exception {
        String jre = read("src/main/java/pojlib/util/JREUtils.java");
        int java25 = jre.indexOf("if(javaMajor >= 25)");
        int diagnostic = jre.indexOf(
                "LabJvmHeapDiagnostics.addIfEligible(activity, instance, javaMajor, userArgs);",
                java25);
        int legacy = jre.indexOf("} else {", java25);
        int minecraftArguments = jre.indexOf("userArgs.addAll(JVMArgs);", diagnostic);

        assertTrue(java25 >= 0);
        assertTrue(diagnostic > java25);
        assertTrue(diagnostic < legacy);
        assertTrue(minecraftArguments > diagnostic);
        assertTrue(!jre.contains("JAVA_TOOL_OPTIONS"));
    }
}
