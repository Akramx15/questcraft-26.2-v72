package pojlib.util;

import org.junit.Test;

import static org.junit.Assert.assertEquals;

public class JvmMemoryPolicyTest {
    @Test
    public void automaticValueUsesTheConservativeMinimumTarget() {
        assertDecision(1536, JvmMemoryPolicy.Source.AUTO,
                JvmMemoryPolicy.resolve(false, "ignored", 900));
        assertDecision(1536, JvmMemoryPolicy.Source.AUTO,
                JvmMemoryPolicy.resolve(false, "ignored", 1800));
        assertDecision(1536, JvmMemoryPolicy.Source.AUTO,
                JvmMemoryPolicy.resolve(false, "ignored", 2800));
        assertDecision(1536, JvmMemoryPolicy.Source.AUTO,
                JvmMemoryPolicy.resolve(false, "ignored", 3168));
    }

    @Test
    public void customValueUsesTheSameHardBounds() {
        assertDecision(1536, JvmMemoryPolicy.Source.CUSTOM,
                JvmMemoryPolicy.resolve(true, "512", 1900));
        assertDecision(1800, JvmMemoryPolicy.Source.CUSTOM,
                JvmMemoryPolicy.resolve(true, " 1800 ", 1900));
        assertDecision(2048, JvmMemoryPolicy.Source.CUSTOM,
                JvmMemoryPolicy.resolve(true, "8192", 1900));
    }

    @Test
    public void invalidCustomValueFallsBackToBoundedAutomaticValue() {
        assertDecision(1536, JvmMemoryPolicy.Source.AUTO_AFTER_INVALID_CUSTOM,
                JvmMemoryPolicy.resolve(true, "not-a-number", 1900));
        assertDecision(1536, JvmMemoryPolicy.Source.AUTO_AFTER_INVALID_CUSTOM,
                JvmMemoryPolicy.resolve(true, null, Long.MAX_VALUE));
        assertDecision(1536, JvmMemoryPolicy.Source.AUTO_AFTER_INVALID_CUSTOM,
                JvmMemoryPolicy.resolve(true, "", -1));
    }

    @Test
    public void initialHeapIsAlways512MiB() {
        assertEquals(512, JvmMemoryPolicy.resolve(false, null, 1536).getInitialHeapMiB());
        assertEquals(512, JvmMemoryPolicy.resolve(true, "2048", 1536).getInitialHeapMiB());
    }

    private static void assertDecision(
            int maximumHeapMiB,
            JvmMemoryPolicy.Source source,
            JvmMemoryPolicy.Decision decision) {
        assertEquals(512, decision.getInitialHeapMiB());
        assertEquals(maximumHeapMiB, decision.getMaximumHeapMiB());
        assertEquals(source, decision.getSource());
    }
}
