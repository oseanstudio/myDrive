using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;
namespace MyDrive;
public sealed partial class MainWindow
{
    private async Task OpenSmbShare()
    {
        if(busy||!storageReady)return;
        var panel=new StackPanel{Spacing=12,MinWidth=compact?280:420};
        panel.Children.Add(Text("Open the shared folder directly on your network. Files open in their usual apps and save back to the share. For offline copies on both computers, use Sync.",12));
        var address=new TextBox{Header="Shared folder",PlaceholderText=@"\\computer\share or smb://computer/share"};panel.Children.Add(address);
        var account=new StackPanel{Spacing=10};var user=new TextBox{Header="Username (optional)",PlaceholderText=@"COMPUTER\name"};var password=new PasswordBox{Header="Password"};account.Children.Add(user);account.Children.Add(password);panel.Children.Add(new Expander{Header="Use another account",Content=account,HorizontalAlignment=HorizontalAlignment.Stretch});
        var validation=new InfoBar{Severity=InfoBarSeverity.Error,IsClosable=false};panel.Children.Add(validation);
        var dialog=new ContentDialog{XamlRoot=root.XamlRoot,Title="Open shared folder",Content=new ScrollViewer{Content=panel,MaxHeight=compact?330:520},PrimaryButtonText="Connect and open",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Primary};
        bool connecting=false;Bookmark? connected=null;List<RemoteFile>? files=null;
        dialog.Closing+=(_,args)=>{if(connecting)args.Cancel=true;};
        dialog.PrimaryButtonClick+=async(_,args)=>{
            if(connecting){args.Cancel=true;return;}var deferral=args.GetDeferral();connecting=true;dialog.IsPrimaryButtonEnabled=false;validation.IsOpen=false;
            try{
                var location=address.Text.Trim();string host,path;
                if(location.StartsWith("smb://",StringComparison.OrdinalIgnoreCase)){
                    if(!Uri.TryCreate(location,UriKind.Absolute,out var uri)||uri.UserInfo.Length>0||uri.Query.Length>0||uri.Fragment.Length>0)throw new IOException("Enter an SMB address without an account, query or fragment.");
                    host=uri.Host;path=Uri.UnescapeDataString(uri.AbsolutePath).Trim('/');
                }else{
                    if(!location.StartsWith(@"\\"))throw new IOException(@"Enter a shared folder such as \\computer\share.");
                    var pieces=location[2..].Replace('/','\\').Split('\\',2);if(pieces.Length!=2)throw new IOException("Include the share name after the computer name.");host=pieces[0];path=pieces[1].Trim('\\');
                }
                if(host.Length==0||path.Length==0||path.Split(['/','\\']).Any(p=>p is "." or ".."))throw new IOException("Enter a computer and share name without parent-folder segments.");
                var b=new Bookmark{protocol="smb",nickname=host+" · "+path,host=host,path=path,username=user.Text.Trim()};b.credentials_ref="myDrive/"+b.id;
                var credential=new Credentials{password=password.Password};using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(20));
                await CoreBridge.Call(new{action="smb.connect",bookmark=b,credentials=credential},timeout.Token);
                var result=await CoreBridge.Call(new{action="list",bookmark=b,credentials=credential,path=""},timeout.Token);
                files=result.Deserialize<List<RemoteFile>>()??new();
                var next=bookmarks.Append(b).ToList();CredentialStore.Save(b.id,b.username,credential);try{await CoreBridge.Save(next);}catch{CredentialStore.Delete(b.id);throw;}
                bookmarks=next;connected=b;
            }catch(Exception e){args.Cancel=true;validation.Title="Could not open this share";validation.Message=e is OperationCanceledException?"The server took too long to respond. Check that the computer is online and try again.":e.Message;validation.IsOpen=true;}
            finally{connecting=false;dialog.IsPrimaryButtonEnabled=true;deferral.Complete();}
        };
        await ShowDialog(dialog);
        if(connected!=null){health[connected.id]="Connected";currentBookmark=connected;currentFiles=files??new();currentPath="";currentView="files";Render();await Record(new(DateTimeOffset.Now,"Open shared folder",connected.nickname,connected.Location,true));}
    }
}
