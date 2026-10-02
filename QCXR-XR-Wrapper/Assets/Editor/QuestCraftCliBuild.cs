using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;

public static class QuestCraftCliBuild
{
    private const string DefaultApplicationIdentifier = "com.qcxr.qcxr.canary262";
    private const string DefaultProductName = "QuestCraft Vivecraft Lab 26.2";
    private const string DefaultVersionName = "6.0.1-26.2-vivecraft-personal.12-rc.4";
    private const int DefaultVersionCode = 71;
    private const string DefaultOutputPath =
        "Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.4-integrated-local.apk";
    private const string AcceptedPersonalApplicationIdentifier = "com.qcxr.qcxr.dev262";
    private const string AcceptedPersonalProductName = "Vivecraft Stable";
    private const string PersonalV69VersionName =
        "6.0.1-26.2-vivecraft-personal.10";
    private const int PersonalV69VersionCode = 69;
    private const string PersonalV69OutputPath =
        "Builds/QuestCraft-Vivecraft-26.2-personal.10-local.apk";
    private const string PersonalV71VersionName =
        "6.0.1-26.2-vivecraft-personal.12";
    private const int PersonalV71VersionCode = 71;
    private const string PersonalV71OutputPath =
        "Builds/QuestCraft-Vivecraft-26.2-personal.12-local.apk";
    private const string PersonalV72VersionName =
        "6.0.1-26.2-vivecraft-personal.13";
    private const int PersonalV72VersionCode = 72;
    private const string PersonalV72OutputPath =
        "Builds/QuestCraft-Vivecraft-26.2-personal.13-local.apk";

    private enum PersonalBuildIdentity
    {
        None,
        V69,
        V71,
        V72
    }

    public static void BuildAndroid()
    {
        BuildAndroidInternal(PersonalBuildIdentity.None);
    }

    /// <summary>
    /// Exact, non-parameterizable Personal v69 build target. This stays
    /// internal so Unity's public CLI entry point cannot use it to build an
    /// arbitrary package over the accepted Personal installation.
    /// </summary>
    internal static void BuildAcceptedPersonalV69Android()
    {
        BuildAndroidInternal(PersonalBuildIdentity.V69);
    }

    /// <summary>
    /// Exact, non-parameterizable Personal v71 build target. Only the dedicated
    /// v71 entry point can call this path; the ordinary Lab entry point remains
    /// unable to target the installed Personal package.
    /// </summary>
    internal static void BuildAcceptedPersonalV71Android()
    {
        BuildAndroidInternal(PersonalBuildIdentity.V71);
    }

    /// <summary>Exact seed-only Personal v72 build target.</summary>
    internal static void BuildAcceptedPersonalV72Android()
    {
        BuildAndroidInternal(PersonalBuildIdentity.V72);
    }

    private static void BuildAndroidInternal(PersonalBuildIdentity personalIdentity)
    {
        var outputPath = GetArgument("-outputPath") ?? DefaultOutputPath;
        var releaseBuild = HasArgument("-release");
        var applicationIdentifier = GetArgument("-applicationIdentifier") ?? DefaultApplicationIdentifier;
        var productName = GetArgument("-productName") ?? DefaultProductName;
        var versionName = GetArgument("-versionName") ?? DefaultVersionName;
        var versionCodeArgument = GetArgument("-versionCode");
        var versionCode = DefaultVersionCode;
        if (versionCodeArgument != null &&
            (!int.TryParse(versionCodeArgument, out versionCode) || versionCode <= 0))
        {
            throw new InvalidOperationException("-versionCode must be a positive integer.");
        }
        var outputDirectory = Path.GetDirectoryName(outputPath);
        if (!string.IsNullOrEmpty(outputDirectory))
        {
            Directory.CreateDirectory(outputDirectory);
        }

        EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android, BuildTarget.Android);
        var previousAndroidBuildType = EditorUserBuildSettings.androidBuildType;
        var previousAndroidBuildSystem = EditorUserBuildSettings.androidBuildSystem;
        var previousBuildAppBundle = EditorUserBuildSettings.buildAppBundle;
        var previousUseCustomKeystore = PlayerSettings.Android.useCustomKeystore;
        var previousKeystoreName = PlayerSettings.Android.keystoreName;
        var previousKeystorePass = PlayerSettings.Android.keystorePass;
        var previousKeyaliasName = PlayerSettings.Android.keyaliasName;
        var previousKeyaliasPass = PlayerSettings.Android.keyaliasPass;
        var previousApplicationIdentifier = PlayerSettings.GetApplicationIdentifier(BuildTargetGroup.Android);
        var previousProductName = PlayerSettings.productName;
        var previousVersionName = PlayerSettings.bundleVersion;
        var previousVersionCode = PlayerSettings.Android.bundleVersionCode;

