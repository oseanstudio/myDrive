import java.time.Instant;
import java.util.*;
import bsarchive.*;
import net.blip.libblip.*;
import net.blip.libblip.frontend.Transfer;
import okio.ByteString;

// Typed saved-transfer fixture, no host, account or filesystem access.
public class LinkMetadataCheck {
    static Transfer transfer(Metadata metadata, Transfer.Direction direction, Transfer.Status status) {
        return new Transfer(UUID.randomUUID().toString(), null, 0, metadata, "", "", false,
            null, null, direction, status, false, false, 0, new net.blip.libblip.frontend.ConnStats(), 0, Instant.now(), ByteString.EMPTY);
    }
    public static void main(String[] args) {
        // Exercise the real native dispatch dependency; absolute-path fixtures alone miss it.
        String downloads = com.sun.jna.platform.win32.Shell32Util.getKnownFolderPath(com.sun.jna.platform.win32.KnownFolders.FOLDERID_Downloads);
        if (!java.nio.file.Path.of(downloads).isAbsolute()) throw new AssertionError("Windows known-folder resolution failed");
        var file = new AnyItem(new bsarchive.File(32,0,false,ByteString.EMPTY),null,null,null,ByteString.EMPTY);
        var symlink = new AnyItem(null,null,new Link("https://example.com/",ByteString.EMPTY),null,ByteString.EMPTY);
        var folder = new AnyItem(null,new Folder(ByteString.EMPTY),null,null,ByteString.EMPTY);
        String local = "C:\\fixture\\Received.url";
        var metadata = new Metadata(Map.of("Received.url",file,"Symlink.url",symlink,"Folder",folder,"Folder/nested.url",file),
            Map.of("Received.url",local,"Symlink.url","C:\\fixture\\Symlink.url","Folder","C:\\fixture\\Folder","Folder/nested.url","C:\\fixture\\Folder\\nested.url"),ByteString.EMPTY);
        if (!BlipBridge.receivedLinkFiles(transfer(metadata,Transfer.Direction.Incoming,Transfer.Status.Completed)).equals(List.of(local))) throw new AssertionError("Expected only completed incoming root shortcut files");
        var received=BlipBridge.receivedItems(transfer(metadata,Transfer.Direction.Incoming,Transfer.Status.Completed));
        if(received.size()!=2||received.toString().contains("Symlink.url")||received.toString().contains("nested.url"))throw new AssertionError("Received actions must resolve only root regular files and folders");
        if(!BlipBridge.receivedItems(transfer(metadata,Transfer.Direction.Outgoing,Transfer.Status.Completed)).isEmpty()||!BlipBridge.receivedItems(transfer(metadata,Transfer.Direction.Incoming,Transfer.Status.Active)).isEmpty())throw new AssertionError("Incomplete/outgoing content exposed as received files");
        if (!BlipBridge.receivedLinkFiles(transfer(metadata,Transfer.Direction.Outgoing,Transfer.Status.Completed)).isEmpty()) throw new AssertionError("Outgoing link opened");
        if (!BlipBridge.receivedLinkFiles(transfer(metadata,Transfer.Direction.Incoming,Transfer.Status.Pending)).isEmpty()) throw new AssertionError("Pending link opened");
        var single = new Metadata(Map.of("Received.url",file),Map.of(),ByteString.EMPTY);
        if (!BlipBridge.linkOnly(transfer(single,Transfer.Direction.Incoming,Transfer.Status.Pending))) throw new AssertionError("Link-only request not recognized");
        if (BlipBridge.linkOnly(transfer(metadata,Transfer.Direction.Incoming,Transfer.Status.Pending))) throw new AssertionError("Mixed request accepted automatically");
        var large = new AnyItem(new bsarchive.File(65537,0,false,ByteString.EMPTY),null,null,null,ByteString.EMPTY);
        if (BlipBridge.linkOnly(transfer(new Metadata(Map.of("large.url",large),Map.of(),ByteString.EMPTY),Transfer.Direction.Incoming,Transfer.Status.Pending))) throw new AssertionError("Oversized shortcut accepted automatically");
        System.out.println("{\"ok\":true,\"typedMetadata\":true,\"rootOnly\":true,\"symlinksExcluded\":true,\"incomingCompletedOnly\":true,\"boundedLinkOnly\":true}");
    }
}
