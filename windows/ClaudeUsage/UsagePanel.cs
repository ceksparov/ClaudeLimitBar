using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace ClaudeUsage;

/// <summary>
/// The usage panel, opened with a left click. Drawn entirely with GDI+ in a pixel-art idiom:
/// square corners, block bars, pixel digits.
/// </summary>
internal sealed class UsagePanel : Form
{
    private const int PanelWidth = 336;
    private const int PadX = 16;
    private const int PadTop = 14;
    private const int PadBottom = 16;
    private const int BorderWidth = 2;

    private const int HeaderHeight = 48;
    private const int LabelHeight = 22;           // gap between label and percentage
    private const int PercentCell = 3;            // pixel-digit cell size
    private const int ValueHeight = 29;           // percentage block plus breathing room below it
    private const int BarHeight = 10;
    private const int BarSegments = 20;           // each block is 5%
    private const int BarGap = 2;
    private const int RowGap = 24;                // gap between rows
    private const int SpendHeight = 56;

    private readonly Font _titleFont = new(Palette.FontFamily, 9.5f, FontStyle.Bold);
    private readonly Font _labelFont = new(Palette.FontFamily, 7.5f, FontStyle.Bold);
    private readonly Font _resetFont = new(Palette.FontFamily, 8f);
    private readonly Font _messageFont = new(Palette.FontFamily, 9f);

    private List<UsageRow> _rows = [];
    private string? _spendText;
    private string? _message;

    /// <summary>Stops the click that follows a Deactivate-triggered hide from reopening the panel.</summary>
    private DateTime _hiddenAt = DateTime.MinValue;

