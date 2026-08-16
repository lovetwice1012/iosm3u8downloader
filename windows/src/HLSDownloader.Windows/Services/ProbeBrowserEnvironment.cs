using HLSDownloader.WebProbe;
using Microsoft.Web.WebView2.Core;

namespace HLSDownloader.Windows.Services;

internal static class ProbeBrowserEnvironment
{
    private static readonly Lazy<Task<CoreWebView2Environment>> SharedEnvironment = new(
        CreateAsync,
        LazyThreadSafetyMode.ExecutionAndPublication);

    public static Task<CoreWebView2Environment> GetAsync() => SharedEnvironment.Value;

    private static async Task<CoreWebView2Environment> CreateAsync()
    {
        var localApplicationData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolderOption.DoNotVerify);
        var userDataFolder = ProbeBrowserProfilePath.FromLocalApplicationData(localApplicationData);

        // Do not silently fall back to the portable executable directory. A
        // custom UDF is required so login/session data remains available across
        // app updates and the directory is guaranteed to be user-writable.
        return await CoreWebView2Environment.CreateWithOptionsAsync(
            null,
            userDataFolder,
            new CoreWebView2EnvironmentOptions());
    }
}
