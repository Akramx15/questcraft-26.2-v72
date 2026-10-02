using System;
using System.IO;
using System.Linq;

/// <summary>
/// Fail-closed entry point for the isolated v69 Quest canary APK. The regular
/// Personal builder remains unchanged; this method refuses to delegate unless
/// every identity-bearing argument is the exact Lab value and the build is
/// Debug. The normal builder is also Lab-pinned on this branch. This prevents
/// the canary source tree from accidentally producing an
/// APK that can update the accepted Personal package.
/// </summary>
public static class QuestCraftLabCliBuild
{
    public const string ApplicationIdentifier = "com.qcxr.qcxr.canary262";
    public const string ProductName = "QuestCraft Vivecraft Lab 26.2";
    public const string VersionName = "6.0.1-26.2-vivecraft-personal.10-rc.1";
    public const string VersionCode = "69";
    public const string OutputPath =
        "Builds/QuestCraft-Vivecraft-Lab-26.2-v69-rc.1-local.apk";

    public static void BuildAndroid()
    {
        RequireExact("-applicationIdentifier", ApplicationIdentifier);
        RequireExact("-productName", ProductName);
        RequireExact("-versionName", VersionName);
        RequireExact("-versionCode", VersionCode);
        RequireExact("-outputPath", OutputPath);
        if (HasArgument("-release"))
        {
            throw new InvalidOperationException("The Lab canary must use the Debug signer.");
        }

        var normalizedOutput = OutputPath.Replace('/', Path.DirectorySeparatorChar);
        if (Path.IsPathRooted(normalizedOutput) || normalizedOutput.Contains(".."))
        {
            throw new InvalidOperationException("The Lab output path escaped the project.");
        }

        QuestCraftCliBuild.BuildAndroid();
    }

    private static void RequireExact(string name, string expected)
    {
        var actual = GetArgument(name);
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"{name} must equal the fixed Lab identity.");
        }
    }

    private static string GetArgument(string name)
    {
        var args = Environment.GetCommandLineArgs();
        for (var index = 0; index < args.Length - 1; index++)
        {
            if (args[index].Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }
        return null;
    }

    private static bool HasArgument(string name)
    {
        return Environment.GetCommandLineArgs()
            .Any(argument => argument.Equals(name, StringComparison.OrdinalIgnoreCase));
    }
}
