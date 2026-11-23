using System.Text.Json;
using Microsoft.UI.Xaml.Controls;

namespace MyDrive;
public sealed partial class MainWindow
{
    private JsonElement sendActivity;
    private string sendActivityOwner = "", sendActivityError = "";
    private bool readingSendActivity;
    private long lastSendActivity = -10_000;

    private async Task LoadSendActivity(bool retry = false, string? id = null)
    {
        var owner = BlipOwner;
        if (diagnosticMode || owner.Length == 0 || readingSendActivity) return;
        readingSendActivity = true;
        lastSendActivity = Environment.TickCount64;
        if (sendActivityOwner != owner) sendActivity = default;
        sendActivityOwner = owner;
        sendActivityError = "";
        if (currentView == "activity") Render();
        try
        {
            if (retry && id != null) await blip.RetryAsync(owner, id);
            var reply = await blip.ActivityAsync(owner);
            if (owner == BlipOwner) sendActivity = reply;
        }
        catch (Exception error)
        {
            if (owner == BlipOwner) sendActivityError = error.Message;
        }
        finally
        {
            lastSendActivity = Environment.TickCount64;
            readingSendActivity = false;
            if (currentView == "activity") Render();
        }
    }

    private void RenderSendActivity()
    {
        var owner = BlipOwner;
        if (owner.Length == 0) return;
        if (!diagnosticMode && !readingSendActivity &&
            (owner != sendActivityOwner || Environment.TickCount64 - lastSendActivity >= 15_000))
        {
            DispatcherQueue.TryEnqueue(() => _ = LoadSendActivity());
        }
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        header.Children.Add(QuickText("Send activity", 13, true));
        var refresh = QuickIcon("\uE72C", "Refresh Send activity", () => _ = LoadSendActivity());
        refresh.IsEnabled = !readingSendActivity;
        header.Children.Add(refresh);
        page.Children.Add(header);
        if (readingSendActivity) page.Children.Add(QuickText("Checking sends…", 11));
        if (sendActivityOwner != owner) return;
        if (!string.IsNullOrEmpty(sendActivityError)) page.Children.Add(Text(sendActivityError, 11));
        var entries = sendActivity.ValueKind == JsonValueKind.Object
            ? Items(sendActivity, "entries").ToArray() : Array.Empty<JsonElement>();
        foreach (var entry in entries)
        {
            var details = new StackPanel { Spacing = 2 };
            details.Children.Add(QuickText(S(entry, "kind") + " · " + S(entry, "name"), 12, true));
            details.Children.Add(QuickText(S(entry, "recipient") + " · " + S(entry, "status"), 11));
            if (S(entry, "detail") is { Length: > 0 } failure) details.Children.Add(Text(failure, 11));
            if (B(entry, "can_retry"))
            {
                var retry = QuickButton("Retry", () => _ = LoadSendActivity(retry: true, id: S(entry, "id")));
                retry.IsEnabled = !readingSendActivity;
                details.Children.Add(retry);
            }
            page.Children.Add(QuickRow(details));
        }
        if (!readingSendActivity && sendActivityError.Length == 0 && entries.Length == 0)
            page.Children.Add(QuickText("No sends recorded yet.", 11));
    }
}
