using System.Text.Json;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace MyDrive;
public sealed partial class MainWindow
{
    public async Task DiagnoseSyncViewport(string report)
    {
        object result;
        try
        {
            currentView="sync";
            syncSnapshot=JsonSerializer.SerializeToElement(new
            {
                folders=Enumerable.Range(0,20).Select(i=>new
                {
                    id=$"viewport-{i}",label=$"Folder {i:00}",path=Path.GetDirectoryName(report),
                    type="sendreceive",status=new{state="idle",pullErrors=1,localFiles=40}
                }).ToArray()
            });
            SetMode(true);
            await Task.Delay(400);
            root.UpdateLayout();
            if(quickViews.Flyout is not Microsoft.UI.Xaml.Controls.MenuFlyout viewMenu||
                viewMenu.Items.FirstOrDefault() is not Microsoft.UI.Xaml.Controls.MenuFlyoutItem { Text: "Send" })
                throw new IOException("The view picker must start with Send.");
            if (viewMenu.Placement != Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight)
                throw new IOException("The view picker must open below the header button.");
            var list=syncFolderList??throw new IOException("The compact Sync list did not load.");
            double top=list.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0,0)).Y;
            double gap=root.ActualHeight-top-list.ActualHeight;
            if(pageScroll.Visibility!=Microsoft.UI.Xaml.Visibility.Collapsed||list.ActualHeight<200||Math.Abs(gap)>2)
                throw new IOException($"The Sync list does not reach the bottom of the popup (gap {gap:F1}, list height {list.ActualHeight:F1}).");
            var last=list.Items[^1];
            list.ScrollIntoView(last);
            await Task.Delay(250);
            root.UpdateLayout();
            if(list.ContainerFromItem(last) is not Microsoft.UI.Xaml.FrameworkElement row)
                throw new IOException("The last folder became unreachable.");
            double rowTop=row.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0,0)).Y;
            if(rowTop<top-2||rowTop+row.ActualHeight>root.ActualHeight+2)
                throw new IOException("The last folder did not scroll fully into view.");
            result=new{ok=true,bottom_gap=gap,viewport_height=list.ActualHeight};
        }
        catch(Exception error){result=new{ok=false,error=error.ToString()};}
        try{await File.WriteAllTextAsync(report,JsonSerializer.Serialize(result));}
        finally{Quit();}
    }

    // Development-only command line: --diagnose <output-directory>.
    // Renders this app's own XAML surface; it never captures other windows.
    public async Task Diagnose(string directory)
    {
        diagnosticMode=true;syncTimer.Stop();healthTimer.Stop();
        var report=new Dictionary<string,object>();
        try
        {
            Directory.CreateDirectory(directory);await Task.Delay(1200);
            var id="diagnostic-"+Guid.NewGuid().ToString("N");
            try{CredentialStore.Save(id,"fixture",new(){password="local-fixture-only"});if(CredentialStore.Read(id).password!="local-fixture-only")throw new IOException("Credential roundtrip failed");report["credential_manager"]="pass";}finally{CredentialStore.Delete(id);}
            var temporary=Path.Combine(directory,"fixture");Directory.CreateDirectory(temporary);await File.WriteAllTextAsync(Path.Combine(temporary,"Welcome.txt"),"myDrive local test file");Directory.CreateDirectory(Path.Combine(temporary,"Projects"));
            var b=new Bookmark{nickname="Studio files",protocol="local",host=temporary};
            var stored=Path.Combine(directory,"store");await CoreBridge.Call(new{action="bookmarks.save",data_dir=stored,bookmarks=new[]{b}});var loaded=await CoreBridge.Call(new{action="bookmarks.load",data_dir=stored});if(loaded.GetArrayLength()!=1)throw new IOException("Bookmark roundtrip failed");report["bookmarks"]="pass";
            var listing=await CoreBridge.List(b,"");if(listing.Count!=2)throw new IOException("Core list failed");report["core_bridge"]="pass";
            bookmarks=new(){b};storageReady=true;
            currentView="connections";
            SetMode(false);await Task.Delay(500);await Capture(directory,"full-window.png");report["full_window_size"]=new[]{root.ActualWidth,root.ActualHeight};
            SetMode(true);await Task.Delay(500);await Capture(directory,"quick-menu.png");report["quick_menu_size"]=new[]{root.ActualWidth,root.ActualHeight};
            // Place our own window away from the tray. The old redraw path
            // would move it back to the icon/cursor on every interaction.
            var workArea=Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id,Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).WorkArea;
            quickOrigin=new(workArea.X+24,workArea.Y+24);AppWindow.Move(quickOrigin.Value);await Task.Delay(150);
            var stablePosition=AppWindow.Position;var stableSize=AppWindow.Size;
            void CheckStable(string stage){if(AppWindow.Position.X!=stablePosition.X||AppWindow.Position.Y!=stablePosition.Y||AppWindow.Size.Width!=stableSize.Width||AppWindow.Size.Height!=stableSize.Height)throw new IOException("Popup moved or resized during "+stage);}
            Render();await Task.Delay(150);CheckStable("redraw");SetMode(true);CheckStable("repeated activation");
            currentBookmark=b;currentPath="";currentFiles=listing;currentView="files";Render();await Task.Delay(500);await Capture(directory,"quick-files.png");
            CheckStable("file navigation");
            report["file_rows"]=filesList?.Items.Count??0;
            var editing=EditBookmark(b);await Task.Delay(500);
            if(activeDialog==null||activeDialog.ActualWidth<=0)throw new IOException("The popup connection editor did not load");
            report["editor_size"]=new[]{activeDialog.ActualWidth,activeDialog.ActualHeight};
            CheckStable("opening the editor");
            await Capture(directory,"quick-editor.png",activeDialog);activeDialog.Hide();await editing;
            await Task.Delay(300);if(root.ActualWidth>350||root.ActualHeight>420)throw new IOException("Closing the editor did not restore the small popup.");report["editor_returns_to_small_popup"]="pass";
            CheckStable("closing the editor");report["popup_position_and_size_stable"]="pass";
            try{
                var live=await SyncthingService.Call("snapshot");report["syncthing_live"]=new{version=S(live,"version"),folders=Items(live,"folders").Count(),connected_devices=Items(live,"devices").Count(d=>d.TryGetProperty("connection",out var c)&&B(c,"connected"))};
                async Task<double> Measure(bool invalidate){var samples=new List<double>();for(int i=0;i<10;i++){if(invalidate)SyncthingService.Invalidate();var watch=System.Diagnostics.Stopwatch.StartNew();await SyncthingService.Call("snapshot");watch.Stop();if(i>=2)samples.Add(watch.Elapsed.TotalMilliseconds);}samples.Sort();return Math.Round((samples[3]+samples[4])/2,1);}
                report["status_latency_ms"]=new{samples_per_mode=8,engine_check_each_call=await Measure(true),cached_connection=await Measure(false)};
            }catch(Exception e){report["syncthing_live"]=e.Message;}
            if(tray!=null){foreach(var level in new[]{TrayStatus.Normal,TrayStatus.Attention,TrayStatus.Problem,TrayStatus.Normal}){tray.SetStatus(level);if(tray.HasBadge!=(level!=TrayStatus.Normal))throw new IOException("Native tray status badge creation failed.");}report["native_tray_icon"]=new{asset=tray.AssetName,pixels=tray.PixelSize,status_badges="pass"};}
            syncSnapshot=JsonSerializer.SerializeToElement(new{version="v2.1",devices=new[]{new{deviceID="diagnostic-peer",name="Studio laptop",is_local=false,connection=new{connected=true}}},folders=new[]{new{id="diagnostic-folder",label="Studio project",path=temporary,type="sendreceive",paused=false,device_ids=new[]{"diagnostic-peer"},status=new{state="idle",localFiles=2,localBytes=48,needFiles=0}}}});
            currentView="sync";Render();await Task.Delay(400);await Capture(directory,"quick-sync.png");report["quick_sync_one_folder_size"]=new[]{root.ActualWidth,root.ActualHeight};
            var samplePeers=new[]{new{deviceID="diagnostic-peer",name="Studio laptop",is_local=false,connection=new{connected=true}}};
            var sampleFolders=Enumerable.Range(0,11).Select(i=>new{id="diagnostic-"+i,label=i==0?"myDrive":i==1?"An unusually long project folder name for overflow checking":"Studio folder "+i,path=i==0?SyncthingService.ProjectFolder():temporary,type="sendreceive",paused=i==3,device_ids=new[]{"diagnostic-peer"},status=new{state=i==2?"syncing":"idle",localFiles=48+i,localBytes=12000,needFiles=i==2?18:0,pullErrors=i==4?1:0}}).ToArray();
            syncSnapshot=JsonSerializer.SerializeToElement(new{version="v2.1",devices=samplePeers,folders=sampleFolders});Render();await Task.Delay(400);await Capture(directory,"quick-sync-many.png");report["quick_sync_many_size"]=new[]{root.ActualWidth,root.ActualHeight};
            var visibleRows=0;
            if(syncFolderList!=null){var viewport=syncFolderList.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0,0));for(int i=0;i<syncFolderList.Items.Count;i++)if(syncFolderList.ContainerFromIndex(i) is Microsoft.UI.Xaml.FrameworkElement row){var origin=row.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0,0));if(origin.Y>=viewport.Y&&origin.Y+row.ActualHeight<=Math.Min(root.ActualHeight,viewport.Y+syncFolderList.ActualHeight))visibleRows++;}}
            report["visible_sync_folder_rows"]=visibleRows;
            var retainedList=syncFolderList;var retainedContainer=syncFolderList?.ContainerFromIndex(0);
            if(!RefreshQuickSyncControls()||!ReferenceEquals(retainedList,syncFolderList)||!ReferenceEquals(retainedContainer,syncFolderList?.ContainerFromIndex(0)))throw new IOException("A status-only refresh rebuilt stable folder controls.");
            report["status_refresh_preserves_controls"]="pass";
            if(root.ActualWidth>350||root.ActualHeight>420||visibleRows<5)throw new IOException("The dense popup did not fit five complete folder rows within its size budget.");
            var oldTheme=colorTheme;colorTheme=Microsoft.UI.Xaml.ElementTheme.Dark;root.RequestedTheme=colorTheme;root.Background=Brush("ApplicationPageBackgroundThemeBrush");Render();await Task.Delay(300);await Capture(directory,"quick-sync-dark.png");colorTheme=oldTheme;root.RequestedTheme=colorTheme;root.Background=Brush("ApplicationPageBackgroundThemeBrush");Render();
            var sharing=ShowQuickShare();await Task.Delay(400);if(activeDialog==null)throw new IOException("The compact share dialog did not open");await Capture(directory,"quick-share.png",activeDialog);activeDialog.Hide();await sharing;
            CheckStable("refresh, themes and sharing dialog");
            var stopPrompt=StopSyncFolder("diagnostic-folder","Studio project",temporary);await Task.Delay(350);if(activeDialog==null||activeDialog.PrimaryButtonText!="Stop syncing")throw new IOException("Stop syncing confirmation did not open");CheckStable("stop syncing confirmation");await Capture(directory,"quick-stop-folder.png",activeDialog);activeDialog.Hide();await stopPrompt;report["stop_folder_cancel_keeps_configuration"]="pass";
            syncSnapshot=JsonSerializer.SerializeToElement(new{version="v2.1",devices=new[]{new{deviceID="diagnostic-peer",name="Studio laptop",is_local=false,connection=new{connected=false}}},folders=new[]{new{id="offline-fixture",label="Offline project",path=temporary,type="sendreceive",paused=false,device_ids=new[]{"diagnostic-peer"},status=new{state="idle",localFiles=2,localBytes=48,needFiles=0}}}});Render();await Task.Delay(250);await Capture(directory,"quick-sync-offline.png");
            syncSnapshot=JsonSerializer.SerializeToElement(new{version="v2.1",devices=samplePeers,folders=new[]{new{id="paused-fixture",label="Paused project",path=temporary,type="sendreceive",paused=true,device_ids=new[]{"diagnostic-peer"},status=new{state="idle",localFiles=2,localBytes=48,needFiles=0}}}});Render();await Task.Delay(250);await Capture(directory,"quick-sync-paused.png");
            SetMode(false);await Task.Delay(400);await Capture(directory,"full-sync.png");SetMode(true);
            syncFolderId="diagnostic-folder";syncFolderLabel="Studio project";syncPath="";syncRules=new();syncBrowse=JsonSerializer.SerializeToElement(new{entries=new object[]{new{name="Projects",path="Projects",is_dir=true,size=0},new{name="Welcome.txt",path="Welcome.txt",is_dir=false,size=23},new{name="Welcome.sync-conflict-20261113-120000-TEST.txt",path="Welcome.sync-conflict-20261113-120000-TEST.txt",is_dir=false,size=31,alternative_for="Welcome.txt"}}});currentView="sync-files";Render();await Task.Delay(400);await Capture(directory,"quick-sync-files.png");
            syncBrowse=JsonSerializer.SerializeToElement(new{entries=Enumerable.Range(0,10000).Select(i=>new{name="File "+i,path="File "+i,is_dir=false,size=23}).ToArray()});Render();await Task.Delay(500);
            var realized=0;if(syncFileList!=null)for(int i=0;i<syncFileList.Items.Count;i++)if(syncFileList.ContainerFromIndex(i)!=null)realized++;
            if(syncFileList?.Items.Count!=10000||realized>=100)throw new IOException("The sync file browser did not virtualize its 10,000-row fixture.");
            report["large_sync_browser"]=new{items=10000,realized};await Capture(directory,"quick-sync-10000-files.png");
            syncSnapshot=JsonSerializer.SerializeToElement(new{devices=samplePeers,folders=new[]{new{id=syncFolderId,path=temporary}}});
            syncPath="Projects";syncBrowse=JsonSerializer.SerializeToElement(new{entries=Array.Empty<object>()});Render();await Task.Delay(150);
            stablePosition=AppWindow.Position;stableSize=AppWindow.Size;
            await Capture(directory,"quick-subfolder.png");
            var childSharing=ShareBrowsedSubfolder();await Task.Delay(350);
            if(activeDialog==null)throw new IOException("The subfolder sharing dialog did not open");
            var shareForm=(Microsoft.UI.Xaml.Controls.StackPanel)((Microsoft.UI.Xaml.Controls.ScrollViewer)activeDialog.Content).Content;
            var childPath=shareForm.Children.OfType<Microsoft.UI.Xaml.Controls.TextBox>().Single();
            if(childPath.Text!=Path.Combine(temporary,"Projects"))throw new IOException("Subfolder share selected the wrong root");
            CheckStable("subfolder share");await Capture(directory,"quick-subfolder-share.png",activeDialog);activeDialog.Hide();await childSharing;
            report["subfolder_share_prefills_only_selected_child"]="pass";
            var openingSmb=OpenSmbShare();await Task.Delay(500);if(activeDialog==null)throw new IOException("The SMB quick connection dialog did not load");await Capture(directory,"quick-smb.png",activeDialog);activeDialog.Hide();await openingSmb;
            if(root.ActualWidth<300||root.ActualWidth>460)throw new IOException("Quick menu width is outside expected bounds");
            var outside=new Windows.Graphics.PointInt32(-32000,-32000);
            SetMode(true);if(!popupInput.IsWatching)throw new IOException("The popup's native outside-click monitor is not installed.");
            var inside=new Windows.Graphics.PointInt32(AppWindow.Position.X+24,AppWindow.Position.Y+60);
            DismissAt(inside,true);if(!AppWindow.IsVisible)throw new IOException("An inside click closed the popup.");
            nativePickerDepth++;try{DismissAt(outside,true);if(!AppWindow.IsVisible)throw new IOException("The popup closed during a native picker.");}finally{nativePickerDepth--;}
            var testCancellation=new CancellationTokenSource();operation=testCancellation;busy=true;
            try{DismissAt(outside,true);if(AppWindow.IsVisible||testCancellation.IsCancellationRequested)throw new IOException("Outside-click dismissal did not hide the busy popup while preserving the operation.");}finally{busy=false;operation=null;testCancellation.Dispose();}
            await Task.Delay(100);if(popupInput.IsWatching)throw new IOException("The outside-click monitor remained installed while hidden.");
            SetMode(true);if(!AppWindow.IsVisible||!popupInput.IsWatching)throw new IOException("The popup did not reopen with outside-click monitoring.");
            var dismissing=ShowDialog(new Microsoft.UI.Xaml.Controls.ContentDialog{XamlRoot=root.XamlRoot,Title="Cancel fixture",Content="No changes are made.",PrimaryButtonText="Do not accept",CloseButtonText="Cancel"});
            await Task.Delay(200);DismissAt(outside,true);if(await dismissing!=Microsoft.UI.Xaml.Controls.ContentDialogResult.None||AppWindow.IsVisible)throw new IOException("An outside click did not cancel the embedded confirmation.");
            SetMode(false);DismissAt(outside,true);if(!AppWindow.IsVisible||popupInput.IsWatching)throw new IOException("Full window inherited compact-popup dismissal.");
            report["popup_outside_click"]="pass: inside retained; busy hidden without cancellation; picker retained; embedded confirmation cancelled; reopen works; full window retained";
            SetMode(true);currentView="sync";Render();stablePosition=AppWindow.Position;stableSize=AppWindow.Size;
            syncInfoBack="sync";syncInfoTitle="Folder errors";syncInfoFolderLabel="Studio project";syncInfoAction="errors";
            syncInfoFailure="";syncInfoLoading=false;
            syncInfoData=JsonSerializer.SerializeToElement(new{errors=new[]{new{path="Projects/a very long folder name/Project notes.txt",error="This file is in use. Close the app using it, then refresh."},new{path="Projects/second-file.txt",error="The folder is unavailable. Reconnect its drive, then refresh."}}});
            currentView="sync-info";Render();await Task.Delay(250);
            if(activeDialog!=null||modalDepth!=0||quickViews.Content?.ToString()!="Sync")throw new IOException("Folder errors opened a dialog or lost the Sync header.");
            CheckStable("in-place errors view");await Capture(directory,"quick-errors.png");
            var detailTheme=colorTheme;colorTheme=Microsoft.UI.Xaml.ElementTheme.Dark;root.RequestedTheme=colorTheme;root.Background=Brush("ApplicationPageBackgroundThemeBrush");Render();await Task.Delay(150);await Capture(directory,"quick-errors-dark.png");colorTheme=detailTheme;root.RequestedTheme=colorTheme;root.Background=Brush("ApplicationPageBackgroundThemeBrush");
            syncInfoData=JsonSerializer.SerializeToElement(new{errors=Array.Empty<object>()});Render();await Task.Delay(150);await Capture(directory,"quick-errors-empty.png");CheckStable("empty errors view");
            syncInfoFailure="Status could not load. Refresh to try again.";Render();await Task.Delay(150);await Capture(directory,"quick-errors-unavailable.png");syncInfoFailure="";
            SetMode(false);await Task.Delay(150);await Capture(directory,"full-errors.png");SetMode(true);
            BackFromSyncInfo();if(currentView!="sync"||activeDialog!=null)throw new IOException("Errors Back did not return to Sync.");
            NavigateQuick("connections");
            if(quickViews.Content?.ToString()!="SMB Drives"||navigation.MenuItems.OfType<Microsoft.UI.Xaml.Controls.NavigationViewItem>().First(i=>i.Tag?.ToString()=="connections").Content?.ToString()!="SMB Drives")throw new IOException("SMB Drives navigation labels are inconsistent.");
            var viewMenu=quickViews.Flyout as Microsoft.UI.Xaml.Controls.MenuFlyout;
            if(viewMenu==null||!viewMenu.Items.OfType<Microsoft.UI.Xaml.Controls.MenuFlyoutItem>().Any(i=>i.Text=="SMB Drives")||viewMenu.Items.OfType<Microsoft.UI.Xaml.Controls.MenuFlyoutItem>().Any(i=>i.Text is "Storage" or "Connections"))throw new IOException("The view menu uses an inconsistent SMB Drives name.");
            await Task.Delay(150);await Capture(directory,"quick-storage.png");
            report["in_place_folder_details"]="pass: same popup/header; stable bounds; back to Sync; light/dark; empty/error states; full-window parity";
            report["storage_navigation_labels"]="pass: menu, compact header and full-window navigation agree";
            report["result"]="pass";
        }
        catch(Exception e){report["result"]="fail";report["error"]=e.ToString();}
        finally{await File.WriteAllTextAsync(Path.Combine(directory,"report.json"),JsonSerializer.Serialize(report,new JsonSerializerOptions{WriteIndented=true}));diagnosticMode=false;Quit();}
    }
    private async Task Capture(string directory,string name,Microsoft.UI.Xaml.UIElement? element=null)
    {
        var bitmap=new RenderTargetBitmap();await bitmap.RenderAsync(element??root);var pixelBuffer=await bitmap.GetPixelsAsync();var data=new byte[pixelBuffer.Length];using(var reader=DataReader.FromBuffer(pixelBuffer)){reader.ReadBytes(data);}
        var folder=await StorageFolder.GetFolderFromPathAsync(Path.GetFullPath(directory));var file=await folder.CreateFileAsync(name,CreationCollisionOption.ReplaceExisting);using var stream=await file.OpenAsync(FileAccessMode.ReadWrite);
        var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,stream);encoder.SetPixelData(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,(uint)bitmap.PixelWidth,(uint)bitmap.PixelHeight,96,96,data);await encoder.FlushAsync();
    }
}
