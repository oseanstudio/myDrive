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
                await blip.UseDesktopAsync(attachTimeout.Token).ConfigureAwait(false);
                blipSnapshot = null; LinkOpener.ResetSession();
            }
            if (blip.IsRunning)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                var freshSnapshot=await blip.PollAsync(timeout.Token).ConfigureAwait(false);
                blipFailure="";
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
                    if (ShouldAutoReceive(snapshot.Status,request) && !blipAutoAccepted.ContainsKey(request.Id) && ReceiveLedger.TryClaim(snapshot.Status.UserId,request.Id) && blipAutoAccepted.TryAdd(request.Id,0)) {

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
                    transfers = snapshot?.Transfers.Where(t => t.IsLive), blipRelayWaiting,
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
        blipIncomingWindow??=new BlipIncomingWindow(t=>_=ReceiveFromBlipNotice(t),()=>{currentView="transfers";SetMode(true);_=ChooseLinkSenders();},()=>tray?.Anchor()??AppWindow.Position);
        string name=blipSnapshot?.Devices.FirstOrDefault(d=>d.Peer.Equals(transfer.Peer,StringComparison.OrdinalIgnoreCase))?.ToString()??"Previous sender";
        blipIncomingWindow.Update(transfer,name,blipAutoAccepted.ContainsKey(transfer.Id),announce);
    }
    private async Task ReceiveFromBlipNotice(BlipTransfer transfer) {
        if(diagnosticMode||!transfer.AwaitingAcceptance||!blipAutoAccepted.TryAdd(transfer.Id,0))return;
        blipIncomingWindow?.ClearFailure();
        UpdateIncomingBlip(transfer,false);
        try{ReceiveLedger.TryClaim(blipSnapshot?.Status.UserId??"",transfer.Id);using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(15));await blip.AcceptAsync(transfer.Id,timeout.Token);}
        catch(Exception error){blipAutoAccepted.TryRemove(transfer.Id,out _);blipIncomingWindow?.ShowFailure(error.Message);}
        await RefreshBlip();
    }
    private void RenderBlip()
    {
        if (!compact) Heading("Send & Receive", "");
        bool running = BlipRunning, signedIn = blipSnapshot?.Status.Authenticated == true;
        var header = new Grid { ColumnSpacing = 6 }; header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var label = running ? signedIn ? BlipDesktop ? "Ready in the background" : blipSnapshot!.Status.ReceivePolicyVerified ? "Ready to send and receive" : "Checking receiving settings" : "Sign in to send or receive" : Preferences.Current.BlipAutoConnectDesktop ? "Preparing background Blip" : "Blip is disconnected";
        header.Children.Add(QuickText(label, compact ? 13 : 18, true));
        var refresh = QuickIcon("\uE72C", "Refresh Blip transfers", () => _ = RefreshBlip()); refresh.IsEnabled = running && !busy;
        var options = QuickIcon("\uE713", "Blip options", () => { });
        var menu = new MenuFlyout();
        var autoOpen = new ToggleMenuFlyoutItem { Text = "Open received links automatically", IsChecked = Preferences.Current.BlipAutoOpenLinks };
        autoOpen.Click += (_, _) => { if (diagnosticMode) return; Preferences.Current.BlipAutoOpenLinks = autoOpen.IsChecked; Preferences.Save(); LinkOpener.ResetSession(); };
        menu.Items.Add(autoOpen); options.Flyout = menu;
        var autoConnect = new ToggleMenuFlyoutItem { Text = "Keep Blip available in the background", IsChecked = Preferences.Current.BlipAutoConnectDesktop };
        autoConnect.Click += (_, _) => { if (diagnosticMode) return; Preferences.Current.BlipAutoConnectDesktop = autoConnect.IsChecked; Preferences.Save(); Interlocked.Exchange(ref nextDesktopBlipAttempt, 0); if (autoConnect.IsChecked) _ = RefreshBlip(); };
        menu.Items.Add(autoConnect);
        var senders = new MenuFlyoutItem { Text = "Sender permissions…", IsEnabled = signedIn };
        senders.Click += (_,_) => _ = ChooseLinkSenders(); menu.Items.Add(senders);
        if (running) MenuAction(menu, BlipDesktop ? "Disconnect Blip" : "Stop Blip", () => _ = StopBlip());
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 }; tools.Children.Add(options); tools.Children.Add(refresh); Grid.SetColumn(tools, 1); header.Children.Add(tools); page.Children.Add(header);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (!running) actions.Children.Add(QuickButton("Connect…", () => _ = ChooseBlipConnection(), true));
        else
        {
            if (signedIn) { var send = QuickButton("Send…", () => _ = ShowBlipSend(), true); send.IsEnabled = !busy; actions.Children.Add(send); }
            if (!signedIn && !BlipDesktop) actions.Children.Add(QuickButton(blipSnapshot?.Status.Registration == "CODE_SENT" ? "Enter code…" : "Connect Blip…", () => _ = ConnectBlip()));
        }
        if(signedIn)actions.Children.Add(QuickButton("Senders…",()=>_=ChooseLinkSenders()));
        actions.Children.Add(QuickButton("Received files", OpenBlipDownloads)); page.Children.Add(actions);
        if (!blip.RuntimeAvailable && !diagnosticMode) page.Children.Add(Card(Text("The myDrive Blip helper is missing. Reinstall myDrive.", 12)));
        string failure = blipFailure.Length > 0 ? blipFailure : blip.LastError;
        if (blipRelayWaiting > 0) page.Children.Add(Text($"{blipRelayWaiting} waiting for relay or delivery", 11));
        if (failure.Length > 0) page.Children.Add(Card(Text(failure, 12)));
        if (!running) page.Children.Add(Text(Preferences.Current.BlipAutoConnectDesktop ? "myDrive keeps this computer's existing Blip device available. Sign in in Blip once if needed." : "Reuse the account in desktop Blip, or start a separate Blip device for headless use.", 12));
        if (running && BlipDesktop && !signedIn) page.Children.Add(Text("Sign in in the Blip desktop app, then refresh here.", 12));
        if (running && !signedIn && !BlipDesktop) page.Children.Add(Text("Use your Blip account to connect this computer as a separate device. Sign-in starts only when you choose Connect Blip.", 12));
        if (running && signedIn && !BlipDesktop && blipSnapshot?.Status.ReceivePolicyVerified != true) page.Children.Add(Text("Wait for receiving settings to verify before sending files to this computer.", 12));
        var transfers = blipSnapshot?.Transfers.Where(transfer => transfer.IsLive).ToList();
        if (transfers is { Count: > 0 })
        {
            // ListView virtualizes rows and keeps the compact window at the existing fixed size.
            var list = new ListView { SelectionMode = ListViewSelectionMode.None, MaxHeight = compact ? 215 : 480, HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var transfer in transfers) list.Items.Add(BlipTransferRow(transfer));
            page.Children.Add(list);
        }
    }
    private UIElement BlipTransferRow(BlipTransfer transfer)
    {
        var row = new Grid { ColumnSpacing = 6, MinHeight = 44, Padding = new Thickness(0, 3, 0, 3) };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        string peer = blipSnapshot?.Devices.FirstOrDefault(d => d.Peer.Equals(transfer.Peer, StringComparison.OrdinalIgnoreCase))?.ToString() ?? "Previous device";
        string title = blipSentNames.GetValueOrDefault(transfer.Id, (transfer.Direction == "Incoming" ? "From " : "To ") + peer);
        var detail = new StackPanel { Spacing = 2 }; detail.Children.Add(QuickText(title, 13, true)); detail.Children.Add(QuickText(transfer.ProgressLabel + (BlipRunning ? "" : " · last known"), 12)); row.Children.Add(detail);
        ToolTipService.SetToolTip(row, title + "\n" + transfer.Id + "\n" + transfer.Peer); AutomationProperties.SetName(row, title + ", " + transfer.StateLabel);
        if (transfer.AwaitingAcceptance && blipAutoAccepted.ContainsKey(transfer.Id))
        {
            var receiving=QuickText("Receiving…",12);Grid.SetColumn(receiving,1);row.Children.Add(receiving);
        }
        else if (transfer.AwaitingAcceptance)
        {
            var accept = QuickButton("Receive", () => _ = AcceptBlip(transfer)); accept.IsEnabled = BlipRunning && blipSnapshot?.Status.Authenticated == true && (BlipDesktop || blipSnapshot.Status.ReceivePolicyVerified) && !busy; Grid.SetColumn(accept, 1); row.Children.Add(accept);
        }
        return row;
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
        { await Run("Connect to desktop Blip", async token => { blipSnapshot = null; LinkOpener.ResetSession(); await blip.UseDesktopAsync(token); Preferences.Current.BlipAutoConnectDesktop = true; Preferences.Save(); await RefreshBlip(); }); Render(); }
        else await StartBlip();
    }
    private async Task ChooseLinkSenders()
    {
        if(busy||blipSnapshot?.Status.Authenticated!=true)return;
        if(!diagnosticMode)await RefreshBlip();
        var snapshot=blipSnapshot;if(snapshot?.Status.Authenticated!=true)return;
        var account=snapshot.Status.UserId;bool same=Preferences.Current.BlipAutoOpenAccount.Equals(account,StringComparison.OrdinalIgnoreCase);
        var content=new StackPanel{Spacing=7,MaxWidth=compact?274:460};
        var choices=new List<(string Peer,CheckBox Files,CheckBox Links,TextBox Name,string Initial,string Nickname)>();
        var devices=snapshot.Devices.Where(d=>BlipTrustPolicy.ExactPeer(d.Peer)&&!d.Peer.Equals(account+":"+snapshot.Status.DeviceId,StringComparison.OrdinalIgnoreCase)).ToList();
        foreach(var group in devices.GroupBy(d=>d.Peer.Split(':')[0],StringComparer.OrdinalIgnoreCase)) {
            string person = group.Key.Equals(account, StringComparison.OrdinalIgnoreCase)
                ? "Your devices"
                : group.Select(d => d.ContactName).FirstOrDefault(n => !string.IsNullOrWhiteSpace(n)) ?? "Previous sender";
            var heading = QuickText(person, 13, true);
            ToolTipService.SetToolTip(heading, person);
            content.Children.Add(heading);
            foreach(var device in group.OrderBy(d=>d.Name).ThenBy(d=>d.Peer)) {
                string name = device.DisplayName;
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
                choices.Add((device.Peer, files, links, label, name, device.Nickname));
            }
        }
        if(choices.Count==0)content.Children.Add(Text("No senders available yet.",12));
        var dialog=new ContentDialog{XamlRoot=root.XamlRoot,Title="Sender permissions",Content=new ScrollViewer{Content=content,MaxHeight=compact?235:440},PrimaryButtonText="Save",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close};
        if(await ShowDialog(dialog)!=ContentDialogResult.Primary||diagnosticMode)return;
        lock(blipPolicyGate) {
            Preferences.Current.BlipAutoOpenAccount=account;
            Preferences.Current.BlipAutoOpenPeers=choices.Where(c=>c.Links.IsChecked==true).Select(c=>c.Peer).ToList();
            Preferences.Current.BlipAutoReceivePeers=choices.Where(c=>c.Files.IsChecked==true).Select(c=>c.Peer).ToList();
            Preferences.Save();
        }
        SenderCatalog.SetNicknames(account,choices.Select(c=>(c.Peer,c.Name.Text==c.Initial?c.Nickname:c.Name.Text)));
        await RefreshBlip();
    }
    private async Task StartBlip()
    {
        if (busy || diagnosticMode) return;
        await Run("Start Blip engine", async token => { blipSnapshot = null; LinkOpener.ResetSession(); await blip.StartAsync(token); Preferences.Current.BlipAutoConnectDesktop = false; Preferences.Save(); await RefreshBlip(); }); Render();
    }
    private async Task StopBlip()
    {
        if (busy || diagnosticMode) return;
        if (BlipDesktop) { Preferences.Current.BlipAutoConnectDesktop = false; Preferences.Save(); LinkOpener.ResetSession(); await Run("Disconnect desktop Blip", async _ => { await blip.StopAsync(); blipSnapshot = null; }); Render(); return; }
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Stop Blip?", Content = Text("Ongoing transfers may pause. Received files stay on this computer. Syncthing and the separate Blip desktop app keep running."), PrimaryButtonText = "Stop Blip", CloseButtonText = "Keep running", DefaultButton = ContentDialogButton.Close };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
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
            if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
            bool sent = false; await Run("Request Blip sign-in code", async token => { await blip.LoginAsync(email.Text.Trim(), token); sent = true; });
            if (!sent) return;
        }
        var code = new PasswordBox { Header = "Sign-in code", PlaceholderText = "Code from your email" };
        var verify = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Verify Blip", Content = code, PrimaryButtonText = "Connect", CloseButtonText = "Later", DefaultButton = ContentDialogButton.Close };
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
        var content = new StackPanel { Spacing = 10 };
        string localPeer = blipSnapshot.Status.UserId + ":" + blipSnapshot.Status.DeviceId;
        var devices = blipSnapshot.Devices.Where(d => !d.History && !d.Peer.Equals(localPeer, StringComparison.OrdinalIgnoreCase))
            .OrderBy(d => d.ContactName, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(d => d.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
        var paths = initialPaths ?? new List<string>();
        var recipients = new ListView { SelectionMode = ListViewSelectionMode.None, MaxHeight = compact ? 172 : 280 };
        AutomationProperties.SetName(recipients, "Recipient devices");
        var instruction = Text(paths.Count > 0 ? "Click a device to send." : "Choose files or a folder, then click a device to send.", 12);
        if (devices.Count > 0) content.Children.Add(instruction);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = "Send with Blip", Content = content,
            CloseButtonText = "Cancel" };
        BlipDevice? clickedPeer = null;
        var sendButtons = new List<Button>();
        foreach (var device in devices)
        {
            var title = QuickText(device.ToString(), 13);
            var send = QuickButton("", () =>
            {
                if (clickedPeer != null || nativePickerDepth > 0 || paths.Count == 0) return;
                clickedPeer = device;
                dialog.Hide();
            });
            send.Content = title;
            send.HorizontalAlignment = HorizontalAlignment.Stretch;
            send.HorizontalContentAlignment = HorizontalAlignment.Left;
            send.IsEnabled = paths.Count > 0;
            send.Tag = device;
            sendButtons.Add(send);
            var rename = QuickIcon("\uE70F", "Rename " + device.DisplayName, () =>
                EditRecipientName(dialog, content, localPeer, device, title, send));
            var row = new Grid { ColumnSpacing = 4 };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            row.Children.Add(send);
            Grid.SetColumn(rename, 1);
            row.Children.Add(rename);
            AutomationProperties.SetName(send, "Send to " + title.Text);
            ToolTipService.SetToolTip(send, title.Text);
            recipients.Items.Add(new ListViewItem { Content = row, MinHeight = 36, Padding = new Thickness(2),
                HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false });
        }
        if (devices.Count > 0) content.Children.Add(recipients);
        else content.Children.Add(Text("No other Blip devices are available.", 12));

        var selected = QuickText(initialDescription ?? "", 12);
        selected.Visibility = paths.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        content.Children.Add(selected);
        void SetPayload(List<string> value, string description)
        {
            paths = value;
            selected.Text = description;
            ToolTipService.SetToolTip(selected, description);
            selected.Visibility = Visibility.Visible;
            instruction.Text = "Click a device to send.";
            foreach (var send in sendButtons) send.IsEnabled = true;
            sendButtons.FirstOrDefault()?.Focus(FocusState.Programmatic);
        }
        if (devices.Count > 0 && initialPaths == null)
        {
            var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            choices.Children.Add(QuickButton("Choose files…", async () =>
            {
                var picker = new FileOpenPicker();
                InitializeWithWindow.Initialize(picker, hwnd);
                picker.FileTypeFilter.Add("*");
                var files = await Modal(async () => await picker.PickMultipleFilesAsync());
                if (files.Count > 0) SetPayload(files.Select(f => f.Path).ToList(),
                    files.Count == 1 ? files[0].Name : files.Count + " files selected");
            }));
            choices.Children.Add(QuickButton("Choose folder…", async () =>
            {
                var picker = new FolderPicker();
                InitializeWithWindow.Initialize(picker, hwnd);
                picker.FileTypeFilter.Add("*");
                var folder = await Modal(async () => await picker.PickSingleFolderAsync());
                if (folder != null) SetPayload(new() { folder.Path }, folder.Name);
            }));
            content.Children.Insert(1, choices);
        }
        await ShowDialog(dialog);
        if (clickedPeer is not { } peer || diagnosticMode) return;
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
            await RefreshBlip();
        });
        Render();
    }

    private void EditRecipientName(ContentDialog dialog, StackPanel recipients, string owner,
                                   BlipDevice device, TextBlock name, Button send)
    {
        var input = new TextBox { Header = "Device name", Text = device.Nickname, PlaceholderText = device.DisplayName,
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
            if (!diagnosticMode)
            {
                try { SenderCatalog.SetNicknames(status.UserId, new[] { (device.Peer, input.Text) }); }
                catch (IOException error) { Error(error); return; }
            }
            device.Nickname = new string(input.Text.Trim().Where(c => !char.IsControl(c)).Take(80).ToArray());
            device.SelectionName = "";
            name.Text = device.ToString();
            AutomationProperties.SetName(send, "Send to " + name.Text);
            ToolTipService.SetToolTip(send, name.Text);
            dialog.Content = recipients;
        }, true));
        controls.Children.Add(QuickButton("Back", () => dialog.Content = recipients));
        form.Children.Add(controls);
        dialog.Content = form;
        input.Focus(FocusState.Programmatic);
    }
    private Task AcceptBlip(BlipTransfer transfer)=>ReceiveFromBlipNotice(transfer);
}
