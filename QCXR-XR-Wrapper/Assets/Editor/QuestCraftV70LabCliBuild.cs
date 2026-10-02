using System;
using System.IO;
using System.Linq;

/// <summary>
/// Exact, fail-closed entry point for the isolated v71 Quest Lab APK. It can
/// never target Personal/Stable and refuses release signing.
/// </summary>
public static class QuestCraftV70LabCliBuild
{
    public const string ApplicationIdentifier = "com.qcxr.qcxr.canary262";
    public const string ProductName = "QuestCraft Vivecraft Lab 26.2";
    public const string VersionName = "6.0.1-26.2-vivecraft-personal.12-rc.2";
    public const string VersionCode = "71";
    public const string OutputPath =
        "Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.2-integrated-local.apk";

    public static void BuildAndroid()
    {
        RequireExact("-applicationIdentifier", ApplicationIdentifier);
        RequireExact("-productName", ProductName);
        RequireExact("-versionName", VersionName);
        RequireExact("-versionCode", VersionCode);
        RequireExact("-outputPath", OutputPath);
        if (HasArgument("-release"))
        {
            throw new InvalidOperationException("The v71 Lab canary must use the Debug signer.");
        }

        var normalizedOutput = OutputPath.Replace('/', Path.DirectorySeparatorChar);
        if (Path.IsPathRooted(normalizedOutput) || normalizedOutput.Contains(".."))
        {
            throw new InvalidOperationException("The v71 Lab output path escaped the project.");
        }

        QuestCraftCliBuild.BuildAndroid();
    }

    private static void RequireExact(string name, string expected)
    {
        var actual = GetArgument(name);
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"{name} must equal the fixed v71 Lab identity.");
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
