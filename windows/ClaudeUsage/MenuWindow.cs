using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeUsage;

/// <summary>
/// The menu window, opened from the tray icon's context menu. The body is deliberately empty
/// for now - this establishes the frame, the header and the button so the content can be
/// dropped in later without redesigning anything.
/// </summary>
internal sealed class MenuWindow : Form
{
    private const int WindowWidth = 420;
    private const int WindowHeight = 340;
    private const int Pad = 22;
    private const int HeaderHeight = 66;

    private const int WmNcLButtonDown = 0x00A1;
    private const int HtCaption = 0x0002;

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    private readonly Rectangle _closeButton = new(120, 254, 180, 44);
    private readonly Font _titleFont = new(Palette.FontFamily, 14f, FontStyle.Bold);
    private readonly Font _buttonFont = new(Palette.FontFamily, 11f, FontStyle.Bold);
    private bool _closeHovered;
    private bool _closePressed;

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

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics graphics = e.Graphics;
        // Same pixel-art rules as the usage panel: hard edges everywhere.
        graphics.SmoothingMode = SmoothingMode.None;
        graphics.PixelOffsetMode = PixelOffsetMode.Half;
        graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
        graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

        using var background = new SolidBrush(Palette.Background);
        using var panel = new SolidBrush(Palette.Panel);
        using var border = new SolidBrush(Palette.Border);
        using var accent = new SolidBrush(Palette.Accent);

        graphics.FillRectangle(background, ClientRectangle);
        graphics.FillRectangle(border, 0, 0, Width, 4);
        graphics.FillRectangle(border, 0, Height - 4, Width, 4);
        graphics.FillRectangle(border, 0, 0, 4, Height);
        graphics.FillRectangle(border, Width - 4, 0, 4, Height);
        graphics.FillRectangle(panel, 4, 4, Width - 8, Height - 8);

        PetSprite.Draw(graphics, Pad, 20, 2.5f, Palette.Accent, Palette.Eye);
        graphics.DrawString("MENU", _titleFont, accent, Pad + 54, 24);
        DrawDottedRule(graphics, Pad, HeaderHeight, Width - Pad * 2, border);

        // The body between the rule and the button is intentionally left empty.

        PixelButton.Draw(graphics, _closeButton, "CLOSE", _buttonFont, _closeHovered, _closePressed);
    }

    private static void DrawDottedRule(Graphics graphics, int x, int y, int width, Brush brush)
    {
        for (int offset = 0; offset < width; offset += 8)
            graphics.FillRectangle(brush, x + offset, y, 4, 4);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;

        if (_closeButton.Contains(e.Location))
        {
            _closePressed = true;
            Invalidate(PixelButton.RepaintBounds(_closeButton));
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
        bool hovered = _closeButton.Contains(e.Location);
        if (hovered == _closeHovered) return;
        _closeHovered = hovered;
        Invalidate(PixelButton.RepaintBounds(_closeButton));
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        bool accept = _closePressed && _closeButton.Contains(e.Location);
        _closePressed = false;
        if (accept) Close();
        else Invalidate(PixelButton.RepaintBounds(_closeButton));
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
            _buttonFont.Dispose();
        }
        base.Dispose(disposing);
    }
}
