using System.Windows.Forms;

namespace ClaudeUsage;

/// <summary>The app's brain: tray icon, menu, timer and the refresh flow.</summary>
internal sealed class TrayAppContext : ApplicationContext
{
    private const int MaxErrorLogBytes = 256 * 1024;

    private readonly Settings _settings = Settings.Load();
    private readonly WebViewHost _webViewHost = new();
    private readonly ClaudeClient _client;
    private readonly TrayIconRenderer _renderer = new();
    private readonly UsagePanel _panel = new();
    private readonly UsageOverlay _overlay = new();
    private readonly NotifyIcon _notifyIcon = new();
    private readonly ContextMenuStrip _menu = new();
    private readonly SemaphoreSlim _refreshLock = new(1, 1);

    // System.Windows.Forms.Timer ticks on the UI thread, so updating the icon from it is safe.
    private readonly System.Windows.Forms.Timer _timer = new();

    private readonly ToolStripMenuItem _refreshItem = new("Refresh");
    private readonly ToolStripMenuItem _loginItem = new("Sign in to Claude");
    private readonly ToolStripMenuItem _switchAccountItem = new("Switch account");
    private readonly ToolStripMenuItem _logoutItem = new("Sign out");
    private readonly ToolStripMenuItem _menuWindowItem = new("Menu");
    private readonly ToolStripMenuItem _batteryItem = new("Show on tray icon") { CheckOnClick = true };
    private readonly ToolStripMenuItem _overlayItem = new("Show on screen") { CheckOnClick = true };
    private readonly ToolStripMenuItem _refreshIntervalItem = new("Refresh interval");
    private readonly ToolStripMenuItem _startupItem = new("Start with Windows") { CheckOnClick = true };

    private LoginWindow? _loginWindow;
    private MenuWindow? _menuWindow;
    private bool _authenticated;
    private bool _switchingAccount;

    public TrayAppContext()
    {
        _client = new ClaudeClient(_webViewHost, _settings);

        BuildMenu();

        _notifyIcon.ContextMenuStrip = _menu;
        _notifyIcon.Visible = true;
        _notifyIcon.MouseClick += OnTrayClick;
        _renderer.Apply(_notifyIcon, percent: null, Palette.Accent);
        _notifyIcon.Text = "Claude Usage";

        _batteryItem.Checked = _settings.BatteryMode;
        _startupItem.Checked = Settings.IsRegisteredForStartup();

        _overlay.RestorePosition(_settings.OverlayX, _settings.OverlayY);
        _overlay.PositionChanged += (_, _) =>
        {
            _settings.OverlayX = _overlay.Left;
            _settings.OverlayY = _overlay.Top;
            _settings.Save();
        };
        _overlayItem.Checked = _settings.OverlayVisible;
        if (_settings.OverlayVisible) _overlay.Show();

        _timer.Interval = Math.Max(2, _settings.RefreshSeconds) * 1000;
        _timer.Tick += async (_, _) => await RefreshAsync();
        _ = InitializeAsync();
    }

    private void BuildMenu()
    {
        _refreshItem.Click += async (_, _) => await RefreshAsync();
        _loginItem.Click += (_, _) => OpenLogin();
        _switchAccountItem.Click += async (_, _) => await SwitchAccountAsync();
        _logoutItem.Click += async (_, _) => await LogoutAsync();
        _menuWindowItem.Click += (_, _) => OpenMenuWindow();
        _batteryItem.Click += (_, _) =>
        {
            _settings.BatteryMode = _batteryItem.Checked;
            _settings.Save();
            UpdateTrayIcon();
        };
        _overlayItem.Click += (_, _) =>
        {
            _settings.OverlayVisible = _overlayItem.Checked;
            _settings.Save();

            if (_overlayItem.Checked) _overlay.Show();
            else _overlay.Hide();
        };
        _startupItem.Click += (_, _) =>
        {
            Settings.SetStartupRegistration(_startupItem.Checked);
        };

        AddRefreshInterval("10 seconds", 10);
        AddRefreshInterval("30 seconds", 30);
        AddRefreshInterval("1 minute", 60);
        AddRefreshInterval("5 minutes", 300);

        var exitItem = new ToolStripMenuItem("Quit");
        exitItem.Click += (_, _) => ExitThread();

        _menu.Items.AddRange([
            _refreshItem,
            _loginItem,
            _switchAccountItem,
            _logoutItem,
            new ToolStripSeparator(),
            _menuWindowItem,
            _overlayItem,
            _batteryItem,
            _refreshIntervalItem,
            _startupItem,
            new ToolStripSeparator(),
            exitItem,
        ]);
    }

