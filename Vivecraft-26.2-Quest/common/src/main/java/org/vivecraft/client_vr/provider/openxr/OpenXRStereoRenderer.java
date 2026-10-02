package org.vivecraft.client_vr.provider.openxr;

import com.mojang.blaze3d.GpuFormat;
import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.network.chat.Component;
import org.joml.Matrix4f;
import org.joml.Vector2i;
import org.joml.Vector2ic;
import org.lwjgl.PointerBuffer;
import org.lwjgl.openxr.*;
import org.lwjgl.system.MemoryStack;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRTextureTarget;
import org.vivecraft.client_vr.provider.VRRenderer;
import org.vivecraft.client_vr.render.RenderConfigException;
import org.vivecraft.client_vr.render.helpers.graphics.GraphicsHelper;
import org.vivecraft.client_vr.render.helpers.graphics.VulkanHelper;
import org.vivecraft.client_vr.settings.VRSettings;

import java.io.IOException;
import java.nio.IntBuffer;

public class OpenXRStereoRenderer extends VRRenderer {
    private final MCOpenXR openxr;
    private final int[] swapIndex = new int[]{0, 0};
    private final boolean[] imageAcquired = new boolean[2];
    private final boolean[] imageWaited = new boolean[2];
    private final XrCompositionLayerProjectionView.Buffer projectionLayerViews;
    private long[][] swapchainImages = new long[2][];
    private boolean recalculateProjectionMatrix = true;
    private long submittedFrameCount;

    public OpenXRStereoRenderer(MCOpenXR vr) {
        super(vr);
        this.openxr = vr;
        this.projectionLayerViews = XrCompositionLayerProjectionView.calloc(2);
    }

    @Override
    public void checkCapabilities() throws RenderConfigException {
        super.checkCapabilities();
        if (GraphicsHelper.INSTANCE instanceof VulkanHelper vulkan) {
            VRSettings settings = ClientDataHolderVR.getInstance().vrSettings;
            vulkan.checkExtensionSupport(
                DeviceCompat.splitExtensions(settings.requiredVulkanInstanceExtensions),
                DeviceCompat.splitExtensions(settings.requiredVulkanDeviceExtensions));
        }
    }

    @Override
    public void createRenderTexture(int width, int height) {
        for (int eye = 0; eye < 2; eye++) {
            this.framebufferEye[eye] = VRTextureTarget.builder((eye == 0 ? "L" : "R") + " Eye")
                .withSize(width, height)
                .withFormat(GpuFormat.RGBA8_UNORM)
                .build();
            VRSettings.LOGGER.info("Vivecraft: {}", this.framebufferEye[eye]);
            GraphicsHelper.INSTANCE.checkError((eye == 0 ? "Left" : "Right") + " Eye framebuffer setup");
        }

        try (MemoryStack stack = MemoryStack.stackPush()) {
            for (int eye = 0; eye < 2; eye++) {
                IntBuffer count = stack.callocInt(1);
                int result = XR10.xrEnumerateSwapchainImages(this.openxr.swapchain[eye], count, null);
                DeviceCompat.checkResult(result, "xrEnumerateSwapchainImages");
                this.swapchainImages[eye] = MCOpenXR.device.enumerateSwapchainImages(
                    this.openxr.swapchain[eye], count.get(0), stack);
            }
        }
        this.lastError = GraphicsHelper.INSTANCE.checkError("create OpenXR textures");
    }

    @Override
    public void setupRenderConfiguration() throws IOException, RenderConfigException {
        super.setupRenderConfiguration();
        if (this.openxr.frameBegun && this.openxr.shouldRender &&
            !this.imageAcquired[0] && !this.imageAcquired[1])
        {
            this.acquireSwapchainImages();
        } else if (this.openxr.frameBegun && this.openxr.shouldRender &&
            (this.imageAcquired[0] || this.imageAcquired[1]))
        {
            throw renderFailure("an OpenXR swapchain image is still outstanding from a failed frame");
        }
    }

