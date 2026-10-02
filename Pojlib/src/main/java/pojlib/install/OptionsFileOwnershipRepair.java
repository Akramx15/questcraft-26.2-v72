package pojlib.install;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

/**
 * Repairs a bounded settings-file inode that was created by adb rather than by
 * the app. The contents are never interpreted. Replacement is serialized in
 * process and preserves the current inode at a deterministic recovery path
 * until the byte-exact app-owned replacement has been published and verified.
 */
public final class OptionsFileOwnershipRepair {
    public enum Outcome {
        ABSENT,
        ALREADY_WRITABLE,
        REPAIRED
    }

    static final int MAX_OPTIONS_BYTES = 4 * 1024 * 1024;
    private static final Object REPAIR_MUTEX = new Object();

    interface MoveEngine {
        void atomicReplace(Path source, Path destination) throws IOException;

        void move(Path source, Path destination, boolean replace) throws IOException;
    }

    private static final MoveEngine NIO_MOVES = new MoveEngine() {
        @Override
        public void atomicReplace(Path source, Path destination) throws IOException {
            Files.move(source, destination,
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        }

        @Override
        public void move(Path source, Path destination, boolean replace) throws IOException {
            if (replace) {
                Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
            } else {
                Files.move(source, destination);
            }
        }
    };

    private OptionsFileOwnershipRepair() {
    }

    /**
     * Returns without touching absent or already-writable files. An unwritable
     * regular file is replaced by an app-created inode containing exactly the
     * same bytes. An interrupted journaled replacement is recovered before a
     * new decision is made.
     */
    public static Outcome repair(File optionsFile) throws IOException {
        return repair(optionsFile, false, NIO_MOVES);
    }

    /** Package-private seam used to exercise the unwritable path on host OSes. */
    static Outcome repair(File optionsFile, boolean forceRepair, MoveEngine moves) throws IOException {
        if (optionsFile == null || moves == null) {
            throw new IOException("options ownership repair requires a file and move engine");
        }
        synchronized (REPAIR_MUTEX) {
            return repairSerialized(optionsFile, forceRepair, moves);
        }
    }

    private static Outcome repairSerialized(
            File optionsFile, boolean forceRepair, MoveEngine moves) throws IOException {
        Path destination = optionsFile.toPath().toAbsolutePath();
        Path parent = destination.getParent();
        if (parent == null) {
            throw new IOException("options ownership repair requires an existing parent directory");
        }
        if (!Files.exists(parent, LinkOption.NOFOLLOW_LINKS) &&
                !Files.exists(destination, LinkOption.NOFOLLOW_LINKS)) {
            return Outcome.ABSENT;
        }
        if (!Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("options ownership repair requires an existing parent directory");
        }
        Path staged = sidecar(destination, ".qc-owner-stage.tmp");
        Path backup = sidecar(destination, ".qc-owner-backup.bak");
        Path displaced = sidecar(destination, ".qc-owner-original.bak");
        recoverInterruptedReplacement(destination, staged, backup, displaced, moves);

        if (!Files.exists(destination, LinkOption.NOFOLLOW_LINKS)) {
            return Outcome.ABSENT;
        }
        if (Files.isSymbolicLink(destination) ||
                !Files.isRegularFile(destination, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("options ownership repair requires a regular file");
        }
        if (!forceRepair && optionsFile.canWrite()) {
            return Outcome.ALREADY_WRITABLE;
        }

        byte[] original = readBounded(destination, MAX_OPTIONS_BYTES);
        byte[] expectedHash = sha256(original);
        boolean replacementStarted = false;
        boolean success = false;
        try {
            createNewRegularFile(staged);
            writeDurably(staged, original);
            verifyExact(staged, original, expectedHash);
            createNewRegularFile(backup);
            writeDurably(backup, original);
            verifyExact(backup, original, expectedHash);

            // First compare, then atomically preserve the exact inode at a
            // deterministic recovery path. Verifying the displaced inode
            // closes the compare/publish race: a concurrent edit is retained
            // and rejected rather than overwritten by our staged copy.
            verifyExact(destination, original, expectedHash);
            replacementStarted = true;
            journaledReplace(destination, staged, displaced, original,
                expectedHash, moves);

            verifyExact(destination, original, expectedHash);
            if (!destination.toFile().canWrite()) {
                restoreFromBackup(destination, backup, original, expectedHash, moves);
                throw new IOException("repaired options file is still not writable");
            }
            success = true;
            return Outcome.REPAIRED;
        } catch (IOException failure) {
            if (replacementStarted &&
                    !Files.exists(destination, LinkOption.NOFOLLOW_LINKS)) {
                try {
                    restoreFromBackup(destination, backup, original, expectedHash, moves);
                } catch (IOException restoreFailure) {
                    failure.addSuppressed(restoreFailure);
                }
            } else if (replacementStarted &&
                    !exactBytes(destination, original, expectedHash)) {
                failure.addSuppressed(new IOException(
                    "current settings changed during ownership repair; unknown bytes preserved"));
            }
            throw failure;
        } finally {
            deleteQuietly(staged);
            if (!replacementStarted || success ||
                    Files.exists(destination, LinkOption.NOFOLLOW_LINKS)) {
                deleteQuietly(backup);
            }
            if (!replacementStarted || success ||
                    exactBytes(destination, original, expectedHash)) {
                deleteQuietly(displaced);
            }
        }
    }

    private static void journaledReplace(
            Path destination, Path staged, Path displaced, byte[] original,
            byte[] expectedHash, MoveEngine moves) throws IOException {
        boolean originalDisplaced = false;
        try {
            requireUnusedSidecar(displaced);
            moves.move(destination, displaced, false);
            originalDisplaced = true;
            verifyExact(displaced, original, expectedHash);
            moves.move(staged, destination, false);
            verifyExact(destination, original, expectedHash);
        } catch (IOException fallbackFailure) {
            if (originalDisplaced) {
                try {
                    if (!Files.exists(destination, LinkOption.NOFOLLOW_LINKS)) {
                        moves.move(displaced, destination, false);
                    } else if (exactBytes(destination, original, expectedHash)) {
                        deleteQuietly(displaced);
                    } else {
                        fallbackFailure.addSuppressed(new IOException(
                            "replacement destination contains unknown concurrent bytes; journal retained"));
                    }
                } catch (IOException displacedRestoreFailure) {
                    fallbackFailure.addSuppressed(displacedRestoreFailure);
                }
            }
            throw fallbackFailure;
        }
    }

    private static void recoverInterruptedReplacement(
            Path destination, Path staged, Path backup, Path displaced,
            MoveEngine moves) throws IOException {
        assertSafeSidecar(staged);
        assertSafeSidecar(backup);
        assertSafeSidecar(displaced);
        if (Files.exists(displaced, LinkOption.NOFOLLOW_LINKS)) {
            if (!Files.exists(destination, LinkOption.NOFOLLOW_LINKS)) {
                moves.move(displaced, destination, false);
            } else if (sameBoundedBytes(destination, displaced)) {
                Files.delete(displaced);
            } else {
                throw new IOException(
                    "interrupted ownership repair conflicts with current settings; recovery journal retained");
            }
        }
        deleteQuietly(staged);
        deleteQuietly(backup);
    }

    private static Path sidecar(Path destination, String suffix) {
        return destination.resolveSibling("." + destination.getFileName() + suffix);
    }

    private static void createNewRegularFile(Path path) throws IOException {
        requireUnusedSidecar(path);
        Files.createFile(path);
    }

    private static void requireUnusedSidecar(Path path) throws IOException {
        if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("ownership repair sidecar already exists");
        }
    }

    private static void assertSafeSidecar(Path path) throws IOException {
        if (Files.exists(path, LinkOption.NOFOLLOW_LINKS) &&
                (Files.isSymbolicLink(path) ||
                    !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))) {
            throw new IOException("ownership repair sidecar is not a regular file");
        }
    }