    private void AddRefreshInterval(string label, int seconds)
    {
        var item = new ToolStripMenuItem(label)
        {
            Checked = _settings.RefreshSeconds == seconds,
            Tag = seconds,
        };

        item.Click += (_, _) =>
        {
            _settings.RefreshSeconds = seconds;
            _settings.Save();
            _timer.Interval = seconds * 1000;

            foreach (ToolStripMenuItem option in _refreshIntervalItem.DropDownItems)
                option.Checked = Equals(option.Tag, seconds);
        };

        _refreshIntervalItem.DropDownItems.Add(item);
    }

    private async Task InitializeAsync()
    {
        try
        {
            SetAuthenticated(await _client.IsAuthenticatedAsync());
        }
        catch (WebViewHost.WebView2MissingException exception)
        {
            SetAuthenticated(false);
            ShowError(exception.Message);
            return;
        }

        if (_authenticated)
        {
            await RefreshAsync();
        }
        else
        {
            _panel.SetMessage("Sign in to connect your Claude account.");
            OpenLogin();
        }
    }

    private void SetAuthenticated(bool value)
    {
        _authenticated = value;
        _loginItem.Visible = !value;
        _switchAccountItem.Visible = value;
        _logoutItem.Visible = value;
        _refreshItem.Visible = value;

        if (value) _timer.Start();
        else _timer.Stop();
    }

    private void OnTrayClick(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        _panel.Toggle();
        if (_panel.Visible && _authenticated) _ = RefreshAsync();
    }

