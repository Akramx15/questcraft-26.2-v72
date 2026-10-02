package pojlib.util;

import android.app.Activity;
import android.os.SystemClock;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.Reader;
import java.nio.ByteBuffer;
import java.nio.channels.SeekableByteChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.EnumMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import pojlib.util.json.MinecraftInstances;

/**
 * Reads {@code /proc/self/smaps} from inside the Lab process and persists only
 * aggregate memory categories and size buckets.
 *
 * <p>Raw map addresses and names are used only while classifying one sample;
 * they are never written or logged. The fixed JSONL output rotates at
 * {@value #MAX_FILE_MIB} MiB and retains at most {@value #FILE_COUNT} files.
 * Sampling is explicitly armed by its own fixed marker and is never available
 * to Stable. The independent JFR/NMT marker is not required, so this
 * lower-overhead probe can run alone.</p>
 */
public final class LabNativeMemoryMapSampler {
    static final String EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262";
    static final String ENABLE_MARKER_NAME = "enable-memory-map-probe";
    static final String OUTPUT_DIRECTORY = ".questcraft-lab/native-memory-maps";
    static final String OUTPUT_FILE_NAME = "smaps-aggregates.jsonl";
    static final int SAMPLE_INTERVAL_SECONDS = 60;
    static final int MAX_FILE_MIB = 1;
    static final int FILE_COUNT = 3;
    static final int TOP_ANONYMOUS_MAPPING_COUNT = 8;
    private static final Path SELF_SMAPS = Paths.get("/proc/self/smaps");
    private static final Pattern HEADER = Pattern.compile(
            "^[0-9a-fA-F]+-[0-9a-fA-F]+\\s+([rwxps-]{4})\\s+\\S+\\s+\\S+\\s+\\S+\\s*(.*)$");
    private static final Pattern KIB_VALUE = Pattern.compile("^([A-Za-z_]+):\\s+(\\d+)\\s+kB$");

    private LabNativeMemoryMapSampler() {
    }

    /** Starts a daemon sampler or returns an inert session when not armed. */
    public static Session startIfEligible(
            Activity activity, MinecraftInstances.Instance instance) {
        if(activity == null ||
                !EXPECTED_PACKAGE.equals(activity.getPackageName()) ||
                instance == null) {
            return Session.NO_OP;
        }

        try {
            Path outputDirectory = prepareOutputDirectory(
                    activity.getPackageName(), instance.gameDir);
            if(outputDirectory == null) {
                return Session.NO_OP;
            }
            Session session = new Session(outputDirectory);
            session.start();
            Logger.getInstance().appendToLog(
                    "Lab native memory-map sampler enabled (aggregate-only, " +
                            SAMPLE_INTERVAL_SECONDS + "s / " + FILE_COUNT + "x" +
                            MAX_FILE_MIB + "MiB rotation)");
            return session;
        } catch(IOException | RuntimeException ignored) {
            // Deliberately omit exception text because it may contain a path.
            Logger.getInstance().appendToLog(
                    "Lab native memory-map sampler unavailable; continuing without it");
            return Session.NO_OP;
        }
    }

