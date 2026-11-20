package net.oseanstudio.mydrive

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.io.File

@Composable fun DevicesPanel(model: DriveModel,onAdd:()->Unit,onEdit:(Device)->Unit,onPick:()->Unit) {
    LazyColumn(contentPadding=PaddingValues(20.dp,12.dp,20.dp,100.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        item {
            Text("Your devices",style=MaterialTheme.typography.headlineMedium,fontWeight=FontWeight.Bold)
            Text("Browse shared folders. Send files wherever you are.",color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        item {
            Card(onClick=onPick,colors=CardDefaults.cardColors(containerColor=MaterialTheme.colorScheme.primaryContainer)) {
                Row(Modifier.fillMaxWidth().padding(20.dp),verticalAlignment=Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.Send,null,Modifier.size(36.dp))
                    Column(Modifier.padding(start=16.dp)) { Text("Send with Blip",fontWeight=FontWeight.Bold); Text("Use the account in your Blip app",style=MaterialTheme.typography.bodySmall) }
                }
            }
        }
        items(model.devices,key={it.id}) { device ->
            Card {
                Column(Modifier.fillMaxWidth().padding(16.dp)) {
                    Row(verticalAlignment=Alignment.CenterVertically) {
                        Icon(Icons.Default.Computer,null,Modifier.size(38.dp))
                        Column(Modifier.weight(1f).padding(horizontal=12.dp)) {
                            Text(device.name,fontWeight=FontWeight.Bold)
                            Text("${device.host} / ${device.share}",maxLines=1,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.bodySmall)
                        }
                        IconButton(onClick={onEdit(device)}) { Icon(Icons.Default.Edit,"Edit ${device.name}") }
                    }
                    Row {
                        Button(onClick={model.browse(device)}) { Text("Browse") }
                        if(model.selected.isNotEmpty())TextButton(onClick={model.browse(device)}) { Text("Choose upload folder") }
                    }
                }
            }
        }
        item { OutlinedButton(onClick=onAdd,modifier=Modifier.fillMaxWidth()) { Icon(Icons.Default.Add,null); Text("Add SMB device") } }
        item { Text("Use the computer's Tailscale name or address. Keep Tailscale connected on both devices.",style=MaterialTheme.typography.bodySmall) }
    }
}

@Composable fun BrowserPanel(model: DriveModel,onCommand:(Pair<String,RemoteEntry?>)->Unit) {
    val context=LocalContext.current
    val device=model.active
    if(device==null) {
        Column(Modifier.padding(24.dp)) {
            Text("Choose a device",style=MaterialTheme.typography.headlineSmall)
            Text("Saved SMB shares appear here after you add a computer.")
            Button(onClick={model.tab=0}) { Text("Your devices") }
            model.store.receivedTree?.let { TextButton(onClick={model.loadReceived()}) { Text("Refresh Blip received folder") } }
            model.received.forEach{document->TextButton(onClick={model.importReceived(document)}){Text("Import ${document.name?:"File"}",maxLines=1,overflow=TextOverflow.Ellipsis)}}
        }
        return
    }
    fun download(entry: RemoteEntry) { TransferService.start(context,device,entry.path,entry.name,size=entry.size); model.tab=2 }
    Column {
        Row(Modifier.fillMaxWidth().padding(horizontal=20.dp),verticalAlignment=Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(device.name,fontWeight=FontWeight.Bold)
                Text(if(model.path.isEmpty())device.share else model.path,maxLines=1,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.bodySmall)
            }
            IconButton(onClick={model.refresh()},enabled=!model.loading) { Icon(Icons.Default.Refresh,"Refresh folder") }
            IconButton(onClick={onCommand("New folder" to null)},enabled=!model.loading) { Icon(Icons.Default.CreateNewFolder,"New folder") }
        }
        if(model.loading)LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(contentPadding=PaddingValues(bottom=100.dp)) {
            if(!model.loading&&model.entries.isEmpty())item { Text("This folder is empty.",Modifier.padding(24.dp)) }
            items(model.entries,key={it.path}) { entry ->
                var menu by remember { mutableStateOf(false) }
                ListItem(
                    headlineContent={Text(entry.name,maxLines=1,overflow=TextOverflow.Ellipsis)},
                    supportingContent={Text(if(entry.linked)"Linked item · not followed" else if(entry.directory)"Folder" else bytes(entry.size))},
                    leadingContent={Icon(if(entry.directory)Icons.Default.Folder else Icons.Default.Description,null)},
                    trailingContent={
                        Box {
                            IconButton(onClick={menu=true}) { Icon(Icons.Default.MoreVert,"Actions for ${entry.name}") }
                            DropdownMenu(expanded=menu,onDismissRequest={menu=false}) {
                                if(!entry.directory)DropdownMenuItem(text={Text("Download")},onClick={menu=false;download(entry)},enabled=!entry.linked)
                                DropdownMenuItem(text={Text("Rename")},onClick={menu=false;onCommand("Rename" to entry)},enabled=!entry.linked)
                                DropdownMenuItem(text={Text("Delete")},onClick={menu=false;onCommand("Delete" to entry)},enabled=!entry.linked)
                            }
                        }
                    },
                    modifier=Modifier.clickable(enabled=!entry.linked&&!model.loading) { if(entry.directory){model.path=entry.path;model.refresh()}else download(entry) }
                )
            }
        }
    }
}

@Composable fun TransfersPanel(model: DriveModel,transfers: List<Transfer>) {
    val context=LocalContext.current
    LazyColumn(contentPadding=PaddingValues(20.dp,12.dp,20.dp,100.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        item { Text("Transfers",style=MaterialTheme.typography.headlineMedium,fontWeight=FontWeight.Bold); Text("SMB progress and Blip handoffs") }
        if(transfers.isEmpty())item { Text("Your transfers will appear here.",Modifier.padding(vertical=24.dp)) }
        items(transfers,key={it.id}) { transfer ->
            Card {
                Column(Modifier.fillMaxWidth().padding(16.dp)) {
                    Text(transfer.name,fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis)
                    Text("${transfer.device} · ${transfer.state}",style=MaterialTheme.typography.bodySmall)
                    if(transfer.active) {
                        if(transfer.total>0)LinearProgressIndicator(progress={transfer.bytes.toFloat()/transfer.total},modifier=Modifier.fillMaxWidth().padding(top=8.dp))
                        else LinearProgressIndicator(Modifier.fillMaxWidth().padding(top=8.dp))
                        Text(bytes(transfer.bytes),style=MaterialTheme.typography.bodySmall)
                        TextButton(onClick={TransferService.cancel(context,transfer.id)}) { Text("Cancel") }
                    }
                    transfer.error?.let { Text(it,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall) }
                    transfer.localPath?.let { path ->
                        Row {
                            TextButton(onClick={val uri=BlipSharing.fileUri(context,File(path));runCatching{context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri,context.contentResolver.getType(uri)?:"application/octet-stream").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))}.onFailure{model.error="No app is available to open this file. Use Share to export it."}}) { Text("Open") }
                            TextButton(onClick={val uri=BlipSharing.fileUri(context,File(path));context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("*/*").putExtra(Intent.EXTRA_STREAM,uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),"Save or share"))}) { Text("Share") }
                        }
                    }
                    if(transfer.state=="Handed to Blip")Text("Check Blip for acceptance and delivery.",style=MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