    private async Task RefreshAsync(bool waitForActiveRefresh = false)
    {
        if (!_authenticated) return;

        bool entered;
        if (waitForActiveRefresh)
        {
            await _refreshLock.WaitAsync();
            entered = true;
        }
        else
        {
            entered = await _refreshLock.WaitAsync(0);
        }

        if (!entered) return;

        try
        {
            if (!_authenticated) return;

            var response = await _client.FetchUsageAsync();
            SetAuthenticated(true);

            HandleLimitResetNotification(response);

            var rows = UsageFormatting.ToRows(response, DateTimeOffset.UtcNow);
            string? spendText = UsageFormatting.SpendText(response.Spend);
            if (!_hasCurrentData || UsageChanged(rows, spendText))
            {
                _lastRows = rows;
                _lastSpendText = spendText;
                _hasCurrentData = true;
                _panel.SetData(rows, spendText);
                UpdateTrayIcon();
            }
        }
        catch (ClaudeSessionChangedException)
        {
            // An older request that finished mid-account-switch is discarded on purpose.
        }
        catch (ClaudeSessionExpiredException exception)
        {
            LogException(exception);
            await HandleExpiredSessionAsync(exception.Message);
        }
        catch (Exception exception)
        {
            LogException(exception);
            string message = exception is ClaudeException or WebViewHost.WebView2MissingException
                ? exception.Message
                : $"Usage data could not be fetched: {exception.Message}";
            ShowError(message);
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private void HandleLimitResetNotification(UsageResponse response)
    {
        bool windowHasNotStarted = response.FiveHour is
        {
            Utilization: 0,
            ResetsAt: null,
        };

        if (windowHasNotStarted && !_settings.LoggedNotification)
        {
            // Recorded before the window opens, so that quitting the app while the reminder is
            // up doesn't make it fire again and again during the same unused limit cycle.
            _settings.LoggedNotification = true;
            _settings.Save();

            using var notification = new LimitResetNotification();
            notification.ShowDialog();
            return;
        }

        if (!windowHasNotStarted && _settings.LoggedNotification)
        {
            _settings.LoggedNotification = false;
            _settings.Save();
        }
    }

    private List<UsageRow> _lastRows = [];
    private string? _lastSpendText;
    private bool _hasCurrentData;

    private async Task HandleExpiredSessionAsync(string message)
    {
        try
        {
            await _client.LogoutAsync();
        }
        catch (Exception exception)
        {
            LogException(exception);
        }

        SetAuthenticated(false);
        _lastRows = [];
        _lastSpendText = null;
        _hasCurrentData = false;
        UpdateTrayIcon();
        ShowError(message);
        OpenLogin();
    }

    private bool UsageChanged(IReadOnlyList<UsageRow> rows, string? spendText)
    {
        if (!string.Equals(_lastSpendText, spendText, StringComparison.Ordinal) ||
            rows.Count != _lastRows.Count)
        {
            return true;
        }

        for (int index = 0; index < rows.Count; index++)
        {
            UsageRow current = rows[index];
            UsageRow previous = _lastRows[index];
            if (!string.Equals(current.Kind, previous.Kind, StringComparison.Ordinal) ||
                current.Percent != previous.Percent)
            {
                return true;
            }
        }

        return false;
    }

    private void UpdateTrayIcon()
    {
        var row = _lastRows.FirstOrDefault(r => string.Equals(
                      UsageFormatting.CanonicalKind(r.Kind),
                      UsageFormatting.CanonicalKind(_settings.TrayLimitKind),
                      StringComparison.OrdinalIgnoreCase))
                  ?? _lastRows.FirstOrDefault();

        if (_settings.BatteryMode && row is not null)
        {
            _renderer.Apply(_notifyIcon, row.Percent, row.Color);
        }
        else
        {
            _renderer.Apply(_notifyIcon, percent: null, Palette.Accent);
        }

        _notifyIcon.Text = UsageFormatting.Tooltip(row);
        _overlay.SetUsage(row?.Percent, row?.Color ?? Palette.Accent);
    }

    private void ShowError(string message)
    {
        _hasCurrentData = false;
        _panel.SetMessage(message);
        _notifyIcon.Text = message.Length <= 63 ? message : message[..63];
    }

    private static void LogException(Exception exception)
    {
        try
        {
            Directory.CreateDirectory(Settings.DataDirectory);
            string path = Path.Combine(Settings.DataDirectory, "error.log");
            string entry = $"[{DateTimeOffset.Now:O}] {exception}\r\n\r\n";
            bool resetLog = File.Exists(path) &&
                new FileInfo(path).Length + System.Text.Encoding.UTF8.GetByteCount(entry) > MaxErrorLogBytes;

            if (resetLog) File.WriteAllText(path, entry);
            else File.AppendAllText(path, entry);
        }
        catch
        {
            // Diagnostics must never stop the app from running.
        }
    }

    private void OpenLogin()
    {
        if (_loginWindow is { IsDisposed: false, Visible: true })
        {
            if (_loginWindow.WindowState == FormWindowState.Minimized)
                _loginWindow.WindowState = FormWindowState.Normal;

            _loginWindow.Show();
            _loginWindow.Activate();
            _loginWindow.BringToFront();
            return;
        }

        if (_loginWindow is { IsDisposed: false }) _loginWindow.Dispose();
        _loginWindow = null;
        _loginWindow = new LoginWindow(_webViewHost);
        _loginWindow.LoginCompleted += async (_, _) =>
        {
            _client.ResetSession();
            SetAuthenticated(true);
            await RefreshAsync(waitForActiveRefresh: true);
        };
        _loginWindow.FormClosed += (_, _) => _loginWindow = null;
        _loginWindow.Show();
    }

    private void OpenMenuWindow()
    {
        if (_menuWindow is { IsDisposed: false })
        {
            if (_menuWindow.WindowState == FormWindowState.Minimized)
                _menuWindow.WindowState = FormWindowState.Normal;

            _menuWindow.Show();
            _menuWindow.Activate();
            _menuWindow.BringToFront();
            return;
        }

        _menuWindow = new MenuWindow();
        _menuWindow.FormClosed += (_, _) => _menuWindow = null;
        _menuWindow.Show();
    }

    private async Task LogoutAsync()
    {
        Task clearSession = _client.LogoutAsync();
        SetAuthenticated(false);
        _lastRows = [];
        _lastSpendText = null;
        _hasCurrentData = false;
        _settings.LoggedNotification = false;
        _settings.Save();

        try
        {
            await clearSession;
        }
        catch (Exception exception)
        {
            LogException(exception);
            ShowError("The Claude session data could not be fully cleared.");
            return;
            // Local state is reset even when clearing the cookies fails.
        }

        _panel.SetMessage("The Claude session was removed from this app.");
        UpdateTrayIcon();
    }

    private async Task SwitchAccountAsync()
    {
        if (_switchingAccount) return;
        _switchingAccount = true;

        Task clearSession = _client.LogoutAsync();
        SetAuthenticated(false);
        _lastRows = [];
        _lastSpendText = null;
        _hasCurrentData = false;
        _settings.LoggedNotification = false;
        _settings.Save();
        _panel.SetMessage("Sign in with the new Claude account.");
        UpdateTrayIcon();

        try
        {
            await clearSession;
        }
        catch (Exception exception)
        {
            LogException(exception);
            ShowError("The previous Claude session could not be cleared.");
            return;
        }
        finally
        {
            _switchingAccount = false;
        }

        OpenLogin();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Stop();
            _timer.Dispose();
            _refreshLock.Dispose();
            _notifyIcon.Visible = false;   // otherwise a ghost icon is left behind on exit
            _notifyIcon.Dispose();
            _renderer.Dispose();
            _menu.Dispose();
            _panel.Dispose();
            _overlay.Dispose();
            _loginWindow?.Dispose();
            _menuWindow?.Dispose();
            _webViewHost.Dispose();
        }
        base.Dispose(disposing);
    }
}