    private static boolean sameBoundedBytes(Path first, Path second) throws IOException {
        byte[] firstBytes = readBounded(first, MAX_OPTIONS_BYTES);
        byte[] secondBytes = readBounded(second, MAX_OPTIONS_BYTES);
        return Arrays.equals(firstBytes, secondBytes);
    }

    private static void restoreFromBackup(
            Path destination, Path backup, byte[] original, byte[] expectedHash,
            MoveEngine moves) throws IOException {
        verifyExact(backup, original, expectedHash);
        try {
            moves.atomicReplace(backup, destination);
        } catch (IOException atomicFailure) {
            if (Files.exists(destination, LinkOption.NOFOLLOW_LINKS)) {
                if (exactBytes(destination, original, expectedHash) &&
                        destination.toFile().canWrite()) {
                    return;
                }
                throw new IOException(
                    "restore destination changed during atomic replacement; unknown bytes preserved",
                    atomicFailure);
            }
            try {
                moves.move(backup, destination, false);
            } catch (IOException fallbackFailure) {
                fallbackFailure.addSuppressed(atomicFailure);
                throw fallbackFailure;
            }
        }
        verifyExact(destination, original, expectedHash);
    }

    private static void deleteQuietly(Path path) {
        try {
            Files.deleteIfExists(path);
        } catch (IOException ignored) {
            // The verified destination is authoritative. A same-directory
            // recovery sidecar may be cleaned up on a later launch.
        }
    }

