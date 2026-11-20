package net.oseanstudio.mydrive

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow

class Store(context: Context) {
    private val prefs=context.getSharedPreferences("mydrive",Context.MODE_PRIVATE)
    var autoOpenLinks: Boolean get()=prefs.getBoolean("auto_open_links",true); set(value){prefs.edit().putBoolean("auto_open_links",value).apply()}
    var receivedTree: String? get()=prefs.getString("received_tree",null); set(value){prefs.edit().putString("received_tree",value).apply()}
    fun devices(): List<Device> { val a=JSONArray(prefs.getString("devices","[]"));return (0 until a.length()).map{Device.from(a.getJSONObject(it))} }
    fun save(devices: List<Device>){check(prefs.edit().putString("devices",JSONArray(devices.map{it.json()}).toString()).commit()){ "Could not save devices." }}
    private fun key(): SecretKey {
        val ks=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
        (ks.getKey("mydrive.smb",null) as? SecretKey)?.let{return it}
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply{init(KeyGenParameterSpec.Builder("mydrive.smb",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())}.generateKey()
    }
    fun password(id: String): String {
        val stored=prefs.getString("secret.$id",null)?:return ""
        val pair=stored.split(':',limit=2);require(pair.size==2){"Saved password cannot be read. Edit this device."}
        val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,Base64.decode(pair[0],Base64.NO_WRAP)))
        return String(cipher.doFinal(Base64.decode(pair[1],Base64.NO_WRAP)),Charsets.UTF_8)
    }
    fun password(id: String,value: String){val c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.ENCRYPT_MODE,key());check(prefs.edit().putString("secret.$id",Base64.encodeToString(c.iv,Base64.NO_WRAP)+":"+Base64.encodeToString(c.doFinal(value.toByteArray()),Base64.NO_WRAP)).commit()){ "Could not save the password." }}
    fun removePassword(id: String){prefs.edit().remove("secret.$id").commit()}
    fun history(): List<Transfer> {val a=JSONArray(prefs.getString("history","[]"));return (0 until a.length()).map{Transfer.from(a.getJSONObject(it)).let{t->if(t.active)t.copy(state="Interrupted",error="The app stopped. Check the destination before retrying.")else t}}}
    fun history(items: List<Transfer>){prefs.edit().putString("history",JSONArray(items.take(200).map{it.json()}).toString()).apply()}
}
object Transfers {
    val items=MutableStateFlow<List<Transfer>>(emptyList())
    var historyError: String?=null; private set
    private var historyReadable=true
    @Synchronized fun init(context: Context){if(items.value.isEmpty()&&historyReadable)try{items.value=Store(context).history()}catch(e: Exception){historyReadable=false;historyError="Saved transfer history could not be loaded. Its existing data has been kept."}}
    @Synchronized fun update(context: Context,transfer: Transfer){items.value=listOf(transfer)+items.value.filterNot{it.id==transfer.id};if(historyReadable&&(!transfer.active||transfer.state in setOf("Queued","Connecting")))Store(context).history(items.value)}
}
