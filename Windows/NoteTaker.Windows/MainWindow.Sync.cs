using System.Net.Http;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Input;
using System.Windows.Controls;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private readonly AutomaticSyncSchedule syncSchedule = new();
    private readonly Func<SyncConfiguration, HttpMessageHandler>? syncHandlerFactory;
    private bool syncing, syncForegroundPending;
    private string syncMessage = "서버를 설정하면 다른 기기와 동기화할 수 있습니다.";
    private LibrarySyncStatus? syncStatus;
    internal LibrarySyncResult? LastSyncResult { get; private set; }
    internal bool IsSynchronizing => syncing;
    private bool SyncConfigured => !string.IsNullOrWhiteSpace(settings.SharingServerUrl) && !string.IsNullOrWhiteSpace(settings.ProtectedSharingSyncToken);
    private bool SyncBusy => !IsLoaded || syncing || closePending || exitRequested || syncForegroundPending || recorder is not null || transitioning || runningWork is not null || ModalOperationOpen ||
        player.IsPlaying || ComponentDispatcher.IsThreadModal || OwnedWindows.Cast<Window>().Any(w => w.IsVisible) || CapturePopup.IsOpen ||
        Mouse.LeftButton == MouseButtonState.Pressed || Keyboard.FocusedElement is MenuItem or System.Windows.Controls.ContextMenu;

    private void ReadSyncStatus()
    {
        syncStatus = null;
        try
        {
            if (SyncConfigured)
            {
                var configuration = new SyncConfiguration(settings.SharingServerUrl, SettingsStore.ReadSharingToken(settings));
                syncStatus = LibrarySyncEngine.ReadStatus(library.Root, configuration.Endpoint);
                syncMessage = syncStatus.Pending > 0 ? $"다시 확인할 항목 {syncStatus.Pending}개" : settings.AutomaticSyncEnabled ? "자동 동기화 대기 중" : "필요할 때 지금 동기화를 눌러 주세요.";
            }
            else syncMessage = "서버 주소와 토큰을 설정해 주세요.";
        }
        catch (Exception) { syncMessage = "동기화 설정 또는 저장된 상태를 읽지 못했습니다. 설정과 저장 폴더를 확인해 주세요."; }
        UpdateSyncControls();
    }
    private void UpdateSyncControls()
    {
        if (!loaded) return;
        SyncStatusText.Text = syncMessage;
        SyncModeText.Text = settings.AutomaticSyncEnabled ? "자동 동기화 켜짐 · 작업이 끝나면 실행" : "자동 동기화 꺼짐";
        SyncServerText.Text = string.IsNullOrWhiteSpace(settings.SharingServerUrl) ? "서버 미설정" : settings.SharingServerUrl;
        SyncLastText.Text = syncStatus?.LastCompletedAt is { } date ? $"마지막 완료 · {date.LocalDateTime:MM월 dd일 HH:mm:ss}" : "아직 완료된 동기화가 없습니다.";
        SyncPendingText.Text = syncStatus is null ? "대기 항목 · 아직 확인하지 않음" : $"저장된 대기 항목 · {syncStatus.Pending}개";
        SyncIssuesText.Text = string.Join("\n", (LastSyncResult?.Issues ?? syncStatus?.Issues ?? []).Select(i => i.Message).Distinct().Take(8));
        SyncIssuesText.Visibility = string.IsNullOrEmpty(SyncIssuesText.Text) ? Visibility.Collapsed : Visibility.Visible;
        SyncKeyText.Text = syncStatus?.OtherDevicesHaveApiKey == true && settings.ProtectedApiKey is null
            ? "다른 기기에 클라우드 AI 키가 있습니다. 이 PC에서 클라우드 AI를 사용하려면 키를 별도로 입력하세요."
            : "API 키·동기화 토큰·목소리 프로필은 기기 사이에 전송하지 않습니다.";
        SyncNowButton.IsEnabled = SyncConfigured && !SyncBusy;
        CancelSyncButton.Visibility = syncing ? Visibility.Visible : Visibility.Collapsed;
        SyncSettingsButton.IsEnabled = !closePending && !exitRequested && recorder is null && !transitioning && (runningWork is null || syncing) && !ModalOperationOpen;
        SyncIndicator.Text = syncing ? "동기화 중…" : syncStatus?.Pending > 0 || LastSyncResult?.Issues.Count > 0 ? "동기화 확인" : "동기화";
    }
    private void Sync_Click(object sender, RoutedEventArgs e) { UpdateSyncControls(); SyncPopup.IsOpen = !SyncPopup.IsOpen; }
    private async void SyncNow_Click(object sender, RoutedEventArgs e) => await SynchronizeAsync(true);
    private void CancelSync_Click(object sender, RoutedEventArgs e) { if (syncing) { workCancellation?.Cancel(); syncMessage = "전송을 중단하는 중…"; UpdateSyncControls(); } }
    private void SyncSettings_Click(object sender, RoutedEventArgs e) { SyncPopup.IsOpen = false; OpenSettings(true); }
    private void TickAutomaticSync()
    {
        if (syncSchedule.IsDue(settings.AutomaticSyncEnabled && SyncConfigured, SyncBusy)) _ = SynchronizeAsync(false);
    }
    internal void RequestAutomaticSync() => syncSchedule.Reset();
    internal async Task SynchronizeAsync(bool manual)
    {
        if (SyncBusy || !SyncConfigured) return;
        if (manual) syncSchedule.Reset();
        bool success = false, cancelled = false;
        syncing = true; LastSyncResult = null; syncMessage = "동기화를 준비하는 중…";
        try
        {
            await RunWorkAsync(async token =>
            {
                Guid? selection = selected?.Id; int? version = selected?.AudioVersion; double position = PlaybackSlider.Position;
                StopTurnPlayback(); player.Dispose(); playbackLoaded = false;
                waveformCancellation?.Cancel(); await WaveformLoadTask;
                try
                {
                    var configuration = new SyncConfiguration(settings.SharingServerUrl, SettingsStore.ReadSharingToken(settings));
                    var progress = new Progress<string>(message => { if (syncing && LastSyncResult is null && !token.IsCancellationRequested) { syncMessage = message; UpdateSyncControls(); } });
                    // Hashing, conversion, JSON merge and recovery must not run on the WPF dispatcher.
                    LastSyncResult = await Task.Run(async () =>
                    {
                        using var engine = new LibrarySyncEngine(library, configuration, syncHandlerFactory?.Invoke(configuration));
                        return await engine.RunAsync(progress, token, force: manual);
                    }, token);
                    success = LastSyncResult.Issues.Count == 0 && LastSyncResult.Pending == 0;
                    syncMessage = success ? $"동기화 완료 · 보냄 {LastSyncResult.Uploaded} · 받음 {LastSyncResult.Downloaded}"
                        : $"동기화 확인 필요 · 대기 {LastSyncResult.Pending} · 오류 {LastSyncResult.Issues.Count}";
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { cancelled = true; syncMessage = "동기화를 중단했습니다. 남은 항목은 다음에 다시 확인합니다."; }
                catch (Exception)
                {
                    syncMessage = "동기화를 완료하지 못했습니다. 서버 설정과 저장 폴더를 확인해 주세요.";
                    throw;
                }
                finally
                {
                    // A cancelled run may already have committed part of the library. Re-read before allowing edits.
                    settings = settingsStore.Load(); folderStore.Reload();
                    selected = null; ReloadLibrary(selection);
                    if (selected?.Id == selection && selected?.AudioVersion == version) PlaybackSlider.Position = position;
                    if (SyncConfigured)
                    {
                        var configuration = new SyncConfiguration(settings.SharingServerUrl, SettingsStore.ReadSharingToken(settings));
                        syncStatus = await Task.Run(() => LibrarySyncEngine.ReadStatus(library.Root, configuration.Endpoint));
                    }
                }
            });
        }
        finally { syncing = false; syncSchedule.Finished(success, cancelled); UpdateControls(); }
    }
    private async Task<bool> StopSyncForForegroundAsync()
    {
        if (syncForegroundPending || closePending || exitRequested) return false;
        if (syncing)
        {
            syncForegroundPending = true;
            try { workCancellation?.Cancel(); await CurrentWork; }
            finally { syncForegroundPending = false; }
        }
        return !closePending && !exitRequested;
    }
}
