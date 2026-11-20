import java.awt.GraphicsEnvironment;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import net.blip.libblip.*;
import net.blip.libblip.event.*;
import net.blip.libblip.frontend.State;
import net.blip.libblip.frontend.Transfer;
import okio.ByteString;

/** Experimental adapter for Blip 1.2.8's private native interface. No desktop entry point. */
public class BlipBridge {
    static final ByteString EMPTY = ByteString.EMPTY;
    static final String PREFIX = "MYDRIVE_JSON ";
    static final ByteBuffer BUFFER = ByteBuffer.allocateDirect(32 * 1024 * 1024);
    static Path profile;
    static String desktopSocket;

    public static void main(String[] args) {
        int exit = 0;
        try {
            if (args.length != 3 && args.length != 4) throw new IllegalArgumentException("Expected mode, profile, command, optional socket");
            if (args.length == 4) {
                if (!args[0].equals("request") || !Set.of("status", "devices", "transfers", "poll", "send", "accept").contains(args[2]))
                    throw new IllegalArgumentException("Desktop session command not allowed");
                desktopSocket = Path.of(args[3]).toAbsolutePath().normalize().toString();
            }
            if (!GraphicsEnvironment.isHeadless()) throw new IllegalStateException("Headless JVM required");
            profile = Path.of(args[1]).toRealPath();
            if (!Files.isRegularFile(profile.resolve("mydrive-profile.json")))
                throw new IllegalArgumentException("Not an initialized MyDrive test profile");
            LibBlip.Companion.configureLogging(profile.resolve("cache").toString(), "MyDriveHeadless", LogLevel.ERROR.getRaw());
            if (args[0].equals("host")) host();
            else if(args[0].equals("desktop-host"))desktopHost();
            else if (args[0].equals("desktop-request") && Set.of("status", "poll", "send", "accept").contains(args[2])) {
                desktopSocket = FlavorKt.getRpcSockPath(net.blip.desktop.FlavorDesktopProd.INSTANCE);
                request(args[2]);
            }
            else if (args[0].equals("request")) request(args[2]);
            else throw new IllegalArgumentException("Unknown bridge mode");
        } catch (Throwable error) {
            // Exception messages from native messages may contain login codes. Emit only the class.
            emit(Map.of("ok", false, "error", error.getClass().getSimpleName()));
            exit = 1;
        }
        System.exit(exit);
    }

    static Client connect() {
        return new Client(desktopSocket == null ? profile.resolve("cache/sock").toString() : desktopSocket, "MyDriveHeadless/0.1", false);
    }

    static State snapshot(Client client) {
        BUFFER.clear();
        return client.getState(BUFFER);
    }

    static void desktopHost() throws Exception {
        var flavor=net.blip.desktop.FlavorDesktopProd.INSTANCE;
        Path storage=Path.of(flavor.getStoragePath());
        if(!Files.isRegularFile(storage.resolve("state.dat"))){emit(Map.of("ok",false,"error","desktop_profile_missing"));return;}
        desktopSocket=net.blip.libblip.FlavorKt.getRpcSockPath(flavor);
        try(var channel=java.nio.channels.FileChannel.open(profile.resolve("desktop-host.lock"),StandardOpenOption.CREATE,StandardOpenOption.WRITE);var lock=channel.tryLock()) {
            if(lock==null)throw new IllegalStateException("Background desktop helper already running");
            // The same native host election and profile paths used by desktop Blip.
            // Its interprocess mutex arbitrates ownership; no auth/state file is copied.
            LibBlip.Companion.startHosting(true,flavor.getCachesPath(),flavor.getStoragePath(),flavor.getServerAddr());
            Runtime.getRuntime().addShutdownHook(new Thread(()->{try{LibBlip.Companion.stopHosting();}catch(Throwable ignored){}}));
            Thread stopper=new Thread(()->{try{new BufferedReader(new InputStreamReader(System.in,StandardCharsets.UTF_8)).readLine();}catch(Exception ignored){}System.exit(0);});stopper.setDaemon(true);stopper.start();
            Client client=connect();State state=snapshot(client);
            emit(Map.of("ok",true,"event","host_ready","desktop_session",true,"background",true));
            while(true) {
                if(state.getUser_agent()==null||state.getUser_agent().getApp_id().isBlank()) {
                    var hardware=new net.blip.desktop.HardwareInfoDesktop(flavor.getStoragePath());
                    client.dispatch(new SetUserAgent(net.blip.libblip.UserAgent_createKt.create(UserAgent.Companion,hardware,flavor),EMPTY));
                }
                Thread.sleep(250);state=snapshot(client);
            }
        }
    }

