using System.Security.Cryptography;
using System.Text.Json;

namespace NoteTaker.Core;

public sealed record LocalAcousticCache(Guid RecordingId, int AudioVersion, string AudioHash, string TranscriptHash,
    string? DocumentRevision, AcousticDiarization Acoustic)
{
    public int SchemaVersion { get; init; } = 1;
    public string? TranscriptFingerprint { get; init; }
}
public static class OwnerAttribution
{
    public static string CachePath(LibraryStore library, Guid id) => Path.Combine(library.DirectoryFor(id), "speaker-acoustic-local.json");
    public static string Fingerprint(MeetingTranscript transcript) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new
    { transcript.RecordingId, transcript.AudioVersion, transcript.TranscriptionModelId, transcript.Turns }, JsonDisk.Options)));
    public static MeetingTranscript Apply(MeetingTranscript transcript, AcousticDiarization acoustic, MeetingProfile profile, LocalVoiceProfile? voice)
    {
        var vectors = acoustic.Speakers.ToDictionary(s => s.Id, StringComparer.Ordinal);
        return transcript with
        {
            Speakers = transcript.Speakers.Select((speaker, index) =>
            {
                if (speaker.ManuallyAssigned) return speaker;
                bool own = vectors.TryGetValue(speaker.Id, out var vector) && OwnerVoicePolicy.Classify(acoustic.ModelId, vector.Embedding, voice) == OwnerSpeechState.Owner;
                return speaker with { IsOwner = own, Name = own ? (profile.DisplayName.Length > 0 ? profile.DisplayName : "나") : speaker.IsOwner ? $"참여자 {index + 1}" : speaker.Name };
            }).ToList()
        };
    }
    public static async Task<bool> ReapplyAsync(LibraryStore library, Recording recording, MeetingProfile profile, LocalVoiceProfile? voice, CancellationToken token)
    {
        string path = CachePath(library, recording.Id); if (!File.Exists(path)) return false;
        MeetingValidation.Require(new FileInfo(path).Length <= 4 * 1024 * 1024);
        var store = new MeetingWorkspaceStore(library); var document = store.Load(recording); if (document is null) return false;
        string? revision = store.Revision(recording.Id);
        var cache = JsonDisk.Read<LocalAcousticCache>(path);
        if (cache is null || cache.SchemaVersion != 1 || cache.RecordingId != recording.Id || cache.AudioVersion != recording.AudioVersion ||
            cache.Acoustic?.ModelId != SpeakerModels.EmbeddingModelId || cache.Acoustic.Speakers is not { Count: <= 64 } ||
            cache.Acoustic.Speakers.Any(s => s is null || !SpeakerWorkerClient.ValidEmbedding(s.Embedding)) ||
            cache.Acoustic.Speakers.Select(s => s.Id).Distinct().Count() != cache.Acoustic.Speakers.Count) return false;
        string fingerprint = Fingerprint(document.Transcript);
        if (cache.TranscriptFingerprint is { } saved ? saved != fingerprint : cache.DocumentRevision != revision) return false;
        if (cache.AudioHash != await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token)) return false;
        var transcript = Apply(document.Transcript, cache.Acoustic, profile, voice);
        if (transcript.Speakers.SequenceEqual(document.Transcript.Speakers)) return false;
        token.ThrowIfCancellationRequested(); store.Save(recording, document with { Transcript = transcript }, revision);
        JsonDisk.Write(path, cache with { TranscriptFingerprint = fingerprint, DocumentRevision = store.Revision(recording.Id) }); return true;
    }
}
