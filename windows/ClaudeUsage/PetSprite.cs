using System.Drawing;

namespace ClaudeUsage;

/// <summary>
/// The app's mascot. Single source of truth: both the tray icon and the panel header draw it.
/// </summary>
internal static class PetSprite
{
    /// <summary>
    /// A 16x11 pixel map. <c>X</c> is body, <c>O</c> is eye, <c>.</c> is transparent.
    /// It was cut from 12 rows down to 10 so the aspect ratio matches the reference art
    /// (~720x430, about 1.67), then one row was added back on top.
    /// </summary>
    public static readonly string[] Rows =
    [
        "..XXXXXXXXXXXX..",
        "..XXXXXXXXXXXX..",
        "..XXOXXXXXXOXX..",
        "..XXOXXXXXXOXX..",
        "XXXXXXXXXXXXXXXX",
        "XXXXXXXXXXXXXXXX",
        "..XXXXXXXXXXXX..",
        "..XXXXXXXXXXXX..",
        "..XXXXXXXXXXXX..",
        "...X.X....X.X...",
        "...X.X....X.X...",
    ];

    public const int Columns = 16;
    public static int RowCount => Rows.Length;

    /// <summary>The outline drawn around the silhouette. Always black, whatever the backdrop.</summary>
    public static readonly Color Outline = ColorTranslator.FromHtml("#000000");

    /// <summary>
    /// Draws the pet with <paramref name="unit"/>-pixel cells. Each cell boundary is rounded
    /// separately; using one shared width would leave gaps between cells. A one-cell black
    /// outline follows the silhouette's real shape rather than boxing it in a rectangle.
    /// </summary>
    public static void Draw(Graphics graphics, float originX, float originY, float unit, Color body, Color eye)
    {
        using var bodyBrush = new SolidBrush(body);
        using var eyeBrush = new SolidBrush(eye);
        using var outlineBrush = new SolidBrush(Outline);

        for (int row = -1; row <= Rows.Length; row++)
        {
            for (int column = -1; column <= Columns; column++)
            {
                if (IsFilled(row, column)) continue;
                if (!HasFilledNeighbor(row, column)) continue;

                DrawCell(graphics, outlineBrush, originX, originY, unit, row, column);
            }
        }

        for (int row = 0; row < Rows.Length; row++)
        {
            string line = Rows[row];
            for (int column = 0; column < line.Length; column++)
            {
                Brush? brush = line[column] switch
                {
                    'X' => bodyBrush,
                    'O' => eyeBrush,
                    _ => null,
                };
                if (brush is null) continue;

                DrawCell(graphics, brush, originX, originY, unit, row, column);
            }
        }
    }

    private static bool IsFilled(int row, int column)
    {
        if (row < 0 || row >= Rows.Length || column < 0 || column >= Columns) return false;
        return Rows[row][column] != '.';
    }

    /// <summary>
    /// Diagonal neighbors count too - otherwise the outline breaks at outer corners
    /// (the ear and leg tips).
    /// </summary>
    private static bool HasFilledNeighbor(int row, int column)
    {
        for (int dr = -1; dr <= 1; dr++)
        for (int dc = -1; dc <= 1; dc++)
        {
            if (dr == 0 && dc == 0) continue;
            if (IsFilled(row + dr, column + dc)) return true;
        }
        return false;
    }

    private static void DrawCell(
        Graphics graphics, Brush brush, float originX, float originY, float unit, int row, int column)
    {
        int x = Round(originX, column, unit);
        int y = Round(originY, row, unit);
        graphics.FillRectangle(brush, x, y,
            Round(originX, column + 1, unit) - x,
            Round(originY, row + 1, unit) - y);
    }

    private static int Round(float origin, float cells, float unit) => (int)MathF.Round(origin + cells * unit);
}
