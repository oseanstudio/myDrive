package net.oseanstudio.mydrive

import java.net.URI
import java.util.UUID
import org.json.JSONObject

data class Device(val id: String = UUID.randomUUID().toString(), val name: String, val host: String, val share: String, val root: String = "", val username: String = "", val domain: String = "", val port: Int = 445, val encrypted: Boolean = false) {
    fun json() = JSONObject().put("id",id).put("name",name).put("host",host).put("share",share).put("root",root).put("username",username).put("domain",domain).put("port",port).put("encrypted",encrypted)
    companion object {
        fun from(o: JSONObject) = Device(o.optString("id",UUID.randomUUID().toString()),o.getString("name"),o.getString("host"),o.getString("share"),o.optString("root"),o.optString("username"),o.optString("domain"),o.optInt("port",445),o.optBoolean("encrypted"))
        fun imported(o: JSONObject)=from(o).copy(id=UUID.randomUUID().toString()).also { require(it.name.isNotBlank()&&it.port in 1..65535);RemotePath.server(it.host);RemotePath.name(it.share);RemotePath.clean(it.root) }
    }
}
data class RemoteEntry(val name: String, val path: String, val directory: Boolean, val size: Long, val linked: Boolean = false)
data class Transfer(val id: String = UUID.randomUUID().toString(), val name: String, val device: String, val direction: String, val state: String = "Queued", val bytes: Long = 0, val total: Long = 0, val localPath: String? = null, val error: String? = null) {
    val active get() = state in setOf("Queued","Connecting","Transferring","Saving")
    fun json() = JSONObject().put("id",id).put("name",name).put("device",device).put("direction",direction).put("state",state).put("bytes",bytes).put("total",total).put("localPath",localPath).put("error",error)
    companion object { fun from(o: JSONObject) = Transfer(o.getString("id"),o.getString("name"),o.optString("device"),o.optString("direction"),o.optString("state"),o.optLong("bytes"),o.optLong("total"),o.optString("localPath").takeIf{it.isNotBlank()&&it!="null"},o.optString("error").takeIf{it.isNotBlank()&&it!="null"}) }
}
object RemotePath {
    fun clean(value: String): String {
        require(!value.any{it=='\\'||it==':'||it=='\u0000'}) { "Use a relative path inside the share." }
        val parts=value.split('/').filter{it.isNotEmpty()&&it!="."}
        require(parts.none{it==".."}) { "The path must stay inside this share." }
        return parts.joinToString("/")
    }
    fun name(value: String): String {
        require(value.isNotBlank()&&value!="."&&value!=".."&&value.none{it in "<>:\"/\\|?*"||it.code<32}&&!value.endsWith('.')&&!value.endsWith(' ')) { "Enter a single valid file or folder name." }
        return value
    }
    fun child(parent: String,name: String)=clean(listOf(parent,this.name(name)).filter{it.isNotEmpty()}.joinToString("/"))
    fun server(raw: String): Pair<String,Int> {
        val uri=URI(if(raw.startsWith("smb://",true))raw else "smb://$raw")
        require(uri.scheme.equals("smb",true)&&uri.host!=null&&uri.rawUserInfo==null&&uri.rawQuery==null&&uri.rawFragment==null&&uri.path.orEmpty().let{it.isEmpty()||it=="/"}) { "Enter only the server hostname or Tailscale address; put the share below." }
        val port=if(uri.port==-1)445 else uri.port;require(port in 1..65535)
        return uri.host.removeSurrounding("[","]") to port
    }
}
