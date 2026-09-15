using System.Text;
using System.Text.RegularExpressions;

namespace NoteTaker.Core;

public sealed record SyncPending(string Kind, Guid Id, string Revision, int Attempts = 0, long RetryAfter = 0, string? Error = null);
public sealed record SyncState
{
    public int SchemaVersion { get; init; } = 1;
    public Dictionary<string, string> Acknowledged { get; init; } = [];
    public Dictionary<string, SyncPending> Pending { get; init; } = [];
    public long EditCursor { get; init; }
    public DateTimeOffset? LastCompletedAt { get; init; }
}
public sealed class SyncStateStore
{
    public string Path { get; }
    public SyncState State { get; private set; }
    public SyncStateStore(string root, Uri endpoint)
    {
        // Credentials never participate in filenames or persisted state. Changing servers gets independent acknowledgements/cursors.
        string workspace = SyncJson.Hash(Encoding.UTF8.GetBytes(endpoint.AbsoluteUri));
        Path = SyncFileTransaction.PathIn(root, ".sync/workspaces/" + workspace + "/state.json");
        if (File.Exists(Path) && new FileInfo(Path).Length > 32 * 1024 * 1024) throw new InvalidDataException("동기화 상태 파일이 너무 큽니다.");
        State = JsonDisk.Read<SyncState>(Path) ?? new();
        if (State.SchemaVersion != 1 || State.Acknowledged is null || State.Pending is null || State.Acknowledged.Count > 100000 || State.Pending.Count > 100000 || State.EditCursor < 0)
            throw new InvalidDataException("동기화 상태를 읽지 못했습니다. 기존 전송 기록은 유지됩니다.");
        foreach (var pair in State.Acknowledged) { RequireKey(pair.Key); RequireRevision(pair.Value); }
        foreach (var pair in State.Pending)
        {
            var item = pair.Value; RequireKey(pair.Key); RequireRevision(item.Revision);
            if (item.Id == Guid.Empty || Key(item.Kind, item.Id) != pair.Key || item.Attempts < 0 || item.RetryAfter < 0) throw new InvalidDataException("동기화 대기 기록이 올바르지 않습니다.");
        }
    }
    public static string Key(string kind, Guid id) => kind + ":" + SyncJson.Id(id);
    private static void RequireKey(string key)
    {
        if (!Regex.IsMatch(key, "^(recording|folder|notes|intelligence|edit):[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")) throw new InvalidDataException("동기화 상태 키가 올바르지 않습니다.");
    }
    private static void RequireRevision(string value) { if (!Regex.IsMatch(value, "^[0-9a-f]{64}$")) throw new InvalidDataException("동기화 상태 해시가 올바르지 않습니다."); }
    public void Observe(string kind, Guid id, string revision)
    {
        string key = Key(kind, id); RequireKey(key); RequireRevision(revision);
        if (State.Acknowledged.GetValueOrDefault(key) == revision) { if (State.Pending.Remove(key)) Save(); }
        else if (!State.Pending.TryGetValue(key, out var previous) || previous.Revision != revision) { State.Pending[key] = new(kind, id, revision); Save(); }
    }
    public void Acknowledge(string kind, Guid id, string revision)
    {
        string key = Key(kind, id); RequireKey(key); RequireRevision(revision);
        bool changed = State.Acknowledged.GetValueOrDefault(key) != revision; State.Acknowledged[key] = revision;
        if (State.Pending.TryGetValue(key, out var pending) && pending.Revision == revision) changed |= State.Pending.Remove(key);
        if (changed) Save();
    }
    public bool Ready(string kind, Guid id, bool force) => force || !State.Pending.TryGetValue(Key(kind, id), out var pending) || pending.RetryAfter <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public void Failed(string key, string message)
    {
        if (State.Pending.TryGetValue(key, out var pending))
        {
            int attempts = Math.Min(pending.Attempts + 1, 30);
            long delay = (long)Math.Min(3600, 5 * Math.Pow(2, Math.Min(attempts - 1, 10))) * 1000;
            State.Pending[key] = pending with { Attempts = attempts, RetryAfter = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + delay, Error = message };
            Save();
        }
    }
    public void Completed() { State = State with { LastCompletedAt = DateTimeOffset.UtcNow }; Save(); }
    private void Save() => JsonDisk.Write(Path, State);
}
