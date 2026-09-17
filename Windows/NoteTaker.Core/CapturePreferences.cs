namespace NoteTaker.Core;

public sealed record CapturePreferences
{
    public RecordingMode Mode { get; init; } = RecordingMode.Mixed;
    public string? MicrophoneId { get; init; }
    public string? OutputId { get; init; }
    public float MicrophoneGain { get; init; } = 1;
    public float SystemGain { get; init; } = 1;
    public static float Gain(float value) => float.IsFinite(value) ? Math.Clamp(value, 0, 2) : 1;
    public CapturePreferences Sanitized() => this with
    {
        Mode = Mode is RecordingMode.Microphone or RecordingMode.SystemAudio or RecordingMode.Mixed ? Mode : RecordingMode.Mixed,
        MicrophoneGain = Gain(MicrophoneGain), SystemGain = Gain(SystemGain)
    };
}

// Device identities and capture levels are local preferences, separate from synced AI settings.
public sealed class CapturePreferencesStore(string root)
{
    private readonly string path = Path.Combine(root, "capture-settings-local.json");
    public CapturePreferences Load() => (JsonDisk.Read<CapturePreferences>(path) ?? new()).Sanitized();
    public void Save(CapturePreferences preferences) => JsonDisk.Write(path, preferences.Sanitized());
}

public interface IConfigurableRecordingSession
{
    void ConfigureGains(float microphoneGain, float systemGain);
}

public interface IMicrophoneInputActivity
{
    double DetectedInputSeconds { get; }
    float InputRms { get; }
}
