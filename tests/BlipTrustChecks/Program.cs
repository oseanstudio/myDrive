using MyDrive;
string account=Guid.NewGuid().ToString(),peer=Guid.NewGuid()+":"+Guid.NewGuid();
var status=new BlipStatus{Authenticated=true,UserId=account};
var transfer=new BlipTransfer{Id=Guid.NewGuid().ToString(),Peer=peer,Direction="Incoming",Status="Invited",LinkOnly=true};
void Check(bool value,string name){if(!value)throw new Exception(name);Console.WriteLine(name);}
Check(!BlipTrustPolicy.Allowed(status,account,Array.Empty<string>(),transfer),"unknown sender denied by default");
Check(BlipTrustPolicy.AutoReceive(status,account,new[]{peer},transfer),"approved invitation can receive automatically");
Check(!BlipTrustPolicy.Allowed(status,Guid.NewGuid().ToString(),new[]{peer},transfer),"approval is scoped to signed-in account");
transfer.LinkOnly=false;Check(!BlipTrustPolicy.AutoReceive(status,account,new[]{peer},transfer),"ordinary or mixed transfer still requires Receive");
transfer.LinkOnly=true;transfer.HasError=true;Check(!BlipTrustPolicy.AutoReceive(status,account,new[]{peer},transfer),"errored transfer cannot auto-receive");
transfer.HasError=false;transfer.Status="Invited";
Check(BlipTrustPolicy.AutoReceive(status,account,new[]{peer},transfer),"approved Invited web link can receive before Pending");
Check(BlipTrustPolicy.AutoReceive(status,account,Array.Empty<string>(),new[]{peer},transfer,false),"approved Invited file can receive with browser off");
transfer.Dismissed=true;Check(!BlipTrustPolicy.AutoReceive(status,account,new[]{peer},transfer),"dismissed invitation never auto-receives");transfer.Dismissed=false;transfer.Status="Pending";
Check(!BlipTrustPolicy.AutoReceive(status,account,new[]{peer},transfer)&&transfer.StateLabel=="Connecting","native Pending is already accepted and cannot be accepted again");transfer.Status="Invited";
var root=Path.Combine(Path.GetTempPath(),"mydrive-trust-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
var path=Path.Combine(root,"claims.json");var ledger=new BlipReceiveLedger(path);
Check(ledger.TryClaim(account,transfer.Id)&&!new BlipReceiveLedger(path).TryClaim(account,transfer.Id),"uncertain acceptance is not automatically replayed after restart");
Check(!File.ReadAllText(path).Contains(account),"receive claims contain hashes only");
transfer.HasError=false;transfer.LinkOnly=false;
Check(BlipTrustPolicy.AutoReceive(status,account,Array.Empty<string>(),new[]{peer},transfer,false),"explicit file approval receives ordinary files with browser switch off");
Check(!BlipTrustPolicy.Allowed(status,account,Array.Empty<string>(),transfer),"file approval never grants browser opening");
var old= new BlipTransfer{Id=Guid.NewGuid().ToString(),Peer=peer,Direction="Incoming",Status="Completed",Completed=true};
var catalogFile=Path.Combine(root,"senders.json");var catalog=new BlipSenderCatalog(catalogFile);
var names=catalog.Merge(status,new[]{new BlipDevice{Peer=peer,Name="Studio Mac",NameKnown=true}},new[]{old},Array.Empty<string>());
names=new BlipSenderCatalog(catalogFile).Merge(status,Array.Empty<BlipDevice>(),new[]{old},Array.Empty<string>());
Check(names.Single().Name=="Studio Mac","named historical sender stays selectable after restart while offline");
catalog.SetNicknames(account,new[]{(peer,"Travel MacBook")});
names=new BlipSenderCatalog(catalogFile).Merge(status,new[]{new BlipDevice{Peer=peer,Name="Updated remote name",NameKnown=true}},new[]{old},Array.Empty<string>());
Check(names.Single().DisplayName=="Travel MacBook"&&names.Single().Peer==peer,"local nickname survives refresh and restart without changing peer identity");
var phonePeer=peer.Split(':')[0]+":"+Guid.NewGuid();
var phones=catalog.Merge(status,new[]{new BlipDevice{Peer=peer,Name="Phone"},new BlipDevice{Peer=phonePeer,Name="Phone"}},Array.Empty<BlipTransfer>(),Array.Empty<string>());
Check(phones.Count==2&&phones.Select(d=>d.Peer).Distinct().Count()==2,"separate phone identities are retained without duplicate rows");
catalog.SetNicknames(account,new[]{(peer,"Phone"),(phonePeer,"Phone")});
phones=catalog.Merge(status,Array.Empty<BlipDevice>(),Array.Empty<BlipTransfer>(),Array.Empty<string>());
Check(phones.Select(d=>d.DisplayName).Distinct().Count()==2,"identically named devices remain distinguishable in recipient selection");
var namedPhone = new BlipDevice { Peer = phonePeer, Kind = "Phone", Name = "Studio Pixel 9", NameKnown = true, UserName = "Studio tester" };
Check(namedPhone.RecipientCaption(account, namedPhone.DisplayName, namedPhone.ContactName, false) == "Studio tester",
    "a remote person is shown by their Blip username");
Check(namedPhone.RecipientCaption(account, namedPhone.DisplayName, namedPhone.ContactName, true) == "Studio tester · Studio Pixel 9",
    "the username leads when a remote person has multiple targets");
var ownMac = new BlipDevice { Peer = account + ":" + Guid.NewGuid(), Name = "Mac", NameKnown = true, UserName = "Studio tester" };
Check(ownMac.RecipientCaption(account, ownMac.DisplayName, ownMac.ContactName, true) == "Mac",
    "an owned device keeps its registered name even when it resembles a platform name");
var hiddenPhone = new BlipDevice { Peer = phonePeer, Kind = "Phone", Name = "Phone", UserName = "Studio tester" };
Check(hiddenPhone.ToString() == "Studio tester" && hiddenPhone.DisplayName == "Phone" && !hiddenPhone.HasDeviceName,
    "a missing device name keeps the remote username and a readable fallback");
var anotherContactDevice = new BlipDevice { Peer = peer, Kind = "Desktop", UserName = "Studio tester" };
var targets = BlipDevice.GroupDestinations(new[] { ownMac, hiddenPhone, anotherContactDevice }, account).ToList();
Check(targets.Count == 2 && targets[0].Single() == ownMac &&
    targets[1].SequenceEqual(new[] { hiddenPhone, anotherContactDevice }),
    "several unnamed endpoints appear under one contact while owned devices stay separate");
var blankPeer = peer.Split(':')[0] + ":" + Guid.NewGuid();
catalog.Merge(status, new[] { new BlipDevice { Peer = blankPeer, Kind = "Laptop", UserName = "Studio tester" } }, Array.Empty<BlipTransfer>(), Array.Empty<string>());
var restoredContact = catalog.Merge(status, new[] { new BlipDevice { Peer = blankPeer, History = true } },
    Array.Empty<BlipTransfer>(), Array.Empty<string>()).Single(d => d.Peer == blankPeer);
Check(restoredContact.ToString() == "Studio tester" && restoredContact.Kind == "Laptop",
    "a history-only row keeps the username and type of its exact peer");
var otherStatus=new BlipStatus{Authenticated=true,UserId=Guid.NewGuid().ToString()};
Check(catalog.Merge(otherStatus,Array.Empty<BlipDevice>(),Array.Empty<BlipTransfer>(),Array.Empty<string>()).Count==0,"cached sender list is isolated per account");
var tracker=new BlipNoticeTracker();Check(tracker.Update(status,new[]{old}).Count==0,"initial completed history produces no popup");
var active=new BlipTransfer{Id=Guid.NewGuid().ToString(),Peer=peer,Direction="Incoming",Status="Active"};
Check(tracker.Update(status,new[]{old,active}).Single()==active,"active receive gets popup even when Pending was missed");
Check(tracker.Update(status,new[]{old,active}).Count==0,"unchanged active state does not create another popup");
active.Status="Completed";active.Completed=true;Check(tracker.Update(status,new[]{old,active}).Single()==active,"completion updates the receive popup");
var fast=new BlipTransfer{Id=Guid.NewGuid().ToString(),Peer=peer,Direction="Incoming",Status="Completed",Completed=true};
Check(tracker.Update(status,new[]{old,active,fast}).Single()==fast,"fast completed transfer still gets a notification");
var outgoing=new BlipTransfer{Id=Guid.NewGuid().ToString(),Peer=peer,Direction="Outgoing",Status="Active"};
Check(outgoing.IsLive && !old.IsLive && !new BlipTransfer { Status="Cancelled" }.IsLive &&
    !new BlipTransfer { Status="Paused", Dismissed=true }.IsLive,
    "The Send view shows active work without completed, cancelled or dismissed history");
Check(tracker.Update(status,new[]{old,active,fast,outgoing}).Count==0,"outgoing transfers never produce incoming popups");
await Task.WhenAll(Enumerable.Range(0,16).Select(_=>Task.Run(()=>ledger.TryClaim(account,Guid.NewGuid().ToString()))));
Check(System.Text.Json.JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(path))!.Count==17,"manual and automatic receipt claims persist safely when concurrent");
var receivedPath=Path.Combine(root,"received.txt");await File.WriteAllTextAsync(receivedPath,"Generated preview\nSecond line");
var receivedItem=new BlipReceivedItem{Name="received.txt",Path=receivedPath,Size=29};
var completedFile=new BlipTransfer{Direction="Incoming",Status="Completed",Completed=true,ReceivedItems=new(){receivedItem}};
Check(BlipReceivedFiles.LocalPath(completedFile,receivedItem)==receivedPath,"completed incoming file resolves to its actual local path");
completedFile.Status="Active";Check(BlipReceivedFiles.LocalPath(completedFile,receivedItem)==null,"incomplete payload cannot be previewed, copied or opened");
completedFile.Status="Completed";completedFile.Direction="Outgoing";Check(BlipReceivedFiles.LocalPath(completedFile,receivedItem)==null,"outgoing content never becomes a received-file action");
completedFile.Direction="Incoming";completedFile.HasError=true;Check(BlipReceivedFiles.LocalPath(completedFile,receivedItem)==null,"errored payload cannot be opened");completedFile.HasError=false;
Check(BlipReceivedFiles.LocalPath(completedFile,new(){Path=Path.Combine(root,"unlisted.txt")})==null,"unlisted path cannot be substituted for a received file");
receivedItem.Path="file://server/share/received.txt";Check(BlipReceivedFiles.LocalPath(completedFile,receivedItem)==null,"remote file URLs are not probed for automatic previews");receivedItem.Path=receivedPath;
Check((await BlipReceivedFiles.TextPreviewAsync(receivedPath)).StartsWith("Generated preview"),"plain-text preview reads received bytes without executing content");
File.Delete(receivedPath);Check(BlipReceivedFiles.LocalPath(completedFile,receivedItem)==null,"missing received file disables its actions");
