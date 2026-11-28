using System.Diagnostics;
using System.Text.Json;

namespace MyDrive;

public sealed partial class MainWindow
{
    private int blipRelayWaiting;
    private sealed record QueuedBlipRelay(string id, string peer, string label);
    private List<QueuedBlipRelay> blipRelayQueued = [];
    private string relaySession = "";
    private string relayTransportState = "";
    private long nextRelayDiscovery;
    private readonly Dictionary<string, BlipTransfer> relayReceived = new(StringComparer.Ordinal);
    private static bool IsRelayPacket(BlipTransfer transfer) =>
        transfer.ItemNames.Count == 1 && transfer.ItemNames[0].StartsWith("mydrive-relay-v1.", StringComparison.Ordinal);

    private static bool SameBlipAccount(string peer, string account) =>
        BlipTrustPolicy.ExactPeer(peer) && peer.Split(':')[0].Equals(account, StringComparison.OrdinalIgnoreCase);

    private async Task<bool> TryQueueRelay(BlipDevice target, IReadOnlyList<string> paths, CancellationToken token)
    {
        var snapshot = blipSnapshot;
        if (snapshot?.Status.Authenticated != true || !target.CanRelay ||
            !SameBlipAccount(target.Peer, snapshot.Status.UserId)) return false;
        var own = snapshot.Status.UserId + ":" + snapshot.Status.DeviceId;
        var fresh = await blip.PollAsync(token);
        if (!fresh.Status.Authenticated || fresh.Status.UserId + ":" + fresh.Status.DeviceId != own) return false;
        if (fresh.Devices.FirstOrDefault(d => !d.History && d.Peer == target.Peer)?.Online != false) return false;
        var relays = fresh.Devices.Where(d => !d.History && d.CanRelay && d.Online == true &&
            SameBlipAccount(d.Peer, fresh.Status.UserId) &&
            !d.Peer.Equals(own, StringComparison.OrdinalIgnoreCase) &&
            !d.Peer.Equals(target.Peer, StringComparison.OrdinalIgnoreCase)).Select(d => d.Peer).Distinct().ToList();
        if (relays.Count == 0) return false;
        await CoreBridge.Call(new { action = "relay.stage", data_dir = CoreBridge.DataDir,
            payload = new { @self = own, target = target.Peer, relay = relays[0], alternatives = relays.Skip(1).ToList(), paths } }, token);
        Interlocked.Exchange(ref nextRelayDiscovery, 0);
        return true;
    }

    private async Task UpdateRelay(BlipSnapshot snapshot, CancellationToken token)
    {
        var status = snapshot.Status;
        if (!status.Authenticated)
        {
            relayReceived.Clear();
            blipRelayWaiting = 0;
            blipRelayQueued = [];
            relaySession = "";
            return;
        }
        var own = status.UserId + ":" + status.DeviceId;
        if (relaySession != own) { relayReceived.Clear(); blipRelayQueued = []; relaySession = own; relayTransportState = ""; Interlocked.Exchange(ref nextRelayDiscovery, 0); }
        var transports = snapshot.Transfers.Where(t => IsRelayPacket(t) && SameBlipAccount(t.Peer, status.UserId)).ToArray();
        var states = string.Join("|", transports.OrderBy(t => t.Id, StringComparer.Ordinal)
            .Select(t => $"{t.Id}:{t.Status}:{t.Completed}:{t.HasError}"));
        var now = Environment.TickCount64;
        if (blipRelayWaiting == 0 && states == relayTransportState && !transports.Any(t => t.IsLive) &&
            now < Interlocked.Read(ref nextRelayDiscovery)) return;
        var data = await CoreBridge.Call(new { action = "relay.tick", data_dir = CoreBridge.DataDir,
            payload = new { @self = own, inbox = blip.DownloadsDirectory, previous_inboxes = previousBlipDownloadFolders, downloads = status.DownloadsDirectory,
                devices = snapshot.Devices, transfers = snapshot.Transfers } }, token);
        relayTransportState = states;
        Interlocked.Exchange(ref nextRelayDiscovery, now + 30_000);
        blipRelayWaiting = data.GetProperty("waiting").GetInt32();
        blipRelayQueued = Items(data, "queued").Select(entry =>
            new QueuedBlipRelay(S(entry, "id"), S(entry, "peer"), S(entry, "label"))).ToList();
        var command = data.GetProperty("command");
        if (command.ValueKind != JsonValueKind.Object) return;
        string id = command.GetProperty("id").GetString() ?? "";
        switch (command.GetProperty("action").GetString())
        {
            case "accept":
                await blip.AcceptAsync(id, token);
                break;
            case "send":
                var paths = command.GetProperty("paths").Deserialize<List<string>>() ?? new();
                await blip.SendAsync(command.GetProperty("peer").GetString() ?? "", paths, token, requestId: id);
                break;
            case "deliver":
                var transport = snapshot.Transfers.FirstOrDefault(t => t.Id == id && t.Direction == "Incoming" && t.ConfirmedComplete);
                if (transport == null || !SameBlipAccount(transport.Peer, status.UserId)) return;
                var files = command.GetProperty("paths").Deserialize<List<string>>() ?? new();
                var delivery = new BlipTransfer { Id = id, Peer = transport.Peer, Direction = "Incoming", Status = "Completed", Completed = true,
                    ItemNames = files.Select(Path.GetFileName).OfType<string>().ToList(),
                    ReceivedItems = files.Select(path => new BlipReceivedItem { Name = Path.GetFileName(path), Path = path, IsDirectory = Directory.Exists(path) }).ToList() };
                relayReceived[id] = delivery;
                if (!Preferences.Current.BlipAutoOpenLinks ||
                    !BlipTrustPolicy.Allowed(status, Preferences.Current.BlipAutoOpenAccount, Preferences.Current.BlipAutoOpenPeers, transport)) return;
                var opened = new HashSet<string>();
                foreach (var file in files.Where(BlipReceivedFiles.IsShortcut).Take(16))
                {
                    var url = await BlipLinkOpener.ReadShortcutAsync(file);
                    if (url != null && Preferences.Current.BlipAutoOpenLinks && opened.Add(url.AbsoluteUri))
                        Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
                }
                break;
        }
    }
}
