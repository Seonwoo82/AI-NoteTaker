namespace NoteTaker.Core;

public static class SyncRecordings
{
    public static SyncRecording FromLocal(Recording recording, SyncRecording? previous, long timestamp, bool stamp)
    {
        if (previous is not null) { previous.Validate(); if (previous.Id != recording.Id) throw new InvalidDataException("녹음 동기화 ID가 일치하지 않습니다."); }
        long time = stamp ? Math.Max(timestamp, previous is null ? 0 : checked(previous.ModifiedAt + 1)) : previous?.ModifiedAt ?? timestamp;
        var warnings = previous?.Warnings.ToList() ?? [];
        if (!string.IsNullOrEmpty(recording.Warning) && string.Join("\n", warnings) != recording.Warning) warnings = [recording.Warning];
        var wire = new SyncRecording(1, recording.Id, recording.Title, recording.CreatedAt, recording.DurationSeconds, recording.IsFavorite, recording.DeletedAt,
            recording.Mode switch { RecordingMode.SystemAudio => "systemOnly", RecordingMode.Mixed => "micAndSystem", _ => "micOnly" }, recording.AudioVersion,
            previous?.HasTranscript ?? false, previous?.TranscriptionError, previous?.PlaybackRate ?? 1, previous?.SkipsSilence ?? false, previous?.Enhances ?? false,
            warnings, time, stamp || previous is null ? Guid.NewGuid() : previous.MutationId, new(recording.FolderId));
        wire.Validate(); return wire;
    }
    public static Recording ToLocal(SyncRecording remote, Recording? previous)
    {
        remote.Validate();
        return new Recording
        {
            Id = remote.Id, Title = remote.Title, CreatedAt = remote.CreatedAt, DurationSeconds = remote.Duration, AudioVersion = remote.AudioVersion,
            Mode = remote.Mode switch { "systemOnly" => RecordingMode.SystemAudio, "micAndSystem" => RecordingMode.Mixed, _ => previous?.Mode == RecordingMode.Imported ? RecordingMode.Imported : RecordingMode.Microphone },
            IsFavorite = remote.IsFavorite, DeletedAt = remote.DeletedAt, FolderId = remote.FolderAssignment is { } folder ? folder.Id : previous?.FolderId,
            Warning = remote.Warnings.Count > 0 ? string.Join("\n", remote.Warnings) : previous?.Warning, SyncMetadata = remote
        };
    }
    public static string MetadataPath(Guid id) => $"Recordings/{id:D}/meta.json";
    // This path never repairs an open recording; active capture is explicitly skipped by the sync engine.
    public static Recording? Read(LibraryStore library, Guid id)
    {
        lock (JsonDisk.Gate)
        {
            string path = SyncFileTransaction.PathIn(library.Root, MetadataPath(id));
            if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024) throw new InvalidDataException("녹음 메타데이터가 너무 큽니다.");
            var recording = JsonDisk.Read<Recording>(path); if (recording is null) return null;
            if (recording.SchemaVersion != 1 || recording.Id != id || !Enum.IsDefined(recording.Mode)) throw new InvalidDataException("녹음 메타데이터가 올바르지 않습니다.");
            var wire = FromLocal(recording, recording.SyncMetadata, Math.Max(0, new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds()), stamp: false);
            bool changed = recording.SyncMetadata is null;
            string transcriptPath = library.TranscriptPath(id);
            if (!recording.IsRecording && !wire.HasTranscript && File.Exists(transcriptPath) && new FileInfo(transcriptPath).Length <= 64 * 1024 * 1024)
            {
                try
                {
                    var cache = JsonDisk.Read<TranscriptCache>(transcriptPath);
                    if (cache?.Complete == true && cache.Chunks is { Count: > 0 } && cache.Chunks.Any(text => !string.IsNullOrWhiteSpace(text)))
                    {
                        wire = wire with { HasTranscript = true, ModifiedAt = Math.Max(wire.ModifiedAt + 1, new DateTimeOffset(File.GetLastWriteTimeUtc(transcriptPath)).ToUnixTimeMilliseconds()), MutationId = Guid.NewGuid() };
                        wire.Validate(); changed = true;
                    }
                }
                catch (System.Text.Json.JsonException) { /* A broken transcript is reported by the document phase; audio/metadata can still synchronize. */ }
            }
            if (changed) { recording = recording with { SyncMetadata = wire }; JsonDisk.Write(path, recording); }
            return recording;
        }
    }
}
