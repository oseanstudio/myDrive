using MyDrive;
using System.Text.Json;
// Read-only IPC test; never sends login, receive, transfer, settings or stop-host events.
if(args.Length!=4)throw new ArgumentException("Expected bundle, runtime, node, fresh short profile");
if(Directory.Exists(args[3]))throw new IOException("Use a fresh test profile");
await using var service=new BlipService(args[0],args[1],args[3],args[2]);
await service.UseDesktopAsync();
var snapshot=await service.SnapshotAsync();
if(!snapshot.Status.DesktopSession)throw new Exception("Desktop connection was not confirmed");
await service.StopAsync();
if(service.IsRunning||File.Exists(Path.Combine(args[3],"host.lock")))throw new Exception("Attachment owned a host");
await service.UseDesktopAsync();
var after=await service.SnapshotAsync();
bool sameIdentity=snapshot.Status.UserId==after.Status.UserId&&snapshot.Status.DeviceId==after.Status.DeviceId;
if(!sameIdentity)throw new Exception("Desktop identity changed");
await service.StopAsync();
Console.WriteLine(JsonSerializer.Serialize(new{ok=true,desktopSession=snapshot.Status.DesktopSession,authenticated=snapshot.Status.Authenticated,disconnectPreservedDesktop=true,sameDeviceIdentity=sameIdentity,noOwnedHost=true},new JsonSerializerOptions{WriteIndented=true}));
