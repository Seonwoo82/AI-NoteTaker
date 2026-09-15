namespace NoteTaker.Core;

public static class SyncAccountData
{
    private sealed record Device(Guid Id);
    public static Guid DeviceId(string root)
    {
        lock (JsonDisk.Gate)
        {
            string path = SyncFileTransaction.PathIn(root, ".sync/device.json");
            var device = JsonDisk.Read<Device>(path);
            if (device is null) { device = new(Guid.NewGuid()); JsonDisk.Write(path, device); }
            if (device.Id == Guid.Empty) throw new InvalidDataException("동기화 기기 ID가 올바르지 않습니다."); return device.Id;
        }
    }
    public static bool SamePreferences(AppSettings a, AppSettings b) => a.SummaryModel == b.SummaryModel && a.EnhancementModel == b.EnhancementModel &&
        a.TranscriptionModel == b.TranscriptionModel && a.Language == b.Language && a.AutoGenerate == b.AutoGenerate && a.TranscriptCleanupEnabled == b.TranscriptCleanupEnabled;
    public static SyncPreferences Preferences(AppSettings settings, long time) => new(1, settings.SummaryModel, settings.TranscriptionModel, settings.Language, settings.AutoGenerate,
        time, Guid.NewGuid(), settings.EnhancementModel, settings.TranscriptCleanupEnabled);
    public static AppSettings ReadSettings(string root)
    {
        lock (JsonDisk.Gate)
        {
            var settings = new SettingsStore(root).Load(); string path = Path.Combine(root, "settings.json");
            if (settings.SharedSyncPreferences is null && File.Exists(path) && !SamePreferences(settings, new()))
            {
                var preferences = Preferences(settings, Math.Max(0, new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds()));
                preferences.Validate(); settings = settings with { SharedSyncPreferences = preferences }; JsonDisk.Write(path, settings);
            }
            settings.SharedSyncPreferences?.Validate(); return settings;
        }
    }
    public static AppSettings ApplyPreferences(AppSettings current, SyncPreferences shared)
    {
        shared.Validate();
        return current with
        {
            SummaryModel = shared.ModelId, TranscriptionModel = shared.TranscriptionModelId, EnhancementModel = shared.EnhancementModelId ?? current.EnhancementModel,
            Language = shared.OutputLanguage, AutoGenerate = shared.AutoGenerate, TranscriptCleanupEnabled = shared.TranscriptCleanupEnabled ?? current.TranscriptCleanupEnabled,
            SummaryModelInfo = shared.ModelId == current.SummaryModel ? current.SummaryModelInfo : null,
            EnhancementModelInfo = shared.EnhancementModelId is null || shared.EnhancementModelId == current.EnhancementModel ? current.EnhancementModelInfo : null,
            SharedSyncPreferences = shared
        };
    }
    public static bool? KeyPresence(AppSettings settings)
    {
        if (settings.ProtectedApiKey is null) return false;
        try { return SettingsStore.ReadKey(settings).Length > 0; }
        catch (InvalidOperationException) { return null; }
    }
}
