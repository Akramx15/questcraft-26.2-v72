package pojlib.util;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import javax.xml.parsers.DocumentBuilderFactory;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class LabJvmNativeMemoryDiagnosticsTest {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";

    @Rule
    public final TemporaryFolder temporary = new TemporaryFolder();

    @Test
    public void diagnosticIsInertUntilExactLabMarkerExists() throws Exception {
        Path gameDirectory = temporary.newFolder("26.2").toPath();
        Path stableMissing = temporary.getRoot().toPath().resolve("stable-missing");

        assertTrue(LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE, gameDirectory.toString(), 25, new ArrayList<>()).isEmpty());
        assertTrue(LabJvmNativeMemoryDiagnostics.prepareArguments(
                STABLE_PACKAGE, stableMissing.toString(), 25, new ArrayList<>()).isEmpty());
        assertTrue(LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE + ".debug", stableMissing.toString(), 25,
                new ArrayList<>()).isEmpty());
        assertFalse(Files.exists(stableMissing));
        assertFalse(Files.exists(gameDirectory.resolve(
                LabJvmNativeMemoryDiagnostics.OUTPUT_DIRECTORY)));

        Path root = gameDirectory.resolve(LabJvmNativeMemoryDiagnostics.DIAGNOSTIC_ROOT);
        Files.createDirectories(root);
        Files.write(root.resolve(LabNativeMemoryMapSampler.ENABLE_MARKER_NAME), new byte[0]);
        assertTrue(LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE, gameDirectory.toString(), 25, new ArrayList<>()).isEmpty());
    }

    @Test
    public void markerProducesBoundedAggregateOnlyRecording() throws Exception {
        Path gameDirectory = temporary.newFolder("armed").toPath();
        Path root = gameDirectory.resolve(LabJvmNativeMemoryDiagnostics.DIAGNOSTIC_ROOT);
        Files.createDirectories(root);
        Files.write(root.resolve(LabJvmNativeMemoryDiagnostics.ENABLE_MARKER_NAME),
                new byte[0]);

        List<String> arguments = LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE, gameDirectory.toString(), 25, new ArrayList<>());

        assertEquals(2, arguments.size());
        assertEquals("-XX:NativeMemoryTracking=summary", arguments.get(0));
        String flightRecording = arguments.get(1);
        assertTrue(flightRecording.startsWith("-XX:StartFlightRecording="));
        assertTrue(flightRecording.contains("duration=15m"));
        assertTrue(flightRecording.contains("maxsize=16m"));
        assertTrue(flightRecording.contains("disk=true,dumponexit=true"));
        assertFalse(flightRecording.contains(STABLE_PACKAGE));

        Path output = gameDirectory.resolve(
                LabJvmNativeMemoryDiagnostics.OUTPUT_DIRECTORY);
        Path configuration = output.resolve(
                LabJvmNativeMemoryDiagnostics.CONFIG_FILE_NAME);
        assertTrue(Files.isRegularFile(configuration));
        assertEquals(LabJvmNativeMemoryDiagnostics.configurationText(),
                new String(Files.readAllBytes(configuration), StandardCharsets.UTF_8));

        NodeList events = DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(configuration.toFile()).getElementsByTagName("event");
        assertEquals(5, events.getLength());
        Set<String> configuredEvents = new HashSet<>();
        for(int index = 0; index < events.getLength(); index++) {
            Element event = (Element) events.item(index);
            configuredEvents.add(event.getAttribute("name"));
            assertEquals("true", settingValue(event, "enabled"));
            assertEquals("5 s", settingValue(event, "period"));
        }
        assertTrue(configuredEvents.contains("jdk.ResidentSetSize"));
        assertTrue(configuredEvents.contains("jdk.NativeMemoryUsage"));
        assertTrue(configuredEvents.contains("jdk.NativeMemoryUsageTotal"));
        assertTrue(configuredEvents.contains("jdk.GCHeapMemoryUsage"));
        assertTrue(configuredEvents.contains("jdk.DirectBufferStatistics"));
        for(String forbidden : new String[] {
                "jdk.JVMInformation", "jdk.InitialEnvironmentVariable",
                "jdk.InitialSystemProperty", "jdk.SystemProcess",
                "jdk.ExecutionSample", "jdk.FileRead", "jdk.FileWrite",
                "jdk.SocketRead", "jdk.SocketWrite"}) {
            assertFalse("forbidden event was configured: " + forbidden,
                    configuredEvents.contains(forbidden));
        }
    }

    @Test
    public void staleRecordingIsReplacedButMarkerPersists() throws Exception {
        Path gameDirectory = temporary.newFolder("replace").toPath();
        Path root = gameDirectory.resolve(LabJvmNativeMemoryDiagnostics.DIAGNOSTIC_ROOT);
        Path output = gameDirectory.resolve(
                LabJvmNativeMemoryDiagnostics.OUTPUT_DIRECTORY);
        Files.createDirectories(output);
        Path marker = root.resolve(LabJvmNativeMemoryDiagnostics.ENABLE_MARKER_NAME);
        Path recording = output.resolve(
                LabJvmNativeMemoryDiagnostics.RECORDING_FILE_NAME);
        Files.write(marker, new byte[0]);
        Files.write(recording, new byte[] {1, 2, 3});

        List<String> arguments = LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE, gameDirectory.toString(), 25, new ArrayList<>());

        assertEquals(2, arguments.size());
        assertFalse(Files.exists(recording));
        assertTrue(Files.isRegularFile(marker));
    }

    @Test
    public void unsupportedJavaConflictsAndUnsafePathsFailClosed() throws Exception {
        Path gameDirectory = temporary.newFolder("conflicts").toPath();
        Path root = gameDirectory.resolve(LabJvmNativeMemoryDiagnostics.DIAGNOSTIC_ROOT);
        Files.createDirectories(root);
        Files.write(root.resolve(LabJvmNativeMemoryDiagnostics.ENABLE_MARKER_NAME),
                new byte[0]);

        assertTrue(LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE, gameDirectory.toString(), 24, new ArrayList<>()).isEmpty());

        List<String> nmt = new ArrayList<>();
        nmt.add("-XX:NativeMemoryTracking=detail");
        assertTrue(LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE, gameDirectory.toString(), 25, nmt).isEmpty());

        List<String> jfr = new ArrayList<>();
        jfr.add("-XX:StartFlightRecording=settings=default");
        assertTrue(LabJvmNativeMemoryDiagnostics.prepareArguments(
                LAB_PACKAGE, gameDirectory.toString(), 25, jfr).isEmpty());
    }

    @Test
    public void knownSensitiveEventsAreAbsentFromConfigurationText() {
        String configuration = LabJvmNativeMemoryDiagnostics.configurationText();
        for(String forbidden : new String[] {
                "JVMInformation", "InitialEnvironmentVariable", "InitialSystemProperty",
                "Environment", "OSInformation", "SystemProcess", "ProcessStart",
                "ExecutionSample", "NativeMethodSample", "FileRead", "FileWrite",
                "SocketRead", "SocketWrite", "NetworkUtilization",
                "ObjectAllocationSample", "OldObjectSample"}) {
            assertFalse("forbidden selector is present: " + forbidden,
                    configuration.contains(forbidden));
        }
    }

    private static String settingValue(Element event, String name) {
        NodeList children = event.getChildNodes();
        for(int index = 0; index < children.getLength(); index++) {
            Node child = children.item(index);
            if(child instanceof Element) {
                Element setting = (Element) child;
                if("setting".equals(setting.getTagName()) &&
                        name.equals(setting.getAttribute("name"))) {
                    return setting.getTextContent();
                }
            }
        }
        return null;
    }
}
