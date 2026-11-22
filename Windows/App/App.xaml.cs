using Microsoft.UI.Xaml;
namespace MyDrive;
public partial class App : Application
{
    private MainWindow? window;
    private SingleInstance? instance;
    public App()
    {
        RequestedTheme=ApplicationTheme.Light;
        InitializeComponent();
        UnhandledException += (_,e) => { try { Directory.CreateDirectory(CoreBridge.DataDir); File.AppendAllText(Path.Combine(CoreBridge.DataDir,"crash.log"),$"{DateTimeOffset.Now:O} {e.Exception}\n"); } catch {} };
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var commandLine=Environment.GetCommandLineArgs();var diagnostic=Array.IndexOf(commandLine,"--diagnose");
        var blipDiagnostic=Array.IndexOf(commandLine,"--diagnose-blip");
        var viewportDiagnostic=Array.IndexOf(commandLine,"--diagnose-sync-viewport");
        bool diagnostics=diagnostic>=0||blipDiagnostic>=0||viewportDiagnostic>=0;
        if(!diagnostics){instance=new SingleInstance();if(!instance.IsPrimary){_=RedirectAndExit();return;}}
        window = new MainWindow(diagnostics); window.Activate();
        if(commandLine.Contains("--transfers"))window.OpenTransfers();
        instance?.Listen(()=>window.DispatcherQueue.TryEnqueue(()=>window.OpenQuickMenu()));
        window.Closed+=(_,_)=>instance?.Dispose();
        if(diagnostic>=0&&diagnostic+1<commandLine.Length)_=window.Diagnose(commandLine[diagnostic+1]);
        if(blipDiagnostic>=0&&blipDiagnostic+1<commandLine.Length)_=window.DiagnoseBlip(commandLine[blipDiagnostic+1]);
        if(viewportDiagnostic>=0&&viewportDiagnostic+1<commandLine.Length)_=window.DiagnoseSyncViewport(commandLine[viewportDiagnostic+1]);
    }
    private async Task RedirectAndExit(){await instance!.Redirect();instance.Dispose();Exit();}
}