    static void host() throws Exception {
        // Keep profile state local and separate from the user's desktop app.
        Path lockPath = profile.resolve("host.lock");
        try (var channel = java.nio.channels.FileChannel.open(lockPath, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             var lock = channel.tryLock()) {
            if (lock == null) throw new IllegalStateException("Profile already hosted");
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                try { LibBlip.Companion.stopHosting(); } catch (Throwable ignored) {}
            }));
            LibBlip.Companion.startHosting(true, profile.resolve("cache").toString(), profile.resolve("state").toString(), "https://prod.blip.net");
            Thread stopper = new Thread(() -> {
                try {
                    var reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
                    String line = reader.readLine();
                    if (line == null || line.equals("STOP")) System.exit(0);
                } catch (Exception ignored) { System.exit(1); }
            });
            stopper.setDaemon(true);
            stopper.start();
            Client client = connect();
            snapshot(client); // Establish the RPC session before sending events, as Blip's Core does.
            // Request disabled native auto-accept; verify after authentication before our receiver acts.
            client.dispatch(new TransferSetAutoAccept(false, EMPTY));
            client.dispatch(new TransferSetCustomDefaultSavePath(profile.resolve("downloads").toString(), EMPTY));
            client.dispatch(new SetUserAgent(new UserAgent("", "MyDrive headless", DeviceKind.Desktop,
                System.getProperty("os.name"), System.getProperty("os.version"), "mydrive.blip.poc",
                "MyDrive headless proof", "0.1.0", "1", EMPTY), EMPTY));
            emit(Map.of("ok", true, "event", "host_ready", "headless", true, "receiving_verified", false));
            Set<String> accepted = new HashSet<>();
            boolean configuredAfterAuth = false;
            boolean receivingVerified = false;
            AtomicBoolean policyConfirmed = new AtomicBoolean(false);
            while (true) {
                State state = snapshot(client);
                boolean authenticated = state.getAuth() != null && state.getAuth().getToken().size() != 0;
                if (!authenticated) { configuredAfterAuth = false; receivingVerified = false; }
                if (authenticated && !configuredAfterAuth) {
                    client.dispatch(new TransferSetAutoAccept(false, EMPTY));
                    client.dispatch(new TransferSetCustomDefaultSavePath(profile.resolve("downloads").toString(), EMPTY));
                    configuredAfterAuth = true;
                    Thread watchdog = new Thread(() -> {
                        try { Thread.sleep(5000); } catch (InterruptedException ignored) {}
                        if (!policyConfirmed.get()) {
                            emit(Map.of("ok", false, "event", "receive_policy_unconfirmed", "action", "stopping_host"));
                            System.exit(1);
                        }
                    });
                    watchdog.setDaemon(true); watchdog.start();
                    continue;
                }
                if (authenticated && !receivingVerified && state.getConfig().getAuto_accept_disabled()
                        && profile.resolve("downloads").toString().equals(state.getConfig().getCustom_default_save_path())) {
                    receivingVerified = true;
                    policyConfirmed.set(true);
                    emit(Map.of("ok", true, "event", "receive_policy_verified"));
                }
                Set<String> trusted = new HashSet<>(Files.readAllLines(profile.resolve("trusted-peers.txt")));
                for (var item : state.getTransfers().entrySet()) {
                    Transfer transfer = item.getValue();
                    String peer = peerString(transfer.getPeer_id());
                    if (receivingVerified && transfer.getDirection() == Transfer.Direction.Incoming
                            && transfer.getStatus() == Transfer.Status.Invited
                            && trusted.contains(peer) && !accepted.contains(item.getKey())) {
                        // Distinct directory prevents different transfers overwriting each other's files.
                        Path destination = transferDirectory(item.getKey());
                        Files.createDirectories(destination);
                        client.dispatch(new TransferAcceptanceRequested(item.getKey(), destination.toString(), EMPTY));
                        accepted.add(item.getKey());
                        emit(Map.of("ok", true, "event", "acceptance_dispatched", "transfer_id", item.getKey()));
                    }
                }
                Thread.sleep(100);
            }
        }
    }

    static Path transferDirectory(String id) {
        UUID.fromString(id);
        Path inbox = profile.resolve("downloads");
        if (desktopSocket != null && !com.sun.jna.Platform.isWindows()) {
            String override = System.getProperty("mydrive.inbox");
            if (override != null) {
                inbox = Path.of(override).normalize();
                if (!inbox.isAbsolute()) throw new IllegalArgumentException("Expected absolute receive directory");
            }
        }
        return inbox.resolve(id).normalize();
    }

    static List<String> input() throws Exception {
        List<String> values = new ArrayList<>();
        try (var reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            for (String line; (line = reader.readLine()) != null; ) {
                if (line.length() > 1_048_576 || values.size() >= 1000) throw new IllegalArgumentException("Input too large");
                values.add(new String(Base64.getDecoder().decode(line), StandardCharsets.UTF_8));
            }
        }
        return values;
    }

    static void requireAuth(State state) {
        if (state.getAuth() == null || state.getAuth().getToken().size() == 0)
            throw new IllegalStateException("Authentication required");
    }

    static void request(String command) throws Exception {
        List<String> values = input();
        Client client = connect();
        State initial = snapshot(client);
        switch (command) {
            case "status" -> emit(status(initial));
            case "devices" -> emit(Map.of("ok", true, "devices", devices(initial)));
            case "transfers" -> emit(Map.of("ok", true, "transfers", transfers(initial)));
            case "poll" -> emit(Map.of("ok", true, "status", status(initial), "devices", devices(initial), "transfers", transfers(initial)));
            case "login" -> {
                if (values.size() != 2) throw new IllegalArgumentException("Expected email and device name");
                if (initial.getAuth() != null && initial.getAuth().getToken().size() != 0)
                    throw new IllegalStateException("Profile already authenticated");
                client.dispatch(new SendRegistrationCodeRequested(values.get(0), values.get(1), EMPTY));
                emit(awaitRegistration(client, false));
            }
            case "verify" -> {
                if (values.size() != 3) throw new IllegalArgumentException("Expected code, dedupe ID and name");
                client.dispatch(new RegistrationRequested(values.get(0), values.get(1), values.get(2), DeviceKind.Desktop, EMPTY));
                emit(awaitRegistration(client, true));
            }
            case "send" -> {
                requireAuth(initial);
                if (values.size() < 3) throw new IllegalArgumentException("Expected peer, request identifier, and files");
                PeerId peer = parsePeer(values.get(0));
                String id = values.get(1).isEmpty() ? UUID.randomUUID().toString() : UUID.fromString(values.get(1)).toString();
                if (initial.getTransfers().containsKey(id)) throw new IllegalStateException("Transfer identifier already exists");
                List<String> paths = new ArrayList<>();
                for (String value : values.subList(2, values.size())) {
                    Path path = Path.of(value).toRealPath();
                    if (!Files.isRegularFile(path) && !Files.isDirectory(path)) throw new IllegalArgumentException("Unsupported file");
                    paths.add(path.toString());
                }
                client.dispatch(new TransferCreateRequested(id, peer, EMPTY));
                client.dispatch(new TransferAddContentRequested(id, paths, EMPTY));
                client.dispatch(new TransferInviteRequested(id, peer, EMPTY));
                emit(Map.of("ok", true, "phase", "dispatch_requested", "transfer_id", id, "completed", false));
            }
            case "accept" -> {
                requireAuth(initial);
                if (values.size() != 1) throw new IllegalArgumentException("Expected transfer ID");
                Transfer transfer = initial.getTransfers().get(values.get(0));
                if(transfer!=null&&transfer.getDirection()==Transfer.Direction.Incoming&&!transfer.is_dismissed()&&transfer.getLocal_err()==null&&transfer.getRemote_err()==null
                        &&(transfer.getStatus()==Transfer.Status.Pending||transfer.getStatus()==Transfer.Status.Active||transfer.getStatus()==Transfer.Status.Completed)) {
                    emit(Map.of("ok",true,"phase","already_receiving","native_status",transfer.getStatus().name(),"completed",transfer.getStatus()==Transfer.Status.Completed));return;
                }
                if (transfer == null || transfer.getDirection() != Transfer.Direction.Incoming
                        || transfer.getStatus() != Transfer.Status.Invited
                        || transfer.is_dismissed() || transfer.getLocal_err()!=null || transfer.getRemote_err()!=null) {
                    emit(Map.of("ok",false,"error","accept_not_waiting","native_status",transfer==null?"Missing":transfer.getStatus().name()));
                    return;
                }
                Path destination = transferDirectory(values.get(0));
                Files.createDirectories(destination);
                client.dispatch(new TransferAcceptanceRequested(values.get(0), destination.toString(), EMPTY));
                boolean confirmed=false;String last=transfer.getStatus().name();
                // Keep the RPC client alive and confirm native acknowledgement, not just enqueueing.
                long deadline=System.nanoTime()+5_000_000_000L;
                while(System.nanoTime()<deadline) {
                    // getState may wait for a revision; bound the wait independently of the CLI timeout.
                    var update=java.util.concurrent.CompletableFuture.supplyAsync(()->snapshot(client));
                    State state;
                    try {state=update.get(Math.max(1,(deadline-System.nanoTime())/1_000_000L),java.util.concurrent.TimeUnit.MILLISECONDS);}
                    catch(java.util.concurrent.TimeoutException timeout){break;}
                    var after=state.getTransfers().get(values.get(0));if(after==null)continue;
                    last=after.getStatus().name();
                    if(after.getLocal_err()!=null||after.getRemote_err()!=null||after.getStatus()==Transfer.Status.Cancelled)break;
                    if(after.getStatus()==Transfer.Status.Active||after.getStatus()==Transfer.Status.Completed||after.getProgress()>transfer.getProgress()||after.getStatus()==Transfer.Status.Pending&&transfer.getStatus()==Transfer.Status.Invited){confirmed=true;break;}
                    Thread.sleep(125);
                }
                emit(Map.of("ok",confirmed,"phase",confirmed?"receiving_confirmed":"acceptance_unconfirmed","error",confirmed?"":"acceptance_unconfirmed","native_status",last,"completed",last.equals("Completed")));
            }
            default -> throw new IllegalArgumentException("Unsupported command");
        }
    }

    static Map<String,Object> awaitRegistration(Client client, boolean verify) throws Exception {
        for (int count = 0; count < 100; count++) {
            State state = snapshot(client);
            var auth = state.getAuth();
            var registration = state.getRegistration();
            if (verify && auth != null && auth.getToken().size() != 0) return status(state);
            if (registration != null && registration.getError() != null)
                return Map.of("ok", false, "error", "registration_failed");
            if (!verify && registration != null && registration.getStatus().name().equals("CODE_SENT"))
                return Map.of("ok", true, "phase", "code_sent");
            Thread.sleep(100);
        }
        return Map.of("ok", false, "error", "registration_unconfirmed");
    }

    static Map<String,Object> status(State state) {
        Map<String,Object> result = new LinkedHashMap<>();
        result.put("ok", true);
        result.put("headless", GraphicsEnvironment.isHeadless());
        result.put("desktop_session", desktopSocket != null);
        result.put("authenticated", state.getAuth() != null && state.getAuth().getToken().size() != 0);
        result.put("user_id", state.getAuth() == null ? "" : state.getAuth().getUser_id());
        result.put("device_id", state.getAuth() == null ? "" : state.getAuth().getDevice_id());
        result.put("registration", state.getRegistration() == null ? "unknown" : state.getRegistration().getStatus().name());
        result.put("transfer_count", state.getTransfers().size());
        if (com.sun.jna.Platform.isWindows()) try {
            result.put("downloads_directory", com.sun.jna.platform.win32.Shell32Util.getKnownFolderPath(
                com.sun.jna.platform.win32.KnownFolders.FOLDERID_Downloads));
        } catch (Exception ignored) { }
        result.put("native_auto_accept_disabled", state.getConfig().getAuto_accept_disabled());
        result.put("receive_path_configured", profile.resolve("downloads").toString().equals(state.getConfig().getCustom_default_save_path()));
        result.put("app_id", state.getUser_agent() == null ? "" : state.getUser_agent().getApp_id());
        result.put("receive_policy_verified", Boolean.TRUE.equals(result.get("authenticated"))
            && state.getConfig().getAuto_accept_disabled() && Boolean.TRUE.equals(result.get("receive_path_configured")));
        return result;
    }

    static List<Object> devices(State state) {
        Map<String, User> users = new LinkedHashMap<>();
        if (state.getUsers() != null) {
            users.putAll(state.getUsers().getDiscovered());
        }
        Map<String,Object> devices = new LinkedHashMap<>();
        for (User user : users.values()) for (Device device : user.getDevices().values()) {
            String peer=user.getUser_id()+":"+device.getDevice_id();
            if (!exactPeer(peer)) continue;
            String contact = contactAddress(user), kind = device.getKind().name();
            String name = validDeviceName(device.getName()) ? Device_DerivedKt.getDisplayName(device) : "";
            var row = new LinkedHashMap<>(Map.of("peer",peer,"name",name.isEmpty()?readableKind(kind):name,
                "contact",contact,"user_name",userName(user),"kind",kind,"history",false,"name_known",!name.isEmpty()));
            if (device.getReach() != null) row.put("online", device.getReach().is_online());
            row.put("can_relay", kind.equals("Desktop") || kind.equals("Laptop"));
            devices.put(peer,row);
        }
        for (Transfer transfer:state.getTransfers().values()) {
            String peer=peerString(transfer.getPeer_id());if(transfer.getDirection()!=Transfer.Direction.Incoming||!exactPeer(peer))continue;
            if(devices.containsKey(peer))continue;
            User user=users.get(transfer.getPeer_id().getUser_id());
            String contact=user==null?"":contactAddress(user);
            devices.put(peer,Map.of("peer",peer,"name","Previous device","contact",contact,"user_name",user==null?"":userName(user),"kind","","history",true));
        }
        return new ArrayList<>(devices.values());
    }
    static boolean exactPeer(String peer) {try{parsePeer(peer);return peer.matches("[0-9a-fA-F-]{36}:[0-9a-fA-F-]{36}");}catch(Exception e){return false;}}
    static boolean validDeviceName(String name) {
        return !name.isBlank() && name.codePointCount(0, name.length()) <= 160 &&
            name.codePoints().noneMatch(Character::isISOControl);
    }
    static String readableKind(String kind){return Set.of("Desktop","Laptop","Phone","Tablet").contains(kind)?kind:"Device";}
    static String userName(User user){String value=wireText(user.encode(),2);return !value.isBlank()&&value.length()<=100&&value.chars().noneMatch(Character::isISOControl)?value:contactAddress(user);}
    static String wireText(byte[] data,int tag){try{int[] p={0};while(p[0]<data.length){long key=wireNumber(data,p);int type=(int)(key&7);if(type==0){wireNumber(data,p);continue;}if(type==1){p[0]+=8;continue;}if(type==5){p[0]+=4;continue;}if(type!=2)return "";long length=wireNumber(data,p);if(length<0||length>data.length-p[0])return "";int start=p[0];p[0]+=(int)length;if(key>>3==tag)return new String(data,start,(int)length,StandardCharsets.UTF_8);}}catch(Exception ignored){}return "";}
    // Contact address in the public frontend User message; never read account files.
    static String contactAddress(User user) {
        try {byte[] data=user.encode();int[] position={0};while(position[0]<data.length){long key=wireNumber(data,position);int wire=(int)(key&7);if(wire==0){wireNumber(data,position);continue;}if(wire==1){position[0]+=8;continue;}if(wire==5){position[0]+=4;continue;}if(wire!=2)return "";long length=wireNumber(data,position);if(length<0||length>data.length-position[0])return "";int start=position[0];position[0]+=(int)length;if(key>>3==1&&length<=254){String value=new String(data,start,(int)length,StandardCharsets.UTF_8);return value.matches("^[^\\s@\\p{Cntrl}]+@[^\\s@\\p{Cntrl}]+\\.[^\\s@\\p{Cntrl}]+$")?value:"";}}}catch(Exception ignored){}return "";
    }
    static long wireNumber(byte[] data,int[] position){long value=0;for(int shift=0;shift<64;shift+=7){int b=data[position[0]++]&255;if(shift==63&&b>1)throw new IllegalArgumentException();value|=(long)(b&127)<<shift;if((b&128)==0)return value;}throw new IllegalArgumentException();}

    static List<Object> transfers(State state) {
        List<Object> result = new ArrayList<>();
        for (Transfer transfer : state.getTransfers().values()) {
            var row=new LinkedHashMap<String,Object>(Map.of("transfer_id", transfer.getTransfer_id(), "peer", peerString(transfer.getPeer_id()),
                "direction", transfer.getDirection().name(), "status", transfer.getStatus().name(),
                "progress", transfer.getProgress(), "completed", transfer.getStatus() == Transfer.Status.Completed,
                "has_error", transfer.getLocal_err() != null || transfer.getRemote_err() != null,
                "link_files", receivedLinkFiles(transfer), "link_only", linkOnly(transfer)));
            row.put("dismissed",transfer.is_dismissed());
            row.put("received_items",receivedItems(transfer));
            var metadata=transfer.getArchive_stub();long total=0;
            if(metadata!=null)try{for(var item:metadata.getItems().values())if(item.getFile()!=null)total=Math.addExact(total,Math.max(0,item.getFile().getSize()));}catch(ArithmeticException ignored){total=0;}
            row.put("total_bytes",total);
            row.put("item_names",metadata==null?List.of():Metadata_DerivedKt.getRootVPaths(metadata).stream().limit(3).map(s->s.replaceAll("\\p{Cntrl}"," ")).map(s->s.substring(0,Math.min(s.length(),160))).toList());
            result.add(row);
        }
        return result;
    }

    static List<String> receivedLinkFiles(Transfer transfer) {
        if (transfer.getDirection() != Transfer.Direction.Incoming || transfer.getStatus() != Transfer.Status.Completed
                || transfer.getLocal_err() != null || transfer.getRemote_err() != null || transfer.is_dismissed()) return List.of();
        var metadata = transfer.getArchive_stub();
        if (metadata == null) return List.of();
        PathDecoder.Companion.setShared(new net.blip.desktop.PathDecoderDesktop(net.blip.desktop.SystemPathsDesktopKt.getSystemPathsDesktop()));
        List<String> files = new ArrayList<>();
        // Root files only: never traverse a received folder or treat archive symlinks as web links.
        for (String vpath : Metadata_DerivedKt.getRootVPaths(metadata)) {
            var item = metadata.getItems().get(vpath);
            String lower = vpath.toLowerCase(Locale.ROOT);
            if (item == null || item.getFile() == null || !(lower.endsWith(".url") || lower.endsWith(".webloc"))) continue;
            String location = Metadata_DerivedKt.diskLocation(metadata, vpath);
            if (location != null && files.size() < 256) files.add(location);
        }
        return files;
    }

    static List<Object> receivedItems(Transfer transfer) {
        if(transfer.getDirection()!=Transfer.Direction.Incoming||transfer.getStatus()!=Transfer.Status.Completed||transfer.getLocal_err()!=null||transfer.getRemote_err()!=null)return List.of();
        var metadata=transfer.getArchive_stub();if(metadata==null)return List.of();
        PathDecoder.Companion.setShared(new net.blip.desktop.PathDecoderDesktop(net.blip.desktop.SystemPathsDesktopKt.getSystemPathsDesktop()));
        List<Object> result=new ArrayList<>();
        for(String root:Metadata_DerivedKt.getRootVPaths(metadata).stream().sorted().toList()) {
            if(root.isBlank()||root.equals(".")||root.equals("..")||root.contains("/")||root.contains("\\")||root.chars().anyMatch(Character::isISOControl))continue;
            var item=metadata.getItems().get(root);if(item==null||item.getFile()==null&&item.getFolder()==null)continue;
            String location=Metadata_DerivedKt.diskLocation(metadata,root);if(location==null||location.isBlank())continue;
            result.add(Map.of("name",root,"path",location,"is_directory",item.getFolder()!=null,"size",item.getFile()==null?0:Math.max(0,item.getFile().getSize())));
            if(result.size()==256)break;
        }
        return result;
    }

    static boolean linkOnly(Transfer transfer) {
        if (transfer.getDirection() != Transfer.Direction.Incoming || transfer.is_dismissed()) return false;
        var metadata = transfer.getArchive_stub();
        if (metadata == null || metadata.getItems().isEmpty() || metadata.getItems().size() > 16) return false;
        var roots = Metadata_DerivedKt.getRootVPaths(metadata);
        if (roots.size() != metadata.getItems().size()) return false;
        for (String path : roots) {
            var item = metadata.getItems().get(path); String lower = path.toLowerCase(Locale.ROOT);
            if (item == null || item.getFile() == null || !(lower.endsWith(".url") || lower.endsWith(".webloc"))) return false;
            if (item.getFile().getSize() <= 0 || item.getFile().getSize() > 65536) return false;
        }
        return true;
    }

    static PeerId parsePeer(String text) {
        String[] parts = text.split(":", -1);
        if (parts.length != 2) throw new IllegalArgumentException("Invalid peer");
        UUID.fromString(parts[0]); UUID.fromString(parts[1]);
        return new PeerId(parts[0], parts[1], EMPTY);
    }
    static String peerString(PeerId peer) {
        return peer == null ? "" : peer.getUser_id() + ":" + peer.getDevice_id();
    }

    static void emit(Object value) { System.out.println(PREFIX + json(value)); System.out.flush(); }
    static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof Boolean || value instanceof Number) return value.toString();
        if (value instanceof Map<?,?> map) {
            List<String> entries = new ArrayList<>();
            for (var entry : map.entrySet()) entries.add(json(entry.getKey().toString()) + ":" + json(entry.getValue()));
            return "{" + String.join(",", entries) + "}";
        }
        if (value instanceof Collection<?> items) {
            List<String> entries = new ArrayList<>();
            for (Object item : items) entries.add(json(item));
            return "[" + String.join(",", entries) + "]";
        }
        String text = value.toString(); StringBuilder result = new StringBuilder("\"");
        for (int index = 0; index < text.length(); index++) {
            char c = text.charAt(index);
            if (c == '\\' || c == '"') result.append('\\').append(c);
            else if (c < 32) result.append(String.format("\\u%04x", (int)c));
            else result.append(c);
        }
        return result.append('"').toString();
    }
}
