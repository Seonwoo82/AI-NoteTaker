using System.IO;
using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static class SmokeParticipants
{
    public static async Task RunAsync(string output, string sample, string modelRoot)
    {
        Directory.CreateDirectory(output); Appearance.Apply(false);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        new SettingsStore(library.Root).Save(new AppSettings { SpeechLanguage = "zh" });
        var recording = await library.ImportAsync(sample); recording = recording with { Title = "공개 4인 음성 · 참여자 분석 검증" }; library.Save(recording);
        var preservedNotes = new MeetingNotes("# 이전 회의록\n\n참여자 분석 전 보존 확인용 문서입니다.", DateTimeOffset.UtcNow, "fixture", 0);
        JsonDisk.Write(library.NotesPath(recording.Id), preservedNotes);
        string audioHash = await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default);
        var window = new MainWindow(library, discoverDevices: false, aiModelRoot: modelRoot, enableDesktopIntegration: false)
        { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false, Width = 1120, Height = 780 };
        window.Show(); window.ReloadLibrary(recording.Id);
        try
        {
            ((TabControl)window.FindName("DetailPanel")).SelectedIndex = 2;
            ((Button)window.FindName("AnalyzeParticipantsButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await window.CurrentWork;
            if (window.LastWorkError is not null) throw new InvalidOperationException("Native participant analysis failed.", window.LastWorkError);
            var store = new MeetingWorkspaceStore(library); var document = store.Load(recording) ?? throw new InvalidOperationException("No participant document.");
            if (document.Transcript.Turns.Count == 0 || document.Transcript.Speakers.Count == 0) throw new InvalidOperationException("No timed speaker turns.");
            var people = (ComboBox)window.FindName("ParticipantPeople"); people.SelectedIndex = 0;
            ((Button)window.FindName("MarkOwnerButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var resolved = store.Resolve(recording)!;
            if (resolved.OwnTurns.Count == 0) throw new InvalidOperationException("Mark as me did not persist.");
            store.Append(recording, "speakerName", resolved.Transcript.Speakers[0].Id, "확인한 참여자");
            window.LoadDocuments(recording);
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "participants.png"));
            ((ComboBox)window.FindName("ParticipantFilter")).SelectedIndex = 1;
            if (((ListBox)window.FindName("ParticipantTurns")).Items.Count != resolved.OwnTurns.Count) throw new InvalidOperationException("Own-turn filter mismatch.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "own-turns.png"));
            string originalTranscript = File.ReadAllText(library.TranscriptPath(recording.Id));
            ((Button)window.FindName("AnalyzeParticipantsButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await window.CurrentWork;
            if (window.LastWorkError is not null) throw window.LastWorkError;
            var reopened = new MeetingWorkspaceStore(library).Resolve(recording)!;
            if (reopened.OwnTurns.Count != resolved.OwnTurns.Count || reopened.Transcript.Speakers[0].Name != "확인한 참여자") throw new InvalidOperationException("Reanalysis lost edits.");
            if (originalTranscript != File.ReadAllText(library.TranscriptPath(recording.Id)) || preservedNotes != JsonDisk.Read<MeetingNotes>(library.NotesPath(recording.Id)) ||
                audioHash != await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default)) throw new InvalidOperationException("Analysis changed source material.");
            Appearance.Apply(true); window.Width = 820; window.Height = 690;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "participants-compact-dark.png"));
            var stressRecording = await library.ImportAsync(sample); stressRecording = stressRecording with { Title = "가상화 검증 전용 · 생성한 발화 3,000개" }; library.Save(stressRecording);
            var stressTurns = Enumerable.Range(0, 3000).Select(index => new TranscriptTurn("stress-" + index, index * .015, index * .015 + .008, "a", "목록 가상화 검증용 생성 문장 " + index)).ToList();
            var stressDocument = new MeetingIntelligenceDocument(stressRecording.Id, 1, 0, Guid.NewGuid(), "", new(stressRecording.Id, 1, "generated-ui-fixture", [new("a", "검증 참여자", true)], stressTurns), null, [], "fixture");
            store.Save(stressRecording, stressDocument, null); window.ReloadLibrary(stressRecording.Id);
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "virtualized-3000-turns.png"));
            var turnList = (ListBox)window.FindName("ParticipantTurns");
            if (turnList.Items.Count != 3000 || turnList.ItemContainerGenerator.ContainerFromIndex(2999) is not null) throw new InvalidOperationException("Long turn list was not virtualized.");
            File.WriteAllText(Path.Combine(output, "result.txt"), $"PASS: Real Whisper Chinese ASR and Sherpa ONNX speaker analysis through the WPF action; {document.Transcript.Speakers.Count} published groups, {document.Transcript.Turns.Count} timed turns. Owner marking, own-turn filter, rename persistence after reanalysis and source audio/transcript/notes preservation verified. Light and compact dark UI rendered. Public Chinese fixture only; no microphone was opened and no speaker-identification accuracy claim is made for Korean meetings.");
        }
        finally { window.Close(); }
    }
}
