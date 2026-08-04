using System.Drawing;
using System.Windows.Forms;
using Microsoft.Web.WebView2.WinForms;

namespace ClaudeUsage;

/// <summary>
/// Opened only while signing in. It shares the one <c>CoreWebView2Environment</c> - without
/// that, the session would be written to a separate store and the sign-in wouldn't "stick".
/// </summary>
internal sealed class LoginWindow : Form
{
    private readonly WebViewHost _host;
    private readonly WebView2 _webView = new() { Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer _cookiePoll = new() { Interval = 1500 };
    private bool _completed;

    /// <summary>Raised once the sessionKey cookie appears.</summary>
    public event EventHandler? LoginCompleted;

    public LoginWindow(WebViewHost host)
    {
        _host = host;

        Text = "Claude Sign-In";
        ClientSize = new Size(1080, 800);
        MinimumSize = new Size(760, 600);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Palette.Background;
        ShowIcon = false;

        Controls.Add(_webView);
        _cookiePoll.Tick += async (_, _) => await CheckLoginAsync();
    }

    protected override async void OnLoad(EventArgs e)
    {
        base.OnLoad(e);

        try
        {
            var environment = await _host.GetEnvironmentAsync();
            await _webView.EnsureCoreWebView2Async(environment);
            WebViewHost.Configure(_webView.CoreWebView2);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Claude Usage",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            Close();
            return;
        }

        // WebView2 has no equivalent of Electron's cookies.on("changed"), so we poll instead.
        _webView.CoreWebView2.NavigationCompleted += async (_, _) => await CheckLoginAsync();
        _cookiePoll.Start();

        try
        {
            _webView.CoreWebView2.Navigate($"{WebViewHost.ClaudeOrigin}/login");
        }
        catch (Exception exception)
        {
            _cookiePoll.Stop();
            MessageBox.Show(this, $"The Claude sign-in page could not be opened: {exception.Message}",
                "Claude Usage", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task CheckLoginAsync()
    {
        if (_completed || IsDisposed) return;

        bool authenticated;
        try
        {
            authenticated = await _host.HasSessionCookieAsync();
        }
        catch
        {
            return;
        }

        if (!authenticated || _completed || IsDisposed) return;

        _completed = true;
        _cookiePoll.Stop();
        LoginCompleted?.Invoke(this, EventArgs.Empty);

        // A short delay, as in the Electron build: let the page finish writing the session.
        var closeTimer = new System.Windows.Forms.Timer { Interval = 900 };
        closeTimer.Tick += (_, _) =>
        {
            closeTimer.Stop();
            closeTimer.Dispose();
            if (!IsDisposed) Close();
        };
        closeTimer.Start();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _cookiePoll.Stop();
            _cookiePoll.Dispose();
            _webView.Dispose();
        }
        base.Dispose(disposing);
    }
}
