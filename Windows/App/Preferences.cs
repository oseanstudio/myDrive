using System.Text.Json;
namespace MyDrive;
public sealed class Preferences
{
    public string Theme {get;set;}="System";
    public bool BlipAutoOpenLinks {get;set;}=true;
    public bool BlipAutoConnectDesktop {get;set;}=true;
    public string BlipAutoOpenAccount {get;set;}="";
    public List<string> BlipAutoOpenPeers {get;set;}=new();
    public List<string> BlipAutoReceivePeers {get;set;}=new();
    public string SyncthingConfigPath {get;set;}="";
    public string SyncthingEndpoint {get;set;}="";
    public bool SyncthingManual {get;set;}
    public string LastSyncFolder {get;set;}="";
    public string LastSyncDevice {get;set;}="";
    public static Preferences Current {get;private set;}=Load();
    private static Preferences Load(){try{return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(CoreBridge.DataDir,"preferences.json")))??new();}catch{return new();}}
    public static void Save(){Directory.CreateDirectory(CoreBridge.DataDir);var path=Path.Combine(CoreBridge.DataDir,"preferences.json");File.WriteAllText(path+".tmp",JsonSerializer.Serialize(Current,new JsonSerializerOptions{WriteIndented=true}));File.Move(path+".tmp",path,true);}
}
