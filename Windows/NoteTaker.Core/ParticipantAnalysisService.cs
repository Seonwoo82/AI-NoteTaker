namespace NoteTaker.Core;

public sealed class ParticipantAnalysisService(LibraryStore library, string modelRoot, MeetingNotesService notesService)
{
    public async Task<MeetingIntelligenceDocument> AnalyzeAsync(Recording recording, AppSettings settings, string key,
        int knownSpeakerCount, IProgress<string> progress, CancellationToken token)
    {
        if (recording.IsRecording || recording.DeletedAt is not null) throw new InvalidOperationException("저장된 녹음을 선택해 주세요.");
        SpeakerAudioWindows.ValidateDuration(recording.DurationSeconds);
        var store = new MeetingWorkspaceStore(library);
        string? revision = store.Revision(recording.Id); var previous = store.Load(recording);
        var edits = store.Edits(recording.Id);
        var transcript = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id));
        if (transcript?.Complete != true) transcript = await notesService.TranscribeAsync(recording, settings, key, progress, token);
        string audioPath = library.AudioPath(recording.Id), hash = await MeetingNotesService.AudioHashAsync(audioPath, token);
        if (transcript.AudioHash != hash) throw new InvalidDataException("현재 녹음과 전사문이 다릅니다.");
        string transcriptHash = MeetingNotesService.TranscriptContentHash(transcript);
        var timed = await new ParticipantTranscriptService(library, modelRoot).PrepareAsync(recording, transcript, settings, key, progress, token);
        if (timed.Segments.Count == 0) throw new InvalidDataException("시간 정보가 있는 전사문이 필요합니다. 전사를 완료한 뒤 다시 실행해 주세요.");
        await SpeakerModels.PrepareAsync(modelRoot, progress, token);
        var acoustic = await new SpeakerWorkerClient(modelRoot, knownSpeakerCount: knownSpeakerCount).DiarizeAsync(audioPath, progress, token);
        token.ThrowIfCancellationRequested();
        AcousticDiarization? previousAcoustic = null;
        string acousticPath = OwnerAttribution.CachePath(library, recording.Id);
        if (previous is not null && File.Exists(acousticPath) && new FileInfo(acousticPath).Length <= 4 * 1024 * 1024)
        {
            try
            {
                var cache = JsonDisk.Read<LocalAcousticCache>(acousticPath);
                if (cache?.RecordingId == recording.Id && cache.AudioVersion == recording.AudioVersion && cache.AudioHash == hash &&
                    (cache.TranscriptFingerprint is { } fingerprint ? fingerprint == OwnerAttribution.Fingerprint(previous.Transcript) : cache.DocumentRevision == revision)) previousAcoustic = cache.Acoustic;
            }
            catch (System.Text.Json.JsonException) { }
        }
        acoustic = SpeakerIdentity.Reconcile(acoustic, previousAcoustic);
        var assembled = MeetingTranscriptAssembler.Assemble(recording.Id, recording.AudioVersion, timed.Model, recording.DurationSeconds, timed.Segments, acoustic);
        assembled = SpeakerIdentity.PreserveCorrectedTurns(assembled, previous?.Transcript, edits);
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
