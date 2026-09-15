namespace NoteTaker.Core;

public static class MeetingNotesSources
{
    public static MeetingNotesSource Resolve(LibraryStore library, Recording recording, MeetingNotes notes, string audioHash)
    {
        if (notes.Original is { } original) { Validate(original, recording, audioHash); return original; }
        // Older versions stored only a content hash. Recover exclusively from the exact matching original, never from a newer transcript.
        if (string.IsNullOrEmpty(notes.TranscriptHash)) throw Missing();
        string history = Path.Combine(library.DirectoryFor(recording.Id), "TranscriptHistory");
        IEnumerable<string> paths = new[] { library.TranscriptPath(recording.Id) };
        if (Directory.Exists(history)) paths = paths.Concat(Directory.EnumerateFiles(history, "*.json").OrderDescending(StringComparer.Ordinal));
        foreach (string path in paths)
        {
            if (!File.Exists(path) || new FileInfo(path).Length > 64 * 1024 * 1024) continue;
            TranscriptCache? cache;
            try { cache = JsonDisk.Read<TranscriptCache>(path); }
            catch (System.Text.Json.JsonException) { continue; }
            if (cache?.Complete != true || cache.Chunks is null || cache.Chunks.Any(c => c is null) || !string.Equals(cache.AudioHash, audioHash, StringComparison.OrdinalIgnoreCase) || MeetingNotesService.TranscriptContentHash(cache) != notes.TranscriptHash) continue;
            MeetingTranscript? speakers = null;
            if (notes.Cleanup?.SourceKind == "speakers")
            {
                speakers = new MeetingWorkspaceStore(library).Resolve(recording)?.Transcript;
                try { notes.Cleanup.Validate(CleanupSource.Make(string.Join("\n\n", cache.Chunks), speakers, "speakers")); }
                catch (InvalidDataException) { throw Missing(); }
            }
            var recovered = new MeetingNotesSource(recording.AudioVersion, audioHash, string.Join("\n\n", cache.Chunks), cache.Model, speakers);
            Validate(recovered, recording, audioHash); return recovered;
        }
        throw Missing();
    }
    public static void Validate(MeetingNotesSource source, Recording recording, string audioHash)
    {
        if (source.AudioVersion != recording.AudioVersion || !string.Equals(source.AudioHash, audioHash, StringComparison.OrdinalIgnoreCase)) throw Missing();
        MeetingValidation.Utf8Text(source.Transcript, SyncJson.NotesLimit, true); MeetingValidation.Utf8Text(source.TranscriptionModelId, 512);
        if (source.Speakers is { } speakers)
        {
            speakers.Validate(recording.DurationSeconds);
            MeetingValidation.Require(speakers.RecordingId == recording.Id && speakers.AudioVersion == recording.AudioVersion);
        }
    }
    private static InvalidDataException Missing() => new("이 회의록을 만들 때 사용한 원문을 확인하지 못했습니다. 기존 회의록은 보존했습니다. 원문을 복구하거나 회의록을 다시 생성해 주세요.");
    public static DateTimeOffset NextEditTime(MeetingNotes previous) => DateTimeOffset.FromUnixTimeMilliseconds(Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), previous.CreatedAt.ToUnixTimeMilliseconds() + 1000));
}
