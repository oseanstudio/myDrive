using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json;
using System.Windows.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;

namespace MyDrive;
public sealed partial class MainWindow
{
    // Row models survive status updates; XAML creates controls only for the viewport.
    private sealed class RowCommand(Action action):ICommand
    {
        public bool CanExecute(object? value)=>true;
        public void Execute(object? value)=>action();
        public event EventHandler? CanExecuteChanged {add{} remove{}}
    }
    [Microsoft.UI.Xaml.Data.Bindable]
    public sealed class SyncRow:INotifyPropertyChanged
    {
        public string Id {get;init;}="";
        public JsonElement Data;
        public string Label {get;private set;}="";
        public string Detail {get;private set;}="";
        public string PeerDetail {get;private set;}="";
        public string Hint {get;private set;}="";
        public string PauseGlyph {get;private set;}="";
        public string PauseLabel {get;private set;}="";
        public string OpenLabel=>"Open "+Label+"; "+Detail+(PeerDetail.Length==0?"":"; "+PeerDetail);
        public string SyncLabel=>"Sync "+Label;
        public string StopLabel=>"Stop syncing "+Label+"; keep copies";
        public ICommand Open {get;init;}=null!;
        public ICommand Pause {get;init;}=null!;
        public ICommand Enable {get;init;}=null!;
        public ICommand Stop {get;init;}=null!;
        public MenuFlyout? Menu {get;set;}
        public event PropertyChangedEventHandler? PropertyChanged;
        public void Update(JsonElement data,string label,string detail,string hint,string pauseGlyph="",string pauseLabel="",string peerDetail="")
        {
            Data=data;
            if((Label,Detail,Hint,PauseGlyph,PauseLabel,PeerDetail)==(label,detail,hint,pauseGlyph,pauseLabel,peerDetail))return;
            (Label,Detail,Hint,PauseGlyph,PauseLabel,PeerDetail)=(label,detail,hint,pauseGlyph,pauseLabel,peerDetail);
            PropertyChanged?.Invoke(this,new PropertyChangedEventArgs(null));
        }
    }
    private readonly ObservableCollection<SyncRow> folderRows=new();
    private ListView? syncFolderList,syncFileList;
    private TextBlock? syncTitleText,syncDetailText;
    private Microsoft.UI.Xaml.Shapes.Ellipse? syncStatusDot;
    private void ResetSyncControls(){syncFolderList=null;syncFileList=null;syncTitleText=null;syncDetailText=null;syncStatusDot=null;folderRows.Clear();}

