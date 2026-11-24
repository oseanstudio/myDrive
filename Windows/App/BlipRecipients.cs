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
    private string recentOwner = "", recipientQuery = "", searchedQuery = "", searchMessage = "";
    private bool searchingRecipients;
    private bool archivesExpanded;
    private readonly HashSet<string> expandedContacts = new(StringComparer.OrdinalIgnoreCase);
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

    private string BlipBaseDeviceName(BlipDevice device)
    {
        var recent = recentOwner == BlipOwner ? recentRecipients.Find(r =>
            r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase)) : null;
        var known = blipSnapshot?.Devices.Find(d => d.Peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase));
        return FirstName(recent?.nickname, known?.Nickname, device.HasDeviceName ? device.BaseLabel : null,
            known?.HasRegisteredName == true ? known.Name : null, recent?.device, known?.BaseLabel, device.BaseLabel);
    }

    private string BlipDeviceName(BlipDevice device)
    {
        var name = BlipBaseDeviceName(device);
        var account = device.Peer.Split(':')[0] + ":";
        bool duplicate = (blipSnapshot?.Devices ?? []).Concat(directoryRecipients).Any(other =>
            !other.Peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase) &&
            other.Peer.StartsWith(account, StringComparison.OrdinalIgnoreCase) &&
            BlipBaseDeviceName(other).Equals(name, StringComparison.OrdinalIgnoreCase));
        return duplicate ? device.DisambiguatedName(name) : name;
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

    private string? BlipPersonName(BlipDevice device, string account)
    {
        var saved = recentRecipients.Where(r => r.Account.Equals(account, StringComparison.OrdinalIgnoreCase));
        var known = (blipSnapshot?.Devices ?? []).Concat(directoryRecipients).Where(other =>
            other.Peer.StartsWith(account + ":", StringComparison.OrdinalIgnoreCase));
        return saved.Select(r => r.person_nickname).Append(device.UserName)
            .Concat(known.Select(other => other.UserName))
            .Concat(saved.Select(r => r.person)).Append(device.Contact)
            .Concat(known.Select(other => other.Contact))
            .Concat(saved.Select(r => r.FallbackLabel).Where(label => label != "Device"))
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
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
            expandedContacts.Clear();
            recipientQuery = searchedQuery = searchMessage = "";
            directoryRecipients = new();
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
            RenderRecipientRows();
        };
        search.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; _ = SearchBlipRecipients(); } };
        var find = QuickIcon("\uE721", "Search Blip for a person", () => _ = SearchBlipRecipients());
        find.IsEnabled = search.IsEnabled;
        var input = new Grid { ColumnSpacing = 4 };
        input.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        input.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        input.Children.Add(search);
        Grid.SetColumn(find, 1);
        input.Children.Add(find);
        page.Children.Add(input);
        recipientRows = new StackPanel { Spacing = 3 };
        page.Children.Add(recipientRows);
        RenderRecipientRows();
        if (focus && search.IsEnabled) { search.Focus(FocusState.Keyboard); search.SelectionStart = search.Text.Length; }
    }

    private async Task SearchBlipRecipients()
    {
        string owner = BlipOwner, query = recipientQuery.Trim();
        if (diagnosticMode || searchingRecipients || owner.Length == 0 || query.Length == 0) return;
        searchingRecipients = true;
        searchedQuery = query;
        searchMessage = "Searching Blip…";
        directoryRecipients = new();
        RenderRecipientRows();
        try
        {
            var matches = await blip.SearchAsync(query);
            if (owner == BlipOwner) { directoryRecipients = matches; searchMessage = ""; }
        }
        catch (Exception error) { if (owner == BlipOwner) searchMessage = error.Message; }
        finally { searchingRecipients = false; RenderRecipientRows(); }
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
            var matches = devices.Where(d => new[] { d.ContactName, d.Contact, BlipDeviceName(d), d.Name,
                    BlipPersonName(d, d.Account) ?? "" }
                .Any(text => text.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
                .Concat(searched ? directoryRecipients : new List<BlipDevice>())
                .Where(d => BlipTrustPolicy.ExactPeer(d.Peer) && !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase)
                    && !IsRecipientArchived(owner, d.Peer))
                .DistinctBy(d => d.Peer, StringComparer.OrdinalIgnoreCase)
                .OrderBy(BlipDeviceCaption, StringComparer.CurrentCultureIgnoreCase).Take(30).ToList();
            foreach (var group in BlipDevice.GroupDestinations(matches, owner.Split(':')[0]))
                AddContactRows(rows, owner, group, null);
            if (searched && searchMessage.Length > 0) rows.Children.Add(QuickText(searchMessage, 12));
            else if (matches.Count == 0) rows.Children.Add(QuickText(searched ? "No matching Blip devices." : "Press Enter to search Blip.", 12));
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
        var list = grouped ? new StackPanel { Spacing = 3 } : rows;
        foreach (var device in group)
        {
            var recent = saved?.GetValueOrDefault(device.Peer);
            var name = grouped ? BlipDeviceName(device) : BlipDeviceCaption(device);
            AddRecipientRow(list, owner, name, device.History ? null : device, saved == null ? null : device.Peer,
                recent?.nickname);
        }
        if (!grouped || contact == null) return;

        var expander = ContactExpander(contact, list);
        expander.IsExpanded = expandedContacts.Contains(group.Key);
        expander.Expanding += (_, _) => expandedContacts.Add(group.Key);
        expander.Collapsed += (_, _) => expandedContacts.Remove(group.Key);
        if (saved != null && group.Select(d => saved.GetValueOrDefault(d.Peer)).FirstOrDefault(r => r != null) is { } entry)
        {
            var actions = new MenuFlyout();
            MenuAction(actions, "Rename contact…", () => _ = RenameRecentRecipient(owner, entry.Account, contact,
                entry.person_nickname, person: true));
            MenuAction(actions, "Archive recent devices", () => _ = UpdateRecentRecipients("archive", owner,
                target: entry.Account));
            expander.ContextFlyout = actions;
        }
        rows.Children.Add(expander);
    }

    private static Expander ContactExpander(string name, StackPanel devices) => new()
    {
        Header = QuickText(name, 12, true), Content = devices,
        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch
    };

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

    private void AddRecipientRow(StackPanel rows, string owner, string name, BlipDevice? device, string? remove,
                                 string? nickname = null, bool deviceShortcut = false)
    {
        var row = new Grid { ColumnSpacing = 4 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        if (device == null) row.Children.Add(QuickText(name, 12));
        else
        {
            var send = QuickButton("", () => _ = SendToBlipRecipient(owner, device));
            send.Content = QuickText(name, 12);
            send.HorizontalAlignment = HorizontalAlignment.Stretch;
            send.HorizontalContentAlignment = HorizontalAlignment.Left;
            send.IsEnabled = BlipRunning && !busy;
            AutomationProperties.SetName(send, "Send files to " + name);
            ToolTipService.SetToolTip(send, name);
            var alternatives = new MenuFlyout();
            MenuAction(alternatives, "Send folder…", () => _ = SendToBlipRecipient(owner, device, folder: true));
            MenuAction(alternatives, "Paste and send", () => _ = SendToBlipRecipient(owner, device, paste: true));
            send.ContextFlyout = alternatives;
            row.Children.Add(send);
        }
        if (remove != null || deviceShortcut)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
            if (device != null)
            {
                var paste = QuickIcon("\uE77F", "Paste and send to " + name,
                    () => _ = SendToBlipRecipient(owner, device, paste: true));
                paste.IsEnabled = BlipRunning && !busy;
                actions.Children.Add(paste);
            }
            if (deviceShortcut && device != null)
                actions.Children.Add(QuickIcon("\uE70F", "Rename " + name,
                    () => _ = RenameBlipDevice(owner, name, device, nickname)));
            if (remove != null)
            {
                actions.Children.Add(QuickIcon("\uE70F", "Rename " + name,
                    () => _ = RenameRecentRecipient(owner, remove, name, nickname, person: false)));
                actions.Children.Add(QuickIcon("\uE711", "Archive " + name,
                    () => _ = UpdateRecentRecipients("archive", owner, device, target: remove)));
            }
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
