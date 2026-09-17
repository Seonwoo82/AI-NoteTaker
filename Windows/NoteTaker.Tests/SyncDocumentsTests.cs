using System.Net;
using System.Text;
using System.Text.Json;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class SyncDocumentsTests
{
    private static SyncConfiguration Config => new("https://sync.fixture", "synthetic-windows-sync-token");
    private static void Success(LibrarySyncResult result) { Assert.Empty(result.Issues); Assert.Equal(0, result.Pending); }
    private static async Task<Recording> Fixture(LibraryStore library, bool documents = true)
    {
        var recording = new Recording { Title = "공유 회의", DurationSeconds = 1, Mode = RecordingMode.Imported };
        TestFolder.Wave(library.AudioPath(recording.Id)); library.Save(recording);
        if (documents)
        {
            string audioHash = await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default);
            const string text = "금요일까지 초안을 정리하겠습니다.";
            var transcript = new MeetingTranscript(recording.Id, 1, "fixture/stt", [new("s1", "민수", true)], [new("t1", 0, 1, "s1", text)]);
            var insights = new MeetingInsights([new("a1", "commitment", "초안 정리", "s1", null, "금요일", ["t1"])], [], []);
            var analysis = new MeetingIntelligenceDocument(recording.Id, 1, 1000, Guid.NewGuid(), "출시", transcript, insights, [], "fixture/analysis");
            new MeetingWorkspaceStore(library).Save(recording, analysis, null);
            var cache = new TranscriptCache(audioHash, "fixture/stt", "ko", [text], true); JsonDisk.Write(library.TranscriptPath(recording.Id), cache);
            var cleanupSource = CleanupSource.Make(text, transcript);
            var cleanup = new TranscriptCleanup("fixture/cleanup", cleanupSource.Kind, cleanupSource.Hash, cleanupSource.Passages);
            var notes = new MeetingNotes("# 회의록\n\n금요일까지 초안을 준비합니다.", DateTimeOffset.UtcNow, "fixture/summary", 0)
            {
                TranscriptHash = MeetingNotesService.TranscriptContentHash(cache), Cleanup = cleanup,
                Original = new(1, audioHash, text, cache.Model, transcript)
            };
            JsonDisk.Write(library.NotesPath(recording.Id), notes);
            new MeetingWorkspaceStore(library).Append(recording, "speakerName", "s1", "김민수");
        }
        return SyncRecordings.Read(library, recording.Id)!;
    }

    [Fact] public async Task RemoteRestoreDownloadsPurgedAudioNotesAndMeetingEditsAgain()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = await Fixture(a);
        using var first = new LibrarySyncEngine(a, Config, server.Handler()); using var second = new LibrarySyncEngine(b, Config, server.Handler());
        Success(await first.RunAsync()); Success(await second.RunAsync());
        a.Save(a.Load().Single() with { DeletedAt = DateTimeOffset.UtcNow }); Success(await first.RunAsync()); Success(await second.RunAsync());
        var deleted = b.Load().Single(); string tombstone = File.ReadAllText(Path.Combine(b.DirectoryFor(recording.Id), "meta.json"));
        b.DeletePermanently(deleted); Success(await second.RunAsync());
        Assert.Equal(tombstone, File.ReadAllText(Path.Combine(b.DirectoryFor(recording.Id), "meta.json")));
        Assert.True(b.Load().Single().IsLocallyPurged); Assert.False(File.Exists(b.AudioPath(recording.Id)));
        Assert.False(File.Exists(b.NotesPath(recording.Id))); Assert.False(File.Exists(b.TranscriptPath(recording.Id)));
        using var transport = new SyncTransport(Config, server.Handler());
        await transport.PutEditAsync(new(Guid.NewGuid(), recording.Id, 1, 5000, "projectName", "", "복원 프로젝트"), default);
        Success(await second.RunAsync());
        Assert.Equal(2, Directory.GetFileSystemEntries(b.DirectoryFor(recording.Id)).Length); // Tombstone and marker only, even after receiving another edit.
        a.Save(a.Load().Single() with { DeletedAt = null }); Success(await first.RunAsync()); Success(await second.RunAsync());
        var restored = b.Load().Single(); Assert.Null(restored.DeletedAt); Assert.False(restored.IsLocallyPurged);
        Assert.False(File.Exists(b.PurgeMarkerPath(recording.Id))); Assert.True(File.Exists(b.AudioPath(recording.Id)));
        var notes = JsonDisk.Read<MeetingNotes>(b.NotesPath(recording.Id))!;
        Assert.Equal("fixture/summary", notes.Model); Assert.Contains("금요일", notes.Markdown);
        Assert.Equal(await MeetingNotesService.AudioHashAsync(b.AudioPath(recording.Id), default), notes.Original!.AudioHash);
        var meeting = new MeetingWorkspaceStore(b).Resolve(restored)!;
        Assert.Equal("김민수", meeting.Transcript.Speakers.Single().Name); Assert.Single(meeting.Source.Insights!.Actions);
        Assert.Equal("복원 프로젝트", meeting.ProjectName);
        Success(await second.RunAsync()); Assert.True(File.Exists(b.AudioPath(recording.Id)));
    }

    [Fact] public async Task ActualWorkerRoundTripPreservesDocumentsEditsProfileSettingsAndLocalSecrets()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = await Fixture(a);
        var profile = new MeetingProfile { DisplayName = "민수", Aliases = ["김민수"], Role = "개발", Terms = [new(Guid.NewGuid(), "노트테이커", "노트 테이커", "회의 앱", "project")] };
        new MeetingProfileStore(a.Root).Save(profile, null);
        new SettingsStore(a.Root).Save(new() { SummaryModel = "fixture/summary", TranscriptionModel = "fixture/stt", EnhancementModel = "fixture/revise", Language = "en", AutoGenerate = true,
            ProtectedApiKey = SettingsStore.ProtectKey("fixture-private-key-a") });
        var localSettings = new AppSettings { ProtectedApiKey = SettingsStore.ProtectKey("fixture-private-key-b"), ProtectedSharingSyncToken = SettingsStore.ProtectKey("fixture-sharing-secret-b"),
            SharingServerUrl = "https://local-setting.fixture", TranscriptionProvider = "whisper", SummaryProvider = "ollama", LocalSummaryModel = "qwen3.5:4b", UseGpu = false };
        new SettingsStore(b.Root).Save(localSettings); File.WriteAllText(Path.Combine(b.Root, "voice-profile-local.json"), "local-voice-must-stay");
        var captured = new List<string>();
        using var first = new LibrarySyncEngine(a, Config, new ObserveHandler(server.Handler(), captured));
        using var second = new LibrarySyncEngine(b, Config, new ObserveHandler(server.Handler(), captured));
        Success(await first.RunAsync()); var result = await second.RunAsync(); Success(result); Assert.True(result.OtherDevicesHaveApiKey);
        var received = b.Load().Single(); var notes = JsonDisk.Read<MeetingNotes>(b.NotesPath(received.Id))!;
        Assert.Equal("fixture/summary", notes.Model); Assert.Equal("금요일까지 초안을 정리하겠습니다.", notes.Original!.Transcript);
        Assert.Equal(await MeetingNotesService.AudioHashAsync(b.AudioPath(received.Id), default), notes.Original.AudioHash); Assert.NotNull(notes.Cleanup);
        var meeting = new MeetingWorkspaceStore(b).Resolve(received)!; Assert.Equal("김민수", meeting.Transcript.Speakers.Single().Name); Assert.Single(meeting.Source.Insights!.Actions);
        Assert.Equal("민수", new MeetingProfileStore(b.Root).Load().DisplayName);
        var settings = new SettingsStore(b.Root).Load(); Assert.Equal("fixture/summary", settings.SummaryModel); Assert.Equal("fixture/revise", settings.EnhancementModel); Assert.Equal("en", settings.Language); Assert.True(settings.AutoGenerate);
        Assert.Equal("whisper", settings.TranscriptionProvider); Assert.Equal("ollama", settings.SummaryProvider); Assert.False(settings.UseGpu); Assert.Equal("qwen3.5:4b", settings.LocalSummaryModel);
        Assert.Equal(localSettings.ProtectedApiKey, settings.ProtectedApiKey); Assert.Equal(localSettings.ProtectedSharingSyncToken, settings.ProtectedSharingSyncToken); Assert.Equal(localSettings.SharingServerUrl, settings.SharingServerUrl);
        Assert.Equal("local-voice-must-stay", File.ReadAllText(Path.Combine(b.Root, "voice-profile-local.json")));
        Assert.DoesNotContain(captured, request => request.Contains("fixture-private-key") || request.Contains("fixture-sharing-secret") || request.Contains("protectedApiKey") || request.Contains("voice-profile"));
        var before = await new SyncDocumentStore(b).ReadAsync(received, false, default);
        using var transport = new SyncTransport(Config, server.Handler()); var descriptor = (await transport.NotesAsync(null, default)).Notes.Single();
        Assert.Equal(await transport.DownloadDocumentAsync(descriptor, false, default), before!.Bytes);
        new MeetingWorkspaceStore(b).Append(received, "actionStatus", "a1", "done");
        Success(await second.RunAsync()); Success(await first.RunAsync()); Assert.Equal("done", new MeetingWorkspaceStore(a).Resolve(a.Load().Single())!.ActionStates["a1"]);
        Success(await first.RunAsync()); var unchanged = await second.RunAsync(); Success(unchanged); Assert.Equal(0, unchanged.Uploaded); Assert.Equal(0, unchanged.Downloaded);
        Assert.Equal(descriptor, (await transport.NotesAsync(null, default)).Notes.Single());
    }

    [Fact] public async Task RawAppleBytesAndFractionalDateSurviveImportAndLocalTranscriptReplacement()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = await Fixture(a, false);
        using var first = new LibrarySyncEngine(a, Config, server.Handler()); Success(await first.RunAsync()); using var transport = new SyncTransport(Config, server.Handler());
        string raw = "\n" + JsonSerializer.Serialize(new SyncNotes(1, recording.Id, 1, DateTimeOffset.Parse("2026-09-16T01:02:03Z"), "fixture/apple", "fixture/stt", "# 원래 회의록", "원래 발화"), new JsonSerializerOptions(SyncJson.Options) { WriteIndented = true }) + "\n";
        raw = raw.Replace("2026-09-16T01:02:03Z", "2026-09-16T01:02:03.125Z"); byte[] bytes = Encoding.UTF8.GetBytes(raw);
        var descriptor = await transport.UploadDocumentAsync(recording.Id, 1, bytes, false, default);
        using var second = new LibrarySyncEngine(b, Config, server.Handler()); Success(await second.RunAsync()); var local = b.Load().Single();
        var store = new SyncDocumentStore(b); Assert.Equal(bytes, (await store.ReadAsync(local, false, default))!.Bytes);
        var cache = JsonDisk.Read<TranscriptCache>(b.TranscriptPath(local.Id))!; JsonDisk.Write(b.TranscriptPath(local.Id), cache with { Chunks = ["새 전사문"], Model = "fixture/new" });
        Assert.Equal(bytes, (await store.ReadAsync(local, false, default))!.Bytes); Success(await second.RunAsync());
        Assert.Equal(descriptor, (await transport.NotesAsync(null, default)).Notes.Single()); Assert.Equal("원래 발화", JsonDisk.Read<MeetingNotes>(b.NotesPath(local.Id))!.Original!.Transcript);
        Assert.Equal("새 전사문", JsonDisk.Read<TranscriptCache>(b.TranscriptPath(local.Id))!.Chunks.Single());
    }

    [Fact] public async Task FailedNotesUploadLeavesPendingAndResumesWithoutRevisingItsOriginal()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root); var a = new LibraryStore(Path.Combine(test.Root, "a")); var recording = await Fixture(a);
        using (var failing = new LibrarySyncEngine(a, Config, new BeforeHandler(server.Handler(), request => request.Method == HttpMethod.Put && request.RequestUri!.AbsolutePath.EndsWith("/notes/1"), _ =>
            Task.FromResult<HttpResponseMessage?>(new(HttpStatusCode.ServiceUnavailable)))))
        {
            var result = await failing.RunAsync(); Assert.Single(result.Issues); Assert.Equal(1, result.Pending);
        }
        string original = JsonDisk.Read<MeetingNotes>(a.NotesPath(recording.Id))!.Original!.Transcript;
        using var retry = new LibrarySyncEngine(new LibraryStore(a.Root), Config, server.Handler()); Success(await retry.RunAsync());
        using var transport = new SyncTransport(Config, server.Handler()); var descriptor = (await transport.NotesAsync(null, default)).Notes.Single();
        Assert.Equal(original, SyncJson.Decode<SyncNotes>(await transport.DownloadDocumentAsync(descriptor, false, default), SyncJson.NotesLimit).Transcript);
    }

    [Fact] public async Task UnknownRecordingEditsRemainInDurableInboxUntilAudioCanBeDownloaded()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = await Fixture(a);
        using var first = new LibrarySyncEngine(a, Config, server.Handler()); Success(await first.RunAsync());
        using (var failed = new LibrarySyncEngine(b, Config, new BeforeHandler(server.Handler(), request => request.Method == HttpMethod.Get && request.RequestUri!.AbsolutePath.EndsWith("/audio/1"), _ =>
            Task.FromResult<HttpResponseMessage?>(new(HttpStatusCode.ServiceUnavailable)))))
        {
            var result = await failed.RunAsync(); Assert.Single(result.Issues); Assert.Equal(2, result.Pending); Assert.Empty(b.Load());
        }
        var state = new SyncStateStore(b.Root, Config.Endpoint); Assert.True(state.State.EditCursor > 0);
        string inbox = Path.Combine(Path.GetDirectoryName(state.Path)!, "edits-inbox.json"); Assert.Single(JsonDisk.Read<List<SyncEditEntry>>(inbox)!);
        using var restarted = new LibrarySyncEngine(new LibraryStore(b.Root), Config, server.Handler()); Success(await restarted.RunAsync());
        Assert.Empty(JsonDisk.Read<List<SyncEditEntry>>(inbox)!); Assert.Single(new MeetingWorkspaceStore(b).Edits(recording.Id));
        Assert.Equal("김민수", new MeetingWorkspaceStore(b).Resolve(b.Load().Single())!.Transcript.Speakers.Single().Name);
    }

    [Fact] public async Task LegacyNotesOnlyRecoverTheExactHashedTranscriptAndDoNotUseANewerOne()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var recording = await Fixture(library);
        var notes = JsonDisk.Read<MeetingNotes>(library.NotesPath(recording.Id))! with { Original = null, Cleanup = null };
        JsonDisk.Write(library.NotesPath(recording.Id), notes); var old = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id))!;
        JsonDisk.Write(library.TranscriptPath(recording.Id), old with { Chunks = ["이후 전사"], Model = "new" });
        var store = new SyncDocumentStore(library); await Assert.ThrowsAsync<InvalidDataException>(() => store.ReadAsync(recording, false, default));
        string history = Path.Combine(library.DirectoryFor(recording.Id), "TranscriptHistory", "original.json"); JsonDisk.Write(history, old);
        var artifact = await store.ReadAsync(recording, false, default); Assert.Equal(old.Chunks.Single(), artifact!.Notes!.Transcript);
        Assert.Equal(old.Chunks.Single(), JsonDisk.Read<MeetingNotes>(library.NotesPath(recording.Id))!.Original!.Transcript);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task DocumentDownloadDoesNotOverwriteAConcurrentLocalEdit(bool intelligence)
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = await Fixture(a);
        using var first = new LibrarySyncEngine(a, Config, server.Handler()); Success(await first.RunAsync());
        using (var initial = new LibrarySyncEngine(b, Config, server.Handler())) Success(await initial.RunAsync());
        if (intelligence)
        {
            var store = new MeetingWorkspaceStore(a); var snapshot = store.Snapshot(recording); store.Save(recording, snapshot.Document! with { ProjectName = "서버 수정" }, snapshot.Revision);
        }
        else
        {
            var notes = JsonDisk.Read<MeetingNotes>(a.NotesPath(recording.Id))!;
            JsonDisk.Write(a.NotesPath(recording.Id), notes with { Markdown = "# 서버 수정", CreatedAt = MeetingNotesSources.NextEditTime(notes) });
        }
        Success(await first.RunAsync()); bool edited = false; string kind = intelligence ? "/intelligence/1/" : "/notes/1/";
        using (var concurrent = new LibrarySyncEngine(b, Config, new BeforeHandler(server.Handler(), request => !edited && request.Method == HttpMethod.Get && request.RequestUri!.AbsolutePath.Contains(kind), _ =>
        {
            edited = true; var local = b.Load().Single();
            if (intelligence)
            {
                var store = new MeetingWorkspaceStore(b); var snapshot = store.Snapshot(local); store.Save(local, snapshot.Document! with { ProjectName = "다운로드 중 편집" }, snapshot.Revision);
            }
            else
            {
                var notes = JsonDisk.Read<MeetingNotes>(b.NotesPath(local.Id))!;
                JsonDisk.Write(b.NotesPath(local.Id), notes with { Markdown = "# 다운로드 중 편집", CreatedAt = DateTimeOffset.UtcNow.AddMinutes(1) });
            }
            return Task.FromResult<HttpResponseMessage?>(null);
        })))
        {
            var result = await concurrent.RunAsync(); Assert.Single(result.Issues); Assert.Equal(1, result.Pending);
        }
        if (intelligence) Assert.Equal("다운로드 중 편집", new MeetingWorkspaceStore(b).Load(b.Load().Single())!.ProjectName);
        else Assert.Equal("# 다운로드 중 편집", JsonDisk.Read<MeetingNotes>(b.NotesPath(recording.Id))!.Markdown);
        using var retry = new LibrarySyncEngine(b, Config, server.Handler()); Success(await retry.RunAsync());
    }

    [Fact] public async Task SharedSettingsAndProfileRetainLocalEditsMadeDuringDownload()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b"));
        new SettingsStore(a.Root).Save(new() { SummaryModel = "fixture/server" }); new MeetingProfileStore(a.Root).Save(new() { DisplayName = "서버 이름" }, null);
        using var first = new LibrarySyncEngine(a, Config, server.Handler()); Success(await first.RunAsync());
        bool changedSettings = false, changedProfile = false;
        using (var concurrent = new LibrarySyncEngine(b, Config, new BeforeHandler(server.Handler(), _ => true, request =>
        {
            if (request.Method == HttpMethod.Get && request.RequestUri!.AbsolutePath == "/v1/profile" && !changedProfile)
            { changedProfile = true; new MeetingProfileStore(b.Root).Save(new() { DisplayName = "로컬 이름" }, null); }
            if (request.Method == HttpMethod.Get && request.RequestUri!.AbsolutePath == "/v1/ai-settings" && !changedSettings)
            { changedSettings = true; new SettingsStore(b.Root).Save(new() { SummaryModel = "fixture/local", ProtectedApiKey = SettingsStore.ProtectKey("fixture-retain-key") }); }
            return Task.FromResult<HttpResponseMessage?>(null);
        }))) Assert.Equal(2, (await concurrent.RunAsync()).Issues.Count);
        Assert.Equal("로컬 이름", new MeetingProfileStore(b.Root).Load().DisplayName); Assert.Equal("fixture/local", new SettingsStore(b.Root).Load().SummaryModel);
        using var retry = new LibrarySyncEngine(b, Config, server.Handler()); Success(await retry.RunAsync());
        using var transport = new SyncTransport(Config, server.Handler()); Assert.Equal("로컬 이름", (await transport.ProfileAsync(null, default)).Profile!.DisplayName);
        Assert.Equal("fixture/local", (await transport.SettingsAsync(SyncAccountData.DeviceId(b.Root), null, default)).Preferences!.ModelId);
    }

    [Fact] public async Task LegalKoreanWireDocumentsRemainLoadableAfterLocalUnicodeEscaping()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var recording = await Fixture(library, false);
        string text = string.Concat(Enumerable.Repeat("가<", 200000)); var notes = new SyncNotes(1, recording.Id, 1, DateTimeOffset.UtcNow, "fixture", "fixture", text, text);
        byte[] raw = SyncJson.Encode(notes, SyncJson.NotesLimit); notes = SyncJson.Decode<SyncNotes>(raw, SyncJson.NotesLimit);
        var store = new SyncDocumentStore(library); var descriptor = new SyncDescriptor(recording.Id, 1, notes.GeneratedAt.ToUnixTimeMilliseconds(), SyncJson.Hash(raw), raw.Length);
        await store.ApplyAsync(recording, SyncDocumentStore.Decode(recording, false, raw, descriptor, store.Snapshot(recording, false)), false, default);
        Assert.True(new FileInfo(library.NotesPath(recording.Id)).Length > 4 * 1024 * 1024); Assert.Equal(text, new NotesDocumentStore(library).Load(recording)!.Markdown);
        Assert.Equal(raw, (await store.ReadAsync(recording, false, default))!.Bytes);
        var transcript = new MeetingTranscript(recording.Id, 1, "fixture", [], Enumerable.Range(0, 350).Select(i => new TranscriptTurn("t" + i, i / 350d, (i + 1) / 350d, null, new string('나', 2300))).ToList());
        var intelligence = new MeetingIntelligenceDocument(recording.Id, 1, 1000, Guid.NewGuid(), "프로젝트", transcript, null, [], "fixture");
        raw = SyncJson.Encode(intelligence, SyncJson.IntelligenceLimit); var analysisDescriptor = new SyncDescriptor(recording.Id, 1, 1000, SyncJson.Hash(raw), raw.Length);
        await store.ApplyAsync(recording, SyncDocumentStore.Decode(recording, true, raw, analysisDescriptor, store.Snapshot(recording, true)), true, default);
        Assert.True(new FileInfo(new MeetingWorkspaceStore(library).DocumentPath(recording.Id)).Length > 4 * 1024 * 1024); Assert.Equal(350, new MeetingWorkspaceStore(library).Load(recording)!.Transcript.Turns.Count);
        var profile = new MeetingProfile { Terms = Enumerable.Range(0, 100).Select(i => new GlossaryTerm(Guid.NewGuid(), "용어" + i, Meaning: new string('다', 120))).ToList() };
        profile.Validate(); var profileStore = new MeetingProfileStore(test.Root); profileStore.Save(profile, null);
        Assert.True(new FileInfo(profileStore.ProfilePath).Length > MeetingProfile.MaximumBytes); Assert.Equal(100, profileStore.Load().Terms.Count);
    }

    [Fact] public async Task IntelligenceConflictUsesMutationIdEvenWhenTheLosingDocumentHasTheHigherSha()
    {
        using var test = new TestFolder(); using var server = await LocalSyncServer.StartAsync(test.Root);
        var a = new LibraryStore(Path.Combine(test.Root, "a")); var b = new LibraryStore(Path.Combine(test.Root, "b")); var recording = await Fixture(a, false);
        var transcript = new MeetingTranscript(recording.Id, 1, "fixture", [], [new("t1", 0, 1, null, "근거 발화")]);
        var winner = new MeetingIntelligenceDocument(recording.Id, 1, 1000, Guid.Parse("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"), "원격 승자", transcript, null, [], "fixture");
        string winningHash = SyncJson.Hash(SyncJson.Encode(winner, SyncJson.IntelligenceLimit)); MeetingIntelligenceDocument? loser = null;
        for (int index = 0; index < 1000; index++)
        {
            var candidate = winner with { MutationId = Guid.Parse("00000000-0000-0000-0000-000000000001"), ProjectName = "낮은 수정 ID " + index };
            if (string.CompareOrdinal(SyncJson.Hash(SyncJson.Encode(candidate, SyncJson.IntelligenceLimit)), winningHash) > 0) { loser = candidate; break; }
        }
        Assert.NotNull(loser); JsonDisk.Write(new MeetingWorkspaceStore(a).DocumentPath(recording.Id), winner);
        using var first = new LibrarySyncEngine(a, Config, server.Handler()); Success(await first.RunAsync());
        using var second = new LibrarySyncEngine(b, Config, server.Handler()); Success(await second.RunAsync());
        JsonDisk.Write(new MeetingWorkspaceStore(b).DocumentPath(recording.Id), loser);
        var result = await second.RunAsync(); Success(result); Assert.Equal(0, result.Uploaded);
        Assert.Equal(winner.MutationId, new MeetingWorkspaceStore(b).Load(b.Load().Single())!.MutationId);
        Assert.Equal("원격 승자", new MeetingWorkspaceStore(b).Load(b.Load().Single())!.ProjectName);
    }

    private sealed class ObserveHandler(HttpMessageHandler inner, List<string> captured) : DelegatingHandler(inner)
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            if (request.Content?.Headers.ContentType?.MediaType == "application/json") captured.Add(await request.Content.ReadAsStringAsync(token));
            return await base.SendAsync(request, token);
        }
    }
    private sealed class BeforeHandler(HttpMessageHandler inner, Func<HttpRequestMessage, bool> match, Func<HttpRequestMessage, Task<HttpResponseMessage?>> before) : DelegatingHandler(inner)
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            if (match(request) && await before(request) is { } response) return response;
            return await base.SendAsync(request, token);
        }
    }
}
