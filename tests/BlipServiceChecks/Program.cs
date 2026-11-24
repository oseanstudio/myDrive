using MyDrive;
using System.Text.Json;
if(args.Length!=3)throw new ArgumentException("Expected node executable, fake bundle, and scratch directory");
string profile=Path.Combine(args[2],"profile-"+Guid.NewGuid().ToString("N")[..8]);
Directory.CreateDirectory(args[2]);
var checks=new List<string>();
void Check(bool condition,string name){if(!condition)throw new Exception(name);checks.Add(name);}
await using var service=new BlipService(args[1],args[2],profile,args[0]);
await service.StartAsync();Check(service.IsRunning,"starts its own host");
var snapshot=await service.SnapshotAsync();Check(!snapshot.Status.Authenticated&&snapshot.Devices.Count==0&&snapshot.Transfers.Count==0,"typed unauthenticated snapshot");
Check(!new BlipTransfer{Status="Invited",Completed=true}.ConfirmedComplete&&!new BlipTransfer{Status="Completed",Completed=false}.ConfirmedComplete,"dispatch and inconsistent completion are not delivery");
Check(new BlipTransfer{Status="Completed",Completed=true}.ConfirmedComplete,"matching completion fields confirm delivery");
string file=Path.Combine(args[2],"a ; file.txt");await File.WriteAllTextAsync(file,"local fixture");
bool rejected=false;try{await service.SendAsync("phone",new[]{file});}catch(IOException){rejected=true;}Check(rejected&&!File.Exists(Path.Combine(profile,"send-count")),"ambiguous peer rejected before dispatch");
string peer="11111111-1111-4111-8111-111111111111:22222222-2222-4222-8222-222222222222";
await service.SendAsync(peer,new[]{file});Check(File.ReadAllText(Path.Combine(profile,"send-count"))=="1","explicit dispatch issued once");
await File.WriteAllTextAsync(Path.Combine(profile,"fail-send"),"");try{await service.SendAsync(peer,new[]{file});}catch(IOException){}
Check(File.ReadAllText(Path.Combine(profile,"send-count"))=="2","failed mutation is never replayed");
await File.WriteAllTextAsync(Path.Combine(profile,"stall-status"),"");using(var cancelled=new CancellationTokenSource(300)){
  var a=service.CommandAsync("status",token:cancelled.Token);var b=service.CommandAsync("devices");
  bool interrupted=false;try{await a;}catch(IOException){interrupted=true;}
  var devices=await b;Check(interrupted&&service.IsRunning&&devices.GetProperty("devices").GetArrayLength()==0,"cancelling request A preserves request B and host");
}
await service.StopAsync();Check(!service.IsRunning&&File.Exists(Path.Combine(profile,"clean-stop")),"owned host stops gracefully");
File.Delete(Path.Combine(profile,"stall-status"));
string socket=Path.Combine(args[2],"desktop.sock");await File.WriteAllTextAsync(socket,"fixture only");
await using(var attached=new BlipService(args[1],args[2],profile,args[0],socket)){
  File.Delete(Path.Combine(profile,"host-pid"));File.Delete(Path.Combine(profile,"clean-stop"));
  await attached.UseDesktopAsync();
  Check(attached.IsRunning&&attached.UsesDesktopSession&&File.Exists(Path.Combine(profile,"host-pid")),"existing desktop account has a managed background helper");
  var shared=await attached.SnapshotAsync();Check(shared.Status.Authenticated&&shared.Status.DesktopSession&&!shared.Status.NativeAutoAcceptDisabled,"desktop queries use its existing session");
  var poll=await attached.PollAsync();Check(poll.Status.Authenticated&&poll.Status.DesktopSession&&poll.Transfers.Count==0,"background polling includes fresh auth and transfer state through the desktop socket");
  var concurrent = await Task.WhenAll(attached.PollAsync(), attached.PollAsync());
  Check(concurrent.All(result => result.Status.DesktopSession) && !File.Exists(Path.Combine(profile,"standalone-poll")),
      "concurrent status reads reuse the existing host without launching a process");
  await File.WriteAllTextAsync(Path.Combine(profile,"fail-accept"),"");bool acceptFailed=false;
  try{await attached.AcceptAsync("ABCD1234-EF56-4789-ABCD-123456789ABC");}catch(IOException){acceptFailed=true;}
  Check(acceptFailed&&attached.IsRunning&&attached.UsesDesktopSession,"unconfirmed receive preserves the desktop attachment");
  string receiveResult=File.ReadAllText(Path.Combine(profile,"last-receive-result.json"));Check(receiveResult.Contains("Invited")&&!receiveResult.Contains("ABCD1234"),"receive diagnostics retain status without transfer identity");
  File.Delete(Path.Combine(profile,"fail-accept"));
  await attached.AcceptAsync("ABCD1234-EF56-4789-ABCD-123456789ABC",manual:true);
  Check(File.ReadAllText(Path.Combine(profile,"last-accept-command"))=="accept-manual:desktop",
      "the Receive button uses the explicit manual action on the existing session");
  bool separateRejected=false;try{await attached.StartAsync();}catch(IOException){separateRejected=true;}
  Check(separateRejected&&attached.UsesDesktopSession,"separate startup cannot silently reuse the existing desktop account");
  bool loginRejected=false,trustRejected=false;
  try{await attached.LoginAsync("example@example.invalid");}catch(IOException){loginRejected=true;}
  try{await attached.TrustAsync(peer);}catch(IOException){trustRejected=true;}
  Check(loginRejected&&trustRejected,"desktop sign-in and automatic receiving stay in desktop Blip");
  int helperId=int.Parse(File.ReadAllText(Path.Combine(profile,"host-pid")));using(var helper=System.Diagnostics.Process.GetProcessById(helperId)){helper.Kill();await helper.WaitForExitAsync();}
  Check(!attached.IsRunning,"unexpected helper exit is detected independently of the desktop attachment flag");
  await attached.UseDesktopAsync();
  Check(attached.IsRunning&&int.Parse(File.ReadAllText(Path.Combine(profile,"host-pid")))!=helperId,"background helper can be restarted without another sign-in");
  await attached.StopAsync();
  Check(!attached.IsRunning&&!attached.UsesDesktopSession&&File.ReadAllText(Path.Combine(profile,"clean-stop"))=="desktop-serve","disconnect stops only the managed desktop helper");
}
Console.WriteLine(JsonSerializer.Serialize(new{ok=true,checks},new JsonSerializerOptions{WriteIndented=true}));
