using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using NAudio.Wave;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static class SmokeSync
{
    private const string Host = "https://sync.fixture";
    private const string Token = "synthetic-windows-sync-token";
    public static async Task RunAsync(string output)
    {
        Directory.CreateDirectory(output); Appearance.Apply(false);
        string root = Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        using var server = await FixtureServer.StartAsync(root);
        var a = new LibraryStore(Path.Combine(root, "a")); var b = new LibraryStore(Path.Combine(root, "b"));
        var config = new AppSettings { SharingServerUrl = Host, ProtectedSharingSyncToken = SettingsStore.ProtectKey(Token), KeepRunningInTray = false };
        new SettingsStore(a.Root).Save(config with { ProtectedApiKey = SettingsStore.ProtectKey("synthetic-private-key"), SummaryModel = "fixture/summary" });
        new SettingsStore(b.Root).Save(config);
        var recording = new Recording { Title = "Windows 기기 간 회의", Mode = RecordingMode.Imported, DurationSeconds = 1 };
        Wave(a.AudioPath(recording.Id)); a.Save(recording);
        string hash = await MeetingNotesService.AudioHashAsync(a.AudioPath(recording.Id), default);
        var cache = new TranscriptCache(hash, "fixture/stt", "ko", ["금요일까지 초안을 정리합니다."], true); JsonDisk.Write(a.TranscriptPath(recording.Id), cache);
        JsonDisk.Write(a.NotesPath(recording.Id), new MeetingNotes("# 회의록\n\n금요일까지 초안을 정리합니다.", DateTimeOffset.UtcNow, "fixture/summary", 0)
            { TranscriptHash = MeetingNotesService.TranscriptContentHash(cache), Original = new(1, hash, cache.Chunks[0], cache.Model) });
        new MeetingProfileStore(a.Root).Save(new MeetingProfile { DisplayName = "민수", Role = "개발" }, null);
        var capture = new SyntheticCapture();
        MainWindow Make(LibraryStore library) => new(library, discoverDevices: false, enableDesktopIntegration: false, recordingFactory: () => capture, syncHandlerFactory: _ => server.Handler())
            { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        var first = Make(a); var second = Make(b);
        void Diagnose(object? sender, System.Runtime.ExceptionServices.FirstChanceExceptionEventArgs args)
        {
            if (args.Exception is IOException or InvalidOperationException) File.AppendAllText(Path.Combine(output, "diagnostics.txt"), args.Exception + "\n");
        }
        AppDomain.CurrentDomain.FirstChanceException += Diagnose;
        int completionRequests = 0; bool completionRequestStarted = false;
        void RequestDuringCompletion(object sender, DependencyPropertyChangedEventArgs args)
        {
            if (args.NewValue is true && second.IsSynchronizing && second.CurrentWork.IsCompleted)
            {
                completionRequests++;
                var attempt = second.SynchronizeAsync(false);
                completionRequestStarted |= !attempt.IsCompleted;
                JsonDisk.Write(Path.Combine(output, "completion-reentry.json"), new { Requests = completionRequests, Started = completionRequestStarted });
            }
        }
        ((Button)second.FindName("RenameButton")).IsEnabledChanged += RequestDuringCompletion;
        try
        {
            first.Show(); second.Show(); await Task.Delay(300);
            Require(server.Requests == 0, "Sharing settings alone enabled automatic upload.");
            first.CreateNamedFolder("출시 준비");
            await Manual(first); await Manual(second);
            Require(completionRequests > 0 && !completionRequestStarted, $"Completion reentry requests={completionRequests}, started={completionRequestStarted}.");
            ((Button)second.FindName("RenameButton")).IsEnabledChanged -= RequestDuringCompletion;
            Require(b.Load().Single().Id == recording.Id && JsonDisk.Read<MeetingNotes>(b.NotesPath(recording.Id))?.Original?.Transcript == cache.Chunks[0], "WPF sync did not load notes/original.");
            Require(new MeetingProfileStore(b.Root).Load().DisplayName == "민수", "Profile did not arrive.");
            Require(new SettingsStore(b.Root).Load().SummaryModel == "fixture/summary", "Shared settings did not arrive.");
            Require(((TreeView)second.FindName("FolderTree")).Items.Count == 1 && ((ListBox)second.FindName("RecordingList")).Items.Count == 1, "WPF library/folders were not refreshed.");
            Require(Text(second, "SyncKeyText").Contains("다른 기기"), "Missing other-device key notice.");
            Click(second, "SyncButton"); await CapturePopup(second, output, "sync-complete.png");
            Appearance.Apply(true); await CapturePopup(second, output, "sync-dark.png"); Appearance.Apply(false);
            ((Popup)second.FindName("SyncPopup")).IsOpen = false;
            second.Width = 840; second.Height = 600; await SmokeUi.CaptureAsync(second, Path.Combine(output, "compact-library.png"));

            await Settings(second, async dialog =>
            {
                dialog.ShowSyncSettings(); Click(dialog, "TestSyncButton"); await dialog.LastConnectionTest;
                Require(Text(dialog, "SyncConnectionStatus").Contains("완료"), "Real Worker health test failed.");
                await SmokeUi.CaptureAsync(dialog, Path.Combine(output, "sync-settings.png"));
                // A path cannot accidentally point the API at a different application.
                ((TextBox)dialog.FindName("SharingUrlBox")).Text = Host + "/invalid-path";
                Click(dialog, "SaveSettingsButton"); Require(dialog.IsVisible && Text(dialog, "ErrorText").Contains("호스트"), "Invalid sync origin was saved.");
                ((TextBox)dialog.FindName("SharingUrlBox")).Text = Host;
                ((CheckBox)dialog.FindName("AutomaticSyncBox")).IsChecked = true;
                Click(dialog, "SaveSettingsButton");
            });
            await second.CurrentWork; await Until(() => !second.IsSynchronizing);
            int beforeModal = server.Requests;
            var modal = new RenameWindow("동기화 대기 확인") { Owner = second };
            Exception? modalError = null;
            modal.Loaded += async (_, _) => { try { second.RequestAutomaticSync(); await Task.Delay(350); Require(server.Requests == beforeModal, "Automatic sync started inside a modal editor."); } catch (Exception ex) { modalError = ex; } finally { modal.Close(); } };
            modal.ShowDialog(); if (modalError is not null) throw modalError;
            await Until(() => server.Requests > beforeModal); await Until(() => !second.IsSynchronizing);
            Require(second.LastSyncResult is { Pending: 0, Issues.Count: 0 }, "Automatic sync failed: " +
                JsonSerializer.Serialize(second.LastSyncResult, JsonDisk.Options) + " " + second.LastWorkError + " " + Text(second, "SyncStatusText"));

            // A failed network attempt leaves the local edit durable, and a restarted app resumes it.
            Click(second, "FavoriteButton"); server.Offline = true; await StartManual(second);
            Require(second.LastSyncResult is { Pending: > 0 } && second.LastSyncResult.Issues.Count > 0, "Offline retry was not retained.");
            Click(second, "SyncButton"); await CapturePopup(second, output, "sync-offline.png"); ((Popup)second.FindName("SyncPopup")).IsOpen = false;
            await Close(second); server.Offline = false;
            // Temporarily disable auto in this fixture to prove the explicit restart/manual path.
            var stored = new SettingsStore(b.Root); stored.Save(stored.Load() with { AutomaticSyncEnabled = false });
            second = Make(b); second.Show(); Require(Text(second, "SyncPendingText").Contains("1개"), "Restart lost durable pending status.");
            await Manual(second); await Manual(first); Require(a.Load().Single().IsFavorite, "Retry did not send the retained edit.");

            // A paused reader holds audio.wav open; sync must release it before replacing a newer version.
            ((Button)second.FindName("ForwardButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            File.Move(a.NotesPath(recording.Id), Path.Combine(a.DirectoryFor(recording.Id), "previous-notes.json"));
            File.Move(a.TranscriptPath(recording.Id), Path.Combine(a.DirectoryFor(recording.Id), "previous-transcript.json"));
            Wave(a.AudioPath(recording.Id), 2); a.Save(a.Load().Single() with { AudioVersion = 2, DurationSeconds = 2 });
            await Manual(first); await Manual(second);
            Require(b.Load().Single().AudioVersion == 2 && ((WaveformControl)second.FindName("PlaybackSlider")).Duration == 2, "Audio reader/version refresh failed.");

            server.Block(); Click(second, "SyncButton"); Click(second, "SyncNowButton"); await server.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(10));
            await Settings(second, dialog =>
            {
                Require(!second.IsSynchronizing, "Settings opened before sync stopped."); server.Unblock();
                ((ComboBox)dialog.FindName("LanguageBox")).SelectedIndex = 1;
                Click(dialog, "SaveSettingsButton"); return Task.CompletedTask;
            });
            Require(new SettingsStore(b.Root).Load().Language == "en", "Settings edit after cancellation was overwritten.");

            // A new recording request cancels and awaits sync before opening the input session.
            server.Block(); Click(second, "SyncButton"); Click(second, "SyncNowButton"); await server.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Require(((Button)second.FindName("RecordButton")).IsEnabled && !((Button)second.FindName("RenameButton")).IsEnabled, "Sync operation controls were not exclusive.");
            var mic = (ComboBox)second.FindName("MicrophoneBox"); mic.ItemsSource = new[] { new AudioDevice("fixture", "합성 파일 입력") }; mic.SelectedIndex = 0;
            ((ComboBox)second.FindName("ModeBox")).SelectedIndex = 1;
            Click(second, "RecordButton"); await Until(() => capture.Started);
            Require(!second.IsSynchronizing, "Capture began before sync had stopped."); server.Unblock();
            int duringCapture = server.Requests; await second.SynchronizeAsync(true); Require(server.Requests == duringCapture, "Sync ran during capture.");
            Click(second, "StopButton"); await second.LastStopButtonWork; Require(capture.Stopped, "Synthetic capture did not finalize.");

            // Closing explicitly while a request is pending waits for cancellation and leaves no owned task.
            server.Block(); Click(second, "SyncButton"); Click(second, "SyncNowButton"); await server.Blocked.Task.WaitAsync(TimeSpan.FromSeconds(10));
            await Close(second); Require(!second.IsSynchronizing && second.CurrentWork.IsCompleted, "Exit retained sync work."); server.Unblock();
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, Root = root, ActualWorkerHttpSqlite = true, IndependentWpfLibraries = true,
                OptInOnly = true, ManualAndAutomatic = true, ModalDeferral = true, CompletionReentrancyBlocked = completionRequests > 0 && !completionRequestStarted,
                OfflineRestartRetry = true, ConnectionTest = true, AudioVersionRefresh = true,
                CaptureWaitsForCancellation = true, SettingsWaitForCancellation = true, ExitWaitsForCancellation = true, MicrophoneCapture = false,
                Scope = "Real WPF actions, actual Worker with SQLite and filesystem object-store stand-in. Authored transcript and synthetic WAV. No real Apple device or deployed Cloudflare proof." });
        }
        finally { AppDomain.CurrentDomain.FirstChanceException -= Diagnose; server.Unblock(); await Close(first); await Close(second); }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static string Text(Window window, string name) => ((TextBlock)window.FindName(name)).Text;
    private static void Click(Window window, string name) => ((Button)window.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static async Task Until(Func<bool> predicate) { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20)); while (!predicate()) await Task.Delay(25, timeout.Token); }
    private static async Task StartManual(MainWindow window)
    {
        ((Popup)window.FindName("SyncPopup")).IsOpen = false; Click(window, "SyncButton"); Click(window, "SyncNowButton");
        await window.CurrentWork.WaitAsync(TimeSpan.FromSeconds(30)); await Until(() => !window.IsSynchronizing);
        ((Popup)window.FindName("SyncPopup")).IsOpen = false;
    }
    private static async Task Manual(MainWindow window)
    {
        await StartManual(window);
        Require(window.LastWorkError is null && window.LastSyncResult is { Pending: 0 } result && result.Issues.Count == 0, "WPF sync failed: " + Text(window, "SyncStatusText") + " " + window.LastWorkError);
    }
    private static async Task Settings(MainWindow owner, Func<SettingsWindow, Task> action)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _ = owner.Dispatcher.BeginInvoke(async () =>
        {
            SettingsWindow? dialog = null;
            try { await Until(() => owner.OwnedWindows.OfType<SettingsWindow>().Any()); dialog = owner.OwnedWindows.OfType<SettingsWindow>().Single(); await action(dialog); done.SetResult(); }
            catch (Exception ex) { done.SetException(ex); }
            finally { if (dialog?.IsVisible == true) dialog.Close(); }
        }, DispatcherPriority.ContextIdle);
        Click(owner, "SettingsButton"); await done.Task.WaitAsync(TimeSpan.FromSeconds(30));
    }
    private static async Task CapturePopup(MainWindow owner, string output, string name)
    {
        await owner.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        var popup = (Popup)owner.FindName("SyncPopup"); var content = (FrameworkElement)popup.Child; content.UpdateLayout();
        SmokeUi.SaveImage(content, Path.Combine(output, name));
    }
    private static async Task Close(MainWindow window)
    {
        if (!window.IsLoaded) return;
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); window.Closed += (_, _) => closed.TrySetResult();
        window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
    private static void Wave(string path, int seconds = 1)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var writer = new WaveFileWriter(path, new WaveFormat(16000, 16, 1)); writer.Write(new byte[32000 * seconds]);
    }
    private sealed class SyntheticCapture : IRecordingSession
    {
        public bool Started { get; private set; }
        public bool Stopped { get; private set; }
        public string? Failure => null;
        public double DurationSeconds => 1;
        public bool IsPaused { get; private set; }
        public float MicrophoneLevel => 0;
        public float SystemLevel => 0;
        public Task StartAsync(string path, RecordingMode mode, string? microphoneId, string? outputId) { Wave(path); Started = true; return Task.CompletedTask; }
        public void TogglePause() => IsPaused = !IsPaused;
        public Task<double> StopAsync() { Stopped = true; return Task.FromResult(1d); }
        public ValueTask DisposeAsync() { Stopped = true; return ValueTask.CompletedTask; }
    }
    internal sealed class FixtureServer(Process process, int port) : IDisposable
    {
        public bool Offline;
        private bool blocking;
        public int Requests;
        public TaskCompletionSource Blocked { get; private set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Block() { Blocked = new(TaskCreationOptions.RunContinuationsAsynchronously); blocking = true; }
        public void Unblock() => blocking = false;
        public static async Task<FixtureServer> StartAsync(string root)
        {
            string? repository = AppContext.BaseDirectory;
            while (repository is not null && !File.Exists(Path.Combine(repository, "Cloudflare", "worker.mjs"))) repository = Path.GetDirectoryName(repository);
            if (repository is null) throw new InvalidOperationException("Run this smoke in the repository with Node and Python installed.");
            var start = new ProcessStartInfo("node") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add(Path.Combine(repository, "Cloudflare", "tests", "local-sync-server.mjs")); start.ArgumentList.Add(Path.Combine(root, "server"));
            start.Environment["PYTHON"] = Environment.GetEnvironmentVariable("PYTHON") ?? "python";
            var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start local Worker.");
            try
            {
                string? line = await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(20));
                if (line is null) throw new InvalidOperationException(await process.StandardError.ReadToEndAsync());
                using var json = JsonDocument.Parse(line); return new(process, json.RootElement.GetProperty("port").GetInt32());
            }
            catch { if (!process.HasExited) process.Kill(true); process.Dispose(); throw; }
        }
        public HttpMessageHandler Handler() => new Bridge(this, port);
        private sealed class Bridge(FixtureServer server, int port) : DelegatingHandler(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseProxy = false })
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Require(request.RequestUri!.Host == "sync.fixture", "Unexpected fixture host."); Interlocked.Increment(ref server.Requests);
                if (server.Offline) throw new HttpRequestException("Synthetic offline condition");
                if (server.blocking) { server.Blocked.TrySetResult(); await Task.Delay(Timeout.Infinite, token); }
                request.RequestUri = new Uri($"http://127.0.0.1:{port}" + request.RequestUri.PathAndQuery);
                return await base.SendAsync(request, token);
            }
        }
        public void Dispose() { if (!process.HasExited) { process.Kill(true); process.WaitForExit(); } process.Dispose(); }
    }
}
