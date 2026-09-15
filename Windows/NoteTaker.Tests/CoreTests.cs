using System.Buffers.Binary;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NAudio.Wave;
using NoteTaker.Core;
using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace NoteTaker.Tests;

public sealed class TestFolder : IDisposable
{
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "NoteTaker-tests-" + Guid.NewGuid().ToString("N"));
    public TestFolder() => Directory.CreateDirectory(Root);
    public void Dispose()
    {
        var target = Path.GetFullPath(Root);
        if (!target.StartsWith(Path.Combine(Path.GetTempPath(), "NoteTaker-tests-"), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException();
        Directory.Delete(target, recursive: true);
    }
    public static void Wave(string path, double seconds = 1, float amplitude = .2f)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var writer = new WaveFileWriter(path, AudioFiles.RecordingFormat);
        var bytes = new byte[(int)(seconds * 48000) * 4];
        for (int frame = 0; frame < bytes.Length / 4; frame++)
        {
            short value = (short)(Math.Sin(frame * 2 * Math.PI * 440 / 48000) * short.MaxValue * amplitude);
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(frame * 4, 2), value);
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(frame * 4 + 2, 2), value);
        }
        writer.Write(bytes, 0, bytes.Length);
    }
}

public sealed class StorageTests
{
    [Fact] public void RenameFavoriteDeleteRestoreRoundTripsWithoutChangingAudio()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording { Title = "회의", DurationSeconds = 1 };
        TestFolder.Wave(store.AudioPath(record.Id));
        var hash = SHA256.HashData(File.ReadAllBytes(store.AudioPath(record.Id)));
        store.Save(record);
        store.Save(record with { Title = "회의 / 새 이름", IsFavorite = true, DeletedAt = DateTimeOffset.Now });
        var deleted = Assert.Single(store.Load());
        Assert.True(deleted.IsFavorite); Assert.NotNull(deleted.DeletedAt);
        store.Save(deleted with { DeletedAt = null });
        Assert.Null(Assert.Single(store.Load()).DeletedAt);
        Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(store.AudioPath(record.Id))));
    }
    [Fact] public void CorruptMetadataIsRetainedAndReported()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording(); store.Save(record);
        var path = Path.Combine(store.DirectoryFor(record.Id), "meta.json");
        File.WriteAllText(path, "{incomplete");
        Assert.Empty(store.Load()); Assert.Single(store.LoadWarnings); Assert.Equal("{incomplete", File.ReadAllText(path));
    }
    [Fact] public void MismatchedRecordIdCannotRedirectLibraryReads()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording(); store.Save(record);
        JsonDisk.Write(Path.Combine(store.DirectoryFor(record.Id), "meta.json"), record with { Id = Guid.NewGuid() });
        Assert.Empty(store.Load()); Assert.Single(store.LoadWarnings);
    }
    [Fact] public void InterruptedWaveWithStaleHeaderRecoversAllCompleteFrames()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording { IsRecording = true }; store.Save(record);
        var path = store.AudioPath(record.Id); TestFolder.Wave(path);
        using (var file = new FileStream(path, FileMode.Append)) file.Write(new byte[192003]);
        var recovered = Assert.Single(store.Load());
        Assert.False(recovered.IsRecording); Assert.NotNull(recovered.Warning);
        Assert.Equal(2, recovered.DurationSeconds, precision: 4);
        using var reader = new WaveFileReader(path);
        Assert.Equal(2, reader.TotalTime.TotalSeconds, precision: 4);
    }
    [Fact] public void InterruptedMissingFileIsVisibleWithWarning()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        store.Save(new Recording { IsRecording = true });
        var recovered = Assert.Single(store.Load());
        Assert.False(recovered.IsRecording); Assert.NotNull(recovered.Warning);
    }
    [Fact] public async Task ImportCopiesAudioWithoutModifyingOriginal()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(Path.Combine(folder.Root, "library"));
        string source = Path.Combine(folder.Root, "회의.wav"); TestFolder.Wave(source, .25);
        var hash = SHA256.HashData(File.ReadAllBytes(source));
        var record = await store.ImportAsync(source);
        Assert.Equal("회의", record.Title); Assert.Equal(RecordingMode.Imported, record.Mode);
        Assert.InRange(record.DurationSeconds, .24, .26);
        Assert.True(File.Exists(store.AudioPath(record.Id))); Assert.Equal(hash, SHA256.HashData(File.ReadAllBytes(source)));
    }
    [Fact] public async Task CancelledImportLeavesNoPublishedRecording()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(Path.Combine(folder.Root, "library"));
        string source = Path.Combine(folder.Root, "source.wav"); TestFolder.Wave(source);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.ImportAsync(source, new CancellationToken(true)));
        Assert.Empty(store.Load());
        Assert.Empty(Directory.EnumerateFiles(store.Root, "*.tmp", SearchOption.AllDirectories));
    }
    [Fact] public void CredentialsAreEncryptedAtRestAndSurviveSettingsReload()
    {
        using var folder = new TestFolder(); var store = new SettingsStore(folder.Root);
        const string key = "not-a-real-key-local-test-only";
        store.Save(new AppSettings { ProtectedApiKey = SettingsStore.ProtectKey(key) });
        Assert.DoesNotContain(key, File.ReadAllText(Path.Combine(folder.Root, "settings.json")));
        Assert.Equal(key, SettingsStore.ReadKey(store.Load()));
        store.Save(store.Load() with { ProtectedApiKey = null });
        Assert.Equal("", SettingsStore.ReadKey(store.Load()));
    }
}

