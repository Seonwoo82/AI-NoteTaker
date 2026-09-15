namespace NoteTaker.Core;

public sealed partial class LibraryStore
{
    public static readonly TimeSpan TrashRetention = TimeSpan.FromDays(30);
    public string PurgeMarkerPath(Guid id) => SafePath($"Recordings/{id:D}/.purged");
    private string PurgePendingPath(Guid id) => SafePath($"Recordings/{id:D}/.purge-pending");
    private string SafePath(string relative) => SyncFileTransaction.PathIn(Root, relative);
    private void ClearPurgeMarkers(Guid id)
    {
        File.Delete(PurgeMarkerPath(id)); File.Delete(PurgePendingPath(id));
    }

    /// <summary>Remove this device's files while preserving the exact deletion tombstone for sync.</summary>
    public void DeletePermanently(Recording expected)
    {
        lock (JsonDisk.Gate)
        {
            SyncFileTransaction.Recover(Root);
            string metadata = SafePath(SyncRecordings.MetadataPath(expected.Id));
            var current = JsonDisk.Read<Recording>(metadata);
            if (current is null || current.Id != expected.Id || current.SchemaVersion != 1 || current.IsRecording ||
                current.DeletedAt is null || current.DeletedAt != expected.DeletedAt || current.AudioVersion != expected.AudioVersion ||
                current.SyncMetadata?.MutationId != expected.SyncMetadata?.MutationId)
                throw new InvalidOperationException("최근 삭제된 녹음의 상태가 바뀌었습니다. 목록을 새로 확인해 주세요.");

            string marker = PurgeMarkerPath(current.Id), pending = PurgePendingPath(current.Id);
            var files = new List<string>(); var directories = new List<string>();
            // Remove managed sharing-cache entries before their per-recording ownership directories.
            string sharing = SafePath($"Recordings/{current.Id:D}/SharedAudio");
            if (Directory.Exists(sharing))
                foreach (string share in Directory.EnumerateDirectories(sharing))
                    if (Guid.TryParseExact(Path.GetFileName(share), "N", out var shareId))
                    {
                        string cache = AudioShareCacheDirectory(current.Id, shareId);
                        if (Directory.Exists(cache)) { files.AddRange(InspectShareCache(cache)); directories.Add(cache); }
                    }
            // Preflight the entire tree before removing anything. Never traverse junctions or symlinks.
            Inspect(SafePath($"Recordings/{current.Id:D}"));
            var inboxes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            files.AddRange(SyncFileTransaction.RecordingHistoryFiles(Root, current.Id, inboxes));
            string workspaces = SafePath(".sync/workspaces");
            if (Directory.Exists(workspaces))
                foreach (string workspace in Directory.EnumerateDirectories(workspaces))
                    inboxes.Add(SafePath(Path.GetRelativePath(Root, workspace) + "/edits-inbox.json"));
            var redactions = new Dictionary<string, List<SyncEditEntry>>();
            foreach (string inbox in inboxes.Where(File.Exists))
            {
                if (new FileInfo(inbox).Length > 32 * 1024 * 1024) throw new InvalidDataException("수정 이력 수신함이 너무 큽니다.");
                var entries = JsonDisk.Read<List<SyncEditEntry>>(inbox) ?? throw new InvalidDataException("수정 이력 수신함을 읽지 못했습니다.");
                foreach (var entry in entries) { if (entry?.Edit is null) throw new InvalidDataException("수정 이력이 올바르지 않습니다."); entry.Edit.Validate(); }
                var retained = entries.Where(e => e.Edit.RecordingId != current.Id).ToList();
                if (retained.Count != entries.Count) redactions.Add(inbox, retained);
            }
            string outgoing = SafePath(".sync/outgoing");
            if (Directory.Exists(outgoing))
                foreach (string file in Directory.EnumerateFiles(outgoing, $"{current.Id:D}-*"))
                    files.Add(SafePath(Path.GetRelativePath(Root, file)));

            JsonDisk.Write(pending, new { schemaVersion = 1 });
            // Completed journals never replay these history copies; keep unrelated meeting edits intact.
            foreach (var pair in redactions) JsonDisk.Write(pair.Key, pair.Value);
            foreach (string file in files.Distinct(StringComparer.OrdinalIgnoreCase)) File.Delete(file);
            foreach (string directory in directories) Directory.Delete(directory); // Children precede parents.
            JsonDisk.Write(marker, new { schemaVersion = 1 });
            File.Delete(pending);

            void Inspect(string directory)
            {
                foreach (string item in Directory.EnumerateFileSystemEntries(directory))
                {
                    string path = SafePath(Path.GetRelativePath(Root, item));
                    if (Directory.Exists(path)) { Inspect(path); directories.Add(path); }
                    else if (!string.Equals(path, metadata, StringComparison.OrdinalIgnoreCase) &&
                        !string.Equals(path, marker, StringComparison.OrdinalIgnoreCase) &&
                        !string.Equals(path, pending, StringComparison.OrdinalIgnoreCase)) files.Add(path);
                }
            }
        }
    }

