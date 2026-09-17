using System.Text;
using System.Text.Json;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class NotesEditingTests
{
    private sealed class StructuredCleanupModel : IStructuredSummarizer
    {
        public string Model => "structured-fixture"; public int MaximumInputBytes => 12000;
        public Task<AiText> CompleteAsync(string system, string text, CancellationToken token) => throw new InvalidOperationException("Expected schema-constrained cleanup.");
        public Task<AiText> CompleteStructuredAsync(string system, string text, JsonElement schema, CancellationToken token)
        {
            using var json = JsonDocument.Parse(text); int count = json.RootElement.GetProperty("passages").GetArrayLength();
            var passages = schema.GetProperty("properties").GetProperty("passages"); Assert.Equal(count, passages.GetProperty("minItems").GetInt32()); Assert.Equal(count, passages.GetProperty("maxItems").GetInt32());
            Assert.Equal(count, passages.GetProperty("items").GetProperty("properties").GetProperty("id").GetProperty("enum").GetArrayLength());
            return Task.FromResult(new AiText(Echo(text), 0));
        }
        public void Dispose() { }
    }
    [Fact] public async Task LocalCleanupUsesSchemaAndStillValidatesSourceIdentity()
    {
        var source = CleanupSource.Make("첫 발언입니다.\n\n일정은 6월 20일 목표입니다.", null);
        var result = await TranscriptCleanupService.PrepareAsync(source, new StructuredCleanupModel(), new Progress<string>(), default);
        Assert.Equal(source.Passages, result.Cleanup.Passages);
    }
    private sealed class FixtureModel(Func<string, string, CancellationToken, Task<string>> run, int limit = 12000) : ISummarizer
    {
        public string Model => "editing-fixture";
        public int MaximumInputBytes => limit;
        public async Task<AiText> CompleteAsync(string system, string text, CancellationToken token)
        {
            Assert.True(Encoding.UTF8.GetByteCount(system) + Encoding.UTF8.GetByteCount(text) <= limit);
            return new(await run(system, text, token), .01m);
        }
        public void Dispose() { }
    }
    private static async Task<(LibraryStore Library, Recording Recording)> Setup(TestFolder folder)
    {
        var library = new LibraryStore(folder.Root); var recording = new Recording { DurationSeconds = 1 };
        library.Save(recording); TestFolder.Wave(library.AudioPath(recording.Id));
        var cache = new TranscriptCache(await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default), "fixture", "ko", ["[00:01] 출시 예산은 300만 원입니다. 일정은 확정하지 않았습니다."], true);
        JsonDisk.Write(library.TranscriptPath(recording.Id), cache);
        JsonDisk.Write(library.NotesPath(recording.Id), new MeetingNotes("# 출시 회의\n\n## 일정\n출시는 목표 일정입니다.\n\n## 예산\n300만 원", DateTimeOffset.Now, "original", .02m) { TranscriptHash = MeetingNotesService.TranscriptContentHash(cache) });
        return (library, recording);
    }
    [Fact] public async Task PreviewDoesNotWriteAndApplyPreservesSourcesAndProvenance()
    {
        using var folder = new TestFolder(); var (library, recording) = await Setup(folder);
        string notes = File.ReadAllText(library.NotesPath(recording.Id)), transcript = File.ReadAllText(library.TranscriptPath(recording.Id));
        var model = new FixtureModel((_, _, _) => Task.FromResult("# 출시 회의\n\n일정은 미확정입니다. 예산은 300만 원입니다."));
        var service = new MeetingNotesEditingService(library, (_, _) => model);
        var preview = await service.PreviewAsync(recording, new(), "", "목표와 확정 일정을 구별해 주세요.", new Progress<string>(), default);
        Assert.Equal(notes, File.ReadAllText(library.NotesPath(recording.Id)));
        await service.ApplyAsync(recording, preview, default);
        var saved = new NotesDocumentStore(library).Load(recording)!;
        Assert.Equal(preview.Markdown, saved.Markdown); Assert.Equal("original", saved.Model); Assert.Equal("editing-fixture", saved.Enhancement!.ModelId);
        Assert.Equal(.03m, saved.CostUsd); Assert.Equal(preview.Original.TranscriptHash, saved.TranscriptHash);
        Assert.Equal(transcript, File.ReadAllText(library.TranscriptPath(recording.Id)));
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.ApplyAsync(recording, preview, default));
    }
    [Theory] [InlineData("notes")] [InlineData("transcript")] [InlineData("profile")] [InlineData("audio")] [InlineData("edits")] [InlineData("metadata")]
    public async Task ApplyRejectsConcurrentSourceChange(string change)
    {
        using var folder = new TestFolder(); var (library, recording) = await Setup(folder);
        var service = new MeetingNotesEditingService(library, (_, _) => new FixtureModel((_, _, _) => Task.FromResult("# 수정안")));
        var preview = await service.PreviewAsync(recording, new(), "", "일정을 보완해 주세요.", new Progress<string>(), default);
        switch (change)
        {
            case "notes": JsonDisk.Write(library.NotesPath(recording.Id), preview.Original with { Markdown = "# 다른 기기의 변경" }); break;
            case "transcript": File.AppendAllText(library.TranscriptPath(recording.Id), " "); break;
            case "profile": JsonDisk.Write(Path.Combine(library.Root, "meeting-profile.json"), new MeetingProfile()); break;
            case "audio": TestFolder.Wave(library.AudioPath(recording.Id), amplitude: .1f); break;
            case "edits": File.WriteAllText(Path.Combine(library.DirectoryFor(recording.Id), "meeting-edits-local.json"), "{}"); break;
            case "metadata": library.Save(recording with { DeletedAt = DateTimeOffset.Now }); break;
        }
        string existing = File.ReadAllText(library.NotesPath(recording.Id));
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.ApplyAsync(recording, preview, default));
        Assert.Equal(existing, File.ReadAllText(library.NotesPath(recording.Id)));
    }
    [Theory] [InlineData(false)] [InlineData(true)] public async Task PreviewFailureAndCancellationLeaveExistingNotes(bool cancel)
    {
        using var folder = new TestFolder(); var (library, recording) = await Setup(folder); using var cts = new CancellationTokenSource();
        string existing = File.ReadAllText(library.NotesPath(recording.Id));
        var service = new MeetingNotesEditingService(library, (_, _) => new FixtureModel((_, _, token) =>
        {
            if (cancel) { cts.Cancel(); token.ThrowIfCancellationRequested(); }
            throw new InvalidDataException("fixture failure");
        }));
        await Assert.ThrowsAnyAsync<Exception>(() => service.PreviewAsync(recording, new(), "", "보완", new Progress<string>(), cts.Token));
        Assert.Equal(existing, File.ReadAllText(library.NotesPath(recording.Id)));
    }
    [Fact] public void EnhancementPartsCoverUnicodeMarkdownAndAllowNewContextOnlyAtEnd()
    {
        string markdown = string.Concat(Enumerable.Range(0, 130).Select(i => $"## 주제 {i} 😀\n확정하지 않은 일정을 유지합니다.\n\n"));
        var parts = MeetingEnhancementPrompts.Parts(markdown, "원문 일정 미확정", "확정 일정을 구별", "ko", 4000);
        Assert.InRange(parts.Count, 2, 32);
        var decoded = parts.Select(p => JsonDocument.Parse(p)).ToList();
        try
        {
            Assert.Equal(markdown, string.Concat(decoded.Select(p => p.RootElement.GetProperty("existing_markdown").GetString())));
            for (int i = 0; i < parts.Count; i++)
            {
                Assert.Equal(i == parts.Count - 1, decoded[i].RootElement.GetProperty("allows_new_context").GetBoolean());
                Assert.True(Encoding.UTF8.GetByteCount(parts[i]) + Encoding.UTF8.GetByteCount(MeetingEnhancementPrompts.System("ko", true)) <= 4000);
            }
        }
        finally { decoded.ForEach(p => p.Dispose()); }
        Assert.Throws<InvalidOperationException>(() => MeetingEnhancementPrompts.Parts(markdown, "", new string('가', 3000), "ko", 4000));
    }
    private static string Echo(string prompt, Func<string, string>? transform = null)
    {
        using var json = JsonDocument.Parse(prompt);
        return JsonSerializer.Serialize(new { passages = json.RootElement.GetProperty("passages").EnumerateArray().Reverse().Select(p => new { id = p.GetProperty("id").GetString(), text = transform?.Invoke(p.GetProperty("text").GetString()!) ?? p.GetProperty("text").GetString() }) });
    }
    [Fact] public async Task CleanupPreservesUnicodeBoundariesNumbersAndSourceHash()
    {
        string text = string.Concat(Enumerable.Repeat("예산 300만 원, 일정은 미확정입니다. 😀 ", 50)).Trim();
        var source = CleanupSource.Make(text, null);
        var model = new FixtureModel((_, prompt, _) => Task.FromResult(Echo(prompt)), 5000);
        var result = await TranscriptCleanupService.PrepareAsync(source, model, new Progress<string>(), default);
        Assert.Equal(text, result.Cleanup.CleanedText); Assert.Equal(source.Hash, result.Cleanup.SourceHash);
        Assert.Throws<InvalidDataException>(() => result.Cleanup.Validate(CleanupSource.Make(text + "변경", null)));
        var runeSource = CleanupSource.Make(new string('가', 1999) + "😀끝", null);
        Assert.Equal(2000, runeSource.Passages[0].Text.EnumerateRunes().Count()); Assert.EndsWith("😀", runeSource.Passages[0].Text); Assert.Equal("끝", runeSource.Passages[1].Text);
    }
    [Theory] [InlineData("300", "301")] [InlineData("00:01", "00:02")]
    public void CleanupRejectsChangedNumbersAndTimestamps(string from, string to)
    {
        var source = CleanupSource.Make("[00:01] 예산은 300만 원입니다.", null);
        var batch = TranscriptCleanupPrompts.Batches(source, 12000).Single();
        Assert.Throws<InvalidDataException>(() => batch.Decode(Echo(batch.Prompt, s => s.Replace(from, to))));
        Assert.Throws<InvalidDataException>(() => batch.Decode("{\"passages\":[{\"id\":\"unknown\",\"text\":\"내용\"}]}"));
    }
    [Theory] [InlineData("아직 확정한 일정은 아닙니다.", "아직 확 정한 일정은 아닌니다.")]
    [InlineData("예산은 유지합니다.", "예산 은 유지 합니다.")]
    [InlineData("출시는 확정하지 않았습니다.", "출시는 확정했습니다.")]
    public async Task CleanupKeepsOriginalWhenModelChangesSpellingNegationOrSplitsKoreanWords(string original, string damaged)
    {
        var result = await TranscriptCleanupService.PrepareAsync(CleanupSource.Make(original, null), new FixtureModel((_, p, _) => Task.FromResult(Echo(p, _ => damaged))), new Progress<string>(), default);
        Assert.Equal(original, result.Cleanup.CleanedText);
    }
    [Fact] public async Task CleanupRejectsExcessiveRemovalAndPreservesManualNotesOnFailure()
    {
        var source = CleanupSource.Make("이 내용은 확정되지 않은 제안으로 다음 회의에서 다시 논의합니다.", null);
        await Assert.ThrowsAsync<InvalidDataException>(() => TranscriptCleanupService.PrepareAsync(source, new FixtureModel((_, p, _) => Task.FromResult(Echo(p, _ => "제안"))), new Progress<string>(), default));
        using var folder = new TestFolder(); var (library, recording) = await Setup(folder);
        string original = File.ReadAllText(library.NotesPath(recording.Id));
        var service = new MeetingNotesEditingService(library, (_, _) => new FixtureModel((_, p, _) => Task.FromResult(Echo(p, s => s.Replace("300", "301")))));
        await Assert.ThrowsAsync<InvalidDataException>(() => service.CleanAsync(recording, new(), "", new Progress<string>(), default));
        Assert.Equal(original, File.ReadAllText(library.NotesPath(recording.Id)));
    }
    [Fact] public async Task AutomaticCleanupFallsBackToOriginalAndSuccessfulCleanupIsReused()
    {
        using var folder = new TestFolder(); var (library, recording) = await Setup(folder); int calls = 0; bool broken = true;
        string original = File.ReadAllText(library.TranscriptPath(recording.Id));
        var model = new FixtureModel((system, prompt, _) =>
        {
            if (system == TranscriptCleanupPrompts.System) { calls++; return Task.FromResult(broken ? "invalid json" : Echo(prompt)); }
            Assert.Contains("300만 원", prompt); return Task.FromResult("# 회의록\n예산 300만 원. 일정 미확정.");
        });
        var service = new MeetingNotesService(library, (_, _, _) => throw new InvalidOperationException("Must reuse existing transcript."), (_, _) => model);
        var fallback = await service.SummarizeAsync(recording, new(), "", new Progress<string>(), default);
        Assert.Null(fallback.Cleanup); Assert.NotNull(fallback.CleanupNotice);
        broken = false; var cleaned = await service.SummarizeAsync(recording, new(), "", new Progress<string>(), default); Assert.NotNull(cleaned.Cleanup);
        await service.SummarizeAsync(recording, new(), "", new Progress<string>(), default);
        Assert.Equal(2, calls); Assert.Equal(original, File.ReadAllText(library.TranscriptPath(recording.Id)));
    }
}
