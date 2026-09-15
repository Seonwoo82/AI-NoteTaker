using System.Collections;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

/// <summary>Real profile UI and local worker, exclusively using file-backed public speech fixtures.</summary>
internal static class SmokeProfile
{
    public static async Task RunAsync(string output, string publicSpeech, string modelRoot)
    {
        Directory.CreateDirectory(output); Appearance.Apply(false);
        string root = Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        string enrollment = Path.Combine(root, "public-enrollment.wav"); File.WriteAllBytes(enrollment, Crop(publicSpeech, .4, 6.7, 10));
        string silence = Path.Combine(root, "silence.wav");
        using (var writer = new WaveFileWriter(silence, new WaveFormat(16000, 16, 1))) writer.Write(new byte[320000], 0, 320000);
        var captures = new List<FileCapture>();
        ProfileWindow Open(string sample) => new(root, modelRoot, "file-fixture", () => { var capture = new FileCapture(sample); captures.Add(capture); return capture; })
            { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        var store = new MeetingProfileStore(root); var window = Open(enrollment); window.Show();
        LocalVoiceProfile voice;
        try
        {
            ((TextBox)window.FindName("ProfileNameBox")).Text = "김민수";
            ((TextBox)window.FindName("ProfileAliasesBox")).Text = "민수, Minsoo";
            ((TextBox)window.FindName("ProfileRoleBox")).Text = "프로젝트 매니저";
            ((CheckBox)window.FindName("AutoAnalyzeBox")).IsChecked = true;
            ((IList)((DataGrid)window.FindName("GlossaryGrid")).ItemsSource).Add(new ProfileWindow.EditableTerm { Term = "AI-NoteTaker", SpokenAs = "에이아이 노트테이커", Meaning = "회의 기록 앱", Category = "project" });
            Click(window, "SaveProfileButton"); if (window.LastError is not null) throw window.LastError;
            if (store.Load().Terms.Count != 1 || !store.Load().AutomaticallyAnalyze) throw new InvalidOperationException("Profile UI did not persist terms and automatic analysis.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "profile-light.png"));
            ((TabControl)window.FindName("ProfileTabs")).SelectedIndex = 1;
            await Start(window); await SmokeUi.CaptureAsync(window, Path.Combine(output, "enrollment-light.png"));
            Click(window, "FinishEnrollmentButton"); await window.CurrentOperation;
            if (window.LastError is not null) throw window.LastError;
            voice = store.LoadVoice() ?? throw new InvalidOperationException("Voice was not enrolled.");
            string revision = store.VoiceRevision!;
            await Start(window); Click(window, "CancelEnrollmentButton"); await window.CurrentOperation;
            if (revision != store.VoiceRevision || captures.Any(c => !c.Stopped)) throw new InvalidOperationException("Cancellation lost profile or did not stop capture.");
            AssertClean(root);
            Appearance.Apply(true); window.Width = 600; window.Height = 650;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "voice-compact-dark.png"));
            ((ScrollViewer)window.FindName("VoiceScroll")).ScrollToEnd();
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "voice-compact-dark-bottom.png"));
            ((TabControl)window.FindName("ProfileTabs")).SelectedIndex = 0;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "profile-compact-dark.png"));
            // Deletion affects only the voice profile, not the name or terms.
            Click(window, "DeleteVoiceButton");
            if (store.LoadVoice() is not null || store.Load().DisplayName != "김민수") throw new InvalidOperationException("Voice deletion affected text profile.");
            store.SaveVoice(voice, null);
            await Start(window); await window.StopAndCloseAsync();
            if (captures.Any(c => !c.Stopped) || store.VoiceRevision is null) throw new InvalidOperationException("Closing enrollment did not preserve the profile.");
            AssertClean(root);
        }
        finally { await window.StopAndCloseAsync(); }
        string preserved = store.VoiceRevision!;
        var failed = Open(silence); failed.Show();
        try
        {
            await Start(failed); Click(failed, "FinishEnrollmentButton"); await failed.CurrentOperation;
            if (failed.LastError is null || preserved != store.VoiceRevision) throw new InvalidOperationException("Silence enrollment was accepted or replaced the previous voice.");
            AssertClean(root);
        }
        finally { await failed.StopAndCloseAsync(); }
        var client = new SpeakerWorkerClient(modelRoot);
        var timer = System.Diagnostics.Stopwatch.StartNew();
        var same = await client.EmbedLiveAsync(Crop(publicSpeech, 22.2, 25.2), default);
        double liveSeconds = timer.Elapsed.TotalSeconds;
        var other = await client.EmbedLiveAsync(Crop(publicSpeech, 7.1, 10.1), default);
        double sameScore = SpeakerWorkerClient.Cosine(voice.Embedding, same.Embedding), otherScore = SpeakerWorkerClient.Cosine(voice.Embedding, other.Embedding);
        if (OwnerVoicePolicy.Classify(same.ModelId, same.Embedding, voice) != OwnerSpeechState.Owner || OwnerVoicePolicy.Classify(other.ModelId, other.Embedding, voice) == OwnerSpeechState.Owner)
            throw new InvalidOperationException($"Held-out live voice check failed: same={sameScore:F4}, other={otherScore:F4}.");
        await AutomaticAnalysis(root, output, publicSpeech, modelRoot);
        JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, LiveSameSpeakerCosine = sameScore, LiveOtherSpeakerCosine = otherScore, LiveInferenceSeconds = liveSeconds,
            Scope = "Real WPF profile/enrollment/cancel/close/delete/failure plus Sherpa enrollment and stdin live inference. Real automatic Whisper/Sherpa analysis after file capture. Public Chinese speech only; no microphone or physical playback. No Korean meeting accuracy claim." });
    }
    private static async Task AutomaticAnalysis(string root, string output, string fixture, string modelRoot)
    {
        var library = new LibraryStore(root); new SettingsStore(root).Save(new() { SpeechLanguage = "zh", KeepRunningInTray = false });
        var recent = Recent(fixture, 22.2, 25.2);
        var capture = new FileCapture(fixture) { RecentWindow = recent };
        var window = new MainWindow(library, discoverDevices: false, aiModelRoot: modelRoot, enableDesktopIntegration: false, recordingFactory: () => capture)
            { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); window.Closed += (_, _) => closed.TrySetResult();
        window.Show();
        try
        {
            var mic = (ComboBox)window.FindName("MicrophoneBox"); mic.ItemsSource = new[] { new AudioDevice("fixture", "공개 음성 파일 입력") }; mic.SelectedIndex = 0;
            ((ComboBox)window.FindName("ModeBox")).SelectedIndex = 1;
            Click(window, "RecordButton");
            var label = (TextBlock)window.FindName("LiveOwnerLabel");
            await WaitUntil(() => label.Text == "최근 발화 · 나", TimeSpan.FromSeconds(20));
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "live-owner.png"));
            Click(window, "PauseButton"); if (label.Text != "목소리 확인 일시정지") throw new InvalidOperationException("Live display did not pause.");
            Click(window, "ResumeButton");
            capture.RecentWindow = Recent(fixture, 7.1, 10.1);
            await WaitUntil(() => label.Text == "최근 발화 · 다른 참여자", TimeSpan.FromSeconds(20));
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "live-other.png"));
            Click(window, "StopButton");
            await WaitUntil(() => !((FrameworkElement)window.FindName("RecordingPanel")).IsVisible, TimeSpan.FromSeconds(20));
            await window.CurrentWork;
            if (window.LastWorkError is not null) throw window.LastWorkError;
            var recording = library.Load().Single(); var meeting = new MeetingWorkspaceStore(library).Resolve(recording);
            if (meeting?.Transcript.Speakers.Any(s => s.IsOwner && s.Name == "김민수") != true) throw new InvalidOperationException("Automatic analysis did not identify the enrolled fixture speaker.");
            ((TabControl)window.FindName("DetailPanel")).SelectedIndex = 2;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "automatic-owner-analysis.png"));
            // A manual correction remains authoritative after removing automatic owner attribution.
            var store = new MeetingWorkspaceStore(library); var owner = meeting.Transcript.Speakers.First(s => s.IsOwner);
            store.Append(recording, "speakerName", owner.Id, "수동 이름"); store.Append(recording, "speakerOwner", owner.Id, "true");
            if (!await OwnerAttribution.ReapplyAsync(library, recording, new(), null, default)) throw new InvalidOperationException("Removing voice did not clear automatic owner attribution.");
            var resolved = store.Resolve(recording)!;
            if (!resolved.Transcript.Speakers.Any(s => s.IsOwner && s.Name == "수동 이름")) throw new InvalidOperationException("Reapplication erased manual corrections.");
        }
        finally { window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15)); }
    }
    private static async Task Start(ProfileWindow window)
    {
        Click(window, "StartEnrollmentButton"); await window.CurrentOperation; if (window.LastError is not null) throw window.LastError;
        await Task.Delay(150); // Permit the WPF clock to enable completion for the ten-second file fixture.
        if (!((Button)window.FindName("FinishEnrollmentButton")).IsEnabled) throw new InvalidOperationException("Enrollment did not reach the minimum duration.");
    }
    private static void AssertClean(string root)
    {
        if (Directory.Exists(Path.Combine(root, "VoiceWork")) && Directory.EnumerateFiles(Path.Combine(root, "VoiceWork"), "enroll-*.wav").Any())
            throw new InvalidOperationException("Temporary enrollment audio remains.");
    }
    private static void Click(Window window, string name) => ((Button)window.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static async Task WaitUntil(Func<bool> condition, TimeSpan timeout)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        while (!condition()) { if (watch.Elapsed > timeout) throw new TimeoutException("WPF profile/capture state did not settle."); await Task.Delay(100); }
    }
    private static RecentAudioWindow Recent(string source, double start, double end)
    {
        using var reader = new AudioFileReader(source);
        ISampleProvider samples = new AudioRangeSampleProvider(reader, [new(start, end)]);
        samples = new WdlResamplingSampleProvider(samples, AudioFiles.SampleRate);
        if (samples.WaveFormat.Channels == 1) samples = new MonoToStereoSampleProvider(samples);
        var provider = new SampleToWaveProvider16(samples); var pcm = new byte[3 * AudioFiles.SampleRate * 4]; int count = 0, read;
        while (count < pcm.Length && (read = provider.Read(pcm, count, pcm.Length - count)) > 0) count += read;
        return new(pcm, end, 0);
    }
    private static byte[] Crop(string source, double start, double end, int minimumSeconds = 0)
    {
        using var reader = new AudioFileReader(source); var range = new AudioRangeSampleProvider(reader, [new(start, end)]);
        using var stream = new MemoryStream();
        using (var writer = new WaveFileWriter(new NAudio.Utils.IgnoreDisposeStream(stream), range.WaveFormat))
        {
            var buffer = new float[16000]; int read, total = 0;
            while ((read = range.Read(buffer, 0, buffer.Length)) > 0) { writer.WriteSamples(buffer, 0, read); total += read; }
            int padding = Math.Max(0, minimumSeconds * range.WaveFormat.SampleRate * range.WaveFormat.Channels - total);
            if (padding > 0) writer.WriteSamples(new float[padding], 0, padding);
        }
        return stream.ToArray();
    }
    private sealed class FileCapture(string fixture) : IRecordingSession, IRecentAudioSource
    {
        public RecentAudioWindow? RecentWindow { get; set; }
        public RecentAudioWindow? RecentAudio() => IsPaused || Stopped ? null : RecentWindow;
        public bool Stopped { get; private set; }
        public string? Failure => null;
        public double DurationSeconds { get; private set; }
        public bool IsPaused { get; private set; }
        public float MicrophoneLevel => .12f;
        public float SystemLevel => 0;
        public Task StartAsync(string path, RecordingMode mode, string? microphoneId, string? outputId)
        { File.Copy(fixture, path); using var reader = new WaveFileReader(path); DurationSeconds = reader.TotalTime.TotalSeconds; return Task.CompletedTask; }
        public void TogglePause() => IsPaused = !IsPaused;
        public Task<double> StopAsync() { Stopped = true; return Task.FromResult(DurationSeconds); }
        public ValueTask DisposeAsync() { Stopped = true; return ValueTask.CompletedTask; }
    }
}