    /** Package-private preparation boundary used by Host tests. */
    static Path prepareOutputDirectory(String packageName, String gameDir)
            throws IOException {
        // Exact package check precedes path parsing and filesystem I/O.
        if(!EXPECTED_PACKAGE.equals(packageName) || gameDir == null) {
            return null;
        }
        Path gameDirectory = Paths.get(gameDir).toAbsolutePath().normalize();
        if(!Files.isDirectory(gameDirectory, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(gameDirectory)) {
            return null;
        }

        Path root = gameDirectory.resolve(
                LabJvmNativeMemoryDiagnostics.DIAGNOSTIC_ROOT).normalize();
        Path marker = root.resolve(ENABLE_MARKER_NAME).normalize();
        if(!root.startsWith(gameDirectory) || !marker.startsWith(root) ||
                Files.isSymbolicLink(root) || Files.isSymbolicLink(marker) ||
                !Files.isRegularFile(marker, LinkOption.NOFOLLOW_LINKS)) {
            return null;
        }

        Path outputDirectory = gameDirectory.resolve(OUTPUT_DIRECTORY).normalize();
        if(!outputDirectory.startsWith(root) || Files.isSymbolicLink(outputDirectory)) {
            return null;
        }
        Files.createDirectories(outputDirectory);
        if(Files.isSymbolicLink(outputDirectory)) {
            return null;
        }

        Path realGame = gameDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realMarker = marker.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realOutput = outputDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if(!realMarker.startsWith(realGame) || !realOutput.startsWith(realGame)) {
            return null;
        }
        for(int index = 0; index < FILE_COUNT; index++) {
            Path candidate = outputPath(realOutput, index);
            if(Files.isSymbolicLink(candidate) ||
                    (Files.exists(candidate, LinkOption.NOFOLLOW_LINKS) &&
                            !Files.isRegularFile(candidate, LinkOption.NOFOLLOW_LINKS))) {
                return null;
            }
        }
        return realOutput;
    }

    /** Parses one smaps stream without retaining or exposing map names. */
    static Snapshot parse(Reader input, long elapsedRealtimeMs) throws IOException {
        EnumMap<Category, Metrics> categories = new EnumMap<>(Category.class);
        EnumMap<SizeBucket, Metrics> buckets = new EnumMap<>(SizeBucket.class);
        EnumMap<Category, EnumMap<SizeBucket, Metrics>> categoryBuckets =
                new EnumMap<>(Category.class);
        AnonymousMappingSummary[] topAnonymousMappings =
                new AnonymousMappingSummary[TOP_ANONYMOUS_MAPPING_COUNT];
        int topAnonymousMappingCount = 0;
        Metrics total = new Metrics();
        Mapping current = null;

        try(BufferedReader reader = input instanceof BufferedReader
                ? (BufferedReader) input : new BufferedReader(input)) {
            String line;
            while((line = reader.readLine()) != null) {
                Matcher header = HEADER.matcher(line);
                if(header.matches()) {
                    if(current != null) {
                        topAnonymousMappingCount = addMapping(
                                current, total, categories, buckets,
                                categoryBuckets, topAnonymousMappings,
                                topAnonymousMappingCount);
                    }
                    current = new Mapping(header.group(1), header.group(2));
                    continue;
                }
                if(current == null) {
                    continue;
                }
                Matcher value = KIB_VALUE.matcher(line);
                if(value.matches()) {
                    current.set(value.group(1), parsePositiveLong(value.group(2)));
                }
            }
        }
        if(current != null) {
            topAnonymousMappingCount = addMapping(
                    current, total, categories, buckets,
                    categoryBuckets, topAnonymousMappings,
                    topAnonymousMappingCount);
        }
        return new Snapshot(
                elapsedRealtimeMs, total, categories, buckets, categoryBuckets,
                copyTopAnonymousMappings(topAnonymousMappings, topAnonymousMappingCount));
    }

    private static long parsePositiveLong(String value) {
        try {
            long parsed = Long.parseLong(value);
            return Math.max(0L, parsed);
        } catch(NumberFormatException ignored) {
            return 0L;
        }
    }

    private static int addMapping(
            Mapping mapping,
            Metrics total,
            EnumMap<Category, Metrics> categories,
            EnumMap<SizeBucket, Metrics> buckets,
            EnumMap<Category, EnumMap<SizeBucket, Metrics>> categoryBuckets,
            AnonymousMappingSummary[] topAnonymousMappings,
            int topAnonymousMappingCount) {
        Metrics category = categories.get(mapping.category);
        if(category == null) {
            category = new Metrics();
            categories.put(mapping.category, category);
        }
        SizeBucket sizeBucket = SizeBucket.fromKiB(mapping.metrics.sizeKiB);
        Metrics bucket = buckets.get(sizeBucket);
        if(bucket == null) {
            bucket = new Metrics();
            buckets.put(sizeBucket, bucket);
        }
        EnumMap<SizeBucket, Metrics> bucketsForCategory =
                categoryBuckets.get(mapping.category);
        if(bucketsForCategory == null) {
            bucketsForCategory = new EnumMap<>(SizeBucket.class);
            categoryBuckets.put(mapping.category, bucketsForCategory);
        }
        Metrics categoryBucket = bucketsForCategory.get(sizeBucket);
        if(categoryBucket == null) {
            categoryBucket = new Metrics();
            bucketsForCategory.put(sizeBucket, categoryBucket);
        }
        total.add(mapping.metrics);
        category.add(mapping.metrics);
        bucket.add(mapping.metrics);
        categoryBucket.add(mapping.metrics);
        if(mapping.category == Category.ANONYMOUS_PRIVATE) {
            return insertTopAnonymousMapping(
                    mapping, topAnonymousMappings, topAnonymousMappingCount);
        }
        return topAnonymousMappingCount;
    }

    private static int insertTopAnonymousMapping(
            Mapping mapping,
            AnonymousMappingSummary[] topMappings,
            int count) {
        int insertion = 0;
        while(insertion < count &&
                !comesBefore(mapping, topMappings[insertion])) {
            insertion++;
        }
        if(insertion >= topMappings.length) {
            return count;
        }

        int newCount = Math.min(count + 1, topMappings.length);
        for(int index = newCount - 1; index > insertion; index--) {
            topMappings[index] = topMappings[index - 1];
        }
        topMappings[insertion] = new AnonymousMappingSummary(mapping);
        return newCount;
    }

    private static boolean comesBefore(
            Mapping candidate, AnonymousMappingSummary existing) {
        Metrics metrics = candidate.metrics;
        int comparison = Long.compare(metrics.pssKiB, existing.pssKiB);
        if(comparison != 0) return comparison > 0;
        comparison = Long.compare(metrics.rssKiB, existing.rssKiB);
        if(comparison != 0) return comparison > 0;
        comparison = Long.compare(metrics.sizeKiB, existing.sizeKiB);
        if(comparison != 0) return comparison > 0;
        comparison = Long.compare(metrics.privateDirtyKiB, existing.privateDirtyKiB);
        if(comparison != 0) return comparison > 0;
        comparison = Long.compare(metrics.anonymousKiB, existing.anonymousKiB);
        if(comparison != 0) return comparison > 0;
        comparison = Long.compare(metrics.swapKiB, existing.swapKiB);
        if(comparison != 0) return comparison > 0;
        return candidate.permissions.compareTo(existing.permissions) < 0;
    }

    private static AnonymousMappingSummary[] copyTopAnonymousMappings(
            AnonymousMappingSummary[] source, int count) {
        AnonymousMappingSummary[] result = new AnonymousMappingSummary[count];
        System.arraycopy(source, 0, result, 0, count);
        return result;
    }

    static void appendBounded(Path directory, String jsonLine, long maxBytes, int fileCount)
            throws IOException {
        if(directory == null || jsonLine == null || maxBytes < 1L || fileCount < 1) {
            throw new IllegalArgumentException("invalid bounded-output arguments");
        }
        byte[] bytes = (jsonLine + '\n').getBytes(StandardCharsets.UTF_8);
        if(bytes.length > maxBytes) {
            throw new IOException("aggregate sample exceeds output bound");
        }

        Path current = outputPath(directory, 0);
        if(Files.isSymbolicLink(current) ||
                (Files.exists(current, LinkOption.NOFOLLOW_LINKS) &&
                        !Files.isRegularFile(current, LinkOption.NOFOLLOW_LINKS))) {
            throw new IOException("unsafe aggregate output");
        }
        long length = Files.exists(current, LinkOption.NOFOLLOW_LINKS)
                ? Files.size(current) : 0L;
        if(length + bytes.length > maxBytes) {
            rotate(directory, fileCount);
        }

        Set<OpenOption> options = new HashSet<>();
        options.add(StandardOpenOption.CREATE);
        options.add(StandardOpenOption.WRITE);
        options.add(StandardOpenOption.APPEND);
        options.add(LinkOption.NOFOLLOW_LINKS);
        try(SeekableByteChannel channel = Files.newByteChannel(current, options)) {
            ByteBuffer buffer = ByteBuffer.wrap(bytes);
            while(buffer.hasRemaining()) {
                channel.write(buffer);
            }
        }
    }

    private static void rotate(Path directory, int fileCount) throws IOException {
        for(int index = fileCount - 1; index >= 1; index--) {
            Path source = outputPath(directory, index - 1);
            Path destination = outputPath(directory, index);
            if(Files.isSymbolicLink(source) || Files.isSymbolicLink(destination)) {
                throw new IOException("unsafe aggregate rotation");
            }
            if(index == fileCount - 1) {
                Files.deleteIfExists(destination);
            }
            if(Files.exists(source, LinkOption.NOFOLLOW_LINKS)) {
                moveReplacing(source, destination);
            }
        }
    }

    private static void moveReplacing(Path source, Path destination) throws IOException {
        try {
            Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
        } catch(IOException atomicFailure) {
            Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static Path outputPath(Path directory, int index) {
        return directory.resolve(index == 0
                ? OUTPUT_FILE_NAME : OUTPUT_FILE_NAME + "." + index);
    }

    enum Category {
        HOTSPOT_HEAP("hotspotHeap"),
        HOTSPOT_RUNTIME("hotspotRuntime"),
        ANDROID_RUNTIME("androidRuntime"),
        NATIVE_HEAP("nativeHeap"),
        GPU_OR_DMA("gpuOrDma"),
        THREAD_STACK("threadStack"),
        JIT_OR_CODE("jitOrCode"),
        SHARED_MEMORY("sharedMemory"),
        APP_BINARY("appBinary"),
        GAME_CONTENT("gameContent"),
        SYSTEM_BINARY("systemBinary"),
        OTHER_FILE("otherFile"),
        ANONYMOUS_PRIVATE("anonymousPrivate"),
        ANONYMOUS_SHARED("anonymousShared");

        final String jsonName;

        Category(String jsonName) {
            this.jsonName = jsonName;
        }
    }

    enum SizeBucket {
        UNDER_64_KIB("under64KiB"),
        FROM_64_KIB_TO_1_MIB("64KiBTo1MiB"),
        FROM_1_MIB_TO_16_MIB("1MiBTo16MiB"),
        FROM_16_MIB_TO_128_MIB("16MiBTo128MiB"),
        AT_LEAST_128_MIB("atLeast128MiB");

        final String jsonName;

        SizeBucket(String jsonName) {
            this.jsonName = jsonName;
        }

        static SizeBucket fromKiB(long sizeKiB) {
            if(sizeKiB < 64L) return UNDER_64_KIB;
            if(sizeKiB < 1024L) return FROM_64_KIB_TO_1_MIB;
            if(sizeKiB < 16L * 1024L) return FROM_1_MIB_TO_16_MIB;
            if(sizeKiB < 128L * 1024L) return FROM_16_MIB_TO_128_MIB;
            return AT_LEAST_128_MIB;
        }
    }

    static final class Metrics {
        long mappings;
        long sizeKiB;
        long rssKiB;
        long pssKiB;
        long privateCleanKiB;
        long privateDirtyKiB;
        long sharedCleanKiB;
        long sharedDirtyKiB;
        long anonymousKiB;
        long swapKiB;
        long swapPssKiB;

        void add(Metrics other) {
            mappings += other.mappings;
            sizeKiB += other.sizeKiB;
            rssKiB += other.rssKiB;
            pssKiB += other.pssKiB;
            privateCleanKiB += other.privateCleanKiB;
            privateDirtyKiB += other.privateDirtyKiB;
            sharedCleanKiB += other.sharedCleanKiB;
            sharedDirtyKiB += other.sharedDirtyKiB;
            anonymousKiB += other.anonymousKiB;
            swapKiB += other.swapKiB;
            swapPssKiB += other.swapPssKiB;
        }

        String toJson() {
            return "{\"mappings\":" + mappings +
                    ",\"sizeKiB\":" + sizeKiB +
                    ",\"rssKiB\":" + rssKiB +
                    ",\"pssKiB\":" + pssKiB +
                    ",\"privateCleanKiB\":" + privateCleanKiB +
                    ",\"privateDirtyKiB\":" + privateDirtyKiB +
                    ",\"sharedCleanKiB\":" + sharedCleanKiB +
                    ",\"sharedDirtyKiB\":" + sharedDirtyKiB +
                    ",\"anonymousKiB\":" + anonymousKiB +
                    ",\"swapKiB\":" + swapKiB +
                    ",\"swapPssKiB\":" + swapPssKiB + "}";
        }
    }

    static final class Snapshot {
        final long elapsedRealtimeMs;
        final Metrics total;
        final EnumMap<Category, Metrics> categories;
        final EnumMap<SizeBucket, Metrics> sizeBuckets;
        final EnumMap<Category, EnumMap<SizeBucket, Metrics>> categorySizeBuckets;
        final AnonymousMappingSummary[] topAnonymousPrivateMappings;

        Snapshot(long elapsedRealtimeMs, Metrics total,
                EnumMap<Category, Metrics> categories,
                EnumMap<SizeBucket, Metrics> sizeBuckets,
                EnumMap<Category, EnumMap<SizeBucket, Metrics>> categorySizeBuckets,
                AnonymousMappingSummary[] topAnonymousPrivateMappings) {
            this.elapsedRealtimeMs = elapsedRealtimeMs;
            this.total = total;
            this.categories = categories;
            this.sizeBuckets = sizeBuckets;
            this.categorySizeBuckets = categorySizeBuckets;
            this.topAnonymousPrivateMappings = topAnonymousPrivateMappings;
        }

        String toJson() {
            StringBuilder output = new StringBuilder(16384);
            output.append("{\"schema\":2,\"elapsedRealtimeMs\":")
                    .append(elapsedRealtimeMs)
                    .append(",\"total\":")
                    .append(total.toJson())
                    .append(",\"categories\":{");
            appendMap(output, categories);
            output.append("},\"sizeBuckets\":{");
            appendMap(output, sizeBuckets);
            output.append("},\"categorySizeBuckets\":{");
            appendCategorySizeBuckets(output, categorySizeBuckets);
            output.append("},\"topAnonymousPrivateMappings\":[");
            for(int index = 0; index < topAnonymousPrivateMappings.length; index++) {
                if(index > 0) output.append(',');
                output.append(topAnonymousPrivateMappings[index].toJson());
            }
            return output.append("]}").toString();
        }

        private static <E extends Enum<E>> void appendMap(
                StringBuilder output, EnumMap<E, Metrics> values) {
            boolean first = true;
            for(Map.Entry<E, Metrics> entry : values.entrySet()) {
                if(!first) output.append(',');
                first = false;
                String name = entry.getKey() instanceof Category
                        ? ((Category) entry.getKey()).jsonName
                        : ((SizeBucket) entry.getKey()).jsonName;
                output.append('\"').append(name).append("\":")
                        .append(entry.getValue().toJson());
            }
        }

        private static void appendCategorySizeBuckets(
                StringBuilder output,
                EnumMap<Category, EnumMap<SizeBucket, Metrics>> values) {
            boolean firstCategory = true;
            for(Map.Entry<Category, EnumMap<SizeBucket, Metrics>> entry :
                    values.entrySet()) {
                if(!firstCategory) output.append(',');
                firstCategory = false;
                output.append('\"').append(entry.getKey().jsonName).append("\":{");
                appendMap(output, entry.getValue());
                output.append('}');
            }
        }
    }

    private static final class Mapping {
        final Category category;
        final String permissions;
        final Metrics metrics = new Metrics();

        Mapping(String permissions, String rawName) {
            category = classify(permissions, rawName);
            this.permissions = sanitizePermissions(permissions);
            metrics.mappings = 1L;
        }

        void set(String name, long value) {
            switch(name) {
                case "Size": metrics.sizeKiB = value; break;
                case "Rss": metrics.rssKiB = value; break;
                case "Pss": metrics.pssKiB = value; break;
                case "Private_Clean": metrics.privateCleanKiB = value; break;
                case "Private_Dirty": metrics.privateDirtyKiB = value; break;
                case "Shared_Clean": metrics.sharedCleanKiB = value; break;
                case "Shared_Dirty": metrics.sharedDirtyKiB = value; break;
                case "Anonymous": metrics.anonymousKiB = value; break;
                case "Swap": metrics.swapKiB = value; break;
                case "SwapPss": metrics.swapPssKiB = value; break;
                default: break;
            }
        }
    }

    static final class AnonymousMappingSummary {
        final long sizeKiB;
        final long rssKiB;
        final long pssKiB;
        final long privateDirtyKiB;
        final long anonymousKiB;
        final long swapKiB;
        final String permissions;

        AnonymousMappingSummary(Mapping mapping) {
            Metrics metrics = mapping.metrics;
            sizeKiB = metrics.sizeKiB;
            rssKiB = metrics.rssKiB;
            pssKiB = metrics.pssKiB;
            privateDirtyKiB = metrics.privateDirtyKiB;
            anonymousKiB = metrics.anonymousKiB;
            swapKiB = metrics.swapKiB;
            permissions = mapping.permissions;
        }

        String toJson() {
            return "{\"sizeKiB\":" + sizeKiB +
                    ",\"rssKiB\":" + rssKiB +
                    ",\"pssKiB\":" + pssKiB +
                    ",\"privateDirtyKiB\":" + privateDirtyKiB +
                    ",\"anonymousKiB\":" + anonymousKiB +
                    ",\"swapKiB\":" + swapKiB +
                    ",\"permissions\":\"" + permissions + "\"}";
        }
    }

    private static String sanitizePermissions(String permissions) {
        if(permissions == null || permissions.length() != 4) {
            return "----";
        }
        char read = permissions.charAt(0);
        char write = permissions.charAt(1);
        char execute = permissions.charAt(2);
        char sharing = permissions.charAt(3);
        if((read != 'r' && read != '-') ||
                (write != 'w' && write != '-') ||
                (execute != 'x' && execute != '-') ||
                (sharing != 'p' && sharing != 's')) {
            return "----";
        }
        return permissions;
    }

    private static Category classify(String permissions, String rawName) {
        String name = rawName == null
                ? "" : rawName.trim().toLowerCase(Locale.ROOT);
        boolean shared = permissions != null && permissions.length() >= 4 &&
                permissions.charAt(3) == 's';
        boolean executable = permissions != null && permissions.length() >= 3 &&
                permissions.charAt(2) == 'x';

        if(name.contains("g1") && (name.contains("heap") || name.contains("reserved"))) {
            return Category.HOTSPOT_HEAP;
        }
        if(name.contains("/runtimes/jre/") || name.contains("libjvm.so") ||
                name.endsWith("/lib/modules") || name.endsWith("/classes.jsa")) {
            return Category.HOTSPOT_RUNTIME;
        }
        if(name.contains("dalvik") || name.contains("/libart.so") ||
                name.contains("/boot.art") || name.contains("/boot.oat")) {
            return Category.ANDROID_RUNTIME;
        }
        if(name.equals("[heap]") || name.contains("libc_malloc") ||
                name.contains("scudo") || name.contains("malloc")) {
            return Category.NATIVE_HEAP;
        }
        if(name.contains("/dev/kgsl") || name.contains("dmabuf") ||
                name.contains("dma_heap") || name.contains("gralloc") ||
                name.contains("/dev/dri")) {
            return Category.GPU_OR_DMA;
        }
        if(name.startsWith("[stack") || name.contains("anon:stack")) {
            return Category.THREAD_STACK;
        }
        if(name.contains("jit") || name.contains("codeheap") ||
                (executable && (name.isEmpty() || name.startsWith("[anon:")))) {
            return Category.JIT_OR_CODE;
        }
        if(name.contains("/dev/ashmem") || name.contains("memfd:") ||
                name.contains("/dev/shm")) {
            return Category.SHARED_MEMORY;
        }
        if(name.contains("/data/app/")) {
            return Category.APP_BINARY;
        }
        if(name.contains("/android/data/com.qcxr.qcxr.canary262/") ||
                name.contains("/storage/emulated/") || name.startsWith("/sdcard/")) {
            return Category.GAME_CONTENT;
        }
        if(name.startsWith("/system/") || name.startsWith("/vendor/") ||
                name.startsWith("/apex/") || name.startsWith("/product/") ||
                name.startsWith("/odm/")) {
            return Category.SYSTEM_BINARY;
        }
        if(name.startsWith("/")) {
            return Category.OTHER_FILE;
        }
        return shared ? Category.ANONYMOUS_SHARED : Category.ANONYMOUS_PRIVATE;
    }

    /** Handle owned by the launch that started the sampler. */
    public static final class Session implements AutoCloseable {
        private static final Session NO_OP = new Session();
        private final Path outputDirectory;
        private final AtomicBoolean closed = new AtomicBoolean();
        private Thread worker;

        private Session() {
            outputDirectory = null;
            closed.set(true);
        }

        private Session(Path outputDirectory) {
            this.outputDirectory = outputDirectory;
        }

        private void start() {
            worker = new Thread(this::run, "Quest-Lab-Smaps");
            worker.setDaemon(true);
            worker.start();
        }

        private void run() {
            try {
                while(!closed.get()) {
                    writeOneSample();
                    Thread.sleep(SAMPLE_INTERVAL_SECONDS * 1000L);
                }
            } catch(InterruptedException ignored) {
                Thread.currentThread().interrupt();
            } catch(IOException | RuntimeException ignored) {
                // Stop after one failure; never leak paths through logs.
                Logger.getInstance().appendToLog(
                        "Lab native memory-map sampler stopped after a read/write failure");
            }
        }

        private void writeOneSample() throws IOException {
            // Keep all per-sample maps, summaries, and JSON scoped to this
            // call so the sleeping sampler retains no previous snapshot.
            Snapshot snapshot;
            try(BufferedReader input = Files.newBufferedReader(
                    SELF_SMAPS, StandardCharsets.US_ASCII)) {
                snapshot = parse(input, SystemClock.elapsedRealtime());
            }
            appendBounded(outputDirectory, snapshot.toJson(),
                    MAX_FILE_MIB * 1024L * 1024L, FILE_COUNT);
        }

        @Override
        public void close() {
            if(!closed.compareAndSet(false, true)) return;
            Thread running = worker;
            if(running != null) running.interrupt();
        }
    }
}
