package pojlib.util;

import android.app.Activity;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

import pojlib.util.json.MinecraftInstances;

/**
 * Adds a bounded, low-overhead HotSpot heap log to the isolated Quest Lab.
 *
 * <p>The {@code gc+heap=debug} selector records heap summaries around garbage
 * collections. In a G1 summary, {@code total} is the currently committed Java
 * heap and {@code used} is its occupancy. The post-GC {@code used} value is the
 * useful retention trend: if it stays flat while Android PSS/RSS grows, the
 * growth is outside the Java heap (for example native, graphics, or mapped
 * memory). If post-GC used and committed total rise together, investigate Java
 * allocation/retention instead.</p>
 *
 * <p>The log deliberately enables no command-line, class-loading, account,
 * world, or network tags. HotSpot rotates one fixed file inside the selected
 * Lab game directory, retaining at most {@value #LOG_FILE_COUNT} files of
 * {@value #LOG_FILE_SIZE_MIB} MiB each.</p>
 */
public final class LabJvmHeapDiagnostics {
    static final String EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262";
    static final String DIAGNOSTIC_DIRECTORY = ".questcraft-lab/jvm-heap";
    static final String LOG_FILE_NAME = "gc-heap.log";
    static final int LOG_FILE_COUNT = 3;
    static final int LOG_FILE_SIZE_MIB = 2;
    private static final int MINIMUM_UNIFIED_LOGGING_JAVA = 9;
    private static final String XLOG_PREFIX = "-Xlog:gc+heap=debug:file=";

    private LabJvmHeapDiagnostics() {
    }

    /**
     * Adds the diagnostic argument only for the exact Lab package. A failure to
     * prepare diagnostics must never prevent Minecraft from starting.
     */
    public static void addIfEligible(
            Activity activity,
            MinecraftInstances.Instance instance,
            int javaMajor,
            List<String> userArgs) {
        if(activity == null ||
                !EXPECTED_PACKAGE.equals(activity.getPackageName()) ||
                instance == null || userArgs == null) {
            return;
        }

        try {
            String argument = prepareArgument(
                    activity.getPackageName(), instance.gameDir, javaMajor);
            if(argument == null || containsDiagnosticArgument(userArgs)) {
                return;
            }
            userArgs.add(argument);
            Logger.getInstance().appendToLog(
                    "Lab JVM heap diagnostic enabled (GC heap summaries, " +
                            LOG_FILE_COUNT + "x" + LOG_FILE_SIZE_MIB + "MiB rotation)");
        } catch(IOException | RuntimeException ignored) {
            // Deliberately omit exception text: it may contain a local path.
            Logger.getInstance().appendToLog(
                    "Lab JVM heap diagnostic unavailable; continuing without it");
        }
    }

    /** Package-private pure boundary used by Host tests. */
    static String prepareArgument(String packageName, String gameDir, int javaMajor)
            throws IOException {
        // Package and Java checks intentionally precede all path parsing and I/O.
        if(!EXPECTED_PACKAGE.equals(packageName) ||
                javaMajor < MINIMUM_UNIFIED_LOGGING_JAVA || gameDir == null) {
            return null;
        }

        Path gameDirectory = Paths.get(gameDir).toAbsolutePath().normalize();
        if(!Files.isDirectory(gameDirectory, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(gameDirectory)) {
            return null;
        }

        Path diagnosticsRoot = gameDirectory.resolve(".questcraft-lab").normalize();
        Path diagnosticsDirectory = gameDirectory.resolve(DIAGNOSTIC_DIRECTORY).normalize();
        if(!diagnosticsRoot.startsWith(gameDirectory) ||
                !diagnosticsDirectory.startsWith(diagnosticsRoot) ||
                Files.isSymbolicLink(diagnosticsRoot) ||
                Files.isSymbolicLink(diagnosticsDirectory)) {
            return null;
        }

        Files.createDirectories(diagnosticsDirectory);
        if(Files.isSymbolicLink(diagnosticsRoot) ||
                Files.isSymbolicLink(diagnosticsDirectory)) {
            return null;
        }

        Path realGameDirectory = gameDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realDiagnosticsDirectory =
                diagnosticsDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if(!realDiagnosticsDirectory.startsWith(realGameDirectory)) {
            return null;
        }

        String logPath = realDiagnosticsDirectory.resolve(LOG_FILE_NAME).toString();
        if(logPath.indexOf('\n') >= 0 || logPath.indexOf('\r') >= 0 ||
                logPath.indexOf('%') >= 0) {
            return null;
        }
        return XLOG_PREFIX + logPath + ":uptime,level,tags:filecount=" +
                LOG_FILE_COUNT + ",filesize=" + LOG_FILE_SIZE_MIB + "M";
    }

    static boolean containsDiagnosticArgument(List<String> arguments) {
        for(String argument : arguments) {
            if(argument != null && argument.startsWith(XLOG_PREFIX)) {
                return true;
            }
        }
        return false;
    }
}