        try
        {
            EditorUserBuildSettings.androidBuildSystem = AndroidBuildSystem.Gradle;
            EditorUserBuildSettings.buildAppBundle = false;

            RequireValue(applicationIdentifier, "-applicationIdentifier cannot be empty.");
            RequireValue(productName, "-productName cannot be empty.");
            RequireValue(versionName, "-versionName cannot be empty.");
            if (personalIdentity != PersonalBuildIdentity.None)
            {
                var expectedVersionName = PersonalV69VersionName;
                var expectedVersionCode = PersonalV69VersionCode;
                var expectedOutputPath = PersonalV69OutputPath;
                var identityLabel = "Personal v69";
                if (personalIdentity == PersonalBuildIdentity.V71)
                {
                    expectedVersionName = PersonalV71VersionName;
                    expectedVersionCode = PersonalV71VersionCode;
                    expectedOutputPath = PersonalV71OutputPath;
                    identityLabel = "Personal v71";
                }
                else if (personalIdentity == PersonalBuildIdentity.V72)
                {
                    expectedVersionName = PersonalV72VersionName;
                    expectedVersionCode = PersonalV72VersionCode;
                    expectedOutputPath = PersonalV72OutputPath;
                    identityLabel = "Personal v72";
                }

                RequireExact(applicationIdentifier, AcceptedPersonalApplicationIdentifier,
                    $"-applicationIdentifier must equal the fixed {identityLabel} identity.");
                RequireExact(productName, AcceptedPersonalProductName,
                    $"-productName must equal the fixed {identityLabel} identity.");
                RequireExact(versionName, expectedVersionName,
                    $"-versionName must equal the fixed {identityLabel} identity.");
                if (versionCode != expectedVersionCode)
                {
                    throw new InvalidOperationException(
                        $"-versionCode must equal the fixed {identityLabel} identity.");
                }
                RequireExact(NormalizeRelativePath(outputPath),
                    NormalizeRelativePath(expectedOutputPath),
                    $"-outputPath must equal the fixed {identityLabel} identity.");
                if (releaseBuild)
                {
                    throw new InvalidOperationException(
                        $"{identityLabel} must use the existing local Debug signer.");
                }
            }
            else if (applicationIdentifier.Equals(
                         AcceptedPersonalApplicationIdentifier, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "This Lab branch refuses to build over the accepted Personal package.");
            }
            PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.Android, applicationIdentifier);
            PlayerSettings.productName = productName;
            PlayerSettings.bundleVersion = versionName;
            PlayerSettings.Android.bundleVersionCode = versionCode;

