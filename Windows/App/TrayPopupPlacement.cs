using System.Runtime.InteropServices;
using Windows.Graphics;

namespace MyDrive;

internal static class TrayPopupPlacement
{
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(PointInt32 point, uint flags);

    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);

    [StructLayout(LayoutKind.Sequential)]
    private struct Bounds { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public uint Size; public Bounds Monitor, Work; public uint Flags; }

    public static (RectInt32 Area, double Scale) MonitorAt(PointInt32 point, IntPtr window)
    {
        var monitor = MonitorFromPoint(point, 2);
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (GetMonitorInfoW(monitor, ref info))
        {
            var work = info.Work;
            var scale = GetDpiForMonitor(monitor, 0, out uint dpi, out _) == 0 ? dpi / 96d : TrayIcon.Scale(window);
            return (new RectInt32(work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top), scale);
        }
        var display = Microsoft.UI.Windowing.DisplayArea.GetFromPoint(point, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest);
        var area = display.WorkArea;
        return (new RectInt32(display.OuterBounds.X + area.X, display.OuterBounds.Y + area.Y, area.Width, area.Height),
            TrayIcon.Scale(window));
    }

    public static PointInt32 Center(RectInt32 icon) => new(icon.X + icon.Width / 2, icon.Y + icon.Height / 2);

    public static PointInt32 Beside(RectInt32 icon, RectInt32 area, SizeInt32 size, int gap)
    {
        var center = Center(icon);
        var right = area.X + area.Width;
        var bottom = area.Y + area.Height;
        // A tray icon outside the work area gives the taskbar edge directly.
        int[] distances = [bottom - center.Y, center.Y - area.Y, right - center.X, center.X - area.X];
        var edge = Array.IndexOf(distances, distances.Min());
        var position = edge switch
        {
            0 => new PointInt32(icon.X + icon.Width - size.Width, Math.Min(icon.Y, bottom) - size.Height - gap),
            1 => new PointInt32(icon.X + icon.Width - size.Width, Math.Max(icon.Y + icon.Height, area.Y) + gap),
            2 => new PointInt32(Math.Min(icon.X, right) - size.Width - gap, icon.Y + icon.Height - size.Height),
            _ => new PointInt32(Math.Max(icon.X + icon.Width, area.X) + gap, icon.Y + icon.Height - size.Height)
        };
        return Fit(position, area, size, gap);
    }

    public static PointInt32 Fit(PointInt32 position, RectInt32 area, SizeInt32 size, int gap) =>
        new(Math.Clamp(position.X, area.X + gap, area.X + Math.Max(gap, area.Width - size.Width - gap)),
            Math.Clamp(position.Y, area.Y + gap, area.Y + Math.Max(gap, area.Height - size.Height - gap)));
}
