using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NoteTaker.Core;

public sealed record GlossaryTerm(Guid Id, string Term, string SpokenAs = "", string Meaning = "", string Category = "general")
{
    public void Validate()
    {
        MeetingProfile.Text(Term, 120); MeetingProfile.Text(SpokenAs, 120, true); MeetingProfile.Text(Meaning, 500, true);
        MeetingValidation.Require(Id != Guid.Empty && Category is "person" or "organization" or "project" or "abbreviation" or "general");
    }
}
public sealed record GlossarySubstitution(Guid TermId, int Utf16Start, int Utf16Length, string SourceText, string DisplayText);
public sealed record MeetingProfile
{
    public int SchemaVersion { get; init; } = 1;
    public string DisplayName { get; init; } = "";
    public List<string> Aliases { get; init; } = [];
    public string Role { get; init; } = "";
    public bool AutomaticallyAnalyze { get; init; }
    public List<GlossaryTerm> Terms { get; init; } = [];
    public long ModifiedAt { get; init; }
    [JsonPropertyName("mutationID")] public Guid MutationId { get; init; } = Guid.NewGuid();
    public const int MaximumBytes = 60 * 1024;

    public void Validate()
    {
        MeetingValidation.Require(SchemaVersion == 1 && MutationId != Guid.Empty && Aliases is { Count: <= 24 } && Terms is { Count: <= 200 });
        Text(DisplayName, 120, true); Text(Role, 160, true); MeetingValidation.Timestamp(ModifiedAt);
        foreach (var alias in Aliases!) Text(alias, 120);
        MeetingValidation.Require(Aliases.Select(Normalized).Distinct(StringComparer.Ordinal).Count() == Aliases.Count);
        foreach (var term in Terms!) { MeetingValidation.Require(term is not null); term!.Validate(); }
        MeetingValidation.Require(Terms.Select(t => t.Id).Distinct().Count() == Terms.Count && JsonSerializer.SerializeToUtf8Bytes(this, JsonDisk.Options).Length <= MaximumBytes);
    }
    [JsonIgnore] public string PromptContext
    {
        get
        {
            Validate(); var lines = new List<string>();
            if (DisplayName.Length > 0) lines.Add("Owner: " + DisplayName);
            if (Aliases.Count > 0) lines.Add("Owner aliases: " + string.Join(", ", Aliases));
            if (Role.Length > 0) lines.Add("Owner role: " + Role);
            if (Terms.Count > 0) { lines.Add("Glossary:"); lines.AddRange(Terms.Select(t => $"- [{t.Category}] {t.Term}" + (t.SpokenAs.Length > 0 ? " (spoken as: " + t.SpokenAs + ")" : "") + (t.Meaning.Length > 0 ? " - " + t.Meaning : ""))); }
            string context = string.Join('\n', lines); int bytes = 0; var result = new StringBuilder();
            foreach (var rune in context.EnumerateRunes()) { if (bytes + rune.Utf8SequenceLength > 12000) break; result.Append(rune); bytes += rune.Utf8SequenceLength; }
            return result.ToString();
        }
    }
    public IReadOnlyList<GlossarySubstitution> Substitutions(string source)
    {
        var result = new List<GlossarySubstitution>();
        foreach (var term in Terms)
        {
            string needle = string.IsNullOrWhiteSpace(term.SpokenAs) ? term.Term.Trim() : term.SpokenAs.Trim();
            if (needle.Length == 0 || needle == term.Term) continue;
            int offset = 0;
            while (offset < source.Length)
            {
                int relative = CultureInfo.InvariantCulture.CompareInfo.IndexOf(source.AsSpan(offset), needle.AsSpan(), CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace, out int length);
                if (relative < 0 || length == 0) break;
                int start = offset + relative;
                if (!result.Any(s => s.Utf16Start < start + length && start < s.Utf16Start + s.Utf16Length)) result.Add(new(term.Id, start, length, source.Substring(start, length), term.Term));
                offset = start + length;
            }
        }
        return result.OrderBy(s => s.Utf16Start).ToList();
    }
    public static string Normalized(string value) => string.Concat(value.Trim().Normalize(NormalizationForm.FormD).Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)).ToUpperInvariant();
    internal static void Text(string? value, int limit, bool empty = false)
    {
        MeetingValidation.Utf8Text(value, limit, empty);
        MeetingValidation.Require(value!.All(c => !char.IsControl(c) || c is '\n' or '\t'));
    }
}
public sealed record LocalVoiceProfile([property: JsonPropertyName("modelID")] string ModelId, float[] Embedding, DateTimeOffset EnrolledAt, double SampleDuration)
{
    public int SchemaVersion { get; init; } = 1;
    public void Validate()
    {
        MeetingValidation.Require(SchemaVersion == 1 && ModelId == SpeakerModels.EmbeddingModelId && SpeakerWorkerClient.ValidEmbedding(Embedding) &&
            double.IsFinite(SampleDuration) && SampleDuration is >= 10 and <= 30 && EnrolledAt >= DateTimeOffset.UnixEpoch);
    }
}
public enum OwnerSpeechState { Unavailable, Listening, Silence, Owner, Other, Uncertain }
public static class OwnerVoicePolicy
{
    public static OwnerSpeechState Classify(string modelId, float[] embedding, LocalVoiceProfile? profile)
    {
        if (profile is null) return OwnerSpeechState.Unavailable;
        try { profile.Validate(); } catch (InvalidDataException) { return OwnerSpeechState.Uncertain; }
        if (modelId != profile.ModelId || !SpeakerWorkerClient.ValidEmbedding(embedding)) return OwnerSpeechState.Uncertain;
        double score = SpeakerWorkerClient.Cosine(embedding, profile.Embedding);
        return score >= .6 ? OwnerSpeechState.Owner : score < .25 ? OwnerSpeechState.Other : OwnerSpeechState.Uncertain;
    }
}
public sealed class MeetingProfileStore(string root)
{
    private readonly object gate = JsonDisk.Gate;
    public string ProfilePath => Path.Combine(root, "meeting-profile.json");
    public string VoicePath => Path.Combine(root, "voice-profile-local.json");
    public string? ProfileRevision => Revision(ProfilePath);
    public string? VoiceRevision => Revision(VoicePath);
    public MeetingProfile Load()
    {
        if (!File.Exists(ProfilePath)) return new();
        RequireSize(ProfilePath, MeetingProfile.MaximumBytes);
        var profile = JsonDisk.Read<MeetingProfile>(ProfilePath) ?? throw new InvalidDataException("프로필을 읽지 못했습니다."); profile.Validate(); return profile;
    }
    public LocalVoiceProfile? LoadVoice()
    {
        if (!File.Exists(VoicePath)) return null; RequireSize(VoicePath, 262144);
        var voice = JsonDisk.Read<LocalVoiceProfile>(VoicePath) ?? throw new InvalidDataException("목소리 프로필을 읽지 못했습니다."); voice.Validate(); return voice;
    }
    public MeetingProfile Save(MeetingProfile profile, string? expectedRevision)
    {
        lock (gate)
        {
            var previous = Load(); if (ProfileRevision != expectedRevision) throw new InvalidOperationException("프로필이 다른 곳에서 변경되었습니다. 창을 다시 열어 확인해 주세요.");
            profile = profile with { ModifiedAt = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), checked(previous.ModifiedAt + 1)), MutationId = Guid.NewGuid() };
            profile.Validate(); JsonDisk.Write(ProfilePath, profile); return profile;
        }
    }
    public void SaveVoice(LocalVoiceProfile voice, string? expectedRevision)
    {
        lock (gate)
        {
            if (VoiceRevision != expectedRevision) throw new InvalidOperationException("목소리 프로필이 변경되었습니다. 다시 등록해 주세요.");
            // Explicit re-enrollment may replace an incompatible model, but only after a valid new result exists.
            voice.Validate(); JsonDisk.Write(VoicePath, voice);
        }
    }
    public void DeleteVoice(string? expectedRevision)
    {
        lock (gate)
        {
            if (VoiceRevision != expectedRevision) throw new InvalidOperationException("목소리 프로필이 변경되었습니다. 창을 다시 열어 주세요.");
            if (File.Exists(VoicePath)) File.Delete(VoicePath);
        }
    }
    private static string? Revision(string path)
    {
        if (!File.Exists(path)) return null; RequireSize(path, 262144);
        return Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
    }
    private static void RequireSize(string path, int bytes) { if (new FileInfo(path).Length > bytes) throw new InvalidDataException("프로필 파일이 너무 큽니다. 원본을 보존했습니다."); }
}
