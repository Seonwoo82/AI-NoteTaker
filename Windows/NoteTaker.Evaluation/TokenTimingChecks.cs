using NoteTaker.Core;
using Whisper.net;

internal static class TokenTimingChecks
{
    public static async Task<int> RunAsync(string source, string output, string root, string language)
    {
        Directory.CreateDirectory(output); await ModelDownload.VerifyAsync(ModelDownload.PathFor(root, ModelDownload.WhisperTurbo), ModelDownload.WhisperTurbo, default);
        LocalRuntime.LoadCudaDependencies(root);
        using var factory = WhisperFactory.FromPath(ModelDownload.PathFor(root, ModelDownload.WhisperTurbo), new() { UseGpu = true });
        var capture = new WhisperUtf8Capture();
        await using var processor = factory.CreateBuilder().WithLanguage(language).WithThreads(4).WithTemperature(0).WithTokenTimestamps().WithStringPool(capture).Build();
        var result = new List<object>();
        using var wave = new MemoryStream(AudioFiles.ReadTranscriptionChunks(source).First());
        int wordCount = 0, untimed = 0;
        await foreach (var segment in processor.ProcessAsync(wave))
        {
            var words = WhisperTokenAlignment.Align(segment, capture); wordCount += words.Count;
            if (words.Count == 0) untimed++;
            if (words.Count > 0 && string.Concat(words.Select(w => w.Text)) != segment.Text) throw new InvalidOperationException("Timing reconstruction changed text.");
            result.Add(new { segment.Text, Start = segment.Start.TotalSeconds, End = segment.End.TotalSeconds, Words = words,
                Tokens = segment.Tokens.Select(t => new { t.Id, t.Text, t.Start, t.End, t.Probability }).ToList() });
        }
        JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = untimed == 0 && wordCount > 0, Segments = result.Count, WordPieces = wordCount, SegmentsWithoutWords = untimed });
        JsonDisk.Write(Path.Combine(output, "tokens.json"), result); Console.WriteLine($"Saved {result.Count} segments with native token centiseconds."); return untimed == 0 && wordCount > 0 ? 0 : 1;
    }
}
