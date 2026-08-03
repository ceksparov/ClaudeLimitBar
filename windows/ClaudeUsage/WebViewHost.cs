using System.Text.Json;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ClaudeUsage;

/// <summary>
/// Holds the persistent Claude session - the Windows counterpart of Electron's
/// <c>session.fromPartition("persist:claude-auth")</c>.
/// A single live <see cref="CoreWebView2"/> instance is kept inside a hidden Form for the
/// lifetime of the app, because that is the only way to read the cookie store.
/// </summary>
internal sealed class WebViewHost : IDisposable
{
    public const string ClaudeOrigin = "https://claude.ai";

    private static readonly string UserDataFolder = Path.Combine(Settings.DataDirectory, "WebView2");

    private CoreWebView2Environment? _environment;
    private Form? _hiddenForm;
    private WebView2? _hiddenView;
    private readonly SemaphoreSlim _navigationLock = new(1, 1);
    private readonly SemaphoreSlim _fetchLock = new(1, 1);
    private bool _disposed;

    public sealed class WebView2MissingException(Exception inner)
        : Exception(
            "WebView2 Runtime was not found. Signing in to Claude needs the Microsoft Edge WebView2 Runtime.\n\n" +
            "Download it from:\nhttps://developer.microsoft.com/microsoft-edge/webview2/",
            inner);

    public async Task<CoreWebView2Environment> GetEnvironmentAsync()
    {
        if (_environment is not null) return _environment;

        try
        {
            Directory.CreateDirectory(UserDataFolder);
            _environment = await CoreWebView2Environment.CreateAsync(
                browserExecutableFolder: null,
                userDataFolder: UserDataFolder,
                options: null);
        }
        catch (Exception exception) when (exception is not WebView2MissingException)
        {
            throw new WebView2MissingException(exception);
        }

        return _environment;
    }

    /// <summary>The app-lifetime hidden instance that reading the cookie store depends on.</summary>
    private async Task<CoreWebView2> GetCoreAsync()
    {
        if (_hiddenView?.CoreWebView2 is { } existing) return existing;

        var environment = await GetEnvironmentAsync();

        _hiddenForm = new Form
        {
            FormBorderStyle = FormBorderStyle.None,
            ShowInTaskbar = false,
            StartPosition = FormStartPosition.Manual,
            Location = new System.Drawing.Point(-32000, -32000),
            Size = new System.Drawing.Size(1, 1),
            Opacity = 0,
        };
        _hiddenView = new WebView2 { Dock = DockStyle.Fill };
        _hiddenForm.Controls.Add(_hiddenView);

        // EnsureCoreWebView2Async never completes until the window handle exists.
        _hiddenForm.Show();
        _hiddenForm.Hide();

        await _hiddenView.EnsureCoreWebView2Async(environment);
        Configure(_hiddenView.CoreWebView2);
        return _hiddenView.CoreWebView2;
    }

    public static void Configure(CoreWebView2 core)
    {
        core.Settings.IsWebMessageEnabled = true;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
    }

    public async Task<bool> HasSessionCookieAsync()
    {
        try
        {
            var core = await GetCoreAsync();
            var cookies = await core.CookieManager.GetCookiesAsync(ClaudeOrigin);
            return cookies.Any(cookie =>
                cookie.Name == "sessionKey" && !string.IsNullOrEmpty(cookie.Value));
        }
        catch (WebView2MissingException)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    public async Task<string?> GetActiveOrganizationIdAsync()
    {
        try
        {
            var core = await GetCoreAsync();
            var cookies = await core.CookieManager.GetCookiesAsync(ClaudeOrigin);
            return cookies.FirstOrDefault(cookie => cookie.Name == "lastActiveOrg")?.Value;
        }
        catch (WebView2MissingException)
        {
            throw;
        }
        catch
        {
            return null;
        }
    }

    private async Task<CoreWebView2> GetClaudeCoreAsync()
    {
        var core = await GetCoreAsync();
        if (IsClaudePage(core.Source)) return core;

        await _navigationLock.WaitAsync();
        try
        {
            if (IsClaudePage(core.Source)) return core;

            var completion = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);

            void NavigationCompleted(object? _, CoreWebView2NavigationCompletedEventArgs args)
            {
                if (args.IsSuccess && IsClaudePage(core.Source)) completion.TrySetResult(true);
                else if (!args.IsSuccess) completion.TrySetException(
                    new ClaudeException($"The Claude page could not be loaded: {args.WebErrorStatus}"));
            }

            core.NavigationCompleted += NavigationCompleted;
            try
            {
                // Being on the same origin is enough; there is no reason to boot the Claude SPA,
                // its WebSockets and its heavy UI assets in the background.
                core.Navigate($"{ClaudeOrigin}/robots.txt");
                await completion.Task.WaitAsync(TimeSpan.FromSeconds(30));
            }
            finally
            {
                core.NavigationCompleted -= NavigationCompleted;
            }

            return core;
        }
        finally
        {
            _navigationLock.Release();
        }
    }

