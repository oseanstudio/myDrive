using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;

internal sealed class BlipIncomingCard : UserControl
{
    private readonly TextBlock sender = new() { FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock state = new() { FontSize = 11, Opacity = .8, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock details = new() { FontSize = 11, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly TextBlock bytes = new() { FontSize = 11, TextWrapping = TextWrapping.Wrap };
    private readonly ProgressBar progress = new() { Height = 6 };
    private readonly Button receive = new() { Content = "Receive", MinHeight = 28 };
    private readonly Button open = new() { Content = "Show in Blip", MinHeight = 28 };
    internal BlipReceivedCard FileCard { get; }
    internal BlipTransfer? Transfer { get; private set; }
    private string? failure;
    private bool automatic;
    private bool isDetail;
    public event Action? DismissRequested;
    public event Action? LayoutChanged;
    public event Action<bool>? MenuActive;

    public BlipIncomingCard(Func<nint> owner, Action<BlipTransfer> accept, Action<BlipTransfer> show,
                            Action settings, bool inline)
    {
        var content = new StackPanel { Spacing = 5 };
        var header = new Grid { ColumnSpacing = 4 };
        header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        for (int index = 0; index < (inline ? 3 : 2); index++)
            header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        sender.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(sender);
        Grid.SetColumn(state, 1); header.Children.Add(state);
        var preferences = Icon("\uE713", "Sender settings", settings);
        Grid.SetColumn(preferences, 2); header.Children.Add(preferences);
        if (inline)
        {
            var close = Icon("\uE711", "Dismiss incoming transfer", () => DismissRequested?.Invoke());
            Grid.SetColumn(close, 3); header.Children.Add(close);
        }
        FileCard = new BlipReceivedCard(owner);
        FileCard.SetHeader(header);
        FileCard.PreviewHeightChanged += () => LayoutChanged?.Invoke();
        FileCard.MenuActive += active => MenuActive?.Invoke(active);
        FileCard.Copied += id => { if (Transfer?.Id == id) DismissRequested?.Invoke(); };
        content.Children.Add(FileCard);
        content.Children.Add(details);
        content.Children.Add(progress);
        content.Children.Add(bytes);
        AutomationProperties.SetName(progress, "Incoming Blip transfer progress");
        receive.Click += (_, _) => { if (Transfer is { } value) accept(value); };
        open.Click += (_, _) => { if (Transfer is { } value) show(value); };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        actions.Children.Add(receive); actions.Children.Add(open);
        content.Children.Add(actions);
        Content = content;
    }

    private static Button Icon(string glyph, string label, Action action)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 11 },
            MinWidth = 25, MinHeight = 27, Padding = new Thickness(3) };
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => action();
        return button;
    }

    public void Update(BlipTransfer transfer, string name, bool auto, bool detail = false)
    {
        if (Transfer?.Id != transfer.Id || Transfer?.Status != transfer.Status || Transfer?.HasError != transfer.HasError)
            failure = null;
        Transfer = transfer;
        automatic = auto;
        isDetail = detail;
        sender.Text = name;
        ToolTipService.SetToolTip(sender, name);
        FileCard.SetTransfer(transfer);
        RenderStatus();
    }

    public void ShowFailure(string? message)
    {
        failure = message;
        RenderStatus();
        LayoutChanged?.Invoke();
    }

    private void RenderStatus()
    {
        if (Transfer is not { } value) return;
        state.Text = failure != null || value.HasError ? "Needs attention" : value.ConfirmedComplete ? "Received"
            : automatic && value.AwaitingAcceptance ? "Requesting…" : value.StateLabel;
        details.Text = failure ?? (value.HasError ? value.FailureLabel : "");
        details.Visibility = details.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        receive.Visibility = value.AwaitingAcceptance && (!automatic || failure != null) ? Visibility.Visible : Visibility.Collapsed;
        open.Visibility = !isDetail && (value.HasError || failure != null) ? Visibility.Visible : Visibility.Collapsed;
        ConfigureProgress(value, progress, bytes, automatic && value.AwaitingAcceptance && failure == null);
    }

    public static void ConfigureProgress(BlipTransfer value, ProgressBar progress, TextBlock bytes, bool starting = false)
    {
        bool active = value.ReceivingFiles || starting;
        bool interrupted = value.HasError || value.Status == "Cancelled";
        bool knownProgress = value.Progress > 0 || value.HasByteTotal;
        progress.Visibility = active || interrupted && value.HasByteTotal ? Visibility.Visible : Visibility.Collapsed;
        bytes.Visibility = active || value.HasError || interrupted && knownProgress ? Visibility.Visible : Visibility.Collapsed;
        progress.IsIndeterminate = active && !value.HasByteTotal && value.Status != "Paused";
        progress.Maximum = Math.Max(1, value.TotalBytes);
        progress.Value = Math.Clamp(value.Progress, 0, Math.Max(1, value.TotalBytes));
        bytes.Text = value.ByteLabel;
    }
}
