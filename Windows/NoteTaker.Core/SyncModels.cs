using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using System.Text.RegularExpressions;

namespace NoteTaker.Core;

// Dedicated wire contracts: never serialize AppSettings, recording caches or voice profiles to the server.
public static class SyncJson
{
    public const int MetadataLimit = 64 * 1024, AudioLimit = 95 * 1024 * 1024, NotesLimit = 2 * 1024 * 1024, IntelligenceLimit = 4 * 1024 * 1024;
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        RespectRequiredConstructorParameters = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, TypeInfoResolver = Resolver(),
        Converters = { new UpperGuidConverter(), new AppleDateConverter() }
    };
    private static DefaultJsonTypeInfoResolver Resolver()
    {
        var resolver = new DefaultJsonTypeInfoResolver();
        resolver.Modifiers.Add(info =>
        {
            if (info.Kind != JsonTypeInfoKind.Object) return;
            string[] optional = info.Type.Name switch
            {
                nameof(SyncRecording) => ["deletedAt", "transcriptionError", "folderAssignment"],
                nameof(RecordingCollectionFolder) => ["deletedAt", "sortOrder"],
                nameof(SyncNotes) => ["costUSD", "speakerTranscript", "enhancement", "transcriptCleanup"],
                nameof(SyncPreferences) => ["enhancementModelID", "transcriptCleanupEnabled"],
                nameof(MeetingIntelligenceDocument) => ["insights"],
                nameof(TranscriptTurn) or nameof(MeetingDecisionStep) => ["speakerID"],
                nameof(MeetingAction) => ["actorSpeakerID", "targetSpeakerID", "dueText"],
                nameof(MeetingQuestion) => ["answer"],
                nameof(SyncRecordingsPage) or nameof(SyncFoldersPage) or nameof(SyncNotesPage) or nameof(SyncIntelligencePage) or nameof(SyncEditsPage) => ["nextCursor"],
                _ => []
            };
            foreach (var property in info.Properties.Where(p => p.Set is not null)) property.IsRequired = !optional.Contains(property.Name);
        }); return resolver;
    }
    public static byte[] Encode<T>(T value, int limit)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value, Options);
        if (bytes.Length > limit) throw new InvalidDataException("동기화 문서가 서버 크기 제한을 초과했습니다."); return bytes;
    }
    public static T Decode<T>(ReadOnlySpan<byte> bytes, int limit)
    {
        if (bytes.Length > limit) throw new InvalidDataException("동기화 응답이 크기 제한을 초과했습니다.");
        try { return JsonSerializer.Deserialize<T>(bytes, Options) ?? throw new InvalidDataException("동기화 응답이 비어 있습니다."); }
        catch (JsonException ex) { throw new InvalidDataException("지원하지 않는 동기화 문서입니다.", ex); }
    }
    public static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    public static string Id(Guid id) => id.ToString("D").ToUpperInvariant();
    public static bool Wins(long time, Guid mutation, long otherTime, Guid otherMutation) => time > otherTime || time == otherTime && string.CompareOrdinal(Id(mutation), Id(otherMutation)) > 0;
    public static DateTimeOffset Seconds(DateTimeOffset date) => DateTimeOffset.FromUnixTimeSeconds(date.ToUnixTimeSeconds());
    private sealed class UpperGuidConverter : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            string? value = reader.GetString();
            if (value is null || !Guid.TryParseExact(value, "D", out var id) || value != Id(id)) throw new JsonException("Expected canonical uppercase UUID."); return id;
        }
        public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) => writer.WriteStringValue(Id(value));
    }
    private sealed class AppleDateConverter : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        {
            string? value = reader.GetString();
            if (value is null || !Regex.IsMatch(value, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$") || !DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) throw new JsonException("Expected ISO-8601 date."); return date;
        }
        // Apple's JSONDecoder.iso8601 expects whole seconds; mutation clocks retain millisecond precision separately.
        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) => writer.WriteStringValue(value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }
}
public sealed record SyncFolderAssignment(Guid? Id);
public sealed record SyncRecording(int SchemaVersion, Guid Id, string Title, DateTimeOffset CreatedAt, double Duration,
    bool IsFavorite, DateTimeOffset? DeletedAt, string Mode, int AudioVersion, bool HasTranscript, string? TranscriptionError,
    double PlaybackRate, bool SkipsSilence, bool Enhances, List<string> Warnings, long ModifiedAt,
    [property: JsonPropertyName("mutationID")] Guid MutationId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] SyncFolderAssignment? FolderAssignment = null)
{
    public void Validate()
    {
        MeetingValidation.Require(SchemaVersion == 1 && Id != Guid.Empty && MutationId != Guid.Empty && AudioVersion > 0 &&
            double.IsFinite(Duration) && Duration >= 0 && double.IsFinite(PlaybackRate) && PlaybackRate > 0 && Mode is "micOnly" or "systemOnly" or "micAndSystem" && Warnings is not null);
        MeetingValidation.Utf8Text(Title, 4096, true); MeetingValidation.Require(Title.Length <= 1024); MeetingValidation.Timestamp(ModifiedAt);
        if (TranscriptionError is not null) { MeetingValidation.Utf8Text(TranscriptionError, 16384, true); MeetingValidation.Require(TranscriptionError.Length <= 4096); }
        foreach (var warning in Warnings!) MeetingValidation.Require(warning is not null);
        _ = SyncJson.Encode(this, SyncJson.MetadataLimit);
    }
    public bool Wins(SyncRecording? other) => other is null || SyncJson.Wins(ModifiedAt, MutationId, other.ModifiedAt, other.MutationId);
}
public sealed record SyncNotes(int SchemaVersion, [property: JsonPropertyName("recordingID")] Guid RecordingId,
    int AudioVersion, DateTimeOffset GeneratedAt, [property: JsonPropertyName("modelID")] string ModelId,
    [property: JsonPropertyName("transcriptionModelID")] string TranscriptionModelId, string Markdown, string Transcript,
    [property: JsonPropertyName("costUSD")] decimal? CostUsd = null, MeetingTranscript? SpeakerTranscript = null,
    MeetingNotesEnhancement? Enhancement = null, TranscriptCleanup? TranscriptCleanup = null)
{
    public void Validate(double duration)
    {
        MeetingValidation.Require(SchemaVersion == 1 && RecordingId != Guid.Empty && AudioVersion > 0 && CostUsd is null or >= 0);
        MeetingValidation.Utf8Text(ModelId, 512); MeetingValidation.Utf8Text(TranscriptionModelId, 512);
        MeetingValidation.Utf8Text(Markdown, SyncJson.NotesLimit, true); MeetingValidation.Utf8Text(Transcript, SyncJson.NotesLimit, true);
        if (SpeakerTranscript is { } speakers)
        {
            speakers.Validate(duration); MeetingValidation.Require(speakers.RecordingId == RecordingId && speakers.AudioVersion == AudioVersion);
        }
        if (Enhancement is { } enhancement) { MeetingValidation.Utf8Text(enhancement.ModelId, 512); MeetingValidation.Utf8Text(enhancement.Instructions, 8000); }
        if (TranscriptCleanup is { } cleanup) cleanup.Validate(CleanupSource.Make(Transcript, SpeakerTranscript, cleanup.SourceKind));
        _ = SyncJson.Encode(this, SyncJson.NotesLimit);
    }
}
public sealed record SyncDescriptor([property: JsonPropertyName("recordingID")] Guid RecordingId, int AudioVersion, long GeneratedAtMillis, string Revision, int ByteCount)
{
    public void Validate(int limit)
    {
        MeetingValidation.Require(RecordingId != Guid.Empty && AudioVersion > 0 && Revision is not null && Regex.IsMatch(Revision, "^[0-9a-f]{64}$") && ByteCount > 0 && ByteCount <= limit);
        MeetingValidation.Timestamp(GeneratedAtMillis);
    }
    public bool Wins(SyncDescriptor? other) => other is null || GeneratedAtMillis > other.GeneratedAtMillis || GeneratedAtMillis == other.GeneratedAtMillis && string.CompareOrdinal(Revision, other.Revision) > 0;
}
public sealed record SyncPreferences(int SchemaVersion, [property: JsonPropertyName("modelID")] string ModelId,
    [property: JsonPropertyName("transcriptionModelID")] string TranscriptionModelId, string OutputLanguage, bool AutoGenerate,
    long ModifiedAt, [property: JsonPropertyName("mutationID")] Guid MutationId,
    [property: JsonPropertyName("enhancementModelID")] string? EnhancementModelId = null, bool? TranscriptCleanupEnabled = null)
{
    public void Validate()
    {
        bool Model(string? id) => id is not null && Encoding.UTF8.GetByteCount(id) <= 256 && (id.Length == 0 || Regex.IsMatch(id, "^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$"));
        MeetingValidation.Require(SchemaVersion == 1 && Model(ModelId) && Model(TranscriptionModelId) && Model(EnhancementModelId ?? "") && OutputLanguage is "ko" or "en" or "source" && MutationId != Guid.Empty);
        MeetingValidation.Timestamp(ModifiedAt);
    }
}
public sealed record SyncDevice(Guid Id, string Platform, [property: JsonPropertyName("hasAPIKey")] bool? HasApiKey);
public sealed record SyncSettingsUpload(SyncPreferences? Preferences, SyncDevice Device);
public sealed record SyncSettingsResponse(SyncPreferences? Preferences, [property: JsonPropertyName("otherDevicesHaveAPIKey")] bool OtherDevicesHaveApiKey);
public sealed record SyncHealth(bool Ok, int SchemaVersion);
public sealed record SyncRecordingsPage(List<SyncRecording> Recordings, string? NextCursor = null);
public sealed record SyncFoldersPage(List<RecordingCollectionFolder> Folders, string? NextCursor = null);
public sealed record SyncNotesPage(List<SyncDescriptor> Notes, string? NextCursor = null);
public sealed record SyncIntelligencePage(List<SyncDescriptor> Intelligence, string? NextCursor = null);
public sealed record SyncProfileResponse(MeetingProfile? Profile);
public sealed record SyncEditEntry(long Sequence, MeetingEdit Edit);
public sealed record SyncEditsPage(List<SyncEditEntry> Entries, long? NextCursor);
