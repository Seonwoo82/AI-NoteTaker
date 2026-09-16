using System.IO;
using System.Reflection;
using System.Runtime.Loader;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using NAudio.Wave;
using NoteTaker.Core;
using NoteTaker.Windows;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        string package = Path.GetFullPath(args[0]), output = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(output);
        AssemblyLoadContext.Default.Resolving += (_, name) => {
            string path = Path.Combine(package, name.Name + ".dll");
            return File.Exists(path) ? AssemblyLoadContext.Default.LoadFromAssemblyPath(path) : null;
        };
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += async (_, _) => {
            try { await CheckAsync(app, output); app.Shutdown(0); }
            catch(Exception ex) { File.WriteAllText(Path.Combine(output, "error.txt"), ex.ToString()); app.Shutdown(1); }
        };
        app.Run();
    }

    static async Task CheckAsync(Application app, string output)
    {
        var assembly = typeof(MainWindow).Assembly;
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/AI-NoteTaker;component/Components/AppleTheme.xaml", UriKind.Relative) });
        assembly.GetType("NoteTaker.Windows.Components.Appearance")!.GetMethod("Apply")!.Invoke(null, [false]);
        foreach (string scenario in new[] { "stop-empty-retry", "exit-empty" })
        {
            var library = new LibraryStore(Path.Combine(output, scenario));
            new SettingsStore(library.Root).Save(new AppSettings { AutoGenerate = true, KeepRunningInTray = false,
                EnableGlobalShortcuts = false, AutomaticSyncEnabled = false, TranscriptionProvider = "openrouter", SummaryProvider = "openrouter" });
            var empty = new FileSession(empty: true);
            var valid = new FileSession(empty: false);
            var sessions = new Queue<FileSession>([empty, valid]);
            MainWindow Open() => new(library, discoverDevices: false, enableDesktopIntegration: false, recordingFactory: () => sessions.Dequeue())
                { ShowInTaskbar = false, Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual };
            var window = Open();
            window.Show();
            Configure(window);
            Click(window, "RecordButton");
            Require(empty.Started && Button(window, "StopButton").IsEnabled, "Empty session did not start.");
            string audioPath = empty.Path!;
            string originalHash = Hash(audioPath);
            Guid emptyId = Guid.Parse(Path.GetFileName(Path.GetDirectoryName(audioPath))!);
            string metadataPath = Path.Combine(library.DirectoryFor(emptyId), "meta.json");
            if (scenario == "exit-empty") await CloseAsync(window);
            else
            {
                Click(window, "StopButton");
                await ((Task)Internal(window, "LastStopButtonWork")!).WaitAsync(TimeSpan.FromSeconds(15));
                string status = ((TextBlock)window.FindName("StatusText")).Text;
                Require(status.Contains("녹음된 오디오가 없습니다") && !status.Contains("저장했습니다"), "Empty stop was not reported as an error: " + status);
                Require(Button(window, "RecordButton").IsEnabled && !Button(window, "StopButton").IsEnabled, "Empty stop did not restore recording controls.");
                Require(JsonDisk.Read<Recording>(metadataPath)?.IsRecording == true, "Empty capture was committed as successful before recovery.");
                Require(Internal(window, "LastWorkError") is null, "Automatic AI was attempted after empty recording.");
                Click(window, "RecordButton");
                Require(valid.Started && Button(window, "StopButton").IsEnabled, "A new recording could not start after empty failure.");
                await CloseAsync(window); // Finalizes the valid retry; exit suppresses automatic AI.
            }
            Require(empty.Stopped && empty.Disposed, "Empty capture session was not stopped/disposed.");
            Require(Hash(audioPath) == originalHash, "Empty recording bytes changed during completion.");
            Require(!File.Exists(library.TranscriptPath(emptyId)) && !File.Exists(library.NotesPath(emptyId)), "Empty recording generated AI output.");
            var restored = Open();
            restored.Show();
            try
            {
                var records = library.Load();
                var recovered = records.Single(r => r.Id == emptyId);
                Require(!recovered.IsRecording && recovered.DurationSeconds == 0 && recovered.Warning?.Contains("복구하지 못했습니다") == true, "WPF restart misreported empty recovery.");
                Require(Hash(audioPath) == originalHash, "Empty recording bytes changed during recovery.");
                if (scenario == "stop-empty-retry")
                    Require(records.Count == 2 && records.Single(r=>r.Id!=emptyId).DurationSeconds == 1 && valid.Disposed, "Retry was not completed with actual PCM duration.");
                JsonDisk.Write(Path.Combine(output, scenario + ".json"), new { Passed = true, Scenario = scenario, Recording = recovered,
                    AudioHash = originalHash, Scope = "Real packaged WPF assemblies and record/stop/close/reopen handlers. File-backed capture reports 37 seconds but writes zero PCM frames. No microphone or network AI." });
            }
            finally { await CloseAsync(restored); }
        }
        JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, AppAssembly = assembly.Location, CoreAssembly = typeof(LibraryStore).Assembly.Location,
            AppAssemblySha256 = Hash(assembly.Location), CoreAssemblySha256 = Hash(typeof(LibraryStore).Assembly.Location), Scenarios = new[] { "stop-empty-retry", "exit-empty" } });
    }
    static Button Button(MainWindow window, string name) => (Button)window.FindName(name);
    static void Click(MainWindow window, string name) => Button(window, name).RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
    static object? Internal(MainWindow window, string name) => typeof(MainWindow).GetProperty(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window);
    static void Configure(MainWindow window)
    {
        var mic = (ComboBox)window.FindName("MicrophoneBox"); mic.ItemsSource = new[] { new AudioDevice("fixture", "생성 파일 입력") }; mic.SelectedIndex = 0;
        ((ComboBox)window.FindName("ModeBox")).SelectedIndex = 1;
    }
    static async Task CloseAsync(MainWindow window)
    {
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        window.Closed += (_, _) => closed.TrySetResult();
        window.Close(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
    static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
    static void Require(bool condition, string message) { if(!condition) throw new InvalidOperationException(message); }

    sealed class FileSession(bool empty) : IRecordingSession
    {
        public bool Started { get; private set; }
        public bool Stopped { get; private set; }
        public bool Disposed { get; private set; }
        public string? Path { get; private set; }
        public string? Failure => null;
        public double DurationSeconds => 37;
        public bool IsPaused => false;
        public float MicrophoneLevel => 0;
        public float SystemLevel => 0;
        public Task StartAsync(string path, RecordingMode mode, string? microphoneId, string? outputId)
        {
            using var writer = new WaveFileWriter(path, AudioFiles.RecordingFormat);
            if(!empty) writer.Write(new byte[AudioFiles.RecordingFormat.AverageBytesPerSecond]);
            Path = path; Started = true; return Task.CompletedTask;
        }
        public void TogglePause() { }
        public Task<double> StopAsync() { Stopped = true; return Task.FromResult(DurationSeconds); }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
}
