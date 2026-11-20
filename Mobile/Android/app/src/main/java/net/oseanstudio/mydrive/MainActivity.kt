package net.oseanstudio.mydrive

import android.app.Application
import android.content.*
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.security.MessageDigest

class DriveModel(app: Application): AndroidViewModel(app) {
    val store=Store(app)
    private var readable=true
    var error by mutableStateOf<String?>(null)
    var devices by mutableStateOf<List<Device>>(emptyList())
    var active by mutableStateOf<Device?>(null)
    var path by mutableStateOf("")
    var entries by mutableStateOf<List<RemoteEntry>>(emptyList())
    var loading by mutableStateOf(false)
    var tab by mutableIntStateOf(0)
    var selected by mutableStateOf<List<Uri>>(emptyList())
    var sharedText by mutableStateOf<String?>(null)
    var received by mutableStateOf<List<androidx.documentfile.provider.DocumentFile>>(emptyList())
    init {try{devices=store.devices()}catch(e: Exception){readable=false;error="Saved devices could not be loaded. Their existing data has been kept."};Transfers.init(app);Transfers.historyError?.let{error=it}}
    fun save(device: Device,password: String){try{
        check(readable){"Restore the saved device list before adding another connection."};RemotePath.name(device.share);RemotePath.clean(device.root)
        val previous=devices.firstOrNull{it.id==device.id};val secret=if(previous!=null)store.password(device.id)else null
        require(previous==null||password.isNotEmpty()||(previous.host==device.host&&previous.port==device.port&&previous.username==device.username&&previous.domain==device.domain)){"Re-enter the password after changing the server or account."}
        if(password.isNotEmpty()||previous==null)store.password(device.id,password)
        val changed=devices.filterNot{it.id==device.id}+device
        try{store.save(changed);devices=changed}catch(e: Exception){if(secret==null)store.removePassword(device.id)else store.password(device.id,secret);throw e}
    }catch(e: Exception){error=e.message?:"Could not save this device."}}
    fun remove(device: Device){try{check(readable);val changed=devices.filterNot{it.id==device.id};store.save(changed);store.removePassword(device.id);devices=changed;if(active?.id==device.id){active=null;entries=emptyList()}}catch(e: Exception){error="Could not remove this saved connection."}}
    fun browse(device: Device,newPath: String=""){if(loading)return;active=device;path=newPath;tab=1;refresh()}
    fun refresh(){val d=active?:return;if(loading)return;loading=true;viewModelScope.launch{try{entries=SmbClient(getApplication()).list(d,path)}catch(e: Exception){error=TransferService.friendly(e);entries=emptyList()}finally{loading=false}}}
    fun operation(action: suspend (SmbClient,Device)->Unit){val d=active?:return;if(loading)return;loading=true;viewModelScope.launch{try{action(SmbClient(getApplication()),d);entries=SmbClient(getApplication()).list(d,path)}catch(e: Exception){error=TransferService.friendly(e)}finally{loading=false}}}
    fun upload(){val d=active?:return;val ctx=getApplication<Application>();try{selected.forEach{uri->TransferService.start(ctx,d,path,displayName(ctx,uri),uri)};selected=emptyList();tab=2}catch(e: Exception){error=e.message}}
    fun loadReceived(){val uri=store.receivedTree?:return;viewModelScope.launch{try{received=withContext(Dispatchers.IO){androidx.documentfile.provider.DocumentFile.fromTreeUri(getApplication(),Uri.parse(uri))?.listFiles()?.filter{it.isFile}.orEmpty()}}catch(e: Exception){error="The selected received folder is unavailable. Choose it again."}}}
    fun importReceived(document: androidx.documentfile.provider.DocumentFile){viewModelScope.launch{try{val ctx=getApplication<Application>();val target=withContext(Dispatchers.IO){val dir=File(ctx.filesDir,"received/${java.util.UUID.randomUUID()}").apply{mkdirs()};val final=File(dir,RemotePath.name(document.name?:"File"));val partial=File(dir,".partial");try{ctx.contentResolver.openInputStream(document.uri).use{input->requireNotNull(input);partial.outputStream().use{output->input.copyTo(output,128*1024)}};java.nio.file.Files.move(partial.toPath(),final.toPath());final}finally{if(partial.exists())partial.delete()}};Transfers.update(ctx,Transfer(name=target.name,device="Blip received folder",direction="Incoming",state="Imported",localPath=target.absolutePath));tab=2}catch(e: Exception){error="The received file could not be imported. Wait until Blip finishes receiving it, then try again."}}}
    fun importDevices(uri: Uri){viewModelScope.launch{try{check(readable);val text=withContext(Dispatchers.IO){getApplication<Application>().contentResolver.openInputStream(uri)!!.bufferedReader().use{reader->val text=StringBuilder();val chars=CharArray(4096);while(true){val count=reader.read(chars);if(count<0)break;require(text.length+count<=262144){"Connection file is too large."};text.append(chars,0,count)};text.toString()}};val a=JSONObject(text).getJSONArray("devices");require(a.length()<=100);val added=(0 until a.length()).map{Device.imported(a.getJSONObject(it))};added.forEach{require(it.host.isNotBlank()&&it.port in 1..65535);RemotePath.server(it.host);RemotePath.name(it.share);RemotePath.clean(it.root)};val merged=(devices+added).distinctBy{it.host.lowercase()+":"+it.port+"/"+it.share+"/"+it.root};store.save(merged);devices=merged}catch(e: Exception){error="Connection file could not be imported. Existing devices were kept."}}}
}
fun displayName(context: Context,uri: Uri): String = context.contentResolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use{if(it.moveToFirst())it.getString(0)else null}?:"File"
fun bytes(value: Long): String=android.text.format.Formatter.formatShortFileSize(AppContext.context,value)
private object AppContext {lateinit var context: Context}

