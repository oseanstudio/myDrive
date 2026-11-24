using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation;
using Windows.Storage.Pickers;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Text.Json;
using WinRT.Interop;

namespace MyDrive;
public sealed partial class MainWindow : Window
{
    private readonly Grid root=new();
    private readonly StackPanel page=new(){Spacing=20,Padding=new Thickness(36,28,36,32)};
    private readonly ScrollViewer pageScroll=new(){HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
    private readonly Grid quickSyncPane=new(){Visibility=Visibility.Collapsed,Padding=new Thickness(8,4,8,0),RowSpacing=6};
    private readonly NavigationView navigation=new(){PaneDisplayMode=NavigationViewPaneDisplayMode.Left,OpenPaneLength=218,IsBackButtonVisible=NavigationViewBackButtonVisible.Collapsed,IsSettingsVisible=true,IsPaneToggleButtonVisible=false,AlwaysShowHeader=false};
    private readonly InfoBar notice=new(){IsClosable=true,Margin=new Thickness(36,12,36,0)};
    private readonly TextBlock status=new(){Text="Starting myDrive…",FontSize=12,VerticalAlignment=VerticalAlignment.Center};
    private readonly ProgressRing ring=new(){Width=16,Height=16,IsActive=false};
    private readonly Button cancel=new(){Content="Cancel",Visibility=Visibility.Collapsed,Padding=new Thickness(12,2,12,2)};
    private List<Bookmark> bookmarks=new();
    private List<ActivityEntry> activity=new();
    private readonly Dictionary<string,string> health=new();
    private readonly Dictionary<string,TextBlock> smbHealthLabels=new();
    private readonly DispatcherTimer healthTimer=new();
    private readonly CancellationTokenSource smbMonitoringLifetime=new();
    private Dictionary<string,JsonElement> smbHealthState=new();
    private string smbTrigger="periodic";
    private bool smbViewShown;
    private CancellationTokenSource? operation;
    private TrayIcon? tray;
    private bool busy,quitting,monitoring,storageReady;
    private string currentView="transfers",currentPath="";
    private Bookmark? currentBookmark;
    private ListView? filesList;
    private List<RemoteFile> currentFiles=new();
    private string search="";
    private readonly IntPtr hwnd;
    private bool compact=true;
    private bool diagnosticMode;
    private int modalDepth;
    private int nativePickerDepth;
    private readonly PopupInput popupInput;
    private readonly Grid quickHeader=new(){Padding=new Thickness(10,6,10,6),ColumnSpacing=4};
    private readonly Dictionary<string, ToggleButton> quickTabs = new();
    private Border? statusFooter;
    private StackPanel? branding;
    internal static ElementTheme RequestedAppearance => Preferences.Current.Theme switch
    {
        "Dark" => ElementTheme.Dark,
        "Light" => ElementTheme.Light,
        _ => ElementTheme.Default,
    };
    private static ElementTheme colorTheme=RequestedAppearance;
    private ContentDialog? activeDialog;
    private Window? detachedDialog;
    private readonly Dictionary<(ElementTheme,string),SolidColorBrush> themeBrushes=new();
    private Windows.Graphics.PointInt32? quickOrigin;
    private const string StorageViewName = "SMB Drives";
    private const string SendViewName = "Blip";
    private const string SyncViewName = "Syncthing";
    private static string DisplayVersion => typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "";

    private SolidColorBrush Brush(string resource)
    {
        // Theme resources are resolved by XAML when the element joins the visual tree.
        // A direct Application.Resources lookup can fail before the first window loads.
        if(themeBrushes.TryGetValue((colorTheme,resource),out var cached))return cached;
        var holder=(Border)Microsoft.UI.Xaml.Markup.XamlReader.Load($"<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' RequestedTheme='{colorTheme}' Background='{{ThemeResource {resource}}}' />");
        return themeBrushes[(colorTheme,resource)]=holder.Background as SolidColorBrush ?? new SolidColorBrush(Colors.Transparent);
    }
    private static TextBlock Text(string value,double size=14,bool strong=false)=>new(){Text=value,FontSize=size,FontWeight=strong?Microsoft.UI.Text.FontWeights.SemiBold:Microsoft.UI.Text.FontWeights.Normal,TextWrapping=TextWrapping.Wrap};
    private static Button Button(string label,Action action,bool accent=false){var b=new Button{Content=label};if(accent)b.Style=(Style)Application.Current.Resources["AccentButtonStyle"];b.Click+=(_,_)=>action();return b;}
    private Border Card(UIElement content)=>new(){Child=content,Padding=new Thickness(compact?8:22),CornerRadius=new CornerRadius(compact?5:10),Background=Brush("CardBackgroundFillColorDefaultBrush"),BorderBrush=Brush("CardStrokeColorDefaultBrush"),BorderThickness=new Thickness(1)};

    public MainWindow(bool diagnostics=false)
    {
        diagnosticMode=diagnostics;
        popupInput=new PopupInput(point=>DispatcherQueue.TryEnqueue(()=>DismissAt(point)));
        Title="myDrive";SystemBackdrop=new MicaBackdrop();root.RequestedTheme=RequestedAppearance;root.Background=Brush("ApplicationPageBackgroundThemeBrush");
        hwnd=WindowNative.GetWindowHandle(this);AppWindow.Resize(new Windows.Graphics.SizeInt32(1160,790));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory,"Assets","myDrive.ico"));
        root.RowDefinitions.Add(new(){Height=GridLength.Auto});root.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});root.RowDefinitions.Add(new(){Height=GridLength.Auto});
        branding=new StackPanel{Orientation=Orientation.Horizontal,Spacing=12,Margin=new Thickness(20,22,12,22)};
        branding.Children.Add(new Image{Source=new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory,"Assets","myDrive.png"))),Width=38,Height=38});branding.Children.Add(Text("myDrive",22,true));navigation.PaneHeader=branding;
        navigation.MenuItems.Add(new NavigationViewItem{Content=SendViewName,Icon=new SymbolIcon(Symbol.Send),Tag="transfers"});
        navigation.MenuItems.Add(new NavigationViewItem{Content=SyncViewName,Icon=new SymbolIcon(Symbol.Switch),Tag="sync"});
        navigation.MenuItems.Add(new NavigationViewItem{Content=StorageViewName,Icon=new SymbolIcon(Symbol.World),Tag="connections"});
        navigation.MenuItems.Add(new NavigationViewItem{Content="Activity",Icon=new SymbolIcon(Symbol.Sync),Tag="activity"});
        navigation.PaneFooter=Text($"  myDrive {DisplayVersion}",12);
        var content=new Grid();content.RowDefinitions.Add(new(){Height=GridLength.Auto});content.RowDefinitions.Add(new(){Height=GridLength.Auto});content.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});
        content.Children.Add(notice);Grid.SetRow(updateOffer,1);content.Children.Add(updateOffer);
        pageScroll.Content=page;Grid.SetRow(pageScroll,2);content.Children.Add(pageScroll);
        quickSyncPane.RowDefinitions.Add(new(){Height=GridLength.Auto});
        quickSyncPane.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});
        Grid.SetRow(quickSyncPane,2);content.Children.Add(quickSyncPane);navigation.Content=content;
        navigation.SelectionChanged+=(sender,e)=>{if(busy)return;currentView=e.IsSettingsSelected?"settings":(e.SelectedItem as NavigationViewItem)?.Tag?.ToString()??"transfers";Render();if(!diagnosticMode&&currentView=="sync"&&Environment.TickCount64-lastSyncRefresh>=10_000)_=RefreshSyncthing();if(currentView=="transfers")_=RefreshBlip();};
        Grid.SetRow(navigation,1);root.Children.Add(navigation);
        BuildQuickHeader();root.Children.Add(quickHeader);
        var footer=new Grid{Padding=new Thickness(24,10,24,10),ColumnSpacing=10};footer.ColumnDefinitions.Add(new(){Width=GridLength.Auto});footer.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});footer.ColumnDefinitions.Add(new(){Width=GridLength.Auto});footer.Children.Add(ring);Grid.SetColumn(status,1);footer.Children.Add(status);Grid.SetColumn(cancel,2);footer.Children.Add(cancel);cancel.Click+=(_,_)=>operation?.Cancel();
        statusFooter=new Border{Child=footer,BorderBrush=Brush("DividerStrokeColorDefaultBrush"),BorderThickness=new Thickness(0,1,0,0)};Grid.SetRow(statusFooter,2);root.Children.Add(statusFooter);
        Content=root;
        root.ActualThemeChanged+=(_,_)=>ApplyCurrentTheme();
        try{tray=new TrayIcon(hwnd,ToggleQuickMenu,Quit,()=>SetMode(false),()=>_=OnSystemResume());}catch{compact=false;}
        EnableFileDrop();
        AppWindow.Closing+=(_,e)=>{if(!quitting&&tray!=null){e.Cancel=true;AppWindow.Hide();}};
        Closed+=(_,_)=>{popupInput.Dispose();StopSmbMonitoring();updateTimer.Stop();autoUpdateTimer.Stop();tray?.Dispose();operation?.Cancel();smbHosting.Dispose();};
        AppWindow.Changed+=(_,e)=>{if(compact&&AppWindow.IsVisible)popupInput.Start();else popupInput.Stop();UpdateSmbView();UpdateBlipView();};
        Activated+=(_,e)=>{if(e.WindowActivationState==WindowActivationState.Deactivated)DispatcherQueue.TryEnqueue(()=>{if(!diagnosticMode&&!PopupInput.OurForeground()&&tray?.PointerInside()!=true&&!popupInput.TrackingPress&&!LeftMousePressed())DismissQuickPopup();});};
        healthTimer.Tick+=async(_,_)=>await MonitorSmb();
        if(!diagnosticMode)NetworkChange.NetworkAddressChanged+=OnSmbNetworkChanged;
        navigation.SelectedItem=navigation.MenuItems[0];
        SetMode(compact);
        if(!diagnosticMode){_=Initialize();StartSyncthingRefresh();StartBlipRefresh();StartUpdateChecks();}
    }
    private void ToggleQuickMenu(){if(compact&&AppWindow.IsVisible){AppWindow.Hide();return;}OpenQuickMenu();}
    public void OpenQuickMenu()
    {
        if (detachedDialog != null) { detachedDialog.Activate(); return; }
        if (nativePickerDepth > 0 && !AppWindow.IsVisible) return;
        if (!AppWindow.IsVisible && !busy && modalDepth == 0 && currentView != "transfers")
            NavigateQuick("transfers");
        SetMode(true);
    }
    public void OpenTransfers(){currentView="transfers";OpenQuickMenu();}
    private void SetMode(bool small,bool activate=true)
    {
        bool placePopup=small&&(!compact||!AppWindow.IsVisible||quickOrigin==null);
        compact=small;quickHeader.Visibility=small?Visibility.Visible:Visibility.Collapsed;
        navigation.PaneDisplayMode=small?NavigationViewPaneDisplayMode.LeftMinimal:NavigationViewPaneDisplayMode.Left;navigation.IsPaneVisible=!small;navigation.IsPaneOpen=!small;
        navigation.PaneHeader=small?null:branding;
        navigation.PaneFooter=small?null:Text($"  myDrive {DisplayVersion}",12);
        page.Padding=new Thickness(small?8:36,small?4:28,small?8:36,small?8:32);page.Spacing=small?6:20;
        notice.Margin=new Thickness(small?16:36,8,small?16:36,0);
        status.MaxWidth=small?260:double.PositiveInfinity;status.TextTrimming=TextTrimming.CharacterEllipsis;
        AppWindow.IsShownInSwitchers=!small;
        if(AppWindow.Presenter is OverlappedPresenter presenter){presenter.SetBorderAndTitleBar(true,!small);presenter.IsResizable=!small;presenter.IsMaximizable=!small;presenter.IsMinimizable=!small;presenter.IsAlwaysOnTop=small;}
        double scale=TrayIcon.Scale(hwnd);var area=DisplayArea.GetFromWindowId(AppWindow.Id,DisplayAreaFallback.Nearest).WorkArea;
        if(small)SizeQuickMenu(placePopup);
        else{quickOrigin=null;var width=Math.Min((int)(1160*scale),area.Width-24);var height=Math.Min((int)(790*scale),area.Height-24);AppWindow.Resize(new(width,height));AppWindow.Move(new(area.X+(area.Width-width)/2,area.Y+(area.Height-height)/2));}
        Render();AppWindow.Show(activate);if(activate){Activate();PopupInput.Foreground(hwnd);_=CheckForUpdate();}if(small)popupInput.Start();else popupInput.Stop();if(currentView=="sync"&&!diagnosticMode)_=RefreshSyncthing();
    }
    private void DismissQuickPopup()
    {
        if(!compact||!AppWindow.IsVisible||nativePickerDepth>0)return;
        activeDialog?.Hide(); // Outside clicks cancel embedded confirmations, never accept them.
        AppWindow.Hide();popupInput.Stop(); // Background transfers and syncing continue.
    }
    private void DismissAt(Windows.Graphics.PointInt32 point,bool allowDiagnostic=false)
    {
        if(diagnosticMode&&!allowDiagnostic||!compact||!AppWindow.IsVisible||nativePickerDepth>0)return;
        var origin=AppWindow.Position;var size=AppWindow.Size;
        if(point.X>=origin.X&&point.X<origin.X+size.Width&&point.Y>=origin.Y&&point.Y<origin.Y+size.Height)return;
        if(PopupInput.OurWindowAt(point)||tray?.Contains(point)==true)return; // Native flyouts and tray toggle.
        DismissQuickPopup();
    }
    private int QuickWidth()=>344;
    private int QuickHeight()=>420;
    private void SizeQuickMenu(bool placeOnOpen=false)
    {
        if(!compact)return;var area=DisplayArea.GetFromWindowId(AppWindow.Id,DisplayAreaFallback.Nearest).WorkArea;var scale=TrayIcon.Scale(hwnd);
        int width=Math.Min((int)(QuickWidth()*scale),area.Width-24),height=Math.Min((int)(QuickHeight()*scale),area.Height-24);
        if(placeOnOpen||quickOrigin==null){var anchor=tray?.Anchor()??new Windows.Graphics.PointInt32(area.X+area.Width,area.Y+area.Height);quickOrigin=new(anchor.X-width,anchor.Y>area.Y+area.Height/2?anchor.Y-height-8:anchor.Y+32);}
        // A redraw must never consult the cursor or tray again. Reposition only
        // when opening, or if a changed work area would put the popup off-screen.
        var origin=quickOrigin.Value;var position=new Windows.Graphics.PointInt32(Math.Clamp(origin.X,area.X+8,Math.Max(area.X+8,area.X+area.Width-width-8)),Math.Clamp(origin.Y,area.Y+8,Math.Max(area.Y+8,area.Y+area.Height-height-8)));
        quickOrigin=position;
        if(AppWindow.Size.Width!=width||AppWindow.Size.Height!=height)AppWindow.Resize(new(width,height));
        if(AppWindow.Position.X!=position.X||AppWindow.Position.Y!=position.Y)AppWindow.Move(position);
    }
    private async void Quit(){if(quitting)return;quitting=true;await DiscardPreparedUpdate();blipLinks?.ResetSession();await Task.WhenAll(blip.StopAsync(),SyncthingService.StopAsync());Close();Application.Current.Exit();}
    private async Task Initialize()
    {
        try{bookmarks=await CoreBridge.Load();storageReady=true;var journal=Path.Combine(CoreBridge.DataDir,"activity.json");if(File.Exists(journal))try{activity=JsonSerializer.Deserialize<List<ActivityEntry>>(await File.ReadAllTextAsync(journal))??new();}catch{}status.Text="Ready · Credentials protected by Windows";RequestSmbCheck("periodic");Render();if(!diagnosticMode)_=RefreshSyncthing();}
        catch(Exception e){Error(e);status.Text="Could not load connections. The saved file has been preserved.";Render();}
    }
    private void Error(Exception e){notice.Title=e is OperationCanceledException?"Operation canceled":"Something needs attention";notice.Message=e is OperationCanceledException?"The transfer stopped. To resume an SMB copy, retry with the same file and destination.":e.Message;notice.Severity=e is OperationCanceledException?InfoBarSeverity.Informational:InfoBarSeverity.Error;notice.IsOpen=true;SizeQuickMenu();}
    private void Info(string title,string detail){notice.Title=title;notice.Message=detail;notice.Severity=InfoBarSeverity.Informational;notice.IsOpen=true;SizeQuickMenu();}
    private async Task Run(string label,Func<CancellationToken,Task> work,Bookmark? b=null)
    {
        if(busy)return;busy=true;UpdateQuickChrome();operation=new();ring.IsActive=true;cancel.Visibility=Visibility.Visible;status.Text=label;notice.IsOpen=false;navigation.IsEnabled=false;SizeQuickMenu();
        bool success=false;string detail=label;
        try{await work(operation.Token);success=true;status.Text="Ready · "+label+" complete";}
        catch(Exception e){detail=e.Message;Error(e);status.Text=e is OperationCanceledException?"Canceled":"Operation failed";}
        finally{operation.Dispose();operation=null;busy=false;UpdateQuickChrome();ring.IsActive=false;cancel.Visibility=Visibility.Collapsed;navigation.IsEnabled=true;await Record(new(DateTimeOffset.Now,label,b?.nickname??"myDrive",detail,success));}
    }
    private async Task Record(ActivityEntry entry)
    {
        activity.Insert(0,entry);if(activity.Count>200)activity.RemoveRange(200,activity.Count-200);
        try{Directory.CreateDirectory(CoreBridge.DataDir);var p=Path.Combine(CoreBridge.DataDir,"activity.json");await File.WriteAllTextAsync(p+".tmp",JsonSerializer.Serialize(activity));File.Move(p+".tmp",p,true);}catch{}
    }
    private void Render(){ResetSyncControls();UpdateQuickChrome();page.Children.Clear();if(currentView=="transfers")RenderBlip();else if(currentView=="sync-info")RenderSyncInfo();else if(currentView=="sync-attention")RenderSyncAttention();else if(currentView=="sync")RenderSyncthing();else if(currentView=="sync-files")RenderSyncFiles();else if(currentView=="activity")RenderActivity();else if(currentView=="settings")RenderSettings();else if(currentView=="files")RenderFiles();else RenderConnections();SizeQuickMenu();UpdateSmbView();UpdateBlipView();}
    private void Heading(string title,string subtitle){page.Children.Add(Text(title,compact?16:30,true));if(compact)return;var sub=Text(subtitle,14);sub.Foreground=Brush("TextFillColorSecondaryBrush");page.Children.Add(sub);}
    private void RenderConnections()
    {
        page.Children.Add(RenderSmbOverview());
        if (compact) RenderQuickConnections();
        else
        {
            var line=new Grid();line.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});line.ColumnDefinitions.Add(new(){Width=new GridLength(260)});line.Children.Add(Text("Saved SMB shares",18,true));
            var filter=new AutoSuggestBox{PlaceholderText="Find SMB shares",Text=search};filter.TextChanged+=(_,_)=>{search=filter.Text;RenderConnectionList();};Grid.SetColumn(filter,1);line.Children.Add(filter);page.Children.Add(line);
            connectionsPanel=new StackPanel{Spacing=10};page.Children.Add(connectionsPanel);RenderConnectionList();
        }
        if (RenderTailDevices() is { } devices) page.Children.Add(devices);
    }
    private StackPanel? connectionsPanel;
    private void RenderConnectionList()
    {
        smbHealthLabels.Clear();
        if(compact){RenderQuickConnectionList();return;}
        if(connectionsPanel==null)return;connectionsPanel.Children.Clear();
        foreach(var b in bookmarks.Where(b=>b.protocol=="smb" && (b.nickname+" "+b.host).Contains(search,StringComparison.OrdinalIgnoreCase)))
        {
            var grid=new Grid{ColumnSpacing=compact?10:18};grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});grid.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            if(!compact)grid.Children.Add(new Border{Width=46,Height=46,CornerRadius=new(9),Background=Brush("AccentFillColorDefaultBrush"),Child=new FontIcon{Glyph=b.protocol=="local"?"\uE8B7":b.protocol=="smb"?"\uE968":"\uE753",Foreground=new SolidColorBrush(Colors.White),FontSize=22}});
            var details=new StackPanel{Spacing=4,VerticalAlignment=VerticalAlignment.Center};details.Children.Add(new TextBlock{Text=b.nickname,FontSize=compact?15:17,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,TextTrimming=TextTrimming.CharacterEllipsis});details.Children.Add(new TextBlock{Text=b.Location,TextTrimming=TextTrimming.CharacterEllipsis,Foreground=Brush("TextFillColorSecondaryBrush"),MaxWidth=compact?190:470,HorizontalAlignment=HorizontalAlignment.Left,FontSize=compact?12:14});details.Children.Add(CreateSmbHealthLabel(b,12));Grid.SetColumn(details,1);grid.Children.Add(details);
            var actions=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,VerticalAlignment=VerticalAlignment.Center};actions.Children.Add(Button("Browse",()=>_=Browse(b),true));
            var more=new Button{Content="···"};var menu=new MenuFlyout();var explorer=new MenuFlyoutItem{Text="Open in Explorer",Icon=new SymbolIcon(Symbol.OpenLocal)};explorer.Click+=(_,_)=>OpenExplorer(b);menu.Items.Add(explorer);
            var remove=new MenuFlyoutItem{Text="Remove saved share",Icon=new SymbolIcon(Symbol.Delete)};remove.Click+=(_,_)=>_=DeleteBookmark(b);menu.Items.Add(remove);more.Flyout=menu;actions.Children.Add(more);Grid.SetColumn(actions,2);grid.Children.Add(actions);connectionsPanel.Children.Add(Card(grid));
        }
        if(connectionsPanel.Children.Count==0)connectionsPanel.Children.Add(Text(search.Length==0?"No saved SMB shares.":"No matching SMB shares.",13));
    }
    private async Task TestConnection(Bookmark b)=>await Run("Test connection",async token=>{if(b.protocol=="smb")await Native.ConnectSmb(b,token);var files=await CoreBridge.List(b,"",token);health[b.id]="Connected";Info("Connection successful",$"{b.nickname} is reachable. {files.Count} items in its root folder.");Render();},b);
    private async Task Browse(Bookmark b,string path="")=>await Run("List files",async token=>{if(b.protocol=="smb")await Native.ConnectSmb(b,token);currentFiles=await CoreBridge.List(b,path,token);currentBookmark=b;currentPath=path;currentView="files";health[b.id]="Connected";Render();},b);
    private void RenderFiles()
    {
        if(currentBookmark==null){currentView="connections";Render();return;}
        if(compact){RenderQuickFiles();return;}
        var b=currentBookmark;Heading(b.nickname,b.ProtocolName+"  ·  "+b.Location);
        var toolbar=new CommandBar{DefaultLabelPosition=CommandBarDefaultLabelPosition.Collapsed,HorizontalAlignment=HorizontalAlignment.Stretch,IsDynamicOverflowEnabled=true};
        void Command(string label,Symbol icon,Action action){var button=new AppBarButton{Label=label,Icon=new SymbolIcon(icon)};button.Click+=(_,_)=>action();toolbar.PrimaryCommands.Add(button);}
        Command(StorageViewName,Symbol.Back,()=>{if(busy)return;currentView="connections";Render();});Command("Up",Symbol.Up,()=>{if(busy)return;var slash=currentPath.LastIndexOf('/');_=Browse(b,slash<0?"":currentPath[..slash]);});Command("Refresh",Symbol.Refresh,()=>_=Browse(b,currentPath));Command("Upload file",Symbol.Upload,()=>_=Upload());Command("New folder",Symbol.NewFolder,()=>_=NewFolder());page.Children.Add(toolbar);
        page.Children.Add(Text("/"+currentPath,14,true));
        var header=FileRow("Name","Size","Modified",true);page.Children.Add(header);
        filesList=new ListView{SelectionMode=ListViewSelectionMode.Single,IsItemClickEnabled=true,MinHeight=100,MaxHeight=compact?230:400,HorizontalAlignment=HorizontalAlignment.Stretch};
        filesList.ItemContainerStyle=new Style(typeof(ListViewItem));filesList.ItemContainerStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty,HorizontalAlignment.Stretch));
        foreach(var f in currentFiles){var row=FileRow((f.is_dir?"▰  ":"     ")+f.name,f.Size,f.Modified);row.Tag=f;filesList.Items.Add(row);}
        filesList.DoubleTapped+=(_,_)=>{if(busy)return;if(SelectedFile() is {} f){if(f.is_dir)_=Browse(b,f.path);else _=Download(f,true);}};
        page.Children.Add(filesList);if(currentFiles.Count==0)page.Children.Add(Text("This folder is empty.",16));
        var actions=new CommandBar{DefaultLabelPosition=CommandBarDefaultLabelPosition.Right,IsDynamicOverflowEnabled=true,HorizontalAlignment=HorizontalAlignment.Stretch};
        void FileAction(string label,Symbol icon,Action action){var button=new AppBarButton{Label=label,Icon=new SymbolIcon(icon)};button.Click+=(_,_)=>action();actions.PrimaryCommands.Add(button);}
        FileAction("Open",Symbol.OpenFile,()=>{if(SelectedFile() is {} f){if(f.is_dir)_=Browse(b,f.path);else _=Download(f,true);}});FileAction("Download",Symbol.Download,()=>{if(SelectedFile() is {} f&&!f.is_dir)_=Download(f,false);});FileAction("Rename",Symbol.Rename,()=>_=Rename());FileAction("Delete",Symbol.Delete,()=>_=DeleteFile());page.Children.Add(actions);
        var note=Text(b.protocol is "local" or "smb"?"Files open directly in their usual apps. Saves go back to this folder.":"Opening a remote file downloads a copy. Edits to that copy are not uploaded automatically. Use Sync for local folders kept on your Syncthing devices.",12);note.Foreground=Brush("TextFillColorSecondaryBrush");page.Children.Add(note);
    }
    private Grid FileRow(string name,string size,string modified,bool header=false){var g=new Grid{ColumnSpacing=compact?8:14,Padding=new Thickness(compact?4:12,header?0:10,compact?4:12,header?0:10),HorizontalAlignment=HorizontalAlignment.Stretch};g.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});g.ColumnDefinitions.Add(new(){Width=new GridLength(compact?65:90)});if(!compact)g.ColumnDefinitions.Add(new(){Width=new GridLength(180)});var n=Text(name,header?12:14,header);n.TextTrimming=TextTrimming.CharacterEllipsis;n.TextWrapping=TextWrapping.NoWrap;g.Children.Add(n);var s=Text(size,12);Grid.SetColumn(s,1);g.Children.Add(s);if(!compact){var m=Text(modified,12);Grid.SetColumn(m,2);g.Children.Add(m);}ToolTipService.SetToolTip(g,name+"\n"+modified);return g;}
    private RemoteFile? SelectedFile()=>(filesList?.SelectedItem as Grid)?.Tag as RemoteFile;
    private async Task Upload()
    {
        if(busy||currentBookmark==null)return;var picker=new FileOpenPicker();InitializeWithWindow.Initialize(picker,hwnd);picker.FileTypeFilter.Add("*");var file=await Modal(async()=>await picker.PickSingleFileAsync());if(file==null)return;var b=currentBookmark;var path=Join(currentPath,file.Name);
        await Run("Upload "+file.Name,async token=>{if(currentFiles.Any(f=>f.name==file.Name))throw new IOException("A file with this name already exists. Rename the local file before uploading.");await CoreBridge.Operation("upload",b,path,file.Path,token:token);currentFiles=await CoreBridge.List(b,currentPath,token);Render();},b);
    }
    private async Task Download(RemoteFile file,bool open)
    {
        if(busy||currentBookmark==null)return;var b=currentBookmark;string folder;
        if(open&&b.protocol is "local" or "smb"){try{Process.Start(new ProcessStartInfo(Path.Combine(b.protocol=="local"?Path.Combine(b.host,b.path):b.Location,file.path.Replace('/','\\'))){UseShellExecute=true});}catch(Exception e){Error(e);}return;}
        if(open){folder=Path.Combine(CoreBridge.DataDir,"Opened files",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);}else{var picker=new FolderPicker();InitializeWithWindow.Initialize(picker,hwnd);picker.FileTypeFilter.Add("*");var picked=await Modal(async()=>await picker.PickSingleFolderAsync());if(picked==null)return;folder=picked.Path;}
        var destination=Path.Combine(folder,file.name);await Run("Download "+file.name,async token=>{await CoreBridge.Operation("download",b,file.path,destination,token:token);if(open){Process.Start(new ProcessStartInfo(destination){UseShellExecute=true});Info("Opened a local copy","Edits to this copy are not uploaded automatically. Use Upload file to send a new file to the server.");}else Info("Download complete",destination);},b);
    }
    private static string Join(string parent,string name)=>parent.Length==0?name:parent+"/"+name;
    private async Task<string?> Prompt(string title,string initial="")
    {
        if(busy)return null;var input=new TextBox{Text=initial,PlaceholderText="Name"};var d=new ContentDialog{XamlRoot=root.XamlRoot,Title=title,Content=input,PrimaryButtonText="Save",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Primary};if(await ShowDialog(d)!=ContentDialogResult.Primary)return null;var name=input.Text.Trim();if(name.Length==0||name is "." or ".."||name.IndexOfAny(['/', '\\', ':', '\0'])>=0){Error(new IOException("Enter a single valid file or folder name."));return null;}return name;
    }
    private async Task NewFolder(){if(currentBookmark==null)return;var name=await Prompt("New folder");if(name==null)return;var b=currentBookmark;await Run("Create folder",async token=>{await CoreBridge.Operation("mkdir",b,Join(currentPath,name),token:token);currentFiles=await CoreBridge.List(b,currentPath,token);Render();},b);}
    private async Task Rename(){if(SelectedFile() is not {} f||currentBookmark==null)return;var name=await Prompt("Rename",f.name);if(name==null||name==f.name)return;var b=currentBookmark;await Run("Rename "+f.name,async token=>{await CoreBridge.Operation("rename",b,f.path,destination:Join(currentPath,name),token:token);currentFiles=await CoreBridge.List(b,currentPath,token);Render();},b);}
    private async Task DeleteFile(){if(busy||SelectedFile() is not {} f||currentBookmark==null)return;var d=new ContentDialog{XamlRoot=root.XamlRoot,Title=$"Delete {f.name}?",Content=f.is_dir?"The folder must be empty, except on WebDAV where the server may delete its contents. This action cannot be undone.":"This permanently removes the remote file. This action cannot be undone.",PrimaryButtonText="Delete",CloseButtonText="Cancel"};if(await ShowDialog(d)!=ContentDialogResult.Primary)return;var b=currentBookmark;await Run("Delete "+f.name,async token=>{await CoreBridge.Operation("delete",b,f.path,isDir:f.is_dir,token:token);currentFiles=await CoreBridge.List(b,currentPath,token);Render();},b);}
    private void OpenExplorer(Bookmark b){try{Process.Start(new ProcessStartInfo("explorer.exe"){ArgumentList={b.protocol=="local"?Path.Combine(b.host,b.path):b.Location},UseShellExecute=true});}catch(Exception e){Error(e);}}
    private void RenderActivity()
    {
        Heading("Activity","Connection checks and file transfers, kept on this computer.");
        RenderSendActivity();
        if(activity.Count==0)return;
        foreach(var entry in activity.Take(100)){var content=new StackPanel{Spacing=6};content.Children.Add(Text((entry.Success?"✓  ":"!  ")+entry.Operation,16,true));content.Children.Add(Text(entry.Connection+"  ·  "+entry.Time.LocalDateTime.ToString("MMM d  HH:mm:ss"),12));if(!entry.Success)content.Children.Add(Text(entry.Detail));page.Children.Add(Card(content));}
    }
    private void RenderSettings()
    {
        var appearance=new StackPanel{Spacing=6};appearance.Children.Add(Text("Appearance",13,true));
        var themes = new[] { "System", "Light", "Dark" };
        var theme = new ComboBox { ItemsSource = themes, SelectedIndex = Math.Max(0, Array.IndexOf(themes, Preferences.Current.Theme)), MinWidth = 220 };
        theme.SelectionChanged+=(_,_)=>{
            if(theme.SelectedItem is not string selected || selected==Preferences.Current.Theme)return;
            Preferences.Current.Theme=selected;Preferences.Save();
            root.RequestedTheme=RequestedAppearance;
            if(blipIncomingWindow!=null)blipIncomingWindow.Surface.RequestedTheme=RequestedAppearance;
            ApplyCurrentTheme();
        };
        appearance.Children.Add(theme);page.Children.Add(appearance);
        page.Children.Add(StartupControl());
        page.Children.Add(AutoUpdateSetting());
        page.Children.Add(Button("Check for updates",()=>_=CheckForUpdate(showResult:true)));
        var advanced=new DropDownButton{Content="Advanced"};var menu=new MenuFlyout();
        MenuAction(menu,"Syncthing settings…",()=>_=EditSyncthingConnection());
        MenuAction(menu,"Open app data folder",()=>{Directory.CreateDirectory(CoreBridge.DataDir);Process.Start(new ProcessStartInfo("explorer.exe"){ArgumentList={CoreBridge.DataDir},UseShellExecute=true});});
        advanced.Flyout=menu;page.Children.Add(advanced);
        page.Children.Add(Button("Quit myDrive",Quit));
    }
    private void ApplyCurrentTheme()
    {
        colorTheme=root.ActualTheme;
        root.Background=Brush("ApplicationPageBackgroundThemeBrush");
        if(statusFooter!=null)statusFooter.BorderBrush=Brush("DividerStrokeColorDefaultBrush");
        Render();
    }
    private void UpdateSmbView()
    {
        bool visible = currentView == "connections" && AppWindow.IsVisible && storageReady;
        if (visible && !smbViewShown) RequestSmbCheck("view");
        smbViewShown = visible;
    }

    private TextBlock CreateSmbHealthLabel(Bookmark bookmark, double size)
    {
        var label = Text("", size);
        smbHealthLabels[bookmark.id] = label;
        SetSmbHealthLabel(label, health.GetValueOrDefault(bookmark.id, "Checking…"));
        return label;
    }

    private void SetSmbHealthLabel(TextBlock label, string value)
    {
        label.Text = $"SMB · {value}";
        label.Foreground = value is "Unavailable" or "Access denied"
            ? new SolidColorBrush(colorTheme == ElementTheme.Dark ? Colors.LightCoral : Colors.Firebrick)
            : Brush("TextFillColorSecondaryBrush");
    }

    private void OnSmbNetworkChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(() => RequestSmbCheck("network"));

    private Task OnSystemResume()
    {
        RequestSmbCheck("wake");
        return Task.CompletedTask;
    }

    private void RequestSmbCheck(string trigger)
    {
        if (diagnosticMode || quitting || smbMonitoringLifetime.IsCancellationRequested || !storageReady) return;
        if (trigger != "periodic") smbTrigger = trigger;
        if (!monitoring) ScheduleSmbCheck(trigger is "wake" or "network" ? 2 : 1);
    }

    private void ScheduleSmbCheck(int seconds)
    {
        healthTimer.Stop();
        healthTimer.Interval = TimeSpan.FromSeconds(seconds);
        healthTimer.Start();
    }

    private void StopSmbMonitoring()
    {
        healthTimer.Stop();
        smbMonitoringLifetime.Cancel();
        if (!diagnosticMode) NetworkChange.NetworkAddressChanged -= OnSmbNetworkChanged;
    }

    private async Task MonitorSmb()
    {
        healthTimer.Stop();
        if (monitoring || quitting || smbMonitoringLifetime.IsCancellationRequested) return;
        monitoring = true;
        var trigger = smbTrigger;
        smbTrigger = "periodic";
        int next = 90;
        try
        {
            if (smbViewShown) _ = RefreshSmbInventory(trigger != "periodic");
            var targets = bookmarks.Where(b => b.protocol == "smb").Select(b => new
            {
                b.id,
                probe = new { kind = "path", value = $@"\\{b.host.Trim('\\')}\{b.path.Trim('/', '\\').Replace('/', '\\')}" },
            }).ToArray();
            if (targets.Length == 0)
            {
                smbHealthState.Clear();
                return;
            }
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(smbMonitoringLifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            var response = await CoreBridge.Call(new
            {
                action = "smb.health",
                payload = new { trigger, targets, previous = smbHealthState },
            }, timeout.Token);
            if (quitting || smbMonitoringLifetime.IsCancellationRequested) return;
            smbHealthState = response.GetProperty("states").Deserialize<Dictionary<string,JsonElement>>() ?? new();
            next = response.GetProperty("next_seconds").GetInt32();
            bool changed = false;
            foreach (var (id, state) in smbHealthState)
            {
                var label = state.GetProperty("status").GetString() switch
                {
                    "connected" => "Connected",
                    "access_denied" => "Access denied",
                    _ => "Unavailable",
                };
                if (health.GetValueOrDefault(id) == label) continue;
                health[id] = label;
                if (smbViewShown && smbHealthLabels.TryGetValue(id, out var text))
                    SetSmbHealthLabel(text, label);
                changed = true;
            }
            if (changed) UpdateProblemColors();
        }
        catch (Exception e) when (e is IOException or JsonException or OperationCanceledException or System.ComponentModel.Win32Exception) { }
        finally
        {
            monitoring = false;
            if (!quitting && !smbMonitoringLifetime.IsCancellationRequested) ScheduleSmbCheck(smbTrigger == "periodic" ? next : 2);
        }
    }

    // Color notifications: the tray icon and status text turn orange for
    // pending or paused work and red for anything actually broken — mirroring
    // the macOS menu bar tint.
    private TrayStatus CurrentStatus()
    {
        if(syncFailure.Length>0)return TrayStatus.Problem;
        if(bookmarks.Any(b=>health.GetValueOrDefault(b.id)=="Unavailable"))return TrayStatus.Problem;
        if(syncSnapshot is { } snapshot)
        {
            var folders=Items(snapshot,"folders").ToList();
            var active=folders.Where(f=>!B(f,"paused")).ToList();
            if(active.Any(HasFolderError))return TrayStatus.Problem;
            if(folders.Count>0&&folders.All(f=>B(f,"paused")))return TrayStatus.Attention;
            if(active.Any(f=>N(FolderStats(f),"needFiles")>0))return TrayStatus.Attention;
        }
        return TrayStatus.Normal;
    }
    private void UpdateProblemColors()
    {
        var level=CurrentStatus();
        tray?.SetStatus(level);
        status.Foreground=level switch
        {
            TrayStatus.Problem=>new SolidColorBrush(colorTheme==ElementTheme.Dark?Colors.LightCoral:Colors.Firebrick),
            TrayStatus.Attention=>new SolidColorBrush(Colors.Orange),
            _=>Brush("TextFillColorSecondaryBrush"),
        };
    }
    private Microsoft.UI.Xaml.Shapes.Ellipse StatusDot(double size=8)
    {
        var level=CurrentStatus();
        var color=level switch
        {
            TrayStatus.Problem=>colorTheme==ElementTheme.Dark?Colors.LightCoral:Colors.Firebrick,
            TrayStatus.Attention=>Colors.Orange,
            _=>syncSnapshot==null&&bookmarks.Count==0?Colors.Gray:Colors.Green,
        };
        return new Microsoft.UI.Xaml.Shapes.Ellipse{Width=size,Height=size,Fill=new SolidColorBrush(color),VerticalAlignment=VerticalAlignment.Center};
    }

    private async Task DeleteBookmark(Bookmark b)
    {
        if(busy||!storageReady)return;var d=new ContentDialog{XamlRoot=root.XamlRoot,Title=$"Remove {b.nickname}?",Content="This removes the saved connection and its stored credentials. Files on the server are kept.",PrimaryButtonText="Remove",CloseButtonText="Cancel"};if(await ShowDialog(d)!=ContentDialogResult.Primary)return;
        await Run("Remove connection",async _=>{var next=bookmarks.Where(x=>x.id!=b.id).ToList();await CoreBridge.Save(next);bookmarks=next;CredentialStore.Delete(b.id);Render();},b);
    }
    private async Task EditBookmark(Bookmark? existing)
    {
        if(busy||!storageReady)return;
        modalDepth++;try{await ShowBookmarkEditor(existing);}catch(Exception e){Error(e);}finally{modalDepth--;SizeQuickMenu();}
    }
    private async Task ShowBookmarkEditor(Bookmark? existing)
    {
        var b=existing==null?new Bookmark():JsonSerializer.Deserialize<Bookmark>(JsonSerializer.Serialize(existing))!;
        var secrets=existing==null?new Credentials():CredentialStore.Read(b.id);
        var form=new StackPanel{Spacing=12,MinWidth=compact?280:420,MaxWidth=compact?320:480};
        var name=new TextBox{Header="Connection name",PlaceholderText="Studio files",Text=b.nickname};form.Children.Add(name);
        var protocols=new[]{"sftp","webdav","s3","smb","local"};var protocol=new ComboBox{Header="Connection type",ItemsSource=new[]{"SFTP · SSH file transfer","WebDAV · Nextcloud and servers","S3 · AWS, B2, Wasabi, MinIO","SMB · Network share","Local folder · Try myDrive"},SelectedIndex=Math.Max(0,Array.IndexOf(protocols,b.protocol)),HorizontalAlignment=HorizontalAlignment.Stretch};form.Children.Add(protocol);
        var host=new TextBox{Header="Server",Text=b.host};form.Children.Add(host);
        var pickFolder=Button("Choose folder…",()=>_=ChooseLocalFolder());form.Children.Add(pickFolder);
        async Task ChooseLocalFolder(){var picker=new FolderPicker();InitializeWithWindow.Initialize(picker,hwnd);picker.FileTypeFilter.Add("*");var picked=await Modal(async()=>await picker.PickSingleFolderAsync());if(picked!=null){host.Text=picked.Path;if(name.Text.Length==0)name.Text=picked.Name;}}
        var path=new TextBox{Header="Root path (optional)",Text=b.path};form.Children.Add(path);
        var user=new TextBox{Header="Username",Text=b.username};form.Children.Add(user);
        var password=new PasswordBox{Header="Password",Password=secrets.password};form.Children.Add(password);
        var port=new NumberBox{Header="Port (0 = default)",Value=b.port,Minimum=0,Maximum=65535,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Compact};form.Children.Add(port);
        var bucket=new TextBox{Header="Bucket",Text=b.options.GetValueOrDefault("bucket","")};form.Children.Add(bucket);
        var region=new TextBox{Header="Region",Text=b.options.GetValueOrDefault("region","us-east-1")};form.Children.Add(region);
        var key=new TextBox{Header="SSH private key file (optional)",Text=secrets.private_key,PlaceholderText=@"C:\Users\YourName\.ssh\id_ed25519"};form.Children.Add(key);
        var passphrase=new PasswordBox{Header="Key passphrase (optional)",Password=secrets.passphrase};form.Children.Add(passphrase);
        var token=new PasswordBox{Header="S3 session token (optional)",Password=secrets.session_token};form.Children.Add(token);
        var drive=new TextBox{Header="Drive letter (optional, e.g. M:)",Text=b.mount_path};form.Children.Add(drive);
        var hint=Text("",12);form.Children.Add(hint);
        void Update(){var p=protocols[protocol.SelectedIndex];bool sftp=p=="sftp",s3=p=="s3",local=p=="local",smb=p=="smb";host.Header=local?"Folder":smb?"Server name":"Server address";host.PlaceholderText=local?@"D:\Files":p=="webdav"?"https://cloud.example.com/remote.php/dav/files/you":s3?"https://s3.us-east-1.amazonaws.com":"server.example.com";path.Header=smb?"Share name / folder":"Root path (optional)";user.Header=s3?"Access key ID":"Username";password.Header=s3?"Secret access key":"Password";pickFolder.Visibility=local?Visibility.Visible:Visibility.Collapsed;user.Visibility=password.Visibility=local?Visibility.Collapsed:Visibility.Visible;port.Visibility=sftp||p=="webdav"||s3?Visibility.Visible:Visibility.Collapsed;bucket.Visibility=region.Visibility=token.Visibility=s3?Visibility.Visible:Visibility.Collapsed;key.Visibility=passphrase.Visibility=sftp?Visibility.Visible:Visibility.Collapsed;drive.Visibility=smb?Visibility.Visible:Visibility.Collapsed;hint.Text=sftp?"Trust the server first with OpenSSH (ssh username@host). Password, private key and SSH agent authentication are supported.":s3?"Use the bucket's region. Path-style S3 endpoints are supported; uploads are limited to 100 MiB in this preview.":local?"A local folder is a simple way to try browsing and transfers.":smb?"Use a server name without slashes, and enter the share name below. Existing Windows credentials are used when fields are empty.":"Use HTTPS. HTTP is intended for a trusted local test server.";}
        protocol.SelectionChanged+=(_,_)=>Update();Update();
        var validation=new InfoBar{IsClosable=false,Severity=InfoBarSeverity.Error};form.Children.Add(validation);
        var dialog=new ContentDialog{XamlRoot=root.XamlRoot,Title=existing==null?"Add connection":"Edit connection",Content=new ScrollViewer{Content=form,MaxHeight=compact?330:520},PrimaryButtonText="Save",SecondaryButtonText="Test",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Primary};
        bool testing=false;
        (Bookmark,Credentials) Values(){var p=protocols[protocol.SelectedIndex];b.nickname=name.Text.Trim();b.protocol=p;b.host=host.Text.Trim();b.path=path.Text.Trim();b.username=user.Text.Trim();b.port=(ushort)(double.IsNaN(port.Value)?0:port.Value);b.mount_path=p=="smb"?drive.Text.Trim().ToUpperInvariant():"";b.credentials_ref=$"myDrive/{b.id}";b.options["bucket"]=bucket.Text.Trim();b.options["region"]=region.Text.Trim();if(b.nickname.Length==0||b.host.Length==0)throw new IOException("Enter a connection name and server or folder.");if(p=="smb"&&(b.path.Length==0||b.host.Contains('/')||b.host.Contains('\\')))throw new IOException("Enter the server name without slashes and a share name.");if(b.mount_path.Length>0&&(b.mount_path.Length!=2||!char.IsAsciiLetter(b.mount_path[0])||b.mount_path[1]!=':'))throw new IOException("Use a drive letter such as M: or leave it empty.");return(b,new Credentials{password=password.Password,private_key=key.Text.Trim(),passphrase=passphrase.Password,session_token=token.Password});}
        dialog.SecondaryButtonClick+=async(_,args)=>{args.Cancel=true;if(testing)return;testing=true;dialog.IsPrimaryButtonEnabled=false;dialog.IsSecondaryButtonEnabled=false;validation.IsOpen=false;try{var (bookmark,credential)=Values();using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(30));var items=await CoreBridge.Call(new{action="test",bookmark,credentials=credential},timeout.Token);validation.Severity=InfoBarSeverity.Success;validation.Title="Connection successful";validation.Message=$"Found {items.GetArrayLength()} items.";validation.IsOpen=true;}catch(Exception e){validation.Severity=InfoBarSeverity.Error;validation.Title="Connection failed";validation.Message=e.Message;validation.IsOpen=true;}finally{testing=false;dialog.IsPrimaryButtonEnabled=true;dialog.IsSecondaryButtonEnabled=true;}};
        dialog.PrimaryButtonClick+=async(_,args)=>{var deferral=args.GetDeferral();try{var (bookmark,credential)=Values();var next=bookmarks.Where(x=>x.id!=b.id).Append(bookmark).ToList();var oldSecrets=CredentialStore.Read(b.id);CredentialStore.Save(b.id,b.username,credential);try{await CoreBridge.Save(next);}catch{if(existing==null)CredentialStore.Delete(b.id);else CredentialStore.Save(b.id,existing.username,oldSecrets);throw;}bookmarks=next;}catch(Exception e){args.Cancel=true;validation.Severity=InfoBarSeverity.Error;validation.Title="Could not save";validation.Message=e.Message;validation.IsOpen=true;}finally{deferral.Complete();}};
        await ShowDialog(dialog);Render();
    }
    private async Task<T> Modal<T>(Func<Task<T>> action, bool dismissMenu = false)
    {
        modalDepth++;
        nativePickerDepth++;
        SizeQuickMenu();
        try
        {
            var picking = action();
            if (dismissMenu && activeDialog == null && compact) AppWindow.Hide();
            return await picking;
        }
        finally { nativePickerDepth--; modalDepth--; SizeQuickMenu(); }
    }

    private async Task<ContentDialogResult> ShowDialog(ContentDialog dialog, bool dismissMenu = false)
    {
        modalDepth++;
        SizeQuickMenu();
        activeDialog = dialog;
        try
        {
            return dismissMenu && compact && !diagnosticMode
                ? await ShowDetachedDialog(dialog)
                : await dialog.ShowAsync();
        }
        finally { activeDialog = null; modalDepth--; SizeQuickMenu(); }
    }

    private async Task<ContentDialogResult> ShowDetachedDialog(ContentDialog dialog)
    {
        var host = new Grid { RequestedTheme = RequestedAppearance, Background = root.Background };
        var window = new Window { Title = "myDrive", Content = host };
        detachedDialog = window;
        var bounds = AppWindow.Size;
        var origin = AppWindow.Position;
        window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(origin.X, origin.Y, bounds.Width, bounds.Height));
        window.AppWindow.IsShownInSwitchers = false;
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(true, false);
            presenter.IsResizable = presenter.IsMinimizable = presenter.IsMaximizable = false;
        }
        var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        host.Loaded += (_, _) => ready.TrySetResult(true);
        bool showing = false;
        void ClosePicker(AppWindow _, AppWindowClosingEventArgs args)
        {
            args.Cancel = true;
            if (showing) dialog.Hide();
            else ready.TrySetResult(false);
        }
        window.AppWindow.Closing += ClosePicker;
        try
        {
            window.Activate();
            if (!await ready.Task) return ContentDialogResult.None;
            dialog.XamlRoot = host.XamlRoot;
            var result = dialog.ShowAsync();
            showing = true;
            AppWindow.Hide();
            return await result;
        }
        finally
        {
            window.AppWindow.Closing -= ClosePicker;
            detachedDialog = null;
            window.Close();
        }
    }
}
