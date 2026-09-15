using System.Text.Json;

namespace NoteTaker.Core;

public sealed partial class LibrarySyncEngine
{
    private string EditInbox => Path.Combine(Path.GetDirectoryName(state.Path)!, "edits-inbox.json");
    private List<SyncEditEntry> ReadInbox()
        => ReadInbox(EditInbox);
    private static List<SyncEditEntry> ReadInbox(string editInbox)
    {
        if (File.Exists(editInbox) && new FileInfo(editInbox).Length > 32 * 1024 * 1024) throw new InvalidDataException("수정 이력 수신함이 너무 큽니다.");
        var entries = JsonDisk.Read<List<SyncEditEntry>>(editInbox) ?? [];
        if (entries.Any(e => e?.Edit is null || e.Sequence is <= 0 or > 9007199254740991) || entries.Select(e => e.Edit.Id).Distinct().Count() != entries.Count)
            throw new InvalidDataException("저장된 수정 이력 수신함이 올바르지 않습니다.");
        foreach (var entry in entries) entry.Edit.Validate(); return entries;
    }
    private async Task SyncEditsAsync(IEnumerable<Guid> ids, bool force, CancellationToken token)
    {
        for (int count = 0; ; count++)
        {
            if (count == 1000) throw new InvalidDataException("수정 이력 페이지 제한을 초과했습니다.");
            long after = state.State.EditCursor; var page = await transport.EditsAsync(after, token);
            if (page.Entries is null || page.Entries.Count > 100) throw new InvalidDataException("수정 이력 목록 크기가 올바르지 않습니다.");
            long previous = after;
            foreach (var entry in page.Entries)
            {
                if (entry?.Edit is null || entry.Sequence <= previous || entry.Sequence > 9007199254740991) throw new InvalidDataException("수정 이력의 순서가 올바르지 않습니다.");
                entry.Edit.Validate(); previous = entry.Sequence;
            }
            if (page.NextCursor is { } next && (page.Entries.Count == 0 || next != previous)) throw new InvalidDataException("수정 이력 페이지가 진행되지 않습니다.");
            if (page.Entries.Count > 0)
            {
                lock (JsonDisk.Gate)
                {
                    var inbox = ReadInbox(); var seen = inbox.ToDictionary(e => e.Edit.Id);
                    foreach (var entry in page.Entries)
                    {
                        if (seen.TryGetValue(entry.Edit.Id, out var existing) && existing != entry) throw new InvalidDataException("같은 수정 ID의 이력이 충돌합니다.");
                        if (!seen.ContainsKey(entry.Edit.Id)) { inbox.Add(entry); seen.Add(entry.Edit.Id, entry); }
                    }
                    string inboxPath = Path.GetRelativePath(library.Root, EditInbox), statePath = Path.GetRelativePath(library.Root, state.Path);
                    var expected = SyncFileTransaction.Snapshot(library.Root, [inboxPath, statePath]);
                    var nextState = state.State with { EditCursor = previous };
                    byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(inbox, JsonDisk.Options);
                    if (bytes.Length > 32 * 1024 * 1024) throw new InvalidDataException("수정 이력 수신함이 너무 큽니다.");
                    SyncDocumentStore.ApplyFiles(library.Root, expected, new() { [inboxPath] = bytes, [statePath] = JsonSerializer.SerializeToUtf8Bytes(nextState, JsonDisk.Options) }, token);
                    state.AcceptCommitted(nextState);
                }
            }
            ApplyInbox(token);
            if (page.NextCursor is null) break;
        }
        foreach (var id in ids)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var recording = SyncRecordings.Read(library, id); if (recording is null || recording.IsRecording) continue;
                state.ForgetObsolete(recording);
                if (recording.DeletedAt is not null || state.State.Pending.ContainsKey(SyncStateStore.Key("recording", id))) continue;
                foreach (var edit in new MeetingWorkspaceStore(library).Edits(id).Where(e => e.AudioVersion == recording.AudioVersion))
                {
                    string revision = Revision(edit), key = SyncStateStore.Key("edit", edit.Id); state.Observe("edit", edit.Id, revision, id, recording.AudioVersion);
                    if (state.State.Acknowledged.GetValueOrDefault(key) == revision || !state.Ready("edit", edit.Id, force)) continue;
                    try { await transport.PutEditAsync(edit, token); uploaded++; state.Acknowledge("edit", edit.Id, revision); }
                    catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(key, ex); }
                }
            }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue("edits:" + SyncJson.Id(id), ex); }
        }
    }
    private void ApplyInbox(CancellationToken token)
    {
        foreach (var group in ReadInbox().GroupBy(e => e.Edit.RecordingId))
        {
            try
            {
                lock (JsonDisk.Gate)
                {
                    token.ThrowIfCancellationRequested(); var recording = SyncRecordings.Read(library, group.Key); if (recording is null || recording.IsRecording) continue;
                    var entries = group.Where(e => e.Edit.AudioVersion == recording.AudioVersion).ToArray(); if (entries.Length == 0) continue;
                    string editPath = $"Recordings/{recording.Id:D}/meeting-edits-local.json", inboxPath = Path.GetRelativePath(library.Root, EditInbox), statePath = Path.GetRelativePath(library.Root, state.Path);
                    var expected = SyncFileTransaction.Snapshot(library.Root, [editPath, inboxPath, statePath, SyncRecordings.MetadataPath(recording.Id)]);
                    var edits = new MeetingWorkspaceStore(library).Edits(recording.Id).ToList(); var byId = edits.ToDictionary(e => e.Id);
                    int added = 0;
                    var acknowledged = new Dictionary<string, string>(state.State.Acknowledged); var pending = new Dictionary<string, SyncPending>(state.State.Pending);
                    foreach (var entry in entries)
                    {
                        if (byId.TryGetValue(entry.Edit.Id, out var old) && old != entry.Edit) throw new InvalidDataException("같은 수정 ID가 서로 다른 값을 가리킵니다.");
                        if (!byId.ContainsKey(entry.Edit.Id)) { edits.Add(entry.Edit); byId.Add(entry.Edit.Id, entry.Edit); added++; }
                        string key = SyncStateStore.Key("edit", entry.Edit.Id), revision = Revision(entry.Edit); acknowledged[key] = revision;
                        if (pending.TryGetValue(key, out var item) && item.Revision == revision) pending.Remove(key);
                    }
                    byte[] editsBytes = JsonSerializer.SerializeToUtf8Bytes(edits, JsonDisk.Options); if (editsBytes.Length > 16 * 1024 * 1024) throw new InvalidDataException("수정 이력 파일이 너무 큽니다.");
                    var applied = entries.Select(e => e.Edit.Id).ToHashSet(); var inbox = ReadInbox().Where(e => !applied.Contains(e.Edit.Id)).ToList();
                    var next = state.State with { Acknowledged = acknowledged, Pending = pending };
                    SyncDocumentStore.ApplyFiles(library.Root, expected, new() { [editPath] = editsBytes, [inboxPath] = JsonSerializer.SerializeToUtf8Bytes(inbox, JsonDisk.Options), [statePath] = JsonSerializer.SerializeToUtf8Bytes(next, JsonDisk.Options) }, token);
                    state.AcceptCommitted(next); downloaded += added;
                }
            }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue("edits:" + SyncJson.Id(group.Key), ex); }
        }
    }
}
