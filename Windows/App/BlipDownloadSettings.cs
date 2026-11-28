using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MyDrive;

public sealed partial class MainWindow
{
    private string[] previousBlipDownloadFolders = [];

    private Task<JsonElement> DownloadSettings(string action, string? folder = null) => CoreBridge.Call(new
    {
        action = "blip.downloads." + action, data_dir = CoreBridge.DataDir, payload = new { path = folder }
    });

    private void ApplyBlipDownloadSettings(JsonElement settings)
    {
        blip.CustomDownloadsDirectory = B(settings, "custom") ? S(settings, "path") : null;
        previousBlipDownloadFolders = settings.GetProperty("previous_inboxes").Deserialize<string[]>() ?? [];
        if (currentView == "settings") Render();
    }

    private async Task LoadBlipDownloadSettings()
    {
        try { ApplyBlipDownloadSettings(await DownloadSettings("get")); }
        catch (Exception error) { if (currentView == "settings") Error(error); }
    }

    private void AddBlipDownloadSetting(StackPanel settings)
    {
        settings.Children.Add(QuickText("Download folder", 12, true));
        var path = QuickButton("", () => _ = PickBlipDownloadFolder());
        path.Content = QuickText(blip.DownloadsDirectory, 11);
        path.HorizontalAlignment = HorizontalAlignment.Stretch;
        path.HorizontalContentAlignment = HorizontalAlignment.Left;
        ToolTipService.SetToolTip(path, "Change Blip download folder · " + blip.DownloadsDirectory);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(path, "Change Blip download folder");
        settings.Children.Add(path);
        if (blip.CustomDownloadsDirectory != null)
            settings.Children.Add(QuickButton("Use default", () => _ = SaveBlipDownloadFolder(null)));
    }

    private async Task PickBlipDownloadFolder()
    {
        if (busy || modalDepth > 0 || diagnosticMode) return;
        var picker = new FolderPicker { CommitButtonText = "Choose", SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, hwnd);
        var selected = await Modal(async () => await picker.PickSingleFolderAsync());
        if (selected != null) await SaveBlipDownloadFolder(selected.Path);
    }

    private async Task SaveBlipDownloadFolder(string? path)
    {
        if (diagnosticMode) return;
        try { ApplyBlipDownloadSettings(await DownloadSettings("set", path)); }
        catch (Exception error) { Error(error); }
    }
}
