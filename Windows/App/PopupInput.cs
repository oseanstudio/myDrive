using System.Runtime.InteropServices;
using Windows.Graphics;
namespace MyDrive;

// Installed only while our small popup is visible. Observes mouse-down location;
// never consumes input, moves the pointer or records keys, clicks or window data.
internal sealed class PopupInput : IDisposable
{
    private readonly Action<PointInt32> pointerDown;
    private readonly HookProc callback;
    private IntPtr hook;
    private delegate IntPtr HookProc(int code,IntPtr message,IntPtr data);
    [DllImport("user32.dll",SetLastError=true)]private static extern IntPtr SetWindowsHookExW(int id,HookProc callback,IntPtr module,uint thread);
    [DllImport("user32.dll")]private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]private static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]private static extern IntPtr GetModuleHandleW(string? name);
    [StructLayout(LayoutKind.Sequential)]private struct Point{public int X,Y;}
    [DllImport("user32.dll")]private static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll")]private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]private static extern bool SetForegroundWindow(IntPtr window);
    public PopupInput(Action<PointInt32> pointerDown){this.pointerDown=pointerDown;callback=Observe;}
    public bool IsWatching=>hook!=IntPtr.Zero;
    public void Start(){if(hook==IntPtr.Zero)hook=SetWindowsHookExW(14,callback,GetModuleHandleW(null),0);}
    public void Stop(){if(hook!=IntPtr.Zero){UnhookWindowsHookEx(hook);hook=IntPtr.Zero;}}
    public static void Foreground(IntPtr window)=>SetForegroundWindow(window);
    private static bool OurWindow(IntPtr window)=>window!=IntPtr.Zero&&GetWindowThreadProcessId(window,out var pid)!=0&&pid==(uint)Environment.ProcessId;
    public static bool OurWindowAt(PointInt32 point)=>OurWindow(WindowFromPoint(new Point{X=point.X,Y=point.Y}));
    public static bool OurForeground()=>OurWindow(GetForegroundWindow());
    private IntPtr Observe(int code,IntPtr message,IntPtr data)
    {
        if(code>=0&&message.ToInt64() is 0x201 or 0x204 or 0x207 or 0x20B)
        {
            var point=new PointInt32(Marshal.ReadInt32(data),Marshal.ReadInt32(data,4));
            try{pointerDown(point);}catch{} // Never let a managed exception cross the OS callback.
        }
        return CallNextHookEx(hook,code,message,data);
    }
    public void Dispose()=>Stop();
}
