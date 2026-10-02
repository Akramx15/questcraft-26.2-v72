package pojlib.util;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class InstalledJavaRuntimeTest {
    private static final String[] REQUIRED_FILES = {
            "release",
            "bin/java",
            "conf/security/java.security",
            "lib/modules",
            "lib/libjli.so",
            "lib/server/libjvm.so",
            "lib/libverify.so",
            "lib/libjava.so",
            "lib/libnet.so",
            "lib/libnio.so",
            "lib/libawt.so",
            "lib/libawt_headless.so",
            "lib/libawt_xawt.so",
            "lib/libfreetype.so",
            "lib/libfontmanager.so"
    };

    @Rule public TemporaryFolder temporary = new TemporaryFolder();

    @Test
    public void acceptsCompletePinnedJava25Runtime() throws Exception {
        File runtime = completeRuntime("25");
        assertTrue(InstalledJavaRuntime.validate(runtime, 25).isValid());
    }

    @Test
    public void rejectsWrongJavaMajor() throws Exception {
        File runtime = completeRuntime("22");
        InstalledJavaRuntime.Validation result = InstalledJavaRuntime.validate(runtime, 25);
        assertFalse(result.isValid());
        assertTrue(result.getReason().contains("expected Java 25"));
    }

    @Test
    public void rejectsMissingRequiredNativeBeforeDlopen() throws Exception {
        File runtime = completeRuntime("25");
        assertTrue(new File(runtime, "lib/server/libjvm.so").delete());
        InstalledJavaRuntime.Validation result = InstalledJavaRuntime.validate(runtime, 25);
        assertFalse(result.isValid());
        assertTrue(result.getReason().contains("lib/server/libjvm.so"));
    }

    private File completeRuntime(String marker) throws Exception {
        File runtime = temporary.newFolder("runtime");
        Files.write(new File(runtime, ".questcraft-java-major").toPath(),
                marker.getBytes(StandardCharsets.UTF_8));
        for(String relative : REQUIRED_FILES) {
            File file = new File(runtime, relative);
            assertTrue(file.getParentFile().isDirectory() || file.getParentFile().mkdirs());
            Files.write(file.toPath(), new byte[]{1});
        }
        return runtime;
    }
}
