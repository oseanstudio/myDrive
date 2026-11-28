using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using WinRT.Interop;

namespace MyDrive;

internal sealed class BlipIncomingWindow : Window
{
    private readonly DispatcherTimer expiry = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly BlipIncomingCard card;
    private readonly Func<RectInt32> anchor;
    private bool hovered, menuOpen;
    private readonly HashSet<string> dismissed = new();
    private string signature = "";
    public FrameworkElement Surface { get; }
    public string TransferId => card.Transfer?.Id ?? "";
    internal BlipReceivedCard FileCard => card.FileCard;
    public event Action<string>? NoticeDismissed;

    public BlipIncomingWindow(Action<BlipTransfer> accept, Action settings, Func<RectInt32> anchor,
                              Action<BlipTransfer>? show = null)
    {
        this.anchor = anchor;
        Title = "myDrive · Incoming transfer";
        AppWindow.SetIcon(MainWindow.AppIconPath);
        card = new BlipIncomingCard(() => WindowNative.GetWindowHandle(this), accept, show ?? (_ => { }), settings, inline: false);
        card.LayoutChanged += () => { if (AppWindow.IsVisible) SizeNearTray(); };
        card.MenuActive += active => { menuOpen = active; UpdateExpiry(); };
        card.DismissRequested += Dismiss;

        var border = (Border)XamlReader.Load("""
            <Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    Background="{ThemeResource ApplicationPageBackgroundThemeBrush}" />
            """);
        border.Padding = new Thickness(5);
        border.Child = new ScrollViewer { Content = card, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        border.RequestedTheme = MainWindow.RequestedAppearance;
        border.PointerEntered += (_, _) => { hovered = true; UpdateExpiry(); };
        border.PointerExited += (_, _) => { hovered = false; UpdateExpiry(); };
        Content = border;
        Surface = border;
        AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(true, true);
            presenter.IsResizable = presenter.IsMaximizable = presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
        }
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            void ApplyCaptionTheme() => AppWindow.TitleBar.PreferredTheme = border.ActualTheme == ElementTheme.Dark
                ? TitleBarTheme.Dark : TitleBarTheme.Light;
            border.ActualThemeChanged += (_, _) => ApplyCaptionTheme();
            ApplyCaptionTheme();
        }
        AppWindow.Closing += (_, args) => { args.Cancel = true; Dismiss(); };
        expiry.Tick += (_, _) => Dismiss();
    }

    private void Dismiss()
    {
        if (card.Transfer != null)
        {
            dismissed.Add(TransferId);
            NoticeDismissed?.Invoke(TransferId);
        }
        Stop();
    }

    private void UpdateExpiry()
    {
        expiry.Stop();
        if (!hovered && !menuOpen && card.Transfer is { } transfer &&
            (transfer.ConfirmedComplete || transfer.HasError || transfer.Status == "Cancelled")) expiry.Start();
    }

    public void Update(BlipTransfer transfer, string name, bool automatic, bool announce)
    {
        if (dismissed.Contains(transfer.Id) || !announce && TransferId != transfer.Id) return;
        card.Update(transfer, name, automatic);
        string next = transfer.Id + ":" + transfer.Status + ":" + transfer.HasError;
        bool changed = signature != next;
        if (changed) { signature = next; UpdateExpiry(); }
        if (changed && AppWindow.IsVisible || announce && !AppWindow.IsVisible) SizeNearTray();
        if (announce && !AppWindow.IsVisible) AppWindow.Show(false);
    }

    private void SizeNearTray()
    {
        var icon = anchor();
        var (area, scale) = TrayPopupPlacement.MonitorAt(TrayPopupPlacement.Center(icon), WindowNative.GetWindowHandle(this));
        int gap = (int)Math.Ceiling(4 * scale);
        int width = Math.Max(1, Math.Min((int)(332 * scale), area.Width - 2 * gap - (int)(16 * scale)));
        Surface.Measure(new Windows.Foundation.Size(width / scale, double.PositiveInfinity));
        int height = Math.Max(1, Math.Min((int)Math.Ceiling(Surface.DesiredSize.Height * scale), area.Height - 2 * gap - (int)(45 * scale)));
        if (AppWindow.ClientSize.Width != width || AppWindow.ClientSize.Height != height) AppWindow.ResizeClient(new SizeInt32(width, height));
        AppWindow.Move(TrayPopupPlacement.Beside(icon, area, AppWindow.Size, gap));
    }

    public void ShowClipboardFailure(string id, string message)
    {
        if (TransferId == id && AppWindow.IsVisible) card.ShowFailure("Could not copy to clipboard. " + message);
    }

    public void Stop() { expiry.Stop(); AppWindow.Hide(); }
    public void ClearFailure() => card.ShowFailure(null);
    public void ShowFailure(string message) => card.ShowFailure(message);
}
