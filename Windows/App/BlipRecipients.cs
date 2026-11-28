using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;
using System.Text.Json.Serialization;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace MyDrive;

public sealed partial class MainWindow
{
    private sealed record RecentRecipient(string peer, string label, string? person = null, string? device = null,
                                          string? nickname = null, string? person_nickname = null,
                                          string? archived = null)
    {
        [JsonIgnore] public string Account => peer.Split(':')[0];
        [JsonIgnore] public string FallbackLabel
        {
            get
            {
                var parts = label.Split(" · ", 2);
                if (parts.Length == 2 && DeviceType(parts[1])) return parts[0];
                return DeviceType(label) ? "Device" : label;
            }
        }
        private static bool DeviceType(string name)
        {
            var parts = name.Split(' ', 2);
            return (parts[0] is "Desktop" or "Laptop" or "Tablet" or "Phone") &&
                (parts.Length == 1 || int.TryParse(parts[1], out _));
        }
    }
    private List<RecentRecipient> recentRecipients = new();
    private List<BlipDevice> directoryRecipients = new();
    private readonly SemaphoreSlim recentGate = new(1, 1);
    private readonly SemaphoreSlim recipientSearchGate = new(1, 1);
    private string recentOwner = "", recipientQuery = "", searchedQuery = "", searchMessage = "";
    private CancellationTokenSource? recipientLookup;
    private CancellationTokenSource? activeRecipientLookup;
    private bool archivesExpanded;
    private TextBox? recipientInput;
    private StackPanel? recipientRows;

    private string BlipOwner => blipSnapshot?.Status is { Authenticated: true } status
        ? status.UserId.ToLowerInvariant() + ":" + status.DeviceId.ToLowerInvariant() : "";

    private bool IsRecipientArchived(string owner, string peer) => recentOwner == owner &&
        recentRecipients.Any(r => r.archived != null && r.peer.Equals(peer, StringComparison.OrdinalIgnoreCase));