    private void acquireSwapchainImages() throws RenderConfigException {
        Throwable failure = null;
        try (MemoryStack stack = MemoryStack.stackPush()) {
            for (int eye = 0; eye < 2; eye++) {
                IntBuffer index = stack.callocInt(1);
                int result = XR10.xrAcquireSwapchainImage(
                    this.openxr.swapchain[eye],
                    XrSwapchainImageAcquireInfo.calloc(stack).type(XR10.XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO),
                    index);
                requireSuccess(result, "xrAcquireSwapchainImage");
                this.swapIndex[eye] = index.get(0);
                // A successful acquire owns the image even if the following wait fails.
                this.imageAcquired[eye] = true;

                XrSwapchainImageWaitInfo waitInfo = XrSwapchainImageWaitInfo.calloc(stack)
                    .type(XR10.XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO)
                    .timeout(XR10.XR_INFINITE_DURATION);
                result = XR10.xrWaitSwapchainImage(this.openxr.swapchain[eye], waitInfo);
                if (result == XR10.XR_TIMEOUT_EXPIRED) {
                    // The timeout is infinite, but retry once if a runtime reports
                    // a spurious timeout. Release is illegal until wait succeeds.
                    result = XR10.xrWaitSwapchainImage(this.openxr.swapchain[eye], waitInfo);
                }
                requireSuccess(result, "xrWaitSwapchainImage");
                if (result == XR10.XR_TIMEOUT_EXPIRED) {
                    throw renderFailure("xrWaitSwapchainImage timed out");
                }
                this.imageWaited[eye] = true;

                XrCompositionLayerProjectionView projectionView = this.projectionLayerViews.get(eye)
                    .type(XR10.XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW)
                    .pose(this.openxr.viewBuffer.get(eye).pose())
                    .fov(this.openxr.viewBuffer.get(eye).fov());
                projectionView.subImage()
                    .swapchain(this.openxr.swapchain[eye])
                    .imageArrayIndex(0);
                projectionView.subImage().imageRect().offset().set(0, 0);
                projectionView.subImage().imageRect().extent().set(this.openxr.width, this.openxr.height);
            }
            this.recalculateProjectionMatrix = true;
        } catch (Throwable throwable) {
            failure = throwable;
        }

        if (failure != null) {
            try (MemoryStack stack = MemoryStack.stackPush()) {
                failure = this.releaseWaitedImages(stack, failure);
            }
            if (this.openxr.frameBegun) {
                try {
                    // setupRenderConfiguration throws before renderFrame's TAIL
                    // hook can run. Complete this frame with zero layers now;
                    // the caller will tear down/recreate the session if an
                    // acquired-but-unwaited image is still owned.
                    this.endFrame();
                } catch (Throwable endFrameFailure) {
                    failure = appendFailure(failure, endFrameFailure);
                }
            }
            rethrow(failure);
        }
    }

    @Override
    public Matrix4f getCachedProjectionMatrix(int eyeType, float nearClip, float farClip) {
        if (this.recalculateProjectionMatrix || this.lastFarClip != farClip) {
            this.eyeProj[0] = this.getProjectionMatrix(0, nearClip, farClip);
            this.eyeProj[1] = this.getProjectionMatrix(1, nearClip, farClip);
            this.lastFarClip = farClip;
            this.recalculateProjectionMatrix = false;
        }
        return this.eyeProj[eyeType];
    }

    @Override
    protected Matrix4f getProjectionMatrix(int eyeType, float nearClip, float farClip) {
        XrFovf fov = this.openxr.viewBuffer.get(eyeType).fov();
        return new Matrix4f().frustum(
            (float) Math.tan(fov.angleLeft()) * nearClip,
            (float) Math.tan(fov.angleRight()) * nearClip,
            (float) Math.tan(fov.angleDown()) * nearClip,
            (float) Math.tan(fov.angleUp()) * nearClip,
            nearClip,
            farClip,
            RenderSystem.getDevice().getDeviceInfo().isZZeroToOne());
    }