    /// <summary>Export the stored WAV byte for byte. Cancellation or failure keeps any existing destination.</summary>
    public Task ExportAudioAsync(Recording expected, string destination, CancellationToken token = default)
        => CopyAudioAsync(expected, destination, false, token);

    public static string AudioFileName(string title)
    {
        string name = string.Concat(title.Select(c => char.IsControl(c) || Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)).Trim().TrimEnd('.');
        if (name.Length > 120) name = name[..120].TrimEnd('.');
        if (name.Length > 0 && char.IsHighSurrogate(name[^1])) name = name[..^1];
        if (string.IsNullOrWhiteSpace(name)) name = "녹음";
        if (System.Text.RegularExpressions.Regex.IsMatch(name, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant)) name = "녹음 - " + name;
        return name + ".wav";
    }

    public async Task<string> CreateAudioShareCopyAsync(Recording recording, CancellationToken token = default)
    {
        if (recording.DeletedAt is not null) throw new InvalidOperationException("최근 삭제된 녹음을 먼저 복원해 주세요.");
        Guid shareId = Guid.NewGuid();
        string ownership = SafePath($"Recordings/{recording.Id:D}/SharedAudio/{shareId:N}");
        string directory = AudioShareCacheDirectory(recording.Id, shareId);
        // StorageFile does not support extended-length paths. Keep its snapshot in the user's temp cache.
        string name = AudioFileName(recording.Title); int allowed = Math.Min(124, 239 - directory.Length);
        if (allowed < 16) throw new InvalidOperationException("Windows 공유용 임시 폴더 경로가 너무 깁니다. 오디오 내보내기를 이용해 주세요.");
        if (name.Length > allowed)
        {
            string stem = name[..(allowed - 4)].TrimEnd('.', ' ');
            if (stem.Length > 0 && char.IsHighSurrogate(stem[^1])) stem = stem[..^1];
            name = stem + ".wav";
        }
        string path = Path.Combine(directory, name);
        Directory.CreateDirectory(ownership);
        try { Directory.CreateDirectory(directory); await CopyAudioAsync(recording, path, true, token); return path; }
        catch
        {
            if (Directory.Exists(directory) && !Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory);
            if (!Directory.Exists(directory) && Directory.Exists(ownership) && !Directory.EnumerateFileSystemEntries(ownership).Any()) Directory.Delete(ownership);
            throw;
        }
    }

