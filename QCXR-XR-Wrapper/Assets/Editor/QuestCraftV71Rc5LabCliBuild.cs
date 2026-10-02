using System;
using System.IO;
using System.Linq;

/// <summary>
/// Exact, fail-closed entry point for the persistent v71 RC5.2 Quest Lab APK.
/// The historical RC4 entry point remains unchanged and this target can never
/// select the Personal/Stable package or release signing.
/// </summary>
public static class QuestCraftV71Rc5LabCliBuild
{
    public const string ApplicationIdentifier = "com.qcxr.qcxr.canary262";
    public const string ProductName = "QuestCraft Vivecraft Lab 26.2";
    public const string VersionName = "6.0.1-26.2-vivecraft-personal.12-rc.5.2";
    public const string VersionCode = "71";
    public const string OutputPath =
        "Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.5.2-integrated-local.apk";

    public static void BuildAndroid()
    {
        RequireExact("-applicationIdentifier", ApplicationIdentifier);
        RequireExact("-productName", ProductName);
        RequireExact("-versionName", VersionName);
        RequireExact("-versionCode", VersionCode);
        RequireExact("-outputPath", OutputPath);
        if (HasArgument("-release"))
        {
            throw new InvalidOperationException("The v71 RC5 Lab must use the Debug signer.");
        }

        var normalizedOutput = OutputPath.Replace('/', Path.DirectorySeparatorChar);
        if (Path.IsPathRooted(normalizedOutput) || normalizedOutput.Contains(".."))
        {
            throw new InvalidOperationException("The v71 RC5 Lab output path escaped the project.");
        }

        QuestCraftCliBuild.BuildAndroid();
    }

    private static void RequireExact(string name, string expected)
    {
        var actual = GetArgument(name);
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"{name} must equal the fixed v71 RC5 Lab identity.");
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
