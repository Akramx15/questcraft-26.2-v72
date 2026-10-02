package pojlib.install;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

public class AssetIndexInstallerTest {
    @Rule
    public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void validExistingIndexIsPreservedWithoutDownload() throws Exception {
        byte[] valid = "{\"objects\":{\"valid\":{}}}".getBytes(StandardCharsets.UTF_8);
        File destination = temporaryFolder.newFile("32.json");
        Files.write(destination.toPath(), valid);
        long modified = destination.lastModified();

        AssetIndexInstaller.Outcome outcome = AssetIndexInstaller.ensure(
            destination, "https://example.invalid/32.json", sha1(valid), valid.length,
            unexpectedDownloader(), nioMoves());

        assertEquals(AssetIndexInstaller.Outcome.ALREADY_VALID, outcome);
        assertArrayEquals(valid, Files.readAllBytes(destination.toPath()));
        assertEquals(modified, destination.lastModified());
        assertOnlyDestinationRemains(destination);
    }

    @Test
    public void missingIndexIsDownloadedVerifiedAndPublished() throws Exception {
        byte[] valid = "{\"objects\":{\"new\":{}}}".getBytes(StandardCharsets.UTF_8);
        File destination = new File(temporaryFolder.getRoot(), "indexes/32.json");

        AssetIndexInstaller.Outcome outcome = AssetIndexInstaller.ensure(
            destination, "https://example.invalid/32.json", sha1(valid), valid.length,
            bytesDownloader(valid), nioMoves());

        assertEquals(AssetIndexInstaller.Outcome.INSTALLED, outcome);
        assertArrayEquals(valid, Files.readAllBytes(destination.toPath()));
        assertOnlyDestinationRemains(destination);
    }

    @Test
    public void staleIndexRemainsVisibleUntilVerifiedReplacementIsReady() throws Exception {
        byte[] stale = "stale-index".getBytes(StandardCharsets.UTF_8);
        byte[] valid = "{\"objects\":{\"repaired\":{}}}".getBytes(StandardCharsets.UTF_8);
        File destination = temporaryFolder.newFile("32.json");
        Files.write(destination.toPath(), stale);

        AssetIndexInstaller.Downloader downloader = (url, staged, expectedSize) -> {
            assertArrayEquals(stale, Files.readAllBytes(destination.toPath()));
            Files.write(staged.toPath(), valid);
            assertArrayEquals(stale, Files.readAllBytes(destination.toPath()));
        };
        AssetIndexInstaller.Outcome outcome = AssetIndexInstaller.ensure(
            destination, "https://example.invalid/32.json", sha1(valid), valid.length,
            downloader, nioMoves());

        assertEquals(AssetIndexInstaller.Outcome.REPAIRED, outcome);
        assertArrayEquals(valid, Files.readAllBytes(destination.toPath()));
        assertOnlyDestinationRemains(destination);
    }

    @Test
    public void failedDownloadPreservesOldIndexAndCleansStagingFile() throws Exception {
        byte[] stale = "old-index-must-survive".getBytes(StandardCharsets.UTF_8);
        byte[] partial = "partial".getBytes(StandardCharsets.UTF_8);
        File destination = temporaryFolder.newFile("32.json");
        Files.write(destination.toPath(), stale);

        try {
            AssetIndexInstaller.ensure(
                destination, "https://example.invalid/32.json", sha1("expected".getBytes(StandardCharsets.UTF_8)),
                0, (url, staged, expectedSize) -> {
                    Files.write(staged.toPath(), partial);
                    throw new IOException("injected network failure");
                }, nioMoves());
            fail("expected download failure");
        } catch (IOException expected) {
            assertEquals("injected network failure", expected.getMessage());
        }

        assertArrayEquals(stale, Files.readAllBytes(destination.toPath()));
        assertOnlyDestinationRemains(destination);
    }

    @Test
    public void badDownloadedHashPreservesOldIndexAndReportsIntegrityFailure() throws Exception {
        byte[] stale = "old-index-must-survive".getBytes(StandardCharsets.UTF_8);
        byte[] valid = "expected-index".getBytes(StandardCharsets.UTF_8);
        byte[] corrupt = "corrupt-index".getBytes(StandardCharsets.UTF_8);
        File destination = temporaryFolder.newFile("32.json");
        Files.write(destination.toPath(), stale);

        try {
            AssetIndexInstaller.ensure(
                destination, "https://example.invalid/32.json", sha1(valid), 0,
                bytesDownloader(corrupt), nioMoves());
            fail("expected integrity failure");
        } catch (IOException expected) {
            assertEquals("Downloaded Minecraft asset index SHA-1 does not match version metadata",
                expected.getMessage());
        }

        assertArrayEquals(stale, Files.readAllBytes(destination.toPath()));
        assertOnlyDestinationRemains(destination);
    }

