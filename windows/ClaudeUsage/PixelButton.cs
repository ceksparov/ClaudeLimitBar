using System.Drawing;
using System.Windows.Forms;

namespace ClaudeUsage;

/// <summary>
/// The one button style the app uses: a square face with a black outline, a hard border on
/// the top and left edges, and an accent shadow slipped under the bottom. Shared so every
/// window that needs a button looks like it came from the same place.
/// </summary>
internal static class PixelButton
{
    private static readonly Color Face = Color.FromArgb(46, 42, 49);
    private static readonly Color FaceHovered = Color.FromArgb(57, 52, 61);

    public static void Draw(
        Graphics graphics, Rectangle bounds, string text, Font font, bool hovered, bool pressed)
    {
        Color faceColor = pressed ? Palette.Border : hovered ? FaceHovered : Face;

        using var face = new SolidBrush(faceColor);
        using var outline = new SolidBrush(PetSprite.Outline);
        using var border = new SolidBrush(Palette.Border);
        using var accent = new SolidBrush(Palette.Accent);

        graphics.FillRectangle(outline, bounds.X - 4, bounds.Y - 4, bounds.Width + 8, bounds.Height + 8);
        graphics.FillRectangle(accent, bounds.X + 3, bounds.Bottom, bounds.Width, 4);
        graphics.FillRectangle(face, bounds);
        graphics.FillRectangle(border, bounds.X, bounds.Y, bounds.Width, 4);
        graphics.FillRectangle(border, bounds.X, bounds.Y, 4, bounds.Height);

        TextRenderer.DrawText(graphics, text, font, bounds, Palette.Text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }

    /// <summary>The area a repaint has to cover: the button, its outline and its shadow.</summary>
    public static Rectangle RepaintBounds(Rectangle bounds) =>
        new(bounds.X - 5, bounds.Y - 5, bounds.Width + 10, bounds.Height + 14);
}
