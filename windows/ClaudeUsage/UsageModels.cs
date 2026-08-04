using System.Drawing;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClaudeUsage;

// ------------------------------------------------------------------- DTOs

internal sealed class UsageResponse
{
    [JsonPropertyName("five_hour")]
    public UsageWindow? FiveHour { get; set; }

    [JsonPropertyName("seven_day")]
    public UsageWindow? SevenDay { get; set; }

    [JsonPropertyName("seven_day_opus")]
    public UsageWindow? SevenDayOpus { get; set; }

    [JsonPropertyName("seven_day_sonnet")]
    public UsageWindow? SevenDaySonnet { get; set; }

    [JsonPropertyName("seven_day_oauth_apps")]
    public UsageWindow? SevenDayOauthApps { get; set; }

    [JsonPropertyName("seven_day_cowork")]
    public UsageWindow? SevenDayCowork { get; set; }

    [JsonPropertyName("seven_day_omelette")]
    public UsageWindow? SevenDayOmelette { get; set; }

    [JsonPropertyName("limits")]
    public List<UsageLimit>? Limits { get; set; }

    [JsonPropertyName("spend")]
    public UsageSpend? Spend { get; set; }
}

internal sealed class UsageWindow
{
    [JsonPropertyName("utilization")]
    public double? Utilization { get; set; }

    [JsonPropertyName("resets_at")]
    public string? ResetsAt { get; set; }
}

internal sealed class UsageLimit
{
    [JsonPropertyName("kind")]
    public string? Kind { get; set; }

    [JsonPropertyName("percent")]
    public double? Percent { get; set; }

    [JsonPropertyName("resets_at")]
    public string? ResetsAt { get; set; }
}

internal sealed class UsageSpend
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; }

    [JsonPropertyName("used")]
    public UsageAmount? Used { get; set; }
}

internal sealed class UsageAmount
{
    [JsonPropertyName("amount_minor")]
    public long AmountMinor { get; set; }

    [JsonPropertyName("exponent")]
    public int Exponent { get; set; }

    [JsonPropertyName("currency")]
    public string? Currency { get; set; }
}

internal sealed class Organization
{
    [JsonPropertyName("uuid")]
    public string? Uuid { get; set; }

    [JsonPropertyName("id")]
    public JsonElement Id { get; set; }

    [JsonPropertyName("organization_id")]
    public string? OrganizationId { get; set; }

    /// <summary>For a personal account this is the sign-in email address.</summary>
    [JsonPropertyName("name")]
    public string? Name { get; set; }

    [JsonPropertyName("rate_limit_tier")]
    public string? RateLimitTier { get; set; }

    [JsonPropertyName("created_at")]
    public string? CreatedAt { get; set; }

    public string? ResolveId() => Uuid ?? OrganizationId ?? Id.ValueKind switch
    {
        JsonValueKind.String => Id.GetString(),
        JsonValueKind.Number => Id.GetRawText(),
        _ => null,
    };
}

internal sealed class OrganizationListEnvelope
{
    [JsonPropertyName("organizations")]
    public List<Organization>? Organizations { get; set; }
}

// Source-generated serialization, so trimming can't prune the reflection these types need.
[JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(UsageResponse))]
[JsonSerializable(typeof(List<Organization>))]
[JsonSerializable(typeof(OrganizationListEnvelope))]
[JsonSerializable(typeof(JsonElement))]
internal sealed partial class UsageJsonContext : JsonSerializerContext;

/// <summary>What the menu shows about the signed-in account, already formatted.</summary>
internal sealed record AccountInfo(string Email, string Tier, string MemberSince)
{
    public static AccountInfo From(Organization organization)
    {
        string email = string.IsNullOrWhiteSpace(organization.Name) ? "Unknown" : organization.Name;

        // The tier arrives as an internal identifier like "default_claude_ai". Rather than
        // guessing at a plan name it might not mean, it is shown tidied up but unmapped.
        string tier = string.IsNullOrWhiteSpace(organization.RateLimitTier)
            ? "Unknown"
            : organization.RateLimitTier.Replace('_', ' ');

        string memberSince = DateTimeOffset.TryParse(
            organization.CreatedAt, CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var created)
            ? created.ToString("d MMM yyyy", CultureInfo.InvariantCulture)
            : "Unknown";

        return new AccountInfo(email, tier, memberSince);
    }
}

// ------------------------------------------------------------ Presentation

/// <summary>One ready-to-draw line for the panel and the tray icon.</summary>
internal sealed record UsageRow(string Label, string? Kind, double Percent, string ResetText, Color Color)
{
    public string PercentText => Math.Round(Percent, MidpointRounding.AwayFromZero)
        .ToString("0", CultureInfo.InvariantCulture) + "%";

    /// <summary>The bar fill is clamped to 100; the text isn't, so overage stays visible.</summary>
    public double ClampedPercent => Math.Clamp(Percent, 0, 100);
}

internal static class Palette
{
    public static readonly Color Background = ColorTranslator.FromHtml("#151318");
    public static readonly Color Panel = ColorTranslator.FromHtml("#211e24");
    public static readonly Color Border = ColorTranslator.FromHtml("#37323b");
    public static readonly Color Text = ColorTranslator.FromHtml("#f4f0ec");
    public static readonly Color Muted = ColorTranslator.FromHtml("#aaa2ad");
    public static readonly Color Accent = ColorTranslator.FromHtml("#d67756");

    /// <summary>The pet's eye. Same as the outline - pure black.</summary>
    public static readonly Color Eye = ColorTranslator.FromHtml("#000000");

