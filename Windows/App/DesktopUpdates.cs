using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.Win32;

namespace MyDrive;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer updateTimer = new() { Interval = TimeSpan.FromHours(6) };
    private readonly DispatcherTimer autoUpdateTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly Button updateOffer = CreateUpdateOffer();
    private readonly Button quickUpdateOffer = CreateUpdateOffer();

    private static Button CreateUpdateOffer() => new()
    {
        Visibility = Visibility.Collapsed,
        Height = 26,
        MinHeight = 0,
        MinWidth = 0,
        FontSize = 11,
        Padding = new Thickness(7, 0, 7, 0),
        VerticalAlignment = VerticalAlignment.Center,
    };
    private DateTime autoUpdateAfter;
    private bool updateChecksStarted;
    private bool checkingForUpdate;
    private bool showUpdateResult;
    private bool updatingApp;
    private bool manualUpdateRequested;
    private string? offeredAppVersion;
    private string? preparedUpdatePath;

    private async void StartUpdateChecks()
    {
        updateOffer.Click += (_, _) => _ = InstallUpdate();
        quickUpdateOffer.Click += (_, _) => _ = InstallUpdate();
        updateTimer.Tick += (_, _) => _ = CheckForUpdate();
        autoUpdateTimer.Tick += (_, _) =>
        {
            if (!manualUpdateRequested || UpdateIdle()) _ = InstallUpdate(automatic: !manualUpdateRequested);
        };
        try
        {
            var error = await CoreBridge.Call(new { action = "update.error", data_dir = CoreBridge.DataDir });
            if (!quitting && error.ValueKind == JsonValueKind.String)
            {
                autoUpdateAfter = DateTime.UtcNow.AddHours(1);
                Info("Could not update myDrive", error.GetString()!);
            }
        }
        catch { /* An absent update result must not affect startup. */ }
        if (quitting) return;
        updateChecksStarted = true;
        updateTimer.Start();
        await CheckForUpdate();
    }

    private CheckBox AutoUpdateSetting()
    {
        var setting = new CheckBox
        {
            Content = "Install updates automatically",
            IsChecked = Preferences.Current.AutoInstallUpdates,
        };
        ToolTipService.SetToolTip(setting, "Updates install when myDrive is in the background and idle.");
        setting.Click += (_, _) =>
        {
            bool previous = Preferences.Current.AutoInstallUpdates;
            Preferences.Current.AutoInstallUpdates = setting.IsChecked == true;
            try { Preferences.Save(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Preferences.Current.AutoInstallUpdates = previous;
                setting.IsChecked = previous;
                Info("Could not save update settings", e.Message);
                return;
            }
            UpdateAutoInstallTimer();
            if (Preferences.Current.AutoInstallUpdates) _ = CheckForUpdate();
        };
        return setting;
    }

    private async Task CheckForUpdate(bool showResult = false)
    {
        if (!updateChecksStarted || diagnosticMode || quitting || updatingApp) return;
        if (checkingForUpdate)
        {
            showUpdateResult |= showResult;
            return;
        }
        showUpdateResult = showResult;
        checkingForUpdate = true;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            var result = await CoreBridge.Call(new { action = "update.check", payload = new { version = DisplayVersion } }, timeout.Token);
            if (quitting || updatingApp) return;
            var version = result.ValueKind == JsonValueKind.Object ? result.GetProperty("version").GetString() : null;
            if (version != offeredAppVersion)
            {
                manualUpdateRequested = false;
                await DiscardPreparedUpdate();
            }
            offeredAppVersion = version;
            UpdateOfferLabel();
            if (version is null && showUpdateResult) Info("myDrive is up to date", $"You’re using version {DisplayVersion}.");
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
        await InstallUpdate(automatic: true);
    }

    private bool UpdateIdle()
    {
        var transfers = blipSnapshot?.Transfers;
        return !busy && modalDepth == 0 && (transfers == null ||
            !transfers.Any(t => t.IsLive && t.Status is "Created" or "Pending" or "Active" or "ResumeRequested"));
    }

    private bool CanAutoInstall() =>
        Preferences.Current.AutoInstallUpdates && DateTime.UtcNow >= autoUpdateAfter &&
        (!AppWindow.IsVisible || AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized }) &&
        hostedShares.Count == 0;

    private void UpdateOfferLabel()
    {
        string? title = offeredAppVersion is { } version
            ? preparedUpdatePath is null ? $"Update to myDrive {version}" : $"Install myDrive {version}"
            : null;
        ShowUpdateOffers(preparedUpdatePath is null ? "Update" : "Install", title, enabled: !updatingApp);
        UpdateAutoInstallTimer();
    }

    private void ShowUpdateOffers(string label, string? title, bool enabled)
    {
        foreach (var button in new[] { quickUpdateOffer, updateOffer })
        {
            button.Visibility = title is null ? Visibility.Collapsed : Visibility.Visible;
            button.Content = label;
            button.IsEnabled = enabled;
            ToolTipService.SetToolTip(button, title);
            AutomationProperties.SetName(button, title ?? label);
        }
    }

    private void UpdateAutoInstallTimer()
    {
        if (!quitting && offeredAppVersion != null && (Preferences.Current.AutoInstallUpdates || manualUpdateRequested))
            autoUpdateTimer.Start();
        else
            autoUpdateTimer.Stop();
    }

    private async Task InstallUpdate(bool automatic = false)
    {
        if (offeredAppVersion is not { } version || checkingForUpdate || updatingApp || quitting) return;
        if (automatic && !CanAutoInstall()) return;
        if (!UpdateIdle())
        {
            if (!automatic) Info("An operation is running", "Finish the current operation before updating myDrive.");
            return;
        }
        var app = Environment.ProcessPath;
        using var registered = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\myDrive.OseanStudio_is1");
        var installDirectory = registered?.GetValue("InstallLocation") as string;
        if (app is null || string.IsNullOrEmpty(installDirectory) ||
            !string.Equals(Path.GetDirectoryName(app), Path.TrimEndingDirectorySeparator(installDirectory), StringComparison.OrdinalIgnoreCase))
        {
            autoUpdateAfter = DateTime.UtcNow.AddHours(1);
            if (!automatic) Info("Install myDrive first", "Use the Windows installer from GitHub to enable in-app updates.");
            return;
        }
        updatingApp = true;
        manualUpdateRequested |= !automatic;
        try
        {
            if (preparedUpdatePath is null)
            {
                ShowUpdateOffers("Updating…", $"Downloading myDrive {version}…", enabled: false);
                using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(11));
                var prepared = await CoreBridge.Call(new
                {
                    action = "update.stage",
                    data_dir = CoreBridge.DataDir,
                    payload = new { version = DisplayVersion, target_version = version, app_path = app, pid = Environment.ProcessId },
                }, timeout.Token);
                preparedUpdatePath = prepared.GetProperty("plan_path").GetString();
            }
            if (quitting)
            {
                await DiscardPreparedUpdate();
                return;
            }
            if (!UpdateIdle() || (automatic && !CanAutoInstall())) return;
            ShowUpdateOffers("Updating…", $"Installing myDrive {version}…", enabled: false);
            await UsePreparedUpdate("update.apply", preparedUpdatePath!);
            preparedUpdatePath = null;
            Quit();
        }
        catch (Exception error)
        {
            manualUpdateRequested = false;
            autoUpdateAfter = DateTime.UtcNow.AddHours(1);
            if (!quitting) Info("Could not update myDrive", error.Message);
        }
        finally
        {
            if (!quitting) { updatingApp = false; UpdateOfferLabel(); }
        }
    }

    private async Task DiscardPreparedUpdate()
    {
        if (preparedUpdatePath is not { } path) return;
        preparedUpdatePath = null;
        try { await UsePreparedUpdate("update.discard", path); }
        catch { /* Cleanup must not block the app from closing or detecting an update. */ }
    }

    private async Task UsePreparedUpdate(string action, string path)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await CoreBridge.Call(new
        {
            action, data_dir = CoreBridge.DataDir,
            payload = new { plan_path = path, app_path = Environment.ProcessPath, pid = Environment.ProcessId },
        }, timeout.Token);
    }
}
