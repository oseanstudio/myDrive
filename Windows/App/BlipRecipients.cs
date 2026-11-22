using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace MyDrive;

public sealed partial class MainWindow
{
    private sealed record RecentRecipient(string peer, string label);
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

    private async Task UpdateRecentRecipients(string action, string owner, BlipDevice? recipient = null, string? target = null)
    {
        if (diagnosticMode || !BlipTrustPolicy.ExactPeer(owner)) return;
        await recentGate.WaitAsync();
        try
        {
            var names = KnownRecipients(owner).ToDictionary(d => d.Peer, d => d.ToString(), StringComparer.OrdinalIgnoreCase);
            var seed = (blipSnapshot?.Transfers ?? new())
                .Where(t => t.Direction == "Outgoing" && t.ConfirmedComplete && !IsRelayPacket(t) && names.ContainsKey(t.Peer))
                .OrderByDescending(t => t.UpdatedAt).DistinctBy(t => t.Peer, StringComparer.OrdinalIgnoreCase).Take(24)
                .Select(t => new RecentRecipient(t.Peer, names[t.Peer])).ToArray();
            var result = await CoreBridge.Call(new { action = "blip.recents." + action, data_dir = CoreBridge.DataDir,
                payload = new { owner, seed, recipient = recipient == null ? null : new RecentRecipient(recipient.Peer, recipient.ToString()), target } });
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
            var matches = devices.Where(d => new[] { d.ContactName, d.Contact, d.DisplayName, d.Name }
                .Any(text => text.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
                .Concat(searched ? directoryRecipients : new List<BlipDevice>())
                .Where(d => BlipTrustPolicy.ExactPeer(d.Peer) && !d.Peer.Equals(owner, StringComparison.OrdinalIgnoreCase))
                .DistinctBy(d => d.Peer, StringComparer.OrdinalIgnoreCase)
                .OrderBy(d => d.ToString(), StringComparer.CurrentCultureIgnoreCase).Take(30).ToList();
            foreach (var device in matches) AddRecipientRow(rows, owner, device.ToString(), device, null);
            if (searched && searchMessage.Length > 0) rows.Children.Add(QuickText(searchMessage, 12));
            else if (matches.Count == 0) rows.Children.Add(QuickText(searched ? "No matching Blip devices." : "Press Enter to search Blip.", 12));
            return;
        }
        if (recentRecipients.Count == 0) return;
        rows.Children.Add(QuickText("Recent recipients", 12, true));
        foreach (var group in recentRecipients.GroupBy(r => r.peer.Split(':')[0]))
        {
            var entries = group.ToList();
            if (entries.Count > 1 && !owner.StartsWith(group.Key + ":", StringComparison.OrdinalIgnoreCase))
            {
                var name = devices.Find(d => d.Peer.StartsWith(group.Key + ":", StringComparison.OrdinalIgnoreCase))?.ContactName;
                if (!string.IsNullOrWhiteSpace(name)) AddRecipientRow(rows, owner, name, null, group.Key);
            }
            foreach (var entry in entries)
            {
                var device = devices.Find(d => d.Peer.Equals(entry.peer, StringComparison.OrdinalIgnoreCase));
                AddRecipientRow(rows, owner, device?.ToString() ?? entry.label, device, entry.peer);
            }
        }
    }

    private void AddRecipientRow(StackPanel rows, string owner, string name, BlipDevice? device, string? remove)
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
        if (remove != null)
        {
            var button = QuickIcon("\uE711", "Remove " + name + " from recent recipients", () => _ = UpdateRecentRecipients("remove", owner, target: remove));
            Grid.SetColumn(button, 1);
            row.Children.Add(button);
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
