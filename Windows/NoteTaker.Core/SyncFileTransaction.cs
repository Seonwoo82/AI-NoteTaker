using System.Security.Cryptography;
using System.Text.Json;

namespace NoteTaker.Core;

public sealed class SyncLocalConflictException() : IOException("동기화 중 로컬 자료가 변경되었습니다. 변경 내용은 보존했으며 다음 동기화에서 다시 비교합니다.");
public sealed record SyncFileChange(string RelativePath, string? SourcePath);

/// <summary>Durable local apply journal. Originals remain in its history; incomplete commits roll forward before library loading.</summary>
public static class SyncFileTransaction
{
    private sealed record Entry(string Path, string? Before, string? After, int Index);
    private sealed record Journal(int SchemaVersion, List<Entry> Entries, bool Complete);
    public static string? Revision(string path)
    {
        if (!File.Exists(path)) return null;
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexStringLower(SHA256.HashData(file));
    }
    public static string PathIn(string root, string relative)
    {
        string fullRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        if (Path.IsPathRooted(relative) || relative.Split(['/', '\\']).Any(p => p is "" or "." or ".." || p.Contains(':')))
            throw new InvalidDataException("동기화 파일 경로가 올바르지 않습니다.");
        string path = Path.GetFullPath(Path.Combine(fullRoot, relative));
        if (!path.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("동기화 파일이 저장 폴더 밖을 가리킵니다.");
        for (string? item = path; item is not null && !string.Equals(item, fullRoot, StringComparison.OrdinalIgnoreCase); item = Path.GetDirectoryName(item))
            if ((File.Exists(item) || Directory.Exists(item)) && (File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("동기화 경로에 연결된 외부 폴더가 있습니다.");
        return path;
    }
    public static Dictionary<string, string?> Snapshot(string root, IEnumerable<string> paths)
    {
        lock (JsonDisk.Gate) return paths.Distinct(StringComparer.OrdinalIgnoreCase).ToDictionary(p => p, p => Revision(PathIn(root, p)), StringComparer.OrdinalIgnoreCase);
    }
    public static void RequireCurrent(string root, IReadOnlyDictionary<string, string?> expected)
    {
        foreach (var pair in expected) if (Revision(PathIn(root, pair.Key)) != pair.Value) throw new SyncLocalConflictException();
    }
    public static void Commit(string root, IReadOnlyDictionary<string, string?> expected, IReadOnlyList<SyncFileChange> changes,
        CancellationToken token = default, Action<int>? afterFileApplied = null)
    {
        if (changes.Count is < 1 or > 64 || expected.Count > 128 || changes.Select(c => c.RelativePath).Distinct(StringComparer.OrdinalIgnoreCase).Count() != changes.Count)
            throw new InvalidDataException("동기화 적용 항목이 올바르지 않습니다.");
        lock (JsonDisk.Gate)
        {
            token.ThrowIfCancellationRequested(); RequireCurrent(root, expected);
            foreach (var change in changes) { _ = PathIn(root, change.RelativePath); if (!expected.ContainsKey(change.RelativePath)) throw new InvalidDataException("동기화 파일의 이전 버전이 없습니다."); }
            string directory = PathIn(root, ".sync/transactions/" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
            var entries = new List<Entry>();
            for (int index = 0; index < changes.Count; index++)
            {
                token.ThrowIfCancellationRequested(); var change = changes[index]; string target = PathIn(root, change.RelativePath);
                if (File.Exists(target)) CopyFlushed(target, Path.Combine(directory, $"old-{index}"));
                string? hash = null;
                if (change.SourcePath is not null)
                {
                    string staged = Path.Combine(directory, $"new-{index}"); CopyFlushed(change.SourcePath, staged); hash = Revision(staged);
                }
                entries.Add(new(change.RelativePath, expected[change.RelativePath], hash, index));
            }
            // Cancellation is observed before the durable commit decision, never halfway through normal local application.
            token.ThrowIfCancellationRequested(); RequireCurrent(root, expected);
            var journal = new Journal(1, entries, false); JsonDisk.Write(Path.Combine(directory, "manifest.json"), journal);
            Apply(root, directory, journal, afterFileApplied);
        }
    }
    public static void Recover(string root)
    {
        lock (JsonDisk.Gate)
        {
            string parent = PathIn(root, ".sync/transactions"); if (!Directory.Exists(parent)) return;
            foreach (string directory in Directory.EnumerateDirectories(parent).Order(StringComparer.Ordinal))
            {
                if (!Guid.TryParseExact(Path.GetFileName(directory), "N", out _)) continue;
                _ = PathIn(root, Path.GetRelativePath(root, directory));
                string manifest = Path.Combine(directory, "manifest.json"); if (!File.Exists(manifest)) continue;
                if (new FileInfo(manifest).Length > 64 * 1024) throw new InvalidDataException("동기화 복구 기록이 너무 큽니다.");
                var journal = JsonDisk.Read<Journal>(manifest) ?? throw new InvalidDataException("동기화 복구 기록을 읽지 못했습니다.");
                if (!journal.Complete) Apply(root, directory, journal, null);
            }
        }
    }
    private static void Apply(string root, string directory, Journal journal, Action<int>? afterFileApplied)
    {
        if (journal.SchemaVersion != 1 || journal.Entries is not { Count: > 0 and <= 64 } || journal.Entries.Select(e => e.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != journal.Entries.Count)
            throw new InvalidDataException("동기화 복구 기록이 올바르지 않습니다.");
        // Validate the whole transaction before resuming any write. Unrelated newer files are never overwritten.
        for (int index = 0; index < journal.Entries.Count; index++)
        {
            var entry = journal.Entries[index]; if (entry.Index != index) throw new InvalidDataException("동기화 복구 순서가 올바르지 않습니다.");
            string? current = Revision(PathIn(root, entry.Path));
            if (current != entry.Before && current != entry.After) throw new SyncLocalConflictException();
            if (entry.After is not null && Revision(Path.Combine(directory, $"new-{index}")) != entry.After) throw new InvalidDataException("동기화 복구 파일이 손상되었습니다. 이전 자료는 보관되어 있습니다.");
        }
        foreach (var entry in journal.Entries)
        {
            string destination = PathIn(root, entry.Path);
            if (Revision(destination) != entry.After)
            {
                if (entry.After is null) { if (File.Exists(destination)) File.Delete(destination); }
                else
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                    string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".sync-part";
                    try { CopyFlushed(Path.Combine(directory, $"new-{entry.Index}"), temporary); File.Move(temporary, destination, true); }
                    finally { if (File.Exists(temporary)) File.Delete(temporary); }
                }
            }
            afterFileApplied?.Invoke(entry.Index);
        }
        JsonDisk.Write(Path.Combine(directory, "manifest.json"), journal with { Complete = true });
        // Keep old files as version history. Completed replacement copies no longer need duplicate disk space.
        foreach (var entry in journal.Entries) { string staged = Path.Combine(directory, $"new-{entry.Index}"); if (File.Exists(staged)) File.Delete(staged); }
    }
    private static void CopyFlushed(string source, string destination)
    {
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        input.CopyTo(output); output.Flush(true);
    }

    internal static IReadOnlyList<string> RecordingHistoryFiles(string root, Guid id, ISet<string> sharedInboxes)
    {
        var files = new List<string>();
        string parent = PathIn(root, ".sync/transactions"), prefix = $"Recordings/{id:D}/";
        if (!Directory.Exists(parent)) return files;
        foreach (string directory in Directory.EnumerateDirectories(parent))
        {
            if (!Guid.TryParseExact(Path.GetFileName(directory), "N", out _)) continue;
            string relative = Path.GetRelativePath(root, directory);
            string manifest = PathIn(root, relative + "/manifest.json");
            if (!File.Exists(manifest)) continue;
            if (new FileInfo(manifest).Length > 64 * 1024) throw new InvalidDataException("동기화 복구 기록이 너무 큽니다.");
            var journal = JsonDisk.Read<Journal>(manifest);
            if (journal is not { SchemaVersion: 1, Complete: true, Entries.Count: > 0 and <= 64 })
                throw new InvalidDataException("동기화 복구를 완료한 후 삭제해 주세요.");
            for (int i = 0; i < journal.Entries.Count; i++)
            {
                var entry = journal.Entries[i];
                _ = PathIn(root, entry.Path);
                if (entry.Index != i) throw new InvalidDataException("동기화 복구 순서가 올바르지 않습니다.");
                if (entry.Path.Replace('\\', '/').StartsWith(".sync/workspaces/", StringComparison.OrdinalIgnoreCase) &&
                    entry.Path.Replace('\\', '/').EndsWith("/edits-inbox.json", StringComparison.OrdinalIgnoreCase))
                {
                    sharedInboxes.Add(PathIn(root, relative + $"/old-{i}"));
                    sharedInboxes.Add(PathIn(root, relative + $"/new-{i}"));
                }
                if (!entry.Path.Replace('\\', '/').StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
                files.Add(PathIn(root, relative + $"/old-{i}"));
                files.Add(PathIn(root, relative + $"/new-{i}"));
            }
        }
        return files;
    }
}
