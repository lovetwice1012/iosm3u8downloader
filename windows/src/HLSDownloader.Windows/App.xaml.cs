using Microsoft.UI.Xaml;
using HLSDownloader.Core;

namespace HLSDownloader.Windows;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            System.Diagnostics.Debug.WriteLine(args.Exception);
            WriteStartupFailure(args.Exception);
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            _window = new MainWindow();
            _window.Activate();
        }
        catch (Exception exception)
        {
            WriteStartupFailure(exception);
            throw;
        }
    }

    private static void WriteStartupFailure(Exception exception)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "HLSDownloader.Windows");
            Directory.CreateDirectory(directory);
            var details = new List<string>();
            for (var current = exception; current is not null; current = current.InnerException)
            {
                details.Add($"{current.GetType().FullName} (0x{current.HResult:X8}): {current.Message}");
                if (!string.IsNullOrWhiteSpace(current.StackTrace))
                {
                    details.Add(current.StackTrace);
                }
            }

            var message = DiagnosticRedactor.Redact(string.Join(Environment.NewLine, details));
            var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!string.IsNullOrWhiteSpace(profile))
            {
                message = message.Replace(profile, "[local-path]", StringComparison.OrdinalIgnoreCase);
            }

            File.WriteAllText(Path.Combine(directory, "startup-failure.log"), message);
        }
        catch (Exception)
        {
        }
    }
}
