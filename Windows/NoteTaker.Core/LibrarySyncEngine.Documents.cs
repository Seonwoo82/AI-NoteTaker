namespace NoteTaker.Core;

public sealed partial class LibrarySyncEngine
{
    private async Task SyncDocumentsAsync(IEnumerable<Guid> ids, bool intelligence, bool force, CancellationToken token)
    {
        string kind = intelligence ? "intelligence" : "notes"; var store = new SyncDocumentStore(library);
        var remote = await DocumentIndexAsync(intelligence, token);
        foreach (var id in ids.OrderBy(SyncJson.Id, StringComparer.Ordinal))
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var recording = SyncRecordings.Read(library, id); if (recording is null || recording.IsRecording) continue;
                state.ForgetObsolete(recording); if (recording.DeletedAt is not null) { state.Forget(kind, id); continue; }
                // Metadata must first be accepted, including the matching audio version.
                if (state.State.Pending.ContainsKey(SyncStateStore.Key("recording", id))) continue;
                var local = await store.ReadAsync(recording, intelligence, token);
                var descriptor = remote.GetValueOrDefault((id, recording.AudioVersion));
                if (local is not null) state.Observe(kind, id, local.Descriptor.Revision, id, recording.AudioVersion);
                if (local is null && descriptor is null) { state.Forget(kind, id); continue; }
                if (!state.Ready(kind, id, force)) continue;
                SyncArtifact? server = null;
                if (descriptor is not null && descriptor != local?.Descriptor)
                {
                    if (local is null) state.Observe(kind, id, descriptor.Revision, id, recording.AudioVersion);
                    var expected = local?.Expected ?? store.Snapshot(recording, intelligence);
                    if (!intelligence && local is null) expected[$"Recordings/{id:D}/audio.wav"] = (await MeetingNotesService.AudioHashAsync(library.AudioPath(id), token)).ToLowerInvariant();
                    var bytes = await transport.DownloadDocumentAsync(descriptor, intelligence, token);
                    server = SyncDocumentStore.Decode(recording, intelligence, bytes, descriptor, expected);
                    bool serverWins = local is null || (intelligence ? Wins(server.Intelligence!, local.Intelligence!) : descriptor.Wins(local.Descriptor));
                    if (serverWins)
                    {
                        state.Observe(kind, id, descriptor.Revision, id, recording.AudioVersion); await store.ApplyAsync(recording, server, intelligence, token); downloaded++;
                        state.Acknowledge(kind, id, descriptor.Revision); continue;
                    }
                }
                if (local is null) continue;
                if (descriptor == local.Descriptor) { state.Acknowledge(kind, id, local.Descriptor.Revision); continue; }
                if (server is not null && intelligence && !Wins(local.Intelligence!, server.Intelligence!))
                    throw new InvalidDataException("동일한 회의 분석 수정 ID에 서로 다른 내용이 있습니다. 기존 문서는 보존됩니다.");
                SyncFileTransaction.RequireCurrent(library.Root, local.Expected);
                var winner = await transport.UploadDocumentAsync(id, recording.AudioVersion, local.Bytes, intelligence, token); uploaded++;
                if (winner == local.Descriptor) state.Acknowledge(kind, id, winner.Revision);
                else
                {
                    var bytes = await transport.DownloadDocumentAsync(winner, intelligence, token);
                    var returned = SyncDocumentStore.Decode(recording, intelligence, bytes, winner, local.Expected);
                    if (intelligence && !Wins(returned.Intelligence!, local.Intelligence!)) throw new InvalidDataException("서버의 회의 분석 승자를 확인하지 못했습니다.");
                    await store.ApplyAsync(recording, returned, intelligence, token); downloaded++; state.Acknowledge(kind, id, winner.Revision);
                }
                var latest = await store.ReadAsync(recording, intelligence, token);
                if (latest is not null) state.Observe(kind, id, latest.Descriptor.Revision, id, recording.AudioVersion);
            }
            catch (Exception ex) when (Recoverable(ex, token)) { AddIssue(SyncStateStore.Key(kind, id), ex); }
        }
    }
    private static bool Wins(MeetingIntelligenceDocument first, MeetingIntelligenceDocument second) => SyncJson.Wins(first.ModifiedAt, first.MutationId, second.ModifiedAt, second.MutationId);
    private async Task<Dictionary<(Guid, int), SyncDescriptor>> DocumentIndexAsync(bool intelligence, CancellationToken token)
    {
        var result = new Dictionary<(Guid, int), SyncDescriptor>(); string? cursor = null;
        int limit = intelligence ? SyncJson.IntelligenceLimit : SyncJson.NotesLimit;
        for (int page = 0; page < 1000; page++)
        {
            List<SyncDescriptor> descriptors; string? next;
            if (intelligence) { var value = await transport.IntelligenceAsync(cursor, token); descriptors = value.Intelligence; next = value.NextCursor; }
            else { var value = await transport.NotesAsync(cursor, token); descriptors = value.Notes; next = value.NextCursor; }
            if (descriptors is null || descriptors.Count > 100) throw new InvalidDataException("동기화 문서 목록 크기가 올바르지 않습니다.");
            string? previous = cursor;
            foreach (var descriptor in descriptors)
            {
                if (descriptor is null) throw new InvalidDataException("문서 설명자가 비어 있습니다."); descriptor.Validate(limit);
                string key = SyncJson.Id(descriptor.RecordingId) + ":" + descriptor.AudioVersion.ToString("D10", System.Globalization.CultureInfo.InvariantCulture);
                if (previous is not null && string.CompareOrdinal(key, previous) <= 0 || !result.TryAdd((descriptor.RecordingId, descriptor.AudioVersion), descriptor)) throw new InvalidDataException("동기화 문서 목록이 중복되거나 순서가 올바르지 않습니다."); previous = key;
            }
            if (next is null) return result;
            if (descriptors.Count == 0 || next != previous || next == cursor) throw new InvalidDataException("동기화 문서 목록이 진행되지 않습니다."); cursor = next;
        }
        throw new InvalidDataException("동기화 문서 목록의 페이지 제한을 초과했습니다.");
    }
    private async Task ObserveDocumentsAsync(Recording recording, CancellationToken token)
    {
        if (recording.DeletedAt is not null) return;
        foreach (bool intelligence in new[] { false, true })
        {
            try
            {
                var artifact = await new SyncDocumentStore(library).ReadAsync(recording, intelligence, token);
                if (artifact is not null) state.Observe(intelligence ? "intelligence" : "notes", recording.Id, artifact.Descriptor.Revision, recording.Id, recording.AudioVersion);
            }
            // Report invalid artifacts after metadata reconciliation, which can replace an obsolete audio version and its old caches.
            catch (Exception ex) when (Recoverable(ex, token)) { }
        }
        try
        {
            foreach (var edit in new MeetingWorkspaceStore(library).Edits(recording.Id).Where(e => e.AudioVersion == recording.AudioVersion))
                state.Observe("edit", edit.Id, Revision(edit), recording.Id, recording.AudioVersion);
        }
        catch (Exception ex) when (Recoverable(ex, token)) { }
    }
}