    public static readonly Color Ok = ColorTranslator.FromHtml("#58bd88");
    public static readonly Color Warn = ColorTranslator.FromHtml("#e4aa43");
    public static readonly Color Bad = ColorTranslator.FromHtml("#e35f64");
    public static readonly Color Channel = ColorTranslator.FromHtml("#39343e");

    public const string FontFamily = "Segoe UI";
}

internal static class UsageFormatting
{
    /// <summary>
    /// The same limit can arrive both as a top-level field (<c>five_hour</c>) and inside
    /// <c>limits[]</c> under its older name (<c>session</c>). Comparisons go through this table;
    /// without it the same row shows up twice in the panel.
    /// </summary>
    private static readonly Dictionary<string, string> CanonicalKinds = new(StringComparer.OrdinalIgnoreCase)
    {
        ["session"] = "five_hour",
        ["weekly_all"] = "seven_day",
        ["weekly_opus"] = "seven_day_opus",
        ["weekly_sonnet"] = "seven_day_sonnet",
        ["weekly_oauth_apps"] = "seven_day_oauth_apps",
        ["weekly_cowork"] = "seven_day_cowork",
        ["weekly_omelette"] = "seven_day_omelette",
    };

    private static readonly Dictionary<string, string> Labels = new(StringComparer.OrdinalIgnoreCase)
    {
        ["five_hour"] = "5-Hour Session",
        ["seven_day"] = "Weekly (All Models)",
        ["seven_day_opus"] = "Weekly Opus",
        ["seven_day_sonnet"] = "Weekly Sonnet",
        ["seven_day_oauth_apps"] = "Weekly OAuth Apps",
        ["seven_day_cowork"] = "Weekly Cowork",
        ["seven_day_omelette"] = "Weekly Omelette",
    };

    /// <summary>Reduces the several names one limit can arrive under to a single key.</summary>
    public static string CanonicalKind(string? kind)
    {
        if (string.IsNullOrWhiteSpace(kind)) return string.Empty;
        return CanonicalKinds.TryGetValue(kind, out string? canonical) ? canonical : kind;
    }

    /// <summary>
    /// Normal usage is the same orange as the pet; green is never used. The color only turns to
    /// the warning shade near the limit, and to red once it's reached.
    /// </summary>
    public static Color ColorFor(double percent) =>
        percent >= 90 ? Palette.Bad :
        percent >= 70 ? Palette.Warn :
        Palette.Accent;

    public static string LabelFor(string? kind)
    {
        if (string.IsNullOrWhiteSpace(kind)) return "Limit";
        return Labels.TryGetValue(CanonicalKind(kind), out string? label) ? label : kind;
    }

    public static string ResetText(string? iso, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(iso)) return "No reset time";
        if (!DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var resetsAt))
        {
            return "No reset time";
        }

        var remaining = resetsAt - now;
        if (remaining <= TimeSpan.Zero) return "Reset";

        int totalMinutes = (int)remaining.TotalMinutes;
        int days = totalMinutes / 1440;
        int hours = totalMinutes % 1440 / 60;
        int minutes = totalMinutes % 60;

        return days > 0
            ? $"Resets in {days}d {hours}h"
            : $"Resets in {hours}h {minutes}m";
    }

    public static List<UsageRow> ToRows(UsageResponse response, DateTimeOffset now)
    {
        var rows = new List<UsageRow>();

        AddWindow(rows, "five_hour", response.FiveHour, now);
        AddWindow(rows, "seven_day", response.SevenDay, now);
        AddWindow(rows, "seven_day_opus", response.SevenDayOpus, now);
        AddWindow(rows, "seven_day_sonnet", response.SevenDaySonnet, now);
        AddWindow(rows, "seven_day_oauth_apps", response.SevenDayOauthApps, now);
        AddWindow(rows, "seven_day_cowork", response.SevenDayCowork, now);
        AddWindow(rows, "seven_day_omelette", response.SevenDayOmelette, now);

        foreach (var limit in response.Limits ?? [])
        {
            // Skip anything already added from a top-level field, or it would be listed twice.
            if (rows.Any(row => string.Equals(
                    CanonicalKind(row.Kind), CanonicalKind(limit.Kind), StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            double percent = Math.Max(0, limit.Percent ?? 0);
            rows.Add(new UsageRow(
                LabelFor(limit.Kind),
                limit.Kind,
                percent,
                ResetText(limit.ResetsAt, now),
                ColorFor(percent)));
        }

        return rows;
    }

    private static void AddWindow(
        List<UsageRow> rows,
        string kind,
        UsageWindow? window,
        DateTimeOffset now)
    {
        if (window?.Utilization is not { } utilization) return;

        double percent = Math.Max(0, utilization);
        rows.Add(new UsageRow(
            LabelFor(kind),
            kind,
            percent,
            ResetText(window.ResetsAt, now),
            ColorFor(percent)));
    }

    /// <summary>The spend card is only drawn when <c>spend.enabled</c> is set.</summary>
    public static string? SpendText(UsageSpend? spend)
    {
        if (spend is not { Enabled: true }) return null;

        var used = spend.Used;
        double amount = used is null ? 0 : used.AmountMinor / Math.Pow(10, used.Exponent);
        return $"{amount.ToString("F2", CultureInfo.InvariantCulture)} {used?.Currency ?? "USD"}";
    }

    /// <summary>The tray tooltip. Truncated because NotifyIcon.Text caps out at 63 characters.</summary>
    public static string Tooltip(UsageRow? row)
    {
        string text = row is null ? "Claude Usage" : $"{row.Label}: {row.PercentText}";
        return text.Length <= 63 ? text : text[..63];
    }
}
