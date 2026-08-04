using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeUsage;

/// <summary>
/// The menu window, opened from the tray icon's context menu. It gathers in one place the
/// things the tray menu can only hint at: who is signed in, where each limit window stands,
/// and how the app itself is configured.
/// </summary>
internal sealed class MenuWindow : Form
{
    private const int WindowWidth = 460;
    private const int WindowHeight = 508;
    private const int Pad = 22;
    private const int HeaderHeight = 66;
    private const int SectionGap = 30;
    private const int RowHeight = 26;

    private const int WmNcLButtonDown = 0x00A1;
    private const int HtCaption = 0x0002;

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    private readonly Rectangle _folderButton = new(Pad + 4, 432, 190, 44);
    private readonly Rectangle _closeButton = new(WindowWidth - Pad - 194, 432, 190, 44);
    private readonly Font _titleFont = new(Palette.FontFamily, 14f, FontStyle.Bold);
    private readonly Font _sectionFont = new(Palette.FontFamily, 8f, FontStyle.Bold);
    private readonly Font _labelFont = new(Palette.FontFamily, 8.5f);
    private readonly Font _valueFont = new(Palette.FontFamily, 8.5f, FontStyle.Bold);
    private readonly Font _buttonFont = new(Palette.FontFamily, 10f, FontStyle.Bold);

    private Rectangle? _pressedButton;
    private Rectangle? _hoveredButton;

    private AccountInfo? _account;
    private string _accountStatus = "Loading...";
    private IReadOnlyList<UsageRow> _rows = [];
    private string _refreshInterval = "-";
    private bool _overlayVisible;
    private bool _startsWithWindows;

