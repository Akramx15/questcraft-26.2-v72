package org.questcraft.veq.client.compat;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

/** Host regression for MC 26.2's pre-component-bind startup window. */
public final class DeferredUtilityIconSelfTest {
    private DeferredUtilityIconSelfTest() {
    }

    public static void main(String[] args) {
        AtomicBoolean componentsBound = new AtomicBoolean(false);
        AtomicInteger constructions = new AtomicInteger();
        Object fallback = new Object();
        Object resolved = new Object();
        Supplier<Object> icon = VepUtilityActionRegistry.deferUntilReady(
                componentsBound::get,
                () -> {
                    constructions.incrementAndGet();
                    return resolved;
                },
                fallback
        );

        require(icon.get() == fallback, "pre-bind lookup did not return the safe fallback");
        require(icon.get() == fallback, "repeated pre-bind lookup changed state");
        require(constructions.get() == 0, "icon was constructed before components were bound");

        componentsBound.set(true);
        require(icon.get() == resolved, "icon did not resolve after components became ready");
        require(icon.get() == resolved, "resolved icon was not cached");
        require(constructions.get() == 1, "icon factory was not called exactly once");
        System.out.println("DeferredUtilityIconSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
