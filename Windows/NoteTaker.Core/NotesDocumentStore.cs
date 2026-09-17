using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;

namespace NoteTaker.Core;

public sealed record NotesSourceSnapshot(string AudioHash, Dictionary<string, string?> Revisions);
public sealed class NotesDocumentStore(LibraryStore library)
{
    private readonly object gate = JsonDisk.Gate;
    private Dictionary<string, string?> Revisions(Recording recording)
    {
        string directory = library.DirectoryFor(recording.Id);
        string[] paths = [Path.Combine(directory, "meta.json"), library.NotesPath(recording.Id), library.TranscriptPath(recording.Id), Path.Combine(directory, "meeting-intelligence.json"), Path.Combine(directory, "meeting-edits-local.json"), Path.Combine(library.Root, "meeting-profile.json")];
        return paths.ToDictionary(p => p, Revision, StringComparer.OrdinalIgnoreCase);
    }
    private static string? Revision(string path)
    {
        if (!File.Exists(path)) return null;
        if (new FileInfo(path).Length > 64 * 1024 * 1024) throw new InvalidDataException("회의 자료가 처리 범위를 초과했습니다. 기존 자료는 유지됩니다.");
        return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
    }
    public MeetingNotes? Load(Recording recording)
    {
        _ = Revision(library.NotesPath(recording.Id)); var notes = JsonDisk.Read<MeetingNotes>(library.NotesPath(recording.Id));
        if (notes is not null) Validate(notes); return notes;
    }
    private void RequireRecording(Recording recording)
    {
        var current = JsonDisk.Read<Recording>(Path.Combine(library.DirectoryFor(recording.Id), "meta.json"));
        if (current is null || current.Id != recording.Id || current.AudioVersion != recording.AudioVersion || current.DurationSeconds != recording.DurationSeconds || current.IsRecording || current.DeletedAt is not null)
            throw new InvalidOperationException("녹음 정보가 변경됐거나 삭제됐습니다. 현재 녹음을 다시 확인해 주세요.");
    }
    public async Task<NotesSourceSnapshot> SnapshotAsync(Recording recording, CancellationToken token)
    {
        RequireRecording(recording); _ = Load(recording); var revisions = Revisions(recording);
        string hash = await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token);
        RequireRevisions(recording, revisions); return new(hash, revisions);
    }
    private void RequireRevisions(Recording recording, Dictionary<string, string?> expected)
    {
        RequireRecording(recording);
        if (Revisions(recording).Any(pair => !expected.TryGetValue(pair.Key, out var value) || value != pair.Value))
            throw new InvalidOperationException("작업 중 회의록·전사·프로필 또는 수정 이력이 변경됐습니다. 최신 내용을 확인한 뒤 다시 실행해 주세요.");
    }
    public async Task RequireCurrentAsync(Recording recording, NotesSourceSnapshot snapshot, CancellationToken token)
    {
        if (await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), token) != snapshot.AudioHash) throw new InvalidOperationException("작업 중 녹음이 변경됐습니다. 이전 자료는 유지됩니다.");
        lock (gate) RequireRevisions(recording, snapshot.Revisions);
    }
    public async Task SaveAsync(Recording recording, MeetingNotes notes, NotesSourceSnapshot snapshot, CancellationToken token)
    {
        Validate(notes); await RequireCurrentAsync(recording, snapshot, token);
        lock (gate) { token.ThrowIfCancellationRequested(); RequireRevisions(recording, snapshot.Revisions); JsonDisk.Write(library.NotesPath(recording.Id), notes); }
    }
    public static void Validate(MeetingNotes notes)
    {
        MeetingValidation.Utf8Text(notes.Markdown, 2 * 1024 * 1024); MeetingValidation.Utf8Text(notes.Model, 512);
        // Local JSON retains the source snapshot and escapes Unicode; the separate wire document still has a 2 MiB limit.
        MeetingValidation.Require(JsonSerializer.SerializeToUtf8Bytes(notes, JsonDisk.Options).Length <= 16 * 1024 * 1024);
    }
}
