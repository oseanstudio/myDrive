using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer updateTimer = new() { Interval = TimeSpan.FromHours(6) };
    private readonly HyperlinkButton updateOffer = new()
    {
        Visibility = Visibility.Collapsed,
        Margin = new Thickness(8, 0, 8, 0),
    };
    private bool checkingForUpdate;
    private bool showUpdateResult;

    private void StartUpdateChecks()
    {
        updateTimer.Tick += (_, _) => _ = CheckForUpdate();
        updateTimer.Start();
        _ = CheckForUpdate();
    }

    private async Task CheckForUpdate(bool showResult = false)
    {
        if (diagnosticMode || quitting) return;
        showUpdateResult |= showResult;
        if (checkingForUpdate) return;
        checkingForUpdate = true;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            var result = await CoreBridge.Call(new { action = "update.check", payload = new { version = DisplayVersion } }, timeout.Token);
            if (quitting) return;
            if (result.ValueKind == JsonValueKind.Object)
            {
                updateOffer.Content = $"Download myDrive {result.GetProperty("version").GetString()}";
                updateOffer.NavigateUri = new Uri(result.GetProperty("url").GetString()!);
                updateOffer.Visibility = Visibility.Visible;
            }
            else
            {
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
}