    private static bool IsClaudePage(string? source) =>
        Uri.TryCreate(source, UriKind.Absolute, out var uri) &&
        string.Equals(uri.Host, "claude.ai", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Sends the request from inside the signed-in WebView2 page's own browser context, so the
    /// cookie value never crosses into managed code or into another HTTP client.
    /// </summary>
    public async Task<BrowserFetchResult> FetchAsync(string pathname)
    {
        if (!pathname.StartsWith("/api/", StringComparison.Ordinal))
        {
            throw new ArgumentException("Only Claude API paths are allowed.", nameof(pathname));
        }

        await _fetchLock.WaitAsync();
        try
        {
            var core = await GetClaudeCoreAsync();
            string requestId = Guid.NewGuid().ToString("N");
            string encodedRequestId = JsonSerializer.Serialize(requestId);
            string encodedPath = JsonSerializer.Serialize(pathname);
            string script = $$"""
            (async () => {
              try {
                const response = await fetch({{encodedPath}}, {
                  method: "GET",
                  cache: "no-store",
                  credentials: "include",
                  headers: {
                    "accept": "*/*",
                    "anthropic-client-platform": "web_claude_ai",
                    "anthropic-client-version": "1.0.0"
                  }
                });
                window.chrome.webview.postMessage({
                  type: "claude-usage-fetch-result",
                  id: {{encodedRequestId}},
                  ok: response.ok,
                  status: response.status,
                  body: await response.text(),
                  error: null
                });
              } catch (error) {
                window.chrome.webview.postMessage({
                  type: "claude-usage-fetch-result",
                  id: {{encodedRequestId}},
                  ok: false,
                  status: 0,
                  body: "",
                  error: String(error)
                });
              }
            })()
            """;

            var completion = new TaskCompletionSource<BrowserFetchResult>(
                TaskCreationOptions.RunContinuationsAsynchronously);

            void WebMessageReceived(object? _, CoreWebView2WebMessageReceivedEventArgs args)
            {
                if (!IsClaudePage(args.Source)) return;

                try
                {
                    using var document = JsonDocument.Parse(args.WebMessageAsJson);
                    var root = document.RootElement;

                    if (!root.TryGetProperty("type", out var type) ||
                        type.GetString() != "claude-usage-fetch-result" ||
                        !root.TryGetProperty("id", out var id) ||
                        id.GetString() != requestId)
                    {
                        return;
                    }

                    completion.TrySetResult(new BrowserFetchResult(
                        root.TryGetProperty("ok", out var ok) && ok.GetBoolean(),
                        root.TryGetProperty("status", out var status) ? status.GetInt32() : 0,
                        root.TryGetProperty("body", out var body) ? body.GetString() ?? "" : "",
                        root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String
                            ? error.GetString()
                            : null));
                }
                catch (JsonException)
                {
                    // Ignore malformed page messages, and any that belong to another request.
                }
            }

            core.WebMessageReceived += WebMessageReceived;
            try
            {
                // ExecuteScriptAsync only kicks the async work off. The result is taken from the
                // reliable message bridge rather than from the promise's return value.
                await core.ExecuteScriptAsync(script);
                return await completion.Task.WaitAsync(TimeSpan.FromSeconds(30));
            }
            catch (TimeoutException)
            {
                throw new ClaudeException("The Claude API request timed out.");
            }
            finally
            {
                core.WebMessageReceived -= WebMessageReceived;
            }
        }
        finally
        {
            _fetchLock.Release();
        }
    }

    public async Task ClearAllSessionDataAsync()
    {
        var core = await GetCoreAsync();
        await core.Profile.ClearBrowsingDataAsync(CoreWebView2BrowsingDataKinds.AllProfile);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _hiddenView?.Dispose();
        _hiddenForm?.Dispose();
        _navigationLock.Dispose();
        _fetchLock.Dispose();
        _hiddenView = null;
        _hiddenForm = null;
    }
}

internal sealed record BrowserFetchResult(bool IsSuccess, int StatusCode, string Body, string? Error);
