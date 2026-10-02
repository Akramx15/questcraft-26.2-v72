package pojlib.util;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class LabNativeMemoryMapSamplerTest {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";

    @Rule
    public final TemporaryFolder temporary = new TemporaryFolder();

    @Test
    public void exactLabAndSharedMarkerAreRequiredBeforeOutputIo() throws Exception {
        Path game = temporary.newFolder("game").toPath();
        Path missingStable = temporary.getRoot().toPath().resolve("stable-missing");

        assertNull(LabNativeMemoryMapSampler.prepareOutputDirectory(
                STABLE_PACKAGE, missingStable.toString()));
        assertNull(LabNativeMemoryMapSampler.prepareOutputDirectory(
                LAB_PACKAGE + ".debug", missingStable.toString()));
        assertFalse(Files.exists(missingStable));
        assertNull(LabNativeMemoryMapSampler.prepareOutputDirectory(
                LAB_PACKAGE, game.toString()));

        Path root = game.resolve(LabJvmNativeMemoryDiagnostics.DIAGNOSTIC_ROOT);
        Files.createDirectories(root);
        Files.write(root.resolve(LabJvmNativeMemoryDiagnostics.ENABLE_MARKER_NAME),
                new byte[0]);
        assertNull(LabNativeMemoryMapSampler.prepareOutputDirectory(
                LAB_PACKAGE, game.toString()));
        Files.write(root.resolve(LabNativeMemoryMapSampler.ENABLE_MARKER_NAME),
                new byte[0]);
        Path output = LabNativeMemoryMapSampler.prepareOutputDirectory(
                LAB_PACKAGE, game.toString());
        assertEquals(game.resolve(LabNativeMemoryMapSampler.OUTPUT_DIRECTORY).toRealPath(),
                output);
    }

    @Test
    public void smapsParserEmitsOnlyAggregatesAndGenericCategories() throws Exception {
        String sensitiveWorld = "Super Secret User World";
        String smaps =
                "10000000-10010000 rw-p 00000000 00:00 0 [anon:G1 Reserved Space]\n" +
                metrics(65536, 32768, 30000, 0, 30000, 0, 0, 30000, 1024, 900) +
                "20000000-20010000 rw-p 00000000 00:00 0 /dev/kgsl-3d0\n" +
                metrics(16384, 12000, 11000, 0, 8000, 3000, 1000, 0, 0, 0) +
                "30000000-30010000 r--p 00000000 00:00 0 " +
                        "/storage/emulated/0/Android/data/com.qcxr.qcxr.canary262/files/" +
                        sensitiveWorld + "/region/r.0.0.mca\n" +
                metrics(512, 128, 64, 64, 0, 0, 64, 0, 0, 0) +
                "40000000-40010000 rw-p 00000000 00:00 0\n" +
                metrics(32, 16, 16, 0, 16, 0, 0, 16, 0, 0);

        LabNativeMemoryMapSampler.Snapshot snapshot =
                LabNativeMemoryMapSampler.parse(new StringReader(smaps), 123456L);
        String json = snapshot.toJson();

        assertEquals(4L, snapshot.total.mappings);
        assertEquals(82464L, snapshot.total.sizeKiB);
        assertEquals(44912L, snapshot.total.rssKiB);
        assertEquals(41080L, snapshot.total.pssKiB);
        assertEquals(1L, snapshot.categories.get(
                LabNativeMemoryMapSampler.Category.HOTSPOT_HEAP).mappings);
        assertEquals(11000L, snapshot.categories.get(
                LabNativeMemoryMapSampler.Category.GPU_OR_DMA).pssKiB);
        assertEquals(64L, snapshot.categories.get(
                LabNativeMemoryMapSampler.Category.GAME_CONTENT).pssKiB);
        assertEquals(16L, snapshot.categories.get(
                LabNativeMemoryMapSampler.Category.ANONYMOUS_PRIVATE).pssKiB);
        assertEquals(30000L, snapshot.categorySizeBuckets.get(
                LabNativeMemoryMapSampler.Category.HOTSPOT_HEAP).get(
                LabNativeMemoryMapSampler.SizeBucket.FROM_16_MIB_TO_128_MIB).pssKiB);
        assertEquals(11000L, snapshot.categorySizeBuckets.get(
                LabNativeMemoryMapSampler.Category.GPU_OR_DMA).get(
                LabNativeMemoryMapSampler.SizeBucket.FROM_16_MIB_TO_128_MIB).pssKiB);
        assertEquals(1, snapshot.topAnonymousPrivateMappings.length);
        assertEquals(16L, snapshot.topAnonymousPrivateMappings[0].pssKiB);
        assertEquals("rw-p", snapshot.topAnonymousPrivateMappings[0].permissions);
        assertTrue(json.startsWith("{\"schema\":2,"));
        assertTrue(json.contains("\"elapsedRealtimeMs\":123456"));
        assertTrue(json.contains("\"gpuOrDma\""));
        assertTrue(json.contains("\"16MiBTo128MiB\""));
        assertTrue(json.contains("\"categorySizeBuckets\""));
        assertTrue(json.contains("\"topAnonymousPrivateMappings\""));
        assertTrue(json.contains("\"permissions\":\"rw-p\""));
        assertFalse(json.contains(sensitiveWorld));
        assertFalse(json.contains("storage/emulated"));
        assertFalse(json.contains("10000000"));
        assertFalse(json.contains("kgsl-3d0"));
    }

    @Test
    public void schemaTwoKeepsVersionOneAggregatesAndAddsFieldsAfterThem()
            throws Exception {
        String smaps =
                "10000000-10001000 rw-p 00000000 00:00 0\n" +
                metrics(4, 4, 4, 0, 4, 0, 0, 4, 0, 0);
        String json = LabNativeMemoryMapSampler.parse(
                new StringReader(smaps), 7L).toJson();

        int total = json.indexOf("\"total\"");
        int categories = json.indexOf("\"categories\"");
        int sizeBuckets = json.indexOf("\"sizeBuckets\"");
        int crossTab = json.indexOf("\"categorySizeBuckets\"");
        int topMappings = json.indexOf("\"topAnonymousPrivateMappings\"");

        assertTrue(json.startsWith("{\"schema\":2,\"elapsedRealtimeMs\":7,"));
        assertTrue(total >= 0 && categories > total);
        assertTrue(sizeBuckets > categories);
        assertTrue(crossTab > sizeBuckets);
        assertTrue(topMappings > crossTab);
        assertTrue(json.contains("\"mappings\":1"));
        assertTrue(json.contains("\"anonymousPrivate\""));
        assertTrue(json.contains("\"under64KiB\""));
    }

    @Test
    public void topAnonymousMappingsAreBoundedSortedAndNeverExposeIdentity()
            throws Exception {
        long[] pssValues = { 20, 90, 40, 100, 70, 30, 80, 60, 50, 10 };
        StringBuilder smaps = new StringBuilder();
        for(int index = 0; index < pssValues.length; index++) {
            String address = Integer.toHexString(0x50000000 + index * 0x10000);
            String permissions = index == 2 ? "r--p" : "rw-p";
            smaps.append(address).append('-').append(address).append("ffff ")
                    .append(permissions)
                    .append(" 00000000 00:00 0 [anon:private-secret-")
                    .append(index).append("]\n")
                    .append(metrics(
                            128 + index,
                            pssValues[index] + 7,
                            pssValues[index],
                            0,
                            pssValues[index] - 1,
                            0,
                            0,
                            pssValues[index] - 2,
                            index,
                            0));
        }

        LabNativeMemoryMapSampler.Snapshot snapshot =
                LabNativeMemoryMapSampler.parse(
                        new StringReader(smaps.toString()), 99L);
        String json = snapshot.toJson();
        String repeatedJson = LabNativeMemoryMapSampler.parse(
                new StringReader(smaps.toString()), 99L).toJson();

        assertEquals(8, snapshot.topAnonymousPrivateMappings.length);
        assertEquals(json, repeatedJson);
        long[] expectedPss = { 100, 90, 80, 70, 60, 50, 40, 30 };
        for(int index = 0; index < expectedPss.length; index++) {
            assertEquals(expectedPss[index],
                    snapshot.topAnonymousPrivateMappings[index].pssKiB);
        }
        assertTrue(json.contains("\"permissions\":\"r--p\""));
        assertFalse(json.contains("private-secret"));
        assertFalse(json.contains("50000000"));
        assertFalse(json.contains("00:00"));
        assertFalse(json.contains("offset"));
        assertFalse(json.contains("inode"));
        assertFalse(json.contains("device"));
        assertFalse(json.contains("path"));
    }

    @Test
    public void perSampleTopMappingsDoNotRetainPreviousSampleState()
            throws Exception {
        String firstSmaps =
                "10000000-10001000 rw-p 00000000 00:00 0 [anon:first]\n" +
                metrics(4, 4, 4, 0, 4, 0, 0, 4, 0, 0);
        String secondSmaps =
                "20000000-20001000 rw-s 00000000 00:00 0 [anon:second]\n" +
                metrics(4, 4, 4, 0, 0, 0, 4, 4, 0, 0);

        LabNativeMemoryMapSampler.Snapshot first =
                LabNativeMemoryMapSampler.parse(new StringReader(firstSmaps), 1L);
        LabNativeMemoryMapSampler.Snapshot second =
                LabNativeMemoryMapSampler.parse(new StringReader(secondSmaps), 2L);

        assertNotSame(first.topAnonymousPrivateMappings,
                second.topAnonymousPrivateMappings);
        assertEquals(1, first.topAnonymousPrivateMappings.length);
        assertEquals(0, second.topAnonymousPrivateMappings.length);
        assertFalse(second.toJson().contains("first"));
    }

    @Test
    public void boundedWriterRotatesFixedFilesWithoutUnboundedNames() throws Exception {
        Path output = temporary.newFolder("rotate").toPath();

        LabNativeMemoryMapSampler.appendBounded(output, "{\"sample\":1}", 32L, 3);
        LabNativeMemoryMapSampler.appendBounded(output,
                "{\"sample\":222222222222222}", 32L, 3);
        LabNativeMemoryMapSampler.appendBounded(output,
                "{\"sample\":333333333333333}", 32L, 3);
        LabNativeMemoryMapSampler.appendBounded(output,
                "{\"sample\":444444444444444}", 32L, 3);

        assertTrue(Files.isRegularFile(output.resolve("smaps-aggregates.jsonl")));
        assertTrue(Files.isRegularFile(output.resolve("smaps-aggregates.jsonl.1")));
        assertTrue(Files.isRegularFile(output.resolve("smaps-aggregates.jsonl.2")));
        assertEquals(3L, Files.list(output).count());
        assertTrue(new String(Files.readAllBytes(
                output.resolve("smaps-aggregates.jsonl")),
                StandardCharsets.UTF_8).contains("444444444444444"));
    }

    private static String metrics(long size, long rss, long pss,
            long privateClean, long privateDirty, long sharedClean,
            long sharedDirty, long anonymous, long swap, long swapPss) {
        return "Size: " + size + " kB\n" +
                "Rss: " + rss + " kB\n" +
                "Pss: " + pss + " kB\n" +
                "Private_Clean: " + privateClean + " kB\n" +
                "Private_Dirty: " + privateDirty + " kB\n" +
                "Shared_Clean: " + sharedClean + " kB\n" +
                "Shared_Dirty: " + sharedDirty + " kB\n" +
                "Anonymous: " + anonymous + " kB\n" +
                "Swap: " + swap + " kB\n" +
                "SwapPss: " + swapPss + " kB\n";
    }
}
