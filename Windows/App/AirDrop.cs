using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MyDrive;

public sealed partial class MainWindow
{
    private const string AirDropCompanionUrl = "https://github.com/JungyoKim/WirDrop#what-you-need";

    private string? AirDropCompanion()
    {
        if (diagnosticMode || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) return null;
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (programFiles.Length == 0) return null;
        var executable = Path.Combine(programFiles, "WirDrop", "WirDrop.exe");
        return File.Exists(executable) ? executable : null;
    }

    private async Task ShowNearbyAirDrop()
    {
        if (busy || modalDepth > 0) return;
        if (AirDropCompanion() == null)
        {
            var guide = new HyperlinkButton { Content = "Supported adapters and WirDrop setup",
                NavigateUri = new Uri(AirDropCompanionUrl) };
            var setup = new StackPanel { MaxWidth = 270, Spacing = 7 };
            setup.Children.Add(QuickText("Nearby AirDrop uses the experimental WirDrop companion on Windows 11.", 12));
            setup.Children.Add(guide);
            await ShowDialog(new ContentDialog { Title = "AirDrop", XamlRoot = root.XamlRoot,
                Content = setup, CloseButtonText = "Close" });
            return;
        }
        var choices = new StackPanel { Spacing = 6 };
        var dialog = new ContentDialog { Title = "AirDrop", XamlRoot = root.XamlRoot,
            Content = choices, CloseButtonText = "Cancel" };
        Func<Task>? selected = null;
        void Choose(string title, Func<Task> work)
        {
            choices.Children.Add(QuickButton(title, () => { selected = work; dialog.Hide(); }));
        }
        Choose("Send files…", () => PickAirDropItems(false));
        Choose("Send a folder…", () => PickAirDropItems(true));
        Choose("Open WirDrop to receive", () => { StartAirDropCompanion([]); return Task.CompletedTask; });
        await ShowDialog(dialog);
        if (selected != null) await selected();
    }

    private async Task PickAirDropItems(bool folder)
    {
        if (folder)
        {
            var picker = new FolderPicker { CommitButtonText = "Choose" };
            InitializeWithWindow.Initialize(picker, hwnd);
            picker.FileTypeFilter.Add("*");
            var item = await Modal(async () => await picker.PickSingleFolderAsync(), dismissMenu: true);
            if (item != null) StartAirDropCompanion([item.Path]);
        }
        else
        {
            var picker = new FileOpenPicker { CommitButtonText = "Choose" };
            InitializeWithWindow.Initialize(picker, hwnd);
            picker.FileTypeFilter.Add("*");
            var items = await Modal(async () => await picker.PickMultipleFilesAsync(), dismissMenu: true);
            if (items.Count > 0) StartAirDropCompanion(items.Select(item => item.Path).ToList());
        }
    }

    private void StartAirDropCompanion(IReadOnlyList<string> paths)
    {
        var executable = AirDropCompanion();
        if (executable == null) { _ = ShowNearbyAirDrop(); return; }
        if (paths.Count > 256 || paths.Any(path => !Path.IsPathFullyQualified(path) ||
            !(File.Exists(path) || Directory.Exists(path))))
        {
            Info("AirDrop", "Choose up to 256 available files or folders.");
            return;
        }
        try
        {
            var launch = new ProcessStartInfo(executable) { UseShellExecute = false };
            if (paths.Count > 0)
            {
                launch.ArgumentList.Add("--pick");
                foreach (var path in paths) launch.ArgumentList.Add(path);
            }
            using var companion = Process.Start(launch);
            DismissQuickPopup();
        }
        catch (System.ComponentModel.Win32Exception error) { Error(error); }
    }
}
