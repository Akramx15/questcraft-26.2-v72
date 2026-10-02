package pojlib.install;

import pojlib.util.download.DownloadUtils;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;

/**
 * Installs the version's asset index without exposing an existing index to a
 * partial download. The downloaded bytes are verified in the destination
 * directory before publication so the normal path can use an atomic rename.
 */
final class AssetIndexInstaller {
    enum Outcome {
        ALREADY_VALID,
        INSTALLED,
        REPAIRED
    }

    interface Downloader {
        void download(String url, File destination, long expectedSize) throws IOException;
    }

    interface MoveEngine {
        void atomicReplace(Path source, Path destination) throws IOException;

        void replace(Path source, Path destination) throws IOException;
    }

    private static final Downloader NETWORK_DOWNLOADER =
        (url, destination, expectedSize) ->
            DownloadUtils.downloadFileContents(url, destination, expectedSize);

    private static final MoveEngine NIO_MOVES = new MoveEngine() {
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

    private AssetIndexInstaller() {
    }

    static Outcome ensure(
            File destination, String url, String expectedSha1, long expectedSize)
            throws IOException {
        return ensure(destination, url, expectedSha1, expectedSize,
            NETWORK_DOWNLOADER, NIO_MOVES);
    }

    static Outcome ensure(
            File destination, String url, String expectedSha1, long expectedSize,
            Downloader downloader, MoveEngine moves) throws IOException {
        if (destination == null) {
            throw new IOException("Minecraft asset index destination is missing");
        }
        if (url == null || url.trim().isEmpty()) {
            throw new IOException("Minecraft asset index URL is missing");
        }

        String normalizedSha1 = normalizeSha1(expectedSha1);
        Path destinationPath = destination.toPath();
        if (isExactFile(destinationPath, normalizedSha1, expectedSize)) {
            return Outcome.ALREADY_VALID;
        }

        boolean repairing = Files.exists(destinationPath, LinkOption.NOFOLLOW_LINKS);
        Path parent = destinationPath.getParent();
        if (parent == null) {
            throw new IOException("Minecraft asset index destination has no parent directory");
        }
        Files.createDirectories(parent);

        Path staged = Files.createTempFile(parent,
            "." + destination.getName() + ".", ".download");
        IOException pendingFailure = null;
        try {
            downloader.download(url, staged.toFile(), expectedSize > 0 ? expectedSize : -1);
            requireExactFile(staged, normalizedSha1, expectedSize,
                "Downloaded Minecraft asset index");

            try {
                moves.atomicReplace(staged, destinationPath);
            } catch (AtomicMoveNotSupportedException unsupported) {
                moves.replace(staged, destinationPath);
            }

            return repairing ? Outcome.REPAIRED : Outcome.INSTALLED;
        } catch (IOException failure) {
            pendingFailure = failure;
            throw failure;
        } finally {
            try {
                Files.deleteIfExists(staged);
            } catch (IOException cleanupFailure) {
                if (pendingFailure != null) {
                    pendingFailure.addSuppressed(cleanupFailure);
                } else {
                    throw cleanupFailure;
                }
            }
        }
    }

    private static String normalizeSha1(String sha1) throws IOException {
        if (sha1 == null || !sha1.trim().matches("(?i)[0-9a-f]{40}")) {
            throw new IOException("Minecraft asset index metadata has no valid SHA-1");
        }
        return sha1.trim().toLowerCase(Locale.ROOT);
    }

    private static boolean isExactFile(Path file, String expectedSha1, long expectedSize) {
        try {
            requireExactFile(file, expectedSha1, expectedSize, "Existing Minecraft asset index");
            return true;
        } catch (IOException invalidOrUnreadable) {
            return false;
        }
    }

    private static void requireExactFile(
            Path file, String expectedSha1, long expectedSize, String label) throws IOException {
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException(label + " is missing or is not a regular file");
        }
        if (expectedSize > 0 && Files.size(file) != expectedSize) {
            throw new IOException(label + " size does not match version metadata");
        }

        String actualSha1 = sha1(file);
        if (!actualSha1.equals(expectedSha1)) {
            throw new IOException(label + " SHA-1 does not match version metadata");
        }
    }

    private static String sha1(Path file) throws IOException {
        final MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-1");
        } catch (NoSuchAlgorithmException impossible) {
            throw new IOException("SHA-1 is unavailable", impossible);
        }

        byte[] buffer = new byte[16 * 1024];
        try (InputStream input = Files.newInputStream(file)) {
            int read;
            while ((read = input.read(buffer)) != -1) {
                digest.update(buffer, 0, read);
            }
        }

        StringBuilder hex = new StringBuilder(40);
        for (byte value : digest.digest()) {
            hex.append(String.format(Locale.ROOT, "%02x", value & 0xff));
        }
        return hex.toString();
    }
}
