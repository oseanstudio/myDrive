package net.oseanstudio.mydrive

import android.content.*
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import java.net.URI

object BlipSharing {
    const val PACKAGE="net.blip.android"
    fun send(context: Context,uris: List<Uri>,text: String?=null) {
        require(uris.isNotEmpty()||!text.isNullOrBlank()){ "Choose files or enter a link." }
        val intent=Intent(if(uris.size>1)Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND).setType(if(uris.isEmpty())"text/plain" else "*/*").setPackage(PACKAGE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if(uris.size>1)intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM,ArrayList(uris))else uris.firstOrNull()?.let{intent.putExtra(Intent.EXTRA_STREAM,it)}
        if(text!=null)intent.putExtra(Intent.EXTRA_TEXT,text)
        if(uris.isNotEmpty()){val clip=ClipData.newUri(context.contentResolver,"Files",uris.first());uris.drop(1).forEach{clip.addItem(ClipData.Item(it))};intent.clipData=clip}
        check(intent.resolveActivity(context.packageManager)!=null){"Install and sign in to Blip on this phone, then try again."}
        context.startActivity(Intent.createChooser(intent,"Send using your Blip account"))
    }
    fun fileUri(context: Context,file: File): Uri=FileProvider.getUriForFile(context,"${context.packageName}.files",file)
    fun webLink(file: File): Uri? = runCatching {
        if(file.extension.lowercase()!="url"||file.length()>65536)return null
        var section=false;var target: String?=null
        for(raw in file.readLines()){val line=raw.trim().removePrefix("\uFEFF");if(line.startsWith('[')){section=line.equals("[InternetShortcut]",true);continue};if(section&&line.substringBefore('=').equals("URL",true)){if(target!=null)return null;target=line.substringAfter('=')}}
        val value=target?.trim()?:return null;val url=URI(value)
        if(url.scheme?.lowercase() !in setOf("http","https")||url.host.isNullOrBlank()||url.rawUserInfo!=null||value.any{it.code<32||it=='\\'})return null
        Uri.parse(url.toASCIIString())
    }.getOrNull()
}
