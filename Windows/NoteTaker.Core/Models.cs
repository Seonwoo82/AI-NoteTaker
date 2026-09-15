using System.Text.Json.Serialization;

namespace NoteTaker.Core;

public enum RecordingMode { Microphone, SystemAudio, Mixed, Imported }

public sealed record Recording
{
    public int SchemaVersion { get; init; } = 1;
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Title { get; init; } = "새 녹음";
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.Now;
    public double DurationSeconds { get; init; }
    public RecordingMode Mode { get; init; }
    public bool IsFavorite { get; init; }
    public Guid? FolderId { get; init; }
    public DateTimeOffset? DeletedAt { get; init; }
    public bool IsRecording { get; init; }
    public string? Warning { get; init; }
    [JsonIgnore] public string DisplayTitle => (IsFavorite ? "★  " : "") + Title;
    [JsonIgnore] public string Subtitle => $"{CreatedAt.LocalDateTime:MM.dd HH:mm}  ·  {FormatTime(DurationSeconds)}  ·  {ModeLabel}";
    [JsonIgnore] public string ModeLabel => Mode switch
    {
        RecordingMode.Microphone => "마이크", RecordingMode.SystemAudio => "시스템 소리",
        RecordingMode.Mixed => "마이크 + 시스템", _ => "가져온 오디오"
    };
    public static string FormatTime(double seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return time.TotalHours >= 1 ? $"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}" : $"{time.Minutes:00}:{time.Seconds:00}";
    }
}

public sealed record AppSettings
{
    public string TranscriptionProvider { get; init; } = "whisper";
    public string SummaryProvider { get; init; } = "ollama";
    public string SpeechLanguage { get; init; } = "ko";
    public bool UseGpu { get; init; } = true;
    public string LocalSummaryModel { get; init; } = "qwen3.5:4b";
    public string OllamaAddress { get; init; } = "http://127.0.0.1:11434";
    public string QwenAsrModel { get; init; } = "1.7b";
    public string SummaryModel { get; init; } = "google/gemini-2.5-flash";
    public string TranscriptionModel { get; init; } = "openai/whisper-large-v3";
    public string Language { get; init; } = "ko";
    public string? ProtectedApiKey { get; init; }
    public string SharingServerUrl { get; init; } = "";
    public string? ProtectedSharingSyncToken { get; init; }
    public bool KeepRunningInTray { get; init; } = true;
    public bool EnableGlobalShortcuts { get; init; }
    public bool AutoGenerate { get; init; }
}

public sealed record TranscriptSegment(double StartSeconds, double EndSeconds, string Text, string? Speaker = null);
public sealed record TranscriptCache(string AudioHash, string Model, string Language, List<string> Chunks, bool Complete)
{
    public int SchemaVersion { get; init; } = 1;
    public string Provider { get; init; } = "openrouter";
    public string? Fingerprint { get; init; }
    public int ChunkSeconds { get; init; } = 120;
    public List<TranscriptSegment> Segments { get; init; } = [];
    public string Source { get; init; } = "audio";
    public string? OriginalFile { get; init; }
}
public sealed record MeetingNotes(string Markdown, DateTimeOffset CreatedAt, string Model, decimal? CostUsd)
{
    public string? TranscriptHash { get; init; }
}
public sealed record AudioDevice(string Id, string Name)
{
    public override string ToString() => Name;
}
