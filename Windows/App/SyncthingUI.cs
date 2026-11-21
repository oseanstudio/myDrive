using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using System.Diagnostics;
using System.Text.Json;
using Windows.Storage.Pickers;
using WinRT.Interop;
namespace MyDrive;
public sealed partial class MainWindow
{
    private JsonElement? syncSnapshot,syncBrowse;
    private string syncFailure="",syncFolderId="",syncFolderLabel="",syncPath="";
    private bool syncRefreshing;
    private string syncRenderedSignature="";
    private string SyncSignature()=>JsonSerializer.Serialize(new{syncFailure,version=syncSnapshot.HasValue?S(syncSnapshot.Value,"version"):"",folders=syncSnapshot.HasValue?Items(syncSnapshot.Value,"folders").ToArray():Array.Empty<JsonElement>(),devices=syncSnapshot.HasValue?Items(syncSnapshot.Value,"devices").Select(d=>new{id=S(d,"deviceID"),name=S(d,"name"),local=B(d,"is_local"),paused=B(d,"paused"),connected=d.TryGetProperty("connection",out var c)&&B(c,"connected")}).ToArray():null});
    private readonly DispatcherTimer syncTimer=new(){Interval=TimeSpan.FromSeconds(20)};
    private long lastSyncRefresh = -120_000;
    private string syncSharePath=Preferences.Current.LastSyncFolder.Length>0?Preferences.Current.LastSyncFolder:SyncthingService.ProjectFolder();
    private string syncShareDevice=Preferences.Current.LastSyncDevice;
    private List<SyncRule> syncRules=new();
    private List<string> syncExpectedIgnore=new();
    private sealed record Peer(string Id,string Name,bool Connected){public override string ToString()=>Name+(Connected?" · Connected":" · Offline");}
    public sealed class SyncRule {public string path {get;set;}="";public bool sync {get;set;}public bool is_dir {get;set;}}
    private static string S(JsonElement e,string key,string fallback="")=>e.TryGetProperty(key,out var v)&&v.ValueKind==JsonValueKind.String?v.GetString()??fallback:fallback;
    private static bool B(JsonElement e,string key)=>e.TryGetProperty(key,out var v)&&v.ValueKind==JsonValueKind.True;
    private static long N(JsonElement e,string key)=>e.TryGetProperty(key,out var v)&&v.ValueKind==JsonValueKind.Number&&v.TryGetInt64(out var n)?n:0;
    private static IEnumerable<JsonElement> Items(JsonElement e,string key)=>e.TryGetProperty(key,out var v)&&v.ValueKind==JsonValueKind.Array?v.EnumerateArray().ToArray():[];
    private static string Bytes(long count)=>count<1024?$"{count} B":count<1048576?$"{count/1024d:0.#} KB":count<1073741824?$"{count/1048576d:0.#} MB":$"{count/1073741824d:0.##} GB";
    private void StartSyncthingRefresh(){
        syncTimer.Tick+=async(_,_)=>{
            var visible=currentView=="sync" && AppWindow.IsVisible &&
                AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized };
            var interval=visible ? 20_000 : 120_000;
            if(!diagnosticMode&&!busy&&modalDepth==0&&Environment.TickCount64-lastSyncRefresh>=interval)
                await RefreshSyncthing();
        };syncTimer.Start();
        Closed+=(_,_)=>syncTimer.Stop();
    }
    private async Task RefreshSyncthing()
    {
        if(syncRefreshing)return;syncRefreshing=true;lastSyncRefresh=Environment.TickCount64;
        try{using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(180));syncSnapshot=await SyncthingService.Call("snapshot",token:timeout.Token);syncFailure="";}
        catch(Exception e){syncFailure=e is OperationCanceledException?"Syncthing's status took too long to load. Try Refresh after its current scan.":e.Message;}
        finally{syncRefreshing=false;UpdateProblemColors();if(currentView=="sync"&&modalDepth==0&&AppWindow.IsVisible){if(compact&&RefreshQuickSyncControls())syncRenderedSignature=SyncSignature();else if(syncRenderedSignature!=SyncSignature())Render();}}
    }
    private void RenderSyncthing()
    {
        syncRenderedSignature=SyncSignature();
        if(compact){RenderQuickSync();return;}
        if(compact)page.Children.Add(Text("Sync",23,true));else Heading("Sync with your devices","Your existing Syncthing, with simple folder and file controls.");
        if(syncSnapshot==null)
        {
            var setup=new StackPanel{Spacing=12};setup.Children.Add(Text(syncFailure.Length>0?"Connect to Syncthing":"Connecting to Syncthing…",18,true));setup.Children.Add(Text(syncFailure.Length>0?syncFailure:"Starting the background sync engine. First-time setup may download Syncthing."));setup.Children.Add(Button("Refresh",()=>_=RefreshSyncthing(),true));setup.Children.Add(Button("Connection settings",()=>_=EditSyncthingConnection()));page.Children.Add(Card(setup));return;
        }
        var snapshot=syncSnapshot.Value;
        var issueCount = FoldersNeedingAttention().Count();
        if (syncFailure.Length == 0 && issueCount > 0) page.Children.Add(SyncAttentionLink(FolderAttentionTitle(issueCount)));
        var peers=Items(snapshot,"devices").Where(d=>!B(d,"is_local")).Select(d=>new Peer(S(d,"deviceID"),S(d,"name","Unnamed device"),d.TryGetProperty("connection",out var c)&&B(c,"connected"))).OrderByDescending(p=>p.Connected).ThenBy(p=>p.Name).ToList();
        var share=new StackPanel{Spacing=10};share.Children.Add(Text("Sync a folder",18,true));
        var pathBox=new TextBox{Header=compact?null:"Folder",Text=syncSharePath,PlaceholderText="Choose a local folder"};pathBox.TextChanged+=(_,_)=>syncSharePath=pathBox.Text;ToolTipService.SetToolTip(pathBox,"Folder to sync");
        share.Children.Add(pathBox);
        var choose=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};choose.Children.Add(Button(compact?"Choose…":"Choose folder…",async()=>{if(busy)return;var picker=new FolderPicker();InitializeWithWindow.Initialize(picker,hwnd);picker.FileTypeFilter.Add("*");var folder=await Modal(async()=>await picker.PickSingleFolderAsync());if(folder!=null){syncSharePath=folder.Path;pathBox.Text=folder.Path;}}));choose.Children.Add(Button(compact?"Project":"This project",()=>{syncSharePath=SyncthingService.ProjectFolder();pathBox.Text=syncSharePath;}));if(!compact)share.Children.Add(choose);
        var device=new ComboBox{Header=compact?null:"Sync with",PlaceholderText="Choose a connected device",ItemsSource=peers,HorizontalAlignment=HorizontalAlignment.Stretch};ToolTipService.SetToolTip(device,"Sync with this device");device.SelectedItem=peers.FirstOrDefault(p=>p.Id==syncShareDevice)??peers.FirstOrDefault(p=>p.Connected)??peers.FirstOrDefault();device.SelectionChanged+=(_,_)=>syncShareDevice=(device.SelectedItem as Peer)?.Id??"";if(device.SelectedItem is Peer selected)syncShareDevice=selected.Id;share.Children.Add(device);
        var skipBuild=new CheckBox{Content="Skip build, SDK and cache folders",IsChecked=true};ToolTipService.SetToolTip(skipBuild,"For a new sync folder: skips .tools, build, Core/target, node_modules, bin, obj and __pycache__. Existing folder rules are preserved.");if(!compact)share.Children.Add(skipBuild);
        var start=Button("Start syncing",()=>_=ShareFolder(pathBox.Text,(device.SelectedItem as Peer)?.Id??"",skipBuild.IsChecked==true),true);start.IsEnabled=peers.Count>0;if(compact){choose.Children.Insert(0,start);share.Children.Add(choose);}else share.Children.Add(start);
        if(!compact)share.Children.Add(Text("A new share may need acceptance on the other device. Existing files are kept when you pause or exclude them.",12));page.Children.Add(Card(share));
        var tools=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};tools.Children.Add(Button("Refresh",()=>_=RefreshSyncthing()));tools.Children.Add(Button("Open Syncthing",OpenSyncthing));tools.Children.Add(Button("SMB share…",()=>_=OpenSmbShare()));page.Children.Add(tools);
        if(syncFailure.Length>0)page.Children.Add(Text("Last refresh failed: "+syncFailure,12));
        var folders=Items(snapshot,"folders").ToList();page.Children.Add(Text($"Synced folders · {folders.Count}",18,true));
        foreach(var folder in folders)
        {
            var id=S(folder,"id");var label=S(folder,"label",id);var card=new StackPanel{Spacing=8};card.Children.Add(Text(label,16,true));var location=Text(S(folder,"path"),12);location.TextTrimming=TextTrimming.CharacterEllipsis;location.MaxLines=2;card.Children.Add(location);
            var paused=B(folder,"paused");var state=folder.TryGetProperty("status",out var statusData)?S(statusData,"state","Unknown"):S(folder,"error","Unavailable");
            var members=folder.TryGetProperty("device_ids",out var ids)?ids.EnumerateArray().Select(v=>v.GetString()).ToHashSet():new HashSet<string?>();var online=peers.Any(p=>p.Connected&&members.Contains(p.Id));card.Children.Add(Text(paused?"Paused":state=="idle"?(online?"Local files up to date":"Available offline · waiting for a device"):state=="syncing"?"Syncing changes…":state.Contains("scan")?"Checking for changes…":state,13,true));
            if(folder.TryGetProperty("status",out statusData)){card.Children.Add(Text($"{N(statusData,"localFiles"):N0} files on this computer · {Bytes(N(statusData,"localBytes"))}"+(N(statusData,"needFiles")>0?$"\n{N(statusData,"needFiles"):N0} files / {Bytes(N(statusData,"needBytes"))} remaining":""),12));if(N(statusData,"pullErrors")>0)card.Children.Add(Text($"{N(statusData,"pullErrors")} file errors need attention",12,true));}
            var actions=new StackPanel{Orientation=Orientation.Horizontal,Spacing=7};actions.Children.Add(Button("Choose files",()=>_=OpenSyncFolder(id,label,""),true));actions.Children.Add(Button(paused?"Resume":"Pause",()=>_=PauseSyncFolder(id,!paused,label)));
            var more=new Button{Content="···"};var flyout=new MenuFlyout();void Menu(string text,Action action){var item=new MenuFlyoutItem{Text=text};item.Click+=(_,_)=>action();flyout.Items.Add(item);}
            Menu("Rescan",()=>_=SyncAction("scan",new{folder_id=id},"Rescan "+label));Menu("Show errors",()=>_=ShowSyncInfo(id,"errors","Folder errors"));Menu("Pending files",()=>_=ShowSyncInfo(id,"need","Pending files"));Menu("Saved versions",()=>_=ShowSyncVersions(id,label));Menu("Protect version history",()=>_=SyncAction("protect",new{folder_id=id},"Protect history for "+label));Menu("Open local folder",()=>OpenPath(S(folder,"path")));flyout.Items.Add(new MenuFlyoutSeparator());Menu("Stop syncing folder…",()=>_=StopSyncFolder(id,label,S(folder,"path")));more.Flyout=flyout;actions.Children.Add(more);card.Children.Add(actions);page.Children.Add(Card(card));
        }
        var deviceCard=new StackPanel{Spacing=8};deviceCard.Children.Add(Text("Your devices",18,true));foreach(var peer in peers)deviceCard.Children.Add(Text((peer.Connected?"●  ":"○  ")+peer.Name+(peer.Connected?" · Connected":" · Offline"),13));deviceCard.Children.Add(Text("Syncthing "+S(snapshot,"version")+" · Status refreshes while this view is open",12));page.Children.Add(Card(deviceCard));
        if(compact)page.Children.Add(new Expander{Header="Sharing options",Content=skipBuild,HorizontalAlignment=HorizontalAlignment.Stretch});
    }
    private async Task ShareFolder(string folder,string device,bool skipBuild)
    {
        if(busy)return;
        await Run("Start syncing folder",async token=>{
            var result=await SyncthingService.Call("share",new{local_path=folder,device_id=device,skip_build=skipBuild},token);
            Preferences.Current.LastSyncFolder=folder;Preferences.Current.LastSyncDevice=device;Preferences.Save();
            Info("Folder offered to "+S(result,"device_name","your device"),(B(result,"nested")?"Only this folder was offered; the overlapping folders' devices and selections stay unchanged. ":"")+"If this is a new share, accept it in Syncthing on the other device.");
            await RefreshSyncthing();
        });
    }
    private async Task SyncAction(string action,object payload,string label){await Run(label,async token=>{await SyncthingService.Call(action,payload,token);await RefreshSyncthing();});}
    private Task PauseSyncFolder(string id,bool paused,string label)=>SyncAction("pause",new{folder_id=id,paused},(paused?"Pause ":"Resume ")+label);
    private async Task StopSyncFolder(string id,string label,string expectedPath)
    {
        if(busy||modalDepth>0)return;
        var dialog=new ContentDialog{XamlRoot=root.XamlRoot,Title="Stop syncing "+label+"?",Content=Text("This removes the folder from this computer's sync list. Existing files and saved versions stay on this computer and other devices. You can add the folder again later."),PrimaryButtonText="Stop syncing",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close};
        if(await ShowDialog(dialog)!=ContentDialogResult.Primary)return;
        await Run("Stop syncing "+label,async token=>{await SyncthingService.Call("stop",new{folder_id=id,expected_path=expectedPath},token);if(syncFolderId==id){syncBrowse=null;syncFolderId="";syncRules.Clear();syncExpectedIgnore.Clear();}currentView="sync";await RefreshSyncthing();Info("Folder sync stopped","Existing files were kept on every device. Add the folder again whenever you want to resume syncing.");});
    }
    private async Task OpenSyncFolder(string id,string label,string path)
    {
        if(busy)return;
        await Run("Load synced files",async token=>{syncBrowse=await SyncthingService.Call("browse",new{folder_id=id,path},token);syncFolderId=id;syncFolderLabel=label;syncPath=path;syncRules=syncBrowse.Value.GetProperty("rules").Deserialize<List<SyncRule>>()??new();syncExpectedIgnore=syncBrowse.Value.GetProperty("ignore").Deserialize<List<string>>()??new();currentView="sync-files";Render();});
    }
    private void RenderSyncFiles()
    {
        if(compact){RenderQuickSyncFiles();return;}
        Heading(syncFolderLabel,"Choose files and folders to sync on this computer.");
        var top=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};top.Children.Add(Button("← Folders",()=>{if(busy)return;currentView="sync";Render();}));top.Children.Add(Button("↑ Up",()=>_=OpenSyncFolder(syncFolderId,syncFolderLabel,syncPath.Contains('/')?syncPath[..syncPath.LastIndexOf('/')]:"")));top.Children.Add(Button("Refresh",()=>_=OpenSyncFolder(syncFolderId,syncFolderLabel,syncPath)));page.Children.Add(top);
        page.Children.Add(Text("/"+syncPath,13,true));
        if(syncPath.Length>0)page.Children.Add(Button("Sync this subfolder with another device…",()=>_=ShareBrowsedSubfolder()));
        if(syncBrowse==null)return;
        if(B(syncBrowse.Value,"local_limit_reached"))page.Children.Add(Text("Some local files are not shown. Open a smaller subfolder or use Explorer.",12));
        page.Children.Add(CreateSyncFileList());
        var alternatives=Items(syncBrowse.Value,"entries").Where(e=>S(e,"alternative_for").Length>0).ToList();if(alternatives.Count>0){var saved=new StackPanel{Spacing=8};foreach(var version in alternatives){var path=S(version,"path");saved.Children.Add(Button("Open saved edit of "+S(version,"alternative_for"),()=>_=OpenSyncedFile(path)));}page.Children.Add(new Expander{Header=$"Saved alternative edits · {alternatives.Count}",Content=saved,HorizontalAlignment=HorizontalAlignment.Stretch});}
        page.Children.Add(Text("Sync and Stop apply immediately. Stopping keeps existing copies and stops future syncing on this computer. More specific file selections override a containing folder. These local selections affect all devices sharing this Syncthing folder.",12));
    }
    private async Task OpenSyncedFile(string path)=>await Run("Open synced file",async token=>{var result=await SyncthingService.Call("local_file",new{folder_id=syncFolderId,path},token);if(B(result,"pending")){Info("File queued","This file has been moved to the front of Syncthing's download queue. It will be available when a device with the file is connected.");return;}Process.Start(new ProcessStartInfo(S(result,"path")){UseShellExecute=true});});
    private async Task ShowSyncVersions(string id,string label)
    {
        if(busy||modalDepth>0)return;modalDepth++;SizeQuickMenu();
        try{
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(25));var versions=await SyncthingService.Call("versions",new{folder_id=id},timeout.Token);
            var content=new StackPanel{Spacing=10,MinWidth=compact?280:430};content.Children.Add(Text("Restoring replaces the current file and syncs that change to other devices. myDrive backs up the current local file before restoring. History here covers changes received from other devices.",12));
            int count=0;bool restoring=false;
            if(versions.ValueKind==JsonValueKind.Object)foreach(var file in versions.EnumerateObject())foreach(var version in file.Value.EnumerateArray()){
                if(count>=200)continue;count++;var path=file.Name;var time=S(version,"versionTime");var block=new StackPanel{Spacing=5};block.Children.Add(Text(path,14,true));block.Children.Add(Text((DateTimeOffset.TryParse(time,out var date)?date.LocalDateTime.ToString("MMM d, yyyy HH:mm:ss"):time)+" · "+Bytes(N(version,"size")),12));var result=Text("",12);
                var restore=Button("Restore this version",async()=>{if(restoring)return;restoring=true;try{using var restoreTimeout=new CancellationTokenSource(TimeSpan.FromSeconds(45));result.Text="Saving a backup and restoring…";var restored=await SyncthingService.Call("restore",new{folder_id=id,path,version_time=time},restoreTimeout.Token);var backup=S(restored,"backup");result.Text=backup.Length>0?"Restored. Your previous local copy was also saved.":"Restored.";if(backup.Length>0)block.Children.Add(Button("Open previous local copy",()=>{try{Process.Start(new ProcessStartInfo(backup){UseShellExecute=true});}catch(Exception e){Error(e);}}));await Record(new(DateTimeOffset.Now,"Restore saved version",label,path,true));}catch(Exception e){result.Text=e is OperationCanceledException?"Restoration timed out; refresh to check its result.":e.Message;}finally{restoring=false;}});block.Children.Add(restore);block.Children.Add(result);content.Children.Add(Card(block));
            }
            if(count==0)content.Children.Add(Text("No saved versions yet. Use Protect version history in the folder menu to preserve received changes. History is configured separately on each computer."));
            await ShowDialog(new ContentDialog{XamlRoot=root.XamlRoot,Title="Saved versions · "+label,Content=new ScrollViewer{Content=content,MaxHeight=compact?330:520},CloseButtonText="Close"});
        }catch(Exception e){Error(e);}finally{modalDepth--;SizeQuickMenu();}
    }
    private async Task SetSyncPath(string path,bool isDir,bool enabled)
    {
        if(busy)return;var next=syncRules.Where(r=>!r.path.Equals(path,StringComparison.OrdinalIgnoreCase)).Append(new SyncRule{path=path,sync=enabled,is_dir=isDir}).ToList();
        await Run((enabled?"Start syncing ":"Stop syncing ")+Path.GetFileName(path),async token=>{await SyncthingService.Call("selection.apply",new{folder_id=syncFolderId,expected_ignore=syncExpectedIgnore,rules=next},token);syncBrowse=await SyncthingService.Call("browse",new{folder_id=syncFolderId,path=syncPath},token);syncExpectedIgnore=syncBrowse.Value.GetProperty("ignore").Deserialize<List<string>>()??new();syncRules=syncBrowse.Value.GetProperty("rules").Deserialize<List<SyncRule>>()??new();Render();});
    }
    private void OpenSyncthing(){try{Process.Start(new ProcessStartInfo(SyncthingService.Discover().endpoint){UseShellExecute=true});}catch(Exception e){Error(e);}}
    private void OpenPath(string path){try{Process.Start(new ProcessStartInfo("explorer.exe"){UseShellExecute=true,ArgumentList={path}});}catch(Exception e){Error(e);}}
    private async Task EditSyncthingConnection()
    {
        if(busy)return;var panel=new StackPanel{Spacing=12,MinWidth=compact?280:420};panel.Children.Add(Text("myDrive reuses your existing Syncthing configuration and starts its engine without the Syncthing GUI. If missing, the engine is installed automatically. Manual connections use only the address you enter."));
        var path=new TextBox{Header="Syncthing config.xml",Text=SyncthingService.FindConfig()};panel.Children.Add(path);
        panel.Children.Add(Button("Choose config.xml…",async()=>{var picker=new FileOpenPicker();InitializeWithWindow.Initialize(picker,hwnd);picker.FileTypeFilter.Add(".xml");var file=await Modal(async()=>await picker.PickSingleFileAsync());if(file!=null)path.Text=file.Path;}));
        var manual=new CheckBox{Content="Use a manually entered local API address",IsChecked=Preferences.Current.SyncthingManual};panel.Children.Add(manual);
        var endpoint=new TextBox{Header="Local API address",Text=Preferences.Current.SyncthingEndpoint.Length>0?Preferences.Current.SyncthingEndpoint:"http://127.0.0.1:8384"};panel.Children.Add(endpoint);var apiKey=new PasswordBox{Header="API key (manual connection only)"};panel.Children.Add(apiKey);
        var dialog=new ContentDialog{XamlRoot=root.XamlRoot,Title="Syncthing connection",Content=new ScrollViewer{Content=panel,MaxHeight=compact?330:520},PrimaryButtonText="Connect",CloseButtonText="Cancel"};
        if(await ShowDialog(dialog)!=ContentDialogResult.Primary)return;
        try{Preferences.Current.SyncthingConfigPath=path.Text.Trim();Preferences.Current.SyncthingManual=manual.IsChecked==true;Preferences.Current.SyncthingEndpoint=endpoint.Text.Trim();if(manual.IsChecked==true&&apiKey.Password.Length>0)CredentialStore.Save("syncthing-local-api","Syncthing",new(){password=apiKey.Password});Preferences.Save();SyncthingService.Invalidate();syncSnapshot=null;syncFailure="";currentView="sync";Render();await RefreshSyncthing();}catch(Exception e){Error(e);}
    }
}
