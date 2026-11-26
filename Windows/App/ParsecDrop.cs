using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;

namespace MyDrive;

public sealed partial class MainWindow
{
    private sealed record ParsecRoute(ParsecSession Session, string Owner, BlipDevice? Peer);
    private sealed record ParsecConnection(int ProcessId, long Started, string Owner, BlipDevice Peer);
    private ParsecConnection? parsecConnection;
    private Window? parsecDropWindow;
    private TextBlock? parsecDropTitle, parsecDropComputer;
    private ParsecRoute? visibleParsecRoute;
    private nint parsecCandidate;
    private uint? parsecDragSource;
    private long parsecHoverStarted, parsecLastPressed;

    private async Task ConnectParsec(string owner, BlipDevice peer, bool edit = false)
    {
        if (diagnosticMode || busy || modalDepth > 0 || owner != BlipOwner || owner.Length == 0) return;
        string key = owner + "/" + peer.Peer;
        var computers = Preferences.Current.ParsecComputers;
        computers.TryGetValue(key, out var host);
        if (edit || host == null)
        {
            var input = new TextBox { Header = "Parsec Peer ID", MaxLength = 64, Text = host ?? "" };
            var form = new StackPanel { Spacing = 8 };
            form.Children.Add(Text("Copy the Peer ID from Parsec’s Computers tab. A connection opened from myDrive will send drops to " +
                BlipDeviceCaption(peer) + ".", 12));
            form.Children.Add(input);
            var dialog = new ContentDialog { Title = "Link a Parsec computer", Content = form, XamlRoot = root.XamlRoot,
                PrimaryButtonText = edit ? "Save" : "Save & Connect", CloseButtonText = "Cancel",
                SecondaryButtonText = edit && host != null ? "Unlink" : "" };
            var result = await ShowDialog(dialog);
            if (owner != BlipOwner || quitting) return;
            if (result == ContentDialogResult.Secondary)
            {
                computers.Remove(key);
                Preferences.Save();
                parsecConnection = null;
                HideParsecDrop();
                return;
            }
            if (result != ContentDialogResult.Primary) return;
            host = input.Text.Trim();
            if (!System.Text.RegularExpressions.Regex.IsMatch(host, @"\A[A-Za-z0-9_-]{1,64}\z"))
            {
                Info("Invalid Peer ID", "Enter the Peer ID shown in Parsec’s Computers tab.");
                return;
            }
            computers[key] = host;
            Preferences.Save();
            if (edit)
            {
                parsecConnection = null;
                HideParsecDrop();
                return;
            }
        }

        if (!System.Text.RegularExpressions.Regex.IsMatch(host, @"\A[A-Za-z0-9_-]{1,64}\z")) return;
        string executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Parsec", "parsecd.exe");
        if (!File.Exists(executable))
        {
            Info("Parsec unavailable", "Install Parsec to connect to a linked computer.");
            return;
        }
        try
        {
            parsecConnection = null;
            HideParsecDrop();
            var launch = new ProcessStartInfo(executable);
            launch.ArgumentList.Add("peer_id=" + host);
            using var process = Process.Start(launch);
            if (process == null || process.HasExited) return;
            parsecConnection = new(process.Id, process.StartTime.ToFileTimeUtc(), owner, peer);
            if (compact) DismissQuickPopup();
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Error(error);
        }
    }

    private ParsecRoute ResolveParsecRoute(ParsecSession session)
    {
        string owner = BlipOwner;
        var peer = parsecConnection is { } connection && session.ProcessId == connection.ProcessId &&
            session.Started == connection.Started && connection.Owner == owner &&
            !IsRecipientArchived(owner, connection.Peer.Peer) ? connection.Peer : null;
        return new(session, owner, peer);
    }

    private bool TrackParsecHover(PointInt32 point, PointInt32? origin)
    {
        long now = Environment.TickCount64;
        if (origin == null)
        {
            parsecCandidate = 0;
            parsecDragSource = null;
            if (now - parsecLastPressed > 300) HideParsecDrop();
            return false;
        }
        parsecLastPressed = now;
        if (busy || modalDepth > 0 || !BlipRunning || BlipOwner.Length == 0)
        {
            HideParsecDrop();
            return false;
        }
        parsecDragSource ??= ParsecSession.ProcessAt(origin.Value);
        if (Math.Abs((long)point.X - origin.Value.X) + Math.Abs((long)point.Y - origin.Value.Y) < 20) return false;
        if (visibleParsecRoute is { } visible && parsecDropWindow is { } panel)
        {
            var position = panel.AppWindow.Position;
            var size = panel.AppWindow.Size;
            if (point.X >= position.X && point.X < position.X + size.Width &&
                point.Y >= position.Y && point.Y < position.Y + size.Height && CanUse(visible, point))
                return true;
            HideParsecDrop();
        }
        if (ParsecSession.At(point) is not { } session || session.ProcessId == parsecDragSource)
        {
            parsecCandidate = 0;
            return false;
        }
        if (parsecCandidate != session.Window)
        {
            parsecCandidate = session.Window;
            parsecHoverStarted = now;
        }
        if (now - parsecHoverStarted >= 240) ShowParsecDrop(ResolveParsecRoute(session), point);
        return true;
    }