    @Test
    public void badDownloadedSizePreservesOldIndex() throws Exception {
        byte[] stale = "old-index-must-survive".getBytes(StandardCharsets.UTF_8);
        byte[] valid = "expected-index".getBytes(StandardCharsets.UTF_8);
        File destination = temporaryFolder.newFile("32.json");
        Files.write(destination.toPath(), stale);

        try {
            AssetIndexInstaller.ensure(
                destination, "https://example.invalid/32.json", sha1(valid), valid.length + 1L,
                bytesDownloader(valid), nioMoves());
            fail("expected size failure");
        } catch (IOException expected) {
            assertEquals("Downloaded Minecraft asset index size does not match version metadata",
                expected.getMessage());
        }

        assertArrayEquals(stale, Files.readAllBytes(destination.toPath()));
        assertOnlyDestinationRemains(destination);
    }

    @Test
    public void nonAtomicPlatformFallbackPublishesVerifiedIndex() throws Exception {
        byte[] stale = "stale-index".getBytes(StandardCharsets.UTF_8);
        byte[] valid = "verified-index".getBytes(StandardCharsets.UTF_8);
        File destination = temporaryFolder.newFile("32.json");
        Files.write(destination.toPath(), stale);
        AssetIndexInstaller.MoveEngine fallbackMoves = new AssetIndexInstaller.MoveEngine() {
            @Override
            public void atomicReplace(Path source, Path target) throws IOException {
                throw new AtomicMoveNotSupportedException(
                    source.toString(), target.toString(), "injected unsupported move");
            }

            @Override
            public void replace(Path source, Path target) throws IOException {
                Files.move(source, target, StandardCopyOption.REPLACE_EXISTING);
            }
        };

        assertEquals(AssetIndexInstaller.Outcome.REPAIRED,
            AssetIndexInstaller.ensure(
                destination, "https://example.invalid/32.json", sha1(valid), valid.length,
                bytesDownloader(valid), fallbackMoves));
        assertArrayEquals(valid, Files.readAllBytes(destination.toPath()));
        assertOnlyDestinationRemains(destination);
    }

    @Test
    public void nonRegularDestinationFailsWithoutBeingDeleted() throws Exception {
        byte[] valid = "verified-index".getBytes(StandardCharsets.UTF_8);
        File destination = temporaryFolder.newFolder("32.json");
        Files.write(new File(destination, "keep.txt").toPath(),
            "keep".getBytes(StandardCharsets.UTF_8));

        try {
            AssetIndexInstaller.ensure(
                destination, "https://example.invalid/32.json", sha1(valid), valid.length,
                bytesDownloader(valid), nioMoves());
            fail("expected destination replacement failure");
        } catch (IOException expected) {
            assertTrue(destination.isDirectory());
        }

        assertTrue(new File(destination, "keep.txt").isFile());
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    private static AssetIndexInstaller.Downloader bytesDownloader(byte[] bytes) {
        return (url, destination, expectedSize) -> Files.write(destination.toPath(), bytes);
    }

    private static AssetIndexInstaller.Downloader unexpectedDownloader() {
        return (url, destination, expectedSize) -> {
            throw new AssertionError("download must not run for a valid existing index");
        };
    }

    private static AssetIndexInstaller.MoveEngine nioMoves() {
        return new AssetIndexInstaller.MoveEngine() {
            @Override
            public void atomicReplace(Path source, Path destination) throws IOException {
                Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
            }

            @Override
            public void replace(Path source, Path destination) throws IOException {
                Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
            }
        };
    }

    private static String sha1(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-1").digest(bytes);
        StringBuilder hex = new StringBuilder(40);
        for (byte value : digest) {
            hex.append(String.format("%02x", value & 0xff));
        }
        return hex.toString();
    }

    private static void assertOnlyDestinationRemains(File destination) {
        File parent = destination.getParentFile();
        assertTrue(destination.isFile());
        assertEquals(1, parent.list().length);
        assertFalse(new File(parent, ".32.json.download").exists());
    }
}
