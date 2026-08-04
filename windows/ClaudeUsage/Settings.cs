using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace ClaudeUsage;

internal sealed class Settings
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "ClaudeUsage";

    public bool BatteryMode { get; set; } = true;

    /// <summary>The <c>kind</c> of the limit drawn on the tray icon.</summary>
    public string TrayLimitKind { get; set; } = DefaultTrayLimitKind;

    private const string DefaultTrayLimitKind = "five_hour";

    public int RefreshSeconds { get; set; } = 60;

    /// <summary>Whether the reminder was already shown for the current unstarted five-hour window.</summary>
    [JsonPropertyName("loggedNotification")]
    public bool LoggedNotification { get; set; }

    /// <summary>
    /// The last organization UUID that worked. Not a cookie or a session key; it keeps the app
    /// showing the same account's usage after a restart instead of falling back to another one.
    /// </summary>
    public string? LastOrganizationId { get; set; }

    /// <summary>Whether the always-on-screen pet + bar window is open.</summary>
    public bool OverlayVisible { get; set; }

    /// <summary>Last overlay position. -1 means it was never moved, so it goes to the bottom right.</summary>
    public int OverlayX { get; set; } = -1;

    public int OverlayY { get; set; } = -1;

    [JsonIgnore]
    public static string DataDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "ClaudeUsage");

    [JsonIgnore]
    private static string FilePath => Path.Combine(DataDirectory, "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var loaded = JsonSerializer.Deserialize(
                    File.ReadAllText(FilePath),
                    SettingsJsonContext.Default.Settings);
                if (loaded is not null)
                {
                    loaded.RefreshSeconds = Math.Clamp(loaded.RefreshSeconds, 2, 3600);
                    // "session" is the old name; the API returns the five-hour window as "five_hour".
                    if (string.IsNullOrWhiteSpace(loaded.TrayLimitKind) ||
                        string.Equals(loaded.TrayLimitKind, "session", StringComparison.OrdinalIgnoreCase))
                    {
                        loaded.TrayLimitKind = DefaultTrayLimitKind;
                    }
                    return loaded;
                }
            }
        }
        catch
        {
            // A corrupt settings file falls back to the defaults.
        }

        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, SettingsJsonContext.Default.Settings));
        }
        catch
        {
            // The app keeps running even if settings can't be written.
        }
    }

    public static bool IsRegisteredForStartup()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(RunValueName) is not null;
    }

    public static void SetStartupRegistration(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        if (key is null) return;

        if (!enabled)
        {
            key.DeleteValue(RunValueName, throwOnMissingValue: false);
            return;
        }

        string? executable = Environment.ProcessPath;
        if (string.IsNullOrEmpty(executable)) return;
        key.SetValue(RunValueName, $"\"{executable}\"");
    }
}

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower)]
[JsonSerializable(typeof(Settings))]
internal sealed partial class SettingsJsonContext : JsonSerializerContext;
