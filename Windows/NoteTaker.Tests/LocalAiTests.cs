using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NAudio.Wave;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class LocalAiTests
{
    [Theory][InlineData("whisper")][InlineData("qwen")]
    public async Task LocalEnginesDoNotHallucinateOnDigitalSilence(string provider)
    {
        using var folder = new TestFolder();
        using var output = new MemoryStream();
        using (var writer = new WaveFileWriter(new NAudio.Utils.IgnoreDisposeStream(output), new WaveFormat(16000, 16, 1))) writer.Write(new byte[64000], 0, 64000);
        using var engine = AiProviders.Transcriber(folder.Root, new() { TranscriptionProvider = provider }, "", new Progress<string>());
        var result = await engine.TranscribeAsync(output.ToArray(), default);
        Assert.Empty(result.Text); Assert.Empty(result.Segments);
    }
    [Fact] public void NewSettingsUseLocalAiButLegacySettingsKeepCloud()
    {
        using var folder = new TestFolder(); var store = new SettingsStore(folder.Root);
        Assert.Equal("whisper", store.Load().TranscriptionProvider); Assert.Equal("ollama", store.Load().SummaryProvider);
        File.WriteAllText(Path.Combine(folder.Root, "settings.json"), "{\"summaryModel\":\"old-summary\",\"transcriptionModel\":\"old-stt\"}");
        Assert.Equal("openrouter", store.Load().SummaryProvider); Assert.Equal("old-summary", store.Load().SummaryModel);
    }
    [Theory]
    [InlineData("https://example.com")][InlineData("http://example.com")][InlineData("http://127.0.0.1/proxy")]
    [InlineData("http://user:password@localhost:11434")]
    public void LocalSummaryDoesNotAcceptRemoteOrProxyEndpoints(string address) => Assert.Throws<InvalidOperationException>(() => OllamaSummarizer.LocalAddress(address));
    [Fact] public async Task LocalSummaryUsesNoApiKeyAndDisablesThinking()
    {
        using var client = new OllamaSummarizer(new(), new StubHandler(async (request, token) =>
        {
            Assert.Equal("http://127.0.0.1:11434/api/chat", request.RequestUri!.AbsoluteUri);
            Assert.Null(request.Headers.Authorization);
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));
            Assert.False(json.RootElement.GetProperty("think").GetBoolean());
            Assert.Equal(0, json.RootElement.GetProperty("keep_alive").GetInt32());
            return StubHandler.Json("{\"done\":true,\"done_reason\":\"stop\",\"message\":{\"content\":\"# 로컬 회의록\"}}");
        }));
        var result = await client.CompleteAsync("system", "회의", default);
        Assert.Equal(0, result.CostUsd); Assert.Equal("# 로컬 회의록", result.Text);
    }
    [Theory]
    [InlineData("{\"done\":true,\"done_reason\":\"length\",\"message\":{\"content\":\"잘린 답변\"}}")]
    [InlineData("{\"done\":false,\"message\":{\"content\":\"미완성\"}}")]
    [InlineData("{\"done\":true,\"message\":{\"content\":\"\"}}")]
    public async Task LocalSummaryRejectsIncompleteOutput(string json)
    {
        using var client = new OllamaSummarizer(new(), new StubHandler((_, _) => Task.FromResult(StubHandler.Json(json))));
        await Assert.ThrowsAsync<InvalidDataException>(() => client.CompleteAsync("s", "t", default));
    }
    [Fact] public async Task ModelDownloadResumesAndValidatesPinnedHash()
    {
        using var folder = new TestFolder(); byte[] bytes = Encoding.UTF8.GetBytes("verified model fixture");
        var asset = new ModelAsset("model.bin", "https://example.com/model", bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)));
        string path = ModelDownload.PathFor(folder.Root, asset); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path + ".partial", bytes[..5]);
        var handler = new StubHandler((request, _) =>
        {
            Assert.Equal(5, Assert.Single(request.Headers.Range!.Ranges).From);
            var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(bytes[5..]) };
            response.Content.Headers.ContentRange = new ContentRangeHeaderValue(5, bytes.Length - 1, bytes.Length); return Task.FromResult(response);
        });
        await ModelDownload.EnsureAsync(folder.Root, asset, new Progress<string>(), default, handler);
        Assert.Equal(bytes, File.ReadAllBytes(path)); Assert.False(File.Exists(path + ".partial"));
    }
    [Fact] public async Task BadModelNeverBecomesReadyAndCanBeDownloadedAgain()
    {
        using var folder = new TestFolder(); byte[] bytes = [1, 2, 3];
        var asset = new ModelAsset("model.bin", "https://example.com/model", 3, Convert.ToHexString(SHA256.HashData(bytes)));
        var handler = new StubHandler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([3, 2, 1]) }));
        await Assert.ThrowsAsync<InvalidDataException>(() => ModelDownload.EnsureAsync(folder.Root, asset, new Progress<string>(), default, handler));
        Assert.False(File.Exists(ModelDownload.PathFor(folder.Root, asset)));
        Assert.Single(Directory.GetFiles(Path.Combine(folder.Root, "Models"), "*.invalid-*"));
    }
    [Fact] public async Task ImportedTranscriptKeepsOriginalAndSkipsAsrAfterModelChange()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var recording = new Recording { DurationSeconds = 2 }; TestFolder.Wave(library.AudioPath(recording.Id), 2); library.Save(recording);
        var old = new TranscriptCache("old", "old", "ko", ["이전 전사"], true); JsonDisk.Write(library.TranscriptPath(recording.Id), old);
        var imported = TranscriptImport.Parse("참석자 1 00:00\n금요일까지 검토하겠습니다.");
        await TranscriptImport.SaveAsync(library, recording, imported, default);
        var service = new MeetingNotesService(library, (_, _, _) => throw new Exception("ASR must not be called"), (_, _) => new FakeSummary());
        var transcript = await service.TranscribeAsync(recording, new() { TranscriptionProvider = "changed-model" }, "", new Progress<string>(), default);
        Assert.Equal("import", transcript.Source);
        Assert.Equal(imported.OriginalBytes, File.ReadAllBytes(Path.Combine(library.DirectoryFor(recording.Id), transcript.OriginalFile!)));
        Assert.Single(Directory.GetFiles(Path.Combine(library.DirectoryFor(recording.Id), "TranscriptHistory")));
        var notes = await service.SummarizeAsync(recording, new(), "", new Progress<string>(), default);
        Assert.Equal("# 로컬 결과", notes.Markdown);
        Assert.Equal(MeetingNotesService.TranscriptContentHash(transcript), notes.TranscriptHash);
    }
    [Fact] public async Task TranscriptionOnlyDoesNotInitializeSummaryAndPersistsTimeOffsets()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var recording = new Recording { DurationSeconds = 2.2 }; TestFolder.Wave(library.AudioPath(recording.Id), 2.2);
        var service = new MeetingNotesService(library, (_, _, _) => new FakeTranscriber(), (_, _) => throw new Exception("Summary must not be called"));
        var result = await service.TranscribeAsync(recording, new(), "", new Progress<string>(), default);
        Assert.True(result.Complete); Assert.Equal(3, result.Chunks.Count);
        Assert.Equal(2, result.Segments[2].StartSeconds); Assert.Equal("fake/v1", result.Fingerprint);
    }
    [Fact] public async Task ChangedEngineArchivesPreviousTranscript()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var recording = new Recording { DurationSeconds = 1 }; TestFolder.Wave(library.AudioPath(recording.Id));
        string identity = "v1";
        var service = new MeetingNotesService(library, (_, _, _) => new FakeTranscriber(identity), (_, _) => new FakeSummary());
        await service.TranscribeAsync(recording, new(), "", new Progress<string>(), default);
        identity = "v2";
        var changed = await service.TranscribeAsync(recording, new(), "", new Progress<string>(), default);
        Assert.Equal("fake/v2", changed.Fingerprint);
        var archive = Assert.Single(Directory.GetFiles(Path.Combine(library.DirectoryFor(recording.Id), "TranscriptHistory")));
        Assert.Equal("fake/v1", JsonDisk.Read<TranscriptCache>(archive)!.Fingerprint);
    }
    [Fact] public void SrtImportPreservesTimestampsAndRejectsInvalidTime()
    {
        var imported = TranscriptImport.Parse("1\n00:00:01,200 --> 00:00:02,300\n회의 내용\n\n2\n00:00:03,000 --> 00:00:04,000\n다음 안건", "회의.srt");
        Assert.Equal(2, imported.Segments.Count); Assert.Equal(1.2, imported.Segments[0].StartSeconds);
        Assert.Throws<InvalidDataException>(() => TranscriptImport.Parse("1\n00:70:00,000 --> 00:80:00,000\n내용", "bad.srt"));
    }
    [Fact] public async Task MismatchedSrtDoesNotReplaceCurrentTranscript()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root);
        var recording = new Recording { DurationSeconds = 1 }; TestFolder.Wave(library.AudioPath(recording.Id));
        File.WriteAllText(library.TranscriptPath(recording.Id), "existing original");
        var imported = TranscriptImport.Parse("1\n00:00:00,000 --> 00:10:00,000\n다른 녹음", "wrong.srt");
        await Assert.ThrowsAsync<InvalidDataException>(() => TranscriptImport.SaveAsync(library, recording, imported, default));
        Assert.Equal("existing original", File.ReadAllText(library.TranscriptPath(recording.Id)));
    }
    [Fact] public async Task ClovaExportSplitsWithinLimitAndRetainsEntireAudioDuration()
    {
        using var folder = new TestFolder(); string source = Path.Combine(folder.Root, "original.wav"); TestFolder.Wave(source, 2.2);
        byte[] original = SHA256.HashData(File.ReadAllBytes(source));
        var files = await ClovaAudioExport.ExportAsync(source, folder.Root, new Progress<string>(), default, partSeconds: 1);
        Assert.Equal(3, files.Count); double duration = 0;
        foreach (string file in files)
        {
            using var wave = new WaveFileReader(file);
            Assert.Equal(16000, wave.WaveFormat.SampleRate); Assert.Equal(1, wave.WaveFormat.Channels);
            Assert.InRange(wave.TotalTime.TotalSeconds, .19, 1.001); Assert.True(new FileInfo(file).Length < 300_000_000);
            duration += wave.TotalTime.TotalSeconds;
        }
        Assert.InRange(duration, 2.199, 2.201); Assert.Equal(original, SHA256.HashData(File.ReadAllBytes(source)));
    }
    private sealed class FakeTranscriber(string identity = "v1") : ITranscriber
    {
        public string Provider => "fake"; public string Model => identity; public string Fingerprint => "fake/" + identity; public int ChunkSeconds => 1;
        public Task<TranscribedAudio> TranscribeAsync(byte[] wav, CancellationToken token) => Task.FromResult(new TranscribedAudio("회의 내용", [new(0, .1, "회의 내용")]));
        public void Dispose() { }
    }
    private sealed class FakeSummary : ISummarizer
    {
        public string Model => "fake"; public int MaximumInputBytes => 16000;
        public Task<AiText> CompleteAsync(string system, string text, CancellationToken token) => Task.FromResult(new AiText("# 로컬 결과", 0));
        public void Dispose() { }
    }
}
