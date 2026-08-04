using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeUsage;

/// <summary>
/// Draws the tray icon: the orange pet. The percentage lives in the tooltip and the panel,
/// not on the icon itself.
/// <para>
/// Important: <see cref="Bitmap.GetHicon"/> produces a fresh GDI handle on every call and
/// <see cref="Icon.FromHandle"/> does not take ownership of it. In an app that refreshes every
/// 60 seconds that leaks handles. So the previous handle is kept and only destroyed with
/// DestroyIcon <b>after</b> the new one has been assigned to the NotifyIcon.
/// </para>
/// </summary>
internal sealed partial class TrayIconRenderer : IDisposable
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);

    private IntPtr _currentHandle = IntPtr.Zero;
    private Icon? _currentIcon;

    /// <summary>
    /// Updates the tray icon and releases the previous GDI handle in the safe order.
    /// The parameters don't affect the drawing yet; the icon is always the same pet.
    /// </summary>
    public void Apply(NotifyIcon target, double? percent, Color color)
    {
        using var bitmap = Draw(IconSize());

        IntPtr previousHandle = _currentHandle;
        Icon? previousIcon = _currentIcon;

        IntPtr handle = bitmap.GetHicon();
        var icon = Icon.FromHandle(handle);

        target.Icon = icon;          // assign the new icon first
        _currentHandle = handle;
        _currentIcon = icon;

        previousIcon?.Dispose();     // and only then release the old one
        if (previousHandle != IntPtr.Zero) DestroyIcon(previousHandle);
    }

    private static int IconSize()
    {
        int size = SystemInformation.SmallIconSize.Width;
        return size is >= 12 and <= 64 ? size : 16;
    }

    private static Bitmap Draw(int width)
    {
        // The pet's own aspect ratio is used instead of a square canvas (grid including the
        // outline: 18x13). On a square one it sat with wasted transparent space above and below,
        // unlike every other tray icon.
        int gridWidth = PetSprite.Columns + 2;
        int gridHeight = PetSprite.RowCount + 2;
        int height = (int)Math.Round(width * gridHeight / (double)gridWidth);

        var bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        bitmap.SetResolution(96, 96);

        using var graphics = Graphics.FromImage(bitmap);
        // Pixel art: no antialiasing, or it turns to mush at 16 px.
        graphics.SmoothingMode = SmoothingMode.None;
        graphics.PixelOffsetMode = PixelOffsetMode.Half;
        graphics.Clear(Color.Transparent);

        // The design is laid out on an 18-unit grid, then scaled to the real pixel size.
        // The canvas is that wide because the outline spills one unit outside the grid.
        float unit = width / (float)gridWidth;
        PetSprite.Draw(graphics, unit, unit, unit, Palette.Accent, Palette.Eye);

        return bitmap;
    }

    public void Dispose()
    {
        _currentIcon?.Dispose();
        _currentIcon = null;
        if (_currentHandle != IntPtr.Zero)
        {
            DestroyIcon(_currentHandle);
            _currentHandle = IntPtr.Zero;
        }
    }
}
