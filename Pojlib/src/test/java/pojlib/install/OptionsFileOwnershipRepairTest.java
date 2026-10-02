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
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

public class OptionsFileOwnershipRepairTest {
    @Rule
    public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void absentFileIsAnExactNoOp() throws Exception {
        File options = new File(temporaryFolder.getRoot(), "options.txt");

        assertEquals(OptionsFileOwnershipRepair.Outcome.ABSENT,
            OptionsFileOwnershipRepair.repair(options));
        assertFalse(options.exists());
        assertEquals(0, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void absentFileUnderAbsentParentIsAnExactNoOp() throws Exception {
        File options = new File(temporaryFolder.getRoot(),
            "missing/config/vivecraft-client-config.json");

        assertEquals(OptionsFileOwnershipRepair.Outcome.ABSENT,
            OptionsFileOwnershipRepair.repair(options));
        assertFalse(options.exists());
        assertEquals(0, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void writableFileIsNotRewritten() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "resourcePacks:[\"vanilla\"]\n\u0000tail".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        long modified = options.lastModified();

        assertEquals(OptionsFileOwnershipRepair.Outcome.ALREADY_WRITABLE,
            OptionsFileOwnershipRepair.repair(options));
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(modified, options.lastModified());
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void writableDirectoryIsRejectedBeforeWritableFastPath() throws Exception {
        File options = temporaryFolder.newFolder("options.txt");

        try {
            OptionsFileOwnershipRepair.repair(options);
            fail("expected non-regular file rejection");
        } catch (IOException expected) {
            assertEquals("options ownership repair requires a regular file", expected.getMessage());
        }

        assertTrue(options.isDirectory());
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void forcedRepairPreservesEveryByte() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = new byte[131_071];
        for (int index = 0; index < original.length; index++) {
            original[index] = (byte) (index * 31);
        }
        Files.write(options.toPath(), original);

        assertEquals(OptionsFileOwnershipRepair.Outcome.REPAIRED,
            OptionsFileOwnershipRepair.repair(options, true, nioMoves()));
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void nonAtomicFallbackPreservesEveryByte() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "gamma:0.5\r\nresourcePacks:[\"vanilla\"]\r\n"
            .getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        OptionsFileOwnershipRepair.MoveEngine fallbackOnly =
            new OptionsFileOwnershipRepair.MoveEngine() {
                @Override
                public void atomicReplace(Path source, Path destination) throws IOException {
                    throw new AtomicMoveNotSupportedException(
                        source.toString(), destination.toString(), "test fallback");
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

        assertEquals(OptionsFileOwnershipRepair.Outcome.REPAIRED,
            OptionsFileOwnershipRepair.repair(options, true, fallbackOnly));
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void failedFallbackRestoresOriginalAtItsPath() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "music:0.0\nrenderDistance:6\n".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        OptionsFileOwnershipRepair.MoveEngine failInstall =
            new OptionsFileOwnershipRepair.MoveEngine() {
                private int ordinaryMoves;

                @Override
                public void atomicReplace(Path source, Path destination) throws IOException {
                    throw new AtomicMoveNotSupportedException(
                        source.toString(), destination.toString(), "test fallback");
                }

                @Override
                public void move(Path source, Path destination, boolean replace) throws IOException {
                    ordinaryMoves++;
                    if (ordinaryMoves == 2) {
                        throw new IOException("injected staged install failure");
                    }
                    if (replace) {
                        Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
                    } else {
                        Files.move(source, destination);
                    }
                }
            };

        try {
            OptionsFileOwnershipRepair.repair(options, true, failInstall);
            fail("expected staged install failure");
        } catch (IOException expected) {
            assertEquals("injected staged install failure", expected.getMessage());
        }

        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void durableBackupRestoresWhenOriginalInodeCannotBeMovedBack() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "soundCategory_music:0.0\nrenderDistance:6\n"
            .getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        OptionsFileOwnershipRepair.MoveEngine restoreFromBackup =
            new OptionsFileOwnershipRepair.MoveEngine() {
                private int atomicMoves;
                private int ordinaryMoves;

                @Override
                public void atomicReplace(Path source, Path destination) throws IOException {
                    atomicMoves++;
                    if (atomicMoves == 1) {
                        throw new AtomicMoveNotSupportedException(
                            source.toString(), destination.toString(), "test fallback");
                    }
                    Files.move(source, destination,
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                }

                @Override
                public void move(Path source, Path destination, boolean replace) throws IOException {
                    ordinaryMoves++;
                    if (ordinaryMoves == 2) {
                        throw new IOException("injected staged install failure");
                    }
                    if (ordinaryMoves == 3) {
                        throw new IOException("injected original inode restore failure");
                    }
                    if (replace) {
                        Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
                    } else {
                        Files.move(source, destination);
                    }
                }
            };

        try {
            OptionsFileOwnershipRepair.repair(options, true, restoreFromBackup);
            fail("expected staged install failure");
        } catch (IOException expected) {
            assertEquals("injected staged install failure", expected.getMessage());
        }

        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void oversizedFileIsRejectedWithoutCreatingSidecars() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = new byte[OptionsFileOwnershipRepair.MAX_OPTIONS_BYTES + 1];
        Arrays.fill(original, (byte) 0x5a);
        Files.write(options.toPath(), original);

        try {
            OptionsFileOwnershipRepair.repair(options, true, nioMoves());
            fail("expected oversized file rejection");
        } catch (IOException expected) {
            assertEquals("options file exceeds ownership repair limit", expected.getMessage());
        }

        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void concurrentChangeCapturedDuringDisplacementIsPreserved() throws Exception {
        File options = temporaryFolder.newFile("vivecraft-client-config.json");
        byte[] original = "{\"renderScaleFactor\":\"1.0\"}".getBytes(StandardCharsets.UTF_8);
        byte[] external = "{\"renderScaleFactor\":\"0.9\"}".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        OptionsFileOwnershipRepair.MoveEngine mutateDuringComparePublish =
            new OptionsFileOwnershipRepair.MoveEngine() {
                private int moves;

                @Override
                public void atomicReplace(Path source, Path destination) throws IOException {
                    Files.move(source, destination,
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                }

                @Override
                public void move(Path source, Path destination, boolean replace) throws IOException {
                    moves++;
                    if (moves == 1) {
                        Files.write(source, external);
                    }
                    if (replace) {
                        Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
                    } else {
                        Files.move(source, destination);
                    }
                }
            };

        try {
            OptionsFileOwnershipRepair.repair(options, true, mutateDuringComparePublish);
            fail("expected concurrent-change rejection");
        } catch (IOException expected) {
            assertTrue(expected.getMessage().contains("byte verification failed"));
        }

        assertArrayEquals(external, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void destinationCreatedInsideAtomicRestoreIsNeverOverwritten() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "gamma:0.5\n".getBytes(StandardCharsets.UTF_8);
        byte[] external = "gamma:external\n".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        OptionsFileOwnershipRepair.MoveEngine mutateAtomicRestore =
            new OptionsFileOwnershipRepair.MoveEngine() {
                private int ordinaryMoves;

                @Override
                public void atomicReplace(Path source, Path destination) throws IOException {
                    Files.write(destination, external);
                    throw new IOException("injected atomic restore race");
                }

                @Override
                public void move(Path source, Path destination, boolean replace) throws IOException {
                    ordinaryMoves++;
                    if (ordinaryMoves == 2 || ordinaryMoves == 3) {
                        throw new IOException("injected publish and journal restore failure");
                    }
                    if (replace) {
                        Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
                    } else {
                        Files.move(source, destination);
                    }
                }
            };

        try {
            OptionsFileOwnershipRepair.repair(options, true, mutateAtomicRestore);
            fail("expected atomic-restore race rejection");
        } catch (IOException expected) {
            assertEquals("injected publish and journal restore failure", expected.getMessage());
        }

        assertArrayEquals(external, Files.readAllBytes(options.toPath()));
        assertTrue(sidecar(options, ".qc-owner-original.bak").isFile());
    }

    @Test
    public void recoversInterruptionAfterStageCreation() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "stage-boundary".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        Files.write(sidecar(options, ".qc-owner-stage.tmp").toPath(), original);

        assertEquals(OptionsFileOwnershipRepair.Outcome.ALREADY_WRITABLE,
            OptionsFileOwnershipRepair.repair(options, false, nioMoves()));
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void recoversInterruptionAfterBackupCreation() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "backup-boundary".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        Files.write(sidecar(options, ".qc-owner-stage.tmp").toPath(), original);
        Files.write(sidecar(options, ".qc-owner-backup.bak").toPath(), original);

        assertEquals(OptionsFileOwnershipRepair.Outcome.ALREADY_WRITABLE,
            OptionsFileOwnershipRepair.repair(options, false, nioMoves()));
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void recoversInterruptionAfterOriginalDisplacement() throws Exception {
        File options = new File(temporaryFolder.getRoot(), "options.txt");
        byte[] original = "displaced-boundary".getBytes(StandardCharsets.UTF_8);
        Files.write(sidecar(options, ".qc-owner-original.bak").toPath(), original);
        Files.write(sidecar(options, ".qc-owner-stage.tmp").toPath(), original);
        Files.write(sidecar(options, ".qc-owner-backup.bak").toPath(), original);

        assertEquals(OptionsFileOwnershipRepair.Outcome.ALREADY_WRITABLE,
            OptionsFileOwnershipRepair.repair(options, false, nioMoves()));
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void recoversInterruptionAfterReplacementPublication() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "published-boundary".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        Files.write(sidecar(options, ".qc-owner-original.bak").toPath(), original);
        Files.write(sidecar(options, ".qc-owner-backup.bak").toPath(), original);

        assertEquals(OptionsFileOwnershipRepair.Outcome.ALREADY_WRITABLE,
            OptionsFileOwnershipRepair.repair(options, false, nioMoves()));
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    @Test
    public void interruptedJournalNeverOverwritesUnknownCurrentBytes() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "journal-original".getBytes(StandardCharsets.UTF_8);
        byte[] external = "external-current".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), external);
        File journal = sidecar(options, ".qc-owner-original.bak");
        Files.write(journal.toPath(), original);

        try {
            OptionsFileOwnershipRepair.repair(options, false, nioMoves());
            fail("expected interrupted-journal conflict");
        } catch (IOException expected) {
            assertTrue(expected.getMessage().contains("recovery journal retained"));
        }

        assertArrayEquals(external, Files.readAllBytes(options.toPath()));
        assertArrayEquals(original, Files.readAllBytes(journal.toPath()));
    }

    @Test
    public void repairsAreSerializedInsideOneProcess() throws Exception {
        File options = temporaryFolder.newFile("options.txt");
        byte[] original = "serialized-repair".getBytes(StandardCharsets.UTF_8);
        Files.write(options.toPath(), original);
        CountDownLatch firstMoveEntered = new CountDownLatch(1);
        CountDownLatch releaseFirstMove = new CountDownLatch(1);
        CountDownLatch secondStarted = new CountDownLatch(1);
        AtomicInteger ordinaryMoves = new AtomicInteger();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        OptionsFileOwnershipRepair.MoveEngine blockingMoves =
            new OptionsFileOwnershipRepair.MoveEngine() {
                @Override
                public void atomicReplace(Path source, Path destination) throws IOException {
                    Files.move(source, destination,
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                }

                @Override
                public void move(Path source, Path destination, boolean replace) throws IOException {
                    int call = ordinaryMoves.incrementAndGet();
                    if (call == 1) {
                        firstMoveEntered.countDown();
                        try {
                            if (!releaseFirstMove.await(5, TimeUnit.SECONDS)) {
                                throw new IOException("timed out waiting to release first repair");
                            }
                        } catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            throw new IOException("repair test interrupted", interrupted);
                        }
                    }
                    if (replace) {
                        Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
                    } else {
                        Files.move(source, destination);
                    }
                }
            };
        Thread first = new Thread(() -> runRepair(options, blockingMoves, failure));
        Thread second = new Thread(() -> {
            secondStarted.countDown();
            runRepair(options, blockingMoves, failure);
        });

        first.start();
        assertTrue(firstMoveEntered.await(5, TimeUnit.SECONDS));
        second.start();
        assertTrue(secondStarted.await(5, TimeUnit.SECONDS));
        Thread.sleep(100);
        assertEquals(1, ordinaryMoves.get());
        releaseFirstMove.countDown();
        first.join(5_000);
        second.join(5_000);

        assertFalse(first.isAlive());
        assertFalse(second.isAlive());
        if (failure.get() != null) {
            throw new AssertionError("serialized repair failed", failure.get());
        }
        assertArrayEquals(original, Files.readAllBytes(options.toPath()));
        assertEquals(1, temporaryFolder.getRoot().list().length);
    }

    private static void runRepair(
            File options, OptionsFileOwnershipRepair.MoveEngine moves,
            AtomicReference<Throwable> failure) {
        try {
            OptionsFileOwnershipRepair.repair(options, true, moves);
        } catch (Throwable thrown) {
            failure.compareAndSet(null, thrown);
        }
    }

    private static File sidecar(File destination, String suffix) {
        return new File(destination.getParentFile(), "." + destination.getName() + suffix);
    }

    private static OptionsFileOwnershipRepair.MoveEngine nioMoves() {
        return new OptionsFileOwnershipRepair.MoveEngine() {
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
    }
}
