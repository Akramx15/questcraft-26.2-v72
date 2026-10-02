package pojlib.util;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** Pure validation for an already-installed local Java runtime. */
final class InstalledJavaRuntime {
    private static final String JAVA_MAJOR_MARKER = ".questcraft-java-major";
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

    static final class Validation {
        private final boolean valid;
        private final String reason;

        Validation(boolean valid, String reason) {
            this.valid = valid;
            this.reason = reason;
        }

        boolean isValid() {
            return valid;
        }

        String getReason() {
            return reason;
        }
    }

    private InstalledJavaRuntime() {}

    static int expectedMajor(String versionName) {
        return "26.2".equals(versionName) ? 25 : 22;
    }

    static Validation validate(File runtimeDirectory, int expectedMajor) {
        if(runtimeDirectory == null || !runtimeDirectory.isDirectory()) {
            return invalid("runtime directory is missing");
        }

        File marker = new File(runtimeDirectory, JAVA_MAJOR_MARKER);
        if(!marker.isFile()) {
            return invalid("Java major marker is missing");
        }
        try {
            String installedMajor = new String(
                    Files.readAllBytes(marker.toPath()), StandardCharsets.UTF_8).trim();
            if(!String.valueOf(expectedMajor).equals(installedMajor)) {
                return invalid("expected Java " + expectedMajor + " but found " + installedMajor);
            }
        } catch(IOException error) {
            return invalid("Java major marker cannot be read");
        }

        for(String relativePath : REQUIRED_FILES) {
            File required = new File(runtimeDirectory, relativePath);
            if(!required.isFile() || required.length() <= 0L) {
                return invalid("required runtime file is missing: " + relativePath);
            }
        }
        return new Validation(true, "ok");
    }

    private static Validation invalid(String reason) {
        return new Validation(false, reason);
    }
}