    @Override
    public void endFrame() throws RenderConfigException {
        if (!this.openxr.frameBegun) {
            return;
        }

        Throwable failure = null;
        try (MemoryStack stack = MemoryStack.stackPush()) {
            PointerBuffer layers = null;
            boolean completePair = this.imageAcquired[0] && this.imageWaited[0] &&
                this.imageAcquired[1] && this.imageWaited[1];
            boolean copiesSucceeded = false;
            if (this.openxr.shouldRender && completePair) {
                try {
                    for (int eye = 0; eye < 2; eye++) {
                        GraphicsHelper.INSTANCE.copyToExternalImage(
                            this.framebufferEye[eye].getColorTexture(),
                            this.swapchainImages[eye][this.swapIndex[eye]],
                            this.openxr.width,
                            this.openxr.height);
                    }
                    GraphicsHelper.INSTANCE.flush();
                    copiesSucceeded = true;
                } catch (Throwable throwable) {
                    failure = appendFailure(failure, throwable);
                }
            } else if (this.openxr.shouldRender &&
                (this.imageAcquired[0] || this.imageAcquired[1]))
            {
                failure = appendFailure(failure,
                    renderFailure("OpenXR frame has an incomplete acquired/waited image pair"));
            }

            // Release every image which completed xrWait, even when copy or a
            // different eye's release failed. An acquired-but-unwaited image
            // must remain tracked; OpenXR forbids releasing it before a
            // successful xrWaitSwapchainImage.
            failure = this.releaseWaitedImages(stack, failure);

            if (copiesSucceeded && failure == null &&
                !this.imageAcquired[0] && !this.imageAcquired[1])
            {
                XrCompositionLayerProjection projectionLayer = XrCompositionLayerProjection.calloc(stack)
                    .type(XR10.XR_TYPE_COMPOSITION_LAYER_PROJECTION)
                    .space(this.openxr.xrAppSpace)
                    .views(this.projectionLayerViews);
                layers = stack.callocPointer(1).put(0, projectionLayer.address());
            }

            try {
                int result = XR10.xrEndFrame(
                    this.openxr.session,
                    XrFrameEndInfo.calloc(stack)
                        .type(XR10.XR_TYPE_FRAME_END_INFO)
                        .displayTime(this.openxr.time)
                        .environmentBlendMode(XR10.XR_ENVIRONMENT_BLEND_MODE_OPAQUE)
                        .layers(layers));
                requireSuccess(result, "xrEndFrame");
                this.submittedFrameCount++;
                if (this.submittedFrameCount <= 5 || this.submittedFrameCount == 30 ||
                    this.submittedFrameCount == 120 || this.submittedFrameCount % 600 == 0)
                {
                    VRSettings.LOGGER.info(
                        "Vivecraft: OpenXR submitted frame {} predictedTime={} shouldRender={} projectionLayer={}",
                        this.submittedFrameCount,
                        this.openxr.time,
                        this.openxr.shouldRender,
                        layers != null);
                }
            } catch (Throwable throwable) {
                failure = appendFailure(failure, throwable);
            }
        } finally {
            this.openxr.frameBegun = false;
        }

        if (failure != null) {
            rethrow(failure);
        }
    }

    private Throwable releaseWaitedImages(MemoryStack stack, Throwable failure) {
        return releaseWaitedImages(
            this.imageAcquired,
            this.imageWaited,
            eye -> {
                int result = XR10.xrReleaseSwapchainImage(
                    this.openxr.swapchain[eye],
                    XrSwapchainImageReleaseInfo.calloc(stack)
                        .type(XR10.XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO));
                requireSuccess(result, "xrReleaseSwapchainImage[" + eye + "]");
            },
            failure);
    }

    /** Package-private failure coordinator so partial-eye cleanup is behavior-tested without a runtime. */
    static Throwable releaseWaitedImages(
        boolean[] acquired,
        boolean[] waited,
        SwapchainImageReleaser releaser,
        Throwable failure)
    {
        if (acquired.length != waited.length) {
            throw new IllegalArgumentException("acquired/waited state lengths differ");
        }
        for (int eye = 0; eye < acquired.length; eye++) {
            if (!acquired[eye] || !waited[eye]) {
                continue;
            }
            try {
                releaser.release(eye);
                acquired[eye] = false;
                waited[eye] = false;
            } catch (Throwable throwable) {
                failure = appendFailure(failure, throwable);
            }
        }
        return failure;
    }

    private static Throwable appendFailure(Throwable first, Throwable next) {
        if (first == null) {
            return next;
        }
        if (first != next) {
            first.addSuppressed(next);
        }
        return first;
    }

    private static RenderConfigException renderFailure(String message) {
        return new RenderConfigException(
            Component.literal("OpenXR error"), Component.literal(message));
    }

    private static void rethrow(Throwable failure) throws RenderConfigException {
        if (failure instanceof RenderConfigException renderConfigException) {
            throw renderConfigException;
        }
        if (failure instanceof RuntimeException runtimeException) {
            throw runtimeException;
        }
        if (failure instanceof Error error) {
            throw error;
        }
        throw new RuntimeException(failure);
    }

    @FunctionalInterface
    interface SwapchainImageReleaser {
        void release(int eye) throws RenderConfigException;
    }

    private static void requireSuccess(int result, String operation) throws RenderConfigException {
        if (result < XR10.XR_SUCCESS) {
            throw new RenderConfigException(
                Component.literal("OpenXR error"),
                Component.literal(operation + " failed with result " + result));
        }
    }

    @Override
    public boolean providesStencilMask() {
        return false;
    }

    @Override
    public String getName() {
        return MCOpenXR.device.isVulkan() ? "OpenXR Vulkan" : "OpenXR OpenGL ES";
    }

    @Override
    public Vector2ic getRenderTextureSizes() {
        return new Vector2i(this.openxr.width, this.openxr.height);
    }

    @Override
    public void destroy() {
        super.destroy();
        this.projectionLayerViews.close();
        this.swapchainImages = new long[2][];
    }
}
