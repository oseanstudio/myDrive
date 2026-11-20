using System.Text.Json;
namespace MyDrive;

// Local account-scoped names and exact peer identities. Contains no file/URL history.
public sealed class BlipSenderCatalog
{
    private readonly string file;
    private Dictionary<string,List<BlipDevice>> accounts;
    private readonly object gate=new();
    public BlipSenderCatalog(string file) {
        this.file=file;
        try {accounts=File.Exists(file)?JsonSerializer.Deserialize<Dictionary<string,List<BlipDevice>>>(File.ReadAllText(file))??new():new();}
        catch {throw new IOException("Saved sender names could not be read. The existing file has been kept.");}
    }
    public List<BlipDevice> Merge(BlipStatus status,IEnumerable<BlipDevice> devices,IEnumerable<BlipTransfer> transfers,IEnumerable<string> approved) {
        lock(gate) {
        if(!status.Authenticated||!Guid.TryParseExact(status.UserId,"D",out _))return new();
        string account=status.UserId.ToLowerInvariant(),self=account+":"+status.DeviceId.ToLowerInvariant();
        var before=JsonSerializer.Serialize(accounts);
        var peers=(accounts.GetValueOrDefault(account)??new()).Where(d=>BlipTrustPolicy.ExactPeer(d.Peer)).DistinctBy(d=>d.Peer,StringComparer.OrdinalIgnoreCase).ToDictionary(d=>d.Peer,d=>d,StringComparer.OrdinalIgnoreCase);
        foreach(var device in devices.Where(d=>BlipTrustPolicy.ExactPeer(d.Peer))) {
            if (peers.TryGetValue(device.Peer, out var saved)) {
                device.Nickname = saved.Nickname;
                if (saved.NameKnown && !device.NameKnown) { device.Name = saved.Name; device.NameKnown = true; }
                if (string.IsNullOrWhiteSpace(device.Contact)) device.Contact = saved.Contact;
                if (string.IsNullOrWhiteSpace(device.UserName)) device.UserName = saved.UserName;
                if (string.IsNullOrWhiteSpace(device.Kind)) device.Kind = saved.Kind;
            }
            peers[device.Peer]=device;
        }
        foreach(string peer in transfers.Where(t=>t.Direction=="Incoming").Select(t=>t.Peer).Concat(approved).Where(BlipTrustPolicy.ExactPeer))
            if(!peers.ContainsKey(peer))peers[peer]=new(){Peer=peer,Name="Previous device",History=true};
        peers.Remove(self);
        var result=peers.Values.OrderBy(d=>d.Name,StringComparer.CurrentCultureIgnoreCase).ToList();
        foreach(var device in result)device.SelectionName="";
        foreach (var group in result.GroupBy(d => d.Peer.Split(':')[0] + ":" + d.BaseLabel, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
        {
            int ordinal = 0;
            foreach (var device in group.OrderBy(d => d.Peer, StringComparer.OrdinalIgnoreCase))
                device.SelectionName = device.BaseLabel + " " + (++ordinal);
        }
        accounts[account]=result;
        string after=JsonSerializer.Serialize(accounts);
        if(before!=after){Directory.CreateDirectory(Path.GetDirectoryName(file)!);File.WriteAllText(file+".tmp",after);File.Move(file+".tmp",file,true);}
        return result;
        }
    }
    public void SetNicknames(string account,IEnumerable<(string Peer,string Name)> labels) {
        lock(gate) {
            if(!accounts.TryGetValue(account.ToLowerInvariant(),out var devices))return;
            foreach(var label in labels){var device=devices.FirstOrDefault(d=>d.Peer.Equals(label.Peer,StringComparison.OrdinalIgnoreCase));if(device!=null)device.Nickname=new string(label.Name.Trim().Where(c=>!char.IsControl(c)).Take(80).ToArray());}
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);File.WriteAllText(file+".tmp",JsonSerializer.Serialize(accounts));File.Move(file+".tmp",file,true);
        }
    }
}

public sealed class BlipNoticeTracker
{
    private string session="";
    private readonly Dictionary<string,string> states=new();
    public List<BlipTransfer> Update(BlipStatus status,IEnumerable<BlipTransfer> transfers) {
        if(!status.Authenticated){session="";states.Clear();return new();}
        string identity=status.UserId+":"+status.DeviceId;bool baseline=session!=identity;
        if(baseline){session=identity;states.Clear();}
        var changes=new List<BlipTransfer>();
        foreach(var transfer in transfers.Where(t=>t.Direction=="Incoming"&&BlipTrustPolicy.ExactPeer(t.Peer)&&Guid.TryParseExact(t.Id,"D",out _)&&(!t.Dismissed||t.ConfirmedComplete))) {
            string state=transfer.Status+":"+transfer.HasError;
            bool changed=!states.TryGetValue(transfer.Id,out var previous)||previous!=state;
            states[transfer.Id]=state;
            bool live=transfer.Status is "Invited" or "Pending" or "Active" or "Paused" or "ResumeRequested";
            if(changed&&(!baseline||live))changes.Add(transfer);
        }
        return changes;
    }
}