public sealed class AudioTests
{
    [Fact] public void WaveformEnvelopePreservesSilentAndAudibleSections()
    {
        using var folder = new TestFolder(); var path = Path.Combine(folder.Root, "waveform.wav");
        using (var writer = new WaveFileWriter(path, AudioFiles.RecordingFormat))
        {
            writer.Write(new byte[192000], 0, 192000);
            writer.WriteSamples(Enumerable.Repeat(.25f, 96000).ToArray(), 0, 96000);
        }
        var peaks = WaveformSampler.Read(path, 20);
        Assert.Equal(20, peaks.Length);
        Assert.All(peaks.Take(10), value => Assert.Equal(0, value));
        Assert.All(peaks.Skip(10), value => Assert.InRange(value, .249f, .251f));
    }
    [Fact] public void CancelledWaveformLoadStopsReading()
    {
        using var folder = new TestFolder(); var path = Path.Combine(folder.Root, "waveform.wav"); TestFolder.Wave(path);
        Assert.ThrowsAny<OperationCanceledException>(() => WaveformSampler.Read(path, token: new CancellationToken(true)));
    }
    [Fact] public void PlaybackSeekClampsWithoutOpeningOutputDevice()
    {
        using var folder = new TestFolder(); var path = Path.Combine(folder.Root, "waveform.wav"); TestFolder.Wave(path, 2);
        using var player = new AudioPlayer(); player.Load(path);
        player.Seek(1.25); Assert.Equal(1.25, player.Position, precision: 4);
        player.Seek(-100); Assert.Equal(0, player.Position);
        player.Seek(100); Assert.Equal(2, player.Position);
        Assert.False(player.IsPlaying);
    }
    [Fact] public void MixerPreservesStereoAndAvoidsClipping()
    {
        byte[] source = new byte[4], output = new byte[4];
        BinaryPrimitives.WriteInt16LittleEndian(source.AsSpan(0, 2), 30000);
        BinaryPrimitives.WriteInt16LittleEndian(source.AsSpan(2, 2), -30000);
        PcmMixer.Mix([source, source], output, 4);
        Assert.Equal(source, output);
        PcmMixer.Mix([source, new byte[4]], output, 4);
        Assert.Equal(15000, BinaryPrimitives.ReadInt16LittleEndian(output));
        Assert.Equal(-15000, BinaryPrimitives.ReadInt16LittleEndian(output.AsSpan(2)));
    }
    [Fact] public void MixerRejectsUnalignedPcm()
        => Assert.Throws<ArgumentException>(() => PcmMixer.Mix([new byte[4]], new byte[4], 3));
    [Fact] public void FullNegativePcmSampleDoesNotOverflowLevelMeter()
        => Assert.Equal(1, PcmMixer.Peak([0, 128]));
    [Fact] public void TranscriptionChunksHaveBoundedSizeAndPreserveDuration()
    {
        using var folder = new TestFolder(); string path = Path.Combine(folder.Root, "audio.wav"); TestFolder.Wave(path, 2.25);
        var chunks = AudioFiles.ReadTranscriptionChunks(path, 1).ToList(); Assert.Equal(3, chunks.Count);
        double duration = 0;
        foreach (var chunk in chunks)
        {
            Assert.InRange(chunk.Length, 44, 32060);
            using var reader = new WaveFileReader(new MemoryStream(chunk));
            Assert.Equal(16000, reader.WaveFormat.SampleRate); Assert.Equal(1, reader.WaveFormat.Channels); Assert.Equal(16, reader.WaveFormat.BitsPerSample);
            duration += reader.TotalTime.TotalSeconds;
        }
        Assert.InRange(duration, 2.249, 2.251);
    }
    [Fact] public void Utf8SplittingPreservesKoreanAndEmoji()
    {
        string text = string.Concat(Enumerable.Repeat("회의 내용 👍🏽 결정 ", 100));
        var chunks = MeetingNotesService.SplitUtf8(text, 37);
        Assert.Equal(text, string.Join("", chunks));
        Assert.All(chunks, chunk => Assert.InRange(Encoding.UTF8.GetByteCount(chunk), 1, 37));
    }
}

