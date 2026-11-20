using System.Runtime.InteropServices;
using System.ComponentModel;
namespace MyDrive;
public static class Native
{
    public static async Task ConnectSmb(Bookmark b,CancellationToken token=default)
    {
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(15));
        try{await CoreBridge.Call(new{action="smb.connect",bookmark=b,credentials=CredentialStore.Read(b.id)},timeout.Token);}
        catch(OperationCanceledException)when(!token.IsCancellationRequested){throw new IOException("The SMB server did not respond within 15 seconds. The connection will be checked again automatically.");}
    }
}

public enum TrayStatus { Normal, Attention, Problem }

/// Generates a tray icon variant with a colored status badge stamped over the
/// monochrome cloud, so the tray itself signals problems (matching the macOS
/// menu bar tint). Badge pixels are written straight into a 32-bpp DIB because
/// GDI fills would write a zero alpha channel and vanish.
internal static class TrayStatusIcon
{
    [StructLayout(LayoutKind.Sequential)] private struct BITMAPINFOHEADER { public uint Size; public int Width,Height; public ushort Planes,BitCount; public uint Compression,SizeImage; public int XPelsPerMeter,YPelsPerMeter; public uint ClrUsed,ClrImportant; }
    [StructLayout(LayoutKind.Sequential)] private struct BITMAPINFO { public BITMAPINFOHEADER Header; public uint Colors; }
    [StructLayout(LayoutKind.Sequential)] private struct ICONINFO { public int Icon; public uint XHotspot,YHotspot; public IntPtr MaskBitmap,ColorBitmap; }
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window,IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr dc,ref BITMAPINFO info,uint usage,out IntPtr bits,IntPtr section,uint offset);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc,IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateBitmap(int width,int height,uint planes,uint bitsPerPixel,byte[]? data);
    [DllImport("user32.dll")] private static extern bool DrawIconEx(IntPtr dc,int x,int y,IntPtr icon,int width,int height,uint step,IntPtr brush,uint flags);
    [DllImport("user32.dll")] private static extern IntPtr CreateIconIndirect(ref ICONINFO info);

    public static IntPtr Compose(IntPtr baseIcon,uint badgeColor,int size=32)
    {
        const int diNormal=3;
        var info=new BITMAPINFO();
        info.Header=new BITMAPINFOHEADER{Size=(uint)Marshal.SizeOf<BITMAPINFOHEADER>(),Width=size,Height=-size,Planes=1,BitCount=32};
        IntPtr bitmap,bits;
        var screen=GetDC(IntPtr.Zero);
        try
        {
            var dc=CreateCompatibleDC(screen);
            try
            {
                bitmap=CreateDIBSection(screen,ref info,0,out bits,IntPtr.Zero,0);
                if(bitmap==IntPtr.Zero||bits==IntPtr.Zero)return IntPtr.Zero;
                Marshal.Copy(new byte[size*size*4],0,bits,size*size*4);
                var previous=SelectObject(dc,bitmap);
                DrawIconEx(dc,0,0,baseIcon,size,size,0,IntPtr.Zero,diNormal);
                SelectObject(dc,previous);
                StampBadge(bits,size,badgeColor);
            }
            finally{DeleteDC(dc);}
        }
        finally{ReleaseDC(IntPtr.Zero,screen);}
        // With a 32-bpp alpha color bitmap the AND mask stays opaque (all
        // zeros) so the color bitmap's alpha channel drives transparency.
        var mask=CreateBitmap(size,size,1,1,new byte[((size+15)/16)*2*size]);
        if(mask==IntPtr.Zero){DeleteObject(bitmap);return IntPtr.Zero;}
        var iconInfo=new ICONINFO{Icon=1,XHotspot=0,YHotspot=0,MaskBitmap=mask,ColorBitmap=bitmap};
        var composed=CreateIconIndirect(ref iconInfo);
        DeleteObject(bitmap);DeleteObject(mask);
        return composed;
    }

    private static void StampBadge(IntPtr bits,int size,uint color)
    {
        // A compact solid dot with a transparent separator. A pale halo made
        // the 16px cloud look fuzzy on dark taskbars. Sample coverage rather
        // than using a hard circle edge; DIB colors remain premultiplied.
        double scale=size/16d,cx=Math.Round(13*scale),cy=Math.Round(12*scale),radius=2*scale,gap=.75*scale;
        for(int y=0;y<size;y++)for(int x=0;x<size;x++)
        {
            double dot=0,clear=0;
            const int samples=8;
            for(int sy=0;sy<samples;sy++)for(int sx=0;sx<samples;sx++)
            {
                double dx=x+(sx+.5)/samples-cx,dy=y+(sy+.5)/samples-cy;
                double distance=dx*dx+dy*dy;
                if(distance<=radius*radius)dot++;
                if(distance<=(radius+gap)*(radius+gap))clear++;
            }
            if(clear==0)continue;
            double alpha=dot/(samples*samples),remain=1-clear/(samples*samples);
            uint dst=(uint)Marshal.ReadInt32(bits,(y*size+x)*4);
            int db=(int)(dst&0xFF),dg=(int)((dst>>8)&0xFF),dr=(int)((dst>>16)&0xFF),da=(int)((dst>>24)&0xFF);
            int sb=(int)(color&0xFF),sg=(int)((color>>8)&0xFF),sr=(int)((color>>16)&0xFF);
            int b=(int)Math.Round(sb*alpha+db*remain),g=(int)Math.Round(sg*alpha+dg*remain),r=(int)Math.Round(sr*alpha+dr*remain),a=(int)Math.Round(255*alpha+da*remain);
            uint packed=(uint)(a<<24)|(uint)(r<<16)|(uint)(g<<8)|(uint)b;
            Marshal.WriteInt32(bits,(y*size+x)*4,unchecked((int)packed));
        }
    }
}

