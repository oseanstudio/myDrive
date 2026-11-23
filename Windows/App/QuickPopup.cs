using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using System.Text.Json;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MyDrive;
public sealed partial class MainWindow
{
    private Button quickExpand = null!;

    private static TextBlock QuickText(string value,double size=12,bool strong=false)
    {
        var text=Text(value,size,strong);text.TextWrapping=TextWrapping.NoWrap;
        text.TextTrimming=TextTrimming.CharacterEllipsis;
        return text;
    }
    private static string CountLabel(long count,string singular)=>count.ToString("N0")+" "+singular+(count==1?"":"s");
    private static Button QuickButton(string label,Action action,bool accent=false)
    {
        var button=Button(label,action,accent);button.FontSize=12;button.MinWidth=0;
        button.MinHeight=28;button.Padding=new Thickness(7,2,7,2);return button;
    }
    private static Button QuickIcon(string glyph,string label,Action action)
    {
        var button=QuickButton("",action);button.Content=new FontIcon{Glyph=glyph,FontSize=12};
        button.Width=28;button.Height=28;button.Padding=new Thickness(0);
        ToolTipService.SetToolTip(button,label);AutomationProperties.SetName(button,label);return button;
    }
    private static void MenuAction(MenuFlyout menu,string title,Action action)
    {
        var item=new MenuFlyoutItem{Text=title};item.Click+=(_,_)=>action();menu.Items.Add(item);
    }
    private Border QuickRow(UIElement child)=>new(){Child=child,MinHeight=44,Padding=new Thickness(2,3,2,3),BorderBrush=Brush("DividerStrokeColorDefaultBrush"),BorderThickness=new Thickness(0,0,0,1)};
    private void BuildQuickHeader()
    {
        quickHeader.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});
        for(int i=0;i<4;i++)quickHeader.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        var identity = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        identity.Children.Add(QuickText("myDrive", 13, true));
        identity.Children.Add(new TextBlock { Text = DisplayVersion, FontSize = 10, Opacity = .73, VerticalAlignment = VerticalAlignment.Center });
        quickHeader.Children.Add(identity);
        var views=new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        foreach(var view in new[]{(SendViewName,"transfers"),("Sync","sync"),(StorageViewName,"connections"),("Activity","activity"),("Settings","settings")})
            MenuAction(views,view.Item1,()=>NavigateQuick(view.Item2));
        views.Items.Add(new MenuFlyoutSeparator());
        MenuAction(views,"Hide to tray",DismissQuickPopup);
        MenuAction(views,"Quit myDrive",Quit);
        quickViews.Flyout=views;AutomationProperties.SetName(quickViews,"Choose myDrive view");Grid.SetColumn(quickViews,1);quickHeader.Children.Add(quickViews);
        var add=QuickIcon("\uE710","Add folder or connection",()=>{});var addMenu=new MenuFlyout();
        MenuAction(addMenu,"Sync a folder…",()=>_=ShowQuickShare());
        MenuAction(addMenu,"Send with Blip…",()=>{NavigateQuick("transfers");if(blipSnapshot?.Status.Authenticated==true)_=ShowBlipSend();});
        MenuAction(addMenu,"Paste and send…",()=>_=PasteAndSendBlip());
        add.Flyout=addMenu;
        Grid.SetColumn(add,2);quickHeader.Children.Add(add);
        var paste=QuickIcon("\uE77F","Paste clipboard and send",()=>_=PasteAndSendBlip());Grid.SetColumn(paste,3);quickHeader.Children.Add(paste);
        quickExpand = QuickIcon("\uE740", "Open full window", () => SetMode(false));
        Grid.SetColumn(quickExpand, 4);
        quickHeader.Children.Add(quickExpand);
    }
    private void NavigateQuick(string view)
    {
        if(busy)return;currentView=view;
        navigation.SelectedItem=view=="settings"?navigation.SettingsItem:navigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i=>i.Tag?.ToString()==view);
        Render();if(!diagnosticMode&&view=="sync"&&Environment.TickCount64-lastSyncRefresh>=10_000)_=RefreshSyncthing();if(view=="transfers")_=RefreshBlip();
    }
    private void UpdateQuickChrome()
    {
        quickViews.Content=currentView switch{"sync" or "sync-files" or "sync-info" or "sync-attention"=>"Sync","transfers"=>SendViewName,"activity"=>"Activity","settings"=>"Settings",_=>StorageViewName};
        quickViews.IsEnabled=!busy;
        quickExpand.IsEnabled = !busy;
        if(statusFooter!=null){statusFooter.Visibility=compact&&!busy?Visibility.Collapsed:Visibility.Visible;if(statusFooter.Child is Grid footer)footer.Padding=compact?new Thickness(10,5,10,5):new Thickness(24,10,24,10);}
        status.MaxWidth=compact?190:double.PositiveInfinity;
        UpdateProblemColors();
    }
    private List<Peer> QuickPeers()=>syncSnapshot.HasValue?Items(syncSnapshot.Value,"devices")
        .Where(d=>!B(d,"is_local")).Select(d=>new Peer(S(d,"deviceID"),S(d,"name","Unnamed device"),d.TryGetProperty("connection",out var c)&&B(c,"connected")))
        .OrderByDescending(p=>p.Connected).ThenBy(p=>p.Name).ToList():new();
    private static JsonElement FolderStats(JsonElement folder)=>folder.TryGetProperty("status",out var stats)&&stats.ValueKind==JsonValueKind.Object?stats:folder;
    private static bool HasFolderError(JsonElement folder)=>S(folder,"error").Length>0||N(FolderStats(folder),"pullErrors")>0||N(FolderStats(folder),"errors")>0;
    private List<(string Id,string Name,string State)> FolderPeers(JsonElement folder)
    {
        var known=syncSnapshot.HasValue?Items(syncSnapshot.Value,"devices").GroupBy(d=>S(d,"deviceID")).ToDictionary(g=>g.Key,g=>g.First()):new Dictionary<string,JsonElement>();
        var result=new List<(string Id,string Name,string State)>();
        foreach(var id in Items(folder,"device_ids").Where(x=>x.ValueKind==JsonValueKind.String).Select(x=>x.GetString()!).Distinct()){
            if(known.TryGetValue(id,out var device)){
                if(B(device,"is_local"))continue;
                var name=S(device,"name");if(name.Length==0)name=id[..Math.Min(7,id.Length)];
                result.Add((id,name,B(device,"paused")?"Paused":device.TryGetProperty("connection",out var c)&&B(c,"connected")?"Connected":"Offline"));
            }else result.Add((id,id[..Math.Min(7,id.Length)],"Unavailable"));
        }
        return result.OrderBy(p=>p.Name,StringComparer.OrdinalIgnoreCase).ToList();
    }
    private static string QuickFolderState(JsonElement folder,List<Peer> peers)
    {
        if(B(folder,"paused"))return PausedFolderLabel(folder);
        if(HasFolderError(folder))return "Needs attention";
        var stats=FolderStats(folder);var state=S(stats,"state","Unknown");
        if(N(stats,"needFiles")>0)return $"{N(stats,"needFiles"):N0} files pending";
        if(state.Contains("scan"))return "Checking changes";
        if(state=="syncing")return "Syncing";
        if(state!="idle")return state;
        var members=folder.TryGetProperty("device_ids",out var ids)?ids.EnumerateArray().Select(v=>v.GetString()).ToHashSet():new HashSet<string?>();
        return peers.Any(p=>p.Connected&&members.Contains(p.Id))?"Local up to date":"Available offline";
    }
    private MenuFlyout SyncFolderMenu(JsonElement folder)
    {
        var menu=new MenuFlyout();var id=S(folder,"id");var label=S(folder,"label",id);
        var sharing=new MenuFlyoutSubItem{Text=S(folder,"type") switch{"sendonly"=>"Syncing to","receiveonly" or "receiveencrypted"=>"Syncing from",_=>"Syncing to & from"}};
        foreach(var peer in FolderPeers(folder)){var entry=new MenuFlyoutItem{Text=peer.Name+" · "+peer.State,IsEnabled=false};ToolTipService.SetToolTip(entry,peer.Id);sharing.Items.Add(entry);}
        if(sharing.Items.Count>0){menu.Items.Add(sharing);menu.Items.Add(new MenuFlyoutSeparator());}
        MenuAction(menu,"Choose files",()=>_=OpenSyncFolder(id,label,""));
        MenuAction(menu,"Open local folder",()=>OpenPath(S(folder,"path")));
        MenuAction(menu,"Device progress",()=>_=ShowSyncInfo(id,"device_progress","Device progress"));
        MenuAction(menu,"Pause until…",()=>_=ChooseSyncPause(folder));
        MenuAction(menu,"Pending files",()=>_=ShowSyncInfo(id,"need","Pending files"));
        MenuAction(menu,"Saved versions",()=>_=ShowSyncVersions(id,label));
        menu.Items.Add(new MenuFlyoutSeparator());
        MenuAction(menu,"Rescan",()=>_=SyncAction("scan",new{folder_id=id},"Rescan "+label));
        MenuAction(menu,"Show errors",()=>_=ShowSyncInfo(id,"errors","Folder errors"));
        MenuAction(menu,"Protect version history",()=>_=SyncAction("protect",new{folder_id=id},"Protect history for "+label));
        menu.Items.Add(new MenuFlyoutSeparator());
        MenuAction(menu,"Stop syncing folder…",()=>_=StopSyncFolder(id,label,S(folder,"path")));
        return menu;
    }
    private void RenderQuickSync()
    {
        if(syncSnapshot==null)
        {
            page.Children.Add(Text(syncFailure.Length>0?"Syncthing unavailable":"Connecting…",14,true));
            if(syncFailure.Length>0){var message=Text(syncFailure,12);page.Children.Add(message);}
            var actions=new StackPanel{Orientation=Orientation.Horizontal,Spacing=6};actions.Children.Add(QuickButton("Retry",()=>_=RefreshSyncthing()));actions.Children.Add(QuickButton("Connection…",()=>_=EditSyncthingConnection()));page.Children.Add(actions);return;
        }
        var (title,detail)=QuickSummary();
        var summary=new Grid{ColumnSpacing=5,Margin=new Thickness(2,2,2,4)};summary.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});summary.ColumnDefinitions.Add(new(){Width=GridLength.Auto});summary.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        var info=new StackPanel{Spacing=2};
        var titleRow=new StackPanel{Orientation=Orientation.Horizontal,Spacing=5};
        syncStatusDot=StatusDot();titleRow.Children.Add(syncStatusDot);
        syncTitleText=QuickText(title,13,true);titleRow.Children.Add(syncTitleText);
        syncAlertLink=SyncAttentionLink(title);titleRow.Children.Add(syncAlertLink);
        UpdateSyncSummaryTitle(title);
        info.Children.Add(titleRow);
        syncDetailText=QuickText(detail,11);info.Children.Add(syncDetailText);ToolTipService.SetToolTip(info,syncFailure.Length>0?syncFailure:detail);summary.Children.Add(info);
        var refresh=QuickIcon("\uE72C","Refresh sync status",()=>_=RefreshSyncthing());Grid.SetColumn(refresh,1);summary.Children.Add(refresh);
        var more=QuickIcon("\uE712","Sync tools",()=>{});var tools=new MenuFlyout();MenuAction(tools,"Devices…",()=>_=ShowQuickDevices());MenuAction(tools,"Sync a folder…",()=>_=ShowQuickShare());MenuAction(tools,"Open Syncthing",OpenSyncthing);MenuAction(tools,"Connection settings…",()=>_=EditSyncthingConnection());more.Flyout=tools;Grid.SetColumn(more,2);summary.Children.Add(more);
        UpdateFolderRows();
        if(folderRows.Count==0)
        {
            page.Children.Add(summary);
            page.Children.Add(QuickButton("Sync your first folder…",()=>_=ShowQuickShare(),true));
            return;
        }
        // The list owns scrolling and uses the rest of the popup below its summary.
        syncFolderList=VirtualRows(folderRows,FolderTemplate);
        Grid.SetRow(syncFolderList,1);
        quickSyncPane.Children.Add(summary);
        quickSyncPane.Children.Add(syncFolderList);
        pageScroll.Visibility=Visibility.Collapsed;
        quickSyncPane.Visibility=Visibility.Visible;
    }
    private (string Title,string Detail) QuickSummary()
    {
        var peers=QuickPeers();var folders=syncSnapshot is {} snapshot?Items(snapshot,"folders").ToList():new List<JsonElement>();var active=folders.Where(f=>!B(f,"paused")).ToList();
        var errors=active.Count(HasFolderError);var need=active.Sum(f=>N(FolderStats(f),"needFiles"));var paused=folders.Count-active.Count;
        var title=syncFailure.Length>0?"Status unavailable":errors>0?FolderAttentionTitle(errors):folders.Count>0&&active.Count==0?"Sync paused":need>0?CountLabel(need,"file")+" pending":peers.All(p=>!p.Connected)?"Working offline":active.Any(f=>S(FolderStats(f),"state").Contains("scan"))?"Checking changes…":active.Any(f=>S(FolderStats(f),"state")=="syncing")?"Syncing changes…":"Local files up to date";
        var detail=CountLabel(folders.Count,"folder")+" · "+CountLabel(peers.Count(p=>p.Connected),"device")+" online"+(paused>0?$" · {paused} paused":"");
        if (syncSnapshot is { } status && S(status, "scheduled_pause_error").Length > 0)
            detail += " · Check scheduled pauses";
        return (title,detail);
    }
    private bool RefreshQuickSyncControls()
    {
        if(syncSnapshot==null||syncTitleText==null||syncDetailText==null||syncFolderList==null)return false;
        if((folderRows.Count==0)!=(!Items(syncSnapshot.Value,"folders").Any()))return false;
        var (title,detail)=QuickSummary();UpdateSyncSummaryTitle(title);syncDetailText.Text=detail;
        ToolTipService.SetToolTip(syncDetailText,syncFailure.Length>0?syncFailure:detail);
        if(syncStatusDot!=null)syncStatusDot.Fill=StatusDot().Fill;
        UpdateFolderRows();return true;
    }

    private void UpdateSyncSummaryTitle(string title)
    {
        if (syncTitleText == null || syncAlertLink == null) return;
        bool actionable = syncFailure.Length == 0 && FoldersNeedingAttention().Any();
        syncTitleText.Text = title;
        syncTitleText.Visibility = actionable ? Visibility.Collapsed : Visibility.Visible;
        syncAlertLink.Content = title;
        syncAlertLink.Visibility = actionable ? Visibility.Visible : Visibility.Collapsed;
    }
    private async Task ShowQuickDevices()
    {
        if(busy||modalDepth>0)return;var content=new StackPanel{Spacing=10,MinWidth=260};
        foreach(var peer in QuickPeers()){var row=new StackPanel{Spacing=2};row.Children.Add(Text(peer.Name,14,true));row.Children.Add(Text(peer.Connected?"Connected":"Offline",12));content.Children.Add(row);}
        if(content.Children.Count==0)content.Children.Add(Text("No other devices configured."));
        await ShowDialog(new ContentDialog{XamlRoot=root.XamlRoot,Title="Devices",Content=new ScrollViewer{Content=content,MaxHeight=300},CloseButtonText="Close"});
    }
    private async Task ShareBrowsedSubfolder()
    {
        if(busy||syncPath.Length==0||syncSnapshot==null)return;
        try {
            var folder=Items(syncSnapshot.Value,"folders").FirstOrDefault(f=>S(f,"id")==syncFolderId);
            var rootPath=S(folder,"path");if(rootPath.Length==0)throw new IOException("Refresh the folder list before sharing this subfolder.");
            var root=Path.GetFullPath(rootPath).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
            var selected=Path.GetFullPath(Path.Combine(root,syncPath.Replace('/',Path.DirectorySeparatorChar)));
            if(!selected.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new IOException("Choose a subfolder inside the current sync folder.");
            await ShowQuickShare(selected);
        }catch(Exception e){Error(e);}
    }
    private async Task ShowQuickShare(string? selectedFolder=null)
    {
        if(busy||modalDepth>0)return;modalDepth++;SizeQuickMenu();
        try
        {
            if(syncSnapshot==null)await RefreshSyncthing();var peers=QuickPeers();
            var form=new StackPanel{Spacing=10,MinWidth=compact?0:280,MaxWidth=compact?260:double.PositiveInfinity};var path=new TextBox{Header="Folder",Text=selectedFolder??syncSharePath};form.Children.Add(path);
            var choose=new StackPanel{Orientation=Orientation.Horizontal,Spacing=6};choose.Children.Add(QuickButton("Choose…",async()=>{var picker=new FolderPicker();InitializeWithWindow.Initialize(picker,hwnd);picker.FileTypeFilter.Add("*");var selected=await Modal(async()=>await picker.PickSingleFolderAsync());if(selected!=null)path.Text=selected.Path;}));choose.Children.Add(QuickButton("This project",()=>path.Text=SyncthingService.ProjectFolder()));form.Children.Add(choose);
            var device=new ComboBox{Header="Device",ItemsSource=peers,HorizontalAlignment=HorizontalAlignment.Stretch};device.SelectedItem=peers.FirstOrDefault(p=>p.Id==syncShareDevice)??peers.FirstOrDefault(p=>p.Connected)??peers.FirstOrDefault();form.Children.Add(device);
            var skip=new CheckBox{Content="Skip build, SDK and cache folders",IsChecked=true};form.Children.Add(skip);form.Children.Add(Text("Subfolders can sync with different devices from their parent. New shares may need acceptance on the other device.",12));
            var dialog=new ContentDialog{XamlRoot=root.XamlRoot,Title="Sync a folder",Content=new ScrollViewer{Content=form,MaxHeight=310},PrimaryButtonText="Start syncing",IsPrimaryButtonEnabled=peers.Count>0,CloseButtonText="Cancel"};
            if(await ShowDialog(dialog)==ContentDialogResult.Primary&&device.SelectedItem is Peer peer){syncSharePath=path.Text;syncShareDevice=peer.Id;await ShareFolder(path.Text,peer.Id,skip.IsChecked==true);}
        }
        catch(Exception e){Error(e);}finally{modalDepth--;if(currentView=="sync")Render();else SizeQuickMenu();}
    }
    private void RenderQuickSyncFiles()
    {
        var toolbar=new Grid{ColumnSpacing=4};toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});toolbar.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        toolbar.Children.Add(QuickIcon("\uE72B","Back to synced folders",()=>NavigateQuick("sync")));
        var title=QuickText(syncPath.Length==0?syncFolderLabel:Path.GetFileName(syncPath),13,true);title.VerticalAlignment=VerticalAlignment.Center;ToolTipService.SetToolTip(title,syncFolderLabel+" /"+syncPath);Grid.SetColumn(title,1);toolbar.Children.Add(title);
        var up=QuickIcon("\uE74A","Parent folder",()=>_=OpenSyncFolder(syncFolderId,syncFolderLabel,syncPath.Contains('/')?syncPath[..syncPath.LastIndexOf('/')]:""));up.IsEnabled=syncPath.Length>0;Grid.SetColumn(up,2);toolbar.Children.Add(up);
        var refresh=QuickIcon("\uE72C","Refresh files",()=>_=OpenSyncFolder(syncFolderId,syncFolderLabel,syncPath));Grid.SetColumn(refresh,3);toolbar.Children.Add(refresh);page.Children.Add(toolbar);
        if(syncPath.Length>0)page.Children.Add(QuickButton("Sync this subfolder with another device…",()=>_=ShareBrowsedSubfolder()));
        if(syncBrowse==null)return;
        if(B(syncBrowse.Value,"local_limit_reached"))page.Children.Add(Text("Some local files are not shown. Open a smaller subfolder or use Explorer.",11));
        page.Children.Add(CreateSyncFileList());
        var footer=new StackPanel{Orientation=Orientation.Horizontal,Spacing=5};var alternatives=Items(syncBrowse.Value,"entries").Where(e=>S(e,"alternative_for").Length>0).ToList();
        if(alternatives.Count>0)footer.Children.Add(QuickButton($"Saved edits ({alternatives.Count})",()=>_=ShowQuickAlternatives(alternatives)));
        footer.Children.Add(QuickButton("Selection help",()=>_=ShowDialog(new ContentDialog{XamlRoot=root.XamlRoot,Title="File selection",Content=Text("Sync and Stop apply immediately on this computer, for all devices sharing this Syncthing folder. Stop keeps existing copies. A specific file selection overrides a containing folder. Default rules retain your existing Syncthing selection."),CloseButtonText="Close"})));page.Children.Add(footer);
    }
    private async Task ShowQuickAlternatives(List<JsonElement> alternatives)
    {
        if(busy||modalDepth>0)return;var content=new StackPanel{Spacing=8,MinWidth=260};
        foreach(var file in alternatives){var path=S(file,"path");var button=Button("Open saved edit of "+S(file,"alternative_for"),()=>_=OpenSyncedFile(path));button.Content=Text("Open saved edit of "+S(file,"alternative_for"),12);content.Children.Add(button);}
        await ShowDialog(new ContentDialog{XamlRoot=root.XamlRoot,Title="Saved alternative edits",Content=new ScrollViewer{Content=content,MaxHeight=300},CloseButtonText="Close"});
    }
    private void RenderQuickConnections()
    {
        if(bookmarks.Count(b=>b.protocol=="smb")>4||search.Length>0){var filter=new AutoSuggestBox{PlaceholderText="Find SMB shares",Text=search,FontSize=12};filter.TextChanged+=(_,_)=>{search=filter.Text;RenderConnectionList();};page.Children.Add(filter);}
        connectionsPanel=new StackPanel{Spacing=0};page.Children.Add(connectionsPanel);RenderConnectionList();
    }
    private void RenderQuickFiles()
    {
        if(currentBookmark==null)return;var bookmark=currentBookmark;
        var tools=new Grid{ColumnSpacing=3};tools.ColumnDefinitions.Add(new(){Width=GridLength.Auto});tools.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});for(int i=0;i<3;i++)tools.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        tools.Children.Add(QuickIcon("\uE72B","Back to storage",()=>NavigateQuick("connections")));
        var title=QuickText(currentPath.Length==0?bookmark.nickname:Path.GetFileName(currentPath),13,true);title.VerticalAlignment=VerticalAlignment.Center;ToolTipService.SetToolTip(title,bookmark.Location+" /"+currentPath);Grid.SetColumn(title,1);tools.Children.Add(title);
        var up=QuickIcon("\uE74A","Parent folder",()=>_=Browse(bookmark,currentPath.Contains('/')?currentPath[..currentPath.LastIndexOf('/')]:""));up.IsEnabled=currentPath.Length>0;Grid.SetColumn(up,2);tools.Children.Add(up);
        var refresh=QuickIcon("\uE72C","Refresh files",()=>_=Browse(bookmark,currentPath));Grid.SetColumn(refresh,3);tools.Children.Add(refresh);
        var more=QuickIcon("\uE712","File commands",()=>{});var commands=new MenuFlyout();MenuAction(commands,"Upload file…",()=>_=Upload());MenuAction(commands,"New folder…",()=>_=NewFolder());if(bookmark.protocol is "local" or "smb")MenuAction(commands,"Open in Explorer",()=>OpenExplorer(bookmark));more.Flyout=commands;Grid.SetColumn(more,4);tools.Children.Add(more);page.Children.Add(tools);
        filesList=new ListView{SelectionMode=ListViewSelectionMode.Single,IsItemClickEnabled=true,MaxHeight=Math.Max(80,QuickHeight()-100),HorizontalAlignment=HorizontalAlignment.Stretch};
        filesList.ItemContainerStyle=new Style(typeof(ListViewItem));filesList.ItemContainerStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty,HorizontalAlignment.Stretch));filesList.ItemContainerStyle.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(4,0,4,0)));filesList.ItemContainerStyle.Setters.Add(new Setter(FrameworkElement.MinHeightProperty,38d));
        foreach(var file in currentFiles)
        {
            var row=new Grid{ColumnSpacing=5,Tag=file};row.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            var name=QuickText((file.is_dir?"▰ ":"")+file.name,12);name.VerticalAlignment=VerticalAlignment.Center;ToolTipService.SetToolTip(name,file.name+"\n"+file.Modified);row.Children.Add(name);
            var size=QuickText(file.is_dir?"":file.Size,10);size.VerticalAlignment=VerticalAlignment.Center;size.Foreground=Brush("TextFillColorSecondaryBrush");Grid.SetColumn(size,1);row.Children.Add(size);
            void Select()=>filesList.SelectedItem=row;
            var actions=QuickIcon("\uE712","Actions for "+file.name,()=>{});var menu=new MenuFlyout();MenuAction(menu,"Open",()=>{Select();if(file.is_dir)_=Browse(bookmark,file.path);else _=Download(file,true);});if(!file.is_dir)MenuAction(menu,"Download…",()=>{Select();_=Download(file,false);});MenuAction(menu,"Rename…",()=>{Select();_=Rename();});MenuAction(menu,"Delete…",()=>{Select();_=DeleteFile();});actions.Flyout=menu;Grid.SetColumn(actions,2);row.Children.Add(actions);filesList.Items.Add(row);
        }
        filesList.ItemClick+=(_,args)=>{if(busy)return;if(args.ClickedItem is Grid row&&row.Tag is RemoteFile file){if(file.is_dir)_=Browse(bookmark,file.path);else _=Download(file,true);}};
        page.Children.Add(filesList);if(currentFiles.Count==0)page.Children.Add(Text("This folder is empty.",12));
    }
    private void RenderQuickConnectionList()
    {
        if(connectionsPanel==null)return;connectionsPanel.Children.Clear();
        foreach(var b in bookmarks.Where(b=>b.protocol=="smb" && (b.nickname+" "+b.host).Contains(search,StringComparison.OrdinalIgnoreCase)))
        {
            var row=new Grid{ColumnSpacing=4};row.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            var details=new StackPanel{Spacing=1};details.Children.Add(QuickText(b.nickname,13,true));details.Children.Add(CreateSmbHealthLabel(b,11));
            var open=QuickButton("",()=>_=Browse(b));open.Content=details;open.HorizontalAlignment=HorizontalAlignment.Stretch;open.HorizontalContentAlignment=HorizontalAlignment.Stretch;open.Padding=new Thickness(3,1,3,1);open.Background=new SolidColorBrush(Colors.Transparent);open.BorderThickness=new Thickness(0);ToolTipService.SetToolTip(open,b.Location);AutomationProperties.SetName(open,"Browse "+b.nickname);row.Children.Add(open);
            var more=QuickIcon("\uE712","Actions for "+b.nickname,()=>{});var menu=new MenuFlyout();MenuAction(menu,"Open in Explorer",()=>OpenExplorer(b));MenuAction(menu,"Remove saved share",()=>_=DeleteBookmark(b));more.Flyout=menu;Grid.SetColumn(more,1);row.Children.Add(more);connectionsPanel.Children.Add(QuickRow(row));
        }
        if(connectionsPanel.Children.Count==0)connectionsPanel.Children.Add(Text(search.Length==0?"No saved SMB shares.":"No matching SMB shares.",12));
    }
}