    public MenuWindow()
    {
        ClientSize = new Size(WindowWidth, WindowHeight);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Palette.Background;
        DoubleBuffered = true;
        KeyPreview = true;
        Text = "Menu";
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ClassStyle |= 0x00020000; // CS_DROPSHADOW
            return parameters;
        }
    }

    /// <summary>Everything the window knows before the account call comes back.</summary>
    public void SetLocalState(
        IReadOnlyList<UsageRow> rows, int refreshSeconds, bool overlayVisible, bool startsWithWindows)
    {
        _rows = rows;
        _refreshInterval = refreshSeconds % 60 == 0 && refreshSeconds >= 60
            ? $"{refreshSeconds / 60} min"
            : $"{refreshSeconds} sec";
        _overlayVisible = overlayVisible;
        _startsWithWindows = startsWithWindows;
        Invalidate();
    }

    public void SetAccount(AccountInfo account)
    {
        _account = account;
        Invalidate();
    }

    /// <summary>Shown in place of the account rows when the lookup can't be made.</summary>
    public void SetAccountUnavailable(string reason)
    {
        _account = null;
        _accountStatus = reason;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics graphics = e.Graphics;
        // Same pixel-art rules as the usage panel: hard edges everywhere.
        graphics.SmoothingMode = SmoothingMode.None;
        graphics.PixelOffsetMode = PixelOffsetMode.Half;
        graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
        graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

        DrawFrame(graphics);

        using var accent = new SolidBrush(Palette.Accent);
        PetSprite.Draw(graphics, Pad, 20, 2.5f, Palette.Accent, Palette.Eye);
        graphics.DrawString("MENU", _titleFont, accent, Pad + 54, 24);

        int contentWidth = WindowWidth - Pad * 2;
        int y = HeaderHeight;

        y = DrawSection(graphics, "ACCOUNT", y, contentWidth);
        if (_account is { } account)
        {
            y = DrawRow(graphics, "Signed in as", account.Email, y, contentWidth);
            y = DrawRow(graphics, "Rate limit tier", account.Tier, y, contentWidth);
            y = DrawRow(graphics, "Member since", account.MemberSince, y, contentWidth);
        }
        else
        {
            y = DrawRow(graphics, "Signed in as", _accountStatus, y, contentWidth);
            y += RowHeight * 2;
        }

        y += SectionGap - RowHeight;
        y = DrawSection(graphics, "LIMITS", y, contentWidth);
        if (_rows.Count == 0)
        {
            y = DrawRow(graphics, "No usage data yet", string.Empty, y, contentWidth);
            y += RowHeight;
        }
        else
        {
            foreach (UsageRow row in _rows.Take(2))
            {
                y = DrawRow(graphics, row.Label, $"{row.PercentText}  -  {row.ResetText}",
                    y, contentWidth, row.Color);
            }
            if (_rows.Count < 2) y += RowHeight;
        }

        y += SectionGap - RowHeight;
        y = DrawSection(graphics, "APP", y, contentWidth);
        y = DrawRow(graphics, "Refresh every", _refreshInterval, y, contentWidth);
        y = DrawRow(graphics, "On-screen pet", _overlayVisible ? "On" : "Off", y, contentWidth);
        DrawRow(graphics, "Start with Windows", _startsWithWindows ? "On" : "Off", y, contentWidth);

        PixelButton.Draw(graphics, _folderButton, "DATA FOLDER", _buttonFont,
            _hoveredButton == _folderButton, _pressedButton == _folderButton);
        PixelButton.Draw(graphics, _closeButton, "CLOSE", _buttonFont,
            _hoveredButton == _closeButton, _pressedButton == _closeButton);
    }

    private void DrawFrame(Graphics graphics)
    {
        using var background = new SolidBrush(Palette.Background);
        using var panel = new SolidBrush(Palette.Panel);
        using var border = new SolidBrush(Palette.Border);

        graphics.FillRectangle(background, ClientRectangle);
        graphics.FillRectangle(border, 0, 0, Width, 4);
        graphics.FillRectangle(border, 0, Height - 4, Width, 4);
        graphics.FillRectangle(border, 0, 0, 4, Height);
        graphics.FillRectangle(border, Width - 4, 0, 4, Height);
        graphics.FillRectangle(panel, 4, 4, Width - 8, Height - 8);
    }

    /// <summary>A section heading with the dotted rule under it. Returns the first row's y.</summary>
    private int DrawSection(Graphics graphics, string title, int y, int contentWidth)
    {
        using var accent = new SolidBrush(Palette.Accent);
        using var border = new SolidBrush(Palette.Border);

        graphics.DrawString(title, _sectionFont, accent, Pad, y);
        DrawDottedRule(graphics, Pad, y + 20, contentWidth, border);
        return y + 32;
    }

    /// <summary>Label on the left, value right-aligned against it. Returns the next row's y.</summary>
    private int DrawRow(
        Graphics graphics, string label, string value, int y, int contentWidth, Color? valueColor = null)
    {
        using var muted = new SolidBrush(Palette.Muted);
        using var text = new SolidBrush(valueColor ?? Palette.Text);

        graphics.DrawString(label, _labelFont, muted, Pad, y);

        if (!string.IsNullOrEmpty(value))
        {
            SizeF size = graphics.MeasureString(value, _valueFont);
            graphics.DrawString(value, _valueFont, text, Pad + contentWidth - size.Width, y);
        }

        return y + RowHeight;
    }

    private static void DrawDottedRule(Graphics graphics, int x, int y, int width, Brush brush)
    {
        for (int offset = 0; offset < width; offset += 8)
            graphics.FillRectangle(brush, x + offset, y, 4, 4);
    }

    private Rectangle? ButtonAt(Point location) =>
        _folderButton.Contains(location) ? _folderButton :
        _closeButton.Contains(location) ? _closeButton :
        null;

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;

        if (ButtonAt(e.Location) is { } button)
        {
            _pressedButton = button;
            Invalidate(PixelButton.RepaintBounds(button));
            return;
        }

        // There is no title bar to grab, so the header doubles as one.
        if (e.Y > HeaderHeight) return;
        ReleaseCapture();
        SendMessage(Handle, WmNcLButtonDown, (IntPtr)HtCaption, IntPtr.Zero);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Rectangle? hovered = ButtonAt(e.Location);
        if (hovered == _hoveredButton) return;

        Rectangle? previous = _hoveredButton;
        _hoveredButton = hovered;
        if (previous is { } old) Invalidate(PixelButton.RepaintBounds(old));
        if (hovered is { } current) Invalidate(PixelButton.RepaintBounds(current));
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        Rectangle? pressed = _pressedButton;
        _pressedButton = null;
        if (pressed is not { } button) return;

        Invalidate(PixelButton.RepaintBounds(button));
        if (!button.Contains(e.Location)) return;

        if (button == _closeButton) Close();
        else OpenDataFolder();
    }

    private static void OpenDataFolder()
    {
        try
        {
            Directory.CreateDirectory(Settings.DataDirectory);
            Process.Start(new ProcessStartInfo(Settings.DataDirectory) { UseShellExecute = true });
        }
        catch
        {
            // Explorer refusing to open is not worth interrupting the user over.
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode is Keys.Escape) Close();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _titleFont.Dispose();
            _sectionFont.Dispose();
            _labelFont.Dispose();
            _valueFont.Dispose();
            _buttonFont.Dispose();
        }
        base.Dispose(disposing);
    }
}
