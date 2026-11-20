package net.oseanstudio.mydrive

import android.content.Context
import android.net.Uri
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.file.Files
import java.util.EnumSet
import java.util.UUID
import java.util.concurrent.TimeUnit

class SmbClient(private val context: Context, private val passwordFor: (String)->String = { Store(context).password(it) }) {
    private suspend fun <T> session(device: Device,operation: suspend (DiskShare)->T): T = withContext(Dispatchers.IO) {
        val config=SmbConfig.builder().withTimeout(30,TimeUnit.SECONDS).withSoTimeout(30000).withSigningRequired(true).withEncryptData(device.encrypted).build()
        SMBClient(config).use { client -> client.connect(device.host,device.port).use { connection ->
            val secret=passwordFor(device.id).toCharArray()
            val auth=try{connection.authenticate(AuthenticationContext(device.username,secret,device.domain))}finally{secret.fill('\u0000')}
            auth.use { authenticated -> (authenticated.connectShare(device.share) as DiskShare).use{operation(it)} }
        } }
    }
    private fun wire(device: Device,path: String)=RemotePath.clean(listOf(device.root,path).filter{it.isNotEmpty()}.joinToString("/")).replace('/','\\')
    suspend fun list(device: Device,path: String): List<RemoteEntry> = session(device){share ->
        share.list(wire(device,path)).filter{it.fileName!="."&&it.fileName!=".."}.map {
            RemoteEntry(it.fileName,RemotePath.child(path,it.fileName),it.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L,it.endOfFile,it.fileAttributes and FileAttributes.FILE_ATTRIBUTE_REPARSE_POINT.value != 0L)
        }.sortedWith(compareBy<RemoteEntry>{!it.directory}.thenBy{it.name.lowercase()})
    }
    suspend fun mkdir(device: Device,path: String)=session(device){it.mkdir(wire(device,path))}
    suspend fun rename(device: Device,path: String,destination: String)=session(device){share ->
        share.open(wire(device,path),EnumSet.of(AccessMask.DELETE),EnumSet.noneOf(FileAttributes::class.java),SMB2ShareAccess.ALL,SMB2CreateDisposition.FILE_OPEN,EnumSet.noneOf(SMB2CreateOptions::class.java)).use{it.rename(wire(device,destination),false)}
    }
    suspend fun delete(device: Device,entry: RemoteEntry)=session(device){share ->
        require(!entry.linked){"Linked items cannot be changed in this preview."}
        if(entry.directory)share.rmdir(wire(device,entry.path),false)else share.rm(wire(device,entry.path))
    }
    suspend fun download(device: Device,entry: RemoteEntry,progress: (Long,Long)->Unit): File = session(device){share ->
        require(!entry.directory&&!entry.linked){"Choose a regular file."}
        val dir=File(context.filesDir,"received").apply{mkdirs()}
        // A unique transfer directory keeps repeated filenames and previous downloads intact.
        val transferDir=File(dir,UUID.randomUUID().toString()).apply{mkdirs()}
        val target=File(transferDir,RemotePath.name(entry.name));val temporary=File(transferDir,".partial")
        try {
            share.openFile(wire(device,entry.path),EnumSet.of(AccessMask.GENERIC_READ),EnumSet.noneOf(FileAttributes::class.java),SMB2ShareAccess.ALL,SMB2CreateDisposition.FILE_OPEN,EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE)).use{remote ->
                val total=remote.length;var done=0L;val buffer=ByteArray(128*1024)
                temporary.outputStream().use{output -> while(true){currentCoroutineContext().ensureActive();val count=remote.read(buffer,done);if(count<0)break;if(count==0){check(done==total){"Server ended the download early."};break};output.write(buffer,0,count);done+=count;progress(done,total)};output.flush()}
                check(done==total){"The server returned an incomplete file."}
            }
            Files.move(temporary.toPath(),target.toPath());target
        } finally {if(temporary.exists())temporary.delete()}
    }
    suspend fun upload(device: Device,path: String,name: String,source: Uri,progress:(Long,Long)->Unit)=session(device){share ->
        val final=wire(device,RemotePath.child(path,name));val temporary=wire(device,RemotePath.child(path,".mydrive-${UUID.randomUUID()}.partial"))
        var committed=false
        try {
            share.openFile(temporary,EnumSet.of(AccessMask.GENERIC_WRITE,AccessMask.DELETE),EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),SMB2ShareAccess.ALL,SMB2CreateDisposition.FILE_CREATE,EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE)).use{remote ->
                context.contentResolver.openInputStream(source).use{input ->
                    requireNotNull(input){"The selected file is no longer available."};val buffer=ByteArray(128*1024);var done=0L
                    while(true){currentCoroutineContext().ensureActive();val count=input.read(buffer);if(count<0)break;var written=0
                        while(written<count){currentCoroutineContext().ensureActive();val n=remote.write(buffer,done,written,count-written).toInt();check(n>0){"Server stopped accepting data."};written+=n;done+=n}
                        progress(done,0)
                    }
                }
                remote.flush();remote.rename(final,false);committed=true
            }
        } finally {if(!committed)runCatching{share.rm(temporary)}}
    }
}
