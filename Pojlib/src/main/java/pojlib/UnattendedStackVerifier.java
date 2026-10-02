package pojlib;

import android.app.Activity;

import com.google.gson.Gson;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;

import pojlib.util.json.MinecraftInstances;
import pojlib.util.json.ModsJson;
import pojlib.util.json.ProjectInfo;

/**
 * Verifies every APK-bundled managed artifact against the installed profile.
 * This intentionally ignores disabledMods: unattended benchmarks require the
 * exact locked core + default stack, while normal manual launches remain free
 * to honor the user's durable disabled list.
 */
public final class UnattendedStackVerifier {
    private static final String PROFILE = "26.2";
    private static final String VERSION = "26.2";

    private UnattendedStackVerifier() {
    }

    public static boolean verify(Activity activity, MinecraftInstances.Instance instance) {
        boolean coreCanaryPermitPresent = VivecraftCoreCanaryGate.hasProcessPermit();
        boolean veqCanaryPermitPresent = VeqCanaryGate.hasProcessPermit();
        boolean modsAbCanaryPermitPresent = ModsAbCanaryGate.hasProcessPermit();
        boolean verified = false;
        if(activity == null || instance == null ||
                !PROFILE.equals(instance.instanceName) || !VERSION.equals(instance.versionName) ||
                instance.gameDir == null) {
            if(coreCanaryPermitPresent) {
                VivecraftCoreCanaryGate.abortPromotedCandidate();
            }
            if(veqCanaryPermitPresent) {
                VeqCanaryGate.abortPromotedCandidate();
            }
            if(modsAbCanaryPermitPresent) {
                ModsAbCanaryGate.abortPromotedCandidate();
            }
            return false;
        }

        try(InputStream stream = activity.getAssets().open("mods.json");
                InputStreamReader reader = new InputStreamReader(stream, StandardCharsets.UTF_8)) {
            ModsJson manifest = new Gson().fromJson(reader, ModsJson.class);
            if(manifest == null || manifest.versions == null) {
                return false;
            }
            for(ModsJson.Version version : manifest.versions) {
                if(version == null || !VERSION.equals(version.name) ||
                        version.coreMods == null || version.coreMods.length < 2 ||
                        version.defaultMods == null || version.defaultMods.length == 0) {
                    continue;
                }
                for(ProjectInfo project : version.coreMods) {
                    if(!verifyProject(instance, project)) {
                        return false;
                    }
                }
                for(ProjectInfo project : version.defaultMods) {
                    if(!verifyProject(instance, project)) {
                        return false;
                    }
                }
                verified = true;
                return true;
            }
        } catch(IOException | RuntimeException ignored) {
            return false;
        } finally {
            if(coreCanaryPermitPresent && !verified) {
                VivecraftCoreCanaryGate.abortPromotedCandidate();
            }
            if(veqCanaryPermitPresent && !verified) {
                VeqCanaryGate.abortPromotedCandidate();
            }
            if(modsAbCanaryPermitPresent && !verified) {
                ModsAbCanaryGate.abortPromotedCandidate();
            }
        }
        return false;
    }

    private static boolean verifyProject(MinecraftInstances.Instance instance, ProjectInfo project)
            throws IOException {
        if(project == null || project.slug == null || project.sha256 == null ||
                !project.sha256.matches("(?i)^[0-9a-f]{64}$")) {
            return false;
        }
        String baseName = project.fileName == null ? project.slug : project.fileName;
        File artifact = new File(instance.gameDir + "/mods", baseName + ".jar");
        if("Vivecraft".equals(project.slug) && VivecraftCoreCanaryGate.hasProcessPermit()) {
            return VivecraftCoreCanaryGate.verifyVivecraftArtifact(instance, project, artifact);
        }
        if("Vivecraft-Essentials-Quest".equals(project.slug) &&
                VeqCanaryGate.hasProcessPermit()) {
            return VeqCanaryGate.verifyVeqArtifact(instance, project, artifact);
        }
        if(ModsAbCanaryGate.handlesProject(project)) {
            return ModsAbCanaryGate.verifyManagedArtifact(instance, project, artifact);
        }
        return artifact.isFile() && project.sha256.equalsIgnoreCase(sha256(artifact));
    }

    private static String sha256(File file) throws IOException {
        try(FileInputStream input = new FileInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[64 * 1024];
            int read;
            while((read = input.read(buffer)) != -1) {
                digest.update(buffer, 0, read);
            }
            StringBuilder value = new StringBuilder(64);
            for(byte b : digest.digest()) {
                value.append(String.format(Locale.ROOT, "%02x", b & 0xff));
            }
            return value.toString();
        } catch(NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is unavailable", e);
        }
    }
}
