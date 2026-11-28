using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;

public sealed partial class MainWindow
{
    private async Task ShowSyncDrop(List<string> paths)
    {
        if (busy || modalDepth > 0 || paths.Count is 0 or > 256 || diagnosticMode) return;
        NavigateQuick("sync");
        if (!syncSnapshot.HasValue)
            syncSnapshot = await SyncthingService.Call("snapshot", new { }, CancellationToken.None);
        var devices = QuickPeers(includePaused: false);
        if (devices.Count == 0)
        {
            Info("Sync with a device", "Pair a device in Syncthing before offering files or folders.");
            return;
        }
        string owner = BlipOwner;
        var recent = recentOwner == owner && owner.Length > 0
            ? recentRecipients.Where(item => item.archived == null &&
                (BlipTrustPolicy.ExactPeer(item.peer) || new BlipDevice { Peer = item.peer }.IsPerson))
                .DistinctBy(item => item.peer, StringComparer.OrdinalIgnoreCase).ToList() : [];
        var roster = KnownRecipients(owner).Concat(KnownPeople(owner)).ToList();
        var rows = new StackPanel { Spacing = 4 };
        var dialog = SyncDropDialog(paths.Count == 1 ? DropItemName(paths[0]) : $"{paths.Count} items", rows);
        Peer? device = null;
        string? link = null;
        bool relink = false;
        if (recent.Count > 0)
        {
            rows.Children.Add(QuickText("Recent recipients", 12, true));
            foreach (var item in recent)
            {
                var known = roster.Find(match => match.Peer.Equals(item.peer, StringComparison.OrdinalIgnoreCase));
                string caption = item.nickname ?? item.person_nickname ??
                    (known == null ? item.FallbackLabel : BlipDeviceCaption(known));
                string key = owner + "/" + item.peer.ToLowerInvariant();
                var linked = devices.Find(peer => peer.Id == Preferences.Current.SyncRecipientDevices.GetValueOrDefault(key));
                var row = new Grid { ColumnSpacing = 3 };
                row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                var choose = QuickButton(caption, () => { link = key; device = linked; dialog.Hide(); });
                choose.HorizontalAlignment = HorizontalAlignment.Stretch;
                choose.HorizontalContentAlignment = HorizontalAlignment.Left;
                row.Children.Add(choose);
                if (linked != null)
                {
                    ToolTipService.SetToolTip(choose, "Sync with " + linked.Name);
                    var change = QuickIcon("\uE70F", "Change sync device for " + caption,
                        () => { link = key; relink = true; dialog.Hide(); });
                    Grid.SetColumn(change, 1);
                    row.Children.Add(change);
                }
                rows.Children.Add(row);
            }
        }
        rows.Children.Add(QuickText("Other devices", 12, true));
        AddSyncDropDevices(rows, devices, peer => { device = peer; dialog.Hide(); });
        await ShowDialog(dialog);
        if (link != null)
        {
            if (BlipOwner != owner) return;
            if (relink || device == null)
            {
                var paired = new StackPanel { Spacing = 4 };
                var choose = SyncDropDialog("Link a Syncthing device", paired);
                paired.Children.Add(QuickText("Choose this person’s paired device. This starts two-way sync.", 12));
                AddSyncDropDevices(paired, devices, peer => { device = peer; choose.Hide(); });
                await ShowDialog(choose);
            }
        }
        if (device is not { } target || link != null && BlipOwner != owner) return;
        await Run("Start two-way sync", async token =>
        {
            var result = await SyncthingService.Call("share.drop", new { local_paths = paths, device_id = target.Id }, token);
            if (link != null && BlipOwner == owner)
            {
                Preferences.Current.SyncRecipientDevices[link] = target.Id;
                Preferences.Save();
            }
            Info("Offered to " + target.Name, B(result, "created")
                ? "Accept the share on the other device to start syncing."
                : "This selection is shared for two-way sync.");
            await RefreshSyncthing();
        });
    }

    private ContentDialog SyncDropDialog(string title, StackPanel rows) => new() {
        XamlRoot = root.XamlRoot, Title = title, CloseButtonText = "Cancel",
        Content = new ScrollViewer { Content = rows, MaxHeight = compact ? 245 : 425 }
    };

    private static void AddSyncDropDevices(StackPanel panel, List<Peer> peers, Action<Peer> select)
    {
        foreach (var peer in peers)
        {
            var button = QuickButton(peer.Name, () => select(peer));
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.HorizontalContentAlignment = HorizontalAlignment.Left;
            ToolTipService.SetToolTip(button, peer.Name + " · " + peer.Id);
            panel.Children.Add(button);
        }
    }

    private static string DropItemName(string path) => Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
}
