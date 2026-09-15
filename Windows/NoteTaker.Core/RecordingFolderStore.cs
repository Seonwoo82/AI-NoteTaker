using System.Text.Json;

namespace NoteTaker.Core;

public sealed record RecordingCollectionFolder
{
    public int SchemaVersion { get; init; } = 1;
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; init; } = "";
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public long ModifiedAt { get; init; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public string MutationID { get; init; } = Guid.NewGuid().ToString("D").ToUpperInvariant();
    public DateTimeOffset? DeletedAt { get; init; }
    public long? SortOrder { get; init; }
}

/// <summary>Folder tombstones retain membership and audio. The UI resolves a deleted folder as unfiled.</summary>
public sealed class RecordingFolderStore
{
    private readonly string path;
    private List<RecordingCollectionFolder> folders = [];
    public string? LoadError { get; private set; }
    public IReadOnlyList<RecordingCollectionFolder> All { get { lock (JsonDisk.Gate) { Reload(); return folders.ToArray(); } } }
    public IReadOnlyList<RecordingCollectionFolder> Active { get { lock (JsonDisk.Gate) { Reload(); return folders.Where(x => x.DeletedAt is null)
        .OrderBy(x => x.SortOrder ?? long.MaxValue).ThenBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase).ThenBy(x => x.Id).ToArray(); } } }

    public RecordingFolderStore(string root)
    {
        path = Path.Combine(root, "recording-folders.json");
        try
        {
            var document = JsonDisk.Read<FolderFile>(path);
            if (document is null) return;
            if (document.SchemaVersion != 1 || document.Folders is null || document.Folders.Count > 10000 || document.Folders.Select(x => x.Id).Distinct().Count() != document.Folders.Count)
                throw new InvalidDataException();
            foreach (var folder in document.Folders) Validate(folder);
            folders = document.Folders;
        }
        catch (Exception ex) when (ex is IOException or JsonException or InvalidDataException or UnauthorizedAccessException or ArgumentException)
        { LoadError = "폴더 정보를 읽지 못했습니다. 원본을 보존했으며 폴더 변경을 중지했습니다."; }
    }

    public bool IsActive(Guid? id) => id is not null && All.Any(x => x.Id == id && x.DeletedAt is null);
    public RecordingCollectionFolder Create(string name)
    {
        lock (JsonDisk.Gate) return CreateLocked(name);
    }
    private RecordingCollectionFolder CreateLocked(string name)
    {
        EnsureWritable(); name = ValidName(name); RejectDuplicate(name);
        if (Active.Count >= 256) throw new InvalidOperationException("폴더는 최대 256개까지 만들 수 있습니다.");
        var folder = new RecordingCollectionFolder { Name = name, SortOrder = Active.Count };
        // Normalize ranks before appending, including libraries with imported sparse ranks.
        var ordered = Active.Select((item, index) => item.SortOrder == index ? item : Stamp(item with { SortOrder = index }, item)).ToDictionary(x => x.Id);
        Commit(folders.Select(x => ordered.GetValueOrDefault(x.Id, x)).Append(folder).ToList());
        return folder;
    }
    public RecordingCollectionFolder Rename(Guid id, string name)
    {
        lock (JsonDisk.Gate) return RenameLocked(id, name);
    }
    private RecordingCollectionFolder RenameLocked(Guid id, string name)
    {
        EnsureWritable(); var previous = RequireActive(id); name = ValidName(name); RejectDuplicate(name, id);
        var renamed = Stamp(previous with { Name = name }, previous); Replace(renamed); return renamed;
    }
    public void Delete(Guid id)
    {
        lock (JsonDisk.Gate) DeleteLocked(id);
    }
    private void DeleteLocked(Guid id)
    {
        EnsureWritable(); var previous = RequireActive(id);
        Replace(Stamp(previous with { DeletedAt = DateTimeOffset.UtcNow }, previous));
    }
    public void Move(Guid id, Guid? beforeId)
    {
        lock (JsonDisk.Gate) MoveLocked(id, beforeId);
    }
    private void MoveLocked(Guid id, Guid? beforeId)
    {
        EnsureWritable(); var source = RequireActive(id);
        if (beforeId == id) return;
        if (beforeId is Guid target) RequireActive(target);
        var ordered = Active.Where(x => x.Id != id).ToList();
        ordered.Insert(beforeId is null ? ordered.Count : ordered.FindIndex(x => x.Id == beforeId), source);
        var ranked = ordered.Select((item, index) => item.SortOrder == index ? item : Stamp(item with { SortOrder = index }, item)).ToDictionary(x => x.Id);
        Commit(folders.Select(x => ranked.GetValueOrDefault(x.Id, x)).ToList());
    }
    public void ApplyRemote(RecordingCollectionFolder remote)
    {
        lock (JsonDisk.Gate) ApplyRemoteLocked(remote);
    }
    private void ApplyRemoteLocked(RecordingCollectionFolder remote)
    {
        EnsureWritable(); Validate(remote);
        var previous = folders.FirstOrDefault(x => x.Id == remote.Id);
        if (previous is not null && (remote.ModifiedAt < previous.ModifiedAt || remote.ModifiedAt == previous.ModifiedAt && string.CompareOrdinal(remote.MutationID, previous.MutationID) <= 0)) return;
        Replace(remote with { SortOrder = remote.SortOrder ?? previous?.SortOrder });
    }
    public Recording MoveRecording(LibraryStore library, Recording recording, Guid? destination)
    {
        EnsureWritable(); if (destination is Guid id) RequireActive(id);
        var changed = recording with { FolderId = destination }; library.Save(changed); return changed;
    }
    private void Replace(RecordingCollectionFolder folder) => Commit(folders.Where(x => x.Id != folder.Id).Append(folder).ToList());
    private void Commit(List<RecordingCollectionFolder> next) { JsonDisk.Write(path, new FolderFile(1, next)); folders = next; }
    public void Reload()
    {
        lock (JsonDisk.Gate)
        {
            var current = new RecordingFolderStore(Path.GetDirectoryName(path)!);
            folders = current.folders; LoadError = current.LoadError;
        }
    }
    private void EnsureWritable() { Reload(); if (LoadError is not null) throw new InvalidDataException(LoadError); }
    private RecordingCollectionFolder RequireActive(Guid id) => folders.FirstOrDefault(x => x.Id == id && x.DeletedAt is null) ?? throw new InvalidOperationException("이 폴더는 없거나 삭제되었습니다.");
    private void RejectDuplicate(string name, Guid? except = null)
    {
        if (Active.Any(x => x.Id != except && string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("같은 이름의 폴더가 있습니다.");
    }
    private static string ValidName(string name)
    {
        name = name.Trim();
        if (name.Length == 0 || System.Globalization.StringInfo.ParseCombiningCharacters(name).Length > 120 || System.Text.Encoding.UTF8.GetByteCount(name) > 512) throw new ArgumentException("폴더 이름은 1~120자, UTF-8 512바이트 안으로 입력해 주세요.");
        return name;
    }
    public static void Validate(RecordingCollectionFolder folder)
    {
        if (folder.SchemaVersion != 1 || folder.Id == Guid.Empty || folder.Name is null || ValidName(folder.Name) != folder.Name || folder.ModifiedAt is < 0 or > 9007199254740991 ||
            !Guid.TryParseExact(folder.MutationID, "D", out _) || folder.MutationID != folder.MutationID.ToUpperInvariant() || folder.SortOrder is < 0 or > 9007199254740991)
            throw new InvalidDataException("폴더 메타데이터가 올바르지 않습니다.");
    }
    private static RecordingCollectionFolder Stamp(RecordingCollectionFolder changed, RecordingCollectionFolder previous) => changed with
    {
        ModifiedAt = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), checked(previous.ModifiedAt + 1)),
        MutationID = Guid.NewGuid().ToString("D").ToUpperInvariant()
    };
    private sealed record FolderFile(int SchemaVersion, List<RecordingCollectionFolder> Folders);
}
