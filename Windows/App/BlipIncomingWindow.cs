using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using WinRT.Interop;
namespace MyDrive;

// A separate native window: tray outside-click dismissal never closes this notice.
internal sealed class BlipIncomingWindow : Window
{
    private readonly TextBlock sender=new(){FontSize=14,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,TextTrimming=TextTrimming.CharacterEllipsis};
    private readonly TextBlock state=new(){FontSize=11,Opacity=.75,TextTrimming=TextTrimming.CharacterEllipsis,MaxWidth=125,VerticalAlignment=VerticalAlignment.Center};
    private readonly TextBlock details=new(){FontSize=11,TextWrapping=TextWrapping.Wrap,Visibility=Visibility.Collapsed};
    private readonly BlipReceivedCard fileCard;
    private readonly ProgressBar progress=new(){IsIndeterminate=true,Height=4};
    private readonly Button receive=new(){Content="Receive",MinHeight=28};
    private readonly DispatcherTimer expiry=new(){Interval=TimeSpan.FromSeconds(30)};
    private bool hovered,menuOpen;
    private readonly HashSet<string> dismissed=new();
    private BlipTransfer? transfer;
    private string signature="";
    private string? failure;
    private readonly Func<RectInt32> anchor;
    public FrameworkElement Surface {get;}
    public string TransferId=>transfer?.Id??"";
    internal BlipReceivedCard FileCard=>fileCard;
    public BlipIncomingWindow(Action<BlipTransfer> accept,Action settings,Func<RectInt32> anchor) {
        this.anchor=anchor;
        Title="myDrive · Incoming transfer";
        var content=new StackPanel{Spacing=8};
        var identity=new Grid{ColumnSpacing=6};
        identity.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});
        identity.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        identity.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        sender.VerticalAlignment=VerticalAlignment.Center;
        identity.Children.Add(sender);Grid.SetColumn(state,1);identity.Children.Add(state);
        var preferences=new Button{Content=new FontIcon{Glyph="\uE713",FontSize=12},MinWidth=28,MinHeight=28,Padding=new Thickness(3)};
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(preferences,"Sender settings");
        ToolTipService.SetToolTip(preferences,"Sender settings");
        preferences.Click+=(_,_)=>settings();
        Grid.SetColumn(preferences,2);identity.Children.Add(preferences);
        content.Children.Add(identity);
        fileCard=new BlipReceivedCard(()=>WindowNative.GetWindowHandle(this));fileCard.MenuActive+=active=>{menuOpen=active;UpdateExpiry();};content.Children.Add(fileCard);content.Children.Add(details);content.Children.Add(progress);
        receive.Click+=(_,_)=>{if(transfer!=null)accept(transfer);};content.Children.Add(receive);
        var border=new Border{Padding=new Thickness(14),Child=new ScrollViewer{Content=content,VerticalScrollBarVisibility=ScrollBarVisibility.Auto},RequestedTheme=MainWindow.RequestedAppearance};
        border.PointerEntered+=(_,_)=>{hovered=true;UpdateExpiry();};border.PointerExited+=(_,_)=>{hovered=false;UpdateExpiry();};
        void ApplyBackground()=>border.Background=new SolidColorBrush(border.ActualTheme==ElementTheme.Dark?Microsoft.UI.ColorHelper.FromArgb(255,32,32,32):Microsoft.UI.Colors.White);
        border.ActualThemeChanged+=(_,_)=>ApplyBackground();
        ApplyBackground();
        Content=border;Surface=border;
        AppWindow.IsShownInSwitchers=false;
        if(AppWindow.Presenter is OverlappedPresenter presenter){presenter.SetBorderAndTitleBar(true,true);presenter.IsResizable=false;presenter.IsMaximizable=false;presenter.IsMinimizable=false;presenter.IsAlwaysOnTop=true;}
        AppWindow.Closing+=(_,e)=>{e.Cancel=true;Dismiss();};expiry.Tick+=(_,_)=>{expiry.Stop();AppWindow.Hide();};
    }
    private void Dismiss(){if(transfer!=null)dismissed.Add(transfer.Id);expiry.Stop();AppWindow.Hide();}
    private void UpdateExpiry(){expiry.Stop();if(!hovered&&!menuOpen&&transfer!=null&&(transfer.ConfirmedComplete||transfer.HasError||transfer.Status=="Cancelled"))expiry.Start();}
    public void Update(BlipTransfer value,string name,bool automatic,bool announce) {
        if(dismissed.Contains(value.Id)||!announce&&TransferId!=value.Id)return;
        transfer=value;sender.Text=name;ToolTipService.SetToolTip(sender,value.Peer);fileCard.SetTransfer(value);
        string next=value.Id+":"+value.Status+":"+value.HasError;
        if(signature!=next)failure=null;
        state.Text=failure!=null||value.HasError?"Needs attention":value.ConfirmedComplete?"Received":automatic&&value.AwaitingAcceptance?"Requesting…":value.ProgressLabel;
        ToolTipService.SetToolTip(state,state.Text);details.Text=failure??(value.HasError?"Transfer needs attention. Open the Blip tab for details.":"");details.Visibility=details.Text.Length>0?Visibility.Visible:Visibility.Collapsed;
        bool pending=value.AwaitingAcceptance&&!value.HasError;
        receive.Visibility=pending&&!automatic?Visibility.Visible:Visibility.Collapsed;
        progress.Visibility=value.Status is "Pending" or "Active" or "ResumeRequested"||automatic&&pending?Visibility.Visible:Visibility.Collapsed;
        progress.IsIndeterminate=!(value.TotalBytes>0&&value.Progress>=0&&value.Progress<=value.TotalBytes);progress.Maximum=Math.Max(1,value.TotalBytes);progress.Value=Math.Max(0,value.Progress);
        if(signature!=next){signature=next;UpdateExpiry();}
        if (announce && !AppWindow.IsVisible)
        {
            var icon = anchor();
            var (area, scale) = TrayPopupPlacement.MonitorAt(TrayPopupPlacement.Center(icon), WindowNative.GetWindowHandle(this));
            int gap = (int)Math.Ceiling(4 * scale);
            var size = new SizeInt32(Math.Min((int)(352 * scale), area.Width - 2 * gap),
                Math.Min((int)(360 * scale), area.Height - 2 * gap));
            AppWindow.Move(TrayPopupPlacement.Beside(icon, area, size, gap));
            AppWindow.Resize(size);
            AppWindow.Show(false);
        }
    }
    public void Stop(){expiry.Stop();AppWindow.Hide();}
    public void ClearFailure(){failure=null;details.Text="";details.Visibility=Visibility.Collapsed;}
    public void ShowFailure(string message){failure=message;state.Text="Needs attention";details.Text=message;details.Visibility=Visibility.Visible;receive.Visibility=Visibility.Visible;progress.Visibility=Visibility.Collapsed;}
}