    public UsagePanel()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Palette.Background;
        DoubleBuffered = true;
        Width = PanelWidth;
        Height = 140;
        KeyPreview = true;
    }

    protected override bool ShowWithoutActivation => false;

    protected override CreateParams CreateParams
    {
        get
        {
            var createParams = base.CreateParams;
            createParams.ClassStyle |= 0x00020000; // CS_DROPSHADOW
            return createParams;
        }
    }

    public void SetData(IEnumerable<UsageRow> rows, string? spendText)
    {
        _rows = rows.ToList();
        _spendText = spendText;
        _message = null;
        Relayout();
    }

    public void SetMessage(string message)
    {
        _message = message;
        Relayout();
    }

    /// <summary>Called when the tray icon is left-clicked.</summary>
    public void Toggle()
    {
        if (Visible)
        {
            HidePanel();
            return;
        }

        if ((DateTime.UtcNow - _hiddenAt).TotalMilliseconds < 250) return;

        Relayout();
        PositionNearCursor();
        Show();
        Activate();
    }

    public void HidePanel()
    {
        if (!Visible) return;
        _hiddenAt = DateTime.UtcNow;
        Hide();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        HidePanel();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Escape) HidePanel();
    }

    private static int RowHeight() => LabelHeight + ValueHeight + BarHeight + RowGap;

    private void Relayout()
    {
        int height = PadTop + HeaderHeight;

        if (_message is not null) height += 48;
        else
        {
            height += _rows.Count * RowHeight();
            if (_spendText is not null) height += SpendHeight;
        }

        Width = PanelWidth;
        Height = Math.Max(120, height + PadBottom);
        Invalidate();
    }

    private void PositionNearCursor()
    {
        var cursor = Cursor.Position;
        var work = Screen.FromPoint(cursor).WorkingArea;

        int x = cursor.X - Width / 2;
        int y = cursor.Y > work.Top + work.Height / 2
            ? work.Bottom - Height - 8   // taskbar at the bottom
            : work.Top + 8;              // taskbar at the top

        // Keep the panel inside the working area even when the taskbar is on the left or right.
        x = Math.Clamp(x, work.Left + 8, Math.Max(work.Left + 8, work.Right - Width - 8));
        y = Math.Clamp(y, work.Top + 8, Math.Max(work.Top + 8, work.Bottom - Height - 8));

        Location = new Point(x, y);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var graphics = e.Graphics;
        // Pixel art: everything hard-edged. Text sits on the same hard grid rather than
        // being smoothed by ClearType.
        graphics.SmoothingMode = SmoothingMode.None;
        graphics.PixelOffsetMode = PixelOffsetMode.Half;
        graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
        graphics.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;

        DrawFrame(graphics);

        int contentWidth = Width - PadX * 2;
        int y = PadTop;

        DrawHeader(graphics, y, contentWidth);
        y += HeaderHeight;

        if (_message is not null)
        {
            using var muted = new SolidBrush(Palette.Muted);
            graphics.DrawString(_message, _messageFont, muted,
                new RectangleF(PadX, y, contentWidth, 60));
            return;
        }

        foreach (var row in _rows)
        {
            DrawRow(graphics, row, y, contentWidth);
            y += RowHeight();
        }

        if (_spendText is not null) DrawSpend(graphics, y, contentWidth);
    }

    /// <summary>A heavy, square, two-layer frame, like the ones in Minecraft's UI.</summary>
    private void DrawFrame(Graphics graphics)
    {
        using (var background = new SolidBrush(Palette.Background))
        {
            graphics.FillRectangle(background, 0, 0, Width, Height);
        }

        using (var outer = new SolidBrush(Palette.Border))
        {
            graphics.FillRectangle(outer, 0, 0, Width, BorderWidth);
            graphics.FillRectangle(outer, 0, Height - BorderWidth, Width, BorderWidth);
            graphics.FillRectangle(outer, 0, 0, BorderWidth, Height);
            graphics.FillRectangle(outer, Width - BorderWidth, 0, BorderWidth, Height);
        }

        using (var inner = new SolidBrush(Palette.Panel))
        {
            graphics.FillRectangle(inner,
                BorderWidth, BorderWidth, Width - BorderWidth * 2, Height - BorderWidth * 2);
        }
    }

    private void DrawHeader(Graphics graphics, int y, int contentWidth)
    {
        PetSprite.Draw(graphics, PadX, y, 2f, Palette.Accent, Palette.Eye);

        using (var text = new SolidBrush(Palette.Text))
        {
            graphics.DrawString("CLAUDE USAGE", _titleFont, text, PadX + 40, y + 4);
        }

        // The separator is a run of pixels, not a solid rule.
        DrawDottedRule(graphics, PadX, y + HeaderHeight - 16, contentWidth);
    }

    private static void DrawDottedRule(Graphics graphics, int x, int y, int width)
    {
        using var brush = new SolidBrush(Palette.Border);
        for (int offset = 0; offset < width; offset += 4)
        {
            graphics.FillRectangle(brush, x + offset, y, 2, 2);
        }
    }

    private void DrawRow(Graphics graphics, UsageRow row, int y, int contentWidth)
    {
        using var muted = new SolidBrush(Palette.Muted);

        graphics.DrawString(row.Label.ToUpperInvariant(), _labelFont, muted, PadX, y);

        PixelFont.Draw(graphics, row.PercentText, PadX, y + LabelHeight, PercentCell, row.Color);

        // The reset text is right-aligned and sits on the baseline of the pixel digits.
        var resetSize = graphics.MeasureString(row.ResetText, _resetFont);
        graphics.DrawString(row.ResetText, _resetFont, muted,
            PadX + contentWidth - resetSize.Width,
            y + LabelHeight + PixelFont.Height(PercentCell) - resetSize.Height);

        DrawBar(graphics, PadX, y + LabelHeight + ValueHeight, contentWidth, row.ClampedPercent, row.Color);
    }

    private void DrawSpend(Graphics graphics, int y, int contentWidth)
    {
        DrawDottedRule(graphics, PadX, y, contentWidth);

        using var muted = new SolidBrush(Palette.Muted);
        graphics.DrawString("EXTRA USAGE", _labelFont, muted, PadX, y + 16);

        string text = _spendText ?? string.Empty;
        int width = PixelFont.Width(text, PercentCell);
        PixelFont.Draw(graphics, text, PadX + contentWidth - width, y + 16, PercentCell, Palette.Text);
    }

    /// <summary>The block bar: no rounded caps, just 5% squares.</summary>
    private static void DrawBar(Graphics graphics, int x, int y, int width, double percent, Color color)
    {
        using var channel = new SolidBrush(Palette.Channel);
        using var fill = new SolidBrush(color);

        int filled = (int)Math.Round(BarSegments * percent / 100.0);
        if (percent > 0 && filled == 0) filled = 1;   // anything above zero should show

        for (int index = 0; index < BarSegments; index++)
        {
            // Block edges are rounded one at a time, or the error accumulates into a visible
            // drift at the right edge.
            int left = x + (int)Math.Round(index * (double)width / BarSegments);
            int right = x + (int)Math.Round((index + 1) * (double)width / BarSegments);
            graphics.FillRectangle(index < filled ? fill : channel,
                left, y, Math.Max(1, right - left - BarGap), BarHeight);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _titleFont.Dispose();
            _labelFont.Dispose();
            _resetFont.Dispose();
            _messageFont.Dispose();
        }
        base.Dispose(disposing);
    }
}
