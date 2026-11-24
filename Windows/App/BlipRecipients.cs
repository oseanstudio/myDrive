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
            !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase)).ToList();

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
        if (caption != null && caption.Equals(BlipPersonName(device, device.Account), StringComparison.CurrentCultureIgnoreCase))
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

    private static StackPanel BlipDestinationLabel(TextBlock title, string detail)
    {
        var summary = QuickText(detail, 11);
        summary.Opacity = .70;
        var text = new StackPanel { Spacing = 1, IsHitTestVisible = false };
        text.Children.Add(title);
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
        var known = new[] { device }.Concat(directoryRecipients).Concat(blipSnapshot?.Devices ?? [])
            .Where(other => other.Account.Equals(account, StringComparison.OrdinalIgnoreCase)).ToArray();
        var usernames = known.OrderBy(other => other.History).Select(other => other.UserName)
            .Concat(saved.Select(r => r.person))
            .Where(name => !string.IsNullOrWhiteSpace(name) &&
                !known.Any(other => string.Equals(other.Contact, name, StringComparison.OrdinalIgnoreCase)));
        return saved.Select(r => r.person_nickname).Concat(usernames)
            .Concat(known.Select(other => other.Contact))
            .Concat(saved.Select(r => r.person ?? r.FallbackLabel).Where(label => label != "Device"))
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim();
    }

    private string BlipPeerCaption(string peer) => (blipSnapshot?.Devices ?? []).Concat(directoryRecipients)
        .FirstOrDefault(d => d.Peer.Equals(peer, StringComparison.OrdinalIgnoreCase)) is { } device
        ? BlipDeviceCaption(device) : BlipDeviceCaption(new BlipDevice { Peer = peer });

    private async Task UpdateRecentRecipients(string action, string owner, BlipDevice? recipient = null,
                                              string? target = null, string? name = null)
    {
        if (diagnosticMode || !BlipTrustPolicy.ExactPeer(owner)) return;
        await recentGate.WaitAsync();
        try
        {
            var names = KnownRecipients(owner).ToDictionary(d => d.Peer, Recent, StringComparer.OrdinalIgnoreCase);
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
        search.TextChanged += (_, _) =>
        {
            recipientQuery = search.Text;
            QueueRecipientLookup();
        };
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
        input.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        input.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        input.Children.Add(search);
        Grid.SetColumn(find, 1);
        input.Children.Add(find);
        ToolTipService.SetToolTip(search, "Search by name, email address, or device name");
        page.Children.Add(input);
        recipientRows = new StackPanel { Spacing = 3 };
        page.Children.Add(recipientRows);
        RenderRecipientRows();
        if (focus && search.IsEnabled) { search.Focus(FocusState.Keyboard); search.SelectionStart = search.Text.Length; }
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
        var devices = KnownRecipients(owner).Where(d => !IsRecipientArchived(owner, d.Peer)).ToList();
        if (query.Length > 0)
        {
            bool searched = query.Equals(searchedQuery, StringComparison.OrdinalIgnoreCase);
            var matches = (searched ? directoryRecipients : []).Concat(devices.Where(d => new[] {
                    d.ContactName, d.Contact, BlipDeviceName(d), d.Name,
                    BlipPersonName(d, d.Account) ?? "" }
                .Any(text => text.Contains(query, StringComparison.CurrentCultureIgnoreCase))))
                .Where(d => BlipTrustPolicy.ExactPeer(d.Peer) && !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase)
                    && !IsRecipientArchived(owner, d.Peer))
                .DistinctBy(d => d.Peer, StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(d => d.Contact.Equals(query, StringComparison.OrdinalIgnoreCase))
                .ThenBy(BlipDeviceCaption, StringComparer.CurrentCultureIgnoreCase).Take(30).ToList();
            if (matches.Count > 0) rows.Children.Add(QuickText("Suggestions", 12, true));
            foreach (var device in matches)
            {
                var name = BlipDeviceCaption(device);
                var email = device.Contact;
                if (email.Contains('@') && !email.Equals(name, StringComparison.OrdinalIgnoreCase))
                    AddRecipientRow(rows, owner, name, device, null, suggestionDetail: email);
                else
                    AddRecipientRow(rows, owner, name, device, null);
            }
            if (searched && searchMessage.Length > 0) rows.Children.Add(QuickText(searchMessage, 12));
            else if (matches.Count == 0) rows.Children.Add(QuickText("No matching people or devices.", 12));
            return;
        }
        var ownAccount = owner.Split(':')[0];
        var myDevices = devices.Where(d => d.Peer.StartsWith(ownAccount + ":", StringComparison.OrdinalIgnoreCase))
            .OrderBy(d => d.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (myDevices.Count > 0)
        {
            rows.Children.Add(QuickText("My devices", 12, true));
            foreach (var device in myDevices)
            {
                var recent = recentRecipients.Find(r => r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase));
                var name = BlipDeviceName(device);
                AddRecipientRow(rows, owner, name, device, null, deviceShortcut: true, nickname: recent?.nickname);
            }
        }
        var listedDevices = myDevices.Select(d => d.Peer).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var saved = recentRecipients.Where(r => r.archived == null && !listedDevices.Contains(r.peer))
            .ToDictionary(r => r.peer, StringComparer.OrdinalIgnoreCase);
        var contacts = saved.Keys.Select(peer => devices.Find(d => d.Peer.Equals(peer, StringComparison.OrdinalIgnoreCase))
                ?? new BlipDevice { Peer = peer, History = true })
            .Concat(devices.Where(d => !listedDevices.Contains(d.Peer) && !saved.ContainsKey(d.Peer))
                .OrderBy(BlipDeviceCaption, StringComparer.CurrentCultureIgnoreCase));
        var groups = BlipDevice.GroupDestinations(contacts, ownAccount).ToList();
        var previous = groups.Where(group => group.Any(d => saved.ContainsKey(d.Peer))).ToList();
        var others = groups.Except(previous).ToList();
        if (previous.Count > 0) rows.Children.Add(QuickText("Recent recipients", 12, true));
        foreach (var group in previous) AddContactRows(rows, owner, group, saved);
        if (others.Count > 0) rows.Children.Add(QuickText("Other devices", 12, true));
        foreach (var group in others) AddContactRows(rows, owner, group, saved);
        var archived = recentRecipients.Where(r => r.archived != null).ToList();
        if (archived.Count > 0)
        {
            var contents = new StackPanel { Spacing = 3 };
            foreach (var entry in archived)
            {
                var device = blipSnapshot?.Devices.Find(d => d.Peer.Equals(entry.peer, StringComparison.OrdinalIgnoreCase))
                    ?? new BlipDevice { Peer = entry.peer };
                var name = device.RecipientCaption(ownAccount, BlipDeviceName(device),
                    BlipPersonName(device, device.Account), showDevice: true);
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
    }

    private void AddContactRows(StackPanel rows, string owner, IGrouping<string, BlipDevice> group,
                                Dictionary<string, RecentRecipient>? saved)
    {
        var first = group.First();
        var contact = BlipPersonName(first, first.Account);
        bool grouped = contact != null && group.Skip(1).Any();
        if (grouped && contact != null) rows.Children.Add(BlipContactHeading(contact, owner,
            saved == null ? null : group.Select(d => saved.GetValueOrDefault(d.Peer)).FirstOrDefault(r => r != null)));
        foreach (var device in group.OrderByDescending(d => d.Online == true))
        {
            var recent = saved?.GetValueOrDefault(device.Peer);
            var name = BlipGroupDeviceCaption(device, grouped);
            AddRecipientRow(rows, owner, name, device, saved == null ? null : device.Peer,
                recent?.nickname);
        }
    }

    private Grid BlipContactHeading(string contact, string owner, RecentRecipient? entry = null)
    {
        var header = new Grid { ColumnSpacing = 3, Padding = new Thickness(6, 1, 0, 0) };
        header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var title = QuickText(contact, 13, true);
        title.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(title);
        if (entry == null) return header;
        var options = BlipRecipientOptions(contact,
            () => _ = RenameRecentRecipient(owner, entry.Account, contact, entry.person_nickname, person: true),
            () => _ = UpdateRecentRecipients("archive", owner, target: entry.Account));
        Grid.SetColumn(options, 1);
        header.Children.Add(options);
        return header;
    }

    private static Button BlipRecipientOptions(string name, Action edit, Action? remove = null)
    {
        var options = FlatBlipButton(QuickIcon("\uE713", "Options for " + name, () => { }));
        var menu = new MenuFlyout();
        MenuAction(menu, "Edit name…", edit);
        if (remove != null) MenuAction(menu, "Remove", remove);
        options.Flyout = menu;
        return options;
    }

    private static string FirstName(params string?[] names) =>
        names.FirstOrDefault(name => !string.IsNullOrWhiteSpace(name)) ?? "Device";

    private async Task RenameRecentRecipient(string owner, string target, string name, string? nickname, bool person)
    {
        var edited = await PromptBlipName(owner, name, nickname, person);
        if (edited == null) return;
        if (!person && blipSnapshot is { } snapshot &&
            snapshot.Devices.Find(d => d.Peer.Equals(target, StringComparison.OrdinalIgnoreCase)) is { } device)
        {
            SaveBlipDeviceName(snapshot.Status.UserId, device, edited);
            RenderRecipientRows();
        }
        else await UpdateRecentRecipients("rename", owner, target: target, name: edited);
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
                                 string? nickname = null, bool deviceShortcut = false, string? suggestionDetail = null)
    {
        var row = new Grid { ColumnSpacing = 4 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var detail = BlipDeviceDetail(device, name);
        if (suggestionDetail != null) detail = suggestionDetail + " · " + detail;
        var title = BlipDestinationLabel(QuickText(name, 12), detail);
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
            send.ContextFlyout = alternatives;
            row.Children.Add(send);
        }
        if (remove != null || deviceShortcut)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
            if (!device.History)
            {
                var paste = QuickIcon("\uE77F", "Paste and send to " + name,
                    () => _ = SendToBlipRecipient(owner, device, paste: true));
                paste.IsEnabled = BlipRunning && !busy;
                actions.Children.Add(paste);
            }
            if (deviceShortcut && !device.History)
                actions.Children.Add(BlipRecipientOptions(name,
                    () => _ = RenameBlipDevice(owner, name, device, nickname)));
            if (remove != null)
            {
                actions.Children.Add(BlipRecipientOptions(name,
                    () => _ = RenameRecentRecipient(owner, remove, name, nickname, person: false),
                    () => _ = UpdateRecentRecipients("archive", owner, device.History ? null : device, target: remove)));
            }
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
