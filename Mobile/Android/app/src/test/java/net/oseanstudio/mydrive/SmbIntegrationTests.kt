package net.oseanstudio.mydrive

import android.app.Application
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35])
class SmbIntegrationTests {
    @Test fun realLoopbackSmbBrowseTransferRenameAndCancellation()=runBlocking<Unit> {
        val source=System.getenv("MYDRIVE_SMB_FIXTURE")
        assumeTrue("Run the optional loopback SMB fixture first",!source.isNullOrBlank())
        val config=JSONObject(File(source!!).readText())
        val app=ApplicationProvider.getApplicationContext<Application>()
        val device=Device(name="Loopback fixture",host="127.0.0.1",share="fixture",username="fixture",port=config.getInt("port"))
        val client=SmbClient(app){config.getString("password")}
        val folder="test-${UUID.randomUUID()}";client.mkdir(device,folder)
        try {
            val original=ByteArray(400_123){(it%251).toByte()};val input=File(app.cacheDir,"upload.bin").apply{writeBytes(original)}
            client.upload(device,folder,"upload.bin",Uri.fromFile(input)){_,_->}
            val listed=client.list(device,folder);assertEquals(listOf("upload.bin"),listed.map{it.name});assertEquals(original.size.toLong(),listed.single().size)
            val downloaded=client.download(device,listed.single()){_,_->};assertArrayEquals(original,downloaded.readBytes())
            var refused=false;try{client.upload(device,folder,"upload.bin",Uri.fromFile(input)){_,_->}}catch(e: Exception){refused=true};assertTrue("Existing destination must not be overwritten",refused)
            assertFalse("Owned temporary uploads must be removed",client.list(device,folder).any{it.name.startsWith(".mydrive-")})
            client.rename(device,"$folder/upload.bin","$folder/renamed.bin");assertEquals("renamed.bin",client.list(device,folder).single().name)
            client.delete(device,client.list(device,folder).single());assertTrue(client.list(device,folder).isEmpty())
            val large=File(app.cacheDir,"cancel.bin").apply{outputStream().use{out->repeat(64){out.write(ByteArray(128*1024){42})}}}
            var cancelled=false;try{withTimeout(450){client.upload(device,folder,"cancel.bin",Uri.fromFile(large)){_,_->Thread.sleep(20)}}}catch(e: TimeoutCancellationException){cancelled=true}
            assertTrue("Cancellation should interrupt an active upload",cancelled)
            assertFalse(client.list(device,folder).any{it.name=="cancel.bin"||it.name.startsWith(".mydrive-")})
            downloaded.delete();input.delete();large.delete()
        } finally {
            for(item in client.list(device,folder))client.delete(device,item)
            client.delete(device,RemoteEntry(folder,folder,true,0))
        }
    }
}
