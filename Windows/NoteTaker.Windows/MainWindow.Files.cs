using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Shell;
using Microsoft.Win32;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private bool libraryDialogOpen;
    internal Task LastLibraryAction { get; private set; } = Task.CompletedTask;
    internal Func<Recording, string?>? AudioExportDestination { get; set; }
    internal Func<string?>? AudioImportSource { get; set; }
    internal Action<string>? RevealAudioLocation { get; set; }
    private WindowsAudioShare? audioShare;
    internal Func<global::Windows.ApplicationModel.DataTransfer.DataPackage, CancellationToken, Task>? AudioSharePresenter { get; set; }
    private async void ShareAudio_Click(object sender, RoutedEventArgs e) => await (LastLibraryAction = ShareAudioAsync());
    private async Task ShareAudioAsync()
    {
        if (!await StopSyncForForegroundAsync() || selected is not { DeletedAt: null } recording ||
            runningWork is not null || recorder is not null || transitioning || ModalOperationOpen) return;
        await RunWorkAsync(async token =>
        {
            try
            {
                SetStatus("공유할 오디오를 준비하는 중…");
                var data = await WindowsAudioShare.PrepareAsync(library, recording, token);
                token.ThrowIfCancellationRequested();
                SetStatus("Windows 공유 창을 기다리는 중…");
                if (AudioSharePresenter is not null) await AudioSharePresenter(data, token);
                else await (audioShare ??= new WindowsAudioShare(this)).ShowAsync(data, token);
                SetStatus("Windows에 공유할 오디오를 전달했습니다. 받을 앱을 선택해 주세요.");
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            { SetStatus("오디오 공유 요청을 취소했습니다."); }
            catch (System.Runtime.InteropServices.COMException ex)
            { throw new InvalidOperationException("Windows 오디오 공유를 준비하거나 열지 못했습니다. 다시 시도하거나 ‘오디오 내보내기’를 이용해 주세요.", ex); }
        });
    }
    private async void PermanentDelete_Click(object sender, RoutedEventArgs e) => await (LastLibraryAction = DeletePermanentlyAsync());
    private async Task DeletePermanentlyAsync()
    {
        if (!await StopSyncForForegroundAsync() || selected is not { DeletedAt: not null } recording ||
            runningWork is not null || recorder is not null || transitioning || ModalOperationOpen) return;
        var dialog = new PermanentDeleteWindow(recording.Title) { Owner = this };
        if (dialog.ShowDialog() != true || closePending || exitRequested) return;
        await RunWorkAsync(async _ =>
        {
            StopTurnPlayback(); waveformCancellation?.Cancel(); player.Dispose(); playbackLoaded = false;
            await WaveformLoadTask;
            SetStatus("녹음 파일을 삭제하는 중…");
            // Once confirmed, finish the local deletion even if the window is closing.
            try { await Task.Run(() => library.DeletePermanently(recording)); }
            finally { ReloadLibrary(); }
            SetStatus("이 기기에서 녹음 파일을 영구 삭제했습니다.");
        });
    }
    private async void ExportAudio_Click(object sender, RoutedEventArgs e) => await (LastLibraryAction = ExportAudioAsync());
    private async Task ExportAudioAsync()
    {
        if (!await StopSyncForForegroundAsync() || selected is not { } recording ||
            runningWork is not null || recorder is not null || transitioning || ModalOperationOpen) return;
        string? destination;
        libraryDialogOpen = true;
        try
        {
            UpdateControls();
            if (AudioExportDestination is not null) destination = AudioExportDestination(recording);
            else
            {
                var dialog = new SaveFileDialog { Title = "오디오 내보내기", Filter = "WAV 오디오 (*.wav)|*.wav", DefaultExt = ".wav", AddExtension = true, FileName = LibraryStore.AudioFileName(recording.Title) };
                destination = dialog.ShowDialog(this) == true ? dialog.FileName : null;
            }
        }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); return; }
        finally { libraryDialogOpen = false; UpdateControls(); }
        if (destination is null || closePending || exitRequested) return;
        await RunWorkAsync(async token =>
        {
            SetStatus("오디오를 내보내는 중…");
            await library.ExportAudioAsync(recording, destination, token);
            SetStatus("저장된 WAV 오디오를 내보냈습니다.");
        });
    }
}

internal sealed class PermanentDeleteWindow : Window
{
    internal Button ConfirmButton { get; } = new() { Content = "영구 삭제" };
    internal Button CancelButton { get; } = new() { Content = "취소", IsCancel = true, IsDefault = true };
    public PermanentDeleteWindow(string title)
    {
        Title = "녹음 영구 삭제"; Width = 460; Height = 280; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ShowInTaskbar = false;
        Style = (Style)FindResource(typeof(Window)); WindowStyle = WindowStyle.None;
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 44, ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(10), UseAeroCaptionButtons = false });
        var root = new Grid(); root.SetResourceReference(BackgroundProperty, "WindowSurface");
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(44) }); root.RowDefinitions.Add(new RowDefinition());
        var header = new Grid(); header.SetResourceReference(BackgroundProperty, "ToolbarSurface");
        var controls = new WindowControls { HorizontalAlignment = HorizontalAlignment.Left };
        WindowChrome.SetIsHitTestVisibleInChrome(controls, true); header.Children.Add(controls);
        header.Children.Add(new TextBlock { Text = Title, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold }); root.Children.Add(header);
        var body = new StackPanel { Margin = new Thickness(24) };
        body.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        var text = new TextBlock { Text = "이 기기의 오디오, 전사문과 회의록을 삭제합니다. 이 기기에서는 복원할 수 없습니다.\n\n동기화 서버와 다른 기기에 남아 있는 사본은 별도로 유지됩니다.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 18) };
        text.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); body.Children.Add(text);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        ConfirmButton.Margin = new Thickness(8, 0, 0, 0); ConfirmButton.SetResourceReference(ForegroundProperty, "RecordRed");
        ConfirmButton.Click += (_, _) => DialogResult = true;
        CancelButton.Click += (_, _) => DialogResult = false;
        buttons.Children.Add(CancelButton); buttons.Children.Add(ConfirmButton); body.Children.Add(buttons);
        Grid.SetRow(body, 1); root.Children.Add(body); Content = root; Loaded += (_, _) => CancelButton.Focus();
    }
}
