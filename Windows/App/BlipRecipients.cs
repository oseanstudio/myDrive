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
                                          string? nickname = null, string? person_nickname = null)
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
    private TextBox? recipientInput;
    private StackPanel? recipientRows;

    private string BlipOwner => blipSnapshot?.Status is { Authenticated: true } status
        ? status.UserId.ToLowerInvariant() + ":" + status.DeviceId.ToLowerInvariant() : "";

    private List<BlipDevice> KnownRecipients(string owner) => (blipSnapshot?.Devices ?? new())
        .Where(d => !d.History && BlipTrustPolicy.ExactPeer(d.Peer) &&
            !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase)).ToList();

    private static RecentRecipient Recent(BlipDevice device) => new(device.Peer, device.ToString(),
        device.ContactName, device.HasDeviceName ? device.DisplayName : null);

    private string BlipDeviceName(BlipDevice device)
    {
        var recent = recentOwner == BlipOwner ? recentRecipients.Find(r =>
            r.peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase)) : null;
        var known = blipSnapshot?.Devices.Find(d => d.Peer.Equals(device.Peer, StringComparison.OrdinalIgnoreCase));
        return FirstName(recent?.nickname, known?.Nickname, device.HasDeviceName ? device.DisplayName : null,
            known?.DisplayName, device.DisplayName);
    }

    private string BlipDeviceCaption(BlipDevice device)
    {
        var name = BlipDeviceName(device);
        if (string.IsNullOrWhiteSpace(device.ContactName) ||
            device.Peer.StartsWith(BlipOwner.Split(':')[0] + ":", StringComparison.OrdinalIgnoreCase)) return name;
        return device.HasDeviceName ? name + " · " + device.ContactName : device.ContactName + " · " + name;
    }

    private string BlipPeerCaption(string peer) => (blipSnapshot?.Devices ?? []).Concat(directoryRecipients)
        .FirstOrDefault(d => d.Peer.Equals(peer, StringComparison.OrdinalIgnoreCase)) is { } device
        ? BlipDeviceCaption(device) : BlipDevice.FallbackName(peer);

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
        var devices = KnownRecipients(owner);
        if (query.Length > 0)
        {
            bool searched = query.Equals(searchedQuery, StringComparison.OrdinalIgnoreCase);
            var matches = devices.Where(d => new[] { d.ContactName, d.Contact, BlipDeviceName(d), d.Name }
                .Any(text => text.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
                .Concat(searched ? directoryRecipients : new List<BlipDevice>())
                .Where(d => BlipTrustPolicy.ExactPeer(d.Peer) && !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase))
                .DistinctBy(d => d.Peer, StringComparer.OrdinalIgnoreCase)
                .OrderBy(BlipDeviceCaption, StringComparer.CurrentCultureIgnoreCase).Take(30).ToList();
            foreach (var device in matches) AddRecipientRow(rows, owner, BlipDeviceCaption(device), device, null);
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
        var otherRecents = recentRecipients.Where(r => !listedDevices.Contains(r.peer)).ToList();
        if (otherRecents.Count > 0) rows.Children.Add(QuickText("Recent recipients", 12, true));
        foreach (var group in otherRecents.GroupBy(r => r.Account))
        {
            var entries = group.ToList();
            bool own = owner.StartsWith(group.Key + ":", StringComparison.OrdinalIgnoreCase);
            bool grouped = entries.Count > 1;
            var person = FirstName(entries[0].person_nickname, own ? "Your devices" : null,
                devices.FirstOrDefault(d => d.Peer.StartsWith(group.Key + ":", StringComparison.OrdinalIgnoreCase))?.ContactName,
                entries[0].person, entries[0].FallbackLabel);
            if (grouped)
                AddRecipientRow(rows, owner, person, null, group.Key, entries[0].person_nickname, person: true);
            foreach (var entry in entries)
            {
                var device = devices.Find(d => d.Peer.Equals(entry.peer, StringComparison.OrdinalIgnoreCase));
                var known = device ?? blipSnapshot?.Devices.Find(d => d.Peer.Equals(entry.peer, StringComparison.OrdinalIgnoreCase));
                var name = known != null ? BlipDeviceName(known) :
                    FirstName(entry.nickname, entry.device, BlipDevice.FallbackName(entry.peer));
                AddRecipientRow(rows, owner, name, device, entry.peer, entry.nickname, nested: grouped);
            }
        }
        listedDevices.UnionWith(otherRecents.Select(r => r.peer));
        var otherDevices = devices.Where(d => !listedDevices.Contains(d.Peer))
            .OrderBy(BlipDeviceCaption, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (otherDevices.Count > 0) rows.Children.Add(QuickText("Other devices", 12, true));
        foreach (var device in otherDevices)
            AddRecipientRow(rows, owner, BlipDeviceCaption(device), device, null, deviceShortcut: true);
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

    private void AddRecipientRow(StackPanel rows, string owner, string name, BlipDevice? device, string? remove,
                                 string? nickname = null, bool person = false, bool nested = false,
                                 bool deviceShortcut = false)
    {
        var row = new Grid { ColumnSpacing = 4, Margin = new Thickness(nested ? 12 : 0, 0, 0, 0) };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        if (device == null) row.Children.Add(QuickText(name, 12, person));
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
                    () => _ = RenameRecentRecipient(owner, remove, name, nickname, person)));
                actions.Children.Add(QuickIcon("\uE711", "Remove " + name + " from recent recipients",
                    () => _ = UpdateRecentRecipients("remove", owner, target: remove)));
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
                var selected = await Modal(async () => await picker.PickSingleFolderAsync());
                paths = selected == null ? new() : new() { selected.Path };
            }
            else
            {
                var picker = new FileOpenPicker { CommitButtonText = "Send files" };
                InitializeWithWindow.Initialize(picker, hwnd);
                picker.FileTypeFilter.Add("*");
                var selected = await Modal(async () => await picker.PickMultipleFilesAsync());
                paths = selected.Select(f => f.Path).ToList();
            }
            if (paths.Count > 0) await DispatchBlipSend(device, paths, owner, () => dispatched = true);
        }
        catch (Exception error) { Error(error); }
        finally { if (!dispatched) clipboard?.Discard(); }
    }
}