public sealed class TrayIcon : IDisposable
{
    private const uint Message=0x8001,PowerBroadcast=0x218,Modify=1;
    private readonly IntPtr hwnd;
    private IntPtr icon;
    private string iconAsset="";
    private int iconPixels;
    private readonly uint taskbarCreated=RegisterWindowMessage("TaskbarCreated");
    private readonly SubclassProc handler;
    private readonly Action show,quit;
    private readonly Action showFull;
    private readonly Action? resume;
    private IntPtr activeIcon,statusIcon;
    internal string AssetName=>iconAsset;
    internal int PixelSize=>iconPixels;
    internal bool HasBadge=>statusIcon!=IntPtr.Zero;
    private TrayStatus status=TrayStatus.Normal;
    private string tip="myDrive · Your storage, connected";
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct NotifyData {public uint Size;public IntPtr Hwnd;public uint Id,Flags,Callback;public IntPtr Icon;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)]public string Tip;public uint State,StateMask;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string Info;public uint Timeout;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)]public string Title;public uint InfoFlags;public Guid Guid;public IntPtr Balloon;}
    private delegate IntPtr SubclassProc(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp,UIntPtr id,IntPtr data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr hwnd,SubclassProc proc,UIntPtr id,IntPtr data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr hwnd,SubclassProc proc,UIntPtr id);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
    [DllImport("shell32.dll",EntryPoint="Shell_NotifyIconW",CharSet=CharSet.Unicode)]private static extern bool Notify(uint message,ref NotifyData data);
    [DllImport("user32.dll",EntryPoint="LoadImageW",CharSet=CharSet.Unicode)]private static extern IntPtr LoadImage(IntPtr instance,string name,uint type,int cx,int cy,uint flags);
    [DllImport("user32.dll")]private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")]private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll",EntryPoint="AppendMenuW",CharSet=CharSet.Unicode)]private static extern bool AppendMenu(IntPtr menu,uint flags,UIntPtr id,string label);
    [DllImport("user32.dll")]private static extern uint TrackPopupMenu(IntPtr menu,uint flags,int x,int y,int reserved,IntPtr hwnd,IntPtr rect);
    [DllImport("user32.dll")]private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")]private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")]private static extern bool SetForegroundWindow(IntPtr hwnd);
    [StructLayout(LayoutKind.Sequential)]private struct Point{public int X,Y;}
    [StructLayout(LayoutKind.Sequential)]private struct Rect{public int Left,Top,Right,Bottom;}
    [StructLayout(LayoutKind.Sequential)]private struct IconIdentifier{public uint Size;public IntPtr Hwnd;public uint Id;public Guid Guid;}
    [DllImport("shell32.dll")]private static extern int Shell_NotifyIconGetRect(ref IconIdentifier identifier,out Rect rect);
    [DllImport("user32.dll")]private static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]private static extern int GetSystemMetricsForDpi(int index,uint dpi);
    [DllImport("user32.dll",EntryPoint="RegisterWindowMessageW",CharSet=CharSet.Unicode)]private static extern uint RegisterWindowMessage(string text);
    [StructLayout(LayoutKind.Sequential)]private struct HighContrast{public uint Size,Flags;public IntPtr Scheme;}
    [DllImport("user32.dll",EntryPoint="SystemParametersInfoW")]private static extern bool SystemParametersInfo(uint action,uint size,ref HighContrast value,uint flags);
    [DllImport("user32.dll")]private static extern uint GetSysColor(int index);
    private static string CurrentAsset()
    {
        var contrast=new HighContrast{Size=(uint)Marshal.SizeOf<HighContrast>()};
        if(SystemParametersInfo(0x42,contrast.Size,ref contrast,0)&&(contrast.Flags&1)!=0)
        {
            var color=GetSysColor(8);return ((color&255)+((color>>8)&255)+((color>>16)&255))>382?"tray-white.ico":"tray-dark.ico";
        }
        try{return Convert.ToInt32(Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize","SystemUsesLightTheme",0))==1?"tray-dark.ico":"tray-white.ico";}catch{return "tray-white.ico";}
    }
    private IntPtr LoadTrayIcon(string asset,int size)
    {
        var loaded=LoadImage(IntPtr.Zero,Path.Combine(AppContext.BaseDirectory,"Assets",asset),1,size,size,0x10);
        return loaded!=IntPtr.Zero?loaded:LoadImage(IntPtr.Zero,Path.Combine(AppContext.BaseDirectory,"Assets","myDrive.ico"),1,size,size,0x10);
    }
    public static double Scale(IntPtr hwnd)=>Math.Max(1,GetDpiForWindow(hwnd)/96d);
    public Windows.Graphics.PointInt32 Anchor(){var id=new IconIdentifier{Size=(uint)Marshal.SizeOf<IconIdentifier>(),Hwnd=hwnd,Id=1};if(Shell_NotifyIconGetRect(ref id,out var r)==0)return new(r.Right,r.Top);GetCursorPos(out var p);return new(p.X,p.Y);}
    public bool Contains(Windows.Graphics.PointInt32 point){var id=new IconIdentifier{Size=(uint)Marshal.SizeOf<IconIdentifier>(),Hwnd=hwnd,Id=1};return Shell_NotifyIconGetRect(ref id,out var r)==0&&point.X>=r.Left&&point.X<r.Right&&point.Y>=r.Top&&point.Y<r.Bottom;}
    public bool PointerInside()=>GetCursorPos(out var point)&&Contains(new(point.X,point.Y));
    private NotifyData Data()=>new(){Size=(uint)Marshal.SizeOf<NotifyData>(),Hwnd=hwnd,Id=1,Flags=7,Callback=Message,Icon=activeIcon,Tip=tip,Info="",Title=""};
    public TrayIcon(IntPtr window,Action show,Action quit,Action showFull,Action? resume=null)
    {
        hwnd=window;this.show=show;this.quit=quit;this.showFull=showFull;this.resume=resume;handler=WndProc;
        iconAsset=CurrentAsset();iconPixels=Math.Max(16,GetSystemMetricsForDpi(49,GetDpiForWindow(hwnd)));
        icon=LoadTrayIcon(iconAsset,iconPixels);
        activeIcon=icon;
        if(!SetWindowSubclass(hwnd,handler,(UIntPtr)1,IntPtr.Zero)){if(icon!=IntPtr.Zero)DestroyIcon(icon);throw new IOException("Could not initialize the system tray.");}
        var data=Data();if(!Notify(0,ref data)){RemoveWindowSubclass(hwnd,handler,(UIntPtr)1);if(icon!=IntPtr.Zero)DestroyIcon(icon);throw new IOException("The system tray is unavailable.");}
    }
    private IntPtr WndProc(IntPtr h,uint message,IntPtr wp,IntPtr lp,UIntPtr id,IntPtr data)
    {
        if(message==0x1A||message==0x31A||message==0x2E0)SetStatus(status);
        if(taskbarCreated!=0&&message==taskbarCreated){var restored=Data();Notify(0,ref restored);}
        if(message==Message)
        {
            var mouse=lp.ToInt32()&0xffff;
            if(mouse==0x203||mouse==0x202)show();
            if(mouse==0x205){var menu=CreatePopupMenu();AppendMenu(menu,0,(UIntPtr)1,"Quick menu");AppendMenu(menu,0,(UIntPtr)3,"Open full window");AppendMenu(menu,0x800,UIntPtr.Zero,"");AppendMenu(menu,0,(UIntPtr)2,"Quit myDrive");GetCursorPos(out var point);SetForegroundWindow(hwnd);var selected=TrackPopupMenu(menu,0x100|2,point.X,point.Y,0,hwnd,IntPtr.Zero);DestroyMenu(menu);if(selected==1)show();if(selected==3)showFull();if(selected==2)quit();}
            return IntPtr.Zero;
        }
        if(message==PowerBroadcast)
        {
            // PBT_APMRESUMEAUTOMATIC / PBT_APMRESUMESUSPEND: SMB sessions usually
            // die during sleep, so recheck the moment the machine wakes.
            var state=wp.ToInt64();
            if(state==0x12||state==0x07){try{resume?.Invoke();}catch{}}
        }
        return DefSubclassProc(h,message,wp,lp);
    }
    /// Swaps the tray icon for a color-badged variant when myDrive needs
    /// attention, and updates the tooltip. Theme follows the taskbar, not the app.
    public void SetStatus(TrayStatus level)
    {
        var asset=CurrentAsset();var pixels=Math.Max(16,GetSystemMetricsForDpi(49,GetDpiForWindow(hwnd)));
        if(status==level&&asset==iconAsset&&pixels==iconPixels)return;status=level;
        if(asset!=iconAsset||pixels!=iconPixels){var replacement=LoadTrayIcon(asset,pixels);if(replacement!=IntPtr.Zero){var previous=icon;icon=replacement;iconAsset=asset;iconPixels=pixels;if(previous!=IntPtr.Zero)DestroyIcon(previous);}}
        if(statusIcon!=IntPtr.Zero){DestroyIcon(statusIcon);statusIcon=IntPtr.Zero;}
        switch(level)
        {
            case TrayStatus.Problem:statusIcon=TrayStatusIcon.Compose(icon,0xFA3838,iconPixels);tip="myDrive · Needs attention";break;
            case TrayStatus.Attention:statusIcon=TrayStatusIcon.Compose(icon,0xFF9E0A,iconPixels);tip="myDrive · Sync pending";break;
            default:tip="myDrive · Your storage, connected";break;
        }
        if(statusIcon!=IntPtr.Zero)activeIcon=statusIcon;else activeIcon=icon;
        var data=Data();Notify(Modify,ref data);
    }
    public void Dispose(){var data=Data();Notify(2,ref data);RemoveWindowSubclass(hwnd,handler,(UIntPtr)1);if(statusIcon!=IntPtr.Zero)DestroyIcon(statusIcon);if(icon!=IntPtr.Zero)DestroyIcon(icon);}
}
