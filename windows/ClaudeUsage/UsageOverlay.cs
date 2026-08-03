using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeUsage;

/// <summary>
/// A small always-on-top window: the pet, with a block bar under it showing the remaining
/// limit. The backdrop is fully transparent, so only the figure itself is visible.
/// Press and hold to drag it; the position is written back to the settings.
/// It shows no taskbar button (a deliberate choice) and stays out of the alt-tab list.
/// </summary>
internal sealed class UsageOverlay : Form
{
    private const int Unit = 6;                       // pet cell, in pixels
    private const int BarHeight = 14;
    private const int BarSegments = 20;               // each block is 5%
    private const int GapAboveBar = 10;
    private const int BarFrame = 4;                    // one-piece black frame around the bar; close in weight to the pet outline (Unit=6)

    /// <summary>
    /// The transparency key. Every pixel painted in this color becomes invisible and passes
    /// clicks through to the window underneath, so it has to be a color the palette never uses.
    /// </summary>
    private static readonly Color ChromaKey = Color.FromArgb(255, 0, 255);

    private const int WmNcLButtonDown = 0x00A1;
    private const int HtCaption = 0x0002;
    private const int WsExNoActivate = 0x08000000;
    private const int WsExToolWindow = 0x00000080;

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    private double? _percent;
    private Color _color = Palette.Accent;

    /// <summary>Reports the new position once a drag ends; saving it is the caller's job.</summary>
    public event EventHandler? PositionChanged;

    public UsageOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = ChromaKey;
        TransparencyKey = ChromaKey;
        DoubleBuffered = true;

        // The window is one unit wider and taller on every side because the outline spills
        // one unit outside the grid. The bar frame asks for extra room at the bottom too.
        Width = (PetSprite.Columns + 2) * Unit;
        Height = (PetSprite.RowCount + 2) * Unit + GapAboveBar + BarHeight + BarFrame * 2;

        MouseDown += OnDragStart;
    }

    /// <summary>Never steals focus; clicking it leaves the window underneath active.</summary>
    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var createParams = base.CreateParams;
            createParams.ExStyle |= WsExNoActivate | WsExToolWindow;
            return createParams;
        }
    }

    public void SetUsage(double? percent, Color color)
    {
        _percent = percent;
        _color = color;
        Invalidate();
    }

    /// <summary>Applies the saved position, pulling it to the bottom right if it's off-screen.</summary>
    public void RestorePosition(int x, int y)
    {
        var work = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);

        bool onAnyScreen = Screen.AllScreens.Any(screen =>
            screen.WorkingArea.IntersectsWith(new Rectangle(x, y, Width, Height)));

        if (!onAnyScreen)
        {
            x = work.Right - Width - 24;
            y = work.Bottom - Height - 24;
        }

        Location = new Point(x, y);
    }

    private void OnDragStart(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;

        // Rather than writing our own drag loop, we let Windows move the window as if the
        // cursor were on a title bar.
        ReleaseCapture();
        SendMessage(Handle, WmNcLButtonDown, (IntPtr)HtCaption, IntPtr.Zero);
        PositionChanged?.Invoke(this, EventArgs.Empty);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var graphics = e.Graphics;
        graphics.SmoothingMode = SmoothingMode.None;
        graphics.PixelOffsetMode = PixelOffsetMode.Half;
        graphics.InterpolationMode = InterpolationMode.NearestNeighbor;

        // The eyes are not left transparent: they would read as white over a light backdrop.
        // They're filled with a fixed dark color instead.
        PetSprite.Draw(graphics, Unit, Unit, Unit, Palette.Accent, Palette.Eye);

        int barY = (PetSprite.RowCount + 2) * Unit + GapAboveBar + BarFrame;
        DrawBar(graphics, BarFrame, barY, Width - BarFrame * 2);
    }

    /// <summary>
    /// The bar is wrapped in a single black frame, and the blocks inside it sit flush together.
    /// </summary>
    private void DrawBar(Graphics graphics, int x, int y, int width)
    {
        using var outline = new SolidBrush(PetSprite.Outline);
        graphics.FillRectangle(outline,
            x - BarFrame, y - BarFrame, width + BarFrame * 2, BarHeight + BarFrame * 2);

        using var channel = new SolidBrush(Palette.Channel);
        using var fill = new SolidBrush(_color);

        double percent = Math.Clamp(_percent ?? 0, 0, 100);
        int filled = (int)Math.Round(BarSegments * percent / 100.0);
        if (percent > 0 && filled == 0) filled = 1;

        for (int index = 0; index < BarSegments; index++)
        {
            // Block edges are rounded one at a time, or the error accumulates into a visible
            // drift at the right edge.
            int left = x + (int)Math.Round(index * (double)width / BarSegments);
            int right = x + (int)Math.Round((index + 1) * (double)width / BarSegments);
            graphics.FillRectangle(index < filled ? fill : channel,
                left, y, right - left, BarHeight);
        }
    }
}
