using System.Collections.Concurrent;
using System.Text.Json;

namespace NoteTaker.Core;

public sealed record SyncIssue(string Item, string Message);
public sealed record LibrarySyncResult(int Uploaded, int Downloaded, int Pending, IReadOnlyList<SyncIssue> Issues, bool OtherDevicesHaveApiKey = false);
public sealed record LibrarySyncStatus(DateTimeOffset? LastCompletedAt, int Pending, bool OtherDevicesHaveApiKey, IReadOnlyList<SyncIssue> Issues);
internal sealed record SyncAudioIdentity(int AudioVersion, string WavHash, string M4aHash, string M4aPath);

/// <summary>Library metadata/audio/folder reconciliation. Document and settings phases attach to the same durable state.</summary>
public sealed partial class LibrarySyncEngine : IDisposable
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Runs = new(StringComparer.OrdinalIgnoreCase);
    private readonly LibraryStore library;
    private readonly SyncConfiguration configuration;
    private readonly SyncTransport transport;
    private SyncStateStore state = null!;
    private readonly List<SyncIssue> issues = [];
    private int uploaded, downloaded;
    public LibrarySyncEngine(LibraryStore library, SyncConfiguration configuration, HttpMessageHandler? handler = null)
    {
        this.library = library; this.configuration = configuration; transport = new(configuration, handler);
    }
    public static LibrarySyncStatus ReadStatus(string root, Uri endpoint)
    {
        lock (JsonDisk.Gate)
        {
            var store = new SyncStateStore(root, endpoint);
            int inbox = ReadInbox(Path.Combine(Path.GetDirectoryName(store.Path)!, "edits-inbox.json")).Count;
            return new(store.State.LastCompletedAt, store.State.Pending.Count + inbox, store.State.OtherDevicesHaveApiKey,
                store.State.Pending.Where(p => p.Value.Error is not null).Select(p => new SyncIssue(p.Key, p.Value.Error!)).ToArray());
        }
    }
    public async Task<LibrarySyncResult> RunAsync(IProgress<string>? progress = null, CancellationToken token = default, bool force = true)
    {
        var gate = Runs.GetOrAdd(library.Root, _ => new(1)); await gate.WaitAsync(token);
        try
        {
            issues.Clear(); uploaded = downloaded = 0; SyncFileTransaction.Recover(library.Root); state = new(library.Root, configuration.Endpoint);
            var ids = Directory.EnumerateDirectories(Path.Combine(library.Root, "Recordings")).Select(Path.GetFileName).Select(n => Guid.TryParse(n, out var id) ? id : Guid.Empty).Where(id => id != Guid.Empty).ToHashSet();
            foreach (var id in ids)
            {
                token.ThrowIfCancellationRequested();
                try { var local = SyncRecordings.Read(library, id); if (local is { IsRecording: false }) { state.Observe("recording", id, Revision(local.SyncMetadata!)); await ObserveDocumentsAsync(local, token); } }
                catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(SyncStateStore.Key("recording", id), ex); }
            }
            var folders = new RecordingFolderStore(library.Root);
            foreach (var folder in folders.All) state.Observe("folder", folder.Id, Revision(folder));
            if (folders.LoadError is not null) issues.Add(new("folders", folders.LoadError));
            ObserveAccount();
            progress?.Report("동기화 서버 연결 확인…");
            try { await transport.HealthAsync(token); }
            catch (Exception ex) when (Recoverable(ex, token))
            {
                string message = ErrorMessage(ex); issues.Add(new("server", message));
                foreach (string key in state.State.Pending.Keys.ToArray()) state.Failed(key, message);
                return Result();
            }
            if (folders.LoadError is null)
            {
                try { await SyncFoldersAsync(folders, force, token); }
                catch (Exception ex) when (Recoverable(ex, token)) { AddIssue("folders", ex); }
            }
            Dictionary<Guid, SyncRecording> remote;
            try { remote = await ReadIndexAsync(async (cursor, ct) => { var p = await transport.RecordingsAsync(cursor, ct); return (p.Recordings, p.NextCursor); }, r => r.Id, r => r.Validate(), token); }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue("recordings", ex); return Result(); }
            ids.UnionWith(remote.Keys);
            foreach (Guid id in ids.OrderBy(SyncJson.Id, StringComparer.Ordinal))
            {
                token.ThrowIfCancellationRequested(); progress?.Report($"녹음 동기화 · {uploaded + downloaded}개 반영");
                try { await SyncRecordingAsync(id, remote.GetValueOrDefault(id), force, token); }
                catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(SyncStateStore.Key("recording", id), ex); }
            }
            foreach (bool intelligence in new[] { false, true })
            {
                try { await SyncDocumentsAsync(ids, intelligence, force, token); }
                catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(intelligence ? "intelligence" : "notes", ex); }
            }
            try { await SyncEditsAsync(ids, force, token); }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue("edits", ex); }
            try { await SyncProfileAsync(force, token); }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(SyncStateStore.Key("profile", deviceId), ex); }
            try { await SyncSettingsAsync(force, token); }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(SyncStateStore.Key("settings", deviceId), ex); }
            if (issues.Count == 0 && PendingCount() == 0) state.Completed();
            return Result();
        }
        finally { gate.Release(); }
    }
    private int PendingCount()
    {
        try { return state.State.Pending.Count + ReadInbox().Count; }
        catch (Exception ex) when (Recoverable(ex, default)) { return state.State.Pending.Count; }
    }
    private LibrarySyncResult Result() => new(uploaded, downloaded, PendingCount(), issues.ToArray(), state.State.OtherDevicesHaveApiKey);
    private static bool Recoverable(Exception ex, CancellationToken token) => ex is IOException or InvalidDataException or HttpRequestException or InvalidOperationException or JsonException or UnauthorizedAccessException or ArgumentException || ex is OperationCanceledException && !token.IsCancellationRequested;
    private static string ErrorMessage(Exception ex) => ex is SyncHttpException or SyncLocalConflictException ? ex.Message : ex is HttpRequestException ? "서버에 연결하지 못했습니다. 연결 후 다시 시도합니다." : "자료를 적용하지 못했습니다. 기존 파일을 보존했으며 다시 비교해야 합니다.";
    private void AddIssue(string key, Exception ex) { string message = ErrorMessage(ex); issues.Add(new(key, message)); state.Failed(key, message); }
    private static string Revision<T>(T value) => SyncJson.Hash(SyncJson.Encode(value, SyncJson.MetadataLimit));
    private static async Task<Dictionary<Guid, T>> ReadIndexAsync<T>(Func<string?, CancellationToken, Task<(List<T> Items, string? Next)>> fetch,
        Func<T, Guid> id, Action<T> validate, CancellationToken token)
    {
        var result = new Dictionary<Guid, T>(); string? cursor = null;
        for (int page = 0; page < 1000; page++)
        {
            token.ThrowIfCancellationRequested(); var response = await fetch(cursor, token);
            if (response.Items is null || response.Items.Count > 100) throw new InvalidDataException("동기화 목록 크기가 올바르지 않습니다.");
            string? previous = cursor;
            foreach (var item in response.Items)
            {
                if (item is null) throw new InvalidDataException("동기화 목록에 비어 있는 항목이 있습니다.");
                validate(item); string key = SyncJson.Id(id(item));
                if (previous is not null && string.CompareOrdinal(key, previous) <= 0 || !result.TryAdd(id(item), item)) throw new InvalidDataException("동기화 목록의 순서 또는 ID가 중복되었습니다.");
                previous = key;
            }
            if (response.Next is null) return result;
            if (response.Items.Count == 0 || response.Next != previous || response.Next == cursor) throw new InvalidDataException("동기화 목록의 다음 페이지가 올바르지 않습니다.");
            cursor = response.Next;
        }
        throw new InvalidDataException("동기화 목록의 페이지 제한을 초과했습니다.");
    }
    private async Task SyncFoldersAsync(RecordingFolderStore store, bool force, CancellationToken token)
    {
        var remote = await ReadIndexAsync(async (cursor, ct) => { var page = await transport.FoldersAsync(cursor, ct); return (page.Folders, page.NextCursor); }, f => f.Id, RecordingFolderStore.Validate, token);
        var ids = store.All.Select(f => f.Id).Union(remote.Keys).OrderBy(SyncJson.Id, StringComparer.Ordinal);
        foreach (var id in ids)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var local = store.All.FirstOrDefault(f => f.Id == id); var server = remote.GetValueOrDefault(id);
                if (server is not null && local is not null && server.SortOrder is null) server = server with { SortOrder = local.SortOrder };
                if (local is not null && (server is null || SyncJson.Wins(local.ModifiedAt, Guid.Parse(local.MutationID), server.ModifiedAt, Guid.Parse(server.MutationID))))
                {
                    state.Observe("folder", id, Revision(local)); if (!state.Ready("folder", id, force)) continue;
                    server = await transport.PutFolderAsync(local, token); uploaded++;
                    if (server.SortOrder is null) server = server with { SortOrder = local.SortOrder };
                }
                if (server is not null)
                {
                    if (local is null || SyncJson.Wins(server.ModifiedAt, Guid.Parse(server.MutationID), local.ModifiedAt, Guid.Parse(local.MutationID))) downloaded++;
                    store.ApplyRemote(server); state.Acknowledge("folder", id, Revision(server));
                    state.Observe("folder", id, Revision(store.All.Single(f => f.Id == id)));
                }
            }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(SyncStateStore.Key("folder", id), ex); }
        }
    }
    private async Task SyncRecordingAsync(Guid id, SyncRecording? remote, bool force, CancellationToken token)
    {
        Recording? local; Dictionary<string, string?> expected;
        lock (JsonDisk.Gate)
        {
            local = SyncRecordings.Read(library, id); if (local?.IsRecording == true) return;
            expected = SyncFileTransaction.Snapshot(library.Root, [SyncRecordings.MetadataPath(id)]);
        }
        SyncRecording? wire = local?.SyncMetadata;
        if (wire is not null && wire.Wins(remote))
        {
            state.Observe("recording", id, Revision(wire)); if (!state.Ready("recording", id, force)) return;
            if (wire.DeletedAt is null && (remote?.AudioVersion != wire.AudioVersion || remote?.DeletedAt is not null))
            {
                string audio = await UploadAudioPathAsync(local!, token);
                SyncFileTransaction.RequireCurrent(library.Root, expected);
                await transport.UploadAudioAsync(wire, audio, token);
            }
            SyncFileTransaction.RequireCurrent(library.Root, expected);
            remote = await transport.PutRecordingAsync(wire, token); uploaded++;
            // A title/folder edit during the request remains pending under its newer clock.
            local = SyncRecordings.Read(library, id); wire = local?.SyncMetadata;
        }
        if (remote is null) return;
        bool missingAudio = remote.DeletedAt is null && !File.Exists(library.AudioPath(id));
        if (wire is null || remote.Wins(wire) || (remote.ModifiedAt == wire.ModifiedAt && remote.MutationId == wire.MutationId && missingAudio))
        {
            state.Observe("recording", id, Revision(remote)); if (!state.Ready("recording", id, force)) return;
            await AdoptRecordingAsync(remote, local, token); downloaded++;
        }
        state.Acknowledge("recording", id, Revision(remote));
        var current = SyncRecordings.Read(library, id);
        if (current is { IsRecording: false }) state.Observe("recording", id, Revision(current.SyncMetadata!));
    }
    private async Task<string> UploadAudioPathAsync(Recording recording, CancellationToken token)
    {
        string hash = (await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token)).ToLowerInvariant();
        string mapPath = SyncFileTransaction.PathIn(library.Root, $"Recordings/{recording.Id:D}/sync-audio-local.json");
        var identity = JsonDisk.Read<SyncAudioIdentity>(mapPath);
        if (identity?.AudioVersion == recording.AudioVersion)
        {
            if (identity.WavHash != hash) throw new InvalidDataException("동일 버전의 녹음 내용이 변경됐습니다. 기존 서버 오디오를 덮어쓰지 않습니다.");
            string original = SyncFileTransaction.PathIn(library.Root, identity.M4aPath);
            if (SyncFileTransaction.Revision(original) == identity.M4aHash) return original;
        }
        string relative = $".sync/outgoing/{recording.Id:D}-{recording.AudioVersion}-{hash}.m4a";
        string target = SyncFileTransaction.PathIn(library.Root, relative);
        await SyncAudio.EncodeAsync(library.AudioPath(recording.Id), target, token);
        if ((await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token)).ToLowerInvariant() != hash) throw new SyncLocalConflictException();
        JsonDisk.Write(mapPath, new SyncAudioIdentity(recording.AudioVersion, hash, SyncFileTransaction.Revision(target)!, relative)); return target;
    }
    private async Task AdoptRecordingAsync(SyncRecording remote, Recording? previous, CancellationToken token)
    {
        bool audioChanged = previous?.AudioVersion != remote.AudioVersion;
        bool download = remote.DeletedAt is null && (audioChanged || !File.Exists(library.AudioPath(remote.Id)));
        string prefix = $"Recordings/{remote.Id:D}/";
        string[] caches = ["transcript.json", "notes.json", "meeting-intelligence.json", "meeting-edits-local.json", "participant-transcript-local.json", "speaker-acoustic-local.json", "sync-notes-local.json", "sync-intelligence-local.json"];
        var paths = new List<string> { prefix + "meta.json" };
        if (download || audioChanged) paths.AddRange([prefix + "audio.wav", prefix + "sync-audio.m4a", prefix + "sync-audio-local.json"]);
        if (audioChanged) paths.AddRange(caches.Select(c => prefix + c));
        Dictionary<string, string?> expected;
        lock (JsonDisk.Gate)
        {
            var current = SyncRecordings.Read(library, remote.Id);
            if (current?.IsRecording == true || !JsonSerializer.SerializeToUtf8Bytes(current, JsonDisk.Options).SequenceEqual(JsonSerializer.SerializeToUtf8Bytes(previous, JsonDisk.Options))) throw new SyncLocalConflictException();
            expected = SyncFileTransaction.Snapshot(library.Root, paths);
        }
        string incoming = SyncFileTransaction.PathIn(library.Root, ".sync/incoming/" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(incoming);
        var changes = new List<SyncFileChange>(); var temporary = new List<string>();
        try
        {
            if (download)
            {
                string m4a = Path.Combine(incoming, "audio.m4a"), wav = Path.Combine(incoming, "audio.wav"); temporary.AddRange([m4a, wav]);
                await transport.DownloadAudioAsync(remote, m4a, token); double duration = await SyncAudio.DecodeAsync(m4a, wav, token);
                if (Math.Abs(duration - remote.Duration) > 2) throw new InvalidDataException("서버 녹음 길이가 메타데이터와 일치하지 않습니다.");
                string mapping = Path.Combine(incoming, "mapping.json"); temporary.Add(mapping);
                JsonDisk.Write(mapping, new SyncAudioIdentity(remote.AudioVersion, SyncFileTransaction.Revision(wav)!, SyncFileTransaction.Revision(m4a)!, prefix + "sync-audio.m4a"));
                changes.AddRange([new(prefix + "audio.wav", wav), new(prefix + "sync-audio.m4a", m4a), new(prefix + "sync-audio-local.json", mapping)]);
            }
            else if (audioChanged)
            {
                // A newer tombstone can arrive without its audio. Archive the older version instead of presenting it as the new one on restore.
                foreach (string old in new[] { "audio.wav", "sync-audio.m4a", "sync-audio-local.json" }) if (expected[prefix + old] is not null) changes.Add(new(prefix + old, null));
            }
            if (audioChanged) foreach (var cache in caches) if (expected[prefix + cache] is not null) changes.Add(new(prefix + cache, null));
            string metadata = Path.Combine(incoming, "meta.json"); temporary.Add(metadata); JsonDisk.Write(metadata, SyncRecordings.ToLocal(remote, previous));
            changes.Add(new(prefix + "meta.json", metadata)); // Publish metadata last; startup recovery completes an interrupted application first.
            SyncFileTransaction.Commit(library.Root, expected, changes, token);
        }
        finally { foreach (string file in temporary) if (File.Exists(file)) File.Delete(file); if (!Directory.EnumerateFileSystemEntries(incoming).Any()) Directory.Delete(incoming); }
    }
    public void Dispose() => transport.Dispose();
}
