using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.FileProperties;
namespace MyDrive;

internal sealed class BlipReceivedCard:UserControl {
    internal const int MediaHeight = 254;
    private static readonly SolidColorBrush OverlayBrush = new(Microsoft.UI.ColorHelper.FromArgb(170, 0, 0, 0));
    private readonly Grid stage = new();
    private readonly Grid preview = new() { Height = MediaHeight };
    private readonly Border identity = new() { VerticalAlignment = VerticalAlignment.Top };
    private readonly Border controls = new() { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Border frame;
    private readonly Image image=new(){Stretch=Stretch.Uniform};
    private readonly TextBlock previewText = new()
    {
        FontSize = 12, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap,
        TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 9,
        Margin = new Thickness(13, 43, 13, 70), VerticalAlignment = VerticalAlignment.Top,
    };
    private readonly FontIcon icon=new(){Glyph="\uE8A5",FontSize=40,Opacity=.65};
    private readonly ComboBox picker=new(){HorizontalAlignment=HorizontalAlignment.Stretch,MinHeight=28,MaxWidth=265};
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
    public event Action? PreviewHeightChanged;
    public event Action<bool>? MenuActive;
    public event Action<string>? Copied;
    public BlipReceivedCard(Func<nint> owner,Func<BlipFileAction,BlipTransfer,BlipReceivedItem,Task>? execute=null) {
        this.owner=owner;this.execute=execute;
        preview.Children.Add(icon);
        preview.Children.Add(image);
        preview.Children.Add(previewText);
        stage.Children.Add(preview);
        stage.Children.Add(identity);
        stage.Children.Add(controls);
        var fileControls = new StackPanel { Spacing = 4 };
        fileControls.Children.Add(picker);
        fileControls.Children.Add(name);
        fileControls.Children.Add(actions);
        fileControls.Children.Add(feedback);
        controls.Child = fileControls;
        frame = new Border { Child = stage, CornerRadius = new CornerRadius(8) };
        AutomationProperties.SetName(preview, "Received file preview");
        AutomationProperties.SetName(picker, "Choose received file");
        AutomationProperties.SetLiveSetting(feedback, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        actions.Children.Add(open);
        actions.Children.Add(copy);
        open.Click += async (_, _) => await Perform(BlipFileAction.Open);
        copy.Click += async (_, _) => await Perform(BlipFileAction.Copy);
        picker.SelectionChanged += (_, _) => { selected = picker.SelectedItem as BlipReceivedItem; LoadedPreview = LoadPreview(); };
        Content = frame;
    }

    public void SetHeader(UIElement header) => identity.Child = header;

    private void StyleCard(bool complete)
    {
        preview.Visibility = complete ? Visibility.Visible : Visibility.Collapsed;
        frame.Background = complete ? new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(22, 128, 128, 128)) : null;
        foreach (var overlay in new[] { identity, controls })
        {
            overlay.Background = complete ? OverlayBrush : null;
            overlay.RequestedTheme = complete ? ElementTheme.Dark : ElementTheme.Default;
            overlay.CornerRadius = new CornerRadius(7);
            overlay.Margin = complete ? new Thickness(6) : new Thickness(0);
            overlay.Padding = complete ? new Thickness(7, 4, 7, 4) : new Thickness(0);
        }
        if (complete)
        {
            stage.RowDefinitions.Clear();
            Grid.SetRow(controls, 0);
        }
        else if (stage.RowDefinitions.Count == 0)
        {
            stage.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            stage.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(controls, 1);
        }
    }

    public void SetTransfer(BlipTransfer value) {
        transfer=value;string next=value.Id+":"+value.Status+":"+value.Completed+":"+value.HasError+":"+string.Join("|",value.ReceivedItems.Select(i=>i.Path).OrderBy(p=>p,StringComparer.Ordinal));
        if(key==next){if(PreviewKind=="missing"&&DateTime.UtcNow-lastAttempt>TimeSpan.FromSeconds(5))LoadedPreview=LoadPreview();return;}key=next;
        StyleCard(value.ConfirmedComplete);
        var entries=value.Direction=="Incoming"&&value.ConfirmedComplete?value.ReceivedItems.Take(256).OrderBy(i=>i.Name,StringComparer.CurrentCultureIgnoreCase).ToList():new();
        string? previous=selected?.Path;picker.ItemsSource=entries;picker.Visibility=entries.Count>1?Visibility.Visible:Visibility.Collapsed;
        picker.SelectedItem=entries.FirstOrDefault(i=>i.Path==previous)??entries.FirstOrDefault();selected=picker.SelectedItem as BlipReceivedItem;
        name.Text=selected?.Name??value.ItemLabel;name.Visibility=entries.Count>1?Visibility.Collapsed:Visibility.Visible;
        LoadedPreview=LoadPreview();
    }
    private void SetPreviewHeight(double height)
    {
        if (Math.Abs(preview.Height - height) < 1) return;
        preview.Height = height;
        PreviewHeightChanged?.Invoke();
    }

    private async Task LoadPreview() {
        int current=++generation;lastAttempt=DateTime.UtcNow;feedback.Text="";feedback.Visibility=Visibility.Collapsed;image.Source=null;previewText.Text="";icon.Visibility=Visibility.Visible;
        open.IsEnabled=copy.IsEnabled=false;actions.Visibility=transfer?.ConfirmedComplete==true?Visibility.Visible:Visibility.Collapsed;
        PreviewKind="placeholder";
        SetPreviewHeight(MediaHeight);
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
                if (thumbnail != null)
                {
                    var bitmap = new BitmapImage();
                    await bitmap.SetSourceAsync(thumbnail);
                    if (current != generation) return;
                    image.Source = bitmap;
                    icon.Visibility = Visibility.Collapsed;
                    PreviewKind = "thumbnail";
                    if (bitmap.PixelWidth > 0)
                        SetPreviewHeight(Math.Clamp(320.0 * bitmap.PixelHeight / bitmap.PixelWidth, 178, MediaHeight));
                    return;
                }
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
