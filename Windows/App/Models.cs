using System.Text.Json.Serialization;
namespace MyDrive;
public sealed class Bookmark
{
    public string id {get;set;}=Guid.NewGuid().ToString("N");
    public string nickname {get;set;}="";
    public string protocol {get;set;}="sftp";
    public string host {get;set;}="";
    public ushort port {get;set;}
    public string path {get;set;}="";
    public string username {get;set;}="";
    public string credentials_ref {get;set;}="";
    public string mount_path {get;set;}="";
    public Dictionary<string,string> options {get;set;}=new();
    [JsonIgnore] public string ProtocolName => protocol switch {"local"=>"Local folder","smb"=>"SMB","sftp"=>"SFTP","webdav"=>"WebDAV","s3"=>"S3",_=>protocol};
    [JsonIgnore] public string Location => protocol=="local" ? host : protocol=="smb" ? $@"\\{host}\{path.Replace('/','\\')}" : host+(path.Length>0?$" / {path}":"");
}
public sealed class Credentials
{
    public string password {get;set;}="";
    public string private_key {get;set;}="";
    public string passphrase {get;set;}="";
    public string session_token {get;set;}="";
}
public sealed class RemoteFile
{
    public string name {get;set;}="";
    public string path {get;set;}="";
    public ulong size {get;set;}
    public string modified {get;set;}="";
    public bool is_dir {get;set;}
    [JsonIgnore] public string Size => is_dir?"Folder":size<1024?$"{size} B":size<1048576?$"{size/1024d:0.#} KB":size<1073741824?$"{size/1048576d:0.#} MB":$"{size/1073741824d:0.##} GB";
    [JsonIgnore] public string Modified => DateTimeOffset.TryParse(modified,out var d)?d.LocalDateTime.ToString("MMM d, yyyy  HH:mm"):modified;
}
public sealed record ActivityEntry(DateTimeOffset Time,string Operation,string Connection,string Detail,bool Success);
