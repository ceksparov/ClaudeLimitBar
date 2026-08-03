using System.Drawing;

namespace ClaudeUsage;

/// <summary>
/// 3x5 pixel digits. Percentages are drawn with these rather than a system font; the panel's
/// pixel-art look only holds together when the numbers are built from blocks too.
/// </summary>
internal static class PixelFont
{
    private const int GlyphWidth = 3;
    private const int GlyphHeight = 5;
    private const int Spacing = 1;   // letter spacing, in cells

    private static readonly Dictionary<char, string[]> Glyphs = new()
    {
        ['0'] = ["XXX", "X.X", "X.X", "X.X", "XXX"],
        ['1'] = ["..X", "..X", "..X", "..X", "..X"],
        ['2'] = ["XXX", "..X", "XXX", "X..", "XXX"],
        ['3'] = ["XXX", "..X", "XXX", "..X", "XXX"],
        ['4'] = ["X.X", "X.X", "XXX", "..X", "..X"],
        ['5'] = ["XXX", "X..", "XXX", "..X", "XXX"],
        ['6'] = ["XXX", "X..", "XXX", "X.X", "XXX"],
        ['7'] = ["XXX", "..X", "..X", "..X", "..X"],
        ['8'] = ["XXX", "X.X", "XXX", "X.X", "XXX"],
        ['9'] = ["XXX", "X.X", "XXX", "..X", "XXX"],
        ['%'] = ["X.X", "..X", ".X.", "X..", "X.X"],
        ['.'] = ["...", "...", "...", "...", "..X"],
        [','] = ["...", "...", "...", "..X", ".X."],
        ['$'] = [".X.", "XXX", "XX.", ".XX", "XXX"],
        [' '] = ["...", "...", "...", "...", "..."],
    };

    public static int Height(int cell) => GlyphHeight * cell;

    public static int Width(string text, int cell) =>
        text.Length == 0 ? 0 : text.Length * GlyphWidth * cell + (text.Length - 1) * Spacing * cell;

    public static void Draw(Graphics graphics, string text, int x, int y, int cell, Color color)
    {
        using var brush = new SolidBrush(color);
        int cursor = x;

        foreach (char character in text)
        {
            if (!Glyphs.TryGetValue(character, out string[]? glyph))
            {
                cursor += (GlyphWidth + Spacing) * cell;
                continue;
            }

            for (int row = 0; row < GlyphHeight; row++)
                for (int column = 0; column < GlyphWidth; column++)
                    if (glyph[row][column] == 'X')
                        graphics.FillRectangle(brush, cursor + column * cell, y + row * cell, cell, cell);

            cursor += (GlyphWidth + Spacing) * cell;
        }
    }
}
