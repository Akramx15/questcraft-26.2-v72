package pojlib.util;

import android.app.Activity;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import pojlib.util.json.MinecraftInstances;

/**
 * Prepares an explicitly armed, bounded native-memory recording for Quest Lab.
 *
 * <p>This diagnostic is intentionally narrower than a normal JFR profile. It
 * records only aggregate RSS, HotSpot Native Memory Tracking totals, Java heap
 * usage, and direct-buffer totals. It does not enable execution samples,
 * sockets, files, environment variables, system properties, JVM arguments,
 * class loading, or process listings.</p>
 *
 * <p>It is inert unless both the exact Lab package and the fixed enable marker
 * are present. The recording stops after {@value #DURATION_MINUTES} minutes and
 * is capped at {@value #MAX_RECORDING_MIB} MiB. NMT/JFR have measurable
 * overhead, so this must remain a diagnostic and must not be used for FPS
 * acceptance runs.</p>
 */
public final class LabJvmNativeMemoryDiagnostics {
    static final String EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262";
    static final String DIAGNOSTIC_ROOT = ".questcraft-lab";
    static final String ENABLE_MARKER_NAME = "enable-jvm-native-memory-probe";
    static final String OUTPUT_DIRECTORY = ".questcraft-lab/native-memory";
    static final String CONFIG_FILE_NAME = "quest-native-memory.jfc";
    static final String RECORDING_FILE_NAME = "quest-native-memory.jfr";
    static final int DURATION_MINUTES = 15;
    static final int MAX_RECORDING_MIB = 16;
    private static final int MINIMUM_JAVA = 25;
    private static final String NMT_PREFIX = "-XX:NativeMemoryTracking=";
    private static final String JFR_PREFIX = "-XX:StartFlightRecording=";

    private static final String CONFIGURATION =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<configuration version=\"2.0\" label=\"Quest Lab Native Memory\" " +
                    "description=\"Bounded aggregate memory diagnostic\" " +
                    "provider=\"QuestCraft Lab\">\n" +
            "  <event name=\"jdk.ResidentSetSize\">\n" +
            "    <setting name=\"enabled\">true</setting>\n" +
            "    <setting name=\"period\">5 s</setting>\n" +
            "  </event>\n" +
            "  <event name=\"jdk.NativeMemoryUsage\">\n" +
            "    <setting name=\"enabled\">true</setting>\n" +
            "    <setting name=\"period\">5 s</setting>\n" +
            "  </event>\n" +
            "  <event name=\"jdk.NativeMemoryUsageTotal\">\n" +
            "    <setting name=\"enabled\">true</setting>\n" +
            "    <setting name=\"period\">5 s</setting>\n" +
            "  </event>\n" +
            "  <event name=\"jdk.GCHeapMemoryUsage\">\n" +
            "    <setting name=\"enabled\">true</setting>\n" +
            "    <setting name=\"period\">5 s</setting>\n" +
            "  </event>\n" +
            "  <event name=\"jdk.DirectBufferStatistics\">\n" +
            "    <setting name=\"enabled\">true</setting>\n" +
            "    <setting name=\"period\">5 s</setting>\n" +
            "  </event>\n" +
            "</configuration>\n";

    private LabJvmNativeMemoryDiagnostics() {
    }

