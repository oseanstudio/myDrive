package net.oseanstudio.mydrive

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun DeviceEditor(existing: Device?,problem: String?,onDismiss:()->Unit,onSave:(Device,String)->Unit,onRemove:(Device)->Unit) {
    var name by remember { mutableStateOf(existing?.name.orEmpty()) }
    var host by remember { mutableStateOf(existing?.let { val address=if(it.host.contains(':'))"[${it.host}]" else it.host;if(it.port==445)address else "$address:${it.port}" }.orEmpty()) }
    var share by remember { mutableStateOf(existing?.share.orEmpty()) }
    var root by remember { mutableStateOf(existing?.root.orEmpty()) }
    var user by remember { mutableStateOf(existing?.username.orEmpty()) }
    var domain by remember { mutableStateOf(existing?.domain.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var encrypted by remember { mutableStateOf(existing?.encrypted?:false) }
    var error by remember { mutableStateOf<String?>(null) }
    var removing by remember { mutableStateOf(false) }
    Scaffold(topBar={TopAppBar(title={Text(if(existing==null)"Add SMB device" else "Edit device")},navigationIcon={TextButton(onClick=onDismiss){Text("Cancel")}},actions={TextButton(onClick={
        try {
            val(server,port)=RemotePath.server(host.trim());require(name.isNotBlank()){ "Enter a device name." };RemotePath.name(share);RemotePath.clean(root)
            onSave(Device(existing?.id?:java.util.UUID.randomUUID().toString(),name.trim(),server,share,root,user,domain,port,encrypted),password)
        }catch(e: Exception){error=e.message}
    },enabled=name.isNotBlank()&&host.isNotBlank()&&share.isNotBlank()){Text("Save")}})}) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize().imePadding(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            item { OutlinedTextField(name,{name=it},modifier=Modifier.fillMaxWidth(),label={Text("Device name")},singleLine=true) }
            item { OutlinedTextField(host,{host=it},modifier=Modifier.fillMaxWidth(),label={Text("Host or Tailscale name")},placeholder={Text("computer.your-tailnet.ts.net")},singleLine=true) }
            item { OutlinedTextField(share,{share=it},modifier=Modifier.fillMaxWidth(),label={Text("Shared folder name")},singleLine=true) }
            item { OutlinedTextField(root,{root=it},modifier=Modifier.fillMaxWidth(),label={Text("Start folder (optional)")},singleLine=true) }
            item { OutlinedTextField(user,{user=it},modifier=Modifier.fillMaxWidth(),label={Text("Username")},singleLine=true) }
            item { OutlinedTextField(password,{password=it},modifier=Modifier.fillMaxWidth(),label={Text(if(existing==null)"Password" else "New password (blank keeps saved)")},visualTransformation=PasswordVisualTransformation(),singleLine=true) }
            item { OutlinedTextField(domain,{domain=it},modifier=Modifier.fillMaxWidth(),label={Text("Domain (optional)")},singleLine=true) }
            item { Row(verticalAlignment=Alignment.CenterVertically) { Checkbox(encrypted,{encrypted=it});Text("Require SMB3 encryption") } }
            item { Text("Use your computer's account password, not its Windows Hello PIN. Keep Tailscale connected.",style=MaterialTheme.typography.bodySmall) }
            (error?:problem)?.let { message -> item { Text(message,color=MaterialTheme.colorScheme.error) } }
            if(existing!=null)item { TextButton(onClick={removing=true}) { Text("Remove saved connection") } }
        }
    }
    if(removing)AlertDialog(onDismissRequest={removing=false},title={Text("Remove connection?")},text={Text("This forgets the saved connection and password. Remote files stay on the computer.")},confirmButton={TextButton(onClick={onRemove(existing!!);removing=false}){Text("Remove")}},dismissButton={TextButton(onClick={removing=false}){Text("Cancel")}})
}