public sealed class StubHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request, cancellationToken);
    public static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
}

public sealed class AiTests
{
    private const string Complete = "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"# 완성된 회의록\"}}],\"usage\":{\"cost\":0.01}}";
    [Fact] public async Task TranscriptionUsesDocumentedFixedEndpointAndBase64Wav()
    {
        using var client = new OpenRouterClient(new StubHandler(async (request, token) =>
        {
            Assert.Equal("https://openrouter.ai/api/v1/audio/transcriptions", request.RequestUri!.AbsoluteUri);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));
            Assert.Equal("wav", json.RootElement.GetProperty("input_audio").GetProperty("format").GetString());
            Assert.Equal(new byte[] { 1, 2, 3 }, Convert.FromBase64String(json.RootElement.GetProperty("input_audio").GetProperty("data").GetString()!));
            return StubHandler.Json("{\"text\":\"전사 내용\"}");
        }));
        Assert.Equal("전사 내용", (await client.TranscribeAsync([1, 2, 3], new AppSettings(), "test-key", default)).Text);
    }
    [Theory]
    [InlineData(401)][InlineData(402)][InlineData(429)][InlineData(500)][InlineData(302)]
    public async Task HttpErrorsDoNotExposeProviderBody(int status)
    {
        using var client = new OpenRouterClient(new StubHandler((_, _) => Task.FromResult(StubHandler.Json("private-provider-payload", (HttpStatusCode)status))));
        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() => client.CompleteAsync("system", "text", new AppSettings(), "test", default));
        Assert.DoesNotContain("private-provider-payload", exception.Message);
    }
    [Theory]
    [InlineData("length")][InlineData("error")][InlineData("content_filter")]
    public async Task IncompleteModelResponsesAreRejected(string reason)
    {
        using var client = new OpenRouterClient(new StubHandler((_, _) => Task.FromResult(StubHandler.Json(Complete.Replace("stop", reason)))));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.CompleteAsync("system", "text", new AppSettings(), "test", default));
    }
    [Fact] public async Task Http200ErrorEnvelopeIsStillFailure()
    {
        using var client = new OpenRouterClient(new StubHandler((_, _) => Task.FromResult(StubHandler.Json("{\"error\":{\"message\":\"private\"}}"))));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.CompleteAsync("system", "text", new AppSettings(), "test", default));
    }
    [Fact] public async Task EmptyFinalAnswerIsNotSavedAsNotes()
    {
        using var client = new OpenRouterClient(new StubHandler((_, _) => Task.FromResult(StubHandler.Json("{\"choices\":[{\"message\":{\"content\":\"\",\"reasoning\":\"not a report\"}}]}"))));
        await Assert.ThrowsAsync<InvalidDataException>(() => client.CompleteAsync("system", "text", new AppSettings(), "test", default));
    }
    [Fact] public async Task CancellationPropagatesToHttpRequest()
    {
        using var cancellation = new CancellationTokenSource();
        using var client = new OpenRouterClient(new StubHandler(async (_, token) => { cancellation.Cancel(); await Task.Delay(10000, token); return StubHandler.Json(Complete); }));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.CompleteAsync("system", "text", new AppSettings(), "test", cancellation.Token));
    }
    [Fact] public async Task CompletedTranscriptIsReusedAndFailedRegenerationPreservesNotes()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var record = new Recording { DurationSeconds = .2 }; TestFolder.Wave(library.AudioPath(record.Id), .2); library.Save(record);
        int transcriptions = 0, summaries = 0;
        using var client = new OpenRouterClient(new StubHandler((request, _) =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("transcriptions"))
            { transcriptions++; return Task.FromResult(StubHandler.Json("{\"text\":\"회의 내용\"}")); }
            summaries++;
            return Task.FromResult(summaries == 3 ? StubHandler.Json("failure", HttpStatusCode.InternalServerError) : StubHandler.Json(Complete));
        }));
        var service = new MeetingNotesService(library, client);
        var settings = new AppSettings(); var progress = new Progress<string>();
        await service.GenerateAsync(record, settings, "test", progress, default);
        await service.GenerateAsync(record, settings, "test", progress, default);
        string original = File.ReadAllText(library.NotesPath(record.Id));
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.GenerateAsync(record, settings, "test", progress, default));
        Assert.Equal(1, transcriptions); Assert.Equal(3, summaries);
        Assert.Equal(original, File.ReadAllText(library.NotesPath(record.Id)));
    }
    [Fact] public async Task AudioChangeInvalidatesTranscriptCache()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var record = new Recording { DurationSeconds = .2 }; TestFolder.Wave(library.AudioPath(record.Id), .2); library.Save(record);
        int transcriptions = 0;
        using var client = new OpenRouterClient(new StubHandler((request, _) =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("transcriptions"))
            { transcriptions++; return Task.FromResult(StubHandler.Json("{\"text\":\"회의\"}")); }
            return Task.FromResult(StubHandler.Json(Complete));
        }));
        var service = new MeetingNotesService(library, client);
        await service.GenerateAsync(record, new(), "test", new Progress<string>(), default);
        TestFolder.Wave(library.AudioPath(record.Id), .3);
        await service.GenerateAsync(record, new(), "test", new Progress<string>(), default);
        Assert.Equal(2, transcriptions);
    }

    [Fact] public async Task FailedSecondChunkResumesAfterSavedFirstChunk()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var record = new Recording { DurationSeconds = 120.2 }; TestFolder.Wave(library.AudioPath(record.Id), 120.2); library.Save(record);
        int transcriptions = 0;
        using var client = new OpenRouterClient(new StubHandler((request, _) =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("transcriptions"))
            {
                transcriptions++;
                return Task.FromResult(transcriptions == 2 ? StubHandler.Json("failure", HttpStatusCode.InternalServerError) : StubHandler.Json("{\"text\":\"구간 내용\"}"));
            }
            return Task.FromResult(StubHandler.Json(Complete));
        }));
        var service = new MeetingNotesService(library, client);
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.GenerateAsync(record, new(), "test", new Progress<string>(), default));
        var partial = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(record.Id))!;
        Assert.False(partial.Complete); Assert.Single(partial.Chunks); Assert.False(File.Exists(library.NotesPath(record.Id)));
        await service.GenerateAsync(record, new(), "test", new Progress<string>(), default);
        Assert.Equal(3, transcriptions);
        Assert.True(JsonDisk.Read<TranscriptCache>(library.TranscriptPath(record.Id))!.Complete);
    }

    [Fact] public async Task EmptyTranscriptionCanBeRetriedAndDoesNotReplaceExistingNotes()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var record = new Recording { DurationSeconds = .2 }; TestFolder.Wave(library.AudioPath(record.Id), .2); library.Save(record);
        var existing = new MeetingNotes("# 이전 회의록", DateTimeOffset.Now, "model", null);
        JsonDisk.Write(library.NotesPath(record.Id), existing);
        int transcriptions = 0;
        using var client = new OpenRouterClient(new StubHandler((_, _) => { transcriptions++; return Task.FromResult(StubHandler.Json("{\"text\":\"\"}")); }));
        var service = new MeetingNotesService(library, client);
        for (int i = 0; i < 2; i++)
            await Assert.ThrowsAsync<InvalidOperationException>(() => service.GenerateAsync(record, new(), "test", new Progress<string>(), default));
        Assert.Equal(2, transcriptions);
        Assert.Equal(existing, JsonDisk.Read<MeetingNotes>(library.NotesPath(record.Id)));
    }
}

