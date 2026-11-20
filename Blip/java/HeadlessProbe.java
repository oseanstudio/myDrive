import java.awt.GraphicsEnvironment;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import net.blip.libblip.LibBlip;
import net.blip.libblip.Client;
import net.blip.libblip.event.TransferSetAutoAccept;
import net.blip.libblip.event.TransferSetCustomDefaultSavePath;
import okio.ByteString;

/** Bounded, unauthenticated startup probe using Blip's installed engine. */
public class HeadlessProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Expected a fresh profile path");
        Path profile = Path.of(args[0]).toAbsolutePath();
        // Refuse reuse: this probe must never open an existing account's state.
        Files.createDirectory(profile);
        Path cache = Files.createDirectory(profile.resolve("cache"));
        Path state = Files.createDirectory(profile.resolve("state"));
        Files.createDirectory(profile.resolve("downloads"));
        System.out.println("MYDRIVE_PROBE headless=" + GraphicsEnvironment.isHeadless());
        if (!GraphicsEnvironment.isHeadless()) throw new IllegalStateException("Java headless mode required");
        boolean started = false;
        try {
            LibBlip.Companion.startHosting(true, cache.toString(), state.toString(), "https://prod.blip.net");
            started = true;
            System.out.println("MYDRIVE_PROBE engine_started=true");
            Client client = new Client(cache.resolve("sock").toString(), "MyDriveProof/0.1", false);
            System.out.println("MYDRIVE_PROBE client_exists=" + client.exists());
            var snapshot = client.getState(ByteBuffer.allocateDirect(16 * 1024 * 1024));
            System.out.println("MYDRIVE_PROBE state_decoded=" + (snapshot != null));
            client.dispatch(new TransferSetAutoAccept(false, ByteString.EMPTY));
            client.dispatch(new TransferSetCustomDefaultSavePath(profile.resolve("downloads").toString(), ByteString.EMPTY));
            Thread.sleep(200);
            var configured = new Client(cache.resolve("sock").toString(), "MyDriveProof/0.1", false)
                .getState(ByteBuffer.allocateDirect(16 * 1024 * 1024));
            System.out.println("MYDRIVE_PROBE acceptance_disabled=" + configured.getConfig().getAuto_accept_disabled());
            System.out.println("MYDRIVE_PROBE receive_path_configured=" + profile.resolve("downloads").toString().equals(configured.getConfig().getCustom_default_save_path()));
            // Never print snapshot: it can contain credentials and personal data.
        } finally {
            if (started) LibBlip.Companion.stopHosting();
        }
        System.out.println("MYDRIVE_PROBE clean_shutdown=true");
        System.exit(0);
    }
}