    private static void writeDurably(Path destination, byte[] contents) throws IOException {
        try (FileOutputStream output = new FileOutputStream(destination.toFile(), false)) {
            output.write(contents);
            output.flush();
            output.getFD().sync();
        }
    }

    private static void verifyExact(Path path, byte[] expected, byte[] expectedHash)
            throws IOException {
        byte[] actual = readBounded(path, MAX_OPTIONS_BYTES);
        if (actual.length != expected.length ||
                !MessageDigest.isEqual(expectedHash, sha256(actual)) ||
                !Arrays.equals(expected, actual)) {
            throw new IOException("options ownership repair byte verification failed");
        }
    }

    private static boolean exactBytes(Path path, byte[] expected, byte[] expectedHash) {
        try {
            if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
                return false;
            }
            byte[] actual = readBounded(path, MAX_OPTIONS_BYTES);
            return actual.length == expected.length &&
                MessageDigest.isEqual(expectedHash, sha256(actual)) &&
                Arrays.equals(expected, actual);
        } catch (IOException ignored) {
            return false;
        }
    }

    private static byte[] readBounded(Path source, int maximumBytes) throws IOException {
        long reportedSize = Files.size(source);
        if (reportedSize < 0 || reportedSize > maximumBytes) {
            throw new IOException("options file exceeds ownership repair limit");
        }

        try (InputStream input = new FileInputStream(source.toFile());
                ByteArrayOutputStream output =
                    new ByteArrayOutputStream((int) Math.min(reportedSize, 64 * 1024))) {
            byte[] buffer = new byte[16 * 1024];
            int total = 0;
            int read;
            while ((read = input.read(buffer)) != -1) {
                total += read;
                if (total > maximumBytes) {
                    throw new IOException("options file exceeds ownership repair limit");
                }
                output.write(buffer, 0, read);
            }
            return output.toByteArray();
        }
    }

    private static byte[] sha256(byte[] contents) throws IOException {
        try {
            return MessageDigest.getInstance("SHA-256").digest(contents);
        } catch (NoSuchAlgorithmException impossible) {
            throw new IOException("SHA-256 is unavailable", impossible);
        }
    }
}
