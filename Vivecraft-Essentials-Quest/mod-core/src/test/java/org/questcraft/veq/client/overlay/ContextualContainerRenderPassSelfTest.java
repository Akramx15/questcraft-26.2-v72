package org.questcraft.veq.client.overlay;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/** Host-only proof that contextual pointer composition extracts carried exactly once. */
public final class ContextualContainerRenderPassSelfTest {
    private ContextualContainerRenderPassSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        Object screen = new Object();
        Object otherScreen = new Object();
        List<String> order = new ArrayList<>();
        int[] carriedCalls = {0};

        ContextualContainerRenderPass.withCarriedDeferred(screen, () -> {
            order.add("base");
            require(ContextualContainerRenderPass.isCarriedDeferred(screen),
                    "the exact base screen must defer its carried extraction");
            require(!ContextualContainerRenderPass.isCarriedDeferred(otherScreen),
                    "the render scope must not suppress another screen");
            if (!ContextualContainerRenderPass.isCarriedDeferred(screen)) {
                order.add("carried");
                carriedCalls[0]++;
            }
        });
        order.add("pointer");
        order.add("carried");
        carriedCalls[0]++;

        require(order.equals(List.of("base", "pointer", "carried")),
                "contextual order must be base, pointer, then one carried extraction: " + order);
        require(carriedCalls[0] == 1,
                "contextual carried item must be extracted exactly once");
        require(!ContextualContainerRenderPass.isCarriedDeferred(screen),
                "the carried deferral scope leaked after a normal render");

        try {
            ContextualContainerRenderPass.withCarriedDeferred(screen, () -> {
                throw new ExpectedFailure();
            });
            throw new AssertionError("expected render failure was not propagated");
        } catch (ExpectedFailure expected) {
            require(!ContextualContainerRenderPass.isCarriedDeferred(screen),
                    "the carried deferral scope leaked after an exceptional render");
        }

        String pointer = Files.readString(sourcePath(
                "src/main/java/org/questcraft/veq/client/overlay/"
                        + "VepSurfacePointerRenderer.java"
        ));
        String pointerDraw = "render(graphics, pointerPosition.x(), pointerPosition.y(),";
        String carriedDraw = "screen.extractCarriedItem(";
        require(occurrences(pointer, carriedDraw) == 1,
                "the production contextual compositor must extract carried exactly once");
        require(pointer.indexOf(pointerDraw) >= 0
                        && pointer.indexOf(carriedDraw) > pointer.indexOf(pointerDraw),
                "the production contextual compositor must draw '+' before carried");

        String runtime = Files.readString(sourcePath(
                "src/main/java/org/questcraft/veq/client/overlay/"
                        + "VepContextualContainerRuntime.java"
        ));
        require(runtime.contains("ContextualContainerRenderPass.withCarriedDeferred("),
                "contextual base rendering must enter the carried-deferral scope");

        String mixin = Files.readString(sourcePath(
                "src/main/java/org/questcraft/veq/mixin/EmbeddedContainerScreenMixin.java"
        ));
        require(mixin.contains("@Inject(method = \"extractCarriedItem\"")
                        && mixin.contains(
                        "ContextualContainerRenderPass.isCarriedDeferred(this)"),
                "the first carried extraction must be suppressed only by the exact scope");

        System.out.println("ContextualContainerRenderPassSelfTest PASS");
    }

    private static int occurrences(String source, String token) {
        int count = 0;
        int offset = 0;
        while ((offset = source.indexOf(token, offset)) >= 0) {
            count++;
            offset += token.length();
        }
        return count;
    }

    private static Path sourcePath(String relative) {
        Path direct = Path.of(relative);
        if (Files.isRegularFile(direct)) {
            return direct;
        }
        Path fromRoot = Path.of("Vivecraft-Essentials-Quest", "mod-core")
                .resolve(relative);
        if (Files.isRegularFile(fromRoot)) {
            return fromRoot;
        }
        throw new IllegalStateException("Could not locate source contract: " + relative);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static final class ExpectedFailure extends RuntimeException {
    }
}
