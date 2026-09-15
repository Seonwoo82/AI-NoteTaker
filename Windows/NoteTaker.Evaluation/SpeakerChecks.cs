using System.Diagnostics;
using NoteTaker.Core;
using NAudio.Wave;

internal static class SpeakerChecks
{
    public static async Task<int> RunAsync(string audio, string output, string modelRoot)
    {
        Directory.CreateDirectory(output); var progress = new Progress<string>(Console.WriteLine);
        await SpeakerModels.PrepareAsync(modelRoot, progress, default);
        var client = new SpeakerWorkerClient(modelRoot);
        var timer = Stopwatch.StartNew();
        var result = await client.DiarizeAsync(audio, progress, default);
        JsonDisk.Write(Path.Combine(output, "diarization.json"), new { ElapsedSeconds = timer.Elapsed.TotalSeconds, Result = result });
        Console.WriteLine($"Found {result.Speakers.Count} speakers, {result.Segments.Count} segments in {timer.Elapsed.TotalSeconds:F2}s.");
        using var cancellation = new CancellationTokenSource();
        var cancelled = client.DiarizeAsync(audio, progress, cancellation.Token);
        cancellation.CancelAfter(500);
        try { await cancelled; throw new InvalidOperationException("Cancellation did not interrupt the owned worker."); }
        catch (OperationCanceledException) { Console.WriteLine("Worker cancellation passed."); }
        // Successful execution is not an accuracy assertion: the speaker count is reported above.
        return 0;
    }
    public static async Task<int> VoiceAsync(string fourSpeakerSample, string output, string modelRoot)
    {
        Directory.CreateDirectory(output);
        var progress = new Progress<string>(_ => { }); await SpeakerModels.PrepareAsync(modelRoot, progress, default);
        var client = new SpeakerWorkerClient(modelRoot);
        // Disjoint reference intervals from Sherpa's public four-speaker sample (not model-produced crops).
        string enrollment = Crop("enrollment", [new(.4, 6.7)]);
        string heldOut = Crop("held-out", [new(22.2, 24.7), new(52.6, 54.5)]);
        string other = Crop("other-person", [new(7.1, 10.6), new(11.6, 13.5)]);
        var enrolled = await client.EmbedAsync(enrollment, progress, default);
        var same = await client.EmbedAsync(heldOut, progress, default);
        var different = await client.EmbedAsync(other, progress, default);
        double sameScore = SpeakerWorkerClient.Cosine(enrolled.Embedding, same.Embedding), differentScore = SpeakerWorkerClient.Cosine(enrolled.Embedding, different.Embedding);
        var rejected = new List<string>();
        foreach (string kind in new[] { "silence", "noise" })
        {
            string path = Path.Combine(output, kind + ".wav"); var random = new Random(194);
            var samples = Enumerable.Range(0, 160000).Select(_ => kind == "silence" ? 0f : (float)(random.NextDouble() * .1 - .05)).ToArray();
            using (var writer = new WaveFileWriter(path, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1))) writer.WriteSamples(samples, 0, samples.Length);
            try { await client.EmbedAsync(path, progress, default); }
            catch (InvalidDataException) { rejected.Add(kind); }
        }
        JsonDisk.Write(Path.Combine(output, "voice-result.json"), new { SameSpeakerCosine = sameScore, DifferentSpeakerCosine = differentScore, RejectedInputs = rejected,
            Source = "sherpa public 0-four-speakers-zh.wav; manually specified disjoint reference speech, padded with silence to 10 seconds", enrolled.SampleDuration, enrolled.SpeechDuration });
        Console.WriteLine($"Held-out same={sameScore:F4}, other={differentScore:F4}; rejected={string.Join(',', rejected)}");
        return sameScore > .6 && differentScore < .5 && sameScore - differentScore > .15 && rejected.Count == 2 ? 0 : 1;

        string Crop(string name, AudioRange[] ranges)
        {
            string path = Path.Combine(output, name + ".wav"); using var reader = new AudioFileReader(fourSpeakerSample);
            var source = new AudioRangeSampleProvider(reader, ranges); using var writer = new WaveFileWriter(path, source.WaveFormat);
            var buffer = new float[16000]; int read, count = 0;
            while ((read = source.Read(buffer, 0, buffer.Length)) > 0) { writer.WriteSamples(buffer, 0, read); count += read; }
            int padding = Math.Max(0, 10 * source.WaveFormat.SampleRate * source.WaveFormat.Channels - count);
            if (padding > 0) writer.WriteSamples(new float[padding], 0, padding);
            return path;
        }
    }
}
