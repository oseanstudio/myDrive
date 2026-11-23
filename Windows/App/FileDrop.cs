using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace MyDrive;

public sealed partial class MainWindow
{
    private void EnableFileDrop()
    {
        if (tray != null && !diagnosticMode) EnableTrayDragHover();
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
                var items = await e.DataView.GetStorageItemsAsync();
                paths = items.Select(item => item.Path).Where(path => !string.IsNullOrWhiteSpace(path))
                    .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            }
            catch (Exception error) { Error(error); return; }
            finally { deferral.Complete(); }
            if (paths.Count > 0) await HandleFileDrop(paths);
        };
    }

    // Explorer owns the notification icon. Reveal our own drop target without
    // activating the popup while a held pointer travels onto that icon.
    private void EnableTrayDragHover()
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(125) };
        PointerPosition? start = null;
        int hover = 0;
        timer.Tick += (_, _) =>
        {
            if ((GetAsyncKeyState(1) & 0x8000) == 0 || !GetCursorPos(out var pointer))
            {
                start = null;
                hover = 0;
                return;
            }
            start ??= pointer;
            if (AppWindow.IsVisible || busy || modalDepth > 0 ||
                Math.Abs(pointer.X - start.Value.X) + Math.Abs(pointer.Y - start.Value.Y) < 20 ||
                tray?.Contains(new(pointer.X, pointer.Y)) != true)
            {
                hover = 0;
                return;
            }
            if (++hover == 2) SetMode(true, activate: false);
        };
        Closed += (_, _) => timer.Stop();
        timer.Start();
    }

    private async Task HandleFileDrop(List<string> paths)
    {
        if (busy || modalDepth > 0) return;
        PopupInput.Foreground(hwnd);
        if (paths.Count != 1 || !Directory.Exists(paths[0]))
        {
            await SendDroppedFiles(paths);
            return;
        }

        string folder = paths[0];
        var choices = new StackPanel { Spacing = 6 };
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = new DirectoryInfo(folder).Name,
            Content = choices, CloseButtonText = "Cancel" };
        Func<Task>? selected = null;
        void Choose(string title, Func<Task> action)
        {
            choices.Children.Add(QuickButton(title, () => { selected = action; dialog.Hide(); }));
        }
        Choose("Send with Blip", () => SendDroppedFiles(paths));
        Choose("Sync folder", () => ShowQuickShare(folder));
        Choose("Share over SMB", () => CreatePrivateShare(folder));
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

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out PointerPosition position);
}
