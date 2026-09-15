using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static class SmokeWebSharing
{
    public static async Task RunAsync(string output)
    {
        Directory.CreateDirectory(output); Appearance.Apply(false);
        string root = Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var server = await SmokeSync.FixtureServer.StartAsync(root);
        var library = new LibraryStore(Path.Combine(root, "library"));
        var recording = new Recording { Title = "웹 공유 확인", DurationSeconds = 1, Mode = RecordingMode.Imported };
        library.Save(recording);
        var notes = new MeetingNotes("# 결정 사항\n\n금요일까지 초안을 준비합니다.", DateTimeOffset.UtcNow, "synthetic", 0);
        JsonDisk.Write(library.NotesPath(recording.Id), notes);
        JsonDisk.Write(library.TranscriptPath(recording.Id), new TranscriptCache("fixture", "fixture", "ko", ["private-transcript-never-upload"], true));
        var settings = new AppSettings { SharingServerUrl = "https://sync.fixture", ProtectedSharingSyncToken = SettingsStore.ProtectKey("synthetic-windows-sync-token"),
            ProtectedApiKey = SettingsStore.ProtectKey("synthetic-private-ai-key"), KeepRunningInTray = false };
        new SettingsStore(library.Root).Save(settings);
        var publications = new List<string>(); bool loseNextResponse = false;
        HttpMessageHandler Handler(SyncConfiguration _) => new Observe(server.Handler(), async request =>
        {
            Require(request.RequestUri!.AbsolutePath.StartsWith("/v1/shares/", StringComparison.Ordinal), "Unexpected management request.");
            if (request.Method != HttpMethod.Put) return;
            string body = await request.Content!.ReadAsStringAsync();
            using var json = JsonDocument.Parse(body);
            Require(json.RootElement.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(new[] { "markdown", "title" }), "Share payload included more than title and minutes.");
            Require(!body.Contains("private-transcript") && !body.Contains("synthetic-private-ai-key"), "Private data leaked into share payload.");
            publications.Add(body);
        }, request => { bool lose = request.Method == HttpMethod.Put && loseNextResponse; if (lose) loseNextResponse = false; return lose; });
        MainWindow Main() => new(library, discoverDevices: false, enableDesktopIntegration: false, syncHandlerFactory: Handler)
            { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        MainWindow main = Main(); string firstUrl = "", secondUrl = "";
        try
        {
            main.Show(); ((TabControl)main.FindName("DetailPanel")).SelectedIndex = 1;
            await WithShare(main, async dialog =>
            {
                Require(Button(dialog, "PublishWebShareButton").IsEnabled && dialog.CurrentUrl is null, "Initial share state was not loaded.");
                Click(dialog, "PublishWebShareButton"); await dialog.CurrentOperation;
                firstUrl = dialog.CurrentUrl ?? throw new InvalidOperationException("Publication URL missing.");
                Require(Button(dialog, "CopyWebShareButton").IsEnabled && Button(dialog, "RevokeWebShareButton").IsEnabled, "Published link controls missing.");
                await SmokeUi.CaptureAsync(dialog, Path.Combine(output, "active-share.png"));
            });
            var publicPage = await Public(firstUrl); Require(publicPage.Status == HttpStatusCode.OK && publicPage.Html.Contains("금요일까지 초안을 준비합니다."), "Public page did not show the snapshot without auth.");
            File.WriteAllText(Path.Combine(output, "public-snapshot.html"), publicPage.Html);
            await WithShare(main, dialog => { Require(dialog.CurrentUrl == firstUrl, "Reopening lost the URL."); return Task.CompletedTask; });
            Require(publications.Count == 1, "Reopening published a replacement unexpectedly.");

            await Close(main); server.Dispose(); server = await SmokeSync.FixtureServer.StartAsync(root); main = Main(); main.Show();
            await WithShare(main, dialog => { Require(dialog.CurrentUrl == firstUrl, "App/server restart lost the persisted URL."); return Task.CompletedTask; });

            string? copied = null;
            var copyWindow = new WebShareWindow(recording, notes, settings, Handler, value => copied = value)
                { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
            copyWindow.Show(); await copyWindow.CurrentOperation;
            Click(copyWindow, "CopyWebShareButton"); Click(copyWindow, "CopyWebShareButton");
            Require(copied == firstUrl && publications.Count == 1, "Repeated copy changed the link or published again.");
            await copyWindow.StopAndCloseAsync();

            // Update the local document; the public snapshot remains unchanged until explicit revoke/create.
            var revised = notes with { Markdown = "# 변경된 결정\n\n월요일까지 수정합니다." }; JsonDisk.Write(library.NotesPath(recording.Id), revised); main.LoadDocuments(recording);
            Require((await Public(firstUrl)).Html.Contains("금요일까지"), "Local edits altered the public snapshot without publication.");
            await WithShare(main, async dialog =>
            {
                Click(dialog, "RevokeWebShareButton"); await dialog.CurrentOperation;
                Require(dialog.CurrentUrl is null && Button(dialog, "PublishWebShareButton").IsEnabled, "Revoke did not reset share controls.");
                Require((await Public(firstUrl)).Status == HttpStatusCode.NotFound, "Revoked URL is still public.");
                Click(dialog, "PublishWebShareButton"); await dialog.CurrentOperation; secondUrl = dialog.CurrentUrl!;
                Require(secondUrl != firstUrl && secondUrl is not null, "New publication reused an old URL.");
            });
            Require((await Public(secondUrl)).Html.Contains("월요일까지 수정합니다."), "New snapshot did not contain the current notes.");

            await ExpireAsync(root, recording.Id);
            Require((await Public(secondUrl)).Status == HttpStatusCode.NotFound, "Expired URL is still public.");
            await WithShare(main, async dialog =>
            {
                Require(dialog.CurrentUrl is null && Button(dialog, "PublishWebShareButton").IsEnabled, "Expired share remained active in WPF.");
                // Server commits, but its response is lost. Refresh must discover that exact publication.
                loseNextResponse = true; int before = publications.Count;
                Click(dialog, "PublishWebShareButton"); await dialog.CurrentOperation;
                Require(dialog.CurrentUrl is null && !Button(dialog, "PublishWebShareButton").IsEnabled, "An uncertain write allowed an immediate duplicate publication.");
                Click(dialog, "RefreshWebShareButton"); await dialog.CurrentOperation;
                Require(dialog.CurrentUrl is not null && publications.Count == before + 1, "Refresh did not recover the committed share.");
                Appearance.Apply(true); await SmokeUi.CaptureAsync(dialog, Path.Combine(output, "recovered-dark-share.png")); Appearance.Apply(false);
            });

            server.Offline = true;
            await WithShare(main, async dialog =>
            {
                Require(!Button(dialog, "PublishWebShareButton").IsEnabled && Button(dialog, "RefreshWebShareButton").IsEnabled, "Unknown status permitted publication.");
                server.Offline = false; Click(dialog, "RefreshWebShareButton"); await dialog.CurrentOperation;
                Require(dialog.CurrentUrl is not null, "Failed status could not be retried in the same window.");
            });

            server.Block();
            await WithShare(main, async dialog =>
            {
                await server.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(10));
                main.RequestExit(); await Until(() => !main.IsLoaded);
                Require(dialog.CurrentOperation.IsCompleted, "Exit left the sharing request active.");
            }, waitForStatus: false);
            server.Unblock();
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, Root = root, ActualWorkerHttpSqlite = true, WpfCreateReopenRestart = true,
                CopyUsesSameUrl = true, ExplicitSnapshotReplacement = true, RevokeAndExpiry = true, LostResponseRecovery = true, OfflineRefresh = true, ExitWaitsForCancellation = true,
                Scope = "Authored notes; no audio capture. Public HTML checked without credentials. Clipboard action uses a test sink. Local Worker/SQLite and filesystem R2 stand-in; expiry set in fixture SQLite." });
        }
        finally { server.Unblock(); await Close(main); server.Dispose(); }

        async Task<(HttpStatusCode Status, string Html)> Public(string url)
        {
            using var client = new HttpClient(server.Handler()); using var response = await client.GetAsync(url);
            return (response.StatusCode, await response.Content.ReadAsStringAsync());
        }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static Button Button(Window window, string name) => (Button)window.FindName(name);
    private static void Click(Window window, string name) => Button(window, name).RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
    private static async Task Until(Func<bool> condition) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20)); while (!condition()) await Task.Delay(25, timeout.Token); }
    private static async Task WithShare(MainWindow main, Func<WebShareWindow, Task> action, bool waitForStatus = true)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _ = main.Dispatcher.BeginInvoke(async () =>
        {
            WebShareWindow? dialog = null;
            try
            {
                await Until(() => main.OwnedWindows.OfType<WebShareWindow>().Any(w => w.IsLoaded)); dialog = main.OwnedWindows.OfType<WebShareWindow>().Single();
                if (waitForStatus) await dialog.CurrentOperation;
                await action(dialog); done.TrySetResult();
            }
            catch (Exception ex) { done.TrySetException(ex); }
            finally { if (dialog?.IsLoaded == true) await dialog.StopAndCloseAsync(); }
        }, DispatcherPriority.ContextIdle);
        Click(main, "ShareWebButton"); await done.Task.WaitAsync(TimeSpan.FromSeconds(40));
    }
    private static async Task Close(MainWindow window)
    {
        if (!window.IsLoaded) return;
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); window.Closed += (_, _) => closed.TrySetResult();
        window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
    private static async Task ExpireAsync(string root, Guid id)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("PYTHON") ?? "python") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardError = true };
        start.ArgumentList.Add("-c"); start.ArgumentList.Add("import json,sqlite3,sys;x=json.load(sys.stdin);c=sqlite3.connect(x['db']);c.execute('UPDATE web_shares SET expires_at = 1 WHERE source_id = ?', [x['id']]);c.commit()");
        using var process = Process.Start(start) ?? throw new IOException("Fixture expiry failed.");
        await process.StandardInput.WriteAsync(JsonSerializer.Serialize(new { db = Path.Combine(root, "server", "sync.sqlite"), id = id.ToString("D").ToUpperInvariant() })); process.StandardInput.Close();
        string error = await process.StandardError.ReadToEndAsync(); await process.WaitForExitAsync(); Require(process.ExitCode == 0, error);
    }
    private sealed class Observe(HttpMessageHandler inner, Func<HttpRequestMessage, Task> inspect, Func<HttpRequestMessage, bool> loseResponse) : DelegatingHandler(inner)
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            await inspect(request); var response = await base.SendAsync(request, token);
            if (loseResponse(request)) { response.Dispose(); throw new HttpRequestException("Synthetic response loss after server commit"); }
            return response;
        }
    }
}
