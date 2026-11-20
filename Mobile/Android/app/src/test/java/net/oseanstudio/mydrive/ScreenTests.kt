package net.oseanstudio.mydrive

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.graphics.asAndroidBitmap
import android.graphics.Bitmap
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import androidx.lifecycle.ViewModelProvider

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk=[35],qualifiers="w393dp-h852dp-440dpi")
class ScreenTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun devicesAndTransfersFitPhoneScreen(){
        compose.onNodeWithText("Your devices").assertIsDisplayed()
        val folder=File(System.getProperty("user.dir"),"screenshots").apply{mkdirs()}
        compose.activity.window.decorView.captureRoboImage(File(folder,"devices.png").absolutePath)
    }
    private fun capture(name: String){val folder=File(System.getProperty("user.dir"),"screenshots").apply{mkdirs()};compose.activity.window.decorView.captureRoboImage(File(folder,"$name.png").absolutePath)}
    @Test fun deviceEditorIsScrollableAndSaveIsVisible(){compose.onNodeWithText("Add SMB device").performClick();compose.onNodeWithText("Save").assertIsDisplayed();val folder=File(System.getProperty("user.dir"),"screenshots").apply{mkdirs()};captureScreenRoboImage(File(folder,"device-editor.png").absolutePath)}
    @Test fun browserShowsLongNamesWithoutLeavingPhoneBounds(){
        compose.runOnIdle{val model=ViewModelProvider(compose.activity)[DriveModel::class.java];model.active=Device(name="Studio laptop",host="studio-laptop.tailnet.ts.net",share="Files");model.tab=1;model.entries=listOf(RemoteEntry("Project assets and source","Project assets and source",true,0),RemoteEntry("A very long studio recording filename with unicode 雪 and spaces.wav","long.wav",false,2_654_321),RemoteEntry("Notes.txt","Notes.txt",false,1042))}
        compose.onNodeWithText("Studio laptop").assertIsDisplayed();compose.onNodeWithText("Notes.txt").assertIsDisplayed();capture("browser")
    }
    @Test @Config(qualifiers="w320dp-h640dp-night-320dpi") fun compactDarkTransferStatesStayReadable(){
        compose.runOnIdle{ViewModelProvider(compose.activity)[DriveModel::class.java].tab=2;Transfers.items.value=listOf(Transfer(name="Studio recording.wav",device="Studio laptop",direction="Incoming",state="Transferring",bytes=500,total=1000),Transfer(name="Project.zip",device="Studio PC",direction="Outgoing",state="Needs attention",error="The server did not respond. Check Tailscale."),Transfer(name="Photos",device="Blip account",direction="Outgoing",state="Handed to Blip"))}
        compose.onNodeWithText("Studio laptop · Transferring").assertIsDisplayed();compose.onNodeWithText("Check Blip for acceptance and delivery.").assertIsDisplayed();capture("transfers-dark-small")
    }
}
