using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private ProfileWindow? profileWindow;
    private bool ModalOperationOpen => profileWindow is not null || notesEditingWindow is not null || OwnedWindows.Cast<Window>().Any(w => w.IsVisible);
    private LiveOwnerMonitor? liveOwner;
    private void StartLiveOwner()
    {
        try
        {
            var voice = new MeetingProfileStore(library.Root).LoadVoice();
            liveOwner = voice is null || recorder is not IRecentAudioSource ? null : new LiveOwnerMonitor(aiModelRoot, voice);
            LiveOwnerLabel.Text = voice is null ? "목소리 미등록 · 프로필에서 등록할 수 있습니다" : "최근 발화를 확인하는 중…";
        }
        catch (Exception) { liveOwner = null; LiveOwnerLabel.Text = "목소리 프로필을 다시 등록해 주세요"; }
    }
    private void UpdateLiveOwner()
    {
        if (liveOwner is null || recorder is not IRecentAudioSource source) return;
        if (recorder.IsPaused) { LiveOwnerLabel.Text = "목소리 확인 일시정지"; return; }
        liveOwner.Poll(source.RecentAudio);
        LiveOwnerLabel.Text = liveOwner.State switch
        {
            OwnerSpeechState.Owner => "최근 발화 · 나", OwnerSpeechState.Other => "최근 발화 · 다른 참여자",
            OwnerSpeechState.Silence => "말소리를 기다리는 중", OwnerSpeechState.Uncertain => "최근 발화 · 확인 어려움",
            _ => "최근 발화를 확인하는 중…"
        };
        LiveOwnerLabel.ToolTip = liveOwner.LastError ?? "최근 3초의 소리로 판단합니다. 여러 목소리가 섞이면 구분하지 않을 수 있습니다.";
    }
    private async Task StopLiveOwnerAsync()
    {
        if (liveOwner is { } monitor) { liveOwner = null; await monitor.DisposeAsync(); }
    }
    private async void Profile_Click(object sender, RoutedEventArgs e)
    {
        if (recorder is not null || runningWork is not null || transitioning || ModalOperationOpen) return;
        try
        {
            StopTurnPlayback(); player.Dispose(); playbackLoaded = false;
            var dialog = new ProfileWindow(library.Root, aiModelRoot, (MicrophoneBox.SelectedItem as AudioDevice)?.Id) { Owner = this };
            profileWindow = dialog; UpdateControls(); dialog.ShowDialog();
            profileWindow = null; UpdateControls();
            if (!dialog.Changed || closePending) return;
            await RunWorkAsync(async token =>
            {
                var store = new MeetingProfileStore(library.Root); var profile = store.Load();
                LocalVoiceProfile? voice = null; try { voice = store.LoadVoice(); } catch (Exception ex) { SetStatus(ex.Message, true); }
                int changed = 0, failed = 0;
                foreach (var recording in recordings.Where(r => !r.IsRecording && r.DeletedAt is null))
                {
                    token.ThrowIfCancellationRequested();
                    try { if (await OwnerAttribution.ReapplyAsync(library, recording, profile, voice, token)) changed++; }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception) { failed++; }
                }
                if (selected is not null) LoadDocuments(selected);
                SetStatus($"프로필을 반영했습니다 · 회의 {changed}개 갱신" + (failed > 0 ? $" · {failed}개 문서는 다시 확인해 주세요." : ""), failed > 0);
            });
        }
        catch (Exception ex) { profileWindow = null; UpdateControls(); SetStatus(FriendlyError(ex), true); }
    }
}
