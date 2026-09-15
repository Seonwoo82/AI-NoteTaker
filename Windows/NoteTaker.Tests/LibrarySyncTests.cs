using System.Net;
using System.Text;
using System.Text.Json;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class LibrarySyncTests
{
    private static SyncConfiguration Configuration(string endpoint = "https://sync.fixture") => new(endpoint, "synthetic-windows-sync-token");
    private static Recording Add(LibraryStore library, string title = "첫 회의", Guid? id = null)
    {
        var recording = new Recording { Id = id ?? Guid.NewGuid(), Title = title, DurationSeconds = 1, Mode = RecordingMode.Imported };
        TestFolder.Wave(library.AudioPath(recording.Id)); library.Save(recording); return library.Load().Single(r => r.Id == recording.Id);
    }
    private static void Success(LibrarySyncResult result) { Assert.Empty(result.Issues); Assert.Equal(0, result.Pending); }

    [Fact] public async Task TwoWindowsLibrariesExchangeAudioFoldersMetadataAndTombstonesWithoutReencodingRemoteAudio()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b"));
        var folderA = new RecordingFolderStore(a.Root); var folderB = new RecordingFolderStore(b.Root);
        var collection = folderA.Create("주간 회의"); var original = Add(a);
        a.Save(original with { FolderId = collection.Id }); string originalHash = SyncFileTransaction.Revision(a.AudioPath(original.Id))!;
        using var first = new LibrarySyncEngine(a, Configuration(), server.Handler());
        using var second = new LibrarySyncEngine(b, Configuration(), server.Handler());
        Success(await first.RunAsync()); Success(await second.RunAsync());
        var received = b.Load().Single(); Assert.Equal(original.Id, received.Id); Assert.Equal(collection.Id, received.FolderId); Assert.True(folderB.IsActive(collection.Id));
        Assert.Equal("주간 회의", folderB.Active.Single().Name); Assert.True(File.Exists(b.AudioPath(received.Id)));
        string originalM4a = Directory.GetFiles(Path.Combine(a.Root, ".sync", "outgoing")).Single();
        Assert.Equal(File.ReadAllBytes(originalM4a), File.ReadAllBytes(Path.Combine(b.DirectoryFor(received.Id), "sync-audio.m4a")));
        using var transport = new SyncTransport(Configuration(), server.Handler());
        var remote = (await transport.RecordingsAsync(null, default)).Recordings.Single();
        await transport.PutRecordingAsync(remote with { ModifiedAt = remote.ModifiedAt + 1, MutationId = Guid.NewGuid(), PlaybackRate = .75, SkipsSilence = true, Enhances = true, Warnings = ["원격 경고"] }, default);
        Success(await second.RunAsync()); received = b.Load().Single();
        b.Save(received with { Title = "Windows에서 수정", IsFavorite = true }); folderB.Rename(collection.Id, "이름 변경");
        Success(await second.RunAsync()); Success(await first.RunAsync());
        var changed = a.Load().Single(); Assert.Equal("Windows에서 수정", changed.Title); Assert.True(changed.IsFavorite);
        Assert.Equal(.75, changed.SyncMetadata!.PlaybackRate); Assert.True(changed.SyncMetadata.SkipsSilence && changed.SyncMetadata.Enhances); Assert.Equal("원격 경고", changed.SyncMetadata.Warnings.Single());
        Assert.Equal(originalHash, SyncFileTransaction.Revision(a.AudioPath(original.Id))); Assert.Equal("이름 변경", folderA.Active.Single().Name);
        var repeat = await first.RunAsync(); Success(repeat); Assert.Equal(0, repeat.Uploaded); Assert.Equal(0, repeat.Downloaded);
        folderB.Delete(collection.Id); b.Save(b.Load().Single() with { DeletedAt = DateTimeOffset.UtcNow });
        Success(await second.RunAsync()); Success(await first.RunAsync()); Assert.NotNull(a.Load().Single().DeletedAt); Assert.Empty(folderA.Active);
        Assert.Equal(originalHash, SyncFileTransaction.Revision(a.AudioPath(original.Id)));
        string statePath = new SyncStateStore(a.Root, Configuration().Endpoint).Path;
        Assert.DoesNotContain("synthetic-windows-sync-token", File.ReadAllText(statePath));
        Assert.Empty(new SyncStateStore(a.Root, Configuration("https://another.fixture").Endpoint).State.Acknowledged);
    }

    [Fact] public async Task FailedMetadataUploadRetriesAfterWorkerAndClientRestartAndKeepsTheFirstAudio()
    {
        using var test = new TestFolder(); var a = new LibraryStore(Path.Combine(test.Root, "a")); var recording = Add(a);
        using (var server = await LocalSyncServer.StartAsync(test.Root))
        {
            using var failure = new LibrarySyncEngine(a, Configuration(), new Intercept(server.Handler(), request => request.Method == HttpMethod.Put && request.RequestUri!.AbsolutePath == "/v1/recordings/" + SyncJson.Id(recording.Id),
                _ => Task.FromResult<HttpResponseMessage?>(new(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("untrusted diagnostic") })));
            var failed = await failure.RunAsync(); Assert.Single(failed.Issues); Assert.Equal(1, failed.Pending);
            var state = new SyncStateStore(a.Root, Configuration().Endpoint).State; Assert.Equal(1, state.Pending.Single().Value.Attempts);
            Assert.DoesNotContain("untrusted", state.Pending.Single().Value.Error);
            using var transport = new SyncTransport(Configuration(), server.Handler()); Assert.Empty((await transport.RecordingsAsync(null, default)).Recordings);
        }
        using (var restarted = await LocalSyncServer.StartAsync(test.Root))
        {
            using var retry = new LibrarySyncEngine(new LibraryStore(a.Root), Configuration(), restarted.Handler());
            var waiting = await retry.RunAsync(force: false); Assert.Equal(1, waiting.Pending); Assert.Equal(0, waiting.Uploaded);
            Success(await retry.RunAsync());
            var b = new LibraryStore(Path.Combine(test.Root, "b")); using var download = new LibrarySyncEngine(b, Configuration(), restarted.Handler()); Success(await download.RunAsync());
            Assert.Equal(recording.Id, b.Load().Single().Id);
            string encoded = Directory.GetFiles(Path.Combine(a.Root, ".sync", "outgoing")).Single();
            Assert.Equal(File.ReadAllBytes(encoded), File.ReadAllBytes(Path.Combine(b.DirectoryFor(recording.Id), "sync-audio.m4a")));
            Assert.Empty(new SyncStateStore(a.Root, Configuration().Endpoint).State.Pending);
        }
    }

    [Fact] public async Task LocalEditDuringAudioDownloadSurvivesAndIsPublishedOnRetry()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = Add(a);
        using var first = new LibrarySyncEngine(a, Configuration(), server.Handler()); Success(await first.RunAsync());
        using (var initial = new LibrarySyncEngine(b, Configuration(), server.Handler())) Success(await initial.RunAsync());
        string oldHash = SyncFileTransaction.Revision(b.AudioPath(recording.Id))!;
        var next = a.Load().Single() with { AudioVersion = 2, Title = "원격 새 버전" }; a.Save(next); Success(await first.RunAsync());
        bool edited = false;
        using (var concurrent = new LibrarySyncEngine(b, Configuration(), new Intercept(server.Handler(), request => !edited && request.Method == HttpMethod.Get && request.RequestUri!.AbsolutePath.EndsWith("/audio/2"), _ =>
        {
            edited = true; b.Save(b.Load().Single() with { Title = "다운로드 중 수정" }); return Task.FromResult<HttpResponseMessage?>(null);
        })))
        {
            var result = await concurrent.RunAsync(); Assert.Single(result.Issues); Assert.Equal(1, result.Pending);
        }
        Assert.Equal("다운로드 중 수정", b.Load().Single().Title); Assert.Equal(1, b.Load().Single().AudioVersion); Assert.Equal(oldHash, SyncFileTransaction.Revision(b.AudioPath(recording.Id)));
        using var retry = new LibrarySyncEngine(b, Configuration(), server.Handler()); Success(await retry.RunAsync());
        using var transport = new SyncTransport(Configuration(), server.Handler()); Assert.Equal("다운로드 중 수정", (await transport.RecordingsAsync(null, default)).Recordings.Single().Title);
    }

    [Fact] public async Task MissingAudioDoesNotBlockOtherRecordingsAndActiveCaptureIsNeverRepairedBySync()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root); var library = new LibraryStore(Path.Combine(test.Root, "a"));
        var missing = new Recording { Title = "파일 없음", Id = Guid.Parse("10000000-0000-0000-0000-000000000000") }; library.Save(missing);
        var good = Add(library, id: Guid.Parse("20000000-0000-0000-0000-000000000000"));
        var active = Add(library); library.Save(active with { IsRecording = true });
        using var engine = new LibrarySyncEngine(library, Configuration(), server.Handler()); var result = await engine.RunAsync(); Assert.Single(result.Issues); Assert.Equal(1, result.Pending);
        Assert.True(SyncRecordings.Read(library, active.Id)!.IsRecording);
        using var transport = new SyncTransport(Configuration(), server.Handler()); Assert.Equal(good.Id, (await transport.RecordingsAsync(null, default)).Recordings.Single().Id);
    }

    [Fact] public async Task MalformedPagesAreRejectedBeforeAdoptingRemoteMetadata()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var original = Add(library); string before = SyncFileTransaction.Revision(library.AudioPath(original.Id))!;
        using var engine = new LibrarySyncEngine(library, Configuration(), new StubHandler((request, _) =>
        {
            object payload = request.RequestUri!.AbsolutePath switch { "/v1/health" => new SyncHealth(true, 1), "/v1/folders" => new SyncFoldersPage([]), _ => new SyncRecordingsPage([original.SyncMetadata!, original.SyncMetadata!]) };
            return Task.FromResult(StubHandler.Json(Encoding.UTF8.GetString(SyncJson.Encode(payload, 65536))));
        }));
        var result = await engine.RunAsync(); Assert.Single(result.Issues); Assert.Equal(0, result.Downloaded); Assert.Equal(before, SyncFileTransaction.Revision(library.AudioPath(original.Id)));
    }

    [Fact] public void LocalApplyRecoversAfterAudioReplacementBeforeMetadataAndKeepsOldVersionHistory()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var original = Add(library); string prefix = $"Recordings/{original.Id:D}/";
        string oldHash = SyncFileTransaction.Revision(library.AudioPath(original.Id))!;
        string newAudio = Path.Combine(test.Root, "next.wav"), newMeta = Path.Combine(test.Root, "next.json"); TestFolder.Wave(newAudio, 2);
        var updated = original with { DurationSeconds = 2, AudioVersion = 2, Title = "복구된 새 버전" }; JsonDisk.Write(newMeta, updated);
        File.WriteAllText(library.TranscriptPath(original.Id), "old transcript");
        var paths = new[] { prefix + "audio.wav", prefix + "transcript.json", prefix + "meta.json" }; var expected = SyncFileTransaction.Snapshot(library.Root, paths);
        Assert.Throws<SimulatedStop>(() => SyncFileTransaction.Commit(library.Root, expected, [new(paths[0], newAudio), new(paths[1], null), new(paths[2], newMeta)], afterFileApplied: index => { if (index == 0) throw new SimulatedStop(); }));
        var restarted = new LibraryStore(test.Root); var recovered = restarted.Load().Single(); Assert.Equal(2, recovered.AudioVersion); Assert.Equal("복구된 새 버전", recovered.Title);
        Assert.False(File.Exists(library.TranscriptPath(original.Id))); Assert.Equal(SyncFileTransaction.Revision(newAudio), SyncFileTransaction.Revision(library.AudioPath(original.Id)));
        string backup = Directory.GetFiles(Path.Combine(test.Root, ".sync", "transactions"), "old-0", SearchOption.AllDirectories).Single(); Assert.Equal(oldHash, SyncFileTransaction.Revision(backup));
        Assert.Empty(Directory.GetFiles(Path.Combine(test.Root, ".sync", "transactions"), "new-*", SearchOption.AllDirectories));
        Assert.Equal(2, restarted.Load().Single().AudioVersion);
    }

    [Fact] public void LocalApplyRejectsConcurrentChangesAndEscapingPathsBeforeWriting()
    {
        using var test = new TestFolder(); string current = Path.Combine(test.Root, "data.json"), replacement = Path.Combine(test.Root, "next.json"); File.WriteAllText(current, "before"); File.WriteAllText(replacement, "remote");
        var expected = SyncFileTransaction.Snapshot(test.Root, ["data.json"]); File.WriteAllText(current, "local change");
        Assert.Throws<SyncLocalConflictException>(() => SyncFileTransaction.Commit(test.Root, expected, [new("data.json", replacement)])); Assert.Equal("local change", File.ReadAllText(current));
        Assert.Throws<InvalidDataException>(() => SyncFileTransaction.PathIn(test.Root, "../escaped.json"));
        Assert.Throws<InvalidDataException>(() => SyncFileTransaction.PathIn(test.Root, "data.json:stream"));
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SyncFileTransaction.Commit(test.Root, expected, [new("data.json", replacement)], cancellation.Token));
        Assert.Equal("local change", File.ReadAllText(current));
    }

    [Fact] public void MultipleFolderStoresRefreshAndUnicodeNamesMatchAppleCharacterBoundaries()
    {
        using var test = new TestFolder(); var first = new RecordingFolderStore(test.Root); var second = new RecordingFolderStore(test.Root);
        var a = first.Create("가족 👨‍👩‍👧‍👦"); var b = second.Create("두 번째"); first.Rename(a.Id, "새 이름");
        Assert.Equal(2, second.All.Count); Assert.Equal("새 이름", second.All.Single(f => f.Id == a.Id).Name); Assert.True(first.IsActive(b.Id));
        string name = string.Concat(Enumerable.Repeat("a\u0301", 120)); var accented = first.Create(name); Assert.Equal(name, accented.Name);
    }

    [Fact] public async Task NewAudioVersionArchivesOldDerivedFilesWithoutTouchingLocalKeysOrVoice()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = Add(a);
        using var first = new LibrarySyncEngine(a, Configuration(), server.Handler()); using var second = new LibrarySyncEngine(b, Configuration(), server.Handler());
        Success(await first.RunAsync()); Success(await second.RunAsync());
        string[] derived = ["transcript.json", "notes.json", "meeting-intelligence.json", "meeting-edits-local.json", "participant-transcript-local.json", "speaker-acoustic-local.json"];
        foreach (string file in derived) File.WriteAllText(Path.Combine(b.DirectoryFor(recording.Id), file), "previous-" + file);
        string keyFile = Path.Combine(b.Root, "settings.json"), voiceFile = Path.Combine(b.Root, "voice-profile-local.json");
        File.WriteAllText(keyFile, "synthetic-local-key-record"); File.WriteAllText(voiceFile, "synthetic-local-voice-record");
        string previousAudio = SyncFileTransaction.Revision(b.AudioPath(recording.Id))!;
        TestFolder.Wave(a.AudioPath(recording.Id), 2); a.Save(a.Load().Single() with { AudioVersion = 2, DurationSeconds = 2 });
        Success(await first.RunAsync()); Success(await second.RunAsync());
        Assert.Equal(2, b.Load().Single().AudioVersion); Assert.Equal(2, b.Load().Single().DurationSeconds);
        foreach (string file in derived) Assert.False(File.Exists(Path.Combine(b.DirectoryFor(recording.Id), file)));
        Assert.Equal("synthetic-local-key-record", File.ReadAllText(keyFile)); Assert.Equal("synthetic-local-voice-record", File.ReadAllText(voiceFile));
        Assert.Contains(Directory.GetFiles(Path.Combine(b.Root, ".sync", "transactions"), "old-*", SearchOption.AllDirectories), file => SyncFileTransaction.Revision(file) == previousAudio);
        string state = File.ReadAllText(new SyncStateStore(b.Root, Configuration().Endpoint).Path); Assert.DoesNotContain("synthetic-local-key", state); Assert.DoesNotContain("synthetic-local-voice", state);
    }

    [Fact] public async Task CancellationAfterAudioUploadLeavesADurableRetryAndOriginalFiles()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root); var library = new LibraryStore(Path.Combine(test.Root, "a")); var recording = Add(library);
        string original = SyncFileTransaction.Revision(library.AudioPath(recording.Id))!; using var cancellation = new CancellationTokenSource();
        using (var engine = new LibrarySyncEngine(library, Configuration(), new Intercept(server.Handler(), request => request.Method == HttpMethod.Put && request.RequestUri!.AbsolutePath == "/v1/recordings/" + SyncJson.Id(recording.Id), _ =>
        {
            cancellation.Cancel(); cancellation.Token.ThrowIfCancellationRequested(); return Task.FromResult<HttpResponseMessage?>(null);
        }))) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => engine.RunAsync(token: cancellation.Token));
        Assert.Single(new SyncStateStore(library.Root, Configuration().Endpoint).State.Pending); Assert.Equal(original, SyncFileTransaction.Revision(library.AudioPath(recording.Id)));
        using var retry = new LibrarySyncEngine(library, Configuration(), server.Handler()); Success(await retry.RunAsync());
    }

    [Fact] public void LegacyMetadataUsesItsActualModificationTimeInsteadOfTimeOfFirstSync()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var original = new Recording { Title = "이전 설치 기록" };
        string path = Path.Combine(library.DirectoryFor(original.Id), "meta.json"); JsonDisk.Write(path, original);
        var editedAt = DateTimeOffset.UtcNow.AddDays(-30); File.SetLastWriteTimeUtc(path, editedAt.UtcDateTime);
        var migrated = SyncRecordings.Read(library, original.Id)!; Assert.Equal(editedAt.ToUnixTimeMilliseconds(), migrated.SyncMetadata!.ModifiedAt);
        var same = SyncRecordings.Read(library, original.Id)!; Assert.Equal(migrated.SyncMetadata.MutationId, same.SyncMetadata!.MutationId);
        library.Save(same with { Title = "지금 편집" }); Assert.True(SyncRecordings.Read(library, original.Id)!.SyncMetadata!.ModifiedAt > migrated.SyncMetadata.ModifiedAt);
    }
    [Fact] public void EmptyAppleTitlesRemainLoadableAndLocalCaptureWarningsAreIncluded()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var recording = new Recording { Title = "", Warning = "중단된 녹음 복구" };
        library.Save(recording); var loaded = library.Load().Single(); Assert.Equal("", loaded.Title); Assert.Equal("새 녹음", loaded.DisplayTitle);
        Assert.Equal("중단된 녹음 복구", loaded.SyncMetadata!.Warnings.Single());
    }
    [Fact] public async Task NewerTombstoneCannotRestoreAnOlderAudioFileUnderTheNewVersion()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = Add(a);
        using var first = new LibrarySyncEngine(a, Configuration(), server.Handler()); using var second = new LibrarySyncEngine(b, Configuration(), server.Handler());
        Success(await first.RunAsync()); Success(await second.RunAsync()); string previous = SyncFileTransaction.Revision(b.AudioPath(recording.Id))!;
        TestFolder.Wave(a.AudioPath(recording.Id), 2); a.Save(a.Load().Single() with { AudioVersion = 2, DurationSeconds = 2, DeletedAt = DateTimeOffset.UtcNow });
        Success(await first.RunAsync()); Success(await second.RunAsync()); Assert.Equal(2, b.Load().Single().AudioVersion); Assert.False(File.Exists(b.AudioPath(recording.Id)));
        Assert.Contains(Directory.GetFiles(Path.Combine(b.Root, ".sync", "transactions"), "old-*", SearchOption.AllDirectories), path => SyncFileTransaction.Revision(path) == previous);
        a.Save(a.Load().Single() with { DeletedAt = null }); Success(await first.RunAsync()); Success(await second.RunAsync());
        Assert.Null(b.Load().Single().DeletedAt); Assert.Equal(2, b.Load().Single().AudioVersion); Assert.NotEqual(previous, SyncFileTransaction.Revision(b.AudioPath(recording.Id)));
    }
    private sealed class SimulatedStop : Exception;
    private sealed class Intercept(HttpMessageHandler inner, Func<HttpRequestMessage, bool> matches, Func<HttpRequestMessage, Task<HttpResponseMessage?>> action) : DelegatingHandler(inner)
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            if (matches(request) && await action(request) is { } response) return response;
            return await base.SendAsync(request, token);
        }
    }
}
