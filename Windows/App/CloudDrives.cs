using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace MyDrive;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer cloudTimer = new();
    private JsonElement cloudState;
    private JsonElement cloudEntries;
    private string cloudAccount = "", cloudPath = "", cloudStatus = "";
    private bool cloudBusy, cloudRefreshing;
    private long nextCloudSchedule;

    private Task<JsonElement> CloudCall(string action, object? payload = null) =>
        CoreBridge.Call(new { action = "cloud." + action, data_dir = CoreBridge.DataDir, payload });

    private static IEnumerable<JsonElement> CloudItems(JsonElement source, string key) =>
        source.ValueKind == JsonValueKind.Object && source.TryGetProperty(key, out var array)
            ? array.EnumerateArray() : Enumerable.Empty<JsonElement>();

    private void StartCloudController()
    {
        cloudTimer.Tick += (_, _) => _ = RefreshCloud(tick: true);
        if (File.Exists(Path.Combine(CoreBridge.DataDir, "cloud", "state.json"))) _ = RefreshCloud(tick: true);
    }

    private bool CloudBackupActive() => CloudItems(cloudState, "jobs")
        .Any(entry => S(entry.GetProperty("report"), "phase") is "running" or "queued");

    private void UpdateCloudTimer()
    {
        var jobs = CloudItems(cloudState, "jobs");
        bool scheduled = jobs.Any(entry => entry.GetProperty("job").GetProperty("interval").GetInt64() > 0 &&
            !entry.GetProperty("job").GetProperty("paused").GetBoolean());
        bool active = CloudBackupActive();
        bool watching = active && currentView == "cloud" && AppWindow.IsVisible;
        if (!scheduled && !active) { cloudTimer.Stop(); return; }
        var interval = TimeSpan.FromSeconds(watching ? 3 : active ? 30 : 60);
        if (cloudTimer.Interval != interval) cloudTimer.Interval = interval;
        if (!cloudTimer.IsEnabled) cloudTimer.Start();
    }

    private async Task RefreshCloud(bool tick = false)
    {
        if (diagnosticMode || cloudRefreshing || quitting) return;
        cloudRefreshing = true;
        try
        {
            long now = Environment.TickCount64;
            if (tick && now >= nextCloudSchedule)
            {
                nextCloudSchedule = now + 60_000;
                await CloudCall("tick");
            }
            var current = await CloudCall("status");
            bool changed = cloudState.ValueKind == JsonValueKind.Undefined || current.GetRawText() != cloudState.GetRawText();
            cloudState = current;
            if (changed && currentView == "cloud" && AppWindow.IsVisible && modalDepth == 0) Render();
        }
        catch (Exception error)
        {
            if (currentView == "cloud" && modalDepth == 0)
            {
                cloudStatus = error.Message;
                Render();
            }
        }
        finally { cloudRefreshing = false; UpdateCloudTimer(); }
    }

    private async Task CloudAction(string label, Func<Task> work)
    {
        if (cloudBusy) return;
        cloudBusy = true;
        cloudStatus = label;
        if (currentView == "cloud") Render();
        try { await work(); cloudStatus = ""; }
        catch (Exception error) { cloudStatus = error.Message; }
        finally
        {
            cloudBusy = false;
            await RefreshCloud();
            if (currentView == "cloud") Render();
        }
    }

    private async Task BrowseCloud(string account, string path)
    {
        await CloudAction("Opening cloud folder…", async () =>
        {
            var entries = await CloudCall("browse", new { account, path });
            cloudAccount = account;
            cloudPath = path;
            cloudEntries = entries;
        });
    }

    private void ReturnToCloudAccounts()
    {
        if (cloudBusy) return;
        cloudAccount = cloudPath = cloudStatus = "";
        Render();
        _ = RefreshCloud();
    }

    private void RenderCloudDrives()
    {
        if (!compact) Heading("Cloud Drives", "");
        if (cloudStatus.Length > 0)
        {
            var message = Text(cloudStatus, 12);
            page.Children.Add(message);
        }
        if (cloudAccount.Length > 0)
        {
            RenderCloudFolder();
            return;
        }
        var connect = QuickButton("Connect account…", () => _ = ConnectCloud(), true);
        connect.IsEnabled = !cloudBusy;
        page.Children.Add(connect);
        foreach (var account in CloudItems(cloudState, "accounts"))
        {
            string id = S(account, "id"), name = S(account, "name");
            var actions = new MenuFlyout();
            MenuAction(actions, "Sign in again…", () => _ = CloudAction("Complete sign-in in your browser…",
                async () => { await CloudCall("connect", new { account = id }); }));
            MenuAction(actions, "Disconnect…", () => _ = ConfirmCloud("Disconnect " + name + "?",
                "Disconnect", () => CloudCall("disconnect", new { account = id })));
            AddCloudRow(name, () => _ = BrowseCloud(id, ""), actions);
        }
        var jobs = CloudItems(cloudState, "jobs").ToList();
        if (jobs.Count == 0) return;
        page.Children.Add(QuickText("Backups", 13, true));
        foreach (var entry in jobs)
        {
            var job = entry.GetProperty("job");
            var report = entry.GetProperty("report");
            string id = S(job, "id"), accountId = S(job, "account");
            string account = CloudItems(cloudState, "accounts").Where(row => S(row, "id") == accountId)
                .Select(row => S(row, "name")).FirstOrDefault() ?? "Cloud";
            string folder = S(job, "folder"), phase = S(report, "phase");
            bool active = phase is "queued" or "running", paused = job.GetProperty("paused").GetBoolean();
            var actions = new MenuFlyout();
            if (job.GetProperty("interval").GetInt64() > 0)
                MenuAction(actions, paused ? "Resume schedule" : "Pause schedule", () =>
                    _ = CloudAction("Updating backup…", async () => {
                        await CloudCall("pause", new { job = id, paused = !paused });
                        if (paused) nextCloudSchedule = 0;
                    }));
            MenuAction(actions, "Browse backup", () => _ = BrowseCloud(accountId, folder));
            MenuAction(actions, "Browse previous versions", () => _ = BrowseCloud(accountId, "myDrive Versions/" + id));
            MenuAction(actions, "Remove backup…", () => _ = ConfirmCloud("Remove backup schedule?", "Remove",
                () => CloudCall("remove", new { job = id })));
            var row = new StackPanel { Spacing = 1 };
            var title = QuickText(account + " · " + folder, 12, true);
            ToolTipService.SetToolTip(title, S(job, "source"));
            row.Children.Add(title);
            string detail = phase switch {
                "queued" => "Queued",
                "running" => "Backing up · " + report.GetProperty("files").GetInt64() + " files copied",
                "complete" => "Backup complete",
                "failed" => S(report, "message"),
                _ => "Ready to back up",
            };
            row.Children.Add(Text(paused && !active ? "Schedule paused · " + detail : detail, 11));
            var line = new Grid { ColumnSpacing = 4 };
            line.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            line.Children.Add(row);
            var run = QuickButton("Run now", () => _ = CloudAction("Starting backup…",
                async () => { await CloudCall("run", new { job = id }); }));
            run.IsEnabled = !cloudBusy && !active;
            Grid.SetColumn(run, 1); line.Children.Add(run);
            var menu = QuickIcon("\uE712", "Backup options", () => { }); menu.Flyout = actions;
            Grid.SetColumn(menu, 2); line.Children.Add(menu);
            page.Children.Add(QuickRow(line));
        }
    }

    private void AddCloudRow(string name, Action open, MenuFlyout? options = null)
    {
        var select = QuickButton("", open);
        select.Content = QuickText(name, 12);
        select.HorizontalAlignment = HorizontalAlignment.Stretch;
        select.HorizontalContentAlignment = HorizontalAlignment.Left;
        select.IsEnabled = !cloudBusy;
        ToolTipService.SetToolTip(select, name);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(select, name);
        if (options == null) { page.Children.Add(select); return; }
        var row = new Grid { ColumnSpacing = 4 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(select);
        var menu = QuickIcon("\uE712", "Options for " + name, () => { });
        menu.Flyout = options;
        menu.IsEnabled = !cloudBusy;
        Grid.SetColumn(menu, 1); row.Children.Add(menu);
        page.Children.Add(row);
    }

    private void RenderCloudFolder()
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        header.Children.Add(QuickButton("Accounts", ReturnToCloudAccounts));
        if (cloudPath.Length > 0)
        {
            int slash = cloudPath.LastIndexOf('/');
            header.Children.Add(QuickButton("Up", () => _ = BrowseCloud(cloudAccount, slash < 0 ? "" : cloudPath[..slash])));
        }
        header.Children.Add(QuickButton("Back up a folder…", () => _ = AddCloudBackup()));
        page.Children.Add(header);
        if (cloudPath.Length > 0)
        {
            var title = QuickText(cloudPath, 12, true);
            ToolTipService.SetToolTip(title, cloudPath);
            page.Children.Add(title);
        }
        foreach (var item in CloudItems(cloudEntries, "entries"))
        {
            string path = S(item, "path"), name = S(item, "name");
            bool directory = item.GetProperty("folder").GetBoolean();
            AddCloudRow(directory ? name + "  ›" : name, directory ? () => _ = BrowseCloud(cloudAccount, path)
                : () => _ = DownloadCloudFile(path, name));
        }
        if (cloudEntries.TryGetProperty("truncated", out var truncated) && truncated.GetBoolean())
            page.Children.Add(Text("Showing the first 4,000 entries.", 11));
        if (!CloudItems(cloudEntries, "entries").Any()) page.Children.Add(QuickText("Empty folder", 12));
    }

    private async Task ConnectCloud()
    {
        if (cloudBusy) return;
        var provider = new ComboBox { Header = "Provider", ItemsSource = new[] { "Dropbox", "OneDrive", "Google Drive" },
            SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var name = new TextBox { Header = "Account name", MaxLength = 80, PlaceholderText = "Personal or Work" };
        var clientId = new TextBox { Header = "Google Drive client ID", MaxLength = 512 };
        var clientSecret = new PasswordBox { Header = "Google Drive client secret", MaxLength = 512 };
        var googleFields = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
        var help = new HyperlinkButton { Content = "Create a Google Drive desktop client",
            NavigateUri = new Uri("https://rclone.org/drive/#making-your-own-client-id") };
        googleFields.Children.Add(help); googleFields.Children.Add(clientId); googleFields.Children.Add(clientSecret);
        var form = new StackPanel { Spacing = 8 };
        form.Children.Add(provider); form.Children.Add(name); form.Children.Add(googleFields);
        provider.SelectionChanged += (_, _) => googleFields.Visibility =
            provider.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
        if (await ShowDialog(new ContentDialog { Title = "Connect cloud account", XamlRoot = root.XamlRoot, Content = form,
            PrimaryButtonText = "Connect", CloseButtonText = "Cancel" }) != ContentDialogResult.Primary) return;
        string selected = new[] { "dropbox", "onedrive", "drive" }[provider.SelectedIndex];
        string label = string.IsNullOrWhiteSpace(name.Text) ? provider.SelectedItem.ToString()! : name.Text;
        string identity = selected == "drive" ? clientId.Text : "";
        string secret = selected == "drive" ? clientSecret.Password : "";
        clientSecret.Password = "";
        await CloudAction("Preparing Cloud Drives. Complete sign-in in your browser…",
            async () => { await CloudCall("connect", new { name = label, provider = selected,
                client_id = identity, client_secret = secret }); });
    }

    private async Task AddCloudBackup()
    {
        if (cloudBusy) return;
        var account = cloudAccount;
        var path = cloudPath;
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, hwnd);
        picker.FileTypeFilter.Add("*");
        var folder = await Modal(async () => await picker.PickSingleFolderAsync());
        if (folder == null) return;
        var destination = new TextBox { Header = "Cloud destination", Text = path.Length > 0 ? path : "Backups/" + folder.Name };
        var schedule = new ComboBox { Header = "Schedule", ItemsSource = new[] { "Run manually", "Hourly", "Daily" },
            SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var form = new StackPanel { Spacing = 8 };
        form.Children.Add(QuickText(folder.Path, 12)); form.Children.Add(destination); form.Children.Add(schedule);
        if (await ShowDialog(new ContentDialog { Title = "Back up a folder", XamlRoot = root.XamlRoot, Content = form,
            PrimaryButtonText = "Save backup", CloseButtonText = "Cancel" }) != ContentDialogResult.Primary) return;
        await CloudAction("Saving backup…", async () =>
        {
            await CloudCall("add", new { account, path = destination.Text.Trim(), source = folder.Path,
                interval = new[] { 0, 60, 1440 }[schedule.SelectedIndex] });
            cloudAccount = cloudPath = "";
            if (schedule.SelectedIndex > 0)
            {
                nextCloudSchedule = Environment.TickCount64 + 60_000;
                await CloudCall("tick");
            }
        });
    }

    private async Task DownloadCloudFile(string path, string name)
    {
        if (cloudBusy) return;
        var account = cloudAccount;
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, hwnd);
        var destination = await Modal(async () => await picker.PickSingleFolderAsync());
        if (destination == null) return;
        string fileName = string.Concat(name.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '_' : character));
        string selected = Path.Combine(destination.Path, fileName);
        await CloudAction("Downloading…", async () =>
        {
            await CloudCall("download", new { account, path, destination = selected });
        });
    }

    private async Task ConfirmCloud(string title, string action, Func<Task<JsonElement>> work)
    {
        if (cloudBusy) return;
        if (await ShowDialog(new ContentDialog { Title = title, XamlRoot = root.XamlRoot,
            PrimaryButtonText = action, CloseButtonText = "Cancel" }) != ContentDialogResult.Primary) return;
        await CloudAction(action + "…", async () => { await work(); });
    }
}
