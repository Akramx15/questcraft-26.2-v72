package org.vivecraft.client_vr.provider.openxr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class OpenXRRuntimePolicyTest {

    @Test
    void leavesRefreshRateAndPerformanceLevelToTheRuntime() {
        Assertions.assertEquals("runtime", OpenXRRuntimePolicy.REFRESH_RATE_OWNER);
        Assertions.assertEquals("off", OpenXRRuntimePolicy.PERFORMANCE_HINT);
        Assertions.assertFalse(OpenXRRuntimePolicy.requestsDisplayRefreshRate());
        Assertions.assertFalse(OpenXRRuntimePolicy.requestsPerformanceLevel());
    }
}
