using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MyDrive;
public sealed partial class MainWindow
{
    private readonly BlipService blip = new(BlipService.BundleDirectory, BlipService.DefaultRuntimeDirectory, Path.Combine(CoreBridge.DataDir, "Blip"));
    private System.Threading.Timer? blipTimer;
    private BlipLinkOpener? blipLinks;
    private BlipLinkOpener LinkOpener => System.Threading.LazyInitializer.EnsureInitialized(ref blipLinks, () => new(Path.Combine(CoreBridge.DataDir, "Blip", "opened-links.json")));
    private BlipSnapshot? blipSnapshot;
    private string blipFailure = "", blipSignature = "";
    private int blipRefreshing;
    private volatile bool blipViewVisible;
    private long nextDesktopBlipAttempt;
    private long nextBlipNamePublish;
    private string blipNamingOwner = "";
    private readonly HashSet<string> cancellingBlipSends = new();
    private readonly BlipNoticeTracker blipNotices=new();
    private BlipSenderCatalog? blipSenderCatalog;
    private BlipSenderCatalog SenderCatalog=>System.Threading.LazyInitializer.EnsureInitialized(ref blipSenderCatalog,()=>new(Path.Combine(CoreBridge.DataDir,"Blip","sender-catalog.json")));
    private BlipIncomingWindow? blipIncomingWindow;
    private readonly object blipPolicyGate=new();
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string,byte> blipAutoAccepted = new();
    private BlipReceiveLedger? blipReceiveLedger;
    private BlipReceiveLedger ReceiveLedger => System.Threading.LazyInitializer.EnsureInitialized(ref blipReceiveLedger,()=>new(Path.Combine(CoreBridge.DataDir,"Blip","auto-receive-claims.json")));
    private bool AllowedLinkSender(BlipTransfer transfer) {lock(blipPolicyGate){return blipSnapshot != null && BlipTrustPolicy.Allowed(blipSnapshot.Status,Preferences.Current.BlipAutoOpenAccount,Preferences.Current.BlipAutoOpenPeers,transfer);}}
    private bool ShouldAutoReceive(BlipStatus status,BlipTransfer transfer) {lock(blipPolicyGate){return BlipTrustPolicy.AutoReceive(status,Preferences.Current.BlipAutoOpenAccount,Preferences.Current.BlipAutoOpenPeers,Preferences.Current.BlipAutoReceivePeers,transfer,Preferences.Current.BlipAutoOpenLinks);}}
    private bool? blipFixtureRunning;
    private readonly Dictionary<string, string> blipSentNames = new();
    private bool BlipRunning => blipFixtureRunning ?? blip.IsRunning;
    private bool BlipDesktop => diagnosticMode ? blipSnapshot?.Status.DesktopSession == true : blip.UsesDesktopSession;
    private void UpdateBlipView() => blipViewVisible = currentView == "transfers" && AppWindow.IsVisible;
    private void StartBlipRefresh()
    {
        // Network polling and browser dispatch must not depend on a visible XAML window.
        blipTimer = new System.Threading.Timer(async _ =>
        {
            if (diagnosticMode || quitting) return;
            await RefreshBlip(false).ConfigureAwait(false);
        }, null, TimeSpan.Zero, TimeSpan.FromSeconds(2));
        Closed += (_, _) => {blipTimer?.Dispose();blipIncomingWindow?.Stop();};
    }
    private async Task RefreshBlip(bool fullSnapshot = true)
    {
        if (!fullSnapshot && !blip.IsRunning &&
            (!Preferences.Current.BlipAutoConnectDesktop || Environment.TickCount64 < Interlocked.Read(ref nextDesktopBlipAttempt))) return;
        if (diagnosticMode || quitting || Interlocked.CompareExchange(ref blipRefreshing, 1, 0) != 0) return;
        try
        {
            // Attach to the already running app through local IPC; never sign in or start it here.
            if (!blip.IsRunning && Preferences.Current.BlipAutoConnectDesktop && !busy && modalDepth == 0
                && Environment.TickCount64 >= Interlocked.Read(ref nextDesktopBlipAttempt) && blip.DesktopAvailable)
            {
                Interlocked.Exchange(ref nextDesktopBlipAttempt, Environment.TickCount64 + 30_000);
                using var attachTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                if (Preferences.Current.BlipSeparateProfile)
                    await blip.StartAsync(attachTimeout.Token).ConfigureAwait(false);
                else
                    await blip.UseDesktopAsync(attachTimeout.Token).ConfigureAwait(false);
                blipSnapshot = null; LinkOpener.ResetSession();
            }
            if (blip.IsRunning)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                var freshSnapshot=await blip.PollAsync(timeout.Token).ConfigureAwait(false);
                blipFailure="";
                var owner = freshSnapshot.Status.UserId + ":" + freshSnapshot.Status.DeviceId;
                if (blipNamingOwner != owner) { blipNamingOwner = owner; nextBlipNamePublish = 0; }
                if (freshSnapshot.Status.Authenticated && freshSnapshot.Status.CurrentDeviceNamed != true &&
                    Environment.TickCount64 >= nextBlipNamePublish)
                {
                    nextBlipNamePublish = Environment.TickCount64 + 300_000;
                    using var nameTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
                    try
                    {
                        await blip.PublishNameAsync(owner, nameTimeout.Token).ConfigureAwait(false);
                        if (freshSnapshot.Status.CurrentDeviceNamed is null) nextBlipNamePublish = long.MaxValue;
                    }
                    catch (Exception error) when (error is IOException or OperationCanceledException or System.Text.Json.JsonException) { }
                }
                try { await UpdateRelay(freshSnapshot, timeout.Token).ConfigureAwait(false); }
                catch (Exception) { blipFailure = "A relay action needs attention. Stored files are kept."; }
                freshSnapshot = freshSnapshot with { Transfers = freshSnapshot.Transfers
                    .Where(t => !IsRelayPacket(t) || !SameBlipAccount(t.Peer, freshSnapshot.Status.UserId))
                    .Concat(relayReceived.Values).ToList() };
                var approved=Preferences.Current.BlipAutoOpenAccount.Equals(freshSnapshot.Status.UserId,StringComparison.OrdinalIgnoreCase)?Preferences.Current.BlipAutoOpenPeers.Concat(Preferences.Current.BlipAutoReceivePeers):Array.Empty<string>();
                blipSnapshot=freshSnapshot with {Devices=SenderCatalog.Merge(freshSnapshot.Status,freshSnapshot.Devices,freshSnapshot.Transfers,approved)};
                var snapshot=blipSnapshot;
                var notices=blipNotices.Update(snapshot.Status,snapshot.Transfers);
                if (notices.Count > 0 || blipIncomingWindow != null) DispatcherQueue.TryEnqueue(()=>{
                    foreach(var transfer in notices)UpdateIncomingBlip(transfer,true);
                    if(blipIncomingWindow!=null&&snapshot.Transfers.FirstOrDefault(t=>t.Id==blipIncomingWindow.TransferId) is {} current)UpdateIncomingBlip(current,false);
                });
                var pending = snapshot.Transfers.Where(t=>t.AwaitingAcceptance).ToList();
                foreach(var id in blipAutoAccepted.Keys.Where(id=>!pending.Any(t=>t.Id==id)))blipAutoAccepted.TryRemove(id,out _);
                foreach(var request in pending)
                    if ((snapshot.Status.DesktopSession || snapshot.Status.NativeAutoAcceptDisabled) &&
                        ShouldAutoReceive(snapshot.Status,request) && !blipAutoAccepted.ContainsKey(request.Id) && ReceiveLedger.TryClaim(snapshot.Status.UserId,request.Id) && blipAutoAccepted.TryAdd(request.Id,0)) {

                        try {await blip.AcceptAsync(request.Id,timeout.Token).ConfigureAwait(false);}
                        catch(Exception error){
                            blipAutoAccepted.TryRemove(request.Id,out _);
                            blipFailure=error.Message;
                            DispatcherQueue.TryEnqueue(()=>{UpdateIncomingBlip(request,true);blipIncomingWindow?.ShowFailure(error.Message);});
                        }
                    }
                await LinkOpener.ProcessAsync(snapshot.Status, snapshot.Transfers, Preferences.Current.BlipAutoOpenLinks, AllowedLinkSender).ConfigureAwait(false);
                if(LinkOpener.LastError.Length>0)blipFailure=LinkOpener.LastError;
            }
            else blipFailure = blip.LastError;
        }
        catch (Exception e)
        {
            blipFailure = e.Message;
            if (blip.UsesDesktopSession)
            {
                // Drop only our IPC attachment. A later attachment gets a fresh history baseline.
                await blip.StopAsync().ConfigureAwait(false); blipSnapshot = null; LinkOpener.ResetSession();
                Interlocked.Exchange(ref nextDesktopBlipAttempt, Environment.TickCount64 + 30_000);
            }
        }
        finally
        {
            Volatile.Write(ref blipRefreshing, 0);
            if (blipViewVisible)
            {
                var snapshot = blipSnapshot;
                string signature = System.Text.Json.JsonSerializer.Serialize(new {
                    running = BlipRunning, blipFailure, status = snapshot?.Status, devices = snapshot?.Devices,
                    transfers = snapshot?.Transfers.Where(t => t.IsLive), blipRelayWaiting, blipRelayQueued,
                });
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (!quitting && blipViewVisible && modalDepth == 0 && signature != blipSignature) { blipSignature = signature; Render(); }
                });
            }
        }
    }
    private void UpdateIncomingBlip(BlipTransfer transfer,bool announce) {
        if(quitting)return;
        blipIncomingWindow ??= new BlipIncomingWindow(t => _ = ReceiveFromBlipNotice(t),
            () => { currentView = "settings"; SetMode(true); _ = ChooseLinkSenders(); },
            TrayPopupAnchor);
        string name=BlipPeerCaption(transfer.Peer);
        blipIncomingWindow.Update(transfer,name,blipAutoAccepted.ContainsKey(transfer.Id),announce);
    }
    private async Task ReceiveFromBlipNotice(BlipTransfer transfer) {
        if(diagnosticMode||!transfer.AwaitingAcceptance||!blipAutoAccepted.TryAdd(transfer.Id,0))return;
        var account = blipSnapshot?.Status.UserId ?? "";
        blipIncomingWindow?.ClearFailure();
        UpdateIncomingBlip(transfer,false);
        try{using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(15));await blip.AcceptAsync(transfer.Id,timeout.Token,manual:true);ReceiveLedger.TryClaim(account,transfer.Id);}
        catch(Exception error){blipAutoAccepted.TryRemove(transfer.Id,out _);blipIncomingWindow?.ShowFailure(error.Message);}
        await RefreshBlip();
    }
    private void RenderBlip()
    {
        if (!compact) Heading(SendViewName, "");
        bool running = BlipRunning, signedIn = blipSnapshot?.Status.Authenticated == true;
        var label = running ? signedIn ? "Checking automatic receiving" : "Sign in to send or receive" : Preferences.Current.BlipAutoConnectDesktop ? "Preparing background Blip" : "Blip is disconnected";
        if (!running || !signedIn || (!BlipDesktop && blipSnapshot?.Status.NativeAutoAcceptDisabled != true))
            page.Children.Add(QuickText(label, compact ? 12 : 16));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (!running) actions.Children.Add(QuickButton("Connect…", () => _ = ChooseBlipConnection(), true));
        else
        {
            if (signedIn) { var send = QuickButton("Send…", () => _ = ShowBlipSend(), true); send.IsEnabled = !busy; actions.Children.Add(send); }
            if (!signedIn && !BlipDesktop) actions.Children.Add(QuickButton(blipSnapshot?.Status.Registration == "CODE_SENT" ? "Enter code…" : "Connect Blip…", () => _ = ConnectBlip()));
        }
        actions.Children.Add(QuickButton("Received files", OpenBlipDownloads));
        page.Children.Add(actions);
        RenderBlipRecipients();
        AddLiveBlipTransfers("Outgoing");
        if (signedIn)
            foreach (var queued in blipRelayQueued)
                page.Children.Add(BlipTransferRow(new BlipTransfer { Id = queued.id, Peer = queued.peer,
                    ItemNames = [queued.label], Direction = "Outgoing", Status = "QueuedForRelay" }, queuedRelay: true));
        if (!blip.RuntimeAvailable && !diagnosticMode) page.Children.Add(Card(Text("The myDrive Blip helper is missing. Reinstall myDrive.", 12)));
        string failure = blipFailure.Length > 0 ? blipFailure : blip.LastError;
        if (blipRelayWaiting > 0) page.Children.Add(Text($"{blipRelayWaiting} waiting for relay or delivery", 11));
        if (failure.Length > 0) page.Children.Add(Card(Text(failure, 12)));
        if (!running) page.Children.Add(Text(Preferences.Current.BlipAutoConnectDesktop ? "myDrive keeps this computer's existing Blip device available. Sign in in Blip once if needed." : "Reuse the account in desktop Blip, or start a separate Blip device for headless use.", 12));
        if (running && BlipDesktop && !signedIn) page.Children.Add(Text("Sign in in the Blip desktop app, then refresh here.", 12));
        if (running && !signedIn && !BlipDesktop) page.Children.Add(Text("Use your Blip account to connect this computer as a separate device. Sign-in starts only when you choose Connect Blip.", 12));
        AddLiveBlipTransfers("Incoming");
    }

    private void AddLiveBlipTransfers(string direction)
    {
        var transfers = blipSnapshot?.Transfers.Where(t => t.IsLive && t.Direction == direction).ToList();
        if (transfers is { Count: > 0 })
        {
            // ListView virtualizes rows and keeps the compact window at the existing fixed size.
            var list = new ListView { SelectionMode = ListViewSelectionMode.None, MaxHeight = compact ? 215 : 480, HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var transfer in transfers) list.Items.Add(BlipTransferRow(transfer));
            page.Children.Add(list);
        }
    }
    private void RenderBlipSettings()
    {
        var settings = new StackPanel { Spacing = 4 };
        settings.Children.Add(QuickText("Blip", 13, true));
        var autoOpen = new CheckBox { Content = "Open approved senders’ links automatically",
            IsChecked = Preferences.Current.BlipAutoOpenLinks };
        autoOpen.Click += (_, _) =>
        {
            if (diagnosticMode) return;
            Preferences.Current.BlipAutoOpenLinks = autoOpen.IsChecked == true;
            Preferences.Save();
            LinkOpener.ResetSession();
        };
        settings.Children.Add(autoOpen);
        var background = new CheckBox { Content = "Keep Blip available in the background",
            IsChecked = Preferences.Current.BlipAutoConnectDesktop };
        background.Click += (_, _) =>
        {
            if (diagnosticMode) return;
            Preferences.Current.BlipAutoConnectDesktop = background.IsChecked == true;
            Preferences.Save();
            Interlocked.Exchange(ref nextDesktopBlipAttempt, 0);
            if (background.IsChecked == true) _ = RefreshBlip();
        };
        settings.Children.Add(background);
        var senders = QuickButton("Sender permissions…", () => _ = ChooseLinkSenders());
        senders.IsEnabled = blipSnapshot?.Status.Authenticated == true;
        settings.Children.Add(senders);
        if (BlipRunning)
            settings.Children.Add(QuickButton(BlipDesktop ? "Disconnect Blip" : "Stop Blip", () => _ = StopBlip()));
        else
            settings.Children.Add(QuickButton("Add Blip engine…", () => _ = ImportBlipEngine()));
        page.Children.Add(settings);
    }

    private UIElement BlipTransferRow(BlipTransfer transfer, bool queuedRelay = false)
    {
        var row = new Grid { ColumnSpacing = 6, MinHeight = 44, Padding = new Thickness(0, 3, 0, 3) };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        string peer = BlipPeerCaption(transfer.Peer);
        bool outgoing = transfer.Direction == "Outgoing";
        string title = outgoing ? blipSentNames.GetValueOrDefault(transfer.Id,
            transfer.ItemNames.FirstOrDefault() ?? "Outgoing transfer") : peer;
        var detail = new StackPanel { Spacing = 2 };
        detail.Children.Add(QuickText(title, 13, true));
        detail.Children.Add(QuickText((outgoing ? peer + " · " : "") + (queuedRelay ? "Queued for relay" : transfer.ProgressLabel) +
            (BlipRunning ? "" : " · last known"), 12));
        row.Children.Add(detail);
        ToolTipService.SetToolTip(row, title + "\n" + transfer.Id + "\n" + transfer.Peer); AutomationProperties.SetName(row, title + ", " + transfer.StateLabel);
        if (transfer.AwaitingAcceptance && blipAutoAccepted.ContainsKey(transfer.Id))
        {
            var receiving=QuickText("Receiving…",12);Grid.SetColumn(receiving,1);row.Children.Add(receiving);
        }
        else if (transfer.AwaitingAcceptance)
        {
            var accept = QuickButton("Receive", () => _ = AcceptBlip(transfer)); accept.IsEnabled = BlipRunning && blipSnapshot?.Status.Authenticated == true && !busy; Grid.SetColumn(accept, 1); row.Children.Add(accept);
        }
        else if (outgoing)
        {
            bool cancelling = cancellingBlipSends.Contains(transfer.Id);
            var stop = QuickButton(cancelling ? "Cancelling…" : "Cancel", () => _ = CancelBlipSend(transfer, queuedRelay));
            stop.IsEnabled = !cancelling && BlipRunning && BlipOwner.Length > 0;
            AutomationProperties.SetName(stop, "Cancel send of " + title);
            Grid.SetColumn(stop, 1);
            row.Children.Add(stop);
        }
        return row;
    }

    private async Task CancelBlipSend(BlipTransfer transfer, bool queuedRelay)
    {
        var owner = BlipOwner;
        if (diagnosticMode || owner.Length == 0 || !cancellingBlipSends.Add(transfer.Id)) return;
        Render();
        try
        {
            if (queuedRelay)
            {
                await CoreBridge.Call(new { action = "relay.cancel", data_dir = CoreBridge.DataDir,
                    payload = new { @self = owner, id = transfer.Id } });
                if (BlipOwner == owner)
                    blipRelayQueued = blipRelayQueued.Where(item => item.id != transfer.Id).ToList();
                Interlocked.Exchange(ref nextRelayDiscovery, 0);
            }
            else await blip.CancelSendAsync(owner, transfer.Id);
        }
        catch (Exception error) { if (owner == BlipOwner) Error(error); }
        finally
        {
            cancellingBlipSends.Remove(transfer.Id);
            await RefreshBlip();
            if (currentView == "transfers") Render();
        }
    }
    private (ContentDialog Dialog, RadioButton Desktop) BlipConnectionDialog()
    {
        var desktop = new RadioButton { Content = "Use this computer's Blip account", IsChecked = true, GroupName = "BlipConnection" };
        var separate = new RadioButton { Content = "Start separately", GroupName = "BlipConnection" };
        var content = new StackPanel { Spacing = 6 };
        content.Children.Add(desktop); content.Children.Add(Text("Reuse your existing sign-in and device. myDrive keeps receiving available when Blip is closed.", 12));
        content.Children.Add(separate); content.Children.Add(Text("An independent device for headless use. Requires its own sign-in.", 12));
        return (new ContentDialog { XamlRoot = root.XamlRoot, Title = "Connect Blip", Content = new ScrollViewer { Content = content, MaxHeight = compact ? 220 : 400 }, PrimaryButtonText = "Connect", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }, desktop);
    }
    private async Task ChooseBlipConnection()
    {
        if (busy || diagnosticMode) return;
        var (dialog, desktop) = BlipConnectionDialog();
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        if (desktop.IsChecked == true)
        { await Run("Connect to existing Blip device", async token => { blipSnapshot = null; LinkOpener.ResetSession(); await blip.UseDesktopAsync(token); Preferences.Current.BlipSeparateProfile = false; Preferences.Current.BlipAutoConnectDesktop = true; Preferences.Save(); await RefreshBlip(); }); Render(); }
        else await StartBlip();
    }
    private async Task ImportBlipEngine()
    {
        if (busy || diagnosticMode || blip.IsRunning) return;
        var picker = new FileOpenPicker { CommitButtonText = "Add engine" };
        InitializeWithWindow.Initialize(picker, hwnd);
        picker.FileTypeFilter.Add(".dll");
        var selected = await Modal(async () => await picker.PickSingleFileAsync());
        if (selected is null) return;
        await Run("Add Blip engine", async token =>
        {
            await blip.ImportEngineAsync(selected.Path, token);
            Interlocked.Exchange(ref nextDesktopBlipAttempt, 0);
        });
        await RefreshBlip();
    }
    private async Task ChooseLinkSenders()
    {
        if(busy||blipSnapshot?.Status.Authenticated!=true)return;
        if(!diagnosticMode)await RefreshBlip();
        var snapshot=blipSnapshot;if(snapshot?.Status.Authenticated!=true)return;
        var account=snapshot.Status.UserId;bool same=Preferences.Current.BlipAutoOpenAccount.Equals(account,StringComparison.OrdinalIgnoreCase);
        var content=new StackPanel{Spacing=7,MaxWidth=compact?274:460};
        var choices=new List<(string Peer,CheckBox Files,CheckBox Links,TextBox Name,string Initial)>();
        var devices=snapshot.Devices.Where(d=>BlipTrustPolicy.ExactPeer(d.Peer)&&!d.Peer.Equals(account+":"+snapshot.Status.DeviceId,StringComparison.OrdinalIgnoreCase)).ToList();
        foreach(var group in devices.GroupBy(d=>d.Peer.Split(':')[0],StringComparer.OrdinalIgnoreCase)) {
            string person = group.Key.Equals(account, StringComparison.OrdinalIgnoreCase)
                ? "Your devices"
                : BlipPersonName(group.First(), group.Key) ?? "Previous sender";
            var heading = QuickText(person, 13, true);
            ToolTipService.SetToolTip(heading, person);
            content.Children.Add(heading);
            foreach(var device in group.OrderBy(d=>d.Name).ThenBy(d=>d.Peer)) {
                string name = BlipDeviceName(device);
                var deviceCard = new StackPanel { Spacing = 3 };
                var label = new TextBox { Text = name, FontSize = 12, MinHeight = 28,
                    Padding = new Thickness(5, 3, 5, 3), MaxLength = 80, Visibility = Visibility.Collapsed };
                AutomationProperties.SetName(label, "Device name for " + name);
                var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                var title = QuickText(name, 12, true);
                title.MaxWidth = compact ? 204 : 374;
                nameRow.Children.Add(title);
                nameRow.Children.Add(QuickIcon("\uE70F", "Rename " + name, () =>
                {
                    label.Visibility = Visibility.Visible;
                    label.Focus(FocusState.Programmatic);
                    label.SelectAll();
                }));
                label.TextChanged += (_, _) => title.Text = string.IsNullOrWhiteSpace(label.Text) ? name : label.Text;
                deviceCard.Children.Add(nameRow);
                deviceCard.Children.Add(QuickText(BlipDeviceDetail(device), 11));
                deviceCard.Children.Add(label);
                var permissions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                var files = new CheckBox { Content = "Auto-receive files", FontSize = 11, MinWidth = 0, MinHeight = 28,
                    IsChecked = same && Preferences.Current.BlipAutoReceivePeers.Contains(device.Peer, StringComparer.OrdinalIgnoreCase) };
                var links = new CheckBox { Content = "Auto-open links", FontSize = 11, MinWidth = 0, MinHeight = 28,
                    IsChecked = same && Preferences.Current.BlipAutoOpenPeers.Contains(device.Peer, StringComparer.OrdinalIgnoreCase) };
                AutomationProperties.SetName(files, "Auto-receive files from " + name);
                AutomationProperties.SetName(links, "Auto-open links from " + name);
                permissions.Children.Add(files);
                permissions.Children.Add(links);
                deviceCard.Children.Add(permissions);
                content.Children.Add(new Border { Child = deviceCard, Padding = new Thickness(7), CornerRadius = new CornerRadius(6),
                    BorderThickness = new Thickness(1), BorderBrush = Brush("DividerStrokeColorDefaultBrush") });
                choices.Add((device.Peer, files, links, label, name));
            }
        }
        if(choices.Count==0)content.Children.Add(Text("No senders available yet.",12));
        var dialog=new ContentDialog{XamlRoot=root.XamlRoot,Title="Sender permissions",Content=new ScrollViewer{Content=content,MaxHeight=compact?235:440},PrimaryButtonText="Save",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close};
        if(await ShowDialog(dialog)!=ContentDialogResult.Primary||diagnosticMode||BlipOwner !=
            (account + ":" + snapshot.Status.DeviceId).ToLowerInvariant())return;
        lock(blipPolicyGate) {
            Preferences.Current.BlipAutoOpenAccount=account;
            Preferences.Current.BlipAutoOpenPeers=choices.Where(c=>c.Links.IsChecked==true).Select(c=>c.Peer).ToList();
            Preferences.Current.BlipAutoReceivePeers=choices.Where(c=>c.Files.IsChecked==true).Select(c=>c.Peer).ToList();
            Preferences.Save();
        }
        foreach (var choice in choices.Where(c => c.Name.Text != c.Initial))
            if (devices.Find(d => d.Peer == choice.Peer) is { } device)
                SaveBlipDeviceName(account, device, choice.Name.Text);
        await RefreshBlip();
    }
    private async Task StartBlip()
    {
        if (busy || diagnosticMode) return;
        await Run("Start Blip engine", async token => { blipSnapshot = null; LinkOpener.ResetSession(); await blip.StartAsync(token); Preferences.Current.BlipSeparateProfile = true; Preferences.Current.BlipAutoConnectDesktop = true; Preferences.Save(); await RefreshBlip(); }); Render();
    }
    private async Task StopBlip()
    {
        if (busy || diagnosticMode) return;
        if (BlipDesktop) { Preferences.Current.BlipAutoConnectDesktop = false; Preferences.Save(); LinkOpener.ResetSession(); await Run("Disconnect desktop Blip", async _ => { await blip.StopAsync(); blipSnapshot = null; }); Render(); return; }
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Stop Blip?", Content = Text("Ongoing transfers may pause. Received files stay on this computer. Syncthing and the separate Blip desktop app keep running."), PrimaryButtonText = "Stop Blip", CloseButtonText = "Keep running", DefaultButton = ContentDialogButton.Close };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        Preferences.Current.BlipAutoConnectDesktop = false;
        Preferences.Save();
        LinkOpener.ResetSession(); await Run("Stop Blip engine", async _ => await blip.StopAsync()); Render();
    }
    private void OpenBlipDownloads()
    {
        if (Directory.Exists(blip.DownloadsDirectory)) OpenPath(blip.DownloadsDirectory);
        else Info("No received files", "Start Blip to create a separate downloads folder for this computer.");
    }
    private async Task ConnectBlip()
    {
        if (busy || diagnosticMode) return;
        if (blipSnapshot?.Status.Registration != "CODE_SENT")
        {
            var email = new TextBox { Header = "Blip account email", PlaceholderText = "you@example.com" };
            var content = new StackPanel { Spacing = 10 }; content.Children.Add(email); content.Children.Add(Text("Request a Blip sign-in code for this computer. Your existing Blip devices remain separate.", 12));
            var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Connect Blip", Content = content, PrimaryButtonText = "Send sign-in code", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            dialog.Opened += (_, _) => email.Focus(FocusState.Programmatic);
            if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
            bool sent = false; await Run("Request Blip sign-in code", async token => { await blip.LoginAsync(email.Text.Trim(), token); sent = true; });
            if (!sent) return;
        }
        var code = new PasswordBox { Header = "Sign-in code", PlaceholderText = "Code from your email" };
        var verify = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Verify Blip", Content = code, PrimaryButtonText = "Connect", CloseButtonText = "Later", DefaultButton = ContentDialogButton.Close };
        verify.Opened += (_, _) => code.Focus(FocusState.Programmatic);
        if (await ShowDialog(verify) != ContentDialogResult.Primary) { await RefreshBlip(); return; }
        string value = code.Password.Trim(); code.Password = "";
        await Run("Verify Blip account", async token => { await blip.VerifyAsync(value, token); await RefreshBlip(); }); Render();
    }
    private async Task PasteAndSendBlip() {
        if(busy||modalDepth>0||diagnosticMode)return;
        if(blipSnapshot?.Status.Authenticated!=true){currentView="transfers";SetMode(true);Info("Connect Blip first","Open desktop Blip, then try Paste and send again.");return;}
        BlipClipboardPayload? payload=null;bool attempted=false;
        try {payload=await BlipClipboard.ReadAsync();await ShowBlipSend(payload.Paths,payload.Description,()=>attempted=true);}
        catch(Exception error){Error(error);}
        finally {if(!attempted)payload?.Discard();}
    }
    private async Task ShowBlipSend(List<string>? initialPaths=null,string? initialDescription=null,Action? sendingStarted=null)
    {
        if (busy || modalDepth > 0 || blipSnapshot?.Status.Authenticated != true) return;
        var content = new StackPanel { Spacing = 4 };
        string localPeer = blipSnapshot.Status.UserId + ":" + blipSnapshot.Status.DeviceId;
        var devices = blipSnapshot.Devices.Where(d => !d.History && !d.Peer.Equals(localPeer, StringComparison.OrdinalIgnoreCase)
                && !IsRecipientArchived(BlipOwner, d.Peer))
            .OrderBy(d => d.ContactName, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(d => d.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
        var paths = initialPaths ?? new List<string>();
        var recipients = new ListView { SelectionMode = ListViewSelectionMode.None, MaxHeight = compact ? 172 : 280 };
        AutomationProperties.SetName(recipients, "Recipient devices");
        var selected = QuickText(initialDescription ?? "", 12);
        selected.Visibility = paths.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        content.Children.Add(selected);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Send with Blip", Content = content,
            CloseButtonText = "Cancel" };
        BlipDevice? clickedPeer = null;
        bool pasteClipboard = false;
        void SelectDevice(BlipDevice device, bool paste)
        {
            if (clickedPeer != null || nativePickerDepth > 0) return;
            clickedPeer = device;
            pasteClipboard = paste;
            dialog.Hide();
        }
        Grid DestinationRow(BlipDevice device, bool grouped)
        {
            var title = QuickText(grouped ? BlipDeviceName(device) : BlipDeviceCaption(device), 13);
            var send = FlatBlipButton(QuickButton("", () => SelectDevice(device, paste: false)));
            var detail = BlipDeviceDetail(device);
            send.Content = BlipDestinationLabel(title, detail);
            send.MinHeight = 36;
            send.HorizontalAlignment = HorizontalAlignment.Stretch;
            send.HorizontalContentAlignment = HorizontalAlignment.Left;
            send.Tag = device;
            var paste = FlatBlipButton(QuickIcon("\uE77F", "Paste and send to " + title.Text + ", " + detail,
                () => SelectDevice(device, paste: true)));
            var rename = BlipRecipientOptions(BlipDeviceName(device) + ", " + detail, () =>
                EditRecipientName(dialog, content, localPeer, device, title, send, paste, grouped));
            var row = new Grid { ColumnSpacing = 4 };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            row.Children.Add(send);
            Grid.SetColumn(paste, 1);
            row.Children.Add(paste);
            Grid.SetColumn(rename, 2);
            row.Children.Add(rename);
            AutomationProperties.SetName(send, "Send to " + title.Text + ", " + detail);
            ToolTipService.SetToolTip(send, title.Text + " · " + detail);
            return row;
        }
        void AddDestination(UIElement row)
        {
            recipients.Items.Add(new ListViewItem { Content = row, MinHeight = 30, Padding = new Thickness(1, 0, 1, 0),
                HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false });
        }
        foreach (var group in BlipDevice.GroupDestinations(devices, blipSnapshot.Status.UserId))
        {
            var first = group.First();
            var contact = group.Skip(1).Any() ? BlipPersonName(first, first.Account) : null;
            if (contact != null) AddDestination(BlipContactHeading(contact, localPeer));
            foreach (var device in group.OrderByDescending(d => d.Online == true))
                AddDestination(DestinationRow(device, grouped: contact != null));
        }
        if (devices.Count > 0) content.Children.Add(recipients);
        else content.Children.Add(Text("No other Blip devices are available.", 12));

        void SetPayload(List<string> value, string description)
        {
            paths = value;
            selected.Text = description;
            ToolTipService.SetToolTip(selected, description);
            selected.Visibility = Visibility.Visible;
        }
        if (devices.Count > 0 && initialPaths == null)
        {
            var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            choices.Children.Add(QuickButton("Choose folder…", async () =>
            {
                var picker = new FolderPicker();
                InitializeWithWindow.Initialize(picker, detachedDialog == null ? hwnd : WindowNative.GetWindowHandle(detachedDialog));
                picker.FileTypeFilter.Add("*");
                var folder = await Modal(async () => await picker.PickSingleFolderAsync());
                if (folder != null) SetPayload(new() { folder.Path }, folder.Name);
            }));
            content.Children.Add(choices);
        }
        await ShowDialog(dialog, dismissMenu: true);
        if (clickedPeer is not { } peer || diagnosticMode) return;
        if (pasteClipboard) { await SendToBlipRecipient(localPeer.ToLowerInvariant(), peer, paste: true); return; }
        if (paths.Count == 0) { await SendToBlipRecipient(localPeer.ToLowerInvariant(), peer); return; }
        await DispatchBlipSend(peer, paths, localPeer, sendingStarted);
    }

    private async Task DispatchBlipSend(BlipDevice peer, List<string> paths, string localPeer, Action? sendingStarted = null)
    {
        if (blipSnapshot?.Status.Authenticated != true ||
            !string.Equals(localPeer, blipSnapshot.Status.UserId + ":" + blipSnapshot.Status.DeviceId, StringComparison.OrdinalIgnoreCase))
        {
            Info("Blip connection changed", "Open the device list again before sending.");
            return;
        }
        sendingStarted?.Invoke();
        await Run("Queue Blip transfer", async token => {
            if (!await TryQueueRelay(peer, paths, token)) {
                string id = await blip.SendAsync(peer.Peer, paths, token);
                blipSentNames[id] = paths.Count == 1 ? Path.GetFileName(paths[0]) : paths.Count + " files";
            }
            await UpdateRecentRecipients("remember", localPeer, peer);
            await RefreshBlip();
        });
        Render();
    }

    private void EditRecipientName(ContentDialog dialog, StackPanel recipients, string owner,
                                   BlipDevice device, TextBlock name, Button send, Button paste, bool grouped)
    {
        var input = new TextBox { Header = "Device name", Text = recentRecipients.Find(r =>
            r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase))?.nickname ?? device.Nickname,
            PlaceholderText = BlipDeviceName(device),
            MaxLength = 80 };
        var form = new StackPanel { Spacing = 8 };
        form.Children.Add(input);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        controls.Children.Add(QuickButton("Save name", () =>
        {
            var status = blipSnapshot?.Status;
            if (status?.Authenticated != true || !owner.Equals(status.UserId + ":" + status.DeviceId, StringComparison.OrdinalIgnoreCase))
            {
                dialog.Hide();
                return;
            }
            try { SaveBlipDeviceName(status.UserId, device, input.Text); }
            catch (IOException error) { Error(error); return; }
            name.Text = grouped ? BlipDeviceName(device) : BlipDeviceCaption(device);
            AutomationProperties.SetName(send, "Send to " + name.Text);
            ToolTipService.SetToolTip(send, name.Text);
            AutomationProperties.SetName(paste, "Paste and send to " + name.Text);
            ToolTipService.SetToolTip(paste, "Paste and send to " + name.Text);
            dialog.Content = recipients;
        }, true));
        controls.Children.Add(QuickButton("Back", () => dialog.Content = recipients));
        form.Children.Add(controls);
        dialog.Content = form;
        input.Focus(FocusState.Programmatic);
    }

    private void SaveBlipDeviceName(string account, BlipDevice device, string name)
    {
        if (!diagnosticMode) SenderCatalog.SetNicknames(account, new[] { (device.Peer, name) });
        device.Nickname = new string(name.Trim().Where(c => !char.IsControl(c)).Take(80).ToArray());
        var index = recentOwner == BlipOwner ? recentRecipients.FindIndex(r =>
            r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase)) : -1;
        if (index >= 0)
        {
            recentRecipients[index] = recentRecipients[index] with { nickname = device.Nickname };
            _ = UpdateRecentRecipients("rename", BlipOwner, target: device.Peer, name: device.Nickname);
        }
    }

    private Task AcceptBlip(BlipTransfer transfer)=>ReceiveFromBlipNotice(transfer);
}
