using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using System.Text.Json;
namespace MyDrive;
public sealed partial class MainWindow
{
    // Fixture-only native rendering. No account request, transfer, or production profile access.
    public async Task DiagnoseBlip(string directory)
    {
        diagnosticMode = true; syncTimer.Stop(); healthTimer.Stop(); blipTimer?.Dispose();
        var report = new Dictionary<string, object>();
        try
        {
            Directory.CreateDirectory(directory); await Task.Delay(700);
            currentView = "transfers"; storageReady = true;
            navigation.SelectedItem = navigation.MenuItems.OfType<Microsoft.UI.Xaml.Controls.NavigationViewItem>().First(i => i.Tag?.ToString() == "transfers");
            blipFixtureRunning = false; blipSnapshot = null; SetMode(true); await Task.Delay(200);
            var position = AppWindow.Position; var size = AppWindow.Size;
            if (quickExpand.Visibility != Visibility.Visible)
                throw new IOException("The fixed popup must show its footer action.");
            DismissAt(new(position.X + size.Width / 2, position.Y + size.Height - 4), allowDiagnostic: true);
            if (!AppWindow.IsVisible) throw new IOException("A click in the popup footer dismissed the popup.");
            void Stable() { if (AppWindow.Position.X != position.X || AppWindow.Position.Y != position.Y || AppWindow.Size.Width != size.Width || AppWindow.Size.Height != size.Height) throw new IOException("Blip view changed compact popup bounds."); }
            await Capture(directory, "blip-stopped.png");
            var (choice, _) = BlipConnectionDialog(); var choosing = ShowDialog(choice);
            await Task.Delay(200); Stable(); await Capture(directory, "blip-connection-choice.png", choice); choice.Hide(); await choosing;
            blipFixtureRunning = true; blipSnapshot = new(new(), new(), new()); Render(); await Task.Delay(150); Stable(); await Capture(directory, "blip-signin.png");
            string peer = "11111111-1111-4111-8111-111111111111:22222222-2222-4222-8222-222222222222";
            blipSnapshot = new(new() { Authenticated = true, ReceivePolicyVerified = true },
                Enumerable.Range(0,4).Select(i=>new BlipDevice{Peer=i==0?peer:"11111111-1111-4111-8111-111111111111:"+Guid.NewGuid(),Name=new[]{"Studio desktop","Laptop","Phone","Tablet"}[i],Contact="studio@example.test",UserName="Studio tester",NameKnown=true}).ToList(),
                Enumerable.Range(0, 12).Select(i => new BlipTransfer { Id = Guid.NewGuid().ToString(), Peer = peer, Direction = i % 2 == 0 ? "Incoming" : "Outgoing", Status = i == 0 ? "Pending" : i == 1 ? "Active" : i == 2 ? "Completed" : i == 3 ? "Paused" : "Invited", Completed = i == 2 }).ToList());
            Render(); await Task.Delay(250); Stable(); await Capture(directory, "blip-transfers-light.png");
            var identity = quickHeader.Children.OfType<StackPanel>().First();
            if (identity.ActualWidth < identity.Children.OfType<TextBlock>().Sum(text => text.DesiredSize.Width) + identity.Spacing - 1)
                throw new IOException("The popup title clips the application version");
            report["popup_version_visible"] = true;
            blipSnapshot.Status.DesktopSession = true; blipSnapshot.Status.ReceivePolicyVerified = false;
            Render(); await Task.Delay(200); Stable(); await Capture(directory, "blip-desktop-session.png");
            blipSnapshot.Status.Authenticated = false; Render(); await Task.Delay(150); Stable(); await Capture(directory, "blip-desktop-signedout.png");
            blipSnapshot.Status.Authenticated = true;
            blipSnapshot.Status.UserId="33333333-3333-4333-8333-333333333333";blipSnapshot.Status.DeviceId="44444444-4444-4444-8444-444444444444";
            var senderChoices=ChooseLinkSenders();await Task.Delay(200);if(activeDialog==null)throw new IOException("Sender permissions did not open");await Capture(directory,"blip-sender-permissions.png",activeDialog);activeDialog.Hide();await senderChoices;
            var outbox=Path.Combine(directory,"generated-outbox");
            var clipboardLink=await BlipClipboard.PrepareTextAsync("https://example.test/clipboard",outbox);
            if(await BlipLinkOpener.ReadShortcutAsync(clipboardLink.Paths.Single()) is not {} prepared||prepared.Host!="example.test")throw new IOException("Clipboard web-link format did not round-trip");
            var clipboardBatch=await BlipClipboard.PrepareTextAsync("https://example.test/one\nhttps://example.test/two",outbox);
            if(clipboardBatch.Paths.Count!=2||(await BlipLinkOpener.ReadShortcutAsync(clipboardBatch.Paths[1]))?.AbsolutePath!="/two")
                throw new IOException("Multiple clipboard links did not round-trip");
            clipboardBatch.Discard();
            async Task CheckRecipientList(string capture, List<string>? paths = null, string? description = null)
            {
                var showing = ShowBlipSend(paths, description);
                await Task.Delay(350);
                if (activeDialog?.Content is not StackPanel form || form.Children.OfType<ListView>().SingleOrDefault() is not { } list ||
                    list.Items.Count != blipSnapshot.Devices.Count || list.SelectedIndex != -1 ||
                    list.Items.OfType<ListViewItem>().Any(item => item.Content is not Grid deviceRow ||
                        deviceRow.Children.OfType<Button>().Count() != 2 ||
                        deviceRow.Children.OfType<Button>().First().IsEnabled != (paths?.Count > 0) ||
                        !deviceRow.Children.OfType<Button>().Last().IsEnabled) ||
                    !string.IsNullOrEmpty(activeDialog.PrimaryButtonText))
                    throw new IOException("The recipient list must send on click whenever a payload is ready");
                activeDialog.UpdateLayout();
                await Task.Delay(180);
                Stable();
                await Capture(directory, capture, activeDialog);
                activeDialog.Hide();
                await showing;
            }
            await CheckRecipientList("blip-send-devices.png");
            await CheckRecipientList("blip-paste-send.png", clipboardLink.Paths, clipboardLink.Description);
            await CheckRecipientList("blip-drop-send.png", clipboardLink.Paths, "Dropped file");
            var droppedFolder = Path.Combine(directory, "Fixture dropped folder");
            Directory.CreateDirectory(droppedFolder);
            var dropping = HandleFileDrop(new() { droppedFolder });
            await Task.Delay(300);
            if (activeDialog?.Content is not StackPanel folderForm ||
                !folderForm.Children.OfType<Button>().Select(button => button.Content?.ToString())
                    .SequenceEqual(new[] { "Send with Blip", "Sync folder", "Share over SMB" }))
                throw new IOException("A dropped folder did not show the three sharing actions");
            await Capture(directory, "blip-drop-folder.png", activeDialog);
            activeDialog.Hide();
            await dropping;
            report["folder_drop_actions"] = true;
            var originalDevices = blipSnapshot.Devices.ToArray();
            blipSnapshot.Devices.AddRange(Enumerable.Range(1, 9).Select(index => new BlipDevice {
                Peer = "11111111-1111-4111-8111-111111111111:" + Guid.NewGuid(),
                Name = $"Very long name for checking recipient clipping on studio device {index}",
                NameKnown = true
            }));
            await CheckRecipientList("blip-send-many-devices.png");
            blipSnapshot.Devices.Clear();
            var empty = ShowBlipSend();
            await Task.Delay(250);
            if (activeDialog?.Content is not StackPanel emptyForm ||
                !emptyForm.Children.OfType<TextBlock>().Any(text => text.Text == "No other Blip devices are available.") ||
                !string.IsNullOrEmpty(activeDialog.PrimaryButtonText))
                throw new IOException("An empty recipient list did not show its unavailable state");
            activeDialog.Hide();
            await empty;
            blipSnapshot.Devices.AddRange(originalDevices);
            report["visible_recipient_list"] = true;
            clipboardLink.Discard();if(Directory.Exists(clipboardLink.StagingDirectory))throw new IOException("Cancelled clipboard staging was retained");
            var plain=await BlipClipboard.PrepareTextAsync("https://example.test/\r\nURL=file:///bad",outbox);if(Path.GetExtension(plain.Paths.Single())!=".txt")throw new IOException("Multiline clipboard was interpreted as a shortcut");plain.Discard();
            var original=Path.Combine(directory,"copied-user-file.txt");await File.WriteAllTextAsync(original,"Generated fixture");new BlipClipboardPayload(new(){original},"Copied file").Discard();if(!File.Exists(original))throw new IOException("Clipboard cancellation removed a copied file");
            report["clipboard_fixture_checks"]="web-link round trip, recipient chooser, cancel cleanup, multiline text, copied-file preservation; no system clipboard access";
            var incoming=blipSnapshot.Transfers.First();incoming.ItemNames=new(){"Generated transfer.bin"};incoming.TotalBytes=1000;incoming.Progress=450;
            incoming.Status="Invited";UpdateIncomingBlip(incoming,true);await Task.Delay(200);await Capture(directory,"blip-incoming-pending.png",blipIncomingWindow!.Surface);
            if (blipIncomingWindow.AppWindow.Presenter is not OverlappedPresenter { HasTitleBar: true, IsResizable: false })
                throw new IOException("The receive notice does not use the native Windows title bar");
            report["native_receive_chrome"] = true;
            var anchor=tray?.Anchor()??AppWindow.Position;var placement=blipIncomingWindow.AppWindow.Position;var popupSize=blipIncomingWindow.AppWindow.Size;
            if(Math.Abs(placement.X+popupSize.Width-anchor.X)>popupSize.Width||Math.Abs(placement.Y-anchor.Y)>popupSize.Height+48)throw new IOException("Receive notice is not anchored near the tray icon");report["receive_notice_near_tray"]="pass";report["grouped_sender_device_count"]=4;
            blipIncomingWindow.ShowFailure("Blip did not confirm receiving. You can retry Receive here.");await Capture(directory,"blip-incoming-retry.png",blipIncomingWindow.Surface);blipIncomingWindow.ClearFailure();
            incoming.Status="Active";UpdateIncomingBlip(incoming,true);await Task.Delay(200);await Capture(directory,"blip-incoming-active.png",blipIncomingWindow.Surface);
            AppWindow.Hide();UpdateIncomingBlip(incoming,false);await Task.Delay(100);await Capture(directory,"blip-incoming-tray-hidden.png",blipIncomingWindow.Surface);SetMode(true);position=AppWindow.Position;size=AppWindow.Size;
            var picture=Path.Combine(directory,"Generated preview.png");File.Copy(Path.Combine(AppContext.BaseDirectory,"Assets","myDrive.png"),picture,true);
            var textFile=Path.Combine(directory,"Generated document with a long name for overflow checking.txt");await File.WriteAllTextAsync(textFile,"Received document preview\nGenerated local fixture only\nNo clipboard or external app access");
            var receivedFolder=Path.Combine(directory,"Generated folder");Directory.CreateDirectory(receivedFolder);
            incoming.Status="Completed";incoming.Completed=true;incoming.ReceivedItems=new(){new(){Name=Path.GetFileName(picture),Path=picture,Size=new FileInfo(picture).Length}};
            UpdateIncomingBlip(incoming,true);await blipIncomingWindow.FileCard.LoadedPreview;await Task.Delay(300);
            if(blipIncomingWindow.FileCard.PreviewKind!="thumbnail")throw new IOException("Received image thumbnail did not load");
            if (blipIncomingWindow.Surface is Border { Child: ScrollViewer { ScrollableHeight: > 1 } })
                throw new IOException("The native caption clips single-file receive actions");
            await Capture(directory,"blip-incoming-complete.png",blipIncomingWindow.Surface);blipIncomingWindow.Stop();
            var calls=new List<BlipFileAction>();
            var card=new BlipReceivedCard(()=>0,(action,_,item)=>{if(item.Path!=textFile)throw new IOException("File action used the wrong received path");calls.Add(action);return Task.CompletedTask;});
            incoming.ReceivedItems=new(){new(){Name=Path.GetFileName(textFile),Path=textFile},new(){Name="Generated folder",Path=receivedFolder,IsDirectory=true}};
            card.SetTransfer(incoming);await card.LoadedPreview;
            if(card.PreviewKind!="text")throw new IOException("Received text preview did not load");
            foreach(var label in new[]{"Open","Open with…","Copy","Copy path","Open folder","Show in folder","Print","Properties","Copy listed files","Copy listed paths"})if(!card.ActionLabels.Contains(label))throw new IOException("Missing received action: "+label);
            foreach(var action in Enum.GetValues<BlipFileAction>())await card.Perform(action);
            if(calls.Count!=Enum.GetValues<BlipFileAction>().Length)throw new IOException("A received action did not dispatch");
            var previewDialog=new Microsoft.UI.Xaml.Controls.ContentDialog{Title="Received files",Content=card,CloseButtonText="Done",XamlRoot=root.XamlRoot};
            var showing=ShowDialog(previewDialog);await Task.Delay(650);previewDialog.UpdateLayout();await Capture(directory,"blip-received-text-actions.png",previewDialog);previewDialog.Hide();await showing;
            incoming.ReceivedItems=new(){new(){Name="Generated folder",Path=receivedFolder,IsDirectory=true}};card.SetTransfer(incoming);await card.LoadedPreview;if(card.PreviewKind!="folder")throw new IOException("Folder preview failed");
            incoming.ReceivedItems=new(){new(){Name="Missing.txt",Path=Path.Combine(directory,"not-present.txt")}};card.SetTransfer(incoming);await card.LoadedPreview;if(card.PreviewKind!="missing")throw new IOException("Missing file was not disabled");
            incoming.Status="Active";card.SetTransfer(incoming);await card.LoadedPreview;if(card.PreviewKind!="placeholder")throw new IOException("Incomplete file exposed a preview");incoming.Status="Completed";
            report["received_file_checks"]="image thumbnail, text preview, folder, missing/incomplete guards, all menu actions dispatched through fixture callback; no clipboard, printing or external app launch";
            report["independent_receive_popup_lifecycle"]="pending, active progress, completed; renders while tray hidden";
            var oldTheme = colorTheme; colorTheme = ElementTheme.Dark; root.RequestedTheme = colorTheme; root.Background = Brush("ApplicationPageBackgroundThemeBrush"); Render(); await Task.Delay(200); Stable(); await Capture(directory, "blip-transfers-dark.png");
            colorTheme = oldTheme; root.RequestedTheme = colorTheme; root.Background = Brush("ApplicationPageBackgroundThemeBrush");
            blipFailure = "A transfer request stopped before its result was confirmed. Refresh transfers before retrying."; Render(); await Task.Delay(150); Stable(); await Capture(directory, "blip-error.png"); blipFailure = "";
            SetMode(false); await Task.Delay(200); await Capture(directory, "blip-full-window.png");
            report["compact_size"] = new[] { size.Width, size.Height }; report["stable_bounds"] = true;
            report["completion_requires_native_completed_state"] = !new BlipTransfer { Status = "Invited", Completed = true }.ConfirmedComplete && !new BlipTransfer { Status = "Completed", Completed = false }.ConfirmedComplete;
            report["fixtures_only"] = true; report["result"] = "pass";
        }
        catch (Exception e) { report["result"] = "fail"; report["error"] = e.ToString(); }
        finally { await File.WriteAllTextAsync(Path.Combine(directory, "blip-report.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true })); Quit(); }
    }
}
