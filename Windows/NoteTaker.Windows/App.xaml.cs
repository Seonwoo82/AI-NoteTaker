using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using NoteTaker.Core;
using NoteTaker.Windows.Components;
using Microsoft.Win32;

namespace NoteTaker.Windows;

public partial class App : Application
{
    private Mutex? instance;
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Appearance.ApplySystem();
        SystemEvents.UserPreferenceChanged += PreferencesChanged;
        SessionEnding += (_, _) => { if (MainWindow is NoteTaker.Windows.MainWindow window) window.RequestExit(); };
        try
        {
            if (e.Args.Length == 3 && e.Args[0] == "--smoke-meeting")
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                await SmokeMeetingAnalysis.RunAsync(Path.GetFullPath(e.Args[1]), Path.GetFullPath(e.Args[2]));
                Shutdown(0); return;
            }
            if (e.Args.Length == 4 && e.Args[0] == "--smoke-profile")
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                await SmokeProfile.RunAsync(Path.GetFullPath(e.Args[1]), Path.GetFullPath(e.Args[2]), Path.GetFullPath(e.Args[3]));
                Shutdown(0); return;
            }
            if (e.Args.Length == 4 && e.Args[0] == "--smoke-participants")
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                await SmokeParticipants.RunAsync(Path.GetFullPath(e.Args[1]), Path.GetFullPath(e.Args[2]), Path.GetFullPath(e.Args[3]));
                Shutdown(0); return;
            }
            if (e.Args.Length is 4 or 5 && e.Args[0] == "--smoke-ai")
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                await SmokeUi.RunAiAsync(Path.GetFullPath(e.Args[1]), Path.GetFullPath(e.Args[2]), Path.GetFullPath(e.Args[3]), e.Args.Length == 5 ? e.Args[4] : "whisper");
                Shutdown(0);
                return;
            }
            if (e.Args.Length == 2 && e.Args[0] == "--smoke-ui")
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                await SmokeUi.RunAsync(Path.GetFullPath(e.Args[1]));
                Shutdown(0);
                return;
            }
            if (e.Args.Length == 2 && e.Args[0] == "--smoke-desktop")
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                await SmokeDesktop.RunAsync(Path.GetFullPath(e.Args[1]));
                Shutdown(0); return;
            }
            if (e.Args.Length == 4 && e.Args[0] == "--smoke-capture-flow")
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                await SmokeDesktop.RunCaptureFlowAsync(Path.GetFullPath(e.Args[1]), Path.GetFullPath(e.Args[2]), Path.GetFullPath(e.Args[3]));
                Shutdown(0); return;
            }
            string? root = null;
            if (e.Args.Length == 2 && e.Args[0] == "--library-root") root = e.Args[1];
            var library = new LibraryStore(root);
            string rootHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(library.Root.ToUpperInvariant())))[..24];
            instance = new Mutex(true, "Local\\AI-NoteTaker-" + rootHash, out bool isNew);
            if (!isNew)
            {
                MessageBox.Show("이 라이브러리를 사용하는 AI-NoteTaker가 이미 실행 중입니다.", "AI-NoteTaker");
                Shutdown(); return;
            }
            var window = new MainWindow(library);
            MainWindow = window;
            window.Show();
        }
        catch (Exception ex)
        {
            if (e.Args.Length >= 2 && e.Args[0] is "--smoke-ui" or "--smoke-ai" or "--smoke-desktop" or "--smoke-capture-flow" or "--smoke-participants" or "--smoke-profile" or "--smoke-meeting")
            {
                Directory.CreateDirectory(e.Args[1]);
                File.WriteAllText(Path.Combine(e.Args[1], "error.txt"), ex.ToString());
            }
            else MessageBox.Show("앱을 시작할 수 없습니다. 저장 폴더 접근 권한과 설정 파일을 확인해 주세요.\n\n" + ex.Message, "AI-NoteTaker");
            Shutdown(1);
        }
    }
    private void PreferencesChanged(object sender, UserPreferenceChangedEventArgs e) => Dispatcher.BeginInvoke(Appearance.ApplySystem);
    protected override void OnExit(ExitEventArgs e) { SystemEvents.UserPreferenceChanged -= PreferencesChanged; LocalRuntime.StopOwned(); instance?.Dispose(); base.OnExit(e); }
}
