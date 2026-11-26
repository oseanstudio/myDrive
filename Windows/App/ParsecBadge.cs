using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Windows.Graphics;
using ZXing.Common;

namespace MyDrive;

public sealed partial class MainWindow
{
    private readonly Dictionary<nint, ParsecBadgeWindow> parsecBadges = new();
    private long nextParsecBadgeProbe;
    private BitMatrix? parsecBadgeMatrix;
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
        var displays = ParsecBadgeWindow.WorkAreas();
        foreach (nint id in parsecBadges.Keys.Where(id => !displays.ContainsKey(id)).ToArray())
        {
            parsecBadges[id].Dispose();
            parsecBadges.Remove(id);
        }

        try
        {
            if (payload != shownParsecBadge || parsecBadgeMatrix == null)
            {
                parsecBadgeMatrix = ParsecBadgeWindow.MakeMatrix(payload);
                shownParsecBadge = payload;
            }
            foreach (var (id, area) in displays)
            {
                if (!parsecBadges.TryGetValue(id, out var window))
                {
                    window = new ParsecBadgeWindow();
                    parsecBadges[id] = window;
                }
                int side = Math.Clamp(area.Width / 12, 104, 144);
                window.Show(new RectInt32(area.X + area.Width - side - 12,
                    area.Y + area.Height - side - 12, side, side), parsecBadgeMatrix);
            }
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or ArgumentException)
        {
            HideParsecBadges();
        }
    }

    private void HideParsecBadges()
    {
        foreach (var window in parsecBadges.Values) window.Dispose();
        parsecBadges.Clear();
        parsecBadgeMatrix = null;
        shownParsecBadge = "";
    }
}

internal sealed class ParsecBadgeWindow : IDisposable
{
    private const string ClassName = "myDrive.ParsecBadge";
    private static readonly nint Module = GetModuleHandle(null);
    private static readonly WindowProcedure Handler = OnMessage;
    private static readonly Dictionary<nint, ParsecBadgeWindow> Windows = new();
    private static bool registered;
    private readonly nint handle;
    private BitMatrix? matrix;
    private RectInt32 bounds;

    public ParsecBadgeWindow()
    {
        if (!registered)
        {
            var windowClass = new WindowClass { Procedure = Handler, Instance = Module, Name = ClassName };
            if (RegisterClass(ref windowClass) == 0) throw new System.ComponentModel.Win32Exception();
            registered = true;
        }
        const uint toolWindow = 0x80, noActivate = 0x08000000, layered = 0x80000, transparent = 0x20;
        handle = CreateWindowEx(toolWindow | noActivate | layered | transparent, ClassName,
            "myDrive Parsec badge", 0x80000000, 0, 0, 1, 1, 0, 0, Module, 0);
        if (handle == 0) throw new System.ComponentModel.Win32Exception();
        if (!SetLayeredWindowAttributes(handle, 0, 255, 2))
        {
            var error = new System.ComponentModel.Win32Exception();
            DestroyWindow(handle);
            throw error;
        }
        Windows.Add(handle, this);
    }

    public static Dictionary<nint, RectInt32> WorkAreas()
    {
        var workAreas = new Dictionary<nint, RectInt32>();
        EnumerateMonitors(0, 0, (monitor, dc, rectangle, data) =>
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfo(monitor, ref info))
            {
                var work = info.Work;
                workAreas[monitor] = new RectInt32(work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top);
            }
            return true;
        }, 0);
        return workAreas;
    }

    public static BitMatrix MakeMatrix(string payload) =>
        new ZXing.QrCode.QRCodeWriter().encode(payload, ZXing.BarcodeFormat.QR_CODE, 0, 0,
            new Dictionary<ZXing.EncodeHintType, object> { [ZXing.EncodeHintType.ERROR_CORRECTION] = "M" });

    public void Show(RectInt32 position, BitMatrix code)
    {
        if (!ReferenceEquals(matrix, code)) { matrix = code; InvalidateRect(handle, 0, false); }
        if (bounds.Equals(position)) return;
        if (!SetWindowPos(handle, -1, position.X, position.Y, position.Width, position.Height, 0x10 | 0x40))
            throw new System.ComponentModel.Win32Exception();
        bounds = position;
    }

    public void Dispose()
    {
        if (Windows.Remove(handle)) DestroyWindow(handle);
    }

    private static nint OnMessage(nint hwnd, uint message, nint wParam, nint lParam)
    {
        if (message != 0x000f || !Windows.TryGetValue(hwnd, out var window))
            return DefWindowProc(hwnd, message, wParam, lParam);
        var paint = new Paint { Reserved = new byte[32] };
        nint dc = BeginPaint(hwnd, ref paint);
        try
        {
            if (dc == 0 || !GetClientRect(hwnd, out var area)) return 0;
            FillRect(dc, ref area, GetStockObject(0));
            if (window.matrix is not { } code) return 0;
            int step = Math.Min(area.Right / code.Width, area.Bottom / code.Height);
            if (step == 0) return 0;
            int left = (area.Right - code.Width * step) / 2;
            int top = (area.Bottom - code.Height * step) / 2;
            for (int y = 0; y < code.Height; y++)
            {
                for (int x = 0; x < code.Width;)
                {
                    if (!code[x, y]) { x++; continue; }
                    int start = x++;
                    while (x < code.Width && code[x, y]) x++;
                    PatBlt(dc, left + start * step, top + y * step, (x - start) * step, step, 0x00000042);
                }
            }
            return 0;
        }
        finally { EndPaint(hwnd, ref paint); }
    }

    private delegate nint WindowProcedure(nint hwnd, uint message, nint wParam, nint lParam);
    private delegate bool MonitorProcedure(nint monitor, nint dc, nint rect, nint data);
    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public Rect Monitor, Work;
        public uint Flags;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint Style;
        public WindowProcedure Procedure;
        public int ClassExtra, WindowExtra;
        public nint Instance, Icon, Cursor, Background;
        public string? Menu;
        public string Name;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Paint
    {
        public nint Dc;
        public int Erase;
        public Rect Clip;
        public int Restore, Update;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Reserved;
    }
    [DllImport("user32.dll", EntryPoint = "EnumDisplayMonitors")]
    private static extern bool EnumerateMonitors(nint dc, nint rect, MonitorProcedure callback, nint data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandle(string? module);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClass(ref WindowClass value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(uint exStyle, string cls, string name, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint DefWindowProc(nint hwnd, uint message, nint wParam, nint lParam);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(nint hwnd, nint behind, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetLayeredWindowAttributes(nint hwnd, uint color, byte alpha, uint flags);
    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(nint hwnd);
    [DllImport("user32.dll")]
    private static extern bool InvalidateRect(nint hwnd, nint rect, bool erase);
    [DllImport("user32.dll")]
    private static extern nint BeginPaint(nint hwnd, ref Paint paint);
    [DllImport("user32.dll")]
    private static extern bool EndPaint(nint hwnd, ref Paint paint);
    [DllImport("user32.dll")]
    private static extern bool GetClientRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")]
    private static extern int FillRect(nint dc, ref Rect rect, nint brush);
    [DllImport("gdi32.dll")]
    private static extern nint GetStockObject(int index);
    [DllImport("gdi32.dll")]
    private static extern bool PatBlt(nint dc, int x, int y, int width, int height, uint operation);
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
