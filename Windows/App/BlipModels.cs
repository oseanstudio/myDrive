using System.Text.Json.Serialization;
namespace MyDrive;
public sealed class BlipStatus
{
    [JsonPropertyName("authenticated")] public bool Authenticated { get; set; }
    [JsonPropertyName("desktop_session")] public bool DesktopSession { get; set; }
    [JsonPropertyName("receive_policy_verified")] public bool ReceivePolicyVerified { get; set; }
    [JsonPropertyName("registration")] public string Registration { get; set; } = "NOT_STARTED";
    [JsonPropertyName("user_id")] public string UserId { get; set; } = "";
    [JsonPropertyName("device_id")] public string DeviceId { get; set; } = "";
    [JsonPropertyName("downloads_directory")] public string? DownloadsDirectory { get; set; }
}
public sealed class BlipDevice
{
    [JsonPropertyName("peer")] public string Peer { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "Device";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("contact")] public string Contact { get; set; } = "";
    [JsonPropertyName("history")] public bool History { get; set; }
    [JsonPropertyName("online")] public bool? Online { get; set; }
    [JsonPropertyName("can_relay")] public bool CanRelay { get; set; }
    [JsonPropertyName("name_known")] public bool NameKnown { get; set; }
    [JsonPropertyName("user_name")] public string UserName { get; set; }="";
    [JsonPropertyName("nickname")] public string Nickname { get; set; }="";
    [JsonIgnore] public string SelectionName {get;set;}="";
    [JsonIgnore] public bool HasDeviceName => NameKnown || !string.IsNullOrWhiteSpace(Nickname);
    [JsonIgnore] public string ContactName => string.IsNullOrWhiteSpace(UserName) ? Contact : UserName;
    [JsonIgnore] public string BaseLabel
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(Nickname)) return Nickname;
            if (NameKnown) return Name;
            var kind = Kind.Length > 0 ? Kind : Name;
            if (kind is "Desktop" or "Laptop" or "Phone" or "Tablet") return kind;
            return History ? "Previous device" : "Device";
        }
    }
    [JsonIgnore] public string DisplayName => SelectionName.Length > 0 ? SelectionName : BaseLabel;
    public override string ToString()
    {
        if (string.IsNullOrWhiteSpace(ContactName)) return DisplayName;
        return HasDeviceName ? DisplayName + " · " + ContactName : ContactName + " · " + DisplayName;
    }
}
public sealed class BlipTransfer
{
    [JsonPropertyName("updated_at")] public long UpdatedAt { get; set; }
    [JsonPropertyName("transfer_id")] public string Id { get; set; } = "";
    [JsonPropertyName("peer")] public string Peer { get; set; } = "";
    [JsonPropertyName("direction")] public string Direction { get; set; } = "";
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("completed")] public bool Completed { get; set; }
    [JsonPropertyName("has_error")] public bool HasError { get; set; }
    [JsonPropertyName("link_files")] public List<string> LinkFiles { get; set; } = new();
    [JsonPropertyName("link_only")] public bool LinkOnly { get; set; }
    [JsonPropertyName("dismissed")] public bool Dismissed { get; set; }
    [JsonPropertyName("progress")] public long Progress { get; set; }
    [JsonPropertyName("total_bytes")] public long TotalBytes { get; set; }
    [JsonPropertyName("item_names")] public List<string> ItemNames { get; set; }=new();
    [JsonPropertyName("received_items")] public List<BlipReceivedItem> ReceivedItems {get;set;}=new();
    public string ItemLabel=>ItemNames.Count==0?"Incoming transfer":string.Join(", ",ItemNames);
    public string ProgressLabel=>Status=="Active"&&TotalBytes>0&&Progress>=0&&Progress<=TotalBytes?$"Receiving · {100.0*Progress/TotalBytes:0}%":StateLabel;
    public bool ConfirmedComplete => Status == "Completed" && Completed && !HasError;
    public bool IsLive => !Dismissed && !Completed &&
        Status is "Created" or "InviteRequested" or "Invited" or "Pending" or "Active" or "Paused" or "ResumeRequested";
    public bool AwaitingAcceptance=>Direction=="Incoming"&&Status=="Invited"&&!HasError&&!Dismissed;
    public string StateLabel => HasError ? "Needs attention" : ConfirmedComplete ? "Completed" : Status switch
    {
        "Completed" => "Checking delivery", "Created" => "Preparing", "InviteRequested" or "Invited" => "Waiting for acceptance", "Pending" => "Connecting",
        "Active" => "Transferring", "Paused" => "Paused", "ResumeRequested" => "Resuming", "Cancelled" => "Cancelled", _ => "Checking status"
    };
}
public sealed class BlipReceivedItem {
    [JsonPropertyName("name")] public string Name {get;set;}="";
    [JsonPropertyName("path")] public string Path {get;set;}="";
    [JsonPropertyName("is_directory")] public bool IsDirectory {get;set;}
    [JsonPropertyName("size")] public long Size {get;set;}
    public override string ToString()=>Name;
}
public sealed record BlipSnapshot(BlipStatus Status, List<BlipDevice> Devices, List<BlipTransfer> Transfers);
