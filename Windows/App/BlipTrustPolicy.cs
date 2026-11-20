namespace MyDrive;

public static class BlipTrustPolicy
{
    public static bool ExactPeer(string? peer) => !string.IsNullOrEmpty(peer) && peer.Split(':') is var parts && parts.Length == 2 && parts.All(p=>Guid.TryParseExact(p,"D",out _));
    public static bool Allowed(BlipStatus status, string account, IEnumerable<string>? peers, BlipTransfer transfer) =>
        status.Authenticated && Guid.TryParseExact(account,"D",out _) && account.Equals(status.UserId,StringComparison.OrdinalIgnoreCase)
        && ExactPeer(transfer.Peer) && peers?.Contains(transfer.Peer,StringComparer.OrdinalIgnoreCase)==true;
    public static bool AutoReceive(BlipStatus status,string account,IEnumerable<string> peers,BlipTransfer transfer) =>
        Allowed(status,account,peers,transfer) && transfer.AwaitingAcceptance && transfer.LinkOnly;
    public static bool AutoReceive(BlipStatus status,string account,IEnumerable<string> links,IEnumerable<string> files,BlipTransfer transfer,bool openLinks) =>
        transfer.AwaitingAcceptance&&
        (Allowed(status,account,files,transfer)||(openLinks&&transfer.LinkOnly&&Allowed(status,account,links,transfer)));
}
