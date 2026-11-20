package net.oseanstudio.mydrive

import android.app.*
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.os.IBinder
import android.provider.OpenableColumns
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap

class TransferService: Service() {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val jobs=ConcurrentHashMap<String,Job>()
    override fun onBind(intent: Intent?): IBinder?=null
    override fun onCreate(){super.onCreate();Transfers.init(this);getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("transfers","File transfers",NotificationManager.IMPORTANCE_LOW))}
    private fun notification(text: String)=NotificationCompat.Builder(this,"transfers").setSmallIcon(R.drawable.ic_cloud).setContentTitle("myDrive").setContentText(text).setOngoing(jobs.isNotEmpty()).setContentIntent(PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)).build()
    override fun onStartCommand(intent: Intent?,flags: Int,startId: Int): Int {
        if(intent?.action=="cancel"){jobs[intent.getStringExtra("id")]?.cancel();if(jobs.isEmpty())stopSelf();return START_NOT_STICKY}
        if(intent==null){stopSelf();return START_NOT_STICKY}
        startForeground(10,notification("Preparing transfer…"))
        val device=Store(this).devices().firstOrNull{it.id==intent.getStringExtra("device")}
        if(device==null){stopSelf();return START_NOT_STICKY}
        val name=intent.getStringExtra("name")?:"File";val path=intent.getStringExtra("path").orEmpty();val uri=intent.getStringExtra("uri")
        var record=Transfer(name=name,device=device.name,direction=if(uri==null)"Incoming" else "Outgoing")
        Transfers.update(this,record)
        val job=scope.launch(start=CoroutineStart.LAZY){
            var last=0L
            fun update(bytes: Long,total: Long){val now=System.currentTimeMillis();if(now-last<300&&bytes!=total)return;last=now;record=record.copy(state="Transferring",bytes=bytes,total=total);Transfers.update(this@TransferService,record);getSystemService(NotificationManager::class.java).notify(10,notification(name))}
            try {
                record=record.copy(state="Connecting");Transfers.update(this@TransferService,record)
                val client=SmbClient(this@TransferService)
                val local=if(uri==null)client.download(device,RemoteEntry(name,path,false,intent.getLongExtra("size",0)),::update)else{client.upload(device,path,name,Uri.parse(uri),::update);null}
                record=record.copy(state="Completed",localPath=local?.absolutePath)
                Transfers.update(this@TransferService,record)
                // OS browser launches happen only on an active screen; the UI consumes this completed record.
            } catch(e: CancellationException){record=record.copy(state="Cancelled",error="Transfer cancelled. Previous files were kept.");Transfers.update(this@TransferService,record)}
            catch(e: Exception){record=record.copy(state="Needs attention",error=friendly(e));Transfers.update(this@TransferService,record)}
            finally {jobs.remove(record.id);if(jobs.isEmpty()){stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()}else getSystemService(NotificationManager::class.java).notify(10,notification("${jobs.size} transfers running"))}
        }
        jobs[record.id]=job;job.start();return START_NOT_STICKY
    }
    override fun onTimeout(startId: Int,fgsType: Int){scope.cancel();stopSelf()}
    override fun onDestroy(){scope.cancel();super.onDestroy()}
    companion object {
        fun start(context: Context,device: Device,path: String,name: String,uri: Uri?=null,size: Long=0){context.startForegroundService(Intent(context,TransferService::class.java).putExtra("device",device.id).putExtra("path",path).putExtra("name",name).putExtra("uri",uri?.toString()).putExtra("size",size))}
        fun cancel(context: Context,id: String){context.startService(Intent(context,TransferService::class.java).setAction("cancel").putExtra("id",id))}
        fun friendly(e: Exception): String = when {
            e is java.net.UnknownHostException -> "Server not found. Check its Tailscale name and that Tailscale is connected."
            e is java.net.SocketTimeoutException -> "The server did not respond. Check Tailscale and file sharing on the computer."
            e.javaClass.simpleName.contains("SMBApi") -> "The server rejected this operation. Check the username, password, share permissions, or whether that name already exists."
            e is IllegalArgumentException || e is IllegalStateException -> e.message?:"Check the selected path."
            else -> "The transfer could not be confirmed. Check the server and destination before retrying."
        }
    }
}
