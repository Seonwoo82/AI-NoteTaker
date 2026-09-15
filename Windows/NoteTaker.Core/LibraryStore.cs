using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Security.Cryptography;
using NAudio.Wave;

namespace NoteTaker.Core;

public static class JsonDisk
{
    // Short filesystem commits share this gate; network/model work never holds it.
    public static object Gate { get; } = new();
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public static T? Read<T>(string path)
    {
        lock (Gate) return File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options) : default;
    }

    public static void Write<T>(string path, T value)
    {
        lock (Gate) WriteLocked(path, value);
    }
    private static void WriteLocked<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, value, Options);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public sealed class LibraryStore
{
    public string Root { get; }
    public List<string> LoadWarnings { get; } = [];
    public LibraryStore(string? root = null)
    {
        Root = Path.GetFullPath(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AI-NoteTaker"));
        Directory.CreateDirectory(Path.Combine(Root, "Recordings"));
    }
    public string DirectoryFor(Guid id) => Path.Combine(Root, "Recordings", id.ToString("D"));
    public string AudioPath(Guid id) => Path.Combine(DirectoryFor(id), "audio.wav");
    public string TranscriptPath(Guid id) => Path.Combine(DirectoryFor(id), "transcript.json");
    public string NotesPath(Guid id) => Path.Combine(DirectoryFor(id), "notes.json");
    public void Save(Recording recording)
    {
        lock (JsonDisk.Gate)
        {
            string path = Path.Combine(DirectoryFor(recording.Id), "meta.json");
            var previous = JsonDisk.Read<Recording>(path);
            var wire = SyncRecordings.FromLocal(recording, previous?.SyncMetadata ?? recording.SyncMetadata,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), stamp: true);
            JsonDisk.Write(path, recording with { SyncMetadata = wire });
        }
    }

    public IReadOnlyList<Recording> Load()
    {
        lock (JsonDisk.Gate) return LoadLocked();
    }
    private IReadOnlyList<Recording> LoadLocked()
    {
        SyncFileTransaction.Recover(Root);
        LoadWarnings.Clear();
        var result = new List<Recording>();
        foreach (var directory in Directory.EnumerateDirectories(Path.Combine(Root, "Recordings")))
        {
            if (!Guid.TryParse(Path.GetFileName(directory), out var id)) continue;
            try
            {
                var recording = JsonDisk.Read<Recording>(Path.Combine(directory, "meta.json"));
                if (recording is null) continue;
                if (recording.Id != id || recording.SchemaVersion != 1 || recording.Title is null || !Enum.IsDefined(recording.Mode) || !double.IsFinite(recording.DurationSeconds) || recording.DurationSeconds < 0)
                    throw new InvalidDataException("지원하지 않는 메타데이터입니다.");
                if (recording.IsRecording)
                {
                    if (File.Exists(AudioPath(id)))
                    {
                        AudioFiles.RepairInterruptedWave(AudioPath(id));
                        using var audio = new WaveFileReader(AudioPath(id));
                        recording = recording with { IsRecording = false, DurationSeconds = audio.TotalTime.TotalSeconds, Warning = "중단된 녹음을 복구했습니다. 마지막 부분을 확인해 주세요." };
                    }
                    else recording = recording with { IsRecording = false, Warning = "녹음이 중단되어 오디오 파일을 찾을 수 없습니다." };
                    Save(recording);
                }
                result.Add(recording);
            }
            catch (Exception ex) when (ex is IOException or JsonException or InvalidDataException or UnauthorizedAccessException)
            {
                LoadWarnings.Add($"{id}: 읽을 수 없는 녹음이 있습니다. 원본 파일은 보존했습니다.");
            }
        }
        return result.OrderByDescending(x => x.CreatedAt).ToList();
    }

    public async Task<Recording> ImportAsync(string source, CancellationToken token = default)
    {
        var record = new Recording { Title = Path.GetFileNameWithoutExtension(source), Mode = RecordingMode.Imported };
        var directory = DirectoryFor(record.Id);
        Directory.CreateDirectory(directory);
        var partial = Path.Combine(directory, "import.wav.tmp");
        try
        {
            var duration = await Task.Run(() => AudioFiles.ConvertToWave(source, partial, token), token);
            token.ThrowIfCancellationRequested();
            File.Move(partial, AudioPath(record.Id));
            record = record with { DurationSeconds = duration };
            Save(record);
            return record;
        }
        finally { if (File.Exists(partial)) File.Delete(partial); }
    }
}

public sealed class SettingsStore(string root)
{
    private readonly string path = Path.Combine(root, "settings.json");
    public AppSettings Load()
    {
        if (!File.Exists(path)) return new();
        var settings = JsonDisk.Read<AppSettings>(path) ?? new();
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        // Existing installations retain their chosen cloud workflow. New installs use local AI.
        if (!document.RootElement.TryGetProperty("transcriptionProvider", out _))
            settings = settings with { TranscriptionProvider = "openrouter", SummaryProvider = "openrouter" };
        return settings;
    }
    public void Save(AppSettings settings)
    {
        lock (JsonDisk.Gate)
        {
            var previous = Load();
            var shared = previous.SharedSyncPreferences;
            if (!SyncAccountData.SamePreferences(settings, previous)) shared = SyncAccountData.Preferences(settings,
                Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), shared is null ? 0 : checked(shared.ModifiedAt + 1)));
            JsonDisk.Write(path, settings with { SharedSyncPreferences = shared });
        }
    }
    public static string? ProtectKey(string key) => string.IsNullOrWhiteSpace(key) ? null : Convert.ToBase64String(
        ProtectedData.Protect(Encoding.UTF8.GetBytes(key.Trim()), null, DataProtectionScope.CurrentUser));
    public static string ReadKey(AppSettings settings)
    {
        if (string.IsNullOrEmpty(settings.ProtectedApiKey)) return "";
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(settings.ProtectedApiKey), null, DataProtectionScope.CurrentUser)); }
        catch (Exception ex) when (ex is CryptographicException or FormatException)
        { throw new InvalidOperationException("저장된 API 키를 읽을 수 없습니다. 이 Windows 계정에서 키를 다시 저장해 주세요."); }
    }
    public static string ReadSharingToken(AppSettings settings)
    {
        if (string.IsNullOrEmpty(settings.ProtectedSharingSyncToken))
            throw new InvalidOperationException("웹 공유 동기화 토큰을 설정해 주세요.");
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(settings.ProtectedSharingSyncToken), null, DataProtectionScope.CurrentUser)); }
        catch (Exception ex) when (ex is CryptographicException or FormatException)
        { throw new InvalidOperationException("저장된 웹 공유 토큰을 읽을 수 없습니다. 이 Windows 계정에서 토큰을 다시 저장해 주세요."); }
    }
}