            if (releaseBuild)
            {
                var keystorePath = GetArgument("-keystorePath") ?? Environment.GetEnvironmentVariable("QCXR_KEYSTORE_PATH");
                // Never accept passwords as command-line arguments: Unity echoes
                // its command line into build logs and process listings.
                var keystorePass = Environment.GetEnvironmentVariable("QCXR_KEYSTORE_PASS");
                var keyaliasName = GetArgument("-keyaliasName")
                    ?? Environment.GetEnvironmentVariable("QCXR_KEYALIAS_NAME")
                    ?? "qcxr";
                var keyaliasPass = Environment.GetEnvironmentVariable("QCXR_KEYALIAS_PASS")
                    ?? keystorePass;

                RequireValue(keystorePath, "Release build requires -keystorePath or QCXR_KEYSTORE_PATH.");
                RequireValue(keystorePass, "Release build requires QCXR_KEYSTORE_PASS.");
                RequireValue(keyaliasName, "Release build requires -keyaliasName or QCXR_KEYALIAS_NAME.");
                RequireValue(keyaliasPass, "Release build requires QCXR_KEYALIAS_PASS or QCXR_KEYSTORE_PASS.");

                EditorUserBuildSettings.androidBuildType = AndroidBuildType.Release;
                PlayerSettings.Android.useCustomKeystore = true;
                PlayerSettings.Android.keystoreName = keystorePath;
                PlayerSettings.Android.keystorePass = keystorePass;
                PlayerSettings.Android.keyaliasName = keyaliasName;
                PlayerSettings.Android.keyaliasPass = keyaliasPass;
            }
            else
            {
                EditorUserBuildSettings.androidBuildType = AndroidBuildType.Debug;
                PlayerSettings.Android.useCustomKeystore = false;
                PlayerSettings.Android.keystoreName = string.Empty;
                PlayerSettings.Android.keystorePass = string.Empty;
                PlayerSettings.Android.keyaliasName = string.Empty;
                PlayerSettings.Android.keyaliasPass = string.Empty;
            }

            var scenes = EditorBuildSettings.scenes
                .Where(scene => scene.enabled)
                .Select(scene => scene.path)
                .ToArray();

            if (scenes.Length == 0)
            {
                throw new InvalidOperationException("No enabled scenes found in EditorBuildSettings.");
            }

            var options = new BuildPlayerOptions
            {
                scenes = scenes,
                locationPathName = outputPath,
                target = BuildTarget.Android,
                targetGroup = BuildTargetGroup.Android,
                options = BuildOptions.None
            };

            var report = BuildPipeline.BuildPlayer(options);
            if (report.summary.result != BuildResult.Succeeded)
            {
                throw new InvalidOperationException(
                    $"Android build failed: {report.summary.result} with {report.summary.totalErrors} errors.");
            }
        }
        finally
        {
            EditorUserBuildSettings.androidBuildType = previousAndroidBuildType;
            EditorUserBuildSettings.androidBuildSystem = previousAndroidBuildSystem;
            EditorUserBuildSettings.buildAppBundle = previousBuildAppBundle;
            PlayerSettings.Android.useCustomKeystore = previousUseCustomKeystore;
            PlayerSettings.Android.keystoreName = previousKeystoreName;
            PlayerSettings.Android.keystorePass = previousKeystorePass;
            PlayerSettings.Android.keyaliasName = previousKeyaliasName;
            PlayerSettings.Android.keyaliasPass = previousKeyaliasPass;
            PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.Android, previousApplicationIdentifier);
            PlayerSettings.productName = previousProductName;
            PlayerSettings.bundleVersion = previousVersionName;
            PlayerSettings.Android.bundleVersionCode = previousVersionCode;
        }
    }

    private static string GetArgument(string name)
    {
        var args = Environment.GetCommandLineArgs();
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i].Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }

        return null;
    }

    private static bool HasArgument(string name)
    {
        return Environment.GetCommandLineArgs()
            .Any(arg => arg.Equals(name, StringComparison.OrdinalIgnoreCase));
    }

    private static void RequireValue(string value, string message)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void RequireExact(string actual, string expected, string message)
    {
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(message);
        }
    }

    private static string NormalizeRelativePath(string path)
    {
        var normalized = path.Replace('\\', '/');
        if (Path.IsPathRooted(normalized) || normalized.Split('/').Contains(".."))
        {
            throw new InvalidOperationException("The build output path escaped the project.");
        }
        return normalized;
    }
}
