using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MyDrive;
public sealed partial class MainWindow
{
    private string syncInfoFolderId="",syncInfoFolderLabel="",syncInfoAction="",syncInfoTitle="",syncInfoBack="sync",syncInfoFailure="";
    private JsonElement? syncInfoData;
    private bool syncInfoLoading;
    private JsonElement? syncAttentionData;
    private bool syncAttentionLoading;
    private string syncAttentionFailure = "";

    private IEnumerable<JsonElement> FoldersNeedingAttention() => syncSnapshot is { } snapshot
        ? Items(snapshot, "folders").Where(folder => !B(folder, "paused") && HasFolderError(folder))
            .OrderBy(folder => S(folder, "label", S(folder, "id")), StringComparer.CurrentCultureIgnoreCase)
        : [];

    private static string FolderAttentionTitle(int count) =>
        CountLabel(count, "folder") + (count == 1 ? " needs attention" : " need attention");

    private HyperlinkButton SyncAttentionLink(string title)
    {
        var link = new HyperlinkButton { Content = title, FontSize = 13, Padding = new Thickness(0), MinHeight = 24 };
        ToolTipService.SetToolTip(link, "Open sync errors and fixes");
        link.Click += (_, _) => _ = OpenSyncAttention();
        return link;
    }

    private async Task OpenSyncAttention()
    {
        if (busy || modalDepth > 0) return;
        currentView = "sync-attention";
        await LoadSyncAttention();
    }

