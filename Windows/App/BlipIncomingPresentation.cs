using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;

public sealed partial class MainWindow
{
    private readonly Border inlineBlipSlot = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(8, 4, 8, 5) };
    private readonly HashSet<string> dismissedIncomingBlips = new();
    private BlipIncomingCard? inlineBlipCard;
    private BlipTransfer? incomingBlipTransfer;
    private bool incomingBlipDetail;

    private void BlipNoticeSettings()
    {
        if (AppWindow.IsVisible) NavigateQuick("settings");
        else { currentView = "settings"; SetMode(true); }
        _ = ChooseLinkSenders();
    }

    private void UpdateIncomingBlip(BlipTransfer transfer, bool announce)
    {
        if (quitting || dismissedIncomingBlips.Contains(transfer.Id) ||
            !announce && incomingBlipTransfer?.Id != transfer.Id) return;
        if (incomingBlipTransfer?.Id != transfer.Id) incomingBlipDetail = false;
        incomingBlipTransfer = transfer;
        if (AppWindow.IsVisible)
        {
            UpdateInlineBlipVisibility();
            return;
        }
        if (blipIncomingWindow == null)
        {
            blipIncomingWindow = new BlipIncomingWindow(t => _ = ReceiveFromBlipNotice(t),
                BlipNoticeSettings, TrayPopupAnchor, ShowIncomingInBlip);
            blipIncomingWindow.NoticeDismissed += id =>
            {
                dismissedIncomingBlips.Add(id);
                if (incomingBlipTransfer?.Id == id) incomingBlipTransfer = null;
            };
        }
        blipIncomingWindow.Update(transfer, BlipPeerCaption(transfer.Peer),
            blipAutoAccepted.ContainsKey(transfer.Id), announce);
    }

    private void UpdateInlineBlipVisibility()
    {
        if (quitting) return;
        if (!AppWindow.IsVisible || incomingBlipTransfer is not { } transfer)
        {
            inlineBlipSlot.Visibility = Visibility.Collapsed;
            return;
        }
        blipIncomingWindow?.Stop();
        if (inlineBlipCard == null)
        {
            inlineBlipCard = new BlipIncomingCard(() => hwnd, t => _ = ReceiveFromBlipNotice(t),
                ShowIncomingInBlip, BlipNoticeSettings, inline: true);
            inlineBlipCard.DismissRequested += () =>
            {
                if (incomingBlipTransfer is { } shown) dismissedIncomingBlips.Add(shown.Id);
                incomingBlipTransfer = null;
                incomingBlipDetail = false;
                inlineBlipSlot.Visibility = Visibility.Collapsed;
                if (currentView == "transfers") Render();
            };
            inlineBlipSlot.Child = new ScrollViewer { Content = inlineBlipCard,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 276 };
        }
        inlineBlipCard.Update(transfer, BlipPeerCaption(transfer.Peer), blipAutoAccepted.ContainsKey(transfer.Id),
            incomingBlipDetail && currentView == "transfers");
        inlineBlipSlot.Visibility = Visibility.Visible;
    }

    private void ShowIncomingInBlip(BlipTransfer transfer)
    {
        incomingBlipTransfer = transfer;
        incomingBlipDetail = true;
        NavigateQuick("transfers");
        if (!AppWindow.IsVisible) OpenQuickMenu();
        UpdateInlineBlipVisibility();
    }

    private void ShowIncomingFailure(string id, string? reason)
    {
        if (inlineBlipCard?.Transfer?.Id == id && AppWindow.IsVisible)
            inlineBlipCard.ShowFailure(reason);
        if (blipIncomingWindow?.TransferId == id)
        {
            if (reason == null) blipIncomingWindow.ClearFailure();
            else blipIncomingWindow.ShowFailure(reason);
        }
    }
}