    /** Adds the two JVM options only when the exact Lab probe is armed. */
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
            List<String> arguments = prepareArguments(
                    activity.getPackageName(), instance.gameDir, javaMajor, userArgs);
            if(arguments.isEmpty()) {
                return;
            }
            userArgs.addAll(arguments);
            Logger.getInstance().appendToLog(
                    "Lab native-memory diagnostic enabled (aggregate-only JFR, " +
                            DURATION_MINUTES + "m / " + MAX_RECORDING_MIB + "MiB cap)");
        } catch(IOException | RuntimeException ignored) {
            // Never include an exception or path in the launcher log.
            Logger.getInstance().appendToLog(
                    "Lab native-memory diagnostic unavailable; continuing without it");
        }
    }

    /** Package-private pure-ish boundary for Host safety tests. */
    static List<String> prepareArguments(
            String packageName,
            String gameDir,
            int javaMajor,
            List<String> existingArguments) throws IOException {
        // The Stable/lookalike package exits before path parsing or filesystem I/O.
        if(!EXPECTED_PACKAGE.equals(packageName) ||
                javaMajor < MINIMUM_JAVA || gameDir == null ||
                existingArguments == null || hasConflictingArgument(existingArguments)) {
            return Collections.emptyList();
        }

        Path gameDirectory = Paths.get(gameDir).toAbsolutePath().normalize();
        if(!Files.isDirectory(gameDirectory, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(gameDirectory)) {
            return Collections.emptyList();
        }

        Path diagnosticRoot = gameDirectory.resolve(DIAGNOSTIC_ROOT).normalize();
        Path enableMarker = diagnosticRoot.resolve(ENABLE_MARKER_NAME).normalize();
        if(!diagnosticRoot.startsWith(gameDirectory) ||
                !enableMarker.startsWith(diagnosticRoot) ||
                Files.isSymbolicLink(diagnosticRoot) ||
                Files.isSymbolicLink(enableMarker) ||
                !Files.isRegularFile(enableMarker, LinkOption.NOFOLLOW_LINKS)) {
            return Collections.emptyList();
        }

        Path outputDirectory = gameDirectory.resolve(OUTPUT_DIRECTORY).normalize();
        if(!outputDirectory.startsWith(diagnosticRoot) ||
                Files.isSymbolicLink(outputDirectory)) {
            return Collections.emptyList();
        }
        Files.createDirectories(outputDirectory);
        if(Files.isSymbolicLink(outputDirectory)) {
            return Collections.emptyList();
        }

        Path realGameDirectory = gameDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realOutputDirectory = outputDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realEnableMarker = enableMarker.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if(!realOutputDirectory.startsWith(realGameDirectory) ||
                !realEnableMarker.startsWith(realGameDirectory)) {
            return Collections.emptyList();
        }

        Path configuration = realOutputDirectory.resolve(CONFIG_FILE_NAME);
        Path recording = realOutputDirectory.resolve(RECORDING_FILE_NAME);
        if(Files.isSymbolicLink(configuration) || Files.isSymbolicLink(recording) ||
                (Files.exists(configuration, LinkOption.NOFOLLOW_LINKS) &&
                        !Files.isRegularFile(configuration, LinkOption.NOFOLLOW_LINKS)) ||
                (Files.exists(recording, LinkOption.NOFOLLOW_LINKS) &&
                        !Files.isRegularFile(recording, LinkOption.NOFOLLOW_LINKS)) ||
                !isSafeOptionPath(configuration) || !isSafeOptionPath(recording)) {
            return Collections.emptyList();
        }

        Files.write(configuration, CONFIGURATION.getBytes(StandardCharsets.UTF_8),
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE);
        // A fixed filename prevents recordings from accumulating across cold starts.
        Files.deleteIfExists(recording);

        List<String> arguments = new ArrayList<>(2);
        arguments.add(NMT_PREFIX + "summary");
        arguments.add(JFR_PREFIX +
                "name=QuestNativeMemory" +
                ",settings=" + configuration +
                ",filename=" + recording +
                ",duration=" + DURATION_MINUTES + "m" +
                ",maxsize=" + MAX_RECORDING_MIB + "m" +
                ",disk=true,dumponexit=true");
        return arguments;
    }

    static boolean hasConflictingArgument(List<String> arguments) {
        for(String argument : arguments) {
            if(argument != null &&
                    (argument.startsWith(NMT_PREFIX) || argument.startsWith(JFR_PREFIX))) {
                return true;
            }
        }
        return false;
    }

    static String configurationText() {
        return CONFIGURATION;
    }

    private static boolean isSafeOptionPath(Path path) {
        String value = path.toString();
        return value.indexOf('\n') < 0 && value.indexOf('\r') < 0 &&
                value.indexOf(',') < 0 && value.indexOf('=') < 0 &&
                value.indexOf('%') < 0;
    }
}