public sealed class WebShareTests
{
    private static readonly Guid RecordingId = Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");

    [Fact] public async Task PublishUsesUppercaseSourceIdDedicatedTokenAndMinutesOnlyPayload()
    {
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token", new StubHandler(async (request, token) =>
        {
            Assert.Equal(HttpMethod.Put, request.Method);
            Assert.Equal("https://share.example.test/v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", request.RequestUri!.AbsoluteUri);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Equal("sync-token", request.Headers.Authorization.Parameter);
            var body = await request.Content!.ReadAsStringAsync(token);
            Assert.Equal("{\"title\":\"회의 제목\",\"markdown\":\"# 회의록\\n\\n결정 사항\"}", body);
            Assert.DoesNotContain("audio", body, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("transcript", body, StringComparison.OrdinalIgnoreCase);
            return StubHandler.Json("{\"url\":\"https://share.example.test/s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"expiresAt\":1790000000000}");
        }));

        var result = await client.PublishAsync(RecordingId, "  회의 제목  ", "# 회의록\n\n결정 사항", default);

        Assert.Equal("https://share.example.test/s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", result.Url);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1790000000000), result.ExpiresAt);
    }

    [Fact] public async Task StatusAndRevokeUseAuthenticatedManagementContractWithoutRawUrl()
    {
        var calls = new List<(HttpMethod Method, string Path)>();
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token", new StubHandler((request, _) =>
        {
            calls.Add((request.Method, request.RequestUri!.PathAndQuery));
            Assert.Equal("sync-token", request.Headers.Authorization!.Parameter);
            return Task.FromResult(request.Method == HttpMethod.Get
                ? StubHandler.Json("{\"active\":true,\"expiresAt\":1790000000000}")
                : new HttpResponseMessage(HttpStatusCode.NoContent));
        }));

        var status = await client.GetStatusAsync(RecordingId, default);
        await client.RevokeAsync(RecordingId, default);

        Assert.True(status.Active);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1790000000000), status.ExpiresAt);
        Assert.Equal([(HttpMethod.Get, "/v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            (HttpMethod.Delete, "/v1/shares/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")], calls);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"active\":true}")]
    [InlineData("{\"active\":true,\"expiresAt\":0}")]
    public async Task StatusRequiresExplicitActiveAndExpiryWhenActive(string responseBody)
    {
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token",
            new StubHandler((_, _) => Task.FromResult(StubHandler.Json(responseBody))));

        await Assert.ThrowsAsync<InvalidDataException>(() => client.GetStatusAsync(RecordingId, default));
    }

    [Fact] public async Task RedirectResponsesAreFailuresAndDoNotLeakProviderBody()
    {
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token",
            new StubHandler((_, _) => Task.FromResult(StubHandler.Json("private redirect body", HttpStatusCode.Redirect))));

        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            client.PublishAsync(RecordingId, "회의", "내용", default));

        Assert.Contains("리디렉션", exception.Message);
        Assert.DoesNotContain("private redirect body", exception.Message);
    }

    [Theory]
    [InlineData("https://evil.example.test/s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("https://share.example.test/other/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("https://share.example.test/s/short")]
    [InlineData("https://share.example.test/s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?copy=1")]
    [InlineData("https://user:pass@share.example.test/s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    public async Task PublishRejectsUnexpectedReturnedShareUrls(string returnedUrl)
    {
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token",
            new StubHandler((_, _) => Task.FromResult(StubHandler.Json($"{{\"url\":\"{returnedUrl}\",\"expiresAt\":1790000000000}}"))));

        await Assert.ThrowsAsync<InvalidDataException>(() => client.PublishAsync(RecordingId, "회의", "내용", default));
    }

    [Fact] public async Task RevokeRequiresNoContentContract()
    {
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token",
            new StubHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK))));

        await Assert.ThrowsAsync<InvalidOperationException>(() => client.RevokeAsync(RecordingId, default));
    }

    [Fact] public void SharingSettingsRequireHttpsServerAndDedicatedToken()
    {
        var settings = new AppSettings
        {
            SharingServerUrl = "http://share.example.test",
            ProtectedApiKey = SettingsStore.ProtectKey("openrouter-key"),
            ProtectedSharingSyncToken = SettingsStore.ProtectKey("sync-token")
        };

        Assert.Throws<InvalidOperationException>(() => SettingsStore.ReadSharingToken(settings with { ProtectedSharingSyncToken = null }));
        Assert.Equal("sync-token", SettingsStore.ReadSharingToken(settings));
        Assert.Throws<InvalidOperationException>(() => new WebShareClient(new Uri(settings.SharingServerUrl), SettingsStore.ReadSharingToken(settings)));
        Assert.Throws<InvalidOperationException>(() => new WebShareClient(new Uri("https://share.example.test/prefix/"), "sync-token"));
        Assert.Throws<InvalidOperationException>(() => new WebShareClient(new Uri("https://sync-token@share.example.test/"), "sync-token"));
        Assert.Throws<InvalidOperationException>(() => new WebShareClient(new Uri("https://share.example.test/?token=sync-token"), "sync-token"));
    }

    [Fact] public async Task PublishValidatesServerSidePayloadLimitsBeforeSending()
    {
        int sends = 0;
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token",
            new StubHandler((_, _) => { sends++; return Task.FromResult(StubHandler.Json("{}")); }));

        await Assert.ThrowsAsync<InvalidOperationException>(() => client.PublishAsync(RecordingId, "", "내용", default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.PublishAsync(RecordingId, new string('가', 301), "내용", default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.PublishAsync(RecordingId, "회의", "", default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.PublishAsync(RecordingId, "회의", new string('a', 1024 * 1024 + 1), default));
        Assert.Equal(0, sends);
    }

    [Fact] public async Task KoreanMarkdownNearOneMiBIsSentWithoutUnicodeEscaping()
    {
        var markdown = new string('가', 1024 * 1024 / Encoding.UTF8.GetByteCount("가"));
        using var client = new WebShareClient(new Uri("https://share.example.test/"), "sync-token", new StubHandler(async (request, token) =>
        {
            var bodyBytes = await request.Content!.ReadAsByteArrayAsync(token);
            var body = Encoding.UTF8.GetString(bodyBytes);
            Assert.Contains("가가가", body);
            Assert.DoesNotContain("\\uac00", body, StringComparison.OrdinalIgnoreCase);
            Assert.InRange(bodyBytes.Length, 1, 1024 * 1024 + 8192);
            return StubHandler.Json("{\"url\":\"https://share.example.test/s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"expiresAt\":1790000000000}");
        }));

        await client.PublishAsync(RecordingId, "회의", markdown, default);
    }
}
