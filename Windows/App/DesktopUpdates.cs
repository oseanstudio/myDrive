using System.Text.Json;
using Microsoft.Win32;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer updateTimer = new() { Interval = TimeSpan.FromHours(6) };
    private readonly Button updateOffer = new()
    {
        Visibility = Visibility.Collapsed,
        Margin = new Thickness(8, 0, 8, 0),
    };
    private bool checkingForUpdate;
    private bool showUpdateResult;
    private bool updatingApp;
    private string? offeredAppVersion;

    private void StartUpdateChecks()
    {
        updateOffer.Click += (_, _) => _ = InstallUpdate();
        updateTimer.Tick += (_, _) => _ = CheckForUpdate();
        updateTimer.Start();
        _ = ReadUpdateError();
        _ = CheckForUpdate();
    }

    private async Task ReadUpdateError()
    {
        try
        {
            var error = await CoreBridge.Call(new { action = "update.error", data_dir = CoreBridge.DataDir });
            if (!quitting && error.ValueKind == JsonValueKind.String)
                Info("Could not update myDrive", error.GetString()!);
        }
        catch { /* An absent update result must not affect startup. */ }
    }

    private async Task CheckForUpdate(bool showResult = false)
    {
        if (diagnosticMode || quitting || updatingApp) return;
        showUpdateResult |= showResult;
        if (checkingForUpdate) return;
        checkingForUpdate = true;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            var result = await CoreBridge.Call(new { action = "update.check", payload = new { version = DisplayVersion } }, timeout.Token);
            if (quitting || updatingApp) return;
            if (result.ValueKind == JsonValueKind.Object)
            {
                offeredAppVersion = result.GetProperty("version").GetString();
                updateOffer.Content = $"Update to myDrive {offeredAppVersion}";
                updateOffer.Visibility = Visibility.Visible;
            }
            else
            {
                offeredAppVersion = null;
                updateOffer.Visibility = Visibility.Collapsed;
                if (showUpdateResult) Info("myDrive is up to date", $"You’re using version {DisplayVersion}.");
            }
        }
        catch (Exception)
        {
            if (showUpdateResult && !quitting)
                Info("Could not check for updates", "Try again when GitHub is available.");
        }
        finally
        {
            checkingForUpdate = false;
            showUpdateResult = false;
        }
    }

    private async Task InstallUpdate()
    {
        if (offeredAppVersion is not { } version || updatingApp || quitting) return;
        if (busy)
        {
            Info("An operation is running", "Finish the current operation before updating myDrive.");
            return;
        }
        var app = Environment.ProcessPath;
        using var registered = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\myDrive.OseanStudio_is1");
        var installDirectory = registered?.GetValue("InstallLocation") as string;
        if (app is null || string.IsNullOrEmpty(installDirectory) ||
            !string.Equals(Path.GetDirectoryName(app), Path.TrimEndingDirectorySeparator(installDirectory), StringComparison.OrdinalIgnoreCase))
        {
            Info("Install myDrive first", "Use the Windows installer from GitHub to enable in-app updates.");
            return;
        }
        updatingApp = true;
        updateOffer.IsEnabled = false;
        updateOffer.Content = $"Downloading myDrive {version}…";
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(11));
            await CoreBridge.Call(new
            {
                action = "update.install",
                data_dir = CoreBridge.DataDir,
                payload = new { version = DisplayVersion, target_version = version, app_path = app, pid = Environment.ProcessId },
            }, timeout.Token);
            updateOffer.Content = "Installing update…";
            Quit();
        }
        catch (Exception error)
        {
            updatingApp = false;
            updateOffer.IsEnabled = true;
            updateOffer.Content = $"Update to myDrive {version}";
            if (!quitting) Info("Could not update myDrive", error.Message);
        }
    }
}
