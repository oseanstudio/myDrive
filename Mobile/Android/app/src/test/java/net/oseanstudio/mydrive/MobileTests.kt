package net.oseanstudio.mydrive

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import androidx.test.core.app.ApplicationProvider
import android.app.Application
import java.io.File

class PathTests {
    @Test fun traversalAndAbsolutePathsStayOutsideTheShare(){for(value in listOf("../private","a/../../b","C:/data","a\\b","\u0000"))assertThrows(IllegalArgumentException::class.java){RemotePath.clean(value)}}
    @Test fun tailscaleAddressesAndCustomPortsAreAccepted(){assertEquals("computer.tailnet.ts.net" to 445,RemotePath.server("smb://computer.tailnet.ts.net"));assertEquals("100.64.1.2" to 1445,RemotePath.server("100.64.1.2:1445"))}
    @Test fun credentialsAndPathsAreNotParsedFromServerField(){for(value in listOf("smb://name:password@server","smb://server/share","http://server","smb://server?password=secret"))assertThrows(IllegalArgumentException::class.java){RemotePath.server(value)}}
    @Test fun filenameInjectionAndTraversalAreRejected(){for(value in listOf("..","a/b","a\\b","a:","x\u0000","x "))assertThrows(IllegalArgumentException::class.java){RemotePath.name(value)};assertEquals("My folder/雪.txt",RemotePath.child("My folder","雪.txt"))}
}
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35])
class MobileStateTests {
    private val context get()=ApplicationProvider.getApplicationContext<Application>()
    @Test fun receivedLinksDefaultOnAndRespectOptOut(){context.getSharedPreferences("mydrive",0).edit().clear().commit();val store=Store(context);assertTrue(store.autoOpenLinks);store.autoOpenLinks=false;assertFalse(Store(context).autoOpenLinks)}
    @Test fun shortcutNeverLaunchesCustomSchemesOrAmbiguousFields(){val file=File(context.cacheDir,"fixture.url");for(value in listOf("file:///private/data","javascript:alert(1)","ms-settings:test","https://user:password@example.com/")){file.writeText("[InternetShortcut]\nURL=$value");assertNull(BlipSharing.webLink(file))};file.writeText("[InternetShortcut]\nURL=https://example.com/\nURL=https://example.org/");assertNull(BlipSharing.webLink(file));file.writeText("[InternetShortcut]\nURL=https://example.com/?a=1&b=2");assertEquals("example.com",BlipSharing.webLink(file)?.host)}
    @Test fun interruptedHistoryIsNotReportedComplete(){val store=Store(context);store.history(listOf(Transfer(name="Fixture",device="Computer",direction="Outgoing",state="Transferring")));val item=Store(context).history().single();assertEquals("Interrupted",item.state);assertFalse(item.active)}
    @Test fun connectionExportContainsNoPassword(){val device=Device(name="Computer",host="computer",share="Files");assertFalse(device.json().toString().contains("password"));assertEquals(device,Device.from(device.json()))}
    @Test fun importedConnectionsCannotReuseSavedCredentialIdentity(){val device=Device(name="Computer",host="computer",share="Files");val imported=Device.imported(device.json());assertNotEquals(device.id,imported.id);assertEquals(device.host,imported.host)}
}
