using System.Text.Json;

namespace NoteTaker.Core;

public sealed record SyncArtifact(byte[] Bytes, SyncDescriptor Descriptor, SyncNotes? Notes, MeetingIntelligenceDocument? Intelligence,
    Dictionary<string, string?> Expected);
internal sealed record SyncDocumentCache(string LocalRevision, SyncDescriptor Descriptor, byte[] Bytes);

public sealed class SyncDocumentStore(LibraryStore library)
{
    private static string Prefix(Guid id) => $"Recordings/{id:D}/";
    public static string DocumentPath(Guid id, bool intelligence) => Prefix(id) + (intelligence ? "meeting-intelligence.json" : "notes.json");
    private static string CachePath(Guid id, bool intelligence) => Prefix(id) + (intelligence ? "sync-intelligence-local.json" : "sync-notes-local.json");
    public Dictionary<string, string?> Snapshot(Recording recording, bool intelligence)
    {
        var paths = new List<string> { SyncRecordings.MetadataPath(recording.Id), DocumentPath(recording.Id, intelligence), CachePath(recording.Id, intelligence) };
        if (!intelligence) paths.AddRange([Prefix(recording.Id) + "transcript.json", Prefix(recording.Id) + "meeting-intelligence.json", Prefix(recording.Id) + "meeting-edits-local.json"]);
        return SyncFileTransaction.Snapshot(library.Root, paths);
    }
    public async Task<SyncArtifact?> ReadAsync(Recording recording, bool intelligence, CancellationToken token)
    {
        string relative = DocumentPath(recording.Id, intelligence), path = SyncFileTransaction.PathIn(library.Root, relative);
        Dictionary<string, string?> expected;
        lock (JsonDisk.Gate) { RequireRecording(recording); expected = Snapshot(recording, intelligence); if (expected[relative] is null) return null; }
        string? audioHash = intelligence ? null : await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token);
        lock (JsonDisk.Gate)
        {
            token.ThrowIfCancellationRequested(); SyncFileTransaction.RequireCurrent(library.Root, expected); RequireRecording(recording);
            int limit = intelligence ? SyncJson.IntelligenceLimit : SyncJson.NotesLimit;
            string cachePath = SyncFileTransaction.PathIn(library.Root, CachePath(recording.Id, intelligence));
            if (File.Exists(cachePath))
            {
                RequireSize(cachePath, limit * 2 + 4096); var cached = JsonDisk.Read<SyncDocumentCache>(cachePath);
                if (cached is not null && cached.LocalRevision == expected[relative])
                {
                    if (!intelligence)
                    {
                        _ = MeetingNotesSources.Resolve(library, recording, new NotesDocumentStore(library).Load(recording)!, audioHash!);
                        expected[Prefix(recording.Id) + "audio.wav"] = audioHash!.ToLowerInvariant();
                    }
                    return Decode(recording, intelligence, cached.Bytes, cached.Descriptor, expected);
                }
            }
            byte[] bytes; long timestamp;
            if (intelligence)
            {
                var document = new MeetingWorkspaceStore(library).Load(recording)!;
                bytes = SyncJson.Encode(document, limit); timestamp = document.ModifiedAt;
            }
            else
            {
                var notes = new NotesDocumentStore(library).Load(recording)!;
                var source = MeetingNotesSources.Resolve(library, recording, notes, audioHash!);
                var wire = new SyncNotes(1, recording.Id, recording.AudioVersion, SyncJson.Seconds(notes.CreatedAt), notes.Model, source.TranscriptionModelId,
                    notes.Markdown, source.Transcript, notes.CostUsd, source.Speakers, notes.Enhancement, notes.Cleanup);
                wire.Validate(recording.DurationSeconds); bytes = SyncJson.Encode(wire, limit); timestamp = wire.GeneratedAt.ToUnixTimeMilliseconds();
                if (notes.Original is null)
                {
                    // Persist a recovered original even if a later transcript replaces the old cache/history.
                    JsonDisk.Write(path, notes with { Original = source }); expected = Snapshot(recording, false);
                }
                expected[Prefix(recording.Id) + "audio.wav"] = audioHash!.ToLowerInvariant();
            }
            var descriptor = new SyncDescriptor(recording.Id, recording.AudioVersion, timestamp, SyncJson.Hash(bytes), bytes.Length);
            return Decode(recording, intelligence, bytes, descriptor, expected);
        }
    }
    public static SyncArtifact Decode(Recording recording, bool intelligence, byte[] bytes, SyncDescriptor descriptor, Dictionary<string, string?> expected)
    {
        int limit = intelligence ? SyncJson.IntelligenceLimit : SyncJson.NotesLimit; descriptor.Validate(limit);
        MeetingValidation.Require(descriptor.RecordingId == recording.Id && descriptor.AudioVersion == recording.AudioVersion && descriptor.ByteCount == bytes.Length && descriptor.Revision == SyncJson.Hash(bytes));
        if (intelligence)
        {
            var document = SyncJson.Decode<MeetingIntelligenceDocument>(bytes, limit); document.Validate(recording.DurationSeconds);
            MeetingValidation.Require(document.RecordingId == recording.Id && document.AudioVersion == recording.AudioVersion && document.ModifiedAt == descriptor.GeneratedAtMillis);
            return new(bytes, descriptor, null, document, expected);
        }
        var notes = SyncJson.Decode<SyncNotes>(bytes, limit); notes.Validate(recording.DurationSeconds);
        MeetingValidation.Require(notes.RecordingId == recording.Id && notes.AudioVersion == recording.AudioVersion && notes.GeneratedAt.ToUnixTimeMilliseconds() == descriptor.GeneratedAtMillis);
        return new(bytes, descriptor, notes, null, expected);
    }
    public async Task ApplyAsync(Recording recording, SyncArtifact incoming, bool intelligence, CancellationToken token)
    {
        _ = Decode(recording, intelligence, incoming.Bytes, incoming.Descriptor, incoming.Expected);
        string relative = DocumentPath(recording.Id, intelligence), rawRelative = CachePath(recording.Id, intelligence);
        string? audioHash = intelligence ? null : await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token);
        var expected = new Dictionary<string, string?>(incoming.Expected, StringComparer.OrdinalIgnoreCase);
        if (audioHash is not null)
        {
            string path = Prefix(recording.Id) + "audio.wav";
            if (expected.TryGetValue(path, out string? originalHash) && originalHash != audioHash.ToLowerInvariant()) throw new SyncLocalConflictException();
            expected[path] = audioHash.ToLowerInvariant();
        }
        byte[] localBytes; TranscriptCache? transcript = null;
        if (intelligence) localBytes = JsonSerializer.SerializeToUtf8Bytes(incoming.Intelligence, JsonDisk.Options);
        else
        {
            var wire = incoming.Notes!;
            transcript = new(audioHash!, wire.TranscriptionModelId, "source", [wire.Transcript], true) { Provider = "sync", Source = "sync" };
            var notes = new MeetingNotes(wire.Markdown, wire.GeneratedAt, wire.ModelId, wire.CostUsd)
            {
                TranscriptHash = MeetingNotesService.TranscriptContentHash(transcript), Enhancement = wire.Enhancement, Cleanup = wire.TranscriptCleanup,
                Original = new(recording.AudioVersion, audioHash!, wire.Transcript, wire.TranscriptionModelId, wire.SpeakerTranscript)
            };
            NotesDocumentStore.Validate(notes); localBytes = JsonSerializer.SerializeToUtf8Bytes(notes, JsonDisk.Options);
        }
        var files = new Dictionary<string, byte[]> { [relative] = localBytes,
            [rawRelative] = JsonSerializer.SerializeToUtf8Bytes(new SyncDocumentCache(SyncJson.Hash(localBytes), incoming.Descriptor, incoming.Bytes), JsonDisk.Options) };
        // Keep an independently updated local transcript. The note retains its own original and the existing stale-note indicator remains accurate.
        if (transcript is not null && expected[Prefix(recording.Id) + "transcript.json"] is null)
            files[Prefix(recording.Id) + "transcript.json"] = JsonSerializer.SerializeToUtf8Bytes(transcript, JsonDisk.Options);
        lock (JsonDisk.Gate) { RequireRecording(recording); ApplyFiles(library.Root, expected, files, token); }
    }
    public static void ApplyFiles(string root, Dictionary<string, string?> expected, Dictionary<string, byte[]> files, CancellationToken token)
    {
        string directory = SyncFileTransaction.PathIn(root, ".sync/document-work/" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var changes = new List<SyncFileChange>();
        try
        {
            foreach (var pair in files)
            {
                string source = Path.Combine(directory, changes.Count + ".json"); File.WriteAllBytes(source, pair.Value); changes.Add(new(pair.Key, source));
            }
            SyncFileTransaction.Commit(root, expected, changes, token);
        }
        finally { foreach (var change in changes) if (File.Exists(change.SourcePath)) File.Delete(change.SourcePath!); if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory); }
    }
    private void RequireRecording(Recording recording)
    {
        var current = SyncRecordings.Read(library, recording.Id);
        if (current is null || current.IsRecording || current.DeletedAt is not null || current.AudioVersion != recording.AudioVersion || current.DurationSeconds != recording.DurationSeconds) throw new SyncLocalConflictException();
    }
    private static void RequireSize(string path, int limit) { if (new FileInfo(path).Length > limit) throw new InvalidDataException("동기화 문서 캐시가 너무 큽니다."); }
}
