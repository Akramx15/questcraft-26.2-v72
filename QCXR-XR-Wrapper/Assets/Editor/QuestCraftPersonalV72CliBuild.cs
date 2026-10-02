using System;
using System.IO;
using System.Linq;

/// <summary>
/// Fail-closed Unity entry point for the seed-only Personal v72 identity.
/// </summary>
public static class QuestCraftPersonalV72CliBuild
{
    public const string ApplicationIdentifier = "com.qcxr.qcxr.dev262";
    public const string ProductName = "Vivecraft Stable";
    public const string VersionName = "6.0.1-26.2-vivecraft-personal.13";
    public const string VersionCode = "72";
    public const string OutputPath =
        "Builds/QuestCraft-Vivecraft-26.2-personal.13-local.apk";

    public static void BuildAndroid()
    {
        RequireExact("-applicationIdentifier", ApplicationIdentifier);
        RequireExact("-productName", ProductName);
        RequireExact("-versionName", VersionName);
        RequireExact("-versionCode", VersionCode);
        RequireExact("-outputPath", OutputPath);
        if (HasArgument("-release"))
        {
            throw new InvalidOperationException(
                "Personal v72 must use the existing local Debug signer.");
        }

        var normalizedOutput = OutputPath.Replace('/', Path.DirectorySeparatorChar);
        if (Path.IsPathRooted(normalizedOutput) || normalizedOutput.Contains(".."))
        {
            throw new InvalidOperationException("The Personal v72 output path escaped the project.");
        }

        QuestCraftCliBuild.BuildAcceptedPersonalV72Android();
    }

    private static void RequireExact(string name, string expected)
    {
        var actual = GetArgument(name);
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"{name} must equal the fixed Personal v72 identity.");
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