class MainActivity: ComponentActivity() {
    override fun onNewIntent(intent: Intent){super.onNewIntent(intent);setIntent(intent);receive(intent,androidx.lifecycle.ViewModelProvider(this)[DriveModel::class.java])}
    override fun onCreate(savedInstanceState: Bundle?){super.onCreate(savedInstanceState);AppContext.context=applicationContext
        setContent {MaterialTheme(colorScheme=if(androidx.compose.foundation.isSystemInDarkTheme())darkColorScheme(primary=Color(0xFFB8C4FF))else lightColorScheme(primary=Color(0xFF314DCB))){val model: DriveModel=viewModel();LaunchedEffect(Unit){receive(intent,model)};DriveScreen(model)}}
    }
    @Suppress("DEPRECATION") private fun receive(intent: Intent,model: DriveModel){
        if(intent.action==Intent.ACTION_SEND_MULTIPLE)model.selected=intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty().filter{it.scheme=="content"}
        else if(intent.action==Intent.ACTION_SEND)intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.takeIf{it.scheme=="content"}?.let{model.selected=listOf(it)}
        model.sharedText=intent.getStringExtra(Intent.EXTRA_TEXT)
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable fun DriveScreen(model: DriveModel) {
    val context=androidx.compose.ui.platform.LocalContext.current
    var add by remember{mutableStateOf(false)};var editing by remember{mutableStateOf<Device?>(null)}
    var options by remember{mutableStateOf(false)};var settings by remember{mutableStateOf(false)};var link by remember{mutableStateOf(false)}
    var command by remember{mutableStateOf<Pair<String,RemoteEntry?>?>(null)}
    val transfers by Transfers.items.collectAsState()
    val files=rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()){if(it.isNotEmpty())model.selected=it}
    val imports=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()){it?.let(model::importDevices)}
    val blipFolder=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()){uri->if(uri!=null){try{context.contentResolver.takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION);model.store.receivedTree=uri.toString();model.loadReceived();model.tab=1}catch(e: Exception){model.error="That folder could not be kept. Select it again."}}}
    val prefs=context.getSharedPreferences("link_claims",Context.MODE_PRIVATE)
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateFlow.collectAsState()
    var baseline by remember{mutableStateOf(false)}
    LaunchedEffect(transfers,lifecycleState){
        val completed=transfers.filter{it.state=="Completed"&&it.direction=="Incoming"&&it.localPath!=null}
        if(!baseline){completed.forEach{prefs.edit().putBoolean(it.id,true).apply()};baseline=true;return@LaunchedEffect}
        if(lifecycleState.isAtLeast(Lifecycle.State.RESUMED))completed.forEach{t->if(!prefs.getBoolean(t.id,false)){
            val url=withContext(Dispatchers.IO){BlipSharing.webLink(File(t.localPath!!))};prefs.edit().putBoolean(t.id,true).commit()
            if(url!=null&&model.store.autoOpenLinks)runCatching{context.startActivity(Intent(Intent.ACTION_VIEW,url))}.onFailure{model.error="The received link could not open. Open the downloaded file from Transfers."}
        }}
    }
    fun sendBlip(){try{BlipSharing.send(context,model.selected,model.sharedText);Transfers.update(context,Transfer(name=if(model.selected.size==1)displayName(context,model.selected[0])else if(model.selected.isNotEmpty())"${model.selected.size} files" else "Shared link",device="Blip account",direction="Outgoing",state="Handed to Blip"));model.selected=emptyList();model.sharedText=null;model.tab=2}catch(e: Exception){model.error=e.message}}
    if(add) {
        DeviceEditor(editing,model.error,onDismiss={add=false;model.error=null},onSave={d,p->model.error=null;model.save(d,p);if(model.error==null)add=false},onRemove={d->model.remove(d);add=false})
        return
    }
    Scaffold(topBar={CenterAlignedTopAppBar(title={Text("myDrive",fontWeight=FontWeight.Bold)},navigationIcon={if(model.tab==1&&model.active!=null)IconButton(onClick={if(model.path.isEmpty()){model.active=null;model.tab=0}else{model.path=model.path.substringBeforeLast('/',"");model.refresh()}}){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")}},actions={Box{IconButton(onClick={options=true}){Icon(Icons.Default.MoreVert,"More options")};DropdownMenu(expanded=options,onDismissRequest={options=false}){
        DropdownMenuItem(text={Text("Add SMB device")},onClick={options=false;editing=null;add=true})
        DropdownMenuItem(text={Text("Choose files")},onClick={options=false;files.launch(arrayOf("*/*"))})
        DropdownMenuItem(text={Text("Import connections")},onClick={options=false;imports.launch(arrayOf("application/json"))})
        DropdownMenuItem(text={Text("Send a link with Blip")},onClick={options=false;link=true})
        DropdownMenuItem(text={Text("Choose Blip received folder")},onClick={options=false;blipFolder.launch(null)})
        DropdownMenuItem(text={Text("Settings")},onClick={options=false;settings=true})
    }}})},bottomBar={NavigationBar{listOf("Devices" to Icons.Default.Devices,"Browse" to Icons.Default.Folder,"Transfers" to Icons.Default.SwapVert).forEachIndexed{i,pair->NavigationBarItem(selected=model.tab==i,onClick={model.tab=i},icon={Icon(pair.second,pair.first)},label={Text(pair.first)})}}},floatingActionButton={if(model.tab!=2)ExtendedFloatingActionButton(onClick={files.launch(arrayOf("*/*"))},icon={Icon(Icons.AutoMirrored.Filled.Send,null)},text={Text("Send files")})}){padding->
        Column(Modifier.padding(padding).fillMaxSize()){
            if(model.selected.isNotEmpty()||model.sharedText!=null)Surface(color=MaterialTheme.colorScheme.primaryContainer){Column(Modifier.fillMaxWidth().padding(16.dp)){Text(if(model.selected.isNotEmpty())"${model.selected.size} files ready to send" else "Link ready to send",fontWeight=FontWeight.SemiBold);FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)){Button(onClick={sendBlip()}){Text("Send with Blip")};if(model.active!=null&&model.selected.isNotEmpty())OutlinedButton(onClick={model.upload()}){Text("Upload here")};TextButton(onClick={model.selected=emptyList();model.sharedText=null}){Text("Clear")}}}
            }
            when(model.tab) {
                0 -> DevicesPanel(model,onAdd={editing=null;add=true},onEdit={editing=it;add=true},onPick={files.launch(arrayOf("*/*"))})
                1 -> BrowserPanel(model,onCommand={command=it})
                2 -> TransfersPanel(model,transfers)
            }
        }
    }

    if(settings){var enabled by remember{mutableStateOf(model.store.autoOpenLinks)};AlertDialog(onDismissRequest={settings=false},title={Text("Settings")},text={Column{Row(verticalAlignment=Alignment.CenterVertically){Text("Open received web links",Modifier.weight(1f));Switch(checked=enabled,onCheckedChange={enabled=it;model.store.autoOpenLinks=it})};Text("Applies to completed myDrive downloads. Blip manages its own receiving preferences.",style=MaterialTheme.typography.bodySmall);Text("myDrive 0.4.0 mobile preview\nSMB via SMBJ 0.15.0 (Apache 2.0)",Modifier.padding(top=16.dp),style=MaterialTheme.typography.bodySmall)}},confirmButton={TextButton(onClick={settings=false}){Text("Done")}})}
    if(link){var text by remember{mutableStateOf(model.sharedText.orEmpty())};AlertDialog(onDismissRequest={link=false},title={Text("Send a link with Blip")},text={OutlinedTextField(value=text,onValueChange={text=it},label={Text("Link or text")})},confirmButton={TextButton(onClick={model.sharedText=text;link=false;sendBlip()},enabled=text.isNotBlank()){Text("Choose Blip")}},dismissButton={TextButton(onClick={link=false}){Text("Cancel")}})}
    command?.let{(action,entry)->var name by remember(action,entry){mutableStateOf(entry?.name.orEmpty())};AlertDialog(onDismissRequest={command=null},title={Text(action)},text={if(action=="Delete")Text("Delete ${entry!!.name} from ${model.active!!.name}? Folders must be empty.")else OutlinedTextField(value=name,onValueChange={name=it},label={Text("Name")},singleLine=true)},confirmButton={TextButton(onClick={try{if(action!="Delete")RemotePath.name(name);model.operation{client,d->when(action){"New folder"->client.mkdir(d,RemotePath.child(model.path,name));"Rename"->client.rename(d,entry!!.path,RemotePath.child(model.path,name));"Delete"->client.delete(d,entry!!)}};command=null}catch(e: Exception){model.error=e.message}}){Text(if(action=="Delete")"Delete" else "Save")}},dismissButton={TextButton(onClick={command=null}){Text("Cancel")}})}
    model.error?.let{message->AlertDialog(onDismissRequest={model.error=null},title={Text("myDrive")},text={Text(message)},confirmButton={TextButton(onClick={model.error=null}){Text("OK")}})}
}