    private ListView VirtualRows(object items,string template,double height)
    {
        var list=new ListView{ItemsSource=items,SelectionMode=ListViewSelectionMode.None,IsTabStop=false,
            HorizontalAlignment=HorizontalAlignment.Stretch,MaxHeight=height,Padding=new Thickness(0),BorderThickness=new Thickness(0)};
        list.ItemTemplate=(DataTemplate)XamlReader.Load(template);
        var style=new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty,HorizontalAlignment.Stretch));
        style.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(0)));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty,44d));
        list.ItemContainerStyle=style;
        return list;
    }
    private const string FolderTemplate="""
        <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
          <Grid MinHeight="44" ColumnSpacing="3" Padding="2,3">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Button Command="{Binding Open}" ToolTipService.ToolTip="{Binding Hint}" AutomationProperties.Name="{Binding OpenLabel}" HorizontalAlignment="Stretch" HorizontalContentAlignment="Stretch" Background="Transparent" BorderThickness="0" Padding="3,1" MinWidth="0">
              <StackPanel Spacing="1"><TextBlock Text="{Binding Label}" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Text="{Binding Detail}" FontSize="11" Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextTrimming="CharacterEllipsis"/><TextBlock Text="{Binding PeerDetail}" FontSize="10" Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextTrimming="CharacterEllipsis"/></StackPanel>
            </Button>
            <Button Grid.Column="1" Command="{Binding Pause}" ToolTipService.ToolTip="{Binding PauseLabel}" AutomationProperties.Name="{Binding PauseLabel}" Width="28" Height="28" MinWidth="0" MinHeight="28" Padding="0"><FontIcon Glyph="{Binding PauseGlyph}" FontSize="12"/></Button>
            <Button Grid.Column="2" Flyout="{Binding Menu}" ToolTipService.ToolTip="More folder actions" AutomationProperties.Name="More folder actions" Width="28" Height="28" MinWidth="0" MinHeight="28" Padding="0"><FontIcon Glyph="&#xE712;" FontSize="12"/></Button>
          </Grid>
        </DataTemplate>
        """;
    private const string FileTemplate="""
        <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
          <Grid MinHeight="44" ColumnSpacing="3" Padding="2,3">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Button Command="{Binding Open}" ToolTipService.ToolTip="{Binding Hint}" AutomationProperties.Name="{Binding OpenLabel}" HorizontalAlignment="Stretch" HorizontalContentAlignment="Stretch" Background="Transparent" BorderThickness="0" Padding="3,1" MinWidth="0">
              <StackPanel Spacing="1"><TextBlock Text="{Binding Label}" FontSize="12" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/><TextBlock Text="{Binding Detail}" FontSize="10" Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextTrimming="CharacterEllipsis"/></StackPanel>
            </Button>
            <Button Grid.Column="1" Command="{Binding Enable}" AutomationProperties.Name="{Binding SyncLabel}" Content="Sync" FontSize="12" MinWidth="0" MinHeight="28" Padding="7,2"/>
            <Button Grid.Column="2" Command="{Binding Stop}" AutomationProperties.Name="{Binding StopLabel}" Content="Stop" FontSize="12" MinWidth="0" MinHeight="28" Padding="7,2"/>
          </Grid>
        </DataTemplate>
        """;
    private void UpdateFolderRows()
    {
        if(syncSnapshot==null)return;
        var peers=QuickPeers();var folders=Items(syncSnapshot.Value,"folders").ToList();
        var project=SyncthingService.ProjectFolder().TrimEnd('\\','/');
        var sorted=folders.OrderBy(f=>HasFolderError(f)?0:S(f,"path").TrimEnd('\\','/').Equals(project,StringComparison.OrdinalIgnoreCase)?1:B(f,"paused")?4:N(FolderStats(f),"needFiles")>0?2:3).ThenBy(f=>S(f,"label")).ToList();
        var wanted=sorted.Select(f=>S(f,"id")).ToHashSet();
        for(int i=folderRows.Count-1;i>=0;i--)if(!wanted.Contains(folderRows[i].Id))folderRows.RemoveAt(i);
        for(int index=0;index<sorted.Count;index++)
        {
            var folder=sorted[index];var id=S(folder,"id");var label=S(folder,"label",id);
            var row=folderRows.FirstOrDefault(r=>r.Id==id);
            if(row==null)
            {
                SyncRow created=null!;
                created=new SyncRow{Id=id,Open=new RowCommand(()=>_=OpenSyncFolder(id,created.Label,"")),
                    Pause=new RowCommand(()=>_=PauseSyncFolder(id,!B(created.Data,"paused"),created.Label))};
                row=created;folderRows.Insert(index,row);
            }
            var stats=FolderStats(folder);var state=QuickFolderState(folder,peers);var paused=B(folder,"paused");
            var shared=FolderPeers(folder);
            string direction=S(folder,"type") switch{"sendonly"=>"To","receiveonly" or "receiveencrypted"=>"From",_=>"To & from"};
            string peerDetail=shared.Count==0?N(folder,"device_count")>1?"Shared devices unavailable":"Not shared with another device":direction+" "+string.Join(", ",shared.Select(p=>p.Name+(p.State=="Connected"?"":" ("+p.State.ToLowerInvariant()+")")));
            if(row.Label!=label||row.Data.ValueKind!=JsonValueKind.Object||S(row.Data,"path")!=S(folder,"path")||row.PeerDetail!=peerDetail)row.Menu=SyncFolderMenu(folder);
            row.Update(folder,label,state+" · "+CountLabel(N(stats,"localFiles"),"file"),S(folder,"path")+"\n"+state+" · "+Bytes(N(stats,"localBytes"))+"\n"+peerDetail,paused?"\uE768":"\uE769",(paused?"Resume ":"Pause ")+label,peerDetail);
            var oldIndex=folderRows.IndexOf(row);if(oldIndex!=index)folderRows.Move(oldIndex,index);
        }
    }
    private ListView CreateSyncFileList()
    {
        var rules=syncRules.GroupBy(r=>r.path,StringComparer.Ordinal).ToDictionary(g=>g.Key,g=>g.Last(),StringComparer.Ordinal);
        var rows=new List<SyncRow>();
        foreach(var entry in Items(syncBrowse!.Value,"entries").Where(e=>S(e,"alternative_for").Length==0))
        {
            var name=S(entry,"name");var path=S(entry,"path");var directory=B(entry,"is_dir");rules.TryGetValue(path,out var rule);
            var row=new SyncRow{Id=path,Open=new RowCommand(()=>{if(directory)_=OpenSyncFolder(syncFolderId,syncFolderLabel,path);else _=OpenSyncedFile(path);}),
                Enable=new RowCommand(()=>_=SetSyncPath(path,directory,true)),Stop=new RowCommand(()=>_=SetSyncPath(path,directory,false))};
            row.Update(entry,(directory?"▰ ":"")+name,(directory?"Folder":Bytes(N(entry,"size")))+" · "+(rule==null?"Default rules":rule.sync?"Sync enabled":"Stopped here"),name);
            rows.Add(row);
        }
        syncFileList=VirtualRows(rows,FileTemplate,compact?270:460);
        return syncFileList;
    }
}
