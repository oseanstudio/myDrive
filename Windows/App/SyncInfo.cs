using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;
public sealed partial class MainWindow
{
    private string syncInfoFolderId="",syncInfoFolderLabel="",syncInfoAction="",syncInfoTitle="",syncInfoBack="sync",syncInfoFailure="";
    private JsonElement? syncInfoData;
    private bool syncInfoLoading;

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
    private void RenderSyncInfo()
    {
        var toolbar=new Grid{ColumnSpacing=4};toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});toolbar.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});toolbar.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        toolbar.Children.Add(QuickIcon("\uE72B","Back to Sync",BackFromSyncInfo));
        var title=QuickText(syncInfoTitle,13,true);title.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(title,1);toolbar.Children.Add(title);
        var refresh=QuickIcon("\uE72C","Refresh "+syncInfoTitle.ToLowerInvariant(),()=>_=LoadSyncInfo());refresh.IsEnabled=!syncInfoLoading&&!busy;Grid.SetColumn(refresh,2);toolbar.Children.Add(refresh);page.Children.Add(toolbar);
        var label=QuickText(syncInfoFolderLabel,11);ToolTipService.SetToolTip(label,syncInfoFolderLabel);page.Children.Add(label);
        if(syncInfoLoading){page.Children.Add(Text("Loading…",12));return;}
        if(syncInfoFailure.Length>0){page.Children.Add(Text(syncInfoFailure,12));return;}
        var count=0;
        void Row(string path,string detail)
        {
            count++;
            var row=new StackPanel{Spacing=2};var name=Path.GetFileName(path.TrimEnd('\\','/'));
            var file=QuickText(name.Length>0?name:path,12,true);ToolTipService.SetToolTip(file,path);row.Children.Add(file);
            var message=Text(detail,11);message.MaxLines=3;message.TextTrimming=TextTrimming.CharacterEllipsis;ToolTipService.SetToolTip(message,detail);row.Children.Add(message);
            if(detail.Length>140||detail.Contains('\n'))row.Children.Add(new Expander{Header="Details",Content=Text(path+"\n"+detail,11),HorizontalAlignment=HorizontalAlignment.Stretch});
            page.Children.Add(QuickRow(row));
        }
        if(syncInfoData is {} data)
        {
            if(syncInfoAction=="errors")foreach(var file in Items(data,"errors"))Row(S(file,"path",S(file,"file","File")),S(file,"error",S(file,"message","Please check this file.")));
            else foreach(var section in new[]{("progress","Downloading"),("queued","Queued"),("rest","Waiting")})foreach(var file in Items(data,section.Item1))Row(S(file,"name",S(file,"path","File")),section.Item2+" · "+Bytes(N(file,"size")));
        }
        if(count==0)page.Children.Add(Text(syncInfoAction=="errors"?"No file errors. Your folder is ready to sync.":"No pending files on this computer.",12));
        else if(syncInfoAction!="errors")page.Children.Add(Text("Showing up to 50 pending files. Sync resumes when another device is available.",11));
    }
}
