package pojlib.util;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class LabJvmHeapDiagnosticsTest {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";

    @Rule
    public final TemporaryFolder temporary = new TemporaryFolder();

    @Test
    public void exactLabPackageGetsBoundedGcHeapLogInsideGameDirectory() throws Exception {
        Path gameDirectory = temporary.newFolder("26.2").toPath();

        String argument = LabJvmHeapDiagnostics.prepareArgument(
                LAB_PACKAGE, gameDirectory.toString(), 25);

        Path diagnostics = gameDirectory.resolve(".questcraft-lab/jvm-heap");
        assertTrue(Files.isDirectory(diagnostics));
        assertTrue(argument.startsWith("-Xlog:gc+heap=debug:file="));
        assertTrue(argument.contains(diagnostics.toRealPath().toString()));
        assertTrue(argument.endsWith(
                ":uptime,level,tags:filecount=3,filesize=2M"));
        assertFalse(argument.contains("class+load"));
        assertFalse(argument.contains("arguments"));
        assertFalse(argument.contains("network"));
    }

    @Test
    public void stableAndLookalikePackagesDoNoPathParsingOrIo() throws Exception {
        Path missing = temporary.getRoot().toPath().resolve("missing-profile");

        assertNull(LabJvmHeapDiagnostics.prepareArgument(
                STABLE_PACKAGE, missing.toString(), 25));
        assertNull(LabJvmHeapDiagnostics.prepareArgument(
                LAB_PACKAGE + ".debug", missing.toString(), 25));
        assertFalse(Files.exists(missing));
    }

    @Test
    public void unsupportedJavaAndInvalidGameDirectoryFailClosed() throws Exception {
        Path gameDirectory = temporary.newFolder("unsupported").toPath();
        Path missing = gameDirectory.resolve("missing");

        assertNull(LabJvmHeapDiagnostics.prepareArgument(
                LAB_PACKAGE, gameDirectory.toString(), 8));
        assertNull(LabJvmHeapDiagnostics.prepareArgument(
                LAB_PACKAGE, null, 25));
        assertNull(LabJvmHeapDiagnostics.prepareArgument(
                LAB_PACKAGE, missing.toString(), 25));
        assertFalse(Files.exists(missing));
    }

    @Test
    public void diagnosticArgumentIsAddedAtMostOnce() throws Exception {
        Path gameDirectory = temporary.newFolder("dedupe").toPath();
        String diagnostic = LabJvmHeapDiagnostics.prepareArgument(
                LAB_PACKAGE, gameDirectory.toString(), 25);
        List<String> arguments = new ArrayList<>();
        arguments.add("-Xms512M");
        arguments.add(diagnostic);

        assertTrue(LabJvmHeapDiagnostics.containsDiagnosticArgument(arguments));
        assertEquals(2, arguments.size());
    }
}
