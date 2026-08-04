using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace ClaudeUsage;

/// <summary>Reminder shown when the five-hour usage window has not started.</summary>
internal sealed class LimitResetNotification : Form
{
    private const int WindowWidth = 570;
    private const int WindowHeight = 394;
    private readonly Rectangle _button = new(148, 316, 274, 52);
    private readonly Font _titleFont = new(Palette.FontFamily, 16f, FontStyle.Bold);
    private readonly Font _bodyFont = new(Palette.FontFamily, 15f);
    private readonly Font _buttonFont = new(Palette.FontFamily, 13f, FontStyle.Bold);
    private bool _buttonHovered;
    private bool _buttonPressed;

    public LimitResetNotification()
    {
        ClientSize = new Size(WindowWidth, WindowHeight);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.CenterScreen;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Palette.Background;
        DoubleBuffered = true;
        KeyPreview = true;
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

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics graphics = e.Graphics;
        graphics.SmoothingMode = SmoothingMode.None;
        graphics.PixelOffsetMode = PixelOffsetMode.Half;
        graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
        graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

        using var background = new SolidBrush(Palette.Background);
        using var panel = new SolidBrush(Palette.Panel);
        using var border = new SolidBrush(Palette.Border);
        using var accent = new SolidBrush(Palette.Accent);
        using var text = new SolidBrush(Palette.Text);

        graphics.FillRectangle(background, ClientRectangle);
        graphics.FillRectangle(border, 0, 0, Width, 4);
        graphics.FillRectangle(border, 0, Height - 4, Width, 4);
        graphics.FillRectangle(border, 0, 0, 4, Height);
        graphics.FillRectangle(border, Width - 4, 0, 4, Height);
        graphics.FillRectangle(panel, 4, 4, Width - 8, Height - 8);

        PetSprite.Draw(graphics, 28, 22, 3f, Palette.Accent, Palette.Eye);
        graphics.DrawString("LIMIT REMINDER", _titleFont, accent, 95, 35);
        DrawDottedRule(graphics, 28, 83, Width - 56, border);

        const string message =
            "Your 5-hour limit window hasn't started yet.\n" +
            "If you want, send a short throwaway message\n" +
            "now to start it - that way the window lines\n" +
            "up with the hours you actually plan to work,\n" +
            "and resets when it suits you best.";
        graphics.DrawString(message, _bodyFont, text, new RectangleF(30, 111, Width - 60, 184));

        PixelButton.Draw(graphics, _button, "OK", _buttonFont, _buttonHovered, _buttonPressed);
    }

    private static void DrawDottedRule(Graphics graphics, int x, int y, int width, Brush brush)
    {
        for (int offset = 0; offset < width; offset += 8)
            graphics.FillRectangle(brush, x + offset, y, 4, 4);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        bool hovered = _button.Contains(e.Location);
        if (hovered == _buttonHovered) return;
        _buttonHovered = hovered;
        Invalidate(PixelButton.RepaintBounds(_button));
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || !_button.Contains(e.Location)) return;
        _buttonPressed = true;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        bool accept = _buttonPressed && _button.Contains(e.Location);
        _buttonPressed = false;
        if (accept) Close();
        else Invalidate();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode is Keys.Enter or Keys.Escape) Close();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _titleFont.Dispose();
            _bodyFont.Dispose();
            _buttonFont.Dispose();
        }
        base.Dispose(disposing);
    }
}
