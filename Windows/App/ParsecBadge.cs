using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics;
using WinRT.Interop;

namespace MyDrive;

public sealed partial class MainWindow
{
    private readonly Dictionary<ulong, Window> parsecBadges = new();
    private long nextParsecBadgeProbe;
    private volatile string shownParsecBadge = "";

    private void RefreshParsecBadge()
    {
        long now = Environment.TickCount64;
        if (quitting || now < Interlocked.Read(ref nextParsecBadgeProbe)) return;
        Interlocked.Exchange(ref nextParsecBadgeProbe, now + 5000);
        string owner = BlipOwner;
        bool hosting = !string.IsNullOrEmpty(owner) && Preferences.Current.ParsecShowBadge && ParsecHostLog.IsHosting();
        if (!hosting && shownParsecBadge.Length == 0) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (quitting) return;
            if (!hosting || !Preferences.Current.ParsecShowBadge || owner != BlipOwner)
            {
                HideParsecBadges();
                return;
            }

            var payload = ParsecHostLog.Badge(owner, DateTimeOffset.UtcNow);
            if (payload == null) { HideParsecBadges(); return; }
            ShowParsecBadges(payload);
        });
    }

    private void ShowParsecBadges(string payload)
    {
        var displays = DisplayArea.FindAll();
        var ids = displays.Select(display => display.DisplayId.Value).ToHashSet();
        foreach (ulong id in parsecBadges.Keys.Where(id => !ids.Contains(id)).ToArray())
        {
            parsecBadges[id].Close();
            parsecBadges.Remove(id);
        }
        bool changed = payload != shownParsecBadge;
        shownParsecBadge = payload;
        foreach (var display in displays)
        {
            ulong id = display.DisplayId.Value;
            if (!parsecBadges.TryGetValue(id, out var window))
            {
                window = new Window { Title = "myDrive Parsec badge" };
                if (window.AppWindow.Presenter is OverlappedPresenter presenter)
                {
                    presenter.SetBorderAndTitleBar(false, false);
                    presenter.IsResizable = false;
                    presenter.IsAlwaysOnTop = true;
                }
                window.AppWindow.IsShownInSwitchers = false;
                nint handle = WindowNative.GetWindowHandle(window);
                SetBadgeStyle(handle, -20, GetBadgeStyle(handle, -20) | 0x08000020);
                parsecBadges[id] = window;
            }
            if (changed || window.Content == null) window.Content = BadgeView(payload);
            var area = display.WorkArea;
            int side = Math.Clamp(area.Width / 12, 104, 144);
            var bounds = new RectInt32(area.X + area.Width - side - 12, area.Y + area.Height - side - 12, side, side);
            if (window.AppWindow.Position.X != bounds.X || window.AppWindow.Position.Y != bounds.Y ||
                window.AppWindow.Size.Width != side || window.AppWindow.Size.Height != side)
                window.AppWindow.MoveAndResize(bounds);
            if (!window.AppWindow.IsVisible) window.AppWindow.Show(false);
        }
    }

    private static Grid BadgeView(string payload)
    {
        var matrix = new ZXing.QrCode.QRCodeWriter().encode(payload, ZXing.BarcodeFormat.QR_CODE, 0, 0,
            new Dictionary<ZXing.EncodeHintType, object> { [ZXing.EncodeHintType.ERROR_CORRECTION] = "M" });
        var geometry = new GeometryGroup();
        for (int y = 0; y < matrix.Height; y++)
        {
            for (int x = 0; x < matrix.Width;)
            {
                if (!matrix[x, y]) { x++; continue; }
                int start = x++;
                while (x < matrix.Width && matrix[x, y]) x++;
                geometry.Children.Add(new RectangleGeometry { Rect = new Rect(start, y, x - start, 1) });
            }
        }
        // The border keeps the quiet zone outside the black path.
        var grid = new Grid { Background = new SolidColorBrush(Colors.White), Padding = new Thickness(13) };
        grid.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = geometry,
            Fill = new SolidColorBrush(Colors.Black),
            Stretch = Stretch.Uniform,
            IsHitTestVisible = false,
        });
        return grid;
    }

    private void HideParsecBadges()
    {
        foreach (var window in parsecBadges.Values) window.Close();
        parsecBadges.Clear();
        shownParsecBadge = "";
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern nint GetBadgeStyle(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern nint SetBadgeStyle(nint window, int index, nint value);
}

internal static class ParsecHostLog
{
    private static readonly Regex Guest = new(
        @"^\[I (?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (?<guest>[^ ]{1,160}#\d+) (?<verb>connected|disconnected)\.$",
        RegexOptions.CultureInvariant);
    private static readonly string[] Roots = [
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Parsec"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Parsec"),
    ];

    public static string? Badge(string owner, DateTimeOffset now)
    {
        var parts = owner.Split(':');
        if (parts.Length != 2 || !Guid.TryParseExact(parts[0], "D", out var account) ||
            !Guid.TryParseExact(parts[1], "D", out var device)) return null;
        return $"mydrive-parsec-v1:{account:N}:{device:N}:{now.ToUnixTimeSeconds() / 30}";
    }

    public static bool IsHosting()
    {
        if (!Roots.Any(Directory.Exists)) return false;
        var processes = Process.GetProcessesByName("parsecd");
        DateTime? started = null;
        using var own = Process.GetCurrentProcess();
        try
        {
            foreach (var process in processes)
            {
                try
                {
                    if (process.SessionId != own.SessionId) continue;
                    if (started == null || process.StartTime < started) started = process.StartTime;
                }
                catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
        }
        finally { foreach (var process in processes) process.Dispose(); }
        return started is { } time && Roots.Any(root => HasGuest(root, time.AddSeconds(-3)));
    }

    internal static bool HasGuest(string root, DateTime started)
    {
        var guests = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string name in new[] { "log.1.txt", "log.txt" })
        {
            try
            {
                using var file = new FileStream(Path.Combine(root, name), FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                if (file.Length > 384 * 1024) file.Seek(-384 * 1024, SeekOrigin.End);
                using var reader = new StreamReader(file);
                if (file.Position > 0) reader.ReadLine();
                while (reader.ReadLine() is { } line)
                {
                    if (line.EndsWith("===== Parsec: Started =====", StringComparison.Ordinal))
                    {
                        guests.Clear();
                        continue;
                    }
                    var match = Guest.Match(line);
                    if (!match.Success || !DateTime.TryParseExact(match.Groups["time"].Value,
                        "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal,
                        out var stamp) || stamp < started) continue;
                    var guest = match.Groups["guest"].Value;
                    if (match.Groups["verb"].Value == "connected") guests.Add(guest);
                    else guests.Remove(guest);
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return guests.Count != 0;
    }
}