    private string AudioShareCacheDirectory(Guid id, Guid shareId)
    {
        string libraryId = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Root.ToUpperInvariant())))[..16];
        return SyncFileTransaction.PathIn(Path.GetTempPath(), $"AI-NoteTaker-Share/{libraryId}-{id:N}-{shareId:N}");
    }
    private static string[] InspectShareCache(string directory)
    {
        // The directory was derived from this library and recording, never from a stored arbitrary path.
        if (Directory.EnumerateDirectories(directory).Any()) throw new InvalidDataException("오디오 공유 임시 폴더에 알 수 없는 하위 폴더가 있습니다.");
        string[] files = Directory.GetFiles(directory);
        foreach (string file in files) _ = SyncFileTransaction.PathIn(Path.GetTempPath(), Path.GetRelativePath(Path.GetTempPath(), file));
        return files;
    }

    private static void PruneExpiredAudioShareCache()
    {
        string parent = SyncFileTransaction.PathIn(Path.GetTempPath(), "AI-NoteTaker-Share");
        if (!Directory.Exists(parent)) return;
        foreach (string candidate in Directory.EnumerateDirectories(parent))
        {
            string[] parts = Path.GetFileName(candidate).Split('-');
            if (parts.Length != 3 || parts[0].Length != 16 || !parts[0].All(Uri.IsHexDigit) ||
                !Guid.TryParseExact(parts[1], "N", out _) || !Guid.TryParseExact(parts[2], "N", out _)) continue;
            try
            {
                string directory = SyncFileTransaction.PathIn(Path.GetTempPath(), Path.GetRelativePath(Path.GetTempPath(), candidate));
                if (DateTimeOffset.UtcNow - Directory.GetCreationTimeUtc(directory) < TimeSpan.FromDays(1)) continue;
                foreach (string file in InspectShareCache(directory)) File.Delete(file);
                Directory.Delete(directory);
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException) { /* A receiving app may still hold a file; retry next load. */ }
        }
    }

    // Share targets may read after the source window closes. Keep copies for 24 hours, or until the recording is purged.
    public void PruneAudioShareCopies(Guid id, DateTimeOffset now)
    {
        lock (JsonDisk.Gate)
        {
            string parent = SafePath($"Recordings/{id:D}/SharedAudio");
            if (!Directory.Exists(parent)) return;
            foreach (string directory in Directory.EnumerateDirectories(parent))
            {
                if (!Guid.TryParseExact(Path.GetFileName(directory), "N", out var shareId)) continue;
                string safe = SafePath(Path.GetRelativePath(Root, directory));
                string cache = AudioShareCacheDirectory(id, shareId);
                if (now - Directory.GetCreationTimeUtc(Directory.Exists(cache) ? cache : safe) < TimeSpan.FromDays(1)) continue;
                string[] files = Directory.GetFiles(safe);
                if (Directory.EnumerateDirectories(safe).Any()) continue;
                string[] cached = Directory.Exists(cache) ? InspectShareCache(cache) : [];
                foreach (string file in files) _ = SafePath(Path.GetRelativePath(Root, file));
                foreach (string file in cached) File.Delete(file);
                if (Directory.Exists(cache)) Directory.Delete(cache);
                foreach (string file in files) File.Delete(file);
                Directory.Delete(safe);
            }
        }
    }

    private async Task CopyAudioAsync(Recording expected, string destination, bool libraryShareCopy, CancellationToken token)
    {
        destination = Path.GetFullPath(destination);
        string fullRoot = Path.TrimEndingDirectorySeparator(Root);
        if (!libraryShareCopy && (destination.Equals(fullRoot, StringComparison.OrdinalIgnoreCase) ||
            destination.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("녹음 보관 폴더 밖에 오디오를 저장해 주세요.");
        // Resolve every existing destination ancestor to prevent an alias from pointing back into the library.
        for (string? item = destination; item is not null && !(libraryShareCopy && item.Equals(fullRoot, StringComparison.OrdinalIgnoreCase)); item = Path.GetDirectoryName(item))
            if ((File.Exists(item) || Directory.Exists(item)) && (File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("연결된 폴더 대신 실제 저장 폴더를 선택해 주세요.");
        string source = SafePath($"Recordings/{expected.Id:D}/audio.wav");
        string meta = SafePath(SyncRecordings.MetadataPath(expected.Id));
        string? revision;
        lock (JsonDisk.Gate)
        {
            var current = JsonDisk.Read<Recording>(meta);
            if (current is null || current.Id != expected.Id || current.IsRecording || current.AudioVersion != expected.AudioVersion ||
                current.DeletedAt != expected.DeletedAt || File.Exists(PurgePendingPath(expected.Id)) || File.Exists(PurgeMarkerPath(expected.Id)))
                throw new InvalidOperationException("내보낼 녹음의 상태가 바뀌었습니다. 목록을 새로 확인해 주세요.");
            revision = SyncFileTransaction.Revision(meta);
        }
        token.ThrowIfCancellationRequested();
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".export-part";
        try
        {
            using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.Asynchronous))
            {
                await input.CopyToAsync(output, token); await output.FlushAsync(token); output.Flush(true);
            }
            lock (JsonDisk.Gate)
            {
                token.ThrowIfCancellationRequested();
                if (revision != SyncFileTransaction.Revision(meta)) throw new SyncLocalConflictException();
                File.Move(temporary, destination, overwrite: true);
            }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
