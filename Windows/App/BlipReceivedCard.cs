using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.FileProperties;
namespace MyDrive;

internal sealed class BlipReceivedCard:UserControl {
    private readonly Grid preview=new(){Height=184};
    private readonly Image image=new(){Stretch=Stretch.Uniform};
    private readonly TextBlock previewText=new(){FontSize=11,TextWrapping=TextWrapping.Wrap,MaxLines=6,Margin=new Thickness(10),VerticalAlignment=VerticalAlignment.Center};
    private readonly FontIcon icon=new(){Glyph="\uE8A5",FontSize=40,Opacity=.65};
    private readonly ComboBox picker=new(){HorizontalAlignment=HorizontalAlignment.Stretch,MinHeight=28};
    private readonly TextBlock name=new(){FontSize=12,TextTrimming=TextTrimming.CharacterEllipsis};
    private readonly TextBlock feedback=new(){FontSize=11,TextWrapping=TextWrapping.Wrap,MaxLines=2};
    private readonly SplitButton open=new(){Content="Open",MinHeight=30};
    private readonly Button copy=new(){Content="Copy",MinHeight=30};
    private readonly StackPanel actions=new(){Orientation=Orientation.Horizontal,Spacing=8};
    private readonly Func<nint> owner;
    private readonly Func<BlipFileAction,BlipTransfer,BlipReceivedItem,Task>? execute;
    private BlipTransfer? transfer;
    private BlipReceivedItem? selected;
    private string key="";
    private int generation;
    private DateTime lastAttempt;
    public Task LoadedPreview {get;private set;}=Task.CompletedTask;
    public string PreviewKind {get;private set;}="placeholder";
    public IReadOnlyList<string> ActionLabels {get;private set;}=Array.Empty<string>();
    public event Action<bool>? MenuActive;
    public event Action<string>? Copied;
    public BlipReceivedCard(Func<nint> owner,Func<BlipFileAction,BlipTransfer,BlipReceivedItem,Task>? execute=null) {
        this.owner=owner;this.execute=execute;
        var content=new StackPanel{Spacing=6};preview.Children.Add(icon);preview.Children.Add(image);preview.Children.Add(previewText);
        content.Children.Add(new Border{Child=preview,CornerRadius=new CornerRadius(6),Background=new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(22,128,128,128))});
        AutomationProperties.SetName(preview,"Received file preview");AutomationProperties.SetName(picker,"Choose received file");AutomationProperties.SetLiveSetting(feedback,Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        content.Children.Add(picker);content.Children.Add(name);content.Children.Add(actions);content.Children.Add(feedback);
        actions.Children.Add(open);actions.Children.Add(copy);open.Click+=async(_,_)=>await Perform(BlipFileAction.Open);copy.Click+=async(_,_)=>await Perform(BlipFileAction.Copy);
        picker.SelectionChanged+=(_,_)=>{selected=picker.SelectedItem as BlipReceivedItem;LoadedPreview=LoadPreview();};Content=content;
    }
    public void SetTransfer(BlipTransfer value) {
        preview.Height=value.ConfirmedComplete?184:80;
        transfer=value;string next=value.Id+":"+value.Status+":"+value.Completed+":"+value.HasError+":"+string.Join("|",value.ReceivedItems.Select(i=>i.Path).OrderBy(p=>p,StringComparer.Ordinal));
        if(key==next){if(PreviewKind=="missing"&&DateTime.UtcNow-lastAttempt>TimeSpan.FromSeconds(5))LoadedPreview=LoadPreview();return;}key=next;
        var entries=value.Direction=="Incoming"&&value.ConfirmedComplete?value.ReceivedItems.Take(256).OrderBy(i=>i.Name,StringComparer.CurrentCultureIgnoreCase).ToList():new();
        string? previous=selected?.Path;picker.ItemsSource=entries;picker.Visibility=entries.Count>1?Visibility.Visible:Visibility.Collapsed;
        picker.SelectedItem=entries.FirstOrDefault(i=>i.Path==previous)??entries.FirstOrDefault();selected=picker.SelectedItem as BlipReceivedItem;
        name.Text=selected?.Name??value.ItemLabel;name.Visibility=entries.Count>1?Visibility.Collapsed:Visibility.Visible;
        LoadedPreview=LoadPreview();
    }
    private async Task LoadPreview() {
        int current=++generation;lastAttempt=DateTime.UtcNow;feedback.Text="";feedback.Visibility=Visibility.Collapsed;image.Source=null;previewText.Text="";icon.Visibility=Visibility.Visible;
        open.IsEnabled=copy.IsEnabled=false;actions.Visibility=transfer?.ConfirmedComplete==true?Visibility.Visible:Visibility.Collapsed;
        PreviewKind="placeholder";
        var value=transfer;var entry=selected;if(value==null||entry==null){previewText.Text=value?.ConfirmedComplete==true?"File location is not available yet":"Preview appears after receiving";icon.Visibility=Visibility.Collapsed;BuildMenu();return;}
        name.Text=entry.Name;ToolTipService.SetToolTip(name,entry.Path);
        var path=await Task.Run(()=>BlipReceivedFiles.LocalPath(value,entry));if(current!=generation)return;
        if(path==null){PreviewKind="missing";previewText.Text="File moved or unavailable";icon.Visibility=Visibility.Collapsed;BuildMenu();return;}
        open.IsEnabled=copy.IsEnabled=true;BuildMenu();
        try {
            if(entry.IsDirectory){icon.Glyph="\uE8B7";PreviewKind="folder";return;}
            icon.Glyph="\uE8A5";
            if(BlipReceivedFiles.IsShortcut(path)){var url=await BlipLinkOpener.ReadShortcutAsync(path);if(current!=generation)return;previewText.Text=url?.AbsoluteUri??"Web link preview unavailable";PreviewKind="link";icon.Visibility=Visibility.Collapsed;return;}
            if(BlipReceivedFiles.IsText(path)){var text=await BlipReceivedFiles.TextPreviewAsync(path);if(current!=generation)return;previewText.Text=text;PreviewKind="text";icon.Visibility=Visibility.Collapsed;return;}
            string extension=Path.GetExtension(path).ToLowerInvariant();
            if(BlipReceivedFiles.IsImage(path)||new[]{".pdf",".mp4",".mov",".mkv",".docx",".pptx",".xlsx"}.Contains(extension)) {
                var file=await StorageFile.GetFileFromPathAsync(path);
                using var thumbnail=await file.GetThumbnailAsync(ThumbnailMode.SingleItem,512,ThumbnailOptions.UseCurrentScale).AsTask().WaitAsync(TimeSpan.FromSeconds(4));
                if(current!=generation)return;
                if(thumbnail!=null){var bitmap=new BitmapImage();await bitmap.SetSourceAsync(thumbnail);if(current!=generation)return;image.Source=bitmap;icon.Visibility=Visibility.Collapsed;PreviewKind="thumbnail";return;}
            }
            PreviewKind="icon";
        }catch{if(current==generation)PreviewKind="icon";}
    }
    private void BuildMenu() {
        var menu=new MenuFlyout();var labels=new List<string>();
        void Add(string title,BlipFileAction action,bool enabled=true){var item=new MenuFlyoutItem{Text=title,IsEnabled=open.IsEnabled&&enabled};item.Click+=async(_,_)=>await Perform(action);menu.Items.Add(item);labels.Add(title);}
        Add("Open",BlipFileAction.Open);Add("Open with…",BlipFileAction.OpenWith,selected is {IsDirectory:false}&&!BlipReceivedFiles.IsShortcut(selected.Path));
        Add("Copy",BlipFileAction.Copy);
        if (selected is { IsDirectory: false } && BlipReceivedFiles.IsText(selected.Path)) Add("Copy file", BlipFileAction.CopyFile);
        Add("Copy path",BlipFileAction.CopyPath);menu.Items.Add(new MenuFlyoutSeparator());
        Add("Open folder",BlipFileAction.OpenFolder);Add("Show in folder",BlipFileAction.ShowInFolder);
        if(transfer?.ReceivedItems.Count>1){menu.Items.Add(new MenuFlyoutSeparator());Add("Copy listed files",BlipFileAction.CopyListedFiles);Add("Copy listed paths",BlipFileAction.CopyListedPaths);}
        menu.Opening+=(_,_)=>MenuActive?.Invoke(true);menu.Closed+=(_,_)=>MenuActive?.Invoke(false);open.Flyout=menu;ActionLabels=labels;
    }
    internal async Task Perform(BlipFileAction action) {
        if (transfer is not { } value || selected is not { } item) return;
        try
        {
            if (execute != null) await execute(action, value, item);
            else await BlipReceivedActions.Execute(action, value, item, owner());
            if (action is BlipFileAction.Copy or BlipFileAction.CopyFile or BlipFileAction.CopyListedFiles
                or BlipFileAction.CopyPath or BlipFileAction.CopyListedPaths)
                Copied?.Invoke(value.Id);
            feedback.Text = "";
        }
        catch{feedback.Text="This file action is unavailable. The item may have moved.";}
        feedback.Visibility=feedback.Text.Length>0?Visibility.Visible:Visibility.Collapsed;
    }
}