    private bool CanUse(ParsecRoute route, PointInt32 point) =>
        !busy && modalDepth == 0 && BlipRunning && route.Owner == BlipOwner &&
        route.Session.Contains(point) && ParsecSession.Read(route.Session.Window) is { } session &&
        session == route.Session && ResolveParsecRoute(session).Peer?.Peer == route.Peer?.Peer;

    private void ShowParsecDrop(ParsecRoute route, PointInt32 point)
    {
        if (parsecDropWindow == null)
        {
            var window = new Window { Title = "myDrive · Parsec" };
            parsecDropTitle = QuickText("", 13, true);
            parsecDropComputer = QuickText("", 11);
            var content = new StackPanel { Spacing = 4 };
            content.Children.Add(parsecDropTitle);
            content.Children.Add(parsecDropComputer);
            var surface = new Border { Padding = new(12), CornerRadius = new(6),
                Child = content, AllowDrop = true };
            void ApplyTheme()
            {
                surface.Background = new SolidColorBrush(surface.ActualTheme == ElementTheme.Dark
                    ? ColorHelper.FromArgb(255, 36, 36, 36) : Colors.White);
            }
            surface.ActualThemeChanged += (_, _) => ApplyTheme();
            ApplyTheme();
            surface.DragOver += (_, e) =>
            {
                e.Handled = true;
                e.AcceptedOperation = CanDropOnParsec(e.DataView) ? DataPackageOperation.Copy : DataPackageOperation.None;
                if (e.AcceptedOperation == DataPackageOperation.Copy) e.DragUIOverride.Caption = parsecDropTitle!.Text;
            };
            surface.Drop += async (_, e) =>
            {
                e.Handled = true;
                if (visibleParsecRoute is not { } choice || !CanDropOnParsec(e.DataView)) return;
                var deferral = e.GetDeferral();
                List<string> paths;
                try { paths = await DroppedPaths(e.DataView); }
                catch (Exception error) { HideParsecDrop(); OpenTransfers(); Error(error); return; }
                finally { deferral.Complete(); }
                HideParsecDrop();
                if (quitting || choice.Owner != BlipOwner || busy) return;
                OpenTransfers();
                if (choice.Peer is { } peer) await DispatchBlipSend(peer, paths, choice.Owner);
                else await SendDroppedFiles(paths);
            };
            window.Content = surface;
            if (window.AppWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.SetBorderAndTitleBar(false, false);
                presenter.IsResizable = presenter.IsMaximizable = presenter.IsMinimizable = false;
                presenter.IsAlwaysOnTop = true;
            }
            window.AppWindow.IsShownInSwitchers = false;
            parsecDropWindow = window;
            Closed += (_, _) => window.Close();
        }
        visibleParsecRoute = route;
        ((Border)parsecDropWindow.Content).RequestedTheme = RequestedAppearance;
        parsecDropTitle!.Text = route.Peer is { } peer ? "Send to " + BlipDeviceCaption(peer) : "Send with Blip";
        parsecDropComputer!.Text = route.Peer == null ? "Drop to choose a recipient" : "Parsec connection · Blip";
        var (area, scale) = TrayPopupPlacement.MonitorAt(point, hwnd);
        var sizeAtDpi = new SizeInt32((int)(244 * scale), (int)(72 * scale));
        var anchored = TrayPopupPlacement.Fit(new(point.X - sizeAtDpi.Width / 2, point.Y - sizeAtDpi.Height / 2),
            area, sizeAtDpi, 4);
        parsecDropWindow.AppWindow.MoveAndResize(new(anchored.X, anchored.Y, sizeAtDpi.Width, sizeAtDpi.Height));
        parsecDropWindow.AppWindow.Show(false);
    }

    private bool CanDropOnParsec(DataPackageView data) =>
        data.Contains(StandardDataFormats.StorageItems) && visibleParsecRoute is { } route &&
        GetCursorPos(out var cursor) && CanUse(route, new(cursor.X, cursor.Y));

    private void HideParsecDrop()
    {
        if (visibleParsecRoute == null) return;
        visibleParsecRoute = null;
        parsecDropWindow?.AppWindow.Hide();
    }
}

internal sealed record ParsecSession(nint Window, uint ProcessId, long Started, string Title)
{
    public static ParsecSession? At(PointInt32 point) => Read(WindowAt(point));

    public static uint ProcessAt(PointInt32 point)
    {
        GetWindowThreadProcessId(WindowAt(point), out uint id);
        return id;
    }

    private static nint WindowAt(PointInt32 point) => GetAncestor(WindowFromPoint(point), 2);

    public static ParsecSession? Read(nint window)
    {
        if (window == 0 || !IsWindowVisible(window) || GetWindowThreadProcessId(window, out uint id) == 0) return null;
        try
        {
            using var process = Process.GetProcessById((int)id);
            if (!process.ProcessName.Equals("parsecd", StringComparison.OrdinalIgnoreCase) &&
                !process.ProcessName.Equals("parsec", StringComparison.OrdinalIgnoreCase)) return null;
            var title = new StringBuilder(512);
            GetWindowTextW(window, title, title.Capacity);
            return new(window, id, process.StartTime.ToFileTimeUtc(), title.ToString());
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { return null; }
    }

    public bool Contains(PointInt32 point) => GetWindowRect(Window, out var rect) &&
        point.X >= rect.Left && point.X < rect.Right && point.Y >= rect.Top && point.Y < rect.Bottom;

    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(PointInt32 point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetWindowTextW(nint window, StringBuilder title, int maxLength);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out NativeRect rect);
}
