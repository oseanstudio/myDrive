import java.io.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import net.blip.libblip.*;

/** Isolated unsigned-in native host election; never uses desktop profile paths. */
public class HostElectionCheck {
    static void checkState(Path root) throws Exception {
        var ready=CompletableFuture.supplyAsync(()->{
            var client=new Client(root.resolve("cache/sock").toString(),"MyDriveElectionCheck",false);
            var state=client.getState(ByteBuffer.allocateDirect(8*1024*1024));
            return state.getAuth()==null||state.getAuth().getToken().size()==0;
        });
        if(!ready.get(15,TimeUnit.SECONDS))throw new IllegalStateException("Fixture unexpectedly authenticated");
    }
    static Process launch(Path root) throws Exception {
        var arguments=new ArrayList<String>();
        arguments.add(Path.of(System.getProperty("java.home"),"bin",System.getProperty("os.name").startsWith("Windows")?"java.exe":"java").toString());
        arguments.addAll(List.of("-Djava.awt.headless=true","--enable-native-access=ALL-UNNAMED","-Djava.library.path="+System.getProperty("java.library.path"),"-cp",System.getProperty("java.class.path"),HostElectionCheck.class.getName(),"host",root.toString()));
        var process=new ProcessBuilder(arguments).redirectError(ProcessBuilder.Redirect.DISCARD).start();
        try {
            boolean ready=CompletableFuture.supplyAsync(()->{try{var reader=process.inputReader();for(int i=0;i<100;i++){String line=reader.readLine();if(line==null)return false;if(line.equals("ELECTION_READY"))return true;}return false;}catch(IOException error){return false;}}).get(20,TimeUnit.SECONDS);
            if(!ready)throw new IllegalStateException("Fixture host did not become ready");return process;
        }catch(Exception error){process.destroyForcibly();throw error;}
    }
    static void stop(Process process)throws Exception {
        if(process==null||!process.isAlive())return;
        process.outputWriter().write("STOP\n");process.outputWriter().flush();process.getOutputStream().close();
        if(!process.waitFor(15,TimeUnit.SECONDS)){process.destroyForcibly();throw new IllegalStateException("Fixture shutdown did not finish");}
        if(process.exitValue()!=0)throw new IllegalStateException("Fixture shutdown failed");
    }
    public static void main(String[] args)throws Exception {
        Path root=Path.of(args[1]).toAbsolutePath().normalize();
        if(args[0].equals("host")) {
            LibBlip.Companion.configureLogging(root.resolve("cache").toString(),"MyDriveElectionCheck",LogLevel.ERROR.getRaw());
            LibBlip.Companion.startHosting(true,root.resolve("cache").toString(),root.resolve("state").toString(),"https://127.0.0.1:9");
            checkState(root);System.out.println("ELECTION_READY");System.out.flush();
            new BufferedReader(new InputStreamReader(System.in)).readLine();LibBlip.Companion.stopHosting();System.exit(0);
        }
        Files.createDirectories(root.resolve("cache"));Files.createDirectories(root.resolve("state"));
        Process first=null,second=null,third=null;
        try {
            first=launch(root);second=launch(root);checkState(root);
            System.out.println("two_participants_one_readable_native_endpoint=true");
            stop(first);first=null;checkState(root);System.out.println("receiving_endpoint_survives_first_participant_quitting=true");
            third=launch(root);stop(second);second=null;checkState(root);System.out.println("receiving_endpoint_survives_original_owner_quitting=true");
            stop(third);third=null;System.out.println("clean_shutdown=true; authenticated=false");
        } finally {
            for(Process process:new Process[]{first,second,third})if(process!=null){try{stop(process);}catch(Exception error){process.destroyForcibly();}}
        }
    }
}
