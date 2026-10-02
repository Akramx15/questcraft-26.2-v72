package org.questcraft.veq.client.gui;

/** Host-only guard against vanilla -999/THROW on VEP's extended UI bounds. */
public final class VepExtendedContainerInputSelfTest {
    private VepExtendedContainerInputSelfTest() {
    }

    public static void main(String[] args) {
        int panelX = 123;
        int panelY = 57;
        int panelWidth = 258;
        int panelHeight = 166;
        int interactionX = 13;
        int interactionY = 40;
        int interactionWidth = 490;
        int interactionHeight = 200;

        require(!VepExtendedContainerInput.isOutside(
                        20, 48, interactionX, interactionY, interactionWidth, interactionHeight),
                "quick-action/status extension is not an outside click");
        require(!VepExtendedContainerInput.isOutside(
                        450, 80, interactionX, interactionY, interactionWidth, interactionHeight),
                "effect extension is not an outside click");
        require(!VepExtendedContainerInput.isOutside(
                        502, 239, interactionX, interactionY, interactionWidth, interactionHeight),
                "inclusive first/exclusive last bounds preserve the final pixel");
        require(VepExtendedContainerInput.isOutside(
                        503, 239, interactionX, interactionY, interactionWidth, interactionHeight),
                "the first pixel beyond interaction bounds stays outside");

        require(VepExtendedContainerInput.isExtendedArea(
                        20, 48,
                        panelX, panelY, panelWidth, panelHeight,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "status/quick-action extension must be consumed");
        require(VepExtendedContainerInput.isExtendedArea(
                        450, 80,
                        panelX, panelY, panelWidth, panelHeight,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "effect extension must be consumed");
        require(!VepExtendedContainerInput.isExtendedArea(
                        200, 100,
                        panelX, panelY, panelWidth, panelHeight,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "native slots must continue to vanilla");
        require(!VepExtendedContainerInput.isExtendedArea(
                        600, 100,
                        panelX, panelY, panelWidth, panelHeight,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "a true outside click must not be consumed by the extension guard");
        require(VepExtendedContainerInput.isOutside(
                        Double.NaN, 80,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "non-finite coordinates fail closed");

        require(!VepExtendedContainerInput.retainVanillaOutside(
                        true,
                        450, 80,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "Creative extensions suppress Vanilla's outside result");
        require(VepExtendedContainerInput.retainVanillaOutside(
                        true,
                        600, 100,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "a true Creative outside click retains Vanilla drop semantics");
        require(!VepExtendedContainerInput.retainVanillaOutside(
                        false,
                        600, 100,
                        interactionX, interactionY, interactionWidth, interactionHeight),
                "the guard never invents an outside click rejected by Vanilla");

        VepExtendedContainerInput.CreativeOutsideDecision extensionDecision =
                VepExtendedContainerInput.creativeOutsideDecision(
                        true,
                        450, 80,
                        interactionX, interactionY, interactionWidth, interactionHeight);
        require(!extensionDecision.outside() && !extensionDecision.creativeLatch(),
                "Creative extension release must clear the private outside latch");
        VepExtendedContainerInput.CreativeOutsideDecision outsideDecision =
                VepExtendedContainerInput.creativeOutsideDecision(
                        true,
                        600, 100,
                        interactionX, interactionY, interactionWidth, interactionHeight);
        require(outsideDecision.outside() && outsideDecision.creativeLatch(),
                "true Creative outside release must retain drop semantics");
        VepExtendedContainerInput.CreativeOutsideDecision tabDecision =
                VepExtendedContainerInput.creativeOutsideDecision(
                        false,
                        600, 100,
                        interactionX, interactionY, interactionWidth, interactionHeight);
        require(!tabDecision.outside() && !tabDecision.creativeLatch(),
                "a tab rejected by Vanilla must keep the Creative latch clear");
        System.out.println("VepExtendedContainerInputSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
