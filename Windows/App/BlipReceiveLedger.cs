using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace MyDrive;

public sealed class BlipReceiveLedger
{
    private readonly string path;
    private readonly HashSet<string> claims;
    private readonly object gate=new();
    public BlipReceiveLedger(string path) {
        this.path=path;
        claims=File.Exists(path)?JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(path))??throw new IOException("Receive history is unavailable."):new();
    }
    public bool TryClaim(string account,string transfer) {
        lock(gate) {
        if(!Guid.TryParseExact(account,"D",out _)||!Guid.TryParseExact(transfer,"D",out _))return false;
        var key=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(account.ToLowerInvariant()+":"+transfer.ToLowerInvariant())));
        if(!claims.Add(key))return false;
        try{Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path+".tmp",JsonSerializer.Serialize(claims));File.Move(path+".tmp",path,true);return true;}
        catch{claims.Remove(key);throw;}
        }
    }
}
