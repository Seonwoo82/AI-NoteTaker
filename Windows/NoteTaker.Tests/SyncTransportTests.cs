using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using NAudio.Wave;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class SyncTransportTests
{
    private static SyncRecording Recording(Guid? id = null) => new(1, id ?? Guid.Parse("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"), "동기화 회의", DateTimeOffset.Parse("2026-09-16T01:02:03.456Z"), 1,
        false, null, "micOnly", 1, false, null, 1, false, false, [], 1000, Guid.Parse("BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"));
    [Theory] [InlineData("http://example.com")] [InlineData("https://user:password@example.com")] [InlineData("https://example.com/path")] [InlineData("https://example.com?key=secret")] [InlineData("https://example.com#fragment")]
    public void OnlyCleanHttpsOriginsAreAccepted(string address) => Assert.Throws<InvalidOperationException>(() => new SyncConfiguration(address, "fixture-token"));
    [Fact] public void WireDocumentsUseAppleKeysDatesAndUuidCasingAndRejectUnknownFields()
    {
        var recording = Recording(); byte[] bytes = SyncJson.Encode(recording, SyncJson.MetadataLimit); string json = Encoding.UTF8.GetString(bytes);
        Assert.Contains("\"mutationID\"", json); Assert.Contains("2026-09-16T01:02:03Z", json); Assert.Contains(SyncJson.Id(recording.Id), json); Assert.DoesNotContain("durationSeconds", json);
        var decoded = SyncJson.Decode<SyncRecording>(bytes, SyncJson.MetadataLimit); decoded.Validate();
        Assert.Equal(SyncJson.Seconds(recording.CreatedAt), decoded.CreatedAt);
        Assert.Throws<InvalidDataException>(() => SyncJson.Decode<SyncRecording>(Encoding.UTF8.GetBytes(json.Replace("\"schemaVersion\":1,", "")), SyncJson.MetadataLimit));
        Assert.Throws<InvalidDataException>(() => SyncJson.Decode<SyncRecording>(Encoding.UTF8.GetBytes(json.Replace("\"title\":", "\"apiKey\":\"secret\",\"title\":")), SyncJson.MetadataLimit));
        // Swift encodeIfPresent omits nil speakerID/answer/insights, while required content stays required.
        var turn = SyncJson.Decode<TranscriptTurn>("""{"id":"t1","start":0,"end":1,"text":"원문"}"""u8, 1000); Assert.Null(turn.SpeakerId);
        Assert.Throws<InvalidDataException>(() => SyncJson.Decode<TranscriptTurn>("""{"id":"t1","start":0,"end":1}"""u8, 1000));
    }
    [Fact] public async Task FailedAndTruncatedTransfersPreserveDestinationAndDoNotExposeServerBody()
    {
        using var folder = new TestFolder(); string target = Path.Combine(folder.Root, "audio.m4a"); File.WriteAllText(target, "original");
        using var transport = new SyncTransport(new("https://sync.fixture", "test"), new StubHandler((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2, 3]) }; response.Content.Headers.ContentType = new("audio/mp4"); response.Content.Headers.ContentLength = 10; return Task.FromResult(response);
        }));
        await Assert.ThrowsAsync<InvalidDataException>(() => transport.DownloadAudioAsync(Recording(), target, default)); Assert.Equal("original", File.ReadAllText(target));
        using var rejected = new SyncTransport(new("https://sync.fixture", "test"), new StubHandler((_, _) => Task.FromResult(StubHandler.Json("secret-server-body", HttpStatusCode.Redirect))));
        var error = await Assert.ThrowsAsync<SyncHttpException>(() => rejected.HealthAsync(default)); Assert.DoesNotContain("secret", error.Message);
        Assert.Single(Directory.GetFiles(folder.Root));
    }
    [Fact] public async Task DocumentDownloadRequiresExactDescriptorHashAndLength()
    {
        byte[] bytes = Encoding.UTF8.GetBytes("{\"changed\":true}");
        using var transport = new SyncTransport(new("https://sync.fixture", "test"), new StubHandler((_, _) => Task.FromResult(StubHandler.Json(Encoding.UTF8.GetString(bytes)))));
        var descriptor = new SyncDescriptor(Recording().Id, 1, 1000, new string('0', 64), bytes.Length);
        await Assert.ThrowsAsync<InvalidDataException>(() => transport.DownloadDocumentAsync(descriptor, false, default));
    }
    [Fact] public async Task NativeAacRoundTripPreservesOriginalAndCancellationKeepsPriorOutput()
    {
        using var folder = new TestFolder(); string source = Path.Combine(folder.Root, "source.wav"), m4a = Path.Combine(folder.Root, "audio.m4a"), decoded = Path.Combine(folder.Root, "decoded.wav");
        TestFolder.Wave(source, 1); string hash = await MeetingNotesService.AudioHashAsync(source, default);
        await SyncAudio.EncodeAsync(source, m4a, default); double duration = await SyncAudio.DecodeAsync(m4a, decoded, default);
        Assert.InRange(duration, .95, 1.12); Assert.Equal(hash, await MeetingNotesService.AudioHashAsync(source, default));
        using var reader = new WaveFileReader(decoded); Assert.True(reader.Length > 10000);
        byte[] previous = File.ReadAllBytes(m4a); using var cts = new CancellationTokenSource(); cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => SyncAudio.EncodeAsync(source, m4a, cts.Token)); Assert.Equal(previous, File.ReadAllBytes(m4a));
    }
    [Fact] public async Task WindowsWireContractsRoundTripThroughActualWorkerHttpAndSqlite()
    {
        using var folder = new TestFolder(); using var server = await LocalSyncServer.StartAsync(folder.Root);
        using var transport = new SyncTransport(new("https://sync.fixture", "synthetic-windows-sync-token"), server.Handler());
        Assert.True((await transport.HealthAsync(default)).Ok);
        var recording = Recording(); string wav = Path.Combine(folder.Root, "source.wav"), m4a = Path.Combine(folder.Root, "source.m4a"), download = Path.Combine(folder.Root, "download.m4a");
        TestFolder.Wave(wav, 1); await SyncAudio.EncodeAsync(wav, m4a, default);
        await transport.UploadAudioAsync(recording, m4a, default);
        var published = await transport.PutRecordingAsync(recording, default); Assert.Equal(recording.Id, published.Id);
        Assert.Single((await transport.RecordingsAsync(null, default)).Recordings);
        await transport.DownloadAudioAsync(recording, download, default); Assert.Equal(File.ReadAllBytes(m4a), File.ReadAllBytes(download));
        // Immutable audio must retain its first successful upload even when a retry supplies different bytes.
        File.WriteAllBytes(m4a, [1, 2, 3]); await transport.UploadAudioAsync(recording, m4a, default); await transport.DownloadAudioAsync(recording, m4a, default); Assert.Equal(File.ReadAllBytes(download), File.ReadAllBytes(m4a));
        var collection = new RecordingCollectionFolder { Name = "검토 폴더" };
        await transport.PutFolderAsync(collection, default); Assert.Single((await transport.FoldersAsync(null, default)).Folders);
        var transcript = new MeetingTranscript(recording.Id, 1, "fixture", [new("s1", "민수")], [new("t1", 0, 1, "s1", "금요일까지 준비하겠습니다.")]);
        var notes = new SyncNotes(1, recording.Id, 1, DateTimeOffset.Parse("2026-09-16T01:02:03Z"), "fixture", "fixture", "# 회의록", "금요일까지 준비하겠습니다.", SpeakerTranscript: transcript);
        notes.Validate(1); byte[] bytes = SyncJson.Encode(notes, SyncJson.NotesLimit);
        var descriptor = await transport.UploadDocumentAsync(recording.Id, 1, bytes, false, default); Assert.Equal(SyncJson.Hash(bytes), descriptor.Revision);
        Assert.Equal(bytes, await transport.DownloadDocumentAsync(descriptor, false, default)); Assert.Single((await transport.NotesAsync(null, default)).Notes);
        var intelligence = new MeetingIntelligenceDocument(recording.Id, 1, 1000, Guid.NewGuid(), "출시", transcript, null, [], "fixture");
        byte[] analysisBytes = SyncJson.Encode(intelligence, SyncJson.IntelligenceLimit); var analysisDescriptor = await transport.UploadDocumentAsync(recording.Id, 1, analysisBytes, true, default);
        Assert.Equal(analysisBytes, await transport.DownloadDocumentAsync(analysisDescriptor, true, default)); Assert.Single((await transport.IntelligenceAsync(null, default)).Intelligence);
        var profile = new MeetingProfile { DisplayName = "민수", ModifiedAt = 1000 }; Assert.Equal("민수", (await transport.ProfileAsync(profile, default)).Profile!.DisplayName);
        var edit = new MeetingEdit(Guid.NewGuid(), recording.Id, 1, 1001, "speakerName", "s1", "김민수");
        var entry = await transport.PutEditAsync(edit, default); Assert.Equal(entry, await transport.PutEditAsync(edit, default)); Assert.Equal(edit, (await transport.EditsAsync(0, default)).Entries.Single().Edit);
        var preferences = new SyncPreferences(1, "fixture/summary", "fixture/stt", "ko", true, 1000, Guid.NewGuid(), "fixture/revise", true);
        var response = await transport.SettingsAsync(Guid.NewGuid(), new(preferences, new(Guid.NewGuid(), "Windows", false)), default); Assert.Equal(preferences, response.Preferences);
        var tombstone = recording with { ModifiedAt = 2000, MutationId = Guid.NewGuid(), DeletedAt = DateTimeOffset.UtcNow };
        await transport.PutRecordingAsync(tombstone, default); Assert.NotNull((await transport.PutRecordingAsync(recording, default)).DeletedAt);
    }
    [Fact] public async Task CancellationDuringNativeEncodingPreservesThePreviousM4a()
    {
        using var folder = new TestFolder(); string source = Path.Combine(folder.Root, "long.wav"), target = Path.Combine(folder.Root, "audio.m4a");
        TestFolder.Wave(source, 60); File.WriteAllText(target, "previous output"); using var cts = new CancellationTokenSource();
        var operation = SyncAudio.EncodeAsync(source, target, cts.Token); await Task.Delay(20); cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => operation);
        Assert.Equal("previous output", File.ReadAllText(target)); Assert.Equal(2, Directory.GetFiles(folder.Root).Length);
    }
    [Theory] [InlineData(false)] [InlineData(true)] public async Task AudioConversionCannotOverwriteItsSource(bool decode)
    {
        using var folder = new TestFolder(); string source = Path.Combine(folder.Root, "source.wav"); TestFolder.Wave(source); byte[] before = File.ReadAllBytes(source);
        if (decode) await Assert.ThrowsAsync<InvalidOperationException>(() => SyncAudio.DecodeAsync(source, source, default));
        else await Assert.ThrowsAsync<InvalidOperationException>(() => SyncAudio.EncodeAsync(source, source, default));
        Assert.Equal(before, File.ReadAllBytes(source));
    }
}
internal sealed class LocalSyncServer(Process process, int port) : IDisposable
{
    public static async Task<LocalSyncServer> StartAsync(string root)
    {
        string? repository = AppContext.BaseDirectory;
        while (repository is not null && !File.Exists(Path.Combine(repository, "Cloudflare", "worker.mjs"))) repository = Path.GetDirectoryName(repository);
        if (repository is null) throw new InvalidOperationException("Repository required for actual Worker integration test.");
        var start = new ProcessStartInfo("node") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add(Path.Combine(repository, "Cloudflare", "tests", "local-sync-server.mjs")); start.ArgumentList.Add(Path.Combine(root, "server"));
        start.Environment["PYTHON"] = Environment.GetEnvironmentVariable("PYTHON") ?? (OperatingSystem.IsWindows() ? "python" : "python3");
        var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start local Worker.");
        try
        {
            string? line = await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(20));
            if (line is null) throw new InvalidOperationException(await process.StandardError.ReadToEndAsync());
            using var json = JsonDocument.Parse(line); return new(process, json.RootElement.GetProperty("port").GetInt32());
        }
        catch { if (!process.HasExited) process.Kill(true); process.Dispose(); throw; }
    }
    public HttpMessageHandler Handler() => new LoopbackBridge(port);
    private sealed class LoopbackBridge(int port) : DelegatingHandler(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseProxy = false })
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Assert.Equal("sync.fixture", request.RequestUri!.Host); request.RequestUri = new Uri($"http://127.0.0.1:{port}" + request.RequestUri.PathAndQuery);
            var response = await base.SendAsync(request, token);
            Assert.True(response.IsSuccessStatusCode, "Local fixture Worker: " + (response.IsSuccessStatusCode ? "" : await response.Content.ReadAsStringAsync(token))); return response;
        }
    }
    public void Dispose() { if (!process.HasExited) { process.Kill(true); process.WaitForExit(); } process.Dispose(); }
}
