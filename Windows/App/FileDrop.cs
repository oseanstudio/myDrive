using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace MyDrive;

public sealed partial class MainWindow
{
    private void EnableFileDrop()
    {
        if (!diagnosticMode) EnableTrayDragHover();
        root.AllowDrop = true;
        root.DragOver += (_, e) =>
        {
            if (modalDepth > 0 || busy || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Open in myDrive";
            e.Handled = true;
        };
        root.Drop += async (_, e) =>
        {
            if (modalDepth > 0 || busy || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            e.Handled = true;
            var deferral = e.GetDeferral();
            List<string> paths;
            try
            {
                paths = await DroppedPaths(e.DataView);
            }
            catch (Exception error) { Error(error); return; }
            finally { deferral.Complete(); }
            if (paths.Count > 0)
            {
                if (currentView == "sync")
                {
                    try { await ShowSyncDrop(paths); }
                    catch (Exception error) { Error(error); }
                }
                else await HandleFileDrop(paths);
            }
        };
    }

    private static async Task<List<string>> DroppedPaths(DataPackageView data)
    {
        var items = await data.GetStorageItemsAsync();
        if (items.Count is 0 or > 256 || items.Any(item => string.IsNullOrEmpty(item.Path) || !Path.IsPathFullyQualified(item.Path)))
            throw new IOException("Drop up to 256 available files or folders.");
        return items.Select(item => item.Path).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private void EnableRecipientDrop(Grid row, string owner, BlipDevice recipient, string label)
    {
        bool available() => !busy && modalDepth == 0 && BlipRunning &&
            owner.Equals(BlipOwner, StringComparison.OrdinalIgnoreCase);
        row.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        row.AllowDrop = true;
        row.DragOver += (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            e.Handled = true;
            e.AcceptedOperation = available() ? DataPackageOperation.Copy : DataPackageOperation.None;
            if (available()) e.DragUIOverride.Caption = "Send to " + label;
        };
        row.Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            e.Handled = true;
            if (!available() || diagnosticMode) return;
            var deferral = e.GetDeferral();
            List<string> paths;
            try { paths = await DroppedPaths(e.DataView); }
            catch (Exception error) { Error(error); return; }
            finally { deferral.Complete(); }
            if (available()) await DispatchBlipSend(recipient, paths, owner);
        };
    }

    // Explorer owns the notification icon. Reveal our own drop target without
    // activating the popup while a held pointer travels onto that icon.
    private void EnableTrayDragHover()
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(125) };
        PointerPosition? start = null;
        PointerPosition? lastIdlePosition = null;
        int hover = 0;
        timer.Tick += (_, _) =>
        {
            if (!GetCursorPos(out var pointer)) return;
            if (!LeftMousePressed())
            {
                TrackParsecHover(new(pointer.X, pointer.Y), null);
                lastIdlePosition = pointer;
                start = null;
                hover = 0;
                return;
            }
            start ??= lastIdlePosition ?? pointer;
            if (TrackParsecHover(new(pointer.X, pointer.Y), new(start.Value.X, start.Value.Y))) return;
            if (AppWindow.IsVisible || busy || modalDepth > 0 ||
                Math.Abs(pointer.X - start.Value.X) + Math.Abs(pointer.Y - start.Value.Y) < 20 ||
                tray?.Contains(new(pointer.X, pointer.Y)) != true)
            {
                hover = 0;
                return;
            }
            if (++hover == 2)
            {
                NavigateQuick("transfers");
                SetMode(true, activate: false);
            }
        };
        Closed += (_, _) => timer.Stop();
        timer.Start();
    }

    private async Task HandleFileDrop(List<string> paths)
    {
        if (busy || modalDepth > 0) return;
        PopupInput.Foreground(hwnd);
        bool folderDrop = paths.Count == 1 && Directory.Exists(paths[0]);
        bool hasAirDrop = AirDropCompanion() != null;
        if (!folderDrop && !hasAirDrop)
        {
            await SendDroppedFiles(paths);
            return;
        }

        string folder = paths[0];
        var choices = new StackPanel { Spacing = 6 };
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = paths.Count == 1
            ? Path.GetFileName(Path.TrimEndingDirectorySeparator(folder)) : $"{paths.Count} files and folders",
            Content = choices, CloseButtonText = "Cancel" };
        Func<Task>? selected = null;
        void Choose(string title, Func<Task> action)
        {
            choices.Children.Add(QuickButton(title, () => { selected = action; dialog.Hide(); }));
        }
        Choose("Send with Blip", () => SendDroppedFiles(paths));
        if (hasAirDrop) Choose("Send via AirDrop", () => { StartAirDropCompanion(paths); return Task.CompletedTask; });
        if (folderDrop)
        {
            Choose("Sync folder", () => ShowQuickShare(folder));
            Choose("Share over SMB", () => CreatePrivateShare(folder));
        }
        await ShowDialog(dialog);
        if (selected != null) await selected();
    }

    public async Task SendFromFileManager(string[] selection)
    {
        if (selection.Length is 0 or > 256) return;
        var paths = await Task.Run(() => selection
            .Where(path => !string.IsNullOrEmpty(path) && Path.IsPathFullyQualified(path) &&
                           (File.Exists(path) || Directory.Exists(path)))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList());
        OpenQuickMenu();
        if (paths.Count == 0) { Info("Send with myDrive", "Choose an available file or folder."); return; }
        if (busy || modalDepth > 0) { Info("Send with myDrive", "Finish the current action, then try again."); return; }
        for (int attempt = 0; attempt < 40 && blipSnapshot?.Status.Authenticated != true &&
             Volatile.Read(ref blipRefreshing) != 0; attempt++)
            await Task.Delay(100);
        if (quitting || busy || modalDepth > 0) return;
        await SendDroppedFiles(paths);
    }

    private async Task SendDroppedFiles(List<string> paths)
    {
        currentView = "transfers";
        Render();
        if (blipSnapshot?.Status.Authenticated != true) await RefreshBlip();
        if (blipSnapshot?.Status.Authenticated != true)
        {
            Info("Connect Blip first", "Sign in to your Blip account to send the dropped items.");
            return;
        }
        string description = paths.Count == 1 ? Path.GetFileName(paths[0]) : $"{paths.Count} items";
        await ShowBlipSend(paths, description);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PointerPosition
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    private static bool LeftMousePressed() => (GetAsyncKeyState(1) & 0x8000) != 0;

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out PointerPosition position);
}
