using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;

public sealed partial class MainWindow
{
    private bool startupEnabled = true;
    private bool startupConfigured;
    private bool startupLoading;
    private DateTime nextStartupRefresh;

    private StackPanel StartupControl()
    {
        var panel = new StackPanel { Spacing = 4 };
        var check = new CheckBox { Content = "Start at boot", IsChecked = startupEnabled, IsEnabled = !startupLoading };
        check.Click += (_, _) => _ = ChangeStartup(check.IsChecked == true ? "startup.enable" : "startup.disable");
        panel.Children.Add(check);
        if (startupEnabled && !startupConfigured)
            panel.Children.Add(QuickButton("Set up before-sign-in startup…", () => _ = SetUpStartup()));
        if (!diagnosticMode && !startupLoading && DateTime.UtcNow >= nextStartupRefresh) _ = ChangeStartup("startup.status");
        return panel;
    }

    private async Task ChangeStartup(string action)
    {
        if (diagnosticMode || startupLoading || quitting) return;
        startupLoading = true;
        nextStartupRefresh = DateTime.UtcNow.AddSeconds(15);
        try
        {
            var state = await CoreBridge.Call(new { action });
            startupEnabled = state.GetProperty("enabled").GetBoolean();
            startupConfigured = state.GetProperty("configured").GetBoolean();
        }
        catch (Exception error) { if (action != "startup.status") Error(error); }
        finally
        {
            startupLoading = false;
            if (!quitting && currentView == "settings") Render();
        }
    }

    private async Task SetUpStartup()
    {
        if (diagnosticMode || startupLoading || quitting) return;
        startupLoading = true;
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "mydrive-cli.exe");
            using var identity = WindowsIdentity.GetCurrent();
            var info = new ProcessStartInfo(path) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Normal };
            info.ArgumentList.Add("startup");
            info.ArgumentList.Add("setup");
            info.ArgumentList.Add(identity.Name);
            using var child = Process.Start(info) ?? throw new IOException("Could not open Windows startup setup.");
            await child.WaitForExitAsync();
            if (child.ExitCode != 0) Info("Startup setup incomplete", "Use your Windows account password in the setup prompt.");
        }
        catch (Exception error) { Error(error); }
        finally { startupLoading = false; }
        await ChangeStartup("startup.status");
    }
}
