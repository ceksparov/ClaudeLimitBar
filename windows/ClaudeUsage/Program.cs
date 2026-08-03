using System.Windows.Forms;

namespace ClaudeUsage;

internal static class Program
{
    private const string MutexName = @"Local\ClaudeUsage.SingleInstance";

    [STAThread]
    private static void Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        if (args.Contains("--preview-notification", StringComparer.OrdinalIgnoreCase))
        {
            using var preview = new LimitResetNotification();
            Application.Run(preview);
            return;
        }

        using var mutex = new Mutex(initiallyOwned: true, MutexName, out bool isFirstInstance);
        if (!isFirstInstance) return;

        Application.ThreadException += (_, e) => ShowFatal(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => ShowFatal(e.ExceptionObject as Exception);

        using var context = new TrayAppContext();
        Application.Run(context);

        GC.KeepAlive(mutex);
    }

    private static void ShowFatal(Exception? exception)
    {
        MessageBox.Show(
            exception?.Message ?? "An unexpected error occurred.",
            "Claude Usage",
            MessageBoxButtons.OK,
            MessageBoxIcon.Error);
    }
}