    private List<BlipDevice> KnownRecipients(string owner) => (blipSnapshot?.Devices ?? new())
        .Where(d => !d.History && BlipTrustPolicy.ExactPeer(d.Peer) &&
            !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase))
        .DistinctBy(d => d.Peer, StringComparer.OrdinalIgnoreCase).ToList();

    private List<BlipDevice> KnownPeople(string owner) => (blipSnapshot?.People ?? [])
        .Where(d => d.IsPerson && !d.Account.Equals(owner.Split(':')[0], StringComparison.OrdinalIgnoreCase))
        .DistinctBy(d => d.Account, StringComparer.OrdinalIgnoreCase).ToList();

    private RecentRecipient Recent(BlipDevice device) => new(device.Peer, BlipDeviceCaption(device),
        device.ContactName, device.HasDeviceName ? device.DisplayName : null);

    private string BlipDeviceName(BlipDevice device)
    {
        var recent = recentOwner == BlipOwner ? recentRecipients.Find(r =>
            r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase)) : null;
        var known = blipSnapshot?.Devices.Find(d => d.Peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase));
        var saved = recent?.device;
        if (saved != null && BlipTrustPolicy.ExactPeer(device.Peer) &&
            saved.EndsWith(" " + device.Peer[^6..], StringComparison.OrdinalIgnoreCase))
            saved = saved[..^7];
        return FirstName(recent?.nickname, known?.Nickname, device.HasDeviceName ? device.BaseLabel : null,
            known?.HasRegisteredName == true ? known.Name : null, saved, known?.BaseLabel, device.BaseLabel);
    }

    private string BlipDeviceDetail(BlipDevice device, string? caption = null)
    {
        var status = device.History ? "Previously seen" : device.Online switch
        {
            true => "Online",
            false => "Offline",
            _ => "Status unknown"
        };
        if (!device.IsPerson && caption != null && caption.Equals(BlipPersonName(device, device.Account), StringComparison.CurrentCultureIgnoreCase))
        {
            var deviceName = BlipDeviceName(device);
            if (!caption.Equals(deviceName, StringComparison.CurrentCultureIgnoreCase))
                status = deviceName + " · " + status;
        }
        var last = (blipSnapshot?.Transfers ?? []).Where(t => t.Direction == "Outgoing" && t.ConfirmedComplete &&
                t.Peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase))
            .Select(t => t.UpdatedAt).DefaultIfEmpty().Max();
        return last is > 0 and <= 253402300799
            ? status + " · Sent " + DateTimeOffset.FromUnixTimeSeconds(last).ToLocalTime().ToString("g")
            : status;
    }

    private static Grid BlipSendingLabel(TextBlock title)
    {
        var heading = new Grid { ColumnSpacing = 6, HorizontalAlignment = HorizontalAlignment.Left };
        heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var sending = QuickText("Sending", 11);
        sending.Opacity = .70;
        sending.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(sending, 1);
        heading.Children.Add(title);
        heading.Children.Add(sending);
        return heading;
    }

    private static StackPanel BlipDestinationLabel(TextBlock title, string detail, bool sending = false)
    {
        var summary = QuickText(detail, 11);
        summary.Opacity = .70;
        var text = new StackPanel { Spacing = 1, IsHitTestVisible = false };
        text.Children.Add(sending ? BlipSendingLabel(title) : title);
        text.Children.Add(summary);
        return text;
    }

    private static Button FlatBlipButton(Button button)
    {
        button.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.BorderThickness = new Thickness(0);
        return button;
    }

    private string BlipDeviceCaption(BlipDevice device)
    {
        var name = BlipDeviceName(device);
        var account = device.Peer.Split(':')[0];
        var known = (blipSnapshot?.Devices ?? []).Concat(directoryRecipients);
        var recent = recentRecipients.Find(r => r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase));
        var person = BlipPersonName(device, account);
        if (device.IsPerson) return person ?? "Blip user";
        bool distinguish = !string.IsNullOrWhiteSpace(recent?.nickname) ||
            !string.IsNullOrWhiteSpace(device.Nickname) ||
            (device.HasDeviceName && known.Any(other => !other.History && !other.Peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase) &&
                other.Peer.StartsWith(account + ":", StringComparison.OrdinalIgnoreCase) &&
                !IsRecipientArchived(BlipOwner, other.Peer)));
        return device.RecipientCaption(BlipOwner.Split(':')[0], name, person, distinguish);
    }

    private string BlipGroupDeviceCaption(BlipDevice device, bool grouped) =>
        grouped && device.HasDeviceName ? BlipDeviceName(device) : BlipDeviceCaption(device);

    private string? BlipPersonName(BlipDevice device, string account)
    {
        var saved = recentRecipients.Where(r => r.Account.Equals(account, StringComparison.OrdinalIgnoreCase));
        var known = (blipSnapshot?.People ?? []).Concat(directoryRecipients).Append(device).Concat(blipSnapshot?.Devices ?? [])
            .Where(other => other.Account.Equals(account, StringComparison.OrdinalIgnoreCase)).ToArray();
        var usernames = known.OrderBy(other => other.History).Select(other => other.UserName)
            .Concat(saved.Select(r => r.person))
            .Where(name => !string.IsNullOrWhiteSpace(name) &&
                !known.Any(other => string.Equals(other.Contact, name, StringComparison.OrdinalIgnoreCase)));
        return saved.Where(r => r.peer.EndsWith(':')).Select(r => r.nickname)
            .Concat(saved.Select(r => r.person_nickname)).Concat(usernames)
            .Concat(known.Select(other => other.Contact))
            .Concat(saved.Select(r => r.person ?? r.FallbackLabel).Where(label => label != "Device"))
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim();
    }

    private string BlipPeerCaption(string peer) => (blipSnapshot?.Devices ?? []).Concat(blipSnapshot?.People ?? []).Concat(directoryRecipients)
        .FirstOrDefault(d => d.Peer.Equals(peer, StringComparison.OrdinalIgnoreCase)) is { } device
        ? BlipDeviceCaption(device) : BlipDeviceCaption(new BlipDevice { Peer = peer });

    private async Task UpdateRecentRecipients(string action, string owner, BlipDevice? recipient = null,
                                              string? target = null, string? name = null)
    {
        if (diagnosticMode || !BlipTrustPolicy.ExactPeer(owner)) return;
        await recentGate.WaitAsync();
        try
        {
            var names = KnownRecipients(owner).Concat(KnownPeople(owner)).ToDictionary(d => d.Peer, Recent, StringComparer.OrdinalIgnoreCase);
            var seed = (blipSnapshot?.Transfers ?? new())
                .Where(t => t.Direction == "Outgoing" && t.ConfirmedComplete && !IsRelayPacket(t) && names.ContainsKey(t.Peer))
                .OrderByDescending(t => t.UpdatedAt).DistinctBy(t => t.Peer, StringComparer.OrdinalIgnoreCase).Take(24)
                .Select(t => names[t.Peer]).ToArray();
            var result = await CoreBridge.Call(new { action = "blip.recents." + action, data_dir = CoreBridge.DataDir,
                payload = new { owner, seed, recipient = recipient == null ? null : Recent(recipient), target, name } });
            if (owner == BlipOwner && owner == recentOwner)
            {
                recentRecipients = result.Deserialize<List<RecentRecipient>>() ?? new();
                RenderRecipientRows();
            }
        }
        catch (Exception error)
        {
            if (owner == BlipOwner)
            {
                recentOwner = "";
                searchMessage = error.Message;
                RenderRecipientRows();
            }
        }
        finally { recentGate.Release(); }
    }

    private void RenderBlipRecipients()
    {
        var owner = BlipOwner;
        if (recentOwner != owner)
        {
            recentOwner = owner;
            recentRecipients = new();
            archivesExpanded = false;
            recipientQuery = searchedQuery = searchMessage = "";
            directoryRecipients = new();
            recipientLookup?.Cancel();
            recipientLookup = null;
            if (owner.Length > 0) _ = UpdateRecentRecipients("list", owner);
        }
        bool focus = recipientInput?.FocusState is FocusState.Keyboard or FocusState.Pointer;
        var search = new TextBox { PlaceholderText = "Find people & devices", Text = recipientQuery, MaxLength = 254,
            IsEnabled = owner.Length > 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        recipientInput = search;
        AutomationProperties.SetName(search, "Find people & devices");
        search.TextChanged += (_, _) => SetRecipientQuery(search.Text);
        search.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter) { e.Handled = true; QueueRecipientLookup(immediate: true); }
            if (e.Key == VirtualKey.Escape && search.Text.Length > 0) { e.Handled = true; search.Text = ""; }
            if (e.Key == VirtualKey.Down && recipientQuery.Trim().Length > 0 &&
                recipientRows?.Children.OfType<Grid>().SelectMany(row => row.Children.OfType<Button>())
                    .FirstOrDefault(button => button.IsEnabled) is { } suggestion)
            {
                e.Handled = true;
                suggestion.Focus(FocusState.Keyboard);
            }
        };
        var find = QuickIcon("\uE721", "Search Blip by name or email", () => QueueRecipientLookup(immediate: true));
        find.IsEnabled = search.IsEnabled;
        var input = new Grid { ColumnSpacing = 4 };
        input.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        input.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        input.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        input.Children.Add(QuickIcon("\uE8B7", "Received files", OpenBlipDownloads));
        Grid.SetColumn(search, 1);
        input.Children.Add(search);
        Grid.SetColumn(find, 2);
        input.Children.Add(find);
        ToolTipService.SetToolTip(search, "Search by name, email address, or device name");
        page.Children.Add(input);
        recipientRows = new StackPanel { Spacing = 3 };
        page.Children.Add(recipientRows);
        RenderRecipientRows();
        if (focus && search.IsEnabled) { search.Focus(FocusState.Keyboard); search.SelectionStart = search.Text.Length; }
    }

    private void SetRecipientQuery(string query)
    {
        recipientQuery = query;
        QueueRecipientLookup();
    }

    private void QueueRecipientLookup(bool immediate = false)
    {
        string owner = BlipOwner, query = recipientQuery.Trim();
        if (diagnosticMode) { RenderRecipientRows(); return; }
        if (query.Equals(searchedQuery, StringComparison.OrdinalIgnoreCase) &&
            (!immediate || recipientLookup != null && recipientLookup == activeRecipientLookup)) return;
        recipientLookup?.Cancel();
        recipientLookup = null;
        searchedQuery = query;
        searchMessage = "";
        directoryRecipients = new();
        if (owner.Length > 0 && query.Length > 0)
        {
            recipientLookup = new CancellationTokenSource();
            searchMessage = "Searching Blip…";
            _ = SearchBlipRecipients(owner, query, recipientLookup, immediate);
        }
        RenderRecipientRows();
    }

    private async Task SearchBlipRecipients(string owner, string query, CancellationTokenSource lookup, bool immediate)
    {
        bool current() => lookup == recipientLookup && owner == BlipOwner && !quitting;
        try
        {
            if (!immediate) await Task.Delay(350, lookup.Token);
            await recipientSearchGate.WaitAsync(lookup.Token);
            try
            {
                if (!current()) return;
                activeRecipientLookup = lookup;
                var matches = await blip.SearchAsync(query);
                if (current()) { directoryRecipients = matches; searchMessage = ""; }
            }
            finally
            {
                activeRecipientLookup = null;
                recipientSearchGate.Release();
            }
        }
        catch (OperationCanceledException) when (lookup.IsCancellationRequested) { }
        catch (Exception error) { if (current()) searchMessage = error.Message; }
        finally
        {
            if (current()) RenderRecipientRows();
            if (recipientLookup == lookup) recipientLookup = null;
            lookup.Dispose();
        }
    }

    private void RenderRecipientRows()
    {
        if (recipientRows is not { } rows || currentView != "transfers") return;
        rows.Children.Clear();
        string owner = BlipOwner, query = recipientQuery.Trim();
        if (owner.Length == 0) return;
        var active = LiveBlipSends();
        void AddUnlistedSends()
        {
            int index = 0;
            foreach (var group in active.GroupBy(item => item.Transfer.Peer, StringComparer.OrdinalIgnoreCase))
            {
                string name = BlipPeerCaption(group.Key);
                var row = new Grid { ColumnSpacing = 4 };
                row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                row.Children.Add(BlipSendingLabel(QuickText(name, 12)));
                var cancel = CancelBlipSendingItems(name, group.ToList());
                Grid.SetColumn(cancel, 1);
                row.Children.Add(cancel);
                rows.Children.Insert(index++, row);
            }
        }
        var ownAccount = owner.Split(':')[0];
        var devices = KnownRecipients(owner).Where(d => !IsRecipientArchived(owner, d.Peer)).ToList();
        var knownAccounts = devices.Select(d => d.Account).Concat(recentRecipients.Where(entry => entry.archived == null)
            .Select(entry => entry.Account)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var people = KnownPeople(owner).Where(d => (d.Recent || knownAccounts.Contains(d.Account)) &&
            !IsRecipientArchived(owner, d.Peer)).ToList();
        if (query.Length > 0)
        {
            bool searched = query.Equals(searchedQuery, StringComparison.OrdinalIgnoreCase);
            var matches = (searched ? directoryRecipients : []).Concat(people.Concat(devices).Where(d => new[] {
                    d.ContactName, d.Contact, BlipDeviceName(d), d.Name,
                    BlipPersonName(d, d.Account) ?? "" }
                .Any(text => text.Contains(query, StringComparison.CurrentCultureIgnoreCase))))
                .Where(d => (d.IsPerson || BlipTrustPolicy.ExactPeer(d.Peer)) && !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase)
                    && !IsRecipientArchived(owner, d.Peer))
                .DistinctBy(d => d.Peer, StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(d => d.Contact.Equals(query, StringComparison.OrdinalIgnoreCase))
                .ThenBy(BlipDeviceCaption, StringComparer.CurrentCultureIgnoreCase).ToList();
            var personMatches = matches.Where(d => d.IsPerson).Select(d => d.Account).ToHashSet(StringComparer.OrdinalIgnoreCase);
            matches = matches.Where(d => d.IsPerson || !personMatches.Contains(d.Account)).Take(30).ToList();
            if (matches.Count > 0) rows.Children.Add(QuickText("Suggestions", 12, true));
            foreach (var device in matches)
            {
                var name = BlipDeviceCaption(device);
                var email = device.Contact;
                if (email.Contains('@') && !email.Equals(name, StringComparison.OrdinalIgnoreCase))
                    AddRecipientRow(rows, owner, name, device, null, active, suggestionDetail: email);
                else
                    AddRecipientRow(rows, owner, name, device, null, active);
            }
            if (searched && searchMessage.Length > 0) rows.Children.Add(QuickText(searchMessage, 12));
            else if (matches.Count == 0) rows.Children.Add(QuickText("No matching people or devices.", 12));
            AddUnlistedSends();
            return;
        }
        var myDevices = devices.Where(d => d.Peer.StartsWith(ownAccount + ":", StringComparison.OrdinalIgnoreCase))
            .OrderBy(d => d.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
        var saved = recentRecipients.Where(r => r.archived == null &&
            !r.Account.Equals(ownAccount, StringComparison.OrdinalIgnoreCase)).ToList();
        var byAccount = people.ToDictionary(d => d.Account, StringComparer.OrdinalIgnoreCase);
        var previous = saved.Select(r => r.Account).Concat(people.Where(d => d.Recent).Select(d => d.Account))
            .Distinct(StringComparer.OrdinalIgnoreCase).Where(account => !IsRecipientArchived(owner, account + ":"))
            .Select(account => byAccount.GetValueOrDefault(account) ?? new BlipDevice { Peer = account + ":", History = true })
            .ToList();
        var recentAccounts = previous.Select(d => d.Account).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var others = people.Where(d => !recentAccounts.Contains(d.Account)).OrderBy(BlipDeviceCaption, StringComparer.CurrentCultureIgnoreCase).ToList();
        void AddPeople(string heading, List<BlipDevice> group)
        {
            if (group.Count == 0) return;
            rows.Children.Add(QuickText(heading, 12, true));
            foreach (var person in group)
            {
                var alias = saved.Find(r => r.peer.Equals(person.Peer, StringComparison.OrdinalIgnoreCase))?.nickname
                    ?? saved.Find(r => r.Account.Equals(person.Account, StringComparison.OrdinalIgnoreCase))?.person_nickname;
                AddRecipientRow(rows, owner, BlipDeviceCaption(person), person, person.Peer, active, alias);
            }
        }
        AddPeople("Recent recipients", previous);
        rows.Children.Add(QuickText("My devices", 12, true));
        if (myDevices.Count == 0) rows.Children.Add(QuickText("No other devices on this Blip account.", 11));
        foreach (var device in myDevices)
        {
            var recent = recentRecipients.Find(r => r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase));
            AddRecipientRow(rows, owner, BlipDeviceName(device), device, null, active, deviceShortcut: true, nickname: recent?.nickname);
        }
        AddPeople("Other people", others);
        var archived = recentRecipients.Where(r => r.archived != null).ToList();
        if (archived.Count > 0)
        {
            var contents = new StackPanel { Spacing = 3 };
            foreach (var entry in archived)
            {
                var device = (blipSnapshot?.Devices ?? []).Concat(blipSnapshot?.People ?? [])
                    .FirstOrDefault(d => d.Peer.Equals(entry.peer, StringComparison.OrdinalIgnoreCase))
                    ?? new BlipDevice { Peer = entry.peer };
                var name = device.IsPerson ? BlipDeviceCaption(device) : device.RecipientCaption(ownAccount,
                    BlipDeviceName(device), BlipPersonName(device, device.Account), showDevice: true);
                var entryRow = new Grid { ColumnSpacing = 4 };
                entryRow.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                entryRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                entryRow.Children.Add(QuickText(name, 12));
                var restore = QuickButton("Restore", () => _ = UpdateRecentRecipients("restore", owner, target: entry.peer));
                AutomationProperties.SetName(restore, "Restore " + name);
                Grid.SetColumn(restore, 1);
                entryRow.Children.Add(restore);
                contents.Children.Add(entryRow);
            }
            var collection = new Expander { Header = "Archived", IsExpanded = archivesExpanded,
                Content = contents, HorizontalAlignment = HorizontalAlignment.Stretch };
            collection.Expanding += (_, _) => archivesExpanded = true;
            collection.Collapsed += (_, _) => archivesExpanded = false;
            rows.Children.Add(collection);
        }
        AddUnlistedSends();
    }

    private static Button BlipRecipientOptions(string name, Action? permissions = null, Action? edit = null, Action? remove = null,
                                              Action? connectParsec = null, Action? editParsec = null)
    {
        var options = FlatBlipButton(QuickIcon("\uE713", "Options for " + name, () => { }));
        var menu = new MenuFlyout();
        if (permissions != null) MenuAction(menu, "Sender permissions…", permissions);
        if (edit != null) MenuAction(menu, "Edit name…", edit);
        if (connectParsec != null) MenuAction(menu, "Connect with Parsec", connectParsec);
        if (editParsec != null) MenuAction(menu, "Edit Parsec computer…", editParsec);
        if (remove != null) MenuAction(menu, "Remove", remove);
        options.Flyout = menu;
        return options;
    }

    private static Button BlipPasteButton(string name, Action paste)
    {
        var button = QuickButton("Paste", paste);
        button.MinWidth = 55;
        AutomationProperties.SetName(button, "Paste and send to " + name);
        ToolTipService.SetToolTip(button, "Paste and send to " + name);
        return button;
    }

    private static string FirstName(params string?[] names) =>
        names.FirstOrDefault(name => !string.IsNullOrWhiteSpace(name)) ?? "Device";

    private async Task RenameRecentRecipient(string owner, string target, string name, string? nickname, bool person,
                                             BlipDevice? recipient = null)
    {
        var edited = await PromptBlipName(owner, name, nickname, person);
        if (edited == null) return;
        if (!person && blipSnapshot is { } snapshot &&
            snapshot.Devices.Find(d => d.Peer.Equals(target, StringComparison.OrdinalIgnoreCase)) is { } device)
        {
            SaveBlipDeviceName(snapshot.Status.UserId, device, edited);
            RenderRecipientRows();
        }
        else await UpdateRecentRecipients("rename", owner, recipient, target: target, name: edited);
    }

    private async Task<string?> PromptBlipName(string owner, string name, string? nickname, bool person)
    {
        if (busy || modalDepth > 0 || diagnosticMode || owner != BlipOwner) return null;
        var input = new TextBox { Text = nickname ?? "", PlaceholderText = name, MaxLength = 80 };
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, Title = person ? "Person name" : "Device name",
            Content = input, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        dialog.Opened += (_, _) => input.Focus(FocusState.Programmatic);
        return await ShowDialog(dialog) == ContentDialogResult.Primary && owner == BlipOwner ? input.Text : null;
    }

    private async Task RenameBlipDevice(string owner, string name, BlipDevice device, string? nickname)
    {
        var edited = await PromptBlipName(owner, name, nickname ?? device.Nickname, false);
        if (edited == null || blipSnapshot?.Status is not { } status) return;
        try
        {
            SaveBlipDeviceName(status.UserId, device, edited);
            RenderRecipientRows();
        }
        catch (IOException error) { Error(error); }
    }

    private void AddRecipientRow(StackPanel rows, string owner, string name, BlipDevice device, string? remove,
                                 List<BlipSendingItem> active, string? nickname = null, bool deviceShortcut = false, string? suggestionDetail = null)
    {
        var row = new Grid { ColumnSpacing = 4 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var detail = BlipDeviceDetail(device, name);
        if (suggestionDetail != null) detail = suggestionDetail + " · " + detail;
        var sends = active.Where(item => string.Equals(item.Transfer.Peer, device.Peer, StringComparison.OrdinalIgnoreCase) ||
            (device.IsPerson && SameBlipAccount(item.Transfer.Peer, device.Account))).ToList();
        active.RemoveAll(sends.Contains);
        var title = BlipDestinationLabel(QuickText(name, 12), detail, sends.Count > 0);
        if (device.History) row.Children.Add(new Border { Child = title, Padding = new Thickness(7, 3, 0, 3) });
        else
        {
            var send = FlatBlipButton(QuickButton("", () => _ = SendToBlipRecipient(owner, device)));
            send.Content = title;
            send.Padding = new Thickness(7, 2, 4, 2);
            send.MinHeight = 36;
            send.HorizontalAlignment = HorizontalAlignment.Stretch;
            send.HorizontalContentAlignment = HorizontalAlignment.Left;
            send.IsEnabled = BlipRunning && !busy;
            AutomationProperties.SetName(send, "Send files to " + name + ", " + detail);
            ToolTipService.SetToolTip(send, name + " · " + detail);
            var alternatives = new MenuFlyout();
            MenuAction(alternatives, "Send folder…", () => _ = SendToBlipRecipient(owner, device, folder: true));
            MenuAction(alternatives, "Paste and send", () => _ = SendToBlipRecipient(owner, device, paste: true));
            MenuAction(alternatives, "Connect with Parsec", () => _ = ConnectParsec(owner, device));
            MenuAction(alternatives, "Edit Parsec computer…", () => _ = ConnectParsec(owner, device, edit: true));
            send.ContextFlyout = alternatives;
            row.Children.Add(send);
            EnableRecipientDrop(row, owner, device, name);
        }
        if (!device.History || remove != null || deviceShortcut || sends.Count > 0)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
            if (sends.Count > 0) actions.Children.Add(CancelBlipSendingItems(name, sends));
            if (!device.History)
            {
                var paste = BlipPasteButton(name,
                    () => _ = SendToBlipRecipient(owner, device, paste: true));
                paste.IsEnabled = BlipRunning && !busy;
                actions.Children.Add(paste);
            }
            actions.Children.Add(BlipRecipientOptions(name,
                permissions: () => { if (owner == BlipOwner) _ = ChooseLinkSenders(device); },
                edit: remove != null ? () => _ = RenameRecentRecipient(owner, remove, name, nickname, device.IsPerson, device)
                    : deviceShortcut ? () => _ = RenameBlipDevice(owner, name, device, nickname) : null,
                remove: remove == null ? null : () => _ = UpdateRecentRecipients("archive", owner, device.History ? null : device, target: remove),
                connectParsec: device.History ? null : () => _ = ConnectParsec(owner, device),
                editParsec: device.History ? null : () => _ = ConnectParsec(owner, device, edit: true)));
            foreach (var action in actions.Children.OfType<Button>()) FlatBlipButton(action);
            Grid.SetColumn(actions, 1);
            row.Children.Add(actions);
        }
        rows.Children.Add(row);
    }

    private async Task SendToBlipRecipient(string owner, BlipDevice device, bool folder = false, bool paste = false)
    {
        if (diagnosticMode || busy || modalDepth > 0 || owner != BlipOwner) return;
        BlipClipboardPayload? clipboard = null;
        bool dispatched = false;
        try
        {
            List<string> paths;
            if (paste) { clipboard = await BlipClipboard.ReadAsync(); paths = clipboard.Paths; }
            else if (folder)
            {
                var picker = new FolderPicker { CommitButtonText = "Send folder" };
                InitializeWithWindow.Initialize(picker, hwnd);
                picker.FileTypeFilter.Add("*");
                var selected = await Modal(async () => await picker.PickSingleFolderAsync(), dismissMenu: true);
                paths = selected == null ? new() : new() { selected.Path };
            }
            else
            {
                var picker = new FileOpenPicker { CommitButtonText = "Send files" };
                InitializeWithWindow.Initialize(picker, hwnd);
                picker.FileTypeFilter.Add("*");
                var selected = await Modal(async () => await picker.PickMultipleFilesAsync(), dismissMenu: true);
                paths = selected.Select(f => f.Path).ToList();
            }
            if (paths.Count > 0) await DispatchBlipSend(device, paths, owner, () => dispatched = true);
        }
        catch (Exception error) { Error(error); }
        finally { if (!dispatched) clipboard?.Discard(); }
    }
}