    private async Task LoadSyncAttention(bool refresh = false)
    {
        if (busy || syncAttentionLoading) return;
        syncAttentionLoading = true;
        syncAttentionFailure = "";
        Render();
        try
        {
            if (refresh) await RefreshSyncthing();
            var ids = FoldersNeedingAttention().Select(folder => S(folder, "id")).ToArray();
            if (ids.Length == 0) { syncAttentionData = null; return; }
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(35));
            syncAttentionData = await SyncthingService.Call("attention", new { folder_ids = ids }, timeout.Token);
        }
        catch (Exception error)
        {
            syncAttentionFailure = error is OperationCanceledException ? "Loading timed out. Use Refresh to try again." : error.Message;
        }
        finally
        {
            syncAttentionLoading = false;
            if (!quitting && currentView == "sync-attention") Render();
        }
    }

    private async Task RescanFromErrors(string id, string label)
    {
        if (busy || modalDepth > 0 || id.Length == 0) return;
        bool requested = false;
        await Run("Rescan " + label, async token =>
        {
            await SyncthingService.Call("scan", new { folder_id = id }, token);
            requested = true;
            await RefreshSyncthing();
        });
        if (!requested) return;
        if (currentView == "sync-attention") await LoadSyncAttention();
        else if (currentView == "sync-info" && syncInfoFolderId == id) await LoadSyncInfo();
    }

    private async Task ChooseMovedSyncFolder(JsonElement folder)
    {
        if (busy || modalDepth > 0) return;
        var id = S(folder, "id");
        var oldPath = S(folder, "path");
        var picker = new FolderPicker { CommitButtonText = "Use this location" };
        InitializeWithWindow.Initialize(picker, hwnd);
        picker.FileTypeFilter.Add("*");
        var selected = await Modal(async () => await picker.PickSingleFolderAsync());
        if (selected is null) return;
        bool relocated = false;
        await Run("Update sync location", async token =>
        {
            await SyncthingService.Call("relocate", new { folder_id = id, expected_path = oldPath, local_path = selected.Path }, token);
            relocated = true;
            if (currentView == "sync-info" && syncInfoFolderId == id) currentView = syncInfoBack;
            await RefreshSyncthing();
        });
        if (!relocated) return;
        if (currentView == "sync-attention") await LoadSyncAttention();
        else Render();
    }

    private void RenderSyncAttention()
    {
        RenderSyncInfoHeader("Sync errors", () => NavigateQuick("sync"), () => _ = LoadSyncAttention(true), syncAttentionLoading);
        if (syncAttentionLoading) { page.Children.Add(Text("Loading folder errors…", 12)); return; }
        var failure = syncAttentionFailure.Length > 0 ? syncAttentionFailure : syncFailure;
        if (failure.Length > 0) page.Children.Add(Text(failure, 12));
        var folders = FoldersNeedingAttention().ToArray();
        if (folders.Length == 0 && failure.Length == 0) page.Children.Add(Text("No folders need attention.", 12));
        foreach (var folder in folders)
        {
            var id = S(folder, "id");
            var name = S(folder, "label");
            if (name.Length == 0) name = id;
            var content = new StackPanel { Spacing = 4 };
            var title = QuickText(name, 13, true);
            ToolTipService.SetToolTip(title, name);
            content.Children.Add(title);
            var message = S(folder, "error");
            var advice = S(folder, "error_advice");
            if (syncAttentionData is { } report && report.TryGetProperty(id, out var result))
            {
                var issue = Items(result, "errors").FirstOrDefault();
                if (issue.ValueKind == JsonValueKind.Object)
                {
                    var path = S(issue, "path");
                    if (path.Length > 0)
                    {
                        var pathLabel = QuickText(path, 11);
                        ToolTipService.SetToolTip(pathLabel, path);
                        content.Children.Add(pathLabel);
                    }
                    message = S(issue, "error", S(issue, "message", message));
                    advice = S(issue, "advice", advice);
                }
                else if (message.Length == 0) message = S(result, "failure");
            }
            var details = Text(message.Length > 0 ? message : "Syncthing reported a sync problem.", 11);
            details.MaxLines = 3;
            details.TextTrimming = TextTrimming.CharacterEllipsis;
            ToolTipService.SetToolTip(details, details.Text);
            content.Children.Add(details);
            if (advice.Length > 0) content.Children.Add(Text(advice, 11));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            if (S(folder, "path").Length > 0) actions.Children.Add(QuickButton("Choose new location…", () => _ = ChooseMovedSyncFolder(folder)));
            actions.Children.Add(QuickButton("Rescan", () => _ = RescanFromErrors(id, name)));
            actions.Children.Add(QuickButton("View errors", () => _ = ShowSyncInfo(id, "errors", "Folder errors")));
            content.Children.Add(actions);
            page.Children.Add(QuickRow(content));
        }
    }

    private async Task ShowSyncInfo(string id,string action,string title)
    {
        if(busy||modalDepth>0)return;
        syncInfoBack=currentView=="sync-info"?syncInfoBack:currentView;
        syncInfoFolderId=id;syncInfoAction=action;syncInfoTitle=title;syncInfoData=null;
        var folder=syncSnapshot.HasValue?Items(syncSnapshot.Value,"folders").FirstOrDefault(f=>S(f,"id")==id):default;
        syncInfoFolderLabel=folder.ValueKind==JsonValueKind.Object?S(folder,"label",id):id;
        currentView="sync-info";
        await LoadSyncInfo();
    }

    private async Task LoadSyncInfo()
    {
        if(busy)return;
        syncInfoLoading=true;syncInfoFailure="";Render();
        await Run("Load "+syncInfoTitle.ToLowerInvariant(),async token=>{
            try{
                using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(20));
                syncInfoData=await SyncthingService.Call(syncInfoAction,new{folder_id=syncInfoFolderId},timeout.Token);
            }
            catch(Exception e){syncInfoFailure=e is OperationCanceledException?"Loading stopped. Refresh to try again.":e.Message;throw;}
            finally{syncInfoLoading=false;if(currentView=="sync-info"&&AppWindow.IsVisible)Render();}
        });
        if(currentView=="sync-info"&&AppWindow.IsVisible)Render();
    }

    private void BackFromSyncInfo(){currentView=syncInfoBack;Render();}
    private void RenderSyncInfoHeader(string title, Action back, Action refresh, bool loading)
    {
        var toolbar=new Grid{ColumnSpacing=4};toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});toolbar.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        toolbar.Children.Add(QuickIcon("\uE72B","Back",back));
        var text=QuickText(title,13,true);text.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(text,1);toolbar.Children.Add(text);
        var button=QuickIcon("\uE72C","Refresh "+title.ToLowerInvariant(),refresh);button.IsEnabled=!loading&&!busy;Grid.SetColumn(button,2);toolbar.Children.Add(button);page.Children.Add(toolbar);
    }

    private void RenderSyncInfo()
    {
        RenderSyncInfoHeader(syncInfoTitle, BackFromSyncInfo, () => _ = LoadSyncInfo(), syncInfoLoading);
        var label=QuickText(syncInfoFolderLabel,11);ToolTipService.SetToolTip(label,syncInfoFolderLabel);page.Children.Add(label);
        var currentFolder=syncSnapshot is {} snapshot?Items(snapshot,"folders").FirstOrDefault(f=>S(f,"id")==syncInfoFolderId):default;
        if(syncInfoAction=="errors" && syncInfoFolderId.Length>0)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            if (currentFolder.ValueKind == JsonValueKind.Object && S(currentFolder, "path").Length > 0)
                actions.Children.Add(QuickButton("Choose new location…", () => _ = ChooseMovedSyncFolder(currentFolder)));
            actions.Children.Add(QuickButton("Rescan folder",()=>_=RescanFromErrors(syncInfoFolderId,syncInfoFolderLabel)));
            foreach (var button in actions.Children.OfType<Button>()) button.IsEnabled = !syncInfoLoading && !busy;
            page.Children.Add(actions);
        }
        if(syncInfoLoading){page.Children.Add(Text("Loading…",12));return;}
        if(syncInfoFailure.Length>0){page.Children.Add(Text(syncInfoFailure,12));return;}
        var count=0;
        void Row(string path,string detail,string advice="")
        {
            count++;
            var row=new StackPanel{Spacing=2};var name=Path.GetFileName(path.TrimEnd('\\','/'));
            var file=QuickText(name.Length>0?name:path,12,true);ToolTipService.SetToolTip(file,path);row.Children.Add(file);
            var message=Text(detail,11);message.MaxLines=3;message.TextTrimming=TextTrimming.CharacterEllipsis;ToolTipService.SetToolTip(message,detail);row.Children.Add(message);
            if(advice.Length>0)row.Children.Add(Text(advice,11));
            if(detail.Length>140||detail.Contains('\n'))row.Children.Add(new Expander{Header="Details",Content=Text(path+"\n"+detail,11),HorizontalAlignment=HorizontalAlignment.Stretch});
            page.Children.Add(QuickRow(row));
        }
        if(syncInfoData is {} data)
        {
            if(syncInfoAction=="errors")foreach(var file in data.ValueKind==JsonValueKind.Array?data.EnumerateArray().ToArray():Items(data,"errors"))Row(S(file,"path",S(file,"file","File")),S(file,"error",S(file,"message","Please check this file.")),S(file,"advice"));
            else foreach(var section in new[]{("progress","Downloading"),("queued","Queued"),("rest","Waiting")})foreach(var file in Items(data,section.Item1))Row(S(file,"name",S(file,"path","File")),section.Item2+" · "+Bytes(N(file,"size")));
        }
        if(count==0)
        {
            var message=currentFolder.ValueKind==JsonValueKind.Object?S(currentFolder,"error"):"";
            page.Children.Add(Text(syncInfoAction=="errors"?(message.Length>0?message:"No file errors."):"No pending files on this computer.",12));
        }
        else if(syncInfoAction!="errors")page.Children.Add(Text("Showing up to 50 pending files. Sync resumes when another device is available.",11));
    }
}
