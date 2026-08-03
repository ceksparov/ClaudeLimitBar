using System.Text.Json;

namespace ClaudeUsage;

/// <summary>The networking layer - the counterpart of Electron's <c>electron-main.js</c>.</summary>
internal sealed class ClaudeClient
{
    private readonly WebViewHost _webViewHost;
    private readonly Settings _settings;
    private string? _organizationId;
    private string? _activeOrganizationCookie;
    private int _sessionGeneration;

    public ClaudeClient(WebViewHost webViewHost, Settings settings)
    {
        _webViewHost = webViewHost;
        _settings = settings;
        _organizationId = settings.LastOrganizationId;
    }

    public Task<bool> IsAuthenticatedAsync() => _webViewHost.HasSessionCookieAsync();

    public void ResetSession()
    {
        unchecked { _sessionGeneration++; }
        ForgetOrganization();
        _activeOrganizationCookie = null;
    }

    public async Task<UsageResponse> FetchUsageAsync()
    {
        int generation = _sessionGeneration;
        bool hasSession = await _webViewHost.HasSessionCookieAsync();
        EnsureCurrentSession(generation);

        if (!hasSession)
        {
            throw new ClaudeSessionExpiredException("No Claude session was found. Sign in again.");
        }

        string? activeOrganizationId = await _webViewHost.GetActiveOrganizationIdAsync();
        EnsureCurrentSession(generation);

        if (_activeOrganizationCookie is null)
        {
            // The last known-good UUID from disk is tried first on the very first refresh, so a
            // restart can't let Claude's own fallback order pick a different account.
            _activeOrganizationCookie = activeOrganizationId;
        }
        else if (!string.IsNullOrEmpty(activeOrganizationId) &&
                 !string.Equals(
                     _activeOrganizationCookie, activeOrganizationId, StringComparison.OrdinalIgnoreCase))
        {
            ForgetOrganization();
            _activeOrganizationCookie = activeOrganizationId;
        }

        string? organizationId = _organizationId ??
            await DiscoverOrganizationIdAsync(generation, activeOrganizationId);
        if (string.IsNullOrEmpty(organizationId))
        {
            throw new ClaudeException("No usable organization was found for this Claude account.");
        }

        EnsureCurrentSession(generation);
        RememberOrganization(organizationId);

        string json;
        try
        {
            json = await GetJsonAsync($"/api/organizations/{organizationId}/usage", generation);
        }
        catch (ClaudeOrganizationNotFoundException)
        {
            EnsureCurrentSession(generation);
            ForgetOrganization();

            organizationId = await DiscoverOrganizationIdAsync(generation);
            if (string.IsNullOrEmpty(organizationId))
            {
                throw new ClaudeException("No usable organization was found for this Claude account.");
            }

            EnsureCurrentSession(generation);
            RememberOrganization(organizationId);
            json = await GetJsonAsync($"/api/organizations/{organizationId}/usage", generation);
        }

        EnsureCurrentSession(generation);
        return Deserialize(json, UsageJsonContext.Default.UsageResponse);
    }

    private async Task<string?> DiscoverOrganizationIdAsync(
        int generation,
        string? activeOrganizationId = null)
    {
        string json = await GetJsonAsync("/api/organizations", generation);

        // The response is either a bare array or a { organizations: [...] } envelope.
        List<Organization>? organizations = json.TrimStart().StartsWith('[')
            ? Deserialize(json, UsageJsonContext.Default.ListOrganization)
            : Deserialize(json, UsageJsonContext.Default.OrganizationListEnvelope).Organizations;

        if (organizations is not { Count: > 0 }) return null;

        activeOrganizationId ??= await _webViewHost.GetActiveOrganizationIdAsync();
        EnsureCurrentSession(generation);

        return organizations
                   .Select(organization => organization.ResolveId())
                   .FirstOrDefault(id => string.Equals(
                       id, activeOrganizationId, StringComparison.OrdinalIgnoreCase))
               ?? organizations[0].ResolveId();
    }

    public Task LogoutAsync()
    {
        ResetSession();
        return _webViewHost.ClearAllSessionDataAsync();
    }

    private void RememberOrganization(string organizationId)
    {
        _organizationId = organizationId;
        if (string.Equals(
                _settings.LastOrganizationId, organizationId, StringComparison.OrdinalIgnoreCase)) return;

        _settings.LastOrganizationId = organizationId;
        _settings.Save();
    }

    private void ForgetOrganization()
    {
        _organizationId = null;
        if (_settings.LastOrganizationId is null) return;

        _settings.LastOrganizationId = null;
        _settings.Save();
    }

    private async Task<string> GetJsonAsync(string pathname, int generation)
    {
        EnsureCurrentSession(generation);
        BrowserFetchResult response = await _webViewHost.FetchAsync(pathname);
        EnsureCurrentSession(generation);

        if (response.IsSuccess) return response.Body;

        if (response.StatusCode == 0)
        {
            throw new ClaudeException(
                $"The Claude API request could not be sent: {response.Error ?? "unknown network error"}");
        }

        throw response.StatusCode switch
        {
            401 => new ClaudeSessionExpiredException(
                "The Claude session has expired. Sign in again."),
            403 => new ClaudeException(
                "Claude blocked the request. Open the sign-in window and let the page load fully."),
            404 => new ClaudeOrganizationNotFoundException(),
            429 => new ClaudeException("Too many requests were sent. Try again in a minute."),
            var status => new ClaudeException(
                $"The Claude API returned {status}: {response.Body[..Math.Min(200, response.Body.Length)]}"),
        };
    }

    private void EnsureCurrentSession(int generation)
    {
        if (generation != _sessionGeneration)
            throw new ClaudeSessionChangedException();
    }

    private static T Deserialize<T>(string json, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> typeInfo)
    {
        T? value;
        try
        {
            value = JsonSerializer.Deserialize(json, typeInfo);
        }
        catch (JsonException)
        {
            throw new ClaudeException("The Claude API did not return the expected JSON response.");
        }

        return value ?? throw new ClaudeException("The Claude API did not return the expected JSON response.");
    }

}

/// <summary>An error whose message is safe to show to the user as-is.</summary>
internal class ClaudeException(string message) : Exception(message);

internal sealed class ClaudeSessionExpiredException(string message) : ClaudeException(message);

internal sealed class ClaudeOrganizationNotFoundException()
    : ClaudeException("The Claude organization was not found.");

internal sealed class ClaudeSessionChangedException : OperationCanceledException;
