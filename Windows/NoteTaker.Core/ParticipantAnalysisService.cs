namespace NoteTaker.Core;

public sealed class ParticipantAnalysisService(LibraryStore library, string modelRoot, MeetingNotesService notesService)
{
    public async Task<MeetingIntelligenceDocument> AnalyzeAsync(Recording recording, AppSettings settings, string key,
        int knownSpeakerCount, IProgress<string> progress, CancellationToken token)
    {
        if (recording.IsRecording || recording.DeletedAt is not null) throw new InvalidOperationException("저장된 녹음을 선택해 주세요.");
        var store = new MeetingWorkspaceStore(library);
        string? revision = store.Revision(recording.Id); var previous = store.Load(recording);
        _ = store.Edits(recording.Id);
        var transcript = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id));
        if (transcript?.Complete != true) transcript = await notesService.TranscribeAsync(recording, settings, key, progress, token);
        string audioPath = library.AudioPath(recording.Id), hash = await MeetingNotesService.AudioHashAsync(audioPath, token);
        if (transcript.AudioHash != hash || transcript.Segments.Count == 0) throw new InvalidDataException("시간 정보가 있는 전사문이 필요합니다. 전사를 완료한 뒤 다시 실행해 주세요.");
        string transcriptHash = MeetingNotesService.TranscriptContentHash(transcript);
        await SpeakerModels.PrepareAsync(modelRoot, progress, token);
        var acoustic = await new SpeakerWorkerClient(modelRoot, knownSpeakerCount: knownSpeakerCount).DiarizeAsync(audioPath, progress, token);
        token.ThrowIfCancellationRequested();
        var assembled = MeetingTranscriptAssembler.Assemble(recording.Id, recording.AudioVersion, transcript.Model, recording.DurationSeconds, transcript.Segments, acoustic);
        if (assembled.Turns.Count == 0) throw new InvalidDataException("시간 정보가 있는 발화를 찾지 못했습니다. 기존 전사문은 유지됩니다.");
        var profiles = new MeetingProfileStore(library.Root); var profile = profiles.Load();
        LocalVoiceProfile? voice = null;
        try { voice = profiles.LoadVoice(); }
        catch (Exception ex) when (ex is InvalidDataException or System.Text.Json.JsonException) { progress.Report("목소리 프로필을 다시 등록해야 합니다. 참여자는 이름 없이 구분합니다."); }
        assembled = OwnerAttribution.Apply(assembled, acoustic, profile, voice);
        MeetingInsights? insights = previous?.Insights;
        if (insights is not null) { try { insights.Validate(assembled); } catch (InvalidDataException) { insights = null; } }
        var document = new MeetingIntelligenceDocument(recording.Id, recording.AudioVersion, 0, Guid.NewGuid(), previous?.ProjectName ?? "", assembled,
            insights, insights is null ? [] : previous!.ActionStates, insights is null ? "sherpa-onnx-1.13.8/3dspeaker-eres2net" : previous!.AnalysisModelId);
        // The native worker may take several minutes; verify both sources again before publication.
        if (hash != await MeetingNotesService.AudioHashAsync(audioPath, token)) throw new InvalidOperationException("분석 중 오디오가 변경되었습니다. 다시 실행해 주세요.");
        var current = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id));
        if (current is null || MeetingNotesService.TranscriptContentHash(current) != transcriptHash) throw new InvalidOperationException("분석 중 전사문이 변경되었습니다. 다시 실행해 주세요.");
        token.ThrowIfCancellationRequested(); store.Save(recording, document, revision);
        // Device-local acoustic vectors are deliberately outside the shared intelligence schema.
        JsonDisk.Write(OwnerAttribution.CachePath(library, recording.Id), new LocalAcousticCache(recording.Id, recording.AudioVersion, hash, transcriptHash, store.Revision(recording.Id), acoustic)
        { TranscriptFingerprint = OwnerAttribution.Fingerprint(assembled) });
        return store.Load(recording)!;
    }
}
